/*
 * Offscreen ImGui draw-list tests through Metal 4; no xemu window.
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "ui/xui/metal4/imgui-renderer.h"
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#import <objc/runtime.h>
#include <imgui.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "test-metal-texture-alias.h"

typedef id (*ImGuiPipelineBuilder)(id, SEL, id, id, NSError **)
    __attribute__((ns_returns_retained));
static ImGuiPipelineBuilder original_pipeline;
static unsigned pipeline_builds;
static BOOL fail_pipeline;

static id observe_pipeline(id object, SEL selector, id descriptor, id options,
                           NSError **error) __attribute__((ns_returns_retained));
static id observe_pipeline(id object, SEL selector, id descriptor, id options,
                           NSError **error)
{
    pipeline_builds++;
    if (fail_pipeline) {
        *error = [NSError errorWithDomain:@"test.imgui.pipeline"
                                     code:1
                                 userInfo:nil];
        return nil;
    }
    return original_pipeline(object, selector, descriptor, options, error);
}

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Metal ImGui test failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static void check_pixel(const unsigned char *pixels, unsigned x, unsigned y,
                        unsigned r, unsigned g, unsigned b, unsigned a)
{
    const unsigned char *pixel = pixels + (y * 8 + x) * 4;
    unsigned expected[] = { r, g, b, a };
    for (unsigned channel = 0; channel < 4; channel++) {
        if (abs((int)pixel[channel] - (int)expected[channel]) > 1) {
            fprintf(stderr, "Pixel %u,%u channel %u: got %u, expected %u\n", x,
                    y, channel, pixel[channel], expected[channel]);
            abort();
        }
    }
}

static void callback(const ImDrawList *, const ImDrawCmd *command)
{
    (*(unsigned *)command->UserCallbackData)++;
}

static void read_texture(id<MTLTexture> texture, unsigned char *pixels)
{
    [texture getBytes:pixels
          bytesPerRow:32
           fromRegion:MTLRegionMake2D(0, 0, 8, 8)
          mipmapLevel:0];
}

int main(void)
{
    @autoreleasepool {
        ImGuiContext *owner = ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = nullptr;
        io.LogFilename = nullptr;
        io.DisplaySize = ImVec2(4, 4);
        io.DisplayFramebufferScale = ImVec2(2, 2);
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalDisplay *display =
            [[NV2AMetalDisplay alloc] initWithDevice:commands.device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        require(display != nil, error);
        id<MTL4Compiler> compiler = [commands.device
            newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
        require(compiler != nil, error);
        Method pipeline = class_getInstanceMethod(
            object_getClass(compiler),
            @selector(newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:));
        assert(pipeline);
        original_pipeline = reinterpret_cast<ImGuiPipelineBuilder>(
            method_setImplementation(pipeline, (IMP)observe_pipeline));
        XemuMetal4ImGui *renderer =
            [[XemuMetal4ImGui alloc] initWithDevice:commands.device
                                        pixelFormat:MTLPixelFormatRGBA8Unorm
                                              error:&error];
        require(renderer != nil, error);
        require([renderer newFrameWithError:&error], error);
        assert(io.Fonts->TexID);
        assert(io.BackendFlags & ImGuiBackendFlags_RendererHasVtxOffset);
        ImGuiContext *other = ImGui::CreateContext();
        ImGui::SetCurrentContext(other);
        [renderer invalidateFonts];
        assert(ImGui::GetCurrentContext() == other);
        assert(!io.Fonts->TexID);
        ImGui::DestroyContext(other);
        ImGui::SetCurrentContext(owner);
        require([renderer newFrameWithError:&error], error);
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:8
                                        height:8
                                     mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage =
            MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> target =
            [commands.device newTextureWithDescriptor:descriptor];
        assert(target);
        NV2AMetalDisplayUniforms uniforms = {};
        uniforms.scale[0] = uniforms.scale[1] = 1;
        unsigned callbacks = 0;
        unsigned char pixels[8 * 8 * 4];

        ImDrawData empty;
        empty.DisplaySize = io.DisplaySize;
        empty.FramebufferScale = io.DisplayFramebufferScale;
        require([commands beginWithError:&error] != nil, error);
        require([renderer encodeDrawData:&empty commands:commands target:target
                                  clear:YES error:&error], error);
        ImGui::NewFrame();
        ImDrawList *list = ImGui::GetBackgroundDrawList();
        list->AddRectFilled(ImVec2(0, 0), ImVec2(4, 4), IM_COL32_WHITE);
        list->AddCallback(callback, &callbacks);
        list->AddCallback(ImDrawCallback_ResetRenderState, nullptr);
        list->AddCallback(callback, &callbacks);
        ImGui::Render();
        for (ImDrawCmd &draw : list->CmdBuffer) {
            draw.ElemCount = 0;
        }
        require([renderer encodeDrawData:ImGui::GetDrawData()
                                commands:commands target:target error:&error],
                error);
        assert(callbacks == 2);
        assert(pipeline_builds == 0);
        assert(![renderer valueForKey:@"pipeline"]);
        assert(![renderer valueForKey:@"arguments"]);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        read_texture(target, pixels);
        check_pixel(pixels, 0, 0, 0, 0, 0, 0);
        callbacks = 0;

        ImGui::NewFrame();
        list = ImGui::GetBackgroundDrawList();
        list->Flags &= ~ImDrawListFlags_AntiAliasedFill;
        list->AddRectFilled(ImVec2(0, 0), ImVec2(4, 4),
                            IM_COL32(255, 0, 0, 255));
        list->PushClipRect(ImVec2(1, 1), ImVec2(3, 3), true);
        list->AddRectFilled(ImVec2(0, 0), ImVec2(4, 4),
                            IM_COL32(0, 0, 255, 128));
        list->PopClipRect();
        list->AddCallback(callback, &callbacks);
        list->AddCallback(ImDrawCallback_ResetRenderState, nullptr);
        list->AddRectFilled(ImVec2(3, 0), ImVec2(4, 1),
                            IM_COL32(0, 255, 0, 255));
        ImGui::Render();
        ImDrawData *drawData = ImGui::GetDrawData();
        /* Exercise nonzero DisplayPos, alongside Retina scaling. */
        drawData->DisplayPos = ImVec2(10, 20);
        for (ImDrawList *drawList : drawData->CmdLists) {
            /* Keep this list arena-sized while exercising nonzero base
             * vertex and an odd first-index offset. */
            int vertices = drawList->VtxBuffer.Size;
            int indices = drawList->IdxBuffer.Size;
            drawList->VtxBuffer.resize(vertices + 1);
            drawList->IdxBuffer.resize(indices + 1);
            std::memmove(drawList->VtxBuffer.Data + 1, drawList->VtxBuffer.Data,
                         vertices * sizeof(ImDrawVert));
            std::memmove(drawList->IdxBuffer.Data + 1, drawList->IdxBuffer.Data,
                         indices * sizeof(ImDrawIdx));
            drawList->VtxBuffer[0] = ImDrawVert{};
            drawList->IdxBuffer[0] = 0;
            drawData->TotalVtxCount++;
            drawData->TotalIdxCount++;
            for (ImDrawVert &vertex : drawList->VtxBuffer) {
                vertex.pos.x += 10;
                vertex.pos.y += 20;
            }
            for (ImDrawCmd &draw : drawList->CmdBuffer) {
                draw.VtxOffset++;
                draw.IdxOffset++;
                draw.ClipRect.x += 10;
                draw.ClipRect.z += 10;
                draw.ClipRect.y += 20;
                draw.ClipRect.w += 20;
            }
        }
        require([commands beginWithError:&error] != nil, error);
        BOOL success = [display encodeWithCommands:commands
                                            source:nil
                                            target:target
                                          uniforms:&uniforms
                                            linear:NO
                                         screenOff:YES
                                             error:&error];
        require(success, error);
        id<MTL4CommandBuffer> recording = commands.commandBuffer;
        fail_pipeline = YES;
        success = [renderer encodeDrawData:drawData
                                  commands:commands
                                    target:target
                                     error:&error];
        assert(!success && [error.domain isEqualToString:@"test.imgui.pipeline"]);
        assert(commands.commandBuffer == recording);
        assert(callbacks == 0 && pipeline_builds == 1);
        assert(![renderer valueForKey:@"pipeline"]);
        assert(![renderer valueForKey:@"arguments"]);
        fail_pipeline = NO;
        error = nil;
        success = [renderer encodeDrawData:drawData
                                  commands:commands
                                    target:target
                                     error:&error];
        require(success, error);
        assert(pipeline_builds == 2);
        assert([renderer valueForKey:@"pipeline"]);
        assert([renderer valueForKey:@"arguments"]);
        method_setImplementation(pipeline, (IMP)original_pipeline);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        read_texture(target, pixels);
        check_pixel(pixels, 0, 0, 255, 0, 0, 255);
        check_pixel(pixels, 2, 2, 127, 0, 128, 255);
        check_pixel(pixels, 6, 0, 0, 255, 0, 255);
        check_pixel(pixels, 7, 7, 255, 0, 0, 255);
        assert(callbacks == 1);

        texture_alias_cases(commands.device, ^(id<MTLTexture> src,
                                               id<MTLTexture> dst,
                                               BOOL expected) {
          NSError *alias_error = nil;
          ImGui::NewFrame();
          ImGui::GetBackgroundDrawList()->AddImage(
              (ImTextureID)(uintptr_t)(__bridge void *)src, ImVec2(0, 0),
              ImVec2(4, 4));
          ImGui::Render();
          require([commands beginWithError:&alias_error] != nil, alias_error);
          BOOL accepted = [renderer encodeDrawData:ImGui::GetDrawData()
                                          commands:commands
                                            target:dst
                                             error:&alias_error];
          assert(accepted == expected);
          assert(accepted || alias_error);
          [commands cancel];
        });

        /* More than 65535 vertices exercises baseVertex. Font invalidation
         * and context destruction after submission must preserve GPU inputs. */
        require([renderer newFrameWithError:&error], error);
        ImGui::NewFrame();
        list = ImGui::GetBackgroundDrawList();
        list->Flags &= ~ImDrawListFlags_AntiAliasedFill;
        for (unsigned i = 0; i < 16400; i++) {
            list->AddRectFilled(ImVec2(-10, -10), ImVec2(-9, -9),
                                IM_COL32_WHITE);
        }
        list->AddRectFilled(ImVec2(0, 0), ImVec2(4, 4),
                            IM_COL32(0, 255, 0, 255));
        ImGui::Render();
        drawData = ImGui::GetDrawData();
        bool hasOffset = false;
        for (const ImDrawCmd &draw : list->CmdBuffer) {
            hasOffset |= draw.VtxOffset != 0;
        }
        assert(sizeof(ImDrawIdx) == 4 || hasOffset);
        require([commands beginWithError:&error] != nil, error);
        success = [renderer encodeDrawData:drawData
                                  commands:commands
                                    target:target
                                     error:&error];
        require(success, error);
        require([commands submitWithError:&error], error);
        [renderer invalidateFonts];
        assert(!io.Fonts->TexID);
        other = ImGui::CreateContext();
        ImGui::SetCurrentContext(other);
        [renderer shutdown];
        assert(ImGui::GetCurrentContext() == other);
        assert(!io.BackendRendererUserData);
        ImGui::DestroyContext(other);
        ImGui::DestroyContext(owner);
        renderer = nil;
        require([commands waitUntilIdleWithError:&error], error);
        read_texture(target, pixels);
        check_pixel(pixels, 0, 0, 0, 255, 0, 255);
        check_pixel(pixels, 7, 7, 0, 255, 0, 255);
        puts("Metal 4 ImGui startup: empty/callback-only frames skip pipeline; "
             "first draw compiler failure and retry PASS");
        puts("Metal 4 ImGui clipping, alpha, DPI, callbacks, VtxOffset and "
             "shutdown: PASS (offscreen)");
    }
    return 0;
}
