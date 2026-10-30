/* Differential native tests of line transport, without an emulator/window.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_LINE_TRANSPORT_H
#define TEST_METAL_LINE_TRANSPORT_H
#include "geometry-source.h"
#import <objc/runtime.h>

static id<MTLComputePipelineState> lt_reference;
static id<MTLRenderPipelineState> lt_count_pipeline;
static id<MTL4ArgumentTable> lt_arguments;
static unsigned lt_pairs;
static uint64_t lt_written_depths;
static void (*lt_original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static double lt_gpu_seconds;

static void lt_feedback(id owner, SEL selector,
                        MTL4CommitFeedbackHandler handler)
{
    lt_original_feedback(owner, selector, ^(id<MTL4CommitFeedback> feedback) {
      lt_gpu_seconds = feedback.GPUEndTime - feedback.GPUStartTime;
      handler(feedback);
    });
}
static void lt_finish(void)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static void lt_init(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    /* Independent reconstruction of the previous clipped AABB. Only clip XY
     * changes; endpoint attributes and all coverage/depth metadata stay intact.
     * Both transports subsequently run through the real production fragment. */
    ld.source = [@(metal_shader_source)
        stringByAppendingString:
            @"\nkernel void old_line_transport(device NV2AMetalVertex *v "
            @"[[buffer(0)]], constant float2 &size [[buffer(1)]], uint id "
            @"[[thread_position_in_grid]]) {\n"
             " uint base=id*6; if(v[base].line_raster[2]!=1) return;\n"
             " float2 a(v[base].plane[2][0],v[base].plane[2][1]);\n"
             " float2 b(v[base].plane[2][2],v[base].plane[2][3]);\n"
             " float padding=v[base].line_raster[0]*.5f+2;\n"
             " float2 lo=max(min(a,b)-padding,float2(0));\n"
             " float2 hi=min(max(a,b)+padding,size);\n"
             " float2 c[4]={lo,float2(lo.x,hi.y),float2(hi.x,lo.y),hi};\n"
             " const uint order[6]={0,1,2,2,1,3};\n"
             " for(uint i=0;i<6;i++){float2 p=c[order[i]]/size*2-1;\n"
             " v[base+i].clip[0]=p.x;v[base+i].clip[1]=-p.y;} }\n"
             "struct LTPosition { float4 p [[position]]; };\n"
             "vertex LTPosition lt_vertex(device const NV2AMetalVertex *v "
             "[[buffer(0)]],uint id [[vertex_id]]) {\n"
             " LTPosition o; "
             "o.p=float4(v[id].clip[0],v[id].clip[1],v[id].clip[2],v[id].clip["
             "3]);return o;}\n"
             "fragment float4 lt_fragment(){ return float4(0); }\n"];
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
    fn.library = library;
    fn.name = @"old_line_transport";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    lt_reference = [compiler newComputePipelineStateWithDescriptor:pd
                                               compilerTaskOptions:nil
                                                             error:&error];
    require(lt_reference != nil, error);
    MTL4RenderPipelineDescriptor *rd = [MTL4RenderPipelineDescriptor new];
    MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
    vf.library = library;
    vf.name = @"lt_vertex";
    MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
    ff.library = library;
    ff.name = @"lt_fragment";
    rd.vertexFunctionDescriptor = vf;
    rd.fragmentFunctionDescriptor = ff;
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    rd.rasterSampleCount = 1;
    lt_count_pipeline = [compiler newRenderPipelineStateWithDescriptor:rd
                                                   compilerTaskOptions:nil
                                                                 error:&error];
    require(lt_count_pipeline != nil, error);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 2;
    ad.initializeBindings = YES;
    lt_arguments = [commands.device newArgumentTableWithDescriptor:ad
                                                             error:&error];
    require(lt_arguments != nil, error);
}
static id<MTLBuffer> lt_old(id<MTLBuffer> source, NSUInteger count,
                            unsigned size)
{
    NSError *error = nil;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModePrivate];
    assert(result && count % 6 == 0);
    float viewport[2] = { size, size };
    NSUInteger offset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:viewport
                                             length:sizeof(viewport)
                                             offset:&offset
                                              error:&error];
    require(constants != nil, error);
    require([commands addResource:source error:&error], error);
    require([commands addResource:result error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:result
        destinationOffset:0
                     size:result.length];
    [e barrierAfterEncoderStages:MTLStageBlit
             beforeEncoderStages:MTLStageDispatch
               visibilityOptions:MTL4VisibilityOptionDevice];
    [lt_arguments setAddress:result.gpuAddress atIndex:0];
    [lt_arguments setAddress:constants.gpuAddress + offset atIndex:1];
    [e setArgumentTable:lt_arguments];
    [e setComputePipelineState:lt_reference];
    [e dispatchThreads:MTLSizeMake(count / 6, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static id<MTLBuffer> lt_read(id<MTLTexture> texture)
{
    NSError *error = nil;
    NSUInteger bytes =
        texture.pixelFormat == MTLPixelFormatRGBA32Float ? 16 : 4;
    NSUInteger row = (texture.width * bytes + 255) & ~(NSUInteger)255;
    id<MTLBuffer> out =
        [commands.device newBufferWithLength:row * texture.height
                                     options:MTLResourceStorageModeShared];
    assert(out);
    require([commands addResource:out error:&error], error);
    require([commands addResource:texture error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                        toBuffer:out
               destinationOffset:0
          destinationBytesPerRow:row
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return out;
}
static uint64_t lt_samples(id<MTLBuffer> vertices, NSUInteger count,
                           id<MTLTexture> color, unsigned size)
{
    NSError *error = nil;
    uint64_t zero = 0;
    id<MTLBuffer> result =
        [commands.device newBufferWithBytes:&zero
                                     length:8
                                    options:MTLResourceStorageModeShared];
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:result error:&error], error);
    require([commands addResource:vertices error:&error], error);
    require([commands addResource:color error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    pass.visibilityResultBuffer = result;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [lt_arguments setAddress:vertices.gpuAddress atIndex:0];
    [e setArgumentTable:lt_arguments atStages:MTLRenderStageVertex];
    [e setRenderPipelineState:lt_count_pipeline];
    [e setViewport:(MTLViewport){ 0, 0, size, size, 0, 1 }];
    [e setCullMode:MTLCullModeNone];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    lt_finish();
    return *(uint64_t *)result.contents;
}
static int lt_compare_time(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void lt_case(LinePoint a, LinePoint b, float width, BOOL smooth,
                    unsigned flags, unsigned size, BOOL benchmark)
{
    NSError *error = nil;
    NSUInteger lineCount = benchmark ? 16 : 1;
    NV2AMetalVertex input[32] = { 0 };
    float wa = flags & 1 ? .25f : 1, wb = flags & 1 ? 4 : 1;
    if (flags & 2)
        wa = -wa;
    for (unsigned n = 0; n < lineCount; n++) {
        LinePoint positions[2] = { a, b };
        for (unsigned k = 0; k < 2; k++) {
            NV2AMetalVertex *v = &input[2 * n + k];
            float w = k ? wb : wa;
            v->clip[0] = (positions[k].x / (size * .5) - 1) * w;
            v->clip[1] = (1 - positions[k].y / (size * .5)) * w;
            v->clip[2] = .5f * w;
            v->clip[3] = w;
            v->screen[0] = positions[k].x;
            v->screen[1] = positions[k].y;
            v->screen[2] = 1000 + 2000 * k;
            v->screen[3] = w;
            v->color[0][0] = k ? .75f : .125f;
            v->color[0][1] = k ? .25f : .875f;
            v->color[0][2] = .5f;
            v->color[0][3] = 1;
            v->texcoord[0][0] = k ? 3.125f : -.125f;
            v->texcoord[0][1] = k ? 1.125f : -.125f;
            v->texcoord[0][3] = 1;
        }
    }
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:input
                                     length:lineCount * 2 * sizeof(input[0])
                                    options:MTLResourceStorageModeShared];
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryRasterConfig config = { .lineWidth = width,
                                             .lineSmooth = smooth,
                                             .viewportWidth = size,
                                             .viewportHeight = size };
    NSArray<NV2AMetalGeometryResult *> *g =
        [geometry encodeRasterVertices:source
                                 count:lineCount * 2
                             primitive:NV2AMetalPrimitiveLines
                                config:&config
                                smooth:!(flags & 4)
                        firstProvoking:flags & 8
                          zPerspective:flags & 16
                              commands:commands
                                 error:&error];
    require(g != nil, error);
    assert(g.count == 1);
    id<MTLBuffer> vertices[2] = {
        g[0].vertices, g[0].expandedLines ?
                           lt_old(g[0].vertices, g[0].vertexCount, size) :
                           g[0].vertices
    };
    lt_finish();
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [commands.device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    id<MTLTexture> depth = [commands.device newTextureWithDescriptor:td];
    assert(color && depth);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = flags & 32 ? PS_REGISTER_T0 : PS_REGISTER_V0;
    u.combiner.final_inputs[1] =
        ((flags & 32 ? PS_REGISTER_T0 : PS_REGISTER_V0) | PS_CHANNEL_ALPHA)
        << 8;
    u.smooth_shading = !(flags & 4);
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    u.depth_format = NV2AMetalPixelDepthD16;
    u.z_perspective = !!(flags & 16);
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTLTexture> sampled = nil;
    if (flags & 32) {
        td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:16
                                        height:16
                                     mipmapped:YES];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        sampled = [commands.device newTextureWithDescriptor:td];
        assert(sampled);
        for (unsigned level = 0; level < 5; level++) {
            unsigned w = 16 >> level;
            float data[16 * 16 * 4];
            for (unsigned i = 0; i < w * w * 4; i++)
                data[i] = (i * 71 + level * 19) % 256 / 255.f;
            [sampled replaceRegion:MTLRegionMake2D(0, 0, w, w)
                       mipmapLevel:level
                         withBytes:data
                       bytesPerRow:w * 16];
        }
        textures[0].texture = sampled;
        u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
        u.textures[0].dimension = 2;
        u.textures[0].scale = 1;
        u.textures[0].sampling =
            (NV2AMetalSamplingUniforms){ .enabled = 1,
                                         .address = { 1, 2, 3 },
                                         .min_linear = 1,
                                         .mag_linear = 1,
                                         .mip_filter = 2,
                                         .anisotropy = 4,
                                         .lod_bias = .125f };
    }
    NV2AMetalDrawConfig draw = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ZENABLE |
                     NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16 },
        .setup_raster = NV_PGRAPH_SETUPRASTER_CULLENABLE | 3 << 21,
        .blend = flags & 128 ? NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8 : 0,
    };
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&draw
                                             error:&error];
    require(raster != nil, error);
    u.alpha_test = !!(flags & 64);
    u.alpha_func = 4;
    u.alpha_ref = 127;
    double times[2][9];
    for (unsigned trial = 0; trial < (benchmark ? 11u : 1u); trial++) {
        id<MTLBuffer> output[2][2];
        for (unsigned order = 0; order < 2; order++) {
            unsigned selected = (order + trial) & 1;
            require([commands beginWithError:&error] != nil, error);
            require([pixel encodeVertices:vertices[selected]
                                      offset:0
                                       count:g[0].vertexCount
                                   primitive:g[0].primitiveType
                                    uniforms:&u
                                    textures:textures
                                        pass:pass
                                   drawState:raster
                        ignorePolygonCulling:YES
                                    commands:commands
                                       error:&error],
                    error);
            lt_finish();
            double gpu = lt_gpu_seconds;
            if (benchmark && trial >= 2) {
                assert(gpu > 0);
                times[selected][trial - 2] = gpu;
            }
            require([commands beginWithError:&error] != nil, error);
            output[selected][0] = lt_read(color);
            output[selected][1] = lt_read(depth);
            lt_finish();
        }
        for (unsigned attachment = 0; attachment < 2; attachment++) {
            assert(output[0][attachment].length ==
                   output[1][attachment].length);
            if (memcmp(output[0][attachment].contents,
                       output[1][attachment].contents,
                       output[0][attachment].length)) {
                fprintf(stderr,
                        "Line transport pair%u width%g smooth%d flags%u "
                        "attachment%u differs\n",
                        lt_pairs, width, smooth, flags, attachment);
                abort();
            }
        }
        const uint32_t *depthWords = output[0][1].contents;
        for (NSUInteger i = 0; i < size * size; i++)
            lt_written_depths += depthWords[i] != 0x3f800000u;
        lt_pairs++;
    }
    if (benchmark) {
        for (unsigned i = 0; i < 2; i++)
            qsort(times[i], 9, sizeof(double), lt_compare_time);
        uint64_t samples[2] = {
            lt_samples(vertices[0], g[0].vertexCount, color, size),
            lt_samples(vertices[1], g[0].vertexCount, color, size)
        };
        assert(samples[0] < samples[1]);
        printf("Metal4 line transport %s:16 lines/512x512,11 exact color+depth "
               "pairs,2 warmups/9 alternating GPU samples;oriented/AABB "
               "%.6f/%.6fms;separate no-discard visibility pass %llu/%llu "
               "raster samples PASS\n",
               smooth ? "smooth" : "aliased", times[0][4] * 1000,
               times[1][4] * 1000, (unsigned long long)samples[0],
               (unsigned long long)samples[1]);
    }
}
static void line_transport_tests(void)
{
    lt_init();
    const float widths[] = { .5f, 1, 1.49f, 1.5f, 2, 3, 8, 63, 16384 };
    for (unsigned angle = 0; angle < 16; angle++)
        for (unsigned smooth = 0; smooth < 2; smooth++)
            for (unsigned w = 0; w < sizeof(widths) / sizeof(*widths); w++)
                @autoreleasepool {
                    double a = angle * 3.141592653589793 / 8;
                    LinePoint p = { 32 - 42 * cos(a), 32 - 42 * sin(a) },
                              q = { 32 + 42 * cos(a), 32 + 42 * sin(a) };
                    lt_case(p, q, widths[w], smooth, (angle * 13 + w * 7) & 63,
                            64, NO);
                }
    for (unsigned angle = 0; angle < 16; angle++)
        for (unsigned smooth = 0; smooth < 2; smooth++)
            for (unsigned flat = 0; flat < 2; flat++)
                for (unsigned reverse = 0; reverse < 2; reverse++)
                    @autoreleasepool {
                        double a = angle * 3.141592653589793 / 8;
                        LinePoint p = { 64 - 85 * cos(a), 64 - 85 * sin(a) },
                                  q = { 64 + 85 * cos(a), 64 + 85 * sin(a) };
                        lt_case(reverse ? q : p, reverse ? p : q, 3, smooth,
                                1 | 32 | 64 | 128 | (flat ? 4 : 0) |
                                    (reverse ? 8 : 0) |
                                    ((angle & 3) == 3 ? 2 : 0),
                                128, NO);
                    }
    Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
    lt_original_feedback =
        (void *)method_setImplementation(method, (IMP)lt_feedback);
    lt_case((LinePoint){ 5.25, 7.75 }, (LinePoint){ 507.75, 503.25 }, 3, NO, 1,
            512, YES);
    lt_case((LinePoint){ 5.25, 7.75 }, (LinePoint){ 507.75, 503.25 }, 3, YES, 1,
            512, YES);
    method_setImplementation(method, (IMP)lt_original_feedback);
    assert(lt_pairs == 438 && lt_written_depths > 100000);
    printf(
        "Metal4 line transport:416 independent "
        "direction/width/smooth/clipping/attribute cases plus22 benchmark "
        "pairs;438 exact color/depth image pairs,%llu non-clear depth words; "
        "additional mip/AF/alpha/blend/flat/provoking pairs PASS\n",
        (unsigned long long)lt_written_depths);
}
#endif
