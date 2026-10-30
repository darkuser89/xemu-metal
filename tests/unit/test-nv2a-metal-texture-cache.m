/* Offscreen native texture/surface coherence tests; no VM/window/app.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/texture-cache.h"
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-snapshot.h"
#include "hw/xbox/nv2a/pgraph/metal/geometry-types.h"
#import <objc/runtime.h>
#include "test-metal-texture-readback.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static NV2AMetalCommands *commands;
static NV2AMetalSurfaceCache *surfaces;
static NV2AMetalTextureCache *textures;
static NV2AMetalClear *clearer;
static unsigned checks, notifications;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Texture cache: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static NV2AMetalSamplerConfig policy(void)
{
    return (NV2AMetalSamplerConfig){ .filter = 1 << 16 | 1 << 24,
                                     .address = 3 | 3 << 8 | 3 << 16,
                                     .anisotropy = 1 };
}
static NV2AMetalTextureSource source(NSUInteger address, unsigned format,
                                     unsigned width, unsigned pitch)
{
    return (NV2AMetalTextureSource){ .shape = { .format = format,
                                                .dimension = 2,
                                                .width = width,
                                                .height = 4,
                                                .depth = 1,
                                                .levels = 1,
                                                .pitch = pitch },
                                     .address = address,
                                     .length = pitch * 4 };
}
static NV2AMetalCachedTexture *prepare(NV2AMetalTextureSource c)
{
    NSError *error = nil;
    NV2AMetalSamplerConfig sampler = policy();
    NV2AMetalCachedTexture *result = [textures prepareSource:&c
                                                     sampler:&sampler
                                                       frame:1
                                                       error:&error];
    require(result != nil, error);
    return result;
}
static void finish(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceRecording *token = surfaces.recording;
    assert(token && !token.submitted && !token.completed && !token.cancelled);
    require([surfaces submitWithError:&error], error);
    assert(token.submitted && !token.completed && !surfaces.recording);
    require([surfaces waitUntilIdleWithError:&error], error);
    assert(token.completed && !token.cancelled);
}
static void cpu_write(NSUInteger address, NSUInteger length)
{
    NSError *error = nil;
    require([surfaces prepareCPUAccessAtAddress:address
                                         length:length
                                          write:YES
                                          error:&error],
            error);
}
static id<MTLBuffer> read_texture(NV2AMetalCachedTexture *t)
{
    return test_metal_read_texture(commands, t.binding.texture, 0, 0);
}

static void color_at(id<MTLBuffer> out, unsigned width, unsigned x, unsigned y,
                     float r, float g, float b, float a)
{
    NSUInteger row = ((NSUInteger)width * 16 + 255) & ~(NSUInteger)255;
    const float *p =
        (const float *)((const unsigned char *)out.contents + y * row + x * 16);
    const float expected[] = { r, g, b, a };
    for (unsigned k = 0; k < 4; k++) {
        if (fabsf(p[k] - expected[k]) > .000001f) {
            fprintf(stderr, "Texel %u,%u channel %u: %g expected %g\n", x, y, k,
                    p[k], expected[k]);
            abort();
        }
    }
}
static void ordinary_and_cancel_tests(void)
{
    NSError *error = nil;
    NV2AMetalTextureSource c =
        source(4096, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    cpu_write(c.address, c.length);
    uint32_t *vram =
        (uint32_t *)((unsigned char *)surfaces.vram.contents + c.address);
    for (unsigned i = 0; i < 16; i++)
        vram[i] = 0xff030201 + i;
    NV2AMetalCachedTexture *first = prepare(c);
    assert(![first validateCompletedWithError:&error]);
    NV2AMetalCachedTexture *again = prepare(c);
    assert(first.binding.texture == again.binding.texture &&
           textures.count == 1);
    id<MTLBuffer> out = read_texture(first);
    finish();
    require([first validateCompletedWithError:&error], error);
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++)
            color_at(out, 4, x, y, 3.f / 255, 2.f / 255,
                     (1.f + y * 4 + x) / 255, 1);
    cpu_write(8192, 1);
    NV2AMetalSamplerConfig sampler = policy();
    sampler.filter = 2 << 16 | 2 << 24;
    again = [textures prepareSource:&c sampler:&sampler frame:2 error:&error];
    require(again != nil, error);
    assert(again.binding.texture == first.binding.texture &&
           again.binding.sampling.mag_linear);
    finish();
    cpu_write(c.address + c.length - 1, 1);
    ((unsigned char *)surfaces.vram.contents)[c.address + c.length - 1] = 0x55;
    again = prepare(c);
    assert(again.binding.texture != first.binding.texture);
    out = read_texture(again);
    finish();
    color_at(out, 4, 3, 3, 3.f / 255, 2.f / 255, 16.f / 255, 0x55 / 255.f);
    checks++;
    c.address = 12288;
    cpu_write(c.address, c.length);
    memset((unsigned char *)surfaces.vram.contents + c.address, 0, c.length);
    first = prepare(c);
    NV2AMetalSurfaceRecording *cancelled = surfaces.recording;
    [surfaces cancel];
    assert(cancelled.cancelled && !cancelled.submitted && !cancelled.completed);
    assert(![first validateCompletedWithError:&error]);
    again = prepare(c);
    assert(again.binding.texture != first.binding.texture);
    out = read_texture(again);
    finish();
    color_at(out, 4, 0, 0, 0, 0, 0, 0);
    checks++;
}
static NV2AMetalCachedSurface *surface(NSUInteger address, unsigned format,
                                       BOOL color, unsigned bytes,
                                       unsigned scale)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = { .format = format,
                                 .width = 4,
                                 .height = 4,
                                 .pitch = 4 * bytes,
                                 .scale = scale,
                                 .color = color };
    NV2AMetalCachedSurface *s = [surfaces prepareSurfaceAtAddress:address
                                                           config:&c
                                                            frame:1
                                                            error:&error];
    require(s != nil, error);
    return s;
}
static void clear(NV2AMetalCachedSurface *s, NV2AMetalClearConfig c)
{
    NSError *error = nil;
    require([clearer
                encodeColor:s.transfer.config.color ? s.transfer.texture : nil
                       zeta:s.transfer.config.color ? nil : s.transfer.texture
                     config:&c
                   commands:commands
                      error:&error],
            error);
    require([surfaces markWritten:s error:&error], error);
}
static void rtt_color_at(id<MTLBuffer> out, unsigned width, unsigned x,
                         unsigned y, unsigned format, float r, float g, float b,
                         float a)
{
    if (format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8)
        color_at(out, width, x, y, b, g, r, a);
    else if (format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8)
        color_at(out, width, x, y, a, r, g, b);
    else
        color_at(out, width, x, y, r, g, b, a);
}
static void rtt_tests(void)
{
    NSError *error = nil;
    const unsigned surface_formats[] = {
        1, 3, 4, 8, 8, 8, 3, 4, 8, 2, 5, 6, 7
    };
    const unsigned texture_formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8
    };
    for (unsigned f = 0; f < 13; f++) {
        unsigned bytes = f < 2 || f == 6 || f == 9 ? 2 : 4;
        NSUInteger address = 16384 + f * 4096;
        cpu_write(address, 4 * 4 * bytes);
        memset((unsigned char *)surfaces.vram.contents + address, 0x31,
               4 * 4 * bytes);
        NV2AMetalSurfaceConfig layout = { .format = surface_formats[f],
                                          .width = 4,
                                          .height = 4,
                                          .pitch = 4 * bytes,
                                          .scale = 2,
                                          .color = YES,
                                          .swizzle = f >= 6 && f < 9 };
        NV2AMetalCachedSurface *s = [surfaces prepareSurfaceAtAddress:address
                                                               config:&layout
                                                                frame:1
                                                                error:&error];
        require(s != nil, error);
        NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                   .rect = { 0, 0, 8, 8 },
                                   .uniforms = { .color = { 1, 0, 0, 0 },
                                                 .depth = 0 } };
        clear(s, c);
        c.rect = (MTLScissorRect){ 4, 2, 2, 4 };
        c.uniforms.color[0] = 0;
        c.uniforms.color[2] = 1;
        clear(s, c);
        NV2AMetalTextureSource src =
            source(address, texture_formats[f], 4, 4 * bytes);
        unsigned before = notifications;
        NV2AMetalCachedTexture *t = prepare(src);
        assert(t.scale == 2 && t.binding.texture.width == 8 && s.dirty);
        assert(t.binding.texture.pixelFormat == (bytes == 4 ?
            MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA32Float));
        id<MTLBuffer> out = read_texture(t);
        finish();
        require([t validateCompletedWithError:&error], error);
        assert(notifications == before && s.dirty);
        const unsigned char *ram = surfaces.vram.contents;
        for (unsigned i = 0; i < 4 * 4 * bytes; i++)
            assert(ram[address + i] == 0x31);
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                BOOL blue = x >= 4 && x < 6 && y >= 2 && y < 6;
                rtt_color_at(out, 8, x, y, texture_formats[f], !blue, 0, blue,
                             (surface_formats[f] == 8 ||
                              surface_formats[f] == 6 ||
                              surface_formats[f] == 7) ?
                                 0 :
                                 1);
            }
        s = [surfaces prepareSurfaceAtAddress:address
                                       config:&layout
                                        frame:1
                                        error:&error];
        require(s != nil, error);
        c.rect = (MTLScissorRect){ 0, 0, 8, 8 };
        c.uniforms.color[0] = c.uniforms.color[2] = 0;
        c.uniforms.color[1] = 1;
        clear(s, c);
        NV2AMetalCachedTexture *next = prepare(src);
        assert(next.binding.texture != t.binding.texture);
        id<MTLBuffer> old = read_texture(t), updated = read_texture(next);
        finish();
        rtt_color_at(old, 8, 4, 2, texture_formats[f], 0, 0, 1,
                     (surface_formats[f] == 8 || surface_formats[f] == 6 ||
                      surface_formats[f] == 7) ?
                         0 :
                         1);
        rtt_color_at(updated, 8, 4, 2, texture_formats[f], 0, 1, 0,
                     (surface_formats[f] == 8 || surface_formats[f] == 6 ||
                      surface_formats[f] == 7) ?
                         0 :
                         1);
        assert(notifications == before);
        s = [surfaces prepareSurfaceAtAddress:address
                                       config:&layout
                                        frame:2
                                        error:&error];
        require(s != nil, error);
        c.uniforms.color[0] = 1;
        clear(s, c);
        NV2AMetalCachedTexture *cancelled = prepare(src);
        [surfaces cancel];
        assert(![cancelled validateCompletedWithError:&error]);
        NV2AMetalCachedTexture *reused = prepare(src);
        assert(reused.binding.texture == next.binding.texture);
        finish();
        checks++;
    }
}
static void compact_rtt_tests(void)
{
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
    };
    const unsigned textureFormats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8,
    };
    const unsigned order[3][4] = { { 0, 1, 2, 3 }, { 2, 1, 0, 3 },
                                   { 3, 0, 1, 2 } };
    unsigned captures = 0, channels = 0;
    NSUInteger compactAllocation = 0, floatAllocation = 0;
    for (unsigned f = 0; f < 5; f++) {
        for (unsigned scale = 1; scale <= 2; scale++) {
            for (unsigned permutation = 0; permutation < (f < 2 ? 1u : 3u);
                 permutation++) {
                NSError *error = nil;
                const NSUInteger address = 114688;
                cpu_write(address, 16 * 16 * 4);
                memset((uint8_t *)surfaces.vram.contents + address, 0x31, 1024);
                NV2AMetalSurfaceConfig c = { .format = formats[f],
                    .width = 16, .height = 16, .pitch = 64,
                    .scale = scale, .color = YES };
                NV2AMetalCachedSurface *s =
                    [surfaces prepareSurfaceAtAddress:address config:&c
                                                frame:3 error:&error];
                require(s != nil, error);
                for (unsigned i = 0; i < 256; i++) {
                    const uint8_t rgba[] = { i, 255 - i, i * 71, i * 29 + 7 };
                    NV2AMetalClearConfig clearConfig = {
                        .parameter = NV097_CLEAR_SURFACE_COLOR,
                        .rect = { i % 16 * scale, i / 16 * scale, scale, scale },
                    };
                    for (unsigned k = 0; k < 4; k++) {
                        clearConfig.uniforms.color[k] = rgba[k] / 255.f;
                    }
                    clear(s, clearConfig);
                }
                unsigned textureFormat = f < 2 ?
                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 :
                    textureFormats[permutation];
                NV2AMetalTextureSource src = source(address, textureFormat, 16, 64);
                src.shape.height = 16;
                src.length = 1024;
                unsigned before = notifications;
                NV2AMetalCachedTexture *t = prepare(src);
                assert(t.binding.texture.pixelFormat == MTLPixelFormatRGBA8Unorm);
                assert(t.scale == scale && t.binding.texture.width == 16 * scale);
                NV2AMetalCachedTexture *hit = prepare(src);
                assert(hit.binding.texture == t.binding.texture);
                id<MTLBuffer> original = read_texture(t);
                NV2AMetalClearConfig overwrite = {
                    .parameter = NV097_CLEAR_SURFACE_COLOR,
                    .rect = { 0, 0, 16 * scale, 16 * scale },
                    .uniforms = { .color = { 1, 0, 0, 0 } },
                };
                clear(s, overwrite);
                NV2AMetalCachedTexture *updated = prepare(src);
                assert(updated.binding.texture != t.binding.texture);
                id<MTLBuffer> old = read_texture(t), fresh = read_texture(updated);
                finish();
                require([t validateCompletedWithError:&error], error);
                require([updated validateCompletedWithError:&error], error);
                assert(s.dirty && before == notifications);
                for (unsigned i = 0; i < 1024; i++) {
                    assert(((uint8_t *)surfaces.vram.contents)[address + i] == 0x31);
                }
                NSData *snapshot = nv2a_metal_texture_snapshot(
                    t.binding.texture, commands, &error);
                require(snapshot != nil, error);
                unsigned width = 16 * scale;
                assert(snapshot.length == 40 + width * width * 4);
                const uint8_t *bytes = (const uint8_t *)snapshot.bytes + 40;
                NSUInteger row = (width * 16 + 255) & ~(NSUInteger)255;
                for (unsigned y = 0; y < width; y++) {
                    for (unsigned x = 0; x < width; x++) {
                        unsigned i = (y / scale) * 16 + x / scale;
                        const uint8_t rgba[] = { i, 255 - i, i * 71,
                                                f < 2 ? 255 : i * 29 + 7 };
                        const uint8_t replacement[] = { 255, 0, 0, f < 2 ? 255 : 0 };
                        const float *a = (const float *)((uint8_t *)original.contents +
                                                       y * row + x * 16);
                        const float *b = (const float *)((uint8_t *)old.contents +
                                                       y * row + x * 16);
                        const float *n = (const float *)((uint8_t *)fresh.contents +
                                                       y * row + x * 16);
                        for (unsigned k = 0; k < 4; k++) {
                            uint8_t expected = rgba[order[permutation][k]];
                            assert(a[k] == expected / 255.f && b[k] == a[k]);
                            assert(n[k] == replacement[order[permutation][k]] / 255.f);
                            assert(bytes[(y * width + x) * 4 + k] == expected);
                            channels++;
                        }
                    }
                }
                id<MTLTexture> restored =
                    nv2a_metal_texture_restore(snapshot, commands, &error);
                require(restored != nil, error);
                assert(restored.pixelFormat == MTLPixelFormatRGBA8Unorm);
                NSData *again = nv2a_metal_texture_snapshot(restored, commands, &error);
                require(again != nil, error);
                assert([snapshot isEqualToData:again]);
                if (f == 4 && scale == 2 && !permutation) {
                    MTLTextureDescriptor *td = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                    width:width height:width mipmapped:NO];
                    td.storageMode = MTLStorageModePrivate;
                    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                    id<MTLTexture> control = [commands.device newTextureWithDescriptor:td];
                    assert(control);
                    compactAllocation = t.binding.texture.allocatedSize;
                    floatAllocation = control.allocatedSize;
                }
                captures++;
            }
        }
    }
    printf("Metal4 compact RTT: %u captures/cache hits/old-new isolation/"
           "restore-resave cycles, %u exact channels and raw snapshot bytes; "
           "32x32 allocation RGBA8/Float32 %lu/%lu bytes PASS\n",
           captures, channels, (unsigned long)compactAllocation,
           (unsigned long)floatAllocation);
    checks++;
}

static unsigned layout_morton(unsigned x, unsigned y)
{
    return (x & 1) | (y & 1) << 1 | (x & 2) << 1 | (y & 2) << 2;
}
static void rtt_layout_and_channel_tests(void)
{
    const unsigned formats[2][3] = {
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8 },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 }
    };
    for (unsigned swizzle = 0; swizzle < 2; swizzle++)
        for (unsigned linear = 0; linear < 2; linear++)
            for (unsigned scale = 1; scale <= 2; scale++)
                for (unsigned order = 0; order < 3; order++) {
                    NSError *error = nil;
                    const NSUInteger address = 114688;
                    cpu_write(address, 64);
                    memset((unsigned char *)surfaces.vram.contents + address, 0,
                           64);
                    NV2AMetalSurfaceConfig layout = {
                        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                        .width = 4,
                        .height = 4,
                        .pitch = 16,
                        .scale = scale,
                        .color = YES,
                        .swizzle = swizzle
                    };
                    NV2AMetalCachedSurface *s =
                        [surfaces prepareSurfaceAtAddress:address
                                                   config:&layout
                                                    frame:3
                                                    error:&error];
                    require(s != nil, error);
                    unsigned words[16];
                    for (unsigned y = 0; y < 4; y++)
                        for (unsigned x = 0; x < 4; x++) {
                            unsigned r = 17 * (1 + x * 3 + y);
                            unsigned g = 17 * (2 + x + y * 3);
                            unsigned b = 17 * (3 + x + y);
                            unsigned a = 17 * (4 + x * 2 + y);
                            words[swizzle ? layout_morton(x, y) : y * 4 + x] =
                                a << 24 | r << 16 | g << 8 | b;
                            NV2AMetalClearConfig c = {
                                .parameter = NV097_CLEAR_SURFACE_COLOR,
                                .rect = { x * scale, y * scale, scale, scale },
                                .uniforms = { .color = { r / 255.f, g / 255.f,
                                                         b / 255.f,
                                                         a / 255.f } }
                            };
                            clear(s, c);
                        }
                    NV2AMetalTextureSource src =
                        source(address, formats[linear][order], 4, 16);
                    unsigned before = notifications;
                    NV2AMetalCachedTexture *t = prepare(src);
                    BOOL direct = swizzle != linear && (linear || order == 0);
                    assert(t.scale == (direct ? scale : 1));
                    id<MTLBuffer> out = read_texture(t);
                    finish();
                    unsigned output_scale = direct ? scale : 1;
                    for (unsigned y = 0; y < 4 * output_scale; y++)
                        for (unsigned x = 0; x < 4 * output_scale; x++) {
                            unsigned tx = x / output_scale,
                                     ty = y / output_scale;
                            unsigned word =
                                words[linear ? ty * 4 + tx :
                                               layout_morton(tx, ty)];
                            const float argb[] = { (word >> 24) / 255.f,
                                                   ((word >> 16) & 255) / 255.f,
                                                   ((word >> 8) & 255) / 255.f,
                                                   (word & 255) / 255.f };
                            color_at(out, 4 * output_scale, x, y,
                                     order == 0 ? argb[1] :
                                     order == 1 ? argb[3] :
                                                  argb[0],
                                     order == 2 ? argb[1] : argb[2],
                                     order == 0 ? argb[3] :
                                     order == 1 ? argb[1] :
                                                  argb[2],
                                     order == 2 ? argb[3] : argb[0]);
                        }
                    if (direct)
                        assert(s.dirty && notifications == before);
                    else {
                        assert(!s.dirty && notifications == before + 1);
                        const unsigned char *raw = surfaces.vram.contents;
                        for (unsigned i = 0; i < 16; i++) {
                            unsigned value;
                            memcpy(&value, raw + address + i * 4, 4);
                            assert(value == words[i]);
                        }
                    }
                    checks++;
                }
}
static void alias_tests(void)
{
    NSError *error = nil;
    NV2AMetalCachedSurface *s = surface(32768, 8, YES, 4, 2);
    NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                               .rect = { 0, 0, 8, 8 },
                               .uniforms = { .color = { 1, 0, 0, 1 },
                                             .depth = 0 } };
    clear(s, c);
    unsigned before = notifications;
    NV2AMetalTextureSource src =
        source(32768, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 16, 16);
    NV2AMetalCachedTexture *t = prepare(src);
    assert(!s.dirty && t.scale == 1 && notifications == before);
    id<MTLBuffer> out = read_texture(t);
    finish();
    assert(notifications == before + 1);
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 16; x++) {
            float value = x % 4 >= 2;
            color_at(out, 16, x, y, value, value, value, 1);
        }
    /* The VRAM page version must survive eviction of the GPU surface. */
    require([surfaces invalidateAddress:32768 length:64 error:&error], error);
    t = prepare(src);
    out = read_texture(t);
    finish();
    color_at(out, 16, 2, 0, 1, 1, 1, 1);
    checks++;
    s = surface(36864, NV097_SET_SURFACE_FORMAT_ZETA_Z24S8, NO, 4, 1);
    c.parameter = NV097_CLEAR_SURFACE_Z | NV097_CLEAR_SURFACE_STENCIL;
    c.rect = (MTLScissorRect){ 0, 0, 4, 4 };
    c.uniforms.depth = .5f;
    c.stencil = 0x5a;
    clear(s, c);
    src =
        source(36864, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    t = prepare(src);
    out = read_texture(t);
    finish();
    color_at(out, 4, 0, 0, 0, 0, 0x5a / 255.f, 0x80 / 255.f);
    checks++;
}
static void fragment_feedback_test(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatBGRA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    NV2AMetalCachedSurface *s = surface(49152, 8, YES, 4, 2);
    NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                               .rect = { 0, 0, 8, 8 },
                               .uniforms = { .color = { 1, 0, 0, 1 },
                                             .depth = 0 } };
    clear(s, c);
    c.rect = (MTLScissorRect){ 4, 2, 2, 4 };
    c.uniforms.color[0] = 0;
    c.uniforms.color[2] = 1;
    clear(s, c);
    NV2AMetalCachedTexture *t = prepare(
        source(49152, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16));
    NV2AMetalVertex vertices[6] = { 0 };
    const float xy[6][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 },
                             { 8, 0 }, { 8, 8 }, { 0, 8 } };
    for (unsigned i = 0; i < 6; i++) {
        vertices[i].clip[0] = xy[i][0] / 4 - 1;
        vertices[i].clip[1] = 1 - xy[i][1] / 4;
        vertices[i].clip[2] = .5f;
        vertices[i].clip[3] = 1;
        vertices[i].texcoord[0][0] = 2.5f;
        vertices[i].texcoord[0][1] = 1.5f;
        vertices[i].texcoord[0][3] = 1;
        vertices[i].plane[0][2] = vertices[i].plane[1][2] =
            vertices[i].plane[2][2] = .5f;
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 8;
    u.textures[0].dimension = 2;
    u.textures[0].rectangle = t.rectangle;
    u.textures[0].scale = t.scale;
    u.textures[0].sampling = t.binding.sampling;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    bindings[0].texture = t.binding.texture;
    bindings[0].sampler = t.binding.sampler;
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = s.transfer.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([shader encodeVertices:input
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:bindings
                              pass:pass
                      depthStencil:nil
                          commands:commands
                             error:&error],
            error);
    require([surfaces markWritten:s error:&error], error);
    id<MTLBuffer> out =
        [commands.device newBufferWithLength:s.transfer.sourceLength
                                     options:MTLResourceStorageModeShared];
    assert(out);
    require([s.transfer encodeDownloadToBuffer:out
                                        offset:0
                                       swizzle:NO
                                          flip:NO
                                     downscale:YES
                                      commands:commands
                                         error:&error],
            error);
    id<MTLBuffer> snapshot = read_texture(t);
    finish();
    require([t validateCompletedWithError:&error], error);
    for (unsigned i = 0; i < 16; i++) {
        uint32_t word;
        memcpy(&word, (unsigned char *)out.contents + i * 4, 4);
        assert(word == 0xff0000ff);
    }
    color_at(snapshot, 8, 0, 0, 1, 0, 0, 1);
    color_at(snapshot, 8, 4, 2, 0, 0, 1, 1);
    checks++;
}
static void palette_tests(void)
{
    NSError *error = nil;
    NV2AMetalTextureSource src =
        source(40960, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8, 4, 4);
    src.palette_address = 45056;
    src.palette_length = 128;
    cpu_write(src.address, src.length);
    cpu_write(src.palette_address, 128);
    memset((unsigned char *)surfaces.vram.contents + src.address, 1,
           src.length);
    uint32_t *palette = (uint32_t *)((unsigned char *)surfaces.vram.contents +
                                     src.palette_address);
    memset(palette, 0, 128);
    palette[1] = 0xff112233;
    NV2AMetalCachedTexture *first = prepare(src);
    id<MTLBuffer> out = read_texture(first);
    finish();
    color_at(out, 4, 0, 0, 0x11 / 255.f, 0x22 / 255.f, 0x33 / 255.f, 1);
    cpu_write(src.palette_address + 4, 4);
    palette[1] = 0xffaa3355;
    NV2AMetalCachedTexture *next = prepare(src);
    assert(next.binding.texture != first.binding.texture);
    out = read_texture(next);
    finish();
    color_at(out, 4, 0, 0, 0xaa / 255.f, 0x33 / 255.f, 0x55 / 255.f, 1);
    checks++;
    cpu_write(src.address, src.length);
    memset((unsigned char *)surfaces.vram.contents + src.address, 32,
           src.length);
    next = prepare(src);
    finish();
    assert(![next validateCompletedWithError:&error]);
    NV2AMetalSamplerConfig sampler = policy();
    assert(![textures prepareSource:&src
                            sampler:&sampler
                              frame:2
                              error:&error]);
    assert(!commands.commandBuffer);
    checks++;
}
static void lru_and_reject_tests(void)
{
    NSError *error = nil;
    [textures removeAllTextures];
    // This fixture owns its source bytes; earlier RTT cases may use the range.
    cpu_write(65536, 513 * 64);
    memset((unsigned char *)surfaces.vram.contents + 65536, 0, 513 * 64);
    NV2AMetalCachedTexture *first = nil;
    for (unsigned i = 0; i < 513; i++) {
        NV2AMetalTextureSource c =
            source(65536 + i * 64,
                   NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
        NV2AMetalCachedTexture *t = prepare(c);
        if (!i)
            first = t;
    }
    assert(textures.count == 512);
    Ivar entriesIvar = class_getInstanceVariable(textures.class, "_entries");
    assert(entriesIvar);
    id cache = object_getIvar(textures, entriesIvar);
    NSDictionary *entries = [cache valueForKey:@"entries"];
    NSMutableSet<NSNumber *> *hashes = [NSMutableSet new];
    for (id key in entries)
        [hashes addObject:@([key hash])];
    printf("Actual texture cache: %lu distinct hashes for 512 live keys\n",
           (unsigned long)hashes.count);
    fflush(stdout);
    assert(hashes.count >= 500);

    id<MTLBuffer> out = read_texture(first);
    finish();
    color_at(out, 4, 0, 0, 0, 0, 0, 0);
    NV2AMetalTextureSource c =
        source(65536, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    NV2AMetalCachedTexture *next = prepare(c);
    assert(next.binding.texture != first.binding.texture);
    [surfaces cancel];
    checks++;
    NV2AMetalSamplerConfig sampler = policy();
    c.address = surfaces.vram.length;
    assert(![textures prepareSource:&c sampler:&sampler frame:0 error:&error]);
    c.address = NSUIntegerMax;
    assert(![textures prepareSource:&c sampler:&sampler frame:0 error:&error]);
    c.address = 65536;
    c.length--;
    assert(![textures prepareSource:&c sampler:&sampler frame:0 error:&error]);
    assert(!commands.commandBuffer);
    c.length++;
    c.shape.levels = 0;
    /* Linear formats ignore this field, preserving the existing GL contract. */
    next = prepare(c);
    finish();
    require([next validateCompletedWithError:&error], error);
    c.shape.format = UINT32_MAX;
    assert(![textures prepareSource:&c sampler:&sampler frame:0 error:&error]);
    assert(!commands.commandBuffer);
    c.shape.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8;
    sampler.anisotropy = 3;
    assert(![textures prepareSource:&c sampler:&sampler frame:0 error:&error]);
    assert(!commands.commandBuffer);
    uint64_t version;
    assert(![surfaces sourceVersionAtAddress:0
                                      length:1
                                     version:NULL
                                       error:&error]);
    require([surfaces sourceVersionAtAddress:surfaces.vram.length
                                      length:0
                                     version:&version
                                       error:&error],
            error);
    assert(version == 0);
    checks++;
}
static void signed_channel_cache_tests(void)
{
    NSError *error = nil;
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8
    };
    const unsigned raw[4][4] = { { 255, 128, 127, 1 },
                                 { 127, 128, 255, 1 },
                                 { 128, 255, 1, 127 },
                                 { 1, 255, 128, 127 } };
    NV2AMetalTextureSource c =
        source(110592, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    cpu_write(c.address, c.length);
    uint32_t *vram =
        (uint32_t *)((unsigned char *)surfaces.vram.contents + c.address);
    for (unsigned i = 0; i < 16; i++)
        vram[i] = 0x01ff807f;
    NSMutableArray<NV2AMetalCachedTexture *> *saved = [NSMutableArray new];
    for (unsigned format = 0; format < 8; format++) {
        c.shape.format = formats[format];
        for (unsigned mask = 0; mask < 16; mask++) {
            c.shape.signed_channels = mask;
            NV2AMetalCachedTexture *t = prepare(c);
            for (NV2AMetalCachedTexture *old in saved) {
                assert(old.binding.texture != t.binding.texture);
            }
            [saved addObject:t];
            NV2AMetalSamplerConfig sampler = policy();
            sampler.filter = 2 << 16 | 2 << 24;
            NV2AMetalCachedTexture *linear = [textures prepareSource:&c
                                                             sampler:&sampler
                                                               frame:2
                                                               error:&error];
            require(linear != nil, error);
            assert(linear.binding.texture == t.binding.texture);
            assert(t.mixedSignedHalf == (mask && mask != 15));
            id<MTLBuffer> out = test_metal_read_texture_decoded(
                commands, t.binding.texture, 0, 0,
                t.mixedSignedHalf ? (15u ^ mask) : 0);
            finish();
            require([t validateCompletedWithError:&error], error);
            float expected[4];
            for (unsigned k = 0; k < 4; k++) {
                int v = raw[format / 2][k];
                if ((mask & (1u << k)) && v >= 128)
                    v -= 256;
                expected[k] = v / ((mask & (1u << k)) ? 128.0f : 255.0f);
            }
            for (unsigned y = 0; y < 4; y++) {
                for (unsigned x = 0; x < 4; x++) {
                    color_at(out, 4, x, y, expected[0], expected[1],
                             expected[2], expected[3]);
                }
            }
        }
    }
    checks++;

    /* A signed view of a GPU-dirty target must decode guest bytes, rather
     * than reusing the unsigned scaled render-target copy. */
    c.address = 114688;
    c.shape.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8;
    NV2AMetalCachedSurface *s = surface(c.address, 8, YES, 4, 2);
    NV2AMetalClearConfig clear_config = {
        .parameter = NV097_CLEAR_SURFACE_COLOR,
        .rect = { 0, 0, 8, 8 },
        .uniforms = { .color = { 127.0f / 255, 128.0f / 255, 1, 254.0f / 255 } }
    };
    clear(s, clear_config);
    for (unsigned mask = 0; mask < 16; mask++) {
        c.shape.signed_channels = mask;
        NV2AMetalCachedTexture *t = prepare(c);
        assert(t.scale == (mask ? 1 : 2));
        unsigned width = mask ? 4 : 8;
        assert(t.binding.texture.width == width);
        assert(t.mixedSignedHalf == (mask && mask != 15));
        id<MTLBuffer> out = test_metal_read_texture_decoded(
            commands, t.binding.texture, 0, 0,
            t.mixedSignedHalf ? (15u ^ mask) : 0);
        finish();
        require([t validateCompletedWithError:&error], error);
        const unsigned codes[] = { 127, 128, 255, 254 };
        float expected[4];
        for (unsigned k = 0; k < 4; k++) {
            int v = codes[k];
            if ((mask & (1u << k)) && v >= 128)
                v -= 256;
            expected[k] = v / ((mask & (1u << k)) ? 128.0f : 255.0f);
        }
        for (unsigned y = 0; y < width; y++) {
            for (unsigned x = 0; x < width; x++) {
                color_at(out, width, x, y, expected[0], expected[1],
                         expected[2], expected[3]);
            }
        }
    }
    checks++;
    printf("Metal4 signed8 cache: 128 format/mask identities/reuse, 2048 "
           "texels and 16 RTT views PASS\n");
}

@interface NSObject (MetalTextureKeyTest)
- (instancetype)initWithKeyWords:(const uint64_t *)words;
@end
static void key_identity_tests(void)
{
    Class keyClass = NSClassFromString(@"NV2AMetalTextureKey");
    assert(keyClass);
    uint64_t words[20];
    for (unsigned i = 0; i < 20; i++)
        words[i] = UINT64_C(0x123456789abcdef0) + i;
    id first = [[keyClass alloc] initWithKeyWords:words];
    id same = [[keyClass alloc] initWithKeyWords:words];
    assert([first isEqual:same] && [first hash] == [same hash]);
    id copied = [first copy];
    assert([copied isEqual:first] && [copied hash] == [first hash]);
    NSMutableDictionary *map = [NSMutableDictionary dictionaryWithObject:@1
                                                                  forKey:first];
    assert([map[same] isEqual:@1]);
    for (unsigned field = 0; field < 20; field++) {
        for (unsigned bit = 0; bit < 64; bit++) {
            words[field] ^= UINT64_C(1) << bit;
            id changed = [[keyClass alloc] initWithKeyWords:words];
            assert(![first isEqual:changed] && ![changed isEqual:first]);
            assert(!map[changed]);
            words[field] ^= UINT64_C(1) << bit;
        }
    }
    assert(![first isEqual:@[]]);
    checks++;
    puts("Texture key identity: 1280 full-width field/bit distinctions, "
         "equal-copy dictionary lookup PASS");
}

static void deferred_source_tests(void)
{
    NSError *error = nil;
    NV2AMetalCPUAccessGuard *guard = surfaces.cpuAccessGuard;
    NV2AMetalTextureSource src =
        source(8192, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    uint32_t *words =
        (uint32_t *)((uint8_t *)surfaces.vram.contents + src.address);
    NV2AMetalCachedTexture *old = nil;
    for (unsigned phase = 0; phase < 3; phase++) {
        assert(nv2a_metal_try_cpu_access(guard, src.address, src.length, YES));
        for (unsigned i = 0; i < 16; i++)
            words[i] = phase == 0 ? 0xffff0000 :
                       phase == 1 ? 0xff00ff00 :
                                    0xff0000ff;
        NV2AMetalCachedTexture *t = prepare(src);
        assert(t.binding.texture != old.binding.texture);
        id<MTLBuffer> out = read_texture(t);
        finish();
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 4; x++)
                color_at(out, 4, x, y, phase == 0, phase == 1, phase == 2, 1);
        old = t;
    }
    // Cache reuse without another write must preserve the immutable texture.
    NV2AMetalCachedTexture *same = prepare(src);
    assert(same.binding.texture == old.binding.texture);
    finish();
    src = source(40960, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8, 4, 4);
    src.palette_address = 45056;
    src.palette_length = 128;
    assert(nv2a_metal_try_cpu_access(guard, src.address, src.length, YES));
    assert(nv2a_metal_try_cpu_access(guard, src.palette_address,
                                     src.palette_length, YES));
    memset((uint8_t *)surfaces.vram.contents + src.address, 1, src.length);
    uint32_t *palette =
        (uint32_t *)((uint8_t *)surfaces.vram.contents + src.palette_address);
    memset(palette, 0, src.palette_length);
    palette[1] = 0xff112233;
    NV2AMetalCachedTexture *first = prepare(src);
    id<MTLBuffer> out = read_texture(first);
    finish();
    color_at(out, 4, 0, 0, 0x11 / 255.f, 0x22 / 255.f, 0x33 / 255.f, 1);
    assert(nv2a_metal_try_cpu_access(guard, src.palette_address + 4, 4, YES));
    palette[1] = 0xffaa3355;
    NV2AMetalCachedTexture *next = prepare(src);
    assert(next.binding.texture != first.binding.texture);
    out = read_texture(next);
    finish();
    color_at(out, 4, 0, 0, 0xaa / 255.f, 0x33 / 255.f, 0x55 / 255.f, 1);
    [textures removeAllTextures];
    require([surfaces flushWithError:&error], error);
    puts("Deferred dirty keys: actual GPU red/green/blue reuploads, stable "
         "reuse and palette-only invalidation PASS");
}

#include "test-metal-texture-hit-cache.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        id<MTLBuffer> vram =
            [commands.device newBufferWithLength:131072
                                         options:MTLResourceStorageModeShared];
        assert(vram);
        memset(vram.contents, 0, vram.length);
        surfaces = [[NV2AMetalSurfaceCache alloc]
            initWithCommands:commands
                        vram:vram
                didWriteVRAM:^(NSUInteger address, NSUInteger length) {
                  assert(address < vram.length &&
                         length <= vram.length - address);
                  notifications++;
                }
                       error:&error];
        require(surfaces != nil, error);
        textures = [[NV2AMetalTextureCache alloc] initWithSurfaces:surfaces
                                                             error:&error];
        require(textures != nil, error);
        clearer = [[NV2AMetalClear alloc] initWithDevice:commands.device
                                                   error:&error];
        require(clearer != nil, error);
        if (argc == 2 && !strcmp(argv[1], "--CPU-dirty-source")) {
            deferred_source_tests();
            return 0;
        }
        texture_hit_cache_tests();
        if (argc == 2 && !strcmp(argv[1], "--hit-cache"))
            return 0;
        ordinary_and_cancel_tests();
        rtt_tests();
        compact_rtt_tests();
        rtt_layout_and_channel_tests();
        alias_tests();
        fragment_feedback_test();
        palette_tests();
        lru_and_reject_tests();
        key_identity_tests();
        signed_channel_cache_tests();
        [textures removeAllTextures];
        require([surfaces flushWithError:&error], error);
        printf(
            "Metal 4 texture cache: %u coherence/RTT/palette/LRU groups PASS\n",
            checks);
    }
    return 0;
}
