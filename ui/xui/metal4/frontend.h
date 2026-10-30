/* Native UI session; SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef XEMU_UI_METAL4_FRONTEND_H
#define XEMU_UI_METAL4_FRONTEND_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
typedef struct SDL_Window SDL_Window;
struct ImDrawData;
#ifdef __cplusplus
extern "C" {
#endif
/* One UI/ImGui session on the main thread. NULL window permits offscreen
 * rendering. Create after ImGui::CreateContext, close before DestroyContext. */
bool xemu_metal4_ui_init(SDL_Window *window, bool vsync);
bool xemu_metal4_ui_close(void);
const char *xemu_metal4_ui_error(void);
const char *xemu_metal4_ui_device_name(void);
bool xemu_metal4_ui_set_vsync(bool vsync);
bool xemu_metal4_ui_new_frame(void);
void xemu_metal4_ui_invalidate_fonts(void);
/* SDL's C main loop can execute its complete frame inside an ObjC pool. */
void xemu_metal4_ui_with_pool(void (*callback)(void *), void *opaque);
/* Borrowed immutable NV2AMetalFramebuffer; the session retains its snapshot. */
bool xemu_metal4_ui_set_frame(void *frame);
uintptr_t xemu_metal4_ui_frame_texture(void);
/* target=0 obtains the window drawable. An offscreen session requires a
 * target. Hidden windows still allow offscreen asset updates in this frame. */
bool xemu_metal4_ui_begin(uintptr_t target);
bool xemu_metal4_ui_end(const struct ImDrawData *draw_data);
void xemu_metal4_ui_cancel(void);
bool xemu_metal4_ui_framebuffer(float scale_x, float scale_y, bool linear);
/* Texture handles are owned MTLTexture pointers, also valid ImTextureIDs.
 * Data are already RGBA8, top row first. No CPU conversion or vertical flip. */
uintptr_t xemu_metal4_ui_texture(const void *rgba, uint32_t width,
                                 uint32_t height);
uintptr_t xemu_metal4_ui_target(uint32_t width, uint32_t height);
void xemu_metal4_ui_release_texture(uintptr_t texture);
bool xemu_metal4_ui_texture_size(uintptr_t texture, uint32_t *width,
                                 uint32_t *height);
bool xemu_metal4_ui_push_target(uintptr_t target);
bool xemu_metal4_ui_pop_target(void);
/* Rects are top-left x/y/w/h. shader=0 mask,1 logo,2 UI-FBO logo;
 * blend=0 replace,1 alpha,
 * 2 cutout. Colors use 0xRRGGBBAA. Pending decals flush before target changes.
 */
bool xemu_metal4_ui_decal(uintptr_t texture, const float destination[4],
                          const float source[4], uint32_t primary,
                          uint32_t secondary, uint32_t fill, float time,
                          bool flip_y, unsigned shader, unsigned blend);
#ifdef __cplusplus
}
#endif
#endif
