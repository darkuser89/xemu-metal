/* Color storage must not inherit the interpretation of the depth attachment.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COLOR_DEPTH_IDENTITY_H
#define TEST_METAL_COLOR_DEPTH_IDENTITY_H

static void color_depth_pixels(id<MTLBuffer> vram, NSUInteger address,
                               NV2AMetalSurfaceConfig c, id<MTLBuffer> pixels)
{
    unsigned bytes = bytes_for(c);
    for (unsigned y = 0; y < (c.swizzle ? 1u : c.height); y++) {
        NSUInteger offset = c.swizzle ? 0 : y * c.pitch;
        NSUInteger length = c.width * bytes * (c.swizzle ? c.height : 1);
        assert(!memcmp((const uint8_t *)vram.contents + address + offset,
                       (const uint8_t *)pixels.contents + offset, length));
    }
}

static void color_depth_identity_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned colors = 0, depths = 0;
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
    };
    for (unsigned kind = 0; kind < 12; kind++)
        for (unsigned swizzle = 0; swizzle < 2; swizzle++)
            for (unsigned scale = 1; scale <= 2; scale++)
                for (unsigned floating = 0; floating < 2; floating++) {
                    @autoreleasepool {
                        BOOL color = kind < 10;
                        unsigned format =
                            color        ? formats[kind]
                            : kind == 10 ? NV097_SET_SURFACE_FORMAT_ZETA_Z16
                                         : NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
                        NV2AMetalSurfaceConfig c = {
                            .format = format,
                            .width = 8,
                            .height = 4,
                            .scale = scale,
                            .color = color,
                            .swizzle = swizzle,
                            .floating_depth = floating,
                        };
                        NV2AMetalSurfaceLayout layout;
                        c.pitch = 32;
                        require(nv2a_metal_surface_layout(&c, &layout, &error),
                                error);
                        NV2AMetalCommands *commands =
                            [[NV2AMetalCommands alloc] initWithError:&error];
                        require(commands != nil, error);
                        id<MTLBuffer> vram = [device
                            newBufferWithLength:4096
                                        options:MTLResourceStorageModeShared];
                        assert(vram);
                        memset(vram.contents, 0x31, vram.length);
                        NV2AMetalSurfaceCache *cache =
                            [[NV2AMetalSurfaceCache alloc]
                                initWithCommands:commands
                                            vram:vram
                                    didWriteVRAM:nil
                                           error:&error];
                        require(cache != nil, error);
                        NV2AMetalCachedSurface *first =
                            [cache prepareSurfaceAtAddress:512
                                                    config:&c
                                                     frame:0
                                                     error:&error];
                        require(first != nil, error);
                        clear_surface(cache, first,
                                      MTLClearColorMake(.25, .5, .75, 1), .5,
                                      0x5a);
                        id<MTLBuffer> pixels = gpu_pixels(cache, first);
                        uint64_t generation = first.generation, version;
                        require(
                            [cache
                                sourceVersionAtAddress:512
                                                length:layout.reservation_length
                                               version:&version
                                                 error:&error],
                            error);
                        assert(first.dirty && !cache.recording);
                        NV2AMetalSubmission *submission =
                            commands.lastSubmitted;
                        c.floating_depth = !floating;
                        NV2AMetalCachedSurface *second =
                            [cache prepareSurfaceAtAddress:512
                                                    config:&c
                                                     frame:1
                                              forRendering:NO
                                                     error:&error];
                        require(second != nil, error);
                        if (color) {
                            assert(second == first && first.valid &&
                                   first.dirty &&
                                   first.generation == generation &&
                                   cache.count == 1 && !cache.recording &&
                                   commands.lastSubmitted == submission);
                            uint64_t afterVersion;
                            require(
                                [cache
                                    sourceVersionAtAddress:512
                                                    length:
                                                        layout
                                                            .reservation_length
                                                   version:&afterVersion
                                                     error:&error],
                                error);
                            assert(afterVersion == version);
                            const uint8_t *raw = vram.contents;
                            for (NSUInteger i = 0; i < vram.length; i++)
                                assert(raw[i] == 0x31);
                            /* An unsubmitted write across the same metadata
                             * change must still roll back its own generation.
                             */
                            second = [cache prepareSurfaceAtAddress:512
                                                             config:&c
                                                              frame:2
                                                              error:&error];
                            require(second != nil, error);
                            clear_surface(cache, second,
                                          MTLClearColorMake(1, 0, 0, 1), 0, 0);
                            assert(first.generation != generation);
                            [cache cancel];
                            assert(first.valid && first.dirty &&
                                   first.generation == generation);
                            require([cache
                                        prepareSurfaceAtAddress:512
                                                         config:&c
                                                          frame:3
                                                          error:&error] != nil,
                                    error);
                            id<MTLBuffer> after = gpu_pixels(cache, first);
                            assert(after.length == pixels.length &&
                                   !memcmp(after.contents, pixels.contents,
                                           pixels.length));
                            require([cache flushWithError:&error], error);
                            color_depth_pixels(vram, 512, c, pixels);
                            require([cache discardForRestoreWithError:&error],
                                    error);
                            assert(!first.valid && !cache.count);
                            NV2AMetalCachedSurface *restored =
                                [cache prepareSurfaceAtAddress:512
                                                        config:&c
                                                         frame:4
                                                         error:&error];
                            require(restored != nil, error);
                            assert(restored != first &&
                                   restored.generation != generation);
                            after = gpu_pixels(cache, restored);
                            assert(after.length == pixels.length &&
                                   !memcmp(after.contents, pixels.contents,
                                           pixels.length));
                            colors++;
                        } else {
                            assert(second != first && !first.valid &&
                                   second.valid);
                            /* A real depth reinterpretation still retires and
                             * preserves its previous guest representation. */
                            color_depth_pixels(vram, 512, c, pixels);
                            depths++;
                        }
                        require([cache flushWithError:&error], error);
                    }
                }
    assert(colors == 80 && depths == 16);
    puts("Color/depth identity:80 color cases reuse dirty storage with zero "
         "replacement/upload/download/submission; bit-exact pixels, "
         "generations, "
         "versions, cancel/restore;16 depth reinterpretations still retire; "
         "10 formats,pitched/swizzled,scale1/2,both depth modes PASS");
}
#endif
