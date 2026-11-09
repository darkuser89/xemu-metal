/* Whole fullscreen GPU durations, with separate untimed Float4 readbacks.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_SHARED_TAPS_BENCHMARK_H
#define TEST_METAL_SAMPLER_SHARED_TAPS_BENCHMARK_H

@interface SamplerSharedTapsBenchmarkFeedback : NSObject {
@public
    NSUInteger registrations, callbacks;
    CFTimeInterval start, end;
    NSError *failure;
}
@end
@implementation SamplerSharedTapsBenchmarkFeedback
@end

static _Thread_local __unsafe_unretained SamplerSharedTapsBenchmarkFeedback
    *sstb_feedback;
static void (*sstb_add_feedback_original)(id, SEL, MTL4CommitFeedbackHandler);
static void sstb_add_feedback(id owner, SEL selector,
                              MTL4CommitFeedbackHandler handler)
{
    SamplerSharedTapsBenchmarkFeedback *timing = sstb_feedback;
    if (!timing) {
        sstb_add_feedback_original(owner, selector, handler);
        return;
    }
    @synchronized(timing) {
        timing->registrations++;
    }
    sstb_add_feedback_original(owner, selector,
                               ^(id<MTL4CommitFeedback> feedback) {
                                 @synchronized(timing) {
                                     timing->callbacks++;
                                     timing->start = feedback.GPUStartTime;
                                     timing->end = feedback.GPUEndTime;
                                     timing->failure = feedback.error;
                                 }
                                 /* Original receipt publication follows the
                                  * real feedback unchanged. */
                                 handler(feedback);
                               });
}

static SamplerSharedTapsBenchmarkFeedback *sstb_submit(void)
{
    NSError *error = nil;
    SamplerSharedTapsBenchmarkFeedback *timing =
        [SamplerSharedTapsBenchmarkFeedback new];
    assert(timing && !sstb_feedback);
    sstb_feedback = timing;
    @try {
        require([commands submitWithError:&error], error);
    } @finally {
        sstb_feedback = nil;
    }
    return timing;
}

static double sstb_duration(SamplerSharedTapsBenchmarkFeedback *timing,
                            CFTimeInterval *start, CFTimeInterval *end)
{
    @synchronized(timing) {
        assert(timing->registrations == 1 && timing->callbacks == 1 &&
               !timing->failure && isfinite(timing->start) &&
               isfinite(timing->end) && timing->start > 0 &&
               timing->end > timing->start);
        *start = timing->start;
        *end = timing->end;
        return *end - *start;
    }
}

static NSString *sstb_source(BOOL reference)
{
    NSString *source = @(metal_shader_source);
    if (reference)
        source = sst_guard_off(source);
    NSMutableString *result = [source mutableCopy];
    [result appendString:
                @"\nstruct SSTBenchVarying { float4 position [[position]]; "
                @"float2 uv; };\n"
                 "vertex SSTBenchVarying sstb_vertex(uint i [[vertex_id]]) {\n"
                 " float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};\n"
                 " SSTBenchVarying v; v.position=float4(p[i],0,1); "
                 "v.uv=p[i]*.5f+.5f; return v; }\n"];
    NSArray *types =
        @[ @"texture2d<float>", @"texture3d<float>", @"texturecube<float>" ];
    NSArray *coords = @[
        @".125f+v.uv*.75f", @"float3(.125f+v.uv*.75f,.375f+v.uv.x*.125f)",
        @"float3(v.uv*.5f-.25f,1)"
    ];
    for (unsigned kind = 0; kind < 3; kind++)
        [result appendFormat:@"fragment float4 sstb_fragment%u(SSTBenchVarying "
                             @"v [[stage_in]], "
                              "%@ t [[texture(0)]], constant "
                              "NV2AMetalSamplingUniforms &s [[buffer(0)]]) {\n"
                              " constexpr sampler "
                              "smp(coord::normalized,address::clamp_to_edge,"
                              "filter::nearest);\n"
                              " return nv2a_sample(t,smp,%@,s); }\n",
                             kind, types[kind], coords[kind]];
    return result;
}

static id<MTLTexture> sstb_texture(unsigned kind, BOOL collapsed)
{
    unsigned size = collapsed ? 1 : kind == 1 ? 16 : 64;
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    d.textureType = kind == 1 ? MTLTextureType3D :
                    kind == 2 ? MTLTextureTypeCube :
                                MTLTextureType2D;
    d.depth = kind == 1 ? size : 1;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:d];
    require(texture != nil, nil);
    for (unsigned face = 0; face < (kind == 2 ? 6u : 1u); face++) {
        NSMutableData *bytes =
            [NSMutableData dataWithLength:size * size * d.depth * 16];
        float *p = bytes.mutableBytes;
        for (unsigned i = 0; i < size * size * d.depth; i++)
            for (unsigned k = 0; k < 4; k++)
                p[4 * i + k] =
                    ((i * 37 + face * 19 + k * 53) % 251 + 1) / 256.f;
        [texture replaceRegion:MTLRegionMake3D(0, 0, 0, size, size, d.depth)
                   mipmapLevel:0
                         slice:face
                     withBytes:bytes.bytes
                   bytesPerRow:size * 16
                 bytesPerImage:size * size * 16];
    }
    return texture;
}

