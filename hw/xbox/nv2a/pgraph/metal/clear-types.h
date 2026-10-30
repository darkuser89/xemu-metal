/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_CLEAR_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_CLEAR_TYPES_H

typedef struct NV2AMetalClearUniforms {
    float color[4], depth;
    unsigned int dither, color_bits[4];
} NV2AMetalClearUniforms;

#endif
