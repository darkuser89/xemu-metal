/* Download heads publish their exact producer scope once, before a disjoint
 * raster tail. SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DOWNLOAD_PREFIX_H
#define TEST_METAL_DOWNLOAD_PREFIX_H
@interface NV2AMetalSurfaceCache (DownloadPrefixTest)
- (BOOL)canOwnDownloadPrefix:(NV2AMetalSurfaceRecording *)recording;
@end
@interface DownloadPrefixCache : NV2AMetalSurfaceCache
@property(nonatomic) BOOL forceFull;
@end
@implementation DownloadPrefixCache
- (BOOL)canOwnDownloadPrefix:(NV2AMetalSurfaceRecording *)recording
{
    return !_forceFull && [super canOwnDownloadPrefix:recording];
}
@end
@interface DownloadPrefixCommands : CPUPrefixCommands
@property(nonatomic) id<MTLSharedEvent> releaseGate;
@property(nonatomic) BOOL releaseOnWait, forcePressure;
@property(nonatomic) unsigned gateReleases;
@end
@implementation DownloadPrefixCommands
- (BOOL)batchNeedsSubmit
{
    return _forcePressure || super.batchNeedsSubmit;
}
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    if (_releaseOnWait && _releaseGate && !_releaseGate.signaledValue) {
        _gateReleases++;
        _releaseGate.signaledValue = 1;
    }
    return [super waitForSubmission:submission error:error];
}
@end
static unsigned dp_checks;
static DownloadPrefixCache *dp_cache(id<MTLDevice> device,
                                     DownloadPrefixCommands **commands,
                                     unsigned *notifications)
{
    NSError *error = nil;
    *commands = [[DownloadPrefixCommands alloc] initWithDevice:device
                                                         error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(*commands && ram, error);
    memset(ram.contents, 0x37, ram.length);
    DownloadPrefixCache *cache = [[DownloadPrefixCache alloc]
        initWithCommands:*commands
                    vram:ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address < 65536 && length && length <= 65536 - address);
              (*notifications)++;
            }
                   error:&error];
    require(cache != nil, error);
    return cache;
}
static NV2AMetalCachedSurface *dp_source(NV2AMetalSurfaceCache *cache,
                                         NSUInteger address)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = up_config();
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:address
                                                              config:&c
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    assert((uint32_t)gpu_dep_word(cache.vram, address) == 0x37373737 &&
           surface.dirty);
    return surface;
}
static id<MTLBuffer> dp_head(NV2AMetalSurfaceCache *cache, NSUInteger address,
                             NV2AMetalSurfaceRecording **head)
{
    NSError *error = nil;
    require([cache prepareGPUReadAtAddress:address length:64 error:&error],
            error);
    id<MTLBuffer> snapshot = encode_vram_copy(cache, address, 8);
    *head = cache.recording;
    require([cache checkpointWithError:&error], error);
    return snapshot;
}
static IndependentReadCommands *dp_tail(NV2AMetalSurfaceCache *cache,
                                        NSUInteger address,
                                        id<MTLBuffer> *readback,
                                        id<MTLTexture> *raster,
                                        NV2AMetalSurfaceRecording **tail)
{
    NSError *error = nil;
    IndependentReadCommands *late =
        [[IndependentReadCommands alloc] initWithDevice:cache.commands.device
                                                  error:&error];
    require(late != nil, error);
    gpu_dep_gate(late);
    (void)gpu_dep_read(cache, late, 57344, readback);
    gpu_dep_write(cache, address, UINT64_C(0xfedcba9876543210));
    require([cache.commands orderAfterSubmission:late.lastSubmitted
                                    fromCommands:late
                                           error:&error],
            error);
    *raster = cpu_prefix_raster(cache);
    *tail = cache.recording;
    require([cache checkpointWithError:&error], error);
    return late;
}
static NSData *dp_pair(id<MTLDevice> device, BOOL reference, BOOL write,
                       BOOL samePage)
{
    NSError *error = nil;
    unsigned notifications = 0;
    DownloadPrefixCommands *commands = nil;
    DownloadPrefixCache *cache = dp_cache(device, &commands, &notifications);
    const NSUInteger source = 16384,
                     destination = samePage ? source + 128 : 24576;
    NV2AMetalCachedSurface *surface = dp_source(cache, source);
    cache.forceFull = reference;
    commands.fullCalls = commands.prefixCalls = 0;
    NV2AMetalSurfaceRecording *head = nil, *tail = nil;
    id<MTLBuffer> snapshot = dp_head(cache, source, &head), lateBytes = nil;
    id<MTLTexture> raster = nil;
    IndependentReadCommands *late =
        dp_tail(cache, destination, &lateBytes, &raster, &tail);
    commands.releaseGate = late.gate;
    commands.releaseOnWait = reference;
    uint64_t generation = up_generation(cache);
    require([cache resolveCPUAccessAtAddress:source
                                      length:4
                                       write:write
                                       error:&error],
            error);
    // Completed real GPU download/copy bytes precede metadata or counter tests.
    assert((uint32_t)gpu_dep_word(cache.vram, source) == 0xff00ff00 &&
           gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
    if (!reference) {
        assert(gpu_dep_word(cache.vram, destination) ==
               UINT64_C(0x3737373737373737));
        cpu_prefix_color(raster, 0);
    }
    assert(notifications == 1 && head.producersCompleted &&
           (reference ?
                head.completed && commands.fullCalls == 1 &&
                    !commands.prefixCalls && late.gate.signaledValue == 1 :
                head.cpuHazardsRetired && !head.completed && !tail.submitted &&
                    !tail.completed && commands.prefixCalls == 1 &&
                    !commands.fullCalls && !late.gate.signaledValue));
    assert(up_generation(cache) == generation + write);
    if (write)
        up_store(cache, source, 0xff0000ff);
    uint64_t afterCPU = up_generation(cache);
    if (!late.gate.signaledValue)
        late.gate.signaledValue = 1;
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    cpu_prefix_color(raster, 0xff00ff00);
    assert(gpu_dep_word(cache.vram, destination) ==
               UINT64_C(0xfedcba9876543210) &&
           gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
    assert(head.completed && tail.completed && notifications == 1 &&
           up_generation(cache) == afterCPU);
    if (write) {
        NV2AMetalSurfaceConfig c = up_config();
        require([cache prepareSurfaceAtAddress:source
                                        config:&c
                                         frame:1
                                  forRendering:NO
                                         error:&error] == surface,
                error);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        up_pixels(surface, 0xff0000ff);
        assert(gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00) &&
               notifications == 1);
    }
    return [NSData dataWithBytes:cache.vram.contents length:cache.vram.length];
}

/* The old Head can finish after a full transfer and after a new batch has
 * encoded another download. Only that new download's receipt can expose RAM. */
