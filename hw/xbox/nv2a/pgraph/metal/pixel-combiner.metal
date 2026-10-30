/*
 * Native NV2A register combiners, from glsl/psh.c
 * Copyright (c) 2013 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
 * Based on Cxbx PixelShader.cpp (Aaron Robinson, Kingofc, 2004) and
 * Xeon XBD3DPixelShader.cpp (_SF_, 2003).
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_MSL
#define HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_MSL

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_TYPES_H
#include "pixel-combiner-types.h"
#endif
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

#ifndef NV2A_COMBINER_CONTROL
#define NV2A_COMBINER_CONTROL(u) ((u).control)
#endif
#ifndef NV2A_COMBINER_SHADER_STAGE_PROGRAM
#define NV2A_COMBINER_SHADER_STAGE_PROGRAM(u) ((u).shader_stage_program)
#endif
#ifndef NV2A_COMBINER_FINAL_INPUTS
#define NV2A_COMBINER_FINAL_INPUTS(u, i) ((u).final_inputs[i])
#endif
#ifndef NV2A_COMBINER_RGB_INPUTS
#define NV2A_COMBINER_RGB_INPUTS(u, i) ((u).rgb_inputs[i])
#endif
#ifndef NV2A_COMBINER_RGB_OUTPUTS
#define NV2A_COMBINER_RGB_OUTPUTS(u, i) ((u).rgb_outputs[i])
#endif
#ifndef NV2A_COMBINER_ALPHA_INPUTS
#define NV2A_COMBINER_ALPHA_INPUTS(u, i) ((u).alpha_inputs[i])
#endif
#ifndef NV2A_COMBINER_ALPHA_OUTPUTS
#define NV2A_COMBINER_ALPHA_OUTPUTS(u, i) ((u).alpha_outputs[i])
#endif

static float4 combiner_load(constant const float *v)
{
    return float4(v[0], v[1], v[2], v[3]);
}

static float4 combiner_load_device(device const float *v)
{
    return float4(v[0], v[1], v[2], v[3]);
}

static float4 combiner_map(float4 v, uint mapping)
{
    switch (mapping) {
    case PS_INPUTMAPPING_UNSIGNED_IDENTITY:
        return max(v, 0.0f);
    case PS_INPUTMAPPING_UNSIGNED_INVERT:
        return 1.0f - clamp(v, 0.0f, 1.0f);
    case PS_INPUTMAPPING_EXPAND_NORMAL:
        return 2.0f * max(v, 0.0f) - 1.0f;
    case PS_INPUTMAPPING_EXPAND_NEGATE:
        return -2.0f * max(v, 0.0f) + 1.0f;
    case PS_INPUTMAPPING_HALFBIAS_NORMAL:
        return max(v, 0.0f) - 0.5f;
    case PS_INPUTMAPPING_HALFBIAS_NEGATE:
        return -max(v, 0.0f) + 0.5f;
    case PS_INPUTMAPPING_SIGNED_IDENTITY:
        return v;
    default:
        return -v;
    }
}

static float4 combiner_read(uint input, bool alpha, uint stage,
                            constant NV2AMetalCombinerState &u,
                            thread const float4 *registers, float3 ef)
{
    uint reg = input & 15;
    float4 v;
    if (reg == PS_REGISTER_C0 || reg == PS_REGISTER_C1) {
        uint flags = NV2A_COMBINER_CONTROL(u) >> 8;
        uint unique = reg == PS_REGISTER_C0 ? PS_COMBINERCOUNT_UNIQUE_C0 :
                                              PS_COMBINERCOUNT_UNIQUE_C1;
        uint s = stage == 8 || (flags & unique) ? stage : 0;
        v = combiner_load(u.constants[2 * s + reg - 1]);
    } else if (reg == PS_REGISTER_V1R0_SUM) {
        uint flags = NV2A_COMBINER_FINAL_INPUTS(u, 1) & 255;
        float3 v1 = registers[PS_REGISTER_V1].rgb;
        float3 r0 = registers[PS_REGISTER_R0].rgb;
        if (flags & PS_FINALCOMBINERSETTING_COMPLEMENT_V1) {
            v1 = 1.0f - v1;
        }
        if (flags & PS_FINALCOMBINERSETTING_COMPLEMENT_R0) {
            r0 = 1.0f - r0;
        }
        v = float4(v1 + r0, 0);
        if (flags & PS_FINALCOMBINERSETTING_CLAMP_SUM) {
            v = clamp(v, 0.0f, 1.0f);
        }
    } else if (reg == PS_REGISTER_EF_PROD) {
        v = float4(ef, 0);
    } else {
        v = registers[reg];
    }
    if (input & PS_CHANNEL_ALPHA) {
        v = float4(v.a);
    } else if (alpha) {
        v = float4(v.b);
    }
    return combiner_map(v, input & 0xe0);
}

static float4 combiner_output_map(float4 value, uint flags)
{
    /* Xbox output bias is code 128 in the combiner's 255-step range.
     * CombinerOps/ShiftClamping captures distinguish it from exact 0.5. */
    constexpr float bias = 128.0f / 255.0f;
    switch (flags & 0x38) {
    case PS_COMBINEROUTPUT_BIAS:
        return value - bias;
    case PS_COMBINEROUTPUT_SHIFTLEFT_1:
        return value * 2.0f;
    case PS_COMBINEROUTPUT_SHIFTLEFT_1_BIAS:
        return (value - bias) * 2.0f;
    case PS_COMBINEROUTPUT_SHIFTLEFT_2:
        return value * 4.0f;
    case PS_COMBINEROUTPUT_SHIFTRIGHT_1:
        return value / 2.0f;
    default:
        return value;
    }
}

