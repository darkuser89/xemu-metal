/* Real PGRAPH chain versus existing synchronous fallback; no app or VM.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_WRITABLE_SUBMIT_BENCHMARK_H
#define TEST_METAL_WRITABLE_SUBMIT_BENCHMARK_H
#include <time.h>
#import <objc/runtime.h>
@interface WritableSubmitSample : NSObject
@property(nonatomic) unsigned submits, waits, begins, captures, denied,
    serialEpochs;
@property(nonatomic) unsigned feedbacks, timedFeedbacks;
@property(nonatomic) double drawSeconds, waitSeconds, beginSeconds,
    retireSeconds, gpuSeconds;
@end
@implementation WritableSubmitSample
@end
@interface WritableSubmitFeedbackToken : NSObject
@property(nonatomic, strong) WritableSubmitSample *sample;
@property(nonatomic) uintptr_t optionsIdentity;
@property(nonatomic) BOOL recorded;
@end
@implementation WritableSubmitFeedbackToken
@end
static WritableSubmitSample *submit_sample;
static WritableSubmitFeedbackToken *submit_feedback_token;
static BOOL submit_synchronous, submit_deny_capture;
static double submit_now(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec + t.tv_nsec / 1e9;
}
typedef id (*SubmitCaptureIMP)(id __attribute__((ns_consumed)), SEL,
                               PGRAPHState *, NSError **)
    __attribute__((ns_returns_retained));
static SubmitCaptureIMP submit_original_capture;
static id submit_capture(id object __attribute__((ns_consumed)), SEL selector,
                         PGRAPHState *pg, NSError **error)
    __attribute__((ns_returns_retained));
static id submit_capture(id object __attribute__((ns_consumed)), SEL selector,
                         PGRAPHState *pg, NSError **error)
{
    if (submit_sample) {
        submit_sample.captures++;
        if (submit_synchronous && submit_deny_capture) {
            submit_deny_capture = NO;
            submit_sample.denied++;
            if (error)
                *error = nil;
            /* Test only: reach the existing fetch-first synchronous fallback.
             * The real post-Fetch capture below still validates the state. */
            return nil;
        }
    }
    return submit_original_capture(object, selector, pg, error);
}
static BOOL (*submit_original_submit)(id, SEL, NSError **);
static BOOL submit_count(id object, SEL selector, NSError **error)
{
    if (!submit_sample)
        return submit_original_submit(object, selector, error);
    submit_sample.submits++;
    assert(!submit_feedback_token);
    WritableSubmitFeedbackToken *token = [WritableSubmitFeedbackToken new];
    token.sample = submit_sample;
    submit_feedback_token = token;
    BOOL result = submit_original_submit(object, selector, error);
    submit_feedback_token = nil;
    return result;
}
static id<MTL4CommandBuffer> (*submit_original_begin)(id, SEL, NSError **);
static id<MTL4CommandBuffer> submit_begin(id object, SEL selector,
                                          NSError **error)
{
    double t = submit_now();
    id<MTL4CommandBuffer> result =
        submit_original_begin(object, selector, error);
    if (submit_sample) {
        submit_sample.begins++;
        submit_sample.beginSeconds += submit_now() - t;
    }
    return result;
}
static BOOL (*submit_original_idle)(id, SEL, NSError **);
static BOOL submit_idle(id object, SEL selector, NSError **error)
{
    double t = submit_now();
    BOOL result = submit_original_idle(object, selector, error);
    if (submit_sample) {
        submit_sample.waits++;
        submit_sample.waitSeconds += submit_now() - t;
    }
    return result;
}
static BOOL (*submit_original_wait)(id, SEL, NV2AMetalSubmission *, NSError **);
static BOOL submit_wait(id object, SEL selector,
                        NV2AMetalSubmission *submission, NSError **error)
{
    double t = submit_now();
    BOOL result = submit_original_wait(object, selector, submission, error);
    if (submit_sample) {
        submit_sample.waits++;
        submit_sample.waitSeconds += submit_now() - t;
    }
    return result;
}
static NV2AMetalEpochResult *(*submit_original_epoch)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NSError **);
static NV2AMetalEpochResult *submit_epoch(id object, SEL selector,
                                          NV2AMetalPGRAPHVertexState *captured,
                                          id<MTLBuffer> input, NSUInteger first,
                                          NSUInteger count, NSError **error)
{
    if (submit_sample)
        submit_sample.serialEpochs++;
    return submit_original_epoch(object, selector, captured, input, first,
                                 count, error);
}
static void (*submit_original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static void submit_feedback(id object, SEL selector,
                            MTL4CommitFeedbackHandler handler)
{
    WritableSubmitFeedbackToken *token = submit_feedback_token;
    if (!token) {
        submit_original_feedback(object, selector, handler);
        return;
    }
    uintptr_t identity = (uintptr_t)(__bridge void *)object;
    if (!token.optionsIdentity)
        token.optionsIdentity = identity;
    if (token.optionsIdentity != identity) {
        submit_original_feedback(object, selector, handler);
        return;
    }
    WritableSubmitSample *sample = token.sample;
    submit_original_feedback(object, selector, ^(id<MTL4CommitFeedback> f) {
      @synchronized(sample) {
          /* Validation can attach another handler to the same options.
           * Account for the submission once and preserve every handler. */
          if (!token.recorded) {
              token.recorded = YES;
              sample.feedbacks++;
              double duration = f.GPUEndTime - f.GPUStartTime;
              if (f.GPUStartTime > 0 && duration > 0) {
                  sample.timedFeedbacks++;
                  sample.gpuSeconds += duration;
              }
          }
      }
      handler(f);
    });
}
static NSDictionary *submit_result(WritableSubmitSample *s)
{
    return @{
        @"submits" : @(s.submits),
        @"wait_calls" : @(s.waits),
        @"begins" : @(s.begins),
        @"capture_calls" : @(s.captures),
        @"denied_prefetch_captures" : @(s.denied),
        @"synchronous_epoch_calls" : @(s.serialEpochs),
        @"feedbacks" : @(s.feedbacks),
        @"timed_gpu_feedbacks" : @(s.timedFeedbacks),
        @"draw_ms" : @(s.drawSeconds * 1e3),
        @"wait_api_ms" : @(s.waitSeconds * 1e3),
        @"begin_api_ms" : @(s.beginSeconds * 1e3),
        @"draw_and_retire_ms" : @(s.retireSeconds * 1e3),
        @"timed_gpu_sum_ms" : @(s.gpuSeconds * 1e3)
    };
}
static double submit_median(NSArray<NSDictionary *> *samples, NSString *key)
{
    NSArray *sorted = [[samples valueForKey:key]
        sortedArrayUsingSelector:@selector(compare:)];
    assert(sorted.count == 9);
    return [sorted[4] doubleValue];
}
static NSDictionary *submit_medians(NSArray<NSDictionary *> *samples)
{
    NSMutableDictionary *medians = [NSMutableDictionary new];
    for (NSString *key in @[
             @"draw_ms", @"wait_api_ms", @"begin_api_ms", @"draw_and_retire_ms",
             @"timed_gpu_sum_ms"
         ])
        medians[key] = @(submit_median(samples, key));
    return medians;
}
static void writable_submit_benchmark(BOOL nonwriting)
{
    Method capture = class_getInstanceMethod(NV2AMetalPGRAPHVertexState.class,
                                             @selector(initWithState:error:));
    Method begin = class_getInstanceMethod(NV2AMetalCommands.class,
                                           @selector(beginWithError:));
    Method submit = class_getInstanceMethod(NV2AMetalCommands.class,
                                            @selector(submitWithError:));
    Method idle = class_getInstanceMethod(NV2AMetalCommands.class,
                                          @selector(waitUntilIdleWithError:));
    Method wait = class_getInstanceMethod(NV2AMetalCommands.class,
                                          @selector(waitForSubmission:error:));
    Method epoch = class_getInstanceMethod(
        NV2AMetalEpochExecutor.class,
        @selector(executeRasterState:attributeBuffer:first:count:error:));
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    assert(capture && begin && submit && idle && wait && epoch && feedback);
    submit_original_capture =
        (void *)method_setImplementation(capture, (IMP)submit_capture);
    submit_original_begin =
        (void *)method_setImplementation(begin, (IMP)submit_begin);
    submit_original_submit =
        (void *)method_setImplementation(submit, (IMP)submit_count);
    submit_original_idle =
        (void *)method_setImplementation(idle, (IMP)submit_idle);
    submit_original_wait =
        (void *)method_setImplementation(wait, (IMP)submit_wait);
    submit_original_epoch =
        (void *)method_setImplementation(epoch, (IMP)submit_epoch);
    submit_original_feedback =
        (void *)method_setImplementation(feedback, (IMP)submit_feedback);
    NSMutableArray *workloads = [NSMutableArray new];
    unsigned exactPairs = 0;
    for (unsigned perRange = 3; perRange <= 63; perRange += 60)
        for (unsigned ranges = 1; ranges <= 16; ranges *= 4) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
            pg->enable_vertex_program_write = true;
            pg->zpass_pixel_count_enable = true;
            pg->dma_report = 64;
            feedback_program(191, 15);
            if (nonwriting) {
                mov(0, 0, 0, false);
                mov(1, 3, 3, true);
            }
            pg->draw_arrays_length = ranges;
            float positions[1008][4];
            for (unsigned v = 0; v < ranges * perRange; v++) {
                const float p[3][4] = { { 0, 0, 32768, 1 },
                                        { 8, 0, 32768, 1 },
                                        { 0, 8, 32768, 1 } };
                memcpy(positions[v], p[v % 3], 16);
            }
            for (unsigned i = 0; i < ranges; i++) {
                pg->draw_arrays_start[i] = i * perRange;
                pg->draw_arrays_count[i] = perRange;
            }
            dma[2].limit = ranges * perRange * 16 - 1;
            cpu_write(16384, ranges * perRange * 16);
            memcpy(state->vram_ptr + 16384, positions, ranges * perRange * 16);
            if (nonwriting) {
                /* Admit optional specialization and finish it outside timing.
                 * Production draws themselves never wait for compilation. */
                for (unsigned warm = 0; warm < 4; warm++) {
                    render();
                    read_vram(1024, 256);
                }
                id program =
                    [[draw valueForKey:@"epoch"] valueForKey:@"program"];
                Ivar field = class_getInstanceVariable([program class],
                                                       "_specializationQueue");
                assert(field);
                dispatch_queue_t queue = object_getIvar(program, field);
                dispatch_sync(queue, ^{
                              });
                assert([[program valueForKey:@"specializationSuccesses"]
                    unsignedIntegerValue]);
            }
            NSMutableArray *measurements[2] = { [NSMutableArray new],
                                                [NSMutableArray new] };
            unsigned referenceSubmits = 0, referenceWaits = 0,
                     nativeSubmits = 0;
            unsigned nativeTimed = 0, referenceTimed = 0;
            for (unsigned trial = 0; trial < 11; trial++) {
                NSData *images[2], *constants[2], *dirty[2], *current[2],
                    *pending[2];
                uint32_t samples[2];
                for (unsigned pass = 0; pass < 2; pass++) {
                    @autoreleasepool {
                        unsigned reference = pass ^ (trial & 1);
                        NSError *error = nil;
                        cpu_write(1024, 256);
                        for (unsigned k = 0; k < 64; k++)
                            stl_le_p(state->vram_ptr + 1024 + k * 4,
                                     0xffff0000);
                        for (unsigned k = 0; k < 4; k++) {
                            float initial = 10 * (k + 1);
                            memcpy(&pg->vsh_constants[191][k], &initial, 4);
                        }
                        memset(pg->vsh_constants_dirty, 0,
                               sizeof(pg->vsh_constants_dirty));
                        pg->draw_time = 0;
                        qemu_mutex_lock(&pg->lock);
                        [draw.reports clear];
                        require([draw.reports processWithError:&error], error);
                        require(
                            [surfaces.cache submitWithError:&error] &&
                                [surfaces.cache waitUntilIdleWithError:&error],
                            error);
                        WritableSubmitSample *result =
                            [WritableSubmitSample new];
                        submit_synchronous = reference;
                        submit_deny_capture = YES;
                        submit_sample = result;
                        double t = submit_now();
                        require([draw drawWithError:&error], error);
                        require([surfaces.cache submitWithError:&error], error);
                        result.drawSeconds = submit_now() - t;
                        submit_sample = nil;
                        assert(pg->draw_time == 1 &&
                               !surfaces.cache.commands.commandBuffer);
                        require([surfaces.cache waitUntilIdleWithError:&error],
                                error);
                        result.retireSeconds = submit_now() - t;
                        if (!(result.denied == reference &&
                              result.captures == 2 &&
                              result.serialEpochs == (reference ? ranges : 0) &&
                              result.begins == result.submits &&
                              result.feedbacks == result.submits)) {
                            fprintf(stderr,
                                    "Submit observer:ranges%u vertices%u "
                                    "reference%u trial%u denied%u captures%u "
                                    "epochs%u begins%u submits%u feedbacks%u\n",
                                    ranges, perRange, reference, trial,
                                    result.denied, result.captures,
                                    result.serialEpochs, result.begins,
                                    result.submits, result.feedbacks);
                        }
                        assert(result.denied == reference &&
                               result.captures == 2 &&
                               result.serialEpochs ==
                                   (reference ? ranges : 0) &&
                               result.begins == result.submits &&
                               result.feedbacks == result.submits);
                        if (reference) {
                            referenceSubmits = result.submits;
                            referenceWaits = result.waits;
                            referenceTimed = result.timedFeedbacks;
                            assert(result.submits == ranges + 3 &&
                                   result.waits == ranges + 1);
                        } else {
                            nativeSubmits = result.submits;
                            nativeTimed = result.timedFeedbacks;
                            assert(result.submits == 2 && result.waits == 1);
                        }
                        expect_context(191, 15, ranges * perRange, !nonwriting);
                        constants[reference] =
                            [NSData dataWithBytes:pg->vsh_constants
                                           length:sizeof(pg->vsh_constants)];
                        dirty[reference] = [NSData
                            dataWithBytes:pg->vsh_constants_dirty
                                   length:sizeof(pg->vsh_constants_dirty)];
                        current[reference] = [NSData
                            dataWithBytes:pg->vertex_attributes
                                   length:sizeof(pg->vertex_attributes)];
                        pending[reference] =
                            [draw pendingSnapshotWithError:&error];
                        require(pending[reference] != nil, error);
                        require([draw.reports getReport:1u << 24
                                                  error:&error] &&
                                    [draw.reports processWithError:&error],
                                error);
                        samples[reference] = reported;
                        assert(samples[reference]);
                        qemu_mutex_unlock(&pg->lock);
                        read_vram(1024, 256);
                        images[reference] =
                            [NSData dataWithBytes:state->vram_ptr + 1024
                                           length:256];
                        color(1, 1, 0xff00ff00);
                        color(7, 7, 0xffff0000);
                        if (trial >= 2)
                            [measurements[reference]
                                addObject:submit_result(result)];
                    }
                }
                assert([images[0] isEqual:images[1]] &&
                       [constants[0] isEqual:constants[1]] &&
                       [dirty[0] isEqual:dirty[1]] &&
                       [current[0] isEqual:current[1]] &&
                       [pending[0] isEqual:pending[1]] &&
                       samples[0] == samples[1]);
                exactPairs++;
            }
            [workloads addObject:@{
                @"nonwriting" : @(nonwriting),
                @"ranges" : @(ranges),
                @"vertices_per_range" : @(perRange),
                @"native_submits_waits" : @[ @(nativeSubmits), @1 ],
                @"reference_submits_waits" :
                    @[ @(referenceSubmits), @(referenceWaits) ],
                @"timed_gpu_feedbacks_native_reference" :
                    @[ @(nativeTimed), @(referenceTimed) ],
                @"native_medians_ms" : submit_medians(measurements[0]),
                @"reference_medians_ms" : submit_medians(measurements[1]),
                @"native_samples" : measurements[0],
                @"reference_samples" : measurements[1]
            }];
        }
    method_setImplementation(capture, (IMP)submit_original_capture);
    method_setImplementation(begin, (IMP)submit_original_begin);
    method_setImplementation(submit, (IMP)submit_original_submit);
    method_setImplementation(idle, (IMP)submit_original_idle);
    method_setImplementation(wait, (IMP)submit_original_wait);
    method_setImplementation(epoch, (IMP)submit_original_epoch);
    method_setImplementation(feedback, (IMP)submit_original_feedback);
    assert(exactPairs == 66);
    NSDictionary *report = @{
        @"device" : surfaces.cache.commands.device.name,
        @"os" : NSProcessInfo.processInfo.operatingSystemVersionString,
        @"reference" : @"Existing synchronous fetch-first fallback in the same "
                       @"binary;only the first optional vertex capture is "
                       @"denied by the test. Actual post-Fetch capture and all "
                       @"production GPU validation remain.",
        @"method" :
            @"Two warmups,nine alternating pairs;monotonic CPU "
            @"Draw/wait-API/begin-API and Draw+final-retire "
            @"intervals;per-submission valid MTL4 feedback duration sums;wait "
            @"intervals include API bookkeeping. Frame readback/state "
            @"comparison and reset excluded. Desktop load/driver cache "
            @"uncontrolled;no boot/FPS/cold-compile claim.",
        @"exact_pairs" : @(exactPairs),
        @"nonwriting" : @(nonwriting),
        @"workloads" : workloads
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                   options:0
                                                     error:NULL];
    assert(json);
    printf("Writable submit benchmark:%s\n",
           [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
               .UTF8String);
    puts("Writable submit benchmark:66 exact "
         "image/Current/constant/dirty/pending/query pairs;independent full "
         "synchronous fallback and real submits/waits PASS");
    groups++;
}
#endif
