/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_DRAW_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_DRAW_PGRAPH_H
#import "surface-pgraph.h"
#import "reports-pgraph.h"
#import "blit-pgraph.h"

NS_ASSUME_NONNULL_BEGIN
/* Native PGRAPH batch controller. Calls require pg.lock; it consumes the
 * current common-PGRAPH batch without resetting its lengths or connecting
 * independent DrawArrays ranges. Surface/texture/fetch checkpoints precede
 * final attachment and state capture. Dynamic program faults are checked
 * before any fragment draw. Completed transformed ranges survive failed
 * retries; only new suffixes run XF, and consumption follows successful
 * submission. VRAM and NV2AState outlive the controller. Close after stopping CPU access.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHDraw : NSObject
@property(nonatomic, readonly) NV2AMetalPGRAPHSurfaces *surfaces;
@property(nonatomic, readonly) NV2AMetalPGRAPHReports *reports;
@property(nonatomic, readonly) NV2AMetalPGRAPHBlit *blitter;
- (nullable instancetype)initWithState:(NV2AState *)state
                              surfaces:(NV2AMetalPGRAPHSurfaces *)surfaces
                                 error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/* Begin captures shader/raster/texture state. Flush uses late vertex inputs
 * without completing the guest End or resetting common-PGRAPH batch lengths.
 * End advances draw_time once, including an empty non-nop block. Missing
 * raster accesses still execute XF; its checkpoint preserves common Current
 * state, and no raster attachment, fragment draw or passing query is created.
 */
- (BOOL)beginWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)flushDrawWithError:(NSError *_Nullable *_Nullable)error;
/* Ordered XF boundaries preserve the running primitive and common inputs.
 * Mutation preparation runs the old suffix before the caller changes state;
 * the replacement capture is validated only when another suffix uses it. */
- (BOOL)prepareVertexStateChangeWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)launchStateProgram:(NSUInteger)start
                     error:(NSError *_Nullable *_Nullable)error;
- (nullable NSData *)pendingSnapshotWithError:
    (NSError *_Nullable *_Nullable)error;
- (BOOL)restorePendingSnapshot:(NSData *)data
                         error:(NSError *_Nullable *_Nullable)error;
- (BOOL)endWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)clearSurface:(uint32_t)parameter
               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)drawWithError:(NSError *_Nullable *_Nullable)error;
/* Discard only host captures after invalidation; common input arrays survive.
 * The callback layer reconstructs an active Begin from restored/live registers.
 */
- (void)invalidateSession;
/* Flush GPU VRAM without resetting input batches or immutable Begin captures.
 * Retained texture snapshots outlive cache eviction. Loads explicitly discard
 * captures; scale changes preserve them. */
- (BOOL)flushWithError:(NSError *_Nullable *_Nullable)error;
/* GL's explicit surface flush additionally rebinds live attachment registers,
 * preserving the current Begin's shader/raster/viewport and query captures. */
- (BOOL)flushSurfacesWithError:(NSError *_Nullable *_Nullable)error;
/* Discard obsolete state after RAM load; no new VRAM writebacks. Submitted
 * writes must already have completed before the loader replaced RAM. */
- (BOOL)discardForRestoreWithError:(NSError *_Nullable *_Nullable)error;
/* Vertex capture is separate from live vertex-input state. Empty data means
 * no active Begin. Import stages the capture for the next Begin. */
- (nullable NSData *)beginSnapshotWithError:
    (NSError *_Nullable *_Nullable)error;
- (BOOL)restoreBeginSnapshot:(NSData *)data
                       error:(NSError *_Nullable *_Nullable)error;
- (NSData *)vertexSnapshot;
- (BOOL)restoreVertexSnapshot:(NSData *)data
                        error:(NSError *_Nullable *_Nullable)error;
- (nullable NSData *)reportSnapshotWithError:
    (NSError *_Nullable *_Nullable)error;
- (BOOL)restoreReportSnapshot:(NSData *)data
                        error:(NSError *_Nullable *_Nullable)error;
- (BOOL)closeWithError:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
