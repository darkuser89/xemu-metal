/* Completed GPU surfaces before an unrelated open raster texture consumer.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPLETED_TEXTURE_UPLOAD_H
#define TEST_METAL_COMPLETED_TEXTURE_UPLOAD_H

@interface NV2AMetalSurfaceCache (CompletedTextureUploadTest)
- (BOOL)
    canDownloadCompletedTextureUploadReadPatterns:
        (const NV2AMetalVRAMReadPattern *)patterns
                                            count:(NSUInteger)count
                                           bounds:(NSRange)bounds
                                         surfaces:
                                             (NSArray<NV2AMetalCachedSurface *>
                                                  *)surfaces;
@end
@interface CompletedTextureUploadCache : RasterUploadCache
@property(nonatomic) BOOL forceCompletedOff, omitQueue;
@property(nonatomic) unsigned probes, completedEligible;
@property(nonatomic, strong) NV2AMetalCommands *helper;
@end
@implementation CompletedTextureUploadCache
- (BOOL)
    canDownloadCompletedTextureUploadReadPatterns:
        (const NV2AMetalVRAMReadPattern *)patterns
                                            count:(NSUInteger)count
                                           bounds:(NSRange)bounds
                                         surfaces:
                                             (NSArray<NV2AMetalCachedSurface *>
                                                  *)surfaces
{
    BOOL allowed =
        [super canDownloadCompletedTextureUploadReadPatterns:patterns
                                                       count:count
                                                      bounds:bounds
                                                    surfaces:surfaces];
    _probes++;
    _completedEligible += allowed;
    return !_forceCompletedOff && allowed;
}
- (NV2AMetalCommands *)completedDownloadCommandsWithError:(NSError **)error
{
    if (_omitQueue) {
        _omitQueue = NO;
        return nil;
    }
    _helper = [super completedDownloadCommandsWithError:error];
    return _helper;
}
@end

@interface CompletedTextureUploadCase : NSObject {
@public
    RasterUploadFixture *f;
    NSArray<NV2AMetalCachedSurface *> *sources;
    NSMutableData *expectedRAM;
    NSData *beforeCallbackRAM;
    NSMutableArray *notices;
    BOOL observing, reentered;
    unsigned action, failure, helperEncodes, helperSubmits, helperWaits,
        injected;
    IndependentReadCommands *reader;
    NV2AMetalIndependentReads *readerScope;
    id<MTLBuffer> readerBytes;
    id<MTLTexture> snapshot;
    NV2AMetalSurfaceRecording *b;
    unsigned nativeMainCommits, nativeHelperCommits;
    unsigned postCallbackCaptures, postCallbackUploads;
    unsigned postCallbackFull;
    NV2AMetalSurfaceRecording *rawWriter;
    NV2AMetalSubmission *callbackReceipt;
    BOOL rawNoticed;
    uint64_t versions[2];
}
@end
@implementation CompletedTextureUploadCase
@end
static _Thread_local __unsafe_unretained CompletedTextureUploadCase *ctu_active;
static NSError *ctu_error;
static CompletedTextureUploadCache *ctu_cache(CompletedTextureUploadCase *c)
{
    return (CompletedTextureUploadCache *)c->f->cache;
}
static void ctu_require_at(BOOL ok, NSError *error, unsigned line)
{
    if (!ok) {
        CompletedTextureUploadCase *c = ctu_active;
        NV2AMetalCommands *queue = c ? c->f->queue : nil;
        NV2AMetalCommands *helper = c ? ctu_cache(c).helper : nil;
        fprintf(
            stderr,
            "Completed upload failure line%u mode%u reference%u action%u "
            "failure%u "
            "recording%d cb%d batch%llu sealed%zu raster%d helper%d helperCB%d "
            "helperBatch%llu helperSealed%zu targets%zu injected%u error=%s\n",
            line, rtu_case, (unsigned)rtu_reference, c ? c->action : 0,
            c ? c->failure : 0, c && c->f->cache.recording != nil,
            queue.commandBuffer != nil, (unsigned long long)queue.batchSerial,
            queue.sealedBufferCount, queue.hasPendingRasterPass, helper != nil,
            helper.commandBuffer != nil, (unsigned long long)helper.batchSerial,
            helper.sealedBufferCount,
            c ? [[c->f->cache valueForKey:@"completedDownloadTargets"] count] :
                0,
            c ? c->injected : 0,
            error.localizedDescription.UTF8String ?: "unknown");
    }
    require(ok, error);
}
#define ctu_require(ok, error) ctu_require_at((ok), (error), __LINE__)
static void ctu_commit(id owner, SEL selector,
                       const id<MTL4CommandBuffer> *buffers, NSUInteger count,
                       MTL4CommitOptions *options)
{
    CompletedTextureUploadCase *c = ctu_active;
    if (c && c->observing) {
        if (owner == c->f->nativeQueue)
            c->nativeMainCommits++;
        if (ctu_cache(c).helper &&
            owner == [ctu_cache(c).helper valueForKey:@"queue"])
            c->nativeHelperCommits++;
    }
    rtu_commit(owner, selector, buffers, count, options);
}

static void ctu_notice(CompletedTextureUploadCase *c, NSUInteger address,
                       NSUInteger length)
{
    assert(c && length && address <= 65536 && length <= 65536 - address);
    c->f->notices++;
    if (!c->observing)
        return;
    uint32_t word;
    memcpy(&word, (uint8_t *)c->f->ram.contents + address, 4);
    [c->notices addObject:@[ @(address), @(length), @(word) ]];
    if (c->helperEncodes) {
        for (NV2AMetalCachedSurface *a in c->sources)
            assert(!a.dirty);
        assert(![[c->f->cache valueForKey:@"completedDownloadTargets"] count] &&
               ![c->f->cache valueForKey:@"completedDownloadSubmission"]);
    }
    if (!c->action || c->reentered)
        return;
    c->reentered = YES;
    c->beforeCallbackRAM = [c->expectedRAM copy];
    c->callbackReceipt = c->f->queue.lastSubmitted;
    NSError *error = nil;
    if (c->action == 1) {
        ctu_require([c->f->cache resolveCPUAccessAtAddress:address
                                                    length:length
                                                     write:YES
                                                     error:&error],
                    error);
        uint32_t red = UINT32_C(0xffff0000);
        for (NSUInteger p = 0; p < length; p += 4) {
            memcpy((uint8_t *)c->f->ram.contents + address + p, &red, 4);
            memcpy((uint8_t *)c->expectedRAM.mutableBytes + address + p, &red,
                   4);
        }
    } else if (c->action == 2) {
        ctu_require([c->f->cache beginRasterProducersWithError:&error], error);
        ctu_require([c->f->cache prepareGPUBlitFrom:NSMakeRange(60000, 8)
                                                 to:NSMakeRange(address, 8)
                                   replacingSurface:^BOOL(
                                       NV2AMetalCachedSurface *surface) {
                                     (void)surface;
                                     return NO;
                                   }
                                              error:&error],
                    error);
        (void)gpu_dep_copy(c->f->queue, c->f->ram, 60000, c->f->ram, address);
        c->rawWriter = c->f->cache.recording;
        [c->f->cache endRasterProducers];
        /* Checkpoint would itself submit an overwrite. Leave this real
         * cancellable producer open so the outer fresh guard must reject its
         * overwrite target and pending writer, before any upload can begin. */
        assert(c->rawWriter);
        if (!ctu_cache(c).forceCompletedOff)
            assert(!c->b.submitted);
        uint64_t blue = UINT64_C(0xff0000ffff0000ff);
        memcpy((uint8_t *)c->expectedRAM.mutableBytes + address, &blue, 8);
    } else {
        ctu_require([c->f->cache discardForRestoreWithError:&error], error);
        assert(!c->f->cache.recording && !c->f->queue.hasPendingRasterPass);
    }
}

