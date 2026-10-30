/* Complete offscreen UI frame without SDL initialization or a window.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "ui/xui/metal4/frontend.h"
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#include <imgui.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <thread>

@interface FrontendFrame : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) NV2AMetalDisplayUniforms displayUniforms;
@property(nonatomic) BOOL screenOff;
@end
@implementation FrontendFrame
@end

static void ok(bool success)
{
    if (!success) {
        std::fprintf(stderr, "Native UI: %s\n", xemu_metal4_ui_error());
        std::abort();
    }
}
static void pixel(const uint8_t *data, unsigned x, unsigned y, unsigned r,
                  unsigned g, unsigned b)
{
    const uint8_t *p = data + (y * 4 + x) * 4;
    if (p[0] != b || p[1] != g || p[2] != r || p[3] != 255) {
        std::fprintf(stderr,
                     "UI pixel %u,%u: BGRA %u,%u,%u,%u; expected "
                     "%u,%u,%u,255\n",
                     x, y, p[0], p[1], p[2], p[3], b, g, r);
        std::abort();
    }
}
int main()
{
    @autoreleasepool {
        assert(!xemu_metal4_ui_init(nullptr, false));
        ImGui::CreateContext();
        ok(xemu_metal4_ui_init(nullptr, false));
        assert(!xemu_metal4_ui_init(nullptr, false));
        assert(xemu_metal4_ui_device_name()[0]);
        std::thread other([] { assert(!xemu_metal4_ui_new_frame()); });
        other.join();
        unsigned pool_calls = 0;
        xemu_metal4_ui_with_pool([](void *opaque) { ++*(unsigned *)opaque; },
                                 &pool_calls);
        assert(pool_calls == 1);
        ok(xemu_metal4_ui_set_vsync(true));
        ok(xemu_metal4_ui_new_frame());
        ImTextureID first_font = ImGui::GetIO().Fonts->TexID;
        assert(first_font);
        xemu_metal4_ui_invalidate_fonts();
        assert(!ImGui::GetIO().Fonts->TexID);
        ok(xemu_metal4_ui_new_frame());
        assert(ImGui::GetIO().Fonts->TexID);

        const uint8_t corners[] = { 255, 0, 0,   255, 0,   255, 0,   255,
                                    0,   0, 255, 255, 255, 255, 255, 255 };
        uintptr_t source = xemu_metal4_ui_texture(corners, 2, 2);
        assert(source);
        uint32_t w, h;
        ok(xemu_metal4_ui_texture_size(source, &w, &h));
        assert(w == 2 && h == 2);
        assert(!xemu_metal4_ui_texture(nullptr, 1, 1));
        assert(!xemu_metal4_ui_target(0, 1));
        assert(!xemu_metal4_ui_target(20000, 1));
        FrontendFrame *frame = [FrontendFrame new];
        frame.texture = (__bridge id<MTLTexture>)(void *)source;
        NV2AMetalDisplayUniforms u = { .scale = { 1, 1 } };
        for (unsigned i = 0; i < 256; i++)
            u.palette[i] = i | (i << 8) | (i << 16);
        frame.displayUniforms = u;
        ok(xemu_metal4_ui_set_frame((__bridge void *)frame));
        assert(xemu_metal4_ui_frame_texture() == source);
        frame = nil;
        xemu_metal4_ui_release_texture(source);

        id<MTLDevice> device =
            ((__bridge id<MTLTexture>)(void *)xemu_metal4_ui_frame_texture())
                .device;
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:4
                                        height:4
                                     mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        uintptr_t handle = (uintptr_t)(__bridge void *)target;
        assert(!xemu_metal4_ui_begin(0));
        ok(xemu_metal4_ui_begin(handle));
        assert(!xemu_metal4_ui_begin(handle));
        ok(xemu_metal4_ui_framebuffer(1, 1, false));

        uintptr_t parent = xemu_metal4_ui_target(2, 2);
        uintptr_t child = xemu_metal4_ui_target(1, 1);
        const uint8_t mask[] = { 255, 0, 0, 255, 255, 0, 0, 255,
                                 255, 0, 0, 255, 255, 0, 0, 255 };
        uintptr_t mask_texture = xemu_metal4_ui_texture(mask, 2, 2);
        const float region[] = { 0, 0, 1, 1 }, whole[] = { 0, 0, 2, 2 };
        ok(xemu_metal4_ui_push_target(parent));
        ok(xemu_metal4_ui_decal(mask_texture, whole, whole, 0x00ff00ff, 0, 0, 0,
                                false, 0, 0));
        ok(xemu_metal4_ui_push_target(child));
        ok(xemu_metal4_ui_decal(mask_texture, region, whole, 0x0000ffff, 0, 0,
                                0, false, 0, 0));
        assert(!xemu_metal4_ui_end(nullptr));
        ok(xemu_metal4_ui_pop_target());
        ok(xemu_metal4_ui_decal(mask_texture, region, whole, 0xff0000ff, 0, 0,
                                0, false, 0, 0));
        xemu_metal4_ui_release_texture(mask_texture);
        ok(xemu_metal4_ui_pop_target());
        assert(!xemu_metal4_ui_pop_target());
        ImGuiIO &io = ImGui::GetIO();
        io.DisplaySize = ImVec2(4, 4);
        io.IniFilename = nullptr;
        ImGui::NewFrame();
        ImGui::GetBackgroundDrawList()->AddImage((ImTextureID)parent,
                                                 ImVec2(0, 0), ImVec2(2, 2));
        ImGui::GetBackgroundDrawList()->AddImage((ImTextureID)child,
                                                 ImVec2(2, 0), ImVec2(3, 1));
        ImGui::Render();
        ok(xemu_metal4_ui_end(ImGui::GetDrawData()));
        xemu_metal4_ui_release_texture(parent);
        xemu_metal4_ui_release_texture(child);
        ok(xemu_metal4_ui_close());
        assert(!io.BackendRendererUserData && !io.Fonts->TexID);
        uint8_t pixels[64];
        [target getBytes:pixels
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0];
        for (unsigned y = 0; y < 4; y++) {
            for (unsigned x = 0; x < 4; x++) {
                unsigned r = x < 2 ? (y < 2 ? 255 : 0) : (y < 2 ? 0 : 255);
                unsigned g = x < 2 ? 0 : 255;
                unsigned b = y < 2 ? 0 : 255;
                if (x < 2 && y < 2) {
                    r = x == 0 && y == 0 ? 255 : 0;
                    g = r ? 0 : 255;
                }
                if (x == 2 && y == 0) {
                    r = g = 0;
                    b = 255;
                }
                pixel(pixels, x, y, r, g, b);
            }
        }
        ok(xemu_metal4_ui_init(nullptr, false));
        ok(xemu_metal4_ui_begin(handle));
        assert(!xemu_metal4_ui_framebuffer(0, 1, false));
        xemu_metal4_ui_cancel();
        ok(xemu_metal4_ui_begin(handle));
        ok(xemu_metal4_ui_framebuffer(1, 1, false));
        ok(xemu_metal4_ui_end(nullptr));
        ok(xemu_metal4_ui_close());
        [target getBytes:pixels
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0];
        for (unsigned i = 0; i < sizeof(pixels); i++)
            assert(pixels[i] == 0);
        ImGui::DestroyContext();
        std::puts(
            "Metal4 UI session: display->nested decals->ImGui, ownership, "
            "fonts and lifecycle PASS (no SDL/window/app)");
    }
}
