/* Native surface-to-texture capture from gl/surface.c
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_CACHE_TYPES_H
#include "texture-cache-types.h"
#endif
#include <metal_stdlib>
using namespace metal;

kernel void
nv2a_surface_texture(texture2d<float, access::read> source [[texture(0)]],
                     texture2d<float, access::write> target [[texture(1)]],
                     constant NV2AMetalSurfaceTextureUniforms &u [[buffer(0)]],
                     uint2 p [[thread_position_in_grid]])
{
    if (p.x >= u.width || p.y >= u.height) {
        return;
    }
    float4 color = source.read(p);
    if (u.force_alpha) {
        color.a = 1;
    }
    if (u.channel_order == 1) {
        color = color.bgra;
    } else if (u.channel_order == 2) {
        color = color.argb;
    }
    target.write(color, p);
}

/* Match surface-download point selection and byte quantization before the
 * old X8 upload. This capture stays at logical resolution: native filtering
 * must not observe the intervening scaled surface texels. */
kernel void nv2a_surface_texture_downsample_opaque(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> target [[texture(1)]],
    constant NV2AMetalSurfaceTextureUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    if (p.x >= u.width || p.y >= u.height)
        return;
    uint2 ratio =
        uint2(source.get_width() / u.width, source.get_height() / u.height);
    float3 color = source.read(p * ratio).rgb;
    color = round(color * 255.0f) / 255.0f;
    target.write(float4(color, 1), p);
}

/* Preserve the old Surface download and byte decoder at logical resolution.
 * A7 is already encoded in the source's stored alpha byte; do not normalize
 * its low seven bits or replace its high bit during this channel permutation.
 */
kernel void nv2a_surface_texture_downsample_channels(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> target [[texture(1)]],
    constant NV2AMetalSurfaceTextureUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    if (p.x >= u.width || p.y >= u.height)
        return;
    uint2 ratio =
        uint2(source.get_width() / u.width, source.get_height() / u.height);
    float4 color = source.read(p * ratio);
    color = round(color * 255.0f) / 255.0f;
    if (u.channel_order == 1)
        color = color.bgra;
    else if (u.channel_order == 2)
        color = color.argb;
    else if (u.channel_order == 3)
        color = color.grab;
    else
        return;
    target.write(color, p);
}
