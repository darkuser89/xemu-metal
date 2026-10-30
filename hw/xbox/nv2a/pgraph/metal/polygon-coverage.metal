/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_POLYGON_COVERAGE_MSL
#define HW_XBOX_NV2A_PGRAPH_METAL_POLYGON_COVERAGE_MSL
#include <metal_stdlib>
using namespace metal;

/* Depth clamp leaves Z to the existing fragment depth calculation. Four
 * homogeneous side planes also enforce W >= 0 without an artificial epsilon.
 * A W=0 origin is the projective apex and adds no screen-space boundary. */
static uint polygon_project(thread const float4 *input, float2 viewport,
                            thread float2 *points)
{
    float4 polygon[8];
    uint count = 3;
    for (uint i = 0; i < count; i++) {
        if (!all(isfinite(input[i])))
            return 0;
        polygon[i] = input[i];
    }
    for (uint side = 0; side < 4 && count; side++) {
        float4 next[8];
        uint n = 0, axis = side / 2;
        float sign = side & 1 ? -1.0f : 1.0f;
        float4 previous = polygon[count - 1];
        float pd = previous.w + sign * previous[axis];
        for (uint i = 0; i < count; i++) {
            float4 current = polygon[i];
            float cd = current.w + sign * current[axis];
            if ((pd < 0 && cd > 0) || (pd > 0 && cd < 0))
                next[n++] = mix(previous, current, pd / (pd - cd));
            if (cd >= 0)
                next[n++] = current;
            previous = current;
            pd = cd;
        }
        count = n;
        for (uint i = 0; i < count; i++)
            polygon[i] = next[i];
    }
    uint n = 0;
    for (uint i = 0; i < count; i++) {
        float4 p = polygon[i];
        if (p.w > 0) {
            float2 xy = p.xy / p.w;
            points[n++] = float2(xy.x + 1, 1 - xy.y) * viewport * .5f;
        }
    }
    return n >= 3 ? n : 0;
}
#endif
