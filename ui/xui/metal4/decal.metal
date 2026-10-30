/*
 * Native Metal 4 port of gl-helpers.cc's mask shader and xemu-logo.frag
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <metal_stdlib>
#ifndef XEMU_UI_METAL4_DECAL_UNIFORMS_H
#include "decal-uniforms.h"
#endif
using namespace metal;

float4 decal_load4(constant float *values)
{
    return float4(values[0], values[1], values[2], values[3]);
}

struct DecalVertex {
    float4 position [[position]];
    float2 texcoord;
};

vertex DecalVertex xemu_decal_vertex(uint vertex_id [[vertex_id]],
                                     constant XemuMetal4DecalUniforms &u
                                     [[buffer(0)]])
{
    const float2 positions[] = {
        float2(-1, 1),
        float2(-1, -1),
        float2(1, 1),
        float2(1, -1),
    };
    float2 p = positions[vertex_id];
    float4 transform = decal_load4(u.position);
    float4 tex_transform = decal_load4(u.texture);
    DecalVertex out;
    out.position = float4(p * transform.xy + transform.zw, 0, 1);
    float2 uv = p * float2(0.5f, -0.5f) + 0.5f;
    if (u.flip_y) {
        uv.y = 1.0f - uv.y;
    }
    out.texcoord = uv * tex_transform.xy + tex_transform.zw;
    return out;
}

fragment float4 xemu_decal_mask(DecalVertex in [[stage_in]],
                                constant XemuMetal4DecalUniforms &u
                                [[buffer(0)]],
                                texture2d<float> image [[texture(0)]],
                                sampler image_sampler [[sampler(0)]])
{
    float4 texel = image.sample(image_sampler, in.texcoord);
    float4 color = decal_load4(u.fill);
    color.rgb +=
        mix(decal_load4(u.secondary).rgb, decal_load4(u.primary).rgb, texel.r);
    color.a += texel.a - texel.b;
    return color;
}

constant float4 logo_text_pos(0.01f, 0, 0.98f, 0.125f);
constant float logo_pi = 3.14159265359f;
constant float logo_line_width = 0.175f;
constant int logo_num_particles = 35;
constant int logo_num_spotlights = 5;

// Original random function: https://www.shadertoy.com/view/Xl2SRR
float logo_random(float co)
{
    return fract(abs(sin(co * 12.989f)) * 43758.545f);
}

// Original impulse:
// https://www.iquilezles.org/www/articles/functions/functions.htm
float logo_impulse(float k, float x)
{
    return 2.0f * sqrt(k) * x / (1.0f + k * x * x);
}

float logo_box(float2 uv, float x, float width)
{
    float lhs = sign(clamp(x - uv.x, 0.0f, 1.0f));
    float rhs = sign(clamp(x - uv.x + width, 0.0f, 1.0f));
    return rhs - lhs;
}

float logo_sweeping_line_pos(float time)
{
    return time - logo_line_width + logo_text_pos.x;
}

float logo_gradients(float2 uv, float time)
{
    float l_s = abs(cos(time * logo_pi * 2.0f));
    float pos = time - uv.x + logo_text_pos.x;
    float left = l_s * smoothstep(0.0f, 1.0f,
                                  0.5f - abs(pos - logo_line_width) *
                                             (20.0f + 80.0f * (1.0f - l_s)));
    float r_s = abs(sin(time * logo_pi * 2.0f));
    float right =
        r_s * smoothstep(0.0f, 1.0f,
                         0.5f - abs(pos) * (20.0f + 80.0f * (1.0f - r_s)));
    float gradient_y = smoothstep(0.55f, 1.0f, 1.0f - abs(0.5f - uv.y));
    return (left + right) * gradient_y;
}

float2 logo_spotlight_pos(int i, float time)
{
    float2 initial = logo_text_pos.zw *
                     float2(float(i) / float(logo_num_spotlights - 1),
                            sign(logo_random(float(i + 62)) - 0.6f) * 2.0f);
    float2 velocity;
    velocity.x = sign(logo_random(float(i + 63)) - 0.5f) * 0.7f *
                 (0.3f + 0.6f * logo_random(float(i + 100)));
    velocity.y =
        -sign(initial.y) * 0.8f * (0.1f + 0.9f * logo_random(float(i + 62)));
    return initial + velocity * time + float2(logo_text_pos.x, 0.5f);
}

float logo_spotlights(float2 uv, float time)
{
    float right = smoothstep(
        0.3f, 0.7f, 0.8f - 8.0f * abs(time - uv.x + logo_text_pos.x + 0.05f));
    float c = 0;
    for (int i = 0; i < logo_num_spotlights; i++) {
        c += 1.0f - smoothstep(0.04f, 0.07835f,
                               distance(uv, logo_spotlight_pos(i, time)));
    }
    return 0.6f * right + 0.4f * c;
}

float2 logo_particle_initial(int i)
{
    return logo_text_pos.zw * float2(float(i) / float(logo_num_particles - 1),
                                     sign(logo_random(float(i)) - 0.2f));
}

float logo_probability(float p, int i)
{
    return sign(clamp(logo_random(float(i * 30)) - (1.0f - p), 0.0f, 1.0f));
}

float logo_particle_lifespan(int i)
{
    return 1.0f + 1.25f * exp(-10.0f * logo_random(float(i * 30))) +
           0.5f * logo_probability(0.3f, i);
}

float2 logo_particle_pos(int i, float time)
{
    float pt = time - logo_particle_initial(i).x;
    float impulse = logo_impulse(20.0f, pt * 0.25f + 0.05f +
                                            0.4f * logo_random(float(i + 30)));
    float2 initial = logo_particle_initial(i);
    float2 velocity;
    velocity.x = 0.4f * impulse * sign(logo_random(float(i + 66)) - 0.1f) *
                 (0.3f + 0.6f * logo_random(float(i + 100)));
    velocity.y = 0.8f * impulse * sign(initial.y) *
                 (0.1f + 0.9f * logo_random(float(i + 62)));
    float alive = clamp(sign(pt), 0.0f, 1.0f);
    return initial + alive * velocity * pt + float2(logo_text_pos.x, 0.5f);
}

float logo_particles(float2 uv, float time)
{
    float c = 0;
    for (int i = 0; i < logo_num_particles; i++) {
        float pt = time - logo_particle_initial(i).x;
        float intensity = clamp(sign(pt), 0.0f, 1.0f) *
                          clamp(logo_particle_lifespan(i) - pt, 0.0f, 1.0f);
        c += (1.0f - smoothstep(0.004f, 0.00835f,
                                distance(uv, logo_particle_pos(i, time)))) *
             intensity;
    }
    return c;
}

fragment float4 xemu_decal_logo(DecalVertex in [[stage_in]],
                                constant XemuMetal4DecalUniforms &u
                                [[buffer(0)]],
                                texture2d<float> image [[texture(0)]],
                                sampler image_sampler [[sampler(0)]])
{
    /* The original logo uses bottom-left gl_FragCoord in a 512x512 FBO. */
    float2 uv =
        float2(in.position.x,
               u.reserved ? in.position.y : u.target_height - in.position.y) /
        512.0f;
    const float scale = 1.4f;
    uv -= 0.5f * (1.0f - 1.0f / scale);
    uv *= scale;
    /* Native texture row zero is at the top; the GL asset was uploaded flipped.
     */
    float3 msd = image.sample(image_sampler, float2(uv.x, 1.0f - uv.y)).rgb;
    float sd = max(min(msd.r, msd.g), min(max(msd.r, msd.g), msd.b));
    float screen_distance = 6.0f * (sd - 0.5f);
    float opacity = clamp(screen_distance + 0.5f, 0.0f, 1.0f);
    float4 fg = decal_load4(u.primary), bg = decal_load4(u.fill);
    float4 fill_color = mix(bg, fg, opacity);
    float outline = clamp(screen_distance + 1.6f, 0.0f, 1.0f) -
                    clamp(screen_distance - 1.6f, 0.0f, 1.0f);
    outline = smoothstep(0.5f, 1.0f, outline);
    float4 line_color = mix(bg, fg, outline);
    float time = (u.time - 7.25f * floor(u.time / 7.25f)) / 1.25f;
    float sweep = logo_sweeping_line_pos(time);
    float4 color =
        mix(fill_color, line_color, logo_box(uv, sweep, logo_line_width));
    float mask_rhs = clamp(sign(uv.x - logo_line_width - sweep), 0.0f, 1.0f);
    color += fill_color * mask_rhs * logo_spotlights(uv, time);
    color += mix(float4(0), fg, logo_particles(uv, time));
    color += 2.0f * fg * logo_box(uv, logo_text_pos.x, logo_text_pos.z) *
             logo_gradients(uv, time);
    return color;
}
