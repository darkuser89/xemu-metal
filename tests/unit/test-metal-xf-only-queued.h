/* XF-only metadata and queued GPU ownership across state/restore boundaries.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_XF_ONLY_QUEUED_H
#define TEST_METAL_XF_ONLY_QUEUED_H
#include "test-metal-range-idx.h"
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
    Token t[8];
    unsigned count = 0, base = kind == 1              ? 97 :
                               kind == 4 || kind == 6 ? 95 :
                                                        96;
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
}
static BOOL constant_raster_requires_completion(id object, SEL selector)
{
    (void)object;
    (void)selector;
    return NO;
}
static void queued_constant_raster_tests(void)
{
    NSError *error = nil;
    unsigned pairs = 0;
    for (unsigned kind = 0; kind < 8; kind++)
        for (unsigned policy = 0; policy < 4; policy++)
            for (unsigned converted = 0; converted < 2; converted++) {
                NSData *reference = nil;
                for (unsigned gated = 0; gated < 2; gated++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    pg->regs_[NV_PGRAPH_CSV0_D] =
                        2u << 30 |
                        (policy & 1 ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0);
                    pg->enable_vertex_program_write = policy & 2;
                    queued_xf_constant_program(pg, kind);
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
                    }
                    qemu_mutex_lock(&pg->lock);
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
                    if (gated) {
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
                        submit, (IMP)shared_submit_count);
                    shared_original_wait = (void *)method_setImplementation(
                        wait, (IMP)shared_wait_count);
                    shared_original_submission_wait =
                        (void *)method_setImplementation(
                            receipt, (IMP)shared_submission_wait_count);
                    shared_draw_submits = shared_draw_waits = 0;
                    Method proof = class_getInstanceMethod(
                        NV2AMetalPGRAPHVertexState.class,
                        @selector(faultFreeReadOnlyAccess));
                    IMP originalProof =
                        gated ? NULL :
                                method_setImplementation(
                                    proof,
                                    (IMP)constant_raster_requires_completion);
                    @try {
                        require([draw endWithError:&error], error);
                        assert(
                            pg->draw_time == 1 &&
                            (gated ?
                                 (!shared_draw_submits && !shared_draw_waits) :
                                 (shared_draw_submits && shared_draw_waits)) &&
                            !gate.signaledValue &&
                            !memcmp(constants, pg->vsh_constants,
                                    sizeof(constants)));
                        const float last[4] = { 0, 8, 32768, 1 };
                        assert(!memcmp(pg->vertex_attributes[0].inline_value,
                                       last, 16));
                        if (gated) {
                            unsigned row = kind == 4 ? 58 : 100;
                            for (unsigned lane = 0; lane < 4; lane++)
                                memcpy(&pg->vsh_constants[row][lane],
                                       &(uint32_t){ 0x7fc12345 }, 4);
                        }
                        unsigned submitted = shared_draw_submits,
                                 waited = shared_draw_waits;
                        require([surfaces.cache submitWithError:&error], error);
                        assert(shared_draw_submits == submitted + 1 &&
                               shared_draw_waits == waited);
                        if (gated) {
                            assert(!gate.signaledValue &&
                                   ![commands.lastSubmitted
                                       completedWithError:NULL]);
                            gate.signaledValue = 1;
                        }
                    } @finally {
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
                    color(1, 1,
                          kind == 0 || kind == 2 || kind == 6 || kind == 7 ?
                              0xff0000ff :
                              0xff00ff00);
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
    assert(pairs == 64);
    puts("Constant IDX raster:64 exact 256-byte frame pairs/128 actual draws;"
         "eight ARL/ADD/MUL/relative/paired-ILU programs,USER/FULL,write "
         "flag0/1,"
         "DMA Float4/converted inline;forced completion reference versus "
         "64 GPU-gated draws with zero producer "
         "submits/waits,immediate exact Current,NaN live-constant mutation "
         "isolated until GPU completion,explicit blue/green/red pixels PASS");
    groups++;
}

static void queued_xf_tests(void)
{
    NSError *error = nil;
    unsigned pairs = 0, failedAccepts = 0;
    unsigned constantCaptures = 0;
    for (unsigned mode = 0; mode < 105; mode++)
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
                    if (mode >= 73)
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
                if (mode >= 73) {
                    NV2AMetalPGRAPHVertexState *capture =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initRawXFWithState:pg
                                         error:&error];
                    require(capture != nil, error);
                    assert(capture.faultFreeReadOnlyAccess &&
                           ![capture.validatedProgram
                               hasFaultFreeReadOnlyAccess:capture.fullAccess]);
                    NV2AMetalPGRAPHVertexState *restored =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithSnapshot:capture.snapshotData
                                       error:&error];
                    require(restored != nil, error);
                    assert(restored.faultFreeReadOnlyAccess);
                    NV2AMetalProgramUniforms changed = capture.programUniforms;
                    unsigned row = (mode - 73) / 4 == 4 ? 58 : 100;
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
                    assert(!invalid.faultFreeReadOnlyAccess &&
                           capture.faultFreeReadOnlyAccess &&
                           restored.faultFreeReadOnlyAccess);
                    NV2AMetalPGRAPHVertexState *invalidRestored =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithSnapshot:invalid.snapshotData
                                       error:&error];
                    require(invalidRestored != nil, error);
                    assert(!invalidRestored.faultFreeReadOnlyAccess);
                    constantCaptures++;
                }
                VertexAttribute original[16];
                memcpy(original, pg->vertex_attributes, sizeof(original));
                uint32_t constants[192][4];
                memcpy(constants, pg->vsh_constants, sizeof(constants));
                uint8_t dirty[sizeof(pg->vsh_constants_dirty)];
                memcpy(dirty, pg->vsh_constants_dirty, sizeof(dirty));
                id<MTLSharedEvent> gate = nil;
                Method submit = class_getInstanceMethod(
                    NV2AMetalCommands.class, @selector(submitWithError:));
                Method wait =
                    class_getInstanceMethod(NV2AMetalCommands.class,
                                            @selector(waitUntilIdleWithError:));
                Method receiptWait = class_getInstanceMethod(
                    NV2AMetalCommands.class,
                    @selector(waitForSubmission:error:));
                if (queued) {
                    gate = [surfaces.cache.commands.device newSharedEvent];
                    Ivar queueIvar = class_getInstanceVariable(
                        NV2AMetalCommands.class, "_queue");
                    id<MTL4CommandQueue> queue =
                        object_getIvar(surfaces.cache.commands, queueIvar);
                    assert(gate && queue);
                    [queue waitForEvent:gate value:1];
                    id<MTLSharedEvent> watchdog = gate;
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                          if (!watchdog.signaledValue)
                              watchdog.signaledValue = 2;
                        });
                    shared_original_submit = (void *)method_setImplementation(
                        submit, (IMP)shared_submit_count);
                    shared_original_wait = (void *)method_setImplementation(
                        wait, (IMP)shared_wait_count);
                    shared_original_submission_wait =
                        (void *)method_setImplementation(
                            receiptWait, (IMP)shared_submission_wait_count);
                    shared_draw_submits = shared_draw_waits = 0;
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
                    assert(!shared_draw_submits && !shared_draw_waits &&
                           !gate.signaledValue);
                    memset(positions, 0xa5, sizeof(positions));
                    if (action != 2) {
                        /* The snapshot itself must submit and finish pending
                         * XF before copying bytes into its CPU archive. */
                        id<MTLSharedEvent> release = gate;
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW,
                                          20 * NSEC_PER_MSEC),
                            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                              release.signaledValue = 1;
                            });
                        wire = [draw pendingSnapshotWithError:&error];
                        require(wire != nil, error);
                        assert(shared_draw_submits && shared_draw_waits &&
                               gate.signaledValue == 1);
                    } else {
                        require([surfaces.cache submitWithError:&error], error);
                        assert(![surfaces.cache.commands.lastSubmitted
                            completedWithError:NULL]);
                        gate.signaledValue = 1;
                        require([surfaces.cache waitUntilIdleWithError:&error],
                                error);
                    }
                    method_setImplementation(submit,
                                             (IMP)shared_original_submit);
                    method_setImplementation(wait, (IMP)shared_original_wait);
                    method_setImplementation(
                        receiptWait, (IMP)shared_original_submission_wait);
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
    assert(pairs == 945 && failedAccepts == 945 && constantCaptures == 384);
    puts("Queued XF-only:945 Float32-array/Float4/D3D-byte-array exact GPU "
         "archive "
         "pairs;Fixed/readonly/nonwriting,"
         "direct/zero-IDX/bounded/integer/zero-product-ARL "
         "relative,USER/FULL,bound/raw/standalone NOP;"
         "zero producer submits/waits "
         "before GPU gate release;"
         "bit-exact Current/populated/compressed/constants/dirty,immutable "
         "prefix/suffix,"
         "945 rejected checkpoints and retries,384 immutable constant "
         "captures/restores/changed-constant proof invalidations;288 "
         "constant-dependent ARL pairs,360 additional MIN/MAX/"
         "SLT/SGE range-boundary pairs,repeat/consume,snapshot and "
         "untouched VRAM PASS");
    groups++;
}
#endif
