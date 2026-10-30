/*
 * Native Metal 4 execution of glsl/vsh-prog.c and vsh.c's programmable tail
 * Copyright (c) 2012 espes
 * Copyright (c) 2014 Jannik Vogel
 * Copyright (c) 2025 Matt Borgerson
 * Based on Cxbx, VertexShader.cpp:
 * Copyright (c) 2004 Aaron Robinson and Kingofc
 * and Dxbx, uPushBuffer.pas:
 * Copyright (c) 2007 Shadow_tj and PatrickvL
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#include <metal_stdlib>
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_TYPES_H
#include "vertex-program-types.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_TYPES_H
#include "geometry-types.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_COMMON_MSL
#include "vertex-common.metal"
#endif
using namespace metal;

#pragma clang fp contract(off)

struct VPRegisters {
#ifdef NV2A_METAL_CONTEXT
    float4 constants[NV2A_METAL_VP_CONSTANTS];
    uint dirty[NV2A_METAL_VP_CONSTANTS];
    bool full_access;
#endif
    float4 temporary[12];
    float4 output[13];
    int address;
    uint fault;
};

#ifdef NV2A_METAL_CONTEXT
struct VPReadOnlyRegisters {
    bool full_access;
    float4 temporary[12];
    float4 output[13];
    int address;
    uint fault;
};

float4 vp_context_constant(constant NV2AMetalProgramUniforms &,
                           thread const VPRegisters &r, uint index)
{
    return r.constants[index];
}
float4 vp_context_constant(constant NV2AMetalProgramUniforms &u,
                           thread const VPReadOnlyRegisters &, uint index)
{
    return vp_load4(u.constants[index]);
}
#endif

template <typename Registers>
float4 vp_temporary(thread const Registers &r, uint index)
{
    return index == 12 ? r.output[0] : r.temporary[index];
}

template <typename Registers>
float4 vp_source(uint operand, constant NV2AMetalProgramInstruction &op,
                 constant NV2AMetalProgramUniforms &u,
                 device const NV2AMetalProgramInput &input, thread Registers &r,
                 bool scalar)
{
    uint source = op.source[operand];
    float4 value;
    switch (source & 3u) {
    case 1:
        value = vp_temporary(r, (source >> 2) & 15u);
        break;
    case 2:
        value = float4(input.attributes[op.attribute_index][0],
                       input.attributes[op.attribute_index][1],
                       input.attributes[op.attribute_index][2],
                       input.attributes[op.attribute_index][3]);
        break;
    default: {
        /* Use wide arithmetic so an extreme ARL cannot overflow an index. */
        long index =
            long(op.constant_index) + (op.relative ? long(r.address) : 0);
#ifdef NV2A_METAL_CONTEXT
        bool aperture = r.full_access || index >= 96 ||
                        (!op.relative && (index == 58 || index == 59));
        if (index < 0 || index >= NV2A_METAL_VP_CONSTANTS || !aperture) {
#else
        if (index < 0 || index >= NV2A_METAL_VP_CONSTANTS) {
#endif
            r.fault = NV2AMetalProgramFaultConstantRange;
            return float4(0);
        }
#ifdef NV2A_METAL_CONTEXT
        value = vp_context_constant(u, r, index);
#else
        value = vp_load4(u.constants[index]);
#endif
        break;
    }
    }
    float4 result;
    for (uint i = 0; i < 4; i++) {
        uint swizzle = (source >> (6 + 2 * (scalar ? 0 : i))) & 3u;
        result[i] = value[swizzle];
    }
    return source & (1u << 14) ? -result : result;
}

/* NV20/Kelvin RZ/FTZ arithmetic, following envytools fp32_mul and
 * xf_sum(version 2). Raw source/selection bits remain separate from arithmetic.
 * Sum alignment reserves two exponent bits and truncates seven low bits. */
