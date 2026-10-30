/* Native PGRAPH batch controller with real Metal 4 and QEMU types/helpers.
 * Only VM/RAM/DMA registration is mocked; no app, VM or window is started.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#include "hw/xbox/nv2a/pgraph/psh_regs.h"
#import "hw/xbox/nv2a/pgraph/metal/draw-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/fetch-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"

static NV2AState *state;
static NV2AMetalPGRAPHSurfaces *surfaces;
static NV2AMetalPGRAPHDraw *draw;
static MemAccessCallback *hook;
static CPUState cpu;
static DMAObject dma[5];
static bool texture_dirty[16];
static unsigned groups, draws, rejected, notifications;
static uint32_t reported, report_values[64];
static bool report_seen[64];
static const char *active_case = "setup";
bool tcg_allowed = true;
uint64_t memory_region_size(MemoryRegion *mr)
{
    assert(mr == state->vram);
    return 65536;
}
void *memory_region_get_ram_ptr(MemoryRegion *mr)
{
    assert(mr == state->vram);
    return state->vram_ptr;
}
DMAObject nv_dma_load(NV2AState *d, hwaddr object)
{
    assert(d == state && object >= 16 && object <= 80 && object % 16 == 0);
    return dma[object / 16 - 1];
}
void pgraph_write_zpass_pixel_cnt_report(NV2AState *d, uint32_t parameter,
                                         uint32_t result)
{
    unsigned offset = parameter & NV097_GET_REPORT_OFFSET;
    assert(d == state && (parameter >> 24) == 1 && !(offset % 16) &&
           offset / 16 < 64);
    report_seen[offset / 16] = true;
    report_values[offset / 16] = result;
    reported = result; /* Full RAM layout is tested with real common PGRAPH. */
}
hwaddr nv_clip_gpu_tile_blit(NV2AState *d, hwaddr address, hwaddr length)
{
    (void)d;
    (void)address;
    (void)length;
    abort(); /* The renderer integration test exercises the blit boundary. */
}
void *nv_dma_map(NV2AState *d, hwaddr object, hwaddr *length)
{
    (void)d;
    (void)object;
    (void)length;
    abort(); /* Native paths must use validated DMA spans. */
}
bool memory_region_test_and_clear_dirty(MemoryRegion *mr, hwaddr address,
                                        hwaddr length, unsigned client)
{
    assert(mr == state->vram && length && address < 65536 &&
           length <= 65536 - address);
    assert(client == DIRTY_MEMORY_NV2A || client == DIRTY_MEMORY_NV2A_TEX);
    if (client == DIRTY_MEMORY_NV2A)
        return false;
    bool dirty = false;
    for (unsigned i = address / 4096; i <= (address + length - 1) / 4096; i++) {
        dirty |= texture_dirty[i];
        texture_dirty[i] = false;
    }
    return dirty;
}
void memory_region_set_client_dirty(MemoryRegion *mr, hwaddr address,
                                    hwaddr length, unsigned client)
{
    assert(mr == state->vram && length && address < 65536 &&
           length <= 65536 - address);
    if (client == DIRTY_MEMORY_VGA) {
        notifications++;
        return;
    }
    assert(client == DIRTY_MEMORY_NV2A_TEX || client == DIRTY_MEMORY_NV2A);
    if (client == DIRTY_MEMORY_NV2A_TEX)
        for (unsigned i = address / 4096; i <= (address + length - 1) / 4096;
             i++)
            texture_dirty[i] = true;
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
static BOOL XF_cache_handle_kick(NV2AState *d);
void pfifo_kick(NV2AState *d)
{
    if (XF_cache_handle_kick(d))
        return;
    (void)d;
    abort(); /* No CPU worker is started in this controller test. */
}
/* Original pgraph.c clear formulas at the mocked VM link boundary. */
void pgraph_get_clear_color(PGRAPHState *pg, float rgba[4])
{
    assert(pg->surface_shape.color_format ==
           NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8);
    uint32_t word = pgraph_reg_r(pg, NV_PGRAPH_COLORCLEARVALUE);
    rgba[0] = ((word >> 16) & 255) / 255.f;
    rgba[1] = ((word >> 8) & 255) / 255.f;
    rgba[2] = (word & 255) / 255.f;
    rgba[3] = (word >> 24) / 255.f;
}
void pgraph_get_clear_depth_stencil_value(PGRAPHState *pg, float *depth,
                                          int *stencil)
{
    uint32_t word = pgraph_reg_r(pg, NV_PGRAPH_ZSTENCILCLEARVALUE);
    assert(!pg->surface_shape.z_format);
    if (pg->surface_shape.zeta_format == NV097_SET_SURFACE_FORMAT_ZETA_Z16) {
        *depth = (word & 65535) / 65535.f;
        *stencil = 0;
    } else {
        *depth = (word >> 8) / 16777215.f;
        *stencil = word & 255;
    }
}
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "PGRAPH draw: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void reg_float(unsigned reg, float value)
{
    memcpy(&state->pgraph.regs_[reg], &value, 4);
}
static void cpu_write(NSUInteger address, NSUInteger length)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:address
                                               length:length
                                                write:YES
                                                error:&error],
            error);
}
static void mov(unsigned slot, unsigned attr, unsigned output, bool final)
{
    uint32_t *t = state->pgraph.program_data[slot];
    t[1] = 1 << 21 | attr << 9 | 27;
    t[2] = 2u << 26;
    t[3] = 1 << 11 | output << 3 | 15 << 12 | final;
}
static void fixture(void)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    [draw invalidateSession];
    require([draw flushWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    qemu_mutex_destroy(&state->pgraph.lock);
    memset(&state->pgraph, 0, sizeof(state->pgraph));
    qemu_mutex_init(&state->pgraph.lock);
    memset(texture_dirty, 0, sizeof(texture_dirty));
    for (unsigned i = 0; i < 5; i++)
        dma[i] = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                              .address = (unsigned[]){ 1024, 4096, 16384, 32768,
                                                       49152 }[i],
                              .limit = 1023 };
    PGRAPHState *pg = &state->pgraph;
    pg->dma_color = 16;
    pg->dma_zeta = 32;
    pg->dma_vertex_a = pg->dma_vertex_b = 48;
    pg->dma_a = 64;
    pg->dma_b = 80;
    pg->surface_color.pitch = 32;
    pg->surface_zeta.pitch = 16;
    pg->surface_shape = (SurfaceShape){
        .color_format = 8, .zeta_format = 1, .clip_width = 8, .clip_height = 8
    };
    pg->surface_scale_factor = 1;
    pg->primitive_mode = PRIM_TYPE_TRIANGLES;
    pg->material_alpha = 1;
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    pg->regs_[NV_PGRAPH_CONTROL_3] = NV_PGRAPH_CONTROL_3_SHADEMODE;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_V0;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                           << 8;
    reg_float(NV_PGRAPH_ZCLIPMAX, 65535);
    pg->regs_[NV_PGRAPH_WINDOWCLIPX0] = pg->regs_[NV_PGRAPH_WINDOWCLIPY0] =
        7 << 16;
    for (unsigned i = 1; i < 8; i++)
        pg->regs_[NV_PGRAPH_WINDOWCLIPX0 + i * 4] =
            pg->regs_[NV_PGRAPH_WINDOWCLIPY0 + i * 4] = 1;
    for (unsigned i = 0; i < 16; i++)
        pg->vertex_attributes[i].inline_value[3] = 1;
    pg->vertex_attributes[3].inline_value[1] = 1;
    for (unsigned i = 0; i < 4; i++) {
        float one = 1;
        memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0 + i][i], &one, 4);
    }
    pg->vertex_attributes[0] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .count = 4,
                           .size = 4,
                           .stride = 16 };
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 3;
    const float positions[][4] = { { 0, 0, 32768, 1 },
                                   { 8, 0, 32768, 1 },
                                   { 0, 8, 32768, 1 } };
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    cpu_write(1024, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
    }
    cpu_write(4096, 256);
    memset(state->vram_ptr + 4096, 255, 256);
}
static void render(void)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    int before = state->pgraph.draw_time;
    require([draw drawWithError:&error], error);
    assert(state->pgraph.draw_time == before + 1 &&
           !surfaces.cache.commands.commandBuffer);
    qemu_mutex_unlock(&state->pgraph.lock);
    draws++;
}
static void read_vram(NSUInteger address, NSUInteger length)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([surfaces.cache prepareCPUAccessAtAddress:address
                                               length:length
                                                write:NO
                                                error:&error],
            error);
    qemu_mutex_unlock(&state->pgraph.lock);
}
static void color(unsigned x, unsigned y, uint32_t expected)
{
    uint32_t actual;
    memcpy(&actual, state->vram_ptr + 1024 + y * 32 + x * 4, 4);
    if (actual != expected) {
        fprintf(stderr, "PGRAPH %s pixel%u,%u: %08x expected%08x\n",
                active_case, x, y, actual,
                expected);
        abort();
    }
}
static void input_paths(void)
{
    for (unsigned path = 0; path < 4; path++)
        for (unsigned programmed = 0; programmed < 2; programmed++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            if (programmed) {
                pg->regs_[NV_PGRAPH_CSV0_D] =
                    2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                mov(0, 0, 0, false);
                mov(1, 3, 3, true);
            }
            if (path) {
                pg->draw_arrays_length = 0;
                if (path == 1) {
                    pg->inline_elements_length = 3;
                    pg->inline_elements[0] = 2;
                    pg->inline_elements[1] = 0;
                    pg->inline_elements[2] = 1;
                } else if (path == 2) {
                    pg->inline_array_length = 12;
                    memcpy(pg->inline_array, state->vram_ptr + 16384, 48);
                } else {
                    pg->inline_buffer_length = 3;
                    pg->vertex_attributes[0].inline_buffer =
                        (float *)(state->vram_ptr + 16384);
                    pg->vertex_attributes[0].inline_buffer_populated = true;
                }
            }
            render();
            assert(surfaces.color.dirty && pg->surface_color.draw_dirty);
            assert(pg->draw_arrays_length || pg->inline_elements_length ||
                   pg->inline_array_length || pg->inline_buffer_length);
            read_vram(1024, 256);
            color(1, 1, 0xff00ff00);
            color(7, 7, 0xffff0000);
        }
    groups++;
}
static void inline_retry(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->draw_arrays_length = 0;
    pg->inline_buffer_length = 3;
    pg->vertex_attributes[0].inline_buffer = (float *)(state->vram_ptr + 16384);
    pg->vertex_attributes[0].inline_buffer_populated = true;
    pg->vertex_attributes[0].inline_value[0] = 42;
    pg->compressed_attrs = 4;
    pg->regs_[NV_PGRAPH_CSV0_D] =
        2u << 30 |
        NV_PGRAPH_CSV0_D_RANGE_MODE; /* No FINAL: capture must fail. */
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    assert(![draw drawWithError:&error]);
    assert(pg->vertex_attributes[0].inline_buffer_populated &&
           pg->vertex_attributes[0].inline_value[0] == 42 &&
           pg->compressed_attrs == 4 && !pg->surface_color.draw_dirty);
    qemu_mutex_unlock(&pg->lock);
    rejected++;
    mov(0, 0, 0, false);
    mov(1, 3, 3, true);
    render();
    assert(!pg->vertex_attributes[0].inline_buffer_populated &&
           pg->vertex_attributes[0].inline_value[1] == 8 &&
           pg->compressed_attrs == 0);
    read_vram(1024, 256);
    color(1, 1, 0xff00ff00);
    groups++;
}
static void independent_ranges(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    const float positions[][4] = { { 0, 0, 32768, 1 }, { 4, 0, 32768, 1 },
                                   { 0, 4, 32768, 1 }, { 4, 4, 32768, 1 },
                                   { 8, 4, 32768, 1 }, { 4, 8, 32768, 1 } };
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    pg->primitive_mode = PRIM_TYPE_TRIANGLE_STRIP;
    pg->draw_arrays_length = 2;
    pg->draw_arrays_start[1] = 3;
    pg->draw_arrays_count[1] = 3;
    render();
    read_vram(1024, 256);
    color(1, 1, 0xff00ff00);
    color(5, 5, 0xff00ff00);
    color(4, 1, 0xffff0000);
    groups++;
}
static void all_primitives_and_formats(void)
{
    for (unsigned primitive = PRIM_TYPE_POINTS; primitive <= PRIM_TYPE_POLYGON;
         primitive++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->primitive_mode = primitive;
        float positions[4][4] = { { .5f, .5f, 32768, 1 },
                                  { 7.5f, .5f, 32768, 1 },
                                  { 7.5f, 7.5f, 32768, 1 },
                                  { .5f, 7.5f, 32768, 1 } };
        if (primitive == PRIM_TYPE_TRIANGLE_STRIP ||
            primitive == PRIM_TYPE_QUAD_STRIP) {
            positions[2][0] = .5f;
            positions[3][0] = 7.5f;
        }
        pg->draw_arrays_count[0] = primitive == PRIM_TYPE_POINTS    ? 1 :
                                   primitive == PRIM_TYPE_LINES     ? 2 :
                                   primitive == PRIM_TYPE_TRIANGLES ? 3 :
                                                                      4;
        cpu_write(16384, sizeof(positions));
        memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
        render();
        read_vram(1024, 256);
        unsigned green = 0;
        for (unsigned i = 0; i < 64; i++) {
            uint32_t word;
            memcpy(&word, state->vram_ptr + 1024 + i * 4, 4);
            assert(word == 0xff00ff00 || word == 0xffff0000);
            green += word == 0xff00ff00;
        }
        assert(green > 0);
    }
    groups++;
    const unsigned formats[] = { 1, 3, 4, 8, 9, 10, 2, 5 };
    const unsigned sizes[] = { 2, 2, 4, 4, 1, 2, 2, 4 };
    const uint32_t red[] = { 0xfc00, 0xf800, 0xffff0000, 0xffff0000,
                             255,    255,    0xfc00,     0xffff0000 };
    const uint32_t green[] = { 0x03e0, 0x07e0, 0x0000ff00, 0xff00ff00,
                               0,      0xff00, 0x83e0,     0xff00ff00 };
    for (unsigned f = 0; f < ARRAY_SIZE(formats); f++) {
        fixture();
        state->pgraph.surface_shape.color_format = formats[f];
        state->pgraph.surface_color.pitch = 8 * sizes[f];
        for (unsigned i = 0; i < 64; i++)
            memcpy(state->vram_ptr + 1024 + i * sizes[f], &red[f], sizes[f]);
        render();
        read_vram(1024, 64 * sizes[f]);
        uint32_t word = 0;
        memcpy(&word, state->vram_ptr + 1024 + 9 * sizes[f], sizes[f]);
        assert(word == green[f]);
        word = 0;
        memcpy(&word, state->vram_ptr + 1024 + 63 * sizes[f], sizes[f]);
        assert(word == red[f]);
    }
    groups++;
}
static void depth_stencil_only(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_ZENABLE |
                                     NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16;
    render();
    assert(!surfaces.color && surfaces.zeta.dirty);
    read_vram(4096, 128);
    uint16_t word;
    memcpy(&word, state->vram_ptr + 4096 + 16 + 2, 2);
    assert(word == 32768);
    memcpy(&word, state->vram_ptr + 4096 + 7 * 16 + 14, 2);
    assert(word == 65535);
    color(1, 1, 0xffff0000);
    fixture();
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE;
    pg->regs_[NV_PGRAPH_CONTROL_1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                     7 << 4 | 0x5a << 8 | 0xff << 16 |
                                     0xffu << 24;
    pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 3 << 8;
    for (unsigned i = 0; i < 64; i++) {
        uint32_t packed = 0xffffff11;
        memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
    }
    render();
    assert(!surfaces.color && surfaces.zeta.dirty);
    read_vram(4096, 256);
    uint32_t packed;
    memcpy(&packed, state->vram_ptr + 4096 + 32 + 4, 4);
    assert(packed == 0xffffff5a);
    memcpy(&packed, state->vram_ptr + 4096 + 7 * 32 + 28, 4);
    assert(packed == 0xffffff11);
    fixture();
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE | 1 << 16;
    render();
    assert(surfaces.color.dirty && !surfaces.zeta.dirty);
    read_vram(1024, 256);
    color(1, 1, 0xff00ff00);
    read_vram(4096, 128);
    for (unsigned i = 0; i < 128; i++)
        assert(state->vram_ptr[4096 + i] == 255);
    groups++;
}
static void polygon_modes(void)
{
    for (unsigned primitive = PRIM_TYPE_TRIANGLES;
         primitive <= PRIM_TYPE_POLYGON; primitive++)
        for (unsigned mode = 0; mode < 3; mode++) {
            if (primitive == PRIM_TYPE_POLYGON && mode == 1)
                continue; /* Original GL does not support this state. */
            fixture();
            PGRAPHState *pg = &state->pgraph;
            pg->primitive_mode = primitive;
            pg->regs_[NV_PGRAPH_SETUPRASTER] = mode | mode << 2;
            float positions[4][4] = { { 1.5f, 1.5f, 32768, 1 },
                                      { 6.5f, 1.5f, 32768, 1 },
                                      { 6.5f, 6.5f, 32768, 1 },
                                      { 1.5f, 6.5f, 32768, 1 } };
            if (primitive == PRIM_TYPE_TRIANGLES) {
                positions[2][0] = 1.5f;
            } else if (primitive == PRIM_TYPE_TRIANGLE_STRIP ||
                       primitive == PRIM_TYPE_QUAD_STRIP) {
                positions[2][0] = 1.5f;
                positions[3][0] = 6.5f;
            }
            pg->draw_arrays_count[0] = primitive == PRIM_TYPE_TRIANGLES ? 3 : 4;
            cpu_write(16384, sizeof(positions));
            memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
            render();
            read_vram(1024, 256);
            unsigned x = 2, y = primitive == PRIM_TYPE_TRIANGLE_FAN ? 4 : 2;
            color(x, y, mode == 0 ? 0xff00ff00 : 0xffff0000);
            if (mode == 1)
                color(1, 1, 0xff00ff00);
            if (mode == 2)
                color(3, 1, 0xff00ff00);
        }
    groups++;
}
static const float face_scene[6][4] = {
    { .5f, .5f, 32768, 1 },   { 3.5f, .5f, 32768, 1 },
    { .5f, 3.5f, 32768, 1 },  { 4.5f, 4.5f, 32768, 1 },
    { 4.5f, 7.5f, 32768, 1 }, { 7.5f, 4.5f, 32768, 1 },
};
static void load_face_scene(void)
{
    cpu_write(16384, sizeof(face_scene));
    memcpy(state->vram_ptr + 16384, face_scene, sizeof(face_scene));
    state->pgraph.draw_arrays_count[0] = 6;
}
static void face_mode_matrix(void)
{
    uint32_t reference[2][3][64];
    for (unsigned side = 0; side < 2; side++)
        for (unsigned mode = 0; mode < 3; mode++) {
            fixture();
            load_face_scene();
            state->pgraph.draw_arrays_start[0] = side * 3;
            state->pgraph.draw_arrays_count[0] = 3;
            state->pgraph.regs_[NV_PGRAPH_SETUPRASTER] = mode | mode << 2;
            render();
            read_vram(1024, 256);
            memcpy(reference[side][mode], state->vram_ptr + 1024, 256);
        }
    for (unsigned guestCCW = 0; guestCCW < 2; guestCCW++)
        for (unsigned front = 0; front < 3; front++)
            for (unsigned back = 0; back < 3; back++)
                for (unsigned cull = 0; cull < 4; cull++) {
                    fixture();
                    load_face_scene();
                    state->pgraph.regs_[NV_PGRAPH_SETUPRASTER] =
                        front | back << 2 |
                        (guestCCW ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0) |
                        (cull ? NV_PGRAPH_SETUPRASTER_CULLENABLE | cull << 21 :
                                0);
                    render();
                    read_vram(1024, 256);
                    for (unsigned p = 0; p < 64; p++) {
                        uint32_t expected = 0xffff0000;
                        for (unsigned side = 0; side < 2; side++) {
                            /* OGL selects CW for the CCW bit after its
                             * clip-Y reversal: side 0 is front for bit 0. */
                            bool facing_front =
                                side == 0 ? !guestCCW : guestCCW;
                            bool culled =
                                cull == 3 || cull == (facing_front ? 1 : 2);
                            unsigned mode = facing_front ? front : back;
                            if (!culled &&
                                reference[side][mode][p] != 0xffff0000)
                                expected = reference[side][mode][p];
                        }
                        uint32_t actual;
                        memcpy(&actual, state->vram_ptr + 1024 + p * 4, 4);
                        if (actual != expected)
                            fprintf(stderr, "Face matrix guestCCW=%u front=%u "
                                    "back=%u cull=%u\n", guestCCW, front, back, cull);
                        color(p % 8, p / 8, expected);
                    }
                }
    groups++;
}
static void ordered_blending(void)
{
    uint32_t images[3][64];
    for (unsigned run = 0; run < 3; run++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        float positions[9][4], colors[9][4] = { 0 };
        for (unsigned p = 0; p < 3; p++) {
            const float base[3][4] = { { 1.5f, 1.5f, 32768, 1 },
                                       { 6.5f, 1.5f, 32768, 1 },
                                       { 1.5f, 6.5f, 32768, 1 } };
            for (unsigned i = 0; i < 3; i++) {
                unsigned index = p == 1 && i != 0 ? 3 - i : i;
                memcpy(positions[p * 3 + i], base[index], 16);
                colors[p * 3 + i][p] = 1;
                colors[p * 3 + i][3] = .5f;
            }
        }
        cpu_write(16384, sizeof(positions));
        memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
        cpu_write(16384 + 256, sizeof(colors));
        memcpy(state->vram_ptr + 16384 + 256, colors, sizeof(colors));
        pg->vertex_attributes[3] = (VertexAttribute){
            .offset = 256,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .size = 4,
            .count = 4,
            .stride = 16,
        };
        pg->regs_[NV_PGRAPH_SETUPRASTER] = 1 | NV_PGRAPH_SETUPRASTER_FRONTFACE;
        pg->regs_[NV_PGRAPH_BLEND] = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
        if (run == 2) {
            pg->draw_arrays_count[0] = 9;
            render();
        } else {
            const unsigned order[2][3] = { { 0, 1, 2 }, { 0, 2, 1 } };
            for (unsigned p = 0; p < 3; p++) {
                pg->draw_arrays_start[0] = order[run][p] * 3;
                render();
            }
        }
        read_vram(1024, 256);
        memcpy(images[run], state->vram_ptr + 1024, 256);
    }
    assert(memcmp(images[0], images[1],
                  256)); /* Fixture detects face reordering. */
    assert(!memcmp(images[0], images[2], 256));
    groups++;
}
static void polygon_family_culling(void)
{
    for (unsigned primitive = PRIM_TYPE_TRIANGLES;
         primitive <= PRIM_TYPE_POLYGON; primitive++) {
        uint32_t reference[2][64];
        for (unsigned run = 0; run < 10; run++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            pg->primitive_mode = primitive;
            float positions[6][4] = {
                { .5f, .5f, 32768, 1 },   { 7.5f, .5f, 32768, 1 },
                { 7.5f, 7.5f, 32768, 1 }, { .5f, 7.5f, 32768, 1 },
                { .5f, 7.5f, 32768, 1 },  { 7.5f, 7.5f, 32768, 1 }
            };
            unsigned count = primitive == PRIM_TYPE_TRIANGLES ? 3 : 4;
            if (primitive == PRIM_TYPE_TRIANGLE_STRIP) {
                positions[2][0] = .5f;
                positions[3][0] = 7.5f;
            } else if (primitive == PRIM_TYPE_QUAD_STRIP) {
                positions[2][0] = .5f;
                positions[2][1] = positions[3][1] = 3.5f;
                positions[3][0] = 7.5f;
                count = 6;
            } else if (primitive == PRIM_TYPE_POLYGON) {
                /* A collinear prefix must not classify the whole polygon as
                 * degenerate or give each boundary edge a different face. */
                const float polygon[5][4] = {
                    { .5f, .5f, 32768, 1 },  { 3.5f, .5f, 32768, 1 },
                    { 7.5f, .5f, 32768, 1 }, { 7.5f, 7.5f, 32768, 1 },
                    { .5f, 7.5f, 32768, 1 },
                };
                memcpy(positions, polygon, sizeof(polygon));
                count = 5;
            }
            cpu_write(16384, sizeof(positions));
            memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
            pg->draw_arrays_count[0] = count;
            unsigned guestCCW = run < 2 ? 0 : (run - 2) / 4;
            unsigned cull = run < 2 ? 0 : (run - 2) % 4;
            pg->regs_[NV_PGRAPH_SETUPRASTER] =
                run < 2 ?
                    run * 2 | run * 2 << 2 :
                    2 << 2 | (guestCCW ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0) |
                        (cull ? NV_PGRAPH_SETUPRASTER_CULLENABLE | cull << 21 :
                                0);
            render();
            read_vram(1024, 256);
            if (run < 2) {
                memcpy(reference[run], state->vram_ptr + 1024, 256);
            } else {
                bool culled = cull == 3 || cull == (guestCCW ? 2 : 1);
                for (unsigned p = 0; p < 64; p++)
                    color(p % 8, p / 8,
                          culled ? 0xffff0000 :
                                   reference[guestCCW ? 1 : 0][p]);
            }
        }
    }
    groups++;
}
static void provoking_and_offsets(void)
{
    for (unsigned first = 0; first < 2; first++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_CONTROL_3] =
            first ? NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX : 0;
        const float colors[3][4] = { { 1, 0, 0, 1 },
                                     { 0, 1, 0, 1 },
                                     { 0, 0, 1, 1 } };
        cpu_write(16384 + 256, sizeof(colors));
        memcpy(state->vram_ptr + 16384 + 256, colors, sizeof(colors));
        pg->vertex_attributes[3] = (VertexAttribute){
            .offset = 256,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .size = 4,
            .count = 4,
            .stride = 16,
        };
        render();
        read_vram(1024, 256);
        color(1, 1, first ? 0xffff0000 : 0xff0000ff);
    }
    groups++;
    for (unsigned offset_mode = 0; offset_mode < 3; offset_mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                          NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                          7 << 16;
        pg->regs_[NV_PGRAPH_SETUPRASTER] =
            1 | 2 << 2 | NV_PGRAPH_SETUPRASTER_FRONTFACE |
            (offset_mode == 0 ? NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE :
             offset_mode == 1 ? NV_PGRAPH_SETUPRASTER_POFFSETPOINTENABLE :
                                NV_PGRAPH_SETUPRASTER_POFFSETLINEENABLE);
        reg_float(NV_PGRAPH_ZOFFSETBIAS, 16);
        float positions[3][4] = { { 1.5f, 1.5f, 32768, 1 },
                                  { 6.5f, 1.5f, 32768, 1 },
                                  { 1.5f, 6.5f, 32768, 1 } };
        cpu_write(16384, sizeof(positions));
        memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
        render(); /* Guest CCW front selects this triangle's back-line mode. */
        read_vram(4096, 128);
        uint16_t word;
        memcpy(&word, state->vram_ptr + 4096 + 16 + 3 * 2, 2);
        assert(word == (offset_mode == 2 ? 32784 : 32768));
    }
    groups++;
}
static void aa_and_scale(void)
{
    for (unsigned aa = 0; aa < 3; aa++)
        for (unsigned scale = 1; scale <= 2; scale++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            unsigned width = aa ? 16 : 8;
            unsigned height = aa == 2 ? 16 : 8;
            pg->surface_shape.anti_aliasing = aa;
            pg->surface_scale_factor = scale;
            pg->surface_color.pitch = width * 4;
            cpu_write(1024, width * height * 4);
            for (unsigned i = 0; i < width * height; i++) {
                uint32_t red = 0xffff0000;
                memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
            }
            render();
            assert(surfaces.color.transfer.texture.width == width * scale &&
                   surfaces.color.transfer.texture.height == height * scale);
            read_vram(1024, width * height * 4);
            uint32_t word;
            memcpy(&word, state->vram_ptr + 1024 + (width + 1) * 4, 4);
            assert(word == 0xff00ff00);
            memcpy(&word, state->vram_ptr + 1024 + (width * height - 1) * 4, 4);
            assert(word == 0xffff0000);
        }
    groups++;
}
static void wide_and_smooth_lines(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->primitive_mode = PRIM_TYPE_LINES;
    pg->surface_scale_factor = 2;
    pg->draw_arrays_count[0] = 2;
    float positions[4][4] = { { 1.5f, 3.5f, 32768, 1 },
                              { 6.5f, 3.5f, 32768, 1 },
                              { 6.5f, 6.5f, 32768, 1 },
                              { 1.5f, 6.5f, 32768, 1 } };
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    pg->regs_[NV_PGRAPH_SETUPRASTER] =
        NV_PGRAPH_SETUPRASTER_CULLENABLE | 3 << 21;
    render();
    read_vram(1024, 256);
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++)
            color(x, y, y == 3 && x >= 1 && x <= 5 ? 0xff00ff00 : 0xffff0000);
    fixture();
    pg->primitive_mode = PRIM_TYPE_LINES;
    pg->draw_arrays_count[0] = 2;
    positions[0][0] = 2.5f;
    positions[0][1] = positions[1][1] = 3.25f;
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE;
    render();
    read_vram(1024, 256);
    color(3, 2, 0x4000ff00);
    color(3, 3, 0xbf00ff00);
    color(2, 2, 0x2000ff00);
    color(2, 3, 0x6000ff00);
    pg->regs_[NV_PGRAPH_ANTIALIASING] = NV_PGRAPH_ANTIALIASING_ENABLE;
    /* Restore the framebuffer through the actual cache, then prove that the
     * GL edge-AA flag disables LINE_SMOOTH's separate alpha coverage. */
    cpu_write(1024, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
    }
    render();
    read_vram(1024, 256);
    color(3, 2, 0xffff0000);
    color(3, 3, 0xff00ff00);
    fixture();
    pg->primitive_mode = PRIM_TYPE_QUADS;
    pg->surface_scale_factor = 2;
    pg->draw_arrays_count[0] = 4;
    positions[0][0] = 1.5f;
    positions[0][1] = positions[1][1] = 1.5f;
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    pg->regs_[NV_PGRAPH_SETUPRASTER] =
        2 | 2 << 2 | NV_PGRAPH_SETUPRASTER_CULLENABLE | 2 << 21;
    render();
    read_vram(1024, 256);
    color(3, 1, 0xff00ff00);
    color(3, 3,
          0xffff0000); /* No triangulation diagonal in polygon-line mode. */
    fixture();
    pg->primitive_mode = PRIM_TYPE_LINES;
    pg->draw_arrays_count[0] = 2;
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE;
    pg->regs_[NV_PGRAPH_CONTROL_1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                     7 << 4 | 0x5a << 8 | 0xff << 16 |
                                     0xffu << 24;
    pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 3 << 8;
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE;
    positions[0][0] = 2.5f;
    positions[0][1] = positions[1][1] = 3.25f;
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    cpu_write(4096, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t packed = 0xffffff11;
        memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
    }
    render();
    assert(!surfaces.color && surfaces.zeta.dirty);
    read_vram(4096, 256);
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint32_t word;
            memcpy(&word, state->vram_ptr + 4096 + y * 32 + x * 4, 4);
            assert(word == ((y == 2 || y == 3) && x >= 2 && x <= 6 ?
                                0xffffff5a :
                                0xffffff11));
        }
    groups++;
}
static void smooth_polygons(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    const float positions[4][4] = { { 1.25f, 1.25f, 32768, 1 },
                                    { 6.25f, 1.25f, 32768, 1 },
                                    { 1.25f, 6.25f, 32768, 1 },
                                    { 6.25f, 6.25f, 32768, 1 } };
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    render();
    read_vram(1024, 256);
    color(2, 1, 0xbf00ff00);
    color(1, 1, 0x8f00ff00);
    color(3, 3, 0xdf00ff00);
    color(4, 3, 0x2000ff00);
    color(4, 4, 0xffff0000);
    pg->regs_[NV_PGRAPH_ANTIALIASING] = NV_PGRAPH_ANTIALIASING_ENABLE;
    cpu_write(1024, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
    }
    render();
    read_vram(1024, 256);
    color(2, 1, 0xff00ff00);
    color(4, 3, 0xffff0000); /* Centre is outside the unsmoothed triangle. */
    pg->regs_[NV_PGRAPH_ANTIALIASING] = 0;
    pg->regs_[NV_PGRAPH_SETUPRASTER] |=
        NV_PGRAPH_SETUPRASTER_CULLENABLE | 1 << 21;
    cpu_write(1024, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
    }
    render();
    read_vram(1024, 256);
    color(2, 1, 0xffff0000);
    fixture();
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE;
    pg->regs_[NV_PGRAPH_CONTROL_1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                     7 << 4 | 0x5a << 8 | 0xff << 16 |
                                     0xffu << 24;
    pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 3 << 8;
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
    cpu_write(4096, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t packed = 0xffffff11;
        memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
    }
    render();
    read_vram(4096, 256);
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint32_t word;
            memcpy(&word, state->vram_ptr + 4096 + y * 32 + x * 4, 4);
            assert(word ==
                   (x >= 1 && y >= 1 && x + y <= 7 ? 0xffffff5a : 0xffffff11));
        }
    fixture();
    pg->primitive_mode = PRIM_TYPE_QUADS;
    pg->draw_arrays_count[0] = 4;
    float quad[4][4];
    memcpy(quad, positions, sizeof(quad));
    memcpy(quad[2], positions[3], 16);
    memcpy(quad[3], positions[2], 16);
    cpu_write(16384, sizeof(quad));
    memcpy(state->vram_ptr + 16384, quad, sizeof(quad));
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    render();
    read_vram(1024, 256);
    uint32_t diagonal;
    memcpy(&diagonal, state->vram_ptr + 1024 + (3 * 8 + 3) * 4, 4);
    /* Two independent GL triangles each cover half the square. Float area
     * and UNORM quantization may choose either adjacent half-alpha byte. */
    assert(diagonal == 0x7f00ff00 || diagonal == 0x8000ff00);
    color(4, 3, 0xff00ff00);
    groups++;
}
static void logic_operations(void)
{
    for (unsigned test = 0; test < 7; test++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_BLEND] = NV_PGRAPH_BLEND_LOGICOP_ENABLE |
                                     NV_PGRAPH_BLEND_EN |
                                     (test == 1 ? 10 :
                                      test >= 2 ? 5 :
                                                  6)
                                         << 12 |
                                     7 | 11 << 4 | 11 << 8;
        if (test == 1)
            pg->regs_[NV_PGRAPH_CONTROL_0] =
                NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE;
        if (test >= 2) {
            pg->surface_shape.zeta_format = 2;
            pg->surface_zeta.pitch = 32;
            pg->regs_[NV_PGRAPH_CONTROL_0] |=
                NV_PGRAPH_CONTROL_0_ZENABLE | NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE | 7 << 16;
            pg->regs_[NV_PGRAPH_CONTROL_1] =
                NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 | 0x5a << 8 |
                0xff << 16 | 0xffu << 24;
            pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 3 << 8;
            cpu_write(4096, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t packed = 0xffffff11;
                memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
            }
            if (test == 6) { /* No color attachment: depth/stencil only. */
                pg->regs_[NV_PGRAPH_CONTROL_0] &=
                    ~(NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                      NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                      NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                      NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE);
            }
            if (test == 3) { /* Depth never: no logic write, stencil Z-fail. */
                pg->regs_[NV_PGRAPH_CONTROL_0] &= ~NV_PGRAPH_CONTROL_0_ZFUNC;
                pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 3 << 4 | 1 << 8;
                pg->regs_[NV_PGRAPH_BLEND] =
                    (pg->regs_[NV_PGRAPH_BLEND] & ~NV_PGRAPH_BLEND_LOGICOP) |
                    6 << 12;
            }
            if (test ==
                4) { /* Shader alpha rejection precedes logic and stencil. */
                pg->regs_[NV_PGRAPH_CONTROL_0] |=
                    NV_PGRAPH_CONTROL_0_ALPHATESTENABLE;
                pg->regs_[NV_PGRAPH_CONTROL_0] &=
                    ~NV_PGRAPH_CONTROL_0_ALPHAFUNC;
                pg->regs_[NV_PGRAPH_BLEND] =
                    (pg->regs_[NV_PGRAPH_BLEND] & ~NV_PGRAPH_BLEND_LOGICOP) |
                    6 << 12;
            }
            if (test ==
                5) { /* Stencil never: stencil fail but no logic/depth write. */
                pg->regs_[NV_PGRAPH_CONTROL_1] &=
                    ~NV_PGRAPH_CONTROL_1_STENCIL_FUNC;
                pg->regs_[NV_PGRAPH_CONTROL_2] = 3 | 1 << 4 | 1 << 8;
                pg->regs_[NV_PGRAPH_BLEND] =
                    (pg->regs_[NV_PGRAPH_BLEND] & ~NV_PGRAPH_BLEND_LOGICOP) |
                    6 << 12;
            }
        }
        render();
        read_vram(1024, 256);
        color(1, 1,
              test == 0 ? 0x00ffff00 :
              test == 1 ? 0xff000000 :
                          0xffff0000);
        color(7, 7, 0xffff0000);
        if (test >= 2) {
            read_vram(4096, 256);
            uint32_t word;
            memcpy(&word, state->vram_ptr + 4096 + 32 + 4, 4);
            assert(word == ((test == 2 || test == 6) ? 0x0080005a :
                            test == 4                ? 0xffffff11 :
                                                       0xffffff5a));
            memcpy(&word, state->vram_ptr + 4096 + 7 * 32 + 7 * 4, 4);
            assert(word == 0xffffff11);
        }
    }
    groups++;
}
static void dither_operations(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    const float source[4] = { .5f, .25f, .75f, .5f };
    memcpy(pg->vertex_attributes[3].inline_value, source, 16);
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_DITHERENABLE;
    render();
    read_vram(1024, 256);
    color(2, 2, 0x808040c0); /* Bayer rank1: higher adjacent values. */
    color(2, 1, 0x7f7f3fbf); /* Bayer rank14: lower adjacent values. */
    pg->regs_[NV_PGRAPH_BLEND] = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
    cpu_write(1024, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
    }
    render();
    read_vram(1024, 256);
    color(2, 2, 0xc0c02060); /* Quantization after SrcAlpha blending. */
    color(2, 1, 0xbfbf1f5f);
    pg->regs_[NV_PGRAPH_BLEND] |= NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12;
    cpu_write(1024, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
    }
    render();
    read_vram(1024, 256);
    color(2, 2, 0x7f7f40c0); /* Dither then XOR; blend suppressed. */
    color(2, 1, 0x80803fbf);
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0x80336699;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    require([surfaces clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error],
            error);
    require([surfaces.cache submitWithError:&error], error);
    require([surfaces.cache waitUntilIdleWithError:&error], error);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++)
            color(x, y, 0x80336699);
    groups++;
}
static void texture_registers(unsigned format, unsigned pitch)
{
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_TEXFMT0] = format << 8 | 2 << 6 |
                                   NV_PGRAPH_TEXFMT0_BORDER_SOURCE | 1 << 16 |
                                   3 << 20 | 3 << 24;
    pg->regs_[NV_PGRAPH_TEXCTL0_0] = NV_PGRAPH_TEXCTL0_0_ENABLE;
    pg->regs_[NV_PGRAPH_TEXCTL1_0] = pitch << 16;
    pg->regs_[NV_PGRAPH_TEXIMAGERECT0] = 8 << 16 | 8;
    pg->regs_[NV_PGRAPH_TEXFILTER0] = 1 << 16 | 1 << 24;
    pg->regs_[NV_PGRAPH_TEXADDRESS0] = 3 | 3 << 8 | 3 << 16;
    pg->regs_[NV_PGRAPH_SHADERPROG] = PS_TEXTUREMODES_PROJECT2D;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_T0;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA)
                                           << 8;
    pg->vertex_attributes[9].inline_value[0] =
        pg->vertex_attributes[9].inline_value[1] = 1.5f;
    pg->texture_dirty[0] = true;
}
static void texture_and_feedback(void)
{
    NSError *error = nil;
    fixture();
    texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
    cpu_write(32768, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t blue = 0xff0000ff;
        memcpy(state->vram_ptr + 32768 + i * 4, &blue, 4);
    }
    render();
    read_vram(1024, 256);
    color(1, 1, 0xff0000ff);
    color(7, 7, 0xffff0000);
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff0000ff;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 1 << 16;
    qemu_mutex_lock(&pg->lock);
    require([surfaces clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error],
            error);
    qemu_mutex_unlock(&pg->lock);
    dma[3].address = 1024;
    texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
    render();
    read_vram(1024, 256);
    color(1, 3, 0xff0000ff);
    color(7, 7, 0xffff0000);
    groups++;
    fixture();
    texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8, 0);
    pg->vertex_attributes[9].inline_value[0] =
        pg->vertex_attributes[9].inline_value[1] = 0;
    pg->regs_[NV_PGRAPH_TEXPALETTE0] =
        NV_PGRAPH_TEXPALETTE0_CONTEXT_DMA | 3 << 2;
    cpu_write(32768, 64);
    memset(state->vram_ptr + 32768, 0, 64);
    cpu_write(49152, 128);
    uint32_t cyan = 0xff00ffff;
    memcpy(state->vram_ptr + 49152, &cyan, 4);
    render();
    read_vram(1024, 256);
    color(1, 1, cyan);
    color(7, 7, 0xffff0000);
    groups++;
}
static void dynamic_program(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
    mov(0, 0, 0, false);
    pg->program_data[0][3] |=
        2; /* Addressing flag, attribute source unchanged. */
    mov(1, 3, 3, true);
    render();
    assert(surfaces.color.dirty);
    read_vram(1024, 256);
    color(1, 1, 0xff00ff00);
    fixture();
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
    mov(0, 0, 0, false);
    pg->program_data[0][1] = 13 << 21 | 27;
    pg->program_data[0][3] = 0; /* ARL A0.x <- v0.x. */
    mov(1, 0, 0, true);
    pg->program_data[1][1] = 1 << 21 | 255 << 13 | 27;
    pg->program_data[1][2] = 3u << 26;
    pg->program_data[1][3] |= 2;
    float x = 1000;
    memcpy(state->vram_ptr + 16384, &x, 4);
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    assert(![draw drawWithError:&error]);
    assert([error.localizedDescription containsString:@"address fault"]);
    assert(!surfaces.color.dirty && pg->draw_time == 0 &&
           !surfaces.cache.commands.commandBuffer);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    color(1, 1, 0xffff0000);
    rejected++;
    fixture();
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
    mov(0, 0, 0, false);
    pg->program_data[0][1] = 13 << 21 | 27;
    pg->program_data[0][3] = 0;
    mov(1, 0, 0, false);
    mov(2, 3, 3, true);
    pg->draw_arrays_length = 2;
    pg->draw_arrays_start[1] = 3;
    pg->draw_arrays_count[1] = 3;
    cpu_write(16384, 96);
    memcpy(state->vram_ptr + 16384 + 48, state->vram_ptr + 16384, 48);
    float invalid = NAN;
    memcpy(state->vram_ptr + 16384 + 48, &invalid, 4);
    qemu_mutex_lock(&pg->lock);
    assert(![draw drawWithError:&error]);
    assert([error.localizedDescription containsString:@"address fault"]);
    assert(!surfaces.color.dirty && pg->draw_time == 0 &&
           !surfaces.cache.commands.commandBuffer);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    color(1, 1,
          0xffff0000); /* First valid range must not reach fragment draw. */
    rejected++;
    groups++;
}
static void failure_and_lifecycle(void)
{
    NSError *error = nil;
    for (unsigned i = 0; i < 7; i++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        switch (i) {
        case 0:
            dma[2].limit = 46;
            break;
        case 1:
            pg->regs_[NV_PGRAPH_CONTROL_0] |=
                NV_PGRAPH_CONTROL_0_ZENABLE | 8 << 16;
            break;
        case 2:
            pg->zpass_pixel_count_enable = true;
            break;
        case 3:
            pg->primitive_mode = PRIM_TYPE_INVALID;
            break;
        case 4:
            dma[0].limit = 254;
            break;
        case 5:
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            break;
        case 6:
            pg->regs_[NV_PGRAPH_SETUPRASTER] = 2 | 2 << 2;
            pg->surface_scale_factor = 0;
            break;
        }
        qemu_mutex_lock(&pg->lock);
        if (i == 2) {
            pg->dma_report = 64;
            require([draw drawWithError:&error], error);
            draws++;
            require([draw.reports getReport:1u << 24 error:&error], error);
            require([draw.reports processWithError:&error], error);
            assert(reported == 28 && pg->draw_time == 1);
            qemu_mutex_unlock(&pg->lock);
            color(1, 1, 0xffff0000); // Counting did not read back color pixels.
            read_vram(1024, 256);
            color(1, 1, 0xff00ff00);
            continue;
        }
        assert(![draw drawWithError:&error] &&
               !surfaces.cache.commands.commandBuffer);
        assert(pg->draw_time == 0 && !surfaces.color.dirty);
        qemu_mutex_unlock(&pg->lock);
        color(1, 1, 0xffff0000);
        rejected++;
    }
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff0000ff;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
    qemu_mutex_lock(&pg->lock);
    require([surfaces clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error],
            error);
    assert(surfaces.cache.commands.commandBuffer && surfaces.color.dirty);
    dma[2].limit = 46;
    assert(![draw drawWithError:&error] &&
           !surfaces.cache.commands.commandBuffer);
    assert(surfaces.color.dirty && pg->surface_color.draw_dirty &&
           pg->draw_time == 0);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    color(1, 1, 0xff0000ff); /* A prior clear survives the failed draw. */
    rejected++;
    fixture();
    state->pgraph.regs_[NV_PGRAPH_CONTROL_0] = 0;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw drawWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    assert(!surfaces.color && state->pgraph.draw_time == 0 &&
           state->pgraph.vertex_attributes[0].inline_value[0] == 0);
    fixture();
    tcg_allowed = false;
    unsigned before = notifications;
    render();
    assert(!surfaces.color.dirty && notifications > before);
    color(1, 1, 0xff00ff00);
    tcg_allowed = true;
    fixture();
    render();
    qemu_mutex_lock(&state->pgraph.lock);
    BOOL bindingDirty = state->pgraph.surface_color.buffer_dirty;
    require([draw flushWithError:&error], error);
    assert(!surfaces.cache.count && !surfaces.color &&
           state->pgraph.surface_color.buffer_dirty == bindingDirty);
    color(1, 1, 0xff00ff00);
    require([draw closeWithError:&error], error);
    require([draw closeWithError:&error], error);
    assert(!hook && ![draw drawWithError:&error] &&
           ![draw flushWithError:&error]);
    qemu_mutex_unlock(&state->pgraph.lock);
    groups++;
}
#include "test-metal-vertex-context.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#include <objc/runtime.h>
static id fail_geometry(id owner, SEL selector, id<MTLBuffer> vertices,
                        NSUInteger firstVertex, NSUInteger count,
                        enum NV2AMetalPrimitive primitive,
                        const NV2AMetalGeometryRasterConfig *config,
                        BOOL smooth, BOOL first, BOOL perspective,
                        NV2AMetalCommands *commands, NSError **error)
{
    (void)owner;
    (void)selector;
    (void)vertices;
    (void)firstVertex;
    (void)count;
    (void)primitive;
    (void)config;
    (void)smooth;
    (void)first;
    (void)perspective;
    (void)commands;
    if (error)
        *error = [NSError errorWithDomain:@"xemu.test.geometry-fault"
                                     code:1
                                 userInfo:nil];
    return nil;
}
static void feedback_program(unsigned row, unsigned mask)
{
    PGRAPHState *pg = &state->pgraph;
    mov(0, 0, 0, false);
    Token add = token(3, 0, row);
    add.word[1] |= 4u << 9;
    source(&add, 0, 3, 0, 0xe4);
    source(&add, 2, 2, 0, 0xe4);
    destination(&add, row, mask, 0, 0, 0, 0);
    memcpy(pg->program_data[1], add.word, sizeof(add.word));
    mov(2, 3, 3, true);
    for (unsigned k = 0; k < 4; k++) {
        float initial = 10 * (k + 1);
        memcpy(&pg->vsh_constants[row][k], &initial, 4);
        pg->vertex_attributes[4].inline_value[k] = k + 1;
    }
    pg->draw_arrays_length = 2;
    pg->draw_arrays_start[1] = 3;
    pg->draw_arrays_count[1] = 3;
    cpu_write(16384, 96);
    memcpy(state->vram_ptr + 16384 + 48, state->vram_ptr + 16384, 48);
}
static void expect_context(unsigned row, unsigned mask, unsigned count,
                           BOOL enabled)
{
    PGRAPHState *pg = &state->pgraph;
    for (unsigned k = 0; k < 4; k++) {
        float actual;
        memcpy(&actual, &pg->vsh_constants[row][k], 4);
        float expected =
            10 * (k + 1) +
            ((enabled && (mask & (8u >> k))) ? count * (k + 1) : 0);
        assert(actual == expected);
    }
    for (unsigned i = 0; i < 192; i++)
        assert(pg->vsh_constants_dirty[i] == (i == row && enabled && mask));
}
static void context_feedback_tests(void)
{
    const unsigned rows[] = { 10, 58, 59, 96, 154, 191 };
    unsigned cases = 0, faults = 0;
    for (unsigned access = 0; access < 2; access++)
        for (unsigned enabled = 0; enabled < 2; enabled++)
            for (unsigned mask = 0; mask < 16; mask++)
                for (unsigned index = 0; index < 6; index++) {
                    @autoreleasepool {
                        fixture();
                        unsigned row = rows[index];
                        PGRAPHState *pg = &state->pgraph;
                        pg->regs_[NV_PGRAPH_CSV0_D] =
                            2u << 30 |
                            (access ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0);
                        pg->enable_vertex_program_write = enabled;
                        feedback_program(row, mask);
                        if (!access && row == 10) {
                            NSError *error = nil;
                            qemu_mutex_lock(&pg->lock);
                            assert(![draw drawWithError:&error] && error);
                            expect_context(row, 0, 0, NO);
                            assert(pg->draw_time == 0 &&
                                   !surfaces.cache.commands.commandBuffer);
                            qemu_mutex_unlock(&pg->lock);
                            faults++;
                        } else {
                            render();
                            expect_context(row, mask, 6, enabled);
                            cases++;
                        }
                    }
                }
    assert(cases == 352 && faults == 32);
    printf("Ordered Draw XFCTX: %u two-range feedback cases/%u USER read "
           "rejections; all16 masks, WriteEnable0/1, six full constant rows "
           "PASS\n",
           cases, faults);
    groups++;
}
static void context_boundary_tests(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
    pg->enable_vertex_program_write = true;
    feedback_program(191, 15);
    pg->draw_arrays_length = 1;
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    require([draw beginWithError:&error], error);
    require([draw flushDrawWithError:&error], error);
    expect_context(191, 15, 3, YES);
    pg->draw_arrays_start[0] = 3;
    require([draw endWithError:&error], error);
    expect_context(191, 15, 6, YES);
    assert(pg->draw_time == 1);
    qemu_mutex_unlock(&pg->lock);
    fixture();
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
    pg->enable_vertex_program_write = true;
    feedback_program(191, 15);
    mov(2, 3, 3, false);
    Token arl = token(13, 0, 0);
    arl.word[1] |= 1u << 9;
    source(&arl, 0, 2, 0, 0);
    destination(&arl, 0, 0, 0, 0, 0, 0);
    arl.word[3] |= 1;
    memcpy(pg->program_data[3], arl.word, sizeof(arl.word));
    pg->vertex_attributes[1] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .count = 1,
                           .size = 4,
                           .stride = 4,
                           .offset = 96 };
    float indices[6] = { 0, 0, 0, NAN, 0, 0 };
    cpu_write(16384 + 96, sizeof(indices));
    memcpy(state->vram_ptr + 16384 + 96, indices, sizeof(indices));
    qemu_mutex_lock(&pg->lock);
    error = nil;
    assert(![draw drawWithError:&error] && error);
    expect_context(191, 15, 3, YES);
    assert(pg->draw_time == 0 && !surfaces.cache.commands.commandBuffer);
    indices[3] = 0;
    cpu_write(16384 + 96, sizeof(indices));
    memcpy(state->vram_ptr + 16384 + 96, indices, sizeof(indices));
    error = nil;
    require([draw drawWithError:&error], error);
    expect_context(191, 15, 6, YES);
    assert(pg->draw_time == 1);
    qemu_mutex_unlock(&pg->lock);
    puts("Ordered Draw epochs: Begin/Flush/End feedback retained; completed "
         "first-range context writes survive a later-range address fault PASS; "
         "retry transforms only the remaining range PASS");
    fixture();
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
    pg->enable_vertex_program_write = true;
    feedback_program(191, 15);
    pg->compressed_attrs = 1u << 4;
    qemu_mutex_lock(&pg->lock);
    require([draw beginWithError:&error], error);
    pg->draw_arrays_length = 0;
    pg->inline_buffer_length = 3;
    const float positions[3][4] = { { 0, 0, 32768, 1 },
                                    { 8, 0, 32768, 1 },
                                    { 0, 8, 32768, 1 } };
    pg->vertex_attributes[0].inline_buffer = (float *)positions;
    pg->vertex_attributes[0].inline_buffer_populated = true;
    error = nil;
    Method method = class_getInstanceMethod(
        [NV2AMetalGeometry class],
        @selector(encodeNativeRasterVertices:first:count:primitive:config:
                  smooth:firstProvoking:zPerspective:commands:error:));
    assert(method);
    IMP original = method_setImplementation(method, (IMP)fail_geometry);
    BOOL ok = [draw flushDrawWithError:&error];
    method_setImplementation(method, original);
    assert(!ok && error);

    expect_context(191, 15, 3, YES);
    NV2AMetalPGRAPHVertexState *retained =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:draw.vertexSnapshot
                                                       error:&error];
    assert(retained && retained.compressedAttributes == (1u << 4));
    assert(pg->compressed_attrs == (1u << 4) &&
           pg->vertex_attributes[0].inline_buffer_populated);
    [draw invalidateSession];
    qemu_mutex_unlock(&pg->lock);
    puts("Completed XF writes retain the previous capture metadata after a "
         "failing compressed-input rebind PASS");
    groups++;
}

