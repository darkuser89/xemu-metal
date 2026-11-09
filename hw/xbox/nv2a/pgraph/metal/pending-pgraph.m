/* PGRAPH batch descriptor. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "pending-pgraph.h"
#import "vertex-fetch.h"
#import <objc/runtime.h>
static NSArray *input_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pending-inputs"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return nil;
}
static NSArray *reuse_inline_input(NSArray *previous, NV2AMetalInputKind kind,
                                   NSUInteger count)
{
    if (previous.count != 1)
        return nil;
    NV2AMetalPendingInput *old = previous[0];
    if (object_getClass(old) != NV2AMetalPendingInput.class ||
        old.kind != kind || old.count != count)
        return nil;
    return [previous copy];
}
@implementation NV2AMetalPGRAPHPendingInputs
+ (NSArray<NV2AMetalPendingInput *> *)inputsWithState:(PGRAPHState *)pg
                                                error:(NSError **)error
{
    return [self inputsWithState:pg reusingInputs:nil error:error];
}
+ (NSArray<NV2AMetalPendingInput *> *)inputsWithState:(PGRAPHState *)pg
                                        reusingInputs:(NSArray *)previous
                                                error:(NSError **)error
{
    if (!pg || pg->draw_arrays_length > ARRAY_SIZE(pg->draw_arrays_start) ||
        pg->inline_elements_length > NV2A_MAX_BATCH_LENGTH ||
        pg->inline_buffer_length > NV2A_MAX_BATCH_LENGTH ||
        pg->inline_array_length > NV2A_MAX_BATCH_LENGTH)
        return input_error(error, @"Invalid pending PGRAPH input lengths");
    unsigned kinds = !!pg->draw_arrays_length + !!pg->inline_elements_length +
                     !!pg->inline_buffer_length + !!pg->inline_array_length;
    if (!kinds)
        return @[];
    if (kinds != 1)
        return input_error(error, @"Conflicting pending PGRAPH input kinds");
    if (pg->draw_arrays_length) {
        BOOL unchanged = previous.count == pg->draw_arrays_length;
        for (unsigned i = 0; unchanged && i < pg->draw_arrays_length; i++) {
            NV2AMetalPendingInput *old = previous[i];
            unchanged = [old isKindOfClass:NV2AMetalPendingInput.class] &&
                        old.kind == NV2AMetalInputArrays &&
                        pg->draw_arrays_start[i] >= 0 &&
                        pg->draw_arrays_count[i] > 0 &&
                        old.first == (NSUInteger)pg->draw_arrays_start[i] &&
                        old.count == (NSUInteger)pg->draw_arrays_count[i];
        }
        if (unchanged)
            return [previous copy];
        NSMutableArray *inputs = [NSMutableArray new];
        for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
            int32_t first = pg->draw_arrays_start[i],
                    count = pg->draw_arrays_count[i];
            if (first < 0 || count <= 0)
                return input_error(error, @"Invalid pending DrawArrays range");
            NV2AMetalPendingInput *input =
                [NV2AMetalPendingInput arraysFrom:(NSUInteger)first
                                            count:(NSUInteger)count];
            if (!input)
                return input_error(error, @"Pending DrawArrays range overflow");
            [inputs addObject:input];
        }
        return [inputs copy];
    }
    if (pg->inline_elements_length) {
        NV2AMetalPendingInput *input = [NV2AMetalPendingInput
            indexedBytes:pg->inline_elements
                   count:pg->inline_elements_length
        matchingPrevious:previous.count == 1 ? previous[0] : nil];
        if (previous.count == 1 && input == previous[0])
            return [previous copy];
        return @[ input ];
    }
    if (pg->inline_buffer_length) {
        NSArray *same = reuse_inline_input(previous, NV2AMetalInputInlineBuffer,
                                           pg->inline_buffer_length);
        if (same)
            return same;
        return @[ [NV2AMetalPendingInput inlineKind:NV2AMetalInputInlineBuffer
                                              count:pg->inline_buffer_length] ];
    }
    NSUInteger stride = 0;
    for (unsigned i = 0; i < 16; i++) {
        const VertexAttribute *a = &pg->vertex_attributes[i];
        if (!a->count)
            continue;
        unsigned element = nv2a_metal_attribute_size(a->format, a->count);
        if (!element || !a->size || a->size * a->count != element ||
            (a->size & (a->size - 1)))
            return input_error(error, @"Invalid pending packed inline layout");
        stride = (stride + a->size - 1) & ~(NSUInteger)(a->size - 1);
        stride += element;
        stride = (stride + a->size - 1) & ~(NSUInteger)(a->size - 1);
    }
    if (!stride)
        return input_error(error,
                           @"Pending packed stream has no enabled attributes");
    NSUInteger count = (NSUInteger)pg->inline_array_length * 4 / stride;
    if (!count)
        return input_error(error, @"Incomplete pending packed inline vertex");
    NSArray *same =
        reuse_inline_input(previous, NV2AMetalInputInlineArray, count);
    if (same)
        return same;
    return @[ [NV2AMetalPendingInput inlineKind:NV2AMetalInputInlineArray
                                          count:count] ];
}
@end
