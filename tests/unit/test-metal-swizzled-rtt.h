/* Native channel-order RTT captures versus the original RAM/Morton decoder.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SWIZZLED_RTT_H
#define TEST_METAL_SWIZZLED_RTT_H
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"

@interface NV2AMetalTextureCache (SwizzledRTTTest)
- (BOOL)canCaptureSwizzledChannelsSurface:(NV2AMetalCachedSurface *)surface
                                   format:(unsigned)format;
- (BOOL)prepareDownsampleChannelsCaptureWithError:(NSError **)error;
@end
static _Thread_local BOOL srt_reference;
static BOOL (*srt_admission_original)(id, SEL, NV2AMetalCachedSurface *,
                                      unsigned);
static BOOL srt_admission(id object, SEL selector,
                          NV2AMetalCachedSurface *surface, unsigned format)
{
    return !srt_reference &&
           srt_admission_original(object, selector, surface, format);
}
@interface SwizzledRTTFixture : NSObject {
@public
    NV2AMetalCommands *queue;
    NV2AMetalSurfaceCache *cache;
    NV2AMetalTextureCache *textures;
    NV2AMetalCachedSurface *surface;
    id<MTLBuffer> ram;
    NV2AMetalSurfaceConfig config;
    NV2AMetalTextureSource source;
    unsigned notifications;
}
@end
@implementation SwizzledRTTFixture
@end
static void srt_image(SwizzledRTTFixture *f, unsigned phase)
{
    NSError *error = nil;
    f->surface = [f->cache prepareSurfaceAtAddress:4096
                                            config:&f->config
                                             frame:phase + 2
                                      forRendering:YES
                                             error:&error];
    require(f->surface != nil, error);
    id<MTLTexture> texture = [f->surface.transfer textureForCommands:f->queue
                                                               error:&error];
    require(texture != nil, error);
    NSUInteger pitch = (texture.width * 4 + 255) & ~(NSUInteger)255;
    id<MTLBuffer> bytes =
        [f->queue.device newBufferWithLength:pitch * texture.height
                                     options:MTLResourceStorageModeShared];
    require(bytes != nil, nil);
    memset(bytes.contents, 0x91, bytes.length);
    for (NSUInteger y = 0; y < texture.height; y++)
        for (NSUInteger x = 0; x < texture.width; x++) {
            unsigned i = ((y / f->config.scale) * f->config.width +
                          x / f->config.scale + phase * 43) &
                         255;
            uint8_t *p = (uint8_t *)bytes.contents + y * pitch + x * 4;
            p[0] = i * 29 + 7;
            p[1] = i * 37 + 11;
            p[2] = i;
            p[3] = i * 53 + 17;
            if (x % f->config.scale || y % f->config.scale) {
                p[0] ^= 0xd3;
                p[1] ^= 0x6b;
                p[2] ^= 0xa7;
                p[3] ^= 0xf1;
            }
        }
    require([f->queue addResource:bytes error:&error] &&
                [f->queue addResource:texture error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [f->queue.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:bytes
               sourceOffset:0
          sourceBytesPerRow:pitch
        sourceBytesPerImage:bytes.length
                 sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                  toTexture:texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([f->cache markWritten:f->surface
                replacingContents:YES
                            error:&error],
            error);
    rck_finish(f->cache);
}
static SwizzledRTTFixture *srt_fixture(id<MTLDevice> device, unsigned family,
                                       unsigned order, unsigned scale)
{
    NSError *error = nil;
    SwizzledRTTFixture *f = [SwizzledRTTFixture new];
    f->queue = [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    f->ram = [device newBufferWithLength:16384
                                 options:MTLResourceStorageModeShared];
    require(f->queue && f->ram, error);
    memset(f->ram.contents, 0x51, f->ram.length);
    __weak SwizzledRTTFixture *weak = f;
    f->cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:f->queue
                    vram:f->ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address == 4096 && length == 1024);
              SwizzledRTTFixture *owner = weak;
              if (owner)
                  owner->notifications++;
            }
                   error:&error];
    require(f->cache != nil, error);
    const unsigned surfaceFormats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8
    };
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8
    };
    unsigned width = scale == 2 ? 8 :
                     scale == 4 ? 32 :
                                  16,
             height = 256 / width;
    f->config = (NV2AMetalSurfaceConfig){ .format = surfaceFormats[family],
                                          .width = width,
                                          .height = height,
                                          .pitch = width * 4,
                                          .scale = scale,
                                          .color = YES,
                                          .swizzle = order != 3 };
    f->surface = [f->cache prepareSurfaceAtAddress:4096
                                            config:&f->config
                                             frame:1
                                             error:&error];
    require(f->surface != nil, error);
    rck_finish(f->cache);
    srt_image(f, 0);
    f->textures = [[NV2AMetalTextureCache alloc] initWithSurfaces:f->cache
                                                            error:&error];
    require(f->textures != nil, error);
    f->source = (NV2AMetalTextureSource){ .shape = { .format = formats[order],
                                                     .dimension = 2,
                                                     .width = width,
                                                     .height = height,
                                                     .depth = 1,
                                                     .levels = 1,
                                                     .pitch = width * 4 },
                                          .address = 4096,
                                          .length = 1024 };
    return f;
}
/* Sampling uses the existing production pixel shader, not the readback's
 * swizzle-expansion helper. Nearest texel centers cover every logical texel. */
