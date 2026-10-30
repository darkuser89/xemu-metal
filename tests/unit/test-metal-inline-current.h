/* Bit-exact known Float4 Current versus native GPU decoding.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INLINE_CURRENT_H
#define TEST_METAL_INLINE_CURRENT_H
static void inline_current_tests(void)
{
    NSError *error = nil;
    NSMutableArray *results = [NSMutableArray new],
                   *expected = [NSMutableArray new];
    const uint32_t special[] = { 0,          0x80000000, 1,          0x80000001,
                                 0x007fffff, 0x00800000, 0x3f800000, 0x7f7fffff,
                                 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc12345,
                                 0x7f812345, 0xff812345 };
    for (unsigned test = 0; test < 128; test++) {
        reset();
        PGRAPHState *pg = &state->pgraph;
        pg->inline_buffer_length = 3;
        pg->compressed_attrs = 0xffff;
        uint32_t source[16][3][4], before[16][4];
        for (unsigned a = 0; a < 16; a++) {
            for (unsigned v = 0; v < 3; v++)
                for (unsigned c = 0; c < 4; c++)
                    source[a][v][c] =
                        special[(test + a * 3 + v + c) %
                                (sizeof(special) / sizeof(*special))];
            for (unsigned c = 0; c < 4; c++)
                before[a][c] = 0x3f000000 + a * 19 + c;
            memcpy(pg->vertex_attributes[a].inline_value, before[a], 16);
            pg->vertex_attributes[a].inline_buffer_populated =
                test % 3 == 0 || ((a + test) & 1);
            pg->vertex_attributes[a].inline_buffer = (float *)source[a];
        }
        NSArray *reference = current_gpu_reference(@[ @(test % 4) ], nil);
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            [adapter encodeInlineCurrentSnapshotsWithPrefixes:@[ @(test % 4) ]
                                                        error:&error];
        require(batches != nil, error);
        check_captured_fetch(batches);
        assert(batches.count == 1 &&
               adapter.encodingCommands == surfaces.commands);
        NV2AMetalProgramInput bits;
        for (unsigned a = 0; a < 16; a++)
            memcpy(bits.attributes[a],
                   pg->vertex_attributes[a].inline_buffer_populated ?
                       source[a][2] :
                       before[a],
                   16);
        memset(source, 0xa5, sizeof(source));
        require([adapter completeInlineCurrentSnapshotsWithError:&error],
                error);
        assert(!adapter.encodingCommands && !pg->compressed_attrs);
        for (unsigned a = 0; a < 16; a++) {
            assert(!memcmp(pg->vertex_attributes[a].inline_value,
                           bits.attributes[a], 16));
            assert(!pg->vertex_attributes[a].inline_buffer_populated);
        }
        assert(![adapter completeInlineCurrentSnapshotsWithError:&error]);
        [results addObject:((NV2AMetalPGRAPHFetchBatch *)reference[0]).fetch];
        [expected addObject:[NSData dataWithBytes:&bits length:sizeof(bits)]];
        require([surfaces checkpointWithError:&error], error);
    }
    require([surfaces submitWithError:&error], error);
    require([surfaces waitUntilIdleWithError:&error], error);
    for (unsigned i = 0; i < results.count; i++) {
        NV2AMetalFetchResult *r = results[i];
        NSData *bits = expected[i];
        assert(!memcmp((const uint8_t *)r.attributes.contents +
                           r.vertexCount * sizeof(NV2AMetalProgramInput),
                       bits.bytes, bits.length));
        assert(!((uint32_t *)r.faults.contents)[r.vertexCount]);
    }
    reset();
    assert(![adapter encodeInlineCurrentSnapshotsWithPrefixes:@[]
                                                        error:&error]);
    state->pgraph.inline_array_length = 4;
    assert(![adapter encodeInlineCurrentSnapshotsWithPrefixes:@[ @0 ]
                                                        error:&error]);
    reset();
    state->pgraph.inline_buffer_length = 3;
    state->pgraph.vertex_attributes[0].inline_buffer_populated = true;
    assert(![adapter encodeInlineCurrentSnapshotsWithPrefixes:@[ @0 ]
                                                        error:&error]);
    assert(!adapter.encodingCommands && !surfaces.commands.commandBuffer);
    puts("Known inline Current:128 exact native Float4 comparisons; all 16 "
         "attributes, "
         "mixed populated masks, prefixes0..3, signed "
         "zero/subnormal/infinity/NaN payloads, "
         "immutable source mutation, repeated completion and invalid sources "
         "PASS");
    groups++;
}
#endif
