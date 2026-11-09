/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "frame-images.h"
#import "hw/xbox/nv2a/pgraph/metal/scanout-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
#include "frame-images-source.h"
#include <fpng.h>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

static std::mutex capture_lock;
static NV2AMetalFramebuffer *capture_frame;
static id<MTLTexture> capture_texture;
static NV2AMetalDisplayUniforms capture_uniforms;
static BOOL capture_screen_off;
/* Retain only the current capture device's immutable RGB module. A capture
 * keeps its own local reference across compilation; clearing/changing the
 * published device releases this cache without invalidating an active call. */
static NV2AMetalShaderLibrary *capture_rgb_module;

void xemu_metal4_set_capture_frame(void *handle)
{
    @autoreleasepool {
        NV2AMetalFramebuffer *frame = (__bridge NV2AMetalFramebuffer *)handle;
        std::lock_guard<std::mutex> guard(capture_lock);
        capture_frame = frame;
        capture_texture = frame.texture;
        if (capture_rgb_module.library.device != capture_texture.device)
            capture_rgb_module = nil;
        capture_uniforms =
            frame ? frame.displayUniforms : NV2AMetalDisplayUniforms{};
        capture_screen_off = frame.screenOff;
    }
}
bool xemu_metal4_has_capture_frame(void)
{
    std::lock_guard<std::mutex> guard(capture_lock);
    return capture_texture != nil;
}

static bool capture_size(NSUInteger source_width, NSUInteger source_height,
                         float aspect, uint32_t max_width, uint32_t max_height,
                         uint32_t &width, uint32_t &height)
{
    if (!source_width || !source_height || !std::isfinite(aspect) || aspect < 0)
        return false;
    double adjusted = aspect ? double(source_height) * aspect : source_width;
    if (adjusted < 1 || adjusted > 16384 || source_height > 16384)
        return false;
    width = uint32_t(adjusted);
    height = uint32_t(source_height);
    if (!max_width)
        max_width = width;
    if (!max_height)
        max_height = height;
    if (max_width > 16384 || max_height > 16384)
        return false;
    double ratio = double(width) / height;
    if (double(max_width) / max_height >= ratio) {
        width = uint32_t(max_height * ratio);
        height = max_height;
    } else {
        width = max_width;
        height = uint32_t(max_width / ratio);
    }
    return width && height;
}

static id<MTLComputePipelineState> rgb_pipeline(id<MTLDevice> device,
                                                NSError **error)
{
    NV2AMetalShaderLibrary *module;
    {
        std::lock_guard<std::mutex> guard(capture_lock);
        if (capture_rgb_module.library.device == device)
            module = capture_rgb_module;
    }
    if (!module)
        module = [NV2AMetalShaderLibrary sharedWithDevice:device
                                                   source:metal_shader_source
                                                    error:error];
    id<MTLComputePipelineState> pipeline =
        [module computeFunction:@"xemu_capture_rgb" error:error];
    if (!pipeline)
        return nil;
    {
        std::lock_guard<std::mutex> guard(capture_lock);
        /* An older capture may finish after its frame was withdrawn. Do not
         * republish its module for an absent or different current device. */
        if (capture_texture.device == device)
            capture_rgb_module = module;
    }
    return pipeline;
}

void *xemu_metal4_capture_png(float aspect, uint32_t max_width,
                              uint32_t max_height, bool linear, size_t *size)
{
    if (!size)
        return nullptr;
    *size = 0;
    @autoreleasepool {
        NV2AMetalFramebuffer *frame;
        id<MTLTexture> source;
        NV2AMetalDisplayUniforms u;
        BOOL screen_off;
        {
            std::lock_guard<std::mutex> guard(capture_lock);
            frame = capture_frame;
            source = capture_texture;
            u = capture_uniforms;
            screen_off = capture_screen_off;
        }
        if (!source)
            return nullptr;
        uint32_t width, height;
        if (!capture_size(source.width, source.height, aspect, max_width,
                          max_height, width, height))
            return nullptr;
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:source.device
                                                error:&error];
        NV2AMetalDisplay *display =
            [[NV2AMetalDisplay alloc] initWithDevice:source.device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        id<MTLComputePipelineState> pipeline =
            rgb_pipeline(source.device, &error);
        if (!commands || !display || !pipeline)
            return nullptr;
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:width
                                        height:height
                                     mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> target = [source.device newTextureWithDescriptor:td];
        id<MTLBuffer> rgb =
            [source.device newBufferWithLength:NSUInteger(width) * height * 3
                                       options:MTLResourceStorageModeShared];
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
        ad.maxBufferBindCount = 1;
        ad.maxTextureBindCount = 1;
        ad.initializeBindings = YES;
        id<MTL4ArgumentTable> arguments =
            [source.device newArgumentTableWithDescriptor:ad error:&error];
        u.scale[0] = u.scale[1] = 1;
        if (!target || !rgb || !arguments ||
            ![commands beginWithError:&error] ||
            ![commands keepAlive:frame error:&error] ||
            ![display encodeWithCommands:commands
                                  source:source
                                  target:target
                                uniforms:&u
                                  linear:linear
                               screenOff:screen_off
                                   error:&error] ||
            ![commands addResource:rgb error:&error] ||
            ![commands keepAlive:pipeline error:&error] ||
            ![commands keepAlive:arguments error:&error]) {
            [commands cancel];
            return nullptr;
        }
        [arguments setAddress:rgb.gpuAddress atIndex:0];
        [arguments setTexture:target.gpuResourceID atIndex:0];
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        if (!e) {
            [commands cancel];
            return nullptr;
        }
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageDispatch
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e setComputePipelineState:pipeline];
        [e setArgumentTable:arguments];
        [e dispatchThreads:MTLSizeMake(width, height, 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [e barrierAfterStages:MTLStageDispatch
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
        if (![commands submitWithError:&error] ||
            ![commands waitUntilIdleWithError:&error])
            return nullptr;
        static std::once_flag fpng_ready;
        std::call_once(fpng_ready, [] { fpng::fpng_init(); });
        std::vector<uint8_t> png;
        if (!fpng::fpng_encode_image_to_memory(rgb.contents, width, height, 3,
                                               png))
            return nullptr;
        void *result = std::malloc(png.size());
        if (!result)
            return nullptr;
        std::memcpy(result, png.data(), png.size());
        *size = png.size();
        return result;
    }
}
