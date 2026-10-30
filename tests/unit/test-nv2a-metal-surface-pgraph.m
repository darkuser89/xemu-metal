/* Native PGRAPH/QEMU boundary tests. No VM or application is started.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
/* QEMU's existing inline headers are built without these extra warnings.
 * Keep the adapter/test code under -Wextra/-Werror after the include boundary.
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/surface-pgraph.h"

static NV2AState *state;
static MemAccessCallback *hook;
static QemuEvent kicked;
static unsigned pfifo_kicks;
static CPUState cpu;
static unsigned vga_dirty, texture_dirty, checks;
static unsigned expected_zeta_byte = 255;
static DMAObject color_dma, zeta_dma;
bool tcg_allowed = true;

/* Actual QEMU types and synchronization, with the VM/DMA registration boundary
 * mocked so that the GPU adapter can be exercised without running a machine. */
uint64_t memory_region_size(MemoryRegion *mr)
{
    (void)mr;
    return 65536;
}
void *memory_region_get_ram_ptr(MemoryRegion *mr)
{
    (void)mr;
    return state->vram_ptr;
}
void memory_region_set_client_dirty(MemoryRegion *mr, hwaddr address,
                                    hwaddr size, unsigned client)
{
    assert(mr == state->vram && address >= 576 && size);
    assert(state->vram_ptr[address] ==
           (address == 4160 ? expected_zeta_byte : 255));
    if (client == DIRTY_MEMORY_VGA) {
        vga_dirty++;
    } else {
        assert(client == DIRTY_MEMORY_NV2A_TEX);
        texture_dirty++;
    }
}
bool memory_region_test_and_clear_dirty(MemoryRegion *mr, hwaddr address,
                                        hwaddr size, unsigned client)
{
    (void)mr;
    (void)address;
    (void)size;
    (void)client;
    return false;
}
DMAObject nv_dma_load(NV2AState *d, hwaddr address)
{
    assert(d == state);
    return address == d->pgraph.dma_color ? color_dma : zeta_dma;
}
/* Clear-value capture is part of the mocked QEMU boundary; formulas below
 * match the existing helpers in pgraph.c, independently of the GPU clearer. */
