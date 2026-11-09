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

typedef struct NV2AMetalClearAttachmentLayout {
    MTLPixelFormat pixel_format;
    NSUInteger width, height;
} NV2AMetalClearAttachmentLayout;

/* Metadata-only form preserves absent attachments without borrowing textures.
 */
BOOL nv2a_metal_clear_layout_uses_load_actions(
    const NV2AMetalClearAttachmentLayout *_Nullable color,
    const NV2AMetalClearAttachmentLayout *_Nullable zeta,
    const NV2AMetalClearConfig *config);

/* Query the load-clear path for already selected, compatible attachments. */
BOOL nv2a_metal_clear_uses_load_actions(id<MTLTexture> _Nullable color,
                                        id<MTLTexture> _Nullable zeta,
                                        const NV2AMetalClearConfig *config);

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
/* Pure eligibility on a detached pending pass. Actual attachments and the
 * complete command-pass match are checked again before encoding. */
- (BOOL)canContinueRasterPass:(nullable MTL4RenderPassDescriptor *)pass
                       config:(const NV2AMetalClearConfig *_Nullable)config;
/* Shader clear in an already prepared compatible raster section. The owner
 * validates dependencies and retains the parent visibility descriptor;
 * this encoder disables counting and never reserves a query counter.
 * Load-clears continue to use the standalone entry above. */
- (BOOL)encodeColor:(nullable id<MTLTexture>)color
               zeta:(nullable id<MTLTexture>)zeta
             config:(const NV2AMetalClearConfig *_Nullable)config
         rasterPass:(MTL4RenderPassDescriptor *)pass
           commands:(NV2AMetalCommands *)commands
              error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
