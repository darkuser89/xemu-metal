/*
 * Native Metal 4 port of pgraph/glsl/geom.c
 * Copyright (c) 2015 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#include <metal_stdlib>
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_TYPES_H
#include "geometry-types.h"
#endif
using namespace metal;
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_POLYGON_COVERAGE_MSL
#include "polygon-coverage.metal"
#endif

#pragma clang fp contract(off)
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_MATH_MSL
#include "geometry-math.metal"
#endif

float4 geometry_load4(const thread float *v)
{
    return float4(v[0], v[1], v[2], v[3]);
}

void geometry_store4(thread float *v, float4 value)
{
    for (uint i = 0; i < 4; i++) {
        v[i] = value[i];
    }
}

void geometry_emit(device NV2AMetalVertex *output, uint offset,
                   thread NV2AMetalVertex *v, uint index, uint provoking,
                   bool smooth, float4x4 plane)
{
    NV2AMetalVertex result = v[index];
    if (!smooth) {
        for (uint c = 0; c < 4; c++) {
            for (uint k = 0; k < 4; k++) {
                result.color[c][k] = v[provoking].color[c][k];
            }
        }
    }
    for (uint p = 0; p < 3; p++) {
        geometry_store4(result.plane[p], plane[p]);
    }
    result.slope = isfinite(plane[3].x) ? plane[3].x : 0.0f;
    output[offset] = result;
}

void geometry_line(device NV2AMetalVertex *output, uint offset,
                   thread NV2AMetalVertex *v, uint i0, uint i1, uint provoking,
                   bool smooth, float slope,
                   constant NV2AMetalGeometryUniforms &u)
{
    float4 p0 = geometry_load4(v[i0].screen);
    float4 p1 = geometry_load4(v[i1].screen);
    float2 delta = p1.xy - p0.xy;
    float4 p2 = float4(float2(-delta.y, delta.x) + p0.xy, p0.zw);
    if (u.line_width <= 1 && !u.line_smooth && !u.z_perspective) {
        float4x4 plane(p0, p1, p2, float4(slope, 0, 0, 0));
        geometry_emit(output, offset, v, i0, provoking, smooth, plane);
        geometry_emit(output, offset + 1, v, i1, provoking, smooth, plane);
        return;
    }
    float4 a = geometry_load4(v[i0].clip), b = geometry_load4(v[i1].clip);
    float enter = 0, leave = 1;
    bool valid = all(isfinite(a)) && all(isfinite(b));
    if (valid) {
        // Positive homogeneous rescaling preserves the clipped projective
        // segment and keeps a short visible interval from rounding to t=1.
        int shift_a, shift_b;
        frexp(max(abs(a.w), max(abs(a.x), abs(a.y))), shift_a);
        frexp(max(abs(b.w), max(abs(b.x), abs(b.y))), shift_b);
        a.xyw = ldexp(a.xyw, -shift_a);
        b.xyw = ldexp(b.xyw, -shift_b);
    }
    /* Depth clamp leaves Z to the fragment stage. Clip the centreline in XY/W
     * before expanding its width, as with the original line primitive. */
    float4 fa(a.w + a.x, a.w - a.x, a.w + a.y, a.w - a.y);
    float4 fb(b.w + b.x, b.w - b.x, b.w + b.y, b.w - b.y);
    uint enter_planes = 0, leave_planes = 0;
    for (uint k = 0; k < 4; k++) {
        if (fa[k] < 0 && fb[k] < 0)
            valid = false;
        else if (fa[k] < 0) {
            float t = fa[k] / (fa[k] - fb[k]);
            if (t > enter) {
                enter = t;
                enter_planes = 1u << k;
            } else if (t == enter) {
                enter_planes |= 1u << k;
            }
        } else if (fb[k] < 0) {
            float t = fa[k] / (fa[k] - fb[k]);
            if (t < leave) {
                leave = t;
                leave_planes = 1u << k;
            } else if (t == leave) {
                leave_planes |= 1u << k;
            }
        }
    }
    float4 ca = mix(a, b, enter), cb = mix(a, b, leave);
    // Keep generated endpoints exactly on their intersected clip planes.
    for (uint k = 0; k < 4; k++) {
        if (enter_planes & (1u << k))
            ca[k / 2] = k & 1 ? ca.w : -ca.w;
        if (leave_planes & (1u << k))
            cb[k / 2] = k & 1 ? cb.w : -cb.w;
    }
    valid &= enter <= leave && ca.w > 0 && cb.w > 0;
    float2 viewport(u.viewport[0], u.viewport[1]);
    float2 pa = float2(ca.x / ca.w + 1, 1 - ca.y / ca.w) * viewport * .5f;
    float2 pb = float2(cb.x / cb.w + 1, 1 - cb.y / cb.w) * viewport * .5f;
    valid &= all(isfinite(pa)) && all(isfinite(pb)) && any(pa != pb);
    float padding = u.line_width * .5f + 2;
    float2 lo = max(min(pa, pb) - padding, float2(0));
    float2 hi = min(max(pa, pb) + padding, viewport);
    valid &= all(hi > lo);
    if (!valid) {
        NV2AMetalVertex clipped = {};
        geometry_store4(clipped.clip, float4(2, 2, 2, 1));
        for (uint i = 0; i < 6; i++)
            output[offset + i] = clipped;
        return;
    }
    float2 corners[4] = { lo, float2(lo.x, hi.y), float2(hi.x, lo.y), hi };
    /* Every smooth covered square lies within half a line width plus its
     * half-diagonal. Aliased wide lines translate the diamond along the minor
     * axis by at most (rounded_width-1)/2. This bounds both its tangent and
     * normal displacement. Three extra pixels also retain the neighbouring
     * helper quad; fragment interpolation/derivatives stay unchanged.
     * Keep the clipped AABB when it is smaller than this conservative band. */
    float2 segment = pb - pa;
    float length = metal::length(segment);
    float margin = u.line_width * .5f + 3;
    if ((length + 2 * margin) * (2 * margin) < (hi.x - lo.x) * (hi.y - lo.y)) {
        float2 along = segment / length * margin;
        float2 across(-along.y, along.x);
        corners[0] = pa - along - across;
        corners[1] = pa - along + across;
        corners[2] = pb + along - across;
        corners[3] = pb + along + across;
    }
    const uint order[6] = { 0, 1, 2, 2, 1, 3 };
    float4x4 plane(p0, p1, float4(pa, pb), float4(slope, 0, 0, 0));
    for (uint i = 0; i < 6; i++) {
        uint corner = order[i];
        geometry_emit(output, offset + i, v, corner < 2 ? i0 : i1, provoking,
                      smooth, plane);
        NV2AMetalVertex result = output[offset + i];
        float2 ndc = corners[corner] / viewport * 2 - 1;
        geometry_store4(result.clip, float4(ndc.x, -ndc.y, .5f, 1));
        result.line_raster[0] = u.line_width;
        result.line_raster[1] = u.line_smooth;
        result.line_raster[2] = 1;
        output[offset + i] = result;
    }
}

