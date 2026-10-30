/* Native draw/clear dithering tests; no app, VM or window is started.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
#include <math.h>
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
        fprintf(stderr, "Metal dither: %s\n",
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
static double blend_factor(unsigned factor, unsigned channel,
                           const double source[4], const double destination[4],
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
    case 15:
        return 1 - constant[3];
    default:
        abort();
    }
}

static double blend_value(unsigned equation, unsigned sf, unsigned df,
                          unsigned channel, const double source[4],
                          const double destination[4], const double constant[4])
{
    double a = source[channel], b = destination[channel];
    if (equation == 3) {
        return fmin(a, b);
    }
    if (equation == 4) {
        return fmax(a, b);
    }
    a *= blend_factor(sf, channel, source, destination, constant);
    b *= blend_factor(df, channel, source, destination, constant);
    return equation == 0                  ? a - b :
           equation == 1 || equation == 5 ? b - a :
                                            a + b;
}


static double bound(double v)
{
    return fmin(1, fmax(0, v));
}
static unsigned quantize(double value, unsigned bits, unsigned x, unsigned y)
{
    unsigned rank = 0;
    for (unsigned b = 0; b < 2; b++) {
        unsigned xx = (x >> b) & 1, yy = (y >> b) & 1;
        rank += (2 * (xx ^ yy) + yy) << (2 * (1 - b));
    }
    double v = bound(value) * ((1u << bits) - 1), threshold = (rank + .5) / 16.;
    return (unsigned)floor(v) + (v - floor(v) >= threshold);
}
static void validate(const LogicFormat *f, const uint8_t *actual,
                     const uint8_t *initial, const float (*source)[4],
                     unsigned equation, unsigned sf, unsigned df, unsigned op,
                     unsigned write_mask, bool clear)
{
    const double constant[4] = { 51 / 255., 102 / 255., 153 / 255.,
                                 204 / 255. };
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            unsigned old = 0, word = 0;
            memcpy(&old, initial + (y * 16 + x) * f->bytes, f->bytes);
            memcpy(&word, actual + (y * 16 + x) * f->bytes, f->bytes);
            double s[4], d[4];
            for (unsigned k = 0; k < 4; k++) {
                unsigned mask = (1u << f->bits[k]) - 1;
                s[k] = bound(source[y * 16 + x][k]);
                d[k] = mask ? ((old >> f->shift[k]) & mask) / (double)mask :
                              k == 3;
            }
            for (unsigned k = 0; k < 4; k++) {
                unsigned bits = f->bits[k], mask = (1u << bits) - 1;
                if (!bits)
                    continue;
                unsigned expected = (old >> f->shift[k]) & mask;
                bool inside = !clear || (x >= 1 && x < 12 && y >= 2 && y < 11);
                double value = s[k];
                if ((write_mask & (1u << k)) && inside) {
                    if (!clear && op == 16 && equation < 7)
                        value =
                            blend_value(equation, sf, df, k, s, d, constant);
                    expected = quantize(value, bits, x, y);
                    if (op < 16)
                        expected = truth(expected, (old >> f->shift[k]) & mask,
                                         op, bits);
                }
                unsigned got = (word >> f->shift[k]) & mask;
                if (got != expected) {
                    // Independent double and shader float arithmetic can differ
                    // on an exact ordered-quantization threshold by a single
                    // bit.
                    double scaled = bound(value) * mask;
                    unsigned rank = 0;
                    for (unsigned b = 0; b < 2; b++) {
                        unsigned xx = (x >> b) & 1, yy = (y >> b) & 1;
                        rank += (2 * (xx ^ yy) + yy) << (2 * (1 - b));
                    }
                    bool boundary = !clear && op == 16 &&
                                    fabs(scaled - floor(scaled) -
                                         (rank + .5) / 16.) < .00002 &&
                                    abs((int)got - (int)expected) == 1;
                    if (!boundary) {
                        fprintf(
                            stderr,
                            "Dither format%lu image%u eq%u sf%u df%u op%u "
                            "pixel%u,%u channel%u: %u expected%u value%.12g\n",
                            (unsigned long)f->format, images, equation, sf, df,
                            op, x, y, k, got, expected, value);
                        abort();
                    }
                }
            }
            pixels_checked++;
        }
}
static void test_format(const LogicFormat *f)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:f->format
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    NV2AMetalClear *clearer =
        [[NV2AMetalClear alloc] initWithDevice:commands.device error:&error];
    require(clearer != nil, error);
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f->format
                                                           width:16
                                                          height:16
                                                       mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:desc];
    assert(target);
    desc.pixelFormat = MTLPixelFormatRGBA32Float;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [commands.device newTextureWithDescriptor:desc];
    assert(tex);
    uint8_t initial[1024] = { 0 }, actual[1024];
    float source[256][4];
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            unsigned word = 0;
            for (unsigned k = 0; k < 4; k++)
                word |= channel_value(x + 3 * y, k, f->bits[k]) << f->shift[k];
            memcpy(initial + (y * 16 + x) * f->bytes, &word, f->bytes);
            source[y * 16 + x][0] = (x + .375f) / 15;
            source[y * 16 + x][1] = (y + .375f) / 15;
            source[y * 16 + x][2] = (x + y + .375f) / 30;
            source[y * 16 + x][3] = (x + 2 * y + .375f) / 45;
        }
    [tex replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
           mipmapLevel:0
             withBytes:source
           bytesPerRow:256];
    const float xy[6][2] = { { 0, 0 },  { 16, 0 }, { 0, 16 },
                             { 0, 16 }, { 16, 0 }, { 16, 16 } };
    NV2AMetalVertex v[6];
    for (unsigned i = 0; i < 6; i++)
        v[i] = vertex(xy[i][0], xy[i][1], 16);
    id<MTLBuffer> vb =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(vb);
    NV2AMetalPixelUniforms u = { .surface_scale = { 1, 1 },
                                 .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, 16, 16 } },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .smooth_shading = 1 };
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    u.textures[0].dimension = 2;
    u.textures[0].scale = 1;
    NV2AMetalPixelTexture textures[4] = { { 0 } };
    textures[0].texture = tex;
    const unsigned masks[4] = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE,
                                NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE,
                                NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE,
                                NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE };
    for (unsigned test = 0; test < 1607; test++) {
        unsigned eq = 7, sf = 0, df = 0, op = 16, write_mask = 15;
        if (test < 1575) {
            eq = test / 225;
            sf = test % 225 / 15;
            df = test % 15;
            sf += sf >= 11;
            df += df >= 11;
        } else if (test < 1591)
            op = test - 1575;
        else
            write_mask = test - 1591;
        NV2AMetalDrawConfig cfg = { .blend_color = 0xcc336699 };
        cfg.control[0] = NV_PGRAPH_CONTROL_0_DITHERENABLE;
        for (unsigned k = 0; k < 4; k++)
            if (write_mask & (1u << k))
                cfg.control[0] |= masks[k];
        if (eq < 7)
            cfg.blend = NV_PGRAPH_BLEND_EN | eq | sf << 4 | df << 8;
        if (op < 16)
            cfg.blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE | op << 12 |
                        NV_PGRAPH_BLEND_EN | 7 | 11 << 4 | 11 << 8;
        NV2AMetalDrawState *state =
            [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                config:&cfg
                                                 error:&error];
        require(state != nil, error);
        [target replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
                  mipmapLevel:0
                    withBytes:initial
                  bytesPerRow:16 * f->bytes];
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
                             drawState:state
                              commands:commands
                                 error:&error],
                error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        [target getBytes:actual
             bytesPerRow:16 * f->bytes
              fromRegion:MTLRegionMake2D(0, 0, 16, 16)
             mipmapLevel:0];
        validate(f, actual, initial, source, eq, sf, df, op, write_mask, false);
        images++;
    }
    const unsigned clear_masks[4] = { NV097_CLEAR_SURFACE_R,
                                      NV097_CLEAR_SURFACE_G,
                                      NV097_CLEAR_SURFACE_B,
                                      NV097_CLEAR_SURFACE_A };
    for (unsigned mask = 0; mask < 16; mask++) {
        NV2AMetalClearConfig cfg = {
            .dither = YES,
            .rect = { 1, 2, 11, 9 },
            .uniforms = { .color = { .137f, .419f, .673f, .851f } }
        };
        for (unsigned k = 0; k < 4; k++)
            if (mask & (1u << k))
                cfg.parameter |= clear_masks[k];
        for (unsigned i = 0; i < 256; i++)
            memcpy(source[i], cfg.uniforms.color, 16);
        [target replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
                  mipmapLevel:0
                    withBytes:initial
                  bytesPerRow:16 * f->bytes];
        require([commands beginWithError:&error] != nil, error);
        require([clearer encodeColor:target
                                zeta:nil
                              config:&cfg
                            commands:commands
                               error:&error],
                error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        [target getBytes:actual
             bytesPerRow:16 * f->bytes
              fromRegion:MTLRegionMake2D(0, 0, 16, 16)
             mipmapLevel:0];
        validate(f, actual, initial, source, 7, 0, 0, 16, mask, true);
        images++;
    }
}
static void float_targets(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:1
                                    height:1
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
    assert(target);
    const float rgba[4] = { .125f, .375f, 1.125f, .875f };
    NV2AMetalVertex v[3] = { vertex(0, 0, 1), vertex(2, 0, 1),
                             vertex(0, 2, 1) };
    for (unsigned i = 0; i < 3; i++)
        memcpy(v[i].color[0], rgba, 16);
    id<MTLBuffer> vb =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
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
    const double dest[4] = { .25, .5, .75, 1 },
                 src[4] = { .125, .375, 1.125, .875 }, constant[4] = { 0 };
    for (unsigned eq = 0; eq < 7; eq++) {
        NV2AMetalDrawConfig cfg = {
            .control = { NV_PGRAPH_CONTROL_0_DITHERENABLE |
                         NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE },
            .blend = NV_PGRAPH_BLEND_EN | eq | 1 << 4 | 1 << 8
        };
        NV2AMetalDrawState *state =
            [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                config:&cfg
                                                 error:&error];
        require(state != nil, error);
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(.25, .5, .75, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        require([commands beginWithError:&error] != nil, error);
        require([shader encodeVertices:vb
                                 count:3
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:textures
                                  pass:pass
                             drawState:state
                              commands:commands
                                 error:&error],
                error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        float actual[4];
        [target getBytes:actual
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(0, 0, 1, 1)
             mipmapLevel:0];
        for (unsigned k = 0; k < 4; k++)
            assert(fabs(actual[k] -
                        blend_value(eq, 1, 1, k, src, dest, constant)) < 1e-6);
        images++;
        pixels_checked++;
    }
    NV2AMetalClear *clearer =
        [[NV2AMetalClear alloc] initWithDevice:commands.device error:&error];
    require(clearer != nil, error);
    NV2AMetalClearConfig c = { .dither = YES,
                               .parameter = NV097_CLEAR_SURFACE_COLOR,
                               .rect = { 0, 0, 1, 1 },
                               .uniforms = { .color = { -.125f, .375f, 1.125f,
                                                        .875f } } };
    require([commands beginWithError:&error] != nil, error);
    require([clearer encodeColor:target
                            zeta:nil
                          config:&c
                        commands:commands
                           error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    float actual[4];
    [target getBytes:actual
         bytesPerRow:16
          fromRegion:MTLRegionMake2D(0, 0, 1, 1)
         mipmapLevel:0];
    assert(!memcmp(actual, c.uniforms.color, 16));
    images++;
    pixels_checked++;
}
static void raster_samples(void)
{
    NSError *error = nil;
    const float rgba[4] = { .137f, .419f, .673f, .851f };
    for (unsigned test = 0; test < 5; test++) {
        unsigned samples = test >= 3 ? 4 : 1;
        NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA8Unorm
               depthFormat:MTLPixelFormatInvalid
               sampleCount:samples
                     error:&error];
        require(shader != nil, error);
        MTLTextureDescriptor *d = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:4
                                        height:4
                                     mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        d.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> result = [commands.device newTextureWithDescriptor:d];
        assert(result);
        id<MTLTexture> target = result;
        if (samples == 4) {
            d.textureType = MTLTextureType2DMultisample;
            d.sampleCount = 4;
            d.storageMode = MTLStorageModePrivate;
            target = [commands.device newTextureWithDescriptor:d];
            assert(target);
        }
        NV2AMetalPixelUniforms u = { .surface_scale = { 1, 1 },
                                     .clip_range = { 0, 65535, 0, 65535 },
                                     .clip_regions = { { 0, 0, 4, 4 } },
                                     .depth_format = NV2AMetalPixelDepthD16,
                                     .smooth_shading = 1 };
        u.combiner.final_inputs[0] = PS_REGISTER_V0;
        u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
        NV2AMetalVertex v[16];
        unsigned count = 0;
        if (test == 0) {
            for (unsigned y = 0; y < 4; y++)
                for (unsigned x = 0; x < 4; x++) {
                    v[count] = vertex(x + .5f, y + .5f, 4);
                    v[count++].point_size = 1;
                }
        } else if (test == 1) {
            for (unsigned y = 0; y < 4; y++) {
                v[count++] = vertex(0, y + .5f, 4);
                v[count++] = vertex(4, y + .5f, 4);
            }
        } else {
            v[count++] = vertex(0, 0, 4);
            v[count++] = vertex(8, 0, 4);
            v[count++] = vertex(0, 8, 4);
        }
        for (unsigned i = 0; i < count; i++)
            memcpy(v[i].color[0], rgba, 16);
        id<MTLBuffer> vb =
            [commands.device newBufferWithBytes:v
                                         length:count * sizeof(*v)
                                        options:MTLResourceStorageModeShared];
        assert(vb);
        NV2AMetalDrawConfig cfg = {
            .control = { NV_PGRAPH_CONTROL_0_DITHERENABLE |
                         NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE }
        };
        if (test == 4)
            cfg.blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
        NV2AMetalDrawState *state =
            [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                config:&cfg
                                                 error:&error];
        require(state != nil, error);
        NV2AMetalPixelTexture textures[4] = { { 0 } };
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(51 / 255., 102 / 255., 153 / 255., 204 / 255.);
        pass.colorAttachments[0].storeAction =
            samples == 4 ? MTLStoreActionStoreAndMultisampleResolve :
                           MTLStoreActionStore;
        if (samples == 4)
            pass.colorAttachments[0].resolveTexture = result;
        require([commands beginWithError:&error] != nil, error);
        require([shader encodeVertices:vb
                                 count:count
                             primitive:test == 0 ? MTLPrimitiveTypePoint :
                                       test == 1 ? MTLPrimitiveTypeLine :
                                                   MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:textures
                                  pass:pass
                             drawState:state
                              commands:commands
                                 error:&error],
                error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        uint8_t actual[16][4];
        [result getBytes:actual
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0];
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 4; x++)
                for (unsigned k = 0; k < 4; k++) {
                    double value = rgba[k];
                    if (test == 4)
                        value = value * rgba[3] +
                                (51 * (k + 1) / 255.) * (1 - rgba[3]);
                    assert(actual[y * 4 + x][k] == quantize(value, 8, x, y));
                }
        images++;
        pixels_checked += 16;
        if (samples == 4) {
            NV2AMetalClear *clearer =
                [[NV2AMetalClear alloc] initWithDevice:commands.device
                                                 error:&error];
            require(clearer != nil, error);
            NV2AMetalClearConfig c = { .dither = YES,
                                       .parameter = NV097_CLEAR_SURFACE_COLOR,
                                       .rect = { 0, 0, 4, 4 } };
            memcpy(c.uniforms.color, rgba, 16);
            require([commands beginWithError:&error] != nil, error);
            require([clearer encodeColor:target
                                    zeta:nil
                                  config:&c
                                commands:commands
                                   error:&error],
                    error);
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            id<MTL4RenderCommandEncoder> encoder = [commands.commandBuffer
                renderCommandEncoderWithDescriptor:pass];
            assert(encoder);
            [encoder barrierAfterQueueStages:MTLStageAll
                                beforeStages:MTLStageAll
                           visibilityOptions:MTL4VisibilityOptionDevice];
            [encoder endEncoding];
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            [result getBytes:actual
                 bytesPerRow:16
                  fromRegion:MTLRegionMake2D(0, 0, 4, 4)
                 mipmapLevel:0];
            for (unsigned y = 0; y < 4; y++)
                for (unsigned x = 0; x < 4; x++)
                    for (unsigned k = 0; k < 4; k++)
                        assert(actual[y * 4 + x][k] ==
                               quantize(rgba[k], 8, x, y));
            images++;
            pixels_checked += 16;
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
            test_format(&formats[i]);
        float_targets();
        raster_samples();
        printf("Metal 4 dither: %u images, %lu pixels PASS\n", images,
               pixels_checked);
    }
    return 0;
}
