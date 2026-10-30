/* GPU projection reuse: differential bindings, slices and timing.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_PROJECTION_H
#define TEST_METAL_POLYGON_PROJECTION_H
#import <objc/runtime.h>

static unsigned pp_pairs, pp_rejects;
static uint64_t pp_depth_words;
static void (*pp_feedback_original)(id, SEL, MTL4CommitFeedbackHandler);
static double pp_gpu_seconds;
static void pp_feedback(id owner, SEL selector,
                        MTL4CommitFeedbackHandler handler)
{
    pp_feedback_original(owner, selector, ^(id<MTL4CommitFeedback> feedback) {
      pp_gpu_seconds = feedback.GPUEndTime - feedback.GPUStartTime;
      handler(feedback);
    });
}
static void pp_begin(void)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
}
static void pp_finish(void)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static id<MTLBuffer> pp_read(id<MTLTexture> texture)
{
    NSError *error = nil;
    NSUInteger bytes =
        texture.pixelFormat == MTLPixelFormatRGBA32Float ? 16 : 4;
    NSUInteger row = (texture.width * bytes + 255) & ~(NSUInteger)255;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:row * texture.height
                                     options:MTLResourceStorageModeShared];
    assert(result);
    require([commands addResource:result error:&error], error);
    require([commands addResource:texture error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
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
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static NV2AMetalPixelRasterClass pp_class(NV2AMetalGeometryResult *g)
{
    return g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
           g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
                                NV2AMetalPixelRasterNative;
}
static BOOL pp_draw(NV2AMetalGeometryResult *g, NSUInteger offset,
                    NSUInteger count, NV2AMetalPixelUniforms *u,
                    NV2AMetalPixelTexture *textures,
                    MTL4RenderPassDescriptor *pass, NV2AMetalDrawState *raster,
                    BOOL reuse, NSError **error)
{
    if (reuse)
        return [pixel encodeGeometry:g
                              offset:offset
                               count:count
                            uniforms:u
                            textures:textures
                                pass:pass
                           drawState:raster
                         rasterClass:pp_class(g)
                ignorePolygonCulling:YES
                       renderEncoder:nil
                            commands:commands
                               error:error];
    /* Same materialized vertices and raster specialization. Only the optional
     * projection binding differs, isolating the reuse from other fast paths. */
    return [pixel encodeVertices:g.vertices
                          offset:offset
                           count:count
                       primitive:g.primitiveType
                        uniforms:u
                        textures:textures
                            pass:pass
                       drawState:raster
                     rasterClass:pp_class(g)
            ignorePolygonCulling:YES
                   renderEncoder:nil
                        commands:commands
                           error:error];
}
static NSArray<NV2AMetalGeometryResult *> *
pp_geometry(unsigned topology, BOOL mixed, BOOL perspective, BOOL reverse,
            unsigned size, unsigned repeats)
{
    const unsigned modes[] = {
        NV2AMetalPrimitiveTriangles,   NV2AMetalPrimitiveTriangleStrip,
        NV2AMetalPrimitiveTriangleFan, NV2AMetalPrimitiveQuads,
        NV2AMetalPrimitiveQuadStrip,   NV2AMetalPrimitivePolygon
    };
    const unsigned counts[] = { 6, 6, 6, 8, 6, 6 };
    const float xy[8][2] = { { -.125f, .125f },  { .875f, .0625f },
                             { .25f, .9375f },   { .75f, .875f },
                             { .125f, .875f },   { 1.125f, .75f },
                             { .9375f, .0625f }, { .1875f, .9375f } };
    NSUInteger count = counts[topology] * repeats;
    NSMutableData *data =
        [NSMutableData dataWithLength:count * sizeof(NV2AMetalVertex)];
    NV2AMetalVertex *v = data.mutableBytes;
    for (unsigned n = 0; n < count; n++) {
        unsigned i = n % counts[topology];
        unsigned index = reverse ? counts[topology] - 1 - i : i;
        float w = perspective ? (float[]){ .25f, 1, 4 }[i % 3] : 1;
        v[n].clip[0] = (xy[index][0] * 2 - 1) * w;
        v[n].clip[1] = (1 - xy[index][1] * 2) * w;
        v[n].clip[2] = .5f * w;
        v[n].clip[3] = w;
        v[n].screen[0] = xy[index][0] * size;
        v[n].screen[1] = xy[index][1] * size;
        v[n].screen[2] = 1000 + i * 300;
        v[n].screen[3] = w;
        v[n].color[0][i % 3] = .75f;
        v[n].color[0][3] = 1;
        v[n].color[2][(i + 1) % 3] = .5f;
        v[n].color[2][3] = 1;
        v[n].texcoord[0][0] = xy[index][0] * 2;
        v[n].texcoord[0][1] = xy[index][1] * 2;
        v[n].texcoord[0][3] = 1;
    }
    NSError *error = nil;
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:data.bytes
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
    assert(source);
    NV2AMetalGeometryRasterConfig config = { .front = NV2AMetalPolygonFill,
                                             .back = mixed ?
                                                         NV2AMetalPolygonLine :
                                                         NV2AMetalPolygonFill,
                                             .polygonSmooth = YES,
                                             .viewportWidth = size,
                                             .viewportHeight = size };
    return [geometry encodeRasterVertices:source
                                    count:count
                                primitive:modes[topology]
                                   config:&config
                                   smooth:YES
                           firstProvoking:reverse
                             zPerspective:NO
                                 commands:commands
                                    error:&error];
}
static void pp_binding_checks(NV2AMetalGeometryResult *g,
                              NV2AMetalPixelUniforms *u,
                              NV2AMetalPixelTexture *textures,
                              MTL4RenderPassDescriptor *pass,
                              NV2AMetalDrawState *raster)
{
    id<MTLBuffer> original = g.polygonProjections;
    assert(original);
    pp_begin();
    for (unsigned bad = 0; bad < 8; bad++) {
        NSUInteger offset = 0, count = g.vertexCount;
        NV2AMetalPixelRasterClass rasterClass =
            NV2AMetalPixelRasterExpandedPolygon;
        if (bad == 0)
            offset = sizeof(NV2AMetalVertex);
        if (bad == 1)
            count = 3;
        if (bad == 2)
            offset = g.vertexCount * sizeof(NV2AMetalVertex) + 1;
        if (bad == 3)
            count++;
        if (bad == 4)
            rasterClass = NV2AMetalPixelRasterNative;
        if (bad == 5)
            [g setValue:nil forKey:@"polygonProjections"];
        if (bad == 6)
            [g setValue:[commands.device
                            newBufferWithLength:
                                sizeof(NV2AMetalPolygonProjection) - 1
                                        options:MTLResourceStorageModePrivate]
                 forKey:@"polygonProjections"];
        if (bad == 7)
            offset = NSUIntegerMax;
        assert(![pixel encodeGeometry:g
                               offset:offset
                                count:count
                             uniforms:u
                             textures:textures
                                 pass:pass
                            drawState:raster
                          rasterClass:rasterClass
                 ignorePolygonCulling:YES
                        renderEncoder:nil
                             commands:commands
                                error:NULL]);
        assert(commands.commandBuffer);
        [g setValue:original forKey:@"polygonProjections"];
        pp_rejects++;
    }
    [commands cancel];
    for (unsigned cancel = 0; cancel < 2; cancel++) {
        __weak id<MTLBuffer> weak = nil;
        @autoreleasepool {
            pp_begin();
            NSArray<NV2AMetalGeometryResult *> *fresh =
                pp_geometry(0, NO, NO, NO, 32, 1);
            assert(fresh && fresh[0].polygonProjections);
            weak = fresh[0].polygonProjections;
            NSError *error = nil;
            require(pp_draw(fresh[0], 0, fresh[0].vertexCount, u, textures,
                            pass, raster, YES, &error),
                    error);
        }
        assert(
            weak); /* Recording retains it after all geometry owners leave. */
        if (cancel)
            [commands cancel];
        else
            pp_finish();
        assert(!weak);
    }
    puts("Metal4 polygon projection bindings:8 pre-encode slice/length/class "
         "rejections;GPU ownership after geometry owner release,completion and "
         "cancellation PASS");
}
static int pp_compare_time(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void pp_case(unsigned topology, BOOL mixed, BOOL perspective,
                    BOOL slices, BOOL reverse, BOOL textured, BOOL benchmark,
                    BOOL includeGeometry)
{
    NSError *error = nil;
    unsigned size = benchmark ? 256 : 32;
    pp_begin();
    NSArray<NV2AMetalGeometryResult *> *streams = pp_geometry(
        topology, mixed, perspective, reverse, size, benchmark ? 4 : 1);
    require(streams != nil, error);
    pp_finish();
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
        .blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8
    };
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&draw
                                             error:&error];
    require(raster != nil, error);
    NV2AMetalPixelUniforms u = { 0 };
    u.smooth_shading = 1;
    u.two_side = 1;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    u.depth_format = NV2AMetalPixelDepthD16;
    u.combiner.final_inputs[0] = textured ? PS_REGISTER_T0 : PS_REGISTER_V0;
    u.combiner.final_inputs[1] =
        ((textured ? PS_REGISTER_T0 : PS_REGISTER_V0) | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTLTexture> sample = nil;
    if (textured) {
        td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:16
                                        height:16
                                     mipmapped:YES];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        sample = [commands.device newTextureWithDescriptor:td];
        assert(sample);
        for (unsigned level = 0; level < 5; level++) {
            unsigned w = 16 >> level;
            float data[16 * 16 * 4];
            for (unsigned i = 0; i < w * w * 4; i++)
                data[i] = (i * 71 + level * 19) % 256 / 255.f;
            [sample replaceRegion:MTLRegionMake2D(0, 0, w, w)
                      mipmapLevel:level
                        withBytes:data
                      bytesPerRow:w * 16];
        }
        textures[0].texture = sample;
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
        u.alpha_test = 1;
        u.alpha_func = 4;
        u.alpha_ref = 64;
    }
    if (!pp_rejects && !benchmark && !mixed && !textured && topology == 0)
        pp_binding_checks(streams[0], &u, textures, pass, raster);
    double times[2][9];
    for (unsigned trial = 0; trial < (benchmark ? 11u : 1u); trial++) {
        id<MTLBuffer> outputs[2][2];
        for (unsigned order = 0; order < 2; order++) {
            unsigned reuse = (trial + order) & 1;
            pp_begin();
            if (includeGeometry) {
                streams =
                    pp_geometry(topology, mixed, perspective, reverse, size, 4);
                require(streams != nil, error);
            }
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            BOOL groupedSlices = slices && topology != 5;
            NSUInteger rounds = groupedSlices ? streams[0].primitiveCount : 1;
            for (NSUInteger n = 0; n < rounds; n++)
                for (NV2AMetalGeometryResult *g in streams) {
                    NSUInteger count =
                        groupedSlices ? g.verticesPerPrimitive : g.vertexCount;
                    NSUInteger offset =
                        groupedSlices ? n * count * sizeof(NV2AMetalVertex) : 0;
                    require(pp_draw(g, offset, count, &u, textures, pass,
                                    raster, reuse, &error),
                            error);
                    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                    pass.depthAttachment.loadAction = MTLLoadActionLoad;
                }
            pp_finish();
            double gpu = pp_gpu_seconds;
            if (benchmark && trial >= 2) {
                assert(gpu > 0);
                times[reuse][trial - 2] = gpu;
            }
            pp_begin();
            outputs[reuse][0] = pp_read(color);
            outputs[reuse][1] = pp_read(depth);
            pp_finish();
        }
        for (unsigned attachment = 0; attachment < 2; attachment++) {
            assert(outputs[0][attachment].length ==
                   outputs[1][attachment].length);
            if (memcmp(outputs[0][attachment].contents,
                       outputs[1][attachment].contents,
                       outputs[0][attachment].length)) {
                fprintf(stderr,
                        "Projection pair%u topology%u mixed%d perspective%d "
                        "slices%d reverse%d texture%d attachment%u differs\n",
                        pp_pairs, topology, mixed, perspective, slices, reverse,
                        textured, attachment);
                const uint32_t *a = outputs[0][attachment].contents,
                               *b = outputs[1][attachment].contents;
                for (NSUInteger word = 0;
                     word < outputs[0][attachment].length / 4; word++)
                    if (a[word] != b[word]) {
                        fprintf(stderr, "First word%lu:0x%08x/0x%08x\n",
                                (unsigned long)word, a[word], b[word]);
                        break;
                    }
                abort();
            }
        }
        const uint32_t *z = outputs[1][1].contents;
        NSUInteger row = (size * 4 + 255) & ~(NSUInteger)255;
        for (unsigned y = 0; y < size; y++)
            for (unsigned x = 0; x < size; x++)
                pp_depth_words += z[y * row / 4 + x] != 0x3f800000u;
        pp_pairs++;
    }
    if (benchmark) {
        for (unsigned i = 0; i < 2; i++)
            qsort(times[i], 9, sizeof(double), pp_compare_time);
        printf("Metal4 polygon projection %s W/%s:256x256/eight triangles,11 "
               "exact pairs,2 warmups/9 alternating samples;GPU reused/legacy "
               "%.6f/%.6fms PASS\n",
               perspective ? "variable" : "equal",
               includeGeometry ? "geometry+raster" : "raster",
               times[1][4] * 1000, times[0][4] * 1000);
    }
}
static void polygon_projection_tests(void)
{
    for (unsigned topology = 0; topology < 6; topology++)
        for (unsigned mixed = 0; mixed < 2; mixed++)
            for (unsigned perspective = 0; perspective < 2; perspective++)
                for (unsigned slices = 0; slices < 2; slices++)
                    for (unsigned reverse = 0; reverse < 2; reverse++)
                        for (unsigned textured = 0; textured < 2; textured++)
                            @autoreleasepool {
                                pp_case(topology, mixed, perspective, slices,
                                        reverse, textured, NO, NO);
                            }
    Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
    pp_feedback_original =
        (void *)method_setImplementation(method, (IMP)pp_feedback);
    for (unsigned perspective = 0; perspective < 2; perspective++)
        for (unsigned combined = 0; combined < 2; combined++)
            pp_case(0, NO, perspective, NO, NO, NO, YES, combined);
    method_setImplementation(method, (IMP)pp_feedback_original);
    assert(pp_pairs == 236 && pp_depth_words > 10000 && pp_rejects == 8);
    printf("Metal4 polygon projection:192 topology/face/slice/filter pairs+44 "
           "benchmark pairs,236 exact color/depth image pairs,%llu non-clear "
           "depth words PASS\n",
           (unsigned long long)pp_depth_words);
}
#endif