static void dp_batch_boundary(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    DownloadPrefixCommands *commands = nil;
    DownloadPrefixCache *cache = dp_cache(device, &commands, &notifications);
    (void)dp_source(cache, 16384);
    (void)dp_source(cache, 8192);
    IndependentReadCommands *early =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    require(early != nil, error);
    gpu_dep_gate(early);
    id<MTLBuffer> oldRead = nil;
    (void)gpu_dep_read(cache, early, 49152, &oldRead);
    require([cache beginRecordingWithError:&error] &&
                [commands orderAfterSubmission:early.lastSubmitted
                                  fromCommands:early
                                         error:&error],
            error);
    NV2AMetalSurfaceRecording *head = nil, *tail = nil;
    id<MTLBuffer> snapshot = dp_head(cache, 16384, &head);
    id entry = [cache submitProducerPrefix:head error:&error];
    require(entry != nil, error);
    NV2AMetalSubmission *receipt = [entry valueForKey:@"submission"];
    id<MTLBuffer> lateBytes = nil;
    id<MTLTexture> raster = nil;
    IndependentReadCommands *late =
        dp_tail(cache, 24576, &lateBytes, &raster, &tail);
    require([cache submitWithError:&error], error);
    require([cache prepareGPUReadAtAddress:8192 length:64 error:&error], error);
    NV2AMetalSurfaceRecording *fresh = cache.recording;
    early.gate.signaledValue = 1;
    require([cache waitForSubmission:receipt error:&error], error);
    assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0xff00ff00 &&
           (uint32_t)gpu_dep_word(cache.vram, 8192) == 0x37373737 &&
           gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
    commands.releaseGate = late.gate;
    commands.releaseOnWait = YES;
    require([cache resolveCPUAccessAtAddress:8192
                                      length:4
                                       write:NO
                                       error:&error],
            error);
    // A stale old-batch cursor would return the untouched 0x37 RAM bytes.
    assert((uint32_t)gpu_dep_word(cache.vram, 8192) == 0xff00ff00);
    assert(fresh.cpuHazardsRetired && notifications == 2 &&
           late.gate.signaledValue == 1 && commands.gateReleases == 1);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    assert(notifications == 2 && head.completed && tail.completed &&
           fresh.completed);
    dp_checks++;
}

