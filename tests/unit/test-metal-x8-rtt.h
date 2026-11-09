/* A8/A7 RGB bytes can be captured as opaque X8 without guest-memory decode.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_X8_RTT_H
#define TEST_METAL_X8_RTT_H
#include "hw/xbox/nv2a/pgraph/metal/texture-storage.h"

@interface NV2AMetalTextureUpload (X8RTTLegacyStorage)
- (unsigned)storageForShape:(const NV2AMetalTextureShape *)shape;
@end
@interface NV2AMetalTextureCache (X8RTTDownsampleAdmission)
- (BOOL)canCaptureDownsampledOpaqueSurface:(NV2AMetalCachedSurface *)surface
                                    format:(unsigned)format;
@end
static _Thread_local BOOL x8r_reference, x8r_legacy_storage;
static BOOL (*x8r_admission_original)(id, SEL, NV2AMetalCachedSurface *,
                                      unsigned);
static BOOL x8r_admission(id object, SEL selector,
                          NV2AMetalCachedSurface *surface, unsigned format)
{
    return !x8r_reference &&
           x8r_admission_original(object, selector, surface, format);
}
/* Count actual buffer/texture transports only inside prepareSource, excluding
 * fixture upload, independent readbacks, and subsequent lifecycle operations.
 */
static _Thread_local unsigned x8r_uploads, x8r_downloads, x8r_download_calls;
static BOOL (*x8r_transfer_download_original)(id, SEL, id<MTLBuffer>,
                                              NSUInteger, BOOL, BOOL, BOOL,
                                              NV2AMetalCommands *, NSError **);
static BOOL x8r_transfer_download(id object, SEL selector, id<MTLBuffer> target,
                                  NSUInteger offset, BOOL swizzle, BOOL flip,
                                  BOOL downscale, NV2AMetalCommands *commands,
                                  NSError **error)
{
    if (rck_scope)
        x8r_download_calls++;
    return x8r_transfer_download_original(object, selector, target, offset,
                                          swizzle, flip, downscale, commands,
                                          error);
}
static void (*x8r_upload_original)(id, SEL, id, NSUInteger, NSUInteger,
                                   NSUInteger, MTLSize, id, NSUInteger,
                                   NSUInteger, MTLOrigin);
static void x8r_upload(id object, SEL selector, id source, NSUInteger offset,
                       NSUInteger pitch, NSUInteger imagePitch, MTLSize size,
                       id target, NSUInteger slice, NSUInteger level,
                       MTLOrigin origin)
{
    if (rck_scope)
        x8r_uploads++;
    x8r_upload_original(object, selector, source, offset, pitch, imagePitch,
                        size, target, slice, level, origin);
}
static void (*x8r_download_original)(id, SEL, id, NSUInteger, NSUInteger,
                                     MTLOrigin, MTLSize, id, NSUInteger,
                                     NSUInteger, NSUInteger, MTLBlitOption);
static void x8r_download(id object, SEL selector, id source, NSUInteger slice,
                         NSUInteger level, MTLOrigin origin, MTLSize size,
                         id target, NSUInteger offset, NSUInteger pitch,
                         NSUInteger imagePitch, MTLBlitOption options)
{
    if (rck_scope)
        x8r_downloads++;
    x8r_download_original(object, selector, source, slice, level, origin, size,
                          target, offset, pitch, imagePitch, options);
}
static void x8r_begin_scope(void)
{
    x8r_uploads = x8r_downloads = x8r_download_calls = 0;
    rck_begin_scope(1);
}
static unsigned (*x8r_storage_original)(id, SEL, const NV2AMetalTextureShape *);
static unsigned x8r_storage(id object, SEL selector,
                            const NV2AMetalTextureShape *shape)
{
    unsigned storage = x8r_storage_original(object, selector, shape);
    return x8r_legacy_storage && (storage == NV2AMetalTextureStorageBGRA8 ||
                                  storage == NV2AMetalTextureStorageBGRX8) ?
               NV2AMetalTextureStorageUnorm8 :
               storage;
}

