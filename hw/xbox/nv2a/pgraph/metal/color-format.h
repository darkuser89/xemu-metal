/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_COLOR_FORMAT_H
#define HW_XBOX_NV2A_PGRAPH_METAL_COLOR_FORMAT_H
#import <Metal/Metal.h>
#include <string.h>

static inline void nv2a_metal_color_bits(MTLPixelFormat format,
                                         unsigned int bits[4])
{
    memset(bits, 0, 4 * sizeof(*bits));
    switch (format) {
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatBGRA8Unorm:
        for (unsigned i = 0; i < 4; i++)
            bits[i] = 8;
        break;
    case MTLPixelFormatR8Unorm:
        bits[0] = 8;
        break;
    case MTLPixelFormatRG8Unorm:
        bits[0] = bits[1] = 8;
        break;
    case MTLPixelFormatB5G6R5Unorm:
        bits[0] = bits[2] = 5;
        bits[1] = 6;
        break;
    case MTLPixelFormatBGR5A1Unorm:
        bits[0] = bits[1] = bits[2] = 5;
        bits[3] = 1;
        break;
    default:
        break;
    }
}
#endif
