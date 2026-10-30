/* Clean surface aliases permit independent GPU readers; writeback must wait.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CLEAN_SURFACE_READER_H
#define TEST_METAL_CLEAN_SURFACE_READER_H
static void clean_surface_reader_tests(id<MTLDevice> device)
{
    unsigned cases = 0;
    for (unsigned mode = 0; mode < 8; mode++) {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *producer =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        require(commands && producer, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        assert(ram);
        memset(ram.contents, 0x33, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        NV2AMetalSurfaceConfig c =
            config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
        NV2AMetalCachedSurface *surface =
            [cache prepareSurfaceAtAddress:32764
                                    config:&c
                                     frame:0
                                     error:&error];
        require(surface != nil, error);
        if (mode == 1 || mode == 2 || mode == 3) {
            require([cache submitWithError:&error], error);
            require([cache waitUntilIdleWithError:&error], error);
            if (mode == 2) {
                require([cache observeCPUWriteAtAddress:32764
                                                 length:8
                                                  error:&error],
                        error);
                assert(surface.needsUpload);
                memset((uint8_t *)ram.contents + 32764, 0x44, 8);
            } else if (mode == 3) {
                require([cache markRTTSampling:surface error:&error], error);
            }
        }
        id<MTLBuffer> marker = encode_vram_copy(cache, 60000, 4);
        id recording = commands.commandBuffer;
        NV2AMetalSurfaceRecording *token = cache.recording;
        uint64_t generation = surface.generation;
        id<MTLSharedEvent> surfaceGate = [device newSharedEvent];
        assert(surfaceGate);
        Ivar queueIvar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> surfaceQueue = object_getIvar(commands, queueIvar);
        [surfaceQueue waitForEvent:surfaceGate value:1];
        NV2AMetalVRAMReadSpan spans[] = { { 32764, 8 }, { 32768, 4 } };
        NV2AMetalIndependentReads *reads = nil;
        require([cache tryBeginIndependentReads:spans
                                          count:2
                                       commands:producer
                                          reads:&reads
                                          error:&error],
                error);
        assert(reads && producer.commandBuffer && !surfaceGate.signaledValue);
        id<MTLBuffer> output = independent_read_copy(producer, ram);
        assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8, YES));
        if (mode == 4) {
            [cache cancelIndependentReads:reads];
            /* The surface upload still owns the same pages after cancellation.
             */
            BOOL completed = YES;
            require([cache tryIdleCPUAccessAtAddress:32764
                                              length:8
                                               write:YES
                                           completed:&completed
                                               error:&error],
                    error);
            assert(!completed && surface.generation == generation);
        } else if (mode < 4) {
            require([cache submitIndependentReads:reads error:&error], error);
            require([cache completeIndependentReads:reads error:&error], error);
            uint64_t expected = mode == 2 ? UINT64_C(0x4444444444444444) :
                                            UINT64_C(0x3333333333333333);
            assert(*(uint64_t *)output.contents == expected);
            assert(!surfaceGate.signaledValue && !token.submitted &&
                   commands.commandBuffer == recording &&
                   surface.generation == generation);
        } else {
            producer.gate = [device newSharedEvent];
            assert(producer.gate);
            id<MTL4CommandQueue> producerQueue =
                object_getIvar(producer, queueIvar);
            [producerQueue waitForEvent:producer.gate value:1];
            /* An unsent reader cannot be overwritten; a submitted, cancelled
             * reader remains protected until actual producer completion. */
            clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
            assert(![cache prepareGPUReadAtAddress:32764
                                            length:8
                                             error:&error] &&
                   error);
            assert(surface.dirty && !producer.gate.signaledValue &&
                   commands.commandBuffer == recording);
            require([cache submitIndependentReads:reads error:&error], error);
            [cache cancelIndependentReads:reads];
            require([cache prepareGPUReadAtAddress:32764 length:8 error:&error],
                    error);
            assert(!producer.waits && !producer.gate.signaledValue &&
                   !surfaceGate.signaledValue && !surface.dirty &&
                   !*(uint64_t *)output.contents);
            assert(*(uint64_t *)((uint8_t *)ram.contents + 32764) ==
                   UINT64_C(0x3333333333333333));
            if (mode == 6)
                require([cache submitWithError:&error], error);
            NV2AMetalIndependentReads *blocked = nil;
            require([cache tryBeginIndependentReads:spans
                                              count:2
                                           commands:producer
                                              reads:&blocked
                                              error:&error],
                    error);
            assert(!blocked && !producer.commandBuffer); /* Pending download. */
            if (mode == 7) {
                [cache cancel];
                assert(token.cancelled && !surface.dirty);
                require([cache tryBeginIndependentReads:spans
                                                  count:2
                                               commands:producer
                                                  reads:&blocked
                                                  error:&error],
                        error);
                assert(blocked);
                [cache cancelIndependentReads:blocked];
            }
        }
        if (!token.cancelled && !token.submitted)
            require([cache submitWithError:&error], error);
        surfaceGate.signaledValue = 1;
        require([cache waitUntilIdleWithError:&error], error);
        if (!token.cancelled)
            assert(*(uint32_t *)marker.contents == 0x33333333);
        if (mode == 5 || mode == 6)
            assert(*(uint32_t *)((uint8_t *)ram.contents + 32764) ==
                   0xff00ff00);
        require([cache discardForRestoreWithError:&error], error);
        cases++;
    }
    checks += cases;
    printf("Clean surface readers: %u upload/committed/invalidated/RTT/cancel/"
           "future-download cases;independent native copy before surface gate,"
           "GPU-ordered writeback and pending downloads reject PASS\n",
           cases);
}
#endif
