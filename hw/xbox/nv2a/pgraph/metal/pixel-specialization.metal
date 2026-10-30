/* Immutable NV2A structural words; live colors remain draw uniforms.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#include <metal_stdlib>
using namespace metal;
#define NV2A_METAL_FRAGMENT_SPECIALIZATION
constant uint pixel_control_0 [[function_constant(0)]];
#define NV2A_COMBINER_CONTROL(u) pixel_control_0
constant uint pixel_shader_stage_program_0 [[function_constant(1)]];
#define NV2A_COMBINER_SHADER_STAGE_PROGRAM(u) pixel_shader_stage_program_0
constant uint2 pixel_final_inputs_0 [[function_constant(2)]];
#define NV2A_COMBINER_FINAL_INPUTS(u, i) pixel_final_inputs_0[i]
constant uint4 pixel_rgb_inputs_0 [[function_constant(3)]];
constant uint4 pixel_rgb_inputs_1 [[function_constant(4)]];
#define NV2A_COMBINER_RGB_INPUTS(u, i) \
    (i < 4 ? pixel_rgb_inputs_0[i] : pixel_rgb_inputs_1[i - 4])
constant uint4 pixel_rgb_outputs_0 [[function_constant(5)]];
constant uint4 pixel_rgb_outputs_1 [[function_constant(6)]];
#define NV2A_COMBINER_RGB_OUTPUTS(u, i) \
    (i < 4 ? pixel_rgb_outputs_0[i] : pixel_rgb_outputs_1[i - 4])
constant uint4 pixel_alpha_inputs_0 [[function_constant(7)]];
constant uint4 pixel_alpha_inputs_1 [[function_constant(8)]];
#define NV2A_COMBINER_ALPHA_INPUTS(u, i) \
    (i < 4 ? pixel_alpha_inputs_0[i] : pixel_alpha_inputs_1[i - 4])
constant uint4 pixel_alpha_outputs_0 [[function_constant(9)]];
constant uint4 pixel_alpha_outputs_1 [[function_constant(10)]];
#define NV2A_COMBINER_ALPHA_OUTPUTS(u, i) \
    (i < 4 ? pixel_alpha_outputs_0[i] : pixel_alpha_outputs_1[i - 4])
constant uint pixel_raster_class [[function_constant(11)]];
#define NV2A_PIXEL_RASTER_TAG(in) \
    (pixel_raster_class != 0 ? float(pixel_raster_class - 1) : in.line_raster.z)
