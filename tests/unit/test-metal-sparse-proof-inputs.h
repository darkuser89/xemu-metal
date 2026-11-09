/* Warm sparse address-proof inputs versus the unchanged full snapshot path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SPARSE_PROOF_INPUTS_H
#define TEST_METAL_SPARSE_PROOF_INPUTS_H
#import <objc/runtime.h>
#include <math.h>

@interface NV2AMetalValidatedProgram (SparseProofInputsTest)
- (BOOL)proofConstants:(const float *)constants
         matchSnapshot:(NSData *)snapshot;
@end
static _Thread_local __unsafe_unretained NV2AMetalValidatedProgram
    *spi_observed;
static _Thread_local BOOL spi_force_slow;
static _Thread_local unsigned spi_matches, spi_calls, spi_reject_length;
static BOOL (*spi_match_original)(id, SEL, const float *, NSData *);
static id (*spi_data_original)(id, SEL, const void *, NSUInteger);
static BOOL spi_match_spy(id object, SEL selector, const float *constants,
                          NSData *snapshot)
{
    if (object == spi_observed) {
        spi_calls++;
        if (spi_force_slow)
            return NO;
    }
    BOOL match = spi_match_original(object, selector, constants, snapshot);
    if (object == spi_observed)
        spi_matches += match;
    return match;
}
static id spi_data_spy(id object, SEL selector, const void *bytes,
                       NSUInteger length)
{
    if (spi_observed && spi_reject_length && spi_reject_length == length) {
        spi_reject_length = 0;
        return nil;
    }
    return spi_data_original(object, selector, bytes, length);
}
static void spi_bits(float *value, uint32_t bits)
{
    memcpy(value, &bits, sizeof(bits));
}
static NV2AMetalValidatedProgram *spi_program(BOOL fetch, BOOL writer)
{
    Token t[8];
    t[0] = token(NV2AMetalMACMov, 0, 0);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    t[1] = token(NV2AMetalMACArl, 0, 96);
    source(t + 1, 0, 3, 0, 0);
    unsigned n;
    if (fetch) {
        t[2] = token(NV2AMetalMACMov, 0, 191);
        source(t + 2, 0, 3, 0, 0xff);
        destination(t + 2, 0, 0, 0, 6, 8, 0);
        t[3] = token(NV2AMetalMACMad, 0, 120);
        t[3].word[1] |= 15u << 9;
        source(t + 3, 0, 2, 0, 0);
        source(t + 3, 1, 3, 0, 0xaa);
        source(t + 3, 2, 1, 6, 0);
        destination(t + 3, 0, 0, 0, 7, 8, 0);
        t[4] = token(NV2AMetalMACArl, 0, 0);
        source(t + 4, 0, 1, 7, 0);
        n = 5;
    } else {
        t[2] = token(NV2AMetalMACArl, 0, 120);
        source(t + 2, 0, 3, 0, 0xaa);
        t[3] = token(NV2AMetalMACArl, 0, 191);
        source(t + 3, 0, 3, 0, 0xff);
        n = 4;
    }
    t[n] = token(NV2AMetalMACMov, 0, 95);
    source(t + n, 0, 3, 0, 0);
    destination(t + n, 0x103, 8, 0, 0, 0, 0);
    t[n++].word[3] |= 2;
    if (writer) {
        t[n] = token(NV2AMetalMACMov, 0, 0);
        t[n].word[1] |= 5u << 9;
        source(t + n, 0, 2, 0, 0xe4);
        destination(t + n++, 150, 4, 0, 0, 0, 0);
    }
    t[n - 1].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:n
                                                    error:&error];
    require(program != nil, error);
    assert(program.mayWriteConstants == writer &&
           ![program hasFaultFreeReadOnlyAccess:0] &&
           ![program hasFaultFreeReadOnlyAccess:1]);
    NSData *copies = [program valueForKey:@"proofConstantCopies"];
    const uint16_t expected[] = { 96 * 4, 1, 120 * 4 + 2, 1, 191 * 4 + 3, 1 };
    assert(copies.length == sizeof(expected) &&
           !memcmp(copies.bytes, expected, sizeof(expected)));
    return program;
}
static BOOL spi_proof(NV2AMetalValidatedProgram *program, BOOL writer,
                      unsigned access, const float *constants,
                      const NV2AMetalFetchUniforms *fetch)
{
    return writer ? [program hasIndependentConstantWrites:access
                                                constants:constants] :
                    [program hasFaultFreeReadOnlyAccess:access
                                              constants:constants
                                         sourceUniforms:fetch];
}
static NSData *spi_key(NV2AMetalValidatedProgram *program, BOOL writer,
                       const NV2AMetalFetchUniforms *fetch)
{
    return [program valueForKey:writer ? @"writerProofInputs" :
                                fetch  ? @"fetchProofInputs" :
                                         @"constantProofInputs"];
}
static unsigned spi_checks;
static void spi_check(NV2AMetalValidatedProgram *program, BOOL writer,
                      BOOL fetchProgram, NV2AMetalProgramUniforms *u,
                      const NV2AMetalFetchUniforms *fetch, unsigned allowed)
{
    for (unsigned access = 0; access < 2; access++) {
        NV2AMetalValidatedProgram *fresh = spi_program(fetchProgram, writer);
        BOOL expected = !!(allowed & (1u << access));
        assert(spi_proof(fresh, writer, access, u->constants[0], fetch) ==
               expected);
        BOOL actual =
            spi_proof(program, writer, access, u->constants[0], fetch);
        assert(actual == expected &&
               [spi_key(program, writer, fetch)
                   isEqualToData:spi_key(fresh, writer, fetch)]);
        NSData *key = spi_key(program, writer, fetch);
        unsigned calls = spi_calls, matches = spi_matches;
        assert(spi_proof(program, writer, access, u->constants[0], fetch) ==
                   expected &&
               spi_key(program, writer, fetch) == key &&
               spi_calls == calls + 1 && spi_matches == matches + 1);
        assert(key.length == (writer ? 3072u : 4096u));
        spi_checks++;
    }
}
static void spi_constant_cases(BOOL writer)
{
    NV2AMetalValidatedProgram *program = spi_program(NO, writer);
    spi_observed = program;
    NV2AMetalProgramUniforms u = uniforms();
    u.constants[96][0] = u.constants[191][3] = 0;
    u.constants[120][2] = 1;
    spi_check(program, writer, NO, &u, NULL, 2);
    NSData *first = spi_key(program, writer, NULL);
    NSData *frozen = [first copy];
    for (unsigned epoch = 0; epoch < 16; epoch++) {
        u.constants[0][0] = epoch + 1;
        u.constants[96][1] = epoch + 2;
        u.constants[120][3] = epoch + 3;
        spi_bits(&u.constants[191][2], 0x7fc12345u + epoch);
        spi_check(program, writer, NO, &u, NULL, 2);
        assert(spi_key(program, writer, NULL) == first);
    }
    const uint32_t bits[] = { 0x80000000u,
                              0x00000000u,
                              0x3f800000u,
                              0x7fc12345u,
                              0x7fc54321u,
                              0x43000000u,
                              0 };
    const unsigned allowed[] = { 2, 2, 3, 0, 0, 0, 2 };
    for (unsigned i = 0; i < sizeof(bits) / sizeof(bits[0]); i++) {
        NSData *old = spi_key(program, writer, NULL);
        spi_bits(&u.constants[191][3], bits[i]);
        spi_check(program, writer, NO, &u, NULL, allowed[i]);
        assert(spi_key(program, writer, NULL) != old);
    }
    for (unsigned span = 0; span < 2; span++) {
        float *value = span ? &u.constants[120][2] : &u.constants[96][0];
        float saved = *value;
        *value = NAN;
        spi_check(program, writer, NO, &u, NULL, 0);
        *value = saved;
        spi_check(program, writer, NO, &u, NULL, 2);
    }
    assert([first isEqualToData:frozen]);
    NSData *key = spi_key(program, writer, NULL);
    assert(!spi_proof(program, writer, 2, u.constants[0], NULL) &&
           !spi_proof(program, writer, 0, NULL, NULL) &&
           spi_key(program, writer, NULL) == key);
    assert(![program proofConstants:NULL matchSnapshot:key] &&
           ![program proofConstants:u.constants[0] matchSnapshot:nil] &&
           ![program proofConstants:u.constants[0]
                      matchSnapshot:[NSMutableData dataWithLength:3071]]);
    spi_reject_length = writer ? 3072 : 4096;
    u.constants[191][3] = 1;
    assert(spi_proof(program, writer, 0, u.constants[0], NULL) &&
           !spi_reject_length && !spi_key(program, writer, NULL));
    spi_check(program, writer, NO, &u, NULL, 3);
    spi_observed = nil;
}
static void spi_fetch_cases(void)
{
    NV2AMetalValidatedProgram *program = spi_program(YES, NO);
    spi_observed = program;
    NV2AMetalProgramUniforms u = uniforms();
    u.constants[96][0] = u.constants[191][3] = 0;
    u.constants[120][2] = 1;
    NV2AMetalFetchUniforms fetch = { 0 };
    spi_check(program, NO, YES, &u, NULL, 0);
    NSData *constantKey = spi_key(program, NO, NULL);
    spi_check(program, NO, YES, &u, &fetch, 2);
    NSData *fetchKey = spi_key(program, NO, &fetch);
    assert(fetchKey != constantKey &&
           spi_key(program, NO, NULL) == constantKey);
    for (unsigned i = 0; i < 16; i++) {
        fetch.attributes[15].inline_value[1] = i;
        fetch.attributes[3].count = 4;
        fetch.attributes[3].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        fetch.attributes[3].stride = i + 1;
        fetch.first_vertex = i;
        fetch.current_vertex = i + 2;
        spi_check(program, NO, YES, &u, &fetch, 2);
        assert(spi_key(program, NO, &fetch) == fetchKey &&
               spi_key(program, NO, NULL) == constantKey);
    }
    const uint32_t bits[] = { 0x80000000u, 0,           0x3f800000u,
                              0x7fc12345u, 0x7fc54321u, 0x3f800000u };
    const unsigned allowed[] = { 2, 2, 3, 0, 0, 3 };
    for (unsigned i = 0; i < sizeof(bits) / sizeof(bits[0]); i++) {
        NSData *old = spi_key(program, NO, &fetch);
        spi_bits(&fetch.attributes[15].inline_value[0], bits[i]);
        spi_check(program, NO, YES, &u, &fetch, allowed[i]);
        /* NaN payloads share the same unknown numerical domain. Zero signs
         * retain distinct exactBits, as in the original complete key. */
        assert((spi_key(program, NO, &fetch) == old) == (i == 4));
    }
    fetch.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    fetch.attributes[15].count = 1;
    fetch.attributes[15].stride = 4;
    spi_check(program, NO, YES, &u, &fetch, 0);
    fetch.attributes[15].format =
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL;
    spi_check(program, NO, YES, &u, &fetch, 2);
    fetch.attributes[15].format =
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
    fetch.attributes[15].count = 4;
    NSData *normalized = spi_key(program, NO, &fetch);
    spi_check(program, NO, YES, &u, &fetch, 2);
    assert(spi_key(program, NO, &fetch) == normalized);
    fetch.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1;
    fetch.attributes[15].count = 1;
    spi_check(program, NO, YES, &u, &fetch, 2);
    fetch.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP;
    spi_check(program, NO, YES, &u, &fetch, 2);
    fetch.attributes[15].count = 0;
    fetch.attributes[15].inline_value[0] = 0;
    u.constants[191][3] = 1;
    spi_check(program, NO, YES, &u, &fetch, 3);
    assert(spi_key(program, NO, NULL) == constantKey);
    spi_check(program, NO, YES, &u, NULL, 0);
    assert(spi_key(program, NO, NULL) != constantKey);
    spi_observed = nil;
}
static uint64_t spi_now(void)
{
    struct timespec value;
    assert(!clock_gettime(CLOCK_MONOTONIC, &value));
    return (uint64_t)value.tv_sec * 1000000000u + value.tv_nsec;
}
static void spi_warm(void)
{
    for (unsigned mode = 0; mode < 3; mode++) {
        BOOL writer = mode == 0, fetchProgram = mode == 2;
        NV2AMetalProgramUniforms u = uniforms();
        u.constants[96][0] = u.constants[191][3] = 0;
        u.constants[120][2] = 1;
        NV2AMetalFetchUniforms fetch = { 0 };
        if (fetchProgram) {
            fetch.attributes[15].count = 1;
            fetch.attributes[15].format =
                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL;
            fetch.attributes[15].stride = 4;
        }
        const NV2AMetalFetchUniforms *f = fetchProgram ? &fetch : NULL;
        uint64_t elapsed[2] = { 0 };
        for (unsigned slow = 0; slow < 2; slow++) {
            NV2AMetalValidatedProgram *program =
                spi_program(fetchProgram, writer);
            spi_observed = program;
            spi_force_slow = slow;
            assert(!spi_proof(program, writer, 0, u.constants[0], f) &&
                   spi_proof(program, writer, 1, u.constants[0], f));
            NSData *key = spi_key(program, writer, f);
            spi_calls = spi_matches = 0;
            unsigned allowed = 0;
            uint64_t start = spi_now();
            for (unsigned i = 0; i < 32768; i++)
                allowed += spi_proof(program, writer, i & 1, u.constants[0], f);
            elapsed[slow] = spi_now() - start;
            assert(allowed == 16384 && spi_calls == 32768 &&
                   spi_matches == (slow ? 0u : 32768u) &&
                   spi_key(program, writer, f) == key);
            spi_observed = nil;
            spi_force_slow = NO;
        }
        printf("Sparse proof warm %s:32768 calls warm/forced-full-key "
               "%.1f/%.1f ns/call (CPU only; no timing threshold)\n",
               writer       ? "writer" :
               fetchProgram ? "readonly-fetch" :
                              "readonly-constants",
               elapsed[0] / 32768.0, elapsed[1] / 32768.0);
    }
}
static void sparse_proof_input_tests(void)
{
    Method matcher =
        class_getInstanceMethod(NV2AMetalValidatedProgram.class,
                                @selector(proofConstants:matchSnapshot:));
    Method data =
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:));
    assert(matcher && data);
    spi_match_original = (void *)method_getImplementation(matcher);
    spi_data_original = (void *)method_getImplementation(data);
    method_setImplementation(matcher, (IMP)spi_match_spy);
    method_setImplementation(data, (IMP)spi_data_spy);
    spi_checks = spi_calls = spi_matches = 0;
    @try {
        spi_constant_cases(YES);
        spi_constant_cases(NO);
        spi_fetch_cases();
        spi_warm();
    } @finally {
        spi_observed = nil;
        spi_force_slow = NO;
        spi_reject_length = 0;
        method_setImplementation(matcher, (IMP)spi_match_original);
        method_setImplementation(data, (IMP)spi_data_original);
    }
    assert(spi_checks);
    printf("Sparse proof inputs:%u cold-reference/access-bit pairs; raw "
           "constant bits, numerical fetch domains, sparse last lane, scoped "
           "keys and snapshot OOM/retry PASS (CPU only)\n",
           spi_checks);
}
#endif
