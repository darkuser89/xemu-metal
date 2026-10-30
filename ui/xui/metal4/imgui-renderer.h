/*
 * xemu ImGui renderer using the Metal 4 core API
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef XEMU_UI_METAL4_IMGUI_RENDERER_H
#define XEMU_UI_METAL4_IMGUI_RENDERER_H

#import "hw/xbox/nv2a/pgraph/metal/command.h"

struct ImDrawData;

NS_ASSUME_NONNULL_BEGIN

/* Create after ImGui::CreateContext(). Calls belong to that context's thread.
 * Call shutdown before destroying the ImGui context. Texture IDs are borrowed
 * MTLTexture pointers, retained by each submission that uses them. */
API_AVAILABLE(macos(26.0))
@interface XemuMetal4ImGui : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)newFrameWithError:(NSError *_Nullable *_Nullable)error;
- (void)invalidateFonts;
- (void)shutdown;

/* Load the existing target (e.g. the gamma-corrected framebuffer), then draw
 * ImGui. Begin the commands object first; this method ends its own encoder. */
- (BOOL)encodeDrawData:(const struct ImDrawData *)drawData
              commands:(NV2AMetalCommands *)commands
                target:(id<MTLTexture>)target
                 error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END

#endif
