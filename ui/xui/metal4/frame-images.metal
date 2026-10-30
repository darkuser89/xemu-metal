/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <metal_stdlib>
using namespace metal;
kernel void xemu_capture_rgb(texture2d<float, access::read> source
                             [[texture(0)]],
                             device uchar *rgb [[buffer(0)]],
                             uint2 p [[thread_position_in_grid]])
{
    if (p.x >= source.get_width() || p.y >= source.get_height())
        return;
    uint offset = (p.y * source.get_width() + p.x) * 3;
    uint3 color = uint3(round(clamp(source.read(p).rgb, 0.f, 1.f) * 255.f));
    rgb[offset] = uchar(color.r);
    rgb[offset + 1] = uchar(color.g);
    rgb[offset + 2] = uchar(color.b);
}