@interface X8RTTCache : NV2AMetalSurfaceCache
@property(nonatomic) BOOL legacyDecode;
@end
@implementation X8RTTCache
- (BOOL)sourceVersionsForReadSpans:(const NV2AMetalVRAMReadSpan *)spans
                             count:(NSUInteger)count
                          versions:(uint64_t *)versions
                      firstSurface:(NV2AMetalCachedSurface **)surface
                             error:(NSError **)error
{
    BOOL ok = [super sourceVersionsForReadSpans:spans
                                          count:count
                                       versions:versions
                                   firstSurface:surface
                                          error:error];
    /* Preserve all source validation/versioning and force the genuine old
     * prepareGPURead -> surface download -> texture decode route. */
    if (ok && _legacyDecode && surface)
        *surface = nil;
    return ok;
}
@end

static void x8r_image(NV2AMetalSurfaceCache *cache,
                      NV2AMetalCachedSurface *surface, unsigned phase)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig config = surface.transfer.config;
    surface = [cache prepareSurfaceAtAddress:surface.address
                                      config:&config
                                       frame:phase + 2
                                forRendering:YES
                                       error:&error];
    require(surface != nil, error);
    NV2AMetalCommands *q = cache.commands;
    id<MTLTexture> native = [surface.transfer textureForCommands:q
                                                           error:&error];
    require(native != nil, error);
    NSUInteger pitch = ((native.width * 4 + 255) / 256) * 256;
    id<MTLBuffer> bytes =
        [q.device newBufferWithLength:pitch * native.height
                              options:MTLResourceStorageModeShared];
    require(bytes != nil, nil);
    memset(bytes.contents, 0x91, bytes.length);
    for (NSUInteger y = 0; y < native.height; y++)
        for (NSUInteger x = 0; x < native.width; x++) {
            /* Every scale exposes all 256 logical codes; intermediate native
             * pixels are poison, so a filtered or shifted sample cannot pass.
             */
            unsigned i =
                ((y / config.scale) * 16 + x / config.scale + phase * 43) & 255;
            BOOL lattice = !(x % config.scale) && !(y % config.scale);
            uint8_t *p = (uint8_t *)bytes.contents + y * pitch + x * 4;
            p[0] = i * 29 + 7;
            p[1] = i * 37 + 11;
            p[2] = i;
            p[3] = i * 53 + 17;
            if (!lattice) {
                p[0] ^= 0xd3;
                p[1] ^= 0x6b;
                p[2] ^= 0xa7;
                p[3] ^= 0xf1;
            }
        }
    require([q addResource:bytes error:&error] && [q addResource:native
                                                           error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:bytes
               sourceOffset:0
          sourceBytesPerRow:pitch
        sourceBytesPerImage:bytes.length
                 sourceSize:MTLSizeMake(native.width, native.height, 1)
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
    rck_finish(cache);
}

static NSData *x8r_read(NV2AMetalSurfaceCache *cache,
                        NV2AMetalCachedTexture *texture, unsigned scale,
                        unsigned phase)
{
    id<MTLBuffer> pixels =
        test_metal_read_texture(cache.commands, texture.binding.texture, 0, 0);
    rck_finish(cache);
    assert(scale >= 1);
    const float *rgba = pixels.contents;
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            unsigned i = (y * 16 + x + phase * 43) & 255;
            const unsigned expected[] = { i, (i * 37 + 11) & 255,
                                          (i * 29 + 7) & 255, 255 };
            for (unsigned k = 0; k < 4; k++)
                assert(fabsf(rgba[(y * 16 + x) * 4 + k] - expected[k] / 255.f) <
                       .000001f);
        }
    return [NSData dataWithBytes:pixels.contents length:16 * 16 * 16];
}

