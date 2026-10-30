/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_CLEAR_H
#define HW_XBOX_NV2A_PGRAPH_METAL_CLEAR_H

#import "command.h"
#include "clear-types.h"
#include "../../nv2a_regs.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct NV2AMetalClearConfig {
    NV2AMetalClearUniforms uniforms;
    MTLScissorRect rect;
    unsigned int parameter, stencil;
    BOOL dither;
} NV2AMetalClearConfig;

/* Native render clear with masks and scissor, independent of draw-state
 * blend/tests/window-clip/offset. The frontend captures the original clear
 * color/depth helpers and scales the inclusive rectangle by AA and surface
 * scale. Missing stencil on Z16 is a no-op as in GL. Dither uses the same
 * implementation-dependent native host policy as the draw pipeline.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalClear : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Single level-zero 2D or multisample attachments, no resolve. Outside/empty
 * rectangles encode nothing. Width/height/sampleCount must agree. Callers
 * retain attachments until return; commands keep all resources until idle. */
- (BOOL)encodeColor:(nullable id<MTLTexture>)color
               zeta:(nullable id<MTLTexture>)zeta
             config:(const NV2AMetalClearConfig *_Nullable)config
           commands:(NV2AMetalCommands *)commands
              error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