static uint vp_pack_rz(uint sign, int exponent, uint mantissa)
{
    if (exponent <= 0 || mantissa == 0) {
        return sign;
    }
    if (exponent >= 255) {
        return sign | 0x7f7fffff;
    }
    return sign | ((uint)exponent << 23) | (mantissa & 0x7fffff);
}

static uint vp_multiply_rz(uint a, uint b)
{
    int ae = (a >> 23) & 255, be = (b >> 23) & 255;
    uint sign = (a ^ b) & 0x80000000;
    if (ae == 0 || be == 0) {
        return 0;
    }
    if ((ae == 255 && (a & 0x7fffff)) || (be == 255 && (b & 0x7fffff))) {
        return 0x7fffffff;
    }
    if (ae == 255 || be == 255) {
        return sign | 0x7f800000;
    }
    ulong product =
        (ulong)((a & 0x7fffff) | 0x800000) * ((b & 0x7fffff) | 0x800000);
    bool high = (product & (1ul << 47)) != 0;
    int exponent = ae + be - 127 + high;
    uint mantissa = (uint)(product >> (high ? 24 : 23));
    return vp_pack_rz(sign, exponent, mantissa);
}

static uint vp_sum_rz(thread const uint *values, unsigned count)
{
    bool positive_inf = false, negative_inf = false;
    int exponent = 0;
    for (unsigned i = 0; i < count; i++) {
        int e = (values[i] >> 23) & 255;
        if (e == 255) {
            if (values[i] & 0x7fffff) {
                return 0x7fffffff;
            }
            if (values[i] >> 31) {
                negative_inf = true;
            } else {
                positive_inf = true;
            }
        }
        if (e + 2 > exponent) {
            exponent = e + 2;
        }
    }
    if (positive_inf && negative_inf) {
        return 0x7fffffff;
    }
    if (positive_inf || negative_inf) {
        return negative_inf ? 0xff800000 : 0x7f800000;
    }
    long sum = 0;
    for (unsigned i = 0; i < count; i++) {
        int e = (values[i] >> 23) & 255;
        uint mantissa = (values[i] & 0x7fffff) | (e ? 0x800000 : 0);
        int shift = exponent - e - 7;
        uint aligned = shift >= 32 ? 0 :
                       shift >= 0  ? mantissa >> shift :
                                     mantissa << -shift;
        sum += (values[i] >> 31) ? -(long)aligned : aligned;
    }
    if (sum == 0) {
        return 0;
    }
    uint sign = sum < 0 ? 0x80000000 : 0;
    uint magnitude = (uint)(sum < 0 ? -sum : sum);
    while (magnitude < 0x40000000) {
        magnitude <<= 1;
        exponent--;
    }
    return vp_pack_rz(sign, exponent, magnitude >> 7);
}

float4 vp_mul(float4 a, float4 b)
{
    float4 result;
    for (uint i = 0; i < 4; i++) {
        result[i] = as_type<float>(
            vp_multiply_rz(as_type<uint>(a[i]), as_type<uint>(b[i])));
    }
    return result;
}

float4 vp_add(float4 a, float4 b)
{
    float4 result;
    for (uint i = 0; i < 4; i++) {
        uint values[2] = { as_type<uint>(a[i]), as_type<uint>(b[i]) };
        result[i] = as_type<float>(vp_sum_rz(values, 2));
    }
    return result;
}

float vp_dot(float4 values, uint count)
{
    uint bits[4];
    for (uint i = 0; i < 4; i++) {
        bits[i] = as_type<uint>(values[i]);
    }
    return as_type<float>(vp_sum_rz(bits, count));
}

/* Kelvin FP_ZERO_WINS ordering, including raw NaN payloads and denorms.
 * See envytools nvhw/xf.c:xf_cond and hwtest/xf.cc's NV20 flags. */
bool4 vp_less(float4 a, float4 b)
{
    uint4 abits = as_type<uint4>(a), bbits = as_type<uint4>(b);
    uint4 akey =
        select(abits ^ 0x80000000u, ~abits, (abits & 0x80000000u) != 0u);
    uint4 bkey =
        select(bbits ^ 0x80000000u, ~bbits, (bbits & 0x80000000u) != 0u);
    return akey < bkey;
}

