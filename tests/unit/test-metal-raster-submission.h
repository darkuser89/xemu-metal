/* Composite producer/raster receipts and cancellation; no GPU is created.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RASTER_SUBMISSION_H
#define TEST_METAL_RASTER_SUBMISSION_H
static void check_raster_submissions(void)
{
    for (unsigned mode = 0; mode < 6; mode++) {
        TestDevice *device = [TestDevice new];
        device.supported = YES;
        device.queue = [TestQueue new];
        device.queue.pending = [NSMutableArray new];
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                                error:&error];
        assert(commands);
        __weak TestResource *lifetime;
        @autoreleasepool {
            TestResource *resource = [TestResource new];
            resource.device = device;
            lifetime = resource;
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = (id<MTLTexture>)resource;
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            for (unsigned i = 0; i < NV2AMetalCommandBatchLimit; i++) {
                assert([commands beginWithError:&error]);
                uint64_t serial = commands.recordingSerial;
                assert([commands addResource:(id<MTLResource>)resource
                                       error:&error]);
                id<MTL4RenderCommandEncoder> encoder =
                    [commands beginRasterPass:pass error:&error];
                assert(encoder && commands.recordingSerial == serial);
                [encoder endEncoding];
                if (i + 1 < NV2AMetalCommandBatchLimit)
                    assert([commands sealWithError:&error]);
            }
            assert([commands submitWithError:&error] &&
                   !commands.hasPendingRasterPass);
        }
        assert(device.queue.pending.count == 2 && lifetime);
        TestSubmission *producer = device.queue.pending[0];
        TestSubmission *raster = device.queue.pending[1];
        assert(producer.bufferCount == 32 && raster.bufferCount == 33);
        for (TestBuffer *buffer in producer.buffers)
            assert(!buffer.raster);
        for (NSUInteger i = 0; i < raster.buffers.count; i++) {
            TestBuffer *buffer = raster.buffers[i];
            assert(buffer.raster &&
                   buffer.rasterOptions ==
                       (!i      ? MTL4RenderEncoderOptionSuspending :
                        i == 32 ? MTL4RenderEncoderOptionResuming :
                                  MTL4RenderEncoderOptionSuspending |
                                      MTL4RenderEncoderOptionResuming));
        }
        /* Neither feedback order may publish a half-completed receipt. */
        BOOL reverse = mode >= 3;
        BOOL producerFailure = mode == 1 || mode == 4;
        BOOL rasterFailure = mode == 2 || mode == 3;
        if (reverse)
            [device.queue.pending exchangeObjectAtIndex:0 withObjectAtIndex:1];
        NV2AMetalSubmission *receipt = commands.lastSubmitted;
        assert(receipt.hasSeparateProducerFeedback &&
               ![receipt completedProducersWithError:&error] && !error);
        NSError *failure = [NSError errorWithDomain:@"test.raster.commit"
                                               code:mode
                                           userInfo:nil];
        [device.queue completeWithError:(reverse ? rasterFailure : producerFailure) ? failure : nil];
        error = failure;
        assert(![receipt completedWithError:&error] && !error && lifetime);
        if (!reverse) {
            assert([receipt completedProducersWithError:&error] &&
                   error == (producerFailure ? failure : nil));
            assert([commands waitForProducersOfSubmission:receipt error:&error] == !producerFailure);
        } else {
            assert(![receipt completedProducersWithError:&error] && !error);
        }
        [device.queue completeWithError:(reverse ? producerFailure : rasterFailure) ? failure : nil];
        assert([receipt completedWithError:&error] &&
               error == (producerFailure || rasterFailure ? failure : nil));
        assert([receipt completedProducersWithError:&error] &&
               error == (producerFailure || rasterFailure ? failure : nil));
        assert([commands waitForProducersOfSubmission:receipt error:&error] ==
               !(producerFailure || rasterFailure));
        NV2AMetalCommands *foreign = [[NV2AMetalCommands alloc]
            initWithDevice:(id<MTLDevice>)device error:&error];
        assert(foreign && ![foreign waitForProducersOfSubmission:receipt error:&error] && error);
        if (!producerFailure && !rasterFailure) {
            producer = raster = nil;
            assert([commands waitUntilIdleWithError:&error]);
            @autoreleasepool {
            }
            assert(!lifetime);
        }
    }
    for (unsigned fail = 1; fail <= 3; fail++) {
        TestDevice *device = [TestDevice new];
        device.supported = YES;
        device.queue = [TestQueue new];
        device.queue.pending = [NSMutableArray new];
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:(id<MTLDevice>)device
                                                error:&error];
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        assert([commands beginWithError:&error]);
        raster_encoder_fail = 0;
        if (fail == 3) {
            id<MTL4RenderCommandEncoder> encoder =
                [commands beginRasterPass:pass error:&error];
            assert(encoder);
            [encoder endEncoding];
        }
        assert([commands sealWithError:&error]);
        assert([commands beginWithError:&error]);
        raster_encoder_fail = raster_encoder_calls + (fail == 2 ? 2 : 1);
        assert(![commands beginRasterPass:pass error:&error]);
        [commands cancelUnsealed];
        raster_encoder_fail = 0;
        assert(commands.sealedBufferCount == 1 &&
               commands.hasPendingRasterPass == (fail == 3));
        assert([commands submitWithError:&error]);
        while (device.queue.pending.count)
            [device.queue completeWithError:nil];
        assert([commands waitUntilIdleWithError:&error]);
    }
    puts("Metal raster submissions:32 producers/33 contiguous suspend-resume "
         "buffers,one composite receipt,both errors/reversed feedback order,"
         "separate producer readiness/wait,aggregate failure and foreign-owner checks,"
         "resource lifetime and three failed-encoder suffix cancellations PASS "
         "(CPU only)");
}
#endif