static BOOL (*ctu_download_original)(id, SEL, id, NSUInteger, BOOL, BOOL, BOOL,
                                     id, NSError **);
static BOOL ctu_download(id owner, SEL selector, id buffer, NSUInteger offset,
                         BOOL swizzle, BOOL flip, BOOL downscale, id commands,
                         NSError **error)
{
    CompletedTextureUploadCase *c = ctu_active;
    BOOL observed = c && c->observing && commands == ctu_cache(c).helper;
    if (observed)
        c->helperEncodes++;
    BOOL ok = ctu_download_original(owner, selector, buffer, offset, swizzle,
                                    flip, downscale, commands, error);
    if (ok && observed && c->failure == 2) {
        c->failure = 0;
        c->injected++;
        if (error)
            *error = ctu_error;
        return NO;
    }
    return ok;
}
static BOOL (*ctu_submit_original)(id, SEL, NSError **);
static BOOL ctu_submit(id owner, SEL selector, NSError **error)
{
    CompletedTextureUploadCase *c = ctu_active;
    BOOL observed = c && c->observing && owner == ctu_cache(c).helper;
    if (observed) {
        c->helperSubmits++;
        if (c->failure == 3) {
            c->failure = 0;
            c->injected++;
            if (error)
                *error = ctu_error;
            return NO;
        }
    }
    BOOL ok = ctu_submit_original(owner, selector, error);
    if (ok && observed && c->failure == 4) {
        c->failure = 0;
        c->injected++;
        if (error)
            *error = ctu_error;
        return NO;
    }
    return ok;
}
static BOOL (*ctu_wait_original)(id, SEL, id, NSError **);
static BOOL ctu_wait(id owner, SEL selector, id receipt, NSError **error)
{
    CompletedTextureUploadCase *c = ctu_active;
    if (c && owner == c->reader && !c->reader.gate.signaledValue)
        c->reader.gate.signaledValue = 1;
    if (c && c->observing && owner == ctu_cache(c).helper)
        c->helperWaits++;
    return ctu_wait_original(owner, selector, receipt, error);
}

