/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_UPLOAD_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_UPLOAD_TYPES_H

enum {
    NV2AMetalTextureStorageFloat32 = 0,
    NV2AMetalTextureStorageUnorm8 = 1,
    NV2AMetalTextureStorageHalf4 = 2,
    /* These IDs also identify compact v2 snapshot channel layouts. */
    NV2AMetalTextureStorageFloatY16 = 3,
    NV2AMetalTextureStorageFloatHILO16 = 4,
    NV2AMetalTextureStorageFloatDepthY16 = 5,
    NV2AMetalTextureStorageFloatDepth24Fixed = 6,
    NV2AMetalTextureStorageFloatDepth24Float = 7,
    NV2AMetalTextureStorageFloatDepth16Float = 8,
    NV2AMetalTextureStoragePackedR565 = 9,
    NV2AMetalTextureStoragePackedA1555 = 10,
    NV2AMetalTextureStoragePackedX1555 = 11,
    NV2AMetalTextureStoragePackedA4444 = 12,
    NV2AMetalTextureStorageSnorm8 = 13,
    NV2AMetalTextureStorageCount,
};

typedef struct NV2AMetalTextureDecodeUniforms {
    unsigned int format, linear, bytes_per_pixel, block_size;
    unsigned int width, height, depth, source_width;
    unsigned int source_height, source_depth, source_pitch, crop;
    unsigned int output_row, output_slice, palette_entries, signed_channels;
    /* NV2AMetalTextureStorage: exact decoded lanes plus logical swizzle. */
    unsigned int output_storage;
} NV2AMetalTextureDecodeUniforms;

#endif
