/* XF-only producer batching, completion scope and ordered retry contracts.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_XF_ONLY_SUBMIT_H
#define TEST_METAL_XF_ONLY_SUBMIT_H
#import "hw/xbox/nv2a/pgraph/metal/archive-native.h"
#import "hw/xbox/nv2a/pgraph/metal/fetch-pgraph.h"

static NV2AMetalEpochEncoding *(*xf_only_original_encode)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NV2AMetalCommands *, NSError **);
static NSMutableArray *xf_only_encodings;
static unsigned xf_only_case, xf_only_calls;
static BOOL xf_only_testing, xf_only_future;
static NV2AMetalEpochEncoding *
xf_only_capture(id object, SEL selector, NV2AMetalPGRAPHVertexState *vertex,
                id<MTLBuffer> attributes, NSUInteger first, NSUInteger count,
                NV2AMetalCommands *commands, NSError **error)
{
    if (xf_only_testing && ++xf_only_calls == 2 &&
        (xf_only_case == 2 || xf_only_case == 3 || xf_only_case == 5)) {
        if (error)
            *error = [NSError errorWithDomain:@"test.xf-only"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Later XF-only host failure"
                                     }];
        return nil;
    }
    NV2AMetalEpochEncoding *result = xf_only_original_encode(
        object, selector, vertex, attributes, first, count, commands, error);
    if (result)
        [xf_only_encodings
            addObject:@[ vertex, attributes, @(first), @(count) ]];
    return result;
}

static NV2AMetalEpochEncoding *(*xf_only_original_serial)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NV2AMetalEpochEncoding *, NV2AMetalCommands *, NSError **);
static NV2AMetalEpochEncoding *
xf_only_serial_capture(id object, SEL selector,
                       NV2AMetalPGRAPHVertexState *vertex,
                       id<MTLBuffer> attributes, NSUInteger first,
                       NSUInteger count, NV2AMetalEpochEncoding *previous,
                       NV2AMetalCommands *commands, NSError **error)
{
    if (xf_only_testing && ++xf_only_calls == 2 &&
        (xf_only_case == 2 || xf_only_case == 3 || xf_only_case == 5)) {
        if (error)
            *error = [NSError errorWithDomain:@"test.xf-only"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Later XF-only host failure"
                                     }];
        return nil;
    }
    return xf_only_original_serial(object, selector, vertex, attributes, first,
                                   count, previous, commands, error);
}
static void xf_only_submit_tests(void)
{
    unsigned cases = 0;
    const unsigned rangeCounts[] = { 2, 1, 4 };
    for (unsigned raw = 0; raw < 2; raw++)
        for (unsigned mode = 0; mode < 3; mode++)
            for (unsigned kind = 0; kind < 4; kind++)
                for (unsigned r = 0; r < (kind ? 1u : 3u); r++) {
                    fixture();
                    NSError *error = nil;
                    PGRAPHState *pg = &state->pgraph;
                    unsigned ranges = kind ? 1 : rangeCounts[r];
                    unsigned count = 3 * ranges;
                    if (mode)
                        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
                    pg->enable_vertex_program_write = mode == 2;
                    feedback_program(191, 15);
                    float positions[12][4];
                    for (unsigned v = 0; v < 12; v++) {
                        positions[v][0] = (v % 3) == 1 ? 8 : 0;
                        positions[v][1] = (v % 3) == 2 ? 8 : 0;
                        positions[v][2] = 32768;
                        positions[v][3] = 1;
                    }
                    cpu_write(16384, sizeof(positions));
                    memcpy(state->vram_ptr + 16384, positions,
                           sizeof(positions));
                    pg->draw_arrays_length = kind ? 0 : ranges;
                    for (unsigned i = 0; i < ranges; i++) {
                        pg->draw_arrays_start[i] = 3 * i;
                        pg->draw_arrays_count[i] = 3;
                    }
                    if (kind == 1) {
                        pg->inline_elements_length = count;
                        for (unsigned i = 0; i < count; i++)
                            pg->inline_elements[i] = i;
                    } else if (kind == 2) {
                        pg->inline_buffer_length = count;
                        pg->vertex_attributes[0].inline_buffer =
                            &positions[0][0];
                        pg->vertex_attributes[0].inline_buffer_populated = true;
                        pg->compressed_attrs = 1;
                    } else if (kind == 3) {
                        pg->inline_array_length = 4 * count;
                        memcpy(pg->inline_array, positions, count * 16);
                    }
                    if (raw) {
                        pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
                        pg->surface_shape = (SurfaceShape){ 0 };
                        pg->surface_binding_dim.width =
                            pg->surface_binding_dim.height = 0;
                    }
                    qemu_mutex_lock(&pg->lock);
                    require([draw beginWithError:&error], error);
                    require([surfaces.cache submitWithError:&error], error);
                    require([surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    VertexAttribute original[16];
                    memcpy(original, pg->vertex_attributes, sizeof(original));
                    uint16_t compressed = pg->compressed_attrs;
                    NSData *snapshot = draw.vertexSnapshot;
                    Method begin = class_getInstanceMethod(
                        NV2AMetalCommands.class, @selector(beginWithError:));
                    Method submit = class_getInstanceMethod(
                        NV2AMetalCommands.class, @selector(submitWithError:));
                    Method wait = class_getInstanceMethod(
                        NV2AMetalCommands.class,
                        @selector(waitUntilIdleWithError:));
                    Method receiptWait = class_getInstanceMethod(
                        NV2AMetalCommands.class,
                        @selector(waitForSubmission:error:));
                    Method encode = class_getInstanceMethod(
                        NV2AMetalEpochExecutor.class,
                        @selector(encodeRasterState:attributeBuffer:first:count:
                                  commands:error:));
                    shared_original_begin = (void *)method_setImplementation(
                        begin, (IMP)shared_begin_count);
                    shared_original_submit = (void *)method_setImplementation(
                        submit, (IMP)shared_submit_count);
                    shared_original_wait = (void *)method_setImplementation(
                        wait, (IMP)shared_wait_count);
                    shared_original_submission_wait =
                        (void *)method_setImplementation(
                            receiptWait, (IMP)shared_submission_wait_count);
                    xf_only_original_encode = (void *)method_setImplementation(
                        encode, (IMP)xf_only_capture);
                    xf_only_encodings = [NSMutableArray new];
                    shared_draw_begins = shared_draw_submits =
                        shared_draw_waits = 0;
                    require([draw prepareVertexStateChangeWithError:&error],
                            error);
                    unsigned submits = shared_draw_submits,
                             waits = shared_draw_waits;
                    require([draw prepareVertexStateChangeWithError:&error],
                            error);
                    assert(shared_draw_submits == submits &&
                           shared_draw_waits == waits);
                    method_setImplementation(begin, (IMP)shared_original_begin);
                    method_setImplementation(submit,
                                             (IMP)shared_original_submit);
                    method_setImplementation(wait, (IMP)shared_original_wait);
                    method_setImplementation(
                        receiptWait, (IMP)shared_original_submission_wait);
                    method_setImplementation(encode,
                                             (IMP)xf_only_original_encode);
                    printf("XF-only producer:raw%u mode%u kind%u ranges%u "
                           "submits%u waits%u\n",
                           raw, mode, kind, ranges, submits, waits);
                    fflush(stdout);
                    BOOL queued = mode < 2;
                    assert(submits == (queued ? 0u : 1u));
                    assert(waits == (queued ? 0u : 1u));
                    assert(!memcmp(original, pg->vertex_attributes,
                                   sizeof(original)) &&
                           pg->compressed_attrs == compressed &&
                           !pg->draw_time &&
                           !surfaces.cache.commands.commandBuffer);
                    expect_context(191, 15, count, mode == 2);
                    if (queued)
                        require([surfaces.cache submitWithError:&error] &&
                                    [surfaces.cache waitUntilIdleWithError:&error], error);
                    if (mode != 2) {
                        assert([snapshot isEqualToData:draw.vertexSnapshot]);
                        assert(xf_only_encodings.count == ranges);
                        NV2AMetalPendingJournal *pending =
                            [draw valueForKey:@"pending"];
                        assert(pending.retainedStreams.count == ranges);
                        NV2AMetalEpochExecutor *executor =
                            [draw valueForKey:@"epoch"];
                        NV2AMetalPendingArchive *discarded =
                            raw ?
                                nv2a_metal_pending_capture(
                                    pending, surfaces.cache.commands, &error) :
                                nil;
                        if (raw)
                            require(discarded != nil, error);
                        for (unsigned i = 0; i < ranges; i++) {
                            NSArray *item = xf_only_encodings[i];
                            NV2AMetalEpochResult *reference = [executor
                                   executeState:item[0]
                                attributeBuffer:item[1]
                                          first:[item[2] unsignedIntegerValue]
                                          count:[item[3] unsignedIntegerValue]
                                          error:&error];
                            require(reference != nil, error);
                            NSArray<NV2AMetalPendingSpan *> *spans =
                                pending.retainedStreams[i];
                            assert(spans.count == 1 &&
                                   spans[0].count == reference.vertexCount);
                            if (discarded) {
                                assert([spans[0].resource
                                    isMemberOfClass:NV2AMetalDiscardedVertices
                                                        .class]);
                                assert(((NV2AMetalDiscardedVertices *)spans[0]
                                            .resource)
                                           .count == spans[0].count);
                                assert(!memcmp(discarded.vertices[i].bytes,
                                               reference.vertices.contents,
                                               reference.vertexCount *
                                                   sizeof(NV2AMetalVertex)));
                            } else {
                                id<MTLBuffer> buffer = spans[0].resource;
                                assert(
                                    !memcmp((const uint8_t *)buffer.contents +
                                                spans[0].first *
                                                    sizeof(NV2AMetalVertex),
                                            reference.vertices.contents,
                                            reference.vertexCount *
                                                sizeof(NV2AMetalVertex)));
                            }
                        }
                    }
                    xf_only_encodings = nil;
                    require([draw discardForRestoreWithError:&error], error);
                    qemu_mutex_unlock(&pg->lock);
                    read_vram(1024, 256);
                    for (unsigned i = 0; i < 64; i++)
                        color(i % 8, i / 8, 0xffff0000);
                    cases++;
                }
    assert(cases == 36);
    groups++;
    puts("XF-only producer:36 bound/raw,fixed/readonly/writable,four-input "
         "cases;"
         "zero submit/wait for known Current/context;context writers one "
         "submit/wait,serial GPU context chain,prefix "
         "no-replay,exact "
         "full-GPU vertices,"
         "Current/populated/compressed/constants and untouched VRAM PASS");
}
static NV2AMetalEpochResult *(*xf_only_original_resolve)(id, SEL, NSError **);
static BOOL (*xf_only_original_complete)(id, SEL, NSError **);
static id<MTLSharedEvent> xf_only_gate;
static id<MTLBuffer> xf_only_destination;
static NV2AMetalEpochResult *xf_only_resolve(id object, SEL selector,
                                             NSError **error)
{
    if (xf_only_testing && !xf_only_future && xf_only_case != 5) {
        xf_only_future = YES;
        require([surfaces.cache prepareGPUReadAtAddress:60000
                                                 length:4
                                                  error:error],
                *error);
        NV2AMetalCommands *commands = surfaces.cache.commands;
        Ivar queueIvar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
        assert(queue && commands.commandBuffer);
        [queue waitForEvent:xf_only_gate value:1];
        require([commands addResource:xf_only_destination error:error], *error);
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        assert(encoder);
        [encoder barrierAfterQueueStages:MTLStageAll
                            beforeStages:MTLStageBlit
                       visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder copyFromBuffer:surfaces.cache.vram
                   sourceOffset:60000
                       toBuffer:xf_only_destination
              destinationOffset:0
                           size:4];
        [encoder barrierAfterStages:MTLStageBlit
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
        require([surfaces.cache submitWithError:error], *error);
        id<MTLSharedEvent> gate = xf_only_gate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         gate.signaledValue = 1;
                       });
    }
    return xf_only_original_resolve(object, selector, error);
}
static BOOL xf_only_complete(id object, SEL selector, NSError **error)
{
    if (xf_only_testing && xf_only_case == 5) {
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            [object valueForKey:@"encodedBatches"];
        assert(batches.count == 2);
        NV2AMetalFetchResult *result = batches[0].fetch;
        NV2AMetalCommands *commands = [object encodingCommands];
        id<MTLBuffer> source =
            [commands.device newBufferWithLength:4
                                         options:MTLResourceStorageModeShared];
        assert(source && commands.commandBuffer);
        *(uint32_t *)source.contents = 1;
        require([commands addResource:source error:error], *error);
        require([commands addResource:result.faults error:error], *error);
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        assert(encoder);
        [encoder barrierAfterQueueStages:MTLStageAll
                            beforeStages:MTLStageBlit
                       visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder copyFromBuffer:source
                   sourceOffset:0
                       toBuffer:result.faults
              destinationOffset:0
                           size:4];
        [encoder copyFromBuffer:source
                   sourceOffset:0
                       toBuffer:result.faults
              destinationOffset:result.faultSummaryOffset
                           size:4];
        [encoder barrierAfterStages:MTLStageBlit
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
    }
    return xf_only_original_complete(object, selector, error);
}
static void xf_only_failure_case(unsigned writable)
{
    for (xf_only_case = 0; xf_only_case < 6; xf_only_case++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->enable_vertex_program_write = writable;
        if (writable || xf_only_case == 1 || xf_only_case >= 3) {
            pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
            mov(0, 0, 0, false);
            mov(1, 3, 3, true);
        }
        pg->draw_arrays_length = 2;
        pg->draw_arrays_start[1] = 3;
        pg->draw_arrays_count[1] = 3;
        cpu_write(16384, 96);
        memcpy(state->vram_ptr + 16384 + 48, state->vram_ptr + 16384, 48);
        float addresses[6] = { 0, 0, 0, 1000, 0, 0 };
        if (xf_only_case == 4) {
            pg->vertex_attributes[1] = (VertexAttribute){
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                .count = 1,
                .size = 4,
                .stride = 4,
                .offset = 256
            };
            cpu_write(16384 + 256, sizeof(addresses));
            memcpy(state->vram_ptr + 16384 + 256, addresses, sizeof(addresses));
            mov(1, 1, 0, false);
            pg->program_data[1][1] = 13u << 21 | 1u << 9 | 27;
            pg->program_data[1][3] = 0;
            mov(2, 0, 3, true);
            pg->program_data[2][1] = 1u << 21 | 96u << 13 | 27;
            pg->program_data[2][2] = 3u << 26;
            pg->program_data[2][3] |= 2;
        }
        cpu_write(60000, 4);
        stl_le_p(state->vram_ptr + 60000, 0x12345678);
        xf_only_gate = [surfaces.cache.commands.device newSharedEvent];
        xf_only_destination = [surfaces.cache.commands.device
            newBufferWithLength:4
                        options:MTLResourceStorageModeShared];
        assert(xf_only_gate && xf_only_destination);
        *(uint32_t *)xf_only_destination.contents = 0;
        NSError *error = nil;
        qemu_mutex_lock(&pg->lock);
        require([draw beginWithError:&error], error);
        /* A real pending GPU destination makes Current require feedback.
         * Keep this failure-order suite on that path for fixed and readonly XF.
         */
        id<MTLBuffer> currentSource = [surfaces.cache.commands.device
            newBufferWithBytes:state->vram_ptr + 16384 + 5 * 16
                        length:16
                       options:MTLResourceStorageModeShared];
        assert(currentSource);
        require([surfaces.cache prepareGPUWriteAtAddress:16384 + 5 * 16
                                                  length:16
                                                   error:&error],
                error);
        require([surfaces.cache.commands addResource:currentSource
                                               error:&error],
                error);
        id<MTL4ComputeCommandEncoder> writer =
            [surfaces.cache.commands.commandBuffer computeCommandEncoder];
        assert(writer);
        [writer copyFromBuffer:currentSource
                  sourceOffset:0
                      toBuffer:surfaces.cache.vram
             destinationOffset:16384 + 5 * 16
                          size:16];
        [writer endEncoding];
        VertexAttribute original[16];
        memcpy(original, pg->vertex_attributes, sizeof(original));
        Method encode = class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(
                encodeRasterState:attributeBuffer:first:count:commands:error:));
        Method resolve = class_getInstanceMethod(NV2AMetalEpochEncoding.class,
                                                 @selector(resolveWithError:));
        Method complete = class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class, @selector(completeWithError:));
        xf_only_original_encode =
            (void *)method_setImplementation(encode, (IMP)xf_only_capture);
        Method serial = class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:commands:error:));
        xf_only_original_serial = (void *)method_setImplementation(
            serial, (IMP)xf_only_serial_capture);
        xf_only_original_resolve =
            (void *)method_setImplementation(resolve, (IMP)xf_only_resolve);
        xf_only_original_complete =
            (void *)method_setImplementation(complete, (IMP)xf_only_complete);
        xf_only_encodings = [NSMutableArray new];
        xf_only_testing = YES;
        xf_only_future = NO;
        xf_only_calls = 0;
        BOOL ok = [draw prepareVertexStateChangeWithError:&error];
        xf_only_testing = NO;
        method_setImplementation(encode, (IMP)xf_only_original_encode);
        method_setImplementation(serial, (IMP)xf_only_original_serial);
        method_setImplementation(resolve, (IMP)xf_only_original_resolve);
        method_setImplementation(complete, (IMP)xf_only_original_complete);
        assert(!memcmp(original, pg->vertex_attributes, sizeof(original)) &&
               !pg->draw_time);
        assert(ok == (xf_only_case < 2));
        if (!ok)
            assert(error &&
                   [error.localizedDescription
                       containsString:xf_only_case == 5 ? @"vertex fetch" :
                                      xf_only_case == 4 ? @"address fault" :
                                                          @"Later XF-only"]);
        NV2AMetalPendingJournal *pending = [draw valueForKey:@"pending"];
        assert(pending.retainedStreams.count == (xf_only_case < 2  ? 2u :
                                                 xf_only_case == 5 ? 0u :
                                                                     1u));
        NSData *prefix = nil;
        if (pending.retainedStreams.count) {
            NV2AMetalPendingSpan *span = pending.retainedStreams[0][0];
            id<MTLBuffer> buffer = span.resource;
            prefix =
                [NSData dataWithBytes:(const uint8_t *)buffer.contents +
                                      span.first * sizeof(NV2AMetalVertex)
                               length:span.count * sizeof(NV2AMetalVertex)];
        }
        if (xf_only_case != 5) {
            assert(xf_only_future && !xf_only_gate.signaledValue &&
                   !*(uint32_t *)xf_only_destination.contents);
            xf_only_gate.signaledValue = 1;
            require([surfaces.cache waitUntilIdleWithError:&error], error);
            assert(*(uint32_t *)xf_only_destination.contents == 0x12345678);
        } else
            assert(!xf_only_future);
        if (!ok) {
            if (prefix) {
                NSData *vertices = draw.vertexSnapshot;
                NSData *bound = [draw beginSnapshotWithError:&error];
                NSData *saved = [draw pendingSnapshotWithError:&error];
                require(bound && saved, error);
                require([draw discardForRestoreWithError:&error], error);
                require([draw restoreVertexSnapshot:vertices error:&error],
                        error);
                require([draw restoreBeginSnapshot:bound error:&error], error);
                require([draw restorePendingSnapshot:saved error:&error],
                        error);
                require([draw beginWithError:&error], error);
                cpu_write(16384, 48);
                memset(state->vram_ptr + 16384, 0, 48);
            }
            if (xf_only_case == 4) {
                memset(addresses, 0, sizeof(addresses));
                cpu_write(16384 + 256, sizeof(addresses));
                memcpy(state->vram_ptr + 16384 + 256, addresses,
                       sizeof(addresses));
            }
            error = nil;
            require([draw prepareVertexStateChangeWithError:&error], error);
            pending = [draw valueForKey:@"pending"];
            assert(pending.retainedStreams.count == 2 &&
                   !memcmp(original, pg->vertex_attributes, sizeof(original)));
            if (prefix) {
                /* Snapshot helpers own their command recording. The retry may
                 * now leave readonly DMA output queued in the surface cache. */
                require([surfaces.cache submitWithError:&error] &&
                            [surfaces.cache waitUntilIdleWithError:&error],
                        error);
                NV2AMetalPendingArchive *captured = nv2a_metal_pending_capture(
                    pending, surfaces.cache.commands, &error);
                require(captured != nil, error);
                assert([prefix isEqualToData:captured.vertices[0]]);
            }
        }
        require([draw discardForRestoreWithError:&error], error);
        qemu_mutex_unlock(&pg->lock);
        xf_only_encodings = nil;
        xf_only_gate = nil;
        xf_only_destination = nil;
        read_vram(1024, 256);
        color(1, 1, 0xffff0000);
    }
}
static void xf_only_failure_tests(void)
{
    xf_only_failure_case(0);
    xf_only_failure_case(1);
    groups++;
    puts("XF-only completion:12 fixed/readonly/writable "
         "gated-success/late-host/GPU/fetch-priority "
         "cases;later submission not drained,captured prefix survives "
         "restore/source edits,Current preserved and eight retries PASS");
}
#endif