static BOOL injected_draw_failure(BOOL active, NSError **error)
{
    Method method = class_getInstanceMethod(
        [NV2AMetalGeometry class],
        @selector(encodeNativeRasterVertices:first:count:primitive:config:
                  smooth:firstProvoking:zPerspective:commands:error:));
    assert(method);
    IMP original = method_setImplementation(method, (IMP)fail_geometry);
    BOOL ok =
        active ? [draw flushDrawWithError:error] : [draw drawWithError:error];
    method_setImplementation(method, original);
    return ok;
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *(*retry_fetch_original)(
    id, SEL, NSArray<NSNumber *> *, NV2AMetalPendingInput *, NSError **);
static NSArray<NV2AMetalPGRAPHFetchBatch *> *(*retry_inline_original)(
    id, SEL, NSArray<NSNumber *> *, NV2AMetalPendingInput *, NSError **);
static NSUInteger retry_fetch_expected;
static unsigned retry_fetch_cases;
static uint64_t retry_fetch_saved;
static unsigned retry_fetch_kind, retry_capture_cases;
static BOOL retry_capture_active;
static BOOL retry_capture_gpu_current;
static uint64_t retry_capture_saved;
static NSUInteger retry_capture_input;
static NV2AMetalFetchResult *(*retry_capture_original)(
    id, SEL, const NV2AMetalAttributeSource *, NSUInteger, unsigned,
    id<MTLBuffer>, NSUInteger, unsigned, NSUInteger, NSUInteger,
    NV2AMetalCommands *, NSError **);
static NV2AMetalFetchResult *retry_capture_probe(
    id object, SEL selector, const NV2AMetalAttributeSource *sources,
    NSUInteger count, unsigned first, id<MTLBuffer> indices,
    NSUInteger indexOffset, unsigned indexSize, NSUInteger current,
    NSUInteger prefix, NV2AMetalCommands *commands, NSError **error)
{
    if (retry_capture_active) {
        NSUInteger captured =
            retry_fetch_kind ?
                MAX(retry_fetch_expected, retry_capture_gpu_current ? 1u : 0u) :
                retry_capture_input;
        assert(count == captured &&
               current ==
                   (retry_capture_gpu_current ? captured - 1 : NSNotFound) &&
               first == 0 && indexOffset == 0);
        assert(prefix == (retry_fetch_kind ?
                              captured - retry_fetch_expected :
                              retry_capture_input - retry_fetch_expected));
        if (retry_fetch_kind == 1) {
            assert(indexSize == (captured ? 4u : 0u) &&
                   indices.length == captured * 4);
            if (!captured)
                assert(!indices);
            retry_capture_saved += retry_capture_input * 4 - indices.length;
        } else if (retry_fetch_kind >= 2) {
            assert(!indices);
            if (!captured ||
                (retry_fetch_kind == 2 &&
                 !state->pgraph.vertex_attributes[0].inline_buffer_populated)) {
                /* Accepted host Current needs no snapshot. Consumed inline
                 * buffers also use Current until a new stream is populated. */
                assert(!sources[0].count && !sources[0].buffer);
                if (!captured)
                    retry_capture_saved += retry_capture_input * 16;
            } else {
                assert(sources[0].buffer != surfaces.cache.vram &&
                       sources[0].buffer.length == captured * 16 &&
                       sources[0].byteLength == captured * 16);
                retry_capture_saved +=
                    retry_capture_input * 16 - sources[0].buffer.length;
            }
        }
        retry_capture_cases++;
    }
    return retry_capture_original(object, selector, sources, count, first,
                                  indices, indexOffset, indexSize, current,
                                  prefix, commands, error);
}
static void retry_fetch_check(NSArray<NV2AMetalPGRAPHFetchBatch *> *batches,
                              NSArray<NSNumber *> *prefixes, BOOL gpuCurrent,
                              NSError **error)
{
    require(batches != nil, *error);
    assert(batches.count == 1 && prefixes.count == 1);
    NV2AMetalPGRAPHFetchBatch *batch = batches[0];
    NSUInteger prefix = prefixes[0].unsignedIntegerValue;
    assert(batch.firstDecodedVertex == prefix &&
           batch.fetch.vertexCount == retry_fetch_expected &&
           batch.inputVertexCount == prefix + retry_fetch_expected &&
           batch.fetch.hasCurrent == gpuCurrent);
    NSUInteger records = retry_fetch_expected + gpuCurrent;
    assert(batch.fetch.attributes.length ==
           records * sizeof(NV2AMetalProgramInput));
    assert(batch.fetch.faults.length ==
           (records ? records + 1 : 0) * sizeof(uint32_t));
    retry_fetch_saved +=
        prefix * (sizeof(NV2AMetalProgramInput) + sizeof(uint32_t));
    retry_fetch_cases++;
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
retry_inline_probe(id object, SEL selector, NSArray<NSNumber *> *prefixes,
                   NV2AMetalPendingInput *input, NSError **error)
{
    retry_capture_input =
        prefixes[0].unsignedIntegerValue + retry_fetch_expected;
    retry_capture_active = YES;
    retry_capture_gpu_current = NO;
    NSArray *batches =
        retry_inline_original(object, selector, prefixes, input, error);
    retry_capture_active = NO;
    retry_fetch_check(batches, prefixes, NO, error);
    return batches;
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
retry_fetch_probe(id object, SEL selector, NSArray<NSNumber *> *prefixes,
                  NV2AMetalPendingInput *input, NSError **error)
{
    retry_capture_input =
        prefixes[0].unsignedIntegerValue + retry_fetch_expected;
    retry_capture_active = YES;
    retry_capture_gpu_current = YES;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
        retry_fetch_original(object, selector, prefixes, input, error);
    retry_capture_active = NO;
    retry_fetch_check(batches, prefixes, YES, error);
    return batches;
}
static void pending_retry_tests(void)
{
    Method fetchMethod = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(encodeIndependentSnapshotsWithPrefixes:indexedInput:error:));
    assert(fetchMethod);
    retry_fetch_original =
        (void *)method_setImplementation(fetchMethod, (IMP)retry_fetch_probe);
    Method inlineMethod = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:error:));
    assert(inlineMethod);
    retry_inline_original =
        (void *)method_setImplementation(inlineMethod, (IMP)retry_inline_probe);
    retry_fetch_cases = 0;
    retry_fetch_saved = 0;
    retry_capture_cases = 0;
    retry_capture_saved = 0;
    Method captureMethod = class_getInstanceMethod(
        NV2AMetalVertexFetch.class,
        @selector(encodeSources:count:firstVertex:indices:indexOffset:indexSize:
                  currentVertex:skippingPrefix:commands:error:));
    assert(captureMethod);
    retry_capture_original = (void *)method_setImplementation(
        captureMethod, (IMP)retry_capture_probe);
    unsigned cases = 0;
    const unsigned masks[] = { 15, 0, 1, 8 };
    for (unsigned kind = 0; kind < 4; kind++)
        for (unsigned policy = 0; policy < 2; policy++)
            for (unsigned maskIndex = 0; maskIndex < 4; maskIndex++) {
                @autoreleasepool {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    retry_fetch_kind = kind;
                    BOOL enabled = !policy, active = kind & 1;
                    unsigned mask = masks[maskIndex];
                    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
                    pg->enable_vertex_program_write = enabled;
                    feedback_program(191, mask);
                    pg->draw_arrays_length = kind == 0 ? 1 : 0;
                    float positions[4][4] = { { 0, 0, 32768, 1 },
                                              { 8, 0, 32768, 1 },
                                              { 0, 8, 32768, 1 },
                                              { 8, 8, 32768, 1 } };
                    cpu_write(16384, sizeof(positions));
                    memcpy(state->vram_ptr + 16384, positions,
                           sizeof(positions));
                    if (kind == 1) {
                        pg->inline_elements_length = 3;
                        for (unsigned i = 0; i < 4; i++)
                            pg->inline_elements[i] = i;
                    } else if (kind == 2) {
                        pg->inline_buffer_length = 3;
                        pg->vertex_attributes[0].inline_buffer =
                            &positions[0][0];
                        pg->vertex_attributes[0].inline_buffer_populated = true;
                    } else if (kind == 3) {
                        pg->inline_array_length = 12;
                        memcpy(pg->inline_array, positions, sizeof(positions));
                    }
                    NSError *error = nil;
                    qemu_mutex_lock(&pg->lock);
                    if (active)
                        require([draw beginWithError:&error], error);
                    retry_fetch_expected = 3;
                    assert(!injected_draw_failure(active, &error) && error);
                    expect_context(191, mask, 3, enabled);
                    error = nil;
                    retry_fetch_expected = 0;
                    assert(!injected_draw_failure(active, &error) && error);
                    expect_context(191, mask, 3, enabled);
                    /* Cached prefix bytes must survive edits to source memory.
                     */
                    for (unsigned i = 0; i < 3; i++)
                        positions[i][0] = positions[i][1] = 8;
                    if (kind < 2) {
                        cpu_write(16384, sizeof(positions));
                        memcpy(state->vram_ptr + 16384, positions,
                               sizeof(positions));
                    } else if (kind == 3) {
                        memcpy(pg->inline_array, positions, sizeof(positions));
                    }
                    if (kind == 0)
                        pg->draw_arrays_count[0] = 4;
                    if (kind == 1)
                        pg->inline_elements_length = 4;
                    if (kind == 2)
                        pg->inline_buffer_length = 4;
                    if (kind == 3)
                        pg->inline_array_length = 16;
                    error = nil;
                    retry_fetch_expected = 1;
                    assert(!injected_draw_failure(active, &error) && error);
                    expect_context(191, mask, 4, enabled);
                    error = nil;
                    retry_fetch_expected = 0;
                    require(active ? [draw endWithError:&error] :
                                     [draw drawWithError:&error],
                            error);
                    expect_context(191, mask, 4, enabled);
                    assert(pg->draw_time == 1);
                    qemu_mutex_unlock(&pg->lock);
                    read_vram(1024, 256);
                    color(1, 1, 0xff00ff00);
                    /* A consumed batch is a new execution, even with identical
                     * IDs. */
                    if (!active) {
                        retry_fetch_expected = 4;
                        render();
                        expect_context(191, mask, 8, enabled);
                    }
                    cases++;
                }
            }
    method_setImplementation(fetchMethod, (IMP)retry_fetch_original);
    method_setImplementation(inlineMethod, (IMP)retry_inline_original);
    method_setImplementation(captureMethod, (IMP)retry_capture_original);
    assert(cases == 32 && retry_fetch_cases == 144 && retry_capture_cases == 144);
    printf("Pending compact capture: %u actual GPU-input pairs, %llu CPU snapshot "
           "bytes avoided;full DMA arrays and compact inline/index snapshots PASS\n",
           retry_capture_cases, (unsigned long long)retry_capture_saved);
    printf("Pending compact Fetch: %u actual plan/capture pairs, %llu logical "
           "output bytes avoided;Current-only retries and one-vertex suffixes PASS\n",
           retry_fetch_cases, (unsigned long long)retry_fetch_saved);
    printf("Pending Draw retries: %u four-input/policy/mask cases; repeated "
           "raster faults preserve context, one new suffix executes once, "
           "cached prefix pixels survive source edits, consume permits new "
           "execution PASS\n",
           cases);
    groups++;
}
static void pending_hidden_last_test(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
    pg->enable_vertex_program_write = true;
    feedback_program(191, 15);
    pg->draw_arrays_length = 3;
    pg->draw_arrays_start[2] = 6;
    pg->draw_arrays_count[2] = 3;
    cpu_write(16384, 160);
    for (unsigned i = 6; i < 10; i++)
        memcpy(state->vram_ptr + 16384 + i * 16,
               state->vram_ptr + 16384 + (i % 3) * 16, 16);
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    require([draw beginWithError:&error], error);
    assert(!injected_draw_failure(YES, &error) && error);
    expect_context(191, 15, 9, YES);
    /* Mirror common PGRAPH's temporary N-1 flush before last-range expansion.
     */
    pg->draw_arrays_length = 2;
    error = nil;
    require([draw flushDrawWithError:&error], error);
    expect_context(191, 15, 9, YES);
    pg->draw_arrays_length = 0;
    pg->inline_elements_length = 4;
    for (unsigned i = 0; i < 4; i++)
        pg->inline_elements[i] = 6 + i;
    pg->inline_elements[1] = 0;
    error = nil;
    assert(![draw flushDrawWithError:&error] && error);
    expect_context(191, 15, 9, YES);
    pg->inline_elements[1] = 7;
    error = nil;
    require([draw endWithError:&error], error);
    expect_context(191, 15, 10, YES);
    assert(pg->draw_time == 1);
    qemu_mutex_unlock(&pg->lock);
    puts("Pending Draw hidden-last: three independent ranges, N-1 consume, "
         "rejected changed index prefix and later indexed suffix without XF "
         "replay PASS");
    groups++;
}

