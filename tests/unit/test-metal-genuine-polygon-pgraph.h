/* Genuine polygon PGRAPH integration against unchanged compute geometry.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_GENUINE_POLYGON_PGRAPH_H
#define TEST_METAL_GENUINE_POLYGON_PGRAPH_H
static BOOL gp_reference, gp_fail_emit;
static unsigned gp_adapters, gp_indexed, gp_faces, gp_old_faces, gp_expansions,
    gp_gathers, gp_failures, gp_pairs;
static uint64_t gp_visible[3][2], gp_changed[3][2];
static NSData *gp_last;
static NSMapTable<id<MTLComputePipelineState>, NSString *> *gp_names;
static NSMutableDictionary<NSValue *, NSString *> *gp_encoders;
static id (*gp_compute)(id, SEL, NSString *, NSError **);
static id gp_compute_spy(id object, SEL selector, NSString *name,
                         NSError **error)
{
    id result = gp_compute(object, selector, name, error);
    if (result)
        [gp_names setObject:name forKey:result];
    return result;
}
static void (*gp_pipeline)(id, SEL, id);
static void gp_pipeline_spy(id object, SEL selector, id pipeline)
{
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
    NSString *name = pipeline ? [gp_names objectForKey:pipeline] : nil;
    if (name)
        gp_encoders[key] = name;
    else
        [gp_encoders removeObjectForKey:key];
    gp_pipeline(object, selector, pipeline);
}
static void (*gp_dispatch)(id, SEL, MTLSize, MTLSize);
static void gp_dispatch_spy(id object, SEL selector, MTLSize threads,
                            MTLSize group)
{
    NSString *name =
        gp_encoders[[NSValue valueWithPointer:(__bridge const void *)object]];
    gp_faces += [name isEqualToString:@"nv2a_direct_polygon_face"] ||
                [name isEqualToString:@"nv2a_direct_indexed_polygon_face"];
    gp_old_faces += [name isEqualToString:@"nv2a_polygon_face"];
    gp_expansions += [name isEqualToString:@"nv2a_expand_geometry"];
    gp_gathers += [name isEqualToString:@"nv2a_vertex_stream_gather"];
    gp_dispatch(object, selector, threads, group);
}
static NSArray *(*gp_geometry)(id, SEL, NV2AMetalVertexSlice *,
                               enum NV2AMetalPrimitive,
                               const NV2AMetalGeometryRasterConfig *, BOOL,
                               BOOL, BOOL, NV2AMetalCommands *, NSError **);
static NSArray *gp_geometry_spy(id object, SEL selector,
                                NV2AMetalVertexSlice *slice,
                                enum NV2AMetalPrimitive primitive,
                                const NV2AMetalGeometryRasterConfig *config,
                                BOOL smooth, BOOL first, BOOL perspective,
                                NV2AMetalCommands *commands, NSError **error)
{
    assert(primitive == NV2AMetalPrimitivePolygon);
    gp_adapters++;
    unsigned faces = gp_faces, oldFaces = gp_old_faces,
             expansions = gp_expansions, gathers = gp_gathers;
    NSArray<NV2AMetalGeometryResult *> *results;
    if (gp_reference) {
        id<MTLBuffer> vertices = slice.buffer;
        NSUInteger offset = slice.firstVertex;
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
            vertices = [stream encodeWithCommands:commands error:error];
            if (!vertices)
                return nil;
            offset = 0;
        }
        results = [object encodeRasterVertices:vertices
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
        results = gp_geometry(object, selector, slice, primitive, config,
                              smooth, first, perspective, commands, error);
    if (!results)
        return nil;
    assert(results.count == (config->front == config->back ? 1u : 2u));
    id<MTLBuffer> sharedFace = nil;
    unsigned nonempty = 0;
    for (NSUInteger side = 0; side < results.count; side++) {
        NV2AMetalGeometryResult *g = results[side];
        enum NV2AMetalPolygonMode mode = side ? config->back : config->front;
        BOOL fill = mode == NV2AMetalPolygonFill;
        NSUInteger count = slice.vertexCount;
        NSUInteger primitives =
            fill ? (count < 3 ? 0 : count - 2) : (count < 2 ? 0 : count);
        assert(g.polygonMode == mode &&
               g.vertexCount == primitives * (fill ? 3 : 2) &&
               g.primitiveCount == primitives &&
               g.verticesPerPrimitive == (fill ? 3u : 2u));
        nonempty += g.vertexCount != 0;
        if (gp_reference)
            continue;
        unsigned options =
            fill ? g.directTriangleOptions : g.directPolygonOptions;
        assert((options & NV2AMetalDirectTriangleTopologyMask) ==
                   NV2AMetalDirectTrianglePolygon &&
               !(options & NV2AMetalDirectTriangleFirst) &&
               g.directTriangles == fill && !g.directQuadOptions &&
               !g.directPoints && !g.directLineMode && !g.expandedLines &&
               !g.expandedPolygons && !g.polygonProjections);
        if (results.count == 2)
            assert(options & (side ? NV2AMetalDirectTriangleCullFront :
                                     NV2AMetalDirectTriangleCullBack));
        if (!g.vertexCount) {
            assert(!g.vertices && !g.indexedVertices && !g.polygonFacing &&
                   !g.sourceVertexCount && !g.physicalVertexCount);
            continue;
        }
        assert(g.vertices == slice.buffer &&
               g.indexedVertices == slice.indexedVertices &&
               g.sourceVertexCount == count && g.polygonFacing.length == 4 &&
               g.polygonFacing.storageMode == MTLStorageModePrivate);
        if (sharedFace)
            assert(sharedFace == g.polygonFacing);
        sharedFace = g.polygonFacing;
        if (slice.indexedVertices) {
            assert(g.physicalVertexCount ==
                       slice.indexedVertices.physicalVertexCount &&
                   g.indexOffset == slice.firstVertex && !g.firstVertex);
            if (count == 12)
                assert(g.physicalVertexCount < count);
            gp_indexed++;
        } else
            assert(g.firstVertex == slice.firstVertex && !g.indexOffset);
    }
    if (gp_reference)
        assert(gp_faces == faces && gp_old_faces - oldFaces == nonempty &&
               gp_expansions - expansions == nonempty &&
               gp_gathers - gathers == !!slice.indexedVertices);
    else
        assert(gp_faces - faces == !!nonempty && gp_old_faces == oldFaces &&
               gp_expansions == expansions && gp_gathers == gathers);
    return results;
}
static BOOL (*gp_emit)(id, SEL, id, id, NSError **);
static BOOL gp_emit_spy(id object, SEL selector, id encoder, id commands,
                        NSError **error)
{
    BOOL ok = gp_emit(object, selector, encoder, commands, error);
    if (ok && gp_fail_emit) {
        gp_fail_emit = NO;
        gp_failures++;
        if (error)
            *error = [NSError errorWithDomain:@"test.genuine-polygon-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static void gp_scene(unsigned front, unsigned back, unsigned program,
                     BOOL indexed, unsigned count, unsigned boundary,
                     unsigned variant, unsigned cull)
{
    qm_scene(0, 2, program, indexed, boundary, 0);
    PGRAPHState *pg = &state->pgraph;
    pg->primitive_mode = PRIM_TYPE_POLYGON;
    pg->regs_[NV_PGRAPH_SETUPRASTER] =
        front | back << 2 | NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE |
        NV_PGRAPH_SETUPRASTER_POFFSETLINEENABLE |
        (variant & 8 ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0) |
        (variant & 16 ? 0 : NV_PGRAPH_SETUPRASTER_TWO_SIDE) |
        (cull ? NV_PGRAPH_SETUPRASTER_CULLENABLE | cull << 21 : 0);
    pg->regs_[NV_PGRAPH_CONTROL_3] =
        (variant & 1 ? NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX : 0) |
        (variant & 2 ? NV_PGRAPH_CONTROL_3_SHADEMODE : 0);
    if (variant & 16)
        pg->regs_[NV_PGRAPH_CSV0_C] &= ~NV_PGRAPH_CSV0_C_TWO_SIDE;
    if (variant & 4)
        pg->regs_[NV_PGRAPH_CONTROL_0] |=
            NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;
    const float physical[8][4] = {
        { .5f, .5f, 30000, 1 },        { 3.5f, .5f, 31000, 1 },
        { 6.5f, .5f, 32500, 1 },       { 6.5f, 6.5f, 30500, 1.375f },
        { 3.5f, 3.5f, 33000, 1 },      { .5f, 6.5f, 34000, 1.25f },
        { 6.5f, 3.5f, 35000, 1.125f }, { 3.5f, 6.5f, 33500, 1.375f }
    };
    const uint32_t indices[12] = { 0, 1, 2, 3, 4, 5, 6, 7, 0, 4, 2, 5 };
    /* This fixture has a degenerate first fan and later opposite local
     * winding. Whole-boundary face must still be shared by every edge/fan. */
    assert((physical[1][1] - physical[0][1]) == 0 &&
           (physical[2][1] - physical[0][1]) == 0);
    unsigned positive = 0, negative = 0;
    for (unsigned i = 1; i + 1 < 12; i++) {
        const float *a = physical[indices[i]], *b = physical[indices[i + 1]];
        float area = (a[0] - .5f) * (b[1] - .5f) - (a[1] - .5f) * (b[0] - .5f);
        positive += area > 0;
        negative += area < 0;
    }
    assert(positive && negative);
    cpu_write(16384, 1024);
    for (unsigned v = 0; v < (indexed ? 8u : count); v++) {
        unsigned original = indexed ? v : indices[v];
        memcpy(state->vram_ptr + 16384 + v * 16, physical[original], 16);
        const float colors[2][4] = {
            { (original + 1) / 9.f, .25f, (8 - original) / 9.f, .5f },
            { .125f, (original + 1) / 9.f, (8 - original) / 10.f, .75f }
        };
        memcpy(state->vram_ptr + 16640 + v * 16, colors[0], 16);
        memcpy(state->vram_ptr + 16896 + v * 16, colors[1], 16);
    }
    if (indexed) {
        pg->inline_elements_length = count;
        memcpy(pg->inline_elements, indices, count * sizeof(*indices));
    } else
        pg->draw_arrays_count[0] = count;
}
static NSData *gp_capture(uint32_t query)
{
    PGRAPHState *pg = &state->pgraph;
    NSMutableData *result = [NSMutableData dataWithBytes:state->vram_ptr + 1024
                                                  length:256];
    [result appendBytes:state->vram_ptr + 4096 length:256];
    for (unsigned i = 0; i < 16; i++)
        [result appendBytes:pg->vertex_attributes[i].inline_value length:16];
    [result appendBytes:pg->vsh_constants length:sizeof(pg->vsh_constants)];
    [result appendBytes:pg->vsh_constants_dirty
                 length:sizeof(pg->vsh_constants_dirty)];
    [result appendBytes:&query length:sizeof(query)];
    return result;
}
static void gp_pair(unsigned front, unsigned back, unsigned program,
                    BOOL indexed, unsigned count, unsigned boundary,
                    unsigned variant, unsigned cull)
{
    NSData *reference = nil, *pending = nil, *vertex = nil, *begin = nil,
           *failedPending = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        gp_scene(front, back, program, indexed, count, boundary, variant, cull);
        gp_reference = !candidate;
        gp_fail_emit = NO;
        gp_adapters = gp_indexed = gp_faces = gp_old_faces = gp_expansions =
            gp_gathers = 0;
        unsigned failures = gp_failures;
        NSError *error = nil;
        PGRAPHState *pg = &state->pgraph;
        qemu_mutex_lock(&pg->lock);
        if (boundary) {
            assert(count == 12);
            if (indexed)
                pg->inline_elements_length = 5;
            else
                pg->draw_arrays_count[0] = 5;
            require([draw beginWithError:&error] &&
                        [draw prepareVertexStateChangeWithError:&error],
                    error);
            NSData *p = [draw pendingSnapshotWithError:&error],
                   *v = draw.vertexSnapshot,
                   *b = [draw beginSnapshotWithError:&error];
            require(p && v && b, error);
            if (!candidate) {
                pending = p;
                vertex = v;
                begin = b;
            } else
                assert([pending isEqualToData:p] && [vertex isEqualToData:v] &&
                       [begin isEqualToData:b]);
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
            if (boundary == 2) {
                gp_fail_emit = YES;
                assert(![draw endWithError:&error] && error && !gp_fail_emit &&
                       gp_failures == failures + 1);
                error = nil;
                NSData *p = [draw pendingSnapshotWithError:&error];
                require(p != nil, error);
                if (!candidate)
                    failedPending = p;
                else
                    assert([failedPending isEqualToData:p]);
            }
            require([draw endWithError:&error], error);
        } else
            require([draw drawWithError:&error], error);
        assert(gp_adapters && pg->draw_time == 1);
        if (candidate) {
            assert(!gp_expansions && !gp_gathers && !gp_old_faces);
            if (indexed && program < 2 && count == 12 && !boundary)
                assert(gp_indexed);
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
        NSData *actual = gp_capture(query);
        if (!candidate)
            reference = actual;
        else {
            if (![reference isEqualToData:actual]) {
                fprintf(stderr,
                        "Genuine polygon PGRAPH mismatch front%u back%u "
                        "program%u indexed%d "
                        "count%u boundary%u variant%u cull%u query%u\n",
                        front, back, program, indexed, count, boundary, variant,
                        cull, query);
                abort();
            }
            gp_last = actual;
            if (front == back && !cull) {
                unsigned mode = front == NV2AMetalPolygonLine;
                gp_visible[program][mode] += query;
                const uint32_t red = UINT32_C(0xffff0000);
                for (unsigned byte = 0; byte < 256; byte++)
                    gp_changed[program][mode] +=
                        state->vram_ptr[1024 + byte] !=
                        ((const uint8_t *)&red)[byte % 4];
            }
        }
    }
    gp_pairs++;
}
static void genuine_polygon_pgraph_tests(void)
{
    NSError *error = nil;
    fixture();
    NV2AMetalGeometry *previousGeometry = [draw valueForKey:@"geometry"];
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(geometry != nil, error);
    [draw setValue:geometry forKey:@"geometry"];
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
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(object_getClass(encoder),
                                @selector(setComputePipelineState:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    [encoder endEncoding];
    [probe cancel];
    IMP replacements[] = { (IMP)gp_geometry_spy, (IMP)gp_compute_spy,
                           (IMP)gp_pipeline_spy, (IMP)gp_dispatch_spy,
                           (IMP)gp_emit_spy },
        originals[5];
    gp_names = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    gp_encoders = [NSMutableDictionary new];
    for (unsigned i = 0; i < 5; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    gp_geometry = (void *)originals[0];
    gp_compute = (void *)originals[1];
    gp_pipeline = (void *)originals[2];
    gp_dispatch = (void *)originals[3];
    gp_emit = (void *)originals[4];
    const unsigned modes[][2] = { { 0, 0 }, { 2, 2 }, { 0, 2 }, { 2, 0 } };
    @try {
        for (unsigned program = 0; program < 3; program++)
            for (unsigned mode = 0; mode < 4; mode++)
                for (unsigned indexed = 0; indexed < 2; indexed++)
                    for (unsigned first = 0; first < 2; first++) {
                        unsigned boundary =
                            (program + mode + indexed + first) % 3;
                        unsigned variant =
                            first | (((program + mode + indexed) & 1) << 1) |
                            ((boundary & 1) << 3);
                        gp_pair(modes[mode][0], modes[mode][1], program,
                                indexed, 12, boundary, variant, 0);
                    }
        for (unsigned program = 0; program < 3; program++)
            for (unsigned mode = 0; mode < 4; mode++)
                for (unsigned indexed = 0; indexed < 2; indexed++)
                    gp_pair(modes[mode][0], modes[mode][1], program, indexed, 2,
                            0, 1, 0);
        for (unsigned mode = 0; mode < 4; mode++)
            for (unsigned clockwise = 0; clockwise < 2; clockwise++)
                for (unsigned cull = 1; cull <= 3; cull++)
                    gp_pair(modes[mode][0], modes[mode][1], 1, YES, 12, 0,
                            clockwise << 3, cull);
        /* Genuine polygon First is ignored for both fill and boundary wire,
         * including mixed modes. Require identical complete guest outputs. */
        for (unsigned mode = 0; mode < 4; mode++) {
            gp_pair(modes[mode][0], modes[mode][1], 1, YES, 12, 0, 0, 0);
            NSData *first = gp_last;
            gp_pair(modes[mode][0], modes[mode][1], 1, YES, 12, 0, 1, 0);
            assert([first isEqualToData:gp_last]);
        }
        gp_pair(0, 0, 1, YES, 12, 0, 4, 0);
        gp_pair(0, 0, 2, NO, 12, 2, 7, 0);
        gp_pair(0, 2, 0, YES, 12, 1, 16, 0);
        gp_pair(2, 2, 1, NO, 12, 0, 18, 0);
    } @finally {
        for (unsigned i = 0; i < 5; i++)
            method_setImplementation(methods[i], originals[i]);
        [draw setValue:previousGeometry forKey:@"geometry"];
        gp_names = nil;
        gp_encoders = nil;
        gp_reference = gp_fail_emit = NO;
        gp_last = nil;
    }
    for (unsigned program = 0; program < 3; program++)
        for (unsigned mode = 0; mode < 2; mode++)
            assert(gp_visible[program][mode] && gp_changed[program][mode]);
    printf("Genuine polygon PGRAPH: %u exact "
           "framebuffer/zeta/Current/constants/query pairs; "
           "Fixed/readonly/writer arrays/index, shared Private4B whole face, "
           "collinear/concave fans, "
           "fill/edge provokers and ignored First, TwoSide/cull/offset/W, n2 "
           "wire, "
           "one direct face dispatch without expansion/gather, "
           "prefix/Restore/late-raster retry PASS\n",
           gp_pairs);
    groups += gp_pairs;
}
#endif
