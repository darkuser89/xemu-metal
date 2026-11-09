/* Packed 1555 RTT sampling versus the original VRAM download and decoder.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PACKED1555_RTT_PGRAPH_H
#define TEST_METAL_PACKED1555_RTT_PGRAPH_H

static BOOL p15_reference, p15_scope, p15_fail, p15_track_xf;
static unsigned p15_ram_downloads, p15_private_downloads, p15_eligible, p15_xf;
static __weak NV2AMetalSurfaceTransfer *p15_source;
static BOOL (*p15_admission_original)(id, SEL, id, unsigned);
static BOOL p15_admission(id owner, SEL selector, id surface, unsigned format)
{
    BOOL eligible = p15_admission_original(owner, selector, surface, format);
    if (p15_scope && ((NV2AMetalCachedSurface *)surface).transfer == p15_source)
        p15_eligible += eligible;
    return p15_reference ? NO : eligible;
}
static BOOL (*p15_download_original)(id, SEL, id, NSUInteger, BOOL, BOOL, BOOL,
                                     id, NSError **);
static BOOL p15_download(id owner, SEL selector, id<MTLBuffer> buffer,
                         NSUInteger offset, BOOL swizzle, BOOL flip,
                         BOOL downscale, id commands, NSError **error)
{
    if (p15_scope && owner == p15_source) {
        p15_ram_downloads += buffer == surfaces.cache.vram;
        p15_private_downloads += buffer.storageMode == MTLStorageModePrivate;
    }
    return p15_download_original(owner, selector, buffer, offset, swizzle, flip,
                                 downscale, commands, error);
}
static BOOL (*p15_emit_original)(id, SEL, id, id, NSError **);
static BOOL p15_emit(id owner, SEL selector, id encoder, id commands,
                     NSError **error)
{
    BOOL ok = p15_emit_original(owner, selector, encoder, commands, error);
    if (ok && p15_fail && commands == surfaces.cache.commands) {
        p15_fail = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.packed1555.raster"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return ok;
}
static id (*p15_epoch_original)(id, SEL, id, id, NSUInteger, NSUInteger, id, id,
                                NSError **);
static id p15_epoch(id owner, SEL selector, id vertex, id attributes,
                    NSUInteger first, NSUInteger count, id fetch, id commands,
                    NSError **error)
{
    if (p15_track_xf)
        p15_xf += count;
    return p15_epoch_original(owner, selector, vertex, attributes, first, count,
                              fetch, commands, error);
}
static unsigned p15_ordinal(unsigned x, unsigned y, BOOL linear)
{
    return linear ? y * 8 + x :
                    (x & 1) | ((y & 1) << 1) | ((x & 2) << 1) | ((y & 2) << 2) |
                        ((x & 4) << 2) | ((y & 4) << 3);
}
static uint16_t p15_word(unsigned x, unsigned y, BOOL kill)
{
    if (kill && !y && x < 3) {
        const uint16_t endpoints[] = { 0x001f, 0xfc00, 0x03e0 };
        return endpoints[x]; /* Blue/opaque red/green, alpha 0/1/0. */
    }
    return (((x ^ y) & 1) << 15) | (((x * 7 + y * 3 + 1) & 31) << 10) |
           (((x * 3 + y * 11 + 5) & 31) << 5) | ((x * 13 + y * 5 + 9) & 31);
}
static void p15_ram(BOOL linear, BOOL downloaded, BOOL kill, BOOL fresh)
{
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint16_t expected = fresh      ? 0x83e0 :
                                downloaded ? p15_word(x, y, kill) :
                                             0x4210;
            uint16_t actual;
            memcpy(&actual,
                   state->vram_ptr + 32768 + p15_ordinal(x, y, linear) * 2, 2);
            assert(le16_to_cpu(actual) == expected);
        }
}
static void p15_seed(NV2AMetalCachedSurface *surface, BOOL kill)
{
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *q = cache.commands;
    NSError *error = nil;
    id<MTLTexture> texture = [surface.transfer textureForCommands:q
                                                            error:&error];
    require(texture && texture.pixelFormat == MTLPixelFormatBGR5A1Unorm, error);
    unsigned scale = surface.transfer.config.scale;
    NSUInteger pitch = (texture.width * 2 + 255) & ~(NSUInteger)255;
    id<MTLBuffer> bytes =
        [q.device newBufferWithLength:pitch * texture.height
                              options:MTLResourceStorageModeShared];
    require(bytes != nil, nil);
    memset(bytes.contents, 0xcd, bytes.length);
    for (unsigned y = 0; y < texture.height; y++)
        for (unsigned x = 0; x < texture.width; x++) {
            uint16_t word = cpu_to_le16(
                x % scale || y % scale ? 0x7c1f :
                                         p15_word(x / scale, y / scale, kill));
            memcpy((uint8_t *)bytes.contents + y * pitch + x * 2, &word, 2);
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
static NSData *p15_texture(id<MTLTexture> texture, unsigned format, BOOL kill,
                           BOOL fresh)
{
    NSError *error = nil;
    NV2AMetalCommands *q =
        [[NV2AMetalCommands alloc] initWithDevice:texture.device error:&error];
    require(q && [q beginWithError:&error], error);
    id<MTLBuffer> bytes = test_metal_read_texture(q, texture, 0, 0);
    require(bytes && [q submitWithError:&error] &&
                [q waitUntilIdleWithError:&error],
            error);
    assert(texture.width == 8 && texture.height == 8 &&
           bytes.length >= 7 * 256 + 8 * 16);
    NSMutableData *result = [NSMutableData new];
    for (unsigned y = 0; y < 8; y++) {
        const float *row =
            (const float *)((const uint8_t *)bytes.contents + y * 256);
        for (unsigned x = 0; x < 8; x++) {
            uint16_t word = fresh ? 0x83e0 : p15_word(x, y, kill);
            float expected[] = { ((word >> 10) & 31) / 31.f,
                                 ((word >> 5) & 31) / 31.f, (word & 31) / 31.f,
                                 !format ? 1.f : (float)(word >> 15) };
            for (unsigned component = 0; component < 4; component++)
                assert(fabsf(row[x * 4 + component] - expected[component]) <
                       .000001f);
        }
        [result appendBytes:row length:8 * 16];
    }
    return result;
}
static NSData *p15_frame(unsigned expectedQuery)
{
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NSError *error = nil;
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
    unsigned query = report_value(0);
    assert(query == expectedQuery);
    return cpp_capture(query);
}
static void p15_coordinates(BOOL linear, BOOL kill)
{
    sxp_coordinates(!linear);
    if (!kill)
        return;
    for (unsigned i = 0; i < 3; i++) {
        float coordinate[4] = { (i + .5f) / (linear ? 1.f : 8.f),
                                .5f / (linear ? 1.f : 8.f), 0, 1 };
        memcpy(state->vram_ptr + 17152 + i * 16, coordinate, 16);
    }
}
static NSData *p15_run(unsigned family, unsigned format, unsigned scale,
                       BOOL filtering, BOOL reference, BOOL kill,
                       BOOL lifecycle, BOOL cold)
{
    p15_reference = reference;
    cpp_scene(YES, 0);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5
    };
    BOOL linear = format == 2;
    texture_registers(formats[format], linear ? 16 : 0);
    pg->regs_[NV_PGRAPH_TEXFILTER0] =
        (filtering ? 2u : 1u) << 16 | (filtering ? 2u : 1u) << 24;
    if (kill)
        pg->regs_[NV_PGRAPH_TEXCTL0_0] |= NV_PGRAPH_TEXCTL0_0_ALPHAKILLEN;
    p15_coordinates(linear, kill);
    qemu_mutex_lock(&pg->lock);
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    cpu_write(32768, 128);
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint16_t word = cpu_to_le16(cold ? p15_word(x, y, kill) : 0x4210);
            memcpy(state->vram_ptr + 32768 + p15_ordinal(x, y, linear) * 2,
                   &word, 2);
        }
    NV2AMetalSurfaceConfig config = {
        .format = family ? NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5 :
                           NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
        .width = 8,
        .height = 8,
        .pitch = 16,
        .scale = scale,
        .color = YES,
        .swizzle = !linear
    };
    if (!cold) {
        NV2AMetalCachedSurface *source = [cache prepareSurfaceAtAddress:32768
                                                                 config:&config
                                                                  frame:1
                                                           forRendering:YES
                                                                  error:&error];
        require(source != nil, error);
        p15_seed(source, kill);
        p15_ram(linear, NO, kill, NO);
        p15_source = source.transfer;
    }
    p15_ram_downloads = p15_private_downloads = p15_eligible = 0;
    p15_scope = YES;
    BOOL ok = [draw beginWithError:&error];
    p15_scope = NO;
    require(ok, error);
    unsigned ramDownloads = p15_ram_downloads;
    unsigned privateDownloads = p15_private_downloads, eligible = p15_eligible;
    p15_source = nil;
    NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
    NV2AMetalCachedTexture *snapshot = [pixel.textureSnapshot textureAtIndex:0];
    require(snapshot != nil, nil);
    /* Snapshot completion fences the real capture before a separate queue
     * reads the immutable texture. It does not download the original RAM. */
    NSData *begin = [draw beginSnapshotWithError:&error];
    require(begin != nil, error);
    NSMutableData *actual = [NSMutableData
        dataWithData:p15_texture(snapshot.binding.texture, format, kill, NO)];
    p15_ram(linear, reference || cold, kill, NO);
    [actual appendData:begin];
    p15_track_xf = lifecycle;
    p15_xf = 0;
    if (lifecycle) {
        require([draw prepareVertexStateChangeWithError:&error], error);
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *vertex = draw.vertexSnapshot;
        require(pending && vertex && [draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    [draw restorePendingSnapshot:pending error:&error] &&
                    [draw beginWithError:&error],
                error);
        NSData *checkpoint = fpp_host();
        p15_fail = YES;
        assert(![draw flushDrawWithError:&error] && error && !p15_fail &&
               [error.domain isEqualToString:@"test.packed1555.raster"] &&
               [checkpoint isEqualToData:fpp_host()]);
        error = nil;
        NSData *after = [draw pendingSnapshotWithError:&error];
        require(after != nil, error);
        assert([pending isEqualToData:after]);
        [actual appendData:after];
        [actual appendData:vertex];
    }
    require([draw endWithError:&error], error);
    p15_track_xf = NO;
    [actual appendData:p15_frame(kill && format ? 1 : 3)];
    if (kill) {
        color(4, 1, UINT32_C(0xffff0000));
        color(1, 1, format ? UINT32_C(0xffff0000) : UINT32_C(0xff0000ff));
        color(1, 4, format ? UINT32_C(0xffff0000) : UINT32_C(0xff00ff00));
    }
    /* Sampling and actual query/Current/context bytes precede route counts. */
    assert(snapshot.scale == 1);
    if (cold)
        assert(!eligible && !ramDownloads && !privateDownloads);
    else
        assert(eligible && ramDownloads == (reference ? 1u : 0u) &&
               privateDownloads == (!reference && scale > 1 ? 1u : 0u));
    if (lifecycle)
        assert(p15_xf == 3);
    if (lifecycle) {
        /* Restore discarded the original dirty target. Reestablish an actual
         * GPU writer before CPU-prewrite and before the immutable old reader.
         */
        NV2AMetalCachedSurface *source = [cache prepareSurfaceAtAddress:32768
                                                                 config:&config
                                                                  frame:2
                                                           forRendering:YES
                                                                  error:&error];
        require(source != nil, error);
        p15_seed(source, kill);
        source = nil;
        NV2AMetalCommands *reader =
            [[NV2AMetalCommands alloc] initWithDevice:cache.commands.device
                                                error:&error];
        id<MTLSharedEvent> gate = [reader.device newSharedEvent];
        require(reader && gate && [reader beginWithError:&error], error);
        [((id<MTL4CommandQueue>)[reader valueForKey:@"queue"]) waitForEvent:gate
                                                                      value:1];
        id<MTLTexture> oldTexture = snapshot.binding.texture;
        MTLPixelFormat storage = oldTexture.pixelFormat;
        NSUInteger bytesPerPixel =
            storage == MTLPixelFormatBGR5A1Unorm ? 2 : 16;
        assert(storage == MTLPixelFormatBGR5A1Unorm ||
               storage == MTLPixelFormatRGBA32Float);
        id<MTLBuffer> old =
            [reader.device newBufferWithLength:2048
                                       options:MTLResourceStorageModeShared];
        require(old && [reader addResource:old error:&error] &&
                    [reader addResource:oldTexture error:&error],
                error);
        memset(old.contents, 0xcd, old.length);
        id<MTL4ComputeCommandEncoder> e =
            [reader.commandBuffer computeCommandEncoder];
        require(e != nil, nil);
        [e copyFromTexture:oldTexture
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
        NV2AMetalSubmission *receipt = reader.lastSubmitted;
        assert(receipt && ![receipt completedWithError:&error] && !error &&
               !gate.signaledValue &&
               *(uint32_t *)old.contents == UINT32_C(0xcdcdcdcd));
        id<MTLSharedEvent> watchdog = gate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!watchdog.signaledValue)
                             watchdog.signaledValue = 2;
                       });
        require([cache prepareCPUAccessAtAddress:32768
                                          length:128
                                           write:YES
                                           error:&error],
                error);
        p15_ram(linear, YES, kill, NO);
        for (unsigned i = 0; i < 64; i++) {
            uint16_t green = cpu_to_le16(0x83e0);
            memcpy(state->vram_ptr + 32768 + i * 2, &green, 2);
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
        [actual appendData:p15_frame(3)];
        color(1, 1, UINT32_C(0xff00ff00));
        color(4, 1, UINT32_C(0xff00ff00));
        color(1, 4, UINT32_C(0xff00ff00));
        [actual
            appendData:p15_texture(fresh.binding.texture, format, kill, YES)];
        assert(![receipt completedWithError:&error] && !error &&
               !gate.signaledValue &&
               *(uint32_t *)old.contents == UINT32_C(0xcdcdcdcd));
        gate.signaledValue = 1;
        require([reader waitUntilIdleWithError:&error], error);
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                const uint8_t *raw =
                    (const uint8_t *)old.contents + y * 256 + x * bytesPerPixel;
                uint16_t expected = p15_word(x, y, kill);
                if (bytesPerPixel == 2) {
                    uint16_t word;
                    memcpy(&word, raw, 2);
                    assert((le16_to_cpu(word) & 0x7fff) == (expected & 0x7fff));
                    if (format)
                        assert((le16_to_cpu(word) >> 15) == (expected >> 15));
                } else {
                    const float *rgba = (const float *)raw;
                    float expectedRGBA[] = { ((expected >> 10) & 31) / 31.f,
                                             ((expected >> 5) & 31) / 31.f,
                                             (expected & 31) / 31.f,
                                             format ? expected >> 15 : 1 };
                    for (unsigned c = 0; c < 4; c++)
                        assert(fabsf(rgba[c] - expectedRGBA[c]) < .000001f);
                }
            }
        assert(fresh.binding.texture != snapshot.binding.texture);
    } else if (cold) {
        /* A second real Begin is a warm content hit, including the old RAM
         * sender. It still runs three fresh vertex transforms and samples. */
        [draw.reports clear];
        require([draw beginWithError:&error], error);
        pixel = [draw valueForKey:@"pixelState"];
        NV2AMetalCachedTexture *warm = [pixel.textureSnapshot textureAtIndex:0];
        require([draw endWithError:&error], error);
        [actual appendData:p15_frame(3)];
        assert(warm.binding.texture == snapshot.binding.texture);
    }
    [actual appendData:p15_texture(snapshot.binding.texture, format, kill, NO)];
    qemu_mutex_unlock(&pg->lock);
    p15_source = nil;
    return actual;
}
static void packed1555_rtt_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalTextureCache.class,
            NSSelectorFromString(@"canCapturePacked1555Surface:format:")),
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
    IMP replacements[] = { (IMP)p15_admission, (IMP)p15_download, (IMP)p15_emit,
                           (IMP)p15_epoch };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    p15_admission_original = (void *)originals[0];
    p15_download_original = (void *)originals[1];
    p15_emit_original = (void *)originals[2];
    p15_epoch_original = (void *)originals[3];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned family = 0; family < 2; family++)
            for (unsigned format = 0; format < 3; format++)
                for (unsigned scale = 1; scale <= 4; scale *= 2)
                    for (unsigned filtering = 0; filtering < 2; filtering++) {
                        BOOL lifecycle =
                            !family &&
                            ((format == 1 && scale == 2 && !filtering) ||
                             (format == 2 && scale == 4 && filtering));
                        @autoreleasepool {
                            NSData *old =
                                p15_run(family, format, scale, filtering, YES,
                                        NO, lifecycle, NO);
                            NSData *actual =
                                p15_run(family, format, scale, filtering, NO,
                                        NO, lifecycle, NO);
                            assert([old isEqualToData:actual]);
                        }
                        pairs++;
                    }
        for (unsigned format = 0; format < 3; format++) {
            @autoreleasepool {
                NSData *old =
                    p15_run(format & 1, format, 2, NO, YES, YES, NO, NO);
                NSData *actual =
                    p15_run(format & 1, format, 2, NO, NO, YES, NO, NO);
                assert([old isEqualToData:actual]);
            }
            pairs++;
        }
        @autoreleasepool {
            NSData *old = p15_run(0, 2, 1, NO, YES, NO, NO, YES);
            NSData *actual = p15_run(0, 2, 1, NO, NO, NO, NO, YES);
            assert([old isEqualToData:actual]);
            pairs++;
        }
    } @finally {
        p15_reference = p15_scope = p15_fail = p15_track_xf = NO;
        p15_source = nil;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    assert(pairs == 40);
    puts("Packed1555 RTT PGRAPH: 40 X1Z/O SZ_X1/SZ_A1/LU_A1 scale1/2/4 "
         "nearest/linear pairs, actual stored MSB/alphaKill/query, RAM poison/"
         "GPU pattern, framebuffer/Zeta/Current/constants, snapshots/Restore/"
         "late retry/CPUalias/oldreader/cold sender/warm content PASS");
    groups += pairs;
}
#endif
