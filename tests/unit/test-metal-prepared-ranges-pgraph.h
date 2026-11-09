/* Whole immutable raster packets versus legacy per-primitive preparation.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PREPARED_RANGES_PGRAPH_H
#define TEST_METAL_PREPARED_RANGES_PGRAPH_H

@interface PreparedRangeEncoderProbe : NSProxy
@property(nonatomic, strong) id target;
@property(nonatomic) unsigned mutations;
@end
@implementation PreparedRangeEncoderProbe
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    return [_target methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation
{
    if (invocation.selector != @selector(device) &&
        invocation.selector != @selector(commandBuffer))
        _mutations++;
    [invocation invokeWithTarget:_target];
}
@end

static BOOL pr_legacy, pr_grouped, pr_count_init, pr_checked;
static BOOL pr_expect_indexed;
static unsigned pr_prepare_calls, pr_packet_inits, pr_emit_calls,
    pr_fail_prepare, pr_fail_emit, pr_injected, pr_expected_emits,
    pr_indexed_results, pr_nonzero_emits;
static NSMutableDictionary<NSValue *, NSArray<NV2AMetalPixelDraw *> *>
    *pr_packets;
static NSMutableArray<NSArray<NV2AMetalPixelDraw *> *> *pr_faces;
static NSUInteger pr_widths[2];
static NV2AMetalCommands *pr_foreign;
static NSArray *(*pr_geometry)(id, SEL, NV2AMetalVertexSlice *,
                               enum NV2AMetalPrimitive,
                               const NV2AMetalGeometryRasterConfig *, BOOL,
                               BOOL, BOOL, NV2AMetalCommands *, NSError **);
static NSArray *pr_geometry_spy(id object, SEL selector,
                                NV2AMetalVertexSlice *slice,
                                enum NV2AMetalPrimitive primitive,
                                const NV2AMetalGeometryRasterConfig *config,
                                BOOL smooth, BOOL first, BOOL perspective,
                                NV2AMetalCommands *commands, NSError **error)
{
    NSArray *results = pr_geometry(object, selector, slice, primitive, config,
                                   smooth, first, perspective, commands, error);
    if (results) {
        assert(results.count == 2 && config->front != config->back);
        for (NV2AMetalGeometryResult *g in results) {
            assert(g.primitiveCount && g.verticesPerPrimitive &&
                   g.vertexCount == g.primitiveCount * g.verticesPerPrimitive);
            if (pr_expect_indexed) {
                NV2AMetalIndexedVertices *owner = g.indexedVertices;
                assert(owner && owner == slice.indexedVertices &&
                       owner.vertexCount == slice.vertexCount &&
                       owner.physicalVertexCount < owner.vertexCount &&
                       owner.vertices.length == owner.physicalVertexCount *
                                                    sizeof(NV2AMetalVertex) &&
                       owner.indices.length == owner.vertexCount * 4);
                pr_indexed_results++;
            }
        }
    }
    return results;
}
static NV2AMetalPixelDraw *(*pr_init)(id, SEL, NV2AMetalCommands *);
static NV2AMetalPixelDraw *pr_init_spy(id object, SEL selector,
                                       NV2AMetalCommands *commands)
{
    pr_packet_inits += pr_count_init;
    return pr_init(object, selector, commands);
}
static NV2AMetalPixelDraw *(*pr_prepare)(
    id, SEL, NV2AMetalGeometryResult *, NSUInteger, NSUInteger,
    const NV2AMetalPixelUniforms *, const NV2AMetalPixelTexture *,
    MTL4RenderPassDescriptor *, NV2AMetalDrawState *, NV2AMetalPixelRasterClass,
    BOOL, NV2AMetalCommands *, NSError **);
static NV2AMetalPixelDraw *pr_prepare_one(
    id object, SEL selector, NV2AMetalGeometryResult *geometry,
    NSUInteger offset, NSUInteger count, const NV2AMetalPixelUniforms *uniforms,
    const NV2AMetalPixelTexture *textures, MTL4RenderPassDescriptor *pass,
    NV2AMetalDrawState *state, NV2AMetalPixelRasterClass raster, BOOL ignore,
    NV2AMetalCommands *commands, NSError **error)
{
    pr_prepare_calls++;
    pr_count_init = YES;
    NV2AMetalPixelDraw *packet =
        pr_prepare(object, selector, geometry, offset, count, uniforms,
                   textures, pass, state, raster, ignore, commands, error);
    pr_count_init = NO;
    if (packet && pr_prepare_calls == pr_fail_prepare) {
        pr_injected++;
        if (error)
            *error = [NSError errorWithDomain:@"test.prepared-last-prepare"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return packet;
}
static NV2AMetalPixelDraw *pr_prepare_spy(
    id object, SEL selector, NV2AMetalGeometryResult *geometry,
    NSUInteger offset, NSUInteger count, const NV2AMetalPixelUniforms *uniforms,
    const NV2AMetalPixelTexture *textures, MTL4RenderPassDescriptor *pass,
    NV2AMetalDrawState *state, NV2AMetalPixelRasterClass raster, BOOL ignore,
    NV2AMetalCommands *commands, NSError **error)
{
    assert(!offset && count == geometry.vertexCount && geometry.primitiveCount);
    assert(pr_faces.count < 2);
    pr_widths[pr_faces.count] = geometry.verticesPerPrimitive;
    if (!pr_legacy) {
        NV2AMetalPixelDraw *packet = pr_prepare_one(
            object, selector, geometry, offset, count, uniforms, textures, pass,
            state, raster, ignore, commands, error);
        if (packet)
            [pr_faces addObject:@[ packet ]];
        return packet;
    }
    /* Independent old transport: every primitive gets a real old slice
     * packet before any render encoder is opened. The new loop supplies only
     * the original primitive/face order to the legacy whole-packet emitter. */
    NSMutableArray *packets = [NSMutableArray new];
    NSUInteger width = geometry.verticesPerPrimitive;
    for (NSUInteger i = 0; i < geometry.primitiveCount; i++) {
        NV2AMetalPixelDraw *packet = pr_prepare_one(
            object, selector, geometry, i * width * sizeof(NV2AMetalVertex),
            width, uniforms, textures, pass, state, raster, ignore, commands,
            error);
        if (!packet)
            return nil;
        [packets addObject:packet];
    }
    pr_packets[[NSValue valueWithPointer:(__bridge const void *)packets[0]]] =
        packets;
    [pr_faces addObject:packets];
    return packets[0];
}
static BOOL (*pr_whole)(id, SEL, id, NV2AMetalCommands *, NSError **);
static BOOL (*pr_range)(id, SEL, id, NV2AMetalCommands *, NSUInteger,
                        NSUInteger, NSError **);