static void dp_cancel_restore(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    DownloadPrefixCommands *commands = nil;
    DownloadPrefixCache *cache = dp_cache(device, &commands, &notifications);
    (void)dp_source(cache, 16384);
    NV2AMetalSurfaceRecording *head = nil, *tail = nil;
    id<MTLBuffer> snapshot = dp_head(cache, 16384, &head), lateBytes = nil;
    id<MTLTexture> raster = nil;
    IndependentReadCommands *late =
        dp_tail(cache, 24576, &lateBytes, &raster, &tail);
    require([cache resolveCPUAccessAtAddress:16384
                                      length:4
                                       write:YES
                                       error:&error],
            error);
    assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0xff00ff00 &&
           gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
    up_store(cache, 16384, 0xff0000ff);
    assert(!late.gate.signaledValue && notifications == 1);
    late.gate.signaledValue = 1; // Restore must drain the independent reader.
    require([cache discardForRestoreWithError:&error], error);
    assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0xff0000ff &&
           gpu_dep_word(cache.vram, 24576) == UINT64_C(0x3737373737373737) &&
           gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
    cpu_prefix_color(raster, 0);
    assert(tail.cancelled && notifications == 1);
    NV2AMetalSurfaceConfig c = up_config();
    NV2AMetalCachedSurface *retry = [cache prepareSurfaceAtAddress:16384
                                                            config:&c
                                                             frame:2
                                                      forRendering:NO
                                                             error:&error];
    require(retry && [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    up_pixels(retry, 0xff0000ff);
    assert(notifications == 1);
    dp_checks++;
}

static void dp_fallbacks(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 4; mode++) {
        NSError *error = nil;
        unsigned notifications = 0;
        DownloadPrefixCommands *commands = nil;
        DownloadPrefixCache *cache =
            dp_cache(device, &commands, &notifications);
        NV2AMetalCachedSurface *surface = dp_source(cache, 16384);
        commands.fullCalls = commands.prefixCalls = 0;
        NV2AMetalSurfaceRecording *head = nil;
        id<MTLBuffer> snapshot = dp_head(cache, 16384, &head);
        uint32_t expected = 0xff00ff00;
        if (mode == 0)
            require([cache markRTTSampling:surface error:&error], error);
        else if (mode == 1) {
            require([cache prepareSelectedSurface:surface
                               discardingContents:NO
                                            error:&error],
                    error);
            clear_surface(cache, surface, MTLClearColorMake(0, 0, 1, 1), 0, 0);
            expected = 0xff0000ff;
        } else if (mode == 2) {
            NV2AMetalSurfaceConfig c = up_config();
            NV2AMetalCachedSurface *alias =
                [cache prepareSurfaceAtAddress:16400
                                        config:&c
                                         frame:1
                                         error:&error];
            require(alias != nil, error);
        } else {
            require([cache prepareGPUBlitFrom:NSMakeRange(32768, 64)
                                           to:NSMakeRange(16384, 64)
                             replacingSurface:^BOOL(NV2AMetalCachedSurface *s) {
                               return s == surface;
                             }
                                        error:&error],
                    error);
            id<MTLBuffer> blue =
                [device newBufferWithLength:64
                                    options:MTLResourceStorageModeShared];
            require(blue != nil, nil);
            for (unsigned i = 0; i < 16; i++)
                ((uint32_t *)blue.contents)[i] = 0xff0000ff;
            for (unsigned i = 0; i < 8; i++)
                gpu_dep_copy(commands, blue, i * 8, cache.vram, 16384 + i * 8);
            expected = 0xff0000ff;
        }
        require([cache resolveCPUAccessAtAddress:16384
                                          length:4
                                           write:NO
                                           error:&error],
                error);
        assert((uint32_t)gpu_dep_word(cache.vram, 16384) == expected &&
               gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
        assert(!commands.prefixCalls && commands.fullCalls &&
               notifications == (mode == 1 ? 2u : 1u));
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        dp_checks++;
    }
}

static void dp_failed_submit(id<MTLDevice> device)
{
    for (unsigned full = 0; full < 2; full++) {
        NSError *error = nil;
        unsigned notifications = 0;
        DownloadPrefixCommands *commands = nil;
        DownloadPrefixCache *cache =
            dp_cache(device, &commands, &notifications);
        NV2AMetalCachedSurface *surface = dp_source(cache, 16384);
        NV2AMetalSurfaceRecording *head = nil;
        id<MTLBuffer> snapshot = dp_head(cache, 16384, &head);
        if (full) {
            require([cache markRTTSampling:surface error:&error], error);
            gpu_dep_write(cache, 24576, 456);
            commands.rejectFull = YES;
        } else
            commands.rejectPrefix = YES;
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:4
                                           write:NO
                                           error:&error] &&
               error);
        assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0x37373737 &&
               !notifications);
        if (full) {
            NV2AMetalSurfaceRecording *cancelled = cache.recording;
            assert(cancelled && !cancelled.cancelled);
            [cache cancel];
            assert(cancelled.cancelled && !head.cancelled);
        }
        error = nil;
        require([cache resolveCPUAccessAtAddress:16384
                                          length:4
                                           write:NO
                                           error:&error],
                error);
        assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0xff00ff00 &&
               gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(notifications == 1 &&
               gpu_dep_word(cache.vram, 24576) == UINT64_C(0x3737373737373737));
        dp_checks++;
    }
}