static void nop_vertex_context_tests(void)
{
    unsigned cases = 0;
    const unsigned masks[] = { 15, 0, 1, 8 };
    for (unsigned kind = 0; kind < 4; kind++)
        for (unsigned enabled = 0; enabled < 2; enabled++)
            for (unsigned maskIndex = 0; maskIndex < 4; maskIndex++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
                memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
                pg->surface_binding_dim.width = pg->surface_binding_dim.height =
                    0;
                pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
                pg->enable_vertex_program_write = enabled;
                unsigned mask = masks[maskIndex];
                feedback_program(191, mask);
                pg->draw_arrays_length = kind == 0 ? 1 : 0;
                float positions[4][4] = { { 0, 0, 32768, 1 },
                                          { 8, 0, 32768, 1 },
                                          { 0, 8, 32768, 1 },
                                          { 8, 8, 32768, 1 } };
                cpu_write(16384, sizeof(positions));
                memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
                if (kind == 1) {
                    pg->inline_elements_length = 3;
                    for (unsigned i = 0; i < 4; i++)
                        pg->inline_elements[i] = i;
                } else if (kind == 2) {
                    pg->inline_buffer_length = 3;
                    pg->vertex_attributes[0].inline_buffer = &positions[0][0];
                    pg->vertex_attributes[0].inline_buffer_populated = true;
                } else if (kind == 3) {
                    pg->inline_array_length = 12;
                    memcpy(pg->inline_array, positions, sizeof(positions));
                }
                VertexAttribute original[16];
                memcpy(original, pg->vertex_attributes, sizeof(original));
                uint16_t compressed = pg->compressed_attrs;
                NSError *error = nil;
                qemu_mutex_lock(&pg->lock);
                require([draw beginWithError:&error], error);
                require([draw prepareVertexStateChangeWithError:&error], error);
                expect_context(191, mask, 3, enabled);
                require([draw prepareVertexStateChangeWithError:&error], error);
                expect_context(191, mask, 3, enabled);
                if (kind == 0)
                    pg->draw_arrays_count[0] = 4;
                else if (kind == 1)
                    pg->inline_elements_length = 4;
                else if (kind == 2)
                    pg->inline_buffer_length = 4;
                else
                    pg->inline_array_length = 16;
                require([draw endWithError:&error], error);
                expect_context(191, mask, 4, enabled);
                assert(!memcmp(original, pg->vertex_attributes,
                               sizeof(original)) &&
                       pg->compressed_attrs == compressed &&
                       pg->draw_time == 0 && !surfaces.color &&
                       !surfaces.zeta && !surfaces.cache.count);
                qemu_mutex_unlock(&pg->lock);
                color(1, 1, 0xffff0000);
                cases++;
            }
    /* Standalone NOP consumes a batch, preserving Current. Identical later
     * inputs are a new execution, not a cached replay suppression. */
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
    memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
    pg->surface_binding_dim.width = pg->surface_binding_dim.height = 0;
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
    pg->enable_vertex_program_write = true;
    feedback_program(191, 15);
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    require([draw drawWithError:&error], error);
    expect_context(191, 15, 6, YES);
    require([draw drawWithError:&error], error);
    expect_context(191, 15, 12, YES);
    assert(pg->draw_time == 0 && !surfaces.cache.count);
    qemu_mutex_unlock(&pg->lock);
    /* A block that becomes NOP at End must retain its earlier XF writes. */
    fixture();
    pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
    pg->enable_vertex_program_write = true;
    feedback_program(191, 15);
    qemu_mutex_lock(&pg->lock);
    require([draw beginWithError:&error], error);
    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
    require([draw endWithError:&error], error);
    expect_context(191, 15, 6, YES);
    assert(pg->draw_time == 0);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    color(1, 1, 0xffff0000);
    assert(cases == 32);
    printf("Surface0 NOP XF: %u four-input/write/mask cases, "
           "Current/populated/compressed "
           "preserved, prefix once/new suffix once, standalone consume and "
           "live-End NOP context writes without raster PASS\n",
           cases);
    groups++;
}

