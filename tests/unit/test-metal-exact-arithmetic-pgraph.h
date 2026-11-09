/* Exact numerical admission versus the unchanged generic GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_EXACT_ARITHMETIC_PGRAPH_H
#define TEST_METAL_EXACT_ARITHMETIC_PGRAPH_H
static _Thread_local BOOL eap_reference;
static BOOL eap_writer, eap_wait_seen;
static uint32_t eap_unpublished[4];
static BOOL (*eap_ro_static)(id, SEL, unsigned),
    (*eap_w_static)(id, SEL, unsigned);
static BOOL (*eap_ro)(id, SEL, unsigned, const float *,
                      const NV2AMetalFetchUniforms *);
static BOOL (*eap_ro_summary)(id, SEL, unsigned, const float *,
                              const NV2AMetalFetchUniforms *, NSData *,
                              uint64_t);
static BOOL (*eap_w_constants)(id, SEL, unsigned, const float *);
static BOOL (*eap_w)(id, SEL, unsigned, const float *,
                     const NV2AMetalFetchUniforms *);
static BOOL (*eap_w_summary)(id, SEL, unsigned, const float *,
                             const NV2AMetalFetchUniforms *, NSData *,
                             uint64_t);
static BOOL eap_ro_static_spy(id o, SEL s, unsigned a)
{
    return !eap_reference && eap_ro_static(o, s, a);
}
static BOOL eap_w_static_spy(id o, SEL s, unsigned a)
{
    return !eap_reference && eap_w_static(o, s, a);
}
static BOOL eap_ro_spy(id o, SEL s, unsigned a, const float *c,
                       const NV2AMetalFetchUniforms *u)
{
    return !eap_reference && eap_ro(o, s, a, c, u);
}
static BOOL eap_ro_summary_spy(id o, SEL s, unsigned a, const float *c,
                               const NV2AMetalFetchUniforms *u, NSData *d,
                               uint64_t m)
{
    return !eap_reference && eap_ro_summary(o, s, a, c, u, d, m);
}
static BOOL eap_w_constants_spy(id o, SEL s, unsigned a, const float *c)
{
    return !eap_reference && eap_w_constants(o, s, a, c);
}
static BOOL eap_w_spy(id o, SEL s, unsigned a, const float *c,
                      const NV2AMetalFetchUniforms *u)
{
    return !eap_reference && eap_w(o, s, a, c, u);
}
static BOOL eap_w_summary_spy(id o, SEL s, unsigned a, const float *c,
                              const NV2AMetalFetchUniforms *u, NSData *d,
                              uint64_t m)
{
    return !eap_reference && eap_w_summary(o, s, a, c, u, d, m);
}
static void eap_before_wait(id object)
{
    if (eap_writer && !eap_wait_seen && fpp_work &&
        object == fpp_work->producer) {
        /* A queued GPU store must not become host constants before this real
         * producer completion. The gate below has not yet been released. */
        assert(!memcmp(eap_unpublished, state->pgraph.vsh_constants[150], 16));
        eap_wait_seen = YES;
    }
}
static BOOL eap_wait(id o, SEL s, id receipt, NSError **error)
{
    eap_before_wait(o);
    return fpp_wait(o, s, receipt, error);
}
static BOOL eap_producer_wait(id o, SEL s, id receipt, NSError **error)
{
    eap_before_wait(o);
    return fpp_producer_wait(o, s, receipt, error);
}
static const unsigned eap_ops[] = { NV2AMetalMACAdd, NV2AMetalMACMul,
                                    NV2AMetalMACMad, NV2AMetalMACDp3,
                                    NV2AMetalMACDph, NV2AMetalMACDp4,
                                    NV2AMetalMACDst };
static BOOL eap_blue(unsigned kind)
{
    return kind == 1 || kind == 4 || kind == 6;
}
static void eap_scene(unsigned kind, BOOL writer, BOOL indexed)
{
    fpp_scene(writer, indexed, NO, 0, kind & 1);
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[1].count = 0;
    float a[4], b[4], c[4];
    for (unsigned lane = 0; lane < 4; lane++) {
        a[lane] = b[lane] = 0x1p20f;
        c[lane] = 0x1p-40f;
    }
    if (!kind)
        for (unsigned lane = 0; lane < 4; lane++) {
            a[lane] = 0x1p25f;
            c[lane] = -0x1p25f;
        }
    else if (kind == 2)
        for (unsigned lane = 0; lane < 4; lane++)
            c[lane] = -0x1p40f;
    else if (kind == 3) {
        b[1] = -0x1p20f;
        b[2] = 0;
    } else if (kind == 4) {
        a[2] = b[2] = 0;
        a[3] = 16;
        b[1] = -0x1p20f;
        b[3] = 0x1p40f;
    } else if (kind == 5) {
        b[1] = b[3] = -0x1p20f;
    }
    memcpy(pg->vsh_constants[120], a, 16);
    memcpy(pg->vsh_constants[121], b, 16);
    memcpy(pg->vsh_constants[122], c, 16);
    const float green[4] = { 0, 1, 0, 1 }, blue[4] = { 0, 0, 1, 1 };
    memcpy(pg->vsh_constants[96], green, 16);
    memcpy(pg->vsh_constants[97], blue, 16);
    Token tokens[10];
    unsigned n = 0;
    tokens[n] = token(NV2AMetalMACMov, 0, 0);
    source(tokens + n, 0, 2, 0, 0xe4);
    destination(tokens + n++, 0x100, 15, 0, 0, 0, 0);
    for (unsigned row = 0; row < 3; row++) {
        tokens[n] = token(NV2AMetalMACMov, 0, 120 + row);
        source(tokens + n, 0, 3, 0, 0xe4);
        destination(tokens + n++, 0, 0, 0, row + 1, 15, 0);
    }
    tokens[n] = token(eap_ops[kind], 0, 0);
    source(tokens + n, 0, 1, 1, 0xe4);
    source(tokens + n, 1, 1, 2, 0xe4);
    source(tokens + n, 2, 1, 3, 0xe4);
    destination(tokens + n++, 0, 0, 0, 4, 15, 0);
    if (eap_blue(kind)) {
        tokens[n] = token(NV2AMetalMACMul, 0, 0);
        source(tokens + n, 0, 1, 4, kind == 6 ? 0x55 : 0);
        source(tokens + n, 1, 1, 3, 0);
        destination(tokens + n++, 0, 0, 0, 4, 8, 0);
    }
    tokens[n] = token(NV2AMetalMACArl, 0, 0);
    source(tokens + n++, 0, 1, 4, 0);
    tokens[n] = token(NV2AMetalMACMov, 0, 96);
    source(tokens + n, 0, 3, 0, 0xe4);
    destination(tokens + n, 0x103, 15, 0, 0, 0, 0);
    tokens[n++].word[3] |= 2;
    if (writer) {
        tokens[n] = token(NV2AMetalMACMov, 0, 0);
        tokens[n].word[1] |= 5u << 9;
        source(tokens + n, 0, 2, 0, 0);
        destination(tokens + n++, 150, 8, 0, 0, 0, 0);
    }
    tokens[n - 1].word[3] |= 1;
    memcpy(pg->program_data, tokens, n * sizeof(*tokens));
    assert(n <= ARRAY_SIZE(tokens));
    if (indexed)
        pg->inline_elements_length = 3;
    else
        pg->draw_arrays_count[0] = 3;
}
static void eap_grow(BOOL indexed)
{
    if (indexed)
        state->pgraph.inline_elements_length = 6;
    else
        state->pgraph.draw_arrays_count[0] = 6;
}
static NSData *eap_cache(NV2AMetalValidatedProgram *program)
{
    NSData *key = [program valueForKey:@"fetchProofInputs"];
    return key ?: [program valueForKey:@"constantProofInputs"];
}
static void eap_arm(FloatProofPGRAPHWork *work)
{
    fpp_gate = [surfaces.cache.commands.device newSharedEvent];
    require(fpp_gate != nil, nil);
    id<MTLSharedEvent> watchdog = fpp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    fpp_gate_installed = NO;
    fpp_gate_encode = YES;
    fpp_work = work;
}
static void eap_release(void)
{
    fpp_work = NULL;
    fpp_gate_encode = NO;
    if (!fpp_gate.signaledValue)
        fpp_gate.signaledValue = 1;
}
static void eap_pair(unsigned kind, BOOL writer, BOOL lifecycle)
{
    NSArray *reference = nil;
    FloatProofPGRAPHWork work[2] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++)
        @autoreleasepool {
            BOOL indexed = kind & 1;
            eap_scene(kind, writer, indexed);
            NSError *error = nil;
            PGRAPHState *pg = &state->pgraph;
            qemu_mutex_lock(&pg->lock);
            eap_reference = !candidate;
            eap_writer = writer;
            eap_wait_seen = NO;
            memcpy(eap_unpublished, pg->vsh_constants[150], 16);
            require([draw beginWithError:&error], error);
            eap_arm(&work[candidate]);
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NV2AMetalValidatedProgram *program =
                ((NV2AMetalPGRAPHVertexState *)[draw
                     valueForKey:@"vertexState"])
                    .validatedProgram;
            NSData *cold = (!writer && candidate) ? eap_cache(program) : nil;
            if (writer) {
                float expected = (indexed ? 1 : 2) + .25f;
                assert(!memcmp(pg->vsh_constants[150], &expected, 4));
            }
            eap_grow(indexed);
            fpp_work = &work[candidate];
            ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NSData *warm = (!writer && candidate) ? eap_cache(program) : nil;
            NSMutableArray *actual = [NSMutableArray new];
            uint64_t gateBeforeSnapshot = fpp_gate.signaledValue;
            if (lifecycle) {
                eap_release();
                NSData *pending = [draw pendingSnapshotWithError:&error],
                       *begin = [draw beginSnapshotWithError:&error],
                       *vertex = draw.vertexSnapshot;
                require(pending && begin && vertex &&
                            [draw flushWithError:&error] &&
                            [draw discardForRestoreWithError:&error] &&
                            [draw restoreVertexSnapshot:vertex error:&error] &&
                            [draw restoreBeginSnapshot:begin error:&error] &&
                            [draw restorePendingSnapshot:pending
                                                   error:&error] &&
                            [draw beginWithError:&error],
                        error);
                [actual addObjectsFromArray:@[ pending, begin, vertex ]];
                NSData *checkpoint = fpp_host();
                fpp_fail_emit = YES;
                fpp_work = &work[candidate];
                ok = [draw flushDrawWithError:&error];
                fpp_work = NULL;
                assert(
                    !ok && error && !fpp_fail_emit &&
                    [error.domain isEqualToString:@"test.float-proof.emit"] &&
                    [checkpoint isEqualToData:fpp_host()]);
                error = nil;
                NSData *after = [draw pendingSnapshotWithError:&error];
                require(after != nil, error);
                assert([after isEqualToData:pending]);
            }
            fpp_work = &work[candidate];
            ok = [draw endWithError:&error];
            fpp_work = NULL;
            uint64_t returnedGate = fpp_gate.signaledValue;
            uint64_t batch = work[candidate].producer.batchSerial;
            NSUInteger sealed = work[candidate].producer.sealedBufferCount;
            BOOL raster = work[candidate].producer.hasPendingRasterPass;
            eap_release();
            eap_reference = NO;
            require(ok, error);
            [actual addObject:fpp_frame(pg)];
            color(1, 1,
                  eap_blue(kind) ? UINT32_C(0xff0000ff) : UINT32_C(0xff00ff00));
            if (writer) {
                float expected = (indexed ? 0 : 5) + .25f;
                assert(pg->vsh_constants_dirty[150] &&
                       !memcmp(pg->vsh_constants[150], &expected, 4));
            }
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            /* Every work/cache oracle follows real framebuffer/context bytes.
             */
            assert(work[candidate].records == 6);
            if (candidate && !writer) {
                assert(cold && cold == warm &&
                       ![cold isKindOfClass:NSMutableData.class]);
                assert(!gateBeforeSnapshot && !work[candidate].waits &&
                       !work[candidate].completions);
                if (!lifecycle)
                    assert(!returnedGate &&
                           batch == work[candidate].encodedBatch && batch &&
                           sealed > work[candidate].sealedBefore && raster);
            } else {
                assert(gateBeforeSnapshot == 1 && work[candidate].waits &&
                       work[candidate].completions == 2);
                if (writer)
                    assert(eap_wait_seen);
            }
            if (writer)
                assert(candidate ? work[candidate].writerParallel == 2 &&
                                       !work[candidate].writerSerial :
                                   work[candidate].writerSerial == 2 &&
                                       !work[candidate].writerParallel);
            qemu_mutex_unlock(&pg->lock);
        }
}
/* Change one actual address dependency after a successful prefix. The first
 * new vertex faults; repair retries only that suffix, preserving prior output.
 */
static void eap_fault(BOOL writer)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++)
        @autoreleasepool {
            unsigned kind = writer ? 0 : 1;
            eap_scene(kind, writer, NO);
            NSError *error = nil;
            PGRAPHState *pg = &state->pgraph;
            qemu_mutex_lock(&pg->lock);
            eap_reference = !candidate;
            eap_writer = NO;
            FloatProofPGRAPHWork work = { 0 };
            require([draw beginWithError:&error], error);
            fpp_work = &work;
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            require(pending != nil, error);
            float original[4];
            memcpy(original, pg->vsh_constants[122], 16);
            for (unsigned lane = 0; lane < 4; lane++) {
                float invalid = writer ? 0 : 1;
                memcpy(pg->vsh_constants[122] + lane, &invalid, 4);
            }
            pg->vsh_constants_dirty[122] = true;
            eap_grow(NO);
            NSData *checkpoint = fpp_host();
            fpp_work = &work;
            ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            assert(!ok && error && [checkpoint isEqualToData:fpp_host()]);
            NSString *domain = error.domain,
                     *message = error.localizedDescription;
            NSNumber *code = @(error.code);
            error = nil;
            NSData *after = [draw pendingSnapshotWithError:&error];
            require(after != nil, error);
            assert([pending isEqualToData:after]);
            memcpy(pg->vsh_constants[122], original, 16);
            fpp_work = &work;
            ok = [draw prepareVertexStateChangeWithError:&error] &&
                 [draw endWithError:&error];
            fpp_work = NULL;
            eap_reference = NO;
            require(ok, error);
            NSArray *actual = @[ fpp_frame(pg), domain, message, code, after ];
            color(1, 1,
                  eap_blue(kind) ? UINT32_C(0xff0000ff) : UINT32_C(0xff00ff00));
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(work.records == 9 &&
                   work.completions == (writer || !candidate ? 3 : 1));
            qemu_mutex_unlock(&pg->lock);
        }
}
static void exact_arithmetic_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(hasFaultFreeReadOnlyAccess:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            @selector(hasFaultFreeReadOnlyAccess:constants:sourceUniforms:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            @selector(hasFaultFreeReadOnlyAccess:constants:sourceUniforms:
                      floatSummaries:laneMask:)),
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
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(@"refineIndependentConstantWrites:constants:"
                                 @"sourceUniforms:floatSummaries:laneMask:")),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:attributeFetch:commands:error:)),
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:)),
        class_getInstanceMethod(NV2AMetalPGRAPHFetch.class,
                                @selector(completeWithError:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
    };
    IMP replacements[] = { (IMP)eap_ro_static_spy,   (IMP)eap_ro_spy,
                           (IMP)eap_ro_summary_spy,  (IMP)eap_w_static_spy,
                           (IMP)eap_w_constants_spy, (IMP)eap_w_spy,
                           (IMP)eap_w_summary_spy,   (IMP)eap_wait,
                           (IMP)eap_producer_wait,   (IMP)fpp_epoch,
                           (IMP)fpp_writer,          (IMP)fpp_pipeline,
                           (IMP)fpp_complete,        (IMP)fpp_emit },
        originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    eap_ro_static = (void *)originals[0];
    eap_ro = (void *)originals[1];
    eap_ro_summary = (void *)originals[2];
    eap_w_static = (void *)originals[3];
    eap_w_constants = (void *)originals[4];
    eap_w = (void *)originals[5];
    eap_w_summary = (void *)originals[6];
    fpp_wait_original = (void *)originals[7];
    fpp_producer_wait_original = (void *)originals[8];
    fpp_epoch_original = (void *)originals[9];
    fpp_writer_original = (void *)originals[10];
    fpp_pipeline_original = (void *)originals[11];
    fpp_complete_original = (void *)originals[12];
    fpp_emit_original = (void *)originals[13];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned kind = 0; kind < ARRAY_SIZE(eap_ops); kind++)
            for (unsigned writer = 0; writer < 2; writer++)
                eap_pair(kind, writer, NO);
        eap_pair(0, NO, YES);
        eap_pair(1, YES, YES);
        eap_fault(NO);
        eap_fault(YES);
    } @finally {
        if (fpp_gate)
            fpp_gate.signaledValue = 1;
        eap_reference = eap_writer = NO;
        fpp_work = NULL;
        fpp_gate_encode = fpp_gate_installed = fpp_fail_emit = NO;
        fpp_gate = nil;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    puts("Exact arithmetic PGRAPH:18 generic "
         "GPU/framebuffer/depth/query/Current/context pairs; "
         "ADD/MUL/MAD/DP3/DPH/DP4/DST.y, large cancellation/scaling, cold/warm "
         "proof, "
         "RO gate0/writer publication waits, prefix/Restore/late retry and "
         "dependency-fault repair PASS");
    groups += 18;
}
#endif
