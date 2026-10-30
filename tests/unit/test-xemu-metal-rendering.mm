/* UI assets/layout against an independent software model of the GL equations.
 * No SDL initialization, GL context, window, VM or xemu.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#include "qemu/osdep.h"
#import "ui/xui/metal4/rendering.hh"
#include "ui/xui/gl-helpers.hh"
#import "ui/xui/metal4/frontend.h"
#import "ui/xui/metal4/decal.h"
#include <imgui.h>
#include <stb_image.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>
#include <thread>
#include <string>
#include <fstream>
#include <set>
#include <fpng.h>
extern "C" {
uintptr_t xemu_snapshots_load_png_to_texture(void *, size_t);
void xemu_snapshots_release_texture(uintptr_t);
void xemu_snapshots_set_metal4_framebuffer(void *);
void *xemu_snapshots_create_framebuffer_thumbnail_png(size_t *);
}
#import "hw/xbox/nv2a/pgraph/metal/display.h"
@interface ThumbnailFrame : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) NV2AMetalDisplayUniforms displayUniforms;
@property(nonatomic) BOOL screenOff;
@end
@implementation ThumbnailFrame
@end
#include "data/controller_mask.png.h"
#include "data/controller_mask_s.png.h"
#include "data/xmu_mask.png.h"
#include "data/logo_sdf.png.h"

extern "C" bool xemu_hud_uses_metal4(void)
{
    return true;
}
extern "C" const uint8_t *nv2a_get_dac_palette(void)
{
    abort();
}
extern "C" int nv2a_get_screen_off(void)
{
    abort();
}
struct config g_config;
const char *bound_drivers[4] = { DRIVER_DUKE, DRIVER_S, DRIVER_DUKE, DRIVER_S };
extern "C" bool xemu_get_widescreen(void)
{
    return false;
}
static std::vector<std::string> screenshot_notifications, screenshot_errors;
static bool expected_screenshot_error;
extern "C" void xemu_queue_notification(const char *message)
{
    screenshot_notifications.emplace_back(message);
}
extern "C" void xemu_queue_error_message(const char *message)
{
    if (!expected_screenshot_error)
        abort();
    screenshot_errors.emplace_back(message);
}
namespace R = XemuMetal4UI;
static unsigned images;
static size_t pixels, neighbors;

static void require(bool ok)
{
    if (!ok) {
        fprintf(stderr, "UI asset test: %s\n", xemu_metal4_ui_error());
        abort();
    }
}
struct Image {
    int w, h;
    std::vector<uint8_t> data;
    Image(const unsigned char *png, unsigned size)
    {
        int channels;
        stbi_set_flip_vertically_on_load_thread(0);
        uint8_t *rgba = stbi_load_from_memory(png, size, &w, &h, &channels, 4);
        assert(rgba);
        data.assign(rgba, rgba + w * h * 4);
        stbi_image_free(rgba);
    }
    double sample(int x, int y, unsigned c) const
    {
        if (x < 0 || y < 0 || x >= w || y >= h)
            return 0;
        /* Original GL load uploaded the asset's rows backwards. */
        return data[((h - 1 - y) * w + x) * 4 + c] / 255.0;
    }
};
static double component(uint32_t packed, unsigned c)
{
    return ((packed >> ((3 - c) * 8)) & 255) / 255.0;
}
static void mask(std::vector<uint8_t> &target, int target_w, const Image &src,
                 int x, int y, int w, int h, int tx, int ty, int tw, int th,
                 uint32_t primary, uint32_t secondary, uint32_t fill,
                 unsigned blend)
{
    if (!w || !h)
        return;
    int target_h = target.size() / (target_w * 4);
    for (int row = std::max(y, 0); row < std::min(y + h, target_h); row++) {
        for (int col = std::max(x, 0); col < std::min(x + w, target_w); col++) {
            double sx = tx + (col + .5 - x) * tw / w - .5;
            double sy = ty + (row + .5 - y) * th / h - .5;
            int ix = int(floor(sx)), iy = int(floor(sy));
            double fx = sx - ix, fy = sy - iy, tex[4], color[4];
            for (unsigned c = 0; c < 4; c++)
                tex[c] = src.sample(ix, iy, c) * (1 - fx) * (1 - fy) +
                         src.sample(ix + 1, iy, c) * fx * (1 - fy) +
                         src.sample(ix, iy + 1, c) * (1 - fx) * fy +
                         src.sample(ix + 1, iy + 1, c) * fx * fy;
            for (unsigned c = 0; c < 3; c++)
                color[c] = component(fill, c) +
                           component(secondary, c) * (1 - tex[0]) +
                           component(primary, c) * tex[0];
            color[3] = component(fill, 3) + tex[3] - tex[2];
            uint8_t *out = target.data() + (row * target_w + col) * 4;
            double dest_alpha = out[3] / 255.0;
            double source_alpha = std::clamp(color[3], 0.0, 1.0);
            for (unsigned c = 0; c < 4; c++) {
                double value = std::clamp(color[c], 0.0, 1.0);
                if (blend == 1)
                    value = value * source_alpha +
                            out[c] / 255.0 * (1 - source_alpha);
                if (blend == 2)
                    value = value * (1 - dest_alpha) + out[c] / 255.0;
                out[c] = uint8_t(lround(std::clamp(value, 0.0, 1.0) * 255));
            }
        }
    }
}
static std::vector<uint8_t> read(id<MTLTexture> texture)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:texture.device error:&error];
    assert(commands);
    size_t pitch = (texture.width * 4 + 255) & ~size_t(255);
    id<MTLBuffer> bytes =
        [texture.device newBufferWithLength:pitch * texture.height
                                    options:MTLResourceStorageModeShared];
    assert(bytes && [commands beginWithError:&error]);
    assert([commands addResource:texture error:&error] &&
           [commands addResource:bytes error:&error]);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    [e copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                        toBuffer:bytes
               destinationOffset:0
          destinationBytesPerRow:pitch
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e endEncoding];
    assert([commands submitWithError:&error] &&
           [commands waitUntilIdleWithError:&error]);
    std::vector<uint8_t> result(texture.width * texture.height * 4);
    for (unsigned y = 0; y < texture.height; y++)
        memcpy(result.data() + y * texture.width * 4,
               (uint8_t *)bytes.contents + y * pitch, texture.width * 4);
    return result;
}
static void compare(const std::vector<uint8_t> &actual,
                    const std::vector<uint8_t> &expected, unsigned test,
                    unsigned tolerance)
{
    assert(actual.size() == expected.size());
    for (size_t i = 0; i < actual.size(); i++) {
        unsigned difference = unsigned(abs(int(actual[i]) - int(expected[i])));
        if (difference > tolerance) {
            fprintf(stderr, "UI case %u byte %zu: got %u expected %u\n", test,
                    i, actual[i], expected[i]);
            abort();
        }
        neighbors += difference != 0;
    }
    images++;
    pixels += actual.size() / 4;
}
static std::vector<uint8_t> screenshot_bytes(const std::string &path)
{
    std::ifstream file(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(file),
                                std::istreambuf_iterator<char>());
}
static void screenshot_collision_test(const uint8_t *expected_rgb)
{
    char *directory = g_dir_make_tmp("xemu-metal-screenshot-XXXXXX", nullptr);
    assert(directory);
    const char *old_directory = g_config.general.screenshot_dir;
    g_config.general.screenshot_dir = directory;
    const std::vector<uint8_t> sentinel = { 0x54, 0x45, 0x53, 0x54 };
    std::set<std::string> existing;
    // Reserve a bounded window around the actual capture time, without
    // replacing the process clock or intercepting system/Metal functions.
    time_t now = time(nullptr);
    for (int offset = -60; offset <= 60; offset++) {
        time_t stamp = now + offset;
        struct tm calendar;
        assert(localtime_r(&stamp, &calendar));
        char name[128];
        assert(strftime(name, sizeof(name), "xemu-%Y-%m-%d-%H-%M-%S.png",
                        &calendar));
        std::string path = std::string(directory) + "/" + name;
        std::ofstream file(path, std::ios::binary);
        file.write(reinterpret_cast<const char *>(sentinel.data()),
                   sentinel.size());
        assert(file.good());
        existing.insert(path);
    }
    screenshot_notifications.clear();
    R::SaveScreenshot(0, false);
    R::SaveScreenshot(0, false);
    assert(time(nullptr) >= now - 60 && time(nullptr) <= now + 60);
    assert(screenshot_notifications.size() == 2);
    std::set<std::string> created;
    for (const std::string &message : screenshot_notifications) {
        const std::string prefix = "Screenshot Saved: ";
        assert(message.rfind(prefix, 0) == 0);
        std::string path =
            std::string(directory) + "/" + message.substr(prefix.size());
        assert(!existing.count(path) && created.insert(path).second);
        std::vector<uint8_t> encoded = screenshot_bytes(path), decoded;
        unsigned width, height, channels;
        assert(fpng::fpng_decode_memory(encoded.data(), encoded.size(), decoded,
                                        width, height, channels,
                                        3) == fpng::FPNG_DECODE_SUCCESS);
        assert(width == 2 && height == 2 && channels == 3);
        assert(decoded.size() == 12 &&
               !memcmp(decoded.data(), expected_rgb, 12));
    }
    for (const std::string &path : existing)
        assert(screenshot_bytes(path) == sentinel);
    std::string invalid = std::string(directory) + "/missing";
    g_config.general.screenshot_dir = invalid.c_str();
    expected_screenshot_error = true;
    screenshot_errors.clear();
    R::SaveScreenshot(0, false);
    expected_screenshot_error = false;
    assert(screenshot_errors.size() == 1 &&
           screenshot_notifications.size() == 2);
    g_config.general.screenshot_dir = old_directory;
    for (const std::string &path : created)
        assert(remove(path.c_str()) == 0);
    for (const std::string &path : existing)
        assert(remove(path.c_str()) == 0);
    assert(rmdir(directory) == 0);
    g_free(directory);
    puts("Metal 4 screenshots: existing files preserved, two unique PNGs, "
         "failed open reports error PASS");
}
int main()
{
    @autoreleasepool {
        const uint32_t primary = 0xaacc4400, secondary = 0x22447700;
        for (unsigned test = 0; test < 8; test++) {
            ImGui::CreateContext();
            require(xemu_metal4_ui_init(nullptr, false));
            ::InitCustomRendering();
            assert(::controller_fbo->w == 512 && ::xmu_fbo->h == 256);
            id<MTLTexture> icon = (__bridge id<MTLTexture>)(void *)::g_icon_tex;
            MTLTextureDescriptor *td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                             width:1
                                            height:1
                                         mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> main_target =
                [icon.device newTextureWithDescriptor:td];
            require(
                xemu_metal4_ui_begin((uintptr_t)(__bridge void *)main_target));
            Fbo *fbo = test == 6 ? ::xmu_fbo :
                       test == 7 ? ::logo_fbo :
                                   ::controller_fbo;
            fbo->Target();
            std::vector<uint8_t> expected(fbo->w * fbo->h * 4);
            if (test < 2) {
                ControllerState state = {};
                state.bound = test;
                ::RenderController(0, 0, primary, secondary, &state);
                assert(!state.rumble_l && !state.rumble_r);
                Image src(test ? controller_mask_s_data : controller_mask_data,
                          test ? controller_mask_s_size : controller_mask_size);
                mask(expected, 512, src, 5, 5, 467, 364, 0, 148, 467, 364,
                     primary, secondary, 0, 0);
                mask(expected, 512, src, test ? 199 : 182, test ? 218 : 177,
                     test ? 84 : 113, test ? 84 : 118, 0, 0, 1, 1, 0, 0,
                     secondary, 2);
                mask(expected, 512, src, test ? 74 : 64, test ? 225 : 217, 67,
                     67, 0, 81, 67, 67, primary, secondary, 0, 1);
                mask(expected, 512, src, test ? 266 : 313, test ? 147 : 119, 67,
                     67, 0, 14, 67, 67, primary, secondary, 0, 1);
                mask(expected, 512, src, 15, 389, 150, 5, 0, 0, 1, 1, 0, 0,
                     primary + 0x80, 0);
                mask(expected, 512, src, 312, 389, 150, 5, 0, 0, 1, 1, 0, 0,
                     primary + 0x80, 0);
            } else if (test < 6) {
                unsigned port = test - 2;
                ::RenderControllerPort(0, 0, port, primary);
                Image src(controller_mask_data, controller_mask_size);
                const int label_x[] = { 67, 67, 67, 95 },
                          label_y[] = { 76, 48, 20, 76 };
                mask(expected, 512, src, 0, 0, 68, 44, 67, 104, 68, 44, primary,
                     primary, 0, 0);
                mask(expected, 512, src, 20, 52, 28, 28, label_x[port],
                     label_y[port], 28, 28, primary, primary, 0, 0);
            } else if (test == 6) {
                ::RenderXmu(0, 0, primary, secondary);
                Image src(xmu_mask_data, xmu_mask_size);
                mask(expected, 512, src, 0, 0, 256, 256, 0, 0, 512, 512,
                     primary, secondary, 0, 0);
            } else {
                ::RenderLogo(750);
            }
            fbo->Restore();
            id<MTLTexture> result =
                (__bridge id<MTLTexture>)(void *)fbo->Texture();
            id<MTLTexture> logo_source;
            if (test == 7) {
                uintptr_t handle =
                    R::LoadTextureFromMemory(logo_sdf_data, logo_sdf_size);
                logo_source = (__bridge id<MTLTexture>)(void *)handle;
                xemu_metal4_ui_release_texture(handle);
            }
            require(xemu_metal4_ui_end(nullptr));
            ::CleanupCustomRendering();
            require(xemu_metal4_ui_close());
            ImGui::DestroyContext();
            auto actual = read(result);
            if (test == 7) {
                NSError *error = nil;
                NV2AMetalCommands *commands =
                    [[NV2AMetalCommands alloc] initWithDevice:result.device
                                                        error:&error];
                XemuMetal4Decals *renderer = [[XemuMetal4Decals alloc]
                    initWithDevice:result.device
                       pixelFormat:MTLPixelFormatRGBA8Unorm
                             error:&error];
                MTLTextureDescriptor *ref_td = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                 width:512
                                                height:512
                                             mipmapped:NO];
                ref_td.usage =
                    MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                id<MTLTexture> reference =
                    [result.device newTextureWithDescriptor:ref_td];
                XemuMetal4Decal *d = [XemuMetal4Decal new];
                d.texture = logo_source;
                d.destination = CGRectMake(0, 0, 512, 512);
                d.source = CGRectMake(0, 0, 128, 128);
                d.shader = XemuMetal4DecalShaderLogo;
                d.primary = 0x62ca13ff;
                d.time = .75f;
                assert(commands && renderer && reference &&
                       [commands beginWithError:&error]);
                assert([renderer encodeDecals:@[ d ]
                                     commands:commands
                                       target:reference
                                        clear:YES
                                        error:&error]);
                assert([commands submitWithError:&error] &&
                       [commands waitUntilIdleWithError:&error]);
                auto physical = read(reference);
                for (unsigned y = 0; y < 512; y++)
                    memcpy(expected.data() + y * 512 * 4,
                           physical.data() + (511 - y) * 512 * 4, 512 * 4);
            }
            compare(actual, expected, test, test == 7 ? 0 : 1);
        }
        ImGui::CreateContext();
        require(xemu_metal4_ui_init(nullptr, false));
        fpng::fpng_init();
        const uint8_t input[] = {
            255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255
        };
        std::vector<uint8_t> png;
        assert(fpng::fpng_encode_image_to_memory(input, 2, 2, 3, png));
        uintptr_t thumb =
            xemu_snapshots_load_png_to_texture(png.data(), png.size());
        assert(thumb);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)(void *)thumb;
        uint8_t rgba[16];
        [texture getBytes:rgba
              bytesPerRow:8
               fromRegion:MTLRegionMake2D(0, 0, 2, 2)
              mipmapLevel:0];
        for (unsigned i = 0; i < 4; i++) {
            assert(!memcmp(rgba + i * 4, input + i * 3, 3));
            assert(rgba[i * 4 + 3] == 255);
        }
        assert(!xemu_snapshots_load_png_to_texture(nullptr, 1));
        assert(!xemu_snapshots_load_png_to_texture(png.data(), SIZE_MAX));
        ThumbnailFrame *frame = [ThumbnailFrame new];
        frame.texture = texture;
        NV2AMetalDisplayUniforms u = { .scale = { 1, 1 } };
        for (unsigned i = 0; i < 256; i++)
            u.palette[i] = i | i << 8 | i << 16;
        frame.displayUniforms = u;
        xemu_snapshots_set_metal4_framebuffer((__bridge void *)frame);
        frame = nil;
        xemu_snapshots_release_texture(thumb);
        g_config.display.ui.aspect_ratio =
            CONFIG_DISPLAY_UI_ASPECT_RATIO_NATIVE;
        g_config.display.filtering = CONFIG_DISPLAY_FILTERING_NEAREST;
        std::thread worker([&] {
            @autoreleasepool {
                size_t size = 0;
                void *data =
                    xemu_snapshots_create_framebuffer_thumbnail_png(&size);
                assert(data && size);
                std::vector<uint8_t> decoded;
                unsigned width, height, channels;
                assert(fpng::fpng_decode_memory(data, size, decoded, width,
                                                height, channels, 3) ==
                       fpng::FPNG_DECODE_SUCCESS);
                assert(width == 240 && height == 240 && channels == 3);
                for (unsigned y = 0; y < height; y++)
                    for (unsigned x = 0; x < width; x++) {
                        unsigned source = (y >= 120 ? 2 : 0) + (x >= 120);
                        assert(!memcmp(decoded.data() + (y * width + x) * 3,
                                       input + source * 3, 3));
                    }
                free(data);
            }
        });
        worker.join();
        screenshot_collision_test(input);
        xemu_snapshots_set_metal4_framebuffer(nullptr);
        size_t size = 99;
        assert(!xemu_snapshots_create_framebuffer_thumbnail_png(&size) &&
               !size);
        require(xemu_metal4_ui_close());
        ImGui::DestroyContext();
        puts("Native application thumbnails: PNG import, owned Metal handles, "
             "57600 worker-capture pixels PASS");
        printf("Metal4 UI assets: %u images, %zu pixels, %zu neighboring bytes "
               "PASS\n",
               images, pixels, neighbors);
    }
}
