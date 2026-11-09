/* A pre-write callback invalidates guarded byte-comparison candidates before
 * the caller executes its store. SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CPU_PREFIX_COMPARISON_H
#define TEST_METAL_CPU_PREFIX_COMPARISON_H

static BOOL cpu_comparison_reader_covers(NV2AMetalSurfaceRecording *token,
                                         NSUInteger address, NSUInteger length)
{
    NSIndexSet *pages = [token valueForKey:@"readerPages"];
    NSUInteger first = address / 4096;
    NSUInteger last = (address + length - 1) / 4096;
    return [pages containsIndexesInRange:NSMakeRange(first, last - first + 1)];
}

static void cpu_prefix_comparison_tests(void)
{
    NSError *error = nil;
    NV2AMetalVRAMWriteHandler originalWatch = surfaces.willWatchVRAM;
    __block unsigned watches = 0;
    surfaces.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
      assert(address < surfaces.vram.length && length &&
             length <= surfaces.vram.length - address);
      watches++;
    };
    for (unsigned mode = 0; mode < 3; mode++) {
        [textures removeAllTextures];
        BOOL indexed = mode == 2;
        NV2AMetalTextureSource src =
            source(mode == 0 ? 4096 :
                   mode == 1 ? 8188 :
                               16384,
                   indexed ? NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8 :
                             NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
                   4, indexed ? 4 : 16);
        if (indexed) {
            src.palette_address = 24576;
            src.palette_length = 128;
        }
        cpu_write(src.address, src.length);
        if (indexed)
            cpu_write(src.palette_address, src.palette_length);
        uint8_t *bytes = (uint8_t *)surfaces.vram.contents + src.address;
        uint32_t *words = indexed ?
                              (uint32_t *)((uint8_t *)surfaces.vram.contents +
                                           src.palette_address) :
                              (uint32_t *)bytes;
        if (indexed) {
            memset(bytes, 0, src.length);
            memset(words, 0, src.palette_length);
        }
        NSUInteger count = indexed ? 1 : 16;
        for (NSUInteger i = 0; i < count; i++)
            words[i] = UINT32_C(0xff00ff00);
        NV2AMetalCachedTexture *green = prepare(src);
        id<MTLBuffer> before = read_texture(green);
        NV2AMetalSurfaceRecording *head = surfaces.recording;
        assert(head && !head.cpuHazardsRetired &&
               [[textures valueForKey:@"comparisons"] count] > 0);
        require([surfaces checkpointWithError:&error], error);
        NSUInteger address = indexed ? src.palette_address : src.address;
        NSUInteger length = indexed ? src.palette_length : src.length;
        uint64_t oldVersion = 0, announcedVersion = 0, finalVersion = 0;
        require([surfaces sourceVersionAtAddress:address
                                          length:length
                                         version:&oldVersion
                                           error:&error],
                error);
        assert(cpu_comparison_reader_covers(head, address, length));
        /* This is the real pre-write window. No source byte changes until
         * after the new texture and its GPU upload have been recorded. */
        require([surfaces resolveCPUAccessAtAddress:address
                                             length:length
                                              write:YES
                                              error:&error],
                error);
        require([surfaces sourceVersionAtAddress:address
                                          length:length
                                         version:&announcedVersion
                                           error:&error],
                error);
        assert(head.cpuHazardsRetired && head.producersCompleted &&
               !head.completed && !head.submitted &&
               announcedVersion > oldVersion &&
               ![[head valueForKey:@"readerPages"] count]);
        for (NSUInteger i = 0; i < count; i++)
            assert(words[i] == UINT32_C(0xff00ff00));
        NV2AMetalCachedTexture *fresh = prepare(src);
        /* Without the retired-token rejection the identical comparison bytes
         * deterministically select the old Green texture, before any GPU runs.
         */
        assert(fresh.binding.texture != green.binding.texture &&
               fresh.producerRecording != head &&
               cpu_comparison_reader_covers(fresh.producerRecording, address,
                                            length));
        id<MTLBuffer> after = read_texture(fresh);
        id<MTLBuffer> immutable = read_texture(green);
        for (NSUInteger i = 0; i < count; i++)
            words[i] = UINT32_C(0xff0000ff);
        /* Deliberately no second callback/stamp for this already announced
         * CPU store. Both pending GPU copies execute only after the store. */
        finish();
        require([surfaces sourceVersionAtAddress:address
                                          length:length
                                         version:&finalVersion
                                           error:&error],
                error);
        assert(finalVersion == announcedVersion && head.completed &&
               ![[head valueForKey:@"readerPages"] count] &&
               ![[fresh.producerRecording valueForKey:@"readerPages"] count]);
        for (unsigned y = 0; y < 4; y++) {
            for (unsigned x = 0; x < 4; x++) {
                color_at(before, 4, x, y, 0, 1, 0, 1);
                color_at(immutable, 4, x, y, 0, 1, 0, 1);
                color_at(after, 4, x, y, 0, 0, 1, 1);
            }
        }
        checks++;
    }
    assert(watches);
    [textures removeAllTextures];
    surfaces.willWatchVRAM = originalWatch;
    puts(
        "Metal CPU prefix comparison: 3 pre-write-window cases PASS; "
        "same bytes evict retired guarded candidates, fresh GPU Blue and "
        "immutable Green, source/palette and page boundary, one version stamp");
}
#endif
