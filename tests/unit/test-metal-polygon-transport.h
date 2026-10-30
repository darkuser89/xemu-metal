/* Conservative polygon carriers versus the previous GPU-projected AABB.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_TRANSPORT_H
#define TEST_METAL_POLYGON_TRANSPORT_H
#include "geometry-source.h"

static id<MTLComputePipelineState> pt_reference;
static id<MTLRenderPipelineState> pt_count_pipeline;
static id<MTL4ArgumentTable> pt_arguments;
static unsigned pt_pairs, pt_oriented, pt_bounds;
static uint64_t pt_written_depths;
static void (^pt_vertex_material)(NV2AMetalVertex *, unsigned);
static void (^pt_material)(NV2AMetalPixelUniforms *, NV2AMetalPixelTexture *);
static void pt_init(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = [@(metal_shader_source)
        stringByAppendingString:
            @"\nkernel void pt_aabb(device NV2AMetalVertex *v [[buffer(0)]],"
             "device const NV2AMetalPolygonProjection *p [[buffer(1)]],"
             "constant float2 &size [[buffer(2)]],uint id "
             "[[thread_position_in_grid]]){"
             "uint base=id*6;if(v[base].line_raster[2]!=2)return;"
             "float2 lo=size,hi=0;for(uint i=0;i<p[id].count;i++){"
             "float2 "
             "q(p[id].points[i][0],p[id].points[i][1]);lo=min(lo,q);hi=max(hi,"
             "q);}"
             "lo=max(lo-1,float2(0));hi=min(hi+1,size);"
             "float2 c[4]={lo,float2(hi.x,lo.y),float2(lo.x,hi.y),hi};"
             "const uint order[6]={0,1,2,2,1,3};for(uint i=0;i<6;i++){"
             "float2 q=c[order[i]]/size*2-1;v[base+i].clip[0]=q.x;"
             "v[base+i].clip[1]=-q.y;}}\n"
             "struct PTPosition{float4 p [[position]];};"
             "vertex PTPosition pt_vertex(device const NV2AMetalVertex *v "
             "[[buffer(0)]],"
             "uint id [[vertex_id]]){PTPosition o;o.p=float4(v[id].clip[0],"
             "v[id].clip[1],v[id].clip[2],v[id].clip[3]);return o;}"
             "fragment float4 pt_fragment(){return float4(0);}\n"];
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
    fn.name = @"pt_aabb";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    pt_reference = [compiler newComputePipelineStateWithDescriptor:pd
                                               compilerTaskOptions:nil
                                                             error:&error];
    require(pt_reference != nil, error);
    MTL4RenderPipelineDescriptor *rd = [MTL4RenderPipelineDescriptor new];
    MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new],
                                  *ff = [MTL4LibraryFunctionDescriptor new];
    vf.library = ff.library = library;
    vf.name = @"pt_vertex";
    ff.name = @"pt_fragment";
    rd.vertexFunctionDescriptor = vf;
    rd.fragmentFunctionDescriptor = ff;
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    rd.rasterSampleCount = 1;
    pt_count_pipeline = [compiler newRenderPipelineStateWithDescriptor:rd
                                                   compilerTaskOptions:nil
                                                                 error:&error];
    require(pt_count_pipeline != nil, error);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 3;
    ad.initializeBindings = YES;
    pt_arguments = [commands.device newArgumentTableWithDescriptor:ad
                                                             error:&error];
    require(pt_arguments != nil, error);
}
static id<MTLBuffer> pt_copy(id<MTLBuffer> source, MTLResourceOptions storage)
{
    NSError *error = nil;
    id<MTLBuffer> result = [commands.device newBufferWithLength:source.length
                                                        options:storage];
    assert(result);
    require([commands addResource:source error:&error] &&
                [commands addResource:result error:&error],
            error);
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
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static id<MTLBuffer> pt_old(NV2AMetalGeometryResult *g, unsigned size)
{
    NSError *error = nil;
    id<MTLBuffer> result = pt_copy(g.vertices, MTLResourceStorageModePrivate);
    float viewport[2] = { size, size };
    NSUInteger offset;
    id<MTLBuffer> constants = [commands uploadBytes:viewport
                                             length:sizeof(viewport)
                                             offset:&offset
                                              error:&error];
    require(constants != nil && [commands addResource:g.polygonProjections
                                                error:&error],
            error);
    [pt_arguments setAddress:result.gpuAddress atIndex:0];
    [pt_arguments setAddress:g.polygonProjections.gpuAddress atIndex:1];
    [pt_arguments setAddress:constants.gpuAddress + offset atIndex:2];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setArgumentTable:pt_arguments];
    [e setComputePipelineState:pt_reference];
    [e dispatchThreads:MTLSizeMake(g.vertexCount / 6, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static uint64_t pt_samples(id<MTLBuffer> vertices, NSUInteger count,
                           id<MTLTexture> target, unsigned size)
{
    NSError *error = nil;
    uint64_t zero = 0;
    id<MTLBuffer> result =
        [commands.device newBufferWithBytes:&zero
                                     length:8
                                    options:MTLResourceStorageModeShared];
    pp_begin();
    for (id<MTLResource> r in @[ result, vertices, target ])
        require([commands addResource:r error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
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
    [pt_arguments setAddress:vertices.gpuAddress atIndex:0];
    [e setArgumentTable:pt_arguments atStages:MTLRenderStageVertex];
    [e setRenderPipelineState:pt_count_pipeline];
    [e setViewport:(MTLViewport){ 0, 0, size, size, 0, 1 }];
    [e setCullMode:MTLCullModeNone];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    pp_finish();
    return *(uint64_t *)result.contents;
}
static void pt_containment(NV2AMetalGeometryResult *g, id<MTLBuffer> original,
                           id<MTLBuffer> previous, unsigned size)
{
    pp_begin();
    id<MTLBuffer> vertices = pt_copy(original, MTLResourceStorageModeShared),
                  old = pt_copy(previous, MTLResourceStorageModeShared),
                  projected = pt_copy(g.polygonProjections,
                                      MTLResourceStorageModeShared);
    pp_finish();
    const NV2AMetalVertex *v = vertices.contents, *before = old.contents;
    const NV2AMetalPolygonProjection *p = projected.contents;
    for (NSUInteger base = 0; base < g.vertexCount; base += 6) {
        for (unsigned i = 0; i < 6; i++) {
            NV2AMetalVertex copy = v[base + i];
            memcpy(copy.clip, before[base + i].clip, 8);
            assert(!memcmp(&copy, &before[base + i], sizeof(copy)));
        }
        if (!p[base / 6].count || !memcmp(v[base].clip, before[base].clip, 8))
            continue;
        pt_oriented++;
        PolygonPoint q[3];
        for (unsigned i = 0; i < 3; i++)
            q[i] = (PolygonPoint){ (v[base + i].clip[0] + 1) * size * .5,
                                   (1 - v[base + i].clip[1]) * size * .5 };
        PolygonPoint a = subtract(q[1], q[0]), b = subtract(q[2], q[0]);
        double determinant = cross_point(a, b);
        assert(isfinite(determinant) && determinant > 0);
        /* Independent inverse-parallelogram membership. Retain the pixel's
         * unit square and its adjacent 2x2 helper-quad centres at each hull
         * vertex, not just the visible polygon interior. */
        for (unsigned i = 0; i < p[base / 6].count; i++)
            for (unsigned corner = 0; corner < 4; corner++) {
                PolygonPoint point = {
                    p[base / 6].points[i][0] + (corner & 1 ? 1.5 : -1.5),
                    p[base / 6].points[i][1] + (corner & 2 ? 1.5 : -1.5)
                };
                point = subtract(point, q[0]);
                double u = cross_point(point, b) / determinant,
                       w = cross_point(a, point) / determinant;
                assert(u >= 0 && u <= 1 && w >= 0 && w <= 1);
            }
    }
}
static void pt_case(unsigned angle, unsigned shape, unsigned flags,
                    unsigned size, BOOL benchmark, BOOL geometryOnly,
                    NV2AMetalPixelShader *comparison)
{
    NSError *error = nil;
    unsigned repeats = benchmark ? 8 : 1;
    NV2AMetalVertex input[24];
    double a = angle * 3.141592653589793 / 8;
    PolygonPoint along = { cos(a), sin(a) }, normal = { -sin(a), cos(a) };
    float widths[] = { .03125f, .5f, 4, 32 };
    for (unsigned n = 0; n < repeats; n++)
        for (unsigned i = 0; i < 3; i++) {
            double t = (i ? .6 : -.6) * size;
            double width = i == 2 ? -widths[shape] : .125;
            PolygonPoint point = { size * .5 + along.x * t + normal.x * width,
                                   size * .5 + along.y * t + normal.y * width };
            float w = flags & 1 ? (float[]){ .25f, 1, 4 }[i] : 1;
            if ((flags & 2) && !i)
                w = -w;
            input[n * 3 + i] = vertex(point, w, i);
            if (pt_vertex_material)
                pt_vertex_material(&input[n * 3 + i], i);
            input[n * 3 + i].clip[0] = (point.x / (size * .5) - 1) * w;
            input[n * 3 + i].clip[1] = (1 - point.y / (size * .5)) * w;
            if (flags & (4 | 512))
                for (unsigned lane = 0; lane < 4; lane++)
                    input[n * 3 + i].clip[lane] = ldexpf(
                        input[n * 3 + i].clip[lane], flags & 512 ? -100 : 80);
        }
    if (flags & 8)
        for (unsigned n = 0; n < repeats; n++) {
            NV2AMetalVertex tmp = input[n * 3 + 1];
            input[n * 3 + 1] = input[n * 3 + 2];
            input[n * 3 + 2] = tmp;
        }
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:input
                                     length:repeats * 3 * sizeof(input[0])
                                    options:MTLResourceStorageModeShared];
    assert(source);
    pp_begin();
    NV2AMetalGeometryRasterConfig config = { .polygonSmooth = YES,
                                             .viewportWidth = size,
                                             .viewportHeight = size };
    NSArray<NV2AMetalGeometryResult *> *streams =
        [geometry encodeRasterVertices:source
                                 count:repeats * 3
                             primitive:NV2AMetalPrimitiveTriangles
                                config:&config
                                smooth:!(flags & 16)
                        firstProvoking:flags & 8
                          zPerspective:flags & 32
                              commands:commands
                                 error:&error];
    require(streams != nil, error);
    NV2AMetalGeometryResult *g = streams[0];
    id<MTLBuffer> buffers[2] = { g.vertices,
                                 comparison ? g.vertices : pt_old(g, size) };
    pp_finish();
    if (!comparison)
        pt_containment(g, buffers[0], buffers[1], size);
    if (geometryOnly) {
        pt_bounds++;
        return;
    }
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
    NV2AMetalDrawConfig draw = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ZENABLE |
                     NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16 },
        .blend = flags & 1024 ? NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12 :
                 flags & 64  ? NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8 :
                               0
    };
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&draw
                                             error:&error];
    require(raster != nil, error);
    NV2AMetalPixelUniforms u = { .smooth_shading = !(flags & 16),
                                 .two_side = 1,
                                 .surface_scale = { 1, 1 },
                                 .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, size, size } },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .z_perspective = !!(flags & 32),
                                 .alpha_test = !!(flags & 128),
                                 .alpha_func = 4,
                                 .alpha_ref = 64 };
    u.combiner.final_inputs[0] = flags & 256 ? PS_REGISTER_T0 : PS_REGISTER_V0;
    u.combiner.final_inputs[1] =
        ((flags & 256 ? PS_REGISTER_T0 : PS_REGISTER_V0) | PS_CHANNEL_ALPHA)
        << 8;
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTLTexture> sampled = nil;
    if (flags & 256) {
        td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:16
                                        height:16
                                     mipmapped:YES];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        sampled = [commands.device newTextureWithDescriptor:td];
        textures[0].texture = sampled;
        assert(textures[0].texture);
        for (unsigned level = 0; level < 5; level++) {
            unsigned width = 16 >> level;
            float data[16 * 16 * 4];
            for (unsigned i = 0; i < width * width * 4; i++)
                data[i] = (i * 71 + level * 19) % 256 / 255.f;
            [textures[0].texture
                replaceRegion:MTLRegionMake2D(0, 0, width, width)
                  mipmapLevel:level
                    withBytes:data
                  bytesPerRow:width * 16];
        }
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
    if (pt_material)
        pt_material(&u, textures);
    double times[2][9];
    for (unsigned trial = 0; trial < (benchmark ? 11u : 1u); trial++) {
        id<MTLBuffer> outputs[2][2];
        uint64_t counts[2];
        for (unsigned order = 0; order < 2; order++) {
            unsigned selected = (trial + order) & 1;
            pp_begin();
            uint64_t zero = 0;
            id<MTLBuffer> query = [commands.device
                newBufferWithBytes:&zero
                            length:8
                           options:MTLResourceStorageModeShared];
            assert(query);
            require([commands addResource:query error:&error], error);
            pass.visibilityResultBuffer = query;
            pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
            [g setValue:buffers[selected] forKey:@"vertices"];
            NV2AMetalPixelShader *saved = pixel;
            if (comparison && selected)
                pixel = comparison;
            require(pp_draw(g, 0, g.vertexCount, &u, textures, pass, raster,
                            YES, &error),
                    error);
            pixel = saved;
            pp_finish();
            if (benchmark && trial >= 2) {
                assert(pp_gpu_seconds > 0);
                times[selected][trial - 2] = pp_gpu_seconds;
            }
            counts[selected] = *(uint64_t *)query.contents;
            pp_begin();
            outputs[selected][0] = pp_read(color);
            outputs[selected][1] = pp_read(depth);
            pp_finish();
        }
        assert(counts[0] == counts[1]);
        for (unsigned attachment = 0; attachment < 2; attachment++) {
            if (memcmp(outputs[0][attachment].contents,
                       outputs[1][attachment].contents,
                       outputs[0][attachment].length)) {
                fprintf(stderr,
                        "Polygon transport angle%u shape%u flags%u "
                        "attachment%u differs\n",
                        angle, shape, flags, attachment);
                abort();
            }
        }
        const uint32_t *words = outputs[0][1].contents;
        NSUInteger row = (size * 4 + 255) & ~(NSUInteger)255;
        for (unsigned y = 0; y < size; y++)
            for (unsigned x = 0; x < size; x++)
                pt_written_depths += words[y * row / 4 + x] != 0x3f800000u;
        pt_pairs++;
    }
    [g setValue:buffers[0] forKey:@"vertices"];
    if (benchmark) {
        for (unsigned selected = 0; selected < 2; selected++)
            qsort(times[selected], 9, sizeof(double), pp_compare_time);
        if (comparison) {
            printf("Metal4 polygon quad discard:8 triangles/512x512,11 exact "
                   "color/depth/query pairs;2 warmups/9 alternating raster "
                   "GPU samples;early/late %.6f/%.6fms PASS\n",
                   times[0][4] * 1000, times[1][4] * 1000);
            return;
        }
        uint64_t samples[2] = {
            pt_samples(buffers[0], g.vertexCount, color, size),
            pt_samples(buffers[1], g.vertexCount, color, size)
        };
        assert(samples[0] < samples[1]);
        printf("Metal4 polygon carrier:8 triangles/512x512,11 exact "
               "color/depth/query pairs,"
               "2 warmups/9 alternating raster GPU samples;oriented/AABB "
               "%.6f/%.6fms;"
               "separate no-discard pass %llu/%llu raster samples PASS\n",
               times[0][4] * 1000, times[1][4] * 1000,
               (unsigned long long)samples[0], (unsigned long long)samples[1]);
    }
}
static void polygon_transport_tests(void)
{
    pt_init();
    for (unsigned angle = 0; angle < 16; angle++)
        for (unsigned shape = 0; shape < 4; shape++)
            for (unsigned mode = 0; mode < 4; mode++)
                @autoreleasepool {
                    unsigned flags = (mode & 1) | (mode & 2 ? 2 : 0) |
                                     ((angle & 1) ? 256 | 128 | 64 : 0) |
                                     ((angle & 2) ? 16 : 0) |
                                     ((angle & 4) ? 8 : 0) |
                                     ((angle & 8) ? 32 : 0);
                    pt_case(angle, shape, flags, 64, NO, NO, nil);
                }
    for (unsigned angle = 1; angle < 16; angle += 2)
        pt_case(angle, 0, 4 | 1 | 256, 128, NO, NO, nil);
    for (unsigned size = 0; size < 2; size++)
        for (unsigned angle = 0; angle < 16; angle++)
            for (unsigned mode = 0; mode < 4; mode++)
                pt_case(angle, 0, (unsigned[]){ 0, 1, 3, 512 | 1 }[mode],
                        size ? 16384 : 1, NO, YES, nil);
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    pp_feedback_original =
        (void *)method_setImplementation(feedback, (IMP)pp_feedback);
    pt_case(1, 2, 1, 512, YES, NO, nil);
    method_setImplementation(feedback, (IMP)pp_feedback_original);
    assert(pt_pairs == 275 && pt_bounds == 128 && pt_oriented &&
           pt_written_depths > 1000);
    printf("Metal4 polygon transport:%u exact color/depth/query pairs,%u "
           "oriented carriers,"
           "%llu non-clear depth words;128 additional 1px/16K viewport and "
           "small-W "
           "bounds checks;pixel/helper containment and unchanged "
           "metadata;"
           "thin/wide,16 directions,W/side clipping,large clip "
           "scales,flat/two-side/"
           "mip/AF/alpha/blend/W-depth PASS\n",
           pt_pairs, pt_oriented, (unsigned long long)pt_written_depths);
}
#endif
