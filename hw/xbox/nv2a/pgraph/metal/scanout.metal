/* Native framebuffer/PVIDEO composition from gl/display.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SCANOUT_TYPES_H
#include "scanout-types.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_COLOR_QUANTIZE_MSL
#include "color-quantize.metal"
#endif
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)
struct ScanoutVertex {
    float4 position [[position]];
};
vertex ScanoutVertex nv2a_scanout_vertex(uint id [[vertex_id]])
{
    const float2 p[] = { float2(-1, 1), float2(-1, -3), float2(3, 1) };
    return { float4(p[id], 0, 1) };
}
static float4 texel(texture2d<float, access::read> t, int2 p, int2 size,
                    bool border)
{
    if (border && (any(p < 0) || any(p >= size)))
        return 0;
    return t.read(uint2(p));
}
static float4 linear(texture2d<float, access::read> t, float2 uv, bool border)
{
    // Repeat before converting to integers, so large register-derived input
    // coordinates never overflow integer texel indices.
    if (!border)
        uv = fract(uv);
    int2 size(t.get_width(), t.get_height());
    float2 p = uv * float2(size) - .5f;
    if (border && (any(p < -1) || any(p >= float2(size))))
        return 0;
    int2 lo = int2(floor(p)), hi = lo + 1;
    float2 f = p - float2(lo);
    if (!border) {
        // fract confines the taps to [-1, size], so one edge adjustment
        // replaces modulo for all four reads, including one-texel textures.
        lo = select(lo, lo + size, lo < 0);
        hi = select(hi, hi - size, hi >= size);
    }
    float4 a = mix(texel(t, lo, size, border),
                   texel(t, int2(hi.x, lo.y), size, border), f.x);
    float4 b = mix(texel(t, int2(lo.x, hi.y), size, border),
                   texel(t, hi, size, border), f.x);
    return mix(a, b, f.y);
}
fragment float4 nv2a_scanout_fragment(ScanoutVertex in [[stage_in]],
                                      constant NV2AMetalScanoutUniforms &u
                                      [[buffer(0)]],
                                      texture2d<float, access::read> source
                                      [[texture(0)]],
                                      texture2d<float, access::read> overlay
                                      [[texture(1)]])
{
    float2 uv(in.position.x / u.output_size[0],
              in.position.y / float(source.get_height()) / u.line_offset);
    float4 color = linear(source, uv, u.source_border != 0);
    if (u.overlay_enable) {
        float2 screen(in.position.x - .5f,
                      u.output_size[1] - in.position.y - .5f);
        float2 origin(u.overlay_rect[0], u.overlay_rect[1]);
        float2 extent(u.overlay_rect[2], u.overlay_rect[3]);
        if (all(screen >= origin) && all(screen <= origin + extent) &&
            (!u.color_key_enable ||
             all(color.rgb ==
                 float3(u.color_key[0], u.color_key[1], u.color_key[2])))) {
            float2 p = float2(u.overlay_input[0], u.overlay_input[1]) +
                       (screen - origin) * u.overlay_scale[2] *
                           float2(u.overlay_scale[0], u.overlay_scale[1]);
            float2 st = p / float2(overlay.get_width(), overlay.get_height());
            st.y = -st.y;
            color = linear(overlay, st, false);
        }
    }
    for (uint i = 0; i < 4; i++) {
        uint bits = u.color_bits[i];
        if (bits) {
            uint mask = (1u << bits) - 1;
            uint value =
                u.dither ?
                    color_quantize(color[i], bits, true,
                                   uint2(in.position.xy)) :
                    uint(floor(clamp(color[i], 0.0f, 1.0f) * mask + .5f));
            color[i] = float(value) / mask;
        }
    }
    return color;
}