static void transform_only_retry_tests(void)
{
    for (unsigned nop = 0; nop < 2; nop++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
        pg->enable_vertex_program_write = true;
        if (nop) {
            pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
            memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
            pg->surface_binding_dim.width = pg->surface_binding_dim.height = 0;
        }
        feedback_program(191, 15);
        mov(2, 3, 3, false);
        Token arl = token(13, 0, 0);
        arl.word[1] |= 1u << 9;
        source(&arl, 0, 2, 0, 0);
        destination(&arl, 0, 0, 0, 0, 0, 0);
        arl.word[3] |= 1;
        memcpy(pg->program_data[3], arl.word, sizeof(arl.word));
        pg->vertex_attributes[1] =
            (VertexAttribute){ .format =
                                   NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                               .count = 1,
                               .size = 4,
                               .stride = 4,
                               .offset = 96 };
        float indices[6] = { 0, 0, 0, NAN, 0, 0 };
        cpu_write(16384 + 96, sizeof(indices));
        memcpy(state->vram_ptr + 16384 + 96, indices, sizeof(indices));
        VertexAttribute original[16];
        memcpy(original, pg->vertex_attributes, sizeof(original));
        NSError *error = nil;
        qemu_mutex_lock(&pg->lock);
        require([draw beginWithError:&error], error);
        for (unsigned retry = 0; retry < 2; retry++) {
            error = nil;
            assert(![draw prepareVertexStateChangeWithError:&error] && error);
            expect_context(191, 15, 3, YES);
            assert(!memcmp(original, pg->vertex_attributes, sizeof(original)) &&
                   pg->draw_time == 0 && pg->draw_arrays_length == 2 &&
                   !surfaces.cache.commands.commandBuffer);
        }
        error = nil;
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *vertex = draw.vertexSnapshot;
        NSData *bound = [draw beginSnapshotWithError:&error];
        require(pending && vertex.length && bound.length, error);
        require([draw discardForRestoreWithError:&error], error);
        require([draw restoreVertexSnapshot:vertex error:&error], error);
        require([draw restoreBeginSnapshot:bound error:&error], error);
        require([draw restorePendingSnapshot:pending error:&error], error);
        require([draw beginWithError:&error], error);
        indices[3] = 0;
        cpu_write(16384 + 96, sizeof(indices));
        memcpy(state->vram_ptr + 16384 + 96, indices, sizeof(indices));
        require([draw prepareVertexStateChangeWithError:&error], error);
        expect_context(191, 15, 6, YES);
        require([draw endWithError:&error], error);
        expect_context(191, 15, 6, YES);
        assert(pg->draw_time == !nop);
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        color(1, 1, nop ? 0xffff0000 : 0xff00ff00);
    }
    puts("Transform-only retry: raster/NOP, two later-range faults preserve "
         "completed context and Current, partial-prefix save/restore then "
         "corrected suffix executes once PASS");
    groups++;
}

