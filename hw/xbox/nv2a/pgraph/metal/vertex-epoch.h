/* Captured XF epoch executor. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_EPOCH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_EPOCH_H

#import "vertex-pgraph.h"
#import "vertex-writable.h"
NS_ASSUME_NONNULL_BEGIN
API_AVAILABLE(macos(26.0))
@interface NV2AMetalEpochResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> registers, vertices;
@property(nonatomic, readonly) NSUInteger vertexCount;
@property(nonatomic, readonly) NSData *constants, *written;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* Resolve only after successful completion of the supplied command recording.
 * The encoding retains its GPU outputs until the immutable result is published.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalEpochEncoding : NSObject
- (nullable NV2AMetalEpochResult *)resolveWithError:
    (NSError *_Nullable *_Nullable)error;
/* Fixed context is immutable host metadata and has no XF fault readback.
 * Return it with pending GPU vertex buffers for consumers on the SAME queue.
 * This does not make vertices CPU-readable. Programmed XF is rejected. */
- (nullable NV2AMetalEpochResult *)
    fixedResultForCommands:(NV2AMetalCommands *)commands
                     error:(NSError *_Nullable *_Nullable)error;
/* Fixed or proven-fault-free readonly context, with pending GPU vertices.
 * The source work must remain queued on these same commands. Programmed
 * output additionally requires its original live recording. */
- (nullable NV2AMetalEpochResult *)
    pendingResultForCommands:(NV2AMetalCommands *)commands
                       error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* Synchronous native GPU execution; caller has completed the input producer.
 * Constant feedback is returned privately. This class does not mutate PGRAPH,
 * consume the pending journal, close a primitive, or commit guest commands. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalEpochExecutor : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalEpochResult *)
       executeState:(NV2AMetalPGRAPHVertexState *)state
    attributeBuffer:(id<MTLBuffer>)attributes
              first:(NSUInteger)first
              count:(NSUInteger)count
              error:(NSError *_Nullable *_Nullable)error;
/* Synchronous draw output with nil registers. Discarded output also has
 * nil vertices: only its count/context is retained. This synchronous API
 * completes one Writable context before returning its private result. */
- (nullable NV2AMetalEpochResult *)
    executeRasterState:(NV2AMetalPGRAPHVertexState *)state
       attributeBuffer:(id<MTLBuffer>)attributes
                 first:(NSUInteger)first
                 count:(NSUInteger)count
                 error:(NSError *_Nullable *_Nullable)error;
/* Fixed/readonly XF can follow attribute fetch in the same command recording.
 * Full diagnostic output still rejects a writable capture. Use the explicit
 * serial chain below for programs that can modify constant context. */
- (nullable NV2AMetalEpochEncoding *)
        encodeState:(NV2AMetalPGRAPHVertexState *)state
    attributeBuffer:(id<MTLBuffer>)attributes
              first:(NSUInteger)first
              count:(NSUInteger)count
           commands:(NV2AMetalCommands *)commands
              error:(NSError *_Nullable *_Nullable)error;
/* Draw-only independent output, with nil raw registers. A write-enabled
 * capture is accepted only when its validated instructions cannot write any
 * constants. Guest capture flags remain unchanged. Discarded output has nil
 * vertices; only Fixed raw XF skips unobserved transform work. */
- (nullable NV2AMetalEpochEncoding *)
    encodeRasterState:(NV2AMetalPGRAPHVertexState *)state
      attributeBuffer:(id<MTLBuffer>)attributes
                first:(NSUInteger)first
                count:(NSUInteger)count
             commands:(NV2AMetalCommands *)commands
                error:(NSError *_Nullable *_Nullable)error;
/* Explicit serial Writable chain. All ranges must share one recording;
 * constants flow on GPU while individual feedback remains immutable. Resolve
 * and publish in range order after Fetch and the recording succeed. */
- (nullable NV2AMetalEpochEncoding *)
    encodeSerialRasterState:(NV2AMetalPGRAPHVertexState *)state
            attributeBuffer:(id<MTLBuffer>)attributes
                      first:(NSUInteger)first
                      count:(NSUInteger)count
                   previous:(NV2AMetalEpochEncoding *_Nullable)previous
                   commands:(NV2AMetalCommands *)commands
                      error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END

#endif
