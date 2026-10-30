/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_PGRAPH_H
#import "texture-pgraph.h"
#include "geometry-types.h"
typedef struct PGRAPHState PGRAPHState;

NS_ASSUME_NONNULL_BEGIN
/* Immutable PGRAPH fragment/raster capture; pg.lock must be held, textures
 * captured and render surfaces prepared before construction. Uniforms return
 * by value, and the texture snapshot owns exported borrowed bindings until
 * fragment encode returns. Does not encode, start a VM, or register a renderer.
 * GL's floating-depth and W-buffer slope approximations remain explicit.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHPixelState : NSObject
@property(nonatomic, readonly) NV2AMetalPixelUniforms uniforms;
@property(nonatomic, readonly) NV2AMetalDrawState *raster;
@property(nonatomic, readonly) unsigned int textureMask;
@property(nonatomic, readonly, nullable)
    NV2AMetalPGRAPHTextureSnapshot *textureSnapshot;
/* Portable scalar state. GPU texture content is supplied separately. */
- (NSData *)snapshotData;
+ (BOOL)validateBoundSnapshot:(NSData *)data
                      control:(uint32_t)control
                      stencil:(uint32_t)stencil
                  textureMask:(uint32_t)mask
                     textures:(nullable NSData *)textures;
+ (BOOL)validateSnapshot:(NSData *)data
                   error:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)
    initWithSnapshot:(NSData *)data
            textures:(nullable NV2AMetalPGRAPHTextureSnapshot *)textures
              device:(id<MTLDevice>)device
               error:(NSError *_Nullable *_Nullable)error;
- (NV2AMetalPixelUniforms)uniformsForPolygon:(enum NV2AMetalPolygonMode)polygon;
- (nullable instancetype)
    initWithState:(PGRAPHState *)state
         textures:(nullable NV2AMetalPGRAPHTextureSnapshot *)textures
           device:(id<MTLDevice>)device
            error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/* glClear's persistent masks/dither/scissor changes, without shader/texture
 * recapture. The immutable result is portable through the existing snapshot. */
- (nullable NV2AMetalPGRAPHPixelState *)
    stateByApplyingClear:(uint32_t)parameter
                   state:(PGRAPHState *)state
                  device:(id<MTLDevice>)device
                   error:(NSError *_Nullable *_Nullable)error;
- (BOOL)copyTextureBindings:(NV2AMetalPixelTexture *_Nullable)bindings
                      error:(NSError *_Nullable *_Nullable)error;
/* GL's compressed-inline transition rebinds shaders without changing the
 * already-bound textures, blend/depth/stencil/scissor or polygon offset. */
- (nullable NV2AMetalPGRAPHPixelState *)
    recaptureShaderWithState:(PGRAPHState *)state
                      device:(id<MTLDevice>)device
                       error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
