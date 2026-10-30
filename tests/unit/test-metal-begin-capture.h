/* Attachment capture must preserve real draws and intervening guest writes.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BEGIN_CAPTURE_H
#define TEST_METAL_BEGIN_CAPTURE_H
static void begin_capture_tests(void)
{
    NSError *error = nil;
    unsigned pairs = 0, warm = 0;
    for (unsigned attachments = 0; attachments < 3; attachments++)
        for (unsigned z24 = 0; z24 < 2; z24++)
            for (unsigned swizzle = 0; swizzle < 2; swizzle++)
                for (unsigned scale = 1; scale <= 2; scale++) {
                    uint8_t pixels[512];
                    float current[4];
                    for (unsigned active = 0; active < 2; active++) {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        if (attachments == 1)
                            pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
                        if (attachments)
                            pg->regs_[NV_PGRAPH_CONTROL_0] |=
                                NV_PGRAPH_CONTROL_0_ZENABLE |
                                NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16;
                        pg->surface_shape.zeta_format =
                            z24 ? NV097_SET_SURFACE_FORMAT_ZETA_Z24S8 :
                                  NV097_SET_SURFACE_FORMAT_ZETA_Z16;
                        pg->surface_zeta.pitch = z24 ? 32 : 16;
                        pg->surface_scale_factor = scale;
                        if (swizzle) {
                            pg->surface_type =
                                NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
                            pg->surface_shape.log_width =
                                pg->surface_shape.log_height = 3;
                        }
                        qemu_mutex_lock(&pg->lock);
                        for (unsigned i = 0; i < 3; i++) {
                            uint64_t serial =
                                surfaces.cache.commands.recordingSerial;
                            NSUInteger sections =
                                surfaces.cache.commands.sealedBufferCount;
                            if (active) {
                                require([draw beginWithError:&error], error);
                                if (i) {
                                    assert(surfaces.cache.commands
                                                   .recordingSerial == serial &&
                                           surfaces.cache.commands
                                                   .sealedBufferCount ==
                                               sections);
                                    warm++;
                                }
                            }
                            if (i == 1) {
                                /* Hooked writes after Begin must invalidate the
                                 * cached pixels before End prepares the draw.
                                 */
                                cpu_write(1024, 256);
                                memset(state->vram_ptr + 1024, 0x5a, 256);
                                cpu_write(4096, 256);
                                memset(state->vram_ptr + 4096, 0xab, 256);
                            }
                            require(active ? [draw endWithError:&error] :
                                             [draw drawWithError:&error],
                                    error);
                            assert(pg->draw_time == (int)i + 1);
                        }
                        qemu_mutex_unlock(&pg->lock);
                        read_vram(1024, 256);
                        read_vram(4096, 256);
                        if (!active) {
                            memcpy(pixels, state->vram_ptr + 1024, 256);
                            memcpy(pixels + 256, state->vram_ptr + 4096, 256);
                            memcpy(current,
                                   pg->vertex_attributes[0].inline_value, 16);
                        } else {
                            assert(
                                !memcmp(pixels, state->vram_ptr + 1024, 256) &&
                                !memcmp(pixels + 256, state->vram_ptr + 4096,
                                        256) &&
                                !memcmp(current,
                                        pg->vertex_attributes[0].inline_value,
                                        16));
                            pairs++;
                        }
                    }
                }
    assert(pairs == 24 && warm == 48);
    groups++;
    puts("Begin attachment capture:24 exact standalone/Begin-End "
         "color/depth/Current "
         "pairs;color-only,zeta-only,both,Z16/Z24S8,linear/swizzled,scale1/"
         "2;48 warm Begins without new sections,CPU writes between Begin/End "
         "uploaded before raster PASS");
}
#endif
