/*
 * Shared native NV2A vertex operations, based on glsl/vsh.c
 * Copyright (c) 2015 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_COMMON_MSL
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_COMMON_MSL
#include <metal_stdlib>
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_TYPES_H
#include "vertex-program-types.h"
#endif
using namespace metal;
#pragma clang fp contract(off)

float4 vp_load4(constant float *v)
{
    return float4(v[0], v[1], v[2], v[3]);
}

void vp_store4(thread float *v, float4 value)
{
    for (uint i = 0; i < 4; i++) {
        v[i] = value[i];
    }
}

float vp_clamp_w(float t)
{
    if (t > 0.0f || as_type<uint>(t) == 0u) {
        return clamp(t, as_type<float>(0x1f800000u),
                     as_type<float>(0x5f800000u));
    }
    return clamp(t, as_type<float>(0xdf800000u), as_type<float>(0x9f800000u));
}

float4 vp_color(float4 value)
{
    return clamp(select(value, float4(1), isnan(value)), 0.0f, 1.0f);
}

float vp_fog(float distance, constant NV2AMetalProgramUniforms &u,
             uint enabled, uint mode)
{
    if (!enabled) {
        return 1.0f;
    }
    bool one = mode == 0 || mode == 1 || mode == 4;
    if (isinf(distance)) {
        return one ? 1.0f : 0.0f;
    }
    float factor;
    if (mode == 0 || mode == 4) {
        factor = u.fog[0] + distance * u.fog[1] - 1.0f;
    } else if (mode == 1 || mode == 5) {
        factor = u.fog[0] + exp2(distance * u.fog[1] * 16.0f) - 1.5f;
    } else {
        factor = u.fog[0] +
                 exp2(-distance * distance * u.fog[1] * u.fog[1] * 32.0f) -
                 1.5f;
    }
    if (mode >= 4) {
        factor = abs(factor);
    }
    if (isnan(factor)) {
        factor = one ? 1.0f : 0.0f;
    }
    float maximum = as_type<float>(0x7f7fffffu);
    return clamp(factor, -maximum, maximum);
}

float vp_fog(float distance, constant NV2AMetalProgramUniforms &u)
{
    return vp_fog(distance, u, u.fog_enable, u.fog_mode);
}

#endif
