/* Native PGRAPH renderer callback boundary, from gl/renderer.c and gl/draw.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "ui/xemu-settings.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "draw-pgraph.h"
#import "scanout-pgraph.h"
#import "vertex-pgraph.h"
#include "renderer.h"

typedef struct NV2AMetalRendererState {
    void *draw, *scanout;
    QemuEvent save_complete, shutdown_complete, scale_complete,
        restore_complete;
    bool save_pending, shutdown_pending, scale_pending, resume_begin;
    bool restore_pending, load_pending;
    unsigned int requested_scale;
    char *save_error;
    bool diagnostics;
    uint64_t diagnostic_begins, diagnostic_ends, diagnostic_clears,
        diagnostic_syncs, diagnostic_flips;
} NV2AMetalRendererState;

static NV2AMetalRendererState *renderer_state(NV2AState *d)
{
    assert(d && d->pgraph.metal4_renderer_state);
    return d->pgraph.metal4_renderer_state;
}
static NV2AMetalPGRAPHDraw *renderer_draw(NV2AState *d)
{
    return (__bridge NV2AMetalPGRAPHDraw *)renderer_state(d)->draw;
}
static NV2AMetalPGRAPHScanout *renderer_scanout(NV2AState *d)
{
    return (__bridge NV2AMetalPGRAPHScanout *)renderer_state(d)->scanout;
}
void *pgraph_metal4_copy_framebuffer(NV2AState *d)
{
    qemu_mutex_lock(&d->pfifo.lock);
    qemu_event_reset(&d->pgraph.sync_complete);
    qatomic_set(&d->pgraph.sync_pending, true);
    pfifo_kick(d);
    qemu_mutex_unlock(&d->pfifo.lock);
    qemu_event_wait(&d->pgraph.sync_complete);
    qemu_mutex_lock(&d->pgraph.lock);
    void *frame = (__bridge_retained void *)renderer_scanout(d).frame;
    qemu_mutex_unlock(&d->pgraph.lock);
    return frame;
}
void pgraph_metal4_release_framebuffer(void *handle)
{
    id frame = (__bridge_transfer id)handle;
    (void)frame;
}
void *pgraph_metal4_draw_handle(NV2AState *d)
{
    return renderer_state(d)->draw;
}
static void check_draw(BOOL ok, NSError *error)
{
    if (!ok) {
        error_report("Metal 4 PGRAPH: %s",
                     error.localizedDescription.UTF8String);
        /* The callback interface cannot return failure. Match the GL fatal
         * validation policy rather than dropping an invalid guest draw. */
        abort();
    }
}
void pgraph_metal4_init(NV2AState *d, Error **errp)
{
    @autoreleasepool {
        if (!d || d->pgraph.metal4_renderer_state) {
            error_setg(errp,
                       "Metal 4 PGRAPH requires an uninitialized renderer");
            return;
        }
        if (!d->pgraph.surface_scale_factor) {
            int scale = g_config.display.quality.surface_scale;
            if (scale > 16384) {
                error_setg(errp, "Invalid Metal 4 startup surface scale %d",
                           scale);
                return;
            }
            d->pgraph.surface_scale_factor = MAX(1, scale);
        }
        NSError *error = nil;
        NV2AMetalPGRAPHSurfaces *surfaces =
            [[NV2AMetalPGRAPHSurfaces alloc] initWithState:d error:&error];
        NV2AMetalPGRAPHDraw *draw =
            surfaces ? [[NV2AMetalPGRAPHDraw alloc] initWithState:d
                                                         surfaces:surfaces
                                                            error:&error] :
                       nil;
        NV2AMetalPGRAPHScanout *scanout =
            draw ? [[NV2AMetalPGRAPHScanout alloc] initWithState:d
                                                           cache:surfaces.cache
                                                           error:&error] :
                   nil;
        if (!draw || !scanout) {
            error_setg(errp, "Metal 4 PGRAPH: %s",
                       error.localizedDescription.UTF8String);
            if (surfaces)
                [surfaces closeWithError:nil];
            return;
        }
        NV2AMetalRendererState *state = g_new0(NV2AMetalRendererState, 1);
        state->diagnostics =
            g_strcmp0(g_getenv("XEMU_METAL4_DIAGNOSTICS"), "1") == 0;
        state->draw = (__bridge_retained void *)draw;
        state->scanout = (__bridge_retained void *)scanout;
        qemu_event_init(&state->save_complete, false);
        qemu_event_init(&state->shutdown_complete, false);
        qemu_event_init(&state->scale_complete, false);
        qemu_event_init(&state->restore_complete, false);
        d->pgraph.metal4_renderer_state = state;
        d->pgraph.uniform_attrs = d->pgraph.swizzle_attrs = 0;
    }
}
void pgraph_metal4_finalize(NV2AState *d)
{
    @autoreleasepool {
        if (!d || !d->pgraph.metal4_renderer_state)
            return;
        NV2AMetalPGRAPHDraw *draw = renderer_draw(d);
        NSError *error = nil;
        BOOL ok = [draw closeWithError:&error];
        check_draw(ok, error);
        NV2AMetalRendererState *state = renderer_state(d);
        assert(!qatomic_read(&state->save_pending) &&
               !qatomic_read(&state->shutdown_pending) &&
               !qatomic_read(&state->scale_pending) &&
               !qatomic_read(&state->restore_pending) &&
               !qatomic_read(&state->load_pending));
        id owner = (__bridge_transfer id)state->draw;
        id scanout_owner = (__bridge_transfer id)state->scanout;
        [renderer_scanout(d) invalidate];
        qemu_event_destroy(&state->save_complete);
        qemu_event_destroy(&state->shutdown_complete);
        qemu_event_destroy(&state->scale_complete);
        qemu_event_destroy(&state->restore_complete);
        d->pgraph.metal4_renderer_state = NULL;
        g_free(d->pgraph.metal4_report_snapshot);
        d->pgraph.metal4_report_snapshot = NULL;
        d->pgraph.metal4_report_snapshot_size = 0;
        g_free(d->pgraph.metal4_vertex_capture);
        d->pgraph.metal4_vertex_capture = NULL;
        d->pgraph.metal4_vertex_capture_size = 0;
        g_free(d->pgraph.metal4_begin_capture);
        d->pgraph.metal4_begin_capture = NULL;
        d->pgraph.metal4_begin_capture_size = 0;
        g_free(d->pgraph.metal4_pending_capture);
        d->pgraph.metal4_pending_capture = NULL;
        d->pgraph.metal4_pending_capture_size = 0;
        g_free(state->save_error);
        g_free(state);
        (void)owner;
        (void)scanout_owner;
    }
}
static void resume_begin(NV2AState *d)
{
    NV2AMetalRendererState *state = renderer_state(d);
    if (!state->resume_begin)
        return;
    state->resume_begin = false;
    if (d->pgraph.primitive_mode != PRIM_TYPE_INVALID) {
        NSError *error = nil;
        BOOL ok = [renderer_draw(d) beginWithError:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_draw_begin(NV2AState *d)
{
    @autoreleasepool {
        NV2AMetalRendererState *state = renderer_state(d);
        if (state->diagnostics)
            state->diagnostic_begins++;
        NSError *error = nil;
        BOOL ok = [renderer_draw(d) beginWithError:&error];
        check_draw(ok, error);
        renderer_state(d)->resume_begin = false;
    }
}
void pgraph_metal4_flush_draw(NV2AState *d)
{
    @autoreleasepool {
        NSError *error = nil;
        resume_begin(d);
        BOOL ok = [renderer_draw(d) flushDrawWithError:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_vertex_state_change(NV2AState *d)
{
    @autoreleasepool {
        NSError *error = nil;
        resume_begin(d);
        BOOL ok = [renderer_draw(d) prepareVertexStateChangeWithError:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_launch_transform_program(NV2AState *d, unsigned int start)
{
    @autoreleasepool {
        NSError *error = nil;
        resume_begin(d);
        BOOL ok = [renderer_draw(d) launchStateProgram:start error:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_draw_end(NV2AState *d)
{
    @autoreleasepool {
        NV2AMetalRendererState *state = renderer_state(d);
        if (state->diagnostics)
            state->diagnostic_ends++;
        NSError *error = nil;
        resume_begin(d);
        BOOL ok = [renderer_draw(d) endWithError:&error];
        check_draw(ok, error);
    }
}

static void flush_renderer(NV2AState *d, bool invalidate)
{
    NSError *error = nil;
    BOOL ok = [renderer_draw(d) flushWithError:&error];
    check_draw(ok, error);
    if (invalidate) {
        [renderer_draw(d) invalidateSession];
        renderer_state(d)->resume_begin =
            d->pgraph.primitive_mode != PRIM_TYPE_INVALID;
    }
}
void pgraph_metal4_clear_surface(NV2AState *d, unsigned int parameter)
{
    @autoreleasepool {
        NV2AMetalRendererState *state = renderer_state(d);
        if (state->diagnostics)
            state->diagnostic_clears++;
        NSError *error = nil;
        resume_begin(d);
        BOOL ok = [renderer_draw(d) clearSurface:parameter error:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_clear_report_value(NV2AState *d)
{
    @autoreleasepool {
        [renderer_draw(d).reports clear];
    }
}
void pgraph_metal4_get_report(NV2AState *d, unsigned int parameter)
{
    @autoreleasepool {
        NSError *error = nil;
        BOOL ok = [renderer_draw(d).reports getReport:parameter error:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_process_pending_reports(NV2AState *d)
{
    @autoreleasepool {
        NSError *error = nil;
        BOOL ok = [renderer_draw(d).reports processWithError:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_image_blit(NV2AState *d)
{
    @autoreleasepool {
        NSError *error = nil;
        BOOL ok = [renderer_draw(d).blitter blitWithError:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_flip_stall(NV2AState *d)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalSurfaceCache *cache = renderer_draw(d).surfaces.cache;
        BOOL ok = [cache submitWithError:&error] &&
                  [cache waitUntilIdleWithError:&error];
        check_draw(ok, error);
        NV2AMetalRendererState *state = renderer_state(d);
        if (state->diagnostics) {
            fprintf(stderr,
                    "[Metal4] flip=%" PRIu64 " host_us=%" PRId64
                    " begins=%" PRIu64 "\n",
                    ++state->diagnostic_flips, (int64_t)g_get_monotonic_time(),
                    state->diagnostic_begins);
        }
    }
}
void pgraph_metal4_surface_update(NV2AState *d, bool upload, bool color,
                                  bool zeta)
{
    @autoreleasepool {
        /* Native prepare uploads only stale bindings; even a write-only
         * preparation preserves pixels outside the eventual draw rectangle. */
        NSError *error = nil;
        NV2AMetalPGRAPHSurfaces *surfaces = renderer_draw(d).surfaces;
        BOOL ok = upload ?
                      [surfaces prepareColor:color zeta:zeta error:&error] :
                      [surfaces releaseColor:color zeta:zeta error:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_surface_flush(NV2AState *d)
{
    @autoreleasepool {
        resume_begin(d);
        int scale = g_config.display.quality.surface_scale;
        d->pgraph.surface_scale_factor = MAX(1, scale);
        NSError *error = nil;
        BOOL ok = [renderer_draw(d) flushSurfacesWithError:&error];
        check_draw(ok, error);
    }
}
void pgraph_metal4_pre_savevm_trigger(NV2AState *d)
{
    NV2AMetalRendererState *state = renderer_state(d);
    g_clear_pointer(&state->save_error, g_free);
    qemu_event_reset(&state->save_complete);
    qatomic_set(&state->save_pending, true);
}
void pgraph_metal4_pre_savevm_wait(NV2AState *d)
{
    qemu_event_wait(&renderer_state(d)->save_complete);
}
bool pgraph_metal4_pre_save_check(NV2AState *d, Error **errp)
{
    NV2AMetalRendererState *state = renderer_state(d);
    if (qatomic_read(&state->save_pending)) {
        error_setg(errp, "Metal 4 save capture is still pending");
        return false;
    }
    if (state->save_error) {
        error_setg(errp, "Metal 4 save capture: %s", state->save_error);
        return false;
    }
    return true;
}
void pgraph_metal4_pre_restore_trigger(NV2AState *d)
{
    NV2AMetalRendererState *state = renderer_state(d);
    qemu_event_reset(&state->restore_complete);
    qatomic_set(&state->restore_pending, true);
}
void pgraph_metal4_pre_restore_wait(NV2AState *d)
{
    qemu_event_wait(&renderer_state(d)->restore_complete);
}
void pgraph_metal4_post_load(NV2AState *d)
{
    qatomic_set(&renderer_state(d)->load_pending, true);
}
void pgraph_metal4_pre_shutdown_trigger(NV2AState *d)
{
    NV2AMetalRendererState *state = renderer_state(d);
    qemu_event_reset(&state->shutdown_complete);
    qatomic_set(&state->shutdown_pending, true);
}
void pgraph_metal4_pre_shutdown_wait(NV2AState *d)
{
    qemu_event_wait(&renderer_state(d)->shutdown_complete);
}
static BOOL capture_save_state(NV2AState *d, NSError **error)
{
    NV2AMetalPGRAPHDraw *draw = renderer_draw(d);
    NSData *begin = [draw beginSnapshotWithError:error];
    if (!begin)
        return NO;
    NSData *vertex = draw.vertexSnapshot;
    NSData *pending = [draw pendingSnapshotWithError:error];
    if (!pending)
        return NO;
    NSData *reports = [draw reportSnapshotWithError:error];
    if (!reports)
        return NO;
    /* Publish one complete capture set. Failed snapshots retain the last
     * successful set while the live Draw keeps its transformed prefixes. */
    g_free(d->pgraph.metal4_begin_capture);
    d->pgraph.metal4_begin_capture_size = (uint32_t)begin.length;
    d->pgraph.metal4_begin_capture =
        begin.length ? g_memdup2(begin.bytes, begin.length) : NULL;
    g_free(d->pgraph.metal4_vertex_capture);
    d->pgraph.metal4_vertex_capture_size = (uint32_t)vertex.length;
    d->pgraph.metal4_vertex_capture =
        vertex.length ? g_memdup2(vertex.bytes, vertex.length) : NULL;
    g_free(d->pgraph.metal4_pending_capture);
    d->pgraph.metal4_pending_capture_size = (uint32_t)pending.length;
    d->pgraph.metal4_pending_capture =
        pending.length ? g_memdup2(pending.bytes, pending.length) : NULL;
    g_free(d->pgraph.metal4_report_snapshot);
    d->pgraph.metal4_report_snapshot_size = (uint32_t)reports.length;
    d->pgraph.metal4_report_snapshot =
        reports.length ? g_memdup2(reports.bytes, reports.length) : NULL;
    return YES;
}

void pgraph_metal4_process_pending(NV2AState *d)
{
    @autoreleasepool {
        NV2AMetalRendererState *state = renderer_state(d);
        NSError *error = nil;
        if (!qatomic_read(&state->save_pending) &&
            !qatomic_read(&state->shutdown_pending) &&
            !qatomic_read(&state->scale_pending) &&
            !qatomic_read(&state->restore_pending) &&
            !qatomic_read(&state->load_pending) &&
            !qatomic_read(&d->pgraph.flush_pending) &&
            !qatomic_read(&d->pgraph.sync_pending) &&
            ![renderer_draw(d).surfaces needsCPUService])
            return;
        qemu_mutex_unlock(&d->pfifo.lock);
        qemu_mutex_lock(&d->pgraph.lock);
        bool save = qatomic_read(&state->save_pending),
             shutdown = qatomic_read(&state->shutdown_pending),
             scale = qatomic_read(&state->scale_pending),
             flush = qatomic_read(&d->pgraph.flush_pending),
             restore = qatomic_read(&state->restore_pending),
             load = qatomic_read(&state->load_pending);
        if (save || shutdown || scale || flush || restore || load) {
            if (load) {
                BOOL ok = [renderer_draw(d) discardForRestoreWithError:&error];
                check_draw(ok, error);
                if (d->pgraph.metal4_report_snapshot_size) {
                    NSData *data = [NSData
                        dataWithBytes:d->pgraph.metal4_report_snapshot
                               length:d->pgraph.metal4_report_snapshot_size];
                    ok = [renderer_draw(d) restoreReportSnapshot:data
                                                           error:&error];
                    check_draw(ok, error);
                }
                if (d->pgraph.metal4_vertex_capture_size) {
                    NSData *data = [NSData
                        dataWithBytes:d->pgraph.metal4_vertex_capture
                               length:d->pgraph.metal4_vertex_capture_size];
                    ok = [renderer_draw(d) restoreVertexSnapshot:data
                                                           error:&error];
                    check_draw(ok, error);
                }
                if (d->pgraph.metal4_begin_capture_size) {
                    NSData *data = [NSData
                        dataWithBytes:d->pgraph.metal4_begin_capture
                               length:d->pgraph.metal4_begin_capture_size];
                    ok = [renderer_draw(d) restoreBeginSnapshot:data
                                                          error:&error];
                    check_draw(ok, error);
                }
                if (d->pgraph.metal4_pending_capture_size) {
                    NSData *data = [NSData
                        dataWithBytes:d->pgraph.metal4_pending_capture
                               length:d->pgraph.metal4_pending_capture_size];
                    ok = [renderer_draw(d) restorePendingSnapshot:data
                                                            error:&error];
                    check_draw(ok, error);
                }
                state->resume_begin =
                    d->pgraph.primitive_mode != PRIM_TYPE_INVALID;
                qatomic_set(&state->load_pending, false);
                [renderer_scanout(d) invalidate];
            } else {
                /* Quiescence must retain Begin's immutable shader/raster/
                 * texture captures. Save or a cancelled restore resumes the
                 * same guest block; current registers may already differ.
                 * GL scale flush also retains the bound program, raster,
                 * textures and viewport until the next Begin. */
                if ((!flush && !scale) || shutdown)
                    flush_renderer(d, shutdown);
            }
            if (scale) {
                d->pgraph.surface_scale_factor = state->requested_scale;
                g_config.display.quality.surface_scale = state->requested_scale;
            }
            if (!load && !shutdown && (flush || scale)) {
                if (!scale)
                    d->pgraph.surface_scale_factor =
                        MAX(1, g_config.display.quality.surface_scale);
                resume_begin(d);
                BOOL ok = [renderer_draw(d) flushSurfacesWithError:&error];
                check_draw(ok, error);
            }
            if (save || restore || shutdown) {
                /* Complete closed reports before acknowledging quiescence.
                 * A failed load may resume the old VM, so pre-restore must
                 * preserve its pixels, counters and still-open query. */
                BOOL ok = [renderer_draw(d).reports processWithError:&error];
                check_draw(ok, error);
            }
            if (flush) {
                qatomic_set(&d->pgraph.flush_pending, false);
                qemu_event_set(&d->pgraph.flush_complete);
            }
            if (save) {
                if (!capture_save_state(d, &error))
                    state->save_error = g_strdup(
                        error.localizedDescription.UTF8String ?:
                        "Cannot capture native save state");
                qatomic_set(&state->save_pending, false);
                qemu_event_set(&state->save_complete);
            }
            if (shutdown) {
                qatomic_set(&state->shutdown_pending, false);
                qemu_event_set(&state->shutdown_complete);
            }
            if (scale) {
                qatomic_set(&state->scale_pending, false);
                qemu_event_set(&state->scale_complete);
            }
            if (restore) {
                qatomic_set(&state->restore_pending, false);
                qemu_event_set(&state->restore_complete);
            }
        }
        if (qatomic_read(&d->pgraph.sync_pending)) {
            BOOL synced = [renderer_scanout(d) renderWithError:&error];
            check_draw(synced, error);
            if (state->diagnostics &&
                (++state->diagnostic_syncs <= 3 ||
                 state->diagnostic_syncs % 60 == 0)) {
                NV2AMetalFramebuffer *frame = renderer_scanout(d).frame;
                fprintf(stderr,
                        "[Metal4] sync=%" PRIu64 " begin=%" PRIu64
                        " end=%" PRIu64 " clear=%" PRIu64
                        " frame=%d texture=%lux%lu screen_off=%d\n",
                        state->diagnostic_syncs, state->diagnostic_begins,
                        state->diagnostic_ends, state->diagnostic_clears,
                        frame != nil, (unsigned long)frame.texture.width,
                        (unsigned long)frame.texture.height, frame.screenOff);
            }
            d->pgraph.surface_color.draw_dirty =
                renderer_draw(d).surfaces.color.valid &&
                renderer_draw(d).surfaces.color.dirty;
            d->pgraph.surface_zeta.draw_dirty =
                renderer_draw(d).surfaces.zeta.valid &&
                renderer_draw(d).surfaces.zeta.dirty;
            qatomic_set(&d->pgraph.sync_pending, false);
            qemu_event_set(&d->pgraph.sync_complete);
        }
        BOOL ok =
            [renderer_draw(d).surfaces processCPURequestsWithError:&error];
        check_draw(ok, error);
        qemu_mutex_unlock(&d->pgraph.lock);
        qemu_mutex_lock(&d->pfifo.lock);
    }
}
void pgraph_metal4_set_surface_scale_factor(NV2AState *d, unsigned int scale)
{
    NV2AMetalRendererState *state = renderer_state(d);
    scale = MAX(1u, scale);
    if (scale > 16384) {
        error_report("Invalid Metal 4 surface scale %u", scale);
        abort();
    }
    qemu_mutex_lock(&d->pfifo.lock);
    bool halted = qatomic_read(&d->pfifo.halt);
    qatomic_set(&d->pfifo.halt, true);
    qemu_mutex_unlock(&d->pfifo.lock);
    qemu_mutex_lock(&d->pgraph.lock);
    state->requested_scale = scale;
    qemu_event_reset(&state->scale_complete);
    qatomic_set(&state->scale_pending, true);
    qemu_mutex_unlock(&d->pgraph.lock);
    qemu_mutex_lock(&d->pfifo.lock);
    pfifo_kick(d);
    qemu_mutex_unlock(&d->pfifo.lock);
    qemu_event_wait(&state->scale_complete);
    qemu_mutex_lock(&d->pfifo.lock);
    qatomic_set(&d->pfifo.halt, halted);
    pfifo_kick(d);
    qemu_mutex_unlock(&d->pfifo.lock);
}
unsigned int pgraph_metal4_get_surface_scale_factor(NV2AState *d)
{
    qemu_mutex_lock(&d->pgraph.lock);
    unsigned int scale = d->pgraph.surface_scale_factor;
    qemu_mutex_unlock(&d->pgraph.lock);
    return scale;
}
void pgraph_metal4_register_renderer(void)
{
    static const PGRAPHRenderer renderer = {
        .type = CONFIG_DISPLAY_RENDERER_METAL4,
        .name = "Metal 4",
        .ops = {
            .init = pgraph_metal4_init,
            .finalize = pgraph_metal4_finalize,
            .clear_report_value = pgraph_metal4_clear_report_value,
            .clear_surface = pgraph_metal4_clear_surface,
            .draw_begin = pgraph_metal4_draw_begin,
            .draw_end = pgraph_metal4_draw_end,
            .flip_stall = pgraph_metal4_flip_stall,
            .flush_draw = pgraph_metal4_flush_draw,
            .vertex_state_change = pgraph_metal4_vertex_state_change,
            .launch_transform_program = pgraph_metal4_launch_transform_program,
            .get_report = pgraph_metal4_get_report,
            .image_blit = pgraph_metal4_image_blit,
            .pre_savevm_trigger = pgraph_metal4_pre_savevm_trigger,
            .pre_savevm_wait = pgraph_metal4_pre_savevm_wait,
            .pre_restore_trigger = pgraph_metal4_pre_restore_trigger,
            .pre_restore_wait = pgraph_metal4_pre_restore_wait,
            .post_load = pgraph_metal4_post_load,
            .pre_shutdown_trigger = pgraph_metal4_pre_shutdown_trigger,
            .pre_shutdown_wait = pgraph_metal4_pre_shutdown_wait,
            .process_pending = pgraph_metal4_process_pending,
            .process_pending_reports = pgraph_metal4_process_pending_reports,
            .surface_flush = pgraph_metal4_surface_flush,
            .surface_update = pgraph_metal4_surface_update,
            .set_surface_scale_factor = pgraph_metal4_set_surface_scale_factor,
            .get_surface_scale_factor = pgraph_metal4_get_surface_scale_factor,
            .copy_framebuffer = pgraph_metal4_copy_framebuffer,
        },
    };
    pgraph_renderer_register(&renderer);
}

bool pgraph_metal4_validate_vertex_capture(const uint8_t *bytes, size_t size)
{
    if (!bytes || !size || size > NV2A_METAL_VERTEX_CAPTURE_MAX)
        return false;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:bytes length:size];
        return
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:data
                                                           error:NULL] != nil;
    }
}
