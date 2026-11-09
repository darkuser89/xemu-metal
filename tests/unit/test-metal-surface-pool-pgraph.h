/* Productive Draw/Clear/RTT/Scanout borrowing versus disabled surface pooling.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SURFACE_POOL_PGRAPH_H
#define TEST_METAL_SURFACE_POOL_PGRAPH_H
#include "test-metal-surface-pool.h"
#import "hw/xbox/nv2a/pgraph/metal/scanout-pgraph.h"
#include "hw/display/vga_int.h"
static _Thread_local unsigned spg_phase, spg_public, spg_borrows[5];
static _Thread_local BOOL spg_fail_emit;
static _Thread_local uint64_t spg_cycle_ids[2][2], spg_scanout_ids[2][2];
static id (*spg_public_original)(id, SEL);
static id spg_texture(id transfer, SEL selector)
{
    if (spg_phase)
        spg_public++;
    return spg_public_original(transfer, selector);
}
static id (*spg_borrow_original)(id, SEL, id, NSError **);
static id spg_borrow(id transfer, SEL selector, id commands, NSError **error)
{
    id texture = spg_borrow_original(transfer, selector, commands, error);
    if (spg_phase && texture)
        spg_borrows[spg_phase]++;
    return texture;
}
static BOOL (*spg_emit_original)(id, SEL, id, id, NSError **);
static BOOL spg_emit(id packet, SEL selector, id encoder, id commands,
                     NSError **error)
{
    if (spg_phase == 1 && spg_fail_emit) {
        spg_fail_emit = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.surface-pool.late-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return spg_emit_original(packet, selector, encoder, commands, error);
}
static void spg_begin(unsigned phase)
{
    spg_phase = phase;
    sp_width = sp_height = 8;
    sp_format = MTLPixelFormatBGRA8Unorm;
    sp_allocating = YES;
}
static void spg_end(void)
{
    spg_phase = 0;
    sp_allocating = NO;
}
static NV2AMetalSurfaceTexturePool *spg_pool(BOOL reference)
{
    NV2AMetalSurfaceTexturePool *pool = [[NV2AMetalSurfaceTexturePool alloc]
        initWithDevice:surfaces.cache.commands.device
          maximumBytes:reference ? 0 : 8 * 1024 * 1024
          maximumCount:8];
    assert(pool);
    [surfaces.cache setValue:pool forKey:@"texturePool"];
    return pool;
}
static uint32_t spg_report(NSError **error)
{
    require([draw.reports getReport:1u << 24 error:error] &&
                [draw.reports processWithError:error],
            *error);
    uint32_t query = report_value(0);
    assert(query);
    return query;
}
static NSData *spg_cycles(BOOL reference, BOOL lateFailure)
{
    cpp_scene(NO, 0);
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceTexturePool *pool = spg_pool(reference);
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:NULL];
    assert(probe);
    NSError *error = nil;
    NSMutableData *result = [NSMutableData new];
    sp_allocations = 0;
    for (unsigned pass = 0; pass < 2; pass++) {
        __weak NV2AMetalSurfaceTransfer *weakTransfer;
        @autoreleasepool {
            uint32_t background =
                pass ? UINT32_C(0xffffff00) : UINT32_C(0xff0000ff);
            cpu_write(1024, 256);
            for (unsigned i = 0; i < 64; i++)
                memcpy(state->vram_ptr + 1024 + i * 4, &background, 4);
            cpu_write(4096, 256);
            memset(state->vram_ptr + 4096, 0xff, 256);
            const float foreground[4] = { 0, pass ? 0 : 1, pass ? 1 : 0, 1 };
            cpu_write(16640, 48);
            for (unsigned i = 0; i < 3; i++)
                memcpy(state->vram_ptr + 16640 + i * 16, foreground, 16);
            qemu_mutex_lock(&pg->lock);
            pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = UINT32_C(0xff000000);
            /* A partial clear must preserve the newly uploaded background. */
            pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
                0;
            spg_begin(2);
            require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error],
                    error);
            spg_end();
            int before = pg->draw_time;
            spg_begin(1);
            if (lateFailure && pass == 1) {
                spg_fail_emit = YES;
                assert(
                    ![draw drawWithError:&error] && !spg_fail_emit && error &&
                    [error.domain isEqual:@"test.surface-pool.late-raster"] &&
                    pg->draw_time == before);
                error = nil;
            }
            require([draw drawWithError:&error], error);
            spg_end();
            weakTransfer = surfaces.color.transfer;
            uint64_t identity =
                sp_identity(surfaces.color.transfer, probe, NULL);
            spg_cycle_ids[reference][pass] = identity;
            require([surfaces.cache submitWithError:&error] &&
                        [surfaces.cache waitUntilIdleWithError:&error],
                    error);
            assert(
                !memcmp(pg->vertex_attributes[3].inline_value, foreground, 16));
            qemu_mutex_unlock(&pg->lock);
            read_vram(1024, 256);
            read_vram(4096, 256);
            color(1, 1, pass ? UINT32_C(0xff0000ff) : UINT32_C(0xff00ff00));
            color(7, 7, background);
            qemu_mutex_lock(&pg->lock);
            [result appendData:cpp_capture(spg_report(&error))];
            require([surfaces flushWithError:&error], error);
            qemu_mutex_unlock(&pg->lock);
        }
        assert(!weakTransfer);
    }
    assert(pool && sp_allocations == (reference ? 2 : 1));
    return result;
}
static void spg_resolution(VGACommonState *vga, int *width, int *height)
{
    assert(vga == &state->vga);
    *width = *height = 8;
}
static void spg_params(VGACommonState *vga, VGADisplayParams *params)
{
    assert(vga == &state->vga);
    *params = (VGADisplayParams){ .line_offset = 32,
                                  .hpel = 8,
                                  .line_compare = UINT32_MAX };
}
static NSData *spg_rtt_scanout(BOOL reference)
{
    cpp_scene(YES, 0);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalSurfaceTexturePool *pool = spg_pool(reference);
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:cache.commands.device
                                            error:&error];
    require(probe != nil, error);
    cpu_write(32768, 256);
    uint32_t red = UINT32_C(0xffff0000);
    for (unsigned i = 0; i < 64; i++)
        memcpy(state->vram_ptr + 32768 + i * 4, &red, 4);
    qemu_mutex_lock(&pg->lock);
    dma[0].limit = 65535 - 1024;
    pg->surface_color.offset = 32768 - 1024;
    pg->surface_color.buffer_dirty = true;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = UINT32_C(0xff00ff00);
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7u
                                                                        << 16;
    spg_begin(2);
    require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error], error);
    spg_end();
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    assert(surfaces.color.dirty);
    pg->surface_color.offset = 0;
    pg->surface_color.buffer_dirty = true;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_T0 << 24 | PS_REGISTER_V0
                                                                      << 16;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                           << 8;
    spg_begin(3);
    require([draw beginWithError:&error], error);
    NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
    NV2AMetalCachedTexture *snapshot = [pixel.textureSnapshot textureAtIndex:0];
    require(snapshot != nil, error);
    spg_end();
    spg_begin(1);
    require([draw endWithError:&error], error);
    spg_end();
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    qemu_mutex_unlock(&pg->lock);
    NSData *immutable = sp_texture_bytes(snapshot.binding.texture, probe);
    const uint32_t *pixels = immutable.bytes;
    assert(immutable.length == 256);
    for (unsigned i = 0; i < 64; i++)
        assert(pixels[i] == UINT32_C(0xff00ff00));
    read_vram(1024, 256);
    read_vram(4096, 256);
    color(1, 1, UINT32_C(0xff00ff00));
    qemu_mutex_lock(&pg->lock);
    NSMutableData *result = [cpp_capture(spg_report(&error)) mutableCopy];
    [result appendData:immutable];
    state->vga.get_resolution = spg_resolution;
    state->vga.get_params = spg_params;
    state->vga.cr[NV_PRMCIO_INTERLACE_MODE] = NV_PRMCIO_INTERLACE_MODE_DISABLED;
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = 0;
    state->pcrtc.start = 1024 - 32;
    NV2AMetalPGRAPHScanout *scanout =
        [[NV2AMetalPGRAPHScanout alloc] initWithState:state
                                                cache:cache
                                                error:&error];
    require(scanout != nil, error);
    id<MTLSharedEvent> gate = [cache.commands.device newSharedEvent];
    require(gate != nil, error);
    [sp_queue(cache.commands) waitForEvent:gate value:1];
    spg_begin(4);
    require([scanout updatePresentationWithError:&error], error);
    spg_end();
    assert(!gate.signaledValue && [scanout valueForKey:@"pendingRecording"]);
    /* A separate queue writes another pooled allocation while scanout remains
     * gated. Its old source must not become the new allocation. */
    uint64_t sourceID = sp_identity(surfaces.color.transfer, probe, NULL);
    spg_scanout_ids[reference][0] = sourceID;
    NV2AMetalSurfaceConfig config = surfaces.color.transfer.config;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *fresh =
            sp_create(cache.commands.device, pool, config, &error);
        require(fresh != nil, error);
        spg_scanout_ids[reference][1] = sp_identity(fresh, probe, NULL);
        (void)sp_roundtrip(fresh, probe, 173);
    }
    assert(!gate.signaledValue);
    gate.signaledValue = 1;
    spg_begin(4);
    require([scanout renderWithError:&error], error);
    spg_end();
    require(scanout.frame != nil, error);
    NSData *frame = sp_texture_bytes(scanout.frame.texture, probe);
    NSData *native = cpp_color_pixels(&error);
    require(native != nil, error);
    assert([frame isEqual:native]);
    [result appendData:frame];
    [scanout invalidate];
    scanout = nil;
    require([surfaces flushWithError:&error], error);
    qemu_mutex_unlock(&pg->lock);
    /* The immutable RTT and presentation copies are independent of any later
     * reuse of their source SurfaceTransfer allocation. */
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *fresh =
            sp_create(cache.commands.device, pool, config, &error);
        require(fresh != nil, error);
        (void)sp_roundtrip(fresh, probe, 227);
    }
    assert(
        [sp_texture_bytes(snapshot.binding.texture, probe) isEqual:immutable]);
    state->vga.get_resolution = NULL;
    state->vga.get_params = NULL;
    return result;
}
static void surface_pool_pgraph_tests(void)
{
    id<MTLDevice> device = surfaces.cache.commands.device;
    Method allocation = class_getInstanceMethod(
        object_getClass(device), @selector(newTextureWithDescriptor:));
    Method replacement = class_getInstanceMethod(
        NSObject.class, @selector(sp_newTextureWithDescriptor:));
    Method getter = class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                            @selector(texture));
    Method borrow = class_getInstanceMethod(
        NV2AMetalSurfaceTransfer.class, @selector(textureForCommands:error:));
    Method emit = class_getInstanceMethod(
        NV2AMetalPixelDraw.class,
        @selector(encodeWithRenderEncoder:commands:error:));
    assert(allocation && replacement && getter && borrow && emit);
    spg_public_original = (void *)method_getImplementation(getter);
    spg_borrow_original = (void *)method_getImplementation(borrow);
    spg_emit_original = (void *)method_getImplementation(emit);
    memset(spg_borrows, 0, sizeof(spg_borrows));
    spg_public = 0;
    method_exchangeImplementations(allocation, replacement);
    method_setImplementation(getter, (IMP)spg_texture);
    method_setImplementation(borrow, (IMP)spg_borrow);
    method_setImplementation(emit, (IMP)spg_emit);
    @try {
        for (unsigned late = 0; late < 2; late++) {
            NSData *actual = spg_cycles(NO, late);
            NSData *reference = spg_cycles(YES, late);
            assert([actual isEqual:reference]);
            assert(spg_cycle_ids[0][0] == spg_cycle_ids[0][1]);
        }
        NSData *actual = spg_rtt_scanout(NO);
        NSData *reference = spg_rtt_scanout(YES);
        assert([actual isEqual:reference]);
        for (unsigned path = 0; path < 2; path++)
            assert(spg_scanout_ids[path][0] != spg_scanout_ids[path][1]);
        assert(!spg_public);
        for (unsigned phase = 1; phase <= 4; phase++)
            assert(spg_borrows[phase]);
    } @finally {
        spg_end();
        spg_fail_emit = NO;
        method_setImplementation(getter, (IMP)spg_public_original);
        method_setImplementation(borrow, (IMP)spg_borrow_original);
        method_setImplementation(emit, (IMP)spg_emit_original);
        method_exchangeImplementations(allocation, replacement);
    }
    groups++;
    puts("Surface pool PGRAPH:3 exact no-pool pairs, real allocation2->1, "
         "fresh RAM/Framebuffer/Zeta/Current/constants/query, late-raster "
         "retry and productive Clear/Draw/RTT/gatedScanout borrows with zero "
         "public escapes PASS");
}
#endif
