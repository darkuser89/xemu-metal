/* Memoized evidence must retain the original guarded scan's exact results.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FLOAT_SUMMARY_MEMO_H
#define TEST_METAL_FLOAT_SUMMARY_MEMO_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-program.h"

@interface NV2AMetalPGRAPHFetch (FloatSummaryMemoTest)
- (BOOL)reuseFloatProofForBatches:(NSArray *)batches
                          sources:(const NV2AMetalAttributeSource *)sources
                        indexData:(NSData *)data
                      indexOffset:(NSUInteger)offset
                            first:(NSUInteger)first
                           arrays:(BOOL)arrays
                            lanes:(uint64_t)lanes;
- (NSData *)floatProofKeyForBatches:(NSArray *)batches
                            sources:(const NV2AMetalAttributeSource *)sources
                          indexData:(NSData *)data
                        indexOffset:(NSUInteger)offset
                              first:(NSUInteger)first
                             arrays:(BOOL)arrays
                              lanes:(uint64_t)lanes;
@end
static _Thread_local BOOL fsm_scope, fsm_reference, fsm_nil_key,
    fsm_reject_resource, fsm_nil_summary, fsm_in_scan;
static _Thread_local __unsafe_unretained NV2AMetalSurfaceCache *fsm_cache;
static _Thread_local NSUInteger fsm_scans, fsm_words, fsm_hits, fsm_guards,
    fsm_versions, fsm_keys;
static BOOL (*fsm_reuse_original)(id, SEL, NSArray *,
                                  const NV2AMetalAttributeSource *, NSData *,
                                  NSUInteger, NSUInteger, BOOL, uint64_t);
static BOOL fsm_reuse(id owner, SEL selector, NSArray *batches,
                      const NV2AMetalAttributeSource *sources, NSData *data,
                      NSUInteger offset, NSUInteger first, BOOL arrays,
                      uint64_t lanes)
{
    if (fsm_scope && fsm_reference)
        return NO; /* Only bypass the new memo, not capture or qualification. */
    BOOL hit = fsm_reuse_original(owner, selector, batches, sources, data,
                                  offset, first, arrays, lanes);
    if (fsm_scope)
        fsm_hits += hit;
    return hit;
}
static NSData *(*fsm_key_original)(id, SEL, NSArray *,
                                   const NV2AMetalAttributeSource *, NSData *,
                                   NSUInteger, NSUInteger, BOOL, uint64_t);
static NSData *fsm_key(id owner, SEL selector, NSArray *batches,
                       const NV2AMetalAttributeSource *sources, NSData *data,
                       NSUInteger offset, NSUInteger first, BOOL arrays,
                       uint64_t lanes)
{
    if (fsm_scope) {
        fsm_keys++;
        if (fsm_nil_key)
            return nil;
    }
    return fsm_key_original(owner, selector, batches, sources, data, offset,
                            first, arrays, lanes);
}
static NSData *(*fsm_scan_original)(id, SEL, const NV2AMetalAttributeSource *,
                                    const uint32_t *, NSUInteger, NSUInteger,
                                    uint64_t);
static NSData *fsm_scan(id owner, SEL selector,
                        const NV2AMetalAttributeSource *sources,
                        const uint32_t *indices, NSUInteger first,
                        NSUInteger count, uint64_t lanes)
{
    if (fsm_scope) {
        fsm_scans++;
        fsm_words += count * __builtin_popcountll(lanes);
    }
    BOOL previous = fsm_in_scan;
    fsm_in_scan = fsm_scope;
    @try {
        return fsm_scan_original(owner, selector, sources, indices, first,
                                 count, lanes);
    } @finally {
        fsm_in_scan = previous;
    }
}
static BOOL (*fsm_guard_original)(id, SEL, const NV2AMetalVRAMReadSpan *,
                                  NSUInteger, BOOL *, NSError **);
