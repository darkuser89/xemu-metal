/*
 * Offscreen native Metal 4 fragment-pipeline tests
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-fetch.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-program.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-sampler.h"
#include "hw/xbox/nv2a/pgraph/metal/pixel-shader-source.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NV2AMetalCommands *commands;
static NV2AMetalPixelShader *shader;
static id<MTLTexture> target, depth;
static id<MTLDepthStencilState> depth_state;
static id<MTLBuffer> depth_readback;
static float pixels[8][8][4];
static unsigned draws;
static BOOL manual_sampling;
static NV2AMetalDrawState *draw_state;
static float draw_clear_depth = .99f;
static unsigned draw_clear_stencil;
static id<MTLBuffer> stencil_readback;
static const float clear_color[] = { .91f, .92f, .93f, .94f };

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Pixel shader failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static void check(float actual, float expected)
{
    if (!isfinite(actual) ||
        fabsf(actual - expected) > .000015f * fmaxf(1, fabsf(expected))) {
        fprintf(stderr, "Pixel draw %u: got %g expected %g\n", draws, actual,
                expected);
        abort();
    }
}

static void color(unsigned x, unsigned y, float r, float g, float b, float a)
{
    const float expected[] = { r, g, b, a };
    for (unsigned k = 0; k < 4; k++) {
        check(pixels[y][x][k], expected[k]);
    }
}

static void clear(unsigned x, unsigned y)
{
    color(x, y, clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
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
    u.depth_format = NV2AMetalPixelDepthD16;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
        u.textures[i].sampling.enabled = manual_sampling;
        u.textures[i].sampling.address[0] = 3;
        u.textures[i].sampling.address[1] = 3;
        u.textures[i].sampling.address[2] = 3;
        u.textures[i].sampling.anisotropy = 1;
    }
    return u;
}

static void texture_mode(NV2AMetalPixelUniforms *u, unsigned stage,
                         unsigned mode)
{
    u->combiner.shader_stage_program &= ~(31u << (5 * stage));
    u->combiner.shader_stage_program |= mode << (5 * stage);
}

static void show_texture(NV2AMetalPixelUniforms *u, unsigned stage)
{
    u->combiner.final_inputs[0] = PS_REGISTER_T0 + stage;
    u->combiner.final_inputs[1] = (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA)
                                  << 8;
}

static void quad(NV2AMetalVertex v[6])
{
    memset(v, 0, 6 * sizeof(*v));
    const float xy[][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 },
                            { 8, 0 }, { 8, 8 }, { 0, 8 } };
    const float plane[][4] = { { 0, 0, 2.75f, 1 },
                               { 8, 0, 2.75f, 1 },
                               { 0, 8, 2.75f, 1 } };
    for (unsigned i = 0; i < 6; i++) {
        v[i].clip[0] = xy[i][0] / 4 - 1;
        v[i].clip[1] = 1 - xy[i][1] / 4;
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].point_size = 2;
        for (unsigned k = 0; k < 4; k++) {
            v[i].color[0][k] = .1f * (k + 1);
            v[i].color[1][k] = .1f * (k + 2);
        }
        for (unsigned t = 0; t < 4; t++) {
            const float coord[] = { .625f, .375f, .2f, 1 };
            memcpy(v[i].texcoord[t], coord, sizeof(coord));
        }
        memcpy(v[i].plane, plane, sizeof(plane));
    }
}

static void coord(NV2AMetalVertex v[6], unsigned stage, float x, float y,
                  float z, float w)
{
    const float c[] = { x, y, z, w };
    for (unsigned i = 0; i < 6; i++) {
        memcpy(v[i].texcoord[stage], c, sizeof(c));
    }
}

static MTL4RenderPassDescriptor *pass(void)
{
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = target;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(
        clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
    p.depthAttachment.texture = depth;
    p.depthAttachment.loadAction = MTLLoadActionClear;
    p.depthAttachment.storeAction = MTLStoreActionStore;
    p.depthAttachment.clearDepth = draw_clear_depth;
    if (stencil_readback) {
        p.stencilAttachment.texture = depth;
        p.stencilAttachment.loadAction = MTLLoadActionClear;
        p.stencilAttachment.storeAction = MTLStoreActionStore;
        p.stencilAttachment.clearStencil = draw_clear_stencil;
    }
    return p;
}

static void read_depth(void)
{
    NSError *error = nil;
    require([commands addResource:depth_readback error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:depth
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:depth_readback
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:stencil_readback ?
                                     MTLBlitOptionDepthFromDepthStencil :
                                     MTLBlitOptionNone];
    if (stencil_readback) {
        require([commands addResource:stencil_readback error:&error], error);
        [e copyFromTexture:depth
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(8, 8, 1)
                            toBuffer:stencil_readback
                   destinationOffset:0
              destinationBytesPerRow:256
            destinationBytesPerImage:0
                             options:MTLBlitOptionStencilFromDepthStencil];
    }
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}

static void render(NV2AMetalPixelUniforms *u, const NV2AMetalVertex *v,
                   NSUInteger count, MTLPrimitiveType primitive,
                   NV2AMetalPixelTexture textures[4])
{
    NSError *error = nil;
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:count * sizeof(*v)
                                    options:MTLResourceStorageModeShared];
    assert(vertices);
    require([commands beginWithError:&error] != nil, error);
    if (draw_state) {
        require([shader encodeVertices:vertices
                                 count:count
                             primitive:primitive
                              uniforms:u
                              textures:textures
                                  pass:pass()
                             drawState:draw_state
                              commands:commands
                                 error:&error],
                error);
    } else {
        require([shader encodeVertices:vertices
                                 count:count
                             primitive:primitive
                              uniforms:u
                              textures:textures
                                  pass:pass()
                          depthStencil:depth_state
                              commands:commands
                                 error:&error],
                error);
    }
    read_depth();
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    [target getBytes:pixels
         bytesPerRow:sizeof(pixels[0])
          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
         mipmapLevel:0];
    draws++;
}

static float depth_at(unsigned x, unsigned y)
{
    const unsigned char *bytes = depth_readback.contents;
    float value;
    memcpy(&value, bytes + 256 * y + 4 * x, sizeof(value));
    return value;
}

static void check_depth(float actual, float expected)
{
    if (actual != expected) {
        fprintf(stderr, "Pixel depth draw %u: got %.9g expected %.9g\n", draws,
                actual, expected);
        abort();
    }
}

static id<MTLTexture> gradient(unsigned size)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:td];
    assert(t);
    float *data = calloc(size * size * 4, sizeof(float));
    assert(data);
    for (unsigned y = 0; y < size; y++) {
        for (unsigned x = 0; x < size; x++) {
            float *p = data + (y * size + x) * 4;
            p[0] = (x + .5f) / size;
            p[1] = (y + .5f) / size;
            p[2] = .2f;
            p[3] = .75f;
        }
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, size, size)
         mipmapLevel:0
           withBytes:data
         bytesPerRow:16 * size];
    free(data);
    return t;
}

static id<MTLTexture> solid(float r, float g, float b, float a)
{
    id<MTLTexture> t = gradient(1);
    float data[] = { r, g, b, a };
    [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
         mipmapLevel:0
           withBytes:data
         bytesPerRow:sizeof(data)];
    return t;
}

static id<MTLTexture> volume(void)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = MTLPixelFormatRGBA32Float;
    td.width = td.height = td.depth = 2;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:td];
    float data[8][4];
    for (unsigned z = 0; z < 2; z++) {
        for (unsigned y = 0; y < 2; y++) {
            for (unsigned x = 0; x < 2; x++) {
                float *p = data[z * 4 + y * 2 + x];
                p[0] = .1f + .4f * x;
                p[1] = .1f + .4f * y;
                p[2] = .1f + .4f * z;
                p[3] = 1;
            }
        }
    }
    [t replaceRegion:MTLRegionMake3D(0, 0, 0, 2, 2, 2)
          mipmapLevel:0
                slice:0
            withBytes:data
          bytesPerRow:32
        bytesPerImage:64];
    return t;
}

static id<MTLTexture> cube(void)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                        size:1
                                   mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:td];
    for (unsigned face = 0; face < 6; face++) {
        float data[] = { .1f * (face + 1), .2f, .3f, 1 };
        [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
              mipmapLevel:0
                    slice:face
                withBytes:data
              bytesPerRow:16
            bytesPerImage:16];
    }
    return t;
}

/* NV floating Z16 has a positive, biased exponent and twelve fraction bits.
 * Use arithmetic decomposition independently of the shader's bit packing. */
static unsigned f16_depth_code(float value)
{
    if (!(value >= 1.0f / 64))
        return 0;
    if (value >= 511.9375f)
        return 65535;
    int exponent;
    double fraction = frexp(value, &exponent);
    return (exponent + 6) * 4096 + (unsigned)((fraction * 2 - 1) * 4096);
}

