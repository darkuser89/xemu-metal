/* Immutable indexed transformed streams and linear archive compatibility.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEXED_STREAM_H
#define TEST_METAL_INDEXED_STREAM_H
static NSData *indexed_expected(NSData *physical, const uint32_t *map,
                                NSUInteger first, NSUInteger count)
{
    NSMutableData *result = [NSMutableData new];
    for (NSUInteger i = 0; i < count; i++)
        [result appendBytes:(const uint8_t *)physical.bytes +
                            map[first + i] * sizeof(NV2AMetalVertex)
                     length:sizeof(NV2AMetalVertex)];
    return result;
}
static id<MTLBuffer> indexed_source(NV2AMetalCommands *commands, NSData *bytes,
                                    BOOL private)
{
    NSError *error = nil;
    id<MTLBuffer> shared =
        [commands.device newBufferWithBytes:bytes.bytes
                                     length:bytes.length
                                    options:MTLResourceStorageModeShared];
    assert(shared);
    if (!private)
        return shared;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:bytes.length
                                     options:MTLResourceStorageModePrivate];
    require([commands beginWithError:&error] != nil, error);
    require(result && [commands addResource:shared error:&error] &&
                [commands addResource:result error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder copyFromBuffer:shared
               sourceOffset:0
                   toBuffer:result
          destinationOffset:0
                       size:bytes.length];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    return result;
}
static NV2AMetalIndexedVertices *indexed_owner(id<MTLBuffer> buffer,
                                               NSUInteger physical,
                                               const uint32_t *map,
                                               NSUInteger count)
{
    NSError *error = nil;
    NV2AMetalIndexedVertices *owner = [[NV2AMetalIndexedVertices alloc]
        initWithVertices:buffer
           physicalCount:physical
                   remap:[NSData dataWithBytes:map length:count * sizeof(*map)]
                   error:&error];
    require(owner != nil, error);
    return owner;
}
static void indexed_stream_tests(NV2AMetalCommands *commands)
{
    const uint32_t map[] = { 7, 2, 7, 4, 2, 6, 7, 4, 1, 2, 7 };
    const uint32_t otherMap[] = { 2, 7, 0, 7 };
    const uint32_t secondMap[] = { 3, 1, 3, 1 };
    for (unsigned private = 0; private < 2; private ++) {
        NSError *error = nil;
        NSData *rawFirst = raw(10, 3), *rawSecond = raw(8, 6);
        id<MTLBuffer> source = indexed_source(commands, rawFirst, private);
        id<MTLBuffer> second = indexed_source(commands, rawSecond, private);
        NSMutableData *mutable = [NSMutableData dataWithBytes:map
                                                       length:sizeof(map)];
        NV2AMetalIndexedVertices *owner =
            [[NV2AMetalIndexedVertices alloc] initWithVertices:source
                                                 physicalCount:8
                                                         remap:mutable
                                                         error:&error];
        require(owner != nil, error);
        memset(mutable.mutableBytes, 0xff, mutable.length);
        assert(owner.vertices == source && owner.physicalVertexCount == 8 &&
               owner.vertexCount == 11 &&
               owner.indices.storageMode == MTLStorageModeShared &&
               !memcmp(owner.remap.bytes, map, sizeof(map)) &&
               !memcmp(owner.indices.contents, map, sizeof(map)));
        NV2AMetalVertexStream *stream =
            [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                    limit:32
                                                    error:&error];
        require([stream appendIndexedVertices:owner
                                        first:2
                                        count:7
                                        error:&error],
                error);
        NSData *expected = indexed_expected(rawFirst, map, 2, 7);
        NSData *host = stream.completedHostVertexData;
        assert(private ? host == nil : [host isEqualToData:expected]);
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalVertexSlice *slice =
            [stream encodeSliceForDrawingWithCommands:commands error:&error];
        require(slice != nil, error);
        assert(slice.buffer == source && slice.indexedVertices == owner &&
               slice.firstVertex == 2 && slice.vertexCount == 7);
        id<MTLBuffer> linear = [stream encodeWithCommands:commands
                                                    error:&error];
        id<MTLBuffer> drawing = [stream encodeForDrawingWithCommands:commands
                                                               error:&error];
        require(linear && drawing, error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        assert(linear.length == expected.length &&
               drawing.length == expected.length &&
               !memcmp(linear.contents, expected.bytes, expected.length) &&
               !memcmp(drawing.contents, expected.bytes, expected.length));

        NV2AMetalIndexedVertices *other = indexed_owner(source, 8, otherMap, 4);
        NV2AMetalIndexedVertices *secondOwner =
            indexed_owner(second, 4, secondMap, 4);
        NSArray<NV2AMetalPendingSpan *> *spans = @[
            [NV2AMetalPendingSpan resource:owner first:2 count:5],
            [NV2AMetalPendingSpan resource:other first:0 count:4],
            [NV2AMetalPendingSpan resource:source first:4 count:2],
            [NV2AMetalPendingSpan resource:secondOwner first:0 count:4]
        ];
        NSMutableData *joinedExpected =
            [indexed_expected(rawFirst, map, 2, 5) mutableCopy];
        [joinedExpected appendData:indexed_expected(rawFirst, otherMap, 0, 4)];
        [joinedExpected appendBytes:(const uint8_t *)rawFirst.bytes +
                                    4 * sizeof(NV2AMetalVertex)
                             length:2 * sizeof(NV2AMetalVertex)];
        [joinedExpected
            appendData:indexed_expected(rawSecond, secondMap, 0, 4)];
        NV2AMetalPendingJournal *journal =
            [[NV2AMetalPendingJournal alloc] initWithLimit:32];
        NV2AMetalPendingUpdate *update = nil;
        NSUInteger total = 0;
        for (NV2AMetalPendingSpan *span in spans) {
            total += span.count;
            NV2AMetalPendingPlan *plan =
                [journal planInputs:@[ input(1, total) ]
                    preservingLastArray:NO
                                  error:&error];
            require(plan != nil, error);
            update = [journal preparePlan:plan suffixes:@[ span ] error:&error];
            require(update != nil, error);
            require([journal commitUpdate:update error:&error], error);
        }
        NV2AMetalPendingNative *native =
            [[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                    device:commands.device
                                                     limit:32
                                                     error:&error];
        require(native != nil, error);
        assert(native.counts.count == 1 &&
               native.counts[0].unsignedIntegerValue == 15);
        require([commands beginWithError:&error] != nil, error);
        NSArray<NV2AMetalVertexSlice *> *slices =
            [native encodeSlicesWithCommands:commands error:&error];
        require(slices != nil, error);
        slice = slices[0];
        assert(slice.indexedVertices && slice.vertexCount == 15 &&
               slice.firstVertex == 0 &&
               slice.indexedVertices.physicalVertexCount == 8 &&
               slice.buffer.length == 8 * sizeof(NV2AMetalVertex));
        NSArray<id<MTLBuffer>> *linears = [native encodeWithCommands:commands
                                                               error:&error];
        require(linears != nil, error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        const uint32_t *compactMap = slice.indexedVertices.remap.bytes;
        for (NSUInteger i = 0; i < 15; i++)
            assert(!memcmp((const uint8_t *)slice.buffer.contents +
                               compactMap[i] * sizeof(NV2AMetalVertex),
                           (const uint8_t *)joinedExpected.bytes +
                               i * sizeof(NV2AMetalVertex),
                           sizeof(NV2AMetalVertex)));
        assert(linears[0].length == joinedExpected.length &&
               !memcmp(linears[0].contents, joinedExpected.bytes,
                       joinedExpected.length));
        NV2AMetalPendingArchive *capture =
            nv2a_metal_pending_capture(journal, commands, &error);
        require(capture != nil, error);
        assert([capture.vertices[0] isEqualToData:joinedExpected]);
        NV2AMetalPendingJournal *restored =
            nv2a_metal_pending_restore(capture, commands, 32, &error);
        require(restored != nil, error);
        NV2AMetalPendingArchive *recaptured =
            nv2a_metal_pending_capture(restored, commands, &error);
        require(recaptured != nil, error);
        assert([recaptured.data isEqualToData:capture.data]);
    }

    NSError *error = nil;
    NSData *bytes = raw(8, 0);
    id<MTLBuffer> buffer = indexed_source(commands, bytes, NO);
    for (unsigned bad = 0; bad < 6; bad++) {
        uint32_t invalid[] = { 0, 8 };
        NSData *remap =
            bad == 0 ? [NSData data] :
            bad == 1 ? [NSData dataWithBytes:map length:3] :
            bad == 2 ? [NSData dataWithBytes:invalid length:sizeof(invalid)] :
                       [NSData dataWithBytes:map length:sizeof(map)];
        NSUInteger physical = bad == 3 ? 0 :
                              bad == 4 ? 9 :
                              bad == 5 ? NSUIntegerMax :
                                         8;
        error = nil;
        assert(![[NV2AMetalIndexedVertices alloc] initWithVertices:buffer
                                                     physicalCount:physical
                                                             remap:remap
                                                             error:&error] &&
               error);
        assert(!commands.commandBuffer);
    }
    NV2AMetalIndexedVertices *valid = indexed_owner(buffer, 8, map, 11);
    NV2AMetalVertexStream *bounded =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:7
                                                error:&error];
    require([bounded appendIndexedVertices:valid first:11 count:0 error:&error],
            error);
    assert(bounded.vertexCount == 0);
    for (unsigned bad = 0; bad < 3; bad++) {
        error = nil;
        assert(![bounded appendIndexedVertices:valid
                                         first:bad == 0 ? 12 : 0
                                         count:bad == 1 ? NSUIntegerMax :
                                               bad == 2 ? 8 :
                                                          0
                                         error:&error] &&
               error);
        assert(bounded.vertexCount == 0 && !commands.commandBuffer);
    }
    __weak NV2AMetalIndexedVertices *weakOwner;
    @autoreleasepool {
        NV2AMetalIndexedVertices *temporary = indexed_owner(buffer, 8, map, 11);
        weakOwner = temporary;
        NV2AMetalVertexStream *temporaryStream =
            [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                    limit:32
                                                    error:&error];
        require([temporaryStream appendIndexedVertices:temporary
                                                 first:1
                                                 count:2
                                                 error:&error],
                error);
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalVertexSlice *slice =
            [temporaryStream encodeSliceForDrawingWithCommands:commands
                                                         error:&error];
        require(slice != nil, error);
        temporary = nil;
        temporaryStream = nil;
        slice = nil;
        assert(weakOwner);
        [commands cancel];
    }
    assert(!weakOwner);
    puts("Indexed vertex streams: immutable validated remaps, logical slices, "
         "shared/private GPU gather, compact mixed-source joins, compact "
         "archive roundtrip, bounds and cancellation lifetime PASS");
}
#endif
