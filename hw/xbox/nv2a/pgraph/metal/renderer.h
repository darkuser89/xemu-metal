/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_RENDERER_H
#define HW_XBOX_NV2A_PGRAPH_METAL_RENDERER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct NV2AState NV2AState;
typedef struct Error Error;
#ifdef __cplusplus
extern "C" {
#endif
/* PGRAPH-thread callbacks with pg.lock held and live VRAM. Init/finalize
 * require guest CPU access stopped. Common PGRAPH owns input lengths/resets. */
void pgraph_metal4_init(NV2AState *d, Error **errp);
void pgraph_metal4_register_renderer(void);
void pgraph_metal4_finalize(NV2AState *d);
/* Host request under renderer_lock, not pg/pfifo locks. Returns an owned
 * NV2AMetalFramebuffer ObjC handle, or NULL without a cached color source.
 * Release once after retaining its texture/metadata for UI GPU commands. */
void *pgraph_metal4_copy_framebuffer(NV2AState *d);
void pgraph_metal4_release_framebuffer(void *handle);
void pgraph_metal4_draw_begin(NV2AState *d);
void pgraph_metal4_flush_draw(NV2AState *d);
void pgraph_metal4_draw_end(NV2AState *d);
void pgraph_metal4_clear_surface(NV2AState *d, unsigned int parameter);
void pgraph_metal4_clear_report_value(NV2AState *d);
void pgraph_metal4_get_report(NV2AState *d, unsigned int parameter);
/* Like process_pending, enters and leaves with pfifo.lock held. */
void pgraph_metal4_process_pending_reports(NV2AState *d);
void pgraph_metal4_image_blit(NV2AState *d);
void pgraph_metal4_flip_stall(NV2AState *d);
void pgraph_metal4_surface_update(NV2AState *d, bool upload, bool color,
                                  bool zeta);
void pgraph_metal4_surface_flush(NV2AState *d);
/* process_pending enters and leaves with pfifo.lock; triggers/waits do not
 * hold pg.lock. Scale setter is a host request under renderer_lock. */
void pgraph_metal4_process_pending(NV2AState *d);
void pgraph_metal4_pre_savevm_trigger(NV2AState *d);
void pgraph_metal4_pre_savevm_wait(NV2AState *d);
/* Call after the save wait, before serializing the device. A failure leaves
 * the previous capture set intact and is cleared by the next save trigger. */
bool pgraph_metal4_pre_save_check(NV2AState *d, Error **errp);
/* Halt FIFO/guest access, trigger and wait BEFORE replacing RAM. Pre-restore
 * writes current GPU pixels/reports to old RAM, preserving a failed load.
 * Post-load schedules invalidation without new writebacks under pg.lock. */
void pgraph_metal4_pre_restore_trigger(NV2AState *d);
void pgraph_metal4_pre_restore_wait(NV2AState *d);
void pgraph_metal4_post_load(NV2AState *d);
/* VMState subsection validation, without GPU access or live-state changes. */
bool pgraph_metal4_validate_report_snapshot(const uint8_t *bytes, size_t size);
#define NV2A_METAL_VERTEX_CAPTURE_MAX 65536u
bool pgraph_metal4_validate_vertex_capture(const uint8_t *bytes, size_t size);
#define NV2A_METAL_BEGIN_CAPTURE_MAX (512u * 1024 * 1024)
bool pgraph_metal4_validate_begin_capture(const uint8_t *bytes, size_t size);
void pgraph_metal4_pre_shutdown_trigger(NV2AState *d);
void pgraph_metal4_pre_shutdown_wait(NV2AState *d);
void pgraph_metal4_set_surface_scale_factor(NV2AState *d, unsigned int scale);
unsigned int pgraph_metal4_get_surface_scale_factor(NV2AState *d);
/* Borrowed internal draw handle, valid while the renderer is initialized. */
void *pgraph_metal4_draw_handle(NV2AState *d);

#define NV2A_METAL_PENDING_CAPTURE_MAX (32u + 1250u * 16u + 524287u * 248u)
bool pgraph_metal4_validate_pending_capture(const uint8_t *bytes, size_t size);

void pgraph_metal4_vertex_state_change(NV2AState *d);
void pgraph_metal4_launch_transform_program(NV2AState *d, unsigned int start);
#ifdef __cplusplus
}
#endif
#endif
