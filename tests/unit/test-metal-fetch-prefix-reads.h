/* Accepted XF prefixes do not own unread DMA bytes or allocate source copies.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FETCH_PREFIX_READS_H
#define TEST_METAL_FETCH_PREFIX_READS_H
static id prefix_copy_device;
static unsigned prefix_copy_count;
static id<MTLBuffer> (*prefix_copy_original)(id, SEL, const void *, NSUInteger,
                                             MTLResourceOptions);
static id<MTLBuffer> prefix_copy(id device, SEL selector, const void *bytes,
                                 NSUInteger length, MTLResourceOptions options)
{
    if (device == prefix_copy_device)
        prefix_copy_count++;
    return prefix_copy_original(device, selector, bytes, length, options);
}
static void current_only_source_tests(void)
{
    NSError *error = nil;
    Method copy =
        class_getInstanceMethod([surfaces.commands.device class],
                                @selector(newBufferWithBytes:length:options:));
    assert(copy);
    prefix_copy_device = surfaces.commands.device;
    prefix_copy_original =
        (void *)method_setImplementation(copy, (IMP)prefix_copy);
    for (unsigned kind = 0; kind < 4; kind++) {
        require([surfaces discardForRestoreWithError:&error], error);
        reset();
        PGRAPHState *pg = &state->pgraph;
        float data[3][4] = { { 1, 2, 3, 1 }, { 4, 5, 6, 1 }, { 7, 8, 9, 1 } };
        VertexAttribute *a = &pg->vertex_attributes[0];
        *a = (VertexAttribute){ .format =
                                    NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                                .count = 4,
                                .size = 4,
                                .stride = 16,
                                .inline_value = { -1, -2, -3, 1 },
                                .inline_buffer_populated = true,
                                .inline_buffer = &data[0][0] };
        pg->compressed_attrs = 0x400;
        if (!kind) {
            pg->draw_arrays_length = 1;
            pg->draw_arrays_count[0] = 3;
        } else if (kind == 1) {
            pg->inline_elements_length = 3;
            pg->inline_elements[0] = 2;
            pg->inline_elements[1] = 0;
            pg->inline_elements[2] = 1;
        } else if (kind == 2) {
            pg->inline_buffer_length = 3;
        } else {
            pg->inline_array_length = 12;
            memcpy(pg->inline_array, data, sizeof(data));
        }
        if (kind < 2) {
            cpu_write(dma_a.address, sizeof(data));
            memcpy(state->vram_ptr + dma_a.address, data, sizeof(data));
        }
        NV2AMetalPendingInput *input =
            kind == 1 ? [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                                      count:3
                                           matchingPrevious:nil] :
                        nil;
        prefix_copy_count = 0;
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            [adapter encodeCurrentSnapshotsWithPrefixes:@[ @3 ]
                                           indexedInput:input
                                                  error:&error];
        require(batches != nil, error);
        check_captured_fetch(batches);
        assert(!prefix_copy_count && batches.count == 1 &&
               batches[0].inputVertexCount == 3 &&
               batches[0].firstDecodedVertex == 3 &&
               batches[0].indexed == (kind == 1) && a->inline_value[0] == -1 &&
               pg->compressed_attrs == 0x400);
        const float *expected = data[kind == 1 ? 1 : 2];
        float frozen[4];
        memcpy(frozen, expected, sizeof(frozen));
        memset(data, 0, sizeof(data));
        memset(pg->inline_array, 0, sizeof(data));
        memset(pg->inline_elements, 0, 3 * 4);
        require([adapter completeCurrentSnapshotsWithError:&error], error);
        assert(!prefix_copy_count && !memcmp(a->inline_value, frozen, 16) &&
               a->inline_buffer_populated == (kind != 2) &&
               !pg->compressed_attrs);
        require([surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error],
                error);
    }
    method_setImplementation(copy, (IMP)prefix_copy_original);
    prefix_copy_device = nil;
    puts("Current-only accepted inputs:four source kinds,no Metal source-copy "
         "allocations,empty GPU outputs,frozen Current after source mutation "
         "and unchanged index identity PASS");
    groups++;
}
static void fetch_prefix_read_tests(void)
{
    unsigned cases = 0;
    for (unsigned host = 0; host < 2; host++)
        for (unsigned kind = 0; kind < 4; kind++)
            for (unsigned full = 0; full < 2; full++) {
                NSError *error = nil;
                require([surfaces discardForRestoreWithError:&error], error);
                reset();
                PGRAPHState *pg = &state->pgraph;
                dma_a.address = 0;
                dma_a.limit = 65535;
                VertexAttribute *a = &pg->vertex_attributes[0];
                *a = (VertexAttribute){
                    .offset = 4096,
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                    .size = 4,
                    .count = 4,
                    .stride = kind == 3 ? 0 : 4096,
                    .inline_value = { -1, -2, -3, 1 }
                };
                float data[3][4] = { { 1, 2, 3, 1 },
                                     { 4, 5, 6, 1 },
                                     { 7, 8, 9, 1 } };
                cpu_write(4096, 3 * 4096);
                for (unsigned i = 0; i < 3; i++)
                    memcpy(state->vram_ptr + 4096 + i * 4096, data[i], 16);
                NSArray *prefixes;
                unsigned selected = 2, dirtyIndex = 0;
                if (!kind || kind == 3) {
                    pg->draw_arrays_length = 1;
                    pg->draw_arrays_count[0] = 3;
                    prefixes = @[ @(full ? 3 : 2) ];
                    if (kind == 3) {
                        selected = 0;
                        dirtyIndex = 1;
                    }
                } else if (kind == 1) {
                    pg->inline_elements_length = 3;
                    pg->inline_elements[0] = 2;
                    pg->inline_elements[1] = 1;
                    pg->inline_elements[2] = 0;
                    prefixes = @[ @(full ? 3 : 2) ];
                    selected = 0;
                    dirtyIndex = 2;
                } else {
                    pg->draw_arrays_length = 2;
                    pg->draw_arrays_start[0] = 2;
                    pg->draw_arrays_start[1] = 0;
                    pg->draw_arrays_count[0] = pg->draw_arrays_count[1] = 1;
                    prefixes = @[ @1, @(full ? 1 : 0) ];
                    dirtyIndex = 1; /* Between suffix and prefix Current. */
                }
                const NSUInteger dirtyAddress = 4096 + dirtyIndex * 4096;
                NV2AMetalSurfaceConfig config = {
                    .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                    .width = 2,
                    .height = 2,
                    .pitch = 8,
                    .scale = 1,
                    .color = YES
                };
                NV2AMetalCachedSurface *dirty =
                    [surfaces prepareSurfaceAtAddress:dirtyAddress
                                               config:&config
                                                frame:0
                                                error:&error];
                NV2AMetalClear *clear = [[NV2AMetalClear alloc]
                    initWithDevice:surfaces.commands.device
                             error:&error];
                require(dirty && clear, error);
                NV2AMetalClearConfig c = {
                    .parameter = NV097_CLEAR_SURFACE_COLOR,
                    .rect = { 0, 0, 2, 2 },
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
                assert(dirty.dirty);
                NV2AMetalPendingInput *input =
                    kind == 1 ?
                        [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                                      count:3
                                           matchingPrevious:nil] :
                        nil;
                NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                    host ?
                        [adapter encodeCurrentSnapshotsWithPrefixes:prefixes
                                                       indexedInput:input
                                                              error:&error] :
                        [adapter encodeIndependentSnapshotsWithPrefixes:prefixes
                                                           indexedInput:input
                                                                  error:&error];
                require(batches != nil, error);
                assert(dirty.dirty && a->inline_value[0] == -1);
                if (!host)
                    assert(adapter.encodingCommands != surfaces.commands);
                BOOL done = YES;
                require([surfaces tryIdleCPUAccessAtAddress:4096 +
                                                            selected * a->stride
                                                     length:16
                                                      write:YES
                                                  completed:&done
                                                      error:&error],
                        error);
                assert(!done); /* Current still owns its selected bytes. */
                /* An unread gap on a different page remains CPU-writable. */
                const NSUInteger gap = kind < 2 ? 8192 : 24576;
                done = NO;
                require([surfaces tryIdleCPUAccessAtAddress:gap
                                                     length:16
                                                      write:YES
                                                  completed:&done
                                                      error:&error],
                        error);
                assert(done);
                require(host ?
                            [adapter completeCurrentSnapshotsWithError:&error] :
                            [adapter completeWithError:&error],
                        error);
                assert(dirty.dirty &&
                       !memcmp(a->inline_value, data[selected], 16));
                require([surfaces submitWithError:&error] &&
                            [surfaces waitUntilIdleWithError:&error],
                        error);
                assert(dirty.dirty);
                if (!host || !full) {
                    for (NSUInteger i = 0; i < batches.count; i++) {
                        NV2AMetalFetchResult *f = batches[i].fetch;
                        const NV2AMetalProgramInput *v = f.attributes.contents;
                        const uint32_t *faults = f.faults.contents;
                        for (NSUInteger j = 0; j < f.vertexCount; j++) {
                            unsigned vertex = !kind ? 2 : 0;
                            assert(!faults[j] && !memcmp(v[j].attributes[0],
                                                         data[vertex], 16));
                        }
                    }
                }
                cases++;
            }
    printf(
        "Accepted DMA prefixes:%u native host/GPU Current pairs;arrays,"
        "indexed,separate prefix Current,zero stride,full/partial acceptance;"
        "unread dirty surfaces stay dirty,no unrelated download,Current "
        "source stays protected and exact suffix attributes retained PASS\n",
        cases);
    groups++;
}
#endif