/* A filled triangle becomes two transport triangles; original attributes at
 * 0/2/5 remain available for area-integrated fragment interpolation. */
static void geometry_polygon(device NV2AMetalVertex *output, uint offset,
                             thread NV2AMetalVertex *v, uint3 indices,
                             uint provoking, float4x4 plane,
                             constant NV2AMetalGeometryUniforms &u,
                             device NV2AMetalPolygonProjection *projections)
{
    float4 clips[3];
    for (uint i = 0; i < 3; i++)
        clips[i] = geometry_load4(v[indices[i]].clip);
    float2 points[8], viewport(u.viewport[0], u.viewport[1]);
    uint count = polygon_project(clips, viewport, points);
    float area = geometry_area(clips[0], clips[1], clips[2]);
    bool front = v[indices[0]].face == NV2AMetalFaceFront;
    bool valid = count && area != 0 &&
                 (!u.face_mask || (u.face_mask & (front ? 1u : 2u)));
    projections[offset / 6].count = valid ? count : 0;
    for (uint i = 0; i < count; i++) {
        projections[offset / 6].points[i][0] = points[i].x;
        projections[offset / 6].points[i][1] = points[i].y;
    }
    float2 lo = viewport, hi = 0;
    for (uint i = 0; i < count; i++) {
        lo = min(lo, points[i]);
        hi = max(hi, points[i]);
    }
    // Padding ensures Metal's centre sampling covers every intersected square.
    lo = max(lo - 1, float2(0));
    hi = min(hi + 1, viewport);
    float2 corners[4] = { lo, float2(hi.x, lo.y), float2(lo.x, hi.y), hi };
    /* A long diagonal polygon need not shade the empty corners of its AABB.
     * Bound its projected vertices along the longest edge and its normal.
     * Scaling the largest axis component to one keeps the inverse basis's
     * determinant in [1,2], without a square root or a tiny divisor. Three
     * pixels of L-infinity padding retain intersected squares and neighbouring
     * helper quads, with headroom for Float32 reconstruction at <=16K
     * viewports. Use this carrier only when its full area is below the clipped
     * AABB's; original clip/plane/attribute records and fragment integration
     * stay put. */
    float2 edge = 0;
    float longest = 0;
    if (valid) {
        for (uint i = 0; i < count; i++) {
            float2 delta = points[(i + 1) % count] - points[i];
            float squared = dot(delta, delta);
            if (isfinite(squared) && squared > longest) {
                edge = delta;
                longest = squared;
            }
        }
    }
    if (longest > 0) {
        float2 axis = edge / max(abs(edge.x), abs(edge.y));
        float2 normal(-axis.y, axis.x), origin = points[0];
        float2 lower = INFINITY, upper = -INFINITY;
        bool finite = true;
        for (uint i = 0; i < count; i++) {
            float2 relative = points[i] - origin;
            float2 p(dot(relative, axis), dot(relative, normal));
            finite &= all(isfinite(p));
            lower = min(lower, p);
            upper = max(upper, p);
        }
        float padding = 3 * (abs(axis.x) + abs(axis.y));
        lower -= padding;
        upper += padding;
        float inverse = 1 / dot(axis, axis);
        float2 extent = upper - lower;
        if (finite && all(isfinite(lower)) && all(isfinite(upper)) &&
            extent.x * extent.y * inverse < (hi.x - lo.x) * (hi.y - lo.y)) {
            corners[0] = origin + (axis * lower.x + normal * lower.y) * inverse;
            corners[1] = origin + (axis * upper.x + normal * lower.y) * inverse;
            corners[2] = origin + (axis * lower.x + normal * upper.y) * inverse;
            corners[3] = origin + (axis * upper.x + normal * upper.y) * inverse;
        }
    }
    const uint order[6] = { 0, 1, 2, 2, 1, 3 };
    const uint source[6] = { 0, 0, 1, 1, 0, 2 };
    for (uint i = 0; i < 6; i++) {
        if (!valid) {
            NV2AMetalVertex clipped = {};
            geometry_store4(clipped.clip, float4(2, 2, 2, 1));
            output[offset + i] = clipped;
            continue;
        }
        uint index = source[i];
        geometry_emit(output, offset + i, v, indices[index], provoking,
                      u.smooth, plane);
        NV2AMetalVertex result = output[offset + i];
        float2 ndc = corners[order[i]] / viewport * 2 - 1;
        geometry_store4(result.clip, float4(ndc.x, -ndc.y, .5f, 1));
        result.coverage_clip[0] = clips[index].x;
        result.coverage_clip[1] = clips[index].y;
        result.line_raster[0] = clips[index].w;
        result.line_raster[1] = viewport.x;
        result.line_raster[2] = 2;
        result.point_size = viewport.y;
        output[offset + i] = result;
    }
}