static id<MTLBuffer> srt_sample(SwizzledRTTFixture *f,
                                NV2AMetalCachedTexture *texture,
                                NV2AMetalPixelShader *shader)
{
    NSError *error = nil;
    unsigned w = (unsigned)texture.binding.texture.width,
             h = (unsigned)texture.binding.texture.height;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:w
                                    height:h
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [f->queue.device newTextureWithDescriptor:td];
    require(target != nil, nil);
    const float xy[6][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 },
                             { 1, 0 }, { 1, 1 }, { 0, 1 } };
    NV2AMetalVertex v[6] = { 0 };
    for (unsigned i = 0; i < 6; i++) {
        v[i].clip[0] = 2 * xy[i][0] - 1;
        v[i].clip[1] = 1 - 2 * xy[i][1];
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].texcoord[0][0] = xy[i][0] * (texture.rectangle ? w : 1);
        v[i].texcoord[0][1] = xy[i][1] * (texture.rectangle ? h : 1);
        v[i].texcoord[0][3] = 1;
        v[i].plane[0][2] = v[i].plane[1][2] = v[i].plane[2][2] = .5f;
    }
    id<MTLBuffer> vertices =
        [f->queue.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    require(vertices != nil, nil);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = w;
    u.clip_regions[0][3] = h;
    u.textures[0].dimension = 2;
    u.textures[0].rectangle = texture.rectangle;
    u.textures[0].scale = texture.scale;
    u.textures[0].sampling = texture.binding.sampling;
    u.textures[0].snorm = texture.mixedSignedHalf ?
                              NV2AMetalTextureNormalizationMixedHalf :
                              texture.signedNormalized;
    u.textures[0].signed_channels = f->source.shape.signed_channels;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    bindings[0].texture = texture.binding.texture;
    bindings[0].sampler = texture.binding.sampler;
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([shader encodeVertices:vertices
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:bindings
                              pass:pass
                      depthStencil:nil
                          commands:f->queue
                             error:&error],
            error);
    return test_metal_read_2d_texture(f->queue, target, 0);
}
static NSData *srt_pack(id<MTLBuffer> pixels, unsigned width, unsigned height)
{
    NSUInteger row = (width * 16 + 255) & ~(NSUInteger)255;
    require(pixels.length >= row * height, nil);
    NSMutableData *data = [NSMutableData data];
    for (unsigned y = 0; y < height; y++)
        [data appendBytes:(const uint8_t *)pixels.contents + y * row
                   length:width * 16];
    return data;
}
static void srt_expected(unsigned order, unsigned i, uint32_t uniform,
                         unsigned rgba[4])
{
    unsigned native[4] = { i, (i * 37 + 11) & 255, (i * 29 + 7) & 255,
                           (i * 53 + 17) & 255 };
    if (uniform) {
        native[0] = (uniform >> 16) & 255;
        native[1] = (uniform >> 8) & 255;
        native[2] = uniform & 255;
        native[3] = uniform >> 24;
    }
    const unsigned permutation[3][4] = { { 2, 1, 0, 3 },
                                         { 3, 0, 1, 2 },
                                         { 1, 0, 3, 2 } };
    for (unsigned k = 0; k < 4; k++)
        rgba[k] = native[permutation[MIN(order, 2u)][k]];
}
static NSData *srt_observe(SwizzledRTTFixture *f,
                           NV2AMetalCachedTexture *texture,
                           NV2AMetalPixelShader *shader, unsigned order,
                           unsigned phase, uint32_t uniform, BOOL goldens)
{
    NSError *error = nil;
    require([f->cache beginRecordingWithError:&error], error);
    id<MTLBuffer> raw =
        test_metal_read_2d_texture(f->queue, texture.binding.texture, 0);
    id<MTLBuffer> sampled = srt_sample(f, texture, shader);
    rck_finish(f->cache);
    require([texture validateCompletedWithError:&error], error);
    unsigned w = (unsigned)texture.binding.texture.width,
             h = (unsigned)texture.binding.texture.height;
    NSData *read = srt_pack(raw, w, h), *sample = srt_pack(sampled, w, h);
    if (goldens) {
        const float *a = read.bytes, *b = sample.bytes;
        for (unsigned i = 0; i < w * h; i++) {
            unsigned rgba[4];
            srt_expected(order, (i + phase * 43) & 255, uniform, rgba);
            for (unsigned k = 0; k < 4; k++) {
                float expected = rgba[k] / 255.f;
                if (fabsf(a[i * 4 + k] - expected) > .000001f ||
                    fabsf(b[i * 4 + k] - expected) > .000001f) {
                    fprintf(stderr,
                            "Swizzled RTT GPU scalar order%u phase%u pixel%u "
                            "lane%u read%.9g sample%.9g expected%.9g\n",
                            order, phase, i, k, a[i * 4 + k], b[i * 4 + k],
                            expected);
                    abort();
                }
            }
        }
    }
    NSMutableData *result = [NSMutableData dataWithData:read];
    [result appendData:sample];
    return result;
}
static NSData *srt_pair(id<MTLDevice> device, NV2AMetalPixelShader *shader,
                        unsigned family, unsigned order, unsigned scale,
                        BOOL reference, BOOL lifecycle)
{
    srt_reference = reference;
    SwizzledRTTFixture *f = srt_fixture(device, family, order, scale);
    NSError *error = nil;
    NV2AMetalSamplerConfig sampler = policy();
    x8r_begin_scope();
    NV2AMetalCachedTexture *old = [f->textures prepareSource:&f->source
                                                     sampler:&sampler
                                                       frame:3
                                                       error:&error];
    rck_scope = 0;
    unsigned copies = rck_copies, dispatches = rck_dispatches,
             uploads = x8r_uploads, downloads = x8r_download_calls;
    require(old != nil, error);
    if (lifecycle && !reference) {
        [f->cache cancel];
        assert(![old validateCompletedWithError:&error]);
        error = nil;
        old = [f->textures prepareSource:&f->source
                                 sampler:&sampler
                                   frame:3
                                   error:&error];
        require(old != nil, error);
    }
    NSData *first = srt_observe(f, old, shader, order, 0, 0, YES);
    // GPU read and actual pixel-sampler goldens precede all route assertions.
    BOOL compute = scale > 1 || order >= 2;
    assert(old.scale == 1 && old.binding.texture.width == f->config.width &&
           old.binding.texture.height == f->config.height);
    if (reference)
        assert(downloads == 1 && f->notifications == 1 && dispatches);
    else {
        assert(!downloads && !f->notifications && !uploads &&
               (compute ? !copies && dispatches == 1 :
                          copies == 1 && !dispatches));
        for (unsigned i = 0; i < 1024; i++)
            assert(((const uint8_t *)f->ram.contents)[4096 + i] == 0x51);
    }
    NSMutableData *result = [NSMutableData dataWithData:first];
    if (lifecycle) {
        srt_image(f, 1);
        require([f->cache beginRecordingWithError:&error], error);
        id<MTLBuffer> inFlight =
            test_metal_read_2d_texture(f->queue, old.binding.texture, 0);
        NV2AMetalCachedTexture *fresh = [f->textures prepareSource:&f->source
                                                           sampler:&sampler
                                                             frame:4
                                                             error:&error];
        require(fresh != nil, error);
        NSData *second = srt_observe(f, fresh, shader, order, 1, 0, YES);
        NSData *oldRead = srt_pack(inFlight, f->config.width, f->config.height);
        assert(!memcmp(oldRead.bytes, first.bytes, oldRead.length));
        [result appendData:second];
        require([f->cache resolveCPUAccessAtAddress:4096
                                             length:1024
                                              write:YES
                                              error:&error],
                error);
        uint32_t *words = (uint32_t *)((uint8_t *)f->ram.contents + 4096);
        for (unsigned i = 0; i < 256; i++)
            words[i] = 0xe9112233;
        NV2AMetalCachedTexture *alias = [f->textures prepareSource:&f->source
                                                           sampler:&sampler
                                                             frame:5
                                                             error:&error];
        require(alias != nil, error);
        [result appendData:srt_observe(f, alias, shader, order, 0, 0xe9112233,
                                       YES)];
        NSData *retained = srt_observe(f, fresh, shader, order, 1, 0, YES);
        assert([retained isEqualToData:second]);
        NV2AMetalCommands *snapshotQueue =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        require(snapshotQueue != nil, error);
        NSData *snapshot = nv2a_metal_texture_snapshot(old.binding.texture,
                                                       snapshotQueue, &error);
        require(snapshot != nil, error);
        require([f->cache discardForRestoreWithError:&error], error);
        id<MTLTexture> restored =
            nv2a_metal_texture_restore(snapshot, snapshotQueue, &error);
        require(restored != nil, error);
        require([snapshotQueue beginWithError:&error] != nil, error);
        id<MTLBuffer> image =
            test_metal_read_2d_texture(snapshotQueue, restored, 0);
        require([snapshotQueue submitWithError:&error] &&
                    [snapshotQueue waitUntilIdleWithError:&error],
                error);
        NSData *restoredBytes =
            srt_pack(image, f->config.width, f->config.height);
        assert(!memcmp(restoredBytes.bytes, first.bytes, restoredBytes.length));
    }
    return result;
}
/* These are valid old-path inputs. The source predicate cannot inspect
 * mip/signed/pitch fields; complete compatible() must still reject the RTT. */
