/* Read-only VRAM consumers may overlap private texture uploads/rendering.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PARALLEL_SURFACE_READERS_H
#define TEST_METAL_PARALLEL_SURFACE_READERS_H
static id<MTLBuffer> parallel_surface_pixels(NV2AMetalSurfaceCache *cache,
                                             NV2AMetalCachedSurface *surface)
{
    NSError *error = nil;
    id<MTLBuffer> result = [cache.commands.device
        newBufferWithLength:surface.transfer.sourceLength
                    options:MTLResourceStorageModeShared];
    assert(result);
    memset(result.contents, 0xcd, result.length);
    require([surface.transfer encodeDownloadToBuffer:result
                                              offset:0
                                             swizzle:YES
                                                flip:NO
                                           downscale:YES
                                            commands:cache.commands
                                               error:&error],
            error);
    require([cache submitWithError:&error], error);
    require([cache waitForSubmission:cache.commands.lastSubmitted error:&error],
            error);
    return result;
}
static void parallel_surface_check(id<MTLBuffer> pixels,
                                   NV2AMetalSurfaceConfig c, uint32_t word)
{
    unsigned bytes = bytes_for(c);
    for (NSUInteger at = 0; at < pixels.length; at++) {
        BOOL valid = c.swizzle ? at < c.width * c.height * bytes :
                                 at % c.pitch < c.width * bytes;
        uint8_t expected = valid ? word >> (8 * (at % bytes)) : 0xcd;
        assert(((const uint8_t *)pixels.contents)[at] == expected);
    }
}
static void parallel_surface_reader_tests(id<MTLDevice> device)
{
    unsigned cases = 0, unsentRejections = 0;
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    IndependentReadCommands *producer =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    require(commands && producer, error);
    for (unsigned format = 0; format < 3; format++)
        for (unsigned scale = 1; scale <= 2; scale++)
            for (unsigned swizzle = 0; swizzle < 2; swizzle++)
                for (unsigned phase = 0; phase < 5; phase++)
                    for (unsigned state = 0; state < 3; state++) {
                        @autoreleasepool {
                            NSError *error = nil;
                            producer.waits = producer.idleWaits = 0;
                            id<MTLBuffer> ram = [device
                                newBufferWithLength:65536
                                            options:
                                                MTLResourceStorageModeShared];
                            assert(ram);
                            memset(ram.contents, 0x33, ram.length);
                            NV2AMetalSurfaceCache *cache =
                                [[NV2AMetalSurfaceCache alloc]
                                    initWithCommands:commands
                                                vram:ram
                                        didWriteVRAM:nil
                                               error:&error];
                            require(cache != nil, error);
                            NV2AMetalSurfaceConfig c = config(
                                format == 0 ?
                                    NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 :
                                format == 1 ?
                                    NV097_SET_SURFACE_FORMAT_ZETA_Z16 :
                                    NV097_SET_SURFACE_FORMAT_ZETA_Z24S8,
                                format == 0, format == 1 ? 2 : 4, scale,
                                swizzle);
                            NV2AMetalCachedSurface *original = nil;
                            uint8_t source = 0x33;
                            if (phase) {
                                original =
                                    [cache prepareSurfaceAtAddress:32764
                                                            config:&c
                                                             frame:0
                                                             error:&error];
                                require(original != nil, error);
                                if (phase > 1)
                                    require(
                                        [cache submitWithError:&error] &&
                                            [cache
                                                waitUntilIdleWithError:&error],
                                        error);
                                if (phase == 3) {
                                    require(
                                        [cache
                                            prepareCPUAccessAtAddress:32764
                                                               length:
                                                                   original
                                                                       .reservationLength
                                                                write:YES
                                                                error:&error],
                                        error);
                                    source = 0x44;
                                    memset((uint8_t *)ram.contents + 32764,
                                           source, original.reservationLength);
                                }
                                if (phase == 4)
                                    c.height *=
                                        2; /* Clean incompatible alias. */
                            }
                            NV2AMetalVRAMReadSpan spans[] = { { 32764, 8 },
                                                              { 32768, 4 } };
                            NV2AMetalIndependentReads *reads = nil;
                            require([cache tryBeginIndependentReads:spans
                                                              count:2
                                                           commands:producer
                                                              reads:&reads
                                                              error:&error],
                                    error);
                            require(reads != nil, error);
                            id<MTLBuffer> input =
                                independent_read_copy(producer, ram);
                            memset(input.contents, 0, input.length);
                            producer.gate = [device newSharedEvent];
                            assert(producer.gate);
                            Ivar ivar = class_getInstanceVariable(
                                NV2AMetalCommands.class, "_queue");
                            id<MTL4CommandQueue> queue =
                                object_getIvar(producer, ivar);
                            assert(queue);
                            [queue waitForEvent:producer.gate value:1];
                            if (state) {
                                require([cache submitIndependentReads:reads
                                                                error:&error],
                                        error);
                                if (state == 2)
                                    [cache cancelIndependentReads:reads];
                            }
                            NV2AMetalCachedSurface *surface =
                                [cache prepareSurfaceAtAddress:32764
                                                        config:&c
                                                         frame:1
                                                         error:&error];
                            require(surface != nil, error);
                            assert(!producer.waits && !producer.idleWaits &&
                                   !producer.gate.signaledValue);
                            if (phase == 4)
                                assert(!original.valid && surface != original);
                            id<MTLBuffer> uploaded =
                                parallel_surface_pixels(cache, surface);
                            parallel_surface_check(
                                uploaded, c, source * UINT32_C(0x01010101));
                            uint64_t expected =
                                source * UINT64_C(0x0101010101010101);
                            assert(!producer.waits &&
                                   !producer.gate.signaledValue &&
                                   !*(uint64_t *)input.contents &&
                                   *(uint64_t *)((uint8_t *)ram.contents +
                                                 32764) == expected &&
                                   !nv2a_metal_try_cpu_access(
                                       cache.cpuAccessGuard, 32764, 8, YES));
                            /* Texture writes can finish before the independent
                             * reader, since neither one overwrites guest VRAM.
                             */
                            require([cache prepareSurfaceAtAddress:32764
                                                            config:&c
                                                             frame:1
                                                             error:&error] ==
                                        surface,
                                    error);
                            clear_surface(cache, surface,
                                          MTLClearColorMake(0, 1, 0, 1), 1,
                                          0xa5);
                            NV2AMetalSurfaceRecording *written =
                                cache.recording;
                            id<MTLBuffer> rendered =
                                parallel_surface_pixels(cache, surface);
                            uint32_t word = format == 0 ? UINT32_C(0xff00ff00) :
                                            format == 1 ? UINT32_C(0xffff) :
                                                          UINT32_C(0xffffffa5);
                            parallel_surface_check(rendered, c, word);
                            assert(surface.dirty && written.completed &&
                                   !producer.waits &&
                                   !producer.gate.signaledValue &&
                                   !*(uint64_t *)input.contents &&
                                   *(uint64_t *)((uint8_t *)ram.contents +
                                                 32764) == expected);
                            if (!state) {
                                uint64_t serial = commands.recordingSerial;
                                assert(
                                    ![cache prepareGPUReadAtAddress:32764
                                                             length:8
                                                              error:&error] &&
                                    error &&
                                    [error.localizedDescription
                                        containsString:
                                            @"Submit or cancel independent"]);
                                assert(surface.dirty &&
                                       !commands.commandBuffer &&
                                       commands.recordingSerial == serial &&
                                       !producer.waits &&
                                       !producer.gate.signaledValue);
                                unsentRejections++;
                                require([cache submitIndependentReads:reads
                                                                error:&error],
                                        error);
                            }
                            /* An actual RAM download must wait for the source
                             * reader. The reader sees old bytes, then VRAM
                             * changes.
                             */
                            require([cache prepareGPUReadAtAddress:32764
                                                            length:8
                                                             error:&error],
                                    error);
                            assert(!producer.waits &&
                                   !producer.gate.signaledValue &&
                                   !*(uint64_t *)input.contents &&
                                   !surface.dirty);
                            require([cache submitWithError:&error], error);
                            assert(!producer.waits &&
                                   !producer.gate.signaledValue &&
                                   ![commands.lastSubmitted
                                       completedWithError:NULL]);
                            require([cache
                                        waitForSubmission:commands.lastSubmitted
                                                    error:&error],
                                    error);
                            assert(producer.gate.signaledValue == 1 &&
                                   *(uint64_t *)input.contents == expected);
                            assert(producer.waits == 1);
                            check_region(ram, 32764, c, word, source);
                            require([cache discardForRestoreWithError:&error],
                                    error);
                            cases++;
                        }
                    }
    assert(cases == 180 && unsentRejections == 60);
    checks += cases;
    puts("Parallel surface readers:180 "
         "A8R8G8B8/Z16/Z24S8,scale1/2,linear/swizzled,cold/live-upload/warm/"
         "CPU-dirty/clean-replacement,unsent/submitted/cancelled-submitted "
         "cases;upload and private rendering finish before producer gate with "
         "zero reader waits;exact GPU/VRAM pixels,old source bytes,CPU "
         "protection,60 unsent writeback rejects,180 GPU-ordered downloads "
         "without encoding waits and180 CPU feedback boundaries "
         "PASS");
}
#endif
