/* Offscreen PNG capture; no xemu, VM or window.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "ui/xui/metal4/frame-images.h"
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
#import <objc/runtime.h>
#include <fpng.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <mutex>
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

static NV2AMetalShaderLibrary *(*rgb_shared_original)(id, SEL, id<MTLDevice>,
                                                      const char *, NSError **);
static id<MTLComputePipelineState> (*rgb_compute_original)(id, SEL, NSString *,
                                                           NSError **);
static std::mutex rgb_probe_lock;
static __weak NV2AMetalShaderLibrary *rgb_module_seen;
static unsigned rgb_shared_requests, rgb_compute_requests;
static bool rgb_fail_shared, rgb_fail_compute, rgb_gate_compute;
static dispatch_semaphore_t rgb_entered, rgb_release;
static void rgb_error(NSError **error)
{
    if (error)
        *error = [NSError errorWithDomain:@"test.capture.module"
                                     code:1
                                 userInfo:nil];
}
static NV2AMetalShaderLibrary *rgb_shared(id owner, SEL selector,
                                          id<MTLDevice> device,
                                          const char *source, NSError **error)
{
    if (!source || !std::strstr(source, "xemu_capture_rgb"))
        return rgb_shared_original(owner, selector, device, source, error);
    bool fail;
    {
        std::lock_guard<std::mutex> guard(rgb_probe_lock);
        rgb_shared_requests++;
        fail = rgb_fail_shared;
        rgb_fail_shared = false;
    }
    if (fail) {
        rgb_error(error);
        return nil;
    }
    NV2AMetalShaderLibrary *module =
        rgb_shared_original(owner, selector, device, source, error);
    {
        std::lock_guard<std::mutex> guard(rgb_probe_lock);
        rgb_module_seen = module;
    }
    return module;
}
static id<MTLComputePipelineState> rgb_compute(id owner, SEL selector,
                                               NSString *name, NSError **error)
{
    if (![name isEqualToString:@"xemu_capture_rgb"])
        return rgb_compute_original(owner, selector, name, error);
    bool fail, gate;
    {
        std::lock_guard<std::mutex> guard(rgb_probe_lock);
        rgb_compute_requests++;
        fail = rgb_fail_compute;
        gate = rgb_gate_compute;
        rgb_fail_compute = rgb_gate_compute = false;
    }
    if (gate) {
        dispatch_semaphore_signal(rgb_entered);
        assert(!dispatch_semaphore_wait(
            rgb_release, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
    }
    if (fail) {
        rgb_error(error);
        return nil;
    }
    return rgb_compute_original(owner, selector, name, error);
}
static void rgb_reset()
{
    std::lock_guard<std::mutex> guard(rgb_probe_lock);
    rgb_shared_requests = rgb_compute_requests = 0;
    rgb_fail_shared = rgb_fail_compute = rgb_gate_compute = false;
    assert(!rgb_module_seen);
}
static void rgb_cache_tests(id<MTLDevice> device)
{
    Method shared =
        class_getClassMethod(NV2AMetalShaderLibrary.class,
                             @selector(sharedWithDevice:source:error:));
    Method compute = class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                             @selector(computeFunction:error:));
    assert(shared && compute);
    rgb_shared_original = reinterpret_cast<decltype(rgb_shared_original)>(
        method_setImplementation(shared, (IMP)rgb_shared));
    rgb_compute_original = reinterpret_cast<decltype(rgb_compute_original)>(
        method_setImplementation(compute, (IMP)rgb_compute));
    CaptureFrame *frame = [CaptureFrame new];
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:256
                                    height:1
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    frame.texture = [device newTextureWithDescriptor:td];
    assert(frame.texture);
    uint8_t rgba[256 * 4];
    std::vector<uint8_t> expected(256 * 3);
    NV2AMetalDisplayUniforms u = { .scale = { 1, 1 } };
    for (unsigned i = 0; i < 256; i++) {
        rgba[i * 4] = expected[i * 3] = i;
        rgba[i * 4 + 1] = expected[i * 3 + 1] = 255 - i;
        rgba[i * 4 + 2] = expected[i * 3 + 2] = i ^ 0x5a;
        rgba[i * 4 + 3] = 255;
        u.palette[i] = i | i << 8 | i << 16;
    }
    [frame.texture replaceRegion:MTLRegionMake2D(0, 0, 256, 1)
                     mipmapLevel:0
                       withBytes:rgba
                     bytesPerRow:sizeof(rgba)];
    frame.displayUniforms = u;
    @try {
        rgb_reset();
        @autoreleasepool {
            xemu_metal4_set_capture_frame((__bridge void *)frame);
            auto first = capture(0, 0, 0, 256, 1, false);
            NV2AMetalShaderLibrary *module = rgb_module_seen;
            assert(module && rgb_shared_requests == 1 &&
                   [[module valueForKey:@"computeBuildCount"]
                       unsignedIntegerValue] == 1);
            id<MTLLibrary> library = module.library;
            xemu_metal4_set_capture_frame((__bridge void *)frame);
            assert(first == expected &&
                   first == capture(0, 0, 0, 256, 1, false));
            assert(rgb_module_seen == module && module.library == library &&
                   rgb_shared_requests == 1 && rgb_compute_requests == 2 &&
                   [[module valueForKey:@"computeBuildCount"]
                       unsignedIntegerValue] == 1);
            xemu_metal4_set_capture_frame(nullptr);
        }
        assert(!rgb_module_seen);
        for (unsigned failure = 0; failure < 2; failure++) {
            rgb_reset();
            @autoreleasepool {
                xemu_metal4_set_capture_frame((__bridge void *)frame);
                rgb_fail_shared = failure == 0;
                rgb_fail_compute = failure == 1;
                size_t size = 123;
                assert(!xemu_metal4_capture_png(0, 0, 0, true, &size) && !size);
            }
            /* A failed lookup must not pin an incomplete module while the
             * frame remains published. A fresh capture must retry it. */
            assert(!rgb_module_seen && xemu_metal4_has_capture_frame());
            @autoreleasepool {
                assert(capture(0, 0, 0, 256, 1, false) == expected);
                assert(rgb_shared_requests == 2 &&
                       rgb_compute_requests == 1 + failure);
                xemu_metal4_set_capture_frame(nullptr);
            }
            assert(!rgb_module_seen);
        }
        rgb_reset();
        rgb_entered = dispatch_semaphore_create(0);
        rgb_release = dispatch_semaphore_create(0);
        rgb_gate_compute = true;
        xemu_metal4_set_capture_frame((__bridge void *)frame);
        std::vector<uint8_t> result;
        std::thread worker([&] {
            @autoreleasepool {
                result = capture(0, 0, 0, 256, 1, false);
            }
        });
        assert(!dispatch_semaphore_wait(
            rgb_entered, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
        assert(rgb_module_seen);
        __weak CaptureFrame *activeFrame = frame;
        frame = nil;
        xemu_metal4_set_capture_frame(nullptr);
        assert(activeFrame);
        dispatch_semaphore_signal(rgb_release);
        worker.join();
        assert(!activeFrame);
        assert(!xemu_metal4_has_capture_frame() && !rgb_module_seen &&
               rgb_shared_requests == 1 && rgb_compute_requests == 1);
        assert(result == expected);
        puts("Metal4 RGB cache:warm frame republish retains one module/library/"
             "pipeline and one actual compute build;lookup failures release "
             "and retry;withdrawn frame cannot be republished by an active "
             "capture;all256 RGB byte codes in exact decoded PNGs PASS");
    } @finally {
        xemu_metal4_set_capture_frame(nullptr);
        rgb_entered = rgb_release = nil;
        method_setImplementation(shared, (IMP)rgb_shared_original);
        method_setImplementation(compute, (IMP)rgb_compute_original);
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
        rgb_cache_tests(commands.device);
        std::printf("Metal4 native PNG: %u images, %u pixels, 5 rejects PASS\n",
                    images, pixels);
    }
}
