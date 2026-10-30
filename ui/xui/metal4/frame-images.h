/* Native framebuffer PNG capture; SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef XEMU_UI_METAL4_FRAME_IMAGES_H
#define XEMU_UI_METAL4_FRAME_IMAGES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/* Borrow an immutable NV2AMetalFramebuffer handle and retain its image and
 * captured DAC/screen state until replaced. NULL clears it. Thread-safe. */
void xemu_metal4_set_capture_frame(void *frame);
bool xemu_metal4_has_capture_frame(void);
/* aspect=0 preserves texture aspect; limits=0 preserve native dimensions.
 * GPU scaling/DAC/RGB packing finishes before CPU PNG encoding. Returns a
 * malloc-owned PNG or NULL, sets size=0 on failure; safe off the UI thread. */
void *xemu_metal4_capture_png(float aspect, uint32_t max_width,
                              uint32_t max_height, bool linear, size_t *size);
#ifdef __cplusplus
}
#endif
#endif