void pgraph_get_clear_color(PGRAPHState *pg, float rgba[4])
{
    uint32_t v = pgraph_reg_r(pg, NV_PGRAPH_COLORCLEARVALUE);
    unsigned f = pg->surface_shape.color_format;
    if (f == NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5) {
        rgba[0] = ((v >> 11) & 31) / 31.0f;
        rgba[1] = ((v >> 5) & 63) / 63.0f;
        rgba[2] = (v & 31) / 31.0f;
    } else if (f == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5) {
        rgba[0] = ((v >> 10) & 31) / 31.0f;
        rgba[1] = ((v >> 5) & 31) / 31.0f;
        rgba[2] = (v & 31) / 31.0f;
    } else {
        assert(f == NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 ||
               f == NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8);
        rgba[0] = ((v >> 16) & 255) / 255.0f;
        rgba[1] = ((v >> 8) & 255) / 255.0f;
        rgba[2] = (v & 255) / 255.0f;
    }
    rgba[3] = f == NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 ?
                  (v >> 24) / 255.0f :
                  1;
}
void pgraph_get_clear_depth_stencil_value(PGRAPHState *pg, float *depth,
                                          int *stencil)
{
    uint32_t v = pgraph_reg_r(pg, NV_PGRAPH_ZSTENCILCLEARVALUE);
    if (pg->surface_shape.zeta_format == NV097_SET_SURFACE_FORMAT_ZETA_Z16) {
        *stencil = 0;
        *depth = pg->surface_shape.z_format ?
                     convert_f16_to_float(v & 65535) / f16_max :
                     (v & 65535) / 65535.0f;
    } else {
        assert(pg->surface_shape.zeta_format ==
               NV097_SET_SURFACE_FORMAT_ZETA_Z24S8);
        *stencil = v & 255;
        *depth = pg->surface_shape.z_format ?
                     convert_f24_to_float(v >> 8) / f24_max :
                     (v >> 8) / 16777215.0f;
    }
}
CPUState *qemu_get_cpu(int index)
{
    assert(index == 0);
    return &cpu;
}
static GPtrArray *registered_hooks;
MemAccessCallback *mem_access_callback_insert(CPUState *c, MemoryRegion *mr,
                                              hwaddr address, hwaddr length,
                                              MemAccessCallbackFunc func,
                                              void *opaque)
{
    assert(c == &cpu && mr == state->vram && length && address < 65536 &&
           length <= 65536 - address);
    if (!registered_hooks)
        registered_hooks = g_ptr_array_new();
    MemAccessCallback *entry = g_new0(MemAccessCallback, 1);
    entry->mr = mr;
    entry->addr = address;
    entry->len = length;
    entry->func = func;
    entry->opaque = opaque;
    g_ptr_array_add(registered_hooks, entry);
    hook = entry;
    return entry;
}
void mem_access_callback_remove_by_ref(CPUState *c, MemAccessCallback *h)
{
    assert(c == &cpu && g_ptr_array_remove(registered_hooks, h));
    g_free(h);
    hook = registered_hooks->len ?
               g_ptr_array_index(registered_hooks, registered_hooks->len - 1) :
               NULL;
    if (!hook) {
        g_ptr_array_unref(registered_hooks);
        registered_hooks = NULL;
    }
}
void pfifo_kick(NV2AState *d)
{
    assert(d == state);
    pfifo_kicks++;
    qemu_event_set(&kicked);
}
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "PGRAPH surface adapter: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void clear(NV2AMetalPGRAPHSurfaces *s)
{
    NSError *error = nil;
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = s.color.transfer.texture;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1);
    if (s.zeta) {
        p.depthAttachment.texture = s.zeta.transfer.texture;
        p.depthAttachment.loadAction = MTLLoadActionClear;
        p.depthAttachment.storeAction = MTLStoreActionStore;
        p.depthAttachment.clearDepth = 1;
    }
    id<MTL4RenderCommandEncoder> e =
        [s.cache.commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([s markColorWritten:YES zetaWritten:s.zeta != nil error:&error],
            error);
}
static void replacement_bindings(NV2AMetalPGRAPHSurfaces *surfaces)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    SurfaceShape original = pg->surface_shape;
    unsigned pitch = pg->surface_zeta.pitch;
    for (unsigned captured = 0; captured < 2; captured++) {
        require([surfaces prepareColor:YES zeta:YES error:&error], error);
        clear(surfaces);
        require([surfaces.cache submitWithError:&error], error);
        require([surfaces.cache waitUntilIdleWithError:&error], error);
        NV2AMetalCachedSurface *color = surfaces.color;
        NV2AMetalCachedSurface *zeta = surfaces.zeta;
        pg->surface_shape.zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
        pg->surface_zeta.pitch = 40;
        if (captured) {
            NV2AMetalSurfaceBindings bindings = [surfaces captureBindings];
            bindings.zeta.config.format = NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
            bindings.zeta.config.pitch = 40;
            require([surfaces prepareBindings:bindings error:&error], error);
        } else {
            require([surfaces prepareColor:YES zeta:YES error:&error], error);
        }
        assert(surfaces.color == color && color.valid && !zeta.valid);
        clear(surfaces);
        NSUInteger zetaAddress = surfaces.zeta.address;
        require([surfaces flushWithError:&error], error);
        assert((uint32_t)ldl_le_p(state->vram_ptr + color.address) ==
               0xffff00ff);
        assert(((uint32_t)ldl_le_p(state->vram_ptr + zetaAddress) >> 8) ==
               0xffffff);
        pg->surface_shape = original;
        pg->surface_zeta.pitch = pitch;
    }
    checks++;
}
static void clear_register_tests(NV2AMetalPGRAPHSurfaces *surfaces)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    SurfaceShape original = pg->surface_shape;
    pg->surface_shape.anti_aliasing =
        NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_CENTER_1;
    pg->surface_shape.clip_x = pg->surface_shape.clip_y = 0;
    pg->surface_shape.clip_width = 8;
    pg->surface_shape.clip_height = 4;
    pg->surface_scale_factor = 2;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = 2 | 4 << 16;
    pg->regs_[NV_PGRAPH_CLEARRECTY] = 1 | 2 << 16;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0x6612ab34;
    /* CONTROL write masks and tests must not suppress clear writes. */
    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
    pg->regs_[NV_PGRAPH_CONTROL_1] = 0;
    require([surfaces clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error],
            error);
    assert(!pg->clearing && surfaces.color.dirty);
    id<MTLBuffer> result = [surfaces.cache.commands.device
        newBufferWithLength:surfaces.color.transfer.sourceLength
                    options:MTLResourceStorageModeShared];
    require([surfaces.color.transfer
                encodeDownloadToBuffer:result
                                offset:0
                               swizzle:NO
                                  flip:NO
                             downscale:YES
                              commands:surfaces.cache.commands
                                 error:&error],
            error);
    require([surfaces.cache submitWithError:&error], error);
    require([surfaces.cache waitUntilIdleWithError:&error], error);
    const unsigned char *raw = result.contents;
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint32_t word;
            memcpy(&word, raw + y * 40 + x * 4, 4);
            if (x >= 2 && x <= 4 && y >= 1 && y <= 2)
                assert(word == 0x6612ab34);
        }
    require([surfaces clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error],
            error);
    /* Subsequent no-op/stencil clears leave the source color untouched. */
    [surfaces.cache cancel];
    uint64_t generation = surfaces.color.generation;
    require([surfaces clearSurface:0 error:&error], error);
    assert(surfaces.color.generation == generation);
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_DITHERENABLE;
    require([surfaces clearSurface:NV097_CLEAR_SURFACE_R error:&error], error);
    [surfaces.cache cancel];
    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = 4 | 2 << 16;
    assert(![surfaces clearSurface:NV097_CLEAR_SURFACE_R error:&error]);
    pg->regs_[NV_PGRAPH_CLEARRECTX] = 0 | 7 << 16;
    pg->regs_[NV_PGRAPH_CLEARRECTY] = 0 | 3 << 16;
    pg->surface_shape.zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
    pg->surface_zeta.pitch = 40;
    pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 0x1234565a;
    expected_zeta_byte = 0x5a;
    require([surfaces
                clearSurface:NV097_CLEAR_SURFACE_Z | NV097_CLEAR_SURFACE_STENCIL
                       error:&error],
            error);
    id<MTLBuffer> z = [surfaces.cache.commands.device
        newBufferWithLength:surfaces.zeta.transfer.sourceLength
                    options:MTLResourceStorageModeShared];
    require([surfaces.zeta.transfer
                encodeDownloadToBuffer:z
                                offset:0
                               swizzle:NO
                                  flip:NO
                             downscale:YES
                              commands:surfaces.cache.commands
                                 error:&error],
            error);
    require([surfaces.cache submitWithError:&error], error);
    require([surfaces.cache waitUntilIdleWithError:&error], error);
    raw = z.contents;
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint32_t word;
            memcpy(&word, raw + y * 40 + x * 4, 4);
            assert(word == 0x1234565a);
        }
    require([surfaces flushWithError:&error], error);
    uint32_t setup = pg->regs_[NV_PGRAPH_SETUPRASTER];
    pg->regs_[NV_PGRAPH_SETUPRASTER] |= NV_PGRAPH_SETUPRASTER_Z_FORMAT;
    pg->surface_shape.zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z16;
    const uint16_t codes[] = { 0,      0x000f, 0x0fff, 0x1000,
                               0x7fff, 0x8007, 0xfffe, 0xffff };
    for (unsigned i = 0; i < ARRAY_SIZE(codes); i++) {
        pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = codes[i];
        expected_zeta_byte = codes[i] & 255;
        require([surfaces clearSurface:NV097_CLEAR_SURFACE_Z error:&error],
                error);
        id<MTLBuffer> f16 = [surfaces.cache.commands.device
            newBufferWithLength:surfaces.zeta.transfer.sourceLength
                        options:MTLResourceStorageModeShared];
        require([surfaces.zeta.transfer
                    encodeDownloadToBuffer:f16
                                    offset:0
                                   swizzle:NO
                                      flip:NO
                                 downscale:YES
                                  commands:surfaces.cache.commands
                                     error:&error],
                error);
        require([surfaces.cache submitWithError:&error], error);
        require([surfaces.cache waitUntilIdleWithError:&error], error);
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 8; x++) {
                uint16_t word;
                memcpy(&word, (const uint8_t *)f16.contents + y * 40 + x * 2,
                       2);
                assert(word == codes[i]);
            }
        require([surfaces flushWithError:&error], error);
    }
    printf("Metal4 F16 raw clears: 8 PGRAPH cases/256 pixels PASS\n");
    pg->surface_shape.zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
    const uint32_t f24_codes[] = { 0,        0x2f,     0xffff,   0x10000,
                                   0x7f8017, 0xfeffff, 0xff0000, 0xffffff };
    for (unsigned i = 0; i < ARRAY_SIZE(f24_codes); i++) {
        uint32_t packed = f24_codes[i] << 8 | ((i * 37 + 19) & 255);
        pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = packed;
        expected_zeta_byte = packed & 255;
        require([surfaces clearSurface:NV097_CLEAR_SURFACE_Z |
                                       NV097_CLEAR_SURFACE_STENCIL
                                 error:&error],
                error);
        id<MTLBuffer> f24 = [surfaces.cache.commands.device
            newBufferWithLength:surfaces.zeta.transfer.sourceLength
                        options:MTLResourceStorageModeShared];
        require([surfaces.zeta.transfer
                    encodeDownloadToBuffer:f24
                                    offset:0
                                   swizzle:NO
                                      flip:NO
                                 downscale:YES
                                  commands:surfaces.cache.commands
                                     error:&error],
                error);
        require([surfaces.cache submitWithError:&error], error);
        require([surfaces.cache waitUntilIdleWithError:&error], error);
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 8; x++) {
                uint32_t word;
                memcpy(&word, (const uint8_t *)f24.contents + y * 40 + x * 4,
                       4);
                assert(word == packed);
            }
        require([surfaces flushWithError:&error], error);
    }
    pg->regs_[NV_PGRAPH_SETUPRASTER] = setup;
    printf(
        "Metal4 F24 raw clears: 8 PGRAPH cases/256 depth/stencil words PASS\n");
    /* Restore the original register capture for the lifecycle checks. */
    pg->surface_shape = original;
    pg->surface_zeta.pitch = 24;
    checks++;
}