static void f16_depth_encoding_tests(void)
{
    const unsigned size = 256, count = size * size;
    NSError *error = nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color_target = [commands.device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    id<MTLTexture> depth_target = [commands.device newTextureWithDescriptor:td];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:count * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> vertices =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    assert(color_target && depth_target && readback && vertices);
    NV2AMetalVertex *v = vertices.contents;
    NV2AMetalVertex q[6];
    quad(q);
    NV2AMetalPixelUniforms u = uniforms();
    u.depth_format = NV2AMetalPixelDepthF16;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    NV2AMetalPixelTexture textures[4] = { 0 };
    for (unsigned mode = 0; mode < 4; mode++) {
        for (unsigned i = 0; i < count; i++) {
            /* Decode every raw code, then probe both neighboring float32
             * values and an interior fraction. Exponent-zero draw values
             * flush to zero; raw upload/clear still retain those words. */
            float z = ldexpf(1 + (i % 4096) / 4096.0f, (int)(i / 4096) - 7);
            if (mode == 1)
                z = nextafterf(z, -INFINITY);
            else if (mode == 2)
                z = nextafterf(z, INFINITY);
            else if (mode == 3)
                z += ldexpf(.75f / 4096, (int)(i / 4096) - 7);
            v[i] = q[0];
            v[i].clip[0] = 2 * ((i % size + .5f) / size) - 1;
            v[i].clip[1] = 1 - 2 * ((i / size + .5f) / size);
            v[i].point_size = 1;
            for (unsigned k = 0; k < 3; k++)
                v[i].plane[k][2] = z;
        }
        MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
        p.colorAttachments[0].texture = color_target;
        p.colorAttachments[0].loadAction = MTLLoadActionClear;
        p.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        p.depthAttachment.texture = depth_target;
        p.depthAttachment.loadAction = MTLLoadActionClear;
        p.depthAttachment.storeAction = MTLStoreActionStore;
        p.depthAttachment.clearDepth = .123f;
        require([commands beginWithError:&error] != nil, error);
        require([shader encodeVertices:vertices
                                 count:count
                             primitive:MTLPrimitiveTypePoint
                              uniforms:&u
                              textures:textures
                                  pass:p
                          depthStencil:depth_state
                              commands:commands
                                 error:&error],
                error);
        require([commands addResource:readback error:&error], error);
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        assert(e);
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e copyFromTexture:depth_target
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(size, size, 1)
                            toBuffer:readback
                   destinationOffset:0
              destinationBytesPerRow:size * sizeof(float)
            destinationBytesPerImage:0
                             options:MTLBlitOptionNone];
        [e barrierAfterStages:MTLStageBlit
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        const float *actual = readback.contents;
        for (unsigned i = 0; i < count; i++) {
            float expected = f16_depth_code(v[i].plane[0][2]) / 65535.0f;
            if (actual[i] != expected) {
                fprintf(stderr,
                        "F16 mode %u code %u: z %.9g got %.9g "
                        "expected %.9g\n",
                        mode, i, v[i].plane[0][2], actual[i], expected);
                abort();
            }
        }
        draws++;
    }
    printf("Metal 4 F16 encoding: 4 native draws/262144 depths PASS\n");
}

static unsigned f24_depth_code(float value)
{
    if (!(value >= 0x1p-126f))
        return 0;
    int exponent;
    double fraction = frexp(value, &exponent);
    return (exponent + 126) * 65536 + (unsigned)((fraction * 2 - 1) * 65536);
}

static void f24_depth_encoding_tests(void)
{
    const unsigned size = 256, count = size * size;
    NSError *error = nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color_target = [commands.device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    id<MTLTexture> depth_target = [commands.device newTextureWithDescriptor:td];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:count * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> vertices =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    assert(color_target && depth_target && readback && vertices);
    NV2AMetalVertex *v = vertices.contents;
    NV2AMetalVertex q[6];
    quad(q);
    NV2AMetalPixelUniforms u = uniforms();
    u.depth_format = NV2AMetalPixelDepthF24;
    u.clip_range[1] = u.clip_range[3] = 0x1.fffffep127f;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    NV2AMetalPixelTexture textures[4] = { 0 };
    for (unsigned exponent = 0; exponent < 255; exponent++)
        for (unsigned mode = 0; mode < 4; mode++) {
            for (unsigned i = 0; i < count; i++) {
                /* Every exponent/fraction code, adjacent float32 values and
                 * an interior F24 fraction. Point depth is constant per vertex.
                 */
                float z = exponent ?
                              ldexpf(1 + i / 65536.0f, (int)exponent - 127) :
                              ldexpf(i / 65536.0f, -126);
                if (mode == 1)
                    z = nextafterf(z, -INFINITY);
                else if (mode == 2)
                    z = nextafterf(z, INFINITY);
                else if (mode == 3)
                    z += ldexpf(.75f / 65536,
                                exponent ? (int)exponent - 127 : -126);
                v[i] = q[0];
                v[i].clip[0] = 2 * ((i % size + .5f) / size) - 1;
                v[i].clip[1] = 1 - 2 * ((i / size + .5f) / size);
                v[i].point_size = 1;
                for (unsigned k = 0; k < 3; k++)
                    v[i].plane[k][2] = z;
            }
            MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
            p.colorAttachments[0].texture = color_target;
            p.colorAttachments[0].loadAction = MTLLoadActionClear;
            p.colorAttachments[0].storeAction = MTLStoreActionDontCare;
            p.depthAttachment.texture = depth_target;
            p.depthAttachment.loadAction = MTLLoadActionClear;
            p.depthAttachment.storeAction = MTLStoreActionStore;
            p.depthAttachment.clearDepth = .123f;
            require([commands beginWithError:&error] != nil, error);
            require([shader encodeVertices:vertices
                                     count:count
                                 primitive:MTLPrimitiveTypePoint
                                  uniforms:&u
                                  textures:textures
                                      pass:p
                              depthStencil:depth_state
                                  commands:commands
                                     error:&error],
                    error);
            require([commands addResource:readback error:&error], error);
            id<MTL4ComputeCommandEncoder> e =
                [commands.commandBuffer computeCommandEncoder];
            assert(e);
            [e barrierAfterQueueStages:MTLStageAll
                          beforeStages:MTLStageBlit
                     visibilityOptions:MTL4VisibilityOptionDevice];
            [e copyFromTexture:depth_target
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(size, size, 1)
                                toBuffer:readback
                       destinationOffset:0
                  destinationBytesPerRow:size * sizeof(float)
                destinationBytesPerImage:0
                                 options:MTLBlitOptionNone];
            [e barrierAfterStages:MTLStageBlit
                beforeQueueStages:MTLStageAll
                visibilityOptions:MTL4VisibilityOptionDevice];
            [e endEncoding];
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            const float *actual = readback.contents;
            for (unsigned i = 0; i < count; i++) {
                float expected = f24_depth_code(v[i].plane[0][2]) / 16777215.0f;
                if (actual[i] != expected) {
                    fprintf(stderr,
                            "F24 exponent %u mode %u code %u: z %.9g got %.9g "
                            "expected %.9g\n",
                            exponent, mode, i, v[i].plane[0][2], actual[i],
                            expected);
                    abort();
                }
            }
            draws++;
        }
    printf("Metal 4 F24 encoding: 1020 native draws/66846720 depths PASS\n");
}

static void f24_gradient_geometry_tests(void)
{
    const unsigned size = 256, quads = 1020, count = quads * 6;
    /* Four affine planes, with exact binary fractions at all pixel centres.
     * The last sixteen quads retain the existing subtraction-underflow path.
     */
    const unsigned fractions[4][4] = { { 0x4000, 0x8000, 0x8000, 0x4000 },
                                       { 0x8000, 0x4000, 0x4000, 0x8000 },
                                       { 0x4000, 0x4000, 0x8000, 0x8000 },
                                       { 0x8000, 0x6000, 0x4000, 0x6000 } };
    const unsigned small_fractions[4][4] = { { 0x4000, 0x5000, 0x5000, 0x4000 },
                                             { 0x8000, 0x7000, 0x7000, 0x8000 },
                                             { 0x4000, 0x4000, 0x5000, 0x5000 },
                                             { 0x8000, 0x7800, 0x7000,
                                               0x7800 } };
    const unsigned corners[6] = { 0, 1, 2, 0, 2, 3 };
    const unsigned xy[4][2] = { { 0, 0 }, { 8, 0 }, { 8, 8 }, { 0, 8 } };
    NSError *error = nil;
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    require(geometry != nil, error);
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    NV2AMetalVertexProgram *program =
        [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                 error:&error];
    require(fetch != nil && program != nil, error);
    /* MOV oPos.xyzw, v0.xyzw; final. Original vsh_regs.h token fields. */
    const uint32_t tokens[4] = { 0, 1u << 21 | 27, 2u << 26,
                                 1u << 11 | 15u << 12 | 1 };
    NV2AMetalProgramUniforms vp = { .surface_size = { size, size },
                                    .zmax = 0x1.ffffp127f,
                                    .point_size = 1,
                                    .point_scale = 1 };
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color_target = [commands.device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    id<MTLTexture> depth_target = [commands.device newTextureWithDescriptor:td];
    id<MTLBuffer> vertices =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:size * size * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> positions =
        [commands.device newBufferWithLength:(count + 1) * 4 * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> indices =
        [commands.device newBufferWithLength:count * sizeof(uint32_t)
                                     options:MTLResourceStorageModeShared];
    assert(color_target && depth_target && vertices && readback && positions &&
           indices);
    NV2AMetalPixelUniforms u = uniforms();
    u.depth_format = NV2AMetalPixelDepthF24;
    u.clip_range[1] = u.clip_range[3] = 0x1.fffffep127f;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    NV2AMetalPixelTexture textures[4] = { 0 };
    unsigned checked = 0, vertex_checked = 0;
    /* Direct geometry, fetched arrays, and reused indexed corners in both
     * guest index widths. The latter paths run fetch -> microcode -> geometry
     * -> fragment in one submission, without a CPU vertex readback between.
     */
    for (unsigned route = 0; route < 4; route++) {
        for (unsigned permutation = 0; permutation < 4; permutation++) {
            NV2AMetalVertex *v = vertices.contents;
            memset(v, 0, vertices.length);
            memset(positions.contents, 0xa5, positions.length);
            float (*input)[4] = positions.contents;
            unsigned index_size = route == 2 ? 2 : route == 3 ? 4 : 0;
            for (unsigned q = 0; q < quads; q++) {
                BOOL small = q >= 1004;
                unsigned exponent = small ? (q - 1004) / 4 : 4 + q / 4;
                unsigned pattern = q % 4;
                for (unsigned i = 0; i < 6; i++) {
                    unsigned k = i / 3 * 3 + (permutation == 3 ?
                                                  2 - i % 3 :
                                                  (i % 3 + permutation) % 3);
                    unsigned corner = corners[k];
                    NV2AMetalVertex *out = &v[q * 6 + i];
                    float x = (q % 32) * 8 + xy[corner][0];
                    float y = (q / 32) * 8 + xy[corner][1];
                    unsigned fraction = small ?
                                            small_fractions[pattern][corner] :
                                            fractions[pattern][corner];
                    uint32_t bits = ((exponent << 16) | fraction) << 7;
                    out->clip[0] = x / (size * .5f) - 1;
                    out->clip[1] = 1 - y / (size * .5f);
                    out->clip[2] = .5f;
                    out->clip[3] = 1;
                    out->screen[0] = x;
                    out->screen[1] = y;
                    memcpy(&out->screen[2], &bits, sizeof(bits));
                    out->screen[3] = 1;
                    unsigned source = route >= 2 ? q * 4 + corner : q * 6 + i;
                    input[source + 1][0] = x + 1.0f / 32;
                    input[source + 1][1] = y + 1.0f / 32;
                    memcpy(&input[source + 1][2], &bits, sizeof(bits));
                    input[source + 1][3] = 0.5f * (1u << corner);
                    if (index_size == 2)
                        ((uint16_t *)indices.contents)[q * 6 + i] = source;
                    else if (index_size == 4)
                        ((uint32_t *)indices.contents)[q * 6 + i] = source;
                }
            }
            MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
            p.colorAttachments[0].texture = color_target;
            p.colorAttachments[0].loadAction = MTLLoadActionClear;
            p.colorAttachments[0].storeAction = MTLStoreActionDontCare;
            p.depthAttachment.texture = depth_target;
            p.depthAttachment.loadAction = MTLLoadActionClear;
            p.depthAttachment.storeAction = MTLStoreActionStore;
            p.depthAttachment.clearDepth = .123f;
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalFetchResult *fetched = nil;
            NV2AMetalProgramResult *executed = nil;
            id<MTLBuffer> geometry_input = vertices;
            if (route) {
                NV2AMetalAttributeSource sources[16] = { 0 };
                sources[0] = (NV2AMetalAttributeSource){
                    .buffer = positions,
                    .count = 4,
                    .stride = 4 * sizeof(float),
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F
                };
                fetched = [fetch encodeSources:sources
                                         count:count
                                   firstVertex:1
                                       indices:index_size ? indices : nil
                                   indexOffset:0
                                     indexSize:index_size
                                      commands:commands
                                         error:&error];
                require(fetched != nil, error);
                executed = [program encodeTokens:tokens
                                          length:1
                                        uniforms:&vp
                                      attributes:fetched.attributes
                                           count:count
                                        commands:commands
                                           error:&error];
                require(executed != nil, error);
                geometry_input = executed.vertices;
            }
            NV2AMetalGeometryResult *result =
                [geometry encodeVertices:geometry_input
                                   count:count
                               primitive:NV2AMetalPrimitiveTriangles
                                 polygon:NV2AMetalPolygonFill
                                  smooth:YES
                          firstProvoking:YES
                            zPerspective:NO
                                commands:commands
                                   error:&error];
            require(result != nil, error);
            require([shader encodeVertices:result.vertices
                                     count:result.vertexCount
                                 primitive:result.primitiveType
                                  uniforms:&u
                                  textures:textures
                                      pass:p
                              depthStencil:depth_state
                                  commands:commands
                                     error:&error],
                    error);
            require([commands addResource:readback error:&error], error);
            id<MTL4ComputeCommandEncoder> encoder =
                [commands.commandBuffer computeCommandEncoder];
            assert(encoder);
            [encoder barrierAfterQueueStages:MTLStageAll
                                beforeStages:MTLStageBlit
                           visibilityOptions:MTL4VisibilityOptionDevice];
            [encoder copyFromTexture:depth_target
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(size, size, 1)
                                toBuffer:readback
                       destinationOffset:0
                  destinationBytesPerRow:size * sizeof(float)
                destinationBytesPerImage:0
                                 options:MTLBlitOptionNone];
            [encoder barrierAfterStages:MTLStageBlit
                      beforeQueueStages:MTLStageAll
                      visibilityOptions:MTL4VisibilityOptionDevice];
            [encoder endEncoding];
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            if (route) {
                const NV2AMetalProgramInput *attributes =
                    fetched.attributes.contents;
                const unsigned *faults = fetched.faults.contents;
                const NV2AMetalProgramOutput *raw = executed.registers.contents;
                const NV2AMetalVertex *output = executed.vertices.contents;
                for (unsigned i = 0; i < count; i++) {
                    unsigned source =
                        index_size == 2 ? ((uint16_t *)indices.contents)[i] :
                        index_size == 4 ? ((uint32_t *)indices.contents)[i] :
                                          i;
                    assert(!faults[i] &&
                           raw[i].fault == NV2AMetalProgramFaultNone);
                    assert(!memcmp(attributes[i].attributes[0],
                                   input[source + 1], 4 * sizeof(float)));
                    assert(!memcmp(raw[i].registers[0], input[source + 1],
                                   4 * sizeof(float)));
                    assert(!memcmp(output[i].screen, v[i].screen,
                                   3 * sizeof(float)));
                    assert(output[i].screen[3] == input[source + 1][3]);
                    vertex_checked++;
                }
            }
            const float *actual = readback.contents;
            for (unsigned q = 0; q < quads; q++) {
                BOOL small = q >= 1004;
                unsigned exponent = small ? (q - 1004) / 4 : 4 + q / 4;
                unsigned pattern = q % 4;
                for (unsigned y = 0; y < 8; y++) {
                    for (unsigned x = 0; x < 8; x++) {
                        /* Exclude the shared edge only for the underflow
                         * controls; the normal affine planes must agree on that
                         * edge too.
                         */
                        if (small && x == y)
                            continue;
                        unsigned fraction;
                        if (small) {
                            unsigned triangle = x > y ? 0 : 1;
                            unsigned anchor =
                                corners[triangle * 3 +
                                        (permutation == 3 ? 2 : permutation)];
                            fraction = small_fractions[pattern][anchor];
                        } else {
                            const unsigned expected[4] = {
                                0x4000 + 2048 * x + 1024,
                                0x8000 - 2048 * x - 1024,
                                0x4000 + 2048 * y + 1024,
                                0x8000 - 1024 * (x + y + 1)
                            };
                            fraction = expected[pattern];
                        }
                        unsigned code =
                            exponent ? (exponent << 16) | fraction : 0;
                        float expected = code / 16777215.0f;
                        unsigned index =
                            ((q / 32) * 8 + y) * size + (q % 32) * 8 + x;
                        if (actual[index] != expected) {
                            fprintf(stderr,
                                    "F24 gradient route %u permutation %u "
                                    "exponent %u "
                                    "pattern %u pixel %u,%u: got %.9g expected "
                                    "%.9g\n",
                                    route, permutation, exponent, pattern, x, y,
                                    actual[index], expected);
                            abort();
                        }
                        checked++;
                    }
                }
            }
            draws++;
        }
    }
    assert(checked == 1042432 && vertex_checked == 73440);
    printf("Metal 4 F24 affine gradients: 16 draws/1042432 depths; "
           "73440 Fetch->Vertex->Geometry vertices PASS\n");
}

static void raster_tests(void)
{
    NV2AMetalVertex v[6];
    NV2AMetalPixelTexture t[4] = { 0 };
    for (unsigned exclusive = 0; exclusive < 2; exclusive++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        u.window_clip_exclusive = exclusive;
        u.clip_regions[0][0] = 2;
        u.clip_regions[0][1] = 3;
        u.clip_regions[0][2] = 5;
        u.clip_regions[0][3] = 6;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        for (unsigned y = 0; y < 8; y++) {
            for (unsigned x = 0; x < 8; x++) {
                if ((x >= 2 && x < 5 && y >= 3 && y < 6) != exclusive) {
                    color(x, y, .1f, .2f, .3f, .4f);
                } else {
                    clear(x, y);
                }
            }
        }
    }
    /* 102 rounds to exactly 0.4 * 255. The tables independently cover all
     * comparison outcomes on either side and at equality. */
    const BOOL expected[3][8] = {
        { NO, NO, NO, NO, YES, YES, YES, YES },
        { NO, NO, YES, YES, NO, NO, YES, YES },
        { NO, YES, NO, YES, NO, YES, NO, YES },
    };
    for (unsigned ref = 101; ref <= 103; ref++) {
        for (unsigned f = 0; f < 8; f++) {
            NV2AMetalPixelUniforms u = uniforms();
            quad(v);
            u.alpha_test = 1;
            u.alpha_func = f;
            u.alpha_ref = ref;
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            if (expected[ref - 101][f]) {
                color(3, 4, .1f, .2f, .3f, .4f);
            } else {
                clear(3, 4);
            }
        }
    }
    for (unsigned mask = 0; mask < 16; mask++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        texture_mode(&u, 0, PS_TEXTUREMODES_CLIPPLANE);
        u.textures[0].compare_mask = mask;
        coord(v, 0, mask & 1 ? -1 : 1, mask & 2 ? -1 : 1, mask & 4 ? -1 : 1,
              mask & 8 ? -1 : 1);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, .1f, .2f, .3f, .4f);
        coord(v, 0, 0, 0, 0, 0);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        if (mask) {
            clear(3, 4);
        } else {
            color(3, 4, .1f, .2f, .3f, .4f);
        }
    }
    for (unsigned clipping = 0; clipping < 2; clipping++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        u.clip_range[3] = 2;
        u.depth_clipping = clipping;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        if (clipping) {
            clear(3, 4);
            check_depth(depth_at(3, 4), .99f);
        } else {
            color(3, 4, .1f, .2f, .3f, .4f);
            check_depth(depth_at(3, 4), 2.0f / 65535);
        }
    }
    for (unsigned format = 0; format < 4; format++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        u.depth_format = format;
        u.depth_offset = 1.5f;
        u.depth_factor = 2;
        for (unsigned i = 0; i < 6; i++) {
            v[i].slope = 3;
            v[i].plane[1][2] = 26.75f;
            v[i].plane[2][2] = 34.75f;
        }
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        /* At (3.5,4.5): 2.75+3*3.5+4*4.5+1.5+2*3=38.75. */
        float expected_depth = format == NV2AMetalPixelDepthD16 ?
                                   38.0f / 65535 :
                               format == NV2AMetalPixelDepthD24 ?
                                   nextafterf(38.0f / 16777216, INFINITY) :
                               format == NV2AMetalPixelDepthF16 ?
                                   f16_depth_code(38.75f) / 65535.0f :
                                   f24_depth_code(38.75f) / 16777215.0f;
        check_depth(depth_at(3, 4), expected_depth);
    }
}

static void f24_w_offset_geometry_tests(void)
{
    const unsigned size = 128, quads = 128, count = quads * 6;
    const unsigned corners[6] = { 0, 1, 2, 0, 2, 3 };
    const unsigned xy[4][2] = { { 0, 0 }, { 8, 0 }, { 8, 8 }, { 0, 8 } };
    NSError *error = nil;
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    NV2AMetalVertexProgram *program =
        [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                 error:&error];
    require(geometry && fetch && program, error);
    const uint32_t tokens[4] = { 0, 1u << 21 | 27, 2u << 26,
                                 1u << 11 | 15u << 12 | 1 };
    NV2AMetalProgramUniforms vp = { .surface_size = { size, size },
                                    .zmax = 0x1.ffffp127f,
                                    .point_size = 1,
                                    .point_scale = 1 };
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color_target = [commands.device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth_target = [commands.device newTextureWithDescriptor:td];
    id<MTLBuffer> vertices =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> positions =
        [commands.device newBufferWithLength:count * 4 * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:size * size * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    float (*colors)[4] = malloc(size * size * sizeof(*colors));
    assert(color_target && depth_target && vertices && positions && readback &&
           colors);
    NV2AMetalPixelUniforms u = uniforms();
    u.depth_format = NV2AMetalPixelDepthF24;
    u.z_perspective = 1;
    u.clip_range[1] = 0x1.ffffp127f;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    u.combiner.final_inputs[0] = PS_REGISTER_C0;
    u.combiner.final_inputs[1] = (PS_REGISTER_C0 | PS_CHANNEL_ALPHA) << 8;
    const float blue[4] = { .25f, .5f, .75f, 1 };
    memcpy(u.combiner.constants[16], blue, sizeof(blue));
    NV2AMetalPixelTexture textures[4] = { 0 };
    unsigned checked = 0, vertex_checked = 0, rendered = 0;
    for (unsigned route = 0; route < 2; route++)
        for (unsigned axis = 0; axis < 2; axis++)
            for (unsigned reverse = 0; reverse < 2; reverse++)
                for (unsigned permutation = 0; permutation < 3; permutation++)
                    for (unsigned mode = 0; mode < 6; mode++) {
                        NV2AMetalVertex *v = vertices.contents;
                        float (*input)[4] = positions.contents;
                        memset(v, 0, vertices.length);
                        for (unsigned q = 0; q < quads; q++)
                            for (unsigned i = 0; i < 6; i++) {
                                unsigned corner =
                                    corners[i / 3 * 3 +
                                            (i % 3 + permutation) % 3];
                                float x = (q % 16) * 8 + xy[corner][0];
                                float y = (q / 16) * 8 + xy[corner][1];
                                unsigned endpoint =
                                    xy[corner][axis] / 8 ^ reverse;
                                float w = ldexpf(1, (int)q - 64 + endpoint);
                                NV2AMetalVertex *out = &v[q * 6 + i];
                                out->screen[0] = x;
                                out->screen[1] = y;
                                out->screen[2] = 1;
                                out->screen[3] = w;
                                out->clip[0] = (x / (size * .5f) - 1) * w;
                                out->clip[1] = (1 - y / (size * .5f)) * w;
                                out->clip[2] = .5f * w;
                                out->clip[3] = w;
                                memcpy(input[q * 6 + i], out->screen,
                                       4 * sizeof(float));
                            }
                        u.depth_factor = mode == 1 || mode >= 4 ? .5f :
                                         mode == 2              ? -1 :
                                                                  0;
                        u.depth_offset = mode == 3 ? 0x1p-65f : 0;
                        u.clip_range[2] = mode >= 4 ? 0x1.4p-64f : 0;
                        u.clip_range[3] =
                            mode >= 4 ? 0x1.cp-64f : 0x1.ffffp127f;
                        u.depth_clipping = mode == 5;
                        require([commands beginWithError:&error] != nil, error);
                        NV2AMetalFetchResult *fetched = nil;
                        NV2AMetalProgramResult *executed = nil;
                        id<MTLBuffer> geometry_input = vertices;
                        if (route) {
                            NV2AMetalAttributeSource sources[16] = { 0 };
                            sources[0] = (NV2AMetalAttributeSource){
                                .buffer = positions,
                                .count = 4,
                                .stride = 16,
                                .format =
                                    NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F
                            };
                            fetched = [fetch encodeSources:sources
                                                     count:count
                                               firstVertex:0
                                                   indices:nil
                                               indexOffset:0
                                                 indexSize:0
                                                  commands:commands
                                                     error:&error];
                            require(fetched != nil, error);
                            executed = [program encodeTokens:tokens
                                                      length:1
                                                    uniforms:&vp
                                                  attributes:fetched.attributes
                                                       count:count
                                                    commands:commands
                                                       error:&error];
                            require(executed != nil, error);
                            geometry_input = executed.vertices;
                        }
                        NV2AMetalGeometryResult *result =
                            [geometry encodeVertices:geometry_input
                                               count:count
                                           primitive:NV2AMetalPrimitiveTriangles
                                             polygon:NV2AMetalPolygonFill
                                              smooth:YES
                                      firstProvoking:YES
                                        zPerspective:YES
                                            commands:commands
                                               error:&error];
                        require(result != nil, error);
                        MTL4RenderPassDescriptor *pass =
                            [MTL4RenderPassDescriptor new];
                        pass.colorAttachments[0].texture = color_target;
                        pass.colorAttachments[0].clearColor =
                            MTLClearColorMake(0, 0, 0, 0);
                        pass.colorAttachments[0].loadAction =
                            MTLLoadActionClear;
                        pass.colorAttachments[0].storeAction =
                            MTLStoreActionStore;
                        pass.depthAttachment.texture = depth_target;
                        pass.depthAttachment.loadAction = MTLLoadActionClear;
                        pass.depthAttachment.storeAction = MTLStoreActionStore;
                        pass.depthAttachment.clearDepth = .123f;
                        require([shader encodeVertices:result.vertices
                                                 count:result.vertexCount
                                             primitive:result.primitiveType
                                              uniforms:&u
                                              textures:textures
                                                  pass:pass
                                          depthStencil:depth_state
                                              commands:commands
                                                 error:&error],
                                error);
                        require([commands addResource:readback error:&error],
                                error);
                        id<MTL4ComputeCommandEncoder> encoder =
                            [commands.commandBuffer computeCommandEncoder];
                        assert(encoder);
                        [encoder
                            barrierAfterQueueStages:MTLStageAll
                                       beforeStages:MTLStageBlit
                                  visibilityOptions:MTL4VisibilityOptionDevice];
                        [encoder copyFromTexture:depth_target
                                         sourceSlice:0
                                         sourceLevel:0
                                        sourceOrigin:MTLOriginMake(0, 0, 0)
                                          sourceSize:MTLSizeMake(size, size, 1)
                                            toBuffer:readback
                                   destinationOffset:0
                              destinationBytesPerRow:size * 4
                            destinationBytesPerImage:0
                                             options:MTLBlitOptionNone];
                        [encoder barrierAfterStages:MTLStageBlit
                                  beforeQueueStages:MTLStageAll
                                  visibilityOptions:MTL4VisibilityOptionDevice];
                        [encoder endEncoding];
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error],
                                error);
                        [color_target getBytes:colors
                                   bytesPerRow:size * 16
                                    fromRegion:MTLRegionMake2D(0, 0, size, size)
                                   mipmapLevel:0];
                        if (route) {
                            const NV2AMetalProgramInput *attributes =
                                fetched.attributes.contents;
                            const unsigned *faults = fetched.faults.contents;
                            const NV2AMetalProgramOutput *raw =
                                executed.registers.contents;
                            const NV2AMetalVertex *out =
                                executed.vertices.contents;
                            for (unsigned i = 0; i < count; i++) {
                                assert(!faults[i] &&
                                       raw[i].fault ==
                                           NV2AMetalProgramFaultNone);
                                assert(!memcmp(attributes[i].attributes[0],
                                               input[i], 16));
                                assert(
                                    !memcmp(raw[i].registers[0], input[i], 16));
                                assert(!memcmp(out[i].screen, input[i], 16));
                                vertex_checked++;
                            }
                        }
                        const float *actual = readback.contents;
                        for (unsigned y = 0; y < size; y++)
                            for (unsigned x = 0; x < size; x++) {
                                unsigned q = (y / 8) * 16 + x / 8,
                                         index = y * size + x;
                                double z = 0;
                                BOOL covered = q < quads;
                                if (covered) {
                                    unsigned k = axis ? y % 8 : x % 8;
                                    double t = (k + .5) / 8;
                                    if (reverse)
                                        t = 1 - t;
                                    double base = ldexp(1, (int)q - 64);
                                    double w = base / (1 - t / 2);
                                    // Analytic reciprocal plane, not GPU
                                    // barycentric arithmetic.
                                    z = w + u.depth_offset +
                                        u.depth_factor * w * w / (16 * base);
                                    if (u.depth_clipping)
                                        covered = z >= u.clip_range[2] &&
                                                  z <= u.clip_range[3];
                                    else
                                        z = fmin(fmax(z, u.clip_range[2]),
                                                 u.clip_range[3]);
                                }
                                float expected =
                                    covered ?
                                        f24_depth_code((float)z) / 16777215.0f :
                                        .123f;
                                if (actual[index] != expected) {
                                    fprintf(stderr,
                                            "F24 W route%u axis%u reverse%u "
                                            "perm%u mode%u q%u pixel%u,%u: "
                                            "%.9g expected%.9g z%.17g\n",
                                            route, axis, reverse, permutation,
                                            mode, q, x, y, actual[index],
                                            expected, z);
                                    abort();
                                }
                                for (unsigned c = 0; c < 4; c++) {
                                    float wanted = covered ? blue[c] : 0;
                                    if (colors[index][c] != wanted) {
                                        fprintf(stderr,
                                                "F24 W color route%u axis%u "
                                                "reverse%u perm%u mode%u q%u "
                                                "pixel%u,%u channel%u: %.9g "
                                                "expected%.9g\n",
                                                route, axis, reverse,
                                                permutation, mode, q, x, y, c,
                                                colors[index][c], wanted);
                                        abort();
                                    }
                                }
                                checked++;
                            }
                        rendered++;
                        draws++;
                    }
    free(colors);
    assert(rendered == 144 && checked == 2359296 && vertex_checked == 55296);
    printf("Metal4 F24 W/offset/clipping: %u draws/%u color-depth pixels/%u "
           "Fetch-MOV vertices PASS\n",
           rendered, checked, vertex_checked);
}

static void w_depth_tests(void)
{
    NV2AMetalVertex v[6];
    NV2AMetalPixelTexture t[4] = { 0 };
    NV2AMetalPixelUniforms u = uniforms();
    quad(v);
    u.z_perspective = 1;
    u.depth_offset = 2;
    u.depth_factor = .5f;
    for (unsigned i = 0; i < 6; i++) {
        v[i].slope = 2;
        v[i].plane[0][3] = 1;
        v[i].plane[1][3] = 2;
        v[i].plane[2][3] = 4;
    }
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    /* Harmonic W at (2.5,3.5) is 64/33. Bias gives floor(W+2+W*W)=7. */
    check_depth(depth_at(2, 3), 7.0f / 65535);
    for (unsigned clipping = 0; clipping < 2; clipping++) {
        u.depth_clipping = clipping;
        for (unsigned i = 0; i < 6; i++) {
            for (unsigned k = 0; k < 3; k++) {
                v[i].plane[k][3] = -1;
            }
        }
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        if (clipping) {
            clear(2, 3);
            check_depth(depth_at(2, 3), .99f);
        } else {
            check_depth(depth_at(2, 3), 1);
        }
    }
}

static void sampling_tests(void)
{
    NV2AMetalVertex v[6];
    NV2AMetalPixelTexture t[4] = { 0 };
    id<MTLTexture> tex = gradient(4), tex16 = gradient(16);
    __attribute__((objc_precise_lifetime)) id<MTLTexture> signed_source =
        solid(-.4f, -.25f, .25f, 1);
    id<MTLTexture> tex3 = volume(), tex_cube = cube();
    for (unsigned stage = 0; stage < 4; stage++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        texture_mode(&u, stage, PS_TEXTUREMODES_PROJECT2D);
        show_texture(&u, stage);
        u.textures[stage].rectangle = 1;
        u.textures[stage].scale = 2;
        coord(v, stage, 1.25f, .75f, .2f, 1);
        t[stage].texture = tex;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, .625f, .375f, .2f, .75f);
    }
    for (unsigned two = 0; two < 2; two++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        texture_mode(
            &u, 0, two ? PS_TEXTUREMODES_PROJECT2D : PS_TEXTUREMODES_PROJECT3D);
        show_texture(&u, 0);
        u.textures[0].dimension = 3;
        coord(v, 0, .75f, .25f, .75f, 1);
        t[0].texture = tex3;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, .5f, .1f, two ? .1f : .5f, 1);
    }
    const float axes[6][3] = { { 1, 0, 0 },  { -1, 0, 0 }, { 0, 1, 0 },
                               { 0, -1, 0 }, { 0, 0, 1 },  { 0, 0, -1 } };
    for (unsigned face = 0; face < 6; face++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        texture_mode(&u, 0, PS_TEXTUREMODES_CUBEMAP);
        show_texture(&u, 0);
        u.textures[0].cubemap = 1;
        coord(v, 0, axes[face][0], axes[face][1], axes[face][2], 1);
        t[0].texture = tex_cube;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, .1f * (face + 1), .2f, .3f, 1);
    }
    NV2AMetalPixelUniforms u = uniforms();
    quad(v);
    texture_mode(&u, 0, PS_TEXTUREMODES_CUBEMAP);
    show_texture(&u, 0);
    coord(v, 0, 1, .375f, -.625f, 1);
    t[0].texture = tex;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .625f, .375f, .2f, .75f);

    for (unsigned signed_bump = 0; signed_bump < 2; signed_bump++) {
        for (unsigned lum = 0; lum < 2; lum++) {
            u = uniforms();
            quad(v);
            texture_mode(&u, 0,
                         signed_bump ? PS_TEXTUREMODES_PROJECT2D :
                                       PS_TEXTUREMODES_PASSTHRU);
            texture_mode(&u, 1,
                         lum ? PS_TEXTUREMODES_BUMPENVMAP_LUM :
                               PS_TEXTUREMODES_BUMPENVMAP);
            show_texture(&u, 1);
            u.textures[0].snorm = signed_bump;
            if (signed_bump) {
                // A negative bump source must be an actual signed texture;
                // PASS_THROUGH clamps coordinates and cannot supply it.
                t[0].texture = signed_source;
            }
            coord(v, 0, signed_bump ? -.4f : .4f,
                  signed_bump ? -.25f : (256 - .25f * 127) / 255,
                  signed_bump ? .25f : .25f * 127 / 255, 1);
            if (signed_bump)
                coord(v, 0, .5f, .5f, 0, 1);
            coord(v, 1, .46875f, .53125f, .2f, 1);
            const float matrix[] = { 1, .25f, .5f, 1 };
            memcpy(u.textures[1].bump_matrix, matrix, sizeof(matrix));
            u.textures[1].bump_scale = 2;
            u.textures[1].bump_offset = .1f;
            t[1].texture = tex16;
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            float factor = lum ? (signed_bump ? 1.0f : .9f) : 1;
            color(3, 4, .59375f * factor, .34375f * factor, .2f * factor, .75f);
        }
    }
    for (unsigned stage = 1; stage < 4; stage++) {
        for (unsigned gb = 0; gb < 2; gb++) {
            u = uniforms();
            quad(v);
            texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
            texture_mode(&u, stage,
                         gb ? PS_TEXTUREMODES_DPNDNT_GB :
                              PS_TEXTUREMODES_DPNDNT_AR);
            show_texture(&u, stage);
            coord(v, 0, .375f, .625f, .375f, .625f);
            t[stage].texture = tex;
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            color(3, 4, .625f, .375f, .2f, .75f);
        }
    }
    u = uniforms();
    quad(v);
    texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
    texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
    texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ST);
    show_texture(&u, 2);
    coord(v, 0, .25f, .5f, .75f, 1);
    coord(v, 1, 1, 0, 0, 1);
    coord(v, 2, 0, 1, 0, 1);
    t[2].texture = tex;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .375f, .625f, .2f, .75f);
    texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
    texture_mode(&u, 3, PS_TEXTUREMODES_DOT_STR_3D);
    show_texture(&u, 3);
    u.textures[3].dimension = 3;
    coord(v, 3, 0, 0, 1, 1);
    t[3].texture = tex3;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .1f, .5f, .5f, 1);

    id<MTLTexture> key_texture =
        solid(17.0f / 255, 34.0f / 255, 51.0f / 255, 68.0f / 255);
    for (unsigned mode = 0; mode < 4; mode++) {
        u = uniforms();
        quad(v);
        texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
        show_texture(&u, 0);
        u.textures[0].colorkey_mode = mode;
        u.textures[0].color_key = 0x44112233;
        u.textures[0].color_key_mask = 0xffffffff;
        t[0].texture = key_texture;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        if (mode == COLOR_KEY_DISCARD) {
            clear(3, 4);
        } else {
            color(3, 4,
                  mode == COLOR_KEY_KILL_COLOR_AND_ALPHA ? 0 : 17.0f / 255,
                  mode == COLOR_KEY_KILL_COLOR_AND_ALPHA ? 0 : 34.0f / 255,
                  mode == COLOR_KEY_KILL_COLOR_AND_ALPHA ? 0 : 51.0f / 255,
                  mode ? 0 : 68.0f / 255);
        }
        u.textures[0].color_key ^= 1;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, 17.0f / 255, 34.0f / 255, 51.0f / 255, 68.0f / 255);
    }
    u = uniforms();
    quad(v);
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 0);
    id<MTLTexture> alpha_texture = solid(.1f, .2f, .3f, 0);
    t[0].texture = alpha_texture;
    u.textures[0].alphakill = 1;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    clear(3, 4);
    texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
    coord(v, 0, .1f, .2f, .3f, 0);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .1f, .2f, .3f, 0);
}

/* NV_texture_shader 3.8.13.1.6 clamps the interpolated coordinates before
 * either the combiner or a dependent texture operation can consume them. */
static void passthrough_tests(void)
{
    const float inputs[][4] = {
        { -2, -.25f, 1.25f, 3 },
        { 1.25f, -2, 3, -.25f },
        { 3, 1.25f, -.25f, -2 },
        { -.25f, 3, -2, 1.25f },
        { -0.0f, 0, 1, 1 },
        { .125f, .375f, .625f, .875f },
        { -.0001f, .9999f, 1.0001f, .0001f },
        { .9999f, 1.0001f, .0001f, -.0001f },
    };
    const unsigned first_draw = draws;
    for (unsigned stage = 0; stage < 4; stage++) {
        for (unsigned k = 0; k < sizeof(inputs) / sizeof(inputs[0]); k++) {
            NV2AMetalPixelUniforms u = uniforms();
            NV2AMetalVertex v[6];
            NV2AMetalPixelTexture textures[4] = { 0 };
            quad(v);
            texture_mode(&u, stage, PS_TEXTUREMODES_PASSTHRU);
            show_texture(&u, stage);
            coord(v, stage, inputs[k][0], inputs[k][1], inputs[k][2],
                  inputs[k][3]);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            float expected[4];
            for (unsigned c = 0; c < 4; c++)
                expected[c] = fminf(1, fmaxf(0, inputs[k][c]));
            for (unsigned y = 0; y < 8; y++)
                for (unsigned x = 0; x < 8; x++)
                    color(x, y, expected[0], expected[1], expected[2],
                          expected[3]);
        }
        // Interpolate -0.5..1.5 across the quad, THEN clamp each fragment.
        // Clamping endpoint values before interpolation produces x/8 instead.
        NV2AMetalPixelUniforms u = uniforms();
        NV2AMetalVertex v[6];
        NV2AMetalPixelTexture textures[4] = { 0 };
        quad(v);
        texture_mode(&u, stage, PS_TEXTUREMODES_PASSTHRU);
        show_texture(&u, stage);
        for (unsigned i = 0; i < 6; i++) {
            float x = 4 * (v[i].clip[0] + 1), y = 4 * (1 - v[i].clip[1]);
            v[i].texcoord[stage][0] = x / 4 - .5f;
            v[i].texcoord[stage][1] = y / 4 - .5f;
            v[i].texcoord[stage][2] = 1.5f - x / 4;
            v[i].texcoord[stage][3] = 1.5f - y / 4;
        }
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                float r = fminf(1, fmaxf(0, (x + .5f) / 4 - .5f));
                float g = fminf(1, fmaxf(0, (y + .5f) / 4 - .5f));
                color(x, y, r, g, 1 - r, 1 - g);
            }
    }
    id<MTLTexture> tex = gradient(4);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeRepeat;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.supportArgumentBuffers = YES;
    __attribute__((objc_precise_lifetime)) id<MTLSamplerState> repeat =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(repeat);
    for (unsigned wrap = 0; wrap < 2; wrap++)
        for (unsigned manual = 0; manual < 2; manual++)
            for (unsigned stage = 1; stage < 4; stage++)
                for (unsigned gb = 0; gb < 2; gb++)
                    for (unsigned k = 0; k < sizeof(inputs) / sizeof(inputs[0]);
                         k++) {
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalVertex v[6];
                        NV2AMetalPixelTexture textures[4] = { 0 };
                        quad(v);
                        texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
                        texture_mode(&u, stage,
                                     gb ? PS_TEXTUREMODES_DPNDNT_GB :
                                          PS_TEXTUREMODES_DPNDNT_AR);
                        show_texture(&u, stage);
                        coord(v, 0, inputs[k][0], inputs[k][1], inputs[k][2],
                              inputs[k][3]);
                        textures[stage].texture = tex;
                        textures[stage].sampler = wrap ? repeat : nil;
                        u.textures[stage].sampling.enabled = manual;
                        u.textures[stage].sampling.address[0] =
                            u.textures[stage].sampling.address[1] =
                                wrap ? 1 : 3;
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                        // Clamp before addressing; at 1, REPEAT wraps to
                        // texel0.
                        float a = fminf(1, fmaxf(0, inputs[k][gb ? 1 : 3]));
                        float b = fminf(1, fmaxf(0, inputs[k][gb ? 2 : 0]));
                        unsigned x = wrap && a == 1 ?
                                         0 :
                                         (unsigned)fminf(3, floorf(a * 4));
                        unsigned y = wrap && b == 1 ?
                                         0 :
                                         (unsigned)fminf(3, floorf(b * 4));
                        for (unsigned py = 0; py < 8; py++)
                            for (unsigned px = 0; px < 8; px++)
                                color(px, py, (x + .5f) / 4, (y + .5f) / 4, .2f,
                                      .75f);
                    }
    printf(
        "Metal 4 pass-through: %u clamped/interpolated/dependent draws PASS\n",
        draws - first_draw);
}

static void special_sampling_tests(void)
{
    NV2AMetalVertex v[6];
    NV2AMetalPixelTexture t[4] = { 0 };
    /* Reference compares sampled depth to Z/W (not the reverse order). */
    const BOOL less[8] = { NO, YES, NO, YES, NO, YES, NO, YES };
    const BOOL equal[8] = { NO, NO, YES, YES, NO, NO, YES, YES };
    for (unsigned format = 0; format < 3; format++) {
        id<MTLTexture> source = solid(.5f, format == 1, format == 2, 1);
        float maximum = format == 1 ? 16777215 :
                        format == 2 ? 511.9375f :
                                      65535;
        t[0].texture = source;
        for (unsigned f = 0; f < 8; f++) {
            NV2AMetalPixelUniforms u = uniforms();
            quad(v);
            texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT3D);
            show_texture(&u, 0);
            u.textures[0].shadow = 1;
            u.shadow_func = f;
            coord(v, 0, .625f, .375f, maximum, 2);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            float value = equal[f];
            color(3, 4, value, value, value, value);
            coord(v, 0, .625f, .375f, maximum * .75f, 1);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            value = less[f];
            color(3, 4, value, value, value, value);
            texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            value = f == SHADOW_DEPTH_FUNC_GREATER ||
                    f == SHADOW_DEPTH_FUNC_NOTEQUAL ||
                    f == SHADOW_DEPTH_FUNC_GEQUAL ||
                    f == SHADOW_DEPTH_FUNC_ALWAYS;
            color(3, 4, value, value, value, value);
        }
    }
    id<MTLTexture> tex16 = gradient(16);
    NV2AMetalPixelUniforms u = uniforms();
    quad(v);
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 0);
    for (unsigned k = 0; k < 3; k++) {
        u.textures[0].border_logical_size[k] = 2;
        u.textures[0].border_inv_real_size[k] = 1.0f / 16;
    }
    coord(v, 0, .5f, .5f, .5f, 1);
    t[0].texture = tex16;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .34375f, .34375f, .2f, .75f);
    u.textures[1] = u.textures[0];
    memset(&u.textures[0], 0, sizeof(u.textures[0]));
    texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
    texture_mode(&u, 1, PS_TEXTUREMODES_DPNDNT_AR);
    show_texture(&u, 1);
    coord(v, 0, .5f, .5f, .5f, .5f);
    t[1].texture = tex16;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .34375f, .34375f, .2f, .75f);

    id<MTLTexture> impulse = gradient(4);
    float data[16][4] = { 0 };
    for (unsigned k = 0; k < 16; k++) {
        data[k][3] = 1;
    }
    data[5][0] = 1;
    [impulse replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:64];
    for (unsigned convolution = CONVOLUTION_FILTER_QUINCUNX;
         convolution <= CONVOLUTION_FILTER_GAUSSIAN; convolution++) {
        u = uniforms();
        quad(v);
        texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
        show_texture(&u, 0);
        u.textures[0].convolution = convolution;
        coord(v, 0, .375f, .375f, 0, 1);
        t[0].texture = impulse;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, .25f, 0, 0, 1);
    }
    id<MTLTexture> tex_cube = cube();
    const unsigned reflection_modes[] = { PS_TEXTUREMODES_DOT_RFLCT_DIFF,
                                          PS_TEXTUREMODES_DOT_RFLCT_SPEC,
                                          PS_TEXTUREMODES_DOT_STR_CUBE };
    for (unsigned k = 0; k < 3; k++) {
        u = uniforms();
        quad(v);
        texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
        texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
        texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
        unsigned stage = k == 0 ? 2 : 3;
        texture_mode(&u, stage, reflection_modes[k]);
        show_texture(&u, stage);
        u.textures[stage].cubemap = 1;
        coord(v, 0, .25f, .5f, .75f, 1);
        coord(v, 1, 4, 0, 0, 1);
        coord(v, 2, 0, 0, 0, 0);
        coord(v, 3, 0, 0, 0, 0);
        t[stage].texture = tex_cube;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, .1f, .2f, .3f, 1);
    }
    /* Distinct mapping values avoid sampling boundaries at the nearest texel.
     * HILO_1 and hemisphere modes concatenate A:R and G:B. */
    const float texel[8][2] = { { .65625f, .65625f }, { .34375f, .34375f },
                                { .03125f, .03125f }, { .03125f, .03125f },
                                { .40625f, .65625f }, { .78125f, .03125f },
                                { .78125f, .03125f }, { .78125f, .03125f } };
    for (unsigned map = 0; map < 8; map++) {
        u = uniforms();
        quad(v);
        texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
        texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
        texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ST);
        show_texture(&u, 2);
        u.other_stage_input = map | map << 4;
        coord(v, 0, 170.0f / 255, 170.0f / 255, 170.0f / 255, 102.0f / 255);
        coord(v, 1, 1, 0, 0, 1);
        coord(v, 2, 0, 1, 0, 1);
        t[2].texture = tex16;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, texel[map][0], texel[map][1], .2f, .75f);
    }
}

