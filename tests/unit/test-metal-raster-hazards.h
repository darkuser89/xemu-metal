/* Compare production render-pass barriers with All -> All.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_RASTER_HAZARDS_H
#define TEST_METAL_RASTER_HAZARDS_H
#import "hw/xbox/nv2a/pgraph/metal/texture-sampler.h"

/* The reuse probe seeds each query through actual visibility draws, then
 * resets or accumulates those results. No compute shader writes query data. */
static BOOL rh_broad;
static MTLStages rh_pass_stages;
static unsigned rh_consumers, rh_producers;
static void (*rh_original_consumer)(id, SEL, MTLStages, MTLStages,
                                    MTL4VisibilityOptions);
static void (*rh_original_producer)(id, SEL, MTLStages, MTLStages,
                                    MTL4VisibilityOptions);
static void rh_consumer(id object, SEL selector, MTLStages after,
                        MTLStages before, MTL4VisibilityOptions options)
{
    assert(after == MTLStageAll && before == rh_pass_stages &&
           options == MTL4VisibilityOptionDevice);
    rh_consumers++;
    rh_original_consumer(object, selector, after,
                         rh_broad ? MTLStageAll : rh_pass_stages, options);
}
static void rh_producer(id object, SEL selector, MTLStages after,
                        MTLStages before, MTL4VisibilityOptions options)
{
    assert(after == rh_pass_stages && before == MTLStageAll &&
           options == MTL4VisibilityOptionDevice);
    rh_producers++;
    rh_original_producer(object, selector,
                         rh_broad ? MTLStageAll : rh_pass_stages, before,
                         options);
}
static id<MTLTexture> rh_texture(id<MTLDevice> device, MTLPixelFormat format,
                                 unsigned size, unsigned samples,
                                 MTLTextureUsage usage)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType =
        samples == 1 ? MTLTextureType2D : MTLTextureType2DMultisample;
    d.pixelFormat = format;
    d.width = d.height = size;
    d.sampleCount = samples;
    d.storageMode = MTLStorageModePrivate;
    d.usage = usage;
    id<MTLTexture> t = [device newTextureWithDescriptor:d];
    assert(t);
    return t;
}
static void raster_hazards_test(NV2AMetalCommands *commands, BOOL reuseQuery,
                                BOOL noQuery)
{
    assert(!reuseQuery || !noQuery);
    NSError *error = nil;
    id<MTLDevice> device = commands.device;
    const unsigned size = 32, frames = 8, trials = 11;
    const unsigned vertexWords = 6 * sizeof(NV2AMetalVertex) / 4;
    /* CPU fixtures are immutable; only GPU producers write the live private
     * vertex buffer and sampled texture. Queries use the production pattern of
     * separate CPU-initialized Shared buffers; the reuse probe uses one
     * Private counter across actual reset/accumulate passes. The GPU
     * consumer reads all color/depth/stencil samples and query counts, before
     * the next producer overwrites those same vertex/texture inputs. */
    NSString *source =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "kernel void rh_produce(device const uint *seed [[buffer(0)]],"
         "device uint *v [[buffer(1)]],constant uint4 &p [[buffer(2)]],"
         "texture2d<float,access::write> t "
         "[[texture(0)]],"
         "uint id [[thread_position_in_grid]]){"
         "if(id<p.w)v[id]=seed[p.x*p.w+id];"
         "if(id<p.y*p.y){uint2 xy=uint2(id%p.y,id/p.y);"
         "t.write(float4((xy.x/4+p.z)&1,(xy.y/"
         "4+(p.z>>1))&1,(p.z>>2)&1,1),xy);}}\n";
    for (unsigned ms = 0; ms < 2; ms++) {
        NSString *suffix = ms ? @"_ms" : @"";
        NSString *sample = ms ? @",s" : @"";
        source = [source
            stringByAppendingFormat:
                @"kernel void rh_consume%u(texture2d%@<float,access::read> c "
                @"[[texture(0)]],"
                 "depth2d%@<float,access::read> d [[texture(1)]],"
                 "texture2d%@<uint,access::read> st [[texture(2)]],"
                 "texture2d<float,access::read> resolved [[texture(3)]],"
                 "device uint *out [[buffer(0)]],device uint2 *q [[buffer(1)]],"
                 "device uint2 *counts [[buffer(2)]],constant uint4 &p "
                 "[[buffer(3)]],"
                 "uint id [[thread_position_in_grid]]){"
                 "if(id>=p.y*p.y)return;uint2 xy=uint2(id%%p.y,id/p.y);"
                 "uint base=(p.x*p.y*p.y+id)*(p.w*6+4);"
                 "for(uint s=0;s<p.w;s++){uint at=base+s*6;"
                 "float4 color=(p.z&2)?float4(0):c.read(xy%@);float "
                 "z=d.read(xy%@);uint "
                 "stencil=st.read(xy%@).r;"
                 "for(uint k=0;k<4;k++)out[at+k]=as_type<uint>(color[k]);"
                 "out[at+4]=as_type<uint>(z);out[at+5]=stencil;}"
                 "float4 r=(p.z&1)?resolved.read(xy):float4(0);for(uint "
                 "k=0;k<4;k++)out[base+p.w*6+k]=as_type<uint>(r[k]);"
                 "if(id==0)counts[p.x]=q[0];}\n",
                ms, suffix, suffix, suffix, sample, sample, sample];
    }
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = source;
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    id<MTLComputePipelineState> pipelines[3];
    for (unsigned i = 0; i < 3; i++) {
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = i == 0 ? @"rh_produce" :
                           [NSString stringWithFormat:@"rh_consume%u", i - 1];
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        pipelines[i] = [compiler newComputePipelineStateWithDescriptor:pd
                                                   compilerTaskOptions:nil
                                                                 error:&error];
        require(pipelines[i] != nil, error);
    }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 4;
    ad.maxTextureBindCount = 4;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> args = [device newArgumentTableWithDescriptor:ad
                                                                  error:&error];
    require(args != nil, error);
    id<MTLTexture> probeTarget = rh_texture(
        device, MTLPixelFormatRGBA8Unorm, size, 1, MTLTextureUsageRenderTarget);
    require([commands beginWithError:&error] != nil, error);
    MTL4RenderPassDescriptor *probePass = [MTL4RenderPassDescriptor new];
    probePass.colorAttachments[0].texture = probeTarget;
    id<MTL4RenderCommandEncoder> probe =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:probePass];
    assert(probe);
    Class cls = object_getClass(probe);
    Method cm = class_getInstanceMethod(
        cls, @selector(barrierAfterQueueStages:
                                  beforeStages:visibilityOptions:));
    Method pm = class_getInstanceMethod(
        cls, @selector(barrierAfterStages:
                        beforeQueueStages:visibilityOptions:));
    assert(cm && pm);
    class_addMethod(cls, method_getName(cm), method_getImplementation(cm),
                    method_getTypeEncoding(cm));
    class_addMethod(cls, method_getName(pm), method_getImplementation(pm),
                    method_getTypeEncoding(pm));
    cm = class_getInstanceMethod(cls, method_getName(cm));
    pm = class_getInstanceMethod(cls, method_getName(pm));
    [probe endEncoding];
    [commands cancel];
    rh_original_consumer =
        (void *)method_setImplementation(cm, (IMP)rh_consumer);
    rh_original_producer =
        (void *)method_setImplementation(pm, (IMP)rh_producer);
    Method fm = class_getInstanceMethod(MTL4CommitOptions.class,
                                        @selector(addFeedbackHandler:));
    group_original_feedback =
        (void *)method_setImplementation(fm, (IMP)group_feedback);
    unsigned pairs = 0, samplesChecked = 0, queryChecks = 0;
    for (unsigned shape = 0; shape < 7; shape++)
        for (unsigned format = 0; format < 2; format++)
            for (unsigned grouped = 0; grouped < 2; grouped++) {
                @autoreleasepool {
                    unsigned samples = shape == 0               ? 1 :
                                       shape <= 2 || shape == 5 ? 2 :
                                                                  4;
                    BOOL resolveOnly = shape >= 5;
                    unsigned resolveMode =
                        shape == 2 || shape == 4 || resolveOnly;
                    MTLPixelFormat pf = format ? MTLPixelFormatRGBA32Float :
                                                 MTLPixelFormatRGBA8Unorm;
                    MTLTextureUsage usage = MTLTextureUsageRenderTarget |
                                            MTLTextureUsageShaderRead |
                                            MTLTextureUsagePixelFormatView;
                    id<MTLTexture> color =
                        rh_texture(device, pf, size, samples, usage);
                    id<MTLTexture> resolved =
                        samples == 1 ? color :
                                       rh_texture(device, pf, size, 1, usage);
                    id<MTLTexture> depth =
                        rh_texture(device, MTLPixelFormatDepth32Float_Stencil8,
                                   size, samples, usage);
                    id<MTLTexture> stencil =
                        [depth newTextureViewWithPixelFormat:
                                   MTLPixelFormatX32_Stencil8];
                    id<MTLTexture> tex = rh_texture(
                        device, MTLPixelFormatRGBA8Unorm, size, 1,
                        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
                    assert(stencil);
                    NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
                        initWithDevice:device
                           colorFormat:pf
                           depthFormat:depth.pixelFormat
                           sampleCount:samples
                                 error:&error];
                    require(shader != nil, error);
                    NV2AMetalTextureSampler *sampler =
                        [[NV2AMetalTextureSampler alloc] initWithDevice:device
                                                                  error:&error];
                    NV2AMetalSamplerConfig sc = { .filter =
                                                      (1 << 16) | (1 << 24),
                                                  .address = 3 | (3 << 8),
                                                  .anisotropy = 1 };
                    NV2AMetalTextureBinding *binding =
                        [sampler bindingForTexture:tex config:&sc error:&error];
                    require(binding != nil, error);
                    id<MTLBuffer> live = [device
                        newBufferWithLength:vertexWords * 4
                                    options:MTLResourceStorageModePrivate];
                    NSMutableArray<id<MTLBuffer>> *queries =
                        [NSMutableArray new];
                    for (unsigned frame = 0; frame < frames; frame++) {
                        id<MTLBuffer> q =
                            reuseQuery && frame ?
                                queries[0] :
                                [device
                                    newBufferWithLength:8
                                                options:
                                                    reuseQuery ?
                                                        MTLResourceStorageModePrivate :
                                                        MTLResourceStorageModeShared];
                        assert(q);
                        [queries addObject:q];
                    }
                    id<MTLBuffer> out = [device
                        newBufferWithLength:frames * size * size *
                                            (samples * 6 + 4) * 4
                                    options:MTLResourceStorageModeShared];
                    id<MTLBuffer> counts = [device
                        newBufferWithLength:frames * 8
                                    options:MTLResourceStorageModeShared];
                    assert(live && out && counts);
                    double times[2][9];
                    for (unsigned trial = 0; trial < trials; trial++) {
                        NSMutableData *seedData = [NSMutableData
                            dataWithLength:frames * vertexWords * 4];
                        NV2AMetalVertex *v = seedData.mutableBytes;
                        for (unsigned frame = 0; frame < frames; frame++)
                            for (unsigned i = 0; i < 6; i++) {
                                unsigned seed = trial * frames + frame;
                                const float xy[6][2] = { { 0, 0 }, { 1, 0 },
                                                         { 0, 1 }, { 1, 0 },
                                                         { 1, 1 }, { 0, 1 } };
                                float x = xy[i][0] * (frame == 1 ? .5f : 1),
                                      y = xy[i][1];
                                NV2AMetalVertex *a = &v[frame * 6 + i];
                                a->clip[0] = x * 2 - 1;
                                a->clip[1] = 1 - y * 2;
                                a->clip[2] = .5;
                                a->clip[3] = 1;
                                for (unsigned k = 0; k < 4; k++)
                                    a->color[0][k] =
                                        k == 3 ? 1 : (seed >> k) & 1;
                                a->texcoord[0][0] = x;
                                a->texcoord[0][1] = y;
                                a->texcoord[0][3] = 1;
                                a->plane[1][0] = a->plane[2][1] = size;
                                for (unsigned k = 0; k < 3; k++)
                                    a->plane[k][2] = 8388608 + frame * 1024;
                            }
                        id<MTLBuffer> seedBuffer = [device
                            newBufferWithBytes:seedData.bytes
                                        length:seedData.length
                                       options:MTLResourceStorageModeShared];
                        NSData *previous = nil, *previousCounts = nil;
                        for (unsigned variant = 0; variant < 2; variant++) {
                            rh_broad = (variant ^ (trial & 1)) == 0;
                            memset(out.contents, 0x5a, out.length);
                            memset(counts.contents, 0x5a, counts.length);
                            if (!reuseQuery)
                                for (id<MTLBuffer> q in queries)
                                    memset(q.contents, 0, 8);
                            require([commands beginWithError:&error] != nil,
                                    error);
                            for (id<MTLResource> r in @[
                                     color, resolved, depth, stencil, tex, live,
                                     out, counts, seedBuffer
                                 ])
                                require([commands addResource:r error:&error],
                                        error);
                            require([commands keepAlive:args error:&error],
                                    error);
                            for (unsigned frame = 0; frame < frames; frame++) {
                                id<MTLBuffer> query = queries[frame];
                                require([commands addResource:query
                                                        error:&error],
                                        error);
                                uint32_t p[4] = { frame, size,
                                                  trial * frames + frame,
                                                  vertexWords };
                                id<MTLBuffer> params = [device
                                    newBufferWithBytes:p
                                                length:sizeof(p)
                                               options:
                                                   MTLResourceStorageModeShared];
                                require([commands addResource:params
                                                        error:&error],
                                        error);
                                id<MTL4ComputeCommandEncoder> e =
                                    [commands.commandBuffer
                                            computeCommandEncoder];
                                assert(e);
                                // Orders only the previous compute consumer's
                                // output read before overwriting vertex/texture
                                // data.
                                [e barrierAfterQueueStages:MTLStageDispatch
                                              beforeStages:MTLStageDispatch
                                         visibilityOptions:
                                             MTL4VisibilityOptionDevice];
                                [args setAddress:seedBuffer.gpuAddress
                                         atIndex:0];
                                [args setAddress:live.gpuAddress atIndex:1];
                                [args setAddress:params.gpuAddress atIndex:2];
                                [args setTexture:tex.gpuResourceID atIndex:0];
                                [e setComputePipelineState:pipelines[0]];
                                [e setArgumentTable:args];
                                [e dispatchThreads:MTLSizeMake(MAX(size * size,
                                                                   vertexWords),
                                                               1, 1)
                                    threadsPerThreadgroup:MTLSizeMake(64, 1,
                                                                      1)];
                                [e endEncoding]; // Pixel's consumer must
                                                 // protect its inputs.
                                NV2AMetalDrawConfig config = { 0 };
                                config.control[0] =
                                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_ZENABLE |
                                    NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                    (frame == 3 ? 0u : 3u) << 16;
                                config.control[1] =
                                    NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                    (frame == 4 ? 0u : 7u) << 4 | 0xffu << 16 |
                                    0xffu << 24;
                                config.control[2] = 1 | 1 << 4 | 4 << 8;
                                if (frame == 1 || frame == 5) {
                                    config.scissor_enabled = YES;
                                    config.scissor = (MTLScissorRect){
                                        0, 0, frame == 5 ? 0 : size / 4, size
                                    };
                                }
                                if (frame == 6 && !format)
                                    config.blend =
                                        NV_PGRAPH_BLEND_LOGICOP_ENABLE |
                                        5 << 12;
                                if (frame == 7)
                                    config.control[0] |=
                                        NV_PGRAPH_CONTROL_0_DITHERENABLE;
                                NV2AMetalDrawState *state =
                                    [[NV2AMetalDrawState alloc]
                                        initWithDevice:device
                                                config:&config
                                                 error:&error];
                                require(state != nil, error);
                                NV2AMetalPixelUniforms u = uniforms();
                                u.clip_range[1] = u.clip_range[3] = 16777215;
                                u.clip_regions[0][2] = u.clip_regions[0][3] =
                                    size;
                                u.alpha_test = frame == 2;
                                u.alpha_func = 1;
                                u.combiner.shader_stage_program =
                                    PS_TEXTUREMODES_PROJECT2D;
                                unsigned reg =
                                    frame & 1 ? PS_REGISTER_V0 : PS_REGISTER_T0;
                                u.combiner.final_inputs[0] = reg;
                                u.combiner.final_inputs[1] =
                                    (reg | PS_CHANNEL_ALPHA) << 8;
                                u.textures[0].sampling = binding.sampling;
                                NV2AMetalPixelTexture bindings[4] = { 0 };
                                bindings[0].texture = tex;
                                bindings[0].sampler = binding.sampler;
                                MTL4RenderPassDescriptor *pass =
                                    [MTL4RenderPassDescriptor new];
                                pass.colorAttachments[0].texture = color;
                                pass.colorAttachments[0].clearColor =
                                    MTLClearColorMake(0, 0, 0, 0);
                                pass.colorAttachments[0].loadAction =
                                    MTLLoadActionClear;
                                pass.colorAttachments[0].storeAction =
                                    resolveOnly ?
                                        MTLStoreActionMultisampleResolve :
                                    samples == 1 || !resolveMode ?
                                        MTLStoreActionStore :
                                        MTLStoreActionStoreAndMultisampleResolve;
                                if (samples != 1 && resolveMode)
                                    pass.colorAttachments[0].resolveTexture =
                                        resolved;
                                pass.depthAttachment.texture =
                                    pass.stencilAttachment.texture = depth;
                                pass.depthAttachment.loadAction =
                                    pass.stencilAttachment.loadAction =
                                        MTLLoadActionClear;
                                pass.depthAttachment.storeAction =
                                    pass.stencilAttachment.storeAction =
                                        MTLStoreActionStore;
                                pass.depthAttachment.clearDepth = 1;
                                pass.visibilityResultBuffer =
                                    noQuery ? nil : query;
                                pass.visibilityResultType =
                                    (reuseQuery ? frame % 3 == 0 : frame & 1) ?
                                        MTLVisibilityResultTypeReset :
                                        MTLVisibilityResultTypeAccumulate;
                                rh_pass_stages = nv2a_metal_pixel_pass_stages();
                                assert(rh_pass_stages ==
                                       (MTLStageVertex | MTLStageFragment));
                                id<MTL4RenderCommandEncoder> encoder = nil;
                                if (grouped) {
                                    encoder = [commands.commandBuffer
                                        renderCommandEncoderWithDescriptor:
                                            pass];
                                    assert(encoder);
                                    [encoder
                                        barrierAfterQueueStages:MTLStageAll
                                                   beforeStages:rh_pass_stages
                                              visibilityOptions:
                                                  MTL4VisibilityOptionDevice];
                                    [encoder
                                        setVisibilityResultMode:
                                            noQuery ?
                                                MTLVisibilityResultModeDisabled :
                                                MTLVisibilityResultModeCounting
                                                         offset:0];
                                }
                                for (unsigned draw = 0;
                                     draw < (grouped ? 2u : 1u); draw++)
                                    require(
                                        [shader encodeVertices:live
                                                          offset:0
                                                           count:6
                                                       primitive:
                                                           MTLPrimitiveTypeTriangle
                                                        uniforms:&u
                                                        textures:bindings
                                                            pass:pass
                                                       drawState:state
                                                     rasterClass:
                                                         NV2AMetalPixelRasterNative
                                            ignorePolygonCulling:NO
                                                   renderEncoder:encoder
                                                        commands:commands
                                                           error:&error],
                                        error);
                                if (encoder) {
                                    [encoder barrierAfterStages:rh_pass_stages
                                              beforeQueueStages:MTLStageAll
                                              visibilityOptions:
                                                  MTL4VisibilityOptionDevice];
                                    [encoder endEncoding];
                                }
                                /* Resolve-only discards the MSAA color
                                 * attachment. Read only its resolved target;
                                 * depth/stencil attachments remain stored. */
                                uint32_t cp[4] = {
                                    frame, size,
                                    (samples == 1 || resolveMode ? 1u : 0u) |
                                        (resolveOnly ? 2u : 0u),
                                    samples
                                };
                                params = [device
                                    newBufferWithBytes:cp
                                                length:sizeof(cp)
                                               options:
                                                   MTLResourceStorageModeShared];
                                require([commands addResource:params
                                                        error:&error],
                                        error);
                                e = [commands
                                         .commandBuffer computeCommandEncoder];
                                assert(e);
                                // No consumer barrier: pixel's producer must
                                // publish all results.
                                [args setAddress:out.gpuAddress atIndex:0];
                                [args setAddress:query.gpuAddress atIndex:1];
                                [args setAddress:counts.gpuAddress atIndex:2];
                                [args setAddress:params.gpuAddress atIndex:3];
                                [args setTexture:color.gpuResourceID atIndex:0];
                                [args setTexture:depth.gpuResourceID atIndex:1];
                                [args setTexture:stencil.gpuResourceID
                                         atIndex:2];
                                [args setTexture:resolved.gpuResourceID
                                         atIndex:3];
                                [e setComputePipelineState:
                                        pipelines[samples == 1 ? 1 : 2]];
                                [e setArgumentTable:args];
                                [e dispatchThreads:MTLSizeMake(size * size, 1,
                                                               1)
                                    threadsPerThreadgroup:MTLSizeMake(64, 1,
                                                                      1)];
                                [e endEncoding];
                            }
                            require([commands submitWithError:&error], error);
                            require([commands waitUntilIdleWithError:&error],
                                    error);
                            assert(group_gpu_seconds > 0);
                            if (trial >= 2)
                                times[rh_broad][trial - 2] = group_gpu_seconds;
                            const uint32_t *bytes = out.contents;
                            const uint64_t *q = counts.contents;
                            uint64_t accumulated = 0;
                            for (unsigned frame = 0; frame < frames; frame++) {
                                BOOL draw = frame != 2 && frame != 3 &&
                                            frame != 4 && frame != 5;
                                unsigned width = frame == 1 ? size / 4 : size;
                                if (!reuseQuery || frame % 3 == 0)
                                    accumulated = 0;
                                accumulated += noQuery || !draw ?
                                                   0 :
                                                   width * size * samples *
                                                       (grouped ? 2 : 1);
                                uint64_t want = accumulated;
                                if (q[frame] != want) {
                                    fprintf(stderr,
                                            "Raster query broad%u reuse%u "
                                            "samples%u format%u "
                                            "group%u frame%u:%llu/%llu\n",
                                            rh_broad, reuseQuery, samples,
                                            format, grouped, frame,
                                            (unsigned long long)q[frame],
                                            (unsigned long long)want);
                                    abort();
                                }
                                queryChecks++;
                                float depthValue =
                                    (8388608 + frame * 1024) / 16777216.f;
                                uint32_t z;
                                memcpy(&z, &depthValue, 4);
                                z++;
                                unsigned seed = trial * frames + frame;
                                for (unsigned y = 0; y < size; y++)
                                    for (unsigned x = 0; x < size; x++)
                                        for (unsigned s = 0; s < samples; s++) {
                                            BOOL hit = draw && x < width;
                                            uint32_t expected[6] = {
                                                0,
                                                0,
                                                0,
                                                0,
                                                hit ? z : 0x3f800000,
                                                hit ? (grouped ? 2u : 1u) : 0
                                            };
                                            if (hit && !(frame == 6 && !format))
                                                for (unsigned k = 0; k < 4;
                                                     k++) {
                                                    unsigned c =
                                                        k == 3 ?
                                                            1 :
                                                        (frame & 1) ?
                                                            (seed >> k) & 1 :
                                                        k == 0 ?
                                                            (x / 4 + seed) & 1 :
                                                        k == 1 ?
                                                            (y / 4 +
                                                             (seed >> 1)) &
                                                                1 :
                                                            (seed >> 2) & 1;
                                                    expected[k] =
                                                        c ? 0x3f800000 : 0;
                                                }
                                            NSUInteger at =
                                                (frame * size * size +
                                                 y * size + x) *
                                                    (samples * 6 + 4) +
                                                s * 6;
                                            uint32_t stored[6];
                                            memcpy(stored, expected,
                                                   sizeof(stored));
                                            if (resolveOnly)
                                                memset(stored, 0,
                                                       4 * sizeof(uint32_t));
                                            if (memcmp(bytes + at, stored,
                                                       sizeof(stored))) {
                                                fprintf(
                                                    stderr,
                                                    "Raster pixels samples%u "
                                                    "format%u group%u frame%u "
                                                    "xy%u,%u sample%u\n",
                                                    samples, format, grouped,
                                                    frame, x, y, s);
                                                for (unsigned k = 0; k < 6; k++)
                                                    fprintf(stderr,
                                                            " %08x/%08x",
                                                            bytes[at + k],
                                                            stored[k]);
                                                fputc('\n', stderr);
                                                abort();
                                            }
                                            if (!s) {
                                                NSUInteger resolveAt =
                                                    at + samples * 6;
                                                assert(!memcmp(
                                                    bytes + resolveAt,
                                                    samples == 1 ||
                                                            resolveMode ?
                                                        expected :
                                                        (uint32_t[4]){ 0 },
                                                    4 * sizeof(uint32_t)));
                                            }
                                            samplesChecked++;
                                        }
                            }
                            if (!variant) {
                                previous = [NSData dataWithBytes:out.contents
                                                          length:out.length];
                                previousCounts =
                                    [NSData dataWithBytes:counts.contents
                                                   length:counts.length];
                            } else {
                                assert(!memcmp(previous.bytes, out.contents,
                                               out.length));
                                assert(!memcmp(previousCounts.bytes,
                                               counts.contents, counts.length));
                                pairs++;
                            }
                        }
                    }
                    qsort(times[0], 9, sizeof(double), group_compare_time);
                    qsort(times[1], 9, sizeof(double), group_compare_time);
                    printf("Raster barrier GPU samples%u format%u group%u "
                           "resolve%u only%u reuse%u noQuery%u:8 "
                           "passes,candidate/broad %.6f/%.6fms;2 warmups/9 "
                           "alternating pairs\n",
                           samples, format, grouped, resolveMode, resolveOnly,
                           reuseQuery, noQuery, times[0][4] * 1000,
                           times[1][4] * 1000);
                }
            }
    method_setImplementation(cm, (IMP)rh_original_consumer);
    method_setImplementation(pm, (IMP)rh_original_producer);
    method_setImplementation(fm, (IMP)group_original_feedback);
    assert(rh_consumers == 28 * trials * 2 * frames &&
           rh_producers == rh_consumers);
    printf("Raster barriers:%u exact image/query pairs,%u stored/resolve "
           "output records,%u GPU query reads,%u consumer/producer "
           "pairs;MSAA1/2/4,RGBA8/Float4,standalone/grouped,private GPU "
           "producers/overwrite,optional "
           "store+resolve/resolve-only,alpha/depth/stencil/scissor/empty/logic/"
           "dither "
           "PASS\n",
           pairs, samplesChecked, queryChecks, rh_consumers);
}
#endif
