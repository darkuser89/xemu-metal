/* Immutable Fixed/readonly context metadata versus the original byte copies.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_CONTEXT_METADATA_H
#define TEST_METAL_CONTEXT_METADATA_H
#import <objc/runtime.h>
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-types.h"

@interface NV2AMetalEpochResult (ContextMetadataTest)
- (instancetype)initRegisters:(id<MTLBuffer>)registers
                     vertices:(id<MTLBuffer>)vertices
                        count:(NSUInteger)count
                    constants:(NSData *)constants
                      written:(NSData *)written;
@end
@interface NV2AMetalWritableResult (ContextMetadataTest)
- (instancetype)initWithContext:(const NV2AMetalWritableContext *)context
                      registers:(id<MTLBuffer>)registers
                       vertices:(id<MTLBuffer>)vertices
                          count:(NSUInteger)count;
- (instancetype)initReadOnlyWithConstants:(NSData *)constants
                                registers:(id<MTLBuffer>)registers
                                 vertices:(id<MTLBuffer>)vertices
                                    count:(NSUInteger)count;
@end
/* A subclass can return different uniforms without changing object identity.
 * Such captures must retain the old, uncached value semantics. */
@interface ContextMetadataCapture : NV2AMetalPGRAPHVertexState
@property(nonatomic) uint32_t marker;
@end
@implementation ContextMetadataCapture
- (NV2AMetalFixedUniforms)fixedUniforms
{
    NV2AMetalFixedUniforms u = [super fixedUniforms];
    memcpy(u.common.constants[191], &_marker, 4);
    return u;
}
@end
static _Thread_local BOOL cm_counting, cm_reference_fixed,
    cm_reference_readonly;
static _Thread_local NSUInteger cm_constant_copies, cm_written_copies,
    cm_ro_calls;
