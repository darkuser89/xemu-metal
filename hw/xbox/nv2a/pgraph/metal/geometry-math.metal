/* Shared NV2A plane/orientation math for compute and native graphics.
 * Copyright (c) 2015 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_MATH_MSL
#define HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_MATH_MSL
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

/* Kahan's determinant, as in geom.c. The library uses safe math and disables
 * implicit multiply-add contraction; the explicit fma calls remain fused. */
float geometry_det(float a, float b, float c, float d)
{
    float cd = c * d;
    float err = fma(-c, d, cd);
    return fma(a, b, -cd) + err;
}

float4x4 geometry_plane(float4 p0, float4 p1, float4 p2, bool perspective)
{
    float2 m0 = p1.xy - p0.xy, m1 = p2.xy - p0.xy;
    float2 b = perspective ? float2(p0.w - p1.w, p0.w - p2.w) :
                             float2(p1.z - p0.z, p2.z - p0.z);
    if (perspective) {
        float2 w(p1.w, p2.w), product = w * p0.w;
        for (uint i = 0; i < 2; i++) {
            if (isfinite(p0.w) && isfinite(w[i]) && p0.w != 0 && w[i] != 0 &&
                (abs(product[i]) < 0x1p-126f || !isfinite(product[i]))) {
                // Clamped W can have a subnormal product but a normal slope.
                // Divide by the larger magnitude first to avoid overflow too.
                bool first = abs(p0.w) >= abs(w[i]);
                b[i] = (b[i] / (first ? p0.w : w[i])) / (first ? w[i] : p0.w);
            } else {
                b[i] /= product[i];
            }
        }
    }
    float det = geometry_det(m0.x, m1.y, m1.x, m0.y);
    float dzx = geometry_det(b.x, m1.y, b.y, m0.y) / det;
    float dzy = geometry_det(b.y, m0.x, b.x, m1.x) / det;
    return float4x4(p0, p1, p2, float4(max(abs(dzx), abs(dzy)), 0, 0, 0));
}

/* Homogeneous orientation also covers triangles crossing W=0. Divide each
 * (x,y,w) row by a positive scale to avoid intermediate overflow; this does
 * not change the determinant sign or require CPU-processed vertex data. */
static float geometry_area(float4 a, float4 b, float4 c)
{
    float3 p[3] = { a.xyw, b.xyw, c.xyw };
    for (uint i = 0; i < 3; i++) {
        float scale = max(max(abs(p[i].x), abs(p[i].y)), abs(p[i].z));
        if (!all(isfinite(p[i])) || scale == 0)
            return 0;
        p[i] /= scale;
    }
    return p[0].x * geometry_det(p[1].y, p[2].z, p[2].y, p[1].z) -
           p[0].y * geometry_det(p[1].x, p[2].z, p[2].x, p[1].z) +
           p[0].z * geometry_det(p[1].x, p[2].y, p[2].x, p[1].y);
}

#endif