static void dp_feedback_errors(id<MTLDevice> device)
{
    for (unsigned readerError = 0; readerError < 2; readerError++) {
        NSError *error = nil;
        unsigned notifications = 0;
        DownloadPrefixCommands *commands = nil;
        DownloadPrefixCache *cache =
            dp_cache(device, &commands, &notifications);
        NV2AMetalCachedSurface *surface = dp_source(cache, 16384);
        IndependentReadCommands *source = nil;
        CountedIndependentReadReceipt *readerReceipt = nil;
        if (readerError) {
            require([cache prepareCPUAccessAtAddress:16384
                                              length:64
                                               write:NO
                                               error:&error],
                    error);
            source = [[IndependentReadCommands alloc] initWithDevice:device
                                                               error:&error];
            require(source != nil, error);
            id<MTLBuffer> copy = nil;
            NV2AMetalIndependentReads *reader =
                gpu_dep_read(cache, source, 16384, &copy);
            readerReceipt = [CountedIndependentReadReceipt new];
            readerReceipt.nativeSubmission = source.lastSubmitted;
            readerReceipt.waitForNativeFeedback = YES;
            [reader setValue:readerReceipt forKey:@"submission"];
            require([cache prepareSelectedSurface:surface
                               discardingContents:NO
                                            error:&error],
                    error);
            clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
            require([cache submitWithError:&error] &&
                        [commands waitForSubmission:commands.lastSubmitted
                                              error:&error],
                    error);
            notifications = 0;
        }
        NV2AMetalSurfaceRecording *head = nil;
        id<MTLBuffer> snapshot = dp_head(cache, 16384, &head);
        NSError *failure = [NSError errorWithDomain:@"test.download-prefix.head"
                                               code:1
                                           userInfo:nil];
        commands.prefixFailure = failure;
        if (readerError)
            readerReceipt.failure =
                [NSError errorWithDomain:@"test.download-prefix.reader-first"
                                    code:2
                                userInfo:nil];
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:4
                                           write:YES
                                           error:&error] &&
               error == (readerError ? readerReceipt.failure : failure));
        assert(!notifications && !head.cpuHazardsRetired && !head.completed &&
               (!readerError || !commands.injectedReceipt.polls));
        // Finish only native work for resource lifetime, preserving the
        // injected error.
        NV2AMetalSubmission *native = commands.injectedReceipt.nativeSubmission;
        [commands cancel];
        require(native && [commands waitForSubmission:native error:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        assert(gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
        dp_checks++;
    }
}
static void dp_pressure(id<MTLDevice> device)
{
    for (unsigned failure = 0; failure < 2; failure++) {
        NSError *error = nil;
        unsigned notifications = 0;
        DownloadPrefixCommands *commands = nil;
        DownloadPrefixCache *cache =
            dp_cache(device, &commands, &notifications);
        (void)dp_source(cache, 16384);
        commands.fullCalls = commands.prefixCalls = 0;
        require([cache prepareGPUReadAtAddress:16384 length:64 error:&error],
                error);
        id<MTLBuffer> snapshot = encode_vram_copy(cache, 16384, 8);
        NV2AMetalSurfaceRecording *head = cache.recording;
        commands.forcePressure = YES;
        commands.rejectFull = failure;
        if (failure) {
            assert(![cache resolveCPUAccessAtAddress:16384
                                              length:4
                                               write:NO
                                               error:&error] &&
                   error);
            assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0x37373737 &&
                   !gpu_dep_word(snapshot, 0));
            assert(cache.recording == head && !head.cancelled &&
                   !commands.sealedBufferCount && !notifications);
            [cache cancel];
            assert(head.cancelled);
            commands.forcePressure = NO;
            error = nil;
            require([cache resolveCPUAccessAtAddress:16384
                                              length:4
                                               write:NO
                                               error:&error],
                    error);
            assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0xff00ff00 &&
                   !gpu_dep_word(snapshot, 0));
        } else {
            require([cache resolveCPUAccessAtAddress:16384
                                              length:4
                                               write:NO
                                               error:&error],
                    error);
            assert((uint32_t)gpu_dep_word(cache.vram, 16384) == 0xff00ff00 &&
                   gpu_dep_word(snapshot, 0) == UINT64_C(0xff00ff00ff00ff00));
            assert(head.completed && commands.fullCalls == 1 &&
                   !commands.prefixCalls);
        }
        commands.forcePressure = NO;
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(notifications == 1);
        dp_checks++;
    }
}
static void download_prefix_tests(id<MTLDevice> device)
{
    dp_checks = 0;
    for (unsigned write = 0; write < 2; write++)
        for (unsigned samePage = 0; samePage < 2; samePage++) {
            NSData *reference = dp_pair(device, YES, write, samePage);
            NSData *actual = dp_pair(device, NO, write, samePage);
            assert([actual isEqualToData:reference]);
            dp_checks++;
        }
    dp_batch_boundary(device);
    dp_cancel_restore(device);
    dp_fallbacks(device);
    dp_failed_submit(device);
    dp_feedback_errors(device);
    dp_pressure(device);
    assert(dp_checks == 16);
    printf("Download producer prefixes: %u exact RAM/GPU scopes; gated raster "
           "tails, Full reference, callbacks/versions once, same-page/alias "
           "fallback, pending Head across Full/new batch, cancel/retry/Restore "
           "and injected feedback error priority PASS\n",
           dp_checks);
}
#endif
