/* Byte surfaces versus the existing surface-download/texture-decode path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BYTE_RTT_H
#define TEST_METAL_BYTE_RTT_H

static void byte_rtt_tests(void)
{
    const struct {
        unsigned format, bytes, storage;
        BOOL linear;
    } cases[] = {
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 1, 14, YES },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8, 1, 15, YES },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8, 1, 16, YES },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8, 1, 14, NO },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8, 1, 15, NO },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8, 1, 16, NO },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8, 2, 17, YES },
        { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8, 2, 18, YES },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8, 2, 17, NO },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8, 2, 18, NO },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8, 2, 19, NO },
    };
    NSError *error = nil;
    NV2AMetalTextureUpload *decoder =
        [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                 error:&error];
    require(decoder != nil, error);
    unsigned captures = 0;
    NSUInteger lanes = 0;
    for (unsigned test = 0; test < sizeof(cases) / sizeof(cases[0]); test++) {
        for (unsigned scale = 1; scale <= 2; scale++) {
            @autoreleasepool {
                unsigned bytes = cases[test].bytes;
                unsigned side = bytes == 1 ? 16 : 256;
                unsigned pitch = side * bytes + (cases[test].linear ? 16 : 0);
                NSUInteger length =
                    cases[test].linear ? pitch * side : side * side * bytes;
                cpu_write(0, length);
                memset(surfaces.vram.contents, 0xd3, length);
                uint8_t *raw = surfaces.vram.contents;
                for (unsigned y = 0; y < side; y++)
                    for (unsigned x = 0; x < side; x++) {
                        uint16_t word = y * side + x;
                        NSUInteger offset = cases[test].linear ?
                                                y * pitch + x * bytes :
                                                (y * side + x) * bytes;
                        memcpy(raw + offset, &word, bytes);
                    }
                [textures removeAllTextures];
                NV2AMetalSurfaceConfig config = {
                    .format = bytes == 1 ?
                                  NV097_SET_SURFACE_FORMAT_COLOR_LE_B8 :
                                  NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
                    .width = side,
                    .height = side,
                    .pitch = pitch,
                    .scale = scale,
                    .color = YES,
                    .swizzle = !cases[test].linear,
                };
                NV2AMetalCachedSurface *surface =
                    [surfaces prepareSurfaceAtAddress:0
                                               config:&config
                                                frame:1
                                                error:&error];
                require(surface != nil, error);
                /* A real GPU store leaves every source word in the exhaustive
                 * set while making this a dirty render target. */
                NV2AMetalClearConfig zero = {
                    .parameter = NV097_CLEAR_SURFACE_COLOR,
                    .rect = { 0, 0, scale, scale },
                };
                clear(surface, zero);
                NV2AMetalTextureSource src = {
                    .shape = { .format = cases[test].format,
                               .dimension = 2,
                               .width = side,
                               .height = side,
                               .depth = 1,
                               .levels = 1,
                               .pitch = pitch },
                    .address = 0,
                    .length = length,
                };
                unsigned before = notifications;
                NV2AMetalCachedTexture *captured = prepare(src);
                assert(captured.scale == scale &&
                       captured.rectangle == cases[test].linear &&
                       captured.binding.texture.pixelFormat ==
                           (bytes == 1 ? MTLPixelFormatR8Unorm :
                                         MTLPixelFormatRG8Unorm));
                assert(prepare(src) == captured);
                id<MTLBuffer> actual = test_metal_read_2d_texture(
                    commands, captured.binding.texture, 0);
                finish();
                require([captured validateCompletedWithError:&error], error);
                assert(surface.dirty && notifications == before);
                assert(![textures valueForKey:@"capture"] &&
                       ![textures valueForKey:@"arguments"]);
                NSData *snapshot = nv2a_metal_texture_snapshot(
                    captured.binding.texture, commands, &error);
                require(snapshot != nil, error);
                unsigned width = side * scale;
                assert(snapshot.length == 40 + width * width * bytes &&
                       ((const uint8_t *)snapshot.bytes)[39] ==
                           cases[test].storage);
                id<MTLTexture> restored =
                    nv2a_metal_texture_restore(snapshot, commands, &error);
                require(restored != nil, error);
                NSData *resaved =
                    nv2a_metal_texture_snapshot(restored, commands, &error);
                require(resaved != nil, error);
                assert([snapshot isEqualToData:resaved]);

                /* Independent reference: publish the dirty surface to guest
                 * layout, then use the unchanged ordinary texture decoder. */
                require([surfaces downloadSurfacesForCPU:@[ surface ]
                                                   error:&error],
                        error);
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalTextureUploadResult *reference =
                    [decoder encodeData:surfaces.vram
                                 offset:0
                                palette:nil
                          paletteOffset:0
                          paletteLength:0
                                  shape:&src.shape
                               commands:commands
                                  error:&error];
                require(reference != nil, error);
                id<MTLBuffer> expected =
                    test_metal_read_2d_texture(commands, reference.texture, 0);
                id<MTLBuffer> roundtrip =
                    test_metal_read_2d_texture(commands, restored, 0);
                require([commands submitWithError:&error] &&
                            [commands waitUntilIdleWithError:&error],
                        error);
                NSUInteger row = (width * 16 + 255) & ~(NSUInteger)255;
                NSUInteger refRow = (side * 16 + 255) & ~(NSUInteger)255;
                for (unsigned y = 0; y < width; y++)
                    for (unsigned x = 0; x < width; x++) {
                        const uint8_t *a =
                            (const uint8_t *)actual.contents + y * row + x * 16;
                        const uint8_t *b = (const uint8_t *)expected.contents +
                                           (y / scale) * refRow +
                                           (x / scale) * 16;
                        const uint8_t *c = (const uint8_t *)roundtrip.contents +
                                           y * row + x * 16;
                        assert(!memcmp(a, b, 16) && !memcmp(a, c, 16));
                        lanes += 4;
                    }
                /* Later GPU stores must neither mutate the old capture nor
                 * reuse its cache entry for the new generation. */
                require([surfaces prepareSelectedSurface:surface
                                      discardingContents:NO
                                                   error:&error],
                        error);
                NV2AMetalClearConfig overwrite = {
                    .parameter = NV097_CLEAR_SURFACE_COLOR,
                    .rect = { 0, 0, scale, scale },
                    .uniforms = { .color = { 17.f / 255, 203.f / 255, 0, 0 } },
                };
                clear(surface, overwrite);
                NV2AMetalCachedTexture *fresh = prepare(src);
                assert(fresh.binding.texture != captured.binding.texture);
                id<MTLBuffer> unchanged = test_metal_read_2d_texture(
                    commands, captured.binding.texture, 0);
                id<MTLBuffer> changed = test_metal_read_2d_texture(
                    commands, fresh.binding.texture, 0);
                finish();
                assert(surface.dirty);
                for (unsigned y = 0; y < width; y++) {
                    assert(!memcmp((uint8_t *)unchanged.contents + y * row,
                                   (uint8_t *)actual.contents + y * row,
                                   width * 16));
                    for (unsigned x = 0; x < width; x++) {
                        BOOL different =
                            memcmp(
                                (uint8_t *)changed.contents + y * row + x * 16,
                                (uint8_t *)actual.contents + y * row + x * 16,
                                16) != 0;
                        assert(different == (x < scale && y < scale));
                    }
                }
                captures++;
            }
        }
    }
    assert(captures == 22);
    printf("Byte RTT:22 dirty surface captures/cache hits/restore-resave "
           "cycles, %lu bit-exact GPU channels versus surface download + "
           "ordinary decode; B8/G8B8,all byte/word values,11 formats,"
           "linear padded pitch/swizzle,scale1/2,old/new isolation,"
           "zero capture shader PASS\n",
           (unsigned long)lanes);
}

