/* Real Begin texture/XF heads survive targeted CPU writes before raster.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CPU_PREFIX_PGRAPH_H
#define TEST_METAL_CPU_PREFIX_PGRAPH_H
static NV2AMetalCommands *cpp_commands, *cpp_blocker;
static NV2AMetalSurfaceRecording *cpp_tail;
static id<MTL4CommandQueue> cpp_queue;
static id<MTLSharedEvent> cpp_gate;
static BOOL cpp_inject, cpp_fail_emit, cpp_release_on_wait;
static unsigned cpp_commits, cpp_buffers, cpp_waits, cpp_full, cpp_failures;
static void (*cpp_commit_original)(id, SEL, const id<MTL4CommandBuffer> *,
                                   NSUInteger, MTL4CommitOptions *);
static void cpp_commit(id object, SEL selector,
                       const id<MTL4CommandBuffer> *buffers, NSUInteger count,
                       MTL4CommitOptions *options)
{
    if (object == cpp_queue) {
        cpp_commits++;
        cpp_buffers += count;
    }
    cpp_commit_original(object, selector, buffers, count, options);
}
static void cpp_observe_wait(id object)
{
    if (object != cpp_commands)
        return;
    cpp_waits++;
    if (cpp_release_on_wait && !cpp_gate.signaledValue) {
        assert(cpp_commits && cpp_full);
        cpp_gate.signaledValue = 1;
    }
}
static BOOL (*cpp_wait_original)(id, SEL, NV2AMetalSubmission *, NSError **);
static BOOL cpp_wait(id object, SEL selector, NV2AMetalSubmission *receipt,
                     NSError **error)
{
    cpp_observe_wait(object);
    return cpp_wait_original(object, selector, receipt, error);
}
static BOOL (*cpp_producers_original)(id, SEL, NV2AMetalSubmission *,
                                      NSError **);
static BOOL cpp_producers(id object, SEL selector, NV2AMetalSubmission *receipt,
                          NSError **error)
{
    cpp_observe_wait(object);
    return cpp_producers_original(object, selector, receipt, error);
}
static BOOL (*cpp_idle_original)(id, SEL, NSError **);
static BOOL cpp_idle(id object, SEL selector, NSError **error)
{
    cpp_observe_wait(object);
    return cpp_idle_original(object, selector, error);
}
static BOOL (*cpp_full_original)(id, SEL, NSError **);
static BOOL cpp_submit(id object, SEL selector, NSError **error)
{
    cpp_full += object == cpp_commands;
    return cpp_full_original(object, selector, error);
}
static BOOL (*cpp_raster_original)(id, SEL, id, NSArray *, NSError **);
static BOOL cpp_raster(id object, SEL selector, id pass, NSArray *targets,
                       NSError **error)
{
    BOOL ok = cpp_raster_original(object, selector, pass, targets, error);
    if (ok && object == surfaces.cache && cpp_inject) {
        cpp_inject = NO;
        cpp_tail = surfaces.cache.recording;
        assert(cpp_tail && !cpp_gate.signaledValue);
        return [cpp_commands orderAfterSubmission:cpp_blocker.lastSubmitted
                                     fromCommands:cpp_blocker
                                            error:error];
    }
    return ok;
}
static BOOL (*cpp_emit_original)(id, SEL, id, id, NSError **);
static BOOL cpp_emit(id object, SEL selector, id encoder, id commands,
                     NSError **error)
{
    BOOL ok = cpp_emit_original(object, selector, encoder, commands, error);
    if (ok && commands == cpp_commands && cpp_fail_emit) {
        cpp_fail_emit = NO;
        cpp_failures++;
        if (error)
            *error = [NSError errorWithDomain:@"test.cpu-prefix.late-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static void cpp_scene(BOOL textured, unsigned program)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    if (program) {
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
        if (program == 2) {
            pg->enable_vertex_program_write = true;
            feedback_program(191, 15);
        } else {
            pg->regs_[NV_PGRAPH_CSV0_D] |= NV_PGRAPH_CSV0_D_RANGE_MODE;
            mov(0, 0, 0, false);
            mov(1, 3, 3, true);
        }
    }
    pg->primitive_mode = PRIM_TYPE_POINTS;
    pg->regs_[NV_PGRAPH_POINTSIZE] = 8;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 3;
    const float points[3][4] = { { 1.5f, 1.5f, 32768, 1 },
                                 { 4.5f, 1.5f, 32768, 1 },
                                 { 1.5f, 4.5f, 32768, 1 } };
    cpu_write(16384, sizeof(points));
    memcpy(state->vram_ptr + 16384, points, sizeof(points));
    pg->vertex_attributes[3] =
        (VertexAttribute){ .offset = 256,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    cpu_write(16640, 48);
    const float green[4] = { 0, 1, 0, 1 };
    for (unsigned i = 0; i < 3; i++)
        memcpy(state->vram_ptr + 16640 + i * 16, green, 16);
    if (textured) {
        texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
        cpu_write(32768, 256);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t greenPixel = UINT32_C(0xff00ff00);
            memcpy(state->vram_ptr + 32768 + i * 4, &greenPixel, 4);
        }
    }
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                      NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                      7u << 16;
    /* Keep report timestamps out of the original texture source DMA. */
    pg->dma_report = 80;
    pg->zpass_pixel_count_enable = true;
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    qemu_mutex_unlock(&pg->lock);
}
static NSData *cpp_capture(uint32_t query)
{
    PGRAPHState *pg = &state->pgraph;
    NSMutableData *data = [NSMutableData dataWithBytes:state->vram_ptr + 1024
                                                length:256];
    [data appendBytes:state->vram_ptr + 4096 length:256];
    for (unsigned i = 0; i < 16; i++)
        [data appendBytes:pg->vertex_attributes[i].inline_value length:16];
    [data appendBytes:pg->vsh_constants length:sizeof(pg->vsh_constants)];
    [data appendBytes:pg->vsh_constants_dirty
               length:sizeof(pg->vsh_constants_dirty)];
    [data appendBytes:pg->texture_dirty length:sizeof(pg->texture_dirty)];
    [data appendBytes:&query length:sizeof(query)];
    [data appendBytes:&pg->draw_time length:sizeof(pg->draw_time)];
    return data;
}
/* A private attachment needs a GPU readback. This separate queue only reads
 * its already-completed initialization/reference; it never submits the cache's
 * unsubmitted raster chain or touches original VRAM. */