static BOOL fsm_guard(id owner, SEL selector,
                      const NV2AMetalVRAMReadSpan *spans, NSUInteger count,
                      BOOL *ready, NSError **error)
{
    if (fsm_scope && owner == fsm_cache)
        fsm_guards++;
    return fsm_guard_original(owner, selector, spans, count, ready, error);
}
static BOOL (*fsm_version_original)(id, SEL, const NV2AMetalVRAMReadSpan *,
                                    NSUInteger, uint64_t *, NSError **);
static BOOL fsm_version(id owner, SEL selector,
                        const NV2AMetalVRAMReadSpan *spans, NSUInteger count,
                        uint64_t *version, NSError **error)
{
    if (fsm_scope && owner == fsm_cache)
        fsm_versions++;
    return fsm_version_original(owner, selector, spans, count, version, error);
}
static BOOL (*fsm_resource_original)(id, SEL, id<MTLResource>, NSError **);
static BOOL fsm_resource(id owner, SEL selector, id<MTLResource> resource,
                         NSError **error)
{
    if (fsm_reject_resource && owner == fsm_cache.commands &&
        resource == fsm_cache.vram) {
        fsm_reject_resource = NO;
        if (error)
            *error = [NSError errorWithDomain:@"fsm.resource"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return fsm_resource_original(owner, selector, resource, error);
}

static NSData *(*fsm_data_original)(id, SEL, const void *, NSUInteger);
static NSData *fsm_data(id owner, SEL selector, const void *bytes,
                        NSUInteger length)
{
    if (fsm_in_scan && fsm_nil_summary && length == 1024)
        return nil; /* Actual scanner's immutable result allocation fails. */
    return fsm_data_original(owner, selector, bytes, length);
}

typedef struct FloatSummaryMemoWork {
    NSUInteger scans, words, hits, guards, versions, keys;
} FloatSummaryMemoWork;
static uint32_t fsm_bits(unsigned row, unsigned lane)
{
    const uint32_t bits[] = { UINT32_C(0xbf800000), 0, UINT32_C(0x3f800000),
                              UINT32_C(0x40000000) };
    return bits[(row + lane) % 4];
}
static void fsm_seed(FloatProofCaptureFixture *f, unsigned rows,
                     unsigned stride, unsigned components)
{
    NSError *error = nil;
    NSUInteger length = (rows - 1) * stride + components * 4;
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:length
                                         write:YES
                                         error:&error],
            error);
    for (unsigned row = 0; row < rows; row++)
        for (unsigned lane = 0; lane < components; lane++) {
            uint32_t bits = fsm_bits(row, lane);
            memcpy(state->vram_ptr + 4096 + row * stride + lane * 4, &bits, 4);
        }
}
static void fsm_raw_write(FloatProofCaptureFixture *f, NSUInteger address,
                          uint32_t bits, BOOL cancel, BOOL blit)
{
    NSError *error = nil;
    uint64_t before = f.cache.gpuWriteEpoch;
    if (blit) {
        require([f.cache prepareCPUAccessAtAddress:32768
                                            length:4
                                             write:YES
                                             error:&error],
                error);
        memcpy(state->vram_ptr + 32768, &bits, 4);
        require([f.cache prepareGPUBlitFrom:NSMakeRange(32768, 4)
                                         to:NSMakeRange(address, 4)
                           replacingSurface:^BOOL(NV2AMetalCachedSurface *s) {
                             (void)s;
                             return NO;
                           }
                                      error:&error],
                error);
    } else {
        require([f.cache prepareGPUWriteAtAddress:address
                                           length:4
                                            error:&error],
                error);
    }
    assert(f.cache.gpuWriteEpoch ==
           (before == UINT64_MAX ? before : before + 1));
    id<MTLBuffer> source =
        blit ? f.cache.vram :
               [f.queue.device newBufferWithBytes:&bits
                                           length:4
                                          options:MTLResourceStorageModeShared];
    require(source && [f.queue addResource:source error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [f.queue.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:blit ? 32768 : 0
                 toBuffer:f.cache.vram
        destinationOffset:address
                     size:4];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    if (cancel)
        [f.cache cancel];
    else
        require([f.cache submitWithError:&error] &&
                    [f.cache waitUntilIdleWithError:&error],
                error);
    /* No noticeTextureDirty and NO intervening capture: the epoch itself
     * must prevent reuse after this completed, real raw GPU write. */
    assert(f.cache.gpuWriteEpoch ==
           (before == UINT64_MAX ? before : before + 1));
    if (!cancel)
        assert(!memcmp(state->vram_ptr + address, &bits, 4));
}
static NSData *fsm_capture(FloatProofCaptureFixture *f,
                           NV2AMetalVertexProgram *xf,
                           NV2AMetalPendingInput *input, NSArray *prefixes,
                           BOOL host, BOOL dedup, uint64_t lanes,
                           FloatSummaryMemoWork *work)
{
    NSError *error = nil;
    fsm_scans = fsm_words = fsm_hits = fsm_guards = fsm_versions = fsm_keys = 0;
    fsm_scope = YES;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches;
    @try {
        batches = fpc_encode(f, input, prefixes, host, dedup, lanes, NO);
    } @finally {
        fsm_scope = NO;
    }
    *work = (FloatSummaryMemoWork){ fsm_scans,  fsm_words,    fsm_hits,
                                    fsm_guards, fsm_versions, fsm_keys };
    NSMutableData *bytes = [NSMutableData new];
    NSMutableArray<NV2AMetalProgramResult *> *outputs = [NSMutableArray new];
    NV2AMetalCommands *queue = f.fetch.encodingCommands;
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        NSData *summary = nil;
        uint64_t mask = 0;
        BOOL found =
            [batch.fetch getFloatProofSummaries:&summary
                                       laneMask:&mask
                                attributeBuffer:batch.fetch.attributes
                                          first:0
                                          count:batch.physicalVertexCount
                                       commands:queue];
        [bytes appendBytes:&found length:sizeof(found)];
        [bytes appendBytes:&mask length:sizeof(mask)];
        if (summary) {
            assert(summary.length == 1024 &&
                   ![summary isKindOfClass:NSMutableData.class]);
            [bytes appendData:summary];
        }
        if (!batch.fetch.vertexCount) {
            [outputs addObject:(id)NSNull.null];
            continue;
        }
        uint32_t tokens[2][4] = { 0 };
        /* Raw texture output preserves NaN/signed-zero lanes; oPos is safe. */
        tokens[0][1] = 1 << 21 | 27;
        tokens[0][2] = 2u << 26;
        tokens[0][3] = 1 << 11 | 9 << 3 | 15 << 12;
        tokens[1][1] = 1 << 21 | 96 << 13 | 27;
        tokens[1][2] = 3u << 26;
        tokens[1][3] = 1 << 11 | 15 << 12 | 1;
        NV2AMetalProgramUniforms u = { 0 };
        u.constants[96][3] = 1;
        u.surface_size[0] = u.surface_size[1] = 8;
        u.zmax = 65535;
        u.point_size = u.point_scale = 1;
        NV2AMetalProgramResult *result =
            [xf encodeTokens:&tokens[0][0]
                      length:2
                    uniforms:&u
                  attributes:batch.fetch.attributes
                       count:batch.fetch.vertexCount
                    commands:queue
                       error:&error];
        require(result != nil, error);
        [outputs addObject:result];
    }
    /* This waits actual Fetch/XF feedback, checks faults, and publishes
     * Current. */
    [bytes appendData:fpc_output(f, batches)];
    for (NSUInteger b = 0; b < batches.count; b++) {
        NV2AMetalPGRAPHFetchBatch *batch = batches[b];
        if (!batch.fetch.vertexCount)
            continue;
        NV2AMetalProgramResult *result = outputs[b];
        const NV2AMetalProgramOutput *raw = result.registers.contents;
        const NV2AMetalProgramInput *attributes =
            batch.fetch.attributes.contents;
        for (NSUInteger i = 0; i < result.vertexCount; i++) {
            assert(!raw[i].fault && !memcmp(raw[i].registers[9],
                                            attributes[i].attributes[0], 16));
        }
        [bytes appendBytes:result.registers.contents
                    length:result.vertexCount * sizeof(NV2AMetalProgramOutput)];
        [bytes appendBytes:result.vertices.contents
                    length:result.vertexCount * sizeof(NV2AMetalVertex)];
        /* Reconstruct the logical source through the public remap, not a
         * copy of the deduplication implementation. Every GPU row is checked.
         */
        const uint32_t *order = input.indices.bytes;
        const uint32_t *remap = batch.remap.bytes;
        for (NSUInteger i = 0;
             i < batch.inputVertexCount - batch.firstDecodedVertex; i++) {
            NSUInteger physical = remap ? remap[i] : i;
            NSUInteger index =
                input ? order[batch.firstDecodedVertex + i] :
                        batch.firstVertex + batch.firstDecodedVertex + i;
            assert(physical < batch.fetch.vertexCount);
            const VertexAttribute *source = &state->pgraph.vertex_attributes[0];
            for (unsigned lane = 0; lane < source->count; lane++)
                assert(!memcmp(attributes[physical].attributes[0] + lane,
                               state->vram_ptr + dma_a.address +
                                   source->offset + index * source->stride +
                                   lane * 4,
                               4));
        }
    }
    return bytes;
}

/* Thirteen bounded scenarios, each retaining one controller across real GPU
 * completions. Reference NO executes the old scanner on that same sequence. */
static NSArray<NSData *> *fsm_run(unsigned profile, BOOL reference,
                                  NSMutableData *workBytes)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    fsm_cache = f.cache;
    fsm_reference = reference;
    NSError *error = nil;
    NV2AMetalVertexProgram *xf =
        [[NV2AMetalVertexProgram alloc] initWithDevice:f.queue.device
                                                 error:&error];
    require(xf != nil, error);
    unsigned rows = profile == 5 ? 4096 : profile == 6 ? 4097 : 64;
    unsigned components = profile == 5 || profile == 6 ? 1 : 4;
    unsigned stride = profile == 5 ? 8 : components * 4;
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .offset = 4096,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = components,
                           .stride = stride };
    fsm_seed(f, rows, stride, components);
    uint64_t sequenceVersion = 0;
    if (profile == 1 || profile == 2) {
        /* The original scanner stops at NaN. Rotation changes its concrete
         * min/max prefix bytes even though the source word set is identical.
         * No source write occurs between cold, same-order warm, and rotation.
         */
        unsigned row = profile == 1 ? 26 : 2;
        NSUInteger address = 4096 + row * stride;
        uint32_t nan = UINT32_C(0x7fc12345);
        require([f.cache prepareCPUAccessAtAddress:address
                                            length:4
                                             write:YES
                                             error:&error],
                error);
        memcpy(state->vram_ptr + address, &nan, 4);
        require([f.cache sourceVersionAtAddress:4096
                                         length:rows * stride
                                        version:&sequenceVersion
                                          error:&error],
                error);
    }
    state->pgraph.draw_arrays_length = profile == 4 ? 2 : 1;
    state->pgraph.draw_arrays_count[0] = profile == 4                 ? 3 :
                                         profile == 5 || profile == 6 ? rows :
                                                                        8;
    state->pgraph.draw_arrays_start[1] = 8;
    state->pgraph.draw_arrays_count[1] = 3;
    NV2AMetalPendingInput *input = nil;
    if (profile >= 1 && profile <= 3) {
        NSUInteger count = profile == 3 ? 8192 : 8;
        NSMutableData *indices = [NSMutableData dataWithLength:count * 4];
        for (NSUInteger i = 0; i < count; i++)
            ((uint32_t *)indices.mutableBytes)[i] =
                (uint32_t)((i * 13) % (profile == 2 ? 4 : 32));
        input = rip_input(indices.bytes, count, nil);
        require(input != nil, nil);
    }
    if (profile == 10) {
        /* Explicitly simulated counter exhaustion, not naturally reached.
         * The following registrations, GPU writes and feedback are real. */
        [f.cache setValue:@(UINT64_MAX - 1) forKey:@"gpuWriteEpoch"];
    }
    NSMutableArray<NSData *> *outputs = [NSMutableArray new];
    unsigned steps =
        profile == 7                                                   ? 12 :
        profile == 8                                                   ? 6 :
        profile == 9                                                   ? 7 :
        profile == 1 || profile == 2 || profile == 11 || profile == 12 ? 4 :
                                                                         3;
    @try {
        for (unsigned step = 0; step < steps; step++) {
            NSUInteger prefix = 0;
            uint64_t lanes = 1;
            NSArray *prefixes = profile == 4 ? @[ @0, @0 ] : @[ @0 ];
            if ((profile == 1 || profile == 2) && step) {
                uint32_t order[8];
                memcpy(order, input.indices.bytes, sizeof(order));
                if (step == 2) {
                    uint32_t first = order[0];
                    memmove(order, order + 1, 7 * sizeof(*order));
                    order[7] =
                        first; /* Same set, new execution order/Current. */
                }
                input =
                    rip_input(order, 8, nil); /* New descriptor, exact bytes. */
                require(input != nil, nil);
            }
            if (profile == 1 || profile == 2) {
                uint64_t currentVersion = 0;
                require([f.cache sourceVersionAtAddress:4096
                                                 length:rows * stride
                                                version:&currentVersion
                                                  error:&error],
                        error);
                assert(currentVersion == sequenceVersion);
            }
            if (profile == 7 && step) {
                /* Same selected word set, but a different order/Current,
                 * mapping, stride, effective mask or decoded suffix. */
                if (step == 1)
                    state->pgraph.draw_arrays_start[0] = 1;
                if (step == 2)
                    state->pgraph.draw_arrays_count[0] = 7;
                if (step == 3)
                    state->pgraph.vertex_attributes[0].stride = 8;
                if (step == 4)
                    dma_a.address = 4;
                if (step >= 5)
                    lanes = 2;
                if (step >= 6)
                    prefix = 1;
                if (step >= 7)
                    lanes = 3;
                if (step == 8)
                    state->pgraph.vertex_attributes[0].count = 2;
                if (step >= 9)
                    state->pgraph.vertex_attributes[0].count = 1;
                if (step == 10)
                    state->pgraph.vertex_attributes[0].stride = 0;
                if (step == 11)
                    state->pgraph.vertex_attributes[0].stride = 4;
                prefixes = @[ @(prefix) ];
            }
            if (profile == 8 && step) {
                uint32_t bits = step <= 2 ? fsm_bits(0, 0) :
                                step == 3 ? UINT32_C(0x80000000) :
                                step == 4 ? UINT32_C(0x7fc12345) :
                                            UINT32_C(0x3f800000);
                if (step == 1) {
                    require([f.cache prepareCPUAccessAtAddress:4096
                                                        length:4
                                                         write:YES
                                                         error:&error],
                            error);
                } else {
                    /* A real fast pre-write callback and its actual store.
                     * The next version query must consume deferred dirty. */
                    assert(nv2a_metal_try_cpu_access(f.cache.cpuAccessGuard,
                                                     4096, 4, YES));
                }
                memcpy(state->vram_ptr + 4096, &bits, 4);
            }
            if (profile == 9 && step >= 2) {
                if (step == 2)
                    fsm_raw_write(f, 4096, UINT32_C(0x7fc12345), NO, NO);
                if (step == 3)
                    fsm_raw_write(f, 24576, UINT32_C(0x3f800000), NO, NO);
                if (step == 4)
                    fsm_raw_write(f, 4096, UINT32_C(0x3f000000), YES, NO);
                if (step == 5)
                    fsm_raw_write(f, 4096, UINT32_C(0x3f800000), NO, YES);
                if (step == 6) {
                    uint64_t epoch = f.cache.gpuWriteEpoch;
                    require([f.cache prepareGPUWriteAtAddress:4096
                                                       length:0
                                                        error:&error],
                            error);
                    assert(f.cache.gpuWriteEpoch == epoch);
                    [f.cache cancel];
                    error = nil;
                    assert(![f.cache prepareGPUWriteAtAddress:65536
                                                       length:4
                                                        error:&error] &&
                           f.cache.gpuWriteEpoch == epoch);
                    error = nil;
                    fsm_reject_resource = YES;
                    assert(![f.cache prepareGPUWriteAtAddress:4096
                                                       length:4
                                                        error:&error] &&
                           !fsm_reject_resource &&
                           f.cache.gpuWriteEpoch == epoch);
                    [f.cache cancel];
                    error = nil;
                }
            }
            if (profile == 10 && step)
                fsm_raw_write(f, 4096,
                              step == 1 ? UINT32_C(0x3f000000) :
                                          UINT32_C(0x3f800000),
                              NO, NO);
            fsm_nil_key = profile == 11 && step < 2;
            fsm_nil_summary = profile == 12 && step < 2;
            FloatSummaryMemoWork work;
            NSData *bytes = fsm_capture(f, xf, input, prefixes, NO,
                                        profile == 2, lanes, &work);
            [outputs addObject:bytes];
            if ((profile == 1 || profile == 2) && step == 2) {
                NSRange summary =
                    NSMakeRange(sizeof(BOOL) + sizeof(uint64_t), 1024);
                assert(((NSData *)outputs[1]).length >= NSMaxRange(summary) &&
                       bytes.length >= NSMaxRange(summary));
                assert(![[outputs[1] subdataWithRange:summary]
                    isEqualToData:[bytes subdataWithRange:summary]]);
            }
            [workBytes appendBytes:&work length:sizeof(work)];
            /* Actual owned payload only, not heap/driver memory usage. */
            NSUInteger payload =
                ((NSData *)[f.fetch valueForKey:@"floatProofKey"]).length +
                ((NSData *)[f.fetch valueForKey:@"floatProofSpans"]).length;
            for (NSData *summary in
                 [f.fetch valueForKey:@"floatProofSummaries"])
                payload += summary.length;
            assert(payload == [[f.fetch valueForKey:@"floatProofPayload"]
                                  unsignedIntegerValue]);
            for (NSString *key in @[
                     @"indexRanges", @"indexRangesKey", @"arrayRanges",
                     @"arrayRangesKey", @"readonlyUniqueIndices",
                     @"readonlyRemap"
                 ])
                payload += ((NSData *)[f.fetch valueForKey:key]).length;
            assert(payload <= 65536);
        }
    } @finally {
        fsm_scope = fsm_reference = fsm_nil_key = fsm_reject_resource =
            fsm_nil_summary = fsm_in_scan = NO;
        fsm_cache = nil;
        [f.fetch close];
    }
    return outputs;
}
static void fsm_weak_inputs(void)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    fsm_cache = f.cache;
    fsm_reference = NO;
    NSError *error = nil;
    NV2AMetalVertexProgram *xf =
        [[NV2AMetalVertexProgram alloc] initWithDevice:f.queue.device
                                                 error:&error];
    require(xf != nil, error);
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .offset = 4096,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    fsm_seed(f, 8, 16, 4);
    __weak NV2AMetalPendingInput *weakInput;
    __weak NSData *weakIndices;
    @autoreleasepool {
        const uint32_t order[] = { 7, 1, 3, 1, 0, 4, 2, 1 };
        NV2AMetalPendingInput *input = rip_input(order, 8, nil);
        weakInput = input;
        weakIndices = input.indices;
        FloatSummaryMemoWork work;
        NSData *cold = fsm_capture(f, xf, input, @[ @0 ], NO, NO, 1, &work);
        NSData *warm = fsm_capture(f, xf, input, @[ @0 ], NO, NO, 1, &work);
        assert([cold isEqualToData:warm] && work.hits == 1);
    }
    /* Neither memo nor pure plans may own the input descriptor/view. */
    assert(!weakInput && !weakIndices);
    fsm_cache = nil;
    [f.fetch close];
}

