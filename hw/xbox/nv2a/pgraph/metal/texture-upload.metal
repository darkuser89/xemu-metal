/*
 * Native NV2A texture decode, based on pgraph/{texture,swizzle,s3tc}.c,
 * gl/constants.h and pgraph/util.h.
 * Copyright (c) 2012-2013 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * Copyright (c) 2007-2010 The Nouveau Project
 * SPDX-License-Identifier: LGPL-2.0-or-later AND MIT
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_UPLOAD_TYPES_H
#include "texture-upload-types.h"
#endif
#ifndef NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8
#include "../../nv2a_regs.h"
#endif
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

static uint texture_u16(device const uchar *p)
{
    return uint(p[0]) | uint(p[1]) << 8;
}

static uint texture_u32(device const uchar *p)
{
    return texture_u16(p) | texture_u16(p + 2) << 16;
}

static uint texture_morton(uint3 coordinate, uint3 size)
{
    uint address = 0, out_bit = 1;
    for (uint bit = 1; bit < max(size.x, max(size.y, size.z)); bit <<= 1) {
        for (uint axis = 0; axis < 3; axis++) {
            if (bit < size[axis]) {
                if (coordinate[axis] & bit) {
                    address |= out_bit;
                }
                out_bit <<= 1;
            }
        }
    }
    return address;
}

/*
 * S3TC Texture Decompression
 *
 * Copyright (c) 2020 Wilhelm Kovatch
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */


static uint3 texture_rgb565(uint c)
{
    return uint3(((c >> 11) & 31) * 255 / 31, ((c >> 5) & 63) * 255 / 63,
                 (c & 31) * 255 / 31);
}

/* Integer endpoint/interpolant truncation matches the existing software S3TC
 * decoder, including volume blocks grouped in up to four depth slices. */
static float4 texture_bc(device const uchar *source, uint3 c,
                         constant NV2AMetalTextureDecodeUniforms &u)
{
    uint blocks_x = (u.source_width + 3) / 4;
    uint blocks_y = (u.source_height + 3) / 4;
    uint chunk = c.z / 4;
    uint chunk_depth = min(4u, u.source_depth - chunk * 4);
    uint block = chunk * 4 * blocks_x * blocks_y +
                 (c.y / 4 * blocks_x + c.x / 4) * chunk_depth + c.z % 4;
    device const uchar *p = source + block * u.block_size;
    device const uchar *colors = p + (u.block_size == 8 ? 0 : 8);
    uint c0 = texture_u16(colors), c1 = texture_u16(colors + 2);
    uint pixel = (c.y % 4) * 4 + c.x % 4;
    uint index = (texture_u32(colors + 4) >> (2 * pixel)) & 3;
    uint3 a = texture_rgb565(c0), b = texture_rgb565(c1), rgb;
    uint alpha = 255;
    bool transparent = u.block_size == 8 && c0 <= c1;
    if (index < 2) {
        rgb = index ? b : a;
    } else if (transparent) {
        rgb = index == 2 ? (a + b) / 2 : uint3(0);
        alpha = index == 3 ? 0 : 255;
    } else {
        rgb = index == 2 ? (2 * a + b) / 3 : (a + 2 * b) / 3;
    }
    if (u.format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8) {
        alpha = ((p[pixel / 2] >> (4 * (pixel % 2))) & 15) * 17;
    } else if (u.format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8) {
        ulong bits = 0;
        for (uint i = 0; i < 6; i++) {
            bits |= ulong(p[2 + i]) << (8 * i);
        }
        uint ai = uint(bits >> (3 * pixel)) & 7;
        uint a0 = p[0], a1 = p[1];
        if (ai < 2) {
            alpha = ai ? a1 : a0;
        } else if (a0 > a1) {
            alpha = ((8 - ai) * a0 + (ai - 1) * a1) / 7;
        } else if (ai < 6) {
            alpha = ((6 - ai) * a0 + (ai - 1) * a1) / 5;
        } else {
            alpha = ai == 6 ? 0 : 255;
        }
    }
    return float4(float3(rgb), float(alpha)) / 255.0f;
}

