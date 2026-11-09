/* Controller-owned CPU program metadata; live captures always remain fresh.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PROGRAM_CAPTURE_REUSE_H
#define TEST_METAL_PROGRAM_CAPTURE_REUSE_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-writable.h"

@interface NV2AMetalPGRAPHDraw (ProgramCaptureNativeTest)
- (NV2AMetalPGRAPHVertexState *)programCaptureWitness;
@end
typedef struct ProgramCaptureNativeWork {
    BOOL reference;
    NSUInteger metadata, captures, probes;
    __unsafe_unretained NSMutableArray *captureWires;
} ProgramCaptureNativeWork;
static _Thread_local ProgramCaptureNativeWork *pcr_work;
static _Thread_local BOOL pcr_reference;
static _Thread_local unsigned pcr_kind;
static _Thread_local const char *pcr_stage;
static _Thread_local BOOL pcr_fail_metadata, pcr_fail_pixel;
static NSError *pcr_failure;
static id (*pcr_witness_original)(id, SEL);
static id (*pcr_pixel_original)(id, SEL, id, NSError **);
static id pcr_witness(id owner, SEL selector)
{
    if (pcr_work) {
        pcr_work->probes++;
    }
    if (pcr_reference)
        return nil;
    return pcr_witness_original(owner, selector);
}
static id pcr_pixel(id owner, SEL selector, id textures, NSError **error)
{
    id result = pcr_pixel_original(owner, selector, textures, error);
    if (result && pcr_fail_pixel) {
        pcr_fail_pixel = NO;
        if (error)
            *error = pcr_failure;
        return nil;
    }
    return result;
}
/* Both exchanged constructors retain the original init-family ARC contract. */
@interface NV2AMetalValidatedProgram (ProgramCaptureNativeCount)
- (instancetype)pcr_initWithTokens:(const uint32_t *)tokens
                            length:(NSUInteger)length
                             error:(NSError **)error
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalValidatedProgram (ProgramCaptureNativeCount)
- (instancetype)pcr_initWithTokens:(const uint32_t *)tokens
                            length:(NSUInteger)length
                             error:(NSError **)error
{
    if (pcr_work)
        pcr_work->metadata++;
    NV2AMetalValidatedProgram *result = [self pcr_initWithTokens:tokens
                                                          length:length
                                                           error:error];
    if (result && pcr_fail_metadata) {
        pcr_fail_metadata = NO;
        result = nil;
        if (error)
            *error = pcr_failure;
    }
    return result;
}
@end
@interface NV2AMetalPGRAPHVertexState (ProgramCaptureNativeOriginal)
- (instancetype)initWithState:(PGRAPHState *)pg
                      unbound:(BOOL)unbound
                rasterDiscard:(BOOL)discard
           reusingProgramFrom:(NV2AMetalPGRAPHVertexState *)previous
                        error:(NSError **)error;
@end
@interface NV2AMetalPGRAPHVertexState (ProgramCaptureNativeCount)
- (instancetype)pcr_initWithState:(PGRAPHState *)pg
                          unbound:(BOOL)unbound
                    rasterDiscard:(BOOL)discard
               reusingProgramFrom:(NV2AMetalPGRAPHVertexState *)previous
                            error:(NSError **)error
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalPGRAPHVertexState (ProgramCaptureNativeCount)
- (instancetype)pcr_initWithState:(PGRAPHState *)pg
                          unbound:(BOOL)unbound
                    rasterDiscard:(BOOL)discard
               reusingProgramFrom:(NV2AMetalPGRAPHVertexState *)previous
                            error:(NSError **)error
{
    if (pcr_work)
        pcr_work->captures++;
    NV2AMetalPGRAPHVertexState *result = [self pcr_initWithState:pg
                                                         unbound:unbound
                                                   rasterDiscard:discard
                                              reusingProgramFrom:previous
                                                           error:error];
    if (result && pcr_work && pcr_work->captureWires) {
        ProgramCaptureNativeWork *saved = pcr_work;
        pcr_work = NULL;
        @try {
            NSError *mirrorError = nil;
            NV2AMetalPGRAPHVertexState *mirror =
                [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                          unbound:unbound
                                                    rasterDiscard:discard
                                               reusingProgramFrom:nil
                                                            error:&mirrorError];
            require(mirror != nil, mirrorError);
            NSData *wire = result.snapshotData;
            assert(result != mirror &&
                   [wire isEqualToData:mirror.snapshotData]);
            [saved->captureWires addObject:wire];
        } @finally {
            pcr_work = saved;
        }
    }
    return result;
}
@end
static NV2AMetalPGRAPHVertexState *pcr_actual_witness(void)
{
    return pcr_witness_original(draw, @selector(programCaptureWitness));
}
static void pcr_scene(BOOL raw)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    inline_fixed_context(pg, 2);
    pg->primitive_mode = PRIM_TYPE_POINTS;
    pg->draw_arrays_count[0] = 1;
    if (raw)
        pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
}
static void pcr_constant(unsigned row, unsigned component, float value)
{
    memcpy(&state->pgraph.vsh_constants[row][component], &value, sizeof(value));
}
/* A second ordinary constructor supplies the independent old snapshot.
 * It is outside the measured controller-call scope, not a synthetic result. */