static void float_summary_memo_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(reuseFloatProofForBatches:sources:indexData:indexOffset:
                      first:arrays:lanes:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(floatProofKeyForBatches:sources:indexData:indexOffset:
                      first:arrays:lanes:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(scanFloatProofSources:indices:first:count:lanes:)),
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            @selector(tryIdleCPUReadSpans:count:completed:error:)),
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            @selector(sourceVersionForReadSpans:count:version:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(addResource:error:)),
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:))
    };
    IMP replacements[] = { (IMP)fsm_reuse, (IMP)fsm_key,     (IMP)fsm_scan,
                           (IMP)fsm_guard, (IMP)fsm_version, (IMP)fsm_resource,
                           (IMP)fsm_data };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    fsm_reuse_original = (void *)originals[0];
    fsm_key_original = (void *)originals[1];
    fsm_scan_original = (void *)originals[2];
    fsm_guard_original = (void *)originals[3];
    fsm_version_original = (void *)originals[4];
    fsm_resource_original = (void *)originals[5];
    fsm_data_original = (void *)originals[6];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        fsm_weak_inputs();
        for (unsigned profile = 0; profile < 13; profile++) {
            @autoreleasepool {
                NSMutableData *oldWork = [NSMutableData new],
                              *newWork = [NSMutableData new];
                NSArray *old = fsm_run(profile, YES, oldWork);
                NSArray *warm = fsm_run(profile, NO, newWork);
                assert([warm
                    isEqualToArray:old]); /* All GPU/summary bytes first. */
                const FloatSummaryMemoWork *before = oldWork.bytes,
                                           *after = newWork.bytes;
                NSUInteger count = newWork.length / sizeof(*after);
                assert(oldWork.length == newWork.length && count >= 3);
                for (NSUInteger i = 0; i < count; i++) {
                    assert(!before[i].hits && before[i].words <= 4096 &&
                           after[i].words <= 4096);
                    if (after[i].hits)
                        assert(!after[i].scans && after[i].guards &&
                               after[i].versions);
                }
                /* Unchanged exact descriptors and order may reuse; a changed
                 * sequence never borrows evidence just because its set matches.
                 */
                if (profile == 0 || profile == 3 || profile == 4) {
                    assert(after[0].scans && !after[0].hits);
                    assert(after[1].hits == 1 && after[2].hits == 1);
                }
                if (profile == 1 || profile == 2)
                    assert(after[0].scans && !after[0].hits &&
                           after[1].hits == 1 && !after[2].hits &&
                           after[2].scans && after[3].hits == 1);
                if (profile == 5)
                    for (NSUInteger i = 0; i < count; i++)
                        assert(!after[i].hits && after[i].scans == 1 &&
                               after[i].words == 4096);
                if (profile == 7)
                    for (NSUInteger i = 0; i < count; i++)
                        assert(
                            !after[i].hits &&
                            (i == 10 ? !after[i].scans : after[i].scans != 0));
                if (profile == 6)
                    for (NSUInteger i = 0; i < count; i++)
                        assert(!after[i].hits && !after[i].scans);
                if (profile == 8)
                    for (NSUInteger i = 0; i < count; i++)
                        assert(!after[i].hits && after[i].scans);
                if (profile == 9) {
                    assert(after[1].hits == 1);
                    for (unsigned i = 2; i <= 5; i++)
                        assert(!after[i].hits && after[i].scans);
                    assert(after[6].hits ==
                           1); /* Empty/rejected writes changed nothing. */
                }
                if (profile == 10)
                    for (NSUInteger i = 0; i < count; i++)
                        assert(!after[i].hits && after[i].scans);
                if (profile == 11 || profile == 12)
                    assert(after[0].scans && after[1].scans && after[2].scans &&
                           !after[0].hits && !after[1].hits && !after[2].hits &&
                           after[0].keys && after[1].keys &&
                           after[3].hits == 1);
            }
        }
    } @finally {
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
        fsm_scope = fsm_reference = fsm_nil_key = fsm_reject_resource =
            fsm_nil_summary = fsm_in_scan = NO;
        fsm_cache = nil;
    }
    puts(
        "Float summary memo: 13 guarded cold/warm A/B groups, complete summary/"
        "GPU Fetch/XF/Current bytes; key/budget/CPUdirty/rawGPUepoch/cancel/"
        "simulated saturation/factory retry PASS");
    groups++;
}
#endif
