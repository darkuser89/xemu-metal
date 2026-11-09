/* Immutable RTT copies permit only their necessary CPU hazard prefix.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RTT_PREFIX_H
#define TEST_METAL_RTT_PREFIX_H

@interface NV2AMetalSurfaceCache (RTTPrefixDownloadEligibility)
- (BOOL)canOwnDownloadPrefix:(NV2AMetalSurfaceRecording *)recording;
@end

@interface RTTPrefixReceipt : NSObject
@property(nonatomic) NV2AMetalSubmission *native;
@property(nonatomic) NSError *failure;
@property(nonatomic) BOOL ready;
@property(nonatomic) unsigned polls;
@end
@implementation RTTPrefixReceipt
- (BOOL)completedWithError:(NSError **)error
{
    _polls++;
    if (error)
        *error = _ready ? _failure : nil;
    return _ready;
}
- (BOOL)completedProducersWithError:(NSError **)error
{
    return [self completedWithError:error];
}
- (BOOL)hasSeparateProducerFeedback
{
    return NO;
}
- (BOOL)belongsToOwner:(NV2AMetalCommands *)owner
{
    return [owner ownsSubmission:_native];
}
- (id<MTLEvent>)signalEvent
{
    return [_native valueForKey:@"signalEvent"];
}
- (uint64_t)signalValue
{
    return [[_native valueForKey:@"signalValue"] unsignedLongLongValue];
}
@end

@interface RTTPrefixCommands : NV2AMetalCommands
@property(nonatomic) unsigned prefixes, full, waits;
@property(nonatomic) NSUInteger cut;
@property(nonatomic) id<MTLSharedEvent> gate;
@property(nonatomic) BOOL releaseGateOnWait, rejectPrefix;
@property(nonatomic) NSError *prefixFailure;
@property(nonatomic) RTTPrefixReceipt *prefixReceipt;
@end
@implementation RTTPrefixCommands
- (NV2AMetalSubmission *)submitProducersThroughSectionCount:(NSUInteger)count
                                                batchSerial:(uint64_t)serial
                                                      error:(NSError **)error
{
    _prefixes++;
    _cut = count;
    if (_rejectPrefix) {
        _rejectPrefix = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.rtt-prefix.reject"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    NV2AMetalSubmission *receipt =
        [super submitProducersThroughSectionCount:count
                                      batchSerial:serial
                                            error:error];
    if (receipt && _prefixFailure) {
        _prefixReceipt = [RTTPrefixReceipt new];
        _prefixReceipt.native = receipt;
        _prefixReceipt.failure = _prefixFailure;
        return (id)_prefixReceipt;
    }
    return receipt;
}
- (BOOL)submitWithError:(NSError **)error
{
    _full++;
    return [super submitWithError:error];
}
- (void)observeWait
{
    _waits++;
    if (_releaseGateOnWait && !_gate.signaledValue)
        _gate.signaledValue = 1;
}
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)receipt error:(NSError **)error
{
    [self observeWait];
    RTTPrefixReceipt *wrapped =
        [(id)receipt isKindOfClass:RTTPrefixReceipt.class] ? (id)receipt : nil;
    if (![super waitForSubmission:wrapped ? wrapped.native : receipt
                            error:error])
        return NO;
    if (!wrapped)
        return YES;
    wrapped.ready = YES;
    if (error)
        *error = wrapped.failure;
    return !wrapped.failure;
}
- (BOOL)waitForProducersOfSubmission:(NV2AMetalSubmission *)receipt
                               error:(NSError **)error
{
    [self observeWait];
    RTTPrefixReceipt *wrapped =
        [(id)receipt isKindOfClass:RTTPrefixReceipt.class] ? (id)receipt : nil;
    if (![super waitForProducersOfSubmission:wrapped ? wrapped.native : receipt
                                       error:error])
        return NO;
    if (!wrapped)
        return YES;
    wrapped.ready = YES;
    if (error)
        *error = wrapped.failure;
    return !wrapped.failure;
}
@end

static NV2AMetalSurfaceCache *rttp_reference;
static NV2AMetalCachedSurface *(*rttp_prepare_original)(
    id, SEL, NV2AMetalCachedSurface *, uint64_t, NSError **);
static BOOL (*rttp_mark_original)(id, SEL, NV2AMetalCachedSurface *,
                                  NSError **);
static BOOL (*rttp_download_prefix_original)(id, SEL,
                                            NV2AMetalSurfaceRecording *);
static BOOL rttp_download_prefix(id object, SEL selector,
                                  NV2AMetalSurfaceRecording *recording)
{
    return object == rttp_reference ?
               NO :
               rttp_download_prefix_original(object, selector, recording);
}
static NV2AMetalCachedSurface *rttp_prepare(id object, SEL selector,
                                            NV2AMetalCachedSurface *s,
                                            uint64_t frame, NSError **error)
{
    if (object != rttp_reference)
        return rttp_prepare_original(object, selector, s, frame, error);
    NV2AMetalSurfaceConfig config = s.transfer.config;
    if (![object prepareTextureRead:s error:error])
        return nil;
    /* Exact previous route: ordinary rendering preparation plus the old mark
     * after the private copy. Never edit the new intent metadata directly. */
    return [object prepareSurfaceAtAddress:s.address
                                    config:&config
                                     frame:frame
                                     error:error];
}
static BOOL rttp_mark(id object, SEL selector, NV2AMetalCachedSurface *s,
                      NSError **error)
{
    return object == rttp_reference ?
               [object markRTTSampling:s error:error] :
               rttp_mark_original(object, selector, s, error);
}
static uint64_t rttp_word(id<MTLBuffer> buffer)
{
    uint64_t value;
    memcpy(&value, buffer.contents, sizeof(value));
    return value;
}
static id<MTLBuffer> rttp_copy(NV2AMetalCommands *owner, id<MTLBuffer> input,
                               NSUInteger offset)
{
    NSError *error = nil;
    id<MTLBuffer> out =
        [owner.device newBufferWithLength:8
                                  options:MTLResourceStorageModeShared];
    assert(out);
    memset(out.contents, 0, out.length);
    require([owner addResource:input error:&error] &&
                [owner addResource:out error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [owner.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:input
             sourceOffset:offset
                 toBuffer:out
        destinationOffset:0
                     size:8];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return out;
}
static BOOL rttp_covers(NV2AMetalSurfaceRecording *token, NSUInteger address)
{
    return [[token valueForKey:@"readerPages"] containsIndex:address / 4096];
}
static NV2AMetalIndependentReads *
rttp_reader(RTTPrefixCommands *owner, NSUInteger address, id<MTLBuffer> *copy)
{
    NSError *error = nil;
    NV2AMetalVRAMReadSpan span = { address, 8 };
    NV2AMetalIndependentReads *reader = nil;
    require([surfaces tryBeginIndependentReads:&span
                                         count:1
                                      commands:owner
                                         reads:&reader
                                         error:&error] &&
                reader,
            error);
    *copy = rttp_copy(owner, surfaces.vram, address);
    require([surfaces submitIndependentReads:reader error:&error], error);
    return reader;
}
static NV2AMetalCommands *rttp_blocker(RTTPrefixCommands *owner)
{
    NSError *error = nil;
    NV2AMetalCommands *blocker =
        [[NV2AMetalCommands alloc] initWithDevice:owner.device error:&error];
    require(blocker != nil, error);
    owner.gate = [owner.device newSharedEvent];
    id<MTL4CommandQueue> queue = [blocker valueForKey:@"queue"];
    assert(queue && owner.gate);
    [queue waitForEvent:owner.gate value:1];
    id<MTLSharedEvent> gate = owner.gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
    require([blocker beginWithError:&error] != nil, error);
    id<MTLBuffer> sentinel =
        [owner.device newBufferWithLength:8
                                  options:MTLResourceStorageModeShared];
    assert(sentinel);
    (void)rttp_copy(blocker, sentinel, 0);
    require([blocker submitWithError:&error], error);
    return blocker;
}

/* A real compatible Load/Store raster tail, with one visible green point. */
static id<MTLTexture> rttp_raster(void)
{
    NSError *error = nil;
    require([surfaces beginRasterProducersWithError:&error], error);
    require([surfaces prepareGPUReadAtAddress:57344 length:8 error:&error],
            error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [commands.device newTextureWithDescriptor:td];
    uint32_t zeros[16] = { 0 };
    assert(color);
    [color replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0
               withBytes:zeros
             bytesPerRow:16];
    require([commands addResource:color error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([surfaces prepareRasterPass:pass targets:@[] error:&error], error);
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
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
        [commands.device newBufferWithBytes:&point
                                     length:sizeof(point)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalPixelUniforms uniforms = { 0 };
    uniforms.combiner.final_inputs[0] = PS_REGISTER_V0;
    uniforms.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                        << 8;
    uniforms.smooth_shading = 1;
    uniforms.depth_format = NV2AMetalPixelDepthD24;
    uniforms.surface_scale[0] = uniforms.surface_scale[1] = 1;
    uniforms.clip_range[1] = uniforms.clip_range[3] = 16777215;
    uniforms.clip_regions[0][2] = uniforms.clip_regions[0][3] = 4;
    for (unsigned k = 0; k < 4; k++) {
        uniforms.textures[k].dimension = 2;
        uniforms.textures[k].scale = 1;
    }
    NV2AMetalDrawConfig config = { 0 };
    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(state != nil, error);
    NV2AMetalPixelTexture bindings[4] = { 0 };
    id<MTL4RenderCommandEncoder> e = [commands beginRasterPass:pass
                                                         error:&error];
    require(e != nil, error);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    require([pixel encodeVertices:vertices
                              offset:0
                               count:1
                           primitive:MTLPrimitiveTypePoint
                            uniforms:&uniforms
                            textures:bindings
                                pass:pass
                           drawState:state
                         rasterClass:NV2AMetalPixelRasterDirectPoint
                ignorePolygonCulling:NO
                       renderEncoder:e
                            commands:commands
                               error:&error],
            error);
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    [surfaces endRasterProducers];
    return color;
}
static NSData *rttp_pixels(id<MTLTexture> texture, BOOL visible)
{
    uint32_t words[16];
    [texture getBytes:words
          bytesPerRow:16
           fromRegion:MTLRegionMake2D(0, 0, 4, 4)
          mipmapLevel:0];
    unsigned green = 0;
    for (unsigned i = 0; i < 16; i++) {
        assert(words[i] == 0 || words[i] == UINT32_C(0xff00ff00));
        green += words[i] == UINT32_C(0xff00ff00);
    }
    assert(green == (unsigned)visible);
    return [NSData dataWithBytes:words length:sizeof(words)];
}

static void rttp_fixture(id<MTLDevice> device)
{
    NSError *error = nil;
    commands = [[RTTPrefixCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(commands && ram, error);
    memset(ram.contents, 0, ram.length);
    surfaces = [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                          vram:ram
                                                  didWriteVRAM:nil
                                                         error:&error];
    require(surfaces != nil, error);
    /* Register real CPU interception ownership without mutating source bytes.
     */
    surfaces.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
      assert(length && address + length <= 65536);
    };
    textures = [[NV2AMetalTextureCache alloc] initWithSurfaces:surfaces
                                                         error:&error];
    clearer = [[NV2AMetalClear alloc] initWithDevice:device error:&error];
    require(textures && clearer, error);
}
static NV2AMetalCachedTexture *rttp_texture(NV2AMetalTextureSource src)
{
    NSError *error = nil;
    NV2AMetalSamplerConfig sampler = policy();
    NV2AMetalCachedTexture *texture = [textures prepareSource:&src
                                                      sampler:&sampler
                                                        frame:7
                                                        error:&error];
    require(texture != nil, error);
    return texture;
}
static void rttp_float_pixels(id<MTLBuffer> buffer, unsigned mode)
{
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++)
            color_at(buffer, 4, x, y, mode == 3 ? 128.f / 255 : 0,
                     mode == 3 ? 128.f / 255 : 1, mode == 3 ? 128.f / 255 : 0,
                     1);
}
static void rttp_append_texels(NSMutableData *data, id<MTLBuffer> buffer)
{
    for (unsigned y = 0; y < 4; y++)
        [data appendBytes:(const uint8_t *)buffer.contents + y * 256
                   length:4 * 16];
}

/* Cases 0..3: cold/warm BGRA/packed/byte snapshots. 4..5: same-surface
 * intent upgrades after capture deduplication. 6: dirty copy-source access.
 * 7: cancel only the raster tail, retry, then restore an immutable snapshot. */
static NSData *rttp_run(id<MTLDevice> device, unsigned mode, BOOL reference)
{
    NSError *error = nil;
    rttp_fixture(device);
    RTTPrefixCommands *owner = (id)commands;
    rttp_reference = reference ? surfaces : nil;
    const NSUInteger surfaceAddress = 8192, vertexAddress = 32768;
    const uint64_t oldVertex = UINT64_C(0xffff0000ffff0000);
    const uint64_t blueVertex = UINT64_C(0xff0000ffff0000ff);
    unsigned bytes = mode == 2 ? 2 : mode == 3 ? 1 : 4;
    NV2AMetalSurfaceConfig config = {
        .format = mode == 2 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5 :
                  mode == 3 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_B8 :
                              NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 4,
        .height = 4,
        .pitch = 4 * bytes,
        .scale = 1,
        .color = YES
    };
    cpu_write(surfaceAddress, 16 * bytes);
    cpu_write(vertexAddress, 64);
    uint8_t *ram = surfaces.vram.contents;
    for (unsigned i = 0; i < 16; i++) {
        uint32_t green = mode == 1 || mode == 6 ? UINT32_C(0xffff0000) :
                         mode == 2              ? 0x07e0 :
                         mode == 3              ? 128 :
                                                  UINT32_C(0xff00ff00);
        memcpy(ram + surfaceAddress + i * bytes, &green, bytes);
        uint32_t red = UINT32_C(0xffff0000);
        memcpy(ram + vertexAddress + i * 4, &red, 4);
    }
    memset(ram + 57344, 0x55, 8);
    NV2AMetalCachedSurface *s = [surfaces prepareSurfaceAtAddress:surfaceAddress
                                                           config:&config
                                                            frame:1
                                                     forRendering:NO
                                                            error:&error];
    require(s != nil, error);
    if (mode == 1 || mode == 6) {
        s = [surfaces prepareSurfaceAtAddress:surfaceAddress
                                       config:&config
                                        frame:2
                                        error:&error];
        require(s != nil, error);
        NV2AMetalClearConfig green = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                       .rect = { 0, 0, 4, 4 },
                                       .uniforms = {
                                           .color = { 0, 1, 0, 1 } } };
        clear(s, green);
        assert(s.dirty);
    }
    BOOL warm = mode == 1 || mode == 3;
    if (warm)
        finish();
    unsigned baseFull = owner.full;
    RTTPrefixCommands *independent =
        [[RTTPrefixCommands alloc] initWithDevice:device error:&error];
    require(independent != nil, error);
    id<MTLBuffer> independentCopy = nil;
    NV2AMetalIndependentReads *reader =
        rttp_reader(independent, vertexAddress, &independentCopy);
    RTTPrefixReceipt *delayed = [RTTPrefixReceipt new];
    delayed.native = independent.lastSubmitted;
    [reader setValue:delayed forKey:@"submission"];
    NV2AMetalTextureSource src =
        source(surfaceAddress,
               mode == 2 ? NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5 :
               mode == 3 ? NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8 :
                           NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
               4, 4 * bytes);
    NV2AMetalCachedTexture *old = rttp_texture(src);
    assert(old.binding.texture != s.transfer.texture && old.scale == 1 &&
           s.frame == 7);
    require([surfaces prepareGPUReadAtAddress:vertexAddress
                                       length:64
                                        error:&error],
            error);
    id<MTLBuffer> headCopy = rttp_copy(commands, surfaces.vram, vertexAddress);
    id<MTLBuffer> oldReadback = read_texture(old);
    NV2AMetalSurfaceRecording *head = surfaces.recording;
    assert(head && rttp_covers(head, vertexAddress) && !head.cpuHazardsRetired);
    if (mode == 4) {
        NV2AMetalCachedSurface *same =
            [surfaces prepareSurfaceAtAddress:surfaceAddress
                                       config:&config
                                        frame:7
                                        error:&error];
        require(same == s, error);
    } else if (mode == 5) {
        require([surfaces markRTTSampling:s error:&error], error);
    }
    require([surfaces checkpointWithError:&error], error);
    /* For cancellation parity the conservative reference completes only its
     * old-API Head before the cancellable Tail is introduced. */
    if (mode == 7 && reference)
        require([surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error],
                error);
    require([surfaces prepareGPUReadAtAddress:57344 length:8 error:&error],
            error);
    NV2AMetalCommands *blocker = rttp_blocker(owner);
    require([commands orderAfterSubmission:blocker.lastSubmitted
                              fromCommands:blocker
                                     error:&error],
            error);
    id<MTLBuffer> tailCopy = rttp_copy(commands, surfaces.vram, 57344);
    id<MTLTexture> color = rttp_raster();
    NV2AMetalSurfaceRecording *tail = surfaces.recording;
    assert(tail && tail != head && rttp_covers(tail, 57344));
    if (mode == 7) {
        /* Cancel still-open work before the CPU host boundary seals it.
         * Retry the real raster Tail; Restore below discards its later seal. */
        [surfaces cancel];
        assert(tail.cancelled && !tail.submitted && !rttp_word(tailCopy));
        (void)rttp_pixels(color, NO);
        require([surfaces prepareGPUReadAtAddress:57344 length:8 error:&error],
                error);
        require([commands orderAfterSubmission:blocker.lastSubmitted
                                  fromCommands:blocker
                                         error:&error],
                error);
        tailCopy = rttp_copy(commands, surfaces.vram, 57344);
        color = rttp_raster();
        NV2AMetalSurfaceRecording *retry = surfaces.recording;
        assert(retry && retry != tail && retry != head);
        tail = retry;
    }
    BOOL prefix = !reference && mode != 4 && mode != 5 && mode != 6;
    owner.releaseGateOnWait = !prefix && mode != 7;
    NSUInteger target = mode == 6 ? surfaceAddress : vertexAddress;
    NSUInteger length = 64;
    uint64_t before = 0, announced = 0, finalVersion = 0;
    require([surfaces sourceVersionAtAddress:target
                                      length:length
                                     version:&before
                                       error:&error],
            error);
    if (mode == 1 || mode == 6)
        for (unsigned i = 0; i < 16; i++) {
            uint32_t value;
            memcpy(&value, ram + surfaceAddress + i * 4, 4);
            assert(value == UINT32_C(0xffff0000));
        }
    uint64_t generationBefore =
        [[surfaces valueForKey:@"generation"] unsignedLongLongValue];
    if (mode == 2 && !reference) {
        owner.rejectPrefix = YES;
        assert(![surfaces resolveCPUAccessAtAddress:target
                                             length:length
                                              write:YES
                                              error:&error] &&
               [error.domain isEqualToString:@"test.rtt-prefix.reject"] &&
               !head.cpuHazardsRetired && !owner.gate.signaledValue &&
               rttp_covers(head, vertexAddress) &&
               [[surfaces valueForKey:@"generation"] unsignedLongLongValue] ==
                   generationBefore);
        error = nil;
    }
    require([surfaces resolveCPUAccessAtAddress:target
                                         length:length
                                          write:YES
                                          error:&error],
            error);
    require([surfaces sourceVersionAtAddress:target
                                      length:length
                                     version:&announced
                                       error:&error],
            error);
    assert(announced == generationBefore + 1 && announced > before &&
           !rttp_covers(head, vertexAddress));
    if (prefix) {
        assert(owner.prefixes == 1 + (mode == 2) && owner.cut == 1 &&
               owner.full == baseFull && !owner.gate.signaledValue &&
               head.cpuHazardsRetired && head.producersCompleted &&
               !head.completed && !head.submitted && !tail.submitted &&
               !tail.cpuHazardsRetired && commands.hasPendingRasterPass &&
               rttp_covers(tail, 57344) && !rttp_word(tailCopy));
        (void)rttp_pixels(color, NO);
        unsigned commits = owner.prefixes, waits = owner.waits;
        require([surfaces resolveCPUAccessAtAddress:target
                                             length:length
                                              write:NO
                                              error:&error],
                error);
        assert(owner.prefixes == commits && owner.waits == waits &&
               !owner.gate.signaledValue);
    } else if (mode != 7) {
        /* A dirty-source download first closes the raster chain. Its new
         * raster-free section can then commit alone; the old reference route
         * retains the second full submit. The ordinary upgrades need one. */
        unsigned expectedFull = baseFull + (mode == 6 && reference ? 2 : 1);
        unsigned expectedPrefixes = mode == 6 && !reference ? 1 : 0;
        if (owner.prefixes != expectedPrefixes || owner.full != expectedFull ||
            owner.gate.signaledValue != 1 || !head.completed ||
            !tail.completed || commands.hasPendingRasterPass) {
            NV2AMetalSubmission *receipt = commands.lastSubmitted;
            NSError *fullError = nil, *producerError = nil;
            BOOL fullReady = [receipt completedWithError:&fullError];
            BOOL producerReady =
                [receipt completedProducersWithError:&producerError];
            fprintf(
                stderr,
                "RTT full route mode%u reference%d base/full/prefix=%u/%u/%u "
                "gate%llu head(s/c/p/h)=%d/%d/%d/%d tail(s/c/p/h)=%d/%d/%d/%d "
                "pendingRaster%d recording%d separate%d ready(full/prod)=%d/%d "
                "error(full/prod)=%s/%s\n",
                mode, reference, baseFull, owner.full, owner.prefixes,
                (unsigned long long)owner.gate.signaledValue, head.submitted,
                head.completed, head.producersCompleted, head.cpuHazardsRetired,
                tail.submitted, tail.completed, tail.producersCompleted,
                tail.cpuHazardsRetired, commands.hasPendingRasterPass,
                !!commands.commandBuffer, receipt.hasSeparateProducerFeedback,
                fullReady, producerReady,
                fullError.description.UTF8String ?: "nil",
                producerError.description.UTF8String ?: "nil");
        }
        assert(owner.prefixes == expectedPrefixes &&
               (!expectedPrefixes || owner.cut == 1) &&
               owner.full == expectedFull && owner.gate.signaledValue == 1 &&
               head.completed && tail.completed &&
               !commands.hasPendingRasterPass);
        (void)rttp_pixels(color, YES);
    }
    assert(rttp_word(headCopy) == oldVertex &&
           rttp_word(independentCopy) == oldVertex);
    rttp_float_pixels(oldReadback, mode);
    require([old validateCompletedWithError:&error], error);
    if (mode == 1 || mode == 6)
        for (unsigned i = 0; i < 16; i++) {
            uint32_t value;
            memcpy(&value, ram + surfaceAddress + i * 4, 4);
            assert(value ==
                   (mode == 6 ? UINT32_C(0xff00ff00) : UINT32_C(0xffff0000)));
        }
    /* The only actual host store occurs after the callback succeeded. */
    for (NSUInteger at = 0; at < length; at += 8)
        memcpy(ram + target + at, &blueVertex, 8);
    BOOL cancelled = mode == 7;
    if (cancelled) {
        require([surfaces discardForRestoreWithError:&error], error);
        assert(tail.cancelled && !tail.submitted && !tail.completed &&
               !rttp_word(tailCopy) && !s.valid &&
               !commands.hasPendingRasterPass);
        (void)rttp_pixels(color, NO);
    }
    owner.gate.signaledValue = 1;
    require([blocker waitUntilIdleWithError:&error], error);
    if (!cancelled)
        require([surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error],
                error);
    require([surfaces completeIndependentReads:reader error:&error], error);
    if (!cancelled) {
        assert(rttp_word(tailCopy) == UINT64_C(0x5555555555555555));
        (void)rttp_pixels(color, YES);
        require([surfaces sourceVersionAtAddress:target
                                          length:length
                                         version:&finalVersion
                                           error:&error],
                error);
        assert(finalVersion == announced);
    }
    NV2AMetalTextureSource freshSource =
        source(target, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    NV2AMetalCachedTexture *fresh = rttp_texture(freshSource);
    id<MTLBuffer> freshReadback = read_texture(fresh);
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    id<MTLBuffer> immutable = read_texture(old);
    finish();
    rttp_float_pixels(immutable, mode);
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++)
            color_at(freshReadback, 4, x, y, 0, 0, 1, 1);
    NSMutableData *result = [NSMutableData new];
    rttp_append_texels(result, oldReadback);
    rttp_append_texels(result, immutable);
    rttp_append_texels(result, freshReadback);
    [result appendData:rttp_pixels(color, !cancelled)];
    [result appendBytes:headCopy.contents length:8];
    [result appendBytes:independentCopy.contents length:8];
    [result appendBytes:ram + target length:length];
    [textures removeAllTextures];
    require([surfaces flushWithError:&error], error);
    rttp_reference = nil;
    return result;
}

static void rttp_error_priority(id<MTLDevice> device)
{
    NSError *error = nil;
    rttp_fixture(device);
    RTTPrefixCommands *owner = (id)commands;
    RTTPrefixCommands *sourceQueue =
        [[RTTPrefixCommands alloc] initWithDevice:device error:&error];
    require(sourceQueue != nil, error);
    uint8_t *ram = surfaces.vram.contents;
    for (unsigned i = 0; i < 16; i++) {
        uint32_t green = UINT32_C(0xff00ff00);
        memcpy(ram + 8192 + i * 4, &green, 4);
    }
    memset(ram + 32768, 0x37, 8);
    NV2AMetalSurfaceConfig config = {
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 4,
        .height = 4,
        .pitch = 16,
        .scale = 1,
        .color = YES
    };
    NV2AMetalCachedSurface *s = [surfaces prepareSurfaceAtAddress:8192
                                                           config:&config
                                                            frame:1
                                                     forRendering:NO
                                                            error:&error];
    require(s != nil, error);
    id<MTLBuffer> independentCopy = nil;
    NV2AMetalIndependentReads *reader =
        rttp_reader(sourceQueue, 32768, &independentCopy);
    RTTPrefixReceipt *failedReader = [RTTPrefixReceipt new];
    failedReader.native = sourceQueue.lastSubmitted;
    failedReader.failure =
        [NSError errorWithDomain:@"test.rtt-prefix.reader-first"
                            code:1
                        userInfo:nil];
    [reader setValue:failedReader forKey:@"submission"];
    (void)rttp_texture(
        source(8192, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16));
    require([surfaces prepareGPUReadAtAddress:32768 length:8 error:&error],
            error);
    id<MTLBuffer> headCopy = rttp_copy(commands, surfaces.vram, 32768);
    NV2AMetalSurfaceRecording *head = surfaces.recording;
    require([surfaces checkpointWithError:&error], error);
    owner.prefixFailure =
        [NSError errorWithDomain:@"test.rtt-prefix.head-second"
                            code:2
                        userInfo:nil];
    assert(![surfaces resolveCPUAccessAtAddress:32768
                                         length:8
                                          write:YES
                                          error:&error] &&
           error == failedReader.failure && sourceQueue.waits == 1 &&
           owner.prefixes == 1 && !owner.full && owner.prefixReceipt &&
           !owner.prefixReceipt.polls && !head.cpuHazardsRetired &&
           !head.completed && rttp_covers(head, 32768));
    /* Only test feedback is failed. Drain the real GPU work for lifetime,
     * without publishing the failed cache transaction or performing a store. */
    [commands cancel];
    require([owner waitForSubmission:owner.prefixReceipt.native error:&error],
            error);
    assert(rttp_word(headCopy) == UINT64_C(0x3737373737373737) &&
           rttp_word(independentCopy) == UINT64_C(0x3737373737373737));
    checks++;
}

static void rtt_prefix_tests(void)
{
    NV2AMetalCommands *savedCommands = commands;
    NV2AMetalSurfaceCache *savedSurfaces = surfaces;
    NV2AMetalTextureCache *savedTextures = textures;
    NV2AMetalClear *savedClearer = clearer;
    Method prepareMethod = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class,
        @selector(prepareSurfaceForRTTSnapshot:frame:error:));
    Method markMethod = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class, @selector(markRTTSnapshotCaptured:error:));
    Method downloadPrefixMethod = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class, @selector(canOwnDownloadPrefix:));
    assert(prepareMethod && markMethod && downloadPrefixMethod);
    rttp_download_prefix_original =
        (void *)method_getImplementation(downloadPrefixMethod);
    rttp_prepare_original =
        (void *)method_setImplementation(prepareMethod, (IMP)rttp_prepare);
    rttp_mark_original =
        (void *)method_setImplementation(markMethod, (IMP)rttp_mark);
    method_setImplementation(downloadPrefixMethod, (IMP)rttp_download_prefix);
    @try {
        for (unsigned mode = 0; mode < 8; mode++) {
            @autoreleasepool {
                NSData *reference = rttp_run(savedCommands.device, mode, YES);
                NSData *candidate = rttp_run(savedCommands.device, mode, NO);
                if (![candidate isEqualToData:reference]) {
                    fprintf(stderr, "RTT prefix exact output mismatch case%u\n",
                            mode);
                    abort();
                }
                checks++;
            }
        }
        rttp_error_priority(savedCommands.device);
    } @finally {
        rttp_reference = nil;
        method_setImplementation(prepareMethod, (IMP)rttp_prepare_original);
        method_setImplementation(markMethod, (IMP)rttp_mark_original);
        method_setImplementation(downloadPrefixMethod,
                                 (IMP)rttp_download_prefix_original);
        commands = savedCommands;
        surfaces = savedSurfaces;
        textures = savedTextures;
        clearer = savedClearer;
    }
    puts("Metal RTT prefix:8 old-route/Gate0 GPU pairs,cold/warm "
         "BGRA/packed/byte,"
         "real source+independent readers,immutable captures,fresh CPU stores,"
         "intent upgrades/dirty-source full fallback,rejected-prefix retry,"
         "Tail cancel/restore,reader-before-head failure;exact "
         "texels/raster/versions PASS");
}

#endif
