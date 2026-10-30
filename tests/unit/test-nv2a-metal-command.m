/*
 * CPU-only tests for NV2A Metal 4 submission ownership and ordering.
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "hw/xbox/nv2a/pgraph/metal/command.h"
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>
#include "test-metal-lru.h"

static char feedback_key;

/* Capture feedback without creating a GPU device or submitting GPU work. */
static void capture_feedback(id self, SEL selector,
                             MTL4CommitFeedbackHandler handler)
{
    (void)selector;
    objc_setAssociatedObject(self, &feedback_key, handler,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@interface TestAllocator : NSObject
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL recording;
@property(nonatomic) NSUInteger resets;
@property(nonatomic) uint64_t commandBytes;
- (void)reset;
- (uint64_t)allocatedSize;
@end

@implementation TestAllocator
- (void)reset
{
    assert(!self.busy);
    self.resets++;
    self.commandBytes = 0;
}
- (uint64_t)allocatedSize
{
    return self.commandBytes;
}
@end

static NSUInteger raster_encoder_calls, raster_encoder_fail;
@interface TestRasterEncoder : NSObject
- (void)endEncoding;
@end
@implementation TestRasterEncoder
- (void)endEncoding
{
}
@end

@interface TestBuffer : NSObject
@property(nonatomic) BOOL recording;
@property(nonatomic, strong) TestAllocator *allocator;
@property(nonatomic) BOOL raster;
@property(nonatomic) MTL4RenderEncoderOptions rasterOptions;
@property(nonatomic) MTL4RenderPassDescriptor *pass;
- (void)beginCommandBufferWithAllocator:(TestAllocator *)allocator;
- (void)endCommandBuffer;
- (void)useResidencySet:(id)set;
- (id)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)pass
                                 options:(MTL4RenderEncoderOptions)options;
@end

@implementation TestBuffer
- (void)beginCommandBufferWithAllocator:(TestAllocator *)allocator
{
    assert(!self.recording && !allocator.busy && !allocator.recording);
    allocator.recording = YES;
    self.raster = NO;
    self.pass = nil;
    self.recording = YES;
    self.allocator = allocator;
}
- (void)endCommandBuffer
{
    assert(self.recording);
    self.recording = NO;
    self.allocator.recording = NO;
}
- (void)useResidencySet:(id)set
{
    assert(self.recording && set);
}
- (id)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)pass
                                 options:(MTL4RenderEncoderOptions)options
{
    assert(self.recording && pass && !self.raster);
    if (++raster_encoder_calls == raster_encoder_fail)
        return nil;
    self.raster = YES;
    self.rasterOptions = options;
    self.pass = [pass copy];
    return [TestRasterEncoder new];
}
@end

@interface TestResidency : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic) NSUInteger allocations;
- (void)addAllocation:(id)allocation;
- (void)removeAllAllocations;
- (void)commit;
@end

@implementation TestResidency
- (void)addAllocation:(id)allocation
{
    assert(allocation);
    self.allocations++;
}
- (void)removeAllAllocations
{
    self.allocations = 0;
}
- (void)commit
{
}
@end

@interface TestFeedback : NSObject
@property(nonatomic, strong) NSError *error;
@end

@implementation TestFeedback
@end

@interface TestSubmission : NSObject
@property(nonatomic, strong) TestBuffer *buffer;
@property(nonatomic) NSUInteger bufferCount;
@property(nonatomic) NSArray<TestBuffer *> *buffers;
@property(nonatomic, copy) MTL4CommitFeedbackHandler feedback;
@end

@interface TestLayer : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic, strong) TestResidency *residencySet;
@end

@implementation TestLayer
@end

@interface TestDrawable : NSObject
@property(nonatomic, strong) id texture;
@property(nonatomic, strong) TestLayer *layer;
@property(nonatomic) BOOL waited;
@property(nonatomic) BOOL committed;
@property(nonatomic) BOOL signaled;
@property(nonatomic) BOOL presented;
- (void)present;
@end

