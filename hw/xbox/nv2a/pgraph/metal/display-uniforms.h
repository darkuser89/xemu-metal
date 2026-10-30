/*
 * NV2A Metal 4 display uniforms shared with Metal Shading Language
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_DISPLAY_UNIFORMS_H
#define HW_XBOX_NV2A_PGRAPH_METAL_DISPLAY_UNIFORMS_H

/* Scalar members have identical layouts in C and MSL. Avoid float3 alignment.
 */
typedef struct NV2AMetalDisplayUniforms {
    float scale[2];
    unsigned int flip_y;
    unsigned int reserved;
    unsigned int palette[256];
} NV2AMetalDisplayUniforms;

#endif
