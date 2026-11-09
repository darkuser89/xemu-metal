/* Capture-bound writer domains versus the serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CAPTURED_ATTRIBUTE_WRITES_H
#define TEST_METAL_CAPTURED_ATTRIBUTE_WRITES_H
static BOOL attr_writer_expected, attr_writer_pending;
static NSUInteger attr_writer_count, attr_writer_width;
static unsigned attr_writer_parallel, attr_writer_serial;
static id (*attr_writer_pipeline)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL,
                                  NSError **);
static void (*attr_writer_dispatch)(id, SEL, MTLSize, MTLSize);
static id attr_writer_pipeline_spy(id object, SEL selector, BOOL write,
                                   BOOL compact, BOOL discard, BOOL chained,
                                   BOOL independent, NSError **error)
{
    if (!write || independent != attr_writer_expected || attr_writer_pending)
        fprintf(stderr,
                "Bound writer pipeline: write%d compact%d discard%d chained%d "
                "selected%d expected%d pending%d count%lu\n",
                write, compact, discard, chained, independent,
                attr_writer_expected, attr_writer_pending,
                (unsigned long)attr_writer_count);
    assert(write && independent == attr_writer_expected &&
           !attr_writer_pending);
    id<MTLComputePipelineState> result = attr_writer_pipeline(
        object, selector, write, compact, discard, chained, independent, error);
    if (result) {
        attr_writer_width = independent ? MIN(MAX(attr_writer_count, 1u),
                                              result.threadExecutionWidth) :
                                          1;
        attr_writer_pending = YES;
    }
    return result;
}
static void attr_writer_dispatch_spy(id object, SEL selector, MTLSize threads,
                                     MTLSize group)
{
    if (attr_writer_pending) {
        assert(threads.width ==
                   (attr_writer_expected ? MAX(attr_writer_count, 1u) : 1) &&
               threads.height == 1 && threads.depth == 1 &&
               group.width == attr_writer_width);
        attr_writer_parallel += attr_writer_expected;
        attr_writer_serial += !attr_writer_expected;
        attr_writer_pending = NO;
    }
    attr_writer_dispatch(object, selector, threads, group);
}
static NV2AMetalValidatedProgram *
attr_writer_program(unsigned base, unsigned row, unsigned mask, unsigned lane,
                    unsigned readLane, BOOL scaled)
{
    Token t[6];
    unsigned n = 0;
    t[n] = token(1, 0, 0);
    source(&t[n], 0, 2, 0, 0xe4);
    destination(&t[n++], 0x100, 15, 0, 0, 0, 0);
    if (scaled) {
        t[n] = token(2, 0, 120);
        t[n].word[1] |= 15u << 9;
        source(&t[n], 0, 2, 0, 0x55 * lane);
        source(&t[n], 1, 3, 0, 0);
        destination(&t[n++], 0, 0, 0, 2, 8, 0);
    }
    t[n] = token(13, 0, 0);
    t[n].word[1] |= 15u << 9;
    source(&t[n], 0, scaled ? 1 : 2, scaled ? 2 : 0, scaled ? 0 : 0x55 * lane);
    destination(&t[n++], 0, 0, 0, 0, 0, 0);
    t[n] = token(1, 0, base);
    source(&t[n], 0, 3, 0, 0x55 * readLane);
    destination(&t[n], 0x103, 8, 0, 0, 0, 0);
    t[n++].word[3] |= 2;
    t[n] = token(1, 0, 0);
    t[n].word[1] |= 5u << 9;
    source(&t[n], 0, 2, 0, 0xe4);
    destination(&t[n++], row, mask, 0, 0, 0, 0);
    t[n] = token(0, 0, 0);
    return captured_tokens(t, n + 1);
}
static NV2AMetalWritableEncoding *attr_writer_encode(
    NV2AMetalWritableProgram *engine, NV2AMetalCommands *commands,
    NV2AMetalValidatedProgram *program, const NV2AMetalProgramUniforms *u,
    id<MTLBuffer> input, NSUInteger first, NSUInteger count, unsigned access,
    BOOL compact, BOOL raster, NV2AMetalFetchResult *fetch,
    NV2AMetalWritableEncoding *previous, BOOL expected)
{
    NSError *error = nil;
    attr_writer_expected = expected;
    attr_writer_count = count;
    NV2AMetalWritableEncoding *result =
        previous ? [engine encodeSerialProgram:program
                                      uniforms:u
                               attributeBuffer:input
                                         first:first
                                         count:count
                                        access:access
                                     rasterize:raster
                                      previous:previous
                                attributeFetch:fetch
                                      commands:commands
                                         error:&error] :
                   [engine encodeProgram:program
                                uniforms:u
                         attributeBuffer:input
                                   first:first
                                   count:count
                                  access:access
                             writeEnable:YES
                               rasterize:raster
                        compactRegisters:compact
                          attributeFetch:fetch
                                commands:commands
                                   error:&error];
    require(result != nil, error);
    assert(!attr_writer_pending &&
           ![result canUsePendingReadOnlyResultForCommands:commands]);
    independent_prefill(result);
    return result;
}
static BOOL (*attr_writer_snapshot_previous)(id, SEL, unsigned, const float *,
                                             const NV2AMetalFetchUniforms *);
static NV2AMetalProgramUniforms *attr_writer_caller;
static BOOL attr_writer_snapshot_spy(id object, SEL selector, unsigned access,
                                     const float *constants,
                                     const NV2AMetalFetchUniforms *sources)
{
    BOOL result = attr_writer_snapshot_previous(object, selector, access,
                                                constants, sources);
    if (attr_writer_caller) {
        attr_writer_caller->constants[120][0] = 4096;
        attr_writer_caller = NULL;
    }
    return result;
}
static unsigned attr_writer_source_queries;
static BOOL attr_writer_query_spy(id object, SEL selector, unsigned access,
                                  const float *constants,
                                  const NV2AMetalFetchUniforms *sources)
{
    attr_writer_source_queries++;
    return attr_writer_snapshot_previous(object, selector, access, constants,
                                         sources);
}
static void captured_attribute_write_tests(NV2AMetalWritableProgram *engine,
                                           NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    require(fetch != nil, error);
    enum {
        UB = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
        D3D = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
        S1 = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
        RAW = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
        F = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        CMP = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP
    };
    const struct WriterCase {
        unsigned format, bits, base, row, mask, lane, readLane, access;
        BOOL zeroStride, scaled, allowed, valid;
    } cases[] = {
        { UB, 255, 96, 150, 15, .allowed = YES, .valid = YES },
        { UB, 255, 191, 150, 15, .valid = NO },
        { D3D, 0xff001080, 96, 150, 15, .allowed = YES, .valid = YES },
        { D3D, 0xff001080, 96, 150, 15, .zeroStride = YES, .allowed = YES,
          .valid = YES },
        { S1, 0x8000, 97, 150, 15, .allowed = YES, .valid = YES },
        { S1, 0x8000, 96, 150, 15, .valid = NO },
        { S1, 0x8000, 96, 150, 15, .access = 1, .allowed = YES, .valid = YES },
        { CMP, 512u << 22, 98, 150, 15, .lane = 2, .allowed = YES,
          .valid = YES },
        { CMP, 512u << 22, 97, 150, 15, .lane = 2 },
        { CMP, 512u << 22, 97, 150, 15, .lane = 2, .zeroStride = YES,
          .allowed = YES, .valid = YES },
        { F, 0x3e800000, 96, 150, 15, .valid = YES },
        { F, 0x7fc12345, 96, 150, 15, .valid = NO },
        { F, 0x7fc12345, 190, 150, 15, .lane = 3, .allowed = YES,
          .valid = YES },
        { RAW, 0x8000, 128, 191, 15, .scaled = YES, .allowed = YES,
          .valid = YES },
        { UB, 255, 96, 96, 4, .allowed = YES, .valid = YES },
        { UB, 255, 96, 96, 8, .valid = YES },
        { UB, 255, 96, 96, 8, .readLane = 1, .allowed = YES, .valid = YES },
        { UB, 255, 128, 120, 8, .scaled = YES, .valid = YES },
        { UB, 255, 128, 120, 4, .scaled = YES, .allowed = YES, .valid = YES },
    };
    require([commands beginWithError:&error] != nil, error);
    Class cls = object_getClass(commands.commandBuffer);
    Method compute =
        class_getInstanceMethod(cls, @selector(computeCommandEncoder));
    id encoder = ((id (*)(id, SEL))method_getImplementation(compute))(
        commands.commandBuffer, @selector(computeCommandEncoder));
    require(encoder != nil, error);
    Class encoderClass = object_getClass(encoder);
    [encoder endEncoding];
    [commands cancel];
    Method pipeline =
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:));
    SEL dispatchSelector = @selector(dispatchThreads:threadsPerThreadgroup:);
    Method dispatch = class_getInstanceMethod(encoderClass, dispatchSelector);
    class_addMethod(encoderClass, dispatchSelector,
                    method_getImplementation(dispatch),
                    method_getTypeEncoding(dispatch));
    dispatch = class_getInstanceMethod(encoderClass, dispatchSelector);
    attr_writer_pipeline = (void *)method_setImplementation(
        pipeline, (IMP)attr_writer_pipeline_spy);
    attr_writer_dispatch = (void *)method_setImplementation(
        dispatch, (IMP)attr_writer_dispatch_spy);
    unsigned pairs = 0, acceptedDomains = 0;
    @try {
        for (unsigned test = 0; test < sizeof(cases) / sizeof(cases[0]); test++)
            for (unsigned layout = 0; layout < 3; layout++)
                @autoreleasepool {
                    const struct WriterCase *c = &cases[test];
                    NSUInteger count = 17;
                    NV2AMetalProgramUniforms u = uniforms();
                    u.constants[120][0] = c->scaled ? 0x1p-10f : 1;
                    NV2AMetalValidatedProgram *program =
                        attr_writer_program(c->base, c->row, c->mask, c->lane,
                                            c->readLane, c->scaled);
                    assert(
                        ![program hasIndependentConstantWrites:c->access] &&
                        ![program
                            hasIndependentConstantWrites:c->access
                                               constants:&u.constants[0][0]]);
                    uint32_t raw[24];
                    float colors[24][4];
                    for (unsigned n = 0; n < 24; n++) {
                        raw[n] = c->bits;
                        for (unsigned lane = 0; lane < 4; lane++)
                            colors[n][lane] = (float)(n + lane + 1) / 16;
                    }
                    id<MTLBuffer> sourceBuffer = [commands.device
                        newBufferWithBytes:raw
                                    length:sizeof(raw)
                                   options:MTLResourceStorageModeShared];
                    id<MTLBuffer> colorBuffer = [commands.device
                        newBufferWithBytes:colors
                                    length:sizeof(colors)
                                   options:MTLResourceStorageModeShared];
                    NV2AMetalAttributeSource sources[16] = { 0 };
                    sources[0].inline_value[3] = 1;
                    sources[5] =
                        (NV2AMetalAttributeSource){ .buffer = colorBuffer,
                                                    .format = F,
                                                    .count = 4,
                                                    .stride = 16 };
                    sources[15] = (NV2AMetalAttributeSource){
                        .buffer = sourceBuffer,
                        .format = c->format,
                        .count = c->format == D3D ? 4 : 1,
                        .stride = c->zeroStride ? 0 : 4,
                        .inline_value = { 0, 0, 0, 1 }
                    };
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalFetchResult *frozen = [fetch encodeSources:sources
                                                                  count:20
                                                            firstVertex:0
                                                                indices:nil
                                                            indexOffset:0
                                                              indexSize:0
                                                          currentVertex:19
                                                         skippingPrefix:0
                                                               commands:commands
                                                                  error:&error];
                    require(frozen != nil, error);
                    NV2AMetalFetchUniforms domains;
                    assert([frozen getReadonlyProofUniforms:&domains
                                            attributeBuffer:frozen.attributes
                                                      first:2
                                                      count:count
                                                   commands:commands]);
                    assert([program
                               hasIndependentConstantWrites:c->access
                                                  constants:&u.constants[0][0]
                                             sourceUniforms:&domains] ==
                           c->allowed);
                    acceptedDomains += c->allowed;
                    /* Original caller metadata can change after capture;
                     * admission must use the immutable Fetch snapshot, never
                     * this array. */
                    sources[15].format = F;
                    sources[15].inline_value[0] = 4096;
                    NV2AMetalWritableEncoding *candidate = attr_writer_encode(
                        engine, commands, program, &u, frozen.attributes, 2,
                        count, c->access, layout != 0, layout != 2, frozen, nil,
                        c->allowed);
                    NV2AMetalWritableEncoding *reference = attr_writer_encode(
                        engine, commands, program, &u, frozen.attributes, 2,
                        count, c->access, layout != 0, layout != 2, nil, nil,
                        NO);
                    require([commands submitWithError:&error] &&
                                [commands waitUntilIdleWithError:&error],
                            error);
                    independent_compare(candidate, reference);
                    NV2AMetalWritableResult *result =
                        [candidate resolveWithError:NULL];
                    assert(!!result == c->valid);
                    if (result && !c->scaled) {
                        const NV2AMetalProgramInput *last =
                            (const NV2AMetalProgramInput *)
                                frozen.attributes.contents +
                            18;
                        const float *final =
                            (const float *)result.constants.bytes + c->row * 4;
                        const uint32_t *dirty = result.written.bytes;
                        for (unsigned lane = 0; lane < 4; lane++)
                            assert(final[lane] ==
                                   (c->mask & (8u >> lane) ?
                                        last->attributes[5][lane] :
                                        u.constants[c->row][lane]));
                        assert(dirty[c->row]);
                        const NV2AMetalProgramInput *current =
                            (const NV2AMetalProgramInput *)
                                frozen.attributes.contents +
                            frozen.vertexCount;
                        assert(!memcmp(current->attributes[5], colors[19], 16));
                    }
                    assert(![frozen getReadonlyProofUniforms:&domains
                                             attributeBuffer:frozen.attributes
                                                       first:2
                                                       count:count
                                                    commands:commands]);
                    pairs++;
                }
        /* Binding, range and predecessor guards exercise the same safe program.
         */
        NV2AMetalProgramUniforms u = uniforms();
        NV2AMetalValidatedProgram *safe =
            attr_writer_program(96, 150, 15, 0, 0, NO);
        uint32_t bytes[24] = { 0 };
        memset(bytes, 0xff, sizeof(bytes));
        id<MTLBuffer> sourceBuffer =
            [commands.device newBufferWithBytes:bytes
                                         length:sizeof(bytes)
                                        options:MTLResourceStorageModeShared];
        NV2AMetalAttributeSource sources[16] = { 0 };
        sources[0].inline_value[3] = 1;
        sources[5].inline_value[0] = 2;
        sources[15] =
            (NV2AMetalAttributeSource){ .buffer = sourceBuffer,
                                        .format = UB,
                                        .count = 1,
                                        .stride = 4,
                                        .inline_value = { 0, 0, 0, 1 } };
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalFetchResult *frozen = [fetch encodeSources:sources
                                                      count:20
                                                firstVertex:0
                                                    indices:nil
                                                indexOffset:0
                                                  indexSize:0
                                              currentVertex:19
                                             skippingPrefix:0
                                                   commands:commands
                                                      error:&error];
        require(frozen != nil, error);
        NV2AMetalWritableEncoding *first[2], *second[2];
        for (unsigned reference = 0; reference < 2; reference++) {
            first[reference] = attr_writer_encode(
                engine, commands, safe, &u, frozen.attributes, 2, 17, 0, YES,
                YES, reference ? nil : frozen, nil, !reference);
            second[reference] = attr_writer_encode(
                engine, commands, safe, &u, frozen.attributes, 3, 7, 0, YES,
                YES, reference ? nil : frozen, first[reference], !reference);
        }
        NV2AMetalWritableEncoding *current = attr_writer_encode(
            engine, commands, safe, &u, frozen.attributes, frozen.vertexCount,
            1, 0, YES, YES, frozen, nil, YES);
        NV2AMetalWritableEncoding *currentRef = attr_writer_encode(
            engine, commands, safe, &u, frozen.attributes, frozen.vertexCount,
            1, 0, YES, YES, nil, nil, NO);
        NV2AMetalWritableEncoding *empty =
            attr_writer_encode(engine, commands, safe, &u, frozen.attributes, 0,
                               0, 0, YES, YES, frozen, nil, NO);
        NV2AMetalWritableEncoding *emptyRef =
            attr_writer_encode(engine, commands, safe, &u, frozen.attributes, 0,
                               0, 0, YES, YES, nil, nil, NO);
        NV2AMetalFetchUniforms proof;
        assert(![frozen getReadonlyProofUniforms:&proof
                                 attributeBuffer:frozen.attributes
                                           first:21
                                           count:1
                                        commands:commands]);
        id<MTLBuffer> foreign =
            [commands.device newBufferWithLength:frozen.attributes.length
                                         options:MTLResourceStorageModeShared];
        memset(foreign.contents, 0, foreign.length);
        NV2AMetalWritableEncoding *wrong =
            attr_writer_encode(engine, commands, safe, &u, foreign, 2, 17, 0,
                               YES, YES, frozen, nil, NO);
        NV2AMetalWritableEncoding *wrongRef =
            attr_writer_encode(engine, commands, safe, &u, foreign, 2, 17, 0,
                               YES, YES, nil, nil, NO);
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        independent_compare(first[0], first[1]);
        independent_compare(second[0], second[1]);
        independent_compare(current, currentRef);
        independent_compare(empty, emptyRef);
        independent_compare(wrong, wrongRef);
        pairs += 5;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalWritableEncoding *stale =
            attr_writer_encode(engine, commands, safe, &u, frozen.attributes, 2,
                               17, 0, YES, YES, frozen, nil, NO);
        NV2AMetalWritableEncoding *staleRef =
            attr_writer_encode(engine, commands, safe, &u, frozen.attributes, 2,
                               17, 0, YES, YES, nil, nil, NO);
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        independent_compare(stale, staleRef);
        pairs++;

        /* Written address lanes reject refinement, while a later child with
         * disjoint address inputs may refine and still inherit the GPU fault. */
        u.constants[120][0] = 0x1p-10f;
        sources[5].inline_value[0] = 4096;
        require([commands beginWithError:&error] != nil, error);
        frozen = [fetch encodeSources:sources
                                count:20
                          firstVertex:0
                              indices:nil
                          indexOffset:0
                            indexSize:0
                        currentVertex:19
                       skippingPrefix:0
                             commands:commands
                                error:&error];
        require(frozen != nil, error);
        NV2AMetalValidatedProgram *producer =
            attr_writer_program(96, 120, 8, 0, 0, NO);
        NV2AMetalValidatedProgram *gpuScaled =
            attr_writer_program(128, 191, 15, 0, 0, YES);
        assert([frozen getReadonlyProofUniforms:&proof
                                attributeBuffer:frozen.attributes
                                          first:2
                                          count:17
                                       commands:commands]);
        assert([gpuScaled hasIndependentConstantWrites:0
                                             constants:&u.constants[0][0]
                                        sourceUniforms:&proof]);
        Method query = class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(
                @"refineIndependentConstantWrites:constants:sourceUniforms:"));
        attr_writer_snapshot_previous =
            (void *)method_setImplementation(query, (IMP)attr_writer_query_spy);
        attr_writer_source_queries = 0;
        NV2AMetalWritableEncoding *third[2];
        @try {
            for (unsigned reference = 0; reference < 2; reference++) {
                first[reference] = attr_writer_encode(
                    engine, commands, producer, &u, frozen.attributes, 2, 17, 0,
                    YES, YES, reference ? nil : frozen, nil, !reference);
                unsigned before = attr_writer_source_queries;
                second[reference] = attr_writer_encode(
                    engine, commands, gpuScaled, &u, frozen.attributes, 2, 17,
                    0, YES, YES, reference ? nil : frozen, first[reference], NO);
                third[reference] = attr_writer_encode(
                    engine, commands, safe, &u, frozen.attributes, 2, 17, 0,
                    YES, YES, reference ? nil : frozen, second[reference], !reference);
                assert(attr_writer_source_queries == before + !reference);
            }
            assert(attr_writer_source_queries == 2);
        } @finally {
            method_setImplementation(query, (IMP)attr_writer_snapshot_previous);
        }
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        independent_compare(first[0], first[1]);
        independent_compare(second[0], second[1]);
        independent_compare(third[0], third[1]);
        NV2AMetalWritableResult *gpuInitial = [first[0] resolveWithError:NULL];
        assert(gpuInitial &&
               ((const float *)gpuInitial.constants.bytes)[120 * 4] == 4096);
        error = nil;
        assert(![second[0] resolveWithError:&error] && error);
        error = nil;
        assert(![third[0] resolveWithError:&error] && error);
        error = nil;
        pairs += 3;
        sources[5].inline_value[0] = 2;

        /* Index addition may use raw inline fallback even for normalized
         * data. A NaN fallback remains unproven despite these safe indices. */
        sources[15].stride = 0;
        sources[15].inline_value[0] = NAN;
        uint32_t zeroIndices[20] = { 0 };
        id<MTLBuffer> indexBuffer =
            [commands.device newBufferWithBytes:zeroIndices
                                         length:sizeof(zeroIndices)
                                        options:MTLResourceStorageModeShared];
        assert(indexBuffer);
        require([commands beginWithError:&error] != nil, error);
        frozen = [fetch encodeSources:sources
                                count:20
                          firstVertex:1
                              indices:indexBuffer
                          indexOffset:0
                            indexSize:4
                        currentVertex:19
                       skippingPrefix:0
                             commands:commands
                                error:&error];
        require(frozen != nil, error);
        NV2AMetalWritableEncoding *fallback =
            attr_writer_encode(engine, commands, safe, &u, frozen.attributes, 2,
                               17, 0, YES, YES, frozen, nil, NO);
        NV2AMetalWritableEncoding *fallbackRef =
            attr_writer_encode(engine, commands, safe, &u, frozen.attributes, 2,
                               17, 0, YES, YES, nil, nil, NO);
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        independent_compare(fallback, fallbackRef);
        pairs++;
        sources[15].stride = 4;
        sources[15].inline_value[0] = 0;

        require([commands beginWithError:&error] != nil, error);
        NV2AMetalFetchResult *cancelled = [fetch encodeSources:sources
                                                         count:20
                                                   firstVertex:0
                                                       indices:nil
                                                   indexOffset:0
                                                     indexSize:0
                                                 currentVertex:19
                                                skippingPrefix:0
                                                      commands:commands
                                                         error:&error];
        require(cancelled != nil, error);
        [commands cancel];
        require([commands beginWithError:&error] != nil, error);
        assert(![cancelled getReadonlyProofUniforms:&proof
                                    attributeBuffer:cancelled.attributes
                                              first:2
                                              count:17
                                           commands:commands]);
        frozen = [fetch encodeSources:sources
                                count:20
                          firstVertex:0
                              indices:nil
                          indexOffset:0
                            indexSize:0
                        currentVertex:19
                       skippingPrefix:0
                             commands:commands
                                error:&error];
        require(frozen != nil, error);
        assert([frozen getReadonlyProofUniforms:&proof
                                attributeBuffer:frozen.attributes
                                          first:2
                                          count:17
                                       commands:commands]);
        assert([safe hasIndependentConstantWrites:0
                                        constants:&u.constants[0][0]
                                   sourceUniforms:&proof]);
        proof.attributes[15].format = F;
        assert(![safe hasIndependentConstantWrites:0
                                         constants:&u.constants[0][0]
                                    sourceUniforms:&proof]);
        attr_writer_expected = YES;
        attr_writer_count = 17;
        NV2AMetalWritableEncoding *retried =
            [engine encodeSerialProgram:safe
                               uniforms:&u
                        attributeBuffer:frozen.attributes
                                  first:2
                                  count:17
                                 access:0
                              rasterize:YES
                               previous:nil
                         attributeFetch:frozen
                               commands:commands
                                  error:&error];
        require(retried != nil, error);
        independent_prefill(retried);
        attr_writer_expected = NO;
        NV2AMetalWritableEncoding *retryRef =
            [engine encodeSerialProgram:safe
                               uniforms:&u
                        attributeBuffer:frozen.attributes
                                  first:2
                                  count:17
                                 access:0
                              rasterize:YES
                               previous:nil
                               commands:commands
                                  error:&error];
        require(retryRef != nil, error);
        independent_prefill(retryRef);
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        independent_compare(retried, retryRef);
        pairs++;

        /* Prove/upload the same constant copy even if a caller changes its
         * original uniforms during admission. */
        require([commands beginWithError:&error] != nil, error);
        frozen = [fetch encodeSources:sources
                                count:20
                          firstVertex:0
                              indices:nil
                          indexOffset:0
                            indexSize:0
                        currentVertex:19
                       skippingPrefix:0
                             commands:commands
                                error:&error];
        require(frozen != nil, error);
        NV2AMetalValidatedProgram *scaled =
            attr_writer_program(128, 191, 15, 0, 0, YES);
        u.constants[120][0] = 0x1p-10f;
        NV2AMetalProgramUniforms caller = u;
        Method admission = class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(
                @"refineIndependentConstantWrites:constants:sourceUniforms:"));
        attr_writer_snapshot_previous = (void *)method_setImplementation(
            admission, (IMP)attr_writer_snapshot_spy);
        NV2AMetalWritableEncoding *snapshot;
        @try {
            attr_writer_caller = &caller;
            snapshot = attr_writer_encode(engine, commands, scaled, &caller,
                                          frozen.attributes, 2, 17, 0, YES, YES,
                                          frozen, nil, YES);
            assert(!attr_writer_caller && caller.constants[120][0] == 4096);
        } @finally {
            method_setImplementation(admission,
                                     (IMP)attr_writer_snapshot_previous);
            attr_writer_caller = NULL;
        }
        NV2AMetalWritableEncoding *snapshotRef =
            attr_writer_encode(engine, commands, scaled, &u, frozen.attributes,
                               2, 17, 0, YES, YES, nil, nil, NO);
        caller.constants[120][0] = 1024;
        NV2AMetalWritableEncoding *changed = attr_writer_encode(
            engine, commands, scaled, &caller, frozen.attributes, 2, 17, 0, YES,
            YES, frozen, nil, NO);
        NV2AMetalWritableEncoding *changedRef = attr_writer_encode(
            engine, commands, scaled, &caller, frozen.attributes, 2, 17, 0, YES,
            YES, nil, nil, NO);
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        independent_compare(snapshot, snapshotRef);
        independent_compare(changed, changedRef);
        pairs += 2;
    } @finally {
        method_setImplementation(pipeline, (IMP)attr_writer_pipeline);
        method_setImplementation(dispatch, (IMP)attr_writer_dispatch);
    }
    assert(pairs == 70 && acceptedDomains && attr_writer_parallel &&
           attr_writer_serial);
    printf("Capture-bound writer domains: %u serial GPU pairs/%u accepted "
           "domains; formats, CMP/D3D stride modes, lane feedback, "
           "offset/Current, stale binding, predecessor, changed captures and "
           "immutable upload PASS; writers retain completion feedback\n",
           pairs, acceptedDomains);
}
#endif
