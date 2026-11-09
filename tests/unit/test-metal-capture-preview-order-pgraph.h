/* Pure capture-attempt selection before the final, bound numerical proof.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CAPTURE_PREVIEW_ORDER_PGRAPH_H
#define TEST_METAL_CAPTURE_PREVIEW_ORDER_PGRAPH_H

typedef struct CapturePreviewOrderWork {
    BOOL reference;
    __unsafe_unretained NV2AMetalValidatedProgram *program;
    NSUInteger strictBodies, attemptBodies, snapshots, numericCalls;
} CapturePreviewOrderWork;
static _Thread_local CapturePreviewOrderWork *cpo_work;
static _Thread_local unsigned cpo_numeric_depth;
static BOOL (*cpo_attempt_original)(id, SEL, const NV2AMetalFetchUniforms *);
static BOOL (*cpo_strict_original)(id, SEL, const NV2AMetalFetchUniforms *);
static BOOL (*cpo_numeric_original)(id, SEL, unsigned, const float *,
                                    const NV2AMetalFetchUniforms *, NSData *,
                                    uint64_t);
static id (*cpo_data_original)(id, SEL, const void *, NSUInteger);

static BOOL cpo_reference(void)
{
    return cpo_work ? cpo_work->reference : fsm_work && fsm_work->reference;
}
static BOOL cpo_attempt(id owner, SEL selector,
                        const NV2AMetalFetchUniforms *preview)
{
    if (cpo_reference())
        return NO;
    if (cpo_work)
        cpo_work->attemptBodies++;
    return cpo_attempt_original(owner, selector, preview);
}
static BOOL cpo_strict(id owner, SEL selector,
                       const NV2AMetalFetchUniforms *preview)
{
    if (cpo_work)
        cpo_work->strictBodies++;
    BOOL strict = cpo_strict_original(owner, selector, preview);
    if (strict || !cpo_reference())
        return strict;
    /* The production predicate is Attempt || Strict. Only the reference's
     * first hook returns NO, so this executes exactly the original
     * Strict || Attempt bodies and short-circuit order, once each. */
    if (cpo_work)
        cpo_work->attemptBodies++;
    return cpo_attempt_original(
        owner, @selector(mayAttemptReadonlyFloatProofWithPreview:), preview);
}
static BOOL cpo_numeric(id owner, SEL selector, unsigned access,
                        const float *constants,
                        const NV2AMetalFetchUniforms *fetch, NSData *summaries,
                        uint64_t lanes)
{
    BOOL observed = cpo_work && owner == cpo_work->program && fetch;
    if (observed) {
        cpo_work->numericCalls++;
        cpo_numeric_depth++;
    }
    @try {
        return cpo_numeric_original(owner, selector, access, constants, fetch,
                                    summaries, lanes);
    } @finally {
        if (observed)
            cpo_numeric_depth--;
    }
}
static id cpo_data(id owner, SEL selector, const void *bytes, NSUInteger length)
{
    /* This factory is observed only inside this capture's exact validated
     * program's RO Fetch-proof method, never uniform/summary/index factories.
     * Its current owned key is 3072 constant bytes plus 64 16-byte domains. */
    if (cpo_work && cpo_numeric_depth && length == 3072 + 64 * 16)
        cpo_work->snapshots++;
    return cpo_data_original(owner, selector, bytes, length);
}

static BOOL cpo_end(CapturePreviewOrderWork *work, FloatProofPGRAPHWork *gpu,
                    NSError **error)
{
    assert(!cpo_work && !fpp_work);
    cpo_work = work;
    fpp_work = gpu;
    @try {
        return [draw endWithError:error];
    } @finally {
        cpo_work = NULL;
        fpp_work = NULL;
    }
}
static void cpo_gate(void)
{
    fpp_gate = [surfaces.cache.commands.device newSharedEvent];
    require(fpp_gate != nil, nil);
    id<MTLSharedEvent> watchdog = fpp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    fpp_gate_encode = YES;
    fpp_gate_installed = NO;
}
static void cpo_repeat(BOOL writer, BOOL indexed)
{
    NSArray *reference = nil;
    CapturePreviewOrderWork work[2][3] = { 0 };
    FloatProofPGRAPHWork gpu[2][3] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++)
        @autoreleasepool {
            fsm_scene(writer, indexed ? 3 : 0);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            NV2AMetalValidatedProgram *identity = nil;
            NSData *previousKey = nil;
            qemu_mutex_lock(&pg->lock);
            for (unsigned pass = 0; pass < 3; pass++) {
                require([draw beginWithError:&error], error);
                NV2AMetalPGRAPHVertexState *capture =
                    [draw valueForKey:@"vertexState"];
                NV2AMetalValidatedProgram *program = capture.validatedProgram;
                require(program != nil, nil);
                if (!identity)
                    identity = program;
                BOOL sameProgram = program == identity;
                work[candidate][pass] =
                    (CapturePreviewOrderWork){ .reference = !candidate,
                                               .program = program };
                cpo_gate();
                BOOL ok = cpo_end(&work[candidate][pass], &gpu[candidate][pass],
                                  &error);
                fpp_gate_encode = NO;
                require(ok, error);
                uint64_t gate = fpp_gate.signaledValue;
                FloatProofPGRAPHWork *g = &gpu[candidate][pass];
                BOOL pending =
                    g->encodedBatch &&
                    g->producer.batchSerial == g->encodedBatch &&
                    g->producer.sealedBufferCount > g->sealedBefore &&
                    g->producer.hasPendingRasterPass;
                NSData *key = [program valueForKey:@"fetchProofInputs"];
                BOOL sameKey = key == previousKey;
                if (!gate)
                    fpp_gate.signaledValue = 1;
                NSData *frame = fpp_frame(pg);
                [actual addObject:frame];
                if (candidate)
                    assert([reference[pass] isEqualToData:frame]);
                unsigned last = indexed ? 7 : 5;
                assert(!memcmp(pg->vertex_attributes[1].inline_value,
                               state->vram_ptr + 20480 + last * 4, 4));
                if (writer)
                    assert(pg->vsh_constants_dirty[150] &&
                           !memcmp(pg->vsh_constants[150],
                                   state->vram_ptr + 24576 + last * 16, 4));
                assert(pg->draw_time == (int)pass + 1);
                /* All framebuffer/Zeta/query/Current/context/dirty bytes
                 * precede any cache/call/allocation assertions. */
                if (writer) {
                    assert(gate == 1 && g->waits && g->completions &&
                           g->writerParallel && !g->writerSerial);
                    assert(!work[candidate][pass].attemptBodies &&
                           !work[candidate][pass].strictBodies &&
                           !work[candidate][pass].snapshots);
                } else {
                    if (!sameProgram || key.length != 4096 ||
                        work[candidate][pass].snapshots !=
                            (candidate ? (pass ? 0u : 1u) : 2u) ||
                        work[candidate][pass].attemptBodies != 1 ||
                        work[candidate][pass].strictBodies !=
                            (candidate ? 0u : 1u) ||
                        work[candidate][pass].numericCalls !=
                            (candidate ? 1u : 2u))
                        fprintf(stderr,
                                "Preview order index%d reference%u pass%u "
                                "program%d key%zu sameKey%d snapshots%zu "
                                "strict%zu attempt%zu numeric%zu\n",
                                indexed, !candidate, pass, sameProgram,
                                key.length, sameKey,
                                work[candidate][pass].snapshots,
                                work[candidate][pass].strictBodies,
                                work[candidate][pass].attemptBodies,
                                work[candidate][pass].numericCalls);
                    assert(!gate && pending && !g->waits && !g->completions &&
                           key.length == 4096 && sameProgram);
                    assert(work[candidate][pass].attemptBodies == 1 &&
                           work[candidate][pass].strictBodies ==
                               (candidate ? 0u : 1u) &&
                           work[candidate][pass].numericCalls ==
                               (candidate ? 1u : 2u));
                    assert(work[candidate][pass].snapshots ==
                           (candidate ? (pass ? 0u : 1u) : 2u));
                    if (pass)
                        assert(sameKey == !!candidate);
                    previousKey = key;
                }
            }
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            qemu_mutex_unlock(&pg->lock);
        }
    NSUInteger records = indexed ? 32 : 6;
    for (unsigned pass = 0; pass < 3; pass++)
        assert(gpu[0][pass].records == records &&
               gpu[1][pass].records == records);
}

static void cpo_fault(unsigned fault)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++)
        @autoreleasepool {
            fpp_scene(NO, NO, NO, 0, NO);
            PGRAPHState *pg = &state->pgraph;
            pg->draw_arrays_count[0] = 3;
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            require([draw beginWithError:&error], error);
            NV2AMetalPGRAPHVertexState *capture =
                [draw valueForKey:@"vertexState"];
            CapturePreviewOrderWork work = { .reference = !candidate,
                                             .program =
                                                 capture.validatedProgram };
            FloatProofPGRAPHWork gpu = { 0 };
            cpo_work = &work;
            fpp_work = &gpu;
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            cpo_work = NULL;
            fpp_work = NULL;
            require(ok, error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            require(pending != nil, error);
            uint32_t bits = fault ? UINT32_C(0x447a0000) : UINT32_C(0x7fc12345);
            cpu_write(16652, 4);
            memcpy(state->vram_ptr + 16652, &bits, 4);
            pg->draw_arrays_count[0] = 6;
            NSData *host = fpp_host();
            cpo_gate();
            cpo_work = &work;
            fpp_work = &gpu;
            ok = [draw prepareVertexStateChangeWithError:&error];
            cpo_work = NULL;
            fpp_work = NULL;
            fpp_gate_encode = NO;
            assert(!ok && error && fpp_gate.signaledValue == 1 &&
                   [host isEqualToData:fpp_host()]);
            NSString *domain = error.domain,
                     *message = error.localizedDescription;
            NSNumber *code = @(error.code);
            error = nil;
            NSData *after = [draw pendingSnapshotWithError:&error];
            require(after != nil, error);
            assert([pending isEqualToData:after]);
            const float repaired = 0;
            cpu_write(16652, 4);
            memcpy(state->vram_ptr + 16652, &repaired, 4);
            cpo_work = &work;
            fpp_work = &gpu;
            ok = [draw prepareVertexStateChangeWithError:&error] &&
                 [draw endWithError:&error];
            cpo_work = NULL;
            fpp_work = NULL;
            require(ok, error);
            NSArray *actual = @[ fpp_frame(pg), domain, message, code, after ];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(gpu.records == 9 && gpu.scans == 3 && gpu.completions == 1 &&
                   gpu.waits);
            qemu_mutex_unlock(&pg->lock);
        }
}

static void capture_preview_order_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHVertexState.class,
            @selector(mayAttemptReadonlyFloatProofWithPreview:)),
        class_getInstanceMethod(NV2AMetalPGRAPHVertexState.class,
                                @selector(mayUseReadonlyFetchPreview:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            @selector(hasFaultFreeReadOnlyAccess:constants:sourceUniforms:
                      floatSummaries:laneMask:)),
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(
                @"scanFloatProofSources:indices:first:count:lanes:")),
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
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(NV2AMetalPGRAPHFetch.class,
                                @selector(completeWithError:)),
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            @selector(tryIdleCPUReadSpans:count:completed:error:)),
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            @selector(sourceVersionForReadSpans:count:version:error:))
    };
    IMP replacements[] = { (IMP)cpo_attempt, (IMP)cpo_strict,
                           (IMP)cpo_numeric, (IMP)cpo_data,
                           (IMP)fpp_wait,    (IMP)fpp_producer_wait,
                           (IMP)fpp_scan,    (IMP)fpp_epoch,
                           (IMP)fpp_writer,  (IMP)fpp_pipeline,
                           (IMP)fpp_emit,    (IMP)fpp_complete,
                           (IMP)fsm_guard,   (IMP)fsm_version };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    cpo_attempt_original = (void *)originals[0];
    cpo_strict_original = (void *)originals[1];
    cpo_numeric_original = (void *)originals[2];
    cpo_data_original = (void *)originals[3];
    fpp_wait_original = (void *)originals[4];
    fpp_producer_wait_original = (void *)originals[5];
    fpp_scan_original = (void *)originals[6];
    fpp_epoch_original = (void *)originals[7];
    fpp_writer_original = (void *)originals[8];
    fpp_pipeline_original = (void *)originals[9];
    fpp_emit_original = (void *)originals[10];
    fpp_complete_original = (void *)originals[11];
    fsm_guard_original = (void *)originals[12];
    fsm_version_original = (void *)originals[13];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        cpo_repeat(NO, NO);
        cpo_repeat(NO, YES);
        cpo_repeat(YES, NO);
        fsm_lifecycle_pair(NO);
        fsm_busy_pair(NO);
        cpo_fault(0);
        cpo_fault(1);
    } @finally {
        if (fpp_gate)
            fpp_gate.signaledValue = 1;
        cpo_work = NULL;
        cpo_numeric_depth = 0;
        fpp_work = NULL;
        fsm_work = NULL;
        fpp_release = fpp_fail_emit = fpp_gate_encode = fpp_gate_installed = NO;
        fpp_gate = nil;
        fpp_write = nil;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    groups += 7;
    puts("Capture preview order:7 exact framebuffer/Zeta/query/Current/context "
         "pairs; "
         "real old Strict->Attempt reference, warm bound-proof identity/0 vs2 "
         "4096B snapshots, writer publication, Prefix/Restore/lateRetry, "
         "GPUbusy Current/fault/repair and NaN/USER first-error PASS");
}
#endif
