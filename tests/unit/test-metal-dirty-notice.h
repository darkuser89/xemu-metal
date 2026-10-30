/* Dirty-page notifications must not drain unrelated native GPU work.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DIRTY_NOTICE_H
#define TEST_METAL_DIRTY_NOTICE_H

@interface DirtyNoticeCommands : NV2AMetalCommands
@property(nonatomic) unsigned submits, waits;
@property(nonatomic) id<MTLSharedEvent> gate;
@end
@implementation DirtyNoticeCommands
- (BOOL)submitWithError:(NSError **)error
{
    _submits++;
    return [super submitWithError:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    _waits++;
    /* Release only if production actually waits. Safe cases require the gate
     * to remain zero, so the old unconditional drain fails deterministically.
     */
    if (_gate && !_gate.signaledValue)
        _gate.signaledValue = 1;
    return [super waitUntilIdleWithError:error];
}
@end

static void dirty_notice_tests(id<MTLDevice> device)
{
    unsigned cases = 0;
    for (unsigned submitted = 0; submitted < 2; submitted++)
        for (unsigned mode = 0; mode < 8; mode++) {
            NSError *error = nil;
            DirtyNoticeCommands *commands =
                [[DirtyNoticeCommands alloc] initWithDevice:device
                                                      error:&error];
            require(commands != nil, error);
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
            NV2AMetalSurfaceConfig c = config(
                NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
            NV2AMetalCachedSurface *surface = nil;
            if (mode == 1 || mode == 2 || mode == 3) {
                surface = [cache prepareSurfaceAtAddress:1024
                                                  config:&c
                                                   frame:0
                                                   error:&error];
                require(surface != nil, error);
                require([cache submitWithError:&error], error);
                require([cache waitUntilIdleWithError:&error], error);
                if (mode == 1) {
                    require([cache prepareSurfaceAtAddress:1024
                                                    config:&c
                                                     frame:1
                                                     error:&error] != nil,
                            error);
                    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1),
                                  0, 0);
                } else if (mode == 3) {
                    require([cache prepareSurfaceAtAddress:1024
                                                    config:&c
                                                     frame:1
                                                     error:&error] != nil,
                            error);
                }
            }
            NSUInteger readAddress = mode == 4 ? 50000 : 16384;
            id<MTLBuffer> output = encode_vram_copy(cache, readAddress, 4);
            NV2AMetalSurfaceRecording *token = cache.recording;
            id recording = commands.commandBuffer;
            uint64_t serial = commands.recordingSerial;
            commands.gate = [device newSharedEvent];
            assert(commands.gate);
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
            [queue waitForEvent:commands.gate value:1];
            if (submitted)
                require([cache submitWithError:&error], error);
            NSUInteger address = mode == 2 ? 1028 :
                                 mode == 4 ? 50016 :
                                 mode == 5 ? 32764 :
                                 mode == 6 ? 65536 :
                                             50000;
            NSUInteger length = mode == 5 ? 8 : mode == 6 ? 0 : 4;
            uint64_t before = 0, after = 0;
            require([cache sourceVersionAtAddress:address
                                           length:length
                                          version:&before
                                            error:&error],
                    error);
            if (length)
                memset((uint8_t *)ram.contents + address, 0x55, length);
            unsigned submits = commands.submits, waits = commands.waits;
            BOOL dirty = surface.dirty, upload = surface.needsUpload;
            uint64_t generation = surface.generation;
            require([cache observeCPUWriteAtAddress:address
                                             length:length
                                              error:&error],
                    error);
            assert(!commands.gate.signaledValue &&
                   commands.submits == submits && commands.waits == waits &&
                   commands.recordingSerial == serial);
            assert(token.submitted == !!submitted && !token.completed &&
                   !token.cancelled);
            assert(commands.commandBuffer == (submitted ? nil : recording));
            require([cache sourceVersionAtAddress:address
                                           length:length
                                          version:&after
                                            error:&error],
                    error);
            assert(length ? after > before : after == before);
            if (mode == 2) {
                assert(surface.needsUpload && surface.generation > generation);
            } else if (surface) {
                assert(surface.dirty == dirty &&
                       surface.needsUpload == upload &&
                       surface.generation == generation);
            }
            BOOL completed = YES;
            require([cache tryIdleCPUAccessAtAddress:readAddress
                                              length:4
                                               write:YES
                                           completed:&completed
                                               error:&error],
                    error);
            assert(!completed);
            if (!submitted && mode == 7) {
                [cache cancel];
                assert(token.cancelled && !token.submitted);
            } else {
                if (!submitted)
                    require([cache submitWithError:&error], error);
                commands.gate.signaledValue = 1;
                require([cache waitUntilIdleWithError:&error], error);
                assert(*(uint32_t *)output.contents == 0x33333333);
            }
            commands.gate.signaledValue = 1;
            if (mode == 2)
                assert(surface.needsUpload && surface.generation > generation);
            require([cache discardForRestoreWithError:&error], error);
            cases++;
        }

    /* Exact overlapping readers still drain; a dirty GPU target remains a
     * coherence error, with its recording and page version untouched. */
    for (unsigned submitted = 0; submitted < 2; submitted++)
        for (unsigned conflict = 0; conflict < 5; conflict++) {
            NSError *error = nil;
            DirtyNoticeCommands *commands =
                [[DirtyNoticeCommands alloc] initWithDevice:device
                                                      error:&error];
            require(commands != nil, error);
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
            NSUInteger address = 1024;
            id<MTLBuffer> output = encode_vram_copy(cache, address, 4);
            if (conflict == 1) {
                require([cache prepareGPUWriteAtAddress:address
                                                 length:4
                                                  error:&error],
                        error);
            } else if (conflict >= 2) {
                NV2AMetalSurfaceConfig c = config(
                    NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
                NV2AMetalCachedSurface *surface =
                    [cache prepareSurfaceAtAddress:address
                                            config:&c
                                             frame:0
                                             error:&error];
                require(surface != nil, error);
                if (conflict != 4)
                    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1),
                                  0, 0);
                if (conflict == 3)
                    require([cache prepareGPUReadAtAddress:address
                                                    length:4
                                                     error:&error],
                            error);
            }
            NV2AMetalSurfaceRecording *token = cache.recording;
            commands.gate = [device newSharedEvent];
            assert(commands.gate);
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
            [queue waitForEvent:commands.gate value:1];
            if (submitted)
                require([cache submitWithError:&error], error);
            unsigned submits = commands.submits, waits = commands.waits;
            uint64_t before = 0, after = 0;
            require([cache sourceVersionAtAddress:address
                                           length:4
                                          version:&before
                                            error:&error],
                    error);
            BOOL ok = [cache observeCPUWriteAtAddress:address
                                               length:4
                                                error:&error];
            if (!conflict || conflict >= 3) {
                require(ok, error);
                assert(commands.gate.signaledValue == 1 &&
                       commands.submits == submits + !submitted &&
                       commands.waits == waits + 1 && token.completed);
                assert(*(uint32_t *)output.contents == 0x33333333);
                if (conflict == 3)
                    assert(*(uint32_t *)((uint8_t *)ram.contents + address) ==
                           0xff00ff00);
            } else {
                assert(!ok && error && !commands.gate.signaledValue &&
                       commands.submits == submits && commands.waits == waits);
                require([cache sourceVersionAtAddress:address
                                               length:4
                                              version:&after
                                                error:&error],
                        error);
                assert(after == before);
                if (!submitted)
                    [cache cancel];
                commands.gate.signaledValue = 1;
                require([cache waitUntilIdleWithError:&error], error);
            }
            require([cache discardForRestoreWithError:&error], error);
            cases++;
        }
    checks += cases;
    printf("Dirty-page notifications: %u gated unrelated/overlap/target/cancel/"
           "restore cases PASS\n",
           cases);
}
#endif