static NSData *pcr_current_capture(void)
{
    ProgramCaptureNativeWork *saved = pcr_work;
    pcr_work = NULL;
    NSError *error = nil;
    NV2AMetalPGRAPHVertexState *captured = [draw valueForKey:@"vertexState"];
    assert(captured);
    NV2AMetalPGRAPHVertexState *old =
        captured.rasterDiscard ?
            [[NV2AMetalPGRAPHVertexState alloc]
                initRawXFWithState:&state->pgraph
                             error:&error] :
            [[NV2AMetalPGRAPHVertexState alloc] initWithState:&state->pgraph
                                                        error:&error];
    require(old != nil, error);
    NSData *wire = [captured snapshotData];
    NSData *oldWire = old.snapshotData;
    if (captured == old || ![wire isEqualToData:oldWire]) {
        NSUInteger limit = MIN(wire.length, oldWire.length), first = 0;
        const uint8_t *a = wire.bytes, *b = oldWire.bytes;
        while (first < limit && a[first] == b[first])
            first++;
        fprintf(stderr,
                "Program capture mismatch kind%u reference%u stage%s "
                "first%lu lengths%lu/%lu byte%02x/%02x "
                "captureRaw%u/full%u/write%u/programmed%u "
                "oldRaw%u/full%u/write%u/programmed%u csvC%08x csvD%08x\n",
                pcr_kind, pcr_reference, pcr_stage, (unsigned long)first,
                (unsigned long)wire.length, (unsigned long)oldWire.length,
                first < wire.length ? a[first] : 0,
                first < oldWire.length ? b[first] : 0, captured.rasterDiscard,
                captured.fullAccess, captured.writeEnable, captured.programmed,
                old.rasterDiscard, old.fullAccess, old.writeEnable,
                old.programmed, state->pgraph.regs_[NV_PGRAPH_CSV0_C],
                state->pgraph.regs_[NV_PGRAPH_CSV0_D]);
    }
    assert(captured != old && [wire isEqualToData:oldWire]);
    NV2AMetalProgramUniforms uniforms = captured.programUniforms;
    assert(!memcmp(uniforms.constants, state->pgraph.vsh_constants,
                   sizeof(uniforms.constants)));
    NV2AMetalProgramInput values = captured.inlineValues;
    for (unsigned i = 0; i < 16; i++)
        assert(!memcmp(values.attributes[i],
                       state->pgraph.vertex_attributes[i].inline_value, 16));
    pcr_work = saved;
    return wire;
}
static void pcr_counts(NSMutableArray *counts, ProgramCaptureNativeWork work,
                       NSUInteger expected)
{
    [counts addObject:@[ @(work.metadata), @(expected), @(work.captures) ]];
}
static void pcr_error(NSMutableArray *bytes, NSError *error)
{
    require(error != nil, nil);
    [bytes addObjectsFromArray:@[
        error.domain, @(error.code), error.localizedDescription
    ]];
}
static void pcr_empty(BOOL reference, NSMutableArray *bytes,
                      NSMutableArray *counts, NSUInteger expected,
                      BOOL succeeds)
{
    PGRAPHState *pg = &state->pgraph;
    unsigned arrays = pg->draw_arrays_length;
    pg->draw_arrays_length = 0;
    ProgramCaptureNativeWork work = { .reference = reference };
    NSError *error = nil;
    pcr_work = &work;
    BOOL ok;
    @try {
        ok = [draw beginWithError:&error];
        if (ok) {
            pcr_stage = "empty-begin";
            [bytes addObject:pcr_current_capture()];
            require([draw prepareVertexStateChangeWithError:&error], error);
            ok = [draw endWithError:&error];
        }
    } @finally {
        pcr_work = NULL;
        pg->draw_arrays_length = arrays;
    }
    assert(ok == succeeds);
    if (!ok)
        pcr_error(bytes, error);
    assert(work.captures == 1);
    pcr_counts(counts, work, expected);
}
static void pcr_accept(BOOL reference, BOOL standalone, NSMutableArray *bytes,
                       NSMutableArray *counts, NSUInteger expected)
{
    NSError *error = nil;
    ProgramCaptureNativeWork work = { .reference = reference };
    pcr_work = &work;
    @try {
        if (standalone) {
            require([draw drawWithError:&error], error);
        } else {
            require([draw beginWithError:&error], error);
            pcr_stage = "accepted-begin";
            [bytes addObject:pcr_current_capture()];
            require([draw endWithError:&error], error);
        }
    } @finally {
        pcr_work = NULL;
    }
    NV2AMetalPGRAPHVertexState *witness = pcr_actual_witness();
    assert(witness.programmed &&
           [witness isMemberOfClass:NV2AMetalPGRAPHVertexState.class]);
    /* Only the immutable instruction identity is used from this object.
     * A writer witness may intentionally predate published constants. */
    [bytes addObject:witness.programBytes];
    assert(work.captures);
    pcr_counts(counts, work, expected);
}
static void pcr_cpu_owner(NV2AMetalPGRAPHVertexState *witness)
{
    unsigned n = 0;
    Ivar *ivars = class_copyIvarList(NV2AMetalPGRAPHVertexState.class, &n);
    for (unsigned i = 0; i < n; i++) {
        if (ivar_getTypeEncoding(ivars[i])[0] != '@')
            continue;
        id object = object_getIvar(witness, ivars[i]);
        assert(!object || [object isKindOfClass:NSData.class] ||
               [object isKindOfClass:NV2AMetalValidatedProgram.class]);
    }
    free(ivars);
}
static NSArray *pcr_run(unsigned kind, BOOL reference, NSMutableArray *counts)
{
    pcr_scene(kind == 1);
    PGRAPHState *pg = &state->pgraph;
    NSError *error = nil;
    NSMutableArray *bytes = [NSMutableArray new];
    qemu_mutex_lock(&pg->lock);
    NSUInteger warm = reference ? 1 : 0;
    if (kind < 2) {
        /* Empty Begin/End cannot publish a witness. A real accepted Draw/XF
         * primes it before the following newly allocated live snapshots. */
        pcr_empty(reference, bytes, counts, 1, YES);
        pcr_empty(reference, bytes, counts, 1, YES);
        assert(!pcr_actual_witness());
        pcr_accept(reference, NO, bytes, counts, 1);
        NV2AMetalPGRAPHVertexState *accepted = pcr_actual_witness();
        for (unsigned i = 0; i < 4; i++) {
            pcr_constant(120, 0, .125f * (i + 1));
            pg->vertex_attributes[3].inline_value[0] = .125f * i;
            pcr_empty(reference, bytes, counts, warm, YES);
            assert(pcr_actual_witness() == accepted);
            pcr_accept(reference, NO, bytes, counts, warm);
            accepted = pcr_actual_witness();
        }
    } else if (kind == 2) {
        for (unsigned i = 0; i < 4; i++) {
            pcr_constant(120, 1, .25f * i);
            pcr_accept(reference, YES, bytes, counts, i ? warm : 1);
        }
    } else {
        if (kind != 8)
            pcr_accept(reference, NO, bytes, counts, 1);
        if (kind == 3) {
            /* Program start is not instruction identity. Every constructor
             * still checks the current bounded token window including END. */
            memcpy(pg->program_data[4], pg->program_data[0], 32);
            pg->regs_[NV_PGRAPH_CSV0_C] = 4u << 8;
            pcr_empty(reference, bytes, counts, warm, YES);
            pg->program_data[4][3] |= 1;
            pcr_empty(reference, bytes, counts, 1, YES);
            pg->program_data[4][3] &= ~1u;
            pg->program_data[5][3] &= ~1u;
            mov(6, 3, 3, true);
            pcr_empty(reference, bytes, counts, 1, YES);
            pg->program_data[4][1] =
                (pg->program_data[4][1] & ~(15u << 21)) | 15u << 21;
            pcr_empty(reference, bytes, counts, 1, NO);
            pg->regs_[NV_PGRAPH_CSV0_C] = 0;
            pcr_empty(reference, bytes, counts, warm, YES);
        } else if (kind == 4) {
            for (unsigned i = 0; i < 4; i++) {
                pcr_constant(121, 2, .125f * i);
                pg->vertex_attributes[3].inline_value[2] = .25f * i;
                pg->regs_[NV_PGRAPH_CSV0_D] ^= NV_PGRAPH_CSV0_D_RANGE_MODE;
                pg->enable_vertex_program_write =
                    !pg->enable_vertex_program_write;
                reg_float(NV_PGRAPH_FOGPARAM0, .5f * i);
                pg->regs_[NV_PGRAPH_POINTSIZE] = 8 * (i + 1);
                pg->surface_scale_factor = (i & 1) + 1;
                pcr_empty(reference, bytes, counts, warm, YES);
            }
            pg->regs_[NV_PGRAPH_CSV0_D] = 0;
            pg->enable_vertex_program_write = NO;
            pcr_empty(reference, bytes, counts, 0, YES);
            inline_fixed_context(pg, 2);
            pcr_empty(reference, bytes, counts, warm, YES);
        } else if (kind == 5) {
            /* Active oldPrevious reuse must remain effective even when the
             * new fallback getter is forced nil for the old reference. */
            require([draw beginWithError:&error] &&
                        [draw prepareVertexStateChangeWithError:&error],
                    error);
            pcr_constant(120, 0, .75f);
            pg->draw_arrays_count[0] = 2;
            __attribute__((objc_precise_lifetime))
            NSMutableArray *captureWires = [NSMutableArray new];
            ProgramCaptureNativeWork work = { .reference = reference,
                                              .captureWires = captureWires };
            pcr_work = &work;
            @try {
                require([draw prepareVertexStateChangeWithError:&error], error);
            } @finally {
                pcr_work = NULL;
            }
            pcr_stage = "active-boundary";
            /* Current is restored after the local recapture. Compare the
             * active state to the complete wire checked at its actual ctor
             * time, not to a later live-state reconstruction. */
            NSData *activeWire =
                [[draw valueForKey:@"vertexState"] snapshotData];
            assert(captureWires.count &&
                   [activeWire isEqualToData:captureWires.lastObject]);
            [bytes addObjectsFromArray:captureWires];
            [bytes addObject:activeWire];
            pcr_counts(counts, work, 0);
            NV2AMetalPGRAPHVertexState *accepted = pcr_actual_witness();
            require([draw endWithError:&error], error);
            assert(pcr_actual_witness() == accepted);
        } else if (kind == 6) {
            NV2AMetalPGRAPHVertexState *old = pcr_actual_witness();
            mov(1, 4, 3, true);
            pcr_fail_metadata = YES;
            pcr_empty(reference, bytes, counts, 1, NO);
            assert(!pcr_fail_metadata && pcr_actual_witness() == old);
            pcr_empty(reference, bytes, counts, 1, YES);
            assert(pcr_actual_witness() == old);
            pcr_accept(reference, NO, bytes, counts, 1);
            pcr_empty(reference, bytes, counts, warm, YES);
        } else if (kind == 7) {
            NV2AMetalPGRAPHVertexState *old = pcr_actual_witness();
            unsigned csvd = pg->regs_[NV_PGRAPH_CSV0_D];
            pg->regs_[NV_PGRAPH_CSV0_D] = 1u << 30;
            pcr_empty(reference, bytes, counts, 0, NO);
            pg->regs_[NV_PGRAPH_CSV0_D] = csvd;
            pcr_fail_pixel = YES;
            pcr_empty(reference, bytes, counts, warm, NO);
            assert(!pcr_fail_pixel && pcr_actual_witness() == old);
            pcr_empty(reference, bytes, counts, warm, YES);
        } else if (kind == 8) {
            __weak NV2AMetalPGRAPHVertexState *old;
            @autoreleasepool {
                pcr_accept(reference, NO, bytes, counts, 1);
                old = pcr_actual_witness();
                pcr_cpu_owner(old);
                require([draw flushWithError:&error], error);
                assert(old);
            }
            @autoreleasepool {
                mov(1, 4, 3, true);
                pcr_accept(reference, NO, bytes, counts, 1);
                require([draw flushWithError:&error], error);
            }
            assert(!old);
            pcr_cpu_owner(pcr_actual_witness());
        } else {
            require([draw beginWithError:&error], error);
            NSData *vertex = draw.vertexSnapshot;
            NSData *begin = [draw beginSnapshotWithError:&error];
            require(vertex && begin && [draw endWithError:&error], error);
            NV2AMetalPGRAPHVertexState *old = pcr_actual_witness();
            assert(![draw restoreVertexSnapshot:[NSMutableData dataWithLength:3]
                                          error:&error] &&
                   error && pcr_actual_witness() == old);
            error = nil;
            require([draw discardForRestoreWithError:&error], error);
            assert(!pcr_actual_witness());
            ProgramCaptureNativeWork work = { .reference = reference };
            pcr_work = &work;
            @try {
                require([draw restoreVertexSnapshot:vertex error:&error],
                        error);
            } @finally {
                pcr_work = NULL;
            }
            pcr_counts(counts, work,
                       1); /* External wire is always revalidated. */
            assert(!pcr_actual_witness());
            require([draw restoreBeginSnapshot:begin error:&error] &&
                        [draw beginWithError:&error],
                    error);
            pcr_stage = "restored-begin";
            [bytes addObject:pcr_current_capture()];
            require([draw endWithError:&error], error);
            /* No Pending inputs were imported: the restored End really ran
             * the live suffix and published its successful new witness. */
            pcr_accept(reference, NO, bytes, counts, warm);
            [draw invalidateSession];
            assert(!pcr_actual_witness());
            pcr_accept(reference, NO, bytes, counts, 1);
            require([draw closeWithError:&error], error);
            assert(!pcr_actual_witness());
            draw = nil;
            surfaces = [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state
                                                                error:&error];
            draw = [[NV2AMetalPGRAPHDraw alloc] initWithState:state
                                                     surfaces:surfaces
                                                        error:&error];
            require(draw && surfaces, error);
        }
    }
    [bytes addObject:fpp_host()];
    require([draw flushWithError:&error], error);
    qemu_mutex_unlock(&pg->lock);
    return bytes;
}
static void program_capture_reuse_tests(void)
{
    Method witness = class_getInstanceMethod(NV2AMetalPGRAPHDraw.class,
                                             @selector(programCaptureWitness));
    Method pixel = class_getInstanceMethod(
        NV2AMetalPGRAPHDraw.class,
        NSSelectorFromString(@"capturePixelStateWithTextures:error:"));
    Method metadata =
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(initWithTokens:length:error:));
    Method metadataHook =
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(pcr_initWithTokens:length:error:));
    Method capture = class_getInstanceMethod(
        NV2AMetalPGRAPHVertexState.class,
        NSSelectorFromString(
            @"initWithState:unbound:rasterDiscard:reusingProgramFrom:error:"));
    Method captureHook = class_getInstanceMethod(
        NV2AMetalPGRAPHVertexState.class,
        @selector(
            pcr_initWithState:unbound:rasterDiscard:reusingProgramFrom:error:));
    assert(witness && pixel && metadata && metadataHook && capture &&
           captureHook);
    pcr_witness_original = (void *)method_getImplementation(witness);
    pcr_pixel_original = (void *)method_getImplementation(pixel);
    pcr_failure = [NSError errorWithDomain:@"test.program-capture-reuse"
                                      code:1
                                  userInfo:nil];
    method_setImplementation(witness, (IMP)pcr_witness);
    method_setImplementation(pixel, (IMP)pcr_pixel);
    method_exchangeImplementations(metadata, metadataHook);
    method_exchangeImplementations(capture, captureHook);
    @try {
        for (unsigned kind = 0; kind < 10; kind++) {
            NSArray *reference = nil;
            for (unsigned candidate = 0; candidate < 2; candidate++) {
                @autoreleasepool {
                    NSMutableArray *counts = [NSMutableArray new];
                    pcr_kind = kind;
                    pcr_reference = !candidate;
                    NSArray *actual;
                    @try {
                        actual = pcr_run(kind, !candidate, counts);
                    } @finally {
                        pcr_reference = NO;
                    }
                    if (!candidate)
                        reference = actual;
                    else
                        assert([reference isEqualToArray:actual]);
                    for (NSArray *count in counts) {
                        if (![count[0] isEqual:count[1]])
                            fprintf(stderr,
                                    "Program capture kind%u candidate%u "
                                    "metadata%lu expected%lu captures%lu\n",
                                    kind, candidate,
                                    [count[0] unsignedLongValue],
                                    [count[1] unsignedLongValue],
                                    [count[2] unsignedLongValue]);
                        assert([count[0] isEqual:count[1]]);
                    }
                }
            }
            groups++;
        }
    } @finally {
        pcr_work = NULL;
        pcr_reference = NO;
        pcr_fail_metadata = pcr_fail_pixel = NO;
        method_exchangeImplementations(capture, captureHook);
        method_exchangeImplementations(metadata, metadataHook);
        method_setImplementation(pixel, (IMP)pcr_pixel_original);
        method_setImplementation(witness, (IMP)pcr_witness_original);
        pcr_failure = nil;
    }
    puts("Program capture metadata:10 native lifecycle groups, fresh exact "
         "snapshots/uniforms vs original constructors, accepted-only "
         "witness/active previous/END/start/failure/weak/Restore/close PASS");
}
#endif
