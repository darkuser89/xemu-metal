/* Compact smooth polygon fill against the unchanged full-record expansion.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_POLYGON_FILL_PGRAPH_H
#define TEST_METAL_COMPACT_POLYGON_FILL_PGRAPH_H

/* Reuse only the established scene, counter and legacy per-primitive adapters.
 * This geometry hook calls the original compute selector on the reference. */
static NSArray *cff_geometry_spy(id object, SEL selector,
                                 NV2AMetalVertexSlice *slice,
                                 enum NV2AMetalPrimitive primitive,
                                 const NV2AMetalGeometryRasterConfig *config,
                                 BOOL smooth, BOOL first, BOOL perspective,
                                 NV2AMetalCommands *commands, NSError **error)
{
    cpw_adapters++;
    unsigned pack = cpw_pack, expand = cpw_expand, gather = cpw_gather,
             faces = cpw_faces;
    id<MTLBuffer> source = slice.buffer;
    NSUInteger offset = slice.firstVertex;
    NSArray<NV2AMetalGeometryResult *> *results;
    if (cpw_reference) {
        if (slice.indexedVertices) {
            NV2AMetalVertexStream *stream =
                [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                        limit:slice.vertexCount
                                                        error:error];
            if (!stream || ![stream appendIndexedVertices:slice.indexedVertices
                                                    first:slice.firstVertex
                                                    count:slice.vertexCount
                                                    error:error])
                return nil;
            source = [stream encodeWithCommands:commands error:error];
            if (!source)
                return nil;
            offset = 0;
        }
        results = [object encodeRasterVertices:source
                                         first:offset
                                         count:slice.vertexCount
                                     primitive:primitive
                                        config:config
                                        smooth:smooth
                                firstProvoking:first
                                  zPerspective:perspective
                                      commands:commands
                                         error:error];
    } else
        results = cpw_geometry(object, selector, slice, primitive, config,
                               smooth, first, perspective, commands, error);
    if (!results)
        return nil;
    cpw_mixed = config->front != config->back;
    cpw_genuine = primitive == NV2AMetalPrimitivePolygon;
    assert(results.count == (cpw_mixed ? 2u : 1u));
    assert(config->polygonSmooth);
    unsigned fills = 0, packs = 0;
    for (NV2AMetalGeometryResult *g in results) {
        if (g.polygonMode == NV2AMetalPolygonFill) {
            fills++;
            if (!cpw_reference) {
                assert(
                    g.compactPolygons && !g.compactLines &&
                    g.expandedPolygons && !g.expandedLines &&
                    g.vertices == slice.buffer &&
                    g.indexedVertices == slice.indexedVertices &&
                    g.sourcePrimitive == primitive &&
                    g.polygonCoverage.storageMode == MTLStorageModePrivate &&
                    g.polygonCoverage.length ==
                        g.vertexCount / 6 * sizeof(NV2AMetalCompactPolygon) &&
                    g.polygonProjections.length ==
                        g.vertexCount / 6 * sizeof(NV2AMetalPolygonProjection));
                packs++;
            }
        } else if (!cpw_reference) {
            packs += g.compactLines;
            assert(g.compactLines || g.directQuadOptions ||
                   g.directPolygonOptions);
        }
        if (!cpw_reference && slice.indexedVertices) {
            assert(g.indexedVertices == slice.indexedVertices &&
                   g.physicalVertexCount ==
                       slice.indexedVertices.physicalVertexCount &&
                   g.indexOffset == slice.firstVertex && !g.firstVertex);
            cpw_indexed++;
        }
    }
    assert(fills == 1);
    if (cpw_reference)
        assert(cpw_pack == pack && cpw_expand - expand == results.count &&
               cpw_gather - gather == !!slice.indexedVertices);
    else
        assert(cpw_pack - pack == packs && cpw_expand == expand &&
               cpw_gather == gather);
    assert(cpw_faces - faces ==
           (cpw_genuine ? (cpw_reference ? results.count : 1u) : 0u));
    cpw_expected_packs = packs;
    cpw_expected_emits = cpw_mixed && !cpw_genuine ?
                             results[0].primitiveCount * 2 :
                             results.count;
    cpw_expected_prepares = cpw_reference ? cpw_expected_emits : results.count;
    pr_expected_emits = cpw_expected_emits;
    pr_fail_prepare = cpw_failure == 1 ? cpw_expected_prepares : 0;
    pr_fail_emit = cpw_failure == 2 ? cpw_expected_emits : 0;
    return results;
}

