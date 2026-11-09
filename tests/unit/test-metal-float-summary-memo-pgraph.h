/* Float-summary memo reuse through real PGRAPH Fetch/XF and raster callers.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FLOAT_SUMMARY_MEMO_PGRAPH_H
#define TEST_METAL_FLOAT_SUMMARY_MEMO_PGRAPH_H

typedef struct FloatSummaryMemoWork {
    BOOL reference;
    NSUInteger probes, hits, keys, guards, blocked, versions;
} FloatSummaryMemoWork;
static _Thread_local FloatSummaryMemoWork *fsm_work;
static const char *fsm_phase;
static unsigned fsm_writer_kind, fsm_shape, fsm_candidate, fsm_pass;
static void fsm_require_at(BOOL ok, NSError *error, unsigned line)
{
    if (!ok) {
        const PGRAPHState *pg = &state->pgraph;
        fprintf(stderr,
                "Float memo failure: line=%u phase=%s writer=%u shape=%u "
                "reference=%u "
                "pass=%u arrays=%u indices=%u attr1offset=%llu stride=%u "
                "attr5offset=%llu DMA=%llu error=%s\n",
                line, fsm_phase, fsm_writer_kind, fsm_shape,
                (unsigned)!fsm_candidate, fsm_pass, pg->draw_arrays_length,
                pg->inline_elements_length,
                (unsigned long long)pg->vertex_attributes[1].offset,
                pg->vertex_attributes[1].stride,
                (unsigned long long)pg->vertex_attributes[5].offset,
                (unsigned long long)dma[2].limit,
                error.localizedDescription.UTF8String);
    }
    require(ok, error);
}
#define fsm_require(ok, error) fsm_require_at((ok), (error), __LINE__)
static BOOL (*fsm_reuse_original)(id, SEL, NSArray *,
                                  const NV2AMetalAttributeSource *, NSData *,
                                  NSUInteger, NSUInteger, BOOL, uint64_t);
static id (*fsm_key_original)(id, SEL, NSArray *,
                              const NV2AMetalAttributeSource *, NSData *,
                              NSUInteger, NSUInteger, BOOL, uint64_t);
static BOOL (*fsm_guard_original)(id, SEL, const NV2AMetalVRAMReadSpan *,
                                  NSUInteger, BOOL *, NSError **);
static BOOL (*fsm_version_original)(id, SEL, const NV2AMetalVRAMReadSpan *,
                                    NSUInteger, uint64_t *, NSError **);
static BOOL fsm_guard(id owner, SEL selector,
                      const NV2AMetalVRAMReadSpan *spans, NSUInteger count,
                      BOOL *ready, NSError **error)
{
    BOOL ok = fsm_guard_original(owner, selector, spans, count, ready, error);
    if (fsm_work && owner == surfaces.cache) {
        fsm_work->guards++;
        fsm_work->blocked += ok && !*ready;
    }
    return ok;
}
static BOOL fsm_version(id owner, SEL selector,
                        const NV2AMetalVRAMReadSpan *spans, NSUInteger count,
                        uint64_t *version, NSError **error)
{
    if (fsm_work && owner == surfaces.cache)
        fsm_work->versions++;
    return fsm_version_original(owner, selector, spans, count, version, error);
}
static BOOL fsm_reuse(id owner, SEL selector, NSArray *batches,
                      const NV2AMetalAttributeSource *sources, NSData *indices,
                      NSUInteger offset, NSUInteger first, BOOL arrays,
                      uint64_t lanes)
{
    if (fsm_work) {
        fsm_work->probes++;
        if (fsm_work->reference)
            return NO; /* Exactly the existing cold scanner and binding. */
    }
    BOOL hit = fsm_reuse_original(owner, selector, batches, sources, indices,
                                  offset, first, arrays, lanes);
    if (fsm_work)
        fsm_work->hits += hit;
    return hit;
}
static id fsm_key(id owner, SEL selector, NSArray *batches,
                  const NV2AMetalAttributeSource *sources, NSData *indices,
                  NSUInteger offset, NSUInteger first, BOOL arrays,
                  uint64_t lanes)
{
    if (fsm_work)
        fsm_work->keys++;
    return fsm_key_original(owner, selector, batches, sources, indices, offset,
                            first, arrays, lanes);
}
static BOOL fsm_end(FloatSummaryMemoWork *memo, FloatProofPGRAPHWork *work,
                    NSError **error)
{
    assert(!fsm_work && !fpp_work);
    fsm_work = memo;
    fpp_work = work;
    BOOL ok = [draw endWithError:error];
    fsm_work = NULL;
    fpp_work = NULL;
    return ok;
}
static void fsm_scene(BOOL writer, unsigned shape)
{
    fpp_scene(writer, shape >= 2, shape == 1, 0, YES);
    PGRAPHState *pg = &state->pgraph;
    unsigned records = shape == 3 ? 32 : 6;
    /* Nonoverlapping source arrays also support the large logical list.
     * The source used by ARL differs from the deliberately stale HostCurrent.
     */
    pg->vertex_attributes[1].offset = 4096;
    pg->vertex_attributes[5].offset = 8192;
    /* fixture() exposes only 1024 bytes. Include the last enabled source's
     * actual final record, while keeping the DMA wholly inside shared VRAM. */
    dma[2].limit = 8192 + records * 16 - 1;
    const float triangle[3][4] = { { .5f, .5f, 32000, 1 },
                                   { 6.5f, 1.5f, 32000, 1 },
                                   { 1.5f, 6.5f, 32000, 1 } };
    cpu_write(16384, records * 16);
    cpu_write(20480, records * 4);
    cpu_write(24576, records * 16);
    for (unsigned i = 0; i < records; i++) {
        const float address = i & 1;
        const float value[4] = { i + .25f, i + .5f, i + .75f, 1 };
        memcpy(state->vram_ptr + 16384 + i * 16, triangle[i % 3], 16);
        memcpy(state->vram_ptr + 20480 + i * 4, &address, 4);
        memcpy(state->vram_ptr + 24576 + i * 16, value, 16);
    }
    if (shape == 3) {
        /* Keep the RO suffix key plus its logical remap and the new memo
         * together inside the unchanged combined 64 KiB metadata budget. */
        unsigned logical = writer ? 8192 : 6144;
        assert(logical <= ARRAY_SIZE(pg->inline_elements));
        pg->inline_elements_length = logical;
        for (unsigned i = 0; i < logical; i++)
            pg->inline_elements[i] = (i * 13 + 5) % 32;
        pg->inline_elements[logical - 1] = 7; /* Not the last unique row. */
    }
}
/* Every pass is a new Begin/End execution. Only the immutable proof metadata
 * may be reused; the old scanner reference executes identical GPU work. */
