/* Native byte blits from gl/blit.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_BLIT_TYPES_H
#include "blit-types.h"
#endif
#ifndef NV09F_SET_OPERATION_SRCCOPY
#include "../../nv2a_regs.h"
#endif
#include <metal_stdlib>
using namespace metal;

static uint row_bytes(constant NV2AMetalBlitUniforms &u, uint y)
{
    return y < u.rows ? u.row_bytes : u.tail_bytes;
}
static uchar blended(uchar source, uchar destination, uint beta)
{
    return uchar((uint(source) * beta + uint(destination) * (0x7f80u - beta)) /
                 0x7f80u);
}
kernel void nv2a_blit_parallel(device const uchar *source [[buffer(0)]],
                               device uchar *destination [[buffer(1)]],
                               constant NV2AMetalBlitUniforms &u [[buffer(2)]],
                               uint2 p [[thread_position_in_grid]])
{
    uint n = row_bytes(u, p.y);
    uint x = p.x;
    if (u.operation == NV09F_SET_OPERATION_BLEND_AND) {
        if (x >= n / u.bytes_per_pixel * 3)
            return;
        x = x / 3 * 4 + x % 3;
        uint s = u.source_offset + p.y * u.source_pitch + x;
        uint d = u.destination_offset + p.y * u.destination_pitch + x;
        destination[d] = blended(source[s], destination[d], u.beta);
    } else {
        if (x >= n)
            return;
        destination[u.destination_offset + p.y * u.destination_pitch + x] =
            source[u.source_offset + p.y * u.source_pitch + x];
    }
}
kernel void nv2a_blit_serial(device volatile uchar *source [[buffer(0)]],
                             device volatile uchar *destination [[buffer(1)]],
                             constant NV2AMetalBlitUniforms &u [[buffer(2)]],
                             uint lane [[thread_index_in_threadgroup]],
                             uint3 group [[threads_per_threadgroup]])
{
    uint rows = u.rows + (u.tail_bytes != 0);
    if (u.operation == NV09F_SET_OPERATION_BLEND_AND) {
        if (lane != 0)
            return;
        /* Aliased byte blending observes prior channel/pixel/row stores, just
         * as the GL loop does. Other lanes must not race those accesses. */
        for (uint y = 0; y < rows; y++) {
            uint n = row_bytes(u, y) / u.bytes_per_pixel;
            for (uint x = 0; x < n; x++) {
                for (uint ch = 0; ch < 3; ch++) {
                    uint s = u.source_offset + y * u.source_pitch + x * 4 + ch;
                    uint d = u.destination_offset + y * u.destination_pitch +
                             x * 4 + ch;
                    destination[d] = blended(source[s], destination[d], u.beta);
                }
            }
        }
        return;
    }
    threadgroup uchar scratch[1024];
    for (uint y = 0; y < rows; y++) {
        uint n = row_bytes(u, y);
        ulong s = u.source_address + ulong(y) * u.source_pitch;
        ulong d = u.destination_address + ulong(y) * u.destination_pitch;
        bool reverse = d > s && d - s < n;
        for (uint done = 0; done < n;) {
            uint count = min(1024u, n - done);
            uint start = reverse ? n - done - count : done;
            for (uint i = lane; i < count; i += group.x)
                scratch[i] =
                    source[u.source_offset + y * u.source_pitch + start + i];
            threadgroup_barrier(mem_flags::mem_device |
                                mem_flags::mem_threadgroup);
            for (uint i = lane; i < count; i += group.x)
                destination[u.destination_offset + y * u.destination_pitch +
                            start + i] = scratch[i];
            threadgroup_barrier(mem_flags::mem_device |
                                mem_flags::mem_threadgroup);
            done += count;
        }
    }
}
kernel void nv2a_blit_alpha(device const uchar *source [[buffer(0)]],
                            device uchar *destination [[buffer(1)]],
                            constant NV2AMetalBlitUniforms &u [[buffer(2)]],
                            uint2 p [[thread_position_in_grid]])
{
    (void)source;
    if (p.x < row_bytes(u, p.y) / 4)
        destination[u.destination_offset + p.y * u.destination_pitch + p.x * 4 +
                    3] = uchar(u.alpha_value);
}