@implementation TestDrawable
- (void)present
{
    assert(self.waited && self.committed && self.signaled && !self.presented);
    self.presented = YES;
}
@end

@implementation TestSubmission
@end

@class TestQueue;
@interface TestEvent : NSObject
@property(nonatomic, weak) TestQueue *queue;
@end
@implementation TestEvent
@end

@interface TestQueue : NSObject
@property(nonatomic, strong) NSMutableArray<TestSubmission *> *pending;
@property(nonatomic) NSMutableArray<NSArray *> *foreignWaits;
@property(nonatomic) uint64_t signaled;
@property(nonatomic) uint64_t waited;
@property(nonatomic, weak) TestDrawable *waitingDrawable;
- (void)commit:(const id<MTL4CommandBuffer>[])buffers
         count:(NSUInteger)count
       options:(MTL4CommitOptions *)options;
- (void)signalEvent:(id)event value:(uint64_t)value;
- (void)waitForEvent:(id)event value:(uint64_t)value;
- (void)completeWithError:(NSError *)error;
- (void)waitForDrawable:(TestDrawable *)drawable;
- (void)signalDrawable:(TestDrawable *)drawable;
@end

@implementation TestQueue
- (void)commit:(const id<MTL4CommandBuffer>[])buffers
         count:(NSUInteger)count
       options:(MTL4CommitOptions *)options
{
    assert(count && count <= NV2AMetalCommandBatchLimit + 1 &&
           self.waited == self.signaled);
    TestSubmission *submission = [TestSubmission new];
    submission.buffer = (TestBuffer *)buffers[0];
    submission.bufferCount = count;
    NSMutableArray *retained = [NSMutableArray new];
    for (NSUInteger i = 0; i < count; i++) {
        TestBuffer *buffer = (TestBuffer *)buffers[i];
        assert(!buffer.recording &&
               buffer.allocator == submission.buffer.allocator);
        for (NSUInteger j = 0; j < i; j++)
            assert(buffers[i] != buffers[j]);
        [retained addObject:buffer];
    }
    submission.buffers = [retained copy];
    submission.buffer.allocator.busy = YES;
    submission.feedback = objc_getAssociatedObject(options, &feedback_key);
    assert(submission.feedback);
    [self.pending addObject:submission];
    if (self.waitingDrawable) {
        assert(self.waitingDrawable.waited && !self.waitingDrawable.committed);
        self.waitingDrawable.committed = YES;
    }
}
- (void)waitForDrawable:(TestDrawable *)drawable
{
    assert(drawable && !drawable.waited && !self.waitingDrawable);
    drawable.waited = YES;
    self.waitingDrawable = drawable;
}
- (void)signalDrawable:(TestDrawable *)drawable
{
    assert(drawable == self.waitingDrawable && drawable.committed &&
           !drawable.presented && !drawable.signaled);
    drawable.signaled = YES;
    self.waitingDrawable = nil;
}
- (void)signalEvent:(id)event value:(uint64_t)value
{
    assert(event && value == self.signaled + 1);
    self.signaled = value;
}
- (void)waitForEvent:(id)event value:(uint64_t)value
{
    assert(event);
    if (((TestEvent *)event).queue != self) {
        assert(((TestEvent *)event).queue.signaled >= value);
        if (!self.foreignWaits)
            self.foreignWaits = [NSMutableArray new];
        [self.foreignWaits addObject:@[ event, @(value) ]];
        return;
    }
    assert(value == self.signaled);
    self.waited = value;
}
- (void)completeWithError:(NSError *)error
{
    TestSubmission *submission = self.pending.firstObject;
    assert(submission);
    [self.pending removeObjectAtIndex:0];
    submission.buffer.allocator.busy = NO;
    TestFeedback *feedback = [TestFeedback new];
    feedback.error = error;
    submission.feedback((id<MTL4CommitFeedback>)feedback);
}
@end

@interface TestUploadBuffer : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic, strong) NSMutableData *data;
- (NSUInteger)length;
- (void *)contents;
- (NSUInteger)allocatedSize;
@end