float4 vp_mac(uint opcode, float4 a, float4 b, float4 c)
{
    switch (opcode) {
    case NV2AMetalMACMov:
        return a;
    case NV2AMetalMACMul:
        return vp_mul(a, b);
    case NV2AMetalMACAdd:
        return vp_add(a, c);
    case NV2AMetalMACMad:
        return vp_add(vp_mul(a, b), c);
    case NV2AMetalMACDp3:
        return float4(vp_dot(vp_mul(a, b), 3));
    case NV2AMetalMACDph:
        a.w = 1;
        return float4(vp_dot(vp_mul(a, b), 4));
    case NV2AMetalMACDp4:
        return float4(vp_dot(vp_mul(a, b), 4));
    case NV2AMetalMACDst:
        return float4(1, vp_mul(a, b).y, a.z, b.w);
    case NV2AMetalMACMin:
        return select(b, a, vp_less(a, b));
    case NV2AMetalMACMax:
        return select(a, b, vp_less(a, b));
    case NV2AMetalMACSlt:
        return select(float4(0), float4(1), vp_less(a, b));
    case NV2AMetalMACSge:
        return select(float4(0), float4(1), !vp_less(a, b));
    default:
        return float4(0);
    }
}

/* ILU helpers derived from envytools nvhw/xf.c, NV20 version2.
 * Its MIT notice below applies to these helpers and lookup tables. */