static void fsm_repeat_pair(BOOL writer, unsigned shape)
{
    fsm_phase = "repeat";
    fsm_writer_kind = writer;
    fsm_shape = shape;
    NSArray *reference = nil;
    FloatSummaryMemoWork memo[2][3] = { 0 };
    FloatProofPGRAPHWork work[2][3] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        fsm_candidate = candidate;
        @autoreleasepool {
            fsm_scene(writer, shape);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            qemu_mutex_lock(&pg->lock);
            for (unsigned pass = 0; pass < 3; pass++) {
                fsm_pass = pass;
                fsm_require([draw beginWithError:&error], error);
                memo[candidate][pass].reference = !candidate;
                fpp_gate = [surfaces.cache.commands.device newSharedEvent];
                fsm_require(fpp_gate != nil, nil);
                id<MTLSharedEvent> watchdog = fpp_gate;
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                    dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                      if (!watchdog.signaledValue)
                          watchdog.signaledValue = 2;
                    });
                fpp_gate_encode = YES;
                fpp_gate_installed = NO;
                BOOL ok = fsm_end(&memo[candidate][pass],
                                  &work[candidate][pass], &error);
                fpp_gate_encode = NO;
                fsm_require(ok, error);
                uint64_t gate = fpp_gate.signaledValue;
                FloatProofPGRAPHWork *w = &work[candidate][pass];
                BOOL pendingRaster =
                    w->producer.batchSerial == w->encodedBatch &&
                    w->producer.sealedBufferCount > w->sealedBefore &&
                    w->producer.hasPendingRasterPass;
                if (!gate)
                    fpp_gate.signaledValue = 1;
                NSData *frame = fpp_frame(pg);
                [actual addObject:frame];
                if (candidate)
                    assert([reference[pass] isEqualToData:frame]);
                unsigned last = shape == 3 ? 7 : shape >= 2 ? 0 : 5;
                assert(!memcmp(pg->vertex_attributes[1].inline_value,
                               state->vram_ptr + 20480 + last * 4, 4));
                if (writer)
                    assert(pg->vsh_constants_dirty[150] &&
                           !memcmp(pg->vsh_constants[150],
                                   state->vram_ptr + 24576 + last * 16, 4));
                /* Real completed framebuffer/depth/Current/context/query
                 * bytes above precede the metadata and scheduling oracles. */
                if (writer)
                    assert(gate == 1 && w->waits && w->completions &&
                           w->writerParallel && !w->writerSerial);
                else
                    assert(!gate && pendingRaster && !w->waits &&
                           !w->completions);
                assert(pg->draw_time == (int)pass + 1);
            }
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            qemu_mutex_unlock(&pg->lock);
        }
    }
    NSUInteger expected = shape == 3            ? (writer ? 8192 : 32) :
                          shape == 2 && !writer ? 3 :
                                                  6;
    NSUInteger scans = shape == 1 ? 2 : 1;
    for (unsigned pass = 0; pass < 3; pass++) {
        assert(work[0][pass].records == expected &&
               work[1][pass].records == expected &&
               work[0][pass].scans == scans);
        assert(memo[0][pass].probes && !memo[0][pass].hits);
        assert(work[1][pass].scans == (pass ? 0 : scans) &&
               memo[1][pass].hits == (pass ? 1 : 0));
        assert(pass ? !memo[1][pass].keys : memo[1][pass].keys == 1);
        assert(memo[1][pass].guards && memo[1][pass].versions);
    }
}

