/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FIXED_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FIXED_TYPES_H

#ifndef HW_NV2A_REGS_H
#include "../../nv2a_regs.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_TYPES_H
#include "vertex-program-types.h"
#endif

/* Internal modes follow VshSkinning, VshTexgen, VshLight, VshFoggen and
 * MaterialColorSource in pgraph/vsh_regs.h, not hardware bitfield definitions.
 */
enum NV2AMetalSkinning {
    NV2AMetalSkinningOff,
    NV2AMetalSkinningOneWeight,
    NV2AMetalSkinningTwoWeightsTwoMatrices,
    NV2AMetalSkinningTwoWeights,
    NV2AMetalSkinningThreeWeightsThreeMatrices,
    NV2AMetalSkinningThreeWeights,
    NV2AMetalSkinningFourWeightsFourMatrices,
};
enum NV2AMetalTexgen {
    NV2AMetalTexgenDisabled,
    NV2AMetalTexgenEyeLinear,
    NV2AMetalTexgenObjectLinear,
    NV2AMetalTexgenSphere,
    NV2AMetalTexgenNormal,
    NV2AMetalTexgenReflection,
};
enum NV2AMetalLight {
    NV2AMetalLightOff,
    NV2AMetalLightInfinite,
    NV2AMetalLightLocal,
    NV2AMetalLightSpot,
};
enum NV2AMetalFoggen {
    NV2AMetalFoggenSpecularAlpha,
    NV2AMetalFoggenRadial,
    NV2AMetalFoggenPlanar,
    NV2AMetalFoggenAbsPlanar,
    NV2AMetalFoggenFogX,
};
enum NV2AMetalMaterialSource {
    NV2AMetalMaterialSourceMaterial,
    NV2AMetalMaterialSourceDiffuse,
    NV2AMetalMaterialSourceSpecular,
};

typedef struct NV2AMetalFixedUniforms {
    /* Common vertex constants/viewport/fog/specular controls. program_length
     * and point_programmed are unused; the encoder sets vertex_count. */
    NV2AMetalProgramUniforms common;
    float ltctxa[NV2A_LTCTXA_COUNT][4];
    float ltctxb[NV2A_LTCTXB_COUNT][4];
    float ltc1[NV2A_LTC1_COUNT][4];
    float light_direction[NV2A_MAX_LIGHTS][3];
    float light_half_vector[NV2A_MAX_LIGHTS][3];
    float light_attenuation[NV2A_MAX_LIGHTS][3];
    float light_position[NV2A_MAX_LIGHTS][3];
    float point_params[8];
    float specular_power; /* Version-1 capture compatibility. */
    float material_alpha;
    unsigned int skinning, normalization, lighting, local_eye;
    unsigned int emission_src, ambient_src, diffuse_src, specular_src;
    unsigned int separate_specular, foggen, point_params_enable;
    unsigned int texture_matrix_enable[4];
    unsigned int texgen[4][4];
    unsigned int light[NV2A_MAX_LIGHTS];
    unsigned int texgen_infinite_viewer;
    unsigned int reserved[2];
    float specular_params[3]; /* Front-lighting L/M/N coefficients. */
    /* Only the version-1 capture decoder selects the historical power model. */
    unsigned int legacy_specular;
    /* Version-4 capture extension; older fixed captures retain their prefix. */
    float specular_params_back[3];
    float material_alpha_back;
    unsigned int back_emission_src, back_ambient_src;
    unsigned int back_diffuse_src, back_specular_src, two_side;
} NV2AMetalFixedUniforms;

/* Function-constant indices are internal compiler metadata, not capture or
 * register layout. Keep scalar access and CPU key construction in one list. */
#define NV2A_METAL_FIXED_SCALAR_CONSTANTS(X)                   \
    X(skinning, skinning, 0)                                   \
    X(normalization, normalization, 1)                         \
    X(lighting, lighting, 2)                                   \
    X(local_eye, local_eye, 3)                                 \
    X(emission_src, emission_src, 4)                           \
    X(ambient_src, ambient_src, 5)                             \
    X(diffuse_src, diffuse_src, 6)                             \
    X(specular_src, specular_src, 7)                           \
    X(separate_specular, separate_specular, 8)                 \
    X(foggen, foggen, 9)                                       \
    X(point_params_enable, point_params_enable, 10)            \
    X(texgen_infinite_viewer, texgen_infinite_viewer, 11)      \
    X(legacy_specular, legacy_specular, 12)                    \
    X(two_side, two_side, 13)                                  \
    X(back_emission_src, back_emission_src, 14)                \
    X(back_ambient_src, back_ambient_src, 15)                  \
    X(back_diffuse_src, back_diffuse_src, 16)                  \
    X(back_specular_src, back_specular_src, 17)                \
    X(specular_enable, common.specular_enable, 18)             \
    X(ignore_specular_alpha, common.ignore_specular_alpha, 19) \
    X(fog_enable, common.fog_enable, 20)                       \
    X(fog_mode, common.fog_mode, 21)
#define NV2A_METAL_FIXED_CONSTANT_COUNT 28

/* Internal CPU/MSL execution parameters; not a capture or hardware ABI. */
typedef struct NV2AMetalFixedParameters {
    NV2AMetalFixedUniforms uniforms;
    unsigned int rasterize;
} NV2AMetalFixedParameters;

#endif
