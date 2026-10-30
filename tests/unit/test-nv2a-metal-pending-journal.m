/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
/* CPU-only transformed-stream metadata test. Resources are immutable ID data,
 * not GPU vertices; no Metal device/queue/dispatch is created. */
#import "hw/xbox/nv2a/pgraph/metal/pending-journal.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned checks, commits, rejections;
static void index_snapshot_reuse(void)
{
    uint32_t words[] = { UINT32_MAX, 37, 9, 0, 900 };
    NV2AMetalPendingInput *input = nil;
    for (NSUInteger count = 1; count <= 5; count++) {
        NV2AMetalPendingInput *next =
            [NV2AMetalPendingInput indexedBytes:words
                                          count:count
                               matchingPrevious:input];
        assert(next && next != input && next.count == count);
        assert(next.minimumIndex == (count == 1 ? UINT32_MAX :
                                     count == 2 ? 37 :
                                     count == 3 ? 9 :
                                                  0));
        assert(next.maximumIndex == UINT32_MAX);
        assert([NV2AMetalPendingInput indexedBytes:words
                                             count:count
                                  matchingPrevious:next] == next);
        assert(!memcmp(next.indices.bytes, words, count * 4));
        input = next;
    }
    words[0] = 20;
    NV2AMetalPendingInput *changed = [NV2AMetalPendingInput indexedBytes:words
                                                                   count:5
                                                        matchingPrevious:input];
    assert(changed != input && changed.maximumIndex == 900 &&
           input.maximumIndex == UINT32_MAX);
    NV2AMetalPendingInput *shorter = [NV2AMetalPendingInput indexedBytes:words
                                                                   count:2
                                                        matchingPrevious:input];
    assert(shorter.count == 2 && shorter.minimumIndex == 20 &&
           shorter.maximumIndex == 37);
    /* No aligned uint32_t access and no retained pointer to caller storage. */
    uint8_t raw[] = { 0xaa, 0x80, 0, 0, 0, 0, 0, 0, 0x80, 0xbb };
    NV2AMetalPendingInput *unaligned =
        [NV2AMetalPendingInput indexedBytes:raw + 1
                                      count:2
                           matchingPrevious:nil];
    memset(raw, 0, sizeof(raw));
    assert(unaligned.minimumIndex == 128 &&
           unaligned.maximumIndex == 0x80000000u);
    __weak NV2AMetalPendingInput *weak = nil;
    NV2AMetalPendingInput *grown = nil;
    @autoreleasepool {
        NV2AMetalPendingInput *old = [NV2AMetalPendingInput indexedBytes:words
                                                                   count:2
                                                        matchingPrevious:nil];
        weak = old;
        grown = [NV2AMetalPendingInput indexedBytes:words
                                              count:5
                                   matchingPrevious:old];
        assert(weak && grown.minimumIndex == 0 && grown.maximumIndex == 900);
    }
    assert(!weak && grown.count == 5);
    assert(![NV2AMetalPendingInput indexedBytes:NULL
                                          count:1
                               matchingPrevious:nil]);
    assert(![NV2AMetalPendingInput indexedBytes:words
                                          count:0
                               matchingPrevious:nil]);
    assert(![NV2AMetalPendingInput indexedBytes:words
                                          count:NSUIntegerMax / 4 + 1
                               matchingPrevious:nil]);
    puts(
        "Pending index snapshots: identical reuse, growth/full bounds, changed "
        "prefix, shrink, unaligned LE32, immutable bytes and weak history "
        "PASS");
}
static NV2AMetalPendingInput *array(unsigned first, unsigned count)
{
    NV2AMetalPendingInput *input = [NV2AMetalPendingInput arraysFrom:first
                                                               count:count];
    assert(input);
    return input;
}
static NV2AMetalPendingInput *indices(const uint32_t *words, unsigned count)
{
    NV2AMetalPendingInput *input = [NV2AMetalPendingInput
        indexed:[NSData dataWithBytes:words length:count * 4]];
    assert(input);
    return input;
}
static NV2AMetalPendingSpan *tags(unsigned epoch, unsigned stream,
                                  unsigned first, unsigned count)
{
    NSMutableData *data = [NSMutableData dataWithLength:(count + 2) * 4];
    uint32_t *values = data.mutableBytes;
    values[0] = values[count + 1] = 0xdeadbeefu;
    for (unsigned n = 0; n < count; n++)
        values[n + 1] = (epoch << 24) | (stream << 16) | (first + n + 1);
    NV2AMetalPendingSpan *span = [NV2AMetalPendingSpan resource:[data copy]
                                                          first:1
                                                          count:count];
    assert(span);
    return span;
}
static void compare(NSArray<NV2AMetalPendingSpan *> *stream,
                    NSArray<NSNumber *> *expected)
{
    NSUInteger vertex = 0;
    for (NV2AMetalPendingSpan *span in stream) {
        NSData *data = span.resource;
        assert([data isKindOfClass:NSData.class]);
        assert(span.first + span.count <= data.length / 4);
        for (NSUInteger i = 0; i < span.count; i++) {
            uint32_t value;
            memcpy(&value, (const uint8_t *)data.bytes + 4 * (span.first + i),
                   4);
            assert(vertex < expected.count &&
                   value == expected[vertex].unsignedIntValue);
            vertex++;
            checks++;
        }
    }
    assert(vertex == expected.count);
}
static NV2AMetalPendingUpdate *
step(NV2AMetalPendingJournal *j, NSArray<NV2AMetalPendingInput *> *inputs,
     NSArray<NSMutableArray<NSNumber *> *> *expected, unsigned epoch,
     unsigned firstStream, BOOL partial)
{
    NSError *error = nil;
    NV2AMetalPendingPlan *plan = [j planInputs:inputs
                           preservingLastArray:partial
                                         error:&error];
    assert(plan && !error);
    NSMutableArray *suffixes = [NSMutableArray new];
    for (NSUInteger b = 0; b < inputs.count; b++) {
        NSUInteger before = expected[b].count, total = inputs[b].count;
        assert(plan.prefixCounts[b].unsignedIntegerValue == before &&
               total >= before);
        if (total == before)
            [suffixes addObject:NSNull.null];
        else
            [suffixes
                addObject:tags(epoch, (unsigned)b + firstStream,
                               (unsigned)before, (unsigned)(total - before))];
        for (NSUInteger i = before; i < total; i++)
            [expected[b] addObject:@((epoch << 24) |
                                     (((unsigned)b + firstStream) << 16) |
                                     ((unsigned)i + 1))];
    }
    error = nil;
    NV2AMetalPendingUpdate *update = [j preparePlan:plan
                                           suffixes:suffixes
                                              error:&error];
    assert(update && !error);
    for (NSUInteger b = 0; b < inputs.count; b++)
        compare(update.streams[b], expected[b]);
    error = nil;
    assert([j commitUpdate:update error:&error] && !error);
    commits++;
    error = nil;
    assert(![j commitUpdate:update error:&error] && error);
    rejections++;
    return update;
}
static void reject_plan(NV2AMetalPendingJournal *j, NSArray *inputs,
                        BOOL partial)
{
    NSUInteger generation = j.generation, streams = j.streamCount;
    NSError *error = nil;
    assert(![j planInputs:inputs preservingLastArray:partial error:&error] &&
           error);
    assert(j.generation == generation && j.streamCount == streams);
    rejections++;
}
static NV2AMetalPendingInput *progress_input(unsigned kind, unsigned stream,
                                             unsigned count)
{
    if (kind == NV2AMetalInputArrays)
        return array(stream * 100, count);
    if (kind == NV2AMetalInputIndexed) {
        uint32_t words[4];
        for (unsigned i = 0; i < count; i++)
            words[i] = stream * 100 + (i ^ 1);
        return indices(words, count);
    }
    return [NV2AMetalPendingInput inlineKind:kind count:count];
}
static void incremental_publication(void)
{
    unsigned cases = 0, partials = 0, rejected = 0;
    for (unsigned kind = 1; kind <= 4; kind++)
        for (unsigned streams = 1; streams <= 8; streams++) {
            @autoreleasepool {
                NV2AMetalPendingJournal *j =
                    [[NV2AMetalPendingJournal alloc] initWithLimit:128];
                NSMutableArray *inputs = [NSMutableArray new],
                               *full = [NSMutableArray new],
                               *suffixes = [NSMutableArray new];
                for (unsigned i = 0; i < streams; i++) {
                    [inputs addObject:progress_input(kind, i, 3)];
                    [full addObject:progress_input(kind, i, 4)];
                    [suffixes addObject:tags(1, i, 0, 3)];
                }
                NSError *error = nil;
                NV2AMetalPendingPlan *plan = [j planInputs:inputs
                                       preservingLastArray:NO
                                                     error:&error];
                assert(plan && !error);
                NV2AMetalPendingUpdate *update = [j preparePlan:plan
                                                       suffixes:suffixes
                                                          error:&error];
                assert(update && [j commitUpdate:update error:&error] &&
                       !error);
                for (unsigned completed = 1; completed <= streams;
                     completed++) {
                    plan = [j planInputs:full
                        preservingLastArray:NO
                                      error:&error];
                    assert(plan && !error);
                    for (unsigned i = 0; i < streams; i++)
                        assert(plan.prefixCounts[i].unsignedIntegerValue ==
                               (i + 1 < completed ? 4u : 3u));
                    suffixes = [NSMutableArray new];
                    for (unsigned i = 0; i + 1 < completed; i++)
                        [suffixes addObject:NSNull.null];
                    [suffixes addObject:tags(2, completed - 1, 3, 1)];
                    NSUInteger generation = j.generation;
                    error = nil;
                    assert(![j preparePlan:plan
                               completedInputs:0
                                      suffixes:@[]
                                         error:&error] &&
                           error);
                    rejected++;
                    error = nil;
                    assert(![j preparePlan:plan
                               completedInputs:streams + 1
                                      suffixes:suffixes
                                         error:&error] &&
                           error);
                    rejected++;
                    assert(j.generation == generation);
                    error = nil;
                    update = [j preparePlan:plan
                            completedInputs:completed
                                   suffixes:suffixes
                                      error:&error];
                    assert(update && !error &&
                           update.streams.count == completed);
                    assert([j commitUpdate:update error:&error] && !error &&
                           j.streamCount == streams);
                    partials++;
                    error = nil;
                    assert(![j consumeUpdate:update error:&error] && error);
                    rejected++;
                    error = nil;
                    assert(![j preparePlan:plan
                               completedInputs:completed
                                      suffixes:suffixes
                                         error:&error] &&
                           error);
                    rejected++;
                    error = nil;
                }
                plan = [j planInputs:full preservingLastArray:NO error:&error];
                assert(plan && !error);
                suffixes = [NSMutableArray new];
                for (unsigned i = 0; i < streams; i++) {
                    assert(plan.prefixCounts[i].unsignedIntegerValue == 4);
                    [suffixes addObject:NSNull.null];
                }
                update = [j preparePlan:plan suffixes:suffixes error:&error];
                assert(update && [j commitUpdate:update error:&error] &&
                       !error);
                for (unsigned i = 0; i < streams; i++) {
                    assert(update.streams[i].count == 2);
                    NV2AMetalPendingSpan *old = update.streams[i][0],
                                         *new = update.streams[i][1];
                    assert(old.count == 3 && new.count == 1);
                    const uint32_t *a = ((NSData *)old.resource).bytes,
                                   *b = ((NSData *)new.resource).bytes;
                    assert(a[1] == ((1u << 24) | (i << 16) | 1u) &&
                           a[3] == ((1u << 24) | (i << 16) | 3u) &&
                           b[1] == ((2u << 24) | (i << 16) | 4u));
                }
                assert([j consumeUpdate:update error:&error] && !error &&
                       !j.streamCount);
                cases++;
            }
        }
    assert(cases == 32 && partials == 144 && rejected == 576);
    printf("Pending incremental CPU: %u four-input/range-count cases, %u "
           "completed-prefix commits, %u invalid/stale/partial-consume "
           "rejections; unprocessed future resources retained PASS\n",
           cases, partials, rejected);
}

