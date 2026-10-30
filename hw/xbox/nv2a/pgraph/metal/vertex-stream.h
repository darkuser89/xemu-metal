#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_STREAM_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_STREAM_H
/* Native Metal4 vertex-stream assembly.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "command.h"
#include "geometry-types.h"

NS_ASSUME_NONNULL_BEGIN
/* Immutable drawing view. The valid range is measured in vertices; buffer
 * length may include unrelated prefix/suffix records. No bytes are copied. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalVertexSlice : NSObject
@property(nonatomic, readonly) id<MTLBuffer> buffer;
@property(nonatomic, readonly) NSUInteger firstVertex, vertexCount;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

API_AVAILABLE(macos(26.0))
@interface NV2AMetalVertexStream : NSObject
@property(nonatomic, readonly) NSUInteger vertexCount;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  limit:(NSUInteger)limit
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/* Appending does not transform or draw. Inputs must remain immutable until
 * commands using them finish. Independent primitive streams use separate
 * instances; a state-program boundary does not end a strip, fan or polygon. */
- (BOOL)appendVertices:(nullable id<MTLBuffer>)vertices
                 first:(NSUInteger)first
                 count:(NSUInteger)count
                 error:(NSError *_Nullable *_Nullable)error;
/* Snapshot-only zero transport. No allocation or GPU encoding while appending;
 * drawing variants reject streams containing these discarded segments. */
- (BOOL)appendDiscardedVertices:(NSUInteger)count
                          error:(NSError *_Nullable *_Nullable)error;
/* Requires a live recording. Copies all segments into a new shared buffer
 * with exactly vertexCount vertices, suitable for snapshot readback after
 * GPU completion. Empty streams return nil without an error. */
- (nullable id<MTLBuffer>)encodeWithCommands:(NV2AMetalCommands *)commands
                                       error:
                                           (NSError *_Nullable *_Nullable)error;
/* Requires a live recording. A contiguous stream starting at buffer offset
 * zero reuses its immutable source; other streams are joined on the MTL4
 * encoder. Only vertexCount vertices are valid, regardless of buffer length.
 * Consumers must not mutate the result and must synchronize with its GPU
 * producer. The recording retains the resident result until completion.
 * Empty streams return nil without an error. No CPU vertex readback occurs. */
- (nullable id<MTLBuffer>)
    encodeForDrawingWithCommands:(NV2AMetalCommands *)commands
                           error:(NSError *_Nullable *_Nullable)error;
/* Offset-aware drawing: reuse any one contiguous source range. Multiple
 * disjoint ranges still join on GPU and return a view starting at zero.
 * The same immutability, recording and ownership rules apply. */
- (nullable NV2AMetalVertexSlice *)
    encodeSliceForDrawingWithCommands:(NV2AMetalCommands *)commands
                                error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
