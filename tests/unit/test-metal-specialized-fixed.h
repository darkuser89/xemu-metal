/* Fixed Function Constants versus general Metal4 execution.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_SPECIALIZED_FIXED_H
#define TEST_METAL_SPECIALIZED_FIXED_H
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#import <objc/runtime.h>
#include <time.h>
@interface NV2AMetalVertexFixed (SpecializedFixedTest)
- (id<MTLComputePipelineState>)pipelineForUniforms:
                                   (const NV2AMetalFixedUniforms *)u
                                           compact:(BOOL)compact;
- (NSArray *)compileVariant:(NSData *)key error:(NSError **)error;
@end
@interface SpecializedFixedReference : NV2AMetalVertexFixed
@end
@implementation SpecializedFixedReference
- (id<MTLComputePipelineState>)pipelineForUniforms:
                                   (const NV2AMetalFixedUniforms *)u
                                           compact:(BOOL)compact
{
    (void)u;
    return [self valueForKey:compact ? @"rasterPipeline" : @"pipeline"];
}
@end
static NV2AMetalFixedUniforms sf_uniforms(void)
{
    NV2AMetalFixedUniforms u = uniforms();
    u.material_alpha = .75f;
    u.material_alpha_back = .625f;
    u.specular_params[2] = u.specular_params_back[2] = 1;
    u.specular_power = 4;
    u.common.fog[0] = .5f;
    u.common.fog[1] = -.01f;
    u.point_params[0] = 1;
    u.point_params[3] = 8;
    u.point_params[6] = .25f;
    u.point_params[7] = 1;
    u.common.constants[NV_IGRAPH_XF_XFCTX_EYEP][2] = 20;
    u.common.constants[NV_IGRAPH_XF_XFCTX_EYEP][3] = 1;
    for (unsigned i = 0; i < 8; i++) {
        u.light_direction[i][2] = u.light_half_vector[i][2] = 1;
        u.light_position[i][0] = .125f;
        u.light_position[i][2] = 10 + i;
        u.light_attenuation[i][0] = 1;
        u.light_attenuation[i][1] = .01f;
        u.ltc1[NV_IGRAPH_XF_LTC1_r0 + i][0] = 1000;
        u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_SPT + 2 * i][2] = 1;
        u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * i][2] = 1;
    }
    for (unsigned i = 0; i < NV2A_LTCTXA_COUNT; i++)
        u.ltctxa[i][3] = 1;
    for (unsigned i = 0; i < NV2A_LTCTXB_COUNT; i++)
        for (unsigned k = 0; k < 3; k++)
            u.ltctxb[i][k] = (i % 7 + k + 1) / 32.f;
    return u;
}
static NV2AMetalFixedResult *
sf_encode(NV2AMetalVertexFixed *fixed, NV2AMetalCommands *commands,
          const NV2AMetalFixedUniforms *u, id<MTLBuffer> source,
          NSUInteger first, NSUInteger count, BOOL raster, BOOL compact)
{
    NSError *error = nil;
    NV2AMetalFixedResult *r = [fixed encodeAttributes:source
                                                first:first
                                                count:count
                                             uniforms:u
                                            rasterize:raster
                                     compactRegisters:compact
                                             commands:commands
                                                error:&error];
    require(r != nil, error);
    return r;
}
static void sf_warm(NV2AMetalVertexFixed *fixed, NV2AMetalCommands *commands,
                    NV2AMetalFixedUniforms *u, id<MTLBuffer> source)
{
    begin(commands);
    for (unsigned i = 0; i < 4; i++)
        sf_encode(fixed, commands, u, source, 0, 1, YES, NO);
    finish(commands);
    dispatch_sync((dispatch_queue_t)[fixed valueForKey:@"specializationQueue"],
                  ^{
                  });
    id variant = [fixed valueForKey:@"variant"];
    NSError *compileError = [variant valueForKey:@"error"];
    require([[variant valueForKey:@"pipelines"] count] == 2 && !compileError,
            compileError);
}
static unsigned sf_pairs, sf_cases;
static void sf_compare(const void *a, const void *b, NSUInteger bytes,
                       const char *kind)
{
    if (!memcmp(a, b, bytes))
        return;
    const uint32_t *av = a, *bv = b;
    for (NSUInteger i = 0; i < bytes / 4; i++)
        if (av[i] != bv[i]) {
            fprintf(
                stderr,
                "Specialized Fixed case%u pair%u %s word%lu: %08x != %08x\n",
                sf_cases, sf_pairs, kind, (unsigned long)i, av[i], bv[i]);
            abort();
        }
    abort();
}

/* Exercise both general entry points without warming a specialization. In
 * particular, the compact kernel has no raw-output allocation to write to. */