static void fixed_nop_input_tests(void)
{
    unsigned cases = 0;
    const unsigned masks[] = { 15, 0, 1, 8 };
    for (unsigned kind = 0; kind < 4; kind++)
        for (unsigned enabled = 0; enabled < 2; enabled++)
            for (unsigned maskIndex = 0; maskIndex < 4; maskIndex++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
                memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
                pg->surface_binding_dim.width = pg->surface_binding_dim.height =
                    0;
                pg->regs_[NV_PGRAPH_CSV0_D] = 0;
                pg->enable_vertex_program_write = enabled;
                unsigned mask = masks[maskIndex];
                feedback_program(191, mask);
                pg->draw_arrays_length = kind == 0 ? 1 : 0;
                float positions[4][4] = { { 0, 0, 32768, 1 },
                                          { 8, 0, 32768, 1 },
                                          { 0, 8, 32768, 1 },
                                          { 8, 8, 32768, 1 } };
                cpu_write(16384, sizeof(positions));
                memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
                if (kind == 1) {
                    pg->inline_elements_length = 3;
                    for (unsigned i = 0; i < 4; i++)
                        pg->inline_elements[i] = i;
                } else if (kind == 2) {
                    pg->inline_buffer_length = 3;
                    pg->vertex_attributes[0].inline_buffer = &positions[0][0];
                    pg->vertex_attributes[0].inline_buffer_populated = true;
                } else if (kind == 3) {
                    pg->inline_array_length = 12;
                    memcpy(pg->inline_array, positions, sizeof(positions));
                }
                VertexAttribute original[16];
                memcpy(original, pg->vertex_attributes, sizeof(original));
                uint16_t compressed = pg->compressed_attrs;
                NSError *error = nil;
                qemu_mutex_lock(&pg->lock);
                require([draw beginWithError:&error], error);
                require([draw prepareVertexStateChangeWithError:&error], error);
                expect_context(191, mask, 3, NO);
                require([draw prepareVertexStateChangeWithError:&error], error);
                expect_context(191, mask, 3, NO);
                if (kind == 0)
                    pg->draw_arrays_count[0] = 4;
                else if (kind == 1)
                    pg->inline_elements_length = 4;
                else if (kind == 2)
                    pg->inline_buffer_length = 4;
                else
                    pg->inline_array_length = 16;
                require([draw endWithError:&error], error);
                expect_context(191, mask, 4, NO);
                assert(!memcmp(original, pg->vertex_attributes,
                               sizeof(original)) &&
                       pg->compressed_attrs == compressed &&
                       pg->draw_time == 0 && !surfaces.color &&
                       !surfaces.zeta && !surfaces.cache.count);
                qemu_mutex_unlock(&pg->lock);
                color(1, 1, 0xffff0000);
                cases++;
            }
    assert(cases == 32);
    groups++;
    puts("Fixed Raw Surface0 inputs:32 four-input/write/mask cases; repeated "
         "boundary and new suffix, no context writes, Current/VRAM preserved "
         "PASS");
}

