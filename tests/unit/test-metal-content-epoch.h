/* Bounded raw-source reuse across page versions; no VM, window or app.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CONTENT_EPOCH_H
#define TEST_METAL_CONTENT_EPOCH_H

static NV2AMetalCachedTexture *epoch_capture(NV2AMetalTextureSource c,
                                             NV2AMetalSamplerConfig sampler) {
    NSError *error = nil;
    BOOL collected = YES;
    NV2AMetalCachedTexture *t = [textures captureSource:&c
                                                sampler:&sampler
                                                  frame:1
                                      collectedFeedback:&collected
                                                  error:&error];
    require(t != nil, error);
    return t;
}

static void epoch_neighbor(NSUInteger address) {
    NSError *error = nil;
    BOOL completed = NO;
    require([surfaces tryIdleCPUAccessAtAddress:address
                                         length:1
                                          write:YES
                                      completed:&completed
                                          error:&error],
            error);
    assert(completed);
    ((uint8_t *)surfaces.vram.contents)[address] ^= 0x5a;
}

static void epoch_pixels(NV2AMetalCachedTexture *t, float r, float g, float b) {
    NSError *error = nil;
    id<MTLBuffer> out = read_texture(t);
    finish();
    require([t validateCompletedWithError:&error], error);
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++)
            color_at(out, 4, x, y, r, g, b, 1);
}

static void epoch_gpu_write(NSUInteger address, uint32_t pixel) {
    NSError *error = nil;
    uint32_t data[16];
    for (unsigned i = 0; i < 16; i++)
        data[i] = pixel;
    require([surfaces prepareGPUWriteAtAddress:address
                                        length:sizeof(data)
                                         error:&error],
            error);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:data
                                     length:sizeof(data)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    require([commands addResource:input error:&error] &&
                [commands addResource:surfaces.vram error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:input
               sourceOffset:0
                   toBuffer:surfaces.vram
          destinationOffset:address
                       size:sizeof(data)];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
}

/* Host component costs only: cold copies, version misses and ordinary hits.
 * The same test can be linked with comparison disabled as a control. */
static void texture_content_epoch_costs(void) {
    NSError *error = nil;
    surfaces.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
      assert(address < surfaces.vram.length &&
             length <= surfaces.vram.length - address);
    };
    NV2AMetalSamplerConfig sampler = policy();
    cpu_write(0, surfaces.vram.length);
    uint32_t *pixels = surfaces.vram.contents;
    for (NSUInteger i = 0; i < surfaces.vram.length / 4; i++)
        pixels[i] = 0xff030201;
    const unsigned sizes[] = {1024, 16384, 65536};
    for (unsigned size = 0; size < 3; size++) {
        NV2AMetalTextureSource c = {
            .address = 64,
            .length = sizes[size],
            .shape = {.format =
                          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
                      .dimension = 2,
                      .width = 128,
                      .height = sizes[size] / 512,
                      .depth = 1,
                      .levels = 1,
                      .pitch = 512}};
        epoch_capture(c, sampler);
        finish();
        double cold[7], changed[7], hits[7];
        unsigned uploads = 0;
        for (unsigned sample = 0; sample < 9; sample++) {
            [textures removeAllTextures];
            double start = hit_clock();
            NV2AMetalCachedTexture *last = epoch_capture(c, sampler);
            double coldTime = hit_clock() - start;
            uploads = 0;
            start = hit_clock();
            for (unsigned n = 0; n < 32; n++) {
                @autoreleasepool {
                    epoch_neighbor(c.address + c.length);
                    NV2AMetalCachedTexture *next = epoch_capture(c, sampler);
                    uploads += next.binding.texture != last.binding.texture;
                    last = next;
                }
            }
            double changedTime = hit_clock() - start;
            start = hit_clock();
            for (unsigned n = 0; n < 64; n++)
                assert(epoch_capture(c, sampler) == last);
            double hitTime = hit_clock() - start;
            if (sample >= 2) {
                cold[sample - 2] = coldTime;
                changed[sample - 2] = changedTime;
                hits[sample - 2] = hitTime;
            }
            id<MTLBuffer> out = read_texture(last);
            finish();
            require([last validateCompletedWithError:&error], error);
            color_at(out, 128, 0, 0, 3.f / 255, 2.f / 255, 1.f / 255, 1);
        }
        qsort(cold, 7, sizeof(*cold), hit_compare);
        qsort(changed, 7, sizeof(*changed), hit_compare);
        qsort(hits, 7, sizeof(*hits), hit_compare);
        printf("Texture content epoch cost bytes=%u: cold=%.6f ms, "
               "32 versions=%.6f ms (%u new uploads), 64 hits=%.6f ms; "
               "median 7 samples after 2 warmups, host component only\n",
               sizes[size], cold[3], changed[3], uploads, hits[3]);
    }
    [textures removeAllTextures];
}

