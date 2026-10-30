/* Native visibility reports from gl/reports.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_REPORTS_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_REPORTS_PGRAPH_H
#import "surface-cache.h"
typedef struct NV2AState NV2AState;

NS_ASSUME_NONNULL_BEGIN
/* A bounded native visibility range. GPU storage may be released after its
 * recording completes; reports then retain the captured uint64 value. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalVisibilityCounter : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> buffer;
@property(nonatomic, readonly) NSUInteger offset;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* One guest Begin/End query may contain several independently submitted
 * batches. Only successfully submitted visibility buffers join its result.
 * Reports freeze prefixes without ending the guest Begin or rounding each
 * physical batch independently. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHQuery : NSObject
@property(nonatomic, readonly) BOOL discarded;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* All calls require the PGRAPH thread and pg.lock. GPU counting is native
 * Metal 4; CPU reads only completed 64-bit counters, never render pixels. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHReports : NSObject
/* Existing storage can stay bound with visibility testing disabled, keeping
 * query/non-query transitions compatible. This getter never allocates. */
@property(nonatomic, readonly, nullable) id<MTLBuffer> visibilityBuffer;
- (instancetype)initWithState:(NV2AState *)state
                        cache:(NV2AMetalSurfaceCache *)cache;
/* A smaller bounded capacity also permits deterministic pressure tests. */
- (nullable instancetype)initWithState:(NV2AState *)state
                                 cache:(NV2AMetalSurfaceCache *)cache
                       counterCapacity:(NSUInteger)capacity;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (NV2AMetalPGRAPHQuery *)beginQuery;
- (void)endQuery:(nullable NV2AMetalPGRAPHQuery *)query;
- (void)cancelQuery:(NV2AMetalPGRAPHQuery *)query;
- (void)commitBuffer:(id<MTLBuffer>)buffer query:(NV2AMetalPGRAPHQuery *)query;
/* Allocation may drain at pool pressure. Call before preparing raster
 * packets, since that drain can end the current producer recording. */
- (nullable NV2AMetalVisibilityCounter *)allocateCounterWithError:
    (NSError *_Nullable *_Nullable)error;
/* Bind the current cache recording after pass/packet preparation and before
 * any GPU use. A failed draw cancels its recording before cancelling its
 * counter. Accepted counters remain owned until actual GPU completion. */
- (BOOL)recordCounter:(NV2AMetalVisibilityCounter *)counter
                error:(NSError *_Nullable *_Nullable)error;
- (void)commitCounter:(NV2AMetalVisibilityCounter *)counter
                query:(NV2AMetalPGRAPHQuery *)query;
- (void)cancelCounter:(nullable NV2AMetalVisibilityCounter *)counter;
- (void)clear;
- (BOOL)getReport:(uint32_t)parameter
            error:(NSError *_Nullable *_Nullable)error;
/* getReport freezes the already committed prefix, even during an open Begin.
 * Later batches continue the same Begin without modifying queued reports.
 * Clear discards only the unreported window; previously queued reports survive.
 * Processing waits for frozen GPU counters and writes reports in FIFO order. */
- (BOOL)processWithError:(NSError *_Nullable *_Nullable)error;
/* Portable snapshot of completed counters, FIFO relationships and runtime
 * raster scale, never GPU handles. Export waits for submitted work. Import
 * replaces state and restores scale atomically; discard old surfaces first.
 * v3 retains each Begin's reported raw prefix so scale rounding crosses report
 * boundaries without loss. v1/v2 remain readable with a zero reported prefix.
 */
- (nullable NSData *)
    snapshotWithActiveQuery:(nullable NV2AMetalPGRAPHQuery *)query
                      error:(NSError *_Nullable *_Nullable)error;
- (BOOL)restoreSnapshot:(NSData *)data
            activeQuery:(NV2AMetalPGRAPHQuery *_Nullable *_Nonnull)query
                  error:(NSError *_Nullable *_Nullable)error;
/* Called after GPU quiescence at restore or destruction. */
- (void)discard;
@end
NS_ASSUME_NONNULL_END
#endif
