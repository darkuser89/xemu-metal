/*
 * Native Metal 4 fragment pipeline, from glsl/psh.c and glsl/common.c
 * Copyright (c) 2013 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
 * Based on Cxbx PixelShader.cpp (Aaron Robinson, Kingofc, 2004) and
 * Xeon XBD3DPixelShader.cpp (_SF_, 2003).
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_SHADER_TYPES_H
#include "pixel-shader-types.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_TYPES_H
#include "geometry-types.h"
#endif
#ifndef NV_PGRAPH_BLEND_EN
#include "../../nv2a_regs.h"
#endif
#define NV2A_METAL_COMBINER_NO_KERNEL
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_MSL
#include "pixel-combiner.metal"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLE_MSL
#include "texture-sample.metal"
#endif
#include <metal_stdlib>
using namespace metal;
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_COLOR_QUANTIZE_MSL
#include "color-quantize.metal"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_POLYGON_COVERAGE_MSL
#include "polygon-coverage.metal"
#endif
#pragma clang fp contract(off)
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_MATH_MSL
#include "geometry-math.metal"
#endif

struct PixelVertex {
    float4 position [[position]];
    float4 diffuse, specular;
    float4 flat_diffuse [[flat]], flat_specular [[flat]];
    float4 back_diffuse, back_specular;
    float4 flat_back_diffuse [[flat]], flat_back_specular [[flat]];
    uint face [[flat]];
    float fog;
    float4 t0, t1, t2, t3;
    float4 p0 [[flat]], p1 [[flat]], p2 [[flat]];
    float slope [[flat]];
    float3 line_raster [[flat]];
    uint line_base [[flat]];
};

struct PixelPointVertex {
    float4 position [[position]];
    float4 diffuse, specular;
    float4 flat_diffuse [[flat]], flat_specular [[flat]];
    float4 back_diffuse, back_specular;
    float4 flat_back_diffuse [[flat]], flat_back_specular [[flat]];
    uint face [[flat]];
    float fog;
    float4 t0, t1, t2, t3;
    float4 p0 [[flat]], p1 [[flat]], p2 [[flat]];
    float slope [[flat]];
    float3 line_raster [[flat]];
    uint line_base [[flat]];
    float point_size [[point_size]];
};

template <typename T>
static T pixel_vertex(uint id, device const NV2AMetalVertex *vertices)
{
    device const NV2AMetalVertex &v = vertices[id];
    T out;
    out.position = combiner_load_device(v.clip);
    out.diffuse = out.flat_diffuse = combiner_load_device(v.color[0]);
    out.specular = out.flat_specular = combiner_load_device(v.color[1]);
    out.back_diffuse = out.flat_back_diffuse = combiner_load_device(v.color[2]);
    out.back_specular = out.flat_back_specular =
        combiner_load_device(v.color[3]);
    out.face = v.face;
    out.fog = v.fog;
    out.t0 = combiner_load_device(v.texcoord[0]);
    out.t1 = combiner_load_device(v.texcoord[1]);
    out.t2 = combiner_load_device(v.texcoord[2]);
    out.t3 = combiner_load_device(v.texcoord[3]);
    out.p0 = combiner_load_device(v.plane[0]);
    out.p1 = combiner_load_device(v.plane[1]);
    out.p2 = combiner_load_device(v.plane[2]);
    out.slope = v.slope;
    out.line_raster =
        float3(v.line_raster[0], v.line_raster[1], v.line_raster[2]);
    out.line_base = id / 6 * 6;
    return out;
}

vertex PixelVertex nv2a_pixel_vertex(uint id [[vertex_id]],
                                     device const NV2AMetalVertex *vertices
                                     [[buffer(0)]])
{
    return pixel_vertex<PixelVertex>(id, vertices);
}

vertex PixelVertex nv2a_pixel_line_vertex(uint id [[vertex_id]],
                                          device const NV2AMetalVertex *vertices
                                          [[buffer(0)]])
{
    PixelVertex out = pixel_vertex<PixelVertex>(id, vertices);
    if (out.face == NV2AMetalFaceNative)
        out.face = NV2AMetalFaceFront;
    return out;
}

vertex PixelPointVertex nv2a_pixel_point_vertex(
    uint id [[vertex_id]], device const NV2AMetalVertex *vertices [[buffer(0)]])
{
    PixelPointVertex out = pixel_vertex<PixelPointVertex>(id, vertices);
    out.point_size = vertices[id].point_size;
    if (out.face == NV2AMetalFaceNative)
        out.face = NV2AMetalFaceFront;
    return out;
}

/* True NV2A points do not need a geometry output buffer. This is the point
 * branch of nv2a_expand_geometry, applied to vertex outputs instead. Polygon
 * point mode keeps the original shader and its polygon plane/face/slope. */
vertex PixelPointVertex nv2a_pixel_direct_point_vertex(
    uint id [[vertex_id]], device const NV2AMetalVertex *vertices [[buffer(0)]])
{
    PixelPointVertex out = pixel_vertex<PixelPointVertex>(id, vertices);
    out.point_size = vertices[id].point_size;
    out.face = NV2AMetalFaceFront;
    out.p0 = out.p1 = out.p2 = combiner_load_device(vertices[id].screen);
    out.slope = 0;
    return out;
}

/* Line-list endpoints share the same plane and flat colors. Line strips,
 * wide/smooth lines and W-depth lines keep their compute expansion. */
static PixelVertex pixel_direct_line_vertex(
    uint id, device const NV2AMetalVertex *vertices, bool flat, uint provoking)
{
    PixelVertex out = pixel_vertex<PixelVertex>(id, vertices);
    uint base = id & ~1u;
    float4 p0 = combiner_load_device(vertices[base].screen);
    float4 p1 = combiner_load_device(vertices[base + 1].screen);
    float2 delta = p1.xy - p0.xy;
    out.p0 = p0;
    out.p1 = p1;
    out.p2 = float4(float2(-delta.y, delta.x) + p0.xy, p0.zw);
    out.slope = 0;
    out.face = NV2AMetalFaceFront;
    if (flat) {
        device const NV2AMetalVertex &v = vertices[base + provoking];
        out.diffuse = out.flat_diffuse = combiner_load_device(v.color[0]);
        out.specular = out.flat_specular = combiner_load_device(v.color[1]);
        out.back_diffuse = out.flat_back_diffuse = combiner_load_device(v.color[2]);
        out.back_specular = out.flat_back_specular = combiner_load_device(v.color[3]);
    }
    return out;
}
vertex PixelVertex nv2a_pixel_direct_line_smooth_vertex(
    uint id [[vertex_id]], device const NV2AMetalVertex *vertices [[buffer(0)]])
{
    return pixel_direct_line_vertex(id, vertices, false, 0);
}
vertex PixelVertex nv2a_pixel_direct_line_first_vertex(
    uint id [[vertex_id]], device const NV2AMetalVertex *vertices [[buffer(0)]])
{
    return pixel_direct_line_vertex(id, vertices, true, 0);
}
vertex PixelVertex nv2a_pixel_direct_line_last_vertex(
    uint id [[vertex_id]], device const NV2AMetalVertex *vertices [[buffer(0)]])
{
    return pixel_direct_line_vertex(id, vertices, true, 1);
}

