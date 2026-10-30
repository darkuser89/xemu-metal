/* Isolated Metal4 scanout/PVIDEO composition, independent scalar GL equations.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/scanout.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-upload.h"
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#include "test-metal-texture-alias.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static NV2AMetalCommands *commands;
static float source_data[4][4][4], overlay_data[4][4][4];
static unsigned images, pixels, rejects, boundary_steps;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Scanout: %s\n", error.localizedDescription.UTF8String);
        abort();
    }
}
static void linear(const float data[4][4][4], double x, double y, BOOL border,
                   double out[4])
{
    if (!border) {
        x -= floor(x);
        y -= floor(y);
    }
    x = x * 4 - .5;
    y = y * 4 - .5;
    int ix = floor(x), iy = floor(y);
    double fx = x - ix, fy = y - iy;
    for (unsigned k = 0; k < 4; k++) {
        out[k] = 0;
        for (unsigned dy = 0; dy < 2; dy++)
            for (unsigned dx = 0; dx < 2; dx++) {
                int a = ix + dx, b = iy + dy;
                if (border && (a < 0 || a >= 4 || b < 0 || b >= 4))
                    continue;
                a = (a % 4 + 4) % 4;
                b = (b % 4 + 4) % 4;
                out[k] +=
                    data[b][a][k] * (dx ? fx : 1 - fx) * (dy ? fy : 1 - fy);
            }
    }
}
static id<MTLTexture> texture(MTLPixelFormat format, unsigned w, unsigned h,
                              MTLTextureUsage usage)
{
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = usage;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:d];
    assert(t);
    return t;
}
static void reference(unsigned x, unsigned y, const NV2AMetalScanoutUniforms *u,
                      double out[4])
{
    linear(source_data, (x + .5) / u->output_size[0],
           (y + .5) / 4 / u->line_offset, u->source_border, out);
    if (!u->overlay_enable)
        return;
    double sx = x, sy = u->output_size[1] - 1 - y;
    if (sx < u->overlay_rect[0] || sy < u->overlay_rect[1] ||
        sx > u->overlay_rect[0] + u->overlay_rect[2] ||
        sy > u->overlay_rect[1] + u->overlay_rect[3])
        return;
    if (u->color_key_enable &&
        (out[0] != u->color_key[0] || out[1] != u->color_key[1] ||
         out[2] != u->color_key[2]))
        return;
    double tx =
        (u->overlay_input[0] + (sx - u->overlay_rect[0]) * u->overlay_scale[2] *
                                   u->overlay_scale[0]) /
        4;
    double ty =
        -(u->overlay_input[1] + (sy - u->overlay_rect[1]) *
                                    u->overlay_scale[2] * u->overlay_scale[1]) /
        4;
    linear(overlay_data, tx, ty, NO, out);
}
static double quantize(double x, unsigned bits)
{
    unsigned n = (1u << bits) - 1;
    return floor(fmin(1, fmax(0, x)) * n + .5) / n;
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 4; x++)
                for (unsigned k = 0; k < 4; k++) {
                    source_data[y][x][k] =
                        ((x * 3 + y * 7 + k * 11) % 19) / 20.f;
                    overlay_data[y][x][k] =
                        ((x * 13 + y * 5 + k * 3) % 17) / 18.f;
                }
        id<MTLTexture> source =
            texture(MTLPixelFormatRGBA32Float, 4, 4, MTLTextureUsageShaderRead);
        id<MTLTexture> overlay =
            texture(MTLPixelFormatRGBA32Float, 4, 4, MTLTextureUsageShaderRead);
        [source replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                  mipmapLevel:0
                    withBytes:source_data
                  bytesPerRow:64];
        [overlay replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                   mipmapLevel:0
                     withBytes:overlay_data
                   bytesPerRow:64];
        MTLPixelFormat formats[] = {
            MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA8Unorm,
            MTLPixelFormatBGRA8Unorm,  MTLPixelFormatB5G6R5Unorm,
            MTLPixelFormatBGR5A1Unorm, MTLPixelFormatR8Unorm,
            MTLPixelFormatRG8Unorm
        };
        for (unsigned f = 0; f < 7; f++) {
            NV2AMetalScanout *scanout =
                [[NV2AMetalScanout alloc] initWithDevice:commands.device
                                             pixelFormat:formats[f]
                                                   error:&error];
            require(scanout != nil, error);
            for (unsigned test = 0; test < 18; test++) {
                NV2AMetalScanoutUniforms u = { .output_size = { 6, 7 },
                                               .line_offset = 1,
                                               .overlay_enable = test >= 4,
                                               .overlay_rect = { 1, 2, 3, 3 },
                                               .overlay_scale = { 1, 1, 1 },
                                               .source_border = test % 2 };
                if (test == 2 || test == 3)
                    u.line_offset = 2;
                if (test == 5)
                    u.overlay_input[0] = .375;
                if (test == 6)
                    u.overlay_input[1] = .75;
                if (test == 7)
                    u.overlay_input[1] = -.75;
                if (test == 8)
                    u.overlay_scale[0] = .5;
                if (test == 9)
                    u.overlay_scale[1] = 1.5;
                if (test == 10)
                    u.overlay_scale[2] = .5;
                if (test == 11)
                    u.overlay_rect[1] = 0;
                if (test == 12)
                    u.overlay_rect[2] = 0;
                if (test == 13)
                    u.overlay_rect[3] = 0;
                if (test == 14)
                    u.color_key_enable = 1;
                if (test == 15) {
                    u.overlay_rect[0] = 20;
                    u.overlay_rect[1] = 20;
                }
                if (test >= 16)
                    u.dither = 1;
                id<MTLTexture> target = texture(formats[f], 6, 7,
                                                MTLTextureUsageRenderTarget |
                                                    MTLTextureUsageShaderRead);
                require([commands beginWithError:&error] != nil, error);
                require([scanout encodeSource:source
                                      overlay:overlay
                                       target:target
                                     uniforms:&u
                                     commands:commands
                                        error:&error],
                        error);
                require([commands submitWithError:&error], error);
                require([commands waitUntilIdleWithError:&error], error);
                uint8_t raw[6 * 7 * 16];
                unsigned bytes = f == 0 ? 16 :
                                 f <= 2 ? 4 :
                                 f <= 4 ? 2 :
                                 f == 5 ? 1 :
                                          2;
                [target getBytes:raw
                     bytesPerRow:6 * bytes
                      fromRegion:MTLRegionMake2D(0, 0, 6, 7)
                     mipmapLevel:0];
                for (unsigned y = 0; y < 7; y++)
                    for (unsigned x = 0; x < 6; x++) {
                        double want[4];
                        reference(x, y, &u, want);
                        double got[4] = { 0, 0, 0, 1 };
                        const uint8_t *p = raw + (y * 6 + x) * bytes;
                        if (f == 0) {
                            float values[4];
                            memcpy(values, p, 16);
                            for (unsigned k = 0; k < 4; k++)
                                got[k] = values[k];
                        } else if (f <= 2)
                            for (unsigned k = 0; k < 4; k++)
                                got[k] = p[f == 2 && k < 3 ? 2 - k : k] / 255.0;
                        else if (f <= 4) {
                            uint16_t q;
                            memcpy(&q, p, 2);
                            got[0] = f == 3 ? (q >> 11) / 31.0 :
                                              ((q >> 10) & 31) / 31.0;
                            got[1] = f == 3 ? ((q >> 5) & 63) / 63.0 :
                                              ((q >> 5) & 31) / 31.0;
                            got[2] = (q & 31) / 31.0;
                            got[3] = f == 4 ? (q >> 15) : 1;
                        } else {
                            got[0] = p[0] / 255.0;
                            if (f == 6)
                                got[1] = p[1] / 255.0;
                        }
                        for (unsigned k = 0; k < 4; k++) {
                            unsigned bits = f == 0 ? 0 :
                                            f <= 2 ? 8 :
                                            f == 3 ? (k == 1 ? 6 :
                                                      k == 3 ? 0 :
                                                               5) :
                                            f == 4 ? (k == 3 ? 1 : 5) :
                                                     8;
                            if (f >= 5 && (k == 2 || (f == 5 && k == 1)))
                                want[k] = 0;
                            if ((f == 3 && k == 3) || (f >= 5 && k == 3))
                                want[k] = 1;
                            double unquantized = want[k];
                            if (bits) {
                                if (u.dither) {
                                    const unsigned ranks[16] = {
                                        0, 8,  2, 10, 12, 4, 14, 6,
                                        3, 11, 1, 9,  15, 7, 13, 5
                                    };
                                    unsigned mask = (1u << bits) - 1;
                                    double scaled =
                                        fmin(1, fmax(0, want[k])) * mask;
                                    double threshold =
                                        (ranks[(y % 4) * 4 + x % 4] + .5) / 16;
                                    want[k] = (floor(scaled) +
                                               (scaled - floor(scaled) >=
                                                threshold)) /
                                              mask;
                                } else
                                    want[k] = quantize(want[k], bits);
                            }
                            BOOL boundary = NO;
                            if (bits && fabs(got[k] - want[k]) > 1e-6) {
                                unsigned n = (1u << bits) - 1;
                                double v = fmin(1, fmax(0, unquantized)) * n;
                                boundary =
                                    fabs(v -
                                         (floor(v) +
                                          (u.dither ?
                                               ((const unsigned[16]){
                                                   0, 8, 2, 10, 12, 4, 14, 6, 3,
                                                   11, 1, 9, 15, 7, 13,
                                                   5 })[(y % 4) * 4 + x % 4] /
                                                       16.0 +
                                                   .5 / 16 :
                                               .5))) < .00002 &&
                                    fabs(got[k] - want[k]) <= 1.0 / n + 1e-6;
                                if (boundary)
                                    boundary_steps++;
                            }
                            if (!boundary && fabs(got[k] - want[k]) >
                                                 (f == 0 ? .000003 : 1e-6)) {
                                fprintf(stderr,
                                        "Scanout format%u test%u pixel%u,%u "
                                        "channel%u: %.9g != %.9g\n",
                                        f, test, x, y, k, got[k], want[k]);
                                abort();
                            }
                        }
                        pixels++;
                    }
                images++;
            }
        }
        // Color key exact hit/miss using constant values, after source
        // filtering.
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 4; x++)
                for (unsigned k = 0; k < 4; k++)
                    source_data[y][x][k] = k == 3 ? 1 : .25f;
        [source replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                  mipmapLevel:0
                    withBytes:source_data
                  bytesPerRow:64];
        NV2AMetalScanout *scanout =
            [[NV2AMetalScanout alloc] initWithDevice:commands.device
                                         pixelFormat:MTLPixelFormatRGBA32Float
                                               error:&error];
        require(scanout != nil, error);
        id<MTLTexture> target =
            texture(MTLPixelFormatRGBA32Float, 4, 4,
                    MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        for (unsigned hit = 0; hit < 2; hit++) {
            NV2AMetalScanoutUniforms u = { .output_size = { 4, 4 },
                                           .line_offset = 1,
                                           .overlay_enable = 1,
                                           .overlay_rect = { 0, 0, 4, 4 },
                                           .overlay_scale = { 1, 1, 1 },
                                           .color_key_enable = 1,
                                           .color_key = { hit ? .25f : .5f,
                                                          .25f, .25f } };
            require([commands beginWithError:&error] != nil, error);
            require([scanout encodeSource:source
                                  overlay:overlay
                                   target:target
                                 uniforms:&u
                                 commands:commands
                                    error:&error],
                    error);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            float data[4][4][4];
            [target getBytes:data
                 bytesPerRow:64
                  fromRegion:MTLRegionMake2D(0, 0, 4, 4)
                 mipmapLevel:0];
            for (unsigned y = 0; y < 4; y++)
                for (unsigned x = 0; x < 4; x++) {
                    double want[4];
                    reference(x, y, &u, want);
                    for (unsigned k = 0; k < 4; k++)
                        assert(fabs(data[y][x][k] - want[k]) < .000003);
                    pixels++;
                }
            images++;
        }
        // GPU YUY2 decode -> scanout -> final DAC gamma, in one recording.
        uint8_t yuv[32];
        for (unsigned y = 0; y < 4; y++)
            for (unsigned pair = 0; pair < 2; pair++) {
                unsigned p = y * 8 + pair * 4;
                yuv[p] = 16 + y * 39 + pair * 11;
                yuv[p + 1] = 92 + pair * 32;
                yuv[p + 2] = 47 + y * 31 + pair * 7;
                yuv[p + 3] = 104 + y * 17;
            }
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 4; x++) {
                unsigned p = y * 8 + (x & ~1u) * 2;
                int yy = yuv[y * 8 + x * 2] - 16, cb = yuv[p + 1] - 128,
                    cr = yuv[p + 3] - 128;
                int rgb[] = { (298 * yy + 409 * cr + 128) >> 8,
                              (298 * yy - 100 * cb - 208 * cr + 128) >> 8,
                              (298 * yy + 516 * cb + 128) >> 8 };
                for (unsigned k = 0; k < 3; k++)
                    overlay_data[y][x][k] = fmin(255, fmax(0, rgb[k])) / 255.f;
                overlay_data[y][x][3] = 1;
            }
        NV2AMetalTextureUpload *upload =
            [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                     error:&error];
        require(upload != nil, error);
        id<MTLBuffer> bytes =
            [commands.device newBufferWithBytes:yuv
                                         length:sizeof(yuv)
                                        options:MTLResourceStorageModeShared];
        assert(bytes);
        NV2AMetalTextureShape shape = {
            .format = NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8,
            .dimension = 2,
            .width = 4,
            .height = 4,
            .depth = 1,
            .levels = 1,
            .pitch = 8
        };
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *decoded = [upload encodeData:bytes
                                                            offset:0
                                                           palette:nil
                                                     paletteOffset:0
                                                     paletteLength:0
                                                             shape:&shape
                                                          commands:commands
                                                             error:&error];
        require(decoded != nil, error);
        NV2AMetalScanout *compose8 =
            [[NV2AMetalScanout alloc] initWithDevice:commands.device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        require(compose8 != nil, error);
        id<MTLTexture> composed =
            texture(MTLPixelFormatRGBA8Unorm, 4, 4,
                    MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        NV2AMetalScanoutUniforms composed_u = { .output_size = { 4, 4 },
                                                .line_offset = 1,
                                                .overlay_enable = 1,
                                                .overlay_rect = { 0, 0, 4, 4 },
                                                .overlay_scale = { 1, 1, 1 } };
        require([compose8 encodeSource:source
                               overlay:decoded.texture
                                target:composed
                              uniforms:&composed_u
                              commands:commands
                                 error:&error],
                error);
        NV2AMetalDisplay *display =
            [[NV2AMetalDisplay alloc] initWithDevice:commands.device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        require(display != nil, error);
        id<MTLTexture> final =
            texture(MTLPixelFormatRGBA8Unorm, 4, 4,
                    MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        NV2AMetalDisplayUniforms gamma = { .scale = { 1, 1 } };
        for (unsigned i = 0; i < 256; i++)
            gamma.palette[i] =
                (255 - i) | ((i * 29) & 255) << 8 | ((i * 61) & 255) << 16;
        require([display encodeWithCommands:commands
                                     source:composed
                                     target:final
                                   uniforms:&gamma
                                     linear:NO
                                  screenOff:NO
                                      error:&error],
                error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        uint8_t composited[4][4][4], result[4][4][4];
        [composed getBytes:composited
               bytesPerRow:16
                fromRegion:MTLRegionMake2D(0, 0, 4, 4)
               mipmapLevel:0];
        [final getBytes:result
            bytesPerRow:16
             fromRegion:MTLRegionMake2D(0, 0, 4, 4)
            mipmapLevel:0];
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 4; x++) {
                double want[4];
                reference(x, y, &composed_u, want);
                for (unsigned k = 0; k < 4; k++) {
                    unsigned q = (unsigned)floor(want[k] * 255 + .5),
                             actual = composited[y][x][k];
                    if (actual != q)
                        assert(abs((int)actual - (int)q) == 1 &&
                               fabs(want[k] * 255 -
                                    (floor(want[k] * 255) + .5)) < .00002);
                    unsigned mapped =
                        k == 3 ? actual :
                                 (gamma.palette[actual] >> (8 * k)) & 255;
                    assert(result[y][x][k] == mapped);
                }
                pixels++;
            }
        images++;
        NV2AMetalScanoutUniforms u = { .output_size = { 4, 4 },
                                       .line_offset = 1 };
        require([commands beginWithError:&error] != nil, error);
        assert(![scanout encodeSource:target
                              overlay:nil
                               target:target
                             uniforms:&u
                             commands:commands
                                error:&error]);
        rejects++;
        u.line_offset = 0;
        assert(![scanout encodeSource:source
                              overlay:nil
                               target:target
                             uniforms:&u
                             commands:commands
                                error:&error]);
        rejects++;
        u.line_offset = NAN;
        assert(![scanout encodeSource:source
                              overlay:nil
                               target:target
                             uniforms:&u
                             commands:commands
                                error:&error]);
        rejects++;
        u.line_offset = 1;
        u.overlay_enable = 1;
        assert(![scanout encodeSource:source
                              overlay:nil
                               target:target
                             uniforms:&u
                             commands:commands
                                error:&error]);
        rejects++;
        u.line_offset = 1e-40f;
        u.overlay_enable = 0;
        assert(![scanout encodeSource:source
                              overlay:nil
                               target:target
                             uniforms:&u
                             commands:commands
                                error:&error]);
        rejects++;
        u.line_offset = 1;
        u.overlay_enable = 1;
        u.overlay_scale[2] = 3e38f;
        assert(![scanout encodeSource:source
                              overlay:overlay
                               target:target
                             uniforms:&u
                             commands:commands
                                error:&error]);
        rejects++;
        [commands cancel];
        id<MTLTexture> independent_source =
            texture(MTLPixelFormatRGBA8Unorm, 8, 8, MTLTextureUsageShaderRead);
        uint8_t independent_pixels[8 * 8 * 4];
        for (unsigned i = 0; i < 64; i++) {
            independent_pixels[4 * i] = 32;
            independent_pixels[4 * i + 1] = 96;
            independent_pixels[4 * i + 2] = 160;
            independent_pixels[4 * i + 3] = 224;
        }
        [independent_source replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
                              mipmapLevel:0
                                withBytes:independent_pixels
                              bytesPerRow:32];
        const uint8_t *independent_bytes = independent_pixels;
        NV2AMetalScanout *alias_scanout =
            [[NV2AMetalScanout alloc] initWithDevice:commands.device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        require(alias_scanout != nil, error);
        __block unsigned alias_rejects = 0, alias_draws = 0;
        texture_alias_cases(
            commands.device,
            ^(id<MTLTexture> input, id<MTLTexture> output, BOOL expected) {
              for (unsigned mode = 0; mode < 3; mode++) {
                  NSError *alias_error = nil;
                  BOOL overlay_enabled = mode == 1;
                  BOOL accepted_expected = mode == 2 || expected;
                  NV2AMetalScanoutUniforms config = {
                      .output_size = { 8, 8 },
                      .line_offset = 1,
                      .overlay_enable = overlay_enabled,
                      .overlay_rect = { 0, 0, 8, 8 },
                      .overlay_scale = { 1, 1, 1 },
                  };
                  uint8_t solid[8 * 8 * 4];
                  for (unsigned i = 0; i < 64; i++) {
                      solid[4 * i] = 64;
                      solid[4 * i + 1] = 128;
                      solid[4 * i + 2] = 192;
                      solid[4 * i + 3] = 255;
                  }
                  [input replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
                           mipmapLevel:0
                             withBytes:solid
                           bytesPerRow:32];
                  require([commands beginWithError:&alias_error] != nil,
                          alias_error);
                  BOOL accepted = [alias_scanout
                      encodeSource:mode ? independent_source : input
                           overlay:mode ? input : nil
                            target:output
                          uniforms:&config
                          commands:commands
                             error:&alias_error];
                  if (accepted != accepted_expected) {
                      fprintf(stderr,
                              "Scanout storage mode %u: accepted %u, "
                              "expected %u\n",
                              mode, (unsigned)accepted,
                              (unsigned)accepted_expected);
                      abort();
                  }
                  if (!accepted) {
                      assert(alias_error);
                      alias_rejects++;
                      [commands cancel];
                      continue;
                  }
                  require([commands submitWithError:&alias_error], alias_error);
                  require([commands waitUntilIdleWithError:&alias_error],
                          alias_error);
                  uint8_t actual[8 * 8 * 4];
                  [output getBytes:actual
                       bytesPerRow:32
                        fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                       mipmapLevel:0];
                  const uint8_t *want = mode == 2 ? independent_bytes : solid;
                  for (unsigned i = 0; i < sizeof(actual); i++) {
                      assert(abs((int)actual[i] - (int)want[i]) <= 1);
                  }
                  alias_draws++;
              }
            });
        assert(alias_rejects == 24 && alias_draws == 33);
        printf("Scanout storage: %u rejections, %u GPU draws, "
               "inactive overlay aliases allowed PASS\n",
               alias_rejects, alias_draws);
        printf("Metal4 scanout: %u reference images, %u pixels, %u rejects, %u "
               "boundary steps PASS\n",
               images, pixels, rejects, boundary_steps);
    }
    return 0;
}
