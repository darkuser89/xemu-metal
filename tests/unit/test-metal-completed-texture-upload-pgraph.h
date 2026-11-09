/* Completed dirty texture/palette sources ahead of a disjoint PGRAPH pass.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPLETED_TEXTURE_UPLOAD_PGRAPH_H
#define TEST_METAL_COMPLETED_TEXTURE_UPLOAD_PGRAPH_H

typedef struct CompletedTextureUploadPgraphWork {
    RasterTextureUploadWork route;
    unsigned probes, eligible, helperSubmits, helperDownloads, mainDownloads,
        mainCommits;
    unsigned repairFull;
} CompletedTextureUploadPgraphWork;
static BOOL ctp_reference, ctp_scope;
static NSUInteger ctp_source;
static unsigned ctp_probes, ctp_eligible, ctp_helper_submits,
    ctp_helper_downloads, ctp_main_downloads;
static NSMutableArray<NV2AMetalTextureUploadResult *> *ctp_results;
static BOOL (*ctp_admit_original)(id, SEL, const NV2AMetalVRAMReadPattern *,
                                  NSUInteger, NSRange, NSArray *);
static BOOL ctp_admit(id owner, SEL selector,
                      const NV2AMetalVRAMReadPattern *patterns,
                      NSUInteger count, NSRange bounds, NSArray *selected)
{
    BOOL allowed =
        ctp_admit_original(owner, selector, patterns, count, bounds, selected);
    if (ctp_scope && owner == surfaces.cache) {
        ctp_probes++;
        ctp_eligible += allowed;
        if (ctp_reference)
            return NO; /* Only the new helper admission, never the old gate. */
    }
    return allowed;
}
static BOOL ctp_submit(id owner, SEL selector, NSError **error)
{
    if (ctp_scope &&
        owner == [surfaces.cache valueForKey:@"completedDownloadCommands"])
        ctp_helper_submits++;
    return rtp_submit(owner, selector, error);
}
static BOOL (*ctp_download_original)(id, SEL, id, NSUInteger, BOOL, BOOL, BOOL,
                                     id, NSError **);