struct CombinerValues {
    float4 ab, cd, sum;
};

static CombinerValues combiner_stage(uint inputs, uint output, bool alpha,
                                     uint stage,
                                     constant NV2AMetalCombinerState &u,
                                     thread const float4 *registers)
{
    float4 a =
        combiner_read(inputs >> 24, alpha, stage, u, registers, float3(0));
    float4 b =
        combiner_read(inputs >> 16, alpha, stage, u, registers, float3(0));
    float4 c =
        combiner_read(inputs >> 8, alpha, stage, u, registers, float3(0));
    float4 d = combiner_read(inputs, alpha, stage, u, registers, float3(0));
    uint flags = output >> 12;
    float4 ab = !alpha && (flags & PS_COMBINEROUTPUT_AB_DOT_PRODUCT) ?
                    float4(dot(a.rgb, b.rgb)) :
                    a * b;
    float4 cd = !alpha && (flags & PS_COMBINEROUTPUT_CD_DOT_PRODUCT) ?
                    float4(dot(c.rgb, d.rgb)) :
                    c * d;
    float4 sum;
    if (flags & PS_COMBINEROUTPUT_AB_CD_MUX) {
        float r0a = registers[PS_REGISTER_R0].a;
        bool choose_cd =
            (NV2A_COMBINER_CONTROL(u) >> 8) & PS_COMBINERCOUNT_MUX_MSB ?
                r0a >= 0.5f :
                (uint(r0a * 255.0f) & 1u) == 1u;
        sum = choose_cd ? cd : ab;
    } else {
        sum = ab + cd;
    }
    return { clamp(combiner_output_map(ab, flags), -1.0f, 1.0f),
             clamp(combiner_output_map(cd, flags), -1.0f, 1.0f),
             clamp(combiner_output_map(sum, flags), -1.0f, 1.0f) };
}

static void combiner_write(uint output, bool alpha, CombinerValues values,
                           thread float4 *registers)
{
    uint ab = (output >> 4) & 15, cd = output & 15, sum = (output >> 8) & 15;
    uint flags = output >> 12;
    if (alpha) {
        if (ab) {
            registers[ab].a = values.ab.x;
        }
        if (cd) {
            registers[cd].a = values.cd.x;
        }
        if (sum) {
            registers[sum].a = values.sum.x;
        }
    } else {
        if (ab) {
            registers[ab].rgb = values.ab.rgb;
            if (flags & PS_COMBINEROUTPUT_AB_BLUE_TO_ALPHA) {
                registers[ab].a = values.ab.b;
            }
        }
        if (cd) {
            registers[cd].rgb = values.cd.rgb;
            if (flags & PS_COMBINEROUTPUT_CD_BLUE_TO_ALPHA) {
                registers[cd].a = values.cd.b;
            }
        }
        if (sum) {
            registers[sum].rgb = values.sum.rgb;
        }
    }
}

