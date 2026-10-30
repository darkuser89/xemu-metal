#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PENDING_NATIVE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PENDING_NATIVE_H
/* Native stream adapter. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#import "pending-journal.h"
#import "vertex-stream.h"
NS_ASSUME_NONNULL_BEGIN
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPendingNative : NSObject
@property(nonatomic, readonly) NSArray<NSNumber *> *counts;
/* Validates every resource/offset/length on the CPU before any GPU encoding.
 * Only update.streams are drawn; a preserved hidden last range stays cached.
 * Caller retains immutable buffers and serializes journal operations. */
- (nullable instancetype)initWithUpdate:(NV2AMetalPendingUpdate *)update
                                 device:(id<MTLDevice>)device
                                  limit:(NSUInteger)limit
                                  error:(NSError *_Nullable *_Nullable)error;
/* Independent streams may together exceed a single buffer's capacity. */
- (nullable instancetype)initWithUpdate:(NV2AMetalPendingUpdate *)update
                                 device:(id<MTLDevice>)device
                            streamLimit:(NSUInteger)streamLimit
                             totalLimit:(NSUInteger)totalLimit
                                  error:(NSError *_Nullable *_Nullable)error;
/* One immutable GPU buffer per independent stream; use counts, not buffer
 * lengths, for the valid vertex ranges. No vertex readback or journal commit.
 * On any encoding failure caller must abandon the recording, not submit it. */
- (nullable NSArray<id<MTLBuffer>> *)
    encodeWithCommands:(NV2AMetalCommands *)commands
                 error:(NSError *_Nullable *_Nullable)error;
/* Drawing variant preserving a contiguous source's nonzero first vertex.
 * Independent streams remain independent; fragmented streams are GPU-joined.
 * Slices retain their immutable buffers; commands keep them resident. */
- (nullable NSArray<NV2AMetalVertexSlice *> *)
    encodeSlicesWithCommands:(NV2AMetalCommands *)commands
                       error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
#endif