static CompletedTextureUploadCase *ctu_fixture(id<MTLDevice> device,
                                               unsigned format, BOOL reference)
{
    NSError *error = nil;
    CompletedTextureUploadCase *c = [CompletedTextureUploadCase new];
    c->f = rtu_fixture(device, format, NO);
    RasterUploadFixture *f = c->f;
    /* rtu_fixture has fully drained all its work. Replace only its idle
     * cache so this test owns the notification block; all native raster,
     * decoder, sampler, queue-gate and resource fixtures are reused. */
    assert(!f->queue.commandBuffer && !f->queue.batchSerial);
    __weak CompletedTextureUploadCase *weak = c;
    CompletedTextureUploadCache *cache = [[CompletedTextureUploadCache alloc]
        initWithCommands:f->queue
                    vram:f->ram
            didWriteVRAM:^(NSUInteger a, NSUInteger n) {
              ctu_notice(weak, a, n);
            }
                   error:&error];
    ctu_require(cache != nil, error);
    f->cache = cache;
    cache.forceCompletedOff = reference;
    NV2AMetalSurfaceConfig config = up_config();
    f->target = [cache prepareSurfaceAtAddress:8192
                                        config:&config
                                         frame:0
                                         error:&error];
    ctu_require(f->target != nil, error);
    clear_surface(cache, f->target, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    ctu_require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
    f->textures = [[NV2AMetalTextureCache alloc] initWithSurfaces:cache
                                                            error:&error];
    ctu_require(f->textures != nil, error);
    c->notices = [NSMutableArray new];
    return c;
}

static NV2AMetalCachedSurface *ctu_surface(CompletedTextureUploadCase *c,
                                           NSUInteger address, unsigned scale,
                                           BOOL packed)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig config = up_config();
    config.scale = scale;
    if (packed) {
        config.format = NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5;
        config.pitch = 8;
    }
    NV2AMetalCachedSurface *a = [c->f->cache prepareSurfaceAtAddress:address
                                                              config:&config
                                                               frame:0
                                                        forRendering:NO
                                                               error:&error];
    ctu_require(a && [c->f->cache submitWithError:&error] &&
                    [c->f->cache waitUntilIdleWithError:&error],
                error);
    return a;
}
static NV2AMetalSurfaceRecording *ctu_seed(CompletedTextureUploadCase *c,
                                           NV2AMetalCachedSurface *a,
                                           BOOL finish, BOOL blue)
{
    NSError *error = nil;
    ctu_require([c->f->cache prepareSelectedSurface:a
                                 discardingContents:NO
                                              error:&error],
                error);
    clear_surface(c->f->cache, a, MTLClearColorMake(0, !blue, blue, 1), 0, 0);
    NV2AMetalSurfaceRecording *writer = c->f->cache.recording;
    ctu_require(writer && [c->f->cache checkpointWithError:&error], error);
    if (finish)
        ctu_require([c->f->cache submitWithError:&error] &&
                        [c->f->cache waitForRecording:writer error:&error],
                    error);
    return writer;
}
static void ctu_expected_surface(CompletedTextureUploadCase *c,
                                 NV2AMetalCachedSurface *a, BOOL blue)
{
    unsigned bytes =
        a.transfer.config.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5 ?
            2 :
            4;
    uint32_t word = bytes == 2 ?
                        (blue ? 31 : 0x7e0) :
                        (blue ? UINT32_C(0xff0000ff) : UINT32_C(0xff00ff00));
    assert(a.reservationLength % bytes == 0);
    for (NSUInteger p = 0; p < a.reservationLength; p += bytes)
        memcpy((uint8_t *)c->expectedRAM.mutableBytes + a.address + p, &word,
               bytes);
}
static void ctu_decode(CompletedTextureUploadCase *c, NSData *pixels,
                       NSData *expectedRAM)
{
    assert(pixels.length == 8 * 8 * 16);
    const float *actual = pixels.bytes;
    BOOL palette = c->f->source.palette_length != 0;
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            unsigned at = palette ? rtu_morton(x, y) : y * 8 + x;
            uint32_t word;
            const uint8_t *ram = expectedRAM.bytes;
            if (palette) {
                unsigned index = ram[32768 + at];
                memcpy(&word, ram + 49152 + index * 4, 4);
            } else
                memcpy(&word, ram + 32768 + at * 4, 4);
            const float expected[] = { ((word >> 16) & 255) / 255.f,
                                       ((word >> 8) & 255) / 255.f,
                                       (word & 255) / 255.f,
                                       (word >> 24) / 255.f };
            for (unsigned k = 0; k < 4; k++)
                assert(fabsf(actual[(y * 8 + x) * 4 + k] - expected[k]) <
                       .000001f);
        }
}
static void ctu_frame(NSData *frame, NSData *decoded)
{
    assert(frame.length == 4 * 4 * 16 && decoded.length == 8 * 8 * 16);
    const float *p = frame.bytes, *sample = decoded.bytes;
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++) {
            const float red[] = { 1, 0, 0, 1 }, green[] = { 0, 1, 0, 1 };
            const float *e = x == 1 && y == 1 ? green :
                             x == 2 && y == 2 ? sample :
                                                red;
            for (unsigned k = 0; k < 4; k++)
                assert(fabsf(p[(y * 4 + x) * 4 + k] - e[k]) < .000001f);
        }
}

