/* Queue event dependencies are submitted atomically with their host sections.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_GPU_QUEUE_ORDER_H
#define TEST_METAL_GPU_QUEUE_ORDER_H
static void check_gpu_queue_order(void)
{
    NSError *error = nil;
    TestDevice *device = [TestDevice new];
    device.supported = device.freshQueues = YES;
    NV2AMetalCommands *source =
        [[NV2AMetalCommands alloc] initWithDevice:(id)device error:&error];
    TestQueue *sourceQueue = device.queue;
    NV2AMetalCommands *target =
        [[NV2AMetalCommands alloc] initWithDevice:(id)device error:&error];
    TestQueue *targetQueue = device.queue;
    assert(source && target && sourceQueue != targetQueue);
    assert([source beginWithError:&error] && [source submitWithError:&error]);
    NV2AMetalSubmission *first = source.lastSubmitted;
    assert(![target orderAfterSubmission:first
                            fromCommands:source
                                   error:&error] &&
           error);
    assert([target beginWithError:&error]);
    id recording = target.commandBuffer;
    NV2AMetalSubmission *missing = nil;
    assert(![target orderAfterSubmission:missing
                            fromCommands:source
                                   error:&error] &&
           error);
    assert(![target orderAfterSubmission:first
                            fromCommands:target
                                   error:&error] &&
           error);
    assert(target.commandBuffer == recording &&
           !targetQueue.foreignWaits.count);
    assert([target orderAfterSubmission:first
                           fromCommands:source
                                  error:&error]);
    assert([target orderAfterSubmission:first
                           fromCommands:source
                                  error:&error]);
    assert(!targetQueue.foreignWaits.count);
    assert([target sealWithError:&error]);
    assert([source beginWithError:&error] && [source submitWithError:&error]);
    NV2AMetalSubmission *second = source.lastSubmitted;
    assert([target beginWithError:&error]);
    assert([target orderAfterSubmission:second
                           fromCommands:source
                                  error:&error]);
    [target cancelUnsealed];
    assert(!targetQueue.foreignWaits.count && target.sealedBufferCount == 1);
    assert([target submitWithError:&error]);
    assert(targetQueue.foreignWaits.count == 1 &&
           [targetQueue.foreignWaits[0][1] unsignedLongLongValue] == 1);
    assert(![first completedWithError:NULL] &&
           ![second completedWithError:NULL]);
    [sourceQueue completeWithError:nil];
    [targetQueue completeWithError:nil];
    assert([target waitForSubmission:target.lastSubmitted error:&error]);
    assert(
        ![second completedWithError:NULL]); /* No drain of the later source. */
    [sourceQueue completeWithError:nil];
    assert([source beginWithError:&error] && [source submitWithError:&error]);
    NV2AMetalSubmission *third = source.lastSubmitted;
    assert([target beginWithError:&error]);
    assert([target orderAfterSubmission:first
                           fromCommands:source
                                  error:&error]);
    assert([target sealWithError:&error]);
    assert([target beginWithError:&error]);
    assert([target orderAfterSubmission:third
                           fromCommands:source
                                  error:&error]);
    assert([target submitWithError:&error]);
    assert(targetQueue.foreignWaits.count == 2 &&
           [targetQueue.foreignWaits[1][1] unsignedLongLongValue] == 3);
    [sourceQueue completeWithError:nil];
    [targetQueue completeWithError:nil];
    /* Finished producer work does not need a redundant native event wait. */
    assert([target beginWithError:&error]);
    assert([target orderAfterSubmission:third
                           fromCommands:source
                                  error:&error]);
    assert([target submitWithError:&error] &&
           targetQueue.foreignWaits.count == 2);
    [targetQueue completeWithError:nil];
    /* Whole-batch cancellation never leaks a native wait into a later submit.
     */
    assert([target beginWithError:&error]);
    assert([target orderAfterSubmission:third
                           fromCommands:source
                                  error:&error]);
    [target cancel];
    assert([target beginWithError:&error] && [target submitWithError:&error]);
    assert(targetQueue.foreignWaits.count == 2);
    [targetQueue completeWithError:nil];
    /* A source error arriving after registration rejects submit while its
     * newest recording is still cancellable. */
    assert([source beginWithError:&error] && [source submitWithError:&error]);
    NV2AMetalSubmission *failed = source.lastSubmitted;
    assert([target beginWithError:&error]);
    recording = target.commandBuffer;
    assert([target orderAfterSubmission:failed
                           fromCommands:source
                                  error:&error]);
    NSError *failure = [NSError errorWithDomain:@"test.gpu-order"
                                           code:1
                                       userInfo:nil];
    [sourceQueue completeWithError:failure];
    assert(![target submitWithError:&error] && error == failure &&
           target.commandBuffer == recording &&
           targetQueue.foreignWaits.count == 2);
    assert(![target orderAfterSubmission:failed
                            fromCommands:source
                                   error:&error] &&
           error == failure);
    [target cancel];
    TestDevice *other = [TestDevice new];
    other.supported = other.freshQueues = YES;
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:(id)other error:&error];
    assert([foreign beginWithError:&error] && [foreign submitWithError:&error]);
    assert([target beginWithError:&error]);
    assert(![target orderAfterSubmission:foreign.lastSubmitted
                            fromCommands:foreign
                                   error:&error] &&
           error);
    [target cancel];
    [other.queue completeWithError:nil];
    assert([target waitUntilIdleWithError:&error]);
    /* Registered waits keep a native source queue/event alive even after
     * the source owner disappears; full idle releases that retention. */
    __weak TestQueue *weakQueue;
    @autoreleasepool {
        NV2AMetalCommands *ephemeral =
            [[NV2AMetalCommands alloc] initWithDevice:(id)device error:&error];
        TestQueue *queue = device.queue;
        weakQueue = queue;
        assert([ephemeral beginWithError:&error] &&
               [ephemeral submitWithError:&error]);
        assert([target beginWithError:&error] &&
               [target orderAfterSubmission:ephemeral.lastSubmitted
                               fromCommands:ephemeral
                                      error:&error]);
        ephemeral = nil;
        device.queue = targetQueue;
        queue = nil;
        assert(weakQueue);
        assert([target submitWithError:&error]);
        [weakQueue completeWithError:nil];
        [targetQueue completeWithError:nil];
        assert([target waitUntilIdleWithError:&error]);
    }
    assert(!weakQueue);
    /* A later successful callback cannot discard an earlier pending wait on
     * the same native event. Exercise callback order independently of GPU
     * execution order. */
    @autoreleasepool {
        TestDevice *reordered = [TestDevice new];
        reordered.supported = reordered.freshQueues = YES;
        NV2AMetalCommands *producer =
            [[NV2AMetalCommands alloc] initWithDevice:(id)reordered
                                                error:&error];
        TestQueue *producerQueue = reordered.queue;
        NV2AMetalCommands *consumer =
            [[NV2AMetalCommands alloc] initWithDevice:(id)reordered
                                                error:&error];
        TestQueue *consumerQueue = reordered.queue;
        assert([producer beginWithError:&error] &&
               [producer submitWithError:&error]);
        NV2AMetalSubmission *earlier = producer.lastSubmitted;
        assert([producer beginWithError:&error] &&
               [producer submitWithError:&error]);
        NV2AMetalSubmission *later = producer.lastSubmitted;
        [producerQueue.pending exchangeObjectAtIndex:0 withObjectAtIndex:1];
        [producerQueue completeWithError:nil];
        assert(![earlier completedWithError:NULL] &&
               [later completedWithError:NULL]);
        assert([consumer beginWithError:&error]);
        assert([consumer orderAfterSubmission:earlier
                                 fromCommands:producer
                                        error:&error]);
        assert([consumer orderAfterSubmission:later
                                 fromCommands:producer
                                        error:&error]);
        assert([consumer submitWithError:&error]);
        assert(consumerQueue.foreignWaits.count == 1 &&
               [consumerQueue.foreignWaits[0][1] unsignedLongLongValue] == 2);
        [producerQueue completeWithError:nil];
        [consumerQueue completeWithError:nil];
        assert([producer waitUntilIdleWithError:&error] &&
               [consumer waitUntilIdleWithError:&error]);
    }
    puts("Metal GPU queue order:deferred native waits,immutable source "
         "timeline,owner/device rejection,duplicate/max "
         "coalescing,sealed-prefix/suffix cancellation,no later-source "
         "drain,late source error preserves recording,source-owner destruction "
         "and bounded lifetime PASS (CPU only)");
}
#endif
