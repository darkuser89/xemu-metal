/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_COMBINER_H

#import "command.h"
#include "pixel-combiner-types.h"

NS_ASSUME_NONNULL_BEGIN

/* Shared validation for the compute harness and later fragment pipelines.
 * A disabled final combiner leaves fragColor undefined in the GL generator;
 * reject it until its hardware behavior has been established. */
BOOL nv2a_metal_combiner_validate(const NV2AMetalCombinerState *state,
                                  NSError *_Nullable *_Nullable error);

API_AVAILABLE(macos(26.0))
@interface NV2AMetalCombinerResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> outputs;
@property(nonatomic, readonly) NSUInteger count;
@end

API_AVAILABLE(macos(26.0))
@interface NV2AMetalPixelCombiner : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Executes the fragment combiner function with supplied texture-stage colors.
 * states contains either one broadcast state or count per-pixel states;
 * it is copied during encoding. Inputs may be produced by another GPU stage.
 * Returns count NV2AMetalCombinerOutputs; an empty operation allocates no
 * output buffer and dispatches no GPU work. */
- (nullable NV2AMetalCombinerResult *)
    encodeInputs:(id<MTLBuffer>)inputs
           count:(NSUInteger)count
          states:(const NV2AMetalCombinerState *)states
      stateCount:(NSUInteger)stateCount
        commands:(NV2AMetalCommands *)commands
           error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