static void ctu_snapshot(CompletedTextureUploadCase *c,
                         NV2AMetalCachedSurface *a)
{
    NSError *error = nil;
    ctu_require([c->f->cache prepareSurfaceForRTTSnapshot:a
                                                    frame:1
                                                    error:&error] == a,
                error);
    id<MTLTexture> native = [a.transfer textureForCommands:c->f->queue
                                                     error:&error];
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:4
                                    height:4
                                 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead;
    c->snapshot = [c->f->queue.device newTextureWithDescriptor:d];
    ctu_require(native && c->snapshot &&
                    [c->f->queue addResource:native error:&error] &&
                    [c->f->queue addResource:c->snapshot error:&error],
                error);
    id<MTL4ComputeCommandEncoder> e =
        [c->f->queue.commandBuffer computeCommandEncoder];
    ctu_require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:native
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(4, 4, 1)
                toTexture:c->snapshot
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    ctu_require([c->f->cache markRTTSnapshotCaptured:a error:&error] &&
                    [c->f->cache checkpointWithError:&error],
                error);
}

static CompletedTextureUploadCase *ctu_begin(id<MTLDevice> device,
                                             unsigned mode, BOOL reference)
{
    NSError *error = nil;
    rtu_case = mode;
    rtu_reference = reference;
    CompletedTextureUploadCase *c =
        ctu_fixture(device, mode == 1 || mode == 2 ? 2 : 0, reference);
    RasterUploadFixture *f = c->f;
    NSUInteger address = mode == 1 ? 49280 : mode == 2 ? 32800 : 32896;
    NV2AMetalCachedSurface *a = ctu_surface(c, address,
                                            mode == 2 ? 2 :
                                            mode == 3 ? 4 :
                                                        1,
                                            mode == 2);
    if (mode == 6) {
        c->reader = [[IndependentReadCommands alloc] initWithDevice:device
                                                              error:&error];
        ctu_require(c->reader != nil, error);
        gpu_dep_gate(c->reader);
        id<MTLBuffer> readerBytes = nil;
        c->readerScope =
            gpu_dep_read(f->cache, c->reader, address, &readerBytes);
        c->readerBytes = readerBytes;
        ctu_require(c->readerScope != nil, error);
    }
    NV2AMetalSurfaceRecording *writer = ctu_seed(c, a, mode != 4, NO);
    if (mode != 4)
        assert(writer.completed && a.dirty);
    NSMutableArray *selected = [NSMutableArray arrayWithObject:a];
    if (mode == 2) {
        NV2AMetalCachedSurface *palette = ctu_surface(c, 49152, 1, NO);
        (void)ctu_seed(c, palette, YES, NO);
        [selected addObject:palette];
    }
    if (mode == 5)
        ctu_snapshot(c, a);
    if (mode == 7)
        ctu_require([f->cache prepareGPUReadAtAddress:a.address
                                               length:a.reservationLength
                                                error:&error] &&
                        [f->cache checkpointWithError:&error],
                    error);
    if (mode == 8) {
        NV2AMetalSurfaceConfig config = up_config();
        config.width = 2;
        config.pitch = 8;
        NV2AMetalCachedSurface *alias =
            [f->cache prepareSurfaceAtAddress:a.address + 16
                                       config:&config
                                        frame:1
                                 forRendering:NO
                                        error:&error];
        ctu_require(alias != nil, error);
        assert(!a.valid);
        (void)ctu_seed(c, alias, NO, YES);
        selected = [NSMutableArray arrayWithObject:alias];
    }
    c->sources = [selected copy];
    if (mode == 11) {
        ctu_require([f->cache resolveCPUAccessAtAddress:60000
                                                 length:8
                                                  write:YES
                                                  error:&error],
                    error);
        const uint64_t blue = UINT64_C(0xff0000ffff0000ff);
        memcpy((uint8_t *)f->ram.contents + 60000, &blue, 8);
    }
    assert(c->sources.count <= 2);
    for (NSUInteger i = 0; i < c->sources.count; i++) {
        NV2AMetalCachedSurface *surface = c->sources[i];
        ctu_require([f->cache sourceVersionAtAddress:surface.address
                                              length:surface.reservationLength
                                             version:&c->versions[i]
                                               error:&error],
                    error);
    }
    c->expectedRAM = [NSMutableData dataWithBytes:f->ram.contents
                                           length:f->ram.length];
    for (NV2AMetalCachedSurface *surface in c->sources)
        ctu_expected_surface(c, surface, mode == 8);
    ctu_active = c;
    rtu_active = f;
    c->b = rtu_raster(f, nil, YES, NO);
    id<MTLSharedEvent> watchdog = f->queue.gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    f->queue.fullCalls = f->queue.prefixCalls = 0;
    ctu_cache(c).probes = ctu_cache(c).completedEligible = 0;
    f->notices = 0;
    rtu_uploads = 0;
    c->observing = YES;
    if (mode == 9)
        ctu_cache(c).omitQueue = YES;
    if (mode >= 10)
        c->action = mode - 9;
    return c;
}

