/* CPU-owned Float32 Current bit capture versus native packed GPU fetch.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PACKED_FLOAT_CURRENT_H
#define TEST_METAL_PACKED_FLOAT_CURRENT_H
static void packed_float_current_tests(void)
{
    NSError *error = nil;
    const uint32_t special[] = { 0,          0x80000000, 1,          0x80000001,
                                 0x007fffff, 0x00800000, 0x3f800000, 0x7f7fffff,
                                 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc12345,
                                 0x7f812345, 0xff812345 };
    NSMutableArray *results = [NSMutableArray new];
    NSMutableArray *expected = [NSMutableArray new];
    for (unsigned test = 0; test < 128; test++) {
        reset();
        PGRAPHState *pg = &state->pgraph;
        NSUInteger words = 0, offsets[16] = { 0 };
        uint32_t before[16][4];
        NV2AMetalProgramInput bits;
        for (unsigned a = 0; a < 16; a++) {
            unsigned count = (test + a) % 5;
            pg->vertex_attributes[a].format =
                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
            pg->vertex_attributes[a].count = count;
            pg->vertex_attributes[a].size = 4;
            pg->vertex_attributes[a].inline_buffer_populated =
                (test + a) % 7 == 0;
            offsets[a] = words;
            words += count;
            for (unsigned k = 0; k < 4; k++)
                before[a][k] = special[(test + a + k) % 14];
            memcpy(pg->vertex_attributes[a].inline_value, before[a], 16);
            memcpy(bits.attributes[a], before[a], 16);
        }
        for (unsigned v = 0; v < 4; v++)
            for (unsigned a = 0; a < 16; a++) {
                unsigned count = pg->vertex_attributes[a].count;
                for (unsigned k = 0; k < count; k++)
                    pg->inline_array[v * words + offsets[a] + k] =
                        special[(test + v + a * 3 + k) % 14];
                if (v == 2 && count) {
                    const uint32_t defaults[4] = { 0, 0, 0, 0x3f800000 };
                    memcpy(bits.attributes[a], defaults, 16);
                    memcpy(bits.attributes[a],
                           pg->inline_array + v * words + offsets[a],
                           count * 4);
                }
            }
        pg->inline_array_length = 3 * words + test % words;
        pg->compressed_attrs = 0xffff;
        NSArray *reference = current_gpu_reference(@[ @(test % 4) ], nil);
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            [adapter encodeInlineCurrentSnapshotsWithPrefixes:@[ @(test % 4) ]
                                                        error:&error];
        require(batches != nil, error);
        check_captured_fetch(batches);
        assert(batches.count == 1 &&
               adapter.encodingCommands == surfaces.commands);
        for (unsigned a = 0; a < 16; a++)
            assert(
                !memcmp(pg->vertex_attributes[a].inline_value, before[a], 16));
        memset(pg->inline_array, 0xa5, sizeof(pg->inline_array));
        require([adapter completeInlineCurrentSnapshotsWithError:&error],
                error);
        for (unsigned a = 0; a < 16; a++) {
            assert(!memcmp(pg->vertex_attributes[a].inline_value,
                           bits.attributes[a], 16));
            assert(pg->vertex_attributes[a].inline_buffer_populated ==
                   ((test + a) % 7 == 0));
        }
        assert(!adapter.encodingCommands && !pg->compressed_attrs);
        [results addObject:((NV2AMetalPGRAPHFetchBatch *)reference[0]).fetch];
        [expected addObject:[NSData dataWithBytes:&bits length:sizeof(bits)]];
        require([surfaces checkpointWithError:&error], error);
    }
    require([surfaces submitWithError:&error] &&
                [surfaces waitUntilIdleWithError:&error],
            error);
    for (unsigned i = 0; i < results.count; i++) {
        NV2AMetalFetchResult *result = results[i];
        NSData *bits = expected[i];
        assert(!memcmp((const uint8_t *)result.attributes.contents +
                           result.vertexCount * sizeof(NV2AMetalProgramInput),
                       bits.bytes, bits.length));
        assert(!((uint32_t *)result.faults.contents)[result.vertexCount]);
    }
    for (unsigned invalid = 0; invalid < 7; invalid++) {
        reset();
        PGRAPHState *pg = &state->pgraph;
        pg->inline_array_length = 4;
        pg->vertex_attributes[0].format =
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        pg->vertex_attributes[0].count = 4;
        pg->vertex_attributes[0].size = 4;
        switch (invalid) {
        case 0:
            pg->vertex_attributes[0].format =
                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
            break;
        case 1:
            pg->vertex_attributes[0].size = 2;
            break;
        case 2:
            pg->vertex_attributes[0].count = 5;
            break;
        case 3:
            pg->vertex_attributes[0].count = 0;
            break;
        case 4:
            pg->inline_array_length = 3;
            break;
        case 5:
            pg->inline_buffer_length = 1;
            break;
        case 6:
            pg->inline_elements_length = 1;
            break;
        }
        uint32_t before[4];
        memcpy(before, pg->vertex_attributes[0].inline_value, 16);
        error = nil;
        assert(![adapter encodeInlineCurrentSnapshotsWithPrefixes:@[ @0 ]
                                                            error:&error] &&
               error);
        assert(!adapter.encodingCommands && !surfaces.commands.commandBuffer &&
               !memcmp(before, pg->vertex_attributes[0].inline_value, 16));
    }
    puts("Packed Float32 Current:128 exact native GPU comparisons;16 "
         "interleaved "
         "attributes/counts0..4/default lanes,prefixes0..3,partial trailing "
         "record,signed zero/subnormal/Inf/NaN bits,immutable source mutation "
         "and populated flags;seven invalid/conflicting layouts reject "
         "without Current changes PASS");
    groups++;
}
#endif
