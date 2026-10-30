/*
 * xemu User Interface
 *
 * Copyright (C) 2020-2022 Matt Borgerson
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <cstdint>
#include <fpng.h>
#include <vector>

#include "xemu-snapshots.h"
#include "xui/gl-helpers.hh"
#ifdef XEMU_NATIVE_METAL4_UI
#include "xui/metal4/frontend.h"
#endif
#include "xemu-settings.h"

static XemuTexture display_tex = 0;
static bool display_flip = false;

#if defined(__APPLE__) && defined(__aarch64__)
#include "xemu-widescreen.h"
#include "xui/metal4/frame-images.h"

void xemu_snapshots_set_metal4_framebuffer(void *frame)
{
    xemu_metal4_set_capture_frame(frame);
}
#endif

void xemu_snapshots_set_framebuffer_texture(XemuTexture tex, bool flip)
{
    display_tex = tex;
    display_flip = flip;
}

XemuTexture xemu_snapshots_load_png_to_texture(void *buf, size_t size)
{
    std::vector<uint8_t> pixels;
    unsigned int width, height, channels;
#ifdef XEMU_NATIVE_METAL4_UI
    if (xemu_hud_uses_metal4()) {
        if (!buf || size > UINT32_MAX ||
            fpng::fpng_get_info(buf, size, width, height, channels) !=
                fpng::FPNG_DECODE_SUCCESS ||
            !width || !height || width > 16384 || height > 16384) {
            return 0;
        }
        if (fpng::fpng_decode_memory(buf, size, pixels, width, height, channels,
                                     4) != fpng::FPNG_DECODE_SUCCESS) {
            return 0;
        }
        return xemu_metal4_ui_texture(pixels.data(), width, height);
    } else
#endif
    {
        if (fpng::fpng_decode_memory(buf, size, pixels, width, height, channels,
                                     3) != fpng::FPNG_DECODE_SUCCESS) {
            return 0;
        }

        GLuint tex;
        glGenTextures(1, &tex);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex);

        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);

        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, width, height, 0, GL_RGB,
                     GL_UNSIGNED_BYTE, pixels.data());

        return tex;
    }
}

void xemu_snapshots_release_texture(XemuTexture texture)
{
#ifdef XEMU_NATIVE_METAL4_UI
    if (xemu_hud_uses_metal4()) {
        xemu_metal4_ui_release_texture(texture);
    } else
#endif
    {
        GLuint gl_texture = texture;
        glDeleteTextures(1, &gl_texture);
    }
}

void *xemu_snapshots_create_framebuffer_thumbnail_png(size_t *size)
{
    if (!size) {
        return NULL;
    }
    *size = 0;
#ifdef XEMU_NATIVE_METAL4_UI
    if (xemu_hud_uses_metal4()) {
        if (xemu_metal4_has_capture_frame()) {
            float aspect;
            switch (g_config.display.ui.aspect_ratio) {
            case CONFIG_DISPLAY_UI_ASPECT_RATIO_NATIVE:
                aspect = 0;
                break;
            case CONFIG_DISPLAY_UI_ASPECT_RATIO_16X9:
                aspect = 16.f / 9;
                break;
            case CONFIG_DISPLAY_UI_ASPECT_RATIO_4X3:
                aspect = 4.f / 3;
                break;
            default:
                aspect = xemu_get_widescreen() ? 16.f / 9 : 4.f / 3;
                break;
            }
            bool linear =
                g_config.display.filtering == CONFIG_DISPLAY_FILTERING_LINEAR;
            return xemu_metal4_capture_png(
                aspect, 2 * XEMU_SNAPSHOT_THUMBNAIL_WIDTH,
                2 * XEMU_SNAPSHOT_THUMBNAIL_HEIGHT, linear, size);
        }
        return NULL;
    }
#endif
    /*
     * Avoids crashing if a snapshot is made on a thread with no GL context
     * Normally, this is not an issue, but it is better to fail safe than assert
     * here.
     * FIXME: Allow for dispatching a thumbnail request to the UI thread to
     * remove this altogether.
     */
    if (!SDL_GL_GetCurrentContext() || display_tex == 0) {
        return NULL;
    }

    std::vector<uint8_t> png;
    if (!RenderFramebufferToPng(display_tex, display_flip, png,
                                2 * XEMU_SNAPSHOT_THUMBNAIL_WIDTH,
                                2 * XEMU_SNAPSHOT_THUMBNAIL_HEIGHT)) {
        return NULL;
    }

    void *buf = g_malloc(png.size());
    memcpy(buf, png.data(), png.size());
    *size = png.size();
    return buf;
}