static void ctu_complete_write(CompletedTextureUploadCase *c)
{
    if (!c->rawWriter || c->rawNoticed)
        return;
    NSError *error = nil;
    unsigned full = c->f->queue.fullCalls;
    ctu_require([c->f->cache waitForRecording:c->rawWriter error:&error],
                error);
    assert(c->rawWriter.completed && !c->rawWriter.cancelled);
    const uint64_t blue = UINT64_C(0xff0000ffff0000ff);
    assert(!memcmp((uint8_t *)c->f->ram.contents + c->sources[0].address, &blue,
                   8));
    /* The real blit caller publishes texture-source dirtiness only after
     * validated full GPU feedback (blit-pgraph.m), not on registration. */
    ctu_require([c->f->cache noticeTextureDirtyAtAddress:c->sources[0].address
                                                  length:8
                                                   error:&error],
                error);
    c->rawNoticed = YES;
    c->postCallbackFull = c->f->queue.fullCalls - full;
    assert(c->postCallbackFull == (ctu_cache(c).forceCompletedOff ? 1u : 0u));
}

static NSArray *ctu_finish(CompletedTextureUploadCase *c,
                           NV2AMetalCachedTexture *texture)
{
    RasterUploadFixture *f = c->f;
    NSError *error = nil;
    if (f->cache.recording)
        ctu_require([f->cache checkpointWithError:&error], error);
    NV2AMetalSurfaceRecording *initialToken = texture.producerRecording;
    ctu_require(initialToken &&
                    [f->cache
                        waitForProducersOfRecording:texture.producerRecording
                                              error:&error],
                error);
    BOOL cancelledOld = c->action == 3 && ctu_cache(c).forceCompletedOff;
    if (cancelledOld) {
        /* Restore may cancel the old upload capability after its real GPU
         * prefix ran. Keep that rejection strict; prove physical completion
         * using the original immutable native receipt before reading bytes. */
        NV2AMetalSubmission *receipt = c->callbackReceipt;
        ctu_require(receipt && [f->queue waitForSubmission:receipt
                                                     error:&error],
                    error);
        assert(initialToken.cancelled);
        NSError *cancelled = nil;
        assert(![texture validateCompletedWithError:&cancelled] && cancelled &&
               [cancelled.localizedDescription containsString:@"cancelled"]);
    } else
        ctu_require([texture validateCompletedWithError:&error], error);
    NSData *decoded = rtu_texture(texture.binding.texture);
    if (c->action) {
        assert(c->reentered && c->beforeCallbackRAM);
        if (ctu_cache(c).forceCompletedOff) {
            /* The old main buffer already encoded its immutable upload when
             * feedback published the download and ran the callback. Verify
             * those OLD bytes first; do not compare different capture times. */
            NV2AMetalCachedTexture *old = texture;
            NSData *oldPixels = decoded;
            ctu_decode(c, oldPixels, c->beforeCallbackRAM);
            if (c->action == 2)
                ctu_complete_write(c);
            unsigned uploads = (unsigned)rtu_uploads;
            texture = rtu_upload(f, &error);
            ctu_require(texture && texture != old &&
                            texture.binding.texture != old.binding.texture,
                        error);
            c->postCallbackCaptures++;
            c->postCallbackUploads = (unsigned)rtu_uploads - uploads;
            if (f->cache.recording)
                ctu_require([f->cache checkpointWithError:&error], error);
            ctu_require(
                [f->cache waitForProducersOfRecording:texture.producerRecording
                                                error:&error] &&
                    [texture validateCompletedWithError:&error],
                error);
            decoded = rtu_texture(texture.binding.texture);
            ctu_decode(c, decoded, c->expectedRAM);
            if (c->action < 3)
                assert(![oldPixels isEqualToData:decoded]);
            assert([oldPixels isEqualToData:rtu_texture(old.binding.texture)]);
        } else
            ctu_decode(c, decoded, c->expectedRAM);
    } else
        ctu_decode(c, decoded, c->expectedRAM);
    if (c->action == 2)
        ctu_complete_write(c);
    assert(!memcmp(f->ram.contents, c->expectedRAM.bytes, f->ram.length));
    if (c->snapshot) {
        NSData *snapshot = rtu_texture(c->snapshot);
        const float *p = snapshot.bytes;
        assert(snapshot.length == 4 * 4 * 16);
        for (unsigned i = 0; i < 16; i++)
            assert(p[i * 4] == 0 && p[i * 4 + 1] == 1 && p[i * 4 + 2] == 0 &&
                   p[i * 4 + 3] == 1);
    }
    if (c->readerBytes) {
        /* A foreign reader really completed before any RAM download. Its
         * original words are checked against the unmodified source pattern. */
        NSUInteger offset = c->sources[0].address - 32768;
        assert(offset % 4 == 0);
        uint32_t words[] = { rtu_word(offset / 4), rtu_word(offset / 4 + 1) };
        assert(!memcmp(c->readerBytes.contents, words, 8));
    }
    if (c->action == 3) {
        /* Restore intentionally discarded B; use only public preparation to
         * build a new legal target and reset the independent query after all
         * old native work has actually drained. */
        f->queue.gate.signaledValue = 1;
        /* Close the fresh upload's still-open producer batch through its
         * owner. This cleanup is after the primary route-counter snapshot. */
        ctu_require([f->cache submitWithError:&error] &&
                        [f->cache waitUntilIdleWithError:&error],
                    error);
        NV2AMetalSurfaceConfig config = up_config();
        f->target = [f->cache prepareSurfaceAtAddress:8192
                                               config:&config
                                                frame:2
                                                error:&error];
        ctu_require(f->target != nil, error);
        clear_surface(f->cache, f->target, MTLClearColorMake(1, 0, 0, 1), 0, 0);
        ctu_require([f->cache submitWithError:&error] &&
                        [f->cache waitUntilIdleWithError:&error],
                    error);
        memset(f->query.contents, 0, 8);
        (void)rtu_raster(f, nil, YES, NO);
    }
    (void)rtu_raster(f, texture, YES, NO);
    f->queue.gate.signaledValue = 1;
    ctu_require([f->cache submitWithError:&error] &&
                    [f->cache waitUntilIdleWithError:&error],
                error);
    NSData *frame = rtu_texture(f->target.transfer.texture);
    ctu_frame(frame, decoded);
    uint64_t query;
    memcpy(&query, f->query.contents, 8);
    assert(query == 2 && f->target.dirty && f->queue.gate.signaledValue == 1);
    uint64_t versions[2] = { 0 };
    for (NSUInteger i = 0; i < c->sources.count; i++) {
        NV2AMetalCachedSurface *surface = c->sources[i];
        ctu_require([f->cache sourceVersionAtAddress:surface.address
                                              length:surface.reservationLength
                                             version:&versions[i]
                                               error:&error],
                    error);
        assert(c->action ? versions[i] >= c->versions[i] :
                           versions[i] == c->versions[i]);
        assert(!up_readers(f->cache, surface.address));
    }
    return @[
        decoded, frame, [NSData dataWithBytes:&query length:8],
        [NSData dataWithBytes:f->ram.contents length:f->ram.length], c->notices,
        [NSData dataWithBytes:versions
                       length:c->sources.count * sizeof(*versions)]
    ];
}

