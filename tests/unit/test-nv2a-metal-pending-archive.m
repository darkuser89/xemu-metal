/* Raw pending-vertex archive CPU test, no Metal runtime.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/pending-archive.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned roundtrips, rejections, restores;
static NSData *raw(unsigned count, unsigned seed)
{
    static const uint32_t special[] = { 0,          0x80000000, 0x7f800000,
                                        0xff800000, 0x7fc12345, 0x7f800001,
                                        0xff812345, 1,          0x807fffff,
                                        0x3f800000 };
    NSMutableData *data =
        [NSMutableData dataWithLength:count * sizeof(NV2AMetalVertex)];
    for (NSUInteger i = 0; i < data.length / 4; i++) {
        uint32_t bits = special[(i + seed) % 10];
        memcpy((uint8_t *)data.mutableBytes + 4 * i, &bits, 4);
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
static void reject(NSData *data, unsigned limit)
{
    NSError *error = nil;
    assert(![[NV2AMetalPendingArchive alloc] initWithData:data
                                                    limit:limit
                                                    error:&error] &&
           error);
    rejections++;
}
static NSMutableData *word(NSData *data, unsigned offset, uint32_t value)
{
    assert(offset + 4 <= data.length);
    NSMutableData *copy = [data mutableCopy];
    uint8_t bytes[] = { value >> 24, value >> 16, value >> 8, value };
    [copy replaceBytesInRange:NSMakeRange(offset, 4) withBytes:bytes];
    return copy;
}
static void check(NSArray *inputs, NSArray *vertices, unsigned limit)
{
    NSError *error = nil;
    NV2AMetalPendingArchive *a =
        [[NV2AMetalPendingArchive alloc] initWithInputs:inputs
                                               vertices:vertices
                                                  limit:limit
                                                  error:&error];
    assert(a && !error);
    NSData *wire = a.data;
    NV2AMetalPendingArchive *b =
        [[NV2AMetalPendingArchive alloc] initWithData:wire
                                                limit:limit
                                                error:&error];
    assert(b && !error && [b.data isEqualToData:wire] &&
           [b.vertices isEqualToArray:vertices]);
    assert(b.inputs.count == inputs.count);
    for (NSUInteger i = 0; i < inputs.count; i++) {
        NV2AMetalPendingInput *x = inputs[i], *y = b.inputs[i];
        assert(x.kind == y.kind && x.first == y.first && x.count == y.count &&
               [x.indices isEqualToData:y.indices]);
    }
    NV2AMetalPendingJournal *journal = b.CPUJournal;
    assert(journal && journal.streamCount == inputs.count);
    NV2AMetalPendingPlan *plan = [journal planInputs:inputs
                                 preservingLastArray:NO
                                               error:&error];
    assert(plan && !error);
    NSMutableArray *suffixes = [NSMutableArray new];
    for (NSUInteger i = 0; i < inputs.count; i++) {
        assert(plan.prefixCounts[i].unsignedIntegerValue ==
               ((NV2AMetalPendingInput *)inputs[i]).count);
        [suffixes addObject:NSNull.null];
    }
    NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                 suffixes:suffixes
                                                    error:&error];
    assert(update && !error);
    for (NSUInteger i = 0; i < inputs.count; i++) {
        assert(update.streams[i].count == 1);
        NV2AMetalPendingSpan *span = update.streams[i][0];
        assert(span.first == 0 &&
               span.count == ((NV2AMetalPendingInput *)inputs[i]).count &&
               [span.resource isEqualToData:vertices[i]]);
    }
    assert([journal commitUpdate:update error:&error] && !error);
    assert([journal consumeUpdate:update error:&error] && !error &&
           !journal.streamCount);
    restores++;
    roundtrips++;
}
int main(void)
{
    @autoreleasepool {
        const unsigned counts[] = { 1, 2, 3, 7, 16, 31, 32 };
        for (unsigned kind = 1; kind <= 4; kind++)
            for (unsigned c = 0; c < 7; c++)
                for (unsigned seed = 0; seed < 32; seed++)
                    check(@[ input(kind, counts[c]) ],
                          @[ raw(counts[c], seed) ], 524287);
        for (unsigned count = 0; count <= 1250; count++)
            @autoreleasepool {
                NSMutableArray *inputs = [NSMutableArray new],
                               *vertices = [NSMutableArray new];
                for (unsigned i = 0; i < count; i++) {
                    [inputs addObject:[NV2AMetalPendingInput arraysFrom:i * 7
                                                                  count:1]];
                    [vertices addObject:raw(1, i)];
                }
                check(inputs, vertices, 524287);
            }
        check(@[ [NV2AMetalPendingInput arraysFrom:UINT32_MAX count:1] ],
              @[ raw(1, 0) ], 1);
        NSError *error = nil;
        NV2AMetalPendingArchive *a =
            [[NV2AMetalPendingArchive alloc] initWithInputs:@[ input(1, 1) ]
                                                   vertices:@[ raw(1, 0) ]
                                                      limit:1
                                                      error:&error];
        assert(a && !error);
        NSData *wire = a.data;
        for (NSUInteger length = 0; length < wire.length; length++)
            reject([wire subdataWithRange:NSMakeRange(0, length)], 1);
        for (unsigned offset = 0; offset < 36; offset += 4)
            for (unsigned value = 0; value < 8; value++) {
                const uint32_t fields[] = { 0, 1,    2,      3,
                                            4, 1251, 524288, UINT32_MAX };
                NSMutableData *bad = word(wire, offset, fields[value]);
                /* Some altered fields describe another canonical valid archive.
                 */
                NSError *e = nil;
                NV2AMetalPendingArchive *decoded =
                    [[NV2AMetalPendingArchive alloc] initWithData:bad
                                                            limit:1
                                                            error:&e];
                if (decoded)
                    assert(!e && [decoded.data isEqualToData:bad]);
                else {
                    assert(e);
                    rejections++;
                }
            }
        NSMutableData *trailing = [wire mutableCopy];
        uint8_t extra = 0;
        [trailing appendBytes:&extra length:1];
        reject(trailing, 1);
        reject(wire, 0);
        reject(wire, 524288);
        NV2AMetalPendingArchive *indexed =
            [[NV2AMetalPendingArchive alloc] initWithInputs:@[ input(2, 2) ]
                                                   vertices:@[ raw(2, 0) ]
                                                      limit:2
                                                      error:&error];
        assert(indexed);
        reject(word(indexed.data, 32, 1), 2);
        reject(word(indexed.data, 24, 1), 2);
        reject(indexed.data, 1);
        NSMutableData *mutable = [raw(1, 7) mutableCopy];
        a = [[NV2AMetalPendingArchive alloc] initWithInputs:@[ input(3, 1) ]
                                                   vertices:@[ mutable ]
                                                      limit:1
                                                      error:&error];
        assert(a);
        NSData *before = a.data;
        memset(mutable.mutableBytes, 0, mutable.length);
        assert([before isEqualToData:a.data]);
        assert(roundtrips == 2148 && restores == 2148);
        printf("Pending archive CPU: %u canonical roundtrips/%u restored "
               "journals, %u malformed/truncated rejections PASS; raw signed "
               "zero/NaN/Inf/subnormal bits preserved, no Metal "
               "device/queue/dispatch\n",
               roundtrips, restores, rejections);
    }
    return 0;
}