/*
 * Copyright (C) 2018 Marcelina Kościelnicka <mwk@0x04.net>
 * All Rights Reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

constant uchar vp_reciprocal_lut[0x40] = {
    0x7f, 0x7d, 0x7b, 0x79, 0x78, 0x76, 0x74, 0x73, 0x71, 0x6f, 0x6e,
    0x6d, 0x6b, 0x6a, 0x68, 0x67, 0x66, 0x65, 0x63, 0x62, 0x61, 0x60,
    0x5f, 0x5e, 0x5d, 0x5c, 0x5b, 0x5a, 0x59, 0x58, 0x57, 0x56, 0x55,
    0x54, 0x53, 0x52, 0x52, 0x51, 0x50, 0x4f, 0x4e, 0x4e, 0x4d, 0x4c,
    0x4c, 0x4b, 0x4a, 0x49, 0x49, 0x48, 0x48, 0x47, 0x46, 0x46, 0x45,
    0x45, 0x44, 0x43, 0x43, 0x42, 0x42, 0x41, 0x41, 0x40,
};

constant uchar vp_root_lut[0x80] = {
    0x7f, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x7a, 0x79, 0x78, 0x77, 0x77, 0x76,
    0x75, 0x74, 0x74, 0x73, 0x72, 0x71, 0x71, 0x70, 0x6f, 0x6f, 0x6e, 0x6d,
    0x6d, 0x6c, 0x6c, 0x6b, 0x6a, 0x6a, 0x69, 0x69, 0x68, 0x68, 0x67, 0x67,
    0x66, 0x66, 0x65, 0x65, 0x64, 0x64, 0x63, 0x63, 0x62, 0x62, 0x61, 0x61,
    0x61, 0x60, 0x60, 0x5f, 0x5f, 0x5e, 0x5e, 0x5e, 0x5d, 0x5d, 0x5d, 0x5c,
    0x5c, 0x5b, 0x5b, 0x5b, 0x5a, 0x59, 0x59, 0x58, 0x57, 0x57, 0x56, 0x56,
    0x55, 0x54, 0x54, 0x53, 0x53, 0x52, 0x52, 0x51, 0x51, 0x50, 0x50, 0x4f,
    0x4f, 0x4e, 0x4e, 0x4d, 0x4d, 0x4d, 0x4c, 0x4c, 0x4b, 0x4b, 0x4a, 0x4a,
    0x4a, 0x49, 0x49, 0x49, 0x48, 0x48, 0x48, 0x47, 0x47, 0x46, 0x46, 0x46,
    0x46, 0x45, 0x45, 0x45, 0x44, 0x44, 0x44, 0x43, 0x43, 0x43, 0x43, 0x42,
    0x42, 0x42, 0x41, 0x41, 0x41, 0x41, 0x40, 0x40,
};

static uint vp_rcp_bits(uint bits, bool clamped)
{
    uint sign = bits & 0x80000000u;
    unsigned inputExponent = (bits >> 23) & 255u;
    uint fraction = bits & 0x7fffffu;
    if ((bits & 0x7fffffffu) > 0x7f800000u) {
        return 0x7fffffffu;
    }
    if (inputExponent == 0 && !clamped) {
        return sign | 0x7f800000u;
    }
    int exponent = 254 - (int)inputExponent;
    uint result = 0;
    if (fraction != 0) {
        uint mantissa = fraction | 0x800000u;
        ulong estimate = vp_reciprocal_lut[(mantissa >> 17) & 63u];
        estimate = (((1ul << 31) - estimate * mantissa) * estimate) >> 24;
        estimate = (((1ul << 37) - estimate * mantissa) * estimate) >> 25;
        result = (uint)estimate - 0x800000u;
        exponent--;
    }
    if (clamped) {
        if (exponent < 63) {
            exponent = 63;
            result = 0;
        } else if (exponent >= 191) {
            exponent = 191;
            result = 0;
        }
    } else if (exponent <= 0) {
        exponent = 0;
        result = 0;
    }
    return sign | ((uint)exponent << 23) | result;
}

static uint vp_rsq_bits(uint bits)
{
    unsigned exponent = (bits >> 23) & 255u;
    uint fraction = bits & 0x7fffffu;
    if ((bits & 0x7fffffffu) > 0x7f800000u) {
        return 0x7fffffffu;
    }
    if (exponent == 0) {
        return 0x7f800000u;
    }
    if ((bits & 0x7fffffffu) == 0x7f800000u) {
        return 0;
    }
    int resultExponent;
    if (exponent & 1u) {
        resultExponent = 126 - ((int)exponent - 127) / 2;
    } else {
        resultExponent = 126 - ((int)exponent - 128) / 2;
        fraction |= 0x800000u;
    }
    ulong estimate = vp_root_lut[(fraction >> 17) & 127u];
    uint mantissa = fraction & 0x800000u ? fraction << 1 : fraction | 0x800000u;
    estimate =
        (((3ul << 37) - estimate * estimate * mantissa) * estimate) >> 32;
    estimate =
        (((3ul << 49) - estimate * estimate * mantissa) * estimate) >> 39;
    return ((uint)resultExponent << 23) | ((uint)estimate - 0x800000u);
}

constant ushort exp_lut_a[0x20] = {
    0x0000, 0x0167, 0x02d5, 0x044c, 0x05cb, 0x0752, 0x08e2, 0x0a7b,
    0x0c1c, 0x0dc7, 0x0f7b, 0x1138, 0x12ff, 0x14d1, 0x16ac, 0x1892,
    0x1a83, 0x1c7e, 0x1e84, 0x2096, 0x22b4, 0x24dd, 0x2712, 0x2954,
    0x2ba3, 0x2dfe, 0x3067, 0x32dc, 0x3561, 0x37f2, 0x3a93, 0x3d44,
};

constant ushort exp_lut_b[0x20] = {
    0x167, 0x16e, 0x177, 0x17f, 0x187, 0x190, 0x199, 0x1a1, 0x1ab, 0x1b4, 0x1bd,
    0x1c7, 0x1d2, 0x1db, 0x1e6, 0x1f1, 0x1fb, 0x206, 0x212, 0x21e, 0x229, 0x235,
    0x242, 0x24f, 0x25b, 0x269, 0x275, 0x285, 0x291, 0x2a1, 0x2b1, 0x2bb,
};

constant uint log_lut_a[0x20] = {
    0x00000, 0x02db6, 0x059bd, 0x08493, 0x0ae2d, 0x0d6a6, 0x0fe20, 0x12468,
    0x149ce, 0x16e47, 0x191df, 0x1b4a1, 0x1d696, 0x1f7c9, 0x2183f, 0x23804,
    0x2571e, 0x27592, 0x2936b, 0x2b0ab, 0x2cd5a, 0x2e97c, 0x3051a, 0x32035,
    0x33ad3, 0x354f7, 0x36ea9, 0x387e9, 0x3a0bd, 0x3b928, 0x3d12b, 0x3e8d5,
};

constant ushort log_lut_b[0x20] = {
    0x2db6, 0x2c07, 0x2ad6, 0x299a, 0x2879, 0x277a, 0x2648, 0x2566,
    0x2479, 0x2398, 0x22c2, 0x21f5, 0x2133, 0x2076, 0x1fc5, 0x1f1a,
    0x1e74, 0x1dd9, 0x1d40, 0x1caf, 0x1c22, 0x1b9e, 0x1b1b, 0x1a9e,
    0x1a24, 0x19b2, 0x1940, 0x18d4, 0x186b, 0x1803, 0x17aa, 0x172a,
};

static uint vp_shift(uint value, int shift, bool ceil)
{
    if (shift <= 0) {
        return value << -shift;
    }
    if (shift >= 32) {
        return ceil && value != 0;
    }
    uint rest = value & ((1u << shift) - 1u);
    return (value >> shift) + (ceil && rest != 0);
}

static int vp_pre_exp(uint bits)
{
    bool sign = (bits >> 31) != 0;
    int exponent = (bits >> 23) & 255u;
    if ((bits & 0x7fffffffu) > 0x7f800000u) {
        return 0x7fffffff;
    }
    if (exponent >= 145) {
        return sign ? (-0x7fffffff - 1) : 0x7fffffff;
    }
    if (exponent < 104) {
        return 0;
    }
    uint fraction = (bits & 0x7fffffu) | 0x800000u;
    fraction = vp_shift(fraction, 137 - exponent, sign);
    return sign ? -(int)fraction : (int)fraction;
}

static uint vp_exp_core(int value)
{
    int integral = value >> 13;
    if (integral <= -127) {
        return 0;
    }
    if (integral >= 128) {
        return 0x7f800000u;
    }
    uint h = ((uint)value >> 8) & 31u;
    uint l = (uint)value & 255u;
    uint fraction = exp_lut_a[h] * 256u + exp_lut_b[h] * l;
    return ((uint)(integral + 127) << 23) | (fraction << 1);
}

static uint vp_exp_floor(uint bits)
{
    return vp_exp_core(vp_pre_exp(bits) & ~0x1fff);
}

static uint vp_exp(uint bits)
{
    if ((bits & 0x7fffffffu) > 0x7f800000u) {
        return 0x7fffffffu;
    }
    return vp_exp_core(vp_pre_exp(bits));
}

static uint vp_exp_fraction(uint bits)
{
    bool sign = (bits >> 31) != 0;
    int exponent = (bits >> 23) & 255u;
    if ((bits & 0x7fffffffu) > 0x7f800000u) {
        return bits;
    }
    if (exponent == 0 || exponent >= 150) {
        return 0;
    }
    uint fraction = (bits & 0x7fffffu) | 0x800000u;
    if (!sign) {
        if (exponent < 127) {
            return bits;
        }
    } else {
        if (exponent < 104) {
            return 0x3f800000u;
        }
        if (exponent < 127) {
            fraction = vp_shift(fraction, 127 - exponent, true);
            exponent = 127;
        }
        fraction = 0u - fraction;
    }
    fraction &= (1u << (150 - exponent)) - 1u;
    if (fraction == 0) {
        return 0;
    }
    while ((fraction & 0x800000u) == 0) {
        fraction <<= 1;
        exponent--;
    }
    return ((uint)exponent << 23) | (fraction - 0x800000u);
}

static uint vp_log_e(uint bits)
{
    uint absolute = bits & 0x7fffffffu;
    int exponent = (bits >> 23) & 255u;
    if (absolute > 0x7f800000u) {
        return absolute;
    }
    if (exponent == 0) {
        return 0xff800000u;
    }
    if (exponent == 255) {
        return 0x7f800000u;
    }
    exponent -= 127;
    uint sign = exponent < 0 ? 0x80000000u : 0;
    uint fraction = exponent < 0 ? (uint)-exponent : (uint)exponent;
    if (fraction == 0) {
        return 0;
    }
    int resultExponent = 150;
    while ((fraction & 0x800000u) == 0) {
        fraction <<= 1;
        resultExponent--;
    }
    return sign | ((uint)resultExponent << 23) | (fraction - 0x800000u);
}

static uint vp_log_f(uint bits)
{
    uint absolute = bits & 0x7fffffffu;
    if (absolute > 0x7f800000u) {
        return absolute;
    }
    if ((bits & 0x7f800000u) == 0) {
        return 0x3f800000u;
    }
    return 0x3f800000u | (bits & 0x7fffffu);
}

static long vp_log_core(uint bits)
{
    int exponent = (bits >> 23) & 255u;
    uint h = (bits >> 18) & 31u;
    uint l = (bits >> 10) & 255u;
    long fraction = log_lut_a[h] * 256u + log_lut_b[h] * l;
    return fraction + (exponent - 127) * 0x4000000l;
}

static uint vp_log(uint bits)
{
    uint absolute = bits & 0x7fffffffu;
    int exponent = (bits >> 23) & 255u;
    if (absolute > 0x7f800000u) {
        return absolute;
    }
    if (exponent == 0) {
        return 0xff800000u;
    }
    if (exponent == 255) {
        return 0x7f800000u;
    }
    long value = vp_log_core(bits);
    uint sign = value < 0 ? 0x80000000u : 0;
    ulong fraction = value < 0 ? (ulong)-value : (ulong)value;
    if (fraction == 0) {
        return 0;
    }
    int resultExponent = 133;
    while ((fraction & (1ul << 32)) == 0) {
        fraction <<= 1;
        resultExponent--;
    }
    return sign | ((uint)resultExponent << 23) |
           ((uint)(fraction >> 9) - 0x800000u);
}

static uint vp_lit_y(uint x)
{
    return x & 0x80000000u ? 0 : x;
}

static uint vp_lit_z(uint x, uint y, uint w)
{
    if ((x & 0x80000000u) || (x & 0x7f800000u) == 0) {
        return 0;
    }
    if ((w & 0x7f800000u) == 0) {
        return 0x3f800000u;
    }
    if ((y & 0x7fffffffu) > 0x7f800000u || (w & 0x7fffffffu) > 0x7f800000u) {
        return 0x7fffffffu;
    }
    if ((y & 0x80000000u) || (y & 0x7f800000u) == 0) {
        return w & 0x80000000u ? 0x7f800000u : 0;
    }
    if ((y & 0x7fffffffu) == 0x7f800000u) {
        return w & 0x80000000u ? 0 : 0x7f800000u;
    }
    int power = vp_pre_exp(w);
    if (power < -0x100000) {
        power = -0x100000;
    }
    if (power > 0xfffff) {
        power = 0xfffff;
    }
    long result = (vp_log_core(y) * power) >> 26;
    if (result < (-0x7fffffffl - 1)) {
        return 0;
    }
    if (result > 0x7fffffff) {
        return 0x7f800000u;
    }
    return vp_exp_core((int)result);
}

float4 vp_ilu(uint opcode, float4 c)
{
    switch (opcode) {
    case NV2AMetalILUMov:
        return c;
    case NV2AMetalILURcp:
        return float4(as_type<float>(vp_rcp_bits(as_type<uint>(c.x), false)));
    case NV2AMetalILURcc:
        return float4(as_type<float>(vp_rcp_bits(as_type<uint>(c.x), true)));
    case NV2AMetalILURsq:
        return float4(as_type<float>(vp_rsq_bits(as_type<uint>(c.x))));
    case NV2AMetalILUExp: {
        uint bits = as_type<uint>(c.x);
        return as_type<float4>(uint4(vp_exp_floor(bits), vp_exp_fraction(bits),
                                     vp_exp(bits), 0x3f800000u));
    }
    case NV2AMetalILULog: {
        uint bits = as_type<uint>(c.x);
        return as_type<float4>(
            uint4(vp_log_e(bits), vp_log_f(bits), vp_log(bits), 0x3f800000u));
    }
    case NV2AMetalILULit: {
        uint4 bits = as_type<uint4>(c);
        return as_type<float4>(uint4(0x3f800000u, vp_lit_y(bits.x),
                                     vp_lit_z(bits.x, bits.y, bits.w),
                                     0x3f800000u));
    }
    default:
        return float4(0);
    }
}

void vp_write(thread float4 &dest, float4 value, uint mask, bool fog)
{
    uint packed = 0;
    for (uint i = 0; i < 4; i++) {
        if (mask & (8u >> i)) {
            /* Fog consumes the already-swizzled result starting at X,
             * as in OGL fog_mask_str; do not apply the output mask to
             * the source again. Only X is the hardware Fog coordinate.
             */
            uint component = fog ? packed++ : i;
            dest[component] = value[component];
        }
    }
}

