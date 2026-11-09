/* End-to-end readonly indexed dedupe versus the original linear XF path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEXED_READONLY_H
#define TEST_METAL_INDEXED_READONLY_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"

static void indexed_compare_pending(NSData *linear, NSData *candidate,
                                    BOOL compact)
{
    assert(
        pgraph_metal4_validate_pending_capture(linear.bytes, linear.length) &&
        pgraph_metal4_validate_pending_capture(candidate.bytes,
                                               candidate.length));
    assert(!memcmp(linear.bytes, candidate.bytes, 12));
    NSError *error = nil;
    NV2AMetalPendingArchive *a = [[NV2AMetalPendingArchive alloc]
        initWithData:[linear
                         subdataWithRange:NSMakeRange(12, linear.length - 12)]
               limit:524287
               error:&error];
    NV2AMetalPendingArchive *b = [[NV2AMetalPendingArchive alloc]
        initWithData:[candidate subdataWithRange:NSMakeRange(
                                                     12, candidate.length - 12)]
               limit:524287
               error:&error];
    require(a && b, error);
    assert(a.inputs.count == b.inputs.count &&
           [a.vertices isEqualToArray:b.vertices]);
    NSUInteger physicalA = 0, physicalB = 0;
    for (NSUInteger i = 0; i < a.inputs.count; i++) {
        assert(a.inputs[i].kind == b.inputs[i].kind &&
               a.inputs[i].first == b.inputs[i].first &&
               a.inputs[i].count == b.inputs[i].count &&
               [a.inputs[i].indices isEqualToData:b.inputs[i].indices]);
        physicalA += a.physicalVertices[i].length;
        physicalB += b.physicalVertices[i].length;
        assert(compact ? b.remaps[i].length != 0 : b.remaps[i].length == 0);
    }
    assert(compact ? physicalB < physicalA : [linear isEqualToData:candidate]);
}

static BOOL indexed_reference, indexed_fail_emit;
static NSUInteger indexed_xf_records, indexed_owners, indexed_fetch_maps;
static unsigned indexed_independent_calls, indexed_current_calls;
static id (*indexed_fetch_independent)(id, SEL, NSArray *, id, BOOL, uint64_t,
                                       NSError **);
static id (*indexed_fetch_current)(id, SEL, NSArray *, id, BOOL, uint64_t,
                                   NSError **);
static id indexed_observe_fetch(NSArray<NV2AMetalPGRAPHFetchBatch *> *batches)
{
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        if (batch.remap) {
            assert(!indexed_reference &&
                   batch.physicalVertexCount <
                       batch.inputVertexCount - batch.firstDecodedVertex);
            indexed_fetch_maps++;
        }
    }
    return batches;
}
static id indexed_independent(id object, SEL selector, NSArray *prefixes,
                              id input, BOOL readonly, uint64_t proofLanes,
                              NSError **error)
{
    indexed_independent_calls++;
    return indexed_observe_fetch(indexed_fetch_independent(
        object, selector, prefixes, input, readonly && !indexed_reference,
        proofLanes, error));
}
static id indexed_current(id object, SEL selector, NSArray *prefixes, id input,
                          BOOL readonly, uint64_t proofLanes, NSError **error)
{
    indexed_current_calls++;
    return indexed_observe_fetch(indexed_fetch_current(
        object, selector, prefixes, input, readonly && !indexed_reference,
        proofLanes, error));
}
static id (*indexed_epoch_encode)(id, SEL, id, id, NSUInteger, NSUInteger, id,
                                  id, NSError **);
static id indexed_encode(id object, SEL selector, id state, id attributes,
                         NSUInteger first, NSUInteger count, id fetch,
                         id commands, NSError **error)
{
    indexed_xf_records += count;
    return indexed_epoch_encode(object, selector, state, attributes, first,
                                count, fetch, commands, error);
}
static id (*indexed_epoch_execute)(id, SEL, id, id, NSUInteger, NSUInteger,
                                   NSError **);
static id indexed_execute(id object, SEL selector, id state, id attributes,
                          NSUInteger first, NSUInteger count, NSError **error)
{
    indexed_xf_records += count;
    return indexed_epoch_execute(object, selector, state, attributes, first,
                                 count, error);
}
static id (*indexed_epoch_serial)(id, SEL, id, id, NSUInteger, NSUInteger, id,
                                  id, id, NSError **);
static id indexed_serial(id object, SEL selector, id state, id attributes,
                         NSUInteger first, NSUInteger count, id previous,
                         id fetch, id commands, NSError **error)
{
    indexed_xf_records += count;
    return indexed_epoch_serial(object, selector, state, attributes, first,
                                count, previous, fetch, commands, error);
}
static BOOL (*indexed_commit_suffix)(id, SEL, id, id, NSError **);
static BOOL indexed_suffix(id object, SEL selector, NV2AMetalPendingSpan *span,
                           id progress, NSError **error)
{
    if ([span.resource isKindOfClass:NV2AMetalIndexedVertices.class]) {
        NV2AMetalIndexedVertices *owner = span.resource;
        assert(!indexed_reference && span.first == 0 &&
               span.count == owner.vertexCount &&
               owner.physicalVertexCount < owner.vertexCount);
        indexed_owners++;
    }
    return indexed_commit_suffix(object, selector, span, progress, error);
}
static BOOL (*indexed_pixel_emit)(id, SEL, id, id, NSError **);
static BOOL indexed_emit(id object, SEL selector, id encoder, id commands,
                         NSError **error)
{
    BOOL ok = indexed_pixel_emit(object, selector, encoder, commands, error);
    if (ok && indexed_fail_emit) {
        indexed_fail_emit = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.indexed-late-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static void indexed_scene(unsigned primitive, unsigned mode)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    if (mode == 3) {
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
        pg->enable_vertex_program_write = true;
        feedback_program(191, 15);
    } else if (mode) {
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
        pg->enable_vertex_program_write = mode == 2;
        mov(0, 0, 0, false);
        mov(1, 3, 3, true);
    }
    pg->primitive_mode = primitive;
    pg->draw_arrays_length = 0;
    pg->vertex_attributes[3] =
        (VertexAttribute){ .offset = 256,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    const float position[4][4] = { { .5f, .5f, 31000, 1 },
                                   { 6.5f, 1.5f, 32000, 1 },
                                   { 1.5f, 6.5f, 33000, 1 },
                                   { 6.5f, 6.5f, 34000, 1 } };
    const float color[4][4] = { { 1, .125f, .25f, 1 },
                                { .25f, 1, .125f, 1 },
                                { .125f, .25f, 1, 1 },
                                { 1, .75f, .25f, 1 } };
    const uint32_t indices[12] = { 2, 0, 1, 2, 1, 0, 3, 1, 2, 3, 0, 2 };
    cpu_write(16384, sizeof(position));
    memcpy(state->vram_ptr + 16384, position, sizeof(position));
    cpu_write(16640, sizeof(color));
    memcpy(state->vram_ptr + 16640, color, sizeof(color));
    memcpy(pg->inline_elements, indices, sizeof(indices));
    pg->inline_elements_length = 12;
    pg->regs_[NV_PGRAPH_POINTSIZE] = 16;
}
static void indexed_gpu_retry_tests(void)
{
    for (unsigned writeEnabled = 0; writeEnabled < 2; writeEnabled++) {
        uint8_t framebuffer[256];
        uint32_t current[16][4], constants[192][4];
        NSData *referencePending = nil;
        for (unsigned compact = 0; compact < 2; compact++) {
            indexed_scene(PRIM_TYPE_TRIANGLE_STRIP, writeEnabled ? 2 : 1);
            indexed_reference = !compact;
            PGRAPHState *pg = &state->pgraph;
            mov(1, 3, 3, false);
            Token arl = token(13, 0, 0);
            arl.word[1] |= 1u << 9;
            source(&arl, 0, 2, 0, 0);
            destination(&arl, 0, 0, 0, 0, 0, 0);
            arl.word[3] |= 1;
            memcpy(pg->program_data[2], arl.word, sizeof(arl.word));
            pg->vertex_attributes[1] = (VertexAttribute){
                .offset = 384,
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                .size = 4,
                .count = 1,
                .stride = 4
            };
            float dynamic[4] = { 0, 0, 0, NAN };
            cpu_write(16768, sizeof(dynamic));
            memcpy(state->vram_ptr + 16768, dynamic, sizeof(dynamic));
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            pg->inline_elements_length = 6;
            require([draw beginWithError:&error], error);
            require([draw prepareVertexStateChangeWithError:&error], error);
            NSData *prefix = [draw pendingSnapshotWithError:&error];
            require(prefix != nil, error);
            if (!compact)
                referencePending = prefix;
            else
                indexed_compare_pending(referencePending, prefix, YES);
            pg->inline_elements_length = 12;
            assert(![draw prepareVertexStateChangeWithError:&error] && error);
            error = nil;
            NSData *failed = [draw pendingSnapshotWithError:&error];
            require(failed != nil, error);
            assert([failed isEqualToData:prefix] && !pg->draw_time);
            dynamic[3] = 0;
            cpu_write(16768, sizeof(dynamic));
            memcpy(state->vram_ptr + 16768, dynamic, sizeof(dynamic));
            require([draw prepareVertexStateChangeWithError:&error], error);
            require([draw endWithError:&error], error);
            qemu_mutex_unlock(&pg->lock);
            read_vram(1024, 256);
            if (!compact) {
                memcpy(framebuffer, state->vram_ptr + 1024,
                       sizeof(framebuffer));
                for (unsigned i = 0; i < 16; i++)
                    memcpy(current[i], pg->vertex_attributes[i].inline_value,
                           16);
                memcpy(constants, pg->vsh_constants, sizeof(constants));
            } else {
                assert(!memcmp(framebuffer, state->vram_ptr + 1024,
                               sizeof(framebuffer)));
                for (unsigned i = 0; i < 16; i++)
                    assert(!memcmp(current[i],
                                   pg->vertex_attributes[i].inline_value, 16));
                assert(
                    !memcmp(constants, pg->vsh_constants, sizeof(constants)));
            }
        }
    }
    groups += 2;
    puts("PGRAPH indexed GPU retry: readonly/write-enabled ARL NaN faults "
         "preserve accepted prefix, corrected suffix matches linear "
         "raster/Current/context PASS");
}
static void indexed_readonly_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeIndependentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(executeRasterState:attributeBuffer:first:count:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:attributeFetch:commands:error:)),
        class_getInstanceMethod(NV2AMetalPendingJournal.class,
                                @selector(commitNextSuffix:progress:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    IMP replacements[] = { (IMP)indexed_independent, (IMP)indexed_current,
                           (IMP)indexed_encode,      (IMP)indexed_execute,
                           (IMP)indexed_serial,      (IMP)indexed_suffix,
                           (IMP)indexed_emit };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    indexed_fetch_independent = (void *)originals[0];
    indexed_fetch_current = (void *)originals[1];
    indexed_epoch_encode = (void *)originals[2];
    indexed_epoch_execute = (void *)originals[3];
    indexed_epoch_serial = (void *)originals[4];
    indexed_commit_suffix = (void *)originals[5];
    indexed_pixel_emit = (void *)originals[6];
    const unsigned primitives[] = {
        PRIM_TYPE_POINTS,    PRIM_TYPE_LINES,          PRIM_TYPE_LINE_STRIP,
        PRIM_TYPE_TRIANGLES, PRIM_TYPE_TRIANGLE_STRIP, PRIM_TYPE_TRIANGLE_FAN,
        PRIM_TYPE_QUADS
    };
    unsigned pairs = 0;
    NSUInteger linearRecords = 0, compactRecords = 0;
    @try {
        for (unsigned mode = 0; mode < 4; mode++) {
            for (unsigned topology = 0; topology < ARRAY_SIZE(primitives);
                 topology++) {
                for (unsigned boundary = 0; boundary < 3; boundary++) {
                    uint8_t framebuffer[256], zeta[256];
                    uint32_t current[16][4], constants[192][4];
                    NSData *pending = nil, *vertex = nil, *begin = nil;
                    for (unsigned compact = 0; compact < 2; compact++) {
                        indexed_scene(primitives[topology], mode);
                        PGRAPHState *pg = &state->pgraph;
                        indexed_reference = !compact;
                        indexed_fail_emit = NO;
                        indexed_xf_records = indexed_owners =
                            indexed_fetch_maps = 0;
                        NSError *error = nil;
                        qemu_mutex_lock(&pg->lock);
                        if (boundary) {
                            pg->inline_elements_length = 6;
                            require([draw beginWithError:&error], error);
                            require(
                                [draw prepareVertexStateChangeWithError:&error],
                                error);
                            NSData *p = [draw pendingSnapshotWithError:&error];
                            NSData *v = draw.vertexSnapshot;
                            NSData *b = [draw beginSnapshotWithError:&error];
                            require(p && v && b, error);
                            if (!compact) {
                                pending = p;
                                vertex = v;
                                begin = b;
                            } else {
                                indexed_compare_pending(pending, p, mode != 3);
                                assert([vertex isEqualToData:v]);
                                assert([begin isEqualToData:b]);
                            }
                            require([draw flushWithError:&error], error);
                            if (boundary == 2) {
                                require(
                                    [draw discardForRestoreWithError:&error],
                                    error);
                                require([draw restoreVertexSnapshot:v
                                                              error:&error],
                                        error);
                                require([draw restoreBeginSnapshot:b
                                                             error:&error],
                                        error);
                                require([draw restorePendingSnapshot:p
                                                               error:&error],
                                        error);
                                require([draw beginWithError:&error], error);
                                NSData *restored =
                                    [draw pendingSnapshotWithError:&error];
                                require(restored != nil, error);
                                assert([restored isEqualToData:p]);
                            }
                            pg->inline_elements_length = 12;
                            if (boundary == 2) {
                                uint32_t beforeCurrent[16][4];
                                for (unsigned i = 0; i < 16; i++)
                                    memcpy(
                                        beforeCurrent[i],
                                        pg->vertex_attributes[i].inline_value,
                                        16);
                                indexed_fail_emit = YES;
                                assert(![draw endWithError:&error] && error &&
                                       !indexed_fail_emit);
                                if (!mode)
                                    for (unsigned i = 0; i < 16; i++)
                                        assert(!memcmp(beforeCurrent[i],
                                                       pg->vertex_attributes[i]
                                                           .inline_value,
                                                       16));
                                NSUInteger beforeRetry = indexed_xf_records;
                                error = nil;
                                require([draw endWithError:&error], error);
                                NSUInteger replay =
                                    mode ? 0 : (!compact ? 6 : 4);
                                if (indexed_xf_records !=
                                    beforeRetry + replay) {
                                    fprintf(stderr,
                                            "Retry mode%u topology%u compact%u "
                                            "before%lu after%lu "
                                            "expectedReplay%lu\n",
                                            mode, topology, compact,
                                            (unsigned long)beforeRetry,
                                            (unsigned long)indexed_xf_records,
                                            (unsigned long)replay);
                                    abort();
                                }
                            } else
                                require([draw endWithError:&error], error);
                        } else
                            require([draw drawWithError:&error], error);
                        assert(pg->draw_time == 1);
                        if (mode == 3)
                            expect_context(191, 15, 12, YES);
                        NSUInteger expected = !compact || mode == 3 ? 12 :
                                              boundary              ? 7 :
                                                                      4;
                        if (boundary == 2 && !mode)
                            expected += !compact ? 6 : 4;
                        if (indexed_xf_records != expected) {
                            fprintf(stderr,
                                    "Indexed mode%u topology%u boundary%u "
                                    "compact%u XF%lu expected%lu\n",
                                    mode, topology, boundary, compact,
                                    (unsigned long)indexed_xf_records,
                                    (unsigned long)expected);
                            abort();
                        }
                        if (compact && mode != 3) {
                            assert(indexed_owners && indexed_fetch_maps);
                            compactRecords += indexed_xf_records;
                        } else if (!compact && mode != 3)
                            linearRecords += indexed_xf_records;
                        else
                            assert(!indexed_owners && !indexed_fetch_maps);
                        qemu_mutex_unlock(&pg->lock);
                        read_vram(1024, 256);
                        read_vram(4096, 256);
                        unsigned changed = 0;
                        for (unsigned pixel = 0; pixel < 64; pixel++)
                            changed +=
                                (uint32_t)ldl_le_p(state->vram_ptr + 1024 + pixel * 4) !=
                                UINT32_C(0xffff0000);
                        assert(changed);
                        if (!compact) {
                            memcpy(framebuffer, state->vram_ptr + 1024, 256);
                            memcpy(zeta, state->vram_ptr + 4096, 256);
                            for (unsigned i = 0; i < 16; i++)
                                memcpy(current[i],
                                       pg->vertex_attributes[i].inline_value,
                                       16);
                            memcpy(constants, pg->vsh_constants,
                                   sizeof(constants));
                        } else {
                            assert(!memcmp(framebuffer, state->vram_ptr + 1024,
                                           256));
                            assert(!memcmp(zeta, state->vram_ptr + 4096, 256));
                            for (unsigned i = 0; i < 16; i++)
                                assert(!memcmp(
                                    current[i],
                                    pg->vertex_attributes[i].inline_value, 16));
                            assert(!memcmp(constants, pg->vsh_constants,
                                           sizeof(constants)));
                        }
                    }
                    pairs++;
                }
            }
        }
        indexed_gpu_retry_tests();
    } @finally {
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
        indexed_reference = indexed_fail_emit = NO;
    }
    assert(pairs == 84 && compactRecords < linearRecords &&
           indexed_independent_calls && indexed_current_calls);
    printf("PGRAPH indexed readonly: %u framebuffer/Current/context pairs; "
           "%lu vs %lu readonly XF records, writers linear; stable owners, "
           "Begin suffix/frame/snapshot restore and late raster retry PASS\n",
           pairs, (unsigned long)compactRecords, (unsigned long)linearRecords);
    groups += pairs;
}
#endif
