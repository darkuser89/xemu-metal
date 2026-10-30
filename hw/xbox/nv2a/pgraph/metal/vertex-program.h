/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PROGRAM_H

#import "command.h"
#include "vertex-program-types.h"

NS_ASSUME_NONNULL_BEGIN

BOOL nv2a_metal_program_validate(
    const uint32_t *_Nullable tokens, NSUInteger length,
    const NV2AMetalProgramUniforms *_Nullable uniforms,
    NSError *_Nullable *_Nullable error);

API_AVAILABLE(macos(26.0))
@interface NV2AMetalProgramResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> registers;
@property(nonatomic, readonly, nullable) id<MTLBuffer> vertices;
@property(nonatomic, readonly) NSUInteger vertexCount;
@end

/* Executes NV2A microcode directly in MSL through MTL4 compute. Inputs are
 * decoded Float4 attributes; the attribute-fetch frontend is separate. Raw
 * registers allow inspection of dynamic-address faults after GPU completion.
 * vertices uses NV2AMetalVertex and feeds the native geometry stage directly.
 * Mutable constants and undefined outputs are rejected, as they have no
 * working implementation in the reference GL generator. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalVertexProgram : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NV2AMetalProgramResult *)
    encodeTokens:(const uint32_t *)tokens
          length:(NSUInteger)length
        uniforms:(const NV2AMetalProgramUniforms *)uniforms
      attributes:(id<MTLBuffer>)attributes
           count:(NSUInteger)count
        commands:(NV2AMetalCommands *)commands
           error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