constant uint nv2a_direct_triangle_options [[function_constant(12)]];
vertex PixelVertex nv2a_pixel_direct_triangle_vertex(
    uint id [[vertex_id]], device const NV2AMetalVertex *vertices [[buffer(0)]])
{
    uint base = id / 3 * 3;
    float4 a = combiner_load_device(vertices[base].clip);
    float4 b = combiner_load_device(vertices[base + 1].clip);
    float4 c = combiner_load_device(vertices[base + 2].clip);
    float area = geometry_area(a, b, c);
    bool front =
        nv2a_direct_triangle_options & NV2AMetalDirectTriangleClockwise ?
            area < 0 :
            area > 0;
    if (nv2a_direct_triangle_options &
        (front ? NV2AMetalDirectTriangleCullFront :
                 NV2AMetalDirectTriangleCullBack)) {
        PixelVertex clipped = {};
        clipped.position = float4(2, 2, 2, 1);
        return clipped;
    }
    PixelVertex out = pixel_vertex<PixelVertex>(id, vertices);
    float4x4 plane = geometry_plane(
        combiner_load_device(vertices[base].screen),
        combiner_load_device(vertices[base + 1].screen),
        combiner_load_device(vertices[base + 2].screen),
        nv2a_direct_triangle_options & NV2AMetalDirectTriangleWDepth);
    out.p0 = plane[0];
    out.p1 = plane[1];
    out.p2 = plane[2];
    out.slope = isfinite(plane[3].x) ? plane[3].x : 0;
    out.face = front ? NV2AMetalFaceFront : NV2AMetalFaceBack;
    if (!(nv2a_direct_triangle_options & NV2AMetalDirectTriangleSmooth)) {
        uint provoking =
            nv2a_direct_triangle_options & NV2AMetalDirectTriangleFirst ? 0 : 2;
        device const NV2AMetalVertex &v = vertices[base + provoking];
        out.diffuse = out.flat_diffuse = combiner_load_device(v.color[0]);
        out.specular = out.flat_specular = combiner_load_device(v.color[1]);
        out.back_diffuse = out.flat_back_diffuse =
            combiner_load_device(v.color[2]);
        out.back_specular = out.flat_back_specular =
            combiner_load_device(v.color[3]);
    }
    return out;
}

static float pixel_det(float2 a, float2 b)
{
    float cd = a.y * b.x;
    float err = fma(-a.y, b.x, cd);
    return fma(a.x, b.y, -cd) + err;
}

static bool pixel_compare(float a, float b, uint function)
{
    switch (function) {
    case 0:
        return false;
    case 1:
        return a < b;
    case 2:
        return a == b;
    case 3:
        return a <= b;
    case 4:
        return a > b;
    case 5:
        return a != b;
    case 6:
        return a >= b;
    default:
        return true;
    }
}

static float3 pixel_border(float3 coordinates,
                           constant NV2AMetalTextureStage &s)
{
    if (!s.cubemap && s.border_logical_size[0] != 0) {
        float3 logical(s.border_logical_size[0], s.border_logical_size[1],
                       s.border_logical_size[2]);
        float3 inverse(s.border_inv_real_size[0], s.border_inv_real_size[1],
                       s.border_inv_real_size[2]);
        coordinates = (coordinates * logical + 4.0f) * inverse;
    }
    return coordinates;
}

static float pixel_sign(float x, uint mode)
{
    x *= 255.0f;
    if (mode == PS_DOTMAPPING_MINUS1_TO_1_D3D) {
        return (x - 128.0f) / 127.0f;
    }
    if (mode == PS_DOTMAPPING_MINUS1_TO_1_GL) {
        return x >= 128.0f ? (x - 255.5f) / 127.5f : (x + .5f) / 127.5f;
    }
    return x >= 128.0f ? (x - 256.0f) / 127.0f : x / 127.0f;
}

static float3 pixel_dotmap(float4 color, uint mode, uint signed_channels = 0,
                           bool hilo16 = false)
{
    // NV_texture_shader 3.8.13.1.14: typed HILO bypasses RGBA remapping.
    if (hilo16) {
        float z = signed_channels == 15 ?
                      sqrt(max(0.0f, 1.0f - dot(color.rg, color.rg))) :
                      1;
        return float3(color.rg, z);
    }
    // NV_texture_shader 3.8.13.1.14: signed RGBA bypasses unsigned remapping.
    if (signed_channels == 15 && mode < PS_DOTMAPPING_HILO_1) {
        return color.rgb;
    }
    if (mode >= 1 && mode <= 3) {
        return float3(pixel_sign(color.r, mode), pixel_sign(color.g, mode),
                      pixel_sign(color.b, mode));
    }
    if (mode >= PS_DOTMAPPING_HILO_1) {
        uint hi = uint(color.a * 255.0f) << 8 | uint(color.r * 255.0f);
        uint lo = uint(color.g * 255.0f) << 8 | uint(color.b * 255.0f);
        if (mode == PS_DOTMAPPING_HILO_1) {
            return float3(float(hi) / 65535.0f, float(lo) / 65535.0f, 1);
        }
        float2 value(int(hi) - (hi >= 32768 ? 65536 : 0),
                     int(lo) - (lo >= 32768 ? 65536 : 0));
        // NVIDIA US6664963, table4: distinct MS, GL and NV signed16 maps.
        if (mode == PS_DOTMAPPING_HILO_HEMISPHERE_D3D) {
            value /= 32768.0f;
        } else if (mode == PS_DOTMAPPING_HILO_HEMISPHERE_GL) {
            value = (value + .5f) / 32767.5f;
        } else {
            value /= 32767.0f;
        }
        return float3(value, sqrt(max(0.0f, 1.0f - value.x * value.x -
                                                value.y * value.y)));
    }
    return color.rgb;
}

static float2 pixel_cube_to_2d(float3 c)
{
    float3 a = abs(c);
    if (a.x > a.y && a.x > a.z) {
        return float2(c.x > 0 ? -c.z : c.z, c.y) / a.x;
    }
    if (a.y > a.x && a.y > a.z) {
        return float2(c.x, c.y > 0 ? -c.z : c.z) / a.y;
    }
    return float2(c.z > 0 ? c.x : -c.x, c.y) / a.z;
}

static float3 pixel_normalize_rect(float3 c, constant NV2AMetalTextureStage &s,
                                   texture2d<float> tex)
{
    if (s.rectangle) {
        c.xy /= float2(tex.get_width(), tex.get_height()) / s.scale;
    }
    return c;
}

static uint pixel_unsigned_half_mask(constant NV2AMetalTextureStage &s)
{
    return s.snorm == NV2AMetalTextureNormalizationMixedHalf ?
               (15u ^ s.signed_channels) :
               0;
}

static float4 pixel_cube_sample(texturecube<float> t, sampler smp, float3 c,
                                constant NV2AMetalTextureStage &s)
{
    return nv2a_sample(
        t, smp, c, s.sampling,
        float2(s.border_logical_size[0], s.border_logical_size[1]),
        float2(s.border_inv_real_size[0], s.border_inv_real_size[1]),
        pixel_unsigned_half_mask(s));
}

static float4 pixel_sample(float3 c, constant NV2AMetalTextureStage &s,
                           texture2d<float> t2, texture3d<float> t3,
                           texturecube<float> tc, sampler smp, bool cube)
{
    if (cube) {
        return s.cubemap ? pixel_cube_sample(tc, smp, c, s) :
                           nv2a_sample(t2, smp, pixel_cube_to_2d(c), s.sampling,
                                       pixel_unsigned_half_mask(s));
    }
    return s.dimension == 3 ?
               nv2a_sample(t3, smp, c, s.sampling,
                           pixel_unsigned_half_mask(s)) :
               nv2a_sample(t2, smp, pixel_normalize_rect(c, s, t2).xy,
                           s.sampling, pixel_unsigned_half_mask(s));
}

