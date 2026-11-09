/* Direct polygon point/wire raster versus the unchanged compute geometry path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_MODES_PGRAPH_H
#define TEST_METAL_POLYGON_MODES_PGRAPH_H
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
@interface NV2AMetalGeometry (PolygonModesReference)
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
static BOOL pm_reference, pm_direct, pm_fail_emit, pm_group_reference;
static unsigned pm_order_controls;
static NSData *pm_last_frame;
static unsigned pm_expansions, pm_gathers, pm_adapters, pm_indexed,
    pm_emit_failures;
static unsigned pm_compact_adapters, pm_compact_fills;
static uint64_t pm_samples[3][2], pm_color_bytes[3][2], pm_zeta_bytes[3][2];
static NSMapTable<id<MTLComputePipelineState>, NSString *> *pm_names;
static NSMutableDictionary<NSValue *, NSString *> *pm_encoders;
static id (*pm_compute)(id, SEL, NSString *, NSError **);
static id pm_compute_spy(id object, SEL selector, NSString *name,
                         NSError **error)
{
    id result = pm_compute(object, selector, name, error);
    if (result)
        [pm_names setObject:name forKey:result];
    return result;
}
static void (*pm_set_pipeline)(id, SEL, id);
static void pm_pipeline_spy(id object, SEL selector, id pipeline)
{
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
    NSString *name = pipeline ? [pm_names objectForKey:pipeline] : nil;
    if (name)
        pm_encoders[key] = name;
    else
        [pm_encoders removeObjectForKey:key];
    pm_set_pipeline(object, selector, pipeline);
}
static void (*pm_dispatch)(id, SEL, MTLSize, MTLSize);
static void pm_dispatch_spy(id object, SEL selector, MTLSize threads,
                            MTLSize group)
{
    NSString *name =
        pm_encoders[[NSValue valueWithPointer:(__bridge const void *)object]];
    pm_expansions += [name isEqualToString:@"nv2a_expand_geometry"];
    pm_gathers += [name isEqualToString:@"nv2a_vertex_stream_gather"];
    pm_dispatch(object, selector, threads, group);
}
static NSArray *(*pm_geometry)(id, SEL, NV2AMetalVertexSlice *,
                               enum NV2AMetalPrimitive,
                               const NV2AMetalGeometryRasterConfig *, BOOL,
                               BOOL, BOOL, NV2AMetalCommands *, NSError **);
static NSArray *pm_geometry_spy(id object, SEL selector,
                                NV2AMetalVertexSlice *slice,
                                enum NV2AMetalPrimitive primitive,
                                const NV2AMetalGeometryRasterConfig *config,
                                BOOL smooth, BOOL first, BOOL perspective,
                                NV2AMetalCommands *commands, NSError **error)
{
    pm_adapters++;
    if (pm_reference) {
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
        NSArray<NV2AMetalGeometryResult *> *result =
            [object encodeRasterVertices:vertices
                                   first:offset
                                   count:slice.vertexCount
                               primitive:primitive
                                  config:config
                                  smooth:smooth
                          firstProvoking:first
                            zPerspective:perspective
                                commands:commands
                                   error:error];
        if (pm_group_reference && result.count == 2) {
            /* Deliberately group all front then all back primitives. This
             * negative control must differ from the ordered render. */
            for (NV2AMetalGeometryResult *g in result) {
                [g setValue:@1 forKey:@"primitiveCount"];
                [g setValue:@(g.vertexCount) forKey:@"verticesPerPrimitive"];
            }
        }
        return result;
    }
    NSArray<NV2AMetalGeometryResult *> *result =
        pm_geometry(object, selector, slice, primitive, config, smooth, first,
                    perspective, commands, error);
    if (result && polygon_compact_results(result, slice, primitive, config,
                                          perspective, &pm_compact_fills)) {
        pm_compact_adapters++;
        if (slice.indexedVertices)
            pm_indexed++;
        return result;
    }
    if (result && pm_direct) {
        BOOL mixed = config->front != config->back;
        assert(result.count == (mixed ? 2u : 1u));
        BOOL quads = primitive == NV2AMetalPrimitiveQuads ||
                     primitive == NV2AMetalPrimitiveQuadStrip;
        NSUInteger primitives =
            primitive == NV2AMetalPrimitiveTriangles ?
                slice.vertexCount / 3 :
            primitive == NV2AMetalPrimitiveQuads ?
                slice.vertexCount / 4 :
            primitive == NV2AMetalPrimitiveQuadStrip ?
                (slice.vertexCount < 4 ? 0 : slice.vertexCount / 2 - 1) :
                (slice.vertexCount < 3 ? 0 : slice.vertexCount - 2);
        NSUInteger source = primitive == NV2AMetalPrimitiveTriangles ?
                                slice.vertexCount / 3 * 3 :
                            primitive == NV2AMetalPrimitiveQuads ?
                                slice.vertexCount / 4 * 4 :
                            primitive == NV2AMetalPrimitiveQuadStrip ?
                                slice.vertexCount / 2 * 2 :
                                slice.vertexCount;
        for (NSUInteger face = 0; face < result.count; face++) {
            NV2AMetalGeometryResult *g = result[face];
            enum NV2AMetalPolygonMode mode =
                face ? config->back : config->front;
            NSUInteger width = mode == NV2AMetalPolygonPoint ? (quads ? 4 : 3) :
                               mode == NV2AMetalPolygonLine  ? (quads ? 8 : 6) :
                                                               (quads ? 6 : 3);
            unsigned options = g.directPolygonOptions | g.directQuadOptions |
                               g.directTriangleOptions;
            assert(g.polygonMode == mode && g.vertices == slice.buffer &&
                   g.indexedVertices == slice.indexedVertices &&
                   g.sourceVertexCount == source &&
                   g.primitiveCount == primitives &&
                   g.vertexCount == primitives * width &&
                   g.verticesPerPrimitive == width && !g.directPoints &&
                   !g.directLineMode);
            if (mode == NV2AMetalPolygonFill)
                assert(g.directTriangles && !g.directPolygonOptions &&
                       !g.directQuadOptions);
            else
                assert(!g.directTriangles &&
                       (quads ?
                            g.directQuadOptions && !g.directPolygonOptions :
                            g.directPolygonOptions && !g.directQuadOptions));
            if (quads)
                assert(!(options & NV2AMetalDirectTriangleFirst));
            if (mixed)
                assert(options & (face ? NV2AMetalDirectTriangleCullFront :
                                         NV2AMetalDirectTriangleCullBack));
            if (slice.indexedVertices) {
                assert(g.physicalVertexCount ==
                           slice.indexedVertices.physicalVertexCount &&
                       g.indexOffset == slice.firstVertex &&
                       g.physicalVertexCount < slice.vertexCount);
                pm_indexed++;
            } else
                assert(g.firstVertex == slice.firstVertex);
        }
    } else if (result) {
        for (NV2AMetalGeometryResult *g in result)
            assert(!g.directQuadOptions && !g.directPolygonOptions &&
                   !g.directTriangles);
    }
    return result;
}
static BOOL (*pm_emit)(id, SEL, id, id, NSError **);
static BOOL pm_emit_spy(id object, SEL selector, id encoder, id commands,
                        NSError **error)
{
    BOOL ok = pm_emit(object, selector, encoder, commands, error);
    if (ok && pm_fail_emit) {
        pm_fail_emit = NO;
        pm_emit_failures++;
        if (error)
            *error = [NSError errorWithDomain:@"test.polygon-late-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static BOOL (*pm_range_emit)(id, SEL, id, id, NSUInteger, NSUInteger,
                             NSError **);
static BOOL pm_range_emit_spy(id object, SEL selector, id encoder, id commands,
                              NSUInteger first, NSUInteger count,
                              NSError **error)
{
    BOOL ok =
        pm_range_emit(object, selector, encoder, commands, first, count, error);
    if (ok && pm_fail_emit) {
        pm_fail_emit = NO;
        pm_emit_failures++;
        if (error)
            *error = [NSError errorWithDomain:@"test.polygon-late-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static const unsigned pm_topologies[] = {
    PRIM_TYPE_TRIANGLES, PRIM_TYPE_TRIANGLE_STRIP, PRIM_TYPE_TRIANGLE_FAN,
    PRIM_TYPE_QUADS, PRIM_TYPE_QUAD_STRIP
};
static void pm_scene(unsigned topology, unsigned front, unsigned back,
                     unsigned program, BOOL indexed, unsigned boundary,
                     unsigned special)
{
    /* Reuse the established PGRAPH program, report, DMA and attachment
     * fixture; replace only the guest scene and raster modes below. */
    qm_scene(0, front, program, indexed, boundary, 0);
    PGRAPHState *pg = &state->pgraph;
    pg->primitive_mode = pm_topologies[topology];
    pg->regs_[NV_PGRAPH_SETUPRASTER] =
        front | back << 2 | NV_PGRAPH_SETUPRASTER_TWO_SIDE |
        NV_PGRAPH_SETUPRASTER_POFFSETPOINTENABLE |
        NV_PGRAPH_SETUPRASTER_POFFSETLINEENABLE |
        NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE |
        (boundary & 1 ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0);
    unsigned cull = front != back ? 0 : (program + topology + indexed) % 3;
    if (cull)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_CULLENABLE | cull << 21;
    if (special == 1 || special == 8)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE;
    if (special == 2)
        pg->surface_scale_factor = 2;
    if (special == 3 || special == 10)
        pg->regs_[NV_PGRAPH_CONTROL_0] |=
            NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;
    if (special == 4 || special == 9 || special == 10)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    if (special >= 5 && special <= 7)
        pg->primitive_mode = PRIM_TYPE_POLYGON;
    /* Genuine polygon fill/thin wire are direct now. Keep these two cases
     * strict fallbacks using a real unsupported coverage/depth policy. */
    if (special == 5)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |= NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    if (special == 6)
        pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;
    if (front != back) {
        pg->regs_[NV_PGRAPH_BLEND] = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
        /* Only the first two overlapping fragments pass. Grouping all front
         * before all back work changes which colors reach the framebuffer. */
        pg->regs_[NV_PGRAPH_CONTROL_1] =
            NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 5 << 4 | 0x13 << 8 |
            0xff << 16 | 0xffu << 24;
    }
    const float physical[8][4] = {
        { .5f, .5f, 30000, 1 },  { 6.5f, .5f, 31000, 1 },
        { .5f, 6.5f, 32000, 1 }, { 6.5f, 6.5f, 31500, 1 },
        { .5f, .5f, 30500, 1 },  { 6.5f, .5f, 31200, 1 },
        { .5f, 6.5f, 32500, 1 }, { 6.5f, 6.5f, 31700, 1 }
    };
    static const uint32_t indices[5][13] = {
        { 0, 1, 2, 0, 2, 1, 4, 5, 6, 4, 6, 5, 3 },
        { 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 7 },
        { 0, 1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5 },
        { 0, 1, 3, 2, 0, 2, 3, 1, 4, 5, 7, 6, 5 },
        { 0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 6, 7, 5 }
    };
    cpu_write(16384, 1024);
    for (unsigned v = 0; v < (indexed ? 8u : 13u); v++) {
        unsigned original = indexed ? v : indices[topology][v];
        memcpy(state->vram_ptr + 16384 + v * 16, physical[original], 16);
        const float color[2][4] = {
            { (original + 1) / 9.f, .25f, (8 - original) / 9.f, .5f },
            { .125f, (original + 1) / 9.f, (8 - original) / 10.f, .75f }
        };
        memcpy(state->vram_ptr + 16640 + v * 16, color[0], 16);
        memcpy(state->vram_ptr + 16896 + v * 16, color[1], 16);
    }
    if (indexed)
        memcpy(pg->inline_elements, indices[topology], sizeof(indices[0]));
}
static void pm_pair(unsigned topology, unsigned front, unsigned back,
                    unsigned program, BOOL indexed, unsigned boundary,
                    unsigned special)
{
    uint8_t frame[512];
    uint32_t current[16][4], constants[192][4];
    bool dirty[192];
    NSData *pending = nil, *vertex = nil, *begin = nil, *failedPending = nil;
    uint32_t referenceQuery = 0;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        pm_scene(topology, front, back, program, indexed, boundary, special);
        pm_reference = !candidate;
        pm_direct = special == 0 || special == 10;
        pm_fail_emit = NO;
        pm_expansions = pm_gathers = pm_adapters = pm_indexed = 0;
        pm_compact_adapters = pm_compact_fills = 0;
        unsigned failures = pm_emit_failures;
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
                pm_fail_emit = YES;
                assert(![draw endWithError:&error] && error && !pm_fail_emit &&
                       pm_emit_failures == failures + 1);
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
        assert(pm_adapters && pg->draw_time == 1);
        if (candidate && pm_compact_adapters) {
            assert(pm_expansions == pm_compact_fills);
            if (indexed && program < 2)
                assert(pm_indexed && pm_gathers == pm_compact_fills);
            else
                assert(!pm_gathers);
        } else if (candidate && pm_direct) {
            assert(!pm_expansions && !pm_gathers);
            if (indexed && program < 2)
                assert(pm_indexed);
        } else {
            assert(pm_expansions);
            if (indexed && program < 2)
                assert(pm_gathers);
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
        if (candidate && pm_direct && front == back && front > 0) {
            pm_samples[program][front == 2] += query;
            const uint32_t red = UINT32_C(0xffff0000),
                           initialZeta = UINT32_C(0xffffff11);
            for (unsigned byte = 0; byte < 256; byte++) {
                pm_color_bytes[program][front == 2] +=
                    state->vram_ptr[1024 + byte] !=
                    ((const uint8_t *)&red)[byte % 4];
                pm_zeta_bytes[program][front == 2] +=
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
                        "Polygon PGRAPH mismatch topology%u front%u/back%u "
                        "program%u "
                        "indexed%d boundary%u special%u query%u/%u\n",
                        topology, front, back, program, indexed, boundary,
                        special, query, referenceQuery);
                abort();
            }
            for (unsigned i = 0; i < 16; i++)
                assert(!memcmp(current[i],
                               pg->vertex_attributes[i].inline_value, 16));
            assert(!memcmp(constants, pg->vsh_constants, sizeof(constants)) &&
                   !memcmp(dirty, pg->vsh_constants_dirty, sizeof(dirty)));
        }
    }
    NSMutableData *image = [NSMutableData dataWithBytes:state->vram_ptr + 1024
                                                 length:256];
    [image appendBytes:state->vram_ptr + 4096 length:256];
    pm_last_frame = image;
}
static void polygon_modes_pgraph_tests(void)
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
    IMP replacements[] = { (IMP)pm_geometry_spy, (IMP)pm_compute_spy,
                           (IMP)pm_pipeline_spy, (IMP)pm_dispatch_spy,
                           (IMP)pm_emit_spy,     (IMP)pm_range_emit_spy };
    IMP originals[6];
    pm_names = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                                                    NSPointerFunctionsObjectPointerPersonality
                                      valueOptions:NSPointerFunctionsStrongMemory];
    pm_encoders = [NSMutableDictionary new];
    id existing = [[draw valueForKey:@"geometry"] valueForKey:@"pipeline"];
    if (existing)
        [pm_names setObject:@"nv2a_expand_geometry" forKey:existing];
    for (unsigned i = 0; i < 6; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    pm_geometry = (void *)originals[0];
    pm_compute = (void *)originals[1];
    pm_set_pipeline = (void *)originals[2];
    pm_dispatch = (void *)originals[3];
    pm_emit = (void *)originals[4];
    pm_range_emit = (void *)originals[5];
    memset(pm_samples, 0, sizeof(pm_samples));
    memset(pm_color_bytes, 0, sizeof(pm_color_bytes));
    memset(pm_zeta_bytes, 0, sizeof(pm_zeta_bytes));
    unsigned pairs = 0;
    @try {
        for (unsigned program = 0; program < 3; program++)
            for (unsigned topology = 0; topology < 3; topology++)
                for (unsigned mode = 1; mode <= 2; mode++)
                    for (unsigned indexed = 0; indexed < 2; indexed++) {
                        unsigned boundary =
                            (program + topology + mode + indexed) % 3;
                        pm_pair(topology, mode, mode, program, indexed,
                                boundary, 0);
                        pairs++;
                    }
        for (unsigned topology = 0; topology < 5; topology++)
            for (unsigned front = 0; front < 3; front++)
                for (unsigned back = 0; back < 3; back++) {
                    if (front == back)
                        continue;
                    unsigned ordinal = topology * 9 + front * 3 + back;
                    pm_pair(topology, front, back, ordinal % 3, ordinal & 1,
                            ordinal % 3, 0);
                    pairs++;
                }
        /* Deliberately reorder otherwise unchanged compute results. Require
         * visible sensitivity, not just equality of two empty images. */
        pm_order_controls = 0;
        for (unsigned topology = 0; topology < 5; topology += 3) {
            pm_pair(topology, 0, 1, 1, YES, 0, 0);
            pairs++;
            NSData *ordered = pm_last_frame;
            pm_scene(topology, 0, 1, 1, YES, 0, 0);
            pm_reference = pm_group_reference = YES;
            pm_direct = YES;
            qemu_mutex_lock(&state->pgraph.lock);
            require([draw drawWithError:&error], error);
            qemu_mutex_unlock(&state->pgraph.lock);
            read_vram(1024, 256);
            read_vram(4096, 256);
            pm_group_reference = NO;
            assert(memcmp(ordered.bytes, state->vram_ptr + 1024, 256));
            pm_order_controls++;
        }
        for (unsigned topology = 0; topology < 3; topology++)
            for (unsigned special = 1; special <= 4; special++) {
                unsigned mode = special == 4 ? 0 : 2;
                pm_pair(topology, mode, mode, 1, YES, 0, special);
                pairs++;
            }
        for (unsigned topology = 0; topology < 5; topology++) {
            pm_pair(topology, 2, 1, 1, YES, 0, 8);
            pm_pair(topology, 0, 1, 2, YES, 2, 9);
            pairs += 2;
        }
        for (unsigned special = 5; special <= 6; special++) {
            unsigned mode = special == 5 ? 0 : 2;
            pm_pair(0, mode, mode, 1, YES, 0, special);
            pairs++;
        }
        for (unsigned topology = 0; topology < 3; topology++) {
            pm_pair(topology, 1, 1, 1, YES, 0, 10);
            pairs++;
        }
        for (unsigned candidate = 0; candidate < 2; candidate++) {
            pm_scene(0, 1, 1, 1, YES, 0, 7);
            pm_reference = !candidate;
            pm_direct = NO;
            pm_expansions = pm_gathers = 0;
            uint32_t current[16][4], constants[192][4];
            for (unsigned i = 0; i < 16; i++)
                memcpy(current[i],
                       state->pgraph.vertex_attributes[i].inline_value, 16);
            memcpy(constants, state->pgraph.vsh_constants, sizeof(constants));
            error = nil;
            qemu_mutex_lock(&state->pgraph.lock);
            assert(![draw drawWithError:&error] && error &&
                   !state->pgraph.draw_time && !pm_expansions);
            qemu_mutex_unlock(&state->pgraph.lock);
            for (unsigned i = 0; i < 16; i++)
                assert(!memcmp(current[i],
                               state->pgraph.vertex_attributes[i].inline_value,
                               16));
            assert(!memcmp(constants, state->pgraph.vsh_constants,
                           sizeof(constants)));
        }
        pairs++;
        for (unsigned topology = 0; topology < 3; topology++) {
            for (unsigned candidate = 0; candidate < 2; candidate++) {
                pm_scene(topology, 1, 1, 2, YES, 0, 0);
                pm_reference = !candidate;
                pm_direct = YES;
                pm_expansions = pm_gathers = pm_adapters = 0;
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
                       !state->pgraph.draw_time && !pm_adapters &&
                       !pm_expansions && !pm_gathers);
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
        pm_names = nil;
        pm_encoders = nil;
        pm_reference = pm_fail_emit = pm_group_reference = NO;
        pm_last_frame = nil;
    }
    assert(pairs == 99 && pm_order_controls == 2);
    uint64_t samples[2] = { 0 }, colors[2] = { 0 }, zeta[2] = { 0 };
    for (unsigned program = 0; program < 3; program++)
        for (unsigned mode = 0; mode < 2; mode++) {
            assert(pm_samples[program][mode] && pm_color_bytes[program][mode] &&
                   pm_zeta_bytes[program][mode]);
            samples[mode] += pm_samples[program][mode];
            colors[mode] += pm_color_bytes[program][mode];
            zeta[mode] += pm_zeta_bytes[program][mode];
        }
    printf("Polygon direct visibility Point/Wire: %llu/%llu samples, %llu/%llu "
           "changed color bytes, "
           "%llu/%llu changed depth-stencil bytes; each Fixed/readonly/writer "
           "group nonzero PASS\n",
           (unsigned long long)samples[0], (unsigned long long)samples[1],
           (unsigned long long)colors[0], (unsigned long long)colors[1],
           (unsigned long long)zeta[0], (unsigned long long)zeta[1]);
    printf("Polygon point/wire PGRAPH: %u exact "
           "framebuffer/depth-stencil/Current/constants/query pairs; "
           "fixed/readonly/writer, arrays/remap, flat/smooth/TwoSide/cull and "
           "split slopes; "
           "zero direct geometry expansion/gather, prefix/Restore/late-raster "
           "retry, "
           "mixed primitive Blend/Stencil order with 2 negative controls, "
           "wide/smooth/W-wire compact results, compact smooth fill and full "
           "input bounds PASS\n",
           pairs);
    groups += pairs;
}
#endif
