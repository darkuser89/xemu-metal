/* Exact, non-drawable zero transport for discarded raster output.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DISCARDED_TRANSPORT_H
#define TEST_METAL_DISCARDED_TRANSPORT_H
#import "hw/xbox/nv2a/pgraph/metal/pending-native.h"
static void discarded_transport_tests(NV2AMetalCommands *commands)
{
    unsigned cases = 0;
    for (unsigned kind = 1; kind <= 4; kind++)
        for (unsigned mask = 0; mask < 8; mask++) {
            NSError *error = nil;
            NSData *source = raw(8, kind);
            id<MTLBuffer> buffer = [commands.device
                newBufferWithBytes:source.bytes
                            length:source.length
                           options:MTLResourceStorageModeShared];
            NV2AMetalDiscardedVertices *zero =
                [[NV2AMetalDiscardedVertices alloc] initWithCount:8];
            assert(buffer && zero);
            NV2AMetalPendingJournal *journal =
                [[NV2AMetalPendingJournal alloc] initWithLimit:32];
            NSMutableData *expected = [NSMutableData new];
            const unsigned counts[] = { 2, 3, 1 }, starts[] = { 1, 2, 0 };
            unsigned total = 0;
            for (unsigned span = 0; span < 3; span++) {
                total += counts[span];
                NV2AMetalPendingPlan *plan =
                    [journal planInputs:@[ input(kind, total) ]
                        preservingLastArray:NO
                                      error:&error];
                require(plan != nil, error);
                id resource = mask & (1u << span) ? (id)zero : buffer;
                NV2AMetalPendingSpan *suffix =
                    [NV2AMetalPendingSpan resource:resource
                                             first:starts[span]
                                             count:counts[span]];
                NV2AMetalPendingUpdate *update =
                    [journal preparePlan:plan
                                suffixes:@[ suffix ]
                                   error:&error];
                require(update != nil, error);
                require([journal commitUpdate:update error:&error], error);
                NSData *bytes =
                    mask & (1u << span) ?
                        [NSMutableData dataWithLength:counts[span] *
                                                      sizeof(NV2AMetalVertex)] :
                        [source
                            subdataWithRange:NSMakeRange(
                                                 starts[span] *
                                                     sizeof(NV2AMetalVertex),
                                                 counts[span] *
                                                     sizeof(NV2AMetalVertex))];
                [expected appendData:bytes];
            }
            NV2AMetalPendingArchive *reference =
                [[NV2AMetalPendingArchive alloc]
                    initWithInputs:@[ input(kind, total) ]
                          vertices:@[ expected ]
                             limit:32
                             error:&error];
            NV2AMetalPendingArchive *captured =
                nv2a_metal_pending_capture(journal, commands, &error);
            require(reference && captured, error);
            assert([captured.data isEqualToData:reference.data] &&
                   !memcmp(source.bytes, buffer.contents, source.length));
            for (unsigned cycle = 0; cycle < 2; cycle++) {
                NV2AMetalPendingJournal *restored =
                    nv2a_metal_pending_restore_raw(captured, commands, 32,
                                                   &error);
                require(restored != nil, error);
                id resource =
                    ((NV2AMetalPendingSpan *)restored.retainedStreams[0][0])
                        .resource;
                assert(
                    mask == 7 ?
                        [resource
                            isMemberOfClass:NV2AMetalDiscardedVertices.class] :
                        [resource conformsToProtocol:@protocol(MTLBuffer)]);
                captured =
                    nv2a_metal_pending_capture(restored, commands, &error);
                require(captured != nil, error);
                assert([captured.data isEqualToData:reference.data]);
            }
            NV2AMetalPendingJournal *regular =
                nv2a_metal_pending_restore(captured, commands, 32, &error);
            require(regular != nil, error);
            id regularResource =
                ((NV2AMetalPendingSpan *)regular.retainedStreams[0][0])
                    .resource;
            assert([regularResource conformsToProtocol:@protocol(MTLBuffer)]);
            NV2AMetalPendingPlan *plan =
                [journal planInputs:@[ input(kind, total) ]
                    preservingLastArray:NO
                                  error:&error];
            NV2AMetalPendingUpdate *update =
                [journal preparePlan:plan
                            suffixes:@[ NSNull.null ]
                               error:&error];
            require(update != nil, error);
            NV2AMetalPendingNative *native =
                [[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                        device:commands.device
                                                         limit:32
                                                         error:&error];
            assert(mask ? !native && error : native != nil);
            assert(!commands.commandBuffer);
            cases++;
        }
    NSError *error = nil;
    assert(![[NV2AMetalDiscardedVertices alloc] initWithCount:0] &&
           ![[NV2AMetalDiscardedVertices alloc] initWithCount:NSUIntegerMax]);
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:8
                                                error:&error];
    require(stream != nil, error);
    require([stream appendDiscardedVertices:0 error:&error], error);
    require([stream appendDiscardedVertices:3 error:&error], error);
    require([stream appendDiscardedVertices:2 error:&error], error);
    assert(stream.vertexCount == 5 && ![stream appendDiscardedVertices:4
                                                                 error:&error]);
    require([commands beginWithError:&error] != nil, error);
    assert(![stream encodeForDrawingWithCommands:commands error:&error] &&
           error);
    assert(![stream encodeSliceForDrawingWithCommands:commands error:&error] &&
           error);
    id<MTLBuffer> bytes = [stream encodeWithCommands:commands error:&error];
    require(bytes != nil, error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    NSData *zeroBytes =
        [NSMutableData dataWithLength:5 * sizeof(NV2AMetalVertex)];
    assert(bytes.length == zeroBytes.length &&
           !memcmp(bytes.contents, zeroBytes.bytes, bytes.length));
    NV2AMetalPendingJournal *bad =
        [[NV2AMetalPendingJournal alloc] initWithLimit:8];
    NV2AMetalPendingPlan *plan = [bad planInputs:@[ input(1, 2) ]
                             preservingLastArray:NO
                                           error:&error];
    NV2AMetalDiscardedVertices *shortZero =
        [[NV2AMetalDiscardedVertices alloc] initWithCount:1];
    NV2AMetalPendingUpdate *update =
        [bad preparePlan:plan
                suffixes:@[ [NV2AMetalPendingSpan resource:shortZero
                                                     first:0
                                                     count:2] ]
                   error:&error];
    require(update != nil, error);
    require([bad commitUpdate:update error:&error], error);
    assert(!nv2a_metal_pending_capture(bad, commands, &error) && error &&
           !commands.commandBuffer);
    assert(cases == 32);
    puts("Discarded vertex transport:32 exact mixed/zero/GPU spans,four input "
         "kinds;"
         "two raw restore cycles/canonical wire,nonzero legacy bytes and "
         "regular GPU restore preserved;"
         "drawing/size/bounds rejects and exact Metal fill PASS");
}
#endif