static float4 geometry_device_clip(device const NV2AMetalVertex &v)
{
    return float4(v.clip[0], v.clip[1], v.clip[2], v.clip[3]);
}
kernel void nv2a_polygon_face(device const NV2AMetalVertex *input [[buffer(0)]],
                              device uint *face [[buffer(1)]],
                              constant NV2AMetalGeometryUniforms &u
                              [[buffer(2)]],
                              uint id [[thread_position_in_grid]])
{
    if (id != 0)
        return;
    face[0] = 0;
    if (u.input_count < 3)
        return;
    float4 a = geometry_device_clip(input[0]);
    for (uint i = 1; i + 1 < u.input_count; i++) {
        float area = geometry_area(a, geometry_device_clip(input[i]),
                                   geometry_device_clip(input[i + 1]));
        if (area != 0) {
            face[0] = u.front_clockwise ? area < 0 : area > 0;
            return;
        }
    }
}

kernel void nv2a_expand_geometry(device const NV2AMetalVertex *input
                                 [[buffer(0)]],
                                 device NV2AMetalVertex *output [[buffer(1)]],
                                 constant NV2AMetalGeometryUniforms &u
                                 [[buffer(2)]],
                                 device const uint *polygon_face [[buffer(3)]],
                                 device NV2AMetalPolygonProjection *projections
                                 [[buffer(4)]],
                                 uint primitive_id [[thread_position_in_grid]])
{
    if (primitive_id >= u.primitive_count) {
        return;
    }
    uint4 indices;
    bool line = false, quad = false;
    uint provoking = 0;
    switch (u.primitive) {
    case NV2AMetalPrimitivePoints:
        indices = uint4(primitive_id);
        break;
    case NV2AMetalPrimitiveLines:
        indices = uint4(2 * primitive_id, 2 * primitive_id + 1, 0, 0);
        line = true;
        provoking = u.first_provoking ? 0 : 1;
        break;
    case NV2AMetalPrimitiveLineLoop:
    case NV2AMetalPrimitiveLineStrip:
        indices = uint4(primitive_id, (primitive_id + 1) % u.input_count, 0, 0);
        line = true;
        provoking = u.first_provoking ? 0 : 1;
        break;
    case NV2AMetalPrimitiveTriangles:
        indices = uint4(3 * primitive_id, 3 * primitive_id + 1,
                        3 * primitive_id + 2, 0);
        provoking = u.first_provoking ? 0 : 2;
        break;
    case NV2AMetalPrimitiveTriangleStrip:
        indices = uint4(primitive_id, primitive_id + 1 + (primitive_id & 1),
                        primitive_id + 2 - (primitive_id & 1), 0);
        provoking = u.first_provoking ? 0 : 2 - (primitive_id & 1);
        break;
    case NV2AMetalPrimitiveTriangleFan:
        indices = uint4(0, primitive_id + 1, primitive_id + 2, 0);
        provoking = u.first_provoking ? 0 : 1;
        break;
    case NV2AMetalPrimitiveQuads:
        indices = uint4(4 * primitive_id) + uint4(0, 1, 2, 3);
        provoking = 3;
        quad = true;
        break;
    case NV2AMetalPrimitiveQuadStrip:
        indices = uint4(2 * primitive_id) + uint4(0, 1, 2, 3);
        provoking = 3;
        quad = true;
        break;
    default: /* Polygon. The host validates the mode. */
        if (u.polygon == NV2AMetalPolygonLine) {
            indices =
                uint4(primitive_id, (primitive_id + 1) % u.input_count, 0, 0);
            line = true;
            /* Preserve GL's documented polygon-line limitation: edge-first
             * provoking vertex and no polygon depth slope. */
            provoking = 0;
        } else {
            indices = uint4(0, primitive_id + 1, primitive_id + 2, 0);
            provoking = 2;
        }
        break;
    }
    uint count = quad ? 4 : (line ? 2 : 3);
    if (u.primitive == NV2AMetalPrimitivePoints) {
        count = 1;
    }
    NV2AMetalVertex v[4];
    for (uint i = 0; i < count; i++) {
        v[i] = input[indices[i]];
    }
    uint offset = primitive_id * u.output_per_primitive;
    bool polygon = u.primitive >= NV2AMetalPrimitiveTriangles;
    if (polygon && u.polygon == NV2AMetalPolygonFill && u.polygon_smooth) {
        projections[offset / 6].count = 0;
        if (quad)
            projections[offset / 6 + 1].count = 0;
    }
    bool front = true;
    if (polygon) {
        if (u.primitive == NV2AMetalPrimitivePolygon) {
            /* One face for the whole polygon boundary, including wireframe. */
            front = polygon_face[0] != 0;
        } else {
            float area = geometry_area(geometry_load4(v[0].clip),
                                       geometry_load4(v[1].clip),
                                       geometry_load4(v[2].clip));
            front = u.front_clockwise ? area < 0 : area > 0;
        }
    }
    if (polygon && u.face_mask && !(u.face_mask & (front ? 1u : 2u))) {
        NV2AMetalVertex clipped = {};
        geometry_store4(clipped.clip, float4(2, 2, 2, 1));
        for (uint i = 0; i < u.output_per_primitive; i++)
            output[offset + i] = clipped;
        return;
    }
    for (uint i = 0; i < count; i++)
        v[i].face = front ? NV2AMetalFaceFront : NV2AMetalFaceBack;
    if (count == 1) {
        float4 p = geometry_load4(v[0].screen);
        geometry_emit(output, offset, v, 0, 0, true,
                      float4x4(p, p, p, float4(0)));
        return;
    }
    if (line) {
        geometry_line(output, offset, v, 0, 1, provoking, u.smooth, 0, u);
        return;
    }
    float4 p[4];
    for (uint i = 0; i < count; i++) {
        p[i] = geometry_load4(v[i].screen);
    }
    bool strip = u.primitive == NV2AMetalPrimitiveQuadStrip;
    float4x4 plane = quad && strip ?
                         geometry_plane(p[2], p[0], p[1], u.z_perspective) :
                         geometry_plane(p[0], p[1], p[2], u.z_perspective);
    float4x4 plane2 =
        quad ? (strip ? geometry_plane(p[2], p[1], p[3], u.z_perspective) :
                        geometry_plane(p[0], p[2], p[3], u.z_perspective)) :
               plane;
    if (u.polygon == NV2AMetalPolygonLine) {
        const uint4 edges =
            quad ? (strip ? uint4(0, 1, 3, 2) : uint4(0, 1, 2, 3)) :
                   uint4(0, 1, 2, 0);
        for (uint e = 0; e < count; e++) {
            float slope = quad && (strip ? e == 1 || e == 2 : e >= 2) ?
                              plane2[3].x :
                              plane[3].x;
            uint per =
                u.line_width > 1 || u.line_smooth || u.z_perspective ? 6 : 2;
            geometry_line(output, offset + per * e, v, edges[e],
                          edges[(e + 1) % count], provoking, u.smooth, slope,
                          u);
        }
    } else if (u.polygon == NV2AMetalPolygonPoint) {
        for (uint i = 0; i < count; i++) {
            float4x4 base = quad && i == 3 ? plane2 : plane;
            geometry_emit(output, offset + i, v, i, provoking, u.smooth,
                          float4x4(p[i], p[i], p[i], base[3]));
        }
    } else if (u.polygon_smooth) {
        const uint3 first = quad && !strip ? uint3(1, 2, 0) : uint3(0, 1, 2);
        geometry_polygon(output, offset, v, first, provoking, plane, u,
                         projections);
        if (quad) {
            const uint3 second = strip ? uint3(2, 1, 3) : uint3(2, 3, 0);
            geometry_polygon(output, offset + 6, v, second, provoking, plane2,
                             u, projections);
        }
    } else if (quad) {
        const uint3 first = strip ? uint3(0, 1, 2) : uint3(1, 2, 0);
        const uint3 second = strip ? uint3(2, 1, 3) : uint3(2, 3, 0);
        for (uint i = 0; i < 3; i++) {
            geometry_emit(output, offset + i, v, first[i], provoking, u.smooth,
                          plane);
            geometry_emit(output, offset + 3 + i, v, second[i], provoking,
                          u.smooth, plane2);
        }
    } else {
        for (uint i = 0; i < 3; i++) {
            geometry_emit(output, offset + i, v, i, provoking, u.smooth, plane);
        }
    }
}
