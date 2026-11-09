/* Recording-local fetch parameters versus the original unconditional upload.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_FETCH_UNIFORM_CACHE_H
#define TEST_METAL_FETCH_UNIFORM_CACHE_H

@interface NV2AMetalVertexFetch (FetchUniformCacheTest)
- (MTLGPUAddress)addressForUniforms:(const NV2AMetalFetchUniforms *)uniforms
                           commands:(NV2AMetalCommands *)commands
                              error:(NSError **)error;
@end

@interface FetchUniformCommands : NV2AMetalCommands
@property(nonatomic) NSUInteger uniformCalls, uploadDepth;
@property(nonatomic) BOOL rejectUniform;
@property(nonatomic, weak) id<MTLResource> rejectResource;
@property(nonatomic) NSMutableArray<NSData *> *uniformPayloads;
@end
@implementation FetchUniformCommands
- (BOOL)addResource:(id<MTLResource>)resource error:(NSError **)error
{
    if (resource == _rejectResource) {
        _rejectResource = nil;
        if (error)
            *error = [NSError errorWithDomain:@"test.fetch-uniform.resource"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return [super addResource:resource error:error];
}
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                      length:(NSUInteger)length
                      offset:(NSUInteger *)offset
                       error:(NSError **)error
{
    BOOL uniform = !_uploadDepth && length == sizeof(NV2AMetalFetchUniforms);
    if (uniform) {
        _uniformCalls++;
        if (_rejectUniform) {
            _rejectUniform = NO;
            if (error)
                *error = [NSError errorWithDomain:@"test.fetch-uniform.upload"
                                             code:1
                                         userInfo:nil];
            return nil;
        }
    }
    _uploadDepth++;
    id<MTLBuffer> result = [super uploadBytes:bytes
                                       length:length
                                       offset:offset
                                        error:error];
    _uploadDepth--;
    if (uniform && result) {
        assert(*offset <= result.length && length <= result.length - *offset);
        assert(
            !memcmp((const uint8_t *)result.contents + *offset, bytes, length));
        if (!_uniformPayloads)
            _uniformPayloads = [NSMutableArray new];
        [_uniformPayloads addObject:[NSData dataWithBytes:bytes length:length]];
    }
    return result;
}
@end

@interface FetchUniformReference : NV2AMetalVertexFetch
@end
@implementation FetchUniformReference
- (MTLGPUAddress)addressForUniforms:(const NV2AMetalFetchUniforms *)uniforms
                           commands:(NV2AMetalCommands *)commands
                              error:(NSError **)error
{
    /* The original callsite, independent of the new lookup implementation. */
    NSUInteger offset = 0;
    id<MTLBuffer> result = [commands uploadBytes:uniforms
                                          length:sizeof(*uniforms)
                                          offset:&offset
                                           error:error];
    return result ? result.gpuAddress + offset : 0;
}
@end

@interface FetchUniformObservation : NSObject
@property(nonatomic) NV2AMetalFetchResult *result;
@property(nonatomic) NSData *expected, *uniforms;
@property(nonatomic) NSUInteger calls, expectedCalls;
@end
@implementation FetchUniformObservation
@end

static FetchUniformCommands *ufc_commands(id<MTLDevice> device)
{
    NSError *error = nil;
    FetchUniformCommands *q =
        [[FetchUniformCommands alloc] initWithDevice:device error:&error];
    require(q != nil, error);
    return q;
}
static NV2AMetalVertexFetch *ufc_fetch(id<MTLDevice> device, BOOL reference,
                                       BOOL summary)
{
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [(reference ? FetchUniformReference.class :
                      NV2AMetalVertexFetch.class) alloc];
    fetch = [fetch initWithDevice:device faultSummaryOnly:summary error:&error];
    require(fetch != nil, error);
    return fetch;
}
static id<MTLBuffer> ufc_source(NV2AMetalCommands *q, unsigned salt,
                                NSUInteger offset)
{
    NSMutableData *data = [NSMutableData dataWithLength:offset + 8 * 16];
    for (unsigned v = 0; v < 8; v++)
        for (unsigned k = 0; k < 4; k++) {
            float value = salt * 32 + v * 4 + k + .25f;
            memcpy((uint8_t *)data.mutableBytes + offset + v * 16 + k * 4,
                   &value, 4);
        }
    return buffer(q, data.bytes, data.length);
}
static void ufc_bind(NV2AMetalAttributeSource s[16], id<MTLBuffer> source,
                     NSUInteger offset)
{
    defaults(s);
    s[0] = (NV2AMetalAttributeSource){
        .buffer = source,
        .offset = offset,
        .byteLength = 8 * 16,
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .count = 4,
        .stride = 16
    };
}

