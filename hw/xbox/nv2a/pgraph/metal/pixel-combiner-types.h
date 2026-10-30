/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_TYPES_H

#ifndef HW_NV2A_PSH_H
#include "../psh_regs.h"
#endif

/* Original NV2A words consumed by glsl/psh.c; constants are RGBA Float4s,
 * arranged as C0/C1 for stages 0..7 and the final combiner at indices 16/17.
 * No implicit C/MSL vector alignment is used in the shared structures. */
typedef struct NV2AMetalCombinerState {
    unsigned int control;
    unsigned int shader_stage_program;
    unsigned int final_inputs[2];
    unsigned int rgb_inputs[8];
    unsigned int rgb_outputs[8];
    unsigned int alpha_inputs[8];
    unsigned int alpha_outputs[8];
    float constants[18][4];
} NV2AMetalCombinerState;

typedef struct NV2AMetalCombinerInput {
    float diffuse[4];
    float specular[4];
    float fog[4];
    float textures[4][4];
} NV2AMetalCombinerInput;

typedef struct NV2AMetalCombinerOutput {
    float registers[16][4];
    float color[4];
} NV2AMetalCombinerOutput;

typedef struct NV2AMetalCombinerDispatch {
    unsigned int count;
    unsigned int state_count;
} NV2AMetalCombinerDispatch;

#endif
