/* Offscreen Metal 4 visibility counting. No application or VM is started.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#import <objc/runtime.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Visibility: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static id<MTLTexture> attachment(id<MTLDevice> device, MTLPixelFormat format,
                                 unsigned samples)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType =
        samples == 1 ? MTLTextureType2D : MTLTextureType2DMultisample;
    d.pixelFormat = format;
    d.width = d.height = 8;
    d.sampleCount = samples;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:d];
    assert(texture);
    return texture;
}
static NV2AMetalPixelUniforms uniforms(void)
{
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = 1;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 8;
    u.depth_format = NV2AMetalPixelDepthD24;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
    }
    return u;
}
static void pipeline_cache_test(NV2AMetalCommands *commands,
                                id<MTLBuffer> vertices)
{
    NSError *error = nil;
    id<MTLTexture> color = attachment(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
        initWithDevice:commands.device colorFormat:color.pixelFormat
           depthFormat:MTLPixelFormatInvalid sampleCount:1 error:&error];
    require(shader != nil, error);
    NV2AMetalDrawConfig config = { 0 };
    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
        initWithDevice:commands.device config:&config error:&error];
    require(state != nil, error);
    uint64_t zero = 0;
    id<MTLBuffer> result = [commands.device newBufferWithBytes:&zero
        length:sizeof(zero) options:MTLResourceStorageModeShared];
    assert(result);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.visibilityResultBuffer = result;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    const unsigned registers[] = { PS_REGISTER_V0, PS_REGISTER_V1,
        PS_REGISTER_T0, PS_REGISTER_T1, PS_REGISTER_T2, PS_REGISTER_T3,
        PS_REGISTER_R0, PS_REGISTER_R1 };
    require([commands beginWithError:&error] != nil, error);
    /* 316 distinct combiner pipelines exceed both caches; the initial hot
     * pipeline is used between each cold variant. All draws remain in flight
     * while cache eviction occurs, then their GPU query results are checked. */
    for (unsigned i = 0; i < 631; i++) {
        NV2AMetalPixelUniforms u = uniforms();
        if (i & 1) {
            unsigned variant = i / 2;
            u.combiner.final_inputs[0] = registers[variant % 8] << 24 |
                registers[(variant / 8) % 8] << 16 |
                registers[variant / 64] << 8 | PS_REGISTER_V0;
        }
        require([shader encodeVertices:vertices count:6
                              primitive:MTLPrimitiveTypeTriangle
                               uniforms:&u textures:bindings pass:pass
                              drawState:state commands:commands error:&error],
                error);
    }
    NV2AMetalLRUCache *pipelines = [shader valueForKey:@"fragmentPipelines"];
    assert([pipelines isKindOfClass:NV2AMetalLRUCache.class]);
    assert(pipelines.count == 256 && pipelines.missCount == 316 &&
           pipelines.hitCount == 315 && pipelines.evictionCount == 60);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    assert(*(uint64_t *)result.contents == 631 * 64);
    puts("Metal fragment cache: 316 complete pipelines, 315 draw-cache "
         "hits, 60 evictions, 256 cached entries; 631 queued "
         "draws/40384 GPU samples after in-flight eviction PASS");
}
static void (*group_original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static double group_gpu_seconds;
static void group_feedback(id object, SEL selector,
                           MTL4CommitFeedbackHandler handler)
{
    group_original_feedback(
        object, selector, ^(id<MTL4CommitFeedback> feedback) {
          group_gpu_seconds = feedback.GPUEndTime - feedback.GPUStartTime;
          handler(feedback);
        });
}
static int group_compare_time(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
/* Compare one shared encoder against ordered standalone Load/Store passes.
 * Switching logic operations, scissor and immutable uniforms exercises state
 * rebinding and framebuffer-fetch ordering within the shared render pass. */
static void render_group_test(NV2AMetalCommands *commands,
                              id<MTLBuffer> vertices)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    id<MTLBuffer> images[2], queries[2];
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    assert(feedback);
    group_original_feedback =
        (void *)method_setImplementation(feedback, (IMP)group_feedback);
    double times[2][9];
    for (unsigned trial = 0; trial < 11; trial++) {
        for (unsigned variant = 0; variant < 2; variant++) {
            unsigned grouped = variant ^ (trial & 1);
            id<MTLTexture> color =
                attachment(commands.device, MTLPixelFormatRGBA8Unorm, 1);
            uint64_t zero = 0;
            queries[grouped] = [commands.device
                newBufferWithBytes:&zero
                            length:sizeof(zero)
                           options:MTLResourceStorageModeShared];
            images[grouped] = [commands.device
                newBufferWithLength:256 * 8
                            options:MTLResourceStorageModeShared];
            assert(queries[grouped] && images[grouped]);
            require([commands beginWithError:&error] != nil, error);
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = color;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.visibilityResultBuffer = queries[grouped];
            pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
            id<MTL4RenderCommandEncoder> encoder = nil;
            if (grouped) {
                encoder = [commands.commandBuffer
                    renderCommandEncoderWithDescriptor:pass];
                assert(encoder);
                [encoder barrierAfterQueueStages:MTLStageAll
                                    beforeStages:MTLStageAll
                               visibilityOptions:MTL4VisibilityOptionDevice];
                [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting
                                          offset:0];
            }
            NV2AMetalDrawState *lastState = nil;
            for (unsigned i = 0; i < 32; i++) {
                NV2AMetalDrawConfig config = { 0 };
                config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
                if (i % 3)
                    config.blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12;
                config.scissor_enabled = YES;
                config.scissor = (MTLScissorRect){ i % 4, i % 4, 4, 4 };
                NV2AMetalDrawState *state =
                    [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                        config:&config
                                                         error:&error];
                require(state != nil, error);
                NV2AMetalPixelUniforms u = uniforms();
                u.combiner.final_inputs[0] = PS_REGISTER_C0;
                u.combiner.final_inputs[1] = (PS_REGISTER_C0 | PS_CHANNEL_ALPHA)
                                             << 8;
                u.combiner.constants[16][0] = (i * 7 % 255) / 255.f;
                u.combiner.constants[16][1] = (i * 13 % 255) / 255.f;
                u.combiner.constants[16][2] = (i * 19 % 255) / 255.f;
                u.combiner.constants[16][3] = 1;
                lastState = state;
                NV2AMetalPixelTexture bindings[4] = { 0 };
                require([shader encodeVertices:vertices
                                          offset:0
                                           count:6
                                       primitive:MTLPrimitiveTypeTriangle
                                        uniforms:&u
                                        textures:bindings
                                            pass:pass
                                       drawState:state
                                     rasterClass:NV2AMetalPixelRasterNative
                            ignorePolygonCulling:NO
                                   renderEncoder:encoder
                                        commands:commands
                                           error:&error],
                        error);
                if (!grouped)
                    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            }
            if (encoder) {
                /* A rejected draw must neither end the borrowed encoder nor
                 * commit it. The owner closes it before the following readback.
                 */
                NV2AMetalPixelUniforms u = uniforms();
                NV2AMetalPixelTexture bindings[4] = { 0 };
                assert(![shader encodeVertices:vertices
                                        offset:1
                                         count:6
                                     primitive:MTLPrimitiveTypeTriangle
                                      uniforms:&u
                                      textures:bindings
                                          pass:pass
                                     drawState:lastState
                                   rasterClass:NV2AMetalPixelRasterNative
                          ignorePolygonCulling:NO
                                 renderEncoder:encoder
                                      commands:commands
                                         error:&error]);
                [encoder barrierAfterStages:MTLStageAll
                          beforeQueueStages:MTLStageAll
                          visibilityOptions:MTL4VisibilityOptionDevice];
                [encoder endEncoding];
            }
            require([commands addResource:images[grouped] error:&error], error);
            id<MTL4ComputeCommandEncoder> copy =
                [commands.commandBuffer computeCommandEncoder];
            assert(copy);
            [copy barrierAfterQueueStages:MTLStageAll
                             beforeStages:MTLStageBlit
                        visibilityOptions:MTL4VisibilityOptionDevice];
            [copy copyFromTexture:color
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(8, 8, 1)
                                toBuffer:images[grouped]
                       destinationOffset:0
                  destinationBytesPerRow:256
                destinationBytesPerImage:0
                                 options:MTLBlitOptionNone];
            [copy endEncoding];
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            assert(*(uint64_t *)queries[grouped].contents == 32 * 16);
            assert(group_gpu_seconds > 0);
            if (trial >= 2)
                times[grouped][trial - 2] = group_gpu_seconds;
        }
        unsigned nonzero = 0;
        for (unsigned row = 0; row < 8; row++) {
            const uint8_t *a = (const uint8_t *)images[0].contents + row * 256;
            const uint8_t *b = (const uint8_t *)images[1].contents + row * 256;
            assert(!memcmp(a, b, 8 * 4));
            for (unsigned x = 0; x < 8; x++)
                nonzero += a[x * 4] || a[x * 4 + 1] || a[x * 4 + 2];
        }
        assert(nonzero);
    }
    method_setImplementation(feedback, (IMP)group_original_feedback);
    qsort(times[0], 9, sizeof(double), group_compare_time);
    qsort(times[1], 9, sizeof(double), group_compare_time);
    printf("Metal grouped raster GPU median shared/separate=%.6f/%.6f ms "
           "(32 draws,2 warmups,9 paired alternating samples,11 exact "
           "image/query pairs)\n",
           times[1][4] * 1000, times[0][4] * 1000);
    puts("Metal grouped render pass: 32 standalone passes versus one pass; "
         "256 identical output bytes, 512 samples each, changing uniforms/"
         "scissor/logic, rejected draw and following compute readback PASS");
}
/* Characterize native sampler precision against the current float-read
 * implementation before selecting a production fast path. This deliberately
 * reports differences rather than weakening the renderer's pixel oracle. */
static void native_sampling_probe(NV2AMetalCommands *commands,
                                  id<MTLBuffer> vertices)
{
    NSError *error = nil;
    id<MTLDevice> device = commands.device;
    uint8_t bytes[16 * 16 * 4];
    float values[16 * 16 * 4];
    for (unsigned i = 0; i < sizeof(bytes); i++) {
        unsigned texel = i / 4;
        bytes[i] = (uint8_t)(i % 4 == 0 ? texel : i % 4 == 1 ? 255 - texel :
                            i % 4 == 2 ? texel * 71 : texel * 29 + 7);
        values[i] = bytes[i] / 255.f;
    }
    id<MTLTexture> sources[2];
    for (unsigned format = 0; format < 2; format++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:format ? MTLPixelFormatRGBA8Unorm :
                                                       MTLPixelFormatRGBA32Float
                                       width:16 height:16 mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        sources[format] = [device newTextureWithDescriptor:td];
        assert(sources[format]);
        [sources[format] replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
                           mipmapLevel:0 withBytes:format ? (void *)bytes :
                                                               (void *)values
                           bytesPerRow:16 * (format ? 4 : 16)];
    }
    NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
        initWithDevice:device colorFormat:MTLPixelFormatRGBA32Float
           depthFormat:MTLPixelFormatInvalid sampleCount:1 error:&error];
    require(shader != nil, error);
    float maximum[2][3] = { 0 };
    unsigned differences[2][3] = { 0 }, comparisons[2][3] = { 0 };
    const float origins[] = { 0, -.25f, 1.f / 32, .5f - 1e-7f,
                              .5f + 1e-7f, -1.25f };
    const float spans[] = { 0, .125f, 1, 1.75f };
    for (unsigned linear = 0; linear < 2; linear++)
        for (unsigned address = 1; address <= 3; address++)
            for (unsigned origin = 0; origin < 6; origin++)
                for (unsigned span = 0; span < 4; span++) {
                    @autoreleasepool {
                        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
                        sd.minFilter = sd.magFilter = linear ?
                            MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
                        sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
                        sd.sAddressMode = sd.tAddressMode = address == 1 ?
                            MTLSamplerAddressModeRepeat : address == 2 ?
                            MTLSamplerAddressModeMirrorRepeat : MTLSamplerAddressModeClampToEdge;
                        sd.supportArgumentBuffers = YES;
                        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];
                        assert(sampler);
                        NV2AMetalVertex v[6];
                        memcpy(v, vertices.contents, sizeof(v));
                        for (unsigned i = 0; i < 6; i++) {
                            v[i].texcoord[0][0] = origins[origin] +
                                (v[i].clip[0] + 1) * .5f * spans[span];
                            v[i].texcoord[0][1] = origins[origin] +
                                (v[i].clip[1] + 1) * .5f * spans[span];
                            v[i].texcoord[0][3] = 1;
                        }
                        id<MTLBuffer> input = [device newBufferWithBytes:v
                            length:sizeof(v) options:MTLResourceStorageModeShared];
                        id<MTLBuffer> outputs[4] = { nil, nil, nil, nil };
                        require([commands beginWithError:&error] != nil, error);
                        for (unsigned mode = 0; mode < 4; mode++) {
                            if (mode == 1 && linear && !device.supports32BitFloatFiltering)
                                continue;
                            MTLTextureDescriptor *td = [MTLTextureDescriptor
                                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                           width:16 height:16 mipmapped:NO];
                            td.storageMode = MTLStorageModePrivate;
                            td.usage = MTLTextureUsageRenderTarget;
                            id<MTLTexture> target = [device newTextureWithDescriptor:td];
                            assert(target);
                            NV2AMetalPixelUniforms u = uniforms();
                            u.clip_regions[0][2] = u.clip_regions[0][3] = 16;
                            u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
                            u.combiner.final_inputs[0] = PS_REGISTER_T0;
                            u.combiner.final_inputs[1] =
                                (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
                            u.textures[0].sampling = (NV2AMetalSamplingUniforms){
                                .enabled = !mode || mode == 3, .address = { address, address, 3 },
                                .min_linear = linear, .mag_linear = linear,
                                .anisotropy = 1 };
                            NV2AMetalPixelTexture bindings[4] = { 0 };
                            bindings[0].texture = sources[mode >= 2];
                            bindings[0].sampler = sampler;
                            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
                            pass.colorAttachments[0].texture = target;
                            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                            require([shader encodeVertices:input count:6
                                primitive:MTLPrimitiveTypeTriangle uniforms:&u
                                 textures:bindings pass:pass depthStencil:nil
                                 commands:commands error:&error], error);
                            outputs[mode] = [device newBufferWithLength:256 * 16
                                options:MTLResourceStorageModeShared];
                            require([commands addResource:outputs[mode] error:&error], error);
                            id<MTL4ComputeCommandEncoder> copy =
                                [commands.commandBuffer computeCommandEncoder];
                            assert(copy);
                            [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit
                                      visibilityOptions:MTL4VisibilityOptionDevice];
                            [copy copyFromTexture:target sourceSlice:0 sourceLevel:0
                                     sourceOrigin:MTLOriginMake(0, 0, 0)
                                       sourceSize:MTLSizeMake(16, 16, 1) toBuffer:outputs[mode]
                                destinationOffset:0 destinationBytesPerRow:256
                              destinationBytesPerImage:0 options:MTLBlitOptionNone];
                            [copy endEncoding];
                        }
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error], error);
                        for (unsigned mode = 1; mode < 4; mode++) {
                            if (!outputs[mode])
                                continue;
                            float caseMaximum = 0;
                            for (unsigned y = 0; y < 16; y++) {
                                const float *a = (const float *)(
                                    (const uint8_t *)outputs[0].contents + y * 256);
                                const float *b = (const float *)(
                                    (const uint8_t *)outputs[mode].contents + y * 256);
                                for (unsigned x = 0; x < 64; x++) {
                                    assert(isfinite(a[x]) && isfinite(b[x]));
                                    assert(a[x] >= 0 && a[x] <= 1 &&
                                           b[x] >= 0 && b[x] <= 1);
                                    if (!linear && origin == 0 && span == 0)
                                        assert(a[x] == values[x % 4]);
                                    float delta = fabsf(a[x] - b[x]);
                                    if (mode == 3)
                                        assert(delta == 0);
                                    caseMaximum = fmaxf(caseMaximum, delta);
                                    maximum[linear][mode - 1] =
                                        fmaxf(maximum[linear][mode - 1], delta);
                                    differences[linear][mode - 1] += delta != 0;
                                    comparisons[linear][mode - 1]++;
                                }
                            }
                            if (mode == 1 && caseMaximum > 1e-4f)
                                printf("Native boundary difference: linear=%u address=%u "
                                       "origin=%.9g span=%.9g error=%.9g\n",
                                       linear, address, origins[origin], spans[span], caseMaximum);
                        }
                    }
                }
    printf("Texture payload: RGBA32F=4096 RGBA8=1024 bytes; device allocations "
           "%lu/%lu bytes\n", (unsigned long)sources[0].allocatedSize,
           (unsigned long)sources[1].allocatedSize);
    printf("Native sampling capability: 32-bit float filtering %s\n",
           device.supports32BitFloatFiltering ? "YES" : "NO");
    for (unsigned linear = 0; linear < 2; linear++)
        for (unsigned format = 0; format < 3; format++)
            printf("Sampling %s %s versus manual RGBA32F: %u channels, %u "
                   "nonidentical, max absolute error %.9g\n",
                   linear ? "linear" : "nearest",
                   format == 0 ? "RGBA32F" : format == 1 ? "RGBA8" : "manual-RGBA8",
                   comparisons[linear][format], differences[linear][format],
                   maximum[linear][format]);
}
#include "test-metal-raster-hazards.h"
#include "test-metal-pixel-packets.h"
#include "test-metal-combiner-keys.h"
#include "test-metal-sampler-base-only.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        const float xy[6][2] = { { -1, -1 }, { 1, -1 }, { -1, 1 },
                                 { 1, -1 },  { 1, 1 },  { -1, 1 } };
        NV2AMetalVertex v[6] = { 0 };
        for (unsigned i = 0; i < 6; i++) {
            v[i].clip[0] = xy[i][0];
            v[i].clip[1] = xy[i][1];
            v[i].clip[2] = .5;
            v[i].clip[3] = 1;
            v[i].color[0][1] = v[i].color[0][3] = 1;
            const float plane[3][4] = { { 0, 0, 32768, 1 },
                                        { 8, 0, 32768, 1 },
                                        { 0, 8, 32768, 1 } };
            memcpy(v[i].plane, plane, sizeof(plane));
        }
        id<MTLBuffer> vertices =
            [commands.device newBufferWithBytes:v
                                         length:sizeof(v)
                                        options:MTLResourceStorageModeShared];
        assert(vertices);
        if (argc == 2 && !strcmp(argv[1], "--base-only-sampling")) {
            sampler_base_only_tests(commands);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--combiner-keys")) {
            combiner_key_tests(commands, vertices);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--pixel-packets")) {
            pixel_packet_tests(commands, vertices);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--native-sampling")) {
            native_sampling_probe(commands, vertices);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--raster-hazards")) {
            raster_hazards_test(commands, NO, NO);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--raster-query-reuse")) {
            raster_hazards_test(commands, YES, NO);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--raster-no-query")) {
            raster_hazards_test(commands, NO, YES);
            return 0;
        }
        assert(argc == 1);
        sampler_base_only_tests(commands);
        combiner_key_tests(commands, vertices);
        pixel_packet_tests(commands, vertices);
        render_group_test(commands, vertices);
        pipeline_cache_test(commands, vertices);
        unsigned images = 0, rejects = 0;
        for (unsigned samples = 1; samples <= 4; samples *= 2) {
            for (unsigned format = 0; format < 2; format++) {
                id<MTLTexture> color =
                    attachment(commands.device,
                               format ? MTLPixelFormatRGBA32Float :
                                        MTLPixelFormatBGRA8Unorm,
                               samples);
                id<MTLTexture> depth =
                    attachment(commands.device,
                               MTLPixelFormatDepth32Float_Stencil8, samples);
                NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
                    initWithDevice:commands.device
                       colorFormat:color.pixelFormat
                       depthFormat:depth.pixelFormat
                       sampleCount:samples
                             error:&error];
                require(shader != nil, error);
                for (unsigned test = 0; test < 9; test++) {
                    NV2AMetalDrawConfig config = { 0 };
                    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
                    NV2AMetalPixelUniforms u = uniforms();
                    unsigned expected = 64 * samples;
                    if (test == 1) {
                        config.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE;
                        expected = 0;
                    } else if (test == 2) {
                        u.alpha_test = 1;
                        u.alpha_func = 1;
                        expected = 0;
                    } else if (test == 3) {
                        config.control[1] =
                            NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 0xff
                                                                          << 16;
                        config.control[2] = 1 | 1 << 4 | 1 << 8;
                        expected = 0;
                    } else if (test == 4 || test == 8) {
                        config.scissor_enabled = YES;
                        config.scissor =
                            (MTLScissorRect){ 2, 2, test == 4 ? 4 : 0, 4 };
                        expected = test == 4 ? 16 * samples : 0;
                    } else if (test == 5) {
                        u.clip_regions[0][0] = u.clip_regions[0][1] = 2;
                        u.clip_regions[0][2] = u.clip_regions[0][3] = 6;
                        expected = 16 * samples;
                    } else if (test == 6) {
                        config.control[0] = NV_PGRAPH_CONTROL_0_ZENABLE |
                                            NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                            7 << 16;
                    } else if (test == 7) {
                        // Ordered framebuffer fetch, even for LogicOp NOOP.
                        config.blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE | 5 << 12;
                    }
                    NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                        initWithDevice:commands.device
                                config:&config
                                 error:&error];
                    require(state != nil, error);
                    for (unsigned accumulate = 0; accumulate < 2;
                         accumulate++) {
                        if (test == 0) {
                            u.clip_regions[0][2] = 8;
                            u.clip_regions[0][3] = 8;
                        }
                        uint64_t initial = 7;
                        id<MTLBuffer> result = [commands.device
                            newBufferWithBytes:&initial
                                        length:sizeof(initial)
                                       options:MTLResourceStorageModeShared];
                        assert(result);
                        require([commands beginWithError:&error] != nil, error);
                        unsigned secondExpected = expected;
                        for (unsigned repeat = 0; repeat < 2; repeat++) {
                            if (test == 0 && repeat == 1) {
                                /* Distinct constants in one recording must
                                 * retain their own upload-arena slices. */
                                u.clip_regions[0][2] = 4;
                                u.clip_regions[0][3] = 4;
                                secondExpected = 16 * samples;
                            }
                            MTL4RenderPassDescriptor *pass =
                                [MTL4RenderPassDescriptor new];
                            pass.colorAttachments[0].texture = color;
                            pass.colorAttachments[0].loadAction =
                                MTLLoadActionClear;
                            pass.colorAttachments[0].storeAction =
                                MTLStoreActionStore;
                            pass.depthAttachment.texture =
                                pass.stencilAttachment.texture = depth;
                            pass.depthAttachment.loadAction =
                                pass.stencilAttachment.loadAction =
                                    MTLLoadActionClear;
                            pass.depthAttachment.storeAction =
                                pass.stencilAttachment.storeAction =
                                    MTLStoreActionStore;
                            pass.depthAttachment.clearDepth = 1;
                            pass.visibilityResultBuffer = result;
                            pass.visibilityResultType =
                                accumulate ? MTLVisibilityResultTypeAccumulate :
                                             MTLVisibilityResultTypeReset;
                            NV2AMetalPixelTexture bindings[4] = { 0 };
                            require([shader
                                        encodeVertices:vertices
                                                 count:6
                                             primitive:MTLPrimitiveTypeTriangle
                                              uniforms:&u
                                              textures:bindings
                                                  pass:pass
                                             drawState:state
                                              commands:commands
                                                 error:&error],
                                    error);
                        }
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error],
                                error);
                        uint64_t actual;
                        memcpy(&actual, result.contents, sizeof(actual));
                        uint64_t wanted = accumulate ?
                                              7 + expected + secondExpected :
                                              secondExpected;
                        if (actual != wanted) {
                            fprintf(stderr,
                                    "Visibility samples%u format%u test%u "
                                    "accumulate%u: %llu != %llu\n",
                                    samples, format, test, accumulate,
                                    (unsigned long long)actual,
                                    (unsigned long long)wanted);
                            abort();
                        }
                        images++;
                    }
                }
                require([commands beginWithError:&error] != nil, error);
                MTL4RenderPassDescriptor *invalid =
                    [MTL4RenderPassDescriptor new];
                invalid.colorAttachments[0].texture = color;
                invalid.depthAttachment.texture = depth;
                invalid.stencilAttachment.texture = depth;
                invalid.visibilityResultBuffer = [commands.device
                    newBufferWithLength:7
                                options:MTLResourceStorageModeShared];
                NV2AMetalPixelUniforms u = uniforms();
                NV2AMetalPixelTexture bindings[4] = { 0 };
                assert(![shader encodeVertices:vertices
                                         count:6
                                     primitive:MTLPrimitiveTypeTriangle
                                      uniforms:&u
                                      textures:bindings
                                          pass:invalid
                                  depthStencil:nil
                                      commands:commands
                                         error:&error]);
                rejects++;
                invalid.visibilityResultBuffer = [commands.device
                    newBufferWithLength:8
                                options:MTLResourceStorageModeShared];
                invalid.visibilityResultType = (MTLVisibilityResultType)2;
                assert(![shader encodeVertices:vertices
                                         count:6
                                     primitive:MTLPrimitiveTypeTriangle
                                      uniforms:&u
                                      textures:bindings
                                          pass:invalid
                                  depthStencil:nil
                                      commands:commands
                                         error:&error]);
                rejects++;
                [commands cancel];
            }
        }
        printf("Metal 4 visibility: %u GPU counter checks, %u rejects PASS\n",
               images, rejects);
    }
    return 0;
}
