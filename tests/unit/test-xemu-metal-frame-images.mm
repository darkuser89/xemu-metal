/* Offscreen PNG capture; no xemu, VM or window.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "ui/xui/metal4/frame-images.h"
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#include <fpng.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

/* Implements the immutable framebuffer getter ABI; actual PGRAPH publication
 * is exercised separately by test-nv2a-metal-renderer. */
@interface CaptureFrame : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) NV2AMetalDisplayUniforms displayUniforms;
@property(nonatomic) BOOL screenOff;
@end
@implementation CaptureFrame
@end

static unsigned images, pixels;
static std::vector<uint8_t> capture(float aspect, uint32_t max_width,
                                    uint32_t max_height, unsigned width,
                                    unsigned height, bool linear = true)
{
    size_t size = 0;
    void *png =
        xemu_metal4_capture_png(aspect, max_width, max_height, linear, &size);
    assert(png && size);
    std::vector<uint8_t> rgb;
    unsigned w, h, channels;
    assert(fpng::fpng_decode_memory(png, uint32_t(size), rgb, w, h, channels,
                                    3) == fpng::FPNG_DECODE_SUCCESS);
    assert(w == width && h == height && channels == 3);
    std::free(png);
    images++;
    pixels += w * h;
    return rgb;
}

static void pixel(const std::vector<uint8_t> &rgb, unsigned width, unsigned x,
                  unsigned y, unsigned r, unsigned g, unsigned b)
{
    const uint8_t expected[] = { uint8_t(r), uint8_t(g), uint8_t(b) };
    for (unsigned c = 0; c < 3; c++)
        assert(rgb[(y * width + x) * 3 + c] == expected[c]);
}

static void pattern(const std::vector<uint8_t> &rgb, unsigned width,
                    unsigned height, NV2AMetalDisplayUniforms u, bool linear)
{
    const float color[4][3] = {
        { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 1, 1 }
    };
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            float sx = (x + .5f) * 2 / width;
            float sy = (y + .5f) * 2 / height;
            if (u.flip_y)
                sy = 2 - sy;
            unsigned expected[3];
            for (unsigned c = 0; c < 3; c++) {
                float value;
                if (linear) {
                    float fx = std::fmax(0.f, std::fmin(1.f, sx - .5f));
                    float fy = std::fmax(0.f, std::fmin(1.f, sy - .5f));
                    value = color[0][c] * (1 - fx) * (1 - fy) +
                            color[1][c] * fx * (1 - fy) +
                            color[2][c] * (1 - fx) * fy + color[3][c] * fx * fy;
                } else {
                    unsigned ix = unsigned(std::fmin(1.f, std::floor(sx)));
                    unsigned iy = unsigned(std::fmin(1.f, std::floor(sy)));
                    value = color[iy * 2 + ix][c];
                }
                unsigned index = unsigned(value * 255);
                expected[c] = (u.palette[index] >> (c * 8)) & 255;
            }
            pixel(rgb, width, x, y, expected[0], expected[1], expected[2]);
        }
    }
}

