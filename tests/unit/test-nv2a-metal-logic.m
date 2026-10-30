/* Native framebuffer logic tests; no app, VM or window is started.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#include "hw/xbox/nv2a/pgraph/metal/geometry-types.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    MTLPixelFormat format;
    unsigned bytes, shift[4], bits[4];
} LogicFormat;
static const LogicFormat formats[] = {
    { MTLPixelFormatRGBA8Unorm, 4, { 0, 8, 16, 24 }, { 8, 8, 8, 8 } },
    { MTLPixelFormatBGRA8Unorm, 4, { 16, 8, 0, 24 }, { 8, 8, 8, 8 } },
    { MTLPixelFormatR8Unorm, 1, { 0 }, { 8 } },
    { MTLPixelFormatRG8Unorm, 2, { 0, 8 }, { 8, 8 } },
    { MTLPixelFormatB5G6R5Unorm, 2, { 11, 5, 0 }, { 5, 6, 5 } },
    { MTLPixelFormatBGR5A1Unorm, 2, { 10, 5, 0, 15 }, { 5, 5, 5, 1 } },
};
static NV2AMetalCommands *commands;
static unsigned images;
static unsigned long pixels_checked;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Metal logic: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
/* Independent bit truth table, rather than the shader's sixteen expressions. */
static unsigned truth(unsigned source, unsigned destination, unsigned operation,
                      unsigned bits)
{
    static const unsigned table[16] = { 0, 8, 4, 12, 2, 10, 6, 14,
                                        1, 9, 5, 13, 3, 11, 7, 15 };
    unsigned result = 0;
    for (unsigned bit = 0; bit < bits; bit++) {
        unsigned index = ((source >> bit) & 1) * 2 + ((destination >> bit) & 1);
        result |= ((table[operation] >> index) & 1) << bit;
    }
    return result;
}
static unsigned channel_value(unsigned n, unsigned channel, unsigned bits)
{
    return (n * (2 * channel + 1) + 17 * channel) & ((1u << bits) - 1);
}
static NV2AMetalVertex vertex(float x, float y, float size)
{
    NV2AMetalVertex v = { 0 };
    v.clip[0] = x / size * 2 - 1;
    v.clip[1] = 1 - y / size * 2;
    v.clip[2] = .5;
    v.clip[3] = 1;
    v.screen[0] = x;
    v.screen[1] = y;
    v.screen[2] = 32768;
    v.screen[3] = 1;
    const float planes[3][4] = { { 0, 0, 32768, 1 },
                                 { size, 0, 32768, 1 },
                                 { 0, size, 32768, 1 } };
    memcpy(v.plane, planes, sizeof(planes));
    v.texcoord[0][0] = x / size;
    v.texcoord[0][1] = y / size;
    v.texcoord[0][3] = 1;
    return v;
}
static NV2AMetalDrawState *state(unsigned operation, unsigned write_mask)
{
    const unsigned masks[4] = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE,
                                NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE,
                                NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE,
                                NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE };
    NV2AMetalDrawConfig c = { .blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE |
                                       operation << 12 | NV_PGRAPH_BLEND_EN |
                                       7 | 11 << 4 | 11 << 8 };
    for (unsigned i = 0; i < 4; i++)
        if (write_mask & (1u << i))
            c.control[0] |= masks[i];
    NSError *error = nil;
    NV2AMetalDrawState *s =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&c
                                             error:&error];
    require(s != nil, error);
    assert(s.logicEnabled && s.logicOperation == operation);
    assert(s.colorAttachment.blendingState != MTL4BlendStateEnabled);
    return s;
}
static void exhaustive(const LogicFormat *f)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:f->format
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f->format
                                                           width:256
                                                          height:256
                                                       mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
    assert(target);
    d.pixelFormat = MTLPixelFormatRGBA32Float;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:d];
    assert(texture);
    float (*source)[4] = malloc(256 * 256 * 16);
    uint8_t *initial = calloc(256 * 256, f->bytes),
            *output = malloc(256 * 256 * f->bytes);
    assert(source && initial && output);
    for (unsigned y = 0; y < 256; y++)
        for (unsigned x = 0; x < 256; x++) {
            unsigned word = 0;
            for (unsigned k = 0; k < 4; k++) {
                unsigned mask = (1u << f->bits[k]) - 1;
                source[y * 256 + x][k] =
                    mask ? channel_value(x, k, f->bits[k]) / (float)mask :
                           k == 3;
                word |= channel_value(y, k, f->bits[k]) << f->shift[k];
            }
            memcpy(initial + (y * 256 + x) * f->bytes, &word, f->bytes);
        }
    [texture replaceRegion:MTLRegionMake2D(0, 0, 256, 256)
               mipmapLevel:0
                 withBytes:source
               bytesPerRow:256 * 16];
    const float coordinates[6][2] = { { 0, 0 },   { 256, 0 }, { 0, 256 },
                                      { 0, 256 }, { 256, 0 }, { 256, 256 } };
    NV2AMetalVertex vertices[6];
    for (unsigned i = 0; i < 6; i++)
        vertices[i] = vertex(coordinates[i][0], coordinates[i][1], 256);
    id<MTLBuffer> vb =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(vb);
    NV2AMetalPixelTexture textures[4] = { { 0 } };
    textures[0].texture = texture;
    NV2AMetalPixelUniforms u = { .surface_scale = { 1, 1 },
                                 .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, 256, 256 } },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .smooth_shading = 1 };
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    u.textures[0].dimension = 2;
    u.textures[0].scale = 1;
    for (unsigned test = 0; test < 32; test++) {
        unsigned op = test < 16 ? test : 6,
                 write_mask = test < 16 ? 15 : test - 16;
        [target replaceRegion:MTLRegionMake2D(0, 0, 256, 256)
                  mipmapLevel:0
                    withBytes:initial
                  bytesPerRow:256 * f->bytes];
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        require([commands beginWithError:&error] != nil, error);
        require([shader encodeVertices:vb
                                 count:6
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:textures
                                  pass:pass
                             drawState:state(op, write_mask)
                              commands:commands
                                 error:&error],
                error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        [target getBytes:output
             bytesPerRow:256 * f->bytes
              fromRegion:MTLRegionMake2D(0, 0, 256, 256)
             mipmapLevel:0];
        for (unsigned y = 0; y < 256; y++)
            for (unsigned x = 0; x < 256; x++) {
                unsigned expected = 0, actual = 0;
                memcpy(&actual, output + (y * 256 + x) * f->bytes, f->bytes);
                for (unsigned k = 0; k < 4; k++) {
                    unsigned src = channel_value(x, k, f->bits[k]),
                             dst = channel_value(y, k, f->bits[k]);
                    unsigned result = write_mask & (1u << k) ?
                                          truth(src, dst, op, f->bits[k]) :
                                          dst;
                    expected |= result << f->shift[k];
                }
                if (actual != expected) {
                    fprintf(stderr,
                            "Logic format%lu op%u mask%u pixel%u,%u: %08x "
                            "expected%08x\n",
                            (unsigned long)f->format, op, write_mask, x, y,
                            actual, expected);
                    abort();
                }
                pixels_checked++;
            }
        images++;
    }
    free(source);
    free(initial);
    free(output);
}
static void ordered(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:1
                                    height:1
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
    assert(target);
    enum { primitives = 96 };
    NV2AMetalVertex input[primitives * 3];
    for (unsigned p = 0; p < primitives; p++)
        for (unsigned i = 0; i < 3; i++) {
            NV2AMetalVertex v = vertex(i == 1 ? 2 : 0, i == 2 ? 2 : 0, 1);
            for (unsigned k = 0; k < 4; k++)
                v.color[0][k] = channel_value(p, k, 8) / 255.f;
            input[p * 3 + i] = v;
        }
    id<MTLBuffer> vb =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(vb);
    NV2AMetalPixelUniforms u = { .surface_scale = { 1, 1 },
                                 .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, 1, 1 } },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .smooth_shading = 1 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { { 0 } };
    for (unsigned op = 0; op < 16; op++) {
        const uint8_t initial[4] = { 0x51, 0xa5, 0x39, 0xf0 };
        [target replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                  mipmapLevel:0
                    withBytes:initial
                  bytesPerRow:4];
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        require([commands beginWithError:&error] != nil, error);
        require([shader encodeVertices:vb
                                 count:primitives * 3
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:textures
                                  pass:pass
                             drawState:state(op, 15)
                              commands:commands
                                 error:&error],
                error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        uint8_t actual[4];
        [target getBytes:actual
             bytesPerRow:4
              fromRegion:MTLRegionMake2D(0, 0, 1, 1)
             mipmapLevel:0];
        for (unsigned k = 0; k < 4; k++) {
            unsigned expected = initial[k];
            for (unsigned p = 0; p < primitives; p++)
                expected = truth(channel_value(p, k, 8), expected, op, 8);
            if (actual[k] != expected) {
                fprintf(stderr, "Ordered logic op%u channel%u: %u expected%u\n",
                        op, k, actual[k], expected);
                abort();
            }
        }
        images++;
        pixels_checked++;
    }
}
static void float_and_msaa(void)
{
    NSError *error = nil;
    NV2AMetalVertex vertices[3] = { vertex(0, 0, 1), vertex(2, 0, 1),
                                    vertex(0, 2, 1) };
    const float rgba[4] = { .125f, .375f, .625f, .875f };
    for (unsigned i = 0; i < 3; i++)
        memcpy(vertices[i].color[0], rgba, sizeof(rgba));
    id<MTLBuffer> vb =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(vb);
    NV2AMetalPixelUniforms u = { .surface_scale = { 1, 1 },
                                 .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, 1, 1 } },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .smooth_shading = 1 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { { 0 } };
    for (unsigned msaa = 0; msaa < 2; msaa++) {
        MTLPixelFormat format =
            msaa ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA32Float;
        NV2AMetalPixelShader *shader =
            [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                             colorFormat:format
                                             depthFormat:MTLPixelFormatInvalid
                                             sampleCount:msaa ? 4 : 1
                                                   error:&error];
        require(shader != nil, error);
        MTLTextureDescriptor *d =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                               width:1
                                                              height:1
                                                           mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        d.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> result = [commands.device newTextureWithDescriptor:d];
        assert(result);
        id<MTLTexture> target = result;
        if (msaa) {
            d.textureType = MTLTextureType2DMultisample;
            d.sampleCount = 4;
            d.storageMode = MTLStorageModePrivate;
            target = [commands.device newTextureWithDescriptor:d];
            assert(target);
            for (unsigned i = 0; i < 3; i++)
                for (unsigned k = 0; k < 4; k++)
                    vertices[i].color[0][k] = (17 + 31 * k) / 255.f;
            vb = [commands.device
                newBufferWithBytes:vertices
                            length:sizeof(vertices)
                           options:MTLResourceStorageModeShared];
            assert(vb);
        }
        for (unsigned op = 0; op < 16; op++) {
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(
                51 / 255., 102 / 255., 153 / 255., 204 / 255.);
            pass.colorAttachments[0].storeAction =
                msaa ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
            if (msaa)
                pass.colorAttachments[0].resolveTexture = result;
            require([commands beginWithError:&error] != nil, error);
            require([shader encodeVertices:vb
                                     count:3
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:textures
                                      pass:pass
                                 drawState:state(op, 15)
                                  commands:commands
                                     error:&error],
                    error);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            if (msaa) {
                uint8_t actual[4];
                [result getBytes:actual
                     bytesPerRow:4
                      fromRegion:MTLRegionMake2D(0, 0, 1, 1)
                     mipmapLevel:0];
                for (unsigned k = 0; k < 4; k++)
                    assert(actual[k] ==
                           truth(17 + 31 * k, 51 * (k + 1), op, 8));
            } else {
                float actual[4];
                [result getBytes:actual
                     bytesPerRow:16
                      fromRegion:MTLRegionMake2D(0, 0, 1, 1)
                     mipmapLevel:0];
                assert(!memcmp(actual, rgba, sizeof(rgba)));
            }
            images++;
            pixels_checked++;
        }
    }
}
static void points_and_lines(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:1
                                    height:1
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
    assert(target);
    NV2AMetalPixelUniforms u = { .surface_scale = { 1, 1 },
                                 .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, 1, 1 } },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .smooth_shading = 1 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { { 0 } };
    const uint8_t initial[4] = { 51, 102, 153, 204 },
                  source[4] = { 17, 48, 79, 110 };
    for (unsigned line = 0; line < 2; line++) {
        NV2AMetalVertex input[2] = { vertex(line ? 0 : .5f, .5f, 1),
                                     vertex(1, .5f, 1) };
        for (unsigned i = 0; i < 2; i++) {
            input[i].point_size = 1;
            for (unsigned k = 0; k < 4; k++)
                input[i].color[0][k] = source[k] / 255.f;
        }
        id<MTLBuffer> vb =
            [commands.device newBufferWithBytes:input
                                         length:sizeof(input)
                                        options:MTLResourceStorageModeShared];
        assert(vb);
        for (unsigned op = 0; op < 16; op++) {
            [target replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                      mipmapLevel:0
                        withBytes:initial
                      bytesPerRow:4];
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            require([commands beginWithError:&error] != nil, error);
            require([shader encodeVertices:vb
                                     count:line ? 2 : 1
                                 primitive:line ? MTLPrimitiveTypeLine :
                                                  MTLPrimitiveTypePoint
                                  uniforms:&u
                                  textures:textures
                                      pass:pass
                                 drawState:state(op, 15)
                                  commands:commands
                                     error:&error],
                    error);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            uint8_t actual[4];
            [target getBytes:actual
                 bytesPerRow:4
                  fromRegion:MTLRegionMake2D(0, 0, 1, 1)
                 mipmapLevel:0];
            for (unsigned k = 0; k < 4; k++)
                assert(actual[k] == truth(source[k], initial[k], op, 8));
            images++;
            pixels_checked++;
        }
    }
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); i++)
            exhaustive(&formats[i]);
        ordered();
        float_and_msaa();
        points_and_lines();
        printf("Metal 4 logic: %u images, %lu bit-exact pixels PASS\n", images,
               pixels_checked);
    }
    return 0;
}