static void geometry_handoff_test(void)
{
    NSError *error = nil;
    NV2AMetalGeometry *g =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    require(g != nil, error);
    NV2AMetalVertex v[6];
    quad(v);
    const float xy[6][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 },
                             { 8, 0 }, { 8, 8 }, { 0, 8 } };
    for (unsigned i = 0; i < 6; i++) {
        v[i].screen[0] = xy[i][0];
        v[i].screen[1] = xy[i][1];
        v[i].screen[2] = 42.5f;
        v[i].screen[3] = 1;
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryResult *result =
        [g encodeVertices:input
                     count:6
                 primitive:NV2AMetalPrimitiveTriangles
                   polygon:NV2AMetalPolygonFill
                    smooth:YES
            firstProvoking:YES
              zPerspective:NO
                  commands:commands
                     error:&error];
    require(result != nil, error);
    require([shader encodeVertices:result.vertices
                             count:result.vertexCount
                         primitive:result.primitiveType
                          uniforms:&u
                          textures:textures
                              pass:pass()
                      depthStencil:depth_state
                          commands:commands
                             error:&error],
            error);
    read_depth();
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    [target getBytes:pixels
         bytesPerRow:sizeof(pixels[0])
          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
         mipmapLevel:0];
    draws++;
    color(3, 4, .1f, .2f, .3f, .4f);
    check_depth(depth_at(3, 4), 42.0f / 65535);
}

static void primitive_tests(void)
{
    NV2AMetalVertex v[6];
    quad(v);
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture t[4] = { 0 };
    v[0].clip[0] = v[0].clip[1] = 0;
    render(&u, v, 1, MTLPrimitiveTypePoint, t);
    color(3, 3, .1f, .2f, .3f, .4f);
    color(4, 4, .1f, .2f, .3f, .4f);
    clear(2, 3);
    clear(5, 4);
    id<MTLTexture> tex = gradient(2);
    texture_mode(&u, 3, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 3);
    u.point_sprite = 1;
    t[3].texture = tex;
    render(&u, v, 1, MTLPrimitiveTypePoint, t);
    color(3, 3, .25f, .25f, .2f, .75f);
    color(4, 4, .75f, .75f, .2f, .75f);
    u = uniforms();
    quad(v);
    v[0].clip[1] = v[1].clip[1] = .125f;
    render(&u, v, 2, MTLPrimitiveTypeLine, t);
    unsigned covered = 0;
    for (unsigned y = 0; y < 8; y++) {
        for (unsigned x = 0; x < 8; x++) {
            if (pixels[y][x][0] != clear_color[0]) {
                color(x, y, .1f, .2f, .3f, .4f);
                covered++;
            }
        }
    }
    assert(covered == 8);
}

static void interpolation_and_sampler_tests(void)
{
    NV2AMetalVertex v[6];
    NV2AMetalPixelTexture t[4] = { 0 };
    NV2AMetalPixelUniforms u = uniforms();
    quad(v);
    for (unsigned i = 0; i < 6; i++) {
        float x = (v[i].clip[0] + 1) / 2;
        float y = (1 - v[i].clip[1]) / 2;
        v[i].color[0][0] = x;
        v[i].color[0][1] = y;
        v[i].fog = y;
    }
    render(&u, v, 3, MTLPrimitiveTypeTriangle, t);
    color(1, 2, 1.5f / 8, 2.5f / 8, .3f, .4f);
    u.smooth_shading = 0;
    render(&u, v, 3, MTLPrimitiveTypeTriangle, t);
    color(1, 2, 0, 0, .3f, .4f);
    u.combiner.final_inputs[0] = PS_REGISTER_FOG;
    u.combiner.final_inputs[1] = (PS_REGISTER_FOG | PS_CHANNEL_ALPHA) << 8;
    u.fog_color[0] = .7f;
    u.fog_color[1] = .6f;
    u.fog_color[2] = .5f;
    render(&u, v, 3, MTLPrimitiveTypeTriangle, t);
    color(1, 2, .7f, .6f, .5f, 2.5f / 8);

    id<MTLTexture> tex = gradient(2);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);
    u = uniforms();
    quad(v);
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 0);
    coord(v, 0, .5f, .5f, .2f, 1);
    t[0].texture = tex;
    t[0].sampler = sampler;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .5f, .5f, .2f, .75f);

    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:2
                                    height:2
                                 mipmapped:YES];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> mipped = [commands.device newTextureWithDescriptor:td];
    float red[4][4] = {
        { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 }
    };
    float green[] = { 0, 1, 0, 1 };
    [mipped replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
              mipmapLevel:0
                withBytes:red
              bytesPerRow:32];
    [mipped replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
              mipmapLevel:1
                withBytes:green
              bytesPerRow:16];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.mipFilter = MTLSamplerMipFilterNearest;
    sd.lodMinClamp = sd.lodMaxClamp = 1;
    sampler = [commands.device newSamplerStateWithDescriptor:sd];
    t[0].texture = mipped;
    t[0].sampler = sampler;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, 0, 1, 0, 1);

    id<MTLTexture> tex_cube = cube();
    t[0].texture = tex_cube;
    t[0].sampler = nil;
    u.textures[0].cubemap = 1;
    coord(v, 0, 1.25f, .75f, .2f, 2);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    color(3, 4, .1f, .2f, .3f, 1);
    const unsigned modes[] = { PS_TEXTUREMODES_NONE, PS_TEXTUREMODES_DOT_ZW,
                               PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST };
    for (unsigned k = 0; k < 3; k++) {
        u = uniforms();
        quad(v);
        unsigned stage = k == 2 ? 3 : 2;
        texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
        texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
        texture_mode(&u, stage, modes[k]);
        u.legacy_spec_const = k == 2;
        show_texture(&u, stage);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, 0, 0, 0, k == 0 ? 1 : 0);
        check_depth(depth_at(3, 4), k == 1 ? 1 : 2.0f / 65535);
    }
    u = uniforms();
    quad(v);
    u.surface_scale[0] = u.surface_scale[1] = 2;
    for (unsigned i = 0; i < 6; i++) {
        v[i].plane[1][2] = 26.75f;
        v[i].plane[2][2] = 34.75f;
    }
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    /* (3.5,4.5)/2 -> floor(2.75+3*1.75+4*2.25)=17. */
    check_depth(depth_at(3, 4), 17.0f / 65535);

    id<MTLTexture> key_texture =
        solid(17.0f / 255, 34.0f / 255, 51.0f / 255, 68.0f / 255);
    u = uniforms();
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 0);
    t[0].texture = key_texture;
    u.textures[0].alphakill = 1;
    u.textures[0].colorkey_mode = COLOR_KEY_KILL_ALPHA;
    u.textures[0].color_key = 0xff112233;
    u.textures[0].color_key_mask = 0x00ffffff;
    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    /* Key-generated zero alpha is retained: alpha kill ran before keying. */
    color(3, 4, 17.0f / 255, 34.0f / 255, 51.0f / 255, 0);
}

static void rejection_tests(void)
{
    NSError *error = nil;
    NV2AMetalVertex v[6];
    quad(v);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    id<MTLTexture> tex = gradient(4);
    id<MTLTexture> view =
        [target newTextureViewWithPixelFormat:target.pixelFormat];
    assert(view);
    require([commands beginWithError:&error] != nil, error);
    for (unsigned test = 0; test < 28; test++) {
        error = nil;
        NV2AMetalPixelUniforms u = uniforms();
        NV2AMetalPixelTexture t[4] = { 0 };
        t[0].texture = tex;
        texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
        MTL4RenderPassDescriptor *p = pass();
        NSUInteger count = 6;
        switch (test) {
        case 0:
            t[0].texture = nil;
            break;
        case 1:
            t[0].texture = target;
            break;
        case 2:
            t[0].texture = view;
            break;
        case 3:
            u.textures[0].dimension = 3;
            break;
        case 4:
            texture_mode(&u, 2, PS_TEXTUREMODES_DPNDNT_AR);
            u.other_stage_input = 2 << 16;
            break;
        case 5:
            u.alpha_ref = 256;
            break;
        case 6:
            u.textures[0].border_logical_size[0] = 2;
            break;
        case 7:
            p.colorAttachments[1].texture = target;
            break;
        case 8:
            p.colorAttachments[0].level = 1;
            break;
        case 9:
            p.colorAttachments[0].resolveTexture = target;
            p.colorAttachments[0].storeAction =
                MTLStoreActionMultisampleResolve;
            break;
        case 10:
            p.depthAttachment.texture = nil;
            break;
        case 11:
            count = 7;
            break;
        case 12:
            p.depthAttachment.resolveTexture = depth;
            break;
        case 13:
            u.depth_format = 99;
            break;
        case 14:
            u.clip_range[2] = 65536;
            break;
        case 15:
            u.textures[0].convolution = 3;
            break;
        case 16:
            p.colorAttachments[0].storeAction =
                MTLStoreActionMultisampleResolve;
            break;
        case 24:
            u.textures[0].signed_channels = 16;
            break;
        case 25:
            u.textures[0].signed_channels = 1;
            u.textures[0].snorm = 1;
            break;
        case 26:
            u.textures[0].signed_channels = 1;
            u.textures[0].shadow = 1;
            break;
        case 27:
            u.textures[0].signed_channels = 1;
            u.textures[0].dimension = 0;
            break;
        case 17:
        case 18:
        case 19:
        case 20:
        case 21:
        case 22:
        case 23: {
            NV2AMetalSamplingUniforms *s = &u.textures[0].sampling;
            s->enabled = 1;
            s->address[0] = s->address[1] = s->address[2] = 3;
            s->anisotropy = 1;
            switch (test) {
            case 17:
                s->enabled = 2;
                break;
            case 18:
                s->address[1] = 6;
                break;
            case 19:
                s->anisotropy = 3;
                break;
            case 20:
                s->lod_bias = NAN;
                break;
            case 21:
                s->border_color[3] = INFINITY;
                break;
            case 22:
                s->min_linear = 2;
                break;
            case 23:
                s->mip_filter = 1;
                u.textures[0].rectangle = 1;
                break;
            }
            break;
        }
        }
        assert(![shader encodeVertices:input
                                 count:count
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:t
                                  pass:p
                          depthStencil:depth_state
                              commands:commands
                                 error:&error]);
        assert(error);
    }
    [commands cancel];
}

static void hilo_exhaustive_test(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    NSString *kernel =
        @"\nkernel void nv2a_hilo_check(device const uint *input "
        @"[[buffer(0)]],\n"
         "device float4 *output [[buffer(1)]], constant uint2 &p "
         "[[buffer(2)]],\n"
         "uint id [[thread_position_in_grid]]) {\n"
         "if (id >= p.y) return; uint c = input[id];\n"
         "float4 color(float((c >> 16) & 255), float((c >> 8) & 255),\n"
         "float(c & 255), float(c >> 24));\n"
         "output[id] = float4(pixel_dotmap(color / 255.0f, p.x), 0); }\n";
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = [@(metal_shader_source) stringByAppendingString:kernel];
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = library;
    function.name = @"nv2a_hilo_check";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = function;
    id<MTLComputePipelineState> pipeline =
        [compiler newComputePipelineStateWithDescriptor:pd
                                    compilerTaskOptions:nil
                                                  error:&error];
    require(pipeline != nil, error);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 3;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(arguments != nil, error);
    const unsigned count = 7 * 65536;
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:count * 4
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:count * 16
                                     options:MTLResourceStorageModeShared];
    assert(input && output);
    uint32_t *words = input.contents;
    for (unsigned pattern = 0; pattern < 7; pattern++)
        for (unsigned value = 0; value < 65536; value++) {
            unsigned fixed = pattern < 2 ? 0 : pattern < 4 ? 0x4000 : 0x8000;
            unsigned hi = pattern & 1 ? fixed : value;
            unsigned lo = pattern & 1 ? value : fixed;
            if (pattern == 6)
                lo = (value * 40503 + 97) & 65535;
            words[pattern * 65536 + value] = hi << 16 | lo;
        }
    for (unsigned mode = 4; mode <= 7; mode++) {
        uint32_t params[] = { mode, count };
        id<MTLBuffer> uniform =
            [commands.device newBufferWithBytes:params
                                         length:sizeof(params)
                                        options:MTLResourceStorageModeShared];
        assert(uniform);
        require([commands beginWithError:&error] != nil, error);
        require([commands addResource:input error:&error] &&
                    [commands addResource:output error:&error] &&
                    [commands addResource:uniform error:&error] &&
                    [commands keepAlive:pipeline error:&error] &&
                    [commands keepAlive:arguments error:&error],
                error);
        [arguments setAddress:input.gpuAddress atIndex:0];
        [arguments setAddress:output.gpuAddress atIndex:1];
        [arguments setAddress:uniform.gpuAddress atIndex:2];
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        assert(encoder);
        [encoder setArgumentTable:arguments];
        [encoder setComputePipelineState:pipeline];
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(pipeline.threadExecutionWidth, 1,
                                              1)];
        [encoder barrierAfterStages:MTLStageDispatch
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        const float *actual = output.contents;
        for (unsigned i = 0; i < count; i++) {
            unsigned raw[] = { words[i] >> 16, words[i] & 65535 };
            double expected[3] = { 0, 0, 1 };
            for (unsigned axis = 0; axis < 2; axis++) {
                int signedValue =
                    raw[axis] < 32768 ? (int)raw[axis] : (int)raw[axis] - 65536;
                expected[axis] = mode == 4 ? raw[axis] / 65535.0 :
                                 mode == 5 ? signedValue / 32768.0 :
                                 mode == 6 ? (signedValue + .5) / 32767.5 :
                                             signedValue / 32767.0;
            }
            if (mode != 4)
                expected[2] = sqrt(fmax(0, 1 - expected[0] * expected[0] -
                                               expected[1] * expected[1]));
            for (unsigned axis = 0; axis < 3; axis++) {
                // Near the hemisphere rim the sqrt magnifies Float32 input
                // rounding. X/Y still require their full Float32 precision.
                double tolerance =
                    axis != 2         ? 0.00000012 :
                    expected[2] > .01 ? .0000002 / expected[2] + .0000001 :
                                        .0004;
                if (!isfinite(actual[i * 4 + axis]) ||
                    fabs(actual[i * 4 + axis] - expected[axis]) > tolerance) {
                    fprintf(
                        stderr,
                        "HILO mode%u word%08x axis%u got%.9g expected%.12g\n",
                        mode, words[i], axis, actual[i * 4 + axis],
                        expected[axis]);
                    abort();
                }
            }
        }
    }
    printf("Metal 4 HILO: %u raw ARGB mappings PASS\n", count * 4);
}

static void hilo_fragment_tests(void)
{
    __attribute__((objc_precise_lifetime)) id<MTLTexture> normalCube = cube();
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalVertex v[6];
    for (unsigned map = 5; map <= 7; map++) {
        NV2AMetalPixelUniforms u = uniforms();
        quad(v);
        texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
        texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
        texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
        texture_mode(&u, 3, PS_TEXTUREMODES_DOT_STR_CUBE);
        u.other_stage_input = map | map << 4 | map << 8;
        coord(v, 0, 0, 64.0f / 255, 0, 32.0f / 255);
        coord(v, 1, 1, 0, 0, 1);
        coord(v, 2, 0, 1, 0, 1);
        coord(v, 3, 0, 0, 1, 1);
        show_texture(&u, 3);
        u.textures[3].cubemap = 1;
        textures[3].texture = normalCube;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        color(3, 4, .5f, .2f, .3f, 1); // Positive Z from hemisphere completion.
        texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ZW);
        texture_mode(&u, 3, PS_TEXTUREMODES_NONE);
        coord(v, 1, 0, 0, 1, 1);
        coord(v, 2, 0, 0, 2, 1);
        u.combiner.final_inputs[0] = PS_REGISTER_V0;
        u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        color(3, 4, .1f, .2f, .3f, .4f);
        check_depth(depth_at(3, 4), 32767.0f / 65535);
    }
}


static void reflection_range_tests(void)
{
    __attribute__((objc_precise_lifetime)) id<MTLTexture> reflection_cube =
        cube();
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                     width:16
                                    height:16
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    __attribute__((objc_precise_lifetime)) id<MTLTexture> reflection_2d =
        [commands.device newTextureWithDescriptor:td];
    assert(reflection_2d);
    _Float16 data[16][16][4];
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            data[y][x][0] = (x + .5f) / 16;
            data[y][x][1] = (y + .5f) / 16;
            data[y][x][2] = .25f;
            data[y][x][3] = .75f;
        }
    [reflection_2d replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
                     mipmapLevel:0
                       withBytes:data
                     bytesPerRow:sizeof(data[0])];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode =
        MTLSamplerAddressModeClampToEdge;
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> linear =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(linear);
    const float normals[][3] = { { 2, 1, 0 },   { 1, 0, 2 },  { 0, 2, 1 },
                                 { -2, -1, 0 }, { 2, -1, 1 }, { 0, 0, 1 } };
    const float eyes[][3] = { { 1, .25f, -.5f },
                              { -.25f, 1, .5f },
                              { .5f, -.25f, 1 } };
    const int exponents[] = { 0, 70, -70, 100, -100 };
    unsigned cases = 0;
    for (unsigned n = 0; n < sizeof(normals) / sizeof(*normals); n++) {
        for (unsigned e = 0; e < sizeof(eyes) / sizeof(*eyes); e++) {
            // Double-precision oracle uses the unscaled vectors. Independent
            // positive scaling of N and E must preserve reflection direction.
            double nn = 0, ne = 0, reflected[3];
            for (unsigned k = 0; k < 3; k++) {
                nn += (double)normals[n][k] * normals[n][k];
                ne += (double)normals[n][k] * eyes[e][k];
            }
            for (unsigned k = 0; k < 3; k++)
                reflected[k] = 2 * ne / nn * normals[n][k] - eyes[e][k];
            unsigned axis = 0;
            for (unsigned k = 1; k < 3; k++)
                if (fabs(reflected[k]) > fabs(reflected[axis]))
                    axis = k;
            unsigned face = axis * 2 + (reflected[axis] < 0);
            float scale_reference[5][2][3][4] = { 0 };
            for (unsigned ns = 0; ns < sizeof(exponents) / sizeof(*exponents);
                 ns++)
                for (unsigned es = 0;
                     es < sizeof(exponents) / sizeof(*exponents); es++)
                    for (unsigned constant_eye = 0; constant_eye < 2;
                         constant_eye++)
                        for (unsigned manual = 0; manual < 2; manual++)
                            for (unsigned target_kind = 0; target_kind < 3;
                                 target_kind++) {
                                BOOL cubemap = target_kind == 0,
                                     bordered = target_kind == 2;
                                NV2AMetalVertex v[6];
                                quad(v);
                                NV2AMetalPixelUniforms u = uniforms();
                                NV2AMetalPixelTexture textures[4] = { 0 };
                                texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
                                texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
                                texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
                                texture_mode(
                                    &u, 3,
                                    constant_eye ?
                                        PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST :
                                        PS_TEXTUREMODES_DOT_RFLCT_SPEC);
                                show_texture(&u, 3);
                                u.textures[3].cubemap = cubemap;
                                u.textures[3].sampling.enabled = manual;
                                u.textures[3].sampling.min_linear =
                                    u.textures[3].sampling.mag_linear =
                                        !cubemap;
                                if (bordered) {
                                    for (unsigned k = 0; k < 3; k++) {
                                        u.textures[3].border_logical_size[k] =
                                            k == 2 ? 1 : 8;
                                        u.textures[3].border_inv_real_size[k] =
                                            1.f / 16;
                                    }
                                }
                                textures[3].texture =
                                    cubemap ? reflection_cube : reflection_2d;
                                textures[3].sampler = cubemap ? nil : linear;
                                coord(v, 0, 1, 0, 0, 1);
                                for (unsigned k = 0; k < 3; k++) {
                                    u.eye_vector[k] =
                                        ldexpf(eyes[e][k], exponents[es]);
                                    coord(v, k + 1,
                                          ldexpf(normals[n][k], exponents[ns]),
                                          0, 0,
                                          constant_eye ? 13 + k * 4 :
                                                         u.eye_vector[k]);
                                }
                                render(&u, v, 6, MTLPrimitiveTypeTriangle,
                                       textures);
                                double c[3];
                                for (unsigned k = 0; k < 3; k++) {
                                    c[k] = ldexp(reflected[k], exponents[es]);
                                    if (bordered)
                                        c[k] =
                                            (c[k] * (k == 2 ? 1 : 8) + 4) / 16;
                                }
                                unsigned a = fabs(c[0]) > fabs(c[1]) &&
                                                     fabs(c[0]) > fabs(c[2]) ?
                                                 0 :
                                             fabs(c[1]) > fabs(c[0]) &&
                                                     fabs(c[1]) > fabs(c[2]) ?
                                                 1 :
                                                 2;
                                double x = a == 0 ? (c[0] > 0 ? -c[2] : c[2]) :
                                           a == 1 ? c[0] :
                                                    (c[2] > 0 ? c[0] : -c[0]);
                                double y =
                                    a == 1 ? (c[1] > 0 ? -c[2] : c[2]) : c[1];
                                x = fmin(31.0 / 32,
                                         fmax(1.0 / 32, x / fabs(c[a])));
                                y = fmin(31.0 / 32,
                                         fmax(1.0 / 32, y / fabs(c[a])));
                                float expected[] = {
                                    cubemap ? .1f * (face + 1) : x,
                                    cubemap ? .2f : y, cubemap ? .3f : .25f,
                                    cubemap ? 1 : .75f
                                };
                                // Native float filtering has its own fractional
                                // precision. Check its analytic color within a
                                // bounded tolerance, and require the tighter
                                // scale-invariance comparison against N-scale1.
                                float tolerance =
                                    !manual && !cubemap ? 1.f / 2048 : .000015f;
                                if (!ns && !manual)
                                    memcpy(scale_reference[es][constant_eye]
                                                          [target_kind],
                                           pixels[4][3], sizeof(pixels[4][3]));
                                for (unsigned y = 0; y < 8; y++)
                                    for (unsigned x = 0; x < 8; x++)
                                        for (unsigned k = 0; k < 4; k++) {
                                            float actual = pixels[y][x][k];
                                            if (!isfinite(actual) ||
                                                fabsf(actual - expected[k]) >
                                                    tolerance) {
                                                fprintf(stderr,
                                                        "Reflection range: "
                                                        "N=%u E=%u ns=%d es=%d "
                                                        "const=%u manual=%u "
                                                        "target=%u channel=%u "
                                                        "got=%g expected=%g "
                                                        "tolerance=%g\n",
                                                        n, e, exponents[ns],
                                                        exponents[es],
                                                        constant_eye, manual,
                                                        target_kind, k, actual,
                                                        expected[k], tolerance);
                                                abort();
                                            }
                                            if (!manual && !cubemap && ns)
                                                check(actual,
                                                      scale_reference
                                                          [es][constant_eye]
                                                          [target_kind][k]);
                                        }
                                cases++;
                            }
        }
    }
    assert(cases == 5400);
    printf("Metal4 reflection range: %u normal/eye/target scale draws PASS\n",
           cases);
}

/* The BRDF inputs are packed ARGB words, not repeated-byte R16/B16 colors.
 * NVIDIA US6664963 equations8/9 define thetaEye/thetaLight/phiLight-phiEye.
 * These tests establish that source-based contract, not Xbox measurement. */
static id<MTLTexture> brdf_angles(uint32_t word, BOOL cubemap, BOOL hilo16)
{
    MTLPixelFormat format =
        hilo16 ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA8Unorm;
    MTLTextureDescriptor *td =
        cubemap ?
            [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:format
                                                                  size:1
                                                             mipmapped:NO] :
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                               width:1
                                                              height:1
                                                           mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:td];
    assert(texture);
    uint8_t rgba[] = { word >> 16, word >> 8, word, word >> 24 };
    float values[] = { (word >> 16) / 65535.f, (word & 65535) / 65535.f,
                       (word & 65535) / 65535.f, 1 };
    NSUInteger length = hilo16 ? sizeof(values) : sizeof(rgba);
    const void *data = hilo16 ? (const void *)values : rgba;
    for (unsigned face = 0; face < (cubemap ? 6 : 1); face++)
        [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                   mipmapLevel:0
                         slice:face
                     withBytes:data
                   bytesPerRow:length
                 bytesPerImage:length];
    return texture;
}

static void brdf_texel(int x, int y, int z, BOOL padded, float rgba[4])
{
    if (padded) {
        x -= 4;
        y -= 4;
        z -= 4;
    }
    if (x < 0 || x >= 4 || y < 0 || y >= 4 || z < 0 || z >= 4) {
        const float border[] = { .875f, .75f, .625f, .25f };
        memcpy(rgba, border, sizeof(border));
    } else {
        rgba[0] = (x + 1) / 16.f;
        rgba[1] = (y + 1) / 16.f;
        rgba[2] = (z + 1) / 16.f;
        rgba[3] = .5f + (x + 2 * y + z) / 64.f;
    }
}

static id<MTLTexture> brdf_lookup(BOOL padded)
{
    unsigned size = padded ? 12 : 4;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = MTLPixelFormatRGBA32Float;
    td.width = td.height = td.depth = size;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:td];
    assert(texture);
    float data[12 * 12 * 12][4];
    for (unsigned z = 0; z < size; z++)
        for (unsigned y = 0; y < size; y++)
            for (unsigned x = 0; x < size; x++)
                brdf_texel(x, y, z, padded, data[(z * size + y) * size + x]);
    [texture replaceRegion:MTLRegionMake3D(0, 0, 0, size, size, size)
               mipmapLevel:0
                     slice:0
                 withBytes:data
               bytesPerRow:16 * size
             bytesPerImage:16 * size * size];
    return texture;
}

static void brdf_reference(uint32_t eye, uint32_t light, BOOL linear,
                           unsigned address, BOOL padded, float rgba[4])
{
    // Calculate from raw unsigned16 words independently of MSL byte packing.
    double c[] = { (eye >> 16) / 65535.0, (light >> 16) / 65535.0,
                   ((int)(light & 65535) - (int)(eye & 65535)) / 65535.0 };
    int size = padded ? 12 : 4, base[3];
    double fraction[3];
    for (unsigned axis = 0; axis < 3; axis++) {
        double position = c[axis] * 4 + (padded ? 4 : 0) - (linear ? .5 : 0);
        base[axis] = (int)floor(position);
        fraction[axis] = linear ? position - base[axis] : 0;
    }
    memset(rgba, 0, 4 * sizeof(*rgba));
    for (unsigned tap = 0; tap < (linear ? 8 : 1); tap++) {
        int index[3];
        double weight = 1;
        BOOL border = NO;
        for (unsigned axis = 0; axis < 3; axis++) {
            unsigned high = (tap >> axis) & 1;
            index[axis] = base[axis] + high;
            weight *= high ? fraction[axis] : 1 - fraction[axis];
            if (axis == 2 && address == 1)
                index[axis] = (index[axis] % size + size) % size;
            else if (axis == 2 && address == 4 &&
                     (index[axis] < 0 || index[axis] >= size))
                border = YES;
            else
                index[axis] = index[axis] < 0     ? 0 :
                              index[axis] >= size ? size - 1 :
                                                    index[axis];
        }
        float texel[4] = {};
        if (!border)
            brdf_texel(index[0], index[1], index[2], padded, texel);
        for (unsigned channel = 0; channel < 4; channel++)
            rgba[channel] += weight * texel[channel];
    }
}