static BOOL pr_range_spy(id object, SEL selector, id encoder,
                         NV2AMetalCommands *commands, NSUInteger first,
                         NSUInteger count, NSError **error)
{
    pr_emit_calls++;
    pr_nonzero_emits += first != 0;
    NSUInteger face = (pr_emit_calls - 1) % 2;
    NSUInteger primitive = (pr_emit_calls - 1) / 2;
    assert(pr_faces.count == 2 && object == pr_faces[face][0] &&
           count == pr_widths[face]);
    if (!pr_legacy)
        assert(first == primitive * pr_widths[face]);
    if (!pr_legacy && !pr_checked) {
        pr_checked = YES;
        PreparedRangeEncoderProbe *probe = [PreparedRangeEncoderProbe alloc];
        probe.target = encoder;
        NSError *failure = nil;
        NSUInteger capacity = [(NV2AMetalPixelDraw *)object vertexCount];
        assert(!pr_range(object, selector, probe, commands, capacity + 1, 0,
                         &failure) &&
               failure && !probe.mutations);
        failure = nil;
        assert(
            !pr_range(object, selector, probe, commands, 1, count, &failure) &&
            failure && !probe.mutations);
        failure = nil;
        assert(!pr_range(object, selector, probe, pr_foreign, 0, count,
                         &failure) &&
               failure && !probe.mutations);
        require(
            pr_range(object, selector, probe, commands, capacity, 0, &failure),
            failure);
        assert(!probe.mutations);
    }
    BOOL ok;
    if (pr_legacy) {
        /* The reference selects its primitive from its own alternating
         * emission ordinal, never from the candidate's generated first ID. */
        NSArray *packets = pr_faces[face];
        assert(packets ==
                   pr_packets[[NSValue
                       valueWithPointer:(__bridge const void *)object]] &&
               primitive < packets.count);
        if (pr_grouped) {
            ok = YES;
            if (pr_emit_calls == pr_expected_emits)
                for (NSArray *face in pr_faces)
                    for (NV2AMetalPixelDraw *packet in face)
                        ok &= pr_whole(
                            packet,
                            @selector(encodeWithRenderEncoder:commands:error:),
                            encoder, commands, error);
        } else
            ok = pr_whole(packets[primitive],
                          @selector(encodeWithRenderEncoder:commands:error:),
                          encoder, commands, error);
    } else
        ok = pr_range(object, selector, encoder, commands, first, count, error);
    if (ok && pr_emit_calls == pr_fail_emit) {
        pr_injected++;
        if (error)
            *error = [NSError errorWithDomain:@"test.prepared-last-emit"
                                         code:2
                                     userInfo:nil];
        return NO;
    }
    return ok;
}

