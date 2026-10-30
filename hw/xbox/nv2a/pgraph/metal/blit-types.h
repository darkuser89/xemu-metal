/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_BLIT_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_BLIT_TYPES_H
/* Physical/logical start addresses select each row's memmove direction when
 * separate Metal buffers alias the same shared RAM. Not GPU dereference values.
 */
typedef struct NV2AMetalBlitUniforms {
    unsigned long source_address, destination_address;
    unsigned int source_offset, destination_offset, source_pitch,
        destination_pitch;
    unsigned int row_bytes, rows, tail_bytes, operation, beta, bytes_per_pixel;
    unsigned int patch_alpha, alpha_value;
} NV2AMetalBlitUniforms;
#endif
