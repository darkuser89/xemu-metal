/* Layout/state calculations from gl-helpers.cc, rendered solely on Metal4.
 * Copyright (C) 2020-2022 Matt Borgerson
 * SPDX-License-Identifier: GPL-2.0-or-later */
#include "qemu/osdep.h"
#include "rendering.hh"
#include "frontend.h"
#include "frame-images.h"
#include "ui/xemu-notifications.h"
#include "ui/xemu-widescreen.h"
extern "C" {
#include "qapi/error.h"
#include "qemu/error-report.h"
}
#include "data/controller_mask.png.h"
#include "data/controller_mask_s.png.h"
#include "data/logo_sdf.png.h"
#include "data/xemu_64x64.png.h"
#include "data/xmu_mask.png.h"
#include <stb_image.h>
#include <cmath>
#include <climits>

namespace XemuMetal4UI {
Fbo *controller_fbo, *xmu_fbo, *logo_fbo;
uintptr_t g_icon_tex;
static uintptr_t g_controller_duke_tex, g_controller_s_tex, g_logo_tex,
    g_xmu_tex;
struct DecalShader {
    unsigned shader;
    float time;
};
static DecalShader mask_shader = { 0, 0 }, logo_shader = { 2, 0 };
static DecalShader *g_decal_shader = &mask_shader,
                   *g_logo_shader = &logo_shader;
static uintptr_t current_texture;
static unsigned current_blend;
static void must(bool success)
{
    if (!success) {
        fprintf(stderr, "Metal UI rendering: %s\n", xemu_metal4_ui_error());
        abort();
    }
}
Fbo::Fbo(int width, int height) : w(width), h(height)
{
    tex = xemu_metal4_ui_target(width, height);
    must(tex != 0);
}
Fbo::~Fbo()
{
    xemu_metal4_ui_release_texture(tex);
}
void Fbo::Target()
{
    must(xemu_metal4_ui_push_target(tex));
}
void Fbo::Restore()
{
    must(xemu_metal4_ui_pop_target());
}
uintptr_t LoadTextureFromMemory(const unsigned char *bytes, unsigned int size)
{
    if (!bytes || size > INT_MAX)
        return 0;
    stbi_set_flip_vertically_on_load_thread(0);
    int width, height, channels;
    unsigned char *rgba =
        stbi_load_from_memory(bytes, size, &width, &height, &channels, 4);
    if (!rgba)
        return 0;
    uintptr_t result = xemu_metal4_ui_texture(rgba, width, height);
    stbi_image_free(rgba);
    return result;
}
void CleanupCustomRendering()
{
    delete controller_fbo;
    controller_fbo = nullptr;
    delete xmu_fbo;
    xmu_fbo = nullptr;
    delete logo_fbo;
    logo_fbo = nullptr;
    for (uintptr_t *p : { &g_controller_duke_tex, &g_controller_s_tex,
                          &g_logo_tex, &g_xmu_tex, &g_icon_tex }) {
        xemu_metal4_ui_release_texture(*p);
        *p = 0;
    }
    current_texture = 0;
}
void InitCustomRendering()
{
    assert(!controller_fbo && !xmu_fbo && !logo_fbo);
    g_controller_duke_tex =
        LoadTextureFromMemory(controller_mask_data, controller_mask_size);
    g_controller_s_tex =
        LoadTextureFromMemory(controller_mask_s_data, controller_mask_s_size);
    g_xmu_tex = LoadTextureFromMemory(xmu_mask_data, xmu_mask_size);
    g_logo_tex = LoadTextureFromMemory(logo_sdf_data, logo_sdf_size);
    g_icon_tex = LoadTextureFromMemory(xemu_64x64_data, xemu_64x64_size);
    must(g_controller_duke_tex && g_controller_s_tex && g_xmu_tex &&
         g_logo_tex && g_icon_tex);
    controller_fbo = new Fbo(512, 512);
    xmu_fbo = new Fbo(512, 256);
    logo_fbo = new Fbo(512, 512);
}
static void RenderDecal(DecalShader *s, float x, float y, float w, float h,
                        float tx, float ty, float tw, float th,
                        uint32_t primary, uint32_t secondary, uint32_t fill)
{
    uint32_t texture_width, texture_height;
    must(xemu_metal4_ui_texture_size(current_texture, &texture_width,
                                     &texture_height));
    float dst[] = { float(int(x)), float(int(y)), float(int(w)),
                    float(int(h)) };
    /* Keep GL FBO memory-row order: the existing ImGui consumers invert UVs.
     * GL uploaded masks reversed, so translate that bottom-up atlas selection.
     */
    float src[] = { float(int(tx)),
                    float(int(texture_height) - int(ty) - int(th)),
                    float(int(tw)), float(int(th)) };
    must(xemu_metal4_ui_decal(current_texture, dst, src, primary, secondary,
                              fill, s->time / 1000.f, true, s->shader,
                              current_blend));
}
struct rect {
    int x, y, w, h;
};

static const struct rect tex_items[] = {
    { 0, 148, 467, 364 }, // obj_controller
    { 0, 81, 67, 67 }, // obj_lstick
    { 0, 14, 67, 67 }, // obj_rstick
    { 67, 104, 68, 44 }, // obj_port_socket
    { 67, 76, 28, 28 }, // obj_port_lbl_1
    { 67, 48, 28, 28 }, // obj_port_lbl_2
    { 67, 20, 28, 28 }, // obj_port_lbl_3
    { 95, 76, 28, 28 }, // obj_port_lbl_4
    { 0, 0, 512, 512 } // obj_xmu
};

enum tex_item_names {
    obj_controller,
    obj_lstick,
    obj_rstick,
    obj_port_socket,
    obj_port_lbl_1,
    obj_port_lbl_2,
    obj_port_lbl_3,
    obj_port_lbl_4,
    obj_xmu
};

static void RenderMeter(DecalShader *s, float x, float y, float width,
                        float height, float p, uint32_t color_bg,
                        uint32_t color_fg)
{
    RenderDecal(s, x, y, width, height, 0, 0, 1, 1, 0, 0, color_bg);
    RenderDecal(s, x, y, width * p, height, 0, 0, 1, 1, 0, 0, color_fg);
}

static void RenderDukeController(float frame_x, float frame_y,
                                 uint32_t primary_color,
                                 uint32_t secondary_color,
                                 ControllerState *state)
{
    // Location within the controller texture of masked button locations,
    // relative to the origin of the controller
    const struct rect jewel = { 177, 172, 113, 118 };
    const struct rect lstick_ctr = { 93, 246, 0, 0 };
    const struct rect rstick_ctr = { 342, 148, 0, 0 };
    const struct rect buttons[12] = {
        { 367, 187, 30, 38 }, // A
        { 368, 229, 30, 38 }, // B
        { 330, 204, 30, 38 }, // X
        { 331, 247, 30, 38 }, // Y
        { 82, 121, 31, 47 }, // D-Left
        { 104, 160, 44, 25 }, // D-Up
        { 141, 121, 31, 47 }, // D-Right
        { 104, 105, 44, 25 }, // D-Down
        { 187, 94, 34, 24 }, // Back
        { 246, 94, 36, 26 }, // Start
        { 348, 288, 30, 38 }, // White
        { 386, 268, 30, 38 }, // Black
    };

    uint8_t alpha = 0;
    uint32_t now = SDL_GetTicks();
    float t;


    current_texture = g_controller_duke_tex;

    // Add a 5 pixel space around the controller so we can wiggle the controller
    // around to visualize rumble in action
    frame_x += 5;
    frame_y += 5;
    float original_frame_x = frame_x;
    float original_frame_y = frame_y;

    // Floating point versions that will get scaled
    float rumble_l = 0;
    float rumble_r = 0;


    current_blend = 0;

    uint32_t jewel_color = secondary_color;

    // Check to see if the guide button is pressed
    const uint32_t animate_guide_button_duration = 2000;
    if (state->buttons & CONTROLLER_BUTTON_GUIDE) {
        state->animate_guide_button_end = now + animate_guide_button_duration;
    }

    if (now < state->animate_guide_button_end) {
        t = 1.0f - (float)(state->animate_guide_button_end - now) /
                       (float)animate_guide_button_duration;
        float sin_wav = (1 - sin(M_PI * t / 2.0f));

        // Animate guide button by highlighting logo jewel and fading out over
        // time
        alpha = sin_wav * 255.0f;
        jewel_color = primary_color + alpha;

        // Add a little extra flare: wiggle the frame around while we rumble
        frame_x += ((float)(rand() % 5) - 2.5) * (1 - t);
        frame_y += ((float)(rand() % 5) - 2.5) * (1 - t);
        rumble_l = rumble_r = sin_wav;
    }

    // Render controller texture
    RenderDecal(g_decal_shader, frame_x + 0, frame_y + 0,
                tex_items[obj_controller].w, tex_items[obj_controller].h,
                tex_items[obj_controller].x, tex_items[obj_controller].y,
                tex_items[obj_controller].w, tex_items[obj_controller].h,
                primary_color, secondary_color, 0);

    current_blend = 2; // Blend with controller cutouts
    RenderDecal(g_decal_shader, frame_x + jewel.x, frame_y + jewel.y, jewel.w,
                jewel.h, 0, 0, 1, 1, 0, 0, jewel_color);

    // The controller has alpha cutouts where the buttons are. Draw a surface
    // behind the buttons if they are activated
    for (int i = 0; i < 12; i++) {
        if (state->buttons & (1 << i)) {
            RenderDecal(g_decal_shader, frame_x + buttons[i].x,
                        frame_y + buttons[i].y, buttons[i].w, buttons[i].h, 0,
                        0, 1, 1, 0, 0, primary_color + 0xff);
        }
    }

    current_blend = 1; // Blend with controller

    // Render left thumbstick
    float w = tex_items[obj_lstick].w;
    float h = tex_items[obj_lstick].h;
    float c_x = frame_x + lstick_ctr.x;
    float c_y = frame_y + lstick_ctr.y;
    float lstick_x = (float)state->axis[CONTROLLER_AXIS_LSTICK_X] / 32768.0;
    float lstick_y = (float)state->axis[CONTROLLER_AXIS_LSTICK_Y] / 32768.0;
    RenderDecal(g_decal_shader, (int)(c_x - w / 2.0f + 10.0f * lstick_x),
                (int)(c_y - h / 2.0f + 10.0f * lstick_y), w, h,
                tex_items[obj_lstick].x, tex_items[obj_lstick].y, w, h,
                (state->buttons & CONTROLLER_BUTTON_LSTICK) ? secondary_color :
                                                              primary_color,
                (state->buttons & CONTROLLER_BUTTON_LSTICK) ? primary_color :
                                                              secondary_color,
                0);

    // Render right thumbstick
    w = tex_items[obj_rstick].w;
    h = tex_items[obj_rstick].h;
    c_x = frame_x + rstick_ctr.x;
    c_y = frame_y + rstick_ctr.y;
    float rstick_x = (float)state->axis[CONTROLLER_AXIS_RSTICK_X] / 32768.0;
    float rstick_y = (float)state->axis[CONTROLLER_AXIS_RSTICK_Y] / 32768.0;
    RenderDecal(g_decal_shader, (int)(c_x - w / 2.0f + 10.0f * rstick_x),
                (int)(c_y - h / 2.0f + 10.0f * rstick_y), w, h,
                tex_items[obj_rstick].x, tex_items[obj_rstick].y, w, h,
                (state->buttons & CONTROLLER_BUTTON_RSTICK) ? secondary_color :
                                                              primary_color,
                (state->buttons & CONTROLLER_BUTTON_RSTICK) ? primary_color :
                                                              secondary_color,
                0);

    current_blend = 0; // Don't blend, just overwrite values in buffer

    // Render trigger bars
    float ltrig = state->axis[CONTROLLER_AXIS_LTRIG] / 32767.0;
    float rtrig = state->axis[CONTROLLER_AXIS_RTRIG] / 32767.0;
    const uint32_t animate_trigger_duration = 1000;
    if ((ltrig > 0) || (rtrig > 0)) {
        state->animate_trigger_end = now + animate_trigger_duration;
        rumble_l = fmax(rumble_l, ltrig);
        rumble_r = fmax(rumble_r, rtrig);
    }

    // Animate trigger alpha down after a period of inactivity
    alpha = 0x80;
    if (state->animate_trigger_end > now) {
        t = 1.0f - (float)(state->animate_trigger_end - now) /
                       (float)animate_trigger_duration;
        float sin_wav = (1 - sin(M_PI * t / 2.0f));
        alpha += fmin(sin_wav * 0x40, 0x80);
    }

    RenderMeter(g_decal_shader, original_frame_x + 10,
                original_frame_y + tex_items[obj_controller].h + 20, 150, 5,
                ltrig, primary_color + alpha, primary_color + 0xff);
    RenderMeter(g_decal_shader,
                original_frame_x + tex_items[obj_controller].w - 160,
                original_frame_y + tex_items[obj_controller].h + 20, 150, 5,
                rtrig, primary_color + alpha, primary_color + 0xff);

    // Apply rumble updates
    state->rumble_l = (int)(rumble_l * (float)0xffff);
    state->rumble_r = (int)(rumble_r * (float)0xffff);
}

static void RenderControllerS(float frame_x, float frame_y,
                              uint32_t primary_color, uint32_t secondary_color,
                              ControllerState *state)
{
    // Location within the controller texture of masked button locations,
    // relative to the origin of the controller
    const struct rect jewel = { 194, 213, 84, 84 };
    const struct rect lstick_ctr = { 103, 254, 0, 0 };
    const struct rect rstick_ctr = { 295, 176, 0, 0 };
    const struct rect buttons[12] = {
        { 347, 200, 34, 34 }, // A
        { 381, 235, 34, 34 }, // B
        { 313, 235, 34, 34 }, // X
        { 347, 270, 34, 34 }, // Y
        { 123, 165, 31, 26 }, // D-Left
        { 150, 187, 26, 31 }, // D-Up
        { 173, 165, 31, 26 }, // D-Right
        { 150, 135, 26, 31 }, // D-Down
        { 45, 195, 20, 24 }, // Back
        { 70, 163, 26, 26 }, // Start
        { 352, 145, 30, 30 }, // White
        { 388, 172, 30, 30 }, // Black
    };

    uint8_t alpha = 0;
    uint32_t now = SDL_GetTicks();
    float t;


    current_texture = g_controller_s_tex;

    // Add a 5 pixel space around the controller so we can wiggle the controller
    // around to visualize rumble in action
    frame_x += 5;
    frame_y += 5;
    float original_frame_x = frame_x;
    float original_frame_y = frame_y;

    // Floating point versions that will get scaled
    float rumble_l = 0;
    float rumble_r = 0;


    current_blend = 0;

    uint32_t jewel_color = secondary_color;

    // Check to see if the guide button is pressed
    const uint32_t animate_guide_button_duration = 2000;
    if (state->buttons & CONTROLLER_BUTTON_GUIDE) {
        state->animate_guide_button_end = now + animate_guide_button_duration;
    }

    if (now < state->animate_guide_button_end) {
        t = 1.0f - (float)(state->animate_guide_button_end - now) /
                       (float)animate_guide_button_duration;
        float sin_wav = (1 - sin(M_PI * t / 2.0f));

        // Animate guide button by highlighting logo jewel and fading out over
        // time
        alpha = sin_wav * 255.0f;
        jewel_color = primary_color + alpha;

        // Add a little extra flare: wiggle the frame around while we rumble
        frame_x += ((float)(rand() % 5) - 2.5) * (1 - t);
        frame_y += ((float)(rand() % 5) - 2.5) * (1 - t);
        rumble_l = rumble_r = sin_wav;
    }

    // Render controller texture
    RenderDecal(g_decal_shader, frame_x + 0, frame_y + 0,
                tex_items[obj_controller].w, tex_items[obj_controller].h,
                tex_items[obj_controller].x, tex_items[obj_controller].y,
                tex_items[obj_controller].w, tex_items[obj_controller].h,
                primary_color, secondary_color, 0);

    current_blend = 2; // Blend with controller cutouts
    RenderDecal(g_decal_shader, frame_x + jewel.x, frame_y + jewel.y, jewel.w,
                jewel.h, 0, 0, 1, 1, 0, 0, jewel_color);

    // The controller has alpha cutouts where the buttons are. Draw a surface
    // behind the buttons if they are activated
    for (int i = 0; i < 12; i++) {
        if (state->buttons & (1 << i)) {
            RenderDecal(g_decal_shader, frame_x + buttons[i].x,
                        frame_y + buttons[i].y, buttons[i].w, buttons[i].h, 0,
                        0, 1, 1, 0, 0, primary_color + 0xff);
        }
    }

    current_blend = 1; // Blend with controller

    // Render left thumbstick
    float w = tex_items[obj_lstick].w;
    float h = tex_items[obj_lstick].h;
    float c_x = frame_x + lstick_ctr.x;
    float c_y = frame_y + lstick_ctr.y;
    float lstick_x = (float)state->axis[CONTROLLER_AXIS_LSTICK_X] / 32768.0;
    float lstick_y = (float)state->axis[CONTROLLER_AXIS_LSTICK_Y] / 32768.0;
    RenderDecal(g_decal_shader, (int)(c_x - w / 2.0f + 10.0f * lstick_x),
                (int)(c_y - h / 2.0f + 10.0f * lstick_y), w, h,
                tex_items[obj_lstick].x, tex_items[obj_lstick].y, w, h,
                (state->buttons & CONTROLLER_BUTTON_LSTICK) ? secondary_color :
                                                              primary_color,
                (state->buttons & CONTROLLER_BUTTON_LSTICK) ? primary_color :
                                                              secondary_color,
                0);

    // Render right thumbstick
    w = tex_items[obj_rstick].w;
    h = tex_items[obj_rstick].h;
    c_x = frame_x + rstick_ctr.x;
    c_y = frame_y + rstick_ctr.y;
    float rstick_x = (float)state->axis[CONTROLLER_AXIS_RSTICK_X] / 32768.0;
    float rstick_y = (float)state->axis[CONTROLLER_AXIS_RSTICK_Y] / 32768.0;
    RenderDecal(g_decal_shader, (int)(c_x - w / 2.0f + 10.0f * rstick_x),
                (int)(c_y - h / 2.0f + 10.0f * rstick_y), w, h,
                tex_items[obj_rstick].x, tex_items[obj_rstick].y, w, h,
                (state->buttons & CONTROLLER_BUTTON_RSTICK) ? secondary_color :
                                                              primary_color,
                (state->buttons & CONTROLLER_BUTTON_RSTICK) ? primary_color :
                                                              secondary_color,
                0);

    current_blend = 0; // Don't blend, just overwrite values in buffer

    // Render trigger bars
    float ltrig = state->axis[CONTROLLER_AXIS_LTRIG] / 32767.0;
    float rtrig = state->axis[CONTROLLER_AXIS_RTRIG] / 32767.0;
    const uint32_t animate_trigger_duration = 1000;
    if ((ltrig > 0) || (rtrig > 0)) {
        state->animate_trigger_end = now + animate_trigger_duration;
        rumble_l = fmax(rumble_l, ltrig);
        rumble_r = fmax(rumble_r, rtrig);
    }

    // Animate trigger alpha down after a period of inactivity
    alpha = 0x80;
    if (state->animate_trigger_end > now) {
        t = 1.0f - (float)(state->animate_trigger_end - now) /
                       (float)animate_trigger_duration;
        float sin_wav = (1 - sin(M_PI * t / 2.0f));
        alpha += fmin(sin_wav * 0x40, 0x80);
    }

    RenderMeter(g_decal_shader, original_frame_x + 10,
                original_frame_y + tex_items[obj_controller].h + 20, 150, 5,
                ltrig, primary_color + alpha, primary_color + 0xff);
    RenderMeter(g_decal_shader,
                original_frame_x + tex_items[obj_controller].w - 160,
                original_frame_y + tex_items[obj_controller].h + 20, 150, 5,
                rtrig, primary_color + alpha, primary_color + 0xff);

    // Apply rumble updates
    state->rumble_l = (int)(rumble_l * (float)0xffff);
    state->rumble_r = (int)(rumble_r * (float)0xffff);
}

void RenderController(float frame_x, float frame_y, uint32_t primary_color,
                      uint32_t secondary_color, ControllerState *state)
{
    if (strcmp(bound_drivers[state->bound], DRIVER_S) == 0)
        RenderControllerS(frame_x, frame_y, primary_color, secondary_color,
                          state);
    else if (strcmp(bound_drivers[state->bound], DRIVER_DUKE) == 0)
        RenderDukeController(frame_x, frame_y, primary_color, secondary_color,
                             state);
}

void RenderControllerPort(float frame_x, float frame_y, int i,
                          uint32_t port_color)
{
    current_texture = g_controller_duke_tex;
    current_blend = 0;

    // Render port socket
    RenderDecal(g_decal_shader, frame_x, frame_y, tex_items[obj_port_socket].w,
                tex_items[obj_port_socket].h, tex_items[obj_port_socket].x,
                tex_items[obj_port_socket].y, tex_items[obj_port_socket].w,
                tex_items[obj_port_socket].h, port_color, port_color, 0);

    frame_x += (tex_items[obj_port_socket].w - tex_items[obj_port_lbl_1].w) / 2;
    frame_y += tex_items[obj_port_socket].h + 8;

    // Render port label
    RenderDecal(
        g_decal_shader, frame_x, frame_y, tex_items[obj_port_lbl_1 + i].w,
        tex_items[obj_port_lbl_1 + i].h, tex_items[obj_port_lbl_1 + i].x,
        tex_items[obj_port_lbl_1 + i].y, tex_items[obj_port_lbl_1 + i].w,
        tex_items[obj_port_lbl_1 + i].h, port_color, port_color, 0);
}

void RenderXmu(float frame_x, float frame_y, uint32_t primary_color,
               uint32_t secondary_color)
{
    current_texture = g_xmu_tex;

    current_blend = 0;

    // Render xmu
    RenderDecal(g_decal_shader, frame_x, frame_y, 256, 256,
                tex_items[obj_xmu].x, tex_items[obj_xmu].y,
                tex_items[obj_xmu].w, tex_items[obj_xmu].h, primary_color,
                secondary_color, 0);
}

void RenderLogo(uint32_t time)
{
    uint32_t color = 0x62ca13ff;

    g_logo_shader->time = time;


    current_blend = 0;

    current_texture = g_logo_tex;
    RenderDecal(g_logo_shader, 0, 0, 512, 512, 0, 0, 128, 128, color, color,
                0x00000000);
}

// Scale <src> proportionally to fit in <max>
void ScaleDimensions(int src_width, int src_height, int max_width,
                     int max_height, int *out_width, int *out_height)
{
    float w_ratio = (float)max_width / (float)max_height;
    float t_ratio = (float)src_width / (float)src_height;

    if (w_ratio >= t_ratio) {
        *out_width = (float)max_width * t_ratio / w_ratio;
        *out_height = max_height;
    } else {
        *out_width = max_width;
        *out_height = (float)max_height * w_ratio / t_ratio;
    }
}

static float GetDisplayAspectRatio(int width, int height)
{
    switch (g_config.display.ui.aspect_ratio) {
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_NATIVE:
        return (float)width / (float)height;
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_16X9:
        return 16.0f / 9.0f;
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_4X3:
        return 4.0f / 3.0f;
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_AUTO:
    default:
        return xemu_get_widescreen() ? 16.0f / 9.0f : 4.0f / 3.0f;
    }
}

void RenderFramebuffer(uintptr_t, int, int, bool, float scale[2])
{
    must(xemu_metal4_ui_framebuffer(scale[0], scale[1],
                                    g_config.display.filtering ==
                                        CONFIG_DISPLAY_FILTERING_LINEAR));
}
void RenderFramebuffer(uintptr_t tex, int width, int height, bool flip)
{
    if (width <= 0 || height <= 0)
        return;
    uint32_t tw, th;
    if (!tex || !xemu_metal4_ui_texture_size(tex, &tw, &th)) {
        float scale[] = { 1, 1 };
        RenderFramebuffer(tex, width, height, flip, scale);
        return;
    }
    float scale[2], ratio = GetDisplayAspectRatio(tw, th);
    if (g_config.display.ui.fit == CONFIG_DISPLAY_UI_FIT_STRETCH) {
        scale[0] = scale[1] = 1;
    } else if (g_config.display.ui.fit == CONFIG_DISPLAY_UI_FIT_CENTER) {
        scale[0] = ratio * th / width;
        scale[1] = float(th) / height;
    } else {
        float window_ratio = float(width) / height;
        scale[0] = window_ratio >= ratio ? ratio / window_ratio : 1;
        scale[1] = window_ratio >= ratio ? 1 : window_ratio / ratio;
    }
    RenderFramebuffer(tex, width, height, flip, scale);
}
bool RenderFramebufferToPng(uintptr_t, bool, std::vector<uint8_t> &png,
                            int max_width, int max_height)
{
    png.clear();
    if (max_width < 0 || max_height < 0)
        return false;
    float aspect = g_config.display.ui.aspect_ratio ==
                           CONFIG_DISPLAY_UI_ASPECT_RATIO_NATIVE ?
                       0 :
                       GetDisplayAspectRatio(1, 1);
    size_t size = 0;
    void *bytes = xemu_metal4_capture_png(
        aspect, max_width, max_height,
        g_config.display.filtering == CONFIG_DISPLAY_FILTERING_LINEAR, &size);
    if (!bytes)
        return false;
    png.assign((uint8_t *)bytes, (uint8_t *)bytes + size);
    free(bytes);
    return true;
}
void SaveScreenshot(uintptr_t tex, bool flip)
{
    Error *err = NULL;
    char fname[128];
    std::vector<uint8_t> png;

    if (RenderFramebufferToPng(tex, flip, png)) {
        time_t t = time(NULL);
        struct tm calendar;
        char stem[96];
        if (!localtime_r(&t, &calendar) ||
            !strftime(stem, sizeof(stem), "xemu-%Y-%m-%d-%H-%M-%S",
                      &calendar)) {
            strcpy(stem, "xemu");
        }

        const char *output_dir = g_config.general.screenshot_dir;
        if (!strlen(output_dir)) {
            output_dir = ".";
        }
        char *path = nullptr;
        FILE *fd = nullptr;
        for (unsigned suffix = 0;; suffix++) {
            if (suffix)
                g_snprintf(fname, sizeof(fname), "%s-%u.png", stem, suffix);
            else
                g_snprintf(fname, sizeof(fname), "%s.png", stem);
            path = g_strdup_printf("%s/%s", output_dir, fname);
            // Exclusive creation also closes the race between separate callers.
            fd = qemu_fopen(path, "wbx");
            if (fd || errno != EEXIST || suffix == UINT_MAX)
                break;
            g_free(path);
        }
        if (fd) {
            size_t written = fwrite(png.data(), 1, png.size(), fd);
            if (written != png.size()) {
                error_setg_errno(&err, errno, "Failed to write %s", path);
            }
            if (fclose(fd) != 0 && !err) {
                error_setg_errno(&err, errno, "Failed to close %s", path);
            }
        } else {
            error_setg(&err, "Failed to open %s for writing", path);
        }
        g_free(path);
    } else {
        error_setg(&err, "Failed to encode PNG image");
    }

    if (err) {
        xemu_queue_error_message(error_get_pretty(err));
        error_report_err(err);
    } else {
        char *msg = g_strdup_printf("Screenshot Saved: %s", fname);
        xemu_queue_notification(msg);
        free(msg);
    }
}

} // namespace XemuMetal4UI
