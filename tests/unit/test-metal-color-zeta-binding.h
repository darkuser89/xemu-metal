/* Depth-only state changes retain the PGRAPH color binding and guest bytes.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COLOR_ZETA_BINDING_H
#define TEST_METAL_COLOR_ZETA_BINDING_H
static void color_zeta_binding_tests(NV2AMetalPGRAPHSurfaces *surfaces)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    unsigned cases = 0;
    require([surfaces flushWithError:&error], error);
    for (unsigned zeta = 0; zeta < 2; zeta++)
        for (unsigned floating = 0; floating < 2; floating++) {
            memset(state->vram_ptr, 0x31, 65536);
            pg->surface_scale_factor = 2;
            pg->surface_type = NV097_SET_SURFACE_FORMAT_TYPE_PITCH;
            pg->surface_shape = (SurfaceShape){
                .color_format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                .zeta_format = zeta ? NV097_SET_SURFACE_FORMAT_ZETA_Z24S8
                                    : NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                .clip_width = 8,
                .clip_height = 4,
            };
            pg->surface_color.offset = pg->surface_zeta.offset = 64;
            pg->surface_color.pitch = pg->surface_zeta.pitch = 40;
            pg->regs_[NV_PGRAPH_SETUPRASTER] =
                floating ? NV_PGRAPH_SETUPRASTER_Z_FORMAT : 0;
            require([surfaces prepareColor:YES zeta:YES error:&error], error);
            NV2AMetalCachedSurface *color = surfaces.color,
                                   *depth = surfaces.zeta;
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = color.transfer.texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1);
            id<MTL4RenderCommandEncoder> encoder =
                [surfaces.cache.commands.commandBuffer
                    renderCommandEncoderWithDescriptor:pass];
            assert(encoder);
            [encoder barrierAfterQueueStages:MTLStageAll
                                beforeStages:MTLStageAll
                           visibilityOptions:MTL4VisibilityOptionDevice];
            [encoder barrierAfterStages:MTLStageAll
                      beforeQueueStages:MTLStageAll
                      visibilityOptions:MTL4VisibilityOptionDevice];
            [encoder endEncoding];
            require([surfaces markColorWritten:YES
                                   zetaWritten:NO
                                         error:&error] &&
                        [surfaces.cache submitWithError:&error] &&
                        [surfaces.cache waitUntilIdleWithError:&error],
                    error);
            uint64_t generation = color.generation;
            unsigned writes = vga_dirty;
            assert(color.dirty && !depth.dirty);
            pg->regs_[NV_PGRAPH_SETUPRASTER] ^= NV_PGRAPH_SETUPRASTER_Z_FORMAT;
            require([surfaces prepareColor:YES
                                      zeta:YES
                              forRendering:NO
                                     error:&error],
                    error);
            assert(surfaces.color == color && color.valid && color.dirty &&
                   color.generation == generation && !depth.valid &&
                   surfaces.zeta != depth && surfaces.zeta.valid &&
                   vga_dirty == writes && state->vram_ptr[576] == 0x31);
            NV2AMetalSurfaceBindings bindings = surfaces.captureBindings;
            assert(!bindings.color.config.floating_depth &&
                   bindings.zeta.config.floating_depth == !floating);
            /* Historical packets may contain the irrelevant color flag.
             * Decode them unchanged, then reuse the current color storage. */
            bindings.color.config.floating_depth = YES;
            NSData *packet = nv2a_metal_surface_bindings_encode(bindings);
            NV2AMetalSurfaceBindings decoded;
            require(
                nv2a_metal_surface_bindings_decode(packet, &decoded, &error),
                error);
            assert(decoded.color.config.floating_depth);
            require([surfaces prepareBindings:decoded
                                 forRendering:NO
                                        error:&error],
                    error);
            assert(
                surfaces.color == color && color.dirty &&
                color.generation == generation && vga_dirty == writes &&
                [packet isEqual:nv2a_metal_surface_bindings_encode(decoded)]);
            require([surfaces flushWithError:&error], error);
            for (unsigned y = 0; y < 4; y++)
                for (unsigned x = 0; x < 8; x++)
                    assert((uint32_t)ldl_le_p(state->vram_ptr + 576 + y * 40 +
                                              x * 4) == 0xffff00ff);
            cases++;
        }
    assert(cases == 4);
    puts(
        "Color/zeta PGRAPH binding:4 Z16/Z24S8 fixed/float transitions; "
        "dirty color identity/generation/guest pixels retained,depth replaced, "
        "canonical color captures and legacy packet roundtrip PASS");
}
#endif