static NSData *cpp_color_pixels(NSError **error)
{
    id<MTLDevice> device = surfaces.cache.commands.device;
    NV2AMetalCommands *readback =
        [[NV2AMetalCommands alloc] initWithDevice:device error:error];
    id<MTLBuffer> bytes =
        [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    if (!readback || !bytes || ![readback beginWithError:error] ||
        ![surfaces.color.transfer encodeDownloadToBuffer:bytes
                                                  offset:0
                                                 swizzle:YES
                                                    flip:NO
                                               downscale:YES
                                                commands:readback
                                                   error:error] ||
        ![readback submitWithError:error] ||
        ![readback waitUntilIdleWithError:error])
        return nil;
    return [NSData dataWithBytes:bytes.contents length:256];
}
static void cpp_pair(BOOL textured, unsigned program, unsigned boundary)
{
    NSData *reference = nil, *referencePending = nil, *referenceBegin = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            cpp_scene(textured, program);
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
            require([draw beginWithError:&error], error);
            NV2AMetalSurfaceRecording *head;
            NV2AMetalPGRAPHPixelState *pixelState =
                [draw valueForKey:@"pixelState"];
            if (textured)
                head = [pixelState.textureSnapshot textureAtIndex:0]
                           .producerRecording;
            else {
                require([draw prepareVertexStateChangeWithError:&error], error);
                NV2AMetalPendingJournal *pending =
                    [draw valueForKey:@"pending"];
                head = ((NV2AMetalPendingSpan *)pending.retainedStreams[0][0])
                           .producerRecording;
            }
            assert(head && !head.submitted && !head.cpuHazardsRetired &&
                   !cpp_commands.hasPendingRasterPass);
            NSData *pending = nil, *begin = nil, *vertex = nil;
            if (boundary == 1) {
                pending = [draw pendingSnapshotWithError:&error];
                begin = [draw beginSnapshotWithError:&error];
                vertex = draw.vertexSnapshot;
                require(pending && begin && vertex, error);
                if (!candidate) {
                    referencePending = pending;
                    referenceBegin = begin;
                } else
                    assert([referencePending isEqualToData:pending] &&
                           [referenceBegin isEqualToData:begin]);
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
            cpp_commits = cpp_buffers = cpp_waits = cpp_full = 0;
            uint64_t batch = cpp_commands.batchSerial;
            if (!candidate) {
                cpp_gate.signaledValue = 1;
                require([cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
            }
            if (!candidate) {
                NSData *frame = cpp_color_pixels(&error);
                require(frame != nil, error);
                const uint32_t *pixels = frame.bytes;
                assert(pixels[9] == UINT32_C(0xff00ff00));
            }
            NSUInteger source = textured ? 32768 : 16640;
            /* The raster tail legitimately captures the last vertex for
             * Current. Mutate only the first endpoint's disjoint source slot.
             */
            NSUInteger length = textured ? 256 : 16;
            BOOL fallback = boundary == 3;
            if (fallback) {
                cpp_release_on_wait = candidate;
                require([cache resolveCPUAccessAtAddress:1024
                                                  length:256
                                                   write:NO
                                                   error:&error],
                        error);
                if (candidate)
                    assert(cpp_gate.signaledValue == 1 && cpp_full &&
                           cpp_commits && cpp_waits && cpp_tail.completed);
                cpp_release_on_wait = NO;
            }
            require([cache resolveCPUAccessAtAddress:source
                                              length:length
                                               write:YES
                                               error:&error],
                    error);
            if (candidate && !fallback) {
                assert(!cpp_gate.signaledValue && head.cpuHazardsRetired &&
                       !cpp_tail.completed && !cpp_tail.cpuHazardsRetired &&
                       !cpp_tail.submitted && !cpp_full &&
                       cpp_commands.batchSerial == batch &&
                       cpp_commands.hasPendingRasterPass);
                if (!program && !boundary)
                    assert(cpp_commits == 1 && cpp_buffers == 1 && cpp_waits);
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
                        "CPU prefix old pixel tex%d program%u boundary%u "
                        "candidate%u\n",
                        textured, program, boundary, candidate);
            color(1, 1, 0xff00ff00);
            require([draw.reports getReport:1u << 24 error:&error] &&
                        [draw.reports processWithError:&error],
                    error);
            uint32_t query = report_value(0);
            assert(query && state->pgraph.draw_time == 1);
            NSMutableData *actual = [cpp_capture(query) mutableCopy];
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
            if (firstPixel != UINT32_C(0xff0000ff))
                fprintf(stderr,
                        "CPU prefix fresh pixel tex%d program%u boundary%u "
                        "candidate%u\n",
                        textured, program, boundary, candidate);
            color(1, 1, 0xff0000ff);
            require([draw.reports getReport:1u << 24 error:&error] &&
                        [draw.reports processWithError:&error],
                    error);
            query = report_value(0);
            assert(state->pgraph.draw_time == 2 && query);
            [actual appendData:cpp_capture(query)];
            if (program == 2)
                expect_context(191, 15, 6, YES);
            if (!candidate)
                reference = actual;
            else if (![reference isEqualToData:actual]) {
                fprintf(stderr,
                        "CPU prefix PGRAPH mismatch texture%d program%u "
                        "boundary%u\n",
                        textured, program, boundary);
                abort();
            }
            qemu_mutex_unlock(&state->pgraph.lock);
            cpp_tail = nil;
            cpp_blocker = cpp_commands = nil;
            cpp_queue = nil;
            cpp_gate = nil;
        }
    }
}
static void cpu_prefix_pgraph_tests(void)
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
    unsigned pairs = 0;
    @try {
        for (unsigned textured = 0; textured < 2; textured++)
            for (unsigned program = 0; program < 3; program++)
                for (unsigned boundary = 0; boundary < 4; boundary++) {
                    /* Writable XF boundaries deliberately use the independent
                     * serial queue; they are not a shared queued-XF head. */
                    if (!textured && program == 2)
                        continue;
                    cpp_pair(textured, program, boundary);
                    pairs++;
                }
    } @finally {
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
    printf("CPU prefix PGRAPH: %u exact old/new "
           "framebuffer/zeta/Current/constants/dirty/query pairs; "
           "real Begin texture and queued XF heads, original CPUwrite at gated "
           "raster tail, "
           "immutable old data then fresh source validation, "
           "prefix/Restore/late retry, "
           "conservative raster/download full fallback PASS\n",
           pairs);
    groups += pairs;
}
#endif
