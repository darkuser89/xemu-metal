/*
 * Native attribute decoding from gl/vertex.c, glsl/vsh.c and pgraph/vertex.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2024 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FETCH_TYPES_H
#include "vertex-fetch-types.h"
#endif
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

/* Byte loads avoid alignment requirements for interleaved and DMA data. */
static uint fetch_u16(device const uchar *p)
{
    return uint(p[0]) | (uint(p[1]) << 8);
}

static uint fetch_u32(device const uchar *p)
{
    return fetch_u16(p) | (fetch_u16(p + 2) << 16);
}

static float4 fetch_attribute(device const uchar *p,
                              constant NV2AMetalFetchAttribute &a,
                              bool current)
{
    float4 value(0, 0, 0, 1);
    if (a.format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP) {
        uint packed = fetch_u32(p);
        int x = int(packed & 0x7ff) - int((packed & 0x400) << 1);
        int y = int((packed >> 11) & 0x7ff) - int((packed & 0x200000) >> 10);
        int z = int(packed >> 22) - int((packed & 0x80000000) >> 21);
        value = float4(float(x) / 1023.0f, float(y) / 1023.0f,
                       float(z) / 511.0f, 1);
        if (current || !a.stride) {
            value = max(value, float4(-1));
        }
        return value;
    }
    for (uint k = 0; k < a.count; k++) {
        switch (a.format) {
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D:
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL:
            value[k] = as_type<float>(nv2a_metal_ubyte_bits(p[k]));
            break;
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1:
            value[k] = as_type<float>(nv2a_metal_nshort_bits(
                as_type<short>(ushort(fetch_u16(p + 2 * k)))));
            break;
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K:
            value[k] = float(as_type<short>(ushort(fetch_u16(p + 2 * k))));
            break;
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F:
            value[k] = as_type<float>(fetch_u32(p + 4 * k));
            break;
        }
    }
    if (a.format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D &&
        a.stride && !current) {
        value = value.bgra;
    }
    return value;
}

kernel void nv2a_vertex_fetch(
    device const uchar *s0 [[buffer(0)]], device const uchar *s1 [[buffer(1)]],
    device const uchar *s2 [[buffer(2)]], device const uchar *s3 [[buffer(3)]],
    device const uchar *s4 [[buffer(4)]], device const uchar *s5 [[buffer(5)]],
    device const uchar *s6 [[buffer(6)]], device const uchar *s7 [[buffer(7)]],
    device const uchar *s8 [[buffer(8)]], device const uchar *s9 [[buffer(9)]],
    device const uchar *s10 [[buffer(10)]],
    device const uchar *s11 [[buffer(11)]],
    device const uchar *s12 [[buffer(12)]],
    device const uchar *s13 [[buffer(13)]],
    device const uchar *s14 [[buffer(14)]],
    device const uchar *s15 [[buffer(15)]],
    device NV2AMetalProgramInput *output [[buffer(16)]],
    device uint *faults [[buffer(17)]],
    constant NV2AMetalFetchUniforms &u [[buffer(18)]],
    device const uchar *indices [[buffer(19)]],
    device atomic_uint *summary [[buffer(20)]],
    uint id [[thread_position_in_grid]])
{
    uint decoded = u.vertex_count - u.first_decoded_vertex;
    bool separate_current = u.current_vertex < u.first_decoded_vertex;
    if (id >= decoded + uint(separate_current)) {
        return;
    }
    uint ordinal = id < decoded ? u.first_decoded_vertex + id : u.current_vertex;
    device const uchar *sources[16] = { s0, s1, s2,  s3,  s4,  s5,  s6,  s7,
                                        s8, s9, s10, s11, s12, s13, s14, s15 };
    uint index = u.index_size == 2 ? fetch_u16(indices + 2ul * ordinal) :
                 u.index_size == 4 ? fetch_u32(indices + 4ul * ordinal) :
                                     ordinal;
    bool overflow = index > UINT_MAX - u.first_vertex;
    index += u.first_vertex;
    uint fault = overflow ? UINT_MAX : 0;
    for (uint i = 0; i < 16; i++) {
        constant NV2AMetalFetchAttribute &a = u.attributes[i];
        float4 value(a.inline_value[0], a.inline_value[1], a.inline_value[2],
                     a.inline_value[3]);
        if (a.count && !overflow) {
            if (a.stride && index > a.max_index) {
                fault |= 1u << i;
                value = float4(0, 0, 0, 1);
            } else {
                value = fetch_attribute(
                    sources[i] + ulong(index) * a.stride, a, false);
            }
        }
        if (id < decoded)
            for (uint k = 0; k < 4; k++)
                output[id].attributes[i][k] = value[k];
        if (ordinal == u.current_vertex) {
            /* Current conversion differs from array conversion for D3D
             * colors and CMP endpoints. Never copy the array result blindly. */
            if (a.count && !(fault & (1u << i))) {
                value = fetch_attribute(sources[i] + ulong(index) * a.stride,
                                        a, true);
            }
            for (uint k = 0; k < 4; k++) {
                output[decoded].attributes[i][k] = value[k];
            }
        }
    }
    if (id < decoded)
        faults[id] = fault;
    if (fault)
        atomic_fetch_or_explicit(summary, fault, memory_order_relaxed);
    if (ordinal == u.current_vertex)
        faults[decoded] = fault;
}
