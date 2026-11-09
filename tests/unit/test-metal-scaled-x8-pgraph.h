/* Scaled opaque RTT sampling versus the original VRAM download/upload.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SCALED_X8_PGRAPH_H
#define TEST_METAL_SCALED_X8_PGRAPH_H
#include "test-metal-texture-readback.h"

static BOOL sxp_reference, sxp_scope, sxp_fail;
static unsigned sxp_downloads, sxp_eligible, sxp_xf;
static NV2AMetalSurfaceTransfer *sxp_source;
static BOOL (*sxp_admission_original)(id, SEL, id, unsigned);
static BOOL sxp_admission(id object, SEL selector, id surface, unsigned format)
{
    BOOL eligible = sxp_admission_original(object, selector, surface, format);
    if (sxp_scope &&
        ((NV2AMetalCachedSurface *)surface).transfer == sxp_source) {
        sxp_eligible += eligible;
        if (sxp_reference)
            return NO;
    }
    return eligible;
}
static BOOL (*sxp_download_original)(id, SEL, id, NSUInteger, BOOL, BOOL, BOOL,
                                     id, NSError **);
static BOOL sxp_download(id object, SEL selector, id buffer, NSUInteger offset,
                         BOOL swizzle, BOOL flip, BOOL downscale, id commands,
                         NSError **error)
{
    if (sxp_scope && object == sxp_source)
        sxp_downloads++;
    return sxp_download_original(object, selector, buffer, offset, swizzle,
                                 flip, downscale, commands, error);
}
static BOOL (*sxp_emit_original)(id, SEL, id, id, NSError **);
static BOOL sxp_emit(id object, SEL selector, id encoder, id commands,
                     NSError **error)
{
    BOOL ok = sxp_emit_original(object, selector, encoder, commands, error);
    if (ok && sxp_fail && commands == surfaces.cache.commands) {
        sxp_fail = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.scaled-x8.raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static id (*sxp_epoch_original)(id, SEL, id, id, NSUInteger, NSUInteger, id, id,
                                NSError **);
static BOOL sxp_track_xf;
static id sxp_epoch(id object, SEL selector, id vertex, id attributes,
                    NSUInteger first, NSUInteger count, id fetch, id commands,
                    NSError **error)
{
    if (sxp_track_xf)
        sxp_xf += count;
    return sxp_epoch_original(object, selector, vertex, attributes, first,
                              count, fetch, commands, error);
}
static uint32_t sxp_pixel(unsigned x, unsigned y)
{
    unsigned r = (17 + x * 23 + y * 3) & 255;
    unsigned g = (11 + x * 7 + y * 29) & 255;
    unsigned b = (7 + x * 41 + y * 13) & 255;
    return ((x * 53 + y * 37) & 255) << 24 | r << 16 | g << 8 | b;
}
static void sxp_seed(NV2AMetalCachedSurface *surface)
{
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *q = cache.commands;
    NSError *error = nil;
    id<MTLTexture> texture = [surface.transfer textureForCommands:q
                                                            error:&error];
    require(texture != nil, error);
    unsigned scale = surface.transfer.config.scale;
    NSUInteger pitch = (texture.width * 4 + 255) & ~(NSUInteger)255;
    id<MTLBuffer> bytes =
        [q.device newBufferWithLength:pitch * texture.height
                              options:MTLResourceStorageModeShared];
    require(bytes != nil, nil);
    memset(bytes.contents, 0xcd, bytes.length);
    for (unsigned y = 0; y < texture.height; y++)
        for (unsigned x = 0; x < texture.width; x++) {
            /* Every intervening scaled texel is poison for accidental native
             * filtering or centre selection. Only (x*scale,y*scale) is legal.
             */
            uint32_t color = x % scale || y % scale ?
                                 UINT32_C(0xffec03df) :
                                 sxp_pixel(x / scale, y / scale);
            memcpy((uint8_t *)bytes.contents + y * pitch + x * 4, &color, 4);
        }
    require([q addResource:bytes error:&error] && [q addResource:texture
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
                 sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                  toTexture:texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([cache markWritten:surface replacingContents:YES error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
}
static NSData *sxp_texture(id<MTLTexture> texture, BOOL blue)
{
    NSError *error = nil;
    assert(texture.width == 8 && texture.height == 8);
    NV2AMetalCommands *q =
        [[NV2AMetalCommands alloc] initWithDevice:texture.device error:&error];
    require(q && [q beginWithError:&error], error);
    id<MTLBuffer> values = test_metal_read_texture(q, texture, 0, 0);
    require(values && [q submitWithError:&error] &&
                [q waitUntilIdleWithError:&error],
            error);
    NSMutableData *logical = [NSMutableData new];
    for (unsigned y = 0; y < 8; y++) {
        const float *row =
            (const float *)((const uint8_t *)values.contents + y * 256);
        for (unsigned x = 0; x < 8; x++) {
            uint32_t value = blue ? 0xff0000ff : sxp_pixel(x, y);
            unsigned expected[] = { (value >> 16) & 255, (value >> 8) & 255,
                                    value & 255, 255 };
            for (unsigned k = 0; k < 4; k++)
                assert(fabsf(row[x * 4 + k] - expected[k] / 255.f) < .000001f);
        }
        [logical appendBytes:row length:8 * 16];
    }
    return logical;
}
static void sxp_coordinates(BOOL swizzled)
{
    PGRAPHState *pg = &state->pgraph;
    const float coordinates[3][2] = { { 1.25, 2.75 },
                                      { 5.625, 3.125 },
                                      { 4.25, 6.375 } };
    pg->vertex_attributes[9] =
        (VertexAttribute){ .offset = 768,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    cpu_write(17152, 48);
    for (unsigned i = 0; i < 3; i++) {
        float t[4] = { coordinates[i][0] / (swizzled ? 8.f : 1.f),
                       coordinates[i][1] / (swizzled ? 8.f : 1.f), 0, 1 };
        memcpy(state->vram_ptr + 17152 + i * 16, t, 16);
    }
}
static NSData *sxp_frame(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error] &&
                [cache prepareCPUAccessAtAddress:1024
                                          length:256
                                           write:NO
                                           error:&error] &&
                [cache prepareCPUAccessAtAddress:4096
                                          length:256
                                           write:NO
                                           error:&error] &&
                [draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(query == 3);
    return cpp_capture(query);
}
static NSData *sxp_run(unsigned family, BOOL swizzled, unsigned scale,
                       BOOL linear, BOOL reference, BOOL lifecycle)
{
    cpp_scene(YES, 0);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    sxp_reference = reference;
    texture_registers(swizzled ?
                          NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8 :
                          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8,
                      swizzled ? 0 : 32);
    pg->regs_[NV_PGRAPH_TEXFILTER0] =
        (linear ? 2u : 1u) << 16 | (linear ? 2u : 1u) << 24;
    sxp_coordinates(swizzled);
    qemu_mutex_lock(&pg->lock);
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    cpu_write(32768, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t poison = UINT32_C(0xffe00017);
        memcpy(state->vram_ptr + 32768 + i * 4, &poison, 4);
    }
    NV2AMetalSurfaceConfig config = {
        .format = family ?
                      NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8 :
                      NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 8,
        .height = 8,
        .pitch = 32,
        .scale = scale,
        .color = YES,
        .swizzle = swizzled
    };
    NV2AMetalCachedSurface *source = [cache prepareSurfaceAtAddress:32768
                                                             config:&config
                                                              frame:1
                                                       forRendering:YES
                                                              error:&error];
    require(source != nil, error);
    sxp_seed(source);
    for (unsigned i = 0; i < 64; i++)
        assert((uint32_t)ldl_le_p(state->vram_ptr + 32768 + i * 4) ==
               UINT32_C(0xffe00017));
    sxp_source = source.transfer;
    sxp_downloads = sxp_eligible = 0;
    sxp_scope = YES;
    BOOL ok = [draw beginWithError:&error];
    sxp_scope = NO;
    require(ok, error);
    unsigned downloads = sxp_downloads, eligible = sxp_eligible;
    sxp_source = nil;
    source = nil;
    NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
    NV2AMetalCachedTexture *snapshot = [pixel.textureSnapshot textureAtIndex:0];
    assert(snapshot && snapshot.scale == 1);
    sxp_track_xf = lifecycle;
    sxp_xf = 0;
    if (lifecycle)
        require([draw prepareVertexStateChangeWithError:&error], error);
    NSData *begin = [draw beginSnapshotWithError:&error];
    require(begin != nil, error);
    NSMutableData *actual =
        [NSMutableData dataWithData:sxp_texture(snapshot.binding.texture, NO)];
    assert(reference ? (ldl_le_p(state->vram_ptr + 32768) & 0xffffff) ==
                           (sxp_pixel(0, 0) & 0xffffff) :
                       (uint32_t)ldl_le_p(state->vram_ptr + 32768) ==
                           UINT32_C(0xffe00017));
    if (lifecycle) {
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *vertex = draw.vertexSnapshot;
        require(pending && vertex && [draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    [draw restorePendingSnapshot:pending error:&error] &&
                    [draw beginWithError:&error],
                error);
        NSData *checkpoint = fpp_host();
        sxp_fail = YES;
        assert(![draw flushDrawWithError:&error] && error && !sxp_fail &&
               [error.domain isEqualToString:@"test.scaled-x8.raster"] &&
               [checkpoint isEqualToData:fpp_host()]);
        error = nil;
        NSData *after = [draw pendingSnapshotWithError:&error];
        require(after != nil, error);
        assert([after isEqualToData:pending]);
    }
    require([draw endWithError:&error], error);
    sxp_track_xf = NO;
    [actual appendData:sxp_frame()];
    uint32_t a = ldl_le_p(state->vram_ptr + 1024 + (1 * 8 + 1) * 4);
    uint32_t b = ldl_le_p(state->vram_ptr + 1024 + (1 * 8 + 4) * 4);
    assert(a != b); /* Real sampled pattern, not the common green V0. */
    assert(eligible && downloads == (reference ? 1u : 0u));
    if (lifecycle) {
        assert(sxp_xf == 3);
        /* Restore retained the immutable Begin texture, not the discarded
         * dirty source binding. Establish a real new GPU writer before the
         * CPU-prewrite/download and alias test below. */
        NV2AMetalCachedSurface *liveSource =
            [cache prepareSurfaceAtAddress:32768
                                    config:&config
                                     frame:2
                              forRendering:YES
                                     error:&error];
        require(liveSource != nil, error);
        sxp_seed(liveSource);
        liveSource = nil;
        /* A pending private reader must not prevent a CPU store to the
         * original guest source or observe a later source reallocation. */
        NV2AMetalCommands *reader =
            [[NV2AMetalCommands alloc] initWithDevice:cache.commands.device
                                                error:&error];
        id<MTLSharedEvent> gate = [reader.device newSharedEvent];
        require(reader && gate && [reader beginWithError:&error], error);
        [((id<MTL4CommandQueue>)[reader valueForKey:@"queue"]) waitForEvent:gate
                                                                      value:1];
        id<MTLBuffer> old =
            [reader.device newBufferWithLength:2048
                                       options:MTLResourceStorageModeShared];
        require(old && [reader addResource:old error:&error] &&
                    [reader addResource:snapshot.binding.texture error:&error],
                error);
        memset(old.contents, 0xcd, old.length);
        id<MTL4ComputeCommandEncoder> e =
            [reader.commandBuffer computeCommandEncoder];
        require(e != nil, nil);
        [e copyFromTexture:snapshot.binding.texture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(8, 8, 1)
                            toBuffer:old
                   destinationOffset:0
              destinationBytesPerRow:256
            destinationBytesPerImage:0
                             options:MTLBlitOptionNone];
        [e endEncoding];
        require([reader submitWithError:&error], error);
        id<MTLSharedEvent> watchdog = gate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!watchdog.signaledValue)
                             watchdog.signaledValue = 2;
                       });
        uint64_t generation =
            [[cache valueForKey:@"generation"] unsignedLongLongValue];
        require([cache prepareCPUAccessAtAddress:32768
                                          length:256
                                           write:YES
                                           error:&error],
                error);
        assert([[cache valueForKey:@"generation"] unsignedLongLongValue] ==
               generation + 1);
        assert((ldl_le_p(state->vram_ptr + 32768) & 0xffffff) ==
               (sxp_pixel(0, 0) & 0xffffff));
        for (unsigned i = 0; i < 64; i++) {
            uint32_t blue = UINT32_C(0x000000ff);
            memcpy(state->vram_ptr + 32768 + i * 4, &blue, 4);
        }
        config.scale = 1;
        require([cache prepareSurfaceAtAddress:32768
                                        config:&config
                                         frame:3
                                  forRendering:NO
                                         error:&error] != nil,
                error);
        pg->draw_arrays_length = 1;
        [draw.reports clear];
        require([draw beginWithError:&error], error);
        pixel = [draw valueForKey:@"pixelState"];
        NV2AMetalCachedTexture *fresh =
            [pixel.textureSnapshot textureAtIndex:0];
        require([draw endWithError:&error], error);
        [actual appendData:sxp_frame()];
        color(1, 1, UINT32_C(0xff0000ff));
        color(4, 1, UINT32_C(0xff0000ff));
        color(1, 4, UINT32_C(0xff0000ff));
        [actual appendData:sxp_texture(fresh.binding.texture, YES)];
        assert(fresh.binding.texture != snapshot.binding.texture &&
               !gate.signaledValue &&
               *(const uint32_t *)old.contents == UINT32_C(0xcdcdcdcd));
        gate.signaledValue = 1;
        require([reader waitUntilIdleWithError:&error], error);
        MTLPixelFormat storage = snapshot.binding.texture.pixelFormat;
        assert(storage == MTLPixelFormatBGRA8Unorm ||
               storage == MTLPixelFormatRGBA8Unorm);
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                const uint8_t *value =
                    (const uint8_t *)old.contents + y * 256 + x * 4;
                uint32_t expected = sxp_pixel(x, y);
                // X8's physical X byte is ignored; logical alpha-one was
                // checked above.
                assert(value[1] == ((expected >> 8) & 255));
                assert(value[storage == MTLPixelFormatBGRA8Unorm ? 0 : 2] ==
                       (expected & 255));
                assert(value[storage == MTLPixelFormatBGRA8Unorm ? 2 : 0] ==
                       ((expected >> 16) & 255));
            }
    }
    [actual appendData:sxp_texture(snapshot.binding.texture, NO)];
    qemu_mutex_unlock(&pg->lock);
    sxp_source = nil;
    return actual;
}
static void scaled_x8_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalTextureCache.class,
            NSSelectorFromString(
                @"canCaptureDownsampledOpaqueSurface:format:")),
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(encodeDownloadToBuffer:offset:swizzle:
                                          flip:downscale:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:))
    };
    IMP replacements[] = { (IMP)sxp_admission, (IMP)sxp_download, (IMP)sxp_emit,
                           (IMP)sxp_epoch };
    IMP originals[4];
    for (unsigned i = 0; i < 4; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    sxp_admission_original = (void *)originals[0];
    sxp_download_original = (void *)originals[1];
    sxp_emit_original = (void *)originals[2];
    sxp_epoch_original = (void *)originals[3];
    for (unsigned i = 0; i < 4; i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned family = 0; family < 2; family++)
            for (unsigned layout = 0; layout < 2; layout++)
                for (unsigned scale = 2; scale <= 4; scale *= 2)
                    for (unsigned linear = 0; linear < 2; linear++) {
                        @autoreleasepool {
                            BOOL lifecycle =
                                family && layout && scale == 4 && linear;
                            NSData *old = sxp_run(family, layout, scale, linear,
                                                  YES, lifecycle);
                            NSData *actual = sxp_run(family, layout, scale,
                                                     linear, NO, lifecycle);
                            if (![old isEqualToData:actual]) {
                                fprintf(stderr,
                                        "Scaled X8 PGRAPH mismatch A7%u SZ%u "
                                        "scale%u linear%u\n",
                                        family, layout, scale, linear);
                                abort();
                            }
                            pairs++;
                        }
                    }
    } @finally {
        sxp_scope = sxp_reference = sxp_fail = sxp_track_xf = NO;
        sxp_source = nil;
        for (unsigned i = 0; i < 4; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    assert(pairs == 16);
    printf(
        "Scaled X8 PGRAPH:16 A8/A7 LU/SZ scale2/4 nearest/linear raster pairs; "
        "GPU pattern/offgrid, logical alpha-one, depth/query/Current/context, "
        "prefix/snapshot/late retry, CPUwrite/sourcealias and retained "
        "GPUreader PASS\n");
    groups += pairs;
}
#endif