static void cff_scene(unsigned topology, unsigned profile, unsigned program,
                      BOOL indexed, unsigned count, BOOL homogeneous)
{
    cpw_scene(topology, profile, program, indexed, count, homogeneous);
    PGRAPHState *pg = &state->pgraph;
    unsigned front = profile == 1 ? (topology == 5 ? 2 : 1) : 0;
    unsigned back = profile == 2 ? 2 : 0;
    pg->regs_[NV_PGRAPH_SETUPRASTER] &= ~(NV_PGRAPH_SETUPRASTER_FRONTFACEMODE |
                                          NV_PGRAPH_SETUPRASTER_BACKFACEMODE);
    pg->regs_[NV_PGRAPH_SETUPRASTER] |=
        front | back << 2 | NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
}

static NSData *cff_run(unsigned topology, unsigned profile, unsigned program,
                       BOOL indexed, unsigned count, unsigned boundary,
                       unsigned failure, BOOL reference, NSData **pending,
                       NSData **vertex, NSData **begin, NSData **failed)
{
    cff_scene(topology, profile, program, indexed, count, profile == 0);
    cpw_reference = reference;
    cpw_failure = failure;
    cpw_reset_attempt();
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    if (boundary) {
        if (indexed)
            pg->inline_elements_length = 5;
        else
            pg->draw_arrays_count[0] = 5;
        require([draw beginWithError:&error] &&
                    [draw prepareVertexStateChangeWithError:&error],
                error);
        NSData *p = [draw pendingSnapshotWithError:&error];
        NSData *v = draw.vertexSnapshot;
        NSData *b = [draw beginSnapshotWithError:&error];
        require(p && v && b, error);
        if (reference) {
            *pending = p;
            *vertex = v;
            *begin = b;
        } else
            assert([*pending isEqualToData:p] && [*vertex isEqualToData:v] &&
                   [*begin isEqualToData:b]);
        require([draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:v error:&error] &&
                    [draw restoreBeginSnapshot:b error:&error] &&
                    [draw restorePendingSnapshot:p error:&error] &&
                    [draw beginWithError:&error],
                error);
        if (indexed)
            pg->inline_elements_length = count;
        else
            pg->draw_arrays_count[0] = count;
    } else if (failure)
        require([draw beginWithError:&error], error);
    if (failure) {
        unsigned injected = pr_injected;
        assert(![draw endWithError:&error] && error &&
               pr_injected == injected + 1 && !pg->draw_time &&
               pr_prepare_calls == cpw_expected_prepares &&
               pr_packet_inits == pr_prepare_calls &&
               pr_emit_calls == (failure == 1 ? 0 : cpw_expected_emits));
        error = nil;
        NSData *p = [draw pendingSnapshotWithError:&error];
        require(p != nil, error);
        if (reference)
            *failed = p;
        else
            assert([*failed isEqualToData:p]);
        cpw_failure = 0;
        cpw_reset_attempt();
    }
    require(boundary || failure ? [draw endWithError:&error] :
                                  [draw drawWithError:&error],
            error);
    assert(cpw_adapters && pg->draw_time == 1 &&
           pr_prepare_calls == cpw_expected_prepares &&
           pr_packet_inits == pr_prepare_calls &&
           pr_emit_calls == cpw_expected_emits);
    if (!reference) {
        assert(cpw_pack == cpw_expected_packs);
        if (indexed && program < 2 && count >= 12)
            assert(cpw_indexed);
    }
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    if (program == 2)
        expect_context(191, 15, count, YES);
    return cpw_capture(query);
}
static NSData *cff_attachment_switch(BOOL reference)
{
    cff_scene(0, 0, 1, YES, 13, YES);
    dma[0].limit = 16383;
    cpu_write(8192, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = UINT32_C(0xffff0000);
        memcpy(state->vram_ptr + 8192 + i * 4, &red, 4);
    }
    cpw_reference = reference;
    cpw_failure = 0;
    cpw_reset_attempt();
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.cache.commands;
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    /* Both attachments must already be uploaded: a cold new attachment would
     * flush the prior chain during Begin and hide the late pass boundary. */
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error],
            error);
    pg->surface_color.offset = 8192 - 1024;
    pg->surface_color.buffer_dirty = true;
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [surfaces.cache submitWithError:&error] &&
                [surfaces.cache waitUntilIdleWithError:&error],
            error);
    pg->surface_color.offset = 0;
    pg->surface_color.buffer_dirty = true;
    require([draw drawWithError:&error], error);
    assert(commands.hasPendingRasterPass && commands.sealedBufferCount &&
           !commands.commandBuffer && pg->draw_time == 1);
    uint64_t serial = commands.recordingSerial;
    NV2AMetalSubmission *old = commands.lastSubmitted;
    /* No fixture reset, flush or CPU callback may hide the attachment
     * mismatch after the second geometry producer has been constructed. */
    pg->surface_color.offset = 8192 - 1024;
    pg->surface_color.buffer_dirty = true;
    cpw_reset_attempt();
    cpw_switches = 0;
    cpw_watch_switch = YES;
    require([draw drawWithError:&error], error);
    cpw_watch_switch = NO;
    /* Submitted compact carriers continue without a second geometry encode. */
    assert(commands.recordingSerial > serial && commands.lastSubmitted != old &&
           cpw_switches == 1 && pg->draw_time == 2 && cpw_adapters &&
           cpw_fetches == 1 && cpw_xfs == 1 && (reference || cpw_pack == 1));
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(query);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(8192, 256);
    read_vram(4096, 256);
    NSMutableData *data = [cpw_capture(query) mutableCopy];
    [data appendBytes:state->vram_ptr + 8192 length:256];
    return data;
}

