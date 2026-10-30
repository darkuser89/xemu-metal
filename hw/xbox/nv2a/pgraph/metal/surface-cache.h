/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_CACHE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_CACHE_H

#import "surface-transfer.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^NV2AMetalVRAMWriteHandler)(NSUInteger address,
                                          NSUInteger length);

API_AVAILABLE(macos(26.0))
@interface NV2AMetalCachedSurface : NSObject
@property(nonatomic, readonly) NV2AMetalSurfaceTransfer *transfer;
@property(nonatomic, readonly) NSUInteger address, reservationLength;
@property(nonatomic, readonly) uint64_t frame;
/* Texture-cache captures can key by entry identity and generation. Cancelled
 * writes roll back the visible generation; allocated values are never reused.
 */
@property(nonatomic, readonly) uint64_t generation;
/* Invalidation stamp for dirty-publication observers. Read before the locked
 * dirty getter; a different later stamp requires another publication. MAX
 * permanently disables a no-work shortcut instead of wrapping. */
@property(nonatomic, readonly) uint64_t dirtyEpoch;
@property(nonatomic, readonly) BOOL valid, dirty, needsUpload,
    scanoutClampToBorder;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* A recording token lets dependent caches discard work cancelled before
 * submission, even after the command-buffer slot has been reused. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalSurfaceRecording : NSObject
@property(nonatomic, readonly) BOOL submitted, completed, cancelled;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* Encoding belongs to the PGRAPH thread; cache metadata has a separate
 * recursive guard shared with cached-surface generation/upload getters.
 * CPU callers may use tryIdleCPUAccess without the PGRAPH lock. Other methods
 * remain on the PGRAPH thread. The guard never acquires
 * PGRAPH/PFIFO locks. The shared VRAM buffer must alias the frontend's RAM;
 * route CPU reads/writes through its access hook before touching the bytes.
 * The frontend must route TCG hooks or dirty-page notifications to these
 * methods and publish completed downloads to VGA/texture dirty tracking.
 * The completion handler runs on this thread after submission completion; do
 * not reenter the cache from that handler. Use this cache's submit/cancel/idle
 * methods, never mutate commands directly. Commands are exposed only so native
 * renderers can encode into the recording. Flush before saving VRAM, global
 * scale changes or destruction. Before RAM loading, flush current state so a
 * failed load can resume it; after loading, discardForRestore invalidates
 * obsolete surfaces without new downloads. */
typedef struct NV2AMetalCPUAccessGuard NV2AMetalCPUAccessGuard;
typedef struct {
    NSUInteger address, length;
} NV2AMetalVRAMReadSpan;
/* A zero stride denotes one contiguous span. Otherwise length ends at the
 * last element's end and only element bytes in each stride are read. */
typedef struct {
    NSUInteger address, length, stride, element;
} NV2AMetalVRAMReadPattern;
/* A PGRAPH-owned read recording on another queue. The cache retains submitted
 * scopes, including cancelled producers, until their GPU feedback is complete.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalIndependentReads : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* Conservative, lock-free check for RAM with no GPU ownership. Reads must
 * avoid all prior GPU write destinations. Writes must also avoid all prior
 * GPU sources/cache keys. Before first GPU use there is no cached content to
 * invalidate; the normal dirty-page journal still records the RAM write.
 * A false result requires the synchronized access path. */
BOOL nv2a_metal_untracked_cpu_access(const NV2AMetalCPUAccessGuard *guard,
                                     NSUInteger address, NSUInteger length,
                                     BOOL write);

/* CPU-hook fast path. Pure source/key pages with no active GPU reader record
 * deferred dirty bits instead of entering cache metadata. The next source-key
 * query publishes a fresh version. GPU destinations and active readers still
 * require the synchronized path. A false result may conservatively invalidate
 * a source key but never permits the CPU access. */
BOOL nv2a_metal_try_cpu_access(NV2AMetalCPUAccessGuard *_Nullable guard,
                               NSUInteger address, NSUInteger length,
                               BOOL write);

API_AVAILABLE(macos(26.0))
@interface NV2AMetalSurfaceCache : NSObject
@property(nonatomic, readonly) NV2AMetalCommands *commands;
@property(nonatomic, readonly) id<MTLBuffer> vram;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly) NV2AMetalCPUAccessGuard *cpuAccessGuard;
/* PGRAPH thread only; called before first GPU ownership of each RAM page.
 * Install the frontend's CPU hook here. Do not reenter the cache. */
@property(nonatomic, copy, nullable) NV2AMetalVRAMWriteHandler willWatchVRAM;
@property(nonatomic, readonly, nullable) NV2AMetalSurfaceRecording *recording;
/* PGRAPH draw owner only. Producer work inside this scope may precede earlier
 * compatible raster sections. Texture/VRAM dependencies and external work
 * still close that chain before consuming its targets. No encoder is opened. */
- (BOOL)beginRasterProducersWithError:(NSError *_Nullable *_Nullable)error;
- (void)endRasterProducers;
/* Call after all geometry producers and before preparing pixel packets.
 * A changed descriptor submits the old chain, then reacquires attachments in
 * the current recording. Include read-only depth/stencil attachments too. */
