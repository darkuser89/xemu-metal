/* Completed surface writeback uses its own queue before a disjoint raster tail.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPLETED_DOWNLOAD_H
#define TEST_METAL_COMPLETED_DOWNLOAD_H
@interface NV2AMetalSurfaceCache (CompletedDownloadTest)
- (BOOL)canDownloadCompletedSurfaces:
    (NSArray<NV2AMetalCachedSurface *> *)surfaces;
- (NV2AMetalCommands *)completedDownloadCommandsWithError:(NSError **)error;
@end
@interface CompletedDownloadCache : NV2AMetalSurfaceCache
@property(nonatomic) BOOL forceFull, omitQueue;
@property(nonatomic) NV2AMetalCommands *helper;
@property(nonatomic) NSArray<NV2AMetalCachedSurface *> *callbackSources;
@property(nonatomic) BOOL reenterCallback, didReenter;
@property(nonatomic) NSMutableArray<NSArray<NSNumber *> *> *notices;
@end
@implementation CompletedDownloadCache
- (BOOL)canDownloadCompletedSurfaces:
    (NSArray<NV2AMetalCachedSurface *> *)surfaces
{
    return !_forceFull && [super canDownloadCompletedSurfaces:surfaces];
}
- (NV2AMetalCommands *)completedDownloadCommandsWithError:(NSError **)error
{
    if (_omitQueue) {
        _omitQueue = NO;
        return nil; /* Optional factory OOM takes the complete old route. */
    }
    _helper = [super completedDownloadCommandsWithError:error];
    return _helper;
}
@end
static CompletedDownloadCache *cd_observed;
static BOOL cd_track, cd_fail_encode, cd_fail_wait;
static unsigned cd_encodes, cd_submits, cd_waits, cd_injected;
static NSError *cd_failure;
static BOOL (*cd_download_original)(id, SEL, id, NSUInteger, BOOL, BOOL, BOOL,
                                    id, NSError **);