static BOOL ctp_download(id owner, SEL selector, id buffer, NSUInteger offset,
                         BOOL swizzle, BOOL flip, BOOL downscale, id commands,
                         NSError **error)
{
    BOOL ok = ctp_download_original(owner, selector, buffer, offset, swizzle,
                                    flip, downscale, commands, error);
    if (ok && ctp_scope && buffer == surfaces.cache.vram &&
        offset == ctp_source) {
        if (commands == rtp_commands)
            ctp_main_downloads++;
        else if (commands ==
                 [surfaces.cache valueForKey:@"completedDownloadCommands"])
            ctp_helper_downloads++;
    }
    return ok;
}
static id ctp_upload(id owner, SEL selector, id data, NSUInteger offset,
                     id palette, NSUInteger paletteOffset,
                     NSUInteger paletteLength,
                     const NV2AMetalTextureShape *shape, id commands,
                     NSError **error)
{
    NV2AMetalTextureUploadResult *result =
        rtp_upload(owner, selector, data, offset, palette, paletteOffset,
                   paletteLength, shape, commands, error);
    if (result && ctp_scope && commands == rtp_commands)
        [ctp_results addObject:result];
    return result;
}
static void ctp_reset(void)
{
    rtp_full = rtp_commits = rtp_raster_commits = rtp_waits = rtp_uploads = 0;
    ctp_probes = ctp_eligible = ctp_helper_submits = ctp_helper_downloads =
        ctp_main_downloads = 0;
    ctp_results = [NSMutableArray new];
}
static CompletedTextureUploadPgraphWork ctp_work(void)
{
    return (CompletedTextureUploadPgraphWork){
        .route = { rtp_full, rtp_raster_commits, rtp_uploads, 0, rtp_waits,
                   rtp_a.submitted, rtp_commands.hasPendingRasterPass,
                   rtp_gate.signaledValue },
        .probes = ctp_probes,
        .eligible = ctp_eligible,
        .helperSubmits = ctp_helper_submits,
        .helperDownloads = ctp_helper_downloads,
        .mainDownloads = ctp_main_downloads,
        .mainCommits = rtp_commits
    };
}
static NSData *ctp_fault_bytes(BOOL fault)
{
    NSMutableData *data = [NSMutableData new];
    for (NSUInteger i = 0; i < ctp_results.count; i++) {
        id<MTLBuffer> buffer = ctp_results[i].faults;
        assert(buffer.length >= sizeof(uint32_t));
        uint32_t word;
        memcpy(&word, buffer.contents, sizeof(word));
        assert(word == (fault && i + 1 == ctp_results.count ? 1u : 0u));
        [data appendBytes:&word length:sizeof(word)];
    }
    return data;
}
static void ctp_ram(NSUInteger address, uint32_t expected)
{
    for (unsigned i = 0; i < 64; i++) {
        uint32_t actual;
        memcpy(&actual, state->vram_ptr + address + 4 * i, 4);
        assert(actual == expected);
    }
}
static NSData *ctp_image(NV2AMetalCachedTexture *texture, uint32_t expected)
{
    NSError *error = nil;
    NV2AMetalCommands *reader =
        [[NV2AMetalCommands alloc] initWithDevice:rtp_commands.device
                                            error:&error];
    require(reader && [reader beginWithError:&error], error);
    id<MTLBuffer> pixels =
        test_metal_read_texture(reader, texture.binding.texture, 0, 0);
    require(pixels && [reader submitWithError:&error] &&
                [reader waitUntilIdleWithError:&error],
            error);
    NSMutableData *bytes = [NSMutableData new];
    for (unsigned y = 0; y < 8; y++) {
        const float *row =
            (const float *)((const uint8_t *)pixels.contents + 256 * y);
        for (unsigned x = 0; x < 8; x++) {
            /* Actual MixedHalf storage, before the real fragment's unsigned
             * byte/255 reconstruction. Signed red is zero in both witnesses. */
            float divisor = texture.mixedSignedHalf ? 256.f : 255.f;
            float color[] = { ((expected >> 16) & 255) / divisor,
                              ((expected >> 8) & 255) / divisor,
                              (expected & 255) / divisor,
                              (expected >> 24) / divisor };
            for (unsigned c = 0; c < 4; c++)
                assert(fabsf(row[4 * x + c] - color[c]) < .000001f);
        }
        [bytes appendBytes:row length:8 * 16];
    }
    return bytes;
}
static void ctp_registers(BOOL palette, BOOL shortPalette)
{
    if (palette) {
        rtp_registers(2, NO, NO, NO);
        if (shortPalette)
            state->pgraph.regs_[NV_PGRAPH_TEXPALETTE0 + 4] |= 3u << 2;
    } else {
        rtp_registers(1, NO, NO, NO);
        state->pgraph.regs_[NV_PGRAPH_TEXFILTER0] |=
            NV_PGRAPH_TEXFILTER0_RSIGNED;
    }
}
static NSData *ctp_run(unsigned kind, BOOL reference,
                       CompletedTextureUploadPgraphWork *work)
{
    BOOL palette = kind == 2 || kind == 3;
    BOOL readonly = kind == 1 || kind == 4;
    cpp_scene(NO, readonly);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    rtp_commands = cache.commands;
    rtp_queue = [rtp_commands valueForKey:@"queue"];
    rtp_reference = NO; /* The old clean-upload admission remains unmodified. */
    ctp_reference = reference;
    ctp_scope = rtp_scope = rtp_known_error = NO;
    rtp_foreign = nil;
    rtp_foreign_marker = nil;
    rtp_foreign_gate = nil;
    ctp_source = palette ? rtp_palette(1) : 32768;
    dma[0].limit = 65535 - 1024;
    dma[3].limit = 8191;
    dma[4].limit = 16383;
    if (readonly) {
        mov(0, 0, 0, false);
        mov(1, 3, 3, false);
        for (unsigned i = 0; i < 4; i++)
            mov(2 + i, 9 + i, 9 + i, i == 3);
    }
    const float positions[3][4] = { { 6.5f, 6.5f, 16384, 1 },
                                    { 5.5f, 6.5f, 16384, 1 },
                                    { 6.5f, 5.5f, 16384, 1 } };
    cpu_write(16896, sizeof(positions));
    memcpy(state->vram_ptr + 16896, positions, sizeof(positions));
    /* Every CPU store is before A's writer and B's reader/target leases. */
    cpu_write(32768, 1024);
    for (unsigned i = 0; i < 64; i++)
        stl_le_p(state->vram_ptr + 32768 + 4 * i, rtp_color(0));
    memset(state->vram_ptr + 33280, kind == 3 ? 32 : 0, 256);
    cpu_write(ctp_source, palette ? 1024 : 256);
    for (unsigned i = 0; i < (palette ? 256u : 64u); i++)
        stl_le_p(state->vram_ptr + ctp_source + 4 * i, UINT32_C(0xffff0000));
    qemu_mutex_lock(&pg->lock);
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    pg->surface_color.offset = ctp_source - 1024;
    pg->surface_scale_factor = readonly ? 2 : 1;
    pg->surface_color.buffer_dirty = true;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = UINT32_C(0xff00ff00);
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7u
                                                                        << 16;
    require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    NV2AMetalCachedSurface *source = surfaces.color;
    assert(source.address == ctp_source && source.valid && source.dirty &&
           ![[source valueForKey:@"recording"] boolValue] &&
           source.transfer.config.scale == (readonly ? 2u : 1u));
    ctp_ram(ctp_source, UINT32_C(0xffff0000));
    pg->surface_color.offset = 0;
    pg->surface_scale_factor = 1;
    pg->surface_color.buffer_dirty = true;
    rtp_gate = [rtp_commands.device newSharedEvent];
    require(rtp_gate != nil, nil);
    id<MTLSharedEvent> watchdog = rtp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    rtp_failure = [NSError errorWithDomain:@"test.completed-texture-upload"
                                      code:83
                                  userInfo:nil];
    if (kind == 5)
        rtp_foreign_start();
    rtp_arm_a = YES;
    require([draw drawWithError:&error], error);
    assert(!rtp_arm_a && rtp_a && !rtp_a.submitted &&
           rtp_commands.hasPendingRasterPass && surfaces.color != source);
    if (kind == 5) {
        rtp_foreign_gate.signaledValue = 1;
        require([rtp_foreign waitUntilIdleWithError:&error], error);
        assert(
            [rtp_foreign.lastSubmitted completedWithError:&error] && !error &&
            *(uint32_t *)rtp_foreign_marker.contents == UINT32_C(0x6b6b6b6b));
        rtp_known_error = YES;
    }
    ctp_registers(palette, kind == 3);
    ctp_reset();
    ctp_scope = rtp_scope = YES;
    NSData *host = fpp_host();
    BOOL ok = [draw beginWithError:&error];
    NSMutableData *actual = [NSMutableData new];
    if (kind == 5) {
        assert(!ok && error == rtp_failure && [host isEqualToData:fpp_host()] &&
               pg->draw_time == 1);
        [actual appendBytes:rtp_foreign_marker.contents length:4];
        [actual
            appendData:[error.domain dataUsingEncoding:NSUTF8StringEncoding]];
        NSInteger code = error.code;
        [actual appendBytes:&code length:sizeof(code)];
        *work = ctp_work();
        ctp_scope = rtp_scope = rtp_known_error = NO;
        rtp_gate.signaledValue = 1;
        [actual appendData:rtp_frame(3)];
        qemu_mutex_unlock(&pg->lock);
        return actual;
    }
    unsigned repairFull = 0;
    if (kind == 3) {
        assert(!ok && error &&
               [error.localizedDescription
                   containsString:@"palette index fault"] &&
               [host isEqualToData:fpp_host()] && pg->draw_time == 1);
        [actual appendData:ctp_fault_bytes(YES)]; /* Real completed decode. */
        [actual
            appendData:[error.domain dataUsingEncoding:NSUTF8StringEncoding]];
        NSInteger code = error.code;
        [actual appendBytes:&code length:sizeof(code)];
        *work = ctp_work(); /* Preserve the actual fault's Gate0/Full0 proof. */
        error = nil;
        unsigned fullBefore = rtp_full;
        require([cache resolveCPUAccessAtAddress:33280
                                          length:64
                                           write:YES
                                           error:&error],
                error);
        repairFull = rtp_full - fullBefore;
        /* Existing CPU ownership remains conservative after producer-only
         * feedback under B's pending raster. The required repair can drain B.
         */
        assert(rtp_gate.signaledValue == 1 && rtp_a.submitted);
        memset(state->vram_ptr + 33280, 0, 64);
        ctp_scope = rtp_scope = NO;
        ctp_reset();
        ctp_scope = rtp_scope = YES;
        require([draw beginWithError:&error], error);
    } else
        require(ok, error);
    NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
    NV2AMetalPGRAPHTextureSnapshot *textures = pixel.textureSnapshot;
    NSData *begin = [draw beginSnapshotWithError:&error];
    require(begin != nil, error);
    unsigned stages = palette ? 2 : 1;
    for (unsigned i = 0; i < stages; i++) {
        NV2AMetalCachedTexture *texture = [textures textureAtIndex:i];
        require(texture && texture.producerRecording.producersCompleted, nil);
        [actual appendData:ctp_image(texture, palette && !i ?
                                                  rtp_color(0) :
                                                  UINT32_C(0xff00ff00))];
    }
    [actual appendData:ctp_fault_bytes(NO)];
    ctp_ram(ctp_source, UINT32_C(0xff00ff00));
    [actual appendBytes:state->vram_ptr + ctp_source length:256];
    [actual appendData:begin];
    if (kind != 3)
        *work = ctp_work();
    work->repairFull = repairFull;
    ctp_scope = rtp_scope = NO;
    if (kind == 4) {
        NV2AMetalCachedTexture *old = [textures textureAtIndex:0];
        NSData *oldPixels = ctp_image(old, UINT32_C(0xff00ff00));
        unsigned before = rtp_full;
        require([cache resolveCPUAccessAtAddress:ctp_source
                                          length:256
                                           write:YES
                                           error:&error],
                error);
        assert(rtp_full == before + !reference && rtp_gate.signaledValue == 1 &&
               rtp_a.submitted);
        for (unsigned i = 0; i < 64; i++)
            stl_le_p(state->vram_ptr + ctp_source + 4 * i,
                     UINT32_C(0xff0000ff));
        assert([oldPixels isEqualToData:ctp_image(old, UINT32_C(0xff00ff00))]);
        require([draw prepareVertexStateChangeWithError:&error], error);
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *vertex = draw.vertexSnapshot;
        require(pending && vertex, error);
        NSData *checkpoint = fpp_host();
        rtp_fail_emit = YES;
        assert(![draw flushDrawWithError:&error] && error == rtp_failure &&
               !rtp_fail_emit && [checkpoint isEqualToData:fpp_host()]);
        error = nil;
        require([draw endWithError:&error], error);
        [actual appendData:rtp_frame(6)];
        require([draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    (!pending.length || [draw restorePendingSnapshot:pending
                                                               error:&error]) &&
                    [draw beginWithError:&error] && [draw endWithError:&error],
                error);
        [actual appendData:rtp_frame(3)];
        [actual appendData:pending];
        [actual appendData:vertex];
        require([draw beginWithError:&error], error);
        NV2AMetalPGRAPHPixelState *fresh = [draw valueForKey:@"pixelState"];
        require([draw beginSnapshotWithError:&error] != nil, error);
        [actual appendData:ctp_image([fresh.textureSnapshot textureAtIndex:0],
                                     UINT32_C(0xff0000ff))];
        require([draw endWithError:&error], error);
        [actual appendData:rtp_frame(6)];
        color(6, 6, UINT32_C(0xff0000ff));
    } else {
        require([draw endWithError:&error], error);
        rtp_gate.signaledValue = 1;
        [actual appendData:rtp_frame(6)];
        color(6, 6, UINT32_C(0xff00ff00));
    }
    color(1, 1, UINT32_C(0xff00ff00));
    qemu_mutex_unlock(&pg->lock);
    return actual;
}

static void completed_texture_upload_pgraph_tests(void)
{
    id<MTL4CommandBuffer> probe =
        [surfaces.cache.commands.device newCommandBuffer];
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            NSSelectorFromString(@"canDownloadCompletedTextureUploadReadPattern"
                                 @"s:count:bounds:surfaces:")),
        class_getInstanceMethod([probe class],
                                @selector(beginCommandBufferWithAllocator:)),
        class_getInstanceMethod(
            [probe class],
            @selector(renderCommandEncoderWithDescriptor:options:)),
        class_getInstanceMethod(
            [[surfaces.cache.commands valueForKey:@"queue"] class],
            @selector(commit:count:options:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitUntilIdleWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(
            NV2AMetalTextureUpload.class,
            @selector(encodeData:offset:palette:paletteOffset:paletteLength:
                      shape:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(NV2AMetalSubmission.class,
                                @selector(completedWithError:)),
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(encodeDownloadToBuffer:offset:swizzle:
                                          flip:downscale:commands:error:))
    };
    IMP replacements[] = {
        (IMP)ctp_admit,  (IMP)rtp_begin,    (IMP)rtp_encoder,  (IMP)rtp_commit,
        (IMP)rtp_wait,   (IMP)rtp_producer, (IMP)rtp_idle,     (IMP)ctp_submit,
        (IMP)ctp_upload, (IMP)rtp_emit,     (IMP)rtp_feedback, (IMP)ctp_download
    };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    ctp_admit_original = (void *)originals[0];
    rtp_begin_original = (void *)originals[1];
    rtp_encoder_original = (void *)originals[2];
    rtp_commit_original = (void *)originals[3];
    rtp_wait_original = (void *)originals[4];
    rtp_producer_original = (void *)originals[5];
    rtp_idle_original = (void *)originals[6];
    rtp_full_original = (void *)originals[7];
    rtp_upload_original = (void *)originals[8];
    rtp_emit_original = (void *)originals[9];
    rtp_feedback_original = (void *)originals[10];
    ctp_download_original = (void *)originals[11];
    rtp_rasters = [[NSMapTable alloc]
        initWithKeyOptions:NSPointerFunctionsWeakMemory |
                           NSPointerFunctionsObjectPointerPersonality
              valueOptions:NSPointerFunctionsStrongMemory
                  capacity:32];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        /* Known real feedback failure is checked before any guest fault. */
        const unsigned order[] = { 5, 0, 1, 2, 3, 4 };
        for (unsigned n = 0; n < ARRAY_SIZE(order); n++)
            @autoreleasepool {
                unsigned kind = order[n];
                CompletedTextureUploadPgraphWork work[2] = { 0 };
                NSData *old = ctp_run(kind, YES, &work[0]);
                NSData *actual = ctp_run(kind, NO, &work[1]);
                if (![old isEqualToData:actual])
                    fprintf(stderr,
                            "Completed texture upload PGRAPH kind%u GPU/state "
                            "mismatch\n",
                            kind);
                assert(
                    [old isEqualToData:actual]); /* Whole bytes before work. */
                if (kind == 5) {
                    for (unsigned i = 0; i < 2; i++) {
                        if (work[i].helperSubmits || work[i].helperDownloads ||
                            work[i].mainDownloads || work[i].mainCommits ||
                            work[i].route.full != (i ? 0u : 1u) ||
                            work[i].route.raster || work[i].route.uploads ||
                            work[i].route.gate || work[i].route.aSubmitted)
                            fprintf(
                                stderr,
                                "Completed upload known error reference%u "
                                "source%zu probes%u eligible%u helperSubmit%u "
                                "helperDownload%u mainDownload%u mainCommit%u "
                                "full%u raster%u uploads%u admissions%u "
                                "waits%u "
                                "submitted%d pending%d gate%llu repairFull%u\n",
                                !i, ctp_source, work[i].probes,
                                work[i].eligible, work[i].helperSubmits,
                                work[i].helperDownloads, work[i].mainDownloads,
                                work[i].mainCommits, work[i].route.full,
                                work[i].route.raster, work[i].route.uploads,
                                work[i].route.admissions, work[i].route.waits,
                                work[i].route.aSubmitted, work[i].route.pending,
                                (unsigned long long)work[i].route.gate,
                                work[i].repairFull);
                        /* Full counts a method attempt. The old reference
                         * reaches submit, whose known dependency rejects
                         * before any native commit; the candidate checks it
                         * before starting the optional helper transaction. */
                        assert(!work[i].helperSubmits &&
                               !work[i].helperDownloads &&
                               !work[i].mainDownloads && !work[i].mainCommits &&
                               work[i].route.full == (i ? 0u : 1u) &&
                               !work[i].route.raster &&
                               !work[i].route.uploads && !work[i].route.gate &&
                               !work[i].route.aSubmitted);
                    }
                } else {
                    assert(work[0].probes && work[1].probes &&
                           work[1].eligible);
                    assert(
                        work[0].route.full == 1 && work[0].route.raster == 1 &&
                        work[0].route.gate == 1 && work[0].route.aSubmitted &&
                        !work[0].helperSubmits && !work[0].helperDownloads &&
                        work[0].mainDownloads == 1);
                    assert(
                        !work[1].route.full && !work[1].route.raster &&
                        !work[1].route.gate && !work[1].route.aSubmitted &&
                        work[1].route.pending && work[1].helperSubmits == 1 &&
                        work[1].helperDownloads == 1 && !work[1].mainDownloads);
                    if (kind == 3)
                        assert(!work[0].repairFull && work[1].repairFull == 1);
                }
            }
    } @finally {
        if (rtp_gate)
            rtp_gate.signaledValue = 1;
        if (rtp_foreign_gate)
            rtp_foreign_gate.signaledValue = 1;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
        ctp_reference = ctp_scope = rtp_scope = rtp_reference = rtp_arm_a =
            rtp_fail_emit = rtp_known_error = NO;
        ctp_results = nil;
        rtp_commands = rtp_foreign = nil;
        rtp_a = nil;
        rtp_queue = nil;
        rtp_gate = rtp_foreign_gate = nil;
        rtp_foreign_marker = nil;
        rtp_rasters = nil;
        rtp_failure = nil;
    }
    groups += 6;
    puts("Completed dirty texture upload PGRAPH:6 legacy-full A/B pairs; "
         "GPUgreen signed-R and palette-only sources, Scale1/2, pending raster "
         "Gate0, producer snapshot, physical decode faults, CPUrepair, "
         "lateRetry/Restore/CPUblue immutable old texture, prior feedback "
         "error; framebuffer/Zeta/query/Current/context/archive PASS");
}
#endif