static void sstb_draw(id<MTLRenderPipelineState> pipeline,
                      id<MTLTexture> source, id<MTLTexture> output,
                      id<MTL4ArgumentTable> args, id<MTLBuffer> uniform)
{
    NSError *error = nil;
    require([commands beginWithError:&error] &&
                [commands addResource:source error:&error] &&
                [commands addResource:output error:&error] &&
                [commands addResource:uniform error:&error] &&
                [commands keepAlive:args error:&error] &&
                [commands keepAlive:pipeline error:&error],
            error);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = output;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(-7, -11, -13, -17);
    /* This isolated pass stays in the single native command buffer. The
     * backend's suspending raster-chain API would add a second commit. */
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    require(e != nil, error);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setRenderPipelineState:pipeline];
    [e setCullMode:MTLCullModeNone];
    [e setViewport:(MTLViewport){ 0, 0, 1024, 1024, 0, 1 }];
    [e setScissorRect:(MTLScissorRect){ 0, 0, 1024, 1024 }];
    [e setArgumentTable:args atStages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}

static NSData *sstb_read(id<MTLTexture> texture)
{
    NSError *error = nil;
    NSUInteger row = texture.width * 16, length = row * texture.height;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    require(result && [commands beginWithError:&error] &&
                [commands addResource:texture error:&error] &&
                [commands addResource:result error:&error],
            error);
    memset(result.contents, 0xcd, length);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                        toBuffer:result
               destinationOffset:0
          destinationBytesPerRow:row
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    /* This second commit has no timing observer and is never included in the
     * fullscreen GPU duration. */
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    const float *pixels = result.contents;
    for (NSUInteger i = 0; i < length / 4; i++)
        assert(isfinite(pixels[i]) && pixels[i] >= 0 && pixels[i] <= 1);
    return [NSData dataWithBytes:result.contents length:length];
}

