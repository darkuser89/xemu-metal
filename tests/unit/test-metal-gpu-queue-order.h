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
    for (unsigned i = 0; i < 128; i++)
        assert([target orderAfterSubmission:first
                               fromCommands:source
                                      error:&error]);
    id slot = [target valueForKey:@"current"];
    NSArray *registered = [slot valueForKey:@"waits"];
    NSMapTable *receipts = [slot valueForKey:@"waitReceipts"];
    assert(registered.count == 1 && receipts.count == 1 &&
           [receipts objectForKey:first]);
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
    assert(registered.count == 1 && receipts.count == 1 &&
           [receipts objectForKey:first] && ![receipts objectForKey:second]);
    assert([target beginWithError:&error] &&
           [target orderAfterSubmission:second fromCommands:source error:&error]);
    assert(registered.count == 2 && receipts.count == 2 &&
           [receipts objectForKey:second]);
    [target cancelUnsealed];
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
    assert(!registered.count && !receipts.count);
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
    for (unsigned mode = 0; mode < 4; mode++) @autoreleasepool {
        BOOL reverse = mode & 1, mixedEvents = mode & 2;
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
        NV2AMetalCommands *readyProducer =
            [[NV2AMetalCommands alloc] initWithDevice:(id)reordered
                                                error:&error];
        TestQueue *readyQueue = reordered.queue;
        assert([readyProducer beginWithError:&error] &&
               [readyProducer submitWithError:&error]);
        NV2AMetalSubmission *becomesReady = readyProducer.lastSubmitted;
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
        SEL feedbackSelector = @selector(completedWithError:);
        Method feedback = class_getInstanceMethod(NV2AMetalSubmission.class,
                                                   feedbackSelector);
        assert(feedback);
        BOOL (*original)(id, SEL, NSError **) =
            (void *)method_getImplementation(feedback);
        __block unsigned earlierChecks = 0, laterChecks = 0, readyChecks = 0;
        IMP spy = imp_implementationWithBlock(
            ^BOOL(NV2AMetalSubmission *receipt, NSError **failure) {
                earlierChecks += receipt == earlier;
                laterChecks += receipt == later;
                readyChecks += receipt == becomesReady;
                return original(receipt, feedbackSelector, failure);
            });
        method_setImplementation(feedback, spy);
        assert([consumer beginWithError:&error]);
        assert([consumer orderAfterSubmission:reverse ? later : earlier
                                 fromCommands:producer
                                        error:&error]);
        if (mixedEvents && !reverse)
            assert([consumer orderAfterSubmission:becomesReady
                                     fromCommands:readyProducer
                                            error:&error]);
        assert([consumer orderAfterSubmission:reverse ? earlier : later
                                 fromCommands:producer
                                        error:&error]);
        if (mixedEvents && reverse)
            assert([consumer orderAfterSubmission:becomesReady
                                     fromCommands:readyProducer
                                            error:&error]);
        [readyQueue completeWithError:nil];
        for (unsigned i = 0; i < 2; i++) {
            if (mixedEvents)
                assert([consumer orderAfterSubmission:becomesReady
                                         fromCommands:readyProducer
                                                error:&error]);
            assert([consumer orderAfterSubmission:later fromCommands:producer
                                            error:&error]);
        }
        SEL factorySelector = @selector(mapTableWithKeyOptions:valueOptions:);
        Method factory = class_getClassMethod(NSMapTable.class, factorySelector);
        assert(factory);
        NSMapTable *(*originalFactory)(id, SEL, NSPointerFunctionsOptions,
                                       NSPointerFunctionsOptions) =
            (void *)method_getImplementation(factory);
        __block unsigned tables = 0;
        IMP factorySpy = imp_implementationWithBlock(
            ^NSMapTable *(Class cls, NSPointerFunctionsOptions keys,
                          NSPointerFunctionsOptions values) {
                tables++;
                return originalFactory(cls, factorySelector, keys, values);
            });
        method_setImplementation(factory, factorySpy);
        assert([consumer submitWithError:&error]);
        method_setImplementation(factory, (IMP)originalFactory);
        assert(imp_removeBlock(factorySpy));
        assert(tables == (mixedEvents ? 1u : 0u));
        method_setImplementation(feedback, (IMP)original);
        assert(imp_removeBlock(spy));
        assert(earlierChecks == 2 && laterChecks == 1 &&
               readyChecks == (mixedEvents ? 2u : 0u));
        assert(consumerQueue.foreignWaits.count == 1 &&
               ((TestEvent *)consumerQueue.foreignWaits[0][0]).queue ==
                   producerQueue &&
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
    puts("Metal GPU wait index: 128 duplicate registrations keep one receipt; "
         "suffix cancellation, retry and idle release preserve membership PASS");
    puts("Metal GPU event groups: a pending earlier receipt keeps the maximum "
         "timeline wait in either order; another completed event is skipped PASS");
    puts("Metal GPU wait feedback: confirmed success is reused at registration "
         "and submit; pending receipts are checked again PASS");
    puts("Metal GPU event table: zero grouping tables for one event, "
         "one for mixed events; out-of-order feedback still gates the batch PASS");
}
#endif
