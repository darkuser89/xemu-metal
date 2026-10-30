/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
/* CPU-only descriptors from actual PGRAPH inputs; no GPU initialization. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/pending-pgraph.h"
static unsigned captures, rejected;
static NSArray<NV2AMetalPendingInput *> *read_inputs(PGRAPHState *pg,
                                                     BOOL valid)
{
    PGRAPHState *before = malloc(sizeof(*before));
    assert(before);
    memcpy(before, pg, sizeof(*pg));
    NSError *error = nil;
    NSArray *inputs = [NV2AMetalPGRAPHPendingInputs inputsWithState:pg
                                                              error:&error];
    assert(!memcmp(pg, before, sizeof(*pg)));
    free(before);
    if (valid) {
        assert(inputs && !error);
        captures++;
    } else {
        assert(!inputs && error);
        rejected++;
    }
    return inputs;
}
int main(void)
{
    @autoreleasepool {
        PGRAPHState *pg = calloc(1, sizeof(*pg));
        assert(pg);
        assert(read_inputs(pg, YES).count == 0);
        for (unsigned ranges = 1; ranges <= 1250; ranges++) {
            pg->draw_arrays_length = ranges;
            for (unsigned i = 0; i < ranges; i++) {
                pg->draw_arrays_start[i] = (int32_t)(i % 2 ? 5000 - i : i * 3);
                pg->draw_arrays_count[i] = (int32_t)(1 + i % 256);
            }
            NSArray<NV2AMetalPendingInput *> *inputs = read_inputs(pg, YES);
            assert(inputs.count == ranges);
            for (unsigned i = 0; i < ranges; i++)
                assert(inputs[i].kind == NV2AMetalInputArrays &&
                       inputs[i].first ==
                           (NSUInteger)pg->draw_arrays_start[i] &&
                       inputs[i].count == (NSUInteger)pg->draw_arrays_count[i]);
        }
        memset(pg, 0, sizeof(*pg));
        NSArray<NV2AMetalPendingInput *> *previous = nil;
        NSUInteger minimum = UINT32_MAX, maximum = 0;
        for (unsigned count = 1; count <= 128; count++) {
            pg->inline_elements_length = count;
            pg->inline_elements[count - 1] = count % 2 ? 1000 - count : count;
            minimum = MIN(minimum, pg->inline_elements[count - 1]);
            maximum = MAX(maximum, pg->inline_elements[count - 1]);
            NSError *error = nil;
            NSArray<NV2AMetalPendingInput *> *next =
                [NV2AMetalPGRAPHPendingInputs inputsWithState:pg
                                                reusingInputs:previous
                                                        error:&error];
            assert(next && !error && next[0] != previous.firstObject &&
                   next[0].minimumIndex == minimum &&
                   next[0].maximumIndex == maximum);
            NSArray<NV2AMetalPendingInput *> *same =
                [NV2AMetalPGRAPHPendingInputs inputsWithState:pg
                                                reusingInputs:next
                                                        error:&error];
            assert(same && same[0] == next[0] && !error);
            previous = next;
        }
        NSError *reuseError = nil;
        pg->inline_elements[0] = UINT32_MAX;
        NSArray<NV2AMetalPendingInput *> *changed =
            [NV2AMetalPGRAPHPendingInputs inputsWithState:pg
                                            reusingInputs:previous
                                                    error:&reuseError];
        assert(changed && !reuseError && changed[0] != previous[0] &&
               changed[0].maximumIndex == UINT32_MAX &&
               previous[0].maximumIndex < UINT32_MAX);
        puts("PGRAPH index capture: 128 growing/repeated immutable snapshots "
             "and "
             "changed accepted prefix/full bounds PASS");
        memset(pg, 0, sizeof(*pg));
        for (unsigned count = 1; count <= 128; count++) {
            pg->inline_elements_length = count;
            for (unsigned i = 0; i < count; i++)
                pg->inline_elements[i] = (i * 37) % 23;
            NSArray<NV2AMetalPendingInput *> *inputs = read_inputs(pg, YES);
            assert(inputs.count == 1 &&
                   inputs[0].kind == NV2AMetalInputIndexed &&
                   inputs[0].count == count &&
                   inputs[0].indices.length == count * 4);
            assert(!memcmp(inputs[0].indices.bytes, pg->inline_elements,
                           count * 4));
            uint32_t original;
            memcpy(&original, inputs[0].indices.bytes, 4);
            pg->inline_elements[0]++;
            uint32_t frozen;
            memcpy(&frozen, inputs[0].indices.bytes, 4);
            assert(original == frozen);
        }
        memset(pg, 0, sizeof(*pg));
        for (unsigned count = 1; count <= 128; count++) {
            pg->inline_buffer_length = count;
            NSArray<NV2AMetalPendingInput *> *inputs = read_inputs(pg, YES);
            assert(inputs.count == 1 &&
                   inputs[0].kind == NV2AMetalInputInlineBuffer &&
                   inputs[0].count == count);
        }
        const unsigned formats[] = {
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP
        };
        const unsigned sizes[] = { 1, 1, 2, 2, 4, 4 };
        for (unsigned f = 0; f < 6; f++)
            for (unsigned components = 1; components <= 4; components++)
                for (unsigned words = 1; words <= 128; words++) {
                    memset(pg, 0, sizeof(*pg));
                    pg->inline_array_length = words;
                    pg->vertex_attributes[7].count = components;
                    pg->vertex_attributes[7].size = sizes[f];
                    pg->vertex_attributes[7].format = formats[f];
                    BOOL format_valid = (f != 0 || components == 4) &&
                                        (f != 5 || components == 1);
                    unsigned count = words * 4 / (sizes[f] * components);
                    NSArray<NV2AMetalPendingInput *> *inputs =
                        read_inputs(pg, format_valid && count);
                    if (inputs)
                        assert(inputs.count == 1 &&
                               inputs[0].kind == NV2AMetalInputInlineArray &&
                               inputs[0].count == count);
                }
        const unsigned mixed[][3] = { { 3, 1, 1 }, { 1, 3, 3 }, { 1, 1, 4 } };
        const unsigned strides[] = { 12, 20, 20 };
        for (unsigned m = 0; m < 3; m++)
            for (unsigned words = 1; words <= 128; words++) {
                memset(pg, 0, sizeof(*pg));
                pg->inline_array_length = words;
                for (unsigned a = 0; a < 3; a++) {
                    VertexAttribute *v = &pg->vertex_attributes[a * 5];
                    v->count = mixed[m][a];
                    v->format = formats[a == 0 ? 1 : a == 1 ? 2 : 4];
                    v->size = a == 0 ? 1 : a == 1 ? 2 : 4;
                }
                unsigned count = words * 4 / strides[m];
                NSArray<NV2AMetalPendingInput *> *inputs =
                    read_inputs(pg, count != 0);
                if (inputs)
                    assert(inputs[0].count == count);
            }
        for (unsigned a = 0; a < 4; a++)
            for (unsigned b = a + 1; b < 4; b++) {
                memset(pg, 0, sizeof(*pg));
                unsigned *lengths[] = { &pg->draw_arrays_length,
                                        &pg->inline_elements_length,
                                        &pg->inline_buffer_length,
                                        &pg->inline_array_length };
                *lengths[a] = *lengths[b] = 1;
                read_inputs(pg, NO);
            }
        for (unsigned fault = 0; fault < 9; fault++) {
            memset(pg, 0, sizeof(*pg));
            if (fault == 0)
                pg->draw_arrays_length = 1251;
            if (fault == 1)
                pg->inline_elements_length = NV2A_MAX_BATCH_LENGTH + 1;
            if (fault == 2)
                pg->inline_buffer_length = NV2A_MAX_BATCH_LENGTH + 1;
            if (fault == 3)
                pg->inline_array_length = NV2A_MAX_BATCH_LENGTH + 1;
            if (fault == 4) {
                pg->draw_arrays_length = 1;
                pg->draw_arrays_start[0] = -1;
                pg->draw_arrays_count[0] = 1;
            }
            if (fault == 5) {
                pg->draw_arrays_length = 1;
                pg->draw_arrays_count[0] = 0;
            }
            if (fault >= 6) {
                pg->inline_array_length = 1;
                pg->vertex_attributes[0].count = 1;
                pg->vertex_attributes[0].size = fault == 6 ? 0 :
                                                fault == 7 ? 3 :
                                                             4;
                pg->vertex_attributes[0].format =
                    fault == 8 ? 99 : NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
            }
            read_inputs(pg, NO);
        }
        NSError *error = nil;
        assert(![NV2AMetalPGRAPHPendingInputs inputsWithState:NULL
                                                        error:&error] &&
               error);
        rejected++;
        printf(
            "Pending PGRAPH descriptors: %u readonly captures/%u rejected "
            "layouts PASS; all1250 array counts, indexed/immediate and six "
            "packed formats/mixed alignment, no Metal device/queue/dispatch\n",
            captures, rejected);
        free(pg);
    }
    return 0;
}
