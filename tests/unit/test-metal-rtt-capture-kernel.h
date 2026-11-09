/* Regular RTT admission and a separate valid-input capture-kernel probe.
 * The kernel probe does not claim reachability of the defensive host branch.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RTT_CAPTURE_KERNEL_H
#define TEST_METAL_RTT_CAPTURE_KERNEL_H
#include "hw/xbox/nv2a/pgraph/metal/texture-cache-types.h"

@interface NV2AMetalTextureCache (RTTCaptureKernelTest)
- (BOOL)prepareCaptureWithError:(NSError **)error;
@end
static _Thread_local unsigned rck_scope, rck_copies, rck_dispatches,
    rck_prepares;
static BOOL (*rck_prepare_original)(id, SEL, NSError **);
static void (*rck_dispatch_original)(id, SEL, MTLSize, MTLSize);
static void (*rck_copy_original)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin,
                                 MTLSize, id, NSUInteger, NSUInteger,
                                 MTLOrigin);
static BOOL rck_prepare(id object, SEL selector, NSError **error)
{
    if (rck_scope)
        rck_prepares++;
    return rck_prepare_original(object, selector, error);
}
static void rck_dispatch(id object, SEL selector, MTLSize threads,
                         MTLSize group)
{
    if (rck_scope)
        rck_dispatches++;
    rck_dispatch_original(object, selector, threads, group);
}
static void rck_copy(id object, SEL selector, id source, NSUInteger slice,
                     NSUInteger level, MTLOrigin origin, MTLSize size,
                     id target, NSUInteger targetSlice, NSUInteger targetLevel,
                     MTLOrigin targetOrigin)
{
    if (rck_scope)
        rck_copies++;
    rck_copy_original(object, selector, source, slice, level, origin, size,
                      target, targetSlice, targetLevel, targetOrigin);
}
static void rck_begin_scope(unsigned scope)
{
    rck_scope = scope;
    rck_copies = rck_dispatches = rck_prepares = 0;
}
static NV2AMetalSurfaceCache *rck_cache(NV2AMetalCommands *q)
{
    NSError *error = nil;
    id<MTLBuffer> vram =
        [q.device newBufferWithLength:16384
                              options:MTLResourceStorageModeShared];
    require(vram != nil, nil);
    memset(vram.contents, 0x51, vram.length);
    NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:q
                    vram:vram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address <= vram.length && length <= vram.length - address);
            }
                   error:&error];
    require(cache != nil, error);
    return cache;
}
static void rck_finish(NV2AMetalSurfaceCache *cache)
{
    NSError *error = nil;
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
}
typedef struct RCKPair {
    unsigned surface, texture, bytes;
    BOOL swizzled;
    MTLPixelFormat native;
} RCKPair;
static NV2AMetalTextureSource rck_source(RCKPair pair)
{
    return (NV2AMetalTextureSource){ .shape = { .format = pair.texture,
                                                .dimension = 2,
                                                .width = 16,
                                                .height = 16,
                                                .depth = 1,
                                                .levels = 1,
                                                .pitch = 16 * pair.bytes },
                                     .address = 4096,
                                     .length = 256 * pair.bytes };
}
static NV2AMetalCachedSurface *rck_surface(NV2AMetalSurfaceCache *cache,
                                           RCKPair pair)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig config = { .format = pair.surface,
                                      .width = 16,
                                      .height = 16,
                                      .pitch = 16 * pair.bytes,
                                      .scale = 1,
                                      .color = YES,
                                      .swizzle = pair.swizzled };
    require([cache prepareCPUAccessAtAddress:4096
                                      length:256 * pair.bytes
                                       write:YES
                                       error:&error],
            error);
    uint8_t *vram = (uint8_t *)cache.vram.contents + 4096;
    for (unsigned i = 0; i < 256 * pair.bytes; i++)
        vram[i] = (i * 37 + 11) & 255;
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:4096
                                                              config:&config
                                                               frame:1
                                                               error:&error];
    require(surface != nil, error);
    rck_finish(cache);
    MTLTextureSwizzleChannels swizzle = surface.transfer.nativeSwizzle;
    assert(surface.transfer.nativePixelFormat == pair.native &&
           surface.transfer.nativeWidth == 16 &&
           surface.transfer.nativeHeight == 16 &&
           swizzle.red == MTLTextureSwizzleRed &&
           swizzle.green == MTLTextureSwizzleGreen &&
           swizzle.blue == MTLTextureSwizzleBlue &&
           swizzle.alpha == MTLTextureSwizzleAlpha);
    return surface;
}
static NV2AMetalCachedTexture *rck_direct(NV2AMetalTextureCache *cache,
                                          RCKPair pair)
{
    NSError *error = nil;
    NV2AMetalTextureSource source = rck_source(pair);
    NV2AMetalSamplerConfig sampler = policy();
    rck_begin_scope(1);
    NV2AMetalCachedTexture *texture = [cache prepareSource:&source
                                                   sampler:&sampler
                                                     frame:2
                                                     error:&error];
    rck_scope = 0;
    require(texture != nil, error);
    return texture;
}
static void rck_regular_matrix(NV2AMetalCommands *q)
{
    const RCKPair pairs[] = {
        { 1, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5, 2, NO,
          MTLPixelFormatBGR5A1Unorm },
        { 2, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5, 2, NO,
          MTLPixelFormatBGR5A1Unorm },
        { 3, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5, 2, NO,
          MTLPixelFormatB5G6R5Unorm },
        { 3, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5, 2, YES,
          MTLPixelFormatB5G6R5Unorm },
        { 4, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 4, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8, 4, YES,
          MTLPixelFormatBGRA8Unorm },
        { 5, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 5, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8, 4, YES,
          MTLPixelFormatBGRA8Unorm },
        { 6, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 6, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 6, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 6, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8, 4, YES,
          MTLPixelFormatBGRA8Unorm },
        { 7, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 7, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 7, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 7, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8, 4, YES,
          MTLPixelFormatBGRA8Unorm },
        { 8, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 8, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 8, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8, 4, NO,
          MTLPixelFormatBGRA8Unorm },
        { 8, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8, 4, YES,
          MTLPixelFormatBGRA8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8, 1, YES, MTLPixelFormatR8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8, 1, YES,
          MTLPixelFormatR8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8, 1, YES, MTLPixelFormatR8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 1, NO,
          MTLPixelFormatR8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8, 1, NO,
          MTLPixelFormatR8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8, 1, NO,
          MTLPixelFormatR8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8, 2, YES,
          MTLPixelFormatRG8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8, 2, YES,
          MTLPixelFormatRG8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8, 2, YES,
          MTLPixelFormatRG8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8, 2, NO,
          MTLPixelFormatRG8Unorm },
        { NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8, 2, NO,
          MTLPixelFormatRG8Unorm }
    };
    for (NSUInteger i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
        @autoreleasepool {
            NSError *error = nil;
            NV2AMetalSurfaceCache *cache = rck_cache(q);
            NV2AMetalTextureCache *tc =
                [[NV2AMetalTextureCache alloc] initWithSurfaces:cache
                                                          error:&error];
            require(tc != nil, error);
            NV2AMetalCachedSurface *surface = rck_surface(cache, pairs[i]);
            NV2AMetalCachedTexture *texture = rck_direct(tc, pairs[i]);
            unsigned copies = rck_copies, dispatches = rck_dispatches,
                     prepares = rck_prepares;
            id<MTLBuffer> readback =
                test_metal_read_texture(q, texture.binding.texture, 0, 0);
            rck_finish(cache);
            require([texture validateCompletedWithError:&error], error);
            const float *values = readback.contents;
            for (unsigned k = 0; k < 256 * 4; k++)
                assert(isfinite(values[k]));
            assert(
                surface.valid && texture.scale == 1 &&
                texture.binding.texture.storageMode == MTLStorageModePrivate &&
                copies == 1 && !dispatches && !prepares &&
                ![tc valueForKey:@"capture"] && ![tc valueForKey:@"arguments"]);
        }
    }
}
static void rck_kernel_pair(NV2AMetalCommands *q, unsigned mode)
{
    NSError *error = nil;
    const unsigned orders[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8
    };
    RCKPair pair = { mode == 3 ?
                         NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8 :
                         NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                     orders[mode], 4, NO, MTLPixelFormatBGRA8Unorm };
    NV2AMetalSurfaceCache *cache = rck_cache(q);
    NV2AMetalTextureCache *tc =
        [[NV2AMetalTextureCache alloc] initWithSurfaces:cache error:&error];
    require(tc != nil, error);
    NV2AMetalCachedSurface *surface = rck_surface(cache, pair);
    uint8_t *ram = (uint8_t *)cache.vram.contents + 4096;
    NSData *oldRAM = [NSData dataWithBytes:ram length:1024];
    NV2AMetalSurfaceConfig renderConfig = surface.transfer.config;
    surface = [cache prepareSurfaceAtAddress:surface.address
                                      config:&renderConfig
                                       frame:2
                                forRendering:YES
                                       error:&error];
    require(surface != nil, error);
    id<MTLTexture> native = [surface.transfer textureForCommands:q
                                                           error:&error];
    require(native != nil, error);
    uint8_t words[16 * 256];
    memset(words, 0xcd, sizeof(words));
    for (unsigned i = 0; i < 256; i++) {
        uint8_t *pixel = words + (i / 16) * 256 + (i % 16) * 4;
        pixel[0] = (i * 29 + 7) & 255;
        pixel[1] = (i * 37 + 11) & 255;
        pixel[2] = i;
        pixel[3] = (i * 53 + 17) & 255;
    }
    id<MTLBuffer> source =
        [q.device newBufferWithBytes:words
                              length:sizeof(words)
                             options:MTLResourceStorageModeShared];
    require(source && [q addResource:source error:&error] &&
                [q addResource:native error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
               sourceOffset:0
          sourceBytesPerRow:256
        sourceBytesPerImage:sizeof(words)
                 sourceSize:MTLSizeMake(16, 16, 1)
                  toTexture:native
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([cache markWritten:surface replacingContents:YES error:&error],
            error);
    NV2AMetalCachedTexture *direct = rck_direct(tc, pair);
    unsigned directCopies = rck_copies, directDispatches = rck_dispatches;
    assert(![tc valueForKey:@"capture"] && ![tc valueForKey:@"arguments"]);
    /* Compile the actual generated production source. No input descriptor,
     * native getter, selector decision, or storage flags are overridden. */
    require([tc prepareCaptureWithError:&error], error);
    id<MTLComputePipelineState> pipeline = [tc valueForKey:@"capture"];
    id<MTL4ArgumentTable> arguments = [tc valueForKey:@"arguments"];
    require(pipeline && arguments, nil);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:16
                                    height:16
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> computed = [q.device newTextureWithDescriptor:td];
    require(computed != nil, nil);
    NV2AMetalSurfaceTextureUniforms u = { .width = 16,
                                          .height = 16,
                                          .force_alpha = mode == 3,
                                          .channel_order = mode == 1 ? 1 :
                                                           mode == 2 ? 2 :
                                                                       0 };
    NSUInteger offset;
    id<MTLBuffer> uniforms = [q uploadBytes:&u
                                     length:sizeof(u)
                                     offset:&offset
                                      error:&error];
    require(uniforms && [q addResource:computed error:&error] &&
                [q addResource:native error:&error] &&
                [q keepAlive:tc error:&error],
            error);
    [arguments setAddress:uniforms.gpuAddress + offset atIndex:0];
    [arguments setTexture:native.gpuResourceID atIndex:0];
    [arguments setTexture:computed.gpuResourceID atIndex:1];
    e = [q.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:pipeline];
    [e setArgumentTable:arguments];
    rck_begin_scope(2);
    [e dispatchThreads:MTLSizeMake(16, 16, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    rck_scope = 0;
    unsigned kernelDispatches = rck_dispatches;
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([cache markRTTSnapshotCaptured:surface error:&error], error);
    id<MTLBuffer> reference =
        test_metal_read_texture(q, direct.binding.texture, 0, 0);
    id<MTLBuffer> actual = test_metal_read_texture(q, computed, 0, 0);
    rck_finish(cache);
    if (memcmp(actual.contents, reference.contents, 256 * 16)) {
        fprintf(stderr,
                "RTT capture kernel mode%u: logical GPU float4 bytes differ\n",
                mode);
        abort();
    }
    // The shader must see the GPU image, which differs from the untouched RAM.
    assert(!memcmp(oldRAM.bytes, ram, oldRAM.length));
    for (unsigned i = 0; i < 256; i++) {
        const uint8_t *pixel = words + (i / 16) * 256 + (i % 16) * 4;
        const float *value = (const float *)actual.contents + i * 4;
        unsigned rgba[4] = { pixel[2], pixel[1], pixel[0],
                             mode == 3 ? 255u : pixel[3] };
        unsigned channel[4] = { 0, 1, 2, 3 };
        if (mode == 1) {
            channel[0] = 2;
            channel[2] = 0;
        }
        if (mode == 2) {
            channel[0] = 3;
            channel[1] = 0;
            channel[2] = 1;
            channel[3] = 2;
        }
        for (unsigned k = 0; k < 4; k++)
            assert(fabsf(value[k] - rgba[channel[k]] / 255.f) < .000001f);
    }
    assert(directCopies == 1 && !directDispatches && kernelDispatches == 1);
    require([direct validateCompletedWithError:&error], error);
}
static void rtt_capture_kernel_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *q = [[NV2AMetalCommands alloc] initWithDevice:device
                                                               error:&error];
    require(q != nil, error);
    require([q beginWithError:&error] != nil, error);
    id encoder = [q.commandBuffer computeCommandEncoder];
    require(encoder != nil, nil);
    Method methods[] = {
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:
                      sourceSize:toTexture:destinationSlice:destinationLevel:
                      destinationOrigin:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(NV2AMetalTextureCache.class,
                                @selector(prepareCaptureWithError:))
    };
    [encoder endEncoding];
    [q cancel];
    IMP originals[3],
        replacements[] = { (IMP)rck_copy, (IMP)rck_dispatch, (IMP)rck_prepare };
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    rck_copy_original = (void *)originals[0];
    rck_dispatch_original = (void *)originals[1];
    rck_prepare_original = (void *)originals[2];
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        rck_regular_matrix(q);
        for (unsigned mode = 0; mode < 4; mode++)
            rck_kernel_pair(q, mode);
    } @finally {
        rck_scope = 0;
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
        [q cancel];
    }
    puts("RTT valid inputs:31 compatible native-family/identity-swizzle cases "
         "use actual direct copies and no capture compute;"
         "4 separate original-kernel BGRA8 probes match direct-copy logical "
         "GPU float4 bytes,"
         "all256codes/channel,RGBA orders/ForceAlpha,GPU image differs from "
         "RAM PASS;"
         "kernel coverage is not host-fallback branch reachability");
}
#endif