static NSData *cff_report_pressure(BOOL reference)
{
    cff_scene(0, 0, 1, YES, 13, YES);
    cpw_reference = reference;
    cpw_failure = 0;
    cpw_reset_attempt();
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *commands = cache.commands;
    NV2AMetalPGRAPHReports *saved = draw.reports;
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:reference ? 1024 : 1];
    assert(reports);
    [draw setValue:reports forKey:@"reports"];
    PGRAPHState *pg = &state->pgraph;
    NSData *result = nil;
    @try {
        qemu_mutex_lock(&pg->lock);
        require([draw drawWithError:&error], error);
        NSArray *slots = [reports valueForKey:@"counterSlots"];
        NV2AMetalVisibilityCounter *first = slots[0];
        id<MTLBuffer> pool = reports.visibilityBuffer;
        NV2AMetalSurfaceRecording *token = [first valueForKey:@"token"];
        assert(pool && pool.length == (reference ? 8192 : 8) &&
               slots.count == (reference ? 1024u : 1u) &&
               first.buffer == pool && !first.offset && token &&
               !token.submitted && !token.completed &&
               commands.hasPendingRasterPass);
        uint64_t serial = commands.recordingSerial;
        uint64_t batch = commands.batchSerial;
        NV2AMetalSubmission *receipt = commands.lastSubmitted;
        cpw_reset_attempt();
        cpw_switches = 0;
        cpw_watch_switch = YES;
        require([draw drawWithError:&error], error);
        cpw_watch_switch = NO;
        assert(pg->draw_time == 2 && cpw_fetches == 1 && cpw_xfs == 1 &&
               !cpw_switches && reports.visibilityBuffer == pool);
        if (reference) {
            if (commands.batchSerial != batch ||
                commands.lastSubmitted != receipt || first.buffer != pool ||
                token.submitted || token.completed)
                fprintf(stderr,
                        "Compact wire pressure reference "
                        "recording%llu->%llu batch%llu->%llu receiptSame%d "
                        "poolOwned%d firstSubmitted%d firstCompleted%d\n",
                        (unsigned long long)serial,
                        (unsigned long long)commands.recordingSerial,
                        (unsigned long long)batch,
                        (unsigned long long)commands.batchSerial,
                        commands.lastSubmitted == receipt, first.buffer == pool,
                        token.submitted, token.completed);
            /* Each new section has a new recording serial even without a
             * commit. The stable batch/receipt and live counter prove that
             * the large pool did not introduce a submission boundary. */
            assert(commands.recordingSerial > serial &&
                   commands.batchSerial == batch &&
                   commands.lastSubmitted == receipt && first.buffer == pool &&
                   !token.submitted && !token.completed);
        } else {
            NV2AMetalVisibilityCounter *second =
                [[reports valueForKey:@"counterSlots"] firstObject];
            /* The submitted producer is reused after the real counter drain. */
            assert(commands.recordingSerial > serial &&
                   commands.batchSerial != batch &&
                   commands.lastSubmitted != receipt && token.completed &&
                   !first.buffer &&
                   [[first valueForKey:@"captured"] boolValue] &&
                   [[first valueForKey:@"value"] unsignedLongLongValue] > 0 &&
                   second != first && second.buffer == pool && !second.offset &&
                   cpw_pack == 1 && cpw_adapters == 1);
        }
        require([reports getReport:1u << 24 error:&error] &&
                    [reports processWithError:&error],
                error);
        uint32_t query = report_value(0);
        assert(query);
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        read_vram(4096, 256);
        result = cpw_capture(query);
    } @finally {
        [draw setValue:saved forKey:@"reports"];
        cpw_watch_switch = NO;
    }
    return result;
}

