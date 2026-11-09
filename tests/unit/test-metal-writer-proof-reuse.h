/* Single constant admission before bound writer refinement.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_WRITER_PROOF_REUSE_H
#define TEST_METAL_WRITER_PROOF_REUSE_H

static BOOL reuse_reference, reuse_expected, reuse_write, reuse_pending;
static unsigned reuse_static_calls, reuse_constant_calls, reuse_fetch_calls;
static unsigned reuse_refine_calls, reuse_binding, reuse_dispatches;
static NSUInteger reuse_count, reuse_width;
static const float *reuse_constants;
static NV2AMetalProgramUniforms *reuse_mutate;
static BOOL (*reuse_static)(id, SEL, unsigned);
static BOOL (*reuse_constant)(id, SEL, unsigned, const float *);
static BOOL (*reuse_refine)(id, SEL, unsigned, const float *,
                            const NV2AMetalFetchUniforms *);
static BOOL (*reuse_fetch)(id, SEL, NV2AMetalFetchUniforms *, id, NSUInteger,
                           NSUInteger, id);
static id (*reuse_pipeline)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL, NSError **);
static void (*reuse_dispatch)(id, SEL, MTLSize, MTLSize);

static BOOL reuse_static_spy(id object, SEL selector, unsigned access)
{
    reuse_static_calls++;
    return !reuse_reference && reuse_static(object, selector, access);
}
static BOOL reuse_constant_spy(id object, SEL selector, unsigned access,
                               const float *constants)
{
    reuse_constant_calls++;
    reuse_constants = constants;
    return !reuse_reference &&
           reuse_constant(object, selector, access, constants);
}
static BOOL reuse_refine_spy(id object, SEL selector, unsigned access,
                             const float *constants,
                             const NV2AMetalFetchUniforms *sources)
{
    reuse_refine_calls++;
    assert(reuse_constant_calls == 1 && reuse_fetch_calls == 1 &&
           constants == reuse_constants && sources);
    BOOL allowed = !reuse_reference &&
                   reuse_refine(object, selector, access, constants, sources);
    if (reuse_mutate) {
        assert(constants != reuse_mutate->constants[0]);
        reuse_mutate->constants[120][0] = 4096;
        reuse_mutate = NULL;
    }
    return allowed;
}
static BOOL reuse_fetch_spy(id object, SEL selector,
                            NV2AMetalFetchUniforms *uniforms, id attributes,
                            NSUInteger first, NSUInteger count, id commands)
{
    reuse_fetch_calls++;
    assert(reuse_constant_calls == 1);
    return reuse_fetch(object, selector, uniforms,
                       reuse_binding == 1 ? nil : attributes,
                       reuse_binding == 2 ? NSUIntegerMax : first, count,
                       reuse_binding == 3 ? nil : commands);
}
static id reuse_pipeline_spy(id object, SEL selector, BOOL write, BOOL compact,
                             BOOL discard, BOOL chained, BOOL independent,
                             NSError **error)
{
    assert(write == reuse_write && independent == reuse_expected &&
           !reuse_pending);
    id<MTLComputePipelineState> pipeline = reuse_pipeline(
        object, selector, write, compact, discard, chained, independent, error);
    if (pipeline && write) {
        reuse_width = independent ? MIN(MAX(reuse_count, 1u),
                                        pipeline.threadExecutionWidth) :
                                    1;
        reuse_pending = YES;
    }
    return pipeline;
}
static void reuse_dispatch_spy(id object, SEL selector, MTLSize threads,
                               MTLSize group)
{
    if (reuse_pending) {
        assert(threads.width == (reuse_expected ? MAX(reuse_count, 1u) : 1) &&
               threads.height == 1 && threads.depth == 1 &&
               group.width == reuse_width && group.height == 1 &&
               group.depth == 1);
        reuse_pending = NO;
        reuse_dispatches++;
    }
    reuse_dispatch(object, selector, threads, group);
}
static void reuse_reset(BOOL reference, BOOL expected, BOOL write,
                        NSUInteger count)
{
    assert(!reuse_pending);
    reuse_reference = reference;
    reuse_expected = expected;
    reuse_write = write;
    reuse_count = count;
    reuse_static_calls = reuse_constant_calls = reuse_fetch_calls = 0;
    reuse_refine_calls = reuse_dispatches = 0;
    reuse_constants = NULL;
}
static NV2AMetalWritableEncoding *
reuse_encode(NV2AMetalWritableProgram *engine, NV2AMetalCommands *commands,
             NV2AMetalValidatedProgram *program,
             NV2AMetalProgramUniforms *uniforms, NV2AMetalFetchResult *fetch,
             NSUInteger count, BOOL write, BOOL raw,
             NV2AMetalWritableEncoding *previous)
{
    NSError *error = nil;
    NV2AMetalWritableEncoding *encoding;
    if (raw)
        encoding = [engine encodeTokens:program.tokens.bytes
                                 length:program.tokens.length / 16
                               uniforms:uniforms
                        attributeBuffer:fetch.attributes
                                  first:2
                                  count:count
                                 access:0
                            writeEnable:write
                              rasterize:YES
                       compactRegisters:NO
                               commands:commands
                                  error:&error];
    else if (previous)
        encoding = [engine encodeSerialProgram:program
                                      uniforms:uniforms
                               attributeBuffer:fetch.attributes
                                         first:2
                                         count:count
                                        access:0
                                     rasterize:YES
                                      previous:previous
                                attributeFetch:fetch
                                      commands:commands
                                         error:&error];
    else
        encoding = [engine encodeProgram:program
                                uniforms:uniforms
                         attributeBuffer:fetch.attributes
                                   first:2
                                   count:count
                                  access:0
                             writeEnable:write
                               rasterize:YES
                        compactRegisters:NO
                          attributeFetch:fetch
                                commands:commands
                                   error:&error];
    require(encoding != nil, error);
    assert(!reuse_pending);
    if (write)
        assert(reuse_dispatches == 1 &&
               ![encoding canUsePendingReadOnlyResultForCommands:commands]);
    independent_prefill(encoding);
    return encoding;
}
static void writer_proof_reuse_tests(NV2AMetalWritableProgram *engine,
                                     NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    require(fetch != nil, error);
    Token tokens[5];
    NV2AMetalValidatedProgram *staticProgram =
        independent_tokens(tokens, 150, 15, 100);
    NV2AMetalValidatedProgram *constant = captured_program(96, 150, 15, NO);
    NV2AMetalValidatedProgram *bound =
        attr_writer_program(96, 150, 15, 0, 0, NO);
    NV2AMetalValidatedProgram *feedback =
        attr_writer_program(96, 96, 8, 0, 0, NO);
    NV2AMetalValidatedProgram *addressFeedback =
        attr_writer_program(128, 120, 8, 0, 0, YES);
    NV2AMetalValidatedProgram *disjoint =
        attr_writer_program(128, 120, 4, 0, 0, YES);
    NV2AMetalValidatedProgram *scaled =
        attr_writer_program(128, 191, 15, 0, 0, YES);
    NV2AMetalProgramUniforms initial = uniforms();
    initial.constants[120][0] = 0x1p-10f;
    assert([staticProgram hasIndependentConstantWrites:0] &&
           ![constant hasIndependentConstantWrites:0] &&
           [constant hasIndependentConstantWrites:0
                                        constants:initial.constants[0]]);
    /* Public complete proof remains compatible even without a Fetch domain. */
    assert([constant hasIndependentConstantWrites:0
                                        constants:initial.constants[0]
                                   sourceUniforms:NULL]);
    require([commands beginWithError:&error] != nil, error);
    id encoder = [commands.commandBuffer computeCommandEncoder];
    Method dispatch = class_getInstanceMethod(
        object_getClass(encoder),
        @selector(dispatchThreads:threadsPerThreadgroup:));
    [encoder endEncoding];
    [commands cancel];
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
            NV2AMetalFetchResult.class,
            @selector(getReadonlyProofUniforms:attributeBuffer:first:count:
                      commands:)),
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:)),
        dispatch
    };
    IMP spies[] = { (IMP)reuse_static_spy,   (IMP)reuse_constant_spy,
                    (IMP)reuse_refine_spy,   (IMP)reuse_fetch_spy,
                    (IMP)reuse_pipeline_spy, (IMP)reuse_dispatch_spy };
    IMP originals[6];
    for (unsigned i = 0; i < 6; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], spies[i]);
    }
    reuse_static = (void *)originals[0];
    reuse_constant = (void *)originals[1];
    reuse_refine = (void *)originals[2];
    reuse_fetch = (void *)originals[3];
    reuse_pipeline = (void *)originals[4];
    reuse_dispatch = (void *)originals[5];
    NV2AMetalFetchResult *old = nil;
    unsigned pairs = 0;
    @try {
        for (unsigned test = 0; test < 18; test++) {
            @autoreleasepool {
                NV2AMetalProgramUniforms u = initial, snapshot = initial;
                NV2AMetalAttributeSource sources[16] = { 0 };
                sources[0].inline_value[3] = 1;
                sources[5].inline_value[0] = .25f;
                sources[5].inline_value[3] = 1;
                uint32_t bits[20] = { 0 };
                id<MTLBuffer> sourceBuffer = [commands.device
                    newBufferWithBytes:bits
                                length:sizeof(bits)
                               options:MTLResourceStorageModeShared];
                sources[15] = (NV2AMetalAttributeSource){
                    .buffer = sourceBuffer,
                    .format =
                        test == 4 ?
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F :
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                    .count = 1,
                    .stride = 4
                };
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalFetchResult *frozen = [fetch encodeSources:sources
                                                              count:20
                                                        firstVertex:0
                                                            indices:nil
                                                        indexOffset:0
                                                          indexSize:0
                                                      currentVertex:19
                                                           commands:commands
                                                              error:&error];
                require(frozen != nil, error);
                NV2AMetalValidatedProgram *program =
                    test == 0  ? staticProgram :
                    test == 1  ? constant :
                    test == 5  ? feedback :
                    test == 6  ? addressFeedback :
                    test == 7  ? disjoint :
                    test >= 16 ? scaled :
                                 bound;
                BOOL write = test != 13, raw = test == 14;
                NSUInteger count = test == 15 ? 0 : 17;
                reuse_binding = test >= 8 && test <= 10 ? test - 7 : 0;
                if (test == 11) {
                    assert(old);
                    frozen = old;
                }
                if (test == 17)
                    snapshot.constants[120][0] = u.constants[120][0] = 1024;
                NV2AMetalWritableEncoding *previous = nil;
                if (test == 12) {
                    reuse_reset(YES, NO, YES, count);
                    previous = reuse_encode(engine, commands, program, &u,
                                            frozen, count, YES, YES, nil);
                }
                BOOL expected = test <= 3 || test == 7 || test == 16;
                reuse_reset(NO, expected, write, count);
                reuse_mutate = test == 16 ? &u : NULL;
                NV2AMetalWritableEncoding *candidate =
                    reuse_encode(engine, commands, program, &u, frozen, count,
                                 write, raw, previous);
                unsigned numeric = write && !raw && !previous && test != 0;
                unsigned staticChecks = write && !raw ? 1u + numeric : 0u;
                unsigned binding = numeric && test > 1 && count;
                unsigned refinement = binding && !reuse_binding && test != 11;
                if (reuse_constant_calls != numeric ||
                    reuse_static_calls != staticChecks ||
                    reuse_fetch_calls != binding ||
                    reuse_refine_calls != refinement)
                    fprintf(stderr,
                            "Writer proof reuse case%u: constants%u/%u "
                            "static%u/%u binding%u/%u refinement%u/%u\n",
                            test, reuse_constant_calls, numeric,
                            reuse_static_calls, staticChecks, reuse_fetch_calls,
                            binding, reuse_refine_calls, refinement);
                assert(reuse_constant_calls == numeric &&
                       reuse_static_calls == staticChecks &&
                       reuse_fetch_calls == binding &&
                       reuse_refine_calls == refinement);
                assert(!reuse_mutate);
                reuse_binding = 0;
                reuse_reset(YES, NO, write, count);
                NV2AMetalWritableEncoding *reference =
                    reuse_encode(engine, commands, program, &snapshot, frozen,
                                 count, write, raw, previous);
                require([commands submitWithError:&error] &&
                            [commands waitUntilIdleWithError:&error],
                        error);
                independent_compare(candidate, reference);
                if (test == 10)
                    old = frozen;
                pairs++;
            }
        }
    } @finally {
        reuse_mutate = NULL;
        reuse_pending = NO;
        for (unsigned i = 0; i < 6; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    assert(pairs == 18);
    printf(
        "Writer proof reuse: %u serial GPU pairs; single constant query, "
        "lazy bound refinement, binding failures, previous/raw/empty/readonly "
        "guards and immutable upload PASS\n",
        pairs);
}
#endif