static id (*cm_data_original)(id, SEL, const void *, NSUInteger);
static id cm_data(id cls, SEL selector, const void *bytes, NSUInteger length)
{
    if (cm_counting) {
        cm_constant_copies += length == 3072;
        cm_written_copies += length == 768;
    }
    return cm_data_original(cls, selector, bytes, length);
}
@interface NV2AMetalEpochResult (ContextMetadataHook)
- (instancetype)cm_initRegisters:(id<MTLBuffer>)registers
                        vertices:(id<MTLBuffer>)vertices
                           count:(NSUInteger)count
                       constants:(NSData *)constants
                         written:(NSData *)written
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalEpochResult (ContextMetadataHook)
- (instancetype)cm_initRegisters:(id<MTLBuffer>)registers
                        vertices:(id<MTLBuffer>)vertices
                           count:(NSUInteger)count
                       constants:(NSData *)constants
                         written:(NSData *)written
{
    if (cm_reference_fixed) {
        /* The previous Fixed result path owned two full NSData byte copies.
         * GPU execution, range validation and ownership stay unchanged. */
        constants = [NSData dataWithBytes:constants.bytes
                                   length:constants.length];
        written = [NSData dataWithBytes:written.bytes length:written.length];
    }
    return [self cm_initRegisters:registers
                         vertices:vertices
                            count:count
                        constants:constants
                          written:written];
}
@end
@interface NV2AMetalWritableResult (ContextMetadataHook)
- (instancetype)cm_initReadOnlyWithConstants:(NSData *)constants
                                   registers:(id<MTLBuffer>)registers
                                    vertices:(id<MTLBuffer>)vertices
                                       count:(NSUInteger)count
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalWritableResult (ContextMetadataHook)
- (instancetype)cm_initReadOnlyWithConstants:(NSData *)constants
                                   registers:(id<MTLBuffer>)registers
                                    vertices:(id<MTLBuffer>)vertices
                                       count:(NSUInteger)count
{
    cm_ro_calls++;
    if (!cm_reference_readonly)
        return [self cm_initReadOnlyWithConstants:constants
                                        registers:registers
                                         vertices:vertices
                                            count:count];
    /* Exactly the former readonly stack context -> owning result initializer.
     * This hook runs after the original admission/fault checks. */
    NV2AMetalWritableContext context = { 0 };
    assert(constants.length == sizeof(context.constants));
    memcpy(context.constants, constants.bytes, sizeof(context.constants));
    return [self initWithContext:&context
                       registers:registers
                        vertices:vertices
                           count:count];
}
@end
static void cm_scope(void)
{
    cm_constant_copies = cm_written_copies = cm_ro_calls = 0;
    cm_counting = YES;
}
static void cm_copies(NSUInteger constants, NSUInteger written)
{
    cm_counting = NO;
    assert(cm_constant_copies == constants && cm_written_copies == written);
}
static NV2AMetalPGRAPHVertexState *cm_capture(BOOL programmed, BOOL raw)
{
    NSMutableData *data = [capture(5, programmed, 0) mutableCopy];
    if (raw) {
        metadata_word(data, 4, 6);
        metadata_word(data, 8, metadata_read(data, 8) | 64);
        if (programmed) {
            memset((uint8_t *)data.mutableBytes + 32 +
                       sizeof(NV2AMetalProgramInput) +
                       sizeof(((NV2AMetalProgramUniforms *)0)->constants),
                   0,
                   sizeof(NV2AMetalProgramUniforms) -
                       sizeof(((NV2AMetalProgramUniforms *)0)->constants));
        } else {
            /* Fixed raw XF still validates point/fog/lighting context. Only
             * surface dimensions and zmax are omitted from its capture. */
            NSUInteger common = 32 + sizeof(NV2AMetalProgramInput);
            metadata_word(
                data, common + offsetof(NV2AMetalProgramUniforms, surface_size),
                0);
            metadata_word(
                data,
                common + offsetof(NV2AMetalProgramUniforms, surface_size) + 4,
                0);
            metadata_word(data,
                          common + offsetof(NV2AMetalProgramUniforms, zmax), 0);
        }
    }
    if (programmed) {
        Token tokens[2] = { token(1, 0, 96), token(1, 0, 96) };
        source(&tokens[0], 0, 2, 0, 0xe4);
        destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
        tokens[1].word[1] |= 3u << 9;
        source(&tokens[1], 0, 2, 0, 0xe4);
        destination(&tokens[1], 0x103, 15, 0, 0, 0, 0);
        tokens[1].word[3] |= 1;
        [data setLength:data.length - 16];
        metadata_word(data, 28, 2);
        append(data, tokens, sizeof(tokens));
    }
    NSError *error = nil;
    NV2AMetalPGRAPHVertexState *state =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:data error:&error];
    require(state != nil, error);
    return state;
}
static void cm_metadata_equal(NV2AMetalEpochResult *a, NV2AMetalEpochResult *b)
{
    assert(a && b && a.vertexCount == b.vertexCount &&
           a.constants.length == 3072 && a.written.length == 768 &&
           [a.constants isEqual:b.constants] && [a.written isEqual:b.written]);
    const uint32_t *flags = a.written.bytes;
    for (unsigned row = 0; row < 192; row++)
        assert(!flags[row]);
}
static void cm_equal(NV2AMetalEpochResult *a, NV2AMetalEpochResult *b)
{
    cm_metadata_equal(a, b);
    assert(!!a.registers == !!b.registers && !!a.vertices == !!b.vertices);
    if (a.vertexCount) {
        if (a.registers)
            assert(!memcmp(a.registers.contents, b.registers.contents,
                           a.vertexCount * sizeof(NV2AMetalProgramOutput)));
        if (a.vertices)
            assert(!memcmp(a.vertices.contents, b.vertices.contents,
                           a.vertexCount * sizeof(NV2AMetalVertex)));
    }
}
static NV2AMetalEpochResult *cm_run(NV2AMetalEpochExecutor *executor,
                                    NV2AMetalCommands *commands,
                                    NV2AMetalPGRAPHVertexState *state,
                                    id<MTLBuffer> input, NSUInteger count,
                                    BOOL compact)
{
    NSError *error = nil;
    if (!compact)
        return [executor executeState:state
                      attributeBuffer:input
                                first:1
                                count:count
                                error:&error];
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalEpochEncoding *encoded = [executor encodeRasterState:state
                                                  attributeBuffer:input
                                                            first:1
                                                            count:count
                                                         commands:commands
                                                            error:&error];
    require(encoded != nil, error);
    finish(commands);
    return [encoded resolveWithError:&error];
}
static void cm_fixed(NV2AMetalCommands *commands, id<MTLBuffer> input)
{
    NSError *error = nil;
    unsigned pairs = 0;
    for (unsigned raw = 0; raw < 2; raw++)
        for (unsigned compact = 0; compact < 2; compact++) {
            NV2AMetalEpochExecutor *executor =
                [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                         error:&error];
            require(executor != nil, error);
            NV2AMetalPGRAPHVertexState *state = cm_capture(NO, raw);
            NSData *before = state.snapshotData;
            cm_scope();
            NV2AMetalEpochResult *cold =
                cm_run(executor, commands, state, input, 3, compact);
            cm_copies(1, 0);
            require(cold != nil, error);
            assert([state stateByApplyingConstants:cold.constants
                                           written:cold.written
                                             error:&error] == state);
            for (unsigned empty = 0; empty < 2; empty++) {
                cm_scope();
                NV2AMetalEpochResult *actual = cm_run(
                    executor, commands, state, input, empty ? 0 : 3, compact);
                cm_copies(0, 0);
                cm_reference_fixed = YES;
                cm_scope();
                NV2AMetalEpochResult *reference = cm_run(
                    executor, commands, state, input, empty ? 0 : 3, compact);
                cm_copies(1, 1);
                cm_reference_fixed = NO;
                cm_equal(actual, reference);
                assert(actual.constants == cold.constants &&
                       actual.written == cold.written);
                pairs++;
            }
            assert([before isEqual:state.snapshotData]);
            cm_scope();
            assert(![executor executeState:state
                           attributeBuffer:input
                                     first:NSUIntegerMax
                                     count:1
                                     error:&error] &&
                   error);
            cm_copies(0, 0);
        }
    /* Cache identity must not cross a changed clone or an external restore. */
    NV2AMetalEpochExecutor *executor =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                 error:&error];
    NV2AMetalPGRAPHVertexState *state = cm_capture(NO, NO);
    NV2AMetalEpochResult *old =
        cm_run(executor, commands, state, input, 3, YES);
    NSMutableData *changed = [old.constants mutableCopy];
    uint32_t bits = 0x7fa12345u, flags[192] = { 0 };
    memcpy((uint8_t *)changed.mutableBytes + 191 * 16, &bits, 4);
    flags[191] = 1;
    NV2AMetalPGRAPHVertexState *clone =
        [state stateByApplyingConstants:changed
                                written:[NSData dataWithBytes:flags
                                                       length:sizeof(flags)]
                                  error:&error];
    require(clone && clone != state, error);
    NSData *wire = clone.snapshotData;
    NV2AMetalPGRAPHVertexState *restored =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire error:&error];
    require(restored != nil, error);
    NV2AMetalEpochResult *next =
                             cm_run(executor, commands, clone, input, 3, YES),
                         *after = cm_run(executor, commands, restored, input, 3,
                                         YES);
    cm_equal(next, after);
    assert([next.constants isEqual:changed] &&
           ![old.constants isEqual:changed] &&
           [restored.snapshotData isEqual:wire]);
    ContextMetadataCapture *dynamic =
        [[ContextMetadataCapture alloc] initWithSnapshot:state.snapshotData
                                                   error:&error];
    require(dynamic != nil, error);
    dynamic.marker = 0x3f800000;
    cm_scope();
    NV2AMetalEpochResult *one =
        cm_run(executor, commands, dynamic, input, 3, YES);
    dynamic.marker = 0x40000000;
    NV2AMetalEpochResult *two =
        cm_run(executor, commands, dynamic, input, 3, YES);
    cm_copies(2, 0);
    assert(![one.constants isEqual:two.constants]);
    printf(
        "Context metadata Fixed: %u exact full/compact/raw/count0 "
        "copy-reference pairs; clone/restore/subclass and range guards PASS\n",
        pairs);
}
static void cm_readonly_tests(NV2AMetalCommands *commands, id<MTLBuffer> input)
{
    NSError *error = nil;
    NV2AMetalEpochExecutor *executor =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                 error:&error];
    require(executor != nil, error);
    unsigned pairs = 0;
    for (unsigned raw = 0; raw < 2; raw++)
        for (unsigned compact = 0; compact < 2; compact++)
            for (unsigned empty = 0; empty < 2; empty++) {
                NV2AMetalPGRAPHVertexState *state = cm_capture(YES, raw);
                /* Initial readonly encoding still takes its one original
                 * constant snapshot; measure result construction separately. */
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalEpochEncoding *encoded =
                    compact ? [executor encodeRasterState:state
                                          attributeBuffer:input
                                                    first:1
                                                    count:empty ? 0 : 3
                                                 commands:commands
                                                    error:&error] :
                              [executor encodeState:state
                                    attributeBuffer:input
                                              first:1
                                              count:empty ? 0 : 3
                                           commands:commands
                                              error:&error];
                require(encoded != nil, error);
                NV2AMetalEpochResult *pending = nil;
                if (compact) {
                    cm_scope();
                    pending = [encoded pendingResultForCommands:commands
                                                          error:&error];
                    cm_copies(0, 0);
                    require(pending != nil, error);
                    assert(cm_ro_calls == 1);
                    cm_reference_readonly = YES;
                    cm_scope();
                    NV2AMetalEpochResult *reference =
                        [encoded pendingResultForCommands:commands
                                                    error:&error];
                    cm_copies(1, 1);
                    cm_reference_readonly = NO;
                    cm_metadata_equal(pending, reference);
                    assert(pending.vertices == reference.vertices &&
                           !pending.registers && !reference.registers);
                }
                finish(commands);
                cm_scope();
                NV2AMetalEpochResult *actual =
                    [encoded resolveWithError:&error];
                cm_copies(0, 0);
                assert(cm_ro_calls == 1);
                cm_reference_readonly = YES;
                cm_scope();
                NV2AMetalEpochResult *reference =
                    [encoded resolveWithError:&error];
                cm_copies(1, 1);
                cm_reference_readonly = NO;
                cm_equal(actual, reference);
                assert(actual.constants == [[encoded valueForKey:@"program"]
                                               valueForKey:@"constants"]);
                if (pending) {
                    cm_equal(pending, actual);
                    assert(pending.constants == actual.constants);
                }
                pairs++;
            }
    /* Actual proof admission remains bound to its original live recording. */
    NV2AMetalPGRAPHVertexState *state = cm_capture(YES, NO);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalEpochEncoding *encoded = [executor encodeRasterState:state
                                                  attributeBuffer:input
                                                            first:1
                                                            count:3
                                                         commands:commands
                                                            error:&error];
    require(encoded != nil, error);
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(foreign != nil, error);
    cm_scope();
    assert(![encoded pendingResultForCommands:foreign error:&error] && error);
    [commands cancel];
    assert(![encoded pendingResultForCommands:commands error:&error]);
    require([commands beginWithError:&error] != nil, error);
    assert(![encoded pendingResultForCommands:commands error:&error]);
    cm_copies(0, 0);
    assert(!cm_ro_calls);
    [commands cancel];
    printf("Context metadata readonly: %u exact full/compact/raw/count0 "
           "copy-reference pairs; pending/resolve and foreign/cancel/reuse "
           "guards PASS\n",
           pairs);
}
static void cm_faults(NV2AMetalCommands *commands, id<MTLBuffer> input)
{
    NSError *error = nil;
    NV2AMetalEpochExecutor *executor =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                 error:&error];
    require(executor != nil, error);
    NV2AMetalProgramInput values[5];
    assert(input.length == sizeof(values));
    memcpy(values, input.contents, sizeof(values));
    /* The third executed vertex faults after two valid ARL/relative reads. */
    values[1].attributes[1][0] = 0;
    values[2].attributes[1][0] = 1;
    values[3].attributes[1][0] = 1000;
    id<MTLBuffer> faultInput =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    require(faultInput != nil, error);
    NSMutableData *bytes = nonwriting_wire(0, 0, 3);
    metadata_word(bytes, 8, metadata_read(bytes, 8) & ~32u);
    NV2AMetalPGRAPHVertexState *state =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bytes
                                                       error:&error];
    require(state != nil, error);
    assert(!state.writeEnable && state.dynamicAddressing);
    for (unsigned compact = 0; compact < 2; compact++) {
        /* The same real GPU program accepts both preceding vertices. Its
         * ARL source is attribute1.x, giving USER constants96 and97. */
        cm_scope();
        error = nil;
        NV2AMetalEpochResult *prefix =
            compact ? [executor executeRasterState:state
                                   attributeBuffer:faultInput
                                             first:1
                                             count:2
                                             error:&error] :
                      [executor executeState:state
                             attributeBuffer:faultInput
                                       first:1
                                       count:2
                                       error:&error];
        cm_copies(compact ? 0 : 1, 0);
        assert(prefix && !error && prefix.vertexCount == 2 && cm_ro_calls == 1);
        NV2AMetalProgramUniforms uniforms = state.programUniforms;
        assert(!memcmp(prefix.constants.bytes, uniforms.constants,
                       sizeof(uniforms.constants)));
        const uint32_t *dirty = prefix.written.bytes;
        for (unsigned row = 0; row < 192; row++)
            assert(!dirty[row]);
        NSError *first = nil;
        for (unsigned reference = 0; reference < 2; reference++) {
            cm_reference_readonly = reference;
            cm_scope();
            error = nil;
            NV2AMetalEpochResult *result =
                compact ? [executor executeRasterState:state
                                       attributeBuffer:faultInput
                                                 first:1
                                                 count:3
                                                 error:&error] :
                          [executor executeState:state
                                 attributeBuffer:faultInput
                                           first:1
                                           count:3
                                           error:&error];
            /* The accepted prefix warmed this program's exact initial
             * constants. Faulting ranges reuse that immutable snapshot; no
             * result initializer or publication bypasses the GPU fault. */
            cm_copies(0, 0);
            assert(!result && error && !cm_ro_calls &&
                   [error.localizedDescription
                       isEqual:@"Native writable-vertex address fault"]);
            if (first)
                assert([first.domain isEqual:error.domain] &&
                       first.code == error.code &&
                       [first.localizedDescription
                           isEqual:error.localizedDescription]);
            else
                first = error;
            cm_reference_readonly = NO;
        }
    }
    /* wire() selects attribute1 in token1.word1 bits9..12 and writes191.
     * The final executed vertex is source3 (first1 + count3 - 1). */
    state = [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire(5, 1, 3)
                                                           error:&error];
    require(state != nil, error);
    cm_scope();
    NV2AMetalEpochResult *written = [executor executeRasterState:state
                                                 attributeBuffer:input
                                                           first:1
                                                           count:3
                                                           error:&error];
    cm_counting = NO;
    require(written != nil, error);
    assert(!cm_ro_calls &&
           ((const uint32_t *)written.written.bytes)[191] == 1 &&
           !memcmp(
               (const uint8_t *)written.constants.bytes + 191 * 16,
               ((const NV2AMetalProgramInput *)input.contents)[3].attributes[1],
               16));
    puts("Context metadata: later readonly ARL fault before result "
         "construction, full/compact error identity and real writer context "
         "PASS");
}
static void cm_lifetime(NV2AMetalCommands *commands, id<MTLBuffer> input)
{
    NSError *error = nil;
    for (unsigned programmed = 0; programmed < 2; programmed++) {
        NV2AMetalEpochResult *result;
        __weak NV2AMetalEpochExecutor *weakExecutor;
        __weak NV2AMetalPGRAPHVertexState *weakState;
        uint8_t expected[3072];
        @autoreleasepool {
            NV2AMetalEpochExecutor *executor =
                [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                         error:&error];
            NV2AMetalPGRAPHVertexState *state = cm_capture(programmed, NO);
            weakExecutor = executor;
            weakState = state;
            NV2AMetalProgramUniforms u = state.programUniforms;
            memcpy(expected, u.constants, sizeof(expected));
            result = cm_run(executor, commands, state, input, 3, YES);
            require(result != nil, error);
        }
        assert(!weakExecutor && !weakState &&
               !memcmp(result.constants.bytes, expected, sizeof(expected)));
        /* New capture/clone/restore activity cannot repoint old result bytes.
         */
        NV2AMetalPGRAPHVertexState *different =
            [[NV2AMetalPGRAPHVertexState alloc]
                initWithSnapshot:capture(5, programmed, 2)
                           error:&error];
        require(different != nil, error);
        NSData *wire = different.snapshotData;
        NV2AMetalPGRAPHVertexState *restored =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire
                                                           error:&error];
        assert(restored && [restored.snapshotData isEqual:wire] &&
               !memcmp(result.constants.bytes, expected, sizeof(expected)) &&
               result.written == nv2a_metal_zero_constant_writes());
    }
    NSMutableData *mutable = [NSMutableData dataWithLength:3072];
    memset(mutable.mutableBytes, 0xa5, mutable.length);
    NV2AMetalWritableResult *owned =
        [[NV2AMetalWritableResult alloc] initReadOnlyWithConstants:mutable
                                                         registers:nil
                                                          vertices:nil
                                                             count:0];
    memset(mutable.mutableBytes, 0x5a, mutable.length);
    assert(owned.constants.length == 3072 && owned.vertexCount == 0 &&
           !owned.vertices && !owned.registers &&
           ![owned.constants isKindOfClass:NSMutableData.class]);
    const uint8_t *bytes = owned.constants.bytes;
    for (NSUInteger i = 0; i < owned.constants.length; i++)
        assert(bytes[i] == 0xa5);
    puts("Context metadata: owning immutable result after "
         "capture/encoding/executor release and defensive mutable-input copy "
         "PASS");
}
static void cm_parallel_fixed(NV2AMetalCommands *commands, id<MTLBuffer> input)
{
    NSError *error = nil;
    NV2AMetalEpochExecutor *executor =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                 error:&error];
    require(executor != nil, error);
    NV2AMetalPGRAPHVertexState *original = cm_capture(NO, YES);
    NV2AMetalFixedUniforms uniforms = original.fixedUniforms;
    NSData *first = [NSData dataWithBytes:uniforms.common.constants
                                   length:sizeof(uniforms.common.constants)];
    NSMutableData *changed = [first mutableCopy];
    uint32_t marker = 0x7fa54321u, flags[192] = { 0 };
    memcpy((uint8_t *)changed.mutableBytes + 191 * 16, &marker, 4);
    flags[191] = 1;
    NV2AMetalPGRAPHVertexState *clone =
        [original stateByApplyingConstants:changed
                                   written:[NSData dataWithBytes:flags
                                                          length:sizeof(flags)]
                                     error:&error];
    require(clone && clone != original, error);
    NSArray<NV2AMetalPGRAPHVertexState *> *states = @[ original, clone ];
    NSArray<NSData *> *expected = @[ first, [changed copy] ];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:64];
    for (NSUInteger i = 0; i < 64; i++)
        [results addObject:NSNull.null];
    assert(!executor.commands.commandBuffer &&
           executor.commands.recordingSerial == 0);
    /* Compact raw Fixed discards every GPU output before command begin. This
     * exercises the synchronized cache on its real public CPU-only route. */
    dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                   ^(size_t job) {
                     @autoreleasepool {
                         assert(!cm_counting && !cm_reference_fixed &&
                                !cm_reference_readonly);
                         NSError *jobError = nil;
                         NV2AMetalEpochResult *result =
                             [executor executeRasterState:states[job % 2]
                                          attributeBuffer:input
                                                    first:1
                                                    count:3
                                                    error:&jobError];
                         require(result != nil, jobError);
                         @synchronized(results) {
                             results[job] = result;
                         }
                     }
                   });
    assert(!executor.commands.commandBuffer &&
           executor.commands.recordingSerial == 0);
    for (NSUInteger i = 0; i < results.count; i++) {
        NV2AMetalEpochResult *result = results[i];
        assert(result.vertexCount == 3 && !result.registers &&
               !result.vertices && [result.constants isEqual:expected[i % 2]] &&
               result.written == nv2a_metal_zero_constant_writes());
    }
    puts("Context metadata:64 parallel CPU-only raw Fixed discard results, two "
         "immutable captures, exact bytes and no recording PASS");
}
static void context_metadata_tests(NV2AMetalCommands *commands)
{
    /* One process-wide zero mask allocation is outside per-result counts. */
    NSData *zero = nv2a_metal_zero_constant_writes();
    assert(zero.length == 768 && ![zero isKindOfClass:NSMutableData.class]);
    const uint8_t *bytes = zero.bytes;
    for (NSUInteger i = 0; i < zero.length; i++)
        assert(!bytes[i]);
    NV2AMetalProgramInput values[5] = { 0 };
    for (unsigned v = 0; v < 5; v++)
        for (unsigned a = 0; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                values[v].attributes[a][k] =
                    k == 3 ? 1 : (v + a + k + 1) * .125f;
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    Method methods[] = {
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:)),
        class_getInstanceMethod(
            NV2AMetalEpochResult.class,
            @selector(initRegisters:vertices:count:constants:written:)),
        class_getInstanceMethod(
            NV2AMetalWritableResult.class,
            @selector(initReadOnlyWithConstants:registers:vertices:count:))
    };
    Method hooks[] = {
        class_getInstanceMethod(
            NV2AMetalEpochResult.class,
            @selector(cm_initRegisters:vertices:count:constants:written:)),
        class_getInstanceMethod(
            NV2AMetalWritableResult.class,
            @selector(cm_initReadOnlyWithConstants:registers:vertices:count:))
    };
    for (unsigned i = 0; i < 3; i++)
        assert(methods[i]);
    cm_data_original = (void *)method_getImplementation(methods[0]);
    assert(cm_data_original);
    method_setImplementation(methods[0], (IMP)cm_data);
    for (unsigned i = 0; i < 2; i++) {
        assert(hooks[i]);
        method_exchangeImplementations(methods[i + 1], hooks[i]);
    }
    @try {
        cm_fixed(commands, input);
        cm_readonly_tests(commands, input);
        cm_faults(commands, input);
        cm_lifetime(commands, input);
        cm_parallel_fixed(commands, input);
    } @finally {
        cm_counting = cm_reference_fixed = cm_reference_readonly = NO;
        method_setImplementation(methods[0], (IMP)cm_data_original);
        for (unsigned i = 0; i < 2; i++)
            method_exchangeImplementations(methods[i + 1], hooks[i]);
    }
}
#endif
