/* Owning initial XF constants snapshots versus the original per-range copy.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_INITIAL_CONSTANTS_H
#define TEST_METAL_INITIAL_CONSTANTS_H
#import <objc/runtime.h>
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-types.h"
@interface NV2AMetalWritableProgram (InitialConstantsTest)
- (NSData *)snapshotConstants:(const float *)constants;
@end
static _Thread_local BOOL ic_active, ic_reference, ic_mutable;
static _Thread_local NSUInteger ic_copies, ic_calls;
static _Thread_local uint8_t ic_expected[3072];
static NSMutableData *ic_mutable_input;
static id (*ic_data_original)(id, SEL, const void *, NSUInteger);
static id ic_data(id cls, SEL selector, const void *bytes, NSUInteger length)
{
    if (ic_active && length == sizeof(ic_expected) &&
        !memcmp(bytes, ic_expected, sizeof(ic_expected)))
        ic_copies++;
    return ic_data_original(cls, selector, bytes, length);
}
static id (*ic_snapshot_original)(id, SEL, const float *);
static id ic_snapshot(id program, SEL selector, const float *constants)
{
    if (!ic_active)
        return ic_snapshot_original(program, selector, constants);
    ic_calls++;
    if (ic_mutable)
        return ic_mutable_input;
    /* Exactly the old owning snapshot at the same final construction point.
     * Neither admission, GPU encoding nor result resolution is replaced. */
    if (ic_reference)
        return [NSData dataWithBytes:constants length:sizeof(ic_expected)];
    return ic_snapshot_original(program, selector, constants);
}
static void ic_scope(const void *expected)
{
    memcpy(ic_expected, expected, sizeof(ic_expected));
    ic_copies = ic_calls = 0;
    ic_active = YES;
}
static void ic_finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
}
static NV2AMetalValidatedProgram *ic_program(void)
{
    Token tokens[3] = { token(1, 0, 96), token(1, 0, 96), token(1, 0, 96) };
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1].word[1] |= 3u << 9;
    source(&tokens[1], 0, 2, 0, 0xe4);
    destination(&tokens[1], 0x103, 15, 0, 0, 0, 0);
    source(&tokens[2], 0, 3, 0, 0xe4);
    destination(&tokens[2], 0x109, 15, 0, 0, 0, 0);
    tokens[2].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:3
                                                    error:&error];
    require(program != nil, error);
    return program;
}
static void ic_equal(NV2AMetalWritableResult *a, NV2AMetalWritableResult *b)
{
    assert(a && b && a.vertexCount == b.vertexCount &&
           [a.constants isEqual:b.constants] && [a.written isEqual:b.written]);
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
static NSArray<NV2AMetalWritableResult *> *
ic_ranges(id<MTLDevice> device, id<MTLBuffer> attributes, BOOL compact,
          BOOL rasterize, BOOL reference)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    NSMutableArray<NV2AMetalWritableEncoding *> *encodings =
        [NSMutableArray new];
    __weak NV2AMetalWritableProgram *weakOwner;
    const NSUInteger starts[] = { 0, 2, 8, 5, 1, 4 };
    const NSUInteger counts[] = { 3, 2, 0, 1, 1, 2 };
    uint8_t expected[2][3072];
    NSUInteger copies[6], calls[6];
    NV2AMetalProgramUniforms base = uniforms();
    const uint32_t edge[] = { 0x80000000, 0x7fa12345, 0x7fc54321, 1 };
    memcpy(base.constants[191], edge, sizeof(edge));
    memcpy(expected[0], base.constants, sizeof(expected[0]));
    memcpy(expected[1], base.constants, sizeof(expected[1]));
    float changed = 2.5f;
    memcpy(expected[1] + 96 * 16, &changed, 4);
    @autoreleasepool {
        NV2AMetalWritableProgram *engine =
            [[NV2AMetalWritableProgram alloc] initWithDevice:device
                                                       error:&error];
        require(engine != nil, error);
        weakOwner = engine;
        NV2AMetalValidatedProgram *program = ic_program();
        require([commands beginWithError:&error] != nil, error);
        for (unsigned i = 0; i < 6; i++) {
            NV2AMetalProgramUniforms u = base;
            memcpy(u.constants, expected[i == 4], sizeof(u.constants));
            u.point_size =
                i + 1; // Unrelated uniforms and range are not key data.
            ic_reference = reference;
            ic_scope(u.constants);
            NV2AMetalWritableEncoding *encoded =
                [engine encodeProgram:program
                             uniforms:&u
                      attributeBuffer:attributes
                                first:starts[i]
                                count:counts[i]
                               access:1
                          writeEnable:NO
                            rasterize:rasterize
                     compactRegisters:compact
                             commands:commands
                                error:&error];
            ic_active = NO;
            copies[i] = ic_copies;
            calls[i] = ic_calls;
            require(encoded != nil, error);
            [encodings addObject:encoded];
            /* Caller storage changes before any GPU dispatch is submitted. */
            memset(u.constants, 0xa5, sizeof(u.constants));
        }
        /* A warm key cannot bypass failed range or uniform preflight. */
        for (unsigned invalid = 0; invalid < 2; invalid++) {
            NV2AMetalProgramUniforms u = base;
            if (invalid)
                u.surface_size[0] = 0;
            ic_scope(u.constants);
            error = nil;
            assert(![engine encodeProgram:program
                                 uniforms:&u
                          attributeBuffer:attributes
                                    first:invalid ? 0 : 9
                                    count:1
                                   access:1
                              writeEnable:NO
                                rasterize:YES
                         compactRegisters:YES
                                 commands:commands
                                    error:&error] &&
                   error);
            ic_active = NO;
            assert(!ic_calls && !ic_copies);
        }
        dispatch_queue_t queue = [engine valueForKey:@"specializationQueue"];
        dispatch_sync(queue, ^{
                      });
    }
    assert(!weakOwner);
    ic_finish(commands);
    NSMutableArray<NV2AMetalWritableResult *> *results = [NSMutableArray new];
    for (unsigned i = 0; i < encodings.count; i++) {
        error = nil;
        NV2AMetalWritableResult *result =
            [encodings[i] resolveWithError:&error];
        require(result != nil, error);
        /* Byte-first oracle: a stale cache must fail after real GPU completion
         * before any allocation-count or identity assertions. */
        assert(result.constants.length == sizeof(expected[0]) &&
               !memcmp(result.constants.bytes, expected[i == 4],
                       sizeof(expected[0])));
        assert(result.vertexCount == counts[i] && result.written.length == 768);
        const uint32_t *dirty = result.written.bytes;
        for (unsigned row = 0; row < 192; row++)
            assert(!dirty[row]);
        if (!compact && counts[i]) {
            const NV2AMetalProgramOutput *raw = result.registers.contents;
            for (NSUInteger v = 0; v < counts[i]; v++) {
                assert(!raw[v].fault &&
                       !memcmp(raw[v].registers[9], expected[i == 4] + 96 * 16,
                               16));
            }
        }
        [results addObject:result];
    }
    for (unsigned i = 0; i < 6; i++) {
        assert(calls[i] == 1 &&
               copies[i] == (reference || i == 0 || i >= 4 ? 1u : 0u));
        assert(results[i].constants == [encodings[i] valueForKey:@"constants"]);
        if (!reference && i > 0 && i < 4)
            assert(results[i].constants == results[0].constants);
    }
    ic_reference = NO;
    return results;
}
static void ic_bits(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *engine =
        [[NV2AMetalWritableProgram alloc] initWithDevice:device error:&error];
    require(engine != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    const uint32_t bits[] = { 0, 0x80000000, 0x7fa12345, 0x7fc54321, 1 };
    NSMutableArray<NSData *> *retained = [NSMutableArray new];
    for (unsigned i = 0; i < sizeof(bits) / sizeof(bits[0]); i++) {
        memcpy(&u.constants[191][3], &bits[i], 4);
        for (unsigned repeat = 0; repeat < 2; repeat++) {
            ic_scope(u.constants);
            NSData *snapshot = [engine snapshotConstants:&u.constants[0][0]];
            ic_active = NO;
            assert(snapshot.length == sizeof(u.constants) &&
                   !memcmp(snapshot.bytes, u.constants, sizeof(u.constants)));
            assert(ic_calls == 1 && ic_copies == (repeat ? 0u : 1u));
            [retained addObject:snapshot];
        }
    }
    memset(u.constants, 0x5a, sizeof(u.constants));
    for (unsigned i = 0; i < retained.count; i++) {
        uint32_t value;
        memcpy(&value, (const uint8_t *)retained[i].bytes + 191 * 16 + 12, 4);
        assert(value == bits[i / 2]);
    }
}
static void ic_mutable_owner(id<MTLDevice> device, id<MTLBuffer> attributes)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalWritableProgram *engine =
        [[NV2AMetalWritableProgram alloc] initWithDevice:device error:&error];
    require(commands && engine, error);
    NV2AMetalProgramUniforms u = uniforms();
    uint8_t expected[3072];
    memcpy(expected, u.constants, sizeof(expected));
    ic_mutable_input = [NSMutableData dataWithBytes:u.constants
                                             length:sizeof(u.constants)];
    require([commands beginWithError:&error] != nil, error);
    ic_scope(u.constants);
    ic_mutable = YES;
    NV2AMetalWritableEncoding *encoded = [engine encodeProgram:ic_program()
                                                      uniforms:&u
                                               attributeBuffer:attributes
                                                         first:1
                                                         count:2
                                                        access:1
                                                   writeEnable:NO
                                                     rasterize:YES
                                              compactRegisters:YES
                                                      commands:commands
                                                         error:&error];
    ic_active = ic_mutable = NO;
    require(encoded != nil, error);
    memset(ic_mutable_input.mutableBytes, 0xa5, ic_mutable_input.length);
    memset(u.constants, 0x5a, sizeof(u.constants));
    ic_mutable_input = nil;
    ic_finish(commands);
    NV2AMetalWritableResult *result = [encoded resolveWithError:&error];
    require(result != nil, error);
    assert(!memcmp(result.constants.bytes, expected, sizeof(expected)) &&
           ![result.constants isKindOfClass:NSMutableData.class]);
}
static void ic_faults(id<MTLDevice> device, id<MTLBuffer> attributes)
{
    NSError *error = nil;
    NV2AMetalProgramInput values[8];
    assert(attributes.length == sizeof(values));
    memcpy(values, attributes.contents, sizeof(values));
    values[1].attributes[0][0] = 0;
    values[2].attributes[0][0] = 1;
    values[3].attributes[0][0] = 1000;
    id<MTLBuffer> input =
        [device newBufferWithBytes:values
                            length:sizeof(values)
                           options:MTLResourceStorageModeShared];
    require(input != nil, error);
    Token tokens[2];
    proof_cache_tokens(tokens, YES);
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:2
                                                    error:&error];
    require(program != nil, error);
    for (unsigned compact = 0; compact < 2; compact++) {
        NSError *first = nil;
        for (unsigned reference = 0; reference < 2; reference++) {
            NV2AMetalWritableProgram *engine =
                [[NV2AMetalWritableProgram alloc] initWithDevice:device
                                                           error:&error];
            NV2AMetalCommands *commands =
                [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
            require(engine && commands, error);
            NV2AMetalProgramUniforms u = uniforms();
            require([commands beginWithError:&error] != nil, error);
            ic_reference = reference;
            ic_scope(u.constants);
            NV2AMetalWritableEncoding *encoded = [engine encodeProgram:program
                                                              uniforms:&u
                                                       attributeBuffer:input
                                                                 first:1
                                                                 count:3
                                                                access:0
                                                           writeEnable:NO
                                                             rasterize:YES
                                                      compactRegisters:compact
                                                              commands:commands
                                                                 error:&error];
            ic_active = NO;
            require(encoded != nil, error);
            assert(ic_calls == 1 && ic_copies == 1);
            ic_finish(commands);
            error = nil;
            assert(![encoded resolveWithError:&error] && error &&
                   [error.localizedDescription
                       isEqual:@"Native writable-vertex address fault"]);
            if (first)
                assert([first.domain isEqual:error.domain] &&
                       first.code == error.code);
            else
                first = error;
        }
    }
    ic_reference = NO;
}
static void ic_writers(id<MTLDevice> device, id<MTLBuffer> attributes)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *engine =
        [[NV2AMetalWritableProgram alloc] initWithDevice:device error:&error];
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(engine && commands, error);
    Token tokens[7];
    writable_tokens(tokens, 96, 3, 15);
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:7
                                                    error:&error];
    require(program != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    float expected[192][4];
    memcpy(expected, u.constants, sizeof(expected));
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *previous = nil;
    NSMutableArray<NV2AMetalWritableEncoding *> *encodings =
        [NSMutableArray new];
    for (unsigned hop = 0; hop < 2; hop++) {
        ic_scope(u.constants);
        NV2AMetalWritableEncoding *encoded =
            [engine encodeSerialProgram:program
                               uniforms:&u
                        attributeBuffer:attributes
                                  first:hop * 3
                                  count:2
                                 access:1
                              rasterize:YES
                               previous:previous
                               commands:commands
                                  error:&error];
        ic_active = NO;
        require(encoded != nil, error);
        assert(!ic_calls && ic_copies == (hop ? 0u : 1u));
        [encodings addObject:encoded];
        previous = encoded;
        /* Child CPU constants are not the chained GPU predecessor. */
        u.constants[191][0] = -123;
    }
    ic_finish(commands);
    const NV2AMetalProgramInput *input = attributes.contents;
    NSData *baseline = [encodings[0] valueForKey:@"constants"];
    for (unsigned hop = 0; hop < 2; hop++) {
        for (unsigned v = hop * 3; v < hop * 3 + 2; v++)
            for (unsigned k = 0; k < 4; k++)
                expected[96][k] += input[v].attributes[3][k];
        NV2AMetalWritableResult *result =
            [encodings[hop] resolveWithError:&error];
        require(result != nil, error);
        assert(!memcmp(result.constants.bytes, expected, sizeof(expected)));
        const uint32_t *dirty = result.written.bytes;
        for (unsigned row = 0; row < 192; row++)
            assert(dirty[row] == (row == 96));
        assert([encodings[hop] valueForKey:@"constants"] == baseline);
    }
}
static void initial_constants_tests(NV2AMetalCommands *commands)
{
    id<MTLDevice> device = commands.device;
    NV2AMetalProgramInput values[8];
    for (unsigned v = 0; v < 8; v++)
        writable_input(&values[v], v);
    id<MTLBuffer> attributes =
        [device newBufferWithBytes:values
                            length:sizeof(values)
                           options:MTLResourceStorageModeShared];
    assert(attributes);
    Method helper = class_getInstanceMethod(NV2AMetalWritableProgram.class,
                                            @selector(snapshotConstants:));
    Method factory =
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:));
    assert(helper && factory);
    ic_snapshot_original = (void *)method_getImplementation(helper);
    ic_data_original = (void *)method_getImplementation(factory);
    method_setImplementation(factory, (IMP)ic_data);
    method_setImplementation(helper, (IMP)ic_snapshot);
    @try {
        for (unsigned compact = 0; compact < 2; compact++)
            for (unsigned rasterize = 0; rasterize < 2; rasterize++) {
                NSArray *actual =
                    ic_ranges(device, attributes, compact, rasterize, NO);
                NSArray *reference =
                    ic_ranges(device, attributes, compact, rasterize, YES);
                assert(actual.count == 6 && reference.count == actual.count);
                for (NSUInteger i = 0; i < actual.count; i++)
                    ic_equal(actual[i], reference[i]);
            }
        ic_bits(device);
        ic_mutable_owner(device, attributes);
        ic_faults(device, attributes);
        ic_writers(device, attributes);
    } @finally {
        ic_active = ic_reference = ic_mutable = NO;
        ic_mutable_input = nil;
        method_setImplementation(helper, (IMP)ic_snapshot_original);
        method_setImplementation(factory, (IMP)ic_data_original);
    }
    puts("Initial constants:24 exact full/compact/raw/raster copy-reference "
         "pairs, four equal snapshots4->1, A/B/A eviction, caller "
         "mutation/owner release, NaN/signed-zero bits, mutable ctor, faults "
         "and unchanged writer baseline PASS");
}
#endif