static QemuMutex test_bql;
static __thread bool test_bql_held;
bool bql_locked(void)
{
    return test_bql_held;
}
bool mutex_is_bql(QemuMutex *mutex)
{
    return mutex == &test_bql;
}
void bql_update_status(bool locked)
{
    (void)locked;
}
void bql_lock_impl(const char *file, int line)
{
    (void)file;
    (void)line;
    assert(!test_bql_held);
    qemu_mutex_lock(&test_bql);
    test_bql_held = true;
}
void bql_unlock(void)
{
    assert(test_bql_held);
    test_bql_held = false;
    qemu_mutex_unlock(&test_bql);
}
static void *cpu_write(void *opaque)
{
    (void)opaque;
    @autoreleasepool {
        bql_lock();
        hook->func(hook->opaque, hook->mr, 577, 1, true);
        assert(bql_locked());
        assert(state->vram_ptr[576] == 255 && state->vram_ptr[577] == 0);
        state->vram_ptr[577] = 0x55;
        bql_unlock();
    }
    return NULL;
}
static void *crossing_cpu_read(void *opaque)
{
    (void)opaque;
    @autoreleasepool {
        hook->func(hook->opaque, hook->mr, 65535, 8, false);
    }
    return NULL;
}

int main(void)
{
    @autoreleasepool {
        state = g_new0(NV2AState, 1);
        state->vram = g_new0(MemoryRegion, 1);
        assert(
            !posix_memalign((void **)&state->vram_ptr, getpagesize(), 65536));
        memset(state->vram_ptr, 0x31, 65536);
        qemu_mutex_init(&state->pgraph.lock);
        qemu_mutex_init(&state->pfifo.lock);
        qemu_mutex_init(&test_bql);
        qemu_event_init(&kicked, false);
        PGRAPHState *pg = &state->pgraph;
        pg->surface_scale_factor = 2;
        pg->surface_type = NV097_SET_SURFACE_FORMAT_TYPE_PITCH;
        pg->surface_shape = (SurfaceShape){
            .color_format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            .zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
            .clip_x = 2,
            .clip_y = 1,
            .clip_width = 3,
            .clip_height = 2,
            .anti_aliasing =
                NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_CENTER_CORNER_2
        };
        pg->surface_color.offset = 64;
        pg->surface_color.pitch = 40;
        pg->surface_zeta.offset = 64;
        pg->surface_zeta.pitch = 24;
        pg->dma_color = 1;
        pg->dma_zeta = 2;
        color_dma = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                                 .address = 512,
                                 .limit = 1023 };
        zeta_dma = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                                .address = 4096,
                                .limit = 1023 };
        NSError *error = nil;
        NV2AMetalPGRAPHSurfaces *surfaces =
            [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state error:&error];
        require(surfaces != nil, error);
        assert(!hook && surfaces.cache.vram.contents == state->vram_ptr);
        qemu_mutex_lock(&pg->lock);
        require([surfaces prepareColor:YES zeta:YES error:&error], error);
        assert(registered_hooks->len == 1 && hook->addr == 0 &&
               hook->len == 8192);
        assert(surfaces.color.address == 576 && surfaces.zeta.address == 4160);
        assert(surfaces.color.transfer.config.width == 8 &&
               surfaces.color.transfer.config.height == 3);
        assert(surfaces.color.transfer.texture.width == 16 &&
               surfaces.zeta.transfer.texture.height == 6);
        assert(pg->surface_binding_dim.width == 8 &&
               pg->surface_binding_dim.clip_x == 2);
        clear(surfaces);
        NV2AMetalSurfaceRecording *recording = surfaces.cache.recording;
        /* No enabled/current or cached write mask: no release. Cached masks
         * must still release old writes even when both requested masks are off.
         */
        require([surfaces releaseColor:YES zeta:YES error:&error], error);
        assert(pg->surface_color.draw_dirty && pg->surface_zeta.draw_dirty);
        pg->surface_color.write_enabled_cache = true;
        require([surfaces releaseColor:NO zeta:NO error:&error], error);
        assert(!pg->surface_color.draw_dirty && pg->surface_zeta.draw_dirty &&
               !pg->surface_color.write_enabled_cache);
        pg->surface_zeta.write_enabled_cache = true;
        require([surfaces releaseColor:NO zeta:NO error:&error], error);
        assert(!pg->surface_zeta.draw_dirty &&
               !pg->surface_zeta.write_enabled_cache);
        assert(surfaces.cache.recording == recording && !recording.submitted &&
               surfaces.color.dirty && surfaces.zeta.dirty &&
               state->vram_ptr[576] == 0x31 && state->vram_ptr[4160] == 0x31 &&
               !vga_dirty && !texture_dirty);
        puts("TCG release: GPU recording/dirty attachments retained; no RAM "
             "download, CPU callback still required PASS");
        qemu_mutex_unlock(&pg->lock);
        checks++;
        QemuThread worker;
        qemu_thread_create(&worker, "metal-vram-test", cpu_write, NULL,
                           QEMU_THREAD_JOINABLE);
        qemu_event_wait(&kicked);
        /* Model a FIFO notification needing BQL before the RAM request. */
        bql_lock();
        qemu_mutex_lock(&state->pfifo.lock);
        require([surfaces processPendingWithError:&error], error);
        qemu_mutex_unlock(&state->pfifo.lock);
        bql_unlock();
        qemu_thread_join(&worker);
        assert(vga_dirty == 1 && texture_dirty == 1 &&
               surfaces.color.needsUpload);
        assert(state->vram_ptr[576] == 255 && state->vram_ptr[577] == 0x55);
        checks++;
        assert(!pg->surface_color.draw_dirty && pg->surface_zeta.draw_dirty);
        qemu_event_reset(&kicked);
        unsigned before_kicks = pfifo_kicks;
        crossing_cpu_read(NULL);
        /* An idle, nonoverlapping RAM read needs no PGRAPH worker. */
        assert(pfifo_kicks == before_kicks);
        assert([surfaces requestCPUAccessAtAddress:65536
                                            length:0
                                             write:NO
                                             error:&error]);
        assert(![surfaces requestCPUAccessAtAddress:NSUIntegerMax
                                             length:1
                                              write:YES
                                              error:&error]);
        checks++;
        qemu_mutex_lock(&pg->lock);
        require([surfaces prepareColor:YES zeta:NO error:&error], error);
        id<MTLBuffer> result = [surfaces.cache.commands.device
            newBufferWithLength:surfaces.color.transfer.sourceLength
                        options:MTLResourceStorageModeShared];
        require([surfaces.color.transfer
                    encodeDownloadToBuffer:result
                                    offset:0
                                   swizzle:NO
                                      flip:NO
                                 downscale:YES
                                  commands:surfaces.cache.commands
                                     error:&error],
                error);
        require([surfaces.cache submitWithError:&error], error);
        require([surfaces.cache waitUntilIdleWithError:&error], error);
        assert(((unsigned char *)result.contents)[1] == 0x55);
        checks++;
        color_dma.limit = 100;
        assert(![surfaces prepareColor:YES zeta:NO error:&error]);
        color_dma.limit = 1023;
        color_dma.dma_class = 0;
        assert(![surfaces prepareColor:YES zeta:NO error:&error]);
        color_dma.dma_class = NV_DMA_IN_MEMORY_CLASS;
        color_dma.address = 65520;
        assert(![surfaces prepareColor:YES zeta:NO error:&error]);
        color_dma.address = 512;
        pg->surface_shape.anti_aliasing = 3;
        assert(![surfaces prepareColor:YES zeta:NO error:&error]);
        pg->surface_shape.anti_aliasing =
            NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_CENTER_CORNER_2;
        NV2AMetalCachedSurface *old = surfaces.color;
        pg->frame_time = 5;
        require([surfaces prepareColor:YES zeta:NO error:&error], error);
        assert(!old.valid && surfaces.color.valid && vga_dirty == 2);
        checks++;
        clear(surfaces);
        require([surfaces flushWithError:&error], error);
        assert(pg->surface_color.buffer_dirty &&
               !pg->surface_color.draw_dirty && !surfaces.cache.count);
        tcg_allowed = false;
        pg->surface_shape.anti_aliasing =
            NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4;
        require([surfaces prepareColor:YES zeta:YES error:&error], error);
        assert(surfaces.color.transfer.config.width == 8 &&
               surfaces.color.transfer.config.height == 5);
        assert(surfaces.zeta.transfer.texture.height == 10);
        tcg_allowed = true;
        clear(surfaces);
        assert(surfaces.color.dirty && surfaces.zeta.dirty);
        tcg_allowed = false;
        pg->surface_color.write_enabled_cache = true;
        pg->surface_zeta.write_enabled_cache = true;
        require([surfaces releaseColor:NO zeta:NO error:&error], error);
        assert(!surfaces.color.dirty && !surfaces.zeta.dirty);
        puts("Unmonitored CPU release: synchronous color/depth download PASS");
        tcg_allowed = true;
        require([surfaces flushWithError:&error], error);
        replacement_bindings(surfaces);
        clear_register_tests(surfaces);
        require([surfaces.cache prepareGPUReadAtAddress:32768
                                                 length:16
                                                  error:&error],
                error);
        assert(registered_hooks->len == 2);
        uint64_t version;
        require([surfaces.cache sourceVersionAtAddress:8192
                                                length:24576
                                               version:&version
                                                 error:&error],
                error);
        assert(registered_hooks->len == 1 && hook->addr == 0 &&
               hook->len == 36864);
        [surfaces.cache cancel];
        uint64_t oldVersion = version;
        NSObject *metadata = [surfaces.cache valueForKey:@"stateLock"];
        dispatch_semaphore_t held = dispatch_semaphore_create(0);
        dispatch_semaphore_t release = dispatch_semaphore_create(0);
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        dispatch_group_t workers = dispatch_group_create();
        dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
          @synchronized(metadata) {
              dispatch_semaphore_signal(held);
              dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
          }
        });
        assert(!dispatch_semaphore_wait(
            held, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
        dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
          for (unsigned i = 0; i < 10000; i++) {
              hook->func(hook->opaque, hook->mr, 8192, 4, true);
              stl_le_p(state->vram_ptr + 8192, i);
          }
          dispatch_semaphore_signal(finished);
        });
        long blocked = dispatch_semaphore_wait(
            finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        dispatch_semaphore_signal(release);
        dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
        assert(!blocked && ldl_le_p(state->vram_ptr + 8192) == 9999);
        require([surfaces.cache sourceVersionAtAddress:8192
                                                length:4
                                               version:&version
                                                 error:&error],
                error);
        assert(version > oldVersion);
        printf("Installed callback:10000 source writes with cache metadata "
               "held PASS\n");
        printf("Dynamic CPU hooks: initially absent, GPU sources/targets "
               "protected, adjacent ranges merged PASS\n");
        require([surfaces closeWithError:&error], error);
        require([surfaces closeWithError:&error], error);
        assert(!hook);
        qemu_mutex_unlock(&pg->lock);
        assert(![surfaces requestCPUAccessAtAddress:0
                                             length:1
                                              write:YES
                                              error:&error]);
        surfaces = nil;
        qemu_event_destroy(&kicked);
        qemu_mutex_destroy(&pg->lock);
        qemu_mutex_destroy(&state->pfifo.lock);
        qemu_mutex_destroy(&test_bql);
        free(state->vram_ptr);
        g_free(state->vram);
        g_free(state);
        printf("Metal 4 PGRAPH surface adapter: %u boundary groups PASS\n",
               checks);
    }
    return 0;
}
