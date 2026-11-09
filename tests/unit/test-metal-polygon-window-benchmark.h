/* Paired full polygon fragment GPU durations, without intervening readbacks.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_WINDOW_BENCHMARK_H
#define TEST_METAL_POLYGON_WINDOW_BENCHMARK_H
@interface PolygonWindowBenchmarkFeedback : NSObject {
@public
    NSUInteger registrations, callbacks;
    CFTimeInterval start, end;
    NSError *failure;
}
@end
@implementation PolygonWindowBenchmarkFeedback
@end
static _Thread_local __unsafe_unretained PolygonWindowBenchmarkFeedback
    *pwb_feedback;
static void (*pwb_feedback_original)(id, SEL, MTL4CommitFeedbackHandler);
static void pwb_add_feedback(id owner, SEL selector,
                             MTL4CommitFeedbackHandler handler)
{
    PolygonWindowBenchmarkFeedback *timing = pwb_feedback;
    if (!timing) {
        pwb_feedback_original(owner, selector, handler);
        return;
    }
    @synchronized(timing) {
        timing->registrations++;
    }
    pwb_feedback_original(owner, selector, ^(id<MTL4CommitFeedback> feedback) {
      @synchronized(timing) {
          timing->callbacks++;
          timing->start = feedback.GPUStartTime;
          timing->end = feedback.GPUEndTime;
          timing->failure = feedback.error;
      }
      handler(feedback);
    });
}
static PolygonWindowBenchmarkFeedback *pwb_submit(NV2AMetalCommands *q)
{
    NSError *error = nil;
    PolygonWindowBenchmarkFeedback *f = [PolygonWindowBenchmarkFeedback new];
    assert(f && !pwb_feedback);
    pwb_feedback = f;
    @try {
        require([q submitWithError:&error], error);
    } @finally {
        pwb_feedback = nil;
    }
    return f;
}
static double pwb_duration(PolygonWindowBenchmarkFeedback *f,
                           CFTimeInterval *start, CFTimeInterval *end)
{
    @synchronized(f) {
        assert(f->registrations == 1 && f->callbacks == 1 && !f->failure &&
               isfinite(f->start) && isfinite(f->end) && f->start > 0 &&
               f->end > f->start);
        *start = f->start;
        *end = f->end;
        return *end - *start;
    }
}
static int pwb_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static PolygonWindowImage *pwb_read(NV2AMetalCommands *q,
                                    PolygonWindowTargets *t)
{
    NSError *error = nil;
    require([q beginWithError:&error] != nil, error);
    id<MTLBuffer> b = pwc_read(q, t);
    require([q submitWithError:&error] && [q waitUntilIdleWithError:&error],
            error);
    PolygonWindowImage *image = [PolygonWindowImage new];
    image.bytes = [NSData dataWithBytes:b.contents length:b.length];
    uint64_t count;
    memcpy(&count, t.query.contents, sizeof(count));
    image.query = count;
    const float *p = image.bytes.bytes;
    for (NSUInteger i = 0; i < image.bytes.length / sizeof(float); i++)
        assert(isfinite(p[i]));
    return image;
}
static PolygonWindowImage *pwb_control_pair(NV2AMetalCommands *q,
                                            NV2AMetalGeometryResult *g,
                                            NV2AMetalPixelShader *previous,
                                            NV2AMetalPixelShader *current,
                                            PolygonWindowCase c, unsigned label)
{
    NSError *error = nil;
    PolygonWindowImage *images[2];
    NV2AMetalPixelShader *shaders[2] = { previous, current };
    for (unsigned v = 0; v < 2; v++) {
        PolygonWindowTargets *target = pwc_targets(q, 1024, 1);
        require([q beginWithError:&error] != nil, error);
        NV2AMetalPixelDraw *draw = pwc_prepare(q, shaders[v], g, c, target);
        pwc_emit(q, draw, target);
        require([q submitWithError:&error] && [q waitUntilIdleWithError:&error],
                error);
        images[v] = pwb_read(q, target);
    }
    pwc_equal(images[0], images[1], label);
    return images[1];
}
static void polygon_window_benchmark(void)
{
    NSError *error = nil;
    NV2AMetalCommands *q = [[NV2AMetalCommands alloc] initWithError:&error];
    require(q != nil, error);
    NV2AMetalGeometry *engine =
        [[NV2AMetalGeometry alloc] initWithDevice:q.device error:&error];
    require(engine != nil, error);
    pwc_textures(q);
    /* Retain the materialized old transport across both recordings. There is
     * no compact recording capability to refresh and no timed geometry work. */
    PolygonWindowCase c = { .scale = 1, .samples = 1 };
    NV2AMetalPixelShader *shaders[2] = { pwc_shader(q, 1, 1),
                                         pwc_shader(q, 0, 1) };
    Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
    assert(method);
    pwb_feedback_original = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)pwb_add_feedback);
    @try {
        for (unsigned material = 0; material < 2; material++) {
            c.material = material;
            c.anisotropic = material;
            c.wideFootprint = material;
            c.lodBias = 1.5f;
            /* Each material receives its actual immutable UV geometry before
             * any timed capture. The sampling fixture's physical slope is 2. */
            require([q beginWithError:&error] != nil, error);
            NV2AMetalGeometryResult *g = pwc_geometry(q, engine, c, 1024);
            require([q submitWithError:&error] &&
                        [q waitUntilIdleWithError:&error],
                    error);
            assert(g.expandedPolygons && !g.compactPolygons);
            for (unsigned clipped = 0; clipped < 2; clipped++)
                @autoreleasepool {
                    /* A central strip retains 1/16 of the framebuffer and
                     * includes the nonconstant T0 transition, also for AF. */
                    c.window = clipped ? 8 : 0;
                    PolygonWindowTargets *targets[2] = {
                        pwc_targets(q, 1024, 1), pwc_targets(q, 1024, 1)
                    };
                    assert(targets[0].color != targets[1].color &&
                           targets[0].depth != targets[1].depth);
                    double times[2][10] = { 0 }, ratios[10] = { 0 },
                           gaps[10] = { 0 };
                    double ordered[2][2][5] = { 0 }, orderRatios[2][5] = { 0 };
                    unsigned orderCounts[2] = { 0 };
                    for (unsigned trial = 0; trial < 12; trial++)
                        @autoreleasepool {
                            PolygonWindowBenchmarkFeedback *feedbacks[2];
                            for (unsigned position = 0; position < 2;
                                 position++) {
                                unsigned variant = (trial + position) & 1;
                                memset(targets[variant].query.contents, 0, 8);
                                require([q beginWithError:&error] != nil,
                                        error);
                                NV2AMetalPixelDraw *draw =
                                    pwc_prepare(q, shaders[variant], g, c,
                                                targets[variant]);
                                pwc_emit(q, draw, targets[variant]);
                                feedbacks[variant] = pwb_submit(q);
                            }
                            require([q waitUntilIdleWithError:&error], error);
                            CFTimeInterval start[2], end[2];
                            double dt[2];
                            for (unsigned v = 0; v < 2; v++)
                                dt[v] = pwb_duration(feedbacks[v], &start[v],
                                                     &end[v]);
                            PolygonWindowImage *a = pwb_read(q, targets[0]);
                            PolygonWindowImage *b = pwb_read(q, targets[1]);
                            pwc_equal(a, b, 100 + 2 * material + clipped);
                            /* Independently count the exact visible rectangle
                             * union; query includes only actual surviving
                             * pixels. */
                            NV2AMetalPixelTexture unused[4] = { 0 };
                            NV2AMetalPixelUniforms u =
                                pwc_uniforms(c, 1024, unused);
                            uint64_t expected = 0;
                            for (unsigned y = 0; y < 1024; y++)
                                for (unsigned x = 0; x < 1024; x++)
                                    expected += pwc_visible(&u, x, y);
                            assert(a.query == expected && expected > 0);
                            unsigned order = trial & 1;
                            assert(end[order] <= start[order ^ 1]);
                            if (material && trial == 0) {
                                /* Untimed witnesses use identical old/new
                                 * source pairs and separate output owners. */
                                PolygonWindowCase control = c;
                                control.sourceProbe = YES;
                                PolygonWindowImage *sourceAF4 =
                                    pwb_control_pair(q, g, shaders[0],
                                                     shaders[1], control, 104);
                                control.sourceAF = 1;
                                PolygonWindowImage *sourceAF1 =
                                    pwb_control_pair(q, g, shaders[0],
                                                     shaders[1], control, 105);
                                pwc_af_difference(sourceAF4, sourceAF1, 1024, 1,
                                                  NO);
                                control.sourceAF = 4;
                                control.dependentAF = 1;
                                control.sourceProbe = NO;
                                PolygonWindowImage *dependentAF1 =
                                    pwb_control_pair(q, g, shaders[0],
                                                     shaders[1], control, 106);
                                pwc_af_difference(b, dependentAF1, 1024, 1,
                                                  YES);
                            }
                            if (trial >= 2) {
                                unsigned sample = trial - 2,
                                         n = orderCounts[order]++;
                                assert(n < 5);
                                for (unsigned v = 0; v < 2; v++) {
                                    times[v][sample] = dt[v];
                                    ordered[order][v][n] = dt[v];
                                }
                                gaps[sample] = start[order ^ 1] - end[order];
                                ratios[sample] = dt[0] / dt[1];
                                orderRatios[order][n] = ratios[sample];
                            }
                        }
                    assert(orderCounts[0] == 5 && orderCounts[1] == 5);
                    for (unsigned v = 0; v < 2; v++)
                        qsort(times[v], 10, sizeof(double), pwb_compare);
                    qsort(ratios, 10, sizeof(double), pwb_compare);
                    qsort(gaps, 10, sizeof(double), pwb_compare);
                    printf("Polygon window GPU %s %s 1024x1024 old/new median "
                           "%.6f/%.6f ms range old[%.6f,%.6f] new[%.6f,%.6f]; "
                           "paired ratio median %.6f range[%.6f,%.6f]; 2 "
                           "warmups+10 balanced pairs, separate full "
                           "byte/query readbacks, pipelines prepared\n",
                           material ? "dependentMipAF" : "simple",
                           clipped ? "clipped" : "full",
                           (times[0][4] + times[0][5]) * 500,
                           (times[1][4] + times[1][5]) * 500,
                           times[0][0] * 1000, times[0][9] * 1000,
                           times[1][0] * 1000, times[1][9] * 1000,
                           (ratios[4] + ratios[5]) * .5, ratios[0], ratios[9]);
                    printf("  observed GPU gap median %.6f ms range[%.6f,%.6f] "
                           "across 10 measured pairs; no cause inferred\n",
                           (gaps[4] + gaps[5]) * 500, gaps[0] * 1000,
                           gaps[9] * 1000);
                    for (unsigned order = 0; order < 2; order++) {
                        for (unsigned v = 0; v < 2; v++)
                            qsort(ordered[order][v], 5, sizeof(double),
                                  pwb_compare);
                        qsort(orderRatios[order], 5, sizeof(double),
                              pwb_compare);
                        printf(
                            "  %s-first n5 old/new median %.6f/%.6f ms ranges "
                            "old[%.6f,%.6f] new[%.6f,%.6f]; ratio %.6f "
                            "[%.6f,%.6f]\n",
                            order ? "new" : "old", ordered[order][0][2] * 1000,
                            ordered[order][1][2] * 1000,
                            ordered[order][0][0] * 1000,
                            ordered[order][0][4] * 1000,
                            ordered[order][1][0] * 1000,
                            ordered[order][1][4] * 1000, orderRatios[order][2],
                            orderRatios[order][0], orderRatios[order][4]);
                    }
                }
        }
    } @finally {
        pwb_feedback = nil;
        method_setImplementation(method, (IMP)pwb_feedback_original);
    }
}
#endif
