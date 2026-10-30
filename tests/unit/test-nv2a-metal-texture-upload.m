/*
 * Offscreen native Metal 4 texture decode/upload tests
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "hw/xbox/nv2a/pgraph/metal/texture-upload.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-sampler.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-snapshot.h"
#include "hw/xbox/nv2a/pgraph/metal/geometry-types.h"
#include "test-metal-texture-readback.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NV2AMetalCommands *commands;
static NV2AMetalTextureUpload *uploader;
static unsigned int uploads;

@interface TextureUploadTestCommands : NV2AMetalCommands
@property(nonatomic) BOOL measureScratch;
@property(nonatomic) NSUInteger scratchBytes;
@end
@implementation TextureUploadTestCommands
- (BOOL)addResource:(id<MTLResource>)resource error:(NSError **)error
{
    if (![super addResource:resource error:error]) {
        return NO;
    }
    if (_measureScratch && resource.storageMode == MTLStorageModePrivate &&
        [resource conformsToProtocol:@protocol(MTLBuffer)]) {
        _scratchBytes += ((id<MTLBuffer>)resource).length;
    }
    return YES;
}
@end

static void require(BOOL success, NSError *error)
{
    if (!success) {
        fprintf(stderr, "Texture upload: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}

static void check(float actual, float expected)
{
    if (!isfinite(actual) || fabsf(actual - expected) > .000002f) {
        fprintf(stderr, "Texture upload %u: got %.9g expected %.9g\n", uploads,
                actual, expected);
        abort();
    }
}

static NV2AMetalTextureShape shape(unsigned int format)
{
    return (NV2AMetalTextureShape){ .format = format,
                                    .dimension = 2,
                                    .width = 2,
                                    .height = 2,
                                    .depth = 1,
                                    .levels = 1,
                                    .pitch = 16 };
}

static id<MTLBuffer> buffer(const void *bytes, NSUInteger size)
{
    id<MTLBuffer> b =
        [commands.device newBufferWithBytes:bytes
                                     length:size
                                    options:MTLResourceStorageModeShared];
    assert(b);
    return b;
}

/* Independent bit deposition, used only to lay out input fixtures. */
static size_t morton(unsigned int x, unsigned int y, unsigned int z,
                     unsigned int w, unsigned int h, unsigned int d)
{
    size_t address = 0, mask[3] = { 0 };
    size_t bit = 1;
    for (unsigned int coordinate_bit = 1;
         coordinate_bit < w || coordinate_bit < h || coordinate_bit < d;
         coordinate_bit <<= 1) {
        if (coordinate_bit < w) {
            mask[0] |= bit;
            bit <<= 1;
        }
        if (coordinate_bit < h) {
            mask[1] |= bit;
            bit <<= 1;
        }
        if (coordinate_bit < d) {
            mask[2] |= bit;
            bit <<= 1;
        }
    }
    const unsigned int c[] = { x, y, z };
    for (unsigned int axis = 0; axis < 3; axis++) {
        unsigned int value = c[axis];
        for (size_t m = mask[axis]; m; m &= m - 1) {
            size_t low = m & (~m + 1);
            if (value & 1) {
                address |= low;
            }
            value >>= 1;
        }
    }
    return address;
}

static id<MTLBuffer> read_texture(id<MTLTexture> texture, unsigned int level,
                                  unsigned int face)
{
    return test_metal_read_texture(commands, texture, level, face);
}

static const float *pixel(id<MTLBuffer> b, unsigned int w, unsigned int h,
                          unsigned int x, unsigned int y, unsigned int z)
{
    NSUInteger row = ((NSUInteger)w * 16 + 255) & ~(NSUInteger)255;
    return (const float *)((const unsigned char *)b.contents + z * row * h +
                           y * row + x * 16);
}

static NV2AMetalTextureUploadResult *
upload(NV2AMetalTextureShape s, id<MTLBuffer> data, NSUInteger offset,
       id<MTLBuffer> palette, NSUInteger paletteLength)
{
    NSError *error = nil;
    NV2AMetalTextureUploadResult *r = [uploader encodeData:data
                                                    offset:offset
                                                   palette:palette
                                             paletteOffset:0
                                             paletteLength:paletteLength
                                                     shape:&s
                                                  commands:commands
                                                     error:&error];
    require(r != nil, error);
    uploads++;
    return r;
}

static void finish(void)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}

#include "test-metal-float-lanes.h"