static BOOL cd_download(id object, SEL selector, id buffer, NSUInteger offset,
                        BOOL swizzle, BOOL flip, BOOL downscale, id commands,
                        NSError **error)
{
    if (cd_track && commands == cd_observed.helper) {
        cd_encodes++;
        if (cd_fail_encode) {
            cd_fail_encode = NO;
            cd_injected++;
            if (error)
                *error = cd_failure;
            return NO;
        }
    }
    return cd_download_original(object, selector, buffer, offset, swizzle, flip,
                                downscale, commands, error);
}
static BOOL (*cd_submit_original)(id, SEL, NSError **);
static BOOL cd_submit(id object, SEL selector, NSError **error)
{
    if (cd_track && object == cd_observed.helper)
        cd_submits++;
    return cd_submit_original(object, selector, error);
}
static BOOL (*cd_wait_original)(id, SEL, NV2AMetalSubmission *, NSError **);
static BOOL cd_wait(id object, SEL selector, NV2AMetalSubmission *receipt,
                    NSError **error)
{
    BOOL observed = cd_track && object == cd_observed.helper;
    if (observed)
        cd_waits++;
    BOOL result = cd_wait_original(object, selector, receipt, error);
    if (result && observed && cd_fail_wait) {
        cd_fail_wait = NO;
        cd_injected++;
        if (error)
            *error = cd_failure;
        return NO; /* Real GPU completion, deliberately failed feedback. */
    }
    return result;
}
static CompletedDownloadCache *cd_cache(id<MTLDevice> device,
                                        DownloadPrefixCommands **commands)
{
    NSError *error = nil;
    *commands = [[DownloadPrefixCommands alloc] initWithDevice:device
                                                         error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(*commands && ram, error);
    memset(ram.contents, 0x37, ram.length);
    __block __weak CompletedDownloadCache *weakCache = nil;
    CompletedDownloadCache *cache = [[CompletedDownloadCache alloc]
        initWithCommands:*commands
                    vram:ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              CompletedDownloadCache *owner = weakCache;
              assert(owner && length == 64 &&
                     (address == 16384 || address == 16448 ||
                      address == 32768 || address == 16512));
              uint32_t pixel;
              memcpy(&pixel, (const uint8_t *)ram.contents + address, 4);
              [owner.notices addObject:@[ @(address), @(length), @(pixel) ]];
              if (owner.reenterCallback && !owner.didReenter) {
                  owner.didReenter = YES;
                  assert(owner.callbackSources.count == 2);
                  for (NV2AMetalCachedSurface *surface in owner.callbackSources)
                      assert(!surface.dirty);
                  assert(![[owner valueForKey:@"completedDownloadTargets"]
                             count] &&
                         ![owner valueForKey:@"completedDownloadSubmission"]);
                  NV2AMetalCachedSurface *second = owner.callbackSources[1];
                  unsigned encodes = cd_encodes, submits = cd_submits,
                           waits = cd_waits;
                  NSUInteger notices = owner.notices.count;
                  uint64_t generation = up_generation(owner);
                  NSError *failure = nil;
                  require([owner resolveCPUAccessAtAddress:second.address
                                                    length:64
                                                     write:NO
                                                     error:&failure],
                          failure);
                  assert(cd_encodes == encodes && cd_submits == submits &&
                         cd_waits == waits && owner.notices.count == notices &&
                         up_generation(owner) == generation);
              }
            }
                   error:&error];
    require(cache != nil, error);
    weakCache = cache;
    cache.notices = [NSMutableArray new];
    cd_observed = cache;
    return cache;
}
static NV2AMetalCachedSurface *cd_surface(CompletedDownloadCache *cache,
                                          NSUInteger address, unsigned scale)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = up_config();
    c.scale = scale;
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:address
                                                              config:&c
                                                               frame:0
                                                        forRendering:NO
                                                               error:&error];
    require(surface && [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    return surface;
}
static NV2AMetalSurfaceRecording *cd_write(CompletedDownloadCache *cache,
                                           NV2AMetalCachedSurface *surface,
                                           unsigned rgb, BOOL finish)
{
    NSError *error = nil;
    require([cache prepareSelectedSurface:surface
                       discardingContents:NO
                                    error:&error],
            error);
    clear_surface(cache, surface,
                  MTLClearColorMake(!!(rgb & 4), !!(rgb & 2), !!(rgb & 1), 1),
                  0, 0);
    NV2AMetalSurfaceRecording *writer = cache.recording;
    require(writer && [cache checkpointWithError:&error], error);
    if (finish)
        require([cache submitWithError:&error] &&
                    [cache waitForRecording:writer error:&error],
                error);
    return writer;
}
static NV2AMetalSurfaceRecording *cd_raster(CompletedDownloadCache *cache,
                                            NV2AMetalCachedSurface *surface)
{
    NSError *error = nil;
    require([cache beginRasterProducersWithError:&error] &&
                [cache prepareSelectedSurface:surface
                           discardingContents:NO
                                        error:&error],
            error);
    id<MTLTexture> color = [surface.transfer textureForCommands:cache.commands
                                                          error:&error];
    require(color != nil, error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([cache prepareRasterPass:pass targets:@[ surface ] error:&error],
            error);
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:cache.commands.device
                                         colorFormat:color.pixelFormat
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    NV2AMetalVertex point = { 0 };
    point.clip[2] = .5f;
    point.clip[3] = 1;
    point.point_size = 1;
    point.screen[0] = point.screen[1] = 2;
    point.color[0][1] = point.color[0][3] = 1;
    id<MTLBuffer> vertices =
        [cache.commands.device newBufferWithBytes:&point
                                           length:sizeof(point)
                                          options:MTLResourceStorageModeShared];
    NV2AMetalPixelUniforms u = { .smooth_shading = 1,
                                 .depth_format = NV2AMetalPixelDepthD24,
                                 .surface_scale = { 1, 1 },
                                 .clip_range = { 0, 16777215, 0, 16777215 },
                                 .clip_regions = { { 0, 0, 4, 4 } } };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalDrawConfig c = { 0 };
    c.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:cache.commands.device
                                            config:&c
                                             error:&error];
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTL4RenderCommandEncoder> encoder =
        [cache.commands beginRasterPass:pass error:&error];
    require(pixel && vertices && raster && encoder, error);
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
                           drawState:raster
                         rasterClass:NV2AMetalPixelRasterDirectPoint
                ignorePolygonCulling:NO
                       renderEncoder:encoder
                            commands:cache.commands
                               error:&error],
            error);
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([cache markWritten:surface error:&error], error);
    [cache endRasterProducers];
    return cache.recording;
}
static void cd_words(id<MTLBuffer> ram, NSUInteger address, unsigned word)
{
    for (unsigned i = 0; i < 16; i++) {
        uint32_t value;
        memcpy(&value, (const uint8_t *)ram.contents + address + i * 4, 4);
        assert(value == word);
    }
}
static void cd_expect_b(NV2AMetalCachedSurface *surface, BOOL drawn)
{
    NSError *error = nil;
    NV2AMetalCommands *q =
        [[NV2AMetalCommands alloc] initWithDevice:cd_observed.commands.device
                                            error:&error];
    id<MTLBuffer> bytes =
        [q.device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    require(q && bytes && [q beginWithError:&error] &&
                [surface.transfer encodeDownloadToBuffer:bytes
                                                  offset:0
                                                 swizzle:YES
                                                    flip:NO
                                               downscale:YES
                                                commands:q
                                                   error:&error] &&
                [q submitWithError:&error] && [q waitUntilIdleWithError:&error],
            error);
    unsigned green = 0;
    for (unsigned i = 0; i < 16; i++) {
        uint32_t value = ((const uint32_t *)bytes.contents)[i];
        assert(value == UINT32_C(0x37373737) ||
               (drawn && value == UINT32_C(0xff00ff00)));
        green += value == UINT32_C(0xff00ff00);
    }
    assert(drawn ? green != 0 : green == 0);
}
static NSData *cd_pair(id<MTLDevice> device, BOOL reference, unsigned mode)
{
    NSError *error = nil;
    DownloadPrefixCommands *commands = nil;
    CompletedDownloadCache *cache = cd_cache(device, &commands);
    cache.forceFull = reference;
    BOOL multi = mode == 2, write = mode == 1 || mode == 4;
    NSUInteger bAddress = mode == 3 ? 16512 : 32768;
    NV2AMetalCachedSurface *a = cd_surface(cache, 16384, multi ? 2 : 1);
    NV2AMetalCachedSurface *b = cd_surface(cache, bAddress, 1);
    NV2AMetalCachedSurface *second = multi ? cd_surface(cache, 16448, 1) : nil;
    IndependentReadCommands *reader = nil;
    NV2AMetalIndependentReads *readScope = nil;
    id<MTLBuffer> readerBytes = nil;
    if (mode == 9) {
        reader = [[IndependentReadCommands alloc] initWithDevice:device
                                                           error:&error];
        require(reader != nil, error);
        gpu_dep_gate(reader);
        readScope = gpu_dep_read(cache, reader, 16384, &readerBytes);
        assert(readScope && !reader.gate.signaledValue);
    }
    NV2AMetalSurfaceRecording *writer = cd_write(cache, a, 2, YES);
    if (second)
        (void)cd_write(cache, second, 1, YES);
    assert(writer.completed && a.dirty);
    cd_words(cache.vram, 16384, UINT32_C(0x37373737));
    id<MTLTexture> snapshot = nil;
    if (mode == 5) {
        uint64_t writerGeneration = [[a
            valueForKey:@"committedWriterGeneration"] unsignedLongLongValue];
        uint64_t writerSerial =
            [[a valueForKey:@"committedWriterSerial"] unsignedLongLongValue];
        NV2AMetalCachedSurface *captured =
            [cache prepareSurfaceForRTTSnapshot:a frame:1 error:&error];
        require(captured == a, error);
        id<MTLTexture> native = [a.transfer textureForCommands:commands
                                                         error:&error];
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:4
                                        height:4
                                     mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead;
        snapshot = [device newTextureWithDescriptor:descriptor];
        require(native && snapshot &&
                    [commands addResource:native error:&error] &&
                    [commands addResource:snapshot error:&error],
                error);
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        require(encoder != nil, nil);
        [encoder barrierAfterQueueStages:MTLStageAll
                            beforeStages:MTLStageBlit
                       visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder copyFromTexture:native
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(4, 4, 1)
                       toTexture:snapshot
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];
        [encoder barrierAfterStages:MTLStageBlit
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
        require([cache markRTTSnapshotCaptured:a error:&error] &&
                    [cache checkpointWithError:&error],
                error);
        assert(
            ![[a valueForKey:@"recording"] boolValue] &&
            [[a valueForKey:@"committedWriterGeneration"]
                unsignedLongLongValue] == writerGeneration &&
            [[a valueForKey:@"committedWriterSerial"] unsignedLongLongValue] ==
                writerSerial &&
            [[a valueForKey:@"committedCaptureSerial"] unsignedLongLongValue] >
                [[cache valueForKey:@"completedRecordingSerial"]
                    unsignedLongLongValue]);
    }
    if (mode == 6)
        require([cache prepareSelectedSurface:a
                           discardingContents:NO
                                        error:&error],
                error);
    if (mode == 7 || mode == 8) {
        writer = cd_write(cache, a, 4, NO);
        if (mode == 8) {
            require([cache waitForProducersOfRecording:writer error:&error],
                    error);
            assert(writer.producersCompleted && !writer.completed);
        }
    }
    id<MTLSharedEvent> gate = nil;
    NV2AMetalCommands *blocker = up_blocker(device, &gate);
    commands.releaseGate = gate;
    commands.releaseOnWait = reference || mode >= 5;
    if (reader)
        reader.manualGate = NO;
    require([cache beginRecordingWithError:&error] &&
                [commands orderAfterSubmission:blocker.lastSubmitted
                                  fromCommands:blocker
                                         error:&error],
            error);
    NV2AMetalSurfaceRecording *tail = cd_raster(cache, b);
    assert(tail && commands.hasPendingRasterPass && !gate.signaledValue);
    id<MTL4CommandBuffer> buffer = commands.commandBuffer;
    uint64_t batch = commands.batchSerial, serial = commands.recordingSerial;
    NSUInteger sourceLength = multi ? 128 : 64;
    cache.callbackSources = multi ? @[ a, second ] : @[ a ];
    cache.reenterCallback = multi;
    commands.fullCalls = commands.prefixCalls = commands.waits = 0;
    cd_encodes = cd_submits = cd_waits = cd_injected = 0;
    cd_track = YES;
    cd_fail_encode = mode == 10;
    cd_fail_wait = mode == 11;
    cache.omitQueue = mode == 12;
    uint64_t generation = up_generation(cache),
             refs = tr_refs(cache, 16384 / 4096);
    if (mode == 10) {
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:64
                                           write:NO
                                           error:&error] &&
               error == cd_failure && cd_injected == 1);
        cd_words(cache.vram, 16384, UINT32_C(0x37373737));
        assert(!cache.notices.count && a.dirty && !gate.signaledValue &&
               commands.commandBuffer == buffer &&
               commands.batchSerial == batch &&
               commands.recordingSerial == serial && !tail.submitted &&
               tr_refs(cache, 16384 / 4096) == refs &&
               up_generation(cache) == generation);
        error = nil;
    }
    BOOL ok = [cache resolveCPUAccessAtAddress:16384
                                        length:sourceLength
                                         write:write
                                         error:&error];
    if (mode == 11) {
        assert(!ok && error == cd_failure && cd_injected == 1 &&
               !cache.notices.count && a.dirty &&
               up_generation(cache) == generation && !gate.signaledValue &&
               !tail.submitted && !commands.fullCalls &&
               !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 16384, 4, NO));
        NSError *sticky = nil;
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:4
                                           write:NO
                                           error:&sticky] &&
               sticky == cd_failure);
        assert([[cache valueForKey:@"completedDownloadTargets"] count]);
        [cache cancel];
        sticky = nil;
        assert(![cache discardForRestoreWithError:&sticky] &&
               sticky == cd_failure);
        assert(![[cache valueForKey:@"completedDownloadTargets"] count] &&
               ![cache valueForKey:@"completedDownloadSubmission"]);
        gate.signaledValue = 1;
        require([blocker waitUntilIdleWithError:&error], error);
        cd_track = NO;
        return [NSData dataWithBytes:cache.vram.contents
                              length:cache.vram.length];
    }
    require(ok, error);
    unsigned expected =
        mode == 7 || mode == 8 ? UINT32_C(0xffff0000) : UINT32_C(0xff00ff00);
    cd_words(cache.vram, 16384, expected);
    if (second)
        cd_words(cache.vram, 16448, UINT32_C(0xff0000ff));
    BOOL full = reference || (mode >= 5 && mode != 10);
    unsigned helperSubmits = cd_submits, helperEncodes = cd_encodes,
             helperWaits = cd_waits;
    if (!full) {
        cd_expect_b(b, NO);
        assert(!gate.signaledValue && !commands.fullCalls &&
               !commands.prefixCalls && !commands.waits && !tail.submitted &&
               !tail.completed && commands.hasPendingRasterPass &&
               commands.commandBuffer == buffer &&
               commands.batchSerial == batch &&
               commands.recordingSerial == serial && helperSubmits == 1 &&
               helperEncodes == (multi      ? 2u :
                                 mode == 10 ? 2u :
                                              1u) &&
               helperWaits == 1);
    } else
        assert(gate.signaledValue == 1 && commands.fullCalls &&
               tail.completed && !helperSubmits);
    assert(cache.notices.count == (multi ? 2u : 1u) &&
           (!multi || cache.didReenter) &&
           up_generation(cache) == generation + write);
    uint64_t version;
    require([cache sourceVersionAtAddress:16384
                                   length:sourceLength
                                  version:&version
                                    error:&error],
            error);
    if (write) {
        assert(version == generation + 1);
        up_store(cache, 16384, UINT32_C(0xff0000ff));
    }
    unsigned fullBefore = commands.fullCalls, waitBefore = commands.waits;
    require([cache resolveCPUAccessAtAddress:16384
                                      length:sourceLength
                                       write:NO
                                       error:&error],
            error);
    assert(cd_submits == helperSubmits && cd_encodes == helperEncodes &&
           cd_waits == helperWaits && commands.fullCalls == fullBefore &&
           commands.waits == waitBefore &&
           cache.notices.count == (multi ? 2u : 1u));
    if (mode == 4 && !reference) {
        [cache cancel];
        assert(tail.cancelled && !gate.signaledValue);
    }
    gate.signaledValue = 1;
    require([blocker waitUntilIdleWithError:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    if (reader) {
        require([cache completeIndependentReads:readScope error:&error], error);
        assert(gpu_dep_word(readerBytes, 0) == UINT64_C(0x3737373737373737));
    }
    if (mode != 4 || reference)
        cd_expect_b(b, YES);
    uint64_t after;
    require([cache sourceVersionAtAddress:16384
                                   length:sourceLength
                                  version:&after
                                    error:&error],
            error);
    assert(after == version);
    if (write) {
        NV2AMetalSurfaceConfig c = up_config();
        NV2AMetalCachedSurface *fresh = [cache prepareSurfaceAtAddress:16384
                                                                config:&c
                                                                 frame:2
                                                          forRendering:NO
                                                                 error:&error];
        require(fresh && [cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        up_pixels(fresh, UINT32_C(0xff0000ff));
    }
    if (mode == 4) {
        require([cache discardForRestoreWithError:&error], error);
        assert(cache.count == 0 && cache.notices.count == 1);
    }
    NSData *snapshotBytes = nil;
    if (snapshot) {
        NV2AMetalCommands *copy =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        id<MTLBuffer> bytes =
            [device newBufferWithLength:64
                                options:MTLResourceStorageModeShared];
        require(copy && bytes && [copy beginWithError:&error] &&
                    [copy addResource:snapshot error:&error] &&
                    [copy addResource:bytes error:&error],
                error);
        id<MTL4ComputeCommandEncoder> encoder =
            [copy.commandBuffer computeCommandEncoder];
        require(encoder != nil, nil);
        [encoder copyFromTexture:snapshot
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(4, 4, 1)
                            toBuffer:bytes
                   destinationOffset:0
              destinationBytesPerRow:16
            destinationBytesPerImage:0];
        [encoder endEncoding];
        require([copy submitWithError:&error] &&
                    [copy waitUntilIdleWithError:&error],
                error);
        cd_words(bytes, 0, UINT32_C(0xff00ff00));
        snapshotBytes = [NSData dataWithBytes:bytes.contents length:64];
    }
    cd_track = NO;
    NSMutableData *result =
        [NSMutableData dataWithBytes:(uint8_t *)cache.vram.contents + 16384
                              length:128];
    [result appendBytes:&after length:sizeof(after)];
    [result appendBytes:&generation length:sizeof(generation)];
    if (snapshotBytes)
        [result appendData:snapshotBytes];
    for (NSArray<NSNumber *> *notice in cache.notices) {
        uint64_t words[] = { notice[0].unsignedLongLongValue,
                             notice[1].unsignedLongLongValue,
                             notice[2].unsignedLongLongValue };
        [result appendBytes:words length:sizeof(words)];
    }
    return result;
}
static void completed_download_tests(id<MTLDevice> device)
{
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(encodeDownloadToBuffer:offset:swizzle:
                                          flip:downscale:commands:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:))
    };
    IMP replacements[] = { (IMP)cd_download, (IMP)cd_submit, (IMP)cd_wait },
        originals[3];
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    cd_download_original = (void *)originals[0];
    cd_submit_original = (void *)originals[1];
    cd_wait_original = (void *)originals[2];
    cd_failure = [NSError errorWithDomain:@"test.completed-download.failure"
                                     code:1
                                 userInfo:nil];
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned mode = 0; mode < 13; mode++) {
            if (mode == 11)
                continue;
            NSData *old = cd_pair(device, YES, mode == 10 ? 0 : mode);
            NSData *actual = cd_pair(device, NO, mode);
            assert([old isEqualToData:actual]);
            pairs++;
        }
        (void)cd_pair(device, NO, 11);
    } @finally {
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
        cd_track = cd_fail_encode = cd_fail_wait = NO;
        cd_observed = nil;
        cd_failure = nil;
    }
    checks += pairs + 1;
    printf("Completed surface download:%u real GPU/full-route pairs plus "
           "failed-feedback guard; "
           "disjoint cached raster targets/gates, read/write/reupload, "
           "Compute+direct multi-color "
           "A/reentrant callback, repeat no-work, "
           "captures/sealed RTT/generation/producer-only/readers, "
           "encode retry/optional-queue fallback and Restore PASS\n",
           pairs);
}
#endif
