/* Pixel equations from the VGA helpers used by the old GL fallback.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VGA_TYPES_H
#include "vga-types.h"
#endif
#include <metal_stdlib>
using namespace metal;
kernel void nv2a_vga_graphics(device const uchar *data [[buffer(0)]],
                              device const NV2AMetalVGARow *rows [[buffer(1)]],
                              constant NV2AMetalVGAUniforms &u [[buffer(2)]],
                              texture2d<float, access::write> output
                              [[texture(0)]],
                              uint2 p [[thread_position_in_grid]])
{
    if (p.x >= u.width || p.y >= u.height)
        return;
    NV2AMetalVGARow row = rows[p.y];
    uint x = p.x;
    uint3 rgb;
    if (u.mode == 1) {
        uint cell = p.x / u.character_width, dx = p.x % u.character_width;
        uint address = row.address + cell * 4;
        uint ch = data[address], attribute = data[address + 1];
        uint fg = u.palette[attribute & 15], bg = u.palette[attribute >> 4];
        bool cursor = u.cursor_visible && address == u.cursor_address &&
                      row.hpel >= u.cursor_start && row.hpel <= u.cursor_end;
        uint glyph =
            data[u.font_offset[(attribute >> 3) & 1] + ch * 128 + row.hpel * 4];
        bool ink;
        if (u.character_width == 16)
            ink = (glyph >> (7 - dx / 2)) & 1;
        else if (dx < 8)
            ink = (glyph >> (7 - dx)) & 1;
        else
            ink = u.line_graphics && ch >= 0xb0 && ch <= 0xdf && (glyph & 1);
        uint color = cursor || ink ? fg : bg;
        output.write(float4(float(color & 255) / 255.f,
                            float((color >> 8) & 255) / 255.f,
                            float((color >> 16) & 255) / 255.f, 1),
                     p);
        return;
    }
    if (u.mode == 255) {
        output.write(float4(0, 0, 0, 1), p);
        return;
    }
    if (u.mode == 2 || u.mode == 4) {
        x = x / (u.duplicate ? 2 : 1) + row.hpel;
        uint addr = (row.address + x / 8 * 4) & 0x3ffffu;
        uint index = 0;
        if (u.mode == 4)
            for (uint plane = 0; plane < 4; plane++) {
                uint v = (u.plane_mask & (1u << plane)) ?
                             data[((addr & ~3u) + plane) & u.memory_mask] :
                             0;
                index |= ((v >> (7 - x % 8)) & 1) << plane;
            }
        else {
            uint plane = (x % 8) / 4, shift = 6 - 2 * (x % 4);
            uint a = (u.plane_mask & (1u << plane)) ?
                         data[((addr & ~3u) + plane) & u.memory_mask] :
                         0;
            uint b = (u.plane_mask & (1u << (plane + 2))) ?
                         data[((addr & ~3u) + plane + 2) & u.memory_mask] :
                         0;
            index = ((a >> shift) & 3) | (((b >> shift) & 3) << 2);
        }
        uint color = u.palette[index];
        rgb = uint3(color & 255, (color >> 8) & 255, (color >> 16) & 255);
    } else if (u.mode == 0 || u.mode == 8) {
        x = (u.mode == 0 ? x / 2 : x) + row.hpel;
        uint addr = u.mode == 0 ?
                        (((row.address + x / 4 * 4) & 0x3ffffu) + x % 4) :
                        row.address + x;
        uint color = u.palette[data[addr & u.memory_mask]];
        rgb = uint3(color & 255, (color >> 8) & 255, (color >> 16) & 255);
    } else if (u.mode == 15 || u.mode == 16) {
        uint addr = (row.address + x * 2) & u.memory_mask & ~1u;
        uint a = data[addr], b = data[(addr + 1) & u.memory_mask];
        uint v = u.big_endian ? (a << 8) | b : a | (b << 8);
        rgb = u.mode == 15 ?
                  uint3((v >> 7) & 248, (v >> 2) & 248, (v << 3) & 248) :
                  uint3((v >> 8) & 248, (v >> 3) & 252, (v << 3) & 248);
    } else {
        uint stride = u.mode == 24 ? 3 : 4, addr = row.address + x * stride;
        uint r, g, b;
        if (u.big_endian) {
            uint skip = stride == 4 ? 1 : 0;
            r = data[(addr + skip) & u.memory_mask];
            g = data[(addr + skip + 1) & u.memory_mask];
            b = data[(addr + skip + 2) & u.memory_mask];
        } else {
            b = data[addr & u.memory_mask];
            g = data[(addr + 1) & u.memory_mask];
            r = data[(addr + 2) & u.memory_mask];
        }
        rgb = uint3(r, g, b);
    }
    output.write(float4(float3(rgb) / 255.f, 1), p);
}
