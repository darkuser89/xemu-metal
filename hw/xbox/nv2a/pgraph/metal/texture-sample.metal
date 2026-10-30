/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLE_MSL
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLE_MSL
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLER_TYPES_H
#include "texture-sampler-types.h"
#endif
#include <metal_stdlib>
using namespace metal;

/* Explicit texel reads preserve RGBA32Float filtering on Apple7/8. Cube maps
 * follow GL's default non-seamless face selection. Address 5 intentionally
 * retains the reference's CLAMP_OGL -> CLAMP_TO_EDGE approximation. */
static float sample_coordinate(float c, uint address)
{
    if (address == 1) {
        return c - floor(c);
    }
    if (address == 2) {
        float period = c - 2.0f * floor(c * .5f);
        return period <= 1 ? period : 2 - period;
    }
    return clamp(c, -1.0f, 2.0f);
}

static int sample_address(int c, uint size, uint address)
{
    if (address == 1) {
        return (c % int(size) + int(size)) % int(size);
    }
    /* Mirroring coordinates first folds [0, 2] onto [0, 1]; texels at the
     * reflected seams then clamp, rather than wrap to the opposite edge. */
    return address == 4 ? c : clamp(c, 0, int(size) - 1);
}

static uint3 sample_size(texture2d<float> t, uint level)
{
    return uint3(t.get_width(level), t.get_height(level), 1);
}
static uint3 sample_size(texture3d<float> t, uint level)
{
    return uint3(t.get_width(level), t.get_height(level), t.get_depth(level));
}
static uint3 sample_size(texturecube<float> t, uint level)
{
    return uint3(t.get_width(level), t.get_height(level), 1);
}

static float4 sample_read(texture2d<float> t, uint3 c, uint level, uint face)
{
    (void)face;
    return t.read(c.xy, level);
}
static float4 sample_read(texture3d<float> t, uint3 c, uint level, uint face)
{
    (void)face;
    return t.read(c, level);
}
static float4 sample_read(texturecube<float> t, uint3 c, uint level, uint face)
{
    return t.read(c.xy, face, level);
}

template <typename T>
static float4 sample_texel(T t, int3 c, uint3 size, uint level, uint face,
                           constant NV2AMetalSamplingUniforms &s,
                           uint unsigned_half_mask)
{
    for (uint i = 0; i < 3; i++) {
        c[i] = sample_address(c[i], size[i], s.address[i]);
    }
    if (any(c < 0) || any(c >= int3(size))) {
        return float4(s.border_color[0], s.border_color[1], s.border_color[2],
                      s.border_color[3]);
    }
    float4 value = sample_read(t, uint3(c), level, face);
    for (uint k = 0; k < 4; k++)
        if (unsigned_half_mask & (1u << k))
            value[k] = (value[k] * 256.0f) / 255.0f;
    return value;
}

template <typename T>
static float4 sample_level(T t, float3 c, uint level, uint face, bool linear,
                           bool volume, constant NV2AMetalSamplingUniforms &s,
                           uint unsigned_half_mask)
{
    uint3 size = sample_size(t, level);
    for (uint i = 0; i < 3; i++) {
        c[i] = sample_coordinate(c[i], s.address[i]);
    }
    float3 p = c * float3(size);
    if (!linear) {
        return sample_texel(t, int3(floor(p)), size, level, face, s,
                            unsigned_half_mask);
    }
    p -= .5f;
    int3 base = int3(floor(p));
    float3 f = p - floor(p);
    if (!volume) {
        base.z = 0;
    }
    float4 color = 0;
    for (uint z = 0; z < (volume ? 2u : 1u); z++) {
        for (uint y = 0; y < 2; y++) {
            for (uint x = 0; x < 2; x++) {
                float w = (x ? f.x : 1 - f.x) * (y ? f.y : 1 - f.y);
                if (volume) {
                    w *= z ? f.z : 1 - f.z;
                }
                color += w * sample_texel(t, base + int3(x, y, z), size, level,
                                          face, s, unsigned_half_mask);
            }
        }
    }
    return color;
}

template <typename T>
static float4 sample_mips(T t, float3 c, float lod, uint face, bool volume,
                          constant NV2AMetalSamplingUniforms &s,
                          uint unsigned_half_mask)
{
    bool linear = lod <= 0 ? s.mag_linear : s.min_linear;
    lod = lod <= 0 || s.mip_filter == 0 ?
              0 :
              clamp(lod, 0.0f, float(t.get_num_mip_levels() - 1));
    if (s.mip_filter != 2) {
        /* GL's preferred nearest-mip tie selects the lower level. */
        uint level = uint(max(0.0f, ceil(lod + .5f) - 1));
        return sample_level(t, c, level, face, linear, volume, s,
                            unsigned_half_mask);
    }
    uint a = uint(floor(lod));
    uint b = min(a + 1, t.get_num_mip_levels() - 1);
    return mix(
        sample_level(t, c, a, face, linear, volume, s, unsigned_half_mask),
        sample_level(t, c, b, face, linear, volume, s, unsigned_half_mask),
        lod - floor(lod));
}

