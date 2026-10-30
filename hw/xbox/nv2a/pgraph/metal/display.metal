/*
 * NV2A Metal 4 framebuffer display and DAC gamma correction
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#include <metal_stdlib>

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_DISPLAY_UNIFORMS_H
#include "display-uniforms.h"
#endif

using namespace metal;

/* Apple7/8 cannot filter RGBA32F. Keep scanout HDR readable on M1/M2. */
static float4 display_float_read(texture2d<float> source, float2 uv,
                                 bool linear)
{
    int2 size(source.get_width(), source.get_height());
    float2 p = clamp(uv, 0.f, 1.f) * float2(size);
    if (!linear)
        return source.read(uint2(clamp(int2(floor(p)), int2(0), size - 1)));
    p -= .5f;
    int2 lo = int2(floor(p));
    float2 f = fract(p);
    float4 a = source.read(uint2(clamp(lo, int2(0), size - 1)));
    float4 b = source.read(uint2(clamp(lo + int2(1, 0), int2(0), size - 1)));
    float4 c = source.read(uint2(clamp(lo + int2(0, 1), int2(0), size - 1)));
    float4 d = source.read(uint2(clamp(lo + 1, int2(0), size - 1)));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

struct DisplayVertex {
    float4 position [[position]];
    float2 texcoord;
};

vertex DisplayVertex
nv2a_display_vertex(uint vertex_id [[vertex_id]],
                    constant NV2AMetalDisplayUniforms &uniforms [[buffer(0)]])
{
    const float2 positions[] = {
        float2(-1.0f, 1.0f),
        float2(-1.0f, -1.0f),
        float2(1.0f, 1.0f),
        float2(1.0f, -1.0f),
    };
    float2 position = positions[vertex_id];
    DisplayVertex out;
    out.position = float4(
        position * float2(uniforms.scale[0], uniforms.scale[1]), 0.0f, 1.0f);
    out.texcoord = position * float2(0.5f, -0.5f) + 0.5f;
    if (uniforms.flip_y) {
        out.texcoord.y = 1.0f - out.texcoord.y;
    }
    return out;
}

fragment float4
nv2a_display_fragment(DisplayVertex in [[stage_in]],
                      constant NV2AMetalDisplayUniforms &uniforms [[buffer(0)]],
                      texture2d<float> framebuffer [[texture(0)]],
                      sampler framebuffer_sampler [[sampler(0)]])
{
    float4 color = uniforms.reserved ?
                       display_float_read(framebuffer, in.texcoord,
                                          uniforms.reserved == 2) :
                       framebuffer.sample(framebuffer_sampler, in.texcoord);
    /* Match the GL display shader's truncation, including filtered values. */
    uint3 index = uint3(clamp(color.rgb, 0.0f, 1.0f) * 255.0f);
    color.r = float(uniforms.palette[index.r] & 255u) / 255.0f;
    color.g = float((uniforms.palette[index.g] >> 8) & 255u) / 255.0f;
    color.b = float((uniforms.palette[index.b] >> 16) & 255u) / 255.0f;
    return color;
}
