/* Repeated DrawArrays Float proofs through PGRAPH producer and raster
 * boundaries, compared against the original oversized-array fallback.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ARRAY_FLOAT_WINDOWS_PGRAPH_H
#define TEST_METAL_ARRAY_FLOAT_WINDOWS_PGRAPH_H

typedef struct ArrayFloatWindowsPGRAPHWork {
    BOOL reference;
    NSUInteger submits, finiteBoundProofs;
    __unsafe_unretained NSMutableArray *encodings;
} ArrayFloatWindowsPGRAPHWork;
static _Thread_local ArrayFloatWindowsPGRAPHWork *afp_work;
static NSMutableData *(*afp_plan_original)(id, SEL, NSArray *, NSUInteger,
                                           NSUInteger *);
static NSMutableData *afp_plan(id owner, SEL selector, NSArray *batches,
                               NSUInteger maximum, NSUInteger *records)
{
    if (afp_work && afp_work->reference)
        return nil;
    return afp_plan_original(owner, selector, batches, maximum, records);
}
static BOOL (*afp_submit_original)(id, SEL, NSError **);
static BOOL afp_submit(id owner, SEL selector, NSError **error)
{
    if (afp_work)
        afp_work->submits++;
    return afp_submit_original(owner, selector, error);
}
static BOOL (*afp_proof_original)(id, SEL, unsigned, const float *,
                                  const NV2AMetalFetchUniforms *, NSData *,
                                  uint64_t);
static BOOL afp_proof(id owner, SEL selector, unsigned access,
                      const float *constants,
                      const NV2AMetalFetchUniforms *uniforms, NSData *data,
                      uint64_t lanes)
{
    BOOL ok = afp_proof_original(owner, selector, access, constants, uniforms,
                                 data, lanes);
    if (afp_work && ok && data.length == 1024 && (lanes & (UINT64_C(1) << 4))) {
        const NV2AMetalFloatLaneSummary *summary = data.bytes;
        const NV2AMetalFloatLaneSummary *address = &summary[4];
        afp_work->finiteBoundProofs +=
            address->flags == NV2AMetalFloatLaneSummaryFinite &&
            address->minBits == 0 && address->maxBits == UINT32_C(0x3f800000) &&
            address->minExponent == 0;
    }
    return ok; /* Observe the real bound proof; never change admission. */
}
static id afp_epoch(id object, SEL selector, id capture, id attributes,
                    NSUInteger first, NSUInteger count, id fetch, id commands,
                    NSError **error)
{
    id result = fpp_epoch(object, selector, capture, attributes, first, count,
                          fetch, commands, error);
    if (afp_work && result)
        [afp_work->encodings addObject:result];
    return result;
}
static void afp_scene(void)
{
    /* Fresh public owners prevent a previous CLI group or reference run from
     * supplying proof metadata. No private cache is reset. */
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw closeWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    draw = nil;
    surfaces = [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state
                                                        error:&error];
    draw = [[NV2AMetalPGRAPHDraw alloc] initWithState:state
                                             surfaces:surfaces
                                                error:&error];
    require(surfaces && draw, error);
    fpp_scene(NO, NO, NO, 0, YES);
    PGRAPHState *pg = &state->pgraph;
    /* Position, ARL and unused v5 arrays are disjoint, including all384 rows.
     * Color1024, Zeta4096 and Report49152 remain disjoint as well. */
    dma[2].address = 8192;
    dma[2].limit = 12288 + 384 * 16 - 1;
    pg->vertex_attributes[0].offset = 0;
    pg->vertex_attributes[1].offset = 8192;
    pg->vertex_attributes[5].offset = 12288;
    assert(pg->vertex_attributes[1].inline_value[0] == -1000);
    cpu_write(8192, 384 * 16);
    cpu_write(16384, 384 * 4);
    cpu_write(20480, 384 * 16);
    const float triangle[3][4] = { { .5f, .5f, 32000, 1 },
                                   { 6.5f, 1.5f, 32000, 1 },
                                   { 1.5f, 6.5f, 32000, 1 } };
    for (unsigned i = 0; i < 384; i++) {
        const float address = i & 1;
        const float value[] = { i + .25f, i + .5f, i + .75f, 1 };
        memcpy(state->vram_ptr + 8192 + i * 16, triangle[i % 3], 16);
        memcpy(state->vram_ptr + 16384 + i * 4, &address, 4);
        memcpy(state->vram_ptr + 20480 + i * 16, value, 16);
    }
    pg->draw_arrays_length = 16;
    for (unsigned i = 0; i < 16; i++) {
        pg->draw_arrays_start[i] = 0;
        pg->draw_arrays_count[i] = 384;
    }
}
static void array_float_windows_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(
                @"floatProofArrayWindowsForBatches:maximumRecords:records:")),
        class_getInstanceMethod(NV2AMetalPGRAPHFetch.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            @selector(hasFaultFreeReadOnlyAccess:constants:sourceUniforms:
                      floatSummaries:laneMask:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(NV2AMetalPGRAPHFetch.class,
                                @selector(completeWithError:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(
                @"scanFloatProofSources:indices:first:count:lanes:")),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
    };
    IMP replacements[] = { (IMP)afp_plan,          (IMP)afp_submit,
                           (IMP)afp_proof,         (IMP)fpp_wait,
                           (IMP)fpp_producer_wait, (IMP)fpp_complete,
                           (IMP)fpp_scan,          (IMP)afp_epoch };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    afp_plan_original = (void *)originals[0];
    afp_submit_original = (void *)originals[1];
    afp_proof_original = (void *)originals[2];
    fpp_wait_original = (void *)originals[3];
    fpp_producer_wait_original = (void *)originals[4];
    fpp_complete_original = (void *)originals[5];
    fpp_scan_original = (void *)originals[6];
    fpp_epoch_original = (void *)originals[7];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    FloatProofPGRAPHWork work[2] = { 0 };
    ArrayFloatWindowsPGRAPHWork proof[2] = { 0 };
    NSArray *reference = nil;
    @try {
        for (unsigned candidate = 0; candidate < 2; candidate++) {
            @autoreleasepool {
                afp_scene();
                PGRAPHState *pg = &state->pgraph;
                NSError *error = nil;
                NSMutableArray *actual = [NSMutableArray new];
                __attribute__((objc_precise_lifetime))
                NSMutableArray *encodings = [NSMutableArray new];
                proof[candidate].reference = !candidate;
                proof[candidate].encodings = encodings;
                qemu_mutex_lock(&pg->lock);
                NSData *constants =
                    [NSData dataWithBytes:pg->vsh_constants
                                   length:sizeof(pg->vsh_constants)];
                NSData *dirty =
                    [NSData dataWithBytes:pg->vsh_constants_dirty
                                   length:sizeof(pg->vsh_constants_dirty)];
                require([draw beginWithError:&error], error);
                NSData *begin = [draw beginSnapshotWithError:&error];
                NSData *vertex = draw.vertexSnapshot;
                NSData *pending = [draw pendingSnapshotWithError:&error];
                require(begin && vertex && pending, error);
                assert(!pending.length); /* No prior accepted prefix. */
                [actual addObjectsFromArray:@[ begin, vertex, pending ]];
                fpp_gate = [surfaces.cache.commands.device newSharedEvent];
                assert(fpp_gate);
                id<MTLSharedEvent> watchdog = fpp_gate;
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                    dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                      if (!watchdog.signaledValue)
                          watchdog.signaledValue = 2;
                    });
                fpp_gate_encode = YES;
                fpp_gate_installed = NO;
                afp_work = &proof[candidate];
                fpp_work = &work[candidate];
                BOOL ok;
                @try {
                    ok = [draw endWithError:&error];
                } @finally {
                    afp_work = NULL;
                    fpp_work = NULL;
                    fpp_gate_encode = NO;
                }
                require(ok, error);
                FloatProofPGRAPHWork *w = &work[candidate];
                w->gateAtReturn = fpp_gate.signaledValue;
                w->batchAtReturn = w->producer.batchSerial;
                w->sealedAtReturn = w->producer.sealedBufferCount;
                w->rasterAtReturn = w->producer.hasPendingRasterPass;
                if (!fpp_gate.signaledValue)
                    fpp_gate.signaledValue = 1;
                [actual addObject:fpp_frame(pg)]; /* Real full completion. */
                /* Compact readonly has exactly one GPU OR fault word per
                 * actual epoch. Read it only after the producer/frame fence. */
                assert(encodings.count == 16);
                for (NV2AMetalEpochEncoding *encoding in encodings) {
                    id program = [encoding valueForKey:@"programEncoding"];
                    id<MTLBuffer> raw = [program valueForKey:@"raw"];
                    assert(raw.storageMode == MTLStorageModeShared &&
                           raw.length == 4);
                    uint32_t fault;
                    memcpy(&fault, raw.contents, 4);
                    assert(!fault);
                    [actual addObject:[NSData dataWithBytes:&fault length:4]];
                    NV2AMetalEpochResult *result =
                        [encoding resolveWithError:&error];
                    require(result != nil, error);
                    assert(result.vertexCount == 384 && result.vertices &&
                           result.vertices.length >=
                               384 * sizeof(NV2AMetalVertex));
                    [actual addObjectsFromArray:@[
                        result.constants, result.written
                    ]];
                    [actual
                        addObject:[NSData
                                      dataWithBytes:result.vertices.contents
                                             length:384 *
                                                    sizeof(NV2AMetalVertex)]];
                }
                assert(!memcmp(constants.bytes, pg->vsh_constants,
                               constants.length) &&
                       !memcmp(dirty.bytes, pg->vsh_constants_dirty,
                               dirty.length));
                assert(!memcmp(pg->vertex_attributes[1].inline_value,
                               state->vram_ptr + 16384 + 383 * 4, 4));
                NSData *afterPending = [draw pendingSnapshotWithError:&error];
                require(afterPending != nil, error);
                [actual addObject:afterPending];
                if (!candidate)
                    reference = actual;
                else
                    assert([reference isEqualToArray:actual]);
                /* Whole Frame/Zeta/query/Current/constants/wire and actual
                 * GPU fault/vertex bytes above precede work assertions. */
                qemu_mutex_unlock(&pg->lock);
                proof[candidate].encodings = nil;
            }
        }
        assert(work[0].records == 6144 && work[1].records == 6144);
        assert(!work[0].scans && work[1].scans == 1 &&
               work[1].scanWords == 384);
        assert(!proof[0].finiteBoundProofs && proof[1].finiteBoundProofs == 16);
        assert(proof[0].submits && !proof[1].submits);
        assert(work[0].gateAtReturn == 1 && work[0].waits &&
               work[0].completions);
        assert(!work[1].gateAtReturn && !work[1].waits &&
               !work[1].completions && work[1].encodedBatch &&
               work[1].batchAtReturn == work[1].encodedBatch &&
               work[1].sealedAtReturn > work[1].sealedBefore &&
               work[1].rasterAtReturn);
    } @finally {
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
        afp_work = NULL;
        fpp_work = NULL;
        fpp_gate_encode = fpp_gate_installed = NO;
        fpp_gate = nil;
    }
    puts("Array Float windows PGRAPH: real16x384 ARL/raster, "
         "fullGPU/context/wire "
         "A/B; bound proof and pending producer PASS");
    groups++;
}
#endif
