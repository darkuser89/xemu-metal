/* CPU-only immutable inline descriptor/plan reuse.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_INLINE_INPUT_REUSE_H
#define TEST_METAL_INLINE_INPUT_REUSE_H
#import <objc/runtime.h>
static _Thread_local BOOL ir_observe;
static _Thread_local unsigned ir_inputs, ir_plans;
@interface NV2AMetalPendingInput (InlineReuseCounter)
- (instancetype)ir_initKind:(NV2AMetalInputKind)kind
                      first:(NSUInteger)first
                      count:(NSUInteger)count
                    indices:(NSData *)indices
             verifiedPrefix:(NV2AMetalPendingInput *)prefix
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalPendingInput (InlineReuseCounter)
- (instancetype)ir_initKind:(NV2AMetalInputKind)kind
                      first:(NSUInteger)first
                      count:(NSUInteger)count
                    indices:(NSData *)indices
             verifiedPrefix:(NV2AMetalPendingInput *)prefix
{
    if (ir_observe)
        ir_inputs++;
    return [self ir_initKind:kind
                       first:first
                       count:count
                     indices:indices
              verifiedPrefix:prefix];
}
@end
@interface NV2AMetalPendingPlan (InlineReuseCounter)
- (instancetype)ir_initInputs:(NSArray *)inputs
                     prefixes:(NSArray *)prefixes
                     previous:(NSArray *)previous
                        owner:(NV2AMetalPendingJournal *)owner
                      version:(NSUInteger)version
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalPendingPlan (InlineReuseCounter)
- (instancetype)ir_initInputs:(NSArray *)inputs
                     prefixes:(NSArray *)prefixes
                     previous:(NSArray *)previous
                        owner:(NV2AMetalPendingJournal *)owner
                      version:(NSUInteger)version
{
    if (ir_observe)
        ir_plans++;
    return [self ir_initInputs:inputs
                      prefixes:prefixes
                      previous:previous
                         owner:owner
                       version:version];
}
@end
@interface InlineReuseSubclass : NV2AMetalPendingInput
@end
@implementation InlineReuseSubclass
@end
static NSArray *ir_read(PGRAPHState *pg, NSArray *previous, BOOL valid)
{
    NSError *error = nil;
    NSArray *result = [NV2AMetalPGRAPHPendingInputs inputsWithState:pg
                                                      reusingInputs:previous
                                                              error:&error];
    assert(valid ? result != nil && !error : result == nil && error != nil);
    return result;
}
static void ir_layout(PGRAPHState *pg, NV2AMetalInputKind kind)
{
    memset(pg, 0, sizeof(*pg));
    if (kind == NV2AMetalInputInlineBuffer)
        pg->inline_buffer_length = 3;
    else {
        pg->inline_array_length = 12;
        pg->vertex_attributes[0].format =
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        pg->vertex_attributes[0].size = 4;
        pg->vertex_attributes[0].count = 4;
    }
}
static void inline_input_reuse_tests(void)
{
    Method originals[] = {
        class_getInstanceMethod(
            NV2AMetalPendingInput.class,
            sel_registerName("initKind:first:count:indices:verifiedPrefix:")),
        class_getInstanceMethod(
            NV2AMetalPendingPlan.class,
            sel_registerName("initInputs:prefixes:previous:owner:version:")),
    };
    Method counters[] = {
        class_getInstanceMethod(
            NV2AMetalPendingInput.class,
            @selector(ir_initKind:first:count:indices:verifiedPrefix:)),
        class_getInstanceMethod(
            NV2AMetalPendingPlan.class,
            @selector(ir_initInputs:prefixes:previous:owner:version:)),
    };
    for (unsigned i = 0; i < 2; i++) {
        assert(originals[i] && counters[i]);
        method_exchangeImplementations(originals[i], counters[i]);
    }
    PGRAPHState *pg = calloc(1, sizeof(*pg));
    assert(pg);
    @try {
        ir_observe = YES;
        for (NV2AMetalInputKind kind = NV2AMetalInputInlineBuffer;
             kind <= NV2AMetalInputInlineArray; kind++) {
            ir_layout(pg, kind);
            ir_inputs = ir_plans = 0;
            NSArray *initial = ir_read(pg, nil, YES);
            assert(ir_inputs == 1 && initial.count == 1);
            NV2AMetalPendingInput *input = initial[0];
            NV2AMetalPendingJournal *journal =
                [[NV2AMetalPendingJournal alloc] initWithLimit:32];
            NSError *error = nil;
            NV2AMetalPendingPlan *plan = [journal planInputs:initial
                                         preservingLastArray:YES
                                                       error:&error];
            NV2AMetalPendingSpan *span =
                [NV2AMetalPendingSpan resource:@"immutable completed vertices"
                                         first:0
                                         count:3];
            NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                         suffixes:@[ span ]
                                                            error:&error];
            assert(update && [journal commitUpdate:update error:&error] &&
                   !error);
            NV2AMetalPendingJournal *reference = [journal copyForTransaction];
            ir_inputs = ir_plans = 0;
            NSArray *warm = ir_read(pg, journal.retainedInputs, YES);
            plan = [journal planInputs:warm
                   preservingLastArray:YES
                                 error:&error];
            assert(plan && ir_inputs == 0 && ir_plans == 1 &&
                   warm[0] == input &&
                   plan.prefixCounts[0].unsignedIntegerValue == 3);
            NSUInteger generation = journal.generation;
            for (unsigned repeat = 0; repeat < 32; repeat++) {
                ir_inputs = ir_plans = 0;
                NSArray *same = ir_read(pg, journal.retainedInputs, YES);
                NV2AMetalPendingPlan *hit = [journal planInputs:same
                                            preservingLastArray:YES
                                                          error:&error];
                assert(hit == plan && !ir_inputs && !ir_plans && !error);
                // Exactly the old capture route: force a fresh descriptor.
                NSArray *fresh = ir_read(pg, nil, YES);
                NV2AMetalPendingPlan *old = [reference planInputs:fresh
                                              preservingLastArray:YES
                                                            error:&error];
                assert(old && ir_inputs == 1 && ir_plans == 1 &&
                       [old.prefixCounts isEqualToArray:hit.prefixCounts] &&
                       fresh[0] != input && journal.generation == generation);
            }
            /* Descriptors contain only kind/count. Mutable payload remains
             * live guest state and is neither frozen nor copied on a hit. */
            pg->inline_array[0] = 0x12345678;
            assert(ir_read(pg, warm, YES)[0] == input &&
                   pg->inline_array[0] == 0x12345678 && !input.indices.length);
            NSMutableArray *mutable = [warm mutableCopy];
            NSArray *frozen = ir_read(pg, mutable, YES);
            assert(frozen != mutable && frozen[0] == input);
            [mutable removeAllObjects];
            assert(frozen.count == 1 && frozen[0] == input);
            NSArray *subclass = @[ [InlineReuseSubclass inlineKind:kind
                                                             count:3] ];
            ir_inputs = 0;
            NSArray *base = ir_read(pg, subclass, YES);
            assert(ir_inputs == 1 && base[0] != subclass[0] &&
                   object_getClass(base[0]) == NV2AMetalPendingInput.class);
            ir_inputs = 0;
            assert(ir_read(pg, @[], YES)[0] != input && ir_inputs == 1);
            assert(ir_read(pg, @[ input, input ], YES)[0] != input);
            NV2AMetalInputKind other = kind == NV2AMetalInputInlineArray ?
                                           NV2AMetalInputInlineBuffer :
                                           NV2AMetalInputInlineArray;
            assert(ir_read(pg, @[ [NV2AMetalPendingInput inlineKind:other
                                                              count:3] ],
                           YES)[0] != input);
            if (kind == NV2AMetalInputInlineBuffer)
                pg->inline_buffer_length = 4;
            else
                pg->inline_array_length = 16;
            NSArray *grown = ir_read(pg, warm, YES);
            assert(grown[0] != input &&
                   ((NV2AMetalPendingInput *)grown[0]).count == 4 &&
                   input.count == 3);
            NV2AMetalPendingPlan *growth = [journal planInputs:grown
                                           preservingLastArray:YES
                                                         error:&error];
            assert(growth && growth.prefixCounts[0].unsignedIntegerValue == 3);
            ir_layout(pg, kind);
            [journal reset];
            ir_plans = 0;
            NV2AMetalPendingPlan *reset =
                [journal planInputs:ir_read(pg, warm, YES)
                    preservingLastArray:YES
                                  error:&error];
            assert(reset && ir_plans == 1 &&
                   !reset.prefixCounts[0].unsignedIntegerValue);
            assert([reference.retainedStreams[0] firstObject] == span);
        }
        ir_layout(pg, NV2AMetalInputInlineArray);
        NSArray *previous = ir_read(pg, nil, YES);
        for (unsigned invalid = 0; invalid < 6; invalid++) {
            ir_layout(pg, NV2AMetalInputInlineArray);
            if (invalid == 0)
                pg->vertex_attributes[0].size = 0;
            if (invalid == 1)
                pg->vertex_attributes[0].size = 3;
            if (invalid == 2)
                pg->vertex_attributes[0].format = 99;
            if (invalid == 3)
                pg->vertex_attributes[0].count = 0;
            if (invalid == 4)
                pg->inline_array_length = 1;
            if (invalid == 5)
                pg->inline_buffer_length = 3;
            ir_inputs = 0;
            ir_read(pg, previous, NO);
            assert(!ir_inputs);
        }
        ir_layout(pg, NV2AMetalInputInlineArray);
        pg->vertex_attributes[0].count = 3;
        pg->inline_array_length = 9; // New valid stride, same descriptor count.
        assert(ir_read(pg, previous, YES)[0] == previous[0]);
        pg->inline_array_length =
            10; // An incomplete trailing word adds no vertex.
        assert(ir_read(pg, previous, YES)[0] == previous[0]);
        pg->inline_array_length = NV2A_MAX_BATCH_LENGTH + 1;
        ir_read(pg, previous, NO);
        ir_layout(pg, NV2AMetalInputInlineBuffer);
        previous = ir_read(pg, nil, YES);
        pg->inline_buffer_length = NV2A_MAX_BATCH_LENGTH + 1;
        ir_read(pg, previous, NO);
        memset(pg, 0, sizeof(*pg));
        assert(ir_read(pg, previous, YES).count == 0);
        ir_read(NULL, previous, NO);
    } @finally {
        ir_observe = NO;
        free(pg);
        for (unsigned i = 0; i < 2; i++)
            method_exchangeImplementations(originals[i], counters[i]);
    }
    puts("Inline input reuse: 64 warm descriptor/plan hits versus 64 exact "
         "fresh "
         "constructions; mutable containers, subclasses, layout/count/kind, "
         "growth/reset/clone and live payload isolation PASS (CPU only)");
}
#endif
