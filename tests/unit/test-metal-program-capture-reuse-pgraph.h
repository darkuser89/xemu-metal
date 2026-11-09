/* CPU-only program witnesses, with fresh real PGRAPH captures and GPU work.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PROGRAM_CAPTURE_REUSE_PGRAPH_H
#define TEST_METAL_PROGRAM_CAPTURE_REUSE_PGRAPH_H

typedef struct ProgramCaptureGPUWork {
    BOOL reference;
    NSUInteger captures, validations, tokenCopies, tokenBytes, witnesses;
    __unsafe_unretained NSMutableArray *states;
    __unsafe_unretained NSMutableArray *encodings;
} ProgramCaptureGPUWork;
static _Thread_local ProgramCaptureGPUWork *pcg_work;
static _Thread_local BOOL pcg_capturing;
static _Thread_local const void *pcg_token_pointer;
static _Thread_local NSUInteger pcg_token_length;
static id (*pcg_witness_original)(id, SEL);
static id (*pcg_data_original)(id, SEL, const void *, NSUInteger);
static id pcg_witness(id owner, SEL selector)
{
    if (pcg_work && owner == draw) {
        pcg_work->witnesses++;
        if (pcg_work->reference)
            return nil; /* Leave every original active-previous route intact. */
    }
    return pcg_witness_original(owner, selector);
}
static id pcg_data(id owner, SEL selector, const void *bytes, NSUInteger length)
{
    if (pcg_work && pcg_token_pointer == bytes && pcg_token_length == length) {
        pcg_work->tokenCopies++;
        pcg_work->tokenBytes += length;
    }
    return pcg_data_original(owner, selector, bytes, length);
}
@interface NV2AMetalPGRAPHVertexState (ProgramCaptureGPUCount)
- (instancetype)pcg_initWithState:(PGRAPHState *)pg
                          unbound:(BOOL)unbound
                    rasterDiscard:(BOOL)discard
               reusingProgramFrom:(NV2AMetalPGRAPHVertexState *)previous
                            error:(NSError **)error
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalPGRAPHVertexState (ProgramCaptureGPUCount)
- (instancetype)pcg_initWithState:(PGRAPHState *)pg
                          unbound:(BOOL)unbound
                    rasterDiscard:(BOOL)discard
               reusingProgramFrom:(NV2AMetalPGRAPHVertexState *)previous
                            error:(NSError **)error
{
    BOOL saved = pcg_capturing;
    pcg_capturing = pcg_work && pg == &state->pgraph;
    if (pcg_capturing)
        pcg_work->captures++;
    @try {
        self = [self pcg_initWithState:pg
                               unbound:unbound
                         rasterDiscard:discard
                    reusingProgramFrom:previous
                                 error:error];
        if (self && pcg_capturing)
            [pcg_work->states addObject:self];
        return self;
    } @finally {
        pcg_capturing = saved;
    }
}
@end
@interface NV2AMetalValidatedProgram (ProgramCaptureGPUCount)
- (instancetype)pcg_initWithTokens:(const uint32_t *)tokens
                            length:(NSUInteger)length
                             error:(NSError **)error
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalValidatedProgram (ProgramCaptureGPUCount)
- (instancetype)pcg_initWithTokens:(const uint32_t *)tokens
                            length:(NSUInteger)length
                             error:(NSError **)error
{
    const void *savedPointer = pcg_token_pointer;
    NSUInteger savedLength = pcg_token_length;
    if (pcg_capturing) {
        pcg_work->validations++;
        pcg_token_pointer = tokens;
        pcg_token_length = length * 16;
    }
    @try {
        return [self pcg_initWithTokens:tokens length:length error:error];
    } @finally {
        pcg_token_pointer = savedPointer;
        pcg_token_length = savedLength;
    }
}
@end
static id pcg_epoch(id owner, SEL selector, id capture, id attributes,
                    NSUInteger first, NSUInteger count, id fetch, id commands,
                    NSError **error)
{
    id encoded = fpp_epoch(owner, selector, capture, attributes, first, count,
                           fetch, commands, error);
    if (encoded && pcg_work)
        [pcg_work->encodings addObject:encoded];
    return encoded;
}
static id pcg_writer(id owner, SEL selector, id capture, id attributes,
                     NSUInteger first, NSUInteger count, id previous, id fetch,
                     id commands, NSError **error)
{
    id encoded = fpp_writer(owner, selector, capture, attributes, first, count,
                            previous, fetch, commands, error);
    if (encoded && pcg_work)
        [pcg_work->encodings addObject:encoded];
    return encoded;
}
enum { PCGBegin, PCGEnd, PCGPrepare, PCGStandalone, PCGFlush };
static BOOL pcg_action(unsigned action, ProgramCaptureGPUWork *work,
                       FloatProofPGRAPHWork *gpu, NSError **error)
{
    assert(!pcg_work && !fpp_work);
    pcg_work = work;
    fpp_work = gpu;
    @try {
        switch (action) {
        case PCGBegin:
            return [draw beginWithError:error];
        case PCGEnd:
            return [draw endWithError:error];
        case PCGPrepare:
            return [draw prepareVertexStateChangeWithError:error];
        case PCGStandalone:
            return [draw drawWithError:error];
        case PCGFlush:
            return [draw flushDrawWithError:error];
        }
        abort();
    } @finally {
        pcg_work = NULL;
        fpp_work = NULL;
    }
}
static void pcg_scene(BOOL writer, BOOL raw)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw closeWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    draw = nil;
    surfaces = [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state
                                                        error:&error];
    draw = [[NV2AMetalPGRAPHDraw alloc] initWithState:state
                                             surfaces:surfaces
                                                error:&error];
    require(surfaces && draw, error);
    fsm_scene(writer, 0);
    if (raw) {
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_CONTROL_0] = pg->regs_[NV_PGRAPH_CONTROL_1] = 0;
        pg->surface_shape = (SurfaceShape){ 0 };
        pg->surface_binding_dim.width = pg->surface_binding_dim.height = 0;
    }
}
static void pcg_wire(NSMutableArray *actual, NSError **error)
{
    NSData *begin = [draw beginSnapshotWithError:error];
    NSData *pending = [draw pendingSnapshotWithError:error];
    NSData *vertex = draw.vertexSnapshot;
    require(begin && pending && vertex, *error);
    [actual addObjectsFromArray:@[ begin, pending, vertex ]];
}
static void pcg_capture(NSMutableArray *actual, ProgramCaptureGPUWork *work,
                        BOOL raw)
{
    NSError *error = nil;
    require([surfaces.cache submitWithError:&error] &&
                [surfaces.cache waitUntilIdleWithError:&error],
            error);
    /* Every retained encoding owns its actual output until real feedback.
     * Never read GPU contents merely because a CPU capture was reusable. */
    for (NV2AMetalEpochEncoding *encoded in work->encodings) {
        NV2AMetalEpochResult *result = [encoded resolveWithError:&error];
        require(result != nil, error);
        NSMutableData *bytes = [NSMutableData new];
        [bytes appendBytes:&(NSUInteger){ result.vertexCount }
                    length:sizeof(NSUInteger)];
        if (result.vertices) {
            assert(result.vertices.storageMode == MTLStorageModeShared &&
                   result.vertices.length >=
                       result.vertexCount * sizeof(NV2AMetalVertex));
            [bytes appendBytes:result.vertices.contents
                        length:result.vertexCount * sizeof(NV2AMetalVertex)];
        }
        [bytes appendData:result.constants];
        [bytes appendData:result.written];
        [actual addObject:bytes];
    }
    [work->encodings removeAllObjects];
    for (NV2AMetalPGRAPHVertexState *capture in work->states)
        [actual addObject:[capture snapshotData]];
    qemu_mutex_unlock(&state->pgraph.lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(raw ? query == 0 : query > 0);
    if (raw) {
        for (unsigned i = 0; i < 64; i++) {
            uint32_t pixel;
            memcpy(&pixel, state->vram_ptr + 1024 + i * 4, 4);
            assert(pixel == UINT32_C(0xffff0000));
        }
    }
    [actual addObject:cpp_capture(query)];
}
static void pcg_repeat_pair(BOOL writer, BOOL raw)
{
    NSArray *reference = nil;
    ProgramCaptureGPUWork phases[2][3] = { 0 };
    FloatProofPGRAPHWork gpu[2][3] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            pcg_scene(writer, raw);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *states =
                [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *encodings =
                [NSMutableArray new];
            qemu_mutex_lock(&pg->lock);
            for (unsigned pass = 0; pass < 3; pass++) {
                if (pass == 1) {
                    const float changed[4] = { .125f, .25f, .875f, 1 };
                    memcpy(pg->vsh_constants[32], changed, 16);
                    pg->vsh_constants_dirty[32] = true;
                }
                if (pass == 2) {
                    const float zero = 0;
                    cpu_write(20480 + 5 * 4, 4);
                    memcpy(state->vram_ptr + 20480 + 5 * 4, &zero, 4);
                    irp_raw_write(24576 + 5 * 16, UINT32_C(0x3f000000));
                }
                NSUInteger before = states.count;
                NSData *liveConstants =
                    [NSData dataWithBytes:pg->vsh_constants
                                   length:sizeof(pg->vsh_constants)];
                VertexAttribute priorAttributes[16];
                memcpy(priorAttributes, pg->vertex_attributes,
                       sizeof(priorAttributes));
                uint16_t priorCompressed = pg->compressed_attrs,
                         priorUniform = pg->uniform_attrs,
                         priorSwizzle = pg->swizzle_attrs;
                phases[candidate][pass] =
                    (ProgramCaptureGPUWork){ .reference = !candidate,
                                             .states = states,
                                             .encodings = encodings };
                ProgramCaptureGPUWork *work = &phases[candidate][pass];
                if (raw && pass == 1) {
                    require(pcg_action(PCGStandalone, work,
                                       &gpu[candidate][pass], &error),
                            error);
                } else {
                    require(pcg_action(PCGBegin, work, &gpu[candidate][pass],
                                       &error),
                            error);
                    pcg_wire(actual, &error);
                    require(
                        pcg_action(PCGEnd, work, &gpu[candidate][pass], &error),
                        error);
                }
                pcg_capture(actual, work, raw);
                assert(states.count > before);
                if (pass)
                    assert(states[before] != states[0]);
                NV2AMetalPGRAPHVertexState *fresh = states[before];
                NV2AMetalProgramUniforms u = fresh.programUniforms;
                assert(!memcmp(u.constants, liveConstants.bytes,
                               sizeof(u.constants)));
                /* Raw XF boundaries restore the complete live input
                 * checkpoint. Raster End publishes the fresh last Current. */
                BOOL currentMatches =
                    raw ? !memcmp(priorAttributes, pg->vertex_attributes,
                                  sizeof(priorAttributes)) &&
                              pg->compressed_attrs == priorCompressed &&
                              pg->uniform_attrs == priorUniform &&
                              pg->swizzle_attrs == priorSwizzle :
                          !memcmp(pg->vertex_attributes[1].inline_value,
                                  state->vram_ptr + 20480 + 5 * 4, 4);
                if (!currentMatches) {
                    uint32_t current, sourceBits, prior;
                    memcpy(&current, pg->vertex_attributes[1].inline_value, 4);
                    memcpy(&sourceBits, state->vram_ptr + 20480 + 5 * 4, 4);
                    memcpy(&prior, priorAttributes[1].inline_value, 4);
                    fprintf(stderr,
                            "Program capture Current writer%u raw%u "
                            "candidate%u pass%u actual%08x source%08x "
                            "prior%08x compressed%04x/%04x uniform%04x/%04x "
                            "swizzle%04x/%04x count%u stride%u populated%u\n",
                            writer, raw, candidate, pass, current, sourceBits,
                            prior, pg->compressed_attrs, priorCompressed,
                            pg->uniform_attrs, priorUniform, pg->swizzle_attrs,
                            priorSwizzle, pg->vertex_attributes[1].count,
                            pg->vertex_attributes[1].stride,
                            pg->vertex_attributes[1].inline_buffer_populated);
                }
                assert(currentMatches);
                if (writer)
                    assert(pg->vsh_constants_dirty[150] &&
                           !memcmp(pg->vsh_constants[150],
                                   state->vram_ptr + 24576 + 5 * 16, 4));
            }
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            qemu_mutex_unlock(&pg->lock);
        }
    }
    for (unsigned pass = 0; pass < 3; pass++) {
        assert(phases[0][pass].validations == 1 &&
               phases[1][pass].validations == (NSUInteger)!pass);
        for (unsigned candidate = 0; candidate < 2; candidate++) {
            assert(phases[candidate][pass].captures ==
                       (raw && pass == 1 ? 2u : 1u) &&
                   phases[candidate][pass].tokenCopies ==
                       phases[candidate][pass].validations &&
                   phases[candidate][pass].tokenBytes ==
                       phases[candidate][pass].validations *
                           (writer ? 64u : 48u));
            assert(gpu[candidate][pass].records == 6);
        }
    }
}

