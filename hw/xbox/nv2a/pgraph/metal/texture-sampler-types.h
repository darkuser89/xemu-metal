/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLER_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLER_TYPES_H

/* Address values are the original NV_PGRAPH_TEXADDRESS0_ADDRU enum.
 * mip_filter: 0 = base, 1 = nearest mip, 2 = linear mip. */
typedef struct NV2AMetalSamplingUniforms {
    unsigned int enabled, address[3];
    unsigned int min_linear, mag_linear, mip_filter, anisotropy;
    float lod_bias;
    float border_color[4];
} NV2AMetalSamplingUniforms;

#endif
