#ifndef HW_XBOX_NV2A_PGRAPH_METAL_ARCHIVE_NATIVE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_ARCHIVE_NATIVE_H
/* Native pending transport. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#import "pending-archive.h"
#import "vertex-stream.h"
NS_ASSUME_NONNULL_BEGIN
/* Exact zero-valued transport for discarded raster output, with no GPU
 * allocation. Drawing adapters must reject this resource. Snapshot capture
 * materializes its bytes with a Metal fill; no vertex program is replayed. */
__attribute__((objc_subclassing_restricted))
@interface NV2AMetalDiscardedVertices : NSObject
@property(nonatomic, readonly) NSUInteger count;
- (nullable instancetype)initWithCount:(NSUInteger)count;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* Caller holds pg.lock and has completed previous producer commands. Commands
 * must not have an active recording. Captures all cached ranges, including the
 * hidden last one. Restore uploads transformed bytes; no vertex program runs.
 * Neither function changes any existing journal or PGRAPH/Begin/Query state. */
API_AVAILABLE(macos(26.0))
NV2AMetalPendingArchive *_Nullable nv2a_metal_pending_capture(
    NV2AMetalPendingJournal *journal, NV2AMetalCommands *commands,
    NSError *_Nullable *_Nullable error);
API_AVAILABLE(macos(26.0))
NV2AMetalPendingJournal *_Nullable nv2a_metal_pending_restore(
    NV2AMetalPendingArchive *archive, NV2AMetalCommands *commands,
    NSUInteger limit, NSError *_Nullable *_Nullable error);
/* Only for a validated raw-only outer capture. Zero payloads become discarded
 * resources; nonzero legacy bytes retain their exact GPU-backed transport. */
API_AVAILABLE(macos(26.0))
NV2AMetalPendingJournal *_Nullable nv2a_metal_pending_restore_raw(
    NV2AMetalPendingArchive *archive, NV2AMetalCommands *commands,
    NSUInteger limit, NSError *_Nullable *_Nullable error);
NS_ASSUME_NONNULL_END
#endif
