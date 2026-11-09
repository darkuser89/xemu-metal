/* A completed dirty target downloads without submitting a later PGRAPH pass.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPLETED_DOWNLOAD_PGRAPH_H
#define TEST_METAL_COMPLETED_DOWNLOAD_PGRAPH_H

static BOOL cdp_reference;
static unsigned cdp_probes;
static BOOL (*cdp_can_original)(id, SEL, NSArray<NV2AMetalCachedSurface *> *);
static BOOL cdp_can(id owner, SEL selector,
                    NSArray<NV2AMetalCachedSurface *> *selected)
{
    if (owner == surfaces.cache) {
        cdp_probes++;
        if (cdp_reference)
            return NO;
    }
    return cdp_can_original(owner, selector, selected);
}
static NSData *cdp_run(BOOL write, BOOL reference)
{
    cpp_scene(NO, write ? 1 : 0);
    cdp_reference = reference;
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    cpp_commands = cache.commands;
    qemu_mutex_lock(&pg->lock);
    /* Warm B before the completed writer A, so B's later Begin cannot close
     * its own raster chain for a cold attachment upload. */
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    cpu_write(32768, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = UINT32_C(0xffff0000);
        memcpy(state->vram_ptr + 32768 + i * 4, &red, 4);
    }
    dma[0].limit = 65535 - 1024;
    pg->surface_color.offset = 32768 - 1024;
    pg->surface_color.buffer_dirty = true;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = UINT32_C(0xff00ff00);
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7u
                                                                        << 16;
    require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    NV2AMetalCachedSurface *a = surfaces.color;
    assert(a.address == 32768 && a.valid && a.dirty &&
           a.transfer.config.scale == 1);
    dpp_expect_source(UINT32_C(0xffff0000));
    pg->surface_color.offset = 0;
    pg->surface_color.buffer_dirty = true;
    require([draw beginWithError:&error], error);
    cpp_blocker = [[NV2AMetalCommands alloc] initWithDevice:cpp_commands.device
                                                      error:&error];
    require(cpp_blocker != nil, error);
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    cpp_queue = object_getIvar(cpp_commands, queue);
    id<MTL4CommandQueue> blockedQueue = object_getIvar(cpp_blocker, queue);
    cpp_gate = [cpp_commands.device newSharedEvent];
    assert(cpp_queue && blockedQueue && cpp_gate);
    [blockedQueue waitForEvent:cpp_gate value:1];
    require([cpp_blocker beginWithError:&error] != nil, error);
    id<MTLBuffer> blocked =
        [cpp_commands.device newBufferWithLength:4
                                         options:MTLResourceStorageModeShared];
    require(blocked && [cpp_blocker addResource:blocked error:&error], error);
    memset(blocked.contents, 0xcd, 4);
    id<MTL4ComputeCommandEncoder> e =
        [cpp_blocker.commandBuffer computeCommandEncoder];
    assert(e);
    [e fillBuffer:blocked range:NSMakeRange(0, 4) value:0x5a];
    [e endEncoding];
    require([cpp_blocker submitWithError:&error], error);
    id<MTLSharedEvent> watchdog = cpp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    cpp_inject = YES;
    cpp_release_on_wait = NO;
    require([draw flushDrawWithError:&error], error);
    assert(!cpp_inject && cpp_tail && !cpp_tail.submitted &&
           cpp_commands.hasPendingRasterPass && !cpp_gate.signaledValue &&
           surfaces.color != a && surfaces.color.address == 1024 && a.dirty);
    pg->draw_arrays_length = 0;
    cpp_commits = cpp_buffers = cpp_full = cpp_waits = cdp_probes = 0;
    uint64_t batch = cpp_commands.batchSerial;
    uint64_t serial = cpp_commands.recordingSerial;
    uint64_t generation =
        [[cache valueForKey:@"generation"] unsignedLongLongValue];
    cpp_release_on_wait = reference;
    require([cache resolveCPUAccessAtAddress:32768
                                      length:256
                                       write:write
                                       error:&error],
            error);
    cpp_release_on_wait = NO;
    /* The actual GPU-green RAM bytes precede route/cursor assertions. */
    dpp_expect_source(UINT32_C(0xff00ff00));
    if (!reference) {
        NSData *untouched = cpp_color_pixels(&error);
        require(untouched != nil, error);
        for (unsigned i = 0; i < 64; i++)
            assert(((const uint32_t *)untouched.bytes)[i] ==
                   UINT32_C(0xffff0000));
        assert(!cpp_gate.signaledValue && !cpp_full && !cpp_commits &&
               !cpp_waits && !cpp_tail.submitted && !cpp_tail.completed &&
               cpp_commands.batchSerial == batch &&
               cpp_commands.recordingSerial == serial &&
               cpp_commands.hasPendingRasterPass &&
               *(uint32_t *)blocked.contents == UINT32_C(0xcdcdcdcd) &&
               ![cpp_blocker.lastSubmitted completedWithError:NULL]);
    } else {
        assert(cpp_gate.signaledValue == 1 && cpp_full && cpp_commits &&
               cpp_waits && cpp_tail.completed);
    }
    assert(cdp_probes);
    uint64_t version = 0;
    require([cache sourceVersionAtAddress:32768
                                   length:256
                                  version:&version
                                    error:&error],
            error);
    assert([[cache valueForKey:@"generation"] unsignedLongLongValue] ==
           generation + write);
    if (write) {
        assert(version == generation + 1);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t blue = UINT32_C(0xff0000ff);
            memcpy(state->vram_ptr + 32768 + i * 4, &blue, 4);
        }
    }
    NSData *begin = [draw beginSnapshotWithError:&error];
    NSData *pending = [draw pendingSnapshotWithError:&error];
    NSData *vertex = draw.vertexSnapshot;
    require(begin && pending && vertex, error);
    if (!reference)
        assert(!cpp_gate.signaledValue && !cpp_full && !cpp_tail.submitted);
    cpp_gate.signaledValue = 1;
    require([draw endWithError:&error] && [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error] &&
                [cpp_blocker waitUntilIdleWithError:&error] &&
                [cache prepareCPUAccessAtAddress:1024
                                          length:256
                                           write:NO
                                           error:&error] &&
                [cache prepareCPUAccessAtAddress:4096
                                          length:256
                                           write:NO
                                           error:&error],
            error);
    color(1, 1, UINT32_C(0xff00ff00));
    dpp_expect_source(write ? UINT32_C(0xff0000ff) : UINT32_C(0xff00ff00));
    uint64_t after = 0;
    require([cache sourceVersionAtAddress:32768
                                   length:256
                                  version:&after
                                    error:&error],
            error);
    assert(after == version);
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t count = report_value(0);
    assert(count && pg->draw_time == 1);
    NSMutableData *actual = [cpp_capture(count) mutableCopy];
    [actual appendData:begin];
    [actual appendData:pending];
    [actual appendData:vertex];
    if (write) {
        /* A later real Begin must sample the post-callback CPU bytes. */
        texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
        pg->draw_arrays_length = 1;
        require([draw beginWithError:&error] && [draw endWithError:&error] &&
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
        color(1, 1, UINT32_C(0xff0000ff));
        require([draw.reports getReport:1u << 24 error:&error] &&
                    [draw.reports processWithError:&error],
                error);
        count = report_value(0);
        assert(count && pg->draw_time == 2);
        [actual appendData:cpp_capture(count)];
    }
    qemu_mutex_unlock(&pg->lock);
    cpp_tail = nil;
    cpp_blocker = cpp_commands = nil;
    cpp_queue = nil;
    cpp_gate = nil;
    return actual;
}
static void completed_download_pgraph_tests(void)
{
    fixture();
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:NULL];
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    Method methods[] = {
        class_getInstanceMethod(object_getClass(object_getIvar(probe, queue)),
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
            NV2AMetalSurfaceCache.class,
            sel_registerName("canDownloadCompletedSurfaces:"))
    };
    IMP replacements[] = { (IMP)cpp_commit, (IMP)cpp_wait,   (IMP)cpp_producers,
                           (IMP)cpp_idle,   (IMP)cpp_submit, (IMP)cpp_raster,
                           (IMP)cdp_can },
        originals[7];
    for (unsigned i = 0; i < 7; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    cpp_commit_original = (void *)originals[0];
    cpp_wait_original = (void *)originals[1];
    cpp_producers_original = (void *)originals[2];
    cpp_idle_original = (void *)originals[3];
    cpp_full_original = (void *)originals[4];
    cpp_raster_original = (void *)originals[5];
    cdp_can_original = (void *)originals[6];
    for (unsigned i = 0; i < 7; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned write = 0; write < 2; write++) {
            NSData *old = cdp_run(write, YES);
            NSData *actual = cdp_run(write, NO);
            assert([old isEqualToData:actual]);
        }
    } @finally {
        if (cpp_gate)
            cpp_gate.signaledValue = 1;
        for (unsigned i = 0; i < 7; i++)
            method_setImplementation(methods[i], originals[i]);
        cdp_reference = NO;
        cpp_inject = cpp_release_on_wait = NO;
        cpp_tail = nil;
        cpp_commands = cpp_blocker = nil;
        cpp_queue = nil;
        cpp_gate = nil;
    }
    groups += 2;
    puts("Completed download PGRAPH:2 legacy-full A/B pairs; finished dirty "
         "PGRAPH clear A downloads GPUgreen while real disjoint raster B stays "
         "gated/unsubmitted; CPUread/write, framebuffer/zeta/Current/context/"
         "query/snapshots and fresh CPUblue sampling PASS");
}
#endif