template <typename Registers>
void vp_write_temporary(thread Registers &r, uint index, float4 value,
                        uint mask)
{
    if (index == 12) {
        vp_write(r.output[0], value, mask, false);
    } else {
        vp_write(r.temporary[index], value, mask, false);
    }
}

template <typename Registers>
float4 vp_mac_inputs(constant NV2AMetalProgramInstruction &op,
                     constant NV2AMetalProgramUniforms &u,
                     device const NV2AMetalProgramInput &input,
                     thread Registers &r)
{
    float4 a = vp_source(0, op, u, input, r, false), b(0), c(0);
    if (op.mac != NV2AMetalMACMov && op.mac != NV2AMetalMACAdd &&
        op.mac != NV2AMetalMACArl) {
        b = vp_source(1, op, u, input, r, false);
    }
    if (op.mac == NV2AMetalMACAdd || op.mac == NV2AMetalMACMad) {
        /* MAC retains C's vector swizzle; only ILU selects its scalar lane. */
        c = vp_source(2, op, u, input, r, false);
    }
    return vp_mac(op.mac, a, b, c);
}

#ifndef NV2A_METAL_CONTEXT
void vp_execute(constant NV2AMetalProgramInstruction *program,
                constant NV2AMetalProgramUniforms &u,
                device const NV2AMetalProgramInput &input,
                thread VPRegisters &r)
{
    for (uint slot = 0; slot < u.program_length && !r.fault; slot++) {
        constant NV2AMetalProgramInstruction &op = program[slot];
        bool paired = op.mac != NV2AMetalMACNop && op.ilu != NV2AMetalILUNop;
        uint mac_mask = paired && op.temp_register == 1 ? 0 : op.mac_mask;
        float4 mac(0), ilu(0);
        int address = r.address;
        /* All operand reads precede the instruction's output/temp writes.
         * R12 mirrors oPos, so reevaluating an operand after writing oPos
         * changes this instruction's result and violates the source snapshot. */
        if (op.mac == NV2AMetalMACArl) {
            float a = vp_source(0, op, u, input, r, false).x;
            float rounded = floor(a + 0.001f);
            if (!isfinite(rounded) || rounded < -2147483648.0f ||
                rounded >= 2147483648.0f)
                r.fault = NV2AMetalProgramFaultAddressRange;
            else
                address = int(rounded);
        } else if (op.mac != NV2AMetalMACNop) {
            mac = vp_mac_inputs(op, u, input, r);
        }
        if (op.ilu != NV2AMetalILUNop) {
            bool scalar = op.ilu >= NV2AMetalILURcp && op.ilu <= NV2AMetalILULog;
            ilu = vp_ilu(op.ilu, vp_source(2, op, u, input, r, scalar));
        }
        if (r.fault) break;
        if (op.output_mask) {
            if (op.output_mux == 0 && op.mac != NV2AMetalMACNop &&
                op.mac != NV2AMetalMACArl)
                vp_write(r.output[op.output_register], mac, op.output_mask,
                         op.output_register == 5);
            else if (op.output_mux == 1 && op.ilu != NV2AMetalILUNop)
                vp_write(r.output[op.output_register], ilu, op.output_mask,
                         op.output_register == 5);
        }
        if (op.ilu != NV2AMetalILUNop && op.ilu_mask)
            vp_write_temporary(r, paired ? 1 : op.temp_register, ilu, op.ilu_mask);
        if (op.mac == NV2AMetalMACArl)
            r.address = address;
        else if (op.mac != NV2AMetalMACNop && mac_mask)
            vp_write_temporary(r, op.temp_register, mac, mac_mask);
    }
}

