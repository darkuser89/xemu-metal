/* Bound Fetch writer admission versus the serial PGRAPH/GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BOUND_WRITER_PGRAPH_H
#define TEST_METAL_BOUND_WRITER_PGRAPH_H
static BOOL bw_reference, bw_expected, bw_previous, bw_pending;
static BOOL bw_float_case, bw_float_fault, bw_range_expected, bw_float_bound;
static __unsafe_unretained id bw_proof_fetch;
static unsigned bw_binding, bw_parallel, bw_serial, bw_chained, bw_count;
static NSUInteger bw_width;
static BOOL (*bw_proof)(id, SEL, unsigned, const float *,
                        const NV2AMetalFetchUniforms *);
static BOOL bw_proof_spy(id object, SEL selector, unsigned access,
                         const float *constants,
                         const NV2AMetalFetchUniforms *uniforms)
{
    return !bw_reference &&
           bw_proof(object, selector, access, constants, uniforms);
}
static BOOL (*bw_summary_proof)(id, SEL, unsigned, const float *,
                                const NV2AMetalFetchUniforms *, NSData *,
                                uint64_t);
static BOOL bw_summary_proof_spy(id object, SEL selector, unsigned access,
                                 const float *constants,
                                 const NV2AMetalFetchUniforms *uniforms,
                                 NSData *summary, uint64_t lanes)
{
    return !bw_reference &&
           bw_summary_proof(object, selector, access, constants, uniforms,
                            summary, lanes);
}
static BOOL (*bw_summary)(id, SEL, NSData **, uint64_t *, id, NSUInteger,
                          NSUInteger, id);
static BOOL bw_summary_spy(id object, SEL selector, NSData **summary,
                           uint64_t *lanes, id attributes, NSUInteger first,
                           NSUInteger count, id commands)
{
    BOOL bound = bw_summary(object, selector, summary, lanes, attributes, first,
                            count, commands);
    if (bound && object == bw_proof_fetch && summary && lanes &&
        (*lanes & (UINT64_C(1) << 4)) && (*summary).length == 1024) {
        const NV2AMetalFloatLaneSummary *value = (*summary).bytes;
        value += 4;
        bw_float_bound = value->flags == NV2AMetalFloatLaneSummaryFinite &&
                         value->minBits == 0 && value->maxBits == 0x3f800000 &&
                         value->minExponent == 0;
    }
    return bound;
}
static BOOL (*bw_fetch)(id, SEL, NV2AMetalFetchUniforms *, id, NSUInteger,
                        NSUInteger, id);
static BOOL bw_fetch_spy(id object, SEL selector,
                         NV2AMetalFetchUniforms *uniforms, id attributes,
                         NSUInteger first, NSUInteger count, id commands)
{
    return bw_fetch(object, selector, uniforms,
                    bw_binding == 1 ? surfaces.cache.vram : attributes,
                    bw_binding == 2 ? NSUIntegerMax : first, count,
                    bw_binding == 3 ? nil : commands);
}
static id (*bw_epoch)(id, SEL, id, id, NSUInteger, NSUInteger, id, id, id,
                      NSError **);
static id bw_epoch_spy(id object, SEL selector, id capture, id attributes,
                       NSUInteger first, NSUInteger count, id previous,
                       id fetch, id commands, NSError **error)
{
    assert(!bw_pending && count && count <= UINT_MAX);
    bw_count = (unsigned)count;
    bw_previous = previous != nil;
    bw_proof_fetch = fetch;
    bw_float_bound = NO;
    bw_range_expected = bw_expected || (bw_float_fault && !previous);
    return bw_epoch(object, selector, capture, attributes, first, count,
                    previous, fetch, commands, error);
}
static id (*bw_pipeline)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL, NSError **);
static id bw_pipeline_spy(id object, SEL selector, BOOL write, BOOL compact,
                          BOOL discard, BOOL chained, BOOL independent,
                          NSError **error)
{
    assert(write && compact && !discard && chained == bw_previous &&
           !bw_pending);
    BOOL expected = bw_range_expected && !bw_reference && !bw_binding;
    if (expected && bw_float_case)
        assert(bw_float_bound);
    if (independent != expected) {
        fprintf(stderr,
                "Bound writer admission: selected%d expected%d previous%d "
                "reference%d binding%u\n",
                independent, expected, bw_previous, bw_reference, bw_binding);
        abort();
    }
    id<MTLComputePipelineState> pipeline = bw_pipeline(
        object, selector, write, compact, discard, chained, independent, error);
    if (pipeline) {
        bw_width =
            independent ? MIN(bw_count, pipeline.threadExecutionWidth) : 1;
        bw_pending = YES;
        bw_parallel += independent;
        bw_serial += !independent;
        bw_chained += chained;
    }
    return pipeline;
}
static void (*bw_dispatch)(id, SEL, MTLSize, MTLSize);
static void bw_dispatch_spy(id object, SEL selector, MTLSize threads,
                            MTLSize group)
{
    if (bw_pending) {
        BOOL parallel = bw_range_expected && !bw_reference && !bw_binding;
        assert(threads.width == (parallel ? bw_count : 1) &&
               threads.height == 1 && threads.depth == 1 &&
               group.width == bw_width && group.height == 1 &&
               group.depth == 1);
        bw_pending = NO;
    }
    bw_dispatch(object, selector, threads, group);
}
static void bw_scene(unsigned format, BOOL full, BOOL indexed, BOOL ranges)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CSV0_D] =
        2u << 30 | (full ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0);
    pg->enable_vertex_program_write = true;
    mov(0, 0, 0, false);
    Token arl = token(13, 0, 0);
    arl.word[1] |= 1u << 9;
    source(&arl, 0, 2, 0, 0);
    destination(&arl, 0, 0, 0, 0, 0, 0);
    memcpy(pg->program_data[1], arl.word, sizeof(arl.word));
    unsigned base = full ? 32 : 110;
    Token color = token(1, 0, base);
    source(&color, 0, 3, 0, 0xe4);
    destination(&color, 0x103, 15, 0, 0, 0, 0);
    color.word[3] |= 2;
    memcpy(pg->program_data[2], color.word, sizeof(color.word));
    Token store = token(1, 0, 0);
    store.word[1] |= 5u << 9;
    source(&store, 0, 2, 0, 0xe4);
    destination(&store, 150, format & 1 ? 8 : 15, 0, 0, 0, 0);
    store.word[3] |= 1;
    memcpy(pg->program_data[3], store.word, sizeof(store.word));
    for (unsigned row = base - 2; row <= base + 1; row++) {
        const float rgba[] = { .125f * (row - base + 3), .75f,
                               .25f * (row - base + 3), 1 };
        memcpy(pg->vsh_constants[row], rgba, sizeof(rgba));
    }
    for (unsigned k = 0; k < 4; k++) {
        float initial = -9 + (int)k;
        memcpy(&pg->vsh_constants[150][k], &initial, 4);
    }
    const float position[6][4] = {
        { .5f, .5f, 32000, 1 },   { 6.5f, 1.5f, 32000, 1 },
        { 1.5f, 6.5f, 32000, 1 }, { .5f, .5f, 32000, 1 },
        { 6.5f, 1.5f, 32000, 1 }, { 1.5f, 6.5f, 32000, 1 }
    };
    cpu_write(16384, 768);
    memcpy(state->vram_ptr + 16384, position, sizeof(position));
    pg->vertex_attributes[5] =
        (VertexAttribute){ .offset = 512,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .count = 4,
                           .size = 4,
                           .stride = 16 };
    for (unsigned v = 0; v < 6; v++) {
        const float value[] = { v + .25f, v + .5f, v + .75f, 1 };
        memcpy(state->vram_ptr + 16896 + v * 16, value, sizeof(value));
    }
    VertexAttribute *attribute = &pg->vertex_attributes[1];
    attribute->offset = 256;
    attribute->count = 1;
    attribute->size = format == 0 ? 1 : format == 1 ? 2 : 4;
    attribute->stride = attribute->size;
    attribute->format =
        format == 0 ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL :
        format == 1 ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1 :
        format == 2 ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP :
                      NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    for (unsigned v = 0; v < 6; v++) {
        uint32_t bits;
        if (!format)
            bits = v & 1 ? 255 : 0;
        else if (format == 1)
            bits = v & 1 ? 0x7fff : 0x8000;
        else if (format == 2)
            bits = v & 1 ? 0x3ff : 0x400;
        else {
            float value = v & 1 ? 1 : 0;
            memcpy(&bits, &value, 4);
        }
        memcpy(state->vram_ptr + 16640 + v * attribute->size, &bits,
               attribute->size);
    }
    if (format == 3) {
        attribute->count = 0;
        attribute->inline_value[0] = .5f;
    }
    if (format == 4)
        attribute->stride = 0;
    pg->draw_arrays_length = ranges ? 2 : 1;
    pg->draw_arrays_count[0] = ranges ? 3 : 6;
    if (ranges) {
        pg->draw_arrays_start[1] = 3;
        pg->draw_arrays_count[1] = 3;
    }
    if (indexed) {
        const uint32_t indices[] = { 2, 0, 1, 2, 1, 0 };
        pg->draw_arrays_length = 0;
        pg->inline_elements_length = 6;
        memcpy(pg->inline_elements, indices, sizeof(indices));
    }
}
static void bw_compare_context(PGRAPHState *pg, uint8_t *frame,
                               uint32_t current[16][4],
                               uint32_t constants[192][4], bool dirty[192],
                               BOOL reference)
{
    read_vram(1024, 256);
    if (reference) {
        memcpy(frame, state->vram_ptr + 1024, 256);
        for (unsigned i = 0; i < 16; i++)
            memcpy(current[i], pg->vertex_attributes[i].inline_value, 16);
        memcpy(constants, pg->vsh_constants, 192 * 16);
        memcpy(dirty, pg->vsh_constants_dirty, 192 * sizeof(bool));
    } else {
        assert(!memcmp(frame, state->vram_ptr + 1024, 256));
        for (unsigned i = 0; i < 16; i++)
            assert(
                !memcmp(current[i], pg->vertex_attributes[i].inline_value, 16));
        assert(!memcmp(constants, pg->vsh_constants, 192 * 16));
        assert(!memcmp(dirty, pg->vsh_constants_dirty, 192 * sizeof(bool)));
    }
}
static void bound_writer_pgraph_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(probe != nil && [probe beginWithError:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [probe.commandBuffer computeCommandEncoder];
    Method dispatch = class_getInstanceMethod(
        object_getClass(encoder),
        @selector(dispatchThreads:threadsPerThreadgroup:));
    [encoder endEncoding];
    [probe cancel];
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(
                @"refineIndependentConstantWrites:constants:sourceUniforms:")),
        class_getInstanceMethod(
            NV2AMetalFetchResult.class,
            @selector(getReadonlyProofUniforms:attributeBuffer:first:count:
                      commands:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:attributeFetch:commands:error:)),
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:)),
        dispatch,
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(@"refineIndependentConstantWrites:constants:"
                                 @"sourceUniforms:floatSummaries:laneMask:")),
        class_getInstanceMethod(
            NV2AMetalFetchResult.class,
            @selector(getFloatProofSummaries:laneMask:attributeBuffer:first:
                      count:commands:))
    };
    IMP replacements[] = { (IMP)bw_proof_spy,    (IMP)bw_fetch_spy,
                           (IMP)bw_epoch_spy,    (IMP)bw_pipeline_spy,
                           (IMP)bw_dispatch_spy, (IMP)bw_summary_proof_spy,
                           (IMP)bw_summary_spy };
    IMP originals[7];
    for (unsigned i = 0; i < 7; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    bw_proof = (void *)originals[0];
    bw_fetch = (void *)originals[1];
    bw_epoch = (void *)originals[2];
    bw_pipeline = (void *)originals[3];
    bw_dispatch = (void *)originals[4];
    bw_summary_proof = (void *)originals[5];
    bw_summary = (void *)originals[6];
    bw_parallel = bw_serial = bw_chained = 0;
    unsigned pairs = 0;
    @try {
        for (unsigned format = 0; format < 6; format++)
            for (unsigned full = 0; full < 2; full++)
                for (unsigned indexed = 0; indexed < 2; indexed++) {
                    uint8_t frame[256];
                    uint32_t current[16][4], constants[192][4];
                    bool dirty[192];
                    for (unsigned candidate = 0; candidate < 2; candidate++) {
                        bw_scene(format, full, indexed, NO);
                        bw_reference = !candidate;
                        /* The formerly unknown strided Float case is now a
                         * freshly bound [0,1] domain. Stride-zero/raw unknown
                         * remains conservative, and reference stays serial. */
                        bw_expected = format < 4 || format == 5;
                        bw_float_case = format == 5;
                        bw_float_fault = NO;
                        bw_binding = 0;
                        unsigned parallel = bw_parallel, serial = bw_serial;
                        render();
                        bw_float_case = NO;
                        assert(!bw_pending &&
                               bw_parallel - parallel ==
                                   (candidate && bw_expected) &&
                               bw_serial - serial ==
                                   !(candidate && bw_expected));
                        PGRAPHState *pg = &state->pgraph;
                        assert(pg->vsh_constants_dirty[150]);
                        for (unsigned k = 0; k < 4; k++) {
                            float expected =
                                ((format & 1 ? 8 : 15) & (8u >> k)) ?
                                    pg->vertex_attributes[5].inline_value[k] :
                                    -9 + (int)k;
                            assert(!memcmp(pg->vsh_constants[150] + k,
                                           &expected, 4));
                        }
                        bw_compare_context(pg, frame, current, constants, dirty,
                                           !candidate);
                    }
                    pairs++;
                }
        for (unsigned full = 0; full < 2; full++)
            for (unsigned format = 0; format < 2; format++) {
                uint8_t frame[256];
                uint32_t current[16][4], constants[192][4];
                bool dirty[192];
                for (unsigned candidate = 0; candidate < 2; candidate++) {
                    bw_scene(format, full, NO, YES);
                    bw_reference = !candidate;
                    bw_expected = YES;
                    bw_binding = 0;
                    unsigned parallel = bw_parallel, serial = bw_serial,
                             chained = bw_chained;
                    render();
                    assert(bw_chained - chained == 1 &&
                           bw_parallel - parallel == (candidate ? 2u : 0u) &&
                           bw_serial - serial == (candidate ? 0u : 2u));
                    bw_compare_context(&state->pgraph, frame, current,
                                       constants, dirty, !candidate);
                }
                pairs++;
            }
        /* A normalized domain can bound the address while still reading a
         * component written by another vertex. That context feedback stays
         * serial. */
        for (unsigned full = 0; full < 2; full++) {
            uint8_t frame[256];
            uint32_t current[16][4], constants[192][4];
            bool dirty[192];
            for (unsigned candidate = 0; candidate < 2; candidate++) {
                bw_scene(0, full, NO, NO);
                unsigned row = full ? 32 : 110;
                Token store = token(1, 0, 0);
                store.word[1] |= 5u << 9;
                source(&store, 0, 2, 0, 0xe4);
                destination(&store, row, 15, 0, 0, 0, 0);
                store.word[3] |= 1;
                memcpy(state->pgraph.program_data[3], store.word,
                       sizeof(store.word));
                bw_reference = !candidate;
                bw_expected = NO;
                bw_binding = 0;
                unsigned parallel = bw_parallel, serial = bw_serial;
                render();
                assert(bw_parallel == parallel && bw_serial - serial == 1 &&
                       state->pgraph.vsh_constants_dirty[row]);
                bw_compare_context(&state->pgraph, frame, current, constants,
                                   dirty, !candidate);
            }
            pairs++;
        }
        for (unsigned binding = 1; binding <= 3; binding++) {
            uint8_t frame[256];
            uint32_t current[16][4], constants[192][4];
            bool dirty[192];
            for (unsigned candidate = 0; candidate < 2; candidate++) {
                bw_scene(0, YES, YES, NO);
                bw_reference = !candidate;
                bw_expected = YES;
                bw_binding = candidate ? binding : 0;
                unsigned parallel = bw_parallel, serial = bw_serial;
                render();
                assert(bw_parallel == parallel && bw_serial - serial == 1);
                bw_compare_context(&state->pgraph, frame, current, constants,
                                   dirty, !candidate);
            }
            pairs++;
        }
        for (unsigned fault = 0; fault < 2; fault++) {
            uint8_t frame[256];
            uint32_t current[16][4], constants[192][4];
            bool dirty[192];
            NSData *pending = nil, *vertex = nil, *begin = nil;
            for (unsigned candidate = 0; candidate < 2; candidate++) {
                bw_scene(fault ? 5 : 0, YES, NO, fault);
                bw_reference = !candidate;
                bw_expected = !fault;
                bw_float_case = bw_float_fault = fault;
                bw_binding = 0;
                PGRAPHState *pg = &state->pgraph;
                if (fault) {
                    float value = NAN;
                    cpu_write(16652, 4);
                    memcpy(state->vram_ptr + 16652, &value, 4);
                }
                qemu_mutex_lock(&pg->lock);
                require([draw beginWithError:&error], error);
                if (fault) {
                    assert(![draw prepareVertexStateChangeWithError:&error] &&
                           error);
                    error = nil;
                } else {
                    pg->draw_arrays_count[0] = 3;
                    require([draw prepareVertexStateChangeWithError:&error],
                            error);
                }
                NSData *p = [draw pendingSnapshotWithError:&error];
                NSData *v = draw.vertexSnapshot,
                       *b = [draw beginSnapshotWithError:&error];
                require(p && v && b, error);
                if (!candidate) {
                    pending = p;
                    vertex = v;
                    begin = b;
                } else
                    assert([pending isEqualToData:p] &&
                           [vertex isEqualToData:v] && [begin isEqualToData:b]);
                require([draw discardForRestoreWithError:&error], error);
                require([draw restoreVertexSnapshot:v error:&error] &&
                            [draw restoreBeginSnapshot:b error:&error] &&
                            [draw restorePendingSnapshot:p error:&error] &&
                            [draw beginWithError:&error],
                        error);
                if (fault) {
                    float value = 1;
                    cpu_write(16652, 4);
                    memcpy(state->vram_ptr + 16652, &value, 4);
                    /* After repair the remaining Float range is finite;
                     * the initial NaN range above was still serial/faulting. */
                    bw_expected = YES;
                    bw_float_fault = NO;
                } else
                    pg->draw_arrays_count[0] = 6;
                require([draw prepareVertexStateChangeWithError:&error] &&
                            [draw endWithError:&error],
                        error);
                qemu_mutex_unlock(&pg->lock);
                bw_compare_context(pg, frame, current, constants, dirty,
                                   !candidate);
                bw_float_case = bw_float_fault = NO;
            }
            pairs++;
        }
    } @finally {
        for (unsigned i = 0; i < 7; i++)
            method_setImplementation(methods[i], originals[i]);
        bw_reference = bw_pending = NO;
        bw_float_case = bw_float_fault = bw_float_bound = NO;
        bw_proof_fetch = nil;
        bw_binding = 0;
    }
    assert(pairs == 35 && bw_parallel && bw_serial && bw_chained);
    printf("Bound writer PGRAPH: %u exact framebuffer/Current/constants/dirty "
           "pairs, %u parallel/%u serial dispatches; "
           "typed/inline/unknown Float domains, USER/FULL, arrays/index, three "
           "Fetch binding rejections, "
           "context-alias/unknown serial, disjoint proven predecessors, NaN "
           "fault/prefix retry and "
           "Begin/Pending restore PASS\n",
           pairs, bw_parallel, bw_serial);
    groups += pairs;
}
#endif
