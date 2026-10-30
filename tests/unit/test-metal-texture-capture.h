/* Frozen texture hits hold resources without creating a GPU transaction.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TEXTURE_CAPTURE_H
#define TEST_METAL_TEXTURE_CAPTURE_H
static void texture_capture_tests(void)
{
    NSError *error = nil;
    only_stage0();
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 4, 4, 64, false);
    NSUInteger address = dma_a.address + 64;
    cpu_write(address, 16);
    memset(state->vram_ptr + address, 33, 16);
    NV2AMetalPGRAPHTextureSnapshot *old = prepare();
    assert(surfaces.commands.commandBuffer && surfaces.recording);
    finish();
    require([old validateCompletedWithError:&error], error);
    id<MTLTexture> texture = [old textureAtIndex:0].binding.texture;
    uint64_t serial = surfaces.commands.recordingSerial;
    NSUInteger sections = surfaces.commands.sealedBufferCount;
    for (unsigned i = 0; i < 128; i++) {
        state->pgraph.regs_[NV_PGRAPH_BORDERCOLOR0] = i;
        NV2AMetalPGRAPHTextureSnapshot *hit = prepare();
        require([hit validateCompletedWithError:&error], error);
        assert([hit textureAtIndex:0].binding.texture == texture);
        require([surfaces checkpointWithError:&error], error);
        assert(surfaces.commands.recordingSerial == serial &&
               surfaces.commands.sealedBufferCount == sections &&
               !surfaces.commands.commandBuffer && !surfaces.recording);
    }
    [surfaces cancel];
    require([old validateCompletedWithError:&error], error);
    [adapter.cache removeAllTextures];
    assert(!adapter.cache.count &&
           [old textureAtIndex:0].binding.texture == texture);
    id<MTLBuffer> pixels = read_texture(old, 0);
    finish();
    pixel(pixels, 4, 0, 0, 33 / 255.f, 33 / 255.f, 33 / 255.f, 1);
    cpu_write(address, 16);
    memset(state->vram_ptr + address, 77, 16);
    NV2AMetalPGRAPHTextureSnapshot *changed = prepare();
    assert(surfaces.commands.commandBuffer &&
           [changed textureAtIndex:0].binding.texture != texture);
    finish();
    require([changed validateCompletedWithError:&error], error);
    pixels = read_texture(changed, 0);
    finish();
    pixel(pixels, 4, 0, 0, 77 / 255.f, 77 / 255.f, 77 / 255.f, 1);
    pixels = read_texture(old, 0);
    finish();
    pixel(pixels, 4, 0, 0, 33 / 255.f, 33 / 255.f, 33 / 255.f, 1);
    registers(1, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 4, 4, 4096, false);
    cpu_write(dma_a.address + 4096, 16);
    memset(state->vram_ptr + dma_a.address + 4096, 99, 16);
    NV2AMetalPGRAPHTextureSnapshot *mixed = prepare();
    NV2AMetalSurfaceRecording *pending = surfaces.recording;
    id recording = surfaces.commands.commandBuffer;
    serial = surfaces.commands.recordingSerial;
    assert(recording && pending);
    NV2AMetalPGRAPHTextureSnapshot *hit = prepare();
    assert(surfaces.commands.commandBuffer == recording &&
           surfaces.recording == pending &&
           surfaces.commands.recordingSerial == serial && !pending.submitted &&
           !pending.cancelled &&
           [hit textureAtIndex:0].binding.texture ==
               [changed textureAtIndex:0].binding.texture);
    [surfaces cancel];
    assert(pending.cancelled && ![mixed validateCompletedWithError:&error]);
    require([changed validateCompletedWithError:&error] &&
                [old validateCompletedWithError:&error],
            error);
    mixed = prepare();
    assert(surfaces.commands.commandBuffer);
    finish();
    require([mixed validateCompletedWithError:&error], error);
    pixels = read_texture(mixed, 1);
    finish();
    pixel(pixels, 4, 0, 0, 99 / 255.f, 99 / 255.f, 99 / 255.f, 1);
    only_stage0();
    stage_roundtrip(old);
    stage_roundtrip(changed);
    checks++;
    puts("Warm texture capture:128 binding-policy hits use zero native "
         "recordings/sections;"
         "frozen GPU pixels survive cancellation,LRU eviction and CPU source "
         "changes;"
         "mixed pending stage preserves recording identity,cancel/retry and "
         "snapshot roundtrip PASS");
}
#endif
