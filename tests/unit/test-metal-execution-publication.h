/* GPU read-completion witnesses survive event failure and delayed feedback.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_EXECUTION_PUBLICATION_H
#define TEST_METAL_EXECUTION_PUBLICATION_H
@interface MissingReadEventCommands : NV2AMetalCommands
@property(nonatomic) BOOL omitReadEvent;
@end
@implementation MissingReadEventCommands
- (BOOL)orderAfterSubmission:(NV2AMetalSubmission *)submission
                fromCommands:(NV2AMetalCommands *)source
                       error:(NSError **)error
{
    BOOL ok = [super orderAfterSubmission:submission
                             fromCommands:source
                                    error:error];
    if (ok && _omitReadEvent) {
        /* Fault injection only: leave all native GPU work and metadata intact,
         * but omit the queue dependency that a driver timeout could bypass. */
        id slot = [self valueForKey:@"current"];
        [[slot valueForKey:@"waits"] removeAllObjects];
    }
    return ok;
}
@end
static void execution_publication_tests(id<MTLDevice> device)
{
    unsigned cases = 0;
    for (unsigned empty = 0; empty < 2; empty++)
        for (unsigned download = 0; download < 2; download++)
            for (unsigned fault = 0; fault < 4; fault++) {
                @autoreleasepool {
                    NSError *error = nil;
                    MissingReadEventCommands *target =
                        [[MissingReadEventCommands alloc]
                            initWithDevice:device
                                     error:&error];
                    target.omitReadEvent = fault == 0;
                    IndependentReadCommands *source =
                        [[IndependentReadCommands alloc] initWithDevice:device
                                                                  error:&error];
                    id<MTLBuffer> ram = [device
                        newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
                    require(target && source && ram, error);
                    memset(ram.contents, 0x44, ram.length);
                    __block unsigned notifications = 0;
                    NV2AMetalSurfaceCache *cache =
                        [[NV2AMetalSurfaceCache alloc]
                            initWithCommands:target
                                        vram:ram
                                didWriteVRAM:^(NSUInteger address,
                                               NSUInteger length) {
                                  (void)address;
                                  (void)length;
                                  notifications++;
                                }
                                       error:&error];
                    require(cache != nil, error);
                    if (!fault)
                        gpu_dep_gate(source);
                    id<MTLBuffer> old = nil;
                    NV2AMetalIndependentReads *reads = nil;
                    if (empty) {
                        NV2AMetalVRAMReadSpan span = { 32764, 8 };
                        require([cache tryBeginIndependentReads:&span
                                                          count:1
                                                       commands:source
                                                          reads:&reads
                                                          error:&error] &&
                                    reads,
                                error);
                        require([cache submitIndependentReads:reads
                                                        error:&error],
                                error);
                    } else {
                        reads = gpu_dep_read(cache, source, 32764, &old);
                    }
                    IndependentReadReceipt *delayed = nil;
                    if (fault) {
                        require([source waitForSubmission:source.lastSubmitted
                                                    error:&error],
                                error);
                        delayed = [IndependentReadReceipt new];
                        delayed.nativeSubmission = source.lastSubmitted;
                        [reads setValue:delayed forKey:@"submission"];
                    }
                    if (download) {
                        NV2AMetalSurfaceConfig c = config(8, YES, 4, 1, NO);
                        NV2AMetalCachedSurface *surface =
                            [cache prepareSurfaceAtAddress:32768
                                                    config:&c
                                                     frame:0
                                                     error:&error];
                        require(surface != nil, error);
                        clear_surface(cache, surface,
                                      MTLClearColorMake(0, 1, 0, 1), 0, 0);
                        require([cache prepareGPUReadAtAddress:32768
                                                        length:4
                                                         error:&error],
                                error);
                    } else {
                        gpu_dep_write(cache, 32764,
                                      UINT64_C(0x7777777777777777));
                    }
                    NSArray *witnesses =
                        [cache valueForKey:@"pendingReadWitnesses"];
                    assert(witnesses.count == 1);
                    id<MTLBuffer> observed =
                        [witnesses[0] valueForKey:@"observed"];
                    NV2AMetalSurfaceRecording *written = cache.recording;
                    require([cache submitWithError:&error], error);
                    require([target waitForSubmission:target.lastSubmitted
                                                error:&error],
                            error);
                    require([cache collectCompletedWithError:&error], error);
                    assert(!written.completed && !notifications &&
                           written.submitted);
                    assert(download ?
                               *(uint32_t *)((uint8_t *)ram.contents + 32768) ==
                                   UINT32_C(0xff00ff00) :
                               gpu_dep_word(ram, 32764) ==
                                   UINT64_C(0x7777777777777777));
                    if (!fault) {
                        assert(
                            !source.gate.signaledValue &&
                            ![source.lastSubmitted completedWithError:NULL] &&
                            gpu_dep_word(observed, 0) == 0);
                        source.gate.signaledValue = 1;
                        require([source waitForSubmission:source.lastSubmitted
                                                    error:&error],
                                error);
                        assert(gpu_dep_word(
                                   [reads valueForKey:@"completionMarker"],
                                   0) == 1 &&
                               gpu_dep_word(observed, 0) == 0);
                    } else {
                        assert(!delayed.ready &&
                               gpu_dep_word(observed, 0) == 1);
                        if (!empty)
                            assert(gpu_dep_word(old, 0) ==
                                   UINT64_C(0x4444444444444444));
                        /* Corrupt a completed observation only; no live GPU
                         * resource is touched. Arbitrary nonzero is not ready.
                         */
                        if (fault < 3) {
                            uint64_t value = fault == 1 ? 2 : UINT64_MAX;
                            memcpy(observed.contents, &value, sizeof(value));
                        }
                        delayed.ready = YES;
                    }
                    if (fault == 3) {
                        require([cache collectCompletedWithError:&error],
                                error);
                        assert(written.completed && notifications == download);
                        require([cache discardForRestoreWithError:&error],
                                error);
                    } else {
                        assert(![cache collectCompletedWithError:&error] &&
                               error && !written.completed &&
                               !written.cancelled && !notifications);
                        NSError *failure = error;
                        assert([failure.localizedDescription
                            containsString:@"GPU readers"]);
                        assert(![cache collectCompletedWithError:&error] &&
                               error == failure);
                        for (unsigned write = 0; write < 2; write++) {
                            assert(!nv2a_metal_try_cpu_access(
                                cache.cpuAccessGuard, 32764, 8, write));
                            assert(!nv2a_metal_try_cpu_access(
                                cache.cpuAccessGuard, 60000, 4, write));
                            BOOL completed = YES;
                            assert(![cache tryIdleCPUAccessAtAddress:32764
                                                              length:8
                                                               write:write
                                                           completed:&completed
                                                               error:&error] &&
                                   error == failure);
                        }
                        assert(![cache prepareGPUReadAtAddress:60000
                                                        length:4
                                                         error:&error] &&
                               error == failure && !notifications);
                    }
                    cache = nil;
                    require([source waitUntilIdleWithError:&error] &&
                                [target waitUntilIdleWithError:&error],
                            error);
                    cases++;
                }
            }
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *target =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        IndependentReadCommands *later =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        require(target && source && later && ram, error);
        memset(ram.contents, 0x44, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        id<MTLBuffer> old = nil;
        NV2AMetalIndependentReads *a = gpu_dep_read(cache, source, 32764, &old);
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        IndependentReadReceipt *first = [IndependentReadReceipt new];
        first.nativeSubmission = source.lastSubmitted;
        [a setValue:first forKey:@"submission"];
        gpu_dep_write(cache, 32764, UINT64_C(0x7777777777777777));
        NV2AMetalSurfaceRecording *accepted = cache.recording;
        require([cache checkpointWithError:&error], error);
        id<MTLBuffer> laterBytes = nil;
        NV2AMetalIndependentReads *b =
            gpu_dep_read(cache, later, 40000, &laterBytes);
        require([later waitForSubmission:later.lastSubmitted error:&error],
                error);
        IndependentReadReceipt *second = [IndependentReadReceipt new];
        second.nativeSubmission = later.lastSubmitted;
        [b setValue:second forKey:@"submission"];
        gpu_dep_write(cache, 40000, UINT64_C(0x8888888888888888));
        NV2AMetalSurfaceRecording *cancelled = cache.recording;
        assert([[cache valueForKey:@"pendingReadWitnesses"] count] == 2);
        [cache cancel];
        assert(cancelled.cancelled &&
               [[cache valueForKey:@"pendingReadWitnesses"] count] == 1);
        require([cache submitWithError:&error] &&
                    [target waitForSubmission:target.lastSubmitted
                                        error:&error],
                error);
        first.ready = YES;
        require([cache collectCompletedWithError:&error], error);
        assert(accepted.completed && !second.ready &&
               gpu_dep_word(ram, 32764) == UINT64_C(0x7777777777777777) &&
               gpu_dep_word(ram, 40000) == UINT64_C(0x4444444444444444) &&
               gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444));
        second.ready = YES;
        require([cache collectCompletedWithError:&error], error);
        assert(gpu_dep_word(laterBytes, 0) == UINT64_C(0x4444444444444444));
        cases++;
        id<MTLBuffer> restoreBytes = nil;
        NV2AMetalIndependentReads *c =
            gpu_dep_read(cache, source, 48000, &restoreBytes);
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        IndependentReadReceipt *restore = [IndependentReadReceipt new];
        restore.nativeSubmission = source.lastSubmitted;
        [c setValue:restore forKey:@"submission"];
        gpu_dep_write(cache, 48000, UINT64_C(0x9999999999999999));
        NV2AMetalSurfaceRecording *obsolete = cache.recording;
        require([cache checkpointWithError:&error], error);
        assert([[cache valueForKey:@"pendingReadWitnesses"] count] == 1);
        require([cache discardForRestoreWithError:&error], error);
        assert(obsolete.cancelled && restore.ready &&
               ![[cache valueForKey:@"pendingReadWitnesses"] count] &&
               gpu_dep_word(ram, 48000) == UINT64_C(0x4444444444444444));
        require([cache prepareGPUReadAtAddress:48000 length:8 error:&error],
                error);
        id<MTLBuffer> resumed = gpu_dep_copy(target, ram, 48000, nil, 0);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(gpu_dep_word(resumed, 0) == UINT64_C(0x4444444444444444) &&
               gpu_dep_word(restoreBytes, 0) == UINT64_C(0x4444444444444444));
        cases++;
    }
    assert(cases == 18);
    checks += cases;
    puts("Metal execution publication:18 native copied/empty-reader "
         "direct-write/dirty-download cases;"
         "omitted event exposes zero GPU witness despite later successful "
         "source feedback;"
         "invalid witnesses withhold tokens/notifications and close all CPU "
         "guards;"
         "valid witness accepts reordered callbacks,including empty sources;"
         "accepted prefix survives cancelled witness suffix and restore drops "
         "obsolete witnesses "
         "PASS");
}
#endif
