/* Real guarded PGRAPH DMA Float domains versus generic/serial XF execution.
 * No VM, renderer registration, application or window is started.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BOUND_FLOAT_PROOF_H
#define TEST_METAL_BOUND_FLOAT_PROOF_H
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/fetch-pgraph.h"

static NV2AState *bfp_state;
bool tcg_allowed = true;
uint64_t memory_region_size(MemoryRegion *region)
{
    assert(bfp_state && region == bfp_state->vram);
    return 65536;
}
DMAObject nv_dma_load(NV2AState *state, hwaddr object)
{
    assert(state == bfp_state && object == 16);
    return (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                        .address = 1024,
                        .limit = 65535 };
}
bool memory_region_test_and_clear_dirty(MemoryRegion *region, hwaddr address,
                                        hwaddr length, unsigned client)
{
    assert(bfp_state && region == bfp_state->vram &&
           client == DIRTY_MEMORY_NV2A && length && address < 65536 &&
           length <= 65536 - address);
    return false;
}
void memory_region_set_client_dirty(MemoryRegion *region, hwaddr address,
                                    hwaddr length, unsigned client)
{
    assert(bfp_state && region == bfp_state->vram &&
           client == DIRTY_MEMORY_NV2A && length && address < 65536 &&
           length <= 65536 - address);
}
static BOOL bfp_active, bfp_fail_pipeline, bfp_selected;
static NSError *bfp_failure;
static id (*bfp_pipeline_original)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL,
                                   NSError **);
static id bfp_pipeline(id owner, SEL selector, BOOL write, BOOL compact,
                       BOOL discard, BOOL chained, BOOL independent,
                       NSError **error)
{
    if (bfp_active) {
        bfp_selected = independent;
        if (bfp_fail_pipeline) {
            bfp_fail_pipeline = NO;
            if (error)
                *error = bfp_failure;
            return nil;
        }
    }
    return bfp_pipeline_original(owner, selector, write, compact, discard,
                                 chained, independent, error);
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
bfp_capture(NV2AMetalPGRAPHFetch *adapter, NV2AMetalSurfaceCache *cache,
            const uint32_t values[3], BOOL strideZero, uint64_t mask)
{
    NSError *error = nil;
    require([cache prepareCPUAccessAtAddress:1024
                                      length:48
                                       write:YES
                                       error:&error],
            error);
    PGRAPHState *pg = &bfp_state->pgraph;
    memset(pg, 0, sizeof(*pg));
    pg->dma_vertex_a = 16;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 3;
    for (unsigned a = 0; a < 16; a++)
        pg->vertex_attributes[a].inline_value[3] = 1;
    pg->vertex_attributes[0].inline_value[0] = 1.5;
    pg->vertex_attributes[0].inline_value[1] = 1.5;
    pg->vertex_attributes[0].inline_value[2] = 8;
    pg->vertex_attributes[5].inline_value[1] = .25;
    pg->vertex_attributes[15] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = strideZero ? 0 : 16 };
    pg->vertex_attributes[15].inline_value[3] = 4096;
    for (unsigned i = 0; i < 3; i++) {
        float record[4] = { 0 };
        memcpy(record + 3, values + i, 4);
        memcpy(bfp_state->vram_ptr + 1024 + i * 16, record, 16);
    }
    NSArray *batches =
        strideZero ? [adapter encodeCurrentSnapshotsWithPrefixes:@[ @0 ]
                                                    indexedInput:nil
                                             deduplicateReadonly:NO
                                             proofAttributeLanes:mask
                                                           error:&error] :
                     [adapter encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
                                                        indexedInput:nil
                                                 deduplicateReadonly:NO
                                                 proofAttributeLanes:mask
                                                               error:&error];
    require(batches != nil, error);
    assert(batches.count == 1 &&
           pg->vertex_attributes[15].inline_value[3] == 4096);
    return batches;
}
static NV2AMetalWritableEncoding *
bfp_encode(NV2AMetalWritableProgram *engine, NV2AMetalCommands *commands,
           NV2AMetalValidatedProgram *program,
           const NV2AMetalProgramUniforms *u, NV2AMetalFetchResult *fetch,
           NV2AMetalFetchResult *proof, BOOL writer, unsigned access,
           NSUInteger first, NSUInteger count, NSError **error)
{
    bfp_selected = NO;
    bfp_active = YES;
    NV2AMetalWritableEncoding *result = [engine encodeProgram:program
                                                     uniforms:u
                                              attributeBuffer:fetch.attributes
                                                        first:first
                                                        count:count
                                                       access:access
                                                  writeEnable:writer
                                                    rasterize:YES
                                             compactRegisters:YES
                                               attributeFetch:proof
                                                     commands:commands
                                                        error:error];
    bfp_active = NO;
    if (result) {
        id<MTLBuffer> vertices = [result valueForKey:@"vertices"];
        memset(vertices.contents, 0xa5, vertices.length);
    }
    return result;
}
static void bfp_pair(NV2AMetalWritableProgram *engine,
                     NV2AMetalPGRAPHFetch *adapter,
                     NV2AMetalSurfaceCache *cache, unsigned test, BOOL writer)
{
    NSError *error = nil;
    uint32_t values[3] = { 0, 0x3f800000, 0x40000000 };
    if (test == 1)
        values[1] = 0x7fc12345;
    if (test == 2)
        values[2] = 0x447a0000;
    if (test == 3)
        values[0] = 0xbf800000;
    if (test == 4)
        values[0] = values[1] = values[2] = 0x71800000;
    if (test == 5) {
        values[0] = 0xbf800000;
        values[1] = 0;
        values[2] = 0x3f800000;
    }
    BOOL reciprocal = test == 4 || test == 5;
    NV2AMetalValidatedProgram *program = fpd_program(writer, reciprocal);
    NV2AMetalProgramUniforms u = uniforms();
    /* Raster colors pass through vp_color's [0,1] clamp. Keep the indexed
     * rows distinct within that interval instead of saturating row+1 to one. */
    for (unsigned row = 95; row <= 98; row++)
        u.constants[row][0] = (row - 94) / 8.f;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = bfp_capture(
        adapter, cache, values, NO, program.readonlyProofAttributeLanes64);
    NV2AMetalFetchResult *fetch = batches[0].fetch;
    NV2AMetalCommands *commands = adapter.encodingCommands;
    NSData *summary = nil;
    uint64_t mask = 0;
    assert([fetch getFloatProofSummaries:&summary
                                laneMask:&mask
                         attributeBuffer:fetch.attributes
                                   first:0
                                   count:3
                                commands:commands] &&
           summary.length == 1024 && mask == (UINT64_C(1) << 63));
    assert(![fetch getFloatProofSummaries:NULL
                                 laneMask:NULL
                          attributeBuffer:fetch.attributes
                                    first:0
                                    count:4
                                 commands:commands]);
    /* Seed a real old unknown result before receiving the bound domains. */
    NV2AMetalFetchUniforms source;
    assert([fetch getReadonlyProofUniforms:&source
                           attributeBuffer:fetch.attributes
                                     first:0
                                     count:3
                                  commands:commands]);
    assert(!fpd_query(program, writer, 0, &u, &source, nil, 0));
    unsigned access = test == 3 || test == 4 || test == 5;
    BOOL safe = test == 0 || test == 3 || test == 4;
    NV2AMetalWritableEncoding *results[3];
    BOOL pending[3], selected[3];
    for (unsigned trial = 0; trial < 3; trial++) {
        results[trial] =
            bfp_encode(engine, commands, program, &u, fetch,
                       trial == 2 ? nil : fetch, writer, access, 0, 3, &error);
        require(results[trial] != nil, error);
        pending[trial] =
            [results[trial] canUsePendingReadOnlyResultForCommands:commands];
        selected[trial] = bfp_selected;
    }
    require([adapter completeWithError:&error], error);
    independent_compare(results[0], results[2]);
    independent_compare(results[1], results[2]);
    const NV2AMetalProgramInput *decoded = fetch.attributes.contents;
    for (unsigned i = 0; i < 3; i++)
        assert(!memcmp(decoded[i].attributes[15] + 3, values + i, 4));
    assert(decoded[0].attributes[15][3] != 4096 &&
           bfp_state->pgraph.vertex_attributes[15].inline_value[3] != 4096);
    NSError *resolved = nil;
    NV2AMetalWritableResult *r = [results[0] resolveWithError:&resolved];
    assert(!!r == safe && !!resolved != safe);
    if (safe) {
        const NV2AMetalVertex *v = r.vertices.contents;
        for (unsigned i = 0; i < 3; i++) {
            unsigned row =
                test == 4 ? 96 : 96 + (int)decoded[i].attributes[15][3];
            assert(v[i].color[0][0] == u.constants[row][0]);
        }
    }
    for (unsigned trial = 0; trial < 3; trial++) {
        assert(pending[trial] == (!writer && safe && trial != 2));
        assert(selected[trial] == (writer && safe && trial != 2));
    }
    /* A finished receipt does not grant this metadata a new queue/recording.
     * Read the same real, completed GPU attributes on a fresh recording. */
    require([cache beginRecordingWithError:&error], error);
    NV2AMetalWritableEncoding *stale =
        bfp_encode(engine, cache.commands, program, &u, fetch, fetch, writer,
                   access, 0, 3, &error);
    require(stale != nil, error);
    BOOL stalePending =
        [stale canUsePendingReadOnlyResultForCommands:cache.commands];
    BOOL staleSelected = bfp_selected;
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    independent_compare(stale, results[2]);
    assert(!stalePending && !staleSelected);
}
static void bfp_stride_zero(NV2AMetalWritableProgram *engine,
                            NV2AMetalPGRAPHFetch *adapter,
                            NV2AMetalSurfaceCache *cache)
{
    NSError *error = nil;
    NV2AMetalValidatedProgram *program = fpd_program(NO, NO);
    NV2AMetalProgramUniforms u = uniforms();
    const uint32_t values[3] = { 0x3f800000, 0x3f800000, 0x3f800000 };
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = bfp_capture(
        adapter, cache, values, YES, program.readonlyProofAttributeLanes64);
    NV2AMetalFetchResult *fetch = batches[0].fetch;
    NV2AMetalCommands *commands = adapter.encodingCommands;
    assert(commands == cache.commands &&
           ![fetch getFloatProofSummaries:NULL
                                 laneMask:NULL
                          attributeBuffer:fetch.attributes
                                    first:0
                                    count:3
                                 commands:commands]);
    NV2AMetalWritableEncoding *a = bfp_encode(
        engine, commands, program, &u, fetch, fetch, NO, 0, 0, 3, &error);
    require(a != nil, error);
    BOOL pending = [a canUsePendingReadOnlyResultForCommands:commands];
    NV2AMetalWritableEncoding *b = bfp_encode(engine, commands, program, &u,
                                              fetch, nil, NO, 0, 0, 3, &error);
    require(b != nil, error);
    require([adapter completeCurrentSnapshotsWithError:&error], error);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    independent_compare(a, b);
    const NV2AMetalProgramInput *decoded = fetch.attributes.contents;
    for (unsigned i = 0; i < 3; i++)
        assert(decoded[i].attributes[15][3] == 1);
    assert(bfp_state->pgraph.vertex_attributes[15].inline_value[3] == 1 &&
           pending);
}
static void bound_float_proof_tests(NV2AMetalWritableProgram *engine,
                                    NV2AMetalCommands *commands)
{
    assert(!bfp_state);
    NSError *error = nil;
    id<MTLBuffer> vram =
        [commands.device newBufferWithLength:65536
                                     options:MTLResourceStorageModeShared];
    assert(vram);
    bfp_state = calloc(1, sizeof(*bfp_state));
    assert(bfp_state);
    bfp_state->vram = calloc(1, sizeof(*bfp_state->vram));
    assert(bfp_state->vram);
    bfp_state->vram_ptr = vram.contents;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    NV2AMetalPGRAPHFetch *adapter =
        [[NV2AMetalPGRAPHFetch alloc] initWithState:bfp_state
                                           surfaces:cache
                                              error:&error];
    require(adapter != nil, error);
    Method pipeline =
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:));
    assert(pipeline);
    bfp_pipeline_original = (void *)method_getImplementation(pipeline);
    method_setImplementation(pipeline, (IMP)bfp_pipeline);
    @try {
        for (unsigned writer = 0; writer < 2; writer++)
            for (unsigned test = 0; test < 6; test++)
                @autoreleasepool {
                    bfp_pair(engine, adapter, cache, test, writer);
                }
        NV2AMetalValidatedProgram *program = fpd_program(NO, NO);
        NV2AMetalProgramUniforms u = uniforms();
        const uint32_t values[3] = { 0, 0, 0 };
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = bfp_capture(
            adapter, cache, values, NO, program.readonlyProofAttributeLanes64);
        bfp_failure = [NSError errorWithDomain:@"test.bound-float.pipeline"
                                          code:1
                                      userInfo:nil];
        bfp_fail_pipeline = YES;
        assert(!bfp_encode(engine, adapter.encodingCommands, program, &u,
                           batches[0].fetch, batches[0].fetch, NO, 0, 0, 3,
                           &error) &&
               error == bfp_failure && !bfp_fail_pipeline &&
               bfp_state->pgraph.vertex_attributes[15].inline_value[3] == 4096);
        NV2AMetalFetchResult *cancelled = batches[0].fetch;
        [adapter cancel];
        error = nil;
        batches = bfp_capture(adapter, cache, values, NO,
                              program.readonlyProofAttributeLanes64);
        NV2AMetalCommands *retryCommands = adapter.encodingCommands;
        NV2AMetalWritableEncoding *retried[3];
        BOOL pending[3];
        for (unsigned trial = 0; trial < 3; trial++) {
            NV2AMetalFetchResult *proof = trial == 0 ? batches[0].fetch :
                                          trial == 1 ? cancelled :
                                                       nil;
            retried[trial] =
                bfp_encode(engine, retryCommands, program, &u, batches[0].fetch,
                           proof, NO, 0, 0, 3, &error);
            require(retried[trial] != nil, error);
            pending[trial] = [retried[trial]
                canUsePendingReadOnlyResultForCommands:retryCommands];
        }
        require([adapter completeWithError:&error], error);
        independent_compare(retried[0], retried[2]);
        independent_compare(retried[1], retried[2]);
        assert(pending[0] && !pending[1] && !pending[2]);
        bfp_stride_zero(engine, adapter, cache);
    } @finally {
        bfp_active = bfp_fail_pipeline = NO;
        bfp_failure = nil;
        method_setImplementation(pipeline, (IMP)bfp_pipeline_original);
        [adapter close];
    }
    require([cache waitUntilIdleWithError:&error], error);
    adapter = nil;
    cache = nil;
    free(bfp_state->vram);
    free(bfp_state);
    bfp_state = NULL;
    puts(
        "Bound Float proof:12 guarded DMA readonly/writer cold/warm/generic "
        "triples, exact GPU input/output/fault/context bytes, stale recording, "
        "range, unknown-cache transitions, guarded stride-zero Current and "
        "pipeline cancel/retry PASS");
}
#endif
