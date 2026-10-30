/*
 * Native Metal 4 counterpart of glsl/vsh-ff.c
 * Copyright (c) 2015 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#include <metal_stdlib>
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FIXED_TYPES_H
#include "vertex-fixed-types.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_TYPES_H
#include "geometry-types.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_COMMON_MSL
#include "vertex-common.metal"
#endif
using namespace metal;
#pragma clang fp contract(off)

/* Unset constants retain the original general uniform-driven shader. */
#define FF_SCALAR(Name, Field, Index)                                        \
constant uint ff_constant_##Name [[function_constant(Index)]];                \
inline uint ff_state_##Name(constant NV2AMetalFixedUniforms &u)               \
{                                                                           \
    return is_function_constant_defined(ff_constant_##Name) ?                 \
               ff_constant_##Name : u.Field;                                \
}
NV2A_METAL_FIXED_SCALAR_CONSTANTS(FF_SCALAR)
#undef FF_SCALAR
constant uint ff_matrix_mask [[function_constant(22)]];
constant uint ff_lights [[function_constant(23)]];
constant uint ff_texgen0 [[function_constant(24)]];
constant uint ff_texgen1 [[function_constant(25)]];
constant uint ff_texgen2 [[function_constant(26)]];
constant uint ff_texgen3 [[function_constant(27)]];
inline uint ff_matrix_enabled(uint t, constant NV2AMetalFixedUniforms &u)
{
    return is_function_constant_defined(ff_matrix_mask) ?
               (ff_matrix_mask >> t) & 1 : u.texture_matrix_enable[t];
}
inline uint ff_light_type(uint i, constant NV2AMetalFixedUniforms &u)
{
    return is_function_constant_defined(ff_lights) ?
               (ff_lights >> (2 * i)) & 3 : u.light[i];
}
inline uint ff_texgen_mode(uint t, uint component,
                          constant NV2AMetalFixedUniforms &u)
{
    switch (t) {
    case 0:
        if (is_function_constant_defined(ff_texgen0))
            return (ff_texgen0 >> (3 * component)) & 7;
        break;
    case 1:
        if (is_function_constant_defined(ff_texgen1))
            return (ff_texgen1 >> (3 * component)) & 7;
        break;
    case 2:
        if (is_function_constant_defined(ff_texgen2))
            return (ff_texgen2 >> (3 * component)) & 7;
        break;
    case 3:
        if (is_function_constant_defined(ff_texgen3))
            return (ff_texgen3 >> (3 * component)) & 7;
        break;
    }
    return u.texgen[t][component];
}

float4 ff_attribute(device const NV2AMetalProgramInput &input, uint index)
{
    return float4(input.attributes[index][0], input.attributes[index][1],
                  input.attributes[index][2], input.attributes[index][3]);
}

float3 ff_load3(constant float *v)
{
    return float3(v[0], v[1], v[2]);
}

float4 ff_transform(float4 value, uint offset,
                    constant NV2AMetalFixedUniforms &u)
{
    /* GLSL's row-vector * matrix(column0,...) convention. */
    return float4(dot(value, vp_load4(u.common.constants[offset])),
                  dot(value, vp_load4(u.common.constants[offset + 1])),
                  dot(value, vp_load4(u.common.constants[offset + 2])),
                  dot(value, vp_load4(u.common.constants[offset + 3])));
}

float3 ff_material(uint source, float3 material, float4 diffuse,
                   float4 specular)
{
    return source == NV2AMetalMaterialSourceMaterial ? material :
           source == NV2AMetalMaterialSourceDiffuse  ? diffuse.xyz :
                                                       specular.xyz;
}

void ff_lighting(float4 position, float3 normal, float4 diffuse,
                 float4 specular, bool back, constant NV2AMetalFixedUniforms &u,
                 thread float4 &d0, thread float4 &d1)
{
    uint ambient_src = back ? ff_state_back_ambient_src(u) : ff_state_ambient_src(u);
    uint emission_src = back ? ff_state_back_emission_src(u) : ff_state_emission_src(u);
    uint diffuse_src = back ? ff_state_back_diffuse_src(u) : ff_state_diffuse_src(u);
    uint specular_src = back ? ff_state_back_specular_src(u) : ff_state_specular_src(u);
    float3 ambient = vp_load4(u.ltctxa[back ? NV_IGRAPH_XF_LTCTXA_BR_AMB :
                                              NV_IGRAPH_XF_LTCTXA_FR_AMB])
                         .xyz;
    float3 emission = vp_load4(u.ltctxa[back ? NV_IGRAPH_XF_LTCTXA_BCM_COL :
                                               NV_IGRAPH_XF_LTCTXA_CM_COL])
                          .xyz;
    float alpha = diffuse_src == NV2AMetalMaterialSourceMaterial ?
                      (back ? u.material_alpha_back : u.material_alpha) :
                  diffuse_src == NV2AMetalMaterialSourceDiffuse ? diffuse.a :
                                                                  specular.a;
    d0 =
        float4(ff_material(ambient_src, ambient, diffuse, specular) * emission +
                   ff_material(emission_src, ambient, diffuse, specular),
               alpha);
    d1 = float4(0, 0, 0, specular.a);
    float3 eye(0);
    if (ff_state_local_eye(u)) {
        float4 eye_position =
            vp_load4(u.common.constants[NV_IGRAPH_XF_XFCTX_EYEP]);
        eye = normalize(eye_position.xyz / eye_position.w -
                        position.xyz / position.w);
    }
    for (uint i = 0; i < NV2A_MAX_LIGHTS; i++) {
        uint light = ff_light_type(i, u);
        if (light == NV2AMetalLightOff) {
            continue;
        }
        float attenuation = 1.0f;
        float3 direction, half_vector;
        if (light == NV2AMetalLightInfinite) {
            direction = normalize(ff_load3(u.light_direction[i]));
            half_vector = ff_state_local_eye(u) ? normalize(direction + eye) :
                                        ff_load3(u.light_half_vector[i]);
        } else {
            float3 delta =
                ff_load3(u.light_position[i]) - position.xyz / position.w;
            float distance = length(delta);
            if (!(distance <= u.ltc1[NV_IGRAPH_XF_LTC1_r0 + i][0])) {
                continue;
            }
            direction = normalize(delta);
            float3 coefficients = ff_load3(u.light_attenuation[i]);
            attenuation = 1.0f / (coefficients.x + coefficients.y * distance +
                                  coefficients.z * distance * distance);
            half_vector = normalize(direction + eye);
            if (light == NV2AMetalLightSpot) {
                float4 spot =
                    vp_load4(u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_SPT + 2 * i]);
                float coordinate = min(dot(spot.xyz, direction) + spot.w, 1.0f);
                float factor = 0;
                if (coordinate > 0.0f) {
                    /* NV lighting uses (s + L) / (M*s + N), not s^power.
                     * Coefficients share the existing LTCTXA capture. */
                    float3 falloff =
                        ff_load3(u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * i]);
                    if (coordinate > -falloff.x) {
                        float denominator = falloff.y * coordinate + falloff.z;
                        /* Keep zero color components zero when the reciprocal
                         * saturates, instead of multiplying them by infinity.
                         */
                        factor = clamp((coordinate + falloff.x) / denominator,
                                       0.0f, 0x1.fffffep127f);
                    }
                }
                attenuation *= factor;
            }
        }
        float ndotl = max(0.0f, dot(normal, direction));
        float ndoth = max(0.0f, dot(normal, half_vector));
        float power = 0;
        if (ff_state_legacy_specular(u)) {
            power = ndotl == 0.0f || ndoth == 0.0f ?
                        0.0f :
                        pow(ndoth, u.specular_power);
        } else {
            float3 parameters =
                ff_load3(back ? u.specular_params_back : u.specular_params);
            if (ndotl > 0.0f && ndoth > -parameters.x) {
                float denominator = parameters.y * ndoth + parameters.z;
                /* Finite saturation retains zero light-color channels. */
                power = clamp((ndoth + parameters.x) / denominator, 0.0f,
                              0x1.fffffep127f);
            }
        }
        float3 la =
            vp_load4(
                u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_AMB + 6 * i + (back ? 3 : 0)])
                .xyz *
            attenuation;
        float3 ld =
            vp_load4(
                u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF + 6 * i + (back ? 3 : 0)])
                .xyz *
            attenuation * ndotl;
        float3 ls =
            vp_load4(
                u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * i + (back ? 3 : 0)])
                .xyz *
            attenuation * power;
        d0.xyz += la;
        d0.xyz += ff_material(diffuse_src, float3(1), diffuse, specular) * ld;
        d1.xyz += ff_material(specular_src, float3(1), diffuse, specular) * ls;
    }
}

