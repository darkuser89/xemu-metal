/* Internal decoder modes follow the existing VGA fallback, not NV registers.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VGA_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VGA_TYPES_H
/* mode0: doubled 256-color pixels; mode2/4: four-/sixteen-color planes. */
typedef struct NV2AMetalVGARow {
    unsigned int address, hpel;
} NV2AMetalVGARow;
typedef struct NV2AMetalVGAUniforms {
    unsigned int width, height, mode, duplicate;
    unsigned int memory_mask, plane_mask, big_endian, reserved;
    unsigned int palette[256];
    unsigned int text_columns, character_width, character_height;
    unsigned int font_offset[2], cursor_address, cursor_start, cursor_end;
    unsigned int cursor_visible, line_graphics;
} NV2AMetalVGAUniforms;
#endif
