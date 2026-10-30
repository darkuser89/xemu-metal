/* Raw versioned backend captures, not NV2A hardware definitions.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_VERTEX_CAPTURE_H
#define TEST_METAL_VERTEX_CAPTURE_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
static void append(NSMutableData *wire, const void *data, size_t length)
{
    for (size_t i = 0; i < length; i += 4) {
        uint32_t word;
        memcpy(&word, (const uint8_t *)data + i, 4);
        uint8_t bytes[] = { word >> 24, word >> 16, word >> 8, word };
        [wire appendBytes:bytes length:4];
    }
}
static NSData *capture(unsigned version, unsigned programmed, unsigned seed)
{
    NV2AMetalFixedUniforms fixed = { 0 };
    NV2AMetalProgramUniforms *u = &fixed.common;
    for (unsigned i = 0; i < 192 * 4; i++) {
        uint32_t bits = 0x3f000000u + i * 157u + seed;
        memcpy((uint8_t *)u->constants + i * 4, &bits, 4);
    }
    u->surface_size[0] = 8;
    u->surface_size[1] = 16;
    u->zmax = 65535;
    u->point_size = 2;
    u->point_scale = 3;
    u->fog_enable = seed & 1;
    u->fog_mode = 4;
    u->fog[0] = .5f;
    u->fog[1] = .25f;
    u->specular_enable = (seed >> 1) & 1;
    u->ignore_specular_alpha = (seed >> 2) & 1;
    fixed.material_alpha = .75f;
    fixed.specular_params[2] = 1;
    if (version >= 4) {
        fixed.material_alpha_back = .5f;
        fixed.specular_params_back[2] = 1;
        fixed.two_side = seed & 1;
    }
    size_t size =
        programmed   ? sizeof(*u) :
        version == 1 ? offsetof(NV2AMetalFixedUniforms, specular_params) :
        version < 4  ? offsetof(NV2AMetalFixedUniforms, specular_params_back) :
                       sizeof(fixed);
    uint32_t header[] = { 0x4d345643,
                          version,
                          programmed | ((seed & 3) << 2) |
                              (version == 5 ? ((seed >> 6) << 4) : 0),
                          seed * 3,
                          seed * 5,
                          seed * 7,
                          (uint32_t)size / 4,
                          programmed };
    NV2AMetalProgramInput input = { 0 };
    for (unsigned i = 0; i < 16; i++)
        for (unsigned k = 0; k < 4; k++)
            input.attributes[i][k] = (float)(i * 4 + k);
    uint32_t token[] = { 0, (1u << 21) | 27, 2u << 26,
                         (1u << 11) | (15u << 12) | 1 };
    NSMutableData *wire = [NSMutableData new];
    append(wire, header, sizeof(header));
    append(wire, &input, sizeof(input));
    append(wire, &fixed, size);
    if (programmed)
        append(wire, token, sizeof(token));
    return wire;
}

#endif