static NSData *x8r_pair(id<MTLDevice> device, unsigned family, BOOL swizzled,
                        unsigned scale, BOOL reference, BOOL lifecycle)
{
    x8r_reference = reference;
    x8r_legacy_storage = reference && scale == 1;
    NSError *error = nil;
    NV2AMetalCommands *q = [[NV2AMetalCommands alloc] initWithDevice:device
                                                               error:&error];
    require(q != nil, error);
    id<MTLBuffer> ram =
        [device newBufferWithLength:16384 options:MTLResourceStorageModeShared];
    require(ram != nil, nil);
    memset(ram.contents, 0x51, ram.length);
    __block unsigned callbacks = 0;
    X8RTTCache *cache = [[X8RTTCache alloc]
        initWithCommands:q
                    vram:ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address == 4096 && length == 1024);
              callbacks++;
            }
                   error:&error];
    require(cache != nil, error);
    cache.legacyDecode = reference && scale == 1;
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8,
    };
    NV2AMetalSurfaceConfig config = { .format = formats[family],
                                      .width = 16,
                                      .height = 16,
                                      .pitch = 64,
                                      .scale = scale,
                                      .color = YES,
                                      .swizzle = swizzled };
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:4096
                                                              config:&config
                                                               frame:1
                                                               error:&error];
    require(surface != nil, error);
    rck_finish(cache);
    x8r_image(cache, surface, 0);
    assert(!memcmp((uint8_t *)ram.contents + 4096,
                   (uint8_t[4]){ 0x51, 0x51, 0x51, 0x51 }, 4));
    NV2AMetalTextureCache *tc =
        [[NV2AMetalTextureCache alloc] initWithSurfaces:cache error:&error];
    require(tc != nil, error);
    NV2AMetalTextureSource src = {
        .shape = { .format =
                       swizzled ?
                           NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8 :
                           NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8,
                   .dimension = 2,
                   .width = 16,
                   .height = 16,
                   .depth = 1,
                   .levels = 1,
                   .pitch = 64 },
        .address = 4096,
        .length = 1024,
    };
    NV2AMetalSamplerConfig sampler = policy();
    x8r_begin_scope();
    NV2AMetalCachedTexture *old = [tc prepareSource:&src
                                            sampler:&sampler
                                              frame:3
                                              error:&error];
    rck_scope = 0;
    unsigned copies = rck_copies, dispatches = rck_dispatches;
    unsigned uploads = x8r_uploads, downloads = x8r_downloads;
    unsigned downloadCalls = x8r_download_calls;
    require(old != nil, error);
    if (lifecycle && !reference) {
        [cache cancel];
        assert(![old validateCompletedWithError:&error]);
        error = nil;
        old = [tc prepareSource:&src sampler:&sampler frame:3 error:&error];
        require(old != nil, error);
    }
    NSData *first = x8r_read(cache, old, scale, 0);
    require([old validateCompletedWithError:&error], error);
    // Independent GPU scalar bytes above precede transport instrumentation.
    BOOL direct = !reference && scale == 1;
    BOOL fused = !reference && scale > 1;
    assert(old.scale == 1 && old.binding.texture.width == 16 &&
           old.binding.texture.height == 16);
    if (reference) {
        assert(dispatches && callbacks == 1 && downloadCalls == 1);
    } else {
        assert(
            !callbacks && !uploads && !downloads && !downloadCalls &&
            (direct ? copies == 1 && !dispatches : !copies && dispatches == 1));
        MTLTextureSwizzleChannels channels = old.binding.texture.swizzle;
        assert(old.binding.texture.pixelFormat == MTLPixelFormatBGRA8Unorm &&
               channels.alpha ==
                   (fused ? MTLTextureSwizzleAlpha : MTLTextureSwizzleOne) &&
               ![tc valueForKey:@"capture"] && ![tc valueForKey:@"arguments"]);
        assert(!![tc valueForKey:@"downsampleCapture"] == fused &&
               !![tc valueForKey:@"downsampleArguments"] == fused);
        for (unsigned i = 0; i < 1024; i++)
            assert(((uint8_t *)ram.contents)[4096 + i] == 0x51);
    }
    NSMutableData *result = [NSMutableData dataWithData:first];
    if (lifecycle) {
        x8r_image(cache, surface, 1);
        require([cache beginRecordingWithError:&error], error);
        id<MTLBuffer> inFlightOld =
            test_metal_read_texture(q, old.binding.texture, 0, 0);
        NV2AMetalCachedTexture *fresh = [tc prepareSource:&src
                                                  sampler:&sampler
                                                    frame:4
                                                    error:&error];
        require(fresh != nil, error);
        NSData *second = x8r_read(cache, fresh, scale, 1);
        require([fresh validateCompletedWithError:&error], error);
        assert(!memcmp(first.bytes, inFlightOld.contents, first.length));
        [result appendData:second];
        // Announce a real source-alias store, then upload/capture its new
        // bytes. No successful write callback is used as a side-effect-free
        // predicate.
        require([cache resolveCPUAccessAtAddress:4096
                                          length:1024
                                           write:YES
                                           error:&error],
                error);
        uint32_t *guest = (uint32_t *)((uint8_t *)ram.contents + 4096);
        for (unsigned i = 0; i < 256; i++)
            guest[i] = 0xff0000ff;
        NV2AMetalCachedTexture *alias = [tc prepareSource:&src
                                                  sampler:&sampler
                                                    frame:5
                                                    error:&error];
        require(alias != nil, error);
        id<MTLBuffer> aliasBytes =
            test_metal_read_texture(q, alias.binding.texture, 0, 0);
        id<MTLBuffer> unchanged =
            test_metal_read_texture(q, fresh.binding.texture, 0, 0);
        rck_finish(cache);
        const float *aliasRGBA = aliasBytes.contents;
        for (unsigned i = 0; i < 256; i++)
            for (unsigned k = 0; k < 4; k++)
                assert(aliasRGBA[i * 4 + k] == (k >= 2 ? 1.f : 0.f));
        assert(!memcmp(second.bytes, unchanged.contents, second.length));
        [result appendBytes:aliasBytes.contents length:first.length];
        NV2AMetalCommands *snapshotCommands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        require(snapshotCommands != nil, error);
        NSData *snapshot = nv2a_metal_texture_snapshot(
            old.binding.texture, snapshotCommands, &error);
        require(snapshot != nil, error);
        require([cache discardForRestoreWithError:&error], error);
        id<MTLTexture> restored =
            nv2a_metal_texture_restore(snapshot, snapshotCommands, &error);
        require(restored != nil, error);
        require([snapshotCommands beginWithError:&error] != nil, error);
        id<MTLBuffer> bytes =
            test_metal_read_texture(snapshotCommands, restored, 0, 0);
        require([snapshotCommands submitWithError:&error] &&
                    [snapshotCommands waitUntilIdleWithError:&error],
                error);
        assert(!memcmp(first.bytes, bytes.contents, first.length));
    }
    return result;
}