/* Warm proof metadata must not make an earlier, address-relevant source
 * host-readable while Current's final row is already available elsewhere. */
static void fsm_busy_pair(BOOL dirty)
{
    fsm_phase = "busy";
    fsm_writer_kind = 0;
    fsm_shape = dirty;
    fsm_pass = 0;
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        fsm_candidate = candidate;
        @autoreleasepool {
            fpp_scene(NO, NO, NO, 0, YES);
            PGRAPHState *pg = &state->pgraph;
            pg->vertex_attributes[1].offset = 16384;
            pg->vertex_attributes[1].stride = 4096;
            dma[2].limit = 65536 - 16384 - 1;
            /* The warm GetReport must not overwrite Float source row four
             * at the fixture's original report destination, 49152. */
            dma[4].address = 61440;
            for (unsigned i = 0; i < 6; i++) {
                const float zero = 0;
                cpu_write(32768 + i * 4096, 4);
                memcpy(state->vram_ptr + 32768 + i * 4096, &zero, 4);
            }
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            NSMutableArray *actual = [NSMutableArray new];
            FloatSummaryMemoWork warm = { .reference = !candidate };
            FloatProofPGRAPHWork cold = { 0 };
            fsm_phase = "busy-cold";
            fsm_require([draw beginWithError:&error] &&
                            fsm_end(&warm, &cold, &error),
                        error);
            [actual addObject:fpp_frame(pg)];
            assert(cold.scans == 1);
            NV2AMetalCommands *commands = surfaces.cache.commands;
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
            /* Upload the distinct source target before putting its actual
             * GPU clear behind a gate. RAM's first word remains Float zero. */
            if (dirty) {
                dma[0].limit = 65535 - 1024;
                pg->surface_color.offset = 32768 - 1024;
                pg->surface_color.buffer_dirty = true;
                fsm_require([surfaces prepareColor:YES
                                              zeta:NO
                                      forRendering:NO
                                             error:&error] &&
                                [surfaces.cache submitWithError:&error] &&
                                [surfaces.cache waitUntilIdleWithError:&error],
                            error);
            }
            fpp_gate = [commands.device newSharedEvent];
            fsm_require(fpp_gate && queue, nil);
            [queue waitForEvent:fpp_gate value:1];
            uint32_t faultBits =
                dirty ? UINT32_C(0xff00ff00) : UINT32_C(0x7fc12345);
            if (dirty) {
                pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = faultBits;
                pg->regs_[NV_PGRAPH_CLEARRECTX] =
                    pg->regs_[NV_PGRAPH_CLEARRECTY] = 7u << 16;
                fsm_require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR
                                         error:&error],
                            error);
                assert(surfaces.color.address == 32768 && surfaces.color.dirty);
                pg->surface_color.offset = 0;
                pg->surface_color.buffer_dirty = true;
            } else {
                id<MTLBuffer> source = [commands.device
                    newBufferWithBytes:&faultBits
                                length:4
                               options:MTLResourceStorageModeShared];
                fsm_require(source &&
                                [surfaces.cache
                                    prepareGPUWriteAtAddress:32768
                                                      length:4
                                                       error:&error] &&
                                [commands addResource:source error:&error],
                            error);
                id<MTL4ComputeCommandEncoder> e =
                    [commands.commandBuffer computeCommandEncoder];
                fsm_require(e != nil, nil);
                [e copyFromBuffer:source
                         sourceOffset:0
                             toBuffer:surfaces.cache.vram
                    destinationOffset:32768
                                 size:4];
                [e endEncoding];
            }
            fsm_require([surfaces.cache submitWithError:&error], error);
            fpp_write = commands.lastSubmitted;
            assert(fpp_write && ![fpp_write completedWithError:&error] &&
                   !error && !fpp_gate.signaledValue);
            uint32_t before;
            memcpy(&before, state->vram_ptr + 32768, 4);
            assert(!before);
            id<MTLSharedEvent> watchdog = fpp_gate;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             if (!watchdog.signaledValue)
                                 watchdog.signaledValue = 2;
                           });
            fsm_require([draw beginWithError:&error], error);
            NV2AMetalPGRAPHFetch *fetch = [draw valueForKey:@"fetch"];
            assert([fetch canCaptureCurrentForInput:nil]);
            NSData *checkpoint = fpp_host();
            FloatSummaryMemoWork rejected = { .reference = !candidate };
            FloatProofPGRAPHWork work = { 0 };
            fpp_release = YES;
            fsm_work = &rejected;
            fpp_work = &work;
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            fsm_work = NULL;
            fpp_work = NULL;
            fpp_release = NO;
            assert(!ok && error && fpp_gate.signaledValue == 1 &&
                   [checkpoint isEqualToData:fpp_host()]);
            NSString *domain = error.domain,
                     *message = error.localizedDescription;
            NSNumber *code = @(error.code);
            error = nil;
            fsm_phase = "busy-writerwait";
            fsm_require([commands waitForSubmission:fpp_write error:&error],
                        error);
            assert(!memcmp(state->vram_ptr + 32768, &faultBits, 4));
            NSUInteger rejectedScans = work.scans;
            const float repaired = 0;
            cpu_write(32768, 4);
            memcpy(state->vram_ptr + 32768, &repaired, 4);
            FloatSummaryMemoWork retry = { .reference = !candidate };
            fsm_phase = "busy-repair";
            fsm_work = &retry;
            fpp_work = &work;
            ok = [draw prepareVertexStateChangeWithError:&error] &&
                 [draw endWithError:&error];
            fsm_work = NULL;
            fpp_work = NULL;
            fsm_require(ok, error);
            [actual
                addObjectsFromArray:@[ fpp_frame(pg), domain, message, code ]];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            /* This is the actual guard's busy answer, not an inferred lack
             * of scans. The failed and repaired producers still execute. */
            assert(rejected.blocked && !rejected.hits && !rejectedScans &&
                   work.records == 12 && work.scans == 1 && work.completions &&
                   !retry.hits && retry.versions);
            fpp_write = nil;
            fpp_gate = nil;
            qemu_mutex_unlock(&pg->lock);
        }
    }
}

