/* Independent constant stores versus the unchanged serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEPENDENT_WRITES_H
#define TEST_METAL_INDEPENDENT_WRITES_H
#import <objc/runtime.h>

static BOOL independent_reference, independent_expected, independent_pending;
static NSUInteger independent_count, independent_width;
static unsigned independent_parallel_draws, independent_serial_draws;
typedef id (*IndependentPipelineBuilder)(id, SEL, id, id, NSError **)
    __attribute__((ns_returns_retained));
static IndependentPipelineBuilder independent_builder;
static NSMutableDictionary<NSValue *, NSString *> *independent_names;
static _Thread_local BOOL independent_capture_names;
static BOOL (*independent_proof)(id, SEL, unsigned);
static BOOL (*independent_captured_proof)(id, SEL, unsigned, const float *);
static id (*independent_pipeline)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL,
                                  NSError **);
static void (*independent_dispatch)(id, SEL, MTLSize, MTLSize);
static id independent_build_spy(id object, SEL selector, id descriptor,
                                id options, NSError **error)
    __attribute__((ns_returns_retained));
static id independent_build_spy(id object, SEL selector, id descriptor,
                                id options, NSError **error)
{
    id pipeline =
        independent_builder(object, selector, descriptor, options, error);
    if (pipeline && independent_capture_names) {
        MTL4LibraryFunctionDescriptor *function =
            (MTL4LibraryFunctionDescriptor *)
                [descriptor computeFunctionDescriptor];
        independent_names[[NSValue
            valueWithPointer:(__bridge const void *)pipeline]] = function.name;
    }
    return pipeline;
}
static BOOL independent_proof_spy(id object, SEL selector, unsigned access)
{
    return !independent_reference &&
           independent_proof(object, selector, access);
}
static BOOL independent_captured_proof_spy(id object, SEL selector,
                                          unsigned access,
                                          const float *constants)
{
    return !independent_reference &&
           independent_captured_proof(object, selector, access, constants);
}
static id independent_pipeline_spy(id object, SEL selector, BOOL write,
                                   BOOL compact, BOOL discard, BOOL chained,
                                   BOOL independent, NSError **error)
{
    assert(write && independent == independent_expected &&
           !independent_pending);
    id<MTLComputePipelineState> pipeline;
    BOOL previousCaptureNames = independent_capture_names;
    independent_capture_names = YES;
    @try {
        pipeline = independent_pipeline(object, selector, write, compact,
                                        discard, chained, independent, error);
    } @finally {
        independent_capture_names = previousCaptureNames;
    }
    if (pipeline) {
        NSString *expected =
            independent ?
                (discard ? @"nv2a_independent_writable_raw_program" :
                 compact ? @"nv2a_independent_writable_raster_program" :
                           @"nv2a_independent_writable_program") :
            chained ? (discard ? @"nv2a_writable_chained_raw_program" :
                                 @"nv2a_writable_chained_raster_program") :
            discard ? @"nv2a_writable_raw_program" :
            compact ? @"nv2a_writable_raster_program" :
                      @"nv2a_writable_program";
        if (independent && chained)
            expected = [expected stringByAppendingString:@"_chained"];
        NSString *actual = independent_names[
            [NSValue valueWithPointer:(__bridge const void *)pipeline]];
        assert([actual isEqualToString:expected]);
        independent_width = independent ? MIN(independent_count,
                                              pipeline.threadExecutionWidth) :
                                          1;
        independent_pending = YES;
    }
    return pipeline;
}
static void independent_dispatch_spy(id object, SEL selector, MTLSize threads,
                                     MTLSize group)
{
    if (independent_pending) {
        assert(threads.width ==
                   (independent_expected ? independent_count : 1) &&
               threads.height == 1 && threads.depth == 1 &&
               group.width == independent_width && group.height == 1 &&
               group.depth == 1);
        independent_pending = NO;
        independent_parallel_draws += independent_expected;
        independent_serial_draws += !independent_expected;
    }
    independent_dispatch(object, selector, threads, group);
}

static NV2AMetalValidatedProgram *independent_tokens(Token tokens[5],
                                                     unsigned row,
                                                     unsigned mask,
                                                     unsigned readRow)
{
    tokens[0] = token(1, 0, 0);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(1, 0, 0);
    tokens[1].word[1] |= 4u << 9;
    source(&tokens[1], 0, 2, 0, 0xe4);
    destination(&tokens[1], row, mask, 0, 0, 0, 0);
    tokens[2] = token(0, 1, 0);
    tokens[2].word[1] |= 5u << 9;
    source(&tokens[2], 2, 2, 0, 0xe4);
    destination(&tokens[2], row, 15 ^ mask, 1, 0, 0, 0);
    tokens[3] = token(3, 0, readRow);
    tokens[3].word[1] |= 6u << 9;
    source(&tokens[3], 0, 3, 0, 0xe4);
    source(&tokens[3], 2, 2, 0, 0xe4);
    destination(&tokens[3], 130, 5, 0, 0, 0, 0);
    tokens[4] = token(1, 0, 0);
    tokens[4].word[1] |= 3u << 9;
    source(&tokens[4], 0, 2, 0, 0xe4);
    destination(&tokens[4], 0x103, 15, 0, 0, 0, 0);
    tokens[4].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:5
                                                    error:&error];
    require(program != nil, error);
    return program;
}

static void independent_compare(NV2AMetalWritableEncoding *a,
                                NV2AMetalWritableEncoding *b)
{
    for (NSString *key in @[ @"context", @"raw", @"vertices" ]) {
        id<MTLBuffer> x = [a valueForKey:key], y = [b valueForKey:key];
        assert(x.length == y.length &&
               (!x || !memcmp(x.contents, y.contents, x.length)));
    }
    NSError *ea = nil, *eb = nil;
    NV2AMetalWritableResult *x = [a resolveWithError:&ea],
                            *y = [b resolveWithError:&eb];
    assert(!!x == !!y && !!ea == !!eb);
    if (x)
        assert(x.vertexCount == y.vertexCount &&
               [x.constants isEqualToData:y.constants] &&
               [x.written isEqualToData:y.written]);
}
static void independent_prefill(NV2AMetalWritableEncoding *encoding)
{
    for (NSString *key in @[ @"context", @"raw", @"vertices" ]) {
        id<MTLBuffer> buffer = [encoding valueForKey:key];
        if (buffer)
            memset(buffer.contents, 0xa5, buffer.length);
    }
}
static void independent_expect(NV2AMetalValidatedProgram *program,
                               unsigned access, NSUInteger count,
                               BOOL reference)
{
    independent_reference = reference;
    independent_expected =
        !reference &&
        independent_proof(program, @selector(hasIndependentConstantWrites:),
                          access);
    independent_count = MAX(count, 1u);
}

static void independent_pair(NV2AMetalWritableProgram *engine,
                             NV2AMetalCommands *commands,
                             NV2AMetalValidatedProgram *program,
                             const NV2AMetalProgramUniforms *u,
                             id<MTLBuffer> input, unsigned count,
                             unsigned access, BOOL compact, BOOL raster)
{
    NSError *error = nil;
    NV2AMetalWritableEncoding *encodings[2];
    require([commands beginWithError:&error] != nil, error);
    for (unsigned reference = 0; reference < 2; reference++) {
        independent_expect(program, access, count, reference);
        independent_expected = !reference && independent_captured_proof(
            program, @selector(hasIndependentConstantWrites:constants:),
            access, &u->constants[0][0]);
        encodings[reference] = [engine encodeProgram:program
                                            uniforms:u
                                     attributeBuffer:input
                                               first:3
                                               count:count
                                              access:access
                                         writeEnable:YES
                                           rasterize:raster
                                    compactRegisters:compact
                                            commands:commands
                                               error:&error];
        require(encodings[reference] != nil, error);
        assert(!independent_pending);
        independent_prefill(encodings[reference]);
    }
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    independent_compare(encodings[0], encodings[1]);
}

static unsigned independent_chain_pairs(NV2AMetalWritableProgram *engine,
                                        NV2AMetalCommands *commands,
                                        id<MTLBuffer> input)
{
    unsigned pairs = 0;
    const unsigned counts[] = { 0, 1, 17 };
    for (unsigned mode = 0; mode < 3; mode++)
        for (unsigned access = 0; access < 2; access++)
            for (unsigned n = 0; n < 3; n++)
                for (unsigned raster = 0; raster < 2; raster++) {
                    NSError *error = nil;
                    Token ta[5], tb[5];
                    NV2AMetalValidatedProgram *a =
                        independent_tokens(ta, mode == 2 ? 95 : 150, 1, 120);
                    if (mode == 1) {
                        ta[1] = token(3, 0, 150);
                        ta[1].word[1] |= 4u << 9;
                        source(&ta[1], 0, 3, 0, 0xe4);
                        source(&ta[1], 2, 2, 0, 0xe4);
                        destination(&ta[1], 150, 1, 0, 0, 0, 0);
                        a = [[NV2AMetalValidatedProgram alloc]
                            initWithTokens:ta[0].word
                                    length:5
                                     error:&error];
                        require(a != nil, error);
                        assert(!independent_proof(
                            a, @selector(hasIndependentConstantWrites:),
                            access));
                    }
                    NV2AMetalValidatedProgram *b =
                        independent_tokens(tb, 151, 5, 150);
                    assert(independent_proof(
                        b, @selector(hasIndependentConstantWrites:), access));
                    NV2AMetalProgramUniforms u = uniforms(), stale = u;
                    u.constants[150][0] = 77.25f;
                    stale.constants[150][0] = -999.625f;
                    NV2AMetalWritableEncoding *first[2], *second[2];
                    require([commands beginWithError:&error] != nil, error);
                    for (unsigned reference = 0; reference < 2; reference++) {
                        independent_expect(a, access, 5, reference);
                        first[reference] = [engine encodeSerialProgram:a
                                                              uniforms:&u
                                                       attributeBuffer:input
                                                                 first:3
                                                                 count:5
                                                                access:access
                                                             rasterize:raster
                                                              previous:nil
                                                              commands:commands
                                                                 error:&error];
                        require(first[reference] != nil, error);
                        independent_prefill(first[reference]);
                        independent_expect(b, access, counts[n], reference);
                        second[reference] =
                            [engine encodeSerialProgram:b
                                               uniforms:&stale
                                        attributeBuffer:input
                                                  first:8
                                                  count:counts[n]
                                                 access:access
                                              rasterize:raster
                                               previous:first[reference]
                                               commands:commands
                                                  error:&error];
                        require(second[reference] != nil, error);
                        assert(!independent_pending);
                        independent_prefill(second[reference]);
                    }
                    require([commands submitWithError:&error] &&
                                [commands waitUntilIdleWithError:&error],
                            error);
                    independent_compare(first[0], first[1]);
                    independent_compare(second[0], second[1]);
                    pairs++;
                }
    return pairs;
}

#include "test-metal-component-writes.h"
#include "test-metal-dead-writes.h"
#include "test-metal-store-writes.h"
#include "test-metal-arl-writes.h"
#include "test-metal-captured-writes.h"

static void independent_write_tests(NV2AMetalWritableProgram *engine,
                                    NV2AMetalCommands *commands,
                                    unsigned only)
{
    BOOL componentsOnly = only == 1, deadOnly = only == 2, storesOnly = only == 3;
    BOOL arlOnly = only == 4;
    BOOL capturedOnly = only == 5;
    NSError *error = nil;
    engine = [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                        error:&error];
    require(engine != nil, error);
    require([commands beginWithError:&error] != nil, error);
    id<MTL4ComputeCommandEncoder> prototype =
        [commands.commandBuffer computeCommandEncoder];
    assert(prototype);
    Method dispatch = class_getInstanceMethod(
        object_getClass(prototype),
        @selector(dispatchThreads:threadsPerThreadgroup:));
    [prototype endEncoding];
    [commands cancel];
    Method proof =
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(hasIndependentConstantWrites:));
    Method capturedProof = class_getInstanceMethod(
        NV2AMetalValidatedProgram.class,
        @selector(hasIndependentConstantWrites:constants:));
    Method pipeline =
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:));
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    Method build = class_getInstanceMethod(
        object_getClass(compiler),
        @selector(
            newComputePipelineStateWithDescriptor:compilerTaskOptions:error:));
    assert(dispatch && proof && capturedProof && pipeline && build);
    independent_names = [NSMutableDictionary new];
    independent_builder = (void *)method_getImplementation(build);
    method_setImplementation(build, (IMP)independent_build_spy);
    independent_proof =
        (void *)method_setImplementation(proof, (IMP)independent_proof_spy);
    independent_captured_proof = (void *)method_setImplementation(
        capturedProof, (IMP)independent_captured_proof_spy);
    independent_pipeline = (void *)method_setImplementation(
        pipeline, (IMP)independent_pipeline_spy);
    independent_dispatch = (void *)method_setImplementation(
        dispatch, (IMP)independent_dispatch_spy);
    unsigned pairs = 0;
    @try {
        NV2AMetalProgramInput values[270];
        for (unsigned v = 0; v < 270; v++) {
            writable_input(&values[v], v);
            const uint32_t bits[] = { 0,          0x80000000, 1,
                                      0x807fffff, 0x7f800000, 0xff800000,
                                      0x7fc12345, 0x7fa12345, 0x3f800001,
                                      0xbf800001 };
            for (unsigned lane = 0; lane < 4; lane++) {
                memcpy(&values[v].attributes[4][lane], &bits[(v + lane) % 10],
                       4);
                memcpy(&values[v].attributes[5][lane],
                       &bits[(v * 3 + lane) % 10], 4);
            }
        }
        id<MTLBuffer> input =
            [commands.device newBufferWithBytes:values
                                         length:sizeof(values)
                                        options:MTLResourceStorageModeShared];
        assert(input);
        NV2AMetalProgramUniforms u = uniforms();
        for (unsigned row = 170; row < 186; row++)
            memcpy(u.constants[row], values[row].attributes[4], 16);
        if (!only) {
            const unsigned rows[] = { 58, 59, 95, 96, 191 };
            const unsigned counts[] = { 0, 1, 3, 17, 257 };
            for (unsigned access = 0; access < 2; access++)
                for (unsigned row = 0; row < 5; row++)
                    for (unsigned mask = 1; mask < 16; mask += 4)
                        for (unsigned n = 0; n < 5; n++)
                            for (unsigned compact = 0; compact < 2; compact++)
                                for (unsigned raster = 0; raster < 2;
                                     raster++) {
                                    Token tokens[5];
                                    NV2AMetalValidatedProgram *program =
                                        independent_tokens(tokens, rows[row],
                                                           mask, 120);
                                    assert(
                                        independent_proof(
                                            program,
                                            @selector(
                                                hasIndependentConstantWrites:),
                                            access) ==
                                        writable_allowed(access, rows[row]));
                                    independent_pair(engine, commands, program,
                                                     &u, input, counts[n],
                                                     access, compact, raster);
                                    pairs++;
                                }
            independent_reference = NO;
            for (unsigned mode = 0; mode < 5; mode++) {
                Token tokens[6];
                independent_tokens(tokens, 96, 1, mode == 0 ? 96 : 120);
                unsigned length = 5;
                if (mode == 1) {
                    tokens[4].word[3] &= ~1u;
                    tokens[5] = token(13, 0, 0);
                    source(&tokens[5], 0, 1, 0, 0xe4);
                    tokens[5].word[3] |= 1;
                    length = 6;
                } else if (mode == 2) {
                    tokens[3].word[1] &= ~(255u << 13);
                    tokens[3].word[1] |= 58u << 13;
                    tokens[3].word[3] |= 2u;
                } else if (mode == 3) {
                    tokens[0] = token(0, 0, 0);
                    destination(&tokens[0], 95, 15, 0, 0, 0, 0);
                } else if (mode == 4) {
                    tokens[5] = token(3, 0, 96);
                    source(&tokens[5], 0, 3, 0, 0xe4);
                    source(&tokens[5], 2, 2, 0, 0xe4);
                    destination(&tokens[5], 96, 15, 0, 0, 0, 0);
                    tokens[5].word[3] |= 1;
                    length = 6;
                }
                NV2AMetalValidatedProgram *control =
                    [[NV2AMetalValidatedProgram alloc]
                        initWithTokens:tokens[0].word
                                length:length
                                 error:&error];
                require(control != nil, error);
                for (unsigned access = 0; access < 2; access++) {
                    BOOL expected = mode >= 3 || mode == 1 ||
                                    (mode == 2 && access == 1);
                    assert(independent_proof(
                               control,
                               @selector(hasIndependentConstantWrites:),
                               access) == expected);
                    independent_pair(engine, commands, control, &u, input, 17,
                                     access, YES, YES);
                    pairs++;
                }
            }
            pairs += independent_chain_pairs(engine, commands, input);
        }
        if (!deadOnly && !storesOnly && !arlOnly && !capturedOnly)
            pairs += component_write_pairs(engine, commands, input, &u);
        if (!componentsOnly && !storesOnly && !arlOnly && !capturedOnly)
            pairs += dead_write_pairs(engine, commands, input, &u);
        if (!componentsOnly && !deadOnly && !arlOnly && !capturedOnly)
            pairs += store_write_pairs(engine, commands, input, &u);
        if (!only || arlOnly)
            pairs += arl_write_pairs(engine, commands, input, &u);
        if (!only || capturedOnly)
            pairs += captured_write_pairs(engine, commands, input, &u);
        assert(!memcmp(input.contents, values, sizeof(values)));
    } @finally {
        method_setImplementation(proof, (IMP)independent_proof);
        method_setImplementation(capturedProof, (IMP)independent_captured_proof);
        method_setImplementation(pipeline, (IMP)independent_pipeline);
        method_setImplementation(dispatch, (IMP)independent_dispatch);
        method_setImplementation(build, (IMP)independent_builder);
        independent_names = nil;
        independent_reference = independent_pending = NO;
    }
    assert(pairs == (componentsOnly ? 4120u : deadOnly ? 3736u :
                    storesOnly ? 9280u : arlOnly ? 7042u :
                    capturedOnly ? 2482u : 27506u) &&
           independent_parallel_draws && independent_serial_draws);
    printf("%s XF writes:%u serial-reference GPU pairs; %u parallel/%u serial "
           "dispatches, actual pipeline descriptors/grid sizes; %s PASS\n",
           componentsOnly ? "Component" : deadOnly ? "Dead temporary" :
           storesOnly ? "Overwritten store" : arlOnly ? "Bounded ARL" :
           capturedOnly ? "Captured" : "Independent", pairs,
           independent_parallel_draws, independent_serial_draws,
           capturedOnly ?
               "captured direct/relative/negated ARL,USER/FULL,data/control "
               "feedback,cache invalidation/narrowing,GPU previous guards,"
               "one proof/upload snapshot,actual pipeline/grid dispatches" :
           arlOnly ?
               "ten address ranges,USER/FULL/aperture boundaries,relative "
               "selector255,masked control/data feedback,paired incoming IDX,"
               "R12 source snapshots,unknown ARL faults,stale CPU/GPU chains" :
           storesOnly ?
               "all16 store/overwrite masks,11 outputs/six constant rows,"
               "packed Fog subsets,R12/oPos snapshots,paired output/temporary "
               "ordering,USER write faults,full/compact/raw/raster" :
           deadOnly ?
               "all16 overwrite/use masks,six swizzles,R0..R11,MAC/ILU stores,"
               "transitive/unused chains,self-update/paired snapshot controls,"
               "context stores,R12 publication,dead operand apertures,full/compact/raw/raster" :
           componentsOnly ?
               "all16 read/write masks,six swizzles,80 MAC/ILU/Fog/DOT/DST/"
               "scalar/paired-R1 cases,zero-result apertures,masked GPU "
               "predecessors with stale CPU uniforms,empty/suffix/raw/raster" :
               "USER/FULL,MAC/ILU masks,empty/first/suffix/full,compact/raw/"
               "raster,NaN/Inf/denormals,feedback/ARL/USER controls,masked "
               "component cases and GPU predecessor chains");
}
#endif