static unsigned pr_vertices(unsigned topology, unsigned primitives)
{
    return topology == 0 ? primitives * 3 :
           topology == 3 ? primitives * 4 :
           topology == 4 ? (primitives + 1) * 2 :
                           primitives + 2;
}
static void pr_scene(unsigned topology, unsigned front, unsigned back,
                     unsigned program, BOOL indexed, unsigned primitives)
{
    pm_scene(topology, front, back, program, indexed, 0, 0);
    PGRAPHState *pg = &state->pgraph;
    unsigned count = pr_vertices(topology, primitives);
    dma[2].limit = 32767;
    pg->vertex_attributes[3].offset = 8192;
    pg->vertex_attributes[7].offset = 16384;
    pg->draw_arrays_start[0] = indexed ? 0 : 5;
    pg->draw_arrays_count[0] = count;
    pg->inline_elements_length = indexed ? count : 0;
    static const uint32_t triangle[] = { 0, 1, 2, 0, 2, 1 };
    static const uint32_t quad[] = { 0, 1, 3, 2, 0, 2, 3, 1 };
    static const uint32_t strip[] = { 0, 1, 2, 3, 4, 5, 6, 7 };
    const uint32_t *map = topology == 0 ? triangle :
                          topology == 3 ? quad :
                                          strip;
    unsigned period = topology == 0 ? 6 : 8;
    const float positions[8][4] = {
        { .5f, .5f, 30000, 1 },  { 6.5f, .5f, 31000, 1 },
        { .5f, 6.5f, 32000, 1 }, { 6.5f, 6.5f, 31500, 1 },
        { .5f, .5f, 30500, 1 },  { 6.5f, .5f, 31200, 1 },
        { .5f, 6.5f, 32500, 1 }, { 6.5f, 6.5f, 31700, 1 }
    };
    cpu_write(16384, 24576);
    for (unsigned v = 0; v < (indexed ? 8 : count + 5); v++) {
        unsigned physical = indexed ? v : map[(v < 5 ? 0 : v - 5) % period];
        memcpy(state->vram_ptr + 16384 + v * 16, positions[physical], 16);
        const float colors[2][4] = {
            { (physical + 1) / 9.f, .25f, (8 - physical) / 9.f, .5f },
            { .125f, (physical + 1) / 9.f, (8 - physical) / 10.f, .75f }
        };
        memcpy(state->vram_ptr + 24576 + v * 16, colors[0], 16);
        memcpy(state->vram_ptr + 32768 + v * 16, colors[1], 16);
    }
    for (unsigned i = 0; indexed && i < count; i++)
        pg->inline_elements[i] = map[i % period];
}
static void pr_reset_attempt(void)
{
    pr_prepare_calls = pr_packet_inits = pr_emit_calls = 0;
    pr_indexed_results = pr_nonzero_emits = 0;
    pr_checked = NO;
    pr_packets = [NSMutableDictionary new];
    pr_faces = [NSMutableArray new];
}
static NSData *pr_result(uint32_t query)
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
    [data appendBytes:&query length:sizeof(query)];
    return data;
}
static NSData *pr_run(unsigned topology, unsigned front, unsigned back,
                      unsigned program, BOOL indexed, unsigned primitives,
                      unsigned boundary, unsigned failure, BOOL legacy,
                      NSData **pending, NSData **vertex, NSData **begin,
                      NSData **failed)
{
    pr_scene(topology, front, back, program, indexed, primitives);
    pr_expect_indexed = indexed && program != 2;
    pr_legacy = legacy;
    pr_expected_emits = 2 * primitives;
    pr_fail_prepare = pr_fail_emit = 0;
    pr_reset_attempt();
    PGRAPHState *pg = &state->pgraph;
    unsigned count = pr_vertices(topology, primitives);
    NSError *error = nil;
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
        if (legacy) {
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
        unsigned previous = pr_injected;
        pr_fail_prepare = failure == 1 ? (legacy ? 2 * primitives : 2) : 0;
        pr_fail_emit = failure == 2 ? 2 * primitives : 0;
        assert(![draw endWithError:&error] && error &&
               pr_injected == previous + 1 && !pg->draw_time);
        assert(pr_prepare_calls == (legacy ? 2 * primitives : 2) &&
               pr_packet_inits == pr_prepare_calls &&
               pr_emit_calls == (failure == 1 ? 0 : 2 * primitives));
        error = nil;
        NSData *p = [draw pendingSnapshotWithError:&error];
        require(p != nil, error);
        if (legacy)
            *failed = p;
        else
            assert([*failed isEqualToData:p]);
        pr_fail_prepare = pr_fail_emit = 0;
        pr_reset_attempt();
    }
    require(boundary || failure ? [draw endWithError:&error] :
                                  [draw drawWithError:&error],
            error);
    assert(pg->draw_time == 1 &&
           pr_prepare_calls == (legacy ? 2 * primitives : 2) &&
           pr_packet_inits == pr_prepare_calls &&
           pr_emit_calls == 2 * primitives && (legacy || pr_checked));
    assert(pr_nonzero_emits && (!pr_expect_indexed || pr_indexed_results == 2));
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    if (program == 2)
        expect_context(191, 15, count, YES);
    return pr_result(query);
}

