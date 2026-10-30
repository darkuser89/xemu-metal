/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FETCH_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FETCH_TYPES_H

#ifndef HW_NV2A_REGS_H
#include "../../nv2a_regs.h"
#endif
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_TYPES_H
#include "vertex-program-types.h"
#endif

/* Internal fetch metadata, not emulated registers. Buffer bindings already
 * include each source's byte offset. max_index bounds the final complete
 * element, including overlapping strides and the last byte of a buffer. */
typedef struct NV2AMetalFetchAttribute {
    float inline_value[4];
    unsigned int count;
    unsigned int format;
    unsigned int stride;
    unsigned int max_index;
} NV2AMetalFetchAttribute;

typedef struct NV2AMetalFetchUniforms {
    NV2AMetalFetchAttribute attributes[NV2A_METAL_VP_ATTRIBUTES];
    unsigned int vertex_count;
    unsigned int first_vertex;
    unsigned int index_size;
    /* UINT32_MAX disables the appended Current record. Otherwise this is
     * a full-input ordinal, before index lookup. */
    unsigned int current_vertex;
    /* Accepted Pending vertices precede this full-input ordinal. The GPU emits
     * only the suffix, plus Current even when it selects the cached prefix. */
    unsigned int first_decoded_vertex;
} NV2AMetalFetchUniforms;

#endif