/* A failed pixel emission keeps the accepted XF prefix. A new source write
 * affects only the later suffix, and Restore cannot revive a stale binding. */
static void fsm_lifecycle_pair(BOOL writer)
{
    fsm_phase = "lifecycle";
    fsm_writer_kind = writer;
    fsm_shape = fsm_pass = 0;
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        fsm_candidate = candidate;
        @autoreleasepool {
            fsm_scene(writer, 0);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            FloatSummaryMemoWork memo = { .reference = !candidate };
            FloatProofPGRAPHWork work = { 0 };
            qemu_mutex_lock(&pg->lock);
            fsm_require([draw beginWithError:&error] &&
                            fsm_end(&memo, &work, &error),
                        error);
            [actual addObject:fpp_frame(pg)];
            /* A fresh immutable journal starts at three vertices. */
            pg->draw_arrays_count[0] = 3;
            fsm_require([draw beginWithError:&error], error);
            fsm_work = &memo;
            fpp_work = &work;
            BOOL ok = [draw prepareVertexStateChangeWithError:&error];
            fsm_work = NULL;
            fpp_work = NULL;
            fsm_require(ok, error);
            NSData *old = [draw pendingSnapshotWithError:&error];
            fsm_require(old != nil, error);
            [actual addObject:old];
            const float changed = 0; /* Original suffix row three was one. */
            cpu_write(20480 + 3 * 4, 4);
            memcpy(state->vram_ptr + 20480 + 3 * 4, &changed, 4);
            pg->draw_arrays_count[0] = 6;
            fsm_work = &memo;
            fpp_work = &work;
            ok = [draw prepareVertexStateChangeWithError:&error];
            fsm_work = NULL;
            fpp_work = NULL;
            fsm_require(ok, error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            NSData *vertex = draw.vertexSnapshot;
            NSData *begin = [draw beginSnapshotWithError:&error];
            fsm_require(
                pending && vertex && begin && [draw flushWithError:&error] &&
                    [draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    [draw restorePendingSnapshot:pending error:&error] &&
                    [draw beginWithError:&error],
                error);
            [actual addObjectsFromArray:@[ pending, vertex, begin ]];
            NSData *restored = [draw pendingSnapshotWithError:&error];
            fsm_require(restored != nil, error);
            assert([pending isEqualToData:restored]);
            NSData *checkpoint = fpp_host();
            fpp_fail_emit = YES;
            fsm_work = &memo;
            fpp_work = &work;
            ok = [draw flushDrawWithError:&error];
            fsm_work = NULL;
            fpp_work = NULL;
            assert(!ok && error && !fpp_fail_emit &&
                   [error.domain isEqualToString:@"test.float-proof.emit"] &&
                   [checkpoint isEqualToData:fpp_host()]);
            NSString *domain = error.domain;
            NSNumber *code = @(error.code);
            error = nil;
            fsm_require(fsm_end(&memo, &work, &error), error);
            [actual addObjectsFromArray:@[ fpp_frame(pg), domain, code ]];
            /* Force one entirely new capture after Restore, not only replay
             * the already accepted journal/snapshot above. */
            fsm_require([draw beginWithError:&error] &&
                            fsm_end(&memo, &work, &error),
                        error);
            [actual addObject:fpp_frame(pg)];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(work.records == 18);
            qemu_mutex_unlock(&pg->lock);
        }
    }
}

static void float_summary_memo_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(@"reuseFloatProofForBatches:sources:indexData:"
                                 @"indexOffset:first:arrays:lanes:")),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(@"floatProofKeyForBatches:sources:indexData:"
                                 @"indexOffset:first:arrays:lanes:")),
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
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            @selector(tryIdleCPUReadSpans:count:completed:error:)),
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            @selector(sourceVersionForReadSpans:count:version:error:))
    };
    IMP replacements[] = { (IMP)fsm_reuse,  (IMP)fsm_key,
                           (IMP)fpp_scan,   (IMP)fpp_epoch,
                           (IMP)fpp_writer, (IMP)fpp_pipeline,
                           (IMP)fpp_emit,   (IMP)fpp_complete,
                           (IMP)fpp_wait,   (IMP)fpp_producer_wait,
                           (IMP)fsm_guard,  (IMP)fsm_version };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    fsm_reuse_original = (void *)originals[0];
    fsm_key_original = (void *)originals[1];
    fpp_scan_original = (void *)originals[2];
    fpp_epoch_original = (void *)originals[3];
    fpp_writer_original = (void *)originals[4];
    fpp_pipeline_original = (void *)originals[5];
    fpp_emit_original = (void *)originals[6];
    fpp_complete_original = (void *)originals[7];
    fpp_wait_original = (void *)originals[8];
    fpp_producer_wait_original = (void *)originals[9];
    fsm_guard_original = (void *)originals[10];
    fsm_version_original = (void *)originals[11];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned writer = 0; writer < 2; writer++) {
            for (unsigned shape = 0; shape < 4; shape++) {
                fsm_repeat_pair(writer, shape);
                pairs++;
            }
            fsm_lifecycle_pair(writer);
            pairs++;
        }
        for (unsigned dirty = 0; dirty < 2; dirty++) {
            fsm_busy_pair(dirty);
            pairs++;
        }
    } @finally {
        if (fpp_gate)
            fpp_gate.signaledValue = 1;
        fsm_work = NULL;
        fpp_work = NULL;
        fpp_release = fpp_fail_emit = fpp_gate_encode = fpp_gate_installed = NO;
        fpp_gate = nil;
        fpp_write = nil;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    printf(
        "PGRAPH Float summary memo: %u exact framebuffer/depth/query/"
        "Current/constants/archive pairs; cold/warm/old-scanner, arrays/"
        "multirange/indexed remap/6144-8192 logical inputs, fresh XF, writer "
        "publication, prefix/Restore/late retry, warm gated raw writer/"
        "dirty download/fault/repair PASS\n",
        pairs);
    groups += pairs;
}
#undef fsm_require
#endif
