/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_TRANSFER_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_TRANSFER_TYPES_H

typedef struct NV2AMetalSurfaceTransferUniforms {
    unsigned int width, height, bytes_per_pixel;
    unsigned int source_pitch, destination_pitch, scale, swizzle, flip;
    unsigned int packed_zeta, stencil_pitch, stencil_offset;
    unsigned int native_bytes_per_pixel, half_depth;
} NV2AMetalSurfaceTransferUniforms;

#endif
