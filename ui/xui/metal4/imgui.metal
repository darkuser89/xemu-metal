/*
 * xemu ImGui shaders for Metal 4
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <metal_stdlib>
using namespace metal;

struct ImGuiVertexIn {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
    float4 color [[attribute(2)]];
};

struct ImGuiVertexOut {
    float4 position [[position]];
    float2 texcoord;
    float4 color;
};

vertex ImGuiVertexOut xemu_imgui_vertex(ImGuiVertexIn in [[stage_in]],
                                        constant float4 &scale_offset
                                        [[buffer(1)]])
{
    ImGuiVertexOut out;
    out.position =
        float4(in.position * scale_offset.xy + scale_offset.zw, 0.0f, 1.0f);
    out.texcoord = in.texcoord;
    out.color = in.color;
    return out;
}

fragment float4 xemu_imgui_fragment(ImGuiVertexOut in [[stage_in]],
                                    texture2d<float> image [[texture(0)]],
                                    sampler image_sampler [[sampler(0)]])
{
    return in.color * image.sample(image_sampler, in.texcoord);
}
