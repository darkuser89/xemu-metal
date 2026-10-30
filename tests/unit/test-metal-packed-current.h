/* Captured Current versus the existing GPU decoder for all inline formats.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PACKED_CURRENT_H
#define TEST_METAL_PACKED_CURRENT_H
static void packed_current_tests(void)
{
    const unsigned formats[] = { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F };
    NSError *error = nil;
    unsigned cases = 0;
    for (unsigned family = 0; family < 7; family++) {
        unsigned count = family < 2 ? 4 : family < 4 ? 1024 : 128;
        NSMutableArray *results = [NSMutableArray new],
                       *expected = [NSMutableArray new];
        for (unsigned test = 0; test < count; test++) {
            reset();
            PGRAPHState *pg = &state->pgraph;
            NSUInteger stride = 0, offsets[16] = { 0 };
            uint32_t before[16][4];
            for (unsigned a = 0; a < 16; a++) {
                unsigned format = formats[family < 6 ? family : (a + test) % 6];
                VertexAttribute *attribute = &pg->vertex_attributes[a];
                attribute->format = format;
                attribute->count =
                    format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP ? 1 :
                    format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D ?
                                                                            4 :
                    family == 6 ? (test + a) % 5 :
                                  4;
                attribute->size =
                    format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F ||
                            format ==
                                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP ?
                        4 :
                    format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1 ||
                            format ==
                                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K ?
                        2 :
                        1;
                attribute->inline_buffer_populated = (test + a) % 7 == 0;
                for (unsigned k = 0; k < 4; k++)
                    before[a][k] = 0x3f000000 + a * 19 + k;
                memcpy(attribute->inline_value, before[a], 16);
                if (!attribute->count)
                    continue;
                stride = (stride + attribute->size - 1) &
                         ~(NSUInteger)(attribute->size - 1);
                offsets[a] = stride;
                stride += nv2a_metal_attribute_size(format, attribute->count);
            }
            assert(stride);
            memset(pg->inline_array, 0xa5, 4 * stride);
            for (unsigned v = 0; v < 4; v++)
                for (unsigned a = 0; a < 16; a++) {
                    VertexAttribute *attribute = &pg->vertex_attributes[a];
                    uint8_t *bytes =
                        (uint8_t *)pg->inline_array + v * stride + offsets[a];
                    for (unsigned k = 0; k < attribute->count; k++) {
                        unsigned code =
                            64 * test + 4 * a + k + (v == 2 ? 0 : 179 * v);
                        if (attribute->format ==
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP) {
                            unsigned x =
                                (test + 128 * a + (v == 2 ? 0 : 179 * v)) &
                                2047;
                            code = x | (((x * 73 + 37) & 2047) << 11) |
                                   (((x * 37 + 51) & 1023) << 22);
                        } else if (attribute->format ==
                                   NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F) {
                            const uint32_t values[] = { 0,          0x80000000,
                                                        1,          0x7fc12345,
                                                        0x7f812345, 0xff800000,
                                                        0x7f7fffff };
                            code = values[code % G_N_ELEMENTS(values)];
                        }
                        for (unsigned b = 0; b < attribute->size; b++)
                            bytes[k * attribute->size + b] = code >> (8 * b);
                    }
                }
            pg->inline_array_length =
                (3 * stride + 3) / 4 + test % (stride / 4);
            pg->compressed_attrs = 0xffff;
            assert(
                [NV2AMetalPGRAPHFetch canCaptureInlineCurrentForState:state]);
            NSArray *reference = current_gpu_reference(@[ @(test % 4) ], nil);
            NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = [adapter
                encodeInlineCurrentSnapshotsWithPrefixes:@[ @(test % 4) ]
                                                   error:&error];
            require(batches != nil, error);
            check_captured_fetch(batches);
            for (unsigned a = 0; a < 16; a++)
                assert(!memcmp(pg->vertex_attributes[a].inline_value, before[a],
                               16));
            memset(pg->inline_array, 0x5b, 4 * stride);
            require([adapter completeInlineCurrentSnapshotsWithError:&error],
                    error);
            NV2AMetalProgramInput current;
            for (unsigned a = 0; a < 16; a++) {
                memcpy(current.attributes[a],
                       pg->vertex_attributes[a].inline_value, 16);
                assert(pg->vertex_attributes[a].inline_buffer_populated ==
                       ((test + a) % 7 == 0));
                if (!pg->vertex_attributes[a].count)
                    assert(!memcmp(current.attributes[a], before[a], 16));
            }
            assert(!pg->compressed_attrs && !adapter.encodingCommands);
            [results
                addObject:((NV2AMetalPGRAPHFetchBatch *)reference[0]).fetch];
            [expected addObject:[NSData dataWithBytes:&current
                                               length:sizeof(current)]];
            require([surfaces checkpointWithError:&error], error);
            cases++;
        }
        require([surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error],
                error);
        for (unsigned i = 0; i < results.count; i++) {
            NV2AMetalFetchResult *result = results[i];
            NSData *bits = expected[i];
            const void *actual =
                (uint8_t *)result.attributes.contents +
                result.vertexCount * sizeof(NV2AMetalProgramInput);
            if (memcmp(actual, bits.bytes, bits.length)) {
                fprintf(stderr, "Packed Current mismatch family%u test%u\n",
                        family, i);
                abort();
            }
            const uint32_t *faults = result.faults.contents;
            for (unsigned v = 0; v <= result.vertexCount; v++)
                assert(!faults[v]);
        }
    }
    for (unsigned invalid = 0; invalid < 9; invalid++) {
        reset();
        PGRAPHState *pg = &state->pgraph;
        VertexAttribute *a = &pg->vertex_attributes[0];
        a->format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1;
        a->count = 4;
        a->size = 2;
        pg->inline_array_length = 2;
        if (invalid == 0)
            a->size = 1;
        if (invalid == 1)
            a->count = 5;
        if (invalid == 2)
            a->format = 7;
        if (invalid == 3)
            pg->inline_array_length = 1;
        if (invalid == 4)
            pg->inline_elements_length = 1;
        if (invalid == 5)
            pg->draw_arrays_length = 1;
        if (invalid == 6)
            pg->inline_buffer_length = 1;
        if (invalid == 7)
            pg->inline_array_length = NV2A_MAX_BATCH_LENGTH + 1;
        uint32_t before[4];
        memcpy(before, a->inline_value, 16);
        error = nil;
        assert(![adapter encodeInlineCurrentSnapshotsWithPrefixes:@[
            @(invalid == 8 ? 2 : 0)
        ]
                                                            error:&error] &&
               error);
        assert(!adapter.encodingCommands && !surfaces.commands.commandBuffer &&
               !memcmp(before, a->inline_value, 16));
    }
    reset();
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0].format =
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP;
    pg->vertex_attributes[0].count = 1;
    pg->vertex_attributes[0].size = 4;
    pg->inline_array_length = 1;
    pg->inline_array[0] = 0xffffffff;
    pg->compressed_attrs = 0x8091;
    uint32_t before[4];
    memcpy(before, pg->vertex_attributes[0].inline_value, 16);
    require([adapter encodeInlineCurrentSnapshotsWithPrefixes:@[ @0 ]
                                                        error:&error] != nil,
            error);
    [adapter cancel];
    assert(![adapter completeInlineCurrentSnapshotsWithError:NULL] &&
           !adapter.encodingCommands && !surfaces.commands.commandBuffer &&
           pg->compressed_attrs == 0x8091 &&
           !memcmp(before, pg->vertex_attributes[0].inline_value, 16));
    puts("Packed Current:nine invalid layout/prefix/conflict rejects and "
         "cancelled CMP capture preserve Current/flags PASS");
    assert(cases == 2440);
    puts("Packed Current:2440 exact native GPU Current comparisons;all256 "
         "byte/all65536 short codes,all2048/1024 CMP component codes,six "
         "formats/16 mixed interleaved "
         "attributes/counts0..4/defaults,prefixes0..3,trailing partial "
         "record,immutable source edits,populated flags and "
         "Current-before-completion isolation PASS");
    groups++;
}
#endif