typedef struct CompletedTextureUploadWork {
    unsigned full, helper, callbacks, probes;
    BOOL gate, bSubmitted, helperReleased;
} CompletedTextureUploadWork;
static NSArray *ctu_run(id<MTLDevice> device, unsigned mode, BOOL reference,
                        CompletedTextureUploadWork *work, BOOL completeness)
{
    NSError *error = nil;
    CompletedTextureUploadCase *c = ctu_begin(device, mode, reference);
    RasterUploadFixture *f = c->f;
    NV2AMetalSurfaceRecording *b = c->b;
    BOOL partialRejected = YES, completeAllowed = YES;
    if (completeness) {
        NV2AMetalVRAMReadPattern patterns[] = { { 32768, 64, 0, 0 },
                                                { 49152, 1024, 0, 0 } };
        NSRange bounds = NSMakeRange(32768, 50176 - 32768);
        partialRejected = ![ctu_cache(c)
            canDownloadCompletedTextureUploadReadPatterns:patterns
                                                    count:2
                                                   bounds:bounds
                                                 surfaces:@[ c->sources[0] ]];
        completeAllowed = [ctu_cache(c)
            canDownloadCompletedTextureUploadReadPatterns:patterns
                                                    count:2
                                                   bounds:bounds
                                                 surfaces:c->sources];
    }
    NV2AMetalCachedTexture *texture = rtu_upload(f, &error);
    ctu_require(texture != nil, error);
    work->full = f->queue.fullCalls;
    work->helper = c->helperEncodes;
    work->probes = ctu_cache(c).probes;
    work->gate = f->queue.gate.signaledValue;
    work->bSubmitted = b.submitted;
    work->helperReleased =
        ![[f->cache valueForKey:@"completedDownloadTargets"] count] &&
        ![f->cache valueForKey:@"completedDownloadSubmission"];
    NSArray *actual = ctu_finish(c, texture);
    work->callbacks = (unsigned)c->notices.count;
    /* All decoded GPU floats, real frame/query, full guest RAM including
     * padding, and callback payloads precede route/metadata assertions. */
    assert(work->helperReleased && c->helperEncodes == work->helper &&
           work->callbacks == c->sources.count && work->probes <= 4 &&
           partialRejected);
    if (completeness)
        assert(completeAllowed == !reference);
    if (mode <= 3 && !reference)
        assert(!work->full && !work->gate && !work->bSubmitted &&
               work->helper == c->sources.count && c->helperSubmits == 1 &&
               c->helperWaits == 1);
    if (reference || (mode >= 4 && mode <= 9))
        assert(work->helper == 0 && work->full == 1 && work->bSubmitted);
    if (mode >= 10) {
        assert(c->reentered && work->helper == (reference ? 0u : 1u));
        if (!reference && mode == 10)
            assert(!work->full && !work->bSubmitted && !work->gate);
        if (!reference && mode == 11)
            assert(work->full == 1 && work->bSubmitted);
        if (!reference && mode == 12)
            assert(work->full == 0 && b.cancelled);
        assert(c->postCallbackCaptures == (reference ? 1u : 0u) &&
               c->postCallbackUploads == (reference ? 1u : 0u));
    }
    c->observing = NO;
    rtu_active = nil;
    ctu_active = nil;
    return actual;
}