static void sf_cold_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    SpecializedFixedReference *fixed = [[SpecializedFixedReference alloc]
        initWithDevice:commands.device error:&error];
    require(fixed != nil, error);
    const NSUInteger counts[] = { 1, 3, 16, 17, 32, 256, 4096 };
    id<MTLBuffer> source = [commands.device
        newBufferWithLength:4100 * sizeof(NV2AMetalProgramInput)
        options:MTLResourceStorageModeShared];
    assert(source);
    NV2AMetalProgramInput *inputs = source.contents;
    for (NSUInteger i = 0; i < 4100; i++) {
        inputs[i] = input();
        inputs[i].attributes[0][0] = (i % 13) * .125f;
        inputs[i].attributes[0][1] = (i % 11) * .125f;
        for (unsigned t = 0; t < 4; t++)
            for (unsigned k = 0; k < 4; k++)
                inputs[i].attributes[9 + t][k] += (i % 7) * .125f;
    }
    NV2AMetalFixedUniforms u = uniforms();
    NSUInteger pairs = 0, vertices = 0;
    for (unsigned n = 0; n < sizeof(counts) / sizeof(*counts); n++) {
        NSUInteger count = counts[n];
        for (unsigned raster = 0; raster < 2; raster++) {
            begin(commands);
            NV2AMetalFixedResult *full =
                sf_encode(fixed, commands, &u, source, 3, count, raster, NO);
            NV2AMetalFixedResult *compact =
                sf_encode(fixed, commands, &u, source, 3, count, raster, YES);
            assert(full.registers && !compact.registers);
            finish(commands);
            sf_compare(full.vertices.contents, compact.vertices.contents,
                       count * sizeof(NV2AMetalVertex), "cold full/compact");
            const NV2AMetalProgramOutput *raw = full.registers.contents;
            const NV2AMetalVertex *native = compact.vertices.contents;
            for (NSUInteger i = 0; i < count; i++) {
                const NV2AMetalProgramInput *v = inputs + 3 + i;
                assert(!raw[i].fault);
                for (unsigned k = 0; k < 4; k++) {
                    check_float(raw[i].registers[0][k], v->attributes[0][k]);
                    for (unsigned t = 0; t < 4; t++) {
                        check_float(raw[i].registers[9 + t][k],
                                    v->attributes[9 + t][k]);
                        if (raster)
                            check_float(native[i].texcoord[t][k],
                                        v->attributes[9 + t][k]);
                    }
                }
                if (raster) {
                    check_float(native[i].clip[0], v->attributes[0][0] / 2 - 1);
                    check_float(native[i].clip[1], 1 - v->attributes[0][1] / 2);
                    check_float(native[i].clip[2], .125f);
                    check_float(native[i].clip[3], 1);
                    check_float(native[i].point_size, 6);
                } else {
                    NV2AMetalVertex zero = { 0 };
                    assert(!memcmp(native + i, &zero, sizeof(zero)));
                }
                vertices++;
            }
            pairs++;
        }
    }
    assert(pairs == 14 && vertices == 8842);
    assert(![[fixed valueForKey:@"variants"] count]);
    printf("Cold Fixed:14 full/compact pairs,8842 CPU position/texgen/"
           "raster checks,28 general dispatches with no specialization PASS\n");
}
static void sf_case(NV2AMetalVertexFixed *native,
                    NV2AMetalVertexFixed *reference,
                    NV2AMetalCommands *commands, NV2AMetalFixedUniforms u,
                    id<MTLBuffer> source)
{
    sf_warm(native, commands, &u, source);
    sf_cases++;
    uint64_t nativeBefore =
        [[native valueForKey:@"specializedDispatches"] unsignedLongLongValue];
    for (unsigned raster = 0; raster < 2; raster++)
        for (unsigned compact = 0; compact < 2; compact++) {
            /* Live matrix/light/color/fog values must not create a variant. */
            id entry = [native valueForKey:@"variant"];
            u.common.constants[NV_IGRAPH_XF_XFCTX_VPOFF][0] += .125f;
            u.material_alpha += .01f;
            u.ltctxb[0][0] += .015625f;
            u.common.fog[0] += .03125f;
            begin(commands);
            NV2AMetalFixedResult *a =
                sf_encode(native, commands, &u, source, 3, 32, raster, compact);
            NV2AMetalFixedResult *b = sf_encode(reference, commands, &u, source,
                                                3, 32, raster, compact);
            assert([native valueForKey:@"variant"] == entry);
            finish(commands);
            assert(a.vertexCount == 32 && b.vertexCount == 32);
            if (!compact)
                sf_compare(a.registers.contents, b.registers.contents,
                           32 * sizeof(NV2AMetalProgramOutput), "raw");
            else
                assert(!a.registers && !b.registers);
            sf_compare(a.vertices.contents, b.vertices.contents,
                       32 * sizeof(NV2AMetalVertex), "raster");
            sf_pairs++;
        }
    assert(
        [[native valueForKey:@"specializedDispatches"] unsignedLongLongValue] -
            nativeBefore ==
        4);
}
static double sf_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec * 1000. + t.tv_nsec / 1000000.;
}
@interface SpecializedFixedMeasured : NV2AMetalVertexFixed
@property(nonatomic, strong) dispatch_semaphore_t gate, entered;
@property(nonatomic) BOOL fail;
@property(nonatomic) double compileMilliseconds;
@end
@implementation SpecializedFixedMeasured
- (NSArray *)compileVariant:(NSData *)key error:(NSError **)error
{
    if (_entered)
        dispatch_semaphore_signal(_entered);
    if (_gate)
        assert(!dispatch_semaphore_wait(
            _gate, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)));
    if (_fail) {
        if (error)
            *error = [NSError errorWithDomain:@"fixed-compile-test"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    double start = sf_clock();
    NSArray *result = [super compileVariant:key error:error];
    _compileMilliseconds += sf_clock() - start;
    return result;
}
@end
static uint64_t sf_counter(id fixed, NSString *name)
{
    return [[fixed valueForKey:name] unsignedLongLongValue];
}
static void sf_queue_wait(NV2AMetalVertexFixed *fixed)
{
    dispatch_sync((dispatch_queue_t)[fixed valueForKey:@"specializationQueue"],
                  ^{
                  });
    assert(!sf_counter(fixed, @"specializationPending"));
}
static void sf_lifecycle(NV2AMetalCommands *commands, id<MTLBuffer> source,
                         NV2AMetalVertexFixed *reference)
{
    NSError *error = nil;
    SpecializedFixedMeasured *fixed =
        [[SpecializedFixedMeasured alloc] initWithDevice:commands.device
                                                   error:&error];
    require(fixed != nil, error);
    fixed.gate = dispatch_semaphore_create(0);
    fixed.entered = dispatch_semaphore_create(0);
    __weak id first, second;
    id deferred;
    begin(commands);
    @autoreleasepool {
        for (unsigned skin = 0; skin < 3; skin++) {
            NV2AMetalFixedUniforms u = sf_uniforms();
            u.skinning = skin;
            for (unsigned call = 0; call < 4; call++)
                sf_encode(fixed, commands, &u, source, 0, 1, YES, NO);
            if (!skin)
                first = [fixed valueForKey:@"variant"];
            else if (skin == 1)
                second = [fixed valueForKey:@"variant"];
            else
                deferred = [fixed valueForKey:@"variant"];
        }
    }
    assert(!dispatch_semaphore_wait(
        fixed.entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    assert(sf_counter(fixed, @"specializationPending") == 2 &&
           sf_counter(fixed, @"specializationAttempts") == 2 &&
           ![[deferred valueForKey:@"queued"] boolValue]);
    for (unsigned cold = 0; cold < 65; cold++)
        @autoreleasepool {
            NV2AMetalFixedUniforms u = sf_uniforms();
            u.skinning = 3;
            u.emission_src = cold % 3;
            u.ambient_src = (cold / 3) % 3;
            u.diffuse_src = (cold / 9) % 3;
            u.specular_src = (cold / 27) % 3;
            sf_encode(fixed, commands, &u, source, 0, 1, YES, NO);
            u = sf_uniforms();
            u.skinning = 2;
            sf_encode(fixed, commands, &u, source, 0, 1, YES, NO);
            assert([fixed valueForKey:@"variant"] == deferred);
        }
    finish(commands); /* Compiler is still gated; GPU must finish anyway. */
    NV2AMetalLRUCache *cache = [fixed valueForKey:@"variants"];
    @autoreleasepool {
        assert(first && second && cache.count == 64);
    }
    dispatch_semaphore_signal(fixed.gate);
    dispatch_semaphore_signal(fixed.gate);
    sf_queue_wait(fixed);
    assert(sf_counter(fixed, @"specializationSuccesses") == 2);
    @autoreleasepool {
        assert(!first && !second);
    }
    NV2AMetalFixedUniforms u = sf_uniforms();
    u.skinning = 2;
    begin(commands);
    sf_encode(fixed, commands, &u, source, 0, 1, YES, NO);
    finish(commands);
    dispatch_semaphore_signal(fixed.gate);
    sf_queue_wait(fixed);
    assert(sf_counter(fixed, @"specializationSuccesses") == 3 &&
           [[deferred valueForKey:@"pipelines"] count] == 2);
    SpecializedFixedMeasured *failed =
        [[SpecializedFixedMeasured alloc] initWithDevice:commands.device
                                                   error:&error];
    require(failed != nil, error);
    failed.fail = YES;
    begin(commands);
    for (unsigned call = 0; call < 4; call++)
        sf_encode(failed, commands, &u, source, 0, 1, YES, NO);
    finish(commands);
    sf_queue_wait(failed);
    assert(sf_counter(failed, @"specializationFailures") == 1);
    for (unsigned call = 0; call < 8; call++) {
        begin(commands);
        NV2AMetalFixedResult *a =
            sf_encode(failed, commands, &u, source, 3, 32, YES, NO);
        NV2AMetalFixedResult *b =
            sf_encode(reference, commands, &u, source, 3, 32, YES, NO);
        finish(commands);
        sf_compare(a.registers.contents, b.registers.contents,
                   32 * sizeof(NV2AMetalProgramOutput), "failed raw");
        sf_compare(a.vertices.contents, b.vertices.contents,
                   32 * sizeof(NV2AMetalVertex), "failed raster");
    }
    assert(sf_counter(failed, @"specializationAttempts") == 1 &&
           !sf_counter(failed, @"specializedDispatches"));
    puts("Specialized Fixed lifecycle:two-job limit,third deferred/retried,GPU "
         "completes behind compiler gate,evicted entries retained then "
         "released;injected compile failure gives eight exact general GPU "
         "pairs/no retry flood PASS");
}
static void sf_boundaries(NV2AMetalVertexFixed *native,
                          NV2AMetalVertexFixed *reference,
                          NV2AMetalCommands *commands, id<MTLBuffer> source)
{
    NV2AMetalFixedUniforms u = sf_uniforms();
    sf_warm(native, commands, &u, source);
    uint64_t dispatches = sf_counter(native, @"specializedDispatches");
    id entry = [native valueForKey:@"variant"];
    begin(commands);
    for (unsigned kind = 0; kind < 12; kind++) {
        NV2AMetalFixedUniforms bad = u;
        NSUInteger first = 0;
        BOOL raster = YES, compact = NO;
        switch (kind) {
        case 0:
            bad.skinning = 7;
            break;
        case 1:
            bad.light[0] = 4;
            break;
        case 2:
            bad.texgen[3][3] = NV2AMetalTexgenSphere;
            break;
        case 3:
            bad.common.fog_enable = 1;
            bad.common.fog_mode = 2;
            break;
        case 4:
            bad.ambient_src = 3;
            break;
        case 5:
            bad.legacy_specular = 2;
            break;
        case 6:
            bad.two_side = 2;
            break;
        case 7:
            bad.common.point_scale = NAN;
            break;
        case 8:
            bad.common.surface_size[0] = 0;
            break;
        case 9:
            first = 36;
            break;
        case 10:
            bad.texgen_infinite_viewer = 2;
            break;
        default:
            bad.common.fog_enable = 1;
            bad.foggen = 5;
            break;
        }
        NSError *error = nil;
        assert(![native encodeAttributes:source
                                   first:first
                                   count:1
                                uniforms:&bad
                               rasterize:raster
                        compactRegisters:compact
                                commands:commands
                                   error:&error] &&
               error);
        assert([native valueForKey:@"variant"] == entry &&
               sf_counter(native, @"specializedDispatches") == dispatches);
    }
    finish(commands);
    /* Raw context accepts unbound dimensions, preserving its original contract.
     */
    u.common.surface_size[0] = u.common.surface_size[1] = 0;
    u.common.zmax = NAN;
    for (unsigned compact = 0; compact < 2; compact++) {
        begin(commands);
        NV2AMetalFixedResult *a =
            sf_encode(native, commands, &u, source, 3, 32, NO, compact);
        NV2AMetalFixedResult *b =
            sf_encode(reference, commands, &u, source, 3, 32, NO, compact);
        finish(commands);
        if (!compact)
            sf_compare(a.registers.contents, b.registers.contents,
                       32 * sizeof(NV2AMetalProgramOutput), "unbound raw");
        sf_compare(a.vertices.contents, b.vertices.contents,
                   32 * sizeof(NV2AMetalVertex), "unbound raster");
    }
    NSError *error = nil;
    id<MTLBuffer> private =
        [commands.device newBufferWithLength:source.length
                                     options:MTLResourceStorageModePrivate];
    assert(private);
    u = sf_uniforms();
    begin(commands);
    require([commands addResource:source error:&error] &&
                [commands addResource:private error:&error],
            error);
    id<MTL4ComputeCommandEncoder> copy =
        [commands.commandBuffer computeCommandEncoder];
    assert(copy);
    [copy copyFromBuffer:source
             sourceOffset:0
                 toBuffer:private
        destinationOffset:0
                     size:source.length];
    [copy endEncoding];
    NV2AMetalFixedResult *a =
        sf_encode(native, commands, &u, private, 3, 32, YES, NO);
    NV2AMetalFixedResult *b =
        sf_encode(reference, commands, &u, private, 3, 32, YES, NO);
    finish(commands);
    sf_compare(a.registers.contents, b.registers.contents,
               32 * sizeof(NV2AMetalProgramOutput), "private raw");
    sf_compare(a.vertices.contents, b.vertices.contents,
               32 * sizeof(NV2AMetalVertex), "private raster");
    puts("Specialized Fixed boundaries:12 warm validation/range "
         "rejections,unbound raw/full+compact,same-recording private GPU "
         "producer/suffix exact PASS");
}
static void sf_inflight(NV2AMetalCommands *commands, id<MTLBuffer> source,
                        NV2AMetalVertexFixed *reference)
{
    NSError *error = nil;
    NV2AMetalFixedResult *a, *b;
    __weak NV2AMetalVertexFixed *owner;
    __weak id<MTLComputePipelineState> pipeline;
    @autoreleasepool {
        NV2AMetalVertexFixed *fixed =
            [[NV2AMetalVertexFixed alloc] initWithDevice:commands.device
                                                   error:&error];
        require(fixed != nil, error);
        NV2AMetalFixedUniforms u = sf_uniforms();
        sf_warm(fixed, commands, &u, source);
        begin(commands);
        a = sf_encode(fixed, commands, &u, source, 3, 32, YES, NO);
        b = sf_encode(reference, commands, &u, source, 3, 32, YES, NO);
        NSArray *pipelines =
            [[fixed valueForKey:@"variant"] valueForKey:@"pipelines"];
        pipeline = pipelines[0];
        owner = fixed;
        NV2AMetalLRUCache *cache = [fixed valueForKey:@"variants"];
        [cache removeAllObjects];
        [fixed setValue:nil forKey:@"variant"];
        fixed = nil;
    }
    @autoreleasepool {
        assert(owner && pipeline);
    }
    finish(commands);
    sf_compare(a.registers.contents, b.registers.contents,
               32 * sizeof(NV2AMetalProgramOutput), "retained raw");
    sf_compare(a.vertices.contents, b.vertices.contents,
               32 * sizeof(NV2AMetalVertex), "retained raster");
    @autoreleasepool {
        assert(!owner);
    }
    puts("Specialized Fixed inflight:queued native pipeline survives cache "
         "clear/external owner release;exact GPU results,command owner "
         "releases after drain PASS");
}
static void (*sf_original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static double sf_gpu_seconds;
static void sf_feedback(id owner, SEL selector,
                        MTL4CommitFeedbackHandler handler)
{
    sf_original_feedback(owner, selector, ^(id<MTL4CommitFeedback> feedback) {
      sf_gpu_seconds = feedback.GPUEndTime - feedback.GPUStartTime;
      handler(feedback);
    });
}
static int sf_time_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void sf_benchmark(NV2AMetalVertexFixed *native,
                         NV2AMetalVertexFixed *reference,
                         NV2AMetalCommands *commands)
{
    const NSUInteger count = 16384;
    NSMutableData *data =
        [NSMutableData dataWithLength:count * sizeof(NV2AMetalProgramInput)];
    NV2AMetalProgramInput *v = data.mutableBytes;
    for (unsigned i = 0; i < count; i++) {
        v[i] = input();
        for (unsigned k = 0; k < 4; k++)
            v[i].attributes[1][k] = (k + 1) / 10.f;
        v[i].attributes[0][0] = (i % 17 + 1) / 16.f;
    }
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:data.bytes
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
    Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
    sf_original_feedback =
        (void *)method_setImplementation(method, (IMP)sf_feedback);
    for (unsigned mode = 0; mode < 2; mode++) {
        NV2AMetalFixedUniforms u = sf_uniforms();
        if (mode) {
            u.lighting = u.two_side = u.normalization = u.local_eye = 1;
            u.skinning = NV2AMetalSkinningFourWeightsFourMatrices;
            for (unsigned i = 0; i < 8; i++)
                u.light[i] = i % 3 + 1;
            for (unsigned t = 0; t < 4; t++) {
                u.texture_matrix_enable[t] = 1;
                for (unsigned c = 0; c < 3; c++)
                    u.texgen[t][c] = NV2AMetalTexgenReflection;
            }
        }
        sf_warm(native, commands, &u, source);
        double times[2][9];
        for (unsigned trial = 0; trial < 11; trial++) {
            NV2AMetalFixedResult *results[2];
            for (unsigned order = 0; order < 2; order++) {
                unsigned selected = (trial + order) & 1;
                begin(commands);
                results[selected] =
                    sf_encode(selected ? native : reference, commands, &u,
                              source, 0, count, YES, YES);
                finish(commands);
                assert(sf_gpu_seconds > 0);
                if (trial >= 2)
                    times[selected][trial - 2] = sf_gpu_seconds;
            }
            sf_compare(results[0].vertices.contents,
                       results[1].vertices.contents,
                       count * sizeof(NV2AMetalVertex), "benchmark");
        }
        for (unsigned i = 0; i < 2; i++)
            qsort(times[i], 9, sizeof(double), sf_time_compare);
        NSArray *pipelines =
            [[native valueForKey:@"variant"] valueForKey:@"pipelines"];
        id<MTLComputePipelineState> pipeline = pipelines[1];
        printf(
            "Specialized Fixed benchmark %s:16384 vertices/11 exact pairs,2 "
            "warmups/9 alternating samples;GPU median native/general %.6f/%.6f "
            "ms;SIMD%lu,maxThreads%lu,staticThreadgroupBytes%lu;no "
            "register/spill or app measurement\n",
            mode ? "lit-skinned-texgen" : "simple", times[1][4] * 1000,
            times[0][4] * 1000, (unsigned long)pipeline.threadExecutionWidth,
            (unsigned long)pipeline.maxTotalThreadsPerThreadgroup,
            (unsigned long)pipeline.staticThreadgroupMemoryLength);
    }
    method_setImplementation(method, (IMP)sf_original_feedback);
}

static void specialized_fixed_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalVertexFixed *native =
        [[SpecializedFixedMeasured alloc] initWithDevice:commands.device
                                                   error:&error];
    require(native != nil, error);
    NV2AMetalVertexFixed *reference =
        [[SpecializedFixedReference alloc] initWithDevice:commands.device
                                                    error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput values[35];
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x00800000, 0x3f800001, 0x3f7fffff,
                              0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
                              0x7fc00123, 0x7f800123 };
    for (unsigned v = 0; v < 35; v++) {
        values[v] = input();
        for (unsigned k = 0; k < 4; k++)
            values[v].attributes[1][k] = (k + 1) / 10.f;
        for (unsigned a = 3; a <= 8; a++)
            for (unsigned k = 0; k < 4; k++) {
                uint32_t word =
                    bits[(v + a + k) % (sizeof(bits) / sizeof(*bits))];
                memcpy(&values[v].attributes[a][k], &word, 4);
            }
    }
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalFixedUniforms u = sf_uniforms();
    sf_case(native, reference, commands, u, source);
    u.lighting = u.two_side = 1;
    u.light[0] = NV2AMetalLightInfinite;
    u.diffuse_src = NV2AMetalMaterialSourceDiffuse;
    sf_case(native, reference, commands, u, source);
    for (unsigned skin = 0; skin < 7; skin++)
        for (unsigned normalize = 0; normalize < 2; normalize++)
            for (unsigned lighting = 0; lighting < 2; lighting++)
                for (unsigned back = 0; back < 2; back++) {
                    u = sf_uniforms();
                    u.skinning = skin;
                    u.normalization = normalize;
                    u.lighting = lighting;
                    u.two_side = back;
                    u.light[0] = NV2AMetalLightInfinite;
                    sf_case(native, reference, commands, u, source);
                }
    for (unsigned index = 0; index < 8; index++)
        for (unsigned type = 0; type < 4; type++)
            for (unsigned eye = 0; eye < 2; eye++)
                for (unsigned legacy = 0; legacy < 2; legacy++) {
                    u = sf_uniforms();
                    u.lighting = u.two_side = 1;
                    u.light[index] = type;
                    u.local_eye = eye;
                    u.legacy_specular = legacy;
                    sf_case(native, reference, commands, u, source);
                }
    for (unsigned field = 0; field < 8; field++)
        for (unsigned mode = 0; mode < 3; mode++) {
            u = sf_uniforms();
            u.lighting = u.two_side = 1;
            u.light[0] = NV2AMetalLightInfinite;
            unsigned *sources[] = {
                &u.emission_src,     &u.ambient_src,       &u.diffuse_src,
                &u.specular_src,     &u.back_emission_src, &u.back_ambient_src,
                &u.back_diffuse_src, &u.back_specular_src
            };
            *sources[field] = mode;
            sf_case(native, reference, commands, u, source);
        }
    for (unsigned stage = 0; stage < 4; stage++)
        for (unsigned mode = 0; mode < 6; mode++)
            for (unsigned viewer = 0; viewer < 2; viewer++)
                for (unsigned matrixOn = 0; matrixOn < 2; matrixOn++) {
                    u = sf_uniforms();
                    u.normalization = mode & 1;
                    u.texgen_infinite_viewer = viewer;
                    u.texture_matrix_enable[stage] = matrixOn;
                    unsigned components =
                        mode == NV2AMetalTexgenSphere ? 2 :
                        mode == NV2AMetalTexgenNormal ||
                                mode == NV2AMetalTexgenReflection ?
                                                        3 :
                                                        4;
                    for (unsigned c = 0; c < components; c++)
                        u.texgen[stage][c] = mode;
                    sf_case(native, reference, commands, u, source);
                }
    for (unsigned n = 0; n < 32; n++) {
        u = sf_uniforms();
        u.lighting = u.two_side = 1;
        u.normalization = n & 1;
        u.local_eye = (n >> 1) & 1;
        u.skinning = n % 7;
        for (unsigned light = 0; light < 8; light++)
            u.light[light] = (n + light) % 4;
        for (unsigned t = 0; t < 4; t++) {
            u.texture_matrix_enable[t] = (n >> t) & 1;
            for (unsigned c = 0; c < 4; c++) {
                unsigned mode = (n + 2 * t + c) % 6;
                if ((mode == 3 && c >= 2) || (mode >= 4 && c >= 3))
                    mode = 0;
                u.texgen[t][c] = mode;
            }
        }
        sf_case(native, reference, commands, u, source);
    }
    for (unsigned generation = 0; generation < 5; generation++)
        for (unsigned mode = 0; mode < 6; mode++)
            for (unsigned point = 0; point < 2; point++) {
                u = sf_uniforms();
                u.common.fog_enable = 1;
                u.common.fog_mode = (unsigned[]){ 0, 1, 3, 4, 5, 7 }[mode];
                u.foggen = generation;
                u.point_params_enable = point;
                sf_case(native, reference, commands, u, source);
            }
    for (unsigned enabled = 0; enabled < 2; enabled++)
        for (unsigned ignore = 0; ignore < 2; ignore++)
            for (unsigned separate = 0; separate < 2; separate++) {
                u = sf_uniforms();
                u.lighting = u.two_side = 1;
                u.light[0] = NV2AMetalLightInfinite;
                u.common.specular_enable = enabled;
                u.common.ignore_specular_alpha = ignore;
                u.separate_specular = separate;
                sf_case(native, reference, commands, u, source);
            }
    assert(sf_cases == 406 && sf_pairs == 1624);
    printf("Specialized Fixed:%u structural cases/%u exact32-vertex "
           "raw/raster/full/compact pairs;all skinning,light "
           "slots/types,front/back material sources,Texgen "
           "stages/modes/viewers/matrices,Fog/point/specular "
           "flags,NaN/Inf/zero/denormal colors,live uniforms PASS\n",
           sf_cases, sf_pairs);
    NV2AMetalLRUCache *cache = [native valueForKey:@"variants"];
    NSUInteger references = 0;
    for (id node in [[cache valueForKey:@"entries"] allValues])
        references +=
            [[[node valueForKey:@"object"] valueForKey:@"pipelines"] count];
    assert(cache.count == 64 && references == 128 &&
           !sf_counter(native, @"specializationPending"));
    printf(
        "Specialized Fixed cache:64 entries/128 ready pipeline "
        "references;worker compile elapsed %.3f ms,driver cache uncontrolled\n",
        ((SpecializedFixedMeasured *)native).compileMilliseconds);
    sf_lifecycle(commands, source, reference);
    sf_boundaries(native, reference, commands, source);
    sf_inflight(commands, source, reference);
    sf_benchmark(native, reference, commands);
}
#endif
