/* Shared Metal4 GPU fetch and host immediate-command decoding. */
#ifndef HW_XBOX_NV2A_METAL_VERTEX_NORMALIZE_H
#define HW_XBOX_NV2A_METAL_VERTEX_NORMALIZE_H

/* Kelvin IDX normalization derived from envytools nvhw/pgraph_idx.c.
 * MIT notice below applies to these helpers. */
/*
 * Copyright (C) 2017 Marcelina Kościelnicka <mwk@0x04.net>
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

static inline unsigned nv2a_metal_ubyte_bits(unsigned value)
{
    if (value == 0) {
        return 0;
    }
    if (value == 255) {
        return 0x3f800000u;
    }
    unsigned fraction = value * 0x010101u;
    unsigned exponent = 126;
    while ((fraction & 0x800000u) == 0) {
        fraction <<= 1;
        exponent--;
    }
    return (exponent << 23) | (fraction & 0x7fffffu);
}

static inline unsigned nv2a_metal_nshort_bits(int value)
{
    if (value == -32768) {
        return 0xbf800000u;
    }
    if (value == 32767) {
        return 0x3f800000u;
    }
    int scaled = value * 2 + 1;
    unsigned fraction = (unsigned)(scaled < 0 ? -scaled : scaled) * 0x10001u;
    unsigned exponent = 118;
    while (fraction >= 0x1000000u) {
        fraction >>= 1;
        exponent++;
    }
    while ((fraction & 0x800000u) == 0) {
        fraction <<= 1;
        exponent--;
    }
    return (value < 0 ? 0x80000000u : 0) | (exponent << 23) |
           (fraction & 0x7fffffu);
}

#endif
