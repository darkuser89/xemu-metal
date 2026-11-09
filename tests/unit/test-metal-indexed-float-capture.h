/* Indexed proof scans may deduplicate evidence, never GPU Fetch records.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEXED_FLOAT_CAPTURE_H
#define TEST_METAL_INDEXED_FLOAT_CAPTURE_H

static _Thread_local BOOL ifc_scope;
static _Thread_local NSUInteger ifc_scans, ifc_words;
static NSData *ifc_scanned;
static NSData *(*ifc_scan_original)(id, SEL, const NV2AMetalAttributeSource *,
                                    const uint32_t *, NSUInteger, NSUInteger,
                                    uint64_t);
static NSData *ifc_scan(id owner, SEL selector,
                        const NV2AMetalAttributeSource *sources,
                        const uint32_t *indices, NSUInteger first,
                        NSUInteger count, uint64_t lanes)
{
    if (ifc_scope) {
        ifc_scans++;
        ifc_words += count * __builtin_popcountll(lanes);
        assert(indices && count <= 4096);
        ifc_scanned = [NSData dataWithBytes:indices + first length:count * 4];
    }
    return ifc_scan_original(owner, selector, sources, indices, first, count,
                             lanes);
}
typedef struct IndexedFloatCaptureCase {
    unsigned unique, attribute, components, prefix;
    BOOL host, live, nan, prefixPoison, fullyCached;
    uint64_t mask;
} IndexedFloatCaptureCase;
static uint32_t ifc_source_bits(unsigned index, unsigned lane, BOOL nan)
{
    if (!(index & 1) || (nan && index == 7))
        return UINT32_C(0x7fc12345);
    const uint32_t values[] = { UINT32_C(0xbf800000), 0, UINT32_C(0x3f800000) };
    return values[(index / 2 + lane) % 3];
}
static NSMutableData *ifc_indices(unsigned unique, unsigned prefix,
                                  BOOL prefixPoison)
{
    NSUInteger count = 8192 + prefix;
    NSMutableData *data = [NSMutableData dataWithLength:count * 4];
    assert(data);
    uint32_t *values = data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++)
        values[i] = i < prefix && prefixPoison ?
                        0 :
                        2 * (uint32_t)((i * 37) % unique) + 1;
    /* Current is deliberately not the maximum index. */
    values[count - 1] = 1;
    return data;
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
ifc_encode(FloatProofCaptureFixture *f, NV2AMetalPendingInput *input,
           NSUInteger prefix, BOOL host, uint64_t mask, BOOL legacy)
{
    ifc_scans = ifc_words = 0;
    ifc_scanned = nil;
    ifc_scope = YES;
    NSArray *batches;
    @try {
        batches = fpc_encode(f, input, @[ @(prefix) ], host, NO, mask, legacy);
    } @finally {
        ifc_scope = NO;
    }
    return batches;
}
/* This independent oracle checks every logical GPU row, including duplicate
 * indices and the separately appended Current. It never reads pending GPU
 * output and does not reproduce the summary algorithm. */