static int3 texture_r6g5b5(uint v)
{
    v ^= (1u << 9) | (1u << 4);
    return int3(int((v >> 10) & 63) * 127 / 63,
                int((v >> 5) & 31) * 255 / 31 - 128,
                int(v & 31) * 255 / 31 - 128);
}
static float4 texture_decode(device const uchar *p, device const uchar *palette,
                             constant NV2AMetalTextureDecodeUniforms &u,
                             device atomic_uint &faults)
{
    uint v = u.bytes_per_pixel == 4 ? texture_u32(p) :
             u.bytes_per_pixel == 2 ? texture_u16(p) :
                                      uint(p[0]);
    switch (u.format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8:
        return float4(float3(v / 255.0f), 1);
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8:
        return float4(v / 255.0f);
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8:
        return float4(1, 1, 1, v / 255.0f);
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8:
        return float4(float3((v & 255) / 255.0f), (v >> 8) / 255.0f);
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8:
        return float4(v & 255, v >> 8, v & 255, v >> 8) / 255.0f;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8:
        return float4(v >> 8, v & 255, v & 255, v >> 8) / 255.0f;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5: {
        bool x = u.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5 ||
                 u.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5;
        return float4(((v >> 10) & 31) / 31.0f, ((v >> 5) & 31) / 31.0f,
                      (v & 31) / 31.0f, x ? 1.0f : float(v >> 15));
    }
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4:
        return float4((v >> 8) & 15, (v >> 4) & 15, v & 15, v >> 12) / 15.0f;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5:
        return float4(((v >> 11) & 31) / 31.0f, ((v >> 5) & 63) / 63.0f,
                      (v & 31) / 31.0f, 1);
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8:
        if (v >= u.palette_entries) {
            atomic_fetch_or_explicit(&faults, 1u, memory_order_relaxed);
            return float4(0);
        }
        v = texture_u32(palette + 4 * v);
        return float4((v >> 16) & 255, (v >> 8) & 255, v & 255, v >> 24) /
               255.0f;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8: {
        bool x = u.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8 ||
                 u.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8;
        return float4((v >> 16) & 255, (v >> 8) & 255, v & 255,
                      x ? 255u : v >> 24) /
               255.0f;
    }
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8:
        return float4(v & 255, (v >> 8) & 255, (v >> 16) & 255, v >> 24) /
               255.0f;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8:
        return float4((v >> 8) & 255, (v >> 16) & 255, v >> 24, v & 255) /
               255.0f;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8:
        return float4(v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255) /
               255.0f;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5: {
        int3 q = texture_r6g5b5(v);
        return float4(max(float3(q) / 127.0f, float3(-1)), 1);
    }
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16:
        /* Xbox Y16 samples keep R/A at one and replicate Y to G/B. */
        return float4(1, v / 65535.0f, v / 65535.0f, 1);
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16: {
        // HILO16 keeps both unsigned words through filtering. The Xbox
        // R16B16 captures suggest HI in R, LO in G/B, and opaque alpha;
        // asymmetric-word hardware parity of that color mapping is pending.
        float hi = texture_u16(p + 2) / 65535.0f;
        float lo = texture_u16(p) / 65535.0f;
        if (u.signed_channels == 15) {
            // Family model: all signed flags select signed16 HILO words.
            // NV_texture_shader uses signed16/32768 before filtering.
            int h = int(texture_u16(p + 2)), l = int(texture_u16(p));
            hi = float(h - (h >= 32768 ? 65536 : 0)) / 32768.0f;
            lo = float(l - (l >= 32768 ? 65536 : 0)) / 32768.0f;
        }
        return float4(hi, lo, lo, 1);
    }
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_DEPTH_Y16_FIXED:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FIXED:
        return float4(v / 65535.0f, 0, 0, 0);
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FIXED:
        return float4((v >> 8) / 16777215.0f, 1, 0, 0);
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FLOAT:
        // NV2A F24 has the Float32 exponent and sixteen fraction bits.
        // Keep physical depth: normalization would underflow small values.
        return float4(as_type<float>((v >> 8) << 7), 1, 1, 0);
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FLOAT: {
        // NV2A F16 is positive with twelve fraction bits, not IEEE half.
        // Retain raw exponent-zero clear words; only Draw flushes those.
        float d = v ? as_type<float>((v << 11) + 0x3c000000u) : 0.0f;
        return float4(d / 511.9375f, 0, 1, 0);
    }
    default:
        return float4(0);
    }
}