template <bool Compact>
static void vertex_fixed(device const NV2AMetalProgramInput *inputs,
                         device NV2AMetalProgramOutput *raw,
                         device NV2AMetalVertex *vertices,
                         constant NV2AMetalFixedParameters &parameters,
                         uint index)
{
    constant NV2AMetalFixedUniforms &u = parameters.uniforms;
    if (index >= u.common.vertex_count) {
        return;
    }
    device const NV2AMetalProgramInput &input = inputs[index];
    float4 position = ff_attribute(input, 0), weight = ff_attribute(input, 1);
    float4 normal(ff_attribute(input, 2).xyz, 0);
    float4 diffuse = ff_attribute(input, 3), specular = ff_attribute(input, 4);
    float4 back_diffuse = ff_attribute(input, 7),
           back_specular = ff_attribute(input, 8);
    uint count = 0;
    bool unity = false;
    switch (ff_state_skinning(u)) {
    case NV2AMetalSkinningOneWeight:
        count = 2;
        unity = true;
        break;
    case NV2AMetalSkinningTwoWeightsTwoMatrices:
        count = 2;
        break;
    case NV2AMetalSkinningTwoWeights:
        count = 3;
        unity = true;
        break;
    case NV2AMetalSkinningThreeWeightsThreeMatrices:
        count = 3;
        break;
    case NV2AMetalSkinningThreeWeights:
        count = 4;
        unity = true;
        break;
    case NV2AMetalSkinningFourWeightsFourMatrices:
        count = 4;
        break;
    default:
        break;
    }
    float4 transformed(0);
    float3 transformed_normal(0);
    float remaining = 1;
    if (count == 0) {
        transformed = ff_transform(position, NV_IGRAPH_XF_XFCTX_MMAT0, u);
        transformed_normal =
            ff_transform(normal, NV_IGRAPH_XF_XFCTX_IMMAT0, u).xyz;
    }
    for (uint i = 0; i < count; i++) {
        float w = unity && i == count - 1 ? remaining : weight[i];
        if (unity && i < count - 1) {
            remaining -= w;
        }
        transformed +=
            ff_transform(position, NV_IGRAPH_XF_XFCTX_MMAT0 + 8 * i, u) * w;
        transformed_normal +=
            ff_transform(normal, NV_IGRAPH_XF_XFCTX_IMMAT0 + 8 * i, u).xyz * w;
    }
    if (ff_state_normalization(u)) {
        transformed_normal = normalize(transformed_normal);
    }

    float4 texture[4];
    for (uint t = 0; t < 4; t++) {
        texture[t] = ff_attribute(input, 9 + t);
        for (uint component = 0; component < 4; component++) {
            uint mode = ff_texgen_mode(t, component, u);
            uint plane = NV_IGRAPH_XF_XFCTX_TG0MAT + 8 * t + component;
            switch (mode) {
            case NV2AMetalTexgenEyeLinear:
                texture[t][component] =
                    dot(vp_load4(u.common.constants[plane]), transformed);
                break;
            case NV2AMetalTexgenObjectLinear:
                texture[t][component] =
                    dot(vp_load4(u.common.constants[plane]), position);
                break;
            case NV2AMetalTexgenSphere: {
                float3 view = ff_state_texgen_infinite_viewer(u) ?
                                  float3(0, 0, 1) :
                                  normalize(transformed.xyz);
                float3 reflection = reflect(view, transformed_normal);
                float inv_m =
                    1.0f / (2.0f * length(reflection + float3(0, 0, 1)));
                texture[t][component] = reflection[component] * inv_m + 0.5f;
                break;
            }
            case NV2AMetalTexgenReflection: {
                float3 view = ff_state_texgen_infinite_viewer(u) ?
                                  float3(0, 0, 1) :
                                  normalize(transformed.xyz);
                texture[t][component] =
                    reflect(view, transformed_normal)[component];
                break;
            }
            case NV2AMetalTexgenNormal:
                texture[t][component] = transformed_normal[component];
                break;
            default:
                break;
            }
        }
        if (ff_matrix_enabled(t, u)) {
            texture[t] =
                ff_transform(texture[t], NV_IGRAPH_XF_XFCTX_T0MAT + 8 * t, u);
        }
    }
    float4 d0 = diffuse, d1 = specular, b0 = back_diffuse, b1 = back_specular;
    if (ff_state_lighting(u)) {
        ff_lighting(transformed, transformed_normal, diffuse, specular, false,
                    u, d0, d1);
        if (ff_state_two_side(u)) {
            /* Kelvin fixed function uses front attributes for both materials.
             */
            ff_lighting(transformed, -transformed_normal, diffuse, specular,
                        true, u, b0, b1);
        }
    }
    if (!ff_state_specular_enable(u)) {
        d1 = b1 = float4(0, 0, 0, 1);
    } else {
        if (!ff_state_separate_specular(u)) {
            if (ff_state_lighting(u)) {
                d0.xyz += d1.xyz;
                b0.xyz += b1.xyz;
            }
            d1 = specular;
            b1 = ff_state_lighting(u) && ff_state_two_side(u) ? specular : back_specular;
        }
        if (ff_state_ignore_specular_alpha(u)) {
            d1.a = b1.a = 1;
        }
    }
    /* Fixed-function hardware does not pass back-color attributes through
     * with lighting disabled. Programmed vertex outputs retain their colors.
     */
    if (!ff_state_lighting(u)) {
        b0 = b1 = float4(0, 0, 0, 1);
    }
    float fog_distance = 1;
    if (ff_state_fog_enable(u)) {
        switch (ff_state_foggen(u)) {
        case NV2AMetalFoggenSpecularAlpha:
            fog_distance = clamp(specular.a, 0.0f, 1.0f);
            break;
        case NV2AMetalFoggenRadial:
            fog_distance = length(transformed.xyz);
            break;
        case NV2AMetalFoggenPlanar:
        case NV2AMetalFoggenAbsPlanar: {
            float4 plane = vp_load4(u.common.constants[NV_IGRAPH_XF_XFCTX_FOG]);
            fog_distance = dot(plane.xyz, transformed.xyz) + plane.w;
            if (ff_state_foggen(u) == NV2AMetalFoggenAbsPlanar) {
                fog_distance = abs(fog_distance);
            }
            break;
        }
        default:
            fog_distance = ff_attribute(input, 5).x;
            break;
        }
    }
    float4 clip = ff_transform(ff_state_skinning(u) == NV2AMetalSkinningOff ? position :
                                                                    transformed,
                               NV_IGRAPH_XF_XFCTX_CMAT0, u);
    clip.w = vp_clamp_w(clip.w);
    float2 screen_xy =
        clip.xy / clip.w +
        vp_load4(u.common.constants[NV_IGRAPH_XF_XFCTX_VPOFF]).xy;
    screen_xy = trunc(screen_xy * 16.0f) / 16.0f;
    float4 screen(screen_xy, clip.z / clip.w, clip.w);
    float point_size;
    if (ff_state_point_params_enable(u)) {
        float distance =
            length(ff_transform(position, NV_IGRAPH_XF_XFCTX_MMAT0, u));
        float minimum = min(u.point_params[7], 63.875f);
        float maximum = min(u.point_params[3] + minimum, 63.875f);
        point_size =
            1.0f / sqrt(u.point_params[0] + u.point_params[1] * distance +
                        u.point_params[2] * distance * distance) +
            u.point_params[6];
        point_size = clamp(point_size * u.point_params[3] + u.point_params[7],
                           minimum, maximum) *
                     u.common.point_scale;
    } else {
        point_size = max(1.0f, u.common.point_size) * u.common.point_scale;
    }

    if (!Compact) {
        NV2AMetalProgramOutput snapshot = {};
        for (uint i = 0; i < 13; i++) {
            snapshot.registers[i][3] = 1;
        }
        vp_store4(snapshot.registers[0], clip);
        vp_store4(snapshot.registers[3], d0);
        vp_store4(snapshot.registers[4], d1);
        snapshot.registers[5][0] = fog_distance;
        snapshot.registers[6][0] = point_size;
        vp_store4(snapshot.registers[7], b0);
        vp_store4(snapshot.registers[8], b1);
        for (uint t = 0; t < 4; t++) {
            vp_store4(snapshot.registers[9 + t], texture[t]);
        }
        raw[index] = snapshot;
    }
    NV2AMetalVertex result = {};
    if (!parameters.rasterize) {
        vertices[index] = result;
        return;
    }
    float2 size(u.common.surface_size[0], u.common.surface_size[1]);
    float2 ndc = (2.0f * screen_xy - size) / size;
    float4 native_clip(ndc.x * clip.w, -ndc.y * clip.w, clip.z / u.common.zmax,
                       clip.w);
    vp_store4(result.clip, native_clip);
    vp_store4(result.screen, screen);
    vp_store4(result.color[0], vp_color(d0));
    vp_store4(result.color[1], vp_color(d1));
    vp_store4(result.color[2], vp_color(b0));
    vp_store4(result.color[3], vp_color(b1));
    for (uint t = 0; t < 4; t++) {
        vp_store4(result.texcoord[t], texture[t]);
    }
    for (uint p = 0; p < 3; p++) {
        vp_store4(result.plane[p], screen);
    }
    result.fog = vp_fog(fog_distance, u.common, ff_state_fog_enable(u),
                        ff_state_fog_mode(u));
    result.point_size = point_size;
    vertices[index] = result;
}

kernel void nv2a_vertex_fixed(device const NV2AMetalProgramInput *inputs
                              [[buffer(0)]],
                              device NV2AMetalProgramOutput *raw [[buffer(1)]],
                              device NV2AMetalVertex *vertices [[buffer(2)]],
                              constant NV2AMetalFixedParameters &parameters
                              [[buffer(3)]],
                              uint index [[thread_position_in_grid]])
{
    vertex_fixed<false>(inputs, raw, vertices, parameters, index);
}

kernel void nv2a_vertex_fixed_raster(
    device const NV2AMetalProgramInput *inputs [[buffer(0)]],
    device NV2AMetalProgramOutput *raw [[buffer(1)]],
    device NV2AMetalVertex *vertices [[buffer(2)]],
    constant NV2AMetalFixedParameters &parameters [[buffer(3)]],
    uint index [[thread_position_in_grid]])
{
    vertex_fixed<true>(inputs, raw, vertices, parameters, index);
}
