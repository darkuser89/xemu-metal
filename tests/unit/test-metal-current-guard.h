/* Current eligibility: atomic source checks and the synchronized guard.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CURRENT_GUARD_H
#define TEST_METAL_CURRENT_GUARD_H
#import <objc/runtime.h>

static NV2AMetalSurfaceCache *cg_target;
static unsigned cg_queries, cg_batches;
static BOOL cg_check_span_reuse;
static const NV2AMetalVRAMReadSpan *cg_first_spans;
static NSUInteger cg_first_count;
static NSUInteger (*cg_writers_original)(id, SEL,
                                         const NV2AMetalVRAMReadPattern *,
                                         NSUInteger, NSRange);
static BOOL (*cg_batch_original)(id, SEL, const NV2AMetalVRAMReadSpan *,
                                 NSUInteger, BOOL, BOOL *, NSError **);
static NSUInteger cg_writers(id self, SEL selector,
                             const NV2AMetalVRAMReadPattern *patterns,
                             NSUInteger count, NSRange bounds)
{
    if (self == cg_target)
        cg_queries++;
    return cg_writers_original(self, selector, patterns, count, bounds);
}
static BOOL cg_batch(id self, SEL selector, const NV2AMetalVRAMReadSpan *spans,
                     NSUInteger count, BOOL collect, BOOL *done,
                     NSError **error)
{
    if (self == cg_target) {
        cg_batches++;
        if (cg_check_span_reuse) {
            if (cg_batches == 1) {
                assert(collect);
                cg_first_spans = spans;
                cg_first_count = count;
            } else {
                assert(cg_batches == 2 && !collect &&
                       spans == cg_first_spans && count == cg_first_count);
            }
        }
    }
    return cg_batch_original(self, selector, spans, count, collect, done, error);
}
static double cg_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC_RAW, &t));
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static int cg_order(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void current_guard_tests(void)
{
    NV2AMetalSurfaceCache *savedCache = surfaces;
    NV2AMetalPGRAPHFetch *savedFetch = adapter;
    Method method = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class,
        sel_registerName("writerConflictForReadPatterns:count:bounds:"));
    Method batchMethod = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class,
        @selector(tryIdleCPUReadSpans:count:collectCompleted:completed:error:));
    assert(method && batchMethod);
    cg_writers_original =
        (void *)method_setImplementation(method, (IMP)cg_writers);
    cg_batch_original =
        (void *)method_setImplementation(batchMethod, (IMP)cg_batch);
    unsigned cases = 0, currentPairs = 0;
    @try {
        for (unsigned kind = 0; kind < 2; kind++)
            for (unsigned countIndex = 0; countIndex < 3; countIndex++)
                @autoreleasepool {
                    NSError *error = nil;
                    unsigned count = (unsigned[]){ 1, 4, 16 }[countIndex];
                    NV2AMetalCommands *queues[2];
                    NV2AMetalSurfaceCache *caches[2];
                    NV2AMetalPGRAPHFetch *fetches[2];
                    for (unsigned p = 0; p < 2; p++) {
                        queues[p] =
                            [[NV2AMetalCommands alloc] initWithError:&error];
                        require(queues[p] != nil, error);
                        caches[p] = [[NV2AMetalSurfaceCache alloc]
                            initWithCommands:queues[p]
                                        vram:savedCache.vram
                                didWriteVRAM:nil
                                       error:&error];
                        require(caches[p] != nil, error);
                        fetches[p] = [[NV2AMetalPGRAPHFetch alloc]
                            initWithState:state
                                 surfaces:caches[p]
                                    error:&error];
                        require(fetches[p] != nil, error);
                    }
                    surfaces = caches[0];
                    adapter = fetches[0];
                    reset();
                    PGRAPHState *pg = &state->pgraph;
                    for (unsigned a = 0; a < count; a++) {
                        pg->vertex_attributes[a] = (VertexAttribute){
                            .dma_select = a & 1,
                            .offset = (a / 2) * 256,
                            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                            .count = 4,
                            .size = 4,
                            .stride = 16
                        };
                        for (unsigned v = 0; v < 8; v++) {
                            float data[4] = { a + v * .125f, a * .5f, v * .25f,
                                              1 };
                            memcpy(state->vram_ptr + (a & 1 ? 8192 : 1024) +
                                       (a / 2) * 256 + v * 16,
                                   data, 16);
                        }
                    }
                    NV2AMetalPendingInput *input = nil;
                    NSArray<NSNumber *> *prefixes = @[ @0, @0 ];
                    unsigned current = 4;
                    if (kind) {
                        uint32_t indices[] = { 4, 0, 3, 1 };
                        pg->inline_elements_length = 4;
                        memcpy(pg->inline_elements, indices, sizeof(indices));
                        input = [NV2AMetalPendingInput
                            indexed:[NSData dataWithBytes:indices
                                                   length:sizeof(indices)]];
                        prefixes = @[ @0 ];
                        current = 1;
                    } else {
                        pg->draw_arrays_length = 2;
                        pg->draw_arrays_start[0] = 3;
                        pg->draw_arrays_count[0] = 2;
                        pg->draw_arrays_start[1] = 0;
                        pg->draw_arrays_count[1] = 2;
                    }
                    /* A cancelled public write registration leaves conservative
                     * read watches, with no pending writes or dirty surfaces.
                     * This is the real full-guard path, not a private-state
                     * mock. */
                    require([caches[1] prepareGPUWriteAtAddress:0
                                                         length:65536
                                                          error:&error],
                            error);
                    [caches[1] cancel];
                    for (unsigned p = 0; p < 2; p++) {
                        cg_target = caches[p];
                        cg_queries = cg_batches = 0;
                        assert([fetches[p] canCaptureCurrentForInput:input]);
                        assert(cg_batches == 1 && cg_queries == p);
                    }
                    /* Exclude the counting wrapper from timing both paths. */
                    method_setImplementation(method, (IMP)cg_writers_original);
                    method_setImplementation(batchMethod, (IMP)cg_batch_original);
                    cg_target = nil;
                    double times[2][9];
                    for (unsigned trial = 0; trial < 11; trial++)
                        for (unsigned order = 0; order < 2; order++) {
                            unsigned p = (trial + order) & 1, successes = 0;
                            double start = cg_clock();
                            for (unsigned n = 0; n < 2000; n++)
                                successes += [fetches[p]
                                    canCaptureCurrentForInput:input];
                            assert(successes == 2000);
                            if (trial >= 2)
                                times[p][trial - 2] = cg_clock() - start;
                        }
                    method_setImplementation(method, (IMP)cg_writers);
                    method_setImplementation(batchMethod, (IMP)cg_batch);
                    for (unsigned p = 0; p < 2; p++)
                        qsort(times[p], 9, sizeof(double), cg_order);
                    printf(
                        "Current guard %s/%u attributes:1 guard acquisition, "
                        "0/1 writer scans;2000 eligibility calls median "
                        "unwatched/full-watch %.6f/%.6fms "
                        "(2 warmups,9 alternating pairs,native host flags)\n",
                        kind ? "indexed" : "arrays", count,
                        times[0][4] * 1000, times[1][4] * 1000);
                    /* Even a completely unwatched batch validates ownership. */
                    require([queues[0] beginWithError:&error] != nil, error);
                    assert(![fetches[0] canCaptureCurrentForInput:input]);
                    [queues[0] cancel];
                    assert([fetches[0] canCaptureCurrentForInput:input]);
                    unsigned last = count - 1;
                    NSUInteger address = (last & 1 ? 8192 : 1024) +
                                         (last / 2) * 256 + current * 16;
                    for (unsigned p = 0; p < 2; p++) {
                        require([caches[p] prepareGPUWriteAtAddress:address
                                                             length:16
                                                              error:&error],
                                error);
                        assert(![fetches[p] canCaptureCurrentForInput:input]);
                        [caches[p] cancel];
                        assert([fetches[p] canCaptureCurrentForInput:input]);
                    }
                    /* The optimized eligibility must preserve actual typed GPU
                     * Current selection and the immutable captured inputs. */
                    NSArray<NV2AMetalPGRAPHFetchBatch *> *reference =
                        current_gpu_reference(prefixes, input);
                    uint32_t before[16][4];
                    for (unsigned a = 0; a < 16; a++)
                        memcpy(before[a], pg->vertex_attributes[a].inline_value,
                               16);
                    cg_target = surfaces;
                    cg_batches = 0;
                    cg_check_span_reuse = YES;
                    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                        [adapter encodeCurrentSnapshotsWithPrefixes:prefixes
                                                       indexedInput:input
                                                              error:&error];
                    cg_check_span_reuse = NO;
                    cg_first_spans = NULL;
                    require(batches != nil, error);
                    assert(cg_batches == 2);
                    check_captured_fetch(batches);
                    for (unsigned a = 0; a < 16; a++)
                        assert(!memcmp(before[a],
                                       pg->vertex_attributes[a].inline_value,
                                       16));
                    require(
                        [adapter completeCurrentSnapshotsWithError:&error] &&
                            [surfaces submitWithError:&error] &&
                            [surfaces waitUntilIdleWithError:&error],
                        error);
                    NV2AMetalProgramInput captured;
                    for (unsigned a = 0; a < 16; a++)
                        memcpy(captured.attributes[a],
                               pg->vertex_attributes[a].inline_value, 16);
                    unsigned records = 0;
                    for (NV2AMetalPGRAPHFetchBatch *b in reference)
                        if (b.fetch.hasCurrent) {
                            assert(!memcmp(
                                &captured,
                                (const uint8_t *)b.fetch.attributes.contents +
                                    b.fetch.vertexCount * sizeof(captured),
                                sizeof(captured)));
                            records++;
                        }
                    assert(records == 1);
                    currentPairs++;
                    cg_target = nil;
                    adapter = nil;
                    surfaces = nil;
                    cases++;
                }
    } @finally {
        cg_check_span_reuse = NO;
        cg_first_spans = NULL;
        cg_target = nil;
        method_setImplementation(method, (IMP)cg_writers_original);
        method_setImplementation(batchMethod, (IMP)cg_batch_original);
        surfaces = savedCache;
        adapter = savedFetch;
        reset();
    }
    assert(cases == 6 && currentPairs == 6);
    puts("Current guard:6 exact native GPU Current pairs;arrays highest/index "
         "last,1/4/16 attributes,two DMA banks,one guard acquisition per batch;"
         "cache health,watched GPU writes/cancel and immutable "
         "publication preserved;component host timings only PASS");
    puts("Current read spans: initial and final VRAM checks share one range "
         "array and preserve collection policy PASS");
    groups++;
}
#endif