static __weak NV2AMetalSurfaceCache *cff_begin_cache;
static BOOL cff_begin_reject;
static unsigned cff_begin_rejections;
static NSError *cff_begin_failure;
static BOOL (*cff_begin_original)(id, SEL, NSError **);
static BOOL cff_begin_spy(id object, SEL selector, NSError **error)
{
    if (object == cff_begin_cache && cff_begin_reject) {
        assert(!((NV2AMetalSurfaceCache *)object).commands.commandBuffer);
        cff_begin_reject = NO;
        cff_begin_rejections++;
        if (error)
            *error = cff_begin_failure;
        return NO;
    }
    return cff_begin_original(object, selector, error);
}

static NSData *cff_pressure_begin_failure(BOOL reference, NSData **prefix,
                                          uint64_t *prefixQuery)
{
    cff_scene(0, 0, 1, YES, 13, YES);
    cpw_reference = reference;
    cpw_failure = 0;
    cpw_reset_attempt();
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *commands = cache.commands;
    NV2AMetalPGRAPHReports *saved = draw.reports;
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:reference ? 1024 : 1];
    assert(reports);
    [draw setValue:reports forKey:@"reports"];
    Method method = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class, @selector(beginRecordingWithError:));
    assert(method);
    cff_begin_original = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)cff_begin_spy);
    cff_begin_cache = cache;
    cff_begin_reject = NO;
    cff_begin_rejections = 0;
    cff_begin_failure = [NSError errorWithDomain:@"test.compact-fill.begin"
                                            code:1
                                        userInfo:nil];
    NSData *result = nil;
    PGRAPHState *pg = &state->pgraph;
    @try {
        qemu_mutex_lock(&pg->lock);
        require([draw drawWithError:&error], error);
        NV2AMetalVisibilityCounter *first =
            [[reports valueForKey:@"counterSlots"] firstObject];
        NV2AMetalSurfaceRecording *token = [first valueForKey:@"token"];
        assert(first && token && !token.completed && pg->draw_time == 1 &&
               commands.hasPendingRasterPass);
        NSData *hostPrefix = cpw_capture(0);
        if (reference)
            *prefix = hostPrefix;
        else
            assert([*prefix isEqualToData:hostPrefix]);
        if (!reference) {
            cpw_reset_attempt();
            cff_begin_reject = YES;
            assert(![draw drawWithError:&error] && error == cff_begin_failure &&
                   !cff_begin_reject && cff_begin_rejections == 1 &&
                   pg->draw_time == 1 && !commands.commandBuffer &&
                   !commands.batchSerial && token.completed &&
                   [[first valueForKey:@"captured"] boolValue] &&
                   !first.buffer &&
                   [[first valueForKey:@"value"] unsignedLongLongValue] > 0 &&
                   cpw_fetches == 1 && cpw_xfs == 1 && cpw_adapters == 1 &&
                   cpw_pack == 1 && !cpw_expand && !cpw_gather &&
                   !pr_prepare_calls && !pr_packet_inits && !pr_emit_calls);
            NSArray *slots = [reports valueForKey:@"counterSlots"];
            NSIndexSet *freeSlots = [reports valueForKey:@"freeCounterSlots"];
            assert(slots.count == 1 && slots[0] == NSNull.null &&
                   freeSlots.count == 1 && freeSlots.firstIndex == 0 &&
                   [hostPrefix isEqualToData:cpw_capture(0)]);
            /* No readback or extra submission intervenes before retry. The
             * completed first GPU counter survives reuse of its pool slot. */
            *prefixQuery = [[first valueForKey:@"value"] unsignedLongLongValue];
            error = nil;
        }
        cpw_reset_attempt();
        require([draw drawWithError:&error], error);
        /* The failed candidate already accepted and committed its programmed
         * XF prefix. Retry validates Current but reuses that output; only the
         * derived carrier is regenerated. The reference has a new XF range. */
        assert(pg->draw_time == 2 && cpw_fetches == 1 &&
               cpw_xfs == (reference ? 1u : 0u) && cpw_adapters == 1 &&
               (reference ? cpw_expand == 1 && !cpw_pack :
                            cpw_pack == 1 && !cpw_expand && !cpw_gather));
        require([reports getReport:1u << 24 error:&error] &&
                    [reports processWithError:&error],
                error);
        uint32_t query = report_value(0);
        assert(query);
        if (reference) {
            if ([[first valueForKey:@"captured"] boolValue])
                *prefixQuery =
                    [[first valueForKey:@"value"] unsignedLongLongValue];
            else {
                assert(token.completed && first.buffer);
                memcpy(prefixQuery,
                       (const uint8_t *)first.buffer.contents + first.offset,
                       sizeof(*prefixQuery));
            }
        }
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        read_vram(4096, 256);
        result = cpw_capture(query);
    } @finally {
        method_setImplementation(method, (IMP)cff_begin_original);
        cff_begin_cache = nil;
        cff_begin_reject = NO;
        cff_begin_failure = nil;
        [draw setValue:saved forKey:@"reports"];
    }
    return result;
}