- (BOOL)prepareRasterPass:(MTL4RenderPassDescriptor *)pass
                  targets:(NSArray<NV2AMetalCachedSurface *> *)targets
                    error:(NSError *_Nullable *_Nullable)error;
/* Order an RTT texture read before its copy is encoded, including clean
 * read-only attachments in a pending raster chain. */
- (BOOL)prepareTextureRead:(NV2AMetalCachedSurface *)surface
                     error:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithCommands:(NV2AMetalCommands *)commands
                                     vram:(id<MTLBuffer>)vram
                             didWriteVRAM:
                                 (nullable NV2AMetalVRAMWriteHandler)handler
                                    error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Reuses compatible larger bindings as GL does; use the returned transfer's
 * dimensions for viewport/uniform capture. Overlaps/incompatible bindings are
 * written back before replacement. A new recording/upload starts if needed. */
- (nullable NV2AMetalCachedSurface *)
    prepareSurfaceAtAddress:(NSUInteger)address
                     config:(const NV2AMetalSurfaceConfig *_Nullable)config
                      frame:(uint64_t)frame
                      error:(NSError *_Nullable *_Nullable)error;
/* Capture-only preparation validates/reuses the same binding and performs
 * required uploads, but does not open a recording for an already current
 * texture. Prepare for rendering again before encoding attachment writes. */
- (nullable NV2AMetalCachedSurface *)
    prepareSurfaceAtAddress:(NSUInteger)address
                     config:(const NV2AMetalSurfaceConfig *_Nullable)config
                      frame:(uint64_t)frame
               forRendering:(BOOL)forRendering
                      error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalCachedSurface *)surfaceContainingAddress:
    (NSUInteger)address;

/* Call only after successfully encoding a draw/clear that can write this
 * attachment, prepared in this recording. Cancel the section on encoding
 * errors. A checkpoint accepts its metadata; cancel rolls back only the new
 * suffix. GPU ownership remains protected until submission completion. */
- (BOOL)markWritten:(NV2AMetalCachedSurface *)surface
              error:(NSError *_Nullable *_Nullable)error;
/* Mirror GL's persistent RTT sampler change in the same host transaction. */
- (BOOL)markRTTSampling:(NV2AMetalCachedSurface *)surface
                  error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitWithError:(NSError *_Nullable *_Nullable)error;
/* Accept successful work without submitting it. Later cancel drops only its
 * unaccepted suffix; accepted sections remain ordered and protected. The
 * bounded command batch submits automatically when full or under resource
 * pressure. This is a host transaction boundary, not GPU completion. */
- (BOOL)checkpointWithError:(NSError *_Nullable *_Nullable)error;
/* Wait for a submission and its earlier feedback prefix on this cache's
 * queue, then retire completed ownership on the PGRAPH thread. A later
 * recording stays open and protected; later submissions need not finish.
 * Validate the required source queues' feedback prefixes before publishing
 * dependent RAM writes, even if this queue's GPU work is already complete.
 * Pending readers also supply GPU-written completion witnesses; an event
 * timeout or an unsatisfied dependency keeps CPU ownership closed. */
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError *_Nullable *_Nullable)error;
/* Cancel only the current unaccepted section, preserving earlier checkpoints.
 * discardForRestore also discards those accepted, unsubmitted sections. */
- (void)cancel;
/* PGRAPH owner only: retire the completed submission prefix without waiting.
 * Keep pending/later sources protected, publish downloads and complete tokens
 * on this thread, never on the Metal feedback thread. Failure is sticky. */
- (BOOL)collectCompletedWithError:(NSError *_Nullable *_Nullable)error;
/* A direct wait releases the metadata guard while the GPU drains; submitted
 * read/download spans remain protected. An enclosing cache transaction retains
 * its guard. Only the PGRAPH owner may call this method or change submissions.
 */
- (BOOL)waitUntilIdleWithError:(NSError *_Nullable *_Nullable)error;

/* Preserve overlapping GPU pixels into shared VRAM in this recording, then
 * allow a native decoder to consume those bytes with queue barriers. Ordered
 * downloads need no CPU wait, pixel readback or notification; overlapping
 * independent readers must finish before a download writes their VRAM.
 * Register the entire span before
 * encoding any GPU read of shared VRAM; it protects against CPU writes until
 * submit/idle or cancel. Submit/cancel remains atomic
 * with the surface metadata. Version includes CPU writes and pending surface
 * writes; retired surface versions survive in the VRAM page journal. */
- (BOOL)prepareGPUReadAtAddress:(NSUInteger)address
                         length:(NSUInteger)length
                          error:(NSError *_Nullable *_Nullable)error;
- (BOOL)prepareGPUReadPattern:(NV2AMetalVRAMReadPattern)pattern
                        error:(NSError *_Nullable *_Nullable)error;
