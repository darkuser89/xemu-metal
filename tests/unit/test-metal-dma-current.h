/* CPU-readable DMA Current with the normal GPU source read guards.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DMA_CURRENT_H
#define TEST_METAL_DMA_CURRENT_H
#import "hw/xbox/nv2a/pgraph/metal/pending-journal.h"
static void dma_current_tests(void)
{
    NSError *error = nil;
    const unsigned formats[] = { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP };
    for (unsigned kind = 0; kind < 2; kind++)
        for (unsigned test = 0; test < 32; test++) {
            reset();
            cpu_write(0, 65536);
            PGRAPHState *pg = &state->pgraph;
            uint32_t before[16][4];
            for (unsigned a = 0; a < 16; a++) {
                VertexAttribute *v = &pg->vertex_attributes[a];
                v->format = formats[(test + a) % 6];
                v->count =
                    v->format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP ?
                        1 :
                    v->format ==
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D ?
                        4 :
                        (test + a) % 5;
                v->size =
                    v->format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F ||
                            v->format ==
                                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP ?
                        4 :
                    v->format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1 ||
                            v->format ==
                                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K ?
                        2 :
                        1;
                v->stride =
                    (test + a) % 7 == 0 ?
                        0 :
                        nv2a_metal_attribute_size(v->format, v->count) + 3;
                v->offset = 513 + (a / 2) * 256;
                v->dma_select = a & 1;
                v->inline_buffer_populated = (a + test) % 3 == 0;
                for (unsigned k = 0; k < 4; k++)
                    before[a][k] = 0x3f000000 + a * 13 + k;
                memcpy(v->inline_value, before[a], 16);
                for (unsigned index = 0; index < 8; index++)
                    for (unsigned k = 0; k < v->count; k++) {
                        uint32_t code = 0x81234567u + test * 93 + a * 101 +
                                        index * 197 + k * 233;
                        if (v->format ==
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F) {
                            const uint32_t bits[] = { 0,          0x80000000,
                                                      1,          0x7fc12345,
                                                      0x7f812345, 0x7f800000,
                                                      0xff800000 };
                            code = bits[(test + a + index + k) %
                                        G_N_ELEMENTS(bits)];
                        }
                        uint8_t *p =
                            state->vram_ptr +
                            (v->dma_select ? dma_b.address : dma_a.address) +
                            v->offset + index * v->stride + k * v->size;
                        for (unsigned b = 0; b < v->size; b++)
                            p[b] = code >> (8 * b);
                    }
            }
            NSArray<NSNumber *> *prefixes;
            NV2AMetalPendingInput *input = nil;
            if (!kind) {
                pg->draw_arrays_length = 3;
                for (unsigned b = 0; b < 3; b++) {
                    pg->draw_arrays_start[b] = (unsigned[]){ 1, 4, 2 }[b];
                    pg->draw_arrays_count[b] = 3;
                }
                prefixes =
                    @[ @(test % 4), @((test + 1) % 4), @((test + 2) % 4) ];
            } else {
                uint32_t indices[] = { 7, 1, 6, 2 };
                pg->inline_elements_length = 4;
                memcpy(pg->inline_elements, indices, sizeof(indices));
                input = [NV2AMetalPendingInput
                    indexed:[NSData dataWithBytes:indices
                                           length:sizeof(indices)]];
                require(input != nil, error);
                pg->inline_elements[3] = UINT32_MAX;
                assert(![adapter canCaptureCurrentForInput:nil]);
                prefixes = @[ @(test % 5) ];
            }
            pg->compressed_attrs = 0x8091;
            NSArray *reference = current_gpu_reference(prefixes, input);
            unsigned oldReads = reads;
            assert(!surfaces.commands.commandBuffer &&
                   [adapter canCaptureCurrentForInput:input] &&
                   !surfaces.commands.commandBuffer && reads == oldReads);
            NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                [adapter encodeCurrentSnapshotsWithPrefixes:prefixes
                                               indexedInput:input
                                                      error:&error];
            require(batches != nil, error);
            check_captured_fetch(batches);
            for (unsigned a = 0; a < 16; a++)
                assert(!memcmp(before[a], pg->vertex_attributes[a].inline_value,
                               16));
            assert(adapter.encodingCommands == surfaces.commands);
            BOOL blocked = NO;
            for (unsigned a = 0; a < 16; a++)
                if (pg->vertex_attributes[a].count) {
                    VertexAttribute *v = &pg->vertex_attributes[a];
                    BOOL done = YES;
                    NSUInteger address =
                        (v->dma_select ? dma_b.address : dma_a.address) +
                        v->offset + (kind ? 2 : 6) * v->stride;
                    require([surfaces tryIdleCPUAccessAtAddress:address
                                                         length:1
                                                          write:YES
                                                      completed:&done
                                                          error:&error],
                            error);
                    assert(!done);
                    blocked = YES;
                }
            assert(blocked);
            memset(pg->inline_elements, 0x5b, sizeof(pg->inline_elements));
            require([adapter completeCurrentSnapshotsWithError:&error], error);
            NV2AMetalProgramInput captured;
            for (unsigned a = 0; a < 16; a++) {
                memcpy(captured.attributes[a],
                       pg->vertex_attributes[a].inline_value, 16);
                assert(pg->vertex_attributes[a].inline_buffer_populated ==
                       ((a + test) % 3 == 0));
            }
            assert(!pg->compressed_attrs);
            require([surfaces submitWithError:&error] &&
                        [surfaces waitUntilIdleWithError:&error],
                    error);
            unsigned currentRecords = 0;
            for (NV2AMetalPGRAPHFetchBatch *b in reference) {
                const uint32_t *faults = b.fetch.faults.contents;
                for (NSUInteger v = 0;
                     v < b.fetch.vertexCount + b.fetch.hasCurrent; v++)
                    assert(!faults[v]);
                if (b.fetch.hasCurrent) {
                    assert(!memcmp(&captured,
                                   (uint8_t *)b.fetch.attributes.contents +
                                       b.fetch.vertexCount * sizeof(captured),
                                   sizeof(captured)));
                    currentRecords++;
                }
            }
            assert(currentRecords == 1);
        }
    puts("DMA Current:64 exact native Current pairs;six formats/16 "
         "attributes/two DMA banks/unaligned and zero strides,nonmonotonic "
         "three-range highest-index selection,frozen last-index "
         "selection,prefixes through Current-only,CPU source-write "
         "guards,populated/compressed flags and unchanged Current until "
         "acceptance PASS");
    groups++;
}
static void dma_current_guard_tests(void)
{
    reset();
    NSError *error = nil;
    unsigned beforeNotifications = notifications;
    require([surfaces discardForRestoreWithError:&error], error);
    PGRAPHState *pg = &state->pgraph;
    dma_a.address = 0;
    dma_a.limit = 65535;
    pg->vertex_attributes[0] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .count = 4,
                           .size = 4,
                           .stride = 16,
                           .offset = 65520 };
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 1;
    assert([adapter canCaptureCurrentForInput:nil]);
    float data[4] = { 3.25f, 4.5f, 5.75f, 1 };
    id<MTLBuffer> source = [surfaces.commands.device
        newBufferWithBytes:data
                    length:sizeof(data)
                   options:MTLResourceStorageModeShared];
    assert(source);
    require([surfaces prepareGPUWriteAtAddress:65520 length:16 error:&error],
            error);
    require([surfaces.commands addResource:source error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [surfaces.commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:surfaces.vram
        destinationOffset:65520
                     size:16];
    [e endEncoding];
    id recording = surfaces.commands.commandBuffer;
    assert(![adapter canCaptureCurrentForInput:nil] &&
           ![adapter encodeCurrentSnapshotsWithPrefixes:@[ @0 ]
                                           indexedInput:nil
                                                  error:NULL] &&
           surfaces.commands.commandBuffer == recording);
    require([surfaces submitWithError:&error], error);
    assert(![adapter canCaptureCurrentForInput:nil]);
    require([surfaces waitUntilIdleWithError:&error], error);
    assert([adapter canCaptureCurrentForInput:nil]);
    NV2AMetalSurfaceConfig config = {
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 2,
        .height = 2,
        .pitch = 8,
        .scale = 1,
        .color = YES
    };
    NV2AMetalCachedSurface *surface = [surfaces prepareSurfaceAtAddress:65520
                                                                 config:&config
                                                                  frame:0
                                                                  error:&error];
    require(surface != nil, error);
    assert([adapter canCaptureCurrentForInput:nil]);
    NV2AMetalClear *clear =
        [[NV2AMetalClear alloc] initWithDevice:surfaces.commands.device
                                         error:&error];
    require(clear != nil, error);
    NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                               .rect = { 0, 0, 2, 2 },
                               .uniforms = { .color = { 1, 0, 0, 1 } } };
    require([clear encodeColor:surface.transfer.texture
                          zeta:nil
                        config:&c
                      commands:surfaces.commands
                         error:&error] &&
                [surfaces markWritten:surface error:&error],
            error);
    assert(![adapter canCaptureCurrentForInput:nil]);
    require([surfaces prepareGPUReadAtAddress:65520 length:16 error:&error],
            error);
    assert(![adapter canCaptureCurrentForInput:nil]);
    require([surfaces submitWithError:&error], error);
    assert(![adapter canCaptureCurrentForInput:nil]);
    require([surfaces waitUntilIdleWithError:&error], error);
    assert([adapter canCaptureCurrentForInput:nil]);
    require([surfaces discardForRestoreWithError:&error], error);
    assert(notifications == beforeNotifications + 1);
    reset();
    pg = &state->pgraph;
    dma_a.limit = 15;
    pg->vertex_attributes[0] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .count = 4,
                           .size = 4,
                           .stride = 16 };
    pg->inline_elements_length = 2;
    pg->inline_elements[0] = UINT32_MAX;
    pg->inline_elements[1] = 0;
    assert([adapter canCaptureCurrentForInput:nil]);
    uint32_t before[4];
    memcpy(before, pg->vertex_attributes[0].inline_value, 16);
    assert(![adapter encodeCurrentSnapshotsWithPrefixes:@[ @1 ]
                                           indexedInput:nil
                                                  error:&error] &&
           error && !surfaces.commands.commandBuffer &&
           !memcmp(before, pg->vertex_attributes[0].inline_value, 16));
    puts("DMA Current guards:pending/submitted direct GPU writes,dirty "
         "surfaces,pending/submitted downloads reject host capture;clean "
         "aliases accept;stale eligibility rechecked without cancelling "
         "writer;invalid DMA inside skipped index prefix rejected before "
         "Current changes PASS");
    groups++;
}
static void captured_current_completion_tests(void)
{
    unsigned cases = 0, retries = 0;
    for (unsigned kind = 0; kind < 4; kind++)
        for (unsigned p = 0; p < 3; p++)
            for (unsigned action = 0; action < 3; action++) {
                unsigned prefix = (unsigned[]){ 0, 1, 3 }[p];
                if (prefix == 3 && action == 1)
                    continue; /* No GPU output exists to fault. */
                reset();
                NSError *error = nil;
                PGRAPHState *pg = &state->pgraph;
                float positions[3][4] = { { 1, 2, 3, 1 },
                                          { 4, 5, 6, 1 },
                                          { 7, 8, 9, 1 } };
                VertexAttribute *a = &pg->vertex_attributes[0];
                *a = (VertexAttribute){
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                    .count = 4,
                    .size = 4,
                    .stride = 16,
                    .inline_value = { -7, -8, -9, 1 },
                    .inline_buffer_populated = true,
                    .inline_buffer = &positions[0][0]
                };
                pg->compressed_attrs = 0x8091;
                if (!kind) {
                    pg->draw_arrays_length = 1;
                    pg->draw_arrays_count[0] = 3;
                } else if (kind == 1) {
                    pg->inline_elements_length = 3;
                    pg->inline_elements[0] = 1;
                    pg->inline_elements[1] = 0;
                    pg->inline_elements[2] = 2;
                } else if (kind == 2) {
                    pg->inline_buffer_length = 3;
                } else {
                    pg->inline_array_length = 12;
                    memcpy(pg->inline_array, positions, sizeof(positions));
                }
                if (kind < 2) {
                    cpu_write(dma_a.address, sizeof(positions));
                    memcpy(state->vram_ptr + dma_a.address, positions,
                           sizeof(positions));
                }
                float before[4];
                memcpy(before, a->inline_value, 16);
                NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                    [adapter encodeCurrentSnapshotsWithPrefixes:@[ @(prefix) ]
                                                   indexedInput:nil
                                                          error:&error];
                require(batches != nil, error);
                check_captured_fetch(batches);
                assert(batches[0].fetch.vertexCount == 3 - prefix &&
                       !memcmp(before, a->inline_value, 16));
                if (action == 2) {
                    [adapter cancel];
                    assert(![adapter completeWithError:&error] && error &&
                           !memcmp(before, a->inline_value, 16) &&
                           a->inline_buffer_populated &&
                           pg->compressed_attrs == 0x8091);
                } else {
                    if (action == 1) {
                        require([adapter submitWithError:&error] &&
                                    [surfaces waitUntilIdleWithError:&error],
                                error);
                        /* Inject after actual GPU completion, before generic
                         * acceptance. No concurrent CPU/GPU fault-buffer edit.
                         */
                        NV2AMetalFetchResult *r = batches[0].fetch;
                        stl_le_p((uint8_t *)r.faults.contents +
                                     r.faultSummaryOffset,
                                 1);
                        assert(![adapter completeWithError:&error] && error &&
                               !memcmp(before, a->inline_value, 16) &&
                               a->inline_buffer_populated &&
                               pg->compressed_attrs == 0x8091);
                        error = nil;
                        batches = [adapter
                            encodeCurrentSnapshotsWithPrefixes:@[ @(prefix) ]
                                                  indexedInput:nil
                                                         error:&error];
                        require(batches != nil, error);
                        check_captured_fetch(batches);
                        retries++;
                    }
                    require([adapter completeWithError:&error], error);
                    assert(!memcmp(a->inline_value, positions[2], 16) &&
                           !pg->compressed_attrs &&
                           a->inline_buffer_populated == (kind != 2));
                    assert(![adapter completeWithError:&error] && error);
                }
                cases++;
            }
    assert(cases == 32 && retries == 8);
    puts("Captured Current completion:32 array/index/Float4/Float32-array "
         "full/suffix/Current-only cases;no GPU Current records or empty "
         "output allocations;generic completion preserves selected Current, "
         "flags and cancel;injected GPU suffix faults reject before Current "
         "publication,eight corrected retries PASS");
    groups++;
}
#endif
