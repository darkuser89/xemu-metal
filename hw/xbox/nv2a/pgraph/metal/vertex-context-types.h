/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_CONTEXT_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_CONTEXT_TYPES_H
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_TYPES_H
#include "vertex-program-types.h"
#endif
#ifdef __METAL_VERSION__
#define NV2A_METAL_CONTEXT 1
#endif
/* Internal CPU/MSL transport, not hardware bitfields or a serialized ABI. */
typedef struct NV2AMetalStateInput {
    float constants[192][4];
    NV2AMetalProgramInput attributes;
} NV2AMetalStateInput;
typedef struct NV2AMetalStateOutput {
    float constants[192][4];
    unsigned dirty[192];
    unsigned fault;
    unsigned reserved[3];
} NV2AMetalStateOutput;

/* Internal native transport; neither NV2A hardware nor a serialized ABI. */
typedef struct NV2AMetalStateParameters {
    NV2AMetalProgramUniforms common;
    unsigned full_access;
    unsigned reserved[3];
} NV2AMetalStateParameters;

/* Internal software transport, no hardware bits or serialized ABI. */
typedef struct NV2AMetalWritableParameters {
    NV2AMetalProgramUniforms common;
    unsigned full_access;
    unsigned write_enable;
    unsigned rasterize;
    unsigned reserved;
} NV2AMetalWritableParameters;
typedef struct NV2AMetalWritableContext {
    float constants[192][4];
    unsigned dirty[192];
    unsigned fault;
    unsigned reserved[3];
} NV2AMetalWritableContext;

#endif