template <typename T>
static float4 sample_footprint(T t, float3 c, float3 dx, float3 dy, uint face,
                               bool volume,
                               constant NV2AMetalSamplingUniforms &s,
                               uint unsigned_half_mask = 0)
{
    if (!all(isfinite(c))) {
        return float4(s.border_color[0], s.border_color[1], s.border_color[2],
                      s.border_color[3]);
    }
    dx = all(isfinite(dx)) ? dx : float3(0);
    dy = all(isfinite(dy)) ? dy : float3(0);
    float3 size = float3(sample_size(t, 0));
    float x = length(dx * size), y = length(dy * size);
    float lod_scale = 0;
    if (!isfinite(max(x, y))) {
        // Finite derivatives can overflow when converted to texel units.
        // A common scale preserves their ratio and the major-axis choice.
        float3 magnitude = max(abs(dx), abs(dy));
        float scale = max(max(magnitude.x, magnitude.y), magnitude.z);
        x = length((dx / scale) * size);
        y = length((dy / scale) * size);
        lod_scale = log2(scale);
    }
    float major = max(x, y), minor = min(x, y);
    /* Khronos's permitted major/minor footprint approximation. Sampling is
     * bounded to eight taps, with all selected mip levels confined to the
     * texture view. Derivatives of dependent reads are as approximate as GL. */
    uint taps = 1;
    if (s.anisotropy > 1 && isfinite(major) && (major > 1 || lod_scale > 0)) {
        taps = uint(
            clamp(ceil(major / max(minor, 1e-30f)), 1.0f, float(s.anisotropy)));
    }
    float lod = log2(max(major / float(taps), 1e-30f)) + lod_scale + s.lod_bias;
    lod = isfinite(lod) ? lod : 0;
    float3 gradient = x > y ? dx : dy;
    float4 result = 0;
    for (uint i = 0; i < taps; i++) {
        float offset = (float(i) + 1) / (float(taps) + 1) - .5f;
        result += sample_mips(t, c + gradient * offset, lod, face, volume, s,
                              unsigned_half_mask);
    }
    return result / float(taps);
}

static bool sample_base_only(constant NV2AMetalSamplingUniforms &s)
{
    /* One tap at level zero with identical min/mag filtering is independent
     * of the footprint. Keep sample_footprint for its exact color arithmetic. */
    return s.enabled == 1 && s.mip_filter == 0 &&
           s.min_linear == s.mag_linear && s.anisotropy == 1;
}

static float4 nv2a_sample(texture2d<float> t, sampler smp, float2 c,
                          constant NV2AMetalSamplingUniforms &s,
                          uint unsigned_half_mask = 0)
{
    if (!s.enabled) {
        return t.sample(smp, c);
    }
    float2 dx(0), dy(0);
    if (!sample_base_only(s)) {
        dx = dfdx(c);
        dy = dfdy(c);
    }
    return sample_footprint(t, float3(c, 0), float3(dx, 0), float3(dy, 0), 0,
                            false, s, unsigned_half_mask);
}
static float4 nv2a_sample(texture3d<float> t, sampler smp, float3 c,
                          constant NV2AMetalSamplingUniforms &s,
                          uint unsigned_half_mask = 0)
{
    if (!s.enabled) {
        return t.sample(smp, c);
    }
    float3 dx(0), dy(0);
    if (!sample_base_only(s)) {
        dx = dfdx(c);
        dy = dfdy(c);
    }
    return sample_footprint(t, c, dx, dy, 0, true, s, unsigned_half_mask);
}
static float4 nv2a_sample(texturecube<float> t, sampler smp, float3 c,
                          constant NV2AMetalSamplingUniforms &s, float2 logical,
                          float2 inverse, uint unsigned_half_mask = 0)
{
    if (!s.enabled) {
        return t.sample(smp, c);
    }
    /* Compute direction derivatives before selecting the face. Projecting
     * those derivatives analytically avoids dfdx/dfdy across a face seam. */
    float3 dx(0), dy(0);
    if (!sample_base_only(s)) {
        dx = dfdx(c);
        dy = dfdy(c);
    }
    float3 a = abs(c);
    uint axis = a.x >= a.y && a.x >= a.z ? 0 : a.y >= a.z ? 1 : 2;
    bool positive = c[axis] >= 0;
    uint face = 2 * axis + uint(!positive);
    float major = a[axis];
    float2 uv, ux, uy;
    if (axis == 0) {
        float sign = positive ? -1 : 1;
        uv = float2(sign * c.z, -c.y);
        ux = float2(sign * dx.z, -dx.y);
        uy = float2(sign * dy.z, -dy.y);
    } else if (axis == 1) {
        float sign = positive ? 1 : -1;
        uv = float2(c.x, sign * c.z);
        ux = float2(dx.x, sign * dx.z);
        uy = float2(dy.x, sign * dy.z);
    } else {
        float sign = positive ? 1 : -1;
        uv = float2(sign * c.x, -c.y);
        ux = float2(sign * dx.x, -dx.y);
        uy = float2(sign * dy.x, -dy.y);
    }
    float sign = positive ? 1 : -1;
    // Divide first: a common direction scale must not overflow/underflow
    // the squared denominator or the numerator's products.
    uv /= major;
    ux = .5f * (ux / major - uv * (sign * dx[axis] / major));
    uy = .5f * (uy / major - uv * (sign * dy[axis] / major));
    uv = .5f * (uv + 1);
    if (logical.x != 0) {
        // Select/project the face before applying its physical border.
        // Keep the base transform across mip views and scale both gradients.
        float2 scale = logical * inverse;
        uv = (uv * logical + 4.0f) * inverse;
        ux *= scale;
        uy *= scale;
    }
    return sample_footprint(t, float3(uv, 0), float3(ux, 0), float3(uy, 0),
                            face, false, s, unsigned_half_mask);
}
static float4 nv2a_sample(texturecube<float> t, sampler smp, float3 c,
                          constant NV2AMetalSamplingUniforms &s,
                          uint unsigned_half_mask = 0)
{
    return nv2a_sample(t, smp, c, s, float2(0), float2(0), unsigned_half_mask);
}
#endif
