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
#import <objc/runtime.h>
#import "hw/xbox/nv2a/pgraph/metal/surface-cache.h"
#import "hw/xbox/nv2a/pgraph/metal/archive-native.h"
#import "hw/xbox/nv2a/pgraph/metal/draw-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-pgraph.h"
#include "hw/xbox/nv2a/pgraph/metal/geometry-types.h"
#include "hw/xbox/nv2a/pgraph/metal/renderer.h"
#include "hw/xbox/nv2a/pgraph/metal/vertex-snapshot.h"
#include "migration/qemu-file.h"
#include "io/channel-file.h"
#import "hw/xbox/nv2a/pgraph/metal/scanout-pgraph.h"
#include "ui/xemu-settings.h"
#include "ui/xui/metal4/frame-images.h"
#include "ui/xemu-notifications.h"
#include "qapi/error.h"
#include "hw/xbox/nv2a/pgraph/metal/pixel-shader-types.h"
#include "hw/xbox/nv2a/pgraph/metal/texture-upload-types.h"
#include "qemu/module.h"
#include "test-metal-legacy-cube.h"

#include "test-metal-idx.h"

static NV2AState *state;
static NV2AMetalPGRAPHSurfaces *surfaces;
static NV2AMetalPGRAPHDraw *draw;
static MemAccessCallback *hook;
static CPUState cpu;
static DMAObject dma[5];
static bool texture_dirty[16];
static unsigned groups, methods, notifications;
static QemuEvent worker_kick;
static QemuThread worker;
static bool worker_running, worker_stop;
static bool worker_common;
static bool worker_pause;
static QemuEvent worker_paused, worker_resume, host_stop_started;
static bool host_stopped;
static void *requested_frame;
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
static hwaddr tile_clipped_length = UINT64_MAX;
hwaddr nv_clip_gpu_tile_blit(NV2AState *d, hwaddr address, hwaddr length)
{
    assert(d == state && address < 65536);
    return MIN(length,
               tile_clipped_length); // Simulated original tile-helper result.
}
void *nv_dma_map(NV2AState *d, hwaddr object, hwaddr *length)
{
    assert(d == state && object == d->pgraph.dma_report);
    DMAObject report = nv_dma_load(d, object);
    *length = report.limit;
    return d->vram_ptr + (report.address & 0x07ffffff);
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
void pfifo_kick(NV2AState *d)
{
    assert(d == state && worker_running);
    qemu_event_set(&worker_kick);
}

/* Mock only unreachable VM/UI scheduling interfaces. Real common PGRAPH
 * dispatch, DrawArrays expansion/lookahead and inline buffers are linked. */
__typeof__(g_config) g_config;
NV2AStats g_nv2a_stats;
const NV2ABlockInfo blocktable[NV_NUM_BLOCKS] = { 0 };
void nv2a_update_irq(NV2AState *d)
{
    (void)d;
    abort();
}
void nv2a_profile_increment(void)
{
    abort();
}
void nv2a_profile_flip_stall(void)
{
    abort();
}
void xemu_queue_notification(const char *m)
{
    (void)m;
    abort();
}
void xemu_queue_error_message(const char *m)
{
    (void)m;
    abort();
}
uint32_t pgraph_rdi_read(PGRAPHState *p, unsigned s, unsigned a)
{
    (void)p;
    (void)s;
    (void)a;
    abort();
}
void pgraph_rdi_write(PGRAPHState *p, unsigned s, unsigned a, uint32_t v)
{
    (void)p;
    (void)s;
    (void)a;
    (void)v;
    abort();
}
void async_safe_run_on_cpu(CPUState *c, run_on_cpu_func f, run_on_cpu_data d)
{
    (void)c;
    (void)f;
    (void)d;
    abort();
}
static const PGRAPHRenderer renderer = {
    .type = CONFIG_DISPLAY_RENDERER_METAL4,
    .name = "Native Metal 4 draw test",
    .ops = { .init = pgraph_metal4_init,
             .finalize = pgraph_metal4_finalize,
             .draw_begin = pgraph_metal4_draw_begin,
             .flush_draw = pgraph_metal4_flush_draw,
             .vertex_state_change = pgraph_metal4_vertex_state_change,
             .launch_transform_program = pgraph_metal4_launch_transform_program,
             .draw_end = pgraph_metal4_draw_end,
             .clear_surface = pgraph_metal4_clear_surface,
             .clear_report_value = pgraph_metal4_clear_report_value,
             .get_report = pgraph_metal4_get_report,
             .process_pending_reports = pgraph_metal4_process_pending_reports,
             .image_blit = pgraph_metal4_image_blit,
             .flip_stall = pgraph_metal4_flip_stall,
             .surface_update = pgraph_metal4_surface_update,
             .surface_flush = pgraph_metal4_surface_flush,
             .process_pending = pgraph_metal4_process_pending,
             .pre_savevm_trigger = pgraph_metal4_pre_savevm_trigger,
             .pre_savevm_wait = pgraph_metal4_pre_savevm_wait,
             .pre_restore_trigger = pgraph_metal4_pre_restore_trigger,
             .pre_restore_wait = pgraph_metal4_pre_restore_wait,
             .post_load = pgraph_metal4_post_load,
             .pre_shutdown_trigger = pgraph_metal4_pre_shutdown_trigger,
             .pre_shutdown_wait = pgraph_metal4_pre_shutdown_wait,
             .set_surface_scale_factor = pgraph_metal4_set_surface_scale_factor,
             .get_surface_scale_factor =
                 pgraph_metal4_get_surface_scale_factor }
};
static NSData *legacy_pixel_fixture(NSData *current, unsigned version)
{
    assert(version >= 1 && version <= 3 && current.length == 100 + 1332);
    unsigned header = version == 1 ? 92 : 100;
    NSMutableData *old = [NSMutableData dataWithBytes:current.bytes
                                               length:header];
    stl_be_p((uint8_t *)old.mutableBytes + 4, version);
    stl_be_p((uint8_t *)old.mutableBytes + 8, version == 3 ? 327 : 323);
    [old appendData:[current subdataWithRange:NSMakeRange(100, 108 * 4)]];
    for (unsigned i = 0; i < 4; i++) {
        [old appendData:[current subdataWithRange:NSMakeRange(
                                                      100 + (108 + i * 38) * 4,
                                                      37 * 4)]];
    }
    [old appendData:[current
                        subdataWithRange:NSMakeRange(100 + 260 * 4,
                                                     (version == 3 ? 71 : 67) *
                                                         4)]];
    return old;
}

static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Native callbacks: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void reg_float(unsigned reg, float value)
{
    memcpy(&state->pgraph.regs_[reg], &value, 4);
}
static void cpu_write(NSUInteger a, NSUInteger n)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:a
                                               length:n
                                                write:YES
                                                error:&error],
            error);
}
static int scan_width = 8, scan_height = 8;
static uint32_t scan_pitch = 32, scan_start, scan_compare;
static int scan_bpp;
static uint8_t scan_hpel;
static bool scan_hpel_split;
static int get_scan_bpp(VGACommonState *vga)
{
    assert(vga == &state->vga);
    return scan_bpp;
}
static void get_scan_resolution(VGACommonState *vga, int *width, int *height)
{
    assert(vga == &state->vga);
    *width = scan_width;
    *height = scan_height;
}
static void get_scan_params(VGACommonState *vga, VGADisplayParams *params)
{
    assert(vga == &state->vga);
    *params = (VGADisplayParams){ .line_offset = scan_pitch,
                                  .start_addr = scan_start,
                                  .line_compare = scan_compare,
                                  .hpel = scan_hpel,
                                  .hpel_split = scan_hpel_split };
}
static void fixture(void)
{
    g_config.display.renderer = CONFIG_DISPLAY_RENDERER_METAL4;
    g_config.display.quality.surface_scale = 1;
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    draw = nil;
    surfaces = nil;
    renderer.ops.finalize(state);
    for (unsigned i = 0; i < 16; i++)
        g_free(pg->vertex_attributes[i].inline_buffer);
    qemu_mutex_unlock(&pg->lock);
    if (pg->renderer) {
        qemu_event_destroy(&pg->flush_complete);
        qemu_event_destroy(&pg->sync_complete);
    }
    qemu_mutex_destroy(&pg->renderer_lock);
    qemu_mutex_destroy(&pg->lock);
    memset(pg, 0, sizeof(*pg));
    qemu_mutex_init(&pg->lock);
    qemu_mutex_init(&pg->renderer_lock);
    qemu_event_init(&pg->flush_complete, false);
    qemu_event_init(&pg->sync_complete, false);
    memset(texture_dirty, 0, sizeof(texture_dirty));
    tile_clipped_length = UINT64_MAX;
    scan_width = scan_height = 8;
    scan_pitch = 32;
    scan_start = 0;
    scan_compare = UINT32_MAX;
    scan_hpel = 8;
    scan_hpel_split = false;
    state->vga.get_bpp = NULL;
    state->vga.vbe_size_mask = 65535;
    state->vga.big_endian_fb = false;
    state->vga.ar_index = 0x20;
    state->vga.gr[VGA_GFX_MISC] = VGA_GR06_GRAPHICS_MODE;
    state->vga.gr[VGA_GFX_MODE] = 2 << 5;
    state->vga.cr[VGA_CRTC_MODE] = 3;
    state->vga.cr[VGA_CRTC_MAX_SCAN] = 0;
    state->vga.get_resolution = get_scan_resolution;
    state->vga.get_params = get_scan_params;
    state->vga.cr[NV_PRMCIO_INTERLACE_MODE] = NV_PRMCIO_INTERLACE_MODE_DISABLED;
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = 0;
    memset(state->pvideo.regs, 0, sizeof(state->pvideo.regs));
    state->pcrtc.start = 1024;
    for (unsigned i = 0; i < 256; i++)
        for (unsigned ch = 0; ch < 3; ch++)
            state->puserdac.palette[i * 3 + ch] = i;
    for (unsigned i = 0; i < 5; i++)
        dma[i] = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                              .address = (unsigned[]){ 1024, 4096, 16384, 32768,
                                                       49152 }[i],
                              .limit = 1023 };
    pg->renderer = &renderer;
    pg->primitive_mode = PRIM_TYPE_INVALID;
    pg->dma_color = 16;
    pg->dma_zeta = 32;
    pg->dma_vertex_a = pg->dma_vertex_b = 48;
    pg->dma_a = 64;
    pg->dma_b = 80;
    pg->dma_report = 64;
    pg->surface_color.pitch = 32;
    pg->surface_zeta.pitch = 16;
    pg->surface_shape = (SurfaceShape){
        .color_format = 8, .zeta_format = 1, .clip_width = 8, .clip_height = 8
    };
    pg->surface_scale_factor = 1;
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
    pg->regs_[NV_PGRAPH_CTX_CONTROL] = NV_PGRAPH_CTX_CONTROL_CHID;
    pg->regs_[NV_PGRAPH_CTX_CACHE1] = NV_KELVIN_PRIMITIVE;
    for (unsigned i = 0; i < 16; i++) {
        pg->vertex_attributes[i].inline_value[3] = 1;
        pg->vertex_attributes[i].inline_buffer = g_new0(float, 64);
    }
    pg->vertex_attributes[3].inline_value[1] = 1;
    for (unsigned i = 0; i < 4; i++) {
        float one = 1;
        memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0 + i][i], &one, 4);
    }
    VertexAttribute *position = &pg->vertex_attributes[0];
    position->format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    position->count = 4;
    position->size = 4;
    position->stride = 16;
    Error *error = NULL;
    qemu_mutex_lock(&pg->lock);
    renderer.ops.init(state, &error);
    qemu_mutex_unlock(&pg->lock);
    assert(!error && pg->metal4_renderer_state && !hook);
    draw = (__bridge NV2AMetalPGRAPHDraw *)pgraph_metal4_draw_handle(state);
    surfaces = draw.surfaces;
    const float positions[6][4] = { { 0, 0, 32768, 1 }, { 8, 0, 32768, 1 },
                                    { 0, 8, 32768, 1 }, { 4, 0, 32768, 1 },
                                    { 8, 0, 32768, 1 }, { 4, 4, 32768, 1 } };
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
static int method(unsigned m, uint32_t parameter, uint32_t *params,
                  size_t words, size_t lookahead, bool inc)
{
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    int n =
        pgraph_method(state, 0, m, parameter, params, words, lookahead, inc);
    qemu_mutex_unlock(&pg->lock);
    methods++;
    return n;
}
static void send_method(unsigned m, uint32_t v)
{
    assert(method(m, v, &v, 1, 0, false) == 1);
}
static void send_float_method(unsigned m, float value)
{
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    send_method(m, bits);
}
static void begin(unsigned primitive)
{
    send_method(NV097_SET_BEGIN_END, primitive);
}
static void end(void)
{
    send_method(NV097_SET_BEGIN_END, NV097_SET_BEGIN_END_OP_END);
}
static void arrays(unsigned start, unsigned count)
{
    send_method(NV097_DRAW_ARRAYS, start | ((count - 1) << 24));
}
static uint32_t color(unsigned x, unsigned y)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:256
                                                write:NO
                                                error:&error],
            error);
    uint32_t value;
    memcpy(&value, state->vram_ptr + 1024 + (y * 8 + x) * 4, 4);
    return value;
}
static void boundaries(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    end();
    assert(pg->draw_time == 0 && pg->primitive_mode == PRIM_TYPE_INVALID);
    begin(PRIM_TYPE_TRIANGLES);
    begin(PRIM_TYPE_LINES);
    assert(pg->primitive_mode == PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    assert(pg->draw_time == 1 && !pg->draw_arrays_length &&
           pg->primitive_mode == PRIM_TYPE_INVALID);
    assert(color(1, 1) == 0xff00ff00 && color(7, 7) == 0xffff0000);
    begin(PRIM_TYPE_TRIANGLES);
    end();
    assert(pg->draw_time == 2); /* Empty non-nop End. */
    send_method(NV097_SET_COLOR_MASK, 0);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    assert(pg->draw_time == 2);
    groups++;
}
static void begin_capture(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    // The GL Begin binds its raster/program state; vertex data is late-bound.
    send_method(NV097_SET_BLEND_ENABLE, 1);
    send_method(NV097_SET_BLEND_EQUATION, 0x8006);
    send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0);
    send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0);
    arrays(0, 3);
    end();
    assert(pg->draw_time == 1 && color(1, 1) == 0xff00ff00);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    assert(pg->draw_time == 2 && color(1, 1) == 0);
    groups++;
}
static void lookahead(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    uint32_t params[] = { 2u << 24,
                          NV097_SET_BEGIN_END,
                          0,
                          NV097_SET_BEGIN_END,
                          PRIM_TYPE_TRIANGLES,
                          NV097_DRAW_ARRAYS,
                          3 | 2u << 24,
                          0 };
    assert(method(NV097_DRAW_ARRAYS, params[0], params, 1, 7, false) == 5);
    assert(pg->draw_time == 0 && pg->draw_arrays_length == 1 &&
           pg->draw_arrays_prevent_connect);
    arrays(3, 3);
    assert(pg->draw_arrays_length == 2);
    end();
    assert(pg->draw_time == 1);
    assert(color(1, 1) == 0xff00ff00 && color(5, 1) == 0xff00ff00);
    groups++;
}
static void array_expansion(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    send_method(NV097_ARRAY_ELEMENT32, 3);
    send_method(NV097_ARRAY_ELEMENT16, 4 | 5u << 16);
    assert(!pg->draw_arrays_length && pg->inline_elements_length == 6);
    end();
    assert(pg->draw_time == 1);
    assert(color(1, 1) == 0xff00ff00 && color(5, 1) == 0xff00ff00);
    // Multiple disconnected draws force the common dispatcher's Flush callback.
    fixture();
    pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    uint32_t params[] = { 2u << 24,
                          NV097_SET_BEGIN_END,
                          0,
                          NV097_SET_BEGIN_END,
                          PRIM_TYPE_TRIANGLES,
                          NV097_DRAW_ARRAYS,
                          3 | 2u << 24,
                          0 };
    assert(method(NV097_DRAW_ARRAYS, params[0], params, 1, 7, false) == 5);
    arrays(3, 3);
    send_method(NV097_ARRAY_ELEMENT32, 0);
    assert(pg->draw_time == 0 && !pg->draw_arrays_length &&
           pg->inline_elements_length == 4);
    send_method(NV097_ARRAY_ELEMENT16, 1 | 2u << 16);
    end();
    assert(pg->draw_time == 1);
    assert(color(1, 1) == 0xff00ff00 && color(5, 1) == 0xff00ff00);
    groups++;
}
static void inline_data(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    const float positions[3][4] = { { 0, 0, 32768, 1 },
                                    { 8, 0, 32768, 1 },
                                    { 0, 8, 32768, 1 } };
    for (unsigned i = 0; i < 3; i++) {
        uint32_t words[4];
        memcpy(words, positions[i], 16);
        assert(method(NV097_SET_VERTEX_DATA4F_M, words[0], words, 4, 0, true) ==
               4);
    }
    assert(pg->inline_buffer_length == 3 &&
           pg->vertex_attributes[0].inline_buffer_populated);
    end();
    assert(pg->draw_time == 1 && !pg->inline_buffer_length);
    assert(color(1, 1) == 0xff00ff00 &&
           pg->vertex_attributes[0].inline_value[1] == 8);
    fixture();
    pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    uint32_t words[12];
    memcpy(words, positions, sizeof(words));
    assert(method(NV097_INLINE_ARRAY, words[0], words, 12, 0, false) == 12);
    end();
    assert(pg->draw_time == 1 && !pg->inline_array_length &&
           color(1, 1) == 0xff00ff00);
    groups++;
}
static void packed_float_immediate_current(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[3].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    pg->vertex_attributes[3].count = 4;
    pg->vertex_attributes[3].size = 4;
    const float data[3][8] = {
        { 0, 0, 32768, 1, 1, 0, 0, 1 },
        { 8, 0, 32768, 1, 0, 0, 1, 1 },
        { 0, 8, 32768, 1, 0, 1, 0, 1 },
    };
    uint32_t words[24];
    memcpy(words, data, sizeof(words));
    begin(PRIM_TYPE_TRIANGLES);
    assert(method(NV097_INLINE_ARRAY, words[0], words, 24, 0, false) == 24);
    NV2AMetalCommands *commands = surfaces.cache.commands;
    id<MTLSharedEvent> gate = [commands.device newSharedEvent];
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
    assert(gate && queue);
    [queue waitForEvent:gate value:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
    end();
    const float green[4] = { 0, 1, 0, 1 };
    assert(!gate.signaledValue && !pg->inline_array_length &&
           !memcmp(pg->vertex_attributes[3].inline_value, green, 16));
    begin(PRIM_TYPE_POINTS);
    const float position[4] = { 4, 4, 32768, 1 };
    uint32_t value[4];
    memcpy(value, position, sizeof(value));
    assert(method(NV097_SET_VERTEX_DATA4F_M, value[0], value, 4, 0, true) == 4);
    assert(pg->inline_buffer_length == 1 &&
           !pg->vertex_attributes[3].inline_buffer_populated);
    const float blue[4] = { 0, 0, 1, 1 };
    memcpy(value, blue, sizeof(value));
    assert(method(NV097_SET_VERTEX_DATA4F_M + 3 * 16, value[0], value, 4, 0,
                  true) == 4);
    /* The real common allocator fills the earlier vertex from Current before
     * the setter replaces it. Both draws are still behind the GPU gate. */
    assert(!gate.signaledValue &&
           pg->vertex_attributes[3].inline_buffer_populated &&
           !memcmp(pg->vertex_attributes[3].inline_buffer, green, 16));
    end();
    assert(!gate.signaledValue && pg->draw_time == 2);
    gate.signaledValue = 1;
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    require([draw flushWithError:&error], error);
    qemu_mutex_unlock(&pg->lock);
    assert(!memcmp(pg->vertex_attributes[3].inline_value, green, 16));
    groups++;
    puts("PGRAPH Float32 InlineArray:real dispatch publishes exact Current and "
         "next SET_VERTEX_DATA4F/common inline allocator copies it before GPU "
         "gate release;both draws finish without producer wait,successful "
         "native completion and Current PASS");
}
static void validation_and_retry(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    assert(![draw flushDrawWithError:&error]);
    assert(![draw endWithError:&error]);
    assert(![draw beginWithError:&error]); /* primitive invalid */
    pg->primitive_mode = PRIM_TYPE_TRIANGLES;
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_FRONTFACEMODE;
    pg->texture_dirty[2] = true;
    pg->surface_color.draw_dirty = true;
    assert(![draw beginWithError:&error] &&
           !surfaces.cache.commands.commandBuffer);
    assert(pg->texture_dirty[2] && pg->surface_color.draw_dirty);
    pg->regs_[NV_PGRAPH_SETUPRASTER] = 0;
    require([draw beginWithError:&error], error);
    assert(![draw beginWithError:&error] && ![draw drawWithError:&error]);
    // Bad input does not complete End; correct and retry this same session.
    pg->draw_arrays_length = 1;
    pg->draw_arrays_start[0] = 0;
    pg->draw_arrays_count[0] = 3;
    dma[2].limit = 46;
    assert(![draw endWithError:&error] && pg->draw_time == 0);
    dma[2].limit = 1023;
    require([draw endWithError:&error], error);
    assert(pg->draw_time == 1);
    pgraph_reset_inline_buffers(pg);
    pg->primitive_mode = PRIM_TYPE_INVALID;
    Error *init_error = NULL;
    void *owner = pg->metal4_renderer_state;
    renderer.ops.init(state, &init_error);
    assert(init_error && pg->metal4_renderer_state == owner);
    error_free(init_error);
    qemu_mutex_unlock(&pg->lock);
    assert(color(1, 1) == 0xff00ff00);
    fixture();
    pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
    pg->zpass_pixel_count_enable = true;
    begin(PRIM_TYPE_TRIANGLES);
    end();
    assert(pg->draw_time == 0);
    groups++;
}
static void flushed_stencil(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE;
    pg->regs_[NV_PGRAPH_CONTROL_1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                     7 << 4 | 0xff << 16 | 0xffu << 24;
    pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 7 << 8;
    cpu_write(4096, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t packed = 0xffffff00;
        memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
    }
    const float left[3][4] = { { 0, 0, 32768, 1 },
                               { 4, 0, 32768, 1 },
                               { 0, 4, 32768, 1 } };
    cpu_write(16384, sizeof(left));
    memcpy(state->vram_ptr + 16384, left, sizeof(left));
    begin(PRIM_TYPE_TRIANGLES);
    uint32_t params[] = { 2u << 24,
                          NV097_SET_BEGIN_END,
                          0,
                          NV097_SET_BEGIN_END,
                          PRIM_TYPE_TRIANGLES,
                          NV097_DRAW_ARRAYS,
                          3 | 2u << 24,
                          0 };
    assert(method(NV097_DRAW_ARRAYS, params[0], params, 1, 7, false) == 5);
    arrays(3, 3);
    send_method(NV097_ARRAY_ELEMENT32, 3);
    send_method(NV097_ARRAY_ELEMENT16, 4 | 5u << 16);
    end();
    assert(pg->draw_time == 1);
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:4096
                                               length:256
                                                write:NO
                                                error:&error],
            error);
    uint32_t a, b;
    memcpy(&a, state->vram_ptr + 4096 + (1 * 8 + 1) * 4, 4);
    memcpy(&b, state->vram_ptr + 4096 + (1 * 8 + 5) * 4, 4);
    /* The first block draws once; the second explicitly submits its triangle
     * twice, through DRAW_ARRAYS and again through ARRAY_ELEMENT. */
    assert(a == 0xffffff01 && b == 0xffffff02);
    groups++;
}
static void process_pending(void)
{
    qemu_mutex_lock(&state->pfifo.lock);
    if (worker_common)
        pgraph_process_pending(state);
    else
        renderer.ops.process_pending(state);
    pgraph_process_pending_reports(state);
    qemu_mutex_unlock(&state->pfifo.lock);
}
static void *service_worker(void *opaque)
{
    assert(opaque == state);
    for (;;) {
        qemu_event_wait(&worker_kick);
        qemu_event_reset(&worker_kick);
        if (qatomic_read(&worker_stop))
            break;
        if (qatomic_read(&worker_pause)) {
            qemu_event_set(&worker_paused);
            qemu_event_wait(&worker_resume);
        }
        process_pending();
    }
    return NULL;
}
static void start_worker(void)
{
    assert(!worker_running);
    worker_stop = false;
    worker_running = true;
    qemu_event_init(&worker_kick, false);
    qemu_thread_create(&worker, "metal-lifecycle-test", service_worker, state,
                       QEMU_THREAD_JOINABLE);
}
static void stop_worker(void)
{
    qatomic_set(&worker_stop, true);
    qemu_event_set(&worker_kick);
    qemu_thread_join(&worker);
    qemu_event_destroy(&worker_kick);
    worker_running = false;
}
static uint32_t raw_color(unsigned x, unsigned y)
{
    uint32_t value;
    memcpy(&value, state->vram_ptr + 1024 + (y * 8 + x) * 4, 4);
    return value;
}
static void deferred_surface_release(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    assert(surfaces.color.dirty && raw_color(1, 1) == 0xffff0000);
    qemu_mutex_lock(&pg->lock);
    NV2AMetalCachedSurface *before = surfaces.color;
    renderer.ops.surface_update(state, false, true, true);
    assert(surfaces.color == before && surfaces.color.dirty &&
           !pg->surface_color.draw_dirty && raw_color(1, 1) == 0xffff0000);
    qemu_mutex_unlock(&pg->lock);
    start_worker();
    hook->func(hook->opaque, hook->mr, 1024 + 36, 4, false);
    assert(raw_color(1, 1) == 0xff00ff00 && !surfaces.color.dirty);
    stop_worker();
    puts("Renderer release: real draw remains GPU-owned until installed CPU "
         "read callback preserves green pixel PASS");
    groups++;
}

static void lifecycle(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    assert(raw_color(1, 1) == 0xffff0000); /* GPU-owned, not yet downloaded. */
    renderer.ops.pre_savevm_trigger(state);
    process_pending();
    renderer.ops.pre_savevm_wait(state);
    assert(raw_color(1, 1) == 0xff00ff00 && !surfaces.color &&
           !surfaces.cache.count);
    assert(!pg->surface_color.draw_dirty && !pg->surface_color.buffer_dirty &&
           pg->draw_time == 1);
    // Repeated save requests complete independently and do not recount End.
    renderer.ops.pre_savevm_trigger(state);
    renderer.ops.pre_shutdown_trigger(state);
    process_pending();
    renderer.ops.pre_savevm_wait(state);
    renderer.ops.pre_shutdown_wait(state);
    assert(pg->draw_time == 1);
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff0000ff;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
    send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
    qemu_mutex_lock(&pg->lock);
    renderer.ops.flip_stall(state);
    qemu_mutex_unlock(&pg->lock);
    assert(surfaces.color.dirty && raw_color(1, 1) == 0xff00ff00);
    qemu_event_reset(&pg->flush_complete);
    qatomic_set(&pg->flush_pending, true);
    process_pending();
    qemu_event_wait(&pg->flush_complete);
    assert(!pg->flush_pending && raw_color(1, 1) == 0xff0000ff &&
           surfaces.color && !surfaces.color.dirty);
    // Scanout can use the clean surface recreated by explicit flush.
    qatomic_set(&pg->sync_pending, true);
    process_pending();
    assert(!pg->sync_pending);
    qemu_mutex_lock(&pg->lock);
    NV2AMetalCachedSurface *before = surfaces.color;
    renderer.ops.surface_update(state, false, true, false);
    assert(surfaces.color == before);
    renderer.ops.surface_update(state, true, true, false);
    assert(surfaces.color);
    renderer.ops.surface_flush(state);
    assert(surfaces.color && surfaces.color != before);
    qemu_mutex_unlock(&pg->lock);
    groups++;
}
static void scale_and_cpu_requests(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    start_worker();
    qemu_mutex_lock(&pg->renderer_lock);
    renderer.ops.set_surface_scale_factor(state, 2);
    assert(renderer.ops.get_surface_scale_factor(state) == 2 &&
           !state->pfifo.halt);
    qemu_mutex_unlock(&pg->renderer_lock);
    assert(raw_color(1, 1) == 0xff00ff00 &&
           g_config.display.quality.surface_scale == 2);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    assert(surfaces.color.transfer.texture.width == 16);
    NSError *error = nil;
    require([surfaces requestCPUAccessAtAddress:1024
                                         length:256
                                          write:NO
                                          error:&error],
            error);
    assert(raw_color(1, 1) == 0xff00ff00);
    qatomic_set(&state->pfifo.halt, true);
    qemu_mutex_lock(&pg->renderer_lock);
    renderer.ops.set_surface_scale_factor(state, 0);
    assert(renderer.ops.get_surface_scale_factor(state) == 1 &&
           state->pfifo.halt);
    qemu_mutex_unlock(&pg->renderer_lock);
    qatomic_set(&state->pfifo.halt, false);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    qemu_mutex_lock(&pg->renderer_lock);
    renderer.ops.set_surface_scale_factor(state, 2);
    qemu_mutex_unlock(&pg->renderer_lock);
    assert(pg->draw_arrays_length == 1 && pg->draw_time == 2);
    end();
    assert(pg->draw_time == 3 && surfaces.color.transfer.texture.width == 16);
    require([surfaces requestCPUAccessAtAddress:1024
                                         length:256
                                          write:YES
                                          error:&error],
            error);
    uint32_t restored = 0xff123456;
    memcpy(state->vram_ptr + 1024, &restored, 4);
    assert(raw_color(0, 0) == restored);
    stop_worker();
    groups++;
}
static void active_block_flush(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    renderer.ops.pre_savevm_trigger(state);
    process_pending();
    renderer.ops.pre_savevm_wait(state);
    assert(pg->draw_time == 0 && pg->draw_arrays_length == 1);
    end();
    assert(pg->draw_time == 1 && color(1, 1) == 0xff00ff00);
    // A clean saved block can be reconstructed from guest state after flush.
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    renderer.ops.pre_savevm_trigger(state);
    process_pending();
    renderer.ops.pre_savevm_wait(state);
    pg->vertex_attributes[3].inline_value[1] = 0;
    pg->vertex_attributes[3].inline_value[2] = 1;
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
    }
    qemu_event_reset(&pg->flush_complete);
    qatomic_set(&pg->flush_pending, true);
    process_pending();
    qemu_event_wait(&pg->flush_complete);
    end();
    assert(pg->draw_time == 2 && color(1, 1) == 0xff0000ff);
    groups++;
}
/* Exercise the common renderer hooks in the same order as nv2a's restore
 * state transition and post_load. Only RAM/device loading itself is simulated;
 * no QEMU VM or application is started. */
static void before_ram_load(void)
{
    start_worker();
    qemu_mutex_lock(&state->pfifo.lock);
    qemu_mutex_lock(&state->pgraph.lock);
    qatomic_set(&state->pfifo.halt, true);
    pgraph_pre_restore_trigger(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    pfifo_kick(state);
    qemu_mutex_unlock(&state->pfifo.lock);
    pgraph_pre_restore_wait(state);
    stop_worker();
    assert(state->pfifo.halt && !surfaces.cache.count && !surfaces.color);
    /* nv2a_pre_load clears the optional subsection before device loading. */
    g_free(state->pgraph.metal4_report_snapshot);
    state->pgraph.metal4_report_snapshot = NULL;
    state->pgraph.metal4_report_snapshot_size = 0;
    g_free(state->pgraph.metal4_vertex_capture);
    state->pgraph.metal4_vertex_capture = NULL;
    state->pgraph.metal4_vertex_capture_size = 0;
    g_free(state->pgraph.metal4_begin_capture);
    state->pgraph.metal4_begin_capture = NULL;
    state->pgraph.metal4_begin_capture_size = 0;
    g_free(state->pgraph.metal4_pending_capture);
    state->pgraph.metal4_pending_capture = NULL;
    state->pgraph.metal4_pending_capture_size = 0;
}
static void after_ram_load(void)
{
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    qemu_event_reset(&pg->flush_complete);
    qatomic_set(&pg->flush_pending, true);
    pgraph_post_load(state);
    qemu_mutex_unlock(&pg->lock);
    process_pending();
    qemu_event_wait(&pg->flush_complete);
    assert(!pg->flush_pending && !surfaces.cache.count && !surfaces.color);
    qatomic_set(&state->pfifo.halt, false);
}
static uint64_t source_version(unsigned address)
{
    NSError *error = nil;
    uint64_t version;
    require([surfaces.cache sourceVersionAtAddress:address
                                            length:1
                                           version:&version
                                             error:&error],
            error);
    return version;
}
static void load_pattern(void)
{
    for (unsigned i = 0; i < 65536; i++)
        state->vram_ptr[i] = (i * 37 + 91) & 255;
}
static void dirty_restore(void)
{
    fixture();
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    NV2AMetalCachedSurface *old = surfaces.color;
    assert(old.dirty && raw_color(1, 1) == 0xffff0000);
    uint64_t version = source_version(1024);
    unsigned writes = notifications;
    before_ram_load();
    assert(!old.valid && notifications > writes &&
           raw_color(1, 1) == 0xff00ff00 && source_version(1024) >= version);
    writes = notifications;
    // Untouched texture-source pages must also get a new generation.
    uint64_t untouched = source_version(61440);
    load_pattern();
    uint8_t saved[65536];
    memcpy(saved, state->vram_ptr, sizeof(saved));
    after_ram_load();
    assert(!memcmp(saved, state->vram_ptr, sizeof(saved)) &&
           source_version(61440) > untouched && notifications == writes);
    qemu_mutex_lock(&state->pgraph.lock);
    renderer.ops.surface_update(state, true, true, false);
    assert(surfaces.color != old && surfaces.color.generation > version);
    renderer.ops.surface_flush(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    assert(!memcmp(saved, state->vram_ptr, sizeof(saved)));
    // Optional restore hooks keep existing renderers' behavior unchanged.
    const PGRAPHRenderer empty = { 0 };
    state->pgraph.renderer = &empty;
    pgraph_pre_restore_trigger(state);
    pgraph_pre_restore_wait(state);
    pgraph_post_load(state);
    state->pgraph.renderer = &renderer;
    groups++;
}
static void cancelled_restore(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff0000ff;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
    send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
    NV2AMetalSurfaceRecording *token = surfaces.cache.recording;
    NV2AMetalCachedSurface *old = surfaces.color;
    assert(token && old.dirty && !token.submitted);
    NSError *error = nil;
    // Pre-restore must preserve pending guest clears if loading later fails.
    require([surfaces.cache prepareGPUReadAtAddress:1024
                                             length:256
                                              error:&error],
            error);
    before_ram_load();
    assert(!token.cancelled && token.submitted && token.completed &&
           !old.valid && raw_color(1, 1) == 0xff0000ff);
    load_pattern();
    uint8_t saved[65536];
    memcpy(saved, state->vram_ptr, sizeof(saved));
    after_ram_load();
    assert(!memcmp(saved, state->vram_ptr, sizeof(saved)));
    // The post-load invalidator itself cancels any unsubmitted obsolete work
    // rather than downloading it into newly loaded RAM.
    fixture();
    pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff0000ff;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
    send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
    token = surfaces.cache.recording;
    require([surfaces.cache prepareGPUReadAtAddress:1024
                                             length:256
                                              error:&error],
            error);
    require([draw discardForRestoreWithError:&error], error);
    assert(token.cancelled && !token.submitted &&
           raw_color(1, 1) == 0xffff0000);
    groups++;
}
static void submitted_download_restore(void)
{
    fixture();
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    NSError *error = nil;
    require([surfaces.cache prepareGPUReadAtAddress:1024
                                             length:256
                                              error:&error],
            error);
    NV2AMetalSurfaceRecording *token = surfaces.cache.recording;
    require([surfaces.cache submitWithError:&error], error);
    assert(token.submitted && !token.completed);
    unsigned writes = notifications;
    before_ram_load();
    assert(token.completed && notifications > writes &&
           raw_color(1, 1) == 0xff00ff00);
    load_pattern();
    uint8_t saved[65536];
    memcpy(saved, state->vram_ptr, sizeof(saved));
    after_ram_load();
    assert(!memcmp(saved, state->vram_ptr, sizeof(saved)));
    groups++;
}
static void restored_active_block(void)
{
    fixture();
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    end();
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    // The old surface is dirty, but the open batch has not drawn yet.
    assert(surfaces.color.dirty && state->pgraph.draw_time == 1);
    before_ram_load();
    // Simulate loaded registers and RAM, leaving the saved input batch intact.
    state->pgraph.vertex_attributes[3].inline_value[1] = 0;
    state->pgraph.vertex_attributes[3].inline_value[2] = 1;
    for (unsigned i = 0; i < 64; i++) {
        uint32_t restored = 0xffffff00;
        memcpy(state->vram_ptr + 1024 + i * 4, &restored, 4);
    }
    after_ram_load();
    assert(raw_color(1, 1) == 0xffffff00 &&
           state->pgraph.draw_arrays_length == 1 &&
           state->pgraph.draw_time == 1);
    end();
    assert(state->pgraph.draw_time == 2 && color(1, 1) == 0xff0000ff &&
           color(7, 7) == 0xffffff00);
    groups++;
}
static void process_reports(void)
{
    qemu_mutex_lock(&state->pfifo.lock);
    pgraph_process_pending_reports(state);
    qemu_mutex_unlock(&state->pfifo.lock);
}
static void get_report(unsigned offset)
{
    send_method(NV097_GET_REPORT,
                NV097_GET_REPORT_TYPE_ZPASS_PIXEL_CNT << 24 | offset);
}
static uint32_t report_result(unsigned offset)
{
    const uint8_t *p = state->vram_ptr + (dma[3].address & 0x07ffffff) + offset;
    assert(ldq_le_p(p) == UINT64_C(0x0011223344556677) &&
           ldl_le_p(p + 12) == 0);
    return ldl_le_p(p + 8);
}
static void query_triangle(unsigned first)
{
    begin(PRIM_TYPE_TRIANGLES);
    arrays(first, 3);
    end();
}
static void report_queue(void)
{
    fixture();
    /* PFIFO dispatches this method with PGRAPH held and PFIFO released. The
     * report callback must not try to acquire PGRAPH a second time. */
    send_method(NV097_SET_CONTEXT_DMA_REPORT, 64);
    assert(state->pgraph.dma_report == 64);
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    query_triangle(0);
    get_report(0);
    query_triangle(3);
    get_report(16);
    send_method(NV097_CLEAR_REPORT_VALUE, 0);
    get_report(32);
    send_method(NV097_SET_CONTEXT_DMA_REPORT, 64);
    assert(report_result(0) == 28 && report_result(16) == 34 &&
           report_result(32) == 0);
    // Clear drops unreported queries; it does not modify report RAM itself.
    query_triangle(0);
    send_method(NV097_CLEAR_REPORT_VALUE, 0);
    get_report(48);
    process_reports();
    assert(report_result(48) == 0 && report_result(16) == 34);
    // NOP and empty blocks do not introduce passing fragments.
    begin(PRIM_TYPE_TRIANGLES);
    end();
    state->pgraph.regs_[NV_PGRAPH_CONTROL_0] = 0;
    query_triangle(0);
    get_report(64);
    process_reports();
    assert(report_result(64) == 0);
    groups++;
}
static void report_rejections(void)
{
    for (unsigned test = 0; test < 6; test++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        if (test == 0) {
            pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE;
            // Never depth comparison rejects every fragment.
        } else if (test == 1) {
            pg->surface_shape.zeta_format = 2;
            pg->surface_zeta.pitch = 32;
            pg->regs_[NV_PGRAPH_CONTROL_1] =
                NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 0xff << 16;
            pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 1 << 8;
            // Never stencil comparison, with valid KEEP operations.
        } else if (test == 2) {
            pg->regs_[NV_PGRAPH_CONTROL_0] |=
                NV_PGRAPH_CONTROL_0_ALPHATESTENABLE | 1 << 8;
            // Never alpha comparison (NV alpha enums begin at one).
        } else if (test == 3) {
            pg->regs_[NV_PGRAPH_WINDOWCLIPX0] = 7 | 7 << 16;
            pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = 7 | 7 << 16;
        } else if (test == 4) {
            // Depth-only pass still counts without color writes.
            pg->regs_[NV_PGRAPH_CONTROL_0] =
                NV_PGRAPH_CONTROL_0_ZENABLE | 7 << 16;
        } else {
            // No color or depth writes, but a passing depth test is not NOP.
            pg->regs_[NV_PGRAPH_CONTROL_0] =
                NV_PGRAPH_CONTROL_0_ZENABLE | 1 << 16;
        }
        query_triangle(0);
        get_report(0);
        process_reports();
        assert(report_result(0) == (test < 4 ? 0 : 28));
    }
    groups++;
}
static void report_flush_and_retry(void)
{
    fixture();
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    qemu_mutex_lock(&state->pgraph.lock);
    renderer.ops.flush_draw(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    get_report(0);
    memset(state->vram_ptr + 32768, 0xaa, 16);
    process_reports();
    assert(report_result(0) == 28); // The submitted prefix is available before End.
    // The common method API normally resets batches after a flush. Set a new
    // independent batch explicitly here to avoid its documented replay case.
    state->pgraph.draw_arrays_length = 0;
    arrays(3, 3);
    qemu_mutex_lock(&state->pgraph.lock);
    NSError *error = nil;
    dma[2].limit = 46;
    assert(![draw endWithError:&error]);
    dma[2].limit = 1023;
    qemu_mutex_unlock(&state->pgraph.lock);
    end();
    process_reports();
    assert(report_result(0) == 28 && state->pgraph.draw_time == 1);
    // Captured query enable survives a guest register change inside Begin.
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 0);
    end();
    get_report(16);
    process_reports();
    assert(report_result(16) == 62);
    groups++;
}
static void report_scale_and_lifecycle(void)
{
    for (unsigned scale = 1; scale <= 3; scale++) {
        fixture();
        state->pgraph.surface_scale_factor = scale;
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        query_triangle(0);
        get_report(0);
        process_reports();
        // The right-angle triangle covers (8s)*(8s-1)/2 samples, divided by s².
        unsigned n = 8 * scale;
        assert(report_result(0) == n * (n - 1) / 2 / (scale * scale));
    }
    for (unsigned aa = 0; aa < 3; aa++) {
        for (unsigned scale = 1; scale <= 2; scale++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            pg->surface_shape.anti_aliasing = aa;
            pg->surface_scale_factor = scale;
            unsigned nx = aa ? 16 : 8, ny = aa == 2 ? 16 : 8;
            pg->surface_color.pitch = nx * 4;
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            query_triangle(0);
            get_report(0);
            process_reports();
            // Independent coverage at physical surface pixel centers. NV2A AA
            // enlarges the surface; it is not Metal attachment multisampling.
            nx *= scale;
            ny *= scale;
            unsigned expected = 0;
            for (unsigned y = 0; y < ny; y++)
                for (unsigned x = 0; x < nx; x++)
                    expected +=
                        (2 * x + 1) * ny + (2 * y + 1) * nx < 2 * nx * ny;
            assert(report_result(0) == expected / (scale * scale));
        }
    }
    fixture();
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    qemu_mutex_lock(&state->pgraph.lock);
    renderer.ops.flush_draw(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    state->pgraph.draw_arrays_length = 0;
    renderer.ops.pre_savevm_trigger(state);
    process_pending();
    renderer.ops.pre_savevm_wait(state);
    arrays(3, 3);
    end();
    get_report(0);
    process_reports();
    assert(report_result(0) == 34);
    query_triangle(0);
    get_report(16);
    before_ram_load();
    memset(state->vram_ptr + 32768, 0xaa, 64);
    after_ram_load();
    process_reports();
    assert(state->vram_ptr[32768 + 16] == 0xaa); // Old report discarded.
    get_report(32);
    process_reports();
    assert(report_result(32) == 0);
    groups++;
}
static void report_alias_and_bounds(void)
{
    fixture();
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    query_triangle(0);
    // Report overlaps the first pixels of a dirty color attachment.
    dma[3].address = 1024;
    uint64_t version = source_version(1024);
    get_report(0);
    process_reports();
    assert(report_result(0) == 28 && raw_color(1, 1) == 0xff00ff00 &&
           surfaces.color.needsUpload && source_version(1024) > version);
    // A too-short DMA must fail before changing RAM or consuming the report.
    NSError *error = nil;
    require([draw.reports getReport:1 << 24 | 32 error:&error], error);
    dma[3].limit = 46;
    uint8_t saved[256];
    memcpy(saved, state->vram_ptr + 1024, sizeof(saved));
    assert(![draw.reports processWithError:&error]);
    assert(!memcmp(saved, state->vram_ptr + 1024, sizeof(saved)));
    dma[3].limit = 1023;
    require([draw.reports processWithError:&error], error);
    assert(report_result(32) == 28);
    assert(![draw.reports getReport:2 << 24 error:&error]);
    groups++;
}
static void synthetic_query(const uint64_t *counts, unsigned n)
{
    // Test host report arithmetic independently of GPU counter generation.
    NV2AMetalPGRAPHQuery *query = [draw.reports beginQuery];
    for (unsigned i = 0; i < n; i++) {
        id<MTLBuffer> buffer = [surfaces.cache.commands.device
            newBufferWithBytes:&counts[i]
                        length:sizeof(counts[i])
                       options:MTLResourceStorageModeShared];
        assert(buffer);
        [draw.reports commitBuffer:buffer query:query];
    }
    [draw.reports endQuery:query];
}
static void report_arithmetic(void)
{
    fixture();
    uint64_t count = UINT32_MAX;
    synthetic_query(&count, 1);
    get_report(0);
    count = (uint64_t)UINT32_MAX + 9;
    synthetic_query(&count, 1);
    get_report(16);
    process_reports();
    assert(report_result(0) == UINT32_MAX && report_result(16) == 7);
    send_method(NV097_CLEAR_REPORT_VALUE, 0);
    state->pgraph.surface_scale_factor = 2;
    const uint64_t two[2] = { 2, 2 };
    synthetic_query(two, 2); // One Begin: floor((2 + 2) / 4) = 1.
    synthetic_query(two, 1);
    synthetic_query(two, 1); // Separate Begins: floor(2 / 4) twice = 0.
    get_report(32);
    process_reports();
    assert(report_result(32) == 1);
    groups++;
}
static void cancelled_restore_before_device_load(void)
{
    fixture();
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    query_triangle(0);
    get_report(0);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(3, 3);
    before_ram_load();
    assert(raw_color(1, 1) == 0xff00ff00 && report_result(0) == 28);
    // Snapshot validation fails before RAM/device load. Resume the old VM.
    qatomic_set(&state->pfifo.halt, false);
    end();
    get_report(16);
    process_reports();
    assert(report_result(16) == 34 && state->pgraph.draw_time == 2);
    groups++;
}
static BOOL reject_capture(unsigned kind, NSData *data, NSError **error)
{
    if (kind == 0)
        return [draw restoreVertexSnapshot:data error:error];
    if (kind == 1)
        return [draw restoreBeginSnapshot:data error:error];
    return [draw restoreReportSnapshot:data error:error];
}
static void restore_rejection_preserves_active_begin(void)
{
    unsigned rejected = 0;
    for (unsigned textured = 0; textured < 2; textured++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        query_triangle(0);
        get_report(0);
        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
        if (textured) {
            cpu_write(49152, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t blue = 0xff0000ff;
                memcpy(state->vram_ptr + 49152 + i * 4, &blue, 4);
            }
            pg->regs_[NV_PGRAPH_TEXFMT0] =
                NV_PGRAPH_TEXFMT0_CONTEXT_DMA |
                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 << 8 | 2 << 6 |
                NV_PGRAPH_TEXFMT0_BORDER_SOURCE | 1 << 16 | 3 << 20 | 3 << 24;
            pg->regs_[NV_PGRAPH_TEXCTL0_0] = NV_PGRAPH_TEXCTL0_0_ENABLE;
            pg->regs_[NV_PGRAPH_TEXCTL1_0] = 32 << 16;
            pg->regs_[NV_PGRAPH_TEXIMAGERECT0] = 8 << 16 | 8;
            pg->regs_[NV_PGRAPH_TEXFILTER0] = 1 << 16 | 1 << 24;
            pg->regs_[NV_PGRAPH_TEXADDRESS0] = 3 | 3 << 8 | 3 << 16;
            pg->regs_[NV_PGRAPH_SHADERPROG] = PS_TEXTUREMODES_PROJECT2D;
            pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_T0;
            pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
                (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
            pg->vertex_attributes[9].inline_value[0] =
                pg->vertex_attributes[9].inline_value[1] = 1.5f;
            pg->texture_dirty[0] = true;
        }
        begin(PRIM_TYPE_TRIANGLES);
        arrays(3, 3);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
        float translate = 4;
        memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3], &translate, 4);
        pg->vsh_constants_dirty[NV_IGRAPH_XF_XFCTX_CMAT0] = true;
        if (textured) {
            cpu_write(49152, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t yellow = 0xffffff00;
                memcpy(state->vram_ptr + 49152 + i * 4, &yellow, 4);
            }
            pg->regs_[NV_PGRAPH_TEXFMT0] = 127u << 8;
        }
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        assert(report_result(0) == 28);
        NSError *error = nil;
        NSData *vertex = [draw vertexSnapshot];
        NSData *begin_capture = [draw beginSnapshotWithError:&error];
        require(begin_capture != nil, error);
        NSData *reports = [draw reportSnapshotWithError:&error];
        require(reports != nil, error);
        NSArray<NSData *> *captures = @[ vertex, begin_capture, reports ];
        assert(vertex.length && begin_capture.length && reports.length);
        for (unsigned kind = 0; kind < 3; kind++) {
            NSData *valid = captures[kind];
            for (NSUInteger length = 0; length < valid.length; length++) {
                @autoreleasepool {
                    NSData *prefix =
                        [valid subdataWithRange:NSMakeRange(0, length)];
                    NSError *failure = nil;
                    assert(!reject_capture(kind, prefix, &failure) && failure);
                    rejected++;
                }
            }
            for (unsigned offset = 0; offset < 12; offset += 4) {
                NSMutableData *bad = [valid mutableCopy];
                unsigned header_offset = kind == 2 && offset == 8 ? 12 : offset;
                stl_be_p((uint8_t *)bad.mutableBytes + header_offset,
                         UINT32_MAX);
                NSError *failure = nil;
                assert(!reject_capture(kind, bad, &failure) && failure);
                rejected++;
            }
        }
        assert([[draw vertexSnapshot] isEqualToData:vertex]);
        assert(
            [[draw beginSnapshotWithError:&error] isEqualToData:begin_capture]);
        assert([[draw reportSnapshotWithError:&error] isEqualToData:reports]);
        // The old Begin remains frozen despite live registers/VRAM changes.
        arrays(0, 3);
        end();
        get_report(16);
        process_reports();
        assert(report_result(16) == 62 && color(1, 1) == 0xff0000ff);
        assert(color(7, 7) == 0xffff0000);
    }
    printf("Metal 4 active restore: %u rejected captures, state and GPU "
           "continuation preserved PASS\n",
           rejected);
    groups++;
}
static void report_snapshot_roundtrip(void)
{
    fixture();
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    query_triangle(0);
    get_report(0);
    process_reports();
    assert(report_result(0) == 28);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(3, 3);
    qemu_mutex_lock(&state->pgraph.lock);
    renderer.ops.flush_draw(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    state->pgraph.draw_arrays_length = 0;
    get_report(16);
    send_method(NV097_CLEAR_REPORT_VALUE, 0);
    start_worker();
    renderer.ops.pre_savevm_trigger(state);
    pfifo_kick(state);
    renderer.ops.pre_savevm_wait(state);
    stop_worker();
    NSData *saved =
        [NSData dataWithBytes:state->pgraph.metal4_report_snapshot
                       length:state->pgraph.metal4_report_snapshot_size];
    assert(saved.length >= 28 && ldl_be_p(saved.bytes) == 0x4d345250);
    arrays(0, 3);
    end();
    get_report(32);
    process_reports();
    assert(report_result(16) == 34 && report_result(32) == 28);
    before_ram_load();
    state->pgraph.primitive_mode = PRIM_TYPE_TRIANGLES;
    state->pgraph.draw_arrays_length = 0;
    g_free(state->pgraph.metal4_report_snapshot);
    state->pgraph.metal4_report_snapshot = g_memdup2(saved.bytes, saved.length);
    state->pgraph.metal4_report_snapshot_size = saved.length;
    after_ram_load();
    arrays(0, 3);
    end();
    get_report(48);
    process_reports();
    assert(report_result(16) == 34 && report_result(48) == 28);
    query_triangle(3);
    get_report(64);
    process_reports();
    assert(report_result(64) == 34);
    groups++;
}
static void report_snapshot_invalid(void)
{
    fixture();
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    query_triangle(0);
    qemu_mutex_lock(&state->pgraph.lock);
    NSError *error = nil;
    NSData *saved = [draw reportSnapshotWithError:&error];
    assert(saved);
    assert(pgraph_metal4_validate_report_snapshot(saved.bytes, saved.length));
    for (NSUInteger size = 0; size < saved.length; size++) {
        NSData *truncated = [saved subdataWithRange:NSMakeRange(0, size)];
        assert(![draw restoreReportSnapshot:truncated error:&error]);
        assert(!pgraph_metal4_validate_report_snapshot(truncated.bytes,
                                                       truncated.length));
        assert([[draw reportSnapshotWithError:&error] isEqualToData:saved]);
    }
    const unsigned offsets[] = { 0, 4, 12, 16, 24, 44, 48, 52 };
    for (unsigned i = 0; i < ARRAY_SIZE(offsets); i++) {
        NSMutableData *bad = [saved mutableCopy];
        if (offsets[i] >= bad.length)
            continue;
        stl_be_p((uint8_t *)bad.mutableBytes + offsets[i], UINT32_MAX);
        assert(![draw restoreReportSnapshot:bad error:&error]);
        assert(!pgraph_metal4_validate_report_snapshot(bad.bytes, bad.length));
        assert([[draw reportSnapshotWithError:&error] isEqualToData:saved]);
    }
    NSMutableData *trailing = [saved mutableCopy];
    uint8_t byte = 0;
    [trailing appendBytes:&byte length:1];
    assert(![draw restoreReportSnapshot:trailing error:&error]);
    /* A closed query cannot become active or lose its unique list owner. */
    assert(saved.length == 56);
    NSMutableData *closedActive = [saved mutableCopy];
    stl_be_p((uint8_t *)closedActive.mutableBytes + 20, 0);
    assert(![draw restoreReportSnapshot:closedActive error:&error]);
    NSMutableData *orphan = [saved mutableCopy];
    orphan.length = 52;
    stl_be_p((uint8_t *)orphan.mutableBytes + 48, 0);
    assert(![draw restoreReportSnapshot:orphan error:&error]);
    /* The same query in pending and a report would count its samples twice. */
    NSMutableData *duplicate = [saved mutableCopy];
    stl_be_p((uint8_t *)duplicate.mutableBytes + 16, 1);
    uint32_t report[] = {
        0, cpu_to_be32(NV097_GET_REPORT_TYPE_ZPASS_PIXEL_CNT << 24),
        cpu_to_be32(1), 0
    };
    [duplicate appendBytes:report length:sizeof(report)];
    assert(![draw restoreReportSnapshot:duplicate error:&error]);
    assert([[draw reportSnapshotWithError:&error] isEqualToData:saved]);
    for (unsigned scale = 0; scale <= 16385; scale += 16385) {
        NSMutableData *bad = [saved mutableCopy];
        stl_be_p((uint8_t *)bad.mutableBytes + 24, scale);
        assert(![draw restoreReportSnapshot:bad error:&error]);
        assert([[draw reportSnapshotWithError:&error] isEqualToData:saved]);
    }
    /* Version 1 lacks scale metadata and retains the live scale. */
    NSMutableData *legacy = [saved mutableCopy];
    [legacy replaceBytesInRange:NSMakeRange(36, 8) withBytes:NULL length:0];
    [legacy replaceBytesInRange:NSMakeRange(24, 4) withBytes:NULL length:0];
    stl_be_p((uint8_t *)legacy.mutableBytes + 4, 1);
    state->pgraph.surface_scale_factor = 2;
    require([draw restoreReportSnapshot:legacy error:&error], error);
    assert(state->pgraph.surface_scale_factor == 2);
    require([draw restoreReportSnapshot:saved error:&error], error);
    assert(state->pgraph.surface_scale_factor == 1);
    qemu_mutex_unlock(&state->pgraph.lock);
    get_report(0);
    process_reports();
    assert(report_result(0) == 28);
    groups++;
}
static void report_snapshot_scale(void)
{
    for (unsigned saved_scale = 1; saved_scale <= 3; saved_scale++) {
        for (unsigned live_scale = 1; live_scale <= 3; live_scale++) {
            fixture();
            state->pgraph.surface_scale_factor = saved_scale;
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            query_triangle(0);
            get_report(0);
            process_reports();
            begin(PRIM_TYPE_TRIANGLES);
            arrays(3, 3);
            qemu_mutex_lock(&state->pgraph.lock);
            renderer.ops.flush_draw(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            state->pgraph.draw_arrays_length = 0;
            get_report(16);
            renderer.ops.pre_savevm_trigger(state);
            process_pending();
            renderer.ops.pre_savevm_wait(state);
            NSData *saved = [NSData
                dataWithBytes:state->pgraph.metal4_report_snapshot
                       length:state->pgraph.metal4_report_snapshot_size];
            assert(ldl_be_p((const uint8_t *)saved.bytes + 4) == 3 &&
                   (uint32_t)ldl_be_p((const uint8_t *)saved.bytes + 24) ==
                       saved_scale);
            before_ram_load();
            state->pgraph.surface_scale_factor = live_scale;
            g_config.display.quality.surface_scale = live_scale;
            state->pgraph.metal4_report_snapshot =
                g_memdup2(saved.bytes, saved.length);
            state->pgraph.metal4_report_snapshot_size = saved.length;
            after_ram_load();
            assert(state->pgraph.surface_scale_factor == saved_scale);
            assert(g_config.display.quality.surface_scale == (int)live_scale);
            arrays(0, 3);
            end();
            get_report(32);
            process_reports();
            unsigned large = 8 * saved_scale, small = 4 * saved_scale;
            unsigned large_count = large * (large - 1) / 2;
            unsigned small_count = small * (small - 1) / 2;
            unsigned divisor = saved_scale * saved_scale;
            assert(report_result(16) ==
                   large_count / divisor + small_count / divisor);
            assert(report_result(32) ==
                   large_count / divisor +
                       (small_count + large_count) / divisor);
        }
    }
    groups++;
}
static void report_snapshot_cleared_active(void)
{
    fixture();
    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
    begin(PRIM_TYPE_TRIANGLES);
    arrays(0, 3);
    qemu_mutex_lock(&state->pgraph.lock);
    renderer.ops.flush_draw(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    state->pgraph.draw_arrays_length = 0;
    send_method(NV097_CLEAR_REPORT_VALUE, 0);
    renderer.ops.pre_savevm_trigger(state);
    process_pending();
    renderer.ops.pre_savevm_wait(state);
    NSData *saved =
        [NSData dataWithBytes:state->pgraph.metal4_report_snapshot
                       length:state->pgraph.metal4_report_snapshot_size];
    assert(pgraph_metal4_validate_report_snapshot(saved.bytes, saved.length));
    end();
    get_report(0);
    process_reports();
    assert(report_result(0) == 0);
    before_ram_load();
    state->pgraph.primitive_mode = PRIM_TYPE_TRIANGLES;
    state->pgraph.draw_arrays_length = 0;
    state->pgraph.metal4_report_snapshot = g_memdup2(saved.bytes, saved.length);
    state->pgraph.metal4_report_snapshot_size = saved.length;
    after_ram_load();
    arrays(0, 3);
    end();
    get_report(16);
    process_reports();
    assert(report_result(16) == 28);
    query_triangle(3);
    get_report(32);
    process_reports();
    assert(report_result(32) == 34);
    groups++;
}
/* Use the production subsection with the base fields that its decoder needs.
 * Full PCI/VGA/RAM migration is deliberately outside this isolated test. */
#pragma clang diagnostic push
/* QEMU's VMSTATE macros use null pointer subtraction for type checking. */
#pragma clang diagnostic ignored "-Wnull-pointer-subtraction"
static const VMStateDescription vertex_snapshot_parent = {
    .name = "nv2a",
    .version_id = 4,
    .minimum_version_id = 1,
    .fields =
        (VMStateField[]){
            VMSTATE_UINT32(pgraph.primitive_mode, NV2AState),
            VMSTATE_UINT32(pgraph.inline_buffer_length, NV2AState),
            VMSTATE_BOOL(pgraph.surface_color.buffer_dirty, NV2AState),
            VMSTATE_BOOL(pgraph.surface_zeta.buffer_dirty, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.z_format, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.color_format, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.zeta_format, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.log_width, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.log_height, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_x, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_y, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_width, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_height, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.anti_aliasing, NV2AState),
            VMSTATE_END_OF_LIST() },
    .subsections =
        (const VMStateDescription *const[]){
            &vmstate_nv2a_metal4_vertices, &vmstate_nv2a_metal4_vertex_capture,
            &vmstate_nv2a_metal4_begin_capture,
            &vmstate_nv2a_metal4_pending_capture, NULL },
};
/* Array tests retain the production base fields as well as the native
 * subsections. Only eight live element indices are needed by these fixtures;
 * this compact parent is not the complete PCI/RAM migration wire format. */
static const VMStateDescription array_snapshot_parent = {
    .name = "nv2a",
    .version_id = 4,
    .minimum_version_id = 1,
    .fields =
        (VMStateField[]){
            VMSTATE_UINT32(pgraph.primitive_mode, NV2AState),
            VMSTATE_UINT32(pgraph.inline_buffer_length, NV2AState),
            VMSTATE_BOOL(pgraph.surface_color.buffer_dirty, NV2AState),
            VMSTATE_BOOL(pgraph.surface_zeta.buffer_dirty, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.z_format, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.color_format, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.zeta_format, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.log_width, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.log_height, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_x, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_y, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_width, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.clip_height, NV2AState),
            VMSTATE_UINT32(pgraph.last_surface_shape.anti_aliasing, NV2AState),
            VMSTATE_UINT32(pgraph.inline_elements_length, NV2AState),
            VMSTATE_UINT32_SUB_ARRAY(pgraph.inline_elements, NV2AState, 0, 8),
            VMSTATE_UINT32(pgraph.draw_arrays_length, NV2AState),
            VMSTATE_UINT32(pgraph.draw_arrays_max_count, NV2AState),
            VMSTATE_INT32_ARRAY(pgraph.draw_arrays_start, NV2AState, 1250),
            VMSTATE_INT32_ARRAY(pgraph.draw_arrays_count, NV2AState, 1250),
            VMSTATE_END_OF_LIST() },
    .subsections =
        (const VMStateDescription *const[]){
            &vmstate_nv2a_metal4_vertices, &vmstate_nv2a_metal4_vertex_capture,
            &vmstate_nv2a_metal4_begin_capture,
            &vmstate_nv2a_metal4_pending_capture, NULL },
};
#pragma clang diagnostic pop
static QEMUFile *vertex_snapshot_file(int fd, bool write)
{
    int copy = dup(fd);
    assert(copy >= 0 && lseek(copy, 0, SEEK_SET) == 0);
    if (write)
        assert(ftruncate(copy, 0) == 0);
    QIOChannel *channel = QIO_CHANNEL(qio_channel_file_new_fd(copy));
    QEMUFile *file =
        write ? qemu_file_new_output(channel) : qemu_file_new_input(channel);
    object_unref(OBJECT(channel));
    return file;
}
static void save_snapshot_parent(int fd, const VMStateDescription *parent)
{
    QEMUFile *file = vertex_snapshot_file(fd, true);
    Error *error = NULL;
    qemu_mutex_lock(&state->pgraph.lock);
    assert(vmstate_save_state(file, parent, state, NULL, &error) == 0 &&
           !error);
    qemu_mutex_unlock(&state->pgraph.lock);
    qemu_put_byte(file, 0);
    assert(qemu_fclose(file) == 0);
}
static int load_snapshot_parent(int fd, const VMStateDescription *parent)
{
    QEMUFile *file = vertex_snapshot_file(fd, false);
    Error *error = NULL;
    qemu_mutex_lock(&state->pgraph.lock);
    int result = vmstate_load_state(file, parent, state, 4, &error);
    qemu_mutex_unlock(&state->pgraph.lock);
    error_free(error);
    qemu_fclose(file);
    return result;
}
static void save_vertex_snapshot(int fd)
{
    save_snapshot_parent(fd, &vertex_snapshot_parent);
}
static int load_vertex_snapshot(int fd)
{
    return load_snapshot_parent(fd, &vertex_snapshot_parent);
}
static int new_vertex_snapshot_file(void)
{
    char path[] = "/tmp/xemu-metal4-vertices.XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0 && unlink(path) == 0);
    return fd;
}
static void inline_position(float x, float y)
{
    float position[4] = { x, y, 32768, 1 };
    uint32_t words[4];
    memcpy(words, position, sizeof(words));
    assert(method(NV097_SET_VERTEX_DATA4F_M, words[0], words, 4, 0, true) == 4);
}
static void vertex_snapshot_open_block(void)
{
    fixture();
    begin(PRIM_TYPE_TRIANGLES);
    inline_position(0, 0);
    inline_position(8, 0);
    int fd = new_vertex_snapshot_file();
    save_vertex_snapshot(fd);
    end();
    before_ram_load();
    PGRAPHState *pg = &state->pgraph;
    for (unsigned i = 0; i < 16; i++) {
        float *buffer = pg->vertex_attributes[i].inline_buffer;
        memset(buffer, 0xa5, 64 * sizeof(float));
        memset(&pg->vertex_attributes[i], 0, sizeof(VertexAttribute));
        pg->vertex_attributes[i].inline_buffer = buffer;
    }
    assert(load_vertex_snapshot(fd) == 0);
    assert(pg->primitive_mode == PRIM_TYPE_TRIANGLES &&
           pg->inline_buffer_length == 2);
    after_ram_load();
    inline_position(0, 8);
    end();
    assert(color(1, 1) == 0xff00ff00 && color(7, 7) == 0xffff0000);
    close(fd);
    groups++;
}
static void vertex_snapshot_invalid(void)
{
    fixture();
    begin(PRIM_TYPE_TRIANGLES);
    inline_position(0, 0);
    inline_position(8, 0);
    PGRAPHState *pg = &state->pgraph;
    const uint32_t float_bits[] = { 0x80000000, 0x7fc12345, 0x7f800000,
                                    0xff800000 };
    memcpy(pg->vertex_attributes[15].inline_value, float_bits, 16);
    pg->compressed_attrs = 0x8000;
    pg->uniform_attrs = 0x1234;
    pg->swizzle_attrs = 0xabcd;
    pg->draw_arrays_min_start = UINT32_MAX;
    pg->draw_arrays_prevent_connect = true;
    pg->enable_vertex_program_write = true;
    size_t fixed_start = offsetof(PGRAPHState, material_alpha);
    size_t fixed_bytes = offsetof(PGRAPHState, point_params) +
                         sizeof(pg->point_params) - fixed_start;
    assert(fixed_bytes == 480);
    for (unsigned i = 0; i < fixed_bytes / 4; i++)
        memcpy((uint8_t *)pg + fixed_start + i * 4, &float_bits[i % 4], 4);
    pg->texture_matrix_enable[1] = pg->texture_matrix_enable[3] = true;
    uint8_t saved_fixed[480];
    memcpy(saved_fixed, (uint8_t *)pg + fixed_start, fixed_bytes);
    VertexAttribute attributes[16];
    memcpy(attributes, pg->vertex_attributes, sizeof(attributes));
    float positions[8];
    memcpy(positions, attributes[0].inline_buffer, sizeof(positions));
    int fd = new_vertex_snapshot_file();
    save_vertex_snapshot(fd);
    off_t length = lseek(fd, 0, SEEK_END);
    unsigned prefix = 50 + 2 + strlen(vmstate_nv2a_metal4_vertices.name) + 4;
    assert(length == prefix + 1293); // v4 adds the live WriteEnable policy.
    uint8_t wire[1369];
    assert(length == sizeof(wire));
    assert(pread(fd, wire, sizeof(wire), 0) == sizeof(wire));
    pg->enable_vertex_program_write = false;
    /* A missing optional section is a valid legacy stream. Once its full
     * header is present, every incomplete vertex payload must fail. */
    for (off_t cut = prefix; cut < length - 1; cut++) {
        assert(ftruncate(fd, cut) == 0 && pwrite(fd, wire, cut, 0) == cut);
        assert(load_vertex_snapshot(fd) < 0);
        assert(!pg->enable_vertex_program_write);
        assert(!memcmp(attributes, pg->vertex_attributes, sizeof(attributes)));
        assert(
            !memcmp(positions, attributes[0].inline_buffer, sizeof(positions)));
        assert(pg->compressed_attrs == 0x8000 && pg->uniform_attrs == 0x1234 &&
               pg->swizzle_attrs == 0xabcd && pg->draw_arrays_prevent_connect &&
               pg->draw_arrays_min_start == UINT32_MAX);
        assert(!memcmp(saved_fixed, (uint8_t *)pg + fixed_start, fixed_bytes));
        assert(pg->texture_matrix_enable[1] && pg->texture_matrix_enable[3]);
    }
    const unsigned offsets[] = { 4, 8, 22, 23, 36, 40, 44, 48, 68, 69,
                                 1286, 1291 };
    for (unsigned i = 0; i < ARRAY_SIZE(offsets); i++) {
        uint8_t bad[1369];
        memcpy(bad, wire, sizeof(bad));
        bad[prefix + offsets[i]] = 0xff;
        assert(ftruncate(fd, 0) == 0 &&
               pwrite(fd, bad, sizeof(bad), 0) == sizeof(bad));
        assert(load_vertex_snapshot(fd) < 0);
        assert(!pg->enable_vertex_program_write);
        assert(!memcmp(attributes, pg->vertex_attributes, sizeof(attributes)));
        assert(!memcmp(saved_fixed, (uint8_t *)pg + fixed_start, fixed_bytes));
    }
    assert(ftruncate(fd, 0) == 0 &&
           pwrite(fd, wire, sizeof(wire), 0) == sizeof(wire));
    pg->vertex_attributes[15].inline_value[0] = 1;
    pg->compressed_attrs = pg->uniform_attrs = pg->swizzle_attrs = 0;
    memset((uint8_t *)pg + fixed_start, 0, fixed_bytes);
    memset(pg->texture_matrix_enable, 0, sizeof(pg->texture_matrix_enable));
    assert(load_vertex_snapshot(fd) == 0);
    assert(pg->enable_vertex_program_write);
    assert(!memcmp(pg->vertex_attributes[15].inline_value, float_bits, 16));
    assert(pg->compressed_attrs == 0x8000 && pg->uniform_attrs == 0x1234 &&
           pg->swizzle_attrs == 0xabcd);
    assert(!memcmp(saved_fixed, (uint8_t *)pg + fixed_start, fixed_bytes));
    assert(pg->texture_matrix_enable[1] && pg->texture_matrix_enable[3]);
    /* Versions 1..3 have no live WriteEnable field. Preserve either value;
     * their streams cannot reconstruct a policy they never saved. */
    for (unsigned writes = 0; writes < 2; writes++) {
        uint8_t v3[1368];
        memcpy(v3, wire, sizeof(v3) - 1);
        v3[sizeof(v3) - 1] = 0;
        stl_be_p(v3 + prefix + 4, 3);
        pg->enable_vertex_program_write = writes;
        assert(ftruncate(fd, 0) == 0 &&
               pwrite(fd, v3, sizeof(v3), 0) == sizeof(v3));
        assert(load_vertex_snapshot(fd) == 0 &&
               pg->enable_vertex_program_write == writes);
        assert(!memcmp(saved_fixed, (uint8_t *)pg + fixed_start, fixed_bytes));
        /* Version 2 omitted back alpha. Its defined reset value is zero. */
        uint8_t v2[1364];
        memcpy(v2, wire, sizeof(v2) - 1);
        v2[sizeof(v2) - 1] = 0;
        stl_be_p(v2 + prefix + 4, 2);
        pg->material_alpha_back = .75f;
        assert(ftruncate(fd, 0) == 0 &&
               pwrite(fd, v2, sizeof(v2), 0) == sizeof(v2));
        assert(load_vertex_snapshot(fd) == 0 && pg->material_alpha_back == 0 &&
               pg->enable_vertex_program_write == writes);
        uint8_t legacy[876];
        memcpy(legacy, wire, prefix);
        memcpy(legacy + prefix, wire + prefix + 8, 799);
        legacy[sizeof(legacy) - 1] = 0;
        pg->material_alpha = .375f;
        assert(ftruncate(fd, 0) == 0 &&
               pwrite(fd, legacy, sizeof(legacy), 0) == sizeof(legacy));
        assert(load_vertex_snapshot(fd) == 0 && pg->material_alpha == .375f &&
               pg->enable_vertex_program_write == writes);
    }
    close(fd);
    groups++;
    puts("Vertex snapshot v4:1292 payload truncations and12 corrupt fields "
         "rejected atomically; WriteEnable restored, v1/v2/v3 preserve "
         "both absent policy values PASS");
}
static NV2AMetalVertex fixed_snapshot_vertex(void)
{
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.cache.commands;
    NV2AMetalPGRAPHVertexState *captured =
        [[NV2AMetalPGRAPHVertexState alloc] initWithState:&state->pgraph
                                                    error:&error];
    require(captured != nil, error);
    assert(captured.fixedUniforms.texture_matrix_enable[2]);
    NV2AMetalVertexFixed *fixed =
        [[NV2AMetalVertexFixed alloc] initWithDevice:commands.device
                                               error:&error];
    require(fixed != nil, error);
    NV2AMetalProgramInput input = { 0 };
    input.attributes[NV2A_VERTEX_ATTR_POSITION][0] = 2;
    input.attributes[NV2A_VERTEX_ATTR_POSITION][1] = 2;
    input.attributes[NV2A_VERTEX_ATTR_POSITION][3] = 1;
    input.attributes[NV2A_VERTEX_ATTR_NORMAL][2] = 1;
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:&input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(buffer);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalPGRAPHVertexResult *encoded = [captured encodeAttributes:buffer
                                                                count:1
                                                              program:nil
                                                                fixed:fixed
                                                             commands:commands
                                                                error:&error];
    require(encoded != nil, error);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    NV2AMetalVertex vertex;
    memcpy(&vertex, encoded.vertices.contents, sizeof(vertex));
    return vertex;
}
static void back_material_methods(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    for (unsigned combination = 0; combination < 6561; combination++) {
        unsigned value = combination, parameter = 0;
        unsigned sources[8];
        for (unsigned field = 0; field < 8; field++) {
            sources[field] = value % 3;
            value /= 3;
            parameter |= sources[field] << (2 * field);
        }
        pg->regs_[NV_PGRAPH_CSV0_C] = 0xa805a500;
        send_method(NV097_SET_COLOR_MATERIAL, parameter);
        unsigned csv = pg->regs_[NV_PGRAPH_CSV0_C];
        const unsigned masks[] = {
            NV_PGRAPH_CSV0_C_EMISSION,      NV_PGRAPH_CSV0_C_AMBIENT,
            NV_PGRAPH_CSV0_C_DIFFUSE,       NV_PGRAPH_CSV0_C_SPECULAR,
            NV_PGRAPH_CSV0_C_BACK_EMISSION, NV_PGRAPH_CSV0_C_BACK_AMBIENT,
            NV_PGRAPH_CSV0_C_BACK_DIFFUSE,  NV_PGRAPH_CSV0_C_BACK_SPECULAR
        };
        unsigned all = 0;
        for (unsigned field = 0; field < 8; field++) {
            assert(GET_MASK(csv, masks[field]) == sources[field]);
            all |= masks[field];
        }
        assert((csv & ~all) == (0xa805a500 & ~all));
    }
    for (unsigned enable = 0; enable < 2; enable++) {
        pg->regs_[NV_PGRAPH_SETUPRASTER] = 0x10800421;
        pg->regs_[NV_PGRAPH_CSV0_C] = 0xc805a500;
        send_method(NV097_SET_LIGHT_TWO_SIDE_ENABLE, enable);
        assert(pg->regs_[NV_PGRAPH_SETUPRASTER] ==
               (0x10800421 | (enable << 24)));
        assert(pg->regs_[NV_PGRAPH_CSV0_C] == (0xc805a500 | (enable << 29)));
    }
    groups++;
    puts("Metal4 back material methods: 6561 combinations and 2 enable states "
         "PASS");
}

static void fixed_snapshot_shader(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CSV0_C] = NV_PGRAPH_CSV0_C_LIGHTING |
                                  NV_PGRAPH_CSV0_C_SPECULAR_ENABLE |
                                  NV_PGRAPH_CSV0_C_SEPARATE_SPECULAR;
    SET_MASK(pg->regs_[NV_PGRAPH_CSV0_D], NV_PGRAPH_CSV0_D_LIGHT0 << 14,
             NV_PGRAPH_CSV0_D_LIGHT0_INFINITE);
    pg->regs_[NV_PGRAPH_CSV0_D] |= NV_PGRAPH_CSV0_D_POINTPARAMSENABLE;
    for (unsigned i = 0; i < 4; i++) {
        for (unsigned j = 0; j < 4; j++) {
            float value = i == j;
            memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_MMAT0 + i][j], &value,
                   4);
            memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_IMMAT0 + i][j], &value,
                   4);
        }
    }
    send_method(NV097_SET_LIGHT_TWO_SIDE_ENABLE, 1);
    const float back_alpha = .625f;
    uint32_t back_word;
    memcpy(&back_word, &back_alpha, 4);
    send_method(NV097_SET_BACK_MATERIAL_ALPHA, back_word);
    const float back_ambient[] = { .125f, .25f, .375f };
    const float back_emission[] = { .5f, .25f, .125f };
    for (unsigned k = 0; k < 3; k++) {
        memcpy(&back_word, &back_ambient[k], 4);
        send_method(NV097_SET_BACK_SCENE_AMBIENT_COLOR + k * 4, back_word);
        memcpy(&back_word, &back_emission[k], 4);
        send_method(NV097_SET_BACK_MATERIAL_EMISSION + k * 4, back_word);
    }
    pg->light_infinite_direction[7][2] = 2;
    pg->light_infinite_half_vector[7][2] = .5f;
    const float diffuse[3] = { .25f, .5f, .125f };
    const float specular[3] = { .4f, .2f, .1f };
    memcpy(pg->ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF + 6 * 7], diffuse, 12);
    memcpy(pg->ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * 7], specular, 12);
    pg->specular_power = 2;
    pg->specular_params[2] = 2;
    pg->material_alpha = .375f;
    pg->point_params[0] = 1;
    pg->point_params[3] = 4;
    pg->point_params[7] = 1;
    pg->texture_matrix_enable[2] = true;
    begin(PRIM_TYPE_TRIANGLES);
    qemu_mutex_lock(&pg->lock);
    NV2AMetalVertex original = fixed_snapshot_vertex();
    qemu_mutex_unlock(&pg->lock);
    assert(fabsf(original.color[0][0] - .25f) < 1e-6f &&
           fabsf(original.color[0][1] - .5f) < 1e-6f &&
           original.color[0][3] == .375f && original.point_size == 5 &&
           fabsf(original.color[1][0] - .1f) < 1e-6f);
    assert(original.color[2][3] == .625f);
    for (unsigned k = 0; k < 3; k++)
        assert(fabsf(original.color[2][k] -
                     back_ambient[k] * (1 + back_emission[k])) < 1e-6f);
    int fd = new_vertex_snapshot_file();
    save_vertex_snapshot(fd);
    end();
    before_ram_load();
    size_t start = offsetof(PGRAPHState, material_alpha);
    size_t bytes =
        offsetof(PGRAPHState, point_params) + sizeof(pg->point_params) - start;
    memset((uint8_t *)pg + start, 0, bytes);
    memset(pg->texture_matrix_enable, 0, sizeof(pg->texture_matrix_enable));
    assert(load_vertex_snapshot(fd) == 0);
    after_ram_load();
    qemu_mutex_lock(&pg->lock);
    renderer.ops.flush_draw(state); // Reconstruct Begin and prepare surfaces.
    NV2AMetalVertex restored = fixed_snapshot_vertex();
    qemu_mutex_unlock(&pg->lock);
    assert(!memcmp(original.color, restored.color, sizeof(original.color)) &&
           original.point_size == restored.point_size);
    end();
    close(fd);
    groups++;
}

static void point_sprite_begin_snapshot(void)
{
    unsigned cases = 0;
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned kind = 0; kind < 4; kind++)
            for (unsigned enabled = 0; enabled < 2; enabled++)
                for (unsigned operation = 0; operation < 4; operation++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    const float texcoord[] = { .125f, .25f, .5f, 1 };
                    const float positions[][4] = { { 2.5f, 2.5f, 32768, 1 },
                                                   { 6.5f, 2.5f, 32768, 1 },
                                                   { 2.5f, 6.5f, 32768, 1 } };
                    cpu_write(16384, sizeof(positions));
                    memcpy(state->vram_ptr + 16384, positions,
                           sizeof(positions));
                    send_method(NV097_SET_POINT_SIZE, 32);
                    send_method(NV097_SET_POINT_SMOOTH_ENABLE, enabled);
                    send_method(NV097_SET_FRONT_POLYGON_MODE,
                                kind == 3 ?
                                    NV097_SET_FRONT_POLYGON_MODE_V_POINT :
                                    NV097_SET_FRONT_POLYGON_MODE_V_FILL);
                    send_method(NV097_SET_BACK_POLYGON_MODE,
                                kind == 3 ?
                                    NV097_SET_FRONT_POLYGON_MODE_V_POINT :
                                    NV097_SET_FRONT_POLYGON_MODE_V_FILL);
                    send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                PS_TEXTUREMODES_PASSTHRU << 15);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                PS_REGISTER_T3);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                (PS_REGISTER_T3 | PS_CHANNEL_ALPHA) << 8);
                    if (programmed) {
                        pg->regs_[NV_PGRAPH_CSV0_D] =
                            2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                        pg->program_data[0][1] = 1 << 21 | 27;
                        pg->program_data[0][2] = 2u << 26;
                        pg->program_data[0][3] = 1 << 11 | 15 << 12;
                        pg->program_data[1][1] = 1 << 21 | 5 << 13 | 27;
                        pg->program_data[1][2] = 3u << 26;
                        pg->program_data[1][3] =
                            1 << 11 | 12 << 3 | 15 << 12 | 1;
                        memcpy(pg->vsh_constants[5], texcoord,
                               sizeof(texcoord));
                    } else {
                        memcpy(pg->vertex_attributes[12].inline_value, texcoord,
                               sizeof(texcoord));
                    }
                    unsigned primitive = kind == 0 ? PRIM_TYPE_POINTS :
                                         kind == 1 ? PRIM_TYPE_LINES :
                                                     PRIM_TYPE_TRIANGLES;
                    unsigned count = kind == 0 ? 1 : kind == 1 ? 2 : 3;
                    unsigned y = kind == 1 ? 2 : 3;
                    uint32_t expected = enabled && (kind == 0 || kind == 3) ?
                                            0xffbfbfff :
                                            0xff204080;
                    begin(primitive);
                    arrays(0, count);
                    send_method(NV097_SET_POINT_SMOOTH_ENABLE, !enabled);
                    send_method(NV097_SET_POINT_SIZE, 8);
                    send_method(NV097_SET_FRONT_POLYGON_MODE,
                                kind == 3 ?
                                    NV097_SET_FRONT_POLYGON_MODE_V_FILL :
                                    NV097_SET_FRONT_POLYGON_MODE_V_POINT);
                    send_method(NV097_SET_BACK_POLYGON_MODE,
                                kind == 3 ?
                                    NV097_SET_FRONT_POLYGON_MODE_V_FILL :
                                    NV097_SET_FRONT_POLYGON_MODE_V_POINT);
                    if (operation == 3)
                        send_method(NV097_CLEAR_SURFACE, 0);
                    if (operation >= 2) {
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        int fd = new_vertex_snapshot_file();
                        save_vertex_snapshot(fd);
                        const uint8_t *pixel = pg->metal4_begin_capture + 48;
                        size_t flag = 25 * 4 + offsetof(NV2AMetalPixelUniforms,
                                                        point_sprite);
                        assert(ldl_be_p(pixel + 4) == 6 &&
                               (uint32_t)ldl_be_p(pixel + flag) == enabled);
                        end();
                        assert(color(3, y) == expected);
                        before_ram_load();
                        assert(load_vertex_snapshot(fd) == 0);
                        after_ram_load();
                        arrays(0, count);
                        close(fd);
                    } else if (operation == 1) {
                        qemu_mutex_lock(&pg->lock);
                        renderer.ops.flush_draw(state);
                        qemu_mutex_unlock(&pg->lock);
                        arrays(0, count);
                    }
                    end();
                    if (color(3, y) != expected) {
                        fprintf(
                            stderr,
                            "PointSprite Begin programmed=%u kind=%u "
                            "enabled=%u operation=%u got=%08x expected=%08x\n",
                            programmed, kind, enabled, operation, color(3, y),
                            expected);
                        abort();
                    }
                    groups++;
                    cases++;
                }
    assert(cases == 64);
    printf("Metal4 point-sprite frozen Begin/flush/save/restore/clear: %u GPU "
           "cases PASS\n",
           cases);
}

/* Guest methods -> frozen TEX3/point state -> native draw -> raw VRAM.
 * Restored RAM deliberately contains a different image from the captured
 * texture. The compact migration parent is not a complete VM migration. */
static void rectangle_point_sprite_begin_snapshot(void)
{
    unsigned cases = 0, restores = 0, pixels = 0;
    for (unsigned shape = 0; shape < 2; shape++)
        for (unsigned linear = 0; linear < 2; linear++)
            for (unsigned enabled = 0; enabled < 2; enabled++)
                for (unsigned polygon = 0; polygon < 2; polygon++)
                    for (unsigned programmed = 0; programmed < 2; programmed++)
                        for (unsigned operation = 0; operation < 4;
                             operation++) {
                            fixture();
                            PGRAPHState *pg = &state->pgraph;
                            unsigned width = shape ? 7 : 3,
                                     height = shape ? 2 : 5;
                            unsigned pitch = (width + 4) * 4, slot = 3 * 64;
                            cpu_write(49152, pitch * height);
                            memset(state->vram_ptr + 49152, 0xd3,
                                   pitch * height);
                            for (unsigned y = 0; y < height; y++)
                                for (unsigned x = 0; x < width; x++) {
                                    uint32_t texel = (96 + 16 * x + 8 * y)
                                                         << 24 |
                                                     (16 + 32 * x) << 16 |
                                                     (16 + 32 * y) << 8 |
                                                     (32 + 16 * x + 16 * y);
                                    stl_le_p(state->vram_ptr + 49152 +
                                                 y * pitch + x * 4,
                                             texel);
                                }
                            uint32_t format = 0;
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
                            SET_MASK(
                                format, NV097_SET_TEXTURE_FORMAT_COLOR,
                                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                                     2);
                            SET_MASK(
                                format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                                NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                            send_method(NV097_SET_TEXTURE_OFFSET + slot, 0);
                            send_method(NV097_SET_TEXTURE_FORMAT + slot,
                                        format);
                            send_method(NV097_SET_TEXTURE_CONTROL0 + slot,
                                        NV097_SET_TEXTURE_CONTROL0_ENABLE);
                            send_method(NV097_SET_TEXTURE_CONTROL1 + slot,
                                        pitch << 16);
                            send_method(NV097_SET_TEXTURE_IMAGE_RECT + slot,
                                        width << 16 | height);
                            send_method(NV097_SET_TEXTURE_FILTER + slot,
                                        (linear + 1) << 16 | (linear + 1)
                                                                 << 24);
                            send_method(NV097_SET_TEXTURE_ADDRESS + slot,
                                        3 | 3 << 8 | 3 << 16);
                            send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                        PS_TEXTUREMODES_PROJECT2D << 15);
                            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                        PS_REGISTER_T3);
                            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                        (PS_REGISTER_T3 | PS_CHANNEL_ALPHA)
                                            << 8);
                            send_method(NV097_SET_POINT_SIZE, 32);
                            send_method(NV097_SET_POINT_SMOOTH_ENABLE, enabled);
                            send_method(NV097_SET_FRONT_POLYGON_MODE,
                                        NV097_SET_FRONT_POLYGON_MODE_V_POINT);
                            send_method(NV097_SET_BACK_POLYGON_MODE,
                                        NV097_SET_FRONT_POLYGON_MODE_V_POINT);
                            const float positions[][4] = { { 2, 2, 32768, 1 },
                                                           { 6, 2, 32768, 1 },
                                                           { 2, 6, 32768, 1 } };
                            cpu_write(16384, sizeof(positions));
                            memcpy(state->vram_ptr + 16384, positions,
                                   sizeof(positions));
                            const float texcoord[] = { 4.5f, 3.5f, .5f, 2 };
                            if (programmed) {
                                pg->regs_[NV_PGRAPH_CSV0_D] =
                                    2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                                pg->program_data[0][1] = 1 << 21 | 27;
                                pg->program_data[0][2] = 2u << 26;
                                pg->program_data[0][3] = 1 << 11 | 15 << 12;
                                pg->program_data[1][1] = 1 << 21 | 5 << 13 | 27;
                                pg->program_data[1][2] = 3u << 26;
                                pg->program_data[1][3] =
                                    1 << 11 | 12 << 3 | 15 << 12 | 1;
                                memcpy(pg->vsh_constants[5], texcoord,
                                       sizeof(texcoord));
                            } else {
                                memcpy(pg->vertex_attributes[12].inline_value,
                                       texcoord, sizeof(texcoord));
                            }
                            begin(polygon ? PRIM_TYPE_TRIANGLES :
                                            PRIM_TYPE_POINTS);
                            if (operation == 1 || operation == 3)
                                arrays(0, 3);
                            if (operation == 1) {
                                qemu_mutex_lock(&pg->lock);
                                renderer.ops.flush_draw(state);
                                qemu_mutex_unlock(&pg->lock);
                            }
                            /* Neither current registers nor changed source RAM
                             * may replace the resources retained by Begin. */
                            send_method(NV097_SET_POINT_SMOOTH_ENABLE,
                                        !enabled);
                            send_method(NV097_SET_POINT_SIZE, 8);
                            send_method(NV097_SET_FRONT_POLYGON_MODE,
                                        NV097_SET_FRONT_POLYGON_MODE_V_FILL);
                            send_method(NV097_SET_BACK_POLYGON_MODE,
                                        NV097_SET_FRONT_POLYGON_MODE_V_FILL);
                            send_method(NV097_SET_TEXTURE_FORMAT + slot,
                                        127u << 8);
                            send_method(NV097_SET_TEXTURE_FILTER + slot,
                                        (2 - linear) << 16 | (2 - linear)
                                                                 << 24);
                            send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                        PS_TEXTUREMODES_PASSTHRU << 15);
                            cpu_write(49152, pitch * height);
                            memset(state->vram_ptr + 49152, 0x5b,
                                   pitch * height);
                            if (operation >= 2) {
                                unsigned pending = operation == 3 ? 1 : 0;
                                assert(pg->draw_arrays_length == pending);
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                                assert(pg->draw_arrays_length == pending);
                                assert(pgraph_metal4_validate_begin_capture(
                                    pg->metal4_begin_capture,
                                    pg->metal4_begin_capture_size));
                                const uint8_t *uniforms =
                                    pg->metal4_begin_capture + 48 + 25 * 4;
                                assert((uint32_t)ldl_be_p(
                                           uniforms +
                                           offsetof(NV2AMetalPixelUniforms,
                                                    point_sprite)) == enabled);
                                assert(
                                    ldl_be_p(uniforms +
                                             offsetof(NV2AMetalPixelUniforms,
                                                      textures) +
                                             3 * sizeof(NV2AMetalTextureStage) +
                                             offsetof(NV2AMetalTextureStage,
                                                      rectangle)) == 1);
                                int fd = new_vertex_snapshot_file();
                                save_snapshot_parent(fd,
                                                     &array_snapshot_parent);
                                NSData *ram =
                                    [NSData dataWithBytes:state->vram_ptr
                                                   length:65536];
                                if (!pending)
                                    arrays(0, 3);
                                end();
                                before_ram_load();
                                memcpy(state->vram_ptr, ram.bytes, ram.length);
                                assert(load_snapshot_parent(
                                           fd, &array_snapshot_parent) == 0);
                                assert(pg->draw_arrays_length == pending);
                                after_ram_load();
                                assert(pg->draw_arrays_length == pending);
                                close(fd);
                                restores++;
                            }
                            if (operation != 3)
                                arrays(0, 3);
                            end();
                            assert(pg->regs_[NV_PGRAPH_TEXFMT0 + 3 * 4] ==
                                   127u << 8);
                            for (unsigned y = 0; y < 8; y++)
                                for (unsigned x = 0; x < 8; x++) {
                                    uint32_t expected = 0xffff0000;
                                    if (x < 4 || y < 4) {
                                        double s =
                                            enabled ? ((x % 4) + .5) / 4 : 2.25;
                                        double t =
                                            enabled ? ((y % 4) + .5) / 4 : 1.75;
                                        double tx = linear ?
                                                        fmax(0, fmin(width - 1,
                                                                     s - .5)) :
                                                        floor(s);
                                        double ty = linear ?
                                                        fmax(0, fmin(height - 1,
                                                                     t - .5)) :
                                                        floor(t);
                                        /* Affine texel channels give the exact
                                         * clamped bilinear result directly. */
                                        expected =
                                            (uint32_t)lround(96 + 16 * tx +
                                                             8 * ty)
                                                << 24 |
                                            (uint32_t)lround(16 + 32 * tx)
                                                << 16 |
                                            (uint32_t)lround(16 + 32 * ty)
                                                << 8 |
                                            (uint32_t)lround(32 + 16 * tx +
                                                             16 * ty);
                                    }
                                    uint32_t got = color(x, y);
                                    if (got != expected) {
                                        fprintf(
                                            stderr,
                                            "Rectangle sprite Begin shape%u "
                                            "linear%u enabled%u polygon%u "
                                            "programmed%u operation%u "
                                            "pixel%u,%u got%08x expected%08x\n",
                                            shape, linear, enabled, polygon,
                                            programmed, operation, x, y, got,
                                            expected);
                                        abort();
                                    }
                                    pixels++;
                                }
                            cases++;
                        }
    assert(cases == 128 && restores == 64 && pixels == 8192);
    printf("Metal4 rectangle sprites: %u dispatcher cases/%u partial-Begin "
           "restores/%u exact raw pixels PASS\n",
           cases, restores, pixels);
    groups++;
}

static void two_side_begin_snapshot(void)
{
    unsigned cases = 0;
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned clockwise = 0; clockwise < 2; clockwise++)
            for (unsigned enabled = 0; enabled < 2; enabled++)
                for (unsigned operation = 0; operation < 4; operation++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    const float front[] = { 0, 1, 0, .5f };
                    const float back[] = { 1, 0, 0, .75f };
                    send_method(NV097_SET_LIGHT_TWO_SIDE_ENABLE, enabled);
                    send_method(NV097_SET_FRONT_FACE,
                                clockwise ? NV097_SET_FRONT_FACE_V_CCW :
                                            NV097_SET_FRONT_FACE_V_CW);
                    if (programmed) {
                        pg->regs_[NV_PGRAPH_CSV0_D] =
                            2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                        const unsigned outputs[] = { 0, 3, 7 };
                        for (unsigned slot = 0; slot < 3; slot++) {
                            pg->program_data[slot][1] =
                                1 << 21 | (slot ? (slot + 4) << 13 : 0) | 27;
                            pg->program_data[slot][2] = (slot ? 3u : 2u) << 26;
                            pg->program_data[slot][3] = 1 << 11 |
                                                        outputs[slot] << 3 |
                                                        15 << 12 | (slot == 2);
                        }
                        memcpy(pg->vsh_constants[5], front, sizeof(front));
                        memcpy(pg->vsh_constants[6], back, sizeof(back));
                    } else {
                        send_method(NV097_SET_LIGHTING_ENABLE, 1);
                        pg->material_alpha = .5f;
                        pg->material_alpha_back = .75f;
                        memcpy(pg->ltctxa[NV_IGRAPH_XF_LTCTXA_FR_AMB], front,
                               12);
                        memcpy(pg->ltctxa[NV_IGRAPH_XF_LTCTXA_BR_AMB], back,
                               12);
                    }
                    begin(PRIM_TYPE_TRIANGLES);
                    arrays(0, 3);
                    send_method(NV097_SET_LIGHT_TWO_SIDE_ENABLE, !enabled);
                    send_method(NV097_SET_FRONT_FACE,
                                clockwise ? NV097_SET_FRONT_FACE_V_CW :
                                            NV097_SET_FRONT_FACE_V_CCW);
                    if (operation == 3)
                        send_method(NV097_CLEAR_SURFACE, 0);
                    uint32_t expected =
                        enabled && clockwise ? 0xbfff0000 : 0x8000ff00;
                    if (operation >= 2) {
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        int fd = new_vertex_snapshot_file();
                        save_vertex_snapshot(fd);
                        const uint8_t *pixel = pg->metal4_begin_capture + 48;
                        unsigned length =
                            ldl_be_p(pg->metal4_begin_capture + 40);
                        assert(ldl_be_p(pixel + 4) == 6 &&
                               (uint32_t)ldl_be_p(pixel + length - 8) ==
                                   enabled);
                        end();
                        if (color(1, 1) != expected) {
                            fprintf(stderr,
                                    "TwoSide Begin programmed=%u clockwise=%u "
                                    "enabled=%u operation=%u got=%08x "
                                    "expected=%08x\n",
                                    programmed, clockwise, enabled, operation,
                                    color(1, 1), expected);
                            abort();
                        }
                        before_ram_load();
                        assert(load_vertex_snapshot(fd) == 0);
                        after_ram_load();
                        arrays(0, 3);
                        close(fd);
                    } else if (operation == 1) {
                        qemu_mutex_lock(&pg->lock);
                        renderer.ops.flush_draw(state);
                        qemu_mutex_unlock(&pg->lock);
                        arrays(0, 3);
                    }
                    end();
                    if (color(1, 1) != expected) {
                        fprintf(
                            stderr,
                            "TwoSide Begin programmed=%u clockwise=%u "
                            "enabled=%u operation=%u got=%08x expected=%08x\n",
                            programmed, clockwise, enabled, operation,
                            color(1, 1), expected);
                        abort();
                    }
                    groups++;
                    cases++;
                }
    assert(cases == 32);
    printf(
        "Metal4 two-sided frozen Begin/save/restore/clear: %u GPU cases PASS\n",
        cases);
}

static void frozen_vertex_snapshot(void)
{
    for (unsigned programmed = 0; programmed < 2; programmed++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        if (programmed) {
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            // Existing vertex-pgraph test's verified MOV token fields.
            pg->program_data[0][1] = 1 << 21 | 27;
            pg->program_data[0][2] = 2u << 26;
            pg->program_data[0][3] = 1 << 11 | 15 << 12;
            pg->program_data[1][1] = 1 << 21 | 5 << 13 | 27;
            pg->program_data[1][2] = 3u << 26;
            pg->program_data[1][3] = 1 << 11 | 3 << 3 | 15 << 12 | 1;
            float blue[] = { 0, 0, 1, 1 };
            memcpy(pg->vsh_constants[5], blue, sizeof(blue));
        }
        if (!programmed) {
            pg->regs_[NV_PGRAPH_CSV0_D] |= NV_PGRAPH_CSV0_D_TEXGEN_REF;
        }
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        if (programmed) {
            float yellow[] = { 1, 1, 0, 1 };
            memcpy(pg->vsh_constants[5], yellow, sizeof(yellow));
            // A later program upload must not replace the bound program.
            pg->program_data[0][1] = 15 << 21;
        } else {
            pg->regs_[NV_PGRAPH_CSV0_D] &= ~NV_PGRAPH_CSV0_D_TEXGEN_REF;
            float translation = 4;
            memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3],
                   &translation, sizeof(translation));
        }
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        NSData *saved = [NSData dataWithBytes:pg->metal4_vertex_capture
                                       length:pg->metal4_vertex_capture_size];
        assert(saved.length && pgraph_metal4_validate_vertex_capture(
                                   saved.bytes, saved.length));
        NSError *error = nil;
        NV2AMetalPGRAPHVertexState *decoded =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:saved
                                                           error:&error];
        require(decoded != nil, error);
        if (!programmed) {
            assert(decoded.fixedUniforms.texgen_infinite_viewer);
            assert(
                !(pg->regs_[NV_PGRAPH_CSV0_D] & NV_PGRAPH_CSV0_D_TEXGEN_REF));
        }
        assert(decoded.programmed == programmed &&
               [[decoded snapshotData] isEqualToData:saved]);
        uint32_t special[] = { 0x80000000, 0x7fc12345, 0x7f800000, 0xff800000 };
        NSMutableData *bits = [saved mutableCopy];
        for (unsigned i = 0; i < ARRAY_SIZE(special); i++)
            stl_be_p((uint8_t *)bits.mutableBytes + 32 +
                         sizeof(NV2AMetalProgramInput) + i * 4,
                     special[i]);
        NV2AMetalPGRAPHVertexState *exact =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bits
                                                           error:&error];
        require(exact != nil, error);
        assert([[exact snapshotData] isEqualToData:bits]);
        if (programmed) {
            NSMutableData *dynamic = [saved mutableCopy];
            uint8_t *raw = dynamic.mutableBytes;
            NSUInteger tokens = 32 + sizeof(NV2AMetalProgramInput) +
                                sizeof(NV2AMetalProgramUniforms);
            stl_be_p(raw + 8, ldl_be_p(raw + 8) | 2);
            stl_be_p(raw + tokens + 4, 13 << 21 | 27);
            stl_be_p(raw + tokens + 12, 0);
            stl_be_p(raw + tokens + 28, ldl_be_p(raw + tokens + 28) | 2);
            NV2AMetalPGRAPHVertexState *relative =
                [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:dynamic
                                                               error:&error];
            require(relative != nil, error);
            assert(relative.dynamicAddressing &&
                   [[relative snapshotData] isEqualToData:dynamic]);
            stl_be_p(raw + 8, ldl_be_p(raw + 8) & ~2u);
            assert(!pgraph_metal4_validate_vertex_capture(raw, dynamic.length));
            NSMutableData *extra = [saved mutableCopy];
            stl_be_p((uint8_t *)extra.mutableBytes + tokens + 12,
                     ldl_be_p((uint8_t *)extra.bytes + tokens + 12) | 1);
            assert(!pgraph_metal4_validate_vertex_capture(extra.bytes,
                                                          extra.length));
        }
        for (NSUInteger length = 0; length < saved.length; length++) {
            NSData *shortened = [saved subdataWithRange:NSMakeRange(0, length)];
            assert(!pgraph_metal4_validate_vertex_capture(shortened.bytes,
                                                          shortened.length));
        }
        unsigned offsets[] = { 0, 4, 8, 12, 16, 20, 24, 28 };
        for (unsigned i = 0; i < ARRAY_SIZE(offsets); i++) {
            NSMutableData *bad = [saved mutableCopy];
            stl_be_p((uint8_t *)bad.mutableBytes + offsets[i], UINT32_MAX);
            assert(
                !pgraph_metal4_validate_vertex_capture(bad.bytes, bad.length));
        }
        int fd = new_vertex_snapshot_file();
        save_vertex_snapshot(fd);
        off_t wire_size = lseek(fd, 0, SEEK_END);
        NSMutableData *wire = [NSMutableData dataWithLength:wire_size];
        assert(pread(fd, wire.mutableBytes, wire.length, 0) == wire_size);
        const uint8_t *packet = wire.bytes;
        NSUInteger capture_start = 0;
        for (NSUInteger i = 0; i + saved.length < wire.length; i++) {
            if (ldl_be_p(packet + i) == 0x4d345643) {
                capture_start = i;
                break;
            }
        }
        assert(capture_start > 8 &&
               !memcmp(packet + capture_start, saved.bytes, saved.length));
        // The production subsection commits its blob only after full decode.
        for (NSUInteger length = 0; length < saved.length; length++) {
            assert(ftruncate(fd, capture_start + length) == 0);
            assert(load_vertex_snapshot(fd) < 0);
            assert(
                pg->metal4_vertex_capture_size == saved.length &&
                !memcmp(pg->metal4_vertex_capture, saved.bytes, saved.length));
            assert(pwrite(fd, wire.bytes, wire.length, 0) == wire_size);
        }
        for (unsigned fault = 0; fault < 3; fault++) {
            NSMutableData *bad = [wire mutableCopy];
            NSUInteger offset = fault == 0 ? capture_start - 4 :
                                fault == 1 ? capture_start - 8 :
                                             capture_start + 8;
            stl_be_p((uint8_t *)bad.mutableBytes + offset,
                     fault == 0 ? NV2A_METAL_VERTEX_CAPTURE_MAX + 1 :
                     fault == 1 ? PRIM_TYPE_POINTS :
                                  UINT32_MAX);
            assert(pwrite(fd, bad.bytes, bad.length, 0) == wire_size);
            assert(load_vertex_snapshot(fd) < 0);
            assert(
                pg->metal4_vertex_capture_size == saved.length &&
                !memcmp(pg->metal4_vertex_capture, saved.bytes, saved.length));
        }
        assert(pwrite(fd, wire.bytes, wire.length, 0) == wire_size);
        end();
        before_ram_load();
        // The minimal VMState parent does not load RAM; simulate saved VRAM.
        for (unsigned i = 0; i < 64; i++) {
            uint32_t red = 0xffff0000;
            memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
        }
        assert(!pg->metal4_vertex_capture && !pg->metal4_vertex_capture_size);
        assert(load_vertex_snapshot(fd) == 0);
        assert(pg->metal4_vertex_capture_size == saved.length &&
               !memcmp(pg->metal4_vertex_capture, saved.bytes, saved.length));
        pg->draw_arrays_length = 0;
        after_ram_load();
        // Save again before the resumed Begin has been materialized.
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        assert(pg->metal4_vertex_capture_size == saved.length &&
               !memcmp(pg->metal4_vertex_capture, saved.bytes, saved.length));
        arrays(0, 3);
        end();
        assert(color(1, 1) == (programmed ? 0xff0000ff : 0xff00ff00));
        assert(color(5, 5) == 0xffff0000);
        if (programmed) {
            assert(pg->program_data[0][1] == 15u << 21);
            pg->program_data[0][1] = 1 << 21 | 27;
        } else {
            float translation;
            memcpy(&translation,
                   &pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3],
                   sizeof(translation));
            assert(translation == 4);
        }
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        end();
        assert(color(programmed ? 1 : 5, programmed ? 1 : 5) ==
               (programmed ? 0xffffff00 : 0xff00ff00));
        close(fd);
    }
    groups++;
}
static void frozen_begin_snapshot(void)
{
    for (unsigned variant = 0; variant < 4; variant++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        if (variant != 1) {
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
        }
        if (variant == 1) {
            pg->surface_shape.zeta_format = 2;
            pg->surface_zeta.pitch = 32;
            pg->regs_[NV_PGRAPH_CONTROL_0] |=
                NV_PGRAPH_CONTROL_0_ZENABLE |
                NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE;
            SET_MASK(pg->regs_[NV_PGRAPH_CONTROL_0], NV_PGRAPH_CONTROL_0_ZFUNC,
                     1);
            pg->regs_[NV_PGRAPH_CONTROL_1] =
                NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 | 6 << 8 |
                0xff << 16 | 0xffu << 24;
            pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 3 << 8;
            cpu_write(4096, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t packed = 0xffffff00;
                memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
            }
        } else if (variant == 2) {
            pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = 3 << 16;
        } else if (variant == 3) {
            send_method(NV097_SET_COLOR_MASK, 0);
        }
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        if (variant == 0) {
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
            send_method(NV097_SET_BLEND_ENABLE, 1);
            send_method(NV097_SET_BLEND_EQUATION, 0x8006);
            send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0);
            send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0);
            send_method(NV097_SET_ALPHA_TEST_ENABLE, 1);
            send_method(NV097_SET_ALPHA_FUNC, 0x200);
            pg->regs_[NV_PGRAPH_SETUPRASTER] |=
                NV_PGRAPH_SETUPRASTER_CULLENABLE |
                NV_PGRAPH_SETUPRASTER_CULLCTRL;
            // An untextured Begin must not bind later, invalid texture regs.
            pg->regs_[NV_PGRAPH_TEXCTL0_0] = NV_PGRAPH_TEXCTL0_0_ENABLE;
            pg->regs_[NV_PGRAPH_TEXFMT0] = 127u << 8;
        } else if (variant == 1) {
            SET_MASK(pg->regs_[NV_PGRAPH_CONTROL_0], NV_PGRAPH_CONTROL_0_ZFUNC,
                     0);
            SET_MASK(pg->regs_[NV_PGRAPH_CONTROL_1],
                     NV_PGRAPH_CONTROL_1_STENCIL_FUNC, 0);
            SET_MASK(pg->regs_[NV_PGRAPH_CONTROL_1],
                     NV_PGRAPH_CONTROL_1_STENCIL_REF, 2);
        } else if (variant == 2) {
            pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = 7 << 16;
        } else {
            send_method(NV097_SET_COLOR_MASK, 0xf);
        }
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        NSData *saved = [NSData dataWithBytes:pg->metal4_begin_capture
                                       length:pg->metal4_begin_capture_size];
        assert(saved.length &&
               pgraph_metal4_validate_begin_capture(saved.bytes, saved.length));
        for (NSUInteger n = 0; n < saved.length; n++)
            assert(!pgraph_metal4_validate_begin_capture(saved.bytes, n));
        for (unsigned i = 0; i < 11; i++) {
            NSMutableData *bad = [saved mutableCopy];
            stl_be_p((uint8_t *)bad.mutableBytes + i * 4, UINT32_MAX);
            assert(
                !pgraph_metal4_validate_begin_capture(bad.bytes, bad.length));
        }
        if (variant != 3) {
            for (unsigned i = 0; i < 17; i++) {
                NSMutableData *bad = [saved mutableCopy];
                stl_be_p((uint8_t *)bad.mutableBytes + saved.length -
                             NV2AMetalSurfaceBindingsBytes + i * 4,
                         UINT32_MAX);
                assert(!pgraph_metal4_validate_begin_capture(bad.bytes,
                                                             bad.length));
            }
            for (unsigned field = 23; field < 25; field++) {
                for (unsigned value = 0; value < 2; value++) {
                    NSMutableData *bad = [saved mutableCopy];
                    stl_be_p((uint8_t *)bad.mutableBytes + 48 + field * 4,
                             value ? 16385 : 0);
                    assert(!pgraph_metal4_validate_begin_capture(bad.bytes,
                                                                 bad.length));
                }
            }
        }
        if (variant == 1) {
            const unsigned fields[] = { 10, 12, 13, 15 };
            const uint32_t values[] = { 1024, 4, 4, 2 };
            for (unsigned i = 0; i < ARRAY_SIZE(fields); i++) {
                NSMutableData *bad = [saved mutableCopy];
                stl_be_p((uint8_t *)bad.mutableBytes + saved.length -
                             NV2AMetalSurfaceBindingsBytes + fields[i] * 4,
                         values[i]);
                assert(!pgraph_metal4_validate_begin_capture(bad.bytes,
                                                             bad.length));
            }
        }
        if (variant == 0) {
            // V2 lacked attachment layouts but retained its pixel/stage blocks.
            NSMutableData *legacy = [NSMutableData
                dataWithBytes:saved.bytes
                       length:saved.length - NV2AMetalSurfaceBindingsBytes];
            stl_be_p((uint8_t *)legacy.mutableBytes + 4, 2);
            assert(pgraph_metal4_validate_begin_capture(legacy.bytes,
                                                        legacy.length));
            saved = [legacy copy];
            g_free(pg->metal4_begin_capture);
            pg->metal4_begin_capture = g_memdup2(saved.bytes, saved.length);
            pg->metal4_begin_capture_size = saved.length;
        }
        if (variant == 2) {
            // Legacy v1 had no texture-length word and no empty M4TS block.
            NSMutableData *legacy = [NSMutableData dataWithBytes:saved.bytes
                                                          length:44];
            stl_be_p((uint8_t *)legacy.mutableBytes + 4, 1);
            unsigned pixelSize =
                (uint32_t)ldl_be_p((const uint8_t *)saved.bytes + 40);
            NSData *pixel = [saved subdataWithRange:NSMakeRange(48, pixelSize)];
            NSData *oldPixel = legacy_pixel_fixture(pixel, 1);
            stl_be_p((uint8_t *)legacy.mutableBytes + 40, oldPixel.length);
            [legacy appendData:oldPixel];
            assert(pgraph_metal4_validate_begin_capture(legacy.bytes,
                                                        legacy.length));
            saved = [legacy copy];
            g_free(pg->metal4_begin_capture);
            pg->metal4_begin_capture = g_memdup2(saved.bytes, saved.length);
            pg->metal4_begin_capture_size = saved.length;
        }
        int fd = new_vertex_snapshot_file();
        save_vertex_snapshot(fd);
        off_t wire_size = lseek(fd, 0, SEEK_END);
        NSMutableData *wire = [NSMutableData dataWithLength:wire_size];
        assert(pread(fd, wire.mutableBytes, wire.length, 0) == wire_size);
        const uint8_t *packet = wire.bytes;
        NSUInteger capture_start = 0;
        for (NSUInteger i = 0; i + saved.length < wire.length; i++) {
            if (ldl_be_p(packet + i) == 0x4d344243) {
                capture_start = i;
                break;
            }
        }
        assert(capture_start > 8 &&
               !memcmp(packet + capture_start, saved.bytes, saved.length));
        for (NSUInteger n = 0; n < saved.length; n++) {
            assert(ftruncate(fd, capture_start + n) == 0);
            assert(load_vertex_snapshot(fd) < 0);
            assert(
                pg->metal4_begin_capture_size == saved.length &&
                !memcmp(pg->metal4_begin_capture, saved.bytes, saved.length));
            assert(pwrite(fd, wire.bytes, wire.length, 0) == wire_size);
        }
        for (unsigned fault = 0; fault < 3 + (variant == 1 ? 17 : 0); fault++) {
            NSMutableData *bad = [wire mutableCopy];
            NSUInteger offset = fault == 0 ? capture_start - 4 :
                                fault == 1 ? capture_start + 8 :
                                fault == 2 ? capture_start + 32 :
                                             capture_start + saved.length -
                                                 NV2AMetalSurfaceBindingsBytes +
                                                 (fault - 3) * 4;
            stl_be_p((uint8_t *)bad.mutableBytes + offset,
                     fault == 0 ? NV2A_METAL_BEGIN_CAPTURE_MAX + 1 :
                     fault == 1 ? PRIM_TYPE_POINTS :
                                  UINT32_MAX);
            assert(pwrite(fd, bad.bytes, bad.length, 0) == wire_size);
            assert(load_vertex_snapshot(fd) < 0);
            assert(
                pg->metal4_begin_capture_size == saved.length &&
                !memcmp(pg->metal4_begin_capture, saved.bytes, saved.length));
        }
        assert(pwrite(fd, wire.bytes, wire.length, 0) == wire_size);
        end();
        before_ram_load();
        assert(!pg->metal4_begin_capture && !pg->metal4_begin_capture_size);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t red = 0xffff0000, packed = 0xffffff00;
            memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
            if (variant == 1)
                memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
        }
        assert(load_vertex_snapshot(fd) == 0);
        pg->draw_arrays_length = 0;
        after_ram_load();
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        assert(pg->metal4_begin_capture_size == saved.length &&
               !memcmp(pg->metal4_begin_capture, saved.bytes, saved.length));
        arrays(0, 3);
        end();
        assert(color(1, 1) == (variant == 3 ? 0xffff0000 :
                               variant == 1 ? 0xff00ff00 :
                                              0xff0000ff));
        assert(color(5, 1) == (variant == 2 || variant == 3 ? 0xffff0000 :
                               variant == 1                 ? 0xff00ff00 :
                                                              0xff0000ff));
        if (variant == 1) {
            NSError *error = nil;
            require([surfaces.cache prepareCPUAccessAtAddress:4096
                                                       length:256
                                                        write:NO
                                                        error:&error],
                    error);
            uint32_t packed;
            memcpy(&packed, state->vram_ptr + 4096 + (1 * 8 + 1) * 4, 4);
            assert((packed & 255) == 6);
        }
        assert(pg->draw_time == (variant == 3 ? 0 : 2));
        close(fd);
    }
    groups++;
}
static void frozen_texture_snapshot(void)
{
    for (unsigned alias = 0; alias < 2; alias++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        unsigned source = alias ? 1024 : 32768;
        dma[3].address = source;
        cpu_write(source, 256);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t blue = 0xff0000ff;
            memcpy(state->vram_ptr + source + i * 4, &blue, 4);
        }
        uint32_t format =
            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 << 8 | 2 << 6 |
            NV_PGRAPH_TEXFMT0_BORDER_SOURCE | 1 << 16 | 3 << 20 | 3 << 24;
        pg->regs_[NV_PGRAPH_TEXFMT0] = format;
        pg->regs_[NV_PGRAPH_TEXCTL0_0] = NV_PGRAPH_TEXCTL0_0_ENABLE;
        pg->regs_[NV_PGRAPH_TEXCTL1_0] = 32 << 16;
        pg->regs_[NV_PGRAPH_TEXIMAGERECT0] = 8 << 16 | 8;
        pg->regs_[NV_PGRAPH_TEXFILTER0] = 1 << 16 | 1 << 24;
        pg->regs_[NV_PGRAPH_TEXADDRESS0] = 3 | 3 << 8 | 3 << 16;
        pg->regs_[NV_PGRAPH_SHADERPROG] = PS_TEXTUREMODES_PROJECT2D;
        pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_T0;
        pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
            (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
        pg->vertex_attributes[9].inline_value[0] =
            pg->vertex_attributes[9].inline_value[1] = 1.5f;
        pg->texture_dirty[0] = true;
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        cpu_write(source, 256);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t yellow = 0xffffff00;
            memcpy(state->vram_ptr + source + i * 4, &yellow, 4);
        }
        pg->regs_[NV_PGRAPH_TEXFMT0] =
            127u << 8; // Current registers are not the binding.
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        NSData *saved = [NSData dataWithBytes:pg->metal4_begin_capture
                                       length:pg->metal4_begin_capture_size];
        assert(saved.length > 2000 &&
               pgraph_metal4_validate_begin_capture(saved.bytes, saved.length));
        for (NSUInteger n = 0; n < saved.length; n++)
            assert(!pgraph_metal4_validate_begin_capture(saved.bytes, n));
        unsigned textureStart =
            48 + (uint32_t)ldl_be_p((const uint8_t *)saved.bytes + 40);
        unsigned stageStart = textureStart + 12;
        unsigned imageStart = stageStart + 220;
        unsigned offsets[] = { 44,
                               textureStart,
                               textureStart + 8,
                               stageStart,
                               stageStart + 4,
                               stageStart + 8,
                               stageStart + 12,
                               stageStart + 164,
                               imageStart + 8,
                               imageStart + 12 };
        for (unsigned i = 0; i < ARRAY_SIZE(offsets); i++) {
            NSMutableData *bad = [saved mutableCopy];
            stl_be_p((uint8_t *)bad.mutableBytes + offsets[i], UINT32_MAX);
            assert(
                !pgraph_metal4_validate_begin_capture(bad.bytes, bad.length));
        }
        int fd = new_vertex_snapshot_file();
        save_vertex_snapshot(fd);
        off_t wireSize = lseek(fd, 0, SEEK_END);
        NSMutableData *wire = [NSMutableData dataWithLength:wireSize];
        assert(pread(fd, wire.mutableBytes, wire.length, 0) == wireSize);
        NSUInteger captureStart = 0;
        const uint8_t *packet = wire.bytes;
        for (NSUInteger i = 0; i + saved.length < wire.length; i++)
            if ((uint32_t)ldl_be_p(packet + i) == 0x4d344243) {
                captureStart = i;
                break;
            }
        assert(captureStart > 8 &&
               !memcmp(packet + captureStart, saved.bytes, saved.length));
        for (NSUInteger n = 0; n < saved.length; n++) {
            assert(ftruncate(fd, captureStart + n) == 0);
            assert(load_vertex_snapshot(fd) < 0);
            assert(
                pg->metal4_begin_capture_size == saved.length &&
                !memcmp(pg->metal4_begin_capture, saved.bytes, saved.length));
            assert(pwrite(fd, wire.bytes, wire.length, 0) == wireSize);
        }
        for (unsigned i = 0; i < ARRAY_SIZE(offsets); i++) {
            NSMutableData *bad = [wire mutableCopy];
            stl_be_p((uint8_t *)bad.mutableBytes + captureStart + offsets[i],
                     UINT32_MAX);
            assert(pwrite(fd, bad.bytes, bad.length, 0) == wireSize);
            assert(load_vertex_snapshot(fd) < 0);
            assert(
                pg->metal4_begin_capture_size == saved.length &&
                !memcmp(pg->metal4_begin_capture, saved.bytes, saved.length));
        }
        assert(pwrite(fd, wire.bytes, wire.length, 0) == wireSize);
        end();
        before_ram_load();
        for (unsigned i = 0; i < 64; i++) {
            uint32_t background = alias ? 0xffffff00 : 0xffff0000;
            memcpy(state->vram_ptr + 1024 + i * 4, &background, 4);
        }
        assert(load_vertex_snapshot(fd) == 0);
        pg->draw_arrays_length = 0;
        after_ram_load();
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        assert(pg->metal4_begin_capture_size == saved.length &&
               !memcmp(pg->metal4_begin_capture, saved.bytes, saved.length));
        arrays(0, 3);
        end();
        assert(color(1, 1) == 0xff0000ff &&
               color(7, 7) == (alias ? 0xffffff00 : 0xffff0000));
        assert(pg->regs_[NV_PGRAPH_TEXFMT0] == 127u << 8);
        pg->regs_[NV_PGRAPH_TEXFMT0] = format;
        pg->texture_dirty[0] = true;
        pg->vertex_attributes[9].inline_value[0] =
            pg->vertex_attributes[9].inline_value[1] = alias ? 7.5f : 1.5f;
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        end();
        assert(color(1, 1) == 0xffffff00);
        close(fd);
    }
    groups++;
}
static void quiescence_preserves_begin(void)
{
    for (unsigned operation = 0; operation < 4; operation++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
        float translate = 4;
        memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3], &translate, 4);
        pg->vsh_constants_dirty[NV_IGRAPH_XF_XFCTX_CMAT0] = true;
        send_method(NV097_SET_BLEND_ENABLE, 1);
        send_method(NV097_SET_BLEND_EQUATION, 0x8006);
        send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0);
        send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0);
        if (operation == 0) {
            renderer.ops.pre_savevm_trigger(state);
            process_pending();
            renderer.ops.pre_savevm_wait(state);
        } else if (operation == 1) {
            qemu_mutex_lock(&pg->lock);
            renderer.ops.surface_flush(state);
            qemu_mutex_unlock(&pg->lock);
        } else if (operation == 2) {
            renderer.ops.pre_restore_trigger(state);
            process_pending();
            renderer.ops.pre_restore_wait(state);
            // A cancelled load resumes the existing VM and Begin capture.
        } else {
            qemu_event_reset(&pg->flush_complete);
            qatomic_set(&pg->flush_pending, true);
            process_pending();
            qemu_event_wait(&pg->flush_complete);
        }
        if (operation == 1 || operation == 3)
            assert(surfaces.cache.count && surfaces.color);
        else
            assert(!surfaces.cache.count && !surfaces.color);
        assert(pg->draw_time == 0 && pg->draw_arrays_length == 1);
        end();
        assert(color(1, 1) == 0xff0000ff && color(5, 5) == 0xffff0000);
        get_report(0);
        process_reports();
        assert(report_result(0) == 28);
        assert(pg->draw_time == 1);
        // A later Begin must still capture the changed registers.
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        end();
        assert(color(5, 1) == 0 && color(1, 1) == 0xff0000ff);
        assert(pg->draw_time == 2);
    }
    groups++;
}
static void quiescence_preserves_texture(void)
{
    for (unsigned alias = 0; alias < 2; alias++) {
        for (unsigned operation = 0; operation < 3; operation++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            unsigned source = alias ? 1024 : 32768;
            dma[3].address = source;
            cpu_write(source, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t blue = 0xff0000ff;
                memcpy(state->vram_ptr + source + i * 4, &blue, 4);
            }
            pg->regs_[NV_PGRAPH_TEXFMT0] =
                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 << 8 | 2 << 6 |
                NV_PGRAPH_TEXFMT0_BORDER_SOURCE | 1 << 16 | 3 << 20 | 3 << 24;
            pg->regs_[NV_PGRAPH_TEXCTL0_0] = NV_PGRAPH_TEXCTL0_0_ENABLE;
            pg->regs_[NV_PGRAPH_TEXCTL1_0] = 32 << 16;
            pg->regs_[NV_PGRAPH_TEXIMAGERECT0] = 8 << 16 | 8;
            pg->regs_[NV_PGRAPH_TEXFILTER0] = 1 << 16 | 1 << 24;
            pg->regs_[NV_PGRAPH_TEXADDRESS0] = 3 | 3 << 8 | 3 << 16;
            pg->regs_[NV_PGRAPH_SHADERPROG] = PS_TEXTUREMODES_PROJECT2D;
            pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_T0;
            pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
                (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
            pg->vertex_attributes[9].inline_value[0] =
                pg->vertex_attributes[9].inline_value[1] = 1.5f;
            pg->texture_dirty[0] = true;
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            // Complete the old upload/capture before replacing its guest bytes.
            cpu_write(source, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t yellow = 0xffffff00;
                memcpy(state->vram_ptr + source + i * 4, &yellow, 4);
            }
            if (operation == 0) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
            } else if (operation == 1) {
                qemu_mutex_lock(&pg->lock);
                renderer.ops.surface_flush(state);
                qemu_mutex_unlock(&pg->lock);
            } else {
                renderer.ops.pre_restore_trigger(state);
                process_pending();
                renderer.ops.pre_restore_wait(state);
            }
            if (operation == 1)
                assert(surfaces.cache.count && surfaces.color);
            else
                assert(!surfaces.cache.count && !surfaces.color);
            end();
            assert(color(1, 1) == 0xff0000ff);
            assert(color(7, 7) == (alias ? 0xffffff00 : 0xffff0000));
            // For feedback, sample an untouched yellow texel after the draw.
            pg->vertex_attributes[9].inline_value[0] =
                pg->vertex_attributes[9].inline_value[1] = alias ? 7.5f : 1.5f;
            // The next Begin sees the new texture content, not a stale capture.
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            assert(color(1, 1) == 0xffffff00 && pg->draw_time == 2);
        }
    }
    groups++;
}
static void compressed_inline_rebind(void)
{
    for (unsigned compressed = 0; compressed < 2; compressed++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        if (compressed) {
            uint32_t format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP;
            SET_MASK(format, NV097_SET_VERTEX_DATA_ARRAY_FORMAT_SIZE, 1);
            SET_MASK(format, NV097_SET_VERTEX_DATA_ARRAY_FORMAT_STRIDE, 4);
            send_method(NV097_SET_VERTEX_DATA_ARRAY_FORMAT +
                            NV2A_VERTEX_ATTR_NORMAL * 4,
                        format);
        }
        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
        begin(PRIM_TYPE_TRIANGLES);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
        float translate = 4;
        memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3], &translate, 4);
        pg->vsh_constants_dirty[NV_IGRAPH_XF_XFCTX_CMAT0] = true;
        // Shader rebinding must preserve GL's already-bound blend state.
        send_method(NV097_SET_BLEND_ENABLE, 1);
        send_method(NV097_SET_BLEND_EQUATION, 0x8006);
        send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0);
        send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0);
        inline_position(0, 0);
        inline_position(4, 0);
        inline_position(0, 4);
        if (compressed) {
            // Failed shader recapture must preserve the pending input batch.
            pg->regs_[NV_PGRAPH_COMBINECTL] = 9;
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            assert(![draw flushDrawWithError:&error]);
            qemu_mutex_unlock(&pg->lock);
            assert(pg->compressed_attrs &&
                   pg->vertex_attributes[0].inline_buffer_populated &&
                   color(1, 1) == 0xffff0000 && color(5, 1) == 0xffff0000);
            pg->regs_[NV_PGRAPH_COMBINECTL] = 0;
        }
        qemu_mutex_lock(&pg->lock);
        renderer.ops.flush_draw(state);
        qemu_mutex_unlock(&pg->lock);
        assert(!pg->compressed_attrs);
        assert(color(1, 1) == (compressed ? 0xffff0000 : 0xff0000ff) &&
               color(5, 1) == (compressed ? 0xffffff00 : 0xffff0000));
        if (compressed) {
            pg->inline_buffer_length = 0;
            translate = 0;
            memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3], &translate,
                   4);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffffff);
            inline_position(0, 0);
            inline_position(4, 0);
            inline_position(0, 4);
            qemu_mutex_lock(&pg->lock);
            renderer.ops.flush_draw(state);
            qemu_mutex_unlock(&pg->lock);
            assert(color(1, 1) == 0xffff0000 && color(5, 1) == 0xffffff00);
        }
        pg->inline_buffer_length = 0;
        end();
    }
    groups++;
}
static void end_live_nop(void)
{
    for (unsigned flushed = 0; flushed < 2; flushed++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        if (flushed) {
            qemu_mutex_lock(&pg->lock);
            renderer.ops.flush_draw(state);
            qemu_mutex_unlock(&pg->lock);
            pg->draw_arrays_length = 0;
            pg->vertex_attributes[3].inline_value[1] = 0;
            pg->vertex_attributes[3].inline_value[2] = 1;
            arrays(3, 3);
        }
        float current[4];
        memcpy(current, pg->vertex_attributes[0].inline_value, sizeof(current));
        send_method(NV097_SET_COLOR_MASK, 0);
        send_method(NV097_SET_DEPTH_TEST_ENABLE, 0);
        send_method(NV097_SET_STENCIL_TEST_ENABLE, 0);
        end();
        assert(pg->draw_time == 0 && !pg->draw_arrays_length &&
               pg->primitive_mode == PRIM_TYPE_INVALID);
        assert(!memcmp(current, pg->vertex_attributes[0].inline_value,
                       sizeof(current)));
        assert(color(1, 1) == (flushed ? 0xff00ff00 : 0xffff0000) &&
               color(5, 1) == (flushed ? 0xff00ff00 : 0xffff0000) &&
               color(5, 5) == 0xffff0000);
        // Native query ownership must still finish, including prior flushes.
        get_report(0);
        process_reports();
        assert(report_result(0) == (flushed ? 28 : 0));
    }
    // Any remaining color, depth or stencil access prevents the End-NOP path.
    for (unsigned remaining = 0; remaining < 4; remaining++) {
        fixture();
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        send_method(NV097_SET_COLOR_MASK, 0);
        if (remaining == 0)
            send_method(NV097_SET_COLOR_MASK,
                        NV097_SET_COLOR_MASK_RED_WRITE_ENABLE);
        if (remaining == 1)
            send_method(NV097_SET_COLOR_MASK,
                        NV097_SET_COLOR_MASK_ALPHA_WRITE_ENABLE);
        if (remaining == 2)
            send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
        if (remaining == 3)
            send_method(NV097_SET_STENCIL_TEST_ENABLE, 1);
        end();
        assert(state->pgraph.draw_time == 1 && color(1, 1) == 0xff00ff00);
        get_report(0);
        process_reports();
        assert(report_result(0) == 28);
    }
    groups++;
}
static void class_method(unsigned cls, unsigned m, uint32_t value)
{
    state->pgraph.regs_[NV_PGRAPH_CTX_CACHE1] = cls;
    send_method(m, value);
    state->pgraph.regs_[NV_PGRAPH_CTX_CACHE1] = NV_KELVIN_PRIMITIVE;
}
static void blit_context(unsigned format, unsigned op, unsigned source,
                         unsigned dest, unsigned source_pitch,
                         unsigned dest_pitch)
{
    state->pgraph.context_surfaces_2d.object_instance = 0x50;
    class_method(NV_CONTEXT_SURFACES_2D, NV062_SET_CONTEXT_DMA_IMAGE_SOURCE,
                 source);
    class_method(NV_CONTEXT_SURFACES_2D, NV062_SET_CONTEXT_DMA_IMAGE_DESTIN,
                 dest);
    class_method(NV_CONTEXT_SURFACES_2D, NV062_SET_COLOR_FORMAT, format);
    class_method(NV_CONTEXT_SURFACES_2D, NV062_SET_PITCH,
                 source_pitch | dest_pitch << 16);
    class_method(NV_CONTEXT_SURFACES_2D, NV062_SET_OFFSET_SOURCE, 0);
    class_method(NV_CONTEXT_SURFACES_2D, NV062_SET_OFFSET_DESTIN, 0);
    class_method(NV_BETA, NV012_SET_BETA, 0x35801234);
    class_method(NV_IMAGE_BLIT, NV09F_SET_CONTEXT_SURFACES, 0x50);
    class_method(NV_IMAGE_BLIT, NV09F_SET_OPERATION, op);
    class_method(NV_IMAGE_BLIT, NV09F_CONTROL_POINT_IN, 0);
    class_method(NV_IMAGE_BLIT, NV09F_CONTROL_POINT_OUT, 0);
}
static void fill_blit_ram(void)
{
    cpu_write(32768, 512);
    cpu_write(49152, 512);
    for (unsigned i = 0; i < 512; i++) {
        state->vram_ptr[32768 + i] = (i * 47 + 7) & 255;
        state->vram_ptr[49152 + i] = (i * 13 + 29) & 255;
    }
}
static void expected_blit(uint8_t *ram, unsigned source, unsigned dest,
                          unsigned source_pitch, unsigned dest_pitch,
                          unsigned pixels, unsigned rows, unsigned bpp,
                          unsigned op, int alpha)
{
    for (unsigned y = 0; y < rows; y++) {
        if (op == NV09F_SET_OPERATION_SRCCOPY)
            memmove(ram + dest + y * dest_pitch,
                    ram + source + y * source_pitch, pixels * bpp);
        else
            for (unsigned x = 0; x < pixels; x++)
                for (unsigned ch = 0; ch < 3; ch++) {
                    unsigned s = source + y * source_pitch + x * 4 + ch;
                    unsigned d = dest + y * dest_pitch + x * 4 + ch;
                    ram[d] =
                        (ram[s] * 0x3580 + ram[d] * (0x7f80 - 0x3580)) / 0x7f80;
                }
    }
    if (alpha >= 0)
        for (unsigned y = 0; y < rows; y++)
            for (unsigned x = 0; x < pixels; x++)
                ram[dest + y * dest_pitch + x * 4 + 3] = alpha;
}
static void blit_method_formats(void)
{
    unsigned formats[] = { NV062_SET_COLOR_FORMAT_LE_Y8,
                           NV062_SET_COLOR_FORMAT_LE_R5G6B5,
                           NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                           NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
                           NV062_SET_COLOR_FORMAT_LE_X8R8G8B8_Z8R8G8B8,
                           NV062_SET_COLOR_FORMAT_LE_Y32 };
    for (unsigned f = 0; f < 6; f++)
        for (unsigned op = 2; op <= 3; op++) {
            fixture();
            fill_blit_ram();
            blit_context(formats[f], op, 64, 80, 32, 40);
            class_method(NV_IMAGE_BLIT, NV09F_CONTROL_POINT_IN, 1 | 1 << 16);
            class_method(NV_IMAGE_BLIT, NV09F_CONTROL_POINT_OUT, 2 | 1 << 16);
            unsigned bpp = f == 0 ? 1 : f == 1 ? 2 : 4;
            uint8_t expected[65536];
            memcpy(expected, state->vram_ptr, sizeof(expected));
            expected_blit(expected, 32768 + 32 + bpp, 49152 + 40 + 2 * bpp, 32,
                          40, 7, 3, bpp, op,
                          f == 3 ? 255 :
                          f == 4 ? 0 :
                                   -1);
            class_method(NV_IMAGE_BLIT, NV09F_SIZE, 7 | 3 << 16);
            assert(!memcmp(expected, state->vram_ptr, sizeof(expected)) &&
                   state->pgraph.draw_time == 0);
            class_method(NV_IMAGE_BLIT, NV09F_SIZE, 0);
            assert(!memcmp(expected, state->vram_ptr, sizeof(expected)));
        }
    groups++;
}
static void blit_tile_tail(void)
{
    fixture();
    fill_blit_ram();
    blit_context(NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
                 NV09F_SET_OPERATION_SRCCOPY, 64, 80, 24, 32);
    uint8_t expected[65536];
    memcpy(expected, state->vram_ptr, sizeof(expected));
    memmove(expected + 49152, expected + 32768, 12);
    memmove(expected + 49152 + 32, expected + 32768 + 24, 7);
    for (unsigned x = 0; x < 3; x++)
        expected[49152 + x * 4 + 3] = 255;
    expected[49152 + 32 + 3] = 255;
    tile_clipped_length = 39;
    class_method(NV_IMAGE_BLIT, NV09F_SIZE, 3 | 3 << 16);
    assert(!memcmp(expected, state->vram_ptr, sizeof(expected)));
    // The min-pitch row clamp does not subtract in/out X, as in GL.
    fixture();
    fill_blit_ram();
    blit_context(NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                 NV09F_SET_OPERATION_SRCCOPY, 64, 80, 16, 24);
    memcpy(expected, state->vram_ptr, sizeof(expected));
    expected_blit(expected, 32768, 49152, 16, 24, 4, 2, 4, 3, -1);
    class_method(NV_IMAGE_BLIT, NV09F_SIZE, 12 | 2 << 16);
    assert(!memcmp(expected, state->vram_ptr, sizeof(expected)));
    groups++;
}
static void blit_surface_alias(void)
{
    fixture();
    query_triangle(0);
    assert(surfaces.color.dirty && raw_color(1, 1) == 0xffff0000);
    blit_context(NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                 NV09F_SET_OPERATION_SRCCOPY, 16, 80, 32, 32);
    class_method(NV_IMAGE_BLIT, NV09F_SIZE, 8 | 8 << 16);
    assert(!memcmp(state->vram_ptr + 1024, state->vram_ptr + 49152, 256));
    assert(raw_color(1, 1) == 0xff00ff00 && !surfaces.color.dirty &&
           state->pgraph.draw_time == 1);
    NV2AMetalCachedSurface *old = surfaces.color;
    cpu_write(49152, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t blue = 0xff0000ff;
        memcpy(state->vram_ptr + 49152 + i * 4, &blue, 4);
    }
    blit_context(NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                 NV09F_SET_OPERATION_SRCCOPY, 80, 16, 32, 32);
    class_method(NV_IMAGE_BLIT, NV09F_CONTROL_POINT_OUT, 5 | 5 << 16);
    class_method(NV_IMAGE_BLIT, NV09F_SIZE, 2 | 2 << 16);
    assert(!old.valid && !state->pgraph.surface_color.draw_dirty &&
           state->pgraph.surface_color.buffer_dirty);
    assert(state->pgraph.draw_time == 2 && raw_color(5, 5) == 0xff0000ff &&
           raw_color(1, 1) == 0xff00ff00);
    query_triangle(0);
    assert(surfaces.color != old && color(5, 5) == 0xff0000ff &&
           color(1, 1) == 0xff00ff00);
    groups++;
}
static void blit_validation(void)
{
    for (unsigned test = 0; test < 6; test++) {
        fixture();
        fill_blit_ram();
        blit_context(NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                     NV09F_SET_OPERATION_SRCCOPY, 64, 80, 32, 32);
        state->pgraph.image_blit.width = state->pgraph.image_blit.height = 8;
        if (test == 0)
            dma[3].limit = 254;
        if (test == 1)
            dma[4].limit = 254;
        if (test == 2)
            dma[3].dma_class = 0;
        if (test == 3)
            state->pgraph.image_blit.context_surfaces = 1;
        if (test == 4)
            state->pgraph.context_surfaces_2d.color_format = 3;
        if (test == 5)
            dma[4].address = 65535;
        state->pgraph.regs_[NV_PGRAPH_CLEARRECTX] =
            state->pgraph.regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
        send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
        NV2AMetalSurfaceRecording *pending = surfaces.cache.recording;
        assert(pending && !pending.submitted);
        uint8_t saved[65536];
        memcpy(saved, state->vram_ptr, sizeof(saved));
        NSError *error = nil;
        qemu_mutex_lock(&state->pgraph.lock);
        assert(![draw.blitter blitWithError:&error]);
        qemu_mutex_unlock(&state->pgraph.lock);
        assert(!memcmp(saved, state->vram_ptr, sizeof(saved)) &&
               surfaces.cache.recording == pending && !pending.cancelled &&
               !pending.submitted);
    }
    groups++;
}
#include "test-metal-blit-submission.h"

static NV2AMetalFramebuffer *copy_frame(void)
{
    qemu_mutex_lock(&state->pgraph.renderer_lock);
    void *handle = pgraph_metal4_copy_framebuffer(state);
    NV2AMetalFramebuffer *frame = (__bridge NV2AMetalFramebuffer *)handle;
    pgraph_metal4_release_framebuffer(handle);
    qemu_mutex_unlock(&state->pgraph.renderer_lock);
    return frame;
}
static NSData *texture_pixels(id<MTLTexture> texture)
{
    assert(texture && texture.width <= 64 &&
           (texture.pixelFormat == MTLPixelFormatBGRA8Unorm ||
            texture.pixelFormat == MTLPixelFormatRGBA8Unorm));
    NSError *error = nil;
    NV2AMetalCommands *read =
        [[NV2AMetalCommands alloc] initWithDevice:texture.device error:&error];
    require(read != nil, error);
    id<MTLBuffer> bytes =
        [read.device newBufferWithLength:texture.height * 256
                                 options:MTLResourceStorageModeShared];
    assert(bytes);
    require([read beginWithError:&error] != nil, error);
    require([read addResource:texture error:&error] &&
                [read addResource:bytes error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [read.commandBuffer computeCommandEncoder];
    assert(e);
    [e copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                        toBuffer:bytes
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e endEncoding];
    require([read submitWithError:&error], error);
    require([read waitUntilIdleWithError:&error], error);
    NSMutableData *pixels =
        [NSMutableData dataWithLength:texture.width * texture.height * 4];
    for (unsigned y = 0; y < texture.height; y++)
        for (unsigned x = 0; x < texture.width; x++) {
            uint32_t result;
            memcpy(&result, (uint8_t *)bytes.contents + y * 256 + x * 4, 4);
            if (texture.pixelFormat == MTLPixelFormatRGBA8Unorm)
                result = (result & 0xff00ff00) | ((result & 255) << 16) |
                         ((result >> 16) & 255);
            memcpy((uint8_t *)pixels.mutableBytes + (y * texture.width + x) * 4,
                   &result, 4);
        }
    return pixels;
}
static uint32_t texture_pixel(id<MTLTexture> texture, unsigned x, unsigned y)
{
    assert(x < texture.width && y < texture.height);
    NSData *pixels = texture_pixels(texture);
    uint32_t result;
    memcpy(&result, (const uint8_t *)pixels.bytes + (y * texture.width + x) * 4,
           4);
    return result;
}
static uint32_t frame_pixel(NV2AMetalFramebuffer *frame, unsigned x, unsigned y)
{
    assert(frame);
    return texture_pixel(frame.texture, x, y);
}
static void surface_registers_preserve_begin(void)
{
    for (unsigned variant = 0; variant < 4; variant++) {
        for (unsigned restore = 0; restore < 2; restore++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            cpu_write(1536, 512);
            if (variant == 1) {
                for (unsigned i = 0; i < 256; i++) {
                    uint16_t yellow = 0xffe0;
                    memcpy(state->vram_ptr + 1536 + i * 2, &yellow, 2);
                }
            } else {
                for (unsigned i = 0; i < 128; i++) {
                    uint32_t yellow = 0xffffff00;
                    memcpy(state->vram_ptr + 1536 + i * 4, &yellow, 4);
                }
            }
            if (variant == 3) {
                send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                send_method(NV097_SET_DEPTH_MASK, 1);
                send_method(NV097_SET_DEPTH_FUNC, 0x201);
                cpu_write(4608, 128);
                memset(state->vram_ptr + 4608, 0, 128);
            }
            begin(PRIM_TYPE_TRIANGLES);
            send_method(variant == 3 ? NV097_SET_SURFACE_ZETA_OFFSET :
                                       NV097_SET_SURFACE_COLOR_OFFSET,
                        512);
            if (variant == 1) {
                send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 16 << 16);
                uint32_t format = 0;
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_COLOR,
                         NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5);
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA,
                         NV097_SET_SURFACE_FORMAT_ZETA_Z16);
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_TYPE,
                         NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                send_method(NV097_SET_SURFACE_FORMAT, format);
                send_method(NV097_SET_SURFACE_PITCH, 32 | 16 << 16);
            } else if (variant == 2) {
                send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 2 | 4 << 16);
            }
            if (restore) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                arrays(0, 3);
                end();
                before_ram_load();
                for (unsigned i = 0; i < 64; i++) {
                    uint32_t red = 0xffff0000;
                    memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
                }
                if (variant == 3)
                    memset(state->vram_ptr + 4096, 255, 128);
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            arrays(0, 3);
            end();
            NSError *error = nil;
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(surfaces.color.address == 1024 &&
                   surfaces.color.transfer.config.format == 8 &&
                   surfaces.color.transfer.texture.width == 8);
            assert(texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                       0xff00ff00 &&
                   texture_pixel(surfaces.color.transfer.texture, 5, 1) ==
                       0xff00ff00);
            if (variant == 3) {
                assert(surfaces.zeta.address == 4096);
                send_method(NV097_SET_SURFACE_COLOR_OFFSET, 512);
            }
            // Register changes become effective at the following Begin.
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(surfaces.color.address == 1536);
            if (variant == 1) {
                assert(surfaces.color.transfer.texture.width == 16 &&
                       surfaces.color.transfer.config.format ==
                           NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5);
                require([surfaces.cache prepareCPUAccessAtAddress:1536
                                                           length:512
                                                            write:NO
                                                            error:&error],
                        error);
                assert(lduw_le_p(state->vram_ptr + 1536 + 32 + 2) == 0x07e0 &&
                       lduw_le_p(state->vram_ptr + 1536 + 7 * 32 + 12 * 2) ==
                           0xffe0);
            } else if (variant == 2) {
                assert(surfaces.color.transfer.texture.width == 6 &&
                       texture_pixel(surfaces.color.transfer.texture, 0, 1) ==
                           0xffffff00 &&
                       texture_pixel(surfaces.color.transfer.texture, 3, 1) ==
                           0xff00ff00);
            } else if (variant == 3) {
                assert(surfaces.zeta.address == 4608 &&
                       texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                           0xffffff00);
            } else {
                assert(texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                           0xff00ff00 &&
                       texture_pixel(surfaces.color.transfer.texture, 7, 7) ==
                           0xffffff00);
            }
        }
    }
    groups++;
}
static void explicit_surface_rebind(void)
{
    for (unsigned operation = 0; operation < 3; operation++) {
        for (unsigned restore = 0; restore < 2; restore++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            cpu_write(1536, 512);
            for (unsigned i = 0; i < 128; i++) {
                uint32_t yellow = 0xffffff00;
                memcpy(state->vram_ptr + 1536 + i * 4, &yellow, 4);
            }
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_SURFACE_COLOR_OFFSET, 512);
            send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 16 << 16);
            send_method(NV097_SET_SURFACE_PITCH, 64 | 16 << 16);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
            float translation = 4;
            memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3],
                   &translation, 4);
            send_method(NV097_SET_BLEND_ENABLE, 1);
            send_method(NV097_SET_BLEND_EQUATION, 0x8006);
            send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0);
            send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0);
            if (operation == 0) {
                qemu_mutex_lock(&pg->lock);
                renderer.ops.surface_flush(state);
                qemu_mutex_unlock(&pg->lock);
            } else if (operation == 1) {
                qemu_event_reset(&pg->flush_complete);
                qatomic_set(&pg->flush_pending, true);
                process_pending();
                qemu_event_wait(&pg->flush_complete);
            } else {
                start_worker();
                qemu_mutex_lock(&pg->renderer_lock);
                renderer.ops.set_surface_scale_factor(state, 2);
                qemu_mutex_unlock(&pg->renderer_lock);
                stop_worker();
            }
            // A later register change must not alter the just-rebound target.
            send_method(NV097_SET_SURFACE_COLOR_OFFSET, 0);
            if (restore) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                arrays(0, 3);
                end();
                before_ram_load();
                for (unsigned i = 0; i < 128; i++) {
                    uint32_t yellow = 0xffffff00;
                    memcpy(state->vram_ptr + 1536 + i * 4, &yellow, 4);
                }
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            arrays(0, 3);
            end();
            NSError *error = nil;
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(surfaces.color.address == 1536);
            assert(surfaces.color.transfer.texture.width ==
                       (operation == 2 ? 32 : 16) &&
                   texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                       0xff0000ff &&
                   texture_pixel(surfaces.color.transfer.texture, 5, 5) ==
                       0xffffff00 &&
                   texture_pixel(surfaces.color.transfer.texture, 9, 1) ==
                       0xffffff00);
            get_report(0);
            process_reports();
            assert(report_result(0) == (operation == 2 ? 7 : 28));
            send_method(NV097_SET_BLEND_ENABLE, 0);
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(surfaces.color.address == 1024 &&
                   texture_pixel(surfaces.color.transfer.texture,
                                 operation == 2 ? 10 : 5,
                                 operation == 2 ? 2 : 1) == 0xffffff00);
        }
    }
    groups++;
}
static void explicit_attachment_masks(void)
{
    for (unsigned mode = 1; mode < 5; mode++) {
        for (unsigned restore = 0; restore < 2; restore++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            cpu_write(1536, 512);
            for (unsigned i = 0; i < 128; i++) {
                uint32_t yellow = 0xffffff00;
                memcpy(state->vram_ptr + 1536 + i * 4, &yellow, 4);
            }
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
            if (mode == 2) {
                pg->surface_shape.zeta_format =
                    NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
                pg->surface_zeta.pitch = 32;
                send_method(NV097_SET_CONTROL0,
                            NV097_SET_CONTROL0_STENCIL_WRITE_ENABLE);
                send_method(NV097_SET_STENCIL_TEST_ENABLE, 1);
                send_method(NV097_SET_STENCIL_FUNC, 0x200);
                send_method(NV097_SET_STENCIL_FUNC_MASK, 255);
                send_method(NV097_SET_STENCIL_MASK, 255);
                send_method(NV097_SET_STENCIL_OP_FAIL, 0x1e00);
                send_method(NV097_SET_STENCIL_OP_ZFAIL, 0x1e00);
                send_method(NV097_SET_STENCIL_OP_ZPASS, 0x1e00);
            } else {
                cpu_write(4096, 128);
                memset(state->vram_ptr + 4096, mode == 4 ? 255 : 0, 128);
                if (mode == 4) {
                    cpu_write(4608, 256);
                    memset(state->vram_ptr + 4608, 255, 256);
                }
                send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                send_method(NV097_SET_DEPTH_MASK, 1);
                send_method(NV097_SET_DEPTH_FUNC, 0x201);
            }
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_SURFACE_COLOR_OFFSET, 512);
            send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 16 << 16);
            send_method(NV097_SET_SURFACE_PITCH, 64 | 32 << 16);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
            if (mode == 2)
                send_method(NV097_SET_CONTROL0, 0);
            else if (mode != 4)
                send_method(NV097_SET_DEPTH_MASK, 0);
            if (mode == 4)
                send_method(NV097_SET_SURFACE_ZETA_OFFSET, 512);
            if (mode >= 3)
                send_method(NV097_SET_COLOR_MASK, 0);
            qemu_event_reset(&pg->flush_complete);
            qatomic_set(&pg->flush_pending, true);
            process_pending();
            qemu_event_wait(&pg->flush_complete);
            assert(mode == 4 ? surfaces.zeta.address == 4608 : !surfaces.zeta);
            assert(mode >= 3 ? !surfaces.color :
                               surfaces.color.address == 1536);
            send_method(NV097_SET_SURFACE_COLOR_OFFSET, 0);
            if (mode == 4)
                send_method(NV097_SET_SURFACE_ZETA_OFFSET, 0);
            float currentPosition[4];
            memcpy(currentPosition, pg->vertex_attributes[0].inline_value, 16);
            if (mode == 3)
                dma[2].limit =
                    0; // No attachments: GL skips even invalid late fetches.
            if (restore) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                arrays(0, 3);
                end();
                before_ram_load();
                for (unsigned i = 0; i < 128; i++) {
                    uint32_t yellow = 0xffffff00;
                    memcpy(state->vram_ptr + 1536 + i * 4, &yellow, 4);
                }
                if (mode == 4)
                    memset(state->vram_ptr + 4608, 255, 256);
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            arrays(0, 3);
            end();
            NSError *error = nil;
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(mode == 4 ? surfaces.zeta.address == 4608 : !surfaces.zeta);
            if (mode == 4) {
                assert(!surfaces.color);
                require([surfaces.cache prepareCPUAccessAtAddress:4608
                                                           length:256
                                                            write:NO
                                                            error:&error],
                        error);
                assert(lduw_le_p(state->vram_ptr + 4608 + 32 + 2) == 0x8000);
            } else if (mode == 3) {
                assert(!memcmp(currentPosition,
                               pg->vertex_attributes[0].inline_value, 16));
                assert(!surfaces.color && !surfaces.cache.count &&
                       (uint32_t)ldl_le_p(state->vram_ptr + 1536 + 64 + 4) ==
                           0xffffff00);
            } else {
                assert(surfaces.color.address == 1536 &&
                       texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                           0xff0000ff &&
                       texture_pixel(surfaces.color.transfer.texture, 9, 1) ==
                           0xffffff00);
            }
            get_report(0);
            process_reports();
            assert(report_result(0) == (mode == 3 ? 0 : 28));
            assert(pg->draw_time == (restore ? 2 : 1));
            dma[2].limit = 1023;
            send_method(NV097_SET_COLOR_MASK,
                        NV097_SET_COLOR_MASK_BLUE_WRITE_ENABLE |
                            NV097_SET_COLOR_MASK_GREEN_WRITE_ENABLE |
                            NV097_SET_COLOR_MASK_RED_WRITE_ENABLE |
                            NV097_SET_COLOR_MASK_ALPHA_WRITE_ENABLE);
            send_method(NV097_SET_DEPTH_TEST_ENABLE, 0);
            send_method(NV097_SET_STENCIL_TEST_ENABLE, 0);
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(surfaces.color.address == 1024 &&
                   texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                       0xffffff00);
        }
    }
    groups++;
}
static void clear_inside_begin(void)
{
    for (unsigned variant = 0; variant < 6; variant++) {
        for (unsigned restore = 0; restore < 4; restore++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            if (variant == 3) {
                pg->surface_shape.zeta_format =
                    NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
                pg->surface_zeta.pitch = 32;
                send_method(NV097_SET_CONTROL0,
                            NV097_SET_CONTROL0_STENCIL_WRITE_ENABLE);
                send_method(NV097_SET_STENCIL_TEST_ENABLE, 1);
                send_method(NV097_SET_STENCIL_FUNC, 0x207);
                send_method(NV097_SET_STENCIL_FUNC_REF, 6);
                send_method(NV097_SET_STENCIL_FUNC_MASK, 255);
                send_method(NV097_SET_STENCIL_MASK, 0);
                send_method(NV097_SET_STENCIL_OP_FAIL, 0x1e00);
                send_method(NV097_SET_STENCIL_OP_ZFAIL, 0x1e00);
                send_method(NV097_SET_STENCIL_OP_ZPASS, 0x1e01);
                pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 0xffffff05;
            } else {
                pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 65535;
                if (variant == 2) {
                    send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                    send_method(NV097_SET_DEPTH_MASK, 0);
                    send_method(NV097_SET_DEPTH_FUNC, 0x201);
                }
            }
            pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff00ff00;
            pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
                7 << 16;
            // Larger cached attachments give Begin an8x8 viewport and4x4
            // scissor.
            send_method(NV097_CLEAR_SURFACE,
                        NV097_CLEAR_SURFACE_COLOR |
                            (variant == 2 ? NV097_CLEAR_SURFACE_Z :
                             variant == 3 ? NV097_CLEAR_SURFACE_Z |
                                                NV097_CLEAR_SURFACE_STENCIL :
                                            0));
            send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 4 << 16);
            send_method(NV097_SET_SURFACE_CLIP_VERTICAL, 4 << 16);
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
            send_method(NV097_SET_DITHER_ENABLE, 1);
            if (variant == 4) {
                cpu_write(1536, 512);
                for (unsigned i = 0; i < 128; i++) {
                    uint32_t yellow = 0xffffff00;
                    memcpy(state->vram_ptr + 1536 + i * 4, &yellow, 4);
                }
                send_method(NV097_SET_SURFACE_COLOR_OFFSET, 512);
                send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 16 << 16);
                send_method(NV097_SET_SURFACE_CLIP_VERTICAL, 8 << 16);
                send_method(NV097_SET_SURFACE_PITCH, 64 | 16 << 16);
            }
            if (variant == 2)
                pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 0xc000;
            else if (variant == 3)
                pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 0xffffff03;
            uint32_t clear = (variant == 0 || variant == 4) ?
                                 NV097_CLEAR_SURFACE_COLOR :
                             variant == 1 ? NV097_CLEAR_SURFACE_R :
                             variant == 2 ? NV097_CLEAR_SURFACE_Z :
                             variant == 3 ? NV097_CLEAR_SURFACE_STENCIL :
                                            0;
            if (restore == 2) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                assert(!surfaces.color && !surfaces.cache.count);
            }
            if (restore == 3) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                             length:65536];
                BOOL colorDirty = pg->surface_color.buffer_dirty;
                BOOL zetaDirty = pg->surface_zeta.buffer_dirty;
                SurfaceShape lastShape = pg->last_surface_shape;
                arrays(0, 3);
                end();
                before_ram_load();
                memcpy(state->vram_ptr, ram.bytes, ram.length);
                pg->surface_color.buffer_dirty = !colorDirty;
                pg->surface_zeta.buffer_dirty = !zetaDirty;
                memset(&pg->last_surface_shape, 255, sizeof(SurfaceShape));
                assert(load_vertex_snapshot(fd) == 0);
                assert(pg->surface_color.buffer_dirty == colorDirty &&
                       pg->surface_zeta.buffer_dirty == zetaDirty &&
                       !memcmp(&pg->last_surface_shape, &lastShape,
                               sizeof(lastShape)));
                pg->draw_arrays_length = 0;
                after_ram_load();
                assert(pg->surface_color.buffer_dirty == colorDirty &&
                       pg->surface_zeta.buffer_dirty == zetaDirty);
                close(fd);
            }
            send_method(NV097_CLEAR_SURFACE, clear);
            NSError *captureError = nil;
            qemu_mutex_lock(&pg->lock);
            NSData *capture = [draw beginSnapshotWithError:&captureError];
            qemu_mutex_unlock(&pg->lock);
            require(capture != nil, captureError);
            assert((uint32_t)ldl_be_p((const uint8_t *)capture.bytes + 12) &
                   NV_PGRAPH_CONTROL_0_DITHERENABLE);
            assert(ldl_be_p((const uint8_t *)capture.bytes + 48 + 7 * 4) == 0);
            if (restore) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                arrays(0, 3);
                end();
                before_ram_load();
                for (unsigned i = 0; i < 64; i++) {
                    uint32_t background = 0xff00ff00;
                    memcpy(state->vram_ptr + 1024 + i * 4, &background, 4);
                    if (variant == 2) {
                        uint16_t depth = 0xc000;
                        memcpy(state->vram_ptr + 4096 + i * 2, &depth, 2);
                    } else if (variant == 3) {
                        uint32_t packed = 0xffffff03;
                        memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
                    }
                }
                if (variant == 4)
                    for (unsigned y = 0; y < 8; y++)
                        for (unsigned x = 0; x < 16; x++) {
                            uint32_t background =
                                x < 8 ? 0xff00ff00 : 0xffffff00;
                            memcpy(state->vram_ptr + 1536 + y * 64 + x * 4,
                                   &background, 4);
                        }
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            arrays(0, 3);
            end();
            uint32_t inside = variant == 1 ? 0xff00ff00 : 0xff0000ff;
            if (variant == 4) {
                NSError *error = nil;
                require([surfaces.cache waitUntilIdleWithError:&error], error);
                assert(surfaces.color.address == 1536 &&
                       surfaces.color.transfer.texture.width == 16 &&
                       texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                           inside &&
                       texture_pixel(surfaces.color.transfer.texture, 5, 1) ==
                           inside &&
                       texture_pixel(surfaces.color.transfer.texture, 7, 7) ==
                           0xff00ff00 &&
                       texture_pixel(surfaces.color.transfer.texture, 9, 1) ==
                           0xffffff00 &&
                       color(1, 1) == 0xff00ff00);
            } else {
                assert(color(1, 1) == inside && color(5, 1) == inside &&
                       color(7, 7) == 0xff00ff00);
            }
            if (variant == 2 || variant == 3) {
                NSError *error = nil;
                require([surfaces.cache prepareCPUAccessAtAddress:4096
                                                           length:256
                                                            write:NO
                                                            error:&error],
                        error);
                if (variant == 2)
                    assert(lduw_le_p(state->vram_ptr + 4096 + 16 + 2) ==
                               0x8000 &&
                           lduw_le_p(state->vram_ptr + 4096 + 7 * 16 + 14) ==
                               0xc000);
                else
                    assert((uint32_t)ldl_le_p(state->vram_ptr + 4096 + 32 +
                                              4) == 0xffffff06 &&
                           (uint32_t)ldl_le_p(state->vram_ptr + 4096 + 7 * 32 +
                                              28) == 0xffffff03);
            }
            get_report(0);
            process_reports();
            assert(report_result(0) ==
                   28); // Clear itself is outside the draw query.
            send_method(NV097_SET_DEPTH_TEST_ENABLE, 0);
            send_method(NV097_SET_STENCIL_TEST_ENABLE, 0);
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            if (variant == 4) {
                NSError *error = nil;
                require([surfaces.cache waitUntilIdleWithError:&error], error);
                assert(texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                           0xffffff00 &&
                       texture_pixel(surfaces.color.transfer.texture, 5, 1) ==
                           0xffffff00);
            } else {
                assert(color(1, 1) == 0xffffff00 && color(5, 1) == inside);
            }
        }
    }
    groups++;
}
static void restored_binding_metadata(void)
{
    for (unsigned mask = 0; mask < 4; mask++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff00ff00;
        pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 65535;
        pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
            7 << 16;
        send_method(NV097_CLEAR_SURFACE,
                    NV097_CLEAR_SURFACE_COLOR | NV097_CLEAR_SURFACE_Z);
        send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
        send_method(NV097_SET_DEPTH_FUNC, 0x201);
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
        begin(PRIM_TYPE_TRIANGLES);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
        if (mask & 1)
            send_method(NV097_SET_SURFACE_COLOR_OFFSET, 512);
        if (mask & 2)
            send_method(NV097_SET_SURFACE_ZETA_OFFSET, 512);
        assert(pg->surface_color.buffer_dirty == !!(mask & 1) &&
               pg->surface_zeta.buffer_dirty == !!(mask & 2));
        renderer.ops.pre_savevm_trigger(state);
        process_pending();
        renderer.ops.pre_savevm_wait(state);
        int fd = new_vertex_snapshot_file();
        save_vertex_snapshot(fd);
        NSData *ram = [NSData dataWithBytes:state->vram_ptr length:65536];
        arrays(0, 3);
        end();
        before_ram_load();
        memcpy(state->vram_ptr, ram.bytes, ram.length);
        pg->surface_color.buffer_dirty = !(mask & 1);
        pg->surface_zeta.buffer_dirty = !(mask & 2);
        assert(load_vertex_snapshot(fd) == 0);
        pg->draw_arrays_length = 0;
        after_ram_load();
        assert(pg->surface_color.buffer_dirty == !!(mask & 1) &&
               pg->surface_zeta.buffer_dirty == !!(mask & 2));
        arrays(0, 3);
        end();
        assert(surfaces.color.address == 1024 &&
               surfaces.zeta.address == 4096 && color(1, 1) == 0xff0000ff);
        assert(pg->surface_color.buffer_dirty == !!(mask & 1) &&
               pg->surface_zeta.buffer_dirty == !!(mask & 2));
        get_report(0);
        process_reports();
        assert(report_result(0) == 28);
        close(fd);
    }
    groups++;
}
static void clear_zero_binding_changes(void)
{
    for (unsigned change = 0; change < 4; change++) {
        for (unsigned restore = 0; restore < 2; restore++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff00ff00;
            pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 65535;
            pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
                7 << 16;
            send_method(NV097_CLEAR_SURFACE,
                        NV097_CLEAR_SURFACE_COLOR | NV097_CLEAR_SURFACE_Z);
            send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
            send_method(NV097_SET_DEPTH_FUNC, 0x201);
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
            if (change == 0)
                send_method(NV097_SET_SURFACE_COLOR_OFFSET, 512);
            else if (change == 1)
                send_method(NV097_SET_SURFACE_ZETA_OFFSET, 512);
            else if (change == 2)
                send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 4 << 16);
            else {
                uint32_t format = 0;
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_COLOR, 8);
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA, 1);
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_TYPE,
                         NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                SET_MASK(
                    format, NV097_SET_SURFACE_FORMAT_ANTI_ALIASING,
                    NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_CENTER_CORNER_2);
                send_method(NV097_SET_SURFACE_FORMAT, format);
            }
            send_method(NV097_CLEAR_SURFACE, 0);
            unsigned mask = change == 0 ? 2 : change == 1 ? 1 : 0;
            assert(!!surfaces.color == !!(mask & 1) &&
                   !!surfaces.zeta == !!(mask & 2));
            renderer.ops.pre_savevm_trigger(state);
            process_pending();
            renderer.ops.pre_savevm_wait(state);
            NSData *capture =
                [NSData dataWithBytes:pg->metal4_begin_capture
                               length:pg->metal4_begin_capture_size];
            assert((uint32_t)ldl_be_p(
                       (const uint8_t *)capture.bytes + capture.length -
                       NV2AMetalSurfaceBindingsBytes + 8) == mask);
            if (restore) {
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                             length:65536];
                arrays(0, 3);
                end();
                before_ram_load();
                memcpy(state->vram_ptr, ram.bytes, ram.length);
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            if (!mask)
                dma[2].limit = 0;
            arrays(0, 3);
            end();
            assert(!!surfaces.color == !!(mask & 1) &&
                   !!surfaces.zeta == !!(mask & 2));
            assert(color(1, 1) == (change == 1 ? 0xff0000ff : 0xff00ff00));
            get_report(0);
            process_reports();
            assert(report_result(0) == (mask ? 28 : 0));
            dma[2].limit = 1023;
            send_method(NV097_SET_DEPTH_TEST_ENABLE, 0);
            if (change == 3) {
                uint32_t format = 0;
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_COLOR, 8);
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA, 1);
                SET_MASK(format, NV097_SET_SURFACE_FORMAT_TYPE,
                         NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                send_method(NV097_SET_SURFACE_FORMAT, format);
            }
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            NSError *error = nil;
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(surfaces.color.address == (change == 0 ? 1536 : 1024) &&
                   texture_pixel(surfaces.color.transfer.texture, 1, 1) ==
                       0xffffff00);
        }
    }
    groups++;
}
static void clear_aa_swizzle_begin(void)
{
    for (unsigned aa = 0; aa < 3; aa++)
        for (unsigned swizzle = 0; swizzle < 2; swizzle++)
            for (unsigned scale = 1; scale <= 2; scale++)
                for (unsigned restore = 0; restore < 2; restore++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    unsigned ax = aa ? 2 : 1, ay = aa == 2 ? 2 : 1;
                    unsigned width = 8 * ax, height = 8 * ay;
                    unsigned sx = ax * scale, sy = ay * scale;
                    pg->surface_scale_factor = scale;
                    g_config.display.quality.surface_scale = scale;
                    uint32_t format = 0;
                    SET_MASK(format, NV097_SET_SURFACE_FORMAT_COLOR, 8);
                    SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA, 1);
                    SET_MASK(format, NV097_SET_SURFACE_FORMAT_TYPE,
                             swizzle ? NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE :
                                       NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                    SET_MASK(format, NV097_SET_SURFACE_FORMAT_ANTI_ALIASING,
                             aa);
                    SET_MASK(format, NV097_SET_SURFACE_FORMAT_WIDTH, 3);
                    SET_MASK(format, NV097_SET_SURFACE_FORMAT_HEIGHT, 3);
                    send_method(NV097_SET_SURFACE_FORMAT, format);
                    send_method(NV097_SET_SURFACE_PITCH, width * 4 | (width * 2)
                                                                         << 16);
                    cpu_write(1024, width * height * 4);
                    for (unsigned i = 0; i < width * height; i++) {
                        uint32_t red = 0xffff0000;
                        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
                    }
                    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                PS_REGISTER_C0);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
                    begin(PRIM_TYPE_TRIANGLES);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
                    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff00ff00;
                    pg->regs_[NV_PGRAPH_CLEARRECTX] =
                        pg->regs_[NV_PGRAPH_CLEARRECTY] = 6 | 7 << 16;
                    send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
                    if (restore) {
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        int fd = new_vertex_snapshot_file();
                        save_vertex_snapshot(fd);
                        NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                     length:65536];
                        arrays(0, 3);
                        end();
                        before_ram_load();
                        memcpy(state->vram_ptr, ram.bytes, ram.length);
                        assert(load_vertex_snapshot(fd) == 0);
                        pg->draw_arrays_length = 0;
                        after_ram_load();
                        close(fd);
                    }
                    arrays(0, 3);
                    end();
                    NSError *error = nil;
                    require([surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    id<MTLTexture> target = surfaces.color.transfer.texture;
                    assert(target.width == width * scale &&
                           target.height == height * scale &&
                           surfaces.color.transfer.config.swizzle == swizzle);
                    NSData *pixels = texture_pixels(target);
                    unsigned samples = 0;
                    for (unsigned y = 0; y < target.height; y++)
                        for (unsigned x = 0; x < target.width; x++) {
                            // Centres strictly inside x/sx+y/sy<8; the
                            // descending edge excludes its on-edge centres.
                            BOOL inside = (2 * x + 1) * sy + (2 * y + 1) * sx <
                                          16 * sx * sy;
                            BOOL cleared = x >= 6 * sx && y >= 6 * sy;
                            uint32_t expected = inside  ? 0xff0000ff :
                                                cleared ? 0xff00ff00 :
                                                          0xffff0000;
                            uint32_t actual;
                            memcpy(&actual,
                                   (const uint8_t *)pixels.bytes +
                                       (y * target.width + x) * 4,
                                   4);
                            assert(actual == expected);
                            samples += inside;
                        }
                    get_report(0);
                    process_reports();
                    assert(report_result(0) == samples / (scale * scale));
                    // Flush to guest bytes, then independently interleave the
                    // coordinate bits for the rectangular Morton layout.
                    require([surfaces.cache
                                prepareCPUAccessAtAddress:1024
                                                   length:width * height * 4
                                                    write:NO
                                                    error:&error],
                            error);
                    for (unsigned y = 0; y < height; y++)
                        for (unsigned x = 0; x < width; x++) {
                            unsigned index = y * width + x;
                            if (swizzle) {
                                index = 0;
                                unsigned dst = 0;
                                for (unsigned bit = 0;
                                     (1u << bit) < MAX(width, height); bit++) {
                                    if ((1u << bit) < width)
                                        index |= ((x >> bit) & 1) << dst++;
                                    if ((1u << bit) < height)
                                        index |= ((y >> bit) & 1) << dst++;
                                }
                            }
                            uint32_t actual, expected;
                            memcpy(&actual, state->vram_ptr + 1024 + index * 4,
                                   4);
                            memcpy(
                                &expected,
                                (const uint8_t *)pixels.bytes +
                                    ((y * scale) * target.width + x * scale) *
                                        4,
                                4);
                            assert(actual == expected);
                        }
                    begin(PRIM_TYPE_TRIANGLES);
                    arrays(0, 3);
                    end();
                    require([surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    assert(texture_pixel(surfaces.color.transfer.texture, sx,
                                         sy) == 0xffffff00);
                }
    groups++;
}
static void depth_replace_snapshot(void)
{
    for (unsigned stage = 2; stage <= 3; stage++)
        for (unsigned z24 = 0; z24 < 2; z24++)
            for (unsigned far = 0; far < 2; far++)
                for (unsigned restore = 0; restore < 2; restore++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    if (z24) {
                        pg->surface_shape.zeta_format =
                            NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
                        pg->surface_zeta.pitch = 32;
                        reg_float(NV_PGRAPH_ZCLIPMAX, 16777215);
                    }
                    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xffff0000;
                    pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] =
                        z24 ? 0x8000007a : 0x8000;
                    pg->regs_[NV_PGRAPH_CLEARRECTX] =
                        pg->regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
                    send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR |
                                                         NV097_CLEAR_SURFACE_Z);
                    send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                    send_method(NV097_SET_DEPTH_MASK, 1);
                    send_method(NV097_SET_DEPTH_FUNC, 0x201);
                    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                PS_REGISTER_C0);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
                    pg->vertex_attributes[9].inline_value[0] = 1;
                    pg->vertex_attributes[9 + stage - 1].inline_value[0] =
                        far ? 1.5f : .5f;
                    pg->vertex_attributes[9 + stage].inline_value[0] = 2;
                    send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                PS_TEXTUREMODES_PASSTHRU |
                                    PS_TEXTUREMODES_DOTPRODUCT
                                        << (5 * (stage - 1)) |
                                    PS_TEXTUREMODES_DOT_ZW << (5 * stage));
                    begin(PRIM_TYPE_TRIANGLES);
                    send_method(NV097_SET_SHADER_STAGE_PROGRAM, 0);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
                    if (restore) {
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        int fd = new_vertex_snapshot_file();
                        save_vertex_snapshot(fd);
                        NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                     length:65536];
                        arrays(0, 3);
                        end();
                        before_ram_load();
                        memcpy(state->vram_ptr, ram.bytes, ram.length);
                        assert(load_vertex_snapshot(fd) == 0);
                        pg->draw_arrays_length = 0;
                        after_ram_load();
                        close(fd);
                    }
                    arrays(0, 3);
                    end();
                    assert(color(1, 1) == (far ? 0xffff0000 : 0xff0000ff));
                    get_report(0);
                    process_reports();
                    assert(report_result(0) == (far ? 0 : 28));
                    NSError *error = nil;
                    require([surfaces.cache prepareCPUAccessAtAddress:4096
                                                               length:256
                                                                write:NO
                                                                error:&error],
                            error);
                    if (z24) {
                        uint32_t packed;
                        memcpy(&packed,
                               state->vram_ptr + 4096 + (1 * 8 + 1) * 4, 4);
                        assert((packed >> 8) == (far ? 0x800000 : 0x3fffff));
                    } else {
                        uint16_t packed;
                        memcpy(&packed,
                               state->vram_ptr + 4096 + (1 * 8 + 1) * 2, 2);
                        assert(packed == (far ? 0x8000 : 0x3fff));
                    }
                    send_method(NV097_SET_DEPTH_FUNC, 0x207);
                    begin(PRIM_TYPE_TRIANGLES);
                    arrays(0, 3);
                    end();
                    assert(color(1, 1) == 0xffffff00);
                }
    groups++;
}
static void float_surface_shadow_snapshot(BOOL f24)
{
    const unsigned f16_codes[] = { 0, 0x000f, 0x0fff, 0x1000, 0x8000, 0xffff };
    const unsigned f24_codes[] = { 0,        0x010001, 0x3f1234,
                                   0x7f8017, 0xfefffe, 0xfeffff };
    const unsigned *codes = f24 ? f24_codes : f16_codes;
    unsigned cases = 0;
    for (unsigned i = 0; i < ARRAY_SIZE(f16_codes); i++)
        for (unsigned project3 = 0; project3 < 2; project3++)
            for (unsigned relation = 0; relation < 3; relation++)
                for (unsigned function = 0; function < 8; function++)
                    for (unsigned restore = 0; restore < 2; restore++) {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        unsigned code = codes[i];
                        uint32_t packed = f24 ? code << 8 | (0x5a + i) : code;
                        if (f24) {
                            uint32_t format = 0;
                            SET_MASK(
                                format, NV097_SET_SURFACE_FORMAT_COLOR,
                                NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8);
                            SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA,
                                     NV097_SET_SURFACE_FORMAT_ZETA_Z24S8);
                            SET_MASK(format, NV097_SET_SURFACE_FORMAT_TYPE,
                                     NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                            send_method(NV097_SET_SURFACE_FORMAT, format);
                            send_method(NV097_SET_SURFACE_PITCH, 32 | 32 << 16);
                        }
                        float sampled = 0;
                        if (code)
                            sampled = f24 ? ldexpf(1 + (code % 65536) / 65536.f,
                                                   (int)(code / 65536) - 127) :
                                            ldexpf(1 + (code % 4096) / 4096.f,
                                                   (int)(code / 4096) - 7);
                        float reference = sampled;
                        if (relation == 0)
                            reference = sampled ?
                                            nextafterf(sampled, -INFINITY) :
                                            -(f24 ? 0x1p-126f : 0x1p-20f);
                        else if (relation == 2)
                            reference = sampled ?
                                            nextafterf(sampled, INFINITY) :
                                            (f24 ? 0x1p-126f : 0x1p-20f);
                        float compare_ref =
                            project3 ? fminf(f24 ? 0x1.ffffp127f : 511.9375f,
                                             fmaxf(0, reference)) :
                                       0;
                        if (!f24 && project3 && compare_ref >= 1.0f / 64) {
                            int exponent;
                            double fraction = frexp(compare_ref, &exponent);
                            compare_ref = ldexpf(
                                1 + floor((fraction * 2 - 1) * 4096) / 4096,
                                exponent - 1);
                        }
                        const BOOL expected[] = { NO,
                                                  (sampled < compare_ref),
                                                  (sampled == compare_ref),
                                                  (sampled <= compare_ref),
                                                  (sampled > compare_ref),
                                                  (sampled != compare_ref),
                                                  (sampled >= compare_ref),
                                                  YES };
                        uint32_t result = expected[function] ? 0xffffffff : 0;
                        send_method(NV097_SET_CONTROL0,
                                    NV097_SET_CONTROL0_Z_FORMAT);
                        send_method(NV097_SET_ZSTENCIL_CLEAR_VALUE, packed);
                        send_method(NV097_SET_COLOR_CLEAR_VALUE, 0xffff0000);
                        send_method(NV097_SET_CLEAR_RECT_HORIZONTAL, 7 << 16);
                        send_method(NV097_SET_CLEAR_RECT_VERTICAL, 7 << 16);
                        send_method(
                            NV097_CLEAR_SURFACE,
                            NV097_CLEAR_SURFACE_Z | NV097_CLEAR_SURFACE_COLOR |
                                (f24 ? NV097_CLEAR_SURFACE_STENCIL : 0));
                        assert(surfaces.zeta && surfaces.zeta.dirty &&
                               surfaces.zeta.transfer.config.floating_depth);
                        /* Point texture DMA B at the GPU-dirty zeta surface.
                         * It must download raw float depth, then decode a
                         * texture; color RTT aliasing cannot satisfy this
                         * contract. */
                        send_method(NV097_SET_CONTEXT_DMA_B, 32);
                        uint32_t format = 0;
                        SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA,
                                 2);
                        SET_MASK(
                            format, NV097_SET_TEXTURE_FORMAT_COLOR,
                            f24 ?
                                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FLOAT :
                                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FLOAT);
                        SET_MASK(format,
                                 NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 2);
                        SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                                 NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                        SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS,
                                 1);
                        send_method(NV097_SET_TEXTURE_FORMAT, format);
                        send_method(NV097_SET_TEXTURE_OFFSET, 0);
                        send_method(NV097_SET_TEXTURE_CONTROL0,
                                    NV097_SET_TEXTURE_CONTROL0_ENABLE);
                        send_method(NV097_SET_TEXTURE_CONTROL1, (f24 ? 32 : 16)
                                                                    << 16);
                        send_method(NV097_SET_TEXTURE_IMAGE_RECT, 8 << 16 | 8);
                        send_method(NV097_SET_TEXTURE_FILTER,
                                    1 << 16 | 1 << 24);
                        send_method(NV097_SET_TEXTURE_ADDRESS,
                                    3 | 3 << 8 | 3 << 16);
                        send_method(NV097_SET_SHADOW_DEPTH_FUNC, function);
                        send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                    project3 ? PS_TEXTUREMODES_PROJECT3D :
                                               PS_TEXTUREMODES_PROJECT2D);
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                    PS_REGISTER_T0);
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                    (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8);
                        float w = relation == 1 && reference < 0x1p127f ? 2 : 1;
                        pg->vertex_attributes[9].inline_value[0] = 1.5f * w;
                        pg->vertex_attributes[9].inline_value[1] = 1.5f * w;
                        pg->vertex_attributes[9].inline_value[2] =
                            reference * w;
                        pg->vertex_attributes[9].inline_value[3] = w;
                        begin(PRIM_TYPE_TRIANGLES);
                        // Begin must retain the bound shadow function and
                        // shader mode.
                        send_method(NV097_SET_SHADOW_DEPTH_FUNC, function ^ 7);
                        send_method(NV097_SET_SHADER_STAGE_PROGRAM, 0);
                        if (restore) {
                            renderer.ops.pre_savevm_trigger(state);
                            process_pending();
                            renderer.ops.pre_savevm_wait(state);
                            int fd = new_vertex_snapshot_file();
                            save_vertex_snapshot(fd);
                            NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                         length:65536];
                            arrays(0, 3);
                            end();
                            assert(color(1, 1) == result);
                            before_ram_load();
                            memcpy(state->vram_ptr, ram.bytes, ram.length);
                            assert(load_vertex_snapshot(fd) == 0);
                            pg->draw_arrays_length = 0;
                            after_ram_load();
                            close(fd);
                        }
                        arrays(0, 3);
                        end();
                        if (color(1, 1) != result) {
                            fprintf(stderr,
                                    "F%u chain code%x project%u relation%u "
                                    "function%u restore%u: got%x expected%x\n",
                                    f24 ? 24 : 16, code, project3, relation,
                                    function, restore, color(1, 1), result);
                            abort();
                        }
                        for (unsigned y = 0; y < 8; y++)
                            for (unsigned x = 0; x < 8; x++)
                                assert(color(x, y) ==
                                       (x + y < 7 ? result : 0xffff0000));
                        NSError *error = nil;
                        require([surfaces.cache
                                    prepareCPUAccessAtAddress:4096
                                                       length:f24 ? 256 : 128
                                                        write:NO
                                                        error:&error],
                                error);
                        for (unsigned pixel = 0; pixel < 64; pixel++) {
                            uint32_t raw = 0;
                            memcpy(&raw,
                                   state->vram_ptr + 4096 +
                                       pixel * (f24 ? 4 : 2),
                                   f24 ? 4 : 2);
                            assert(raw == packed);
                        }
                        cases++;
                    }
    printf("Metal4 F%u surface/texture/shadow: %u dispatcher cases with "
           "Begin/SaveRestore PASS\n",
           f24 ? 24 : 16, cases);
    groups++;
}

static unsigned f24_gradient_words(unsigned batch, unsigned quads, BOOL line,
                                   unsigned scale, BOOL swizzle, unsigned ref,
                                   BOOL perspective, unsigned clipping)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    require([surfaces.cache prepareCPUAccessAtAddress:8192
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    NV2AMetalSurfaceConfig config = surfaces.zeta.transfer.config;
    if (!surfaces.zeta) {
        // Save quiescence evicts live surfaces; inspect the bound wire layout.
        PGRAPHState *pg = &state->pgraph;
        assert(pg->metal4_begin_capture_size >= NV2AMetalSurfaceBindingsBytes);
        NSData *binding = [NSData dataWithBytes:pg->metal4_begin_capture +
                                                pg->metal4_begin_capture_size -
                                                NV2AMetalSurfaceBindingsBytes
                                         length:NV2AMetalSurfaceBindingsBytes];
        NV2AMetalSurfaceBindings decoded;
        require(nv2a_metal_surface_bindings_decode(binding, &decoded, &error),
                error);
        assert(decoded.zeta.address == 8192);
        config = decoded.zeta.config;
    }
    assert(config.floating_depth && config.swizzle == swizzle &&
           config.scale == scale && config.width == 32 && config.height == 32);
    for (unsigned y = 0; y < 32; y++)
        for (unsigned x = 0; x < 32; x++) {
            unsigned tile = (y / 8) * 4 + x / 8, exponent = batch * 16 + tile;
            unsigned pattern = exponent % 4, reverse = (exponent >> 2) & 1;
            unsigned k = pattern & 2 ? y % 8 : x % 8;
            unsigned cross = pattern & 2 ? x % 8 : y % 8;
            // Independent fixed 5-bit square Morton address, not the transfer
            // helper.
            unsigned index =
                swizzle ? (x & 1) | (x & 2) << 1 | (x & 4) << 2 | (x & 8) << 3 |
                              (x & 16) << 4 | (y & 1) << 1 | (y & 2) << 2 |
                              (y & 4) << 3 | (y & 8) << 4 | (y & 16) << 5 :
                          y * 32 + x;
            uint32_t actual_color, actual_zeta;
            memcpy(&actual_color, state->vram_ptr + 1024 + index * 4, 4);
            memcpy(&actual_zeta, state->vram_ptr + 8192 + index * 4, 4);
            BOOL active = tile < quads && exponent < (perspective ? 128 : 255);
            double z = 0;
            BOOL inside = YES;
            if (perspective) {
                double t =
                    line ? ((int)k - 2 + .5 / scale) / 4 : (k + .5 / scale) / 8;
                if (pattern & 1)
                    t = 1 - t;
                double base = ldexp(1, (int)exponent - 64);
                double w = base / (1 - t / 2);
                // Standalone lines have no polygon offset, even when enabled.
                z = line ? w : w + 0x1p-65 + .5 * w * w / (16 * base);
                if (clipping) {
                    double lo = ldexp(1.25, (int)batch * 16 - 64);
                    double hi = ldexp(1.75, (int)batch * 16 - 64);
                    inside = z >= lo && z <= hi;
                    if (clipping == 1)
                        z = fmin(fmax(z, lo), hi);
                }
            }
            BOOL visible = active && (clipping != 2 || inside);
            BOOL covered = actual_color == 0xff0000ff;
            assert(actual_color == 0xffff0000 || covered);
            if (!line && covered != visible) {
                fprintf(
                    stderr,
                    "F24 coverage W%u clip%u batch%u quads%u scale%u swizzle%u "
                    "pixel%u,%u color%08x zeta%08x expectedCovered%u\n",
                    perspective, clipping, batch, quads, scale, swizzle, x, y,
                    actual_color, actual_zeta, visible);
                abort();
            } else if (line) {
                if (!visible || cross == 0 || cross == 7 || k == 0 || k == 7)
                    assert(!covered);
                if (visible && cross == 3 && k >= 3 && k <= 4)
                    assert(covered);
            }
            uint32_t expected = 0xfeffffa5;
            if (covered) {
                unsigned fraction;
                if (exponent < 3) {
                    unsigned endpoint = line ? reverse : 0;
                    fraction = (endpoint ^ (pattern & 1)) ? 0x8000 : 0x4000;
                } else {
                    // Interior line endpoints keep neighboring tiles disjoint.
                    int delta = line ? 4096 * ((int)k - 2) + 2048 / scale :
                                       2048 * k + 1024 / scale;
                    fraction = pattern & 1 ? 0x8000 - delta : 0x4000 + delta;
                }
                unsigned code = exponent ? (exponent << 16) | fraction : 0;
                if (perspective) {
                    float depth = z;
                    memcpy(&code, &depth, 4);
                    code >>= 7;
                }
                expected = code << 8 | (0xa5 & ~0x3cu) | (ref & 0x3c);
            }
            if (actual_zeta != expected) {
                fprintf(stderr,
                        "F24 dispatcher W%u clip%u batch%u quads%u line%u "
                        "scale%u swizzle%u "
                        "pixel%u,%u color%08x: zeta%08x expected%08x\n",
                        perspective, clipping, batch, quads, line, scale,
                        swizzle, x, y, actual_color, actual_zeta, expected);
                abort();
            }
        }
    return 1024;
}

static void f24_gradient_begin_snapshot(BOOL perspective, unsigned clipping)
{
    assert(perspective || !clipping);
    unsigned cases = 0, restored = 0, words = 0;
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned line = 0; line < 2; line++)
            for (unsigned swizzle = 0; swizzle < 2; swizzle++)
                for (unsigned scale = 1; scale <= 2; scale++)
                    for (unsigned restore = 0; restore < 2; restore++) {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        dma[0].limit = dma[1].limit = dma[2].limit = 4095;
                        dma[1].address = 8192;
                        pg->surface_scale_factor = scale;
                        g_config.display.quality.surface_scale = scale;
                        uint32_t format = 0;
                        SET_MASK(format, NV097_SET_SURFACE_FORMAT_COLOR,
                                 NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8);
                        SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA,
                                 NV097_SET_SURFACE_FORMAT_ZETA_Z24S8);
                        SET_MASK(format, NV097_SET_SURFACE_FORMAT_TYPE,
                                 swizzle ?
                                     NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE :
                                     NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                        SET_MASK(format, NV097_SET_SURFACE_FORMAT_WIDTH, 5);
                        SET_MASK(format, NV097_SET_SURFACE_FORMAT_HEIGHT, 5);
                        send_method(NV097_SET_SURFACE_FORMAT, format);
                        send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL,
                                    32 << 16);
                        send_method(NV097_SET_SURFACE_CLIP_VERTICAL, 32 << 16);
                        send_method(NV097_SET_SURFACE_PITCH, 128 | 128 << 16);
                        reg_float(NV_PGRAPH_ZCLIPMAX, 0x1.ffffp127f);
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                    PS_REGISTER_C0);
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                    (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8);
                        send_method(NV097_SET_STENCIL_TEST_ENABLE, 1);
                        send_method(NV097_SET_STENCIL_FUNC_MASK, 255);
                        send_method(NV097_SET_STENCIL_OP_FAIL, 0x1e00);
                        send_method(NV097_SET_STENCIL_OP_ZFAIL, 0x1e00);
                        send_method(NV097_SET_STENCIL_OP_ZPASS, 0x1e01);
                        send_method(NV097_SET_CLEAR_RECT_HORIZONTAL, 31 << 16);
                        send_method(NV097_SET_CLEAR_RECT_VERTICAL, 31 << 16);
                        for (unsigned batch = 0; batch < (perspective ? 8 : 16);
                             batch++) {
                            unsigned quads =
                                !perspective && batch == 15 ? 15 : 16;
                            unsigned stride = line ? 2 : 6, split = 8 * stride;
                            unsigned count = quads * stride;
                            unsigned ref = (batch * 17 + 0x5a) & 255;
                            float positions[96][4] = { 0 };
                            const unsigned corners[6] = { 0, 1, 2, 0, 2, 3 };
                            const unsigned xy[4][2] = {
                                { 0, 0 }, { 8, 0 }, { 8, 8 }, { 0, 8 }
                            };
                            for (unsigned q = 0; q < quads; q++) {
                                unsigned exponent = batch * 16 + q,
                                         pattern = exponent % 4;
                                unsigned reverse = (exponent >> 2) & 1;
                                for (unsigned i = 0; i < stride; i++) {
                                    float *v = positions[q * stride + i];
                                    unsigned endpoint = i ^ reverse;
                                    if (line) {
                                        v[0] = (q % 4) * 8 +
                                               (pattern & 2 ? 3.5f :
                                                              2 + endpoint * 4);
                                        v[1] = (q / 4) * 8 +
                                               (pattern & 2 ? 2 + endpoint * 4 :
                                                              3.5f);
                                    } else {
                                        unsigned corner = corners[i];
                                        v[0] = (q % 4) * 8 + xy[corner][0];
                                        v[1] = (q / 4) * 8 + xy[corner][1];
                                        endpoint =
                                            xy[corner][pattern & 2 ? 1 : 0] / 8;
                                    }
                                    unsigned fraction =
                                        (endpoint ^ (pattern & 1)) ? 0x8000 :
                                                                     0x4000;
                                    uint32_t bits =
                                        ((exponent << 16) | fraction) << 7;
                                    memcpy(&v[2], &bits, 4);
                                    v[3] = 1;
                                    if (perspective) {
                                        v[2] = 1;
                                        v[3] = ldexpf(
                                            1, (int)exponent - 64 +
                                                   (endpoint ^ (pattern & 1)));
                                        if (!programmed) {
                                            // Fixed function consumes
                                            // homogeneous input.
                                            for (unsigned k = 0; k < 3; k++)
                                                v[k] *= v[3];
                                        }
                                    }
                                }
                            }
                            cpu_write(16384, count * 16);
                            memcpy(state->vram_ptr + 16384, positions,
                                   count * 16);
                            pg->regs_[NV_PGRAPH_CSV0_D] =
                                programmed ?
                                    2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE :
                                    0;
                            memset(pg->program_data, 0,
                                   sizeof(pg->program_data));
                            pg->program_data[0][1] = 1 << 21 | 27;
                            pg->program_data[0][2] = 2u << 26;
                            pg->program_data[0][3] = 1 << 11 | 15 << 12 | 1;
                            float zero = 0;
                            memcpy(
                                &pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3],
                                &zero, 4);
                            pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                                pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = 31 << 16;
                            if (perspective) {
                                send_method(NV097_SET_POLY_OFFSET_FILL_ENABLE,
                                            1);
                                send_float_method(
                                    NV097_SET_POLYGON_OFFSET_SCALE_FACTOR, .5f);
                                send_float_method(NV097_SET_POLYGON_OFFSET_BIAS,
                                                  0x1p-65f);
                                send_float_method(
                                    NV097_SET_CLIP_MIN,
                                    clipping ?
                                        ldexpf(1.25f, (int)batch * 16 - 64) :
                                        0);
                                send_float_method(
                                    NV097_SET_CLIP_MAX,
                                    clipping ?
                                        ldexpf(1.75f, (int)batch * 16 - 64) :
                                        0x1.ffffp127f);
                                uint32_t clamp = 0;
                                SET_MASK(
                                    clamp, NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN,
                                    clipping == 2 ?
                                        NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CULL :
                                        NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CLAMP);
                                send_method(NV097_SET_ZMIN_MAX_CONTROL, clamp);
                            }
                            send_method(
                                NV097_SET_CONTROL0,
                                NV097_SET_CONTROL0_Z_FORMAT |
                                    NV097_SET_CONTROL0_STENCIL_WRITE_ENABLE |
                                    (perspective ?
                                         NV097_SET_CONTROL0_Z_PERSPECTIVE_ENABLE :
                                         0));
                            send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                            send_method(NV097_SET_DEPTH_MASK, 1);
                            send_method(NV097_SET_DEPTH_FUNC, 0x207);
                            send_method(NV097_SET_STENCIL_FUNC, 0x207);
                            send_method(NV097_SET_STENCIL_FUNC_REF, ref);
                            send_method(NV097_SET_STENCIL_MASK, 0x3c);
                            send_method(NV097_SET_SPECULAR_FOG_FACTOR,
                                        0xff0000ff);
                            send_method(NV097_SET_ZSTENCIL_CLEAR_VALUE,
                                        0xfeffffa5);
                            send_method(NV097_SET_COLOR_CLEAR_VALUE,
                                        0xffff0000);
                            send_method(NV097_CLEAR_SURFACE,
                                        NV097_CLEAR_SURFACE_COLOR |
                                            NV097_CLEAR_SURFACE_Z |
                                            NV097_CLEAR_SURFACE_STENCIL);
                            begin(line ? PRIM_TYPE_LINES : PRIM_TYPE_TRIANGLES);
                            // All subsequent changes belong to the next Begin,
                            // including the floating-depth format, vertex
                            // program and stencil state.
                            send_method(
                                NV097_SET_CONTROL0,
                                perspective ?
                                    0 :
                                    NV097_SET_CONTROL0_Z_PERSPECTIVE_ENABLE);
                            if (perspective) {
                                send_method(NV097_SET_POLY_OFFSET_FILL_ENABLE,
                                            0);
                                send_float_method(
                                    NV097_SET_POLYGON_OFFSET_SCALE_FACTOR, 17);
                                send_float_method(NV097_SET_POLYGON_OFFSET_BIAS,
                                                  3);
                                send_float_method(NV097_SET_CLIP_MIN, 0);
                                send_float_method(NV097_SET_CLIP_MAX, 1);
                                uint32_t clamp = 0;
                                SET_MASK(
                                    clamp, NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN,
                                    clipping == 2 ?
                                        NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CLAMP :
                                        NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CULL);
                                send_method(NV097_SET_ZMIN_MAX_CONTROL, clamp);
                            }
                            send_method(NV097_SET_DEPTH_MASK, 0);
                            send_method(NV097_SET_DEPTH_FUNC, 0x200);
                            send_method(NV097_SET_STENCIL_FUNC, 0x200);
                            send_method(NV097_SET_STENCIL_FUNC_REF, ref ^ 255);
                            send_method(NV097_SET_STENCIL_MASK, 0);
                            send_method(NV097_SET_SPECULAR_FOG_FACTOR,
                                        0xffffff00);
                            pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                                pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = 1;
                            if (programmed)
                                pg->program_data[0][1] = 15u << 21;
                            else {
                                float translation = 4;
                                memcpy(
                                    &pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0]
                                                      [3],
                                    &translation, 4);
                            }
                            arrays(0, split);
                            qemu_mutex_lock(&pg->lock);
                            renderer.ops.flush_draw(state);
                            qemu_mutex_unlock(&pg->lock);
                            // Quiescence preserves queued DRAW_ARRAYS. Flush
                            // the first half explicitly before saving its RAM.
                            pg->draw_arrays_length = 0;
                            if (restore) {
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                            }
                            words += f24_gradient_words(batch, 8, line, scale,
                                                        swizzle, ref,
                                                        perspective, clipping);
                            int fd = -1;
                            NSData *ram = nil;
                            if (restore) {
                                fd = new_vertex_snapshot_file();
                                save_vertex_snapshot(fd);
                                ram = [NSData dataWithBytes:state->vram_ptr
                                                     length:65536];
                            }
                            arrays(split, count - split);
                            end();
                            words += f24_gradient_words(batch, quads, line,
                                                        scale, swizzle, ref,
                                                        perspective, clipping);
                            if (restore) {
                                before_ram_load();
                                memcpy(state->vram_ptr, ram.bytes, ram.length);
                                assert(load_vertex_snapshot(fd) == 0);
                                pg->draw_arrays_length = 0;
                                after_ram_load();
                                close(fd);
                                arrays(split, count - split);
                                end();
                                words += f24_gradient_words(
                                    batch, quads, line, scale, swizzle, ref,
                                    perspective, clipping);
                                restored++;
                            }
                            cases++;
                        }
                    }
    assert(cases == (perspective ? 256 : 512) &&
           restored == (perspective ? 128 : 256) &&
           words == (perspective ? 655360 : 1310720));
    if (perspective)
        printf("Metal4 F24 W profile%u: %u dispatcher cases/%u partial-Begin "
               "restores/%u packed depth-stencil words and colors PASS\n",
               clipping, cases, restored, words);
    else
        printf("Metal4 F24 gradients: %u dispatcher cases/%u partial-Begin "
               "restores/%u packed depth-stencil words and colors PASS\n",
               cases, restored, words);
    groups++;
}


static const int w_polygon_exponents[8] = { -64, 63, -63, 32, -32, 1, -1, 0 };

static unsigned w_polygon_words(unsigned triangles, unsigned front,
                                unsigned back, unsigned mask, unsigned scale,
                                BOOL swizzle, unsigned ref)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    require([surfaces.cache prepareCPUAccessAtAddress:8192
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    for (unsigned y = 0; y < 32; y++)
        for (unsigned x = 0; x < 32; x++) {
            unsigned tile = y / 8 * 4 + x / 8;
            unsigned mode = tile & 1 ? front : back;
            unsigned index =
                swizzle ? (x & 1) | (x & 2) << 1 | (x & 4) << 2 | (x & 8) << 3 |
                              (x & 16) << 4 | (y & 1) << 1 | (y & 2) << 2 |
                              (y & 4) << 3 | (y & 8) << 4 | (y & 16) << 5 :
                          y * 32 + x;
            uint32_t color, raw;
            memcpy(&color, state->vram_ptr + 1024 + index * 4, 4);
            memcpy(&raw, state->vram_ptr + 8192 + index * 4, 4);
            BOOL covered = color == 0xff0000ff, active = tile < triangles;
            assert(covered || color == 0xffff0000);
            unsigned lx = x % 8, ly = y % 8;
            double px = lx + .5 / scale, py = ly + .5 / scale;
            double base = ldexp(1, w_polygon_exponents[tile / 2]);
            double candidates[3];
            unsigned candidate_count = 1;
            if (mode == NV2AMetalPolygonFill) {
                assert(covered ==
                       (active && px >= 1 && py >= 1 && px + py < 8));
                candidates[0] = base / (1 - (px - 1) / 12);
            } else if (mode == NV2AMetalPolygonPoint) {
                BOOL point = (lx < 2 && ly < 2) || (lx >= 6 && ly < 2) ||
                             (lx < 2 && ly >= 6);
                assert(covered == (active && point));
                candidates[0] = lx >= 6 ? 2 * base : base;
            } else {
                assert(mode == NV2AMetalPolygonLine);
                // Endpoint ownership is not a hardware assertion here. At a
                // shared corner, either incident edge can provide the sample.
                double distance[3] = { fabs(py - 1),
                                       fabs(px + py - 8) / sqrt(2),
                                       fabs(px - 1) };
                double w[3] = { base / (1 - (px - 1) / 12),
                                base / (.5 + (7 - px + py - 1) / 24), base };
                candidate_count = 0;
                for (unsigned edge = 0; edge < 3; edge++)
                    if (distance[edge] <= .75)
                        candidates[candidate_count++] = w[edge];
                if (!active || !candidate_count || (lx == 3 && ly == 3))
                    assert(!covered);
                if (active && lx == 3 && ly == 0) {
                    unsigned other_index = swizzle ? index + 2 : index + 32;
                    uint32_t other;
                    memcpy(&other, state->vram_ptr + 1024 + other_index * 4, 4);
                    assert(covered || other == 0xff0000ff);
                }
                if (active && lx == 0 && ly == 3) {
                    uint32_t other;
                    memcpy(&other, state->vram_ptr + 1024 + (index + 1) * 4, 4);
                    assert(covered || other == 0xff0000ff);
                }
            }
            BOOL matched = !covered && raw == 0xfeffffa5;
            for (unsigned i = 0; covered && i < candidate_count; i++) {
                double w = candidates[i], z = w;
                if (mask & (1u << mode))
                    z += 0x1p-65 + .5 * w * w / (12 * base);
                float depth = z;
                uint32_t bits;
                memcpy(&bits, &depth, 4);
                uint32_t expected =
                    (bits >> 7) << 8 | (0xa5 & ~0x3cu) | (ref & 0x3c);
                matched |= raw == expected;
            }
            if (!matched) {
                fprintf(stderr,
                        "W polygon front%u back%u mask%u scale%u "
                        "swizzle%u triangles%u tile%u pixel%u,%u color%08x "
                        "raw%08x candidates%u\n",
                        front, back, mask, scale, swizzle, triangles, tile, lx,
                        ly, color, raw, candidate_count);
                abort();
            }
        }
    return 1024;
}

static const int w_quad_exponents[8] = { -64, 62, -63, 32, -32, 1, -1, 0 };
static unsigned w_quad_corner(unsigned tile, unsigned vertex, BOOL strip)
{
    const unsigned strip_order[4] = { 0, 1, 3, 2 };
    unsigned corner = strip ? strip_order[vertex] : vertex;
    return tile & 1 && corner ? 4 - corner : corner;
}
static unsigned w_quad_words(unsigned quads, unsigned front, unsigned back,
                             unsigned mask, unsigned scale, BOOL swizzle,
                             unsigned ref, BOOL strip);

static unsigned w_strip_words(unsigned chains, unsigned front, unsigned back,
                              unsigned mask, unsigned scale, BOOL swizzle,
                              unsigned ref, BOOL increment, unsigned quads,
                              unsigned input);

static unsigned w_array_flushes, w_array_prefix_length;
static unsigned w_array_prefix_starts[15];
static unsigned w_array_rotation;
static bool w_prefix_rotations_active;
static unsigned w_prefix_scope[2][16][4][2][2];
static unsigned w_prefix_masks[2][16];
static unsigned w_array_chain(unsigned first, unsigned index, unsigned length)
{
    assert(index < length);
    // Nonmonotonic addresses exercise bounds beyond the first/last range.
    unsigned slot = length == 2 ? index :
                    index & 1   ? index / 2 :
                                  length - 1 - index / 2;
    return first + (slot + w_array_rotation) % length;
}
static void w_array_flush(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    uint32_t minimum = UINT32_MAX, maximum = 0;
    assert(pg->draw_arrays_length == w_array_prefix_length);
    for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
        assert(pg->draw_arrays_start[i] == (int32_t)w_array_prefix_starts[i] &&
               pg->draw_arrays_count[i] == 6);
        assert(pg->draw_arrays_start[i] >= 0 && pg->draw_arrays_count[i] > 0);
        minimum = MIN(minimum, (uint32_t)pg->draw_arrays_start[i]);
        maximum = MAX(maximum, (uint32_t)(pg->draw_arrays_start[i] +
                                          pg->draw_arrays_count[i]));
    }
    // OGL also consumes these cached bounds when binding the prefix arrays.
    assert(pg->draw_arrays_min_start == minimum &&
           pg->draw_arrays_max_count == maximum);
    w_array_flushes++;
    pgraph_metal4_flush_draw(d);
}
// Input1: arrays;2: mixed;3/4/5: closed Begins;6/7: sparse/permuted arrays.
static void w_polygon_mutate(unsigned front, unsigned back, unsigned mask,
                             const unsigned modes[3], const unsigned enables[3])
{
    send_method(NV097_SET_FRONT_POLYGON_MODE, modes[(front + 1) % 3]);
    send_method(NV097_SET_BACK_POLYGON_MODE, modes[(back + 1) % 3]);
    send_method(NV097_SET_FRONT_FACE, NV097_SET_FRONT_FACE_V_CW);
    for (unsigned i = 0; i < 3; i++)
        send_method(enables[i], !((mask >> i) & 1));
    send_float_method(NV097_SET_POLYGON_OFFSET_SCALE_FACTOR, 17);
    send_float_method(NV097_SET_POLYGON_OFFSET_BIAS, 3);
    send_method(NV097_SET_POINT_SIZE, 8);
    send_method(NV097_SET_CONTROL0, 0);
    send_method(NV097_SET_DEPTH_MASK, 0);
    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
}

static unsigned w_strip_index(unsigned chain, unsigned vertex, unsigned input,
                              unsigned stride)
{
    const unsigned order[8] = { 6, 0, 14, 4, 10, 2, 12, 8 };
    if (input == 8)
        return 2 * chain * stride + vertex % 4;
    if (input == 9)
        return 2 * chain * stride + (vertex >= 6 ? vertex - 4 : vertex);
    return input == 7 || input == 10 ?
               2 * chain * stride + order[vertex] :
               (input == 6 ? 2 : 1) * (chain * stride + vertex);
}
static void w_strip_input(unsigned chain, unsigned first, unsigned count,
                          unsigned input, unsigned stride)
{
    unsigned end = first + count, base = chain * stride;
    assert(end <= stride && (stride == 6 || stride == 8) && input >= 1 &&
           input <= 10);
    if (input == 10) {
        for (unsigned i = first; i < end; i++) {
            unsigned index = w_strip_index(chain, i, input, stride);
            if (i == 0 || i == 3 || i == 7)
                arrays(index, 1);
            else if ((i == 1 || i == 4) && i + 1 < end) {
                send_method(NV097_ARRAY_ELEMENT16,
                            index | w_strip_index(chain, i + 1, input, stride)
                                        << 16);
                i++;
            } else
                send_method(NV097_ARRAY_ELEMENT32, index);
        }
        return;
    }
    if (input >= 8) {
        while (first < end) {
            unsigned start = w_strip_index(chain, first, input, stride),
                     count = 1;
            while (first + count < end &&
                   w_strip_index(chain, first + count, input, stride) ==
                       start + count)
                count++;
            arrays(start, count);
            first += count;
        }
        return;
    }
    if (input >= 6) {
        for (unsigned i = first; i < end; i++)
            arrays(w_strip_index(chain, i, input, stride), 1);
        return;
    }
    if (input == 1) {
        arrays(base + first, count);
        return;
    }
    if (!first) {
        assert(count >= 2);
        arrays(base, 2);
        first = 2;
    }
    for (unsigned k = first; k < end; k++) {
        if (k == 3 && k + 1 < end) {
            send_method(NV097_ARRAY_ELEMENT16, base + k | (base + k + 1) << 16);
            k++;
        } else if (k == 5 && input == 2)
            arrays(base + k, 1);
        else
            send_method(NV097_ARRAY_ELEMENT32, base + k);
    }
}
static void w_strip_pending(unsigned chain, unsigned cut, unsigned input,
                            BOOL later, unsigned stride)
{
    PGRAPHState *pg = &state->pgraph;
    assert(!pg->inline_buffer_length && !pg->inline_array_length);
    if (input >= 3 && input <= 5) {
        unsigned length = input == 3 ? 2 : input == 4 ? 4 : 16;
        unsigned minimum = UINT32_MAX, maximum = 0;
        assert(pg->draw_arrays_length == length - !later);
        for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
            unsigned start = w_array_chain(chain, i, length) * 6;
            unsigned count = i + 1 == length ? cut : 6;
            assert(pg->draw_arrays_start[i] == (int32_t)start &&
                   pg->draw_arrays_count[i] == (int32_t)count);
            minimum = MIN(minimum, start);
            maximum = MAX(maximum, start + count);
        }
        assert(pg->draw_arrays_min_start == minimum &&
               pg->draw_arrays_max_count == maximum);
        assert(pg->draw_arrays_prevent_connect == !later &&
               !pg->inline_elements_length);
    } else if (input == 1 || (cut == 2 && input < 6) ||
               ((input == 7 || input == 10) && cut == 1) ||
               (input == 8 && cut <= 4) || (input == 9 && cut <= 6)) {
        unsigned first = w_strip_index(chain, 0, input, stride);
        assert(pg->draw_arrays_length == 1 && !pg->inline_elements_length);
        assert(pg->draw_arrays_start[0] == (int32_t)first &&
               pg->draw_arrays_count[0] == (int32_t)cut);
        assert(pg->draw_arrays_min_start == first &&
               pg->draw_arrays_max_count == first + cut &&
               !pg->draw_arrays_prevent_connect);
    } else {
        assert(!pg->draw_arrays_length && pg->inline_elements_length == cut);
        for (unsigned i = 0; i < cut; i++)
            assert(pg->inline_elements[i] ==
                   w_strip_index(chain, i, input, stride));
        assert(pg->draw_arrays_min_start == UINT32_MAX &&
               !pg->draw_arrays_max_count && !pg->draw_arrays_prevent_connect);
    }
}

static unsigned w_mixed_attribute_kind(unsigned attribute, unsigned front,
                                       unsigned back)
{
    return (attribute - 1 + front + 3 * back) % 6;
}
static unsigned w_mixed_attribute_count(unsigned attribute, unsigned kind,
                                        unsigned mask)
{
    return kind == 3 ? 4 : kind == 5 ? 1 : (attribute + mask) % 4 + 1;
}
static int w_mixed_attribute_code(unsigned attribute, unsigned index,
                                  unsigned component, unsigned mask,
                                  unsigned kind)
{
    if (kind == 0)
        return attribute * 512 + index * 4 + component + mask * 3;
    if (kind == 1 || kind == 2) {
        if (component == 3)
            return (index / 16 + attribute + mask) & 1 ? -32768 : 32767;
        return (int)((index * 257 + attribute * 31 + component * 103 +
                      mask * 19) &
                     65535) -
               32768;
    }
    if (kind == 3 || kind == 4)
        return (index + attribute * 17 + component * 73 + mask * 11) & 255;
    unsigned limit = component == 2 ? 512 : 1024;
    unsigned selector = (index + attribute + mask) & 31;
    if (selector == component)
        return -(int)limit;
    if (selector == component + 3)
        return (int)limit - 1;
    return (int)((index * 29 + attribute * 11 + component * 47 + mask * 17) &
                 (2 * limit - 1)) -
           (int)limit;
}
static float w_mixed_nshort(int code)
{
    if (code == -32768 || code == 32767)
        return code < 0 ? -1.0f : 1.0f;
    /* Independent floating-point form of Kelvin's fixed-point scale.
     * Every code agrees with the recorded original IDX family model. */
    double exact = (2 * code + 1) * 0x10001p-32;
    float rounded = (float)exact;
    if (fabs((double)rounded) > fabs(exact))
        rounded = nextafterf(rounded, 0);
    return rounded;
}

static void w_mixed_current_expected(unsigned attribute, unsigned index,
                                     unsigned kind, unsigned count,
                                     unsigned mask, float expected[4])
{
    // Metal current values retain Kelvin IDX bits, unswapped D3D and clamped
    // CMP.
    expected[0] = expected[1] = expected[2] = 0;
    expected[3] = 1;
    for (unsigned k = 0; k < (kind == 5 ? 3 : count); k++) {
        int code = w_mixed_attribute_code(attribute, index, k, mask, kind);
        if (kind == 1) {
            expected[k] = w_mixed_nshort(code);
        } else if (kind == 3 || kind == 4) {
            uint32_t bits = idx_ubyte[code];
            memcpy(&expected[k], &bits, sizeof(bits));
        } else {
            expected[k] =
                kind == 0 ?
                    code + .25f :
                kind == 2 ?
                    (float)code :
                    fmaxf(-1, (float)code / (k == 2 ? 511.0f : 1023.0f));
        }
    }
}

static void w_mixed_attributes(unsigned front, unsigned back, unsigned mask)
{
    PGRAPHState *pg = &state->pgraph;
    dma[2].limit = 49151;
    cpu_write(32768, 32768);
    unsigned cursor = 32768;
    const unsigned formats[6] = {
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP
    };
    const unsigned sizes[6] = { 4, 2, 2, 1, 1, 4 };
    for (unsigned attribute = 1; attribute < 16; attribute++) {
        unsigned kind = w_mixed_attribute_kind(attribute, front, back);
        unsigned count = w_mixed_attribute_count(attribute, kind, mask);
        unsigned stride = sizes[kind] * count;
        assert(cursor + 256 * stride <= 65536);
        g_free(pg->vertex_attributes[attribute].inline_buffer);
        pg->vertex_attributes[attribute] =
            (VertexAttribute){ .offset = cursor - 16384,
                               .format = formats[kind],
                               .size = sizes[kind],
                               .count = count,
                               .stride = stride };
        for (unsigned index = 0; index < 256; index++) {
            uint8_t *destination = state->vram_ptr + cursor + index * stride;
            if (kind == 5) {
                uint32_t packed =
                    (w_mixed_attribute_code(attribute, index, 0, mask, kind) &
                     2047u) |
                    (w_mixed_attribute_code(attribute, index, 1, mask, kind) &
                     2047u)
                        << 11 |
                    (w_mixed_attribute_code(attribute, index, 2, mask, kind) &
                     1023u)
                        << 22;
                memcpy(destination, &packed, 4);
            } else
                for (unsigned k = 0; k < count; k++) {
                    int code =
                        w_mixed_attribute_code(attribute, index, k, mask, kind);
                    if (kind == 0) {
                        float value = code + .25f;
                        memcpy(destination + 4 * k, &value, 4);
                    } else if (kind == 1 || kind == 2) {
                        int16_t value = code;
                        memcpy(destination + 2 * k, &value, 2);
                    } else
                        destination[k] = code;
                }
        }
        cursor += 256 * stride;
    }
}
static void w_mixed_current(unsigned chain, unsigned front, unsigned back,
                            unsigned mask)
{
    PGRAPHState *pg = &state->pgraph;
    // This stream ends at relative index8, independently of its index packer.
    unsigned index = 16 * chain + 8;
    for (unsigned attribute = 1; attribute < 16; attribute++) {
        unsigned kind = w_mixed_attribute_kind(attribute, front, back);
        unsigned count = w_mixed_attribute_count(attribute, kind, mask);
        float expected[4];
        w_mixed_current_expected(attribute, index, kind, count, mask, expected);
        if (memcmp(pg->vertex_attributes[attribute].inline_value, expected,
                   16)) {
            fprintf(stderr,
                    "Mixed current attr%u kind%u count%u tile%u mask%u "
                    "got%a,%a,%a,%a expected%a,%a,%a,%a\n",
                    attribute, kind, count, chain, mask,
                    pg->vertex_attributes[attribute].inline_value[0],
                    pg->vertex_attributes[attribute].inline_value[1],
                    pg->vertex_attributes[attribute].inline_value[2],
                    pg->vertex_attributes[attribute].inline_value[3],
                    expected[0], expected[1], expected[2], expected[3]);
            abort();
        }
    }
}

static void w_polygon_begin_snapshot(unsigned primitive, unsigned chain_quads,
                                     unsigned input)
{
    BOOL connected = chain_quads > 1;
    BOOL quad = primitive != PRIM_TYPE_TRIANGLES,
         strip = primitive == PRIM_TYPE_QUAD_STRIP;
    assert((!chain_quads || chain_quads == 2 || chain_quads == 3) &&
           (!connected || strip) && (!input || connected) && input <= 10 &&
           (input < 6 || chain_quads == 3) &&
           (chain_quads != 3 || input <= 2 || input >= 6));
    BOOL prefix = input >= 3 && input <= 5;
    BOOL increment = prefix || chain_quads == 3;
    const VMStateDescription *parent =
        input ? &array_snapshot_parent : &vertex_snapshot_parent;
    unsigned pairs = input == 5 ? 16 : input == 4 ? 4 : input == 3 ? 2 : 1;
    PGRAPHRenderer monitored = renderer;
    monitored.ops.flush_draw = w_array_flush;
    if (prefix)
        w_array_flushes = 0;
    unsigned stride = connected ? 2 * (chain_quads + 1) : quad ? 4 : 3;
    unsigned cut_min = input >= 7 ? 1 : 2;
    unsigned cuts[7] = { 0 }, restored_cuts[7] = { 0 };
    unsigned cases = 0, restored = 0, words = 0;
    const unsigned modes[3] = { NV097_SET_FRONT_POLYGON_MODE_V_FILL,
                                NV097_SET_FRONT_POLYGON_MODE_V_POINT,
                                NV097_SET_FRONT_POLYGON_MODE_V_LINE };
    const unsigned enables[3] = { NV097_SET_POLY_OFFSET_FILL_ENABLE,
                                  NV097_SET_POLY_OFFSET_POINT_ENABLE,
                                  NV097_SET_POLY_OFFSET_LINE_ENABLE };
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned front = 0; front < 3; front++)
            for (unsigned back = 0; back < 3; back++)
                for (unsigned mask = 0; mask < 8; mask++)
                    for (unsigned swizzle = 0; swizzle < 2; swizzle++)
                        for (unsigned scale = 1; scale <= 2; scale++)
                            for (unsigned restore = 0; restore < 2; restore++) {
                                fixture();
                                PGRAPHState *pg = &state->pgraph;
                                if (prefix)
                                    pg->renderer = &monitored;
                                dma[0].limit = dma[1].limit = dma[2].limit =
                                    4095;
                                dma[1].address = 8192;
                                pg->surface_scale_factor = scale;
                                g_config.display.quality.surface_scale = scale;
                                uint32_t format = 0;
                                SET_MASK(
                                    format, NV097_SET_SURFACE_FORMAT_COLOR,
                                    NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8);
                                SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA,
                                         NV097_SET_SURFACE_FORMAT_ZETA_Z24S8);
                                SET_MASK(
                                    format, NV097_SET_SURFACE_FORMAT_TYPE,
                                    swizzle ?
                                        NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE :
                                        NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                                SET_MASK(format, NV097_SET_SURFACE_FORMAT_WIDTH,
                                         5);
                                SET_MASK(format,
                                         NV097_SET_SURFACE_FORMAT_HEIGHT, 5);
                                send_method(NV097_SET_SURFACE_FORMAT, format);
                                send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL,
                                            32 << 16);
                                send_method(NV097_SET_SURFACE_CLIP_VERTICAL,
                                            32 << 16);
                                send_method(NV097_SET_SURFACE_PITCH,
                                            128 | 128 << 16);
                                send_float_method(NV097_SET_CLIP_MIN, 0);
                                send_float_method(NV097_SET_CLIP_MAX,
                                                  0x1.ffffp127f);
                                send_method(
                                    NV097_SET_CONTROL0,
                                    NV097_SET_CONTROL0_Z_FORMAT |
                                        NV097_SET_CONTROL0_STENCIL_WRITE_ENABLE |
                                        NV097_SET_CONTROL0_Z_PERSPECTIVE_ENABLE);
                                send_method(NV097_SET_FRONT_FACE,
                                            NV097_SET_FRONT_FACE_V_CCW);
                                send_method(NV097_SET_FRONT_POLYGON_MODE,
                                            modes[front]);
                                send_method(NV097_SET_BACK_POLYGON_MODE,
                                            modes[back]);
                                for (unsigned i = 0; i < 3; i++)
                                    send_method(enables[i], (mask >> i) & 1);
                                send_float_method(
                                    NV097_SET_POLYGON_OFFSET_SCALE_FACTOR, .5f);
                                send_float_method(NV097_SET_POLYGON_OFFSET_BIAS,
                                                  0x1p-65f);
                                send_method(NV097_SET_POINT_SIZE, 16);
                                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                            PS_REGISTER_C0);
                                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                            (PS_REGISTER_C0 | PS_CHANNEL_ALPHA)
                                                << 8);
                                send_method(NV097_SET_SPECULAR_FOG_FACTOR,
                                            0xff0000ff);
                                send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                                send_method(NV097_SET_DEPTH_MASK, 1);
                                send_method(NV097_SET_DEPTH_FUNC, 0x207);
                                send_method(NV097_SET_STENCIL_TEST_ENABLE, 1);
                                send_method(NV097_SET_STENCIL_FUNC, 0x207);
                                send_method(NV097_SET_STENCIL_FUNC_MASK, 255);
                                unsigned ref =
                                    (front * 61 + back * 17 + mask * 3) & 255;
                                send_method(NV097_SET_STENCIL_FUNC_REF, ref);
                                send_method(NV097_SET_STENCIL_MASK,
                                            increment ? 255 : 0x3c);
                                send_method(NV097_SET_STENCIL_OP_FAIL, 0x1e00);
                                send_method(NV097_SET_STENCIL_OP_ZFAIL, 0x1e00);
                                send_method(NV097_SET_STENCIL_OP_ZPASS,
                                            increment ? 0x1e02 : 0x1e01);
                                send_method(NV097_SET_CLEAR_RECT_HORIZONTAL,
                                            31 << 16);
                                send_method(NV097_SET_CLEAR_RECT_VERTICAL,
                                            31 << 16);
                                send_method(NV097_SET_ZSTENCIL_CLEAR_VALUE,
                                            increment ? 0xfeffff00 :
                                                        0xfeffffa5);
                                send_method(NV097_SET_COLOR_CLEAR_VALUE,
                                            0xffff0000);
                                send_method(NV097_CLEAR_SURFACE,
                                            NV097_CLEAR_SURFACE_COLOR |
                                                NV097_CLEAR_SURFACE_Z |
                                                NV097_CLEAR_SURFACE_STENCIL);
                                pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                                    pg->regs_[NV_PGRAPH_WINDOWCLIPY0] =
                                        31 << 16;
                                float positions[256][4] = { 0 };
                                const unsigned xy[4][2] = {
                                    { 1, 1 }, { 7, 1 }, { 1, 7 }, { 7, 7 }
                                };
                                for (unsigned q = 0; q < 16; q++)
                                    for (unsigned i = 0; i < stride; i++) {
                                        if (connected) {
                                            float *v = positions[w_strip_index(
                                                q, i, input, stride)];
                                            const int shifts[8] = {
                                                0, 1, 0, 2, 1, 0, 2, 1
                                            };
                                            unsigned source =
                                                input == 8           ? i % 4 :
                                                input == 9 && i >= 6 ? i - 4 :
                                                                       i;
                                            v[0] = q % 4 * 8 +
                                                   ((source ^ q) & 1 ? 7 : 1);
                                            v[1] = q / 4 * 8 + 1 +
                                                   source / 2 *
                                                       (input == 8 ?
                                                            6 :
                                                            6 / chain_quads) +
                                                   (chain_quads == 3 ? 0x1p-4f :
                                                                       0);
                                            v[2] = 1;
                                            v[3] = ldexpf(
                                                1, w_quad_exponents[q / 2] +
                                                       shifts[source]);
                                            if (!programmed)
                                                for (unsigned k = 0; k < 3; k++)
                                                    v[k] *= v[3];
                                            continue;
                                        }
                                        unsigned corner =
                                            quad ? w_quad_corner(q, i, strip) :
                                            q & 1 && i ? 3 - i :
                                                         i;
                                        // The quad reference uses clockwise
                                        // square corners.
                                        unsigned coordinate =
                                            quad && corner >= 2 ? 5 - corner :
                                                                  corner;
                                        float *v = positions[q * stride + i];
                                        v[0] = q % 4 * 8 + xy[coordinate][0];
                                        v[1] = q / 4 * 8 + xy[coordinate][1];
                                        v[2] = 1;
                                        v[3] = ldexpf(
                                            1,
                                            (quad ?
                                                 w_quad_exponents[q / 2] :
                                                 w_polygon_exponents[q / 2]) +
                                                (corner == 1         ? 1 :
                                                 quad && corner == 2 ? 2 :
                                                                       0));
                                        if (!programmed)
                                            for (unsigned k = 0; k < 3; k++)
                                                v[k] *= v[3];
                                    }
                                cpu_write(16384, sizeof(positions));
                                memcpy(state->vram_ptr + 16384, positions,
                                       sizeof(positions));
                                if (input == 10)
                                    w_mixed_attributes(front, back, mask);
                                if (programmed) {
                                    pg->regs_[NV_PGRAPH_CSV0_D] =
                                        2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                                    pg->program_data[0][1] = 1 << 21 | 27;
                                    pg->program_data[0][2] = 2u << 26;
                                    pg->program_data[0][3] =
                                        1 << 11 | 15 << 12 | 1;
                                }
                                for (unsigned q = 0; q < (strip ? 16 : 1);
                                     q += pairs) {
                                    unsigned cut =
                                        connected ?
                                            cut_min + (q / 2 + mask) %
                                                          (stride - cut_min) :
                                            2;
                                    if (strip) {
                                        send_method(NV097_SET_FRONT_FACE,
                                                    NV097_SET_FRONT_FACE_V_CCW);
                                        send_method(
                                            NV097_SET_FRONT_POLYGON_MODE,
                                            modes[front]);
                                        send_method(NV097_SET_BACK_POLYGON_MODE,
                                                    modes[back]);
                                        for (unsigned k = 0; k < 3; k++)
                                            send_method(enables[k],
                                                        (mask >> k) & 1);
                                        send_float_method(
                                            NV097_SET_POLYGON_OFFSET_SCALE_FACTOR,
                                            .5f);
                                        send_float_method(
                                            NV097_SET_POLYGON_OFFSET_BIAS,
                                            0x1p-65f);
                                        send_method(NV097_SET_POINT_SIZE, 16);
                                        send_method(
                                            NV097_SET_CONTROL0,
                                            NV097_SET_CONTROL0_Z_FORMAT |
                                                NV097_SET_CONTROL0_STENCIL_WRITE_ENABLE |
                                                NV097_SET_CONTROL0_Z_PERSPECTIVE_ENABLE);
                                        send_method(NV097_SET_DEPTH_MASK, 1);
                                        send_method(
                                            NV097_SET_SPECULAR_FOG_FACTOR,
                                            0xff0000ff);
                                    }
                                    begin(primitive);
                                    if (!prefix)
                                        w_polygon_mutate(front, back, mask,
                                                         modes, enables);
                                    unsigned current_chain =
                                        w_array_chain(q, pairs - 1, pairs);
                                    BOOL later = prefix && (mask & 4);
                                    if (w_prefix_rotations_active) {
                                        assert(prefix &&
                                               (input == 4 || input == 5) &&
                                               current_chain < 16 && cut >= 2 &&
                                               cut <= 5);
                                        unsigned kind = input == 5;
                                        w_prefix_scope[kind][current_chain]
                                                      [cut - 2][later]
                                                      [restore]++;
                                        w_prefix_masks[kind][current_chain] |=
                                            1u << mask;
                                    }
                                    if (prefix) {
                                        w_array_prefix_length = pairs - 1;
                                        for (unsigned i = 0; i + 1 < pairs;
                                             i++) {
                                            unsigned chain =
                                                w_array_chain(q, i, pairs);
                                            unsigned next =
                                                w_array_chain(q, i + 1, pairs);
                                            w_array_prefix_starts[i] =
                                                chain * 6;
                                            uint32_t params[] = {
                                                chain * 6 | 5u << 24,
                                                NV097_SET_BEGIN_END,
                                                0,
                                                NV097_SET_BEGIN_END,
                                                PRIM_TYPE_QUAD_STRIP,
                                                NV097_DRAW_ARRAYS,
                                                next * 6 |
                                                    (i + 2 == pairs ? cut - 1 :
                                                                      5u)
                                                        << 24,
                                                0
                                            };
                                            assert(method(NV097_DRAW_ARRAYS,
                                                          params[0], params, 1,
                                                          7, false) == 5);
                                        }
                                        if (later)
                                            arrays(current_chain * 6, cut);
                                    } else if (input)
                                        w_strip_input(q, 0, cut, input, stride);
                                    else if (strip) {
                                        for (unsigned k = 0; k < cut; k++) {
                                            uint32_t data[4];
                                            memcpy(data,
                                                   positions[q * stride + k],
                                                   16);
                                            assert(
                                                method(
                                                    NV097_SET_VERTEX_DATA4F_M,
                                                    data[0], data, 4, 0,
                                                    true) == 4);
                                        }
                                    } else
                                        arrays(0, 8 * stride);
                                    if (prefix) {
                                        // All logical Begins see identical
                                        // state; mutate only after the
                                        // lookahead has consumed their
                                        // boundary.
                                        w_polygon_mutate(front, back, mask,
                                                         modes, enables);
                                    }
                                    if (!strip) {
                                        qemu_mutex_lock(&pg->lock);
                                        renderer.ops.flush_draw(state);
                                        qemu_mutex_unlock(&pg->lock);
                                        pg->draw_arrays_length = 0;
                                    } else if (!input) {
                                        // Save quiescence preserves all
                                        // pending vertices without a draw.
                                        assert(pg->inline_buffer_length == cut);
                                    }
                                    if (restore) {
                                        renderer.ops.pre_savevm_trigger(state);
                                        process_pending();
                                        renderer.ops.pre_savevm_wait(state);
                                    }
                                    if (input) {
                                        w_strip_pending(q, cut, input, later,
                                                        stride);
                                        cuts[cut - cut_min]++;
                                    } else if (connected) {
                                        assert(pg->inline_buffer_length ==
                                                   cut &&
                                               pg->vertex_attributes[0]
                                                   .inline_buffer_populated);
                                        assert(!memcmp(pg->vertex_attributes[0]
                                                           .inline_buffer,
                                                       positions[q * stride],
                                                       cut * 16));
                                        cuts[cut - cut_min]++;
                                    }
                                    words +=
                                        connected ?
                                            w_strip_words(q, front, back, mask,
                                                          scale, swizzle, ref,
                                                          increment,
                                                          chain_quads, input) :
                                        quad ?
                                            w_quad_words(strip ? q : 8, front,
                                                         back, mask, scale,
                                                         swizzle, ref, strip) :
                                            w_polygon_words(8, front, back,
                                                            mask, scale,
                                                            swizzle, ref);
                                    int fd = -1;
                                    NSData *ram = nil;
                                    if (restore) {
                                        fd = new_vertex_snapshot_file();
                                        save_snapshot_parent(fd, parent);
                                        ram = [NSData
                                            dataWithBytes:state->vram_ptr
                                                   length:65536];
                                    }
                                    if (input) {
                                        if (prefix && !later)
                                            arrays(current_chain * 6, cut);
                                        w_strip_input(current_chain, cut,
                                                      stride - cut, input,
                                                      stride);
                                    } else if (strip) {
                                        for (unsigned k = cut; k < stride;
                                             k++) {
                                            uint32_t data[4];
                                            memcpy(data,
                                                   positions[q * stride + k],
                                                   16);
                                            assert(
                                                method(
                                                    NV097_SET_VERTEX_DATA4F_M,
                                                    data[0], data, 4, 0,
                                                    true) == 4);
                                        }
                                    } else
                                        arrays(8 * stride, 8 * stride);
                                    end();
                                    if (input >= 7)
                                        assert(!memcmp(
                                            pg->vertex_attributes[0]
                                                .inline_value,
                                            positions[w_strip_index(
                                                current_chain, stride - 1,
                                                input, stride)],
                                            16));
                                    if (input == 10)
                                        w_mixed_current(current_chain, front,
                                                        back, mask);
                                    words +=
                                        connected ?
                                            w_strip_words(
                                                q + pairs, front, back, mask,
                                                scale, swizzle, ref, increment,
                                                chain_quads, input) :
                                        quad ? w_quad_words(strip ? q + 1 : 16,
                                                            front, back, mask,
                                                            scale, swizzle, ref,
                                                            strip) :
                                               w_polygon_words(16, front, back,
                                                               mask, scale,
                                                               swizzle, ref);
                                    if (restore) {
                                        before_ram_load();
                                        memcpy(state->vram_ptr, ram.bytes,
                                               ram.length);
                                        assert(load_snapshot_parent(
                                                   fd, parent) == 0);
                                        if (!input)
                                            pg->draw_arrays_length = 0;
                                        after_ram_load();
                                        close(fd);
                                        if (input) {
                                            w_strip_pending(q, cut, input,
                                                            later, stride);
                                            restored_cuts[cut - cut_min]++;
                                        } else if (connected) {
                                            assert(
                                                pg->inline_buffer_length ==
                                                    cut &&
                                                pg->vertex_attributes[0]
                                                    .inline_buffer_populated);
                                            assert(
                                                !memcmp(pg->vertex_attributes[0]
                                                            .inline_buffer,
                                                        positions[q * stride],
                                                        cut * 16));
                                            restored_cuts[cut - cut_min]++;
                                        }
                                        if (input) {
                                            if (prefix && !later)
                                                arrays(current_chain * 6, cut);
                                            w_strip_input(current_chain, cut,
                                                          stride - cut, input,
                                                          stride);
                                        } else if (strip) {
                                            for (unsigned k = cut; k < stride;
                                                 k++) {
                                                uint32_t data[4];
                                                memcpy(
                                                    data,
                                                    positions[q * stride + k],
                                                    16);
                                                assert(
                                                    method(
                                                        NV097_SET_VERTEX_DATA4F_M,
                                                        data[0], data, 4, 0,
                                                        true) == 4);
                                            }
                                        } else
                                            arrays(8 * stride, 8 * stride);
                                        end();
                                        if (input >= 7)
                                            assert(!memcmp(
                                                pg->vertex_attributes[0]
                                                    .inline_value,
                                                positions[w_strip_index(
                                                    current_chain, stride - 1,
                                                    input, stride)],
                                                16));
                                        if (input == 10)
                                            w_mixed_current(current_chain,
                                                            front, back, mask);
                                        words +=
                                            connected ?
                                                w_strip_words(
                                                    q + pairs, front, back,
                                                    mask, scale, swizzle, ref,
                                                    increment, chain_quads,
                                                    input) :
                                            quad ?
                                                w_quad_words(strip ? q + 1 : 16,
                                                             front, back, mask,
                                                             scale, swizzle,
                                                             ref, strip) :
                                                w_polygon_words(16, front, back,
                                                                mask, scale,
                                                                swizzle, ref);
                                        restored++;
                                    }
                                    cases++;
                                }
                            }
    assert(cases == (strip ? 18432 / pairs : 1152) &&
           restored == (strip ? 9216 / pairs : 576) &&
           words == (strip ? 47185920 / pairs : 2949120));
    if (connected) {
        for (unsigned i = 0; i < stride - cut_min; i++) {
            const unsigned long_cuts[6] = {
                3168, 3456, 3168, 2880, 2880, 2880
            };
            unsigned count = input >= 7       ? (i ? 2592 : 2880) :
                             chain_quads == 3 ? long_cuts[i] :
                                                4608 / pairs;
            assert(cuts[i] == count && restored_cuts[i] == count / 2);
        }
        if (input == 10)
            printf(
                "Metal4 W mixed elements attributes: %u cases/%u partial-Begin "
                "restores/%u exact colors and packed depth-stencil words; "
                "cuts1..7;16 active attributes/six formats PASS\n",
                cases, restored, words);
        else if (input >= 8)
            printf("Metal4 W %s arrays: %u cases/%u partial-Begin restores/"
                   "%u exact colors and packed depth-stencil words; cuts1..7; "
                   "per-quad facing and last current attributes PASS\n",
                   input == 8 ? "repeated" : "overlapping", cases, restored,
                   words);
        else if (input == 7)
            printf(
                "Metal4 W permuted arrays: %u cases/%u partial-Begin restores/"
                "%u exact colors and packed depth-stencil words; cuts1..7; "
                "last current attributes PASS\n",
                cases, restored, words);
        else if (chain_quads == 3)
            printf("Metal4 W three-quad input%u: %u cases/%u partial-Begin "
                   "restores/%u exact colors and packed depth-stencil words; "
                   "cuts2..7 PASS\n",
                   input, cases, restored, words);
        else if (input)
            printf(
                "Metal4 W array strip%u: %u cases/%u partial-Begin restores/%u "
                "exact colors and packed depth-stencil words PASS\n",
                input, cases, restored, words);
        else
            printf("Metal4 W connected strip: %u cases/%u partial-Begin "
                   "restores/%u exact colors and packed depth-stencil words; "
                   "cuts2/3/4/5 each4608/2304 PASS\n",
                   cases, restored, words);
    } else if (quad)
        printf("Metal4 W quad%u offsets: %u dispatcher cases/%u partial-Begin "
               "restores/%u packed depth-stencil words and colors PASS\n",
               strip, cases, restored, words);
    else
        printf("Metal4 W polygon offsets: %u dispatcher cases/%u partial-Begin "
               "restores/%u packed depth-stencil words and colors PASS\n",
               cases, restored, words);
    if (prefix)
        assert(w_array_flushes == 27648 / pairs);
    state->pgraph.renderer = &renderer;
    groups++;
}


static void w_prefix_rotations(void)
{
    unsigned first_group = groups;
    assert(!w_prefix_rotations_active && !w_array_rotation);
    memset(w_prefix_scope, 0, sizeof(w_prefix_scope));
    memset(w_prefix_masks, 0, sizeof(w_prefix_masks));
    w_prefix_rotations_active = true;
    for (unsigned input = 4; input <= 5; input++) {
        unsigned pairs = input == 4 ? 4 : 16;
        for (unsigned rotation = 0; rotation < pairs; rotation++) {
            w_array_rotation = rotation;
            printf("W prefix%u last-range rotation%u/%u starting\n", pairs - 1,
                   rotation, pairs);
            w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 2, input);
        }
    }
    w_prefix_rotations_active = false;
    w_array_rotation = 0;
    unsigned cells = 0, cases = 0;
    for (unsigned kind = 0; kind < 2; kind++)
        for (unsigned tile = 0; tile < 16; tile++) {
            assert(w_prefix_masks[kind][tile] == 255);
            for (unsigned cut = 0; cut < 4; cut++)
                for (unsigned phase = 0; phase < 2; phase++)
                    for (unsigned restore = 0; restore < 2; restore++) {
                        /* Fixed/MOV *9 polygon pairs *2 layouts *2 scales.
                         * Cut/phase retain the existing mask schedule. */
                        unsigned count =
                            w_prefix_scope[kind][tile][cut][phase][restore];
                        assert(count == 72);
                        cells++;
                        cases += count;
                    }
        }
    assert(cells == 512 && cases == 36864 && groups - first_group == 20);
    printf("W prefix rotations:20 matrices/%u cases/18432 isolated restores/"
           "94371840 exact color-depth-stencil word pairs;512 tile-cut-phase-"
           "restore cells, each72 axes combinations;prefix3/15 all8 W bases/"
           "both windings/all final ranges PASS; cut remains mask-scheduled\n",
           cases);
}


typedef struct {
    double x, y;
} WClipPoint;
static const int w_clip_exponents[] = { -64, -63, -32, -1, 0, 1, 32, 63, 64 };
// The diagonal 1/16 phase avoids exact diamond tangency in this oracle.
static const WClipPoint w_clip_segments[6][2] = {
    { { -3.5, 7.5 }, { 35.5, 7.5 } },
    { { 7.5, -3.5 }, { 7.5, 35.5 } },
    { { -3.5, 2.5625 }, { 35.5, 13.5625 } },
    { { 35.5, 2.5625 }, { -3.5, 13.5625 } },
    { { 3.5, 7.5 }, { 28.5, 7.5 } },
    { { -16384, 7.5 }, { 31.5625, 7.5 } }
};
/* Independent reference: finite perturbation in double, slab clipping of a
 * transformed w_clip_diamond. Test coordinates are multiples of 1/16, so these
 * two perturbations are much smaller than every nonzero geometric separation.
 */
static bool w_clip_diamond(WClipPoint a, WClipPoint b, WClipPoint centre)
{
    a.x -= 1e-8;
    b.x -= 1e-8;
    a.y += 1e-12;
    b.y += 1e-12;
    double pa[2] = { a.x + a.y, a.x - a.y }, pb[2] = { b.x + b.y, b.x - b.y };
    double pc[2] = { centre.x + centre.y, centre.x - centre.y };
    double enter = 0, leave = 1;
    bool end_inside = true;
    for (unsigned i = 0; i < 2; i++) {
        double lo = pc[i] - .5, hi = pc[i] + .5, d = pb[i] - pa[i];
        end_inside &= pb[i] > lo && pb[i] < hi;
        if (d == 0) {
            if (!(pa[i] > lo && pa[i] < hi))
                return false;
        } else {
            double p = (lo - pa[i]) / d, q = (hi - pa[i]) / d;
            enter = fmax(enter, fmin(p, q));
            leave = fmin(leave, fmax(p, q));
        }
    }
    return !end_inside && enter < leave;
}
static bool w_clip_alias_reference(WClipPoint a, WClipPoint b,
                                   WClipPoint centre, double width)
{
    unsigned w = (unsigned)fmax(1, floor(width + .5));
    bool x_major = fabs(b.x - a.x) >= fabs(b.y - a.y);
    if (x_major) {
        a.y += (w - 1) * .5;
        b.y += (w - 1) * .5;
    } else {
        a.x -= (w - 1) * .5;
        b.x -= (w - 1) * .5;
    }
    for (unsigned k = 0; k < w; k++) {
        WClipPoint c = centre;
        if (x_major)
            c.y += k;
        else
            c.x -= k;
        if (w_clip_diamond(a, b, c))
            return true;
    }
    return false;
}
/* GPU clips a pixel square by oblique halfplanes. This reference instead
 * clips the oblique line rectangle by the pixel's four axis-aligned sides. */
static double w_clip_coverage_reference(WClipPoint a, WClipPoint b,
                                        WClipPoint centre, double width)
{
    double dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy);
    double nx = -dy / length * width * .5, ny = dx / length * width * .5;
    WClipPoint polygon[12] = { { a.x + nx, a.y + ny },
                               { a.x - nx, a.y - ny },
                               { b.x - nx, b.y - ny },
                               { b.x + nx, b.y + ny } };
    unsigned count = 4;
    for (unsigned side = 0; side < 4 && count; side++) {
        WClipPoint next[12];
        unsigned n = 0;
        unsigned axis = side / 2;
        double boundary = (axis ? centre.y : centre.x) + (side % 2 ? .5 : -.5);
        WClipPoint previous = polygon[count - 1];
        double pv = axis ? previous.y : previous.x;
        bool pi = side % 2 ? pv <= boundary : pv >= boundary;
        for (unsigned i = 0; i < count; i++) {
            WClipPoint current = polygon[i];
            double cv = axis ? current.y : current.x;
            bool ci = side % 2 ? cv <= boundary : cv >= boundary;
            if (pi != ci) {
                double t = (boundary - pv) / (cv - pv);
                next[n++] =
                    (WClipPoint){ previous.x + t * (current.x - previous.x),
                                  previous.y + t * (current.y - previous.y) };
            }
            if (ci)
                next[n++] = current;
            previous = current;
            pv = cv;
            pi = ci;
        }
        count = n;
        memcpy(polygon, next, n * sizeof(WClipPoint));
    }
    double area = 0;
    for (unsigned i = 0; i < count; i++) {
        WClipPoint a = polygon[i], b = polygon[(i + 1) % count];
        a.x -= centre.x;
        a.y -= centre.y;
        b.x -= centre.x;
        b.y -= centre.y;
        area += a.x * b.y - a.y * b.x;
    }
    return fmin(1, fabs(area) * .5);
}


static unsigned w_quad_words(unsigned quads, unsigned front, unsigned back,
                             unsigned mask, unsigned scale, BOOL swizzle,
                             unsigned ref, BOOL strip)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    require([surfaces.cache prepareCPUAccessAtAddress:8192
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    const WClipPoint corners[4] = { { 1, 1 }, { 7, 1 }, { 7, 7 }, { 1, 7 } };
    const unsigned triangles[2][2][3] = { { { 0, 1, 2 }, { 0, 2, 3 } },
                                          { { 0, 1, 3 }, { 1, 2, 3 } } };
    const unsigned shifts[4] = { 0, 1, 2, 0 };
    for (unsigned y = 0; y < 32; y++)
        for (unsigned x = 0; x < 32; x++) {
            unsigned tile = y / 8 * 4 + x / 8, mode = tile & 1 ? front : back;
            double base = ldexp(1, w_quad_exponents[tile / 2]);
            double reciprocal[4] = { 1 / base, .5 / base, .25 / base,
                                     1 / base };
            double gx[2], gy[2], constant[2], slope[2];
            for (unsigned t = 0; t < 2; t++) {
                unsigned a = triangles[strip][t][0], b = triangles[strip][t][1],
                         c = triangles[strip][t][2];
                double dx1 = corners[b].x - corners[a].x,
                       dy1 = corners[b].y - corners[a].y;
                double dx2 = corners[c].x - corners[a].x,
                       dy2 = corners[c].y - corners[a].y;
                double r1 = reciprocal[b] - reciprocal[a],
                       r2 = reciprocal[c] - reciprocal[a];
                double determinant = dx1 * dy2 - dx2 * dy1;
                gx[t] = (r1 * dy2 - r2 * dy1) / determinant;
                gy[t] = (dx1 * r2 - dx2 * r1) / determinant;
                constant[t] =
                    reciprocal[a] - gx[t] * corners[a].x - gy[t] * corners[a].y;
                slope[t] = fmax(fabs(gx[t]), fabs(gy[t]));
            }
            WClipPoint local = { x % 8 + .5 / scale, y % 8 + .5 / scale };
            double candidates[4], slopes[4];
            unsigned count = 0;
            BOOL active = tile < quads, expected_covered = NO;
            if (mode == NV2AMetalPolygonFill) {
                expected_covered =
                    local.x >= 1 && local.x < 7 && local.y >= 1 && local.y < 7;
                unsigned t = strip ? (local.x + local.y < 8 ? 0 : 1) :
                                     (local.x >= local.y ? 0 : 1);
                candidates[count] =
                    1 / (constant[t] + gx[t] * local.x + gy[t] * local.y);
                slopes[count++] = slope[t];
            } else if (mode == NV2AMetalPolygonPoint) {
                for (unsigned c = 0; c < 4; c++)
                    if (fabs(local.x - corners[c].x) < 1 &&
                        fabs(local.y - corners[c].y) < 1) {
                        expected_covered = YES;
                        unsigned first = strip ? 0 : (tile & 1 ? 1 : 0);
                        unsigned last = w_quad_corner(tile, 3, strip);
                        unsigned t = c == last ? 1 - first : first;
                        candidates[count] = ldexp(base, shifts[c]);
                        slopes[count++] = slope[t];
                    }
            } else {
                assert(mode == NV2AMetalPolygonLine);
                const unsigned strip_edges[4] = { 0, 1, 3, 2 };
                for (unsigned edge = 0; edge < 4; edge++) {
                    unsigned ia = strip ? strip_edges[edge] : edge,
                             ib = strip ? strip_edges[(edge + 1) % 4] :
                                          (edge + 1) % 4;
                    unsigned a = w_quad_corner(tile, ia, strip),
                             b = w_quad_corner(tile, ib, strip);
                    WClipPoint pa = { corners[a].x * scale,
                                      corners[a].y * scale };
                    WClipPoint pb = { corners[b].x * scale,
                                      corners[b].y * scale };
                    WClipPoint centre = { local.x * scale, local.y * scale };
                    if (!w_clip_alias_reference(pa, pb, centre, scale))
                        continue;
                    expected_covered = YES;
                    double dx = corners[b].x - corners[a].x,
                           dy = corners[b].y - corners[a].y;
                    double t = ((local.x - corners[a].x) * dx +
                                (local.y - corners[a].y) * dy) /
                               (dx * dx + dy * dy);
                    unsigned plane;
                    if (strip)
                        plane = (a == 0 || b == 0) ? 0 : 1;
                    else
                        plane = (a == 3 || b == 3) ? 1 : 0;
                    candidates[count] =
                        1 / ((1 - t) * reciprocal[a] + t * reciprocal[b]);
                    slopes[count++] = slope[plane];
                }
            }
            unsigned index =
                swizzle ? (x & 1) | (x & 2) << 1 | (x & 4) << 2 | (x & 8) << 3 |
                              (x & 16) << 4 | (y & 1) << 1 | (y & 2) << 2 |
                              (y & 4) << 3 | (y & 8) << 4 | (y & 16) << 5 :
                          y * 32 + x;
            uint32_t color, raw;
            memcpy(&color, state->vram_ptr + 1024 + index * 4, 4);
            memcpy(&raw, state->vram_ptr + 8192 + index * 4, 4);
            BOOL covered = color == 0xff0000ff;
            if ((!covered && color != 0xffff0000) ||
                covered != (active && expected_covered)) {
                fprintf(
                    stderr,
                    "W quad%u coverage front%u back%u mask%u scale%u swizzle%u "
                    "quads%u tile%u pixel%u,%u color%08x expected%u\n",
                    strip, front, back, mask, scale, swizzle, quads, tile,
                    x % 8, y % 8, color, active && expected_covered);
                abort();
            }
            BOOL matched = !covered && raw == 0xfeffffa5;
            for (unsigned c = 0; covered && c < count; c++) {
                double w = candidates[c], z = w;
                if (mask & (1u << mode))
                    z += 0x1p-65 + .5 * w * w * slopes[c];
                float depth = z;
                uint32_t bits;
                memcpy(&bits, &depth, 4);
                uint32_t expected =
                    (bits >> 7) << 8 | (0xa5 & ~0x3cu) | (ref & 0x3c);
                // ALWAYS depth/stencil preserves the last covered edge in draw
                // order.
                matched = raw == expected;
            }
            if (!matched) {
                fprintf(stderr,
                        "W quad%u depth front%u back%u mask%u scale%u "
                        "swizzle%u quads%u tile%u pixel%u,%u color%08x raw%08x "
                        "candidates%u\n",
                        strip, front, back, mask, scale, swizzle, quads, tile,
                        x % 8, y % 8, color, raw, count);
                abort();
            }
        }
    return 1024;
}

static unsigned w_strip_words(unsigned chains, unsigned front, unsigned back,
                              unsigned mask, unsigned scale, BOOL swizzle,
                              unsigned ref, BOOL increment, unsigned quads,
                              unsigned input)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    require([surfaces.cache prepareCPUAccessAtAddress:8192
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    const int shifts[8] = { 0, 1, 0, 2, 1, 0, 2, 1 };
    assert(quads == 2 || quads == 3);
    const unsigned triangles[2][3] = { { 0, 1, 2 }, { 2, 1, 3 } };
    const unsigned edges[4] = { 0, 1, 3, 2 };
    for (unsigned y = 0; y < 32; y++)
        for (unsigned x = 0; x < 32; x++) {
            unsigned tile = y / 8 * 4 + x / 8;
            unsigned mode = tile & 1 ? front : back;
            WClipPoint local = { x % 8 + .5 / scale, y % 8 + .5 / scale };
            BOOL covered = NO;
            uint32_t expected = increment ? 0xfeffff00 : 0xfeffffa5;
            unsigned samples = 0;
            // Primitive order matters at the shared edge and its two points.
            for (unsigned quad = 0; tile < chains && quad < quads; quad++) {
                WClipPoint points[4];
                double reciprocal[4], w[4];
                for (unsigned i = 0; i < 4; i++) {
                    unsigned v = 2 * quad + i;
                    if (input == 8)
                        v %= 4;
                    else if (input == 9 && v >= 6)
                        v -= 4;
                    points[i] =
                        (WClipPoint){ (v ^ tile) & 1 ? 7 : 1,
                                      1 + v / 2 * (input == 8 ? 6 : 6 / quads) +
                                          (quads == 3 ? 0x1p-4 : 0) };
                    w[i] = ldexp(1, w_quad_exponents[tile / 2] + shifts[v]);
                    reciprocal[i] = 1 / w[i];
                }
                if (input >= 8) {
                    double area = (points[1].x - points[0].x) *
                                      (points[2].y - points[0].y) -
                                  (points[2].x - points[0].x) *
                                      (points[1].y - points[0].y);
                    assert(area);
                    mode = area > 0 ? front : back;
                }
                double gx[2], gy[2], constant[2], slope[2];
                for (unsigned t = 0; t < 2; t++) {
                    unsigned a = triangles[t][0], b = triangles[t][1],
                             c = triangles[t][2];
                    double dx1 = points[b].x - points[a].x,
                           dy1 = points[b].y - points[a].y;
                    double dx2 = points[c].x - points[a].x,
                           dy2 = points[c].y - points[a].y;
                    double r1 = reciprocal[b] - reciprocal[a],
                           r2 = reciprocal[c] - reciprocal[a];
                    double determinant = dx1 * dy2 - dx2 * dy1;
                    gx[t] = (r1 * dy2 - r2 * dy1) / determinant;
                    gy[t] = (dx1 * r2 - dx2 * r1) / determinant;
                    constant[t] = reciprocal[a] - gx[t] * points[a].x -
                                  gy[t] * points[a].y;
                    slope[t] = fmax(fabs(gx[t]), fabs(gy[t]));
                }
                double depths[4], slopes[4];
                unsigned hits = 0;
                if (mode == NV2AMetalPolygonFill) {
                    for (unsigned t = 0; t < 2; t++) {
                        unsigned a = triangles[t][0], b = triangles[t][1],
                                 c = triangles[t][2];
                        double dx1 = points[b].x - points[a].x,
                               dy1 = points[b].y - points[a].y;
                        double dx2 = points[c].x - points[a].x,
                               dy2 = points[c].y - points[a].y;
                        double dx = local.x - points[a].x,
                               dy = local.y - points[a].y;
                        double determinant = dx1 * dy2 - dx2 * dy1;
                        double u = (dx * dy2 - dx2 * dy) / determinant;
                        double v = (dx1 * dy - dx * dy1) / determinant;
                        if (u < 0 || v < 0 || u + v > 1)
                            continue;
                        depths[hits] = 1 / (constant[t] + gx[t] * local.x +
                                            gy[t] * local.y);
                        slopes[hits++] = slope[t];
                    }
                    assert(hits <= 1); // Sample phases avoid diagonal ties.
                } else if (mode == NV2AMetalPolygonPoint) {
                    for (unsigned i = 0; i < 4; i++)
                        if (fabs(local.x - points[i].x) < 1 &&
                            fabs(local.y - points[i].y) < 1) {
                            depths[hits] = w[i];
                            slopes[hits++] = slope[i == 3];
                        }
                } else {
                    assert(mode == NV2AMetalPolygonLine);
                    for (unsigned e = 0; e < 4; e++) {
                        unsigned a = edges[e], b = edges[(e + 1) % 4];
                        WClipPoint pa = { points[a].x * scale,
                                          points[a].y * scale };
                        WClipPoint pb = { points[b].x * scale,
                                          points[b].y * scale };
                        WClipPoint centre = { local.x * scale,
                                              local.y * scale };
                        if (!w_clip_alias_reference(pa, pb, centre, scale))
                            continue;
                        double dx = points[b].x - points[a].x,
                               dy = points[b].y - points[a].y;
                        double t = ((local.x - points[a].x) * dx +
                                    (local.y - points[a].y) * dy) /
                                   (dx * dx + dy * dy);
                        depths[hits] =
                            1 / ((1 - t) * reciprocal[a] + t * reciprocal[b]);
                        slopes[hits++] = slope[e == 1 || e == 2];
                    }
                }
                for (unsigned h = 0; h < hits; h++) {
                    double z = depths[h];
                    if (mask & (1u << mode))
                        z += 0x1p-65 + .5 * z * z * slopes[h];
                    float depth = z;
                    uint32_t bits;
                    memcpy(&bits, &depth, 4);
                    expected = (bits >> 7) << 8 |
                               (increment ? ++samples :
                                            (0xa5 & ~0x3cu) | (ref & 0x3c));
                    covered = YES;
                }
            }
            unsigned index =
                swizzle ? (x & 1) | (x & 2) << 1 | (x & 4) << 2 | (x & 8) << 3 |
                              (x & 16) << 4 | (y & 1) << 1 | (y & 2) << 2 |
                              (y & 4) << 3 | (y & 8) << 4 | (y & 16) << 5 :
                          y * 32 + x;
            uint32_t color, raw;
            memcpy(&color, state->vram_ptr + 1024 + index * 4, 4);
            memcpy(&raw, state->vram_ptr + 8192 + index * 4, 4);
            if (color != (covered ? 0xff0000ff : 0xffff0000) ||
                raw != expected) {
                fprintf(stderr,
                        "W connected strip front%u back%u mask%u scale%u "
                        "swizzle%u chains%u tile%u pixel%u,%u color%08x "
                        "raw%08x expected%08x covered%u\n",
                        front, back, mask, scale, swizzle, chains, tile, x % 8,
                        y % 8, color, raw, expected, covered);
                abort();
            }
        }
    return 1024;
}

static unsigned w_clip_dispatcher_words(unsigned segment, int exponent,
                                        BOOL reverse, BOOL smooth, BOOL cull,
                                        unsigned scale, BOOL swizzle,
                                        unsigned ref, unsigned lines)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    require([surfaces.cache prepareCPUAccessAtAddress:8192
                                               length:4096
                                                write:NO
                                                error:&error],
            error);
    WClipPoint a[2], b[2], ca[2], cb[2];
    double wa = ldexp(segment == 4 ? -1 : 1, exponent),
           wb = ldexp(1, -exponent);
    for (unsigned i = 0; i < 2; i++) {
        a[i] = w_clip_segments[segment][0];
        b[i] = w_clip_segments[segment][1];
        if (segment == 1) {
            a[i].x += 16 * i;
            b[i].x += 16 * i;
        } else {
            a[i].y += 16 * i;
            b[i].y += 16 * i;
        }
        if (segment == 4) {
            ca[i] = (WClipPoint){ 32, a[i].y };
            cb[i] = b[i];
        } else {
            double start[2] = { a[i].x, a[i].y }, end[2] = { b[i].x, b[i].y };
            double enter = 0, leave = 1;
            for (unsigned axis = 0; axis < 2; axis++) {
                double d = end[axis] - start[axis];
                if (!d)
                    continue;
                double lo = -start[axis] / d, hi = (32 - start[axis]) / d;
                enter = fmax(enter, fmin(lo, hi));
                leave = fmin(leave, fmax(lo, hi));
            }
            ca[i] = (WClipPoint){ a[i].x + enter * (b[i].x - a[i].x),
                                  a[i].y + enter * (b[i].y - a[i].y) };
            cb[i] = (WClipPoint){ a[i].x + leave * (b[i].x - a[i].x),
                                  a[i].y + leave * (b[i].y - a[i].y) };
        }
        if (reverse) {
            WClipPoint q = a[i];
            a[i] = b[i];
            b[i] = q;
            q = ca[i];
            ca[i] = cb[i];
            cb[i] = q;
        }
        ca[i].x *= scale;
        ca[i].y *= scale;
        cb[i].x *= scale;
        cb[i].y *= scale;
    }
    if (reverse) {
        double w = wa;
        wa = wb;
        wb = w;
    }
    for (unsigned y = 0; y < 32; y++)
        for (unsigned x = 0; x < 32; x++) {
            // Download selects the first native sample in each scale block.
            WClipPoint native = { x * scale + .5, y * scale + .5 };
            double coverage = 0, z = 0;
            for (unsigned i = 0; i < lines; i++) {
                double c =
                    smooth ?
                        w_clip_coverage_reference(ca[i], cb[i], native, scale) :
                        w_clip_alias_reference(ca[i], cb[i], native, scale);
                if (c <= 1e-7)
                    continue;
                assert(coverage == 0);
                WClipPoint centre = { native.x / scale, native.y / scale };
                double dx = b[i].x - a[i].x, dy = b[i].y - a[i].y;
                double t =
                    ((centre.x - a[i].x) * dx + (centre.y - a[i].y) * dy) /
                    (dx * dx + dy * dy);
                double w = 1 / ((1 - t) / wa + t / wb);
                // A diamond may cover outside the positive-W endpoint while
                // its sample centre lies beyond the reciprocal horizon.
                double depth = w > 0 ? w : 0x1.fffffep127;
                if (cull && depth > 0x1.ffffp127)
                    continue;
                z = fmin(depth, 0x1.ffffp127);
                coverage = c;
            }
            unsigned index =
                swizzle ? (x & 1) | (x & 2) << 1 | (x & 4) << 2 | (x & 8) << 3 |
                              (x & 16) << 4 | (y & 1) << 1 | (y & 2) << 2 |
                              (y & 4) << 3 | (y & 8) << 4 | (y & 16) << 5 :
                          y * 32 + x;
            uint32_t color, raw;
            memcpy(&color, state->vram_ptr + 1024 + index * 4, 4);
            memcpy(&raw, state->vram_ptr + 8192 + index * 4, 4);
            uint32_t expected = 0xfeffffa5;
            BOOL matched;
            if (coverage > 0) {
                unsigned alpha = (unsigned)lround(coverage * 255);
                matched = (color & 0xffffff) == 0xff &&
                          abs((int)(color >> 24) - (int)alpha) <= 1;
                if (!matched) {
                    fprintf(
                        stderr,
                        "W clip dispatcher color segment%u e%d reverse%u "
                        "smooth%u cull%u scale%u swizzle%u lines%u pixel%u,%u: "
                        "%08x coverage%.12g\n",
                        segment, exponent, reverse, smooth, cull, scale,
                        swizzle, lines, x, y, color, coverage);
                    abort();
                }
                float depth = z;
                uint32_t bits;
                memcpy(&bits, &depth, 4);
                uint32_t code = bits >> 7,
                         stencil = (0xa5 & ~0x3cu) | (ref & 0x3c);
                expected = code << 8 | stencil;
                matched = raw == expected;
            } else
                matched = color == 0xffff0000 && raw == expected;
            if (!matched) {
                fprintf(stderr,
                        "W clip dispatcher depth segment%u e%d reverse%u "
                        "smooth%u cull%u scale%u swizzle%u lines%u pixel%u,%u: "
                        "color%08x raw%08x expected%08x coverage%.12g\n",
                        segment, exponent, reverse, smooth, cull, scale,
                        swizzle, lines, x, y, color, raw, expected, coverage);
                abort();
            }
        }
    return 1024;
}

static void w_clip_begin_snapshot(void)
{
    unsigned cases = 0, restored = 0, words = 0;
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned smooth = 0; smooth < 2; smooth++)
            for (unsigned clamp = 0; clamp < 2; clamp++)
                for (unsigned swizzle = 0; swizzle < 2; swizzle++)
                    for (unsigned scale = 1; scale <= 2; scale++)
                        for (unsigned restore = 0; restore < 2; restore++) {
                            fixture();
                            PGRAPHState *pg = &state->pgraph;
                            dma[0].limit = dma[1].limit = dma[2].limit = 4095;
                            dma[1].address = 8192;
                            pg->surface_scale_factor = scale;
                            g_config.display.quality.surface_scale = scale;
                            uint32_t format = 0;
                            SET_MASK(
                                format, NV097_SET_SURFACE_FORMAT_COLOR,
                                NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8);
                            SET_MASK(format, NV097_SET_SURFACE_FORMAT_ZETA,
                                     NV097_SET_SURFACE_FORMAT_ZETA_Z24S8);
                            SET_MASK(format, NV097_SET_SURFACE_FORMAT_TYPE,
                                     swizzle ?
                                         NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE :
                                         NV097_SET_SURFACE_FORMAT_TYPE_PITCH);
                            SET_MASK(format, NV097_SET_SURFACE_FORMAT_WIDTH, 5);
                            SET_MASK(format, NV097_SET_SURFACE_FORMAT_HEIGHT,
                                     5);
                            send_method(NV097_SET_SURFACE_FORMAT, format);
                            send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL,
                                        32 << 16);
                            send_method(NV097_SET_SURFACE_CLIP_VERTICAL,
                                        32 << 16);
                            send_method(NV097_SET_SURFACE_PITCH,
                                        128 | 128 << 16);
                            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                        PS_REGISTER_C0);
                            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                        (PS_REGISTER_C0 | PS_CHANNEL_ALPHA)
                                            << 8);
                            send_method(NV097_SET_STENCIL_TEST_ENABLE, 1);
                            send_method(NV097_SET_STENCIL_FUNC_MASK, 255);
                            send_method(NV097_SET_STENCIL_OP_FAIL, 0x1e00);
                            send_method(NV097_SET_STENCIL_OP_ZFAIL, 0x1e00);
                            send_method(NV097_SET_STENCIL_OP_ZPASS, 0x1e01);
                            send_method(NV097_SET_CLEAR_RECT_HORIZONTAL,
                                        31 << 16);
                            send_method(NV097_SET_CLEAR_RECT_VERTICAL,
                                        31 << 16);
                            for (unsigned segment = 0; segment < 6; segment++)
                                for (unsigned e = 0;
                                     e < G_N_ELEMENTS(w_clip_exponents); e++)
                                    for (unsigned reverse = 0; reverse < 2;
                                         reverse++) {
                                        int exponent = w_clip_exponents[e];
                                        unsigned ref =
                                            (segment * 37 + e * 19 +
                                             reverse * 11 + smooth * 3) &
                                            255;
                                        float positions[4][4];
                                        for (unsigned line = 0; line < 2;
                                             line++)
                                            for (unsigned i = 0; i < 2; i++) {
                                                unsigned endpoint = i ^ reverse;
                                                float *v =
                                                    positions[line * 2 + i];
                                                v[0] =
                                                    w_clip_segments[segment]
                                                                   [endpoint]
                                                                       .x +
                                                    (segment == 1 ? 16 * line :
                                                                    0);
                                                v[1] =
                                                    w_clip_segments[segment]
                                                                   [endpoint]
                                                                       .y +
                                                    (segment == 1 ? 0 :
                                                                    16 * line);
                                                v[2] = 1;
                                                v[3] = ldexpf(
                                                    segment == 4 && !endpoint ?
                                                        -1 :
                                                        1,
                                                    endpoint ? -exponent :
                                                               exponent);
                                                if (!programmed)
                                                    for (unsigned k = 0; k < 3;
                                                         k++)
                                                        v[k] *= v[3];
                                            }
                                        cpu_write(16384, sizeof(positions));
                                        memcpy(state->vram_ptr + 16384,
                                               positions, sizeof(positions));
                                        pg->regs_[NV_PGRAPH_CSV0_D] =
                                            programmed ?
                                                2u << 30 |
                                                    NV_PGRAPH_CSV0_D_RANGE_MODE :
                                                0;
                                        memset(pg->program_data, 0,
                                               sizeof(pg->program_data));
                                        pg->program_data[0][1] = 1 << 21 | 27;
                                        pg->program_data[0][2] = 2u << 26;
                                        pg->program_data[0][3] =
                                            1 << 11 | 15 << 12 | 1;
                                        float zero = 0;
                                        memcpy(
                                            &pg->vsh_constants
                                                 [NV_IGRAPH_XF_XFCTX_CMAT0][3],
                                            &zero, 4);
                                        pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                                            pg->regs_[NV_PGRAPH_WINDOWCLIPY0] =
                                                31 << 16;
                                        send_method(
                                            NV097_SET_LINE_SMOOTH_ENABLE,
                                            smooth);
                                        send_float_method(NV097_SET_CLIP_MIN,
                                                          0);
                                        send_float_method(NV097_SET_CLIP_MAX,
                                                          0x1.ffffp127f);
                                        send_method(
                                            NV097_SET_CONTROL0,
                                            NV097_SET_CONTROL0_Z_FORMAT |
                                                NV097_SET_CONTROL0_STENCIL_WRITE_ENABLE |
                                                NV097_SET_CONTROL0_Z_PERSPECTIVE_ENABLE);
                                        send_method(NV097_SET_DEPTH_TEST_ENABLE,
                                                    1);
                                        send_method(NV097_SET_DEPTH_MASK, 1);
                                        send_method(NV097_SET_DEPTH_FUNC,
                                                    0x207);
                                        send_method(NV097_SET_STENCIL_FUNC,
                                                    0x207);
                                        send_method(NV097_SET_STENCIL_FUNC_REF,
                                                    ref);
                                        send_method(NV097_SET_STENCIL_MASK,
                                                    0x3c);
                                        send_method(
                                            NV097_SET_SPECULAR_FOG_FACTOR,
                                            0xff0000ff);
                                        send_method(
                                            NV097_SET_ZSTENCIL_CLEAR_VALUE,
                                            0xfeffffa5);
                                        send_method(NV097_SET_COLOR_CLEAR_VALUE,
                                                    0xffff0000);
                                        send_method(
                                            NV097_CLEAR_SURFACE,
                                            NV097_CLEAR_SURFACE_COLOR |
                                                NV097_CLEAR_SURFACE_Z |
                                                NV097_CLEAR_SURFACE_STENCIL);
                                        uint32_t clip = 0;
                                        SET_MASK(
                                            clip,
                                            NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN,
                                            clamp ?
                                                NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CLAMP :
                                                NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CULL);
                                        send_method(NV097_SET_ZMIN_MAX_CONTROL,
                                                    clip);
                                        begin(PRIM_TYPE_LINES);
                                        // Live writes belong to the next Begin,
                                        // including CULL and line smoothing.
                                        SET_MASK(
                                            clip,
                                            NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN,
                                            clamp ?
                                                NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CULL :
                                                NV097_SET_ZMIN_MAX_CONTROL_ZCLAMP_EN_CLAMP);
                                        send_method(NV097_SET_ZMIN_MAX_CONTROL,
                                                    clip);
                                        send_method(
                                            NV097_SET_LINE_SMOOTH_ENABLE,
                                            !smooth);
                                        send_method(NV097_SET_CONTROL0, 0);
                                        send_float_method(NV097_SET_CLIP_MAX,
                                                          1);
                                        send_method(NV097_SET_DEPTH_MASK, 0);
                                        send_method(NV097_SET_DEPTH_FUNC,
                                                    0x200);
                                        send_method(NV097_SET_STENCIL_FUNC,
                                                    0x200);
                                        send_method(NV097_SET_STENCIL_FUNC_REF,
                                                    ref ^ 255);
                                        send_method(NV097_SET_STENCIL_MASK, 0);
                                        send_method(
                                            NV097_SET_SPECULAR_FOG_FACTOR,
                                            0xffffff00);
                                        pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                                            pg->regs_[NV_PGRAPH_WINDOWCLIPY0] =
                                                1;
                                        if (programmed)
                                            pg->program_data[0][1] = 15u << 21;
                                        else {
                                            float translation = 4;
                                            memcpy(
                                                &pg->vsh_constants
                                                     [NV_IGRAPH_XF_XFCTX_CMAT0]
                                                     [3],
                                                &translation, 4);
                                        }
                                        arrays(0, 2);
                                        qemu_mutex_lock(&pg->lock);
                                        renderer.ops.flush_draw(state);
                                        qemu_mutex_unlock(&pg->lock);
                                        pg->draw_arrays_length = 0;
                                        if (restore) {
                                            renderer.ops.pre_savevm_trigger(
                                                state);
                                            process_pending();
                                            renderer.ops.pre_savevm_wait(state);
                                        }
                                        words += w_clip_dispatcher_words(
                                            segment, exponent, reverse, smooth,
                                            !clamp, scale, swizzle, ref, 1);
                                        int fd = -1;
                                        NSData *ram = nil;
                                        if (restore) {
                                            fd = new_vertex_snapshot_file();
                                            save_vertex_snapshot(fd);
                                            ram = [NSData
                                                dataWithBytes:state->vram_ptr
                                                       length:65536];
                                        }
                                        arrays(2, 2);
                                        end();
                                        words += w_clip_dispatcher_words(
                                            segment, exponent, reverse, smooth,
                                            !clamp, scale, swizzle, ref, 2);
                                        if (restore) {
                                            before_ram_load();
                                            memcpy(state->vram_ptr, ram.bytes,
                                                   ram.length);
                                            assert(load_vertex_snapshot(fd) ==
                                                   0);
                                            pg->draw_arrays_length = 0;
                                            after_ram_load();
                                            close(fd);
                                            arrays(2, 2);
                                            end();
                                            words += w_clip_dispatcher_words(
                                                segment, exponent, reverse,
                                                smooth, !clamp, scale, swizzle,
                                                ref, 2);
                                            restored++;
                                        }
                                        cases++;
                                    }
                        }
    assert(cases == 6912 && restored == 3456 && words == 17694720);
    printf("Metal4 W clip dispatcher: %u cases/%u partial-Begin restores/%u "
           "packed depth-stencil words and colors PASS\n",
           cases, restored, words);
    groups++;
}

static void readonly_zeta_bindings(void)
{
    for (unsigned kind = 0; kind < 4; kind++)
        for (unsigned cached = 0; cached < 3; cached++)
            for (unsigned pass = 0; pass < 2; pass++)
                for (unsigned restore = 0; restore < 2; restore++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    BOOL z24 = kind != 0, stencil = kind >= 2;
                    pg->surface_shape.zeta_format =
                        z24 ? NV097_SET_SURFACE_FORMAT_ZETA_Z24S8 :
                              NV097_SET_SURFACE_FORMAT_ZETA_Z16;
                    pg->surface_zeta.pitch = z24 ? 32 : 16;
                    unsigned length = z24 ? 256 : 128;
                    uint32_t seed =
                        z24 ? ((stencil || pass) ? 0xffffff5a : 0x0000005a) :
                              (pass ? 65535 : 0);
                    cpu_write(4096, length);
                    for (unsigned i = 0; i < 64; i++)
                        memcpy(state->vram_ptr + 4096 + i * (z24 ? 4 : 2),
                               &seed, z24 ? 4 : 2);
                    NSError *error = nil;
                    if (cached) {
                        pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = seed;
                        pg->regs_[NV_PGRAPH_CLEARRECTX] =
                            pg->regs_[NV_PGRAPH_CLEARRECTY] = 7 << 16;
                        send_method(
                            NV097_CLEAR_SURFACE,
                            NV097_CLEAR_SURFACE_Z |
                                (z24 ? NV097_CLEAR_SURFACE_STENCIL : 0));
                        require(
                            [surfaces.cache submitWithError:&error] &&
                                [surfaces.cache waitUntilIdleWithError:&error],
                            error);
                        assert(surfaces.zeta.dirty);
                        if (cached == 1) {
                            require([surfaces.cache
                                        prepareCPUAccessAtAddress:4096
                                                           length:length
                                                            write:NO
                                                            error:&error],
                                    error);
                            assert(!surfaces.zeta.dirty);
                        }
                    }
                    send_method(NV097_SET_DEPTH_TEST_ENABLE, kind != 2);
                    send_method(NV097_SET_DEPTH_MASK, 0);
                    send_method(NV097_SET_DEPTH_FUNC, 0x201);
                    if (stencil) {
                        send_method(NV097_SET_STENCIL_TEST_ENABLE, 1);
                        send_method(NV097_SET_STENCIL_FUNC, 0x202);
                        send_method(NV097_SET_STENCIL_FUNC_REF,
                                    pass ? 0x5a : 0x6b);
                        send_method(NV097_SET_STENCIL_FUNC_MASK, 255);
                        send_method(NV097_SET_STENCIL_MASK, 0);
                        send_method(NV097_SET_STENCIL_OP_FAIL, 0x1e01);
                        send_method(NV097_SET_STENCIL_OP_ZFAIL, 0x1e01);
                        send_method(NV097_SET_STENCIL_OP_ZPASS, 0x1e01);
                    }
                    assert(!pgraph_zeta_write_enabled(pg));
                    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                PS_REGISTER_C0);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
                    begin(PRIM_TYPE_TRIANGLES);
                    assert(surfaces.zeta && surfaces.zeta.address == 4096);
                    require([surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    assert(surfaces.zeta.dirty == (cached == 2));
                    uint64_t generation = surfaces.zeta.generation;
                    // These live masks must not replace the read-only Begin.
                    send_method(NV097_SET_DEPTH_MASK, 1);
                    if (stencil)
                        send_method(NV097_SET_STENCIL_MASK, 255);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
                    if (restore) {
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        int fd = new_vertex_snapshot_file();
                        save_vertex_snapshot(fd);
                        NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                     length:65536];
                        arrays(0, 3);
                        end();
                        before_ram_load();
                        memcpy(state->vram_ptr, ram.bytes, ram.length);
                        assert(load_vertex_snapshot(fd) == 0);
                        pg->draw_arrays_length = 0;
                        after_ram_load();
                        close(fd);
                    }
                    arrays(0, 3);
                    end();
                    require([surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    assert(surfaces.zeta && surfaces.zeta.address == 4096);
                    assert(surfaces.zeta.dirty == (!restore && cached == 2));
                    if (!restore)
                        assert(surfaces.zeta.generation == generation);
                    assert(color(1, 1) == (pass ? 0xff0000ff : 0xffff0000));
                    get_report(0);
                    process_reports();
                    assert(report_result(0) == (pass ? 28 : 0));
                    require([surfaces.cache prepareCPUAccessAtAddress:4096
                                                               length:length
                                                                write:NO
                                                                error:&error],
                            error);
                    for (unsigned i = 0; i < 64; i++) {
                        uint32_t actual = 0;
                        memcpy(&actual,
                               state->vram_ptr + 4096 + i * (z24 ? 4 : 2),
                               z24 ? 4 : 2);
                        assert(actual == seed);
                    }
                }
    groups++;
}
static unsigned channel_logic(unsigned source, unsigned destination,
                              unsigned op)
{
    switch (op) {
    case 0:
        return 0;
    case 1:
        return source & destination;
    case 2:
        return source & ~destination;
    case 3:
        return source;
    case 4:
        return ~source & destination;
    case 5:
        return destination;
    case 6:
        return source ^ destination;
    case 7:
        return source | destination;
    case 8:
        return ~(source | destination);
    case 9:
        return ~(source ^ destination);
    case 10:
        return ~destination;
    case 11:
        return source | ~destination;
    case 12:
        return ~source;
    case 13:
        return ~source | destination;
    case 14:
        return ~(source & destination);
    default:
        return 255;
    }
}
static void packed_color_channels(void)
{
    const unsigned masks[] = { 2, 4, 8, 15 };
    for (unsigned channels = 1; channels <= 2; channels++)
        for (unsigned variant = 0; variant < 25; variant++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            unsigned mask = variant < 8 ? masks[variant / 2] : 15;
            BOOL restore = variant < 8 && (variant & 1);
            BOOL logic = variant >= 8 && variant < 24;
            pg->surface_shape.color_format =
                channels == 1 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_B8 :
                                NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8;
            pg->surface_color.pitch = 8 * channels;
            cpu_write(1024, 256);
            memset(state->vram_ptr + 1024, 0x3c, 256);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xcc336699);
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            pg->regs_[NV_PGRAPH_CONTROL_0] = mask << 26;
            if (logic) {
                send_method(NV097_SET_LOGIC_OP, 0x1500 + variant - 8);
                send_method(NV097_SET_LOGIC_OP_ENABLE, 1);
            }
            if (variant == 24)
                send_method(NV097_SET_DITHER_ENABLE, 1);
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffaa5511);
            pg->surface_shape.color_format =
                NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8;
            pg->surface_color.pitch = 32;
            if (restore) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                             length:65536];
                arrays(0, 3);
                end();
                before_ram_load();
                memcpy(state->vram_ptr, ram.bytes, ram.length);
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            arrays(0, 3);
            end();
            get_report(0);
            process_reports();
            assert(report_result(0) == 28);
            NSError *error = nil;
            require([surfaces.cache prepareCPUAccessAtAddress:1024
                                                       length:256
                                                        write:NO
                                                        error:&error],
                    error);
            for (unsigned y = 0; y < 8; y++)
                for (unsigned x = 0; x < 8; x++) {
                    BOOL covered = x + y < 7;
                    unsigned blue =
                        logic ? channel_logic(153, 0x3c, variant - 8) & 255 :
                                153;
                    unsigned green =
                        logic ? channel_logic(102, 0x3c, variant - 8) & 255 :
                                102;
                    unsigned at = 1024 + (y * 8 + x) * channels;
                    assert(state->vram_ptr[at] ==
                           (covered && (mask & 8) ? blue : 0x3c));
                    if (channels == 2)
                        assert(state->vram_ptr[at + 1] ==
                               (covered && (mask & 4) ? green : 0x3c));
                }
            for (unsigned i = 64 * channels; i < 256; i++)
                assert(state->vram_ptr[1024 + i] == 0x3c);
        }
    groups++;
}
static void packed_rtt_check(unsigned interpretation, unsigned channels,
                             float blue, float green, uint32_t actual)
{
    const float rgba[] = {
        blue, channels == 2 && !interpretation ? green : blue, blue,
        channels == 1 ? interpretation ? blue : 255 : green
    };
    for (unsigned i = 0; i < 4; i++) {
        unsigned shift = (unsigned[]){ 16, 8, 0, 24 }[i];
        float value = (actual >> shift) & 255;
        assert(fabsf(value - rgba[i]) <= 1);
    }
}
static unsigned packed_rtt_address(unsigned x, unsigned y, unsigned channels,
                                   BOOL swizzle)
{
    unsigned at = y * 10 + x;
    if (swizzle) {
        at = 0;
        for (unsigned bit = 0; bit < 3; bit++) {
            at |= ((x >> bit) & 1) << (2 * bit);
            at |= ((y >> bit) & 1) << (2 * bit + 1);
        }
    }
    return 49152 + at * channels;
}
static void packed_color_rtt(void)
{
    for (unsigned channels = 1; channels <= 2; channels++)
        for (unsigned interpretation = 0; interpretation < 2; interpretation++)
            for (unsigned swizzle = 0; swizzle < 2; swizzle++)
                for (unsigned scale = 1; scale <= 2; scale++)
                    for (unsigned sampling = 0; sampling < 3; sampling++)
                        for (unsigned restore = 0; restore < 2; restore++) {
                            fixture();
                            PGRAPHState *pg = &state->pgraph;
                            dma[0].address = 49152;
                            pg->surface_shape.color_format =
                                channels == 1 ?
                                    NV097_SET_SURFACE_FORMAT_COLOR_LE_B8 :
                                    NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8;
                            pg->surface_shape.log_width =
                                pg->surface_shape.log_height = 3;
                            pg->surface_type =
                                swizzle ?
                                    NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE :
                                    NV097_SET_SURFACE_FORMAT_TYPE_PITCH;
                            pg->surface_color.pitch = 10 * channels;
                            pg->surface_scale_factor = scale;
                            cpu_write(49152, 256);
                            memset(state->vram_ptr + 49152, 0x3c, 256);
                            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                        PS_REGISTER_C0);
                            send_method(NV097_SET_SPECULAR_FOG_FACTOR,
                                        0xcc336699);
                            begin(PRIM_TYPE_TRIANGLES);
                            arrays(0, 3);
                            end();
                            NV2AMetalCachedSurface *source = surfaces.color;
                            assert(source.address == 49152 && source.dirty &&
                                   source.transfer.config.scale == scale);
                            dma[0].address = 1024;
                            pg->surface_shape.color_format =
                                NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8;
                            pg->surface_color.pitch = 32;
                            pg->surface_type =
                                NV097_SET_SURFACE_FORMAT_TYPE_PITCH;
                            pg->surface_scale_factor = 1;
                            pg->surface_color.buffer_dirty = true;
                            unsigned texture_format =
                                channels == 1 ?
                                    swizzle ?
                                    interpretation ?
                                    NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8 :
                                    NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8 :
                                    interpretation ?
                                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8 :
                                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8 :
                                swizzle ?
                                    interpretation ?
                                    NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8 :
                                    NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8 :
                                interpretation ?
                                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8 :
                                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8;
                            uint32_t format = NV_PGRAPH_TEXFMT0_CONTEXT_DMA |
                                              texture_format << 8 | 2 << 6 |
                                              NV_PGRAPH_TEXFMT0_BORDER_SOURCE |
                                              1 << 16 | 3 << 20 | 3 << 24;
                            pg->regs_[NV_PGRAPH_TEXFMT0] = format;
                            pg->regs_[NV_PGRAPH_TEXCTL0_0] =
                                NV_PGRAPH_TEXCTL0_0_ENABLE;
                            pg->regs_[NV_PGRAPH_TEXCTL1_0] = 10 * channels
                                                             << 16;
                            pg->regs_[NV_PGRAPH_TEXIMAGERECT0] = 8 << 16 | 8;
                            unsigned filter = sampling == 1 ? 2 : 1;
                            pg->regs_[NV_PGRAPH_TEXFILTER0] =
                                filter << 16 | filter << 24;
                            pg->regs_[NV_PGRAPH_TEXADDRESS0] =
                                3 | 3 << 8 | 3 << 16;
                            pg->regs_[NV_PGRAPH_SHADERPROG] =
                                PS_TEXTUREMODES_PROJECT2D;
                            pg->regs_[NV_PGRAPH_COMBINESPECFOG0] =
                                PS_REGISTER_T0;
                            pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
                                (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
                            float coordinate = sampling == 0 ? 1.5f :
                                               sampling == 1 ? 4.f :
                                                               7.5f;
                            pg->vertex_attributes[9].inline_value[0] =
                                pg->vertex_attributes[9].inline_value[1] =
                                    swizzle ? coordinate / 8 : coordinate;
                            pg->texture_dirty[0] = true;
                            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                            begin(PRIM_TYPE_TRIANGLES);
                            // Readback and subsequent CPU overwrite force
                            // completion of the GPU decode.
                            cpu_write(49152, 256);
                            for (unsigned y = 0; y < 8; y++)
                                for (unsigned x = 0; x < 8; x++) {
                                    BOOL covered = x + y + 1.f / scale < 8;
                                    unsigned at = packed_rtt_address(
                                        x, y, channels, swizzle);
                                    assert(state->vram_ptr[at] ==
                                           (covered ? 153 : 60));
                                    if (channels == 2)
                                        assert(state->vram_ptr[at + 1] ==
                                               (covered ? 102 : 60));
                                }
                            memset(state->vram_ptr + 49152, 0xaa, 256);
                            pg->regs_[NV_PGRAPH_TEXFMT0] = 127u << 8;
                            if (restore) {
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                                int fd = new_vertex_snapshot_file();
                                save_vertex_snapshot(fd);
                                NSData *ram =
                                    [NSData dataWithBytes:state->vram_ptr
                                                   length:65536];
                                arrays(0, 3);
                                end();
                                before_ram_load();
                                memcpy(state->vram_ptr, ram.bytes, ram.length);
                                assert(load_vertex_snapshot(fd) == 0);
                                pg->draw_arrays_length = 0;
                                after_ram_load();
                                close(fd);
                            }
                            arrays(0, 3);
                            end();
                            get_report(0);
                            process_reports();
                            assert(report_result(0) == 28);
                            float weight = sampling == 0 ? 1 :
                                           sampling == 2 ? 0 :
                                           scale == 1    ? .25f :
                                                           .75f;
                            float blue = 60 + weight * (153 - 60);
                            float green = 60 + weight * (102 - 60);
                            for (unsigned y = 0; y < 8; y++)
                                for (unsigned x = 0; x < 8; x++) {
                                    uint32_t actual = color(x, y);
                                    if (x + y < 7)
                                        packed_rtt_check(interpretation,
                                                         channels, blue, green,
                                                         actual);
                                    else
                                        assert(actual == 0xffff0000);
                                }
                            // The next Begin must use the new CPU bytes, not
                            // the frozen texture.
                            pg->regs_[NV_PGRAPH_TEXFMT0] = format;
                            pg->texture_dirty[0] = true;
                            begin(PRIM_TYPE_TRIANGLES);
                            arrays(0, 3);
                            end();
                            packed_rtt_check(interpretation, channels, 170, 170,
                                             color(1, 1));
                        }
    groups++;
}
static void packed_color_alpha_test(void)
{
    for (unsigned channels = 1; channels <= 2; channels++)
        for (unsigned swizzle = 0; swizzle < 2; swizzle++)
            for (unsigned pass = 0; pass < 2; pass++)
                for (unsigned restore = 0; restore < 2; restore++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    pg->surface_shape.color_format =
                        channels == 1 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_B8 :
                                        NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8;
                    pg->surface_shape.log_width = pg->surface_shape.log_height =
                        3;
                    pg->surface_type =
                        swizzle ? NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE :
                                  NV097_SET_SURFACE_FORMAT_TYPE_PITCH;
                    pg->surface_color.pitch = 10 * channels;
                    cpu_write(1024, 256);
                    memset(state->vram_ptr + 1024, 0x3c, 256);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                PS_REGISTER_C0);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xcc336699);
                    send_method(NV097_SET_ALPHA_FUNC, 0x204);
                    send_method(NV097_SET_ALPHA_REF, pass ? 160 : 220);
                    send_method(NV097_SET_ALPHA_TEST_ENABLE, 1);
                    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                    begin(PRIM_TYPE_TRIANGLES);
                    send_method(NV097_SET_ALPHA_REF, pass ? 220 : 160);
                    send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffaa55);
                    if (restore) {
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        int fd = new_vertex_snapshot_file();
                        save_vertex_snapshot(fd);
                        NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                     length:65536];
                        arrays(0, 3);
                        end();
                        before_ram_load();
                        memcpy(state->vram_ptr, ram.bytes, ram.length);
                        assert(load_vertex_snapshot(fd) == 0);
                        pg->draw_arrays_length = 0;
                        after_ram_load();
                        close(fd);
                    }
                    arrays(0, 3);
                    end();
                    get_report(0);
                    process_reports();
                    assert(report_result(0) == (pass ? 28 : 0));
                    NSError *error = nil;
                    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                                               length:256
                                                                write:NO
                                                                error:&error],
                            error);
                    BOOL pixel[256] = { 0 };
                    for (unsigned y = 0; y < 8; y++)
                        for (unsigned x = 0; x < 8; x++) {
                            unsigned at =
                                packed_rtt_address(x, y, channels, swizzle) -
                                49152;
                            pixel[at] = true;
                            BOOL written = pass && x + y < 7;
                            assert(state->vram_ptr[1024 + at] ==
                                   (written ? 153 : 60));
                            if (channels == 2) {
                                pixel[at + 1] = true;
                                assert(state->vram_ptr[1024 + at + 1] ==
                                       (written ? 102 : 60));
                            }
                        }
                    for (unsigned i = 0; i < 256; i++)
                        if (!pixel[i])
                            assert(state->vram_ptr[1024 + i] == 60);
                }
    groups++;
}
static const unsigned xo_formats[] = {
    NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
    NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5,
    NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8,
    NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
    NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
    NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8
};
static unsigned xo_address(unsigned x, unsigned y, unsigned bytes, BOOL swizzle)
{
    unsigned at = y * 10 + x;
    if (swizzle) {
        at = 0;
        for (unsigned bit = 0; bit < 3; bit++) {
            at |= ((x >> bit) & 1) << (2 * bit);
            at |= ((y >> bit) & 1) << (2 * bit + 1);
        }
    }
    return 1024 + at * bytes;
}
static void xo_prepare(unsigned format, BOOL swizzle)
{
    PGRAPHState *pg = &state->pgraph;
    pg->surface_shape.color_format = xo_formats[format];
    pg->surface_shape.log_width = pg->surface_shape.log_height = 3;
    pg->surface_type = swizzle ? NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE :
                                 NV097_SET_SURFACE_FORMAT_TYPE_PITCH;
    pg->surface_color.pitch = (format < 2 ? 2 : 4) * 10;
    cpu_write(1024, 512);
    memset(state->vram_ptr + 1024, 0xce, 512);
    unsigned initial = format < 2 ? 0xa123 : 0xa5335577;
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++)
            memcpy(state->vram_ptr +
                       xo_address(x, y, format < 2 ? 2 : 4, swizzle),
                   &initial, format < 2 ? 2 : 4);
}
static void xo_validate(unsigned format, unsigned mask, unsigned mode,
                        BOOL swizzle)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:512
                                                write:NO
                                                error:&error],
            error);
    const unsigned shifts[2][4] = { { 15, 10, 5, 0 }, { 24, 16, 8, 0 } };
    unsigned bits = format < 2 ? 5 : 8, maximum = (1u << bits) - 1;
    unsigned initial = format < 2 ? 0xa123 : 0xa5335577;
    unsigned alpha_max = format < 2 ? 1 : 255;
    BOOL used[512] = { 0 };
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            unsigned address = xo_address(x, y, format < 2 ? 2 : 4, swizzle);
            unsigned actual = 0;
            memcpy(&actual, state->vram_ptr + address, format < 2 ? 2 : 4);
            for (unsigned b = 0; b < (format < 2 ? 2 : 4); b++)
                used[address - 1024 + b] = true;
            if (mode != 3 && x + y >= 7) {
                assert(actual == initial);
                continue;
            }
            for (unsigned c = 0; c < 4; c++) {
                unsigned shift = shifts[format >= 2][c];
                unsigned limit = c ? maximum : alpha_max;
                unsigned old = (initial >> shift) & limit;
                float expected = old;
                if (mask & (1u << c)) {
                    if (!c)
                        expected = format & 1 ? alpha_max : 0;
                    else if (mode == 3) {
                        unsigned clear = format < 2 ? 0x3211 : 0x00553311;
                        expected = (clear >> shift) & limit;
                    } else {
                        const float source[] = { 0, 51.f / 255, 102.f / 255,
                                                 153.f / 255 };
                        if (mode == 0)
                            expected = source[c] * maximum;
                        else if (mode == 1)
                            expected = (source[c] * 128.f / 255 +
                                        old / (float)maximum * 127.f / 255) *
                                       maximum;
                        else
                            expected =
                                ((unsigned)floorf(source[c] * maximum) ^ old) &
                                maximum;
                    }
                }
                unsigned value = (actual >> shift) & limit;
                float tolerance =
                    c && mode < 2 && (mask & (1u << c)) ? .51f : 0;
                assert(fabsf(value - expected) <= tolerance);
            }
        }
    for (unsigned i = 0; i < 512; i++)
        if (!used[i])
            assert(state->vram_ptr[1024 + i] == 0xce);
}
static void xo_surface_draws(void)
{
    for (unsigned format = 0; format < 4; format++)
        for (unsigned mode = 0; mode < 3; mode++)
            for (unsigned mask = 0; mask < 16; mask++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                BOOL swizzle = !!(mask & 2);
                xo_prepare(format, swizzle);
                pg->regs_[NV_PGRAPH_CONTROL_0] = mask << 26;
                send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                send_method(NV097_SET_DEPTH_FUNC, 0x207);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                            PS_REGISTER_C0);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                            (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8);
                send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0x80336699);
                send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                if (mode == 1) {
                    send_method(NV097_SET_BLEND_ENABLE, 1);
                    send_method(NV097_SET_BLEND_EQUATION, 0x8006);
                    send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0x302);
                    send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0x303);
                } else if (mode == 2) {
                    send_method(NV097_SET_LOGIC_OP, 0x1506);
                    send_method(NV097_SET_LOGIC_OP_ENABLE, 1);
                }
                begin(PRIM_TYPE_TRIANGLES);
                pg->surface_shape.color_format = xo_formats[format ^ 1];
                pg->regs_[NV_PGRAPH_CONTROL_0] ^= 15u << 26;
                send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffaa55);
                if (mask & 1) {
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    int fd = new_vertex_snapshot_file();
                    save_vertex_snapshot(fd);
                    NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                    arrays(0, 3);
                    end();
                    before_ram_load();
                    memcpy(state->vram_ptr, ram.bytes, ram.length);
                    assert(load_vertex_snapshot(fd) == 0);
                    pg->draw_arrays_length = 0;
                    after_ram_load();
                    close(fd);
                }
                arrays(0, 3);
                end();
                get_report(0);
                process_reports();
                assert(report_result(0) == 28);
                xo_validate(format, mask, mode, swizzle);
                // Same native pixel format, different guest Z/O policy.
                pg->regs_[NV_PGRAPH_CONTROL_0] |= 15u << 26;
                begin(PRIM_TYPE_TRIANGLES);
                arrays(0, 3);
                end();
                NSError *error = nil;
                require([surfaces.cache prepareCPUAccessAtAddress:1024
                                                           length:512
                                                            write:NO
                                                            error:&error],
                        error);
                unsigned next = 0;
                memcpy(&next,
                       state->vram_ptr +
                           xo_address(1, 1, format < 2 ? 2 : 4, swizzle),
                       format < 2 ? 2 : 4);
                assert((next >> (format < 2 ? 15 : 24)) ==
                       ((format ^ 1) & 1 ? format < 2 ? 1 : 255 : 0));
            }
    groups++;
}
static void xo_surface_clears(void)
{
    const unsigned flags[] = { NV097_CLEAR_SURFACE_A, NV097_CLEAR_SURFACE_R,
                               NV097_CLEAR_SURFACE_G, NV097_CLEAR_SURFACE_B };
    for (unsigned format = 0; format < 4; format++)
        for (unsigned mask = 0; mask < 16; mask++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            BOOL swizzle = !!(mask & 2);
            xo_prepare(format, swizzle);
            pg->surface_scale_factor = mask & 4 ? 2 : 1;
            send_method(NV097_SET_COLOR_CLEAR_VALUE,
                        format < 2 ? 0x3211 : 0x00553311);
            send_method(NV097_SET_CLEAR_RECT_HORIZONTAL, 7 << 16);
            send_method(NV097_SET_CLEAR_RECT_VERTICAL, 7 << 16);
            unsigned parameter = 0;
            for (unsigned c = 0; c < 4; c++)
                if (mask & (1u << c))
                    parameter |= flags[c];
            send_method(NV097_CLEAR_SURFACE, parameter);
            xo_validate(format, mask, 3, swizzle);
        }
    groups++;
}
static void xo_surface_alpha_test(void)
{
    for (unsigned format = 0; format < 4; format++)
        for (unsigned pass = 0; pass < 2; pass++) {
            fixture();
            xo_prepare(format, format & 1);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                        (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0x80336699);
            send_method(NV097_SET_ALPHA_FUNC, 0x204);
            send_method(NV097_SET_ALPHA_REF, pass ? 100 : 200);
            send_method(NV097_SET_ALPHA_TEST_ENABLE, 1);
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_ALPHA_REF, pass ? 200 : 100);
            arrays(0, 3);
            end();
            get_report(0);
            process_reports();
            assert(report_result(0) == (pass ? 28 : 0));
            xo_validate(format, pass ? 15 : 0, 0, format & 1);
        }
    groups++;
}
static void a7_validate(unsigned format, unsigned mask, unsigned mode,
                        BOOL swizzle)
{
    NSError *error = nil;
    require([surfaces.cache prepareCPUAccessAtAddress:1024
                                               length:512
                                                write:NO
                                                error:&error],
            error);
    const unsigned shifts[] = { 24, 16, 8, 0 };
    const unsigned initial = 0xa5335577;
    const double source[] = { 128.0 / 255, 51.0 / 255, 102.0 / 255,
                              153.0 / 255 };
    const unsigned ranks[] = { 0, 8,  2, 10, 12, 4, 14, 6,
                               3, 11, 1, 9,  15, 7, 13, 5 };
    BOOL used[512] = { 0 };
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            unsigned address = xo_address(x, y, 4, swizzle), actual = 0;
            memcpy(&actual, state->vram_ptr + address, 4);
            for (unsigned b = 0; b < 4; b++)
                used[address - 1024 + b] = true;
            if (mode != 4 && x + y >= 7) {
                assert(actual == initial);
                continue;
            }
            for (unsigned c = 0; c < 4; c++) {
                unsigned old = (initial >> shifts[c]) & 255;
                double expected = old;
                if (mask & (1u << c)) {
                    if (mode == 4)
                        expected = (0xb7553311 >> shifts[c]) & 255;
                    else if (mode == 1) {
                        double destination =
                            c ? old / 255.0 : (old & 127) / 127.0;
                        expected = source[c] * source[0] +
                                   destination * (1 - source[0]);
                    } else if (mode == 2)
                        expected =
                            ((unsigned)floor(source[c] * (c ? 255 : 127)) ^
                             (c ? old : old & 127)) &
                            (c ? 255 : 127);
                    else
                        expected = source[c];
                    if (!c) {
                        unsigned low;
                        if (mode == 4)
                            low = (unsigned)expected & 127;
                        else if (mode == 2)
                            low = expected;
                        else if (mode == 3) {
                            double scaled = expected * 127;
                            low = floor(scaled);
                            low += scaled - low >=
                                   (ranks[(y & 3) * 4 + (x & 3)] + .5) / 16;
                        } else
                            low = floor(fmin(1, fmax(0, expected)) * 127 + .5);
                        expected = low | (format & 1 ? 128u : 0u);
                    } else if (mode < 2 || mode == 3)
                        expected *= 255;
                }
                unsigned value = (actual >> shifts[c]) & 255;
                double tolerance =
                    c && mode < 4 && mode != 2 && (mask & (1u << c)) ? .51 : 0;
                if (fabs(value - expected) > tolerance) {
                    fprintf(stderr,
                            "A7 fmt%u mask%u mode%u at%u,%u channel%u got%u "
                            "expected%g\n",
                            format, mask, mode, x, y, c, value, expected);
                    abort();
                }
            }
        }
    for (unsigned i = 0; i < 512; i++)
        if (!used[i])
            assert(state->vram_ptr[1024 + i] == 0xce);
}
static void a7_surface_draws(void)
{
    for (unsigned format = 4; format < 6; format++)
        for (unsigned mode = 0; mode < 4; mode++)
            for (unsigned mask = 0; mask < 16; mask++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                BOOL swizzle = !!(mask & 2);
                xo_prepare(format, swizzle);
                pg->regs_[NV_PGRAPH_CONTROL_0] = mask << 26;
                send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
                send_method(NV097_SET_DEPTH_FUNC, 0x207);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                            PS_REGISTER_C0);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                            (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8);
                send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0x80336699);
                send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                if (mode == 1) {
                    send_method(NV097_SET_BLEND_ENABLE, 1);
                    send_method(NV097_SET_BLEND_EQUATION, 0x8006);
                    send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0x302);
                    send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0x303);
                } else if (mode == 2) {
                    send_method(NV097_SET_LOGIC_OP, 0x1506);
                    send_method(NV097_SET_LOGIC_OP_ENABLE, 1);
                }
                if (mode == 3)
                    send_method(NV097_SET_DITHER_ENABLE, 1);
                begin(PRIM_TYPE_TRIANGLES);
                pg->surface_shape.color_format = xo_formats[format ^ 1];
                pg->regs_[NV_PGRAPH_CONTROL_0] ^= 15u << 26;
                send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffaa55);
                if (mask & 1) {
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    int fd = new_vertex_snapshot_file();
                    save_vertex_snapshot(fd);
                    NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                    arrays(0, 3);
                    end();
                    before_ram_load();
                    memcpy(state->vram_ptr, ram.bytes, ram.length);
                    assert(load_vertex_snapshot(fd) == 0);
                    pg->draw_arrays_length = 0;
                    after_ram_load();
                    close(fd);
                }
                arrays(0, 3);
                end();
                get_report(0);
                process_reports();
                assert(report_result(0) == 28);
                a7_validate(format, mask, mode, swizzle);
                // Same native pixel format, different guest Z/O policy.
                pg->regs_[NV_PGRAPH_CONTROL_0] |= 15u << 26;
                send_method(NV097_SET_BLEND_ENABLE, 0);
                send_method(NV097_SET_LOGIC_OP_ENABLE, 0);
                send_method(NV097_SET_DITHER_ENABLE, 0);
                begin(PRIM_TYPE_TRIANGLES);
                arrays(0, 3);
                end();
                NSError *error = nil;
                require([surfaces.cache prepareCPUAccessAtAddress:1024
                                                           length:512
                                                            write:NO
                                                            error:&error],
                        error);
                unsigned next = 0;
                memcpy(&next,
                       state->vram_ptr +
                           xo_address(1, 1, format < 2 ? 2 : 4, swizzle),
                       format < 2 ? 2 : 4);
                assert((next >> 24) == (((format ^ 1) & 1 ? 128u : 0u) | 127u));
            }
    groups++;
}
static void a7_surface_clears(void)
{
    const unsigned flags[] = { NV097_CLEAR_SURFACE_A, NV097_CLEAR_SURFACE_R,
                               NV097_CLEAR_SURFACE_G, NV097_CLEAR_SURFACE_B };
    for (unsigned format = 4; format < 6; format++)
        for (unsigned mask = 0; mask < 16; mask++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            BOOL swizzle = !!(mask & 2);
            xo_prepare(format, swizzle);
            pg->surface_scale_factor = mask & 4 ? 2 : 1;
            send_method(NV097_SET_COLOR_CLEAR_VALUE, 0xb7553311);
            send_method(NV097_SET_CLEAR_RECT_HORIZONTAL, 7 << 16);
            send_method(NV097_SET_CLEAR_RECT_VERTICAL, 7 << 16);
            unsigned parameter = 0;
            for (unsigned c = 0; c < 4; c++)
                if (mask & (1u << c))
                    parameter |= flags[c];
            send_method(NV097_CLEAR_SURFACE, parameter);
            a7_validate(format, mask, 4, swizzle);
        }
    groups++;
}
static void xo_surface_dither(void)
{
    const unsigned ranks[] = { 0, 8,  2, 10, 12, 4, 14, 6,
                               3, 11, 1, 9,  15, 7, 13, 5 };
    for (unsigned format = 0; format < 4; format++) {
        fixture();
        BOOL swizzle = !!(format & 1);
        xo_prepare(format, swizzle);
        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                    (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0x80336699);
        send_method(NV097_SET_DITHER_ENABLE, 1);
        begin(PRIM_TYPE_TRIANGLES);
        send_method(NV097_SET_DITHER_ENABLE, 0);
        arrays(0, 3);
        end();
        NSError *error = nil;
        require([surfaces.cache prepareCPUAccessAtAddress:1024
                                                   length:512
                                                    write:NO
                                                    error:&error],
                error);
        unsigned bits = format < 2 ? 5 : 8, maximum = (1u << bits) - 1;
        const unsigned shifts[] = { format < 2 ? 10u : 16u,
                                    format < 2 ? 5u : 8u, 0 };
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                unsigned actual = 0;
                memcpy(&actual,
                       state->vram_ptr +
                           xo_address(x, y, format < 2 ? 2 : 4, swizzle),
                       format < 2 ? 2 : 4);
                if (x + y >= 7) {
                    assert(actual == (format < 2 ? 0xa123 : 0xa5335577));
                    continue;
                }
                assert((actual >> (format < 2 ? 15 : 24)) ==
                       (format & 1 ? format < 2 ? 1 : 255 : 0));
                for (unsigned c = 0; c < 3; c++) {
                    float source = (c + 1) * 51.f / 255 * maximum;
                    float threshold = (ranks[(y & 3) * 4 + (x & 3)] + .5f) / 16;
                    unsigned expected =
                        floorf(source) + (source - floorf(source) >= threshold);
                    assert(((actual >> shifts[c]) & maximum) == expected);
                }
            }
    }
    groups++;
}
static void hilo_snapshot(void)
{
    for (unsigned map = 5; map <= 7; map++)
        for (unsigned operation = 0; operation < 3; operation++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            send_method(NV097_SET_DEPTH_TEST_ENABLE, 1);
            send_method(NV097_SET_DEPTH_MASK, 1);
            send_method(NV097_SET_DEPTH_FUNC, 0x207);
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
            send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                        PS_TEXTUREMODES_PASSTHRU |
                            PS_TEXTUREMODES_DOTPRODUCT << 5 |
                            PS_TEXTUREMODES_DOT_ZW << 10);
            unsigned mapping = map | map << 4;
            send_method(NV097_SET_DOT_RGBMAPPING, mapping);
            pg->vertex_attributes[9].inline_value[0] = 0;
            pg->vertex_attributes[9].inline_value[1] = 64.0f / 255;
            pg->vertex_attributes[9].inline_value[2] = 0;
            pg->vertex_attributes[9].inline_value[3] = 32.0f / 255;
            pg->vertex_attributes[10].inline_value[2] = 1;
            pg->vertex_attributes[11].inline_value[2] = 2;
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_DOT_RGBMAPPING, 0);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
            if (operation == 2)
                send_method(NV097_CLEAR_SURFACE, 0);
            if (operation) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                const uint8_t *pixel = pg->metal4_begin_capture + 48;
                assert((uint32_t)ldl_be_p(pixel + 100 +
                                          offsetof(NV2AMetalPixelUniforms,
                                                   other_stage_input)) ==
                       mapping);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                             length:65536];
                arrays(0, 3);
                end();
                before_ram_load();
                memcpy(state->vram_ptr, ram.bytes, ram.length);
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            arrays(0, 3);
            end();
            assert(color(1, 1) == 0xff0000ff);
            get_report(0);
            process_reports();
            assert(report_result(0) == 28);
            NSError *error = nil;
            require([surfaces.cache prepareCPUAccessAtAddress:4096
                                                       length:128
                                                        write:NO
                                                        error:&error],
                    error);
            uint16_t packed;
            memcpy(&packed, state->vram_ptr + 4096 + (1 * 8 + 1) * 2, 2);
            assert(packed == 0x7fff);
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            assert(color(1, 1) == 0xffffff00);
            require([surfaces.cache prepareCPUAccessAtAddress:4096
                                                       length:128
                                                        write:NO
                                                        error:&error],
                    error);
            memcpy(&packed, state->vram_ptr + 4096 + (1 * 8 + 1) * 2, 2);
            assert(packed == 0xffff);
        }
    groups++;
}
static void hilo16_brdf_begin_snapshot(void)
{
    const uint32_t pairs[][2] = { { 0x30001000, 0xd0007000 },
                                  { 0x1289e237, 0xabe36519 },
                                  { 0x0102ff00, 0xfefd00ff },
                                  { 0x80800101, 0x7f7ffefe } };
    unsigned cases = 0, restores = 0, pendingRestores = 0, pixels = 0,
             rejections = 0;
    for (unsigned pair = 0; pair < ARRAY_SIZE(pairs); pair++)
        for (unsigned reverse = 0; reverse < 2; reverse++)
            for (unsigned linear = 0; linear < 2; linear++)
                for (unsigned stage = 2; stage <= 3; stage++)
                    for (unsigned operation = 0; operation < 4; operation++) {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        uint32_t eye = pairs[pair][reverse],
                                 light = pairs[pair][!reverse];
                        dma[4].limit = 4095;
                        uint32_t program = 0;
                        for (unsigned i = stage - 2; i <= stage; i++) {
                            unsigned slot = i * 64;
                            unsigned offset = (i - (stage - 2)) * 1024;
                            bool lookup = i == stage;
                            unsigned formatCode =
                                lookup ?
                                    NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8 :
                                linear ?
                                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 :
                                    NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16;
                            uint32_t format = 0;
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
                            SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
                                     formatCode);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                                     lookup ? 3 : 2);
                            SET_MASK(
                                format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                                NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_CUBEMAP_ENABLE,
                                     !lookup && !linear);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U, 2);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V, 2);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_BASE_SIZE_P,
                                     lookup ? 2 : 0);
                            send_method(NV097_SET_TEXTURE_OFFSET + slot,
                                        offset);
                            send_method(NV097_SET_TEXTURE_FORMAT + slot,
                                        format);
                            send_method(NV097_SET_TEXTURE_CONTROL0 + slot,
                                        NV097_SET_TEXTURE_CONTROL0_ENABLE);
                            send_method(NV097_SET_TEXTURE_CONTROL1 + slot,
                                        32 << 16);
                            send_method(NV097_SET_TEXTURE_IMAGE_RECT + slot,
                                        4 << 16 | 4);
                            send_method(NV097_SET_TEXTURE_FILTER + slot,
                                        1 << 16 | 1 << 24);
                            send_method(NV097_SET_TEXTURE_ADDRESS + slot,
                                        3 | 3 << 8 | (lookup ? 1 : 3) << 16);
                            program |= (lookup ? PS_TEXTUREMODES_BRDF :
                                        linear ? PS_TEXTUREMODES_PROJECT2D :
                                                 PS_TEXTUREMODES_CUBEMAP)
                                       << (5 * i);
                            unsigned length = lookup ? 256 : linear ? 128 : 768;
                            cpu_write(49152 + offset, length);
                            if (lookup) {
                                for (unsigned z = 0; z < 4; z++)
                                    for (unsigned y = 0; y < 4; y++)
                                        for (unsigned x = 0; x < 4; x++) {
                                            unsigned morton =
                                                (x & 1) | (y & 1) << 1 |
                                                (z & 1) << 2 | (x & 2) << 2 |
                                                (y & 2) << 3 | (z & 2) << 4;
                                            stl_le_p(state->vram_ptr + 49152 +
                                                         offset + 4 * morton,
                                                     0xff000000 |
                                                         (17 + 32 * x) << 16 |
                                                         (33 + 32 * y) << 8 |
                                                         (49 + 32 * z));
                                        }
                            } else {
                                for (unsigned j = 0; j < length; j += 4)
                                    stl_le_p(state->vram_ptr + 49152 + offset +
                                                 j,
                                             i == stage - 2 ? eye : light);
                                pg->vertex_attributes[9 + i].inline_value[0] =
                                    linear ? .5f : 1;
                                pg->vertex_attributes[9 + i].inline_value[1] =
                                    .25f;
                                pg->vertex_attributes[9 + i].inline_value[2] =
                                    -.5f;
                            }
                        }
                        send_method(NV097_SET_SHADER_STAGE_PROGRAM, program);
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                    PS_REGISTER_T0 + stage);
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                    (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA)
                                        << 8);
                        begin(PRIM_TYPE_TRIANGLES);
                        if (operation == 1 || operation == 3)
                            arrays(0, 3);
                        if (operation == 1) {
                            qemu_mutex_lock(&pg->lock);
                            renderer.ops.flush_draw(state);
                            qemu_mutex_unlock(&pg->lock);
                        }
                        /* Begin owns the original shader, types and decoded
                         * resources even after current registers/RAM change. */
                        for (unsigned i = stage - 2; i <= stage; i++) {
                            send_method(NV097_SET_TEXTURE_FORMAT + i * 64,
                                        127u << 8);
                            send_method(NV097_SET_TEXTURE_OFFSET + i * 64,
                                        3072);
                        }
                        send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                    (uint32_t)PS_TEXTUREMODES_PASSTHRU
                                        << (5 * stage));
                        cpu_write(49152, 3072);
                        memset(state->vram_ptr + 49152, 0x5b, 3072);
                        if (operation >= 2) {
                            unsigned pending = operation == 3 ? 1 : 0;
                            assert(pg->draw_arrays_length == pending);
                            renderer.ops.pre_savevm_trigger(state);
                            process_pending();
                            renderer.ops.pre_savevm_wait(state);
                            assert(pg->draw_arrays_length == pending);
                            assert(pgraph_metal4_validate_begin_capture(
                                pg->metal4_begin_capture,
                                pg->metal4_begin_capture_size));
                            const uint8_t *pixel =
                                pg->metal4_begin_capture + 48;
                            assert(ldl_be_p(pixel + 4) == 6 &&
                                   ldl_be_p(pixel + 8) == 333);
                            assert((uint32_t)ldl_be_p(
                                       pixel + 100 +
                                       offsetof(NV2AMetalPixelUniforms,
                                                hilo16_mask)) ==
                                   (3u << (stage - 2)));
                            assert(
                                (uint32_t)ldl_be_p(
                                    pixel + 100 +
                                    offsetof(NV2AMetalPixelUniforms,
                                             combiner.shader_stage_program)) ==
                                program);
                            unsigned textureStart =
                                48 + (uint32_t)ldl_be_p(
                                         pg->metal4_begin_capture + 40);
                            const uint8_t *textures =
                                pg->metal4_begin_capture + textureStart;
                            assert(ldl_be_p(textures + 4) == 3 &&
                                   (uint32_t)ldl_be_p(textures + 8) ==
                                       (7u << (stage - 2)));
                            assert((ldl_be_p(textures + 12 + 8) & 8) != 0);
                            const unsigned offsets[] = {
                                48 + 100 +
                                    offsetof(NV2AMetalPixelUniforms,
                                             hilo16_mask),
                                textureStart + 12 + 8
                            };
                            for (unsigned i = 0; i < ARRAY_SIZE(offsets); i++) {
                                NSMutableData *bad = [NSMutableData
                                    dataWithBytes:pg->metal4_begin_capture
                                           length:pg->
                                                  metal4_begin_capture_size];
                                uint8_t *bytes = bad.mutableBytes;
                                uint32_t flag = i ? 8 : 1u << (stage - 2);
                                stl_be_p(bytes + offsets[i],
                                         ldl_be_p(bytes + offsets[i]) ^ flag);
                                assert(!pgraph_metal4_validate_begin_capture(
                                    bad.bytes, bad.length));
                                rejections++;
                            }
                            int fd = new_vertex_snapshot_file();
                            save_snapshot_parent(fd, &array_snapshot_parent);
                            NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                         length:65536];
                            if (!pending)
                                arrays(0, 3);
                            end();
                            before_ram_load();
                            memcpy(state->vram_ptr, ram.bytes, ram.length);
                            assert(load_snapshot_parent(
                                       fd, &array_snapshot_parent) == 0);
                            assert(pg->draw_arrays_length == pending);
                            after_ram_load();
                            assert(pg->draw_arrays_length == pending);
                            close(fd);
                            restores++;
                            pendingRestores += pending;
                        }
                        if (operation != 3)
                            arrays(0, 3);
                        end();
                        assert(pg->regs_[NV_PGRAPH_SHADERPROG] ==
                               (uint32_t)PS_TEXTUREMODES_PASSTHRU
                                   << (5 * stage));
                        unsigned x = MIN(3u, (unsigned)floor((eye >> 16) /
                                                             65535.0 * 4)),
                                 y = MIN(3u, (unsigned)floor((light >> 16) /
                                                             65535.0 * 4));
                        int z = (int)floor(
                            ((int)(light & 65535) - (int)(eye & 65535)) /
                            65535.0 * 4);
                        z = (z % 4 + 4) % 4;
                        uint32_t expected = 0xff000000 | (17 + 32 * x) << 16 |
                                            (33 + 32 * y) << 8 | (49 + 32 * z);
                        for (unsigned py = 0; py < 8; py++)
                            for (unsigned px = 0; px < 8; px++) {
                                assert(color(px, py) ==
                                       (px + py < 7 ? expected : 0xffff0000));
                                pixels++;
                            }
                        cases++;
                    }
    assert(cases == 128 && restores == 64 && pendingRestores == 32 &&
           pixels == 8192 && rejections == 128);
    printf(
        "Metal4 HILO16 BRDF dispatcher: %u cases/%u partial-Begin "
        "restores/%u pending-array restores/%u exact pixels/%u type-mismatch "
        "rejections PASS\n",
        cases, restores, pendingRestores, pixels, rejections);
    groups++;
}
static unsigned border_begin_morton(unsigned x, unsigned y, unsigned z,
                                    const unsigned size[3])
{
    const unsigned c[] = { x, y, z };
    unsigned address = 0, position = 0;
    for (unsigned bit = 0; (1u << bit) < MAX(size[0], MAX(size[1], size[2]));
         bit++)
        for (unsigned axis = 0; axis < 3; axis++)
            if ((1u << bit) < size[axis])
                address |= ((c[axis] >> bit) & 1) << position++;
    return address;
}
static uint32_t border_begin_word(unsigned x, unsigned y, unsigned z,
                                  unsigned face, unsigned level)
{
    unsigned hi =
        48 * ((x + 2 * y + 3 * z + 5 * face + 7 * level) % 4) + 8 * face;
    unsigned lo = 48 * ((3 * x + y + 2 * z + face + 3 * level) % 4) +
                  8 * ((3 * face) % 6);
    // Low bits avoid ambiguous half-byte output rounding after interpolation.
    return (hi * 257 + 3) << 16 | (lo * 257 + 7);
}
static uint32_t border_begin_reference(const double center[3],
                                       const unsigned physical[3],
                                       unsigned first, unsigned face,
                                       bool volume, bool linear)
{
    unsigned size[3];
    int base[3];
    double fraction[3], result[2] = {};
    for (unsigned axis = 0; axis < 3; axis++) {
        size[axis] = MAX(1u, physical[axis] >> first);
        double position =
            center[axis] * size[axis] / physical[axis] - (linear ? .5 : 0);
        base[axis] = floor(position);
        fraction[axis] = position - base[axis];
    }
    for (unsigned corner = 0; corner < (linear ? (volume ? 8u : 4u) : 1u);
         corner++) {
        unsigned c[3];
        double weight = 1;
        for (unsigned axis = 0; axis < 3; axis++) {
            unsigned high = (corner >> axis) & 1;
            c[axis] = MAX(0, MIN((int)size[axis] - 1, base[axis] + (int)high));
            if (linear && (volume || axis < 2))
                weight *= high ? fraction[axis] : 1 - fraction[axis];
        }
        uint32_t word = border_begin_word(c[0], c[1], c[2], face, first);
        result[0] += weight * (word >> 16) / 257.0;
        result[1] += weight * (word & 65535) / 257.0;
    }
    unsigned hi = lround(result[0]), lo = lround(result[1]);
    assert(hi <= 192 && lo <= 192);
    return 0xff000000 | hi << 16 | lo << 8 | lo;
}
static void physical_border_begin_snapshot(void)
{
    // Cube flag, dimensionality, then logical log2 axes.
    const unsigned shapes[][5] = { { 1, 2, 0, 0, 0 }, { 1, 2, 4, 4, 0 },
                                   { 0, 2, 0, 5, 0 }, { 0, 2, 5, 0, 0 },
                                   { 0, 3, 0, 1, 4 }, { 0, 3, 4, 0, 1 },
                                   { 0, 3, 0, 0, 0 } };
    unsigned cases = 0, restores = 0, pendingRestores = 0, pixels = 0;
    unsigned rejections = 0, nextBegins = 0, faces = 0;
    for (unsigned shape = 0; shape < ARRAY_SIZE(shapes); shape++)
        for (unsigned range = 0; range < 3; range++)
            for (unsigned face = 0; face < (shapes[shape][0] ? 6u : 1u); face++)
                for (unsigned slot = 0; slot < 2; slot++)
                    for (unsigned side = 0; side < 2; side++)
                        for (unsigned linear = 0; linear < 2; linear++)
                            for (unsigned operation = 0; operation < 4;
                                 operation++) {
                                unsigned log = MAX(
                                    shapes[shape][2],
                                    MAX(shapes[shape][3], shapes[shape][4]));
                                if (!log && range)
                                    continue;
                                fixture();
                                PGRAPHState *pg = &state->pgraph;
                                bool cube = shapes[shape][0],
                                     volume = shapes[shape][1] == 3;
                                unsigned stage = slot ? 3 : 0,
                                         methodSlot = stage * 64;
                                unsigned core[] = { 1u << shapes[shape][2],
                                                    1u << shapes[shape][3],
                                                    1u << shapes[shape][4] };
                                unsigned physical[] = {
                                    MAX(16u, 2 * core[0]),
                                    MAX(16u, 2 * core[1]),
                                    volume ? MAX(16u, 2 * core[2]) : 1
                                };
                                unsigned first = range == 0 ? 0 :
                                                 range == 1 ? 1 :
                                                              log;
                                unsigned faceLength = 0;
                                for (unsigned level = 0; level <= log; level++)
                                    faceLength +=
                                        4 * MAX(1u, physical[0] >> level) *
                                        MAX(1u, physical[1] >> level) *
                                        MAX(1u, physical[2] >> level);
                                unsigned stride =
                                    cube ? (faceLength + 127) & ~127u :
                                           faceLength;
                                unsigned length = stride * (cube ? 6 : 1);
                                // Vertex DMA occupies 16384; keep full physical
                                // resources separate.
                                unsigned source = 24576;
                                assert(source + length < 65536);
                                dma[4].address = source;
                                dma[4].limit = length - 1;
                                cpu_write(source, length);
                                memset(state->vram_ptr + source, 0xd3, length);
                                for (unsigned image = 0;
                                     image < (cube ? 6u : 1u); image++) {
                                    unsigned offset = source + image * stride;
                                    for (unsigned level = 0; level <= log;
                                         level++) {
                                        unsigned size[] = {
                                            MAX(1u, physical[0] >> level),
                                            MAX(1u, physical[1] >> level),
                                            MAX(1u, physical[2] >> level)
                                        };
                                        for (unsigned z = 0; z < size[2]; z++)
                                            for (unsigned y = 0; y < size[1];
                                                 y++)
                                                for (unsigned x = 0;
                                                     x < size[0]; x++)
                                                    stl_le_p(
                                                        state->vram_ptr +
                                                            offset +
                                                            4 * border_begin_morton(
                                                                    x, y, z,
                                                                    size),
                                                        border_begin_word(
                                                            x, y, z, image,
                                                            level));
                                        offset +=
                                            4 * size[0] * size[1] * size[2];
                                    }
                                    assert(offset == source + image * stride +
                                                         faceLength);
                                }
                                uint32_t format = 0;
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA,
                                         2);
                                SET_MASK(
                                    format, NV097_SET_TEXTURE_FORMAT_COLOR,
                                    NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16);
                                SET_MASK(
                                    format,
                                    NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                                    shapes[shape][1]);
                                SET_MASK(
                                    format,
                                    NV097_SET_TEXTURE_FORMAT_CUBEMAP_ENABLE,
                                    cube);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS,
                                         log + 1);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U,
                                         shapes[shape][2]);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V,
                                         shapes[shape][3]);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_P,
                                         shapes[shape][4]);
                                uint32_t control =
                                    NV097_SET_TEXTURE_CONTROL0_ENABLE;
                                SET_MASK(
                                    control,
                                    NV097_SET_TEXTURE_CONTROL0_MIN_LOD_CLAMP,
                                    first);
                                SET_MASK(
                                    control,
                                    NV097_SET_TEXTURE_CONTROL0_MAX_LOD_CLAMP,
                                    log);
                                send_method(
                                    NV097_SET_TEXTURE_OFFSET + methodSlot, 0);
                                send_method(NV097_SET_TEXTURE_FORMAT +
                                                methodSlot,
                                            format);
                                send_method(NV097_SET_TEXTURE_CONTROL0 +
                                                methodSlot,
                                            control);
                                send_method(NV097_SET_TEXTURE_FILTER +
                                                methodSlot,
                                            (linear ? 2 : 1) << 16 |
                                                (linear ? 2 : 1) << 24);
                                send_method(NV097_SET_TEXTURE_ADDRESS +
                                                methodSlot,
                                            3 | 3 << 8 | 3 << 16);
                                uint32_t program =
                                    (cube   ? PS_TEXTUREMODES_CUBEMAP :
                                     volume ? PS_TEXTUREMODES_PROJECT3D :
                                              PS_TEXTUREMODES_PROJECT2D)
                                    << (5 * stage);
                                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                            PS_REGISTER_T0 + stage);
                                send_method(
                                    NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                    (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA)
                                        << 8);
                                double center[3];
                                for (unsigned axis = 0; axis < 3; axis++)
                                    center[axis] =
                                        linear || cube ?
                                            (side ? 4 + core[axis] - .125 :
                                                    4.125) :
                                            (side ? 4 + core[axis] + .5 : 3.5);
                                if (!volume)
                                    center[2] = .5;
                                float *tc = pg->vertex_attributes[9 + stage]
                                                .inline_value;
                                if (cube) {
                                    double u =
                                        2 * (center[0] - 4) / core[0] - 1;
                                    double v =
                                        2 * (center[1] - 4) / core[1] - 1;
                                    const double direction[][3] = {
                                        { 1, -v, -u }, { -1, -v, u },
                                        { u, 1, v },   { u, -1, -v },
                                        { u, -v, 1 },  { -u, -v, -1 }
                                    };
                                    for (unsigned axis = 0; axis < 3; axis++)
                                        tc[axis] = direction[face][axis];
                                    faces |= 1u << face;
                                } else {
                                    for (unsigned axis = 0; axis < 3; axis++)
                                        tc[axis] = volume || axis < 2 ?
                                                       (center[axis] - 4) /
                                                           core[axis] :
                                                       0;
                                }
                                uint32_t expected = border_begin_reference(
                                    center, physical, first, face, volume,
                                    linear);
                                begin(PRIM_TYPE_TRIANGLES);
                                if (operation == 1 || operation == 3)
                                    arrays(0, 3);
                                if (operation == 1) {
                                    qemu_mutex_lock(&pg->lock);
                                    renderer.ops.flush_draw(state);
                                    qemu_mutex_unlock(&pg->lock);
                                }
                                send_method(NV097_SET_TEXTURE_FORMAT +
                                                methodSlot,
                                            127u << 8);
                                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                            (uint32_t)PS_TEXTUREMODES_PASSTHRU
                                                << (5 * stage));
                                cpu_write(source, length);
                                memset(state->vram_ptr + source, 0xe3, length);
                                if (operation >= 2) {
                                    unsigned pending = operation == 3 ? 1 : 0;
                                    assert(pg->draw_arrays_length == pending);
                                    renderer.ops.pre_savevm_trigger(state);
                                    process_pending();
                                    renderer.ops.pre_savevm_wait(state);
                                    assert(pg->draw_arrays_length == pending);
                                    assert(pgraph_metal4_validate_begin_capture(
                                        pg->metal4_begin_capture,
                                        pg->metal4_begin_capture_size));
                                    const uint8_t *pixel =
                                        pg->metal4_begin_capture + 48;
                                    assert((uint32_t)ldl_be_p(pixel + 4) == 6 &&
                                           (uint32_t)ldl_be_p(pixel + 8) ==
                                               333);
                                    unsigned textureStart =
                                        48 + (uint32_t)(uint32_t)ldl_be_p(
                                                 pg->metal4_begin_capture + 40);
                                    const uint8_t *record =
                                        pg->metal4_begin_capture +
                                        textureStart + 12;
                                    assert((uint32_t)ldl_be_p(record - 8) ==
                                               3 &&
                                           (uint32_t)ldl_be_p(record - 4) ==
                                               (1u << stage));
                                    assert(
                                        (uint32_t)ldl_be_p(record) == stage &&
                                        ((uint32_t)ldl_be_p(record + 8) & 8));
                                    const uint8_t *image = record + 220;
                                    assert((uint32_t)ldl_be_p(image + 8) ==
                                           (cube   ? 3u :
                                            volume ? 2u :
                                                     1u));
                                    for (unsigned axis = 0; axis < 3; axis++) {
                                        assert(
                                            (uint32_t)ldl_be_p(image + 12 +
                                                               4 * axis) ==
                                            MAX(1u, physical[axis] >> first));
                                        float logical = core[axis];
                                        unsigned o =
                                            48 + 100 +
                                            offsetof(NV2AMetalPixelUniforms,
                                                     textures) +
                                            stage *
                                                sizeof(NV2AMetalTextureStage) +
                                            offsetof(NV2AMetalTextureStage,
                                                     border_logical_size) +
                                            axis * 4;
                                        uint32_t bits;
                                        memcpy(&bits, &logical, 4);
                                        assert((uint32_t)ldl_be_p(
                                                   pg->metal4_begin_capture +
                                                   o) == bits);
                                    }
                                    assert((uint32_t)ldl_be_p(image + 24) ==
                                           log - first + 1);
                                    const unsigned offsets[] = {
                                        48 + 100 +
                                            offsetof(NV2AMetalPixelUniforms,
                                                     textures) +
                                            stage *
                                                sizeof(NV2AMetalTextureStage) +
                                            offsetof(NV2AMetalTextureStage,
                                                     border_logical_size),
                                        textureStart + 12 + 16 +
                                            offsetof(NV2AMetalTextureStage,
                                                     border_inv_real_size) +
                                            4
                                    };
                                    for (unsigned i = 0;
                                         i < ARRAY_SIZE(offsets); i++) {
                                        NSMutableData *bad = [NSMutableData
                                            dataWithBytes:
                                                pg->metal4_begin_capture
                                                   length:
                                                       pg->
                                                       metal4_begin_capture_size];
                                        uint8_t *bytes = bad.mutableBytes;
                                        stl_be_p(bytes + offsets[i],
                                                 (uint32_t)ldl_be_p(
                                                     bytes + offsets[i]) ^
                                                     1);
                                        assert(
                                            !pgraph_metal4_validate_begin_capture(
                                                bad.bytes, bad.length));
                                        rejections++;
                                    }
                                    int fd = new_vertex_snapshot_file();
                                    save_snapshot_parent(
                                        fd, &array_snapshot_parent);
                                    NSData *ram =
                                        [NSData dataWithBytes:state->vram_ptr
                                                       length:65536];
                                    if (!pending)
                                        arrays(0, 3);
                                    end();
                                    before_ram_load();
                                    memcpy(state->vram_ptr, ram.bytes,
                                           ram.length);
                                    assert(load_snapshot_parent(
                                               fd, &array_snapshot_parent) ==
                                           0);
                                    assert(pg->draw_arrays_length == pending);
                                    after_ram_load();
                                    assert(pg->draw_arrays_length == pending);
                                    close(fd);
                                    restores++;
                                    pendingRestores += pending;
                                }
                                if (operation != 3)
                                    arrays(0, 3);
                                end();
                                for (unsigned phase = 0; phase < 2; phase++) {
                                    for (unsigned y = 0; y < 8; y++)
                                        for (unsigned x = 0; x < 8; x++) {
                                            uint32_t want =
                                                x + y < 7 ?
                                                    (phase ? 0xffe3e3e3 :
                                                             expected) :
                                                    0xffff0000;
                                            uint32_t actual = color(x, y);
                                            if (actual != want) {
                                                fprintf(
                                                    stderr,
                                                    "Border Begin shape%u "
                                                    "view%u face%u stage%u "
                                                    "side%u lin%u op%u phase%u "
                                                    "pixel%u,%u:%08x "
                                                    "expected%08x\n",
                                                    shape, range, face, stage,
                                                    side, linear, operation,
                                                    phase, x, y, actual, want);
                                                abort();
                                            }
                                            pixels++;
                                        }
                                    if (!phase) {
                                        cpu_write(1024, 256);
                                        for (unsigned i = 0; i < 64; i++)
                                            stl_le_p(state->vram_ptr + 1024 +
                                                         4 * i,
                                                     0xffff0000);
                                        send_method(NV097_SET_TEXTURE_FORMAT +
                                                        methodSlot,
                                                    format);
                                        send_method(
                                            NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                        begin(PRIM_TYPE_TRIANGLES);
                                        arrays(0, 3);
                                        end();
                                        nextBegins++;
                                    }
                                }
                                cases++;
                            }
    assert(cases == 1184 && restores == 592 && pendingRestores == 296 &&
           pixels == 151552 && rejections == 1184 && nextBegins == 1184 &&
           faces == 63);
    printf("Metal4 physical border dispatcher: %u cases/%u partial-Begin "
           "restores/%u pending-array restores/%u exact raw pixels/%u "
           "border-mismatch rejects/%u fresh Begins PASS\n",
           cases, restores, pendingRestores, pixels, rejections, nextBegins);
    groups++;
}

static uint32_t convolution_begin_word(unsigned x, unsigned y, unsigned level,
                                       unsigned phase, BOOL signedHILO)
{
    if (signedHILO) {
        int hi = 8195 + 509 * ((x + 3 * y + 5 * level + 7 * phase) % 16);
        if ((x + 3 * y + level + phase) & 1)
            hi = -hi;
        unsigned lo = 8203 + phase * 4096 +
                      233 * ((5 * x + 2 * y + 3 * level + 9 * phase) % 16);
        return (unsigned)(hi & 65535) << 16 | lo;
    }
    unsigned hi = 16 + 17 * ((x + 3 * y + 5 * level + 7 * phase) % 12);
    unsigned lo = 32 + 17 * ((5 * x + 2 * y + 3 * level + 9 * phase) % 12);
    return (hi * 257 + 3) << 16 | (lo * 257 + 7);
}
static void convolution_begin_write(const unsigned physical[3], unsigned levels,
                                    bool rectangle, unsigned phase,
                                    BOOL signedHILO)
{
    unsigned length = 0;
    for (unsigned level = 0; level < levels; level++)
        length += rectangle ? physical[1] * 48 :
                              4 * MAX(1u, physical[0] >> level) *
                                  MAX(1u, physical[1] >> level);
    const unsigned source = 24576;
    assert(source + length < 65536);
    dma[4].address = source;
    dma[4].limit = length - 1;
    cpu_write(source, length);
    memset(state->vram_ptr + source, 0xd3, length);
    unsigned offset = 0;
    for (unsigned level = 0; level < levels; level++) {
        unsigned size[] = { MAX(1u, physical[0] >> level),
                            MAX(1u, physical[1] >> level), 1 };
        for (unsigned y = 0; y < size[1]; y++)
            for (unsigned x = 0; x < size[0]; x++) {
                unsigned pos =
                    rectangle ? y * 48 + x * 4 :
                                offset + 4 * border_begin_morton(x, y, 0, size);
                stl_le_p(
                    state->vram_ptr + source + pos,
                    convolution_begin_word(x, y, level, phase, signedHILO));
            }
        offset += rectangle ? size[1] * 48 : 4 * size[0] * size[1];
    }
    assert(offset == length);
}
static uint32_t convolution_begin_reference(const unsigned core[2],
                                            const unsigned physical[3],
                                            unsigned first, bool border,
                                            bool linear, const double uvq[3],
                                            unsigned phase, BOOL signedHILO)
{
    unsigned size[] = { MAX(1u, physical[0] >> first),
                        MAX(1u, physical[1] >> first) };
    double center[2] = { uvq[0], uvq[1] }, result[2] = {};
    if (border)
        for (unsigned axis = 0; axis < 2; axis++)
            center[axis] = (center[axis] * core[axis] + 4) / physical[axis];
    // Independent CPU point/bilinear sampling with Pascal tap weights. Both
    // selectors currently use GL's Gaussian approximation, including Quincunx.
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            double sx = (center[0] * size[0] + x) / uvq[2] - (linear ? .5 : 0),
                   sy = (center[1] * size[1] + y) / uvq[2] - (linear ? .5 : 0);
            int bx = floor(sx), by = floor(sy);
            double fx = sx - bx, fy = sy - by;
            for (unsigned corner = 0; corner < (linear ? 4u : 1u); corner++) {
                unsigned hx = corner & 1, hy = corner >> 1;
                unsigned cx = MAX(0, MIN((int)size[0] - 1, bx + (int)hx)),
                         cy = MAX(0, MIN((int)size[1] - 1, by + (int)hy));
                double weight = (x == 0 ? 2 : 1) * (y == 0 ? 2 : 1) / 16.0;
                if (linear)
                    weight *= (hx ? fx : 1 - fx) * (hy ? fy : 1 - fy);
                uint32_t word =
                    convolution_begin_word(cx, cy, first, phase, signedHILO);
                for (unsigned k = 0; k < 2; k++) {
                    int raw = k ? word & 65535 : word >> 16;
                    result[k] +=
                        weight * (signedHILO ?
                                      (raw >= 32768 ? raw - 65536 : raw) *
                                          510.0 / 65535 :
                                      raw / 257.0);
                }
            }
        }
    unsigned bytes[2];
    for (unsigned k = 0; k < 2; k++) {
        if (signedHILO)
            result[k] = MAX(0.0, MIN(255.0, result[k]));
        // Low source bits keep every selected profile away from rounding ties.
        assert(fabs(result[k] - floor(result[k]) - .5) > .0005);
        bytes[k] = lround(result[k]);
        assert(bytes[k] <= 255);
    }
    return 0xff000000 | bytes[0] << 16 | bytes[1] << 8 | bytes[1];
}
static void convolution_begin_texcoord(unsigned stage, const float tc[4])
{
    uint32_t words[4];
    memcpy(words, tc, sizeof(words));
    assert(method(NV097_SET_VERTEX_DATA4F_M + (9 + stage) * 16, words[0], words,
                  4, 0, true) == 4);
}
static void convolution_begin_snapshot(BOOL signedHILO)
{
    const struct {
        unsigned width, height;
        bool rectangle, border;
    } shapes[] = { { 8, 8, false, false }, { 8, 4, true, false },
                   { 2, 2, false, true },  { 16, 16, false, true },
                   { 1, 16, false, true }, { 16, 1, false, true } };
    const double positions[][3] = { { .375, .625, 1 },
                                    { .15625, .84375, .5 },
                                    { .8125, .1875, 2 },
                                    { -.25, 1.25, 1 } };
    unsigned cases = 0, restores = 0, pendingRestores = 0, canonical = 0;
    unsigned pixels = 0, nextBegins = 0, rejections = 0, changedOutputs = 0,
             signedRejections = 0;
    NSError *error = nil;
    for (unsigned shape = 0; shape < ARRAY_SIZE(shapes); shape++) {
        bool rect = shapes[shape].rectangle, border = shapes[shape].border;
        const unsigned core[] = { shapes[shape].width, shapes[shape].height };
        const unsigned physical[] = { border ? MAX(16u, 2 * core[0]) : core[0],
                                      border ? MAX(16u, 2 * core[1]) : core[1],
                                      1 };
        unsigned levels = rect ? 1 : ctz32(MAX(core[0], core[1])) + 1;
        for (unsigned first = 0; first < (rect ? 1u : 2u); first++)
            for (unsigned slot = 0; slot < 2; slot++)
                for (unsigned kernel = 1; kernel <= 2; kernel++)
                    for (unsigned mag = 1; mag <= 2; mag++)
                        for (unsigned profile = 0;
                             profile < ARRAY_SIZE(positions); profile++)
                            for (unsigned operation = 0; operation < 4;
                                 operation++) {
                                fixture();
                                PGRAPHState *pg = &state->pgraph;
                                unsigned stage = slot * 3,
                                         methodSlot = stage * 64;
                                convolution_begin_write(physical, levels, rect,
                                                        0, signedHILO);
                                uint32_t format = 0;
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA,
                                         2);
                                SET_MASK(
                                    format, NV097_SET_TEXTURE_FORMAT_COLOR,
                                    rect ?
                                        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 :
                                        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16);
                                SET_MASK(
                                    format,
                                    NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 2);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                                         !border);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS,
                                         levels);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U,
                                         ctz32(core[0]));
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V,
                                         ctz32(core[1]));
                                uint32_t control =
                                    NV097_SET_TEXTURE_CONTROL0_ENABLE;
                                SET_MASK(
                                    control,
                                    NV097_SET_TEXTURE_CONTROL0_MIN_LOD_CLAMP,
                                    first);
                                SET_MASK(
                                    control,
                                    NV097_SET_TEXTURE_CONTROL0_MAX_LOD_CLAMP,
                                    levels - 1);
                                unsigned filter =
                                    7 << 16 | mag << 24 | kernel << 13 |
                                    (signedHILO ? 0xf0000000u : 0);
                                send_method(
                                    NV097_SET_TEXTURE_OFFSET + methodSlot, 0);
                                send_method(NV097_SET_TEXTURE_FORMAT +
                                                methodSlot,
                                            format);
                                send_method(NV097_SET_TEXTURE_CONTROL0 +
                                                methodSlot,
                                            control);
                                send_method(NV097_SET_TEXTURE_CONTROL1 +
                                                methodSlot,
                                            48 << 16);
                                send_method(NV097_SET_TEXTURE_IMAGE_RECT +
                                                methodSlot,
                                            core[0] << 16 | core[1]);
                                send_method(NV097_SET_TEXTURE_FILTER +
                                                methodSlot,
                                            filter);
                                send_method(NV097_SET_TEXTURE_ADDRESS +
                                                methodSlot,
                                            3 | 3 << 8 | 3 << 16);
                                unsigned program = PS_TEXTUREMODES_PROJECT2D
                                                   << (5 * stage);
                                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                            PS_REGISTER_T0 + stage);
                                send_method(
                                    NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                    (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA)
                                        << 8);
                                const float tc[] = { positions[profile][0] *
                                                         (rect ? core[0] : 1),
                                                     positions[profile][1] *
                                                         (rect ? core[1] : 1),
                                                     0, positions[profile][2] };
                                convolution_begin_texcoord(stage, tc);
                                begin(PRIM_TYPE_TRIANGLES);
                                unsigned pending = operation & 1;
                                if (pending)
                                    arrays(0, 3);
                                if (operation == 1) {
                                    qemu_mutex_lock(&pg->lock);
                                    renderer.ops.flush_draw(state);
                                    qemu_mutex_unlock(&pg->lock);
                                }
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                                assert(pg->draw_arrays_length == pending);
                                NSData *frozen = [NSData
                                    dataWithBytes:pg->metal4_begin_capture
                                           length:pg->
                                                  metal4_begin_capture_size];
                                assert(pgraph_metal4_validate_begin_capture(
                                    frozen.bytes, frozen.length));
                                const uint8_t *bytes = frozen.bytes;
                                unsigned textureStart =
                                    48 + (uint32_t)ldl_be_p(bytes + 40);
                                unsigned pixelStage =
                                    48 + 100 +
                                    offsetof(NV2AMetalPixelUniforms, textures) +
                                    stage * sizeof(NV2AMetalTextureStage);
                                unsigned recordStage = textureStart + 12 + 16;
                                unsigned conv = offsetof(NV2AMetalTextureStage,
                                                         convolution);
                                assert((uint32_t)ldl_be_p(bytes + 4) == 3 &&
                                       (uint32_t)ldl_be_p(bytes + 48 + 4) ==
                                           6 &&
                                       (uint32_t)ldl_be_p(bytes + textureStart +
                                                          4) == 3 &&
                                       (uint32_t)ldl_be_p(bytes + pixelStage +
                                                          conv) == kernel &&
                                       (uint32_t)ldl_be_p(bytes + recordStage +
                                                          conv) == kernel);
                                unsigned sign = offsetof(NV2AMetalTextureStage,
                                                         signed_channels);
                                assert((uint32_t)ldl_be_p(bytes + pixelStage +
                                                          sign) ==
                                           (signedHILO ? 15u : 0u) &&
                                       (uint32_t)ldl_be_p(bytes + recordStage +
                                                          sign) ==
                                           (signedHILO ? 15u : 0u) &&
                                       (uint32_t)ldl_be_p(
                                           bytes + 48 + 100 +
                                           offsetof(NV2AMetalPixelUniforms,
                                                    hilo16_mask)) ==
                                           (1u << stage));
                                if (signedHILO)
                                    for (unsigned part = 0; part < 2; part++) {
                                        NSMutableData *bad =
                                            [frozen mutableCopy];
                                        stl_be_p((uint8_t *)bad.mutableBytes +
                                                     (part ? recordStage :
                                                             pixelStage) +
                                                     sign,
                                                 0);
                                        assert(
                                            !pgraph_metal4_validate_begin_capture(
                                                bad.bytes, bad.length));
                                        signedRejections++;
                                    }
                                const uint8_t *image =
                                    bytes + textureStart + 12 + 220;
                                assert((uint32_t)ldl_be_p(image + 12) ==
                                           MAX(1u, physical[0] >> first) &&
                                       (uint32_t)ldl_be_p(image + 16) ==
                                           MAX(1u, physical[1] >> first) &&
                                       (uint32_t)ldl_be_p(image + 24) ==
                                           levels - first);
                                for (unsigned part = 0; part < 2; part++) {
                                    NSMutableData *bad = [frozen mutableCopy];
                                    stl_be_p(
                                        (uint8_t *)bad.mutableBytes +
                                            (part ? recordStage : pixelStage) +
                                            conv,
                                        3 - kernel);
                                    assert(
                                        !pgraph_metal4_validate_begin_capture(
                                            bad.bytes, bad.length));
                                    rejections++;
                                }
                                send_method(NV097_SET_TEXTURE_FORMAT +
                                                methodSlot,
                                            127u << 8);
                                send_method(NV097_SET_TEXTURE_FILTER +
                                                methodSlot,
                                            1 << 16 | 1 << 24);
                                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                            PS_TEXTUREMODES_PASSTHRU
                                                << (5 * stage));
                                convolution_begin_write(physical, levels, rect,
                                                        1, signedHILO);
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                                NSData *again = [NSData
                                    dataWithBytes:pg->metal4_begin_capture
                                           length:pg->
                                                  metal4_begin_capture_size];
                                assert([again isEqualToData:frozen]);
                                canonical++;
                                if (operation >= 2) {
                                    int fd = new_vertex_snapshot_file();
                                    save_snapshot_parent(
                                        fd, &array_snapshot_parent);
                                    NSData *ram =
                                        [NSData dataWithBytes:state->vram_ptr
                                                       length:65536];
                                    for (unsigned pass = 0;
                                         pass < operation - 1; pass++) {
                                        if (!pending)
                                            arrays(0, 3);
                                        end();
                                        before_ram_load();
                                        memcpy(state->vram_ptr, ram.bytes,
                                               ram.length);
                                        assert(
                                            load_snapshot_parent(
                                                fd, &array_snapshot_parent) ==
                                            0);
                                        after_ram_load();
                                        assert(pg->draw_arrays_length ==
                                               pending);
                                        // Materialize the lazy restored Begin
                                        // before the byte comparison.
                                        qemu_mutex_lock(&pg->lock);
                                        renderer.ops.flush_draw(state);
                                        qemu_mutex_unlock(&pg->lock);
                                        assert(pg->draw_arrays_length ==
                                               pending);
                                        close(fd);
                                        restores++;
                                        pendingRestores += pending;
                                        renderer.ops.pre_savevm_trigger(state);
                                        process_pending();
                                        renderer.ops.pre_savevm_wait(state);
                                        again = [NSData
                                            dataWithBytes:
                                                pg->metal4_begin_capture
                                                   length:
                                                       pg->
                                                       metal4_begin_capture_size];
                                        assert([again isEqualToData:frozen]);
                                        canonical++;
                                        if (pass + 1 < operation - 1) {
                                            fd = new_vertex_snapshot_file();
                                            save_snapshot_parent(
                                                fd, &array_snapshot_parent);
                                            ram = [NSData
                                                dataWithBytes:state->vram_ptr
                                                       length:65536];
                                        }
                                    }
                                }
                                // Scratch draws during capture must not hide a
                                // missing final End draw.
                                cpu_write(1024, 256);
                                for (unsigned i = 0; i < 64; i++)
                                    stl_le_p(state->vram_ptr + 1024 + 4 * i,
                                             0xffff0000);
                                if (!pending)
                                    arrays(0, 3);
                                end();
                                uint32_t expected[3];
                                NSData *previous = frozen;
                                for (unsigned phase = 0; phase < 3; phase++) {
                                    expected[phase] =
                                        convolution_begin_reference(
                                            core, physical, first, border,
                                            mag == 2, positions[profile], phase,
                                            signedHILO);
                                    for (unsigned y = 0; y < 8; y++)
                                        for (unsigned x = 0; x < 8; x++) {
                                            uint32_t want =
                                                x + y < 7 ? expected[phase] :
                                                            0xffff0000;
                                            uint32_t actual = color(x, y);
                                            if (actual != want) {
                                                fprintf(
                                                    stderr,
                                                    "Convolution Begin shape%u "
                                                    "first%u stage%u kernel%u "
                                                    "mag%u profile%u op%u "
                                                    "phase%u pixel%u,%u:%08x "
                                                    "expected%08x\n",
                                                    shape, first, stage, kernel,
                                                    mag, profile, operation,
                                                    phase, x, y, actual, want);
                                                abort();
                                            }
                                            pixels++;
                                        }
                                    if (phase < 2) {
                                        if (phase == 1)
                                            convolution_begin_write(
                                                physical, levels, rect, 2,
                                                signedHILO);
                                        cpu_write(1024, 256);
                                        for (unsigned i = 0; i < 64; i++)
                                            stl_le_p(state->vram_ptr + 1024 +
                                                         4 * i,
                                                     0xffff0000);
                                        send_method(NV097_SET_TEXTURE_FORMAT +
                                                        methodSlot,
                                                    format);
                                        send_method(NV097_SET_TEXTURE_FILTER +
                                                        methodSlot,
                                                    filter);
                                        send_method(
                                            NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                        convolution_begin_texcoord(stage, tc);
                                        begin(PRIM_TYPE_TRIANGLES);
                                        require([surfaces.cache
                                                    submitWithError:&error] &&
                                                    [surfaces.cache
                                                        waitUntilIdleWithError:
                                                            &error],
                                                error);
                                        NSData *fresh = [draw
                                            beginSnapshotWithError:&error];
                                        require(fresh != nil, error);
                                        assert(![fresh isEqualToData:previous]);
                                        previous = fresh;
                                        arrays(0, 3);
                                        end();
                                        nextBegins++;
                                    }
                                }
                                changedOutputs += (expected[0] != expected[1]) +
                                                  (expected[1] != expected[2]);
                                cases++;
                            }
    }
    assert(cases == 1408 && restores == 1056 && pendingRestores == 704 &&
           canonical == 2464 && pixels == 270336 && nextBegins == 2816 &&
           rejections == 2816 && changedOutputs == 2816);
    if (signedHILO)
        assert(signedRejections == 2816);
    printf("Metal4 %sHILO16 convolution Begin: %u cases/%u partial restores/%u "
           "pending-array restores/%u exact canonical resaves/%u exact raw "
           "pixels/%u fresh Begins/%u kernel mismatch rejects/%u changed "
           "outputs PASS\n",
           signedHILO ? "signed " : "", cases, restores, pendingRestores,
           canonical, pixels, nextBegins, rejections, changedOutputs);
    if (signedHILO)
        printf("Metal4 signed HILO16 Begin: 2816 signed-metadata mismatch "
               "rejections PASS\n");
    groups++;
}

static uint32_t af_begin_word(unsigned x, unsigned y, unsigned z,
                              unsigned level, unsigned phase, BOOL signedHILO)
{
    return convolution_begin_word(x + 7 * z, y + 5 * z, level, phase,
                                  signedHILO);
}
static void af_begin_write(const unsigned physical[3], unsigned levels,
                           bool rectangle, unsigned phase, BOOL signedHILO)
{
    if (physical[2] == 1) {
        convolution_begin_write(physical, levels, rectangle, phase, signedHILO);
        return;
    }
    const unsigned source = 24576;
    unsigned length = 0;
    for (unsigned level = 0; level < levels; level++)
        length += 4 * MAX(1u, physical[0] >> level) *
                  MAX(1u, physical[1] >> level) * MAX(1u, physical[2] >> level);
    assert(source + length < 49152);
    dma[4].address = source;
    dma[4].limit = length - 1;
    cpu_write(source, length);
    unsigned offset = 0;
    for (unsigned level = 0; level < levels; level++) {
        unsigned size[] = { MAX(1u, physical[0] >> level),
                            MAX(1u, physical[1] >> level),
                            MAX(1u, physical[2] >> level) };
        for (unsigned z = 0; z < size[2]; z++)
            for (unsigned y = 0; y < size[1]; y++)
                for (unsigned x = 0; x < size[0]; x++)
                    stl_le_p(state->vram_ptr + source + offset +
                                 4 * border_begin_morton(x, y, z, size),
                             af_begin_word(x, y, z, level, phase, signedHILO));
        offset += 4 * size[0] * size[1] * size[2];
    }
    assert(offset == length);
}
static void af_begin_gpu_write_face(NV2AMetalPixelShader *writer,
                                    const unsigned physical[3], unsigned levels,
                                    bool rectangle, unsigned phase,
                                    BOOL signedHILO, unsigned scale,
                                    unsigned source, unsigned face, bool seed,
                                    unsigned *draws, unsigned *pixels)
{
    NSError *error = nil;
    BOOL volume = physical[2] > 1;
    assert(!rectangle || !volume);
    unsigned length = 0;
    for (unsigned level = 0; level < levels; level++)
        length += rectangle ? physical[1] * 48 :
                              4 * MAX(1u, physical[0] >> level) *
                                  MAX(1u, physical[1] >> level) *
                                  MAX(1u, physical[2] >> level);
    assert(source >= 24576 && source + length <= 65536);
    unsigned previousLimit = dma[4].address == 24576 ? dma[4].limit : 0;
    dma[4].address = 24576;
    dma[4].limit = MAX(previousLimit, source - 24576 + length - 1);
    if (seed) {
        cpu_write(source, length);
        memset(state->vram_ptr + source, 0xd3, length);
    }
    unsigned offset = 0;
    for (unsigned level = 0; level < levels; level++) {
        unsigned width = MAX(1u, physical[0] >> level),
                 height = MAX(1u, physical[1] >> level);
        unsigned size[] = { width, height, MAX(1u, physical[2] >> level) };
        uint32_t *words = NULL;
        if (volume) {
            unsigned voxels = size[0] * size[1] * size[2];
            width = 1u << ((ctz32(voxels) + 1) / 2);
            height = voxels / width;
            words = g_new(uint32_t, voxels * 2);
            for (unsigned z = 0; z < size[2]; z++)
                for (unsigned y = 0; y < size[1]; y++)
                    for (unsigned x = 0; x < size[0]; x++) {
                        unsigned index = border_begin_morton(x, y, z, size);
                        assert(index < voxels);
                        for (unsigned subpixel = 0; subpixel < 2; subpixel++)
                            words[2 * index + subpixel] =
                                af_begin_word(x, y, z, level,
                                              phase + subpixel * 3, signedHILO);
                    }
        }
        NV2AMetalSurfaceConfig config = {
            .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            .width = width,
            .height = height,
            .pitch = rectangle ? 48 : 4 * width,
            .scale = scale,
            .color = YES,
            .swizzle = !rectangle && !volume
        };
        NV2AMetalCachedSurface *surface =
            [surfaces.cache prepareSurfaceAtAddress:source + offset
                                             config:&config
                                              frame:1
                                              error:&error];
        require(surface != nil, error);
        unsigned nativeWidth = width * scale, nativeHeight = height * scale;
        unsigned count = nativeWidth * nativeHeight * 6;
        id<MTLBuffer> buffer = [surfaces.cache.commands.device
            newBufferWithLength:count * sizeof(NV2AMetalVertex)
                        options:MTLResourceStorageModeShared];
        assert(buffer);
        NV2AMetalVertex *vertices = buffer.contents;
        memset(vertices, 0, buffer.length);
        const unsigned corners[][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 },
                                        { 1, 0 }, { 1, 1 }, { 0, 1 } };
        for (unsigned y = 0; y < nativeHeight; y++)
            for (unsigned x = 0; x < nativeWidth; x++) {
                unsigned samplePhase =
                    phase + ((x % scale || y % scale) ? 3 : 0);
                uint32_t word =
                    volume ? words[2 * (y / scale * width + x / scale) +
                                   (samplePhase != phase)] :
                             af_begin_word(x / scale, y / scale, face, level,
                                           samplePhase, signedHILO);
                for (unsigned corner = 0; corner < 6; corner++) {
                    NV2AMetalVertex *v =
                        &vertices[(y * nativeWidth + x) * 6 + corner];
                    v->clip[0] =
                        2.f * (x + corners[corner][0]) / nativeWidth - 1;
                    v->clip[1] =
                        1 - 2.f * (y + corners[corner][1]) / nativeHeight;
                    v->clip[2] = .5f;
                    v->clip[3] = 1;
                    const unsigned shifts[] = { 16, 8, 0, 24 };
                    for (unsigned channel = 0; channel < 4; channel++)
                        v->color[0][channel] =
                            ((word >> shifts[channel]) & 255) / 255.f;
                    v->plane[0][2] = v->plane[1][2] = v->plane[2][2] = .5f;
                }
            }
        g_free(words);
        NV2AMetalPixelUniforms uniforms = {};
        uniforms.combiner.final_inputs[0] = PS_REGISTER_V0;
        uniforms.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                            << 8;
        uniforms.surface_scale[0] = uniforms.surface_scale[1] = scale;
        uniforms.smooth_shading = 1;
        uniforms.clip_range[1] = uniforms.clip_range[3] = 65535;
        uniforms.clip_regions[0][2] = nativeWidth;
        uniforms.clip_regions[0][3] = nativeHeight;
        NV2AMetalPixelTexture textures[4] = {};
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = surface.transfer.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        require([writer encodeVertices:buffer
                                 count:count
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&uniforms
                              textures:textures
                                  pass:pass
                          depthStencil:nil
                              commands:surfaces.cache.commands
                                 error:&error],
                error);
        require([surfaces.cache markWritten:surface error:&error], error);
        assert(surface.dirty);
        (*draws)++;
        *pixels += nativeWidth * nativeHeight;
        offset += rectangle ? height * 48 : 4 * width * height;
    }
    assert(offset == length);
    if (seed)
        for (unsigned i = 0; i < length; i++)
            assert(state->vram_ptr[source + i] == 0xd3);
}
static void af_begin_gpu_write_at(NV2AMetalPixelShader *writer,
                                  const unsigned physical[3], unsigned levels,
                                  bool rectangle, unsigned phase,
                                  BOOL signedHILO, unsigned scale,
                                  unsigned source, bool seed, unsigned *draws,
                                  unsigned *pixels)
{
    af_begin_gpu_write_face(writer, physical, levels, rectangle, phase,
                            signedHILO, scale, source, 0, seed, draws, pixels);
}
static void af_begin_gpu_write(NV2AMetalPixelShader *writer,
                               const unsigned physical[3], unsigned levels,
                               bool rectangle, unsigned phase, BOOL signedHILO,
                               unsigned scale, unsigned *draws,
                               unsigned *pixels)
{
    af_begin_gpu_write_at(writer, physical, levels, rectangle, phase,
                          signedHILO, scale, 24576, !phase, draws, pixels);
}
static void af_begin_lookup_at(BOOL volume, unsigned stage, unsigned source)
{
    unsigned length = volume ? 2048 : 256, slot = stage * 64;
    assert(source + length <= 65536);
    dma[3].address = source;
    dma[3].limit = length - 1;
    cpu_write(source, length);
    const unsigned size[] = { 8, 8, volume ? 8u : 1u };
    for (unsigned z = 0; z < size[2]; z++)
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++)
                stl_le_p(state->vram_ptr + source +
                             4 * border_begin_morton(x, y, z, size),
                         0xff000000u | (16 + 32 * x) << 16 |
                             (16 + 32 * y) << 8 | (volume ? 16 + 32 * z : 32));
    uint32_t format = 0;
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 1);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
             NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, volume ? 3 : 2);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE, 1);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U, 3);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V, 3);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_P, volume ? 3 : 0);
    send_method(NV097_SET_TEXTURE_FORMAT + slot, format);
    send_method(NV097_SET_TEXTURE_CONTROL0 + slot,
                NV097_SET_TEXTURE_CONTROL0_ENABLE);
    send_method(NV097_SET_TEXTURE_FILTER + slot, 2 << 16 | 2 << 24);
    send_method(NV097_SET_TEXTURE_ADDRESS + slot, 3 | 3 << 8 | 3 << 16);
}
static void af_begin_lookup(BOOL volume, unsigned stage)
{
    af_begin_lookup_at(volume, stage, 49152);
}
static void af_begin_gradient(const unsigned physical[3], unsigned first,
                              unsigned profile, double g[2][3])
{
    const double major[][2] = { { 0, 4 }, { 2.4, 3.2 } };
    const double minor[][2] = { { .25, 0 }, { -.2, .15 } };
    unsigned screen = profile & 1;
    for (unsigned axis = 0; axis < 3; axis++) {
        unsigned size = MAX(1u, physical[axis] >> first);
        bool volume = physical[2] > 1;
        const double volumeMajor[][3] = { { 0, 0, 4 }, { 0, 2.4, 3.2 } };
        const double volumeMinor[][3] = { { .25, 0, 0 }, { -.2, .15, 0 } };
        g[screen][axis] = (volume   ? volumeMajor[screen][axis] :
                           axis < 2 ? major[screen][axis] :
                                      0) /
                          size;
        g[1 - screen][axis] = (volume   ? volumeMinor[screen][axis] :
                               axis < 2 ? minor[screen][axis] :
                                          0) /
                              size;
    }
}
static void af_begin_coordinate(const double g[2][3], unsigned profile,
                                double x, double y, double c[3])
{
    const double origin[] = { .3671875, .58203125, .4296875 };
    double q = profile >= 2 ? 1 + x * .0625 + y * .03125 : 1;
    assert(q > 0);
    for (unsigned axis = 0; axis < 3; axis++)
        c[axis] = (origin[axis] + x * g[0][axis] + y * g[1][axis]) / q;
}
static void af_begin_vertices(const unsigned core[3],
                              const unsigned physical[3], unsigned first,
                              bool rectangle, bool border, unsigned stage,
                              unsigned profile)
{
    const double origin[] = { .3671875, .58203125, .4296875 };
    const double xy[][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 } };
    double g[2][3];
    af_begin_gradient(physical, first, profile, g);
    float values[3][4] = {};
    for (unsigned vertex = 0; vertex < 3; vertex++) {
        double x = xy[vertex][0] - 2, y = xy[vertex][1] - 2;
        for (unsigned axis = 0; axis < 3; axis++) {
            double numerator = origin[axis] + x * g[0][axis] + y * g[1][axis];
            values[vertex][axis] =
                border    ? (numerator * physical[axis] - 4) / core[axis] :
                rectangle ? numerator * core[axis] :
                            numerator;
        }
        values[vertex][3] = profile >= 2 ? 1 + x * .0625 + y * .03125 : 1;
    }
    unsigned offset = stage == 1 ? 512 : 256;
    cpu_write(16384 + offset, sizeof(values));
    memcpy(state->vram_ptr + 16384 + offset, values, sizeof(values));
    uint32_t format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    SET_MASK(format, NV097_SET_VERTEX_DATA_ARRAY_FORMAT_SIZE, 4);
    SET_MASK(format, NV097_SET_VERTEX_DATA_ARRAY_FORMAT_STRIDE, 16);
    send_method(NV097_SET_VERTEX_DATA_ARRAY_FORMAT + (9 + stage) * 4, format);
    send_method(NV097_SET_VERTEX_DATA_ARRAY_OFFSET + (9 + stage) * 4, offset);
}
static double af_begin_level(const double c[3], const unsigned physical[3],
                             unsigned level, unsigned channel, unsigned phase,
                             BOOL signedHILO)
{
    unsigned size[] = { MAX(1u, physical[0] >> level),
                        MAX(1u, physical[1] >> level),
                        MAX(1u, physical[2] >> level) };
    double position[3], fraction[3];
    int base[3];
    for (unsigned axis = 0; axis < 3; axis++) {
        position[axis] = (c[axis] - floor(c[axis])) * size[axis] - .5;
        base[axis] = floor(position[axis]);
        fraction[axis] = position[axis] - base[axis];
    }
    double result = 0;
    for (unsigned corner = 0; corner < (physical[2] > 1 ? 8u : 4u); corner++) {
        unsigned high[] = { corner & 1, (corner >> 1) & 1, corner >> 2 },
                 coordinate[3];
        double weight = 1;
        for (unsigned axis = 0; axis < 3; axis++) {
            int index = base[axis] + high[axis];
            coordinate[axis] =
                (index % (int)size[axis] + size[axis]) % size[axis];
            if (axis < 2 || physical[2] > 1)
                weight *= high[axis] ? fraction[axis] : 1 - fraction[axis];
        }
        uint32_t word = af_begin_word(coordinate[0], coordinate[1],
                                      coordinate[2], level, phase, signedHILO);
        int raw = channel ? word & 65535 : word >> 16;
        result += weight * (signedHILO ? (raw >= 32768 ? raw - 65536 : raw) *
                                             510.0 / 65535 :
                                         raw / 257.0);
    }
    return result;
}
static void af_begin_reference(const unsigned physical[3], unsigned first,
                               unsigned levels, bool rectangle,
                               unsigned profile, unsigned scale,
                               unsigned requested, unsigned phase,
                               BOOL signedHILO, unsigned mode,
                               BOOL lookupVolume, unsigned px, unsigned py,
                               double result[4], unsigned *tapCount)
{
    double g[2][3], c[3], gradient[2][3], squared[2] = {};
    af_begin_gradient(physical, first, profile, g);
    double x = px + .5 / scale - 2, y = py + .5 / scale - 2;
    af_begin_coordinate(g, profile, x, y, c);
    // The VRAM downloader selects native pixel (guest*scale), not a resolve
    // average. Derivatives use that native pixel's 2x2 quad.
    unsigned native[] = { px * scale, py * scale };
    for (unsigned screen = 0; screen < 2; screen++) {
        double low[3], high[3];
        double qx = screen ? x : ((native[0] & ~1u) + .5) / scale - 2;
        double qy = screen ? ((native[1] & ~1u) + .5) / scale - 2 : y;
        af_begin_coordinate(g, profile, qx, qy, low);
        af_begin_coordinate(g, profile, qx + !screen / (double)scale,
                            qy + screen / (double)scale, high);
        for (unsigned axis = 0; axis < (physical[2] > 1 ? 3u : 2u); axis++) {
            gradient[screen][axis] = high[axis] - low[axis];
            double texels =
                gradient[screen][axis] * MAX(1u, physical[axis] >> first);
            squared[screen] += texels * texels;
        }
    }
    unsigned major = squared[0] > squared[1] ? 0 : 1;
    double longest = sqrt(squared[major]), shortest = sqrt(squared[1 - major]);
    unsigned taps =
        longest > 1 ?
            MIN(requested,
                MAX(1u, (unsigned)ceil(longest / MAX(shortest, 1e-30)))) :
            1;
    *tapCount = taps;
    double lod = log2(MAX(longest / taps, 1e-30)) + .375;
    double level =
        rectangle || lod <= 0 ? 0 : MIN((double)(levels - first - 1), lod);
    unsigned low = floor(level), high = MIN(low + 1, levels - first - 1);
    double blend = level - low;
    result[0] = result[1] = 0;
    for (unsigned tap = 0; tap < taps; tap++) {
        double offset = (tap + 1.0) / (taps + 1.0) - .5;
        double position[] = { c[0] + offset * gradient[major][0],
                              c[1] + offset * gradient[major][1],
                              c[2] + offset * gradient[major][2] };
        for (unsigned channel = 0; channel < 2; channel++) {
            double a = af_begin_level(position, physical, first + low, channel,
                                      phase, signedHILO);
            double b = af_begin_level(position, physical, first + high, channel,
                                      phase, signedHILO);
            result[channel] += (a * (1 - blend) + b * blend) / taps;
        }
    }
    assert(mode <= 2);
    if (mode == 2) {
        /* BRDF consumes raw filtered typed HI/LO before output clamping. */
        double factor = (signedHILO ? 65535.0 / 65536 : 1) / 255;
        result[0] *= factor;
        result[1] *= factor;
        result[2] = 0;
        result[3] = 1;
        return;
    }
    if (mode == 1) {
        double factor = signedHILO ? 65535.0 / 65536 : 1;
        double hi = result[0] / 255 * factor, lo = result[1] / 255 * factor;
        double z = signedHILO ? sqrt(MAX(0.0, 1 - hi * hi - lo * lo)) : 1;
        result[0] = 256 * MAX(.0625, MIN(.9375, .5 * hi + .25 * lo + .125 * z));
        result[1] = 256 * MAX(.0625, MIN(.9375, .25 * hi + .5 * lo + .125 * z));
        result[2] =
            lookupVolume ?
                256 * MAX(.0625, MIN(.9375, .125 * hi + .125 * lo + .5 * z)) :
                32;
    } else {
        for (unsigned channel = 0; channel < 2; channel++)
            result[channel] = MAX(0.0, MIN(255.0, result[channel]));
        result[2] = result[1];
    }
    result[3] = 255;
}

/* Snapshot v1 stores four float lanes. Compact v2 captures retain their
 * explicit storage tag and raw lanes; do not read that tag as a float texel. */
static const uint8_t *af_begin_image_payload(const uint8_t *image,
                                             unsigned *storage)
{
    assert((uint32_t)ldl_be_p(image) == 0x4d345458);
    unsigned version = (uint32_t)ldl_be_p(image + 4);
    assert(version == 1 || version == 2);
    *storage = version == 1 ? NV2AMetalTextureStorageFloat32 :
                              (uint32_t)ldl_be_p(image + 36);
    return image + (version == 1 ? 36 : 40);
}
static void af_begin_check_rgba_texel(const uint8_t **data, unsigned storage,
                                      uint32_t word)
{
    assert(storage == NV2AMetalTextureStorageFloat32 ||
           storage == NV2AMetalTextureStorageUnorm8);
    const unsigned shifts[] = { 16, 8, 0, 24 };
    for (unsigned channel = 0; channel < 4; channel++) {
        unsigned expectedByte = (word >> shifts[channel]) & 255;
        if (channel == 3)
            assert(expectedByte == 255);
        if (storage == NV2AMetalTextureStorageUnorm8) {
            assert(*(*data)++ == expectedByte);
        } else {
            uint32_t bits = (uint32_t)ldl_be_p(*data);
            float actual;
            memcpy(&actual, &bits, sizeof(actual));
            float expected = expectedByte / 255.f;
            assert(isfinite(actual) && fabsf(actual - expected) <= 2e-7f);
            if (channel == 3)
                assert(actual == 1);
            *data += 4;
        }
    }
}

static void af_begin_check_image_capture(const uint8_t *image,
                                         const unsigned physical[3],
                                         unsigned first, unsigned levels,
                                         unsigned phase, BOOL signedHILO,
                                         BOOL cube, unsigned *voxels)
{
    assert((uint32_t)ldl_be_p(image + 8) == (cube ? 3u : 2u));
    unsigned storage;
    const uint8_t *data = af_begin_image_payload(image, &storage);
    assert(storage == NV2AMetalTextureStorageFloat32 ||
           storage == NV2AMetalTextureStorageFloatHILO16);
    unsigned lanes = storage == NV2AMetalTextureStorageFloatHILO16 ? 2 : 4;
    for (unsigned face = 0; face < (cube ? 6u : 1u); face++)
        for (unsigned level = first; level < levels; level++) {
            unsigned size[] = { MAX(1u, physical[0] >> level),
                                MAX(1u, physical[1] >> level),
                                MAX(1u, physical[2] >> level) };
            for (unsigned z = 0; z < size[2]; z++)
                for (unsigned y = 0; y < size[1]; y++)
                    for (unsigned x = 0; x < size[0]; x++) {
                        uint32_t word = af_begin_word(x, y, cube ? face : z,
                                                      level, phase, signedHILO);
                        int hi = word >> 16, lo = word & 65535;
                        if (signedHILO) {
                            hi -= hi >= 32768 ? 65536 : 0;
                            lo -= lo >= 32768 ? 65536 : 0;
                        }
                        float divisor = signedHILO ? 32768.f : 65535.f;
                        const float expected[] = { hi / divisor, lo / divisor,
                                                   lo / divisor, 1 };
                        for (unsigned channel = 0; channel < lanes; channel++) {
                            uint32_t bits = (uint32_t)ldl_be_p(data);
                            float actual;
                            memcpy(&actual, &bits, sizeof(actual));
                            assert(isfinite(actual));
                            if (signedHILO || channel == 3)
                                assert(actual == expected[channel]);
                            else
                                assert(fabsf(actual - expected[channel]) <=
                                       2e-7f);
                            data += 4;
                        }
                        (*voxels)++;
                    }
        }
    assert((uint64_t)(data - af_begin_image_payload(image, &storage)) ==
           ((uint64_t)(uint32_t)ldl_be_p(image + 28) << 32 |
            (uint32_t)ldl_be_p(image + 32)));
}

static void af_begin_check_volume_capture(const uint8_t *image,
                                          const unsigned physical[3],
                                          unsigned first, unsigned levels,
                                          unsigned phase, BOOL signedHILO,
                                          unsigned *voxels)
{
    af_begin_check_image_capture(image, physical, first, levels, phase,
                                 signedHILO, NO, voxels);
}

static void hilo16_af_begin_snapshot(BOOL signedHILO, unsigned kind)
{
    const struct {
        unsigned width, height, depth;
        bool rectangle, border;
    } shapes2D[] = { { 8, 8, 1, false, false },
                     { 8, 4, 1, true, false },
                     { 8, 4, 1, false, true } },
      shapes3D[] = { { 8, 4, 2, false, false },
                     { 2, 4, 8, false, false },
                     { 8, 4, 2, false, true },
                     { 2, 4, 8, false, true } };
    assert(kind < 13);
    BOOL volume = kind == 1 || kind == 2 || kind == 4 || kind >= 10,
         typedDot = kind >= 2 && kind != 6 && kind != 10;
    BOOL dual = kind == 8 || kind == 9, secondSigned = kind == 9;
    BOOL lookupVolume = typedDot && kind >= 4 && !dual && kind != 11;
    BOOL gpuSource = kind >= 6;
    const typeof(shapes2D[0]) *shapes = volume ? shapes3D : shapes2D;
    unsigned shapeCount = volume ? ARRAY_SIZE(shapes3D) : ARRAY_SIZE(shapes2D);
    unsigned cases = 0, restores = 0, pendingRestores = 0, canonical = 0;
    unsigned pixels = 0, nextBegins = 0, rejections = 0, changedOutputs = 0,
             signedRejections = 0;
    unsigned ambiguous = 0, coveredChannels = 0, tapPixels[8] = {};
    unsigned lookupRejections = 0, gpuDraws = 0, gpuPixels = 0,
             capturedVoxels = 0;
    unsigned independentOutputs = 0, secondTapPixels[8] = {};
    NV2AMetalPixelShader *writer = nil;
    id<MTLDevice> writerDevice = nil;
    NSError *error = nil;
    for (unsigned shape = 0; shape < shapeCount; shape++) {
        bool rect = shapes[shape].rectangle, border = shapes[shape].border;
        const unsigned core[] = { shapes[shape].width, shapes[shape].height,
                                  shapes[shape].depth };
        const unsigned physical[] = {
            border ? MAX(16u, 2 * core[0]) : core[0],
            border ? MAX(16u, 2 * core[1]) : core[1],
            volume ? (border ? MAX(16u, 2 * core[2]) : core[2]) : 1
        };
        unsigned levels =
            rect ? 1 : ctz32(MAX(core[0], MAX(core[1], core[2]))) + 1;
        for (unsigned first = 0; first < (rect ? 1u : 2u); first++)
            for (unsigned slot = 0; slot < (typedDot ? 1u : 2u); slot++)
                for (unsigned kernel = 1; kernel <= 2; kernel++)
                    for (unsigned mag = 1; mag <= 2; mag++)
                        for (unsigned profile = 0; profile < 4; profile++)
                            for (unsigned operation = 0; operation < 4;
                                 operation++) {
                                fixture();
                                PGRAPHState *pg = &state->pgraph;
                                pg->surface_scale_factor = mag;
                                g_config.display.quality.surface_scale = mag;
                                unsigned requested = kernel == 1 ? 2 : 8;
                                unsigned stage = slot * 3,
                                         methodSlot = stage * 64;
                                if (gpuSource) {
                                    if (writerDevice !=
                                        surfaces.cache.commands.device) {
                                        writerDevice =
                                            surfaces.cache.commands.device;
                                        writer = [[NV2AMetalPixelShader alloc]
                                            initWithDevice:writerDevice
                                               colorFormat:
                                                   MTLPixelFormatBGRA8Unorm
                                               depthFormat:MTLPixelFormatInvalid
                                               sampleCount:1
                                                     error:&error];
                                        require(writer != nil, error);
                                    }
                                    af_begin_gpu_write(writer, physical, levels,
                                                       rect, 0, signedHILO, mag,
                                                       &gpuDraws, &gpuPixels);
                                } else {
                                    af_begin_write(physical, levels, rect, 0,
                                                   signedHILO);
                                }
                                unsigned secondFirst = rect ? 0 : 1 - first;
                                if (dual)
                                    af_begin_gpu_write_at(
                                        writer, physical, levels, rect, 2,
                                        secondSigned, mag, 32768, true,
                                        &gpuDraws, &gpuPixels);
                                uint32_t format = 0;
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA,
                                         2);
                                SET_MASK(
                                    format, NV097_SET_TEXTURE_FORMAT_COLOR,
                                    rect ?
                                        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 :
                                        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16);
                                SET_MASK(
                                    format,
                                    NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                                    volume ? 3 : 2);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                                         !border);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS,
                                         levels);
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U,
                                         ctz32(core[0]));
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V,
                                         ctz32(core[1]));
                                SET_MASK(format,
                                         NV097_SET_TEXTURE_FORMAT_BASE_SIZE_P,
                                         ctz32(core[2]));
                                uint32_t control =
                                    NV097_SET_TEXTURE_CONTROL0_ENABLE;
                                SET_MASK(
                                    control,
                                    NV097_SET_TEXTURE_CONTROL0_MIN_LOD_CLAMP,
                                    first);
                                SET_MASK(
                                    control,
                                    NV097_SET_TEXTURE_CONTROL0_MAX_LOD_CLAMP,
                                    levels - 1);
                                SET_MASK(control,
                                         NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                         kernel == 1 ? 1 : 3);
                                unsigned filter =
                                    6 << 16 | 2 << 24 | 96 |
                                    (signedHILO ? 0xf0000000u : 0);
                                send_method(
                                    NV097_SET_TEXTURE_OFFSET + methodSlot, 0);
                                send_method(NV097_SET_TEXTURE_FORMAT +
                                                methodSlot,
                                            format);
                                send_method(NV097_SET_TEXTURE_CONTROL0 +
                                                methodSlot,
                                            control);
                                send_method(NV097_SET_TEXTURE_CONTROL1 +
                                                methodSlot,
                                            48 << 16);
                                send_method(NV097_SET_TEXTURE_IMAGE_RECT +
                                                methodSlot,
                                            core[0] << 16 | core[1]);
                                send_method(NV097_SET_TEXTURE_FILTER +
                                                methodSlot,
                                            filter);
                                send_method(NV097_SET_TEXTURE_ADDRESS +
                                                methodSlot,
                                            1 | 1 << 8 | 1 << 16);
                                unsigned program =
                                    (volume ? PS_TEXTUREMODES_PROJECT3D :
                                              PS_TEXTUREMODES_PROJECT2D)
                                    << (5 * stage);
                                if (typedDot) {
                                    af_begin_lookup(lookupVolume,
                                                    dual || lookupVolume ? 3 :
                                                                           2);
                                    if (dual) {
                                        program |=
                                            PS_TEXTUREMODES_PROJECT2D << 5 |
                                            PS_TEXTUREMODES_DOTPRODUCT << 10 |
                                            PS_TEXTUREMODES_DOT_ST << 15;
                                        unsigned secondControl = control;
                                        SET_MASK(
                                            secondControl,
                                            NV097_SET_TEXTURE_CONTROL0_MIN_LOD_CLAMP,
                                            secondFirst);
                                        SET_MASK(
                                            secondControl,
                                            NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                            kernel == 1 ? 3 : 1);
                                        send_method(NV097_SET_TEXTURE_OFFSET +
                                                        64,
                                                    8192);
                                        send_method(NV097_SET_TEXTURE_FORMAT +
                                                        64,
                                                    format);
                                        send_method(NV097_SET_TEXTURE_CONTROL0 +
                                                        64,
                                                    secondControl);
                                        send_method(NV097_SET_TEXTURE_CONTROL1 +
                                                        64,
                                                    48 << 16);
                                        send_method(
                                            NV097_SET_TEXTURE_IMAGE_RECT + 64,
                                            core[0] << 16 | core[1]);
                                        send_method(
                                            NV097_SET_TEXTURE_FILTER + 64,
                                            6 << 16 | 2 << 24 | 96 |
                                                (secondSigned ? 0xf0000000u :
                                                                0));
                                        send_method(NV097_SET_TEXTURE_ADDRESS +
                                                        64,
                                                    1 | 1 << 8 | 1 << 16);
                                    } else
                                        program |=
                                            PS_TEXTUREMODES_DOTPRODUCT << 5 |
                                            (lookupVolume ?
                                                 PS_TEXTUREMODES_DOTPRODUCT
                                                         << 10 |
                                                     PS_TEXTUREMODES_DOT_STR_3D
                                                         << 15 :
                                                 PS_TEXTUREMODES_DOT_ST << 10);
                                    send_method(
                                        NV097_SET_SHADER_OTHER_STAGE_INPUT,
                                        (dual ? 1u << 20 :
                                                PS_DOTMAPPING_HILO_1) |
                                            PS_DOTMAPPING_HILO_1 << 4 |
                                            (dual || lookupVolume ?
                                                 PS_DOTMAPPING_HILO_1 << 8 :
                                                 0));
                                    const float vectors[][4] = {
                                        { .5, .25, .125, 1 },
                                        { .25, .5, .125, 1 },
                                        { .125, .125, .5, 1 }
                                    };
                                    for (unsigned i = 0;
                                         i < (lookupVolume ? 3u : 2u); i++)
                                        memcpy(pg->vertex_attributes
                                                   [(dual ? 11 : 10) + i]
                                                       .inline_value,
                                               vectors[i], sizeof(vectors[i]));
                                }
                                unsigned output =
                                    typedDot ? (dual || lookupVolume ? 3 : 2) :
                                               stage;
                                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                            PS_REGISTER_T0 + output);
                                send_method(
                                    NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                    (PS_REGISTER_T0 + output | PS_CHANNEL_ALPHA)
                                        << 8);
                                af_begin_vertices(core, physical, first, rect,
                                                  border, stage, profile);
                                if (dual)
                                    af_begin_vertices(core, physical,
                                                      secondFirst, rect, border,
                                                      1, profile ^ 1);
                                begin(PRIM_TYPE_TRIANGLES);
                                unsigned pending = operation & 1;
                                if (pending)
                                    arrays(0, 3);
                                if (operation == 1) {
                                    qemu_mutex_lock(&pg->lock);
                                    renderer.ops.flush_draw(state);
                                    qemu_mutex_unlock(&pg->lock);
                                }
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                                assert(pg->draw_arrays_length == pending);
                                NSData *frozen = [NSData
                                    dataWithBytes:pg->metal4_begin_capture
                                           length:pg->
                                                  metal4_begin_capture_size];
                                assert(pgraph_metal4_validate_begin_capture(
                                    frozen.bytes, frozen.length));
                                const uint8_t *bytes = frozen.bytes;
                                unsigned textureStart =
                                    48 + (uint32_t)ldl_be_p(bytes + 40);
                                assert((uint32_t)ldl_be_p(bytes + textureStart +
                                                          8) ==
                                       ((1u << stage) | (dual ? 2u : 0u) |
                                        (typedDot ? 1u << output : 0u)));
                                unsigned pixelStage =
                                    48 + 100 +
                                    offsetof(NV2AMetalPixelUniforms, textures) +
                                    stage * sizeof(NV2AMetalTextureStage);
                                unsigned recordStage = textureStart + 12 + 16;
                                unsigned conv =
                                    offsetof(NV2AMetalTextureStage, sampling) +
                                    offsetof(NV2AMetalSamplingUniforms,
                                             anisotropy);
                                assert((uint32_t)ldl_be_p(bytes + 4) == 3 &&
                                       (uint32_t)ldl_be_p(bytes + 48 + 4) ==
                                           6 &&
                                       (uint32_t)ldl_be_p(bytes + textureStart +
                                                          4) == 3 &&
                                       (uint32_t)ldl_be_p(bytes + pixelStage +
                                                          conv) == requested &&
                                       (uint32_t)ldl_be_p(bytes + recordStage +
                                                          conv) == requested);
                                assert((uint32_t)ldl_be_p(
                                           bytes + 48 + 100 +
                                           offsetof(NV2AMetalPixelUniforms,
                                                    surface_scale)) ==
                                       (mag == 1 ? 0x3f800000u : 0x40000000u));
                                assert((uint32_t)ldl_be_p(
                                           bytes + pixelStage +
                                           offsetof(NV2AMetalTextureStage,
                                                    scale)) == 0x3f800000u);
                                unsigned sign = offsetof(NV2AMetalTextureStage,
                                                         signed_channels);
                                assert((uint32_t)ldl_be_p(bytes + pixelStage +
                                                          sign) ==
                                           (signedHILO ? 15u : 0u) &&
                                       (uint32_t)ldl_be_p(bytes + recordStage +
                                                          sign) ==
                                           (signedHILO ? 15u : 0u) &&
                                       (uint32_t)ldl_be_p(
                                           bytes + 48 + 100 +
                                           offsetof(NV2AMetalPixelUniforms,
                                                    hilo16_mask)) ==
                                           ((1u << stage) | (dual ? 2u : 0u)));
                                for (unsigned part = 0; part < 2; part++) {
                                    NSMutableData *bad = [frozen mutableCopy];
                                    stl_be_p(
                                        (uint8_t *)bad.mutableBytes +
                                            (part ? recordStage : pixelStage) +
                                            sign,
                                        signedHILO ? 0 : 15);
                                    assert(
                                        !pgraph_metal4_validate_begin_capture(
                                            bad.bytes, bad.length));
                                    signedRejections++;
                                }
                                const uint8_t *image =
                                    bytes + textureStart + 12 + 220;
                                assert((uint32_t)ldl_be_p(image + 12) ==
                                           MAX(1u, physical[0] >> first) &&
                                       (uint32_t)ldl_be_p(image + 16) ==
                                           MAX(1u, physical[1] >> first) &&
                                       (uint32_t)ldl_be_p(image + 24) ==
                                           levels - first &&
                                       (uint32_t)ldl_be_p(image + 20) ==
                                           MAX(1u, physical[2] >> first));
                                if (gpuSource && volume)
                                    af_begin_check_volume_capture(
                                        image, physical, first, levels, 0,
                                        signedHILO, &capturedVoxels);
                                if (dual) {
                                    unsigned record =
                                        textureStart + 12 + 220 +
                                        (uint32_t)ldl_be_p(bytes +
                                                           textureStart + 24);
                                    unsigned pixel =
                                        pixelStage +
                                        sizeof(NV2AMetalTextureStage);
                                    unsigned flags =
                                        (uint32_t)ldl_be_p(bytes + record + 8);
                                    const uint8_t *secondImage =
                                        bytes + record + 220;
                                    assert((uint32_t)ldl_be_p(bytes + record) ==
                                               1 &&
                                           (flags & 8));
                                    assert(
                                        (uint32_t)ldl_be_p(secondImage + 12) ==
                                            MAX(1u,
                                                physical[0] >> secondFirst) &&
                                        (uint32_t)ldl_be_p(secondImage + 16) ==
                                            MAX(1u,
                                                physical[1] >> secondFirst) &&
                                        (uint32_t)ldl_be_p(secondImage + 24) ==
                                            levels - secondFirst);
                                    for (unsigned part = 0; part < 2; part++) {
                                        unsigned base =
                                            part ? record + 16 : pixel;
                                        assert((uint32_t)ldl_be_p(bytes + base +
                                                                  sign) ==
                                                   (secondSigned ? 15u : 0u) &&
                                               (uint32_t)ldl_be_p(bytes + base +
                                                                  conv) ==
                                                   (requested == 2 ? 8u : 2u) &&
                                               (uint32_t)ldl_be_p(
                                                   bytes + base +
                                                   offsetof(
                                                       NV2AMetalTextureStage,
                                                       scale)) == 0x3f800000u);
                                        NSMutableData *bad =
                                            [frozen mutableCopy];
                                        stl_be_p((uint8_t *)bad.mutableBytes +
                                                     base + sign,
                                                 secondSigned ? 0 : 15);
                                        assert(
                                            !pgraph_metal4_validate_begin_capture(
                                                bad.bytes, bad.length));
                                        signedRejections++;
                                        bad = [frozen mutableCopy];
                                        stl_be_p((uint8_t *)bad.mutableBytes +
                                                     base + conv,
                                                 requested);
                                        assert(
                                            !pgraph_metal4_validate_begin_capture(
                                                bad.bytes, bad.length));
                                        rejections++;
                                    }
                                }
                                if (lookupVolume || dual) {
                                    unsigned record =
                                        textureStart + 12 + 220 +
                                        (uint32_t)ldl_be_p(bytes +
                                                           textureStart + 24);
                                    if (dual)
                                        record +=
                                            220 + (uint32_t)ldl_be_p(
                                                      bytes + record + 12);
                                    unsigned lookupDimension = dual ? 2 : 3;
                                    unsigned pixel =
                                        48 + 100 +
                                        offsetof(NV2AMetalPixelUniforms,
                                                 textures) +
                                        output * sizeof(NV2AMetalTextureStage);
                                    unsigned dimension = offsetof(
                                        NV2AMetalTextureStage, dimension);
                                    const uint8_t *lookupImage =
                                        bytes + record + 220;
                                    assert(
                                        (uint32_t)ldl_be_p(bytes + record) ==
                                            3 &&
                                        (uint32_t)ldl_be_p(bytes + record +
                                                           4) == 1 &&
                                        (uint32_t)ldl_be_p(bytes + record + 16 +
                                                           dimension) ==
                                            lookupDimension &&
                                        (uint32_t)ldl_be_p(bytes + pixel +
                                                           dimension) ==
                                            lookupDimension &&
                                        (uint32_t)ldl_be_p(lookupImage + 12) ==
                                            8 &&
                                        (uint32_t)ldl_be_p(lookupImage + 16) ==
                                            8 &&
                                        (uint32_t)ldl_be_p(lookupImage + 20) ==
                                            (dual ? 1u : 8u) &&
                                        (uint32_t)ldl_be_p(lookupImage + 24) ==
                                            1);
                                    for (unsigned part = 0; part < 2; part++) {
                                        NSMutableData *bad =
                                            [frozen mutableCopy];
                                        stl_be_p(
                                            (uint8_t *)bad.mutableBytes +
                                                (part ? record + 16 : pixel) +
                                                dimension,
                                            dual ? 3 : 2);
                                        assert(
                                            !pgraph_metal4_validate_begin_capture(
                                                bad.bytes, bad.length));
                                        lookupRejections++;
                                    }
                                }
                                for (unsigned part = 0; part < 2; part++) {
                                    NSMutableData *bad = [frozen mutableCopy];
                                    stl_be_p(
                                        (uint8_t *)bad.mutableBytes +
                                            (part ? recordStage : pixelStage) +
                                            conv,
                                        requested == 2 ? 8 : 2);
                                    assert(
                                        !pgraph_metal4_validate_begin_capture(
                                            bad.bytes, bad.length));
                                    rejections++;
                                }
                                send_method(NV097_SET_TEXTURE_FORMAT +
                                                methodSlot,
                                            127u << 8);
                                send_method(NV097_SET_TEXTURE_FILTER +
                                                methodSlot,
                                            1 << 16 | 1 << 24);
                                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                            PS_TEXTUREMODES_PASSTHRU
                                                << (5 * stage));
                                if (dual) {
                                    send_method(NV097_SET_TEXTURE_FORMAT + 64,
                                                127u << 8);
                                    send_method(NV097_SET_TEXTURE_FILTER + 64,
                                                1 << 16 | 1 << 24);
                                }
                                if (gpuSource)
                                    af_begin_gpu_write(writer, physical, levels,
                                                       rect, 1, signedHILO, mag,
                                                       &gpuDraws, &gpuPixels);
                                else
                                    af_begin_write(physical, levels, rect, 1,
                                                   signedHILO);
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                                NSData *again = [NSData
                                    dataWithBytes:pg->metal4_begin_capture
                                           length:pg->
                                                  metal4_begin_capture_size];
                                assert([again isEqualToData:frozen]);
                                canonical++;
                                if (operation >= 2) {
                                    int fd = new_vertex_snapshot_file();
                                    save_snapshot_parent(
                                        fd, &array_snapshot_parent);
                                    NSData *ram =
                                        [NSData dataWithBytes:state->vram_ptr
                                                       length:65536];
                                    for (unsigned pass = 0;
                                         pass < operation - 1; pass++) {
                                        if (!pending)
                                            arrays(0, 3);
                                        end();
                                        before_ram_load();
                                        memcpy(state->vram_ptr, ram.bytes,
                                               ram.length);
                                        assert(
                                            load_snapshot_parent(
                                                fd, &array_snapshot_parent) ==
                                            0);
                                        after_ram_load();
                                        assert(pg->draw_arrays_length ==
                                               pending);
                                        // Materialize the lazy restored Begin
                                        // before the byte comparison.
                                        qemu_mutex_lock(&pg->lock);
                                        renderer.ops.flush_draw(state);
                                        qemu_mutex_unlock(&pg->lock);
                                        assert(pg->draw_arrays_length ==
                                               pending);
                                        close(fd);
                                        restores++;
                                        pendingRestores += pending;
                                        renderer.ops.pre_savevm_trigger(state);
                                        process_pending();
                                        renderer.ops.pre_savevm_wait(state);
                                        again = [NSData
                                            dataWithBytes:
                                                pg->metal4_begin_capture
                                                   length:
                                                       pg->
                                                       metal4_begin_capture_size];
                                        assert([again isEqualToData:frozen]);
                                        canonical++;
                                        if (pass + 1 < operation - 1) {
                                            fd = new_vertex_snapshot_file();
                                            save_snapshot_parent(
                                                fd, &array_snapshot_parent);
                                            ram = [NSData
                                                dataWithBytes:state->vram_ptr
                                                       length:65536];
                                        }
                                    }
                                }
                                // Scratch draws during capture must not hide a
                                // missing final End draw.
                                cpu_write(1024, 256);
                                for (unsigned i = 0; i < 64; i++)
                                    stl_le_p(state->vram_ptr + 1024 + 4 * i,
                                             0xffff0000);
                                if (!pending)
                                    arrays(0, 3);
                                end();
                                uint32_t outputs[4][64];
                                NSData *previous = frozen;
                                for (unsigned phase = 0;
                                     phase < (dual ? 4u : 3u); phase++) {
                                    for (unsigned y = 0; y < 8; y++)
                                        for (unsigned x = 0; x < 8; x++) {
                                            uint32_t actual = color(x, y);
                                            outputs[phase][y * 8 + x] = actual;
                                            bool covered =
                                                (x + y) * mag + 1 < 8 * mag;
                                            if (covered) {
                                                double expected[4];
                                                unsigned taps;
                                                af_begin_reference(
                                                    physical, first, levels,
                                                    rect, profile, mag,
                                                    requested,
                                                    dual ?
                                                        (phase == 3 ?
                                                             2 :
                                                             MIN(phase, 1u)) :
                                                        phase,
                                                    signedHILO, typedDot,
                                                    lookupVolume, x, y,
                                                    expected, &taps);
                                                tapPixels[taps - 1]++;
                                                if (dual) {
                                                    double second[4];
                                                    unsigned secondTaps;
                                                    af_begin_reference(
                                                        physical, secondFirst,
                                                        levels, rect,
                                                        profile ^ 1, mag,
                                                        requested == 2 ? 8 : 2,
                                                        phase < 2 ? 2 : 3,
                                                        secondSigned, YES, NO,
                                                        x, y, second,
                                                        &secondTaps);
                                                    expected[1] = second[1];
                                                    secondTapPixels[secondTaps -
                                                                    1]++;
                                                }
                                                for (unsigned channel = 0;
                                                     channel < 4; channel++) {
                                                    unsigned shifts[] = { 16, 8,
                                                                          0,
                                                                          24 };
                                                    unsigned byte =
                                                        actual >>
                                                            shifts[channel] &
                                                        255;
                                                    // A 0.002/255 float
                                                    // interval only straddles
                                                    // adjacent UNORM codes at
                                                    // genuine rounding
                                                    // boundaries. Most are
                                                    // exact.
                                                    int low = MAX(
                                                        0,
                                                        (int)floor(
                                                            expected[channel] +
                                                            .5 - .002));
                                                    int high = MIN(
                                                        255,
                                                        (int)floor(
                                                            expected[channel] +
                                                            .5 + .002));
                                                    if (byte < (unsigned)low ||
                                                        byte > (unsigned)high) {
                                                        fprintf(
                                                            stderr,
                                                            "AF Begin kind%u "
                                                            "signed%u "
                                                            "shape%u first%u "
                                                            "stage%u AF%u "
                                                            "scale%u profile%u "
                                                            "op%u phase%u "
                                                            "pixel%u,%u "
                                                            "channel%u:%u "
                                                            "expected %.9g "
                                                            "[%d,%d]\n",
                                                            kind, signedHILO,
                                                            shape, first, stage,
                                                            requested, mag,
                                                            profile, operation,
                                                            phase, x, y,
                                                            channel, byte,
                                                            expected[channel],
                                                            low, high);
                                                        abort();
                                                    }
                                                    ambiguous += low != high;
                                                    coveredChannels++;
                                                }
                                            } else {
                                                assert(actual == 0xffff0000);
                                            }
                                            pixels++;
                                        }
                                    if (phase < (dual ? 3u : 2u)) {
                                        if (phase == 1) {
                                            if (dual)
                                                af_begin_gpu_write_at(
                                                    writer, physical, levels,
                                                    rect, 3, secondSigned, mag,
                                                    32768, false, &gpuDraws,
                                                    &gpuPixels);
                                            else if (gpuSource)
                                                af_begin_gpu_write(
                                                    writer, physical, levels,
                                                    rect, 2, signedHILO, mag,
                                                    &gpuDraws, &gpuPixels);
                                            else
                                                af_begin_write(physical, levels,
                                                               rect, 2,
                                                               signedHILO);
                                        }
                                        // Update source0 again after fresh
                                        // Begins: SaveVM can flush its earlier
                                        // cache entry.
                                        if (dual && phase == 2)
                                            af_begin_gpu_write_at(
                                                writer, physical, levels, rect,
                                                2, signedHILO, mag, 24576,
                                                false, &gpuDraws, &gpuPixels);
                                        cpu_write(1024, 256);
                                        for (unsigned i = 0; i < 64; i++)
                                            stl_le_p(state->vram_ptr + 1024 +
                                                         4 * i,
                                                     0xffff0000);
                                        send_method(NV097_SET_TEXTURE_FORMAT +
                                                        methodSlot,
                                                    format);
                                        send_method(NV097_SET_TEXTURE_FILTER +
                                                        methodSlot,
                                                    filter);
                                        send_method(
                                            NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                        if (dual) {
                                            send_method(
                                                NV097_SET_TEXTURE_FORMAT + 64,
                                                format);
                                            send_method(
                                                NV097_SET_TEXTURE_FILTER + 64,
                                                6 << 16 | 2 << 24 | 96 |
                                                    (secondSigned ?
                                                         0xf0000000u :
                                                         0));
                                        }
                                        // Preserve the live texture arrays
                                        // across fresh Begins.
                                        begin(PRIM_TYPE_TRIANGLES);
                                        require([surfaces.cache
                                                    submitWithError:&error] &&
                                                    [surfaces.cache
                                                        waitUntilIdleWithError:
                                                            &error],
                                                error);
                                        NSData *fresh = [draw
                                            beginSnapshotWithError:&error];
                                        require(fresh != nil, error);
                                        assert(![fresh isEqualToData:previous]);
                                        if (gpuSource && volume) {
                                            const uint8_t *freshBytes =
                                                fresh.bytes;
                                            unsigned start =
                                                48 + (uint32_t)ldl_be_p(
                                                         freshBytes + 40);
                                            af_begin_check_volume_capture(
                                                freshBytes + start + 12 + 220,
                                                physical, first, levels,
                                                phase + 1, signedHILO,
                                                &capturedVoxels);
                                        }
                                        previous = fresh;
                                        arrays(0, 3);
                                        end();
                                        nextBegins++;
                                    }
                                }
                                assert(memcmp(outputs[0], outputs[1],
                                              sizeof(outputs[0])) &&
                                       memcmp(outputs[1], outputs[2],
                                              sizeof(outputs[1])));
                                if (dual) {
                                    bool changedR = false, changedG = false,
                                         changedR2 = false;
                                    for (unsigned i = 0; i < 64; i++) {
                                        assert((outputs[0][i] & 0x0000ffffu) ==
                                               (outputs[1][i] & 0x0000ffffu));
                                        assert((outputs[1][i] & 0xffff00ffu) ==
                                               (outputs[2][i] & 0xffff00ffu));
                                        assert((outputs[2][i] & 0x0000ffffu) ==
                                               (outputs[3][i] & 0x0000ffffu));
                                        changedR2 |=
                                            (outputs[2][i] & 0x00ff0000u) !=
                                            (outputs[3][i] & 0x00ff0000u);
                                        changedR |=
                                            (outputs[0][i] & 0x00ff0000u) !=
                                            (outputs[1][i] & 0x00ff0000u);
                                        changedG |=
                                            (outputs[1][i] & 0x0000ff00u) !=
                                            (outputs[2][i] & 0x0000ff00u);
                                    }
                                    assert(changedR && changedG && changedR2);
                                    independentOutputs += 3;
                                }
                                changedOutputs += dual ? 3 : 2;
                                cases++;
                            }
    }
    unsigned count = volume ? (typedDot ? 512 : 1024) : typedDot ? 320 : 640;
    assert(cases == count && restores == count * 3 / 4 &&
           pendingRestores == count / 2 && canonical == count * 7 / 4 &&
           pixels == count * (dual ? 256 : 192) &&
           nextBegins == count * (dual ? 3 : 2) &&
           rejections == count * (dual ? 4 : 2) &&
           changedOutputs == count * (dual ? 3 : 2) &&
           signedRejections == count * (dual ? 4 : 2));
    const unsigned roundingBoundaries[][2] = {
        { 1232, 592 }, { 1256, 1088 }, { 648, 496 },   { 236, 284 },
        { 832, 720 },  { 364, 420 },   { 1232, 592 },  { 364, 420 },
        { 348, 380 },  { 356, 388 },   { 1256, 1088 }, { 648, 496 },
        { 832, 720 }
    };
    assert(ambiguous == roundingBoundaries[kind][signedHILO != NO]);
    assert(gpuDraws == (gpuSource && volume ? (typedDot ? 6144u : 12288u) :
                        dual                ? 5440u :
                        gpuSource           ? (typedDot ? 3264u : 6528u) :
                                              0u) &&
           gpuPixels == (gpuSource && volume ?
                             (typedDot ? 9129600u : 18259200u) :
                         dual      ? 705600u :
                         gpuSource ? (typedDot ? 423360u : 846720u) :
                                     0u));
    assert(capturedVoxels ==
           (gpuSource && volume ? (typedDot ? 2054400u : 4108800u) : 0u));
    if (gpuSource && volume)
        printf("GPU HILO 3D captures: %u complete source voxels PASS\n",
               capturedVoxels);
    assert(independentOutputs == (dual ? count * 3 : 0));
    if (dual) {
        assert(secondTapPixels[1] && secondTapPixels[7]);
        printf("Dual HILO: source1 signed%u/%u independent channel changes; "
               "second-source taps1..8:",
               secondSigned, independentOutputs);
        for (unsigned i = 0; i < 8; i++)
            printf(" %u", secondTapPixels[i]);
        printf("\n");
    }
    assert(lookupRejections == (lookupVolume || dual ? count * 2 : 0));
    assert(coveredChannels == count * (dual ? 512 : 384) &&
           ambiguous < coveredChannels / 100 && tapPixels[1] && tapPixels[7]);
    printf("Metal4 kind%u %sHILO16 AF Begin: %u cases/%u partial restores/%u "
           "pending-array restores/%u canonical resaves/%u bounded raw "
           "pixels/%u covered channels/%u rounding-boundary channels/%u fresh "
           "Begins/%u AF rejects/%u Signed rejects/%u changed outputs PASS\n",
           kind, signedHILO ? "signed " : "", cases, restores, pendingRestores,
           canonical, pixels, coveredChannels, ambiguous, nextBegins,
           rejections, signedRejections, changedOutputs);
    if (lookupVolume || dual)
        printf("%s lookup-dimension mismatch rejects: %u PASS\n",
               dual ? "DOT_ST" : "DOT_STR_3D", lookupRejections);
    if (gpuSource)
        printf("GPU HILO source: %u draws/%u native pixels PASS\n", gpuDraws,
               gpuPixels);
    printf("AF Begin pixel taps1..8:");
    for (unsigned i = 0; i < 8; i++)
        printf(" %u", tapPixels[i]);
    printf("\n");
    groups++;
}

static unsigned cube_begin_face_length(const unsigned physical[3],
                                       unsigned levels)
{
    unsigned length = 0;
    for (unsigned level = 0; level < levels; level++)
        length +=
            4 * MAX(1u, physical[0] >> level) * MAX(1u, physical[1] >> level);
    return length;
}
static void cube_begin_gpu_write_at(NV2AMetalPixelShader *writer,
                                    const unsigned physical[3], unsigned levels,
                                    unsigned phase, BOOL signedHILO,
                                    unsigned scale, unsigned source,
                                    unsigned *draws, unsigned *pixels)
{
    unsigned faceLength = cube_begin_face_length(physical, levels);
    unsigned stride = ROUND_UP(faceLength, NV2A_CUBEMAP_FACE_ALIGNMENT);
    unsigned length = 6 * stride;
    assert(source >= 24576 && source + length < 49152 && physical[2] == 1);
    if (!phase) {
        cpu_write(source, length);
        memset(state->vram_ptr + source, 0xd3, length);
    }
    unsigned previousLimit = dma[4].address == 24576 ? dma[4].limit : 0;
    dma[4].address = 24576;
    dma[4].limit = MAX(previousLimit, source - 24576 + length - 1);
    for (unsigned face = 0; face < 6; face++)
        af_begin_gpu_write_face(writer, physical, levels, false, phase,
                                signedHILO, scale, source + face * stride, face,
                                false, draws, pixels);
    if (!phase)
        for (unsigned i = 0; i < length; i++)
            assert(state->vram_ptr[source + i] == 0xd3);
}
static void cube_begin_gpu_write(NV2AMetalPixelShader *writer,
                                 const unsigned physical[3], unsigned levels,
                                 unsigned phase, BOOL signedHILO,
                                 unsigned scale, unsigned *draws,
                                 unsigned *pixels)
{
    cube_begin_gpu_write_at(writer, physical, levels, phase, signedHILO, scale,
                            24576, draws, pixels);
}
static void cube_begin_check_capture(NSData *capture,
                                     const unsigned physical[3], unsigned first,
                                     unsigned levels, unsigned phase,
                                     BOOL signedHILO, unsigned stage,
                                     unsigned output, unsigned *texels)
{
    assert(pgraph_metal4_validate_begin_capture(capture.bytes, capture.length));
    const uint8_t *bytes = capture.bytes;
    unsigned start = 48 + (uint32_t)ldl_be_p(bytes + 40);
    assert((uint32_t)ldl_be_p(bytes + start + 8) ==
           ((1u << stage) | (1u << output)));
    const uint8_t *image = bytes + start + 12 + 220;
    assert((uint32_t)ldl_be_p(image + 12) == physical[0] >> first &&
           (uint32_t)ldl_be_p(image + 16) == physical[1] >> first &&
           (uint32_t)ldl_be_p(image + 20) == 1 &&
           (uint32_t)ldl_be_p(image + 24) == levels - first);
    af_begin_check_image_capture(image, physical, first, levels, phase,
                                 signedHILO, YES, texels);
}
static void cube_begin_reference(const unsigned physical[3], unsigned first,
                                 unsigned face, const double uv[2], bool border,
                                 bool linear, unsigned phase, BOOL signedHILO,
                                 double result[4])
{
    unsigned size = physical[0] >> first;
    double position[2], fraction[2];
    int base[2];
    for (unsigned axis = 0; axis < 2; axis++) {
        position[axis] =
            (border ? (uv[axis] * 8 + 4) / (1u << first) : uv[axis] * size) -
            (linear ? .5 : 0);
        base[axis] = floor(position[axis]);
        fraction[axis] = position[axis] - base[axis];
    }
    result[0] = result[1] = 0;
    for (unsigned corner = 0; corner < (linear ? 4u : 1u); corner++) {
        unsigned highX = corner & 1, highY = corner >> 1;
        unsigned x = MAX(0, MIN((int)size - 1, base[0] + (int)highX));
        unsigned y = MAX(0, MIN((int)size - 1, base[1] + (int)highY));
        double weight = linear ? (highX ? fraction[0] : 1 - fraction[0]) *
                                     (highY ? fraction[1] : 1 - fraction[1]) :
                                 1;
        uint32_t word = af_begin_word(x, y, face, first, phase, signedHILO);
        int hi = word >> 16, lo = word & 65535;
        if (signedHILO) {
            hi -= hi >= 32768 ? 65536 : 0;
            lo -= lo >= 32768 ? 65536 : 0;
        }
        result[0] += weight * (signedHILO ? hi * 510.0 / 65535 : hi / 257.0);
        result[1] += weight * (signedHILO ? lo * 510.0 / 65535 : lo / 257.0);
    }
    result[0] = MAX(0.0, MIN(255.0, result[0]));
    result[1] = MAX(0.0, MIN(255.0, result[1]));
    result[2] = result[1];
    result[3] = 255;
}
static void cube_af_direction(unsigned face, unsigned first, unsigned profile,
                              double x, double y, double direction[3])
{
    const double major[][2] = {
        { 4, 0 }, { 0, 4 }, { 2.4, 3.2 }, { -3.2, 2.4 }
    };
    const double minor[][2] = {
        { 0, .25 }, { .25, 0 }, { -.2, .15 }, { .15, .2 }
    };
    double along = profile & 1 ? y : x, across = profile & 1 ? x : y;
    double u =
        .3671875 + (along * major[profile][0] + across * minor[profile][0]) /
                       (8u >> first);
    double v =
        .58203125 + (along * major[profile][1] + across * minor[profile][1]) /
                        (8u >> first);
    double a = 2 * u - 1, b = 2 * v - 1;
    const double directions[][3] = { { 1, -b, -a }, { -1, -b, a },
                                     { a, 1, b },   { a, -1, -b },
                                     { a, -b, 1 },  { -a, -b, -1 } };
    memcpy(direction, directions[face], 3 * sizeof(double));
}
static void cube_af_vertices_at(unsigned face, unsigned first, unsigned profile,
                                unsigned stage, unsigned offset)
{
    const double xy[][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 } };
    float values[3][4] = {};
    for (unsigned vertex = 0; vertex < 3; vertex++) {
        double direction[3];
        cube_af_direction(face, first, profile, xy[vertex][0] - 2,
                          xy[vertex][1] - 2, direction);
        for (unsigned axis = 0; axis < 3; axis++)
            values[vertex][axis] = direction[axis];
        values[vertex][3] = 1;
    }
    cpu_write(16384 + offset, sizeof(values));
    memcpy(state->vram_ptr + 16384 + offset, values, sizeof(values));
    uint32_t format = 0;
    SET_MASK(format, NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE,
             NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F);
    SET_MASK(format, NV097_SET_VERTEX_DATA_ARRAY_FORMAT_SIZE, 4);
    SET_MASK(format, NV097_SET_VERTEX_DATA_ARRAY_FORMAT_STRIDE, 16);
    send_method(NV097_SET_VERTEX_DATA_ARRAY_FORMAT + (9 + stage) * 4, format);
    send_method(NV097_SET_VERTEX_DATA_ARRAY_OFFSET + (9 + stage) * 4, offset);
}
static void cube_af_vertices(unsigned face, unsigned first, unsigned profile,
                             unsigned stage)
{
    cube_af_vertices_at(face, first, profile, stage, 256);
}
static void cube_af_level(const unsigned physical[3], unsigned level,
                          unsigned face, const double uv[2], unsigned phase,
                          BOOL signedHILO, double result[2])
{
    unsigned size = MAX(1u, physical[0] >> level);
    double position[] = { uv[0] * size - .5, uv[1] * size - .5 };
    int base[] = { floor(position[0]), floor(position[1]) };
    double fraction[] = { position[0] - base[0], position[1] - base[1] };
    result[0] = result[1] = 0;
    for (unsigned corner = 0; corner < 4; corner++) {
        unsigned highX = corner & 1, highY = corner >> 1;
        unsigned x = MAX(0, MIN((int)size - 1, base[0] + (int)highX));
        unsigned y = MAX(0, MIN((int)size - 1, base[1] + (int)highY));
        double weight = (highX ? fraction[0] : 1 - fraction[0]) *
                        (highY ? fraction[1] : 1 - fraction[1]);
        uint32_t word = af_begin_word(x, y, face, level, phase, signedHILO);
        int hi = word >> 16, lo = word & 65535;
        if (signedHILO) {
            hi -= hi >= 32768 ? 65536 : 0;
            lo -= lo >= 32768 ? 65536 : 0;
        }
        result[0] += weight * (signedHILO ? hi * 510.0 / 65535 : hi / 257.0);
        result[1] += weight * (signedHILO ? lo * 510.0 / 65535 : lo / 257.0);
    }
}
static uint32_t cube_lookup_word(unsigned x, unsigned y, unsigned face,
                                 unsigned phase)
{
    return 0xff000000u | (16 + 24 * x + 3 * face + 7 * phase) << 16 |
           (24 + 24 * y + 5 * face + 11 * phase) << 8 |
           (32 + 17 * face + 2 * x + 3 * y + 13 * phase);
}
static void cube_lookup_write(unsigned phase)
{
    const unsigned size[] = { 8, 8, 1 };
    cpu_write(49152, 1536);
    for (unsigned face = 0; face < 6; face++)
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++)
                stl_le_p(state->vram_ptr + 49152 + face * 256 +
                             4 * border_begin_morton(x, y, 0, size),
                         cube_lookup_word(x, y, face, phase));
}
static void cube_lookup_setup(void)
{
    dma[3].address = 49152;
    dma[3].limit = 1535;
    cube_lookup_write(0);
    uint32_t format = 0;
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 1);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
             NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 2);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CUBEMAP_ENABLE, 1);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE, 1);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U, 3);
    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V, 3);
    send_method(NV097_SET_TEXTURE_FORMAT + 192, format);
    send_method(NV097_SET_TEXTURE_CONTROL0 + 192,
                NV097_SET_TEXTURE_CONTROL0_ENABLE);
    send_method(NV097_SET_TEXTURE_FILTER + 192, 2 << 16 | 2 << 24);
    send_method(NV097_SET_TEXTURE_ADDRESS + 192, 3 | 3 << 8 | 3 << 16);
}
static unsigned cube_lookup_check_capture(NSData *capture, unsigned phase,
                                          unsigned *texels)
{
    const uint8_t *bytes = capture.bytes;
    unsigned start = 48 + (uint32_t)ldl_be_p(bytes + 40);
    unsigned record = start + 12 + 220 + (uint32_t)ldl_be_p(bytes + start + 24);
    const uint8_t *image = bytes + record + 220;
    unsigned storage;
    const uint8_t *data = af_begin_image_payload(image, &storage);
    assert(storage == NV2AMetalTextureStorageFloat32 ||
           storage == NV2AMetalTextureStorageUnorm8);
    unsigned bytesPerTexel = storage == NV2AMetalTextureStorageUnorm8 ? 4 : 16;
    assert((uint32_t)ldl_be_p(bytes + record) == 3 &&
           (uint32_t)ldl_be_p(image + 8) == 3 &&
           (uint32_t)ldl_be_p(image + 12) == 8 &&
           (uint32_t)ldl_be_p(image + 16) == 8 &&
           (uint32_t)ldl_be_p(image + 20) == 1 &&
           (uint32_t)ldl_be_p(image + 24) == 1 &&
           (uint32_t)ldl_be_p(image + 28) == 0 &&
           (uint32_t)ldl_be_p(image + 32) == 6 * 64 * bytesPerTexel);
    unsigned pixel = 48 + 100 + offsetof(NV2AMetalPixelUniforms, textures) +
                     3 * sizeof(NV2AMetalTextureStage);
    for (unsigned part = 0; part < 2; part++) {
        const uint8_t *stage = bytes + (part ? record + 16 : pixel);
        assert((uint32_t)ldl_be_p(
                   stage + offsetof(NV2AMetalTextureStage, dimension)) == 2 &&
               (uint32_t)ldl_be_p(
                   stage + offsetof(NV2AMetalTextureStage, cubemap)) == 1 &&
               (uint32_t)ldl_be_p(stage + offsetof(NV2AMetalTextureStage,
                                                   signed_channels)) == 0 &&
               (uint32_t)ldl_be_p(
                   stage + offsetof(NV2AMetalTextureStage, sampling) +
                   offsetof(NV2AMetalSamplingUniforms, anisotropy)) == 1);
    }
    for (unsigned face = 0; face < 6; face++)
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                uint32_t word = cube_lookup_word(x, y, face, phase);
                af_begin_check_rgba_texel(&data, storage, word);
                (*texels)++;
            }
    assert((uint64_t)(data - af_begin_image_payload(image, &storage)) ==
           6 * 64 * bytesPerTexel);
    return record + 16;
}
static void cube_lookup_vectors(unsigned face)
{
    /* a=.5*HI+.125*LO, b=.125*HI+.5*LO, major=Z. */
    const float rows[6][3][3] = {
        { { 0, 0, 1 }, { -.125, -.5, 0 }, { -.5, -.125, 0 } },
        { { 0, 0, -1 }, { -.125, -.5, 0 }, { .5, .125, 0 } },
        { { .5, .125, 0 }, { 0, 0, 1 }, { .125, .5, 0 } },
        { { .5, .125, 0 }, { 0, 0, -1 }, { -.125, -.5, 0 } },
        { { .5, .125, 0 }, { -.125, -.5, 0 }, { 0, 0, 1 } },
        { { -.5, -.125, 0 }, { -.125, -.5, 0 }, { 0, 0, -1 } }
    };
    for (unsigned i = 0; i < 3; i++)
        memcpy(state->pgraph.vertex_attributes[10 + i].inline_value,
               rows[face][i], sizeof(rows[face][i]));
}
static void cube_lookup_reference(double hi, double lo, double z,
                                  unsigned wantedFace, unsigned phase,
                                  double result[4], unsigned *lookupFace)
{
    double a = .5 * hi + .125 * lo, b = .125 * hi + .5 * lo;
    double c[3] = { a, -b, z };
    switch (wantedFace) {
    case 0:
        c[0] = z;
        c[2] = -a;
        break;
    case 1:
        c[0] = -z;
        c[2] = a;
        break;
    case 2:
        c[1] = z;
        c[2] = b;
        break;
    case 3:
        c[1] = -z;
        c[2] = -b;
        break;
    case 5:
        c[0] = -a;
        c[2] = -z;
        break;
    }
    unsigned axis = 0;
    for (unsigned i = 1; i < 3; i++)
        if (fabs(c[i]) > fabs(c[axis]))
            axis = i;
    unsigned face = 2 * axis + (c[axis] < 0);
    *lookupFace = face;
    assert(face == wantedFace);
    double sign = c[axis] < 0 ? -1 : 1, major = fabs(c[axis]);
    double u = axis == 0 ? -sign * c[2] : axis == 1 ? c[0] : sign * c[0];
    double v = axis == 1 ? sign * c[2] : -c[1];
    double position[] = { 4 * (u / major + 1) - .5, 4 * (v / major + 1) - .5 };
    int base[] = { floor(position[0]), floor(position[1]) };
    double fraction[] = { position[0] - base[0], position[1] - base[1] };
    result[0] = result[1] = result[2] = 0;
    const unsigned shifts[] = { 16, 8, 0 };
    for (unsigned corner = 0; corner < 4; corner++) {
        unsigned highX = corner & 1, highY = corner >> 1;
        unsigned x = MAX(0, MIN(7, base[0] + (int)highX));
        unsigned y = MAX(0, MIN(7, base[1] + (int)highY));
        double weight = (highX ? fraction[0] : 1 - fraction[0]) *
                        (highY ? fraction[1] : 1 - fraction[1]);
        uint32_t word = cube_lookup_word(x, y, face, phase);
        for (unsigned channel = 0; channel < 3; channel++)
            result[channel] += weight * (word >> shifts[channel] & 255);
    }
    result[3] = 255;
}

static void cube_af_reference(const unsigned physical[3], unsigned first,
                              unsigned levels, unsigned inputFace,
                              unsigned profile, unsigned scale,
                              unsigned anisotropy, unsigned kind, bool border,
                              unsigned phase, BOOL signedHILO, unsigned px,
                              unsigned py, double result[4], unsigned *tapCount,
                              unsigned *selectedFace, unsigned *lookupFace)
{
    double x = px + .5 / scale - 2, y = py + .5 / scale - 2;
    double c[3], gradient[2][3];
    cube_af_direction(inputFace, first, profile, x, y, c);
    unsigned native[] = { px * scale, py * scale };
    for (unsigned screen = 0; screen < 2; screen++) {
        double low[3], high[3];
        double qx = screen ? x : ((native[0] & ~1u) + .5) / scale - 2;
        double qy = screen ? ((native[1] & ~1u) + .5) / scale - 2 : y;
        cube_af_direction(inputFace, first, profile, qx, qy, low);
        cube_af_direction(inputFace, first, profile,
                          qx + !screen / (double)scale,
                          qy + screen / (double)scale, high);
        for (unsigned axis = 0; axis < 3; axis++)
            gradient[screen][axis] = high[axis] - low[axis];
    }
    unsigned axis = 0;
    for (unsigned i = 1; i < 3; i++)
        if (fabs(c[i]) > fabs(c[axis]))
            axis = i;
    unsigned face = 2 * axis + (c[axis] < 0);
    *selectedFace = face;
    const int basis[6][3][3] = { { { 0, 0, -1 }, { 0, -1, 0 }, { 1, 0, 0 } },
                                 { { 0, 0, 1 }, { 0, -1, 0 }, { -1, 0, 0 } },
                                 { { 1, 0, 0 }, { 0, 0, 1 }, { 0, 1, 0 } },
                                 { { 1, 0, 0 }, { 0, 0, -1 }, { 0, -1, 0 } },
                                 { { 1, 0, 0 }, { 0, -1, 0 }, { 0, 0, 1 } },
                                 { { -1, 0, 0 }, { 0, -1, 0 }, { 0, 0, -1 } } };
    double projected[3] = {}, derivative[2][3] = {};
    for (unsigned i = 0; i < 3; i++)
        for (unsigned j = 0; j < 3; j++) {
            projected[i] += basis[face][i][j] * c[j];
            for (unsigned screen = 0; screen < 2; screen++)
                derivative[screen][i] +=
                    basis[face][i][j] * gradient[screen][j];
        }
    double uv[2], g[2][2], squared[2] = {};
    for (unsigned i = 0; i < 2; i++) {
        double normalized = projected[i] / projected[2];
        uv[i] = .5 * (normalized + 1);
        if (border)
            uv[i] = (uv[i] * 8 + 4) / physical[0];
        for (unsigned screen = 0; screen < 2; screen++) {
            g[screen][i] =
                .5 * (derivative[screen][i] / projected[2] -
                      normalized * derivative[screen][2] / projected[2]);
            if (border)
                g[screen][i] *= 8.0 / physical[0];
            double texels = g[screen][i] * (physical[0] >> first);
            squared[screen] += texels * texels;
        }
    }
    unsigned major = squared[0] > squared[1] ? 0 : 1;
    double longest = sqrt(squared[major]), shortest = sqrt(squared[1 - major]);
    unsigned taps =
        longest > 1 ?
            MIN(anisotropy,
                MAX(1u, (unsigned)ceil(longest / MAX(shortest, 1e-30)))) :
            1;
    *tapCount = taps;
    double lod = log2(MAX(longest / taps, 1e-30)) + .375;
    double level = MAX(0.0, MIN((double)(levels - first - 1), lod));
    unsigned low = floor(level), high = MIN(low + 1, levels - first - 1);
    double blend = level - low;
    result[0] = result[1] = 0;
    for (unsigned tap = 0; tap < taps; tap++) {
        double offset = (tap + 1.0) / (taps + 1.0) - .5;
        double sample[] = { uv[0] + g[major][0] * offset,
                            uv[1] + g[major][1] * offset };
        double a[2], b[2];
        cube_af_level(physical, first + low, face, sample, MIN(phase, 2u),
                      signedHILO, a);
        cube_af_level(physical, first + high, face, sample, MIN(phase, 2u),
                      signedHILO, b);
        for (unsigned channel = 0; channel < 2; channel++)
            result[channel] +=
                (a[channel] * (1 - blend) + b[channel] * blend) / taps;
    }
    if (kind == 5) {
        /* BRDF uses the two filtered typed components, not Dot's Z. */
        double factor = (signedHILO ? 65535.0 / 65536 : 1) / 255;
        result[0] *= factor;
        result[1] *= factor;
        result[2] = 0;
        result[3] = 1;
        return;
    }
    if (kind >= 2) {
        double factor = signedHILO ? 65535.0 / 65536 : 1;
        double hi = result[0] / 255 * factor, lo = result[1] / 255 * factor;
        double z = signedHILO ? sqrt(MAX(0.0, 1 - hi * hi - lo * lo)) : 1;
        if (kind == 4) {
            cube_lookup_reference(hi, lo, z, inputFace,
                                  phase ? (phase == 3 ? 2 : 1) : 0, result,
                                  lookupFace);
            return;
        }
        result[0] = 256 * MAX(.0625, MIN(.9375, .5 * hi + .25 * lo + .125 * z));
        result[1] = 256 * MAX(.0625, MIN(.9375, .25 * hi + .5 * lo + .125 * z));
        result[2] =
            kind == 3 ?
                256 * MAX(.0625, MIN(.9375, .125 * hi + .125 * lo + .5 * z)) :
                32;
    } else {
        result[0] = MAX(0.0, MIN(255.0, result[0]));
        result[1] = MAX(0.0, MIN(255.0, result[1]));
        result[2] = result[1];
    }
    result[3] = 255;
}

static void hilo16_gpu_cube_begin_snapshot(BOOL signedHILO, unsigned kind)
{
    assert(kind < 5);
    unsigned phases = kind == 4 ? 4 : 3;
    unsigned lookupTexels = 0, lookupRejects = 0, lookupFaces = 0;
    unsigned count = kind == 1 ? 2304 : kind ? 1152 : 768;
    unsigned tapPixels[8] = {}, selectedFaces = 0, changedFaces = 0,
             afRejects = 0;
    const double positions[][2] = { { .28125, .65625 }, { .71875, .34375 } };
    unsigned cases = 0, restores = 0, pendingRestores = 0, canonical = 0;
    unsigned pixels = 0, nextBegins = 0, changed = 0, texels = 0;
    unsigned gpuDraws = 0, gpuPixels = 0, padding = 0, rejects = 0;
    unsigned channels = 0, ambiguous = 0, faces = 0;
    NV2AMetalPixelShader *writer = nil;
    id<MTLDevice> writerDevice = nil;
    NSError *error = nil;
    for (unsigned border = 0; border < 2; border++)
        for (unsigned first = 0; first < 2; first++)
            for (unsigned slot = 0; slot < (kind >= 2 ? 1u : 2u); slot++)
                for (unsigned linear = 0; linear < (kind ? 3u : 2u); linear++)
                    for (unsigned scale = 1; scale <= 2; scale++)
                        for (unsigned face = 0; face < 6; face++)
                            for (unsigned profile = 0;
                                 profile < (kind ? 4u : 2u); profile++)
                                for (unsigned operation = 2; operation < 4;
                                     operation++) {
                                    @autoreleasepool {
                                        fixture();
                                        PGRAPHState *pg = &state->pgraph;
                                        pg->surface_scale_factor = scale;
                                        g_config.display.quality.surface_scale =
                                            scale;
                                        const unsigned physical[] = {
                                            border ? 16u : 8u,
                                            border ? 16u : 8u, 1
                                        };
                                        const unsigned levels = 4,
                                                       stage = slot * 3;
                                        unsigned methodSlot = stage * 64;
                                        unsigned output =
                                            kind >= 2 ? (kind >= 3 ? 3 : 2) :
                                                        stage;
                                        unsigned requested =
                                            kind ? 2u << linear : 1;
                                        if (writerDevice !=
                                            surfaces.cache.commands.device) {
                                            writerDevice =
                                                surfaces.cache.commands.device;
                                            writer = [[NV2AMetalPixelShader
                                                alloc]
                                                initWithDevice:writerDevice
                                                   colorFormat:
                                                       MTLPixelFormatBGRA8Unorm
                                                   depthFormat:
                                                       MTLPixelFormatInvalid
                                                   sampleCount:1
                                                         error:&error];
                                            require(writer != nil, error);
                                        }
                                        cube_begin_gpu_write(
                                            writer, physical, levels, 0,
                                            signedHILO, scale, &gpuDraws,
                                            &gpuPixels);
                                        uint32_t format = 0;
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA,
                                            2);
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_COLOR,
                                            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16);
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                                            2);
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_CUBEMAP_ENABLE,
                                            1);
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                                            !border);
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS,
                                            levels);
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U,
                                            3);
                                        SET_MASK(
                                            format,
                                            NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V,
                                            3);
                                        uint32_t control =
                                            NV097_SET_TEXTURE_CONTROL0_ENABLE;
                                        SET_MASK(
                                            control,
                                            NV097_SET_TEXTURE_CONTROL0_MIN_LOD_CLAMP,
                                            first);
                                        SET_MASK(
                                            control,
                                            NV097_SET_TEXTURE_CONTROL0_MAX_LOD_CLAMP,
                                            levels - 1);
                                        if (kind)
                                            SET_MASK(
                                                control,
                                                NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                                linear + 1);
                                        unsigned filter =
                                            (kind   ? 6 :
                                             linear ? 2 :
                                                      1)
                                                << 16 |
                                            (kind || linear ? 2 : 1) << 24 |
                                            (kind ? 96u : 0u) |
                                            (signedHILO ? 0xf0000000u : 0);
                                        unsigned program =
                                            PS_TEXTUREMODES_CUBEMAP
                                            << (5 * stage);
                                        send_method(NV097_SET_TEXTURE_OFFSET +
                                                        methodSlot,
                                                    0);
                                        send_method(NV097_SET_TEXTURE_FORMAT +
                                                        methodSlot,
                                                    format);
                                        send_method(NV097_SET_TEXTURE_CONTROL0 +
                                                        methodSlot,
                                                    control);
                                        send_method(NV097_SET_TEXTURE_FILTER +
                                                        methodSlot,
                                                    filter);
                                        send_method(NV097_SET_TEXTURE_ADDRESS +
                                                        methodSlot,
                                                    3 | 3 << 8 | 3 << 16);
                                        if (kind >= 2) {
                                            if (kind == 4)
                                                cube_lookup_setup();
                                            else
                                                af_begin_lookup(kind == 3,
                                                                output);
                                            program |=
                                                PS_TEXTUREMODES_DOTPRODUCT
                                                    << 5 |
                                                (kind >= 3 ?
                                                     PS_TEXTUREMODES_DOTPRODUCT
                                                             << 10 |
                                                         (kind == 4 ?
                                                              PS_TEXTUREMODES_DOT_STR_CUBE :
                                                              PS_TEXTUREMODES_DOT_STR_3D)
                                                             << 15 :
                                                     PS_TEXTUREMODES_DOT_ST
                                                         << 10);
                                            send_method(
                                                NV097_SET_SHADER_OTHER_STAGE_INPUT,
                                                PS_DOTMAPPING_HILO_1 |
                                                    PS_DOTMAPPING_HILO_1 << 4 |
                                                    (kind >= 3 ?
                                                         PS_DOTMAPPING_HILO_1
                                                             << 8 :
                                                         0));
                                            const float vectors[][4] = {
                                                { .5, .25, .125, 1 },
                                                { .25, .5, .125, 1 },
                                                { .125, .125, .5, 1 }
                                            };
                                            for (unsigned i = 0;
                                                 i < (kind >= 3 ? 3u : 2u); i++)
                                                memcpy(
                                                    pg->vertex_attributes[10 +
                                                                          i]
                                                        .inline_value,
                                                    vectors[i],
                                                    sizeof(vectors[i]));
                                        }
                                        if (kind == 4)
                                            cube_lookup_vectors(face);
                                        send_method(
                                            NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                        send_method(
                                            NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                            PS_REGISTER_T0 + output);
                                        send_method(
                                            NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                            (PS_REGISTER_T0 + output |
                                             PS_CHANNEL_ALPHA)
                                                << 8);
                                        double a = 2 * positions[profile %
                                                                 ARRAY_SIZE(
                                                                     positions)]
                                                                [0] -
                                                   1,
                                               b = 2 * positions[profile %
                                                                 ARRAY_SIZE(
                                                                     positions)]
                                                                [1] -
                                                   1;
                                        const double directions[][3] = {
                                            { 1, -b, -a }, { -1, -b, a },
                                            { a, 1, b },   { a, -1, -b },
                                            { a, -b, 1 },  { -a, -b, -1 }
                                        };
                                        for (unsigned axis = 0; axis < 3;
                                             axis++)
                                            pg->vertex_attributes[9 + stage]
                                                .inline_value[axis] =
                                                directions[face][axis];
                                        if (kind)
                                            cube_af_vertices(face, first,
                                                             profile, stage);
                                        begin(PRIM_TYPE_TRIANGLES);
                                        unsigned pending = operation & 1;
                                        if (pending)
                                            arrays(0, 3);
                                        renderer.ops.pre_savevm_trigger(state);
                                        process_pending();
                                        renderer.ops.pre_savevm_wait(state);
                                        assert(pg->draw_arrays_length ==
                                               pending);
                                        NSData *frozen = [NSData
                                            dataWithBytes:
                                                pg->metal4_begin_capture
                                                   length:
                                                       pg->
                                                       metal4_begin_capture_size];
                                        cube_begin_check_capture(
                                            frozen, physical, first, levels, 0,
                                            signedHILO, stage, output, &texels);
                                        if (kind == 4) {
                                            unsigned lookupRecord =
                                                cube_lookup_check_capture(
                                                    frozen, 0, &lookupTexels);
                                            unsigned lookupPixel =
                                                48 + 100 +
                                                offsetof(NV2AMetalPixelUniforms,
                                                         textures) +
                                                3 * sizeof(
                                                        NV2AMetalTextureStage);
                                            const unsigned offsets[] = {
                                                offsetof(NV2AMetalTextureStage,
                                                         dimension),
                                                offsetof(NV2AMetalTextureStage,
                                                         cubemap)
                                            };
                                            for (unsigned part = 0; part < 2;
                                                 part++)
                                                for (unsigned field = 0;
                                                     field < 2; field++) {
                                                    NSMutableData *bad =
                                                        [frozen mutableCopy];
                                                    stl_be_p(
                                                        (uint8_t *)bad
                                                                .mutableBytes +
                                                            (part ?
                                                                 lookupRecord :
                                                                 lookupPixel) +
                                                            offsets[field],
                                                        field ? 0 : 3);
                                                    assert(
                                                        !pgraph_metal4_validate_begin_capture(
                                                            bad.bytes,
                                                            bad.length));
                                                    lookupRejects++;
                                                }
                                        }
                                        unsigned pixel =
                                            48 + 100 +
                                            offsetof(NV2AMetalPixelUniforms,
                                                     textures) +
                                            stage *
                                                sizeof(NV2AMetalTextureStage);
                                        unsigned record =
                                            48 +
                                            (uint32_t)ldl_be_p(
                                                (const uint8_t *)frozen.bytes +
                                                40) +
                                            12 + 16;
                                        for (unsigned part = 0; part < 2;
                                             part++) {
                                            NSMutableData *bad =
                                                [frozen mutableCopy];
                                            stl_be_p(
                                                (uint8_t *)bad.mutableBytes +
                                                    (part ? record : pixel) +
                                                    offsetof(
                                                        NV2AMetalTextureStage,
                                                        signed_channels),
                                                signedHILO ? 0 : 15);
                                            assert(
                                                !pgraph_metal4_validate_begin_capture(
                                                    bad.bytes, bad.length));
                                            rejects++;
                                        }
                                        if (kind) {
                                            for (unsigned part = 0; part < 2;
                                                 part++) {
                                                unsigned base =
                                                    part ? record : pixel;
                                                unsigned offset =
                                                    offsetof(
                                                        NV2AMetalTextureStage,
                                                        sampling) +
                                                    offsetof(
                                                        NV2AMetalSamplingUniforms,
                                                        anisotropy);
                                                assert((uint32_t)ldl_be_p(
                                                           (const uint8_t *)
                                                               frozen.bytes +
                                                           base + offset) ==
                                                       requested);
                                                NSMutableData *bad =
                                                    [frozen mutableCopy];
                                                stl_be_p((uint8_t *)bad
                                                                 .mutableBytes +
                                                             base + offset,
                                                         1);
                                                assert(
                                                    !pgraph_metal4_validate_begin_capture(
                                                        bad.bytes, bad.length));
                                                afRejects++;
                                            }
                                        }
                                        send_method(NV097_SET_TEXTURE_FORMAT +
                                                        methodSlot,
                                                    127u << 8);
                                        send_method(NV097_SET_TEXTURE_FILTER +
                                                        methodSlot,
                                                    1 << 16 | 1 << 24);
                                        send_method(
                                            NV097_SET_SHADER_STAGE_PROGRAM,
                                            PS_TEXTUREMODES_PASSTHRU
                                                << (5 * stage));
                                        cube_begin_gpu_write(
                                            writer, physical, levels, 1,
                                            signedHILO, scale, &gpuDraws,
                                            &gpuPixels);
                                        if (kind == 4)
                                            cube_lookup_write(1);
                                        renderer.ops.pre_savevm_trigger(state);
                                        process_pending();
                                        renderer.ops.pre_savevm_wait(state);
                                        assert([frozen
                                            isEqualToData:
                                                [NSData
                                                    dataWithBytes:
                                                        pg->metal4_begin_capture
                                                           length:
                                                               pg->
                                                               metal4_begin_capture_size]]);
                                        canonical++;
                                        int fd = new_vertex_snapshot_file();
                                        save_snapshot_parent(
                                            fd, &array_snapshot_parent);
                                        NSData *ram = [NSData
                                            dataWithBytes:state->vram_ptr
                                                   length:65536];
                                        for (unsigned pass = 0;
                                             pass < operation - 1; pass++) {
                                            if (!pending)
                                                arrays(0, 3);
                                            end();
                                            before_ram_load();
                                            memcpy(state->vram_ptr, ram.bytes,
                                                   ram.length);
                                            assert(
                                                load_snapshot_parent(
                                                    fd,
                                                    &array_snapshot_parent) ==
                                                0);
                                            after_ram_load();
                                            assert(pg->draw_arrays_length ==
                                                   pending);
                                            qemu_mutex_lock(&pg->lock);
                                            renderer.ops.flush_draw(state);
                                            qemu_mutex_unlock(&pg->lock);
                                            assert(pg->draw_arrays_length ==
                                                   pending);
                                            close(fd);
                                            restores++;
                                            pendingRestores += pending;
                                            renderer.ops.pre_savevm_trigger(
                                                state);
                                            process_pending();
                                            renderer.ops.pre_savevm_wait(state);
                                            assert([frozen
                                                isEqualToData:
                                                    [NSData
                                                        dataWithBytes:
                                                            pg->metal4_begin_capture
                                                               length:
                                                                   pg->
                                                                   metal4_begin_capture_size]]);
                                            canonical++;
                                            if (pass + 1 < operation - 1) {
                                                fd = new_vertex_snapshot_file();
                                                save_snapshot_parent(
                                                    fd, &array_snapshot_parent);
                                                ram = [NSData
                                                    dataWithBytes:state
                                                                      ->vram_ptr
                                                           length:65536];
                                            }
                                        }
                                        cpu_write(1024, 256);
                                        for (unsigned i = 0; i < 64; i++)
                                            stl_le_p(state->vram_ptr + 1024 +
                                                         4 * i,
                                                     0xffff0000);
                                        if (!pending)
                                            arrays(0, 3);
                                        end();
                                        uint32_t outputs[4][64];
                                        NSData *previous = frozen;
                                        for (unsigned phase = 0; phase < phases;
                                             phase++) {
                                            double expected[4];
                                            if (!kind)
                                                cube_begin_reference(
                                                    physical, first, face,
                                                    positions[profile], border,
                                                    linear, phase, signedHILO,
                                                    expected);
                                            for (unsigned y = 0; y < 8; y++)
                                                for (unsigned x = 0; x < 8;
                                                     x++) {
                                                    uint32_t actual =
                                                        color(x, y);
                                                    outputs[phase][y * 8 + x] =
                                                        actual;
                                                    if ((x + y) * scale + 1 <
                                                        8 * scale) {
                                                        if (kind) {
                                                            unsigned taps,
                                                                selected,
                                                                lookup = 0;
                                                            cube_af_reference(
                                                                physical, first,
                                                                levels, face,
                                                                profile, scale,
                                                                requested, kind,
                                                                border, phase,
                                                                signedHILO, x,
                                                                y, expected,
                                                                &taps,
                                                                &selected,
                                                                &lookup);
                                                            if (kind == 4)
                                                                lookupFaces |=
                                                                    1u
                                                                    << lookup;
                                                            tapPixels[taps -
                                                                      1]++;
                                                            selectedFaces |=
                                                                1u << selected;
                                                            changedFaces +=
                                                                selected !=
                                                                face;
                                                        }
                                                        const unsigned
                                                            shifts[] = { 16, 8,
                                                                         0,
                                                                         24 };
                                                        for (unsigned channel =
                                                                 0;
                                                             channel < 4;
                                                             channel++) {
                                                            int low = MAX(
                                                                0,
                                                                (int)floor(
                                                                    expected
                                                                        [channel] +
                                                                    .5 - .002));
                                                            int high = MIN(
                                                                255,
                                                                (int)floor(
                                                                    expected
                                                                        [channel] +
                                                                    .5 + .002));
                                                            unsigned byte =
                                                                actual >>
                                                                    shifts
                                                                        [channel] &
                                                                255;
                                                            if (byte <
                                                                    (unsigned)
                                                                        low ||
                                                                byte >
                                                                    (unsigned)
                                                                        high) {
                                                                fprintf(
                                                                    stderr,
                                                                    "GPU Cube "
                                                                    "kind%u "
                                                                    "Begin "
                                                                    "signed%u "
                                                                    "border%u "
                                                                    "first%u "
                                                                    "stage%u "
                                                                    "linear%u "
                                                                    "scale%u "
                                                                    "face%u "
                                                                    "profile%u "
                                                                    "op%u "
                                                                    "phase%u "
                                                                    "pixel%u,%"
                                                                    "u "
                                                                    "channel%u:"
                                                                    "%u "
                                                                    "expected%."
                                                                    "9g "
                                                                    "[%d,%d]\n",
                                                                    kind,
                                                                    signedHILO,
                                                                    border,
                                                                    first,
                                                                    stage,
                                                                    linear,
                                                                    scale, face,
                                                                    profile,
                                                                    operation,
                                                                    phase, x, y,
                                                                    channel,
                                                                    byte,
                                                                    expected
                                                                        [channel],
                                                                    low, high);
                                                                abort();
                                                            }
                                                            ambiguous +=
                                                                low != high;
                                                            channels++;
                                                        }
                                                    } else
                                                        assert(actual ==
                                                               0xffff0000);
                                                    pixels++;
                                                }
                                            unsigned faceLength =
                                                cube_begin_face_length(physical,
                                                                       levels);
                                            unsigned stride = ROUND_UP(
                                                faceLength,
                                                NV2A_CUBEMAP_FACE_ALIGNMENT);
                                            for (unsigned f = 0; f < 6; f++)
                                                for (unsigned i = faceLength;
                                                     i < stride; i++) {
                                                    assert(
                                                        state->vram_ptr
                                                            [24576 +
                                                             f * stride + i] ==
                                                        0xd3);
                                                    padding++;
                                                }
                                            if (phase + 1 < phases) {
                                                if (phase == 2)
                                                    cube_lookup_write(2);
                                                if (phase == 1)
                                                    cube_begin_gpu_write(
                                                        writer, physical,
                                                        levels, 2, signedHILO,
                                                        scale, &gpuDraws,
                                                        &gpuPixels);
                                                cpu_write(1024, 256);
                                                for (unsigned i = 0; i < 64;
                                                     i++)
                                                    stl_le_p(state->vram_ptr +
                                                                 1024 + 4 * i,
                                                             0xffff0000);
                                                send_method(
                                                    NV097_SET_TEXTURE_FORMAT +
                                                        methodSlot,
                                                    format);
                                                send_method(
                                                    NV097_SET_TEXTURE_FILTER +
                                                        methodSlot,
                                                    filter);
                                                send_method(
                                                    NV097_SET_SHADER_STAGE_PROGRAM,
                                                    program);
                                                begin(PRIM_TYPE_TRIANGLES);
                                                require(
                                                    [surfaces.cache
                                                        submitWithError:
                                                            &error] &&
                                                        [surfaces.cache
                                                            waitUntilIdleWithError:
                                                                &error],
                                                    error);
                                                NSData *fresh = [draw
                                                    beginSnapshotWithError:
                                                        &error];
                                                require(fresh != nil, error);
                                                assert(![fresh
                                                    isEqualToData:previous]);
                                                cube_begin_check_capture(
                                                    fresh, physical, first,
                                                    levels, MIN(phase + 1, 2u),
                                                    signedHILO, stage, output,
                                                    &texels);
                                                if (kind == 4)
                                                    cube_lookup_check_capture(
                                                        fresh,
                                                        phase == 2 ? 2 : 1,
                                                        &lookupTexels);
                                                previous = fresh;
                                                arrays(0, 3);
                                                end();
                                                nextBegins++;
                                            }
                                        }
                                        assert(memcmp(outputs[0], outputs[1],
                                                      sizeof(outputs[0])) &&
                                               memcmp(outputs[1], outputs[2],
                                                      sizeof(outputs[1])));
                                        if (kind == 4)
                                            assert(memcmp(outputs[2],
                                                          outputs[3],
                                                          sizeof(outputs[2])));
                                        changed += phases - 1;
                                        faces |= 1u << face;
                                        cases++;
                                    }
                                }
    assert(cases == count && restores == count * 3 / 2 &&
           pendingRestores == count && canonical == count * 5 / 2 &&
           pixels == count * 64 * phases &&
           nextBegins == count * (phases - 1) &&
           changed == count * (phases - 1) && rejects == count * 2 &&
           faces == 63 && gpuDraws == count * 72 &&
           gpuPixels == count * 9562.5 && texels == count * 795 * phases &&
           padding == count * 276 * phases && channels == count * 128 * phases);
    if (kind) {
        assert(afRejects == count * 2 && selectedFaces == 63 && changedFaces &&
               tapPixels[1] && tapPixels[3] && tapPixels[7]);
        printf("Metal4 GPU Cube AF kind%u signed%u: %u cases/%u restores/%u "
               "pending/%u canonical/%u pixels/%u fresh/%u changed/%u signed "
               "rejects/%u AF rejects/%u texels/%u GPU draws/%u GPU pixels/%u "
               "padding/%u channels/%u ambiguous/%u changed faces PASS\n",
               kind, signedHILO, cases, restores, pendingRestores, canonical,
               pixels, nextBegins, changed, rejects, afRejects, texels,
               gpuDraws, gpuPixels, padding, channels, ambiguous, changedFaces);
        if (kind == 4) {
            assert(lookupTexels == count * 384 * phases &&
                   lookupRejects == count * 4 && lookupFaces == 63);
            printf("Cube lookup: %u texels/%u dimension-cubemap rejects/all "
                   "six faces PASS\n",
                   lookupTexels, lookupRejects);
        }
        printf("Cube AF taps1..8:");
        for (unsigned i = 0; i < 8; i++)
            printf(" %u", tapPixels[i]);
        printf("\n");
    } else
        printf(
            "Metal4 GPU Cube HILO16 Begin: signed%u %u cases/%u partial "
            "restores/%u pending restores/%u canonical resaves/%u raw "
            "pixels/%u "
            "fresh Begins/%u changed outputs/%u signed rejects/%u captured "
            "texels/%u GPU draws/%u GPU pixels/%u padding bytes/%u channels/%u "
            "ambiguous PASS\n",
            signedHILO, cases, restores, pendingRestores, canonical, pixels,
            nextBegins, changed, rejects, texels, gpuDraws, gpuPixels, padding,
            channels, ambiguous);
    groups++;
}

static uint32_t brdf_cube_lookup_word(unsigned x, unsigned y, unsigned z,
                                      unsigned phase)
{
    return 0xff000000u | (16 + 24 * x + 7 * phase) << 16 |
           (24 + 24 * y + 11 * phase) << 8 | (32 + 24 * z + 13 * phase);
}
static void brdf_cube_lookup_write(unsigned source, unsigned phase)
{
    const unsigned size[] = { 8, 8, 8 };
    cpu_write(source, 2048);
    for (unsigned z = 0; z < 8; z++)
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++)
                stl_le_p(state->vram_ptr + source +
                             4 * border_begin_morton(x, y, z, size),
                         brdf_cube_lookup_word(x, y, z, phase));
}
static void brdf_cube_source_setup(unsigned input, unsigned stage, bool border,
                                   unsigned first, unsigned kernel,
                                   BOOL signedHILO, uint32_t *format,
                                   unsigned *filter)
{
    *format = 0;
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_COLOR,
             NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 2);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_CUBEMAP_ENABLE, 1);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE, !border);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 4);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U, 3);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V, 3);
    uint32_t control = NV097_SET_TEXTURE_CONTROL0_ENABLE;
    SET_MASK(control, NV097_SET_TEXTURE_CONTROL0_MIN_LOD_CLAMP, first);
    SET_MASK(control, NV097_SET_TEXTURE_CONTROL0_MAX_LOD_CLAMP, 3);
    SET_MASK(control, NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY, kernel + 1);
    *filter = 6 << 16 | 2 << 24 | 96 | (signedHILO ? 0xf0000000u : 0);
    send_method(NV097_SET_TEXTURE_OFFSET + stage * 64, input * 12288);
    send_method(NV097_SET_TEXTURE_FORMAT + stage * 64, *format);
    send_method(NV097_SET_TEXTURE_CONTROL0 + stage * 64, control);
    send_method(NV097_SET_TEXTURE_FILTER + stage * 64, *filter);
    send_method(NV097_SET_TEXTURE_ADDRESS + stage * 64, 3 | 3 << 8 | 3 << 16);
}
static void brdf_volume_source_setup(unsigned input, unsigned stage,
                                     const unsigned core[3], bool border,
                                     unsigned first, unsigned kernel,
                                     BOOL signedHILO, uint32_t *format,
                                     unsigned *filter)
{
    *format = 0;
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_COLOR,
             NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 3);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE, !border);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 4);
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U, ctz32(core[0]));
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V, ctz32(core[1]));
    SET_MASK(*format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_P, ctz32(core[2]));
    uint32_t control = NV097_SET_TEXTURE_CONTROL0_ENABLE;
    SET_MASK(control, NV097_SET_TEXTURE_CONTROL0_MIN_LOD_CLAMP, first);
    SET_MASK(control, NV097_SET_TEXTURE_CONTROL0_MAX_LOD_CLAMP, 3);
    SET_MASK(control, NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY, kernel + 1);
    *filter = 6 << 16 | 2 << 24 | 96 | (signedHILO ? 0xf0000000u : 0);
    send_method(NV097_SET_TEXTURE_OFFSET + stage * 64, input * 20480);
    send_method(NV097_SET_TEXTURE_FORMAT + stage * 64, *format);
    send_method(NV097_SET_TEXTURE_CONTROL0 + stage * 64, control);
    send_method(NV097_SET_TEXTURE_FILTER + stage * 64, *filter);
    send_method(NV097_SET_TEXTURE_ADDRESS + stage * 64, 1 | 1 << 8 | 1 << 16);
}
static void brdf_begin_gpu_write(NV2AMetalPixelShader *writer,
                                 const unsigned physical[3], BOOL volume,
                                 unsigned input, unsigned phase,
                                 BOOL signedHILO, unsigned scale,
                                 unsigned *draws, unsigned *pixels)
{
    if (volume)
        af_begin_gpu_write_at(writer, physical, 4, false, phase, signedHILO,
                              scale, 24576 + input * 20480, !phase, draws,
                              pixels);
    else
        cube_begin_gpu_write_at(writer, physical, 4, phase, signedHILO, scale,
                                24576 + input * 12288, draws, pixels);
}
static void brdf_begin_check_capture(NSData *capture, BOOL volume,
                                     const unsigned physical[3], unsigned first,
                                     unsigned stage, unsigned combination,
                                     unsigned requested,
                                     const unsigned phase[3], bool reject,
                                     unsigned *sourceTexels,
                                     unsigned *lookupTexels, unsigned *rejects)
{
    assert(pgraph_metal4_validate_begin_capture(capture.bytes, capture.length));
    const uint8_t *bytes = capture.bytes;
    unsigned start = 48 + (uint32_t)ldl_be_p(bytes + 40), record = start + 12;
    assert((uint32_t)ldl_be_p(bytes + start + 8) == (7u << stage) &&
           (uint32_t)ldl_be_p(bytes + 48 + 100 +
                              offsetof(NV2AMetalPixelUniforms, hilo16_mask)) ==
               (3u << stage));
    for (unsigned input = 0; input < 3; input++) {
        bool lookup = input == 2;
        unsigned pixel = 48 + 100 + offsetof(NV2AMetalPixelUniforms, textures) +
                         (stage + input) * sizeof(NV2AMetalTextureStage);
        const uint8_t *image = bytes + record + 220;
        assert((uint32_t)ldl_be_p(bytes + record) == stage + input);
        unsigned view = first ^ input;
        BOOL signedHILO = (combination >> input) & 1;
        assert((uint32_t)ldl_be_p(image + 8) == (lookup || volume ? 2u : 3u) &&
               (uint32_t)ldl_be_p(image + 12) ==
                   (lookup ? 8u : physical[0] >> view) &&
               (uint32_t)ldl_be_p(image + 16) ==
                   (lookup ? 8u : physical[1] >> view) &&
               (uint32_t)ldl_be_p(image + 20) ==
                   (lookup ? 8u :
                    volume ? MAX(1u, physical[2] >> view) :
                             1u) &&
               (uint32_t)ldl_be_p(image + 24) == (lookup ? 1u : 4 - view));
        const unsigned fields[] = {
            offsetof(NV2AMetalTextureStage, dimension),
            offsetof(NV2AMetalTextureStage, cubemap),
            offsetof(NV2AMetalTextureStage, signed_channels),
            offsetof(NV2AMetalTextureStage, sampling) +
                offsetof(NV2AMetalSamplingUniforms, anisotropy)
        };
        const unsigned expected[] = { lookup || volume ? 3u : 2u,
                                      !lookup && !volume,
                                      !lookup && signedHILO ? 15u : 0,
                                      lookup ? 1u : requested };
        for (unsigned part = 0; part < 2; part++)
            for (unsigned field = 0; field < 4; field++) {
                unsigned offset = (part ? record + 16 : pixel) + fields[field];
                assert((uint32_t)ldl_be_p(bytes + offset) == expected[field]);
                if (reject &&
                    ((lookup && field < 2) || (!lookup && field >= 2))) {
                    NSMutableData *bad = [capture mutableCopy];
                    stl_be_p((uint8_t *)bad.mutableBytes + offset,
                             lookup     ? (field ? 1 : 2) :
                             field == 2 ? (signedHILO ? 0 : 15) :
                                          1);
                    assert(!pgraph_metal4_validate_begin_capture(bad.bytes,
                                                                 bad.length));
                    rejects[lookup ? 2 : field - 2]++;
                }
            }
        if (!lookup)
            af_begin_check_image_capture(image, physical, view, 4, phase[input],
                                         signedHILO, !volume, sourceTexels);
        else {
            unsigned storage;
            const uint8_t *data = af_begin_image_payload(image, &storage);
            assert(storage == NV2AMetalTextureStorageFloat32 ||
                   storage == NV2AMetalTextureStorageUnorm8);
            unsigned bytesPerTexel =
                storage == NV2AMetalTextureStorageUnorm8 ? 4 : 16;
            assert((uint32_t)ldl_be_p(image + 28) == 0 &&
                   (uint32_t)ldl_be_p(image + 32) == 512 * bytesPerTexel);
            for (unsigned z = 0; z < 8; z++)
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        uint32_t word =
                            brdf_cube_lookup_word(x, y, z, phase[2]);
                        af_begin_check_rgba_texel(&data, storage, word);
                        (*lookupTexels)++;
                    }
            assert((uint64_t)(data - af_begin_image_payload(image, &storage)) ==
                   512 * bytesPerTexel);
        }
        assert((uint32_t)ldl_be_p(bytes + record + 8) == (lookup ? 0u : 8u));
        record += 220 + (uint32_t)ldl_be_p(bytes + record + 12);
    }
    assert(record == start + (uint32_t)ldl_be_p(bytes + 44) &&
           record + NV2AMetalSurfaceBindingsBytes == capture.length);
}
static void brdf_cube_reference(const double eye[4], const double light[4],
                                unsigned phase, double result[4])
{
    double coordinate[] = { eye[0], light[0], light[1] - eye[1] };
    int base[3];
    double fraction[3];
    for (unsigned axis = 0; axis < 3; axis++) {
        double position = 8 * coordinate[axis] - .5;
        base[axis] = floor(position);
        fraction[axis] = position - base[axis];
    }
    result[0] = result[1] = result[2] = 0;
    const unsigned shifts[] = { 16, 8, 0 };
    for (unsigned corner = 0; corner < 8; corner++) {
        unsigned index[3];
        double weight = 1;
        for (unsigned axis = 0; axis < 3; axis++) {
            unsigned high = (corner >> axis) & 1;
            int sample = base[axis] + (int)high;
            index[axis] =
                axis == 2 ? ((sample % 8) + 8) % 8 : MAX(0, MIN(7, sample));
            weight *= high ? fraction[axis] : 1 - fraction[axis];
        }
        uint32_t word =
            brdf_cube_lookup_word(index[0], index[1], index[2], phase);
        for (unsigned channel = 0; channel < 3; channel++)
            result[channel] += weight * (word >> shifts[channel] & 255);
    }
    result[3] = 255;
}
static void hilo16_gpu_brdf_begin_snapshot(BOOL volume, unsigned combination)
{
    assert(combination < 4);
    const unsigned generations[5][3] = {
        { 0, 0, 0 }, { 1, 1, 1 }, { 2, 1, 1 }, { 2, 2, 1 }, { 2, 2, 2 }
    };
    unsigned cases = 0, restores = 0, pending = 0, canonical = 0;
    unsigned pixels = 0, channels = 0, ambiguous = 0, freshBegins = 0;
    unsigned sourceTexels = 0, lookupTexels = 0, rejects[3] = {};
    unsigned gpuDraws = 0, gpuPixels = 0, padding = 0;
    unsigned independent[3] = {}, selectedFaces[2] = {}, changedFaces[2] = {};
    unsigned tapPixels[8] = {}, negativeDelta = 0;
    NV2AMetalPixelShader *writer = nil;
    id<MTLDevice> device = nil;
    NSError *error = nil;
    for (unsigned border = 0; border < 2; border++)
        for (unsigned first = 0; first < 2; first++)
            for (unsigned stage = 0; stage < 2; stage++)
                for (unsigned kernel = 0; kernel < 3; kernel++)
                    for (unsigned scale = 1; scale <= 2; scale++)
                        for (unsigned face = 0; face < (volume ? 2u : 6u);
                             face++)
                            for (unsigned profile = 0; profile < 4; profile++)
                                for (unsigned operation = 2; operation < 4;
                                     operation++) {
                                    @autoreleasepool {
                                        fixture();
                                        PGRAPHState *pg = &state->pgraph;
                                        pg->surface_scale_factor = scale;
                                        g_config.display.quality.surface_scale =
                                            scale;
                                        const unsigned core[] = {
                                            volume && face ? 2u : 8u,
                                            volume ? 4u : 8u,
                                            volume ? (face ? 8u : 2u) : 1u
                                        };
                                        const unsigned physical[] = {
                                            border ? 16u : core[0],
                                            border ? 16u : core[1],
                                            volume ? (border ? 16u : core[2]) :
                                                     1u
                                        };
                                        unsigned output = stage + 2,
                                                 requested = 2u << kernel;
                                        if (device !=
                                            surfaces.cache.commands.device) {
                                            device =
                                                surfaces.cache.commands.device;
                                            writer = [[NV2AMetalPixelShader
                                                alloc]
                                                initWithDevice:device
                                                   colorFormat:
                                                       MTLPixelFormatBGRA8Unorm
                                                   depthFormat:
                                                       MTLPixelFormatInvalid
                                                   sampleCount:1
                                                         error:&error];
                                            require(writer != nil, error);
                                        }
                                        uint32_t format[2];
                                        unsigned filter[2];
                                        unsigned program = PS_TEXTUREMODES_BRDF
                                                           << (5 * output);
                                        for (unsigned input = 0; input < 2;
                                             input++) {
                                            BOOL signedHILO =
                                                (combination >> input) & 1;
                                            brdf_begin_gpu_write(
                                                writer, physical, volume, input,
                                                0, signedHILO, scale, &gpuDraws,
                                                &gpuPixels);
                                            if (volume)
                                                brdf_volume_source_setup(
                                                    input, stage + input, core,
                                                    border, first ^ input,
                                                    kernel, signedHILO,
                                                    &format[input],
                                                    &filter[input]);
                                            else
                                                brdf_cube_source_setup(
                                                    input, stage + input,
                                                    border, first ^ input,
                                                    kernel, signedHILO,
                                                    &format[input],
                                                    &filter[input]);
                                            program |=
                                                (volume ?
                                                     PS_TEXTUREMODES_PROJECT3D :
                                                     PS_TEXTUREMODES_CUBEMAP)
                                                << (5 * (stage + input));
                                            if (volume)
                                                af_begin_vertices(
                                                    core, physical,
                                                    first ^ input, false,
                                                    border, stage + input,
                                                    (profile + input) % 4);
                                            else
                                                cube_af_vertices_at(
                                                    (face + input * 3) % 6,
                                                    first ^ input,
                                                    (profile + input) % 4,
                                                    stage + input,
                                                    256 + input * 256);
                                        }
                                        unsigned lookup = volume ? 8192 : 49152;
                                        af_begin_lookup_at(YES, output, lookup);
                                        brdf_cube_lookup_write(lookup, 0);
                                        send_method(NV097_SET_TEXTURE_ADDRESS +
                                                        output * 64,
                                                    3 | 3 << 8 | 1 << 16);
                                        send_method(
                                            NV097_SET_SHADER_STAGE_PROGRAM,
                                            program);
                                        send_method(
                                            NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                            PS_REGISTER_T0 + output);
                                        send_method(
                                            NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                            (PS_REGISTER_T0 + output |
                                             PS_CHANNEL_ALPHA)
                                                << 8);
                                        begin(PRIM_TYPE_TRIANGLES);
                                        unsigned queued = operation & 1;
                                        if (queued)
                                            arrays(0, 3);
                                        renderer.ops.pre_savevm_trigger(state);
                                        process_pending();
                                        renderer.ops.pre_savevm_wait(state);
                                        assert(pg->draw_arrays_length ==
                                               queued);
                                        NSData *frozen = [NSData
                                            dataWithBytes:
                                                pg->metal4_begin_capture
                                                   length:
                                                       pg->
                                                       metal4_begin_capture_size];
                                        brdf_begin_check_capture(
                                            frozen, volume, physical, first,
                                            stage, combination, requested,
                                            generations[0], true, &sourceTexels,
                                            &lookupTexels, rejects);
                                        for (unsigned input = 0; input < 2;
                                             input++) {
                                            send_method(
                                                NV097_SET_TEXTURE_FORMAT +
                                                    (stage + input) * 64,
                                                127u << 8);
                                            send_method(
                                                NV097_SET_TEXTURE_FILTER +
                                                    (stage + input) * 64,
                                                1 << 16 | 1 << 24);
                                            brdf_begin_gpu_write(
                                                writer, physical, volume, input,
                                                1, (combination >> input) & 1,
                                                scale, &gpuDraws, &gpuPixels);
                                        }
                                        send_method(
                                            NV097_SET_SHADER_STAGE_PROGRAM,
                                            PS_TEXTUREMODES_PASSTHRU
                                                << (5 * output));
                                        brdf_cube_lookup_write(lookup, 1);
                                        renderer.ops.pre_savevm_trigger(state);
                                        process_pending();
                                        renderer.ops.pre_savevm_wait(state);
                                        assert([frozen
                                            isEqualToData:
                                                [NSData
                                                    dataWithBytes:
                                                        pg->metal4_begin_capture
                                                           length:
                                                               pg->
                                                               metal4_begin_capture_size]]);
                                        canonical++;
                                        int fd = new_vertex_snapshot_file();
                                        save_snapshot_parent(
                                            fd, &array_snapshot_parent);
                                        NSData *ram = [NSData
                                            dataWithBytes:state->vram_ptr
                                                   length:65536];
                                        for (unsigned pass = 0;
                                             pass < operation - 1; pass++) {
                                            if (!queued)
                                                arrays(0, 3);
                                            end();
                                            before_ram_load();
                                            memcpy(state->vram_ptr, ram.bytes,
                                                   ram.length);
                                            assert(
                                                load_snapshot_parent(
                                                    fd,
                                                    &array_snapshot_parent) ==
                                                0);
                                            after_ram_load();
                                            assert(pg->draw_arrays_length ==
                                                   queued);
                                            qemu_mutex_lock(&pg->lock);
                                            renderer.ops.flush_draw(state);
                                            qemu_mutex_unlock(&pg->lock);
                                            assert(pg->draw_arrays_length ==
                                                   queued);
                                            close(fd);
                                            restores++;
                                            pending += queued;
                                            renderer.ops.pre_savevm_trigger(
                                                state);
                                            process_pending();
                                            renderer.ops.pre_savevm_wait(state);
                                            assert([frozen
                                                isEqualToData:
                                                    [NSData
                                                        dataWithBytes:
                                                            pg->metal4_begin_capture
                                                               length:
                                                                   pg->
                                                                   metal4_begin_capture_size]]);
                                            canonical++;
                                            if (pass + 1 < operation - 1) {
                                                fd = new_vertex_snapshot_file();
                                                save_snapshot_parent(
                                                    fd, &array_snapshot_parent);
                                                ram = [NSData
                                                    dataWithBytes:state
                                                                      ->vram_ptr
                                                           length:65536];
                                            }
                                        }
                                        cpu_write(1024, 256);
                                        for (unsigned i = 0; i < 64; i++)
                                            stl_le_p(state->vram_ptr + 1024 +
                                                         4 * i,
                                                     0xffff0000);
                                        if (!queued)
                                            arrays(0, 3);
                                        end();
                                        uint32_t outputs[5][64];
                                        NSData *previous = frozen;
                                        for (unsigned phase = 0; phase < 5;
                                             phase++) {
                                            for (unsigned y = 0; y < 8; y++)
                                                for (unsigned x = 0; x < 8;
                                                     x++) {
                                                    uint32_t actual =
                                                        color(x, y);
                                                    outputs[phase][8 * y + x] =
                                                        actual;
                                                    if ((x + y) * scale + 1 <
                                                        8 * scale) {
                                                        double values[2][4],
                                                            expected[4];
                                                        for (unsigned input = 0;
                                                             input < 2;
                                                             input++) {
                                                            unsigned taps,
                                                                selected,
                                                                ignored;
                                                            unsigned inputFace =
                                                                (face +
                                                                 input * 3) %
                                                                6;
                                                            if (volume) {
                                                                af_begin_reference(
                                                                    physical,
                                                                    first ^
                                                                        input,
                                                                    4, false,
                                                                    (profile +
                                                                     input) %
                                                                        4,
                                                                    scale,
                                                                    requested,
                                                                    generations
                                                                        [phase]
                                                                        [input],
                                                                    (combination >>
                                                                     input) &
                                                                        1,
                                                                    2, NO, x, y,
                                                                    values
                                                                        [input],
                                                                    &taps);
                                                                selected =
                                                                    inputFace;
                                                            } else
                                                                cube_af_reference(
                                                                    physical,
                                                                    first ^
                                                                        input,
                                                                    4,
                                                                    inputFace,
                                                                    (profile +
                                                                     input) %
                                                                        4,
                                                                    scale,
                                                                    requested,
                                                                    5, border,
                                                                    generations
                                                                        [phase]
                                                                        [input],
                                                                    (combination >>
                                                                     input) &
                                                                        1,
                                                                    x, y,
                                                                    values
                                                                        [input],
                                                                    &taps,
                                                                    &selected,
                                                                    &ignored);
                                                            tapPixels[taps -
                                                                      1]++;
                                                            selectedFaces
                                                                [input] |=
                                                                1u << selected;
                                                            changedFaces
                                                                [input] +=
                                                                selected !=
                                                                inputFace;
                                                        }
                                                        negativeDelta +=
                                                            values[1][1] <
                                                            values[0][1];
                                                        brdf_cube_reference(
                                                            values[0],
                                                            values[1],
                                                            generations[phase]
                                                                       [2],
                                                            expected);
                                                        const unsigned
                                                            shifts[] = { 16, 8,
                                                                         0,
                                                                         24 };
                                                        for (unsigned channel =
                                                                 0;
                                                             channel < 4;
                                                             channel++) {
                                                            int low = MAX(
                                                                0,
                                                                (int)floor(
                                                                    expected
                                                                        [channel] +
                                                                    .5 - .002));
                                                            int high = MIN(
                                                                255,
                                                                (int)floor(
                                                                    expected
                                                                        [channel] +
                                                                    .5 + .002));
                                                            unsigned byte =
                                                                actual >>
                                                                    shifts
                                                                        [channel] &
                                                                255;
                                                            if (byte <
                                                                    (unsigned)
                                                                        low ||
                                                                byte >
                                                                    (unsigned)
                                                                        high) {
                                                                fprintf(
                                                                    stderr,
                                                                    "GPU %s "
                                                                    "BRDF "
                                                                    "combo%u "
                                                                    "border%u "
                                                                    "first%u "
                                                                    "stage%u "
                                                                    "AF%u "
                                                                    "scale%u "
                                                                    "face%u "
                                                                    "profile%u "
                                                                    "op%u "
                                                                    "phase%u "
                                                                    "pixel%u,%"
                                                                    "u "
                                                                    "channel%u:"
                                                                    "%u "
                                                                    "expected%."
                                                                    "9g "
                                                                    "[%d,%d]\n",
                                                                    volume ?
                                                                        "3D" :
                                                                        "Cube",
                                                                    combination,
                                                                    border,
                                                                    first,
                                                                    stage,
                                                                    requested,
                                                                    scale, face,
                                                                    profile,
                                                                    operation,
                                                                    phase, x, y,
                                                                    channel,
                                                                    byte,
                                                                    expected
                                                                        [channel],
                                                                    low, high);
                                                                abort();
                                                            }
                                                            channels++;
                                                            ambiguous +=
                                                                low != high;
                                                        }
                                                    } else
                                                        assert(actual ==
                                                               0xffff0000);
                                                    pixels++;
                                                }
                                            unsigned faceLength =
                                                cube_begin_face_length(physical,
                                                                       4);
                                            unsigned stride = ROUND_UP(
                                                faceLength,
                                                NV2A_CUBEMAP_FACE_ALIGNMENT);
                                            for (unsigned input = 0; input < 2;
                                                 input++)
                                                for (unsigned f = 0;
                                                     f < (volume ? 0u : 6u);
                                                     f++)
                                                    for (unsigned i =
                                                             faceLength;
                                                         i < stride; i++) {
                                                        assert(
                                                            state->vram_ptr
                                                                [24576 +
                                                                 input * 12288 +
                                                                 f * stride +
                                                                 i] == 0xd3);
                                                        padding++;
                                                    }
                                            if (phase < 4) {
                                                if (phase == 1 || phase == 2) {
                                                    unsigned input = phase - 1;
                                                    brdf_begin_gpu_write(
                                                        writer, physical,
                                                        volume, input, 2,
                                                        (combination >> input) &
                                                            1,
                                                        scale, &gpuDraws,
                                                        &gpuPixels);
                                                }
                                                if (phase == 3)
                                                    brdf_cube_lookup_write(
                                                        lookup, 2);
                                                cpu_write(1024, 256);
                                                for (unsigned i = 0; i < 64;
                                                     i++)
                                                    stl_le_p(state->vram_ptr +
                                                                 1024 + 4 * i,
                                                             0xffff0000);
                                                for (unsigned input = 0;
                                                     input < 2; input++) {
                                                    send_method(
                                                        NV097_SET_TEXTURE_FORMAT +
                                                            (stage + input) *
                                                                64,
                                                        format[input]);
                                                    send_method(
                                                        NV097_SET_TEXTURE_FILTER +
                                                            (stage + input) *
                                                                64,
                                                        filter[input]);
                                                }
                                                send_method(
                                                    NV097_SET_SHADER_STAGE_PROGRAM,
                                                    program);
                                                begin(PRIM_TYPE_TRIANGLES);
                                                require(
                                                    [surfaces.cache
                                                        submitWithError:
                                                            &error] &&
                                                        [surfaces.cache
                                                            waitUntilIdleWithError:
                                                                &error],
                                                    error);
                                                NSData *fresh = [draw
                                                    beginSnapshotWithError:
                                                        &error];
                                                require(fresh != nil, error);
                                                assert(![fresh
                                                    isEqualToData:previous]);
                                                brdf_begin_check_capture(
                                                    fresh, volume, physical,
                                                    first, stage, combination,
                                                    requested,
                                                    generations[phase + 1],
                                                    false, &sourceTexels,
                                                    &lookupTexels, rejects);
                                                previous = fresh;
                                                arrays(0, 3);
                                                end();
                                                freshBegins++;
                                            }
                                        }
                                        for (unsigned phase = 0; phase < 4;
                                             phase++)
                                            assert(
                                                memcmp(outputs[phase],
                                                       outputs[phase + 1],
                                                       sizeof(outputs[phase])));
                                        for (unsigned change = 0; change < 3;
                                             change++) {
                                            bool different = false;
                                            unsigned stable = change == 0 ?
                                                                  0x0000ff00 :
                                                                  0x00ff0000;
                                            for (unsigned i = 0; i < 64; i++) {
                                                uint32_t delta =
                                                    outputs[change + 2][i] ^
                                                    outputs[change + 1][i];
                                                if (change < 2)
                                                    assert(!(delta & stable));
                                                different |= delta != 0;
                                            }
                                            assert(different);
                                            independent[change]++;
                                        }
                                        cases++;
                                    }
                                }
    const unsigned count = volume ? 768 : 2304;
    assert(cases == count && restores == count * 3 / 2 && pending == count &&
           canonical == count * 5 / 2 && pixels == count * 320 &&
           channels == count * 640 && freshBegins == count * 4 &&
           sourceTexels == count * (volume ? 13375 : 7950) &&
           lookupTexels == count * 2560 &&
           gpuDraws == count * (volume ? 24 : 144) &&
           gpuPixels == (volume ? 27388800 : count * 19125) &&
           padding == count * (volume ? 0 : 2760) && rejects[0] == count * 4 &&
           rejects[1] == count * 4 && rejects[2] == count * 4 &&
           independent[0] == count && independent[1] == count &&
           independent[2] == count &&
           (volume || (selectedFaces[0] == 63 && selectedFaces[1] == 63 &&
                       changedFaces[0] && changedFaces[1])) &&
           negativeDelta && tapPixels[1] && tapPixels[3] && tapPixels[7]);
    printf("Metal4 GPU %s BRDF combo%u: %u cases/%u restores/%u pending/%u "
           "canonical/%u pixels/%u channels/%u ambiguous/%u fresh/%u source "
           "texels/%u lookup texels/%u GPU draws/%u GPU pixels/%u padding/%u "
           "signed rejects/%u AF rejects/%u lookup rejects/%u negative delta "
           "PASS\n",
           volume ? "3D" : "Cube", combination, cases, restores, pending,
           canonical, pixels, channels, ambiguous, freshBegins, sourceTexels,
           lookupTexels, gpuDraws, gpuPixels, padding, rejects[0], rejects[1],
           rejects[2], negativeDelta);
    printf("%sBRDF independent sources/lookup: %u %u %u; changed faces: %u %u; "
           "taps1..8:",
           volume ? "3D " : "", independent[0], independent[1], independent[2],
           changedFaces[0], changedFaces[1]);
    for (unsigned i = 0; i < 8; i++)
        printf(" %u", tapPixels[i]);
    printf("\n");
    groups++;
}

static uint32_t legacy_cube_guest_value(unsigned x, unsigned y, unsigned face,
                                        bool hilo, unsigned phase)
{
    if (!hilo)
        return (x + 17 * y + 37 * face + phase * 73) & 255;
    unsigned hi =
        (0x1234 + 499 * x + 977 * y + 5003 * face + phase * 4093) & 65535;
    unsigned lo =
        (0x4567 + 613 * x + 1297 * y + 7001 * face + phase * 8191) & 65535;
    return hi << 16 | lo;
}
static void legacy_cube_write(unsigned capture, unsigned phase)
{
    bool hilo = capture >= 4;
    unsigned bpp = hilo ? 4 : 1, size[] = { 16, 16, 1 };
    const unsigned source = 24576, length = 6 * 256 * bpp;
    dma[4].address = source;
    dma[4].limit = length - 1;
    cpu_write(source, length);
    for (unsigned face = 0; face < 6; face++)
        for (unsigned y = 0; y < 16; y++)
            for (unsigned x = 0; x < 16; x++) {
                unsigned offset =
                    source +
                    bpp * (face * 256 + border_begin_morton(x, y, 0, size));
                uint32_t value =
                    legacy_cube_guest_value(x, y, face, hilo, phase);
                if (hilo)
                    stl_le_p(state->vram_ptr + offset, value);
                else
                    state->vram_ptr[offset] = value;
            }
}
static uint32_t legacy_cube_reference(unsigned capture, unsigned face,
                                      const double uv[2], unsigned phase)
{
    bool hilo = capture >= 4, linear = capture % 2;
    double x = uv[0] * 2 + (phase ? 4 : 0) - (linear ? .5 : 0);
    double y = uv[1] * 2 + (phase ? 4 : 0) - (linear ? .5 : 0);
    int bx = floor(x), by = floor(y);
    double fx = x - bx, fy = y - by, result[3] = {};
    for (unsigned corner = 0; corner < (linear ? 4u : 1u); corner++) {
        unsigned highX = corner & 1, highY = corner >> 1;
        unsigned sx =
            MAX(0, MIN(phase ? 15 : 1, bx + (int)highX)) + (phase ? 0 : 4);
        unsigned sy =
            MAX(0, MIN(phase ? 15 : 1, by + (int)highY)) + (phase ? 0 : 4);
        double weight =
            linear ? (highX ? fx : 1 - fx) * (highY ? fy : 1 - fy) : 1;
        uint32_t word = legacy_cube_guest_value(sx, sy, face, hilo, phase);
        result[0] += weight * (hilo ? (word >> 16) / 257.0 : word);
        result[1] += weight * (hilo ? (word & 65535) / 257.0 : word);
    }
    result[2] = result[1];
    uint32_t out = 0xff000000;
    for (unsigned k = 0; k < 3; k++) {
        // The selected profiles stay away from half-byte quantization ties.
        assert(fabs(result[k] - floor(result[k]) - .5) > .0005);
        unsigned byte = lround(result[k]);
        assert(byte <= 255);
        out |= byte << (16 - 8 * k);
    }
    return out;
}
static void legacy_cube_begin_snapshot(void)
{
    const double positions[][2] = { { .25, .25 },     { .75, .25 },
                                    { .25, .75 },     { .75, .75 },
                                    { .5, .5 },       { .15625, .125 },
                                    { .84375, .875 }, { .3125, .6875 } };
    unsigned cases = 0, restores = 0, pendingRestores = 0, canonical = 0;
    unsigned pixels = 0, nextBegins = 0, invalid = 0, faces = 0;
    NSError *error = nil;
    for (unsigned capture = 0; capture < 8; capture++) {
        NSData *old = legacy_cube_begin_fixture(capture);
        char *digest = g_compute_checksum_for_data(G_CHECKSUM_SHA256, old.bytes,
                                                   old.length);
        assert(!strcmp(digest, legacy_cube_begin_sha256[capture]));
        g_free(digest);
        assert(pgraph_metal4_validate_begin_capture(old.bytes, old.length));
        unsigned stage = capture % 4 >= 2 ? 3 : 0, methodSlot = stage * 64;
        bool hilo = capture >= 4;
        unsigned border = 48 + 100 +
                          offsetof(NV2AMetalPixelUniforms, textures) +
                          stage * sizeof(NV2AMetalTextureStage) +
                          offsetof(NV2AMetalTextureStage, border_logical_size);
        for (unsigned part = 0; part < 2; part++) {
            NSMutableData *bad = [old mutableCopy];
            stl_be_p((uint8_t *)bad.mutableBytes +
                         (part ? 1480 + 12 + 16 +
                                     offsetof(NV2AMetalTextureStage,
                                              border_logical_size) :
                                 border),
                     0x40000000);
            assert(
                !pgraph_metal4_validate_begin_capture(bad.bytes, bad.length));
            invalid++;
        }
        for (unsigned face = 0; face < 6; face++)
            for (unsigned profile = 0; profile < ARRAY_SIZE(positions);
                 profile++)
                for (unsigned operation = 0; operation < 4; operation++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    legacy_cube_write(capture, 0);
                    uint32_t format = 0;
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
                             hilo ?
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16 :
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                             2);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CUBEMAP_ENABLE,
                             1);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_U, 1);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BASE_SIZE_V, 1);
                    send_method(NV097_SET_TEXTURE_OFFSET + methodSlot, 0);
                    send_method(NV097_SET_TEXTURE_FORMAT + methodSlot, format);
                    send_method(NV097_SET_TEXTURE_CONTROL0 + methodSlot,
                                NV097_SET_TEXTURE_CONTROL0_ENABLE);
                    send_method(NV097_SET_TEXTURE_FILTER + methodSlot,
                                (capture % 2 ? 2 : 1) << 16 |
                                    (capture % 2 ? 2 : 1) << 24);
                    send_method(NV097_SET_TEXTURE_ADDRESS + methodSlot,
                                3 | 3 << 8 | 3 << 16);
                    uint32_t program = PS_TEXTUREMODES_CUBEMAP << (5 * stage);
                    send_method(NV097_SET_SHADER_STAGE_PROGRAM, program);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                PS_REGISTER_T0 + stage);
                    send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA)
                                    << 8);
                    double a = 2 * positions[profile][0] - 1,
                           b = 2 * positions[profile][1] - 1;
                    const double direction[][3] = {
                        { 1, -b, -a }, { -1, -b, a }, { a, 1, b },
                        { a, -1, -b }, { a, -b, 1 },  { -a, -b, -1 }
                    };
                    for (unsigned axis = 0; axis < 3; axis++)
                        pg->vertex_attributes[9 + stage].inline_value[axis] =
                            direction[face][axis];
                    begin(PRIM_TYPE_TRIANGLES);
                    unsigned pending = operation & 1;
                    if (pending)
                        arrays(0, 3);
                    send_method(NV097_SET_TEXTURE_FORMAT + methodSlot,
                                127u << 8);
                    send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                (uint32_t)PS_TEXTUREMODES_PASSTHRU
                                    << (5 * stage));
                    cpu_write(24576, 6 * 256 * (hilo ? 4 : 1));
                    memset(state->vram_ptr + 24576, 0xe3,
                           6 * 256 * (hilo ? 4 : 1));
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    assert(pg->draw_arrays_length == pending);
                    // Install the actual historical Begin, retaining the frozen
                    // vertex and pending-array state from the compact parent.
                    g_free(pg->metal4_begin_capture);
                    pg->metal4_begin_capture = g_memdup2(old.bytes, old.length);
                    pg->metal4_begin_capture_size = old.length;
                    int fd = new_vertex_snapshot_file();
                    save_snapshot_parent(fd, &array_snapshot_parent);
                    NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                    for (unsigned pass = 0; pass <= operation / 2; pass++) {
                        if (!pending)
                            arrays(0, 3);
                        end();
                        before_ram_load();
                        memcpy(state->vram_ptr, ram.bytes, ram.length);
                        assert(load_snapshot_parent(
                                   fd, &array_snapshot_parent) == 0);
                        after_ram_load();
                        assert(pg->draw_arrays_length == pending);
                        // Resume the lazy Begin and materialize its GPU
                        // resources before reserializing, rather than returning
                        // its wire.
                        qemu_mutex_lock(&pg->lock);
                        renderer.ops.flush_draw(state);
                        qemu_mutex_unlock(&pg->lock);
                        assert(pg->draw_arrays_length == pending);
                        close(fd);
                        restores++;
                        pendingRestores += pending;
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        NSData *again = [NSData
                            dataWithBytes:pg->metal4_begin_capture
                                   length:pg->metal4_begin_capture_size];
                        assert([again isEqualToData:old]);
                        canonical++;
                        if (pass < operation / 2) {
                            fd = new_vertex_snapshot_file();
                            save_snapshot_parent(fd, &array_snapshot_parent);
                            ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                        }
                    }
                    // A successful scratch flush must not hide a missing End
                    // draw.
                    cpu_write(1024, 256);
                    for (unsigned i = 0; i < 64; i++)
                        stl_le_p(state->vram_ptr + 1024 + 4 * i, 0xffff0000);
                    if (!pending)
                        arrays(0, 3);
                    end();
                    for (unsigned phase = 0; phase < 2; phase++) {
                        uint32_t expected = legacy_cube_reference(
                            capture, face, positions[profile], phase);
                        for (unsigned y = 0; y < 8; y++)
                            for (unsigned x = 0; x < 8; x++) {
                                uint32_t want =
                                    x + y < 7 ? expected : 0xffff0000;
                                uint32_t actual = color(x, y);
                                if (actual != want) {
                                    fprintf(stderr,
                                            "Legacy Cube Begin cap%u face%u "
                                            "profile%u op%u phase%u "
                                            "pixel%u,%u:%08x expected%08x\n",
                                            capture, face, profile, operation,
                                            phase, x, y, actual, want);
                                    abort();
                                }
                                pixels++;
                            }
                        if (!phase) {
                            cpu_write(1024, 256);
                            for (unsigned i = 0; i < 64; i++)
                                stl_le_p(state->vram_ptr + 1024 + 4 * i,
                                         0xffff0000);
                            legacy_cube_write(capture, 1);
                            send_method(NV097_SET_TEXTURE_FORMAT + methodSlot,
                                        format);
                            send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                        program);
                            begin(PRIM_TYPE_TRIANGLES);
                            require([surfaces.cache submitWithError:&error] &&
                                        [surfaces.cache
                                            waitUntilIdleWithError:&error],
                                    error);
                            NSData *fresh =
                                [draw beginSnapshotWithError:&error];
                            require(fresh != nil, error);
                            const uint8_t *bytes = fresh.bytes;
                            unsigned offset =
                                48 + (uint32_t)ldl_be_p(bytes + 40);
                            const uint8_t *image = bytes + offset + 12 + 220;
                            assert((uint32_t)ldl_be_p(image + 12) == 16 &&
                                   (uint32_t)ldl_be_p(image + 16) == 16);
                            assert((uint32_t)ldl_be_p(bytes + border) ==
                                   0x40000000);
                            arrays(0, 3);
                            end();
                            nextBegins++;
                        }
                    }
                    faces |= 1u << face;
                    cases++;
                }
    }
    assert(cases == 1536 && restores == 2304 && pendingRestores == 1152 &&
           canonical == 2304 && pixels == 196608 && nextBegins == 1536 &&
           invalid == 16 && faces == 63);
    printf("Metal4 legacy Cube Begin: %u cases/%u partial restores/%u "
           "pending-array restores/%u exact canonical resaves/%u exact raw "
           "pixels/%u full-resource fresh Begins/%u border mismatch rejects "
           "PASS\n",
           cases, restores, pendingRestores, canonical, pixels, nextBegins,
           invalid);
    groups++;
}

static void constant_eye_snapshot(void)
{
    const uint32_t faces[6] = { 0xff0000ff, 0xffffff00, 0xff00ff00,
                                0xff00ffff, 0xffff0000, 0xffff00ff };
    for (unsigned eyeAxis = 0; eyeAxis < 3; eyeAxis++)
        for (unsigned eyeSign = 0; eyeSign < 2; eyeSign++)
            for (unsigned operation = 0; operation < 3; operation++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                cpu_write(49152, 768);
                for (unsigned i = 0; i < 6; i++)
                    memcpy(state->vram_ptr + 49152 + i * 128, &faces[i], 4);
                const unsigned stage = 3 * 64;
                uint32_t format = 0;
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
                         NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 2);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                         NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CUBEMAP_ENABLE, 1);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                send_method(NV097_SET_TEXTURE_FORMAT + stage, format);
                send_method(NV097_SET_TEXTURE_CONTROL0 + stage,
                            NV097_SET_TEXTURE_CONTROL0_ENABLE);
                send_method(NV097_SET_TEXTURE_FILTER + stage,
                            1 << 16 | 1 << 24);
                send_method(NV097_SET_TEXTURE_ADDRESS + stage,
                            3 | 3 << 8 | 3 << 16);
                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                            PS_TEXTUREMODES_PASSTHRU |
                                PS_TEXTUREMODES_DOTPRODUCT << 5 |
                                PS_TEXTUREMODES_DOTPRODUCT << 10 |
                                PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST << 15);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                            PS_REGISTER_T3);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                            (PS_REGISTER_T3 | PS_CHANNEL_ALPHA) << 8);
                send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                pg->vertex_attributes[9].inline_value[0] = 1;
                pg->vertex_attributes[10].inline_value[0] = 2;
                pg->vertex_attributes[10].inline_value[3] = 13;
                pg->vertex_attributes[11].inline_value[3] = 17;
                pg->vertex_attributes[12].inline_value[3] = 19;
                float eye[3] = { 0 };
                eye[eyeAxis] = eyeSign ? -3 : 3;
                uint32_t words[3];
                memcpy(words, eye, 12);
                assert(method(NV097_SET_EYE_VECTOR, words[0], words, 3, 0,
                              true) == 3);
                begin(PRIM_TYPE_TRIANGLES);
                eye[eyeAxis] = -eye[eyeAxis];
                memcpy(words, eye, 12);
                assert(method(NV097_SET_EYE_VECTOR, words[0], words, 3, 0,
                              true) == 3);
                if (operation == 2)
                    send_method(NV097_CLEAR_SURFACE, 0);
                if (operation) {
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    NSData *beginCapture =
                        [NSData dataWithBytes:pg->metal4_begin_capture
                                       length:pg->metal4_begin_capture_size];
                    const uint8_t *pixel =
                        (const uint8_t *)beginCapture.bytes + 48;
                    unsigned pixelLength = (uint32_t)ldl_be_p(
                        (const uint8_t *)beginCapture.bytes + 40);
                    assert(ldl_be_p(pixel + 4) == 6 &&
                           ldl_be_p(pixel + 8) == 333);
                    const uint8_t *tail = pixel + pixelLength - 24;
                    memcpy(words, eye, 12);
                    for (unsigned i = 0; i < 3; i++) {
                        float original = i == eyeAxis ? -eye[i] : 0;
                        uint32_t bits;
                        memcpy(&bits, &original, 4);
                        assert((uint32_t)ldl_be_p(tail + i * 4) == bits);
                    }
                    assert(ldl_be_p(tail + 12) == 0);
                    int fd = new_vertex_snapshot_file();
                    save_vertex_snapshot(fd);
                    NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                    arrays(0, 3);
                    end();
                    before_ram_load();
                    memcpy(state->vram_ptr, ram.bytes, ram.length);
                    assert(load_vertex_snapshot(fd) == 0);
                    pg->draw_arrays_length = 0;
                    after_ram_load();
                    close(fd);
                }
                arrays(0, 3);
                end();
                unsigned face = eyeAxis * 2 + (eyeSign ^ (eyeAxis != 0));
                assert(color(1, 1) == faces[face]);
                get_report(0);
                process_reports();
                assert(report_result(0) == 28);
                begin(PRIM_TYPE_TRIANGLES);
                arrays(0, 3);
                end();
                assert(color(1, 1) == faces[face ^ 1]);
            }
    groups++;
}
static void signed_dot_snapshot(void)
{
    for (unsigned stage = 2; stage < 4; stage++)
        for (unsigned map = 0; map < 4; map++)
            for (unsigned operation = 0; operation < 3; operation++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                cpu_write(32768, 4);
                uint32_t source = 0xff7f4020;
                memcpy(state->vram_ptr + 32768, &source, 4);
                cpu_write(49152, 256);
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        unsigned address = 0;
                        for (unsigned bit = 0; bit < 3; bit++) {
                            address |= ((x >> bit) & 1) << (2 * bit);
                            address |= ((y >> bit) & 1) << (2 * bit + 1);
                        }
                        uint32_t texel = 0xff000020 | (x * 32 + 16) << 16 |
                                         (y * 32 + 16) << 8;
                        memcpy(state->vram_ptr + 49152 + address * 4, &texel,
                               4);
                    }
                for (unsigned unit = 0; unit < 2; unit++) {
                    unsigned slot = unit ? stage * 64 : 0;
                    uint32_t format = 0;
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA,
                             unit ? 2 : 1);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
                             NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                             2);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                             NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                    SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                    if (unit)
                        format |= 3 << 20 | 3 << 24;
                    send_method(NV097_SET_TEXTURE_FORMAT + slot, format);
                    send_method(NV097_SET_TEXTURE_CONTROL0 + slot,
                                NV097_SET_TEXTURE_CONTROL0_ENABLE);
                    unsigned filter = 1 << 16 | 1 << 24;
                    if (!unit)
                        filter |= NV097_SET_TEXTURE_FILTER_RSIGNED |
                                  NV097_SET_TEXTURE_FILTER_GSIGNED |
                                  NV097_SET_TEXTURE_FILTER_BSIGNED |
                                  NV097_SET_TEXTURE_FILTER_ASIGNED;
                    send_method(NV097_SET_TEXTURE_FILTER + slot, filter);
                    send_method(NV097_SET_TEXTURE_ADDRESS + slot,
                                3 | 3 << 8 | 3 << 16);
                }
                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                            PS_TEXTUREMODES_PROJECT2D |
                                PS_TEXTUREMODES_DOTPRODUCT
                                    << (5 * (stage - 1)) |
                                PS_TEXTUREMODES_DOT_ST << (5 * stage));
                send_method(NV097_SET_SHADER_OTHER_STAGE_INPUT,
                            map << (4 * (stage - 2)) |
                                map << (4 * (stage - 1)));
                const float first[] = { .5f, .25f, -.125f, 1 };
                const float second[] = { -.125f, .25f, .5f, 1 };
                memcpy(pg->vertex_attributes[9 + stage - 1].inline_value, first,
                       sizeof(first));
                memcpy(pg->vertex_attributes[9 + stage].inline_value, second,
                       sizeof(second));
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                            PS_REGISTER_T0 + stage);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                            (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA) << 8);
                send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                begin(PRIM_TYPE_TRIANGLES);
                send_method(NV097_SET_TEXTURE_FILTER, 1 << 16 | 1 << 24);
                if (operation == 2)
                    send_method(NV097_CLEAR_SURFACE, 0);
                if (operation) {
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    int fd = new_vertex_snapshot_file();
                    save_vertex_snapshot(fd);
                    NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                    arrays(0, 3);
                    end();
                    before_ram_load();
                    memcpy(state->vram_ptr, ram.bytes, ram.length);
                    assert(load_vertex_snapshot(fd) == 0);
                    pg->draw_arrays_length = 0;
                    after_ram_load();
                    close(fd);
                }
                arrays(0, 3);
                end();
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++)
                        assert(color(x, y) ==
                               (x + y < 7 ? 0xff903020 : 0xffff0000));
                get_report(0);
                process_reports();
                assert(report_result(0) == 28);
            }
    puts("Metal4 signed dot: 24 frozen Begin/restore/clear cases PASS");
    groups++;
}

static void signed_texture_snapshot(void)
{
    const unsigned flags[] = { NV097_SET_TEXTURE_FILTER_RSIGNED,
                               NV097_SET_TEXTURE_FILTER_GSIGNED,
                               NV097_SET_TEXTURE_FILTER_BSIGNED,
                               NV097_SET_TEXTURE_FILTER_ASIGNED };
    for (unsigned stage = 0; stage < 4; stage++)
        for (unsigned mask = 0; mask < 16; mask++)
            for (unsigned restore = 0; restore < 2; restore++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                cpu_write(49152, 4);
                uint32_t texel = 0xff7f4020;
                memcpy(state->vram_ptr + 49152, &texel, 4);
                unsigned slot = stage * 64;
                uint32_t format = 0;
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
                         NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 2);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                         NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                send_method(NV097_SET_TEXTURE_FORMAT + slot, format);
                send_method(NV097_SET_TEXTURE_CONTROL0 + slot,
                            NV097_SET_TEXTURE_CONTROL0_ENABLE);
                unsigned filter = 1 << 16 | 1 << 24;
                for (unsigned k = 0; k < 4; k++)
                    if (mask & (1u << k))
                        filter |= flags[k];
                send_method(NV097_SET_TEXTURE_FILTER + slot, filter);
                send_method(NV097_SET_TEXTURE_ADDRESS + slot,
                            3 | 3 << 8 | 3 << 16);
                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                            PS_TEXTUREMODES_PROJECT2D << (stage * 5));
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                            PS_REGISTER_T0 + stage);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                            (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA) << 8);
                begin(PRIM_TYPE_TRIANGLES);
                // The current registers differ from the immutable Begin state.
                send_method(NV097_SET_TEXTURE_FILTER + slot,
                            filter ^
                                (flags[0] | flags[1] | flags[2] | flags[3]));
                if (restore) {
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    int fd = new_vertex_snapshot_file();
                    save_vertex_snapshot(fd);
                    NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                    arrays(0, 3);
                    end();
                    before_ram_load();
                    memcpy(state->vram_ptr, ram.bytes, ram.length);
                    assert(load_vertex_snapshot(fd) == 0);
                    pg->draw_arrays_length = 0;
                    after_ram_load();
                    close(fd);
                }
                arrays(0, 3);
                end();
                uint32_t expected = (mask & 8 ? 0u : 255u) << 24 |
                                    (mask & 1 ? 254u : 127u) << 16 |
                                    (mask & 2 ? 128u : 64u) << 8 |
                                    (mask & 4 ? 64u : 32u);
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++)
                        assert(color(x, y) ==
                               (x + y < 7 ? expected : 0xffff0000));
            }
    puts("Metal4 signed8: 128 frozen Begin/restore cases PASS");
    groups++;
}

static void bump_result_snapshot(void)
{
    const float factors[] = { 0, .25f, 1, 2 };
    for (unsigned bump = 1; bump < 3; bump++)
        for (unsigned stage = bump + 1; stage < 4; stage++)
            for (unsigned gb = 0; gb < 2; gb++)
                for (unsigned factor = 0; factor < 4; factor++)
                    for (unsigned operation = 0; operation < 3; operation++) {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        cpu_write(49152, 4);
                        uint32_t image = 0x604080c0;
                        memcpy(state->vram_ptr + 49152, &image, 4);
                        cpu_write(32768, 256);
                        for (unsigned y = 0; y < 8; y++)
                            for (unsigned x = 0; x < 8; x++) {
                                uint32_t texel = 0xff000020 |
                                                 (x * 32 + 16) << 16 |
                                                 (y * 32 + 16) << 8;
                                unsigned address = 0;
                                for (unsigned bit = 0; bit < 3; bit++) {
                                    address |= ((x >> bit) & 1) << (2 * bit);
                                    address |= ((y >> bit) & 1)
                                               << (2 * bit + 1);
                                }
                                memcpy(state->vram_ptr + 32768 + address * 4,
                                       &texel, 4);
                            }
                        for (unsigned unit = 0; unit < 2; unit++) {
                            unsigned index = unit ? stage : bump;
                            unsigned slot = index * 64;
                            uint32_t format = 0;
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA,
                                     unit ? 1 : 2);
                            SET_MASK(
                                format, NV097_SET_TEXTURE_FORMAT_COLOR,
                                NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
                            if (unit)
                                format |= 3 << 20 | 3 << 24;
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY,
                                     2);
                            SET_MASK(
                                format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                                NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                            SET_MASK(format,
                                     NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                            send_method(NV097_SET_TEXTURE_FORMAT + slot,
                                        format);
                            send_method(NV097_SET_TEXTURE_CONTROL0 + slot,
                                        NV097_SET_TEXTURE_CONTROL0_ENABLE);
                            send_method(NV097_SET_TEXTURE_FILTER + slot,
                                        1 << 16 | 1 << 24);
                            send_method(NV097_SET_TEXTURE_ADDRESS + slot,
                                        3 | 3 << 8 | 3 << 16);
                            if (unit) {
                                send_method(NV097_SET_TEXTURE_CONTROL1 + slot,
                                            32 << 16);
                                send_method(NV097_SET_TEXTURE_IMAGE_RECT + slot,
                                            8 << 16 | 8);
                            }
                        }
                        uint32_t bits;
                        memcpy(&bits, &factors[factor], 4);
                        send_method(NV097_SET_TEXTURE_SET_BUMP_ENV_OFFSET +
                                        bump * 64,
                                    bits);
                        send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                                    PS_TEXTUREMODES_PASSTHRU |
                                        PS_TEXTUREMODES_BUMPENVMAP_LUM
                                            << (bump * 5) |
                                        (gb ? PS_TEXTUREMODES_DPNDNT_GB :
                                              PS_TEXTUREMODES_DPNDNT_AR)
                                            << (stage * 5));
                        send_method(NV097_SET_SHADER_OTHER_STAGE_INPUT,
                                    bump << (stage == 2 ? 16 : 20));
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                                    PS_REGISTER_T0 + stage);
                        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                                    (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA)
                                        << 8);
                        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                        begin(PRIM_TYPE_TRIANGLES);
                        float changed = factor ? 0 : 1;
                        memcpy(&bits, &changed, 4);
                        send_method(NV097_SET_TEXTURE_SET_BUMP_ENV_OFFSET +
                                        bump * 64,
                                    bits);
                        if (operation == 2)
                            send_method(NV097_CLEAR_SURFACE, 0);
                        if (operation) {
                            renderer.ops.pre_savevm_trigger(state);
                            process_pending();
                            renderer.ops.pre_savevm_wait(state);
                            int fd = new_vertex_snapshot_file();
                            save_vertex_snapshot(fd);
                            NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                         length:65536];
                            arrays(0, 3);
                            end();
                            before_ram_load();
                            memcpy(state->vram_ptr, ram.bytes, ram.length);
                            assert(load_vertex_snapshot(fd) == 0);
                            pg->draw_arrays_length = 0;
                            after_ram_load();
                            close(fd);
                        }
                        arrays(0, 3);
                        end();
                        uint32_t expected = gb ? 0xff90d020 : 0xff705020;
                        for (unsigned y = 0; y < 8; y++)
                            for (unsigned x = 0; x < 8; x++)
                                assert(color(x, y) ==
                                       (x + y < 7 ? expected : 0xffff0000));
                        get_report(0);
                        process_reports();
                        assert(report_result(0) == 28);
                    }
    puts("Metal4 bump result: 72 frozen Begin/restore/clear dependent cases "
         "PASS");
    groups++;
}

static void bump_luminance_snapshot(void)
{
    const float parameters[4][2] = { { 0, 0 }, { 1, 0 }, { 2, .5f }, { 4, 1 } };
    const uint32_t expected[] = { 0x60000000, 0x60102030, 0x604080c0,
                                  0x604080c0 };
    for (unsigned stage = 1; stage < 4; stage++) {
        for (unsigned test = 0; test < 4; test++) {
            for (unsigned operation = 0; operation < 3; operation++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                cpu_write(49152, 4);
                uint32_t texel = 0x604080c0;
                memcpy(state->vram_ptr + 49152, &texel, 4);
                unsigned slot = stage * 64;
                uint32_t format = 0;
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_CONTEXT_DMA, 2);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_COLOR,
                         NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_DIMENSIONALITY, 2);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE,
                         NV097_SET_TEXTURE_FORMAT_BORDER_SOURCE_COLOR);
                SET_MASK(format, NV097_SET_TEXTURE_FORMAT_MIPMAP_LEVELS, 1);
                send_method(NV097_SET_TEXTURE_FORMAT + slot, format);
                send_method(NV097_SET_TEXTURE_CONTROL0 + slot,
                            NV097_SET_TEXTURE_CONTROL0_ENABLE);
                send_method(NV097_SET_TEXTURE_FILTER + slot, 1 << 16 | 1 << 24);
                send_method(NV097_SET_TEXTURE_ADDRESS + slot,
                            3 | 3 << 8 | 3 << 16);
                uint32_t scale, offset;
                memcpy(&scale, &parameters[test][0], 4);
                memcpy(&offset, &parameters[test][1], 4);
                send_method(NV097_SET_TEXTURE_SET_BUMP_ENV_SCALE + slot, scale);
                send_method(NV097_SET_TEXTURE_SET_BUMP_ENV_OFFSET + slot,
                            offset);
                send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                            PS_TEXTUREMODES_PASSTHRU |
                                PS_TEXTUREMODES_BUMPENVMAP_LUM << (stage * 5));
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                            PS_REGISTER_T0 + stage);
                send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                            (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA) << 8);
                send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                pg->vertex_attributes[9].inline_value[0] = .25f;
                begin(PRIM_TYPE_TRIANGLES);
                float zero = 0, half = .5f;
                memcpy(&scale, &zero, 4);
                memcpy(&offset, &half, 4);
                send_method(NV097_SET_TEXTURE_SET_BUMP_ENV_SCALE + slot, scale);
                send_method(NV097_SET_TEXTURE_SET_BUMP_ENV_OFFSET + slot,
                            offset);
                if (operation == 2)
                    send_method(NV097_CLEAR_SURFACE, 0);
                if (operation) {
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    int fd = new_vertex_snapshot_file();
                    save_vertex_snapshot(fd);
                    NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                                 length:65536];
                    arrays(0, 3);
                    end();
                    before_ram_load();
                    memcpy(state->vram_ptr, ram.bytes, ram.length);
                    assert(load_vertex_snapshot(fd) == 0);
                    pg->draw_arrays_length = 0;
                    after_ram_load();
                    close(fd);
                }
                arrays(0, 3);
                end();
                for (unsigned y = 0; y < 8; y++) {
                    for (unsigned x = 0; x < 8; x++)
                        assert(color(x, y) ==
                               (x + y < 7 ? expected[test] : 0xffff0000));
                }
                get_report(0);
                process_reports();
                assert(report_result(0) == 28);
                begin(PRIM_TYPE_TRIANGLES);
                arrays(0, 3);
                end();
                assert(color(1, 1) == 0x60204060);
            }
        }
    }
    puts("Metal4 bump luminance: 36 frozen Begin/restore/clear cases PASS");
    groups++;
}
static void passthrough_snapshot(void)
{
    const float coordinates[] = { 1.25f, .375f, -.25f, 1.5f };
    for (unsigned stage = 0; stage < 4; stage++)
        for (unsigned operation = 0; operation < 3; operation++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            send_method(NV097_SET_SHADER_STAGE_PROGRAM,
                        PS_TEXTUREMODES_PASSTHRU << (5 * stage));
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0,
                        PS_REGISTER_T0 + stage);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                        (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA) << 8);
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            memcpy(pg->vertex_attributes[9 + stage].inline_value, coordinates,
                   sizeof(coordinates));
            begin(PRIM_TYPE_TRIANGLES);
            // The active Begin keeps its pass-through program and T register
            // even when the live pipeline changes before drawing/restoring.
            send_method(NV097_SET_SHADER_STAGE_PROGRAM, 0);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
            send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW1,
                        (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8);
            send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
            if (operation == 2)
                send_method(NV097_CLEAR_SURFACE, 0);
            if (operation) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                NSData *ram = [NSData dataWithBytes:state->vram_ptr
                                             length:65536];
                arrays(0, 3);
                end();
                before_ram_load();
                memcpy(state->vram_ptr, ram.bytes, ram.length);
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
            }
            arrays(0, 3);
            end();
            assert(color(1, 1) == 0xffff6000 && color(7, 7) == 0xffff0000);
            get_report(0);
            process_reports();
            assert(report_result(0) == 28);
            begin(PRIM_TYPE_TRIANGLES);
            arrays(0, 3);
            end();
            assert(color(1, 1) == 0xffffff00);
        }
    puts("Metal 4 pass-through: 12 frozen Begin/restore/clear cases PASS");
    groups++;
}
static void scale_preserves_begin(void)
{
    for (unsigned restore = 0; restore < 2; restore++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        send_method(NV097_SET_COMBINER_SPECULAR_FOG_CW0, PS_REGISTER_C0);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xff0000ff);
        begin(PRIM_TYPE_TRIANGLES);
        send_method(NV097_SET_SPECULAR_FOG_FACTOR, 0xffffff00);
        float translation = 4;
        memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0][3], &translation,
               4);
        send_method(NV097_SET_BLEND_ENABLE, 1);
        send_method(NV097_SET_BLEND_EQUATION, 0x8006);
        send_method(NV097_SET_BLEND_FUNC_SFACTOR, 0);
        send_method(NV097_SET_BLEND_FUNC_DFACTOR, 0);
        arrays(0, 3);
        start_worker();
        qemu_mutex_lock(&pg->renderer_lock);
        renderer.ops.set_surface_scale_factor(state, 2);
        qemu_mutex_unlock(&pg->renderer_lock);
        stop_worker();
        assert(pg->surface_scale_factor == 2 && pg->draw_time == 0);
        if (restore) {
            renderer.ops.pre_savevm_trigger(state);
            process_pending();
            renderer.ops.pre_savevm_wait(state);
            int fd = new_vertex_snapshot_file();
            save_vertex_snapshot(fd);
            end();
            before_ram_load();
            for (unsigned i = 0; i < 64; i++) {
                uint32_t red = 0xffff0000;
                memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
            }
            assert(load_vertex_snapshot(fd) == 0);
            pg->draw_arrays_length = 0;
            after_ram_load();
            arrays(0, 3);
            close(fd);
        }
        end();
        NSError *error = nil;
        require([surfaces.cache waitUntilIdleWithError:&error], error);
        id<MTLTexture> target = surfaces.color.transfer.texture;
        assert(target.width == 16 && target.height == 16);
        assert(texture_pixel(target, 1, 1) == 0xff0000ff &&
               texture_pixel(target, 5, 5) == 0xffff0000 &&
               texture_pixel(target, 9, 9) == 0xffff0000);
        get_report(0);
        process_reports();
        assert(report_result(0) ==
               7); // GL divides old physical28 by current Scale^2.
        send_method(NV097_SET_BLEND_ENABLE, 0);
        begin(PRIM_TYPE_TRIANGLES);
        arrays(0, 3);
        end();
        require([surfaces.cache waitUntilIdleWithError:&error], error);
        assert(texture_pixel(surfaces.color.transfer.texture, 9, 9) ==
               0xffffff00);
    }
    groups++;
}
static void scanout_reuse(void)
{
    fixture();
    query_triangle(0);
    NSError *error = nil;
    NV2AMetalPGRAPHScanout *capture =
        [[NV2AMetalPGRAPHScanout alloc] initWithState:state
                                                cache:surfaces.cache
                                                error:&error];
    require(capture != nil, error);
    require([capture renderWithError:&error], error);
    NV2AMetalFramebuffer *first = capture.frame;
    assert(first && frame_pixel(first, 1, 1) == 0xff00ff00);
    for (unsigned i = 0; i < 128; i++) {
        require([capture renderWithError:&error], error);
        assert(capture.frame != first &&
               capture.frame.texture == first.texture &&
               !surfaces.cache.recording &&
               !surfaces.cache.commands.commandBuffer);
    }
    NV2AMetalSurfaceConfig config = surfaces.color.transfer.config;
    NV2AMetalCachedSurface *other =
        [surfaces.cache prepareSurfaceAtAddress:8192
                                         config:&config
                                          frame:0
                                          error:&error];
    require(other != nil, error);
    NV2AMetalSurfaceRecording *token = surfaces.cache.recording;
    id<MTL4CommandBuffer> commands = surfaces.cache.commands.commandBuffer;
    state->pgraph.frame_time = 7;
    require([capture renderWithError:&error], error);
    assert(capture.frame.texture == first.texture &&
           token == surfaces.cache.recording &&
           commands == surfaces.cache.commands.commandBuffer &&
           surfaces.color.frame == 7);
    [surfaces.cache cancel];
    require([surfaces.cache evictBeforeFrame:7 error:&error], error);
    assert(surfaces.color.valid && !other.valid);
    state->puserdac.palette[37 * 3] = 99;
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = VGA_SR01_SCREEN_OFF;
    require([capture renderWithError:&error], error);
    assert(capture.frame.texture == first.texture && capture.frame.screenOff &&
           (capture.frame.displayUniforms.palette[37] & 255) == 99 &&
           !first.screenOff && (first.displayUniforms.palette[37] & 255) == 37);
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = 0;
    cpu_write(1024, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t blue = 0xff0000ff;
        memcpy(state->vram_ptr + 1024 + i * 4, &blue, 4);
    }
    require([capture renderWithError:&error], error);
    NV2AMetalFramebuffer *blue = capture.frame;
    assert(blue.texture != first.texture &&
           frame_pixel(blue, 1, 1) == 0xff0000ff &&
           frame_pixel(first, 1, 1) == 0xff00ff00);
    query_triangle(0);
    require([capture renderWithError:&error], error);
    NV2AMetalFramebuffer *green = capture.frame;
    assert(green.texture != blue.texture &&
           frame_pixel(green, 1, 1) == 0xff00ff00 &&
           frame_pixel(blue, 1, 1) == 0xff0000ff);
    scan_pitch = 16;
    require([capture renderWithError:&error], error);
    assert(capture.frame.texture != green.texture);
    scan_pitch = 32;
    state->vga.cr[NV_PRMCIO_INTERLACE_MODE] = 0;
    require([capture renderWithError:&error], error);
    NV2AMetalFramebuffer *interlace = capture.frame;
    assert(interlace.texture.height == 16);
    state->vga.cr[NV_PRMCIO_INTERLACE_MODE] = NV_PRMCIO_INTERLACE_MODE_DISABLED;
    require([capture renderWithError:&error], error);
    NV2AMetalFramebuffer *normal = capture.frame;
    assert(normal.texture.height == 8 && normal.texture != interlace.texture);
    require([surfaces.cache markRTTSampling:surfaces.color error:&error],
            error);
    require([surfaces.cache submitWithError:&error], error);
    require([capture renderWithError:&error], error);
    assert(capture.frame.texture != normal.texture);
    id<MTLTexture> before = capture.frame.texture;
    [capture invalidate];
    assert(!capture.frame);
    require([capture renderWithError:&error], error);
    assert(capture.frame.texture != before);
    before = capture.frame.texture;
    state->pcrtc.start = 64000;
    require([capture renderWithError:&error], error);
    assert(!capture.frame);
    state->pcrtc.start = 1024;
    require([capture renderWithError:&error], error);
    assert(capture.frame.texture != before);
    assert(![surfaces.cache touchSurface:other frame:7 error:&error]);
    assert(![surfaces.cache touchSurface:nil frame:7 error:&error]);
    assert(frame_pixel(first, 1, 1) == 0xff00ff00);
    groups++;
}
static void scanout_frames(void)
{
    fixture();
    query_triangle(0);
    start_worker();
    NV2AMetalFramebuffer *first = copy_frame();
    assert(first.texture.width == 8 && first.texture.height == 8 &&
           !first.screenOff && first.displayUniforms.palette[37] == 0x252525 &&
           frame_pixel(first, 1, 1) == 0xff00ff00);
    assert(!state->pgraph.sync_pending && surfaces.color.dirty &&
           raw_color(1, 1) == 0xffff0000);
    NSError *error = nil;
    require([surfaces requestCPUAccessAtAddress:1024
                                         length:256
                                          write:YES
                                          error:&error],
            error);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t blue = 0xff0000ff;
        memcpy(state->vram_ptr + 1024 + i * 4, &blue, 4);
    }
    state->puserdac.palette[37 * 3] = 99;
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = VGA_SR01_SCREEN_OFF;
    NV2AMetalFramebuffer *second = copy_frame();
    assert(second.texture != first.texture && second.screenOff &&
           (second.displayUniforms.palette[37] & 255) == 99);
    assert(frame_pixel(second, 1, 1) == 0xff0000ff &&
           frame_pixel(first, 1, 1) == 0xff00ff00 &&
           (first.displayUniforms.palette[37] & 255) == 37);
    qemu_mutex_lock(&state->pgraph.renderer_lock);
    renderer.ops.set_surface_scale_factor(state, 2);
    qemu_mutex_unlock(&state->pgraph.renderer_lock);
    query_triangle(0);
    NV2AMetalFramebuffer *scaled = copy_frame();
    assert(scaled.texture.width == 16 && scaled.texture.height == 16 &&
           frame_pixel(scaled, 2, 2) == 0xff00ff00);
    assert(frame_pixel(first, 1, 1) == 0xff00ff00);
    state->vga.cr[NV_PRMCIO_INTERLACE_MODE] = 0;
    NV2AMetalFramebuffer *interlace = copy_frame();
    assert(interlace.texture.height == 32);
    state->pcrtc.start = 64000;
    assert(!copy_frame() && !state->pgraph.sync_pending);
    stop_worker();
    // Published frames survive frontend destruction with independent ownership.
    qemu_mutex_lock(&state->pgraph.lock);
    renderer.ops.finalize(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    assert(frame_pixel(first, 1, 1) == 0xff00ff00);
    groups++;
}
static void scanout_overlay(void)
{
    fixture();
    query_triangle(0);
    cpu_write(32768, 32);
    // Neutral YUY2 producing white, repeated over a 4x4 input.
    for (unsigned i = 0; i < 32; i += 4) {
        state->vram_ptr[32768 + i] = 235;
        state->vram_ptr[32768 + i + 1] = 128;
        state->vram_ptr[32768 + i + 2] = 235;
        state->vram_ptr[32768 + i + 3] = 128;
    }
    uint32_t *r = state->pvideo.regs;
    r[NV_PVIDEO_BUFFER] = NV_PVIDEO_BUFFER_0_USE;
    r[NV_PVIDEO_BASE] = 32768;
    r[NV_PVIDEO_LIMIT] = 32;
    r[NV_PVIDEO_SIZE_IN] = 4 | 4 << 16;
    r[NV_PVIDEO_SIZE_OUT] = 4 | 4 << 16;
    r[NV_PVIDEO_POINT_OUT] = 1 | 1 << 16;
    r[NV_PVIDEO_FORMAT] = 8 | NV_PVIDEO_FORMAT_COLOR_LE_CR8YB8CB8YA8 << 16;
    r[NV_PVIDEO_DS_DX] = r[NV_PVIDEO_DT_DY] = NV_PVIDEO_DIN_DOUT_UNITY;
    start_worker();
    NV2AMetalFramebuffer *overlay = copy_frame();
    assert(frame_pixel(overlay, 1, 1) == 0xffffffff &&
           frame_pixel(overlay, 6, 6) == 0xffff0000);
    // Larger input dimensions are capped to the scaled output, as in GL.
    r[NV_PVIDEO_SIZE_IN] = 8 | 8 << 16;
    NV2AMetalFramebuffer *capped = copy_frame();
    assert(frame_pixel(capped, 1, 1) == 0xffffffff);
    // A non-unity DIN/DOUT produces a one-pixel input after GL's rounding.
    r[NV_PVIDEO_SIZE_IN] = 4 | 4 << 16;
    r[NV_PVIDEO_SIZE_OUT] = 1 | 1 << 16;
    r[NV_PVIDEO_DS_DX] = r[NV_PVIDEO_DT_DY] = 0x00080000;
    NV2AMetalFramebuffer *small = copy_frame();
    assert(frame_pixel(small, 1, 1) == 0xffffffff);
    r[NV_PVIDEO_SIZE_OUT] = 4 | 4 << 16;
    r[NV_PVIDEO_DS_DX] = r[NV_PVIDEO_DT_DY] = NV_PVIDEO_DIN_DOUT_UNITY;
    r[NV_PVIDEO_FORMAT] |= NV_PVIDEO_FORMAT_DISPLAY;
    r[NV_PVIDEO_COLOR_KEY] = 0x00ff00;
    NV2AMetalFramebuffer *key = copy_frame();
    assert(frame_pixel(key, 1, 1) == 0xffffffff &&
           frame_pixel(key, 5, 5) == 0xffff0000);
    r[NV_PVIDEO_SIZE_IN] = UINT32_MAX;
    NV2AMetalFramebuffer *hidden = copy_frame();
    assert(frame_pixel(hidden, 1, 1) == 0xff00ff00);
    // PVIDEO can read GPU-owned framebuffer bytes: download on GPU before
    // YUY2 decode, rather than reading the stale red RAM contents.
    assert(surfaces.color.dirty && raw_color(1, 1) == 0xffff0000);
    r[NV_PVIDEO_BASE] = 1024;
    r[NV_PVIDEO_SIZE_IN] = 4 | 4 << 16;
    r[NV_PVIDEO_FORMAT] = 8 | 1 << 16;
    NV2AMetalFramebuffer *alias = copy_frame();
    assert(alias && !surfaces.color.dirty && raw_color(1, 1) == 0xff00ff00);
    assert(frame_pixel(alias, 1, 1) != frame_pixel(hidden, 1, 1));
    stop_worker();
    groups++;
}
static void scanout_capture_guards(void)
{
    fixture();
    query_triangle(0);
    NSError *error = nil;
    NV2AMetalPGRAPHScanout *capture =
        [[NV2AMetalPGRAPHScanout alloc] initWithState:state
                                                cache:surfaces.cache
                                                error:&error];
    require(capture != nil, error);
    scan_pitch = 64;
    assert(![capture renderWithError:&error]);
    scan_pitch = 32;
    state->pvideo.regs[NV_PVIDEO_BUFFER] = NV_PVIDEO_BUFFER_0_USE;
    state->pvideo.regs[NV_PVIDEO_SIZE_IN] =
        state->pvideo.regs[NV_PVIDEO_SIZE_OUT] = 4 | 4 << 16;
    state->pvideo.regs[NV_PVIDEO_FORMAT] =
        8 | NV_PVIDEO_FORMAT_COLOR_LE_CR8YB8CB8YA8 << 16;
    state->pvideo.regs[NV_PVIDEO_BASE] = 32768;
    state->pvideo.regs[NV_PVIDEO_LIMIT] = 31;
    state->pvideo.regs[NV_PVIDEO_DS_DX] = state->pvideo.regs[NV_PVIDEO_DT_DY] =
        NV_PVIDEO_DIN_DOUT_UNITY;
    assert(![capture renderWithError:&error]);
    state->pvideo.regs[NV_PVIDEO_LIMIT] = 32;
    state->pvideo.regs[NV_PVIDEO_FORMAT] = 6 | 1 << 16;
    assert(![capture renderWithError:&error]);
    // GL's RTT sampler history commits on submit and rolls back on cancel.
    NV2AMetalCachedSurface *surface = surfaces.color;
    assert(!surface.scanoutClampToBorder);
    require([surfaces.cache markRTTSampling:surface error:&error], error);
    assert(surface.scanoutClampToBorder);
    [surfaces.cache cancel];
    assert(!surface.scanoutClampToBorder);
    require([surfaces.cache markRTTSampling:surface error:&error], error);
    require([surfaces.cache submitWithError:&error], error);
    require([surfaces.cache waitUntilIdleWithError:&error], error);
    assert(surface.scanoutClampToBorder);
    groups++;
}
static void vga_ram_frames(void)
{
    unsigned modes[] = { 15, 16, 24, 32 };
    for (unsigned mode = 0; mode < 4; mode++) {
        fixture();
        state->vga.get_bpp = get_scan_bpp;
        scan_bpp = modes[mode];
        scan_start = 49152 / 4;
        scan_pitch = 32;
        scan_width = 8;
        scan_height = 4;
        state->pcrtc.start = 49152;
        cpu_write(49152, 128);
        memset(state->vram_ptr + 49152, 0, 128);
        unsigned bytes = scan_bpp <= 16 ? 2 : scan_bpp / 8;
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 8; x++) {
                uint8_t *q = state->vram_ptr + 49152 + y * 32 + x * bytes;
                if (scan_bpp == 15) {
                    uint16_t v = 0x7c00;
                    memcpy(q, &v, 2);
                } else if (scan_bpp == 16) {
                    uint16_t v = 0xf800;
                    memcpy(q, &v, 2);
                } else {
                    q[0] = 0;
                    q[1] = 0;
                    q[2] = 255;
                }
            }
        start_worker();
        NV2AMetalFramebuffer *frame = copy_frame();
        stop_worker();
        assert(frame && frame.texture.width == 8 && frame.texture.height == 4);
        assert(frame_pixel(frame, 3, 2) ==
               (mode < 2 ? 0xfff80000 : 0xffff0000));
    }
    groups++;
}
static void vga_split_and_repeat(void)
{
    fixture();
    state->vga.get_bpp = get_scan_bpp;
    scan_bpp = 32;
    scan_start = 49152 / 4;
    scan_pitch = 32;
    scan_height = 4;
    state->pcrtc.start = 49152;
    scan_compare = 1;
    cpu_write(0, 64);
    cpu_write(49152, 128);
    for (unsigned i = 0; i < 64; i += 4) {
        uint32_t green = 0xff00ff00;
        memcpy(state->vram_ptr + i, &green, 4);
    }
    for (unsigned i = 0; i < 128; i += 4) {
        uint32_t blue = 0xff0000ff;
        memcpy(state->vram_ptr + 49152 + i, &blue, 4);
    }
    start_worker();
    NV2AMetalFramebuffer *split = copy_frame();
    assert(frame_pixel(split, 1, 0) == 0xff0000ff &&
           frame_pixel(split, 1, 1) == 0xff0000ff &&
           frame_pixel(split, 1, 2) == 0xff00ff00);
    scan_compare = UINT32_MAX;
    state->vga.cr[VGA_CRTC_MAX_SCAN] = 1;
    uint32_t red = 0xffff0000;
    for (unsigned i = 0; i < 32; i += 4)
        memcpy(state->vram_ptr + 49152 + 32 + i, &red, 4);
    NV2AMetalFramebuffer *repeat = copy_frame();
    assert(frame_pixel(repeat, 1, 0) == 0xff0000ff &&
           frame_pixel(repeat, 1, 1) == 0xff0000ff &&
           frame_pixel(repeat, 1, 2) == 0xffff0000);
    stop_worker();
    groups++;
}
static void vga_gpu_owned_ram(void)
{
    fixture();
    query_triangle(0);
    assert(surfaces.color.dirty && raw_color(1, 0) == 0xffff0000);
    state->vga.get_bpp = get_scan_bpp;
    scan_bpp = 32;
    scan_start = 1024 / 4;
    scan_pitch = 256;
    scan_height = 1;
    // Cached lookup at start+pitch falls just outside the old 8x8 surface.
    start_worker();
    NV2AMetalFramebuffer *frame = copy_frame();
    stop_worker();
    assert(frame && frame.texture.height == 1 &&
           frame_pixel(frame, 1, 0) == 0xff00ff00 &&
           raw_color(1, 0) == 0xff00ff00);
    groups++;
}
static void vga_graphics_startup(void)
{
    fixture();
    state->vga.get_bpp = get_scan_bpp;
    scan_bpp = 0;
    scan_start = 32768 / 4;
    scan_pitch = 4;
    scan_height = 2;
    state->pcrtc.start = 32768;
    state->vga.dac_8bit = 1;
    for (unsigned i = 0; i < 256; i++) {
        state->vga.palette[i * 3] = i;
        state->vga.palette[i * 3 + 1] = 0;
        state->vga.palette[i * 3 + 2] = 0;
    }
    cpu_write(32768, 8);
    for (unsigned i = 0; i < 8; i++)
        state->vram_ptr[32768 + i] = 20 + i;
    start_worker();
    NV2AMetalFramebuffer *frame = copy_frame();
    assert(frame_pixel(frame, 0, 0) == 0xff140000 &&
           frame_pixel(frame, 1, 0) == 0xff140000 &&
           frame_pixel(frame, 2, 0) == 0xff150000);
    state->vga.ar_index = 0;
    NV2AMetalFramebuffer *blank = copy_frame();
    assert(frame_pixel(blank, 2, 0) == 0xff000000);
    // Text/glyph rendering has no hidden CPU or GL fallback.
    state->vga.ar_index = 0x20;
    state->vga.gr[VGA_GFX_MISC] = 0;
    assert(!copy_frame());
    stop_worker();
    groups++;
}
static void vga_text_frames(void)
{
    fixture();
    state->vga.get_bpp = get_scan_bpp;
    scan_bpp = 0;
    scan_start = 49152 / 4;
    scan_pitch = 8;
    state->pcrtc.start = 49152;
    state->vga.gr[VGA_GFX_MISC] = 0;
    state->vga.cr[VGA_CRTC_H_DISP] = 1;
    state->vga.cr[VGA_CRTC_MAX_SCAN] = 7;
    state->vga.cr[VGA_CRTC_V_DISP_END] = 15;
    state->vga.cr[VGA_CRTC_OVERFLOW] = 0;
    state->vga.sr[VGA_SEQ_CHARACTER_MAP] = 0;
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = VGA_SR01_CHAR_CLK_8DOTS;
    state->vga.cr[VGA_CRTC_CURSOR_START] = 0x20;
    for (unsigned i = 0; i < 16; i++) {
        state->vga.ar[i] = i;
        state->vga.palette[i * 3] = i == 1 ? 63 : 0;
        state->vga.palette[i * 3 + 1] = 0;
        state->vga.palette[i * 3 + 2] = 0;
    }
    state->vga.ar[VGA_ATC_MODE] = 0;
    state->vga.ar[VGA_ATC_COLOR_PAGE] = 0;
    cpu_write(0, 32768);
    cpu_write(49152, 16);
    memset(state->vram_ptr, 0, 32768);
    memset(state->vram_ptr + 49152, 0, 16);
    for (unsigned row = 0; row < 8; row++)
        state->vram_ptr[2 + 'A' * 128 + row * 4] = 0x81;
    for (unsigned i = 0; i < 4; i++) {
        state->vram_ptr[49152 + i * 4] = 'A';
        state->vram_ptr[49153 + i * 4] = 1;
    }
    start_worker();
    NV2AMetalFramebuffer *frame = copy_frame();
    assert(frame.texture.width == 16 && frame.texture.height == 16 &&
           frame_pixel(frame, 0, 0) == 0xffff0000 &&
           frame_pixel(frame, 1, 0) == 0xff000000 &&
           frame_pixel(frame, 7, 0) == 0xffff0000);
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = 8;
    NV2AMetalFramebuffer *wide = copy_frame();
    assert(wide.texture.width == 32 && frame_pixel(wide, 1, 0) == 0xffff0000 &&
           frame_pixel(wide, 2, 0) == 0xff000000);
    state->vga.sr[VGA_SEQ_CLOCK_MODE] = 0;
    state->vga.ar[VGA_ATC_MODE] = 4;
    state->vram_ptr[49152] = 0xb0;
    for (unsigned row = 0; row < 8; row++)
        state->vram_ptr[2 + 0xb0 * 128 + row * 4] = 1;
    NV2AMetalFramebuffer *nine = copy_frame();
    assert(nine.texture.width == 18 && frame_pixel(nine, 8, 0) == 0xffff0000);
    state->vga.cr[VGA_CRTC_CURSOR_START] = 2;
    state->vga.cr[VGA_CRTC_CURSOR_END] = 4;
    state->vga.cr[VGA_CRTC_CURSOR_HI] = 49152 / 4 >> 8;
    state->vga.cr[VGA_CRTC_CURSOR_LO] = 49152 / 4 & 255;
    state->vga.cursor_blink_time = INT64_MAX;
    state->vga.cursor_visible_phase = true;
    NV2AMetalFramebuffer *cursor = copy_frame();
    assert(frame_pixel(cursor, 2, 2) == 0xffff0000 &&
           frame_pixel(cursor, 2, 1) == 0xff000000);
    state->vga.cursor_visible_phase = false;
    NV2AMetalFramebuffer *off = copy_frame();
    assert(frame_pixel(off, 2, 2) == 0xff000000);
    state->vga.graphic_mode = 1;
    state->vga.cursor_visible_phase = false;
    NV2AMetalFramebuffer *blink = copy_frame();
    assert(state->vga.cursor_visible_phase &&
           frame_pixel(blink, 2, 2) == 0xffff0000);
    // Split occurs after the first complete character row, preserving GL's
    // rule.
    state->vga.cr[VGA_CRTC_CURSOR_START] = 0x20;
    scan_compare = 7;
    state->vram_ptr[0] = 'A';
    state->vram_ptr[1] = 1;
    NV2AMetalFramebuffer *split = copy_frame();
    assert(frame_pixel(split, 0, 8) == 0xffff0000);
    xemu_metal4_set_capture_frame((__bridge void *)split);
    size_t png_size = 0;
    void *png = xemu_metal4_capture_png(0, 0, 0, false, &png_size);
    assert(png && png_size > 24 && !memcmp(png, "\x89PNG\r\n\x1a\n", 8));
    const uint8_t *bytes = png;
    assert(ldl_be_p(bytes + 16) == 18 && ldl_be_p(bytes + 20) == 16);
    free(png);
    xemu_metal4_set_capture_frame(NULL);
    stop_worker();
    groups++;
}
static void registered_backend_startup(void)
{
    fixture();
    qemu_mutex_lock(&state->pgraph.lock);
    draw = nil;
    surfaces = nil;
    renderer.ops.finalize(state);
    qemu_mutex_unlock(&state->pgraph.lock);
    state->pgraph.surface_scale_factor = 0;
    g_config.display.quality.surface_scale = 2;
    nv2a_context_init();
    assert(g_config.display.renderer == CONFIG_DISPLAY_RENDERER_METAL4);
    pgraph_init_thread(state);
    const PGRAPHRenderer *actual = state->pgraph.renderer;
    assert(actual && actual->type == CONFIG_DISPLAY_RENDERER_METAL4 &&
           actual->ops.copy_framebuffer == pgraph_metal4_copy_framebuffer &&
           actual->ops.draw_begin == pgraph_metal4_draw_begin &&
           actual->ops.surface_flush == pgraph_metal4_surface_flush &&
           actual->ops.pre_restore_trigger ==
               pgraph_metal4_pre_restore_trigger);
    assert(state->pgraph.surface_scale_factor == 2);
    draw = (__bridge NV2AMetalPGRAPHDraw *)pgraph_metal4_draw_handle(state);
    surfaces = draw.surfaces;
    state->vga.get_bpp = get_scan_bpp;
    scan_bpp = 32;
    start_worker();
    qemu_mutex_lock(&state->pgraph.renderer_lock);
    void *handle = actual->ops.copy_framebuffer(state);
    qemu_mutex_unlock(&state->pgraph.renderer_lock);
    NV2AMetalFramebuffer *frame = (__bridge NV2AMetalFramebuffer *)handle;
    assert(frame && frame.texture.width == 8 && frame.texture.height == 8);
    nv2a_release_metal4_framebuffer(handle);
    stop_worker();
    groups++;
}
static void *request_global_frame(void *opaque)
{
    assert(opaque == state);
    @autoreleasepool {
        requested_frame = nv2a_copy_metal4_framebuffer();
    }
    return NULL;
}
static void *stop_global_requests(void *opaque)
{
    assert(opaque == state);
    qemu_event_set(&host_stop_started);
    pgraph_stop_metal4_host_requests(state);
    qatomic_set(&host_stopped, true);
    return NULL;
}
static void global_frame_lifetime(void)
{
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    draw = nil;
    surfaces = nil;
    renderer.ops.finalize(state);
    qemu_mutex_unlock(&pg->lock);
    for (unsigned i = 0; i < 16; i++)
        g_free(pg->vertex_attributes[i].inline_buffer);
    qemu_event_destroy(&pg->flush_complete);
    qemu_event_destroy(&pg->sync_complete);
    qemu_mutex_destroy(&pg->renderer_lock);
    qemu_mutex_destroy(&pg->lock);
    memset(pg, 0, sizeof(*pg));
    assert(!nv2a_copy_metal4_framebuffer());
    nv2a_release_metal4_framebuffer(NULL);
    pgraph_init(state);
    assert(g_nv2a == state && !nv2a_copy_metal4_framebuffer());
    assert(nv2a_get_surface_scale_factor() == 1);
    nv2a_set_surface_scale_factor(3); // No renderer before thread init.
    pgraph_init_thread(state);
    draw = (__bridge NV2AMetalPGRAPHDraw *)pgraph_metal4_draw_handle(state);
    surfaces = draw.surfaces;
    worker_common = true;
    start_worker();
    nv2a_set_surface_scale_factor(3);
    assert(nv2a_get_surface_scale_factor() == 3);
    void *owned = nv2a_copy_metal4_framebuffer();
    NV2AMetalFramebuffer *frame = (__bridge NV2AMetalFramebuffer *)owned;
    assert(frame);
    uint32_t saved_pixel = frame_pixel(frame, 1, 1);
    stop_worker();
    before_ram_load();
    for (unsigned i = 0; i < 65536 / 4; i++)
        stl_le_p(state->vram_ptr + i * 4, 0xff123456);
    after_ram_load();
    start_worker();
    void *restored = nv2a_copy_metal4_framebuffer();
    NV2AMetalFramebuffer *restored_frame =
        (__bridge NV2AMetalFramebuffer *)restored;
    assert(restored_frame && frame_pixel(frame, 1, 1) == saved_pixel);
    uint32_t restored_pixel = frame_pixel(restored_frame, 1, 1);
    assert(restored_pixel != saved_pixel);
    qemu_event_init(&worker_paused, false);
    qemu_event_init(&worker_resume, false);
    qemu_event_init(&host_stop_started, false);
    qatomic_set(&worker_pause, true);
    QemuThread getter, stopper;
    qemu_thread_create(&getter, "metal-global-frame", request_global_frame,
                       state, QEMU_THREAD_JOINABLE);
    qemu_event_wait(&worker_paused);
    qemu_thread_create(&stopper, "metal-global-stop", stop_global_requests,
                       state, QEMU_THREAD_JOINABLE);
    qemu_event_wait(&host_stop_started);
    assert(!qatomic_read(&host_stopped));
    qatomic_set(&worker_pause, false);
    qemu_event_set(&worker_resume);
    qemu_thread_join(&getter);
    qemu_thread_join(&stopper);
    assert(requested_frame && host_stopped && !g_nv2a);
    assert(!nv2a_copy_metal4_framebuffer());
    assert(nv2a_get_surface_scale_factor() == 1);
    nv2a_set_surface_scale_factor(2);
    assert(pg->surface_scale_factor == 3);
    pgraph_stop_metal4_host_requests(state); // Repeated unpublish is harmless.
    stop_worker();
    qemu_event_destroy(&worker_paused);
    qemu_event_destroy(&worker_resume);
    qemu_event_destroy(&host_stop_started);
    draw = nil;
    surfaces = nil;
    pgraph_destroy(pg);
    assert(!pg->renderer && !pg->metal4_renderer_state && !hook);
    pgraph_metal4_finalize(state);
    pgraph_metal4_finalize(state);
    free(state->vram_ptr);
    state->vram_ptr = NULL;
    assert(frame_pixel(frame, 1, 1) == saved_pixel);
    assert(frame_pixel((__bridge NV2AMetalFramebuffer *)requested_frame, 1,
                       1) == restored_pixel);
    assert(frame_pixel(restored_frame, 1, 1) == restored_pixel);
    nv2a_release_metal4_framebuffer(owned);
    nv2a_release_metal4_framebuffer(requested_frame);
    nv2a_release_metal4_framebuffer(restored);
    requested_frame = NULL;
    groups++;
}
static unsigned legacy_context_calls;
static void legacy_context_probe(void)
{
    legacy_context_calls++;
}
static void additive_backend_selection(void)
{
    fixture();
    qemu_event_init(&state->pgraph.renderer_switch_complete, false);
    static const PGRAPHRenderer gl = {
        .type = CONFIG_DISPLAY_RENDERER_OPENGL,
        .name = "OpenGL selection probe",
        .ops.early_context_init = legacy_context_probe,
    };
    static const PGRAPHRenderer vk = {
        .type = CONFIG_DISPLAY_RENDERER_VULKAN,
        .name = "Vulkan selection probe",
        .ops.early_context_init = legacy_context_probe,
    };
    pgraph_renderer_register(&gl);
    pgraph_renderer_register(&vk);
    g_config.display.renderer = CONFIG_DISPLAY_RENDERER_OPENGL;
    nv2a_context_init();
    assert(g_config.display.renderer == CONFIG_DISPLAY_RENDERER_OPENGL);
    assert(legacy_context_calls == 2);
    qemu_mutex_lock(&state->pfifo.lock);
    pgraph_process_pending(state);
    assert(state->pgraph.renderer == &renderer);
    assert(state->pgraph.renderer_switch_phase ==
           PGRAPH_RENDERER_SWITCH_PHASE_IDLE);
    state->pgraph.renderer_switch_phase =
        PGRAPH_RENDERER_SWITCH_PHASE_CPU_WAITING;
    pgraph_process_pending(state);
    assert(state->pgraph.renderer == &renderer);
    assert(state->pgraph.renderer_switch_phase ==
           PGRAPH_RENDERER_SWITCH_PHASE_IDLE);
    qemu_mutex_unlock(&state->pfifo.lock);
    qemu_event_wait(&state->pgraph.renderer_switch_complete);
    g_config.display.renderer = CONFIG_DISPLAY_RENDERER_VULKAN;
    nv2a_context_init();
    assert(g_config.display.renderer == CONFIG_DISPLAY_RENDERER_VULKAN);
    assert(legacy_context_calls == 4);
    g_config.display.renderer = CONFIG_DISPLAY_RENDERER_METAL4;
    nv2a_context_init();
    assert(g_config.display.renderer == CONFIG_DISPLAY_RENDERER_METAL4);
    assert(legacy_context_calls == 4);
    qemu_event_destroy(&state->pgraph.renderer_switch_complete);
    groups++;
}
static void legacy_snapshot_cleanup(void)
{
    static const PGRAPHRenderer legacy = {
        .type = CONFIG_DISPLAY_RENDERER_OPENGL,
        .name = "Legacy snapshot ownership probe",
    };
    NV2AState *d = g_new0(NV2AState, 1);
    pgraph_init(d);
    d->pgraph.renderer = &legacy;
    d->pgraph.metal4_report_snapshot = g_malloc0(32);
    d->pgraph.metal4_report_snapshot_size = 32;
    d->pgraph.metal4_vertex_capture = g_malloc0(64);
    d->pgraph.metal4_vertex_capture_size = 64;
    d->pgraph.metal4_begin_capture = g_malloc0(128);
    d->pgraph.metal4_begin_capture_size = 128;
    pgraph_stop_metal4_host_requests(d);
    pgraph_destroy(&d->pgraph);
    assert(!d->pgraph.metal4_report_snapshot &&
           !d->pgraph.metal4_report_snapshot_size &&
           !d->pgraph.metal4_vertex_capture &&
           !d->pgraph.metal4_vertex_capture_size &&
           !d->pgraph.metal4_begin_capture &&
           !d->pgraph.metal4_begin_capture_size);
    g_free(d);
    groups++;
}
static void idx_bits(float value, uint32_t expected)
{
    uint32_t actual;
    memcpy(&actual, &value, sizeof(actual));
    if (actual != expected) {
        fprintf(stderr, "PGRAPH IDX raw: got %08x, expected %08x\n", actual,
                expected);
        abort();
    }
}

static void idx_immediate_methods(void)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    PGRAPHRenderer legacy = renderer;
    legacy.type = CONFIG_DISPLAY_RENDERER_OPENGL;
    for (unsigned family = 0; family < 2; family++) {
        pg->renderer = family ? &renderer : &legacy;
        for (unsigned value = 0; value < 256; value++) {
            uint32_t packed = 0;
            for (unsigned k = 0; k < 4; k++)
                packed |= ((value + 31 * k) & 255) << (8 * k);
            for (unsigned target = 1; target < 18; target++) {
                unsigned attr = target < 16 ? target : target == 16 ? 3 : 4;
                unsigned method = target < 16 ?
                                      NV097_SET_VERTEX_DATA4UB + 4 * target :
                                  target == 16 ? NV097_SET_DIFFUSE_COLOR4UB :
                                                 NV097_SET_SPECULAR_COLOR4UB;
                send_method(method, packed);
                for (unsigned k = 0; k < 4; k++) {
                    unsigned code = (value + 31 * k) & 255;
                    idx_bits(pg->vertex_attributes[attr].inline_value[k],
                             family ? idx_ubyte[code] : idx_ubyte_legacy[code]);
                }
            }
        }
        for (unsigned i = 0; i < G_N_ELEMENTS(idx_short); i++) {
            unsigned next = (i + 17) % G_N_ELEMENTS(idx_short);
            uint32_t word =
                idx_short[i].code | ((uint32_t)idx_short[next].code << 16);
            pg->vertex_attributes[2].inline_value[2] = 7;
            pg->vertex_attributes[2].inline_value[3] = 3;
            send_method(NV097_SET_NORMAL3S, word);
            idx_bits(pg->vertex_attributes[2].inline_value[0],
                     family ? idx_short[i].bits : idx_short[i].legacy);
            idx_bits(pg->vertex_attributes[2].inline_value[1],
                     family ? idx_short[next].bits : idx_short[next].legacy);
            idx_bits(pg->vertex_attributes[2].inline_value[2],
                     family ? 0 : 0x40e00000);
            idx_bits(pg->vertex_attributes[2].inline_value[3],
                     family ? 0x3f800000 : 0x40400000);
            send_method(NV097_SET_NORMAL3S + 4, word);
            idx_bits(pg->vertex_attributes[2].inline_value[2],
                     family ? idx_short[i].bits : idx_short[i].legacy);
            idx_bits(pg->vertex_attributes[2].inline_value[3],
                     family ? 0x3f800000 : idx_short[next].legacy);
        }
        uint32_t initial[4] = { 0x80000000, 0x7fc12345, 0, 0xbf800000 };
        memcpy(pg->vertex_attributes[2].inline_value, initial, 16);
        send_method(NV097_SET_NORMAL3S + 4, 0);
        idx_bits(pg->vertex_attributes[2].inline_value[0], initial[0]);
        idx_bits(pg->vertex_attributes[2].inline_value[1], initial[1]);
        idx_bits(pg->vertex_attributes[2].inline_value[2],
                 family ? 0x37800080 : 0);
        idx_bits(pg->vertex_attributes[2].inline_value[3],
                 family ? initial[3] : 0);
        if (family) {
            const float normal[4] = { 0, 0, 1, 1 };
            memcpy(pg->vertex_attributes[2].inline_value, normal, 16);
            send_method(NV097_SET_POINT_SIZE, 8);
            begin(NV097_SET_BEGIN_END_OP_POINTS);
            for (unsigned vertex = 0; vertex < 2; vertex++) {
                uint32_t packed = 0xff000000;
                for (unsigned k = 0; k < 3; k++)
                    packed |= (31 + vertex * 32 + k * 32) << (8 * k);
                send_method(NV097_SET_VERTEX_DATA4UB, packed);
            }
            assert(pg->inline_buffer_length == 2 &&
                   pg->vertex_attributes[0].inline_buffer_populated);
            for (unsigned vertex = 0; vertex < 2; vertex++)
                for (unsigned k = 0; k < 4; k++)
                    idx_bits(
                        pg->vertex_attributes[0].inline_buffer[4 * vertex + k],
                        idx_ubyte[k == 3 ? 255 : 31 + vertex * 32 + k * 32]);
            end();
        }
        groups++;
    }
    pg->renderer = &renderer;
    puts("Metal4 IDX immediate: all256UB/135Short patterns; legacy bits and "
         "three-component normal defaults PASS");
}

#include "test-metal-vertex-context.h"
static void state_tokens(unsigned start, unsigned row, BOOL feedback)
{
    PGRAPHState *pg = &state->pgraph;
    Token t = token(feedback ? 3 : 1, 0, row);
    source(&t, 0, feedback ? 3 : 2, 0, 0xe4);
    if (feedback)
        source(&t, 2, 2, 0, 0xe4);
    destination(&t, row, 15, 0, 0, 0, 0);
    t.word[3] |= !feedback;
    memcpy(pg->program_data[start], t.word, sizeof(t.word));
    if (feedback) {
        for (unsigned slot = 1; slot < 3; slot++) {
            Token out = token(1, 0, 0);
            out.word[1] |= (slot == 1 ? 0u : 3u) << 9;
            source(&out, 0, 2, 0, 0xe4);
            destination(&out, slot == 1 ? 0 : 3, 15, 0, 0, 0, 0);
            out.word[3] |= 1u << 11 | (slot == 2);
            memcpy(pg->program_data[start + slot], out.word, sizeof(out.word));
        }
    }
}
static float state_constant(unsigned row, unsigned component)
{
    float value;
    memcpy(&value, &state->pgraph.vsh_constants[row][component], 4);
    return value;
}
static void pending_subsection_rejections(void)
{
    PGRAPHState *pg = &state->pgraph;
    const VMStateField *field = vmstate_nv2a_metal4_pending_capture.fields;
    uint8_t *original = pg->metal4_pending_capture;
    uint32_t originalSize = pg->metal4_pending_capture_size;
    NSData *originalBytes = [NSData dataWithBytes:original length:originalSize];
    for (unsigned fault = 0; fault < 7; fault++) {
        NSMutableData *bad = [originalBytes mutableCopy];
        if (fault < 4)
            stl_be_p((uint8_t *)bad.mutableBytes +
                         (fault == 3 ? 24 : fault * 4),
                     UINT32_MAX);
        if (fault == 4)
            [bad setLength:bad.length - 1];
        int fd = new_vertex_snapshot_file();
        QEMUFile *out = vertex_snapshot_file(fd, true);
        qemu_put_be32(out, pg->primitive_mode + (fault == 5));
        qemu_put_be32(out, fault == 6 ? NV2A_METAL_PENDING_CAPTURE_MAX + 1 :
                                        bad.length);
        qemu_put_buffer(out, bad.bytes, bad.length);
        assert(qemu_fclose(out) == 0);
        QEMUFile *in = vertex_snapshot_file(fd, false);
        int result = field->info->get(in, pg, field->size, field);
        if (result >= 0)
            fprintf(stderr, "Pending subsection accepted fault %u\n", fault);
        assert(result < 0);
        qemu_fclose(in);
        close(fd);
        assert(pg->metal4_pending_capture == original &&
               pg->metal4_pending_capture_size == originalSize &&
               !memcmp(original, originalBytes.bytes, originalSize));
    }
}
static void state_boundary_tests(void)
{
    const unsigned primitives[] = { PRIM_TYPE_TRIANGLE_STRIP,
                                    PRIM_TYPE_TRIANGLE_FAN, PRIM_TYPE_POLYGON };
    const unsigned changes[] = { NV097_SET_TRANSFORM_PROGRAM,
                                 NV097_SET_TRANSFORM_CONSTANT,
                                 NV097_SET_TRANSFORM_EXECUTION_MODE,
                                 NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN,
                                 NV097_SET_TRANSFORM_PROGRAM_START };
    unsigned cases = 0;
    for (unsigned nop = 0; nop < 2; nop++)
        for (unsigned primitive = 0; primitive < 3; primitive++)
            for (unsigned change = 0; change < 5; change++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                send_method(NV097_SET_TRANSFORM_EXECUTION_MODE, 2 | 1u << 2);
                send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN, 1);
                /* Vertex v0 adds the actual position to c191 for every vertex.
                 */
                state_tokens(0, 191, YES);
                memset(pg->vsh_constants[191], 0, 16);
                state_tokens(9, 190, NO);
                if (nop) {
                    send_method(NV097_SET_COLOR_MASK, 0);
                    send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                }
                begin(primitives[primitive]);
                arrays(0, 3);
                uint32_t parameter = change == 2 ? 2 | 1u << 2 :
                                     change == 3 ? 1 :
                                                   0;
                if (change == 0)
                    parameter = pg->program_data[0][0];
                if (change == 1)
                    send_method(NV097_SET_TRANSFORM_CONSTANT_LOAD, 191);
                send_method(changes[change], parameter);
                assert(pg->draw_arrays_length == 1 &&
                       pg->draw_arrays_count[0] == 3 &&
                       pg->primitive_mode == primitives[primitive] &&
                       pg->draw_time == 0);
                assert(state_constant(191, 1) == 8 &&
                       state_constant(191, 3) == 3);
                uint32_t repairWord = 0;
                if (change == 0) {
                    /* Invalid intermediate words are not decoded without a
                     * suffix.
                     */
                    repairWord = pg->program_data[0][1];
                    send_method(NV097_SET_TRANSFORM_PROGRAM + 4, UINT32_MAX);
                    /* Keep this program invalid through State-RUN and VMState.
                     * The old capture and retained prefix remain usable. */
                }
                const float launch[4] = { 11, 22, 33, 44 };
                for (unsigned k = 0; k < 4; k++) {
                    uint32_t bits;
                    memcpy(&bits, launch + k, 4);
                    send_method(NV097_SET_TRANSFORM_DATA + k * 4, bits);
                }
                send_method(NV097_LAUNCH_TRANSFORM_PROGRAM, 9);
                assert(state_constant(190, 0) == 11 &&
                       state_constant(190, 3) == 44);
                assert(state_constant(191, 1) == 8 &&
                       state_constant(191, 3) == 3);
                assert(pg->draw_time == 0 && color(1, 1) == 0xffff0000);
                /* Save/load the already transformed prefix while replacement
                 * state still needs capture. Restoring must not execute the
                 * prefix again.
                 */
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                assert(pg->metal4_pending_capture_size &&
                       pgraph_metal4_validate_pending_capture(
                           pg->metal4_pending_capture,
                           pg->metal4_pending_capture_size));
                if (!cases)
                    pending_subsection_rejections();
                int fd = new_vertex_snapshot_file();
                save_snapshot_parent(fd, &array_snapshot_parent);
                before_ram_load();
                assert(!pg->metal4_pending_capture_size);
                assert(load_snapshot_parent(fd, &array_snapshot_parent) == 0);
                assert(pg->metal4_pending_capture_size);
                close(fd);
                after_ram_load();
                if (change == 0)
                    send_method(NV097_SET_TRANSFORM_PROGRAM + 4, repairWord);
                arrays(3, 1);
                send_method(NV097_LAUNCH_TRANSFORM_PROGRAM, 9);
                assert(state_constant(191, 1) == 8 &&
                       state_constant(191, 3) == 4);
                end();
                assert(pg->draw_time == !nop && state_constant(191, 3) == 4);
                assert(color(1, 1) == (nop ? 0xffff0000 : 0xff00ff00));
                if (nop) {
                    get_report(0);
                    process_reports();
                    assert(report_result(0) == 0);
                }
                cases++;
            }
    /* State LAUNCH is independent of ordinary vertex WriteEnable. The CPU
     * fallback remains available when a renderer supplies no native callback.
     */
    for (unsigned native = 0; native < 2; native++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        send_method(NV097_SET_TRANSFORM_EXECUTION_MODE, 2 | 1u << 2);
        state_tokens(9, 191, NO);
        send_float_method(NV097_SET_TRANSFORM_DATA, 27);
        PGRAPHRenderer fallback = renderer;
        fallback.ops.launch_transform_program = NULL;
        if (!native)
            pg->renderer = &fallback;
        send_method(NV097_LAUNCH_TRANSFORM_PROGRAM, 9);
        pg->renderer = &renderer;
        assert(state_constant(191, 0) == 27 &&
               !pg->enable_vertex_program_write);
    }
    assert(cases == 30);
    printf("Native State boundaries: %u primitive/mutation/save-restore cases; "
           "real VMState roundtrips/seven rejected subsection loads, "
           "unfinished uploads across VMState, NOP XF, no pre-End raster, "
           "zero NOP query, exact suffix counts, "
           "WriteEnable independence and callback-null CPU fallback PASS\n",
           cases);
    groups++;
}

static void missing_attachment_vertex_tests(void)
{
    unsigned cases = 0;
    for (unsigned full = 0; full < 2; full++)
        for (unsigned variant = 0; variant < 4; variant++) {
            BOOL writes = variant < 2;
            fixture();
            PGRAPHState *pg = &state->pgraph;
            send_method(NV097_SET_TRANSFORM_EXECUTION_MODE,
                        2 | (full ? 1u << 2 : 0));
            send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN, writes);
            state_tokens(0, 191, YES);
            memset(pg->vsh_constants[191], 0, 16);
            begin(PRIM_TYPE_TRIANGLES);
            send_method(NV097_SET_SURFACE_CLIP_HORIZONTAL, 4 << 16);
            send_method(NV097_CLEAR_SURFACE, 0);
            assert(!surfaces.color && !surfaces.zeta);
            float current[4];
            memcpy(current, pg->vertex_attributes[0].inline_value, 16);
            if (variant == 3) {
                renderer.ops.pre_savevm_trigger(state);
                process_pending();
                renderer.ops.pre_savevm_wait(state);
                int fd = new_vertex_snapshot_file();
                save_vertex_snapshot(fd);
                arrays(0, 3);
                end();
                before_ram_load();
                assert(load_vertex_snapshot(fd) == 0);
                pg->draw_arrays_length = 0;
                after_ram_load();
                close(fd);
                assert(!surfaces.color && !surfaces.zeta);
            }
            if (!writes)
                dma[2].limit = 0;
            arrays(0, 3);
            if (variant == 1) {
                qemu_mutex_lock(&pg->lock);
                NSError *error = nil;
                require([draw prepareVertexStateChangeWithError:&error], error);
                qemu_mutex_unlock(&pg->lock);
                assert(state_constant(191, 1) == 8 &&
                       state_constant(191, 3) == 3);
            }
            end();
            assert(
                state_constant(191, 1) == (writes ? 8 : 0) &&
                state_constant(191, 3) == (writes ? 3 : 0) &&
                !memcmp(current, pg->vertex_attributes[0].inline_value, 16) &&
                !surfaces.color && !surfaces.zeta);
            assert(color(1, 1) == 0xffff0000);
            dma[2].limit = 1023;
            cases++;
        }
    assert(cases == 8);
    groups++;
    puts("Missing attachments XF:8 USER/FULL/write-policy/restore cases; "
         "writes once or invalid DMA skipped, Current/pixels preserved PASS");
}

static void raw_surface_draw_tests(void)
{
    unsigned cases = 0;
    for (unsigned full = 0; full < 2; full++)
        for (unsigned writes = 0; writes < 2; writes++)
            for (unsigned restore = 0; restore < 2; restore++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                send_method(NV097_SET_TRANSFORM_EXECUTION_MODE,
                            2 | (full ? 1u << 2 : 0));
                send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN, writes);
                state_tokens(0, 191, YES);
                memset(pg->vsh_constants[191], 0, 16);
                send_method(NV097_SET_COLOR_MASK, 0);
                send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
                pg->surface_binding_dim.width = pg->surface_binding_dim.height =
                    0;
                float current[4];
                memcpy(current, pg->vertex_attributes[0].inline_value, 16);
                begin(PRIM_TYPE_TRIANGLES);
                NSData *capture = draw.vertexSnapshot;
                assert(capture.length > 8 &&
                       ldl_be_p((const uint8_t *)capture.bytes + 4) == 6);
                assert(!surfaces.color && !surfaces.zeta &&
                       !surfaces.cache.count);
                arrays(0, 3);
                if (restore) {
                    send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN,
                                writes);
                    assert(state_constant(191, 1) == (writes ? 8 : 0) &&
                           state_constant(191, 3) == (writes ? 3 : 0));
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    assert(pg->metal4_pending_capture_size);
                    int fd = new_vertex_snapshot_file();
                    save_snapshot_parent(fd, &array_snapshot_parent);
                    before_ram_load();
                    assert(load_snapshot_parent(fd, &array_snapshot_parent) ==
                           0);
                    after_ram_load();
                    close(fd);
                    arrays(3, 1);
                }
                end();
                assert(state_constant(191, 1) == (writes ? 8 : 0) &&
                       state_constant(191, 3) ==
                           (writes ? (restore ? 4 : 3) : 0) &&
                       !memcmp(current, pg->vertex_attributes[0].inline_value,
                               16));
                assert(!surfaces.color && !surfaces.zeta &&
                       !surfaces.cache.count && !pg->draw_time);
                for (unsigned i = 0; i < 64; i++)
                    assert((uint32_t)ldl_le_p(state->vram_ptr + 1024 + i * 4) ==
                           0xffff0000);
                get_report(0);
                process_reports();
                assert(report_result(0) == 0);
                cases++;
            }
    assert(cases == 8);
    groups++;
    puts(
        "Raw Draw Surface0:8 USER/FULL/write/outer-VMState cases; exact prefix "
        "once/suffix once, Current/red VRAM preserved, no "
        "attachments/drawtime/query PASS");
}
static void raw_raster_restore_rejection(void)
{
    fixture();
    send_method(NV097_SET_TRANSFORM_EXECUTION_MODE, 2 | 1u << 2);
    send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN, 1);
    state_tokens(0, 191, YES);
    send_method(NV097_SET_COLOR_MASK, 0);
    begin(PRIM_TYPE_TRIANGLES);
    NSData *raw = draw.vertexSnapshot;
    assert(ldl_be_p((const uint8_t *)raw.bytes + 4) == 6);
    fixture();
    begin(PRIM_TYPE_TRIANGLES);
    NSError *error = nil;
    NSData *raster = [draw beginSnapshotWithError:&error];
    require(raster != nil, error);
    fixture();
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    pg->primitive_mode = PRIM_TYPE_TRIANGLES;
    require([draw restoreVertexSnapshot:raw error:&error], error);
    require([draw restoreBeginSnapshot:raster error:&error], error);
    error = nil;
    assert(
        ![draw beginWithError:&error] && error &&
        [error.localizedDescription
            isEqualToString:@"Raw XF capture cannot restore a raster Begin"]);
    [draw invalidateSession];
    pg->primitive_mode = PRIM_TYPE_INVALID;
    qemu_mutex_unlock(&pg->lock);
    groups++;
    puts("Raw capture paired with raster Begin explicitly rejected before "
         "drawing PASS");
}

static void fixed_surface_draw_tests(void)
{
    unsigned cases = 0;
    for (unsigned full = 0; full < 2; full++)
        for (unsigned writes = 0; writes < 2; writes++)
            for (unsigned restore = 0; restore < 2; restore++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                send_method(NV097_SET_TRANSFORM_EXECUTION_MODE,
                            full ? 1u << 2 : 0);
                send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN, writes);
                send_method(NV097_SET_COLOR_MASK, 0);
                send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
                memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
                pg->surface_binding_dim.width = pg->surface_binding_dim.height =
                    0;
                uint32_t constants[192][4];
                memcpy(constants, pg->vsh_constants, sizeof(constants));
                float current[4];
                memcpy(current, pg->vertex_attributes[0].inline_value,
                       sizeof(current));
                begin(PRIM_TYPE_TRIANGLES);
                NSData *capture = draw.vertexSnapshot;
                assert(ldl_be_p((const uint8_t *)capture.bytes + 4) == 6 &&
                       !(ldl_be_p((const uint8_t *)capture.bytes + 8) & 1));
                arrays(0, 3);
                if (restore) {
                    renderer.ops.pre_savevm_trigger(state);
                    process_pending();
                    renderer.ops.pre_savevm_wait(state);
                    int fd = new_vertex_snapshot_file();
                    save_snapshot_parent(fd, &array_snapshot_parent);
                    before_ram_load();
                    assert(load_snapshot_parent(fd, &array_snapshot_parent) ==
                           0);
                    after_ram_load();
                    close(fd);
                    arrays(3, 1);
                }
                end();
                assert(
                    !memcmp(constants, pg->vsh_constants, sizeof(constants)) &&
                    !memcmp(current, pg->vertex_attributes[0].inline_value,
                            sizeof(current)));
                assert(!surfaces.color && !surfaces.zeta &&
                       !surfaces.cache.count && !pg->draw_time);
                for (unsigned i = 0; i < 64; i++)
                    assert((uint32_t)ldl_le_p(state->vram_ptr + 1024 + i * 4) ==
                           0xffff0000);
                get_report(0);
                process_reports();
                assert(report_result(0) == 0);
                cases++;
            }
    assert(cases == 8);
    groups++;
    puts(
        "Fixed Raw Draw Surface0:8 USER/FULL/write/VMState cases; "
        "constants/Current/VRAM preserved, no attachments/drawtime/query PASS");
}
static void fixed_program_surface_switch_tests(void)
{
    unsigned cases = 0;
    for (unsigned direction = 0; direction < 2; direction++)
        for (unsigned full = 0; full < 2; full++)
            for (unsigned writes = 0; writes < 2; writes++)
                for (unsigned restore = 0; restore < 2; restore++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    send_method(NV097_SET_TRANSFORM_EXECUTION_MODE,
                                (direction ? 2 : 0) | (full ? 1u << 2 : 0));
                    send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN,
                                writes);
                    state_tokens(0, 191, YES);
                    memset(pg->vsh_constants[191], 0, 16);
                    send_method(NV097_SET_COLOR_MASK, 0);
                    memset(&pg->surface_shape, 0, sizeof(pg->surface_shape));
                    pg->surface_binding_dim.width =
                        pg->surface_binding_dim.height = 0;
                    uint32_t expected[192][4];
                    memcpy(expected, pg->vsh_constants, sizeof(expected));
                    float positions[6][4], sum[4] = { 0 };
                    memcpy(positions, state->vram_ptr + 16384,
                           sizeof(positions));
                    float current[4];
                    memcpy(current, pg->vertex_attributes[0].inline_value,
                           sizeof(current));
                    begin(PRIM_TYPE_TRIANGLES);
                    arrays(0, 3);
                    send_method(NV097_SET_TRANSFORM_EXECUTION_MODE,
                                (direction ? 0 : 2) | (full ? 1u << 2 : 0));
                    assert(state_constant(191, 3) ==
                           (direction && writes ? 3 : 0));
                    arrays(3, 1);
                    if (restore) {
                        renderer.ops.pre_savevm_trigger(state);
                        process_pending();
                        renderer.ops.pre_savevm_wait(state);
                        int fd = new_vertex_snapshot_file();
                        save_snapshot_parent(fd, &array_snapshot_parent);
                        before_ram_load();
                        assert(load_snapshot_parent(
                                   fd, &array_snapshot_parent) == 0);
                        after_ram_load();
                        close(fd);
                        arrays(4, 1);
                    }
                    end();
                    if (writes)
                        for (unsigned v = direction ? 0 : 3;
                             v < (direction ? 3u :
                                  restore   ? 5u :
                                              4u);
                             v++)
                            for (unsigned k = 0; k < 4; k++)
                                sum[k] += positions[v][k];
                    memcpy(expected[191], sum, sizeof(sum));
                    assert(!memcmp(expected, pg->vsh_constants,
                                   sizeof(expected)) &&
                           !memcmp(current,
                                   pg->vertex_attributes[0].inline_value,
                                   sizeof(current)));
                    assert(!surfaces.color && !surfaces.zeta &&
                           !surfaces.cache.count && !pg->draw_time);
                    for (unsigned i = 0; i < 64; i++)
                        assert((uint32_t)ldl_le_p(state->vram_ptr + 1024 +
                                                  i * 4) == 0xffff0000);
                    cases++;
                }
    assert(cases == 16);
    groups++;
    puts("Fixed/program Raw Draw Surface0:16 both-direction "
         "USER/FULL/write/VMState switches; prefix and suffix context writes "
         "exactly once, no Fixed writes, Current/VRAM preserved PASS");
}

static void save_capture_request(void)
{
    renderer.ops.pre_savevm_trigger(state);
    qemu_event_set(&worker_kick);
    renderer.ops.pre_savevm_wait(state);
}
static bool save_capture_status(void *opaque, Error **errp)
{
    return pgraph_metal4_pre_save_check(opaque, errp);
}
static void save_vmstate_check(bool success)
{
    const VMStateDescription parent = {
        .name = "nv2a-save-status-test",
        .version_id = 4,
        .minimum_version_id = 1,
        .pre_save_errp = save_capture_status,
        .fields = (VMStateField[]){ VMSTATE_END_OF_LIST() },
    };
    int fd = new_vertex_snapshot_file();
    QEMUFile *file = vertex_snapshot_file(fd, true);
    Error *error = NULL;
    qemu_mutex_lock(&state->pgraph.lock);
    int result = vmstate_save_state(file, &parent, state, NULL, &error);
    qemu_mutex_unlock(&state->pgraph.lock);
    if (success)
        assert(result == 0 && !error);
    else {
        assert(result == -EINVAL && error &&
               strstr(error_get_pretty(error),
                      "Pending capture exceeds aggregate limit"));
        assert(qemu_file_transferred(file) == 0);
    }
    error_free(error);
    assert(qemu_fclose(file) == 0);
    close(fd);
}

/* The save worker acknowledges completion while still holding pg->lock.
 * Join that critical section before comparing state, and exclude the host
 * mutex internals; their bytes are not emulated PGRAPH state. */
static NSData *save_pgraph_bytes(void)
{
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    NSMutableData *bytes = [NSMutableData dataWithBytes:pg length:sizeof(*pg)];
    memset((uint8_t *)bytes.mutableBytes + offsetof(PGRAPHState, lock), 0,
           sizeof(pg->lock));
    memset((uint8_t *)bytes.mutableBytes + offsetof(PGRAPHState, renderer_lock),
           0, sizeof(pg->renderer_lock));
    qemu_mutex_unlock(&pg->lock);
    return bytes;
}

static void pending_save_capacity_tests(void)
{
    unsigned cases = 0;
    for (unsigned over = 0; over < 2; over++)
        @autoreleasepool {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            send_method(NV097_SET_COLOR_MASK, 0);
            pg->surface_shape = (SurfaceShape){ 0 };
            pg->surface_scale_factor = 1;
            for (unsigned attribute = 0; attribute < 16; attribute++)
                pg->vertex_attributes[attribute].count = 0;
            const float position[4] = { 1, 2, 3, 1 };
            memcpy(pg->vertex_attributes[0].inline_value, position, 16);
            begin(PRIM_TYPE_POINTS);
            start_worker();
            arrays(0, 2);
            send_method(NV097_SET_TRANSFORM_EXECUTION_MODE, 0);
            save_capture_request();
            assert(pgraph_metal4_pre_save_check(state, NULL));
            assert(pg->metal4_begin_capture_size &&
                   pg->metal4_vertex_capture_size &&
                   pg->metal4_pending_capture_size &&
                   pg->metal4_report_snapshot_size);
            /* Eight independent Begins, each with 256 contiguous DrawArrays
             * methods. The real lookahead path squashes only End/Begin pairs.
             * Every submitted start is <= 65280 and each count is <= 256. */
            for (unsigned range = 0; range < 8; range++) {
                for (unsigned part = 0; part < 255; part++)
                    arrays(range == 0 && part == 0 ? 2 : part * 256,
                           range == 0 && part == 0 ? 254 : 256);
                uint32_t last =
                    65280 | ((over || range != 7 ? 255u : 254u) << 24);
                if (range != 7) {
                    uint32_t params[] = { last,
                                          NV097_SET_BEGIN_END,
                                          0,
                                          NV097_SET_BEGIN_END,
                                          PRIM_TYPE_POINTS,
                                          NV097_DRAW_ARRAYS,
                                          255u << 24,
                                          0 };
                    assert(method(NV097_DRAW_ARRAYS, last, params, 1, 7,
                                  false) == 5);
                } else
                    send_method(NV097_DRAW_ARRAYS, last);
            }
            assert(pg->draw_arrays_length == 8 && !pg->inline_elements_length);
            NSUInteger total = 0;
            for (unsigned range = 0; range < 8; range++) {
                assert(pg->draw_arrays_start[range] == 0 &&
                       pg->draw_arrays_count[range] ==
                           (range == 7 && !over ? 65535 : 65536));
                total += pg->draw_arrays_count[range];
            }
            assert(total == 524287u + over);
            NSData *vram = [NSData dataWithBytes:state->vram_ptr length:65536];
            NSData *before = save_pgraph_bytes();
            NSError *error = nil;
            send_method(NV097_SET_TRANSFORM_EXECUTION_MODE, 0);
            assert([before isEqualToData:save_pgraph_bytes()] &&
                   !memcmp(vram.bytes, state->vram_ptr, 65536) &&
                   !surfaces.color && !surfaces.zeta && !surfaces.cache.count);
            NSData *vertex = draw.vertexSnapshot;
            assert(vertex.length);
            NSData *saved = [draw pendingSnapshotWithError:&error];
            if (over) {
                assert(!saved && error &&
                       [error.localizedDescription
                           isEqualToString:
                               @"Pending capture exceeds aggregate limit"]);
                error = nil;
                send_method(NV097_SET_TRANSFORM_EXECUTION_MODE, 0);
                assert([draw.vertexSnapshot isEqualToData:vertex]);
                saved = [draw pendingSnapshotWithError:&error];
                assert(!saved && error &&
                       [error.localizedDescription
                           isEqualToString:
                               @"Pending capture exceeds aggregate limit"]);
                for (unsigned retry = 0; retry < 2; retry++) {
                    save_capture_request();
                    Error *saveError = NULL;
                    assert(!pgraph_metal4_pre_save_check(state, &saveError) &&
                           saveError);
                    assert(strstr(error_get_pretty(saveError),
                                  "Pending capture exceeds aggregate limit"));
                    error_free(saveError);
                    assert([before isEqualToData:save_pgraph_bytes()]);
                    save_vmstate_check(false);
                    assert([before isEqualToData:save_pgraph_bytes()]);
                }
            } else {
                require(saved != nil, error);
                assert(pgraph_metal4_validate_pending_capture(saved.bytes,
                                                              saved.length));
                NV2AMetalPendingArchive *archive =
                    [[NV2AMetalPendingArchive alloc]
                        initWithData:[saved
                                         subdataWithRange:NSMakeRange(
                                                              12, saved.length -
                                                                      12)]
                               limit:524287
                               error:&error];
                require(archive != nil, error);
                assert(archive.inputs.count == 8 &&
                       saved.length == 12 + 20 + 8 * 16 + total * 244);
                for (NSData *bytes in archive.vertices)
                    for (NSUInteger i = 0; i < bytes.length; i++)
                        assert(((const uint8_t *)bytes.bytes)[i] == 0);
                NV2AMetalPendingJournal *restored = nv2a_metal_pending_restore(
                    archive, surfaces.cache.commands, NSUIntegerMax, &error);
                require(restored != nil, error);
                NV2AMetalPendingArchive *again = nv2a_metal_pending_capture(
                    restored, surfaces.cache.commands, &error);
                require(again != nil, error);
                assert([again.data isEqualToData:archive.data]);
                printf(
                    "Capacity exact boundary: %lu transformed vertices, "
                    "%lu canonical snapshot bytes, private GPU restore/capture "
                    "byte-identical PASS\n",
                    (unsigned long)total, (unsigned long)saved.length);
            }
            assert([before isEqualToData:save_pgraph_bytes()] &&
                   !memcmp(vram.bytes, state->vram_ptr, 65536) &&
                   !surfaces.cache.commands.commandBuffer);
            end();
            error = nil;
            assert([draw pendingSnapshotWithError:&error].length == 0 &&
                   !error);
            assert(
                !pg->draw_time && !surfaces.color && !surfaces.zeta &&
                !memcmp(vram.bytes, state->vram_ptr, 65536) &&
                !memcmp(pg->vertex_attributes[0].inline_value, position, 16));
            printf("Capacity frontier: %lu vertices, eight actual squashed "
                   "ranges, %s; PGRAPH/Current/VRAM unchanged, End consumes "
                   "and snapshot recovers PASS\n",
                   (unsigned long)total,
                   over ? "two snapshot rejections reproduced" :
                          "snapshot accepted");
            save_capture_request();
            assert(pgraph_metal4_pre_save_check(state, NULL));
            save_vmstate_check(true);
            stop_worker();
            printf(
                "Save-error candidate: previous four captures retained on "
                "failure, "
                "worker wait completes, VMState status rejects before fields; "
                "End then successful retry PASS\n");
            cases++;
        }
    assert(cases == 2);
    groups++;
}


static void save_snapshot_faults(void)
{
    const SEL selectors[] = { @selector(beginSnapshotWithError:),
                              @selector(pendingSnapshotWithError:),
                              @selector(reportSnapshotWithError:),
                              @selector(reportSnapshotWithError:) };
    unsigned cases = 0;
    for (unsigned programmed = 0; programmed < 2; programmed++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        send_method(NV097_SET_COLOR_MASK, 0);
        pg->surface_shape = (SurfaceShape){ 0 };
        pg->surface_scale_factor = 1;
        for (unsigned a = 0; a < 16; a++)
            pg->vertex_attributes[a].count = 0;
        const float position[4] = { 1, 2, 3, 1 };
        memcpy(pg->vertex_attributes[0].inline_value, position, 16);
        if (programmed) {
            send_method(NV097_SET_TRANSFORM_EXECUTION_MODE, 2 | 1u << 2);
            send_method(NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN, 1);
            state_tokens(0, 191, YES);
        }
        begin(PRIM_TYPE_POINTS);
        arrays(0, 3);
        send_method(NV097_SET_TRANSFORM_EXECUTION_MODE,
                    programmed ? 2 | 1u << 2 : 0);
        start_worker();
        save_capture_request();
        assert(pgraph_metal4_pre_save_check(state, NULL));
        uint32_t constants[192][4];
        memcpy(constants, pg->vsh_constants, sizeof(constants));
        NSData *vram = [NSData dataWithBytes:state->vram_ptr length:65536];
        for (unsigned fault = 0; fault < 4; fault++) {
            NSData *before = save_pgraph_bytes();
            NSArray<NSData *> *captures = @[
                [NSData dataWithBytes:pg->metal4_begin_capture
                               length:pg->metal4_begin_capture_size],
                [NSData dataWithBytes:pg->metal4_vertex_capture
                               length:pg->metal4_vertex_capture_size],
                [NSData dataWithBytes:pg->metal4_pending_capture
                               length:pg->metal4_pending_capture_size],
                [NSData dataWithBytes:pg->metal4_report_snapshot
                               length:pg->metal4_report_snapshot_size]
            ];
            for (NSData *capture in captures)
                assert(capture.length);
            Method target =
                class_getInstanceMethod(draw.class, selectors[fault]);
            assert(target);
            IMP original = method_getImplementation(target);
            IMP injected = imp_implementationWithBlock(^NSData *(
                id owner, NSError **error) {
              (void)owner;
              if (error && fault != 3)
                  *error = [NSError errorWithDomain:@"xemu.audit.save"
                                               code:1
                                           userInfo:@{
                                               NSLocalizedDescriptionKey :
                                                   @"Injected snapshot failure"
                                           }];
              return nil;
            });
            method_setImplementation(target, injected);
            for (unsigned retry = 0; retry < 2; retry++) {
                save_capture_request();
                Error *error = NULL;
                assert(!pgraph_metal4_pre_save_check(state, &error) && error);
                assert(strstr(error_get_pretty(error),
                              fault == 3 ? "Cannot capture native save state" :
                                           "Injected snapshot failure"));
                error_free(error);
                assert([before isEqualToData:save_pgraph_bytes()] &&
                       !memcmp(vram.bytes, state->vram_ptr, 65536));
                assert(!memcmp(captures[0].bytes, pg->metal4_begin_capture,
                               captures[0].length) &&
                       !memcmp(captures[1].bytes, pg->metal4_vertex_capture,
                               captures[1].length) &&
                       !memcmp(captures[2].bytes, pg->metal4_pending_capture,
                               captures[2].length) &&
                       !memcmp(captures[3].bytes, pg->metal4_report_snapshot,
                               captures[3].length));
                cases++;
            }
            method_setImplementation(target, original);
            assert(imp_removeBlock(injected));
            save_capture_request();
            assert(pgraph_metal4_pre_save_check(state, NULL));
            save_vmstate_check(true);
            assert(!memcmp(constants, pg->vsh_constants, sizeof(constants)) &&
                   !memcmp(vram.bytes, state->vram_ptr, 65536));
        }
        end();
        assert(!memcmp(constants, pg->vsh_constants, sizeof(constants)) &&
               !memcmp(pg->vertex_attributes[0].inline_value, position, 16));
        stop_worker();
    }
    assert(cases == 16);
    groups++;
    puts("Save snapshot faults:16 fixed/program/retry cases across Begin, "
         "Pending and Report plus missing NSError; all four previous capture "
         "pointers/sizes/bytes retained, worker wakes, successful retry clears "
         "status; constants/Current/VRAM unchanged and no XF replay PASS");
}

#include "test-metal-facing.h"
#include "test-metal-xf-boundaries.h"
#include "test-metal-array-current.h"
#include "test-metal-packed-inline.h"
#include "test-metal-dma-inline.h"
#include "test-metal-xf-upload-restore.h"

static BOOL (*blit_write_original)(id, SEL, NSUInteger, NSUInteger, NSError **);
static unsigned blit_write_captures;
static BOOL blit_write_probe(id object, SEL selector, NSUInteger address,
                             NSUInteger length, NSError **error)
{
    BOOL ok = blit_write_original(object, selector, address, length, error);
    if (ok && length) {
        NV2AMetalSurfaceCache *cache = object;
        NSError *check = nil;
        for (unsigned write = 0; write < 2; write++) {
            BOOL completed = YES;
            require([cache tryIdleCPUAccessAtAddress:address length:length
                                              write:write completed:&completed
                                              error:&check], check);
            assert(!completed);
        }
        blit_write_captures++;
    }
    return ok;
}
static void blit_coherence_tests(void)
{
    Method registration = class_getInstanceMethod(NV2AMetalSurfaceCache.class,
        @selector(prepareGPUWriteAtAddress:length:error:));
    assert(registration);
    blit_write_captures = 0;
    blit_write_original = (void *)method_setImplementation(registration,
                                                           (IMP)blit_write_probe);
    blit_method_formats();
    blit_tile_tail();
    blit_surface_alias();
    blit_validation();
    blit_submission_tests();
    method_setImplementation(registration, (IMP)blit_write_original);
    assert(blit_write_captures == 64);
    puts("PGRAPH blit coherence:64 real destination registrations protect "
         "CPU reads/writes; full RAM format/operation/tail/alias and validation PASS");
}

#include "test-metal-pending-locks.h"
#ifdef NV2A_METAL_REPORT_FILE_TEST
#include "test-metal-report-file.h"
#endif

int main(int argc, char **argv)
{
    bool pendingLocks = argc == 2 && !strcmp(argv[1], "--pending-locks");
    bool reportsOnly = argc == 2 && !strcmp(argv[1], "--reports");
#ifdef NV2A_METAL_REPORT_FILE_TEST
    bool reportFileOnly = argc == 2 && !strcmp(argv[1], "--report-file");
#else
    bool reportFileOnly = false;
#endif
    bool blitCoherence = argc == 2 && !strcmp(argv[1], "--blit-coherence");
    bool surfaceRelease = argc == 2 && !strcmp(argv[1], "--surface-release");
    bool packedFloatCurrent =
        argc == 2 && !strcmp(argv[1], "--packed-float-current");
    bool facingParity = argc == 2 && !strcmp(argv[1], "--facing-parity");
    bool xfRestore = argc == 2 && !strcmp(argv[1], "--xf-upload-restore");
    bool prefixRotations =
        argc == 2 && !strcmp(argv[1], "--w-prefix-rotations");
    bool arrayCurrent =
        argc == 2 && !strcmp(argv[1], "--array-current-restore");
    bool xfBoundaries = argc == 2 && !strcmp(argv[1], "--xf-between-draws");
    bool stateBoundaries = argc == 2 && !strcmp(argv[1], "--state-boundaries");
    bool idx = argc == 2 && !strcmp(argv[1], "--idx-normalization");
    bool cubeAF = argc == 2 && !strcmp(argv[1], "--hilo16-cube-af-begin");
    bool cubeDot = argc == 2 && !strcmp(argv[1], "--hilo16-cube-dot-begin");
    bool cubeLookup =
        argc == 2 && !strcmp(argv[1], "--hilo16-cube-lookup-begin");
    bool cubeBRDF = argc == 2 && !strcmp(argv[1], "--hilo16-cube-brdf-begin");
    bool volumeBRDF =
        argc == 2 && !strcmp(argv[1], "--hilo16-volume-brdf-begin");
    assert(argc == 1 || pendingLocks || reportsOnly || reportFileOnly || surfaceRelease ||
           packedFloatCurrent || blitCoherence || facingParity || xfRestore ||
           prefixRotations || arrayCurrent || xfBoundaries || stateBoundaries ||
           idx || cubeAF || cubeDot || cubeLookup || cubeBRDF || volumeBRDF);
    if (prefixRotations || cubeAF || cubeDot || cubeLookup || cubeBRDF ||
        volumeBRDF)
        setvbuf(stdout, NULL, _IONBF, 0);
    module_call_init(MODULE_INIT_QOM);
    @autoreleasepool {
        state = g_new0(NV2AState, 1);
        state->vram = g_new0(MemoryRegion, 1);
        assert(
            !posix_memalign((void **)&state->vram_ptr, getpagesize(), 65536));
        memset(state->vram_ptr, 0, 65536);
        qemu_mutex_init(&state->pgraph.lock);
        qemu_mutex_init(&state->pgraph.renderer_lock);
        qemu_mutex_init(&state->pfifo.lock);
#ifdef NV2A_METAL_REPORT_FILE_TEST
        if (reportFileOnly) {
            report_file_tests();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
#endif
        if (packedFloatCurrent) {
            inline_data();
            packed_float_immediate_current();
            packed_inline_current_tests();
            dma_inline_current_tests();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (pendingLocks) {
            pending_lock_tests();
            lifecycle();
            scale_and_cpu_requests();
            dirty_restore();
            submitted_download_restore();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (reportsOnly) {
            report_queue();
            report_rejections();
            report_flush_and_retry();
            report_scale_and_lifecycle();
            report_alias_and_bounds();
            report_arithmetic();
            cancelled_restore_before_device_load();
            restore_rejection_preserves_active_begin();
            report_snapshot_roundtrip();
            report_snapshot_invalid();
            report_snapshot_scale();
            report_snapshot_cleared_active();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (surfaceRelease) {
            deferred_surface_release();
            lifecycle();
            scale_and_cpu_requests();
            dirty_restore();
            submitted_download_restore();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (blitCoherence) {
            blit_coherence_tests();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (facingParity) {
            pgraph_facing_parity();
            two_side_begin_snapshot();
            begin_capture();
            restored_binding_metadata();
            frozen_begin_snapshot();
            raw_raster_restore_rejection();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (xfRestore || xfBoundaries || arrayCurrent || prefixRotations) {
            if (xfRestore) {
                xf_upload_restore();
                vertex_snapshot_invalid();
            } else if (prefixRotations)
                w_prefix_rotations();
            else if (arrayCurrent)
                array_current_restore();
            else
                xf_between_draws();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (idx || stateBoundaries) {
            if (stateBoundaries) {
                pending_save_capacity_tests();
                save_snapshot_faults();
                fixed_surface_draw_tests();
                fixed_program_surface_switch_tests();
                raw_surface_draw_tests();
                raw_raster_restore_rejection();
                state_boundary_tests();
            } else
                idx_immediate_methods();
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        if (cubeAF || cubeDot || cubeLookup || cubeBRDF || volumeBRDF) {
            if (cubeBRDF || volumeBRDF) {
                for (unsigned combination = 0; combination < 4; combination++)
                    hilo16_gpu_brdf_begin_snapshot(volumeBRDF, combination);
            } else
                for (unsigned kind = cubeLookup ? 4 :
                                     cubeAF     ? 1 :
                                                  2;
                     kind < (cubeLookup ? 5u :
                             cubeAF     ? 2u :
                                          4u);
                     kind++) {
                    hilo16_gpu_cube_begin_snapshot(NO, kind);
                    hilo16_gpu_cube_begin_snapshot(YES, kind);
                }
            qemu_mutex_lock(&state->pgraph.lock);
            draw = nil;
            surfaces = nil;
            renderer.ops.finalize(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            goto cleanup;
        }
        pending_save_capacity_tests();
        save_snapshot_faults();
        fixed_surface_draw_tests();
        fixed_program_surface_switch_tests();
        raw_surface_draw_tests();
        raw_raster_restore_rejection();

        idx_immediate_methods();
        boundaries();
        begin_capture();
        point_sprite_begin_snapshot();
        rectangle_point_sprite_begin_snapshot();
        pgraph_facing_parity();
        two_side_begin_snapshot();
        lookahead();
        array_expansion();
        inline_data();
        packed_float_immediate_current();
        packed_inline_current_tests();
        dma_inline_current_tests();
        validation_and_retry();
        flushed_stencil();
        deferred_surface_release();
        lifecycle();
        scale_and_cpu_requests();
        surface_registers_preserve_begin();
        explicit_surface_rebind();
        explicit_attachment_masks();
        clear_inside_begin();
        restored_binding_metadata();
        clear_zero_binding_changes();
        missing_attachment_vertex_tests();
        clear_aa_swizzle_begin();
        depth_replace_snapshot();
        float_surface_shadow_snapshot(NO);
        float_surface_shadow_snapshot(YES);
        f24_gradient_begin_snapshot(NO, 0);
        for (unsigned clipping = 0; clipping < 3; clipping++)
            f24_gradient_begin_snapshot(YES, clipping);
        w_polygon_begin_snapshot(PRIM_TYPE_TRIANGLES, NO, 0);
        w_polygon_begin_snapshot(PRIM_TYPE_QUADS, NO, 0);
        w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, NO, 0);
        w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 2, 0);
        for (unsigned input = 1; input <= 5; input++)
            w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 2, input);
        for (unsigned input = 0; input <= 2; input++)
            w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 3, input);
        w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 3, 6);
        w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 3, 7);
        w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 3, 8);
        w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 3, 9);
        w_polygon_begin_snapshot(PRIM_TYPE_QUAD_STRIP, 3, 10);
        w_clip_begin_snapshot();
        readonly_zeta_bindings();
        packed_color_channels();
        packed_color_rtt();
        packed_color_alpha_test();
        xo_surface_draws();
        xo_surface_clears();
        xo_surface_alpha_test();
        xo_surface_dither();
        a7_surface_draws();
        a7_surface_clears();
        hilo_snapshot();
        hilo16_brdf_begin_snapshot();
        physical_border_begin_snapshot();
        convolution_begin_snapshot(NO);
        convolution_begin_snapshot(YES);
        hilo16_af_begin_snapshot(NO, 0);
        hilo16_af_begin_snapshot(YES, 0);
        for (unsigned kind = 1; kind < 13; kind++) {
            hilo16_af_begin_snapshot(NO, kind);
            hilo16_af_begin_snapshot(YES, kind);
        }
        hilo16_gpu_cube_begin_snapshot(NO, 0);
        hilo16_gpu_cube_begin_snapshot(YES, 0);
        legacy_cube_begin_snapshot();
        constant_eye_snapshot();
        bump_luminance_snapshot();
        bump_result_snapshot();
        signed_texture_snapshot();
        signed_dot_snapshot();
        passthrough_snapshot();
        scale_preserves_begin();
        quiescence_preserves_begin();
        quiescence_preserves_texture();
        active_block_flush();
        dirty_restore();
        cancelled_restore();
        submitted_download_restore();
        restored_active_block();
        report_queue();
        report_rejections();
        report_flush_and_retry();
        report_scale_and_lifecycle();
        report_alias_and_bounds();
        report_arithmetic();
        cancelled_restore_before_device_load();
        restore_rejection_preserves_active_begin();
        report_snapshot_roundtrip();
        report_snapshot_invalid();
        report_snapshot_scale();
        report_snapshot_cleared_active();
        xf_upload_restore();
        vertex_snapshot_open_block();
        vertex_snapshot_invalid();
        back_material_methods();
        fixed_snapshot_shader();
        frozen_vertex_snapshot();
        frozen_begin_snapshot();
        frozen_texture_snapshot();
        compressed_inline_rebind();
        end_live_nop();
        blit_method_formats();
        blit_tile_tail();
        blit_surface_alias();
        blit_validation();
        blit_submission_tests();
        scanout_reuse();
        scanout_frames();
        scanout_overlay();
        scanout_capture_guards();
        pending_lock_tests();
        vga_ram_frames();
        vga_split_and_repeat();
        vga_gpu_owned_ram();
        vga_graphics_startup();
        vga_text_frames();
        additive_backend_selection();
        registered_backend_startup();
        global_frame_lifetime();
        legacy_snapshot_cleanup();
    cleanup:
        assert(!hook && !state->pgraph.metal4_renderer_state);
        qemu_mutex_destroy(&state->pfifo.lock);
        free(state->vram_ptr);
        g_free(state->vram);
        g_free(state);
        printf(
            "Metal 4 callbacks: %u dispatcher groups, %u real methods PASS\n",
            groups, methods);
    }
    return 0;
}
