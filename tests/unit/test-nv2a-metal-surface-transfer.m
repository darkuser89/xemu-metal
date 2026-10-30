/*
 * Offscreen native Metal 4 surface transfer tests
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "hw/xbox/nv2a/pgraph/metal/surface-transfer.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry-types.h"
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
#import <objc/runtime.h>
#include "surface-transfer-source.h"
#include <assert.h>
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static NV2AMetalCommands *commands;
static unsigned uploads, downloads, rejects;
static BOOL measureDownload;
static NSUInteger privateDownloadBytes, avoidedScratchBytes;
static unsigned directDownloads, stagedDownloads;
static BOOL measureCopy;
static NSUInteger copyScratchBytes, copyUniformBytes;
static id<MTLBuffer> copyTransferBuffer;
@interface SurfaceTransferTestCommands : NV2AMetalCommands
@end
@implementation SurfaceTransferTestCommands
- (BOOL)addResource:(id<MTLResource>)resource error:(NSError **)error
{
    if (measureDownload && resource.storageMode == MTLStorageModePrivate &&
        [resource conformsToProtocol:@protocol(MTLBuffer)])
        privateDownloadBytes += ((id<MTLBuffer>)resource).length;
    if (measureCopy && resource != copyTransferBuffer &&
        resource.storageMode == MTLStorageModePrivate &&
        [resource conformsToProtocol:@protocol(MTLBuffer)])
        copyScratchBytes += ((id<MTLBuffer>)resource).length;
    return [super addResource:resource error:error];
}
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                     length:(NSUInteger)length
                     offset:(NSUInteger *)offset
                      error:(NSError **)error
{
    if (measureCopy)
        copyUniformBytes += length;
    return [super uploadBytes:bytes length:length offset:offset error:error];
}
@end

static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Surface transfer: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}

/* Independent mask/deposit oracle from the common swizzle implementation. */
static unsigned morton(unsigned x, unsigned y, unsigned width, unsigned height)
{
    unsigned mx = 0, my = 0, position = 1;
    for (unsigned bit = 1; bit < width || bit < height; bit <<= 1) {
        if (bit < width) {
            mx |= position;
            position <<= 1;
        }
        if (bit < height) {
            my |= position;
            position <<= 1;
        }
    }
    unsigned ox = 0, oy = 0;
    for (unsigned i = 0; i < x; i++) {
        ox = (ox - mx) & mx;
    }
    for (unsigned i = 0; i < y; i++) {
        oy = (oy - my) & my;
    }
    return ox | oy;
}

static NSUInteger span(unsigned width, unsigned height, unsigned pitch,
                       unsigned bytes, BOOL swizzle)
{
    return swizzle ? (NSUInteger)width * height * bytes :
                     (NSUInteger)(height - 1) * pitch + width * bytes;
}

static unsigned char pattern(unsigned x, unsigned y, unsigned byte)
{
    return (x * 13 + y * 29 + byte * 71 + 3) & 255;
}

static void compare_bytes(const unsigned char *actual,
                          const unsigned char *expected, NSUInteger length)
{
    for (NSUInteger i = 0; i < length; i++) {
        if (actual[i] != expected[i]) {
            fprintf(stderr, "Surface byte %zu: got %u expected %u\n", (size_t)i,
                    actual[i], expected[i]);
            abort();
        }
    }
}

