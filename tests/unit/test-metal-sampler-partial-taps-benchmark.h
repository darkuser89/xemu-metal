/* Complete fullscreen GPU durations; partial-axis work versus SHA941540.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_PARTIAL_TAPS_BENCHMARK_H
#define TEST_METAL_SAMPLER_PARTIAL_TAPS_BENCHMARK_H

static NSString *spb_source(BOOL reference)
{
    NSMutableString *source =
        [sampler_partial_taps_source(@(metal_shader_source), reference)
            mutableCopy];
    [source
        appendString:
            @"\nstruct SPTBenchVarying {float4 position [[position]];float2 "
            @"uv;};\n"
             "vertex SPTBenchVarying spb_vertex(uint i [[vertex_id]]){"
             "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};"
             "SPTBenchVarying "
             "v;v.position=float4(p[i],0,1);v.uv=p[i]*.5f+.5f;return v;}\n"];
    NSArray *types =
        @[ @"texture2d<float>", @"texture3d<float>", @"texturecube<float>" ];
    NSArray *normal = @[
        @".125f+v.uv*.75f", @"float3(.125f+v.uv*.75f,.375f+v.uv.x*.125f)",
        @"float3(v.uv*.5f-.25f,1)"
    ];
    NSArray *partial = @[
        @"float2(.375f,.125f+v.uv.y*.75f)",
        @"float3(.125f+v.uv*.75f,.375f+v.uv.x*.125f)",
        @"float3(1,v.uv.y*.5f-.25f,1)"
    ];
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned p = 0; p < 2; p++)
            [source appendFormat:
                        @"fragment float4 spb_fragment%u_%u(SPTBenchVarying v "
                        @"[[stage_in]],%@ t [[texture(0)]],constant "
                        @"NV2AMetalSamplingUniforms &s "
                        @"[[buffer(0)]]){constexpr sampler "
                        @"smp(coord::normalized,address::clamp_to_edge,filter::"
                        @"nearest);return nv2a_sample(t,smp,%@,s);}\n",
                        kind, p, types[kind], p ? partial[kind] : normal[kind]];
    return source;
}
static id<MTLTexture> spb_texture(unsigned kind, BOOL partial)
{
    SamplerPartialShape shape = { kind,
                                  kind == 0 && partial ? 1u :
                                  kind == 1            ? 16u :
                                                         64u,
                                  kind == 1 ? 16u : 64u,
                                  kind == 1 ? (partial ? 1u : 16u) : 1u,
                                  0,
                                  partial };
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:shape.width
                                    height:shape.height
                                 mipmapped:NO];
    d.textureType = kind == 1 ? MTLTextureType3D :
                    kind == 2 ? MTLTextureTypeCube :
                                MTLTextureType2D;
    d.depth = shape.depth;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:d];
    require(t != nil, nil);
    for (unsigned face = 0; face < (kind == 2 ? 6u : 1u); face++) {
        NSUInteger count = (NSUInteger)shape.width * shape.height * shape.depth;
        NSMutableData *data = [NSMutableData dataWithLength:count * 16];
        float *p = data.mutableBytes;
        assert(p);
        for (NSUInteger i = 0; i < count; i++)
            for (unsigned k = 0; k < 4; k++)
                p[4 * i + k] =
                    ((i * 37 + face * 19 + k * 53) % 251 + 1) / 256.f;
        [t replaceRegion:MTLRegionMake3D(0, 0, 0, shape.width, shape.height,
                                         shape.depth)
              mipmapLevel:0
                    slice:face
                withBytes:p
              bytesPerRow:shape.width * 16
            bytesPerImage:shape.width * shape.height * 16];
    }
    return t;
}
static void sampler_partial_taps_benchmark(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    id<MTLRenderPipelineState> pipelines[3][2][2];
    for (unsigned v = 0; v < 2; v++) {
        id<MTLLibrary> library = sst_library(compiler, spb_source(v == 0));
        for (unsigned kind = 0; kind < 3; kind++)
            for (unsigned p = 0; p < 2; p++) {
                MTL4LibraryFunctionDescriptor *vertex =
                                                  [MTL4LibraryFunctionDescriptor
                                                      new],
                                              *fragment =
                                                  [MTL4LibraryFunctionDescriptor
                                                      new];
                vertex.library = fragment.library = library;
                vertex.name = @"spb_vertex";
                fragment.name =
                    [NSString stringWithFormat:@"spb_fragment%u_%u", kind, p];
                MTL4RenderPipelineDescriptor *d =
                    [MTL4RenderPipelineDescriptor new];
                d.vertexFunctionDescriptor = vertex;
                d.fragmentFunctionDescriptor = fragment;
                d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
                d.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
                d.colorAttachments[0].blendingState = MTL4BlendStateDisabled;
                d.rasterSampleCount = 1;
                d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
                pipelines[kind][p][v] =
                    [compiler newRenderPipelineStateWithDescriptor:d
                                               compilerTaskOptions:nil
                                                             error:&error];
                require(pipelines[kind][p][v] != nil, error);
            }
    }
    /* One actual level with mip_filter2 keeps the production derivative path
     * enabled. Texture dimensions/coordinates alone select partial vs normal;
     * normal 2D's equal, untraversed z axis must not select the optimization.
     */
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
    Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
    assert(method);
    IMP saved = method_getImplementation(method);
    sstb_add_feedback_original = (void *)saved;
    method_setImplementation(method, (IMP)sstb_add_feedback);
    @try {
        for (unsigned kind = 0; kind < 3; kind++)
            for (unsigned partial = 0; partial < 2; partial++)
                @autoreleasepool {
                    id<MTLTexture> source = spb_texture(kind, partial);
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
                    double times[2][10] = { 0 }, ratios[10] = { 0 },
                           gaps[10] = { 0 };
                    double ordered[2][2][5] = { 0 }, orderRatios[2][5] = { 0 };
                    unsigned orderCounts[2] = { 0 };
                    for (unsigned trial = 0; trial < 12; trial++)
                        @autoreleasepool {
                            /* Each typed strong owner remains alive until both
                             * real callbacks and the common full wait have
                             * finished. */
                            SamplerSharedTapsBenchmarkFeedback *timings[2];
                            for (unsigned position = 0; position < 2;
                                 position++) {
                                unsigned v = (trial + position) & 1;
                                sstb_draw(pipelines[kind][partial][v], source,
                                          outputs[v], args, uniform);
                                timings[v] = sstb_submit();
                            }
                            require([commands waitUntilIdleWithError:&error],
                                    error);
                            CFTimeInterval starts[2], ends[2];
                            double durations[2];
                            for (unsigned v = 0; v < 2; v++)
                                durations[v] = sstb_duration(
                                    timings[v], &starts[v], &ends[v]);
                            /* Separate untimed native commits, after BOTH timed
                             * submissions. No readback or CPU wait splits a
                             * pair. */
                            NSData *pixels[2] = { sstb_read(outputs[0]),
                                                  sstb_read(outputs[1]) };
                            assert(pixels[0].length == 1024u * 1024u * 16u &&
                                   [pixels[0] isEqualToData:pixels[1]]);
                            unsigned order = trial & 1;
                            assert(ends[order] <= starts[order ^ 1]);
                            if (trial >= 2) {
                                unsigned sample = trial - 2,
                                         n = orderCounts[order]++;
                                assert(n < 5);
                                for (unsigned v = 0; v < 2; v++) {
                                    times[v][sample] = durations[v];
                                    ordered[order][v][n] = durations[v];
                                }
                                ratios[sample] = durations[0] / durations[1];
                                gaps[sample] = starts[order ^ 1] - ends[order];
                                orderRatios[order][n] = ratios[sample];
                            }
                        }
                    assert(orderCounts[0] == 5 && orderCounts[1] == 5);
                    for (unsigned v = 0; v < 2; v++)
                        qsort(times[v], 10, sizeof(double), sstb_compare);
                    qsort(ratios, 10, sizeof(double), sstb_compare);
                    qsort(gaps, 10, sizeof(double), sstb_compare);
                    printf(
                        "Partial taps GPU kind%u %s 1024x1024 old/new median "
                        "%.6f/%.6f ms ranges old[%.6f,%.6f] new[%.6f,%.6f]; "
                        "paired ratio %.6f [%.6f,%.6f]; gap median %.6f ms "
                        "[%.6f,%.6f];2warm+10balancedpairs,fullreadbacks "
                        "separate,pipelines prepared\n",
                        kind, partial ? "partial" : "normal",
                        (times[0][4] + times[0][5]) * 500,
                        (times[1][4] + times[1][5]) * 500, times[0][0] * 1000,
                        times[0][9] * 1000, times[1][0] * 1000,
                        times[1][9] * 1000, (ratios[4] + ratios[5]) * .5,
                        ratios[0], ratios[9], (gaps[4] + gaps[5]) * 500,
                        gaps[0] * 1000, gaps[9] * 1000);
                    for (unsigned order = 0; order < 2; order++) {
                        for (unsigned v = 0; v < 2; v++)
                            qsort(ordered[order][v], 5, sizeof(double),
                                  sstb_compare);
                        qsort(orderRatios[order], 5, sizeof(double),
                              sstb_compare);
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
    } @finally {
        sstb_feedback = nil;
        method_setImplementation(method, saved);
    }
}
#endif
