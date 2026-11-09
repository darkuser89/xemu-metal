/* Cold surface uploads carry explicit, sticky producer-only provenance.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_UPLOAD_PREFIX_H
#define TEST_METAL_UPLOAD_PREFIX_H
@interface NV2AMetalSurfaceCache (UploadPrefixTest)
- (BOOL)download:(NSArray<NV2AMetalCachedSurface *> *)surfaces
           error:(NSError **)error;
@end
@interface UploadPrefixCommands : CPUPrefixCommands
@property(nonatomic) BOOL forcePressure;
@end
@implementation UploadPrefixCommands
- (BOOL)batchNeedsSubmit
{
    return _forcePressure || super.batchNeedsSubmit;
}
@end
static NV2AMetalSurfaceCache *up_cache(id<MTLDevice> device,
                                       UploadPrefixCommands **commands,
                                       unsigned *notifications)
{
    NSError *error = nil;
    *commands = [[UploadPrefixCommands alloc] initWithDevice:device
                                                       error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(*commands && ram, error);
    memset(ram.contents, 0x37, ram.length);
    NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
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
static NV2AMetalSurfaceConfig up_config(void)
{
    return (NV2AMetalSurfaceConfig){
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 4,
        .height = 4,
        .pitch = 16,
        .scale = 1,
        .color = YES
    };
}
static uint64_t up_generation(NV2AMetalSurfaceCache *cache)
{
    return [[cache valueForKey:@"generation"] unsignedLongLongValue];
}
static uint64_t up_readers(NV2AMetalSurfaceCache *cache, NSUInteger address)
{
    const NV2AMetalCPUAccessGuard *g = cache.cpuAccessGuard;
    return atomic_load_explicit(g->watched + 3 * g->words + address / 4096,
                                memory_order_acquire);
}
static void up_store(NV2AMetalSurfaceCache *cache, NSUInteger address,
                     uint32_t word)
{
    for (unsigned i = 0; i < 16; i++)
        memcpy((uint8_t *)cache.vram.contents + address + i * 4, &word, 4);
}
static NV2AMetalCachedSurface *up_cold(NV2AMetalSurfaceCache *cache,
                                       NSUInteger address)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = up_config();
    up_store(cache, address, UINT32_C(0xff00ff00));
    NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:address
                                                        config:&c
                                                         frame:0
                                                  forRendering:NO
                                                         error:&error];
    require(s != nil, error);
    assert(s.reservationLength == 64 && !s.needsUpload && !s.dirty);
    return s;
}
static void up_pixels(NV2AMetalCachedSurface *surface, uint32_t expected)
{
    NSError *error = nil;
    id<MTLDevice> device = surface.transfer.texture.device;
    NV2AMetalCommands *readback =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> bytes =
        [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    require(readback && bytes && [readback beginWithError:&error] &&
                [surface.transfer encodeDownloadToBuffer:bytes
                                                  offset:0
                                                 swizzle:YES
                                                    flip:NO
                                               downscale:YES
                                                commands:readback
                                                   error:&error] &&
                [readback submitWithError:&error] &&
                [readback waitUntilIdleWithError:&error],
            error);
    for (unsigned i = 0; i < 16; i++)
        assert(((const uint32_t *)bytes.contents)[i] == expected);
}
static NV2AMetalCommands *up_blocker(id<MTLDevice> device,
                                     id<MTLSharedEvent> *gate)
{
    NSError *error = nil;
    NV2AMetalCommands *blocker =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(blocker != nil, error);
    Ivar q = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(blocker, q);
    *gate = [device newSharedEvent];
    assert(queue && *gate);
    [queue waitForEvent:*gate value:1];
    id<MTLBuffer> marker =
        [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
    require(marker && [blocker beginWithError:&error] &&
                [blocker addResource:marker error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [blocker.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder fillBuffer:marker range:NSMakeRange(0, 4) value:0x5a];
    [encoder endEncoding];
    require([blocker submitWithError:&error], error);
    id<MTLSharedEvent> escape = *gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!escape.signaledValue)
                         escape.signaledValue = 2; /* Failure-only escape. */
                   });
    return blocker;
}
static void up_original_tests(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 3; mode++) {
        @autoreleasepool {
            NSError *error = nil;
            unsigned notifications = 0;
            UploadPrefixCommands *commands = nil;
            NV2AMetalSurfaceCache *cache =
                up_cache(device, &commands, &notifications);
            NV2AMetalCachedSurface *s = up_cold(cache, 8192);
            NV2AMetalSurfaceRecording *head = cache.recording;
            assert(up_readers(cache, 8192) == 1);
            require([cache checkpointWithError:&error], error);
            if (mode == 1) {
                require([cache waitForProducersOfRecording:head error:&error],
                        error);
                assert(head.producersCompleted && !head.cpuHazardsRetired &&
                       up_readers(cache, 8192) == 1);
            }
            id<MTLSharedEvent> gate = nil;
            NV2AMetalCommands *blocker = up_blocker(device, &gate);
            gpu_dep_write(cache, 24576, UINT64_C(0x123456789abcdef0));
            id<MTLBuffer> copy = encode_vram_copy(cache, 32768, 8);
            require([commands orderAfterSubmission:blocker.lastSubmitted
                                      fromCommands:blocker
                                             error:&error],
                    error);
            id<MTLTexture> raster = cpu_prefix_raster(cache);
            NV2AMetalSurfaceRecording *tail = cache.recording;
            if (mode == 1)
                require([cache checkpointWithError:&error], error);
            uint64_t before = up_generation(cache), version = 0;
            require([cache resolveCPUAccessAtAddress:8192
                                              length:64
                                               write:YES
                                               error:&error],
                    error);
            require([cache sourceVersionAtAddress:8192
                                           length:64
                                          version:&version
                                            error:&error],
                    error);
            assert(!gate.signaledValue && head.cpuHazardsRetired &&
                   head.producersCompleted && !head.completed &&
                   !tail.cpuHazardsRetired && !tail.submitted &&
                   commands.prefixCalls == 1 && !commands.fullCalls &&
                   s.needsUpload && !s.dirty && s.generation == before + 1 &&
                   version == before + 1 && up_readers(cache, 8192) == 0 &&
                   up_readers(cache, 32768) == 1 && !notifications);
            up_pixels(s, UINT32_C(0xff00ff00));
            cpu_prefix_color(raster, 0);
            unsigned prefixCalls = commands.prefixCalls, waits = commands.waits;
            require([cache resolveCPUAccessAtAddress:8192
                                              length:64
                                               write:YES
                                               error:&error],
                    error);
            assert(prefixCalls == commands.prefixCalls &&
                   waits == commands.waits && !gate.signaledValue);
            /* This second authorized pre-write advances the version once more.
             */
            version = up_generation(cache);
            assert(version == before + 2);
            up_store(cache, 8192, UINT32_C(0xff0000ff));
            up_pixels(s, UINT32_C(0xff00ff00));
            if (mode == 2) {
                require([cache discardForRestoreWithError:&error], error);
                assert(!gate.signaledValue && head.cancelled &&
                       tail.cancelled && !s.valid &&
                       !commands.hasPendingRasterPass &&
                       up_readers(cache, 32768) == 0 &&
                       gpu_dep_word(cache.vram, 24576) ==
                           UINT64_C(0x3737373737373737));
                cpu_prefix_color(raster, 0);
                NV2AMetalSurfaceConfig c = up_config();
                NV2AMetalCachedSurface *restored =
                    [cache prepareSurfaceAtAddress:8192
                                            config:&c
                                             frame:1
                                      forRendering:NO
                                             error:&error];
                require(restored && [cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
                assert(restored != s && up_readers(cache, 8192) == 0 &&
                       !notifications);
                up_pixels(restored, UINT32_C(0xff0000ff));
                gate.signaledValue = 1;
            } else {
                commands.gate =
                    gate; /* Release only at the actual required Full wait. */
                require([cache submitWithError:&error] &&
                            [cache waitForRecording:tail error:&error],
                        error);
                assert(gate.signaledValue == 1 && head.completed &&
                       tail.completed && s.needsUpload &&
                       s.generation == version &&
                       up_generation(cache) == version &&
                       up_readers(cache, 8192) == 0 &&
                       up_readers(cache, 32768) == 0 &&
                       gpu_dep_word(copy, 0) == UINT64_C(0x3737373737373737));
                cpu_prefix_color(raster, UINT32_C(0xff00ff00));
                NV2AMetalSurfaceConfig c = up_config();
                require([cache prepareSurfaceAtAddress:8192
                                                config:&c
                                                 frame:1
                                          forRendering:NO
                                                 error:&error] == s,
                        error);
                require([cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
                assert(!s.needsUpload && s.generation == version &&
                       !notifications && up_readers(cache, 8192) == 0);
                up_pixels(s, UINT32_C(0xff0000ff));
            }
            require([blocker waitUntilIdleWithError:&error], error);
            checks++;
        }
    }
}
static void up_same_surface_tail_test(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    UploadPrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache = up_cache(device, &commands, &notifications);
    NV2AMetalCachedSurface *s = up_cold(cache, 8192);
    id<MTLBuffer> old = encode_vram_copy(cache, 32768, 8);
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error], error);
    id<MTLSharedEvent> gate = nil;
    NV2AMetalCommands *blocker = up_blocker(device, &gate);
    require([cache prepareSelectedSurface:s
                       discardingContents:NO
                                    error:&error] &&
                [commands orderAfterSubmission:blocker.lastSubmitted
                                  fromCommands:blocker
                                         error:&error],
            error);
    clear_surface(cache, s, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    NV2AMetalSurfaceRecording *tail = cache.recording;
    uint64_t tailGeneration = s.generation;
    require([cache checkpointWithError:&error], error);
    uint64_t generation = up_generation(cache), version = 0;
    require([cache resolveCPUAccessAtAddress:32768
                                      length:8
                                       write:YES
                                       error:&error] &&
                [cache sourceVersionAtAddress:32768
                                       length:8
                                      version:&version
                                        error:&error],
            error);
    assert(!gate.signaledValue && commands.prefixCalls == 1 &&
           !commands.fullCalls && head.cpuHazardsRetired &&
           !tail.cpuHazardsRetired && !tail.completed && s.dirty &&
           !s.needsUpload && s.generation == tailGeneration &&
           version == generation + 1 && up_readers(cache, 8192) == 0 &&
           up_readers(cache, 32768) == 0);
    up_pixels(s, UINT32_C(0xff00ff00));
    uint64_t cpu = UINT64_C(0xabcdef0123456789);
    memcpy((uint8_t *)cache.vram.contents + 32768, &cpu, 8);
    commands.gate = gate;
    require([cache submitWithError:&error] && [cache waitForRecording:tail
                                                                error:&error],
            error);
    assert(gate.signaledValue == 1 && s.dirty &&
           s.generation == tailGeneration && !s.needsUpload &&
           gpu_dep_word(old, 0) == UINT64_C(0x3737373737373737) &&
           gpu_dep_word(cache.vram, 32768) == cpu);
    up_pixels(s, UINT32_C(0xff0000ff));
    require([cache resolveCPUAccessAtAddress:8192
                                      length:64
                                       write:NO
                                       error:&error],
            error);
    assert(!s.dirty && notifications == 1 &&
           (uint32_t)gpu_dep_word(cache.vram, 8192) == UINT32_C(0xff0000ff));
    uint64_t after = 0;
    require([cache sourceVersionAtAddress:32768
                                   length:8
                                  version:&after
                                    error:&error],
            error);
    assert(after == version);
    require([blocker waitUntilIdleWithError:&error], error);
    checks++;
}
/* A write to the Surface's own original bytes has a different contract from
 * the disjoint raw source above: preserve the dirty raster through a download
 * before the CPU is allowed to overwrite those bytes. */
static void up_dirty_original_test(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    UploadPrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache = up_cache(device, &commands, &notifications);
    NV2AMetalCachedSurface *s = up_cold(cache, 8192);
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error], error);
    id<MTLSharedEvent> gate = nil;
    NV2AMetalCommands *blocker = up_blocker(device, &gate);
    require([cache prepareSelectedSurface:s
                       discardingContents:NO
                                    error:&error] &&
                [commands orderAfterSubmission:blocker.lastSubmitted
                                  fromCommands:blocker
                                         error:&error],
            error);
    clear_surface(cache, s, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    NV2AMetalSurfaceRecording *tail = cache.recording;
    require([cache checkpointWithError:&error], error);
    uint64_t generation = up_generation(cache), version = 0;
    commands.gate = gate;
    require([cache resolveCPUAccessAtAddress:8192
                                      length:64
                                       write:YES
                                       error:&error] &&
                [cache sourceVersionAtAddress:8192
                                       length:64
                                      version:&version
                                        error:&error],
            error);
    assert(gate.signaledValue == 1 && commands.fullCalls == 1 &&
           !commands.prefixCalls && head.completed && tail.completed &&
           !s.dirty && s.needsUpload && s.generation == generation + 1 &&
           version == generation + 1 && notifications == 1 &&
           up_readers(cache, 8192) == 0);
    for (unsigned i = 0; i < 16; i++)
        assert(((const uint32_t *)cache.vram.contents)[8192 / 4 + i] ==
               UINT32_C(0xff0000ff));
    up_store(cache, 8192, UINT32_C(0xff00ff00));
    up_pixels(s, UINT32_C(0xff0000ff));
    NV2AMetalSurfaceConfig c = up_config();
    require([cache prepareSurfaceAtAddress:8192
                                    config:&c
                                     frame:1
                              forRendering:NO
                                     error:&error] == s &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    up_pixels(s, UINT32_C(0xff00ff00));
    assert(!s.needsUpload && s.generation == version &&
           up_generation(cache) == version && notifications == 1);
    require([blocker waitUntilIdleWithError:&error], error);
    checks++;
}
static void up_upgrade_tests(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 6; mode++) {
        NSError *error = nil;
        unsigned notifications = 0;
        UploadPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            up_cache(device, &commands, &notifications);
        NV2AMetalSurfaceConfig c = up_config();
        NV2AMetalCachedSurface *dirty = nil;
        if (mode == 5) {
            dirty = [cache prepareSurfaceAtAddress:4096
                                            config:&c
                                             frame:0
                                             error:&error];
            require(dirty != nil, error);
            clear_surface(cache, dirty, MTLClearColorMake(0, 0, 1, 1), 0, 0);
            require([cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            commands.fullCalls = 0;
            commands.waits = 0;
            commands.idleWaits = 0;
        }
        NV2AMetalCachedSurface *s = up_cold(cache, 8192);
        NV2AMetalSurfaceRecording *token = cache.recording;
        if (mode == 0)
            require([cache prepareSelectedSurface:s
                               discardingContents:NO
                                            error:&error],
                    error);
        else if (mode == 1) {
            require([cache beginRasterProducersWithError:&error], error);
            MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
            p.colorAttachments[0].texture = s.transfer.texture;
            p.colorAttachments[0].loadAction = MTLLoadActionLoad;
            p.colorAttachments[0].storeAction = MTLStoreActionStore;
            require([cache prepareRasterPass:p targets:@[ s ] error:&error],
                    error);
            [cache endRasterProducers];
        } else if (mode == 2)
            require([cache markRTTSampling:s error:&error], error);
        else if (mode < 5) {
            require([cache markWritten:s
                        replacingContents:mode == 4
                                    error:&error],
                    error);
        } else
            require([cache download:@[ dirty ] error:&error], error);
        /* Another genuine pure upload must never erase an earlier upgrade. */
        NV2AMetalCachedSurface *other = up_cold(cache, 16384);
        assert(cache.recording == token);
        commands.rejectFull = YES;
        if (mode == 5) {
            /* A disjoint download is itself producer-only. Its exact ledger
             * may retire together with both uploads, without a full submit. */
            uint64_t generation = up_generation(cache);
            uint64_t dirtyGeneration = dirty.generation;
            uint64_t otherGeneration = other.generation;
            require([cache resolveCPUAccessAtAddress:8192
                                              length:64
                                               write:YES
                                               error:&error],
                    error);
            for (unsigned i = 0; i < 16; i++)
                assert(((const uint32_t *)cache.vram.contents)[4096 / 4 + i] ==
                       UINT32_C(0xff0000ff));
            up_pixels(s, UINT32_C(0xff00ff00));
            up_pixels(other, UINT32_C(0xff00ff00));
            assert(token.producersCompleted && token.cpuHazardsRetired &&
                   !token.completed && !token.submitted && !token.cancelled &&
                   cache.recording != token && !commands.fullCalls &&
                   !commands.rejectedFullCalls && commands.rejectFull &&
                   commands.prefixCalls == 1 && commands.lastCut == 1 &&
                   up_readers(cache, 8192) == 0 && up_readers(cache, 16384) == 0 &&
                   notifications == 1 && !dirty.dirty &&
                   dirty.generation == dirtyGeneration && s.needsUpload &&
                   !s.dirty && s.generation == generation + 1 &&
                   !other.needsUpload && !other.dirty &&
                   other.generation == otherGeneration &&
                   up_generation(cache) == generation + 1);
            uint64_t version = 0;
            require([cache sourceVersionAtAddress:4096
                                           length:64
                                          version:&version
                                            error:&error],
                    error);
            assert(version == dirtyGeneration);
            require([cache sourceVersionAtAddress:8192
                                           length:64
                                          version:&version
                                            error:&error],
                    error);
            assert(version == generation + 1);
            /* A pre-write callback permits the real store. Cancelling a new
             * suffix cannot discard these already accepted GPU uploads. */
            up_store(cache, 8192, UINT32_C(0xffff0000));
            id<MTLBuffer> cancelledCopy = encode_vram_copy(cache, 24576, 8);
            memset(cancelledCopy.contents, 0xcd, 8);
            NV2AMetalSurfaceRecording *cancelled = cache.recording;
            assert(cancelled && cancelled != token &&
                   up_readers(cache, 24576) == 1);
            [cache cancel];
            up_pixels(s, UINT32_C(0xff00ff00));
            assert(cancelled.cancelled && !token.cancelled && !token.completed &&
                   up_readers(cache, 24576) == 0 && s.needsUpload &&
                   s.generation == generation + 1 && !dirty.dirty &&
                   notifications == 1);
            commands.rejectFull = NO;
            require([cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            for (unsigned i = 0; i < 16; i++) {
                assert(((const uint32_t *)cache.vram.contents)[4096 / 4 + i] ==
                       UINT32_C(0xff0000ff));
                assert(((const uint32_t *)cache.vram.contents)[8192 / 4 + i] ==
                       UINT32_C(0xffff0000));
            }
            up_pixels(s, UINT32_C(0xff00ff00));
            assert(gpu_dep_word(cancelledCopy, 0) == UINT64_C(0xcdcdcdcdcdcdcdcd));
            assert(token.completed && token.submitted && !token.cancelled &&
                   token.producersCompleted && token.cpuHazardsRetired &&
                   !cache.recording && s.needsUpload && !s.dirty &&
                   s.generation == generation + 1 && !other.needsUpload &&
                   other.generation == otherGeneration && !dirty.dirty &&
                   dirty.generation == dirtyGeneration && notifications == 1 &&
                   up_generation(cache) == generation + 1 &&
                   up_readers(cache, 8192) == 0 && up_readers(cache, 16384) == 0 &&
                   commands.fullCalls == 1 && commands.prefixCalls == 1 &&
                   !commands.rejectedFullCalls);
            checks++;
            continue;
        }

        assert(![cache resolveCPUAccessAtAddress:8192
                                          length:64
                                           write:YES
                                           error:&error] &&
               [error.domain isEqualToString:@"test.cpu-prefix.full-submit"] &&
               cache.recording == token && !token.submitted &&
               !token.completed && !token.cpuHazardsRetired &&
               !commands.prefixCalls && commands.rejectedFullCalls == 1 &&
               up_readers(cache, 8192) == 1 && up_readers(cache, 16384) == 1);
        [cache cancel];
        assert(token.cancelled && !cache.recording && s.needsUpload &&
               other.needsUpload && !s.dirty && up_readers(cache, 8192) == 0 &&
               up_readers(cache, 16384) == 0 && !notifications);
        if (dirty)
            assert(dirty.dirty);
        require([cache prepareSurfaceAtAddress:8192
                                        config:&c
                                         frame:1
                                  forRendering:NO
                                         error:&error] == s,
                error);
        NV2AMetalSurfaceRecording *retry = cache.recording;
        uint64_t generation = up_generation(cache);
        require([cache resolveCPUAccessAtAddress:8192
                                          length:64
                                           write:YES
                                           error:&error],
                error);
        assert(retry.cpuHazardsRetired && !retry.completed && !s.dirty &&
               s.needsUpload && s.generation == generation + 1 &&
               commands.prefixCalls == 1);
        up_pixels(s, UINT32_C(0xff00ff00));
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(s.needsUpload && s.generation == generation + 1 &&
               !notifications);
        checks++;
    }
}
static void up_pressure_failure_tests(id<MTLDevice> device)
{
    for (unsigned gpuFailure = 0; gpuFailure < 2; gpuFailure++) {
        NSError *error = nil;
        unsigned notifications = 0;
        UploadPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            up_cache(device, &commands, &notifications);
        NV2AMetalCachedSurface *s = up_cold(cache, 8192);
        NV2AMetalSurfaceRecording *head = cache.recording;
        uint64_t generation = up_generation(cache);
        if (gpuFailure)
            commands.prefixFailure =
                [NSError errorWithDomain:@"test.upload-prefix.gpu"
                                    code:1
                                userInfo:nil];
        else {
            commands.forcePressure = YES;
            commands.rejectFull = YES;
        }
        assert(![cache resolveCPUAccessAtAddress:8192
                                          length:64
                                           write:YES
                                           error:&error] &&
               error && !head.cpuHazardsRetired && !head.completed &&
               up_readers(cache, 8192) == 1 && s.generation == generation &&
               !notifications &&
               (uint32_t)gpu_dep_word(cache.vram, 8192) ==
                   UINT32_C(0xff00ff00));
        if (gpuFailure) {
            assert(error == commands.prefixFailure &&
                   commands.prefixCalls == 1);
            NV2AMetalSubmission *native =
                commands.injectedReceipt.nativeSubmission;
            [commands cancel];
            require([commands waitForSubmission:native error:&error] &&
                        [commands waitUntilIdleWithError:&error],
                    error);
            assert(up_readers(cache, 8192) == 1 && !head.cpuHazardsRetired &&
                   s.generation == generation);
        } else {
            assert(cache.recording == head && commands.commandBuffer &&
                   !commands.sealedBufferCount &&
                   commands.rejectedFullCalls == 1);
            [cache cancel];
            commands.forcePressure = NO;
            assert(head.cancelled && s.needsUpload &&
                   up_readers(cache, 8192) == 0);
            NV2AMetalSurfaceConfig c = up_config();
            require([cache prepareSurfaceAtAddress:8192
                                            config:&c
                                             frame:1
                                      forRendering:NO
                                             error:&error] == s &&
                        [cache resolveCPUAccessAtAddress:8192
                                                  length:64
                                                   write:YES
                                                   error:&error],
                    error);
            assert(s.needsUpload && s.generation == generation + 1 &&
                   up_readers(cache, 8192) == 0);
            up_pixels(s, UINT32_C(0xff00ff00));
            require([cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
        }
        checks++;
    }
}
static void upload_prefix_tests(id<MTLDevice> device)
{
    unsigned before = checks;
    up_original_tests(device);
    up_same_surface_tail_test(device);
    up_dirty_original_test(device);
    up_upgrade_tests(device);
    up_pressure_failure_tests(device);
    printf("Upload prefixes: %u groups PASS; real cold upload/source bytes, "
           "Gate0 raster tail, same-Surface metadata, "
           "GPU Green then fresh Blue, sticky "
           "upgrades/rollback/retry/Restore/pressure, exact generations and "
           "one-time reader retirement, failure retains guards\n",
           checks - before);
}
#endif
