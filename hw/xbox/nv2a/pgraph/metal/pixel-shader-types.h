/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_SHADER_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_SHADER_TYPES_H

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_TYPES_H
#include "pixel-combiner-types.h"
#endif

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLER_TYPES_H
#include "texture-sampler-types.h"
#endif

enum NV2AMetalSurfaceStorage {
    NV2AMetalSurfaceStorageNative,
    NV2AMetalSurfaceStorageB8,
    NV2AMetalSurfaceStorageG8B8,
    NV2AMetalSurfaceStorageZ1,
    NV2AMetalSurfaceStorageO1,
    NV2AMetalSurfaceStorageZ8,
    NV2AMetalSurfaceStorageO8,
    NV2AMetalSurfaceStorageZ7,
    NV2AMetalSurfaceStorageO7,
};

enum NV2AMetalPixelDepthFormat {
    NV2AMetalPixelDepthD24,
    NV2AMetalPixelDepthD16,
    NV2AMetalPixelDepthF24,
    NV2AMetalPixelDepthF16,
};

/* Encoder-owned GPU arguments, outside portable pixel captures. */
typedef struct NV2AMetalPixelStorageInfo {
    unsigned int surface_channels, polygon_projection_count;
} NV2AMetalPixelStorageInfo;

enum NV2AMetalTextureNormalization {
    NV2AMetalTextureNormalizationNone,
    NV2AMetalTextureNormalizationLegacySigned,
    NV2AMetalTextureNormalizationMixedHalf,
};
typedef struct NV2AMetalTextureStage {
    float border_logical_size[3];
    float border_inv_real_size[3];
    float bump_matrix[4];
    float bump_scale;
    float bump_offset;
    float scale;
    unsigned int dimension, cubemap, rectangle, snorm, shadow;
    unsigned int convolution, alphakill, colorkey_mode, compare_mask;
    unsigned int color_key, color_key_mask;
    NV2AMetalSamplingUniforms sampling;
    /* Logical RGBA bits0..3; HILO16 permits only 0 or 15, the latter using
     * the signed16 family model. Shader results transfer separately to the
     * combiner. snorm is NV2AMetalTextureNormalization; MixedHalf restores
     * unsigned byte/256 lanes to byte/255 at each texel before filtering. */
    unsigned int signed_channels;
} NV2AMetalTextureStage;

typedef struct NV2AMetalPixelUniforms {
    NV2AMetalCombinerState combiner;
    NV2AMetalTextureStage textures[4];
    float fog_color[4];
    float clip_range[4];
    int clip_regions[8][4];
    float depth_factor, depth_offset;
    float surface_scale[2];
    unsigned int other_stage_input;
    unsigned int smooth_shading, point_sprite, window_clip_exclusive;
    unsigned int depth_clipping, z_perspective, depth_format;
    unsigned int shadow_func, alpha_test, alpha_func;
    int alpha_ref;
    /* Encoder-supplied slice bound for fragment reads of expanded endpoints. */
    unsigned int vertex_capacity;
    /* Encoder supplied: zero disables logic, otherwise GL/NV op + 1.
     * Logical RGBA bit counts, zero for missing/floating channels. */
    unsigned int logic_op, color_bits[4];
    unsigned int dither, blend;
    float blend_color[4];
    float eye_vector[3];
    /* Only pre-v3 captures retain their historical SPEC_CONST placeholder. */
    unsigned int legacy_spec_const;
    /* Version-5 capture extension; selects original polygon back colors. */
    unsigned int two_side;
    /* Version-6 capture extension: typed HILO16 shader inputs per stage.
     * Kept separate from RGBA8 packing and signed-channel remapping. */
    unsigned int hilo16_mask;
} NV2AMetalPixelUniforms;

#endif
