/* Compact polygon edges versus unchanged full-record compute expansion.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_POLYGON_WIRE_PGRAPH_H
#define TEST_METAL_COMPACT_POLYGON_WIRE_PGRAPH_H

static BOOL cpw_reference, cpw_mixed, cpw_genuine;
static BOOL cpw_grouped;
static unsigned cpw_case;
static unsigned cpw_fetches, cpw_xfs;
static id (*cpw_fetch)(id, SEL, NSArray *, NV2AMetalPendingInput *, BOOL,
                       uint64_t, NSError **);
static id cpw_fetch_spy(id object, SEL selector, NSArray *prefixes,
                        NV2AMetalPendingInput *input, BOOL deduplicate,
                        uint64_t proofLanes, NSError **error)
{
    cpw_fetches++;
    return cpw_fetch(object, selector, prefixes, input, deduplicate, proofLanes,
                     error);
}
static id (*cpw_xf)(id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>,
                    NSUInteger, NSUInteger, NV2AMetalFetchResult *,
                    NV2AMetalCommands *, NSError **);
static id cpw_xf_spy(id object, SEL selector, NV2AMetalPGRAPHVertexState *state,
                     id<MTLBuffer> attributes, NSUInteger first,
                     NSUInteger count, NV2AMetalFetchResult *fetch,
                     NV2AMetalCommands *commands, NSError **error)
{
    cpw_xfs++;
    return cpw_xf(object, selector, state, attributes, first, count, fetch,
                  commands, error);
}
static BOOL cpw_watch_switch;
static unsigned cpw_switches;
static BOOL (*cpw_raster)(id, SEL, MTL4RenderPassDescriptor *, NSArray *,
                          NSError **);
static BOOL cpw_raster_spy(id object, SEL selector,
                           MTL4RenderPassDescriptor *pass, NSArray *targets,
                           NSError **error)
{
    if (cpw_watch_switch && object == surfaces.cache &&
        surfaces.cache.commands.hasPendingRasterPass &&
        ![surfaces.cache.commands rasterPassMatches:pass])
        cpw_switches++;
    return cpw_raster(object, selector, pass, targets, error);
}
static unsigned cpw_pack, cpw_expand, cpw_gather, cpw_faces, cpw_adapters,
    cpw_indexed, cpw_failure, cpw_expected_prepares, cpw_expected_emits, cpw_expected_packs;
static NSMutableDictionary<NSValue *, NSString *> *cpw_names, *cpw_encoders;
static id (*cpw_compute)(id, SEL, NSString *, NSError **);
static id cpw_compute_spy(id object, SEL selector, NSString *name,
                          NSError **error)
{
    id pipeline = cpw_compute(object, selector, name, error);
    if (pipeline)
        cpw_names[[NSValue valueWithPointer:(__bridge const void *)pipeline]] =
            name;
    return pipeline;
}
static void (*cpw_pipeline)(id, SEL, id);
static void cpw_pipeline_spy(id object, SEL selector, id pipeline)
{
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
    NSString *name =
        cpw_names[[NSValue valueWithPointer:(__bridge const void *)pipeline]];
    if (name)
        cpw_encoders[key] = name;
    else
        [cpw_encoders removeObjectForKey:key];
    cpw_pipeline(object, selector, pipeline);
}
static void (*cpw_dispatch)(id, SEL, MTLSize, MTLSize);
static void cpw_dispatch_spy(id object, SEL selector, MTLSize size,
                             MTLSize group)
{
    NSString *name =
        cpw_encoders[[NSValue valueWithPointer:(__bridge const void *)object]];
    cpw_pack += [name hasPrefix:@"nv2a_compact_"];
    cpw_expand += [name isEqualToString:@"nv2a_expand_geometry"];
    cpw_gather += [name isEqualToString:@"nv2a_vertex_stream_gather"];
    cpw_faces += [name containsString:@"polygon_face"];
    cpw_dispatch(object, selector, size, group);
}
static NSArray *(*cpw_geometry)(id, SEL, NV2AMetalVertexSlice *,
                                enum NV2AMetalPrimitive,
                                const NV2AMetalGeometryRasterConfig *, BOOL,
                                BOOL, BOOL, NV2AMetalCommands *, NSError **);
static NSArray *cpw_geometry_spy(id object, SEL selector,
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
    unsigned wire = 0, fillCompact = 0;
    for (NV2AMetalGeometryResult *g in results) {
        if (g.polygonMode == NV2AMetalPolygonLine) {
            wire++;
            NSUInteger per = cpw_genuine                          ? 6 :
                             primitive >= NV2AMetalPrimitiveQuads ? 24 :
                                                                    18;
            assert(g.verticesPerPrimitive == per &&
                   g.vertexCount == g.primitiveCount * per);
            if (!cpw_reference) {
                assert(g.compactLines && g.expandedLines &&
                       g.sourcePrimitive == primitive &&
                       g.vertices == slice.buffer &&
                       g.indexedVertices == slice.indexedVertices &&
                       g.lineCoverage.storageMode == MTLStorageModePrivate &&
                       g.lineCoverage.length ==
                           g.vertexCount / 6 * sizeof(NV2AMetalCompactLine) &&
                       !g.polygonFacing && !g.directPolygonOptions &&
                       !g.directQuadOptions && !g.directTriangles &&
                       !g.directLineMode);
                if (slice.indexedVertices) {
                    assert(g.physicalVertexCount ==
                               slice.indexedVertices.physicalVertexCount &&
                           g.indexOffset == slice.firstVertex &&
                           !g.firstVertex);
                    cpw_indexed++;
                } else
                    assert(g.firstVertex == slice.firstVertex &&
                           !g.indexOffset);
            }
        } else if (g.polygonMode == NV2AMetalPolygonFill &&
                   config->polygonSmooth) {
            if (!cpw_reference) {
                assert(g.compactPolygons && g.expandedPolygons &&
                       g.vertices == slice.buffer &&
                       g.indexedVertices == slice.indexedVertices &&
                       g.polygonCoverage.length ==
                           g.vertexCount / 6 * sizeof(NV2AMetalCompactPolygon));
            }
            fillCompact++;
        }
    }
    assert(wire == 1);
    assert(cpw_faces - faces ==
           (cpw_genuine ? (cpw_reference ? results.count : 1u) : 0u));
    if (cpw_reference)
        assert(cpw_pack == pack && cpw_expand - expand == results.count &&
               cpw_gather - gather == !!slice.indexedVertices);
    else
        assert(cpw_pack - pack == 1 + fillCompact && cpw_expand == expand &&
               cpw_gather == gather);
    cpw_expected_packs = 1 + fillCompact;
    cpw_expected_emits = cpw_mixed && !cpw_genuine ?
                             results[0].primitiveCount * 2 :
                             results.count;
    cpw_expected_prepares = cpw_reference ? cpw_expected_emits : results.count;
    pr_expected_emits = cpw_expected_emits;
    pr_fail_prepare = cpw_failure == 1 ? cpw_expected_prepares : 0;
    pr_fail_emit = cpw_failure == 2 ? cpw_expected_emits : 0;
    return results;
}
static NV2AMetalPixelDraw *cpw_prepare_spy(
    id object, SEL selector, NV2AMetalGeometryResult *geometry,
    NSUInteger offset, NSUInteger count, const NV2AMetalPixelUniforms *uniforms,
    const NV2AMetalPixelTexture *textures, MTL4RenderPassDescriptor *pass,
    NV2AMetalDrawState *state, NV2AMetalPixelRasterClass raster, BOOL ignore,
    NV2AMetalCommands *commands, NSError **error)
{
    NV2AMetalPixelDraw *packet;
    if (cpw_mixed && !cpw_genuine)
        packet = pr_prepare_spy(object, selector, geometry, offset, count,
                                uniforms, textures, pass, state, raster, ignore,
                                commands, error);
    else
        packet = pr_prepare_one(object, selector, geometry, offset, count,
                                uniforms, textures, pass, state, raster, ignore,
                                commands, error);
    if (!packet && (!error || ![(*error).domain hasPrefix:@"test."]))
        fprintf(
            stderr,
            "Compact wire prepare failure case%u reference%d "
            "sourcePrimitive%u compact%d mode%u count%lu/%lu source%lu phys%lu "
            "coverageSerial%llu commandsSerial%llu owner%d live%d\n",
            cpw_case, cpw_reference, geometry.sourcePrimitive,
            geometry.compactLines, geometry.polygonMode, (unsigned long)count,
            (unsigned long)geometry.vertexCount,
            (unsigned long)geometry.sourceVertexCount,
            (unsigned long)geometry.physicalVertexCount,
            [[geometry valueForKey:@"coverageSerial"] unsignedLongLongValue],
            (unsigned long long)commands.recordingSerial,
            [geometry valueForKey:@"coverageCommands"] == commands,
            [geometry canUseLineCoverageForCommands:commands]);
    return packet;
}
static BOOL cpw_whole_spy(id object, SEL selector, id encoder,
                          NV2AMetalCommands *commands, NSError **error)
{
    pr_emit_calls++;
    BOOL ok = pr_whole(object, selector, encoder, commands, error);
    if (ok && pr_emit_calls == pr_fail_emit) {
        pr_injected++;
        if (error)
            *error = [NSError errorWithDomain:@"test.compact-wire.last-emit"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}

static void cpw_scene(unsigned topology, unsigned profile, unsigned program,
                      BOOL indexed, unsigned count, BOOL homogeneous)
{
    unsigned front = homogeneous ? 2 : profile == 1 && topology != 5 ? 1 : 0;
    unsigned back = 2;
    if (topology == 5)
        gp_scene(front, back, program, indexed, count, 0,
                 (profile & 1 ? 1 : 2) | (profile == 2 ? 4 : 0), 0);
    else
        pm_scene(topology, front, back, program, indexed, 0, 0);
    PGRAPHState *pg = &state->pgraph;
    pg->surface_scale_factor = profile == 0 ? 2 : 1;
    if (profile == 1)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE;
    if (profile == 2) {
        pg->regs_[NV_PGRAPH_CONTROL_0] |=
            NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;
        if (!homogeneous)
            pg->regs_[NV_PGRAPH_SETUPRASTER] |=
                NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    }
    if (homogeneous && (topology + program + indexed) % 3)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |= NV_PGRAPH_SETUPRASTER_CULLENABLE |
                                            ((topology + program + indexed) % 3)
                                                << 21;
    if (topology != 5 && profile == 2) {
        cpu_write(16384, 256);
        for (unsigned i = 0; i < (indexed ? 8u : count); i++) {
            float w = .625f + (i % 4) * .25f;
            memcpy(state->vram_ptr + 16384 + i * 16 + 12, &w, 4);
        }
    }
}
static void cpw_reset_attempt(void)
{
    pr_reset_attempt();
    pr_legacy = cpw_reference;
    pr_grouped = cpw_grouped;
    pr_fail_prepare = pr_fail_emit = 0;
    cpw_pack = cpw_expand = cpw_gather = cpw_faces = cpw_adapters =
        cpw_indexed = 0;
    cpw_fetches = cpw_xfs = 0;
}
static NSData *cpw_capture(uint32_t query)
{
    NSMutableData *data = [gp_capture(query) mutableCopy];
    data.length -= sizeof(query);
    [data appendBytes:&state->pgraph.compressed_attrs
               length:sizeof(state->pgraph.compressed_attrs)];
    for (unsigned i = 0; i < 16; i++)
        [data appendBytes:&state->pgraph.vertex_attributes[i]
                               .inline_buffer_populated
                   length:sizeof(state->pgraph.vertex_attributes[i]
                                     .inline_buffer_populated)];
    [data appendBytes:&query length:sizeof(query)];
    return data;
}
static NSData *cpw_run(unsigned topology, unsigned profile, unsigned program,
                       BOOL indexed, unsigned count, unsigned boundary,
                       unsigned failure, BOOL reference, NSData **pending,
                       NSData **vertex, NSData **begin, NSData **failed)
{
    cpw_scene(topology, profile, program, indexed, count, profile == 0);
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
static void cpw_invalid_pairs(void)
{
    for (unsigned kind = 0; kind < 2; kind++) {
        NSData *reference = nil;
        for (unsigned candidate = 0; candidate < 2; candidate++) {
            cpw_case = 40 + kind;
            cpw_scene(kind ? 3 : 0, 1, 2, YES, 13, NO);
            cpw_reference = !candidate;
            cpw_failure = 0;
            cpw_reset_attempt();
            if (kind)
                dma[2].limit = 31;
            else
                state->pgraph.inline_elements[12] = UINT32_MAX;
            NSData *before = cpw_capture(0);
            NSError *error = nil;
            qemu_mutex_lock(&state->pgraph.lock);
            assert(![draw drawWithError:&error] && error && !cpw_adapters &&
                   !cpw_pack && !cpw_expand && !cpw_gather &&
                   !pr_prepare_calls && !pr_emit_calls &&
                   !state->pgraph.draw_time);
            qemu_mutex_unlock(&state->pgraph.lock);
            NSData *after = cpw_capture(0);
            assert([before isEqualToData:after]);
            if (!candidate)
                reference = after;
            else
                assert([reference isEqualToData:after]);
        }
    }
}

static NSData *cpw_attachment_switch(BOOL reference)
{
    cpw_scene(0, 0, 1, YES, 13, YES);
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

static NSData *cpw_report_pressure(BOOL reference)
{
    cpw_scene(0, 0, 1, YES, 13, YES);
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

static void compact_polygon_wire_pgraph_tests(void)
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
    IMP replacements[] = { (IMP)cpw_geometry_spy, (IMP)cpw_prepare_spy,
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
    uint64_t visible[3] = { 0 }, colors[3] = { 0 }, depths[3] = { 0 };
    @try {
        for (unsigned test = 0; test < 40; test++) {
            cpw_case = test;
            unsigned topology, profile, program, count, boundary, failure = 0;
            BOOL indexed;
            if (test < 36) {
                topology = test / 6;
                profile = (test / 2) % 3;
                indexed = test & 1;
                program = (topology + profile + indexed) % 3;
                boundary = indexed && (topology + profile) % 3 == 0;
                count = topology == 5 ? 12 : 13;
            } else {
                topology = (unsigned[]){ 0, 3, 5, 5 }[test - 36];
                profile = test == 36 ? 1 : test == 39 ? 0 : 2;
                program = test == 37 ? 2 : 1;
                indexed = YES;
                count = test == 39 ? 2 : topology == 5 ? 12 : 13;
                boundary = test != 39;
                failure = test == 36 ? 1 : test == 39 ? 0 : 2;
            }
            NSData *pending = nil, *vertex = nil, *begin = nil, *failed = nil;
            cpw_grouped = NO;
            NSData *reference =
                cpw_run(topology, profile, program, indexed, count, boundary,
                        failure, YES, &pending, &vertex, &begin, &failed);
            NSData *actual =
                cpw_run(topology, profile, program, indexed, count, boundary,
                        failure, NO, &pending, &vertex, &begin, &failed);
            if (![reference isEqualToData:actual]) {
                fprintf(stderr,
                        "Compact polygon wire PGRAPH mismatch test%u "
                        "topology%u profile%u program%u indexed%d boundary%u\n",
                        test, topology, profile, program, indexed, boundary);
                abort();
            }
            const uint8_t *bytes = actual.bytes;
            uint32_t query;
            memcpy(&query, bytes + actual.length - 4, 4);
            visible[program] += query;
            uint32_t red = UINT32_C(0xffff0000), initial = UINT32_C(0xffffff11);
            for (unsigned i = 0; i < 256; i++) {
                colors[program] += bytes[i] != ((const uint8_t *)&red)[i % 4];
                depths[program] +=
                    bytes[i + 256] != ((const uint8_t *)&initial)[i % 4];
            }
            if (test < 36 && (topology == 0 || topology == 3) && profile == 2 &&
                indexed) {
                cpw_grouped = YES;
                NSData *grouped =
                    cpw_run(topology, profile, program, indexed, count, 0, 0,
                            YES, &pending, &vertex, &begin, &failed);
                assert(memcmp(actual.bytes, grouped.bytes, 256));
                orderControls++;
                cpw_grouped = NO;
            }
            pairs++;
        }
        cpw_invalid_pairs();
        pairs += 2;
        cpw_case = 42;
        NSData *reference = cpw_attachment_switch(YES);
        NSData *actual = cpw_attachment_switch(NO);
        assert([reference isEqualToData:actual]);
        pairs++;
        cpw_case = 43;
        reference = cpw_report_pressure(YES);
        actual = cpw_report_pressure(NO);
        assert([reference isEqualToData:actual]);
        pairs++;
    } @finally {
        for (unsigned i = 0; i < 11; i++)
            method_setImplementation(methods[i], originals[i]);
        cpw_names = cpw_encoders = nil;
        pr_packets = nil;
        pr_faces = nil;
        cpw_grouped = pr_grouped = pr_count_init = NO;
    }
    assert(pairs == 44 && orderControls == 2);
    for (unsigned program = 0; program < 3; program++)
        assert(visible[program] && colors[program] && depths[program]);
    printf(
        "Compact polygon wire PGRAPH: %u exact Color/DepthStencil/Current/"
        "context/query pairs PASS; six topology families, Wide/Smooth/W, "
        "arrays/remap, native Wire pack with no Wire expand/gather, mixed "
        "Point/FillSmooth and independent legacy primitive order, 2 visible "
        "order controls, prefix/Restore, last prepare/emit retry, invalid full "
        "input, genuine 2-edge boundary, unflushed attachment switch and real "
        "one-slot report pressure; geometry transitions repeat no Fetch/XF\n",
        pairs);
    groups += pairs;
}
#endif