static void raw_hidden_last_tests(void)
{
    unsigned cases = 0;
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned enabled = 0; enabled < 2; enabled++)
            for (unsigned restore = 0; restore < 2; restore++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
                memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
                pg->surface_binding_dim.width = pg->surface_binding_dim.height =
                    0;
                pg->regs_[NV_PGRAPH_CSV0_D] = programmed ? 2u << 30 : 0;
                pg->enable_vertex_program_write = enabled;
                feedback_program(191, 15);
                pg->draw_arrays_length = 3;
                pg->draw_arrays_start[2] = 6;
                pg->draw_arrays_count[2] = 3;
                cpu_write(16384, 160);
                for (unsigned i = 6; i < 10; i++)
                    memcpy(state->vram_ptr + 16384 + i * 16,
                           state->vram_ptr + 16384 + (i % 3) * 16, 16);
                VertexAttribute original[16];
                memcpy(original, pg->vertex_attributes, sizeof(original));
                NSError *error = nil;
                qemu_mutex_lock(&pg->lock);
                require([draw beginWithError:&error], error);
                require([draw prepareVertexStateChangeWithError:&error], error);
                expect_context(191, 15, 9, programmed && enabled);
                if (restore) {
                    NSData *pending = [draw pendingSnapshotWithError:&error];
                    NSData *vertex = draw.vertexSnapshot;
                    NSData *bound = [draw beginSnapshotWithError:&error];
                    require(pending && vertex.length && bound.length, error);
                    require([draw discardForRestoreWithError:&error], error);
                    require([draw restoreVertexSnapshot:vertex error:&error],
                            error);
                    require([draw restoreBeginSnapshot:bound error:&error],
                            error);
                    require([draw restorePendingSnapshot:pending error:&error],
                            error);
                    require([draw beginWithError:&error], error);
                }
                pg->draw_arrays_length = 2;
                require([draw flushDrawWithError:&error], error);
                expect_context(191, 15, 9, programmed && enabled);
                pg->draw_arrays_length = 0;
                pg->inline_elements_length = 4;
                for (unsigned i = 0; i < 4; i++)
                    pg->inline_elements[i] = 6 + i;
                pg->inline_elements[1] = 0;
                error = nil;
                assert(![draw flushDrawWithError:&error] && error);
                expect_context(191, 15, 9, programmed && enabled);
                pg->inline_elements[1] = 7;
                error = nil;
                require([draw endWithError:&error], error);
                expect_context(191, 15, 10, programmed && enabled);
                assert(!memcmp(original, pg->vertex_attributes,
                               sizeof(original)) &&
                       !pg->draw_time && !surfaces.color && !surfaces.zeta &&
                       !surfaces.cache.count);
                qemu_mutex_unlock(&pg->lock);
                color(1, 1, 0xffff0000);
                cases++;
            }
    assert(cases == 8);
    groups++;
    puts("Raw Surface0 hidden-last:8 fixed/program/write/restore cases; three "
         "ranges, N-1 consume, changed indexed-prefix rejection, suffix once "
         "and Current/VRAM preserved PASS");
}