static void byte_rtt_fallback_tests(void)
{
    for (unsigned mode = 0; mode < 4; mode++) {
        NSError *error = nil;
        cpu_write(0, 1024);
        memset(surfaces.vram.contents, 0, 1024);
        [textures removeAllTextures];
        NV2AMetalSurfaceConfig config = {
            .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
            .width = 16,
            .height = 16,
            .pitch = 16,
            .scale = 2,
            .color = YES,
            .swizzle = mode == 1,
        };
        NV2AMetalCachedSurface *surface =
            [surfaces prepareSurfaceAtAddress:0
                                       config:&config
                                        frame:1
                                        error:&error];
        require(surface != nil, error);
        NV2AMetalClearConfig zero = {
            .parameter = NV097_CLEAR_SURFACE_COLOR,
            .rect = { 0, 0, 32, 32 },
        };
        clear(surface, zero);
        NV2AMetalTextureSource src = {
            .shape = { .format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8,
                       .dimension = 2,
                       .width = mode == 3 ? 8 : 16,
                       .height = 16,
                       .depth = 1,
                       .levels = 1,
                       .pitch = mode == 2 ? 32 : 16,
                       .signed_channels = mode == 0 ? 15 : 0 },
            .length = mode == 2 ? 512 : 256,
        };
        unsigned before = notifications;
        if (mode == 0) {
            NV2AMetalSamplerConfig sampler = policy();
            NV2AMetalCachedTexture *invalid = [textures prepareSource:&src
                                                              sampler:&sampler
                                                                frame:1
                                                                error:&error];
            /* Signed Y8 is rejected by the existing layout validator before
             * either an RTT capture or an ordinary decode can be recorded. */
            assert(!invalid && error && notifications == before);
            [surfaces cancel];
            continue;
        }
        NV2AMetalCachedTexture *texture = prepare(src);
        assert(texture.scale == 1);
        finish();
        assert(!surface.dirty && notifications > before);
    }
    puts("Byte RTT controls:signed Y8 remains rejected; layout,pitch and size "
         "mismatches retain ordinary download/decode PASS");
}
#endif
