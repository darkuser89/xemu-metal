/* Unsubmitted producer prefixes retain Surface/raster/tail ownership.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SURFACE_PRODUCER_PREFIX_H
#define TEST_METAL_SURFACE_PRODUCER_PREFIX_H
@interface NV2AMetalSurfaceCache (ProducerPrefixTest)
- (id)submitProducerPrefix:(NV2AMetalSurfaceRecording *)recording
                     error:(NSError **)error;
@end
@interface SurfacePrefixCommands : IndependentReadCommands
@property(nonatomic) unsigned prefixCalls, fullCalls, guardedDrains;
@property(nonatomic) NSError *prefixFailure;
@property(nonatomic) CountedIndependentReadReceipt *injectedReceipt;
@property(nonatomic) id<MTLSharedEvent> drainGate;
@property(nonatomic, weak) NV2AMetalSurfaceCache *drainCache;
@property(nonatomic) NSUInteger drainAddress;
@end
@implementation SurfacePrefixCommands
- (NV2AMetalSubmission *)submitProducersThroughSectionCount:(NSUInteger)count
                                                batchSerial:(uint64_t)serial
                                                      error:(NSError **)error
{
    _prefixCalls++;
    NV2AMetalSubmission *receipt =
        [super submitProducersThroughSectionCount:count
                                      batchSerial:serial
                                            error:error];
    if (receipt && _prefixFailure) {
        _injectedReceipt = [CountedIndependentReadReceipt new];
        _injectedReceipt.nativeSubmission = receipt;
        _injectedReceipt.failure = _prefixFailure;
        return (id)_injectedReceipt;
    }
    return receipt;
}
- (BOOL)submitWithError:(NSError **)error
{
    _fullCalls++;
    return [super submitWithError:error];
}
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)receipt error:(NSError **)error
{
    if (_drainGate && !_drainGate.signaledValue) {
        assert(_drainCache &&
               !nv2a_metal_try_cpu_access(_drainCache.cpuAccessGuard,
                                          _drainAddress, 8, YES));
        _guardedDrains++;
        _drainGate.signaledValue = 1;
    }
    return [super waitForSubmission:receipt error:error];
}
@end
static NV2AMetalSurfaceCache *
surface_prefix_cache(id<MTLDevice> device, SurfacePrefixCommands **commands,
                     unsigned *notifications)
{
    NSError *error = nil;
    *commands = [[SurfacePrefixCommands alloc] initWithDevice:device
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
static NV2AMetalIndependentReads *
surface_prefix_reader(NV2AMetalSurfaceCache *cache,
                      IndependentReadCommands *commands, NSUInteger address,
                      id<MTLBuffer> *bytes)
{
    NV2AMetalIndependentReads *reader =
        gpu_dep_read(cache, commands, address, bytes);
    /* Keep native execution ordering, but delay its feedback observation to
     * force the writer's real GPU marker copy even on an idle fast GPU. */
    [reader setValue:reader_delayed_feedback(commands) forKey:@"submission"];
    return reader;
}
static void surface_prefix_scope_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    SurfacePrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache =
        surface_prefix_cache(device, &commands, &notifications);
    IndependentReadCommands *early =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    IndependentReadCommands *late =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    require(early && late, error);
    id<MTLBuffer> earlyBytes = nil;
    NV2AMetalIndependentReads *first =
        surface_prefix_reader(cache, early, 16384, &earlyBytes);
    gpu_dep_write(cache, 16384, UINT64_C(0x1122334455667788));
    id<MTLBuffer> sourceCopy = encode_vram_copy(cache, 49152, 8);
    NV2AMetalSurfaceConfig cfg =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:8192
                                                              config:&cfg
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    require([cache prepareGPUReadAtAddress:8192 length:4 error:&error], error);
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error], error);
    NSArray *headWitnesses = [[cache valueForKey:@"pendingReadWitnesses"] copy];
    assert(headWitnesses.count == 1);
    id<MTLBuffer> markerPage = [headWitnesses[0] valueForKey:@"observed"];
    NSUInteger offset =
        [[headWitnesses[0] valueForKey:@"observedOffset"] unsignedIntegerValue];
    gpu_dep_gate(late);
    id<MTLBuffer> lateBytes = nil;
    NV2AMetalIndependentReads *tailReader =
        surface_prefix_reader(cache, late, 24576, &lateBytes);
    require([cache prepareGPUReadAtAddress:57344 length:8 error:&error], error);
    gpu_dep_write(cache, 24576, UINT64_C(0x8877665544332211));
    NV2AMetalSurfaceRecording *tail = cache.recording;
    require([cache checkpointWithError:&error], error);
    unsigned lateWaits = late.waits;
    require([cache waitForProducersOfRecording:head error:&error], error);
    assert(
        commands.prefixCalls == 1 && !commands.fullCalls &&
        !late.gate.signaledValue && late.waits == lateWaits &&
        head.producersCompleted && !head.submitted && !head.completed &&
        !tail.submitted && !tail.producersCompleted && !notifications &&
        surface.valid && [[cache valueForKey:@"pendingDownloads"] count] == 1 &&
        ![[cache valueForKey:@"submittedDownloadCount"] unsignedIntegerValue] &&
        gpu_dep_word(cache.vram, 16384) == UINT64_C(0x1122334455667788) &&
        gpu_dep_word(earlyBytes, 0) == UINT64_C(0x3737373737373737) &&
        gpu_dep_word(sourceCopy, 0) == UINT64_C(0x3737373737373737));
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 49152, 8, YES));
    assert([[headWitnesses[0] valueForKey:@"validated"] boolValue] &&
           [headWitnesses[0] valueForKey:@"observed"] == markerPage);
    BOOL ready = YES;
    require([cache tryIdleCPUAccessAtAddress:8192
                                      length:4
                                       write:NO
                                   completed:&ready
                                       error:&error],
            error);
    assert(!ready && !head.completed && !notifications);
    unsigned waits = commands.waits;
    require([cache waitForProducersOfRecording:head error:&error], error);
    assert(commands.prefixCalls == 1 && !commands.fullCalls &&
           commands.waits == waits && !late.gate.signaledValue);
    /* The executed Head witness is no longer a pending writer to this reader.
     */
    require([cache completeIndependentReads:first error:&error], error);
    assert([[first valueForKey:@"retired"] boolValue] &&
           !late.gate.signaledValue);
    /* A new witness reuses the retained pending marker page after the first
     * has already been validated. The gated middle section stays unsubmitted
     * until the second explicit producer prefix is requested. */
    IndependentReadCommands *secondQueue =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    require(secondQueue != nil, error);
    id<MTLBuffer> secondBytes = nil;
    NV2AMetalIndependentReads *second =
        surface_prefix_reader(cache, secondQueue, 32768, &secondBytes);
    require([cache prepareGPUReadAtAddress:50000 length:8 error:&error], error);
    gpu_dep_write(cache, 32768, UINT64_C(0x1234567812345678));
    NV2AMetalSurfaceRecording *last = cache.recording;
    require([cache checkpointWithError:&error], error);
    NSArray *witnesses = [cache valueForKey:@"pendingReadWitnesses"];
    assert(witnesses.count == 3 &&
           [witnesses[2] valueForKey:@"observed"] == markerPage &&
           [[witnesses[2] valueForKey:@"observedOffset"]
               unsignedIntegerValue] == offset + 16);
    late.gate.signaledValue = 1;
    require([cache waitForProducersOfRecording:last error:&error], error);
    assert(commands.prefixCalls == 2 && !commands.fullCalls &&
           last.producersCompleted && tail.producersCompleted &&
           !last.submitted && !head.completed && !notifications);
    require([cache completeIndependentReads:second error:&error] &&
                [cache completeIndependentReads:tailReader error:&error],
            error);
    assert([[second valueForKey:@"retired"] boolValue] &&
           gpu_dep_word(secondBytes, 0) == UINT64_C(0x3737373737373737));
    /* Committed witnesses keep their producer provenance when the pending
     * Surface metadata finally transfers to its full receipt. */
    require([cache submitWithError:&error], error);
    NSArray *fullEntries = [cache valueForKey:@"submissions"];
    assert([[fullEntries.lastObject valueForKey:@"readWitnesses"] count] == 0 &&
           ![first valueForKey:@"lastWitnessWriter"] &&
           ![second valueForKey:@"lastWitnessWriter"] &&
           ![tailReader valueForKey:@"lastWitnessWriter"] && !notifications);
    require([cache waitForRecording:head error:&error], error);
    assert(commands.fullCalls == 1 && head.submitted && head.completed &&
           tail.completed && last.completed && notifications == 1 &&
           !commands.sealedBufferCount &&
           !nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard, 8192, 4, NO));
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 49152, 8, YES));
    uint32_t green;
    memcpy(&green, (uint8_t *)cache.vram.contents + 8192, 4);
    assert(green == UINT32_C(0xff00ff00));
    require([commands waitUntilIdleWithError:&error], error);
    require([early waitUntilIdleWithError:&error] &&
                [late waitUntilIdleWithError:&error] &&
                [secondQueue waitUntilIdleWithError:&error],
            error);
    checks++;
}
static void surface_prefix_restore_tests(id<MTLDevice> device)
{
    for (unsigned open = 0; open < 2; open++) {
        NSError *error = nil;
        unsigned notifications = 0;
        SurfacePrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            surface_prefix_cache(device, &commands, &notifications);
        id<MTLBuffer> bytes = encode_vram_copy(cache, 49152, 8);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        gpu_dep_write(cache, 24576, UINT64_MAX);
        NV2AMetalSurfaceRecording *tail = cache.recording;
        if (!open)
            require([cache checkpointWithError:&error], error);
        commands.drainGate = [device newSharedEvent];
        commands.drainCache = cache;
        commands.drainAddress = 49152;
        Ivar ivar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(commands, ivar);
        assert(queue && commands.drainGate);
        [queue waitForEvent:commands.drainGate value:1];
        require([cache submitProducerPrefix:head error:&error] != nil, error);
        assert(commands.prefixCalls == 1 && !head.producersCompleted &&
               !head.submitted);
        require([cache discardForRestoreWithError:&error], error);
        assert(commands.guardedDrains == 1 && commands.prefixCalls == 1 &&
               !commands.fullCalls && head.cancelled && tail.cancelled &&
               !tail.producersCompleted &&
               gpu_dep_word(cache.vram, 24576) ==
                   UINT64_C(0x3737373737373737) &&
               gpu_dep_word(bytes, 0) == UINT64_C(0x3737373737373737) &&
               !notifications &&
               nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 49152, 8, YES));
        checks++;
    }
}
static void surface_prefix_failure_tests(id<MTLDevice> device)
{
    for (unsigned earlier = 0; earlier < 2; earlier++) {
        NSError *error = nil;
        unsigned notifications = 0;
        SurfacePrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            surface_prefix_cache(device, &commands, &notifications);
        NSError *oldFailure =
            [NSError errorWithDomain:@"test.surface-prefix.earlier"
                                code:1
                            userInfo:nil];
        NSError *headFailure =
            [NSError errorWithDomain:@"test.surface-prefix.head"
                                code:2
                            userInfo:nil];
        if (earlier) {
            gpu_dep_write(cache, 16384, UINT64_C(0x1122334455667788));
            require([cache submitWithError:&error] &&
                        [commands waitForSubmission:commands.lastSubmitted
                                              error:&error],
                    error);
            NSArray *entries = [cache valueForKey:@"submissions"];
            CountedIndependentReadReceipt *receipt =
                [CountedIndependentReadReceipt new];
            receipt.nativeSubmission = commands.lastSubmitted;
            receipt.failure = oldFailure;
            [entries.lastObject setValue:receipt forKey:@"submission"];
        }
        (void)encode_vram_copy(cache, 49152, 8);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        gpu_dep_write(cache, 24576, UINT64_MAX);
        NV2AMetalSurfaceRecording *tail = cache.recording;
        commands.prefixFailure = headFailure;
        assert(![cache waitForProducersOfRecording:head error:&error] &&
               error == (earlier ? oldFailure : headFailure) &&
               !head.producersCompleted && !head.submitted && !tail.submitted &&
               !notifications &&
               !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 49152, 8, YES));
        if (earlier)
            assert(!commands.injectedReceipt.polls);
        error = nil;
        assert(![cache collectCompletedWithError:&error] &&
               error == (earlier ? oldFailure : headFailure));
        NV2AMetalSubmission *native = commands.injectedReceipt.nativeSubmission;
        [commands cancel];
        commands.prefixFailure = nil;
        require([commands waitForSubmission:native error:&error], error);
        checks++;
    }
}
static void surface_prefix_raster_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    SurfacePrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache =
        surface_prefix_cache(device, &commands, &notifications);
    require([cache beginRasterProducersWithError:&error], error);
    id<MTLBuffer> output = encode_vram_copy(cache, 49152, 8);
    NV2AMetalSurfaceRecording *head = cache.recording;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [device newTextureWithDescriptor:td];
    const uint32_t zero[16] = { 0 };
    assert(color);
    [color replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0
               withBytes:zero
             bytesPerRow:16];
    require([commands addResource:color error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(pixel != nil, error);
    NV2AMetalVertex point = { 0 };
    point.clip[2] = .5f;
    point.clip[3] = 1;
    point.point_size = 1;
    point.screen[0] = point.screen[1] = 2;
    point.color[0][1] = point.color[0][3] = 1;
    id<MTLBuffer> vertices =
        [device newBufferWithBytes:&point
                            length:sizeof(point)
                           options:MTLResourceStorageModeShared];
    assert(vertices);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = 1;
    u.depth_format = NV2AMetalPixelDepthD24;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 16777215;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 4;
    for (unsigned k = 0; k < 4; k++) {
        u.textures[k].dimension = 2;
        u.textures[k].scale = 1;
    }
    NV2AMetalDrawConfig config = { 0 };
    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *rasterState =
        [[NV2AMetalDrawState alloc] initWithDevice:device
                                            config:&config
                                             error:&error];
    require(rasterState != nil, error);
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTL4RenderCommandEncoder> encoder = [commands beginRasterPass:pass
                                                               error:&error];
    require(encoder != nil, error);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    require([pixel encodeVertices:vertices
                              offset:0
                               count:1
                           primitive:MTLPrimitiveTypePoint
                            uniforms:&u
                            textures:textures
                                pass:pass
                           drawState:rasterState
                         rasterClass:NV2AMetalPixelRasterDirectPoint
                ignorePolygonCulling:NO
                       renderEncoder:encoder
                            commands:commands
                               error:&error],
            error);
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([cache checkpointWithError:&error], error);
    (void)encode_vram_copy(cache, 57344, 8);
    NV2AMetalSurfaceRecording *tail = cache.recording;
    require([cache checkpointWithError:&error], error);
    [cache endRasterProducers];
    require([cache waitForProducersOfRecording:head error:&error], error);
    uint32_t rgba[16];
    [color getBytes:rgba
        bytesPerRow:16
         fromRegion:MTLRegionMake2D(0, 0, 4, 4)
        mipmapLevel:0];
    assert(!memcmp(rgba, zero, sizeof(zero)) && commands.hasPendingRasterPass &&
           commands.prefixCalls == 1 && !commands.fullCalls &&
           head.producersCompleted && !head.completed &&
           !tail.producersCompleted && !notifications &&
           gpu_dep_word(output, 0) == UINT64_C(0x3737373737373737));
    require([cache waitForRecording:head error:&error], error);
    [color getBytes:rgba
        bytesPerRow:16
         fromRegion:MTLRegionMake2D(0, 0, 4, 4)
        mipmapLevel:0];
    unsigned green = 0;
    for (unsigned i = 0; i < 16; i++)
        green += rgba[i] == UINT32_C(0xff00ff00);
    assert(green == 1 && head.completed && tail.completed &&
           commands.fullCalls == 1 && !commands.hasPendingRasterPass &&
           !notifications);
    checks++;
}
static void surface_prefix_pressure_test(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    SurfacePrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache =
        surface_prefix_cache(device, &commands, &notifications);
    NV2AMetalSurfaceRecording *head = nil;
    for (unsigned i = 0; i < NV2AMetalCommandBatchLimit - 1; i++) {
        (void)encode_vram_copy(cache, i * 8, 8);
        if (!head)
            head = cache.recording;
        require([cache checkpointWithError:&error], error);
    }
    (void)encode_vram_copy(cache, 4096, 8);
    NV2AMetalSurfaceRecording *tail = cache.recording;
    require([cache waitForProducersOfRecording:head error:&error], error);
    assert(!commands.prefixCalls && commands.fullCalls == 1 && head.completed &&
           tail.completed && !commands.sealedBufferCount && !notifications);
    checks++;
}
@interface SurfacePrefixFeedback : CountedIndependentReadReceipt
@property(nonatomic) BOOL separated;
@end
@implementation SurfacePrefixFeedback
- (BOOL)hasSeparateProducerFeedback
{
    return _separated;
}
- (BOOL)completedProducersWithError:(NSError **)error
{
    return [self completedWithError:error];
}
@end
static void surface_prefix_ready_failure_tests(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 3; mode++) {
        BOOL foreign = mode == 2;
        NSError *error = nil;
        unsigned notifications = 0;
        SurfacePrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            surface_prefix_cache(device, &commands, &notifications);
        (void)encode_vram_copy(cache, 49152, 8);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error] &&
                    [cache waitForProducersOfRecording:head error:&error] &&
                    [cache submitWithError:&error] &&
                    [commands waitForSubmission:commands.lastSubmitted
                                          error:&error],
                error);
        NSArray *entries = [cache valueForKey:@"submissions"];
        SurfacePrefixFeedback *own = [SurfacePrefixFeedback new];
        own.separated = mode == 1;
        own.nativeSubmission = commands.lastSubmitted;
        [entries.lastObject setValue:own forKey:@"submission"];
        NSError *failure = [NSError errorWithDomain:@"test.surface-prefix.late"
                                               code:3
                                           userInfo:nil];
        IndependentReadCommands *source = nil;
        NV2AMetalIndependentReads *reader = nil;
        CountedIndependentReadReceipt *later = nil;
        NV2AMetalSurfaceRecording *tail = nil;
        unsigned polls = 0;
        if (foreign) {
            source = [[IndependentReadCommands alloc] initWithDevice:device
                                                               error:&error];
            require(source != nil, error);
            id<MTLBuffer> bytes = nil;
            reader = gpu_dep_read(cache, source, 32768, &bytes);
            later = [CountedIndependentReadReceipt new];
            later.nativeSubmission = source.lastSubmitted;
            [reader setValue:later forKey:@"submission"];
            gpu_dep_write(cache, 32768, UINT64_MAX);
            tail = cache.recording;
            later.failure = failure;
            later.ready = YES;
            polls = later.polls;
        } else
            own.failure = failure;
        own.ready = YES;
        unsigned commits = commands.prefixCalls + commands.fullCalls,
                 waits = commands.waits;
        BOOL ok = [cache waitForProducersOfRecording:head error:&error];
        assert(ok == foreign &&
               commands.prefixCalls + commands.fullCalls == commits &&
               commands.waits == waits && !notifications);
        if (foreign) {
            assert(later.polls == polls && !tail.submitted && !tail.cancelled);
            [cache cancel];
            later.failure = nil;
            require([cache completeIndependentReads:reader error:&error] &&
                        [cache waitForRecording:head error:&error],
                    error);
        } else {
            assert(error == failure);
            error = nil;
            assert(![cache collectCompletedWithError:&error] &&
                   error == failure);
        }
        checks++;
    }
}
static void surface_prefix_witness_failure_test(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    SurfacePrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache =
        surface_prefix_cache(device, &commands, &notifications);
    IndependentReadCommands *source =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    require(source != nil, error);
    id<MTLBuffer> bytes = nil;
    NV2AMetalIndependentReads *reader =
        surface_prefix_reader(cache, source, 16384, &bytes);
    gpu_dep_write(cache, 16384, UINT64_MAX);
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error] &&
                [cache submitProducerPrefix:head error:&error] &&
                [commands waitForSubmission:commands.lastSubmitted
                                      error:&error],
            error);
    NSArray *witnesses = [cache valueForKey:@"pendingReadWitnesses"];
    assert(witnesses.count == 1);
    id<MTLBuffer> observed = [witnesses[0] valueForKey:@"observed"];
    NSUInteger offset =
        [[witnesses[0] valueForKey:@"observedOffset"] unsignedIntegerValue];
    uint64_t zero = 0;
    memcpy((uint8_t *)observed.contents + offset, &zero, sizeof(zero));
    assert(![cache waitForProducersOfRecording:head error:&error] && error &&
           !head.producersCompleted && !head.completed && !head.submitted &&
           !notifications && ![[reader valueForKey:@"retired"] boolValue] &&
           !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 16384, 8, YES));
    NSError *failure = error;
    error = nil;
    assert(![cache collectCompletedWithError:&error] && error == failure);
    [commands cancel];
    require([source waitUntilIdleWithError:&error], error);
    checks++;
}
static void surface_producer_prefix_tests(id<MTLDevice> device)
{
    surface_prefix_scope_tests(device);
    surface_prefix_raster_tests(device);
    surface_prefix_pressure_test(device);
    surface_prefix_restore_tests(device);
    surface_prefix_failure_tests(device);
    surface_prefix_ready_failure_tests(device);
    surface_prefix_witness_failure_test(device);
    puts(
        "Surface producer prefixes: older unsubmitted Head commits without "
        "gated Tail, "
        "chronological controls, witness-page reuse, delayed raster pixels and "
        "batch-limit fallback; "
        "Surface/download/source guards "
        "remain pending until full wait; Restore drains only executed "
        "prefixes, "
        "later work cancels, own late full-feedback failure stays sticky and "
        "foreign tail feedback remains untouched; "
        "PASS");
}
#endif