@implementation TestUploadBuffer
- (NSUInteger)length { return self.data.length; }
- (void *)contents { return self.data.mutableBytes; }
- (NSUInteger)allocatedSize { return self.data.length; }
@end

@interface TestDevice : NSObject
@property(nonatomic, strong) TestQueue *queue;
@property(nonatomic) BOOL supported;
@property(nonatomic) NSUInteger bufferAllocations;
@property(nonatomic) BOOL failBufferAllocation;
@property(nonatomic) BOOL freshQueues;
- (NSUInteger)maxBufferLength;
- (id)newBufferWithLength:(NSUInteger)length
                  options:(MTLResourceOptions)options;
- (id)newBufferWithBytes:(const void *)bytes
                  length:(NSUInteger)length
                 options:(MTLResourceOptions)options;
- (BOOL)supportsFamily:(MTLGPUFamily)family;
- (BOOL)hasUnifiedMemory;
- (id)newMTL4CommandQueue;
- (id)newCommandAllocator;
- (id)newCommandBuffer;
- (id)newEvent;
- (id)newResidencySetWithDescriptor:(id)descriptor error:(NSError **)error;
@end

@implementation TestDevice
- (NSUInteger)maxBufferLength { return 16 * 1024 * 1024; }
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
    assert(options == MTLResourceStorageModeShared);
    if (self.failBufferAllocation)
        return nil;
    self.bufferAllocations++;
    TestUploadBuffer *buffer = [TestUploadBuffer new];
    buffer.device = self;
    buffer.data = [NSMutableData dataWithLength:length];
    return buffer;
}
- (id)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length
                 options:(MTLResourceOptions)options
{
    TestUploadBuffer *buffer = [self newBufferWithLength:length options:options];
    if (buffer)
        memcpy(buffer.contents, bytes, length);
    return buffer;
}
- (BOOL)supportsFamily:(MTLGPUFamily)family
{
    assert(family == MTLGPUFamilyApple7 || family == MTLGPUFamilyMetal4);
    return self.supported;
}
- (BOOL)hasUnifiedMemory
{
    return YES;
}
- (id)newMTL4CommandQueue
{
    if (self.freshQueues) {
        self.queue = [TestQueue new];
        self.queue.pending = [NSMutableArray new];
    }
    return self.queue;
}
- (id)newCommandAllocator
{
    return [TestAllocator new];
}
- (id)newCommandBuffer
{
    return [TestBuffer new];
}
- (id)newEvent
{
    TestEvent *event = [TestEvent new];
    event.queue = self.queue;
    return event;
}
- (id)newResidencySetWithDescriptor:(id)descriptor error:(NSError **)error
{
    (void)descriptor;
    (void)error;
    return [TestResidency new];
}
@end

@interface TestResource : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic) NSUInteger allocatedSize;
@end

@implementation TestResource
@end

static void check_uploads(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = YES;
    device.queue = [TestQueue new];
    device.queue.pending = [NSMutableArray new];
    NSError *error = nil;
    NV2AMetalCommands *commands = [[NV2AMetalCommands alloc]
        initWithDevice:(id<MTLDevice>)device error:&error];
    assert(commands);
    unsigned char data[65537];
    memset(data, 0x37, sizeof(data));
    NSUInteger offset = 17;
    assert(![commands uploadBytes:data length:1 offset:&offset error:&error]);
    assert(offset == 17 && error && !device.bufferAllocations);
    id<MTLBuffer> pages[3];
    for (unsigned slot = 0; slot < 3; slot++) {
        assert([commands beginWithError:&error]);
        assert(![commands uploadBytes:data length:0 offset:&offset error:&error]);
        assert(![commands uploadBytes:data length:device.maxBufferLength + 1
                                offset:&offset error:&error]);
        pages[slot] = [commands uploadBytes:data length:13 offset:&offset
                                      error:&error];
        assert(pages[slot] && offset == 0);
        data[0] = 0x50 + slot;
        id<MTLBuffer> second = [commands uploadBytes:data length:600
                                              offset:&offset error:&error];
        assert(second == pages[slot] && offset == 256);
        assert(((unsigned char *)second.contents)[0] == 0x37);
        assert(((unsigned char *)second.contents)[256] == 0x50 + slot);
        memset(data, 0x37, sizeof(data));
        assert([commands uploadBytes:data length:65536 - 1024
                                offset:&offset error:&error] == pages[slot]);
        assert(offset == 1024);
        /* Fill the bounded arena, then exceed it without overwriting pages. */
        for (unsigned page = 1; page < 18; page++) {
            id<MTLBuffer> next = [commands uploadBytes:data length:65536
                                                offset:&offset error:&error];
            assert(next && next != pages[slot] && !offset);
        }
        assert(((unsigned char *)pages[slot].contents)[256] == 0x50 + slot);
        assert([commands submitWithError:&error]);
    }
    assert(pages[0] != pages[1] && pages[1] != pages[2] && pages[0] != pages[2]);
    assert(device.bufferAllocations == 54);
    [device.queue completeWithError:nil];
    assert([commands beginWithError:&error]);
    id<MTLBuffer> reused = [commands uploadBytes:data length:13
                                           offset:&offset error:&error];
    assert(reused == pages[0] && !offset && device.bufferAllocations == 54);
    assert(((unsigned char *)pages[1].contents)[256] == 0x51);
    assert(((unsigned char *)pages[2].contents)[256] == 0x52);
    device.failBufferAllocation = YES;
    offset = 19;
    assert(![commands uploadBytes:data length:sizeof(data)
                            offset:&offset error:&error]);
    assert(error && offset == 19);
    device.failBufferAllocation = NO;
    id<MTLBuffer> oversized = [commands uploadBytes:data length:sizeof(data)
                                              offset:&offset error:&error];
    assert(oversized && oversized != reused && !offset);
    [commands cancel];
    assert([commands beginWithError:&error]);
    assert([commands uploadBytes:data length:13 offset:&offset error:&error] == reused);
    assert(!offset);
    [commands cancel];
    [device.queue completeWithError:nil];
    [device.queue completeWithError:nil];
    assert([commands waitUntilIdleWithError:&error]);
    puts("Metal upload arena: alignment, immutable slices, page overflow, "
         "bounded retention, three in-flight slots, completion/cancel reuse "
         "and allocation failure PASS (CPU only)");
}

static void check_submission_receipts(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = YES;
    device.queue = [TestQueue new];
    device.queue.pending = [NSMutableArray new];
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                            error:&error];
    assert(commands && !commands.lastSubmitted);
    NSMutableArray<NV2AMetalSubmission *> *receipts = [NSMutableArray new];
    for (unsigned i = 0; i < 3; i++) {
        assert([commands beginWithError:&error]);
        assert([commands submitWithError:&error]);
        [receipts addObject:commands.lastSubmitted];
        error = [NSError errorWithDomain:@"stale" code:1 userInfo:nil];
        assert(![receipts[i] completedWithError:&error] && !error);
    }
    assert(receipts[0] != receipts[1] && receipts[1] != receipts[2]);
    [device.queue completeWithError:nil];
    assert([receipts[0] completedWithError:&error] && !error);
    assert(![receipts[1] completedWithError:&error] && !error);
    assert([commands beginWithError:&error]);
    [commands cancel];
    assert(commands.lastSubmitted == receipts[2]);
    /* Slot reuse must not change the old receipt's completed status. */
    assert([commands beginWithError:&error]);
    assert([commands submitWithError:&error]);
    NV2AMetalSubmission *fourth = commands.lastSubmitted;
    assert(fourth != receipts[0] && [receipts[0] completedWithError:&error]);
    assert(![fourth completedWithError:&error]);
    [device.queue completeWithError:nil];
    NSError *failure = [NSError errorWithDomain:@"test.receipt"
                                           code:19
                                       userInfo:nil];
    [device.queue completeWithError:failure];
    assert([receipts[2] completedWithError:&error] && error == failure);
    [device.queue completeWithError:nil];
    assert([fourth completedWithError:&error] && !error);
    commands = nil;
    assert([receipts[2] completedWithError:&error] && error == failure);
    puts(
        "Metal4 submission receipts: pending/success/error, cancel, slot reuse "
        "and owner destruction PASS (CPU only)");
}

static void check_submission_waits(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = YES;
    device.queue = [TestQueue new];
    device.queue.pending = [NSMutableArray new];
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                            error:&error];
    assert(commands);
    __weak NSObject *retainedFirst;
    __weak NSObject *retainedCurrent;
    @autoreleasepool {
        assert([commands beginWithError:&error]);
        NSObject *object = [NSObject new];
        retainedFirst = object;
        assert([commands keepAlive:object error:&error]);
        assert([commands submitWithError:&error]);
    }
    NV2AMetalSubmission *first = commands.lastSubmitted;
    assert([commands beginWithError:&error]);
    assert([commands submitWithError:&error]);
    NV2AMetalSubmission *second = commands.lastSubmitted;
    id recording = [commands beginWithError:&error];
    assert(recording);
    @autoreleasepool {
        NSObject *object = [NSObject new];
        retainedCurrent = object;
        assert([commands keepAlive:object error:&error]);
    }
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      NSError *waitError = nil;
      dispatch_semaphore_signal(entered);
      assert([commands waitForSubmission:first error:&waitError] && !waitError);
      dispatch_semaphore_signal(finished);
    });
    assert(!dispatch_semaphore_wait(
        entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    assert(dispatch_semaphore_wait(finished, DISPATCH_TIME_NOW));
    [device.queue completeWithError:nil];
    assert(!dispatch_semaphore_wait(
        finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    @autoreleasepool {
        assert(commands.commandBuffer == recording && retainedCurrent &&
               retainedFirst);
    }
    assert(![second completedWithError:&error]);
    assert([commands waitForSubmission:first error:&error] && !error);
    [commands cancel];
    @autoreleasepool {
        assert(!retainedCurrent && retainedFirst);
    }
    assert([commands beginWithError:&error]);
    assert([commands submitWithError:&error]);
    [device.queue completeWithError:nil];
    [device.queue completeWithError:nil];
    assert([commands beginWithError:&error]);
    assert(!retainedFirst && [commands ownsSubmission:first]);
    assert([commands waitForSubmission:first error:&error]);
    [commands cancel];

    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                            error:&error];
    NV2AMetalSubmission *missing = nil;
    assert(![foreign ownsSubmission:first]);
    assert(![foreign waitForSubmission:first error:&error] && error);
    assert(![commands waitForSubmission:missing error:&error] && error);
    assert([commands beginWithError:&error]);
    assert([commands submitWithError:&error]);
    NV2AMetalSubmission *failed = commands.lastSubmitted;
    NSError *failure = [NSError errorWithDomain:@"test.specific-wait"
                                           code:23
                                       userInfo:nil];
    dispatch_group_t waiters = dispatch_group_create();
    for (unsigned i = 0; i < 3; i++)
        dispatch_group_async(
            waiters, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
              NSError *waitError = nil;
              dispatch_semaphore_signal(entered);
              assert(![commands waitForSubmission:failed error:&waitError]);
              assert(waitError == failure);
            });
    for (unsigned i = 0; i < 3; i++)
        assert(!dispatch_semaphore_wait(
            entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    [device.queue completeWithError:failure];
    assert(!dispatch_group_wait(
        waiters, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    assert(![commands waitForSubmission:failed error:&error] &&
           error == failure);
    puts("Metal4 specific waits:pending/success/error,multiple waiters,"
         "foreign/missing rejection,live later recording,later submission,"
         "cancel,slot reuse and resource lifetime PASS (CPU only)");
}

@interface TestTextureResource : TestResource
@property(nonatomic, strong) id<MTLTexture> parentTexture;
@property(nonatomic, strong) id<MTLBuffer> buffer;
@end
@implementation TestTextureResource
- (BOOL)conformsToProtocol:(Protocol *)protocol
{
    return protocol == @protocol(MTLTexture) ||
           [super conformsToProtocol:protocol];
}
@end
static void check_batch_budget(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = YES;
    device.queue = [TestQueue new];
    device.queue.pending = [NSMutableArray new];
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                            error:&error];
    assert(commands);
    TestResource *base = [TestResource new];
    base.device = device;
    base.allocatedSize = 128 * 1024 * 1024;
    assert([commands beginWithError:&error]);
    assert([commands addResource:(id)base error:&error]);
    assert([commands sealWithError:&error] && !commands.batchNeedsSubmit);
    assert([commands beginWithError:&error]);
    for (unsigned i = 0; i < 64; i++) {
        TestTextureResource *view = [TestTextureResource new];
        view.device = device;
        view.allocatedSize = NSUIntegerMax;
        view.buffer = (id)base;
        assert([commands addResource:(id)view error:&error]);
        assert(!commands.batchNeedsSubmit);
    }
    TestResource *extra = [TestResource new];
    extra.device = device;
    extra.allocatedSize = NV2AMetalCommandBatchExtraBytes - 1;
    assert([commands addResource:(id)extra error:&error] &&
           !commands.batchNeedsSubmit);
    TestResource *one = [TestResource new];
    one.device = device;
    one.allocatedSize = 1;
    assert([commands addResource:(id)one error:&error] &&
           commands.batchNeedsSubmit);
    [commands cancelUnsealed];
    assert(!commands.batchNeedsSubmit && commands.sealedBufferCount == 1);
    assert([commands beginWithError:&error]);
    TestBuffer *section = (id)commands.commandBuffer;
    section.allocator.commandBytes = NV2AMetalCommandBatchExtraBytes;
    assert(commands.batchNeedsSubmit);
    assert([commands submitWithError:&error]);
    [device.queue completeWithError:nil];
    assert([commands waitUntilIdleWithError:&error]);
    assert([commands beginWithError:&error]);
    assert([commands addResource:(id)base error:&error]);
    assert([commands sealWithError:&error]);
    assert([commands beginWithError:&error]);
    extra.allocatedSize = NSUIntegerMax;
    assert([commands addResource:(id)extra error:&error] &&
           commands.batchNeedsSubmit);
    [commands cancelUnsealed];
    assert(!commands.batchNeedsSubmit);
    [commands cancel];
    puts("Metal batch memory: 128-MiB common source counted once, 64 "
         "buffer-backed views, exact 32-MiB additional resource/allocator "
         "boundary, cancel rollback and saturated size arithmetic PASS (CPU "
         "only)");
}

static void check_batches(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = YES;
    device.queue = [TestQueue new];
    device.queue.pending = [NSMutableArray new];
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                            error:&error];
    assert(commands);
    assert(![commands sealWithError:&error]);
    [commands cancelUnsealed];
    const uint32_t one = 0x12345678, two = 0x89abcdef;
    NSUInteger offset = 0, firstOffset = 0;
    __weak NSObject *prefixLife;
    __weak NSObject *suffixLife;
    assert([commands beginWithError:&error]);
    TestBuffer *first = (id)commands.commandBuffer;
    NSUInteger resets = first.allocator.resets;
    uint64_t serial = commands.recordingSerial;
    id<MTLBuffer> page = [commands uploadBytes:&one
                                        length:4
                                        offset:&firstOffset
                                         error:&error];
    assert(page && !firstOffset);
    @autoreleasepool {
        NSObject *object = [NSObject new];
        prefixLife = object;
        assert([commands keepAlive:object error:&error]);
    }
    assert([commands sealWithError:&error] && prefixLife &&
           !commands.commandBuffer && commands.sealedBufferCount == 1 &&
           !commands.lastSubmitted);
    assert(![commands waitUntilIdleWithError:&error]);
    assert([commands beginWithError:&error] &&
           commands.recordingSerial > serial &&
           commands.commandBuffer != (id)first &&
           first.allocator.resets == resets);
    @autoreleasepool {
        NSObject *object = [NSObject new];
        suffixLife = object;
        assert([commands keepAlive:object error:&error]);
    }
    assert([commands uploadBytes:&two length:4 offset:&offset
                           error:&error] == page &&
           offset == 256);
    assert(*(uint32_t *)page.contents == one);
    @autoreleasepool {
        [commands cancelUnsealed];
    }
    assert(prefixLife && !suffixLife && commands.sealedBufferCount == 1 &&
           !commands.commandBuffer);
    assert([commands beginWithError:&error]);
    assert([commands uploadBytes:&two length:4 offset:&offset
                           error:&error] == page &&
           offset == 256);
    assert(*(uint32_t *)page.contents == one);
    assert([commands sealWithError:&error] && commands.sealedBufferCount == 2);
    assert([commands submitWithError:&error] &&
           commands.sealedBufferCount == 0);
    assert(device.queue.pending.count == 1 &&
           device.queue.pending[0].bufferCount == 2);
    NV2AMetalSubmission *receipt = commands.lastSubmitted;
    assert(![receipt completedWithError:NULL] && prefixLife);
    [device.queue completeWithError:nil];
    assert([commands waitForSubmission:receipt error:&error]);
    assert([commands waitUntilIdleWithError:&error] && !prefixLife);
    for (unsigned section = 0; section < NV2AMetalCommandBatchLimit;
         section++) {
        assert([commands beginWithError:&error]);
        assert([commands sealWithError:&error]);
    }
    assert(![commands beginWithError:&error] &&
           commands.sealedBufferCount == NV2AMetalCommandBatchLimit);
    assert([commands submitWithError:&error] &&
           device.queue.pending[0].bufferCount == NV2AMetalCommandBatchLimit);
    [device.queue completeWithError:nil];
    assert([commands waitUntilIdleWithError:&error]);
    assert([commands beginWithError:&error]);
    assert([commands sealWithError:&error]);
    [commands cancel];
    assert(!commands.sealedBufferCount && !commands.commandBuffer);
    assert([commands waitUntilIdleWithError:&error]);
    puts("Metal batches: shared allocator without reset, sealed-prefix "
         "lifetime, suffix cancel/retry, immutable uploads, one receipt, "
         "32-section bound and full discard PASS (CPU only)");
}

#include "test-metal-gpu-queue-order.h"
#include "test-metal-raster-submission.h"

int main(void)
{
    @autoreleasepool {
        check_lru();
        Method feedback = class_getInstanceMethod(
            [MTL4CommitOptions class], @selector(addFeedbackHandler:));
        IMP original =
            method_setImplementation(feedback, (IMP)capture_feedback);
        check_uploads();
        check_batches();
        check_batch_budget();
        check_submission_receipts();
        check_submission_waits();
        check_gpu_queue_order();
        check_raster_submissions();

        TestDevice *device = [TestDevice new];
        device.queue = [TestQueue new];
        device.queue.pending = [NSMutableArray array];
        NSError *error = nil;
        assert(![[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                                    error:&error]);
        assert(error);
        device.supported = YES;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                                error:&error];
        assert(commands);
        assert(![commands submitWithError:&error]);
        assert([commands beginWithError:&error]);
        assert(![commands beginWithError:&error]);
        assert(![commands waitUntilIdleWithError:&error]);
        [commands cancel];
        assert([commands waitUntilIdleWithError:&error]);

        TestLayer *layer = [TestLayer new];
        layer.device = device;
        layer.residencySet = [TestResidency new];
        layer.residencySet.device = device;
        __weak TestDrawable *retainedDrawable;
        @autoreleasepool {
            TestDrawable *drawable = [TestDrawable new];
            retainedDrawable = drawable;
            TestResource *texture = [TestResource new];
            texture.device = device;
            drawable.texture = texture;
            drawable.layer = layer;
            assert(![commands
                presentDrawableOnSubmit:(id<CAMetalDrawable>)drawable
                                  error:&error]);
            assert([commands beginWithError:&error]);
            layer.residencySet.device = [NSObject new];
            assert(![commands
                presentDrawableOnSubmit:(id<CAMetalDrawable>)drawable
                                  error:&error]);
            layer.residencySet.device = device;
            assert([commands
                presentDrawableOnSubmit:(id<CAMetalDrawable>)drawable
                                  error:&error]);
            assert(![commands
                presentDrawableOnSubmit:(id<CAMetalDrawable>)drawable
                                  error:&error]);
            [commands cancel];
            assert(!drawable.waited && !drawable.presented);
            assert([commands beginWithError:&error]);
            assert([commands
                presentDrawableOnSubmit:(id<CAMetalDrawable>)drawable
                                  error:&error]);
            assert([commands submitWithError:&error]);
            assert(drawable.waited && drawable.committed && drawable.signaled &&
                   drawable.presented);
        }
        assert(retainedDrawable);
        [device.queue completeWithError:nil];
        /* Rotate to the drawable's completed slot and release it before the
         * caller requests another drawable from a bounded layer pool. */
        for (int i = 0; i < 2; i++) {
            assert([commands beginWithError:&error]);
            assert([commands submitWithError:&error]);
            [device.queue completeWithError:nil];
        }
        assert([commands beginWithError:&error]);
        assert(!retainedDrawable);
        [commands cancel];

        __weak TestResource *retainedResource;
        @autoreleasepool {
            TestResource *resource = [TestResource new];
            retainedResource = resource;
            resource.device = device;
            assert([commands beginWithError:&error]);
            assert([commands addResource:(id<MTLResource>)resource
                                   error:&error]);
            NV2AMetalLRUCache *cache =
                [[NV2AMetalLRUCache alloc] initWithCapacity:1];
            cache[@0] = resource;
            cache[@1] = [NSObject new];
            assert(!cache[@0]);
            TestResource *foreign = [TestResource new];
            foreign.device = [NSObject new];
            assert(![commands addResource:(id<MTLResource>)foreign
                                    error:&error]);
            assert([commands submitWithError:&error]);
        }
        assert(retainedResource);

        /* Fill the ring without completing slot zero. Its allocator must not
         * be reset while the simulated GPU still holds its resources. */
        for (int i = 0; i < 2; i++) {
            assert([commands beginWithError:&error]);
            assert([commands submitWithError:&error]);
        }
        [device.queue completeWithError:nil];
        assert([commands beginWithError:&error]);
        assert(!retainedResource);
        [commands cancel];
        [device.queue completeWithError:nil];
        [device.queue completeWithError:nil];
        assert([commands waitUntilIdleWithError:&error]);

        /* Renderer destruction must not release resources still in flight. */
        @autoreleasepool {
            TestResource *resource = [TestResource new];
            resource.device = device;
            retainedResource = resource;
            assert([commands beginWithError:&error]);
            assert([commands addResource:(id<MTLResource>)resource
                                   error:&error]);
            assert([commands submitWithError:&error]);
            commands = nil;
        }
        assert(retainedResource);
        [device.queue completeWithError:nil];
        assert(!retainedResource);

        commands =
            [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                                error:&error];
        device.queue.signaled = device.queue.waited = 0;
        assert([commands beginWithError:&error]);
        assert([commands submitWithError:&error]);
        NSError *gpuFailure = [NSError errorWithDomain:@"test.gpu"
                                                  code:7
                                              userInfo:nil];
        [device.queue completeWithError:gpuFailure];
        assert(![commands waitUntilIdleWithError:&error]);
        assert(error == gpuFailure);
        method_setImplementation(feedback, original);
        puts("Metal 4 command ownership and ordering: PASS (CPU only)");
    }
    return 0;
}