static void brdf_tests(BOOL hilo16)
{
    const uint32_t pairs[][2] = {
        { 0x30001000, 0xd0007000 }, { 0x1289e237, 0xabe36519 },
        { 0x0102ff00, 0xfefd00ff }, { 0x00000000, 0xffffffff },
        { 0x80800101, 0x7f7ffefe }, { 0x23456789, 0x9abcdef0 },
        { 0x55aa3322, 0xaa557766 }, { 0x33338000, 0xcccc8000 },
    };
    const unsigned addresses[] = { 1, 3, 4 };
    __attribute__((objc_precise_lifetime)) id<MTLTexture> lookup =
                                                              brdf_lookup(NO),
                                                          padded_lookup =
                                                              brdf_lookup(YES);
    unsigned cases = 0;
    for (unsigned pair = 0; pair < 8; pair++)
        for (unsigned reverse = 0; reverse < 2; reverse++) {
            uint32_t eye = pairs[pair][reverse], light = pairs[pair][!reverse];
            BOOL cubemap = pair & 1;
            __attribute__((objc_precise_lifetime)) id<MTLTexture>
                eye_texture = brdf_angles(eye, cubemap, hilo16),
                light_texture = brdf_angles(light, cubemap, hilo16);
            for (unsigned stage = 2; stage <= 3; stage++)
                for (unsigned manual = 0; manual < 2; manual++)
                    for (unsigned linear = 0; linear < 2; linear++)
                        for (unsigned a = 0; a < 3; a++)
                            for (unsigned padded = 0; padded < 2; padded++) {
                                NV2AMetalPixelUniforms u = uniforms();
                                NV2AMetalVertex v[6];
                                quad(v);
                                NV2AMetalPixelTexture t[4] = {};
                                // Stage3 has a decoy T0; selectors/dotmap must
                                // not redirect BRDF's fixed two predecessors.
                                texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
                                coord(v, 0, 1, 0, 1, 0);
                                for (unsigned source = stage - 2;
                                     source < stage; source++) {
                                    texture_mode(&u, source,
                                                 cubemap ?
                                                     PS_TEXTUREMODES_CUBEMAP :
                                                     PS_TEXTUREMODES_PROJECT2D);
                                    u.textures[source].cubemap = cubemap;
                                    u.textures[source].sampling.enabled =
                                        manual;
                                    coord(v, source, 1, .25f, -.5f, 1);
                                }
                                u.hilo16_mask = hilo16 ? 3u << (stage - 2) : 0;
                                t[stage - 2].texture = eye_texture;
                                t[stage - 1].texture = light_texture;
                                t[stage].texture =
                                    padded ? padded_lookup : lookup;
                                texture_mode(&u, stage, PS_TEXTUREMODES_BRDF);
                                u.other_stage_input =
                                    ((pair % 2) << 16) | ((pair % 3) << 20) |
                                    ((pair % 8) << 4) | ((7 - pair) << 8);
                                u.textures[stage].dimension = 3;
                                u.textures[stage].sampling.enabled = manual;
                                u.textures[stage].sampling.min_linear = linear;
                                u.textures[stage].sampling.mag_linear = linear;
                                u.textures[stage].sampling.address[2] =
                                    addresses[a];
                                if (padded)
                                    for (unsigned axis = 0; axis < 3; axis++) {
                                        u.textures[stage]
                                            .border_logical_size[axis] = 4;
                                        u.textures[stage]
                                            .border_inv_real_size[axis] =
                                            1.f / 12;
                                    }
                                MTLSamplerDescriptor *sd =
                                    [MTLSamplerDescriptor new];
                                sd.minFilter = sd.magFilter =
                                    linear ? MTLSamplerMinMagFilterLinear :
                                             MTLSamplerMinMagFilterNearest;
                                sd.sAddressMode = sd.tAddressMode =
                                    MTLSamplerAddressModeClampToEdge;
                                sd.rAddressMode =
                                    a == 0 ?
                                        MTLSamplerAddressModeRepeat :
                                    a == 1 ?
                                        MTLSamplerAddressModeClampToEdge :
                                        MTLSamplerAddressModeClampToBorderColor;
                                sd.borderColor =
                                    MTLSamplerBorderColorTransparentBlack;
                                __attribute__((
                                    objc_precise_lifetime)) id<MTLSamplerState>
                                    sampler = [commands.device
                                        newSamplerStateWithDescriptor:sd];
                                assert(sampler);
                                t[stage].sampler = sampler;
                                show_texture(&u, stage);
                                render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                                float expected[4];
                                brdf_reference(eye, light, linear, addresses[a],
                                               padded, expected);
                                // Native fractional filter precision differs
                                // from the manual floating-point interpolation.
                                float tolerance =
                                    !manual && linear ? 1.f / 2048 : .000015f;
                                for (unsigned y = 0; y < 8; y++)
                                    for (unsigned x = 0; x < 8; x++)
                                        for (unsigned channel = 0; channel < 4;
                                             channel++) {
                                            float actual =
                                                pixels[y][x][channel];
                                            if (!isfinite(actual) ||
                                                fabsf(actual -
                                                      expected[channel]) >
                                                    tolerance) {
                                                fprintf(stderr,
                                                        "BRDF pair%u reverse%u "
                                                        "stage%u manual%u "
                                                        "linear%u address%u "
                                                        "padded%u channel%u "
                                                        "got%g expected%g\n",
                                                        pair, reverse, stage,
                                                        manual, linear,
                                                        addresses[a], padded,
                                                        channel, actual,
                                                        expected[channel]);
                                                abort();
                                            }
                                        }
                                cases++;
                            }
        }
    assert(cases == 768);
    printf(
        "Metal4 BRDF HILO16=%u: %u packed-angle/3D lookup draws, %u full-frame "
        "channels PASS\n",
        hilo16, cases, cases * 8 * 8 * 4);
}

static void hilo16_dot_tests(void)
{
    const uint32_t words[] = { 0x1289e237, 0xabe36519, 0x0102ff00, 0xfefd00ff,
                               0,          UINT32_MAX, 0x80800101, 0x7f7ffefe };
    unsigned cases = 0;
    __attribute__((objc_precise_lifetime)) id<MTLTexture> lookup = gradient(4);
    for (unsigned word = 0; word < 8; word++) {
        __attribute__((objc_precise_lifetime)) id<MTLTexture> source =
            brdf_angles(words[word], NO, YES);
        for (unsigned mapping = 0; mapping < 8; mapping++)
            for (unsigned manual = 0; manual < 2; manual++) {
                NV2AMetalPixelUniforms u = uniforms();
                NV2AMetalVertex v[6];
                quad(v);
                u.hilo16_mask = 1;
                texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
                texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ST);
                u.other_stage_input = mapping | mapping << 4;
                for (unsigned stage = 0; stage < 3; stage++)
                    u.textures[stage].sampling.enabled = manual;
                u.textures[2].sampling.min_linear =
                    u.textures[2].sampling.mag_linear = 1;
                coord(v, 1, .25f, .5f, .125f, 1);
                coord(v, 2, .5f, .25f, .0625f, 1);
                NV2AMetalPixelTexture t[4] = {};
                t[0].texture = source;
                t[2].texture = lookup;
                MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
                sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
                sd.sAddressMode = sd.tAddressMode =
                    MTLSamplerAddressModeClampToEdge;
                __attribute__((objc_precise_lifetime)) id<MTLSamplerState>
                    sampler =
                        [commands.device newSamplerStateWithDescriptor:sd];
                t[2].sampler = sampler;
                show_texture(&u, 2);
                render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                double hi = (words[word] >> 16) / 65535.0,
                       lo = (words[word] & 65535) / 65535.0;
                float expected[] = {
                    fmin(.875, fmax(.125, .25 * hi + .5 * lo + .125)),
                    fmin(.875, fmax(.125, .5 * hi + .25 * lo + .0625)), .2f,
                    .75f
                };
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++)
                        for (unsigned channel = 0; channel < 4; channel++) {
                            float actual = pixels[y][x][channel];
                            assert(isfinite(actual) &&
                                   fabsf(actual - expected[channel]) <=
                                       (manual ? .000015f : 1.f / 2048));
                        }
                cases++;
            }
    }
    assert(cases == 128);
    for (unsigned bad = 0; bad < 5; bad++) {
        NV2AMetalPixelUniforms u = uniforms();
        u.hilo16_mask = 1;
        switch (bad) {
        case 0:
            u.hilo16_mask = 16;
            break;
        case 1:
            u.textures[0].dimension = 0;
            break;
        case 2:
            u.textures[0].signed_channels = 1;
            break;
        case 3:
            u.textures[0].snorm = 1;
            break;
        case 4:
            u.textures[0].shadow = 1;
            break;
        }
        assert(!nv2a_metal_pixel_validate(&u, NULL));
    }
    printf("Metal4 HILO16: %u unsigned dot/remap draws,5 invalid states PASS\n",
           cases);
}

static void brdf_effect_tests(void)
{
    __attribute__((objc_precise_lifetime)) id<MTLTexture> angles = brdf_angles(
                                                              0x30001000, NO,
                                                              NO),
                                                          lut = volume(),
                                                          dependent =
                                                              gradient(4);
    unsigned cases = 0;
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned stage = 2; stage <= 3; stage++)
            for (unsigned effect = 0; effect < (stage == 2 ? 9 : 7); effect++) {
                float data[8][4];
                for (unsigned texel = 0; texel < 8; texel++) {
                    data[texel][0] = .25f;
                    data[texel][1] = .5f;
                    data[texel][2] = .75f;
                    data[texel][3] = effect == 5 ? 0 : 1;
                }
                [lut replaceRegion:MTLRegionMake3D(0, 0, 0, 2, 2, 2)
                       mipmapLevel:0
                             slice:0
                         withBytes:data
                       bytesPerRow:32
                     bytesPerImage:64];
                NV2AMetalPixelUniforms u = uniforms();
                NV2AMetalVertex v[6];
                quad(v);
                NV2AMetalPixelTexture t[4] = {};
                for (unsigned source = stage - 2; source < stage; source++) {
                    texture_mode(&u, source, PS_TEXTUREMODES_PROJECT2D);
                    u.textures[source].sampling.enabled = manual;
                    t[source].texture = angles;
                }
                texture_mode(&u, stage, PS_TEXTUREMODES_BRDF);
                u.textures[stage].dimension = 3;
                u.textures[stage].sampling.enabled = manual;
                u.textures[stage].alphakill = effect == 5 || effect == 6;
                u.textures[stage].colorkey_mode =
                    effect >= 1 && effect <= 4 ?
                        (effect == 4 ? COLOR_KEY_DISCARD : effect) :
                        0;
                u.textures[stage].color_key =
                    effect == 4 ? 0xff4080be : 0xff4080bf;
                u.textures[stage].color_key_mask = UINT32_MAX;
                t[stage].texture = lut;
                show_texture(&u, stage);
                if (effect >= 7) {
                    texture_mode(&u, 3,
                                 effect == 7 ? PS_TEXTUREMODES_DPNDNT_AR :
                                               PS_TEXTUREMODES_DPNDNT_GB);
                    u.other_stage_input = 2u << 20;
                    u.textures[3].sampling.enabled = manual;
                    t[3].texture = dependent;
                    show_texture(&u, 3);
                }
                render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        if (effect == COLOR_KEY_DISCARD || effect == 5) {
                            clear(x, y);
                            check_depth(depth_at(x, y), draw_clear_depth);
                        } else if (effect == COLOR_KEY_KILL_COLOR_AND_ALPHA)
                            color(x, y, 0, 0, 0, 0);
                        else if (effect >= 7)
                            color(x, y, effect == 7 ? .875f : .625f,
                                  effect == 7 ? .375f : .875f, .2f, .75f);
                        else
                            color(x, y, .25f, .5f, .75f,
                                  effect == COLOR_KEY_KILL_ALPHA ? 0 : 1);
                    }
                cases++;
            }
    assert(cases == 32);
    printf("Metal4 BRDF: %u alpha/key/dependent draws PASS\n", cases);
}

static void brdf_rejection_tests(void)
{
    NSError *error = nil;
    NV2AMetalVertex v[6];
    quad(v);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    __attribute__((objc_precise_lifetime)) id<MTLTexture> wrong2d = gradient(1),
                                                          wrong_cube = cube(),
                                                          valid = volume();
    unsigned cases = 0;
    for (unsigned stage = 0; stage < 4; stage++) {
        NV2AMetalPixelUniforms u = uniforms();
        texture_mode(&u, stage, PS_TEXTUREMODES_BRDF);
        u.textures[stage].dimension = 3;
        if (stage < 2) {
            assert(!nv2a_metal_pixel_validate(&u, &error));
            cases++;
            continue;
        }
        assert(nv2a_metal_pixel_validate(&u, &error));
        for (unsigned bad = 0; bad < 8; bad++) {
            NV2AMetalPixelUniforms invalid = u;
            switch (bad) {
            case 0:
                invalid.textures[stage].dimension = 0;
                break;
            case 1:
                invalid.textures[stage].dimension = 2;
                break;
            case 2:
                invalid.textures[stage].cubemap = 1;
                break;
            case 3:
                invalid.textures[stage].rectangle = 1;
                break;
            case 4:
                invalid.textures[stage].shadow = 1;
                break;
            case 5:
                invalid.textures[stage].convolution = 1;
                break;
            case 6:
                invalid.textures[stage].scale = 0;
                break;
            case 7:
                invalid.textures[stage].colorkey_mode = 4;
                break;
            }
            assert(!nv2a_metal_pixel_validate(&invalid, &error));
            cases++;
        }
        NV2AMetalPixelTexture t[4] = {};
        for (unsigned bad = 0; bad < 3; bad++) {
            t[stage].texture = bad == 0 ? nil : bad == 1 ? wrong2d : wrong_cube;
            require([commands beginWithError:&error] != nil, error);
            assert(![shader encodeVertices:input
                                     count:6
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:t
                                      pass:pass()
                              depthStencil:depth_state
                                  commands:commands
                                     error:&error]);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            cases++;
        }
        t[stage].texture = valid;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
    }
    assert(cases == 24);
    printf("Metal4 BRDF: %u invalid stage/state/resource cases rejected PASS\n",
           cases);
}

static void constant_eye_tests(void)
{
    NV2AMetalPixelTexture textures[4] = { 0 };
    __attribute__((objc_precise_lifetime)) id<MTLTexture> reflectionCube =
        cube();
    textures[3].texture = reflectionCube;
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned axis = 0; axis < 3; axis++)
            for (unsigned sign = 0; sign < 2; sign++)
                for (unsigned eyeAxis = 0; eyeAxis < 3; eyeAxis++)
                    for (unsigned eyeSign = 0; eyeSign < 2; eyeSign++) {
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalVertex v[6];
                        quad(v);
                        texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
                        texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
                        texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
                        texture_mode(&u, 3,
                                     PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST);
                        show_texture(&u, 3);
                        u.textures[3].cubemap = 1;
                        u.textures[3].sampling.enabled = manual;
                        float normal[3] = { 0 };
                        normal[axis] = sign ? -2 : 2;
                        u.eye_vector[eyeAxis] = eyeSign ? -3 : 3;
                        coord(v, 0, 1, 0, 0, 1);
                        // Deliberately conflicting q coordinates must have no
                        // effect on the constant-eye reflection.
                        for (unsigned i = 0; i < 3; i++)
                            coord(v, i + 1, normal[i], 0, 0, 13 + i * 4);
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                        unsigned reflectedNegative =
                            eyeSign ^ (axis != eyeAxis);
                        unsigned face = eyeAxis * 2 + reflectedNegative;
                        for (unsigned y = 0; y < 8; y++)
                            for (unsigned x = 0; x < 8; x++)
                                color(x, y, .1f * (face + 1), .2f, .3f, 1);
                    }
    const struct {
        float normal[3], eye[3];
        unsigned face;
    } oblique[] = {
        { { 2, 1, 0 }, { 1, 0, 0 }, 2 },  { { 20, 10, 0 }, { 1, 0, 0 }, 2 },
        { { 0, 2, 1 }, { 0, 1, 0 }, 4 },  { { 1, 0, 2 }, { 0, 0, 1 }, 0 },
        { { 2, 1, 0 }, { -1, 0, 0 }, 3 }, { { 0, 2, 1 }, { 0, -1, 0 }, 5 },
        { { 1, 0, 2 }, { 0, 0, -1 }, 1 }, { { -2, -1, 0 }, { 1, 0, 0 }, 2 },
    };
    NV2AMetalVertex v[6];
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned k = 0; k < sizeof(oblique) / sizeof(oblique[0]); k++) {
            NV2AMetalPixelUniforms u = uniforms();
            quad(v);
            texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
            texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
            texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
            texture_mode(&u, 3, PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST);
            show_texture(&u, 3);
            u.textures[3].cubemap = 1;
            u.textures[3].sampling.enabled = manual;
            memcpy(u.eye_vector, oblique[k].eye, 12);
            coord(v, 0, 1, 0, 0, 1);
            for (unsigned i = 0; i < 3; i++)
                coord(v, i + 1, oblique[k].normal[i], 0, 0, 13 + i * 4);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            color(3, 4, .1f * (oblique[k].face + 1), .2f, .3f, 1);
        }
    NV2AMetalPixelUniforms u = uniforms();
    quad(v);
    texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
    texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
    texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
    texture_mode(&u, 3, PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST);
    show_texture(&u, 3);
    u.textures[3].cubemap = 1;
    u.eye_vector[0] = 1;
    coord(v, 0, 1, 0, 0, 1);
    coord(v, 1, 1, 0, 0, 1);
    coord(v, 2, 0, 0, 0, 1);
    coord(v, 3, 0, 0, 0, 1);
    for (unsigned key = 0; key < 4; key++) {
        u.textures[3].colorkey_mode = key;
        u.textures[3].color_key = 0xff1a334d;
        u.textures[3].color_key_mask = 0xffffffff;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        if (key == COLOR_KEY_DISCARD)
            clear(3, 4);
        else if (key == COLOR_KEY_KILL_COLOR_AND_ALPHA)
            color(3, 4, 0, 0, 0, 0);
        else
            color(3, 4, .1f, .2f, .3f, key == COLOR_KEY_KILL_ALPHA ? 0 : 1);
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                        size:1
                                   mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    __attribute__((objc_precise_lifetime)) id<MTLTexture> transparent =
        [commands.device newTextureWithDescriptor:td];
    assert(transparent);
    for (unsigned face = 0; face < 6; face++) {
        float pixel[] = { .1f, .2f, .3f, 0 };
        [transparent replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                       mipmapLevel:0
                             slice:face
                         withBytes:pixel
                       bytesPerRow:16
                     bytesPerImage:16];
    }
    textures[3].texture = transparent;
    u.textures[3].colorkey_mode = 0;
    for (unsigned kill = 0; kill < 2; kill++) {
        u.textures[3].alphakill = kill;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        if (kill)
            clear(3, 4);
        else
            color(3, 4, .1f, .2f, .3f, 0);
    }
    u = uniforms();
    NSError *error = nil;
    texture_mode(&u, 3, PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST);
    assert(!nv2a_metal_pixel_validate(&u, &error));
    texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
    texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
    assert(nv2a_metal_pixel_validate(&u, &error));
    u.legacy_spec_const = 2;
    assert(!nv2a_metal_pixel_validate(&u, &error));
}

static void depth_replace_tests(void)
{
    // Independent expected depths: the preceding dot supplies Z, the current
    // dot supplies W. The fragment's incoming depth and polygon offset lose
    // their effect, including when their depth would normally be rejected.
    const struct {
        float z, w;
        BOOL accepted;
        float expected;
    } cases[] = {
        { .25f, 1, YES, .25f }, { 1, 2, YES, .5f }, { 1.5f, 2, YES, .75f },
        { 0, 2, NO, 0 },        { 1, 1, NO, 0 },    { -1, 2, NO, 0 },
        { 2, 1, NO, 0 },        { .5f, 0, NO, 0 },
    };
    NV2AMetalPixelTexture textures[4] = { 0 };
    for (unsigned stage = 2; stage <= 3; stage++)
        for (unsigned format = 0; format < 4; format++)
            for (unsigned clipping = 0; clipping < 2; clipping++)
                for (unsigned k = 0; k < sizeof(cases) / sizeof(cases[0]);
                     k++) {
                    NV2AMetalPixelUniforms u = uniforms();
                    NV2AMetalVertex v[6];
                    quad(v);
                    u.depth_format = format;
                    u.clip_range[1] =
                        format == NV2AMetalPixelDepthD16 ? 65535 :
                        format == NV2AMetalPixelDepthD24 ? 16777215 :
                                                           256;
                    u.clip_range[2] = .25f * u.clip_range[1];
                    u.clip_range[3] = .75f * u.clip_range[1];
                    u.depth_clipping = clipping;
                    u.depth_offset = -100;
                    u.depth_factor = 25;
                    texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
                    texture_mode(&u, stage - 1, PS_TEXTUREMODES_DOTPRODUCT);
                    texture_mode(&u, stage, PS_TEXTUREMODES_DOT_ZW);
                    coord(v, 0, 1, 0, 0, 1);
                    coord(v, stage - 1, cases[k].z, 0, 0, 1);
                    coord(v, stage, cases[k].w, 0, 0, 1);
                    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                    for (unsigned y = 0; y < 8; y++)
                        for (unsigned x = 0; x < 8; x++) {
                            if (!cases[k].accepted) {
                                clear(x, y);
                                check_depth(depth_at(x, y), draw_clear_depth);
                            } else {
                                color(x, y, .1f, .2f, .3f, .4f);
                                float tolerance =
                                    format == NV2AMetalPixelDepthD16 ?
                                        1.0f / 65535 :
                                    format == NV2AMetalPixelDepthD24 ?
                                        1.0f / 16777215 :
                                        0.0000001f;
                                float expected = cases[k].expected;
                                if (format == NV2AMetalPixelDepthF16)
                                    expected = f16_depth_code(expected *
                                                              u.clip_range[1]) /
                                               65535.0f;
                                if (format == NV2AMetalPixelDepthF24)
                                    expected = f24_depth_code(expected *
                                                              u.clip_range[1]) /
                                               16777215.f;
                                assert(fabsf(depth_at(x, y) - expected) <=
                                       tolerance);
                            }
                        }
                }
    NSError *error = nil;
    NV2AMetalPixelUniforms u = uniforms();
    texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ZW);
    assert(!nv2a_metal_pixel_validate(&u, &error));
    texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
    assert(nv2a_metal_pixel_validate(&u, &error));
    texture_mode(&u, 3, PS_TEXTUREMODES_DOT_ZW);
    assert(!nv2a_metal_pixel_validate(&u, &error));
    for (unsigned stage = 2; stage <= 3; stage++) {
        NV2AMetalVertex v[6];
        quad(v);
        u = uniforms();
        u.depth_format = NV2AMetalPixelDepthF24;
        texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
        texture_mode(&u, stage - 1, PS_TEXTUREMODES_DOTPRODUCT);
        texture_mode(&u, stage, PS_TEXTUREMODES_DOT_ZW);
        coord(v, 0, 1, 0, 0, 1);
        coord(v, stage - 1, 1, 0, 0, 1);
        coord(v, stage, 0, 0, 0, 1);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        check_depth(depth_at(3, 4),
                    f24_depth_code(u.clip_range[1]) / 16777215.f);
        // The replacement is interpolated per fragment, not per vertex.
        coord(v, stage, 1, 0, 0, 1);
        for (unsigned i = 0; i < 6; i++)
            v[i].texcoord[stage - 1][0] = (v[i].clip[0] + 1) * .5f;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                color(x, y, .1f, .2f, .3f, .4f);
                check_depth(depth_at(x, y),
                            f24_depth_code(((x + .5f) / 8) * u.clip_range[1]) /
                                16777215.f);
            }
    }
}

static void snapshots_test(void)
{
    NSError *error = nil;
    NV2AMetalVertex v[6];
    quad(v);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 0);
    require([commands beginWithError:&error] != nil, error);
    __weak id<MTLTexture> borrowed;
    for (unsigned draw = 0; draw < 2; draw++) {
        @autoreleasepool {
            id<MTLTexture> source = solid(draw ? .7f : .1f, .2f, .3f, .4f);
            if (!draw) {
                borrowed = source;
            }
            textures[0].texture = source;
            u.clip_regions[0][0] = draw ? 4 : 0;
            u.clip_regions[0][2] = draw ? 8 : 4;
            MTL4RenderPassDescriptor *p = pass();
            if (draw) {
                p.colorAttachments[0].loadAction = MTLLoadActionLoad;
                p.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            require([shader encodeVertices:input
                                     count:6
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:textures
                                      pass:p
                              depthStencil:depth_state
                                  commands:commands
                                     error:&error],
                    error);
        }
    }
    assert(borrowed);
    memset(&u, 0, sizeof(u));
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    assert(!borrowed);
    [target getBytes:pixels
         bytesPerRow:sizeof(pixels[0])
          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
         mipmapLevel:0];
    draws += 2;
    for (unsigned y = 0; y < 8; y++) {
        for (unsigned x = 0; x < 8; x++) {
            color(x, y, x < 4 ? .1f : .7f, .2f, .3f, .4f);
        }
    }
}

