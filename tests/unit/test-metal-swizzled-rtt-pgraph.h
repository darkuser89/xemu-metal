/* Swizzled channel RTT sampling versus the original VRAM download/decode.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SWIZZLED_RTT_PGRAPH_H
#define TEST_METAL_SWIZZLED_RTT_PGRAPH_H
#include "test-metal-texture-readback.h"

static BOOL scr_reference, scr_scope, scr_fail;
static unsigned scr_downloads, scr_eligible, scr_xf;
static __weak NV2AMetalSurfaceTransfer *scr_source;
static BOOL (*scr_admission_original)(id, SEL, id, unsigned);
static BOOL scr_admission(id object, SEL selector, id surface, unsigned format)
{
    BOOL eligible = scr_admission_original(object, selector, surface, format);
    if (scr_scope &&
        ((NV2AMetalCachedSurface *)surface).transfer == scr_source) {
        scr_eligible += eligible;
    }
    return scr_reference ? NO : eligible;
}
static BOOL (*scr_download_original)(id, SEL, id, NSUInteger, BOOL, BOOL, BOOL,
                                     id, NSError **);
static BOOL scr_download(id object, SEL selector, id buffer, NSUInteger offset,
                         BOOL swizzle, BOOL flip, BOOL downscale, id commands,
                         NSError **error)
{
    if (scr_scope && object == scr_source)
        scr_downloads++;
    return scr_download_original(object, selector, buffer, offset, swizzle,
                                 flip, downscale, commands, error);
}
static BOOL (*scr_emit_original)(id, SEL, id, id, NSError **);
static BOOL scr_emit(id object, SEL selector, id encoder, id commands,
                     NSError **error)
{
    BOOL ok = scr_emit_original(object, selector, encoder, commands, error);
    if (ok && scr_fail && commands == surfaces.cache.commands) {
        scr_fail = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.swizzled-rtt.raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static id (*scr_epoch_original)(id, SEL, id, id, NSUInteger, NSUInteger, id, id,
                                NSError **);
static BOOL scr_track_xf;
static id scr_epoch(id object, SEL selector, id vertex, id attributes,
                    NSUInteger first, NSUInteger count, id fetch, id commands,
                    NSError **error)
{
    if (scr_track_xf)
        scr_xf += count;
    return scr_epoch_original(object, selector, vertex, attributes, first,
                              count, fetch, commands, error);
}
/* Reuse the GPU BGRA seed and point coordinates, not the opaque-X8 oracle. */
static uint32_t scr_expected(unsigned format, uint32_t bgra)
{
    unsigned b = bgra & 255, g = (bgra >> 8) & 255;
    unsigned r = (bgra >> 16) & 255, a = bgra >> 24;
    if (format >= 2)
        return b << 24 | g << 16 | r << 8 | a;
    return format ? (b << 24 | a << 16 | r << 8 | g) :
                    (a << 24 | b << 16 | g << 8 | r);
}
static void scr_ram(unsigned format, BOOL downloaded)
{
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            /* Independent square-8 Morton address; LU uses ordinary rows. */
            unsigned ordinal = format == 3 ?
                                   y * 8 + x :
                                   (x & 1) | ((y & 1) << 1) | ((x & 2) << 1) |
                                       ((y & 2) << 2) | ((x & 4) << 2) |
                                       ((y & 4) << 3);
            assert((uint32_t)ldl_le_p(state->vram_ptr + 32768 + ordinal * 4) ==
                   (downloaded ? sxp_pixel(x, y) : UINT32_C(0xffe00017)));
        }
}
static NSData *scr_texture(id<MTLTexture> texture, unsigned format, BOOL fresh)
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
    assert(values.length >= 7 * 256 + 8 * 16);
    NSMutableData *logical = [NSMutableData new];
    for (unsigned y = 0; y < 8; y++) {
        const float *row =
            (const float *)((const uint8_t *)values.contents + y * 256);
        for (unsigned x = 0; x < 8; x++) {
            uint32_t value = scr_expected(format, fresh ? UINT32_C(0x5a1c8be3) :
                                                          sxp_pixel(x, y));
            unsigned expected[] = { (value >> 16) & 255, (value >> 8) & 255,
                                    value & 255, value >> 24 };
            for (unsigned k = 0; k < 4; k++)
                assert(fabsf(row[x * 4 + k] - expected[k] / 255.f) < .000001f);
        }
        [logical appendBytes:row length:8 * 16];
    }
    return logical;
}
static NSData *scr_run(unsigned family, unsigned format, unsigned scale,
                       BOOL linear, BOOL reference, BOOL lifecycle)
{
    scr_reference = reference;
    cpp_scene(YES, 0);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8
    };
    assert(format < ARRAY_SIZE(formats));
    texture_registers(formats[format], format == 3 ? 32 : 0);
    pg->regs_[NV_PGRAPH_TEXFILTER0] =
        (linear ? 2u : 1u) << 16 | (linear ? 2u : 1u) << 24;
    sxp_coordinates(format != 3);
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
        .format = family == 1 ?
                      NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8 :
                  family == 2 ?
                      NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8 :
                      NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 8,
        .height = 8,
        .pitch = 32,
        .scale = scale,
        .color = YES,
        .swizzle = format != 3
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
    scr_source = source.transfer;
    scr_downloads = scr_eligible = 0;
    scr_scope = YES;
    BOOL ok = [draw beginWithError:&error];
    scr_scope = NO;
    require(ok, error);
    unsigned downloads = scr_downloads, eligible = scr_eligible;
    scr_source = nil;
    source = nil;
    NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
    NV2AMetalCachedTexture *snapshot = [pixel.textureSnapshot textureAtIndex:0];
    assert(snapshot && snapshot.scale == 1);
    scr_track_xf = lifecycle;
    scr_xf = 0;
    if (lifecycle)
        require([draw prepareVertexStateChangeWithError:&error], error);
    NSData *begin = [draw beginSnapshotWithError:&error];
    require(begin != nil, error);
    NSMutableData *actual = [NSMutableData
        dataWithData:scr_texture(snapshot.binding.texture, format, NO)];
    scr_ram(format, reference);
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
        scr_fail = YES;
        assert(![draw flushDrawWithError:&error] && error && !scr_fail &&
               [error.domain isEqualToString:@"test.swizzled-rtt.raster"] &&
               [checkpoint isEqualToData:fpp_host()]);
        error = nil;
        NSData *after = [draw pendingSnapshotWithError:&error];
        require(after != nil, error);
        assert([after isEqualToData:pending]);
    }
    require([draw endWithError:&error], error);
    scr_track_xf = NO;
    [actual appendData:sxp_frame()];
    uint32_t a = ldl_le_p(state->vram_ptr + 1024 + (1 * 8 + 1) * 4);
    uint32_t b = ldl_le_p(state->vram_ptr + 1024 + (1 * 8 + 4) * 4);
    assert(a != b); /* Real sampled pattern, not the common green V0. */
    assert(eligible && downloads == (reference ? 1u : 0u));
    if (lifecycle) {
        assert(scr_xf == 3);
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
        NV2AMetalSubmission *oldReceipt = reader.lastSubmitted;
        NSError *feedbackError = nil;
        assert(oldReceipt && ![oldReceipt completedWithError:&feedbackError] &&
               !feedbackError && !gate.signaledValue &&
               *(const uint32_t *)old.contents == UINT32_C(0xcdcdcdcd));
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
        scr_ram(format, YES);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t changed = UINT32_C(0x5a1c8be3);
            memcpy(state->vram_ptr + 32768 + i * 4, &changed, 4);
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
        uint32_t changed = scr_expected(format, UINT32_C(0x5a1c8be3));
        color(1, 1, changed);
        color(4, 1, changed);
        color(1, 4, changed);
        [actual appendData:scr_texture(fresh.binding.texture, format, YES)];
        assert(![oldReceipt completedWithError:&feedbackError] &&
               !feedbackError && !gate.signaledValue &&
               *(const uint32_t *)old.contents == UINT32_C(0xcdcdcdcd));
        gate.signaledValue = 1;
        require([reader waitUntilIdleWithError:&error], error);
        MTLPixelFormat storage = snapshot.binding.texture.pixelFormat;
        assert(storage == MTLPixelFormatBGRA8Unorm ||
               storage == MTLPixelFormatRGBA8Unorm);
        MTLTextureSwizzleChannels swizzle = snapshot.binding.texture.swizzle;
        unsigned channels[] = { test_texture_swizzle_index(swizzle.red),
                                test_texture_swizzle_index(swizzle.green),
                                test_texture_swizzle_index(swizzle.blue),
                                test_texture_swizzle_index(swizzle.alpha) };
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                const uint8_t *value =
                    (const uint8_t *)old.contents + y * 256 + x * 4;
                unsigned raw[] = {
                    value[storage == MTLPixelFormatBGRA8Unorm ? 2 : 0],
                    value[1],
                    value[storage == MTLPixelFormatBGRA8Unorm ? 0 : 2],
                    value[3],
                    0,
                    255
                };
                uint32_t expected = scr_expected(format, sxp_pixel(x, y));
                unsigned rgba[] = { (expected >> 16) & 255,
                                    (expected >> 8) & 255, expected & 255,
                                    expected >> 24 };
                for (unsigned k = 0; k < 4; k++)
                    assert(raw[channels[k]] == rgba[k]);
            }
        assert(fresh.binding.texture != snapshot.binding.texture);
    }
    [actual appendData:scr_texture(snapshot.binding.texture, format, NO)];
    qemu_mutex_unlock(&pg->lock);
    scr_source = nil;
    return actual;
}
static void swizzled_rtt_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalTextureCache.class,
            NSSelectorFromString(@"canCaptureSwizzledChannelsSurface:format:")),
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
    IMP replacements[] = { (IMP)scr_admission, (IMP)scr_download, (IMP)scr_emit,
                           (IMP)scr_epoch };
    IMP originals[4];
    for (unsigned i = 0; i < 4; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    scr_admission_original = (void *)originals[0];
    scr_download_original = (void *)originals[1];
    scr_emit_original = (void *)originals[2];
    scr_epoch_original = (void *)originals[3];
    for (unsigned i = 0; i < 4; i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned family = 0; family < 3; family++)
            for (unsigned format = 0; format < 4; format++)
                for (unsigned scale = 1; scale <= 4; scale *= 2)
                    for (unsigned linear = 0; linear < 2; linear++) {
                        if (family && (family != (format % 2 ? 2u : 1u) ||
                                       scale != (family == 1 ? 2u : 4u) ||
                                       linear != format % 2))
                            continue;
                        @autoreleasepool {
                            BOOL lifecycle =
                                !family &&
                                ((!format && scale == 2 && !linear) ||
                                 (format == 1 && scale == 4 && linear));
                            NSData *old = scr_run(family, format, scale, linear,
                                                  YES, lifecycle);
                            NSData *actual = scr_run(family, format, scale,
                                                     linear, NO, lifecycle);
                            if (![old isEqualToData:actual]) {
                                fprintf(stderr,
                                        "Swizzled RTT PGRAPH mismatch family%u "
                                        "format%u scale%u linear%u\n",
                                        family, format, scale, linear);
                                abort();
                            }
                            pairs++;
                        }
                    }
    } @finally {
        scr_scope = scr_reference = scr_fail = scr_track_xf = NO;
        scr_source = nil;
        for (unsigned i = 0; i < 4; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    assert(pairs == 28);
    printf(
        "Swizzled RTT PGRAPH:28 A8/A7Z/A7O SZ ABGR/RGBA/BGRA and LU BGRA "
        "scale1/2/4 "
        "nearest/linear pairs; GPU/RAM poison, RGBA bytes, FB/Zeta/query/"
        "Current/context, snapshot/Restore/retry/sourcealias/oldreader PASS\n");
    groups += pairs;
}
#endif