static void compact_polygon_fill_pgraph_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(probe && [probe beginWithError:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [probe.commandBuffer computeCommandEncoder];
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalGeometry.class,
            @selector(encodeNativeRasterSlice:primitive:config:smooth:
                      firstProvoking:zPerspective:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            @selector(
                prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                rasterClass:ignorePolygonCulling:commands:error:)),
        class_getInstanceMethod(NV2AMetalPixelDraw.class,
                                sel_registerName("initForCommands:")),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(NV2AMetalPixelDraw.class,
                                @selector(encodeWithRenderEncoder:commands:
                                          firstVertex:vertexCount:error:)),
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(object_getClass(encoder),
                                @selector(setComputePipelineState:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                @selector(prepareRasterPass:targets:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:))
    };
    [encoder endEncoding];
    [probe cancel];
    IMP replacements[] = { (IMP)cff_geometry_spy, (IMP)cpw_prepare_spy,
                           (IMP)pr_init_spy,      (IMP)cpw_whole_spy,
                           (IMP)pr_range_spy,     (IMP)cpw_compute_spy,
                           (IMP)cpw_pipeline_spy, (IMP)cpw_dispatch_spy,
                           (IMP)cpw_raster_spy,   (IMP)cpw_fetch_spy,
                           (IMP)cpw_xf_spy };
    IMP originals[11];
    for (unsigned i = 0; i < 11; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    cpw_geometry = (void *)originals[0];
    pr_prepare = (void *)originals[1];
    pr_init = (void *)originals[2];
    pr_whole = (void *)originals[3];
    pr_range = (void *)originals[4];
    cpw_compute = (void *)originals[5];
    cpw_pipeline = (void *)originals[6];
    cpw_dispatch = (void *)originals[7];
    cpw_raster = (void *)originals[8];
    cpw_fetch = (void *)originals[9];
    cpw_xf = (void *)originals[10];
    cpw_names = [NSMutableDictionary new];
    cpw_encoders = [NSMutableDictionary new];
    id existing = [[draw valueForKey:@"geometry"] valueForKey:@"pipeline"];
    if (existing)
        cpw_names[[NSValue valueWithPointer:(__bridge const void *)existing]] =
            @"nv2a_expand_geometry";
    unsigned pairs = 0, orderControls = 0;
    uint64_t visible[3] = { 0 }, changedColor[3] = { 0 },
             changedDepth[3] = { 0 };
    @try {
        for (unsigned test = 0; test < 38; test++) {
            cpw_case = test;
            unsigned topology = test < 36 ? test / 6 : test == 36 ? 3 : 5;
            unsigned profile = test < 36 ? (test / 2) % 3 : 2;
            BOOL indexed = test < 36 ? (test & 1) : YES;
            unsigned program = (topology + profile + indexed) % 3;
            unsigned count = topology == 5 ? 12 : 13;
            unsigned boundary =
                test >= 36 || (indexed && (topology + profile) % 3 == 0);
            unsigned failure = test == 36 ? 1 : test == 37 ? 2 : 0;
            NSData *pending = nil, *vertex = nil, *begin = nil, *failed = nil;
            cpw_grouped = NO;
            NSData *reference =
                cff_run(topology, profile, program, indexed, count, boundary,
                        failure, YES, &pending, &vertex, &begin, &failed);
            NSData *actual =
                cff_run(topology, profile, program, indexed, count, boundary,
                        failure, NO, &pending, &vertex, &begin, &failed);
            if (![reference isEqualToData:actual]) {
                fprintf(stderr,
                        "Compact fill PGRAPH mismatch case%u topology%u "
                        "profile%u program%u indexed%d\n",
                        test, topology, profile, program, indexed);
                abort();
            }
            const uint8_t *bytes = actual.bytes;
            uint32_t query;
            memcpy(&query, bytes + actual.length - 4, 4);
            visible[program] += query;
            const uint32_t red = UINT32_C(0xffff0000),
                           initial = UINT32_C(0xffffff11);
            for (unsigned i = 0; i < 256; i++) {
                changedColor[program] +=
                    bytes[i] != ((const uint8_t *)&red)[i % 4];
                changedDepth[program] +=
                    bytes[i + 256] != ((const uint8_t *)&initial)[i % 4];
            }
            if (test < 36 && (topology == 0 || topology == 3) && profile == 2 &&
                indexed) {
                cpw_grouped = YES;
                NSData *grouped =
                    cff_run(topology, profile, program, indexed, count, 0, 0,
                            YES, &pending, &vertex, &begin, &failed);
                assert(memcmp(actual.bytes, grouped.bytes, 256));
                orderControls++;
                cpw_grouped = NO;
            }
            pairs++;
        }
        NSData *reference = cff_attachment_switch(YES);
        NSData *actual = cff_attachment_switch(NO);
        assert([reference isEqualToData:actual]);
        pairs++;
        reference = cff_report_pressure(YES);
        actual = cff_report_pressure(NO);
        assert([reference isEqualToData:actual]);
        pairs++;
        NSData *prefix = nil;
        uint64_t referencePrefix = 0, candidatePrefix = 0;
        reference = cff_pressure_begin_failure(YES, &prefix, &referencePrefix);
        actual = cff_pressure_begin_failure(NO, &prefix, &candidatePrefix);
        assert([reference isEqualToData:actual] && referencePrefix &&
               referencePrefix == candidatePrefix);
        pairs++;
    } @finally {
        for (unsigned i = 0; i < 11; i++)
            method_setImplementation(methods[i], originals[i]);
        cpw_names = cpw_encoders = nil;
        pr_packets = nil;
        pr_faces = nil;
        cpw_grouped = pr_grouped = pr_count_init = NO;
    }
    assert(pairs == 41 && orderControls == 2);
    for (unsigned program = 0; program < 3; program++)
        assert(visible[program] && changedColor[program] &&
               changedDepth[program]);
    printf("Compact smooth fill PGRAPH: %u exact "
           "Color/DepthStencil/Current/context/query pairs PASS; "
           "six topologies, Fill/Point/Wire modes, arrays/remap, original "
           "compute reference, "
           "prefix/Restore, last prepare/emit retry, attachment/report "
           "recording transitions without Fetch/XF replay\n",
           pairs);
    groups += pairs;
}
#endif
