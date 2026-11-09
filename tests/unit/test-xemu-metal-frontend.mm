/* Complete offscreen UI frame without SDL initialization or a window.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "ui/xui/metal4/frontend.h"
#import "ui/xui/metal4/decal.h"
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#import <objc/runtime.h>
#include <imgui.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

@interface FrontendFrame : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) NV2AMetalDisplayUniforms displayUniforms;
@property(nonatomic) BOOL screenOff;
@end
@implementation FrontendFrame
@end

static IMP encode_decals;
static id<MTLTexture> counted_target;
static unsigned clear_only, clear_with_decals;
static unsigned nested_clear_only, nested_clear_with_decals;

static BOOL count_clears(XemuMetal4Decals *self, SEL selector, NSArray *decals,
                         NV2AMetalCommands *commands, id<MTLTexture> target,
                         BOOL clear, NSError **error)
{
    if (clear) {
        if (target == counted_target) {
            if (decals.count)
                clear_with_decals++;
            else
                clear_only++;
        } else {
            if (decals.count)
                nested_clear_with_decals++;
            else
                nested_clear_only++;
        }
    }
    using Encode = BOOL (*)(XemuMetal4Decals *, SEL, NSArray *,
                            NV2AMetalCommands *, id<MTLTexture>, BOOL,
                            NSError **);
    return reinterpret_cast<Encode>(encode_decals)(self, selector, decals,
                                                   commands, target, clear,
                                                   error);
}

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

static void check_parent_clears(id<MTLDevice> device, MTLTextureDescriptor *td)
{
    ok(xemu_metal4_ui_init(nullptr, false));
    td.usage |= MTLTextureUsagePixelFormatView;
    NSMutableArray<id<MTLTexture>> *results = [NSMutableArray new];
    uint8_t bytes[64];
    const float region[] = { 0, 0, 4, 4 };
    uint8_t red[64] = {};
    for (unsigned i = 0; i < sizeof(red); i += 4)
        red[i] = red[i + 3] = 255;
    uintptr_t mask = xemu_metal4_ui_texture(red, 4, 4);
    assert(mask);
    __weak FrontendFrame *submittedFrame;
    for (unsigned variant = 0; variant < 3; variant++) {
        id<MTLTexture> parent = [device newTextureWithDescriptor:td];
        id<MTLTexture> view =
            [parent newTextureViewWithPixelFormat:parent.pixelFormat];
        id<MTLTexture> child = variant == 2 ? view :
            [device newTextureWithDescriptor:td];
        assert(view.parentTexture == parent && child);
        for (unsigned i = 0; i < sizeof(bytes); i += 4) {
            bytes[i] = bytes[i + 1] = 0;
            bytes[i + 2] = bytes[i + 3] = 255;
        }
        [parent replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                  mipmapLevel:0
                    withBytes:bytes
                  bytesPerRow:16];
        counted_target = parent;
        unsigned before = clear_only;
        ok(xemu_metal4_ui_begin((uintptr_t)(__bridge void *)parent));
        ok(xemu_metal4_ui_push_target((uintptr_t)(__bridge void *)child));
        assert(clear_only == before + (variant == 2));
        if (variant == 0) {
            FrontendFrame *frame = [FrontendFrame new];
            frame.texture = view;
            NV2AMetalDisplayUniforms u = {};
            for (unsigned i = 0; i < 256; i++)
                u.palette[i] = i | (i << 8) | (i << 16);
            frame.displayUniforms = u;
            ok(xemu_metal4_ui_set_frame((__bridge void *)frame));
            ok(xemu_metal4_ui_framebuffer(1, 1, false));
            assert(clear_only == before + 1);
            submittedFrame = frame;
            frame = nil;
            ok(xemu_metal4_ui_set_frame(nullptr));
            assert(submittedFrame);
        } else if (variant == 1) {
            ok(xemu_metal4_ui_decal((uintptr_t)(__bridge void *)view, region,
                                    region, 0xff0000ff, 0x00ff00ff, 0x000000ff,
                                    0, false, 0, 0));
        } else {
            ok(xemu_metal4_ui_decal(mask, region, region, 0xff0000ff, 0, 0, 0,
                                    false, 0, 0));
        }
        ok(xemu_metal4_ui_pop_target());
        assert(clear_only == before + 1);
        ok(xemu_metal4_ui_end(nullptr));
        assert(clear_only == before + 1);
        [results addObject:child];
    }
    xemu_metal4_ui_release_texture(mask);
    ok(xemu_metal4_ui_close());
    assert(!submittedFrame);
    counted_target = nil;
    for (unsigned i = 0; i < results.count; i++) {
        [results[i] getBytes:bytes
                 bytesPerRow:16
                  fromRegion:MTLRegionMake2D(0, 0, 4, 4)
                  mipmapLevel:0];
        if (i == 0) {
            for (uint8_t byte : bytes)
                assert(byte == 0);
        } else {
            for (unsigned y = 0; y < 4; y++)
                for (unsigned x = 0; x < 4; x++)
                    pixel(bytes, x, y, i == 2 ? 255 : 0, i == 1 ? 255 : 0, 0);
        }
    }
    std::puts("Metal4 UI parent clear: delayed until sampled or an alias is "
              "written, then exact child pixels and no later clear PASS");
}

#include "test-metal-frontend-deferred.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        assert(!xemu_metal4_ui_init(nullptr, false));
        ImGui::CreateContext();
        if (argc == 2 && !strcmp(argv[1], "--deferred-recording")) {
            frontend_deferred_tests();
            ImGui::DestroyContext();
            return 0;
        }
        assert(argc == 1);
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
        counted_target = target;
        Method method = class_getInstanceMethod(
            [XemuMetal4Decals class],
            @selector(encodeDecals:commands:target:clear:error:));
        assert(method);
        encode_decals = method_setImplementation(method, (IMP)count_clears);
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
        assert(clear_only == 0 && clear_with_decals == 0);
        assert(nested_clear_only == 0 && nested_clear_with_decals == 2);
        xemu_metal4_ui_release_texture(parent);
        xemu_metal4_ui_release_texture(child);
        id<MTLTexture> letterbox = [device newTextureWithDescriptor:td];
        counted_target = letterbox;
        uint8_t pixels[64];
        std::memset(pixels, 0x7c, sizeof(pixels));
        [letterbox replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                     mipmapLevel:0
                       withBytes:pixels
                     bytesPerRow:16];
        ok(xemu_metal4_ui_begin((uintptr_t)(__bridge void *)letterbox));
        ok(xemu_metal4_ui_framebuffer(0.5f, 0.5f, false));
        ok(xemu_metal4_ui_end(nullptr));
        assert(clear_only == 0 && clear_with_decals == 0);
        counted_target = target;
        ok(xemu_metal4_ui_close());
        assert(!io.BackendRendererUserData && !io.Fonts->TexID);
        [letterbox getBytes:pixels
                  bytesPerRow:16
                   fromRegion:MTLRegionMake2D(0, 0, 4, 4)
                   mipmapLevel:0];
        pixel(pixels, 1, 1, 255, 0, 0);
        for (unsigned y = 0; y < 4; y++) {
            for (unsigned x = 0; x < 4; x++) {
                if (x == 0 || x == 3 || y == 0 || y == 3) {
                    const uint8_t *edge = pixels + 4 * (4 * y + x);
                    assert(!(edge[0] | edge[1] | edge[2] | edge[3]));
                }
            }
        }
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
        assert(clear_only == 0);
        ok(xemu_metal4_ui_begin(handle));
        ok(xemu_metal4_ui_end(nullptr));
        assert(clear_only == 1 && clear_with_decals == 0);
        uintptr_t root_decal = xemu_metal4_ui_texture(mask, 2, 2);
        assert(root_decal);
        ok(xemu_metal4_ui_begin(handle));
        ok(xemu_metal4_ui_decal(root_decal, region, whole, 0xff0000ff, 0, 0,
                               0, false, 0, 0));
        ok(xemu_metal4_ui_end(nullptr));
        xemu_metal4_ui_release_texture(root_decal);
        assert(clear_only == 1 && clear_with_decals == 1);
        ok(xemu_metal4_ui_begin(handle));
        ok(xemu_metal4_ui_framebuffer(1, 1, false));
        ok(xemu_metal4_ui_end(nullptr));
        assert(clear_only == 1 && clear_with_decals == 1);

        id<MTLTexture> imgui_only = [device newTextureWithDescriptor:td];
        id<MTLTexture> empty_imgui = [device newTextureWithDescriptor:td];
        std::memset(pixels, 0x7c, sizeof(pixels));
        for (id<MTLTexture> dirty in @[ imgui_only, empty_imgui ]) {
            [dirty replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                     mipmapLevel:0
                       withBytes:pixels
                     bytesPerRow:16];
        }
        ok(xemu_metal4_ui_new_frame());
        ImGui::NewFrame();
        ImGui::GetBackgroundDrawList()->AddRectFilled(
            ImVec2(0, 0), ImVec2(1, 1), IM_COL32(255, 0, 0, 255));
        ImGui::Render();
        counted_target = imgui_only;
        ok(xemu_metal4_ui_begin((uintptr_t)(__bridge void *)imgui_only));
        ok(xemu_metal4_ui_end(ImGui::GetDrawData()));
        counted_target = empty_imgui;
        ImDrawData empty;
        empty.DisplaySize = ImVec2(4, 4);
        empty.FramebufferScale = ImVec2(1, 1);
        ok(xemu_metal4_ui_begin((uintptr_t)(__bridge void *)empty_imgui));
        ok(xemu_metal4_ui_end(&empty));
        assert(clear_only == 1 && clear_with_decals == 1);

        // An empty nested target must still become transparent at pop.
        counted_target = target;
        uintptr_t empty_child = xemu_metal4_ui_target(1, 1);
        assert(empty_child);
        unsigned before = clear_only;
        ok(xemu_metal4_ui_begin(handle));
        ok(xemu_metal4_ui_push_target(empty_child));
        assert(nested_clear_only == 0 && clear_only == before);
        ok(xemu_metal4_ui_pop_target());
        assert(nested_clear_only == 1 && clear_only == before);
        ok(xemu_metal4_ui_framebuffer(1, 1, false));
        ok(xemu_metal4_ui_end(nullptr));
        assert(clear_only == before);
        xemu_metal4_ui_release_texture(empty_child);

        ok(xemu_metal4_ui_begin(handle));
        ok(xemu_metal4_ui_push_target(handle));
        ok(xemu_metal4_ui_decal(handle, region, region, 0, 0, 0, 0, false,
                               0, 0));
        assert(!xemu_metal4_ui_pop_target());
        xemu_metal4_ui_cancel();
        ok(xemu_metal4_ui_close());
        counted_target = nil;
        [target getBytes:pixels
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0];
        for (unsigned i = 0; i < sizeof(pixels); i++)
            assert(pixels[i] == 0);
        [imgui_only getBytes:pixels
                   bytesPerRow:16
                    fromRegion:MTLRegionMake2D(0, 0, 4, 4)
                   mipmapLevel:0];
        pixel(pixels, 0, 0, 255, 0, 0);
        for (unsigned i = 4; i < sizeof(pixels); i++)
            assert(pixels[i] == 0);
        [empty_imgui getBytes:pixels
                    bytesPerRow:16
                     fromRegion:MTLRegionMake2D(0, 0, 4, 4)
                    mipmapLevel:0];
        for (unsigned i = 0; i < sizeof(pixels); i++)
            assert(pixels[i] == 0);
        check_parent_clears(device, td);
        method_setImplementation(method, encode_decals);
        frontend_deferred_tests();
        ImGui::DestroyContext();
        std::puts(
            "Metal4 UI session: display->nested decals->ImGui, ownership, "
            "fonts and lifecycle PASS (no SDL/window/app)");
        std::puts("Metal4 UI initialization: framebuffer and ScreenOff clear "
                  "once, first decals share their clear, empty frame clears, "
                  "cancel emits no clear PASS");
        std::puts("Metal4 UI nested and ImGui initialization: no separate "
                  "clear for first draws; empty data, transparent pixels, "
                  "letterbox, nested alias rejection and cancel PASS");
    }
}
