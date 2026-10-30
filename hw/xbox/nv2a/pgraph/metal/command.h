/*
 * NV2A Metal 4 command submission
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_COMMAND_H
#define HW_XBOX_NV2A_PGRAPH_METAL_COMMAND_H

#if !defined(__APPLE__) || !defined(__aarch64__)
#error "The Metal 4 renderer requires Apple Silicon"
#endif

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    NV2AMetalCommandBatchLimit = 32,
    NV2AMetalCommandBatchExtraBytes = 32 * 1024 * 1024,
};

/* One immutable submission identity, independent of reusable command slots.
 * Polling never waits. YES means feedback arrived; a nonnil error means that
 * completed submission failed. NO means pending and clears the error output.
 * Poll from the encoding owner; Metal feedback only publishes this status. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalSubmission : NSObject
- (BOOL)completedWithError:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* Encoding and submission belong to one thread. Feedback runs on Metal's queue.
 * End every encoder before submitting or cancelling a command buffer. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalCommands : NSObject

@property(nonatomic, readonly) id<MTLDevice> device;
/* Changes only after successful submit; begin/cancel leave it unchanged. */
@property(nonatomic, readonly, nullable) NV2AMetalSubmission *lastSubmitted;
/* Borrowed for this section; release encoders/buffer references at its end. */
@property(nonatomic, readonly, nullable) id<MTL4CommandBuffer> commandBuffer;
/* Monotonic identity for a successful begin, including reuse after cancel.
 * Zero before the first begin; meaningful only while commandBuffer is set. */
@property(nonatomic, readonly) uint64_t recordingSerial;
@property(nonatomic, readonly) NSUInteger sealedBufferCount;
/* Pressure above the first resource-bearing accepted section. Check only at
 * a successful host transaction boundary; the current section stays
 * cancellable until submit succeeds. One draw's resources may exceed this
 * extra budget, as they can before batching. */
@property(nonatomic, readonly) BOOL batchNeedsSubmit;
@property(nonatomic, readonly) BOOL hasPendingRasterPass;

- (nullable instancetype)initWithError:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable id<MTL4CommandBuffer>)beginWithError:
    (NSError *_Nullable *_Nullable)error;

/* PGRAPH producer/raster split. The owner proves that all producer sections
 * are independent of earlier raster targets before using this interface.
 * Only compatible Load/Store attachment passes can share a raster chain.
 * Prepare all compute work and pixel packets before this call; the returned
 * encoder is the last encoder in this logical section. End it before seal,
 * submit or cancel. The recording identity stays unchanged. */
- (BOOL)rasterPassMatches:(MTL4RenderPassDescriptor *)pass;
- (nullable id<MTL4RenderCommandEncoder>)
    beginRasterPass:(MTL4RenderPassDescriptor *)pass
              error:(NSError *_Nullable *_Nullable)error;

/* Metal 4 does not retain resources referenced by encoded GPU addresses. */
- (BOOL)addResource:(id<MTLResource>)resource
              error:(NSError *_Nullable *_Nullable)error;
- (BOOL)keepAlive:(id)object error:(NSError *_Nullable *_Nullable)error;
/* Register a GPU-only dependency on an already submitted source. No queue
 * wait is enqueued until this batch submits; cancel drops only its suffix.
 * The caller must validate the source queue's feedback prefix before
 * publishing dependent CPU state. This method never waits for feedback. */
- (BOOL)orderAfterSubmission:(NV2AMetalSubmission *)submission
                fromCommands:(NV2AMetalCommands *)source
                       error:(NSError *_Nullable *_Nullable)error;

/* Copy immutable, transient shader data into this recording's upload arena.
 * The returned buffer is already resident and retained. Bind gpuAddress plus
 * offset; the slice is 256-byte aligned and valid only until GPU completion.
 * Do not modify it or retain it as persistent state. Pages are reused only
 * after slot completion; oversized/excess uploads use standalone buffers. */
- (nullable id<MTLBuffer>)uploadBytes:(const void *)bytes
                               length:(NSUInteger)length
                               offset:(NSUInteger *)offset
                                error:(NSError *_Nullable *_Nullable)error;

/* Register at most one drawable for this recording. Submission waits for the
 * display, commits, signals rendering complete, then presents it. Cancellation
 * releases it without queuing a wait or presentation. Begin recording before
 * acquiring a drawable, so a completed slot releases its previous drawable. */
- (BOOL)presentDrawableOnSubmit:(id<CAMetalDrawable>)drawable
                          error:(NSError *_Nullable *_Nullable)error;

- (BOOL)submitWithError:(NSError *_Nullable *_Nullable)error;
/* End this successful section without submitting. The next begin shares its
 * allocator, residency and uploads; submit commits all sections together.
 * At most NV2AMetalCommandBatchLimit sections may be held. No drawable may be
 * sealed. Sealing invalidates prepared packets for that recording. */
- (BOOL)sealWithError:(NSError *_Nullable *_Nullable)error;
/* Discard only the current section, preserving sealed sections and their
 * uploads/resources. A normal cancel discards the entire unsubmitted batch. */
- (void)cancelUnsealed;
- (void)cancel;
/* Pure identity check, including receipts whose command slot was reused. */
- (BOOL)ownsSubmission:(NV2AMetalSubmission *)submission;
/* Wait for this queue's immutable submission without submitting, cancelling
 * or releasing a later recording. Later submissions need not have completed.
 * A successful wait does not reset command slots or release their resources. */
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError *_Nullable *_Nullable)error;
- (BOOL)waitUntilIdleWithError:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif
