/* Partial producer commits retain their open batch and raster chain.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMMAND_PRODUCER_PREFIX_H
#define TEST_METAL_COMMAND_PRODUCER_PREFIX_H
static void (*prefix_fake_begin)(id, SEL, TestAllocator *);
/* Metal permits further encoding into an allocator after endCommandBuffer,
 * including while earlier allocations execute. Keep reset's busy assertion. */
static void prefix_fake_append(id object, SEL selector,
                               TestAllocator *allocator)
{
    BOOL busy = allocator.busy;
    allocator.busy = NO;
    prefix_fake_begin(object, selector, allocator);
    allocator.busy = busy;
}
static NV2AMetalCommands *prefix_fake_commands(TestDevice *device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                            error:&error];
    assert(commands && !error && !commands.batchSerial);
    return commands;
}
static BOOL prefix_available(id slot)
{
    dispatch_semaphore_t available = [slot valueForKey:@"available"];
    if (dispatch_semaphore_wait(available, DISPATCH_TIME_NOW))
        return NO;
    dispatch_semaphore_signal(available);
    return YES;
}
static void prefix_fake_cuts(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = device.freshQueues = YES;
    NV2AMetalCommands *source = prefix_fake_commands(device);
    TestQueue *sourceQueue = device.queue;
    assert([source beginWithError:NULL] && [source submitWithError:NULL]);
    NV2AMetalSubmission *dependency = source.lastSubmitted;
    NV2AMetalCommands *commands = prefix_fake_commands(device);
    TestQueue *queue = device.queue;
    NSError *error = nil;
    uint64_t generation = 0;
    TestBuffer *head;
    id slot;
    for (unsigned section = 0; section < 3; section++) {
        assert([commands beginWithError:&error]);
        if (!section) {
            generation = commands.batchSerial;
            head = (id)commands.commandBuffer;
            slot = [commands valueForKey:@"batch"];
        }
        assert(generation && commands.batchSerial == generation);
        if (section)
            assert([commands orderAfterSubmission:dependency
                                     fromCommands:source
                                            error:&error]);
        assert([commands sealWithError:&error]);
    }
    assert(commands.sealedBufferCount == 3);
    assert(![commands submitProducersThroughSectionCount:0
                                             batchSerial:generation
                                                   error:&error]);
    assert(![commands submitProducersThroughSectionCount:4
                                             batchSerial:generation
                                                   error:&error]);
    assert(![commands submitProducersThroughSectionCount:1
                                             batchSerial:generation + 1
                                                   error:&error]);
    NV2AMetalSubmission *first =
        [commands submitProducersThroughSectionCount:1
                                         batchSerial:generation
                                               error:&error];
    assert(first && !error && commands.lastSubmitted == first &&
           queue.pending.count == 1 && queue.pending[0].bufferCount == 1 &&
           queue.pending[0].buffer == head && !queue.foreignWaits.count &&
           queue.signaled == 1 && !prefix_available(slot));
    assert([commands submitProducersThroughSectionCount:1
                                            batchSerial:generation
                                                  error:&error] == first &&
           queue.pending.count == 1 && commands.sealedBufferCount == 3);
    [queue completeWithError:nil];
    assert([first completedWithError:&error] && !error &&
           !prefix_available(slot));
    assert([commands beginWithError:&error] &&
           commands.batchSerial == generation);
    assert(![commands submitProducersThroughSectionCount:2
                                             batchSerial:generation
                                                   error:&error]);
    [commands cancelUnsealed];
    assert([commands submitWithError:&error] && !commands.batchSerial &&
           queue.pending.count == 1 && queue.pending[0].bufferCount == 2 &&
           queue.pending[0].buffer != head && queue.foreignWaits.count == 1 &&
           queue.signaled == 2);
    NV2AMetalSubmission *final = commands.lastSubmitted;
    assert(final != first && !final.hasSeparateProducerFeedback &&
           ![final completedProducersWithError:NULL]);
    [sourceQueue completeWithError:nil];
    [queue completeWithError:nil];
    assert([final completedWithError:&error] && !error &&
           prefix_available(slot));
    assert([commands waitUntilIdleWithError:&error]);
    assert([commands beginWithError:&error] &&
           commands.batchSerial != generation);
    [commands cancelUnsealed];
    assert(![commands submitProducersThroughSectionCount:1
                                             batchSerial:generation
                                                   error:&error]);
}
static void prefix_fake_aggregate(void)
{
    for (unsigned raster = 0; raster < 2; raster++) {
        TestDevice *device = [TestDevice new];
        device.supported = device.freshQueues = YES;
        NV2AMetalCommands *commands = prefix_fake_commands(device);
        TestQueue *queue = device.queue;
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        uint64_t generation = 0;
        for (unsigned section = 0; section < 2; section++) {
            assert([commands beginWithError:NULL]);
            generation = commands.batchSerial;
            if (raster) {
                id<MTL4RenderCommandEncoder> encoder =
                    [commands beginRasterPass:pass error:NULL];
                assert(encoder);
                [encoder endEncoding];
            }
            assert([commands sealWithError:NULL]);
        }
        id slot = [commands valueForKey:@"batch"];
        NV2AMetalSubmission *a =
            [commands submitProducersThroughSectionCount:1
                                             batchSerial:generation
                                                   error:NULL];
        NV2AMetalSubmission *b =
            [commands submitProducersThroughSectionCount:2
                                             batchSerial:generation
                                                   error:NULL];
        assert(a && b && a != b && queue.pending.count == 2 &&
               queue.signaled == 2);
        assert([commands submitProducersThroughSectionCount:1
                                                batchSerial:generation
                                                      error:NULL] == a);
        assert([commands submitWithError:NULL]);
        NV2AMetalSubmission *final = commands.lastSubmitted;
        assert(final != b && final.hasSeparateProducerFeedback == raster &&
               queue.pending.count == 2 + raster &&
               queue.signaled == 2 + raster && !prefix_available(slot));
        if (raster) {
            TestSubmission *tail = queue.pending[2];
            assert(tail.bufferCount == 3);
            for (TestBuffer *buffer in tail.buffers)
                assert(buffer.raster);
            [queue.pending exchangeObjectAtIndex:0 withObjectAtIndex:2];
            [queue completeWithError:nil];
            assert(![final completedWithError:NULL] &&
                   ![final completedProducersWithError:NULL]);
        }
        /* Later feedback errors must never replace the earlier commit's error.
         */
        NSError *early = [NSError errorWithDomain:@"test.prefix.early"
                                             code:1
                                         userInfo:nil];
        NSError *late = [NSError errorWithDomain:@"test.prefix.late"
                                            code:2
                                        userInfo:nil];
        if (!raster)
            [queue.pending exchangeObjectAtIndex:0 withObjectAtIndex:1];
        [queue completeWithError:late];
        assert(![final completedWithError:NULL] && !prefix_available(slot));
        [queue completeWithError:early];
        NSError *error = nil;
        assert([final completedWithError:&error] && error == early &&
               prefix_available(slot));
        assert([final completedProducersWithError:&error] && error == early);
    }
}
static unsigned prefix_destroyed_tokens;
@interface PrefixLifetimeToken : NSObject
@end
@implementation PrefixLifetimeToken
- (void)dealloc
{
    prefix_destroyed_tokens++;
}
@end
static void prefix_fake_lifetime(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = device.freshQueues = YES;
    TestQueue *queue;
    __weak NV2AMetalCommands *weakCommands;
    __weak NSObject *headLife;
    __weak NSObject *tailLife;
    NV2AMetalSubmission *receipt;
    prefix_destroyed_tokens = 0;
    @autoreleasepool {
        NV2AMetalCommands *commands = prefix_fake_commands(device);
        weakCommands = commands;
        queue = device.queue;
        assert([commands beginWithError:NULL]);
        @autoreleasepool {
            NSObject *head = [PrefixLifetimeToken new];
            headLife = head;
            assert([commands keepAlive:head error:NULL]);
        }
        NSUInteger offset;
        uint32_t one = 0x12345678, two = 0xabcdef01;
        id<MTLBuffer> page = [commands uploadBytes:&one
                                            length:4
                                            offset:&offset
                                             error:NULL];
        assert(page && !offset && [commands sealWithError:NULL]);
        id slot = [commands valueForKey:@"batch"];
        TestResidency *residency = [slot valueForKey:@"residency"];
        receipt =
            [commands submitProducersThroughSectionCount:1
                                             batchSerial:commands.batchSerial
                                                   error:NULL];
        assert(receipt && [commands beginWithError:NULL]);
        @autoreleasepool {
            NSObject *tail = [PrefixLifetimeToken new];
            tailLife = tail;
            assert([commands keepAlive:tail error:NULL]);
        }
        assert([commands uploadBytes:&two length:4 offset:&offset
                               error:NULL] == page &&
               offset == 256);
        TestResource *resource = [TestResource new];
        resource.device = device;
        assert([commands addResource:(id)resource error:NULL]);
        NSUInteger removes = residency.removes, resets = residency.resets;
        [commands cancelUnsealed];
        assert(!prefix_destroyed_tokens && residency.removes == removes &&
               residency.resets == resets);
        assert([commands beginWithError:NULL]);
        assert([commands uploadBytes:&two length:4 offset:&offset
                               error:NULL] == page &&
               offset == 256 && *(uint32_t *)page.contents == one);
        commands = nil;
        assert(!prefix_destroyed_tokens && residency.removes == removes &&
               residency.resets == resets && !prefix_available(slot));
    }
    assert(!weakCommands && !prefix_destroyed_tokens);
    @autoreleasepool {
        TestSubmission *completed = queue.pending.firstObject;
        [queue completeWithError:nil];
        completed.feedback = nil;
    }
    assert([receipt completedWithError:NULL] && prefix_destroyed_tokens == 2 &&
           !headLife && !tailLife);
}
static void prefix_fake_known_errors(void)
{
    TestDevice *device = [TestDevice new];
    device.supported = device.freshQueues = YES;
    NV2AMetalCommands *source = prefix_fake_commands(device);
    TestQueue *sourceQueue = device.queue;
    assert([source beginWithError:NULL] && [source submitWithError:NULL]);
    NV2AMetalSubmission *dependency = source.lastSubmitted;
    NV2AMetalCommands *commands = prefix_fake_commands(device);
    TestQueue *queue = device.queue;
    assert([commands beginWithError:NULL] && [commands sealWithError:NULL]);
    uint64_t generation = commands.batchSerial;
    assert([commands beginWithError:NULL] &&
           [commands orderAfterSubmission:dependency
                             fromCommands:source
                                    error:NULL] &&
           [commands sealWithError:NULL]);
    NSError *failure = [NSError errorWithDomain:@"test.prefix.later-dependency"
                                           code:1
                                       userInfo:nil];
    [sourceQueue completeWithError:failure];
    NSError *error = nil;
    NV2AMetalSubmission *head =
        [commands submitProducersThroughSectionCount:1
                                         batchSerial:generation
                                               error:&error];
    assert(head && !error && !queue.foreignWaits.count);
    [queue completeWithError:nil];
    assert(![commands submitProducersThroughSectionCount:2
                                             batchSerial:generation
                                                   error:&error] &&
           error == failure);
    assert(![commands submitWithError:&error] && error == failure &&
           !queue.pending.count);
    [commands cancel];
    assert([head completedWithError:&error] && !error);

    commands = prefix_fake_commands(device);
    queue = device.queue;
    assert([commands beginWithError:NULL] && [commands sealWithError:NULL]);
    generation = commands.batchSerial;
    head = [commands submitProducersThroughSectionCount:1
                                            batchSerial:generation
                                                  error:NULL];
    [queue completeWithError:failure];
    error = nil;
    assert(![commands beginWithError:&error] && error == failure);
    assert([commands submitProducersThroughSectionCount:1
                                            batchSerial:generation
                                                  error:NULL] == head);
    [commands cancel];
}
static void check_command_producer_prefix(void)
{
    Method method = class_getInstanceMethod(
        TestBuffer.class, @selector(beginCommandBufferWithAllocator:));
    prefix_fake_begin =
        (void *)method_setImplementation(method, (IMP)prefix_fake_append);
    @try {
        prefix_fake_cuts();
        prefix_fake_aggregate();
        prefix_fake_lifetime();
        prefix_fake_known_errors();
    } @finally {
        method_setImplementation(method, (IMP)prefix_fake_begin);
    }
    puts("Metal producer prefixes: absolute cuts/generations, idempotent "
         "receipts, wait cutoffs, no head replay, raster-only/zero-commit "
         "final, ordered errors, pinned host lease, cancel/retry uploads and "
         "owner destruction lifetime PASS (CPU only)");
}
static void prefix_native_copy(NV2AMetalCommands *commands,
                               id<MTLBuffer> target, NSUInteger destination,
                               uint32_t value)
{
    NSError *error = nil;
    NSUInteger offset;
    id<MTLBuffer> source = [commands uploadBytes:&value
                                          length:sizeof(value)
                                          offset:&offset
                                           error:&error];
    assert(source && [commands addResource:target error:&error]);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:source
               sourceOffset:offset
                   toBuffer:target
          destinationOffset:destination
                       size:sizeof(value)];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
}
static void check_command_producer_prefix_native(void)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithError:&error];
    assert(commands && !error);
    NV2AMetalCommands *blocker =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    id<MTLSharedEvent> gate = [commands.device newSharedEvent];
    assert(blocker && gate);
    id<MTL4CommandQueue> blockerQueue = [blocker valueForKey:@"queue"];
    [blockerQueue waitForEvent:gate value:1];
    assert([blocker beginWithError:&error] && [blocker submitWithError:&error]);
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:12
                                     options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0, output.length);
    uint64_t generation = 0;
    for (unsigned section = 0; section < 3; section++) {
        assert([commands beginWithError:&error]);
        generation = commands.batchSerial;
        if (section)
            assert([commands orderAfterSubmission:blocker.lastSubmitted
                                     fromCommands:blocker
                                            error:&error]);
        prefix_native_copy(commands, output, section * 4, 100 + section);
        assert([commands sealWithError:&error]);
    }
    NV2AMetalSubmission *head =
        [commands submitProducersThroughSectionCount:1
                                         batchSerial:generation
                                               error:&error];
    assert(head && [commands beginWithError:&error]);
    uint32_t tail = 0xabcdef;
    NSUInteger offset;
    assert([commands uploadBytes:&tail length:4 offset:&offset error:&error] &&
           offset >= 3 * 256);
    [commands cancelUnsealed];
    assert([commands waitForSubmission:head error:&error]);
    const uint32_t *values = output.contents;
    assert(values[0] == 100 && !values[1] && !values[2] &&
           !gate.signaledValue &&
           ![blocker.lastSubmitted completedWithError:NULL] &&
           commands.sealedBufferCount == 3);
    assert([commands submitProducersThroughSectionCount:1
                                            batchSerial:generation
                                                  error:&error] == head);
    gate.signaledValue = 1;
    assert([commands submitWithError:&error] &&
           [commands waitUntilIdleWithError:&error] &&
           [blocker waitUntilIdleWithError:&error]);
    assert(values[0] == 100 && values[1] == 101 && values[2] == 102);
    puts("Native producer prefix: S1 completes while S2/S3 remain gated on "
         "another queue, live tail uploads/cancel, exact final copies and "
         "one-time head execution PASS");
}
#endif
