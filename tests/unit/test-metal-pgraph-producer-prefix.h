/* Native snapshots of an older producer while sealed tail/raster work stays
 * unsubmitted. SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PGRAPH_PRODUCER_PREFIX_H
#define TEST_METAL_PGRAPH_PRODUCER_PREFIX_H

static id ppp_queue;
static NV2AMetalCommands *ppp_commands;
static unsigned ppp_commits, ppp_buffers, ppp_waits;
static NSObject *__weak ppp_life2;
static NSObject *__weak ppp_life3;
static NSObject *__weak ppp_retired2;
static NSObject *__weak ppp_retired3;
static void (*ppp_original_commit)(id, SEL, const id<MTL4CommandBuffer> *,
                                   NSUInteger, MTL4CommitOptions *);
static BOOL (*ppp_original_wait)(id, SEL, NV2AMetalSubmission *, NSError **);
static BOOL (*ppp_original_producers)(id, SEL, NV2AMetalSubmission *,
                                      NSError **);
static BOOL (*ppp_original_idle)(id, SEL, NSError **);
static void ppp_commit(id object, SEL selector,
                       const id<MTL4CommandBuffer> *buffers, NSUInteger count,
                       MTL4CommitOptions *options)
{
    if (object == ppp_queue) {
        ppp_commits++;
        ppp_buffers += count;
    }
    ppp_original_commit(object, selector, buffers, count, options);
}
static BOOL ppp_wait(id object, SEL selector, NV2AMetalSubmission *receipt,
                     NSError **error)
{
    ppp_waits += object == ppp_commands;
    return ppp_original_wait(object, selector, receipt, error);
}
static BOOL ppp_producers(id object, SEL selector, NV2AMetalSubmission *receipt,
                          NSError **error)
{
    ppp_waits += object == ppp_commands;
    return ppp_original_producers(object, selector, receipt, error);
}
static BOOL ppp_idle(id object, SEL selector, NSError **error)
{
    ppp_waits += object == ppp_commands;
    return ppp_original_idle(object, selector, error);
}
static uint32_t ppp_word(NSUInteger address)
{
    uint32_t value;
    memcpy(&value, state->vram_ptr + address, sizeof(value));
    return value;
}
static void ppp_tail(NV2AMetalSurfaceCache *cache, NV2AMetalCommands *blocker,
                     MTL4RenderPassDescriptor *pass,
                     NV2AMetalPixelShader *pixel, NV2AMetalGeometry *geometry,
                     NV2AMetalDrawState *raster, unsigned ordinal,
                     NSError **error)
{
    @autoreleasepool {
        NV2AMetalCommands *commands = cache.commands;
        require([cache beginRasterProducersWithError:error], *error);
        require([cache prepareGPUWriteAtAddress:60000 + ordinal * 4
                                         length:4
                                          error:error],
                *error);
        require([commands orderAfterSubmission:blocker.lastSubmitted
                                  fromCommands:blocker
                                         error:error],
                *error);
        NSObject *lifetime = [NSObject new];
        if (ordinal == 2)
            ppp_life2 = lifetime;
        else
            ppp_life3 = lifetime;
        require([commands keepAlive:lifetime error:error], *error);
        /* Standalone immutable upload, separate from cached upload pages. */
        NSMutableData *data = [NSMutableData dataWithLength:70000];
        memset(data.mutableBytes, 0x11 * ordinal, data.length);
        NSUInteger offset;
        id<MTLBuffer> upload = [commands uploadBytes:data.bytes
                                              length:data.length
                                              offset:&offset
                                               error:error];
        require(upload != nil, *error);
        id<MTL4ComputeCommandEncoder> copy =
            [commands.commandBuffer computeCommandEncoder];
        require(copy != nil, *error);
        [copy barrierAfterQueueStages:MTLStageAll
                         beforeStages:MTLStageBlit
                    visibilityOptions:MTL4VisibilityOptionDevice];
        [copy copyFromBuffer:upload
                 sourceOffset:offset
                     toBuffer:cache.vram
            destinationOffset:60000 + ordinal * 4
                         size:4];
        [copy barrierAfterStages:MTLStageBlit
               beforeQueueStages:MTLStageAll
               visibilityOptions:MTL4VisibilityOptionDevice];
        [copy endEncoding];
        require([cache prepareRasterPass:pass
                                 targets:@[ surfaces.color ]
                                   error:error],
                *error);
        NV2AMetalVertex point = { 0 };
        point.clip[0] = 2.5f / 4 - 1;
        point.clip[1] = 1 - 2.5f / 4;
        point.clip[2] = .5f;
        point.clip[3] = point.point_size = 1;
        point.screen[0] = point.screen[1] = 2.5f;
        point.color[0][ordinal == 2 ? 1 : 2] = point.color[0][3] = 1;
        id<MTLBuffer> vertices =
            [commands.device newBufferWithBytes:&point
                                         length:sizeof(point)
                                        options:MTLResourceStorageModeShared];
        NV2AMetalGeometryRasterConfig config = { .front = NV2AMetalPolygonFill,
                                                 .back = NV2AMetalPolygonFill,
                                                 .lineWidth = 1 };
        NSArray<NV2AMetalGeometryResult *> *results =
            [geometry encodeNativeRasterVertices:vertices
                                           count:1
                                       primitive:NV2AMetalPrimitivePoints
                                          config:&config
                                          smooth:YES
                                  firstProvoking:NO
                                    zPerspective:NO
                                        commands:commands
                                           error:error];
        require(results.count == 1, *error);
        NV2AMetalPixelUniforms u = { 0 };
        u.combiner.final_inputs[0] = PS_REGISTER_V0;
        u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
        u.smooth_shading = 1;
        u.depth_format = NV2AMetalPixelDepthD24;
        u.surface_scale[0] = u.surface_scale[1] = 1;
        u.clip_range[1] = u.clip_range[3] = 16777215;
        u.clip_regions[0][2] = u.clip_regions[0][3] = 8;
        for (unsigned i = 0; i < 4; i++) {
            u.textures[i].dimension = 2;
            u.textures[i].scale = 1;
        }
        NV2AMetalPixelTexture textures[4] = { 0 };
        NV2AMetalPixelDraw *prepared =
            [pixel prepareGeometry:results[0]
                              offset:0
                               count:1
                            uniforms:&u
                            textures:textures
                                pass:pass
                           drawState:raster
                         rasterClass:NV2AMetalPixelRasterDirectPoint
                ignorePolygonCulling:NO
                            commands:commands
                               error:error];
        require(prepared != nil, *error);
        id<MTL4RenderCommandEncoder> encoder = [commands beginRasterPass:pass
                                                                   error:error];
        require(encoder != nil, *error);
        [encoder barrierAfterQueueStages:MTLStageAll
                            beforeStages:MTLStageVertex | MTLStageFragment
                       visibilityOptions:MTL4VisibilityOptionDevice];
        require([prepared encodeWithRenderEncoder:encoder
                                         commands:commands
                                            error:error],
                *error);
        [encoder barrierAfterStages:MTLStageVertex | MTLStageFragment
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
        require([cache markWritten:surfaces.color error:error], *error);
        [cache endRasterProducers];
        require([cache checkpointWithError:error], *error);
    }
}
static void snapshot_producer_prefix_tests(void)
{
    unsigned cases = 0;
    for (unsigned textured = 0; textured < 2; textured++) {
        NSData *referencePending = nil, *referenceBegin = nil,
               *referencePixels = nil;
        /* Full reference, prefix/full-wait, prefix/cancel/restore/retry. */
        for (unsigned mode = 0; mode < 3; mode++) {
            @autoreleasepool {
                ppp_retired2 = ppp_retired3 = nil;
                fixture();
                PGRAPHState *pg = &state->pgraph;
                NSError *error = nil;
                if (textured) {
                    texture_registers(
                        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
                    cpu_write(32768, 256);
                    memset(state->vram_ptr + 32768, 0x3c, 256);
                }
                cpu_write(60008, 8);
                memset(state->vram_ptr + 60008, 0x5a, 8);
                qemu_mutex_lock(&pg->lock);
                NV2AMetalSurfaceCache *cache = surfaces.cache;
                NV2AMetalCommands *commands = cache.commands;
                /* Remove attachment initialization from the measured batch. */
                require([surfaces prepareColor:YES
                                          zeta:NO
                                  forRendering:NO
                                         error:&error] &&
                            [cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
                require([draw beginWithError:&error], error);
                NV2AMetalSurfaceRecording *head;
                if (textured) {
                    NV2AMetalPGRAPHPixelState *captured =
                        [draw valueForKey:@"pixelState"];
                    head = [captured.textureSnapshot textureAtIndex:0]
                               .producerRecording;
                } else {
                    require([draw prepareVertexStateChangeWithError:&error],
                            error);
                    NV2AMetalPendingJournal *pending =
                        [draw valueForKey:@"pending"];
                    head =
                        ((NV2AMetalPendingSpan *)pending.retainedStreams[0][0])
                            .producerRecording;
                }
                assert(head && !head.submitted &&
                       commands.sealedBufferCount == 1);
                NSData *vertex = draw.vertexSnapshot;
                NV2AMetalCommands *blocker =
                    [[NV2AMetalCommands alloc] initWithDevice:commands.device
                                                        error:&error];
                require(blocker != nil, error);
                Ivar queueIvar = class_getInstanceVariable(
                    NV2AMetalCommands.class, "_queue");
                id<MTL4CommandQueue> queue =
                    object_getIvar(commands, queueIvar);
                id<MTL4CommandQueue> blockedQueue =
                    object_getIvar(blocker, queueIvar);
                id<MTLSharedEvent> gate = [commands.device newSharedEvent];
                assert(gate && queue && blockedQueue);
                [blockedQueue waitForEvent:gate value:1];
                require([blocker beginWithError:&error] &&
                            [blocker submitWithError:&error],
                        error);
                MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
                pass.colorAttachments[0].texture =
                    surfaces.color.transfer.texture;
                pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                NV2AMetalPixelShader *pixel = [[NV2AMetalPixelShader alloc]
                    initWithDevice:commands.device
                       colorFormat:surfaces.color.transfer.texture.pixelFormat
                       depthFormat:MTLPixelFormatInvalid
                       sampleCount:1
                             error:&error];
                NV2AMetalGeometry *geometry =
                    [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                        error:&error];
                NV2AMetalDrawConfig config = { 0 };
                config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
                NV2AMetalDrawState *raster =
                    [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                        config:&config
                                                         error:&error];
                require(pixel && geometry && raster, error);
                ppp_tail(cache, blocker, pass, pixel, geometry, raster, 2,
                         &error);
                ppp_tail(cache, blocker, pass, pixel, geometry, raster, 3,
                         &error);
                assert(commands.sealedBufferCount == 3 &&
                       commands.hasPendingRasterPass &&
                       (ppp_life2 && ppp_life3) && !gate.signaledValue);
                uint64_t batch = commands.batchSerial;
                ppp_queue = queue;
                ppp_commands = commands;
                ppp_commits = ppp_buffers = ppp_waits = 0;
                SEL commitSelector = @selector(commit:count:options:);
                Class queueClass = object_getClass(queue);
                Method commit =
                    class_getInstanceMethod(queueClass, commitSelector);
                class_addMethod(queueClass, commitSelector,
                                method_getImplementation(commit),
                                method_getTypeEncoding(commit));
                commit = class_getInstanceMethod(queueClass, commitSelector);
                Method wait = class_getInstanceMethod(
                    NV2AMetalCommands.class,
                    @selector(waitForSubmission:error:));
                Method producers = class_getInstanceMethod(
                    NV2AMetalCommands.class,
                    @selector(waitForProducersOfSubmission:error:));
                Method idle =
                    class_getInstanceMethod(NV2AMetalCommands.class,
                                            @selector(waitUntilIdleWithError:));
                ppp_original_commit =
                    (void *)method_setImplementation(commit, (IMP)ppp_commit);
                ppp_original_wait =
                    (void *)method_setImplementation(wait, (IMP)ppp_wait);
                ppp_original_producers = (void *)method_setImplementation(
                    producers, (IMP)ppp_producers);
                ppp_original_idle =
                    (void *)method_setImplementation(idle, (IMP)ppp_idle);
                NSData *pending, *begin;
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                    dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                      if (!gate.signaledValue)
                          gate.signaledValue =
                              2; /* Failure-only deadlock escape. */
                    });
                @try {
                    if (!mode) {
                        gate.signaledValue = 1;
                        require([cache submitWithError:&error] &&
                                    [cache waitUntilIdleWithError:&error],
                                error);
                    }
                    pending = [draw pendingSnapshotWithError:&error];
                    begin = [draw beginSnapshotWithError:&error];
                    require(pending && begin.length, error);
                    if (mode) {
                        assert(
                            !gate.signaledValue && head.producersCompleted &&
                            !head.completed && commands.batchSerial == batch &&
                            commands.hasPendingRasterPass && ppp_commits == 1 &&
                            ppp_buffers == 1 && ppp_word(60008) == 0x5a5a5a5a &&
                            ppp_word(60012) == 0x5a5a5a5a &&
                            (ppp_life2 && ppp_life3));
                        assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard,
                                                          60008, 4, NO));
                        unsigned commits = ppp_commits, waits = ppp_waits;
                        require([[draw pendingSnapshotWithError:&error]
                                    isEqualToData:pending] &&
                                    [[draw beginSnapshotWithError:&error]
                                        isEqualToData:begin],
                                error);
                        assert(ppp_commits == commits && ppp_waits == waits &&
                               !gate.signaledValue);
                        if (mode == 2) {
                            [cache cancel]; /* Sealed tail remains accepted. */
                            assert((ppp_life2 && ppp_life3) &&
                                   commands.hasPendingRasterPass);
                            ppp_retired2 = ppp_life2;
                            ppp_retired3 = ppp_life3;
                            require([draw discardForRestoreWithError:&error],
                                    error);
                            assert(!gate.signaledValue &&
                                   !commands.hasPendingRasterPass &&
                                   ppp_word(60008) == 0x5a5a5a5a &&
                                   ppp_word(60012) == 0x5a5a5a5a);
                            require(
                                [draw restoreVertexSnapshot:vertex
                                                      error:&error] &&
                                    [draw restoreBeginSnapshot:begin
                                                         error:&error] &&
                                    (!pending.length ||
                                     [draw restorePendingSnapshot:pending
                                                            error:&error]) &&
                                    [draw beginWithError:&error],
                                error);
                            pass.colorAttachments[0].texture =
                                surfaces.color.transfer.texture;
                            ppp_tail(cache, blocker, pass, pixel, geometry,
                                     raster, 2, &error);
                            ppp_tail(cache, blocker, pass, pixel, geometry,
                                     raster, 3, &error);
                        }
                        gate.signaledValue = 1;
                        if (mode == 1)
                            require([cache waitForRecording:head error:&error],
                                    error);
                        else
                            require([cache submitWithError:&error], error);
                        require([cache waitUntilIdleWithError:&error], error);
                    }
                } @finally {
                    gate.signaledValue = 1;
                    method_setImplementation(commit, (IMP)ppp_original_commit);
                    method_setImplementation(wait, (IMP)ppp_original_wait);
                    method_setImplementation(producers,
                                             (IMP)ppp_original_producers);
                    method_setImplementation(idle, (IMP)ppp_original_idle);
                    ppp_commands = nil;
                    ppp_queue = nil;
                }
                require([blocker waitUntilIdleWithError:&error], error);
                require([cache prepareCPUAccessAtAddress:1024
                                                  length:256
                                                   write:NO
                                                   error:&error],
                        error);
                NSData *pixels = [NSData dataWithBytes:state->vram_ptr + 1024
                                                length:256];
                assert(ppp_word(60008) == 0x22222222 &&
                       ppp_word(60012) == 0x33333333 &&
                       ppp_word(1024 + (2 * 8 + 2) * 4) == 0xff0000ff);
                require([[draw pendingSnapshotWithError:&error]
                            isEqualToData:pending] &&
                            [[draw beginSnapshotWithError:&error]
                                isEqualToData:begin],
                        error);
                if (!mode) {
                    referencePending = pending;
                    referenceBegin = begin;
                    referencePixels = pixels;
                } else {
                    assert([pending isEqualToData:referencePending] &&
                           [begin isEqualToData:referenceBegin] &&
                           [pixels isEqualToData:referencePixels]);
                }
                require([draw discardForRestoreWithError:&error], error);
                qemu_mutex_unlock(&pg->lock);
                cases++;
            }
            /* Foundation may autorelease the last removed object while
             * clearing ownership arrays. Drain that temporary reference after
             * full GPU/restore retirement before checking final destruction. */
            assert(!ppp_life2 && !ppp_life3 && !ppp_retired2 && !ppp_retired3);
        }
    }
    assert(cases == 6);
    groups++;
    printf("PGRAPH producer prefix: %u native XF/texture snapshot cases; three "
           "sealed sections, exact older-head capture, closed unsubmitted tail "
           "gate, repeated zero producer-queue commits/waits, full FIFO raster "
           "parity, "
           "cancel/restore/retry and upload/resource lifetime PASS\n",
           cases);
}
#endif