static void format_tests(void)
{
    /* Four distinct source bytes expose the endian and component orders. */
    struct Case {
        unsigned int format, bpp;
        BOOL linear;
        float rgba[4];
    } cases[] = {
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8,
          1,
          NO,
          { 17.0f / 255, 17.0f / 255, 17.0f / 255, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8,
          1,
          NO,
          { 17.0f / 255, 17.0f / 255, 17.0f / 255, 17.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5,
          2,
          NO,
          { 8.0f / 31, 16.0f / 31, 17.0f / 31, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5,
          2,
          NO,
          { 8.0f / 31, 16.0f / 31, 17.0f / 31, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4,
          2,
          NO,
          { 2.0f / 15, 1.0f / 15, 1.0f / 15, 2.0f / 15 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5,
          2,
          NO,
          { 4.0f / 31, 16.0f / 63, 17.0f / 31, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
          4,
          NO,
          { 51.0f / 255, 34.0f / 255, 17.0f / 255, 68.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8,
          4,
          NO,
          { 51.0f / 255, 34.0f / 255, 17.0f / 255, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8,
          1,
          NO,
          { 1, 1, 1, 17.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8,
          2,
          NO,
          { 17.0f / 255, 17.0f / 255, 17.0f / 255, 34.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5,
          2,
          NO,
          { 16.0f / 127, -128.0f / 127, -120.0f / 127, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8,
          2,
          NO,
          { 17.0f / 255, 34.0f / 255, 17.0f / 255, 34.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8,
          2,
          NO,
          { 34.0f / 255, 17.0f / 255, 17.0f / 255, 34.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_DEPTH_Y16_FIXED,
          2,
          NO,
          { 8721.0f / 65535, 0, 0, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FIXED,
          4,
          YES,
          { 4469538.0f / 16777215, 1, 0, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FLOAT,
          4,
          YES,
          { 0x1.3322p-59f, 1, 1, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FLOAT,
          2,
          YES,
          { ldexpf(1 + 529.0f / 4096, -5) / 511.9375f, 0, 1, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16,
          2,
          YES,
          { 1, 8721.0f / 65535, 8721.0f / 65535, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
          4,
          NO,
          { 17.0f / 255, 34.0f / 255, 51.0f / 255, 68.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
          4,
          NO,
          { 34.0f / 255, 51.0f / 255, 68.0f / 255, 17.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8,
          4,
          NO,
          { 68.0f / 255, 51.0f / 255, 34.0f / 255, 17.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5,
          2,
          YES,
          { 8.0f / 31, 16.0f / 31, 17.0f / 31, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5,
          2,
          YES,
          { 8.0f / 31, 16.0f / 31, 17.0f / 31, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4,
          2,
          YES,
          { 2.0f / 15, 1.0f / 15, 1.0f / 15, 2.0f / 15 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5,
          2,
          YES,
          { 4.0f / 31, 16.0f / 63, 17.0f / 31, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
          4,
          YES,
          { 51.0f / 255, 34.0f / 255, 17.0f / 255, 68.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8,
          4,
          YES,
          { 51.0f / 255, 34.0f / 255, 17.0f / 255, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8,
          1,
          YES,
          { 17.0f / 255, 17.0f / 255, 17.0f / 255, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8,
          1,
          YES,
          { 17.0f / 255, 17.0f / 255, 17.0f / 255, 17.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8,
          2,
          YES,
          { 17.0f / 255, 34.0f / 255, 17.0f / 255, 34.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8,
          1,
          YES,
          { 1, 1, 1, 17.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8,
          2,
          YES,
          { 17.0f / 255, 17.0f / 255, 17.0f / 255, 34.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16,
          2,
          NO,
          { 1, 8721.0f / 65535, 8721.0f / 65535, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FIXED,
          2,
          YES,
          { 8721.0f / 65535, 0, 0, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
          4,
          YES,
          { 17.0f / 255, 34.0f / 255, 51.0f / 255, 68.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8,
          4,
          YES,
          { 34.0f / 255, 51.0f / 255, 68.0f / 255, 17.0f / 255 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8,
          4,
          YES,
          { 68.0f / 255, 51.0f / 255, 34.0f / 255, 17.0f / 255 } },
    };
    unsigned char palette_bytes[1024] = { 0 };
    for (unsigned int i = 0; i < 256; i++) {
        palette_bytes[4 * i] = i;
        palette_bytes[4 * i + 1] = 34;
        palette_bytes[4 * i + 2] = 51;
        palette_bytes[4 * i + 3] = 68;
    }
    id<MTLBuffer> palette = buffer(palette_bytes, sizeof(palette_bytes));
    for (unsigned int c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        struct Case test = cases[c];
        unsigned char source[32] = { 0 };
        const unsigned char bytes[] = { 17, 34, 51, 68 };
        NV2AMetalTextureShape s = shape(test.format);
        for (unsigned int y = 0; y < 2; y++) {
            for (unsigned int x = 0; x < 2; x++) {
                unsigned int offset = test.linear ? y * 16 + x * test.bpp :
                                                    (y * 2 + x) * test.bpp;
                memcpy(source + offset, bytes, test.bpp);
            }
        }
        id<MTLBuffer> data = buffer(source, sizeof(source));
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, palette, 1024);
        assert(r.rectangle == test.linear);
        id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
        finish();
        assert(*(uint32_t *)r.faults.contents == 0);
        for (unsigned int y = 0; y < 2; y++) {
            for (unsigned int x = 0; x < 2; x++) {
                const float *p = pixel(readback, 2, 2, x, y, 0);
                for (unsigned int k = 0; k < 4; k++) {
                    /* Signed normalized conversion clamps -128 to -1. */
                    check(p[k], fmaxf(-1, test.rgba[k]));
                }
            }
        }
    }
}

/* Independently specified byte mappings; every channel exercises all 256
 * values before exact comparison, including palette and opaque-X alpha. */
static void compact_byte_tests(void)
{
    const struct {
        unsigned format, bytes;
        BOOL linear, indexed;
        int channels[4];
    } cases[] = {
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8, 1, NO, NO, { 0, 0, 0, -1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 1, YES, NO, { 0, 0, 0, -1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8, 1, NO, NO, { 0, 0, 0, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8, 1, YES, NO, { 0, 0, 0, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8, 1, NO, NO, { -1, -1, -1, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8, 1, YES, NO, { -1, -1, -1, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8, 2, NO, NO, { 0, 0, 0, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8, 2, YES, NO, { 0, 0, 0, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8, 2, NO, NO, { 0, 1, 0, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8, 2, YES, NO, { 0, 1, 0, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8, 2, NO, NO, { 1, 0, 0, 1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8, 1, NO, YES, { 2, 1, 0, 3 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8, 4, NO, NO, { 2, 1, 0, 3 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, YES, NO, { 2, 1, 0, 3 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8, 4, NO, NO, { 2, 1, 0, -1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8, 4, YES, NO, { 2, 1, 0, -1 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8, 4, NO, NO, { 0, 1, 2, 3 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8, 4, YES, NO, { 0, 1, 2, 3 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8, 4, NO, NO, { 1, 2, 3, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8, 4, YES, NO, { 1, 2, 3, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8, 4, NO, NO, { 3, 2, 1, 0 } },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8, 4, YES, NO, { 3, 2, 1, 0 } },
    };
    uint8_t source[16 * 16 * 4], colors[256][4];
    for (unsigned i = 0; i < 256; i++) {
        colors[i][0] = i;
        colors[i][1] = 255 - i;
        colors[i][2] = i * 71;
        colors[i][3] = i * 29 + 7;
    }
    unsigned channels = 0;
    for (unsigned f = 0; f < sizeof(cases) / sizeof(*cases); f++) {
        NV2AMetalTextureShape s = shape(cases[f].format);
        s.width = s.height = 16;
        s.pitch = 16 * cases[f].bytes;
        for (unsigned y = 0; y < 16; y++) {
            for (unsigned x = 0; x < 16; x++) {
                unsigned i = y * 16 + x;
                size_t offset = (cases[f].linear ? i :
                    morton(x, y, 0, 16, 16, 1)) * cases[f].bytes;
                if (cases[f].indexed) {
                    source[offset] = i;
                } else {
                    memcpy(source + offset, colors[i], cases[f].bytes);
                }
            }
        }
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s,
            buffer(source, 256 * cases[f].bytes), 0,
            cases[f].indexed ? buffer(colors, sizeof(colors)) : nil,
            cases[f].indexed ? sizeof(colors) : 0);
        assert(r.texture.pixelFormat == MTLPixelFormatRGBA8Unorm);
        id<MTLBuffer> out = read_texture(r.texture, 0, 0);
        finish();
        assert(*(uint32_t *)r.faults.contents == 0);
        NSData *snapshot = nv2a_metal_texture_snapshot(r.texture, commands, &error);
        require(snapshot != nil, error);
        assert(snapshot.length == 40 + 256 * 4);
        const uint8_t *raw = (const uint8_t *)snapshot.bytes + 40;
        for (unsigned i = 0; i < 256; i++) {
            const float *p = pixel(out, 16, 16, i % 16, i / 16, 0);
            for (unsigned k = 0; k < 4; k++) {
                int input = cases[f].channels[k];
                uint8_t expected = input < 0 ? 255 : colors[i][input];
                assert(raw[i * 4 + k] == expected);
                assert(p[k] == expected / 255.0f);
                channels++;
            }
        }
        id<MTLTexture> restored =
            nv2a_metal_texture_restore(snapshot, commands, &error);
        require(restored != nil, error);
        assert(restored.pixelFormat == MTLPixelFormatRGBA8Unorm);
        NSData *again = nv2a_metal_texture_snapshot(restored, commands, &error);
        require(again != nil, error);
        assert([snapshot isEqualToData:again]);
    }
    printf("Metal4 compact upload: 22 byte formats, %u exact channels and "
           "snapshot bytes, 22 compact restore/resave cycles PASS\n", channels);
}

static void direct_copy_tests(void)
{
    const struct {
        unsigned width, height, pitch, offset;
        BOOL direct;
    } cases[] = {
        { 1, 1, 4, 0, YES },         { 3, 5, 12, 4, YES },
        { 17, 3, 68, 256, YES },     { 16, 16, 64, 0, YES },
        { 17, 3, 256, 4, YES },      { 1, 2, 65536, 4, YES },
        { 1, 2, 65540, 4, NO },      { 7, 3, 32, 1, NO },
        { 7, 3, 32, 3, NO },         { 256, 256, 1024, 4, YES },
        { 16384, 1, 65536, 4, YES },
    };
    unsigned directCount[5] = { 0 }, fallbackCount[5] = { 0 },
             channels[5] = { 0 };
    TextureUploadTestCommands *measured = (TextureUploadTestCommands *)commands;
    for (unsigned packed = 0; packed < 5; packed++)
        for (unsigned f = 0; f < sizeof(cases) / sizeof(*cases); f++) {
            for (unsigned privateSource = 0; privateSource < 2;
                 privateSource++) {
                for (unsigned signedChannel = 0;
                     signedChannel < (packed ? 1u : 2u); signedChannel++) {
                    @autoreleasepool {
                        const unsigned formats[] = {
                            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
                            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5,
                            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5,
                            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5,
                            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4
                        };
                        NV2AMetalTextureShape s = shape(formats[packed]);
                        s.width = cases[f].width;
                        s.height = cases[f].height;
                        s.pitch = cases[f].pitch / (packed ? 2 : 1);
                        s.signed_channels = signedChannel;
                        NSUInteger offset = cases[f].offset;
                        if (packed && !(offset % 4))
                            offset /= 2;
                        NSUInteger length =
                            (offset + s.pitch * s.height + 3) & ~(NSUInteger)3;
                        NSMutableData *seed =
                            [NSMutableData dataWithLength:length];
                        memset(seed.mutableBytes, 0xcc, length);
                        for (unsigned y = 0; y < s.height; y++) {
                            for (unsigned x = 0; x < s.width; x++) {
                                unsigned i = y * s.width + x;
                                const uint8_t rgba[] = { i, 255 - i, i * 71,
                                                         i * 29 + 7 };
                                uint16_t code = (i * 40503 + 0x1289) & 65535;
                                if (packed) {
                                    uint8_t *p = (uint8_t *)seed.mutableBytes +
                                                 offset + y * s.pitch + x * 2;
                                    p[0] = code;
                                    p[1] = code >> 8;
                                } else
                                    memcpy((uint8_t *)seed.mutableBytes +
                                               offset + y * s.pitch + x * 4,
                                           rgba, 4);
                            }
                        }
                        NSError *error = nil;
                        require([commands beginWithError:&error] != nil, error);
                        id<MTLBuffer> data;
                        if (privateSource) {
                            data = [commands.device
                                newBufferWithLength:length
                                            options:
                                                MTLResourceStorageModePrivate];
                            id<MTLBuffer> input = buffer(seed.bytes, length);
                            require([commands addResource:input error:&error],
                                    error);
                            require([commands addResource:data error:&error],
                                    error);
                            id<MTL4ComputeCommandEncoder> producer =
                                [commands.commandBuffer computeCommandEncoder];
                            assert(producer);
                            [producer copyFromBuffer:input
                                        sourceOffset:0
                                            toBuffer:data
                                   destinationOffset:0
                                                size:length];
                            [producer endEncoding];
                        } else {
                            data = buffer(seed.bytes, length);
                        }
                        assert(data);
                        measured.scratchBytes = 0;
                        measured.measureScratch = YES;
                        NV2AMetalTextureUploadResult *r =
                            upload(s, data, offset, nil, 0);
                        measured.measureScratch = NO;
                        BOOL direct = cases[f].direct && !signedChannel;
                        NSUInteger row = (s.width * (packed        ? 2 :
                                                     signedChannel ? 8 :
                                                                     4) +
                                          255) &
                                         ~(NSUInteger)255;
                        assert(measured.scratchBytes ==
                               (privateSource ? length : 0) +
                                   (direct ? 0 : row * s.height));
                        directCount[packed] += direct;
                        fallbackCount[packed] += !direct;
                        assert(r.sourceLength == s.pitch * s.height);
                        id<MTLBuffer> first = test_metal_read_texture_decoded(
                            commands, r.texture, 0, 0,
                            r.mixedSignedHalf ? (15u ^ s.signed_channels) : 0);
                        id<MTL4ComputeCommandEncoder> overwrite =
                            [commands.commandBuffer computeCommandEncoder];
                        assert(overwrite);
                        [overwrite
                            barrierAfterQueueStages:MTLStageAll
                                       beforeStages:MTLStageBlit
                                  visibilityOptions:MTL4VisibilityOptionDevice];
                        [overwrite fillBuffer:data
                                        range:NSMakeRange(0, length)
                                        value:0xaa];
                        [overwrite endEncoding];
                        id<MTLBuffer> retained =
                            test_metal_read_texture_decoded(
                                commands, r.texture, 0, 0,
                                r.mixedSignedHalf ? (15u ^ s.signed_channels) :
                                                    0);
                        __weak id<MTLBuffer> weak = data;
                        data = nil;
                        assert(weak); // Recording owns the source through
                                      // completion.
                        finish();
                        assert(*(uint32_t *)r.faults.contents == 0);
                        for (unsigned y = 0; y < s.height; y++) {
                            for (unsigned x = 0; x < s.width; x++) {
                                unsigned i = y * s.width + x;
                                const uint8_t rgba[] = { i, 255 - i, i * 71,
                                                         i * 29 + 7 };
                                const float *a =
                                    pixel(first, s.width, s.height, x, y, 0);
                                const float *b =
                                    pixel(retained, s.width, s.height, x, y, 0);
                                for (unsigned k = 0; k < 4; k++) {
                                    float expected =
                                        signedChannel && !k ?
                                            (rgba[k] < 128 ?
                                                 rgba[k] :
                                                 (int)rgba[k] - 256) /
                                                128.f :
                                            rgba[k] / 255.f;
                                    if (packed) {
                                        unsigned code =
                                            (i * 40503 + 0x1289) & 65535;
                                        expected =
                                            k == 0 ? (code >> 11) / 31.f :
                                            k == 1 ? ((code >> 5) & 63) / 63.f :
                                            k == 2 ? (code & 31) / 31.f :
                                                     1;
                                    }
                                    if (packed == 2 || packed == 3) {
                                        unsigned code =
                                            (i * 40503 + 0x1289) & 65535;
                                        expected =
                                            k == 0 ?
                                                ((code >> 10) & 31) / 31.f :
                                            k == 1 ? ((code >> 5) & 31) / 31.f :
                                            k == 2 ? (code & 31) / 31.f :
                                            packed == 3 ? 1 :
                                                          (float)(code >> 15);
                                    } else if (packed == 4) {
                                        unsigned code =
                                            (i * 40503 + 0x1289) & 65535;
                                        expected = ((code >> (k == 0 ? 8 :
                                                              k == 1 ? 4 :
                                                              k == 2 ? 0 :
                                                                       12)) &
                                                    15) /
                                                   15.f;
                                    }
                                    assert(a[k] == expected &&
                                           b[k] == expected);
                                    channels[packed]++;
                                }
                            }
                        }
                    }
                }
            }
        }
    for (unsigned packed = 0; packed < 5; packed++)
        printf(
            "Metal4 direct %s upload: %u zero-scratch copies, %u decoder "
            "fallbacks, %u exact channels; padded/max/over-limit rows, aligned/"
            "unaligned offsets, signed inputs, same-recording private "
            "producer, "
            "source lifetime and later source overwrite isolation PASS\n",
            (const char *[]){ "RGBA", "R565", "A1555", "X1555",
                              "A4444" }[packed],
            directCount[packed], fallbackCount[packed], channels[packed]);
}

static void compact_allocation_test(void)
{
    TextureUploadTestCommands *measured = (TextureUploadTestCommands *)commands;
    uint8_t pixels[64 * 64 * 4];
    memset(pixels, 127, sizeof(pixels));
    const unsigned masks[] = { 0, 1, 15 };
    const MTLPixelFormat formats[] = { MTLPixelFormatRGBA8Unorm,
                                       MTLPixelFormatRGBA16Float,
                                       MTLPixelFormatRGBA16Float };
    const unsigned channelBytes[] = { 4, 8, 8 };
    NSUInteger scratch[3], textureBytes[3];
    for (unsigned n = 0; n < 3; n++) {
        NV2AMetalTextureShape s =
            shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
        s.width = s.height = 64;
        s.signed_channels = masks[n];
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        measured.scratchBytes = 0;
        measured.measureScratch = YES;
        NV2AMetalTextureUploadResult *r =
            upload(s, buffer(pixels, sizeof(pixels)), 0, nil, 0);
        measured.measureScratch = NO;
        scratch[n] = measured.scratchBytes;
        textureBytes[n] = r.texture.allocatedSize;
        assert(r.texture.pixelFormat == formats[n]);
        id<MTLBuffer> out = test_metal_read_texture_decoded(
            commands, r.texture, 0, 0,
            r.mixedSignedHalf ? (15u ^ masks[n]) : 0);
        finish();
        const float *p = pixel(out, 64, 64, 0, 0, 0);
        for (unsigned k = 0; k < 4; k++)
            assert(p[k] == 127.0f / ((masks[n] & (1u << k)) ? 128 : 255));
        assert(scratch[n] == 64 * 64 * channelBytes[n]);
    }
    assert(textureBytes[2] == textureBytes[1] &&
           textureBytes[1] > textureBytes[0]);
    printf("Metal4 upload allocations 64x64 unsigned/mixed-signed/full-signed: "
           "scratch %lu/%lu/%lu bytes, actual texture %lu/%lu/%lu bytes PASS\n",
           (unsigned long)scratch[0], (unsigned long)scratch[1],
           (unsigned long)scratch[2], (unsigned long)textureBytes[0],
           (unsigned long)textureBytes[1], (unsigned long)textureBytes[2]);
}

/* Every raw Y16 word, including asymmetric bytes, in both guest layouts. */
static void y16_tests(void)
{
    const unsigned formats[] = { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16 };
    for (unsigned f = 0; f < 2; f++) {
        NV2AMetalTextureShape s = shape(formats[f]);
        s.width = s.height = 256;
        s.pitch = 544;
        unsigned char *bytes = calloc(s.pitch * s.height, 1);
        assert(bytes);
        for (unsigned y = 0; y < 256; y++) {
            for (unsigned x = 0; x < 256; x++) {
                size_t offset =
                    f ? y * s.pitch + x * 2 : morton(x, y, 0, 256, 256, 1) * 2;
                bytes[offset] = x;
                bytes[offset + 1] = y;
            }
        }
        id<MTLBuffer> data = buffer(bytes, s.pitch * s.height);
        free(bytes);
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
        assert(r.rectangle == (f != 0) && !r.signedNormalized && !r.depth);
        assert(r.sourceLength == (f ? 544u * 256 : 256u * 256 * 2));
        id<MTLBuffer> out = read_texture(r.texture, 0, 0);
        finish();
        assert(*(uint32_t *)r.faults.contents == 0);
        for (unsigned y = 0; y < 256; y++) {
            for (unsigned x = 0; x < 256; x++) {
                const float *p = pixel(out, 256, 256, x, y, 0);
                double value = (y * 256u + x) / 65535.0;
                check(p[0], 1);
                check(p[1], (float)value);
                check(p[2], (float)value);
                check(p[3], 1);
            }
        }
    }
    printf(
        "Metal4 Y16: all65536 words in swizzled/padded linear layouts PASS\n");
}

/* Each unsigned16 component visits all65536 values independently. */
static void hilo16_tests(void)
{
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16
    };
    for (unsigned f = 0; f < 2; f++) {
        NV2AMetalTextureShape s = shape(formats[f]);
        s.width = s.height = 256;
        s.pitch = 1040;
        unsigned char *bytes = malloc(s.pitch * s.height);
        assert(bytes);
        memset(bytes, 0x5b, s.pitch * s.height);
        for (unsigned i = 0; i < 65536; i++) {
            unsigned hi = (i * 40503u + 0x1289) & 65535;
            size_t offset = f ? (i / 256) * s.pitch + (i % 256) * 4 :
                                morton(i % 256, i / 256, 0, 256, 256, 1) * 4;
            bytes[offset] = i;
            bytes[offset + 1] = i >> 8;
            bytes[offset + 2] = hi;
            bytes[offset + 3] = hi >> 8;
        }
        id<MTLBuffer> data = buffer(bytes, s.pitch * s.height);
        free(bytes);
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
        assert(r.rectangle == (f != 0) && !r.signedNormalized && !r.depth);
        assert(r.sourceLength == (f ? s.pitch * 256u : 256u * 256 * 4));
        id<MTLBuffer> out = read_texture(r.texture, 0, 0);
        finish();
        assert(*(uint32_t *)r.faults.contents == 0);
        for (unsigned i = 0; i < 65536; i++) {
            unsigned hi = (i * 40503u + 0x1289) & 65535;
            const float *p = pixel(out, 256, 256, i % 256, i / 256, 0);
            check(p[0], (float)(hi / 65535.0));
            check(p[1], (float)(i / 65535.0));
            check(p[2], (float)(i / 65535.0));
            check(p[3], 1);
        }
        s.signed_channels = 15;
        require([commands beginWithError:&error] != nil, error);
        r = upload(s, data, 0, nil, 0);
        assert(r.rectangle == (f != 0) && !r.signedNormalized && !r.depth);
        out = read_texture(r.texture, 0, 0);
        finish();
        assert(*(uint32_t *)r.faults.contents == 0);
        for (unsigned i = 0; i < 65536; i++) {
            unsigned raw = (i * 40503u + 0x1289) & 65535;
            int hi = raw >= 32768 ? (int)raw - 65536 : (int)raw,
                lo = i >= 32768 ? (int)i - 65536 : (int)i;
            const float expected[] = { hi / 32768.f, lo / 32768.f, lo / 32768.f,
                                       1 };
            const float *actual = pixel(out, 256, 256, i % 256, i / 256, 0);
            assert(!memcmp(actual, expected, sizeof(expected)));
        }
        for (unsigned mask = 1; mask < 15; mask++) {
            s.signed_channels = mask;
            NSUInteger length = 0;
            assert(![uploader sourceLengthForShape:&s
                                     paletteLength:0
                                            length:&length
                                             error:&error]);
        }
    }
    printf("Metal4 HILO16: 131072 texels/524288 channels, both unsigned16 "
           "ranges and layouts PASS\n");
    printf("Metal4 signed HILO16: 131072 bit-exact texels/524288 channels, "
           "all65536 values per word in both layouts PASS\n");
}

static void palette_yuv_tests(void)
{
    unsigned char indices[256], colors[1024];
    for (unsigned int i = 0; i < 256; i++) {
        indices[i] = 255 - i;
        colors[4 * i] = i;
        colors[4 * i + 1] = 255 - i;
        colors[4 * i + 2] = i / 2;
        colors[4 * i + 3] = 127;
    }
    id<MTLBuffer> data = buffer(indices, sizeof(indices));
    id<MTLBuffer> palette = buffer(colors, sizeof(colors));
    NV2AMetalTextureShape s =
        shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8);
    s.width = 256;
    s.height = 1;
    for (unsigned int length = 128; length <= 1024; length *= 2) {
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, palette, length);
        id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
        finish();
        assert(*(uint32_t *)r.faults.contents == (length < 1024 ? 1u : 0u));
        for (unsigned int x = 0; x < 256; x++) {
            const float *p = pixel(readback, 256, 1, x, 0, 0);
            unsigned int index = 255 - x;
            for (unsigned int k = 0; k < 4; k++) {
                const unsigned int channels[] = { index / 2, 255 - index, index,
                                                  127 };
                check(p[k], index < length / 4 ? channels[k] / 255.0f : 0);
            }
        }
    }
    const unsigned char yuy[] = { 16,  128, 235, 128, 81,  90,  81, 240,
                                  145, 54,  145, 34,  235, 128, 16, 128 };
    unsigned char uyvy[16];
    for (unsigned int i = 0; i < 16; i += 4) {
        uyvy[i] = yuy[i + 1];
        uyvy[i + 1] = yuy[i];
        uyvy[i + 2] = yuy[i + 3];
        uyvy[i + 3] = yuy[i + 2];
    }
    const unsigned int expected[2][3][3] = {
        { { 0, 0, 0 }, { 255, 255, 255 }, { 255, 0, 0 } },
        { { 0, 255, 1 }, { 0, 255, 1 }, { 255, 255, 255 } }
    };
    for (unsigned int order = 0; order < 2; order++) {
        s = shape(order ? NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_YB8CR8YA8CB8 :
                          NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8);
        s.width = 3;
        s.height = 2;
        s.pitch = 8;
        data = buffer(order ? uyvy : yuy, 16);
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
        id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
        finish();
        for (unsigned int y = 0; y < 2; y++) {
            for (unsigned int x = 0; x < 3; x++) {
                const float *p = pixel(readback, 3, 2, x, y, 0);
                for (unsigned int k = 0; k < 3; k++) {
                    check(p[k], expected[y][x][k] / 255.0f);
                }
                check(p[3], 1);
            }
        }
    }
}

static void bc_tests(void)
{
    const unsigned int formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8
    };
    const unsigned int rgb[4][3] = {
        { 255, 0, 0 }, { 0, 255, 0 }, { 170, 85, 0 }, { 85, 170, 0 }
    };
    const unsigned int dxt5alpha[2][8] = {
        { 200, 60, 180, 160, 140, 120, 100, 80 },
        { 60, 200, 88, 116, 144, 172, 0, 255 }
    };
    for (unsigned int format = 0; format < 3; format++) {
        for (unsigned int alternative = 0; alternative < 2; alternative++) {
            unsigned char block[16] = { 0 };
            unsigned int color_offset = format ? 8 : 0;
            block[color_offset + 1] = 0xf8; /* C0 red */
            block[color_offset + 2] = 0xe0;
            block[color_offset + 3] = 7; /* C1 green */
            if (!format && alternative) {
                block[0] = block[1] = 0;
                block[2] = block[3] = 255; /* transparent BC1 mode */
            }
            memset(block + color_offset + 4, 0xe4,
                   4); /* all four color selectors */
            if (format == 1) {
                for (unsigned int i = 0; i < 8; i++) {
                    block[i] = (2 * i) | ((2 * i + 1) << 4);
                }
            } else if (format == 2) {
                block[0] = alternative ? 60 : 200;
                block[1] = alternative ? 200 : 60;
                uint64_t alpha = 0;
                for (unsigned int i = 0; i < 16; i++) {
                    alpha |= (uint64_t)(i % 8) << (3 * i);
                }
                for (unsigned int i = 0; i < 6; i++) {
                    block[2 + i] = (alpha >> (8 * i)) & 255;
                }
            }
            NV2AMetalTextureShape s = shape(formats[format]);
            s.width = s.height = 4;
            id<MTLBuffer> data = buffer(block, format ? 16 : 8);
            NSError *error = nil;
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
            id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
            finish();
            for (unsigned int i = 0; i < 16; i++) {
                const float *p = pixel(readback, 4, 4, i % 4, i / 4, 0);
                for (unsigned int k = 0; k < 3; k++) {
                    unsigned int value = rgb[i % 4][k];
                    if (!format && alternative) {
                        const unsigned int gray[] = { 0, 255, 127, 0 };
                        value = gray[i % 4];
                    }
                    check(p[k], value / 255.0f);
                }
                float a = format == 1 ? i / 15.0f :
                          format == 2 ? dxt5alpha[alternative][i % 8] / 255.0f :
                          alternative && i % 4 == 3 ? 0 :
                                                      1;
                check(p[3], a);
            }
        }
    }
    for (unsigned int depth = 1; depth <= 8; depth *= 2) {
        /* BC1 volume order: chunk(Z/4), blockY, blockX, sliceWithinChunk. */
        unsigned char bytes[256] = { 0 };
        unsigned int at = 0;
        for (unsigned int chunk = 0; chunk < depth; chunk += 4) {
            unsigned int slices = depth - chunk < 4 ? depth - chunk : 4;
            for (unsigned int y = 0; y < 2; y++) {
                for (unsigned int x = 0; x < 2; x++) {
                    for (unsigned int z = 0; z < slices; z++) {
                        unsigned int r = 1 + x + 2 * y + 3 * (chunk + z);
                        bytes[at + 1] = r << 3;
                        at += 8;
                    }
                }
            }
        }
        id<MTLBuffer> data = buffer(bytes, at);
        NV2AMetalTextureShape s = shape(formats[0]);
        s.dimension = 3;
        s.width = s.height = 8;
        s.depth = depth;
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
        id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
        finish();
        for (unsigned int z = 0; z < depth; z++) {
            for (unsigned int y = 0; y < 8; y++) {
                for (unsigned int x = 0; x < 8; x++) {
                    const float *p = pixel(readback, 8, 8, x, y, z);
                    unsigned int red = 1 + x / 4 + 2 * (y / 4) + 3 * z;
                    check(p[0], (red * 255 / 31) / 255.0f);
                    check(p[1], 0);
                    check(p[2], 0);
                    check(p[3], 1);
                }
            }
        }
    }
}

static void layout_tests(void)
{
    unsigned char bytes[1024] = { 0 };
    for (unsigned int z = 0; z < 2; z++) {
        for (unsigned int y = 0; y < 4; y++) {
            for (unsigned int x = 0; x < 8; x++) {
                size_t at = 4 * morton(x, y, z, 8, 4, 2);
                bytes[at] = 83 * z;
                bytes[at + 1] = 43 * y;
                bytes[at + 2] = 29 * x;
                bytes[at + 3] = 255;
            }
        }
    }
    NV2AMetalTextureShape s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
    s.dimension = 3;
    s.width = 8;
    s.height = 4;
    s.depth = 2;
    id<MTLBuffer> data = buffer(bytes, 256);
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
    id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
    finish();
    for (unsigned int z = 0; z < 2; z++) {
        for (unsigned int y = 0; y < 4; y++) {
            for (unsigned int x = 0; x < 8; x++) {
                const float *p = pixel(readback, 8, 4, x, y, z);
                check(p[0], 29 * x / 255.0f);
                check(p[1], 43 * y / 255.0f);
                check(p[2], 83 * z / 255.0f);
                check(p[3], 1);
            }
        }
    }
    memset(bytes, 0, sizeof(bytes));
    unsigned int offset = 3;
    for (unsigned int level = 0; level < 4; level++) {
        unsigned int w = 8 >> level, h = level ? 1 : 2;
        for (unsigned int y = 0; y < h; y++) {
            for (unsigned int x = 0; x < w; x++) {
                bytes[offset + morton(x, y, 0, w, h, 1)] =
                    41 + 49 * level + x + 9 * y;
            }
        }
        offset += w * h;
    }
    s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
    s.width = 8;
    s.height = 2;
    s.levels = 4;
    s.min_level = 1;
    s.max_level = 3;
    data = buffer(bytes, offset);
    require([commands beginWithError:&error] != nil, error);
    r = upload(s, data, 3, nil, 0);
    assert(r.sourceLength == 23 && r.minLevel == 1 && r.maxLevel == 3);
    NSMutableArray<id<MTLBuffer>> *levels = [NSMutableArray array];
    for (unsigned int level = 0; level < 4; level++) {
        [levels addObject:read_texture(r.texture, level, 0)];
    }
    finish();
    for (unsigned int level = 0; level < 4; level++) {
        unsigned int w = 8 >> level, h = level ? 1 : 2;
        for (unsigned int y = 0; y < h; y++) {
            for (unsigned int x = 0; x < w; x++) {
                const float *p = pixel(levels[level], w, h, x, y, 0);
                for (unsigned int k = 0; k < 3; k++) {
                    check(p[k], (41 + 49 * level + x + 9 * y) / 255.0f);
                }
            }
        }
    }
    memset(bytes, 0, sizeof(bytes));
    for (unsigned int face = 0; face < 6; face++) {
        memset(bytes + face * 128, 17 + face * 19, 4);
        bytes[face * 128 + 4] = 91 + face * 19;
    }
    s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
    s.cubemap = YES;
    s.levels = 2;
    s.max_level = 1;
    data = buffer(bytes, 768);
    require([commands beginWithError:&error] != nil, error);
    r = upload(s, data, 0, nil, 0);
    assert(r.sourceLength == 768);
    [levels removeAllObjects];
    for (unsigned int face = 0; face < 6; face++) {
        for (unsigned int level = 0; level < 2; level++) {
            [levels addObject:read_texture(r.texture, level, face)];
        }
    }
    finish();
    for (unsigned int face = 0; face < 6; face++) {
        for (unsigned int level = 0; level < 2; level++) {
            const float *p = pixel(levels[face * 2 + level], 2 >> level,
                                   2 >> level, 0, 0, 0);
            check(p[0], (17 + face * 19 + level * 74) / 255.0f);
        }
    }
}

static void packed16_tests(void)
{
    const unsigned int formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_DEPTH_Y16_FIXED
    };
    unsigned char *bytes = malloc(65536 * 2);
    assert(bytes);
    for (unsigned int test = 0; test < 10; test++) {
        for (unsigned int v = 0; v < 65536; v++) {
            size_t at = test == 8 ?
                            v * 2 :
                            2 * morton(v % 256, v / 256, 0, 256, 256, 1);
            bytes[at] = v & 255;
            bytes[at + 1] = v >> 8;
        }
        NV2AMetalTextureShape s = shape(formats[test]);
        s.width = s.height = 256;
        s.pitch = 512;
        id<MTLBuffer> data = buffer(bytes, 65536 * 2);
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
        assert(r.signedNormalized == (test == 4));
        id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
        finish();
        for (unsigned int v = 0; v < 65536; v++) {
            float expected[4] = { 0, 0, 0, 1 };
            switch (test) {
            case 0:
            case 1:
                expected[0] = ((v >> 10) & 31) / 31.0f;
                expected[1] = ((v >> 5) & 31) / 31.0f;
                expected[2] = (v & 31) / 31.0f;
                expected[3] = test == 1 ? 1 : v >> 15;
                break;
            case 2:
                expected[0] = ((v >> 8) & 15) / 15.0f;
                expected[1] = ((v >> 4) & 15) / 15.0f;
                expected[2] = (v & 15) / 15.0f;
                expected[3] = (v >> 12) / 15.0f;
                break;
            case 3:
                expected[0] = (v >> 11) / 31.0f;
                expected[1] = ((v >> 5) & 63) / 63.0f;
                expected[2] = (v & 31) / 31.0f;
                break;
            case 4: {
                unsigned int signed_bits = v ^ 0x210;
                expected[0] = ((signed_bits >> 10) * 127 / 63) / 127.0f;
                expected[1] = fmaxf(
                    -1,
                    ((int)((signed_bits >> 5) & 31) * 255 / 31 - 128) / 127.0f);
                expected[2] = fmaxf(
                    -1, ((int)(signed_bits & 31) * 255 / 31 - 128) / 127.0f);
                break;
            }
            case 5:
                expected[0] = expected[1] = expected[2] = (v & 255) / 255.0f;
                expected[3] = (v >> 8) / 255.0f;
                break;
            case 6:
            case 7:
                expected[0] = (test == 6 ? v & 255 : v >> 8) / 255.0f;
                expected[1] = (test == 6 ? v >> 8 : v & 255) / 255.0f;
                expected[2] = (v & 255) / 255.0f;
                expected[3] = (v >> 8) / 255.0f;
                break;
            case 8:
                expected[0] = 1;
                expected[1] = expected[2] = v / 65535.0f;
                break;
            case 9:
                expected[0] = v / 65535.0f;
                expected[3] = 0;
                break;
            }
            const float *p = pixel(readback, 256, 256, v % 256, v / 256, 0);
            for (unsigned int k = 0; k < 4; k++) {
                check(p[k], expected[k]);
            }
        }
    }
    free(bytes);
}

static void border_tests(void)
{
    unsigned char bytes[4096] = { 0 };
    for (unsigned int cube = 0; cube < 2; cube++) {
        for (unsigned int face = 0; face < (cube ? 6u : 1u); face++) {
            for (unsigned int y = 0; y < 16; y++) {
                for (unsigned int x = 0; x < 16; x++) {
                    bytes[face * 256 + morton(x, y, 0, 16, 16, 1)] =
                        (5 * x + 7 * y + 17 * face) & 255;
                }
            }
        }
        NV2AMetalTextureShape s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
        s.border = YES;
        s.cubemap = cube;
        id<MTLBuffer> data = buffer(bytes, cube ? 1536 : 256);
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
        assert(r.texture.width == 16u);
        NSMutableArray<id<MTLBuffer>> *faces = [NSMutableArray array];
        for (unsigned int face = 0; face < (cube ? 6u : 1u); face++) {
            [faces addObject:read_texture(r.texture, 0, face)];
        }
        finish();
        unsigned int size = 16;
        for (unsigned int face = 0; face < faces.count; face++) {
            for (unsigned int y = 0; y < size; y++) {
                for (unsigned int x = 0; x < size; x++) {
                    unsigned int crop = 0;
                    const float *p = pixel(faces[face], size, size, x, y, 0);
                    check(p[0], ((5 * (x + crop) + 7 * (y + crop) + 17 * face) &
                                 255) /
                                    255.0f);
                }
            }
        }
    }
    for (unsigned int z = 0; z < 16; z++) {
        for (unsigned int y = 0; y < 16; y++) {
            for (unsigned int x = 0; x < 16; x++) {
                bytes[morton(x, y, z, 16, 16, 16)] = (x + 3 * y + 11 * z) & 255;
            }
        }
    }
    NV2AMetalTextureShape s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
    s.dimension = 3;
    s.depth = 2;
    s.border = YES;
    id<MTLBuffer> data = buffer(bytes, sizeof(bytes));
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
    id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
    finish();
    for (unsigned int z = 0; z < 16; z++) {
        for (unsigned int y = 0; y < 16; y++) {
            for (unsigned int x = 0; x < 16; x++) {
                const float *p = pixel(readback, 16, 16, x, y, z);
                check(p[0], ((x + 3 * y + 11 * z) & 255) / 255.0f);
            }
        }
    }
}

static void mip_and_lifetime_tests(void)
{
    unsigned char bytes[73] = { 0 };
    unsigned int at = 0;
    for (unsigned int level = 0; level < 3; level++) {
        unsigned int size = 4 >> level;
        memset(bytes + at, 37 + 51 * level, size * size * size);
        at += size * size * size;
    }
    assert(at == 73);
    NV2AMetalTextureShape s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
    s.dimension = 3;
    s.width = s.height = s.depth = 4;
    s.levels = 3;
    s.max_level = 2;
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    __weak id<MTLBuffer> source;
    NV2AMetalTextureUploadResult *r;
    @autoreleasepool {
        id<MTLBuffer> data = buffer(bytes, sizeof(bytes));
        source = data;
        r = upload(s, data, 0, nil, 0);
    }
    assert(source);
    memset(&s, 0, sizeof(s));
    NSMutableArray<id<MTLBuffer>> *levels = [NSMutableArray array];
    for (unsigned int level = 0; level < 3; level++) {
        [levels addObject:read_texture(r.texture, level, 0)];
    }
    /* A second upload in the same submission must not replace the first
     * upload's argument table or constants. */
    s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
    id<MTLBuffer> second = buffer(bytes, 4);
    NV2AMetalTextureUploadResult *other = upload(s, second, 0, nil, 0);
    id<MTLBuffer> other_read = read_texture(other.texture, 0, 0);
    finish();
    assert(!source);
    check(pixel(other_read, 2, 2, 0, 0, 0)[0], 37.0f / 255);
    for (unsigned int level = 0; level < 3; level++) {
        unsigned int size = 4 >> level;
        for (unsigned int z = 0; z < size; z++) {
            for (unsigned int y = 0; y < size; y++) {
                for (unsigned int x = 0; x < size; x++) {
                    check(pixel(levels[level], size, size, x, y, z)[0],
                          (37 + 51 * level) / 255.0f);
                }
            }
        }
    }
    for (unsigned int size = 1; size <= 2; size++) {
        unsigned char bc[] = { 0, 0xf8, 0xe0, 7, 0xe4, 0xe4, 0xe4, 0xe4 };
        id<MTLBuffer> data = buffer(bc, sizeof(bc));
        s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5);
        s.width = size;
        s.height = 1;
        require([commands beginWithError:&error] != nil, error);
        r = upload(s, data, 0, nil, 0);
        id<MTLBuffer> readback = read_texture(r.texture, 0, 0);
        finish();
        assert(r.sourceLength == 8);
        check(pixel(readback, size, 1, 0, 0, 0)[0], 1);
        if (size == 2) {
            check(pixel(readback, size, 1, 1, 0, 0)[1], 1);
        }
    }
}

static void fragment_handoff_test(unsigned format, BOOL native_sampling,
                                  BOOL rectangle, unsigned signed_mask,
                                  BOOL combiner_transfer)
{
    BOOL signed8 = format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8;
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    unsigned char bytes[64] = { 0 };
    for (unsigned int y = 0; y < 4; y++) {
        for (unsigned int x = 0; x < 4; x++) {
            if (signed8) {
                unsigned offset =
                    rectangle ? y * 4 + x : morton(x, y, 0, 4, 4, 1);
                memset(bytes + 4 * offset, x < 2 ? 127 : 128, 4);
            } else {
                bytes[morton(x, y, 0, 4, 4, 1)] = 11 * x + 31 * y;
            }
        }
    }
    id<MTLBuffer> source = buffer(bytes, sizeof(bytes));
    NV2AMetalTextureShape s = shape(format);
    s.width = s.height = 4;
    if (signed8) {
        s.signed_channels = signed_mask;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:8
                                    height:8
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:td];
    assert(target);
    NV2AMetalVertex vertices[6] = { 0 };
    const float xy[6][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 },
                             { 8, 0 }, { 8, 8 }, { 0, 8 } };
    for (unsigned int i = 0; i < 6; i++) {
        vertices[i].clip[0] = xy[i][0] / 4 - 1;
        vertices[i].clip[1] = 1 - xy[i][1] / 4;
        vertices[i].clip[2] = .5f;
        vertices[i].clip[3] = 1;
        vertices[i].texcoord[0][0] = rectangle ? 2 : .5f;
        vertices[i].texcoord[0][1] = rectangle ? 2 : .5f;
        vertices[i].texcoord[0][3] = 1;
        vertices[i].plane[0][2] = vertices[i].plane[1][2] =
            vertices[i].plane[2][2] = .5f;
    }
    id<MTLBuffer> input = buffer(vertices, sizeof(vertices));
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    unsigned mapping = signed8 ? PS_INPUTMAPPING_SIGNED_IDENTITY : 0;
    u.combiner.final_inputs[0] = PS_REGISTER_T0 | mapping;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | mapping | PS_CHANNEL_ALPHA)
                                 << 8;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 8;
    u.textures[0].dimension = 2;
    u.textures[0].rectangle = rectangle;
    u.textures[0].signed_channels = combiner_transfer ? signed_mask : 0;
    u.textures[0].scale = 1;
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *r = upload(s, source, 0, nil, 0);
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTLTexture> sampledTexture = r.texture;
    if (r.texture.pixelFormat == MTLPixelFormatRGBA16Float &&
        (!combiner_transfer || native_sampling))
        sampledTexture = test_metal_float_reference_decoded(
            commands, r.texture, r.mixedSignedHalf ? (15u ^ signed_mask) : 0);
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    NV2AMetalSamplerConfig config = {
        .filter = (2 << 16) | (2 << 24),
        .address = 3 | (3 << 8),
        .anisotropy = 1,
        .signed_channels = combiner_transfer ? signed_mask : 0,
    };
    NV2AMetalTextureBinding *binding = [sampler bindingForTexture:sampledTexture
                                                           config:&config
                                                            error:&error];
    require(binding != nil, error);
    textures[0].texture = binding.texture;
    textures[0].sampler = binding.sampler;
    u.textures[0].sampling = binding.sampling;
    u.textures[0].snorm = sampledTexture == r.texture && r.mixedSignedHalf ?
                              NV2AMetalTextureNormalizationMixedHalf :
                              0;
    id<MTLSamplerState> linear_sampler;
    if (native_sampling) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.supportArgumentBuffers = YES;
        linear_sampler = [commands.device newSamplerStateWithDescriptor:sd];
        assert(linear_sampler);
        textures[0].sampler = linear_sampler;
        u.textures[0].sampling.enabled = 0;
    }
    NV2AMetalPixelUniforms preserved = u;
    require([shader encodeVertices:input
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:textures
                              pass:pass
                      depthStencil:nil
                          commands:commands
                             error:&error],
            error);
    assert(!memcmp(&preserved, &u, sizeof(u)));
    id<MTLBuffer> readback = read_texture(target, 0, 0);
    finish();
    assert(*(uint32_t *)r.faults.contents == 0);
    for (unsigned int y = 0; y < 8; y++) {
        for (unsigned int x = 0; x < 8; x++) {
            const float *p = pixel(readback, 8, 8, x, y, 0);
            for (unsigned k = 0; k < 4; k++) {
                float expected = k == 3 ? 1 : 63.0f / 255;
                if (signed8) {
                    /* Average 127/128 after int8 decoding, then apply the
                     * combiner's signed9 transfer only to signed channels. */
                    expected = signed_mask & (1u << k) ?
                                   -1.0f / (combiner_transfer ? 255 : 256) :
                                   .5f;
                }
                check(p[k], expected);
            }
        }
    }
}

/* Independent exponent/fraction decomposition; no shader bitcast oracle. */
static float f16_texture_depth(unsigned code)
{
    return code ? ldexpf(1 + (code % 4096) / 4096.0f, (int)(code / 4096) - 7) :
                  0;
}

static BOOL shadow_expected(float sampled, float reference, unsigned function)
{
    /* Register indices: NXDK calls index1 GREATER because it names the
     * reference operand. xemu calls it LESS and compares sampled < ref. */
    const BOOL result[] = {
        NO,
        sampled<reference, sampled == reference, sampled <= reference, sampled>
            reference,
        sampled != reference, sampled >= reference, YES
    };
    return result[function];
}

/* Alternating signed-byte seams have a closed-form center sample: symmetric
 * linear/aniso taps average the two decoded codes, while one nearest tap
 * picks the center stripe. Different mip colors expose LOD/view mistakes.
 * This checks the native AF approximation, not an exact Xbox tap pattern. */
static unsigned signed_filter_code(unsigned level, unsigned channel, BOOL high)
{
    static const unsigned low[4][4] = { { 127, 126, 125, 124 },
                                        { 15, 31, 63, 95 },
                                        { 35, 55, 75, 95 },
                                        { 42, 84, 168, 210 } };
    static const unsigned upper[4][4] = { { 128, 129, 130, 131 },
                                          { 240, 224, 192, 160 },
                                          { 215, 195, 175, 155 },
                                          { 42, 84, 168, 210 } };
    return high ? upper[level][channel] : low[level][channel];
}

static float signed_filter_center(unsigned level, unsigned channel,
                                  unsigned mask, BOOL average)
{
    /* Original levels are 8,4,2,1 wide. At u=1/2, nearest picks a low
     * stripe in levels0/1 and a high stripe in level2; level3 is constant. */
    int a = signed_filter_code(level, channel, !average && level == 2);
    int b = average ? signed_filter_code(level, channel, YES) : a;
    if (mask & (1u << channel)) {
        a -= a >= 128 ? 256 : 0;
        b -= b >= 128 ? 256 : 0;
        return (a + b) / 255.0f;
    }
    return (a + b) / 510.0f;
}

static void signed_derivative_filter_tests(void)
{
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
    const unsigned channels[4][4] = {
        { 2, 1, 0, 3 }, { 0, 1, 2, 3 }, { 1, 2, 3, 0 }, { 3, 2, 1, 0 }
    };
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:8
                                    height:8
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:td];
    assert(target);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    const float xy[6][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 },
                             { 8, 0 }, { 8, 8 }, { 0, 8 } };
    unsigned draws = 0, exactPairs = 0, borderPairs = 0;
    for (unsigned format = 0; format < 8; format++) {
        BOOL rectangle = format & 1;
        for (unsigned mask = 0; mask < 16; mask++) {
            NV2AMetalTextureShape s = shape(formats[format]);
            s.width = s.height = 8;
            s.pitch = 48;
            s.levels = rectangle ? 1 : 4;
            s.max_level = s.levels - 1;
            s.signed_channels = mask;
            unsigned char bytes[512];
            memset(bytes, 0xa5, sizeof(bytes));
            unsigned offset = 16;
            for (unsigned level = 0; level < s.levels; level++) {
                unsigned w = 8 >> level;
                for (unsigned y = 0; y < w; y++)
                    for (unsigned x = 0; x < w; x++) {
                        unsigned at = rectangle ? y * s.pitch + x * 4 :
                                                  4 * morton(x, y, 0, w, w, 1);
                        for (unsigned k = 0; k < 4; k++)
                            bytes[offset + at + channels[format / 2][k]] =
                                signed_filter_code(level, k, x & 1);
                    }
                offset += rectangle ? w * s.pitch : w * w * 4;
            }
            id<MTLBuffer> source = buffer(bytes, sizeof(bytes));
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalTextureUploadResult *r = upload(s, source, 16, nil, 0);
            id<MTLTexture> reference =
                mask ? test_metal_float_reference_decoded(
                           commands, r.texture,
                           r.mixedSignedHalf ? (15u ^ mask) : 0) :
                       r.texture;
            finish();
            assert(!*(const uint32_t *)r.faults.contents);
            for (unsigned base = 0; base < (rectangle ? 1u : 2u); base++)
                for (unsigned min = 1; min <= 6; min++)
                    for (unsigned mag = 1; mag <= 2; mag++)
                        for (unsigned aniso = 1; aniso <= 8; aniso *= 2)
                            for (unsigned profile = 0; profile < 4; profile++) {
                                @autoreleasepool {
                                    /* Isotropic lambda0, lambda1.125 with
                                     * negative bias, and 4:1 footprints with
                                     * zero/positive bias. No nearest-mip tie.
                                     */
                                    float major = profile == 0 ? 1 :
                                                  profile == 1 ? exp2f(1.25f) :
                                                                 4;
                                    float minor = profile < 2 ? major : 1;
                                    int bias = profile == 1 ? -32 :
                                               profile == 3 ? 32 :
                                                              0;
                                    unsigned taps = profile < 2 ? 1 :
                                                    aniso < 4   ? aniso :
                                                                  4;
                                    float lambda = profile == 0 ? 0 :
                                                   profile == 1 ? 1.125f :
                                                   taps == 1    ? 2 :
                                                   taps == 2    ? 1 :
                                                                  0;
                                    if (profile == 3)
                                        lambda += .125f;
                                    NV2AMetalSamplerConfig config = {
                                        .filter = min << 16 | mag << 24 |
                                                  ((unsigned)bias & 0x1fff),
                                        .address = 1 | 1 << 8,
                                        .min_level = base,
                                        .max_level = s.max_level,
                                        .anisotropy = aniso,
                                        .rectangle = rectangle,
                                        .signed_channels = mask,
                                    };
                                    NV2AMetalTextureBinding *binding =
                                        [sampler bindingForTexture:r.texture
                                                            config:&config
                                                             error:&error];
                                    require(binding != nil, error);
                                    NV2AMetalVertex v[6] = { 0 };
                                    float w = 8 >> base;
                                    for (unsigned i = 0; i < 6; i++) {
                                        v[i].clip[0] = xy[i][0] / 4 - 1;
                                        v[i].clip[1] = 1 - xy[i][1] / 4;
                                        v[i].clip[2] = .5f;
                                        v[i].clip[3] = 1;
                                        v[i].texcoord[0][0] =
                                            (.5f +
                                             (xy[i][0] - 3.5f) * major / w) *
                                            (rectangle ? w : 1);
                                        v[i].texcoord[0][1] =
                                            (.5f +
                                             (xy[i][1] - 4.5f) * minor / w) *
                                            (rectangle ? w : 1);
                                        v[i].texcoord[0][3] = 1;
                                        v[i].plane[0][2] = v[i].plane[1][2] =
                                            v[i].plane[2][2] = .5f;
                                    }
                                    id<MTLBuffer> input = buffer(v, sizeof(v));
                                    NV2AMetalPixelUniforms u = { 0 };
                                    u.combiner.shader_stage_program =
                                        PS_TEXTUREMODES_PROJECT2D;
                                    u.combiner.final_inputs[0] =
                                        PS_REGISTER_T0 |
                                        PS_INPUTMAPPING_SIGNED_IDENTITY;
                                    u.combiner.final_inputs[1] =
                                        (PS_REGISTER_T0 |
                                         PS_INPUTMAPPING_SIGNED_IDENTITY |
                                         PS_CHANNEL_ALPHA)
                                        << 8;
                                    u.surface_scale[0] = u.surface_scale[1] = 1;
                                    u.clip_range[1] = u.clip_range[3] = 65535;
                                    u.clip_regions[0][2] =
                                        u.clip_regions[0][3] = 8;
                                    u.textures[0].dimension = 2;
                                    u.textures[0].rectangle = rectangle;
                                    u.textures[0].signed_channels = mask;
                                    u.textures[0].snorm =
                                        r.mixedSignedHalf ?
                                            NV2AMetalTextureNormalizationMixedHalf :
                                            0;
                                    u.textures[0].scale = 1;
                                    u.textures[0].sampling = binding.sampling;
                                    NV2AMetalPixelTexture textures[4] = { 0 };
                                    textures[0].texture = binding.texture;
                                    textures[0].sampler = binding.sampler;
                                    require([commands beginWithError:&error] !=
                                                nil,
                                            error);
                                    if (!format && mask == 1 && !base &&
                                        min == 1 && mag == 1 && aniso == 1 &&
                                        !profile) {
                                        for (unsigned invalid = 0; invalid < 7;
                                             invalid++) {
                                            NV2AMetalPixelUniforms bad = u;
                                            if (invalid == 0)
                                                bad.textures[0]
                                                    .signed_channels = 0;
                                            if (invalid == 1)
                                                bad.textures[0]
                                                    .signed_channels = 15;
                                            if (invalid == 2)
                                                bad.textures[0]
                                                    .sampling.enabled = 0;
                                            if (invalid == 3)
                                                bad.textures[0].snorm = 3;
                                            if (invalid == 4)
                                                bad.textures[0].shadow = 1;
                                            if (invalid == 5)
                                                bad.hilo16_mask = 1;
                                            if (invalid < 6) {
                                                assert(
                                                    !nv2a_metal_pixel_validate(
                                                        &bad, NULL));
                                            } else {
                                                textures[0].texture = reference;
                                                assert(![shader
                                                    encodeVertices:input
                                                             count:6
                                                         primitive:
                                                             MTLPrimitiveTypeTriangle
                                                          uniforms:&bad
                                                          textures:textures
                                                              pass:pass
                                                      depthStencil:nil
                                                          commands:commands
                                                             error:NULL]);
                                                textures[0].texture =
                                                    binding.texture;
                                            }
                                        }
                                        puts("Metal4 mixed Signed8:seven "
                                             "invalid "
                                             "sampler/mask/normalization/"
                                             "shadow/HILO/resource "
                                             "combinations rejected PASS");
                                    }
                                    require(
                                        [shader
                                            encodeVertices:input
                                                     count:6
                                                 primitive:
                                                     MTLPrimitiveTypeTriangle
                                                  uniforms:&u
                                                  textures:textures
                                                      pass:pass
                                              depthStencil:nil
                                                  commands:commands
                                                     error:&error],
                                        error);
                                    id<MTLBuffer> out =
                                        read_texture(target, 0, 0);
                                    id<MTLBuffer> paired = nil;
                                    NV2AMetalPixelUniforms preserved = u;
                                    if (mask) {
                                        NV2AMetalTextureBinding *floatBinding =
                                            [sampler bindingForTexture:reference
                                                                config:&config
                                                                 error:&error];
                                        require(floatBinding != nil, error);
                                        textures[0].texture =
                                            floatBinding.texture;
                                        textures[0].sampler =
                                            floatBinding.sampler;
                                        NV2AMetalPixelUniforms referenceU = u;
                                        referenceU.textures[0].snorm = 0;
                                        require(
                                            [shader
                                                encodeVertices:input
                                                         count:6
                                                     primitive:
                                                         MTLPrimitiveTypeTriangle
                                                      uniforms:&referenceU
                                                      textures:textures
                                                          pass:pass
                                                  depthStencil:nil
                                                      commands:commands
                                                         error:&error],
                                            error);
                                        paired = read_texture(target, 0, 0);
                                        exactPairs++;
                                    }
                                    assert(!memcmp(&u, &preserved, sizeof(u)));
                                    finish();
                                    if (paired) {
                                        for (unsigned y = 0; y < 8; y++)
                                            assert(!memcmp(
                                                pixel(out, 8, 8, 0, y, 0),
                                                pixel(paired, 8, 8, 0, y, 0),
                                                8 * 16));
                                    }
                                    if (r.mixedSignedHalf && !base &&
                                        min == 6 && mag == 2 && aniso == 8 &&
                                        profile == 3) {
                                        NV2AMetalVertex edgeVertices[6];
                                        memcpy(edgeVertices, v, sizeof(v));
                                        for (unsigned i = 0; i < 6; i++)
                                            for (unsigned k = 0; k < 2; k++)
                                                edgeVertices[i].texcoord[0][k] =
                                                    (xy[i][k] / 4 - .5f) *
                                                    (rectangle ? 8 : 1);
                                        id<MTLBuffer> edgeInput = buffer(
                                            edgeVertices, sizeof(edgeVertices));
                                        NV2AMetalPixelUniforms edge = u;
                                        for (unsigned k = 0; k < 3; k++)
                                            edge.textures[0]
                                                .sampling.address[k] = 4;
                                        for (unsigned k = 0; k < 4; k++)
                                            edge.textures[0]
                                                .sampling.border_color[k] =
                                                (k + 1) / 8.0f;
                                        for (unsigned convolution = 0;
                                             convolution < 2; convolution++) {
                                            edge.textures[0].convolution =
                                                convolution;
                                            require(
                                                [commands
                                                    beginWithError:&error] !=
                                                    nil,
                                                error);
                                            textures[0].texture =
                                                binding.texture;
                                            require(
                                                [shader
                                                    encodeVertices:edgeInput
                                                             count:6
                                                         primitive:
                                                             MTLPrimitiveTypeTriangle
                                                          uniforms:&edge
                                                          textures:textures
                                                              pass:pass
                                                      depthStencil:nil
                                                          commands:commands
                                                             error:&error],
                                                error);
                                            id<MTLBuffer> edgeOut =
                                                read_texture(target, 0, 0);
                                            NV2AMetalPixelUniforms floatEdge =
                                                edge;
                                            floatEdge.textures[0].snorm = 0;
                                            textures[0].texture = reference;
                                            require(
                                                [shader
                                                    encodeVertices:edgeInput
                                                             count:6
                                                         primitive:
                                                             MTLPrimitiveTypeTriangle
                                                          uniforms:&floatEdge
                                                          textures:textures
                                                              pass:pass
                                                      depthStencil:nil
                                                          commands:commands
                                                             error:&error],
                                                error);
                                            id<MTLBuffer> floatOut =
                                                read_texture(target, 0, 0);
                                            finish();
                                            for (unsigned y = 0; y < 8; y++)
                                                assert(
                                                    !memcmp(pixel(edgeOut, 8, 8,
                                                                  0, y, 0),
                                                            pixel(floatOut, 8,
                                                                  8, 0, y, 0),
                                                            8 * 16));
                                            borderPairs++;
                                        }
                                    }
                                    float level = !rectangle && min >= 3 ?
                                                      fmaxf(0, lambda) :
                                                      0;
                                    level = fminf(level, s.max_level - base);
                                    if (min == 3 || min == 4)
                                        level = floorf(level + .5f);
                                    unsigned a = base + (unsigned)floorf(level);
                                    unsigned b = a < s.max_level ? a + 1 : a;
                                    BOOL linear =
                                        lambda <= 0 ? mag == 2 : min % 2 == 0;
                                    for (unsigned k = 0; k < 4; k++) {
                                        float ca = signed_filter_center(
                                            a, k, mask, linear || taps > 1);
                                        float cb = signed_filter_center(
                                            b, k, mask, linear || taps > 1);
                                        float f = level - floorf(level);
                                        check(pixel(out, 8, 8, 3, 4, 0)[k],
                                              ca * (1 - f) + cb * f);
                                    }
                                    draws++;
                                }
                            }
            assert(!memcmp(source.contents, bytes, sizeof(bytes)));
        }
    }
    assert(draws == 36864 && exactPairs == 34560 && borderPairs == 224);
    printf("Metal4 mixed Signed8 border/convolution:%u bit-exact full-frame "
           "Float32 pairs PASS\n",
           borderPairs);
    printf("Metal4 half signed8/Float32: %u bit-exact 8x8 filtered image pairs "
           "PASS\n",
           exactPairs);
    printf("Metal4 signed8 derivative filters: 128 uploads/36864 draws/147456 "
           "center channels, eight formats/16 masks/six min/two mag/four AF/"
           "four biased footprints/mip views PASS\n");
}

static void f16_shadow_handoff_tests(void)
{
    const unsigned size = 256, count = size * size;
    NSError *error = nil;
    id<MTLBuffer> data =
        [commands.device newBufferWithLength:count * 2
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    assert(data && input);
    uint16_t *codes = data.contents;
    NV2AMetalVertex *v = input.contents;
    memset(v, 0, count * sizeof(*v));
    for (unsigned i = 0; i < count; i++) {
        codes[i] = i;
        v[i].clip[0] = 2 * ((i % size + .5f) / size) - 1;
        v[i].clip[1] = 1 - 2 * ((i / size + .5f) / size);
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].point_size = 1;
        v[i].plane[1][0] = v[i].plane[2][1] = size;
        for (unsigned k = 0; k < 3; k++)
            v[i].plane[k][2] = .5f;
    }
    NV2AMetalTextureShape s =
        shape(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FLOAT);
    s.width = s.height = size;
    s.pitch = size * 2;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
    id<MTLBuffer> decoded = read_texture(r.texture, 0, 0);
    finish();
    assert(r.depth && r.rectangle && *(uint32_t *)r.faults.contents == 0);
    for (unsigned i = 0; i < count; i++) {
        const float *p = pixel(decoded, size, size, i % size, i / size, 0);
        assert(p[0] == f16_texture_depth(i) / 511.9375f);
        assert(p[1] == 0 && p[2] == 1 && p[3] == 0);
        assert(p[0] * 511.9375f == f16_texture_depth(i));
        assert(codes[i] == i);
    }
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    NV2AMetalSamplerConfig config = {
        .filter = (1 << 16) | (1 << 24),
        .address = 3 | (3 << 8),
        .anisotropy = 1,
        .rectangle = YES,
    };
    NV2AMetalTextureBinding *binding = [sampler bindingForTexture:r.texture
                                                           config:&config
                                                            error:&error];
    require(binding != nil, error);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> native_sampler =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(native_sampler);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:td];
    assert(target);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    u.textures[0].dimension = 2;
    u.textures[0].scale = 1;
    u.textures[0].rectangle = 1;
    u.textures[0].shadow = 1;
    NV2AMetalPixelTexture textures[4] = { 0 };
    textures[0].texture = binding.texture;
    unsigned draws = 0;
    for (unsigned native = 0; native < 2; native++)
        for (unsigned project3 = 0; project3 < 2; project3++)
            for (unsigned relation = 0; relation < 3; relation++) {
                u.combiner.shader_stage_program =
                    project3 ? PS_TEXTUREMODES_PROJECT3D :
                               PS_TEXTUREMODES_PROJECT2D;
                u.textures[0].sampling = binding.sampling;
                if (native)
                    u.textures[0].sampling.enabled = 0;
                textures[0].sampler = native ? native_sampler : binding.sampler;
                float w = relation == 1 ? 2 : 1;
                for (unsigned i = 0; i < count; i++) {
                    float z = f16_texture_depth(i);
                    if (relation == 0)
                        z = z ? nextafterf(z, -INFINITY) : -0x1p-20f;
                    else if (relation == 2)
                        z = z ? nextafterf(z, INFINITY) : 0x1p-20f;
                    v[i].texcoord[0][0] = (i % size + .5f) * w;
                    v[i].texcoord[0][1] = (i / size + .5f) * w;
                    v[i].texcoord[0][2] = z * w;
                    v[i].texcoord[0][3] = w;
                }
                for (unsigned function = 0; function < 8; function++) {
                    u.shadow_func = function;
                    MTL4RenderPassDescriptor *pass =
                        [MTL4RenderPassDescriptor new];
                    pass.colorAttachments[0].texture = target;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    pass.colorAttachments[0].clearColor =
                        MTLClearColorMake(.25, .5, .75, .125);
                    require([commands beginWithError:&error] != nil, error);
                    require([shader encodeVertices:input
                                             count:count
                                         primitive:MTLPrimitiveTypePoint
                                          uniforms:&u
                                          textures:textures
                                              pass:pass
                                      depthStencil:nil
                                          commands:commands
                                             error:&error],
                            error);
                    id<MTLBuffer> output = read_texture(target, 0, 0);
                    finish();
                    for (unsigned i = 0; i < count; i++) {
                        float z = f16_texture_depth(i);
                        float ref =
                            project3 ?
                                fminf(511.9375f,
                                      fmaxf(0, v[i].texcoord[0][2] / w)) :
                                0;
                        if (project3 && ref >= 1.0f / 64) {
                            int exponent;
                            double fraction = frexp(ref, &exponent);
                            ref = ldexpf(1 + floor((fraction * 2 - 1) * 4096) /
                                                 4096,
                                         exponent - 1);
                        }
                        float expected = shadow_expected(z, ref, function);
                        const float *p =
                            pixel(output, size, size, i % size, i / size, 0);
                        for (unsigned k = 0; k < 4; k++)
                            if (p[k] != expected) {
                                fprintf(stderr,
                                        "F16 shadow native%u mode%u "
                                        "relation%u func%u code%u channel%u: "
                                        "got%g expected%g\n",
                                        native, project3, relation, function, i,
                                        k, p[k], expected);
                                abort();
                            }
                    }
                    draws++;
                }
            }
    printf("Metal4 F16 textures: 65536 exact decodes and %u shadow draws/"
           "6291456 texels PASS\n",
           draws);
}

static float f24_texture_depth(unsigned code)
{
    unsigned exponent = code / 65536, fraction = code % 65536;
    if (exponent == 255)
        return fraction ? NAN : INFINITY;
    return exponent ? ldexpf(1 + fraction / 65536.f, (int)exponent - 127) :
                      ldexpf(fraction / 65536.f, -126);
}

static void f24_complete_decode_test(void)
{
    /* Tile every possible code, preserving exhaustive coverage while bounding
     * readback memory. Compare the original float4 store from the same source,
     * including the exact subnormal and NaN payload bits. */
    const unsigned size = 256, count = size * size;
    const LaneCase c = lane_cases[9];
    for (unsigned batch = 0; batch < 256; batch++) {
        @autoreleasepool {
            NSError *error = nil;
            id<MTLBuffer> data = [commands.device
                newBufferWithLength:count * 4
                            options:MTLResourceStorageModeShared];
            assert(data);
            uint32_t *codes = data.contents;
            for (unsigned i = 0; i < count; i++) {
                unsigned code = batch * count + i;
                codes[i] = code << 8 | ((code * 37 + 19) & 255);
            }
            NV2AMetalTextureShape s = shape(c.format);
            s.width = s.height = size;
            s.pitch = size * 4;
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
            id<MTLTexture> control = lane_float_decoder(s, c, data, 0);
            id<MTLBuffer> decoded = read_texture(r.texture, 0, 0);
            id<MTLBuffer> old = read_texture(control, 0, 0);
            finish();
            assert(r.depth && r.rectangle &&
                   *(uint32_t *)r.faults.contents == 0);
            for (unsigned i = 0; i < count; i++) {
                unsigned code = batch * count + i;
                const void *p =
                    pixel(decoded, size, size, i % size, i / size, 0);
                const void *q = pixel(old, size, size, i % size, i / size, 0);
                uint32_t expected[] = { code << 7, 0x3f800000, 0x3f800000, 0 };
                lane_compare(p, expected, 16, "exhaustive F24 CPU bits");
                lane_compare(p, q, 16, "exhaustive F24 original Float4 store");
                assert(codes[i] == (code << 8 | ((code * 37 + 19) & 255)));
            }
        }
    }
    printf("Metal4 F24 textures: 16777216 decoded codes/67108864 channels, "
           "exact CPU bits and original Float4 store PASS\n");
}

static void f24_shadow_handoff_tests(void)
{
    const unsigned size = 256, count = size * size;
    NSError *error = nil;
    id<MTLBuffer> data =
        [commands.device newBufferWithLength:count * 4
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    assert(data && input);
    uint32_t *codes = data.contents;
    NV2AMetalVertex *v = input.contents;
    memset(v, 0, count * sizeof(*v));
    for (unsigned i = 0; i < count; i++) {
        unsigned code = i ? (((i % 254) + 1) << 16) | ((i * 7919) & 65535) : 0;
        if (i == count - 1)
            code = 0xfeffff;
        codes[i] = code << 8 | ((i * 37 + 19) & 255);
        v[i].clip[0] = 2 * ((i % size + .5f) / size) - 1;
        v[i].clip[1] = 1 - 2 * ((i / size + .5f) / size);
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].point_size = 1;
        v[i].plane[1][0] = v[i].plane[2][1] = size;
        for (unsigned k = 0; k < 3; k++)
            v[i].plane[k][2] = .5f;
    }
    NV2AMetalTextureShape s =
        shape(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FLOAT);
    s.width = s.height = size;
    s.pitch = size * 4;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *r = upload(s, data, 0, nil, 0);
    id<MTLBuffer> decoded = read_texture(r.texture, 0, 0);
    finish();
    assert(r.depth && r.rectangle && *(uint32_t *)r.faults.contents == 0);
    for (unsigned i = 0; i < count; i++) {
        const float *p = pixel(decoded, size, size, i % size, i / size, 0);
        assert(p[0] == f24_texture_depth(codes[i] >> 8));
        assert(p[1] == 1 && p[2] == 1 && p[3] == 0);
    }
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    NV2AMetalSamplerConfig config = {
        .filter = (1 << 16) | (1 << 24),
        .address = 3 | (3 << 8),
        .anisotropy = 1,
        .rectangle = YES,
    };
    NV2AMetalTextureBinding *binding = [sampler bindingForTexture:r.texture
                                                           config:&config
                                                            error:&error];
    require(binding != nil, error);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> native_sampler =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(native_sampler);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:td];
    assert(target);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = size;
    u.textures[0].dimension = 2;
    u.textures[0].scale = 1;
    u.textures[0].rectangle = 1;
    u.textures[0].shadow = 1;
    NV2AMetalPixelTexture textures[4] = { 0 };
    textures[0].texture = binding.texture;
    unsigned draws = 0;
    for (unsigned native = 0; native < 2; native++)
        for (unsigned project3 = 0; project3 < 2; project3++)
            for (unsigned relation = 0; relation < 3; relation++) {
                u.combiner.shader_stage_program =
                    project3 ? PS_TEXTUREMODES_PROJECT3D :
                               PS_TEXTUREMODES_PROJECT2D;
                u.textures[0].sampling = binding.sampling;
                if (native)
                    u.textures[0].sampling.enabled = 0;
                textures[0].sampler = native ? native_sampler : binding.sampler;
                for (unsigned i = 0; i < count; i++) {
                    float z = f24_texture_depth(codes[i] >> 8);
                    if (relation == 0)
                        z = z ? nextafterf(z, -INFINITY) : -0x1p-126f;
                    else if (relation == 2)
                        z = z ? nextafterf(z, INFINITY) : 0x1p-126f;
                    /* Keep homogeneous inputs finite at the F24 maximum. */
                    float w = relation == 1 && z < 0x1p127f ? 2 : 1;
                    v[i].texcoord[0][0] = (i % size + .5f) * w;
                    v[i].texcoord[0][1] = (i / size + .5f) * w;
                    v[i].texcoord[0][2] = z * w;
                    v[i].texcoord[0][3] = w;
                }
                for (unsigned function = 0; function < 8; function++) {
                    u.shadow_func = function;
                    MTL4RenderPassDescriptor *pass =
                        [MTL4RenderPassDescriptor new];
                    pass.colorAttachments[0].texture = target;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    pass.colorAttachments[0].clearColor =
                        MTLClearColorMake(.25, .5, .75, .125);
                    require([commands beginWithError:&error] != nil, error);
                    require([shader encodeVertices:input
                                             count:count
                                         primitive:MTLPrimitiveTypePoint
                                          uniforms:&u
                                          textures:textures
                                              pass:pass
                                      depthStencil:nil
                                          commands:commands
                                             error:&error],
                            error);
                    id<MTLBuffer> output = read_texture(target, 0, 0);
                    finish();
                    for (unsigned i = 0; i < count; i++) {
                        float z = f24_texture_depth(codes[i] >> 8);
                        float ref =
                            project3 ?
                                fminf(0x1.ffffp127f,
                                      fmaxf(0, v[i].texcoord[0][2] /
                                                   v[i].texcoord[0][3])) :
                                0;
                        float expected = shadow_expected(z, ref, function);
                        const float *p =
                            pixel(output, size, size, i % size, i / size, 0);
                        for (unsigned k = 0; k < 4; k++)
                            if (p[k] != expected) {
                                fprintf(stderr,
                                        "F24 shadow native%u mode%u "
                                        "relation%u func%u code%u channel%u: "
                                        "got%g expected%g\n",
                                        native, project3, relation, function, i,
                                        k, p[k], expected);
                                abort();
                            }
                    }
                    draws++;
                }
            }
    printf("Metal4 F24 textures: 65536 exact decodes and %u shadow draws/"
           "6291456 texels PASS\n",
           draws);
}

static void rejection_tests(void)
{
    unsigned char bytes[1024] = { 0 };
    id<MTLBuffer> data = buffer(bytes, sizeof(bytes));
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    for (unsigned int test = 0; test < 18; test++) {
        error = nil;
        NV2AMetalTextureShape s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8);
        NSUInteger offset = 0, paletteOffset = 0, paletteLength = 1024;
        switch (test) {
        case 0:
            s.format = 8;
            break;
        case 1:
            s.dimension = 1;
            break;
        case 2:
            s.width = 3;
            break;
        case 3:
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8;
            s.cubemap = YES;
            break;
        case 4:
            s.width = 0;
            break;
        case 5:
            s.levels = 0;
            break;
        case 6:
            s.max_level = 1;
            break;
        case 7:
            offset = 1025;
            break;
        case 8:
            s.cubemap = YES;
            s.width = s.height = 16;
            break;
        case 9:
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8;
            paletteLength = 16;
            break;
        case 10:
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8;
            paletteOffset = 1024;
            break;
        case 11:
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16;
            s.pitch = 2;
            break;
        case 12:
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16;
            s.pitch = 5;
            break;
        case 13:
            s.dimension = 3;
            s.depth = 3;
            break;
        case 14:
            // Valid physical cube mips, but the input span is too short.
            s.cubemap = YES;
            s.border = YES;
            s.levels = 2;
            s.max_level = 1;
            break;
        case 15:
            s.width = s.height = 16384;
            s.border = YES;
            break;
        case 16:
            s.width = 1;
            s.height = 1;
            s.levels = 2;
            s.max_level = 1;
            break;
        case 17:
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8;
            s.width = 3;
            s.pitch = 6;
            break;
        }
        assert(![uploader encodeData:data
                              offset:offset
                             palette:data
                       paletteOffset:paletteOffset
                       paletteLength:paletteLength
                               shape:&s
                            commands:commands
                               error:&error]);
        assert(error);
    }
    [commands cancel];
}

static void signed_mip_tests(void)
{
    const unsigned formats[] = { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8 };
    const unsigned channels[4][4] = {
        { 2, 1, 0, 3 }, { 0, 1, 2, 3 }, { 1, 2, 3, 0 }, { 3, 2, 1, 0 }
    };
    unsigned texels = 0;
    for (unsigned format = 0; format < 4; format++) {
        for (unsigned kind = 0; kind < 3; kind++) {
            for (unsigned mask = 0; mask < 16; mask++) {
                NV2AMetalTextureShape s = shape(formats[format]);
                s.width = s.height = 4;
                s.dimension = kind == 1 ? 3 : 2;
                s.depth = kind == 1 ? 4 : 1;
                s.cubemap = kind == 2;
                s.levels = 3;
                s.max_level = 2;
                s.signed_channels = mask;
                unsigned faces = s.cubemap ? 6 : 1;
                unsigned face_stride = kind == 1 ? 292 : kind == 2 ? 128 : 84;
                unsigned char bytes[800];
                memset(bytes, 0xa5, sizeof(bytes));
                for (unsigned face = 0; face < faces; face++) {
                    unsigned offset = 16 + face * face_stride;
                    for (unsigned level = 0; level < 3; level++) {
                        unsigned w = 4 >> level, d = kind == 1 ? w : 1;
                        for (unsigned z = 0; z < d; z++) {
                            for (unsigned y = 0; y < w; y++) {
                                for (unsigned x = 0; x < w; x++) {
                                    unsigned at =
                                        offset + 4 * morton(x, y, z, w, w, d);
                                    for (unsigned k = 0; k < 4; k++)
                                        bytes[at + k] =
                                            (17 + 13 * x + 23 * y + 37 * z +
                                             43 * level + 59 * face + 71 * k) &
                                            255;
                                }
                            }
                        }
                        offset += 4 * w * w * d;
                    }
                }
                id<MTLBuffer> input = buffer(bytes, sizeof(bytes));
                NSError *error = nil;
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalTextureUploadResult *r = upload(s, input, 16, nil, 0);
                assert(r.texture.pixelFormat == (mask ?
                                                     MTLPixelFormatRGBA16Float :
                                                     MTLPixelFormatRGBA8Unorm));
                assert(r.sourceLength == faces * face_stride &&
                       r.texture.mipmapLevelCount == 3 &&
                       r.texture.textureType ==
                           (kind == 1 ? MTLTextureType3D :
                            kind == 2 ? MTLTextureTypeCube :
                                        MTLTextureType2D));
                NSMutableArray<id<MTLBuffer>> *out = [NSMutableArray new];
                for (unsigned face = 0; face < faces; face++) {
                    for (unsigned level = 0; level < 3; level++)
                        [out addObject:test_metal_read_texture_decoded(
                                           commands, r.texture, level, face,
                                           r.mixedSignedHalf ? (15u ^ mask) :
                                                               0)];
                }
                finish();
                assert(!*(const uint32_t *)r.faults.contents);
                for (unsigned face = 0; face < faces; face++) {
                    for (unsigned level = 0; level < 3; level++) {
                        unsigned w = 4 >> level, d = kind == 1 ? w : 1;
                        for (unsigned z = 0; z < d; z++) {
                            for (unsigned y = 0; y < w; y++) {
                                for (unsigned x = 0; x < w; x++) {
                                    const float *actual = pixel(
                                        out[face * 3 + level], w, w, x, y, z);
                                    for (unsigned k = 0; k < 4; k++) {
                                        int code =
                                            (17 + 13 * x + 23 * y + 37 * z +
                                             43 * level + 59 * face +
                                             71 * channels[format][k]) &
                                            255;
                                        if ((mask & (1u << k)) && code >= 128)
                                            code -= 256;
                                        check(actual[k],
                                              code / ((mask & (1u << k)) ?
                                                          128.0f :
                                                          255.0f));
                                    }
                                    texels++;
                                }
                            }
                        }
                    }
                }
                assert(!memcmp(input.contents, bytes, sizeof(bytes)));
            }
        }
    }
    assert(texels == 14080);
    printf("Metal4 signed8 mips: 192 uploads/14080 texels, four orders/16 "
           "masks/2D/3D/cube/three levels PASS\n");
}

static void signed_channel_tests(void)
{
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
    const unsigned channels[4][4] = {
        { 2, 1, 0, 3 }, { 0, 1, 2, 3 }, { 1, 2, 3, 0 }, { 3, 2, 1, 0 }
    };
    for (unsigned format = 0; format < 8; format++) {
        for (unsigned mask = 0; mask < 16; mask++) {
            NV2AMetalTextureShape s = shape(formats[format]);
            s.width = 256;
            s.height = 1;
            s.pitch = 1040;
            s.signed_channels = mask;
            unsigned char bytes[1072];
            memset(bytes, 0xa5, sizeof(bytes));
            for (unsigned x = 0; x < 256; x++) {
                unsigned char *p = bytes + 16 + 4 * x;
                p[0] = (x + 149) & 255;
                p[1] = (x + 71) & 255;
                p[2] = x;
                p[3] = (x + 223) & 255;
            }
            id<MTLBuffer> input = buffer(bytes, sizeof(bytes));
            NSError *error = nil;
            NSUInteger length = 0;
            BOOL valid = [uploader sourceLengthForShape:&s
                                          paletteLength:0
                                                 length:&length
                                                  error:&error];
            if (!valid)
                fprintf(stderr, "Signed upload format 0x%x mask 0x%x\n",
                        s.format, mask);
            require(valid, error);
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalTextureUploadResult *r = upload(s, input, 16, nil, 0);
            assert(r.texture.pixelFormat == (mask ? MTLPixelFormatRGBA16Float :
                                                    MTLPixelFormatRGBA8Unorm));
            id<MTLBuffer> readback = test_metal_read_texture_decoded(
                commands, r.texture, 0, 0,
                r.mixedSignedHalf ? (15u ^ mask) : 0);
            finish();
            assert(r.sourceLength == (format & 1 ? 1040 : 1024));
            assert(length == r.sourceLength);
            assert(!r.signedNormalized && !r.depth);
            assert(r.mixedSignedHalf == (mask && mask != 15));
            assert(!*(const uint32_t *)r.faults.contents);
            for (unsigned x = 0; x < 256; x++) {
                const unsigned raw[] = { (x + 149) & 255, (x + 71) & 255, x,
                                         (x + 223) & 255 };
                const float *actual = pixel(readback, 256, 1, x, 0, 0);
                for (unsigned k = 0; k < 4; k++) {
                    int value = (int)raw[channels[format / 2][k]];
                    if ((mask & (1u << k)) && value >= 128)
                        value -= 256;
                    float expected =
                        value / ((mask & (1u << k)) ? 128.0f : 255.0f);
                    assert(actual[k] == expected);
                }
            }
            assert(!memcmp(input.contents, bytes, sizeof(bytes)));
        }
    }
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        NV2AMetalTextureShape s = shape(formats[0]);
        s.signed_channels = invalid ? 1 : 16;
        if (invalid == 1)
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8;
        if (invalid == 2)
            s.format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5;
        NSUInteger length = 123;
        NSError *error = nil;
        assert(![uploader sourceLengthForShape:&s
                                 paletteLength:0
                                        length:&length
                                         error:&error]);
        assert(error && !commands.commandBuffer);
    }
    printf("Metal4 signed8 upload: 32768 texels/131072 channels, 16 masks, "
           "eight formats/four channel orders PASS\n");
}

#include "test-metal-signed8-benchmark.h"
#include "test-metal-packed-native.h"
#include "test-metal-r565-upload.h"

static void mixed_signed8_allocation_test(void)
{
    NV2AMetalTextureShape s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8);
    s.width = s.height = 256;
    s.signed_channels = 5;
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:256 * 256 * 4
                                     options:MTLResourceStorageModeShared];
    assert(input);
    memset(input.contents, 0x81, input.length);
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *r = upload(s, input, 0, nil, 0);
    assert(r.mixedSignedHalf &&
           r.texture.pixelFormat == MTLPixelFormatRGBA16Float);
    id<MTLTexture> reference =
        test_metal_float_reference_decoded(commands, r.texture, 10);
    finish();
    assert(!*(uint32_t *)r.faults.contents);
    assert(r.texture.allocatedSize > 0 &&
           reference.allocatedSize >= r.texture.allocatedSize * 2);
    printf("Metal4 mixed Signed8 allocation:256x256 half %lu bytes versus "
           "Float32 %lu bytes PASS\n",
           (unsigned long)r.texture.allocatedSize,
           (unsigned long)reference.allocatedSize);
}

static void snorm565_precision_probe(void)
{
    NSError *error = nil;
    NSMutableData *encoded = [NSMutableData dataWithLength:65536 * 2];
    NSMutableData *normalized = [NSMutableData dataWithLength:65536 * 4];
    for (unsigned code = 0; code < 65536; code++) {
        uint8_t *source = (uint8_t *)encoded.mutableBytes +
                          2 * morton(code % 256, code / 256, 0, 256, 256, 1);
        source[0] = code;
        source[1] = code >> 8;
        unsigned v = code ^ (1u << 9) ^ (1u << 4);
        int8_t *texel = (int8_t *)normalized.mutableBytes + code * 4;
        texel[0] = ((v >> 10) & 63) * 127 / 63;
        texel[1] = (int)((v >> 5) & 31) * 255 / 31 - 128;
        texel[2] = (int)(v & 31) * 255 / 31 - 128;
        texel[3] = 127;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Snorm
                                     width:256
                                    height:256
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> native = [commands.device newTextureWithDescriptor:td];
    assert(native);
    [native replaceRegion:MTLRegionMake2D(0, 0, 256, 256)
              mipmapLevel:0
                withBytes:normalized.bytes
              bytesPerRow:1024];
    NV2AMetalTextureShape s = shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5);
    s.width = s.height = 256;
    require([commands beginWithError:&error] != nil, error);
    id<MTLBuffer> guest = buffer(encoded.bytes, encoded.length);
    TextureUploadTestCommands *measured = (TextureUploadTestCommands *)commands;
    measured.scratchBytes = 0;
    measured.measureScratch = YES;
    NV2AMetalTextureUploadResult *uploaded = upload(s, guest, 0, nil, 0);
    NSUInteger compactScratch = measured.scratchBytes;
    id<MTLTexture> reference =
        lane_float_decoder(s, (LaneCase){ s.format, 0, 0, 2, NO }, guest, 0);
    NSUInteger referenceScratch = measured.scratchBytes - compactScratch;
    measured.measureScratch = NO;
    assert(uploaded.texture.pixelFormat == MTLPixelFormatRGBA8Snorm &&
           uploaded.signedNormalized && !uploaded.mixedSignedHalf &&
           !uploaded.depth);
    assert(compactScratch == 262144 && referenceScratch == 1048576);
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:65536 * 48
                                     options:MTLResourceStorageModeShared];
    assert(output);
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "kernel void probe(texture2d<float,access::read> a [[texture(0)]],"
         "texture2d<float,access::read> b [[texture(1)]],"
         "texture2d<float,access::read> c [[texture(2)]],"
         "device uint4 *o [[buffer(0)]],uint2 p [[thread_position_in_grid]]){"
         "uint i=(p.y*256+p.x)*3;o[i]=as_type<uint4>(a.read(p));"
         "o[i+1]=as_type<uint4>(b.read(p));o[i+2]=as_type<uint4>(c.read(p));}";
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
    fn.name = @"probe";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    id<MTLComputePipelineState> pipeline =
        [compiler newComputePipelineStateWithDescriptor:pd
                                    compilerTaskOptions:nil
                                                  error:&error];
    require(pipeline != nil, error);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxTextureBindCount = 3;
    ad.maxBufferBindCount = 1;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> args =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(args != nil, error);
    for (id<MTLResource> resource in
         @[ native, reference, uploaded.texture, output ])
        require([commands addResource:resource error:&error], error);
    require([commands keepAlive:args error:&error], error);
    require([commands keepAlive:pipeline error:&error], error);
    [args setTexture:native.gpuResourceID atIndex:0];
    [args setTexture:reference.gpuResourceID atIndex:1];
    [args setTexture:uploaded.texture.gpuResourceID atIndex:2];
    [args setAddress:output.gpuAddress atIndex:0];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:pipeline];
    [e setArgumentTable:args];
    [e dispatchThreads:MTLSizeMake(256, 256, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [e endEncoding];
    finish();
    const uint32_t *words = output.contents;
    unsigned differences = 0, maximumULP = 0;
    for (unsigned i = 0; i < 65536; i++) {
        const int8_t *q = (const int8_t *)normalized.bytes + i * 4;
        float expected[4];
        for (unsigned k = 0; k < 4; k++) {
            expected[k] = fmaxf(q[k] / 127.f, -1.f);
            uint32_t a = words[i * 12 + k], b = words[i * 12 + 4 + k];
            assert(words[i * 12 + 8 + k] == b);
            differences += a != b;
            maximumULP = MAX(maximumULP, a > b ? a - b : b - a);
        }
        assert(!memcmp(words + i * 12 + 4, expected, sizeof(expected)));
    }
    printf("Metal4 R6G5B5 native Snorm8 precision:65536 texels/262144 channels;"
           "native/original differences=%u maximumULP=%u;independent CPU "
           "oracle PASS\n",
           differences, maximumULP);
    fflush(stdout);
    assert(!differences && !maximumULP);
    assert(!*(const uint32_t *)uploaded.faults.contents);
    assert(uploaded.texture.allocatedSize * 4 <= reference.allocatedSize);
    printf("Metal4 R6G5B5 memory:256x256 scratch=%lu/%lu bytes;native/Float32 "
           "allocated=%lu/%lu bytes PASS\n",
           (unsigned long)compactScratch, (unsigned long)referenceScratch,
           (unsigned long)uploaded.texture.allocatedSize,
           (unsigned long)reference.allocatedSize);
}
static unsigned snorm565_code(unsigned face, unsigned level, unsigned x,
                              unsigned y, unsigned z, unsigned w, unsigned h)
{
    return ((face * 31 + level * 17 + (z * h + y) * w + x) * 7919 + 123) &
           65535;
}
static void snorm565_layout_tests(void)
{
    NSError *error = nil;
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    unsigned texels = 0, subresources = 0, snapshots = 0,
             filterPairs = lane_sample_pairs;
    for (unsigned layout = 0; layout < 8; layout++) {
        @autoreleasepool {
            NV2AMetalTextureShape s =
                shape(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5);
            s.dimension = layout % 3 == 1 ? 3 : 2;
            s.cubemap = layout % 3 == 2;
            s.border = layout >= 3 && layout < 6;
            s.width = 8;
            s.height = s.cubemap ? 8 : 4;
            s.depth = s.dimension == 3 ? 2 : 1;
            s.levels = 4;
            s.max_level = 3;
            if (layout >= 6) {
                s.dimension = layout == 7 ? 3 : 2;
                s.cubemap = s.border = NO;
                s.width = s.height = s.depth = s.levels = 1;
                s.max_level = 0;
            }
            unsigned w = s.border ? 16 : s.width, h = s.border ? 16 : s.height;
            unsigned d = s.dimension == 3 ? (s.border ? 16 : s.depth) : 1;
            unsigned faces = s.cubemap ? 6 : 1;
            NSUInteger faceBytes = 0;
            for (unsigned l = 0; l < s.levels; l++)
                faceBytes += (NSUInteger)MAX(1u, w >> l) * MAX(1u, h >> l) *
                             MAX(1u, d >> l) * 2;
            NSUInteger stride =
                s.cubemap ? (faceBytes + 127) & ~(NSUInteger)127 : faceBytes;
            NSMutableData *bytes =
                [NSMutableData dataWithLength:3 + faces * stride + 7];
            memset(bytes.mutableBytes, 0xa7, bytes.length);
            for (unsigned face = 0; face < faces; face++) {
                NSUInteger base = 3 + face * stride;
                for (unsigned l = 0; l < s.levels; l++) {
                    unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                             ld = MAX(1u, d >> l);
                    for (unsigned z = 0; z < ld; z++)
                        for (unsigned y = 0; y < lh; y++)
                            for (unsigned x = 0; x < lw; x++) {
                                unsigned code =
                                    snorm565_code(face, l, x, y, z, lw, lh);
                                NSUInteger at =
                                    base + 2 * morton(x, y, z, lw, lh, ld);
                                ((uint8_t *)bytes.mutableBytes)[at] = code;
                                ((uint8_t *)bytes.mutableBytes)[at + 1] =
                                    code >> 8;
                            }
                    base += (NSUInteger)lw * lh * ld * 2;
                }
            }
            require([commands beginWithError:&error] != nil, error);
            id<MTLBuffer> source = lane_private_source(bytes);
            NV2AMetalTextureUploadResult *r = upload(s, source, 3, nil, 0);
            id<MTLTexture> reference = lane_float_decoder(
                s, (LaneCase){ s.format, 0, 0, 2, NO }, source, 3);
            assert(r.texture.pixelFormat == MTLPixelFormatRGBA8Snorm &&
                   r.signedNormalized && !r.mixedSignedHalf && !r.depth &&
                   r.sourceLength == faces * stride);
            NSMutableArray *decoded = [NSMutableArray new],
                           *old = [NSMutableArray new];
            for (unsigned face = 0; face < faces; face++)
                for (unsigned l = 0; l < s.levels; l++) {
                    [decoded addObject:read_texture(r.texture, l, face)];
                    [old addObject:read_texture(reference, l, face)];
                }
            finish();
            assert(!*(const uint32_t *)r.faults.contents);
            NSData *snapshot =
                nv2a_metal_texture_snapshot(r.texture, commands, &error);
            require(snapshot != nil, error);
            assert(lane_be((const uint8_t *)snapshot.bytes + 4) == 2 &&
                   lane_be((const uint8_t *)snapshot.bytes + 36) ==
                       NV2AMetalTextureStorageSnorm8);
            NSUInteger packed = 40;
            for (unsigned face = 0; face < faces; face++)
                for (unsigned l = 0; l < s.levels; l++) {
                    unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                             ld = MAX(1u, d >> l);
                    for (unsigned z = 0; z < ld; z++)
                        for (unsigned y = 0; y < lh; y++)
                            for (unsigned x = 0; x < lw; x++) {
                                unsigned v =
                                    snorm565_code(face, l, x, y, z, lw, lh) ^
                                    0x210;
                                int8_t raw[4] = {
                                    ((v >> 10) & 63) * 127 / 63,
                                    (int)((v >> 5) & 31) * 255 / 31 - 128,
                                    (int)(v & 31) * 255 / 31 - 128, 127
                                };
                                float expected[4];
                                for (unsigned k = 0; k < 4; k++)
                                    expected[k] = fmaxf(raw[k] / 127.f, -1.f);
                                lane_compare(pixel(decoded[face * s.levels + l],
                                                   lw, lh, x, y, z),
                                             expected, 16, "Snorm CPU");
                                lane_compare(pixel(decoded[face * s.levels + l],
                                                   lw, lh, x, y, z),
                                             pixel(old[face * s.levels + l], lw,
                                                   lh, x, y, z),
                                             16, "Snorm old GPU");
                                assert(!memcmp((const uint8_t *)snapshot.bytes +
                                                   packed,
                                               raw, 4));
                                packed += 4;
                                texels++;
                            }
                    subresources++;
                }
            assert(packed == snapshot.length);
            id<MTLTexture> restored =
                nv2a_metal_texture_restore(snapshot, commands, &error);
            require(restored != nil, error);
            NSData *again =
                nv2a_metal_texture_snapshot(restored, commands, &error);
            require(again != nil, error);
            assert([snapshot isEqual:again]);
            snapshots++;
            lane_filters(r.texture, restored, reference);
            if (s.levels > 1) {
                NV2AMetalSamplerConfig config = { .filter = 6u << 16 | 2u << 24,
                                                  .address =
                                                      1 | 2 << 8 | 3 << 16,
                                                  .anisotropy = 4,
                                                  .min_level = 1,
                                                  .max_level = s.max_level,
                                                  .bordered = s.border };
                NV2AMetalTextureBinding *view =
                    [sampler bindingForTexture:r.texture
                                        config:&config
                                         error:&error];
                NV2AMetalTextureBinding *oldView =
                    [sampler bindingForTexture:reference
                                        config:&config
                                         error:&error];
                require(view && oldView, error);
                NSData *wire =
                    nv2a_metal_texture_snapshot(view.texture, commands, &error);
                require(wire != nil, error);
                id<MTLTexture> viewRestore =
                    nv2a_metal_texture_restore(wire, commands, &error);
                require(viewRestore != nil, error);
                NV2AMetalSamplingUniforms sampling = view.sampling;
                require([sampler bindingForSnapshotTexture:viewRestore
                                                  sampling:&sampling
                                                     error:&error] != nil,
                        error);
                again =
                    nv2a_metal_texture_snapshot(viewRestore, commands, &error);
                require(again != nil, error);
                assert([wire isEqual:again]);
                snapshots++;
                lane_filters(view.texture, viewRestore, oldView.texture);
            }
        }
    }
    printf("Metal4 R6G5B5 Snorm8:8 layouts/%u subresources/%u exact texels/%u "
           "restore-resave pairs;raw signed "
           "bytes,mips/2D/3D/cube/border/1x1,offset3/private producer;%u "
           "bit-exact manual filter/view/restore pairs PASS\n",
           subresources, texels, snapshots, lane_sample_pairs - filterPairs);
}
int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[TextureUploadTestCommands alloc] initWithError:&error];
        require(commands != nil, error);
        uploader =
            [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                     error:&error];
        require(uploader != nil, error);
        if (argc == 2 && !strcmp(argv[1], "--snorm565-benchmark")) {
            texture_storage_benchmark(2);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--snorm565")) {
            snorm565_precision_probe();
            snorm565_layout_tests();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--snorm565-probe")) {
            snorm565_precision_probe();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--signed8-upload")) {
            signed_channel_tests();
            signed_mip_tests();
            mixed_signed8_allocation_test();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--signed8-filters")) {
            signed_derivative_filter_tests();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--r565-upload-benchmark")) {
            r565_upload_benchmark();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--packed-native-probe")) {
            packed_native_probe();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--packed-formats")) {
            direct_copy_tests();
            packed_native_probe();
            packed_layout_tests();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--packed-benchmark")) {
            texture_storage_benchmark(YES);
            return 0;
        }
        float_lane_tests();
        if (argc == 2 && !strcmp(argv[1], "--float-lanes"))
            return 0;
        assert(argc == 1);
        packed_native_probe();
        packed_layout_tests();
        compact_byte_tests();
        direct_copy_tests();
        compact_allocation_test();
        texture_storage_benchmark(NO);
        f16_shadow_handoff_tests();
        f24_complete_decode_test();
        f24_shadow_handoff_tests();
        format_tests();
        y16_tests();
        hilo16_tests();
        signed_channel_tests();
        signed_mip_tests();
        mixed_signed8_allocation_test();
        signed_derivative_filter_tests();
        palette_yuv_tests();
        bc_tests();
        layout_tests();
        packed16_tests();
        border_tests();
        mip_and_lifetime_tests();
        fragment_handoff_test(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8, NO, NO, 0,
                              NO);
        const unsigned signed_formats[] = {
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8,
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8,
            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8
        };
        for (unsigned f = 0; f < 8; f++) {
            for (unsigned native = 0; native < 2; native++)
                fragment_handoff_test(signed_formats[f], native, f & 1, 15, NO);
        }
        printf("Metal4 signed8 filtering: int8 seam before manual/native "
               "linear filtering, eight formats/16 draws/1024 pixels PASS\n");
        for (unsigned f = 0; f < 8; f++) {
            for (unsigned native = 0; native < 2; native++) {
                for (unsigned mask = 0; mask < 16; mask++)
                    fragment_handoff_test(signed_formats[f], native, f & 1,
                                          mask, YES);
            }
        }
        printf("Metal4 signed8 combiner transfer: eight formats/16 masks/"
               "manual+native filtering/256 draws/16384 pixels/65536 channels "
               "PASS\n");
        rejection_tests();
        printf("Metal 4 native texture upload: %u uploads PASS\n", uploads);
    }
    return 0;
}
