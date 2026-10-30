/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FIXED_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FIXED_H

#import "command.h"
#include "vertex-fixed-types.h"

NS_ASSUME_NONNULL_BEGIN

BOOL nv2a_metal_fixed_validate(const NV2AMetalFixedUniforms *_Nullable uniforms,
                               NSError *_Nullable *_Nullable error);

BOOL nv2a_metal_fixed_validate_context(
    const NV2AMetalFixedUniforms *_Nullable uniforms,
    NSError *_Nullable *_Nullable error);

API_AVAILABLE(macos(26.0))
@interface NV2AMetalFixedResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> registers;
@property(nonatomic, readonly, nullable) id<MTLBuffer> vertices;
@property(nonatomic, readonly) NSUInteger vertexCount;
@end

/* Native MTL4 compute counterpart of glsl/vsh-ff.c. Float4 attribute fetch
 * and PGRAPH uniform population belong to the draw frontend. Front and back
 * lighting use the captured PGRAPH controls. Spotlight falloff
 * uses the programmed LTCTXA coefficients. Raw register 0 is the composite
 * transform with clamped W, register 5.x is fog distance, and register 6.x is
 * computed point size. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalVertexFixed : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
           rasterize:(BOOL)rasterize
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
/* Select a completed input span without a temporary GPU copy. The input
 * resource remains resident and retained until command completion. */
- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
           rasterize:(BOOL)rasterize
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
/* Internal raster output: omit raw registers; raster vertices remain exact. */
- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