static int sstb_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void sampler_shared_taps_benchmark(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    id<MTLRenderPipelineState> pipelines[3][2];
    for (unsigned variant = 0; variant < 2; variant++) {
        id<MTLLibrary> library = sst_library(compiler, sstb_source(!variant));
        for (unsigned kind = 0; kind < 3; kind++) {
            MTL4LibraryFunctionDescriptor *v = [MTL4LibraryFunctionDescriptor
                                              new],
                                          *f = [MTL4LibraryFunctionDescriptor
                                              new];
            v.library = f.library = library;
            v.name = @"sstb_vertex";
            f.name = [NSString stringWithFormat:@"sstb_fragment%u", kind];
            MTL4RenderPipelineDescriptor *d =
                [MTL4RenderPipelineDescriptor new];
            d.vertexFunctionDescriptor = v;
            d.fragmentFunctionDescriptor = f;
            d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
            d.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
            d.colorAttachments[0].blendingState = MTL4BlendStateDisabled;
            d.rasterSampleCount = 1;
            d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
            pipelines[kind][variant] =
                [compiler newRenderPipelineStateWithDescriptor:d
                                           compilerTaskOptions:nil
                                                         error:&error];
            require(pipelines[kind][variant] != nil, error);
        }
    }
    NV2AMetalSamplingUniforms sampling = { .enabled = 1,
                                           .min_linear = 1,
                                           .mag_linear = 1,
                                           .anisotropy = 1,
                                           .mip_filter = 2,
                                           .address = { 3, 3, 3 } };
    id<MTLBuffer> uniform =
        [commands.device newBufferWithBytes:&sampling
                                     length:sizeof(sampling)
                                    options:MTLResourceStorageModeShared];
    require(uniform != nil, nil);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:1024
                                    height:1024
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    assert(feedback);
    sstb_add_feedback_original = (void *)method_getImplementation(feedback);
    method_setImplementation(feedback, (IMP)sstb_add_feedback);
    @try {
        for (unsigned kind = 0; kind < 3; kind++)
            for (unsigned collapsed = 0; collapsed < 2; collapsed++)
                @autoreleasepool {
                    id<MTLTexture> source = sstb_texture(kind, collapsed);
                    id<MTLTexture> outputs[2] = {
                        [commands.device newTextureWithDescriptor:td],
                        [commands.device newTextureWithDescriptor:td]
                    };
                    MTL4ArgumentTableDescriptor *ad =
                        [MTL4ArgumentTableDescriptor new];
                    ad.maxBufferBindCount = 1;
                    ad.maxTextureBindCount = 1;
                    ad.initializeBindings = YES;
                    id<MTL4ArgumentTable> args =
                        [commands.device newArgumentTableWithDescriptor:ad
                                                                  error:&error];
                    require(outputs[0] && outputs[1] &&
                                outputs[0] != outputs[1] && args,
                            error);
                    [args setAddress:uniform.gpuAddress atIndex:0];
                    [args setTexture:source.gpuResourceID atIndex:0];
                    double times[2][10] = { 0 }, ratios[10] = { 0 };
                    double ordered[2][2][5] = { 0 }, orderRatios[2][5] = { 0 };
                    unsigned orderCounts[2] = { 0 };
                    for (unsigned trial = 0; trial < 12; trial++)
                        @autoreleasepool {
                            /* Strong owners cover both real callbacks and
                             * the common full wait. No CPU wait/readback
                             * separates these two same-queue commits. */
                            SamplerSharedTapsBenchmarkFeedback *timings[2];
                            for (unsigned position = 0; position < 2;
                                 position++) {
                                unsigned variant = (trial + position) & 1;
                                sstb_draw(pipelines[kind][variant], source,
                                          outputs[variant], args, uniform);
                                timings[variant] = sstb_submit();
                            }
                            require([commands waitUntilIdleWithError:&error],
                                    error);
                            double durations[2];
                            CFTimeInterval starts[2], ends[2];
                            for (unsigned variant = 0; variant < 2; variant++)
                                durations[variant] = sstb_duration(
                                    timings[variant], &starts[variant],
                                    &ends[variant]);
                            NSData *pixels[2] = { sstb_read(outputs[0]),
                                                  sstb_read(outputs[1]) };
                            assert([pixels[0] isEqualToData:pixels[1]]);
                            unsigned order = trial & 1;
                            /* Commands' previous-submission event orders all
                             * future queue work. Validate actual timestamp
                             * windows as well; never assume non-overlap. */
                            assert(ends[order] <= starts[order ^ 1]);
                            if (trial >= 2) {
                                unsigned sample = trial - 2;
                                unsigned inOrder = orderCounts[order]++;
                                assert(inOrder < 5);
                                for (unsigned variant = 0; variant < 2;
                                     variant++) {
                                    times[variant][sample] = durations[variant];
                                    ordered[order][variant][inOrder] =
                                        durations[variant];
                                }
                                ratios[sample] = durations[0] / durations[1];
                                orderRatios[order][inOrder] = ratios[sample];
                            }
                        }
                    assert(orderCounts[0] == 5 && orderCounts[1] == 5);
                    for (unsigned variant = 0; variant < 2; variant++)
                        qsort(times[variant], 10, sizeof(double), sstb_compare);
                    qsort(ratios, 10, sizeof(double), sstb_compare);
                    printf(
                        "Shared taps fullscreen GPU kind%u %s1024x1024: "
                        "old/shared median %.6f/%.6f ms; range old[%.6f,%.6f] "
                        "shared[%.6f,%.6f] ms; paired old/shared ratio median "
                        "%.6f "
                        "range[%.6f,%.6f]; 2 warmups,10 balanced exact pairs,"
                        "back-to-back nonoverlapping commits,readbacks "
                        "separate,"
                        "pipelines prepared,CPU compiler excluded\n",
                        kind, collapsed ? "collapsed " : "normal ",
                        (times[0][4] + times[0][5]) * .5 * 1000,
                        (times[1][4] + times[1][5]) * .5 * 1000,
                        times[0][0] * 1000, times[0][9] * 1000,
                        times[1][0] * 1000, times[1][9] * 1000,
                        (ratios[4] + ratios[5]) * .5, ratios[0], ratios[9]);
                    for (unsigned order = 0; order < 2; order++) {
                        for (unsigned variant = 0; variant < 2; variant++)
                            qsort(ordered[order][variant], 5, sizeof(double),
                                  sstb_compare);
                        qsort(orderRatios[order], 5, sizeof(double),
                              sstb_compare);
                        printf("  %s-first n5 old/shared median %.6f/%.6f ms; "
                               "range old[%.6f,%.6f] shared[%.6f,%.6f] ms; "
                               "paired ratio median %.6f range[%.6f,%.6f]\n",
                               order ? "shared" : "old",
                               ordered[order][0][2] * 1000,
                               ordered[order][1][2] * 1000,
                               ordered[order][0][0] * 1000,
                               ordered[order][0][4] * 1000,
                               ordered[order][1][0] * 1000,
                               ordered[order][1][4] * 1000,
                               orderRatios[order][2], orderRatios[order][0],
                               orderRatios[order][4]);
                    }
                }
    } @finally {
        sstb_feedback = nil;
        method_setImplementation(feedback, (IMP)sstb_add_feedback_original);
    }
}
#endif
