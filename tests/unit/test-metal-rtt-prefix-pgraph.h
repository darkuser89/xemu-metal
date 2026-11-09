/* Real immutable RTT captures retire only their producer CPU hazards.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RTT_PREFIX_PGRAPH_H
#define TEST_METAL_RTT_PREFIX_PGRAPH_H
static BOOL rttp_reference;
static unsigned rttp_prepares, rttp_marks;
static NV2AMetalCachedSurface *(*rttp_prepare_original)(id, SEL, id, uint64_t,
                                                        NSError **);
static NV2AMetalCachedSurface *rttp_prepare(NV2AMetalSurfaceCache *cache,
                                            SEL selector,
                                            NV2AMetalCachedSurface *surface,
                                            uint64_t frame, NSError **error)
{
    if (cache != surfaces.cache)
        return rttp_prepare_original(cache, selector, surface, frame, error);
    rttp_prepares++;
    if (!rttp_reference)
        return rttp_prepare_original(cache, selector, surface, frame, error);
    // The exact previous TextureCache capture preparation: texture ordering
    // followed by the generic rendering-intent SurfaceCache route.
    if (![cache prepareTextureRead:surface error:error])
        return nil;
    NV2AMetalSurfaceConfig config = surface.transfer.config;
    return [cache prepareSurfaceAtAddress:surface.address
                                   config:&config
                                    frame:frame
                                    error:error];
}
static BOOL (*rttp_mark_original)(id, SEL, id, NSError **);
static BOOL rttp_mark(NV2AMetalSurfaceCache *cache, SEL selector, id surface,
                      NSError **error)
{
    if (cache != surfaces.cache)
        return rttp_mark_original(cache, selector, surface, error);
    rttp_marks++;
    return rttp_reference ? [cache markRTTSampling:surface error:error] :
                            rttp_mark_original(cache, selector, surface, error);
}
static NSData *rttp_texture_bytes(id<MTLTexture> texture, NSError **error)
{
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:texture.device error:error];
    id<MTLBuffer> bytes =
        [texture.device newBufferWithLength:256
                                    options:MTLResourceStorageModeShared];
    if (!commands || !bytes || ![commands beginWithError:error] ||
        ![commands addResource:bytes error:error] ||
        ![commands addResource:texture error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    if (!e)
        return nil;
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:bytes
               destinationOffset:0
          destinationBytesPerRow:32
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    if (![commands submitWithError:error] ||
        ![commands waitUntilIdleWithError:error])
        return nil;
    return [NSData dataWithBytes:bytes.contents length:256];
}
static NSData *rttp_run(unsigned program, unsigned boundary, BOOL candidate)
{
    BOOL textured = boundary == 3;
    {
        @autoreleasepool {
            rttp_reference = !candidate;
            cpp_scene(YES, program);
            PGRAPHState *pg = &state->pgraph;
            /* Real RTT pixels must differ from the backing RAM bytes. */
            cpu_write(32768, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t red = UINT32_C(0xffff0000);
                memcpy(state->vram_ptr + 32768 + i * 4, &red, 4);
            }
            pg->regs_[NV_PGRAPH_COMBINESPECFOG0] =
                PS_REGISTER_T0 << 24 | PS_REGISTER_V0 << 16;
            pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
                (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
            NSError *error = nil;
            NV2AMetalSurfaceCache *cache = surfaces.cache;
            cpp_commands = cache.commands;
            qemu_mutex_lock(&state->pgraph.lock);
            /* Attachment upload/capture is outside the tested producer head. */
            require([surfaces prepareColor:YES
                                      zeta:YES
                              forRendering:NO
                                     error:&error] &&
                        [cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            dma[0].limit = 65535 - 1024;
            pg->surface_color.offset = 32768 - 1024;
            pg->surface_color.buffer_dirty = true;
            pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = UINT32_C(0xff00ff00);
            pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
                7u << 16;
            require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error],
                    error);
            NV2AMetalCachedSurface *sourceSurface = surfaces.color;
            assert(sourceSurface.address == 32768 && sourceSurface.dirty);
            NV2AMetalSubmission *previous = cpp_commands.lastSubmitted;
            if (boundary == 4) {
                // A different array range prevents the later XF head from
                // merely reusing the source draw's completed vertex prefix.
                pg->draw_arrays_start[0] = 2;
                pg->draw_arrays_count[0] = 1;
                require([draw drawWithError:&error], error);
                pg->draw_arrays_start[0] = 0;
                pg->draw_arrays_count[0] = 3;
                assert(cpp_commands.hasPendingRasterPass);
                previous = cpp_commands.lastSubmitted;
            } else {
                require([cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
            }
            int seedTime = pg->draw_time;
            pg->surface_color.offset = 0;
            pg->surface_color.buffer_dirty = true;
            rttp_prepares = rttp_marks = 0;
            require([draw beginWithError:&error], error);
            NV2AMetalPGRAPHPixelState *pixelState =
                [draw valueForKey:@"pixelState"];
            NV2AMetalCachedTexture *snapshot =
                [pixelState.textureSnapshot textureAtIndex:0];
            NV2AMetalSurfaceRecording *rttHead = snapshot.producerRecording;
            assert(rttHead && rttp_prepares == 1 && rttp_marks == 1 &&
                   snapshot.binding.texture != sourceSurface.transfer.texture &&
                   sourceSurface.scanoutClampToBorder && sourceSurface.dirty);
            uint32_t rawSource;
            memcpy(&rawSource, state->vram_ptr + 32768, 4);
            assert(rawSource == UINT32_C(0xffff0000));
            if (boundary == 4)
                assert(cpp_commands.lastSubmitted != previous &&
                       !cpp_commands.hasPendingRasterPass);
            require([draw prepareVertexStateChangeWithError:&error], error);
            NV2AMetalPendingJournal *journal = [draw valueForKey:@"pending"];
            NV2AMetalSurfaceRecording *head =
                ((NV2AMetalPendingSpan *)journal.retainedStreams[0][0])
                    .producerRecording;
            assert(head && !head.submitted && !head.cpuHazardsRetired &&
                   !cpp_commands.hasPendingRasterPass);
            NSData *pending = nil, *begin = nil, *vertex = nil;
            if (boundary == 1) {
                pending = [draw pendingSnapshotWithError:&error];
                begin = [draw beginSnapshotWithError:&error];
                vertex = draw.vertexSnapshot;
                require(pending && begin && vertex, error);
            }
            cpp_blocker =
                [[NV2AMetalCommands alloc] initWithDevice:cpp_commands.device
                                                    error:&error];
            require(cpp_blocker != nil, error);
            Ivar queue =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            cpp_queue = object_getIvar(cpp_commands, queue);
            id<MTL4CommandQueue> blockedQueue =
                object_getIvar(cpp_blocker, queue);
            cpp_gate = [cpp_commands.device newSharedEvent];
            assert(cpp_gate && cpp_queue && blockedQueue);
            [blockedQueue waitForEvent:cpp_gate value:1];
            require([cpp_blocker beginWithError:&error], error);
            id<MTLBuffer> blockedBytes = [cpp_commands.device
                newBufferWithLength:4
                            options:MTLResourceStorageModeShared];
            require(blockedBytes && [cpp_blocker addResource:blockedBytes
                                                       error:&error],
                    error);
            memset(blockedBytes.contents, 0, 4);
            id<MTL4ComputeCommandEncoder> blockedEncoder =
                [cpp_blocker.commandBuffer computeCommandEncoder];
            [blockedEncoder fillBuffer:blockedBytes
                                 range:NSMakeRange(0, 4)
                                 value:0x5a];
            [blockedEncoder endEncoding];
            require([cpp_blocker submitWithError:&error], error);

            id<MTLSharedEvent> watchdogGate = cpp_gate;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             if (!watchdogGate.signaledValue)
                                 watchdogGate.signaledValue =
                                     2; /* Failure-only escape. */
                           });
            assert(![cpp_blocker.lastSubmitted completedWithError:NULL] &&
                   *(uint32_t *)blockedBytes.contents == 0);
            cpp_inject = YES;
            cpp_fail_emit = boundary == 2;
            cpp_release_on_wait = NO;
            unsigned failures = cpp_failures;
            if (boundary == 2) {
                assert(![draw flushDrawWithError:&error] && error &&
                       !cpp_fail_emit && cpp_failures == failures + 1);
                error = nil;
                cpp_inject = YES;
            }
            require([draw flushDrawWithError:&error], error);
            assert(!cpp_inject && cpp_tail && !cpp_tail.submitted &&
                   cpp_commands.hasPendingRasterPass &&
                   !cpp_gate.signaledValue);
            /* Flush does not reset common-PGRAPH batch lengths. The caller
             * consumed these arrays; End must not issue them a second time. */
            state->pgraph.draw_arrays_length = 0;
            BOOL producerReady = head.producersCompleted;
            cpp_commits = cpp_buffers = cpp_waits = cpp_full = 0;
            uint64_t batch = cpp_commands.batchSerial;
            NSUInteger source = textured ? 32768 : 16640;
            /* The raster tail legitimately captures the last vertex for
             * Current. Mutate only the first endpoint's disjoint source slot.
             */
            NSUInteger length = textured ? 256 : 16;
            BOOL fallback = boundary == 3;
            cpp_release_on_wait = !candidate || fallback;
            if (fallback) {
                cpp_release_on_wait = YES;
                require([cache resolveCPUAccessAtAddress:32768
                                                  length:256
                                                   write:YES
                                                   error:&error],
                        error);
                if (candidate)
                    assert(cpp_gate.signaledValue == 1 && cpp_full &&
                           cpp_commits && cpp_waits && cpp_tail.completed);
            }
            if (!fallback) {
                require([cache resolveCPUAccessAtAddress:source
                                                  length:length
                                                   write:YES
                                                   error:&error],
                        error);
            } else {
                uint32_t downloaded;
                memcpy(&downloaded, state->vram_ptr + 32768, 4);
                assert(downloaded == UINT32_C(0xff00ff00));
            }
            cpp_release_on_wait = NO;
            if (!candidate || fallback) {
                assert(cpp_gate.signaledValue == 1 && cpp_full && cpp_commits &&
                       cpp_waits);
                NSData *frame = cpp_color_pixels(&error);
                require(frame != nil, error);
                assert(((const uint32_t *)frame.bytes)[9] ==
                       UINT32_C(0xff00ff00));
            }
            if (candidate && !fallback) {
                assert(!cpp_gate.signaledValue && head.cpuHazardsRetired &&
                       !cpp_tail.completed && !cpp_tail.cpuHazardsRetired &&
                       !cpp_tail.submitted && !cpp_full &&
                       cpp_commands.batchSerial == batch &&
                       cpp_commands.hasPendingRasterPass);
                assert(cpp_commits == !producerReady &&
                       (producerReady || cpp_buffers) &&
                       rttHead.producersCompleted && rttHead.cpuHazardsRetired);
                NSData *captured =
                    rttp_texture_bytes(snapshot.binding.texture, &error);
                require(captured != nil, error);
                const uint32_t *words = captured.bytes;
                for (unsigned i = 0; i < 64; i++)
                    assert(words[i] == UINT32_C(0xff00ff00));
                NSData *frame = cpp_color_pixels(&error);
                require(frame != nil, error);
                const uint32_t *pixels = frame.bytes;
                for (unsigned i = 0; i < 64; i++)
                    assert(pixels[i] == UINT32_C(0xffff0000));
                assert(*(uint32_t *)blockedBytes.contents == 0 &&
                       ![cpp_blocker.lastSubmitted completedWithError:NULL]);
                if (!textured) {
                    BOOL idle = YES;
                    /* The same-page last-vertex Current read remains owned
                     * by the unsubmitted raster tail after the first slot's
                     * exact CPU conflict has retired. */
                    require([cache tryIdleCPUAccessAtAddress:16672
                                                      length:16
                                                       write:YES
                                                   completed:&idle
                                                       error:&error],
                            error);
                    assert(!idle);
                }
                unsigned commits = cpp_commits, waits = cpp_waits;
                require([cache resolveCPUAccessAtAddress:source
                                                  length:length
                                                   write:YES
                                                   error:&error],
                        error);
                assert(cpp_commits == commits && cpp_waits == waits &&
                       !cpp_gate.signaledValue);
            }
            const float blue[4] = { 0, 0, 1, 1 };
            for (unsigned i = 0; i < (textured ? 64u : 1u); i++) {
                uint32_t pixel = UINT32_C(0xff0000ff);
                memcpy(state->vram_ptr + source + i * (textured ? 4 : 16),
                       textured ? (const void *)&pixel : (const void *)blue,
                       textured ? 4 : 16);
            }
            if (boundary == 1) {
                state->pgraph.draw_arrays_length = 1;
                require([draw discardForRestoreWithError:&error], error);
                assert(!candidate || !cpp_gate.signaledValue);
                require([draw restoreVertexSnapshot:vertex error:&error] &&
                            [draw restoreBeginSnapshot:begin error:&error] &&
                            (!pending.length ||
                             [draw restorePendingSnapshot:pending
                                                    error:&error]) &&
                            [draw beginWithError:&error],
                        error);
                cpp_inject = candidate;
                require([draw flushDrawWithError:&error], error);
                assert(!cpp_inject);
                state->pgraph.draw_arrays_length = 0;
            }
            cpp_gate.signaledValue = 1;
            require([draw endWithError:&error] &&
                        [cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            require([cpp_blocker waitUntilIdleWithError:&error], error);
            require([cache prepareCPUAccessAtAddress:1024
                                              length:256
                                               write:NO
                                               error:&error] &&
                        [cache prepareCPUAccessAtAddress:4096
                                                  length:256
                                                   write:NO
                                                   error:&error],
                    error);
            uint32_t firstPixel;
            memcpy(&firstPixel, state->vram_ptr + 1024 + 36, 4);
            if (firstPixel != UINT32_C(0xff00ff00))
                fprintf(stderr,
                        "RTT prefix old pixel tex%d program%u boundary%u "
                        "candidate%u\n",
                        textured, program, boundary, candidate);
            color(1, 1, 0xff00ff00);
            require([draw.reports getReport:1u << 24 error:&error] &&
                        [draw.reports processWithError:&error],
                    error);
            uint32_t query = report_value(0);
            assert(query && state->pgraph.draw_time == seedTime + 1);
            NSMutableData *actual = [cpp_capture(query) mutableCopy];
            if (pending)
                [actual appendData:pending];
            if (begin)
                [actual appendData:begin];
            /* A fresh Begin must validate original VRAM again after the CPU
             * prewrite callback, even though the old snapshot stays alive. */
            state->pgraph.draw_arrays_length = 1;
            require([draw beginWithError:&error], error);
            if (textured) {
                NV2AMetalPGRAPHPixelState *next =
                    [draw valueForKey:@"pixelState"];
                NV2AMetalCachedTexture *old =
                    [pixelState.textureSnapshot textureAtIndex:0];
                NV2AMetalCachedTexture *fresh =
                    [next.textureSnapshot textureAtIndex:0];
                assert(old.binding.texture != fresh.binding.texture);
            }
            require([draw endWithError:&error] &&
                        [cache submitWithError:&error] &&
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
            memcpy(&firstPixel, state->vram_ptr + 1024 + 36, 4);
            if (firstPixel != UINT32_C(0xff000000))
                fprintf(stderr,
                        "RTT prefix fresh pixel tex%d program%u boundary%u "
                        "candidate%u\n",
                        textured, program, boundary, candidate);
            color(1, 1, 0xff000000);
            require([draw.reports getReport:1u << 24 error:&error] &&
                        [draw.reports processWithError:&error],
                    error);
            query = report_value(0);
            assert(state->pgraph.draw_time == seedTime + 2 && query);
            [actual appendData:cpp_capture(query)];
            qemu_mutex_unlock(&state->pgraph.lock);
            cpp_tail = nil;
            cpp_blocker = cpp_commands = nil;
            cpp_queue = nil;
            cpp_gate = nil;
            return actual;
        }
    }
}
static void rtt_prefix_pgraph_tests(void)
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
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    IMP replacements[] = { (IMP)cpp_commit, (IMP)cpp_wait,   (IMP)cpp_producers,
                           (IMP)cpp_idle,   (IMP)cpp_submit, (IMP)cpp_raster,
                           (IMP)cpp_emit },
        originals[7];
    for (unsigned i = 0; i < 7; i++) {
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
    Method prepareMethod = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class,
        @selector(prepareSurfaceForRTTSnapshot:frame:error:));
    Method markMethod = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class, @selector(markRTTSnapshotCaptured:error:));
    assert(prepareMethod && markMethod);
    rttp_prepare_original =
        (void *)method_setImplementation(prepareMethod, (IMP)rttp_prepare);
    rttp_mark_original =
        (void *)method_setImplementation(markMethod, (IMP)rttp_mark);
    unsigned pairs = 0;
    @try {
        for (unsigned test = 0; test < 6; test++) {
            unsigned program = test == 1 || test == 2 || test == 4;
            unsigned boundary = test == 2 ? 1 :
                                test == 3 ? 2 :
                                test == 4 ? 4 :
                                test == 5 ? 3 :
                                            0;
            NSData *reference = rttp_run(program, boundary, NO);
            NSData *candidate = rttp_run(program, boundary, YES);
            if (![reference isEqualToData:candidate]) {
                fprintf(
                    stderr,
                    "RTT prefix PGRAPH pair%u program%u boundary%u mismatch\n",
                    test, program, boundary);
                abort();
            }
            pairs++;
        }
    } @finally {
        method_setImplementation(prepareMethod, (IMP)rttp_prepare_original);
        method_setImplementation(markMethod, (IMP)rttp_mark_original);
        if (cpp_gate)
            cpp_gate.signaledValue = 1;
        for (unsigned i = 0; i < 7; i++)
            method_setImplementation(methods[i], originals[i]);
        cpp_commands = cpp_blocker = nil;
        cpp_tail = nil;
        cpp_queue = nil;
        cpp_gate = nil;
        cpp_inject = cpp_fail_emit = cpp_release_on_wait = NO;
    }
    printf("RTT prefix PGRAPH: %u exact "
           "framebuffer/zeta/Current/constants/dirty/query pairs; legacy RTT "
           "capture reference, real dirty GPU source/private copy, queued XF "
           "source CPUwrite at gated raster, Restore/retry/prior-raster and "
           "dirty-source fallback PASS\n",
           pairs);
    groups += pairs;
}
#endif