static NV2AMetalFetchResult *
ufc_emit(NV2AMetalVertexFetch *fetch, FetchUniformCommands *q,
         NV2AMetalAttributeSource s[16], NSUInteger count, unsigned first,
         id<MTLBuffer> indices, NSUInteger indexOffset, unsigned indexSize,
         NSUInteger current, NSUInteger prefix, BOOL reference,
         NSUInteger uploads,
         NSMutableArray<FetchUniformObservation *> *observations)
{
    NSData *host = [NSData dataWithBytes:s length:16 * sizeof(*s)];
    NSUInteger before = q.uniformCalls;
    NSError *error = nil;
    NV2AMetalFetchResult *result = [fetch encodeSources:s
                                                  count:count
                                            firstVertex:first
                                                indices:indices
                                            indexOffset:indexOffset
                                              indexSize:indexSize
                                          currentVertex:current
                                         skippingPrefix:prefix
                                               commands:q
                                                  error:&error];
    require(result != nil, error);
    assert(!memcmp(host.bytes, s, host.length));
    assert(result.vertexCount == count - prefix &&
           result.hasCurrent == (current != NSNotFound));
    NSUInteger records = result.vertexCount + result.hasCurrent;
    NSMutableData *expected =
        [NSMutableData dataWithLength:records * sizeof(NV2AMetalProgramInput)];
    NV2AMetalProgramInput *out = expected.mutableBytes;
    for (NSUInteger v = 0; v < records; v++) {
        NSUInteger ordinal = v < result.vertexCount ? prefix + v : current;
        unsigned index = (unsigned)ordinal;
        if (indexSize) {
            const uint8_t *p = (const uint8_t *)indices.contents + indexOffset +
                               ordinal * indexSize;
            index = (unsigned)p[0] | (unsigned)p[1] << 8;
            if (indexSize == 4)
                index |= (unsigned)p[2] << 16 | (unsigned)p[3] << 24;
        }
        index += first;
        for (unsigned a = 0; a < 16; a++) {
            memcpy(out[v].attributes[a], s[a].inline_value, 16);
            if (s[a].count) {
                /* These independent fixtures use full Float4 inputs only. */
                assert(s[a].format ==
                           NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F &&
                       s[a].count == 4);
                memcpy(out[v].attributes[a],
                       (const uint8_t *)s[a].buffer.contents + s[a].offset +
                           (NSUInteger)index * s[a].stride,
                       16);
            }
        }
    }
    NV2AMetalFetchUniforms u;
    require([result getSourceUniforms:&u
                      attributeBuffer:result.attributes
                                first:0
                                count:records
                             commands:q],
            nil);
    if (q.uniformCalls != before)
        assert([q.uniformPayloads.lastObject
            isEqualToData:[NSData dataWithBytes:&u length:sizeof(u)]]);
    FetchUniformObservation *o = [FetchUniformObservation new];
    o.result = result;
    o.expected = expected;
    o.uniforms = [NSData dataWithBytes:&u length:sizeof(u)];
    o.calls = q.uniformCalls - before;
    o.expectedCalls = reference ? 1 : uploads;
    [observations addObject:o];
    return result;
}

