/* Compact lines PGRAPH integration against unchanged compute geometry.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_LINES_PGRAPH_H
#define TEST_METAL_COMPACT_LINES_PGRAPH_H
static BOOL clp_reference, clp_fail_emit;
static unsigned clp_adapters, clp_indexed, clp_compact, clp_expansions,
    clp_gathers, clp_failures, clp_pairs;
static uint64_t clp_visible[3], clp_changed[3];
/* Released pipeline/encoder addresses must not name a later unrelated object. */
static NSMapTable<id, NSString *> *clp_names, *clp_encoders;
static id (*clp_compute)(id, SEL, NSString *, NSError **);
static id clp_compute_spy(id object, SEL selector, NSString *name,
                          NSError **error)
{
    id result = clp_compute(object, selector, name, error);
    if (result)
        [clp_names setObject:name forKey:result];
    return result;
}
static void (*clp_pipeline)(id, SEL, id);
static void clp_pipeline_spy(id object, SEL selector, id pipeline)
{
    NSString *name = [clp_names objectForKey:pipeline];
    if (name)
        [clp_encoders setObject:name forKey:object];
    else
        [clp_encoders removeObjectForKey:object];
    clp_pipeline(object, selector, pipeline);
}
static void (*clp_dispatch)(id, SEL, MTLSize, MTLSize);
static void clp_dispatch_spy(id object, SEL selector, MTLSize threads,
                             MTLSize group)
{
    NSString *name = [clp_encoders objectForKey:object];
    clp_compact += [name isEqualToString:@"nv2a_compact_lines"] ||
                   [name isEqualToString:@"nv2a_compact_indexed_lines"];
    clp_expansions += [name isEqualToString:@"nv2a_expand_geometry"];
    clp_gathers += [name isEqualToString:@"nv2a_vertex_stream_gather"];
    clp_dispatch(object, selector, threads, group);
}
static NSArray *(*clp_geometry)(id, SEL, NV2AMetalVertexSlice *,
                                enum NV2AMetalPrimitive,
                                const NV2AMetalGeometryRasterConfig *, BOOL,
                                BOOL, BOOL, NV2AMetalCommands *, NSError **);
