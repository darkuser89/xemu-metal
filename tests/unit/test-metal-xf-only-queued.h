/* XF-only metadata and queued GPU ownership across state/restore boundaries.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_XF_ONLY_QUEUED_H
#define TEST_METAL_XF_ONLY_QUEUED_H
#include "test-metal-range-idx.h"
static NV2AMetalCommands *queued_xf_gate_commands;
static id<MTL4CommandQueue> queued_xf_gate_queue;
static id<MTLSharedEvent> queued_xf_gate;
static BOOL queued_xf_release_on_wait;
static unsigned queued_xf_native_commits, queued_xf_native_waits;
static void (*queued_xf_original_commit)(id, SEL, const id<MTL4CommandBuffer> *,
                                         NSUInteger, MTL4CommitOptions *);
static BOOL (*queued_xf_original_wait)(id, SEL, NSError **);
static BOOL (*queued_xf_original_receipt_wait)(id, SEL, NV2AMetalSubmission *,
                                               NSError **);
static BOOL (*queued_xf_original_producer_wait)(id, SEL, NV2AMetalSubmission *,
                                                NSError **);
static void queued_xf_commit(id object, SEL selector,
                             const id<MTL4CommandBuffer> *buffers,
                             NSUInteger count, MTL4CommitOptions *options)
{
    if (object == queued_xf_gate_queue) {
        assert(count);
        queued_xf_native_commits++;
    }
    queued_xf_original_commit(object, selector, buffers, count, options);
}
static void queued_xf_observe_wait(id object)
{
    if (object != queued_xf_gate_commands)
        return;
    queued_xf_native_waits++;
    if (queued_xf_release_on_wait && !queued_xf_gate.signaledValue) {
        /* A real committed producer is blocked on this queue's event. The
         * snapshot must enter its actual CPU completion wait to release it. */
        assert(queued_xf_native_commits);
        queued_xf_gate.signaledValue = 1;
    }
}
static BOOL queued_xf_wait(id object, SEL selector, NSError **error)
{
    queued_xf_observe_wait(object);
    return queued_xf_original_wait(object, selector, error);
}
static BOOL queued_xf_receipt_wait(id object, SEL selector,
                                   NV2AMetalSubmission *receipt,
                                   NSError **error)
{
    if (object == queued_xf_gate_commands && queued_xf_release_on_wait &&
        !queued_xf_gate.signaledValue)
        assert(![receipt completedWithError:NULL]);
    queued_xf_observe_wait(object);
    return queued_xf_original_receipt_wait(object, selector, receipt, error);
}
static BOOL queued_xf_producer_wait(id object, SEL selector,
                                    NV2AMetalSubmission *receipt,
                                    NSError **error)
{
    if (object == queued_xf_gate_commands && queued_xf_release_on_wait &&
        !queued_xf_gate.signaledValue)
        assert(![receipt completedProducersWithError:NULL]);
    queued_xf_observe_wait(object);
    return queued_xf_original_producer_wait(object, selector, receipt, error);
}
static unsigned queued_xf_checkpoint;
static BOOL (*queued_xf_original_checkpoint)(id, SEL, NSError **);
static BOOL queued_xf_fail_accept(id object, SEL selector, NSError **error)
{
    if (++queued_xf_checkpoint == 2) {
        if (error)
            *error = [NSError errorWithDomain:@"test.queued-xf"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return queued_xf_original_checkpoint(object, selector, error);
}
static BOOL queued_xf_boundary(unsigned action, NSError **error)
{
    return action == 2 ? [draw drawWithError:error] :
                         [draw prepareVertexStateChangeWithError:error];
}
static void queued_xf_inline(PGRAPHState *pg, const float positions[][4],
                             unsigned count, BOOL converted)
{
    pg->inline_array_length = count * (converted ? 5 : 4);
    for (unsigned v = 0; v < count; v++) {
        memcpy(pg->inline_array + v * (converted ? 5 : 4), positions[v], 16);
        if (converted)
            pg->inline_array[v * 5 + 4] = 0xff00ff00;
    }
}
static void queued_xf_bounded_program(PGRAPHState *pg, unsigned kind)
{
    if (kind >= 6) {
        unsigned family = kind - 6;
        if (family >= 8)
            family += 2; /* Ambiguous signed-zero comparisons keep a wait. */
        const unsigned bases[] = { 191, 95, 191, 96, 95,  191,
                                   191, 95, 0,   0,  191, 95 };
        Token tokens[8];
        unsigned count = range_idx_tokens(tokens, family, bases[family], YES);
        memcpy(pg->program_data, tokens, (count - 1) * sizeof(Token));
        /* Preserve initial R12.w for the range proof, then publish position
         * before the final relative color read. */
        mov(count - 1, 0, 0, false);
        memcpy(pg->program_data[count], tokens[count - 1].word, 16);
        const float colors[2][4] = { { 0, 1, 0, 1 }, { 0, 0, 1, 1 } };
        for (unsigned row = 0; row < 192; row++)
            memcpy(pg->vsh_constants[row], colors[row & 1], 16);
        return;
    }
    BOOL negative = kind < 4 && (kind & 1);
    unsigned slot = 2;
    mov(0, 0, 0, false);
    Token compare =
        token(kind >= 4 ? 2 : 11, kind >= 4 ? 7 : 0, kind >= 4 ? 99 : 96);
    compare.word[1] |= 3u << 9;
    source(&compare, 0, 1, 0, 0xe4);
    source(&compare, 1, kind >= 4 ? 3 : 2, 0, 0xe4);
    source(&compare, 2, 1, 0, 0xe4);
    destination(&compare, 0, 0, 0, 2, 15, kind >= 4 ? 15 : 0);
    memcpy(pg->program_data[1], compare.word, 16);
    if (kind == 2 || kind == 3 || kind == 5) {
        Token add = token(3, 0, 96);
        source(&add, 0, 1, 2, 0xe4);
        source(&add, 2, 1, kind == 5 ? 1 : 2, kind == 5 ? 0xff : 0xe4);
        destination(&add, 0, 0, 0, 2, 15, 0);
        memcpy(pg->program_data[slot++], add.word, 16);
    }
    Token arl = token(13, 0, 96);
    source(&arl, 0, 1, 2, 0);
    if (negative)
        arl.word[1] |= 1u << 8;
    destination(&arl, 0, 0, 0, 0, 0, 0);
    memcpy(pg->program_data[slot++], arl.word, 16);
    Token read = token(1, 0, negative ? (kind >= 2 ? 98 : 97) : 96);
    source(&read, 0, 3, 0, 0xe4);
    destination(&read, 0x103, 15, 0, 0, 0, 0);
    read.word[3] |= 3;
    memcpy(pg->program_data[slot], read.word, 16);
    const float colors[3][4] = { { 0, 1, 0, 1 },
                                 { 0, 0, 1, 1 },
                                 { 1, 0, 0, 1 } };
    memcpy(pg->vsh_constants[96], colors, sizeof(colors));
    if (kind >= 4) {
        const uint32_t special[] = { 0x7fc12345, 0x7f800000, 0xff800000, 1 };
        memcpy(pg->vsh_constants[99], special, sizeof(special));
    }
}
static void queued_xf_constant_program(PGRAPHState *pg, unsigned kind)
{
    if (kind >= 16) {
        unsigned family =
            (unsigned[]){ 0, 1, 2, 3, 6, 7, 8, 11 }[(kind - 16) % 8];
        BOOL captured = kind < 24, negative = family == 7 || family == 8;
        Token tokens[12];
        unsigned count = clamped_idx_tokens(tokens, family, negative ? 97 : 96,
                                            captured, YES);
        tokens[captured ? 2 : 0].word[1] |= 3u << 9;
        memcpy(pg->program_data, tokens, (count - 1) * sizeof(Token));
        mov(count - 1, 0, 0, false);
        memcpy(pg->program_data[count], tokens[count - 1].word, 16);
        const float colors[3][4] = { { 0, 1, 0, 1 },
                                     { 0, 0, 1, 1 },
                                     { 1, 0, 0, 1 } };
        const float lower[4] = { 0, 0, 0, 0 }, upper[4] = { 1, 1, 1, 1 };
        memcpy(pg->vsh_constants[96], colors, sizeof(colors));
        memcpy(pg->vsh_constants[100], lower, sizeof(lower));
        memcpy(pg->vsh_constants[101], upper, sizeof(upper));
        return;
    }
    BOOL fractional = kind >= 8;
    kind %= 8;
    Token t[8];
    unsigned count = 0, base = kind == 1              ? 97 :
                               kind == 4 || kind == 6 ? 95 :
                                                        96;
    if (fractional && kind == 4)
        base = 96;
    if (kind == 3 || kind == 5) {
        t[count] = token(11, 0, 96);
        t[count].word[1] |= 3u << 9;
        source(&t[count], 0, 2, 0, 0xe4);
        source(&t[count], 1, 1, 0, 0xe4);
        destination(&t[count++], 0, 0, 0, 2, 15, 0);
    }
    if (kind == 2 || kind >= 5) {
        t[count] = token(kind == 5 ? 2 :
                         kind == 6 ? 3 :
                                     1,
                         kind == 7 ? 1 : 0, 100);
        source(&t[count], 0, kind == 5 || kind == 7 ? 1 : 3, kind == 5 ? 2 : 0,
               kind == 2 ? 0xaa : 0);
        if (kind == 5)
            source(&t[count], 1, 3, 0, 0);
        if (kind == 6 || kind == 7)
            source(&t[count], 2, kind == 6 ? 1 : 3, kind == 6 ? 12 : 0,
                   kind == 6 ? 0xff : 0);
        destination(&t[count++], 0, 0, 0, kind == 7 ? 1 : 3, 15,
                    kind == 7 ? 15 : 0);
    }
    t[count] = token(13, 0, kind == 4 ? 58 : 100);
    source(&t[count], 0, kind == 0 || kind == 1 || kind == 4 ? 3 : 1,
           kind == 3 ? 2 :
           kind == 7 ? 1 :
                       3,
           0);
    if (kind == 1)
        t[count].word[1] |= 1u << 8;
    destination(&t[count++], 0, 0, 0, 0, 0, 0);
    if (kind == 3) {
        t[count] = token(1, 0, 100);
        source(&t[count], 0, 3, 0, 0);
        destination(&t[count], 0, 0, 0, 3, 15, 0);
        t[count++].word[3] |= 2;
        t[count] = token(13, 0, 96);
        source(&t[count], 0, 1, 3, 0);
        destination(&t[count++], 0, 0, 0, 0, 0, 0);
    }
    memcpy(pg->program_data, t, count * sizeof(Token));
    mov(count++, 0, 0, false);
    t[0] = token(1, 0, base);
    source(&t[0], 0, 3, 0, 0xe4);
    destination(&t[0], 0x103, 15, 0, 0, 0, 0);
    t[0].word[3] |= 3;
    memcpy(pg->program_data[count], t[0].word, 16);
    const float colors[3][4] = { { 0, 1, 0, 1 },
                                 { 0, 0, 1, 1 },
                                 { 1, 0, 0, 1 } };
    memcpy(pg->vsh_constants[96], colors, sizeof(colors));
    const float constants[3][4] = { { 1, 1, 1, 1 },
                                    { 0, 1, 0, 1 },
                                    { 2, 2, 2, 2 } };
    memcpy(pg->vsh_constants[100],
           constants[kind == 3 ? 1 :
                     kind == 5 ? 2 :
                                 0],
           16);
    memcpy(pg->vsh_constants[101], constants[0], 16);
    memcpy(pg->vsh_constants[58], constants[0], 16);
    if (fractional)
        for (unsigned i = 0; i < 3; i++)
            for (unsigned lane = 0; lane < 4; lane++) {
                unsigned row = (unsigned[]){ 100, 101, 58 }[i];
                float value;
                memcpy(&value, &pg->vsh_constants[row][lane], sizeof(value));
                value *= 0.25f;
                memcpy(&pg->vsh_constants[row][lane], &value, sizeof(value));
            }
}
static void queued_xf_attribute_program(PGRAPHState *pg, unsigned kind)
{
    unsigned slot = 1;
    mov(0, 0, 0, false);
    if (kind == 2) {
        Token multiply = token(NV2AMetalMACMul, 0, 100);
        multiply.word[1] |= 3u << 9;
        source(&multiply, 0, 2, 0, 0xff);
        source(&multiply, 1, 3, 0, 0);
        destination(&multiply, 0, 0, 0, 2, 8, 0);
        memcpy(pg->program_data[slot++], multiply.word, 16);
    }
    Token arl = token(NV2AMetalMACArl, 0, 96);
    arl.word[1] |= 3u << 9;
    source(&arl, 0, kind == 2 ? 1 : 2, kind == 2 ? 2 : 0,
           kind == 2 ? 0 :
           kind == 1 ? 0xaa :
                       0x55);
    destination(&arl, 0, 0, 0, 0, 0, 0);
    memcpy(pg->program_data[slot++], arl.word, 16);
    Token read = token(NV2AMetalMACMov, 0, kind == 1 ? 98 : 96);
    source(&read, 0, 3, 0, 0xe4);
    destination(&read, 0x103, 15, 0, 0, 0, 0);
    read.word[3] |= 3;
    memcpy(pg->program_data[slot], read.word, 16);
    const float colors[][4] = { { 0, 1, 0, 1 }, { 0, 0, 1, 1 } };
    const float scale[4] = { 0.25f, 0, 0, 0 };
    memcpy(pg->vsh_constants[96], colors, sizeof(colors));
    memcpy(pg->vsh_constants[100], scale, sizeof(scale));
    if (kind == 1)
        pg->vertex_attributes[3].inline_value[2] = -512.0f / 511.0f;
}
static void queued_xf_large_scale_program(PGRAPHState *pg)
{
    queued_xf_attribute_program(pg, 0);
    memcpy(pg->program_data[3], pg->program_data[2], 16);
    Token multiply = token(NV2AMetalMACMul, 0, 100);
    source(&multiply, 0, 3, 0, 0);
    source(&multiply, 1, 3, 0, 0x55);
    destination(&multiply, 0, 0, 0, 2, 8, 0);
    memcpy(pg->program_data[1], multiply.word, 16);
    Token arl = token(NV2AMetalMACArl, 0, 96);
    source(&arl, 0, 1, 2, 0);
    memcpy(pg->program_data[2], arl.word, 16);
    const uint32_t coefficients[] = {0x71800000, 0x0d800000};
    memcpy(pg->vsh_constants[100], coefficients, sizeof(coefficients));
    const float green[4] = {0,1,0,1};
    memcpy(pg->vsh_constants[97], green, sizeof(green));
}
static void queued_xf_large_union_program(PGRAPHState *pg)
{
    queued_xf_large_scale_program(pg);
    memcpy(pg->program_data[5], pg->program_data[3], 16);
    memcpy(pg->program_data[4], pg->program_data[2], 16);
    memcpy(pg->program_data[3], pg->program_data[1], 16);
    pg->program_data[3][3] |= 2;
    Token select = token(NV2AMetalMACSlt, 0, 96);
    select.word[1] |= 3u << 9;
    source(&select, 0, 2, 0, 0);
    source(&select, 1, 1, 0, 0);
    destination(&select, 0, 0, 0, 2, 8, 0);
    memcpy(pg->program_data[1], select.word, 16);
    memcpy(pg->program_data[2], pg->program_data[4], 16);
    memcpy(pg->vsh_constants[101], pg->vsh_constants[100], 16);
}
static void queued_xf_large_reciprocal_program(PGRAPHState *pg,
                                               unsigned opcode, BOOL relative)
{
    if (relative)
        queued_xf_large_union_program(pg);
    else
        queued_xf_large_scale_program(pg);
    unsigned slot = relative ? 3 : 1;
    Token ilu = token(0, opcode, 100);
    source(&ilu, 2, 3, 0, 0);
    destination(&ilu, 0, 0, 0, 2, 0, 8);
    if (relative)
        ilu.word[3] |= 2;
    memcpy(pg->program_data[slot], ilu.word, 16);
    Token read = token(NV2AMetalMACMov, 0, 160);
    source(&read, 0, 3, 0, 0xe4);
    destination(&read, 0x103, 15, 0, 0, 0, 0);
    read.word[3] |= 3;
    memcpy(pg->program_data[slot + 2], read.word, 16);
    const float green[4] = {0,1,0,1};
    for (unsigned row = 159; row <= 161; row++)
        memcpy(pg->vsh_constants[row], green, 16);
}
static void queued_constant_float_tests(BOOL typed, unsigned reciprocal)
{
    assert(!reciprocal || (!typed && reciprocal <= 20));
    BOOL largeScale = reciprocal == 13 || reciprocal == 14;
    BOOL largeReciprocal = reciprocal >= 15;
    NSError *error = nil;
    unsigned cases = 0;
    const struct {
        unsigned format, count, size;
        uint32_t bits[4];
    } sources[] = {
        { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F, 4, 4, { 0, 0x3f800000, 0, 0x3f800000 } },
        { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D, 4, 1, { 0xff00ff00 } },
        { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL, 4, 1, { 0xff00ff00 } },
        { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1, 4, 2, { 0x7fff0000, 0x7fff0000 } },
        { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K, 4, 2, { 0x00010000, 0x00010000 } },
        { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP, 1, 4, { 1023u << 11 } },
    };
    for (unsigned sourceKind = 0; sourceKind < (typed ? ARRAY_SIZE(sources) : 1u); sourceKind++)
      for (unsigned indexed = 0; indexed < 2; indexed++)
        for (unsigned full = 0; full < 2; full++)
            for (unsigned warm = 0; warm < 2; warm++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 |
                    (full ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0);
                queued_xf_attribute_program(pg, 0);
                uint32_t raw[4];
                memcpy(raw, sources[sourceKind].bits, sizeof(raw));
                if (largeReciprocal) {
                    queued_xf_large_reciprocal_program(pg,
                        NV2AMetalILURcp + (reciprocal - 15) % 3,
                        reciprocal >= 18);
                } else if (largeScale) {
                    if (reciprocal == 14)
                        queued_xf_large_union_program(pg);
                    else
                        queued_xf_large_scale_program(pg);
                } else if (reciprocal) {
                    unsigned kind = (reciprocal - 1) % 3;
                    BOOL scaled = reciprocal > 3;
                    BOOL wide = reciprocal > 6;
                    BOOL largest = reciprocal > 9;
                    raw[1] = largest ? (kind == 2 ? 0x27800000 : 0x33800000) :
                             wide ? (kind == 2 ? 0x34800000 : 0x3a000000) :
                             scaled ? (kind == 2 ? 0x37800000 : 0x3b800000) :
                                      kind == 2 ? 0x3e800000 : 0x3f000000;
                    memcpy(pg->program_data[scaled ? 4 : 3], pg->program_data[2], 16);
                    Token ilu = token(0, NV2AMetalILURcp + kind, 96);
                    ilu.word[1] |= 3u << 9;
                    source(&ilu, 2, 2, 0, 0x55);
                    destination(&ilu, 0, 0, 0, 2, 0, 15);
                    memcpy(pg->program_data[1], ilu.word, 16);
                    Token arl = token(NV2AMetalMACArl, 0, 96);
                    source(&arl, 0, 1, 2, 0);
                    memcpy(pg->program_data[scaled ? 3 : 2], arl.word, 16);
                    if (scaled) {
                        if (wide) {
                            const float scale = largest ? 0x1p-18f : .03125f;
                            memcpy(&pg->vsh_constants[100][0], &scale, sizeof(scale));
                        }
                        Token multiply = token(NV2AMetalMACMul, 0, 100);
                        source(&multiply, 0, 1, 2, 0);
                        source(&multiply, 1, 3, 0, 0);
                        destination(&multiply, 0, 0, 0, 2, 15, 0);
                        memcpy(pg->program_data[2], multiply.word, 16);
                    }
                    const float green[4] = { 0, 1, 0, 1 };
                    memcpy(pg->vsh_constants[scaled ? 160 : 98], green, sizeof(green));
                }
                pg->vertex_attributes[3] = (VertexAttribute){
                    .format = sources[sourceKind].format,
                    .size = sources[sourceKind].size, .count = sources[sourceKind].count,
                    .offset = 64, .stride = 0
                };
                cpu_write(16384 + 64, sizeof(raw));
                memcpy(state->vram_ptr + 16384 + 64, raw, sizeof(raw));
                if (indexed) {
                    pg->draw_arrays_length = 0;
                    pg->inline_elements_length = 3;
                    const uint32_t indices[] = { 2, 0, 1 };
                    memcpy(pg->inline_elements, indices, sizeof(indices));
                }
                qemu_mutex_lock(&pg->lock);
                NV2AMetalPGRAPHFetch *fetch = [draw valueForKey:@"fetch"];
                if (warm) {
                    NSArray *seed = [fetch encodeIndependentSnapshotsWithError:&error];
                    require(seed && [fetch completeWithError:&error], error);
                }
                NV2AMetalFetchUniforms preview;
                [fetch getSourcePreview:&preview attributes:1u << 3];
                assert(preview.attributes[3].count == (warm ? 0u : sources[sourceKind].count));
                VertexAttribute original[16];
                memcpy(original, pg->vertex_attributes, sizeof(original));
                require([draw beginWithError:&error] &&
                        [surfaces.cache submitWithError:&error] &&
                        [surfaces.cache waitUntilIdleWithError:&error], error);
                Method submit = class_getInstanceMethod(NV2AMetalCommands.class,
                                                        @selector(submitWithError:));
                Method wait = class_getInstanceMethod(NV2AMetalCommands.class,
                                                      @selector(waitUntilIdleWithError:));
                Method receipt = class_getInstanceMethod(NV2AMetalCommands.class,
                                                        @selector(waitForSubmission:error:));
                Method encode = class_getInstanceMethod(NV2AMetalEpochExecutor.class,
                    @selector(encodeRasterState:attributeBuffer:first:count:attributeFetch:commands:error:));
                shared_original_submit = (void *)method_setImplementation(submit, (IMP)shared_submit_count);
                shared_original_wait = (void *)method_setImplementation(wait, (IMP)shared_wait_count);
                shared_original_submission_wait = (void *)method_setImplementation(receipt, (IMP)shared_submission_wait_count);
                xf_only_original_encode = (void *)method_setImplementation(encode, (IMP)xf_only_capture);
                xf_only_encodings = [NSMutableArray new];
                shared_draw_submits = shared_draw_waits = 0;
                require([draw prepareVertexStateChangeWithError:&error], error);
                unsigned submits = shared_draw_submits, waits = shared_draw_waits;
                method_setImplementation(submit, (IMP)shared_original_submit);
                method_setImplementation(wait, (IMP)shared_original_wait);
                method_setImplementation(receipt, (IMP)shared_original_submission_wait);
                method_setImplementation(encode, (IMP)xf_only_original_encode);
                /* All six stride-zero fixtures decode to finite, safe values.
                 * Guarded capture supplies their exact bound Current domain
                 * even when the cold format preview is opaque. */
                unsigned expectedWaits = 0;
                if (submits != expectedWaits || waits != expectedWaits)
                    fprintf(stderr,
                            "Constant reciprocal queued: reciprocal=%u "
                            "sourceKind=%u format=%u indexed=%u full=%u "
                            "warm=%u submits=%u waits=%u expected=%u "
                            "rawY=%08x\n",
                            reciprocal, sourceKind, sources[sourceKind].format,
                            indexed, full, warm, submits, waits, expectedWaits,
                            raw[1]);
                assert(submits == expectedWaits && waits == expectedWaits);
                require([surfaces.cache submitWithError:&error] &&
                        [surfaces.cache waitUntilIdleWithError:&error], error);
                NV2AMetalPendingJournal *pending = [draw valueForKey:@"pending"];
                NV2AMetalEpochExecutor *executor = [draw valueForKey:@"epoch"];
                assert(xf_only_encodings.count == 1 && pending.retainedStreams.count == 1);
                NSArray *item = xf_only_encodings[0];
                NV2AMetalEpochResult *reference = [executor executeState:item[0]
                    attributeBuffer:item[1] first:[item[2] unsignedIntegerValue]
                    count:[item[3] unsignedIntegerValue] error:&error];
                require(reference != nil, error);
                NSArray<NV2AMetalPendingSpan *> *spans = pending.retainedStreams[0];
                assert(spans.count == 1 && spans[0].count == reference.vertexCount);
                id<MTLBuffer> buffer = spans[0].resource;
                assert(!memcmp((const uint8_t *)buffer.contents + spans[0].first * sizeof(NV2AMetalVertex),
                               reference.vertices.contents, reference.vertexCount * sizeof(NV2AMetalVertex)));
                if (memcmp(pg->vertex_attributes, original, sizeof(original))) {
                    fprintf(stderr, "Constant Current mismatch reciprocal=%u indexed=%u full=%u warm=%u\n",
                            reciprocal, indexed, full, warm);
                    const uint8_t *actual = (const void *)pg->vertex_attributes;
                    const uint8_t *expected = (const void *)original;
                    for (NSUInteger byte = 0; byte < sizeof(original); byte++)
                        if (actual[byte] != expected[byte])
                            fprintf(stderr, "byte %zu actual=%02x expected=%02x\n",
                                    byte, actual[byte], expected[byte]);
                    abort();
                }
                xf_only_encodings = nil;
                require([draw discardForRestoreWithError:&error], error);
                qemu_mutex_unlock(&pg->lock);
                cases++;
            }
    assert(cases == (typed ? 48u : 8u));
    const char *operation = largeReciprocal ?
        (const char *[]){"large RCP", "large RCC", "large RSQ"}[(reciprocal-15)%3] :
        reciprocal == 14 ? "relative large MUL" : largeScale ? "large MUL" : reciprocal ?
        (const char *[]){ "RCP", "RCC", "RSQ" }[(reciprocal - 1) % 3] :
        typed ? "DMA" : "Float";
    const char *factor = largeReciprocal ? (reciprocal >= 18 ? " relative" : " direct") :
                         largeScale ? "" : reciprocal > 9 ? "*2^-18" :
                         reciprocal > 6 ? "*0.03125" :
                         reciprocal > 3 ? "*0.25" : "";
    const char *completion = "cold and warm zero producer submits/waits";
    printf("Constant %s%s XF-only: %u cold/warm,array/indexed,USER/FULL cases; "
           "%s,"
           "exact generic GPU vertices and Current PASS\n",
           operation, factor, cases, completion);
    groups++;
}
static BOOL constant_raster_requires_completion(id object, SEL selector,
                                                NV2AMetalPendingInput *input)
{
    (void)object;
    (void)selector;
    (void)input;
    return NO;
}
static void (*constant_raster_original_preview)(id, SEL,
                                                NV2AMetalFetchUniforms *,
                                                uint16_t);
static void constant_raster_stale_preview(id object, SEL selector,
                                          NV2AMetalFetchUniforms *preview,
                                          uint16_t attributes)
{
    assert(attributes == ((1u << 0) | (1u << 3)));
    constant_raster_original_preview(object, selector, preview, attributes);
    assert(preview->attributes[3].format ==
           NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F);
    preview->attributes[3].format =
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL;
    preview->attributes[3].count = 2;
}
static NV2AMetalSubmission *constant_raster_submission;
static BOOL constant_raster_submit(NV2AMetalCommands *commands, SEL selector,
                                    NSError **error)
{
    if (!shared_submit_count(commands, selector, error))
        return NO;
    constant_raster_submission = commands.lastSubmitted;
    return YES;
}
static void queued_constant_raster_tests(void)
{
    NSError *error = nil;
    unsigned pairs = 0;
    for (unsigned kind = 0; kind < 44; kind++)
        for (unsigned policy = 0; policy < 4; policy++)
            for (unsigned converted = 0; converted < 2; converted++) {
                if (kind == 35 && converted)
                    continue;
                NSData *reference = nil;
                for (unsigned gated = 0; gated < 2; gated++) {
                    BOOL queued = gated && kind != 35;
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    pg->regs_[NV_PGRAPH_CSV0_D] =
                        2u << 30 |
                        (policy & 1 ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0);
                    pg->enable_vertex_program_write = policy & 2;
                    if (kind < 32)
                        queued_xf_constant_program(pg, kind);
                    else if (kind == 36)
                        queued_xf_large_scale_program(pg);
                    else if (kind == 37)
                        queued_xf_large_union_program(pg);
                    else if (kind >= 38)
                        queued_xf_large_reciprocal_program(pg,
                            NV2AMetalILURcp + (kind - 38) % 3, kind >= 41);
                    else
                        queued_xf_attribute_program(pg,
                                                    kind == 35 ? 0 : kind - 32);
                    if (kind >= 16 && kind < 32 && !converted)
                        memcpy(&pg->vertex_attributes[3].inline_value[0],
                               &(uint32_t){ 0x7fc12345 }, 4);
                    if (converted) {
                        pg->draw_arrays_length = 0;
                        VertexAttribute *diffuse = &pg->vertex_attributes[3];
                        diffuse->format =
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
                        diffuse->size = 1;
                        diffuse->count = 4;
                        const float positions[3][4] = { { 0, 0, 32768, 1 },
                                                        { 8, 0, 32768, 1 },
                                                        { 0, 8, 32768, 1 } };
                        queued_xf_inline(pg, positions, 3, YES);
                        if (kind == 33 || kind == 37 || kind >= 41) {
                            diffuse->format =
                                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP;
                            diffuse->size = 4;
                            diffuse->count = 1;
                            for (unsigned v = 0; v < 3; v++)
                                pg->inline_array[v * 5 + 4] = kind == 33 ?
                                    512u << 22 : v == 0 ? 1024u : v == 1 ? 1023u : 0;
                        }
                    } else if (kind == 37 || kind >= 41) {
                        pg->vertex_attributes[3] = (VertexAttribute){
                            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                            .count = 4, .size = 2, .stride = 8, .offset = 64,
                        };
                        const int16_t values[3][4] = {
                            {-32768, 0, 0, 32767}, {32767, 0, 0, 32767},
                            {0, 0, 0, 32767}
                        };
                        cpu_write(16384 + 64, sizeof(values));
                        memcpy(state->vram_ptr + 16384 + 64, values, sizeof(values));
                    } else if (kind == 32) {
                        VertexAttribute *diffuse = &pg->vertex_attributes[3];
                        diffuse->format =
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL;
                        diffuse->count = diffuse->stride = 2;
                        diffuse->size = 1;
                        diffuse->offset = 64;
                        const uint8_t bytes[] = { 0, 255, 0, 255, 0, 255 };
                        cpu_write(16384 + 64, sizeof(bytes));
                        memcpy(state->vram_ptr + 16384 + 64, bytes,
                               sizeof(bytes));
                    } else if (kind == 35) {
                        /* The sample is valid, but arbitrary Float4 does not
                         * prove the relative address. Require late feedback. */
                        pg->vertex_attributes[3] = (VertexAttribute){
                            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                            .count = 4,
                            .size = 4,
                            .stride = 16,
                            .offset = 64,
                        };
                        const float values[3][4] = { { 0, 1, 0, 1 },
                                                     { 0, 1, 0, 1 },
                                                     { 0, 1, 0, 1 } };
                        cpu_write(16384 + 64, sizeof(values));
                        memcpy(state->vram_ptr + 16384 + 64, values,
                               sizeof(values));
                    }
                    qemu_mutex_lock(&pg->lock);
                    if (kind >= 32) {
                        NV2AMetalPGRAPHVertexState *capture =
                            [[NV2AMetalPGRAPHVertexState alloc]
                                initRawXFWithState:pg
                                             error:&error];
                        require(capture != nil, error);
                        assert(capture.faultFreeReadOnlyAccess == (kind >= 36));
                    }
                    require([surfaces prepareColor:YES
                                              zeta:NO
                                      forRendering:NO
                                             error:&error] &&
                                [surfaces.cache submitWithError:&error] &&
                                [surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    require([draw beginWithError:&error], error);
                    uint32_t constants[192][4];
                    memcpy(constants, pg->vsh_constants, sizeof(constants));
                    NV2AMetalCommands *commands = surfaces.cache.commands;
                    id<MTLSharedEvent> gate = nil;
                    if (queued) {
                        gate = [commands.device newSharedEvent];
                        Ivar ivar = class_getInstanceVariable(
                            NV2AMetalCommands.class, "_queue");
                        id<MTL4CommandQueue> queue =
                            object_getIvar(commands, ivar);
                        assert(gate && queue);
                        [queue waitForEvent:gate value:1];
                        id<MTLSharedEvent> watchdog = gate;
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                              if (!watchdog.signaledValue)
                                  watchdog.signaledValue = 2;
                            });
                    }
                    Method submit = class_getInstanceMethod(
                        NV2AMetalCommands.class, @selector(submitWithError:));
                    Method wait = class_getInstanceMethod(
                        NV2AMetalCommands.class,
                        @selector(waitUntilIdleWithError:));
                    Method receipt = class_getInstanceMethod(
                        NV2AMetalCommands.class,
                        @selector(waitForSubmission:error:));
                    shared_original_submit = (void *)method_setImplementation(
                        submit, (IMP)constant_raster_submit);
                    shared_original_wait = (void *)method_setImplementation(
                        wait, (IMP)shared_wait_count);
                    shared_original_submission_wait =
                        (void *)method_setImplementation(
                            receipt, (IMP)shared_submission_wait_count);
                    shared_draw_submits = shared_draw_waits = 0;
                    Method proof = class_getInstanceMethod(
                        NV2AMetalPGRAPHFetch.class,
                        @selector(canCaptureCurrentForInput:));
                    IMP originalProof =
                        gated ? NULL :
                                method_setImplementation(
                                    proof,
                                    (IMP)constant_raster_requires_completion);
                    Method preview = class_getInstanceMethod(
                        NV2AMetalPGRAPHFetch.class,
                        @selector(getSourcePreview:attributes:));
                    IMP originalPreview = NULL;
                    if (kind == 35 && gated) {
                        originalPreview = method_setImplementation(
                            preview, (IMP)constant_raster_stale_preview);
                        constant_raster_original_preview =
                            (void *)originalPreview;
                    }
                    @try {
                        require([draw endWithError:&error], error);
                        /* A completed receipt can be validated without a
                         * blocking wait when GPU feedback arrives early. */
                        NSError *feedbackError = nil;
                        BOOL producerCompleted =
                            [constant_raster_submission
                                completedWithError:&feedbackError] &&
                            !feedbackError;
                        assert(
                            pg->draw_time == 1 &&
                            (queued ?
                                 (!shared_draw_submits && !shared_draw_waits) :
                                 (shared_draw_submits && producerCompleted)) &&
                            !gate.signaledValue &&
                            !memcmp(constants, pg->vsh_constants,
                                    sizeof(constants)));
                        const float last[4] = { 0, 8, 32768, 1 };
                        assert(!memcmp(pg->vertex_attributes[0].inline_value,
                                       last, 16));
                        if (kind == 33 && converted)
                            assert(pg->vertex_attributes[3].inline_value[2] ==
                                   -1.0f);
                        if (queued) {
                            unsigned row =
                                kind < 16 && kind % 8 == 4 ? 58 : 100;
                            for (unsigned lane = 0; lane < 4; lane++)
                                memcpy(&pg->vsh_constants[row][lane],
                                       &(uint32_t){ 0x7fc12345 }, 4);
                        }
                        unsigned submitted = shared_draw_submits,
                                 waited = shared_draw_waits;
                        require([surfaces.cache submitWithError:&error], error);
                        assert(shared_draw_submits == submitted + 1 &&
                               shared_draw_waits == waited);
                        if (queued) {
                            assert(!gate.signaledValue &&
                                   ![commands.lastSubmitted
                                       completedWithError:NULL]);
                            gate.signaledValue = 1;
                        }
                    } @finally {
                        constant_raster_submission = nil;
                        if (originalPreview)
                            method_setImplementation(preview, originalPreview);
                        if (originalProof)
                            method_setImplementation(proof, originalProof);
                        if (gate && !gate.signaledValue)
                            gate.signaledValue = 1;
                        method_setImplementation(submit,
                                                 (IMP)shared_original_submit);
                        method_setImplementation(wait,
                                                 (IMP)shared_original_wait);
                        method_setImplementation(
                            receipt, (IMP)shared_original_submission_wait);
                    }
                    require([surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    memcpy(pg->vsh_constants, constants, sizeof(constants));
                    qemu_mutex_unlock(&pg->lock);
                    read_vram(1024, 256);
                    BOOL blue = kind < 8 && (kind == 0 || kind == 2 ||
                                             kind == 6 || kind == 7);
                    if (kind >= 32) {
                        blue = kind == 32 || kind == 35;
                    } else if (kind >= 16) {
                        unsigned family = (kind - 16) % 8;
                        blue = (!converted) != (family == 5 || family == 6);
                    }
                    color(1, 1, blue ? 0xff0000ff : 0xff00ff00);
                    color(7, 7, 0xffff0000);
                    NSData *frame = [NSData dataWithBytes:state->vram_ptr + 1024
                                                   length:256];
                    if (!gated)
                        reference = frame;
                    else {
                        assert([reference isEqual:frame]);
                        pairs++;
                    }
                    draws++;
                }
            }
    assert(pairs == 348);
    puts("Constant/attribute IDX raster:348 exact 256-byte frame pairs/696 "
         "actual draws;43 integer/fractional/clamped/fetched-input/large-scale/relative-union/large-reciprocal programs; "
         "ARL/ADD/MUL/relative/paired-ILU "
         "programs,USER/FULL,write "
         "flag0/1,"
         "DMA Float4/UB_OGL/S1,converted D3D/CMP,raw inline and CMP Current;"
         "forced completion reference versus 344 GPU-gated draws with zero "
         "producer "
         "submits/waits,4 stale-preview Float feedback controls,immediate "
         "exact Current,"
         "NaN live-constant mutation "
         "isolated until GPU completion,explicit blue/green/red pixels PASS");
    groups++;
}

static void queued_xf_tests(void)
{
    NSError *error = nil;
    unsigned pairs = 0, failedAccepts = 0;
    unsigned constantCaptures = 0, staticCaptures = 0;
    for (unsigned mode = 0; mode < 205; mode++)
        for (unsigned action = 0; action < 3; action++) {
            NSData *reference = nil;
            for (unsigned queued = 0; queued < 4; queued++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                if (mode) {
                    unsigned policy = mode >= 9 ? (mode - 9) % 4 + 1 :
                                      mode > 4  ? mode - 4 :
                                                  mode;
                    pg->regs_[NV_PGRAPH_CSV0_D] =
                        2u << 30 |
                        (policy % 2 ? 0 : NV_PGRAPH_CSV0_D_RANGE_MODE);
                    pg->enable_vertex_program_write = policy >= 3;
                    mov(0, 0, 0, false);
                    mov(1, 3, 3, true);
                    if (mode > 4 && mode < 9) {
                        pg->program_data[1][1] =
                            (pg->program_data[1][1] & ~(255u << 13)) |
                            96u << 13;
                        pg->program_data[1][2] =
                            (pg->program_data[1][2] & ~(3u << 26)) | 3u << 26;
                        pg->program_data[1][3] |= 2;
                        const float green[4] = { 0, 1, 0, 1 };
                        memcpy(pg->vsh_constants[96], green, sizeof(green));
                    }
                    if (mode >= 201)
                        queued_xf_attribute_program(pg, 0);
                    else if (mode >= 73)
                        queued_xf_constant_program(pg, (mode - 73) / 4);
                    else if (mode >= 9)
                        queued_xf_bounded_program(
                            pg, mode >= 33 ? 6 + (mode - 33) / 4 :
                                mode >= 25 ? 4 + (mode >= 29) :
                                mode >= 17 ? 2 + (mode >= 21) :
                                             (mode >= 13));
                }
                if (action) {
                    pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
                    pg->surface_shape = (SurfaceShape){ 0 };
                    pg->surface_binding_dim.width =
                        pg->surface_binding_dim.height = 0;
                }
                float positions[5][4] = { { 0, 0, 32768, 1 },
                                          { 8, 0, 32768, 1 },
                                          { 0, 8, 32768, 1 },
                                          { 8, 8, 32768, 1 },
                                          { 4, 4, 32768, 1 } };
                pg->draw_arrays_length = 0;
                if (queued == 1) {
                    pg->inline_buffer_length = 3;
                    pg->vertex_attributes[0].inline_buffer = (float *)positions;
                    pg->vertex_attributes[0].inline_buffer_populated = true;
                } else {
                    if (queued == 3) {
                        VertexAttribute *diffuse = &pg->vertex_attributes[3];
                        diffuse->format =
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
                        diffuse->size = 1;
                        diffuse->count = 4;
                    }
                    queued_xf_inline(pg, positions, 3, queued == 3);
                }
                pg->compressed_attrs = 0x8011;
                qemu_mutex_lock(&pg->lock);
                if (action != 2)
                    require([draw beginWithError:&error], error);
                if (mode >= 73 && mode < 201) {
                    NV2AMetalPGRAPHVertexState *capture =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initRawXFWithState:pg
                                         error:&error];
                    require(capture != nil, error);
                    BOOL staticProof = (mode - 73) / 4 >= 24;
                    assert(capture.faultFreeReadOnlyAccess &&
                           [capture.validatedProgram
                               hasFaultFreeReadOnlyAccess:capture.fullAccess] ==
                               staticProof);
                    NV2AMetalPGRAPHVertexState *restored =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithSnapshot:capture.snapshotData
                                       error:&error];
                    require(restored != nil, error);
                    assert(restored.faultFreeReadOnlyAccess);
                    NV2AMetalProgramUniforms changed = capture.programUniforms;
                    unsigned family = (mode - 73) / 4;
                    unsigned row = family < 16 && family % 8 == 4 ? 58 : 100;
                    for (unsigned lane = 0; lane < 4; lane++)
                        memcpy(&changed.constants[row][lane],
                               &(uint32_t){ 0x7fc12345 }, 4);
                    uint32_t written[192] = { 0 };
                    written[row] = 1;
                    NV2AMetalPGRAPHVertexState *invalid = [restored
                        stateByApplyingConstants:
                            [NSData dataWithBytes:changed.constants
                                           length:sizeof(changed.constants)]
                                         written:[NSData
                                                     dataWithBytes:written
                                                            length:sizeof(
                                                                       written)]
                                           error:&error];
                    require(invalid != nil, error);
                    assert(invalid.faultFreeReadOnlyAccess == staticProof &&
                           capture.faultFreeReadOnlyAccess &&
                           restored.faultFreeReadOnlyAccess);
                    NV2AMetalPGRAPHVertexState *invalidRestored =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithSnapshot:invalid.snapshotData
                                       error:&error];
                    require(invalidRestored != nil, error);
                    assert(invalidRestored.faultFreeReadOnlyAccess ==
                           staticProof);
                    constantCaptures++;
                    staticCaptures += staticProof;
                }
                VertexAttribute original[16];
                memcpy(original, pg->vertex_attributes, sizeof(original));
                uint32_t constants[192][4];
                memcpy(constants, pg->vsh_constants, sizeof(constants));
                uint8_t dirty[sizeof(pg->vsh_constants_dirty)];
                memcpy(dirty, pg->vsh_constants_dirty, sizeof(dirty));
                id<MTLSharedEvent> gate = nil;
                Method wait =
                    class_getInstanceMethod(NV2AMetalCommands.class,
                                            @selector(waitUntilIdleWithError:));
                Method receiptWait = class_getInstanceMethod(
                    NV2AMetalCommands.class,
                    @selector(waitForSubmission:error:));
                Method producerWait = class_getInstanceMethod(
                    NV2AMetalCommands.class,
                    @selector(waitForProducersOfSubmission:error:));
                Method commit = NULL;
                if (queued) {
                    gate = [surfaces.cache.commands.device newSharedEvent];
                    Ivar queueIvar = class_getInstanceVariable(
                        NV2AMetalCommands.class, "_queue");
                    id<MTL4CommandQueue> queue =
                        object_getIvar(surfaces.cache.commands, queueIvar);
                    assert(gate && queue);
                    queued_xf_gate_commands = surfaces.cache.commands;
                    queued_xf_gate_queue = queue;
                    queued_xf_gate = gate;
                    queued_xf_release_on_wait = action != 2;
                    queued_xf_native_commits = queued_xf_native_waits = 0;
                    SEL commitSelector = @selector(commit:count:options:);
                    Class queueClass = object_getClass(queue);
                    commit =
                        class_getInstanceMethod(queueClass, commitSelector);
                    class_addMethod(queueClass, commitSelector,
                                    method_getImplementation(commit),
                                    method_getTypeEncoding(commit));
                    commit =
                        class_getInstanceMethod(queueClass, commitSelector);
                    queued_xf_original_commit =
                        (void *)method_setImplementation(commit,
                                                         (IMP)queued_xf_commit);
                    [queue waitForEvent:gate value:1];
                    id<MTLSharedEvent> watchdog = gate;
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                          if (!watchdog.signaledValue)
                              watchdog.signaledValue = 2;
                        });
                    queued_xf_original_wait = (void *)method_setImplementation(
                        wait, (IMP)queued_xf_wait);
                    queued_xf_original_receipt_wait =
                        (void *)method_setImplementation(
                            receiptWait, (IMP)queued_xf_receipt_wait);
                    queued_xf_original_producer_wait =
                        (void *)method_setImplementation(
                            producerWait, (IMP)queued_xf_producer_wait);
                }
                for (unsigned step = 0; step < 3; step++) {
                    if (step) {
                        unsigned count = step + 3;
                        if (queued == 1)
                            pg->inline_buffer_length = count;
                        else {
                            queued_xf_inline(pg, positions, count, queued == 3);
                        }
                    }
                    if (queued && step == 2) {
                        NV2AMetalPendingJournal *before =
                            [draw valueForKey:@"pending"];
                        NSArray *spans = before.retainedStreams;
                        NSUInteger generation = before.generation;
                        Method checkpoint = class_getInstanceMethod(
                            NV2AMetalSurfaceCache.class,
                            @selector(checkpointWithError:));
                        queued_xf_original_checkpoint =
                            (void *)method_setImplementation(
                                checkpoint, (IMP)queued_xf_fail_accept);
                        queued_xf_checkpoint = 0;
                        error = nil;
                        assert(!queued_xf_boundary(action, &error));
                        method_setImplementation(
                            checkpoint, (IMP)queued_xf_original_checkpoint);
                        assert(
                            [error.domain isEqualToString:@"test.queued-xf"] &&
                            queued_xf_checkpoint == 2);
                        assert([draw valueForKey:@"pending"] == before &&
                               before.generation == generation &&
                               [spans isEqual:before.retainedStreams]);
                        assert(!memcmp(original, pg->vertex_attributes,
                                       sizeof(original)) &&
                               pg->compressed_attrs == 0x8011);
                        failedAccepts++;
                    }
                    require(queued_xf_boundary(action, &error), error);
                    assert(
                        !memcmp(original, pg->vertex_attributes,
                                sizeof(original)) &&
                        pg->compressed_attrs == 0x8011 && !pg->draw_time &&
                        !memcmp(constants, pg->vsh_constants,
                                sizeof(constants)) &&
                        !memcmp(dirty, pg->vsh_constants_dirty, sizeof(dirty)));
                    if (action != 2) {
                        /* Repeating the same boundary must not replay an
                         * accepted prefix or introduce a new CPU wait. */
                        NSUInteger generation =
                            [[draw valueForKey:@"pending"] generation];
                        require(queued_xf_boundary(action, &error), error);
                        assert([[draw valueForKey:@"pending"] generation] ==
                               generation);
                    } else
                        assert(![[draw valueForKey:@"pending"] streamCount]);
                    if (!step)
                        for (unsigned v = 0; v < 3; v++)
                            positions[v][0] = positions[v][1] = 8;
                }
                NSData *wire = nil;
                if (queued) {
                    assert(!queued_xf_native_commits &&
                           !queued_xf_native_waits && !gate.signaledValue);
                    memset(positions, 0xa5, sizeof(positions));
                    if (action != 2) {
                        /* The snapshot itself must submit and finish pending
                         * XF before copying bytes into its CPU archive. */
                        wire = [draw pendingSnapshotWithError:&error];
                        require(wire != nil, error);
                        assert(queued_xf_native_commits &&
                               queued_xf_native_waits &&
                               gate.signaledValue == 1);
                    } else {
                        require([surfaces.cache submitWithError:&error], error);
                        assert(![surfaces.cache.commands.lastSubmitted
                            completedWithError:NULL]);
                        gate.signaledValue = 1;
                        require([surfaces.cache waitUntilIdleWithError:&error],
                                error);
                        assert(queued_xf_native_commits &&
                               queued_xf_native_waits);
                    }
                    method_setImplementation(commit,
                                             (IMP)queued_xf_original_commit);
                    method_setImplementation(wait,
                                             (IMP)queued_xf_original_wait);
                    method_setImplementation(
                        receiptWait, (IMP)queued_xf_original_receipt_wait);
                    method_setImplementation(
                        producerWait, (IMP)queued_xf_original_producer_wait);
                    queued_xf_gate_commands = nil;
                    queued_xf_gate_queue = nil;
                    queued_xf_gate = nil;
                } else {
                    require([surfaces.cache submitWithError:&error] &&
                                [surfaces.cache waitUntilIdleWithError:&error],
                            error);
                }
                NSData *data = [NSData data];
                if (action != 2) {
                    if (!wire)
                        wire = [draw pendingSnapshotWithError:&error];
                    require(wire.length > 12, error);
                    NV2AMetalPendingArchive *archive =
                        [[NV2AMetalPendingArchive alloc]
                            initWithData:[wire
                                             subdataWithRange:NSMakeRange(
                                                                  12,
                                                                  wire.length -
                                                                      12)]
                                   limit:64
                                   error:&error];
                    require(archive != nil, error);
                    assert(archive.vertices.count == 1 &&
                           archive.vertices[0].length ==
                               5 * sizeof(NV2AMetalVertex));
                    data = archive.vertices[0];
                }
                if (!queued)
                    reference = data;
                else {
                    assert([reference isEqual:data]);
                    pairs++;
                }
                require([draw discardForRestoreWithError:&error], error);
                qemu_mutex_unlock(&pg->lock);
                read_vram(1024, 256);
                for (unsigned p = 0; p < 64; p++)
                    color(p % 8, p / 8, 0xffff0000);
            }
        }
    queued_constant_raster_tests();
    assert(pairs == 1845 && failedAccepts == 1845 && constantCaptures == 1536 &&
           staticCaptures == 384);
    puts(
        "Queued XF-only:1845 Float32-array/Float4/D3D-byte-array exact GPU "
        "archive "
        "pairs;Fixed/readonly/nonwriting,"
        "direct/zero-IDX/bounded/integer/fractional/clamped-input/"
        "zero-product/fetched-attribute-ARL "
        "relative,USER/FULL,bound/raw/standalone NOP;"
        "zero producer submits/waits "
        "before GPU gate release;"
        "bit-exact Current/populated/compressed/constants/dirty,immutable "
        "prefix/suffix,"
        "1845 rejected checkpoints and retries,1536 immutable constant "
        "captures/restores/changed-constant checks(1152 invalidated,384 static "
        "proofs retained);360 additional MIN/MAX/"
        "SLT/SGE range-boundary pairs,repeat/consume,snapshot and "
        "untouched VRAM PASS");
    groups++;
}
#endif
