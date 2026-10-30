/* Incremental publication versus the full-prefix journal path.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_PENDING_PROGRESS_H
#define TEST_METAL_PENDING_PROGRESS_H
#include <time.h>

@interface ProgressJournal : NV2AMetalPendingJournal
@property(nonatomic) NSUInteger plans, inputVisits, prefixVisits;
@end
@implementation ProgressJournal
- (NV2AMetalPendingPlan *)planInputs:(NSArray *)inputs
                 preservingLastArray:(BOOL)preserve
                               error:(NSError **)error
{
    self.plans++;
    self.inputVisits += inputs.count;
    return [super planInputs:inputs preservingLastArray:preserve error:error];
}
- (NV2AMetalPendingUpdate *)preparePlan:(NV2AMetalPendingPlan *)plan
                        completedInputs:(NSUInteger)count
                               suffixes:(NSArray *)suffixes
                                  error:(NSError **)error
{
    self.prefixVisits += count;
    return [super preparePlan:plan
              completedInputs:count
                     suffixes:suffixes
                        error:error];
}
@end
static void progress_reference(NV2AMetalPendingJournal *journal,
                               NSArray *inputs, NSUInteger index,
                               NV2AMetalPendingSpan *span)
{
    if (!span)
        return;
    NSError *error = nil;
    NV2AMetalPendingPlan *plan = [journal planInputs:inputs
                                 preservingLastArray:YES
                                               error:&error];
    NSMutableArray *suffixes = [NSMutableArray new];
    for (NSUInteger i = 0; i < index; i++)
        [suffixes addObject:NSNull.null];
    [suffixes addObject:span];
    NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                          completedInputs:index + 1
                                                 suffixes:suffixes
                                                    error:&error];
    assert(update && [journal commitUpdate:update error:&error] && !error);
}
static void progress_equal(NV2AMetalPendingJournal *a,
                           NV2AMetalPendingJournal *b)
{
    assert([a.retainedInputs isEqual:b.retainedInputs]);
    assert([a.retainedStreams isEqual:b.retainedStreams]);
    assert(a.generation == b.generation);
}
static NV2AMetalPendingProgress *progress_begin(NV2AMetalPendingJournal *j,
                                                NSArray *inputs)
{
    NSError *error = nil;
    NV2AMetalPendingPlan *plan = [j planInputs:inputs
                           preservingLastArray:YES
                                         error:&error];
    NV2AMetalPendingProgress *cursor = [j beginProgressForPlan:plan
                                                         error:&error];
    assert(cursor && !error);
    return cursor;
}
static void progress_publish(NV2AMetalPendingJournal *j,
                             NV2AMetalPendingProgress *cursor,
                             NV2AMetalPendingSpan *span)
{
    NSError *error = nil;
    assert([j commitNextSuffix:span progress:cursor error:&error] && !error);
}
static void pending_progress_contracts(void)
{
    unsigned comparisons = 0, failures = 0;
    for (unsigned kind = 1; kind <= 4; kind++)
        for (unsigned size = 1; size <= 32; size *= 2) {
            @autoreleasepool {
                NV2AMetalPendingJournal *j =
                    [[NV2AMetalPendingJournal alloc] initWithLimit:512];
                NV2AMetalPendingJournal *ref =
                    [[NV2AMetalPendingJournal alloc] initWithLimit:512];
                for (unsigned epoch = 1; epoch <= 3; epoch++) {
                    NSMutableArray *inputs = [NSMutableArray new];
                    for (unsigned i = 0; i < size; i++)
                        [inputs addObject:progress_input(kind, i, epoch)];
                    NV2AMetalPendingProgress *cursor =
                        progress_begin(j, inputs);
                    NSArray *oldInputs = j.retainedInputs,
                            *oldStreams = j.retainedStreams;
                    NSArray *inputCopy = [oldInputs copy],
                            *streamCopy = [oldStreams copy];
                    id inputStorage = [j valueForKey:@"inputs"];
                    id streamStorage = [j valueForKey:@"streams"];
                    for (unsigned i = 0; i < size; i++) {
                        id oldReferenceInputs = [ref valueForKey:@"inputs"];
                        id oldReferenceStreams = [ref valueForKey:@"streams"];
                        assert(cursor.nextInput == i);
                        NSUInteger version = j.generation;
                        NSError *error = nil;
                        assert(![j commitNextSuffix:tags(epoch, i, epoch - 1, 2)
                                           progress:cursor
                                              error:&error] &&
                               error);
                        assert(cursor.nextInput == i &&
                               j.generation == version);
                        failures++;
                        /* A failed early/middle/late range retries from the
                         * immutable journal prefix, never replaying it. */
                        if (i == 0 || i == size / 2 || i + 1 == size) {
                            cursor = progress_begin(j, inputs);
                            for (unsigned prior = 0; prior < i; prior++)
                                progress_publish(j, cursor, nil);
                            assert(cursor.nextInput == i);
                        }
                        NV2AMetalPendingSpan *span =
                            tags(epoch, i, epoch - 1, 1);
                        progress_publish(j, cursor, span);
                        progress_reference(ref, inputs, i, span);
                        progress_equal(j, ref);
                        assert([j valueForKey:@"inputs"] == inputStorage &&
                               [j valueForKey:@"streams"] == streamStorage);
                        assert([ref valueForKey:@"inputs"] !=
                                   oldReferenceInputs &&
                               [ref valueForKey:@"streams"] !=
                                   oldReferenceStreams);
                        assert([oldInputs isEqual:inputCopy] &&
                               [oldStreams isEqual:streamCopy]);
                        /* The snapshots contain immutable inner arrays too. */
                        if (oldStreams.count)
                            assert(((NSArray *)oldStreams[0]).count ==
                                   epoch - 1);
                        comparisons++;
                    }
                    NSError *error = nil;
                    assert(![j commitNextSuffix:nil
                                       progress:cursor
                                          error:&error] &&
                           error);
                    failures++;
                    NV2AMetalPendingProgress *empty = progress_begin(j, inputs);
                    NSUInteger version = j.generation;
                    for (unsigned i = 0; i < size; i++)
                        progress_publish(j, empty, nil);
                    assert(j.generation == version);
                }
            }
        }
    /* Hidden last array, earlier extension, and arrays-to-indexed prefix. */
    NV2AMetalPendingJournal *j =
        [[NV2AMetalPendingJournal alloc] initWithLimit:32];
    NV2AMetalPendingJournal *ref =
        [[NV2AMetalPendingJournal alloc] initWithLimit:32];
    NSArray *inputs = @[ array(10, 2), array(20, 2), array(30, 2) ];
    NV2AMetalPendingProgress *cursor = progress_begin(j, inputs);
    for (unsigned i = 0; i < 3; i++) {
        NV2AMetalPendingSpan *span = tags(1, i, 0, 2);
        progress_publish(j, cursor, span);
        progress_reference(ref, inputs, i, span);
    }
    inputs = @[ inputs[0], array(20, 3) ];
    cursor = progress_begin(j, inputs);
    progress_publish(j, cursor, nil);
    NV2AMetalPendingSpan *span = tags(2, 1, 2, 1);
    progress_publish(j, cursor, span);
    progress_reference(ref, inputs, 1, span);
    progress_equal(j, ref);
    comparisons++;
    for (NV2AMetalPendingJournal *journal in @[ j, ref ]) {
        NSError *error = nil;
        NV2AMetalPendingPlan *plan = [journal planInputs:inputs
                                     preservingLastArray:YES
                                                   error:&error];
        NV2AMetalPendingUpdate *update =
            [journal preparePlan:plan
                        suffixes:@[ NSNull.null, NSNull.null ]
                           error:&error];
        assert(update && [journal commitUpdate:update error:&error]);
        assert([journal consumeUpdate:update error:&error] && !error);
    }
    uint32_t words[] = { 30, 31, 7 };
    inputs = @[ indices(words, 3) ];
    cursor = progress_begin(j, inputs);
    span = tags(3, 2, 2, 1);
    progress_publish(j, cursor, span);
    progress_reference(ref, inputs, 0, span);
    progress_equal(j, ref);
    comparisons++;
    NSError *error = nil;
    cursor = progress_begin(j, inputs);
    assert(![ref commitNextSuffix:nil progress:cursor error:&error] && error);
    failures++;
    NV2AMetalPendingProgress *other = progress_begin(j, inputs);
    [j reset];
    error = nil;
    assert(![j commitNextSuffix:nil progress:cursor error:&error] && error);
    failures++;
    error = nil;
    assert(![j commitNextSuffix:nil progress:other error:&error] && error);
    failures++;
    inputs = @[ array(0, 1) ];
    cursor = progress_begin(j, inputs);
    other = progress_begin(j, inputs);
    progress_publish(j, other, tags(1, 0, 0, 1));
    error = nil;
    assert(![j commitNextSuffix:tags(2, 0, 0, 1)
                       progress:cursor
                          error:&error] &&
           error);
    failures++;
    /* A cursor must also reject legacy publication and exhausted generations.
     */
    cursor = progress_begin(j, inputs);
    NV2AMetalPendingPlan *plan = [j planInputs:inputs
                           preservingLastArray:NO
                                         error:NULL];
    NV2AMetalPendingUpdate *update = [j preparePlan:plan
                                           suffixes:@[ NSNull.null ]
                                              error:NULL];
    assert([j commitUpdate:update error:NULL]);
    error = nil;
    assert(![j commitNextSuffix:nil progress:cursor error:&error] && error);
    failures++;
    [j setValue:@(NSUIntegerMax - 1) forKey:@"generation"];
    plan = [j planInputs:inputs preservingLastArray:NO error:NULL];
    error = nil;
    assert(![j beginProgressForPlan:plan error:&error] && error);
    failures++;
    printf("Pending cursor: %u exact prefix comparisons, %u rejected "
           "faults/stale/owner/exhaustion; four input kinds, zero "
           "outer-storage replacements, immutable snapshots, "
           "hidden last, array-index conversion and prefix retry PASS\n",
           comparisons, failures);
}
static double progress_time(void)
{
    struct timespec t;
    assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static int progress_order(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void pending_progress_benchmark(void)
{
    for (unsigned n = 1; n <= 1024; n *= 4) {
        NSMutableArray *inputs = [NSMutableArray new],
                       *spans = [NSMutableArray new];
        for (unsigned i = 0; i < n; i++) {
            [inputs addObject:array(i * 4, 3)];
            [spans addObject:tags(1, i, 0, 3)];
        }
        double samples[2][7];
        for (unsigned trial = 0; trial < 9; trial++) {
            @autoreleasepool {
                ProgressJournal *journals[2];
                for (unsigned order = 0; order < 2; order++) {
                    unsigned mode = order ^ (trial & 1);
                    ProgressJournal *journal =
                        [[ProgressJournal alloc] initWithLimit:n * 3];
                    journals[mode] = journal;
                    double start = progress_time();
                    if (!mode) {
                        NV2AMetalPendingProgress *cursor =
                            progress_begin(journal, inputs);
                        for (unsigned i = 0; i < n; i++)
                            progress_publish(journal, cursor, spans[i]);
                    } else {
                        for (unsigned i = 0; i < n; i++)
                            progress_reference(journal, inputs, i, spans[i]);
                    }
                    double ms = (progress_time() - start) * 1000;
                    if (trial >= 2)
                        samples[mode][trial - 2] = ms;
                    assert(journal.plans == (mode ? n : 1));
                    assert(journal.inputVisits == (mode ? n * n : n));
                    assert(journal.prefixVisits ==
                           (mode ? n * (n + 1) / 2 : 0));
                }
                progress_equal(journals[0], journals[1]);
            }
        }
        qsort(samples[0], 7, sizeof(double), progress_order);
        qsort(samples[1], 7, sizeof(double), progress_order);
        printf("Pending CPU %u ranges: plans 1/%u, input visits %u/%u, prefix "
               "visits 0/%u; median incremental/legacy %.6f/%.6f ms (2 "
               "warmups,7 alternating paired trials,exact owners)\n",
               n, n, n, n * n, n * (n + 1) / 2, samples[0][3], samples[1][3]);
    }
}
#endif