/* Begin a producer only when every span is independent of dirty surfaces,
 * pending/submitted downloads and GPU writes. Clean surface aliases may share
 * readonly VRAM. YES with nil reads requests the original queue
 * path. No VRAM copy is made. An empty span list also tracks CPU-owned
 * snapshots, without registering VRAM ownership. Commands must be a separate
 * queue on this device with no open recording, owned by the PGRAPH thread.
 * Submit/cancel through these methods;
 * never mutate that queue directly while the scope is live. CPU writes and
 * later GPU destinations retain read ownership until actual GPU completion. */
- (BOOL)tryBeginIndependentReads:(const NV2AMetalVRAMReadSpan *_Nullable)spans
                           count:(NSUInteger)count
                        commands:(NV2AMetalCommands *)commands
                           reads:
                               (NV2AMetalIndependentReads *_Nullable *_Nonnull)
                                   reads
                           error:(NSError *_Nullable *_Nullable)error;
- (BOOL)tryBeginIndependentReadPatterns:
            (const NV2AMetalVRAMReadPattern *_Nullable)patterns
                                  count:(NSUInteger)count
                               commands:(NV2AMetalCommands *)commands
                                  reads:(NV2AMetalIndependentReads *_Nullable
                                             *_Nonnull)reads
                                  error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitIndependentReads:(NV2AMetalIndependentReads *)reads
                         error:(NSError *_Nullable *_Nullable)error;
/* Wait through this producer's feedback prefix, including older submitted
 * cancellations, and submitted writer prefixes that retain its GPU read
 * witnesses. Other producers' feedback and later unrelated surface work need
 * not finish; open recordings stay intact. Failure is sticky and keeps CPU
 * access and dependent Fetch/Current publication closed. */
- (BOOL)completeIndependentReads:(NV2AMetalIndependentReads *)reads
                           error:(NSError *_Nullable *_Nullable)error;
- (void)cancelIndependentReads:(NV2AMetalIndependentReads *)reads;
/* Register direct GPU writes to shared VRAM before encoding them. The caller
 * invalidates overlapping surfaces first and publishes dirty/version changes
 * after completion. Both CPU reads and writes wait for these spans until idle
 * or cancellation. Submit/cancel remains atomic with the other metadata. */
- (BOOL)prepareGPUWriteAtAddress:(NSUInteger)address
                          length:(NSUInteger)length
                           error:(NSError *_Nullable *_Nullable)error;
- (BOOL)sourceVersionAtAddress:(NSUInteger)address
                        length:(NSUInteger)length
                       version:(uint64_t *_Nullable)version
                         error:(NSError *_Nullable *_Nullable)error;

/* Drains prior uploads/draws/downloads before CPU access. Partial CPU writes
 * first preserve all dirty GPU pixels, then make overlapping bindings require
 * reupload. Zero length is a no-op. Range checks never wrap address+length. */
- (BOOL)prepareCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                            error:(NSError *_Nullable *_Nullable)error;
/* Under the cache metadata guard, complete a CPU read unless an overlapping
 * dirty surface or pending download needs servicing. CPU writes also wait for
 * overlapping deferred VRAM reads and recorded surface metadata. Unrelated
 * CPU writes can complete while GPU work is active. completed=NO requires the
 * normal PGRAPH-thread path. This method never encodes, submits or waits for
 * GPU work.
 */
- (BOOL)tryIdleCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                        completed:(BOOL *)completed
                            error:(NSError *_Nullable *_Nullable)error;
/* Dirty-page fallback is after an unhooked CPU write. GPU-owned overlapping
 * pixels cannot safely be preserved at that point; reject a coherence conflict.
 * Frontends without TCG hooks must drain GPU writes before allowing CPU access.
 * Unrelated GPU work stays recorded/in flight; overlapping reads, downloads
 * and recorded clean surfaces retain the synchronized access path.
 */
- (BOOL)observeCPUWriteAtAddress:(NSUInteger)address
                          length:(NSUInteger)length
                           error:(NSError *_Nullable *_Nullable)error;
/* Texture dirty-client pages include external RAM writes and completed GPU
 * writebacks. Invalidate their source versions without discarding newer
 * tracked GPU surfaces. This does not replace surface CPU-access handling. */
- (BOOL)noticeTextureDirtyAtAddress:(NSUInteger)address
                             length:(NSUInteger)length
                              error:(NSError *_Nullable *_Nullable)error;
- (BOOL)invalidateAddress:(NSUInteger)address
                   length:(NSUInteger)length
                    error:(NSError *_Nullable *_Nullable)error;
/* Refresh a valid entry's eviction age without starting GPU work. */
- (BOOL)touchSurface:(nullable NV2AMetalCachedSurface *)surface
               frame:(uint64_t)frame
               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)evictBeforeFrame:(uint64_t)frame
                   error:(NSError *_Nullable *_Nullable)error;
- (BOOL)flushWithError:(NSError *_Nullable *_Nullable)error;
/* Cancel obsolete unsubmitted work, drain submitted work and invalidate every
 * surface/source page without new downloads. The loader MUST drain submitted
 * GPU writes before changing RAM. To preserve failed loads, use flushWithError
 * before loading and this invalidation after loading. Guest access and new GPU
 * submissions remain stopped throughout RAM replacement. */
- (BOOL)discardForRestoreWithError:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
