/* Direct quad point/wire raster versus the unchanged compute geometry path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_QUAD_MODES_PGRAPH_H
#define TEST_METAL_QUAD_MODES_PGRAPH_H
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
@interface NV2AMetalGeometry (QuadModesReference)
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeRasterVertices:(id<MTLBuffer>)vertices
                   first:(NSUInteger)first
                   count:(NSUInteger)count
               primitive:(enum NV2AMetalPrimitive)primitive
                  config:(const NV2AMetalGeometryRasterConfig *)config
                  smooth:(BOOL)smooth
          firstProvoking:(BOOL)first
            zPerspective:(BOOL)perspective
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error;
@end
static BOOL qm_reference, qm_direct, qm_fail_emit;
static unsigned qm_expansions, qm_gathers, qm_adapters, qm_indexed,
    qm_emit_failures;
static unsigned qm_compact_adapters, qm_compact_fills;
static BOOL polygon_compact_results(NSArray<NV2AMetalGeometryResult *> *results,
                                    NV2AMetalVertexSlice *slice,
                                    enum NV2AMetalPrimitive primitive,
                                    const NV2AMetalGeometryRasterConfig *config,
                                    BOOL perspective, unsigned *fillComputes)
{
    (void)fillComputes;
    BOOL compact = NO, compactLine = NO;
    for (NV2AMetalGeometryResult *g in results) {
        compact |= g.compactLines || g.compactPolygons;
        compactLine |= g.compactLines;
    }
    if (!compact)
        return NO;
    assert(config->polygonSmooth ||
           (compactLine &&
            (config->lineWidth > 1 || config->lineSmooth || perspective)));
    assert(results.count == (config->front == config->back ? 1u : 2u));
    for (NV2AMetalGeometryResult *g in results) {
        if (g.polygonMode == NV2AMetalPolygonLine) {
            NSUInteger per = primitive == NV2AMetalPrimitivePolygon ? 6 :
                             primitive >= NV2AMetalPrimitiveQuads   ? 24 :
                                                                      18;
            if (!g.compactLines) {
                assert(!g.expandedLines &&
                       (g.directQuadOptions || g.directPolygonOptions));
                continue;
            }
            assert(g.compactLines && g.expandedLines &&
                   g.sourcePrimitive == primitive &&
                   g.vertices == slice.buffer &&
                   g.indexedVertices == slice.indexedVertices &&
                   g.verticesPerPrimitive == per &&
                   g.vertexCount == per * g.primitiveCount &&
                   g.lineCoverage.storageMode == MTLStorageModePrivate &&
                   g.lineCoverage.length ==
                       g.vertexCount / 6 * sizeof(NV2AMetalCompactLine) &&
                   !g.polygonFacing && !g.directPolygonOptions &&
                   !g.directQuadOptions && !g.directTriangles &&
                   !g.directLineMode);
        } else if (g.polygonMode == NV2AMetalPolygonFill &&
                   config->polygonSmooth) {
            assert(g.compactPolygons && g.expandedPolygons && !g.compactLines &&
                   !g.directTriangles && g.sourcePrimitive == primitive &&
                   g.vertices == slice.buffer &&
                   g.indexedVertices == slice.indexedVertices &&
                   g.polygonCoverage.storageMode == MTLStorageModePrivate &&
                   g.polygonCoverage.length ==
                       g.vertexCount / 6 * sizeof(NV2AMetalCompactPolygon) &&
                   g.polygonProjections.length ==
                       g.vertexCount / 6 * sizeof(NV2AMetalPolygonProjection));
        } else {
            assert(!g.compactLines && g.vertices == slice.buffer &&
                   g.indexedVertices == slice.indexedVertices &&
                   (g.polygonMode == NV2AMetalPolygonFill ?
                        g.directTriangles :
                        g.directQuadOptions || g.directPolygonOptions));
        }
    }
    return YES;
}
static uint64_t qm_samples[3][2], qm_color_bytes[3][2], qm_zeta_bytes[3][2];
static NSMapTable<id<MTLComputePipelineState>, NSString *> *qm_names;
static NSMutableDictionary<NSValue *, NSString *> *qm_encoders;
static id (*qm_compute)(id, SEL, NSString *, NSError **);
static id qm_compute_spy(id object, SEL selector, NSString *name,
                         NSError **error)
{
    id result = qm_compute(object, selector, name, error);
    if (result)
        [qm_names setObject:name forKey:result];
    return result;
}
static void (*qm_set_pipeline)(id, SEL, id);
static void qm_pipeline_spy(id object, SEL selector, id pipeline)
{
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
    NSString *name = pipeline ? [qm_names objectForKey:pipeline] : nil;
    if (name)
        qm_encoders[key] = name;
    else
        [qm_encoders removeObjectForKey:key];
    qm_set_pipeline(object, selector, pipeline);
}
static void (*qm_dispatch)(id, SEL, MTLSize, MTLSize);
static void qm_dispatch_spy(id object, SEL selector, MTLSize threads,
                            MTLSize group)
{
    NSString *name =
        qm_encoders[[NSValue valueWithPointer:(__bridge const void *)object]];
    qm_expansions += [name isEqualToString:@"nv2a_expand_geometry"];
    qm_gathers += [name isEqualToString:@"nv2a_vertex_stream_gather"];
    qm_dispatch(object, selector, threads, group);
}
static NSArray *(*qm_geometry)(id, SEL, NV2AMetalVertexSlice *,
                               enum NV2AMetalPrimitive,
                               const NV2AMetalGeometryRasterConfig *, BOOL,
                               BOOL, BOOL, NV2AMetalCommands *, NSError **);
static NSArray *qm_geometry_spy(id object, SEL selector,
                                NV2AMetalVertexSlice *slice,
                                enum NV2AMetalPrimitive primitive,
                                const NV2AMetalGeometryRasterConfig *config,
                                BOOL smooth, BOOL first, BOOL perspective,
                                NV2AMetalCommands *commands, NSError **error)
{
    qm_adapters++;
    if (qm_reference) {
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
        return [object encodeRasterVertices:vertices
                                      first:offset
                                      count:slice.vertexCount
                                  primitive:primitive
                                     config:config
                                     smooth:smooth
                             firstProvoking:first
                               zPerspective:perspective
                                   commands:commands
                                      error:error];
    }
    NSArray<NV2AMetalGeometryResult *> *result =
        qm_geometry(object, selector, slice, primitive, config, smooth, first,
                    perspective, commands, error);
    if (result && polygon_compact_results(result, slice, primitive, config,
                                          perspective, &qm_compact_fills)) {
        qm_compact_adapters++;
        if (slice.indexedVertices)
            qm_indexed++;
        return result;
    }
    if (result && qm_direct) {
        assert(result.count == 1);
        NV2AMetalGeometryResult *g = result[0];
        BOOL point = config->front == NV2AMetalPolygonPoint;
        NSUInteger primitives =
            primitive == NV2AMetalPrimitiveQuads ? slice.vertexCount / 4 :
            slice.vertexCount < 4                ? 0 :
                                                   slice.vertexCount / 2 - 1;
        NSUInteger source = primitive == NV2AMetalPrimitiveQuads ?
                                slice.vertexCount / 4 * 4 :
                                slice.vertexCount / 2 * 2;
        assert(g.directQuadOptions && !g.directPoints && !g.directTriangles &&
               !g.directLineMode &&
               !(g.directQuadOptions & NV2AMetalDirectTriangleFirst) &&
               g.polygonMode == config->front && g.vertices == slice.buffer &&
               g.indexedVertices == slice.indexedVertices &&
               g.sourceVertexCount == source &&
               g.primitiveCount == primitives &&
               g.vertexCount == primitives * (point ? 4 : 8) &&
               g.verticesPerPrimitive == (point ? 4u : 8u));
        if (slice.indexedVertices) {
            assert(g.physicalVertexCount ==
                       slice.indexedVertices.physicalVertexCount &&
                   g.indexOffset == slice.firstVertex &&
                   g.physicalVertexCount < slice.vertexCount);
            qm_indexed++;
        } else
            assert(g.firstVertex == slice.firstVertex);
    } else if (result) {
        for (NV2AMetalGeometryResult *g in result)
            assert(!g.directQuadOptions);
    }
    return result;
}
static BOOL (*qm_emit)(id, SEL, id, id, NSError **);
static BOOL qm_emit_spy(id object, SEL selector, id encoder, id commands,
                        NSError **error)
{
    BOOL ok = qm_emit(object, selector, encoder, commands, error);
    if (ok && qm_fail_emit) {
        qm_fail_emit = NO;
        qm_emit_failures++;
        if (error)
            *error = [NSError errorWithDomain:@"test.quad-late-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static BOOL (*qm_range_emit)(id, SEL, id, id, NSUInteger, NSUInteger,
                             NSError **);
static BOOL qm_range_emit_spy(id object, SEL selector, id encoder, id commands,
                              NSUInteger first, NSUInteger count,
                              NSError **error)
{
    BOOL ok =
        qm_range_emit(object, selector, encoder, commands, first, count, error);
    if (ok && qm_fail_emit) {
        qm_fail_emit = NO;
        qm_emit_failures++;
        if (error)
            *error = [NSError errorWithDomain:@"test.quad-late-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static void qm_scene(unsigned topology, unsigned polygon, unsigned program,
                     BOOL indexed, unsigned boundary, unsigned special)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    if (program == 2) {
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
        pg->enable_vertex_program_write = true;
        feedback_program(191, 15);
        mov(2, 3, 3, false);
        mov(3, 7, 7, true);
    } else if (program) {
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
        mov(0, 0, 0, false);
        mov(1, 3, 3, false);
        mov(2, 7, 7, true);
    }
    pg->primitive_mode = topology ? PRIM_TYPE_QUAD_STRIP : PRIM_TYPE_QUADS;
    pg->regs_[NV_PGRAPH_SETUPRASTER] =
        polygon | polygon << 2 | NV_PGRAPH_SETUPRASTER_TWO_SIDE |
        (boundary & 1 ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0) |
        (polygon == 1 ? NV_PGRAPH_SETUPRASTER_POFFSETPOINTENABLE :
                        NV_PGRAPH_SETUPRASTER_POFFSETLINEENABLE);
    unsigned cull = (program + topology + indexed) % 3;
    if (cull)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_CULLENABLE | cull << 21;
    pg->regs_[NV_PGRAPH_CSV0_C] |= NV_PGRAPH_CSV0_C_TWO_SIDE;
    pg->regs_[NV_PGRAPH_CONTROL_3] =
        ((program + indexed + topology + boundary) & 1 ?
             NV_PGRAPH_CONTROL_3_SHADEMODE :
             0) |
        (boundary & 1 ? NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX : 0);
    pg->regs_[NV_PGRAPH_POINTSIZE] = 8;
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] |=
        NV_PGRAPH_CONTROL_0_ZENABLE | NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
        NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE | 7 << 16;
    pg->regs_[NV_PGRAPH_CONTROL_1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                     7 << 4 | 0x5a << 8 | 0xff << 16 |
                                     0xffu << 24;
    pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 4 << 8;
    reg_float(NV_PGRAPH_ZOFFSETBIAS, 3);
    reg_float(NV_PGRAPH_ZOFFSETFACTOR, .125f);
    if (special == 1)
        pg->regs_[NV_PGRAPH_SETUPRASTER] =
            (pg->regs_[NV_PGRAPH_SETUPRASTER] & ~15u) | 1 | 2 << 2 |
            NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE;
    if (special == 2)
        pg->surface_scale_factor = 2;
    if (special == 3)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE;
    if (special == 4 || special == 5)
        pg->regs_[NV_PGRAPH_CONTROL_0] |=
            NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;
    if (special == 6)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    const float physical[8][4] = {
        { .5f, .5f, 30000, 1 },   { 3.5f, .5f, 31000, 1 },
        { 3.5f, 3.5f, 32500, 1 }, { .5f, 3.5f, 30500, 1 },
        { 4.5f, 4.5f, 33000, 1 }, { 7.5f, 4.5f, 34000, 1 },
        { 7.5f, 7.5f, 35000, 1 }, { 4.5f, 7.5f, 33500, 1 }
    };
    const uint32_t quads[13] = { 2, 3, 0, 1, 4, 7, 6, 5, 2, 3, 0, 1, 5 };
    const uint32_t strip[13] = { 2, 1, 3, 0, 7, 4, 6, 5, 2, 1, 3, 0, 5 };
    const uint32_t *indices = topology ? strip : quads;
    cpu_write(16384, 1024);
    for (unsigned v = 0; v < (indexed ? 8u : 13u); v++) {
        unsigned original = indexed ? v : indices[v];
        memcpy(state->vram_ptr + 16384 + v * 16, physical[original], 16);
        const float front[] = { (original + 1) / 9.f, .25f,
                                (8 - original) / 9.f, 1 };
        const float back[] = { .125f, (original + 1) / 9.f,
                               (8 - original) / 10.f, 1 };
        memcpy(state->vram_ptr + 16640 + v * 16, front, 16);
        memcpy(state->vram_ptr + 16896 + v * 16, back, 16);
    }
    pg->vertex_attributes[3] =
        (VertexAttribute){ .offset = 256,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    pg->vertex_attributes[7] = pg->vertex_attributes[3];
    pg->vertex_attributes[7].offset = 512;
    pg->draw_arrays_length = indexed ? 0 : 1;
    pg->draw_arrays_count[0] = 13;
    pg->inline_elements_length = indexed ? 13 : 0;
    if (indexed)
        memcpy(pg->inline_elements, indices, sizeof(quads));
    cpu_write(4096, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t packed = UINT32_C(0xffffff11);
        memcpy(state->vram_ptr + 4096 + i * 4, &packed, 4);
    }
    pg->dma_report = 64;
    pg->zpass_pixel_count_enable = true;
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    qemu_mutex_unlock(&pg->lock);
}
static void qm_pair(unsigned topology, unsigned polygon, unsigned program,
                    BOOL indexed, unsigned boundary, unsigned special)
{
    uint8_t frame[512];
    uint32_t current[16][4], constants[192][4];
    bool dirty[192];
    NSData *pending = nil, *vertex = nil, *begin = nil, *failedPending = nil;
    uint32_t referenceQuery = 0;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        qm_scene(topology, polygon, program, indexed, boundary, special);
        qm_reference = !candidate;
        qm_direct = special == 0 || special >= 5;
        qm_fail_emit = NO;
        qm_expansions = qm_gathers = qm_adapters = qm_indexed = 0;
        qm_compact_adapters = qm_compact_fills = 0;
        unsigned failures = qm_emit_failures;
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
            NSData *p = [draw pendingSnapshotWithError:&error],
                   *v = draw.vertexSnapshot;
            NSData *b = [draw beginSnapshotWithError:&error];
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
                pg->inline_elements_length = 13;
            else
                pg->draw_arrays_count[0] = 13;
            if (boundary == 2) {
                qm_fail_emit = YES;
                assert(![draw endWithError:&error] && error && !qm_fail_emit &&
                       qm_emit_failures == failures + 1);
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
        assert(qm_adapters && pg->draw_time == 1);
        if (candidate && qm_compact_adapters) {
            assert(qm_expansions == qm_compact_fills);
            if (indexed && program < 2)
                assert(qm_indexed && qm_gathers == qm_compact_fills);
            else
                assert(!qm_gathers);
        } else if (candidate && qm_direct) {
            assert(!qm_expansions && !qm_gathers);
            if (indexed && program < 2)
                assert(qm_indexed);
        } else {
            assert(qm_expansions);
            if (indexed && program < 2)
                assert(qm_gathers);
        }
        require([draw.reports getReport:1u << 24 error:&error] &&
                    [draw.reports processWithError:&error],
                error);
        uint32_t query = report_value(0);
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        read_vram(4096, 256);
        if (program == 2)
            expect_context(191, 15, 13, YES);
        if (candidate && qm_direct) {
            qm_samples[program][polygon - 1] += query;
            const uint32_t red = UINT32_C(0xffff0000),
                           initialZeta = UINT32_C(0xffffff11);
            for (unsigned byte = 0; byte < 256; byte++) {
                qm_color_bytes[program][polygon - 1] +=
                    state->vram_ptr[1024 + byte] !=
                    ((const uint8_t *)&red)[byte % 4];
                qm_zeta_bytes[program][polygon - 1] +=
                    state->vram_ptr[4096 + byte] !=
                    ((const uint8_t *)&initialZeta)[byte % 4];
            }
        }
        if (!candidate) {
            memcpy(frame, state->vram_ptr + 1024, 256);
            memcpy(frame + 256, state->vram_ptr + 4096, 256);
            for (unsigned i = 0; i < 16; i++)
                memcpy(current[i], pg->vertex_attributes[i].inline_value, 16);
            memcpy(constants, pg->vsh_constants, sizeof(constants));
            memcpy(dirty, pg->vsh_constants_dirty, sizeof(dirty));
            referenceQuery = query;
        } else {
            if (memcmp(frame, state->vram_ptr + 1024, 256) ||
                memcmp(frame + 256, state->vram_ptr + 4096, 256) ||
                query != referenceQuery) {
                fprintf(stderr,
                        "Quad PGRAPH mismatch topology%u polygon%u program%u "
                        "indexed%d boundary%u special%u query%u/%u\n",
                        topology, polygon, program, indexed, boundary, special,
                        query, referenceQuery);
                abort();
            }
            for (unsigned i = 0; i < 16; i++)
                assert(!memcmp(current[i],
                               pg->vertex_attributes[i].inline_value, 16));
            assert(!memcmp(constants, pg->vsh_constants, sizeof(constants)) &&
                   !memcmp(dirty, pg->vsh_constants_dirty, sizeof(dirty)));
        }
    }
}
static void quad_modes_pgraph_tests(void)
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
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(object_getClass(encoder),
                                @selector(setComputePipelineState:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(NV2AMetalPixelDraw.class,
                                @selector(encodeWithRenderEncoder:commands:
                                          firstVertex:vertexCount:error:))
    };
    [encoder endEncoding];
    [probe cancel];
    IMP replacements[] = { (IMP)qm_geometry_spy, (IMP)qm_compute_spy,
                           (IMP)qm_pipeline_spy, (IMP)qm_dispatch_spy,
                           (IMP)qm_emit_spy,     (IMP)qm_range_emit_spy };
    IMP originals[6];
    qm_names = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    qm_encoders = [NSMutableDictionary new];
    id existing = [[draw valueForKey:@"geometry"] valueForKey:@"pipeline"];
    if (existing)
        [qm_names setObject:@"nv2a_expand_geometry" forKey:existing];
    for (unsigned i = 0; i < 6; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    qm_geometry = (void *)originals[0];
    qm_compute = (void *)originals[1];
    qm_set_pipeline = (void *)originals[2];
    qm_dispatch = (void *)originals[3];
    qm_emit = (void *)originals[4];
    qm_range_emit = (void *)originals[5];
    memset(qm_samples, 0, sizeof(qm_samples));
    memset(qm_color_bytes, 0, sizeof(qm_color_bytes));
    memset(qm_zeta_bytes, 0, sizeof(qm_zeta_bytes));
    unsigned pairs = 0;
    @try {
        for (unsigned program = 0; program < 3; program++)
            for (unsigned topology = 0; topology < 2; topology++)
                for (unsigned polygon = 1; polygon <= 2; polygon++)
                    for (unsigned indexed = 0; indexed < 2; indexed++)
                        for (unsigned boundary = 0; boundary < 3; boundary++) {
                            qm_pair(topology, polygon, program, indexed,
                                    boundary, 0);
                            pairs++;
                        }
        for (unsigned special = 1; special <= 6; special++)
            for (unsigned topology = 0; topology < 2; topology++) {
                qm_pair(topology, special >= 5 ? 1 : 2, 1, YES, 0, special);
                pairs++;
            }
        for (unsigned topology = 0; topology < 2; topology++) {
            for (unsigned candidate = 0; candidate < 2; candidate++) {
                qm_scene(topology, 1, 2, YES, 0, 0);
                qm_reference = !candidate;
                qm_direct = YES;
                qm_expansions = qm_gathers = qm_adapters = 0;
                state->pgraph.inline_elements[12] = UINT32_MAX;
                uint32_t current[16][4], constants[192][4];
                for (unsigned i = 0; i < 16; i++)
                    memcpy(current[i],
                           state->pgraph.vertex_attributes[i].inline_value, 16);
                memcpy(constants, state->pgraph.vsh_constants,
                       sizeof(constants));
                error = nil;
                qemu_mutex_lock(&state->pgraph.lock);
                assert(![draw drawWithError:&error] && error &&
                       !state->pgraph.draw_time && !qm_adapters &&
                       !qm_expansions && !qm_gathers);
                qemu_mutex_unlock(&state->pgraph.lock);
                for (unsigned i = 0; i < 16; i++)
                    assert(!memcmp(
                        current[i],
                        state->pgraph.vertex_attributes[i].inline_value, 16));
                assert(!memcmp(constants, state->pgraph.vsh_constants,
                               sizeof(constants)));
            }
            pairs++;
        }
    } @finally {
        for (unsigned i = 0; i < 6; i++)
            method_setImplementation(methods[i], originals[i]);
        qm_names = nil;
        qm_encoders = nil;
        qm_reference = qm_fail_emit = NO;
    }
    assert(pairs == 86);
    uint64_t samples[2] = { 0 }, colors[2] = { 0 }, zeta[2] = { 0 };
    for (unsigned program = 0; program < 3; program++)
        for (unsigned mode = 0; mode < 2; mode++) {
            assert(qm_samples[program][mode] && qm_color_bytes[program][mode] &&
                   qm_zeta_bytes[program][mode]);
            samples[mode] += qm_samples[program][mode];
            colors[mode] += qm_color_bytes[program][mode];
            zeta[mode] += qm_zeta_bytes[program][mode];
        }
    printf("Quad direct visibility Point/Wire: %llu/%llu samples, %llu/%llu "
           "changed color bytes, "
           "%llu/%llu changed depth-stencil bytes; each Fixed/readonly/writer "
           "group nonzero PASS\n",
           (unsigned long long)samples[0], (unsigned long long)samples[1],
           (unsigned long long)colors[0], (unsigned long long)colors[1],
           (unsigned long long)zeta[0], (unsigned long long)zeta[1]);
    printf("Quad point/wire PGRAPH: %u exact "
           "framebuffer/depth-stencil/Current/constants/query pairs; "
           "fixed/readonly/writer, arrays/remap, flat/smooth/TwoSide/cull and "
           "split slopes; "
           "zero direct geometry expansion/gather, prefix/Restore/late-raster "
           "retry, "
           "mixed/wide/smooth/W-wire compact results, strict fallbacks and full input bounds PASS\n",
           pairs);
    groups += pairs;
}
#endif