static void pcg_run_frame(NSMutableArray *actual, ProgramCaptureGPUWork *work,
                          FloatProofPGRAPHWork *gpu, NSError **error)
{
    require(pcg_action(PCGBegin, work, gpu, error), *error);
    pcg_wire(actual, error);
    require(pcg_action(PCGEnd, work, gpu, error), *error);
    pcg_capture(actual, work, NO);
}
static void pcg_token_pair(void)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            pcg_scene(NO, NO);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *states =
                [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *encodings =
                [NSMutableArray new];
            ProgramCaptureGPUWork work = { .reference = !candidate,
                                           .states = states,
                                           .encodings = encodings };
            FloatProofPGRAPHWork gpu = { 0 };
            uint32_t original[3][4];
            memcpy(original, pg->program_data, sizeof(original));
            qemu_mutex_lock(&pg->lock);
            pcg_run_frame(actual, &work, &gpu, &error); /* Successful A. */
            memcpy(pg->program_data[8], original, sizeof(original));
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C],
                     NV_PGRAPH_CSV0_C_CHEOPS_PROGRAM_START, 8);
            pcg_run_frame(actual, &work, &gpu,
                          &error); /* Same bytes/new start. */
            pg->program_data[8][1] =
                (pg->program_data[8][1] & ~(15u << 21)) | 15u << 21;
            NSData *host = fpp_host();
            int time = pg->draw_time;
            assert(!pcg_action(PCGBegin, &work, &gpu, &error) && error &&
                   [host isEqualToData:fpp_host()] && pg->draw_time == time);
            [actual addObjectsFromArray:@[
                error.domain, error.localizedDescription, @(error.code)
            ]];
            error = nil;
            memcpy(pg->program_data[8], original, sizeof(original));
            pcg_run_frame(actual, &work, &gpu,
                          &error); /* Failed B did not replace A. */
            Token changed = token(1, 0, 32);
            source(&changed, 0, 3, 0, 0x1b);
            destination(&changed, 0x103, 15, 0, 0, 0, 0);
            changed.word[3] |= 3;
            memcpy(pg->program_data[10], changed.word, 16);
            pcg_run_frame(actual, &work, &gpu, &error); /* Successful B. */
            memcpy(pg->program_data[8], original, sizeof(original));
            pcg_run_frame(actual, &work, &gpu,
                          &error); /* A must be revalidated. */
            pg->program_data[8][3] |=
                1; /* New early END, valid position only. */
            pcg_run_frame(actual, &work, &gpu, &error);
            memcpy(pg->program_data[8], original, sizeof(original));
            pcg_run_frame(actual, &work, &gpu, &error);
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C],
                     NV_PGRAPH_CSV0_C_CHEOPS_PROGRAM_START,
                     NV2A_METAL_VP_SLOTS);
            host = fpp_host();
            time = pg->draw_time;
            assert(!pcg_action(PCGBegin, &work, &gpu, &error) && error &&
                   [host isEqualToData:fpp_host()] && pg->draw_time == time);
            [actual addObjectsFromArray:@[
                error.domain, error.localizedDescription, @(error.code)
            ]];
            error = nil;
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C],
                     NV_PGRAPH_CSV0_C_CHEOPS_PROGRAM_START, 8);
            pcg_run_frame(actual, &work, &gpu, &error);
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(work.tokenCopies == work.validations &&
                   work.validations == (candidate ? 6u : 9u) &&
                   gpu.records == 48);
            qemu_mutex_unlock(&pg->lock);
        }
    }
}
static void pcg_fault_pair(void)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            pcg_scene(NO, NO);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *states =
                [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *encodings =
                [NSMutableArray new];
            ProgramCaptureGPUWork work = { .reference = !candidate,
                                           .states = states,
                                           .encodings = encodings };
            FloatProofPGRAPHWork gpu = { 0 };
            qemu_mutex_lock(&pg->lock);
            pcg_run_frame(actual, &work, &gpu, &error);
            irp_raw_write(20480, UINT32_C(0x7fc12345));
            require(pcg_action(PCGBegin, &work, &gpu, &error), error);
            NSData *host = fpp_host();
            int time = pg->draw_time;
            assert(!pcg_action(PCGEnd, &work, &gpu, &error) && error &&
                   [host isEqualToData:fpp_host()] && pg->draw_time == time);
            [actual addObjectsFromArray:@[
                error.domain, error.localizedDescription, @(error.code)
            ]];
            /* End could report this logical shader fault only after its
             * real producer feedback/resolve. Inspect the one OR word, not
             * count per-vertex records in the compact feedback allocation. */
            assert(encodings.count == 1);
            NV2AMetalEpochEncoding *failed = encodings[0];
            id program = [failed valueForKey:@"programEncoding"];
            id<MTLBuffer> faults = [program valueForKey:@"raw"];
            assert(faults.storageMode == MTLStorageModeShared &&
                   faults.length == sizeof(uint32_t));
            uint32_t fault;
            memcpy(&fault, faults.contents, sizeof(fault));
            assert(fault == NV2AMetalProgramFaultAddressRange);
            [actual addObject:[NSData dataWithBytes:&fault
                                             length:sizeof(fault)]];
            [encodings removeAllObjects];
            error = nil;
            const float zero = 0;
            cpu_write(20480, 4);
            memcpy(state->vram_ptr + 20480, &zero, 4);
            require(pcg_action(PCGEnd, &work, &gpu, &error), error);
            pcg_capture(actual, &work, NO);
            pcg_run_frame(actual, &work, &gpu, &error);
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(work.tokenCopies == work.validations &&
                   work.validations == (candidate ? 1u : 3u) &&
                   gpu.records == 24);
            qemu_mutex_unlock(&pg->lock);
        }
    }
}
static void pcg_lifecycle_pair(void)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            pcg_scene(YES, NO);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *states =
                [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *encodings =
                [NSMutableArray new];
            ProgramCaptureGPUWork work = { .reference = !candidate,
                                           .states = states,
                                           .encodings = encodings };
            FloatProofPGRAPHWork gpu = { 0 };
            qemu_mutex_lock(&pg->lock);
            pcg_run_frame(actual, &work, &gpu, &error);
            pg->draw_arrays_count[0] = 3;
            require(pcg_action(PCGBegin, &work, &gpu, &error) &&
                        pcg_action(PCGPrepare, &work, &gpu, &error),
                    error);
            NSData *prefix = [draw pendingSnapshotWithError:&error];
            require(prefix != nil, error);
            const float changed = 0;
            cpu_write(20480 + 3 * 4, 4);
            memcpy(state->vram_ptr + 20480 + 3 * 4, &changed, 4);
            pg->draw_arrays_count[0] = 6;
            require(pcg_action(PCGPrepare, &work, &gpu, &error), error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            NSData *begin = [draw beginSnapshotWithError:&error];
            NSData *vertex = draw.vertexSnapshot;
            require(pending && begin && vertex &&
                        [draw flushWithError:&error] &&
                        [draw discardForRestoreWithError:&error] &&
                        [draw restoreVertexSnapshot:vertex error:&error] &&
                        [draw restoreBeginSnapshot:begin error:&error] &&
                        [draw restorePendingSnapshot:pending error:&error] &&
                        pcg_action(PCGBegin, &work, &gpu, &error),
                    error);
            NSData *restored = [draw pendingSnapshotWithError:&error];
            require(restored != nil, error);
            assert([restored isEqualToData:pending]);
            [actual addObjectsFromArray:@[
                prefix, pending, begin, vertex, restored
            ]];
            NSData *host = fpp_host();
            int time = pg->draw_time;
            fpp_fail_emit = YES;
            assert(!pcg_action(PCGFlush, &work, &gpu, &error) && error &&
                   !fpp_fail_emit && [host isEqualToData:fpp_host()] &&
                   pg->draw_time == time);
            [actual addObjectsFromArray:@[ error.domain, @(error.code) ]];
            error = nil;
            require(pcg_action(PCGEnd, &work, &gpu, &error), error);
            pcg_capture(actual, &work, NO);
            /* The restored journal already contains the whole XF prefix.
             * A successful draw with no new suffix cannot publish a witness
             * after Restore cleared it, even though raster work occurred. */
            BOOL emptyWitness = !pcg_witness_original(
                draw, NSSelectorFromString(@"programCaptureWitness"));
            NSUInteger beforeFinal = work.validations;
            pcg_run_frame(actual, &work, &gpu, &error);
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(emptyWitness && work.validations == beforeFinal + 1 &&
                   work.tokenCopies == work.validations && gpu.records == 18);
            if (candidate)
                assert(work.validations < work.captures);
            qemu_mutex_unlock(&pg->lock);
        }
    }
}
static void program_capture_reuse_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalPGRAPHDraw.class,
                                NSSelectorFromString(@"programCaptureWitness")),
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    IMP replacements[] = { (IMP)pcg_witness, (IMP)pcg_data, (IMP)pcg_epoch,
                           (IMP)pcg_writer, (IMP)fpp_emit };
    IMP originals[ARRAY_SIZE(methods)];
    Method stateInit = class_getInstanceMethod(
        NV2AMetalPGRAPHVertexState.class,
        NSSelectorFromString(
            @"initWithState:unbound:rasterDiscard:reusingProgramFrom:error:"));
    Method stateHook = class_getInstanceMethod(
        NV2AMetalPGRAPHVertexState.class,
        @selector(
            pcg_initWithState:unbound:rasterDiscard:reusingProgramFrom:error:));
    Method programInit =
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(initWithTokens:length:error:));
    Method programHook =
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(pcg_initWithTokens:length:error:));
    assert(stateInit && stateHook && programInit && programHook);
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    pcg_witness_original = (void *)originals[0];
    pcg_data_original = (void *)originals[1];
    fpp_epoch_original = (void *)originals[2];
    fpp_writer_original = (void *)originals[3];
    fpp_emit_original = (void *)originals[4];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    method_exchangeImplementations(stateInit, stateHook);
    method_exchangeImplementations(programInit, programHook);
    @try {
        for (unsigned raw = 0; raw < 2; raw++)
            for (unsigned writer = 0; writer < 2; writer++)
                pcg_repeat_pair(writer, raw);
        pcg_token_pair();
        pcg_fault_pair();
        pcg_lifecycle_pair();
    } @finally {
        pcg_work = NULL;
        fpp_work = NULL;
        pcg_capturing = fpp_fail_emit = NO;
        pcg_token_pointer = NULL;
        pcg_token_length = 0;
        method_exchangeImplementations(programInit, programHook);
        method_exchangeImplementations(stateInit, stateHook);
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    groups += 7;
    puts("PGRAPH program capture reuse:7 exact GPU/frame/depth/query/Current/"
         "constants/wire pairs; fresh raster/raw/standalone captures, live "
         "constants+CPU/GPU sources, token/start/END/malformed/fault/repair, "
         "prefix/Restore/late retry; scoped validation/token-copy counts PASS");
}
#endif
