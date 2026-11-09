/* Cold Begin attachment uploads remain producer-only until their intent is
 * upgraded. SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_UPLOAD_PREFIX_PGRAPH_H
#define TEST_METAL_UPLOAD_PREFIX_PGRAPH_H
#import "hw/xbox/nv2a/pgraph/metal/clear.h"

static unsigned up_upgrade, up_upgrades;
static BOOL (*up_checkpoint)(id, SEL, NSError **);
static BOOL up_checkpoint_spy(id object, SEL selector, NSError **error)
{
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    if (object == cache && up_upgrade && cache.recording &&
        [[surfaces.color valueForKey:@"recording"] boolValue] &&
        [[surfaces.zeta valueForKey:@"recording"] boolValue]) {
        unsigned upgrade = up_upgrade;
        up_upgrade = 0;
        up_upgrades++;
        if (upgrade == 1) {
            if (![cache markRTTSampling:surfaces.color error:error])
                return NO;
        } else {
            if (![cache prepareSelectedSurface:surfaces.color
                            discardingContents:NO
                                         error:error])
                return NO;
            NV2AMetalClear *clear =
                [[NV2AMetalClear alloc] initWithDevice:cache.commands.device
                                                 error:error];
            NV2AMetalClearConfig config = {
                .parameter = NV097_CLEAR_SURFACE_COLOR,
                .rect = { 0, 0, 8, 8 },
                .uniforms = { .color = { 1, 0, 0, 1 } }
            };
            if (!clear ||
                ![clear encodeColor:surfaces.color.transfer.texture
                               zeta:nil
                             config:&config
                           commands:cache.commands
                              error:error] ||
                ![cache markWritten:surfaces.color
                    replacingContents:YES
                                error:error] ||
                ![cache prepareGPUReadAtAddress:1024 length:256 error:error])
                return NO;
        }
    }
    return up_checkpoint(object, selector, error);
}
/* Read completed private initialization on a separate queue. Neither this
 * helper nor the transfer changes Surface receipt/capture metadata. */
static NSData *up_surface_bytes(NV2AMetalCachedSurface *surface,
                                NSError **error)
{
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:error];
    id<MTLBuffer> buffer = [surfaces.cache.commands.device
        newBufferWithLength:256
                    options:MTLResourceStorageModeShared];
    if (!commands || !buffer || ![commands beginWithError:error] ||
        ![surface.transfer encodeDownloadToBuffer:buffer
                                           offset:0
                                          swizzle:YES
                                             flip:NO
                                        downscale:YES
                                         commands:commands
                                            error:error] ||
        ![commands submitWithError:error] ||
        ![commands waitUntilIdleWithError:error])
        return nil;
    return [NSData dataWithBytes:buffer.contents length:256];
}
static void up_start_gate(NSError **error)
{
    cpp_blocker = [[NV2AMetalCommands alloc] initWithDevice:cpp_commands.device
                                                      error:error];
    require(cpp_blocker != nil, *error);
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    cpp_queue = object_getIvar(cpp_commands, queue);
    id<MTL4CommandQueue> blockedQueue = object_getIvar(cpp_blocker, queue);
    cpp_gate = [cpp_commands.device newSharedEvent];
    assert(cpp_queue && blockedQueue && cpp_gate);
    [blockedQueue waitForEvent:cpp_gate value:1];
    require([cpp_blocker beginWithError:error], *error);
    id<MTLBuffer> bytes =
        [cpp_commands.device newBufferWithLength:4
                                         options:MTLResourceStorageModeShared];
    require(bytes && [cpp_blocker addResource:bytes error:error], *error);
    id<MTL4ComputeCommandEncoder> encoder =
        [cpp_blocker.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder fillBuffer:bytes range:NSMakeRange(0, 4) value:0x5a];
    [encoder endEncoding];
    require([cpp_blocker submitWithError:error], *error);
    id<MTLSharedEvent> gate = cpp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
    assert(!cpp_gate.signaledValue &&
           ![cpp_blocker.lastSubmitted completedWithError:NULL]);
}

