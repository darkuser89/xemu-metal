/* Unique proof words do not reduce indexed Fetch or writer executions.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEXED_FLOAT_PROOF_H
#define TEST_METAL_INDEXED_FLOAT_PROOF_H
#import "hw/xbox/nv2a/pgraph/metal/pending-journal.h"

@interface NV2AMetalPGRAPHFetch (IndexedFloatProofTest)
- (NSData *)scanFloatProofSources:(const NV2AMetalAttributeSource *)sources
                          indices:(const uint32_t *)indices
                            first:(NSUInteger)first
                            count:(NSUInteger)count
                            lanes:(uint64_t)lanes;
@end
typedef struct IndexedFloatWork {
    BOOL selected, chained, pending;
    NSUInteger scans, words, dispatches, width;
    MTLSize threads, group;
} IndexedFloatWork;
static _Thread_local IndexedFloatWork *ifp_work;
static BOOL ifp_scan_scope;
static id (*ifp_scan_original)(id, SEL, const NV2AMetalAttributeSource *,
                               const uint32_t *, NSUInteger, NSUInteger,
                               uint64_t);
static id ifp_scan(id object, SEL selector,
                   const NV2AMetalAttributeSource *sources,
                   const uint32_t *indices, NSUInteger first, NSUInteger count,
                   uint64_t lanes)
{
    if (ifp_work && ifp_scan_scope) {
        ifp_work->scans++;
        ifp_work->words += count * __builtin_popcountll(lanes);
    }
    return ifp_scan_original(object, selector, sources, indices, first, count,
                             lanes);
}
static id (*ifp_pipeline_original)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL,
                                   NSError **);
static id ifp_pipeline(id object, SEL selector, BOOL write, BOOL compact,
                       BOOL discard, BOOL chained, BOOL independent,
                       NSError **error)
{
    id<MTLComputePipelineState> pipeline = ifp_pipeline_original(
        object, selector, write, compact, discard, chained, independent, error);
    if (ifp_work && pipeline) {
        ifp_work->selected = independent;
        ifp_work->chained = chained;
        ifp_work->width = pipeline.threadExecutionWidth;
        ifp_work->pending = YES;
    }
    return pipeline;
}
static void (*ifp_dispatch_original)(id, SEL, MTLSize, MTLSize);
static void ifp_dispatch(id object, SEL selector, MTLSize threads,
                         MTLSize group)
{
    if (ifp_work && ifp_work->pending) {
        ifp_work->dispatches++;
        ifp_work->threads = threads;
        ifp_work->group = group;
        ifp_work->pending = NO;
    }
    ifp_dispatch_original(object, selector, threads, group);
}
static NV2AMetalValidatedProgram *ifp_program(void)
{
    Token t[4];
    t[0] = token(NV2AMetalMACMov, 0, 0);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    t[1] = token(NV2AMetalMACArl, 0, 0);
    t[1].word[1] |= 15u << 9;
    source(t + 1, 0, 2, 0, 0);
    t[2] = token(NV2AMetalMACMov, 0, 96);
    source(t + 2, 0, 3, 0, 0);
    destination(t + 2, 0x103, 8, 0, 0, 0, 0);
    t[2].word[3] |= 2;
    t[3] = token(NV2AMetalMACMov, 0, 0);
    t[3].word[1] |= 5u << 9;
    source(t + 3, 0, 2, 0, 0);
    destination(t + 3, 150, 8, 0, 0, 0, 0);
    t[3].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *p =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:4
                                                    error:&error];
    require(p != nil, error);
    assert(p.readonlyProofAttributeLanes64 == (UINT64_C(1) << 60));
    return p;
}
static NV2AMetalPendingInput *ifp_scene(NV2AMetalSurfaceCache *cache,
                                        unsigned test, NSUInteger *prefix)
{
    NSError *error = nil;
    require([cache prepareCPUAccessAtAddress:0
                                      length:65536
                                       write:YES
                                       error:&error],
            error);
    PGRAPHState *pg = &bfp_state->pgraph;
    memset(pg, 0, sizeof(*pg));
    pg->dma_vertex_a = 16;
    for (unsigned a = 0; a < 16; a++)
        pg->vertex_attributes[a].inline_value[3] = 1;
    pg->vertex_attributes[0].inline_value[0] = 1.5f;
    pg->vertex_attributes[0].inline_value[1] = 1.5f;
    pg->vertex_attributes[0].inline_value[2] = 8;
    pg->vertex_attributes[15] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .count = 1,
                           .size = 4,
                           .stride = 4 };
    pg->vertex_attributes[15].inline_value[0] = 4096;
    pg->vertex_attributes[5] = pg->vertex_attributes[15];
    pg->vertex_attributes[5].offset = 32768 - 1024;
    pg->vertex_attributes[5].inline_value[0] = 4096;
    unsigned unique = test == 5 ? 4096 : test == 6 ? 4097 : 32;
    unsigned sources = MAX(unique, 64u);
    for (unsigned i = 0; i < sources; i++) {
        float address = i & 1;
        if ((test == 3 || test == 4) && i == 7)
            address = -1;
        if ((test == 1 && i == 63) || (test == 2 && i == 5))
            address = NAN;
        float store = (i + 1) / 8192.f;
        memcpy(bfp_state->vram_ptr + 1024 + i * 4, &address, 4);
        memcpy(bfp_state->vram_ptr + 32768 + i * 4, &store, 4);
    }
    const unsigned count = 8192;
    assert(count <= G_N_ELEMENTS(pg->inline_elements));
    pg->inline_elements_length = count;
    for (unsigned i = 0; i < count; i++)
        pg->inline_elements[i] = (i * 13u) % unique;
    /* The last execution is deliberately not the last first-occurrence
     * unique. A hidden XF reduction would change the final GPU store. */
    pg->inline_elements[count - 1] = 7;
    *prefix = test == 1 ? 2048 : 0;
    if (*prefix)
        pg->inline_elements[0] = 63; // NaN belongs only to an accepted prefix.
    NV2AMetalPendingInput *input =
        [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                      count:count
                           matchingPrevious:nil];
    assert(input && input.count == count && input.maximumIndex < sources &&
           1024 + (NSUInteger)(input.maximumIndex + 1) * 4 <= 65536 &&
           32768 + (NSUInteger)(input.maximumIndex + 1) * 4 <= 65536);
    return input;
}
static NV2AMetalPGRAPHFetchBatch *ifp_capture(NV2AMetalPGRAPHFetch *adapter,
                                              NV2AMetalPendingInput *input,
                                              NSUInteger prefix, BOOL reference)
{
    NSError *error = nil;
    NSArray *batches;
    ifp_scan_scope = YES;
    @try {
        batches =
            reference ?
                [adapter encodeIndependentSnapshotsWithPrefixes:@[ @(prefix) ]
                                                   indexedInput:input
                                            deduplicateReadonly:NO
                                                          error:&error] :
                [adapter
                    encodeIndependentSnapshotsWithPrefixes:@[ @(prefix) ]
                                              indexedInput:input
                                       deduplicateReadonly:NO
                                       proofAttributeLanes:UINT64_C(1) << 60
                                                     error:&error];
    } @finally {
        ifp_scan_scope = NO;
    }
    require(batches != nil, error);
    assert(batches.count == 1);
    return batches[0];
}
static NV2AMetalWritableEncoding *
ifp_encode(NV2AMetalWritableProgram *engine, NV2AMetalCommands *q,
           NV2AMetalValidatedProgram *program,
           const NV2AMetalProgramUniforms *u, NV2AMetalFetchResult *fetch,
           NV2AMetalFetchResult *proof, NSUInteger count, unsigned access)
{
    NSError *error = nil;
    NV2AMetalWritableEncoding *encoded = [engine encodeProgram:program
                                                      uniforms:u
                                               attributeBuffer:fetch.attributes
                                                         first:0
                                                         count:count
                                                        access:access
                                                   writeEnable:YES
                                                     rasterize:YES
                                              compactRegisters:YES
                                                attributeFetch:proof
                                                      commands:q
                                                         error:&error];
    require(encoded != nil, error);
    id<MTLBuffer> vertices = [encoded valueForKey:@"vertices"];
    memset(vertices.contents, 0xa5, vertices.length);
    return encoded;
}
static NSData *ifp_run(NV2AMetalWritableProgram *engine,
                       NV2AMetalPGRAPHFetch *adapter,
                       NV2AMetalSurfaceCache *cache, unsigned test,
                       BOOL reference)
{
    NSError *error = nil;
    NSUInteger prefix;
    NV2AMetalPendingInput *input = ifp_scene(cache, test, &prefix);
    const uint32_t *indices = input.indices.bytes;
    NSUInteger count = input.count - prefix;
    unsigned access = test == 1 || test == 2 || test == 4;
    BOOL safe = test != 2 && test != 3 && test != 8;
    NV2AMetalValidatedProgram *program = ifp_program();
    NV2AMetalProgramUniforms u = uniforms();
    for (unsigned row = 95; row <= 97; row++)
        u.constants[row][0] = (row - 94) / 8.f;
    id<MTLSharedEvent> gate = nil;
    if (test == 8) {
        // A real pending GPU writer invalidates every host summary of word0.
        require([cache prepareGPUWriteAtAddress:1024 length:4 error:&error],
                error);
        gate = [cache.commands.device newSharedEvent];
        assert(gate);
        [((id<MTL4CommandQueue>)[cache.commands
            valueForKey:@"queue"]) waitForEvent:gate value:1];
        uint32_t nan = UINT32_C(0x7fc12345);
        id<MTLBuffer> source = [cache.commands.device
            newBufferWithBytes:&nan
                        length:4
                       options:MTLResourceStorageModeShared];
        require(source && [cache.commands addResource:source error:&error],
                error);
        id<MTL4ComputeCommandEncoder> e =
            [cache.commands.commandBuffer computeCommandEncoder];
        assert(e);
        [e copyFromBuffer:source
                 sourceOffset:0
                     toBuffer:cache.vram
            destinationOffset:1024
                         size:4];
        [e endEncoding];
        require([cache submitWithError:&error], error);
        id<MTLSharedEvent> watchdog = gate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!watchdog.signaledValue)
                             watchdog.signaledValue = 2;
                       });
    }
    IndexedFloatWork work = { 0 };
    ifp_work = &work;
    NV2AMetalPGRAPHFetchBatch *batch =
        ifp_capture(adapter, input, prefix, reference);
    NV2AMetalFetchResult *stale = nil;
    if (test == 7) {
        stale = batch.fetch;
        (void)ifp_encode(engine, adapter.encodingCommands, program, &u,
                         batch.fetch, batch.fetch, count, access);
        [adapter cancel];
        memset(&work, 0, sizeof(work));
        batch = ifp_capture(adapter, input, prefix, reference);
    }
    NV2AMetalCommands *q = adapter.encodingCommands;
    NSData *summary = nil;
    uint64_t mask = 0;
    BOOL summarized = [batch.fetch getFloatProofSummaries:&summary
                                                 laneMask:&mask
                                          attributeBuffer:batch.fetch.attributes
                                                    first:0
                                                    count:count
                                                 commands:q];
    BOOL reduced = batch.remap != nil;
    NSUInteger physical = batch.physicalVertexCount,
               decoded = batch.fetch.vertexCount;
    NV2AMetalWritableEncoding *encoded = ifp_encode(
        engine, q, program, &u, batch.fetch, batch.fetch, count, access);
    BOOL pending = [encoded canUsePendingReadOnlyResultForCommands:q];
    IndexedFloatWork primary = work;
    IndexedFloatWork staleWork = { 0 };
    NV2AMetalWritableEncoding *rejected = nil;
    if (stale) {
        ifp_work = &staleWork;
        rejected = ifp_encode(engine, q, program, &u, batch.fetch, stale, count,
                              access);
    }
    ifp_work = NULL;
    if (gate) {
        assert(!gate.signaledValue && !primary.scans && !primary.words);
        gate.signaledValue = 1;
    }
    require([adapter completeWithError:&error], error);
    id<MTLBuffer> contextBuffer = [encoded valueForKey:@"context"];
    id<MTLBuffer> vertexBuffer = [encoded valueForKey:@"vertices"];
    const NV2AMetalWritableContext *context = contextBuffer.contents;
    const NV2AMetalVertex *vertices = vertexBuffer.contents;
    const NV2AMetalProgramInput *fetched = batch.fetch.attributes.contents;
    unsigned expectedFault = test == 2 || test == 8 ?
                                 NV2AMetalProgramFaultAddressRange :
                             test == 3 ? NV2AMetalProgramFaultConstantRange :
                                         0;
    assert(context->fault == expectedFault);
    NSUInteger firstFault = count;
    for (NSUInteger i = 0; i < count; i++) {
        uint32_t index = indices[prefix + i];
        float address;
        memcpy(&address, bfp_state->vram_ptr + 1024 + index * 4, 4);
        float store = (index + 1) / 8192.f;
        assert(!memcmp(fetched[i].attributes[15], &address, 4) &&
               fetched[i].attributes[5][0] == store);
        BOOL fault = !isfinite(address) || (!access && address < 0);
        if (fault && firstFault == count)
            firstFault = i;
        if (i < firstFault) {
            unsigned row = 96 + (int)address;
            assert(vertices[i].color[0][0] == u.constants[row][0]);
        } else if (i == firstFault) {
            NV2AMetalVertex zero = { 0 };
            assert(!memcmp(vertices + i, &zero, sizeof(zero)));
        } else {
            const uint8_t *bytes = (const uint8_t *)(vertices + i);
            for (NSUInteger b = 0; b < sizeof(*vertices); b++)
                assert(bytes[b] == 0xa5);
        }
    }
    assert((firstFault == count) == safe);
    if (safe) {
        assert(context->constants[150][0] == 8 / 8192.f &&
               context->dirty[150] == 1);
    }
    assert(bfp_state->pgraph.vertex_attributes[15].inline_value[0] ==
               fetched[count - 1].attributes[15][0] &&
           bfp_state->pgraph.vertex_attributes[5].inline_value[0] ==
               8 / 8192.f);
    if (rejected)
        independent_compare(encoded, rejected);
    NSError *fault = nil;
    NV2AMetalWritableResult *result = [encoded resolveWithError:&fault];
    assert(!!result == safe && !!fault != safe);
    NSMutableData *bytes =
        [NSMutableData dataWithBytes:vertexBuffer.contents
                              length:count * sizeof(*vertices)];
    [bytes appendBytes:context length:sizeof(*context)];
    for (unsigned a = 0; a < 16; a++)
        [bytes appendBytes:bfp_state->pgraph.vertex_attributes[a].inline_value
                    length:16];
    /* Execution and work checks come after actual GPU output/context/Current.
     * The reference uses the unmodified mask-zero capture/serial interpreter.
     */
    BOOL proof = !reference && test != 6 && test != 8;
    BOOL parallel = proof && safe;
    assert(!reduced && physical == count && decoded == count && !pending);
    assert(summarized == proof &&
           (proof ? summary.length == 1024 && mask == (UINT64_C(1) << 60) :
                    !summary && !mask));
    assert(primary.scans == (proof ? 1u : 0u));
    assert(primary.words == (proof ? test == 5 ? 4096u : 32u : 0u));
    assert(primary.dispatches == 1 && !primary.pending && !primary.chained &&
           primary.selected == parallel);
    assert(primary.threads.width == (parallel ? count : 1u) &&
           primary.threads.height == 1 && primary.threads.depth == 1 &&
           primary.group.width == (parallel ? MIN(count, primary.width) : 1u));
    if (rejected)
        assert(!staleWork.selected && staleWork.dispatches == 1 &&
               staleWork.threads.width == 1);
    if (gate)
        assert(gate.signaledValue == 1);
    return bytes;
}
static void indexed_float_proof_tests(NV2AMetalWritableProgram *engine,
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
    require([commands beginWithError:&error] != nil, error);
    id encoder = [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(scanFloatProofSources:indices:first:count:lanes:)),
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:))
    };
    [encoder endEncoding];
    [commands cancel];
    IMP replacements[] = { (IMP)ifp_scan, (IMP)ifp_pipeline,
                           (IMP)ifp_dispatch },
        originals[3];
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    ifp_scan_original = (void *)originals[0];
    ifp_pipeline_original = (void *)originals[1];
    ifp_dispatch_original = (void *)originals[2];
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned test = 0; test < 9; test++)
            @autoreleasepool {
                NSData *reference = ifp_run(engine, adapter, cache, test, YES);
                NSData *actual = ifp_run(engine, adapter, cache, test, NO);
                assert([reference isEqualToData:actual]);
            }
    } @finally {
        ifp_work = NULL;
        ifp_scan_scope = NO;
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
        [adapter close];
    }
    require([cache waitUntilIdleWithError:&error], error);
    adapter = nil;
    cache = nil;
    free(bfp_state->vram);
    free(bfp_state);
    bfp_state = NULL;
    puts("Indexed Float proof:9 native8192-execution writer/generic pairs; "
         "32-source unique scan,4096/4097 valid unique bounds,prefix/NaN hole, "
         "USER/FULL,late fault bytes,Current/final stores,stale/cancel retry "
         "and "
         "gated GPU-source0scan; no XF/Fetch execution deduplication PASS");
}
#endif