static NSData *srt_guard(id<MTLDevice> device, NV2AMetalPixelShader *shader,
                         unsigned kind, BOOL reference)
{
    srt_reference = reference;
    SwizzledRTTFixture *f =
        srt_fixture(device, 0, kind == 0 || kind == 3 ? 3 : 0, 2);
    if (kind == 0)
        f->source.shape.format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8;
    else if (kind == 1) {
        f->source.shape.levels = 2;
        f->source.shape.max_level = 1;
    } else if (kind == 2)
        f->source.shape.signed_channels = 15;
    else
        f->source.shape.pitch += 4;
    NSError *error = nil;
    require([f->textures sourceLengthForShape:&f->source.shape
                                paletteLength:0
                                       length:&f->source.length
                                        error:&error],
            error);
    NV2AMetalSamplerConfig sampler = policy();
    x8r_begin_scope();
    NV2AMetalCachedTexture *texture = [f->textures prepareSource:&f->source
                                                         sampler:&sampler
                                                           frame:3
                                                           error:&error];
    rck_scope = 0;
    require(texture != nil, error);
    unsigned downloads = x8r_download_calls;
    NSData *image = srt_observe(f, texture, shader, 0, 0, 0, NO);
    const unsigned route[] = { downloads, f->notifications,
                               !![f->textures
                                   valueForKey:@"downsampleChannelsCapture"] };
    NSMutableData *result = [NSMutableData dataWithData:image];
    [result appendBytes:route length:sizeof(route)];
    return result;
}
/* Fault injection is local to the new lazy acquisition boundary. It is not
 * evidence of a real device/compiler failure; retry executes actual GPU work.
 */
