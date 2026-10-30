/* Cross-stream raster grouping versus independent ordered guest draws.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_STREAM_GROUP_H
#define TEST_METAL_STREAM_GROUP_H

static unsigned stream_plan_calls, stream_progress_calls, stream_partial_calls;
static id (*stream_original_plan)(id, SEL, NSArray *, BOOL, NSError **);
static id (*stream_original_progress)(id, SEL, id, NSError **);
static id (*stream_original_partial)(id, SEL, id, NSUInteger, NSArray *,
                                     NSError **);
static NV2AMetalPendingSpan *(*stream_relocate_span)(NV2AMetalPendingSpan *);
static BOOL (*stream_original_suffix)(id, SEL, NV2AMetalPendingSpan *,
                                      NV2AMetalPendingProgress *, NSError **);
static BOOL stream_suffix(id owner, SEL selector, NV2AMetalPendingSpan *span,
                          NV2AMetalPendingProgress *progress, NSError **error)
{
    if (span && stream_relocate_span)
        span = stream_relocate_span(span);
    return stream_original_suffix(owner, selector, span, progress, error);
}
static id stream_plan(id owner, SEL selector, NSArray *inputs, BOOL preserve,
                      NSError **error)
{
    stream_plan_calls++;
    return stream_original_plan(owner, selector, inputs, preserve, error);
}
static id stream_progress(id owner, SEL selector, id plan, NSError **error)
{
    stream_progress_calls++;
    return stream_original_progress(owner, selector, plan, error);
}
static id stream_partial(id owner, SEL selector, id plan, NSUInteger count,
                         NSArray *suffixes, NSError **error)
{
    stream_partial_calls++;
    return stream_original_partial(owner, selector, plan, count, suffixes,
                                   error);
}
static unsigned stream_geometry_calls, stream_expected_geometry,
    stream_geometry_fail_at;
static NSArray *(*stream_original_geometry)(
    id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger, enum NV2AMetalPrimitive,
    const NV2AMetalGeometryRasterConfig *, BOOL, BOOL, BOOL,
    NV2AMetalCommands *, NSError **);
static NSArray *stream_geometry(id owner, SEL selector, id<MTLBuffer> vertices,
                                NSUInteger firstVertex, NSUInteger count,
                                enum NV2AMetalPrimitive primitive,
                                const NV2AMetalGeometryRasterConfig *config,
                                BOOL smooth, BOOL first, BOOL perspective,
                                NV2AMetalCommands *commands, NSError **error)
{
    assert(!group_calls); /* No raster before the final geometry producer. */
    assert(!stream_relocate_span || firstVertex == 3);
    if (++stream_geometry_calls == stream_geometry_fail_at) {
        if (error)
            *error = [NSError errorWithDomain:@"test.stream-geometry"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return stream_original_geometry(owner, selector, vertices, firstVertex,
                                    count, primitive, config, smooth, first,
                                    perspective, commands, error);
}
static NV2AMetalPixelDraw *stream_encode(
    id owner, SEL selector, NV2AMetalGeometryResult *geometry,
    NSUInteger offset, NSUInteger count, const NV2AMetalPixelUniforms *uniforms,
    const NV2AMetalPixelTexture *textures, MTL4RenderPassDescriptor *pass,
    NV2AMetalDrawState *raster, NV2AMetalPixelRasterClass rasterClass,
    BOOL ignore, NV2AMetalCommands *commands, NSError **error)
{
    assert(stream_geometry_calls == stream_expected_geometry);
    return group_encode(owner, selector, geometry, offset, count, uniforms,
                        textures, pass, raster, rasterClass, ignore, commands,
                        error);
}
static void stream_scene(unsigned topology, unsigned operation,
                         unsigned programmed, unsigned streams)
{
    fixture();
    qemu_mutex_lock(&state->pgraph.lock);
    [draw.reports clear];
    qemu_mutex_unlock(&state->pgraph.lock);
    PGRAPHState *pg = &state->pgraph;
    dma[2].limit = 8191;
    pg->dma_report = 64;
    pg->zpass_pixel_count_enable = true;
    pg->draw_arrays_length = streams;
    pg->vertex_attributes[3] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .count = 4,
                           .size = 4,
                           .stride = 16,
                           .offset = 4096 };
    cpu_write(16384, 8192);
    for (unsigned i = 0; i < streams; i++) {
        pg->draw_arrays_start[i] = i * 6;
        pg->draw_arrays_count[i] =
            topology == 7 || (topology == 6 && (i & 1)) ? 1 : 6;
        for (unsigned j = 0; j < 6; j++) {
            float position[4];
            memcpy(position, face_scene[j], sizeof(position));
            /* Alternate nearer/farther values to exercise depth rejection. */
            position[2] = 30000 + (i & 1 ? 1000 : -(int)i * 128);
            float color[4] = { (i % 3) / 2.f, ((i + 1) % 3) / 2.f,
                               ((i + 2) % 3) / 2.f, .5f };
            memcpy(state->vram_ptr + 16384 + (i * 6 + j) * 16, position, 16);
            memcpy(state->vram_ptr + 20480 + (i * 6 + j) * 16, color, 16);
        }
    }
    if (programmed) {
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
        mov(0, 0, 0, false);
        mov(1, 3, 3, true);
    }
    if (topology == 1)
        pg->regs_[NV_PGRAPH_SETUPRASTER] =
            NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE;
    else if (topology == 2)
        pg->regs_[NV_PGRAPH_SETUPRASTER] = 2 << 2; /* Back lines/front fill. */
    else if (topology == 3)
        pg->primitive_mode = PRIM_TYPE_TRIANGLE_STRIP;
    else if (topology == 4)
        pg->primitive_mode = PRIM_TYPE_QUADS;
    else if (topology == 5)
        pg->primitive_mode = PRIM_TYPE_LINE_LOOP;
    if (operation == 1)
        pg->regs_[NV_PGRAPH_BLEND] = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
    else if (operation == 2) {
        pg->regs_[NV_PGRAPH_BLEND] = NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12;
        pg->regs_[NV_PGRAPH_CONTROL_0] &= ~NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE;
    } else if (operation == 3) {
        pg->surface_shape.zeta_format = 2;
        pg->surface_zeta.pitch = 32;
        pg->regs_[NV_PGRAPH_CONTROL_0] |=
            NV_PGRAPH_CONTROL_0_ZENABLE | NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
            NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE | 1 << 16;
        pg->regs_[NV_PGRAPH_CONTROL_1] =
            NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 | 0x5a << 8 |
            0xff << 16 | 0xffu << 24;
        pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 4 << 8;
        cpu_write(4096, 256);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t initial = 0xffffff11;
            memcpy(state->vram_ptr + 4096 + i * 4, &initial, 4);
        }
    }
}
static BOOL stream_draw(unsigned expected, NSError **error)
{
    Method geometry = class_getInstanceMethod(
        NV2AMetalGeometry.class,
        @selector(encodeNativeRasterVertices:first:count:primitive:config:
                  smooth:firstProvoking:zPerspective:commands:error:));
    Method pixel = class_getInstanceMethod(
        NV2AMetalPixelShader.class,
        @selector(prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                  rasterClass:ignorePolygonCulling:commands:error:));
    Method emit = class_getInstanceMethod(
        NV2AMetalPixelDraw.class,
        @selector(encodeWithRenderEncoder:commands:error:));
    assert(geometry && pixel && emit);
    stream_geometry_calls = group_calls = group_emissions = 0;
    stream_expected_geometry = expected;
    group_encoders = [NSMutableSet new];
    stream_original_geometry =
        (void *)method_setImplementation(geometry, (IMP)stream_geometry);
    group_original_encode =
        (void *)method_setImplementation(pixel, (IMP)stream_encode);
    group_original_emit =
        (void *)method_setImplementation(emit, (IMP)group_emit);
    Method plan = class_getInstanceMethod(
        NV2AMetalPendingJournal.class,
        @selector(planInputs:preservingLastArray:error:));
    Method progress = class_getInstanceMethod(
        NV2AMetalPendingJournal.class, @selector(beginProgressForPlan:error:));
    Method partial = class_getInstanceMethod(
        NV2AMetalPendingJournal.class,
        @selector(preparePlan:completedInputs:suffixes:error:));
    Method suffix =
        class_getInstanceMethod(NV2AMetalPendingJournal.class,
                                @selector(commitNextSuffix:progress:error:));
    assert(plan && progress && partial && suffix);
    stream_original_suffix =
        (void *)method_setImplementation(suffix, (IMP)stream_suffix);
    stream_original_plan =
        (void *)method_setImplementation(plan, (IMP)stream_plan);
    stream_original_progress =
        (void *)method_setImplementation(progress, (IMP)stream_progress);
    stream_original_partial =
        (void *)method_setImplementation(partial, (IMP)stream_partial);
    stream_plan_calls = stream_progress_calls = stream_partial_calls = 0;
    qemu_mutex_lock(&state->pgraph.lock);
    BOOL ok = [draw drawWithError:error];
    qemu_mutex_unlock(&state->pgraph.lock);
    method_setImplementation(plan, (IMP)stream_original_plan);
    method_setImplementation(progress, (IMP)stream_original_progress);
    method_setImplementation(partial, (IMP)stream_original_partial);
    method_setImplementation(suffix, (IMP)stream_original_suffix);
    assert(stream_partial_calls == 0);
    method_setImplementation(geometry, (IMP)stream_original_geometry);
    method_setImplementation(pixel, (IMP)group_original_encode);
    method_setImplementation(emit, (IMP)group_original_emit);
    if (ok) {
        assert(stream_progress_calls == 1 && stream_plan_calls == 3);
        assert(stream_geometry_calls == expected);
        assert(group_emissions == group_calls);
        assert(group_encoders.count == (group_calls ? 1 : 0));
    }
    return ok;
}
static uint32_t stream_report(void)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw.reports getReport:1u << 24 error:&error], error);
    require([draw.reports processWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    return reported;
}
static void stream_group_contract_tests(void)
{
    unsigned pairs = 0, referencePasses = 0, groupedPasses = 0;
    uint64_t samples = 0;
    NSError *error = nil;
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned topology = 0; topology < 8; topology++)
            for (unsigned operation = 0; operation < 4; operation++) {
                uint8_t reference[512];
                float current[2][4];
                uint32_t referenceQuery = 0;
                for (unsigned grouped = 0; grouped < 2; grouped++) {
                    stream_scene(topology, operation, programmed, 8);
                    PGRAPHState *pg = &state->pgraph;
                    group_fail_at = stream_geometry_fail_at = 0;
                    if (grouped) {
                        require(stream_draw(8, &error), error);
                        groupedPasses += group_encoders.count;
                    } else {
                        pg->draw_arrays_length = 1;
                        for (unsigned i = 0; i < 8; i++) {
                            pg->draw_arrays_start[0] = i * 6;
                            pg->draw_arrays_count[0] =
                                topology == 7 || (topology == 6 && (i & 1)) ?
                                    1 :
                                    6;
                            require(stream_draw(1, &error), error);
                            referencePasses += group_encoders.count;
                        }
                    }
                    uint32_t query = stream_report();
                    read_vram(1024, 256);
                    read_vram(4096, 256);
                    if (operation == 3 && topology != 7) {
                        unsigned changedStencil = 0;
                        for (unsigned i = 0; i < 64; i++)
                            changedStencil +=
                                state->vram_ptr[4096 + i * 4] != 0x11;
                        assert(changedStencil && query);
                    }
                    if (!grouped) {
                        memcpy(reference, state->vram_ptr + 1024, 256);
                        memcpy(reference + 256, state->vram_ptr + 4096, 256);
                        memcpy(current[0],
                               pg->vertex_attributes[0].inline_value, 16);
                        memcpy(current[1],
                               pg->vertex_attributes[3].inline_value, 16);
                        referenceQuery = query;
                    } else {
                        if (query != referenceQuery) {
                            fprintf(stderr,
                                    "Stream query mismatch program=%u "
                                    "topology=%u operation=%u: %u/%u\n",
                                    programmed, topology, operation, query,
                                    referenceQuery);
                            abort();
                        }
                        assert(!memcmp(reference, state->vram_ptr + 1024, 256));
                        assert(!memcmp(reference + 256, state->vram_ptr + 4096,
                                       256));
                        assert(!memcmp(current[0],
                                       pg->vertex_attributes[0].inline_value,
                                       16));
                        assert(!memcmp(current[1],
                                       pg->vertex_attributes[3].inline_value,
                                       16));
                        pairs++;
                        samples += query;
                    }
                }
            }
    /* A late geometry failure and a late raster preparation failure must cancel all
     * attachment/query effects, while retry uses completed immutable XF. */
    for (unsigned topology = 0; topology <= 2; topology += 2) {
        uint8_t reference[512];
        uint32_t referenceQuery;
        stream_scene(topology, 3, 1, 8);
        require(stream_draw(8, &error), error);
        referenceQuery = stream_report();
        read_vram(1024, 256);
        memcpy(reference, state->vram_ptr + 1024, 256);
        read_vram(4096, 256);
        memcpy(reference + 256, state->vram_ptr + 4096, 256);
        for (unsigned failure = 0; failure < 2; failure++) {
            stream_scene(topology, 3, 1, 8);
            group_fail_at = failure ? (topology == 2 ? 5 : 2) : 0;
            stream_geometry_fail_at = failure ? 0 : 7;
            error = nil;
            assert(!stream_draw(8, &error) && error);
            assert(state->pgraph.draw_time == 0 &&
                   !surfaces.cache.commands.commandBuffer);
            assert(!group_emissions && !group_encoders.count);
            if (!failure)
                assert(!group_calls);
            read_vram(1024, 256);
            for (unsigned i = 0; i < 64; i++)
                color(i % 8, i / 8, 0xffff0000);
            read_vram(4096, 256);
            for (unsigned i = 0; i < 64; i++) {
                uint32_t initial;
                memcpy(&initial, state->vram_ptr + 4096 + i * 4, 4);
                assert(initial == 0xffffff11);
            }
            group_fail_at = stream_geometry_fail_at = 0;
            require(stream_draw(8, &error), error);
            assert(state->pgraph.draw_time == 1 &&
                   stream_report() == referenceQuery);
            read_vram(1024, 256);
            assert(!memcmp(reference, state->vram_ptr + 1024, 256));
            read_vram(4096, 256);
            assert(!memcmp(reference + 256, state->vram_ptr + 4096, 256));
        }
    }
    group_encoders = nil;
    assert(pairs == 64 && samples > 0 && referencePasses == 416 &&
           groupedPasses == 56);
    printf(
        "PGRAPH stream group: %u exact color/depth-stencil/Current/query "
        "pairs, "
        "%llu samples; %u separate reference passes versus %u grouped passes; "
        "all geometry precedes raster, three plans/one progress/zero prefix updates per draw, four late-failure/retry cases PASS\n",
        pairs, (unsigned long long)samples, referencePasses, groupedPasses);
    groups++;
}
#endif
