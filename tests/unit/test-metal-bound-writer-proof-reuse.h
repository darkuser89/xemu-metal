/* Capture-bound writer proof memoization versus fresh cold analyses.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BOUND_WRITER_PROOF_REUSE_H
#define TEST_METAL_BOUND_WRITER_PROOF_REUSE_H
#import <objc/runtime.h>
#include <stdatomic.h>

@interface NV2AMetalValidatedProgram (BoundWriterProofReuseTest)
- (BOOL)refineIndependentConstantWrites:(unsigned)access
                              constants:(const float *)constants
                         sourceUniforms:(const NV2AMetalFetchUniforms *)fetch;
- (BOOL)boundWriterProofConstants:(const float *)constants
                     fetchDomains:(const void *)domains
                    matchSnapshot:(NSData *)snapshot;
- (NSData *)boundWriterProofKeyWithBytes:(const void *)bytes
                                  length:(NSUInteger)length;
- (BOOL)evaluateBoundWriterAccess:(unsigned)access
                        constants:(const float *)constants
                     fetchDomains:(void *)domains;
@end

static _Thread_local __unsafe_unretained NV2AMetalValidatedProgram
    *bwr_observed;
static _Thread_local BOOL bwr_force_miss, bwr_reject_key;
static _Thread_local unsigned bwr_matches, bwr_evaluations, bwr_keys;
static BOOL (*bwr_match_original)(id, SEL, const float *, const void *,
                                  NSData *);
static id (*bwr_key_original)(id, SEL, const void *, NSUInteger);
static BOOL (*bwr_evaluate_original)(id, SEL, unsigned, const float *, void *);
static BOOL bwr_match_spy(id object, SEL selector, const float *constants,
                          const void *domains, NSData *snapshot)
{
    if (object == bwr_observed) {
        bwr_matches++;
        if (bwr_force_miss)
            return NO;
    }
    return bwr_match_original(object, selector, constants, domains, snapshot);
}
static id bwr_key_spy(id object, SEL selector, const void *bytes,
                      NSUInteger length)
{
    if (object == bwr_observed) {
        bwr_keys++;
        assert(length == 4096);
        if (bwr_reject_key)
            return nil;
    }
    return bwr_key_original(object, selector, bytes, length);
}
static BOOL bwr_evaluate_spy(id object, SEL selector, unsigned access,
                             const float *constants, void *domains)
{
    if (object == bwr_observed)
        bwr_evaluations++;
    return bwr_evaluate_original(object, selector, access, constants, domains);
}
static void bwr_observe(NV2AMetalValidatedProgram *program)
{
    bwr_observed = program;
    bwr_matches = bwr_evaluations = bwr_keys = 0;
}
static void bwr_bits(float *value, uint32_t bits)
{
    memcpy(value, &bits, sizeof(bits));
}
static NV2AMetalValidatedProgram *bwr_fresh(NV2AMetalValidatedProgram *program)
{
    NSError *error = nil;
    NV2AMetalValidatedProgram *fresh = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:program.tokens.bytes
                length:program.tokens.length / 16
                 error:&error];
    require(fresh != nil, error);
    return fresh;
}
static NV2AMetalValidatedProgram *bwr_program(BOOL longProgram)
{
    Token t[NV2A_METAL_VP_SLOTS];
    unsigned n = 0;
    t[n] = token(NV2AMetalMACMov, 0, 0);
    source(t + n, 0, 2, 0, 0xe4);
    destination(t + n++, 0x100, 15, 0, 0, 0, 0);
    t[n] = token(NV2AMetalMACMov, 0, 96);
    source(t + n, 0, 3, 0, 0);
    destination(t + n++, 0, 0, 0, 6, 8, 0);
    t[n] = token(NV2AMetalMACMul, 0, 191);
    t[n].word[1] |= 15u << 9;
    source(t + n, 0, 2, 0, 0xff);
    source(t + n, 1, 3, 0, 0xff);
    destination(t + n++, 0, 0, 0, 2, 8, 0);
    t[n] = token(NV2AMetalMACMad, 0, 120);
    source(t + n, 0, 1, 2, 0);
    source(t + n, 1, 3, 0, 0xaa);
    source(t + n, 2, 1, 6, 0);
    destination(t + n++, 0, 0, 0, 7, 8, 0);
    t[n] = token(NV2AMetalMACArl, 0, 0);
    source(t + n++, 0, 1, 7, 0);
    t[n] = token(NV2AMetalMACMov, 0, 95);
    source(t + n, 0, 3, 0, 0);
    destination(t + n, 0x103, 8, 0, 0, 0, 0);
    t[n++].word[3] |= 2;
    t[n] = token(NV2AMetalMACMov, 0, 0);
    t[n].word[1] |= 5u << 9;
    source(t + n, 0, 2, 0, 0xe4);
    destination(t + n++, 150, 4, 0, 0, 0, 0);
    unsigned length = longProgram ? NV2A_METAL_VP_SLOTS : n + 1;
    while (n < length)
        t[n++] = token(0, 0, 0);
    t[n - 1].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:n
                                                    error:&error];
    require(program != nil, error);
    assert(program.mayWriteConstants &&
           ![program hasIndependentConstantWrites:0] &&
           ![program hasIndependentConstantWrites:1]);
    return program;
}
static void bwr_inputs(NV2AMetalProgramUniforms *u, NV2AMetalFetchUniforms *f)
{
    *u = uniforms();
    memset(f, 0, sizeof(*f));
    u->constants[96][0] = 0;
    u->constants[120][2] = u->constants[191][3] = 1;
}
static BOOL bwr_call(NV2AMetalValidatedProgram *program, unsigned access,
                     const NV2AMetalProgramUniforms *u,
                     const NV2AMetalFetchUniforms *f)
{
    return [program refineIndependentConstantWrites:access
                                          constants:u ? u->constants[0] : NULL
                                     sourceUniforms:f];
}
static NSData *bwr_snapshot(NV2AMetalValidatedProgram *program)
{
    return [program valueForKey:@"boundWriterProofInputs"];
}
static unsigned bwr_cases;
static void bwr_pair(NV2AMetalValidatedProgram *program,
                     NV2AMetalValidatedProgram *forced,
                     const NV2AMetalProgramUniforms *u,
                     const NV2AMetalFetchUniforms *f, unsigned allowed)
{
    for (unsigned access = 0; access < 2; access++) {
        @autoreleasepool {
            NV2AMetalValidatedProgram *fresh = bwr_fresh(program);
            BOOL expected = !!(allowed & (1u << access));
            assert(bwr_call(fresh, access, u, f) == expected);
            bwr_observe(forced);
            bwr_force_miss = YES;
            assert(bwr_call(forced, access, u, f) == expected);
            bwr_force_miss = NO;
            bwr_observe(program);
            assert(bwr_call(program, access, u, f) == expected);
            NSData *key = bwr_snapshot(program);
            unsigned evaluations = bwr_evaluations, keys = bwr_keys;
            assert(bwr_call(program, access, u, f) == expected);
            assert(bwr_evaluations == evaluations && bwr_keys == keys &&
                   bwr_snapshot(program) == key && key.length == 4096);
            bwr_cases++;
        }
    }
    bwr_observed = nil;
}
static void bwr_mutations(void)
{
    NV2AMetalValidatedProgram *program = bwr_program(NO);
    NV2AMetalValidatedProgram *forced = bwr_fresh(program);
    NV2AMetalProgramUniforms u;
    NV2AMetalFetchUniforms f;
    bwr_inputs(&u, &f);
    bwr_observe(program);
    assert(!bwr_call(program, 0, &u, &f) && bwr_call(program, 1, &u, &f));
    assert(bwr_evaluations == 2 && bwr_keys == 1);
    assert(!bwr_call(program, 0, &u, &f) && bwr_call(program, 1, &u, &f));
    assert(bwr_evaluations == 2 && bwr_keys == 1);
    bwr_pair(program, forced, &u, &f, 2);
    NSData *key = bwr_snapshot(program);
    NSData *frozen = [NSData dataWithBytes:key.bytes length:key.length];
    for (unsigned i = 0; i < 16; i++) {
        u.constants[0][0] = i;
        u.constants[191][2] = i + 100;
        f.attributes[15].inline_value[2] = i;
        f.attributes[2].stride = i + 1;
        f.current_vertex = i;
        bwr_pair(program, forced, &u, &f, 2);
        assert(bwr_snapshot(program) == key);
    }
    const uint32_t bits[] = {
        0x80000000u, 0, 0x3f800000u, 0x7fc12345u, 0x7fc54321u, 0x447a0000u, 0
    };
    const unsigned expected[] = { 2, 2, 3, 0, 0, 0, 2 };
    for (unsigned i = 0; i < sizeof(bits) / sizeof(bits[0]); i++) {
        NSData *old = bwr_snapshot(program);
        bwr_bits(&f.attributes[15].inline_value[3], bits[i]);
        bwr_pair(program, forced, &u, &f, expected[i]);
        /* NaN payloads share an unknown numerical domain; signed zeros do
         * not share exactBits. Constants below retain their raw bits. */
        assert((bwr_snapshot(program) == old) == (i == 4));
    }
    f.attributes[15].inline_value[3] = 1;
    for (unsigned span = 0; span < 3; span++) {
        float *lane = span == 0 ? &u.constants[96][0] :
                      span == 1 ? &u.constants[120][2] :
                                  &u.constants[191][3];
        float saved = *lane;
        const uint32_t values[] = { 0x80000000u, 0,           0x3f800000u,
                                    0x7fc12345u, 0x7fc54321u, 0x447a0000u };
        for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
            @autoreleasepool {
                NSData *old = bwr_snapshot(program);
                uint32_t oldBits;
                memcpy(&oldBits, lane, sizeof(oldBits));
                bwr_bits(lane, values[i]);
                /* Expected answers come from separately decoded cold programs;
                 * the explicit address witnesses above also prove YES/NO
                 * changes. */
                NV2AMetalValidatedProgram *fresh = bwr_fresh(program);
                unsigned allowed = bwr_call(fresh, 0, &u, &f) |
                                   (bwr_call(fresh, 1, &u, &f) << 1);
                bwr_pair(program, forced, &u, &f, allowed);
                if (oldBits != values[i])
                    assert(bwr_snapshot(program) != old);
            }
        }
        *lane = saved;
        bwr_pair(program, forced, &u, &f, 3);
    }
    assert([key isEqualToData:frozen]);
    NSData *bound = bwr_snapshot(program);
    assert(![program hasIndependentConstantWrites:0 constants:u.constants[0]]);
    (void)[program hasFaultFreeReadOnlyAccess:0
                                    constants:u.constants[0]
                               sourceUniforms:&f];
    assert(bwr_snapshot(program) == bound);
    bwr_pair(program, forced, &u, &f, 3);
    /* Identical numerical domains across encodings may share the key. */
    f.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL;
    f.attributes[15].count = 4;
    f.attributes[15].stride = 4;
    f.first_vertex = f.index_size = 0;
    bwr_pair(program, forced, &u, &f, 2);
    key = bwr_snapshot(program);
    f.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
    bwr_pair(program, forced, &u, &f, 2);
    assert(bwr_snapshot(program) == key);
    f.attributes[15].stride = 0;
    bwr_pair(program, forced, &u, &f, 2);
    f.attributes[15].count = 3;
    bwr_pair(program, forced, &u, &f, 3);
    f.attributes[15].count = 4;
    f.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    bwr_pair(program, forced, &u, &f, 0);
    f.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL;
    f.index_size = 4;
    f.first_vertex = 1;
    f.attributes[15].inline_value[3] = 1000;
    bwr_pair(program, forced, &u, &f, 0);
    f.first_vertex = 0;
    bwr_pair(program, forced, &u, &f, 2);
    key = bwr_snapshot(program);
    bwr_observe(program);
    assert(!bwr_call(program, 2, &u, &f) && !bwr_call(program, 0, NULL, &f) &&
           !bwr_call(program, 0, &u, NULL));
    assert(!bwr_evaluations && !bwr_keys && bwr_snapshot(program) == key);
    bwr_observed = nil;
}
static void bwr_oom_and_lifetime(void)
{
    __weak NSData *expired = nil;
    __weak NSMutableData *constantsOwner = nil;
    __weak NSMutableData *fetchOwner = nil;
    NV2AMetalValidatedProgram *program = bwr_program(NO);
    @autoreleasepool {
        NSMutableData *c = [NSMutableData dataWithLength:3072];
        NSMutableData *d =
            [NSMutableData dataWithLength:sizeof(NV2AMetalFetchUniforms)];
        constantsOwner = c;
        fetchOwner = d;
        NV2AMetalProgramUniforms u;
        NV2AMetalFetchUniforms f;
        bwr_inputs(&u, &f);
        memcpy(c.mutableBytes, u.constants, c.length);
        memcpy(d.mutableBytes, &f, d.length);
        assert([program refineIndependentConstantWrites:1
                                              constants:c.bytes
                                         sourceUniforms:d.bytes]);
        expired = bwr_snapshot(program);
    }
    assert(!constantsOwner && !fetchOwner && expired);
    NV2AMetalProgramUniforms u;
    NV2AMetalFetchUniforms f;
    bwr_inputs(&u, &f);
    f.attributes[15].inline_value[3] = 1;
    @autoreleasepool {
        bwr_observe(program);
        bwr_reject_key = YES;
        assert(bwr_call(program, 0, &u, &f) && bwr_call(program, 0, &u, &f));
        assert(bwr_evaluations == 2 && bwr_keys == 2);
        bwr_reject_key = NO;
        assert(bwr_call(program, 0, &u, &f));
        assert(bwr_evaluations == 3 && bwr_keys == 3);
        assert(bwr_call(program, 0, &u, &f) && bwr_evaluations == 3 &&
               bwr_keys == 3);
    }
    assert(!expired && bwr_snapshot(program).length == 4096);
    __weak NSData *last = nil;
    for (unsigned i = 0; i < 32; i++) {
        @autoreleasepool {
            f.attributes[15].inline_value[3] = 1 + i;
            assert(bwr_call(program, 1, &u, &f));
            last = bwr_snapshot(program);
        }
    }
    assert(last && last.length == 4096);
    bwr_observed = nil;
    program = nil;
    assert(!last);
}
static void bwr_parallel(void)
{
    NV2AMetalValidatedProgram *program = bwr_program(NO);
    NV2AMetalProgramUniforms u;
    NV2AMetalFetchUniforms f;
    bwr_inputs(&u, &f);
    assert(!bwr_call(program, 0, &u, &f) && bwr_call(program, 1, &u, &f));
    _Atomic unsigned work;
    atomic_init(&work, 0);
    _Atomic unsigned *workPointer = &work;
    dispatch_apply(
        256, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
          @autoreleasepool {
              bwr_observe(program);
              assert(bwr_call(program, i & 1, &u, &f) == (i & 1));
              atomic_fetch_add_explicit(workPointer, bwr_evaluations + bwr_keys,
                                        memory_order_relaxed);
              bwr_observed = nil;
          }
        });
    assert(!atomic_load_explicit(&work, memory_order_relaxed));
    dispatch_apply(256, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                   ^(size_t i) {
                     @autoreleasepool {
                         NV2AMetalProgramUniforms local = u;
                         NV2AMetalFetchUniforms inputs = f;
                         inputs.attributes[15].inline_value[3] = i & 1;
                         unsigned access = (i >> 1) & 1;
                         assert(bwr_call(program, access, &local, &inputs) ==
                                ((i & 1) || access));
                     }
                   });
}
static uint64_t bwr_now(void)
{
    struct timespec value;
    assert(!clock_gettime(CLOCK_MONOTONIC, &value));
    return (uint64_t)value.tv_sec * 1000000000u + value.tv_nsec;
}
static void bwr_warm(BOOL longProgram)
{
    NV2AMetalValidatedProgram *programs[2] = { bwr_program(longProgram), nil };
    programs[1] = bwr_fresh(programs[0]);
    NV2AMetalProgramUniforms u;
    NV2AMetalFetchUniforms f;
    bwr_inputs(&u, &f);
    const unsigned iterations = 16384;
    uint64_t elapsed[2];
    unsigned cold[2], keys[2];
    for (unsigned reference = 0; reference < 2; reference++) {
        NV2AMetalValidatedProgram *program = programs[reference];
        bwr_observe(program);
        bwr_force_miss = reference;
        assert(!bwr_call(program, 0, &u, &f) && bwr_call(program, 1, &u, &f));
        bwr_evaluations = bwr_keys = 0;
        unsigned allowed = 0;
        uint64_t start = bwr_now();
        for (unsigned i = 0; i < iterations; i++)
            allowed += bwr_call(program, i & 1, &u, &f);
        elapsed[reference] = bwr_now() - start;
        cold[reference] = bwr_evaluations;
        keys[reference] = bwr_keys;
        assert(allowed == iterations / 2);
        bwr_observed = nil;
        bwr_force_miss = NO;
    }
    assert(!cold[0] && !keys[0] && cold[1] == iterations);
    printf("Bound writer %s: %u warm/forced-miss-wrapper calls %.1f/%.1f ns; "
           "cold evaluations %u/%u, key materializations %u/%u "
           "(CPU only; reference includes memo wrapper, no timing threshold)\n",
           longProgram ? "136-slot" : "8-slot", iterations,
           elapsed[0] / (double)iterations, elapsed[1] / (double)iterations,
           cold[0], cold[1], keys[0], keys[1]);
}
static void bound_writer_proof_reuse_tests(void)
{
    SEL selectors[] = {
        @selector(boundWriterProofConstants:fetchDomains:matchSnapshot:),
        @selector(boundWriterProofKeyWithBytes:length:),
        @selector(evaluateBoundWriterAccess:constants:fetchDomains:)
    };
    IMP replacements[] = { (IMP)bwr_match_spy, (IMP)bwr_key_spy,
                           (IMP)bwr_evaluate_spy };
    Method methods[3];
    IMP originals[3];
    for (unsigned i = 0; i < 3; i++) {
        methods[i] = class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                             selectors[i]);
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    bwr_match_original = (void *)originals[0];
    bwr_key_original = (void *)originals[1];
    bwr_evaluate_original = (void *)originals[2];
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    bwr_cases = 0;
    @try {
        bwr_mutations();
        bwr_oom_and_lifetime();
        bwr_parallel();
        bwr_warm(NO);
        bwr_warm(YES);
    } @finally {
        bwr_observed = nil;
        bwr_force_miss = bwr_reject_key = NO;
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    printf("Bound writer proof reuse: %u fresh-cold/access-bit pairs; raw "
           "constant bits, last lane, numerical fetch domains, OOM/retry, "
           "bounded snapshots and parallel calls PASS (CPU only)\n",
           bwr_cases);
}
#endif
