/* Fixed Z16 cache coherence through native raster and direct buffer copies.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DIRECT_Z16_CACHE_H
#define TEST_METAL_DIRECT_Z16_CACHE_H
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
#include "hw/xbox/nv2a/pgraph/metal/surface-transfer-types.h"

@interface NV2AMetalSurfaceTransfer (DirectZ16CacheReference)
- (BOOL)canCopyBufferAtOffset:(NSUInteger)offset
                     uniforms:(NV2AMetalSurfaceTransferUniforms)uniforms
                       upload:(BOOL)upload;
- (BOOL)prepareComputeForUpload:(BOOL)upload error:(NSError **)error;
@end
@interface DirectZ16CacheReference : NV2AMetalSurfaceTransfer
@end
@implementation DirectZ16CacheReference
- (BOOL)canCopyBufferAtOffset:(NSUInteger)offset
                     uniforms:(NV2AMetalSurfaceTransferUniforms)uniforms
                       upload:(BOOL)upload
{
    (void)offset;
    (void)uniforms;
    (void)upload;
    return NO;
}
@end
@interface DirectZ16CacheCommands : NV2AMetalCommands
@property(nonatomic) id<MTLSharedEvent> releaseOnWait;
@property(nonatomic) unsigned waits;
@end
@implementation DirectZ16CacheCommands
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    _waits++;
    if (_releaseOnWait) {
        _releaseOnWait.signaledValue = 1;
        _releaseOnWait = nil;
    }
    return [super waitForSubmission:submission error:error];
}
@end
static BOOL dz16_observe;
static NSHashTable<id<MTLBuffer>> *dz16_directBuffers;
static unsigned dz16_uploads, dz16_downloads, dz16_computes;
static BOOL (*dz16_compute)(id, SEL, BOOL, NSError **);
static BOOL dz16_compute_spy(NV2AMetalSurfaceTransfer *owner, SEL selector,
                             BOOL upload, NSError **error)
{
    NV2AMetalSurfaceConfig c = owner.config;
    if (dz16_observe && !c.color && !c.floating_depth &&
        c.format == NV097_SET_SURFACE_FORMAT_ZETA_Z16)
        dz16_computes++;
    return dz16_compute(owner, selector, upload, error);
}
static void (*dz16_upload)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger,
                           MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
static void dz16_upload_spy(id owner, SEL selector, id buffer,
                            NSUInteger offset, NSUInteger row, NSUInteger image,
                            MTLSize size, id<MTLTexture> texture,
                            NSUInteger slice, NSUInteger level,
                            MTLOrigin origin)
{
    if (dz16_observe && texture.pixelFormat == MTLPixelFormatDepth16Unorm &&
        [dz16_directBuffers containsObject:buffer])
        dz16_uploads++;
    dz16_upload(owner, selector, buffer, offset, row, image, size, texture,
                slice, level, origin);
}
static void (*dz16_download)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin,
                             MTLSize, id, NSUInteger, NSUInteger, NSUInteger,
                             MTLBlitOption);
static void dz16_download_spy(id owner, SEL selector, id<MTLTexture> texture,
                              NSUInteger slice, NSUInteger level,
                              MTLOrigin origin, MTLSize size, id buffer,
                              NSUInteger offset, NSUInteger row,
                              NSUInteger image, MTLBlitOption options)
{
    if (dz16_observe && texture.pixelFormat == MTLPixelFormatDepth16Unorm &&
        [dz16_directBuffers containsObject:buffer])
        dz16_downloads++;
    dz16_download(owner, selector, texture, slice, level, origin, size, buffer,
                  offset, row, image, options);
}
static NV2AMetalCachedSurface *dz16_prepare(NV2AMetalSurfaceCache *cache,
                                            NSUInteger address,
                                            NV2AMetalSurfaceConfig c,
                                            BOOL reference)
{
    NSError *error = nil;
    NV2AMetalCachedSurface *s = [cache selectSurfaceAtAddress:address
                                                       config:&c
                                                        frame:0
                                                        error:&error];
    require(s != nil, error);
    if (reference) {
        // The empty subclass changes only the existing transfer predicate,
        // before this selected surface encodes its first upload. No texture
        // or SurfaceCache state is replaced.
        assert(class_getInstanceSize(DirectZ16CacheReference.class) ==
               class_getInstanceSize(NV2AMetalSurfaceTransfer.class));
        object_setClass(s.transfer, DirectZ16CacheReference.class);
    }
    require([cache prepareSelectedSurface:s discardingContents:NO error:&error],
            error);
    return s;
}
static uint64_t dz16_draw(NV2AMetalSurfaceCache *cache,
                          NV2AMetalCachedSurface *color,
                          NV2AMetalCachedSurface *depth, float z, unsigned rgb,
                          BOOL clear)
{
    NSError *error = nil;
    NV2AMetalCommands *commands = cache.commands;
    require([cache beginRasterProducersWithError:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color.transfer.texture;
    pass.colorAttachments[0].loadAction =
        clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.depthAttachment.texture = depth.transfer.texture;
    pass.depthAttachment.loadAction =
        clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    uint64_t zero = 0;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&zero
                                     length:8
                                    options:MTLResourceStorageModeShared];
    require(query && [commands addResource:query error:&error], error);
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    require([cache prepareRasterPass:pass
                             targets:@[ color, depth ]
                               error:&error],
            error);
    NV2AMetalPixelShader *pixel = [[NV2AMetalPixelShader alloc]
        initWithDevice:commands.device
           colorFormat:color.transfer.texture.pixelFormat
           depthFormat:depth.transfer.texture.pixelFormat
           sampleCount:1
                 error:&error];
    require(pixel != nil, error);
    unsigned scale = color.transfer.config.scale;
    NV2AMetalVertex point = { 0 };
    point.screen[0] = 2 * scale;
    point.screen[1] = 2 * scale;
    point.screen[2] = z;
    point.screen[3] = 1;
    point.clip[0] = point.screen[0] / color.transfer.texture.width * 2 - 1;
    point.clip[1] = 1 - point.screen[1] / color.transfer.texture.height * 2;
    point.clip[2] = .5f;
    point.clip[3] = 1;
    point.point_size = scale;
    point.color[0][0] = !!(rgb & 4);
    point.color[0][1] = !!(rgb & 2);
    point.color[0][2] = !!(rgb & 1);
    point.color[0][3] = 1;
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:&point
                                     length:sizeof(point)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = 1;
    u.depth_format = NV2AMetalPixelDepthD16;
    u.surface_scale[0] = u.surface_scale[1] = scale;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = 8;
    u.clip_regions[0][3] = 4;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
    }
    NV2AMetalDrawConfig dc = { 0 };
    dc.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ZENABLE |
                    NV_PGRAPH_CONTROL_0_ZWRITEENABLE;
    dc.control[0] |= NV_PGRAPH_CONTROL_0_ZFUNC_LEQUAL << 16;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    require(state != nil, error);
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    require(geometry != nil, error);
    NV2AMetalGeometryRasterConfig raster = {
        .front = NV2AMetalPolygonFill,
        .back = NV2AMetalPolygonFill,
        .lineWidth = 1,
        .viewportWidth = color.transfer.texture.width,
        .viewportHeight = color.transfer.texture.height
    };
    NSArray *geometries =
        [geometry encodeNativeRasterVertices:vertices
                                       count:1
                                   primitive:NV2AMetalPrimitivePoints
                                      config:&raster
                                      smooth:YES
                              firstProvoking:NO
                                zPerspective:NO
                                    commands:commands
                                       error:&error];
    require(geometries.count == 1, error);
    NV2AMetalPixelDraw *prepared =
        [pixel prepareGeometry:geometries[0]
                          offset:0
                           count:1
                        uniforms:&u
                        textures:textures
                            pass:pass
                       drawState:state
                     rasterClass:NV2AMetalPixelRasterDirectPoint
            ignorePolygonCulling:NO
                        commands:commands
                           error:&error];
    require(prepared != nil, error);
    id<MTL4RenderCommandEncoder> e = [commands beginRasterPass:pass
                                                         error:&error];
    require(e != nil, error);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    require([prepared encodeWithRenderEncoder:e commands:commands error:&error],
            error);
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    [cache endRasterProducers];
    require([cache markWritten:color error:&error] &&
                [cache markWritten:depth error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    return *(const uint64_t *)query.contents;
}
static void dz16_clear(NV2AMetalSurfaceCache *cache,
                       NV2AMetalCachedSurface *color,
                       NV2AMetalCachedSurface *depth, float z, unsigned rgb)
{
    NSError *error = nil;
    require([cache prepareSelectedSurface:color
                       discardingContents:NO
                                    error:&error] &&
                [cache prepareSelectedSurface:depth
                           discardingContents:NO
                                        error:&error],
            error);
    NV2AMetalClear *clear =
        [[NV2AMetalClear alloc] initWithDevice:cache.commands.device
                                         error:&error];
    require(clear != nil, error);
    NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR |
                                            NV097_CLEAR_SURFACE_Z,
                               .rect = { 0, 0, color.transfer.texture.width,
                                         color.transfer.texture.height } };
    c.uniforms.color[0] = !!(rgb & 4);
    c.uniforms.color[1] = !!(rgb & 2);
    c.uniforms.color[2] = !!(rgb & 1);
    c.uniforms.color[3] = 1;
    c.uniforms.depth = z;
    require([clear encodeColor:color.transfer.texture
                          zeta:depth.transfer.texture
                        config:&c
                      commands:cache.commands
                         error:&error] &&
                [cache markWritten:color error:&error] &&
                [cache markWritten:depth error:&error],
            error);
}
static id<MTLBuffer> dz16_readback(NV2AMetalSurfaceCache *cache,
                                   NV2AMetalCachedSurface *surface)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = surface.transfer.config;
    id<MTLBuffer> buffer = [cache.commands.device
        newBufferWithLength:c.pitch * c.height
                    options:MTLResourceStorageModeShared];
    require(buffer != nil, error);
    [dz16_directBuffers addObject:buffer];
    memset(buffer.contents, 0xcd, buffer.length);
    require([surface.transfer encodeDownloadToBuffer:buffer
                                              offset:0
                                             swizzle:YES
                                                flip:NO
                                           downscale:YES
                                            commands:cache.commands
                                               error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    return buffer;
}
static void dz16_capture(NV2AMetalSurfaceCache *cache, NSMutableData *result)
{
    NSError *error = nil;
    require([cache prepareCPUAccessAtAddress:0
                                      length:cache.vram.length
                                       write:NO
                                       error:&error],
            error);
    [result appendBytes:cache.vram.contents length:cache.vram.length];
}
static NSData *dz16_run(id<MTLDevice> device, unsigned scenario, BOOL reference)
{
    NSError *error = nil;
    DirectZ16CacheCommands *commands =
        [[DirectZ16CacheCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:32768 options:MTLResourceStorageModeShared];
    require(commands && ram, error);
    memset(ram.contents, 0xa7, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    unsigned scale = scenario == 5 ? 2 : 1;
    NV2AMetalSurfaceConfig colorConfig = {
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 8,
        .height = 4,
        .pitch = 48,
        .scale = scale,
        .color = YES
    };
    NV2AMetalSurfaceConfig depthConfig = {
        .format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        .width = 8,
        .height = 4,
        .pitch = 24,
        .scale = scale
    };
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint16_t z = UINT16_MAX;
            memcpy((uint8_t *)ram.contents + 8192 + y * 24 + x * 2, &z, 2);
            uint32_t c = UINT32_C(0xff000000);
            memcpy((uint8_t *)ram.contents + 1024 + y * 48 + x * 4, &c, 4);
        }
    dz16_directBuffers = [NSHashTable weakObjectsHashTable];
    [dz16_directBuffers addObject:ram];
    dz16_uploads = dz16_downloads = dz16_computes = 0;
    dz16_observe = YES;
    NV2AMetalCachedSurface *color = dz16_prepare(cache, 1024, colorConfig,
                                                 reference),
                           *depth = dz16_prepare(cache, 8192, depthConfig,
                                                 reference);
    uint64_t visible = dz16_draw(cache, color, depth, 0x3333, 2, NO);
    assert(visible);
    NSMutableData *result = [NSMutableData new];
    [result appendBytes:&visible length:8];
    dz16_capture(cache, result);
    // Native clear must survive download into pitched guest memory.
    dz16_clear(cache, color, depth, .75f, 1);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    dz16_capture(cache, result);
    check_region(ram, 8192, depthConfig, 0xbfff, 0xa7);
    check_region(ram, 1024, colorConfig, UINT32_C(0xff0000ff), 0xa7);
    if (scenario == 0) {
        require([cache resolveCPUAccessAtAddress:8192
                                          length:depth.transfer.sourceLength
                                           write:YES
                                           error:&error],
                error);
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 8; x++) {
                uint16_t z = 0x1111;
                memcpy((uint8_t *)ram.contents + 8192 + y * 24 + x * 2, &z, 2);
            }
        assert(depth.needsUpload);
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        color = dz16_prepare(cache, 1024, colorConfig, reference);
        visible = dz16_draw(cache, color, depth, 0x3333, 4, NO);
        assert(!visible);
        [result appendBytes:&visible length:8];
        dz16_capture(cache, result);
        require([cache resolveCPUAccessAtAddress:8192
                                          length:depth.transfer.sourceLength
                                           write:YES
                                           error:&error],
                error);
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 8; x++) {
                uint16_t z = 0xffff;
                memcpy((uint8_t *)ram.contents + 8192 + y * 24 + x * 2, &z, 2);
            }
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        color = dz16_prepare(cache, 1024, colorConfig, reference);
        visible = dz16_draw(cache, color, depth, 0x3333, 4, NO);
        assert(visible);
        [result appendBytes:&visible length:8];
        dz16_capture(cache, result);
    } else if (scenario == 1) {
        NV2AMetalCachedSurface *old = depth;
        depthConfig.floating_depth = YES;
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        assert(!old.valid && depth != old &&
               depth.transfer.texture.pixelFormat ==
                   MTLPixelFormatDepth32Float);
        id<MTLBuffer> bits = dz16_readback(cache, depth);
        [result appendBytes:bits.contents length:bits.length];
        dz16_capture(cache, result);
    } else if (scenario == 2) {
        NSData *before = [NSData dataWithBytes:ram.contents length:ram.length];
        uint64_t generation = depth.generation;
        dz16_clear(cache, color, depth, .125f, 4);
        [cache cancel];
        assert(depth.generation == generation && !depth.dirty &&
               !memcmp(ram.contents, before.bytes, ram.length));
        color = dz16_prepare(cache, 1024, colorConfig, reference);
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        id<MTLBuffer> old = dz16_readback(cache, depth);
        check_region(old, 0, depthConfig, 0xbfff, 0xcd);
        dz16_clear(cache, color, depth, .5f, 2);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        dz16_capture(cache, result);
    } else if (scenario == 3) {
        color = dz16_prepare(cache, 1024, colorConfig, reference);
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        id<MTLSharedEvent> gate = [device newSharedEvent];
        id<MTL4CommandQueue> queue = object_getIvar(
            commands,
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue"));
        [queue waitForEvent:gate value:1];
        dz16_clear(cache, color, depth, .25f, 4);
        require([cache submitWithError:&error], error);
        assert(!gate.signaledValue);
        commands.releaseOnWait = gate;
        unsigned waits = commands.waits;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!gate.signaledValue)
                             gate.signaledValue = 2;
                       });
        require([cache resolveCPUAccessAtAddress:8192
                                          length:2
                                           write:YES
                                           error:&error],
                error);
        assert(commands.waits > waits && gate.signaledValue == 1);
        uint16_t z = 0x1234;
        memcpy((uint8_t *)ram.contents + 8192, &z, 2);
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        color = dz16_prepare(cache, 1024, colorConfig, reference);
        visible = dz16_draw(cache, color, depth, 0x3333, 1, NO);
        assert(visible);
        [result appendBytes:&visible length:8];
        dz16_capture(cache, result);
        uint16_t restored;
        memcpy(&restored, (uint8_t *)ram.contents + 8192, 2);
        assert(restored == 0x1234);
    } else if (scenario == 4) {
        NSData *snapshot = [NSData dataWithBytes:ram.contents
                                          length:ram.length];
        dz16_clear(cache, color, depth, .125f, 4);
        require([cache checkpointWithError:&error] &&
                    [cache discardForRestoreWithError:&error],
                error);
        assert(!depth.valid && !color.valid && !cache.count &&
               !memcmp(ram.contents, snapshot.bytes, ram.length));
        memcpy(ram.contents, snapshot.bytes, snapshot.length);
        color = dz16_prepare(cache, 1024, colorConfig, reference);
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        id<MTLBuffer> bits = dz16_readback(cache, depth);
        [result appendBytes:bits.contents length:bits.length];
        dz16_capture(cache, result);
    } else {
        color = dz16_prepare(cache, 1024, colorConfig, reference);
        depth = dz16_prepare(cache, 8192, depthConfig, reference);
        NSUInteger pitch = depthConfig.pitch * scale,
                   length = pitch * depthConfig.height * scale;
        id<MTLBuffer> raw =
            [device newBufferWithLength:length
                                options:MTLResourceStorageModeShared];
        [dz16_directBuffers addObject:raw];
        memset(raw.contents, 0x5c, length);
        unsigned downloads = dz16_downloads;
        require([depth.transfer encodeDownloadToBuffer:raw
                                                offset:0
                                               swizzle:NO
                                                  flip:NO
                                             downscale:NO
                                              commands:commands
                                                 error:&error] &&
                    [cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(reference ? dz16_downloads == downloads :
                           dz16_downloads == downloads + 1);
        [result appendBytes:raw.contents length:raw.length];
    }
    dz16_observe = NO;
    dz16_directBuffers = nil;
    if (reference)
        assert(!dz16_uploads && !dz16_downloads && dz16_computes);
    else if (scale == 1)
        assert(dz16_uploads && dz16_downloads && !dz16_computes);
    else
        assert(dz16_downloads && dz16_computes);
    require([cache flushWithError:&error], error);
    return result;
}
static void direct_z16_cache_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands && [commands beginWithError:&error], error);
    id e = [commands.commandBuffer computeCommandEncoder];
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(prepareComputeForUpload:error:)),
        class_getInstanceMethod(
            object_getClass(e),
            @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:
                      sourceBytesPerImage:sourceSize:toTexture:destinationSlice:
                      destinationLevel:destinationOrigin:)),
        class_getInstanceMethod(
            object_getClass(e),
            @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:
                      sourceSize:toBuffer:destinationOffset:
                      destinationBytesPerRow:destinationBytesPerImage:options:))
    };
    [e endEncoding];
    [commands cancel];
    IMP replacements[] = { (IMP)dz16_compute_spy, (IMP)dz16_upload_spy,
                           (IMP)dz16_download_spy },
        originals[3];
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    dz16_compute = (void *)originals[0];
    dz16_upload = (void *)originals[1];
    dz16_download = (void *)originals[2];
    @try {
        for (unsigned scenario = 0; scenario < 6; scenario++)
            @autoreleasepool {
                NSData *result[2];
                for (unsigned order = 0; order < 2; order++) {
                    unsigned reference = (order + scenario) & 1;
                    result[reference] = dz16_run(device, scenario, reference);
                }
                if (![result[0] isEqualToData:result[1]]) {
                    fprintf(stderr, "Direct Z16 cache scenario%u mismatch\n",
                            scenario);
                    abort();
                }
            }
        puts("Direct Z16 cache:6 exact native raster/query/VRAM pairs; "
             "CPUwrite-reupload, F16 alias, cancel/retry, gated old write, "
             "Restore and scaled full readback PASS");
    } @finally {
        dz16_observe = NO;
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
    }
}
#endif