kernel void nv2a_texture_decode(uint3 id [[thread_position_in_grid]],
                                device const uchar *source [[buffer(0)]],
                                device const uchar *palette [[buffer(1)]],
                                constant NV2AMetalTextureDecodeUniforms &u
                                [[buffer(2)]],
                                device uchar *output [[buffer(3)]],
                                device atomic_uint &faults [[buffer(4)]])
{
    if (any(id >= uint3(u.width, u.height, u.depth))) {
        return;
    }
    uint3 coordinate = id + uint3(u.crop, u.crop, 0);
    uint index = id.z * u.output_slice + id.y * u.output_row + id.x;
    float4 color;
    if (u.block_size) {
        color = texture_bc(source, coordinate, u);
    } else if (u.format ==
                   NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8 ||
               u.format ==
                   NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_YB8CR8YA8CB8) {
        device const uchar *p =
            source + coordinate.y * u.source_pitch + (coordinate.x & ~1u) * 2;
        bool yuy =
            u.format == NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8;
        int y = p[(coordinate.x % 2) * 2 + (yuy ? 0 : 1)] - 16;
        int cb = p[yuy ? 1 : 0] - 128, cr = p[yuy ? 3 : 2] - 128;
        int3 rgb =
            int3(298 * y + 409 * cr + 128, 298 * y - 100 * cb - 208 * cr + 128,
                 298 * y + 516 * cb + 128) >>
            8;
        color = float4(float3(clamp(rgb, int3(0), int3(255))) / 255.0f, 1);
    } else {
        uint address = u.linear ?
                           coordinate.y * u.source_pitch +
                               coordinate.x * u.bytes_per_pixel :
                           texture_morton(coordinate,
                                          uint3(u.source_width, u.source_height,
                                                u.source_depth)) *
                               u.bytes_per_pixel;
        if (u.output_storage == NV2AMetalTextureStorageSnorm8 &&
            u.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5 &&
            !u.signed_channels) {
            ((device char4 *)output)[index] =
                char4(char3(texture_r6g5b5(texture_u16(source + address))),
                      char(127));
            return;
        }
        bool packed =
            (u.output_storage == NV2AMetalTextureStoragePackedR565 &&
             (u.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5 ||
              u.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5)) ||
            (u.output_storage == NV2AMetalTextureStoragePackedA1555 &&
             (u.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5 ||
              u.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5)) ||
            (u.output_storage == NV2AMetalTextureStoragePackedX1555 &&
             (u.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5 ||
              u.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5)) ||
            (u.output_storage == NV2AMetalTextureStoragePackedA4444 &&
             (u.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4 ||
              u.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4));
        if (packed && !u.signed_channels) {
            ((device ushort *)output)[index] =
                ushort(texture_u16(source + address));
            return;
        }
        color = texture_decode(source + address, palette, u, faults);
    }
    if (u.signed_channels &&
        u.format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16 &&
        u.format != NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16) {
        // NV_texture_shader separates signed8 texture precision from the
        // signed9 combiner range. Convert each texel before filtering.
        int4 raw = int4(round(color * 255.0f));
        for (uint k = 0; k < 4; k++) {
            if (u.signed_channels & (1u << k)) {
                int value = raw[k] >= 128 ? raw[k] - 256 : raw[k];
                color[k] = float(value) / 128.0f;
            }
        }
    }
    if (u.output_storage == NV2AMetalTextureStoragePackedR565) {
        uint3 raw = uint3(round(color.rgb * float3(31, 63, 31)));
        ((device ushort *)output)[index] =
            ushort(raw.r << 11 | raw.g << 5 | raw.b);
    } else if (u.output_storage == NV2AMetalTextureStoragePackedA1555 ||
               u.output_storage == NV2AMetalTextureStoragePackedX1555) {
        uint3 raw = uint3(round(color.rgb * 31.0f));
        ((device ushort *)output)[index] = ushort(
            uint(round(color.a)) << 15 | raw.r << 10 | raw.g << 5 | raw.b);
    } else if (u.output_storage == NV2AMetalTextureStoragePackedA4444) {
        uint4 raw = uint4(round(color * 15.0f));
        ((device ushort *)output)[index] =
            ushort(raw.a << 12 | raw.r << 8 | raw.g << 4 | raw.b);
    } else if (u.output_storage == NV2AMetalTextureStorageHalf4) {
        if (u.signed_channels != 15) {
            for (uint k = 0; k < 4; k++) {
                if (!(u.signed_channels & (1u << k)))
                    color[k] = round(color[k] * 255.0f) / 256.0f;
            }
        }
        ((device half4 *)output)[index] = half4(color);
    } else if (u.output_storage == NV2AMetalTextureStorageUnorm8) {
        ((device uchar4 *)output)[index] = uchar4(round(color * 255.0f));
    } else if (u.output_storage == NV2AMetalTextureStorageSnorm8) {
        ((device char4 *)output)[index] =
            char4(round(clamp(color, -1.0f, 1.0f) * 127.0f));
    } else if (u.output_storage == NV2AMetalTextureStorageFloatY16) {
        ((device float *)output)[index] = color.g;
    } else if (u.output_storage == NV2AMetalTextureStorageFloatHILO16) {
        ((device float2 *)output)[index] = color.rg;
    } else if (u.output_storage >= NV2AMetalTextureStorageFloatDepthY16 &&
               u.output_storage <= NV2AMetalTextureStorageFloatDepth16Float) {
        ((device float *)output)[index] = color.r;
    } else {
        ((device float4 *)output)[index] = color;
    }
}
