/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_FETCH_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_FETCH_PGRAPH_H
#import "surface-cache.h"
#import "vertex-fetch.h"
typedef struct NV2AState NV2AState;
@class NV2AMetalPendingInput;
NS_ASSUME_NONNULL_BEGIN
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHFetchBatch : NSObject
@property(nonatomic, readonly) NV2AMetalFetchResult *fetch;
@property(nonatomic, readonly) unsigned int firstVertex;
@property(nonatomic, readonly) BOOL indexed;
/* Full guest input count and the ordinal of the compact decoded suffix. */
@property(nonatomic, readonly) NSUInteger inputVertexCount, firstDecodedVertex;
@end

/* PGRAPH-thread/pg.lock only. Captures live DrawArrays/InlineElements/Inline-
 * Buffer/InlineArray and reads vertex DMA A/B through the surface cache's VRAM.
 * Returns one GPU-decoded stream per independent draw, preserving multi-draw
 * boundaries already merged by common PGRAPH. Array/packed data decode stays
 * on GPU; completed current-attribute Float4s are copied back as register
 * state. This stage submits/waits to reject fetch faults before a draw and to
 * commit current attributes. Prepare render attachments/capture AFTER this
 * call. Batch input lengths/reset/carryover remain the common controller's job.
 * NV2AState and live shared RAM outlive this object. No renderer registration.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHFetch : NSObject
@property(nonatomic, readonly) NV2AMetalSurfaceCache *surfaces;
/* Borrow only while an encoding is active, to append XF to its producer.
 * Do not begin, submit, wait or cancel this queue outside the fetch owner. */
@property(nonatomic, readonly, nullable) NV2AMetalCommands *encodingCommands;
- (nullable instancetype)initWithState:(NV2AState *)state
                              surfaces:(NV2AMetalSurfaceCache *)surfaces
                                 error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable NSArray<NV2AMetalPGRAPHFetchBatch *> *)prepareWithError:
    (NSError *_Nullable *_Nullable)error;
/* Split producer encoding from completion so readonly XF can follow the fetch
 * in the same recording. Complete validates faults and publishes Current only
 * after GPU completion. Cancel an encoded producer if later encoding fails. */
- (nullable NSArray<NV2AMetalPGRAPHFetchBatch *> *)encodeWithError:
    (NSError *_Nullable *_Nullable)error;
/* Capture owned snapshots or guarded VRAM sources on an independent queue
 * when no prior GPU writer/download overlaps them. Otherwise use the surface
 * queue. Complete validates GPU faults before publishing Current. */
- (nullable NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshotsWithError:(NSError *_Nullable *_Nullable)error;
/* Prefixes come from the Pending plan, one per input batch. Sources and full
 * DMA bounds are still captured/validated; only suffix attributes are emitted.
 * CPU-owned inline/index snapshots retain the suffix and the selected Current
 * element. DMA index bounds still include the entire original input.
 * Current retains its full-input selection even for an entirely cached batch.
 */
- (nullable NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                                     error:(NSError *_Nullable *_Nullable)error;
/* The indexed input is the immutable Pending snapshot captured and validated
 * from this same pg.lock interval. Its cached bounds cover the full input;
 * Fetch still validates the complete DMA span before using a compact suffix.
 * Pass nil for other input kinds or to capture the live indices here. */
- (nullable NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                              indexedInput:
                                  (nullable NV2AMetalPendingInput *)input
                                     error:(NSError *_Nullable *_Nullable)error;
/* Pure input/layout check; encoding still validates and owns the sources. */
+ (BOOL)canCaptureInlineCurrentForState:(nullable NV2AState *)state;
/* CPU-owned InlineBuffer or a validated interleaved InlineArray. Capture
 * selected Current from immutable source buffers, preserving default lanes,
 * D3D Current ordering and CMP clamping. Encode Fetch/XF on the surface queue;
 * the caller may append known-context work and publish Current without a GPU
 * read, submit or wait. DMA/index sources and private producers are excluded.
 */
- (nullable NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeInlineCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                                       error:
                                           (NSError *_Nullable *_Nullable)error;
- (BOOL)completeInlineCurrentSnapshotsWithError:
    (NSError *_Nullable *_Nullable)error;
/* Nonblocking eligibility check, not a read lease. Encoding revalidates
 * complete DMA bounds and registers the normal GPU read guards before copying
 * selected CPU-readable Current bytes. Pending GPU writers/downloads reject
 * this path. A caller appending XF must also prove its context fault-free and
 * nonwriting. Indexed input has the same immutable-capture contract above.
 * These snapshots omit GPU Current records; fully cached ranges produce no
 * Fetch attributes, fault buffers or dispatch. Generic completion still checks
 * any decoded suffix faults before accepting the captured Current. */
- (BOOL)canCaptureCurrentForInput:(nullable NV2AMetalPendingInput *)input;
- (nullable NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                          indexedInput:(nullable NV2AMetalPendingInput *)input
                                 error:(NSError *_Nullable *_Nullable)error;
- (BOOL)completeCurrentSnapshotsWithError:(NSError *_Nullable *_Nullable)error;
/* Submit the encoded producer without waiting or publishing Current. This
 * permits independent CPU preparation before completeWithError. Do not alter
 * captured inputs or shared Current state between these calls. */
- (BOOL)submitWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)completeWithError:(NSError *_Nullable *_Nullable)error;
- (void)cancel;
- (void)close;
@end
NS_ASSUME_NONNULL_END
#endif
