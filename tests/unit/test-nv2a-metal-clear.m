/* Native masked-clear GPU tests, without a window or application.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

static NV2AMetalCommands *commands;
static NV2AMetalClear *clearer;
static unsigned draws;
/* Exercise the production compiler/cache entry without inventing cache keys. */
@interface NV2AMetalClear (CacheTesting)
- (id<MTLRenderPipelineState>)pipeline:(MTLPixelFormat)format
                              samples:(NSUInteger)samples
                                 mask:(MTLColorWriteMask)mask
                                error:(NSError **)error;
@end
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Clear: %s\n", error.localizedDescription.UTF8String);
        abort();
    }
}
static void pipeline_cache_test(void)
{
    NSError *error = nil;
    NV2AMetalClear *local = [[NV2AMetalClear alloc]
        initWithDevice:commands.device error:&error];
    require(local != nil, error);
    id<MTLRenderPipelineState> hot =
        [local pipeline:MTLPixelFormatRGBA8Unorm samples:1
                   mask:MTLColorWriteMaskAll error:&error];
    require(hot != nil, error);
    const MTLPixelFormat formats[] = {
        MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm,
        MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm,
        MTLPixelFormatB5G6R5Unorm, MTLPixelFormatBGR5A1Unorm,
        MTLPixelFormatRGBA32Float
    };
    for (NSUInteger samples = 1; samples <= 4; samples *= 2)
        for (unsigned f = 0; f < 7; f++)
            for (unsigned mask = 1; mask < 16; mask++) {
                require([local pipeline:formats[f] samples:samples mask:mask
                                  error:&error] != nil, error);
                assert([local pipeline:MTLPixelFormatRGBA8Unorm samples:1
                                  mask:MTLColorWriteMaskAll error:&error] == hot);
            }
    NV2AMetalLRUCache *cache = [local valueForKey:@"pipelines"];
    assert([cache isKindOfClass:NV2AMetalLRUCache.class]);
    assert(cache.count == 256 && cache.missCount == 315 &&
           cache.hitCount == 316 && cache.evictionCount == 59);
    puts("Metal clear pipeline cache: 315 compiled variants, 316 hits, "
         "59 selective evictions, 256 retained entries; hot pipeline reused PASS");
}
static id<MTLTexture> texture(MTLPixelFormat format, unsigned samples)
{
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    d.storageMode = samples == 1 && format != MTLPixelFormatDepth16Unorm &&
                            format != MTLPixelFormatDepth32Float &&
                            format != MTLPixelFormatDepth32Float_Stencil8 ?
                        MTLStorageModeShared :
                        MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
              MTLTextureUsagePixelFormatView;
    if (samples != 1) {
        d.sampleCount = samples;
        d.textureType = MTLTextureType2DMultisample;
    }
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:d];
    assert(t);
    return t;
}
static void initialize(id<MTLTexture> color, id<MTLTexture> zeta,
                       MTLClearColor rgba, double depth, unsigned stencil)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    if (color) {
        require([commands addResource:color error:&error], error);
        p.colorAttachments[0].texture = color;
        p.colorAttachments[0].loadAction = MTLLoadActionClear;
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        p.colorAttachments[0].clearColor = rgba;
    }
    if (zeta) {
        require([commands addResource:zeta error:&error], error);
        p.depthAttachment.texture = zeta;
        p.depthAttachment.loadAction = MTLLoadActionClear;
        p.depthAttachment.storeAction = MTLStoreActionStore;
        p.depthAttachment.clearDepth = depth;
        if (zeta.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            p.stencilAttachment.texture = zeta;
            p.stencilAttachment.loadAction = MTLLoadActionClear;
            p.stencilAttachment.storeAction = MTLStoreActionStore;
            p.stencilAttachment.clearStencil = stencil;
        }
    }
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    assert(e);
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
static void finish(void)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static id<MTLTexture> resolve(id<MTLTexture> color)
{
    if (color.sampleCount == 1) {
        return color;
    }
    NSError *error = nil;
    id<MTLTexture> result = texture(color.pixelFormat, 1);
    require([commands addResource:result error:&error], error);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = color;
    p.colorAttachments[0].resolveTexture = result;
    p.colorAttachments[0].loadAction = MTLLoadActionLoad;
    p.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static BOOL covered(MTLScissorRect r, unsigned x, unsigned y)
{
    return x >= r.x && y >= r.y && x - r.x < r.width && y - r.y < r.height;
}
static const MTLScissorRect rects[] = {
    { 0, 0, 8, 8 },
    { 2, 3, 4, 2 },
    { 6, 7, NSUIntegerMax, NSUIntegerMax },
    { NSUIntegerMax, 3, 1, 1 },
    { 0, 0, 0, 2 },
};
static void color_tests(void)
{
    NSError *error = nil;
    const MTLPixelFormat formats[] = {
        MTLPixelFormatR8Unorm,     MTLPixelFormatRG8Unorm,
        MTLPixelFormatRGBA8Unorm,  MTLPixelFormatBGRA8Unorm,
        MTLPixelFormatB5G6R5Unorm, MTLPixelFormatBGR5A1Unorm,
        MTLPixelFormatRGBA32Float
    };
    const unsigned bytes[] = { 1, 2, 4, 4, 2, 2, 16 };
    const unsigned shifts[][4] = {
        { 0 },        { 0, 8 },        { 0, 8, 16, 24 }, { 16, 8, 0, 24 },
        { 11, 5, 0 }, { 10, 5, 0, 15 }
    };
    const unsigned bits[][4] = { { 8 },          { 8, 8 },    { 8, 8, 8, 8 },
                                 { 8, 8, 8, 8 }, { 5, 6, 5 }, { 5, 5, 5, 1 } };
    for (unsigned samples = 1; samples <= 4; samples *= 4) {
        for (unsigned f = 0; f < 7; f++) {
            @autoreleasepool {
                id<MTLTexture> color = texture(formats[f], samples);
                for (unsigned mask = 0; mask < 16; mask++) {
                    for (unsigned rectangle = 0; rectangle < 5; rectangle++) {
                        initialize(color, nil, MTLClearColorMake(0, 1, 0, 1), 0,
                                   0);
                        NV2AMetalClearConfig c = {
                            .parameter = mask << 4,
                            .rect = rects[rectangle],
                            .uniforms = { .color = { 1, 0, 1, 0 }, .depth = 0 }
                        };
                        require([clearer encodeColor:color
                                                zeta:nil
                                              config:&c
                                            commands:commands
                                               error:&error],
                                error);
                        id<MTLTexture> output = resolve(color);
                        finish();
                        _Alignas(float) unsigned char buffer[8 * 8 * 16];
                        [output getBytes:buffer
                             bytesPerRow:8 * bytes[f]
                              fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                             mipmapLevel:0];
                        for (unsigned y = 0; y < 8; y++) {
                            for (unsigned x = 0; x < 8; x++) {
                                BOOL hit = covered(c.rect, x, y);
                                if (f == 6) {
                                    const float *rgba =
                                        (const float *)(buffer +
                                                        (y * 8 + x) * 16);
                                    for (unsigned k = 0; k < 4; k++) {
                                        float expected =
                                            hit && (mask & (1u << k)) ?
                                                !(k & 1) :
                                                k & 1;
                                        assert(rgba[k] == expected);
                                    }
                                } else {
                                    unsigned word = 0;
                                    memcpy(&word,
                                           buffer + (y * 8 + x) * bytes[f],
                                           bytes[f]);
                                    unsigned expected = 0;
                                    for (unsigned k = 0; k < 4; k++) {
                                        unsigned value =
                                            hit && (mask & (1u << k)) ?
                                                !(k & 1) :
                                                k & 1;
                                        expected |=
                                            value * ((1u << bits[f][k]) - 1)
                                            << shifts[f][k];
                                    }
                                    assert(word == expected);
                                }
                            }
                        }
                        draws++;
                    }
                }
            }
        }
    }
}
static id<MTLBuffer> read_zeta(id<MTLTexture> zeta, BOOL stencil)
{
    NSError *error = nil;
    id<MTLBuffer> data =
        [commands.device newBufferWithLength:8 * 256
                                     options:MTLResourceStorageModeShared];
    require([commands addResource:data error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:zeta
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:data
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:zeta.pixelFormat ==
                                         MTLPixelFormatDepth32Float_Stencil8 ?
                                     stencil ?
                                     MTLBlitOptionStencilFromDepthStencil :
                                     MTLBlitOptionDepthFromDepthStencil :
                                     MTLBlitOptionNone];
    [e endEncoding];
    return data;
}
static void depth_tests(void)
{
    NSError *error = nil;
    const MTLPixelFormat formats[] = { MTLPixelFormatDepth16Unorm,
                                       MTLPixelFormatDepth32Float,
                                       MTLPixelFormatDepth32Float_Stencil8 };
    const float values[] = { -1, 0, 2.0f / 65535, .5f, 1, 2 };
    for (unsigned f = 0; f < 3; f++) {
        id<MTLTexture> depth = texture(formats[f], 1);
        id<MTLTexture> color = texture(MTLPixelFormatRGBA32Float, 1);
        for (unsigned attached = 0; attached < 2; attached++) {
            for (unsigned flags = 0; flags < 4; flags++) {
                for (unsigned v = 0; v < 6; v++) {
                    for (unsigned rectangle = 0; rectangle < 5; rectangle++) {
                        initialize(attached ? color : nil, depth,
                                   MTLClearColorMake(.1, .2, .3, .4), .75,
                                   0x37);
                        NV2AMetalClearConfig c = {
                            .parameter = flags,
                            .rect = rects[rectangle],
                            .stencil = 0x15a,
                            .uniforms = { .color = { 0 }, .depth = values[v] }
                        };
                        require([clearer encodeColor:attached ? color : nil
                                                zeta:depth
                                              config:&c
                                            commands:commands
                                               error:&error],
                                error);
                        id<MTLBuffer> z = read_zeta(depth, NO);
                        id<MTLBuffer> s = f == 2 ? read_zeta(depth, YES) : nil;
                        finish();
                        const unsigned char *raw = z.contents;
                        const unsigned char *st = s.contents;
                        for (unsigned y = 0; y < 8; y++) {
                            for (unsigned x = 0; x < 8; x++) {
                                BOOL hit = covered(c.rect, x, y);
                                float expected =
                                    hit && (flags & 1) ?
                                        fminf(1, fmaxf(0, values[v])) :
                                        .75f;
                                if (f == 0) {
                                    uint16_t word;
                                    memcpy(&word, raw + y * 256 + x * 2, 2);
                                    assert(word ==
                                           (unsigned)roundf(expected * 65535));
                                } else {
                                    float value;
                                    memcpy(&value, raw + y * 256 + x * 4, 4);
                                    assert(value == expected);
                                }
                                if (s) {
                                    assert(st[y * 256 + x] ==
                                           (hit && (flags & 2) ? 0x5a : 0x37));
                                }
                            }
                        }
                        if (attached) {
                            float rgba[8][8][4];
                            [color getBytes:rgba
                                bytesPerRow:sizeof(rgba[0])
                                 fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                                mipmapLevel:0];
                            for (unsigned y = 0; y < 8; y++)
                                for (unsigned x = 0; x < 8; x++)
                                    for (unsigned k = 0; k < 4; k++)
                                        assert(fabsf(rgba[y][x][k] -
                                                     .1f * (k + 1)) < .000001f);
                        }
                        draws++;
                    }
                }
            }
        }
    }
}
/* Read every MSAA sample directly. A color resolve would hide a missing
 * depth/stencil write in one sample, and a blit cannot read multisample depth.
 */
static void multisample_depth_tests(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.source = @"#include <metal_stdlib>\n"
                 "using namespace metal;\n"
                 "struct Sample { float z; uint s; };\n"
                 "kernel void read_depth(depth2d_ms<float> z [[texture(0)]],\n"
                 " device Sample *out [[buffer(0)]],\n"
                 " uint3 p [[thread_position_in_grid]]) {\n"
                 " out[(p.y * 8 + p.x) * 4 + p.z].z = z.read(p.xy, p.z);\n"
                 "}\n"
                 "kernel void read_zeta(depth2d_ms<float> z [[texture(0)]],\n"
                 " texture2d_ms<uint, access::read> s [[texture(1)]],\n"
                 " device Sample *out [[buffer(0)]],\n"
                 " uint3 p [[thread_position_in_grid]]) {\n"
                 " uint i = (p.y * 8 + p.x) * 4 + p.z;\n"
                 " out[i].z = z.read(p.xy, p.z);\n"
                 " out[i].s = s.read(p.xy, p.z).x;\n"
                 "}\n";
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    id<MTLComputePipelineState> pipelines[2];
    for (unsigned stencil = 0; stencil < 2; stencil++) {
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = stencil ? @"read_zeta" : @"read_depth";
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        pipelines[stencil] =
            [compiler newComputePipelineStateWithDescriptor:pd
                                        compilerTaskOptions:nil
                                                      error:&error];
        require(pipelines[stencil] != nil, error);
    }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.maxTextureBindCount = 2;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> table =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(table != nil, error);
    const MTLPixelFormat formats[] = { MTLPixelFormatDepth16Unorm,
                                       MTLPixelFormatDepth32Float,
                                       MTLPixelFormatDepth32Float_Stencil8 };
    typedef struct {
        float z;
        uint32_t s;
    } Sample;
    _Static_assert(sizeof(Sample) == 8, "CPU/MSL MSAA readback sample");
    for (unsigned f = 0; f < 3; f++) {
        id<MTLTexture> depth = texture(formats[f], 4);
        id<MTLTexture> stencil =
            f == 2 ?
                [depth
                    newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8] :
                nil;
        assert(f != 2 || stencil);
        id<MTLBuffer> out =
            [commands.device newBufferWithLength:8 * 8 * 4 * sizeof(Sample)
                                         options:MTLResourceStorageModeShared];
        assert(out);
        for (unsigned flags = 0; flags < 4; flags++) {
            for (unsigned r = 0; r < 5; r++) {
                initialize(nil, depth, MTLClearColorMake(0, 0, 0, 0), .75,
                           0x37);
                NV2AMetalClearConfig c = { .parameter = flags,
                                           .rect = rects[r],
                                           .stencil = 0x5a,
                                           .uniforms = { .color = { 0 },
                                                         .depth = .25f } };
                require([clearer encodeColor:nil
                                        zeta:depth
                                      config:&c
                                    commands:commands
                                       error:&error],
                        error);
                require([commands addResource:out error:&error], error);
                if (stencil) {
                    require([commands addResource:stencil error:&error], error);
                }
                [table setAddress:out.gpuAddress atIndex:0];
                [table setTexture:depth.gpuResourceID atIndex:0];
                if (stencil) {
                    [table setTexture:stencil.gpuResourceID atIndex:1];
                }
                id<MTL4ComputeCommandEncoder> e =
                    [commands.commandBuffer computeCommandEncoder];
                assert(e);
                [e barrierAfterQueueStages:MTLStageAll
                              beforeStages:MTLStageDispatch
                         visibilityOptions:MTL4VisibilityOptionDevice];
                [e setComputePipelineState:pipelines[f == 2]];
                [e setArgumentTable:table];
                [e dispatchThreads:MTLSizeMake(8, 8, 4)
                    threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [e endEncoding];
                finish();
                const Sample *samples = out.contents;
                for (unsigned y = 0; y < 8; y++) {
                    for (unsigned x = 0; x < 8; x++) {
                        BOOL hit = covered(c.rect, x, y);
                        float expected = hit && (flags & 1) ? .25f : .75f;
                        if (f == 0) {
                            expected = roundf(expected * 65535) / 65535;
                        }
                        for (unsigned s = 0; s < 4; s++) {
                            Sample actual = samples[(y * 8 + x) * 4 + s];
                            assert(fabsf(actual.z - expected) < .000001f);
                            if (stencil) {
                                assert(actual.s ==
                                       (hit && (flags & 2) ? 0x5a : 0x37));
                            }
                        }
                    }
                }
                draws++;
            }
        }
    }
}
static void snapshot_test(void)
{
    NSError *error = nil;
    id<MTLTexture> color = texture(MTLPixelFormatRGBA32Float, 1);
    initialize(color, nil, MTLClearColorMake(0, 0, 0, 0), 0, 0);
    __weak NV2AMetalClear *weak;
    @autoreleasepool {
        NV2AMetalClear *local =
            [[NV2AMetalClear alloc] initWithDevice:commands.device
                                             error:&error];
        require(local != nil, error);
        weak = local;
        NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                   .rect = { 0, 0, 4, 8 },
                                   .uniforms = { .color = { 1, 0, 0, 1 },
                                                 .depth = 0 } };
        require([local encodeColor:color
                              zeta:nil
                            config:&c
                          commands:commands
                             error:&error],
                error);
        c.rect.x = 4;
        c.uniforms.color[0] = 0;
        c.uniforms.color[2] = 1;
        require([local encodeColor:color
                              zeta:nil
                            config:&c
                          commands:commands
                             error:&error],
                error);
        memset(&c, 0, sizeof(c));
    }
    assert(weak);
    finish();
    assert(!weak);
    float rgba[8][8][4];
    [color getBytes:rgba
        bytesPerRow:sizeof(rgba[0])
         fromRegion:MTLRegionMake2D(0, 0, 8, 8)
        mipmapLevel:0];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            assert(rgba[y][x][0] == (x < 4));
            assert(rgba[y][x][2] == (x >= 4));
            assert(rgba[y][x][3] == 1);
        }
    draws += 2;
}
static void reject_tests(void)
{
    NSError *error = nil;
    id<MTLTexture> color = texture(MTLPixelFormatRGBA8Unorm, 1);
    id<MTLTexture> depth = texture(MTLPixelFormatDepth16Unorm, 1);
    NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                               .rect = { 0, 0, 8, 8 },
                               .uniforms = { .color = { 1, 0, 1, 1 },
                                             .depth = 0 } };
    assert(![clearer encodeColor:color
                            zeta:nil
                          config:&c
                        commands:commands
                           error:&error]);
    require([commands beginWithError:&error] != nil, error);
    assert(![clearer encodeColor:color
                            zeta:nil
                          config:NULL
                        commands:commands
                           error:&error]);
    assert(![clearer encodeColor:nil
                            zeta:nil
                          config:&c
                        commands:commands
                           error:&error]);
    c.uniforms.color[0] = NAN;
    assert(![clearer encodeColor:color
                            zeta:nil
                          config:&c
                        commands:commands
                           error:&error]);
    c.parameter = NV097_CLEAR_SURFACE_Z;
    c.uniforms.depth = INFINITY;
    assert(![clearer encodeColor:nil
                            zeta:depth
                          config:&c
                        commands:commands
                           error:&error]);
    c.uniforms.depth = 0;
    assert(![clearer encodeColor:nil
                            zeta:nil
                          config:&c
                        commands:commands
                           error:&error]);
    c.parameter = 0x8000000c;
    require([clearer encodeColor:nil
                            zeta:nil
                          config:&c
                        commands:commands
                           error:&error],
            error);
    [commands cancel];
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        pipeline_cache_test();
        clearer = [[NV2AMetalClear alloc] initWithDevice:commands.device
                                                   error:&error];
        require(clearer != nil, error);
        color_tests();
        depth_tests();
        multisample_depth_tests();
        snapshot_test();
        reject_tests();
        printf("Metal 4 native clear: %u masked/scissored/MSAA/depth/stencil "
               "cases PASS\n",
               draws);
    }
    return 0;
}