static void ctu_errors(id<MTLDevice> device, NSArray *reference)
{
    for (unsigned failure = 2; failure <= 4; failure++)
        @autoreleasepool {
            NSError *error = nil;
            CompletedTextureUploadCase *c = ctu_begin(device, 0, NO);
            RasterUploadFixture *f = c->f;
            NV2AMetalCachedSurface *a = c->sources[0];
            uint64_t refs = tr_refs(f->cache, a.address / 4096),
                     generation = up_generation(f->cache);
            NSData *before = [NSData dataWithBytes:f->ram.contents
                                            length:f->ram.length];
            c->failure = failure;
            NV2AMetalCachedTexture *bad = rtu_upload(f, &error);
            assert(!bad && error == ctu_error && c->injected == 1 &&
                   !c->failure);
            if (failure < 4) {
                /* Real encoded work was cancelled before native submission. */
                assert(!memcmp(f->ram.contents, before.bytes, f->ram.length));
                rtu_pixels(rtu_texture(f->target.transfer.texture), 4, 4, NO,
                           NO);
                assert(!c->nativeHelperCommits && !c->notices.count &&
                       a.dirty && tr_refs(f->cache, a.address / 4096) == refs &&
                       up_generation(f->cache) == generation &&
                       !c->b.submitted && !f->queue.gate.signaledValue &&
                       !f->queue.fullCalls);
                error = nil;
                NV2AMetalCachedTexture *texture = rtu_upload(f, &error);
                ctu_require(texture != nil, error);
                NSArray *actual = ctu_finish(c, texture);
                assert([reference isEqualToArray:actual]);
                assert(c->helperEncodes == 2 && c->nativeHelperCommits == 1 &&
                       c->notices.count == 1);
            } else {
                /* A host failure after a real native commit is sticky. Wait
                 * only that immutable native receipt before reading actual RAM;
                 * the cache has deliberately not published any dirty/version
                 * state. */
                NV2AMetalCommands *helper = ctu_cache(c).helper;
                error = nil;
                ctu_require(helper.lastSubmitted &&
                                [helper waitForSubmission:helper.lastSubmitted
                                                    error:&error],
                            error);
                assert(!memcmp(f->ram.contents, c->expectedRAM.bytes,
                               f->ram.length));
                rtu_pixels(rtu_texture(f->target.transfer.texture), 4, 4, NO,
                           NO);
                assert(
                    c->nativeHelperCommits == 1 && a.dirty &&
                    !c->notices.count && !c->b.submitted &&
                    !f->queue.gate.signaledValue &&
                    tr_refs(f->cache, a.address / 4096) > refs &&
                    [[f->cache valueForKey:@"completedDownloadTargets"] count]);
                NSError *sticky = nil;
                unsigned encodes = c->helperEncodes;
                assert(!rtu_upload(f, &sticky) && sticky == ctu_error &&
                       c->helperEncodes == encodes);
                sticky = nil;
                assert(![f->cache discardForRestoreWithError:&sticky] &&
                       sticky == ctu_error);
                assert(![[f->cache valueForKey:@"completedDownloadTargets"]
                           count] &&
                       ![f->cache valueForKey:@"completedDownloadSubmission"]);
                f->queue.gate.signaledValue = 1;
                [f->cache cancel];
                [f->queue cancel];
                ctu_require([f->queue waitUntilIdleWithError:&error], error);
            }
            c->observing = NO;
            rtu_active = nil;
            ctu_active = nil;
        }
}

