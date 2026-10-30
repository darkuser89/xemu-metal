/* A cached prefix never bypasses full PGRAPH DMA/index validation.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PGRAPH_FETCH_SUFFIX_H
#define TEST_METAL_PGRAPH_FETCH_SUFFIX_H
#import "hw/xbox/nv2a/pgraph/metal/pending-journal.h"
static BOOL suffix_cached_indices;
static NV2AMetalPendingInput *suffix_index_input;
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
suffix_encode(NSArray<NSNumber *> *prefixes, NSError **error)
{
    if (suffix_cached_indices)
        suffix_index_input = [NV2AMetalPendingInput
                indexedBytes:state->pgraph.inline_elements
                       count:state->pgraph.inline_elements_length
            matchingPrevious:suffix_index_input];
    return [adapter encodeIndependentSnapshotsWithPrefixes:prefixes
                                              indexedInput:suffix_index_input
                                                     error:error];
}
static void packed_pgraph_suffix_tests(void)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    PGRAPHState *pg = &state->pgraph;
    const unsigned formats[] = {
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL
    };
    const unsigned sizes[] = { 4, 1, 2, 2, 4, 1 },
                   counts[] = { 3, 4, 3, 1, 1, 3 };
    for (unsigned i = 0; i < 6; i++)
        pg->vertex_attributes[i] = (VertexAttribute){ .format = formats[i],
                                                      .size = sizes[i],
                                                      .count = counts[i] };
    pg->inline_array_length = 39; /* Five 31-byte records plus one tail byte. */
    uint8_t *raw = (uint8_t *)pg->inline_array;
    for (unsigned i = 0; i < 156; i++)
        raw[i] = (uint8_t)(i * 37 + 11);
    for (unsigned row = 0; row < 5; row++) {
        float pos[] = { row + .25f, row + .5f, row + .75f };
        memcpy(raw + row * 31, pos, sizeof(pos));
        raw[row * 31 + 12] = row + 10;
        raw[row * 31 + 13] = row + 30;
        raw[row * 31 + 14] = row + 50;
        raw[row * 31 + 15] = 200;
    }
    NSArray<NV2AMetalPGRAPHFetchBatch *> *reference =
        [adapter prepareWithError:&error];
    require(reference != nil, error);
    assert(reference.count == 1 && reference[0].fetch.vertexCount == 5);
    const NV2AMetalProgramInput *expected =
        reference[0].fetch.attributes.contents;
    const NSUInteger prefixes[] = { 1, 3, 4, 5 };
    for (unsigned p = 0; p < 4; p++) {
        NSUInteger prefix = prefixes[p];
        for (unsigned i = 0; i < 6; i++)
            for (unsigned k = 0; k < 4; k++)
                pg->vertex_attributes[i].inline_value[k] = -9;
        pg->compressed_attrs = 0x2000;
        NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
            [adapter encodeIndependentSnapshotsWithPrefixes:@[ @(prefix) ]
                                                      error:&error];
        require(b != nil, error);
        assert(b.count == 1 && b[0].inputVertexCount == 5 &&
               b[0].firstDecodedVertex == prefix);
        assert(pg->vertex_attributes[0].inline_value[0] == -9);
        /* The GPU must retain the earlier Current color in its immutable
         * snapshot, even after changing the original unaligned CPU stream. */
        uint8_t before = raw[4 * 31 + 12];
        raw[4 * 31 + 12] ^= 0x7f;
        require([adapter completeWithError:&error], error);
        raw[4 * 31 + 12] = before;
        assert(!pg->compressed_attrs && b[0].fetch.vertexCount == 5 - prefix);
        const NV2AMetalProgramInput *actual = b[0].fetch.attributes.contents;
        assert(
            !memcmp(actual, expected + prefix, (5 - prefix) * sizeof(*actual)));
        assert(!memcmp(actual + 5 - prefix, expected + 5, sizeof(*actual)));
        for (unsigned i = 0; i < 6; i++)
            assert(!memcmp(pg->vertex_attributes[i].inline_value,
                           expected[5].attributes[i], 16));
    }
    groups += 4;
    puts("Packed compact capture:four suffix/Current-only pairs,six "
         "formats,31-byte "
         "unaligned records,partial tail ignored;post-capture CPU mutation "
         "isolated and exact Current bytes PASS");
}
static void pgraph_fetch_suffix_tests(void)
{
    for (unsigned cached = 0; cached < 2; cached++) {
        suffix_cached_indices = cached;
        suffix_index_input = nil;
        NSError *error = nil;
        require([surfaces discardForRestoreWithError:&error], error);
        reset();
        PGRAPHState *pg = &state->pgraph;
        dma_a.address = 1024;
        dma_a.limit = 63;
        pg->vertex_attributes[0] =
            (VertexAttribute){ .format =
                                   NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                               .size = 4,
                               .count = 4,
                               .stride = 16 };
        pg->vertex_attributes[0].inline_value[0] = -1;
        pg->vertex_attributes[0].inline_value[3] = 1;
        pg->compressed_attrs = 0x400;
        float positions[2][4] = { { 1, 2, 3, 1 }, { 4, 5, 6, 1 } };
        cpu_write(1024, sizeof(positions));
        memcpy(state->vram_ptr + 1024, positions, sizeof(positions));
        pg->inline_elements_length = 3;
        pg->inline_elements[0] =
            999; /* Skipped prefix; Current selects index zero. */
        pg->inline_elements[1] = pg->inline_elements[2] = 0;
        assert(!suffix_encode(@[ @2 ], &error) && error);
        assert(pg->vertex_attributes[0].inline_value[0] == -1 &&
               pg->compressed_attrs == 0x400);
        pg->inline_elements[0] = 1;
        NSArray *invalid[] = { @[], @[ @4 ], @[ @-1 ], @[ @1.5 ],
                               @[ NSNull.null ] };
        for (unsigned i = 0; i < 5; i++) {
            error = nil;
            assert(!suffix_encode(invalid[i], &error) && error);
            assert(pg->vertex_attributes[0].inline_value[0] == -1 &&
                   pg->compressed_attrs == 0x400 && !adapter.encodingCommands);
        }
        NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
            suffix_encode(@[ @2 ], &error);
        require(b != nil, error);
        assert(b.count == 1 && b[0].inputVertexCount == 3 &&
               b[0].firstDecodedVertex == 2 && b[0].fetch.vertexCount == 1 &&
               b[0].fetch.attributes.length == 512);
        assert(pg->vertex_attributes[0].inline_value[0] == -1);
        pg->inline_elements[2] = 1; /* Captured last index was zero. */
        require([adapter completeWithError:&error], error);
        pg->inline_elements[2] = 0;
        scalar(pg->vertex_attributes[0].inline_value[0], 1);
        assert(!pg->compressed_attrs);
        pg->vertex_attributes[0].inline_value[0] = -3.25f;
        b = suffix_encode(@[ @3 ], &error);
        require(b != nil, error);
        assert(b[0].fetch.vertexCount == 0 && b[0].fetch.hasCurrent &&
               b[0].fetch.attributes.length == 256 &&
               b[0].fetch.faults.length == 8);
        pg->inline_elements[2] = 1;
        require([adapter completeWithError:&error], error);
        pg->inline_elements[2] = 0;
        scalar(pg->vertex_attributes[0].inline_value[0], 1);
        groups += 8;
    }
    suffix_index_input = nil;
    NV2AMetalPendingInput *invalidInputs[] = {
        (id)NSNull.null, [NV2AMetalPendingInput arraysFrom:0 count:3],
        [NV2AMetalPendingInput indexedBytes:state->pgraph.inline_elements
                                      count:2
                           matchingPrevious:nil]
    };
    for (unsigned i = 0; i < 3; i++) {
        NSError *error = nil;
        assert(![adapter encodeIndependentSnapshotsWithPrefixes:@[ @2 ]
                                                   indexedInput:invalidInputs[i]
                                                          error:&error] &&
               error);
        scalar(state->pgraph.vertex_attributes[0].inline_value[0], 1);
        assert(!adapter.encodingCommands);
    }
    puts(
        "PGRAPH compact Fetch:full DMA rejection inside skipped indexed prefix,"
        "five malformed-prefix rejections with unchanged Current,corrected "
        "suffix"
        "and Current-only completion with live/cached full bounds, three "
        "invalid snapshots rejected PASS");
    packed_pgraph_suffix_tests();
}
#endif
