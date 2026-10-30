/* Native replacements for the existing UI rendering helpers.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <cstdint>
#include <vector>
#include "ui/xemu-input.h"

namespace XemuMetal4UI {
class Fbo {
public:
    int w, h;
    uintptr_t tex;
    Fbo(int width, int height);
    ~Fbo();
    Fbo(const Fbo &) = delete;
    Fbo &operator=(const Fbo &) = delete;
    uintptr_t Texture() const
    {
        return tex;
    }
    void Target();
    void Restore();
};
extern Fbo *controller_fbo, *xmu_fbo, *logo_fbo;
extern uintptr_t g_icon_tex;
void InitCustomRendering();
void CleanupCustomRendering();
uintptr_t LoadTextureFromMemory(const unsigned char *bytes, unsigned int size);
void RenderLogo(uint32_t time);
void RenderController(float x, float y, uint32_t primary, uint32_t secondary,
                      ControllerState *state);
void RenderControllerPort(float x, float y, int port, uint32_t color);
void RenderXmu(float x, float y, uint32_t primary, uint32_t secondary);
void RenderFramebuffer(uintptr_t texture, int width, int height, bool flip);
void RenderFramebuffer(uintptr_t texture, int width, int height, bool flip,
                       float scale[2]);
bool RenderFramebufferToPng(uintptr_t texture, bool flip,
                            std::vector<uint8_t> &png, int max_width = 0,
                            int max_height = 0);
void SaveScreenshot(uintptr_t texture, bool flip);
void ScaleDimensions(int width, int height, int max_width, int max_height,
                     int *out_width, int *out_height);
} // namespace XemuMetal4UI