static _Thread_local BOOL srt_cold_scope, srt_failure_seen;
static _Thread_local unsigned srt_failure_kind;
static BOOL (*srt_prepare_original)(id, SEL, NSError **);
static BOOL srt_prepare(id object, SEL selector, NSError **error)
{
    BOOL saved = srt_cold_scope;
    srt_cold_scope = YES;
    @try {
        return srt_prepare_original(object, selector, error);
    } @finally {
        srt_cold_scope = saved;
    }
}
static id (*srt_function_original)(id, SEL, NSString *, NSError **);
static void srt_error(NSError **error)
{
    if (error)
        *error = [NSError
            errorWithDomain:@"swizzled-rtt-test"
                       code:1
                   userInfo:@{
                       NSLocalizedDescriptionKey :
                           @"Injected new channel-capture factory failure"
                   }];
    srt_failure_seen = YES;
    srt_failure_kind = 0;
}
static id srt_function(id object, SEL selector, NSString *name, NSError **error)
{
    if (srt_cold_scope && srt_failure_kind == 1 &&
        [name isEqualToString:@"nv2a_surface_texture_downsample_channels"]) {
        srt_error(error);
        return nil;
    }
    return srt_function_original(object, selector, name, error);
}
typedef id (*SRTArgumentFactory)(id, SEL, id, NSError **)
    __attribute__((ns_returns_retained));
