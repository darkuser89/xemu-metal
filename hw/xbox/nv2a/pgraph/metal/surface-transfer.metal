/*
 * Native surface byte transfers from gl/surface.c and swizzle.c
 * Copyright (c) 2012-2013 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2007-2010 The Nouveau Project
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_TRANSFER_TYPES_H
#include "surface-transfer-types.h"
#endif
#include <metal_stdlib>
using namespace metal;

static uint surface_morton(uint2 p, uint width, uint height)
{
    uint result = 0, destination = 0;
    for (uint bit = 1; bit < max(width, height); bit <<= 1) {
        if (bit < width) {
            result |= uint((p.x & bit) != 0) << destination++;
        }
        if (bit < height) {
            result |= uint((p.y & bit) != 0) << destination++;
        }
    }
    return result;
}

/* A float multiply can round the fixed-depth code to a half-integer before
 * rounding. Use the exact IEEE significand product for both storage widths. */
static uint surface_depth_word(float depth, uint maximum, uint minimum_exponent)
{
    if (!(depth > 0)) {
        return 0;
    }
    if (depth >= 1) {
        return maximum;
    }
    uint bits = as_type<uint>(depth);
    uint exponent = (bits >> 23) & 255;
    if (exponent < minimum_exponent) {
        return 0;
    }
    uint shift = 150 - exponent;
    ulong significand = (bits & 0x7fffffu) | 0x800000u;
    ulong product = significand * maximum;
    return uint((product + (1ul << (shift - 1))) >> shift);
}

kernel void nv2a_surface_upload(device const uchar *source [[buffer(0)]],
                                device uchar *destination [[buffer(1)]],
                                constant NV2AMetalSurfaceTransferUniforms &u
                                [[buffer(2)]],
                                uint2 p [[thread_position_in_grid]])
{
    if (p.x >= u.width || p.y >= u.height) {
        return;
    }
    uint2 original = p / u.scale;
    uint src =
        u.swizzle ?
            surface_morton(original, u.width / u.scale, u.height / u.scale) *
                u.bytes_per_pixel :
            original.y * u.source_pitch + original.x * u.bytes_per_pixel;
    uint dst = p.y * u.destination_pitch + p.x * u.native_bytes_per_pixel;
    if (u.half_depth) {
        ushort word = ushort(source[src]) | ushort(source[src + 1]) << 8;
        // NV2A F16 codes are ordered unsigned values, not IEEE half bits.
        // Store their order in native depth, preserving every raw clear code.
        *reinterpret_cast<device float *>(destination + dst) =
            float(word) / 65535.0f;
        return;
    }
    if (u.packed_zeta) {
        uint word = uint(source[src]) | uint(source[src + 1]) << 8 |
                    uint(source[src + 2]) << 16 | uint(source[src + 3]) << 24;
        device float *depth =
            reinterpret_cast<device float *>(destination + dst);
        *depth = float(word >> 8) / 16777215.0f;
        destination[u.stencil_offset + p.y * u.stencil_pitch + p.x] =
            uchar(word);
        return;
    }
    for (uint b = 0; b < u.bytes_per_pixel; b++) {
        destination[dst + b] = source[src + b];
    }
}

kernel void nv2a_surface_download(device const uchar *source [[buffer(0)]],
                                  device uchar *destination [[buffer(1)]],
                                  constant NV2AMetalSurfaceTransferUniforms &u
                                  [[buffer(2)]],
                                  uint2 p [[thread_position_in_grid]])
{
    if (p.x >= u.width || p.y >= u.height) {
        return;
    }
    uint y = u.flip ? u.height * u.scale - 1 - p.y * u.scale : p.y * u.scale;
    uint src = y * u.source_pitch + p.x * u.scale * u.native_bytes_per_pixel;
    uint dst = u.swizzle ?
                   surface_morton(p, u.width, u.height) * u.bytes_per_pixel :
                   p.y * u.destination_pitch + p.x * u.bytes_per_pixel;
    if (u.half_depth) {
        float d = *reinterpret_cast<device const float *>(source + src);
        d = isnan(d) || d < 0 ? 0 : d > 1 ? 1 : d;
        ushort word = ushort(surface_depth_word(d, 65535, 110));
        destination[dst] = uchar(word);
        destination[dst + 1] = uchar(word >> 8);
        return;
    }
    if (u.packed_zeta) {
        device const float *depth =
            reinterpret_cast<device const float *>(source + src);
        uint value = surface_depth_word(*depth, 16777215, 102);
        uint word =
            value << 8 |
            source[u.stencil_offset + y * u.stencil_pitch + p.x * u.scale];
        for (uint b = 0; b < 4; b++) {
            destination[dst + b] = uchar(word >> (8 * b));
        }
        return;
    }
    for (uint b = 0; b < u.bytes_per_pixel; b++) {
        destination[dst + b] = source[src + b];
    }
}

/* Byte UNORM color formats have an exact integer round trip. Read only the
 * selected physical texel instead of staging the whole scaled image. Packed
 * color and depth/stencil keep their raw-buffer transfer above. */
kernel void nv2a_surface_download_color(
    texture2d<float, access::read> source [[texture(0)]],
    device uchar *destination [[buffer(1)]],
    constant NV2AMetalSurfaceTransferUniforms &u [[buffer(2)]],
    uint2 p [[thread_position_in_grid]])
{
    if (p.x >= u.width || p.y >= u.height)
        return;
    uint y = u.flip ? u.height * u.scale - 1 - p.y * u.scale : p.y * u.scale;
    float4 color = source.read(uint2(p.x * u.scale, y));
    if (u.bytes_per_pixel == 4)
        color = color.bgra;
    uchar4 bytes = uchar4(round(color * 255.0f));
    uint dst = u.swizzle ?
                   surface_morton(p, u.width, u.height) * u.bytes_per_pixel :
                   p.y * u.destination_pitch + p.x * u.bytes_per_pixel;
    for (uint b = 0; b < u.bytes_per_pixel; b++)
        destination[dst + b] = bytes[b];
}
