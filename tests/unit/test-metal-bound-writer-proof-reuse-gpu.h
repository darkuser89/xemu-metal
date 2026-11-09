/* Bound-writer memoization versus its cold proof and serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BOUND_WRITER_PROOF_REUSE_GPU_H
#define TEST_METAL_BOUND_WRITER_PROOF_REUSE_GPU_H
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-types.h"

typedef struct BoundWriterGPUWork {
    BOOL forceMiss, independent, chained;
    NSUInteger evals, keys, pipelines, dispatches;
    MTLSize threads, group;
    NSUInteger executionWidth;
} BoundWriterGPUWork;
static _Thread_local BoundWriterGPUWork *bwg_work;
static NV2AMetalValidatedProgram *bwg_target;
static BOOL (*bwg_match_original)(id, SEL, const float *, const void *,
                                  NSData *);
static BOOL (*bwg_eval_original)(id, SEL, unsigned, const float *, void *);
static id (*bwg_key_original)(id, SEL, const void *, NSUInteger);
static id (*bwg_pipeline_original)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL,
                                   NSError **);
static void (*bwg_dispatch_original)(id, SEL, MTLSize, MTLSize);
static BOOL bwg_match(id owner, SEL selector, const float *constants,
                      const void *fetch, NSData *snapshot)
{
    return owner == bwg_target && bwg_work && bwg_work->forceMiss ?
               NO :
               bwg_match_original(owner, selector, constants, fetch, snapshot);
}
static BOOL bwg_eval(id owner, SEL selector, unsigned access,
                     const float *constants, void *fetch)
{
    if (owner == bwg_target && bwg_work)
        bwg_work->evals++;
    return bwg_eval_original(owner, selector, access, constants, fetch);
}
static id bwg_key(id owner, SEL selector, const void *bytes, NSUInteger length)
{
    if (owner == bwg_target && bwg_work) {
        assert(length == 4096);
        bwg_work->keys++;
    }
    return bwg_key_original(owner, selector, bytes, length);
}
static id bwg_pipeline(id owner, SEL selector, BOOL write, BOOL compact,
                       BOOL discard, BOOL chained, BOOL independent,
                       NSError **error)
{
    id<MTLComputePipelineState> result = bwg_pipeline_original(
        owner, selector, write, compact, discard, chained, independent, error);
    if (bwg_work && result) {
        bwg_work->pipelines++;
        bwg_work->independent = independent;
        bwg_work->chained = chained;
        bwg_work->executionWidth = result.threadExecutionWidth;
    }
    return result;
}
static void bwg_dispatch(id owner, SEL selector, MTLSize threads, MTLSize group)
{
    if (bwg_work) {
        bwg_work->dispatches++;
        bwg_work->threads = threads;
        bwg_work->group = group;
    }
    bwg_dispatch_original(owner, selector, threads, group);
}

static NV2AMetalFetchResult *bwg_fetch(NV2AMetalVertexFetch *fetch,
                                       NV2AMetalCommands *commands,
                                       unsigned kind, NSError **error)
{
    NV2AMetalAttributeSource sources[16] = { 0 };
    sources[0].inline_value[0] = sources[0].inline_value[1] = 1.5f;
    sources[0].inline_value[2] = 8;
    sources[0].inline_value[3] = 1;
    float colors[20][4];
    uint32_t address[20];
    for (unsigned i = 0; i < 20; i++) {
        colors[i][0] = 4096;
        colors[i][1] = (i + 1) / 32.f;
        colors[i][2] = (i + 1) / 64.f;
        colors[i][3] = 1;
        address[i] = kind == 1           ? 0x8000 :
                     kind == 2 && i >= 5 ? 255 :
                     kind == 3 && i >= 5 ? UINT32_C(0x7fc12345) :
                                           0;
    }
    id<MTLBuffer> colorBuffer =
        [commands.device newBufferWithBytes:colors
                                     length:sizeof(colors)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> addressBuffer =
        [commands.device newBufferWithBytes:address
                                     length:sizeof(address)
                                    options:MTLResourceStorageModeShared];
    assert(colorBuffer && addressBuffer);
    sources[5] = (NV2AMetalAttributeSource){
        .buffer = colorBuffer,
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .count = 4,
        .stride = 16
    };
    sources[15] = (NV2AMetalAttributeSource){
        .buffer = addressBuffer,
        .format = kind == 1 ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1 :
                  kind == 3 ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F :
                              NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
        .count = 1,
        .stride = 4
    };
    return [fetch encodeSources:sources
                          count:20
                    firstVertex:0
                        indices:nil
                    indexOffset:0
                      indexSize:0
                  currentVertex:18
                       commands:commands
                          error:error];
}
static NV2AMetalWritableEncoding *
bwg_encode(NV2AMetalWritableProgram *engine, NV2AMetalCommands *commands,
           NV2AMetalValidatedProgram *program,
           const NV2AMetalProgramUniforms *u, NV2AMetalFetchResult *input,
           NV2AMetalFetchResult *proof, NV2AMetalWritableEncoding *previous,
           unsigned access)
{
    NSError *error = nil;
    NV2AMetalWritableEncoding *result =
        previous ? [engine encodeSerialProgram:program
                                      uniforms:u
                               attributeBuffer:input.attributes
                                         first:2
                                         count:17
                                        access:access
                                     rasterize:YES
                                      previous:previous
                                attributeFetch:proof
                                      commands:commands
                                         error:&error] :
                   [engine encodeProgram:program
                                uniforms:u
                         attributeBuffer:input.attributes
                                   first:2
                                   count:17
                                  access:access
                             writeEnable:YES
                               rasterize:YES
                        compactRegisters:YES
                          attributeFetch:proof
                                commands:commands
                                   error:&error];
    require(result != nil, error);
    independent_prefill(result);
    return result;
}
static void bwg_triplet(NV2AMetalWritableProgram *engine,
                        NV2AMetalCommands *commands,
                        NV2AMetalVertexFetch *fetch,
                        NV2AMetalValidatedProgram *program, unsigned test)
{
    NSError *error = nil;
    NV2AMetalProgramUniforms u = uniforms();
    u.constants[120][0] = test == 4 ? 4096 : 1;
    u.constants[95][1] = .25f;
    u.constants[96][1] = -.75f;
    u.constants[97][1] = .125f;
    unsigned kind = test == 2              ? 3 :
                    test == 4              ? 2 :
                    test == 5 || test == 6 ? 1 :
                                             0;
    unsigned access = test == 6;
    BOOL allowed = test == 0 || test == 6 || test == 7;
    NSUInteger faultAt = test == 2 || test == 4 ? 3 : test == 5 ? 0 : 17;
    unsigned fault = test == 2    ? NV2AMetalProgramFaultAddressRange :
                     faultAt < 17 ? NV2AMetalProgramFaultConstantRange :
                                    0;
    NV2AMetalValidatedProgram *rootProgram = chain_root_program(test == 1);
    NV2AMetalFetchResult *cancelled = nil;
    if (test == 7) {
        require([commands beginWithError:&error] != nil, error);
        cancelled = bwg_fetch(fetch, commands, 0, &error);
        require(cancelled != nil, error);
        NV2AMetalWritableEncoding *root =
            bwg_encode(engine, commands, rootProgram, &u, cancelled, cancelled,
                       nil, access);
        (void)bwg_encode(engine, commands, program, &u, cancelled, cancelled,
                         root, access);
        [commands cancel];
    }
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalFetchResult *input = bwg_fetch(fetch, commands, kind, &error);
    require(input != nil, error);
    NV2AMetalFetchResult *foreignBinding =
        test == 2 ? bwg_fetch(fetch, commands, 0, &error) : nil;
    require(test != 2 || foreignBinding != nil, error);
    NV2AMetalWritableEncoding *root = bwg_encode(engine, commands, rootProgram,
                                                 &u, input, input, nil, access);
    NV2AMetalWritableEncoding *outputs[4];
    BoundWriterGPUWork work[4] = { 0 };
    bwg_target = program;
    for (unsigned trial = 0; trial < 4; trial++) {
        work[trial].forceMiss = trial == 2;
        bwg_work = &work[trial];
        NV2AMetalFetchResult *proof = trial == 3              ? nil :
                                      test == 2               ? foreignBinding :
                                      test == 7 && trial == 1 ? cancelled :
                                                                input;
        outputs[trial] = bwg_encode(engine, commands, program, &u, input, proof,
                                    root, access);
        bwg_work = NULL;
    }
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    /* GPU context/outputs and exact serial parity precede work counters. */
    for (unsigned trial = 0; trial < 3; trial++)
        independent_compare(outputs[trial], outputs[3]);
    const NV2AMetalWritableContext *rootContext =
        ((id<MTLBuffer>)[root valueForKey:@"context"]).contents;
    assert(rootContext->constants[96][1] == 19 / 32.f &&
           rootContext->constants[96][1] != u.constants[96][1]);
    if (test == 1)
        assert(rootContext->constants[120][0] == 4096 &&
               u.constants[120][0] == 1);
    for (unsigned trial = 0; trial < 4; trial++) {
        const NV2AMetalWritableContext *context =
            ((id<MTLBuffer>)[outputs[trial] valueForKey:@"context"]).contents;
        assert(context->fault == fault);
        id<MTLBuffer> vertices = [outputs[trial] valueForKey:@"vertices"];
        const NV2AMetalVertex *v = vertices.contents;
        for (unsigned i = 0; i < faultAt; i++) {
            float expected = test == 6      ? .25f :
                             test == 3 && i ? (i + 2) / 32.f :
                                              19 / 32.f;
            assert(v[i].color[0][0] == expected);
        }
        if (faultAt < 17) {
            NV2AMetalVertex zero = { 0 };
            assert(!memcmp(v + faultAt, &zero, sizeof(zero)));
            const uint8_t *bytes = vertices.contents;
            for (NSUInteger i = (faultAt + 1) * sizeof(zero);
                 i < vertices.length; i++)
                assert(bytes[i] == 0xa5);
            error = nil;
            assert(![outputs[trial] resolveWithError:&error] && error);
        } else {
            NV2AMetalWritableResult *result =
                [outputs[trial] resolveWithError:&error];
            require(result != nil, error);
            const uint32_t *written = result.written.bytes;
            assert(written[test == 3 ? 96 : 150] == 1);
            const float *constants = result.constants.bytes;
            assert(constants[(test == 3 ? 96 : 150) * 4 + 1] == 19 / 32.f);
        }
        BOOL eligible = allowed && trial != 3 && !(test == 7 && trial == 1);
        assert(work[trial].pipelines == 1 && work[trial].dispatches == 1 &&
               work[trial].chained && work[trial].independent == eligible);
        assert(work[trial].threads.width == (eligible ? 17u : 1u) &&
               work[trial].threads.height == 1 &&
               work[trial].threads.depth == 1 &&
               work[trial].group.width ==
                   (eligible ? MIN(17u, work[trial].executionWidth) : 1u) &&
               work[trial].group.height == 1 && work[trial].group.depth == 1);
        NSUInteger expectedEvals =
            trial == 3 || test == 1 || test == 2 || (test == 7 && trial != 2) ?
                0 :
            trial == 1 ? 0 :
                         1;
        assert(work[trial].evals == expectedEvals);
        assert(work[trial].keys ==
               (trial == 0 && test != 1 && test != 2 && test != 6 && test != 7 ?
                    1u :
                    0u));
    }
    bwg_target = nil;
}
static void bound_writer_proof_reuse_gpu_tests(NV2AMetalWritableProgram *engine,
                                               NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    require(fetch && [commands beginWithError:&error], error);
    id encoder = [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    Method dispatch = class_getInstanceMethod(
        object_getClass(encoder),
        @selector(dispatchThreads:threadsPerThreadgroup:));
    [encoder endEncoding];
    [commands cancel];
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            sel_registerName(
                "boundWriterProofConstants:fetchDomains:matchSnapshot:")),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            sel_registerName(
                "evaluateBoundWriterAccess:constants:fetchDomains:")),
        class_getInstanceMethod(
            NV2AMetalValidatedProgram.class,
            sel_registerName("boundWriterProofKeyWithBytes:length:")),
        class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                @selector(interpreterPipelineWithWrites:compact:
                                          discard:chained:independent:error:)),
        dispatch
    };
    IMP replacements[] = { (IMP)bwg_match, (IMP)bwg_eval, (IMP)bwg_key,
                           (IMP)bwg_pipeline, (IMP)bwg_dispatch },
        originals[5];
    for (unsigned i = 0; i < 5; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    bwg_match_original = (void *)originals[0];
    bwg_eval_original = (void *)originals[1];
    bwg_key_original = (void *)originals[2];
    bwg_pipeline_original = (void *)originals[3];
    bwg_dispatch_original = (void *)originals[4];
    for (unsigned i = 0; i < 5; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        NV2AMetalValidatedProgram *independent =
            attr_writer_program(96, 150, 15, 0, 1, YES);
        NV2AMetalValidatedProgram *hazard =
            attr_writer_program(96, 96, 4, 0, 1, YES);
        for (unsigned test = 0; test < 8; test++)
            bwg_triplet(engine, commands, fetch,
                        test == 3 ? hazard : independent, test);
    } @finally {
        for (unsigned i = 0; i < 5; i++)
            method_setImplementation(methods[i], originals[i]);
        bwg_work = NULL;
        bwg_target = nil;
    }
    puts("Bound writer memo GPU:8 cold/warm/forced-miss triplets plus serial "
         "references, real predecessor constants, hazard feedback, domain/"
         "access changes, late faults, fresh binding/provenance and cancel/"
         "retry exact context/Current/output/dispatch parity PASS");
}
#endif
