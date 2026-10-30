/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SCANOUT_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SCANOUT_TYPES_H
/* Scalar arrays keep CPU/MSL layouts identical. Overlay output Y is in the
 * original GL viewport coordinates; shader translates Metal's top-left Y. */
typedef struct NV2AMetalScanoutUniforms {
    float output_size[2], line_offset;
    unsigned int overlay_enable;
    float overlay_input[2], overlay_rect[4], overlay_scale[3];
    unsigned int color_key_enable;
    float color_key[3];
    unsigned int source_border, dither;
    /* Encoder supplies target channel widths; zero means floating/missing. */
    unsigned int color_bits[4];
} NV2AMetalScanoutUniforms;
#endif