static void raw_pending_correlation_tests(void)
{
    fixture();
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw beginWithError:&error], error);
    NSData *vertex = draw.vertexSnapshot;
    NSData *bound = [draw beginSnapshotWithError:&error];
    require(vertex.length && bound.length, error);
    require([draw endWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    read_vram(1024, 256);
    color(1, 1, 0xff00ff00);

    fixture();
    PGRAPHState *pg = &state->pgraph;
    const uint32_t rasterControl = pg->regs_[NV_PGRAPH_CONTROL_0];
    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
    qemu_mutex_lock(&pg->lock);
    require([draw beginWithError:&error], error);
    NSData *raw = draw.vertexSnapshot;
    assert(ldl_be_p((const uint8_t *)raw.bytes + 4) == 6);
    require([draw prepareVertexStateChangeWithError:&error], error);
    NSData *pending = [draw pendingSnapshotWithError:&error];
    require(pending.length != 0, error);
    require([draw discardForRestoreWithError:&error], error);
    pg->regs_[NV_PGRAPH_CONTROL_0] = rasterControl;
    /* Intentionally mix independently valid capture components. */
    require([draw restoreVertexSnapshot:vertex error:&error], error);
    require([draw restoreBeginSnapshot:bound error:&error], error);
    require([draw restorePendingSnapshot:pending error:&error], error);
    error = nil;
    assert(![draw beginWithError:&error] && error &&
           [error.localizedDescription
               isEqualToString:
                   @"Raw XF pending prefix cannot restore a raster Begin"]);
    assert(!pg->draw_time);
    /* Saved components remain reusable for the correct NOP pair. */
    error = nil;
    require([draw restoreVertexSnapshot:raw error:&error], error);
    NSData *nopBegin = nil;
    /* Build a canonical NOP Begin independently, then restore the saved prefix.
     */
    require([draw discardForRestoreWithError:&error], error);
    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
    require([draw beginWithError:&error], error);
    nopBegin = [draw beginSnapshotWithError:&error];
    require(nopBegin != nil, error);
    require([draw discardForRestoreWithError:&error], error);
    require([draw restoreVertexSnapshot:raw error:&error], error);
    require([draw restoreBeginSnapshot:nopBegin error:&error], error);
    /* A V6 raw vertex cannot import an old envelope without the raw marker. */
    NSMutableData *legacy = [pending mutableCopy];
    stl_be_p((uint8_t *)legacy.mutableBytes + 4, 1);
    stl_be_p((uint8_t *)legacy.mutableBytes + 8,
             ldl_be_p((const uint8_t *)legacy.bytes + 8) & 1);
    require([draw restorePendingSnapshot:legacy error:&error], error);
    error = nil;
    assert(
        ![draw beginWithError:&error] && error &&
        [error.localizedDescription
            isEqualToString:@"Raw XF capture requires raw pending metadata"]);
    error = nil;
    require([draw restorePendingSnapshot:pending error:&error], error);
    require([draw beginWithError:&error], error);
    require([draw endWithError:&error], error);
    assert(!pg->draw_time);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    color(1, 1, 0xffff0000);
    groups++;
    puts("Raw pending correlation guard:regular raster Begin rejected with raw "
         "prefix; V6 plus legacy unmarked prefix rejected; correct NOP restore "
         "recovers and preserves red VRAM PASS");
}


#include "test-metal-XF-independent.h"
#include "test-metal-cache-concurrency.h"

#include "test-metal-shared-draw.h"
#include "test-metal-draw-attachments.h"
#include "test-metal-xf-only-submit.h"
#include "test-metal-xf-only-queued.h"
#include "test-metal-discarded-fixed.h"

static NV2AMetalPixelDraw *(*group_original_encode)(
    id, SEL, NV2AMetalGeometryResult *, NSUInteger, NSUInteger,
    const NV2AMetalPixelUniforms *, const NV2AMetalPixelTexture *,
    MTL4RenderPassDescriptor *, NV2AMetalDrawState *, NV2AMetalPixelRasterClass,
    BOOL, NV2AMetalCommands *, NSError **);
static NSMutableSet *group_encoders;
static unsigned group_calls, group_fail_at, group_emissions;
static BOOL (*group_original_emit)(id, SEL, id<MTL4RenderCommandEncoder>,
                                   NV2AMetalCommands *, NSError **);
static BOOL group_emit(id owner, SEL selector,
                       id<MTL4RenderCommandEncoder> encoder,
                       NV2AMetalCommands *commands, NSError **error)
{
    assert(encoder);
    group_emissions++;
    [group_encoders addObject:encoder];
    return group_original_emit(owner, selector, encoder, commands, error);
}
static NV2AMetalPixelDraw *group_encode(
    id owner, SEL selector, NV2AMetalGeometryResult *geometry,
    NSUInteger offset, NSUInteger count, const NV2AMetalPixelUniforms *uniforms,
    const NV2AMetalPixelTexture *textures, MTL4RenderPassDescriptor *pass,
    NV2AMetalDrawState *raster, NV2AMetalPixelRasterClass rasterClass,
    BOOL ignore, NV2AMetalCommands *commands, NSError **error)
{
    assert(!group_emissions && !group_encoders.count);
    if (++group_calls == group_fail_at) {
        if (error)
            *error = [NSError errorWithDomain:@"test.render-group"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return group_original_encode(owner, selector, geometry, offset, count,
                                 uniforms, textures, pass, raster, rasterClass,
                                 ignore, commands, error);
}
static void render_group_contract_test(void)
{
    NSError *error = nil;
    Method method = class_getInstanceMethod(
        NV2AMetalPixelShader.class,
        @selector(prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                  rasterClass:ignorePolygonCulling:commands:error:));
    Method emit = class_getInstanceMethod(
        NV2AMetalPixelDraw.class,
        @selector(encodeWithRenderEncoder:commands:error:));
    assert(method && emit);
    uint8_t reference[256];
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        if (attempt != 2) {
            fixture();
            load_face_scene();
            state->pgraph.regs_[NV_PGRAPH_SETUPRASTER] = 1 << 2;
        }
        group_calls = group_emissions = 0;
        group_fail_at = attempt == 1 ? 2 : 0;
        group_encoders = [NSMutableSet new];
        group_original_encode =
            (void *)method_setImplementation(method, (IMP)group_encode);
        group_original_emit =
            (void *)method_setImplementation(emit, (IMP)group_emit);
        qemu_mutex_lock(&state->pgraph.lock);
        BOOL ok = [draw drawWithError:&error];
        qemu_mutex_unlock(&state->pgraph.lock);
        method_setImplementation(method, (IMP)group_original_encode);
        method_setImplementation(emit, (IMP)group_original_emit);
        assert(group_encoders.count == (attempt == 1 ? 0 : 1));
        if (attempt == 1) {
            assert(!ok && !group_emissions && group_calls == 2 &&
                   [error.domain isEqualToString:@"test.render-group"]);
            assert(!surfaces.cache.commands.commandBuffer &&
                   state->pgraph.draw_time == 0);
            read_vram(1024, 256);
            for (unsigned i = 0; i < 64; i++)
                color(i % 8, i / 8, 0xffff0000);
        } else {
            require(ok, error);
            assert(group_calls == 4 && group_emissions == 4 &&
                   state->pgraph.draw_time == 1);
            read_vram(1024, 256);
            if (!attempt)
                memcpy(reference, state->vram_ptr + 1024, sizeof(reference));
            else
                assert(!memcmp(reference, state->vram_ptr + 1024,
                               sizeof(reference)));
        }
        group_encoders = nil;
    }
    puts("PGRAPH render group: four ordered front/back topology slices use "
         "one encoder; second-slice preparation failure opens no raster pass, "
         "preserves "
         "draw time and retry reproduces 256 reference bytes PASS");
    groups++;
}
#include "test-metal-discarded-program.h"
#include "test-metal-stream-group.h"
#include "test-metal-draw-transport.h"
#include "test-metal-renderer-cache.h"
#include "test-metal-binding-struct.h"
#include "test-metal-depth-stencil-begin.h"
#include "test-metal-fetch-overlap.h"
#include "test-metal-report-boundaries.h"
#include "test-metal-writable-submit-benchmark.h"
#include "test-metal-inline-producer.h"
#include "test-metal-draw-batches.h"
#include "test-metal-begin-capture.h"
#include "test-metal-textured-begin.h"
#include "test-metal-inline-fixed.h"
#include "test-metal-raster-chains.h"
#include "test-metal-visibility-pool.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        state = g_new0(NV2AState, 1);
        state->vram = g_new0(MemoryRegion, 1);
        assert(
            !posix_memalign((void **)&state->vram_ptr, getpagesize(), 65536));
        memset(state->vram_ptr, 0, 65536);
        qemu_mutex_init(&state->pgraph.lock);
        qemu_mutex_init(&state->pfifo.lock);
        surfaces = [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state
                                                            error:&error];
        require(surfaces != nil, error);
        draw = [[NV2AMetalPGRAPHDraw alloc] initWithState:state
                                                 surfaces:surfaces
                                                    error:&error];
        require(draw != nil, error);
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--visibility-pool")))
            visibility_pool_tests();
        if (argc == 2 && !strcmp(argv[1], "--visibility-pool"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--raster-chains")))
            raster_chain_tests();
        if (argc == 2 && !strcmp(argv[1], "--raster-chains"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--inline-fixed")))
            inline_fixed_tests();
        if (argc == 2 && !strcmp(argv[1], "--inline-fixed"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--textured-begin")))
            textured_begin_tests();
        if (argc == 2 && !strcmp(argv[1], "--textured-begin"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--draw-attachments")))
            draw_attachment_tests();
        if (argc == 2 && !strcmp(argv[1], "--draw-attachments"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--begin-capture")))
            begin_capture_tests();
        if (argc == 2 && !strcmp(argv[1], "--begin-capture"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--draw-batches")))
            draw_batch_tests();
        if (argc == 2 && !strcmp(argv[1], "--draw-batches"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--inline-producer")))
            inline_producer_tests();
        if (argc == 2 && !strcmp(argv[1], "--inline-producer"))
            goto close;
        if (argc == 2 && (!strcmp(argv[1], "--writable-submit-benchmark") ||
                          !strcmp(argv[1], "--nonwriting-submit-benchmark"))) {
            writable_submit_benchmark(
                !strcmp(argv[1], "--nonwriting-submit-benchmark"));
            goto close;
        }
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--discarded-program")))
            discarded_program_tests();
        if (argc == 2 && !strcmp(argv[1], "--discarded-program"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--discarded-fixed")))
            discarded_fixed_tests();
        if (argc == 2 && !strcmp(argv[1], "--discarded-fixed"))
            goto close;
        if (argc == 2 && !strcmp(argv[1], "--constant-idx-raster")) {
            queued_constant_raster_tests();
            goto close;
        }
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--xf-only-queued")))
            queued_xf_tests();
        if (argc == 2 && !strcmp(argv[1], "--xf-only-queued"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--xf-only-submit"))) {
            xf_only_submit_tests();
            xf_only_failure_tests();
        }
        if (argc == 2 && !strcmp(argv[1], "--xf-only-submit"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--report-boundaries")))
            report_boundary_tests();
        if (argc == 2 && !strcmp(argv[1], "--report-boundaries"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--fetch-overlap")))
            fetch_overlap_tests();
        if (argc == 2 && !strcmp(argv[1], "--fetch-overlap"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--typed-bindings"))) {
            depth_stencil_begin_tests();
            binding_struct_tests();
        }
        if (argc == 2 && !strcmp(argv[1], "--typed-bindings"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--renderer-cache")))
            renderer_cache_contract_test();
        if (argc == 2 && !strcmp(argv[1], "--renderer-cache"))
            goto close;
        if (argc == 2 && !strcmp(argv[1], "--raster"))
            goto raster;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--render-group")))
            render_group_contract_test();
        if (argc == 2 && !strcmp(argv[1], "--render-group"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--stream-group")))
            stream_group_contract_tests();
        if (argc == 2 && !strcmp(argv[1], "--stream-group"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--vertex-transport")))
            draw_transport_tests();
        if (argc == 2 && !strcmp(argv[1], "--vertex-transport"))
            goto close;
        if (argc == 2 && !strcmp(argv[1], "--shared-submit")) {
            shared_draw_contract_tests();
            goto close;
        }
        if (argc == 1)
            shared_draw_contract_tests();
        if (argc == 2 && !strcmp(argv[1], "--cache-register-isolation")) {
            cache_register_isolation_test();
            goto close;
        }
        if (argc == 2 && !strcmp(argv[1], "--cache-transaction")) {
            cache_guard_transaction_test();
            goto close;
        }
        if (argc == 2 && !strcmp(argv[1], "--concurrent-XF-RAM")) {
            XF_cache_concurrent_tests();
            goto close;
        }
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--cache-context-regressions")))
            XF_cache_concurrent_tests();
        independent_surface_queue_tests();
        if (argc == 2 && !strcmp(argv[1], "--independent-surface-queue"))
            goto close;
        raw_pending_correlation_tests();
        fixed_nop_input_tests();
        raw_hidden_last_tests();
        nop_vertex_context_tests();
        transform_only_retry_tests();
        pending_retry_tests();
        pending_hidden_last_test();
        context_feedback_tests();
        context_boundary_tests();
        if (argc == 2 && !strcmp(argv[1], "--cache-context-regressions"))
            goto close;
    raster:
        active_case = "input_paths";
        input_paths();
        active_case = "independent_ranges";
        independent_ranges();
        active_case = "all_primitives_and_formats";
        all_primitives_and_formats();
        active_case = "depth_stencil_only";
        depth_stencil_only();
        active_case = "polygon_modes";
        polygon_modes();
        active_case = "face_mode_matrix";
        face_mode_matrix();
        active_case = "ordered_blending";
        ordered_blending();
        active_case = "polygon_family_culling";
        polygon_family_culling();
        active_case = "provoking_and_offsets";
        provoking_and_offsets();
        active_case = "aa_and_scale";
        aa_and_scale();
        active_case = "wide_and_smooth_lines";
        wide_and_smooth_lines();
        active_case = "smooth_polygons";
        smooth_polygons();
        active_case = "logic_operations";
        logic_operations();
        active_case = "dither_operations";
        dither_operations();
        active_case = "texture_and_feedback";
        texture_and_feedback();
        active_case = "dynamic_program";
        dynamic_program();
        active_case = "inline_retry";
        inline_retry();
        active_case = "failure_and_lifecycle";
        failure_and_lifecycle();
    close:
        qemu_mutex_lock(&state->pgraph.lock);
        require([draw closeWithError:&error], error);
        qemu_mutex_unlock(&state->pgraph.lock);
        draw = nil;
        surfaces = nil;
        qemu_mutex_destroy(&state->pgraph.lock);
        qemu_mutex_destroy(&state->pfifo.lock);
        free(state->vram_ptr);
        g_free(state->vram);
        g_free(state);
        printf("Metal 4 PGRAPH draw: %u controller groups, %u draw calls, "
               "%u rejected batches PASS\n",
               groups, draws, rejected);
    }
    return 0;
}
