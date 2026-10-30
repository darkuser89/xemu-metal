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