/* Shared core for the compute harness and fragment pipeline. Texture sampling,
 * clipping/depth and alpha-test remain outside the register-combiner stage. */
static float4 nv2a_combiner(constant NV2AMetalCombinerState &u,
                            thread float4 *registers)
{
    registers[PS_REGISTER_R0] = float4(
        0, 0, 0,
        (NV2A_COMBINER_SHADER_STAGE_PROGRAM(u) & 31) != PS_TEXTUREMODES_NONE ?
            registers[PS_REGISTER_T0].a :
            1.0f);
    registers[PS_REGISTER_R1] = float4(0);
#ifdef NV2A_METAL_FRAGMENT_SPECIALIZATION
#pragma unroll
#endif
    for (uint i = 0; i < (NV2A_COMBINER_CONTROL(u) & 255); i++) {
        CombinerValues rgb = combiner_stage(NV2A_COMBINER_RGB_INPUTS(u, i),
                                            NV2A_COMBINER_RGB_OUTPUTS(u, i),
                                            false, i, u, registers);
        CombinerValues alpha = combiner_stage(NV2A_COMBINER_ALPHA_INPUTS(u, i),
                                              NV2A_COMBINER_ALPHA_OUTPUTS(u, i),
                                              true, i, u, registers);
        combiner_write(NV2A_COMBINER_RGB_OUTPUTS(u, i), false, rgb, registers);
        combiner_write(NV2A_COMBINER_ALPHA_OUTPUTS(u, i), true, alpha,
                       registers);
    }
    uint first = NV2A_COMBINER_FINAL_INPUTS(u, 0),
         second = NV2A_COMBINER_FINAL_INPUTS(u, 1);
    float3 e =
        combiner_read(second >> 24, false, 8, u, registers, float3(0)).rgb;
    float3 f =
        combiner_read(second >> 16, false, 8, u, registers, float3(0)).rgb;
    float3 ef = e * f;
    float3 a = combiner_read(first >> 24, false, 8, u, registers, ef).rgb;
    float3 b = combiner_read(first >> 16, false, 8, u, registers, ef).rgb;
    float3 c = combiner_read(first >> 8, false, 8, u, registers, ef).rgb;
    float3 d = combiner_read(first, false, 8, u, registers, ef).rgb;
    float g = combiner_read(second >> 8, true, 8, u, registers, ef).x;
    return float4(d + mix(c, b, a), g);
}

#ifndef NV2A_METAL_COMBINER_NO_KERNEL
kernel void
nv2a_pixel_combiner(device const NV2AMetalCombinerInput *inputs [[buffer(0)]],
                    constant NV2AMetalCombinerState *states [[buffer(1)]],
                    device NV2AMetalCombinerOutput *outputs [[buffer(2)]],
                    constant NV2AMetalCombinerDispatch &dispatch [[buffer(3)]],
                    uint id [[thread_position_in_grid]])
{
    if (id >= dispatch.count) {
        return;
    }
    thread float4 registers[16] = {};
    registers[PS_REGISTER_V0] = combiner_load_device(inputs[id].diffuse);
    registers[PS_REGISTER_V1] = combiner_load_device(inputs[id].specular);
    registers[PS_REGISTER_FOG] = combiner_load_device(inputs[id].fog);
    for (uint i = 0; i < 4; i++) {
        registers[PS_REGISTER_T0 + i] =
            combiner_load_device(inputs[id].textures[i]);
    }
    float4 color =
        nv2a_combiner(states[dispatch.state_count == 1 ? 0 : id], registers);
    for (uint i = 0; i < 16; i++) {
        for (uint k = 0; k < 4; k++) {
            outputs[id].registers[i][k] = registers[i][k];
        }
    }
    for (uint k = 0; k < 4; k++) {
        outputs[id].color[k] = color[k];
    }
}
#endif
#endif