static NSData *up_run(unsigned test, BOOL candidate)
{
    BOOL textured = test < 3 || test >= 5;
    unsigned program = test < 3 ? test : test == 3 ? 0 : 1;
    BOOL restore = test == 4;
    unsigned upgrade = test >= 6 ? test - 5 : 0;
    cpp_scene(textured, program);
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    cpp_commands = cache.commands;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw discardForRestoreWithError:&error], error);
    assert(!cache.count && !surfaces.color && !surfaces.zeta);
    up_upgrade = upgrade;
    unsigned upgrades = up_upgrades;
    require([draw beginWithError:&error], error);
    assert(!up_upgrade && up_upgrades == upgrades + !!upgrade);
    NSArray *sealed = [cache valueForKey:@"sealedTokens"];
    NV2AMetalSurfaceRecording *uploadHead = sealed.firstObject;
    assert(uploadHead && sealed.count == 1 && !uploadHead.submitted &&
           !uploadHead.producersCompleted && !uploadHead.cpuHazardsRetired &&
           !cache.recording && !surfaces.color.needsUpload &&
           !surfaces.zeta.needsUpload);
    NV2AMetalCachedSurface *colorSurface = surfaces.color;
    NV2AMetalCachedSurface *zetaSurface = surfaces.zeta;
    NV2AMetalPGRAPHPixelState *pixelState = [draw valueForKey:@"pixelState"];
    NV2AMetalSurfaceRecording *head = uploadHead;
    if (textured) {
        assert(
            [pixelState.textureSnapshot textureAtIndex:0].producerRecording ==
            uploadHead);
    } else {
        require([draw prepareVertexStateChangeWithError:&error], error);
        NV2AMetalPendingJournal *pending = [draw valueForKey:@"pending"];
        head = ((NV2AMetalPendingSpan *)pending.retainedStreams[0][0])
                   .producerRecording;
        assert(head && head != uploadHead && !head.cpuHazardsRetired);
    }
    NSData *pending = nil, *vertex = nil, *begin = nil;
    if (restore) {
        pending = [draw pendingSnapshotWithError:&error];
        vertex = draw.vertexSnapshot;
        begin = [draw beginSnapshotWithError:&error];
        require(pending && vertex && begin, error);
    }
    NSUInteger source = textured ? 32768 : 16640;
    NSUInteger length = textured ? 256 : 16;
    uint64_t beforeVersion = 0, announcedVersion = 0, afterVersion = 0;
    require([cache sourceVersionAtAddress:source
                                   length:length
                                  version:&beforeVersion
                                    error:&error],
            error);
    up_start_gate(&error);
    cpp_inject = YES;
    cpp_release_on_wait = NO;
    cpp_fail_emit = test == 5;
    unsigned failures = cpp_failures;
    if (cpp_fail_emit) {
        assert(![draw flushDrawWithError:&error] && error && !cpp_fail_emit &&
               cpp_failures == failures + 1);
        error = nil;
        cpp_inject = YES;
    }
    require([draw flushDrawWithError:&error], error);
    assert(!cpp_inject && cpp_tail && !cpp_tail.submitted &&
           cpp_commands.hasPendingRasterPass && !cpp_gate.signaledValue);
    state->pgraph.draw_arrays_length = 0;
    cpp_commits = cpp_buffers = cpp_waits = cpp_full = 0;
    uint64_t batch = cpp_commands.batchSerial;
    if (!candidate) {
        cpp_gate.signaledValue = 1;
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
    }
    uint64_t generationBeforeWrite =
        [[cache valueForKey:@"generation"] unsignedLongLongValue];
    cpp_release_on_wait = candidate && upgrade;
    require([cache resolveCPUAccessAtAddress:source
                                      length:length
                                       write:YES
                                       error:&error],
            error);
    cpp_release_on_wait = NO;
    if (candidate && !upgrade) {
        assert(!cpp_gate.signaledValue && uploadHead.cpuHazardsRetired &&
               head.cpuHazardsRetired && !uploadHead.completed &&
               !head.completed && !cpp_tail.cpuHazardsRetired &&
               !cpp_tail.completed && !cpp_tail.submitted && !cpp_full &&
               cpp_commands.batchSerial == batch &&
               cpp_commands.hasPendingRasterPass);
        NSData *color = up_surface_bytes(colorSurface, &error);
        NSData *zeta = up_surface_bytes(zetaSurface, &error);
        require(color && zeta, error);
        const uint32_t *rgba = color.bytes;
        const uint32_t *depth = zeta.bytes;
        for (unsigned i = 0; i < 64; i++)
            assert(rgba[i] == UINT32_C(0xffff0000) &&
                   depth[i] == UINT32_C(0xffffffff));
        assert(!cpp_gate.signaledValue &&
               ![cpp_blocker.lastSubmitted completedWithError:NULL]);
    } else if (candidate) {
        assert(cpp_gate.signaledValue == 1 && cpp_full && cpp_commits &&
               cpp_waits && cpp_tail.completed && uploadHead.completed &&
               !uploadHead.cpuHazardsRetired);
    }
    require([cache sourceVersionAtAddress:source
                                   length:length
                                  version:&announcedVersion
                                    error:&error],
            error);
    assert(announcedVersion > beforeVersion &&
           announcedVersion == generationBeforeWrite + 1);
    uint64_t expectedSourceVersion = announcedVersion;
    const float blue[4] = { 0, 0, 1, 1 };
    for (unsigned i = 0; i < (textured ? 64u : 1u); i++) {
        uint32_t value = UINT32_C(0xff0000ff);
        memcpy(state->vram_ptr + source + i * (textured ? 4 : 16),
               textured ? (const void *)&value : (const void *)blue,
               textured ? 4 : 16);
    }
    if (restore) {
        state->pgraph.draw_arrays_length = 1;
        require([draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    [draw restorePendingSnapshot:pending error:&error] &&
                    [draw beginWithError:&error],
                error);
        cpp_inject = candidate;
        require([draw flushDrawWithError:&error], error);
        assert(!cpp_inject);
        state->pgraph.draw_arrays_length = 0;
        require([cache sourceVersionAtAddress:source
                                       length:length
                                      version:&expectedSourceVersion
                                        error:&error],
                error);
        assert(expectedSourceVersion > announcedVersion);
    }
    cpp_gate.signaledValue = 1;
    require([draw endWithError:&error] && [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error] &&
                [cpp_blocker waitUntilIdleWithError:&error],
            error);
    require([cache prepareCPUAccessAtAddress:1024
                                      length:256
                                       write:NO
                                       error:&error] &&
                [cache prepareCPUAccessAtAddress:4096
                                          length:256
                                           write:NO
                                           error:&error],
            error);
    color(1, 1, UINT32_C(0xff00ff00));
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(query && state->pgraph.draw_time == 1);
    NSMutableData *result = [cpp_capture(query) mutableCopy];
    state->pgraph.draw_arrays_length = 1;
    require([draw beginWithError:&error], error);
    if (textured) {
        NV2AMetalPGRAPHPixelState *fresh = [draw valueForKey:@"pixelState"];
        assert([fresh.textureSnapshot textureAtIndex:0].binding.texture !=
               [pixelState.textureSnapshot textureAtIndex:0].binding.texture);
    }
    require([draw endWithError:&error] && [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error] &&
                [cache prepareCPUAccessAtAddress:1024
                                          length:256
                                           write:NO
                                           error:&error] &&
                [cache prepareCPUAccessAtAddress:4096
                                          length:256
                                           write:NO
                                           error:&error],
            error);
    color(1, 1, UINT32_C(0xff0000ff));
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error] &&
                [cache sourceVersionAtAddress:source
                                       length:length
                                      version:&afterVersion
                                        error:&error],
            error);
    query = report_value(0);
    assert(query && state->pgraph.draw_time == 2);
    assert(afterVersion == expectedSourceVersion);
    [result appendData:cpp_capture(query)];
    uint64_t versions[] = { announcedVersion - generationBeforeWrite,
                            afterVersion - expectedSourceVersion };
    [result appendBytes:versions length:sizeof(versions)];
    if (program == 2)
        expect_context(191, 15, 6, YES);
    qemu_mutex_unlock(&state->pgraph.lock);
    cpp_tail = nil;
    cpp_blocker = cpp_commands = nil;
    cpp_queue = nil;
    cpp_gate = nil;
    return result;
}

