/* Capture-only attachment preparation preserves queue and ownership boundaries.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SURFACE_CAPTURE_H
#define TEST_METAL_SURFACE_CAPTURE_H
static void surface_capture_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned cases = 0;
    for (unsigned color = 0; color < 2; color++)
        for (unsigned scale = 1; scale <= 2; scale++)
            for (unsigned swizzle = 0; swizzle < 2; swizzle++) {
                NV2AMetalCommands *commands =
                    [[NV2AMetalCommands alloc] initWithDevice:device
                                                        error:&error];
                id<MTLBuffer> ram =
                    [device newBufferWithLength:4096
                                        options:MTLResourceStorageModeShared];
                require(commands && ram, error);
                memset(ram.contents, 0x91, ram.length);
                NV2AMetalSurfaceCache *cache =
                    [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                               vram:ram
                                                       didWriteVRAM:nil
                                                              error:&error];
                require(cache != nil, error);
                NV2AMetalSurfaceConfig c =
                    config(color ? NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 :
                                   NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                           color, color ? 4 : 2, scale, swizzle);
                NV2AMetalCachedSurface *surface =
                    [cache prepareSurfaceAtAddress:64
                                            config:&c
                                             frame:1
                                      forRendering:NO
                                             error:&error];
                require(surface != nil, error);
                assert(commands.commandBuffer && cache.recording &&
                       !surface.needsUpload);
                NV2AMetalSurfaceRecording *upload = cache.recording;
                require([cache checkpointWithError:&error], error);
                uint64_t serial = commands.recordingSerial,
                         generation = surface.generation;
                for (unsigned i = 0; i < 4; i++) {
                    require([cache prepareSurfaceAtAddress:64
                                                    config:&c
                                                     frame:2
                                              forRendering:NO
                                                     error:&error] == surface,
                            error);
                    require([cache checkpointWithError:&error], error);
                    assert(!commands.commandBuffer &&
                           commands.recordingSerial == serial &&
                           commands.sealedBufferCount == 1 &&
                           !cache.recording && !upload.cancelled &&
                           !upload.submitted &&
                           surface.generation == generation);
                }
                [cache cancel];
                assert(!upload.cancelled &&
                       ![cache markWritten:surface error:&error] && error);
                require([cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
                assert(upload.completed);
                NV2AMetalSubmission *receipt = commands.lastSubmitted;
                for (unsigned i = 0; i < 4; i++) {
                    require([cache prepareSurfaceAtAddress:64
                                                    config:&c
                                                     frame:3
                                              forRendering:NO
                                                     error:&error] == surface,
                            error);
                    require([cache checkpointWithError:&error] &&
                                [cache submitWithError:&error],
                            error);
                    assert(!commands.commandBuffer &&
                           !commands.sealedBufferCount &&
                           commands.recordingSerial == serial &&
                           commands.lastSubmitted == receipt);
                }
                /* A CPU write still requires a new upload. Cancelling that
                 * upload must keep its invalidation for the next attempt. */
                require([cache
                            prepareCPUAccessAtAddress:64
                                               length:surface.reservationLength
                                                write:YES
                                                error:&error],
                        error);
                memset((uint8_t *)ram.contents + 64, 0x42,
                       surface.reservationLength);
                require([cache prepareSurfaceAtAddress:64
                                                config:&c
                                                 frame:4
                                          forRendering:NO
                                                 error:&error] == surface,
                        error);
                assert(commands.commandBuffer && cache.recording);
                NV2AMetalSurfaceRecording *cancelled = cache.recording;
                [cache cancel];
                assert(cancelled.cancelled && surface.needsUpload);
                require([cache prepareSurfaceAtAddress:64
                                                config:&c
                                                 frame:4
                                          forRendering:NO
                                                 error:&error] == surface,
                        error);
                require([cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
                require([cache prepareSurfaceAtAddress:64
                                                config:&c
                                                 frame:4
                                                 error:&error] == surface,
                        error);
                id<MTLBuffer> result = gpu_pixels(cache, surface);
                unsigned bytes = color ? 4 : 2;
                for (NSUInteger at = 0; at < result.length; at++) {
                    BOOL pixel = swizzle ? at < c.width * c.height * bytes :
                                           at % c.pitch < c.width * bytes;
                    assert(((uint8_t *)result.contents)[at] ==
                           (pixel ? 0x42 : 0xcd));
                }
                /* A queued GPU write remains dirty and accepted while its
                 * layout is captured again, without an extra empty section. */
                require([cache prepareSurfaceAtAddress:64
                                                config:&c
                                                 frame:4
                                                 error:&error] == surface,
                        error);
                clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 1,
                              0);
                NV2AMetalSurfaceRecording *written = cache.recording;
                require([cache checkpointWithError:&error], error);
                serial = commands.recordingSerial;
                generation = surface.generation;
                require([cache prepareSurfaceAtAddress:64
                                                config:&c
                                                 frame:5
                                          forRendering:NO
                                                 error:&error] == surface,
                        error);
                [cache cancel];
                assert(surface.dirty && surface.generation == generation &&
                       commands.recordingSerial == serial &&
                       !commands.commandBuffer &&
                       commands.sealedBufferCount == 1 && !written.cancelled);
                require([cache
                            prepareCPUAccessAtAddress:64
                                               length:surface.reservationLength
                                                write:NO
                                                error:&error],
                        error);
                check_region(ram, 64, c, color ? 0xff00ff00 : 0xffff, 0x42);
                assert(written.completed && !surface.dirty);
                NV2AMetalSurfaceConfig invalid = c;
                invalid.width = 0;
                serial = commands.recordingSerial;
                assert(![cache prepareSurfaceAtAddress:64
                                                config:&invalid
                                                 frame:5
                                          forRendering:NO
                                                 error:&error] &&
                       error);
                assert(!commands.commandBuffer &&
                       commands.recordingSerial == serial);
                require([cache discardForRestoreWithError:&error], error);
                assert(!surface.valid && !cache.count);
                cases++;
            }
    assert(cases == 8);
    checks++;
    puts("Capture-only surfaces:8 color/Z16,scale1/2,linear/swizzled cases;64 "
         "warm captures without a new section or submit;required uploads,CPU "
         "invalidation,cancel/retry,queued dirty prefix,write-preparation "
         "guard,exact GPU/VRAM bytes,invalid layout and restore PASS");
}
#endif
