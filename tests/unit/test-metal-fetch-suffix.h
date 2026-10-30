/* Compact decoded suffixes retain full-input Current selection.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FETCH_SUFFIX_H
#define TEST_METAL_FETCH_SUFFIX_H
static void fetch_suffix_tests(NV2AMetalVertexFetch *fetch,
                               NV2AMetalCommands *commands)
{
    enum { Count = 33, SourceCount = 80 };
    NSError *error = nil;
    id<MTLBuffer> source =
        [commands.device newBufferWithLength:SourceCount * 16
                                     options:MTLResourceStorageModeShared];
    assert(source);
    for (unsigned i = 0; i < SourceCount * 4; i++)
        ((float *)source.contents)[i] = (float)((int)i - 101) / 8;
    unsigned formats[] = { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                           NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                           NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                           NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
                           NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP };
    NSUInteger prefixes[] = { 0, 1, 17, Count - 1, Count };
    unsigned cases = 0;
    uint64_t avoided = 0;
    for (unsigned indexed = 0; indexed < 3; indexed++)
        for (unsigned zeroStride = 0; zeroStride < 2; zeroStride++)
            for (unsigned p = 0; p < 5; p++) {
                NSUInteger prefix = prefixes[p];
                NSUInteger currents[] = { NSNotFound, 0,
                                          prefix ? prefix - 1 : 0,
                                          prefix < Count ? prefix : Count - 1,
                                          Count - 1 };
                for (unsigned c = 0; c < 5; c++) {
                    NV2AMetalAttributeSource sources[16] = { 0 };
                    for (unsigned i = 0; i < 16; i++) {
                        sources[i].inline_value[0] = i + .25f;
                        sources[i].inline_value[3] = 1;
                        if (i == 15)
                            continue;
                        sources[i].buffer = source;
                        sources[i].byteLength = source.length;
                        sources[i].format = formats[i % 6];
                        sources[i].count = i % 6 == 5 ? 1 : 4;
                        sources[i].stride = zeroStride && (i & 1) ? 0 : 16;
                    }
                    NSUInteger indexSize = indexed == 1 ? 2 :
                                           indexed == 2 ? 4 :
                                                          0;
                    id<MTLBuffer> indices = nil;
                    if (indexed) {
                        indices = [commands.device
                            newBufferWithLength:12 + Count * indexSize
                                        options:MTLResourceStorageModeShared];
                        assert(indices);
                        for (unsigned i = 0; i < Count; i++) {
                            uint32_t value = (i * 13 + 7) % 64;
                            memcpy((uint8_t *)indices.contents + 12 +
                                       i * indexSize,
                                   &value, indexSize);
                        }
                    }
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalFetchResult *reference =
                        [fetch encodeSources:sources
                                       count:Count
                                 firstVertex:3
                                     indices:indices
                                 indexOffset:indexed ? 12 : 0
                                   indexSize:(unsigned)indexSize
                               currentVertex:currents[c]
                                    commands:commands
                                       error:&error];
                    NV2AMetalFetchResult *compact =
                        [fetch encodeSources:sources
                                       count:Count
                                 firstVertex:3
                                     indices:indices
                                 indexOffset:indexed ? 12 : 0
                                   indexSize:(unsigned)indexSize
                               currentVertex:currents[c]
                              skippingPrefix:prefix
                                    commands:commands
                                       error:&error];
                    require(reference && compact, error);
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                    NSUInteger decoded = Count - prefix;
                    BOOL current = currents[c] != NSNotFound;
                    assert(compact.vertexCount == decoded &&
                           compact.hasCurrent == current);
                    if (decoded + current) {
                        assert(compact.attributes.length ==
                               (decoded + current) *
                                   sizeof(NV2AMetalProgramInput));
                        assert(compact.faults.length ==
                               (decoded + current + 1) * sizeof(uint32_t));
                        assert(
                            !memcmp(compact.attributes.contents,
                                    (const NV2AMetalProgramInput *)
                                            reference.attributes.contents +
                                        prefix,
                                    decoded * sizeof(NV2AMetalProgramInput)));
                        const uint32_t *faults = compact.faults.contents;
                        for (NSUInteger i = 0; i < decoded; i++)
                            assert(!faults[i]);
                        assert(
                            !*(uint32_t *)((uint8_t *)compact.faults.contents +
                                           compact.faultSummaryOffset));
                        if (current) {
                            assert(
                                !memcmp((const NV2AMetalProgramInput *)
                                                compact.attributes.contents +
                                            decoded,
                                        (const NV2AMetalProgramInput *)
                                                reference.attributes.contents +
                                            Count,
                                        sizeof(NV2AMetalProgramInput)));
                            assert(!faults[decoded]);
                        }
                    } else
                        assert(!compact.attributes && !compact.faults);
                    avoided +=
                        reference.attributes.length + reference.faults.length -
                        compact.attributes.length - compact.faults.length;
                    cases++;
                }
            }
    {
        /* A large accepted prefix must not allocate its decoded attributes
         * again. Both buffers are real allocations, not estimated counters. */
        const NSUInteger large = 65536;
        NV2AMetalAttributeSource sources[16] = { 0 };
        sources[0] = (NV2AMetalAttributeSource){
            .buffer = source,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .count = 4,
            .stride = 0
        };
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalFetchResult *reference = [fetch encodeSources:sources
                                                         count:large
                                                   firstVertex:7
                                                       indices:nil
                                                   indexOffset:0
                                                     indexSize:0
                                                 currentVertex:0
                                                      commands:commands
                                                         error:&error];
        NV2AMetalFetchResult *compact = [fetch encodeSources:sources
                                                       count:large
                                                 firstVertex:7
                                                     indices:nil
                                                 indexOffset:0
                                                   indexSize:0
                                               currentVertex:0
                                              skippingPrefix:large - 1
                                                    commands:commands
                                                       error:&error];
        require(reference && compact, error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        assert(compact.vertexCount == 1 && compact.attributes.length == 512 &&
               compact.faults.length == 12 &&
               reference.attributes.length == 16777472);
        assert(!memcmp(
            compact.attributes.contents,
            (const NV2AMetalProgramInput *)reference.attributes.contents +
                large - 1,
            sizeof(NV2AMetalProgramInput)));
        assert(!memcmp(
            (const NV2AMetalProgramInput *)compact.attributes.contents + 1,
            (const NV2AMetalProgramInput *)reference.attributes.contents +
                large,
            sizeof(NV2AMetalProgramInput)));
        avoided += reference.attributes.length + reference.faults.length -
                   compact.attributes.length - compact.faults.length;
        cases++;
    }
    /* Current remains bounds checked even when its ordinal lies before the
     * suffix; requested suffix faults and index overflow retain their words. */
    for (unsigned faultCase = 0; faultCase < 3; faultCase++) {
        NV2AMetalAttributeSource sources[16] = { 0 };
        sources[0] = (NV2AMetalAttributeSource){
            .buffer = source,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .count = 4,
            .stride = 16
        };
        uint32_t indices[8] = { 0, 1, 2, 3, 4, 5, 6, 7 };
        indices[faultCase ? 7 : 0] = UINT32_MAX;
        id<MTLBuffer> indexBuffer =
            [commands.device newBufferWithBytes:indices
                                         length:sizeof(indices)
                                        options:MTLResourceStorageModeShared];
        assert(indexBuffer);
        NSUInteger current = faultCase == 1 ? 7 : 0;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalFetchResult *reference = [fetch encodeSources:sources
                                                         count:8
                                                   firstVertex:3
                                                       indices:indexBuffer
                                                   indexOffset:0
                                                     indexSize:4
                                                 currentVertex:current
                                                      commands:commands
                                                         error:&error];
        NV2AMetalFetchResult *compact = [fetch encodeSources:sources
                                                       count:8
                                                 firstVertex:3
                                                     indices:indexBuffer
                                                 indexOffset:0
                                                   indexSize:4
                                               currentVertex:current
                                              skippingPrefix:4
                                                    commands:commands
                                                       error:&error];
        require(reference && compact, error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        assert(!memcmp(compact.faults.contents,
                       (const uint32_t *)reference.faults.contents + 4,
                       4 * sizeof(uint32_t)));
        assert(((const uint32_t *)compact.faults.contents)[4] ==
               ((const uint32_t *)reference.faults.contents)[8]);
        assert(*(uint32_t *)((uint8_t *)compact.faults.contents +
                             compact.faultSummaryOffset) == UINT32_MAX);
        assert(!memcmp(
            (const NV2AMetalProgramInput *)compact.attributes.contents + 4,
            (const NV2AMetalProgramInput *)reference.attributes.contents + 8,
            sizeof(NV2AMetalProgramInput)));
        cases++;
    }
    /* Full input span validation remains mandatory even when no output is
     * requested. A compact suffix must not bypass the original DMA contract. */
    NV2AMetalAttributeSource sources[16] = { 0 };
    sources[0] = (NV2AMetalAttributeSource){
        .buffer = source,
        .byteLength = source.length,
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .count = 4,
        .stride = 16
    };
    require([commands beginWithError:&error] != nil, error);
    assert(![fetch encodeSources:sources
                           count:Count
                     firstVertex:0
                         indices:nil
                     indexOffset:0
                       indexSize:0
                   currentVertex:0
                  skippingPrefix:Count + 1
                        commands:commands
                           error:&error]);
    assert(![fetch encodeSources:sources
                           count:SourceCount
                     firstVertex:3
                         indices:nil
                     indexOffset:0
                       indexSize:0
                   currentVertex:NSNotFound
                  skippingPrefix:SourceCount
                        commands:commands
                           error:&error]);
    id<MTLBuffer> shortIndices =
        [commands.device newBufferWithLength:Count * 2 - 1
                                     options:MTLResourceStorageModeShared];
    assert(shortIndices);
    assert(![fetch encodeSources:sources
                           count:Count
                     firstVertex:0
                         indices:shortIndices
                     indexOffset:0
                       indexSize:2
                   currentVertex:NSNotFound
                  skippingPrefix:Count
                        commands:commands
                           error:&error]);
    [commands cancel];
    printf(
        "Compact Fetch suffix: %u full/suffix/Current pairs across six formats,"
        "stride-zero and16/32-bit indices;%llu logical output bytes avoided;"
        "full-span/prefix/index-tail rejection PASS\n",
        cases, (unsigned long long)avoided);
}
#endif