/* Valid legacy inputs that fail one of the complete RTT layout contracts.
 * Admission(surface,format) alone intentionally cannot inspect shape guards. */
static NSData *x8r_guard_pair(id<MTLDevice> device, unsigned kind,
                              BOOL reference)
{
    x8r_reference = reference;
    x8r_legacy_storage = NO;
    NSError *error = nil;
    NV2AMetalCommands *q = [[NV2AMetalCommands alloc] initWithDevice:device
                                                               error:&error];
    require(q != nil, error);
    id<MTLBuffer> ram =
        [device newBufferWithLength:16384 options:MTLResourceStorageModeShared];
    require(ram != nil, nil);
    memset(ram.contents, 0x51, ram.length);
    __block unsigned callbacks = 0;
    X8RTTCache *cache = [[X8RTTCache alloc]
        initWithCommands:q
                    vram:ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address == 4096 && length == 1024);
              callbacks++;
            }
                   error:&error];
    require(cache != nil, error);
    NV2AMetalSurfaceConfig config = {
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 16,
        .height = 16,
        .pitch = 64,
        .scale = 2,
        .color = YES,
        .swizzle = kind == 3
    };
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:4096
                                                              config:&config
                                                               frame:1
                                                               error:&error];
    require(surface != nil, error);
    rck_finish(cache);
    x8r_image(cache, surface, 0);
    NV2AMetalTextureCache *tc =
        [[NV2AMetalTextureCache alloc] initWithSurfaces:cache error:&error];
    require(tc != nil, error);
    NV2AMetalTextureSource src = {
        .shape = { .format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8,
                   .dimension = 2,
                   .width = 16,
                   .height = 16,
                   .depth = 1,
                   .levels = 1,
                   .pitch = 64 },
        .address = 4096
    };
    switch (kind) {
    case 0: // Linear surface reinterpreted as Morton texture.
        src.shape.format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8;
        break;
    case 1:
        src.shape.pitch = 68;
        break;
    case 2:
        src.shape.width = 8;
        break;
    case 3:
        src.shape.format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8;
        src.shape.levels = 2;
        src.shape.max_level = 1;
        break;
    case 4:
        src.shape.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5;
        src.shape.pitch = 32;
        break;
    case 5:
        // Signed A8 is a valid old decoder input; signed X8 is not admitted
        // by the existing texture layout API and is not fabricated here.
        src.shape.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8;
        src.shape.signed_channels = 1;
        break;
    default:
        abort();
    }
    require([tc sourceLengthForShape:&src.shape
                       paletteLength:0
                              length:&src.length
                               error:&error],
            error);
    NV2AMetalSamplerConfig sampler = policy();
    x8r_begin_scope();
    NV2AMetalCachedTexture *texture = [tc prepareSource:&src
                                                sampler:&sampler
                                                  frame:3
                                                  error:&error];
    rck_scope = 0;
    require(texture != nil, error);
    id<MTLBuffer> pixels =
        test_metal_read_texture(q, texture.binding.texture, 0, 0);
    rck_finish(cache);
    require([texture validateCompletedWithError:&error], error);
    NSUInteger rowBytes = texture.binding.texture.width * 16;
    NSUInteger rowPitch = (rowBytes + 255) & ~(NSUInteger)255;
    NSMutableData *result = [NSMutableData data];
    for (NSUInteger y = 0; y < texture.binding.texture.height; y++)
        [result appendBytes:(const uint8_t *)pixels.contents + y * rowPitch
                     length:rowBytes];
    // The driver compares actual GPU bytes before checking route counters.
    // Save observations alongside the image, without asserting admission here.
    const unsigned route[] = { callbacks, rck_dispatches, x8r_download_calls,
                               !![tc valueForKey:@"downsampleCapture"],
                               !![tc valueForKey:@"downsampleArguments"] };
    NSMutableData *record = [NSMutableData dataWithData:result];
    [record appendBytes:route length:sizeof(route)];
    return record;
}