static void upload_prefix_pgraph_tests(void)
{
    fixture();
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:NULL];
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id nativeQueue = object_getIvar(probe, queue);
    Method methods[] = {
        class_getInstanceMethod(object_getClass(nativeQueue),
                                @selector(commit:count:options:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitUntilIdleWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                @selector(prepareRasterPass:targets:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                @selector(checkpointWithError:))
    };
    IMP replacements[] = { (IMP)cpp_commit,    (IMP)cpp_wait,
                           (IMP)cpp_producers, (IMP)cpp_idle,
                           (IMP)cpp_submit,    (IMP)cpp_raster,
                           (IMP)cpp_emit,      (IMP)up_checkpoint_spy },
        originals[8];
    for (unsigned i = 0; i < 8; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    cpp_commit_original = (void *)originals[0];
    cpp_wait_original = (void *)originals[1];
    cpp_producers_original = (void *)originals[2];
    cpp_idle_original = (void *)originals[3];
    cpp_full_original = (void *)originals[4];
    cpp_raster_original = (void *)originals[5];
    cpp_emit_original = (void *)originals[6];
    up_checkpoint = (void *)originals[7];
    @try {
        for (unsigned test = 0; test < 8; test++) {
            NSData *reference = up_run(test, NO);
            NSData *candidate = up_run(test, YES);
            if (![reference isEqualToData:candidate]) {
                fprintf(stderr, "Cold upload prefix PGRAPH mismatch case%u\n",
                        test);
                abort();
            }
        }
    } @finally {
        if (cpp_gate)
            cpp_gate.signaledValue = 1;
        for (unsigned i = 0; i < 8; i++)
            method_setImplementation(methods[i], originals[i]);
        cpp_commands = cpp_blocker = nil;
        cpp_tail = nil;
        cpp_queue = nil;
        cpp_gate = nil;
        cpp_inject = cpp_fail_emit = cpp_release_on_wait = NO;
        up_upgrade = 0;
    }
    puts(
        "Cold upload prefix PGRAPH: 8 exact framebuffer/zeta/Current/context/"
        "dirty/query/source-version pairs PASS; real cold Color+Zeta uploads, "
        "Begin textures and queued XF, original CPUwrite at Gate0 raster tail, "
        "private initialization readbacks, immutable Green then fresh Blue, "
        "Restore/late retry and sticky same-capture RTT/render/download "
        "fallback");
    groups += 8;
}
#endif
