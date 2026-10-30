/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_CLEAR_TYPES_H
#include "clear-types.h"
#endif
#include <metal_stdlib>
using namespace metal;
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_COLOR_QUANTIZE_MSL
#include "color-quantize.metal"
#endif

vertex float4 nv2a_clear_vertex(uint id [[vertex_id]])
{
    float2 p = id == 0 ? float2(-1, -1) :
               id == 1 ? float2(3, -1) :
                         float2(-1, 3);
    return float4(p, 0, 1);
}

struct ClearColorDepth {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};
fragment ClearColorDepth nv2a_clear_color(float4 position [[position]],
                                          constant NV2AMetalClearUniforms &u
                                          [[buffer(0)]])
{
    float4 color(u.color[0], u.color[1], u.color[2], u.color[3]);
    if (u.dither) {
        for (uint i = 0; i < 4; i++) {
            uint bits = u.color_bits[i];
            if (bits && bits <= 8)
                color[i] = float(color_quantize(color[i], bits, true,
                                                uint2(position.xy))) /
                           ((1u << bits) - 1);
        }
    }
    return { color, clamp(u.depth, 0.0f, 1.0f) };
}

struct ClearDepth {
    float depth [[depth(any)]];
};
fragment ClearDepth nv2a_clear_depth(constant NV2AMetalClearUniforms &u
                                     [[buffer(0)]])
{
    return { clamp(u.depth, 0.0f, 1.0f) };
}
