/* Submission reduction and ordered partial XF progress across failures.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SHARED_DRAW_H
#define TEST_METAL_SHARED_DRAW_H
#import "hw/xbox/nv2a/pgraph/metal/pending-journal.h"
static unsigned shared_draw_begins, shared_draw_submits, shared_draw_waits;
static id<MTL4CommandBuffer> (*shared_original_begin)(id, SEL, NSError **);
static BOOL (*shared_original_submit)(id, SEL, NSError **);
static BOOL (*shared_original_wait)(id, SEL, NSError **);
static BOOL (*shared_original_submission_wait)(id, SEL, NV2AMetalSubmission *,
                                               NSError **);
static id<MTL4CommandBuffer> shared_begin_count(id object, SEL selector,
                                                NSError **error)
{
    shared_draw_begins++;
    return shared_original_begin(object, selector, error);
}
static BOOL shared_submit_count(id object, SEL selector, NSError **error)
{
    shared_draw_submits++;
    return shared_original_submit(object, selector, error);
}
static BOOL shared_wait_count(id object, SEL selector, NSError **error)
{
    shared_draw_waits++;
    return shared_original_wait(object, selector, error);
}
static BOOL shared_submission_wait_count(id object, SEL selector,
                                         NV2AMetalSubmission *submission,
                                         NSError **error)
{
    shared_draw_waits++;
    return shared_original_submission_wait(object, selector, submission, error);
}
static NV2AMetalEpochEncoding *(*shared_original_encode)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NV2AMetalCommands *, NSError **);
static unsigned shared_encode_calls;
static NV2AMetalEpochEncoding *shared_late_host_failure(
    id object, SEL selector, NV2AMetalPGRAPHVertexState *captured,
    id<MTLBuffer> attributes, NSUInteger first, NSUInteger count,
    NV2AMetalCommands *commands, NSError **error)
{
    if (++shared_encode_calls == 2) {
        if (error)
            *error =
                [NSError errorWithDomain:@"test.shared-XF"
                                    code:7
                                userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"Injected later XF encoding failure"
                                }];
        return nil;
    }
    return shared_original_encode(object, selector, captured, attributes, first,
                                  count, commands, error);
}
static NV2AMetalPixelDraw *shared_cached_raster_failure(
    id object, SEL selector, NV2AMetalGeometryResult *geometry,
    NSUInteger offset, NSUInteger count, const NV2AMetalPixelUniforms *uniforms,
    const NV2AMetalPixelTexture *textures, MTL4RenderPassDescriptor *pass,
    NV2AMetalDrawState *raster, NV2AMetalPixelRasterClass rasterClass,
    BOOL ignore, NV2AMetalCommands *commands, NSError **error)
{
    (void)object;
    (void)selector;
    (void)geometry;
    (void)offset;
    (void)count;
    (void)uniforms;
    (void)textures;
    (void)pass;
    (void)raster;
    (void)rasterClass;
    (void)ignore;
    assert(commands.commandBuffer);
    if (error)
        *error = [NSError errorWithDomain:@"test.cached-producer"
                                     code:1
                                 userInfo:nil];
    return nil;
}
static void shared_cached_producer_tests(void)
{
    for (unsigned mode = 0; mode < 4; mode++) {
        fixture();
        NSError *error = nil;
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
        pg->enable_vertex_program_write = mode == 1 || mode == 2;
        mov(0, 0, 0, false);
        mov(1, 3, 3, true);
        if (mode == 2) {
            mov(0, 3, 20, false);
            pg->program_data[0][3] &= ~(1u << 11);
            mov(1, 0, 0, false);
            mov(2, 3, 3, true);
        } else if (mode == 3) {
            mov(0, 1, 0, false);
            pg->program_data[0][1] = 13u << 21 | 1u << 9 | 27;
            pg->program_data[0][3] = 0;
            mov(1, 0, 0, false);
            mov(2, 0, 3, true);
            pg->program_data[2][1] = 1u << 21 | 96u << 13 | 27;
            pg->program_data[2][2] = 3u << 26;
            pg->program_data[2][3] |= 2;
            const float green[4] = { 0, 1, 0, 1 };
            memcpy(pg->vsh_constants[96], green, 16);
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
        float current[4];
        memcpy(current, pg->vertex_attributes[0].inline_value, 16);
        NV2AMetalCommands *commands = surfaces.cache.commands;
        id<MTLSharedEvent> gate = [commands.device newSharedEvent];
        Ivar ivar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(commands, ivar);
        assert(gate && queue);
        [queue waitForEvent:gate value:1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!gate.signaledValue)
                             gate.signaledValue = 2;
                       });
        Method prepare = class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            @selector(
                prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                rasterClass:ignorePolygonCulling:commands:error:));
        IMP original = method_setImplementation(
            prepare, (IMP)shared_cached_raster_failure);
        id<MTLBuffer> accepted = nil;
        const float changedConstant[4] = { 0, 0, 1, 1 };
        Method submit = class_getInstanceMethod(NV2AMetalCommands.class,
                                                @selector(submitWithError:));
        Method wait = class_getInstanceMethod(
            NV2AMetalCommands.class, @selector(waitUntilIdleWithError:));
        Method receipt = class_getInstanceMethod(
            NV2AMetalCommands.class, @selector(waitForSubmission:error:));
        for (unsigned attempt = 0; attempt < 3; attempt++) {
            if (attempt == 1) {
                shared_original_submit = (void *)method_setImplementation(
                    submit, (IMP)shared_submit_count);
                shared_original_wait = (void *)method_setImplementation(
                    wait, (IMP)shared_wait_count);
                shared_original_submission_wait =
                    (void *)method_setImplementation(
                        receipt, (IMP)shared_submission_wait_count);
                shared_draw_submits = shared_draw_waits = 0;
                if (mode == 2)
                    memcpy(pg->vsh_constants[20], changedConstant, 16);
            }
            error = nil;
            assert(![draw flushDrawWithError:&error] &&
                   [error.domain isEqualToString:@"test.cached-producer"]);
            NV2AMetalPendingJournal *pending = [draw valueForKey:@"pending"];
            assert(pending.retainedStreams.count == 1 &&
                   pending.retainedStreams[0].count == 1);
            NV2AMetalPendingSpan *span = pending.retainedStreams[0][0];
            assert(span.count == 3 && !span.first);
            if (!attempt)
                accepted = span.resource;
            if (!attempt && mode == 2) {
                const float green[4] = { 0, 1, 0, 1 };
                assert(!memcmp(pg->vsh_constants[20], green, 16) &&
                       pg->vsh_constants_dirty[20]);
            }
            assert(span.resource == accepted && !gate.signaledValue &&
                   !commands.commandBuffer &&
                   commands.sealedBufferCount == (mode < 2 ? 1u : 0u) &&
                   !pg->draw_time && !surfaces.color.dirty &&
                   !memcmp(current, pg->vertex_attributes[0].inline_value, 16));
            if (attempt && mode == 2)
                assert(!memcmp(pg->vsh_constants[20], changedConstant, 16));
        }
        method_setImplementation(submit, (IMP)shared_original_submit);
        method_setImplementation(wait, (IMP)shared_original_wait);
        method_setImplementation(receipt, (IMP)shared_original_submission_wait);
        assert(!shared_draw_submits && !shared_draw_waits);
        method_setImplementation(prepare, original);
        gate.signaledValue = 1;
        error = nil;
        require([surfaces.cache submitWithError:&error] &&
                    [surfaces.cache waitUntilIdleWithError:&error],
                error);
        /* Keep frozen vertices while Current reflects the retry's live source.
         */
        cpu_write(16384, 48);
        memset(state->vram_ptr + 16384, 0, 48);
        require([draw endWithError:&error], error);
        const float zero[4] = { 0 };
        assert(pg->draw_time == 1 && commands.sealedBufferCount == 1 &&
               !memcmp(pg->vertex_attributes[0].inline_value, zero, 16));
        if (mode == 2)
            assert(!memcmp(pg->vsh_constants[20], changedConstant, 16));
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        color(1, 1, 0xff00ff00);
    }
    groups++;
    puts("Cached producer:readonly/nonwriting/constant-writing/relative-ARL;"
         "three gated raster failures retain accepted GPU prefix,zero retry "
         "submits/waits and empty producer sections,no context-store replay;"
         "live Current changes after source mutation while frozen green "
         "vertices survive;successful retry uses one raster section PASS");
}
static void shared_draw_contract_tests(void)
{
    shared_cached_producer_tests();
    for (unsigned mode = 0; mode < 3; mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        if (mode) {
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            pg->enable_vertex_program_write = mode == 2;
            mov(0, 0, 0, false);
            mov(1, 3, 3, true);
            if (mode == 2) {
                mov(0,3,20,false);pg->program_data[0][3] &= ~(1u << 11);
                mov(1,0,0,false);mov(2,3,3,true);
            }
        }
        Method begin = class_getInstanceMethod(NV2AMetalCommands.class,
                                               @selector(beginWithError:));
        Method submit = class_getInstanceMethod(NV2AMetalCommands.class,
                                                @selector(submitWithError:));
        Method wait = class_getInstanceMethod(NV2AMetalCommands.class, @selector
                                              (waitUntilIdleWithError:));
        Method submissionWait = class_getInstanceMethod(
            NV2AMetalCommands.class, @selector(waitForSubmission:error:));
        assert(begin && submit && wait && submissionWait);
        shared_original_begin =
            (void *)method_setImplementation(begin, (IMP)shared_begin_count);
        shared_original_submit =
            (void *)method_setImplementation(submit, (IMP)shared_submit_count);
        shared_original_wait =
            (void *)method_setImplementation(wait, (IMP)shared_wait_count);
        shared_original_submission_wait = (void *)method_setImplementation(
            submissionWait, (IMP)shared_submission_wait_count);
        shared_draw_begins = shared_draw_submits = shared_draw_waits = 0;
        render();
        fflush(stdout);
        assert(shared_draw_submits == (mode == 2 ? 1u : 0u) &&
               shared_draw_begins == (mode ? 2u : 1u) &&
               shared_draw_waits == (mode == 2 ? 1u : 0u) &&
               surfaces.cache.commands.sealedBufferCount ==
                   (mode == 1 ? 2u : 1u));
        NSError *rasterError = nil;
        qemu_mutex_lock(&pg->lock);
        require([surfaces.cache submitWithError:&rasterError], rasterError);
        qemu_mutex_unlock(&pg->lock);
        method_setImplementation(begin, (IMP)shared_original_begin);
        method_setImplementation(submit, (IMP)shared_original_submit);
        method_setImplementation(wait, (IMP)shared_original_wait);
        method_setImplementation(submissionWait,
                                 (IMP)shared_original_submission_wait);
        assert(shared_draw_submits == (mode == 2 ? 2u : 1u));
        assert(shared_draw_waits == (mode == 2 ? 1u : 0u));
        assert(shared_draw_begins == (mode ? 2u : 1u));
        assert(pg->vertex_attributes[0].inline_value[0] == 0 &&
               pg->vertex_attributes[0].inline_value[1] == 8);
        read_vram(1024, 256);
        color(1, 1, 0xff00ff00);
    }
    for (unsigned mode = 0; mode < 2; mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = 2;
        pg->draw_arrays_start[0] = 0;
        pg->draw_arrays_count[0] = 3;
        pg->draw_arrays_start[1] = 3;
        pg->draw_arrays_count[1] = 3;
        float positions[6][4] = { { 0, 0, 32768, 1 }, { 4, 0, 32768, 1 },
                                  { 0, 4, 32768, 1 }, { 4, 4, 32768, 1 },
                                  { 8, 4, 32768, 1 }, { 4, 8, 32768, 1 } };
        cpu_write(16384, sizeof(positions));
        memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
        if (mode) {
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            pg->enable_vertex_program_write = false;
            pg->vertex_attributes[1] = (VertexAttribute){
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                .count = 1,
                .size = 4,
                .stride = 4,
                .offset = 256
            };
            const float addresses[6] = { 0, 0, 0, 1000, 1000, 1000 };
            cpu_write(16384 + 256, sizeof(addresses));
            memcpy(state->vram_ptr + 16384 + 256, addresses, sizeof(addresses));
            mov(0, 0, 0, false);
            mov(1, 1, 0, false);
            pg->program_data[1][1] = 13u << 21 | 1u << 9 | 27;
            pg->program_data[1][3] = 0;
            mov(2, 0, 3, true);
            pg->program_data[2][1] = 1u << 21 | 96u << 13 | 27;
            pg->program_data[2][2] = 3u << 26;
            pg->program_data[2][3] |= 2;
            const float green[4] = { 0, 1, 0, 1 };
            memcpy(pg->vsh_constants[96], green, 16);
        }
        float current[4];
        memcpy(current, pg->vertex_attributes[0].inline_value, 16);
        NSError *error = nil;
        Method encode = class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:commands:error:));
        if (!mode) {
            shared_original_encode = (void *)method_setImplementation(
                encode, (IMP)shared_late_host_failure);
            shared_encode_calls = 0;
        }
        qemu_mutex_lock(&pg->lock);
        BOOL ok = [draw drawWithError:&error];
        qemu_mutex_unlock(&pg->lock);
        if (!mode)
            method_setImplementation(encode, (IMP)shared_original_encode);
        assert(!ok && error && !pg->draw_time && !surfaces.color.dirty);
        assert([error.localizedDescription
            containsString:mode ? @"address fault" : @"Injected later"]);
        assert(!memcmp(current, pg->vertex_attributes[0].inline_value, 16));
        NV2AMetalPendingJournal *pending = [draw valueForKey:@"pending"];
        assert(pending.retainedStreams.count >= 1);
        NSArray<NV2AMetalPendingSpan *> *leading = pending.retainedStreams[0];
        assert(leading.count == 1 && leading[0].count == 3);
        if (!mode) {
            memset(positions, 0, 3 * sizeof(positions[0]));
            cpu_write(16384, 3 * sizeof(positions[0]));
            memcpy(state->vram_ptr + 16384, positions,
                   3 * sizeof(positions[0]));
        } else {
            float zero[6] = { 0 };
            cpu_write(16384 + 256, sizeof(zero));
            memcpy(state->vram_ptr + 16384 + 256, zero, sizeof(zero));
            const float blue[4] = { 0, 0, 1, 1 };
            memcpy(pg->vsh_constants[96], blue, 16);
            pg->vsh_constants_dirty[96] = true;
        }
        render();
        read_vram(1024, 256);
        color(1, 1, 0xff00ff00);
        color(5, 5, mode ? 0xff0000ff : 0xff00ff00);
    }
    puts("Shared Draw: fixed/readonly zero producer submit/wait;writable one "
         "submit/wait plus "
         "deferred raster checkpoint and explicit commit; "
         "Current/pixels, host/GPU late-failure prefix retention and immutable "
         "retry colors PASS");
}
#endif
