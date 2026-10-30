/* GPU-ordered RAM writes keep exact cancellation and feedback boundaries.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_GPU_WRITE_DEPENDENCIES_H
#define TEST_METAL_GPU_WRITE_DEPENDENCIES_H
static id<MTLBuffer> gpu_dep_copy(NV2AMetalCommands *commands,
                                  id<MTLBuffer> input, NSUInteger address,
                                  id<MTLBuffer> output, NSUInteger destination)
{
    NSError *error = nil;
    if (!output) {
        output =
            [commands.device newBufferWithLength:8
                                         options:MTLResourceStorageModeShared];
        assert(output);
        memset(output.contents, 0, 8);
    }
    require([commands addResource:input error:&error] &&
                [commands addResource:output error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:input
               sourceOffset:address
                   toBuffer:output
          destinationOffset:destination
                       size:8];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return output;
}
static void gpu_dep_write(NV2AMetalSurfaceCache *cache, NSUInteger address,
                          uint64_t word)
{
    NSError *error = nil;
    require([cache prepareGPUWriteAtAddress:address length:8 error:&error],
            error);
    id<MTLBuffer> input =
        [cache.commands.device newBufferWithBytes:&word
                                           length:8
                                          options:MTLResourceStorageModeShared];
    assert(input);
    gpu_dep_copy(cache.commands, input, 0, cache.vram, address);
}
static NV2AMetalIndependentReads *gpu_dep_read(NV2AMetalSurfaceCache *cache,
                                               IndependentReadCommands *source,
                                               NSUInteger address,
                                               id<MTLBuffer> *bytes)
{
    NSError *error = nil;
    NV2AMetalVRAMReadSpan span = { address, 8 };
    NV2AMetalIndependentReads *reads = nil;
    require([cache tryBeginIndependentReads:&span
                                      count:1
                                   commands:source
                                      reads:&reads
                                      error:&error] &&
                reads,
            error);
    *bytes = gpu_dep_copy(source, cache.vram, address, nil, 0);
    require([cache submitIndependentReads:reads error:&error], error);
    return reads;
}
static void gpu_dep_gate(IndependentReadCommands *source)
{
    source.gate = [source.device newSharedEvent];
    source.manualGate = YES;
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(source, ivar);
    assert(queue && source.gate);
    [queue waitForEvent:source.gate value:1];
    id<MTLSharedEvent> gate = source.gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
}
static uint64_t gpu_dep_word(id<MTLBuffer> buffer, NSUInteger address)
{
    uint64_t word;
    memcpy(&word, (const uint8_t *)buffer.contents + address, sizeof(word));
    return word;
}
static void gpu_write_dependency_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned cases = 0;
    @autoreleasepool {
        NV2AMetalCommands *target =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        require(target && source && ram, error);
        memset(ram.contents, 0x33, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        gpu_dep_gate(source);
        id<MTLBuffer> old = nil;
        gpu_dep_read(cache, source, 32764, &old);
        gpu_dep_write(cache, 32764, UINT64_C(0x8888888888888888));
        NV2AMetalSurfaceRecording *written = cache.recording;
        require([cache submitWithError:&error], error);
        assert(!source.waits && !source.gate.signaledValue);
        /* Release independently of source CPU waits. Waiting only on the
         * target exercises the actual cross-queue GPU dependency. */
        id<MTLSharedEvent> gate = source.gate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         gate.signaledValue = 1;
                       });
        require([target waitForSubmission:target.lastSubmitted error:&error],
                error);
        assert(!source.waits && source.gate.signaledValue == 1 &&
               gpu_dep_word(old, 0) == UINT64_C(0x3333333333333333) &&
               gpu_dep_word(ram, 32764) == UINT64_C(0x8888888888888888));
        require([cache waitForSubmission:target.lastSubmitted error:&error],
                error);
        assert(written.completed && source.waits == 1);
        require([cache discardForRestoreWithError:&error], error);
        cases++;
    }
    for (unsigned prefix = 0; prefix < 2; prefix++) {
        @autoreleasepool {
            NV2AMetalCommands *target =
                [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
            IndependentReadCommands *source =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            source.manualGate = YES;
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && ram, error);
            memset(ram.contents, 0x11, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            NV2AMetalSurfaceRecording *accepted = nil;
            id<MTLBuffer> first = nil;
            if (prefix) {
                gpu_dep_read(cache, source, 32764, &first);
                /* Make the earlier callback available before introducing the
                 * artificial later queue gate. Receipt selection is tested
                 * separately from the driver's callback scheduling. */
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                source.waits = 0;
                gpu_dep_write(cache, 32764, UINT64_C(0x5555555555555555));
                accepted = cache.recording;
                require([cache checkpointWithError:&error], error);
            }
            gpu_dep_gate(source);
            id<MTLBuffer> later = nil;
            NV2AMetalIndependentReads *pending =
                gpu_dep_read(cache, source, 40000, &later);
            gpu_dep_write(cache, 40000, UINT64_C(0x7777777777777777));
            NV2AMetalSurfaceRecording *cancelled = cache.recording;
            assert(!source.waits && !source.gate.signaledValue);
            [cache cancel];
            assert(cancelled.cancelled && !source.gate.signaledValue);
            id<MTLBuffer> unrelated = nil;
            if (!prefix) {
                require([cache prepareGPUReadAtAddress:60000
                                                length:8
                                                 error:&error],
                        error);
                unrelated = gpu_dep_copy(target, ram, 60000, nil, 0);
                accepted = cache.recording;
            }
            require([cache submitWithError:&error], error);
            require([cache waitForSubmission:target.lastSubmitted error:&error],
                    error);
            assert(accepted.completed && !source.gate.signaledValue &&
                   !*(uint64_t *)later.contents &&
                   gpu_dep_word(ram, 40000) == UINT64_C(0x1111111111111111));
            if (prefix) {
                assert(source.waits == 1 &&
                       *(uint64_t *)first.contents ==
                           UINT64_C(0x1111111111111111) &&
                       gpu_dep_word(ram, 32764) ==
                           UINT64_C(0x5555555555555555));
            } else
                assert(!source.waits && *(uint64_t *)unrelated.contents ==
                                            UINT64_C(0x1111111111111111));
            BOOL completed = YES;
            require([cache tryIdleCPUAccessAtAddress:40000
                                              length:8
                                               write:YES
                                           completed:&completed
                                               error:&error],
                    error);
            assert(!completed);
            source.gate.signaledValue = 1;
            require([cache completeIndependentReads:pending error:&error],
                    error);
            assert(*(uint64_t *)later.contents == UINT64_C(0x1111111111111111));
            require([cache discardForRestoreWithError:&error], error);
            cases++;
        }
    }
    for (unsigned failure = 0; failure < 3; failure++) {
        @autoreleasepool {
            NV2AMetalCommands *target =
                [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
            IndependentReadCommands *source =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            IndependentReadCommands *unrelated =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && unrelated && ram, error);
            memset(ram.contents, 0x22, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            gpu_dep_gate(unrelated);
            id<MTLBuffer> other = nil, a = nil, b = nil;
            gpu_dep_read(cache, unrelated, 40000, &other);
            NV2AMetalIndependentReads *first =
                gpu_dep_read(cache, source, 32764, &a);
            require([source waitForSubmission:source.lastSubmitted
                                        error:&error],
                    error);
            IndependentReadReceipt *delayed = [IndependentReadReceipt new];
            delayed.nativeSubmission = source.lastSubmitted;
            [first setValue:delayed forKey:@"submission"];
            gpu_dep_read(cache, source, 32764, &b);
            require([source waitForSubmission:source.lastSubmitted
                                        error:&error],
                    error);
            source.waits = 0;
            gpu_dep_write(cache, 32764, UINT64_C(0x6666666666666666));
            NV2AMetalSurfaceRecording *written = cache.recording;
            if (failure == 2) {
                delayed.failure =
                    [NSError errorWithDomain:@"test.gpu-source-prefix"
                                        code:89
                                    userInfo:nil];
                delayed.ready = YES;
                assert(![cache submitWithError:&error] &&
                       error == delayed.failure && cache.recording == written &&
                       target.commandBuffer && !written.submitted &&
                       !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 60000,
                                                  8, NO));
                [cache cancel];
                assert(written.cancelled && !target.commandBuffer &&
                       gpu_dep_word(ram, 32764) ==
                           UINT64_C(0x2222222222222222));
                unrelated.gate.signaledValue = 1;
                require([unrelated waitForSubmission:unrelated.lastSubmitted
                                               error:&error],
                        error);
                cache = nil;
                require([target waitUntilIdleWithError:&error], error);
                cases++;
                continue;
            }
            require([cache submitWithError:&error], error);
            require([target waitForSubmission:target.lastSubmitted
                                        error:&error],
                    error);
            require([cache collectCompletedWithError:&error], error);
            BOOL completed = YES;
            require([cache tryIdleCPUAccessAtAddress:32764
                                              length:8
                                               write:NO
                                           completed:&completed
                                               error:&error],
                    error);
            assert(!completed && !written.completed && written.submitted &&
                   !delayed.ready && !source.waits && !unrelated.waits &&
                   !unrelated.gate.signaledValue &&
                   *(uint64_t *)a.contents == UINT64_C(0x2222222222222222) &&
                   *(uint64_t *)b.contents == UINT64_C(0x2222222222222222) &&
                   gpu_dep_word(ram, 32764) == UINT64_C(0x6666666666666666));
            delayed.failure =
                failure ? [NSError errorWithDomain:@"test.gpu-source-prefix"
                                              code:88
                                          userInfo:nil] :
                          nil;
            delayed.ready = YES;
            error = nil;
            assert([cache collectCompletedWithError:&error] == !failure);
            if (failure) {
                assert(error == delayed.failure && !written.completed &&
                       !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 60000,
                                                  8, NO));
            } else {
                completed = NO;
                require([cache tryIdleCPUAccessAtAddress:32764
                                                  length:8
                                                   write:NO
                                               completed:&completed
                                                   error:&error],
                        error);
                assert(completed && written.completed);
            }
            assert(!unrelated.waits && !unrelated.gate.signaledValue &&
                   !*(uint64_t *)other.contents);
            unrelated.gate.signaledValue = 1;
            require([unrelated waitForSubmission:unrelated.lastSubmitted
                                           error:&error],
                    error);
            assert(*(uint64_t *)other.contents == UINT64_C(0x2222222222222222));
            if (!failure)
                require([cache discardForRestoreWithError:&error], error);
            cache = nil;
            require([target waitUntilIdleWithError:&error], error);
            cases++;
        }
    }
    assert(cases == 6);
    checks += cases;
    puts("GPU RAM dependencies:six native gate/cancel/prefix/feedback "
         "cases;direct "
         "copies keep old reader bytes,accepted writer survives cancelled "
         "later-source suffix,no ghost GPU wait,unrelated queue remains "
         "gated,CPU publication waits for earlier source feedback,late source "
         "errors before submit and after GPU completion are sticky despite "
         "later success PASS");
}
#endif
