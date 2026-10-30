/*
 * Offscreen Metal 4 display tests. Does not create a window or start xemu.
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "hw/xbox/nv2a/pgraph/metal/display.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#include "test-metal-texture-alias.h"

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Metal display test failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static id<MTLTexture> new_texture(id<MTLDevice> device, NSUInteger width,
                                  NSUInteger height)
{
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    assert(texture);
    return texture;
}

static void check_pixel(const unsigned char *pixels, unsigned width, unsigned x,
                        unsigned y, unsigned r, unsigned g, unsigned b,
                        unsigned a)
{
    const unsigned char *pixel = pixels + (y * width + x) * 4;
    const unsigned expected[] = { r, g, b, a };
    for (unsigned channel = 0; channel < 4; channel++) {
        if (abs((int)pixel[channel] - (int)expected[channel]) > 1) {
            fprintf(stderr, "Pixel %u,%u channel %u: got %u, expected %u\n", x,
                    y, channel, pixel[channel], expected[channel]);
            abort();
        }
    }
}

static void encode(NV2AMetalCommands *commands, NV2AMetalDisplay *display,
                   id<MTLTexture> source, id<MTLTexture> target,
                   const NV2AMetalDisplayUniforms *uniforms, BOOL linear,
                   BOOL screen_off)
{
    NSError *error = nil;
    BOOL success = [display encodeWithCommands:commands
                                        source:source
                                        target:target
                                      uniforms:uniforms
                                        linear:linear
                                     screenOff:screen_off
                                         error:&error];
    require(success, error);
}

static void submit_and_wait(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    BOOL success = [commands submitWithError:&error];
    require(success, error);
    success = [commands waitUntilIdleWithError:&error];
    require(success, error);
}

static void read_texture(id<MTLTexture> texture, unsigned char *pixels)
{
    [texture getBytes:pixels
          bytesPerRow:texture.width * 4
           fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height)
          mipmapLevel:0];
}

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalDisplay *display =
            [[NV2AMetalDisplay alloc] initWithDevice:commands.device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        require(display != nil, error);
        assert(![[NV2AMetalDisplay alloc]
            initWithDevice:commands.device
               pixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                     error:&error]);

        id<MTLTexture> source = new_texture(commands.device, 2, 2);
        const unsigned char input[] = {
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128,
        };
        [source replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                  mipmapLevel:0
                    withBytes:input
                  bytesPerRow:8];
        id<MTLTexture> target = new_texture(commands.device, 4, 4);
        NV2AMetalDisplayUniforms uniforms = { .scale = { 1, 1 } };
        for (unsigned i = 0; i < 256; i++) {
            uniforms.palette[i] = i | (i << 8) | (i << 16);
        }

        assert(!commands.commandBuffer);
        assert(![display encodeWithCommands:commands
                                     source:source
                                     target:target
                                   uniforms:&uniforms
                                     linear:NO
                                  screenOff:NO
                                      error:&error]);
        require([commands beginWithError:&error] != nil, error);
        assert(![display encodeWithCommands:commands
                                     source:target
                                     target:target
                                   uniforms:&uniforms
                                     linear:NO
                                  screenOff:NO
                                      error:&error]);
        encode(commands, display, source, target, &uniforms, NO, NO);
        submit_and_wait(commands);
        assert(!commands.commandBuffer);
        unsigned char pixels[4 * 4 * 4];
        read_texture(target, pixels);
        check_pixel(pixels, 4, 0, 0, 255, 0, 0, 255);
        check_pixel(pixels, 4, 3, 0, 0, 255, 0, 255);
        check_pixel(pixels, 4, 0, 3, 0, 0, 255, 255);
        check_pixel(pixels, 4, 3, 3, 255, 255, 255, 128);

        /* Multiple passes share an argument table. Each draw must snapshot its
         * bindings and synchronize the intermediate texture explicitly. */
        id<MTLTexture> intermediate = new_texture(commands.device, 4, 4);
        require([commands beginWithError:&error] != nil, error);
        uniforms.flip_y = 1;
        encode(commands, display, source, intermediate, &uniforms, NO, NO);
        encode(commands, display, intermediate, target, &uniforms, NO, NO);
        submit_and_wait(commands);
        read_texture(target, pixels);
        check_pixel(pixels, 4, 0, 0, 255, 0, 0, 255);
        check_pixel(pixels, 4, 3, 3, 255, 255, 255, 128);
        read_texture(intermediate, pixels);
        check_pixel(pixels, 4, 0, 0, 0, 0, 255, 255);

        /* Aspect fitting must clear the borders, even on a reused target. */
        uniforms.flip_y = 0;
        uniforms.scale[0] = 0.5f;
        require([commands beginWithError:&error] != nil, error);
        encode(commands, display, source, target, &uniforms, NO, NO);
        submit_and_wait(commands);
        read_texture(target, pixels);
        check_pixel(pixels, 4, 0, 0, 0, 0, 0, 0);
        check_pixel(pixels, 4, 1, 0, 255, 0, 0, 255);
        check_pixel(pixels, 4, 2, 0, 0, 255, 0, 255);
        check_pixel(pixels, 4, 3, 3, 0, 0, 0, 0);

        uniforms.scale[0] = 1;
        for (unsigned i = 0; i < 256; i++) {
            uniforms.palette[i] =
                (255 - i) | ((i / 2) << 8) | ((i == 255 ? 17u : 99u) << 16);
        }
        require([commands beginWithError:&error] != nil, error);
        encode(commands, display, source, target, &uniforms, NO, NO);
        submit_and_wait(commands);
        read_texture(target, pixels);
        check_pixel(pixels, 4, 0, 0, 0, 0, 99, 255);
        check_pixel(pixels, 4, 3, 3, 0, 127, 17, 128);

        /* At the center, linear sampling averages all four source texels.
         * Gamma indexes truncate to 127 before the palette lookup. */
        id<MTLTexture> linear_target = new_texture(commands.device, 3, 3);
        require([commands beginWithError:&error] != nil, error);
        encode(commands, display, source, linear_target, &uniforms, YES, NO);
        submit_and_wait(commands);
        read_texture(linear_target, pixels);
        check_pixel(pixels, 3, 1, 1, 128, 63, 99, 223);

        require([commands beginWithError:&error] != nil, error);
        encode(commands, display, nil, target, &uniforms, NO, YES);
        submit_and_wait(commands);
        read_texture(target, pixels);
        for (unsigned i = 0; i < sizeof(pixels); i++) {
            assert(pixels[i] == 0);
        }
        MTLTextureDescriptor *float_td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:2
                                        height:2
                                     mipmapped:NO];
        float_td.storageMode = MTLStorageModeShared;
        float_td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> float_source =
            [commands.device newTextureWithDescriptor:float_td];
        assert(float_source);
        float float_pixels[] = {
            1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1, 1, 1, 1, 1
        };
        [float_source replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                        mipmapLevel:0
                          withBytes:float_pixels
                        bytesPerRow:32];
        require([commands beginWithError:&error] != nil, error);
        encode(commands, display, float_source, linear_target, &uniforms, YES,
               NO);
        submit_and_wait(commands);
        read_texture(linear_target, pixels);
        check_pixel(pixels, 3, 1, 1, 128, 63, 99, 255);
        float_pixels[0] = -.25f;
        float_pixels[1] = 2;
        float_pixels[2] = .5f;
        [float_source replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                        mipmapLevel:0
                          withBytes:float_pixels
                        bytesPerRow:32];
        require([commands beginWithError:&error] != nil, error);
        encode(commands, display, float_source, target, &uniforms, NO, NO);
        submit_and_wait(commands);
        read_texture(target, pixels);
        check_pixel(pixels, 4, 0, 0, 255, 127, 99, 255);
        texture_alias_cases(commands.device, ^(id<MTLTexture> src,
                                               id<MTLTexture> dst,
                                               BOOL expected) {
          NSError *alias_error = nil;
          require([commands beginWithError:&alias_error] != nil, alias_error);
          BOOL accepted = [display encodeWithCommands:commands
                                               source:src
                                               target:dst
                                             uniforms:&uniforms
                                               linear:NO
                                            screenOff:NO
                                                error:&alias_error];
          assert(accepted == expected);
          assert(accepted || alias_error);
          [commands cancel];
        });
        puts("Metal 4 display gamma, orientation, filtering and hazards: PASS "
             "(offscreen)");
    }
    return 0;
}
