/* SPDX-License-Identifier: GPL-2.0-or-later */

#ifndef XEMU_UI_METAL4_DECAL_UNIFORMS_H
#define XEMU_UI_METAL4_DECAL_UNIFORMS_H

typedef struct XemuMetal4DecalUniforms {
    float position[4];
    float texture[4];
    float primary[4];
    float secondary[4];
    float fill[4];
    float target_height;
    float time;
    unsigned int flip_y;
    unsigned int reserved;
} XemuMetal4DecalUniforms;

#endif