static NSData *ufc_verify(NSArray<FetchUniformObservation *> *observations)
{
    NSMutableData *bytes = [NSMutableData new];
    for (FetchUniformObservation *o in observations) {
        NV2AMetalFetchResult *r = o.result;
        assert(r.attributes.length == o.expected.length);
        assert(!memcmp(r.attributes.contents, o.expected.bytes,
                       o.expected.length));
        assert(r.faults.length >= sizeof(uint32_t));
        const uint8_t *faults = r.faults.contents;
        for (NSUInteger i = 0; i < r.faults.length; i++)
            assert(!faults[i]);
        [bytes appendData:o.expected];
        [bytes appendData:o.uniforms];
        [bytes appendBytes:faults length:r.faults.length];
    }
    /* GPU bytes, all fault words and Current precede work assertions. */
    for (FetchUniformObservation *o in observations) {
        if (o.calls != o.expectedCalls)
            fprintf(stderr, "Fetch uniform uploads: got %lu expected %lu\n",
                    (unsigned long)o.calls, (unsigned long)o.expectedCalls);
        assert(o.calls == o.expectedCalls);
    }
    return bytes;
}

static NSData *ufc_snapshots(id<MTLDevice> device, BOOL reference, BOOL summary)
{
    FetchUniformCommands *q = ufc_commands(device);
    NV2AMetalVertexFetch *fetch = ufc_fetch(device, reference, summary);
    NSMutableArray<FetchUniformObservation *> *observations =
        [NSMutableArray new];
    NV2AMetalAttributeSource s[16];
    defaults(s);
    begin(q);
    for (unsigned i = 0; i < 2; i++)
        ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, !i,
                 observations);
    const uint32_t raw[] = { 0x00000000, 0x80000000, 0x7fc12345, 0x7fc54321 };
    for (unsigned i = 0; i < 4; i++) {
        memcpy(&s[15].inline_value[3], &raw[i], 4);
        ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 1,
                 observations);
        ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 0,
                 observations);
    }
    /* Initial snapshot has now been evicted from the four-entry cache. */
    defaults(s);
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 1, observations);
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, observations);
    ufc_emit(fetch, q, s, 2, 1, nil, 0, 0, 1, 0, reference, 1, observations);
    ufc_emit(fetch, q, s, 2, 1, nil, 0, 0, 0, 0, reference, 1, observations);
    ufc_emit(fetch, q, s, 2, 1, nil, 0, 0, 0, 1, reference, 1, observations);
    ufc_emit(fetch, q, s, 2, 1, nil, 0, 0, NSNotFound, 1, reference, 1,
             observations);
    finish(q);
    return ufc_verify(observations);
}

static NSData *ufc_fresh_bindings(id<MTLDevice> device, BOOL reference)
{
    FetchUniformCommands *q = ufc_commands(device);
    NV2AMetalVertexFetch *fetch = ufc_fetch(device, reference, NO);
    NSMutableArray<FetchUniformObservation *> *observations =
        [NSMutableArray new];
    id<MTLBuffer> a = ufc_source(q, 0, 0), b = ufc_source(q, 3, 3);
    NV2AMetalAttributeSource s[16];
    begin(q);
    ufc_bind(s, a, 0);
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 1, observations);
    ufc_bind(s, b, 3);
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 0, observations);
    uint32_t ia[] = { 0, 2, 1 }, ib[] = { 7, 4, 3 };
    id<MTLBuffer> indicesA = buffer(q, ia, sizeof(ia));
    id<MTLBuffer> indicesB = buffer(q, ib, sizeof(ib));
    ufc_emit(fetch, q, s, 3, 0, indicesA, 0, 4, 2, 0, reference, 1,
             observations);
    ufc_emit(fetch, q, s, 3, 0, indicesB, 0, 4, 2, 0, reference, 0,
             observations);
    uint16_t ix[] = { 0, 1, 3, 5 };
    id<MTLBuffer> indices16 = buffer(q, ix, sizeof(ix));
    ufc_emit(fetch, q, s, 3, 0, indices16, 0, 2, 2, 0, reference, 1,
             observations);
    ufc_emit(fetch, q, s, 3, 0, indices16, 2, 2, 2, 0, reference, 0,
             observations);
    s[0].stride = 0;
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 1, observations);
    s[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    finish(q);
    NSData *result = ufc_verify(observations);
    assert(![observations[0].expected isEqualToData:observations[1].expected]);
    assert(![observations[2].expected isEqualToData:observations[3].expected]);
    assert(![observations[4].expected isEqualToData:observations[5].expected]);
    return result;
}