static float4 pixel_project(float4 c, constant NV2AMetalTextureStage &s,
                            texture2d<float> t2, texture3d<float> t3,
                            texturecube<float> tc, sampler smp, bool two)
{
    if (s.dimension == 3) {
        return nv2a_sample(t3, smp, float3(c.xy, two ? 0.0f : c.z) / c.w,
                           s.sampling, pixel_unsigned_half_mask(s));
    }
    float2 xy = pixel_normalize_rect(c.xyz, s, t2).xy / c.w;
    if (two && s.cubemap) {
        return pixel_cube_sample(tc, smp, normalize(float3(1, xy.y, -xy.x)), s);
    }
    return nv2a_sample(t2, smp, xy, s.sampling, pixel_unsigned_half_mask(s));
}

static float4 pixel_shadow(float4 c, constant NV2AMetalTextureStage &s,
                           texture2d<float> tex, sampler smp, uint function,
                           bool compare_z)
{
    if (function == SHADOW_DEPTH_FUNC_NEVER ||
        function == SHADOW_DEPTH_FUNC_ALWAYS) {
        return float4(function == SHADOW_DEPTH_FUNC_ALWAYS);
    }
    float4 depth = nv2a_sample(
        tex, smp, pixel_normalize_rect(c.xyz, s, tex).xy / c.w, s.sampling);
    float reference = 0;
    if (compare_z) {
        // G identifies 24-bit, B floating depth. F24 is already physical.
        bool f24 = depth.y > 0 && depth.z > 0;
        float maximum = f24         ? 0x1.ffffp127f :
                        depth.y > 0 ? 16777215.0f :
                        depth.z > 0 ? 511.9375f :
                                      65535.0f;
        if (!f24)
            depth.x *= maximum;
        reference = clamp(c.z / c.w, 0.0f, maximum);
        if (depth.y == 0 && depth.z > 0 && reference >= 0.015625f) {
            // Published Xbox F16 shadow comparisons retain twelve fraction
            // bits in the normal reference range. Exponent-zero rules remain
            // separate from the rasterizer's underflow behavior.
            reference = as_type<float>(as_type<uint>(reference) & 0xfffff800u);
        }
    }
    return float4(pixel_compare(depth.x, reference, function));
}

