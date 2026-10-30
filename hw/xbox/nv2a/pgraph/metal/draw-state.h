/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_DRAW_STATE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_DRAW_STATE_H

#import "command.h"
#include "../../nv2a_regs.h"

NS_ASSUME_NONNULL_BEGIN

/* Original register words. Scissor has already had the frontend's AA and
 * surface scale factors applied, in NV2A row0/Metal row0 coordinates. */
typedef struct NV2AMetalDrawConfig {
    unsigned int control[3], blend, blend_color, setup_raster, antialiasing;
    MTLScissorRect scissor;
    BOOL scissor_enabled;
    /* Zero selects the attachment size for uncaptured/legacy callers. */
    unsigned int viewport_width, viewport_height;
} NV2AMetalDrawConfig;

/* CPU-only validation shared by creation and portable snapshot decoding. */
BOOL nv2a_metal_draw_config_validate(
    const NV2AMetalDrawConfig *_Nullable config,
    NSError *_Nullable *_Nullable error);

/* Retain this device cache for the renderer's lifetime to reuse native states
 * across completed/released captures. The global device index is weak; live
 * captures also retain it, including commands already encoded in flight. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalDepthStencilCache : NSObject
+ (nullable instancetype)sharedWithDevice:(id<MTLDevice>)device
                                    error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* Immutable capture of fixed raster state. Polygon offset remains in the
 * geometry/fragment shaders. Logic ops disable blending and are
 * evaluated by the fragment pipeline. Dither follows blending on the GPU. Line
 * and polygon smoothing are supplied by geometry. Polygon modes are validated
 * here and assembled by the native geometry frontend before rasterization. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalDrawState : NSObject
@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) NV2AMetalDrawConfig config;
@property(nonatomic, readonly) id<MTLDepthStencilState> depthStencil;
@property(nonatomic, readonly) BOOL requiresDepth, requiresStencil,
    logicEnabled, ditherEnabled;
@property(nonatomic, readonly) unsigned int logicOperation, blendWord,
    blendColor;
@property(nonatomic, readonly) NSUInteger pipelineKey;

- (nullable instancetype)
    initWithDevice:(id<MTLDevice>)device
            config:(const NV2AMetalDrawConfig *_Nullable)config
             error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* A fresh descriptor, so callers cannot mutate the capture. The pipeline
 * builder supplies its pixel format. Dynamic blend color is not in the key. */
- (MTL4RenderPipelineColorAttachmentDescriptor *)colorAttachment;

/* Sets dynamic state. Returns NO when scissor is empty or both faces of a
 * triangle are culled; the encoder must still end to honor pass load/store.
 * Points and lines ignore polygon culling, as in GL. */
- (BOOL)applyToEncoder:(id<MTL4RenderCommandEncoder>)encoder
                 width:(NSUInteger)width
                height:(NSUInteger)height
             primitive:(MTLPrimitiveType)primitive;
/* Expanded line rectangles are triangles only for transport. Their original
 * polygon faces have already been culled by geometry; direct lines ignore
 * polygon culling. Keep the same depth/stencil/blend/scissor state. */
- (BOOL)applyToEncoder:(id<MTL4RenderCommandEncoder>)encoder
                   width:(NSUInteger)width
                  height:(NSUInteger)height
               primitive:(MTLPrimitiveType)primitive
    ignorePolygonCulling:(BOOL)ignore;
@end

NS_ASSUME_NONNULL_END
#endif