#include "test-metal-pending-progress.h"

static void transaction_copy_tests(void)
{
    for (unsigned kind = 1; kind <= 4; kind++) {
        NV2AMetalPendingInput * (^input)(NSUInteger) = ^(NSUInteger count) {
          if (kind == NV2AMetalInputArrays)
              return [NV2AMetalPendingInput arraysFrom:5 count:count];
          if (kind == NV2AMetalInputIndexed) {
              uint32_t words[] = { 3, 7, 1, 9, 2, 4, 5, 8, 6 };
              return [NV2AMetalPendingInput
                  indexed:[NSData dataWithBytes:words length:count * 4]];
          }
          return [NV2AMetalPendingInput inlineKind:kind count:count];
        };
        NSError *error = nil;
        NV2AMetalPendingJournal *original =
            [[NV2AMetalPendingJournal alloc] initWithLimit:8];
        NV2AMetalPendingPlan *plan = [original planInputs:@[ input(2) ]
                                      preservingLastArray:NO
                                                    error:&error];
        NV2AMetalPendingSpan *a = [NV2AMetalPendingSpan resource:@"accepted"
                                                           first:4
                                                           count:2];
        NV2AMetalPendingUpdate *base = [original preparePlan:plan
                                                    suffixes:@[ a ]
                                                       error:&error];
        assert(base && [original commitUpdate:base error:&error]);
        plan = [original planInputs:@[ input(2) ]
                preservingLastArray:NO
                              error:&error];
        NV2AMetalPendingProgress *cursor =
            [original beginProgressForPlan:plan error:&error];
        NV2AMetalPendingJournal *staged = [original copyForTransaction];
        assert(staged && staged != original &&
               staged.generation == original.generation);
        assert(staged.retainedStreams[0][0] == a);
        assert(![staged beginProgressForPlan:plan error:&error]);
        assert(![staged commitNextSuffix:nil progress:cursor error:&error]);
        NV2AMetalPendingPlan *grown = [staged planInputs:@[ input(3) ]
                                     preservingLastArray:NO
                                                   error:&error];
        NV2AMetalPendingSpan *b = [NV2AMetalPendingSpan resource:@"unsubmitted"
                                                           first:0
                                                           count:1];
        NV2AMetalPendingUpdate *update = [staged preparePlan:grown
                                                    suffixes:@[ b ]
                                                       error:&error];
        assert(update && [staged commitUpdate:update error:&error]);
        assert(staged.retainedStreams[0].count == 2 &&
               original.retainedStreams[0].count == 1);
        assert(original.retainedInputs[0].count == 2 &&
               staged.retainedInputs[0].count == 3);
        assert(![staged planInputs:@[ input(9) ]
               preservingLastArray:NO
                             error:&error]);
        /* Dropping an aborted transaction preserves the original cursor. */
        staged = nil;
        assert([original commitNextSuffix:nil progress:cursor error:&error]);
        staged = [original copyForTransaction];
        [original reset];
        assert(staged.retainedStreams[0][0] == a &&
               staged.retainedInputs[0].count == 2);
    }
    puts("Pending host transactions:four input kinds, shared immutable "
         "resource owners, "
         "independent suffix/abort/reset, original cursor retained, foreign "
         "plans/progress "
         "rejected and copied limits PASS (CPU only)");
}
int main(void)
{
    @autoreleasepool {
        for (unsigned kind = 1; kind <= 4; kind++) {
            @autoreleasepool {
                NV2AMetalPendingJournal *j =
                    [[NV2AMetalPendingJournal alloc] initWithLimit:128];
                assert(j);
                NSMutableArray *expected = [NSMutableArray new];
                NV2AMetalPendingUpdate *update = nil;
                uint32_t indexed[32];
                for (unsigned i = 0; i < 32; i++)
                    indexed[i] = 100 + (31 - i) % 7;
                for (unsigned count = 1; count <= 32; count++) {
                    NV2AMetalPendingInput *input =
                        kind == 1 ? array(100, count) :
                        kind == 2 ? indices(indexed, count) :
                                    [NV2AMetalPendingInput inlineKind:kind
                                                                count:count];
                    assert(input);
                    update = step(j, @[ input ], @[ expected ], count, 0, NO);
                    NSError *error = nil;
                    NV2AMetalPendingPlan *same = [j planInputs:@[ input ]
                                           preservingLastArray:NO
                                                         error:&error];
                    assert(same &&
                           same.prefixCounts[0].unsignedIntegerValue == count &&
                           !error);
                    error = nil;
                    assert(![j preparePlan:same
                                  suffixes:@[ tags(99, 0, 0, 1) ]
                                     error:&error] &&
                           error);
                    rejections++;
                }
                NSError *error = nil;
                assert([j consumeUpdate:update error:&error] && !error &&
                       !j.streamCount);
                error = nil;
                assert(![j consumeUpdate:update error:&error] && error);
                rejections++;
            }
        }
        /* A partial flush must keep the hidden last DrawArrays range. */
        NV2AMetalPendingJournal *j =
            [[NV2AMetalPendingJournal alloc] initWithLimit:128];
        NSMutableArray *a = [NSMutableArray new], *b = [NSMutableArray new],
                       *c = [NSMutableArray new];
        step(j, @[ array(100, 3), array(300, 5), array(500, 7) ], @[ a, b, c ],
             1, 0, NO);
        step(j, @[ array(100, 4), array(300, 6), array(500, 8) ], @[ a, b, c ],
             2, 0, NO);
        reject_plan(j, @[ array(100, 4), array(300, 6) ], NO);
        reject_plan(j, @[ array(100, 4) ], YES);
        reject_plan(j, @[], YES);
        NV2AMetalPendingUpdate *partial =
            step(j, @[ array(100, 4), array(300, 6) ], @[ a, b ], 3, 0, YES);
        NSError *error = nil;
        assert([j consumeUpdate:partial error:&error] && !error &&
               j.streamCount == 1);
        uint32_t words[] = { 500, 501, 502, 503, 504, 505, 506,
                             507, 600, 599, 600, 0,   101 };
        uint32_t broken[13];
        memcpy(broken, words, sizeof(words));
        broken[3] = 77;
        reject_plan(j, @[ indices(broken, 11) ], NO);
        step(j, @[ indices(words, 11) ], @[ c ], 4, 2, NO);
        NV2AMetalPendingUpdate *indexed =
            step(j, @[ indices(words, 13) ], @[ c ], 5, 2, NO);
        reject_plan(j, @[ array(500, 13) ], NO);
        reject_plan(j, @[ indices(words, 12) ], NO);
        error = nil;
        assert([j consumeUpdate:indexed error:&error] && !error &&
               !j.streamCount);
        /* Atomic preparation and stale-plan/update validation. */
        j = [[NV2AMetalPendingJournal alloc] initWithLimit:16];
        NSArray *input = @[ array(10, 3), array(30, 4) ];
        error = nil;
        NV2AMetalPendingPlan *p = [j planInputs:input
                            preservingLastArray:NO
                                          error:&error];
        assert(p && !error);
        NSUInteger generation = j.generation;
        error = nil;
        assert((![j preparePlan:p
                       suffixes:@[ tags(1, 0, 0, 3), tags(1, 1, 0, 3) ]
                          error:&error] &&
                error));
        rejections++;
        assert(!j.streamCount && j.generation == generation);
        error = nil;
        NV2AMetalPendingUpdate *u =
            [j preparePlan:p
                  suffixes:@[ tags(1, 0, 0, 3), tags(1, 1, 0, 4) ]
                     error:&error];
        assert(u && !error);
        error = nil;
        NV2AMetalPendingUpdate *stale =
            [j preparePlan:p
                  suffixes:@[ tags(2, 0, 0, 3), tags(2, 1, 0, 4) ]
                     error:&error];
        assert(stale && !error);
        NV2AMetalPendingJournal *other =
            [[NV2AMetalPendingJournal alloc] initWithLimit:16];
        error = nil;
        assert(![other commitUpdate:u error:&error] && error);
        rejections++;
        error = nil;
        assert(![other preparePlan:p suffixes:@[] error:&error] && error);
        rejections++;
        error = nil;
        assert([j commitUpdate:u error:&error] && !error);
        commits++;
        error = nil;
        assert(![j commitUpdate:stale error:&error] && error);
        rejections++;
        error = nil;
        assert(![j preparePlan:p suffixes:@[] error:&error] && error);
        rejections++;
        reject_plan(j, @[ array(11, 3), array(30, 4) ], NO);
        reject_plan(j, @[ array(10, 2), array(30, 4) ], NO);
        reject_plan(j, @[ array(10, 3), array(30, 14) ], NO);
        [j reset];
        assert(!j.streamCount);
        error = nil;
        assert(![j consumeUpdate:u error:&error] && error);
        rejections++;
        /* A retained last array also counts toward the total limit. */
        a = [NSMutableArray new];
        b = [NSMutableArray new];
        c = [NSMutableArray new];
        step(j, @[ array(10, 4), array(30, 5), array(50, 6) ], @[ a, b, c ], 1,
             0, NO);
        reject_plan(j, @[ array(10, 5), array(30, 6) ], YES);
        [j reset];
        /* Indices are immutable copies; caller changes cannot rewrite identity.
         */
        uint32_t original[] = { 7, 1, 7 };
        NSMutableData *mutable = [NSMutableData dataWithBytes:original
                                                       length:sizeof(original)];
        NV2AMetalPendingInput *frozen = [NV2AMetalPendingInput indexed:mutable];
        memset(mutable.mutableBytes, 0, mutable.length);
        a = [NSMutableArray new];
        step(j, @[ frozen ], @[ a ], 1, 0, NO);
        error = nil;
        assert([j planInputs:@[ indices(original, 3) ]
                   preservingLastArray:NO
                                 error:&error] &&
               !error);
        reject_plan(j, @[ [NV2AMetalPendingInput indexed:mutable] ], NO);
        [j reset];
        /* Plans keep resource owners live through reset until their own
         * release. */
        __weak id weak = nil;
        @autoreleasepool {
            id resource = [NSObject new];
            weak = resource;
            error = nil;
            NV2AMetalPendingPlan *plan = [j planInputs:@[ array(0, 1) ]
                                   preservingLastArray:NO
                                                 error:&error];
            assert(plan);
            NV2AMetalPendingSpan *span = [NV2AMetalPendingSpan resource:resource
                                                                  first:0
                                                                  count:1];
            NV2AMetalPendingUpdate *update = [j preparePlan:plan
                                                   suffixes:@[ span ]
                                                      error:&error];
            assert(update);
            assert([j commitUpdate:update error:&error]);
            resource = nil;
            span = nil;
            assert(weak);
            [j reset];
            assert(weak);
            update = nil;
            plan = nil;
        }
        assert(!weak);
        assert(![NV2AMetalPendingInput arraysFrom:UINT32_MAX count:2]);
        assert(![NV2AMetalPendingInput inlineKind:NV2AMetalInputIndexed
                                            count:1]);
        assert(![NV2AMetalPendingSpan resource:NSNull.null
                                         first:NSUIntegerMax
                                         count:1]);
        printf("Pending journal CPU: %u exact retained IDs, %u atomic commits, "
               "%u rejected transitions PASS; four input kinds, independent "
               "ranges and hidden-last expansion, ownership, no Metal "
               "device/queue/dispatch\n",
               checks, commits, rejections);
        incremental_publication();
        pending_progress_contracts();
        pending_progress_benchmark();
        index_snapshot_reuse();
        transaction_copy_tests();
    }
    return 0;
}