struct PixelOutput {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

/* Lexicographic infinitesimals implement GL's endpoint perturbation without
 * choosing a physical epsilon that disappears at large window coordinates.
 * Row0 is top, hence (-epsilon,+epsilon^2) in this coordinate system. */
static bool line_less(float3 a, float3 b)
{
    return a.x < b.x ||
           (a.x == b.x && (a.y < b.y || (a.y == b.y && a.z < b.z)));
}
static bool line_diamond(float2 a, float2 b, float2 centre)
{
    const float2 normals[4] = { { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } };
    float3 enter(0), leave(1, 0, 0);
    bool end_inside = true;
    for (uint i = 0; i < 4; i++) {
        float2 n = normals[i];
        float f = dot(a - centre, n) - .5f;
        float d = dot(b - a, n);
        float3 at_end(dot(b - centre, n) - .5f, -n.x, n.y);
        end_inside &= line_less(at_end, float3(0));
        if (d == 0) {
            if (!line_less(float3(f, -n.x, n.y), float3(0)))
                return false;
        } else {
            float3 crossing(-f / d, n.x / d, -n.y / d);
            if (d > 0) {
                if (line_less(crossing, leave))
                    leave = crossing;
            } else if (line_less(enter, crossing)) {
                enter = crossing;
            }
        }
    }
    return !end_inside && line_less(enter, leave);
}
static bool line_alias(float2 a, float2 b, float2 centre, float width)
{
    int w = max(1, int(floor(width + .5f)));
    bool x_major = abs(b.x - a.x) >= abs(b.y - a.y);
    uint major = x_major ? 0 : 1, minor = 1 - major;
    float offset = float(w - 1) * .5f;
    a[minor] += x_major ? offset : -offset;
    b[minor] += x_major ? offset : -offset;
    float projected = a[minor] + (centre[major] - a[major]) *
                                     (b[minor] - a[minor]) /
                                     (b[major] - a[major]);
    int candidate = int(
        floor(x_major ? projected - centre[minor] : centre[minor] - projected));
    for (int step = -1; step <= 1; step++) {
        int k = candidate + step;
        if (k >= 0 && k < w) {
            float2 c = centre;
            c[minor] += x_major ? k : -k;
            if (line_diamond(a, b, c))
                return true;
        }
    }
    return false;
}
/* Clip the pixel's unit square against four line-rectangle halfplanes.
 * Local coordinates avoid cancellation in the final area calculation. */
static float line_coverage(float2 a, float2 b, float2 centre, float width)
{
    float2 delta = b - a;
    float length = metal::length(delta);
    float2 tangent = delta / length, normal(-tangent.y, tangent.x);
    const float2 normals[4] = { -tangent, tangent, normal, -normal };
    const float limits[4] = { 0, length, width * .5f, width * .5f };
    float2 polygon[8] = {
        { -.5f, -.5f }, { .5f, -.5f }, { .5f, .5f }, { -.5f, .5f }
    };
    uint count = 4;
    for (uint plane = 0; plane < 4 && count; plane++) {
        float2 next[8];
        uint n = 0;
        float2 previous = polygon[count - 1];
        float fp = dot(previous + centre - a, normals[plane]) - limits[plane];
        for (uint i = 0; i < count; i++) {
            float2 current = polygon[i];
            float fc =
                dot(current + centre - a, normals[plane]) - limits[plane];
            if ((fp < 0 && fc > 0) || (fp > 0 && fc < 0))
                next[n++] = mix(previous, current, fp / (fp - fc));
            if (fc <= 0)
                next[n++] = current;
            previous = current;
            fp = fc;
        }
        count = n;
        for (uint i = 0; i < count; i++)
            polygon[i] = next[i];
    }
    float area = 0;
    for (uint i = 0; i < count; i++) {
        float2 p = polygon[i], q = polygon[(i + 1) % count];
        area += p.x * q.y - p.y * q.x;
    }
    return clamp(abs(area) * .5f, 0.0f, 1.0f);
}

/* Integrate perspective-correct attributes over the covered square. Full
 * squares use the centre, as permitted by GL 2.1 section 3.5.3. Boundary
 * integration uses an 8x8 Gaussian rule per fan triangle (Duffy transform).
 * Coverage itself is the exact polygon/square intersection area. */
static float3 polygon_weights(float2 p, thread const float3 *basis)
{
    float3 q(p, 1);
    float3 weights(dot(basis[0], q), dot(basis[1], q), dot(basis[2], q));
    return weights / (weights.x + weights.y + weights.z);
}
static float polygon_sample(thread const float4 *clips, float2 viewport,
                            float2 centre, thread float3 &weights,
                            device const NV2AMetalPolygonProjection *projection,
                            bool preprojected)
{
    weights = 0;
    float2 points[12];
    uint count;
    if (preprojected) {
        count = projection->count;
        if (count > 8)
            return 0;
        for (uint i = 0; i < count; i++)
            points[i] =
                float2(projection->points[i][0], projection->points[i][1]);
    } else {
        count = polygon_project(clips, viewport, points);
    }
    if (!count)
        return 0;
    // Homogeneous barycentrics avoid division by source W, including W=0.
    float common_scale = 0;
    for (uint i = 0; i < 3; i++)
        common_scale =
            max(common_scale,
                max(max(abs(clips[i].x), abs(clips[i].y)), abs(clips[i].w)));
    float3 rows[3], basis[3];
    for (uint i = 0; i < 3; i++) {
        float3 p = clips[i].xyw / common_scale;
        rows[i] = float3((p.x + p.z) * viewport.x * .5f - centre.x * p.z,
                         (p.z - p.y) * viewport.y * .5f - centre.y * p.z, p.z);
    }
    for (uint i = 0; i < 3; i++)
        basis[i] = cross(rows[(i + 1) % 3], rows[(i + 2) % 3]);
    /* Zero-coverage helper pixels still need the perspective plane for
     * texture derivatives. Covered boundary pixels overwrite these weights
     * with their existing area integral below. */
    weights = polygon_weights(float2(0), basis);
    for (uint i = 0; i < count; i++)
        points[i] -= centre;
    float orientation = 0;
    for (uint i = 0; i < count; i++) {
        float2 a = points[i], b = points[(i + 1) % count];
        orientation += a.x * b.y - a.y * b.x;
    }
    bool full = true;
    for (uint i = 0; i < count; i++) {
        float2 a = points[i], d = points[(i + 1) % count] - a;
        float sign = orientation > 0 ? 1.0f : -1.0f;
        float minimum =
            sign * (d.y * a.x - d.x * a.y) - .5f * (abs(d.x) + abs(d.y));
        full &= minimum >= 0;
    }
    for (uint side = 0; side < 4 && count; side++) {
        float2 next[12];
        uint n = 0, axis = side / 2;
        float sign = side & 1 ? -1.0f : 1.0f;
        float2 previous = points[count - 1];
        float pd = .5f + sign * previous[axis];
        for (uint i = 0; i < count; i++) {
            float2 current = points[i];
            float cd = .5f + sign * current[axis];
            if ((pd < 0 && cd > 0) || (pd > 0 && cd < 0))
                next[n++] = mix(previous, current, pd / (pd - cd));
            if (cd >= 0)
                next[n++] = current;
            previous = current;
            pd = cd;
        }
        count = n;
        for (uint i = 0; i < count; i++)
            points[i] = next[i];
    }
    float twice_area = 0;
    for (uint i = 0; i < count; i++) {
        float2 p = points[i], q = points[(i + 1) % count];
        twice_area += p.x * q.y - p.y * q.x;
    }
    float area = min(abs(twice_area) * .5f, 1.0f);
    if (!(area > 0))
        return 0;
    /* A clipped edge can move by a float ULP onto a square boundary.
     * Classify near-full area consistently with the centre convention. */
    if (full || area >= 1 - 0x1p-20f) {
        weights = polygon_weights(float2(0), basis);
        return area;
    }
    const float nodes[8] = { .0198550717512319f, .101666761293187f,
                             .237233795041836f,  .408282678752175f,
                             .591717321247825f,  .762766204958164f,
                             .898333238706813f,  .980144928248768f };
    const float factors[8] = { .0506142681451881f, .111190517226687f,
                               .156853322938944f,  .181341891689181f,
                               .181341891689181f,  .156853322938944f,
                               .111190517226687f,  .0506142681451881f };
    weights = 0;
    float total = 0;
    for (uint i = 1; i + 1 < count; i++) {
        float2 a = points[0], b = points[i] - a, c = points[i + 1] - a;
        float determinant = abs(b.x * c.y - b.y * c.x);
        if (!(determinant > 0))
            continue;
        // The homogeneous numerators are affine. Evaluate each row once
        // before the inner quadrature loop.
        float3 origin, along_b, along_c;
        for (uint k = 0; k < 3; k++) {
            origin[k] = dot(basis[k], float3(a, 1));
            along_b[k] = dot(basis[k].xy, b);
            along_c[k] = dot(basis[k].xy, c);
        }
        float3 end_b = origin + along_b, end_c = origin + along_c;
        float3 signed_denominators(origin.x + origin.y + origin.z,
                                   end_b.x + end_b.y + end_b.z,
                                   end_c.x + end_c.y + end_c.z);
        bool same_sign =
            all(signed_denominators > 0) || all(signed_denominators < 0);
        float3 denominators = abs(signed_denominators);
        float smallest =
            min(denominators.x, min(denominators.y, denominators.z));
        float largest =
            max(denominators.x, max(denominators.y, denominators.z));
        float3 magnitude = max(abs(origin), max(abs(end_b), abs(end_c)));
        float numerator = max(magnitude.x, max(magnitude.y, magnitude.z));
        /* For affine numerators n and denominator D, both rules integrate
         * the cubic reciprocal expansion exactly after the Duffy transform.
         * Dmax/Dmin <= 33/32 gives r <= 1/65. With |n| <= 2*Dmin,
         * their normalized-rule difference is <= 4*r^4/(1-r) < 2.3e-7,
         * before Float32 rounding. Other cases retain the 8x8 rule. */
        bool compact = same_sign && smallest > 0 && isfinite(largest) &&
                       largest / smallest <= 1.03125f &&
                       numerator / smallest <= 2.0f;
        const float compact_nodes[3] = { .1127016653792583f, .5f,
                                         .8872983346207417f };
        const float compact_factors[3] = { .2777777777777778f,
                                           .4444444444444444f,
                                           .2777777777777778f };
        if (compact) {
            for (uint j = 0; j < 3; j++) {
                float s = compact_nodes[j];
                float3 row = origin + s * along_b;
                float3 step = (1 - s) * along_c;
                float row_factor = determinant * (1 - s) * compact_factors[j];
                for (uint k = 0; k < 3; k++) {
                    float3 values = row + compact_nodes[k] * step;
                    values /= values.x + values.y + values.z;
                    float factor = row_factor * compact_factors[k];
                    weights += factor * values;
                    total += factor;
                }
            }
        } else {
            for (uint j = 0; j < 8; j++)
                for (uint k = 0; k < 8; k++) {
                    float s = nodes[j], t = (1 - s) * nodes[k];
                    float factor =
                        determinant * (1 - s) * factors[j] * factors[k];
                    weights +=
                        factor * polygon_weights(a + s * b + t * c, basis);
                    total += factor;
                }
        }
    }
    weights /= total;
    return area;
}

static bool pixel_quad_helpers(uint program, bool legacy_spec_const,
                               constant NV2AMetalTextureStage *textures)
{
    uint modes = (1u << (program & 31)) | (1u << ((program >> 5) & 31)) |
                 (1u << ((program >> 10) & 31)) |
                 (1u << ((program >> 15) & 31));
    uint without_sampling =
        (1u << PS_TEXTUREMODES_NONE) | (1u << PS_TEXTUREMODES_PASSTHRU) |
        (1u << PS_TEXTUREMODES_CLIPPLANE) | (1u << PS_TEXTUREMODES_DOTPRODUCT) |
        (1u << PS_TEXTUREMODES_DOT_ZW);
    if (legacy_spec_const)
        without_sampling |= 1u << PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST;
    if ((modes & ~without_sampling) == 0)
        return false;
#pragma unroll
    for (uint i = 0; i < 4; i++) {
        uint mode = (program >> (5 * i)) & 31;
        if (!(without_sampling & (1u << mode)) &&
            (mode > PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST ||
             !sample_base_only(textures[i].sampling)))
            return true;
    }
    return false;
}

static PixelOutput pixel_fragment(
    PixelVertex in, float2 point, bool front,
    device const NV2AMetalVertex *vertices, constant NV2AMetalPixelUniforms &u,
    device const NV2AMetalPolygonProjection *projections, uint projection_count,
    array<texture2d<float>, 4> t2, array<texture3d<float>, 4> t3,
    array<texturecube<float>, 4> tc, array<sampler, 4> smp)
{
    float coverage = 1;
    bool polygon_discard = false;
    bool back = u.two_side && (in.face == NV2AMetalFaceBack ||
                               (in.face == NV2AMetalFaceNative && !front));
    uint color = back ? 2 : 0;
    float4 diffuse =
        back ? (u.smooth_shading ? in.back_diffuse : in.flat_back_diffuse) :
               (u.smooth_shading ? in.diffuse : in.flat_diffuse);
    float4 specular =
        back ? (u.smooth_shading ? in.back_specular : in.flat_back_specular) :
               (u.smooth_shading ? in.specular : in.flat_specular);
    float fog = in.fog;
    float4 p[4] = { in.t0, in.t1, in.t2, in.t3 };
    float line_t = 0, perspective_t = 0, perspective_w = 0;
    if (NV2A_PIXEL_RASTER_TAG(in) == 1) {
        float2 a = in.p2.xy, b = in.p2.zw;
        if (in.line_base > u.vertex_capacity ||
            u.vertex_capacity - in.line_base < 3 ||
            !(in.line_raster.x > 0 && in.line_raster.x <= 16384) ||
            !all(isfinite(a)) || !all(isfinite(b)) || all(a == b))
            discard_fragment();
        coverage =
            in.line_raster.y != 0 ?
                line_coverage(a, b, in.position.xy, in.line_raster.x) :
                float(line_alias(a, b, in.position.xy, in.line_raster.x));
        if (!(coverage > 0))
            discard_fragment();
        float2 scale(u.surface_scale[0], u.surface_scale[1]);
        float2 delta = (in.p1.xy - in.p0.xy) * scale;
        float from_a = dot(in.position.xy - in.p0.xy * scale, delta);
        float from_b = dot(in.p1.xy * scale - in.position.xy, delta);
        line_t = from_a / dot(delta, delta);
        // Keep both endpoint distances: 1-t loses the short distance near B.
        float denominator = from_b / in.p0.w + from_a / in.p1.w;
        perspective_t = (from_a / in.p1.w) / denominator;
        perspective_w = dot(delta, delta) / denominator;
        if (!isfinite(perspective_t))
            discard_fragment();
        device const NV2AMetalVertex &va = vertices[in.line_base];
        device const NV2AMetalVertex &vb = vertices[in.line_base + 2];
        diffuse = mix(combiner_load_device(va.color[color]),
                      combiner_load_device(vb.color[color]), perspective_t);
        specular =
            mix(combiner_load_device(va.color[color + 1]),
                combiner_load_device(vb.color[color + 1]), perspective_t);
        fog = mix(va.fog, vb.fog, perspective_t);
        for (uint i = 0; i < 4; i++)
            p[i] = mix(combiner_load_device(va.texcoord[i]),
                       combiner_load_device(vb.texcoord[i]), perspective_t);
    }
    if (NV2A_PIXEL_RASTER_TAG(in) == 2) {
        if (in.line_base > u.vertex_capacity ||
            u.vertex_capacity - in.line_base < 6)
            discard_fragment();
        const uint indices[3] = { in.line_base, in.line_base + 2,
                                  in.line_base + 5 };
        float4 clips[3];
        for (uint i = 0; i < 3; i++) {
            device const NV2AMetalVertex &v = vertices[indices[i]];
            clips[i] = float4(v.coverage_clip[0], v.coverage_clip[1], 0,
                              v.line_raster[0]);
        }
        device const NV2AMetalVertex &first = vertices[indices[0]];
        float2 viewport(first.line_raster[1], first.point_size);
        if (!all(isfinite(viewport)) || any(viewport <= 0) ||
            any(viewport > 16384))
            discard_fragment();
        float3 weights;
        uint projection_index = in.line_base / 6;
        if (projection_count && projection_index >= projection_count)
            discard_fragment();
        coverage = polygon_sample(clips, viewport, in.position.xy, weights,
                                  projections +
                                      (projection_count ? projection_index : 0),
                                  projection_count != 0);
        /* Stages without sampling need no helper gradients. Otherwise retain
         * helper coordinates in every covered quad, but skip fully empty quads
         * before reconstructing attributes and sampling. Vote before the
         * per-pixel finite-weight rejection. */
        if (!pixel_quad_helpers(NV2A_COMBINER_SHADER_STAGE_PROGRAM(u.combiner),
                                u.legacy_spec_const, u.textures)) {
            if (!(coverage > 0))
                discard_fragment();
        } else if (!quad_or(uint(coverage > 0))) {
            discard_fragment();
        }
        if (!all(isfinite(weights)))
            discard_fragment();
        polygon_discard = !(coverage > 0);
        diffuse = specular = 0;
        fog = 0;
        for (uint i = 0; i < 4; i++)
            p[i] = 0;
        for (uint i = 0; i < 3; i++) {
            device const NV2AMetalVertex &v = vertices[indices[i]];
            diffuse += weights[i] * combiner_load_device(v.color[color]);
            specular += weights[i] * combiner_load_device(v.color[color + 1]);
            fog += weights[i] * v.fog;
            for (uint k = 0; k < 4; k++)
                p[k] += weights[i] * combiner_load_device(v.texcoord[k]);
        }
    }
    float2 coordinate = in.position.xy - 0.5f;
    bool contained = false;
    for (uint i = 0; i < 8; i++) {
        int4 region(u.clip_regions[i][0], u.clip_regions[i][1],
                    u.clip_regions[i][2], u.clip_regions[i][3]);
        bool inside = all(coordinate >= float2(region.xy)) &&
                      all(coordinate < float2(region.zw));
        contained |= inside;
    }
    if (contained == bool(u.window_clip_exclusive)) {
        discard_fragment();
    }

    float2 xy = in.position.xy / float2(u.surface_scale[0], u.surface_scale[1]);
    float3 bary(pixel_det(in.p1.xy - xy, in.p2.xy - xy),
                pixel_det(in.p2.xy - xy, in.p0.xy - xy),
                pixel_det(in.p0.xy - xy, in.p1.xy - xy));
    float area = bary.x + bary.y + bary.z;
    if (u.z_perspective) {
        bary /= float3(in.p0.w, in.p1.w, in.p2.w);
    }
    float bary_sum = bary.x + bary.y + bary.z;
    float inv_sum = 1.0f / bary_sum;
    if (isinf(inv_sum)) {
        inv_sum = 0;
    }
    bary.yz *= inv_sum;
    float3 depth_vertices = u.z_perspective ?
                                float3(in.p0.w, in.p1.w, in.p2.w) :
                                float3(in.p0.z, in.p1.z, in.p2.z);
    bool f24_line = NV2A_PIXEL_RASTER_TAG(in) == 1 &&
                    u.depth_format == NV2AMetalPixelDepthF24 &&
                    !u.z_perspective;
    // Expanded lines use p2 to carry clipped XY endpoints, not depth.
    if (f24_line)
        depth_vertices.z = depth_vertices.x;
    float2 depth_delta = depth_vertices.yz - depth_vertices.xx;
    float depth_base = depth_vertices.x;
    int depth_shift = 0;
    if (u.depth_format == NV2AMetalPixelDepthF24 && !u.z_perspective) {
        // Retain unscaled differences, including their subtraction underflow.
        // Scale before weighting to avoid an additional Float32 underflow.
        float largest = max(abs(depth_vertices.x),
                            max(abs(depth_vertices.y), abs(depth_vertices.z)));
        uint exponent = (as_type<uint>(largest) >> 23) & 255;
        if (exponent > 0 && exponent < 127)
            depth_shift = min(127 - int(exponent), 126);
    }
    if (depth_shift) {
        depth_base = ldexp(depth_base, depth_shift);
        depth_delta = ldexp(depth_delta, depth_shift);
    }
    float z = depth_base + (bary.y * depth_delta.x + bary.z * depth_delta.y);
    if (u.z_perspective && area != 0 &&
        any(depth_vertices != depth_vertices.xxx)) {
        // Interpolating W through normalized weights can cancel or underflow
        // when clamped endpoint W values span the full permitted range.
        z = area / bary_sum;
    }
    if (depth_shift)
        z = ldexp(z, -depth_shift);
    if (NV2A_PIXEL_RASTER_TAG(in) == 1) {
        float t = u.z_perspective ? perspective_t : line_t;
        if (f24_line) {
            // Match the affine depth plane used by unexpanded lines.
            z = depth_base + t * depth_delta.x;
            if (depth_shift)
                z = ldexp(z, -depth_shift);
        } else {
            z = u.z_perspective ? perspective_w : mix(in.p0.z, in.p1.z, t);
        }
    }
    if (u.z_perspective) {
        if (z > 0) {
            float slope_offset = u.depth_factor * in.slope * z * z;
            z += u.depth_offset;
            z += slope_offset;
        } else {
            z = as_type<float>(0x7f7fffffu);
        }
        if (isnan(z)) {
            z = as_type<float>(0x7f7fffffu);
        }
    } else {
        z += u.depth_offset;
        z += u.depth_factor * in.slope;
    }
    if (u.point_sprite)
        p[3] = float4(point, 1, 1);
    float4 textures[4], combiner_textures[4];
    uint texture_signed[4] = {};
    uint texture_hilo16[4] = {};
    float dots[4] = {};
    bool depth_replaced = false;
    /* Stage opcodes are pipeline constants; expose each of the four stages
     * before target compilation rather than retaining a generic opcode loop. */
#pragma unroll
    for (uint i = 0; i < 4; i++) {
        constant NV2AMetalTextureStage &s = u.textures[i];
        uint mode =
            (NV2A_COMBINER_SHADER_STAGE_PROGRAM(u.combiner) >> (5 * i)) & 31;
        uint previous =
            i == 1 ? 0 : (u.other_stage_input >> (i == 2 ? 16 : 20)) & 15;
        uint dotmap = i == 0 ? 0 : (u.other_stage_input >> (4 * (i - 1))) & 15;
        float4 color(0);
        float bump_scale = 1;
        bool sampled = false;
        switch (mode) {
        case PS_TEXTUREMODES_NONE:
            color = float4(0, 0, 0, 1);
            break;
        case PS_TEXTUREMODES_PASSTHRU:
            // NV_texture_shader 3.8.13.1.6: clamp after interpolation, before
            // the combiner and dependent texture stages consume the result.
            color = clamp(p[i], 0.0f, 1.0f);
            break;
        case PS_TEXTUREMODES_CLIPPLANE:
            for (uint k = 0; k < 4; k++) {
                if ((s.compare_mask & (1u << k)) ? p[i][k] >= 0 : p[i][k] < 0) {
                    discard_fragment();
                }
            }
            break;
        case PS_TEXTUREMODES_PROJECT2D:
        case PS_TEXTUREMODES_PROJECT3D: {
            sampled = true;
            if (s.shadow) {
                color = pixel_shadow(p[i], s, t2[i], smp[i], u.shadow_func,
                                     mode == PS_TEXTUREMODES_PROJECT3D);
                break;
            }
            p[i].xyz = pixel_border(p[i].xyz, s);
            if (mode == PS_TEXTUREMODES_PROJECT2D && s.convolution) {
                /* GL uses this Gaussian kernel for both Gaussian and Quincunx.
                 */
                const float weights[3] = { 1.0f / 4, 2.0f / 4, 1.0f / 4 };
                float2 center = pixel_normalize_rect(p[i].xyz, s, t2[i]).xy;
                float2 size(t2[i].get_width(), t2[i].get_height());
                for (int y = -1; y <= 1; y++) {
                    for (int x = -1; x <= 1; x++) {
                        float2 delta = float2(x, y) / size;
                        color += nv2a_sample(
                                     t2[i], smp[i], (center + delta) / p[i].w,
                                     s.sampling, pixel_unsigned_half_mask(s)) *
                                 weights[x + 1] * weights[y + 1];
                    }
                }
            } else {
                color = pixel_project(p[i], s, t2[i], t3[i], tc[i], smp[i],
                                      mode == PS_TEXTUREMODES_PROJECT2D);
            }
            break;
        }
        case PS_TEXTUREMODES_CUBEMAP:
            sampled = true;
            color =
                pixel_sample(p[i].xyz, s, t2[i], t3[i], tc[i], smp[i], true);
            break;
        case PS_TEXTUREMODES_BUMPENVMAP:
        case PS_TEXTUREMODES_BUMPENVMAP_LUM: {
            sampled = true;
            float4 previous_color = textures[previous];
            constant NV2AMetalTextureStage &source = u.textures[previous];
            float2 bump(
                source.snorm == NV2AMetalTextureNormalizationLegacySigned ||
                        (source.signed_channels & 4) ?
                    previous_color.b :
                    pixel_sign(previous_color.b, 3),
                source.snorm == NV2AMetalTextureNormalizationLegacySigned ||
                        (source.signed_channels & 2) ?
                    previous_color.g :
                    pixel_sign(previous_color.g, 3));
            float2 delta =
                float2(s.bump_matrix[0] * bump.x + s.bump_matrix[2] * bump.y,
                       s.bump_matrix[1] * bump.x + s.bump_matrix[3] * bump.y);
            color = pixel_sample(float3(p[i].xy + delta, p[i].z), s, t2[i],
                                 t3[i], tc[i], smp[i], false);
            if (mode == PS_TEXTUREMODES_BUMPENVMAP_LUM) {
                float luminance = previous_color.r;
                if (source.snorm == NV2AMetalTextureNormalizationLegacySigned) {
                    luminance =
                        luminance >= 0 ? luminance / 2 : 1 + luminance / 2;
                } else if (source.signed_channels & 1) {
                    float range =
                        (u.hilo16_mask & (1u << previous)) ? 65536.0f : 256.0f;
                    float raw = luminance * (range / 2);
                    luminance = (raw < 0 ? raw + range : raw) / (range - 1);
                }
                bump_scale =
                    clamp(s.bump_scale * luminance + s.bump_offset, 0.0f, 1.0f);
            }
            break;
        }
        case PS_TEXTUREMODES_DPNDNT_AR:
        case PS_TEXTUREMODES_DPNDNT_GB: {
            sampled = true;
            float2 c = mode == PS_TEXTUREMODES_DPNDNT_AR ?
                           textures[previous].ar :
                           textures[previous].gb;
            float3 coord = pixel_border(float3(c, 0), s);
            color = nv2a_sample(t2[i], smp[i], coord.xy, s.sampling,
                                pixel_unsigned_half_mask(s));
            break;
        }
        case PS_TEXTUREMODES_BRDF: {
            // NVIDIA US6664963, equations8/9: unsigned16 theta/phi from the
            // two preceding stages. Its summary table reverses delta phi;
            // follow the detailed equations pending Xbox hardware parity.
            float2 eye = pixel_dotmap(textures[i - 2], PS_DOTMAPPING_HILO_1, 0,
                                      texture_hilo16[i - 2])
                             .xy;
            float2 light = pixel_dotmap(textures[i - 1], PS_DOTMAPPING_HILO_1,
                                        0, texture_hilo16[i - 1])
                               .xy;
            float3 c(eye.x, light.x, light.y - eye.y);
            sampled = true;
            color = nv2a_sample(t3[i], smp[i], pixel_border(c, s), s.sampling,
                                pixel_unsigned_half_mask(s));
            break;
        }
        case PS_TEXTUREMODES_DOTPRODUCT:
            dots[i] = dot(p[i].xyz, pixel_dotmap(textures[previous], dotmap,
                                                 texture_signed[previous],
                                                 texture_hilo16[previous]));
            break;
        case PS_TEXTUREMODES_DOT_ZW: {
            dots[i] = dot(p[i].xyz, pixel_dotmap(textures[previous], dotmap,
                                                 texture_signed[previous],
                                                 texture_hilo16[previous]));
            // NV_texture_shader 3.8.13.1.21 replaces window depth after
            // polygon offset. Direct3D texm3x2depth defines W==0 as depth1.
            float replacement = dots[i] == 0 ? 1 : dots[i - 1] / dots[i];
            if (!isfinite(replacement) ||
                replacement < u.clip_range[2] / u.clip_range[1] ||
                replacement > u.clip_range[3] / u.clip_range[1]) {
                discard_fragment();
            }
            z = replacement * u.clip_range[1];
            depth_replaced = true;
            break;
        }
        case PS_TEXTUREMODES_DOT_ST:
        case PS_TEXTUREMODES_DOT_RFLCT_DIFF:
        case PS_TEXTUREMODES_DOT_RFLCT_SPEC:
        case PS_TEXTUREMODES_DOT_STR_3D:
        case PS_TEXTUREMODES_DOT_STR_CUBE:
        case PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST: {
            if (mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST &&
                u.legacy_spec_const) {
                break;
            }
            sampled = true;
            dots[i] = dot(p[i].xyz, pixel_dotmap(textures[previous], dotmap,
                                                 texture_signed[previous],
                                                 texture_hilo16[previous]));
            float3 c;
            if (mode == PS_TEXTUREMODES_DOT_ST) {
                c = float3(dots[i - 1], dots[i], 0);
            } else if (mode == PS_TEXTUREMODES_DOT_RFLCT_DIFF) {
                uint next_previous = (u.other_stage_input >> 20) & 15;
                uint next_map = (u.other_stage_input >> 8) & 15;
                float next_dot = dot(
                    p[3].xyz, pixel_dotmap(textures[next_previous], next_map,
                                           texture_signed[next_previous],
                                           texture_hilo16[next_previous]));
                c = float3(dots[1], dots[2], next_dot);
            } else {
                c = float3(dots[1], dots[2], dots[3]);
                if (mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC ||
                    mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST) {
                    float3 eye = mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST ?
                                     float3(u.eye_vector[0], u.eye_vector[1],
                                            u.eye_vector[2]) :
                                     float3(p[1].w, p[2].w, p[3].w);
                    // Keep the reflection formula's intermediate products
                    // finite without changing its length before border remap.
                    float normal_scale = max(max(abs(c.x), abs(c.y)), abs(c.z));
                    if (isfinite(normal_scale) && normal_scale > 0) {
                        c /= normal_scale;
                    }
                    float eye_scale =
                        max(max(abs(eye.x), abs(eye.y)), abs(eye.z));
                    eye_scale =
                        isfinite(eye_scale) && eye_scale > 0 ? eye_scale : 1;
                    eye /= eye_scale;
                    c = (2.0f * c * (dot(c, eye) / dot(c, c)) - eye) *
                        eye_scale;
                }
            }
            c = pixel_border(c, s);
            bool cube = mode == PS_TEXTUREMODES_DOT_RFLCT_DIFF ||
                        mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC ||
                        mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST ||
                        mode == PS_TEXTUREMODES_DOT_STR_CUBE;
            color = pixel_sample(c, s, t2[i], t3[i], tc[i], smp[i], cube);
            break;
        }
        default:
            break;
        }
        if (sampled) {
            if (s.alphakill && color.a == 0) {
                discard_fragment();
            }
            if (s.colorkey_mode) {
                float4 key_color = color;
                for (uint k = 0; k < 4; k++) {
                    if ((s.signed_channels & (1u << k)) &&
                        (!(u.hilo16_mask & (1u << i)) || k < 3)) {
                        float range =
                            (u.hilo16_mask & (1u << i)) ? 65536.0f : 256.0f;
                        float raw = color[k] * (range / 2);
                        key_color[k] =
                            (raw < 0 ? raw + range : raw) / (range - 1);
                    }
                }
                uint4 bytes = uint4(key_color * 255.0f + .5f);
                uint packed =
                    bytes.a << 24 | bytes.r << 16 | bytes.g << 8 | bytes.b;
                if ((packed & s.color_key_mask) ==
                    (s.color_key & s.color_key_mask)) {
                    if (s.colorkey_mode == COLOR_KEY_DISCARD) {
                        discard_fragment();
                    } else if (s.colorkey_mode == COLOR_KEY_KILL_ALPHA) {
                        color.a = 0;
                    } else {
                        color = float4(0);
                    }
                }
            }
        }
        textures[i] = color;
        texture_signed[i] = sampled ? s.signed_channels : 0;
        texture_hilo16[i] = sampled ? (u.hilo16_mask >> i) & 1 : 0;
        combiner_textures[i] = color;
        // Luminance scaling affects the combiner, not dependent shader input.
        combiner_textures[i].rgb *= bump_scale;
        if (sampled) {
            // Keep signed8/signed16 precision for dependent stages; combiner
            // transfer uses 2*raw/(2^bits-1), extending the existing signed8
            // precision model to signed16 HILO (Xbox parity is pending).
            for (uint k = 0; k < 4; k++) {
                if ((s.signed_channels & (1u << k)) &&
                    (!texture_hilo16[i] || k < 3)) {
                    combiner_textures[i][k] *= texture_hilo16[i] ?
                                                   65536.0f / 65535.0f :
                                                   256.0f / 255.0f;
                }
            }
        }
    }
    /* Let the whole polygon quad reach texture gradients before suppressing
     * uncovered samples. An early discard can leave neighbour coordinates
     * undefined, changing mip/anisotropic filtering with shader instrumentation
     * or a different conservative carrier. No discarded sample reaches color,
     * depth or visibility output. */
    if (polygon_discard)
        discard_fragment();
    thread float4 registers[16] = {};
    registers[PS_REGISTER_V0] = diffuse;
    registers[PS_REGISTER_V1] = specular;
    registers[PS_REGISTER_FOG] =
        float4(combiner_load(u.fog_color).rgb, clamp(fog, 0.0f, 1.0f));
    for (uint i = 0; i < 4; i++) {
        registers[PS_REGISTER_T0 + i] = combiner_textures[i];
    }
    if (!depth_replaced) {
        if (u.depth_clipping) {
            if (z < u.clip_range[2] || u.clip_range[3] < z) {
                discard_fragment();
            }
        } else {
            z = clamp(z, u.clip_range[2], u.clip_range[3]);
        }
    }
    PixelOutput out;
    out.color = nv2a_combiner(u.combiner, registers);
    if (u.alpha_test && !pixel_compare(float(int(round(out.color.a * 255.0f))),
                                       float(u.alpha_ref), u.alpha_func)) {
        discard_fragment();
    }
    out.color.a *= coverage;
    if (u.depth_format == NV2AMetalPixelDepthD16) {
        out.depth = floor(z) / 65535.0f;
    } else if (u.depth_format == NV2AMetalPixelDepthD24) {
        out.depth = as_type<float>(as_type<uint>(floor(z) / 16777216.0f) + 1u);
    } else if (u.depth_format == NV2AMetalPixelDepthF16) {
        // Xbox DepthFmt captures distinguish truncation/zero exponent from
        // IEEE half and nearest rounding. Native depth stores ordered codes.
        uint bits = as_type<uint>(z);
        uint code = !(z >= 0.015625f) ? 0 :
                    z >= 511.9375f    ? 65535u :
                                        (bits - 0x3c000000u) >> 11;
        out.depth = float(code) / 65535.0f;
    } else {
        // Positive F24 uses IEEE exponent bits and sixteen fraction bits.
        // Keep the ordered code in native depth; flush subnormal Draw values.
        uint code = z >= 0x1p-126f ? as_type<uint>(z) >> 7 : 0;
        out.depth = float(code) / 16777215.0f;
    }
    return out;
}

/* Original GL/NV table order in gl/constants.h. Fixed-point source conversion
 * precedes the logical operation; masks/blending/depth/stencil remain native.
 * The framebuffer fetch uses a raster order group, never a texture alias. */
static uint pixel_logic(uint source, uint destination, uint op)
{
    switch (op) {
    case 0:
        return 0;
    case 1:
        return source & destination;
    case 2:
        return source & ~destination;
    case 3:
        return source;
    case 4:
        return ~source & destination;
    case 5:
        return destination;
    case 6:
        return source ^ destination;
    case 7:
        return source | destination;
    case 8:
        return ~(source | destination);
    case 9:
        return ~(source ^ destination);
    case 10:
        return ~destination;
    case 11:
        return source | ~destination;
    case 12:
        return ~source;
    case 13:
        return ~source | destination;
    case 14:
        return ~(source & destination);
    case 15:
        return ~0u;
    default:
        return source;
    }
}
// A7 surfaces keep a normalized seven-bit alpha field and a forced high bit.
// The host attachment preserves all guest bytes, including contradictory CPU
// high bits until a draw writes alpha; blend/logic consume only the A7 field.
static float pixel_store_a7(float alpha, uint storage)
{
    uint low = uint(round(clamp(alpha, 0.0f, 1.0f) * 127.0f));
    return float(low | (storage == NV2AMetalSurfaceStorageO7 ? 128u : 0u)) /
           255.0f;
}
fragment PixelOutput nv2a_pixel_fragment(
    PixelVertex in [[stage_in]], float2 point [[point_coord]],
    bool front [[front_facing]],
    device const NV2AMetalVertex *vertices [[buffer(0)]],
    constant NV2AMetalPixelUniforms &u [[buffer(1)]],
    constant NV2AMetalPixelStorageInfo &storage [[buffer(2)]],
    device const NV2AMetalPolygonProjection *projections [[buffer(3)]],
    array<texture2d<float>, 4> t2 [[texture(0)]],
    array<texture3d<float>, 4> t3 [[texture(4)]],
    array<texturecube<float>, 4> tc [[texture(8)]],
    array<sampler, 4> smp [[sampler(0)]])
{
    uint surface_channels = storage.surface_channels;
    PixelOutput out =
        pixel_fragment(in, point, front, vertices, u, projections,
                       storage.polygon_projection_count, t2, t3, tc, smp);
    if (surface_channels == NV2AMetalSurfaceStorageB8 ||
        surface_channels == NV2AMetalSurfaceStorageG8B8)
        out.color.r = out.color.b;
    else if (surface_channels >= NV2AMetalSurfaceStorageZ7)
        out.color.a = pixel_store_a7(out.color.a, surface_channels);
    else if (surface_channels >= NV2AMetalSurfaceStorageZ1)
        out.color.a = surface_channels == NV2AMetalSurfaceStorageO1 ||
                              surface_channels == NV2AMetalSurfaceStorageO8 ?
                          1 :
                          0;
    return out;
}
static float4 pixel_blend_factor(uint factor, float4 source, float4 dest,
                                 float4 constant_color)
{
    switch (factor) {
    case 0:
        return 0;
    case 1:
        return 1;
    case 2:
        return source;
    case 3:
        return 1 - source;
    case 4:
        return source.a;
    case 5:
        return 1 - source.a;
    case 6:
        return dest.a;
    case 7:
        return 1 - dest.a;
    case 8:
        return dest;
    case 9:
        return 1 - dest;
    case 10:
        return float4(float3(min(source.a, 1 - dest.a)), 1);
    case 12:
        return constant_color;
    case 13:
        return 1 - constant_color;
    case 14:
        return constant_color.a;
    case 15:
        return 1 - constant_color.a;
    default:
        return 0;
    }
}
static float4 pixel_blend(float4 source, float4 dest,
                          constant NV2AMetalPixelUniforms &u)
{
    source = clamp(source, 0.0f, 1.0f);
    dest = clamp(dest, 0.0f, 1.0f);
    uint equation = u.blend & NV_PGRAPH_BLEND_EQN;
    if (equation == 3)
        return min(source, dest);
    if (equation == 4)
        return max(source, dest);
    float4 constant_color(u.blend_color[0], u.blend_color[1], u.blend_color[2],
                          u.blend_color[3]);
    float4 a =
        source * pixel_blend_factor((u.blend & NV_PGRAPH_BLEND_SFACTOR) >> 4,
                                    source, dest, constant_color);
    float4 b =
        dest * pixel_blend_factor((u.blend & NV_PGRAPH_BLEND_DFACTOR) >> 8,
                                  source, dest, constant_color);
    return clamp(equation == 0                    ? a - b :
                 (equation == 1 || equation == 5) ? b - a :
                                                    a + b,
                 0.0f, 1.0f);
}
fragment PixelOutput nv2a_pixel_logic_fragment(
    PixelVertex in [[stage_in]], float2 point [[point_coord]],
    bool front [[front_facing]],
    float4 destination [[color(0), raster_order_group(0)]],
    device const NV2AMetalVertex *vertices [[buffer(0)]],
    constant NV2AMetalPixelUniforms &u [[buffer(1)]],
    constant NV2AMetalPixelStorageInfo &storage [[buffer(2)]],
    device const NV2AMetalPolygonProjection *projections [[buffer(3)]],
    array<texture2d<float>, 4> t2 [[texture(0)]],
    array<texture3d<float>, 4> t3 [[texture(4)]],
    array<texturecube<float>, 4> tc [[texture(8)]],
    array<sampler, 4> smp [[sampler(0)]])
{
    uint surface_channels = storage.surface_channels;
    PixelOutput out =
        pixel_fragment(in, point, front, vertices, u, projections,
                       storage.polygon_projection_count, t2, t3, tc, smp);
    if (surface_channels == NV2AMetalSurfaceStorageB8 ||
        surface_channels == NV2AMetalSurfaceStorageG8B8)
        out.color.r = out.color.b;
    if (surface_channels >= NV2AMetalSurfaceStorageZ7)
        destination.a =
            float(uint(round(clamp(destination.a, 0.0f, 1.0f) * 255.0f)) &
                  127u) /
            127.0f;
    /* Packed attachment fetches may arrive through reduced precision. Recover
     * their stored integers before blending, then normalize at shader
     * precision. */
    for (uint i = 0; i < 4; i++) {
        uint bits = u.color_bits[i];
        if (bits && bits <= 8) {
            uint maximum = (1u << bits) - 1;
            destination[i] =
                round(clamp(destination[i], 0.0f, 1.0f) * maximum) / maximum;
        }
    }
    bool logic = u.logic_op >= 1 && u.logic_op <= 16;
    if ((u.dither || surface_channels >= NV2AMetalSurfaceStorageZ1) && !logic &&
        (u.blend & NV_PGRAPH_BLEND_EN))
        out.color = pixel_blend(out.color, destination, u);
    if (logic || u.dither) {
        for (uint i = 0; i < 4; i++) {
            uint bits = u.color_bits[i];
            if (!bits || bits > 8)
                continue;
            uint mask = (1u << bits) - 1;
            uint quantized = color_quantize(out.color[i], bits, bool(u.dither),
                                            uint2(in.position.xy));
            if (logic) {
                uint old =
                    uint(round(clamp(destination[i], 0.0f, 1.0f) * mask));
                quantized = pixel_logic(quantized, old, u.logic_op - 1) & mask;
            }
            out.color[i] = float(quantized) / mask;
        }
    }
    if (surface_channels >= NV2AMetalSurfaceStorageZ7)
        out.color.a = pixel_store_a7(out.color.a, surface_channels);
    else if (surface_channels >= NV2AMetalSurfaceStorageZ1)
        out.color.a = surface_channels == NV2AMetalSurfaceStorageO1 ||
                              surface_channels == NV2AMetalSurfaceStorageO8 ?
                          1 :
                          0;
    return out;
}
