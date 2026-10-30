/* Native NV2A framebuffer/PVIDEO composition from gl/display.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SCANOUT_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SCANOUT_H
#import "command.h"
#include "scanout-types.h"
NS_ASSUME_NONNULL_BEGIN
/* Compose before final DAC gamma, screen-off and window scaling. Source
 * textures retain NV2A row0 in Metal row0. The overlay uses GL's repeat/linear
 * sampling including its negative Y coordinate. Manual bilinear reads support
 * RGBA32F on Apple7/8 without hardware float32 filtering. No CPU pixel
 * processing. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalScanout : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)format
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)encodeSource:(id<MTLTexture>)source
             overlay:(nullable id<MTLTexture>)overlay
              target:(id<MTLTexture>)target
            uniforms:(const NV2AMetalScanoutUniforms *)uniforms
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
