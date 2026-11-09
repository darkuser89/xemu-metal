/* PGRAPH fetch checkpoint. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "input-checkpoint.h"
static BOOL checkpoint_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.input-checkpoint"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@implementation NV2AMetalPGRAPHInputCheckpoint {
    PGRAPHState *_origin;
    VertexAttribute _attributes[16];
    uint16_t _compressed;
    unsigned _lengths[4];
    NSData *_ranges;
    BOOL _restored;
}
- (instancetype)initWithState:(PGRAPHState *)state error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!state ||
        state->draw_arrays_length > ARRAY_SIZE(state->draw_arrays_start) ||
        state->inline_elements_length > NV2A_MAX_BATCH_LENGTH ||
        state->inline_buffer_length > NV2A_MAX_BATCH_LENGTH ||
        state->inline_array_length > NV2A_MAX_BATCH_LENGTH) {
        checkpoint_error(error, @"Invalid input checkpoint lengths");
        return nil;
    }
    unsigned kinds =
        !!state->draw_arrays_length + !!state->inline_elements_length +
        !!state->inline_buffer_length + !!state->inline_array_length;
    if (kinds > 1) {
        checkpoint_error(error, @"Conflicting checkpoint input kinds");
        return nil;
    }
    for (unsigned a = 0; a < 16; a++)
        if (state->inline_buffer_length &&
            state->vertex_attributes[a].inline_buffer_populated &&
            !state->vertex_attributes[a].inline_buffer) {
            checkpoint_error(error, @"Missing populated checkpoint buffer");
            return nil;
        }
    _origin = state;
    memcpy(_attributes, state->vertex_attributes, sizeof(_attributes));
    _compressed = state->compressed_attrs;
    _lengths[0] = state->draw_arrays_length;
    _lengths[1] = state->inline_elements_length;
    _lengths[2] = state->inline_buffer_length;
    _lengths[3] = state->inline_array_length;
    if (_lengths[0]) {
        size_t bytes = _lengths[0] * sizeof(state->draw_arrays_start[0]);
        NSMutableData *ranges = [NSMutableData dataWithLength:bytes * 2];
        memcpy(ranges.mutableBytes, state->draw_arrays_start, bytes);
        memcpy((uint8_t *)ranges.mutableBytes + bytes, state->draw_arrays_count,
               bytes);
        /* Private backing is never mutated after this snapshot. */
        _ranges = ranges;
    }
    return self;
}
- (BOOL)restoreWithState:(PGRAPHState *)state error:(NSError **)error
{
    if (_restored || !state || state != _origin ||
        state->draw_arrays_length != _lengths[0] ||
        state->inline_elements_length != _lengths[1] ||
        state->inline_buffer_length != _lengths[2] ||
        state->inline_array_length != _lengths[3])
        return checkpoint_error(error,
                                @"Stale input checkpoint owner or lengths");
    size_t bytes = _lengths[0] * sizeof(state->draw_arrays_start[0]);
    if (bytes && (memcmp(state->draw_arrays_start, _ranges.bytes, bytes) ||
                  memcmp(state->draw_arrays_count,
                         (const uint8_t *)_ranges.bytes + bytes, bytes)))
        return checkpoint_error(error, @"Stale checkpoint DrawArrays ranges");
    for (unsigned a = 0; a < 16; a++) {
        const uint8_t *current = (const uint8_t *)&state->vertex_attributes[a],
                      *original = (const uint8_t *)&_attributes[a];
        const size_t values = offsetof(VertexAttribute, inline_value),
                     valuesEnd = values + sizeof(_attributes[a].inline_value),
                     populated = offsetof(VertexAttribute, inline_buffer_populated),
                     populatedEnd = populated +
                                    sizeof(_attributes[a].inline_buffer_populated);
        _Static_assert(offsetof(VertexAttribute, inline_value) +
                           sizeof(((VertexAttribute *)0)->inline_value) <=
                           offsetof(VertexAttribute, inline_buffer_populated),
                       "Checkpoint attribute ranges must stay ordered");
        /* Compare every other byte, including padding, without copying and
         * clearing two temporary attributes. Validation precedes all writes. */
        if (memcmp(current, original, values) ||
            memcmp(current + valuesEnd, original + valuesEnd,
                   populated - valuesEnd) ||
            memcmp(current + populatedEnd, original + populatedEnd,
                   sizeof(_attributes[a]) - populatedEnd))
            return checkpoint_error(error, @"Stale checkpoint vertex layout");
    }
    for (unsigned a = 0; a < 16; a++) {
        memcpy(state->vertex_attributes[a].inline_value,
               _attributes[a].inline_value,
               sizeof(_attributes[a].inline_value));
        state->vertex_attributes[a].inline_buffer_populated =
            _attributes[a].inline_buffer_populated;
    }
    state->compressed_attrs = _compressed;
    _restored = YES;
    return YES;
}
@end