static void ifc_gpu(FloatProofCaptureFixture *f, NV2AMetalPGRAPHFetchBatch *b,
                    NSData *indices, NSUInteger prefix, unsigned attribute,
                    unsigned components, unsigned stride)
{
    const uint32_t *order = indices.bytes;
    NSUInteger decoded = indices.length / 4 - prefix;
    NSUInteger expectedRecords = decoded + b.fetch.hasCurrent;
    assert(!expectedRecords ||
           (b.fetch.attributes &&
            expectedRecords <=
                b.fetch.attributes.length / sizeof(NV2AMetalProgramInput)));
    const NV2AMetalProgramInput *records = b.fetch.attributes.contents;
    for (NSUInteger i = 0; i < decoded + b.fetch.hasCurrent; i++) {
        unsigned index =
            order[i == decoded ? indices.length / 4 - 1 : prefix + i];
        for (unsigned lane = 0; lane < 4; lane++) {
            uint32_t expected = lane == 3 ? UINT32_C(0x3f800000) : 0;
            if (lane < components)
                memcpy(&expected,
                       state->vram_ptr + 4096 + index * stride + lane * 4, 4);
            assert(
                !memcmp(records[i].attributes[attribute] + lane, &expected, 4));
        }
    }
    unsigned last = order[indices.length / 4 - 1];
    for (unsigned lane = 0; lane < components; lane++)
        assert(!memcmp(state->pgraph.vertex_attributes[attribute].inline_value +
                           lane,
                       state->vram_ptr + 4096 + last * stride + lane * 4, 4));
    (void)f;
}
static NSData *ifc_run(IndexedFloatCaptureCase c, BOOL legacy)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    NSError *error = nil;
    unsigned stride = c.components * 4, rows = c.unique * 2 + 2;
    state->pgraph.vertex_attributes[c.attribute] = (VertexAttribute){
        .offset = 4096,
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = 4,
        .count = c.components,
        .stride = stride,
    };
    for (unsigned lane = 0; lane < 4; lane++)
        state->pgraph.vertex_attributes[c.attribute].inline_value[lane] = 4096;
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:rows * stride
                                         write:YES
                                         error:&error],
            error);
    for (unsigned row = 0; row < rows; row++)
        for (unsigned lane = 0; lane < c.components; lane++) {
            uint32_t bits = ifc_source_bits(row, lane, c.nan);
            memcpy(state->vram_ptr + 4096 + row * stride + lane * 4, &bits, 4);
        }
    NSData *order = ifc_indices(c.unique, c.prefix, c.prefixPoison);
    NV2AMetalPendingInput *input =
        rip_input(order.bytes, order.length / 4, nil);
    require(input != nil, nil);
    NSUInteger prefix = c.fullyCached ? input.count : c.prefix;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
        ifc_encode(f, c.live ? nil : input, prefix, c.host, c.mask, legacy);
    assert(batches.count == 1);
    NV2AMetalPGRAPHFetchBatch *batch = batches[0];
    NV2AMetalCommands *owner = f.fetch.encodingCommands;
    NSUInteger scans = ifc_scans, words = ifc_words;
    NSData *scanned = ifc_scanned;
    NSData *summary = nil;
    uint64_t lanes = 0;
    NSUInteger decoded = order.length / 4 - prefix;
    BOOL bound = [batch.fetch getFloatProofSummaries:&summary
                                            laneMask:&lanes
                                     attributeBuffer:batch.fetch.attributes
                                               first:0
                                               count:decoded
                                            commands:owner];
    BOOL appendedRejected =
        ![batch.fetch getFloatProofSummaries:NULL
                                    laneMask:NULL
                             attributeBuffer:batch.fetch.attributes
                                       first:decoded
                                       count:1
                                    commands:owner];
    NSData *output = fpc_output(f, batches);
    ifc_gpu(f, batch, order, prefix, c.attribute, c.components, stride);
    /* Structural/metadata assertions follow actual GPU and Current bytes. */
    assert(!batch.remap && batch.physicalVertexCount == decoded &&
           batch.fetch.vertexCount == decoded &&
           batch.inputVertexCount == input.count);
    if (!c.fullyCached)
        assert(decoded >= 8192 && decoded > 4096);
    NSUInteger requested = c.unique * __builtin_popcountll(c.mask);
    BOOL expected = !legacy && !c.live && !c.fullyCached && requested <= 4096;
    assert(bound == expected && appendedRejected && words <= 4096);
    assert(scans == expected && words == (expected ? requested : 0));
    if (expected) {
        assert(summary.length == 1024 && lanes == c.mask &&
               ![summary isKindOfClass:NSMutableData.class] &&
               scanned.length == c.unique * 4);
        const uint32_t *actual = scanned.bytes;
        for (unsigned i = 0; i < c.unique; i++)
            assert(actual[i] == 2 * i + 1); /* Exact sparse source set. */
        const NV2AMetalFloatLaneSummary *values = summary.bytes;
        for (unsigned component = 0; component < 64; component++) {
            if (!(c.mask & (UINT64_C(1) << component))) {
                assert(!values[component].flags);
                continue;
            }
            assert(values[component].flags ==
                   (c.nan ? 0 : NV2AMetalFloatLaneSummaryFinite));
            if (!c.nan)
                assert(values[component].minBits == UINT32_C(0xbf800000) &&
                       values[component].maxBits == UINT32_C(0x3f800000) &&
                       !values[component].minExponent);
        }
    } else
        assert(!summary && !lanes && !scanned);
    [f.fetch close];
    return output;
}
static void ifc_pair(IndexedFloatCaptureCase c)
{
    NSData *old, *actual;
    @autoreleasepool {
        old = ifc_run(c, YES);
    }
    @autoreleasepool {
        actual = ifc_run(c, NO);
    }
    assert([old isEqualToData:actual]);
}
static void ifc_binding(void)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    NSError *error = nil;
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .offset = 4096,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 1,
                           .stride = 4 };
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:8
                                         write:YES
                                         error:&error],
            error);
    const uint32_t source[] = { 0, UINT32_C(0x3f800000) };
    memcpy(state->vram_ptr + 4096, source, sizeof(source));
    NSMutableData *indices = [NSMutableData dataWithLength:8192 * 4];
    uint32_t *words = indices.mutableBytes;
    for (unsigned i = 0; i < 8192; i++)
        words[i] = i & 1;
    NV2AMetalPendingInput *input = rip_input(words, 8192, nil);
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
        ifc_encode(f, input, 0, NO, 1, NO);
    NV2AMetalFetchResult *result = b[0].fetch;
    NV2AMetalCommands *owner = f.fetch.encodingCommands;
    NSData *summary = nil;
    uint64_t mask = 0;
    BOOL bound = [result getFloatProofSummaries:&summary
                                       laneMask:&mask
                                attributeBuffer:result.attributes
                                          first:0
                                          count:8192
                                       commands:owner];
    NSData *retained = [summary copy];
    id<MTLBuffer> wrong =
        [owner.device newBufferWithLength:result.attributes.length
                                  options:MTLResourceStorageModeShared];
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:owner.device error:&error];
    require(wrong && foreign && [foreign beginWithError:&error], error);
    BOOL wrongRejected = ![result getFloatProofSummaries:NULL
                                                laneMask:NULL
                                         attributeBuffer:wrong
                                                   first:0
                                                   count:8192
                                                commands:owner];
    BOOL foreignRejected = ![result getFloatProofSummaries:NULL
                                                  laneMask:NULL
                                           attributeBuffer:result.attributes
                                                     first:0
                                                     count:8192
                                                  commands:foreign];
    BOOL appendedRejected = ![result getFloatProofSummaries:NULL
                                                   laneMask:NULL
                                            attributeBuffer:result.attributes
                                                      first:8192
                                                      count:1
                                                   commands:owner];
    [foreign cancel];
    require([f.fetch submitWithError:&error], error);
    BOOL submittedRejected = ![result getFloatProofSummaries:NULL
                                                    laneMask:NULL
                                             attributeBuffer:result.attributes
                                                       first:0
                                                       count:8192
                                                    commands:owner];
    (void)fpc_output(f, b);
    ifc_gpu(f, b[0], indices, 0, 0, 1, 4);
    assert(bound && mask == 1 && summary.length == 1024 && wrongRejected &&
           foreignRejected && appendedRejected && submittedRejected &&
           [summary isEqualToData:retained]);
    b = ifc_encode(f, input, 0, NO, 1, NO);
    NV2AMetalFetchResult *cancelled = b[0].fetch;
    owner = f.fetch.encodingCommands;
    [f.fetch cancel];
    require([owner beginWithError:&error] != nil, error);
    assert(![cancelled getFloatProofSummaries:NULL
                                     laneMask:NULL
                              attributeBuffer:cancelled.attributes
                                        first:0
                                        count:8192
                                     commands:owner]);
    [owner cancel];
    require([f.cache discardForRestoreWithError:&error], error);
    assert(![cancelled getFloatProofSummaries:NULL
                                     laneMask:NULL
                              attributeBuffer:cancelled.attributes
                                        first:0
                                        count:8192
                                     commands:owner] &&
           [summary isEqualToData:retained]);
    [f.fetch close];
}
/* The last Current row is ready, while an earlier indexed source is a real
 * gated write/download. Guarding the unique set must precede every scan. */