static void prepared_ranges_pgraph_tests(void)
{
    NSError *error = nil;
    pr_foreign =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(pr_foreign && [pr_foreign beginWithError:&error], error);
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            @selector(
                prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                rasterClass:ignorePolygonCulling:commands:error:)),
        class_getInstanceMethod(NV2AMetalPixelDraw.class,
                                sel_registerName("initForCommands:")),
        class_getInstanceMethod(NV2AMetalPixelDraw.class,
                                @selector(encodeWithRenderEncoder:commands:
                                          firstVertex:vertexCount:error:)),
        class_getInstanceMethod(
            NV2AMetalGeometry.class,
            @selector(encodeNativeRasterSlice:primitive:config:smooth:
                      firstProvoking:zPerspective:commands:error:))
    };
    IMP replacements[] = { (IMP)pr_prepare_spy, (IMP)pr_init_spy,
                           (IMP)pr_range_spy, (IMP)pr_geometry_spy };
    IMP originals[4];
    for (unsigned i = 0; i < 4; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    pr_prepare = (void *)originals[0];
    pr_init = (void *)originals[1];
    pr_range = (void *)originals[2];
    pr_geometry = (void *)originals[3];
    pr_whole = (void *)method_getImplementation(class_getInstanceMethod(
        NV2AMetalPixelDraw.class,
        @selector(encodeWithRenderEncoder:commands:error:)));
    unsigned pairs = 0, orderControls = 0;
    uint64_t visible[3][2] = { 0 }, colors[3][2] = { 0 }, zeta[3][2] = { 0 };
    @try {
        for (unsigned test = 0; test < 22; test++) {
            unsigned program, topology, front, back, primitives = 64;
            BOOL indexed;
            unsigned boundary = 0, failure = 0;
            if (test < 12) {
                program = test / 4;
                topology = (test / 2) % 2 ? 3 : 0;
                indexed = test & 1;
                front = program;
                back = (program + 1) % 3;
                boundary = indexed;
            } else if (test < 16) {
                program = 1;
                topology = (unsigned[]){ 1, 2, 4, 0 }[test - 12];
                front = 2;
                back = 0;
                indexed = YES;
                primitives = test == 15 ? 2 : 64;
                boundary = test & 1;
            } else if (test < 20) {
                program = test & 1 ? 2 : 1;
                topology = test & 1 ? 3 : 0;
                front = 0;
                back = 1;
                indexed = YES;
                boundary = 1;
                failure = test < 18 ? 1 : 2;
            } else {
                program = 1;
                topology = test == 20 ? 0 : 3;
                front = 0;
                back = 1;
                indexed = YES;
                primitives = 4;
            }
            NSData *pending = nil, *vertex = nil, *begin = nil, *failed = nil;
            pr_grouped = NO;
            NSData *reference = pr_run(topology, front, back, program, indexed,
                                       primitives, boundary, failure, YES,
                                       &pending, &vertex, &begin, &failed);
            NSData *actual = pr_run(topology, front, back, program, indexed,
                                    primitives, boundary, failure, NO, &pending,
                                    &vertex, &begin, &failed);
            if (![reference isEqualToData:actual]) {
                fprintf(stderr,
                        "Prepared ranges PGRAPH mismatch test%u "
                        "topology%u program%u indexed%d boundary%u failure%u\n",
                        test, topology, program, indexed, boundary, failure);
                abort();
            }
            const uint8_t *bytes = actual.bytes;
            uint32_t query;
            memcpy(&query, bytes + actual.length - sizeof(query),
                   sizeof(query));
            unsigned quad = topology >= 3;
            visible[program][quad] += query;
            const uint32_t red = UINT32_C(0xffff0000);
            const uint32_t initialZeta = UINT32_C(0xffffff11);
            for (unsigned i = 0; i < 256; i++) {
                colors[program][quad] +=
                    bytes[i] != ((const uint8_t *)&red)[i % 4];
                zeta[program][quad] +=
                    bytes[256 + i] != ((const uint8_t *)&initialZeta)[i % 4];
            }
            if (test >= 20) {
                pr_grouped = YES;
                NSData *grouped =
                    pr_run(topology, front, back, program, indexed, primitives,
                           0, 0, YES, &pending, &vertex, &begin, &failed);
                assert(memcmp(actual.bytes, grouped.bytes, 256));
                orderControls++;
                pr_grouped = NO;
            }
            pairs++;
        }
    } @finally {
        for (unsigned i = 0; i < 4; i++)
            method_setImplementation(methods[i], originals[i]);
        [pr_foreign cancel];
        pr_foreign = nil;
        pr_packets = nil;
        pr_faces = nil;
        pr_count_init = pr_grouped = NO;
    }
    for (unsigned p = 0; p < 3; p++)
        for (unsigned q = 0; q < 2; q++)
            assert(visible[p][q] && colors[p][q] && zeta[p][q]);
    assert(pairs == 22 && orderControls == 2);
    printf("Prepared raster ranges PGRAPH: %u exact Color/DepthStencil/Current/"
           "constants/query pairs PASS; 2 host preparations/packets versus "
           "2N real legacy per-primitive preparations, large mixed Triangle/"
           "Quad and mapped modes, prefixes/Restore, last prepare/emit retry, "
           "range/owner/zero rejection without encoder changes, 2 visible "
           "Blend/Stencil order controls; each Fixed/readonly/writer visible\n",
           pairs);
    groups += pairs;
}
#endif