kernel void
nv2a_vertex_program(device const NV2AMetalProgramInput *inputs [[buffer(0)]],
                    device NV2AMetalProgramOutput *raw [[buffer(1)]],
                    device NV2AMetalVertex *vertices [[buffer(2)]],
                    constant NV2AMetalProgramUniforms &u [[buffer(3)]],
                    constant NV2AMetalProgramInstruction *program [[buffer(4)]],
                    uint index [[thread_position_in_grid]])
{
    if (index >= u.vertex_count) {
        return;
    }
    VPRegisters r;
    r.address = 0;
    r.fault = NV2AMetalProgramFaultNone;
    for (uint i = 0; i < 12; i++) {
        r.temporary[i] = float4(0);
    }
    for (uint i = 0; i < 13; i++) {
        r.output[i] = float4(0, 0, 0, 1);
    }
    vp_execute(program, u, inputs[index], r);
    NV2AMetalProgramOutput snapshot = {};
    for (uint i = 0; i < 13; i++) {
        vp_store4(snapshot.registers[i], r.output[i]);
    }
    snapshot.fault = r.fault;
    raw[index] = snapshot;

    NV2AMetalVertex result = {};
    if (r.fault) {
        /* Poisoned vertices are never a substitute for handling the fault. */
        vertices[index] = result;
        return;
    }
    float4 position = r.output[0];
    position.xy = trunc(position.xy * 16.0f) / 16.0f;
    position.w = vp_clamp_w(position.w);
    vp_store4(result.screen, position);
    for (uint p = 0; p < 3; p++) {
        vp_store4(result.plane[p], position);
    }
    float2 size(u.surface_size[0], u.surface_size[1]);
    float2 ndc = (2.0f * position.xy - size) / size;
    vp_store4(result.clip,
              float4(ndc.x, -ndc.y, position.z / u.zmax, 1) * position.w);
    vp_store4(result.color[0], vp_color(r.output[3]));
    vp_store4(result.color[2], vp_color(r.output[7]));
    for (uint s = 0; s < 2; s++) {
        float4 specular = u.specular_enable ?
                              vp_color(r.output[s == 0 ? 4 : 8]) :
                              float4(0, 0, 0, 1);
        if (u.ignore_specular_alpha) {
            specular.w = 1;
        }
        vp_store4(result.color[1 + 2 * s], specular);
    }
    for (uint t = 0; t < 4; t++) {
        vp_store4(result.texcoord[t], r.output[9 + t]);
    }
    result.fog = vp_fog(r.output[5].x, u);
    result.point_size =
        u.point_programmed ?
            r.output[6].x :
            (u.point_size <= 0 ? 1.0f : u.point_size) * u.point_scale;
    vertices[index] = result;
}

#endif