static NSData *ufc_lifecycle(id<MTLDevice> device, BOOL reference)
{
    FetchUniformCommands *q = ufc_commands(device);
    NV2AMetalVertexFetch *fetch = ufc_fetch(device, reference, NO);
    NV2AMetalAttributeSource s[16];
    defaults(s);
    NSMutableArray<FetchUniformObservation *> *all = [NSMutableArray new];
    NSError *error = nil;
    begin(q);
    uint64_t serial = q.recordingSerial;
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    require([q sealWithError:&error], error);
    begin(q);
    assert(q.recordingSerial > serial);
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    finish(q);
    NSMutableData *bytes = [NSMutableData dataWithData:ufc_verify(all)];
    [all removeAllObjects];

    begin(q);
    NV2AMetalFetchResult *cancelled =
        ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    [q cancel];
    [all removeAllObjects]; // Cancelled GPU outputs are never read.
    begin(q);
    NV2AMetalFetchUniforms stale;
    assert(![cancelled getSourceUniforms:&stale
                         attributeBuffer:cancelled.attributes
                                   first:0
                                   count:1
                                commands:q]);
    /* Rewind the cancelled arena and occupy its old uniform address. */
    uint8_t poison[1536];
    memset(poison, 0xa7, sizeof(poison));
    NSUInteger offset = 0;
    require([q uploadBytes:poison
                    length:sizeof(poison)
                    offset:&offset
                     error:&error] != nil,
            error);
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 0, all);
    finish(q);
    [bytes appendData:ufc_verify(all)];
    [all removeAllObjects];

    begin(q);
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    require([q sealWithError:&error], error);
    begin(q);
    NSMutableArray<FetchUniformObservation *> *discarded = [NSMutableArray new];
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, discarded);
    [q cancelUnsealed];
    [discarded removeAllObjects];
    begin(q);
    require([q uploadBytes:poison
                    length:sizeof(poison)
                    offset:&offset
                     error:&error] != nil,
            error);
    ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    finish(q);
    [bytes appendData:ufc_verify(all)];
    [all removeAllObjects];

    FetchUniformCommands *ownerA = ufc_commands(device),
                         *ownerB = ufc_commands(device);
    begin(ownerA);
    begin(ownerB);
    assert(ownerA.recordingSerial == ownerB.recordingSerial);
    ufc_emit(fetch, ownerA, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    ufc_emit(fetch, ownerB, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    ufc_emit(fetch, ownerA, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
    finish(ownerA);
    finish(ownerB);
    [bytes appendData:ufc_verify(all)];
    [all removeAllObjects];
    NSUInteger slots = [[q valueForKey:@"slots"] count];
    assert(slots && slots <= 8);
    for (NSUInteger i = 0; i <= slots; i++) {
        begin(q);
        ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 1, all);
        ufc_emit(fetch, q, s, 2, 0, nil, 0, 0, 1, 0, reference, 0, all);
        finish(q);
    }
    [bytes appendData:ufc_verify(all)];
    return bytes;
}

static NSData *ufc_validation(id<MTLDevice> device, BOOL reference)
{
    FetchUniformCommands *q = ufc_commands(device);
    NV2AMetalVertexFetch *fetch = ufc_fetch(device, reference, NO);
    NSMutableArray<FetchUniformObservation *> *observations =
        [NSMutableArray new];
    NV2AMetalAttributeSource s[16];
    id<MTLBuffer> source = ufc_source(q, 0, 0);
    ufc_bind(s, source, 0);
    begin(q);
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 1, observations);
    NSUInteger beforeEmpty = q.uniformCalls;
    NSError *emptyError = nil;
    NV2AMetalFetchResult *empty = [fetch encodeSources:s
                                                 count:0
                                           firstVertex:0
                                               indices:nil
                                           indexOffset:0
                                             indexSize:0
                                              commands:q
                                                 error:&emptyError];
    require(empty != nil, emptyError);
    assert(!empty.vertexCount && !empty.attributes && !empty.faults &&
           q.uniformCalls == beforeEmpty);
    empty = [fetch encodeSources:s
                           count:3
                     firstVertex:0
                         indices:nil
                     indexOffset:0
                       indexSize:0
                   currentVertex:NSNotFound
                  skippingPrefix:3
                        commands:q
                           error:&emptyError];
    require(empty != nil, emptyError);
    assert(!empty.vertexCount && !empty.attributes && !empty.faults &&
           q.uniformCalls == beforeEmpty);
    for (unsigned bad = 0; bad < 6; bad++) {
        NV2AMetalAttributeSource invalid[16];
        memcpy(invalid, s, sizeof(invalid));
        NSUInteger count = 3, prefix = 0, current = 2;
        if (bad == 0)
            invalid[0].buffer = nil;
        if (bad == 1)
            invalid[0].offset = source.length;
        if (bad == 2)
            invalid[0].byteLength = source.length + 1;
        if (bad == 3)
            invalid[0].byteLength = 16;
        if (bad == 4)
            prefix = count + 1;
        if (bad == 5)
            current = count;
        NSUInteger calls = q.uniformCalls;
        q.rejectUniform = YES;
        NSError *error = nil;
        assert(![fetch encodeSources:invalid
                               count:count
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                       currentVertex:current
                      skippingPrefix:prefix
                            commands:q
                               error:&error] &&
               error);
        assert(![error.domain isEqualToString:@"test.fetch-uniform.upload"] &&
               q.uniformCalls == calls && q.rejectUniform);
        q.rejectUniform = NO;
        ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 0,
                 observations);
    }
    /* A failed miss must not publish an unusable address. */
    s[15].inline_value[3] = 123.5f;
    q.rejectUniform = YES;
    NSError *error = nil;
    NSUInteger calls = q.uniformCalls;
    assert(![fetch encodeSources:s
                           count:3
                     firstVertex:0
                         indices:nil
                     indexOffset:0
                       indexSize:0
                   currentVertex:2
                        commands:q
                           error:&error] &&
           [error.domain isEqualToString:@"test.fetch-uniform.upload"] &&
           q.uniformCalls == calls + 1);
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 1, observations);
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 0, observations);
    /* Even a uniform hit still registers the current source resource. */
    q.rejectResource = source;
    calls = q.uniformCalls;
    error = nil;
    assert(![fetch encodeSources:s
                           count:3
                     firstVertex:0
                         indices:nil
                     indexOffset:0
                       indexSize:0
                   currentVertex:2
                        commands:q
                           error:&error] &&
           [error.domain isEqualToString:@"test.fetch-uniform.resource"] &&
           !q.rejectResource && q.uniformCalls == calls + (reference ? 1 : 0));
    ufc_emit(fetch, q, s, 3, 0, nil, 0, 0, 2, 0, reference, 0, observations);
    finish(q);
    return ufc_verify(observations);
}

static void fetch_uniform_cache_tests(id<MTLDevice> device)
{
    _Static_assert(sizeof(NV2AMetalFetchUniforms) == 536,
                   "Fetch uniform upload fixture layout");
    for (unsigned group = 0; group < 5; group++) {
        NSData *reference;
        @autoreleasepool {
            reference = group < 2  ? ufc_snapshots(device, YES, group == 1) :
                        group == 2 ? ufc_fresh_bindings(device, YES) :
                        group == 3 ? ufc_lifecycle(device, YES) :
                                     ufc_validation(device, YES);
        }
        @autoreleasepool {
            NSData *actual = group < 2 ? ufc_snapshots(device, NO, group == 1) :
                             group == 2 ? ufc_fresh_bindings(device, NO) :
                             group == 3 ? ufc_lifecycle(device, NO) :
                                          ufc_validation(device, NO);
            assert([reference isEqualToData:actual]);
        }
    }
    puts("Metal4 fetch uniform cache:5 original-upload/GPU-byte pairs;raw536B,"
         "four-entry eviction,fresh source/index bindings,Current/suffix,"
         "serial/owner/cancel/arena-rewind,validation and upload-retry PASS");
}
#endif
