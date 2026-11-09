/* Native compact archives: exact physical identity, raw bits and GPU restore.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEXED_ARCHIVE_H
#define TEST_METAL_INDEXED_ARCHIVE_H
static unsigned compact_gpu_begins, compact_gpu_xf;
static id (*compact_gpu_begin)(id, SEL, NSError **);
static id compact_gpu_observe_begin(id owner, SEL selector, NSError **error)
{
    compact_gpu_begins++;
    return compact_gpu_begin(owner, selector, error);
}
static id (*compact_gpu_program)(id, SEL, const uint32_t *, NSUInteger,
                                 const NV2AMetalProgramUniforms *,
                                 id<MTLBuffer>, NSUInteger, NV2AMetalCommands *,
                                 NSError **);
static id compact_gpu_observe_program(
    id owner, SEL selector, const uint32_t *tokens, NSUInteger length,
    const NV2AMetalProgramUniforms *uniforms, id<MTLBuffer> attributes,
    NSUInteger count, NV2AMetalCommands *commands, NSError **error)
{
    compact_gpu_xf++;
    return compact_gpu_program(owner, selector, tokens, length, uniforms,
                               attributes, count, commands, error);
}
static NSData *compact_gpu_map(const uint32_t *map, NSUInteger count)
{
    return [NSData dataWithBytes:map length:count * sizeof(*map)];
}
static NV2AMetalPendingUpdate *
compact_gpu_append(NV2AMetalPendingJournal *journal, unsigned stream,
                   NV2AMetalPendingSpan *span, NSUInteger counts[3])
{
    NSError *error = nil;
    counts[stream] += span.count;
    NSMutableArray *inputs = [NSMutableArray new],
                   *suffixes = [NSMutableArray new];
    for (unsigned i = 0; i < 3 && counts[i]; i++) {
        [inputs addObject:[NV2AMetalPendingInput arraysFrom:100 * i
                                                      count:counts[i]]];
        [suffixes addObject:i == stream ? span : (id)NSNull.null];
    }
    NV2AMetalPendingPlan *plan = [journal planInputs:inputs
                                 preservingLastArray:NO
                                               error:&error];
    require(plan != nil, error);
    NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                 suffixes:suffixes
                                                    error:&error];
    require(update && [journal commitUpdate:update error:&error], error);
    return update;
}
static NV2AMetalPendingUpdate *
compact_gpu_update(NV2AMetalPendingJournal *journal)
{
    NSError *error = nil;
    NSMutableArray *suffixes = [NSMutableArray new];
    for (NSUInteger i = 0; i < journal.streamCount; i++)
        [suffixes addObject:NSNull.null];
    NV2AMetalPendingPlan *plan = [journal planInputs:journal.retainedInputs
                                 preservingLastArray:NO
                                               error:&error];
    require(plan != nil, error);
    NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                 suffixes:suffixes
                                                    error:&error];
    require(update != nil, error);
    return update;
}
static void compact_gpu_compare(NV2AMetalPendingJournal *journal,
                                NV2AMetalCommands *commands,
                                NV2AMetalPendingArchive *archive)
{
    NSError *error = nil;
    NSArray<NSData *> *expected = archive.vertices;
    NV2AMetalPendingNative *native = [[NV2AMetalPendingNative alloc]
        initWithUpdate:compact_gpu_update(journal)
                device:commands.device
                 limit:256
                 error:&error];
    require(native != nil, error);
    require([commands beginWithError:&error] != nil, error);
    NSArray<NV2AMetalVertexSlice *> *slices =
        [native encodeSlicesWithCommands:commands error:&error];
    NSArray<id<MTLBuffer>> *linear = [native encodeWithCommands:commands
                                                          error:&error];
    require(slices && linear && slices.count == expected.count, error);
    for (NSUInteger i = 0; i < slices.count; i++) {
        assert(slices[i].vertexCount == archive.inputs[i].count);
        assert((slices[i].indexedVertices != nil) ==
               (archive.remaps[i].length != 0));
        if (slices[i].indexedVertices)
            assert(slices[i].indexedVertices.physicalVertexCount ==
                   archive.physicalVertices[i].length /
                       sizeof(NV2AMetalVertex));
    }
    /* A linear source may be reused as a private GPU buffer. Read back every
     * output explicitly instead of assuming CPU visibility of that source. */
    NSMutableArray<id<MTLBuffer>> *readbacks = [NSMutableArray new];
    for (NSUInteger i = 0; i < linear.count; i++) {
        assert(linear[i].length == expected[i].length);
        id<MTLBuffer> readback =
            [commands.device newBufferWithLength:expected[i].length
                                         options:MTLResourceStorageModeShared];
        require(readback && [commands addResource:linear[i] error:&error] &&
                    [commands addResource:readback error:&error],
                error);
        [readbacks addObject:readback];
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    for (NSUInteger i = 0; i < linear.count; i++)
        [encoder copyFromBuffer:linear[i]
                   sourceOffset:0
                       toBuffer:readbacks[i]
              destinationOffset:0
                           size:expected[i].length];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (NSUInteger i = 0; i < readbacks.count; i++)
        assert(!memcmp(readbacks[i].contents, expected[i].bytes,
                       expected[i].length));
}
static void compact_gpu_cycles(NV2AMetalPendingArchive *archive,
                               NV2AMetalCommands *commands, unsigned cycles)
{
    NSError *error = nil;
    NSData *wire = archive.data;
    assert(wire.length >= 20 && ((const uint8_t *)wire.bytes)[7] == 2);
    for (unsigned cycle = 0; cycle < cycles; cycle++) {
        NV2AMetalPendingArchive *decoded =
            [[NV2AMetalPendingArchive alloc] initWithData:wire
                                                    limit:256
                                                    error:&error];
        require(decoded != nil, error);
        if (!cycle && decoded.inputs.count > 1) {
            Method upload = class_getInstanceMethod(
                NV2AMetalCommands.class,
                @selector(uploadBytes:length:offset:error:));
            assert(upload);
            restore_original_upload = (void *)method_setImplementation(
                upload, (IMP)restore_observe_upload);
            restore_sources =
                [NSHashTable hashTableWithOptions:
                                 NSPointerFunctionsStrongMemory |
                                 NSPointerFunctionsObjectPointerPersonality];
            restore_upload_calls = 0;
            restore_fail_at = 2;
            NV2AMetalSubmission *before = commands.lastSubmitted;
            NV2AMetalPendingJournal *failed =
                nv2a_metal_pending_restore(decoded, commands, 256, &error);
            method_setImplementation(upload, (IMP)restore_original_upload);
            assert(!failed &&
                   [error.domain isEqualToString:@"test.pending-restore"] &&
                   restore_upload_calls == 2 && !commands.commandBuffer &&
                   commands.lastSubmitted == before &&
                   [decoded.data isEqualToData:wire]);
            restore_sources = nil;
            restore_fail_at = 0;
            error = nil;
        }
        NV2AMetalPendingJournal *restored =
            nv2a_metal_pending_restore(decoded, commands, 256, &error);
        require(restored != nil, error);
        for (NSUInteger i = 0; i < restored.streamCount; i++) {
            assert(restored.retainedStreams[i].count == 1);
            NV2AMetalPendingSpan *span = restored.retainedStreams[i][0];
            assert(!span.first && span.count == decoded.inputs[i].count);
            id<MTLBuffer> buffer;
            if (decoded.remaps[i].length) {
                assert([span.resource
                    isKindOfClass:NV2AMetalIndexedVertices.class]);
                NV2AMetalIndexedVertices *owner = span.resource;
                assert(owner.physicalVertexCount ==
                           decoded.physicalVertices[i].length /
                               sizeof(NV2AMetalVertex) &&
                       owner.vertexCount == span.count &&
                       [owner.remap isEqualToData:decoded.remaps[i]]);
                buffer = owner.vertices;
            } else
                buffer = span.resource;
            assert(buffer.storageMode == MTLStorageModePrivate &&
                   buffer.length == decoded.physicalVertices[i].length);
        }
        compact_gpu_compare(restored, commands, decoded);
        NV2AMetalPendingArchive *saved =
            nv2a_metal_pending_capture(restored, commands, &error);
        require(saved != nil, error);
        assert(
            [saved.data isEqualToData:wire] &&
            [saved.vertices isEqualToArray:archive.vertices] &&
            [saved.physicalVertices isEqualToArray:archive.physicalVertices] &&
            [saved.remaps isEqualToArray:archive.remaps]);
    }
}
static void compact_gpu_discarded(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NSData *zero = [NSMutableData dataWithLength:2 * sizeof(NV2AMetalVertex)];
    const uint32_t zeroMap[] = { 0, 1, 0, 1, 0, 1 };
    NV2AMetalPendingArchive *indexedZero = [[NV2AMetalPendingArchive alloc]
          initWithInputs:@[ input(2, 6) ]
        physicalVertices:@[ zero ]
                  remaps:@[ compact_gpu_map(zeroMap, 6) ]
                   limit:256
                   error:&error];
    require(indexedZero != nil, error);
    NV2AMetalPendingJournal *rawRestored =
        nv2a_metal_pending_restore_raw(indexedZero, commands, 256, &error);
    require(rawRestored != nil, error);
    assert([((NV2AMetalPendingSpan *)rawRestored.retainedStreams[0][0]).resource
        isKindOfClass:NV2AMetalIndexedVertices.class]);
    NV2AMetalPendingArchive *saved =
        nv2a_metal_pending_capture(rawRestored, commands, &error);
    require(saved != nil, error);
    assert([saved.data isEqualToData:indexedZero.data]);
    for (unsigned private = 0; private < 2; private ++) {
        NSMutableData *physical = [raw(5, 1) mutableCopy];
        memset(physical.mutableBytes, 0, sizeof(NV2AMetalVertex));
        id<MTLBuffer> buffer = indexed_source(commands, physical, private);
        const uint32_t map[] = { 2, 0, 2, 1 };
        NV2AMetalIndexedVertices *owner = indexed_owner(buffer, 5, map, 4);
        NV2AMetalPendingJournal *journal =
            [[NV2AMetalPendingJournal alloc] initWithLimit:256];
        NSUInteger counts[3] = { 0 };
        compact_gpu_append(journal, 0,
                           [NV2AMetalPendingSpan resource:owner
                                                    first:0
                                                    count:4],
                           counts);
        NV2AMetalDiscardedVertices *discard =
            [[NV2AMetalDiscardedVertices alloc] initWithCount:3];
        compact_gpu_append(journal, 0,
                           [NV2AMetalPendingSpan resource:discard
                                                    first:0
                                                    count:3],
                           counts);
        NV2AMetalPendingUpdate *update = compact_gpu_append(
            journal, 0, [NV2AMetalPendingSpan resource:buffer first:2 count:2],
            counts);
        error = nil;
        assert(![[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                        device:commands.device
                                                         limit:256
                                                         error:&error] &&
               error);
        error = nil;
        compact_gpu_begins = 0;
        NV2AMetalPendingArchive *archive =
            nv2a_metal_pending_capture(journal, commands, &error);
        require(archive != nil, error);
        if (!private)
            assert(!compact_gpu_begins);
        NSMutableData *logical =
            [indexed_expected(physical, map, 0, 4) mutableCopy];
        [logical appendData:[NSMutableData
                                dataWithLength:3 * sizeof(NV2AMetalVertex)]];
        [logical
            appendData:[physical
                           subdataWithRange:NSMakeRange(
                                                2 * sizeof(NV2AMetalVertex),
                                                2 * sizeof(NV2AMetalVertex))]];
        NSMutableData *expectedPhysical =
            [physical
                subdataWithRange:NSMakeRange(0, 4 * sizeof(NV2AMetalVertex))]
                .mutableCopy;
        [expectedPhysical
            appendData:[NSMutableData dataWithLength:sizeof(NV2AMetalVertex)]];
        const uint32_t expectedMap[] = { 2, 0, 2, 1, 4, 4, 4, 2, 3 };
        assert(
            [archive.vertices[0] isEqualToData:logical] &&
            [archive.physicalVertices[0] isEqualToData:expectedPhysical] &&
            [archive.remaps[0] isEqualToData:compact_gpu_map(expectedMap, 9)]);
        /* The shared zero-valued buffer record and synthetic zero remain
         * distinct physical identities; only the three discarded zeros merge.
         */
        compact_gpu_cycles(archive, commands, 2);
    }
}
static void indexed_archive_tests(NV2AMetalCommands *commands)
{
    Method begin = class_getInstanceMethod(NV2AMetalCommands.class,
                                           @selector(beginWithError:));
    Method program = class_getInstanceMethod(
        NV2AMetalVertexProgram.class,
        @selector(
            encodeTokens:length:uniforms:attributes:count:commands:error:));
    assert(begin && program);
    compact_gpu_begin =
        (void *)method_setImplementation(begin, (IMP)compact_gpu_observe_begin);
    compact_gpu_program = (void *)method_setImplementation(
        program, (IMP)compact_gpu_observe_program);
    compact_gpu_xf = 0;
    unsigned cases = 0;
    @try {
        for (unsigned privateA = 0; privateA < 2; privateA++) {
            for (unsigned privateB = 0; privateB < 2; privateB++) {
                NSError *error = nil;
                NSData *a = raw(10, 3), *b = raw(9, 7);
                id<MTLBuffer> bufferA = indexed_source(commands, a, privateA);
                id<MTLBuffer> bufferB = indexed_source(commands, b, privateB);
                const uint32_t mapA[] = { 9, 1, 7, 4, 2, 7, 8, 4, 1, 9, 2, 4 };
                const uint32_t mapB[] = { 6, 2, 6, 2, 6, 2 },
                               mapC[] = { 7, 4, 7, 4, 7, 4 };
                NV2AMetalIndexedVertices *ownerA =
                    indexed_owner(bufferA, 10, mapA, 12);
                NV2AMetalIndexedVertices *ownerB =
                    indexed_owner(bufferB, 9, mapB, 6);
                NV2AMetalIndexedVertices *ownerC =
                    indexed_owner(bufferA, 10, mapC, 6);
                NV2AMetalPendingJournal *journal =
                    [[NV2AMetalPendingJournal alloc] initWithLimit:256];
                NSUInteger counts[3] = { 0 };
                compact_gpu_append(journal, 0,
                                   [NV2AMetalPendingSpan resource:ownerA
                                                            first:2
                                                            count:6],
                                   counts);
                compact_gpu_append(journal, 0,
                                   [NV2AMetalPendingSpan resource:bufferA
                                                            first:2
                                                            count:3],
                                   counts);
                compact_gpu_append(journal, 1,
                                   [NV2AMetalPendingSpan resource:bufferB
                                                            first:4
                                                            count:3],
                                   counts);
                compact_gpu_append(journal, 2,
                                   [NV2AMetalPendingSpan resource:ownerB
                                                            first:0
                                                            count:6],
                                   counts);
                compact_gpu_append(journal, 2,
                                   [NV2AMetalPendingSpan resource:ownerC
                                                            first:0
                                                            count:6],
                                   counts);
                NSMutableData *first =
                    [indexed_expected(a, mapA, 2, 6) mutableCopy];
                [first appendData:[a subdataWithRange:
                                          NSMakeRange(
                                              2 * sizeof(NV2AMetalVertex),
                                              3 * sizeof(NV2AMetalVertex))]];
                NSMutableData *last =
                    [indexed_expected(b, mapB, 0, 6) mutableCopy];
                [last appendData:indexed_expected(a, mapC, 0, 6)];
                NSArray *logical = @[
                    first,
                    [b subdataWithRange:NSMakeRange(
                                            4 * sizeof(NV2AMetalVertex),
                                            3 * sizeof(NV2AMetalVertex))],
                    last
                ];
                const uint32_t orderA[] = { 2, 3, 4, 7, 8 },
                               orderB[] = { 2, 6 }, orderC[] = { 4, 7 };
                NSMutableData *lastPhysical =
                    [indexed_expected(b, orderB, 0, 2) mutableCopy];
                [lastPhysical appendData:indexed_expected(a, orderC, 0, 2)];
                NSArray *physical = @[
                    indexed_expected(a, orderA, 0, 5), logical[1], lastPhysical
                ];
                const uint32_t firstMap[] = { 3, 2, 0, 3, 4, 2, 0, 1, 2 };
                const uint32_t lastMap[] = {
                    1, 0, 1, 0, 1, 0, 3, 2, 3, 2, 3, 2
                };
                NSArray *remaps = @[
                    compact_gpu_map(firstMap, 9), [NSData data],
                    compact_gpu_map(lastMap, 12)
                ];
                NV2AMetalPendingPlan *hidden =
                    [journal planInputs:[journal.retainedInputs
                                            subarrayWithRange:NSMakeRange(0, 2)]
                        preservingLastArray:YES
                                      error:&error];
                require(hidden != nil, error);
                NV2AMetalPendingUpdate *update =
                    [journal preparePlan:hidden
                                suffixes:@[ NSNull.null, NSNull.null ]
                                   error:&error];
                require(update && [journal commitUpdate:update error:&error],
                        error);
                assert(update.streams.count == 2 && journal.streamCount == 3);
                compact_gpu_begins = 0;
                NV2AMetalPendingArchive *archive =
                    nv2a_metal_pending_capture(journal, commands, &error);
                require(archive != nil, error);
                if (!privateA && !privateB)
                    assert(!compact_gpu_begins);
                assert(archive.inputs.count == 3 &&
                       [archive.vertices isEqualToArray:logical] &&
                       [archive.physicalVertices isEqualToArray:physical] &&
                       [archive.remaps isEqualToArray:remaps]);
                NV2AMetalPendingArchive *explicitArchive =
                    [[NV2AMetalPendingArchive alloc]
                          initWithInputs:archive.inputs
                        physicalVertices:physical
                                  remaps:remaps
                                   limit:256
                                   error:&error];
                require(explicitArchive != nil, error);
                assert([explicitArchive.data isEqualToData:archive.data]);
                compact_gpu_cycles(archive, commands, 3);
                cases++;
            }
        }
        compact_gpu_discarded(commands);
    } @finally {
        method_setImplementation(begin, (IMP)compact_gpu_begin);
        method_setImplementation(program, (IMP)compact_gpu_program);
    }
    assert(cases == 4 && !compact_gpu_xf);
    puts("Native compact archives: 4 shared/private combinations, 24 "
         "logical/12 physical records, "
         "hidden last stream, buffer offsets, mixed linear/indexed and raw NaN "
         "bits; "
         "16 GPU restore/capture cycles with exact slices/expansion; shared "
         "capture "
         "opens no recording, indexed raw zeros keep wire/owner, discarded "
         "drawing "
         "guard and single synthetic zero preserved; no XF replay PASS");
}
#endif
