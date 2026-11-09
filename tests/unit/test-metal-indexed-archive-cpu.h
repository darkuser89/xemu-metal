/* Compact physical vertex wire format, no Metal runtime.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_INDEXED_ARCHIVE_CPU_H
#define TEST_METAL_INDEXED_ARCHIVE_CPU_H
static unsigned compactRoundtrips, compactRejections;
static NSData *compact_expand(NSData *physical, NSData *remap)
{
    if (!remap.length)
        return physical;
    NSMutableData *result = [NSMutableData new];
    for (NSUInteger n = 0; n < remap.length / 4; n++) {
        uint32_t index;
        memcpy(&index, (const uint8_t *)remap.bytes + n * 4, 4);
        [result appendBytes:(const uint8_t *)physical.bytes +
                            index * sizeof(NV2AMetalVertex)
                     length:sizeof(NV2AMetalVertex)];
    }
    return result;
}
static void compact_be(NSMutableData *wire, uint32_t value)
{
    uint8_t bytes[4] = { value >> 24, value >> 16, value >> 8, value };
    [wire appendBytes:bytes length:sizeof(bytes)];
}
static void compact_payload(NSMutableData *wire, NSData *payload)
{
    for (NSUInteger n = 0; n < payload.length; n += 4) {
        uint32_t value;
        memcpy(&value, (const uint8_t *)payload.bytes + n, 4);
        compact_be(wire, value);
    }
}
/* Independent format oracle fixes field order, word endianness and placement
 * of physical records before remap ordinals. */
