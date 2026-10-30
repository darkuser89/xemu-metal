/*
 * Offscreen tests of custom xemu UI drawing through Metal 4.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#import "ui/xui/metal4/decal.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "test-metal-texture-alias.h"

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Metal decal test failed: %s\n",
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
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    assert(texture);
    return texture;
}

static XemuMetal4Decal *new_decal(id<MTLTexture> texture, CGRect destination)
{
    XemuMetal4Decal *decal = [XemuMetal4Decal new];
    decal.texture = texture;
    decal.destination = destination;
    decal.source = CGRectMake(0, 0, texture.width, texture.height);
    decal.primary = 0xff0000ff;
    decal.secondary = 0x00ff00ff;
    return decal;
}

static void draw(NV2AMetalCommands *commands, XemuMetal4Decals *renderer,
                 NSArray<XemuMetal4Decal *> *decals, id<MTLTexture> target,
                 BOOL clear)
{
    NSError *error = nil;
    BOOL success = [renderer encodeDecals:decals
                                 commands:commands
                                   target:target
                                    clear:clear
                                    error:&error];
    require(success, error);
}

static void submit(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}

static void check_pixel(id<MTLTexture> texture, unsigned x, unsigned y,
                        unsigned r, unsigned g, unsigned b, unsigned a)
{
    unsigned char pixel[4];
    [texture getBytes:pixel
          bytesPerRow:4
           fromRegion:MTLRegionMake2D(x, y, 1, 1)
          mipmapLevel:0];
    unsigned expected[] = { r, g, b, a };
    for (unsigned i = 0; i < 4; i++) {
        if (abs((int)pixel[i] - (int)expected[i]) > 1) {
            fprintf(stderr, "Pixel %u,%u channel %u: got %u, expected %u\n", x,
                    y, i, pixel[i], expected[i]);
            abort();
        }
    }
}

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        XemuMetal4Decals *renderer =
            [[XemuMetal4Decals alloc] initWithDevice:commands.device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        require(renderer != nil, error);
        id<MTLTexture> texture = new_texture(commands.device, 2, 2);
        const unsigned char mask[] = {
            255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0, 128,
        };
        [texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                   mipmapLevel:0
                     withBytes:mask
                   bytesPerRow:8];
        id<MTLTexture> target = new_texture(commands.device, 4, 4);
        XemuMetal4Decal *decal = new_decal(texture, CGRectMake(1, 1, 2, 2));
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ decal ], target, YES);
        submit(commands);
        check_pixel(target, 0, 0, 0, 0, 0, 0);
        check_pixel(target, 1, 1, 255, 0, 0, 255);
        check_pixel(target, 2, 1, 0, 255, 0, 255);
        check_pixel(target, 1, 2, 0, 255, 0, 0);
        check_pixel(target, 2, 2, 255, 0, 0, 128);
        decal.flipY = YES;
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ decal ], target, YES);
        submit(commands);
        check_pixel(target, 1, 1, 0, 255, 0, 0);
        check_pixel(target, 2, 2, 0, 255, 0, 255);

        /* Draw two overlapping decals in one pass. Alpha uses the original
         * custom-UI equation, where source alpha is itself multiplied by As. */
        const unsigned char half_mask[] = {
            255, 0, 0, 128, 255, 0, 0, 128, 255, 0, 0, 128, 255, 0, 0, 128,
        };
        [texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                   mipmapLevel:0
                     withBytes:half_mask
                   bytesPerRow:8];
        XemuMetal4Decal *background =
            new_decal(texture, CGRectMake(1, 1, 2, 2));
        background.primary = background.secondary = 0x0000ffff;
        background.fill = 0x0000007f;
        XemuMetal4Decal *foreground =
            new_decal(texture, CGRectMake(1, 1, 2, 2));
        foreground.primary = foreground.secondary = 0xff0000ff;
        foreground.blend = XemuMetal4DecalBlendAlpha;
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ background, foreground ], target, YES);
        submit(commands);
        check_pixel(target, 1, 1, 128, 0, 127, 191);

        background.fill = 0;
        foreground.blend = XemuMetal4DecalBlendCutout;
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ background ], target, YES);
        draw(commands, renderer, @[ foreground ], target, NO);
        submit(commands);
        check_pixel(target, 1, 1, 127, 0, 255, 192);

        foreground.blend = XemuMetal4DecalBlendReplace;
        foreground.primary = foreground.secondary = 0;
        foreground.source = CGRectMake(10, 10, 2, 2);
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ foreground ], target, YES);
        submit(commands);
        check_pixel(target, 1, 1, 0, 0, 0, 0);

        /* Synthetic solid MSDF: opaque fill at the center and transparent
         * exterior. The documented animation cycle is 1.25 + 6 seconds. */
        const unsigned char white[16] = {
            255, 255, 255, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 255, 255, 255, 255,
        };
        [texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                   mipmapLevel:0
                     withBytes:white
                   bytesPerRow:8];
        id<MTLTexture> logo_target = new_texture(commands.device, 512, 512);
        XemuMetal4Decal *logo = new_decal(texture, CGRectMake(0, 0, 512, 512));
        logo.shader = XemuMetal4DecalShaderLogo;
        logo.primary = 0x00ff00ff;
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ logo ], logo_target, YES);
        submit(commands);
        check_pixel(logo_target, 256, 256, 0, 255, 0, 255);
        check_pixel(logo_target, 0, 0, 0, 0, 0, 0);
        size_t bytes = 512 * 512 * 4;
        unsigned char *first = malloc(bytes), *next = malloc(bytes);
        assert(first && next);
        [logo_target getBytes:first
                  bytesPerRow:512 * 4
                   fromRegion:MTLRegionMake2D(0, 0, 512, 512)
                  mipmapLevel:0];
        logo.time = 7.25f;
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ logo ], logo_target, YES);
        submit(commands);
        [logo_target getBytes:next
                  bytesPerRow:512 * 4
                   fromRegion:MTLRegionMake2D(0, 0, 512, 512)
                  mipmapLevel:0];
        assert(memcmp(first, next, bytes) == 0);
        logo.time = 0.75f;
        require([commands beginWithError:&error] != nil, error);
        draw(commands, renderer, @[ logo ], logo_target, YES);
        submit(commands);
        [logo_target getBytes:next
                  bytesPerRow:512 * 4
                   fromRegion:MTLRegionMake2D(0, 0, 512, 512)
                  mipmapLevel:0];
        assert(memcmp(first, next, bytes) != 0);
        free(first);
        free(next);
        texture_alias_cases(commands.device, ^(id<MTLTexture> src,
                                               id<MTLTexture> dst,
                                               BOOL expected) {
          NSError *alias_error = nil;
          XemuMetal4Decal *sample = new_decal(src, CGRectMake(0, 0, 8, 8));
          require([commands beginWithError:&alias_error] != nil, alias_error);
          BOOL accepted = [renderer encodeDecals:@[ sample ]
                                        commands:commands
                                          target:dst
                                           clear:NO
                                           error:&alias_error];
          assert(accepted == expected);
          assert(accepted || alias_error);
          [commands cancel];
        });
        puts("Metal 4 mask, alpha/cutout blending, borders and logo animation: "
             "PASS (offscreen)");
    }
    return 0;
}