static void x8_rtt_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(probe && [probe beginWithError:&error], error);
    id encoder = [probe.commandBuffer computeCommandEncoder];
    require(encoder != nil, nil);
    Method copy = class_getInstanceMethod(
        [encoder class],
        @selector(
            copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:
            toTexture:destinationSlice:destinationLevel:destinationOrigin:));
    Method dispatch = class_getInstanceMethod(
        [encoder class], @selector(dispatchThreads:threadsPerThreadgroup:));
    Method storage = class_getInstanceMethod(NV2AMetalTextureUpload.class,
                                             @selector(storageForShape:));
    Method admission = class_getInstanceMethod(
        NV2AMetalTextureCache.class,
        @selector(canCaptureDownsampledOpaqueSurface:format:));
    Method upload = class_getInstanceMethod(
        [encoder class],
        @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:
                  sourceBytesPerImage:sourceSize:toTexture:destinationSlice:
                  destinationLevel:destinationOrigin:));
    Method download = class_getInstanceMethod(
        [encoder class],
        @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:
                  sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:
                  destinationBytesPerImage:options:));
    Method transferDownload =
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(encodeDownloadToBuffer:offset:swizzle:
                                          flip:downscale:commands:error:));
    assert(copy && dispatch && storage && admission && upload && download &&
           transferDownload);
    x8r_transfer_download_original =
        (void *)method_getImplementation(transferDownload);
    x8r_admission_original = (void *)method_getImplementation(admission);
    x8r_upload_original = (void *)method_getImplementation(upload);
    x8r_download_original = (void *)method_getImplementation(download);
    rck_copy_original = (void *)method_getImplementation(copy);
    rck_dispatch_original = (void *)method_getImplementation(dispatch);
    x8r_storage_original = (void *)method_getImplementation(storage);
    [encoder endEncoding];
    [probe cancel];
    method_setImplementation(copy, (IMP)rck_copy);
    method_setImplementation(dispatch, (IMP)rck_dispatch);
    method_setImplementation(storage, (IMP)x8r_storage);
    method_setImplementation(admission, (IMP)x8r_admission);
    method_setImplementation(upload, (IMP)x8r_upload);
    method_setImplementation(download, (IMP)x8r_download);
    method_setImplementation(transferDownload, (IMP)x8r_transfer_download);
    unsigned pairs = 0;
    @try {
        for (unsigned family = 0; family < 3; family++)
            for (unsigned layout = 0; layout < 2; layout++)
                for (unsigned scale = 1; scale <= 4; scale *= 2) {
                    @autoreleasepool {
                        BOOL lifecycle = scale > 1 || !layout;
                        NSData *reference = x8r_pair(device, family, layout,
                                                     scale, YES, lifecycle);
                        NSData *actual = x8r_pair(device, family, layout, scale,
                                                  NO, lifecycle);
                        if (![reference isEqualToData:actual]) {
                            fprintf(stderr,
                                    "X8 RTT GPU bytes differ family%u layout%u "
                                    "scale%u\n",
                                    family, layout, scale);
                            abort();
                        }
                        pairs++;
                    }
                }
        for (unsigned kind = 0; kind < 6; kind++) {
            @autoreleasepool {
                NSData *reference = x8r_guard_pair(device, kind, YES);
                NSData *actual = x8r_guard_pair(device, kind, NO);
                const NSUInteger tail = 5 * sizeof(unsigned);
                assert(reference.length == actual.length &&
                       actual.length > tail);
                NSUInteger imageLength = actual.length - tail;
                if (memcmp(reference.bytes, actual.bytes, imageLength)) {
                    fprintf(stderr, "X8 RTT guard GPU bytes differ kind%u\n",
                            kind);
                    abort();
                }
                unsigned routes[2][5];
                memcpy(routes[0],
                       (const uint8_t *)reference.bytes + imageLength, tail);
                memcpy(routes[1], (const uint8_t *)actual.bytes + imageLength,
                       tail);
                for (unsigned i = 0; i < 2; i++)
                    assert(routes[i][0] == 1 && routes[i][1] &&
                           routes[i][2] == 1 && !routes[i][3] && !routes[i][4]);
            }
        }
    } @finally {
        x8r_reference = x8r_legacy_storage = NO;
        rck_scope = 0;
        method_setImplementation(copy, (IMP)rck_copy_original);
        method_setImplementation(dispatch, (IMP)rck_dispatch_original);
        method_setImplementation(storage, (IMP)x8r_storage_original);
        method_setImplementation(admission, (IMP)x8r_admission_original);
        method_setImplementation(upload, (IMP)x8r_upload_original);
        method_setImplementation(download, (IMP)x8r_download_original);
        method_setImplementation(transferDownload,
                                 (IMP)x8r_transfer_download_original);
    }
    assert(pairs == 18);
    printf("X8 RTT:18 GPU/legacy-download-decode pairs,all channel "
           "codes,A8/A7,LU/SZ,scale1 direct/2/4 fused,offgrid poison,immutable "
           "old/cancel/retry/alias/snapshot/Restore,6 legacy-layout guards "
           "PASS\n");
}
#endif