static void transfer_case(NV2AMetalSurfaceConfig config, unsigned bytes,
                          BOOL private_source, BOOL independent_physical)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig original = config;
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&config
                                                   error:&error];
    require(surface != nil, error);
    config.width = config.pitch = config.scale = 0;
    assert(surface.config.width == original.width);
    config = original;
    NSUInteger length =
        span(config.width, config.height, config.pitch, bytes, config.swizzle);
    assert(surface.sourceLength == length);
    const NSUInteger source_offset = 3, destination_offset = 5;
    id<MTLBuffer> host =
        [commands.device newBufferWithLength:source_offset + length
                                     options:MTLResourceStorageModeShared];
    assert(host);
    unsigned char *raw = host.contents;
    memset(raw, 0xbd, host.length);
    for (unsigned y = 0; y < config.height; y++) {
        for (unsigned x = 0; x < config.width; x++) {
            NSUInteger at =
                source_offset +
                (config.swizzle ?
                     morton(x, y, config.width, config.height) * bytes :
                     y * config.pitch + x * bytes);
            for (unsigned b = 0; b < bytes; b++) {
                raw[at + b] = pattern(x, y, b);
            }
        }
    }
    id<MTLBuffer> source =
        private_source ?
            [commands.device
                newBufferWithLength:host.length
                            options:MTLResourceStorageModePrivate] :
            host;
    assert(source);
    require([commands beginWithError:&error] != nil, error);
    if (private_source) {
        require([commands addResource:host error:&error], error);
        require([commands addResource:source error:&error], error);
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        assert(e);
        [e copyFromBuffer:host
                 sourceOffset:0
                     toBuffer:source
            destinationOffset:0
                         size:host.length];
        [e barrierAfterStages:MTLStageAll
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
    }
    require([surface encodeUploadFromBuffer:source
                                     offset:source_offset
                                   commands:commands
                                      error:&error],
            error);
    uploads++;
    if (independent_physical) {
        unsigned width = (unsigned)surface.texture.width;
        unsigned height = (unsigned)surface.texture.height;
        unsigned pitch = (width * bytes + 255) & ~255u;
        id<MTLBuffer> physical =
            [commands.device newBufferWithLength:height * pitch
                                         options:MTLResourceStorageModeShared];
        assert(physical);
        unsigned char *p = physical.contents;
        memset(p, 0, physical.length);
        for (unsigned y = 0; y < height; y++) {
            for (unsigned x = 0; x < width; x++) {
                for (unsigned b = 0; b < bytes; b++) {
                    p[y * pitch + x * bytes + b] = pattern(x, y, b);
                }
            }
        }
        require([commands addResource:physical error:&error], error);
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        assert(e);
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e copyFromBuffer:physical
                   sourceOffset:0
              sourceBytesPerRow:pitch
            sourceBytesPerImage:0
                     sourceSize:MTLSizeMake(width, height, 1)
                      toTexture:surface.texture
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
        [e barrierAfterStages:MTLStageBlit
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
    }
    NSMutableArray<id<MTLBuffer>> *outputs = [NSMutableArray new];
    NSMutableArray<NSData *> *expectations = [NSMutableArray new];
    for (unsigned downscale = 0; downscale < 2; downscale++) {
        for (unsigned swizzle = 0; swizzle < 2; swizzle++) {
            for (unsigned flip = 0; flip < 2; flip++) {
                BOOL swizzled = swizzle && config.swizzle;
                if (swizzled && !downscale && config.scale != 1) {
                    continue;
                }
                unsigned width = config.width * (downscale ? 1 : config.scale);
                unsigned height =
                    config.height * (downscale ? 1 : config.scale);
                unsigned pitch = config.pitch * (downscale ? 1 : config.scale);
                NSUInteger output_length =
                    span(width, height, pitch, bytes, swizzled) +
                    destination_offset + 7;
                id<MTLBuffer> output = [commands.device
                    newBufferWithLength:output_length
                                options:MTLResourceStorageModeShared];
                assert(output);
                memset(output.contents, 0xcd, output_length);
                NSMutableData *expected =
                    [NSMutableData dataWithLength:output_length];
                unsigned char *e = expected.mutableBytes;
                memset(e, 0xcd, output_length);
                for (unsigned y = 0; y < height; y++) {
                    for (unsigned x = 0; x < width; x++) {
                        unsigned physical_x =
                            x * (downscale ? config.scale : 1);
                        unsigned physical_y =
                            y * (downscale ? config.scale : 1);
                        if (flip) {
                            physical_y =
                                config.height * config.scale - 1 - physical_y;
                        }
                        unsigned px = independent_physical ?
                                          physical_x :
                                          physical_x / config.scale;
                        unsigned py = independent_physical ?
                                          physical_y :
                                          physical_y / config.scale;
                        NSUInteger at =
                            destination_offset +
                            (swizzled ? morton(x, y, width, height) * bytes :
                                        y * pitch + x * bytes);
                        for (unsigned b = 0; b < bytes; b++) {
                            if (!config.color && config.floating_depth &&
                                config.format ==
                                    NV097_SET_SURFACE_FORMAT_ZETA_Z16) {
                                unsigned word = pattern(px, py, 0) |
                                                (unsigned)pattern(px, py, 1)
                                                    << 8;
                                e[at + b] = word >> (8 * b);
                            } else {
                                e[at + b] = pattern(px, py, b);
                            }
                        }
                    }
                }
                privateDownloadBytes = 0;
                measureDownload = YES;
                require([surface encodeDownloadToBuffer:output
                                                 offset:destination_offset
                                                swizzle:swizzle
                                                   flip:flip
                                              downscale:downscale
                                               commands:commands
                                                  error:&error],
                        error);
                measureDownload = NO;
                MTLPixelFormat format = surface.texture.pixelFormat;
                BOOL direct = format == MTLPixelFormatR8Unorm ||
                              format == MTLPixelFormatRG8Unorm ||
                              format == MTLPixelFormatBGRA8Unorm;
                if (direct) {
                    assert(privateDownloadBytes == 0);
                    avoidedScratchBytes +=
                        ((surface.texture.width * bytes + 255) & ~(NSUInteger)255) *
                        surface.texture.height;
                    directDownloads++;
                } else {
                    assert(privateDownloadBytes > 0);
                    stagedDownloads++;
                }
                [outputs addObject:output];
                [expectations addObject:expected];
                downloads++;
            }
        }
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    for (NSUInteger i = 0; i < outputs.count; i++) {
        compare_bytes(outputs[i].contents, expectations[i].bytes,
                      outputs[i].length);
    }
}

static void complete_words_test(unsigned format, BOOL color)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = { .format = format,
                                 .width = 256,
                                 .height = 256,
                                 .pitch = 512,
                                 .scale = 1,
                                 .color = color,
                                 .swizzle = YES };
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:65536 * 2
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:input.length
                                     options:MTLResourceStorageModeShared];
    assert(input && output);
    uint16_t *values = input.contents;
    for (unsigned i = 0; i < 65536; i++) {
        values[i] = i;
    }
    memset(output.contents, 0xfe, output.length);
    require([commands beginWithError:&error] != nil, error);
    require([surface encodeUploadFromBuffer:input
                                     offset:0
                                   commands:commands
                                      error:&error],
            error);
    require([surface encodeDownloadToBuffer:output
                                     offset:0
                                    swizzle:YES
                                       flip:NO
                                  downscale:YES
                                   commands:commands
                                      error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    compare_bytes(output.contents, input.contents, input.length);
    uploads++;
    downloads++;
}

static void complete_z24_test(BOOL floating)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = {
        .format = NV097_SET_SURFACE_FORMAT_ZETA_Z24S8,
        .width = 4096,
        .height = 4096,
        .pitch = 4096 * 4,
        .scale = 1,
        .floating_depth = floating,
    };
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:surface.sourceLength
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:input.length
                                     options:MTLResourceStorageModeShared];
    assert(input && output);
    uint32_t *data = input.contents;
    for (unsigned i = 0; i < 16777216; i++) {
        data[i] = i << 8 | ((i * 37 + 19) & 255);
    }
    require([commands beginWithError:&error] != nil, error);
    require([surface encodeUploadFromBuffer:input
                                     offset:0
                                   commands:commands
                                      error:&error],
            error);
    require([surface encodeDownloadToBuffer:output
                                     offset:0
                                    swizzle:NO
                                       flip:NO
                                  downscale:YES
                                   commands:commands
                                      error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    compare_bytes(output.contents, input.contents, input.length);
    uploads++;
    downloads++;
    printf("Metal 4 %s raw transfer: 16777216 depth/stencil words PASS\n",
           floating ? "F24" : "Z24");
    c.width = 8;
    c.height = 4;
    c.pitch = 40;
    c.scale = 2;
    c.floating_depth = floating;
    transfer_case(c, 4, YES, NO);
}

static void complete_f16_code_test(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = {
        .format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        .width = 256,
        .height = 256,
        .pitch = 512,
        .scale = 1,
        .floating_depth = YES,
    };
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    id<MTLBuffer> source =
        [commands.device newBufferWithLength:surface.sourceLength
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:source.length
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> native_result =
        [commands.device newBufferWithLength:65536 * 4
                                     options:MTLResourceStorageModeShared];
    assert(source && result && native_result);
    uint16_t *data = source.contents;
    for (unsigned i = 0; i < 65536; i++) {
        data[i] = i;
    }
    require([commands beginWithError:&error] != nil, error);
    require([surface encodeUploadFromBuffer:source
                                     offset:0
                                   commands:commands
                                      error:&error],
            error);
    require([surface encodeDownloadToBuffer:result
                                     offset:0
                                    swizzle:NO
                                       flip:NO
                                  downscale:YES
                                   commands:commands
                                      error:&error],
            error);
    require([commands addResource:native_result error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:surface.texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(256, 256, 1)
                        toBuffer:native_result
               destinationOffset:0
          destinationBytesPerRow:1024
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    const uint16_t *output = result.contents;
    const float *depth = native_result.contents;
    for (unsigned i = 0; i < 65536; i++) {
        assert(output[i] == i);
        assert(depth[i] == i / 65535.f);
    }
    uploads++;
    downloads++;
    for (unsigned swizzle = 0; swizzle < 2; swizzle++) {
        c.width = swizzle ? 8 : 7;
        c.height = swizzle ? 4 : 3;
        c.pitch = 20;
        c.scale = 3;
        c.swizzle = swizzle;
        transfer_case(c, 2, YES, NO);
    }
}

static void native_z24_values_test(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = {
        .format = NV097_SET_SURFACE_FORMAT_ZETA_Z24S8,
        .width = 256,
        .height = 256,
        .pitch = 1024,
        .scale = 1,
    };
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    NSUInteger stencil_offset = 256 * 1024;
    id<MTLBuffer> native =
        [commands.device newBufferWithLength:stencil_offset + 256 * 256
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:surface.sourceLength
                                     options:MTLResourceStorageModeShared];
    assert(native && output);
    float *depth = native.contents;
    unsigned char *stencil = (unsigned char *)native.contents + stencil_offset;
    uint32_t *expected = malloc(surface.sourceLength);
    assert(expected);
    const float special[] = {
        -1, -0.0f, 0, .5f, 1, 2, INFINITY, -INFINITY, NAN
    };
    for (unsigned i = 0; i < 65536; i++) {
        uint32_t bits = (i % 126 + 1) << 23 | (i * 7919 & 0x7fffff);
        memcpy(&depth[i], &bits, sizeof(bits));
        if (i < sizeof(special) / sizeof(*special)) {
            depth[i] = special[i];
        }
        stencil[i] = i * 37;
        double d = depth[i];
        unsigned packed = !(d > 0) ? 0 :
                          d >= 1   ? 16777215 :
                                     (unsigned)floor(d * 16777215 + .5);
        expected[i] = packed << 8 | stencil[i];
    }
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:native error:&error], error);
    require([commands addResource:surface.texture error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e copyFromBuffer:native
               sourceOffset:0
          sourceBytesPerRow:1024
        sourceBytesPerImage:0
                 sourceSize:MTLSizeMake(256, 256, 1)
                  toTexture:surface.texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)
                    options:MTLBlitOptionDepthFromDepthStencil];
    [e copyFromBuffer:native
               sourceOffset:stencil_offset
          sourceBytesPerRow:256
        sourceBytesPerImage:0
                 sourceSize:MTLSizeMake(256, 256, 1)
                  toTexture:surface.texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)
                    options:MTLBlitOptionStencilFromDepthStencil];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([surface encodeDownloadToBuffer:output
                                     offset:0
                                    swizzle:NO
                                       flip:NO
                                  downscale:YES
                                   commands:commands
                                      error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    compare_bytes(output.contents, (unsigned char *)expected,
                  surface.sourceLength);
    free(expected);
    downloads++;
}

static void native_render_handoff_test(unsigned kind)
{
    NSError *error = nil;
    BOOL stencil = kind == 1, floating = kind == 2;
    unsigned channels = kind >= 3 ? (kind - 3) / 16 + 1 : 0;
    unsigned mask = kind >= 3 ? (kind - 3) % 16 : 15;
    NV2AMetalSurfaceConfig c = {
        .format = channels == 1 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_B8 :
                  channels == 2 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8 :
                                  NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 8,
        .height = 8,
        .pitch = channels == 1 ? 10 :
                 channels == 2 ? 20 :
                                 40,
        .scale = 2,
        .color = YES,
        .swizzle = YES,
    };
    NV2AMetalSurfaceTransfer *color =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(color != nil, error);
    c.color = NO;
    c.floating_depth = floating;
    c.format = stencil ? NV097_SET_SURFACE_FORMAT_ZETA_Z24S8 :
                         NV097_SET_SURFACE_FORMAT_ZETA_Z16;
    c.pitch = stencil ? 40 : 20;
    NV2AMetalSurfaceTransfer *zeta =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(zeta != nil, error);
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:color.texture.pixelFormat
                                         depthFormat:zeta.texture.pixelFormat
                                         sampleCount:1
                                     surfaceChannels:channels
                                               error:&error];
    require(shader != nil, error);
    id<MTLBuffer> color_data =
        [commands.device newBufferWithLength:color.sourceLength
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> depth_data =
        [commands.device newBufferWithLength:zeta.sourceLength
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> color_result =
        [commands.device newBufferWithLength:color.sourceLength
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> depth_result =
        [commands.device newBufferWithLength:zeta.sourceLength
                                     options:MTLResourceStorageModeShared];
    assert(color_data && depth_data && color_result && depth_result);
    memset(color_data.contents, 0, color_data.length);
    memset(depth_data.contents, 0, depth_data.length);
    NV2AMetalVertex v[6] = { 0 };
    const float xy[][2] = { { -1, 1 }, { 1, 1 },  { -1, -1 },
                            { 1, 1 },  { 1, -1 }, { -1, -1 } };
    const float plane[3][4] = { { 0, 0, 1193046.75f, 1 },
                                { 8, 0, 1193046.75f, 1 },
                                { 0, 8, 1193046.75f, 1 } };
    for (unsigned i = 0; i < 6; i++) {
        v[i].clip[0] = xy[i][0];
        v[i].clip[1] = xy[i][1];
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].color[0][0] = v[i].color[0][2] = v[i].color[0][3] = 1;
        if (channels) {
            const float rgba[] = { 51.f / 255, 102.f / 255, 153.f / 255,
                                   204.f / 255 };
            memcpy(v[i].color[0], rgba, sizeof(rgba));
        }
        memcpy(v[i].plane, plane, sizeof(plane));
        if (!stencil) {
            for (unsigned n = 0; n < 3; n++) {
                v[i].plane[n][2] = floating ? 127.984375f : 2.75f;
            }
        }
    }
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(vertices);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = 1;
    u.surface_scale[0] = u.surface_scale[1] = 2;
    u.clip_range[1] = u.clip_range[3] = stencil  ? 16777215 :
                                        floating ? 511.9375f :
                                                   65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 16;
    u.depth_format = stencil  ? NV2AMetalPixelDepthD24 :
                     floating ? NV2AMetalPixelDepthF16 :
                                NV2AMetalPixelDepthD16;
    NV2AMetalPixelTexture t[4] = { 0 };
    NV2AMetalDrawConfig dc = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ZENABLE |
                     NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16 },
        .scissor = { 4, 6, 6, 4 },
        .scissor_enabled = YES,
    };
    if (channels)
        dc.control[0] = (dc.control[0] & ~(15u << 26)) | mask << 26;
    if (stencil) {
        dc.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 |
                        0x5a << 8 | 255 << 16 | 255u << 24;
        dc.control[2] = 1 | 1 << 4 | 3 << 8;
    }
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    require(state != nil, error);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = color.texture;
    p.colorAttachments[0].loadAction = MTLLoadActionLoad;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.depthAttachment.texture = zeta.texture;
    p.depthAttachment.loadAction = MTLLoadActionLoad;
    p.depthAttachment.storeAction = MTLStoreActionStore;
    if (stencil) {
        p.stencilAttachment.texture = zeta.texture;
        p.stencilAttachment.loadAction = MTLLoadActionLoad;
        p.stencilAttachment.storeAction = MTLStoreActionStore;
    }
    require([commands beginWithError:&error] != nil, error);
    require([color encodeUploadFromBuffer:color_data
                                   offset:0
                                 commands:commands
                                    error:&error],
            error);
    require([zeta encodeUploadFromBuffer:depth_data
                                  offset:0
                                commands:commands
                                   error:&error],
            error);
    require([shader encodeVertices:vertices
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:t
                              pass:p
                         drawState:state
                          commands:commands
                             error:&error],
            error);
    require([color encodeDownloadToBuffer:color_result
                                   offset:0
                                  swizzle:YES
                                     flip:NO
                                downscale:YES
                                 commands:commands
                                    error:&error],
            error);
    require([zeta encodeDownloadToBuffer:depth_result
                                  offset:0
                                 swizzle:YES
                                    flip:NO
                               downscale:YES
                                commands:commands
                                   error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    const uint32_t *rgba = color_result.contents, *zs = depth_result.contents;
    const uint16_t *z16 = depth_result.contents;
    for (unsigned y = 0; y < 8; y++) {
        for (unsigned x = 0; x < 8; x++) {
            unsigned at = morton(x, y, 8, 8);
            BOOL written = x >= 2 && x < 5 && y >= 3 && y < 5;
            if (channels) {
                const uint8_t *bytes = color_result.contents;
                assert(bytes[at * channels] ==
                       (written && (mask & 8) ? 153 : 0));
                if (channels == 2)
                    assert(bytes[at * 2 + 1] ==
                           (written && (mask & 4) ? 102 : 0));
            } else {
                assert(rgba[at] == (written ? 0xffff00ffu : 0));
            }
            if (stencil) {
                assert(zs[at] == (written ? 0x1234565au : 0));
            } else {
                assert(z16[at] == (written ? floating ? 0xdfff : 2 : 0));
            }
        }
    }
    if (channels && mask == 15) {
        for (unsigned dither = 0; dither < 2; dither++) {
            dc.control[0] |= dither ? NV_PGRAPH_CONTROL_0_DITHERENABLE : 0;
            // Populate the non-blended cache first; blending must still fail.
            dc.blend = 0;
            state = [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                        config:&dc
                                                         error:&error];
            require(state != nil, error);
            require([commands beginWithError:&error] != nil, error);
            require([shader encodeVertices:vertices
                                     count:6
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:t
                                      pass:p
                                 drawState:state
                                  commands:commands
                                     error:&error],
                    error);
            dc.blend = NV_PGRAPH_BLEND_EN | 2 | 1 << 4 | 1 << 8;
            state = [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                        config:&dc
                                                         error:&error];
            require(state != nil, error);
            error = nil;
            assert(![shader encodeVertices:vertices
                                     count:6
                                 primitive:MTLPrimitiveTypeTriangle
                                  uniforms:&u
                                  textures:t
                                      pass:p
                                 drawState:state
                                  commands:commands
                                     error:&error]);
            assert([error.localizedDescription
                containsString:@"do not support blending"]);
            [commands cancel];
            rejects++;
        }
    }
    uploads += 2;
    downloads += 2;
}

static void one_surface_transfers(void)
{
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8
    };
    for (unsigned f = 0; f < sizeof(formats) / sizeof(formats[0]); f++) {
        unsigned bytes = f ? 4 : 2;
        for (unsigned swizzle = 0; swizzle < 2; swizzle++)
            for (unsigned scale = 1; scale <= 3; scale++) {
                NV2AMetalSurfaceConfig c = { .format = formats[f],
                                             .width = 8,
                                             .height = 4,
                                             .pitch = 11 * bytes,
                                             .scale = scale,
                                             .color = YES,
                                             .swizzle = swizzle };
                transfer_case(c, bytes, scale == 3, NO);
            }
    }
    complete_words_test(formats[0], YES);
}

static void channel_configuration_rejections(void)
{
    const unsigned channels[] = { 3, 1, 2, 2 };
    const MTLPixelFormat formats[] = { MTLPixelFormatR8Unorm,
                                       MTLPixelFormatBGRA8Unorm,
                                       MTLPixelFormatR8Unorm,
                                       MTLPixelFormatInvalid };
    for (unsigned i = 0; i < 4; i++) {
        NSError *error = nil;
        NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
             initWithDevice:commands.device
                colorFormat:formats[i]
                depthFormat:MTLPixelFormatDepth16Unorm
                sampleCount:1
            surfaceChannels:channels[i]
                      error:&error];
        assert(!shader && error);
        rejects++;
    }
}

static void lifetime_test(void)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    __weak NV2AMetalSurfaceTransfer *borrowed;
    __weak id<MTLTexture> borrowed_texture;
    __weak id<MTLBuffer> borrowed_source;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:4 * 4 * 4
                                     options:MTLResourceStorageModeShared];
    assert(result);
    @autoreleasepool {
        NV2AMetalSurfaceConfig c = {
            .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            .width = 4,
            .height = 4,
            .pitch = 16,
            .scale = 1,
            .color = YES,
        };
        NV2AMetalSurfaceTransfer *surface =
            [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                      config:&c
                                                       error:&error];
        require(surface != nil, error);
        id<MTLBuffer> source =
            [commands.device newBufferWithLength:result.length
                                         options:MTLResourceStorageModeShared];
        assert(source);
        memset(source.contents, 0x37, source.length);
        require([surface encodeUploadFromBuffer:source
                                         offset:0
                                       commands:commands
                                          error:&error],
                error);
        require([surface encodeDownloadToBuffer:result
                                         offset:0
                                        swizzle:NO
                                           flip:NO
                                      downscale:YES
                                       commands:commands
                                          error:&error],
                error);
        borrowed = surface;
        borrowed_texture = surface.texture;
        borrowed_source = source;
    }
    assert(borrowed && borrowed_texture && borrowed_source);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    assert(!borrowed && !borrowed_texture && !borrowed_source);
    const unsigned char *bytes = result.contents;
    for (NSUInteger i = 0; i < result.length; i++) {
        assert(bytes[i] == 0x37);
    }
    uploads++;
    downloads++;
}

static void native_f16_code_rounding_test(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = {
        .format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        .width = 256,
        .height = 256,
        .pitch = 512,
        .scale = 1,
        .floating_depth = YES,
    };
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    id<MTLBuffer> native =
        [commands.device newBufferWithLength:65536 * 4
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> private_output =
        [commands.device newBufferWithLength:surface.sourceLength
                                     options:MTLResourceStorageModePrivate];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:private_output.length
                                     options:MTLResourceStorageModeShared];
    assert(native && private_output && output);
    uint16_t *expected = malloc(output.length);
    assert(expected);
    float *values = native.contents;
    for (unsigned i = 0; i < 65536; i++) {
        unsigned word = (i / 4) * 4;
        float midpoint = (float)(((double)word + .5) / 65535);
        switch (i % 4) {
        case 0:
            values[i] = word / 65535.f;
            break;
        case 1:
            values[i] = midpoint;
            break;
        case 2:
            values[i] = nextafterf(midpoint, -INFINITY);
            break;
        case 3:
            values[i] = nextafterf(midpoint, INFINITY);
            break;
        }
        expected[i] = (uint16_t)floor((double)values[i] * 65535 + .5);
    }
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:native error:&error], error);
    require([commands addResource:surface.texture error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e copyFromBuffer:native
               sourceOffset:0
          sourceBytesPerRow:1024
        sourceBytesPerImage:0
                 sourceSize:MTLSizeMake(256, 256, 1)
                  toTexture:surface.texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([surface encodeDownloadToBuffer:private_output
                                     offset:0
                                    swizzle:NO
                                       flip:NO
                                  downscale:YES
                                   commands:commands
                                      error:&error],
            error);
    require([commands addResource:output error:&error], error);
    e = [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:private_output
             sourceOffset:0
                 toBuffer:output
        destinationOffset:0
                     size:output.length];
    [e endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    compare_bytes(output.contents, (unsigned char *)expected, output.length);
    free(expected);
    downloads++;
}

static void rejection_tests(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig base = {
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 8,
        .height = 4,
        .pitch = 40,
        .scale = 2,
        .color = YES
    };
    for (unsigned i = 0; i < 12; i++) {
        NV2AMetalSurfaceConfig c = base;
        switch (i) {
        case 0:
            c.format = 0;
            break;
        case 1:
            c.width = 0;
            break;
        case 2:
            c.height = 0;
            break;
        case 3:
            c.scale = 0;
            break;
        case 4:
            c.width = 16385;
            break;
        case 5:
            c.height = UINT32_MAX;
            break;
        case 6:
            c.pitch = 30;
            break;
        case 7:
            c.pitch = 41;
            break;
        case 8:
            c.swizzle = YES;
            c.width = 7;
            break;
        case 9:
            c.scale = UINT32_MAX;
            break;
        case 10:
            c.color = NO;
            c.format = 99;
            break;
        case 11:
            c.pitch = UINT32_MAX - 3;
            break;
        }
        assert(![[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                          config:&c
                                                           error:&error]);
        assert(error);
        rejects++;
    }
    assert(![[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                      config:NULL
                                                       error:&error]);
    rejects++;
    base.swizzle = YES;
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&base
                                                   error:&error];
    require(surface != nil, error);
    id<MTLBuffer> exact =
        [commands.device newBufferWithLength:surface.sourceLength
                                     options:MTLResourceStorageModeShared];
    assert(exact);
    assert(![surface encodeUploadFromBuffer:exact
                                     offset:0
                                   commands:commands
                                      error:&error]);
    rejects++;
    require([commands beginWithError:&error] != nil, error);
    assert(![surface encodeUploadFromBuffer:exact
                                     offset:1
                                   commands:commands
                                      error:&error]);
    assert(![surface encodeUploadFromBuffer:exact
                                     offset:NSUIntegerMax
                                   commands:commands
                                      error:&error]);
    assert(![surface encodeDownloadToBuffer:exact
                                     offset:1
                                    swizzle:YES
                                       flip:NO
                                  downscale:YES
                                   commands:commands
                                      error:&error]);
    assert(![surface encodeDownloadToBuffer:exact
                                     offset:0
                                    swizzle:YES
                                       flip:NO
                                  downscale:NO
                                   commands:commands
                                      error:&error]);
    rejects += 4;
    [commands cancel];
}


static void (*original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static double downloadGPUSeconds;
static void download_feedback(id object, SEL selector,
                              MTL4CommitFeedbackHandler handler)
{
    original_feedback(object, selector, ^(id<MTL4CommitFeedback> feedback) {
      downloadGPUSeconds = feedback.GPUEndTime - feedback.GPUStartTime;
      handler(feedback);
    });
}
static int compare_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
#include "test-metal-linear-surface-copy.h"

@interface NV2AMetalSurfaceTransfer (SurfaceLazyTest)
- (BOOL)prepareComputeForUpload:(BOOL)upload error:(NSError **)error;
@end
@interface SurfaceEagerReference : NV2AMetalSurfaceTransfer
@end
@implementation SurfaceEagerReference
- (instancetype)initWithDevice:(id<MTLDevice>)device
                        config:(const NV2AMetalSurfaceConfig *)config
                         error:(NSError **)error
{
    self = [super initWithDevice:device config:config error:error];
    if (self && (![self prepareComputeForUpload:YES error:error] ||
                 ![self prepareComputeForUpload:NO error:error]))
        return nil;
    return self;
}
@end

typedef id<MTL4ArgumentTable> (*SurfaceArgumentsFactory)(
    id, SEL, MTL4ArgumentTableDescriptor *, NSError **) NS_RETURNS_RETAINED;
static SurfaceArgumentsFactory lazy_arguments_original;
static NV2AMetalShaderLibrary *(*lazy_library_original)(id, SEL, id<MTLDevice>,
                                                        const char *,
                                                        NSError **);
static id<MTLComputePipelineState> (*lazy_compute_original)(id, SEL, NSString *,
                                                            NSError **);
static _Thread_local BOOL lazy_watch;
static unsigned lazy_library_calls, lazy_compute_calls, lazy_argument_calls;
static unsigned lazy_fail;

static BOOL lazy_failure(unsigned stage, NSError **error)
{
    if (!lazy_watch || lazy_fail != stage)
        return NO;
    if (error)
        *error = [NSError errorWithDomain:@"test.metal.surface.factory"
                                     code:stage
                                 userInfo:nil];
    return YES;
}
static NV2AMetalShaderLibrary *lazy_library(id object, SEL selector,
                                            id<MTLDevice> device,
                                            const char *source, NSError **error)
{
    lazy_library_calls += lazy_watch;
    return lazy_failure(1, error) ?
               nil :
               lazy_library_original(object, selector, device, source, error);
}
static id<MTLComputePipelineState> lazy_compute(id object, SEL selector,
                                                NSString *name, NSError **error)
{
    lazy_compute_calls += lazy_watch;
    return lazy_failure(2, error) ?
               nil :
               lazy_compute_original(object, selector, name, error);
}
static id<MTL4ArgumentTable>
lazy_arguments(id object, SEL selector, MTL4ArgumentTableDescriptor *descriptor,
               NSError **error) NS_RETURNS_RETAINED;
static id<MTL4ArgumentTable>
lazy_arguments(id object, SEL selector, MTL4ArgumentTableDescriptor *descriptor,
               NSError **error)
{
    lazy_argument_calls += lazy_watch;
    return lazy_failure(3, error) ?
               nil :
               lazy_arguments_original(object, selector, descriptor, error);
}
static void lazy_begin(unsigned fail)
{
    lazy_library_calls = lazy_compute_calls = lazy_argument_calls = 0;
    lazy_fail = fail;
    lazy_watch = YES;
}
static void lazy_expect(unsigned libraries, unsigned pipelines, unsigned tables)
{
    lazy_watch = NO;
    assert(lazy_library_calls == libraries && lazy_compute_calls == pipelines &&
           lazy_argument_calls == tables);
}
static void lazy_seed(NV2AMetalSurfaceTransfer *surface, unsigned bytes)
{
    NSUInteger pitch = (surface.texture.width * bytes + 255) & ~(NSUInteger)255;
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:pitch * surface.texture.height
                                     options:MTLResourceStorageModeShared];
    assert(input);
    memset(input.contents, 0, input.length);
    for (unsigned y = 0; y < surface.texture.height; y++)
        for (unsigned x = 0; x < surface.texture.width; x++)
            for (unsigned b = 0; b < bytes; b++)
                ((uint8_t *)input.contents)[y * pitch + x * bytes + b] =
                    pattern(x, y, b);
    NSError *error = nil;
    require([commands addResource:input error:&error], error);
    require([commands addResource:surface.texture error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e copyFromBuffer:input
               sourceOffset:0
          sourceBytesPerRow:pitch
        sourceBytesPerImage:0
                 sourceSize:MTLSizeMake(surface.texture.width,
                                        surface.texture.height, 1)
                  toTexture:surface.texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
static void lazy_resource_case(unsigned format, unsigned bytes, unsigned kind)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = { .format = format,
                                 .width = 8,
                                 .height = 4,
                                 .pitch = 10 * bytes,
                                 .scale = 1,
                                 .color = YES,
                                 .swizzle = kind != 0 };
    lazy_begin(0);
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    lazy_expect(0, 0, 0);
    NSUInteger length = surface.sourceLength + 7;
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    assert(input && output);
    memset(input.contents, 0xa7, length);
    memset(output.contents, 0xcd, length);
    NSMutableData *expected = [NSMutableData dataWithLength:length];
    memset(expected.mutableBytes, 0xcd, length);
    for (unsigned y = 0; y < c.height; y++)
        for (unsigned x = 0; x < c.width; x++)
            for (unsigned b = 0; b < bytes; b++) {
                NSUInteger at =
                    (c.swizzle ? morton(x, y, c.width, c.height) * bytes :
                                 y * c.pitch + x * bytes) +
                    b;
                ((uint8_t *)input.contents)[at] = pattern(x, y, b);
                ((uint8_t *)expected.mutableBytes)[at] = pattern(x, y, b);
            }
    require([commands beginWithError:&error] != nil, error);
    if (kind == 2)
        lazy_seed(surface, bytes);
    for (unsigned call = 0; call < 3; call++) {
        BOOL upload = kind == 2 ? call == 2 : call != 2;
        lazy_begin(0);
        copy_transfer(surface, upload ? input : output, 0, upload, c.swizzle,
                      NO, YES, kind == 0);
        if (kind == 0)
            lazy_expect(0, 0, 0);
        else
            lazy_expect(call == 0, call != 1, call == 0);
        if (call == 0 && kind)
            assert(![surface valueForKey:upload ? @"download" : @"upload"]);
    }
    id table = [surface valueForKey:@"arguments"];
    assert(kind == 0 ? !table : table != nil);
    lazy_begin(0);
    copy_transfer(surface, output, 0, NO, c.swizzle, NO, YES, kind == 0);
    lazy_expect(0, 0, 0);
    assert([surface valueForKey:@"arguments"] == table);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    compare_bytes(output.contents, expected.bytes, length);
}

static void lazy_failure_case(unsigned direction, unsigned stage,
                              BOOL withError)
{
    NSError *error = nil;
    unsigned bytes = direction == 2 ? 2 : 4;
    NV2AMetalSurfaceConfig c = {
        .format = bytes == 2 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5 :
                               NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 7,
        .height = 3,
        .pitch = 10 * bytes,
        .scale = 2,
        .color = YES
    };
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    NSUInteger length = surface.sourceLength + 7;
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    NSUInteger nativeLength = c.pitch * c.scale * surface.texture.height;
    id<MTLBuffer> prefix =
        [commands.device newBufferWithLength:nativeLength
                                     options:MTLResourceStorageModeShared];
    assert(input && output && prefix);
    memset(input.contents, 0x37, length);
    memset(output.contents, 0xcd, length);
    memset(prefix.contents, 0xcd, nativeLength);
    require([commands beginWithError:&error] != nil, error);
    lazy_seed(surface, bytes);
    copyScratchBytes = copyUniformBytes = 0;
    copyBlitEncoders = copyDispatchEncoders = 0;
    copyTransferBuffer = direction == 0 ? input : output;
    measureCopy = YES;
    lazy_begin(stage);
    BOOL ok = direction == 0 ?
                  [surface encodeUploadFromBuffer:input
                                           offset:0
                                         commands:commands
                                            error:withError ? &error : NULL] :
                  [surface encodeDownloadToBuffer:output
                                           offset:0
                                          swizzle:NO
                                             flip:NO
                                        downscale:YES
                                         commands:commands
                                            error:withError ? &error : NULL];
    lazy_expect(1, stage > 1, stage > 2);
    measureCopy = NO;
    copyTransferBuffer = nil;
    assert(!ok && (withError ? error != nil : error == nil));
    assert(!copyScratchBytes && !copyUniformBytes && !copyBlitEncoders &&
           !copyDispatchEncoders);
    error = nil;
    lazy_begin(stage);
    copy_transfer(surface, prefix, 0, NO, NO, NO, NO, YES);
    lazy_expect(0, 0, 0);
    lazy_begin(0);
    copy_transfer(surface, direction == 0 ? input : output, 0, direction == 0,
                  NO, NO, YES, NO);
    lazy_expect(stage == 1, stage < 3, 1);
    if (direction == 0)
        require([surface encodeDownloadToBuffer:output
                                         offset:0
                                        swizzle:NO
                                           flip:NO
                                      downscale:YES
                                       commands:commands
                                          error:&error],
                error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    for (NSUInteger i = 0; i < length; i++) {
        BOOL pixel = i / c.pitch < c.height && i % c.pitch < c.width * bytes;
        uint8_t value = direction == 0 ?
                            0x37 :
                            pattern((i % c.pitch) / bytes * 2,
                                    (unsigned)(i / c.pitch) * 2, i % bytes);
        assert(((uint8_t *)output.contents)[i] == (pixel ? value : 0xcd));
    }
    for (unsigned y = 0; y < surface.texture.height; y++)
        for (unsigned x = 0; x < c.width * c.scale; x++)
            for (unsigned b = 0; b < bytes; b++)
                assert(((uint8_t *)prefix
                            .contents)[y * c.pitch * c.scale + x * bytes + b] ==
                       pattern(x, y, b));
}

static double lazy_seconds(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static void lazy_setup_benchmark(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = { .format =
                                     NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                                 .width = 640,
                                 .height = 480,
                                 .pitch = 2560,
                                 .scale = 1,
                                 .color = YES };
    double first[2] = { 0 };
    NV2AMetalSurfaceTransfer *anchor = nil;
    for (unsigned variant = 0; variant < 2; variant++) {
        double start = lazy_seconds();
        lazy_begin(0);
        NV2AMetalSurfaceTransfer *surface =
            variant ?
                [[SurfaceEagerReference alloc] initWithDevice:commands.device
                                                       config:&c
                                                        error:&error] :
                [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                          config:&c
                                                           error:&error];
        lazy_expect(variant, 2 * variant, variant);
        first[variant] = lazy_seconds() - start;
        require(surface != nil, error);
        if (variant)
            anchor = surface;
    }
    double samples[2][9] = { 0 };
    for (unsigned iteration = 0; iteration < 11; iteration++)
        for (unsigned order = 0; order < 2; order++) {
            @autoreleasepool {
                unsigned variant = (iteration + order) & 1;
                double start = lazy_seconds();
                lazy_begin(0);
                NV2AMetalSurfaceTransfer *surface =
                    variant ? [[SurfaceEagerReference alloc]
                                  initWithDevice:commands.device
                                          config:&c
                                           error:&error] :
                              [[NV2AMetalSurfaceTransfer alloc]
                                  initWithDevice:commands.device
                                          config:&c
                                           error:&error];
                lazy_expect(variant, 2 * variant, variant);
                double elapsed = lazy_seconds() - start;
                require(surface != nil, error);
                assert(surface.texture.width == anchor.texture.width &&
                       surface.texture.pixelFormat ==
                           anchor.texture.pixelFormat);
                if (iteration >= 2)
                    samples[variant][iteration - 2] = elapsed;
            }
        }
    for (unsigned variant = 0; variant < 2; variant++)
        qsort(samples[variant], 9, sizeof(double), compare_double);
    printf("Metal4 lazy surface setup:640x480 first-instance CPU "
           "lazy/eager=%.6f/%.6fms;warm median=%.6f/%.6fms;11 alternating "
           "pairs/2 warmups;factory requests per object "
           "library/pipeline/table=0/0/0 versus1/2/1 PASS\n",
           first[0] * 1000, first[1] * 1000, samples[0][4] * 1000,
           samples[1][4] * 1000);
}

static void lazy_surface_tests(void)
{
    Method library =
        class_getClassMethod(NV2AMetalShaderLibrary.class,
                             @selector(sharedWithDevice:source:error:));
    Method compute = class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                             @selector(computeFunction:error:));
    Method arguments = class_getInstanceMethod(
        object_getClass(commands.device),
        @selector(newArgumentTableWithDescriptor:error:));
    assert(library && compute && arguments);
    lazy_library_original =
        (void *)method_setImplementation(library, (IMP)lazy_library);
    lazy_compute_original =
        (void *)method_setImplementation(compute, (IMP)lazy_compute);
    lazy_arguments_original =
        (void *)method_setImplementation(arguments, (IMP)lazy_arguments);
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    id<MTL4ComputeCommandEncoder> probe =
        [commands.commandBuffer computeCommandEncoder];
    assert(probe);
    Method end =
        class_getInstanceMethod(object_getClass(probe), @selector(endEncoding));
    assert(end);
    copy_end_original = (void *)method_setImplementation(end, (IMP)copy_end);
    [probe endEncoding];
    [commands cancel];
    @try {
        lazy_setup_benchmark();
        const unsigned formats[] = {
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8
        };
        for (unsigned f = 0; f < 10; f++)
            for (unsigned kind = 0; kind < 3; kind++)
                lazy_resource_case(formats[f],
                                   f < 3 || f == 9 ? 2 :
                                   f == 8          ? 1 :
                                                     4,
                                   kind);
        for (unsigned direction = 0; direction < 3; direction++)
            for (unsigned stage = 1; stage <= 3; stage++)
                for (unsigned withError = 0; withError < 2; withError++)
                    lazy_failure_case(direction, stage, withError);
    } @finally {
        lazy_watch = measureCopy = NO;
        copyTransferBuffer = nil;
        method_setImplementation(library, (IMP)lazy_library_original);
        method_setImplementation(compute, (IMP)lazy_compute_original);
        method_setImplementation(arguments, (IMP)lazy_arguments_original);
        method_setImplementation(end, (IMP)copy_end_original);
    }
    puts("Metal4 lazy surface resources:10 formats/30 "
         "direct,upload-first,download-first GPU cases;zero compute resources "
         "for blits,one direction at first fallback,one immutable pipeline per "
         "direction and one per-surface table reused;exact bytes PASS");
    puts("Metal4 lazy surface retries:18 library/pipeline/table injected "
         "failures across upload/raw-download/color-download,with/without "
         "NSError;zero partial encoders/uniform/scratch,following blit and "
         "retry preserve GPU prefix/output/padding PASS");
}
static void direct_download_comparison(void)
{
    NSError *error = nil;
    id<MTLDevice> device = commands.device;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = @(metal_shader_source);
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
    fn.name = @"nv2a_surface_download";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    id<MTLComputePipelineState> legacy =
        [compiler newComputePipelineStateWithDescriptor:pd
                                    compilerTaskOptions:nil
                                                  error:&error];
    require(legacy != nil, error);
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    assert(feedback);
    original_feedback =
        (void *)method_setImplementation(feedback, (IMP)download_feedback);
    for (unsigned scale = 1; scale <= 4; scale++) {
        @autoreleasepool {
            NV2AMetalSurfaceConfig c = {
                .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                .width = 640,
                .height = 480,
                .pitch = 640 * 4,
                .scale = scale,
                .color = YES
            };
            NV2AMetalSurfaceTransfer *direct =
                [[NV2AMetalSurfaceTransfer alloc] initWithDevice:device
                                                          config:&c
                                                           error:&error];
            require(direct != nil, error);
            NV2AMetalSurfaceTransfer *raw =
                [[SurfaceCopyReference alloc] initWithDevice:device
                                                          config:&c
                                                           error:&error];
            require(raw != nil, error);
            /* Test-only reference: run the preserved original pipeline and
             * staging branch on this second surface. Production uses direct
             * reads for these formats; never expose a compatibility switch. */
            [raw setValue:legacy forKey:@"download"];
            [raw setValue:@NO forKey:@"directColorDownload"];
            NSUInteger length = c.pitch * c.height;
            id<MTLBuffer> input =
                [device newBufferWithLength:length
                                    options:MTLResourceStorageModeShared];
            assert(input);
            uint8_t *bytes = input.contents;
            for (NSUInteger i = 0; i < length; i++)
                bytes[i] = (i * 37 + i / c.pitch * 13) & 255;
            id<MTLBuffer> outputs[2] = {
                [device newBufferWithLength:length
                                    options:MTLResourceStorageModeShared],
                [device newBufferWithLength:length
                                    options:MTLResourceStorageModeShared]
            };
            assert(outputs[0] && outputs[1]);
            require([commands beginWithError:&error] != nil, error);
            require([direct encodeUploadFromBuffer:input
                                            offset:0
                                          commands:commands
                                             error:&error],
                    error);
            require([raw encodeUploadFromBuffer:input
                                         offset:0
                                       commands:commands
                                          error:&error],
                    error);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            double samples[2][9] = { 0 };
            BOOL timingAvailable = YES;
            NSUInteger legacyScratch = ((c.width * scale * 4 + 255) & ~255u) *
                                       (NSUInteger)c.height * scale;
            for (unsigned iteration = 0; iteration < 11; iteration++) {
                for (unsigned order = 0; order < 2; order++) {
                    unsigned variant = (iteration + order) & 1;
                    NV2AMetalSurfaceTransfer *surface = variant ? raw : direct;
                    require([commands beginWithError:&error] != nil, error);
                    measureDownload = YES;
                    privateDownloadBytes = 0;
                    require([surface encodeDownloadToBuffer:outputs[variant]
                                                     offset:0
                                                    swizzle:NO
                                                       flip:iteration & 1
                                                  downscale:YES
                                                   commands:commands
                                                      error:&error],
                            error);
                    measureDownload = NO;
                    assert(privateDownloadBytes ==
                           (variant ? legacyScratch : 0));
                    downloadGPUSeconds = 0;
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                    if (iteration >= 2) {
                        samples[variant][iteration - 2] = downloadGPUSeconds;
                        timingAvailable &= isfinite(downloadGPUSeconds) &&
                                           downloadGPUSeconds > 0;
                    }
                }
                compare_bytes(outputs[0].contents, outputs[1].contents, length);
            }
            qsort(samples[0], 9, sizeof(double), compare_double);
            qsort(samples[1], 9, sizeof(double), compare_double);
            printf(
                "Metal4 download comparison: 640x480 scale=%u, 11 exact paired "
                "readbacks, scratch direct/raw=0/%zu bytes; ",
                scale, (size_t)legacyScratch);
            if (timingAvailable)
                printf("GPU median direct/raw=%.6f/%.6f ms (9 alternating "
                       "samples, "
                       "2 warmups) PASS\n",
                       samples[0][4] * 1000, samples[1][4] * 1000);
            else
                puts("GPU timestamps unavailable; byte/allocation checks PASS");
        }
    }
    method_setImplementation(feedback, (IMP)original_feedback);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[SurfaceTransferTestCommands alloc] initWithError:&error];
        require(commands != nil, error);
        lazy_surface_tests();
        if (argc == 2 && !strcmp(argv[1], "--lazy-resources"))
            return 0;
        linear_surface_copy_tests();
        if (argc == 2 && !strcmp(argv[1], "--linear-copy"))
            return 0;
        assert(argc == 1);
        const unsigned formats[] = {
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
            NV097_SET_SURFACE_FORMAT_ZETA_Z16,
            NV097_SET_SURFACE_FORMAT_ZETA_Z24S8,
        };
        const unsigned bytes[] = { 2, 2, 4, 4, 1, 2, 2, 4 };
        for (unsigned f = 0; f < 8; f++) {
            for (unsigned swizzle = 0; swizzle < 2; swizzle++) {
                for (unsigned scale = 1; scale <= 3; scale++) {
                    NV2AMetalSurfaceConfig c = { .format = formats[f],
                                                 .width = swizzle ? 8 : 7,
                                                 .height = swizzle ? 4 : 3,
                                                 .pitch = (swizzle ? 11 : 10) *
                                                          bytes[f],
                                                 .scale = scale,
                                                 .color = f < 6,
                                                 .swizzle = swizzle };
                    transfer_case(c, bytes[f], scale == 3, NO);
                }
            }
            NV2AMetalSurfaceConfig c = { .format = formats[f],
                                         .width = 8,
                                         .height = 4,
                                         .pitch = 11 * bytes[f],
                                         .scale = 3,
                                         .color = f < 6,
                                         .swizzle = YES };
            transfer_case(c, bytes[f], YES, f != 7);
        }
        /* Every byte value in every native channel, independent physical
         * subpixels, non-power-of-two scale and power-of-two swizzle. */
        const unsigned byteFormats[] = {
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8
        };
        for (unsigned f = 0; f < 7; f++) {
            unsigned pixelBytes = f == 5 ? 1 : f == 6 ? 2 : 4;
            for (unsigned scale = 1; scale <= 4; scale++) {
                NV2AMetalSurfaceConfig c = {
                    .format = byteFormats[f], .width = 256, .height = 4,
                    .pitch = 259 * pixelBytes, .scale = scale,
                    .color = YES, .swizzle = YES
                };
                transfer_case(c, pixelBytes, YES, YES);
            }
        }
        complete_words_test(formats[0], YES);
        complete_words_test(formats[1], YES);
        complete_words_test(formats[5], YES);
        complete_words_test(formats[6], NO);
        complete_z24_test(NO);
        complete_z24_test(YES);
        complete_f16_code_test();
        native_f16_code_rounding_test();
        native_z24_values_test();
        native_render_handoff_test(0);
        native_render_handoff_test(1);
        native_render_handoff_test(2);
        for (unsigned kind = 3; kind < 35; kind++)
            native_render_handoff_test(kind);
        one_surface_transfers();
        channel_configuration_rejections();
        lifetime_test();
        rejection_tests();
        direct_download_comparison();
        printf("Metal4 direct color download: %u zero-scratch downloads, "
               "%u raw staging controls; %zu logical scratch bytes avoided "
               "over tested transfers PASS\n", directDownloads, stagedDownloads,
               (size_t)avoidedScratchBytes);
        printf("Metal 4 surface transfer: %u uploads, %u downloads, %u rejects "
               "PASS\n",
               uploads, downloads, rejects);
    }
    return 0;
}
