/* PGRAPH-owned Float evidence, independent raw expectations and legacy fetch.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FLOAT_PROOF_CAPTURE_H
#define TEST_METAL_FLOAT_PROOF_CAPTURE_H
@interface NV2AMetalPGRAPHFetch (FloatProofCaptureTest)
- (NSData *)scanFloatProofSources:(const NV2AMetalAttributeSource *)sources
                          indices:(const uint32_t *)indices
                            first:(NSUInteger)first
                            count:(NSUInteger)count
                            lanes:(uint64_t)lanes;
@end
static _Thread_local BOOL fpc_scope;
static _Thread_local NSUInteger fpc_scans, fpc_words;
static NSData *(*fpc_scan_original)(id, SEL, const NV2AMetalAttributeSource *,
                                    const uint32_t *, NSUInteger, NSUInteger,
                                    uint64_t);
static NSData *fpc_scan(id owner, SEL selector,
                        const NV2AMetalAttributeSource *sources,
                        const uint32_t *indices, NSUInteger first,
                        NSUInteger count, uint64_t lanes)
{
    if (fpc_scope) {
        fpc_scans++;
        fpc_words += count * __builtin_popcountll(lanes);
    }
    return fpc_scan_original(owner, selector, sources, indices, first, count,
                             lanes);
}
@interface FloatProofCaptureFixture : NSObject
@property(nonatomic) NV2AMetalCommands *queue;
@property(nonatomic) NV2AMetalSurfaceCache *cache;
@property(nonatomic) NV2AMetalPGRAPHFetch *fetch;
@end
@implementation FloatProofCaptureFixture
@end
typedef struct FloatProofCaptureCase {
    const uint32_t *bits;
    unsigned bitCount, rows, attribute, lane, prefix;
    BOOL host, indexed, dedup, liveIndex, multiple, noFloat;
    uint64_t mask;
    NSUInteger scans, words;
    uint32_t minimum, maximum, exponent, finite;
} FloatProofCaptureCase;
static NSUInteger fpc_cases;
static FloatProofCaptureFixture *fpc_fixture(void)
{
    reset();
    dma_a.address = 0;
    NSError *error = nil;
    FloatProofCaptureFixture *f = [FloatProofCaptureFixture new];
    f.queue = [[NV2AMetalCommands alloc] initWithDevice:surfaces.commands.device
                                                  error:&error];
    require(f.queue != nil, error);
    f.cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:f.queue
                    vram:surfaces.vram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(length && address < 65536 && length <= 65536 - address);
            }
                   error:&error];
    require(f.cache != nil, error);
    f.fetch = [[NV2AMetalPGRAPHFetch alloc] initWithState:state
                                                 surfaces:f.cache
                                                    error:&error];
    require(f.fetch != nil, error);
    return f;
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
fpc_encode(FloatProofCaptureFixture *f, NV2AMetalPendingInput *input,
           NSArray<NSNumber *> *prefixes, BOOL host, BOOL dedup, uint64_t lanes,
           BOOL legacy)
{
    NSError *error = nil;
    fpc_scans = fpc_words = 0;
    NSArray *batches;
    fpc_scope = YES;
    @try {
        if (host)
            batches = legacy ?
                          [f.fetch encodeCurrentSnapshotsWithPrefixes:prefixes
                                                         indexedInput:input
                                                  deduplicateReadonly:dedup
                                                                error:&error] :
                          [f.fetch encodeCurrentSnapshotsWithPrefixes:prefixes
                                                         indexedInput:input
                                                  deduplicateReadonly:dedup
                                                  proofAttributeLanes:lanes
                                                                error:&error];
        else
            batches =
                legacy ?
                    [f.fetch encodeIndependentSnapshotsWithPrefixes:prefixes
                                                       indexedInput:input
                                                deduplicateReadonly:dedup
                                                              error:&error] :
                    [f.fetch encodeIndependentSnapshotsWithPrefixes:prefixes
                                                       indexedInput:input
                                                deduplicateReadonly:dedup
                                                proofAttributeLanes:lanes
                                                              error:&error];
    } @finally {
        fpc_scope = NO;
    }
    require(batches != nil, error);
    return batches;
}
static NSData *fpc_output(FloatProofCaptureFixture *f,
                          NSArray<NV2AMetalPGRAPHFetchBatch *> *batches)
{
    NSError *error = nil;
    // This also validates GPU fetch faults before any output .contents access.
    require([f.fetch completeWithError:&error], error);
    NSMutableData *bytes = [NSMutableData new];
    for (NV2AMetalPGRAPHFetchBatch *b in batches) {
        NSUInteger count = b.fetch.vertexCount + b.fetch.hasCurrent;
        if (count)
            [bytes appendBytes:b.fetch.attributes.contents
                        length:count * sizeof(NV2AMetalProgramInput)];
        if (b.remap)
            [bytes appendData:b.remap];
    }
    for (unsigned i = 0; i < 16; i++)
        [bytes appendBytes:state->pgraph.vertex_attributes[i].inline_value
                    length:16];
    require([f.cache flushWithError:&error], error);
    return bytes;
}
static void fpc_summary(NV2AMetalPGRAPHFetchBatch *b, NV2AMetalCommands *owner,
                        FloatProofCaptureCase c, BOOL present)
{
    NSData *data = nil;
    uint64_t mask = 0;
    BOOL found = [b.fetch getFloatProofSummaries:&data
                                        laneMask:&mask
                                 attributeBuffer:b.fetch.attributes
                                           first:0
                                           count:b.physicalVertexCount
                                        commands:owner];
    assert(found == present);
    if (!present) {
        assert(!data && !mask);
        return;
    }
    assert(data.length == 1024 && mask == c.mask &&
           ![data isKindOfClass:NSMutableData.class]);
    const NV2AMetalFloatLaneSummary *s = data.bytes;
    const NV2AMetalFloatLaneSummary *v = &s[4 * c.attribute + c.lane];
    assert(v->flags == c.finite);
    if (c.finite)
        assert(v->minBits == c.minimum && v->maxBits == c.maximum &&
               v->minExponent == c.exponent);
    for (unsigned i = 0; i < 64; i++)
        if (!(c.mask & (UINT64_C(1) << i)))
            assert(!s[i].flags && !s[i].minBits && !s[i].maxBits &&
                   !s[i].minExponent);
}
static NSData *fpc_run(FloatProofCaptureCase c, BOOL legacy)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    NSError *error = nil;
    unsigned count = c.lane + 1, stride = c.noFloat ? 4 : count * 4;
    state->pgraph.vertex_attributes[c.attribute] = (VertexAttribute){
        .offset = 4096,
        .format = c.noFloat ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL :
                              NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = c.noFloat ? 1 : 4,
        .count = c.noFloat ? 4 : count,
        .stride = stride,
    };
    unsigned rows = c.indexed ? 8 : c.rows;
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:rows * stride
                                         write:YES
                                         error:&error],
            error);
    for (unsigned i = 0; i < rows; i++) {
        memset(state->vram_ptr + 4096 + i * stride, 0, stride);
        uint32_t bits = c.bits[i % c.bitCount];
        memcpy(state->vram_ptr + 4096 + i * stride + c.lane * 4, &bits, 4);
    }
    NV2AMetalPendingInput *input = nil;
    NSArray *prefixes;
    if (c.indexed) {
        const uint32_t selection[] = { 0, 7, 1, 7, 3, 1, 7 };
        const uint32_t selected[] = { 0,          0xbf800000, 0, 0,
                                      0x7fc00001, 0,          0, 0x3f800000 };
        for (unsigned i = 0; i < 8; i++)
            memcpy(state->vram_ptr + 4096 + i * stride + c.lane * 4,
                   selected + i, 4);
        input = rip_input(selection, 7, nil);
        if (c.liveIndex)
            input = nil;
        prefixes = @[ @(c.prefix) ];
    } else {
        state->pgraph.draw_arrays_length = c.multiple ? 2 : 1;
        state->pgraph.draw_arrays_count[0] = c.multiple ? c.rows / 2 : c.rows;
        state->pgraph.draw_arrays_start[1] = c.rows / 2;
        state->pgraph.draw_arrays_count[1] = c.rows - c.rows / 2;
        prefixes = c.multiple ? @[ @0, @0 ] : @[ @(c.prefix) ];
    }
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
        fpc_encode(f, input, prefixes, c.host, c.dedup, c.mask, legacy);
    NSUInteger scans = fpc_scans, words = fpc_words;
    NV2AMetalCommands *owner = f.fetch.encodingCommands;
    for (NV2AMetalPGRAPHFetchBatch *batch in b)
        fpc_summary(batch, owner, c, !legacy && c.scans != 0);
    // A blocked write probe is pure: it cannot announce a successful store.
    BOOL writable = YES;
    require([f.cache tryIdleCPUAccessAtAddress:4096 + (rows - 1) * stride
                                        length:4
                                         write:YES
                                     completed:&writable
                                         error:&error],
            error);
    assert(!writable);
    NSData *bytes = fpc_output(f, b);
    assert(scans == (legacy ? 0 : c.scans) && words == (legacy ? 0 : c.words));
    [f.fetch close];
    return bytes;
}
static void fpc_pair(FloatProofCaptureCase c)
{
    NSData *old = fpc_run(c, YES), *actual = fpc_run(c, NO);
    if (![old isEqualToData:actual]) {
        fprintf(stderr,
                "Float proof capture GPU/Current bytes differ case%lu\n",
                (unsigned long)fpc_cases);
        abort();
    }
    fpc_cases++;
}
static void fpc_binding(void)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    NSError *error = nil;
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .offset = 4096,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 1,
                           .stride = 4 };
    state->pgraph.draw_arrays_length = 1;
    state->pgraph.draw_arrays_count[0] = 3;
    const uint32_t bits[] = { 0xbf800000, 0, 0x3f800000 };
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:12
                                         write:YES
                                         error:&error],
            error);
    memcpy(state->vram_ptr + 4096, bits, sizeof(bits));
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
        fpc_encode(f, nil, @[ @0 ], NO, NO, 1, NO);
    NV2AMetalFetchResult *result = b[0].fetch;
    NV2AMetalCommands *owner = f.fetch.encodingCommands;
    NSData *data = nil;
    uint64_t mask = 0;
    require([result getFloatProofSummaries:&data
                                  laneMask:&mask
                           attributeBuffer:result.attributes
                                     first:0
                                     count:3
                                  commands:owner],
            nil);
    NSData *saved = [NSData dataWithData:data];
    id<MTLBuffer> other =
        [owner.device newBufferWithLength:result.attributes.length
                                  options:MTLResourceStorageModeShared];
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:owner.device error:&error];
    require(foreign && [foreign beginWithError:&error] != nil, error);
    assert(![result getFloatProofSummaries:NULL
                                  laneMask:NULL
                           attributeBuffer:other
                                     first:0
                                     count:3
                                  commands:owner]);
    assert(![result getFloatProofSummaries:NULL
                                  laneMask:NULL
                           attributeBuffer:result.attributes
                                     first:0
                                     count:3
                                  commands:foreign]);
    assert(result.hasCurrent &&
           ![result getFloatProofSummaries:NULL
                                  laneMask:NULL
                           attributeBuffer:result.attributes
                                     first:3
                                     count:1
                                  commands:owner]);
    assert(![result getFloatProofSummaries:NULL
                                  laneMask:NULL
                           attributeBuffer:result.attributes
                                     first:0
                                     count:4
                                  commands:owner]);
    [foreign cancel];
    require([f.fetch submitWithError:&error], error);
    assert(![result getFloatProofSummaries:NULL
                                  laneMask:NULL
                           attributeBuffer:result.attributes
                                     first:0
                                     count:3
                                  commands:owner]);
    (void)fpc_output(f, b);
    assert([data isEqualToData:saved]);
    b = fpc_encode(f, nil, @[ @0 ], NO, NO, 1, NO);
    result = b[0].fetch;
    owner = f.fetch.encodingCommands;
    [f.fetch cancel];
    require([owner beginWithError:&error] != nil, error);
    assert(![result getFloatProofSummaries:NULL
                                  laneMask:NULL
                           attributeBuffer:result.attributes
                                     first:0
                                     count:3
                                  commands:owner]);
    [owner cancel];
    require([f.cache discardForRestoreWithError:&error], error);
    assert(![result getFloatProofSummaries:NULL
                                  laneMask:NULL
                           attributeBuffer:result.attributes
                                     first:0
                                     count:3
                                  commands:owner]);
    assert([data isEqualToData:saved]);
    [f.fetch close];
    fpc_cases++;
}

static void fpc_gate(NV2AMetalCommands *q, id<MTLSharedEvent> event)
{
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(q, ivar);
    assert(queue);
    [queue waitForEvent:event value:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!event.signaledValue)
                         event.signaledValue = 2;
                   });
}
static NSData *fpc_busy(BOOL dirty, BOOL legacy)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    NSError *error = nil;
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .offset = 4096,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 1,
                           .stride = 4096 };
    state->pgraph.draw_arrays_length = 1;
    state->pgraph.draw_arrays_count[0] = 3;
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:8196
                                         write:YES
                                         error:&error],
            error);
    for (unsigned i = 0; i < 3; i++) {
        uint32_t value = 0x3f800000;
        memcpy(state->vram_ptr + 4096 + i * 4096, &value, 4);
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
        NV2AMetalCachedSurface *s = [f.cache prepareSurfaceAtAddress:4096
                                                              config:&c
                                                               frame:1
                                                               error:&error];
        NV2AMetalClear *clear =
            [[NV2AMetalClear alloc] initWithDevice:f.queue.device error:&error];
        require(s && clear, error);
        NV2AMetalClearConfig cc = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                    .rect = { 0, 0, 1, 1 },
                                    .uniforms = { .color = { 1, 1, 1, 1 } } };
        id<MTLTexture> texture = [s.transfer textureForCommands:f.queue
                                                          error:&error];
        require(texture &&
                    [clear encodeColor:texture
                                  zeta:nil
                                config:&cc
                              commands:f.queue
                                 error:&error] &&
                    [f.cache markWritten:s
                        replacingContents:YES
                                    error:&error] &&
                    [f.cache submitWithError:&error] &&
                    [f.cache waitUntilIdleWithError:&error],
                error);
    }
    id<MTLSharedEvent> gate = [f.queue.device newSharedEvent];
    assert(gate);
    fpc_gate(f.queue, gate);
    if (!dirty) {
        require([f.cache prepareGPUWriteAtAddress:4096 length:4 error:&error],
                error);
        uint32_t value = 0x7fc01234;
        id<MTLBuffer> source =
            [f.queue.device newBufferWithBytes:&value
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
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
        fpc_encode(f, nil, @[ @0 ], dirty, NO, 1, legacy);
    assert(!gate.signaledValue && !fpc_scans && !fpc_words);
    NSData *summary = nil;
    uint64_t mask = UINT64_MAX;
    assert(![b[0].fetch getFloatProofSummaries:&summary
                                      laneMask:&mask
                               attributeBuffer:b[0].fetch.attributes
                                         first:0
                                         count:3
                                      commands:f.fetch.encodingCommands] &&
           !summary && !mask);
    gate.signaledValue = 1;
    NSData *bytes = fpc_output(f, b);
    assert(gate.signaledValue == 1);
    [f.fetch close];
    return bytes;
}

static void float_proof_capture_tests(void)
{
    Method scan = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(scanFloatProofSources:indices:first:count:lanes:));
    assert(scan);
    fpc_scan_original = (void *)method_getImplementation(scan);
    method_setImplementation(scan, (IMP)fpc_scan);
    unsigned oldReads = reads, oldPages = dirty_read_pages,
             oldNotifications = notifications, oldLoads = dma_loads;
    BOOL oldDirty = dirty_last;
    @try {
        const uint32_t patterns[][3] = {
            { 0xbf800000, 0, 0x3f800000 },
            { 0x80000000, 0, 0x80000000 },
            { 0x80000001, 0, 1 },
            { 0x3f800000, 0x7fc01234, 0xbf800000 },
            { 0xbf800000, 0x7f800000, 0 },
            { 0x71800001, 0x71800001, 0x71800001 },
            { 0x71800001, 0x71800002, 0x71800003 },
        };
        const uint32_t minimum[] = { 0xbf800000, 0x80000000, 0x80000001, 0,
                                     0,          0x71800001, 0x71800001 };
        const uint32_t maximum[] = { 0x3f800000, 0,          1,         0,
                                     0,          0x71800001, 0x71800003 };
        fpc_cases = 0;
        for (unsigned i = 0; i < 7; i++) {
            FloatProofCaptureCase c = {
                .bits = patterns[i],
                .bitCount = 3,
                .rows = 3,
                .host = i & 1,
                .mask = 1,
                .scans = 1,
                .words = 3,
                .minimum = minimum[i],
                .maximum = maximum[i],
                .exponent = i >= 5 ? 227 : 0,
                .finite = i == 3 || i == 4 ? 0 : NV2AMetalFloatLaneSummaryFinite
            };
            fpc_pair(c);
        }
        FloatProofCaptureCase c = { .bits = patterns[0],
                                    .bitCount = 3,
                                    .rows = 3,
                                    .mask = 1,
                                    .scans = 1,
                                    .words = 2,
                                    .prefix = 1,
                                    .minimum = 0,
                                    .maximum = 0x3f800000,
                                    .finite = 1 };
        fpc_pair(c);
        c.prefix = 0;
        c.attribute = 15;
        c.lane = 3;
        c.mask = UINT64_C(1) << 63;
        c.words = 3;
        c.minimum = 0xbf800000;
        fpc_pair(c);
        c.attribute = c.lane = 0;
        c.mask = 1;
        c.indexed = YES;
        c.dedup = YES;
        c.prefix = 2;
        c.words = 3;
        fpc_pair(c);
        c.host = YES;
        fpc_pair(c);
        c.host = NO;
        c.dedup = NO;
        c.words = 5;
        fpc_pair(c);
        c.liveIndex = YES;
        c.scans = c.words = 0;
        fpc_pair(c);
        c.indexed = c.liveIndex = NO;
        c.prefix = 0;
        c.mask = 0;
        fpc_pair(c);
        c.mask = 1;
        c.noFloat = YES;
        fpc_pair(c);
        c.noFloat = NO;
        c.rows = 4096;
        c.scans = 1;
        c.words = 4096;
        fpc_pair(c);
        c.rows = 4097;
        c.scans = c.words = 0;
        fpc_pair(c);
        c.rows = 4096;
        c.multiple = YES;
        c.scans = 2;
        c.words = 4096;
        fpc_pair(c);
        c.rows = 4097;
        c.scans = c.words = 0;
        fpc_pair(c);
        fpc_binding();
        for (unsigned dirty = 0; dirty < 2; dirty++) {
            NSData *old = fpc_busy(dirty, YES), *actual = fpc_busy(dirty, NO);
            assert([old isEqualToData:actual]);
            fpc_cases++;
        }
    } @finally {
        fpc_scope = NO;
        method_setImplementation(scan, (IMP)fpc_scan_original);
        reads = oldReads;
        dirty_read_pages = oldPages;
        notifications = oldNotifications;
        dma_loads = oldLoads;
        dirty_last = oldDirty;
        reset();
    }
    assert(fpc_cases == 22);
    groups += fpc_cases;
    printf("Float proof capture: %lu groups,21 legacy GPU/Current pairs plus "
           "binding/lease scope,raw summaries,global4096 budget,indexed "
           "holes,busy writes/downloads PASS\n",
           (unsigned long)fpc_cases);
}
#endif