static void multisample_test(void)
{
    NSError *error = nil;
    assert([commands.device supportsTextureSampleCount:4]);
    NV2AMetalPixelShader *ms_shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatBGRA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:4
                                               error:&error];
    require(ms_shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:8
                                    height:8
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> resolved = [commands.device newTextureWithDescriptor:td];
    td.textureType = MTLTextureType2DMultisample;
    td.sampleCount = 4;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> multisample = [commands.device newTextureWithDescriptor:td];
    assert(resolved && multisample);
    NV2AMetalVertex v[6];
    quad(v);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = multisample;
    p.colorAttachments[0].resolveTexture = resolved;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    require([commands beginWithError:&error] != nil, error);
    require([ms_shader encodeVertices:input
                                count:6
                            primitive:MTLPrimitiveTypeTriangle
                             uniforms:&u
                             textures:textures
                                 pass:p
                         depthStencil:nil
                             commands:commands
                                error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    unsigned char bytes[8][8][4];
    [resolved getBytes:bytes
           bytesPerRow:sizeof(bytes[0])
            fromRegion:MTLRegionMake2D(0, 0, 8, 8)
           mipmapLevel:0];
    for (unsigned y = 0; y < 8; y++) {
        for (unsigned x = 0; x < 8; x++) {
            assert(abs(bytes[y][x][0] - 77) <= 1);
            assert(abs(bytes[y][x][1] - 51) <= 1);
            assert(abs(bytes[y][x][2] - 26) <= 1);
            assert(bytes[y][x][3] == 102);
        }
    }
    draws++;

    NV2AMetalDrawConfig config = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE },
        .blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8,
        .antialiasing = NV_PGRAPH_ANTIALIASING_ENABLE,
        .setup_raster = NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE |
                        NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE,
    };
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(state != nil, error);
    p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, .5f, 0);
    require([commands beginWithError:&error] != nil, error);
    require([ms_shader encodeVertices:input
                                count:6
                            primitive:MTLPrimitiveTypeTriangle
                             uniforms:&u
                             textures:textures
                                 pass:p
                            drawState:state
                             commands:commands
                                error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    [resolved getBytes:bytes
           bytesPerRow:sizeof(bytes[0])
            fromRegion:MTLRegionMake2D(0, 0, 8, 8)
           mipmapLevel:0];
    for (unsigned y = 0; y < 8; y++) {
        for (unsigned x = 0; x < 8; x++) {
            assert(abs(bytes[y][x][0] - 128) <= 1);
            assert(abs(bytes[y][x][1] - 20) <= 1);
            assert(abs(bytes[y][x][2] - 10) <= 1);
            assert(abs(bytes[y][x][3] - 41) <= 1);
        }
    }
    draws++;
}

/* Independent integer texel addressing oracle, including mirrored seams. */
static int reference_address(int i, int size, unsigned mode)
{
    switch (mode) {
    case NV_PGRAPH_TEXADDRESS0_ADDRU_WRAP:
        return (i % size + size) % size;
    case NV_PGRAPH_TEXADDRESS0_ADDRU_MIRROR: {
        int period = (i % (size * 2) + size * 2) % (size * 2);
        return period < size ? period : size * 2 - 1 - period;
    }
    case NV_PGRAPH_TEXADDRESS0_ADDRU_BORDER:
        return i;
    default:
        return i < 0 ? 0 : i >= size ? size - 1 : i;
    }
}

static void reference_gradient(float expected[4], float x, float y, unsigned u,
                               unsigned v, BOOL linear, const float border[4])
{
    float px = x * 2 - (linear ? .5f : 0);
    float py = y * 2 - (linear ? .5f : 0);
    int ix = (int)floorf(px), iy = (int)floorf(py);
    memset(expected, 0, 4 * sizeof(float));
    for (unsigned j = 0; j < (linear ? 2u : 1u); j++) {
        for (unsigned i = 0; i < (linear ? 2u : 1u); i++) {
            int tx = reference_address(ix + i, 2, u);
            int ty = reference_address(iy + j, 2, v);
            float weight = linear ? (i ? px - ix : 1 - (px - ix)) *
                                        (j ? py - iy : 1 - (py - iy)) :
                                    1;
            float texel[] = { (tx + .5f) / 2, (ty + .5f) / 2, .2f, .75f };
            const float *value =
                tx < 0 || tx >= 2 || ty < 0 || ty >= 2 ? border : texel;
            for (unsigned k = 0; k < 4; k++) {
                expected[k] += weight * value[k];
            }
        }
    }
}

static NV2AMetalTextureBinding *
sampler_binding(NV2AMetalTextureSampler *sampler, id<MTLTexture> texture,
                NV2AMetalSamplerConfig *config, NV2AMetalPixelUniforms *u,
                NV2AMetalPixelTexture textures[4])
{
    NSError *error = nil;
    NV2AMetalTextureBinding *binding = [sampler bindingForTexture:texture
                                                           config:config
                                                            error:&error];
    require(binding != nil, error);
    textures[0].texture = binding.texture;
    textures[0].sampler = binding.sampler;
    u->textures[0].sampling = binding.sampling;
    return binding;
}

static id<MTLTexture> sampler_mips_size(MTLTextureType type, unsigned width)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.pixelFormat = MTLPixelFormatRGBA32Float;
    td.textureType = type;
    td.width = td.height = width;
    td.depth = type == MTLTextureType3D ? width : 1;
    td.mipmapLevelCount = 4;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:td];
    assert(t);
    for (unsigned level = 0; level < 4; level++) {
        unsigned n = width >> level, depth = type == MTLTextureType3D ? n : 1;
        __attribute__((objc_precise_lifetime)) NSMutableData *storage =
            [NSMutableData dataWithLength:16 * n * n * depth];
        float (*data)[4] = storage.mutableBytes;
        for (unsigned i = 0; i < n * n * depth; i++) {
            for (unsigned k = 0; k < 3; k++) {
                data[i][k] = level == 3 || k == level ? 1 : 0;
            }
            data[i][3] = 1;
        }
        for (unsigned face = 0; face < (type == MTLTextureTypeCube ? 6u : 1u);
             face++) {
            [t replaceRegion:MTLRegionMake3D(0, 0, 0, n, n, depth)
                  mipmapLevel:level
                        slice:face
                    withBytes:data
                  bytesPerRow:16 * n
                bytesPerImage:16 * n * n];
        }
    }
    return t;
}

static id<MTLTexture> sampler_mips(MTLTextureType type)
{
    return sampler_mips_size(type, 8);
}

static void sampling_slope(NV2AMetalVertex v[6], float center, float dx,
                           float dy)
{
    for (unsigned i = 0; i < 6; i++) {
        float x = (v[i].clip[0] + 1) * 4;
        float y = (1 - v[i].clip[1]) * 4;
        v[i].texcoord[0][0] = center + (x - 3.5f) * dx;
        v[i].texcoord[0][1] = .5f + (y - 4.5f) * dy;
    }
}

static void sampler_footprint_range_tests(NV2AMetalTextureSampler *sampler)
{
    const unsigned exponents[] = { 60, 64, 80, 112, 127, 128 };
    const unsigned ranges[][2] = { { 0, 3 }, { 1, 3 }, { 0, 2 } };
    const unsigned biases[] = { 4096, 0, 4095 };
    // Even the smallest footprint here exceeds the last mip after maximum
    // negative bias and eight anisotropic taps. All vertex inputs stay finite.
    unsigned cases = 0;
    for (unsigned volume = 0; volume < 2; volume++) {
        id<MTLTexture> texture = sampler_mips_size(
            volume ? MTLTextureType3D : MTLTextureType2D, 128);
        for (unsigned axis = 0; axis < 3; axis++) {
            for (unsigned e = 0; e < 6; e++) {
                for (unsigned range = 0; range < 3; range++) {
                    for (unsigned aniso = 1; aniso <= 8; aniso *= 2) {
                        for (unsigned linear = 0; linear < 2; linear++) {
                            for (unsigned bias = 0; bias < 3; bias++) {
                                NV2AMetalPixelUniforms u = uniforms();
                                u.textures[0].dimension = volume ? 3 : 2;
                                texture_mode(&u, 0,
                                             volume ?
                                                 PS_TEXTUREMODES_PROJECT3D :
                                                 PS_TEXTUREMODES_PROJECT2D);
                                show_texture(&u, 0);
                                NV2AMetalPixelTexture textures[4] = { 0 };
                                NV2AMetalSamplerConfig c = {
                                    .filter = (linear ? 6u : 3u) << 16 |
                                              1u << 24 | biases[bias],
                                    .address = 3 | 3 << 8 | 3 << 16,
                                    .min_level = ranges[range][0],
                                    .max_level = ranges[range][1],
                                    .anisotropy = aniso,
                                };
                                __attribute__((objc_precise_lifetime))
                                NV2AMetalTextureBinding *binding =
                                    sampler_binding(sampler, texture, &c, &u,
                                                    textures);
                                NV2AMetalVertex v[6];
                                quad(v);
                                float slope = exp2f((float)exponents[e] - 7);
                                sampling_slope(v, .5f, axis != 1 ? slope : 0,
                                               axis ? slope / 2 : 0);
                                if (volume && axis == 2) {
                                    for (unsigned i = 0; i < 6; i++) {
                                        v[i].texcoord[0][2] =
                                            v[i].texcoord[0][0];
                                        v[i].texcoord[0][0] = .5f;
                                    }
                                }
                                for (unsigned i = 0; i < 6; i++) {
                                    for (unsigned k = 0; k < 4; k++) {
                                        assert(isfinite(v[i].texcoord[0][k]));
                                    }
                                }
                                render(&u, v, 6, MTLPrimitiveTypeTriangle,
                                       textures);
                                unsigned level = ranges[range][1];
                                for (unsigned y = 0; y < 8; y++) {
                                    for (unsigned x = 0; x < 8; x++) {
                                        color(x, y, level == 0 || level == 3,
                                              level == 1 || level == 3,
                                              level == 2 || level == 3, 1);
                                    }
                                }
                                cases++;
                            }
                        }
                    }
                }
            }
        }
    }
    assert(cases == 2592);
    printf("Metal4 sampler footprints: %u finite extreme-gradient draws, "
           "%u pixel comparisons PASS\n",
           cases, cases * 64);
}

static void native_sampler_tests(void)
{
    NSError *error = nil;
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    sampler_footprint_range_tests(sampler);
    for (unsigned raw = 0; raw < 8192; raw++) {
        int signed_value = raw < 4096 ? (int)raw : (int)raw - 8192;
        assert(nv2a_metal_texture_lod_bias(raw | 0xffe00000) ==
               signed_value / 256.0f);
    }
    NV2AMetalVertex v[6];
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalSamplerConfig c = {
        .filter = (1u << 16) | (1u << 24),
        .address = 3 | (3 << 8) | (3 << 16),
        .anisotropy = 1,
        .border_color = 0x66334c99,
    };
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 0);
    id<MTLTexture> texture = gradient(2);
    const float positions[][2] = {
        { .5f, .5f },       { 0, 0 },          { 1, 1 },
        { -.125f, 1.125f }, { -2.25f, 2.25f }, { .25f, .75f },
        { .999f, -.001f },
    };
    /* Every pair of address modes, both within-level filters, independent
     * expected weights and arbitrary ARGB border alpha. */
    for (unsigned au = 1; au <= 5; au++) {
        for (unsigned av = 1; av <= 5; av++) {
            c.address = au | av << 8;
            for (unsigned linear = 0; linear < 2; linear++) {
                c.filter = (1u << 16) | ((linear + 1) << 24);
                NV2AMetalTextureBinding *binding =
                    sampler_binding(sampler, texture, &c, &u, textures);
                for (unsigned p = 0; p < sizeof(positions) / sizeof(*positions);
                     p++) {
                    quad(v);
                    coord(v, 0, positions[p][0], positions[p][1], 0, 1);
                    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                    float expected[4];
                    NV2AMetalSamplingUniforms sampling = binding.sampling;
                    reference_gradient(expected, positions[p][0],
                                       positions[p][1], au, av, linear,
                                       sampling.border_color);
                    color(3, 4, expected[0], expected[1], expected[2],
                          expected[3]);
                }
                assert(binding.texture == texture);
            }
        }
    }
    c.address = 4 | (4 << 8);
    c.bordered = YES;
    __attribute__((objc_precise_lifetime)) NV2AMetalTextureBinding *binding =
        sampler_binding(sampler, texture, &c, &u, textures);
    quad(v);
    coord(v, 0, -10, 10, 0, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, 0, 0, 0, 0);
    c.bordered = NO;
    c.address = 1 | (2 << 8);
    binding = sampler_binding(sampler, texture, &c, &u, textures);
    coord(v, 0, 1e20f, -1e20f, 0, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, .5f, .25f, .2f, .75f);

    c.address = 3 | (3 << 8);
    for (unsigned min = 1; min <= 7; min++) {
        c.filter = min << 16 | 1 << 24;
        binding = sampler_binding(sampler, texture, &c, &u, textures);
        quad(v);
        sampling_slope(v, .5f, 1, 0);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        BOOL linear = min == 2 || min == 4 || min == 6 || min == 7;
        color(3, 4, linear ? .5f : .75f, linear ? .5f : .75f, .2f, .75f);
    }

    /* Constant mip colors let LOD/filter selection be checked independently
     * of within-level filtering. A view changes the base dimensions/LOD. */
    id<MTLTexture> mips = sampler_mips(MTLTextureType2D);
    c.address = 3 | (3 << 8);
    const float lods[] = { -1, -.1f, .1f, .49f, .5f, .51f, 1.25f, 5 };
    for (unsigned base = 0; base < 3; base++) {
        c.min_level = base;
        c.max_level = 3;
        for (unsigned min = 1; min <= 7; min++) {
            for (unsigned mag = 1; mag <= 4; mag++) {
                if (mag == 3) {
                    continue;
                }
                c.filter = min << 16 | mag << 24;
                binding = sampler_binding(sampler, mips, &c, &u, textures);
                assert(binding.texture.mipmapLevelCount == 4 - base);
                assert(binding.texture.width == (8u >> base));
                for (unsigned l = 0; l < sizeof(lods) / sizeof(*lods); l++) {
                    quad(v);
                    sampling_slope(v, .5f, exp2f(lods[l]) / (8u >> base), 0);
                    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                    float level =
                        lods[l] > 0 && min >= 3 && min <= 6 ? lods[l] : 0;
                    level = fminf(level, 3 - base);
                    if (min == 3 || min == 4) {
                        level = fmaxf(0, ceilf(level + .5f) - 1);
                    }
                    unsigned a = base + (unsigned)floorf(level);
                    unsigned b = a < 3 ? a + 1 : 3;
                    float f = level - floorf(level), expected[3];
                    for (unsigned k = 0; k < 3; k++) {
                        float ca = a == k || a == 3;
                        float cb = b == k || b == 3;
                        expected[k] = ca * (1 - f) + cb * f;
                    }
                    color(3, 4, expected[0], expected[1], expected[2], 1);
                }
            }
        }
    }
    /* Bias below native sampler's S4.6 precision must still affect results. */
    c.min_level = 0;
    c.filter = (6 << 16) | (2 << 24) | 1;
    binding = sampler_binding(sampler, mips, &c, &u, textures);
    quad(v);
    sampling_slope(v, .5f, .125f, 0);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, 255.0f / 256, 1.0f / 256, 0, 1);
    c.filter = (6 << 16) | (2 << 24) | 8191;
    binding = sampler_binding(sampler, mips, &c, &u, textures);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, 1, 0, 0, 1);
    c.filter = (6 << 16) | (2 << 24);
    c.max_level = 0;
    c.rectangle = YES;
    binding = sampler_binding(sampler, mips, &c, &u, textures);
    assert(binding.sampling.mip_filter == 0);
    u.textures[0].rectangle = 1;
    coord(v, 0, 4, 4, 0, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, 1, 0, 0, 1);
    u.textures[0].rectangle = 0;
    c.rectangle = NO;

    /* Eight trilinear texels of a 2x2x2 volume and independent P border. */
    id<MTLTexture> vol = volume();
    c.filter = (2 << 16) | (2 << 24);
    c.address = 3 | (3 << 8) | (4 << 16);
    u.textures[0].dimension = 3;
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT3D);
    binding = sampler_binding(sampler, vol, &c, &u, textures);
    quad(v);
    coord(v, 0, .5f, .5f, .5f, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, .3f, .3f, .3f, 1);
    coord(v, 0, .5f, .5f, 0, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, (.3f + .2f) / 2, (.3f + 76.0f / 255) / 2, (.1f + .6f) / 2,
          (1 + .4f) / 2);
    for (unsigned au = 1; au <= 5; au++) {
        for (unsigned av = 1; av <= 5; av++) {
            for (unsigned ap = 1; ap <= 5; ap++) {
                c.address = au | av << 8 | ap << 16;
                binding = sampler_binding(sampler, vol, &c, &u, textures);
                coord(v, 0, -.25f, 1.25f, -.25f, 1);
                render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                if (au == 4 || av == 4 || ap == 4) {
                    color(3, 4, .2f, 76.0f / 255, .6f, .4f);
                } else {
                    color(3, 4, au == 1 ? .5f : .1f, av == 1 ? .1f : .5f,
                          ap == 1 ? .5f : .1f, 1);
                }
            }
        }
    }
    /* 3D and cube mip-range views and all six cube axes. */
    id<MTLTexture> vol_mips = sampler_mips(MTLTextureType3D);
    c.address = 3 | (3 << 8) | (3 << 16);
    c.min_level = c.max_level = 2;
    binding = sampler_binding(sampler, vol_mips, &c, &u, textures);
    coord(v, 0, .5f, .5f, .5f, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, 0, 0, 1, 1);
    id<MTLTexture> cubemap = cube();
    c.min_level = c.max_level = 0;
    u.textures[0].dimension = 2;
    u.textures[0].cubemap = 1;
    texture_mode(&u, 0, PS_TEXTUREMODES_CUBEMAP);
    binding = sampler_binding(sampler, cubemap, &c, &u, textures);
    for (unsigned face = 0; face < 6; face++) {
        float direction[3] = { 0 };
        direction[face / 2] = face & 1 ? -1 : 1;
        coord(v, 0, direction[0], direction[1], direction[2], 1);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        color(3, 4, .1f * (face + 1), .2f, .3f, 1);
    }
    id<MTLTexture> cube_mips = sampler_mips(MTLTextureTypeCube);
    c.min_level = c.max_level = 1;
    binding = sampler_binding(sampler, cube_mips, &c, &u, textures);
    coord(v, 0, 1, .2f, -.2f, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, 0, 1, 0, 1);
    /* Non-seamless cube border mixes this face with the configured border. */
    c.min_level = c.max_level = 0;
    c.address = 4 | (4 << 8);
    binding = sampler_binding(sampler, cubemap, &c, &u, textures);
    coord(v, 0, 1, 0, 1, 1);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, .15f, (.2f + 76.0f / 255) / 2, .45f, .7f);

    /* Face orientation, not just six distinct constant face colors. */
    MTLTextureDescriptor *cube_td = [MTLTextureDescriptor
        textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                        size:4
                                   mipmapped:NO];
    cube_td.storageMode = MTLStorageModeShared;
    cube_td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> oriented_cube =
        [commands.device newTextureWithDescriptor:cube_td];
    assert(oriented_cube);
    for (unsigned face = 0; face < 6; face++) {
        float data[4][4][4];
        for (unsigned y = 0; y < 4; y++) {
            for (unsigned x = 0; x < 4; x++) {
                data[y][x][0] = (x + .5f) / 4;
                data[y][x][1] = (y + .5f) / 4;
                data[y][x][2] = face / 10.0f;
                data[y][x][3] = 1;
            }
        }
        [oriented_cube replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                         mipmapLevel:0
                               slice:face
                           withBytes:data
                         bytesPerRow:64
                       bytesPerImage:256];
    }
    const float directions[6][3] = { { 2, -1, -.5f }, { -2, -1, .5f },
                                     { .5f, 2, 1 },   { .5f, -2, -1 },
                                     { .5f, -1, 2 },  { -.5f, -1, -2 } };
    c.address = 3 | (3 << 8);
    for (unsigned linear = 0; linear < 2; linear++) {
        c.filter = (1 << 16) | (linear + 1) << 24;
        binding = sampler_binding(sampler, oriented_cube, &c, &u, textures);
        for (unsigned face = 0; face < 6; face++) {
            coord(v, 0, directions[face][0], directions[face][1],
                  directions[face][2], 1);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            color(3, 4, .625f, linear ? .75f : .875f, face / 10.0f, 1);
        }
    }
    c.filter = (6 << 16) | (2 << 24);
    c.max_level = 3;
    binding = sampler_binding(sampler, cube_mips, &c, &u, textures);
    for (unsigned face = 0; face < 6; face++) {
        quad(v);
        for (unsigned i = 0; i < 6; i++) {
            float screen_x = (v[i].clip[0] + 1) * 4;
            float d = (screen_x - 3.5f) * .5f;
            float direction[3] = { 0 };
            direction[face / 2] = face & 1 ? -1 : 1;
            direction[face / 2 == 0 ? 2 : 0] = d;
            memcpy(v[i].texcoord[0], direction, sizeof(direction));
        }
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        color(3, 4, 0, 1, 0, 1);
    }
    /* Cube LOD depends on direction, not on the vector's common scale.
     * Powers of two preserve the fixture exactly while exposing overflow and
     * underflow of a squared major-axis denominator. */
    unsigned scale_draws = 0;
    const int exponents[] = { 0, 70, -70, 100, -100 };
    const float cube_lods[] = { 0, 1, 1.25f, 2 };
    for (unsigned filter = 3; filter <= 6; filter++) {
        c.filter = (filter << 16) | (2 << 24);
        binding = sampler_binding(sampler, cube_mips, &c, &u, textures);
        for (unsigned face = 0; face < 6; face++) {
            for (unsigned l = 0; l < sizeof(cube_lods) / sizeof(*cube_lods);
                 l++) {
                float lod = cube_lods[l];
                float level = filter <= 4 ? ceilf(lod + .5f) - 1 : lod;
                unsigned low = (unsigned)floorf(level);
                unsigned high = low + 1;
                float fraction = level - low, expected[3];
                for (unsigned k = 0; k < 3; k++)
                    expected[k] = (low == k || low == 3) * (1 - fraction) +
                                  (high == k || high == 3) * fraction;
                for (unsigned e = 0; e < sizeof(exponents) / sizeof(*exponents);
                     e++) {
                    for (unsigned slope = 0; slope < 3; slope++) {
                        for (unsigned screen_axis = 0; screen_axis < 2;
                             screen_axis++) {
                            float scale = ldexpf(1, exponents[e]);
                            quad(v);
                            for (unsigned i = 0; i < 6; i++) {
                                float offset =
                                    screen_axis == 0 ?
                                        (v[i].clip[0] + 1) * 4 - 3.5f :
                                        (1 - v[i].clip[1]) * 4 - 4.5f;
                                float major =
                                    1 + offset * (slope == 1 ? .125f :
                                                  slope == 2 ? -.125f :
                                                               0);
                                float direction[3] = { 0 };
                                direction[face / 2] =
                                    (face & 1 ? -scale : scale) * major;
                                direction[face / 2 == 0 ? 2 : 0] =
                                    (.25f * major + offset * exp2f(lod) / 4) *
                                    scale;
                                memcpy(v[i].texcoord[0], direction,
                                       sizeof(direction));
                            }
                            render(&u, v, 6, MTLPrimitiveTypeTriangle,
                                   textures);
                            for (unsigned k = 0; k < 3; k++) {
                                if (!isfinite(pixels[4][3][k]) ||
                                    fabsf(pixels[4][3][k] - expected[k]) >
                                        .000015f)
                                    fprintf(stderr,
                                            "Cube scale: filter=%u face=%u "
                                            "lod=%g exponent=%d slope=%u "
                                            "axis=%u channel=%u\n",
                                            filter, face, lod, exponents[e],
                                            slope, screen_axis, k);
                            }
                            color(3, 4, expected[0], expected[1], expected[2],
                                  1);
                            scale_draws++;
                        }
                    }
                }
            }
        }
    }
    assert(scale_draws == 2880);
    printf("Metal4 cube derivatives: %u scaled direction/mip draws PASS\n",
           scale_draws);
    u.textures[0].cubemap = 0;
    u.textures[0].dimension = 3;
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT3D);
    c.address = 3 | (3 << 8) | (3 << 16);
    binding = sampler_binding(sampler, vol_mips, &c, &u, textures);
    quad(v);
    sampling_slope(v, .5f, exp2f(1.25f) / 8, 0);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    color(3, 4, 0, .75f, .25f, 1);
    u.textures[0].dimension = 2;
    u.textures[0].cubemap = 1;
    texture_mode(&u, 0, PS_TEXTUREMODES_CUBEMAP);
    c.max_level = 0;

    /* A four-texel footprint over alternating stripes averages to one half.
     * This tests actual anisotropic taps, rather than only the host flags. */
    id<MTLTexture> stripes = gradient(8);
    float stripe_data[8][8][4];
    for (unsigned y = 0; y < 8; y++) {
        for (unsigned x = 0; x < 8; x++) {
            stripe_data[y][x][0] = x & 1;
            stripe_data[y][x][1] = stripe_data[y][x][2] = 0;
            stripe_data[y][x][3] = 1;
        }
    }
    [stripes replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
               mipmapLevel:0
                 withBytes:stripe_data
               bytesPerRow:128];
    u.textures[0].cubemap = 0;
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    c.address = 1 | (1 << 8);
    c.filter = (1 << 16) | (1 << 24);
    for (unsigned aniso = 1; aniso <= 8; aniso *= 2) {
        c.anisotropy = aniso;
        binding = sampler_binding(sampler, stripes, &c, &u, textures);
        quad(v);
        sampling_slope(v, .5f, .5f, .125f);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        color(3, 4, aniso == 1 ? 0 : .5f, 0, 0, 1);
    }
    /* Invalid register fields fail before encoding. */
    const unsigned invalid_filters[] = { 0, 8 << 16 | 1 << 24, 1 << 16,
                                         1 << 16 | 3 << 24 };
    for (unsigned i = 0; i < sizeof(invalid_filters) / sizeof(*invalid_filters);
         i++) {
        c.filter = invalid_filters[i];
        assert(![sampler bindingForTexture:texture config:&c error:&error]);
    }
    c.filter = 1 << 16 | 1 << 24;
    c.address = 0;
    assert(![sampler bindingForTexture:texture config:&c error:&error]);
    c.address = 3 | 6 << 8;
    assert(![sampler bindingForTexture:texture config:&c error:&error]);
    c.address = 3 | 3 << 8;
    c.anisotropy = 3;
    assert(![sampler bindingForTexture:texture config:&c error:&error]);
    c.anisotropy = 1;
    c.max_level = 1;
    assert(![sampler bindingForTexture:texture config:&c error:&error]);
    c.min_level = 2;
    assert(![sampler bindingForTexture:mips config:&c error:&error]);
    c.min_level = 0;
    c.rectangle = YES;
    assert(![sampler bindingForTexture:mips config:&c error:&error]);
    c.rectangle = NO;
    c.max_level = 0;
    assert(![sampler bindingForTexture:texture config:NULL error:&error]);
    c.min_level = c.max_level = 0;
    MTLTextureDescriptor *invalid_td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint
                                     width:2
                                    height:2
                                 mipmapped:NO];
    invalid_td.storageMode = MTLStorageModeShared;
    invalid_td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> integer_texture =
        [commands.device newTextureWithDescriptor:invalid_td];
    assert(integer_texture);
    assert(![sampler bindingForTexture:integer_texture config:&c error:&error]);
    invalid_td.pixelFormat = MTLPixelFormatRGBA32Float;
    invalid_td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> unreadable =
        [commands.device newTextureWithDescriptor:invalid_td];
    assert(unreadable);
    assert(![sampler bindingForTexture:unreadable config:&c error:&error]);
    invalid_td.usage = MTLTextureUsageShaderRead;
    invalid_td.mipmapLevelCount = 2;
    id<MTLTexture> unviewable =
        [commands.device newTextureWithDescriptor:invalid_td];
    assert(unviewable);
    assert(![sampler bindingForTexture:unviewable config:&c error:&error]);
    c.address = 3 | (3 << 8) | (6 << 16);
    assert(![sampler bindingForTexture:vol config:&c error:&error]);
    c.address = 3 | (3 << 8);
    /* Multi-draw slots keep views alive after the result is released. */
    c.min_level = c.max_level = 1;
    u.textures[0].sampling = (NV2AMetalSamplingUniforms){ 0 };
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    require([commands beginWithError:&error] != nil, error);
    __weak id<MTLTexture> borrowed_view;
    @autoreleasepool {
        NV2AMetalTextureBinding *temporary =
            sampler_binding(sampler, mips, &c, &u, textures);
        require([shader encodeVertices:vertices
                                 count:6
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:textures
                                  pass:pass()
                          depthStencil:depth_state
                              commands:commands
                                 error:&error],
                error);
        assert(temporary.texture.parentTexture == mips);
        borrowed_view = temporary.texture;
    }
    assert(borrowed_view);
    textures[0] = (NV2AMetalPixelTexture){ 0 };
    read_depth();
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    [target getBytes:pixels
         bytesPerRow:sizeof(pixels[0])
          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
         mipmapLevel:0];
    draws++;
    color(3, 4, 0, 1, 0, 1);
    assert(!borrowed_view);
}

static NV2AMetalDrawConfig draw_config(void)
{
    NV2AMetalDrawConfig c = { 0 };
    c.control[0] = NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE;
    c.blend_color = 0x66334c99;
    return c;
}

static void set_draw_state(const NV2AMetalDrawConfig *c)
{
    NSError *error = nil;
    draw_state = [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                     config:c
                                                      error:&error];
    require(draw_state != nil, error);
}

static float blend_factor(unsigned factor, unsigned channel,
                          const float source[4], const float destination[4],
                          const float constant[4])
{
    switch (factor) {
    case 0:
        return 0;
    case 1:
        return 1;
    case 2:
        return source[channel];
    case 3:
        return 1 - source[channel];
    case 4:
        return source[3];
    case 5:
        return 1 - source[3];
    case 6:
        return destination[3];
    case 7:
        return 1 - destination[3];
    case 8:
        return destination[channel];
    case 9:
        return 1 - destination[channel];
    case 10:
        return channel == 3 ? 1 : fminf(source[3], 1 - destination[3]);
    case 12:
        return constant[channel];
    case 13:
        return 1 - constant[channel];
    case 14:
        return constant[3];
    case 15:
        return 1 - constant[3];
    default:
        abort();
    }
}

static float blend_value(unsigned equation, unsigned sf, unsigned df,
                         unsigned channel, const float source[4],
                         const float destination[4], const float constant[4])
{
    float a = source[channel], b = destination[channel];
    if (equation == 3) {
        return fminf(a, b);
    }
    if (equation == 4) {
        return fmaxf(a, b);
    }
    a *= blend_factor(sf, channel, source, destination, constant);
    b *= blend_factor(df, channel, source, destination, constant);
    return equation == 0                  ? a - b :
           equation == 1 || equation == 5 ? b - a :
                                            a + b;
}

static BOOL reference_compare(float a, float b, unsigned op)
{
    switch (op) {
    case 0:
        return NO;
    case 1:
        return a < b;
    case 2:
        return a == b;
    case 3:
        return a <= b;
    case 4:
        return a > b;
    case 5:
        return a != b;
    case 6:
        return a >= b;
    case 7:
        return YES;
    default:
        abort();
    }
}

static void native_depth_replace_tests(void)
{
    NV2AMetalVertex v[6];
    quad(v);
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
    texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
    texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ZW);
    coord(v, 0, 1, 0, 0, 1);
    coord(v, 1, 1, 0, 0, 1);
    coord(v, 2, 2, 0, 0, 1);
    const float replacement = 32767.0f / 65535;
    const float initial[] = { 0, 32767.0f / 65535, 1 };
    for (unsigned comparison = 0; comparison < 8; comparison++)
        for (unsigned d = 0; d < 3; d++)
            for (unsigned write = 0; write < 2; write++) {
                NV2AMetalDrawConfig c = draw_config();
                c.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE | comparison << 16 |
                                (write ? NV_PGRAPH_CONTROL_0_ZWRITEENABLE : 0);
                set_draw_state(&c);
                draw_clear_depth = initial[d];
                render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                BOOL passed =
                    reference_compare(replacement, initial[d], comparison);
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        if (passed)
                            color(x, y, .1f, .2f, .3f, .4f);
                        else
                            clear(x, y);
                        check_depth(depth_at(x, y),
                                    passed && write ? replacement : initial[d]);
                    }
            }
    draw_state = nil;
    draw_clear_depth = .99f;
}

static void native_draw_tests(void)
{
    NV2AMetalVertex v[6];
    quad(v);
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalDrawConfig c = draw_config();
    const float source[] = { .1f, .2f, .3f, .4f };
    const float constant[] = { .2f, 76.0f / 255, .6f, .4f };
    for (unsigned sf = 0; sf < 16; sf++) {
        if (sf == 11) {
            continue;
        }
        for (unsigned df = 0; df < 16; df++) {
            if (df == 11) {
                continue;
            }
            for (unsigned eq = 0; eq < 7; eq++) {
                c.blend = NV_PGRAPH_BLEND_EN | eq | sf << 4 | df << 8;
                set_draw_state(&c);
                render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                for (unsigned k = 0; k < 4; k++) {
                    check(pixels[4][3][k], blend_value(eq, sf, df, k, source,
                                                       clear_color, constant));
                }
                check_depth(depth_at(3, 4), .99f);
            }
        }
    }
    for (unsigned mask = 0; mask < 16; mask++) {
        c = draw_config();
        c.control[0] = mask << 26;
        set_draw_state(&c);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        unsigned bits[] = { 2, 4, 8, 1 };
        for (unsigned k = 0; k < 4; k++) {
            check(pixels[4][3][k], mask & bits[k] ? source[k] : clear_color[k]);
        }
    }
    c = draw_config();
    c.control[0] |= NV_PGRAPH_CONTROL_0_ZWRITEENABLE;
    set_draw_state(&c);
    render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
    check_depth(depth_at(3, 4), .99f);
    float fragment_depth = 2.0f / 65535;
    const float depths[] = { 0, 2.0f / 65535, 1 };
    for (unsigned compare = 0; compare < 8; compare++) {
        for (unsigned d = 0; d < 3; d++) {
            c = draw_config();
            c.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                            NV_PGRAPH_CONTROL_0_ZWRITEENABLE | compare << 16;
            draw_clear_depth = depths[d];
            set_draw_state(&c);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            BOOL passed = reference_compare(fragment_depth, depths[d], compare);
            for (unsigned k = 0; k < 4; k++) {
                check(pixels[4][3][k], passed ? source[k] : clear_color[k]);
            }
            check_depth(depth_at(3, 4), passed ? fragment_depth : depths[d]);
            c.control[0] &= ~NV_PGRAPH_CONTROL_0_ZWRITEENABLE;
            set_draw_state(&c);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            check_depth(depth_at(3, 4), depths[d]);
        }
    }
    draw_clear_depth = .99f;
    const MTLScissorRect scissors[] = { { 2, 3, 3, 2 },
                                        { 6, 7, NSUIntegerMax, NSUIntegerMax },
                                        { 2, 3, 0, 2 },
                                        { NSUIntegerMax, 1, 2, 2 } };
    for (unsigned n = 0; n < 4; n++) {
        c = draw_config();
        c.scissor_enabled = YES;
        c.scissor = scissors[n];
        set_draw_state(&c);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        for (unsigned y = 0; y < 8; y++) {
            for (unsigned x = 0; x < 8; x++) {
                BOOL covered = n == 0 ? x >= 2 && x < 5 && y >= 3 && y < 5 :
                               n == 1 ? x >= 6 && y >= 7 :
                                        NO;
                for (unsigned k = 0; k < 4; k++) {
                    check(pixels[y][x][k],
                          covered ? source[k] : clear_color[k]);
                }
            }
        }
    }
    for (unsigned front = 0; front < 2; front++) {
        for (unsigned cull = 1; cull <= 3; cull++) {
            c = draw_config();
            c.setup_raster = NV_PGRAPH_SETUPRASTER_CULLENABLE | cull << 21 |
                             (front ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0);
            set_draw_state(&c);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            BOOL covered = cull == 1 ? front : cull == 2 ? !front : NO;
            for (unsigned k = 0; k < 4; k++) {
                check(pixels[4][3][k], covered ? source[k] : clear_color[k]);
            }
        }
    }
    c = draw_config();
    c.setup_raster = NV_PGRAPH_SETUPRASTER_CULLENABLE | 3 << 21;
    set_draw_state(&c);
    render(&u, v, 6, MTLPrimitiveTypePoint, textures);
    color(0, 0, .1f, .2f, .3f, .4f);
    v[0].clip[1] = v[1].clip[1] = .875f;
    render(&u, v, 2, MTLPrimitiveTypeLine, textures);
    color(3, 0, .1f, .2f, .3f, .4f);

    /* Keys use effective static state, not blend constants or references. */
    c = draw_config();
    c.blend = NV_PGRAPH_BLEND_EN | 3 | 2 << 4 | 3 << 8;
    set_draw_state(&c);
    NSUInteger key = draw_state.pipelineKey;
    c.blend = NV_PGRAPH_BLEND_EN | 3 | 5 << 4 | 7 << 8;
    c.blend_color = 0;
    set_draw_state(&c);
    assert(key == draw_state.pipelineKey);
    MTL4RenderPipelineColorAttachmentDescriptor *attachment =
        [draw_state colorAttachment];
    attachment.writeMask = MTLColorWriteMaskNone;
    assert([draw_state colorAttachment].writeMask == MTLColorWriteMaskAll);
    c.blend = NV_PGRAPH_BLEND_EN | 2 | 1 << 4;
    set_draw_state(&c);
    key = draw_state.pipelineKey;
    c.blend = NV_PGRAPH_BLEND_EN | 6 | 1 << 4;
    set_draw_state(&c);
    assert(key == draw_state.pipelineKey);
    draw_state = nil;
}

static unsigned reference_stencil(unsigned op, unsigned stored, unsigned ref)
{
    switch (op) {
    case 1:
        return stored;
    case 2:
        return 0;
    case 3:
        return ref;
    case 4:
        return stored == 255 ? 255 : stored + 1;
    case 5:
        return stored == 0 ? 0 : stored - 1;
    case 6:
        return stored ^ 255;
    case 7:
        return (stored + 1) & 255;
    case 8:
        return (stored - 1) & 255;
    default:
        abort();
    }
}

static void native_stencil_tests(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *saved_shader = shader;
    id<MTLTexture> saved_depth = depth;
    shader = [[NV2AMetalPixelShader alloc]
        initWithDevice:commands.device
           colorFormat:MTLPixelFormatRGBA32Float
           depthFormat:MTLPixelFormatDepth32Float_Stencil8
           sampleCount:1
                 error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                     width:8
                                    height:8
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    depth = [commands.device newTextureWithDescriptor:td];
    stencil_readback =
        [commands.device newBufferWithLength:8 * 256
                                     options:MTLResourceStorageModeShared];
    assert(depth && stencil_readback);
    NV2AMetalVertex v[6];
    quad(v);
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    const unsigned stored_values[] = { 0, 1, 128, 255 };
    for (unsigned facing = 0; facing < 2; facing++) {
        for (unsigned branch = 0; branch < 3; branch++) {
            for (unsigned op = 1; op <= 8; op++) {
                for (unsigned i = 0; i < 4; i++) {
                    for (unsigned partial = 0; partial < 2; partial++) {
                        NV2AMetalDrawConfig c = draw_config();
                        unsigned compare = branch == 0 ? 0 : 7;
                        c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                       compare << 4 | 0x5a << 8 | 255 << 16 |
                                       (partial ? 15u : 255u) << 24;
                        c.setup_raster =
                            facing ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0;
                        c.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                        NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                        (branch == 1 ? 0 : 7 << 16);
                        c.control[2] = branch == 0 ? op | 1 << 4 | 1 << 8 :
                                       branch == 1 ? 1 | op << 4 | 1 << 8 :
                                                     1 | 1 << 4 | op << 8;
                        draw_clear_stencil = stored_values[i];
                        set_draw_state(&c);
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
                        unsigned result =
                            reference_stencil(op, stored_values[i], 0x5a);
                        if (partial) {
                            result = (stored_values[i] & 0xf0) | (result & 15);
                        }
                        const unsigned char *bytes = stencil_readback.contents;
                        assert(bytes[4 * 256 + 3] == result);
                        if (branch < 2) {
                            clear(3, 4);
                        } else {
                            color(3, 4, .1f, .2f, .3f, .4f);
                        }
                        check_depth(depth_at(3, 4),
                                    branch == 2 ? 2.0f / 65535 : .99f);
                    }
                }
            }
        }
    }
    for (unsigned compare = 0; compare < 8; compare++) {
        for (unsigned i = 0; i < 3; i++) {
            NV2AMetalDrawConfig c = draw_config();
            c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                           compare << 4 | 0x35 << 8 | 15 << 16 | 255u << 24;
            c.control[2] = 1 | 1 << 4 | 1 << 8;
            const unsigned values[] = { 0x32, 0xa5, 0xf8 };
            draw_clear_stencil = values[i];
            set_draw_state(&c);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            BOOL passed = reference_compare(5, values[i] & 15, compare);
            if (passed) {
                color(3, 4, .1f, .2f, .3f, .4f);
            } else {
                clear(3, 4);
            }
            const unsigned char *bytes = stencil_readback.contents;
            assert(bytes[4 * 256 + 3] == values[i]);
        }
    }
    stencil_readback = nil;
    draw_clear_stencil = 0;
    draw_state = nil;
    shader = saved_shader;
    depth = saved_depth;
}

static void draw_cache_lifetime_test(void)
{
    NSError *error = nil;
    NV2AMetalVertex v[6];
    quad(v);
    for (unsigned i = 0; i < 6; i++) {
        memset(v[i].color[0], 0, sizeof(v[i].color[0]));
    }
    id<MTLBuffer> black =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    quad(v);
    id<MTLBuffer> final =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(black && final);
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    __weak NV2AMetalDrawState *borrowed;
    require([commands beginWithError:&error] != nil, error);
    for (unsigned n = 0; n < 301; n++) {
        @autoreleasepool {
            NV2AMetalDrawConfig c = draw_config();
            c.scissor_enabled = YES;
            c.scissor = (MTLScissorRect){ n % 8, n / 8 % 8, 1, 1 };
            if (n < 300) {
                unsigned sf = n % 225 / 15, df = n % 15;
                sf += sf >= 11;
                df += df >= 11;
                c.blend =
                    NV_PGRAPH_BLEND_EN | (n < 225 ? 2 : 0) | sf << 4 | df << 8;
            } else {
                c.scissor.x = 3;
                c.scissor.y = 4;
            }
            set_draw_state(&c);
            /* Mutating the caller config must not alter the capture. */
            c.scissor = (MTLScissorRect){ 0, 0, 0, 0 };
            MTL4RenderPassDescriptor *p = pass();
            p.colorAttachments[0].loadAction =
                n ? MTLLoadActionLoad : MTLLoadActionClear;
            p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            p.depthAttachment.loadAction =
                n ? MTLLoadActionLoad : MTLLoadActionClear;
            require([shader encodeVertices:n < 300 ? black : final
                                     count:6
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:textures
                                      pass:p
                                 drawState:draw_state
                                  commands:commands
                                     error:&error],
                    error);
            if (!n) {
                borrowed = draw_state;
            }
            draws++;
        }
    }
    draw_state = nil;
    assert(borrowed);
    read_depth();
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    [target getBytes:pixels
         bytesPerRow:sizeof(pixels[0])
          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
         mipmapLevel:0];
    for (unsigned y = 0; y < 8; y++) {
        for (unsigned x = 0; x < 8; x++) {
            if (x == 3 && y == 4) {
                color(x, y, .1f, .2f, .3f, .4f);
            } else {
                color(x, y, 0, 0, 0, 0);
            }
        }
    }
    assert(!borrowed);

    /* Same pipeline key with different dynamic colors, in one recording. */
    require([commands beginWithError:&error] != nil, error);
    const unsigned constants[] = { 0x66334c99, 0xcc996633 };
    for (unsigned n = 0; n < 2; n++) {
        NV2AMetalDrawConfig c = draw_config();
        c.blend = NV_PGRAPH_BLEND_EN | 2 | 12 << 4;
        c.blend_color = constants[n];
        c.scissor_enabled = YES;
        c.scissor = (MTLScissorRect){ 4 * n, 0, 4, 8 };
        set_draw_state(&c);
        MTL4RenderPassDescriptor *p = pass();
        p.colorAttachments[0].loadAction =
            n ? MTLLoadActionLoad : MTLLoadActionClear;
        p.depthAttachment.loadAction =
            n ? MTLLoadActionLoad : MTLLoadActionClear;
        require([shader encodeVertices:final
                                 count:6
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:textures
                                  pass:p
                             drawState:draw_state
                              commands:commands
                                 error:&error],
                error);
        draws++;
    }
    draw_state = nil;
    read_depth();
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    [target getBytes:pixels
         bytesPerRow:sizeof(pixels[0])
          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
         mipmapLevel:0];
    color(2, 4, .1f * .2f, .2f * 76 / 255, .3f * .6f, .4f * .4f);
    color(6, 4, .1f * .6f, .2f * .4f, .3f * .2f, .4f * .8f);
}

static void draw_state_rejection_tests(void)
{
    NSError *error = nil;
    for (unsigned test = 0; test < 12; test++) {
        NV2AMetalDrawConfig c = draw_config();
        switch (test) {
        case 0:
            c.blend = NV_PGRAPH_BLEND_EN | 7;
            break;
        case 1:
            c.blend = NV_PGRAPH_BLEND_EN | 11 << 4;
            break;
        case 2:
            c.blend = NV_PGRAPH_BLEND_EN | 11 << 8;
            break;
        case 3:
            c.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE | 8 << 16;
            break;
        case 4:
            c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 8 << 4;
            break;
        case 5:
            c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4;
            break;
        case 6:
            c.setup_raster = NV_PGRAPH_SETUPRASTER_CULLENABLE;
            break;
        case 7:
            c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4;
            c.control[2] = 9; /* Invalid stencil operation. */
            break;
        case 8:
            c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4;
            c.control[2] = 9 << 4;
            break;
        case 9:
            c.setup_raster = NV_PGRAPH_SETUPRASTER_FRONTFACEMODE;
            break;
        case 10:
            c.setup_raster = NV_PGRAPH_SETUPRASTER_BACKFACEMODE;
            break;
        case 11:
            c.control[1] =
                NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE; /* Invalid stencil
                                                            operations. */
            break;
        }
        assert(![[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                    config:&c
                                                     error:&error]);
        assert(error);
    }
    assert(![[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                config:NULL
                                                 error:&error]);
    /* Irrelevant invalid fields are ignored while their unit is disabled. */
    NV2AMetalDrawConfig c = draw_config();
    c.blend = 7 | 11 << 4 | 11 << 8;
    c.control[0] |= 15 << 16;
    c.control[1] = 15 << 4;
    c.control[2] = 0xfff;
    set_draw_state(&c);
    draw_state = nil;

    NV2AMetalVertex v[6];
    quad(v);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([commands beginWithError:&error] != nil, error);
    c = draw_config();
    c.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE;
    set_draw_state(&c);
    MTL4RenderPassDescriptor *p = pass();
    p.depthAttachment.texture = nil;
    assert(![shader encodeVertices:input
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:textures
                              pass:p
                         drawState:draw_state
                          commands:commands
                             error:&error]);
    c = draw_config();
    c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4;
    c.control[2] = 1 | 1 << 4 | 1 << 8;
    set_draw_state(&c);
    assert(![shader encodeVertices:input
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:textures
                              pass:pass()
                         drawState:draw_state
                          commands:commands
                             error:&error]);
    [commands cancel];
    draw_state = nil;
}

typedef struct AttachmentFormat {
    MTLPixelFormat format;
    unsigned bytes, shift[4], bits[4];
} AttachmentFormat;

/* Metal packed components run from least to most significant bit. These
 * layouts are independent of the renderer and match GL's surface transfers. */
static const AttachmentFormat attachment_formats[] = {
    { MTLPixelFormatR8Unorm, 1, { 0 }, { 8 } },
    { MTLPixelFormatRG8Unorm, 2, { 0, 8 }, { 8, 8 } },
    { MTLPixelFormatB5G6R5Unorm, 2, { 11, 5, 0 }, { 5, 6, 5 } },
    { MTLPixelFormatBGR5A1Unorm, 2, { 10, 5, 0, 15 }, { 5, 5, 5, 1 } },
};

static void attachment_decode(const AttachmentFormat *f, unsigned word,
                              float rgba[4])
{
    for (unsigned k = 0; k < 4; k++) {
        unsigned maximum = (1u << f->bits[k]) - 1;
        rgba[k] = maximum ? ((word >> f->shift[k]) & maximum) / (float)maximum :
                  k == 3  ? 1 :
                            0;
    }
}

static MTL4RenderPassDescriptor *attachment_pass(id<MTLTexture> color,
                                                 id<MTLTexture> resolve)
{
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = color;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction =
        resolve ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
    p.colorAttachments[0].resolveTexture = resolve;
    return p;
}

static void native_attachment_formats_test(void)
{
    NSError *error = nil;
    const unsigned size = 256, count = size * size;
    unsigned char *original = malloc(count * 2), *result = malloc(count * 2);
    float (*decoded)[4] = malloc(count * sizeof(*decoded));
    assert(original && result && decoded);
    NV2AMetalVertex v[6];
    quad(v);
    for (unsigned i = 0; i < 6; i++) {
        v[i].texcoord[0][0] = (v[i].clip[0] + 1) / 2;
        v[i].texcoord[0][1] = (1 - v[i].clip[1]) / 2;
    }
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    quad(v);
    for (unsigned i = 0; i < 6; i++) {
        const float color[] = { 1, 0, 1, 0 };
        memcpy(v[i].color[0], color, sizeof(color));
    }
    id<MTLBuffer> constant =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(vertices && constant);
    NV2AMetalPixelShader *float_shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(float_shader != nil, error);
    MTLTextureDescriptor *float_td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    float_td.storageMode = MTLStorageModeShared;
    float_td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> float_target =
        [commands.device newTextureWithDescriptor:float_td];
    assert(float_target);
    NV2AMetalTextureSampler *factory =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(factory != nil, error);
    for (unsigned fidx = 0; fidx < 4; fidx++) {
        @autoreleasepool {
            const AttachmentFormat *f = &attachment_formats[fidx];
            for (unsigned i = 0; i < count; i++) {
                original[f->bytes * i] = i & 255;
                if (f->bytes == 2) {
                    original[2 * i + 1] = i >> 8;
                }
            }
            MTLTextureDescriptor *td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:f->format
                                             width:size
                                            height:size
                                         mipmapped:NO];
            td.storageMode = MTLStorageModeShared;
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            id<MTLTexture> source =
                [commands.device newTextureWithDescriptor:td];
            id<MTLTexture> destination =
                [commands.device newTextureWithDescriptor:td];
            assert(source && destination);
            [source replaceRegion:MTLRegionMake2D(0, 0, size, size)
                      mipmapLevel:0
                        withBytes:original
                      bytesPerRow:size * f->bytes];
            NV2AMetalPixelShader *native_shader = [[NV2AMetalPixelShader alloc]
                initWithDevice:commands.device
                   colorFormat:f->format
                   depthFormat:MTLPixelFormatInvalid
                   sampleCount:1
                         error:&error];
            require(native_shader != nil, error);
            for (unsigned sampling = 0; sampling < 3; sampling++) {
                NV2AMetalPixelUniforms u = uniforms();
                u.clip_regions[0][2] = u.clip_regions[0][3] = size;
                texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                show_texture(&u, 0);
                NV2AMetalPixelTexture t[4] = { 0 };
                __attribute__((objc_precise_lifetime))
                NV2AMetalTextureBinding *source_binding = nil,
                                        *destination_binding = nil;
                if (sampling) {
                    NV2AMetalSamplerConfig c = {
                        .filter = (sampling == 2 ? 2u : 1u) << 16 |
                                  (sampling == 2 ? 2u : 1u) << 24,
                        .address = 3 | 3 << 8,
                        .anisotropy = 1,
                    };
                    source_binding = [factory bindingForTexture:source
                                                         config:&c
                                                          error:&error];
                    destination_binding = [factory bindingForTexture:destination
                                                              config:&c
                                                               error:&error];
                    require(source_binding != nil && destination_binding != nil,
                            error);
                    u.textures[0].sampling = source_binding.sampling;
                    t[0].sampler = source_binding.sampler;
                }
                t[0].texture = source;
                require([commands beginWithError:&error] != nil, error);
                require([native_shader
                            encodeVertices:vertices
                                     count:6
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:t
                                      pass:attachment_pass(destination, nil)
                              depthStencil:nil
                                  commands:commands
                                     error:&error],
                        error);
                t[0].texture = destination;
                if (sampling) {
                    u.textures[0].sampling = destination_binding.sampling;
                    t[0].sampler = destination_binding.sampler;
                }
                require([float_shader
                            encodeVertices:vertices
                                     count:6
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:t
                                      pass:attachment_pass(float_target, nil)
                              depthStencil:nil
                                  commands:commands
                                     error:&error],
                        error);
                require([commands submitWithError:&error], error);
                require([commands waitUntilIdleWithError:&error], error);
                draws += 2;
                [destination getBytes:result
                          bytesPerRow:size * f->bytes
                           fromRegion:MTLRegionMake2D(0, 0, size, size)
                          mipmapLevel:0];
                assert(!memcmp(original, result, count * f->bytes));
                [float_target getBytes:decoded
                           bytesPerRow:size * sizeof(*decoded)
                            fromRegion:MTLRegionMake2D(0, 0, size, size)
                           mipmapLevel:0];
                for (unsigned i = 0; i < count; i++) {
                    float expected[4];
                    attachment_decode(f, f->bytes == 1 ? i & 255 : i, expected);
                    for (unsigned k = 0; k < 4; k++) {
                        check(decoded[i][k], expected[k]);
                    }
                }
            }

            /* Channel masks and fixed blending on native 1x and 4x targets. */
            for (unsigned msaa = 0; msaa < 2; msaa++) {
                td.width = td.height = 8;
                td.textureType = MTLTextureType2D;
                td.sampleCount = 1;
                td.storageMode = MTLStorageModeShared;
                id<MTLTexture> resolved =
                    [commands.device newTextureWithDescriptor:td];
                if (msaa) {
                    td.textureType = MTLTextureType2DMultisample;
                    td.sampleCount = 4;
                    td.storageMode = MTLStorageModePrivate;
                    td.usage = MTLTextureUsageRenderTarget;
                }
                id<MTLTexture> color_target =
                    msaa ? [commands.device newTextureWithDescriptor:td] :
                           resolved;
                NV2AMetalPixelShader *draw_shader =
                    msaa ? [[NV2AMetalPixelShader alloc]
                               initWithDevice:commands.device
                                  colorFormat:f->format
                                  depthFormat:MTLPixelFormatInvalid
                                  sampleCount:4
                                        error:&error] :
                           native_shader;
                require(draw_shader != nil, error);
                assert(resolved && color_target);
                unsigned clear_word = f->bytes == 1 ? 0x9d : 0x569d;
                float clear_rgba[4];
                attachment_decode(f, clear_word, clear_rgba);
                for (unsigned blend = 0; blend < 2; blend++) {
                    for (unsigned mask = 0; mask < 16; mask++) {
                        NV2AMetalDrawConfig c = draw_config();
                        c.control[0] = mask << 26;
                        c.blend = blend ?
                                      NV_PGRAPH_BLEND_EN | 2 | 1 << 4 | 1 << 8 :
                                      0;
                        NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                            initWithDevice:commands.device
                                    config:&c
                                     error:&error];
                        require(state != nil, error);
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalPixelTexture t[4] = { 0 };
                        MTL4RenderPassDescriptor *p = attachment_pass(
                            color_target, msaa ? resolved : nil);
                        p.colorAttachments[0].clearColor =
                            MTLClearColorMake(clear_rgba[0], clear_rgba[1],
                                              clear_rgba[2], clear_rgba[3]);
                        require([commands beginWithError:&error] != nil, error);
                        require([draw_shader
                                    encodeVertices:constant
                                             count:6
                                         primitive:MTLPrimitiveTypeTriangle
                                          uniforms:&u
                                          textures:t
                                              pass:p
                                         drawState:state
                                          commands:commands
                                             error:&error],
                                error);
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error],
                                error);
                        draws++;
                        unsigned expected_word = clear_word;
                        const unsigned mask_bits[] = { 2, 4, 8, 1 };
                        for (unsigned k = 0; k < 4; k++) {
                            unsigned bits = ((1u << f->bits[k]) - 1)
                                            << f->shift[k];
                            if (mask & mask_bits[k]) {
                                unsigned replacement =
                                    k == 0 || k == 2 ? bits :
                                    blend            ? clear_word & bits :
                                                       0;
                                expected_word =
                                    (expected_word & ~bits) | replacement;
                            }
                        }
                        [resolved getBytes:result
                               bytesPerRow:8 * f->bytes
                                fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                               mipmapLevel:0];
                        for (unsigned i = 0; i < 64; i++) {
                            unsigned word = result[i * f->bytes];
                            if (f->bytes == 2) {
                                word |= (unsigned)result[i * 2 + 1] << 8;
                            }
                            assert(word == expected_word);
                        }
                    }
                }
            }
        }
    }
    free(original);
    free(result);
    free(decoded);
}

static void native_depth16_test(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *d16_shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatDepth16Unorm
                                         sampleCount:1
                                               error:&error];
    require(d16_shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:256
                                    height:256
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color_target = [commands.device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth16Unorm;
    id<MTLTexture> depth_target = [commands.device newTextureWithDescriptor:td];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:256 * 512
                                     options:MTLResourceStorageModeShared];
    assert(color_target && depth_target && readback);
    NV2AMetalVertex v[6];
    quad(v);
    const float plane[3][4] = {
        { 0, 0, -128.25f, 1 },
        { 256, 0, 127.75f, 1 },
        { 0, 256, 65407.75f, 1 },
    };
    for (unsigned i = 0; i < 6; i++) {
        memcpy(v[i].plane, plane, sizeof(plane));
    }
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(vertices);
    NV2AMetalPixelUniforms u = uniforms();
    u.clip_regions[0][2] = u.clip_regions[0][3] = 256;
    NV2AMetalPixelTexture t[4] = { 0 };
    NV2AMetalDrawConfig c = draw_config();
    c.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                    NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&c
                                             error:&error];
    require(state != nil, error);
    MTL4RenderPassDescriptor *p = attachment_pass(color_target, nil);
    p.depthAttachment.texture = depth_target;
    p.depthAttachment.loadAction = MTLLoadActionClear;
    p.depthAttachment.storeAction = MTLStoreActionStore;
    p.depthAttachment.clearDepth = 1;
    require([commands beginWithError:&error] != nil, error);
    require([d16_shader encodeVertices:vertices
                                 count:6
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:t
                                  pass:p
                             drawState:state
                              commands:commands
                                 error:&error],
            error);
    require([commands addResource:readback error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:depth_target
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(256, 256, 1)
                        toBuffer:readback
               destinationOffset:0
          destinationBytesPerRow:512
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    const uint16_t *values = readback.contents;
    for (unsigned i = 0; i < 65536; i++) {
        assert(values[i] == i);
    }
    draws++;
}

static double xo_blend_factor(unsigned factor, unsigned channel,
                              const double source[4],
                              const double destination[4],
                              const double constant[4])
{
    switch (factor) {
    case 0:
        return 0;
    case 1:
        return 1;
    case 2:
        return source[channel];
    case 3:
        return 1 - source[channel];
    case 4:
        return source[3];
    case 5:
        return 1 - source[3];
    case 6:
        return destination[3];
    case 7:
        return 1 - destination[3];
    case 8:
        return destination[channel];
    case 9:
        return 1 - destination[channel];
    case 10:
        return channel == 3 ? 1 : fmin(source[3], 1 - destination[3]);
    case 12:
        return constant[channel];
    case 13:
        return 1 - constant[channel];
    case 14:
        return constant[3];
    default:
        return 1 - constant[3];
    }
}
static void xo_complete_blending(void)
{
    const unsigned policies[] = { NV2AMetalSurfaceStorageZ1,
                                  NV2AMetalSurfaceStorageO1,
                                  NV2AMetalSurfaceStorageZ8,
                                  NV2AMetalSurfaceStorageO8 };
    const unsigned factors[] = { 0, 1, 2,  3,  4,  5,  6, 7,
                                 8, 9, 10, 12, 13, 14, 15 };
    const double src[] = { 51.0 / 255, 102.0 / 255, 153.0 / 255, 128.0 / 255 };
    const double blend_constant[] = { 43.0 / 255, 125.0 / 255, 153.0 / 255,
                                      85.0 / 255 };
    NV2AMetalVertex vertices[6];
    quad(vertices);
    for (unsigned i = 0; i < 6; i++)
        for (unsigned c = 0; c < 4; c++)
            vertices[i].color[0][c] = src[c];
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    unsigned cases = 0;
    for (unsigned format = 0; format < 4; format++) {
        NSError *error = nil;
        BOOL packed = format < 2;
        unsigned bytes = packed ? 2 : 4;
        unsigned initial = packed     ? format & 1 ? 0x1123 : 0xa123 :
                           format & 1 ? 0x33335577 :
                                        0xa5335577;
        const unsigned shift[] = { packed ? 10u : 16u, packed ? 5u : 8u, 0,
                                   packed ? 15u : 24u };
        const unsigned maximum[] = { packed ? 31u : 255u, packed ? 31u : 255u,
                                     packed ? 31u : 255u, packed ? 1u : 255u };
        double dest[4];
        for (unsigned c = 0; c < 4; c++)
            dest[c] = ((initial >> shift[c]) & maximum[c]) / (double)maximum[c];
        MTLPixelFormat pf =
            packed ? MTLPixelFormatBGR5A1Unorm : MTLPixelFormatBGRA8Unorm;
        NV2AMetalPixelShader *pipeline =
            [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                             colorFormat:pf
                                             depthFormat:MTLPixelFormatInvalid
                                             sampleCount:1
                                         surfaceChannels:policies[format]
                                                   error:&error];
        require(pipeline != nil, error);
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                               width:8
                                                              height:8
                                                           mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> output = [commands.device newTextureWithDescriptor:td];
        assert(output);
        unsigned char seed[256], result[256];
        for (unsigned i = 0; i < 64; i++)
            memcpy(seed + i * bytes, &initial, bytes);
        for (unsigned equation = 0; equation < 7; equation++)
            for (unsigned sf = 0; sf < 15; sf++)
                for (unsigned df = 0; df < 15; df++) {
                    @autoreleasepool {
                        NV2AMetalDrawConfig c = draw_config();
                        c.blend = NV_PGRAPH_BLEND_EN | equation |
                                  factors[sf] << 4 | factors[df] << 8;
                        c.blend_color = 0x552b7d99;
                        NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                            initWithDevice:commands.device
                                    config:&c
                                     error:&error];
                        require(state != nil, error);
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalPixelTexture textures[4] = { 0 };
                        MTL4RenderPassDescriptor *pass =
                            [MTL4RenderPassDescriptor new];
                        pass.colorAttachments[0].texture = output;
                        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                        pass.colorAttachments[0].storeAction =
                            MTLStoreActionStore;
                        [output replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
                                  mipmapLevel:0
                                    withBytes:seed
                                  bytesPerRow:8 * bytes];
                        require([commands beginWithError:&error] != nil, error);
                        require([pipeline
                                    encodeVertices:input
                                             count:6
                                         primitive:MTLPrimitiveTypeTriangle
                                          uniforms:&u
                                          textures:textures
                                              pass:pass
                                         drawState:state
                                          commands:commands
                                             error:&error],
                                error);
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error],
                                error);
                        [output getBytes:result
                             bytesPerRow:8 * bytes
                              fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                             mipmapLevel:0];
                        double expected[4];
                        for (unsigned channel = 0; channel < 3; channel++) {
                            double a =
                                src[channel] *
                                xo_blend_factor(factors[sf], channel, src, dest,
                                                blend_constant);
                            double b =
                                dest[channel] *
                                xo_blend_factor(factors[df], channel, src, dest,
                                                blend_constant);
                            double color =
                                equation == 3 ?
                                    fmin(src[channel], dest[channel]) :
                                equation == 4 ?
                                    fmax(src[channel], dest[channel]) :
                                equation == 0                  ? a - b :
                                equation == 1 || equation == 5 ? b - a :
                                                                 a + b;
                            expected[channel] =
                                fmin(1, fmax(0, color)) * maximum[channel];
                        }
                        expected[3] = format & 1 ? maximum[3] : 0;
                        for (unsigned pixel = 0; pixel < 64; pixel++) {
                            unsigned word = 0;
                            memcpy(&word, result + pixel * bytes, bytes);
                            for (unsigned channel = 0; channel < 4; channel++) {
                                unsigned actual =
                                    (word >> shift[channel]) & maximum[channel];
                                if (fabs(actual - expected[channel]) >
                                    (channel == 3 ? 0 : .51)) {
                                    fprintf(stderr,
                                            "X/O blend format%u eq%u sf%u df%u "
                                            "pixel%u channel%u got%u "
                                            "expected%.12f\n",
                                            format, equation, factors[sf],
                                            factors[df], pixel, channel, actual,
                                            expected[channel]);
                                    abort();
                                }
                            }
                        }
                        draws++;
                        cases++;
                    }
                }
    }
    printf("Metal 4 X/O blending: %u GPU cases, all64 pixels each PASS\n",
           cases);
}

static void a7_complete_blending(void)
{
    const unsigned policies[] = { NV2AMetalSurfaceStorageZ7,
                                  NV2AMetalSurfaceStorageO7 };
    const unsigned factors[] = { 0, 1, 2,  3,  4,  5,  6, 7,
                                 8, 9, 10, 12, 13, 14, 15 };
    const double src[] = { 51.0 / 255, 102.0 / 255, 153.0 / 255, 128.0 / 255 };
    const double blend_constant[] = { 43.0 / 255, 125.0 / 255, 153.0 / 255,
                                      85.0 / 255 };
    NV2AMetalVertex vertices[6];
    quad(vertices);
    for (unsigned i = 0; i < 6; i++)
        for (unsigned c = 0; c < 4; c++)
            vertices[i].color[0][c] = src[c];
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    unsigned cases = 0;
    for (unsigned format = 0; format < 2; format++) {
        NSError *error = nil;
        BOOL packed = NO;
        unsigned bytes = packed ? 2 : 4;
        unsigned initial = packed     ? format & 1 ? 0x1123 : 0xa123 :
                           format & 1 ? 0x33335577 :
                                        0xa5335577;
        const unsigned shift[] = { packed ? 10u : 16u, packed ? 5u : 8u, 0,
                                   packed ? 15u : 24u };
        const unsigned maximum[] = { packed ? 31u : 255u, packed ? 31u : 255u,
                                     packed ? 31u : 255u, packed ? 1u : 255u };
        double dest[4];
        for (unsigned c = 0; c < 4; c++)
            dest[c] = ((initial >> shift[c]) & maximum[c]) / (double)maximum[c];
        dest[3] = ((initial >> 24) & 127) / 127.0;
        MTLPixelFormat pf =
            packed ? MTLPixelFormatBGR5A1Unorm : MTLPixelFormatBGRA8Unorm;
        NV2AMetalPixelShader *pipeline =
            [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                             colorFormat:pf
                                             depthFormat:MTLPixelFormatInvalid
                                             sampleCount:1
                                         surfaceChannels:policies[format]
                                                   error:&error];
        require(pipeline != nil, error);
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                               width:8
                                                              height:8
                                                           mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> output = [commands.device newTextureWithDescriptor:td];
        assert(output);
        unsigned char seed[256], result[256];
        for (unsigned i = 0; i < 64; i++)
            memcpy(seed + i * bytes, &initial, bytes);
        for (unsigned equation = 0; equation < 7; equation++)
            for (unsigned sf = 0; sf < 15; sf++)
                for (unsigned df = 0; df < 15; df++) {
                    @autoreleasepool {
                        NV2AMetalDrawConfig c = draw_config();
                        c.blend = NV_PGRAPH_BLEND_EN | equation |
                                  factors[sf] << 4 | factors[df] << 8;
                        c.blend_color = 0x552b7d99;
                        NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                            initWithDevice:commands.device
                                    config:&c
                                     error:&error];
                        require(state != nil, error);
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalPixelTexture textures[4] = { 0 };
                        MTL4RenderPassDescriptor *pass =
                            [MTL4RenderPassDescriptor new];
                        pass.colorAttachments[0].texture = output;
                        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                        pass.colorAttachments[0].storeAction =
                            MTLStoreActionStore;
                        [output replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
                                  mipmapLevel:0
                                    withBytes:seed
                                  bytesPerRow:8 * bytes];
                        require([commands beginWithError:&error] != nil, error);
                        require([pipeline
                                    encodeVertices:input
                                             count:6
                                         primitive:MTLPrimitiveTypeTriangle
                                          uniforms:&u
                                          textures:textures
                                              pass:pass
                                         drawState:state
                                          commands:commands
                                             error:&error],
                                error);
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error],
                                error);
                        [output getBytes:result
                             bytesPerRow:8 * bytes
                              fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                             mipmapLevel:0];
                        double expected[4];
                        for (unsigned channel = 0; channel < 4; channel++) {
                            double a =
                                src[channel] *
                                xo_blend_factor(factors[sf], channel, src, dest,
                                                blend_constant);
                            double b =
                                dest[channel] *
                                xo_blend_factor(factors[df], channel, src, dest,
                                                blend_constant);
                            double color =
                                equation == 3 ?
                                    fmin(src[channel], dest[channel]) :
                                equation == 4 ?
                                    fmax(src[channel], dest[channel]) :
                                equation == 0                  ? a - b :
                                equation == 1 || equation == 5 ? b - a :
                                                                 a + b;
                            expected[channel] =
                                fmin(1, fmax(0, color)) * maximum[channel];
                        }
                        expected[3] =
                            (unsigned)floor(expected[3] / 255 * 127 + .5) |
                            (format & 1 ? 128u : 0u);
                        for (unsigned pixel = 0; pixel < 64; pixel++) {
                            unsigned word = 0;
                            memcpy(&word, result + pixel * bytes, bytes);
                            for (unsigned channel = 0; channel < 4; channel++) {
                                unsigned actual =
                                    (word >> shift[channel]) & maximum[channel];
                                if (fabs(actual - expected[channel]) >
                                    (channel == 3 ? 0 : .51)) {
                                    fprintf(stderr,
                                            "A7 blend format%u eq%u sf%u df%u "
                                            "pixel%u channel%u got%u "
                                            "expected%.12f\n",
                                            format, equation, factors[sf],
                                            factors[df], pixel, channel, actual,
                                            expected[channel]);
                                    abort();
                                }
                            }
                        }
                        draws++;
                        cases++;
                    }
                }
    }
    printf("Metal 4 A7 blending: %u GPU cases, all64 pixels each PASS\n",
           cases);
}

static void a7_alpha_codes(void)
{
    NSError *error = nil;
    for (unsigned one = 0; one < 2; one++) {
        NV2AMetalPixelShader *pipeline = [[NV2AMetalPixelShader alloc]
             initWithDevice:commands.device
                colorFormat:MTLPixelFormatBGRA8Unorm
                depthFormat:MTLPixelFormatInvalid
                sampleCount:1
            surfaceChannels:one ? NV2AMetalSurfaceStorageO7 :
                                  NV2AMetalSurfaceStorageZ7
                      error:&error];
        require(pipeline != nil, error);
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:8
                                        height:8
                                     mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> output = [commands.device newTextureWithDescriptor:td];
        assert(output);
        for (unsigned batch = 0; batch < 4; batch++) {
            NV2AMetalVertex v[64] = { 0 };
            for (unsigned i = 0; i < 64; i++) {
                v[i].clip[0] = ((i % 8) + .5f) / 4 - 1;
                v[i].clip[1] = 1 - ((i / 8) + .5f) / 4;
                v[i].clip[2] = .5f;
                v[i].clip[3] = 1;
                v[i].point_size = 1;
                v[i].color[0][0] = 1;
                v[i].color[0][1] = 64.f / 255;
                v[i].color[0][2] = 32.f / 255;
                v[i].color[0][3] = (batch * 64 + i) / 255.f;
            }
            id<MTLBuffer> input = [commands.device
                newBufferWithBytes:v
                            length:sizeof(v)
                           options:MTLResourceStorageModeShared];
            assert(input);
            MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
            p.colorAttachments[0].texture = output;
            p.colorAttachments[0].loadAction = MTLLoadActionClear;
            p.colorAttachments[0].storeAction = MTLStoreActionStore;
            NV2AMetalPixelUniforms u = uniforms();
            NV2AMetalPixelTexture textures[4] = { 0 };
            require([commands beginWithError:&error] != nil, error);
            require([pipeline encodeVertices:input
                                       count:64
                                   primitive:MTLPrimitiveTypePoint
                                    uniforms:&u
                                    textures:textures
                                        pass:p
                                depthStencil:nil
                                    commands:commands
                                       error:&error],
                    error);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            uint32_t words[64];
            [output getBytes:words
                 bytesPerRow:32
                  fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                 mipmapLevel:0];
            for (unsigned i = 0; i < 64; i++) {
                unsigned code = batch * 64 + i;
                unsigned alpha = (unsigned)floor(code * 127.0 / 255 + .5) |
                                 (one ? 128u : 0u);
                assert(words[i] == (alpha << 24 | 0xff4020));
            }
            draws++;
        }
    }
    puts("Metal 4 A7: all256 alpha input codes on both storage policies PASS");
}

/* NVIDIA NV_texture_shader section3.8.13.1.9: clamp the luminance
 * factor before multiplying RGB, and preserve the sampled alpha. */
static void bump_luminance_tests(void)
{
    unsigned before = draws;
    NV2AMetalVertex v[6];
    __attribute__((objc_precise_lifetime)) id<MTLTexture> sources[2] = {
        solid(.25f, 0, 0, 1), solid(-.5f, 0, 0, 1)
    };
    __attribute__((objc_precise_lifetime)) id<MTLTexture> image2 =
        solid(.25f, .5f, .75f, .375f);
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = MTLPixelFormatRGBA32Float;
    td.width = td.height = td.depth = 1;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    __attribute__((objc_precise_lifetime)) id<MTLTexture> image3 =
        [commands.device newTextureWithDescriptor:td];
    assert(image3);
    const float texel[] = { .25f, .5f, .75f, .375f };
    [image3 replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1)
              mipmapLevel:0
                    slice:0
                withBytes:texel
              bytesPerRow:16
            bytesPerImage:16];
    __attribute__((objc_precise_lifetime)) id<MTLTexture> lookup = gradient(4);
    // Keep the lookup's Y result constant: this checks dependent A without
    // assuming whether NV2A forwards scaled or unscaled bump RGB downstream.
    float lookup_texels[16][4];
    for (unsigned y = 0; y < 4; y++) {
        for (unsigned x = 0; x < 4; x++) {
            const float value[] = { (x + .5f) / 4, .25f, .2f, .75f };
            memcpy(lookup_texels[y * 4 + x], value, sizeof(value));
        }
    }
    [lookup replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
              mipmapLevel:0
                withBytes:lookup_texels
              bytesPerRow:64];
    const float parameters[][2] = { { -4, 0 },    { 0, 0 },   { 0, .25f },
                                    { 0, 1 },     { 0, 2 },   { 2, -.5f },
                                    { -2, 1.5f }, { 4, -.5f } };
    for (unsigned manual = 0; manual < 2; manual++) {
        manual_sampling = manual;
        for (unsigned signed_source = 0; signed_source < 2; signed_source++) {
            for (unsigned stage = 1; stage < 4; stage++) {
                for (unsigned previous = 0; previous < stage; previous++) {
                    for (unsigned dimension = 2; dimension < 4; dimension++) {
                        for (unsigned test = 0; test < 8; test++) {
                            NV2AMetalPixelUniforms u = uniforms();
                            NV2AMetalPixelTexture t[4] = { 0 };
                            quad(v);
                            texture_mode(&u, previous,
                                         PS_TEXTUREMODES_PROJECT2D);
                            texture_mode(&u, stage,
                                         PS_TEXTUREMODES_BUMPENVMAP_LUM);
                            show_texture(&u, stage);
                            if (stage > 1)
                                u.other_stage_input = previous
                                                      << (stage == 2 ? 16 : 20);
                            u.textures[previous].snorm = signed_source;
                            u.textures[stage].dimension = dimension;
                            u.textures[stage].bump_scale = parameters[test][0];
                            u.textures[stage].bump_offset = parameters[test][1];
                            t[previous].texture = sources[signed_source];
                            t[stage].texture = dimension == 2 ? image2 : image3;
                            coord(v, previous, .5f, .5f, 0, 1);
                            coord(v, stage, .5f, .5f, .5f, 1);
                            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                            double luminance = signed_source ? .75 : .25;
                            double factor = fmax(
                                0, fmin(1, parameters[test][0] * luminance +
                                               parameters[test][1]));
                            for (unsigned y = 0; y < 8; y++) {
                                for (unsigned x = 0; x < 8; x++)
                                    color(x, y, .25f * factor, .5f * factor,
                                          .75f * factor, .375f);
                            }
                        }
                    }
                }
            }
            for (unsigned test = 0; test < 4; test++) {
                NV2AMetalPixelUniforms u = uniforms();
                NV2AMetalPixelTexture t[4] = { 0 };
                quad(v);
                texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                texture_mode(&u, 1, PS_TEXTUREMODES_BUMPENVMAP_LUM);
                u.textures[0].snorm = signed_source;
                u.textures[1].bump_offset = test == 2 ? .25f :
                                            test == 3 ? 2 :
                                                        0;
                t[0].texture = sources[signed_source];
                t[1].texture = image2;
                coord(v, 0, .5f, .5f, 0, 1);
                coord(v, 1, .5f, .5f, 0, 1);
                if (!test) {
                    // Zero luminance must not discard alpha-tested fragments.
                    show_texture(&u, 1);
                    u.alpha_test = 1;
                    u.alpha_func = ALPHA_FUNC_GREATER;
                    u.alpha_ref = 63;
                } else {
                    // A subsequent dependent lookup must receive the original
                    // alpha.
                    texture_mode(&u, 2, PS_TEXTUREMODES_DPNDNT_AR);
                    u.other_stage_input = 1 << 16;
                    show_texture(&u, 2);
                    t[2].texture = lookup;
                }
                render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                for (unsigned y = 0; y < 8; y++) {
                    for (unsigned x = 0; x < 8; x++) {
                        if (!test) {
                            color(x, y, 0, 0, 0, .375f);
                        } else {
                            color(x, y, .375f, .25f, .2f, .75f);
                        }
                    }
                }
            }
        }
    }
    manual_sampling = NO;
    printf(
        "Metal4 bump luminance: %u RGB/alpha/alpha-test/dependent draws PASS\n",
        draws - before);
}

/* Keep R constant: this isolates filtered signed G/B without assuming how
 * NV2A recovers an unsigned luminance across a signed R discontinuity. */
/* NV_texture_shader 3.8.13.1.14: fully signed RGBA shader results enter
 * the dot product directly, independently of unsigned RGB mapping modes. */
static void signed_dot_tests(void)
{
    unsigned before = draws;
    const unsigned codes[] = { 0, 1, 63, 64, 126, 127, 128, 255 };
    id<MTLTexture> lookup = gradient(512);
    NV2AMetalVertex v[6];
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned map = 0; map < 4; map++)
            for (unsigned code = 0; code < 8; code++) {
                int q[4];
                float values[4];
                for (unsigned k = 0; k < 4; k++) {
                    unsigned raw = codes[(code + k) % 8];
                    q[k] = raw >= 128 ? (int)raw - 256 : (int)raw;
                    values[k] = q[k] / 128.0f;
                }
                __attribute__((objc_precise_lifetime)) id<MTLTexture> source =
                    solid(values[0], values[1], values[2], values[3]);
                for (unsigned stage = 2; stage < 4; stage++) {
                    NV2AMetalPixelUniforms u = uniforms();
                    NV2AMetalPixelTexture t[4] = { 0 };
                    quad(v);
                    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                    texture_mode(&u, stage - 1, PS_TEXTUREMODES_DOTPRODUCT);
                    texture_mode(&u, stage, PS_TEXTUREMODES_DOT_ST);
                    u.other_stage_input =
                        map << (4 * (stage - 2)) | map << (4 * (stage - 1));
                    u.textures[0].signed_channels = 15;
                    u.textures[0].sampling.enabled =
                        u.textures[stage].sampling.enabled = manual;
                    t[0].texture = source;
                    t[stage].texture = lookup;
                    coord(v, stage - 1, .5f, .25f, -.125f, 1);
                    coord(v, stage, -.125f, .25f, .5f, 1);
                    show_texture(&u, stage);
                    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                    double x = (.5 * q[0] + .25 * q[1] - .125 * q[2]) / 128;
                    double y = (-.125 * q[0] + .25 * q[1] + .5 * q[2]) / 128;
                    unsigned ix = fmin(511, fmax(0, floor(x * 512)));
                    unsigned iy = fmin(511, fmax(0, floor(y * 512)));
                    for (unsigned py = 0; py < 8; py++)
                        for (unsigned px = 0; px < 8; px++)
                            color(px, py, (ix + .5f) / 512, (iy + .5f) / 512,
                                  .2f, .75f);
                }
                // A fresh signed source isolates R/G in depth replacement.
                int red = codes[code] >= 128 ? (int)codes[code] - 256 :
                                               (int)codes[code];
                __attribute__((objc_precise_lifetime)) id<MTLTexture>
                    depth_source = solid(red / 128.0f, 127 / 128.0f, 1 / 128.0f,
                                         -1 / 128.0f);
                NV2AMetalPixelUniforms u = uniforms();
                NV2AMetalPixelTexture t[4] = { 0 };
                quad(v);
                texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
                texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ZW);
                u.other_stage_input = map | map << 4;
                u.textures[0].signed_channels = 15;
                u.textures[0].sampling.enabled = manual;
                t[0].texture = depth_source;
                coord(v, 1, .25f, .125f, 0, 1);
                coord(v, 2, 0, 1, 0, 1);
                render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                float expected = .25f * red / 127 + .125f;
                if (expected < 0 || expected > 1) {
                    clear(3, 4);
                    check_depth(depth_at(3, 4), .99f);
                } else {
                    color(3, 4, .1f, .2f, .3f, .4f);
                    float quantized = floorf(expected * 65535);
                    check_depth(depth_at(3, 4), quantized / 65535);
                }
            }
    __attribute__((objc_precise_lifetime)) id<MTLTexture> normal_cube = cube();
    __attribute__((objc_precise_lifetime)) id<MTLTexture> signed_source =
        solid(.25f, .5f, .75f, -1 / 128.0f);
    const unsigned modes[] = { PS_TEXTUREMODES_DOT_STR_CUBE,
                               PS_TEXTUREMODES_DOT_RFLCT_SPEC,
                               PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST,
                               PS_TEXTUREMODES_DOT_RFLCT_DIFF };
    const float normals[][3] = { { 1, .25f, .125f },
                                 { -.25f, 1, .125f },
                                 { .25f, .125f, -1 } };
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned map = 0; map < 4; map++)
            for (unsigned mode = 0; mode < 4; mode++)
                for (unsigned normal = 0; normal < 3; normal++) {
                    NV2AMetalPixelUniforms u = uniforms();
                    NV2AMetalPixelTexture t[4] = { 0 };
                    quad(v);
                    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                    texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
                    texture_mode(&u, 2,
                                 mode == 3 ? PS_TEXTUREMODES_DOT_RFLCT_DIFF :
                                             PS_TEXTUREMODES_DOTPRODUCT);
                    texture_mode(&u, 3,
                                 mode == 3 ? PS_TEXTUREMODES_DOT_RFLCT_SPEC :
                                             modes[mode]);
                    u.other_stage_input = map | map << 4 | map << 8;
                    u.textures[0].signed_channels = 15;
                    u.textures[0].sampling.enabled = manual;
                    t[0].texture = signed_source;
                    for (unsigned i = 2; i < 4; i++) {
                        u.textures[i].cubemap = 1;
                        u.textures[i].sampling.enabled = manual;
                        t[i].texture = normal_cube;
                    }
                    const float *n = normals[normal];
                    coord(v, 1, n[0] * 4, 0, 0, 1);
                    coord(v, 2, 0, n[1] * 2, 0, 0);
                    coord(v, 3, 0, 0, n[2] * 4 / 3, 0);
                    u.eye_vector[0] = 1;
                    show_texture(&u, mode == 3 ? 2 : 3);
                    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                    double result[3] = { n[0], n[1], n[2] };
                    if (mode == 1 || mode == 2) {
                        double length2 =
                            n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
                        for (unsigned k = 0; k < 3; k++)
                            result[k] = 2 * n[k] * n[0] / length2 - (k == 0);
                    }
                    unsigned axis = fabs(result[0]) > fabs(result[1]) ? 0 : 1;
                    if (fabs(result[2]) > fabs(result[axis]))
                        axis = 2;
                    unsigned face = 2 * axis + (result[axis] < 0);
                    for (unsigned py = 0; py < 8; py++)
                        for (unsigned px = 0; px < 8; px++)
                            color(px, py, .1f * (face + 1), .2f, .3f, 1);
                }
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned map = 0; map < 4; map++) {
            NV2AMetalPixelUniforms u = uniforms();
            NV2AMetalPixelTexture t[4] = { 0 };
            quad(v);
            texture_mode(&u, 0, PS_TEXTUREMODES_PASSTHRU);
            texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
            texture_mode(&u, 2, PS_TEXTUREMODES_DOT_ST);
            u.other_stage_input = map | map << 4;
            u.textures[0].signed_channels = 15;
            u.textures[2].sampling.enabled = manual;
            t[2].texture = lookup;
            coord(v, 0, .25f, .5f, .75f, 1);
            coord(v, 1, 1, 0, 0, 1);
            coord(v, 2, 0, 1, 0, 1);
            show_texture(&u, 2);
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            const double raw[] = { 63.75, 127.5 };
            unsigned index[2];
            for (unsigned k = 0; k < 2; k++) {
                double value = map == 0 ? raw[k] / 255 :
                               map == 1 ? (raw[k] - 128) / 127 :
                               map == 2 ? (raw[k] + .5) / 127.5 :
                                          raw[k] / 127;
                index[k] = fmin(511, fmax(0, floor(value * 512)));
            }
            color(3, 4, (index[0] + .5f) / 512, (index[1] + .5f) / 512, .2f,
                  .75f);
        }
    printf("Metal4 signed dot: %u RGBA/ST/depth/cube/reflection/passthrough "
           "draws PASS\n",
           draws - before);
}