static void ctu_prior_error(id<MTLDevice> device)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++)
        @autoreleasepool {
            NSError *error = nil;
            CompletedTextureUploadCase *c = ctu_begin(device, 0, !candidate);
            RasterUploadFixture *f = c->f;
            IndependentReadCommands *blocker =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            ctu_require(blocker != nil, error);
            gpu_dep_gate(blocker);
            ctu_require([blocker beginWithError:&error] != nil, error);
            id<MTLBuffer> marker = gpu_dep_copy(blocker, f->ram, 60000, nil, 0);
            ctu_require([blocker submitWithError:&error], error);
            rtu_dependency = blocker.lastSubmitted;
            ctu_require([f->cache beginRasterProducersWithError:&error] &&
                            [f->cache beginRecordingWithError:&error] &&
                            [f->queue orderAfterSubmission:rtu_dependency
                                              fromCommands:blocker
                                                     error:&error],
                        error);
            [f->cache endRasterProducers];
            blocker.gate.signaledValue = 1;
            ctu_require([blocker waitUntilIdleWithError:&error], error);
            assert(gpu_dep_word(marker, 0) == UINT64_C(0x3737373737373737));
            rtu_bad_dependency = YES;
            NV2AMetalCachedTexture *bad = rtu_upload(f, &error);
            rtu_bad_dependency = NO;
            assert(!bad && error == rtu_failure);
            NSData *ram = [NSData dataWithBytes:f->ram.contents
                                         length:f->ram.length];
            NSData *frame = rtu_texture(f->target.transfer.texture);
            rtu_pixels(frame, 4, 4, NO, NO);
            NSArray *failed = @[ ram, frame, error.domain, @(error.code) ];
            if (!candidate)
                reference = failed;
            else
                assert([reference isEqualToArray:failed]);
            assert(!c->helperEncodes && !c->nativeHelperCommits &&
                   !c->nativeMainCommits && !rtu_uploads && !c->notices.count &&
                   !f->queue.gate.signaledValue && !c->b.submitted);
            /* A rejected full-submit method attempt on the old route commits
             * nothing. Candidate discovers the same dependency before the
             * helper. */
            assert(f->queue.fullCalls == (candidate ? 0u : 1u));
            error = nil;
            NV2AMetalCachedTexture *texture = rtu_upload(f, &error);
            ctu_require(texture != nil, error);
            (void)ctu_finish(c, texture);
            c->observing = NO;
            rtu_active = nil;
            ctu_active = nil;
            rtu_dependency = nil;
        }
}

static void completed_texture_upload_tests(id<MTLDevice> device)
{
    RasterUploadFixture *probe = rtu_fixture(device, 0, NO);
    Method methods[] = {
        class_getInstanceMethod(object_getClass(probe->nativeQueue),
                                @selector(commit:count:options:)),
        class_getInstanceMethod(
            NV2AMetalTextureUpload.class,
            @selector(encodeData:offset:palette:paletteOffset:paletteLength:
                      shape:commands:error:)),
        class_getInstanceMethod(NV2AMetalSubmission.class,
                                @selector(completedWithError:)),
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(encodeDownloadToBuffer:offset:swizzle:
                                          flip:downscale:commands:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:))
    };
    IMP replacements[] = { (IMP)ctu_commit,   (IMP)rtu_encode, (IMP)rtu_receipt,
                           (IMP)ctu_download, (IMP)ctu_submit, (IMP)ctu_wait },
        originals[6];
    for (unsigned i = 0; i < 6; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    rtu_commit_original = (void *)originals[0];
    rtu_encode_original = (void *)originals[1];
    rtu_receipt_original = (void *)originals[2];
    ctu_download_original = (void *)originals[3];
    ctu_submit_original = (void *)originals[4];
    ctu_wait_original = (void *)originals[5];
    ctu_error = [NSError errorWithDomain:@"test.completed-texture-upload"
                                    code:1
                                userInfo:nil];
    rtu_failure =
        [NSError errorWithDomain:@"test.completed-texture-upload.dependency"
                            code:2
                        userInfo:nil];
    for (unsigned i = 0; i < 6; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        ctu_prior_error(device);
        NSArray *plainReference = nil;
        for (unsigned mode = 0; mode < 13; mode++)
            @autoreleasepool {
                CompletedTextureUploadWork old = { 0 }, candidate = { 0 };
                NSArray *expected = ctu_run(device, mode, YES, &old, NO);
                NSArray *actual = ctu_run(device, mode, NO, &candidate, NO);
                if (![expected isEqualToArray:actual]) {
                    fprintf(
                        stderr,
                        "Completed texture upload bytes/query mode%u differ\n",
                        mode);
                    abort();
                }
                if (!mode)
                    plainReference = expected;
            }
        @autoreleasepool {
            CompletedTextureUploadWork old = { 0 }, candidate = { 0 };
            NSArray *expected = ctu_run(device, 2, YES, &old, YES);
            NSArray *actual = ctu_run(device, 2, NO, &candidate, YES);
            assert([expected isEqualToArray:actual]);
        }
        ctu_errors(device, plainReference);
    } @finally {
        if (ctu_active)
            ctu_active->f->queue.gate.signaledValue = 1;
        ctu_active = nil;
        rtu_active = nil;
        rtu_dependency = nil;
        ctu_error = rtu_failure = nil;
        rtu_upload_scope = rtu_fail_upload = rtu_bad_dependency = NO;
        for (unsigned i = 0; i < 6; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    checks += 16;
    puts(
        "Completed texture upload:16 native groups; exact "
        "private-texture/frame/query/"
        "whole-RAM and notification bytes before routes; real old admission-NO,"
        "palette/multi/scale/format, writer/capture/reader/download/alias "
        "guards,"
        "complete selection, prior-error, optional queue, encode/submit/sticky "
        "failures/retry and callback mutation/conflict/Restore PASS");
}
#undef ctu_require
#endif
