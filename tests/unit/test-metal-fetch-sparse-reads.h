/* Sparse inputs must not download or guard holes between decoded vertices.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FETCH_SPARSE_READS_H
#define TEST_METAL_FETCH_SPARSE_READS_H
static void fetch_sparse_read_tests(void)
{
    unsigned cases = 0, joinedCurrent = 0;
    for (unsigned host = 0; host < 2; host++)
        for (unsigned layout = 0; layout < 18; layout++)
            for (unsigned prefix = 0; prefix < 2; prefix++) {
                unsigned selection = layout % 6;
                BOOL overlapping = layout >= 12;
                BOOL merged = layout < 6 || overlapping;
                NSUInteger colorOffset = overlapping ? 12 : merged ? 16 : 24;
                NSUInteger hole = layout < 6 ? 12288 : 16896;
                NSError *error = nil;
                require([surfaces discardForRestoreWithError:&error], error);
                reset();
                PGRAPHState *pg = &state->pgraph;
                dma_a.address = dma_b.address = 0;
                dma_a.limit = dma_b.limit = 65535;
                pg->vertex_attributes[0] = (VertexAttribute){
                    .offset = 4096,
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                    .size = 4,
                    .count = 4,
                    .stride = 4096,
                    .inline_value = { -1, -2, -3, 1 }
                };
                pg->vertex_attributes[3] = (VertexAttribute){
                    .dma_select = true,
                    .offset = 4096 + colorOffset,
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                    .size = 1,
                    .count = 4,
                    .stride = 4096
                };
                pg->vertex_attributes[7] = (VertexAttribute){
                    .offset = 50000,
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                    .size = 4,
                    .count = 4,
                    .stride = 0
                };
                cpu_write(4096, 5 * 4096);
                cpu_write(50000, 16);
                float data[5][4];
                uint8_t colors[5][4];
                for (unsigned i = 0; i < 5; i++) {
                    for (unsigned lane = 0; lane < 4; lane++) {
                        data[i][lane] = 10 * i + lane + .25f;
                        colors[i][lane] = i * 30 + lane * 7;
                    }
                    memcpy(state->vram_ptr + 4096 + i * 4096, data[i], 16);
                    if (overlapping)
                        memcpy(colors[i], &data[i][3], 4);
                    else
                        memcpy(state->vram_ptr + 4096 + colorOffset + i * 4096,
                               colors[i], 4);
                }
                float constant[4] = { 100, 200, 300, 1 };
                memcpy(state->vram_ptr + 50000, constant, 16);
                NSArray<NSNumber *> *prefixes;
                unsigned selected;
                if (selection < 2) {
                    pg->draw_arrays_length = selection ? 3 : 2;
                    pg->draw_arrays_start[0] = selection ? 4 : 3;
                    pg->draw_arrays_count[0] = selection ? 1 : 2;
                    pg->draw_arrays_start[1] = 0;
                    pg->draw_arrays_count[1] = selection ? 2 : 1;
                    pg->draw_arrays_start[2] = 3;
                    pg->draw_arrays_count[2] = 1;
                    prefixes = selection ?
                                   @[ @(prefix), @(prefix), @0 ] :
                                   @[ @(prefix), @0 ];
                    selected = 4;
                } else {
                    static const uint32_t indices[][5] = { { 0, 1, 3, 3, 4 },
                                                           { 4, 3, 0, 3, 1 },
                                                           { 4, 3, 1, 1, 0 },
                                                           { 3, 0, 3, 4, 1 } };
                    pg->inline_elements_length = 5;
                    memcpy(pg->inline_elements, indices[selection - 2], 20);
                    prefixes = @[ @(prefix ? 2 : 0) ];
                    selected = indices[selection - 2][4];
                }
                NV2AMetalSurfaceConfig config = {
                    .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                    .width = 4,
                    .height = 4,
                    .pitch = 16,
                    .scale = 1,
                    .color = YES
                };
                NV2AMetalCachedSurface *dirty =
                    [surfaces prepareSurfaceAtAddress:hole
                                               config:&config
                                                frame:0
                                                error:&error];
                NV2AMetalClear *clear = [[NV2AMetalClear alloc]
                    initWithDevice:surfaces.commands.device
                             error:&error];
                require(dirty && clear, error);
                NV2AMetalClearConfig c = {
                    .parameter = NV097_CLEAR_SURFACE_COLOR,
                    .rect = { 0, 0, 4, 4 },
                    .uniforms = { .color = { 1, 0, 0, 1 } }
                };
                require([clear encodeColor:dirty.transfer.texture
                                      zeta:nil
                                    config:&c
                                  commands:surfaces.commands
                                     error:&error] &&
                            [surfaces markWritten:dirty error:&error] &&
                            [surfaces checkpointWithError:&error],
                        error);
                unsigned downloads = notifications;
                id recording = surfaces.commands.commandBuffer;
                NV2AMetalSurfaceRecording *token = surfaces.recording;
                NV2AMetalPendingInput *input =
                    selection < 2 ? nil :
                                 [NV2AMetalPendingInput
                                         indexedBytes:pg->inline_elements
                                                count:5
                                     matchingPrevious:nil];
                unsigned suffixPages = 0;
                if (selection < 2) {
                    for (unsigned batch = 0; batch < pg->draw_arrays_length; batch++)
                        for (unsigned i = prefixes[batch].unsignedIntValue;
                             i < (unsigned)pg->draw_arrays_count[batch]; i++)
                            suffixPages |= 1u << (pg->draw_arrays_start[batch] + i + 1);
                } else {
                    for (unsigned i = prefixes[0].unsignedIntValue;
                         i < pg->inline_elements_length; i++)
                        suffixPages |= 1u << (pg->inline_elements[i] + 1);
                }
                unsigned currentPage = 1u << (selected + 1);
                unsigned expectedPages = suffixPages | currentPage | 1u << 12;
                unsigned lanePages = suffixPages | currentPage;
                unsigned laneRuns =
                    __builtin_popcount(lanePages & ~(lanePages << 1));
                unsigned separateRuns =
                    __builtin_popcount(suffixPages & ~(suffixPages << 1)) +
                    !(suffixPages & currentPage);
                joinedCurrent += separateRuns > laneRuns;
                NSData *pendingReads = [surfaces valueForKey:@"pendingReads"];
                NSUInteger pendingBytes = pendingReads.length;
                unsigned dirtyReads = reads;
                dirty_read_pages = 0;
                NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                    host ?
                        [adapter encodeCurrentSnapshotsWithPrefixes:prefixes
                                                       indexedInput:input
                                                              error:&error] :
                        [adapter encodeIndependentSnapshotsWithPrefixes:prefixes
                                                           indexedInput:input
                                                                  error:&error];
                require(batches != nil, error);
                unsigned runs = __builtin_popcount(expectedPages & ~(expectedPages << 1));
                assert(dirty_read_pages == expectedPages && reads - dirtyReads == runs);
                NSUInteger registeredBytes =
                    host ? pendingReads.length - pendingBytes :
                           [(NSData *)[[adapter valueForKey:@"independentReads"]
                               valueForKey:@"spans"] length];
                unsigned expectedPatterns = laneRuns * (merged ? 1 : 2) + 1;
                assert(registeredBytes ==
                       expectedPatterns * sizeof(NV2AMetalVRAMReadPattern));
                assert(dirty.dirty && notifications == downloads &&
                       !token.submitted && !token.cancelled);
                if (!host)
                    assert(surfaces.commands.commandBuffer == recording &&
                           surfaces.recording == token);
                assert(host || adapter.encodingCommands != surfaces.commands);
                BOOL ready = NO;
                require([surfaces tryIdleCPUAccessAtAddress:13056
                                                     length:16
                                                      write:YES
                                                  completed:&ready
                                                      error:&error],
                        error);
                assert(ready); /* Same hole page, outside the dirty surface. */
                require([surfaces tryIdleCPUAccessAtAddress:4096 + selected * 4096 + 20
                                                     length:1
                                                      write:YES
                                                  completed:&ready
                                                      error:&error], error);
                assert(ready);
                ready = YES;
                require([surfaces
                            tryIdleCPUAccessAtAddress:4096 + selected * 4096
                                               length:16
                                                write:YES
                                            completed:&ready
                                                error:&error],
                        error);
                assert(!ready &&
                       pg->vertex_attributes[0].inline_value[0] == -1);
                require(host ?
                            [adapter completeCurrentSnapshotsWithError:&error] :
                            [adapter completeWithError:&error],
                        error);
                assert(dirty.dirty && notifications == downloads &&
                       !memcmp(pg->vertex_attributes[0].inline_value,
                               data[selected], 16));
                assert(!memcmp(pg->vertex_attributes[7].inline_value, constant,
                               16));
                for (unsigned lane = 0; lane < 4; lane++)
                    scalar(pg->vertex_attributes[3].inline_value[lane],
                           colors[selected][lane] / 255.0f);
                require([surfaces submitWithError:&error] &&
                            [surfaces waitUntilIdleWithError:&error],
                        error);
                assert(dirty.dirty && notifications == downloads);
                for (NSUInteger i = 0; i < batches.count; i++) {
                    NV2AMetalPGRAPHFetchBatch *b = batches[i];
                    if (!b.fetch.vertexCount)
                        continue;
                    const NV2AMetalProgramInput *v = values(b);
                    for (NSUInteger j = 0; j < b.fetch.vertexCount; j++) {
                        NSUInteger ordinal = b.firstDecodedVertex + j;
                        unsigned index =
                            selection < 2 ? pg->draw_arrays_start[i] + ordinal :
                                         pg->inline_elements[ordinal];
                        assert(!memcmp(v[j].attributes[0], data[index], 16) &&
                               !memcmp(v[j].attributes[7], constant, 16));
                        for (unsigned lane = 0; lane < 4; lane++)
                            scalar(v[j].attributes[3][lane],
                                   colors[index][lane] / 255.0f);
                    }
                }
                cases++;
            }
    printf("Sparse DMA reads:%u host/GPU Current,array/index,full/suffix "
           "cases;unordered/overlapping/duplicate ranges,2 DMA sources,zero "
           "stride;index/stride holes undownloaded,unused bytes writable,selected "
           "Current protected,exact GPU attributes PASS\n",
           cases);
    puts("Sparse DMA dirty pages: one TCG query per page run, "
         "no queries across gaps and unchanged GPU byte ownership PASS");
    puts("Sparse DMA interleaved lanes: adjacent and overlapping attributes "
         "share read records; gapped lanes and unused writable bytes PASS");
    assert(joinedCurrent == 6);
    puts("Sparse DMA Current ranges: six adjacent accepted Current values "
         "share exact stride records with decoded suffix vertices PASS");
    groups++;
}
#endif