int main()
{
    @autoreleasepool {
        fpng::fpng_init();
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        assert(commands);
        CaptureFrame *frame = [CaptureFrame new];
        NV2AMetalDisplayUniforms u = { .scale = { 1, 1 } };
        for (unsigned i = 0; i < 256; i++)
            u.palette[i] = i | (i << 8) | (i << 16);
        frame.displayUniforms = u;
        const MTLPixelFormat formats[] = {
            MTLPixelFormatR8Unorm,     MTLPixelFormatRG8Unorm,
            MTLPixelFormatB5G6R5Unorm, MTLPixelFormatBGR5A1Unorm,
            MTLPixelFormatRGBA8Unorm,  MTLPixelFormatBGRA8Unorm,
            MTLPixelFormatRGBA32Float,
        };
        for (MTLPixelFormat format : formats) {
            MTLTextureDescriptor *td =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                   width:2
                                                                  height:2
                                                               mipmapped:NO];
            td.storageMode = MTLStorageModeShared;
            td.usage = MTLTextureUsageShaderRead;
            frame.texture = [commands.device newTextureWithDescriptor:td];
            assert(frame.texture);
            uint8_t white[64];
            std::memset(white, 255, sizeof(white));
            float white_float[16];
            for (float &v : white_float)
                v = 1;
            unsigned bytes = format == MTLPixelFormatR8Unorm ? 1 :
                             format == MTLPixelFormatRG8Unorm ||
                                     format == MTLPixelFormatB5G6R5Unorm ||
                                     format == MTLPixelFormatBGR5A1Unorm ?
                                                               2 :
                             format == MTLPixelFormatRGBA32Float ? 16 :
                                                                   4;
            [frame.texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                             mipmapLevel:0
                               withBytes:format == MTLPixelFormatRGBA32Float ?
                                             (const void *)white_float :
                                             white
                             bytesPerRow:2 * bytes];
            xemu_metal4_set_capture_frame((__bridge void *)frame);
            auto rgb = capture(0, 0, 0, 2, 2);
            for (unsigned y = 0; y < 2; y++)
                for (unsigned x = 0; x < 2; x++)
                    pixel(rgb, 2, x, y, 255,
                          format == MTLPixelFormatR8Unorm ? 0 : 255,
                          format == MTLPixelFormatR8Unorm ||
                                  format == MTLPixelFormatRG8Unorm ?
                              0 :
                              255);
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:2
                                        height:2
                                     mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        frame.texture = [commands.device newTextureWithDescriptor:td];
        const uint8_t corners[] = { 255, 0, 0,   7,  0,   255, 0,   23,
                                    0,   0, 255, 99, 255, 255, 255, 255 };
        [frame.texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                         mipmapLevel:0
                           withBytes:corners
                         bytesPerRow:8];
        xemu_metal4_set_capture_frame((__bridge void *)frame);
        auto rgb = capture(0, 0, 0, 2, 2);
        pattern(rgb, 2, 2, u, true);
        pixel(rgb, 2, 0, 0, 255, 0, 0);
        pixel(rgb, 2, 1, 0, 0, 255, 0);
        pixel(rgb, 2, 0, 1, 0, 0, 255);
        pixel(rgb, 2, 1, 1, 255, 255, 255);
        rgb = capture(0, 4, 4, 4, 4);
        pattern(rgb, 4, 4, u, true);
        pixel(rgb, 4, 0, 0, 255, 0, 0);
        pixel(rgb, 4, 1, 1, 159, 63, 63);
        rgb = capture(0, 4, 4, 4, 4, false);
        pattern(rgb, 4, 4, u, false);
        pixel(rgb, 4, 1, 1, 255, 0, 0);
        pixel(rgb, 4, 2, 2, 255, 255, 255);
        rgb = capture(2, 0, 0, 4, 2);
        pattern(rgb, 4, 2, u, true);
        pixel(rgb, 4, 0, 1, 0, 0, 255);
        rgb = capture(2, 2, 2, 2, 1);
        pattern(rgb, 2, 1, u, true);
        pixel(rgb, 2, 0, 0, 127, 0, 127);
        u.flip_y = 1;
        for (unsigned i = 0; i < 256; i++)
            u.palette[i] = (255 - i) | ((i / 2) << 8) | (17u << 16);
        frame.displayUniforms = u;
        xemu_metal4_set_capture_frame((__bridge void *)frame);
        frame.displayUniforms = NV2AMetalDisplayUniforms{};
        rgb = capture(0, 0, 0, 2, 2);
        pattern(rgb, 2, 2, u, true);
        pixel(rgb, 2, 0, 0, 255, 0, 17);
        pixel(rgb, 2, 1, 1, 255, 127, 17);
        frame.screenOff = YES;
        xemu_metal4_set_capture_frame((__bridge void *)frame);
        frame = nil;
        std::thread worker([] {
            @autoreleasepool {
                auto black = capture(0, 0, 0, 2, 2);
                for (uint8_t v : black)
                    assert(v == 0);
            }
        });
        worker.join();
        size_t size = 99;
        assert(!xemu_metal4_capture_png(-1, 0, 0, true, &size) && !size);
        assert(!xemu_metal4_capture_png(0, 20000, 1, true, &size) && !size);
        assert(!xemu_metal4_capture_png(1e10f, 0, 0, true, &size) && !size);
        assert(!xemu_metal4_capture_png(0, 0, 0, true, nullptr));
        xemu_metal4_set_capture_frame(nullptr);
        assert(!xemu_metal4_has_capture_frame());
        size = 99;
        assert(!xemu_metal4_capture_png(0, 0, 0, true, &size) && !size);
        std::printf("Metal4 native PNG: %u images, %u pixels, 5 rejects PASS\n",
                    images, pixels);
    }
}