static NSData *ifc_busy(BOOL dirty, BOOL legacy)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    NSError *error = nil;
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .offset = 4096,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 1,
                           .stride = 4096 };
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:8196
                                         write:YES
                                         error:&error],
            error);
    for (unsigned i = 0; i < 3; i++) {
        uint32_t one = UINT32_C(0x3f800000);
        memcpy(state->vram_ptr + 4096 + i * 4096, &one, 4);
    }
    if (dirty) {
        NV2AMetalSurfaceConfig c = {
            .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            .width = 1,
            .height = 1,
            .pitch = 4,
            .scale = 1,
            .color = YES
        };
        NV2AMetalCachedSurface *surface =
            [f.cache prepareSurfaceAtAddress:4096
                                      config:&c
                                       frame:1
                                       error:&error];
        NV2AMetalClear *clear =
            [[NV2AMetalClear alloc] initWithDevice:f.queue.device error:&error];
        require(surface && clear, error);
        id<MTLTexture> texture = [surface.transfer textureForCommands:f.queue
                                                                error:&error];
        NV2AMetalClearConfig config = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                        .rect = { 0, 0, 1, 1 },
                                        .uniforms = {
                                            .color = { 1, 1, 1, 1 } } };
        require(texture &&
                    [clear encodeColor:texture
                                  zeta:nil
                                config:&config
                              commands:f.queue
                                 error:&error] &&
                    [f.cache markWritten:surface
                        replacingContents:YES
                                    error:&error] &&
                    [f.cache submitWithError:&error] &&
                    [f.cache waitUntilIdleWithError:&error],
                error);
    }
    NSMutableData *indices = [NSMutableData dataWithLength:8192 * 4];
    uint32_t *words = indices.mutableBytes;
    for (unsigned i = 0; i < 8192; i++)
        words[i] = (i * 2) % 3;
    words[8191] = 2;
    NV2AMetalPendingInput *input = rip_input(words, 8192, nil);
    assert([f.fetch canCaptureCurrentForInput:input]);
    id<MTLSharedEvent> gate = [f.queue.device newSharedEvent];
    require(gate != nil, nil);
    fpc_gate(f.queue, gate);
    if (!dirty) {
        require([f.cache prepareGPUWriteAtAddress:4096 length:4 error:&error],
                error);
        uint32_t nan = UINT32_C(0x7fc12345);
        id<MTLBuffer> source =
            [f.queue.device newBufferWithBytes:&nan
                                        length:4
                                       options:MTLResourceStorageModeShared];
        require(source && [f.queue addResource:source error:&error], error);
        id<MTL4ComputeCommandEncoder> e =
            [f.queue.commandBuffer computeCommandEncoder];
        assert(e);
        [e copyFromBuffer:source
                 sourceOffset:0
                     toBuffer:f.cache.vram
            destinationOffset:4096
                         size:4];
        [e endEncoding];
        require([f.cache submitWithError:&error], error);
    }
    assert([f.fetch canCaptureCurrentForInput:input]);
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
        ifc_encode(f, input, 0, YES, 1, legacy);
    NSUInteger scans = ifc_scans, count = ifc_words;
    NSData *summary = nil;
    uint64_t mask = UINT64_MAX;
    BOOL bound = [b[0].fetch getFloatProofSummaries:&summary
                                           laneMask:&mask
                                    attributeBuffer:b[0].fetch.attributes
                                              first:0
                                              count:8192
                                           commands:f.fetch.encodingCommands];
    NV2AMetalCommands *owner = f.fetch.encodingCommands;
    id<MTLBuffer> marker =
        [owner.device newBufferWithLength:4
                                  options:MTLResourceStorageModeShared];
    require(marker && [owner addResource:marker error:&error], error);
    memset(marker.contents, 0xcd, 4);
    id<MTL4ComputeCommandEncoder> e =
        [owner.commandBuffer computeCommandEncoder];
    assert(e);
    [e fillBuffer:marker range:NSMakeRange(0, 4) value:0x5a];
    [e endEncoding];
    require([f.fetch submitWithError:&error], error);
    NV2AMetalSubmission *receipt = owner.lastSubmitted;
    assert(receipt && ![receipt completedWithError:&error] && !error &&
           !gate.signaledValue &&
           *(uint32_t *)marker.contents == UINT32_C(0xcdcdcdcd));
    gate.signaledValue = 1;
    NSData *output = fpc_output(f, b);
    ifc_gpu(f, b[0], indices, 0, 0, 1, 4096);
    assert(*(uint32_t *)marker.contents == UINT32_C(0x5a5a5a5a) && !scans &&
           !count && !bound && !summary && !mask && !b[0].remap &&
           b[0].physicalVertexCount == 8192 && gate.signaledValue == 1);
    [f.fetch close];
    return output;
}
static void indexed_float_capture_tests(void)
{
    Method scan = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(scanFloatProofSources:indices:first:count:lanes:));
    assert(scan);
    ifc_scan_original = (void *)method_getImplementation(scan);
    method_setImplementation(scan, (IMP)ifc_scan);
    unsigned oldReads = reads, oldPages = dirty_read_pages,
             oldNotifications = notifications, oldLoads = dma_loads;
    BOOL oldDirty = dirty_last;
    unsigned pairs = 0;
    @try {
        IndexedFloatCaptureCase cases[] = {
            { .unique = 32, .components = 1, .mask = 1 },
            { .unique = 32, .components = 1, .mask = 1, .host = YES },
            { .unique = 32,
              .components = 1,
              .mask = 1,
              .prefix = 17,
              .prefixPoison = YES },
            { .unique = 32, .components = 1, .mask = 1, .nan = YES },
            { .unique = 4096, .components = 1, .mask = 1 },
            { .unique = 4097, .components = 1, .mask = 1 },
            { .unique = 32,
              .attribute = 15,
              .components = 4,
              .mask = UINT64_C(1) << 63 },
            { .unique = 2048, .components = 2, .mask = 3 },
            { .unique = 2049, .components = 2, .mask = 3 },
            { .unique = 32, .components = 1, .mask = 1, .live = YES },
            { .unique = 32, .components = 1, .mask = 1, .fullyCached = YES },
        };
        for (unsigned i = 0; i < ARRAY_SIZE(cases); i++) {
            ifc_pair(cases[i]);
            pairs++;
        }
        ifc_binding();
        for (unsigned dirty = 0; dirty < 2; dirty++) {
            NSData *old, *actual;
            @autoreleasepool {
                old = ifc_busy(dirty, YES);
            }
            @autoreleasepool {
                actual = ifc_busy(dirty, NO);
            }
            assert([old isEqualToData:actual]);
            pairs++;
        }
    } @finally {
        ifc_scope = NO;
        ifc_scanned = nil;
        method_setImplementation(scan, (IMP)ifc_scan_original);
        reads = oldReads;
        dirty_read_pages = oldPages;
        notifications = oldNotifications;
        dma_loads = oldLoads;
        dirty_last = oldDirty;
        reset();
    }
    printf("Indexed Float capture:%u legacy GPU/Current pairs plus binding "
           "lifecycle; "
           "full8192 logical records, sparseunique4096/4097 global budget, "
           "Lane63/multiple lanes, prefix/NaNhole/liveinput, "
           "gated source write/download zero scans PASS\n",
           pairs);
    groups += pairs + 1;
}
#endif
