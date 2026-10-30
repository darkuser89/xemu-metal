/*
 * Native NV2A vertex-program data shared with MSL
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_TYPES_H

/* Sizes and opcode order come from nv2a_regs.h and pgraph/vsh_regs.h. */
#define NV2A_METAL_VP_ATTRIBUTES 16
#define NV2A_METAL_VP_CONSTANTS 192
#define NV2A_METAL_VP_SLOTS 136

enum NV2AMetalMAC {
    NV2AMetalMACNop,
    NV2AMetalMACMov,
    NV2AMetalMACMul,
    NV2AMetalMACAdd,
    NV2AMetalMACMad,
    NV2AMetalMACDp3,
    NV2AMetalMACDph,
    NV2AMetalMACDp4,
    NV2AMetalMACDst,
    NV2AMetalMACMin,
    NV2AMetalMACMax,
    NV2AMetalMACSlt,
    NV2AMetalMACSge,
    NV2AMetalMACArl,
};

enum NV2AMetalILU {
    NV2AMetalILUNop,
    NV2AMetalILUMov,
    NV2AMetalILURcp,
    NV2AMetalILURcc,
    NV2AMetalILURsq,
    NV2AMetalILUExp,
    NV2AMetalILULog,
    NV2AMetalILULit,
};

enum NV2AMetalProgramFault {
    NV2AMetalProgramFaultNone,
    NV2AMetalProgramFaultConstantRange,
    NV2AMetalProgramFaultAddressRange,
};

typedef struct NV2AMetalProgramInput {
    float attributes[NV2A_METAL_VP_ATTRIBUTES][4];
} NV2AMetalProgramInput;

/* Raw oPos..oT3, using the original output-register numbers. Reserved outputs
 * 1/2 are never written. A fault indicates an invalid dynamic address, not an
 * emulated hardware result. The caller must reject such a draw. */
typedef struct NV2AMetalProgramOutput {
    float registers[13][4];
    unsigned int fault;
    unsigned int reserved[3];
} NV2AMetalProgramOutput;

typedef struct NV2AMetalProgramUniforms {
    float constants[NV2A_METAL_VP_CONSTANTS][4];
    float surface_size[2];
    float zmax;
    float point_size;
    float fog[2];
    float point_scale;
    unsigned int point_programmed;
    unsigned int fog_enable;
    unsigned int fog_mode;
    unsigned int specular_enable;
    unsigned int ignore_specular_alpha;
    unsigned int vertex_count;
    unsigned int program_length;
    unsigned int reserved[2];
} NV2AMetalProgramUniforms;

/* Internal decoded instructions, not NV2A register/bitfield definitions.
 * source packs mux[1:0], temp[5:2], xyzw swizzle[13:6], negate[14]. */
typedef struct NV2AMetalProgramInstruction {
    unsigned int mac, ilu, constant_index, attribute_index;
    unsigned int source[3];
    unsigned int mac_mask, ilu_mask, output_mask, output_register;
    unsigned int output_mux, temp_register, relative;
} NV2AMetalProgramInstruction;

#endif