static void texture_content_epoch_tests(void) {
    NSError *error = nil;
    NV2AMetalSurfaceCache *savedSurfaces = surfaces;
    NV2AMetalTextureCache *savedTextures = textures;
    id<MTLBuffer> ram =
        [commands.device newBufferWithLength:8 * 1024 * 1024
                                     options:MTLResourceStorageModeShared];
    assert(ram);
    memset(ram.contents, 0, ram.length);
    surfaces = [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                          vram:ram
                                                  didWriteVRAM:nil
                                                         error:&error];
    require(surfaces != nil, error);
    surfaces.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
      assert(address < ram.length && length <= ram.length - address);
    };
    textures = [[NV2AMetalTextureCache alloc] initWithSurfaces:surfaces
                                                         error:&error];
    require(textures != nil, error);
    NV2AMetalSamplerConfig sampler = policy();
    NV2AMetalTextureSource c =
        source(64, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    cpu_write(c.address, c.length);
    uint32_t *pixels = (uint32_t *)((uint8_t *)ram.contents + c.address);
    for (unsigned i = 0; i < 16; i++)
        pixels[i] = 0xff030201;
    NV2AMetalCachedTexture *first = epoch_capture(c, sampler);
    NV2AMetalSurfaceRecording *token = first.producerRecording;
    uint64_t serial = commands.recordingSerial;
    NSUInteger reads = [[surfaces valueForKey:@"pendingReads"] length];
    for (unsigned i = 0; i < 32; i++) {
        epoch_neighbor(128);
        assert(epoch_capture(c, sampler) == first);
        assert(commands.recordingSerial == serial &&
               surfaces.recording == token && !token.completed &&
               !token.cancelled &&
               [[surfaces valueForKey:@"pendingReads"] length] == reads);
    }
    NV2AMetalSamplerConfig linear = sampler;
    linear.filter = 2 << 16 | 2 << 24;
    epoch_neighbor(128);
    NV2AMetalCachedTexture *rebound = epoch_capture(c, linear);
    assert(rebound != first && rebound.binding != first.binding &&
           rebound.binding.texture == first.binding.texture &&
           rebound.binding.sampling.mag_linear &&
           !first.binding.sampling.mag_linear);
    epoch_neighbor(128);
    assert(epoch_capture(c, linear) == rebound);
    require([surfaces submitWithError:&error], error);
    assert(token.submitted && !token.completed && !surfaces.recording);
    serial = commands.recordingSerial;
    epoch_neighbor(128);
    assert(epoch_capture(c, linear) == rebound && !surfaces.recording &&
           commands.recordingSerial == serial && !token.completed);
    /* A normal consumer still opens/owns its recording after a reused capture.
     */
    assert([textures prepareSource:&c sampler:&linear frame:1
                             error:&error] == rebound);
    assert(surfaces.recording && surfaces.recording != token);
    epoch_pixels(rebound, 3.f / 255, 2.f / 255, 1.f / 255);

    /* A retired source has lost its write guards: never compare it on CPU. */
    epoch_neighbor(128);
    NV2AMetalCachedTexture *fresh = epoch_capture(c, linear);
    assert(fresh.binding.texture != first.binding.texture);
    BOOL completed = YES;
    require([surfaces tryIdleCPUAccessAtAddress:c.address
                                         length:4
                                          write:YES
                                      completed:&completed
                                          error:&error],
            error);
    assert(!completed);
    cpu_write(c.address, c.length);
    assert(fresh.producerRecording.completed);
    for (unsigned i = 0; i < 16; i++)
        pixels[i] = 0xff060504;
    fresh = epoch_capture(c, sampler);
    assert(fresh.binding.texture != first.binding.texture);
    epoch_pixels(fresh, 6.f / 255, 5.f / 255, 4.f / 255);

    /* A pending GPU writer must bypass raw comparison even though the old
     * upload's source-read token is still live. Both GPU results stay intact.
     */
    first = epoch_capture(c, sampler);
    epoch_neighbor(128);
    first = epoch_capture(c, sampler);
    token = first.producerRecording;
    epoch_gpu_write(c.address, 0xff090807);
    epoch_neighbor(128);
    assert(!token.completed && !token.cancelled);
    fresh = epoch_capture(c, sampler);
    assert(fresh.binding.texture != first.binding.texture);
    id<MTLBuffer> before = read_texture(first), after = read_texture(fresh);
    finish();
    color_at(before, 4, 0, 0, 6.f / 255, 5.f / 255, 4.f / 255, 1);
    color_at(after, 4, 0, 0, 9.f / 255, 8.f / 255, 7.f / 255, 1);

    /* Incompatible dirty surface aliases download through the ordinary path;
     * compatible RTT captures also stay out of the raw-source index. */
    first = epoch_capture(c, sampler);
    epoch_neighbor(128);
    first = epoch_capture(c, sampler);
    NV2AMetalCachedSurface *s = surface(c.address, 8, YES, 4, 1);
    clear(s, (NV2AMetalClearConfig){.parameter = NV097_CLEAR_SURFACE_COLOR,
                                    .rect = {0, 0, 4, 4},
                                    .uniforms = {.color = {0, 1, 0, 1}}});
    NV2AMetalTextureSource alias = c;
    alias.shape.width = 2;
    alias.shape.pitch = 8;
    alias.length = 32;
    NV2AMetalCachedTexture *narrow = epoch_capture(alias, sampler);
    fresh = epoch_capture(c, sampler);
    assert(fresh.binding.texture != first.binding.texture);
    before = read_texture(narrow);
    after = read_texture(fresh);
    finish();
    color_at(before, 2, 0, 0, 0, 1, 0, 1);
    color_at(after, 4, 0, 0, 0, 1, 0, 1);

    c = source(8192 + 64, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8, 4, 4);
    c.palette_address = 16384 + 64;
    c.palette_length = 128;
    cpu_write(c.address, c.length);
    cpu_write(c.palette_address, c.palette_length);
    memset((uint8_t *)ram.contents + c.address, 1, c.length);
    uint32_t *palette =
        (uint32_t *)((uint8_t *)ram.contents + c.palette_address);
    memset(palette, 0, c.palette_length);
    palette[1] = 0xff112233;
    first = epoch_capture(c, sampler);
    for (unsigned i = 0; i < 8; i++) {
        epoch_neighbor(8192 + 128);
        epoch_neighbor(16384 + 256);
        assert(epoch_capture(c, sampler) == first);
    }
    epoch_pixels(first, 0x11 / 255.f, 0x22 / 255.f, 0x33 / 255.f);
    cpu_write(c.palette_address + 4, 4);
    palette[1] = 0xffaa3355;
    fresh = epoch_capture(c, sampler);
    assert(fresh.binding.texture != first.binding.texture);
    epoch_pixels(fresh, 0xaa / 255.f, 0x33 / 255.f, 0x55 / 255.f);
    cpu_write(c.address, c.length);
    memset((uint8_t *)ram.contents + c.address, 0, c.length);
    cpu_write(c.palette_address, 4);
    palette[0] = 0xff0000ff;
    first = epoch_capture(c, sampler);
    epoch_pixels(first, 0, 0, 1);
    cpu_write(c.address, c.length);
    memset((uint8_t *)ram.contents + c.address, 32, c.length);
    first = epoch_capture(c, sampler);
    epoch_neighbor(8192 + 128);
    assert(epoch_capture(c, sampler) == first);
    finish();
    assert(![first validateCompletedWithError:&error]);
    [textures removeAllTextures];

    /* A cancelled decoder's bytes are not a completed canonical texture. */
    cpu_write(c.address, c.length);
    memset((uint8_t *)ram.contents + c.address, 1, c.length);
    first = epoch_capture(c, sampler);
    token = first.producerRecording;
    [surfaces cancel];
    assert(token.cancelled);
    epoch_neighbor(8192 + 128);
    fresh = epoch_capture(c, sampler);
    assert(fresh.binding.texture != first.binding.texture);
    epoch_pixels(fresh, 0xaa / 255.f, 0x33 / 255.f, 0x55 / 255.f);

    /* Bound the retained raw bytes, and verify weak GPU-content ownership. */
    [textures removeAllTextures];
    for (unsigned i = 0; i < 65; i++) {
        NV2AMetalTextureSource large = {
            .address = 1024 * 1024 + i * 65536,
            .length = 65536,
            .shape = {.format =
                          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
                      .dimension = 2,
                      .width = 128,
                      .height = 128,
                      .depth = 1,
                      .levels = 1,
                      .pitch = 512}};
        epoch_capture(large, sampler);
    }
    NV2AMetalLRUCache *comparisons = [textures valueForKey:@"comparisons"];
    assert(comparisons.count == 64 && comparisons.evictionCount);
    NSDictionary *nodes = [comparisons valueForKey:@"entries"];
    NSUInteger bytes = 0;
    for (id key in nodes) {
        id comparison = [nodes[key] valueForKey:@"object"];
        bytes += [[comparison valueForKey:@"source"] length] +
                 [[comparison valueForKey:@"palette"] length];
    }
    assert(bytes == 4 * 1024 * 1024);
    NV2AMetalTextureSource tooLarge = {
        .address = 6 * 1024 * 1024,
        .length = 65552,
        .shape = {.format = NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
                  .dimension = 2,
                  .width = 4097,
                  .height = 4,
                  .depth = 1,
                  .levels = 1,
                  .pitch = 16388}};
    NSUInteger evictions = comparisons.evictionCount;
    epoch_capture(tooLarge, sampler);
    assert(comparisons.count == 64 && comparisons.evictionCount == evictions);
    [surfaces cancel];
    [textures removeAllTextures];
    assert(!comparisons.count);
    id heldComparison;
    @autoreleasepool {
        c = source(32768, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4,
                   16);
        epoch_capture(c, sampler);
        nodes = [comparisons valueForKey:@"entries"];
        heldComparison = [nodes.allValues.firstObject valueForKey:@"object"];
        assert([heldComparison valueForKey:@"texture"]);
        [textures removeAllTextures];
        [surfaces cancel];
    }
    assert(![heldComparison valueForKey:@"texture"] && !comparisons.count);

    surfaces.willWatchVRAM = nil;
    first = epoch_capture(c, sampler);
    epoch_neighbor(c.address + c.length);
    fresh = epoch_capture(c, sampler);
    assert(fresh.binding.texture != first.binding.texture &&
           !comparisons.count);
    [textures removeAllTextures];
    require([surfaces flushWithError:&error], error);
    surfaces = savedSurfaces;
    textures = savedTextures;
    puts("Texture content epochs: guarded neighbor/palette reuse, immutable "
         "samplers, retired/cancelled/write/alias fallbacks, GPU pixels and "
         "4 MiB raw-byte bound PASS; no app");
}
#endif
