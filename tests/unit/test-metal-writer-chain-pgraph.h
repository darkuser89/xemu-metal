/* Proven writer chains in the real PGRAPH multi-range path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_WRITER_CHAIN_PGRAPH_H
#define TEST_METAL_WRITER_CHAIN_PGRAPH_H
@interface NV2AMetalEpochEncoding (WriterChainTest)
@property(nonatomic, readonly) NV2AMetalWritableEncoding *programEncoding;
- (instancetype)initProgram:(NV2AMetalWritableEncoding *)program;
@end
static BOOL wc_reference, wc_expected, wc_pending, wc_previous, wc_tracking,
    wc_fail_emit;
static BOOL wc_repaired, wc_float_bound;
static __unsafe_unretained id wc_proof_fetch;
static unsigned wc_kind, wc_hop, wc_parallel, wc_serial, wc_chained, wc_waits,
    wc_pairs;
static unsigned wc_wait_totals[2], wc_parallel_totals[2], wc_serial_totals[2];
static NSUInteger wc_count, wc_width;
static NV2AMetalCommands *wc_producer;
static id<MTLSharedEvent> wc_gate;
static BOOL (*wc_static)(id, SEL, unsigned);
static BOOL (*wc_constant)(id, SEL, unsigned, const float *);
static BOOL (*wc_refine)(id, SEL, unsigned, const float *,
                         const NV2AMetalFetchUniforms *);
static BOOL (*wc_origin)(id, SEL, id, const float *, id);
static BOOL wc_static_spy(id o, SEL s, unsigned a)
{
    return !wc_reference && wc_static(o, s, a);
}
static BOOL wc_constant_spy(id o, SEL s, unsigned a, const float *c)
{
    return !wc_reference && wc_constant(o, s, a, c);
}
static BOOL wc_refine_spy(id o, SEL s, unsigned a, const float *c,
                          const NV2AMetalFetchUniforms *u)
{
    return !wc_reference && wc_refine(o, s, a, c, u);
}
static BOOL (*wc_summary_refine)(id, SEL, unsigned, const float *,
                                 const NV2AMetalFetchUniforms *, NSData *,
                                 uint64_t);
static BOOL wc_summary_refine_spy(id o, SEL s, unsigned a, const float *c,
                                  const NV2AMetalFetchUniforms *u,
                                  NSData *summary, uint64_t lanes)
{
    return !wc_reference && wc_summary_refine(o, s, a, c, u, summary, lanes);
}
static BOOL (*wc_summary)(id, SEL, NSData **, uint64_t *, id, NSUInteger,
                          NSUInteger, id);
static BOOL wc_summary_spy(id object, SEL selector, NSData **summary,
                           uint64_t *lanes, id attributes, NSUInteger first,
                           NSUInteger count, id commands)
{
    BOOL bound = wc_summary(object, selector, summary, lanes, attributes, first,
                            count, commands);
    if (bound && object == wc_proof_fetch && summary && lanes &&
        (*lanes & (UINT64_C(1) << 4)) && (*summary).length == 1024) {
        const NV2AMetalFloatLaneSummary *value = (*summary).bytes;
        value += 4;
        wc_float_bound = value->flags == NV2AMetalFloatLaneSummaryFinite &&
                         value->minBits == 0 && value->maxBits == 0x3f800000 &&
                         value->minExponent == 0;
    }
    return bound;
}
static BOOL wc_origin_spy(id o, SEL s, id p, const float *c, id commands)
{
    return !wc_reference && wc_origin(o, s, p, c, commands);
}
static BOOL (*wc_wait)(id, SEL, id, NSError **),
    (*wc_producers)(id, SEL, id, NSError **);
static void wc_release_gate(id owner)
{
    if (wc_tracking && owner == wc_producer) {
        wc_waits++;
        wc_gate.signaledValue = 1;
    }
}
static BOOL wc_wait_spy(id o, SEL s, id receipt, NSError **error)
{
    wc_release_gate(o);
    return wc_wait(o, s, receipt, error);
}
static BOOL wc_producers_spy(id o, SEL s, id receipt, NSError **error)
{
    wc_release_gate(o);
    return wc_producers(o, s, receipt, error);
}
static id (*wc_epoch)(id, SEL, NV2AMetalPGRAPHVertexState *, id, NSUInteger,
                      NSUInteger, NV2AMetalEpochEncoding *, id,
                      NV2AMetalCommands *, NSError **);
static id wc_epoch_spy(id object, SEL selector,
                       NV2AMetalPGRAPHVertexState *capture, id attributes,
                       NSUInteger first, NSUInteger count,
                       NV2AMetalEpochEncoding *previous, id fetch,
                       NV2AMetalCommands *commands, NSError **error)
{
    wc_hop = previous ? wc_hop + 1 : 0;
    wc_count = count;
    wc_previous = previous != nil;
    wc_proof_fetch = fetch;
    wc_float_bound = NO;
    if (!previous) {
        assert(!wc_gate || wc_gate.signaledValue);
        wc_producer = commands;
        wc_gate = [commands.device newSharedEvent];
        id<MTLSharedEvent> gate = wc_gate;
        id<MTL4CommandQueue> queue = [commands valueForKey:@"queue"];
        [queue waitForEvent:gate value:1];
        /* Failure-only escape: a removed mandatory CPU publication wait must
         * fail the count assertion without leaving the GPU queue blocked. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!gate.signaledValue)
                             gate.signaledValue = 1;
                       });
    }
    /* Kind6's middle range contains NaN until repair. Its other ranges have
     * independently captured finite0/1 Float domains, even when an earlier
     * GPU context will propagate its fault instead of executing stores. */
    wc_expected = !wc_reference && wc_kind != 1 && wc_kind != 5 &&
                  (wc_kind != 6 || wc_repaired || wc_hop != 1) &&
                  !(wc_kind == 4 && previous) && !(wc_kind == 2 && wc_hop == 1);
    if (previous && wc_kind == 4)
        [previous.programEncoding setValue:@NO forKey:@"writerProvenanceKnown"];
    /* These two controlled bridge probes alter only the host proof capture;
     * the real previous GPU context remains authoritative. */
    if (previous && wc_hop == 1 && (wc_kind == 2 || wc_kind == 3)) {
        NV2AMetalProgramUniforms u = capture.programUniforms;
        unsigned row = wc_kind == 2 ? 120 : 121;
        u.constants[row][0] = .5f;
        uint32_t written[192] = { 0 };
        written[row] = 1;
        capture = [capture
            stateByApplyingConstants:[NSData dataWithBytes:u.constants
                                                    length:sizeof(u.constants)]
                             written:[NSData dataWithBytes:written
                                                    length:sizeof(written)]
                               error:error];
        if (!capture)
            return nil;
    }
    if (!previous && wc_kind == 5) {
        NV2AMetalWritableProgram *engine = [object valueForKey:@"program"];
        NV2AMetalProgramUniforms u = capture.programUniforms;
        NV2AMetalWritableEncoding *raw =
            [engine encodeTokens:capture.programBytes.bytes
                          length:capture.programBytes.length / 16
                        uniforms:&u
                 attributeBuffer:attributes
                           first:first
                           count:count
                          access:capture.fullAccess
                     writeEnable:YES
                       rasterize:YES
                compactRegisters:YES
                        commands:commands
                           error:error];
        return raw ? [[NV2AMetalEpochEncoding alloc] initProgram:raw] : nil;
    }
    return wc_epoch(object, selector, capture, attributes, first, count,
                    previous, fetch, commands, error);
}
static id (*wc_pipeline)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL, NSError **);
static id wc_pipeline_spy(id o, SEL s, BOOL write, BOOL compact, BOOL discard,
                          BOOL chained, BOOL independent, NSError **error)
{
    if (independent != wc_expected)
        fprintf(stderr,
                "Writer chain kind%u hop%u reference%d previous%d selected%d "
                "expected%d\n",
                wc_kind, wc_hop, wc_reference, wc_previous, independent,
                wc_expected);
    assert(write && compact && !discard && chained == wc_previous &&
           !wc_pending && independent == wc_expected);
    if (wc_expected && wc_kind == 6)
        assert(wc_float_bound);
    id<MTLComputePipelineState> pipeline =
        wc_pipeline(o, s, write, compact, discard, chained, independent, error);
    if (pipeline) {
        wc_pending = YES;
        wc_width =
            independent ? MIN(wc_count, pipeline.threadExecutionWidth) : 1;
        wc_parallel += independent;
        wc_serial += !independent;
        wc_chained += chained;
    }
    return pipeline;
}
static void (*wc_dispatch)(id, SEL, MTLSize, MTLSize);
static void wc_dispatch_spy(id o, SEL s, MTLSize threads, MTLSize group)
{
    if (wc_pending) {
        assert(threads.width == (wc_expected ? wc_count : 1) &&
               threads.height == 1 && threads.depth == 1 &&
               group.width == wc_width && group.height == 1 &&
               group.depth == 1);
        wc_pending = NO;
    }
    wc_dispatch(o, s, threads, group);
}
static BOOL (*wc_emit)(id, SEL, id, id, NSError **);
static BOOL wc_emit_spy(id o, SEL s, id encoder, id commands, NSError **error)
{
    BOOL ok = wc_emit(o, s, encoder, commands, error);
    if (ok && wc_fail_emit) {
        wc_fail_emit = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.writer-chain-raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static void wc_scene(unsigned kind, BOOL full, BOOL indexed)
{
    bw_scene(0, full, NO, NO);
    PGRAPHState *pg = &state->pgraph;
    Token mul = token(2, 0, 120);
    mul.word[1] |= 1u << 9;
    source(&mul, 0, 2, 0, 0);
    source(&mul, 1, 3, 0, 0);
    destination(&mul, 0, 0, 0, 2, 8, 0);
    memcpy(pg->program_data[1], mul.word, 16);
    Token arl = token(13, 0, 0);
    source(&arl, 0, 1, 2, 0);
    destination(&arl, 0, 0, 0, 0, 0, 0);
    memcpy(pg->program_data[2], arl.word, 16);
    Token color = token(1, 0, 160);
    source(&color, 0, 3, 0, 0xe4);
    destination(&color, 0x103, 15, 0, 0, 0, 0);
    color.word[3] |= 2;
    memcpy(pg->program_data[3], color.word, 16);
    Token store = token(1, 0, 0);
    store.word[1] |= 5u << 9;
    source(&store, 0, 2, 0, 0xe4);
    destination(&store, kind == 1 ? 120 : 150, 15, 0, 0, 0, 0);
    store.word[3] |= 1;
    memcpy(pg->program_data[4], store.word, 16);
    for (unsigned row = 119; row < 123; row++)
        for (unsigned lane = 0; lane < 4; lane++) {
            float one = 1;
            memcpy(&pg->vsh_constants[row][lane], &one, 4);
        }
    for (unsigned row = 159; row <= 162; row++) {
        const float rgba[] = { .125f * (row - 158), .25f, .75f, 1 };
        memcpy(pg->vsh_constants[row], rgba, 16);
    }
    cpu_write(16384, 1024);
    const float positions[3][4] = { { .5f, .5f, 32000, 1 },
                                    { 6.5f, 1.5f, 32000, 1 },
                                    { 1.5f, 6.5f, 32000, 1 } };
    for (unsigned v = 0; v < 9; v++) {
        memcpy(state->vram_ptr + 16384 + v * 16, positions[v % 3], 16);
        state->vram_ptr[16640 + v] = v & 1 ? 255 : 0;
        const float values[] = { .125f * (v + 1), .5f, .75f, 1 };
        memcpy(state->vram_ptr + 16896 + v * 16, values, 16);
    }
    if (kind == 6) {
        pg->vertex_attributes[1].format =
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        pg->vertex_attributes[1].size = pg->vertex_attributes[1].stride = 4;
        for (unsigned v = 0; v < 9; v++) {
            float value = v == 4 ? NAN : v & 1;
            memcpy(state->vram_ptr + 16640 + v * 4, &value, 4);
        }
    }
    pg->draw_arrays_length = indexed ? 0 : 3;
    for (unsigned i = 0; i < 3; i++) {
        pg->draw_arrays_start[i] = i * 3;
        pg->draw_arrays_count[i] = 3;
    }
    pg->inline_elements_length = indexed ? 9 : 0;
    const uint32_t indices[] = { 2, 0, 1, 5, 3, 4, 8, 6, 7 };
    if (indexed)
        memcpy(pg->inline_elements, indices, sizeof(indices));
    pg->dma_report = 64;
    pg->zpass_pixel_count_enable = true;
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    qemu_mutex_unlock(&pg->lock);
}
static NSData *wc_capture(uint32_t query)
{
    NSMutableData *d = [NSMutableData dataWithBytes:state->vram_ptr + 1024
                                             length:256];
    for (unsigned i = 0; i < 16; i++)
        [d appendBytes:state->pgraph.vertex_attributes[i].inline_value
                length:16];
    [d appendBytes:state->pgraph.vsh_constants
            length:sizeof(state->pgraph.vsh_constants)];
    [d appendBytes:state->pgraph.vsh_constants_dirty
            length:sizeof(state->pgraph.vsh_constants_dirty)];
    [d appendBytes:&query length:4];
    return d;
}
static void wc_pair(unsigned kind, BOOL full, BOOL indexed, unsigned boundary)
{
    NSData *reference = nil, *pending = nil, *vertex = nil, *begin = nil,
           *failed = nil;
    unsigned referenceWaits = 0;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        wc_scene(kind, full, indexed);
        wc_kind = kind;
        wc_reference = !candidate;
        wc_pending = wc_fail_emit = NO;
        wc_repaired = NO;
        wc_waits = wc_parallel = wc_serial = wc_chained = 0;
        NSError *error = nil;
        PGRAPHState *pg = &state->pgraph;
        qemu_mutex_lock(&pg->lock);
        wc_tracking = YES;
        if (boundary) {
            pg->draw_arrays_length = 1;
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
                assert([p isEqualToData:pending] && [v isEqualToData:vertex] &&
                       [b isEqualToData:begin]);
            require([draw discardForRestoreWithError:&error] &&
                        [draw restoreVertexSnapshot:v error:&error] &&
                        [draw restoreBeginSnapshot:b error:&error] &&
                        [draw restorePendingSnapshot:p error:&error] &&
                        [draw beginWithError:&error],
                    error);
            pg->draw_arrays_length = 3;
            if (boundary == 2) {
                wc_fail_emit = YES;
                assert(![draw endWithError:&error] && error && !wc_fail_emit);
                error = nil;
                NSData *p = [draw pendingSnapshotWithError:&error];
                require(p != nil, error);
                if (!candidate)
                    failed = p;
                else
                    assert([p isEqualToData:failed]);
            }
            require([draw endWithError:&error], error);
        } else if (kind == 6) {
            require([draw beginWithError:&error], error);
            assert(![draw prepareVertexStateChangeWithError:&error] && error);
            error = nil;
            NSData *p = [draw pendingSnapshotWithError:&error];
            require(p != nil, error);
            if (!candidate)
                failed = p;
            else
                assert([p isEqualToData:failed]);
            float repaired = 0;
            cpu_write(16656, 4);
            memcpy(state->vram_ptr + 16656, &repaired, 4);
            wc_repaired = YES;
            require([draw prepareVertexStateChangeWithError:&error] &&
                        [draw endWithError:&error],
                    error);
        } else
            require([draw drawWithError:&error], error);
        wc_tracking = NO;
        assert(!wc_pending && wc_waits && wc_gate.signaledValue &&
               pg->draw_time == 1);
        if (!candidate) {
            referenceWaits = wc_waits;
            assert(!wc_parallel);
        } else {
            assert(wc_waits == referenceWaits);
            if (!kind && !boundary && !indexed)
                assert(wc_parallel == 3 && wc_chained == 2 && !wc_serial);
            if (kind == 1 || kind == 5)
                assert(!wc_parallel && wc_serial);
            if (kind == 6)
                assert(wc_parallel == 4 && wc_serial == 1);
        }
        wc_wait_totals[candidate] += wc_waits;
        wc_parallel_totals[candidate] += wc_parallel;
        wc_serial_totals[candidate] += wc_serial;
        require([draw.reports getReport:1u << 24 error:&error] &&
                    [draw.reports processWithError:&error],
                error);
        uint32_t query = report_value(0);
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        NSData *actual = wc_capture(query);
        if (!candidate)
            reference = actual;
        else if (![reference isEqualToData:actual]) {
            fprintf(stderr,
                    "Writer chain PGRAPH mismatch kind%u full%d index%d "
                    "boundary%u\n",
                    kind, full, indexed, boundary);
            abort();
        }
    }
    wc_pairs++;
}
static void writer_chain_pgraph_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(probe && [probe beginWithError:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [probe.commandBuffer computeCommandEncoder];
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(hasIndependentConstantWrites:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            @selector(hasIndependentConstantWrites:constants:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(
                @"refineIndependentConstantWrites:constants:sourceUniforms:")),
        class_getInstanceMethod(
            NV2AMetalWritableEncoding.class,
            NSSelectorFromString(
                @"canRefineConstantsForProgram:constants:commands:")),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:attributeFetch:commands:error:)),
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(@"refineIndependentConstantWrites:constants:"
                                 @"sourceUniforms:floatSummaries:laneMask:")),
        class_getInstanceMethod(
            NV2AMetalFetchResult.class,
            @selector(getFloatProofSummaries:laneMask:attributeBuffer:first:
                      count:commands:))
    };
    [encoder endEncoding];
    [probe cancel];
    IMP replacement[] = { (IMP)wc_static_spy,         (IMP)wc_constant_spy,
                          (IMP)wc_refine_spy,         (IMP)wc_origin_spy,
                          (IMP)wc_epoch_spy,          (IMP)wc_pipeline_spy,
                          (IMP)wc_dispatch_spy,       (IMP)wc_wait_spy,
                          (IMP)wc_producers_spy,      (IMP)wc_emit_spy,
                          (IMP)wc_summary_refine_spy, (IMP)wc_summary_spy },
        originals[12];
    for (unsigned i = 0; i < 12; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacement[i]);
    }
    wc_static = (void *)originals[0];
    wc_constant = (void *)originals[1];
    wc_refine = (void *)originals[2];
    wc_origin = (void *)originals[3];
    wc_epoch = (void *)originals[4];
    wc_pipeline = (void *)originals[5];
    wc_dispatch = (void *)originals[6];
    wc_wait = (void *)originals[7];
    wc_producers = (void *)originals[8];
    wc_emit = (void *)originals[9];
    wc_summary_refine = (void *)originals[10];
    wc_summary = (void *)originals[11];
    @try {
        for (unsigned full = 0; full < 2; full++)
            for (unsigned index = 0; index < 2; index++)
                wc_pair(0, full, index, 0);
        for (unsigned kind = 1; kind <= 6; kind++)
            wc_pair(kind, YES, NO, 0);
        wc_pair(0, YES, NO, 1);
        wc_pair(0, YES, NO, 2);
    } @finally {
        wc_gate.signaledValue = 1;
        wc_tracking = wc_pending = wc_fail_emit = NO;
        for (unsigned i = 0; i < 12; i++)
            method_setImplementation(methods[i], originals[i]);
        wc_gate = nil;
        wc_producer = nil;
        wc_proof_fetch = nil;
        wc_float_bound = wc_repaired = NO;
    }
    assert(wc_pairs == 12);
    printf("Writer chain PGRAPH: %u exact frame/Current/constants/dirty/query "
           "pairs; "
           "three real array ranges, one-range indexed controls, "
           "disjoint/overlap, "
           "host baseline/unknown/raw bridge probes, first fault retry, "
           "Prefix/Restore/late raster; "
           "actual dispatches parallel %u/%u serial %u/%u, unchanged gated CPU "
           "producer waits %u/%u PASS\n",
           wc_pairs, wc_parallel_totals[0], wc_parallel_totals[1],
           wc_serial_totals[0], wc_serial_totals[1], wc_wait_totals[0],
           wc_wait_totals[1]);
    groups += wc_pairs;
}
#endif
