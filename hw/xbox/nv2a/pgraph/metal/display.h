/*
 * NV2A Metal 4 framebuffer display
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_DISPLAY_H
#define HW_XBOX_NV2A_PGRAPH_METAL_DISPLAY_H

#import "command.h"
#include "display-uniforms.h"

NS_ASSUME_NONNULL_BEGIN

/* Final framebuffer scaling and gamma pass. The source uses top-left texture
 * coordinates unless flip_y is set. NV2A scanout/PVIDEO is composed upstream.
 * All calls belong to the commands object's encoding thread. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalDisplay : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Begin a command buffer first. This method ends its render encoder, clears
 * the entire target, and retains everything until submission completes.
 * source may be nil only when screenOff is YES. target and source must be
 * distinct, single-sample 2D textures; RGB is interpreted without sRGB decode.
 * The caller waits for a drawable before writing its texture. Scanout sources
 * may use R8/RG8, RGB565/RGB5A1, RGBA8/BGRA8 or RGBA32F. Float filtering uses
 * manual GPU reads so it also works on Apple7/8. */
- (BOOL)encodeWithCommands:(NV2AMetalCommands *)commands
                    source:(nullable id<MTLTexture>)source
                    target:(id<MTLTexture>)target
                  uniforms:(const NV2AMetalDisplayUniforms *)uniforms
                    linear:(BOOL)linear
                 screenOff:(BOOL)screenOff
                     error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif
