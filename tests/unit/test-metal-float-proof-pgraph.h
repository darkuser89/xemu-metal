/* Guarded Float domains through the real PGRAPH Fetch/XF callers.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FLOAT_PROOF_PGRAPH_H
#define TEST_METAL_FLOAT_PROOF_PGRAPH_H

typedef struct FloatProofPGRAPHWork {
    BOOL reference;
    unsigned binding;
    __unsafe_unretained NV2AMetalCommands *producer;
    NSUInteger waits, scans, scanWords, records, writerParallel, writerSerial;
    NSUInteger completions;
    uint64_t gateAtReturn;
    uint64_t batchAtReturn, encodedBatch;
    NSUInteger sealedBefore;
    NSUInteger sealedAtReturn;
    BOOL rasterAtReturn;
} FloatProofPGRAPHWork;
static _Thread_local FloatProofPGRAPHWork *fpp_work;
static id<MTLSharedEvent> fpp_gate;
static NV2AMetalSubmission *fpp_write;
static BOOL fpp_release, fpp_fail_emit, fpp_gate_encode, fpp_gate_installed;
static BOOL (*fpp_complete_original)(id, SEL, NSError **);
static BOOL (*fpp_emit_original)(id, SEL, id, id, NSError **);
static uint64_t (*fpp_lanes_original)(id, SEL);
static BOOL (*fpp_wait_original)(id, SEL, id, NSError **);
static BOOL (*fpp_producer_wait_original)(id, SEL, id, NSError **);
static BOOL (*fpp_summary_original)(id, SEL, NSData **, uint64_t *, id,
                                    NSUInteger, NSUInteger, id);
static id (*fpp_scan_original)(id, SEL, const NV2AMetalAttributeSource *,
                               const uint32_t *, NSUInteger, NSUInteger,
                               uint64_t);
static id (*fpp_epoch_original)(id, SEL, id, id, NSUInteger, NSUInteger, id, id,
                                NSError **);
static id (*fpp_writer_original)(id, SEL, id, id, NSUInteger, NSUInteger, id,
                                 id, id, NSError **);
static id (*fpp_pipeline_original)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL,
                                   NSError **);
static BOOL fpp_emit(id object, SEL selector, id encoder, id commands,
                     NSError **error)
{
    if (fpp_fail_emit) {
        fpp_fail_emit = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.float-proof.emit"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return fpp_emit_original(object, selector, encoder, commands, error);
}
static uint64_t fpp_lanes(id object, SEL selector)
{
    return fpp_work && fpp_work->reference ?
               0 :
               fpp_lanes_original(object, selector);
}
static void fpp_arm_producer(NV2AMetalCommands *commands)
{
    if (!fpp_gate_encode || fpp_gate_installed)
        return;
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
    assert(queue && fpp_gate && !fpp_gate.signaledValue);
    [queue waitForEvent:fpp_gate value:1];
    fpp_gate_installed = YES;
}
static BOOL fpp_complete(id object, SEL selector, NSError **error)
{
    if (fpp_work)
        fpp_work->completions++;
    return fpp_complete_original(object, selector, error);
}
static void fpp_observe_wait(id object)
{
    if (!fpp_work)
        return;
    if (object == fpp_work->producer) {
        fpp_work->waits++;
        if (fpp_gate_encode && !fpp_gate.signaledValue) {
            NSError *error = nil;
            NV2AMetalSubmission *receipt = [object lastSubmitted];
            assert(fpp_gate_installed && receipt &&
                   ![receipt completedWithError:&error] && !error);
            fpp_gate.signaledValue = 1;
        }
    }
    if (fpp_release && object == surfaces.cache.commands &&
        !fpp_gate.signaledValue) {
        NSError *error = nil;
        assert(fpp_write && ![fpp_write completedWithError:&error] && !error);
        fpp_gate.signaledValue = 1;
    }
}
static BOOL fpp_wait(id object, SEL selector, id receipt, NSError **error)
{
    fpp_observe_wait(object);
    return fpp_wait_original(object, selector, receipt, error);
}
static BOOL fpp_producer_wait(id object, SEL selector, id receipt,
                              NSError **error)
{
    fpp_observe_wait(object);
    return fpp_producer_wait_original(object, selector, receipt, error);
}
static BOOL fpp_summary(id object, SEL selector, NSData **summaries,
                        uint64_t *lanes, id attributes, NSUInteger first,
                        NSUInteger count, id commands)
{
    unsigned binding = fpp_work ? fpp_work->binding : 0;
    return fpp_summary_original(object, selector, summaries, lanes,
                                binding == 1 ? surfaces.cache.vram : attributes,
                                binding == 2 ? NSUIntegerMax : first, count,
                                binding == 3 ? nil : commands);
}
static id fpp_scan(id object, SEL selector,
                   const NV2AMetalAttributeSource *sources,
                   const uint32_t *indices, NSUInteger first, NSUInteger count,
                   uint64_t lanes)
{
    if (fpp_work) {
        fpp_work->scans++;
        fpp_work->scanWords += count * __builtin_popcountll(lanes);
    }
    return fpp_scan_original(object, selector, sources, indices, first, count,
                             lanes);
}
static id fpp_epoch(id object, SEL selector, id capture, id attributes,
                    NSUInteger first, NSUInteger count, id fetch, id commands,
                    NSError **error)
{
    if (fpp_work) {
        if (!fpp_work->records) {
            fpp_work->encodedBatch = [commands batchSerial];
            fpp_work->sealedBefore = [commands sealedBufferCount];
        }
        fpp_work->producer = commands;
        fpp_work->records += count;
        if (count)
            fpp_arm_producer(commands);
    }
    return fpp_epoch_original(object, selector, capture, attributes, first,
                              count, fetch, commands, error);
}
static id fpp_writer(id object, SEL selector, id capture, id attributes,
                     NSUInteger first, NSUInteger count, id previous, id fetch,
                     id commands, NSError **error)
{
    if (fpp_work) {
        if (!fpp_work->records) {
            fpp_work->encodedBatch = [commands batchSerial];
            fpp_work->sealedBefore = [commands sealedBufferCount];
        }
        fpp_work->producer = commands;
        fpp_work->records += count;
        if (count)
            fpp_arm_producer(commands);
    }
    return fpp_writer_original(object, selector, capture, attributes, first,
                               count, previous, fetch, commands, error);
}
static id fpp_pipeline(id object, SEL selector, BOOL write, BOOL compact,
                       BOOL discard, BOOL chained, BOOL independent,
                       NSError **error)
{
    id result = fpp_pipeline_original(object, selector, write, compact, discard,
                                      chained, independent, error);
    if (result && write && fpp_work) {
        fpp_work->writerParallel += independent;
        fpp_work->writerSerial += !independent;
    }
    return result;
}
static void fpp_scene(BOOL writer, BOOL indexed, BOOL ranges, unsigned values,
                      BOOL full)
{
    bw_scene(3, full, indexed, ranges);
    PGRAPHState *pg = &state->pgraph;
    if (!writer) {
        pg->enable_vertex_program_write = false;
        pg->program_data[2][3] |= 1;
    }
    VertexAttribute *a = &pg->vertex_attributes[1];
    a->count = 1;
    a->stride = values == 2 ? 0 : 4;
    a->inline_value[0] = -1000; /* Distinct from every finite source value. */
    const uint32_t edgeBits[] = { 0,          0x80000000, 1,
                                  0x80000001, 0xbf400000, 0x3fa00000 };
    cpu_write(16640, 24);
    for (unsigned i = 0; i < 6; i++) {
        float value = i & 1 ? 1 : 0;
        uint32_t bits;
        memcpy(&bits, &value, 4);
        if (values == 1)
            bits = edgeBits[i];
        if (values == 2)
            bits = 0x3f800000;
        memcpy(state->vram_ptr + 16640 + i * 4, &bits, 4);
    }
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                      NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                      7u << 16;
    pg->dma_report = 80;
    pg->zpass_pixel_count_enable = true;
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    qemu_mutex_unlock(&pg->lock);
}
/* The ordinary readback/report path runs after the measured producer scope. */
static NSData *fpp_frame(PGRAPHState *pg)
{
    assert(!fpp_work);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    qemu_mutex_lock(&pg->lock);
    NSError *error = nil;
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(query);
    BOOL changed = NO;
    for (unsigned i = 0; i < 64; i++) {
        uint32_t pixel;
        memcpy(&pixel, state->vram_ptr + 1024 + i * 4, 4);
        changed |= pixel != UINT32_C(0xffff0000);
    }
    assert(changed);
    return cpp_capture(query);
}
static NSData *fpp_host(void)
{
    PGRAPHState *pg = &state->pgraph;
    NSMutableData *data = [NSMutableData new];
    for (unsigned i = 0; i < 16; i++)
        [data appendBytes:pg->vertex_attributes[i].inline_value length:16];
    [data appendBytes:pg->vsh_constants length:sizeof(pg->vsh_constants)];
    [data appendBytes:pg->vsh_constants_dirty
               length:sizeof(pg->vsh_constants_dirty)];
    return data;
}
static void fpp_pair(BOOL writer, BOOL indexed, BOOL ranges, unsigned values,
                     BOOL full, unsigned binding)
{
    NSData *reference = nil;
    FloatProofPGRAPHWork work[2] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            fpp_scene(writer, indexed, ranges, values, full);
            NSError *error = nil;
            PGRAPHState *pg = &state->pgraph;
            qemu_mutex_lock(&pg->lock);
            require([draw beginWithError:&error], error);
            work[candidate].reference = !candidate;
            work[candidate].binding = candidate ? binding : 0;
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
            fpp_work = &work[candidate];
            BOOL ok = [draw endWithError:&error];
            fpp_work = NULL;
            fpp_gate_encode = NO;
            require(ok, error);
            work[candidate].gateAtReturn = fpp_gate.signaledValue;
            work[candidate].batchAtReturn =
                work[candidate].producer.batchSerial;
            work[candidate].sealedAtReturn =
                work[candidate].producer.sealedBufferCount;
            work[candidate].rasterAtReturn =
                work[candidate].producer.hasPendingRasterPass;
            if (!fpp_gate.signaledValue)
                fpp_gate.signaledValue = 1;
            NSData *actual = fpp_frame(pg);
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToData:actual]);
            unsigned current = indexed ? 0 : 5;
            uint32_t expected;
            memcpy(&expected,
                   state->vram_ptr + 16640 + (values == 2 ? 0 : current * 4),
                   4);
            assert(
                !memcmp(&expected, pg->vertex_attributes[1].inline_value, 4));
            if (writer) {
                assert(pg->vsh_constants_dirty[150]);
                assert(!memcmp(pg->vsh_constants[150],
                               pg->vertex_attributes[5].inline_value, 4));
            }
            qemu_mutex_unlock(&pg->lock);
        }
    }
    /* Actual GPU framebuffer/depth/context/query bytes precede work oracles. */
    if (work[0].records != work[1].records || !work[0].records ||
        !work[0].waits)
        fprintf(stderr,
                "Float proof work: writer%d index%d ranges%d values%u full%d "
                "binding%u records%zu/%zu waits%zu/%zu scans%zu/%zu\n",
                writer, indexed, ranges, values, full, binding, work[0].records,
                work[1].records, work[0].waits, work[1].waits, work[0].scans,
                work[1].scans);
    assert(work[0].records == work[1].records && work[0].records &&
           work[0].waits);
    assert(work[0].gateAtReturn == 1 && work[0].completions);
    if (writer) {
        assert(work[1].gateAtReturn == 1 && work[1].completions);
        assert(work[1].waits && work[0].writerSerial &&
               !work[0].writerParallel && work[1].writerParallel &&
               !work[1].writerSerial);
    } else {
        if (binding)
            assert(work[1].gateAtReturn == 1 && work[1].waits &&
                   work[1].completions);
        else {
            /* End checkpoints this actual producer's batch. It does not
             * submit it, so an older lastSubmitted is irrelevant here. */
            assert(!work[1].gateAtReturn && !work[1].waits &&
                   !work[1].completions && work[1].encodedBatch &&
                   work[1].batchAtReturn == work[1].encodedBatch &&
                   work[1].sealedAtReturn > work[1].sealedBefore &&
                   work[1].rasterAtReturn);
        }
    }
    assert(!work[0].scans &&
           (values == 2 ? !work[1].scans : work[1].scans != 0));
}
/* Accepted XF prefix, suffix-only growth, immutable archive and Begin/vertex
 * Restore. A late fragment failure must not repeat the accepted transform. */
static void fpp_prefix_pair(BOOL indexed)
{
    NSMutableArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            fpp_scene(NO, indexed, NO, 0, YES);
            PGRAPHState *pg = &state->pgraph;
            if (indexed) {
                const uint32_t list[] = { 2, 0, 1, 2, 3, 0 };
                memcpy(pg->inline_elements, list, sizeof(list));
                pg->inline_elements_length = 3;
            } else
                pg->draw_arrays_count[0] = 3;
            NSError *error = nil;
            FloatProofPGRAPHWork work = { .reference = !candidate };
            NSMutableArray *actual = [NSMutableArray new];
            qemu_mutex_lock(&pg->lock);
            require([draw beginWithError:&error], error);
            fpp_work = &work;
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NSData *old = [draw pendingSnapshotWithError:&error];
            require(old != nil, error);
            [actual addObject:old];
            if (indexed)
                pg->inline_elements_length = 6;
            else
                pg->draw_arrays_count[0] = 6;
            /* Previously accepted source values are changed; only the suffix
             * may be fetched again. */
            const float changed = 1;
            cpu_write(16640, 4);
            memcpy(state->vram_ptr + 16640, &changed, 4);
            fpp_work = &work;
            ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            NSData *vertex = draw.vertexSnapshot;
            NSData *begin = [draw beginSnapshotWithError:&error];
            require(pending && vertex && begin &&
                        [draw flushWithError:&error] &&
                        [draw discardForRestoreWithError:&error] &&
                        [draw restoreVertexSnapshot:vertex error:&error] &&
                        [draw restoreBeginSnapshot:begin error:&error] &&
                        [draw restorePendingSnapshot:pending error:&error] &&
                        [draw beginWithError:&error],
                    error);
            [actual addObject:pending];
            [actual addObject:vertex];
            [actual addObject:begin];
            NSData *restored = [draw pendingSnapshotWithError:&error];
            require(restored != nil, error);
            assert([restored isEqualToData:pending]);
            fpp_fail_emit = YES;
            NSData *checkpoint = fpp_host();
            fpp_work = &work;
            ok = [draw flushDrawWithError:&error];
            fpp_work = NULL;
            assert(!ok && error && !fpp_fail_emit &&
                   [error.domain isEqualToString:@"test.float-proof.emit"] &&
                   [checkpoint isEqualToData:fpp_host()]);
            error = nil;
            fpp_work = &work;
            ok = [draw endWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            [actual addObject:fpp_frame(pg)];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            /* Sources executed once per logical suffix (dedupe may reduce
             * each indexed suffix separately); Restore/retry adds no XF. */
            assert(work.records == 6 && work.scans == (candidate ? 2 : 0));
            assert(work.completions == (candidate ? 0 : 2));
            qemu_mutex_unlock(&pg->lock);
        }
    }
}
static void fpp_fault_pair(unsigned fault)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            fpp_scene(NO, NO, NO, 0, NO);
            PGRAPHState *pg = &state->pgraph;
            pg->draw_arrays_count[0] = 3;
            NSError *error = nil;
            FloatProofPGRAPHWork work = { .reference = !candidate };
            qemu_mutex_lock(&pg->lock);
            require([draw beginWithError:&error], error);
            fpp_work = &work;
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            require(pending != nil, error);
            uint32_t bits = fault == 0 ? UINT32_C(0x7fc12345) :
                            fault == 1 ? UINT32_C(0x7f800000) :
                                         UINT32_C(0x447a0000); /* 1000 */
            cpu_write(16652, 4);
            memcpy(state->vram_ptr + 16652, &bits, 4);
            pg->draw_arrays_count[0] = 6;
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
            const float repaired = 0;
            cpu_write(16652, 4);
            memcpy(state->vram_ptr + 16652, &repaired, 4);
            fpp_work = &work;
            ok = [draw prepareVertexStateChangeWithError:&error] &&
                 [draw endWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NSArray *actual = @[ fpp_frame(pg), domain, message, code, after ];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(work.completions == (candidate ? 1 : 3) &&
                   work.records == 9 &&
                   (candidate ? work.scans == 3 : !work.scans));
            qemu_mutex_unlock(&pg->lock);
        }
    }
}
/* Current's last Float row is ready on another page, while an earlier
 * address-relevant row is a real gated GPU destination. No Float-word scan
 * may occur, even though the Current-only prerequisite succeeds. */
static void fpp_busy_pair(void)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            fpp_scene(NO, NO, NO, 0, YES);
            PGRAPHState *pg = &state->pgraph;
            VertexAttribute *a = &pg->vertex_attributes[1];
            a->offset = 16384;
            a->stride = 4096;
            dma[2].limit = 65536 - 16384 - 1;
            for (unsigned i = 0; i < 6; i++) {
                cpu_write(32768 + i * 4096, 4);
                const float value = 0;
                memcpy(state->vram_ptr + 32768 + i * 4096, &value, 4);
            }
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            require([surfaces prepareColor:YES
                                      zeta:YES
                              forRendering:NO
                                     error:&error] &&
                        [surfaces.cache submitWithError:&error] &&
                        [surfaces.cache waitUntilIdleWithError:&error] &&
                        [draw beginWithError:&error],
                    error);
            NV2AMetalCommands *commands = surfaces.cache.commands;
            fpp_gate = [commands.device newSharedEvent];
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
            uint32_t nan = UINT32_C(0x7fc12345);
            id<MTLBuffer> source = [commands.device
                newBufferWithBytes:&nan
                            length:4
                           options:MTLResourceStorageModeShared];
            require(fpp_gate && source &&
                        [surfaces.cache prepareGPUWriteAtAddress:32768
                                                          length:4
                                                           error:&error] &&
                        [commands addResource:source error:&error],
                    error);
            [queue waitForEvent:fpp_gate value:1];
            id<MTL4ComputeCommandEncoder> encoder =
                [commands.commandBuffer computeCommandEncoder];
            require(encoder != nil, nil);
            [encoder copyFromBuffer:source
                       sourceOffset:0
                           toBuffer:surfaces.cache.vram
                  destinationOffset:32768
                               size:4];
            [encoder endEncoding];
            require([surfaces.cache submitWithError:&error], error);
            fpp_write = commands.lastSubmitted;
            assert(fpp_write && ![fpp_write completedWithError:&error] &&
                   !error && !fpp_gate.signaledValue);
            NV2AMetalPGRAPHFetch *fetch = [draw valueForKey:@"fetch"];
            assert([fetch canCaptureCurrentForInput:nil]);
            id<MTLSharedEvent> watchdog = fpp_gate;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             if (!watchdog.signaledValue)
                                 watchdog.signaledValue = 2;
                           });
            NSData *checkpoint = fpp_host();
            FloatProofPGRAPHWork work = { .reference = !candidate };
            fpp_release = YES;
            fpp_work = &work;
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            fpp_work = NULL;
            fpp_release = NO;
            assert(!ok && error && fpp_gate.signaledValue == 1 &&
                   [checkpoint isEqualToData:fpp_host()]);
            NSString *domain = error.domain,
                     *message = error.localizedDescription;
            NSNumber *code = @(error.code);
            error = nil;
            /* The failed GPU instruction really read the queued NaN. */
            require([commands waitForSubmission:fpp_write error:&error], error);
            assert(!memcmp(state->vram_ptr + 32768, &nan, 4));
            NSUInteger rejectedScans = work.scans;
            const float repaired = 0;
            cpu_write(32768, 4);
            memcpy(state->vram_ptr + 32768, &repaired, 4);
            fpp_work = &work;
            ok = [draw prepareVertexStateChangeWithError:&error] &&
                 [draw endWithError:&error];
            fpp_work = NULL;
            require(ok, error);
            NSArray *actual = @[ fpp_frame(pg), domain, message, code ];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(work.waits && work.completions == (candidate ? 1 : 2) &&
                   !rejectedScans && work.records == 12 &&
                   work.scans == (candidate ? 1 : 0));
            fpp_write = nil;
            fpp_gate = nil;
            qemu_mutex_unlock(&pg->lock);
        }
    }
}
static void float_proof_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(readonlyProofAttributeLanes64)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(
            NV2AMetalFetchResult.class,
            @selector(getFloatProofSummaries:laneMask:attributeBuffer:first:
                      count:commands:)),
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
                                @selector(completeWithError:))
    };
    IMP replacements[] = { (IMP)fpp_lanes,         (IMP)fpp_wait,
                           (IMP)fpp_producer_wait, (IMP)fpp_summary,
                           (IMP)fpp_scan,          (IMP)fpp_epoch,
                           (IMP)fpp_writer,        (IMP)fpp_pipeline,
                           (IMP)fpp_emit,          (IMP)fpp_complete };
    IMP originals[10];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    fpp_lanes_original = (void *)originals[0];
    fpp_wait_original = (void *)originals[1];
    fpp_producer_wait_original = (void *)originals[2];
    fpp_summary_original = (void *)originals[3];
    fpp_scan_original = (void *)originals[4];
    fpp_epoch_original = (void *)originals[5];
    fpp_writer_original = (void *)originals[6];
    fpp_pipeline_original = (void *)originals[7];
    fpp_emit_original = (void *)originals[8];
    fpp_complete_original = (void *)originals[9];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned indexed = 0; indexed < 2; indexed++) {
            fpp_pair(NO, indexed, NO, 0, NO, 0);
            fpp_pair(NO, indexed, NO, 1, YES, 0);
            pairs += 2;
        }
        fpp_pair(NO, NO, YES, 0, YES, 0);
        fpp_pair(NO, NO, NO, 2, YES, 0);
        pairs += 2;
        for (unsigned indexed = 0; indexed < 2; indexed++) {
            fpp_pair(YES, indexed, YES, 0, YES, 0);
            pairs++;
        }
        for (unsigned binding = 1; binding <= 3; binding++) {
            fpp_pair(NO, YES, NO, 0, YES, binding);
            pairs++;
        }
        for (unsigned indexed = 0; indexed < 2; indexed++) {
            fpp_prefix_pair(indexed);
            pairs++;
        }
        for (unsigned fault = 0; fault < 3; fault++) {
            fpp_fault_pair(fault);
            pairs++;
        }
        fpp_busy_pair();
        pairs++;
    } @finally {
        if (fpp_gate)
            fpp_gate.signaledValue = 1;
        fpp_work = NULL;
        fpp_release = fpp_fail_emit = fpp_gate_encode = fpp_gate_installed = NO;
        fpp_gate = nil;
        fpp_write = nil;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    printf(
        "PGRAPH guarded Float proof: %u exact framebuffer/depth/query/"
        "Current/constants pairs; arrays/remap, IEEE edge values, stride0, "
        "writer dispatch, binding/range rejection, prefix/Restore/late retry, "
        "NaN/Inf/address faults and gated non-Current row PASS\n",
        pairs);
    groups += pairs;
}
#endif
