/* Native pending snapshot copies, offscreen only.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/archive-native.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-program.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "test-metal-vertex-context.h"
static unsigned roundtrips, rejects;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Pending archive native: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static NSData *raw(unsigned count, unsigned seed)
{
    const uint32_t pattern[] = { 0,          0x80000000, 0x7f800001, 0x7fc12345,
                                 0xff812345, 0x7f800000, 0xff800000, 1,
                                 0x807fffff, 0x3f800000 };
    NSMutableData *data =
        [NSMutableData dataWithLength:count * sizeof(NV2AMetalVertex)];
    for (NSUInteger i = 0; i < data.length / 4; i++) {
        uint32_t word = pattern[(i + seed) % 10];
        memcpy((uint8_t *)data.mutableBytes + 4 * i, &word, 4);
    }
    return data;
}
static NV2AMetalPendingInput *input(unsigned kind, unsigned count)
{
    if (kind == 1)
        return [NV2AMetalPendingInput arraysFrom:37 count:count];
    if (kind == 2) {
        NSMutableData *data = [NSMutableData new];
        for (unsigned i = 0; i < count; i++) {
            uint32_t index = (i * 37) ^ 0x80000000u;
            [data appendBytes:&index length:4];
        }
        return [NV2AMetalPendingInput indexed:data];
    }
    return [NV2AMetalPendingInput inlineKind:kind count:count];
}
static void check(NV2AMetalPendingArchive *archive, NV2AMetalCommands *commands)
{
    NSData *wire = archive.data;
    for (unsigned cycle = 0; cycle < 2; cycle++) {
        NSError *error = nil;
        NV2AMetalPendingJournal *journal =
            nv2a_metal_pending_restore(archive, commands, 256, &error);
        require(journal != nil, error);
        assert(journal.streamCount == archive.inputs.count);
        for (NSArray *spans in journal.retainedStreams)
            for (NV2AMetalPendingSpan *span in spans)
                assert(((id<MTLBuffer>)span.resource).storageMode ==
                       MTLStorageModePrivate);
        NV2AMetalPendingArchive *saved =
            nv2a_metal_pending_capture(journal, commands, &error);
        require(saved != nil, error);
        assert([saved.data isEqualToData:wire] &&
               [saved.vertices isEqualToArray:archive.vertices]);
        archive = [[NV2AMetalPendingArchive alloc] initWithData:saved.data
                                                          limit:256
                                                          error:&error];
        require(archive != nil, error);
    }
    roundtrips++;
}
#include "test-metal-discarded-transport.h"
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        const unsigned counts[] = { 1, 2, 3, 7, 16, 31, 32 };
        for (unsigned kind = 1; kind <= 4; kind++)
            for (unsigned c = 0; c < 7; c++)
                for (unsigned seed = 0; seed < 4; seed++)
                    @autoreleasepool {
                        NV2AMetalPendingArchive *archive =
                            [[NV2AMetalPendingArchive alloc]
                                initWithInputs:@[ input(kind, counts[c]) ]
                                      vertices:@[ raw(counts[c], seed) ]
                                         limit:256
                                         error:&error];
                        require(archive != nil, error);
                        check(archive, commands);
                    }
        NV2AMetalPendingArchive *empty =
            [[NV2AMetalPendingArchive alloc] initWithInputs:@[]
                                                   vertices:@[]
                                                      limit:256
                                                      error:&error];
        require(empty != nil, error);
        check(empty, commands);
        NSArray *ranges =
                    @[
                        [NV2AMetalPendingInput arraysFrom:10 count:3],
                        [NV2AMetalPendingInput arraysFrom:20 count:3],
                        [NV2AMetalPendingInput arraysFrom:30 count:3]
                    ],
                *bytes = @[ raw(3, 1), raw(3, 2), raw(3, 3) ];
        NV2AMetalPendingArchive *archive =
            [[NV2AMetalPendingArchive alloc] initWithInputs:ranges
                                                   vertices:bytes
                                                      limit:256
                                                      error:&error];
        require(archive != nil, error);
        NV2AMetalPendingJournal *journal =
            nv2a_metal_pending_restore(archive, commands, 256, &error);
        require(journal != nil, error);
        NV2AMetalPendingPlan *plan =
            [journal planInputs:[ranges subarrayWithRange:NSMakeRange(0, 2)]
                preservingLastArray:YES
                              error:&error];
        require(plan != nil, error);
        NV2AMetalPendingUpdate *update =
            [journal preparePlan:plan
                        suffixes:@[ NSNull.null, NSNull.null ]
                           error:&error];
        require(update != nil, error);
        require([journal commitUpdate:update error:&error], error);
        NV2AMetalPendingArchive *saved =
            nv2a_metal_pending_capture(journal, commands, &error);
        require(saved != nil, error);
        assert(saved.inputs.count == 3 &&
               [saved.data isEqualToData:archive.data]);
        check(saved, commands);
        require([journal consumeUpdate:update error:&error], error);
        assert(journal.streamCount == 1);
        uint32_t indices[] = { 30, 31, 32 };
        plan = [journal planInputs:@[
            [NV2AMetalPendingInput
                indexed:[NSData dataWithBytes:indices length:sizeof(indices)]]
        ]
               preservingLastArray:NO
                             error:&error];
        require(plan != nil, error);
        assert([plan.prefixCounts isEqualToArray:@[ @3 ]]);
        update = [journal preparePlan:plan
                             suffixes:@[ NSNull.null ]
                                error:&error];
        require(update != nil, error);
        require([journal commitUpdate:update error:&error], error);
        saved = nv2a_metal_pending_capture(journal, commands, &error);
        require(saved != nil, error);
        assert(saved.inputs.count == 1 &&
               [saved.vertices[0] isEqualToData:bytes[2]]);
        check(saved, commands);
        /* Capture actual native vertex-transform output once, restore only
         * bytes. */
        NV2AMetalVertexProgram *program =
            [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                     error:&error];
        require(program != nil, error);
        Token tokens[2] = { token(1, 0, 96), token(1, 0, 96) };
        source(&tokens[0], 0, 2, 0, 0xe4);
        destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
        tokens[1].word[1] |= 1u << 9;
        source(&tokens[1], 0, 2, 0, 0xe4);
        destination(&tokens[1], 0x103, 15, 0, 0, 0, 0);
        tokens[1].word[3] |= 1;
        NV2AMetalProgramInput inputs[4] = { 0 };
        for (unsigned v = 0; v < 4; v++)
            for (unsigned a = 0; a < 2; a++)
                for (unsigned k = 0; k < 4; k++)
                    inputs[v].attributes[a][k] = (float)(v + a + k + 1);
        NV2AMetalProgramUniforms u = { 0 };
        u.surface_size[0] = u.surface_size[1] = 4;
        u.zmax = 16;
        u.point_size = u.point_scale = 1;
        id<MTLBuffer> attributes =
            [commands.device newBufferWithBytes:inputs
                                         length:sizeof(inputs)
                                        options:MTLResourceStorageModeShared];
        assert(attributes);
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalProgramResult *result = [program encodeTokens:tokens[0].word
                                                        length:2
                                                      uniforms:&u
                                                    attributes:attributes
                                                         count:4
                                                      commands:commands
                                                         error:&error];
        require(result != nil, error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        journal = [[NV2AMetalPendingJournal alloc] initWithLimit:256];
        plan = [journal planInputs:@[ [NV2AMetalPendingInput arraysFrom:0
                                                                  count:4] ]
               preservingLastArray:NO
                             error:&error];
        require(plan != nil, error);
        update = [journal
            preparePlan:plan
               suffixes:@[ [NV2AMetalPendingSpan resource:result.vertices
                                                    first:0
                                                    count:4] ]
                  error:&error];
        require(update != nil, error);
        require([journal commitUpdate:update error:&error], error);
        saved = nv2a_metal_pending_capture(journal, commands, &error);
        require(saved != nil, error);
        assert(saved.vertices[0].length == result.vertices.length &&
               !memcmp(saved.vertices[0].bytes, result.vertices.contents,
                       result.vertices.length));
        check(saved, commands);
        error = nil;
        assert(!nv2a_metal_pending_restore(saved, commands, 3, &error) &&
               error);
        assert(!commands.commandBuffer);
        rejects++;
        require([commands beginWithError:&error] != nil, error);
        error = nil;
        assert(!nv2a_metal_pending_capture(journal, commands, &error) && error);
        [commands cancel];
        rejects++;
        assert(roundtrips == 116 && rejects == 2);
        discarded_transport_tests(commands);
        puts("Native pending archive: 116 archives/two GPU save-restore cycles "
             "each, four input kinds, raw NaN bits/private buffers, hidden "
             "last range and actual GPU-transformed vertices, two pre-encoding "
             "rejects PASS; no vertex replay or PGRAPH mutation");
    }
    return 0;
}
