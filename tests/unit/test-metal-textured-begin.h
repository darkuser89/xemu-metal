/* Warm texture-state capture must not consume an empty native section.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TEXTURED_BEGIN_H
#define TEST_METAL_TEXTURED_BEGIN_H
static void textured_begin_tests(void)
{
    NSError *error = nil;
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8
    };
    unsigned captures = 0;
    for (unsigned mode = 0; mode < 4; mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        BOOL rtt = mode == 3;
        unsigned format = formats[rtt ? 2 : mode];
        unsigned bpp = mode == 0 ? 1 : mode == 1 ? 2 : 4;
        pg->draw_arrays_length = pg->inline_elements_length =
            pg->inline_buffer_length = pg->inline_array_length = 0;
        texture_registers(format, 8 * bpp);
        if (rtt)
            pg->dma_a = 16;
        unsigned address = rtt ? 1024 : 32768;
        cpu_write(address, 64 * bpp);
        memset(state->vram_ptr + address, 0x33, 64 * bpp);
        qemu_mutex_lock(&pg->lock);
        require([draw beginWithError:&error] && [draw endWithError:&error],
                error);
        NV2AMetalSurfaceCache *cache = surfaces.cache;
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        for (unsigned i = 0; i < 64; i++) {
            uint64_t serial = cache.commands.recordingSerial;
            NSUInteger sections = cache.commands.sealedBufferCount;
            require([draw beginWithError:&error], error);
            assert(cache.commands.recordingSerial == serial &&
                   cache.commands.sealedBufferCount == sections &&
                   !cache.commands.commandBuffer && !cache.recording);
            require([draw endWithError:&error], error);
            assert(cache.commands.recordingSerial == serial &&
                   cache.commands.sealedBufferCount == sections &&
                   !cache.commands.commandBuffer && !cache.recording);
            captures++;
        }
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        qemu_mutex_unlock(&pg->lock);
    }
    assert(captures == 256);
    groups++;
    puts("Warm textured Begin:256 Y8/R565/A8R8G8B8/RTT captures;zero native "
         "recording/"
         "section changes at Begin/empty End,real cold uploads "
         "preserved PASS");
}
#endif