static void signed_bump_filter_tests(void)
{
    unsigned before = draws;
    id<MTLTexture> lookup = gradient(512);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.supportArgumentBuffers = YES;
    __attribute__((objc_precise_lifetime)) id<MTLSamplerState> linear =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(linear);
    for (unsigned mask = 0; mask < 16; mask++) {
        float data[2][2][4];
        for (unsigned y = 0; y < 2; y++)
            for (unsigned x = 0; x < 2; x++) {
                const unsigned raw[] = { 64, x ? 128 : 127, x ? 127 : 128,
                                         255 };
                for (unsigned k = 0; k < 4; k++) {
                    int q = raw[k];
                    if ((mask & (1u << k)) && q >= 128)
                        q -= 256;
                    data[y][x][k] = q / ((mask & (1u << k)) ? 128.0f : 255.0f);
                }
            }
        __attribute__((objc_precise_lifetime)) id<MTLTexture> source =
            gradient(2);
        [source replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                  mipmapLevel:0
                    withBytes:data
                  bytesPerRow:sizeof(data[0])];
        for (unsigned manual = 0; manual < 2; manual++)
            for (unsigned stage = 1; stage < 4; stage++)
                for (unsigned previous = 0; previous < stage; previous++)
                    for (unsigned lum = 0; lum < 2; lum++) {
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalPixelTexture t[4] = { 0 };
                        NV2AMetalVertex v[6];
                        quad(v);
                        texture_mode(&u, previous, PS_TEXTUREMODES_PROJECT2D);
                        texture_mode(&u, stage,
                                     lum ? PS_TEXTUREMODES_BUMPENVMAP_LUM :
                                           PS_TEXTUREMODES_BUMPENVMAP);
                        if (stage > 1)
                            u.other_stage_input = previous
                                                  << (stage == 2 ? 16 : 20);
                        u.textures[previous].signed_channels = mask;
                        u.textures[previous].sampling.enabled = manual;
                        u.textures[previous].sampling.min_linear =
                            u.textures[previous].sampling.mag_linear = 1;
                        u.textures[stage].sampling.enabled = 1;
                        const float matrix[] = { .125f, .25f, -.25f, .125f };
                        memcpy(u.textures[stage].bump_matrix, matrix,
                               sizeof(matrix));
                        u.textures[stage].bump_scale = 1;
                        t[previous].texture = source;
                        t[previous].sampler = linear;
                        t[stage].texture = lookup;
                        coord(v, previous, .5f, .5f, 0, 1);
                        coord(v, stage, .519f, .481f, 0, 1);
                        show_texture(&u, stage);
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                        double ds = mask & 4 ? -1.0 / 256 : 127.5 / 127;
                        double dt = mask & 2 ? -1.0 / 256 : 127.5 / 127;
                        unsigned x =
                            floor((.519f + .125 * ds - .25 * dt) * 512);
                        unsigned y =
                            floor((.481f + .25 * ds + .125 * dt) * 512);
                        float factor = lum ? 64 / 255.0f : 1;
                        for (unsigned py = 0; py < 8; py++)
                            for (unsigned px = 0; px < 8; px++)
                                color(px, py, (x + .5f) / 512 * factor,
                                      (y + .5f) / 512 * factor, .2f * factor,
                                      .75f);
                    }
    }
    printf("Metal4 signed bump filtering: %u manual/native seam draws PASS\n",
           draws - before);
}

static void signed_bump_tests(void)
{
    unsigned before = draws;
    const unsigned codes[] = { 0, 1, 63, 64, 126, 127, 128, 255 };
    id<MTLTexture> lookup = gradient(512);
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned stage = 1; stage < 4; stage++)
            for (unsigned previous = 0; previous < stage; previous++)
                for (unsigned mask = 0; mask < 16; mask++)
                    for (unsigned code = 0; code < 8; code++) {
                        unsigned raw[4];
                        float value[4];
                        for (unsigned k = 0; k < 4; k++) {
                            raw[k] = codes[(code + k) % 8];
                            int q = raw[k];
                            if ((mask & (1u << k)) && q >= 128)
                                q -= 256;
                            value[k] =
                                q / ((mask & (1u << k)) ? 128.0f : 255.0f);
                        }
                        __attribute__((objc_precise_lifetime)) id<MTLTexture>
                            source =
                                solid(value[0], value[1], value[2], value[3]);
                        for (unsigned lum = 0; lum < 2; lum++) {
                            NV2AMetalPixelUniforms u = uniforms();
                            NV2AMetalPixelTexture t[4] = { 0 };
                            NV2AMetalVertex v[6];
                            quad(v);
                            texture_mode(&u, previous,
                                         PS_TEXTUREMODES_PROJECT2D);
                            texture_mode(&u, stage,
                                         lum ? PS_TEXTUREMODES_BUMPENVMAP_LUM :
                                               PS_TEXTUREMODES_BUMPENVMAP);
                            if (stage > 1)
                                u.other_stage_input = previous
                                                      << (stage == 2 ? 16 : 20);
                            u.textures[previous].signed_channels = mask;
                            u.textures[previous].sampling.enabled =
                                u.textures[stage].sampling.enabled = manual;
                            const float matrix[] = { .125f, .25f, -.25f,
                                                     .125f };
                            memcpy(u.textures[stage].bump_matrix, matrix,
                                   sizeof(matrix));
                            u.textures[stage].bump_scale = 1;
                            t[previous].texture = source;
                            t[stage].texture = lookup;
                            coord(v, stage, .519f, .481f, 0, 1);
                            show_texture(&u, stage);
                            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                            int b =
                                raw[2] >= 128 ? (int)raw[2] - 256 : (int)raw[2];
                            int g =
                                raw[1] >= 128 ? (int)raw[1] - 256 : (int)raw[1];
                            double ds = b / ((mask & 4) ? 128.0 : 127.0);
                            double dt = g / ((mask & 2) ? 128.0 : 127.0);
                            unsigned x =
                                floor((.519f + .125 * ds - .25 * dt) * 512);
                            unsigned y =
                                floor((.481f + .25 * ds + .125 * dt) * 512);
                            float factor = lum ? raw[0] / 255.0f : 1;
                            for (unsigned py = 0; py < 8; py++)
                                for (unsigned px = 0; px < 8; px++)
                                    color(px, py, (x + .5f) / 512 * factor,
                                          (y + .5f) / 512 * factor,
                                          .2f * factor, .75f);
                        }
                    }
    printf("Metal4 signed bump: %u mask/matrix/luminance draws PASS\n",
           draws - before);
}

/* NV_texture_shader 3.8.13.1.9: dependent stages consume the texel before
 * luminance scaling; the register combiner consumes the scaled RGB. */
static void bump_shader_result_tests(void)
{
    const unsigned before = draws;
    const float factors[] = { 0, .25f, 1, 2 };
    __attribute__((objc_precise_lifetime)) id<MTLTexture> source =
        solid(.25f, 0, 0, 1);
    __attribute__((objc_precise_lifetime)) id<MTLTexture> image =
        solid(.25f, .5f, .75f, .375f);
    id<MTLTexture> lookup = gradient(8);
    NV2AMetalVertex v[6];
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned bump = 1; bump < 3; bump++)
            for (unsigned stage = bump + 1; stage < 4; stage++)
                for (unsigned gb = 0; gb < 2; gb++)
                    for (unsigned factor = 0; factor < 4; factor++) {
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalPixelTexture t[4] = { 0 };
                        quad(v);
                        texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                        texture_mode(&u, bump, PS_TEXTUREMODES_BUMPENVMAP_LUM);
                        texture_mode(&u, stage,
                                     gb ? PS_TEXTUREMODES_DPNDNT_GB :
                                          PS_TEXTUREMODES_DPNDNT_AR);
                        u.other_stage_input = bump << (stage == 2 ? 16 : 20);
                        u.textures[bump].bump_offset = factors[factor];
                        for (unsigned i = 0; i < 4; i++)
                            u.textures[i].sampling.enabled = manual;
                        t[0].texture = source;
                        t[bump].texture = image;
                        t[stage].texture = lookup;
                        show_texture(&u, stage);
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                        float x = gb ? 4.5f / 8 : 3.5f / 8;
                        float y = gb ? 6.5f / 8 : 2.5f / 8;
                        for (unsigned py = 0; py < 8; py++)
                            for (unsigned px = 0; px < 8; px++)
                                color(px, py, x, y, .2f, .75f);
                        show_texture(&u, bump);
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                        float scale = fminf(1, factors[factor]);
                        for (unsigned py = 0; py < 8; py++)
                            for (unsigned px = 0; px < 8; px++)
                                color(px, py, .25f * scale, .5f * scale,
                                      .75f * scale, .375f);
                    }
    printf("Metal4 bump result: %u separate shader/combiner draws PASS\n",
           draws - before);
}

/* Family model: all Signed flags select signed16 HILO. Preserve its 16-bit
 * range when recovering unsigned ColorKey bytes and bump luminance. */
static void signed_hilo16_effect_tests(void)
{
    unsigned before = draws;
    const unsigned words[][2] = { { 0, 1 },           { 1, 32767 },
                                  { 32767, 32768 },   { 32768, 65535 },
                                  { 65535, 255 },     { 0x1289, 0x89ab },
                                  { 0x7ffe, 0x8001 }, { 0xc321, 0x4321 } };
    id<MTLTexture> lookup = gradient(512);
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned code = 0; code < sizeof(words) / sizeof(*words); code++) {
            unsigned hi = words[code][0], lo = words[code][1];
            int h = hi >= 32768 ? (int)hi - 65536 : (int)hi;
            int l = lo >= 32768 ? (int)lo - 65536 : (int)lo;
            __attribute__((objc_precise_lifetime)) id<MTLTexture> source =
                solid(h / 32768.f, l / 32768.f, l / 32768.f, 1);
            const float red = fmaxf(0, 2 * h / 65535.f),
                        green = fmaxf(0, 2 * l / 65535.f);
            unsigned r = floor(hi / 65535.0 * 255 + .5),
                     g = floor(lo / 65535.0 * 255 + .5);
            uint32_t key = 0xff000000u | r << 16 | g << 8 | g;
            for (unsigned stage = 0; stage < 4; stage++)
                for (unsigned mode = 0; mode <= 3; mode++)
                    for (unsigned variant = 0; variant < 2; variant++) {
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalPixelTexture t[4] = { 0 };
                        NV2AMetalVertex v[6];
                        quad(v);
                        texture_mode(&u, stage, PS_TEXTUREMODES_PROJECT2D);
                        show_texture(&u, stage);
                        u.hilo16_mask = 1u << stage;
                        u.textures[stage].signed_channels = 15;
                        u.textures[stage].sampling.enabled = manual;
                        u.textures[stage].colorkey_mode = mode;
                        u.textures[stage].color_key_mask = UINT32_MAX;
                        u.textures[stage].color_key = key ^ (variant ? 1 : 0);
                        u.textures[stage].alphakill = mode == 0 && variant;
                        t[stage].texture = source;
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                        for (unsigned y = 0; y < 8; y++)
                            for (unsigned x = 0; x < 8; x++) {
                                if (mode == COLOR_KEY_DISCARD && !variant)
                                    clear(x, y);
                                else if (mode ==
                                             COLOR_KEY_KILL_COLOR_AND_ALPHA &&
                                         !variant)
                                    color(x, y, 0, 0, 0, 0);
                                else
                                    color(x, y, red, green, green,
                                          mode == COLOR_KEY_KILL_ALPHA &&
                                                  !variant ?
                                              0 :
                                              1);
                            }
                    }
            for (unsigned stage = 1; stage < 4; stage++)
                for (unsigned previous = 0; previous < stage; previous++)
                    for (unsigned lum = 0; lum < 2; lum++) {
                        NV2AMetalPixelUniforms u = uniforms();
                        NV2AMetalPixelTexture t[4] = { 0 };
                        NV2AMetalVertex v[6];
                        quad(v);
                        texture_mode(&u, previous, PS_TEXTUREMODES_PROJECT2D);
                        texture_mode(&u, stage,
                                     lum ? PS_TEXTUREMODES_BUMPENVMAP_LUM :
                                           PS_TEXTUREMODES_BUMPENVMAP);
                        if (stage > 1)
                            u.other_stage_input = previous
                                                  << (stage == 2 ? 16 : 20);
                        u.hilo16_mask = 1u << previous;
                        u.textures[previous].signed_channels = 15;
                        u.textures[previous].sampling.enabled =
                            u.textures[stage].sampling.enabled = manual;
                        const float matrix[] = { .125f, .25f, -.25f, .125f };
                        memcpy(u.textures[stage].bump_matrix, matrix,
                               sizeof(matrix));
                        u.textures[stage].bump_scale = 1;
                        t[previous].texture = source;
                        t[stage].texture = lookup;
                        coord(v, stage, .519f, .481f, 0, 1);
                        show_texture(&u, stage);
                        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                        double value = l / 32768.0;
                        unsigned x = floor((.519f - .125 * value) * 512),
                                 y = floor((.481f + .375 * value) * 512);
                        float factor = lum ? hi / 65535.f : 1;
                        for (unsigned py = 0; py < 8; py++)
                            for (unsigned px = 0; px < 8; px++)
                                color(px, py, (x + .5f) / 512 * factor,
                                      (y + .5f) / 512 * factor, .2f * factor,
                                      .75f);
                    }
        }
    assert(draws - before == 704);
    printf("Metal4 signed HILO16 effects: 704 "
           "ColorKey/AlphaKill/bump/luminance draws PASS\n");
}

static void signed_texture_tests(void)
{
    const unsigned first = draws;
    const unsigned codes[] = { 0, 1, 63, 64, 126, 127, 128, 255 };
    NV2AMetalVertex v[6];
    quad(v);
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned stage = 0; stage < 4; stage++)
            for (unsigned mask = 0; mask < 16; mask++)
                for (unsigned code = 0; code < 8; code++) {
                    float input[4], expected[4];
                    for (unsigned k = 0; k < 4; k++) {
                        int raw = codes[(code + k) % 8];
                        int q =
                            (mask & (1u << k)) && raw >= 128 ? raw - 256 : raw;
                        input[k] = q / ((mask & (1u << k)) ? 128.0f : 255.0f);
                        expected[k] =
                            (mask & (1u << k)) ? 2 * q / 255.0f : q / 255.0f;
                    }
                    NV2AMetalPixelUniforms u = uniforms();
                    NV2AMetalPixelTexture t[4] = { 0 };
                    __attribute__((objc_precise_lifetime)) id<MTLTexture>
                        source = solid(input[0], input[1], input[2], input[3]);
                    t[stage].texture = source;
                    texture_mode(&u, stage, PS_TEXTUREMODES_PROJECT2D);
                    show_texture(&u, stage);
                    u.combiner.final_inputs[0] |=
                        PS_INPUTMAPPING_SIGNED_IDENTITY;
                    u.combiner.final_inputs[1] |=
                        PS_INPUTMAPPING_SIGNED_IDENTITY << 8;
                    u.textures[stage].signed_channels = mask;
                    u.textures[stage].sampling.enabled = manual;
                    render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                    for (unsigned y = 0; y < 8; y++)
                        for (unsigned x = 0; x < 8; x++)
                            color(x, y, expected[0], expected[1], expected[2],
                                  expected[3]);
                }
    // At this resolution q/128 and 2q/255 select distinct texels. A dependent
    // shader must consume the former, independently of the combiner mapping.
    id<MTLTexture> lookup = gradient(512);
    for (unsigned manual = 0; manual < 2; manual++)
        for (unsigned stage = 1; stage < 4; stage++)
            for (unsigned gb = 0; gb < 2; gb++) {
                NV2AMetalPixelUniforms u = uniforms();
                NV2AMetalPixelTexture t[4] = { 0 };
                __attribute__((objc_precise_lifetime)) id<MTLTexture> source =
                    solid(.75f, .75f, .75f, .75f);
                t[0].texture = source;
                t[stage].texture = lookup;
                texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
                texture_mode(&u, stage,
                             gb ? PS_TEXTUREMODES_DPNDNT_GB :
                                  PS_TEXTUREMODES_DPNDNT_AR);
                u.textures[0].signed_channels = 15;
                u.textures[0].sampling.enabled =
                    u.textures[stage].sampling.enabled = manual;
                show_texture(&u, stage);
                render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++)
                        color(x, y, 384.5f / 512, 384.5f / 512, .2f, .75f);
            }
    NSError *error = nil;
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    for (unsigned mask = 0; mask < 16; mask++) {
        NV2AMetalSamplerConfig c = { 0 };
        c.filter = 1 << 16 | 1 << 24;
        c.address = 4 | 4 << 8 | 4 << 16;
        c.anisotropy = 1;
        c.border_color = 0x017f80ff;
        c.signed_channels = mask;
        NV2AMetalTextureBinding *b =
            [sampler bindingForTexture:solid(0, 0, 0, 0)
                                config:&c
                                 error:&error];
        require(b != nil, error);
        NV2AMetalPixelUniforms u = uniforms();
        NV2AMetalPixelTexture t[4] = { 0 };
        t[0].texture = b.texture;
        t[0].sampler = b.sampler;
        u.textures[0].sampling = b.sampling;
        u.textures[0].signed_channels = mask;
        texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
        show_texture(&u, 0);
        u.combiner.final_inputs[0] |= PS_INPUTMAPPING_SIGNED_IDENTITY;
        u.combiner.final_inputs[1] |= PS_INPUTMAPPING_SIGNED_IDENTITY << 8;
        coord(v, 0, -2, -2, 0, 1);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        const unsigned raw[] = { 127, 128, 255, 1 };
        float expected[4];
        for (unsigned k = 0; k < 4; k++) {
            int q = raw[k];
            if ((mask & (1u << k)) && q >= 128)
                q -= 256;
            expected[k] = (mask & (1u << k)) ? 2 * q / 255.0f : q / 255.0f;
        }
        color(3, 4, expected[0], expected[1], expected[2], expected[3]);
    }
    quad(v);
    for (unsigned mask = 0; mask < 16; mask++) {
        const unsigned raw[] = { 127, 128, 255, 1 };
        float value[4], expected[4];
        for (unsigned k = 0; k < 4; k++) {
            int q = raw[k];
            if ((mask & (1u << k)) && q >= 128)
                q -= 256;
            value[k] = q / ((mask & (1u << k)) ? 128.0f : 255.0f);
            expected[k] = (mask & (1u << k)) ? 2 * q / 255.0f : q / 255.0f;
        }
        __attribute__((objc_precise_lifetime)) id<MTLTexture> source =
            solid(value[0], value[1], value[2], value[3]);
        for (unsigned mode = 1; mode <= 3; mode++) {
            NV2AMetalPixelUniforms u = uniforms();
            NV2AMetalPixelTexture t[4] = { 0 };
            t[0].texture = source;
            texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
            show_texture(&u, 0);
            u.combiner.final_inputs[0] |= PS_INPUTMAPPING_SIGNED_IDENTITY;
            u.combiner.final_inputs[1] |= PS_INPUTMAPPING_SIGNED_IDENTITY << 8;
            u.textures[0].signed_channels = mask;
            u.textures[0].colorkey_mode = mode;
            u.textures[0].color_key_mask = UINT32_MAX;
            u.textures[0].color_key = 0x017f80ff;
            render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
            if (mode == COLOR_KEY_DISCARD)
                clear(3, 4);
            else if (mode == COLOR_KEY_KILL_COLOR_AND_ALPHA)
                color(3, 4, 0, 0, 0, 0);
            else
                color(3, 4, expected[0], expected[1], expected[2], 0);
        }
        // Decode each side of the signed seam before bilinear interpolation,
        // then apply the shader-to-combiner transfer exactly once.
        __attribute__((objc_precise_lifetime)) id<MTLTexture> seam =
            gradient(2);
        float data[2][2][4], result[4];
        for (unsigned k = 0; k < 4; k++) {
            float left = (mask & (1u << k)) ? 127 / 128.0f : 127 / 255.0f;
            float right = (mask & (1u << k)) ? -1 : 128 / 255.0f;
            data[0][0][k] = data[1][0][k] = left;
            data[0][1][k] = data[1][1][k] = right;
            result[k] = (mask & (1u << k)) ? -1 / 255.0f : .5f;
        }
        [seam replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                mipmapLevel:0
                  withBytes:data
                bytesPerRow:sizeof(data[0])];
        NV2AMetalPixelUniforms u = uniforms();
        NV2AMetalPixelTexture t[4] = { 0 };
        t[0].texture = seam;
        texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
        show_texture(&u, 0);
        u.combiner.final_inputs[0] |= PS_INPUTMAPPING_SIGNED_IDENTITY;
        u.combiner.final_inputs[1] |= PS_INPUTMAPPING_SIGNED_IDENTITY << 8;
        u.textures[0].signed_channels = mask;
        u.textures[0].sampling.enabled = 1;
        u.textures[0].sampling.min_linear = u.textures[0].sampling.mag_linear =
            1;
        coord(v, 0, .5f, .5f, 0, 1);
        render(&u, v, 6, MTLPrimitiveTypeTriangle, t);
        color(3, 4, result[0], result[1], result[2], result[3]);
    }
    printf("Metal4 signed8 fragment: %u boundary/dependent/border/key/filter "
           "draws PASS\n",
           draws - first);
}

static void combiner_output_bias_tests(void)
{
    const struct {
        unsigned a, b, flags, negative, expected;
    } hardware[] = {
        { 255, 0, PS_COMBINEROUTPUT_BIAS, 0, 127 },
        { 255, 0, PS_COMBINEROUTPUT_SHIFTLEFT_1_BIAS, 0, 254 },
        { 95, 95, PS_COMBINEROUTPUT_SHIFTLEFT_1_BIAS, 0, 124 },
        { 191, 191, PS_COMBINEROUTPUT_BIAS, 0, 254 },
        { 159, 159, PS_COMBINEROUTPUT_BIAS, 0, 190 },
        { 31, 191, PS_COMBINEROUTPUT_BIAS, 1, 32 },
    };
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalVertex v[6];
    quad(v);
    for (unsigned i = 0; i < sizeof(hardware) / sizeof(*hardware); i++) {
        NV2AMetalPixelUniforms u = uniforms();
        u.combiner.control = hardware[i].negative ? 2 : 1;
        for (unsigned k = 0; k < 4; k++) {
            u.combiner.constants[0][k] = hardware[i].a / 255.0f;
            u.combiner.constants[1][k] = hardware[i].b / 255.0f;
        }
        unsigned a = PS_REGISTER_C0 |
                     (hardware[i].negative ? PS_INPUTMAPPING_SIGNED_NEGATE :
                                             PS_INPUTMAPPING_UNSIGNED_IDENTITY);
        u.combiner.rgb_inputs[0] =
            a << 24 | PS_REGISTER_ONE << 16 |
            (hardware[i].negative ? 0 : PS_REGISTER_C1) << 8 | PS_REGISTER_ONE;
        u.combiner.alpha_inputs[0] = u.combiner.rgb_inputs[0] | 0x10101010;
        u.combiner.rgb_outputs[0] = u.combiner.alpha_outputs[0] =
            PS_REGISTER_R0 << 8 | hardware[i].flags << 12;
        if (hardware[i].negative) {
            u.combiner.rgb_inputs[1] =
                PS_REGISTER_C1 << 24 | PS_REGISTER_ONE << 16 |
                (PS_REGISTER_R0 | PS_INPUTMAPPING_SIGNED_IDENTITY) << 8 |
                PS_REGISTER_ONE;
            u.combiner.alpha_inputs[1] = u.combiner.rgb_inputs[1] | 0x10101010;
            u.combiner.rgb_outputs[1] = u.combiner.alpha_outputs[1] =
                PS_REGISTER_R0 << 8;
        }
        u.combiner.final_inputs[0] = PS_REGISTER_R0;
        u.combiner.final_inputs[1] = (PS_REGISTER_R0 | PS_CHANNEL_ALPHA) << 8;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        float expected = hardware[i].expected / 255.0f;
        for (unsigned y = 0; y < 8; y++) {
            for (unsigned x = 0; x < 8; x++) {
                color(x, y, expected, expected, expected, expected);
            }
        }
    }
    printf("Metal 4 combiner output bias: 6 hardware-derived fragment draws "
           "PASS\n");
}

#include "test-metal-raster-specialization.h"

int main(int argc, char **argv)
{
    BOOL specialization =
        argc == 2 && !strcmp(argv[1], "--pipeline-specialization");
    assert(argc == 1 || specialization);
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        shader = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA32Float
               depthFormat:MTLPixelFormatDepth32Float
               sampleCount:1
                     error:&error];
        require(shader != nil, error);
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:8
                                        height:8
                                     mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                   MTLTextureUsagePixelFormatView;
        target = [commands.device newTextureWithDescriptor:td];
        td.pixelFormat = MTLPixelFormatDepth32Float;
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget;
        depth = [commands.device newTextureWithDescriptor:td];
        depth_readback =
            [commands.device newBufferWithLength:8 * 256
                                         options:MTLResourceStorageModeShared];
        MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
        ds.depthCompareFunction = MTLCompareFunctionAlways;
        ds.depthWriteEnabled = YES;
        depth_state = [commands.device newDepthStencilStateWithDescriptor:ds];
        assert(target && depth && depth_readback && depth_state);
        NV2AMetalVertex v[6];
        quad(v);
        NV2AMetalPixelUniforms u = uniforms();
        NV2AMetalPixelTexture textures[4] = { 0 };
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        for (unsigned y = 0; y < 8; y++) {
            for (unsigned x = 0; x < 8; x++) {
                color(x, y, .1f, .2f, .3f, .4f);
                check_depth(depth_at(x, y), 2.0f / 65535);
            }
        }

        id<MTLTexture> tex = gradient(4);
        u.alpha_test = 1;
        u.alpha_func = ALPHA_FUNC_NEVER;
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        clear(3, 4);
        check_depth(depth_at(3, 4), .99f);
        for (unsigned stage = 0; stage < 4; stage++) {
            u = uniforms();
            quad(v);
            texture_mode(&u, stage, PS_TEXTUREMODES_PROJECT2D);
            show_texture(&u, stage);
            coord(v, stage, 1.25f, .75f, .2f, 2);
            textures[stage].texture = tex;
            render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
            color(3, 4, .625f, .375f, .2f, .75f);
        }
        if (specialization) {
            dynamic_raster_tag_tests();
            raster_class_tests();
            combiner_output_bias_tests();
            native_draw_tests();
            native_stencil_tests();
            draw_cache_lifetime_test();
            multisample_test();
            native_attachment_formats_test();
            printf("Metal 4 pipeline specialization: %u oracle/cache/MSAA "
                   "draws PASS\n",
                   draws);
            return 0;
        }
        f16_depth_encoding_tests();
        f24_depth_encoding_tests();
        f24_gradient_geometry_tests();
        raster_tests();
        w_depth_tests();
        f24_w_offset_geometry_tests();
        passthrough_tests();
        bump_luminance_tests();
        bump_shader_result_tests();
        signed_bump_tests();
        signed_bump_filter_tests();
        signed_dot_tests();
        combiner_output_bias_tests();
        signed_texture_tests();
        sampling_tests();
        special_sampling_tests();
        primitive_tests();
        geometry_handoff_test();
        interpolation_and_sampler_tests();
        rejection_tests();
        hilo_exhaustive_test();
        hilo_fragment_tests();
        brdf_tests(NO);
        brdf_tests(YES);
        hilo16_dot_tests();
        signed_hilo16_effect_tests();
        brdf_effect_tests();
        brdf_rejection_tests();
        constant_eye_tests();
        reflection_range_tests();
        depth_replace_tests();
        snapshots_test();
        multisample_test();
        native_sampler_tests();
        manual_sampling = YES;
        sampling_tests();
        special_sampling_tests();
        manual_sampling = NO;
        native_depth_replace_tests();
        native_draw_tests();
        native_stencil_tests();
        draw_state_rejection_tests();
        draw_cache_lifetime_test();
        native_attachment_formats_test();
        xo_complete_blending();
        a7_complete_blending();
        a7_alpha_codes();
        native_depth16_test();
        printf("Metal 4 native fragment pipeline: %u offscreen draws PASS\n",
               draws);
    }
    return 0;
}
