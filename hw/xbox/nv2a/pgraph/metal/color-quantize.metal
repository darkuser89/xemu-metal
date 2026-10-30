/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_COLOR_QUANTIZE_MSL
#define HW_XBOX_NV2A_PGRAPH_METAL_COLOR_QUANTIZE_MSL
#include <metal_stdlib>
using namespace metal;

/* GL permits implementation-dependent dithering. This ordered 4x4 filter
 * selects adjacent UNORM values and preserves exactly representable colors.
 * It is a native host policy, not an asserted Xbox hardware matrix. */
static uint color_quantize(float value, uint bits, bool dither, uint2 position)
{
    uint mask = (1u << bits) - 1;
    float scaled = clamp(value, 0.0f, 1.0f) * mask;
    float low = floor(scaled);
    if (dither) {
        const uint ranks[16] = { 0, 8,  2, 10, 12, 4, 14, 6,
                                 3, 11, 1, 9,  15, 7, 13, 5 };
        float threshold =
            (ranks[(position.y & 3) * 4 + (position.x & 3)] + .5f) / 16;
        low += scaled - low >= threshold;
    }
    return uint(low);
}
#endif
