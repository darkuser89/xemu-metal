/* Stable readonly indexed suffix compaction, with original Current semantics.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FETCH_READONLY_DEDUPE_H
#define TEST_METAL_FETCH_READONLY_DEDUPE_H

static void fetch_readonly_dedupe_tests(void)
{
    const uint32_t inputs[][6] = { { 5, 2, 5, 1, 2, 5 },
                                   { 3, 3, 3, 3, 3, 3 },
                                   { 5, 4, 3, 2, 1, 0 },
                                   { 0, 1, 2, 3, 4, 4 } };
    const NSUInteger prefixes[] = { 0, 2, 5, 6 };
    NSError *error = nil;
    for (unsigned mode = 0; mode < 2; mode++) {
        for (unsigned test = 0; test < ARRAY_SIZE(inputs); test++) {
            require([surfaces discardForRestoreWithError:&error], error);
            dma_stream();
            PGRAPHState *pg = &state->pgraph;
            pg->vertex_attributes[2] = (VertexAttribute){
                .offset = 256,
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP,
                .size = 4,
                .count = 1,
                .stride = 4
            };
            dma_a.limit = 279;
            cpu_write(1280, 24);
            for (unsigned i = 0; i < 6; i++) {
                uint32_t packed = UINT32_C(0x80200400) + i;
                memcpy(state->vram_ptr + 1280 + i * 4, &packed, 4);
            }
            memcpy(pg->inline_elements, inputs[test], sizeof(inputs[test]));
            pg->inline_elements_length = 6;
            NV2AMetalPendingInput *input =
                [NV2AMetalPendingInput indexedBytes:inputs[test]
                                              count:6
                                   matchingPrevious:nil];
            NSArray<NV2AMetalPGRAPHFetchBatch *> *reference = prepare();
            const NV2AMetalProgramInput *expected = values(reference[0]);
            NV2AMetalProgramInput expectedCurrent = expected[6];
            for (unsigned p = 0; p < ARRAY_SIZE(prefixes); p++) {
                NSUInteger prefix = prefixes[p], suffix = 6 - prefix;
                NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                    mode ?
                        [adapter
                            encodeCurrentSnapshotsWithPrefixes:@[ @(prefix) ]
                                                  indexedInput:input
                                           deduplicateReadonly:YES
                                                         error:&error] :
                        [adapter
                            encodeIndependentSnapshotsWithPrefixes:@[ @(
                                                                       prefix) ]
                                                      indexedInput:input
                                               deduplicateReadonly:YES
                                                             error:&error];
                require(batches != nil, error);
                NV2AMetalPGRAPHFetchBatch *batch = batches[0];
                assert(batch.inputVertexCount == 6 &&
                       batch.firstDecodedVertex == prefix && batch.indexed);
                uint32_t unique[6], mapping[6];
                NSUInteger count = 0;
                for (NSUInteger i = 0; i < suffix; i++) {
                    NSUInteger ordinal = 0;
                    while (ordinal < count &&
                           unique[ordinal] != inputs[test][prefix + i])
                        ordinal++;
                    if (ordinal == count)
                        unique[count++] = inputs[test][prefix + i];
                    mapping[i] = (uint32_t)ordinal;
                }
                assert(batch.physicalVertexCount == count);
                assert((batch.remap != nil) == (count < suffix));
                if (batch.remap) {
                    assert(![batch.remap isKindOfClass:NSMutableData.class]);
                    assert(batch.remap.length == suffix * 4 &&
                           !memcmp(batch.remap.bytes, mapping, suffix * 4));
                }
                NV2AMetalFetchUniforms proof;
                if (count) {
                    require(
                        [batch.fetch
                            getReadonlyProofUniforms:&proof
                                     attributeBuffer:batch.fetch.attributes
                                               first:0
                                               count:count
                                            commands:adapter.encodingCommands],
                        nil);
                    assert(proof.vertex_count == count &&
                           proof.index_size == 4);
                    assert(![batch.fetch
                        getReadonlyProofUniforms:&proof
                                 attributeBuffer:surfaces.vram
                                           first:0
                                           count:count
                                        commands:adapter.encodingCommands]);
                    assert(![batch.fetch
                        getReadonlyProofUniforms:&proof
                                 attributeBuffer:batch.fetch.attributes
                                           first:count + 1
                                           count:1
                                        commands:adapter.encodingCommands]);
                }
                require([adapter completeWithError:&error], error);
                const NV2AMetalProgramInput *actual =
                    batch.fetch.attributes.contents;
                for (NSUInteger i = 0; i < suffix; i++)
                    assert(!memcmp(actual + mapping[i], expected + prefix + i,
                                   sizeof(*actual)));
                if (!mode) {
                    assert(batch.fetch.hasCurrent);
                    assert(!memcmp(actual + batch.fetch.vertexCount,
                                   &expectedCurrent, sizeof(*actual)));
                }
                for (unsigned i = 0; i < 16; i++)
                    assert(!memcmp(pg->vertex_attributes[i].inline_value,
                                   expectedCurrent.attributes[i], 16));
                assert(![batch.fetch
                    getReadonlyProofUniforms:&proof
                             attributeBuffer:batch.fetch.attributes
                                       first:0
                                       count:count
                                    commands:surfaces.commands]);
                groups++;
            }
            /* Existing APIs and missing immutable ownership never opt in. */
            NSArray<NV2AMetalPGRAPHFetchBatch *> *legacy =
                [adapter encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
                                                   indexedInput:input
                                                          error:&error];
            require(legacy != nil, error);
            assert(!legacy[0].remap && legacy[0].physicalVertexCount == 6);
            require([adapter completeWithError:&error], error);
            legacy = [adapter encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
                                                        indexedInput:nil
                                                 deduplicateReadonly:YES
                                                               error:&error];
            require(legacy != nil, error);
            assert(!legacy[0].remap && legacy[0].physicalVertexCount == 6);
            require([adapter completeWithError:&error], error);
        }
    }
    /* Full original bounds are rejected before compaction, including an
     * invalid index in the accepted prefix and an otherwise duplicated suffix.
     */
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        for (unsigned enabled = 0; enabled < 2; enabled++) {
            dma_stream();
            PGRAPHState *pg = &state->pgraph;
            uint32_t indices[] = { invalid ? 0 : UINT32_MAX, 1, 1, 1 };
            memcpy(pg->inline_elements, indices, sizeof(indices));
            pg->inline_elements_length = 4;
            if (invalid == 1)
                pg->vertex_attributes[0].stride = UINT32_MAX;
            if (invalid == 2)
                pg->vertex_attributes[0].format = UINT32_MAX;
            NV2AMetalPendingInput *input =
                [NV2AMetalPendingInput indexedBytes:indices
                                              count:4
                                   matchingPrevious:nil];
            float before[4];
            memcpy(before, pg->vertex_attributes[0].inline_value,
                   sizeof(before));
            error = nil;
            assert(![adapter encodeIndependentSnapshotsWithPrefixes:@[ @1 ]
                                                       indexedInput:input
                                                deduplicateReadonly:enabled
                                                              error:&error]);
            assert(error &&
                   !memcmp(before, pg->vertex_attributes[0].inline_value,
                           sizeof(before)));
            groups++;
        }
    }
    puts("Readonly indexed fetch: stable suffix remap, original "
         "Current/D3D/CMP, "
         "cached and unique fallbacks, bound proofs and full bounds PASS");
}
#endif