static NSData *compact_fixture(unsigned version,
                               NSArray<NV2AMetalPendingInput *> *inputs,
                               NSArray<NSData *> *physical,
                               NSArray<NSData *> *remaps)
{
    NSMutableData *wire = [NSMutableData new];
    NSUInteger total = 0;
    for (NV2AMetalPendingInput *source in inputs)
        total += source.count;
    const uint32_t header[] = { 0x4d345650, version, 244,
                                (uint32_t)inputs.count, (uint32_t)total };
    for (unsigned n = 0; n < 5; n++)
        compact_be(wire, header[n]);
    for (NSUInteger n = 0; n < inputs.count; n++) {
        NV2AMetalPendingInput *source = inputs[n];
        compact_be(wire, source.kind);
        compact_be(wire, (uint32_t)source.first);
        compact_be(wire, (uint32_t)source.count);
        compact_be(wire, (uint32_t)(source.indices.length / 4));
        if (version == 2) {
            compact_be(wire, (uint32_t)(physical[n].length / 244));
            compact_be(wire, (uint32_t)(remaps[n].length / 4));
        }
        compact_payload(wire, source.indices);
        compact_payload(wire, physical[n]);
        if (version == 2)
            compact_payload(wire, remaps[n]);
    }
    return wire;
}
static void compact_check(NSArray<NV2AMetalPendingInput *> *inputs,
                          NSArray<NSData *> *physical,
                          NSArray<NSData *> *remaps, NSUInteger limit,
                          BOOL journal)
{
    NSError *error = nil;
    NV2AMetalPendingArchive *archive =
        [[NV2AMetalPendingArchive alloc] initWithInputs:inputs
                                       physicalVertices:physical
                                                 remaps:remaps
                                                  limit:limit
                                                  error:&error];
    assert(archive && !error);
    BOOL indexed = NO;
    for (NSData *map in remaps)
        indexed |= map.length != 0;
    NSData *wire = archive.data;
    assert([wire isEqualToData:compact_fixture(indexed ? 2 : 1, inputs,
                                               physical, remaps)]);
    archive = [[NV2AMetalPendingArchive alloc] initWithData:wire
                                                      limit:limit
                                                      error:&error];
    assert(archive && !error && [archive.data isEqualToData:wire] &&
           [archive.physicalVertices isEqualToArray:physical] &&
           [archive.remaps isEqualToArray:remaps]);
    NSArray<NSData *> *logical = archive.vertices;
    for (NSUInteger i = 0; i < inputs.count; i++) {
        assert(
            logical[i].length == inputs[i].count * sizeof(NV2AMetalVertex) &&
            [logical[i] isEqualToData:compact_expand(physical[i], remaps[i])]);
        assert(archive.inputs[i].kind == inputs[i].kind &&
               archive.inputs[i].first == inputs[i].first &&
               [archive.inputs[i].indices isEqualToData:inputs[i].indices]);
    }
    if (journal) {
        NV2AMetalPendingJournal *restored = archive.CPUJournal;
        assert(restored && restored.retainedStreams.count == inputs.count);
        for (NSUInteger i = 0; i < inputs.count; i++) {
            NV2AMetalPendingSpan *span = restored.retainedStreams[i][0];
            assert(span.first == 0 && span.count == inputs[i].count &&
                   [span.resource isEqualToData:logical[i]]);
        }
    }
    compactRoundtrips++;
}
static void compact_reject(NSData *wire, NSUInteger limit)
{
    NSError *error = nil;
    assert(![[NV2AMetalPendingArchive alloc] initWithData:wire
                                                    limit:limit
                                                    error:&error] &&
           error);
    compactRejections++;
}
static void compact_init_reject(NSArray *inputs, NSArray *physical,
                                NSArray *remaps, NSUInteger limit)
{
    NSError *error = nil;
    assert(![[NV2AMetalPendingArchive alloc] initWithInputs:inputs
                                           physicalVertices:physical
                                                     remaps:remaps
                                                      limit:limit
                                                      error:&error] &&
           error);
    compactRejections++;
}
static void compact_archive_tests(void)
{
    const unsigned counts[] = { 1, 2, 3, 7, 16, 31, 32 };
    for (unsigned kind = 1; kind <= 4; kind++)
        for (unsigned c = 0; c < 7; c++)
            for (unsigned physical = 1; physical <= counts[c]; physical++)
                @autoreleasepool {
                    NSUInteger logical = counts[c];
                    NSMutableData *map =
                        [NSMutableData dataWithLength:logical * 4];
                    for (NSUInteger n = 0; n < logical; n++) {
                        uint32_t ordinal =
                            (uint32_t)((n * 3 + kind) % physical);
                        memcpy((uint8_t *)map.mutableBytes + n * 4, &ordinal,
                               4);
                    }
                    compact_check(@[ input(kind, (unsigned)logical) ],
                                  @[ raw(physical, c + kind) ], @[ map ],
                                  logical, physical == 1);
                }
    const uint32_t repeated[] = { 2, 0, 2, 1, 0, 1, 2 };
    const uint32_t reversed[] = { 1, 1, 0, 1 };
    NSData *firstMap = [NSData dataWithBytes:repeated length:sizeof(repeated)],
           *secondMap = [NSData dataWithBytes:reversed length:sizeof(reversed)];
    NSArray<NV2AMetalPendingInput *> *inputs =
        @[ input(1, 3), input(2, 7), input(4, 4) ];
    NSArray<NSData *> *physical = @[ raw(3, 1), raw(3, 5), raw(2, 7) ],
                      *maps = @[ [NSData data], firstMap, secondMap ];
    compact_check(inputs, physical, maps, 14, YES);
    compact_init_reject(inputs, physical, maps, 13);
    compact_init_reject(@[ input(1, 1) ], @[], @[ [NSData data] ], 1);
    compact_init_reject(@[ input(1, 1) ], @[ raw(1, 0) ], @[], 1);
    compact_init_reject(@[ NSNull.null ], @[ raw(1, 0) ], @[ [NSData data] ],
                        1);
    compact_init_reject(@[ input(1, 1) ], @[ NSNull.null ], @[ [NSData data] ],
                        1);
    compact_init_reject(@[ input(1, 1) ], @[ raw(1, 0) ], @[ NSNull.null ], 1);
    compact_init_reject(@[ input(1, 1) ], @[ [NSData data] ],
                        @[ [NSData data] ], 1);
    compact_init_reject(@[ input(1, 1) ],
                        @[ [NSMutableData dataWithLength:243] ],
                        @[ [NSData data] ], 1);
    compact_init_reject(@[ input(1, 1) ], @[ raw(2, 0) ], @[ [NSData data] ],
                        1);
    compact_init_reject(@[ input(1, 2) ], @[ raw(1, 0) ], @[ [NSData data] ],
                        2);
    compact_init_reject(@[ input(1, 2) ], @[ raw(1, 0) ],
                        @[ [NSMutableData dataWithLength:3] ], 2);
    compact_init_reject(@[ input(1, 2) ], @[ raw(1, 0) ],
                        @[ [NSMutableData dataWithLength:4] ], 2);
    compact_init_reject(@[ input(1, 2) ], @[ raw(1, 0) ],
                        @[ [NSMutableData dataWithLength:12] ], 2);
    uint32_t badMap[] = { 0, 1 };
    compact_init_reject(
        @[ input(1, 2) ], @[ raw(1, 0) ],
        @[ [NSData dataWithBytes:badMap length:sizeof(badMap)] ], 2);
    badMap[1] = UINT32_MAX;
    compact_init_reject(
        @[ input(1, 2) ], @[ raw(1, 0) ],
        @[ [NSData dataWithBytes:badMap length:sizeof(badMap)] ], 2);
    compact_init_reject(@[ input(1, 2) ], @[ raw(1, 0) ],
                        @[ [NSMutableData dataWithLength:8] ], 0);
    compact_init_reject(@[ input(1, 2) ], @[ raw(1, 0) ],
                        @[ [NSMutableData dataWithLength:8] ], 524288);

    NSError *error = nil;
    const uint32_t simpleMap[] = { 1, 0, 1, 0 };
    NSData *simple = [NSData dataWithBytes:simpleMap length:sizeof(simpleMap)];
    NV2AMetalPendingArchive *sample =
        [[NV2AMetalPendingArchive alloc] initWithInputs:@[ input(2, 4) ]
                                       physicalVertices:@[ raw(2, 3) ]
                                                 remaps:@[ simple ]
                                                  limit:4
                                                  error:&error];
    assert(sample && !error);
    NSData *wire = sample.data;
    for (NSUInteger length = 0; length < wire.length; length++)
        compact_reject([wire subdataWithRange:NSMakeRange(0, length)], 4);
    const uint32_t malformed[][2] = {
        { 0, 0 },   { 4, 0 },  { 4, 1 },           { 4, 3 },
        { 8, 240 }, { 12, 0 }, { 12, 1251 },       { 16, 3 },
        { 16, 5 },  { 20, 0 }, { 20, 5 },          { 24, 1 },
        { 28, 0 },  { 28, 5 }, { 32, 3 },          { 32, UINT32_MAX },
        { 36, 0 },  { 36, 5 }, { 36, UINT32_MAX }, { 40, 0 },
        { 40, 3 },  { 40, 5 }, { 40, UINT32_MAX }
    };
    for (NSUInteger n = 0; n < sizeof(malformed) / sizeof(malformed[0]); n++)
        compact_reject(word(wire, malformed[n][0], malformed[n][1]), 4);
    NSUInteger mapOffset = 20 + 24 + 4 * 4 + 2 * 244;
    for (unsigned n = 0; n < 4; n++) {
        compact_reject(word(wire, (unsigned)(mapOffset + n * 4), 2), 4);
        compact_reject(word(wire, (unsigned)(mapOffset + n * 4), UINT32_MAX),
                       4);
    }
    NSMutableData *trailing = [wire mutableCopy];
    uint8_t byte = 0;
    [trailing appendBytes:&byte length:1];
    compact_reject(trailing, 4);
    compact_reject(wire, 3);
    compact_reject(compact_fixture(2, @[], @[], @[]), 1);
    compact_reject(compact_fixture(2, @[ input(1, 2) ], @[ raw(2, 0) ],
                                   @[ [NSData data] ]),
                   2);
    compact_reject(
        compact_fixture(2, @[ [NV2AMetalPendingInput arraysFrom:UINT32_MAX
                                                          count:1] ],
                        @[ raw(1, 0) ], @[ [NSMutableData dataWithLength:4] ]),
        0);
    /* The original guest DMA index and transformed physical ordinal are
     * separate domains: UINT32_MAX guest IDs remain canonical metadata. */
    uint32_t guest[] = { UINT32_MAX, 0x80000000 };
    compact_check(
        @[ [NV2AMetalPendingInput
            indexed:[NSData dataWithBytes:guest length:sizeof(guest)]] ],
        @[ raw(1, 2) ], @[ [NSMutableData dataWithLength:8] ], 2, YES);

    NSMutableData *physicalMutable = [raw(2, 8) mutableCopy],
                  *mapMutable = [simple mutableCopy];
    NSMutableArray *inputMutable = [NSMutableArray arrayWithObject:input(1, 4)],
                   *physicalArray =
                       [NSMutableArray arrayWithObject:physicalMutable],
                   *mapArray = [NSMutableArray arrayWithObject:mapMutable];
    sample = [[NV2AMetalPendingArchive alloc] initWithInputs:inputMutable
                                            physicalVertices:physicalArray
                                                      remaps:mapArray
                                                       limit:4
                                                       error:&error];
    assert(sample && !error);
    NSData *before = sample.data, *beforeLogical = sample.vertices[0];
    memset(physicalMutable.mutableBytes, 0, physicalMutable.length);
    memset(mapMutable.mutableBytes, 0xff, mapMutable.length);
    [inputMutable removeAllObjects];
    [physicalArray removeAllObjects];
    [mapArray removeAllObjects];
    assert([before isEqualToData:sample.data] &&
           [beforeLogical isEqualToData:sample.vertices[0]]);

    /* Explicit linear-v1 fixtures survive the new initializer and decoder
     * byte-for-byte, including empty archives and the maximum DMA endpoint. */
    NSArray<NV2AMetalPendingInput *> *legacyInputs = @[
        [NV2AMetalPendingInput arraysFrom:UINT32_MAX count:1], input(2, 2),
        input(3, 1)
    ];
    NSArray<NSData *> *legacyPhysical = @[ raw(1, 0), raw(2, 3), raw(1, 8) ],
                      *legacyMaps =
                          @[ [NSData data], [NSData data], [NSData data] ];
    compact_check(legacyInputs, legacyPhysical, legacyMaps, 4, YES);
    NSData *fixture =
        compact_fixture(1, legacyInputs, legacyPhysical, legacyMaps);
    NV2AMetalPendingArchive *legacy =
        [[NV2AMetalPendingArchive alloc] initWithInputs:legacyInputs
                                               vertices:legacyPhysical
                                                  limit:4
                                                  error:&error];
    assert(legacy && !error && [legacy.data isEqualToData:fixture]);
    compact_check(@[], @[], @[], 1, YES);

    NSMutableData *wireMutable = [sample.data mutableCopy];
    NV2AMetalPendingArchive *wireIsolated =
        [[NV2AMetalPendingArchive alloc] initWithData:wireMutable
                                                limit:4
                                                error:&error];
    assert(wireIsolated && !error);
    NSData *wireBefore = wireIsolated.data;
    memset(wireMutable.mutableBytes, 0xff, wireMutable.length);
    assert([wireBefore isEqualToData:wireIsolated.data]);

    @autoreleasepool {
        NSMutableArray *manyInputs = [NSMutableArray new],
                       *manyPhysical = [NSMutableArray new],
                       *manyMaps = [NSMutableArray new];
        for (NSUInteger n = 0; n < 1250; n++) {
            [manyInputs addObject:input(1, 1)];
            [manyPhysical addObject:raw(1, (unsigned)n)];
            [manyMaps
                addObject:n ? [NSData data] : [NSMutableData dataWithLength:4]];
        }
        compact_check(manyInputs, manyPhysical, manyMaps, 1250, YES);
        [manyInputs addObject:input(1, 1)];
        [manyPhysical addObject:raw(1, 0)];
        [manyMaps addObject:[NSData data]];
        compact_init_reject(manyInputs, manyPhysical, manyMaps, 1251);
    }

    /* The logical aggregate remains bounded independently of compact byte
     * savings; a maximal constant remap consumes only one physical record. */
    @autoreleasepool {
        NSData *maxMap = [NSMutableData dataWithLength:524287 * 4];
        NV2AMetalPendingArchive *maximum = [[NV2AMetalPendingArchive alloc]
              initWithInputs:@[ input(4, 524287) ]
            physicalVertices:@[ raw(1, 0) ]
                      remaps:@[ maxMap ]
                       limit:524287
                       error:&error];
        assert(maximum && !error && maximum.physicalVertices[0].length == 244);
        NSData *maxWire = maximum.data;
        assert(maxWire.length == 20 + 24 + 244 + maxMap.length);
        maximum = [[NV2AMetalPendingArchive alloc] initWithData:maxWire
                                                          limit:524287
                                                          error:&error];
        assert(maximum && !error && maximum.inputs[0].count == 524287 &&
               [maximum.remaps[0] isEqualToData:maxMap]);
        compact_reject(maxWire, 524286);
        compact_init_reject(@[ input(4, 524288) ], @[ raw(1, 0) ],
                            @[ [NSMutableData dataWithLength:524288 * 4] ],
                            524287);
        compactRoundtrips++;
    }
    printf("Indexed archive CPU: %u v1/v2 canonical roundtrips, %u "
           "physical/remap/header/truncation rejections; BE32 fixtures, raw "
           "bits, mixed streams, copy isolation, CPU logical compatibility and "
           "maximal compact count PASS\n",
           compactRoundtrips, compactRejections);
}
#endif
