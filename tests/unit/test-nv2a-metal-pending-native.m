/* Offscreen native stream assembly. Synthetic vertex bytes, no transform claim.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/pending-native.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned assemblies, compared, rejects;
static NV2AMetalVertex sourceVertices[256];
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Pending native: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static id<MTLBuffer> readback(id<MTLBuffer> source, NSUInteger count,
                             NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NSUInteger bytes = count * sizeof(NV2AMetalVertex);
    assert(source.length >= bytes);
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:bytes
                                     options:MTLResourceStorageModeShared];
    assert(result);
    require([commands addResource:source error:&error], error);
    require([commands addResource:result error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:source sourceOffset:0 toBuffer:result
         destinationOffset:0 size:bytes];
    [encoder endEncoding];
    return result;
}
static void check_reuse(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    for (unsigned test = 0; test < 7; test++) {
        @autoreleasepool {
            id<MTLBuffer> upload = [commands.device
                newBufferWithBytes:sourceVertices length:sizeof(sourceVertices)
                           options:MTLResourceStorageModeShared];
            id<MTLBuffer> gpu = [commands.device
                newBufferWithLength:sizeof(sourceVertices)
                            options:MTLResourceStorageModePrivate];
            assert(upload && gpu);
            require([commands beginWithError:&error] != nil, error);
            require([commands addResource:upload error:&error], error);
            require([commands addResource:gpu error:&error], error);
            id<MTL4ComputeCommandEncoder> encoder =
                [commands.commandBuffer computeCommandEncoder];
            assert(encoder);
            [encoder copyFromBuffer:upload sourceOffset:0 toBuffer:gpu
                 destinationOffset:0 size:sizeof(sourceVertices)];
            [encoder endEncoding];

            NV2AMetalVertexStream *stream = [[NV2AMetalVertexStream alloc]
                initWithDevice:commands.device limit:256 error:&error];
            require(stream != nil, error);
            NSUInteger first = test == 4 || test == 5 ? 4 : 0;
            NSUInteger count = test == 0 ? 256 : 4;
            require([stream appendVertices:gpu first:first count:count
                                     error:&error], error);
            NSUInteger second = test == 3 ? 8 : test == 4 ? 0 : 4;
            if (test == 2 || test == 3 || test == 4 || test == 6)
                require([stream appendVertices:test == 6 ? upload : gpu
                                         first:second count:4 error:&error],
                        error);
            NSUInteger total = stream.vertexCount;
            id<MTLBuffer> result =
                [stream encodeForDrawingWithCommands:commands error:&error];
            require(result != nil, error);
            assert((result == gpu) == (test <= 2));
            id<MTLBuffer> snapshot = [stream encodeWithCommands:commands
                                                         error:&error];
            require(snapshot != nil, error);
            assert(snapshot != gpu && snapshot != result);
            assert(snapshot.storageMode == MTLStorageModeShared &&
                   snapshot.length == total * sizeof(NV2AMetalVertex));
            id<MTLBuffer> bytes = readback(result, total, commands);
            /* Release every caller owner before submission; the command slot
             * must retain both aliased input and copied output resources. */
            upload = nil;
            gpu = nil;
            stream = nil;
            result = nil;
            finish(commands);
            assert(!memcmp(snapshot.contents, bytes.contents, snapshot.length));
            assert(!memcmp(bytes.contents, sourceVertices + first,
                           count * sizeof(NV2AMetalVertex)));
            if (total > count)
                assert(!memcmp((char *)bytes.contents +
                                   count * sizeof(NV2AMetalVertex),
                               sourceVertices + second,
                               4 * sizeof(NV2AMetalVertex)));
        }
    }
    puts("Native stream reuse: private GPU producer in same recording; full, "
         "prefix, adjacent spans reuse source; gaps, reversed spans, nonzero "
         "offset and different buffers preserve copied order; lifetime PASS");
}
static void check_uploads(NV2AMetalCommands *commands)
{
    const NSUInteger sizes[] = { 1, 13, 255, 256, 257, 1336, 65536, 65537 };
    NSMutableArray<id<MTLBuffer>> *results = [NSMutableArray new];
    NSMutableArray<NSData *> *expected = [NSMutableArray new];
    NSError *error = nil;
    for (unsigned round = 0; round < 6; round++) {
        require([commands beginWithError:&error] != nil, error);
        NSMutableArray<id<MTLBuffer>> *sources = [NSMutableArray new];
        NSMutableData *reference = [NSMutableData new];
        NSUInteger offsets[136];
        unsigned char bytes[65537];
        for (unsigned i = 0; i < 136; i++) {
            NSUInteger length = sizes[i % 8];
            for (NSUInteger j = 0; j < length; j++)
                bytes[j] = (round * 71 + i * 17 + j) & 255;
            [reference appendBytes:bytes length:length];
            id<MTLBuffer> source = [commands uploadBytes:bytes length:length
                                                 offset:&offsets[i] error:&error];
            require(source != nil, error);
            assert(!(offsets[i] % 256));
            [sources addObject:source];
            memset(bytes, 0xa5, length);
        }
        id<MTLBuffer> result = [commands.device
            newBufferWithLength:reference.length
                        options:MTLResourceStorageModeShared];
        assert(result);
        require([commands addResource:result error:&error], error);
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        assert(encoder);
        NSUInteger destination = 0;
        for (unsigned i = 0; i < 136; i++) {
            [encoder copyFromBuffer:sources[i] sourceOffset:offsets[i]
                          toBuffer:result destinationOffset:destination
                              size:sizes[i % 8]];
            destination += sizes[i % 8];
        }
        [encoder endEncoding];
        require([commands submitWithError:&error], error);
        [results addObject:result];
        [expected addObject:reference];
    }
    require([commands waitUntilIdleWithError:&error], error);
    for (NSUInteger i = 0; i < results.count; i++)
        assert(!memcmp(results[i].contents, expected[i].bytes,
                       expected[i].length));
    puts("Metal upload arena: 816 GPU slice byte comparisons across six "
         "submissions, nonzero offsets, page/capacity overflow, oversized "
         "uploads and slot reuse PASS");
}
static void check(NV2AMetalPendingUpdate *update, NV2AMetalCommands *commands,
                  NSArray<NSNumber *> *firsts, NSArray<NSNumber *> *counts)
{
    NSError *error = nil;
    NV2AMetalPendingNative *native =
        [[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                device:commands.device
                                                 limit:256
                                                 error:&error];
    require(native != nil, error);
    assert([native.counts isEqualToArray:counts]);
    require([commands beginWithError:&error] != nil, error);
    NSArray<id<MTLBuffer>> *joined = [native encodeWithCommands:commands
                                                          error:&error];
    require(joined != nil, error);
    NSMutableArray<id<MTLBuffer>> *readbacks = [NSMutableArray new];
    for (NSUInteger i = 0; i < counts.count; i++)
        [readbacks addObject:readback(joined[i], counts[i].unsignedIntegerValue,
                                    commands)];
    finish(commands);
    assert(joined.count == counts.count && firsts.count == counts.count);
    for (NSUInteger i = 0; i < counts.count; i++) {
        NSUInteger first = firsts[i].unsignedIntegerValue,
                   count = counts[i].unsignedIntegerValue;
        assert(!memcmp(readbacks[i].contents, sourceVertices + first,
                       count * sizeof(NV2AMetalVertex)));
        compared += count;
    }
    assemblies++;
}
static NV2AMetalPendingInput *input(unsigned kind, unsigned count)
{
    if (kind == NV2AMetalInputArrays)
        return [NV2AMetalPendingInput arraysFrom:0 count:count];
    if (kind == NV2AMetalInputIndexed) {
        uint32_t indices[32];
        for (unsigned i = 0; i < count; i++)
            indices[i] = i;
        return [NV2AMetalPendingInput indexed:[NSData dataWithBytes:indices
                                                             length:count * 4]];
    }
    return [NV2AMetalPendingInput inlineKind:kind count:count];
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        check_uploads(commands);
        uint32_t *words = (uint32_t *)sourceVertices;
        for (unsigned i = 0; i < sizeof(sourceVertices) / 4; i++)
            words[i] = 0x3e000000u + i * 31u;
        check_reuse(commands);
        id<MTLBuffer> staging =
            [commands.device newBufferWithBytes:sourceVertices
                                         length:sizeof(sourceVertices)
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> gpu =
            [commands.device newBufferWithLength:sizeof(sourceVertices)
                                         options:MTLResourceStorageModePrivate];
        assert(staging && gpu);
        require([commands beginWithError:&error] != nil, error);
        require([commands addResource:staging error:&error], error);
        require([commands addResource:gpu error:&error], error);
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        assert(encoder);
        [encoder copyFromBuffer:staging
                   sourceOffset:0
                       toBuffer:gpu
              destinationOffset:0
                           size:sizeof(sourceVertices)];
        [encoder barrierAfterStages:MTLStageBlit
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
        finish(commands);
        for (unsigned kind = 1; kind <= 4; kind++) {
            NV2AMetalPendingJournal *journal =
                [[NV2AMetalPendingJournal alloc] initWithLimit:256];
            NV2AMetalPendingUpdate *update = nil;
            for (unsigned count = 1; count <= 32; count++) {
                NV2AMetalPendingPlan *plan =
                    [journal planInputs:@[ input(kind, count) ]
                        preservingLastArray:NO
                                      error:&error];
                require(plan != nil, error);
                NV2AMetalPendingSpan *span =
                    [NV2AMetalPendingSpan resource:gpu
                                             first:16 + count - 1
                                             count:1];
                update = [journal preparePlan:plan
                                     suffixes:@[ span ]
                                        error:&error];
                require(update != nil, error);
                check(update, commands, @[ @16 ], @[ @(count) ]);
                require([journal commitUpdate:update error:&error], error);
            }
            require([journal consumeUpdate:update error:&error], error);
            assert(!journal.streamCount);
        }
        NV2AMetalPendingJournal *journal =
            [[NV2AMetalPendingJournal alloc] initWithLimit:256];
        NSArray *ranges = @[
            [NV2AMetalPendingInput arraysFrom:10 count:3],
            [NV2AMetalPendingInput arraysFrom:20 count:3],
            [NV2AMetalPendingInput arraysFrom:30 count:3]
        ];
        NV2AMetalPendingPlan *plan = [journal planInputs:ranges
                                     preservingLastArray:NO
                                                   error:&error];
        require(plan != nil, error);
        NV2AMetalPendingUpdate *update = [journal
            preparePlan:plan
               suffixes:@[
                   [NV2AMetalPendingSpan resource:gpu first:10 count:3],
                   [NV2AMetalPendingSpan resource:gpu first:20 count:3],
                   [NV2AMetalPendingSpan resource:gpu first:30 count:3]
               ]
                  error:&error];
        require(update != nil, error);
        check(update, commands, @[ @10, @20, @30 ], @[ @3, @3, @3 ]);
        require([journal commitUpdate:update error:&error], error);
        plan = [journal planInputs:[ranges subarrayWithRange:NSMakeRange(0, 2)]
               preservingLastArray:YES
                             error:&error];
        require(plan != nil, error);
        update = [journal preparePlan:plan
                             suffixes:@[ NSNull.null, NSNull.null ]
                                error:&error];
        require(update != nil, error);
        check(update, commands, @[ @10, @20 ], @[ @3, @3 ]);
        require([journal commitUpdate:update error:&error], error);
        require([journal consumeUpdate:update error:&error], error);
        assert(journal.streamCount == 1);
        uint32_t expanded[] = { 30, 31, 32, 33 };
        plan = [journal planInputs:@[
            [NV2AMetalPendingInput
                indexed:[NSData dataWithBytes:expanded length:sizeof(expanded)]]
        ]
               preservingLastArray:NO
                             error:&error];
        require(plan != nil, error);
        assert([plan.prefixCounts isEqualToArray:@[ @3 ]]);
        update = [journal preparePlan:plan
                             suffixes:@[ [NV2AMetalPendingSpan resource:gpu
                                                                  first:33
                                                                  count:1] ]
                                error:&error];
        require(update != nil, error);
        check(update, commands, @[ @30 ], @[ @4 ]);
        require([journal commitUpdate:update error:&error], error);
        require([journal consumeUpdate:update error:&error], error);
        assert(!journal.streamCount);
        for (unsigned bad = 0; bad < 3; bad++) {
            NV2AMetalPendingJournal *j =
                [[NV2AMetalPendingJournal alloc] initWithLimit:256];
            plan = [j planInputs:@[ [NV2AMetalPendingInput arraysFrom:0
                                                                count:2] ]
                preservingLastArray:NO
                              error:&error];
            require(plan != nil, error);
            NV2AMetalPendingSpan *span =
                [NV2AMetalPendingSpan resource:bad == 0 ? [NSObject new] : gpu
                                         first:bad == 1 ? 255 : 0
                                         count:2];
            update = [j preparePlan:plan suffixes:@[ span ] error:&error];
            require(update != nil, error);
            error = nil;
            assert(![[NV2AMetalPendingNative alloc]
                       initWithUpdate:update
                               device:commands.device
                                limit:bad == 2 ? 1 : 256
                                error:&error] &&
                   error);
            assert(!commands.commandBuffer && !j.streamCount);
            rejects++;
        }
        journal = [[NV2AMetalPendingJournal alloc] initWithLimit:4];
        error = nil;
        plan = [journal planInputs:@[
            [NV2AMetalPendingInput arraysFrom:0 count:2],
            [NV2AMetalPendingInput arraysFrom:2 count:2]
        ]
               preservingLastArray:NO
                             error:&error];
        require(plan != nil, error);
        update =
            [journal preparePlan:plan
                        suffixes:@[
                            [NV2AMetalPendingSpan resource:gpu first:0 count:2],
                            [NV2AMetalPendingSpan resource:gpu first:2 count:2]
                        ]
                           error:&error];
        require(update != nil, error);
        NV2AMetalPendingNative *wide =
            [[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                    device:commands.device
                                               streamLimit:2
                                                totalLimit:NSUIntegerMax
                                                     error:&error];
        require(wide != nil, error);
        assert(wide.counts.count == 2);
        require([commands beginWithError:&error] != nil, error);
        NSArray<id<MTLBuffer>> *wideBuffers = [wide encodeWithCommands:commands
                                                                 error:&error];
        require(wideBuffers != nil, error);
        id<MTLBuffer> wideReadbacks[2];
        for (unsigned i = 0; i < 2; i++)
            wideReadbacks[i] = readback(wideBuffers[i], 2, commands);
        finish(commands);
        for (unsigned i = 0; i < 2; i++)
            assert(!memcmp(wideReadbacks[i].contents, sourceVertices + i * 2,
                           2 * sizeof(NV2AMetalVertex)));
        error = nil;
        assert(![[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                        device:commands.device
                                                   streamLimit:1
                                                    totalLimit:4
                                                         error:&error] &&
               error);
        error = nil;
        assert(![[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                        device:commands.device
                                                   streamLimit:2
                                                    totalLimit:3
                                                         error:&error] &&
               error);
        assert(!commands.commandBuffer && !journal.streamCount);
        puts("Independent native limits: two streams may exceed single-stream "
             "capacity; four extra full vertex byte comparisons and two "
             "pre-encoding capacity rejections PASS");
        assert(assemblies == 131 && compared == 2131 && rejects == 3);
        puts("Pending native assembly: 131 independent stream assemblies/2131 "
             "complete synthetic GPU vertex byte comparisons, four input "
             "kinds, hidden-last expansion, three pre-encoding rejects PASS; "
             "no CPU vertex readback in adapter");
    }
    return 0;
}
