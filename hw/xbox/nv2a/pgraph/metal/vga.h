/* GPU rendering of the graphics and text portions of the former VGA fallback.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VGA_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VGA_H
#import "command.h"
#include "vga-types.h"
NS_ASSUME_NONNULL_BEGIN
/* Rows and palette are captured metadata. Only the GPU reads/converts pixels.
 * memory_mask retains VGA wrapping; plane modes also retain its 256KiB window.
 * Output RGBA8 has top-left row0 and opaque alpha, like VGA's XRGB surface. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalVGA : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable id<MTLTexture>)encodeData:(id<MTLBuffer>)data
                                 rows:(const NV2AMetalVGARow *)rows
                             uniforms:(const NV2AMetalVGAUniforms *)uniforms
                             commands:(NV2AMetalCommands *)commands
                                error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
