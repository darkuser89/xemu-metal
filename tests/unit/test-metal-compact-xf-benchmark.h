/* Paired native XF output traffic, with complete raster/feedback comparison.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_COMPACT_XF_BENCHMARK_H
#define TEST_METAL_COMPACT_XF_BENCHMARK_H
#import <objc/runtime.h>
static void (*compact_original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static double compact_gpu_seconds;
static void compact_feedback(id object, SEL selector,
                             MTL4CommitFeedbackHandler handler)
{
    compact_original_feedback(object, selector, ^(id<MTL4CommitFeedback> f) {
      compact_gpu_seconds = f.GPUEndTime - f.GPUStartTime;
      handler(f);
    });
}
static int compact_compare_time(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void compact_xf_benchmark(NV2AMetalCommands *commands,
                                 NV2AMetalEpochExecutor *executor)
{
    const NSUInteger count = 8192;
    NSMutableData *data =
        [NSMutableData dataWithLength:count * sizeof(NV2AMetalProgramInput)];
    NV2AMetalProgramInput *inputs = data.mutableBytes;
    for (NSUInteger v = 0; v < count; v++)
        for (unsigned a = 0; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                inputs[v].attributes[a][k] =
                    k == 3 ? 1 : (v % 17 + a + k) / 32.f;
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:data.bytes
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
    assert(source);
    Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
    assert(method);
    compact_original_feedback =
        (void *)method_setImplementation(method, (IMP)compact_feedback);
    NSError *error = nil;
    for (unsigned programmed = 0; programmed < 2; programmed++) {
        NV2AMetalPGRAPHVertexState *state = [[NV2AMetalPGRAPHVertexState alloc]
            initWithSnapshot:wire(5, programmed, 0)
                       error:&error];
        require(state != nil, error);
        double times[2][9];
        NSUInteger rawBytes[2] = { 0 };
        for (unsigned trial = 0; trial < 11; trial++) {
            NV2AMetalEpochResult *result[2];
            for (unsigned variant = 0; variant < 2; variant++) {
                unsigned compact = variant ^ (trial & 1);
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalEpochEncoding *encoded =
                    compact ? [executor encodeRasterState:state
                                          attributeBuffer:source
                                                    first:0
                                                    count:count
                                                 commands:commands
                                                    error:&error] :
                              [executor encodeState:state
                                    attributeBuffer:source
                                              first:0
                                              count:count
                                           commands:commands
                                              error:&error];
                require(encoded != nil, error);
                if (programmed) {
                    id program = [encoded valueForKey:@"program"];
                    id<MTLBuffer> raw = [program valueForKey:@"raw"];
                    rawBytes[compact] = raw.length;
                    assert(![program valueForKey:@"context"]);
                }
                finish(commands);
                result[compact] = [encoded resolveWithError:&error];
                require(result[compact] != nil, error);
                if (!programmed)
                    rawBytes[compact] = result[compact].registers.length;
                assert(compact_gpu_seconds > 0);
                if (trial >= 2)
                    times[compact][trial - 2] = compact_gpu_seconds;
            }
            assert(result[0].registers && !result[1].registers &&
                   [result[0].constants isEqual:result[1].constants] &&
                   [result[0].written isEqual:result[1].written] &&
                   !memcmp(result[0].vertices.contents,
                           result[1].vertices.contents,
                           count * sizeof(NV2AMetalVertex)));
        }
        assert(rawBytes[0] == count * sizeof(NV2AMetalProgramOutput));
        assert(rawBytes[1] == (programmed ? sizeof(uint32_t) : 0));
        qsort(times[0], 9, sizeof(double), compact_compare_time);
        qsort(times[1], 9, sizeof(double), compact_compare_time);
        printf("Compact XF %s:8192 vertices,11 exact pairs; raw/fault buffer "
               "bytes compact/full=%lu/%lu, "
               "GPU median compact/full=%.6f/%.6f ms (2 warmups,9 paired "
               "alternating samples)\n",
               programmed ? "readonly" : "fixed", (unsigned long)rawBytes[1],
               (unsigned long)rawBytes[0], times[1][4] * 1000,
               times[0][4] * 1000);
    }
    method_setImplementation(method, (IMP)compact_original_feedback);
}
#endif