static SRTArgumentFactory srt_arguments_original;
static id srt_arguments(id object, SEL selector, id descriptor, NSError **error)
    __attribute__((ns_returns_retained));
static id srt_arguments(id object, SEL selector, id descriptor, NSError **error)
{
    if (srt_cold_scope && srt_failure_kind == 2) {
        srt_error(error);
        return nil;
    }
    return srt_arguments_original(object, selector, descriptor, error);
}
static void srt_failure(id<MTLDevice> device, NV2AMetalPixelShader *shader,
                        unsigned kind)
{
    srt_reference = NO;
    SwizzledRTTFixture *f =
        srt_fixture(device, 0, kind == 1 ? 0 : 3, kind == 1 ? 2 : 1);
    NSError *error = nil;
    require([f->cache beginRecordingWithError:&error], error);
    id<MTLBuffer> marker =
        [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
    require(marker && [f->queue addResource:marker error:&error], error);
    memset(marker.contents, 0xcd, 4);
    id<MTL4ComputeCommandEncoder> encoder =
        [f->queue.commandBuffer computeCommandEncoder];
    require(encoder != nil, nil);
    [encoder fillBuffer:marker range:NSMakeRange(0, 4) value:0x5a];
    [encoder endEncoding];
    id originalBuffer = f->queue.commandBuffer;
    NV2AMetalSurfaceRecording *originalToken = f->cache.recording;
    uint64_t serial = f->queue.recordingSerial, batch = f->queue.batchSerial;
    NSUInteger sealed = f->queue.sealedBufferCount;
    NV2AMetalSubmission *receipt = f->queue.lastSubmitted;
    srt_failure_kind = kind;
    srt_failure_seen = NO;
    NV2AMetalSamplerConfig sampler = policy();
    NV2AMetalCachedTexture *failed = [f->textures prepareSource:&f->source
                                                        sampler:&sampler
                                                          frame:3
                                                          error:&error];
    BOOL observedFailure = !failed && error && srt_failure_seen;
    BOOL preserved =
        f->queue.commandBuffer == originalBuffer &&
        f->cache.recording == originalToken &&
        f->queue.recordingSerial == serial && f->queue.batchSerial == batch &&
        f->queue.sealedBufferCount == sealed &&
        f->queue.lastSubmitted == receipt && !originalToken.cancelled;
    BOOL noPartial = ![f->textures valueForKey:@"downsampleChannelsCapture"] &&
                     ![f->textures valueForKey:@"downsampleChannelsArguments"];
    srt_failure_kind = 0;
    error = nil;
    NV2AMetalCachedTexture *retry = [f->textures prepareSource:&f->source
                                                       sampler:&sampler
                                                         frame:4
                                                         error:&error];
    require(retry != nil, error);
    (void)srt_observe(f, retry, shader, kind == 1 ? 0 : 3, 0, 0, YES);
    // Real marker and image bytes precede the saved recording/metadata checks.
    assert(*(const uint32_t *)marker.contents == UINT32_C(0x5a5a5a5a));
    assert(observedFailure && preserved && noPartial && !f->notifications &&
           [f->textures valueForKey:@"downsampleChannelsCapture"] &&
           [f->textures valueForKey:@"downsampleChannelsArguments"]);
    for (unsigned i = 0; i < 1024; i++)
        assert(((const uint8_t *)f->ram.contents)[4096 + i] == 0x51);
}
/* All three kernels share one cache-owned argument table. Encode all
 * captures before any readback or raster boundary can submit their recording.
 */
static void srt_shared_arguments(id<MTLDevice> device,
                                 NV2AMetalPixelShader *shader)
{
    srt_reference = NO;
    SwizzledRTTFixture *f = srt_fixture(device, 0, 0, 2);
    NSError *error = nil;
    NV2AMetalSamplerConfig sampler = policy();
    const unsigned formats[] = { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8 };
    NV2AMetalCachedTexture *textures[3] = { nil, nil, nil };
    NV2AMetalSurfaceRecording *token = nil;
    id buffer = nil;
    uint64_t serial = 0;
    BOOL sameRecording = YES;
    x8r_begin_scope();
    for (unsigned order = 0; order < 3; order++) {
        f->source.shape.format = formats[order];
        textures[order] = [f->textures prepareSource:&f->source
                                             sampler:&sampler
                                               frame:3
                                               error:&error];
        require(textures[order] != nil, error);
        if (!order) {
            token = f->cache.recording;
            buffer = f->queue.commandBuffer;
            serial = f->queue.recordingSerial;
        }
        sameRecording &=
            f->cache.recording == token && f->queue.commandBuffer == buffer &&
            f->queue.recordingSerial == serial &&
            textures[order].producerRecording == token && !token.submitted;
    }
    rck_scope = 0;
    unsigned dispatches = rck_dispatches, downloads = x8r_download_calls,
             uploads = x8r_uploads;
    id<MTLBuffer> raw[3] = { nil, nil, nil }, sampled[3] = { nil, nil, nil };
    for (unsigned order = 0; order < 3; order++) {
        raw[order] = test_metal_read_2d_texture(
            f->queue, textures[order].binding.texture, 0);
        sampled[order] = srt_sample(f, textures[order], shader);
    }
    rck_finish(f->cache);
    for (unsigned order = 0; order < 3; order++) {
        NSData *a = srt_pack(raw[order], f->config.width, f->config.height);
        NSData *b = srt_pack(sampled[order], f->config.width, f->config.height);
        const float *read = a.bytes, *sample = b.bytes;
        for (unsigned i = 0; i < 256; i++) {
            unsigned expected[4];
            srt_expected(order, i, 0, expected);
            for (unsigned k = 0; k < 4; k++) {
                if (fabsf(read[i * 4 + k] - expected[k] / 255.f) > .000001f ||
                    fabsf(sample[i * 4 + k] - expected[k] / 255.f) > .000001f) {
                    fprintf(stderr,
                            "Swizzled RTT shared-arguments GPU bytes order%u "
                            "pixel%u lane%u\n",
                            order, i, k);
                    abort();
                }
            }
        }
        require([textures[order] validateCompletedWithError:&error], error);
    }
    assert(sameRecording && dispatches == 3 && !downloads && !uploads &&
           !f->notifications);
    assert(textures[0].binding.texture != textures[1].binding.texture &&
           textures[0].binding.texture != textures[2].binding.texture &&
           textures[1].binding.texture != textures[2].binding.texture);
}
static void swizzled_rtt_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(shader && probe && [probe beginWithError:&error], error);
    id encoder = [probe.commandBuffer computeCommandEncoder];
    require(encoder != nil, nil);
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalTextureCache.class,
            @selector(canCaptureSwizzledChannelsSurface:format:)),
        class_getInstanceMethod(
            [encoder class],
            @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:
                      sourceSize:toTexture:destinationSlice:destinationLevel:
                      destinationOrigin:)),
        class_getInstanceMethod(
            [encoder class], @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(
            [encoder class],
            @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:
                      sourceBytesPerImage:sourceSize:toTexture:destinationSlice:
                      destinationLevel:destinationOrigin:)),
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(encodeDownloadToBuffer:offset:swizzle:
                                          flip:downscale:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalTextureCache.class,
            @selector(prepareDownsampleChannelsCaptureWithError:)),
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(
            [device class], @selector(newArgumentTableWithDescriptor:error:))
    };
    IMP originals[8];
    for (unsigned i = 0; i < 8; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    srt_admission_original = (void *)originals[0];
    rck_copy_original = (void *)originals[1];
    rck_dispatch_original = (void *)originals[2];
    x8r_upload_original = (void *)originals[3];
    x8r_transfer_download_original = (void *)originals[4];
    srt_prepare_original = (void *)originals[5];
    srt_function_original = (void *)originals[6];
    srt_arguments_original = (void *)originals[7];
    [encoder endEncoding];
    [probe cancel];
    IMP replacements[] = { (IMP)srt_admission,         (IMP)rck_copy,
                           (IMP)rck_dispatch,          (IMP)x8r_upload,
                           (IMP)x8r_transfer_download, (IMP)srt_prepare,
                           (IMP)srt_function,          (IMP)srt_arguments };
    for (unsigned i = 0; i < 8; i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned family = 0; family < 3; family++)
            for (unsigned order = 0; order < 4; order++)
                for (unsigned scale = 1; scale <= 4; scale *= 2)
                    @autoreleasepool {
                        BOOL lifecycle =
                            !family &&
                            (scale == 2 || (order == 0 && scale != 2));
                        NSData *reference =
                            srt_pair(device, shader, family, order, scale, YES,
                                     lifecycle);
                        NSData *actual = srt_pair(device, shader, family, order,
                                                  scale, NO, lifecycle);
                        if (![reference isEqualToData:actual]) {
                            fprintf(stderr,
                                    "Swizzled RTT GPU bytes family%u order%u "
                                    "scale%u\n",
                                    family, order, scale);
                            abort();
                        }
                        pairs++;
                    }
        for (unsigned kind = 0; kind < 4; kind++)
            @autoreleasepool {
                NSData *old = srt_guard(device, shader, kind, YES),
                       *actual = srt_guard(device, shader, kind, NO);
                NSUInteger tail = 3 * sizeof(unsigned);
                assert(old.length == actual.length && actual.length > tail);
                NSUInteger payload = actual.length - tail;
                if (memcmp(old.bytes, actual.bytes, payload)) {
                    fprintf(stderr, "Swizzled RTT guard GPU bytes kind%u\n",
                            kind);
                    abort();
                }
                unsigned routes[2][3];
                memcpy(routes[0], (const uint8_t *)old.bytes + payload, tail);
                memcpy(routes[1], (const uint8_t *)actual.bytes + payload,
                       tail);
                for (unsigned n = 0; n < 2; n++)
                    assert(routes[n][0] == 1 && routes[n][1] == 1 &&
                           !routes[n][2]);
            }
        srt_failure(device, shader, 1);
        srt_failure(device, shader, 2);
        srt_shared_arguments(device, shader);
    } @finally {
        srt_reference = NO;
        rck_scope = 0;
        srt_failure_kind = 0;
        srt_cold_scope = NO;
        for (unsigned i = 0; i < 8; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    assert(pairs == 36);
    puts("Swizzled RTT:36 native/old-RAM GPU read+pixel-sample "
         "pairs,all256RGBA,A8/A7Z/O,"
         "SZ-ABGR/RGBA/BGRA+LU-BGRA,scale1/2/4 rectangular/offgrid,"
         "immutable/cancel/retry/alias/snapshot/Restore,4 valid fallback "
         "pairs,2 cold factory-failure retries PASS");
}
#endif