static NSArray *clp_geometry_spy(id object, SEL selector,
                                 NV2AMetalVertexSlice *slice,
                                 enum NV2AMetalPrimitive primitive,
                                 const NV2AMetalGeometryRasterConfig *config,
                                 BOOL smooth, BOOL first, BOOL perspective,
                                 NV2AMetalCommands *commands, NSError **error)
{
    assert(primitive >= NV2AMetalPrimitiveLines &&
           primitive <= NV2AMetalPrimitiveLineStrip);
    clp_adapters++;
    unsigned compact = clp_compact, expansions = clp_expansions,
             gathers = clp_gathers;
    NSArray<NV2AMetalGeometryResult *> *results;
    if (clp_reference) {
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
        results = clp_geometry(object, selector, slice, primitive, config,
                               smooth, first, perspective, commands, error);
    if (!results)
        return nil;
    assert(results.count == 1);
    NV2AMetalGeometryResult *g = results[0];
    NSUInteger n = slice.vertexCount;
    NSUInteger segments = primitive == NV2AMetalPrimitiveLines ?
                              n / 2 :
                              (n < 2                                   ? 0 :
                               primitive == NV2AMetalPrimitiveLineLoop ? n :
                                                                         n - 1);
    BOOL eligible = config->lineWidth > 1 || config->lineSmooth || perspective;
    assert(g.vertexCount == segments * (eligible ? 6 : 2));
    if (!clp_reference && eligible && segments) {
        assert(
            g.compactLines && g.expandedLines && g.vertices == slice.buffer &&
            g.indexedVertices == slice.indexedVertices &&
            g.lineCoverage.storageMode == MTLStorageModePrivate &&
            g.lineCoverage.length == segments * sizeof(NV2AMetalCompactLine) &&
            g.sourceVertexCount ==
                (primitive == NV2AMetalPrimitiveLines ? n / 2 * 2 : n));
        if (slice.indexedVertices) {
            assert(g.physicalVertexCount ==
                       slice.indexedVertices.physicalVertexCount &&
                   g.indexOffset == slice.firstVertex && !g.firstVertex);
            clp_indexed++;
        } else
            assert(g.firstVertex == slice.firstVertex && !g.indexOffset);
    }
    if (clp_reference)
        assert(clp_compact == compact &&
               clp_expansions - expansions == !!segments &&
               clp_gathers - gathers == !!slice.indexedVertices);
    else
        assert(clp_compact - compact == !!(eligible && segments) &&
               clp_expansions == expansions && clp_gathers == gathers);
    return results;
}
static BOOL (*clp_emit)(id, SEL, id, id, NSError **);
static BOOL clp_emit_spy(id object, SEL selector, id encoder, id commands,
                         NSError **error)
{
    BOOL ok = clp_emit(object, selector, encoder, commands, error);
    if (ok && clp_fail_emit) {
        clp_fail_emit = NO;
        clp_failures++;
        if (error)
            *error = [NSError errorWithDomain:@"test.compact-line-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static void clp_scene(unsigned topology, unsigned style, unsigned program,
                      BOOL indexed, unsigned boundary, unsigned variant)
{
    qm_scene(0, 2, program, indexed, boundary, 0);
    PGRAPHState *pg = &state->pgraph;
    pg->primitive_mode = (unsigned[]){ PRIM_TYPE_LINES, PRIM_TYPE_LINE_STRIP,
                                       PRIM_TYPE_LINE_LOOP }[topology];
    pg->regs_[NV_PGRAPH_SETUPRASTER] =
        (style & 1 ? NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE : 0) |
        NV_PGRAPH_SETUPRASTER_CULLENABLE | 3u << 21;
    pg->surface_scale_factor = style & 2 ? 2 : 1;
    pg->regs_[NV_PGRAPH_CONTROL_3] =
        (variant & 1 ? NV_PGRAPH_CONTROL_3_SHADEMODE : 0) |
        (variant & 2 ? NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX : 0);
    if (style & 4)
        pg->regs_[NV_PGRAPH_CONTROL_0] |=
            NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;
    if (style & 8)
        pg->regs_[NV_PGRAPH_ANTIALIASING] = NV_PGRAPH_ANTIALIASING_ENABLE;
    const float physical[8][4] = {
        { -2, 1.25f, 30000, 1 },     { 6.5f, 1.25f, 31000, 1.5f },
        { 2.5f, -2, 32500, 1 },      { 2.5f, 9, 30500, .75f },
        { .5f, 6.5f, 33000, 1.25f }, { 6.5f, .5f, 34000, 1 },
        { .5f, .5f, 35000, .625f },  { 6.5f, 6.5f, 33500, 1.375f }
    };
    const uint32_t indices[12] = { 0, 1, 2, 3, 4, 5, 6, 7, 0, 4, 2, 5 };
    cpu_write(16384, 1024);
    for (unsigned v = 0; v < (indexed ? 8u : 12u); v++) {
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
        pg->inline_elements_length = 12;
        memcpy(pg->inline_elements, indices, sizeof(indices));
    } else
        pg->draw_arrays_count[0] = 12;
    unsigned aa = variant & 16 ? 2 : variant & 8 ? 1 : 0;
    unsigned width = aa ? 16 : 8, height = aa == 2 ? 16 : 8;
    pg->surface_shape.anti_aliasing = aa;
    pg->surface_color.pitch = pg->surface_zeta.pitch = width * 4;
    cpu_write(1024, width * height * 4);
    cpu_write(4096, width * height * 4);
    for (unsigned i = 0; i < width * height; i++) {
        const uint32_t red = UINT32_C(0xffff0000), zeta = UINT32_C(0xffffff11);
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
        memcpy(state->vram_ptr + 4096 + i * 4, &zeta, 4);
    }
    if (variant & 4) {
        /* Distinct endpoint texcoords and fog also run under flat color.
         * Neither interpolant may accidentally be loaded from the provoker. */
        dma[2].limit = 2047;
        cpu_write(17152, 512);
        for (unsigned v = 0; v < (indexed ? 8u : 12u); v++) {
            unsigned original = indexed ? v : indices[v];
            float tex[4] = { (original % 4) * 2 + .25f,
                             (original / 4) * 6 + .5f, 0, 1 };
            float fog[4] = { (original + 1) / 9.f, 0, 0, 1 };
            memcpy(state->vram_ptr + 17152 + v * 16, tex, 16);
            memcpy(state->vram_ptr + 17408 + v * 16, fog, 16);
        }
        pg->vertex_attributes[9] = pg->vertex_attributes[3];
        pg->vertex_attributes[9].offset = 768;
        pg->vertex_attributes[5] = pg->vertex_attributes[3];
        pg->vertex_attributes[5].offset = 1024;
        if (program) {
            unsigned slot = program == 2 ? 3 : 2;
            mov(slot++, 7, 7, false);
            mov(slot++, 9, 9, false);
            mov(slot, 5, 5, true);
        }
        pg->regs_[NV_PGRAPH_CSV0_D] |= NV_PGRAPH_CSV0_D_FOGENABLE |
                                       NV_PGRAPH_CSV0_D_FOGGENMODE_FOG_X << 22;
        pg->regs_[NV_PGRAPH_CONTROL_3] |= NV_PGRAPH_CONTROL_3_FOGENABLE;
        reg_float(NV_PGRAPH_FOGPARAM0, 1);
        reg_float(NV_PGRAPH_FOGPARAM1, 1);
        texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
        pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
            (PS_REGISTER_FOG | PS_CHANNEL_ALPHA) << 8;
        cpu_write(32768, 256);
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                uint32_t pixel =
                    0xff000000 | (x * 31) << 16 | (y * 31) << 8 | 0x35;
                memcpy(state->vram_ptr + 32768 + (y * 8 + x) * 4, &pixel, 4);
            }
    }
}
static NSUInteger clp_frame_bytes(void)
{
    unsigned aa = state->pgraph.surface_shape.anti_aliasing;
    return (aa ? 16 : 8) * (aa == 2 ? 16 : 8) * 4;
}
static NSData *clp_capture(uint32_t query)
{
    PGRAPHState *pg = &state->pgraph;
    NSMutableData *result = [NSMutableData dataWithBytes:state->vram_ptr + 1024
                                                  length:clp_frame_bytes()];
    [result appendBytes:state->vram_ptr + 4096 length:clp_frame_bytes()];
    for (unsigned i = 0; i < 16; i++)
        [result appendBytes:pg->vertex_attributes[i].inline_value length:16];
    [result appendBytes:pg->vsh_constants length:sizeof(pg->vsh_constants)];
    [result appendBytes:pg->vsh_constants_dirty
                 length:sizeof(pg->vsh_constants_dirty)];
    [result appendBytes:&query length:sizeof(query)];
    return result;
}
static void clp_pair(unsigned topology, unsigned style, unsigned program,
                     BOOL indexed, unsigned boundary, unsigned variant)
{
    NSData *reference = nil, *pending = nil, *vertex = nil, *begin = nil,
           *failedPending = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        clp_scene(topology, style, program, indexed, boundary, variant);
        clp_reference = !candidate;
        clp_fail_emit = NO;
        clp_adapters = clp_indexed = clp_compact = clp_expansions =
            clp_gathers = 0;
        unsigned failures = clp_failures;
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
                pg->inline_elements_length = 12;
            else
                pg->draw_arrays_count[0] = 12;
            if (boundary == 2) {
                clp_fail_emit = YES;
                assert(![draw endWithError:&error] && error && !clp_fail_emit &&
                       clp_failures == failures + 1);
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
        assert(clp_adapters && pg->draw_time == 1);
        if (candidate) {
            if (clp_expansions || clp_gathers)
                fprintf(stderr, "Compact line work topology%u style%u program%u "
                        "indexed%d boundary%u variant%u adapters%u packs%u "
                        "expansions%u gathers%u\n", topology, style, program,
                        indexed, boundary, variant, clp_adapters, clp_compact,
                        clp_expansions, clp_gathers);
            assert(!clp_expansions && !clp_gathers);
            if (indexed && program < 2 && !boundary && style != 9)
                assert(clp_indexed);
        }
        require([draw.reports getReport:1u << 24 error:&error] &&
                    [draw.reports processWithError:&error],
                error);
        uint32_t query = report_value(0);
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, clp_frame_bytes());
        read_vram(4096, clp_frame_bytes());
        if (program == 2)
            expect_context(191, 15, 12, YES);
        NSData *actual = clp_capture(query);
        if (!candidate)
            reference = actual;
        else {
            if (![reference isEqualToData:actual]) {
                fprintf(stderr,
                        "Compact line PGRAPH mismatch topology%u style%u "
                        "program%u indexed%d boundary%u variant%u query%u\n",
                        topology, style, program, indexed, boundary, variant,
                        query);
                abort();
            }
            clp_visible[program] += query;
            const uint32_t red = UINT32_C(0xffff0000);
            for (unsigned byte = 0; byte < clp_frame_bytes(); byte++)
                clp_changed[program] += state->vram_ptr[1024 + byte] !=
                                        ((const uint8_t *)&red)[byte % 4];
        }
    }
    clp_pairs++;
}
static void compact_lines_pgraph_tests(void)
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
    IMP replacements[] = { (IMP)clp_geometry_spy, (IMP)clp_compute_spy,
                           (IMP)clp_pipeline_spy, (IMP)clp_dispatch_spy,
                           (IMP)clp_emit_spy },
        originals[5];
    clp_names = [[NSMapTable alloc]
        initWithKeyOptions:NSPointerFunctionsWeakMemory |
                           NSPointerFunctionsObjectPointerPersonality
              valueOptions:NSPointerFunctionsStrongMemory capacity:16];
    clp_encoders = [[NSMapTable alloc]
        initWithKeyOptions:NSPointerFunctionsWeakMemory |
                           NSPointerFunctionsObjectPointerPersonality
              valueOptions:NSPointerFunctionsStrongMemory capacity:16];
    for (unsigned i = 0; i < 5; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    clp_geometry = (void *)originals[0];
    clp_compute = (void *)originals[1];
    clp_pipeline = (void *)originals[2];
    clp_dispatch = (void *)originals[3];
    clp_emit = (void *)originals[4];
    @try {
        const unsigned styles[] = { 2, 1, 4, 7 };
        for (unsigned program = 0; program < 3; program++)
            for (unsigned topology = 0; topology < 3; topology++)
                for (unsigned indexed = 0; indexed < 2; indexed++)
                    for (unsigned style = 0; style < 4; style++)
                        clp_pair(topology, styles[style], program, indexed,
                                 (program + topology + indexed + style) % 3,
                                 (program + topology + style) % 4);
        for (unsigned topology = 0; topology < 3; topology++)
            for (unsigned program = 0; program < 3; program++) {
                clp_pair(topology, 7, program, YES, 0, 4);
                clp_pair(topology, 9, program, NO, 0, 1);
                clp_pair(topology, 7, program, YES, 0, 8 | 4);
                clp_pair(topology, 7, program, NO, 0, 16 | 1);
            }
    } @finally {
        for (unsigned i = 0; i < 5; i++)
            method_setImplementation(methods[i], originals[i]);
        [draw setValue:previousGeometry forKey:@"geometry"];
        clp_names = clp_encoders = nil;
        clp_reference = clp_fail_emit = NO;
    }
    for (unsigned program = 0; program < 3; program++)
        assert(clp_visible[program] && clp_changed[program]);
    printf("Compact lines PGRAPH: %u exact "
           "framebuffer/zeta/Current/constants/dirty/query pairs; "
           "Fixed/readonly/writer arrays/index, Lines/Strip/Loop "
           "wide/smooth/W/scale, "
           "AA/clip/flat/endpoints/texture/fog, one compact dispatch without "
           "expansion/gather, "
           "edge-AA thin control, prefix/Restore/late-raster retry PASS\n",
           clp_pairs);
    groups += clp_pairs;
}
#endif
