/* GPU writer-chain provenance versus forced serial execution.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_WRITER_CHAIN_PROOF_H
#define TEST_METAL_WRITER_CHAIN_PROOF_H
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-types.h"

static BOOL chain_reference, chain_in_init;
static unsigned chain_baseline_copies, chain_admissions;
static BOOL (*chain_static)(id, SEL, unsigned);
static BOOL (*chain_constant)(id, SEL, unsigned, const float *);
static BOOL (*chain_refine)(id, SEL, unsigned, const float *,
                            const NV2AMetalFetchUniforms *);
static BOOL (*chain_admit)(id, SEL, id, const float *, id);
static id (*chain_data)(id, SEL, const void *, NSUInteger);
static id (*chain_init)(id, SEL, id, id, id,
                        const NV2AMetalWritableParameters *, BOOL, BOOL, id, id,
                        id);
static BOOL chain_static_spy(id object, SEL selector, unsigned access)
{
    return !chain_reference && chain_static(object, selector, access);
}
static BOOL chain_constant_spy(id object, SEL selector, unsigned access,
                               const float *constants)
{
    return !chain_reference &&
           chain_constant(object, selector, access, constants);
}
static BOOL chain_refine_spy(id object, SEL selector, unsigned access,
                             const float *constants,
                             const NV2AMetalFetchUniforms *sources)
{
    return !chain_reference &&
           chain_refine(object, selector, access, constants, sources);
}
static BOOL chain_admit_spy(id object, SEL selector, id program,
                            const float *constants, id commands)
{
    chain_admissions++;
    return !chain_reference &&
           chain_admit(object, selector, program, constants, commands);
}
static id chain_data_spy(id object, SEL selector, const void *bytes,
                         NSUInteger length)
{
    if (chain_in_init && length == 192 * 16)
        chain_baseline_copies++;
    return chain_data(object, selector, bytes, length);
}
static id chain_init_spy(id object, SEL selector, id raw, id vertices,
                         id context,
                         const NV2AMetalWritableParameters *parameters,
                         BOOL compact, BOOL readonly, id validated, id previous,
                         id commands)
{
    unsigned before = chain_baseline_copies;
    assert(!chain_in_init);
    chain_in_init = YES;
    id result = chain_init(object, selector, raw, vertices, context, parameters,
                           compact, readonly, validated, previous, commands);
    chain_in_init = NO;
    if (result && parameters->write_enable)
        assert(chain_baseline_copies - before == (previous ? 0u : 1u));
    return result;
}
static void chain_metadata(NV2AMetalWritableEncoding *encoding,
                           NSData *baseline, const uint8_t expected[192],
                           BOOL known)
{
    assert([encoding valueForKey:@"constants"] == baseline &&
           baseline.length == 192 * 16);
    assert([[encoding valueForKey:@"writerProvenanceKnown"] boolValue] ==
           known);
    Ivar ivar = class_getInstanceVariable(NV2AMetalWritableEncoding.class,
                                          "_cumulativeWrittenLanes");
    assert(ivar);
    NSUInteger bytes = 0;
    NSGetSizeAndAlignment(ivar_getTypeEncoding(ivar), &bytes, NULL);
    assert(bytes == 192);
    const uint8_t *actual =
        (const uint8_t *)(__bridge const void *)encoding + ivar_getOffset(ivar);
    for (unsigned row = 0; row < 192; row++)
        assert(actual[row] == (known ? expected[row] : 15));
}
static NV2AMetalValidatedProgram *chain_root_program(BOOL addressWrite)
{
    Token t[4];
    t[0] = token(1, 0, 0);
    source(&t[0], 0, 2, 0, 0xe4);
    destination(&t[0], 0x100, 15, 0, 0, 0, 0);
    for (unsigned i = 1; i < 3; i++) {
        t[i] = token(1, 0, 0);
        t[i].word[1] |= 5u << 9;
        source(&t[i], 0, 2, 0, 0xe4);
        destination(&t[i], i == 1 ? 96 : 120, i == 2 && addressWrite ? 8 : 4, 0,
                    0, 0, 0);
    }
    t[3] = token(0, 0, 0);
    return captured_tokens(t, 4);
}
static NV2AMetalFetchResult *chain_fetch(NV2AMetalVertexFetch *fetch,
                                         NV2AMetalCommands *commands,
                                         BOOL fault, NSError **error)
{
    NV2AMetalAttributeSource sources[16] = { 0 };
    sources[0].inline_value[3] = 1;
    sources[5].inline_value[0] = 4096;
    sources[5].inline_value[1] = .5f;
    sources[5].inline_value[2] = .75f;
    sources[5].inline_value[3] = 1;
    uint32_t bytes[20];
    for (unsigned i = 0; i < 20; i++)
        bytes[i] = fault && i < 5 ? 0 : 255;
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:bytes
                                     length:sizeof(bytes)
                                    options:MTLResourceStorageModeShared];
    sources[15] = (NV2AMetalAttributeSource){
        .buffer = buffer,
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
        .count = 1,
        .stride = 4
    };
    return [fetch encodeSources:sources
                          count:20
                    firstVertex:0
                        indices:nil
                    indexOffset:0
                      indexSize:0
                  currentVertex:19
                       commands:commands
                          error:error];
}
static NV2AMetalWritableEncoding *
chain_encode(NV2AMetalWritableProgram *engine, NV2AMetalCommands *commands,
             NV2AMetalValidatedProgram *program,
             const NV2AMetalProgramUniforms *uniforms,
             NV2AMetalFetchResult *fetch, NV2AMetalFetchResult *proof,
             NV2AMetalWritableEncoding *previous, NSUInteger count, BOOL raw,
             BOOL expected)
{
    if (!raw)
        return attr_writer_encode(engine, commands, program, uniforms,
                                  fetch.attributes, 2, count, 0, YES, YES,
                                  proof, previous, expected);
    assert(!previous && !expected);
    attr_writer_expected = NO;
    attr_writer_count = count;
    NSError *error = nil;
    NV2AMetalWritableEncoding *result =
        [engine encodeTokens:program.tokens.bytes
                      length:program.tokens.length / 16
                    uniforms:uniforms
             attributeBuffer:fetch.attributes
                       first:2
                       count:count
                      access:0
                 writeEnable:YES
                   rasterize:YES
            compactRegisters:YES
                    commands:commands
                       error:&error];
    require(result != nil, error);
    independent_prefill(result);
    return result;
}
static void chain_pair(NV2AMetalWritableProgram *engine,
                       NV2AMetalCommands *commands, NV2AMetalVertexFetch *fetch,
                       unsigned test)
{
    NSError *error = nil;
    NV2AMetalProgramUniforms u = uniforms(), childUniforms;
    u.constants[120][0] = 0x1p-10f;
    u.constants[96][1] = -13.25f;
    childUniforms = u;
    BOOL addressWrite = test == 1 || test == 8;
    BOOL raw = test == 4;
    NSUInteger count = test == 6 ? 0 : test == 7 ? 1 : 17;
    NV2AMetalValidatedProgram *root = chain_root_program(addressWrite);
    NV2AMetalValidatedProgram *child =
        attr_writer_program(96, 150, 15, 0, 1, YES);
    NV2AMetalValidatedProgram *third = captured_program(96, 151, 4, NO);
    if (test == 9) {
        NSMutableData *bytes = [third.tokens mutableCopy];
        Token *tokens = bytes.mutableBytes;
        tokens[1].word[1] = (tokens[1].word[1] & ~(255u << 13)) | (150u << 13);
        third =
            captured_tokens(tokens, (unsigned)(bytes.length / sizeof(Token)));
    }
    if (test == 2)
        childUniforms.constants[120][0] =
            nextafterf(u.constants[120][0], INFINITY);
    if (test == 3)
        childUniforms.constants[20][0] =
            nextafterf(u.constants[20][0], INFINITY);
    NV2AMetalFetchResult *stale = nil;
    if (test == 10) {
        require([commands beginWithError:&error] != nil, error);
        stale = chain_fetch(fetch, commands, NO, &error);
        require(stale != nil, error);
        [commands cancel];
    }
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalFetchResult *frozen =
        chain_fetch(fetch, commands, test == 8, &error);
    require(frozen != nil, error);
    NV2AMetalFetchResult *foreign = stale;
    if (test == 5) {
        foreign = chain_fetch(fetch, commands, NO, &error);
        require(foreign != nil, error);
    }
    NV2AMetalWritableEncoding *encodings[2][3];
    for (unsigned reference = 0; reference < 2; reference++) {
        chain_reference = reference;
        encodings[reference][0] =
            chain_encode(engine, commands, root, &u, frozen, frozen, nil, 17,
                         raw, !reference && !raw);
        BOOL allowed = !reference && !addressWrite && !raw && test != 2 &&
                       test != 5 && test != 10 && count;
        encodings[reference][1] = chain_encode(
            engine, commands, child, &childUniforms, frozen, foreign ?: frozen,
            encodings[reference][0], count, NO, allowed);
        encodings[reference][2] =
            chain_encode(engine, commands, third, &u, frozen, frozen,
                         encodings[reference][1], 17, NO,
                         !reference && !addressWrite && !raw && test != 9);
        NSData *baseline = [encodings[reference][0] valueForKey:@"constants"];
        uint8_t masks[192] = { 0 };
        masks[96] = 4;
        masks[120] = addressWrite ? 8 : 4;
        chain_metadata(encodings[reference][0], baseline, masks, !raw);
        masks[150] = 15;
        chain_metadata(encodings[reference][1], baseline, masks, !raw);
        masks[151] = 4;
        chain_metadata(encodings[reference][2], baseline, masks, !raw);
    }
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (unsigned hop = 0; hop < 3; hop++)
        independent_compare(encodings[0][hop], encodings[1][hop]);
    if (!addressWrite && count) {
        NV2AMetalWritableResult *result =
            [encodings[0][1] resolveWithError:&error];
        require(result != nil, error);
        const NV2AMetalVertex *vertices = result.vertices.contents;
        for (NSUInteger i = 0; i < count; i++)
            assert(vertices[i].color[0][0] == .5f);
        assert(u.constants[96][1] != .5f);
    }
    if (test == 8) {
        const NV2AMetalWritableContext *context =
            ((id<MTLBuffer>)[encodings[0][1] valueForKey:@"context"]).contents;
        assert(context->fault == NV2AMetalProgramFaultConstantRange);
        id<MTLBuffer> buffer = [encodings[0][1] valueForKey:@"vertices"];
        const NV2AMetalVertex *vertices = buffer.contents;
        for (unsigned i = 0; i < 3; i++)
            assert(vertices[i].color[0][0] == .5f);
        const uint8_t *bytes = buffer.contents;
        for (NSUInteger i = 4 * sizeof(NV2AMetalVertex); i < buffer.length; i++)
            assert(bytes[i] == 0xa5);
        buffer = [encodings[0][2] valueForKey:@"vertices"];
        bytes = buffer.contents;
        for (NSUInteger i = 0; i < buffer.length; i++)
            assert(bytes[i] == 0xa5);
        error = nil;
        assert(![encodings[0][1] resolveWithError:&error] && error);
        error = nil;
        assert(![encodings[0][2] resolveWithError:&error] && error);
    }
    if (test == 9) {
        const NV2AMetalWritableContext *context =
            ((id<MTLBuffer>)[encodings[0][2] valueForKey:@"context"]).contents;
        assert(context->fault == NV2AMetalProgramFaultConstantRange);
        id<MTLBuffer> buffer = [encodings[0][2] valueForKey:@"vertices"];
        const uint8_t *bytes = buffer.contents;
        for (NSUInteger i = sizeof(NV2AMetalVertex); i < buffer.length; i++)
            assert(bytes[i] == 0xa5);
    }
}
static void chain_lifetime_guards(NV2AMetalWritableProgram *engine,
                                  NV2AMetalCommands *commands,
                                  NV2AMetalVertexFetch *fetch)
{
    NSError *error = nil;
    NV2AMetalProgramUniforms u = uniforms();
    u.constants[120][0] = 0x1p-10f;
    u.constants[96][1] = -13.25f;
    NV2AMetalValidatedProgram *rootProgram = chain_root_program(NO);
    NV2AMetalValidatedProgram *childProgram =
        attr_writer_program(96, 150, 15, 0, 1, YES);
    chain_reference = NO;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalFetchResult *frozen = chain_fetch(fetch, commands, NO, &error);
    require(frozen != nil, error);
    __weak NV2AMetalWritableEncoding *weakRoot;
    NV2AMetalWritableEncoding *child;
    @autoreleasepool {
        NV2AMetalWritableEncoding *root =
            chain_encode(engine, commands, rootProgram, &u, frozen, frozen, nil,
                         17, NO, YES);
        weakRoot = root;
        child = chain_encode(engine, commands, childProgram, &u, frozen, frozen,
                             root, 17, NO, YES);
        assert(weakRoot);
    }
    assert(!weakRoot);
    NV2AMetalCommands *other =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(other && [other beginWithError:&error], error);
    error = nil;
    assert(![engine encodeSerialProgram:childProgram
                               uniforms:&u
                        attributeBuffer:frozen.attributes
                                  first:2
                                  count:17
                                 access:0
                              rasterize:YES
                               previous:child
                         attributeFetch:frozen
                               commands:other
                                  error:&error] &&
           error && !other.lastSubmitted);
    [other cancel];
    error = nil;
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    NV2AMetalWritableResult *result = [child resolveWithError:&error];
    require(result != nil, error);
    const NV2AMetalVertex *vertices = result.vertices.contents;
    assert(vertices[0].color[0][0] == .5f);
    require([commands beginWithError:&error] != nil, error);
    error = nil;
    assert(![engine encodeSerialProgram:childProgram
                               uniforms:&u
                        attributeBuffer:frozen.attributes
                                  first:2
                                  count:17
                                 access:0
                              rasterize:YES
                               previous:child
                         attributeFetch:frozen
                               commands:commands
                                  error:&error] &&
           error);
    [commands cancel];
    error = nil;
    require([commands beginWithError:&error] != nil, error);
    frozen = chain_fetch(fetch, commands, NO, &error);
    require(frozen != nil, error);
    NV2AMetalWritableEncoding *cancelled = chain_encode(
        engine, commands, rootProgram, &u, frozen, frozen, nil, 17, NO, YES);
    [commands cancel];
    require([commands beginWithError:&error] != nil, error);
    error = nil;
    assert(![engine encodeSerialProgram:childProgram
                               uniforms:&u
                        attributeBuffer:frozen.attributes
                                  first:2
                                  count:17
                                 access:0
                              rasterize:YES
                               previous:cancelled
                         attributeFetch:frozen
                               commands:commands
                                  error:&error] &&
           error);
    [commands cancel];
}
static void writer_chain_proof_tests(NV2AMetalWritableProgram *engine,
                                     NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    require(fetch != nil, error);
    require([commands beginWithError:&error] != nil, error);
    id encoder = [commands.commandBuffer computeCommandEncoder];
    Method dispatch = class_getInstanceMethod(
        object_getClass(encoder),
        @selector(dispatchThreads:threadsPerThreadgroup:));
    [encoder endEncoding];
    [commands cancel];
    Class dataClass = object_getClass(NSData.class);
    SEL dataSelector = @selector(dataWithBytes:length:);
    Method dataMethod = class_getInstanceMethod(dataClass, dataSelector);
    class_addMethod(dataClass, dataSelector,
                    method_getImplementation(dataMethod),
                    method_getTypeEncoding(dataMethod));
    dataMethod = class_getInstanceMethod(dataClass, dataSelector);
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(hasIndependentConstantWrites:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            @selector(hasIndependentConstantWrites:constants:)),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            NSSelectorFromString(
                @"refineIndependentConstantWrites:constants:sourceUniforms:")),
        class_getInstanceMethod(
            NV2AMetalWritableEncoding.class,
            NSSelectorFromString(
                @"canRefineConstantsForProgram:constants:commands:")),
        class_getInstanceMethod(
            NV2AMetalWritableEncoding.class,
            NSSelectorFromString(
                @"initRaw:vertices:context:parameters:compact:"
                @"faultFreeReadOnly:validatedProgram:previous:commands:")),
        dataMethod,
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:)),
        dispatch
    };
    IMP replacements[] = {
        (IMP)chain_static_spy,         (IMP)chain_constant_spy,
        (IMP)chain_refine_spy,         (IMP)chain_admit_spy,
        (IMP)chain_init_spy,           (IMP)chain_data_spy,
        (IMP)attr_writer_pipeline_spy, (IMP)attr_writer_dispatch_spy
    };
    IMP originals[8];
    for (unsigned i = 0; i < 8; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    chain_static = (void *)originals[0];
    chain_constant = (void *)originals[1];
    chain_refine = (void *)originals[2];
    chain_admit = (void *)originals[3];
    chain_init = (void *)originals[4];
    chain_data = (void *)originals[5];
    attr_writer_pipeline = (void *)originals[6];
    attr_writer_dispatch = (void *)originals[7];
    chain_admissions = chain_baseline_copies = 0;
    attr_writer_parallel = attr_writer_serial = 0;
    unsigned pairs = 0;
    @try {
        for (unsigned test = 0; test < 11; test++) {
            chain_pair(engine, commands, fetch, test);
            pairs += 3;
        }
        chain_lifetime_guards(engine, commands, fetch);
        /* Successful fresh recording after both GPU faults and cancellation. */
        chain_pair(engine, commands, fetch, 0);
        pairs += 3;
    } @finally {
        for (unsigned i = 0; i < 8; i++)
            method_setImplementation(methods[i], originals[i]);
        chain_reference = chain_in_init = NO;
    }
    assert(pairs == 36 && chain_admissions && attr_writer_parallel &&
           attr_writer_serial);
    printf("Writer chain proof: %u forced-serial GPU pairs; real predecessor "
           "colors, three-hop cumulative 192B lane masks/shared baseline/zero "
           "child 3KB copies, same-row disjoint lanes, overwritten address "
           "lanes/host-bit/foreign-Fetch/raw/empty guards, first range fault "
           "and untouched tails PASS\n",
           pairs);
}
#endif
