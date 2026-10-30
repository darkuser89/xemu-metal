#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PENDING_JOURNAL_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PENDING_JOURNAL_H
/* Pending transformed-stream bookkeeping.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import <Foundation/Foundation.h>
#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(unsigned, NV2AMetalInputKind) {
    NV2AMetalInputArrays = 1,
    NV2AMetalInputIndexed,
    NV2AMetalInputInlineBuffer,
    NV2AMetalInputInlineArray
};
@interface NV2AMetalPendingInput : NSObject
@property(nonatomic, readonly) NV2AMetalInputKind kind;
@property(nonatomic, readonly) NSUInteger first, count;
@property(nonatomic, readonly) NSData *indices;
/* Bounds cover every LE32 index, including any previously accepted prefix. */
@property(nonatomic, readonly) uint32_t minimumIndex, maximumIndex;
+ (nullable instancetype)arraysFrom:(NSUInteger)first count:(NSUInteger)count;
+ (nullable instancetype)indexed:(NSData *)indices;
/* Caller keeps bytes stable during this call. Reuse requires a byte-identical
 * prefix; mutable guest storage is never retained by the descriptor. */
+ (nullable instancetype)indexedBytes:(const void *_Nullable)bytes
                                count:(NSUInteger)count
                     matchingPrevious:
                         (nullable NV2AMetalPendingInput *)previous;
+ (nullable instancetype)inlineKind:(NV2AMetalInputKind)kind
                              count:(NSUInteger)count;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* The resource is an immutable owner supplied by the vertex executor. Journal
 * bookkeeping does not inspect it. Native stream assembly must validate the
 * MTLBuffer device/bounds before encoding; CPU tests use immutable identifiers.
 */
@interface NV2AMetalPendingSpan : NSObject
@property(nonatomic, readonly) id resource;
@property(nonatomic, readonly) NSUInteger first, count;
+ (nullable instancetype)resource:(id)resource
                            first:(NSUInteger)first
                            count:(NSUInteger)count;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
@interface NV2AMetalPendingPlan : NSObject
@property(nonatomic, readonly) NSArray<NV2AMetalPendingInput *> *inputs;
@property(nonatomic, readonly) NSArray<NSNumber *> *prefixCounts;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
@interface NV2AMetalPendingUpdate : NSObject
@property(nonatomic, readonly)
    NSArray<NSArray<NV2AMetalPendingSpan *> *> *streams;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* A single validated plan, advanced in input order. Each successful nonempty
 * suffix publishes its range separately, retaining it across later failures.
 * A reset, consume, or unrelated commit invalidates the cursor; failed
 * validation never advances it.
 */
@interface NV2AMetalPendingProgress : NSObject
@property(nonatomic, readonly) NSUInteger nextInput;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* Caller serializes all operations under pg.lock. Plan/prepare are immutable;
 * commit publishes every transformed suffix together. Consume happens only
 * after successful drawing. State boundaries commit without consuming.
 * No vertex math, GPU command, input-array mutation or PGRAPH write occurs. */
@interface NV2AMetalPendingJournal : NSObject
@property(nonatomic, readonly) NSUInteger streamCount, generation;
@property(nonatomic, readonly) NSArray<NV2AMetalPendingInput *> *retainedInputs;
@property(nonatomic, readonly)
    NSArray<NSArray<NV2AMetalPendingSpan *> *> *retainedStreams;
- (nullable instancetype)initWithLimit:(NSUInteger)limit;
- (nullable NV2AMetalPendingPlan *)
             planInputs:(NSArray<NV2AMetalPendingInput *> *)inputs
    preservingLastArray:(BOOL)preserve
                  error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalPendingProgress *)
    beginProgressForPlan:(NV2AMetalPendingPlan *)plan
                   error:(NSError *_Nullable *_Nullable)error;
/* nil is required for an already transformed input. Progress does not consume
 * streams or change the immutable plan. Retained snapshots stay immutable. */
- (BOOL)commitNextSuffix:(nullable NV2AMetalPendingSpan *)suffix
                progress:(NV2AMetalPendingProgress *)progress
                   error:(NSError *_Nullable *_Nullable)error;
/* One result per input: a suffix span starting at its own buffer's offset, or
 * NSNull when no new vertices exist. Its count must match count-prefixCount. */
- (nullable NV2AMetalPendingUpdate *)preparePlan:(NV2AMetalPendingPlan *)plan
                                        suffixes:(NSArray *)suffixes
                                           error:(NSError *_Nullable *_Nullable)
                                                     error;
/* Stage only the completed leading inputs of a current full plan. Unfinished
 * inputs retain their previous streams. This publishes completed ranges before
 * a later range can fault; the returned partial update cannot be consumed. */
- (nullable NV2AMetalPendingUpdate *)preparePlan:(NV2AMetalPendingPlan *)plan
                                 completedInputs:(NSUInteger)completed
                                        suffixes:(NSArray *)suffixes
                                           error:(NSError *_Nullable *_Nullable)
                                                     error;
- (BOOL)commitUpdate:(NV2AMetalPendingUpdate *)update
               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)consumeUpdate:(NV2AMetalPendingUpdate *)update
                error:(NSError *_Nullable *_Nullable)error;
/* Private host transaction with the same immutable input/span owners. Plans
 * and progress stay bound to their original journal. Replace the caller's
 * journal only after its queued GPU work is accepted; discard on failure. */
- (nullable NV2AMetalPendingJournal *)copyForTransaction;
- (void)reset;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
#endif
