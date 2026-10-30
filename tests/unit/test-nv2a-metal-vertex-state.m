/* Native State-program transport and masked ALU tests; no app or window.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/vertex-state.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "test-metal-vertex-context.h"

static unsigned successCount, rejectionCount;
static NV2AMetalStateResult *execute(NV2AMetalStateProgram *executor,
                                     Token *tokens, unsigned slots,
                                     NSData *constants, NSData *launch)
{
    NSError *error = nil;
    NV2AMetalStateResult *result = [executor executeTokens:tokens[0].word
                                                    length:slots
                                                 constants:constants
                                                    launch:launch
                                                     error:&error];
    if (!result) {
        fprintf(stderr, "State host: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
    assert(result.constants.length == 3072 && result.written.length == 768);
    successCount++;
    return result;
}
static void reject(NV2AMetalStateProgram *executor, const uint32_t *tokens,
                   unsigned slots, NSData *constants, NSData *launch)
{
    NSData *before = [constants copy], *oldLaunch = [launch copy];
    NSError *error = nil;
    assert(![executor executeTokens:tokens
                             length:slots
                          constants:constants
                             launch:launch
                              error:&error]);
    assert(error && [constants isEqualToData:before] &&
           [launch isEqualToData:oldLaunch]);
    rejectionCount++;
}
static void check(NV2AMetalStateResult *result, const uint32_t expected[192][4],
                  const uint32_t written[192])
{
    const uint32_t *raw = result.constants.bytes;
    const uint32_t *flags = result.written.bytes;
    for (unsigned i = 0; i < 192; i++) {
        if (flags[i] != written[i]) {
            fprintf(stderr, "State host flag %u: %u vs %u\n", i, flags[i],
                    written[i]);
            abort();
        }
        for (unsigned k = 0; k < 4; k++) {
            if (raw[i * 4 + k] != expected[i][k]) {
                fprintf(stderr, "State host raw %u/%u: %08x vs %08x\n", i, k,
                        raw[i * 4 + k], expected[i][k]);
                abort();
            }
        }
    }
}
/* Recorded original NV20 version2 ILU results; no candidate shader called. */
static const uint32_t state_family_ilu[4][7][4] = {
    { { 0x40800000u, 0x40400000u, 0x40000000u, 0x3f800000u },
      { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
      { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
      { 0x3effffffu, 0x3effffffu, 0x3effffffu, 0x3effffffu },
      { 0x41800000u, 0x00000000u, 0x41800000u, 0x3f800000u },
      { 0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u },
      { 0x3f800000u, 0x40800000u, 0x404001e0u, 0x3f800000u } },
    { { 0x3f800000u, 0x40000000u, 0x40400000u, 0x40800000u },
      { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
      { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
      { 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu },
      { 0x40000000u, 0x00000000u, 0x40000000u, 0x3f800000u },
      { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
      { 0x3f800000u, 0x3f800000u, 0x41800000u, 0x3f800000u } },
    { { 0x40800000u, 0x40800000u, 0x40800000u, 0x40800000u },
      { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
      { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
      { 0x3effffffu, 0x3effffffu, 0x3effffffu, 0x3effffffu },
      { 0x41800000u, 0x00000000u, 0x41800000u, 0x3f800000u },
      { 0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u },
      { 0x3f800000u, 0x40800000u, 0x43800000u, 0x3f800000u } },
    { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
      { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
      { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
      { 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu },
      { 0x40000000u, 0x00000000u, 0x40000000u, 0x3f800000u },
      { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
      { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } }
};

/* Exact finite fixtures for state transport and ALU selection. Arithmetic
 * conformance is covered separately by the productive vertex-program suite. */
static void exerciseALUs(NV2AMetalStateProgram *executor)
{
    const float a[4] = { 1, 2, 3, 4 }, b[4] = { 5, 6, 7, 8 };
    const float mac[12][4] = { { 1, 2, 3, 4 },     { 5, 12, 21, 32 },
                               { 5, 5, 5, 5 },     { 9, 15, 23, 33 },
                               { 38, 38, 38, 38 }, { 46, 46, 46, 46 },
                               { 70, 70, 70, 70 }, { 1, 12, 3, 8 },
                               { 1, 2, 3, 4 },     { 5, 6, 7, 8 },
                               { 1, 1, 1, 1 },     { 0, 0, 0, 0 } };
    float ilu[7][4];
    memcpy(ilu, state_family_ilu[0], sizeof(ilu));
    uint32_t original[192][4], expected[192][4], flags[192];
    for (unsigned i = 0; i < 192; i++) {
        float value[4] = { 9, 10, 11, 12 };
        memcpy(original[i], value, sizeof(value));
    }
    memcpy(original[0], b, sizeof(b));
    NSData *constants = [NSData dataWithBytes:original length:sizeof(original)];
    NSData *launch = [NSData dataWithBytes:a length:sizeof(a)];
    for (unsigned unit = 0; unit < 2; unit++) {
        unsigned count = unit ? 7 : 12;
        for (unsigned op = 1; op <= count; op++) {
            const float *value = unit ? ilu[op - 1] : mac[op - 1];
            for (unsigned mask = 0; mask < 16; mask++) {
                Token t = token(unit ? 0 : op, unit ? op : 0, 0);
                source(&t, 0, 2, 0, 0xe4);
                source(&t, 1, 3, 0, 0xe4);
                source(&t, 2, 2, 0, 0x1b);
                destination(&t, 191, mask, unit, 0, 0, 0);
                t.word[3] |= 1;
                memcpy(expected, original, sizeof(expected));
                memset(flags, 0, sizeof(flags));
                flags[191] = mask != 0;
                for (unsigned k = 0; k < 4; k++) {
                    if (mask & (8u >> k))
                        memcpy(&expected[191][k], &value[k], 4);
                }
                check(execute(executor, &t, 1, constants, launch), expected,
                      flags);
            }
        }
    }
    for (unsigned m = 1; m <= 12; m++) {
        for (unsigned i = 1; i <= 7; i++) {
            float vector[4];
            memcpy(vector, mac[m - 1], sizeof(vector));
            for (unsigned mux = 0; mux < 2; mux++) {
                for (unsigned collision = 0; collision < 2; collision++) {
                    unsigned temporary = collision ? 1 : 11;
                    Token t[3] = { token(m, i, 0), token(1, 0, 0),
                                   token(1, 0, 0) };
                    source(&t[0], 0, 2, 0, 0xe4);
                    source(&t[0], 1, 3, 0, 0xe4);
                    source(&t[0], 2, 2, 0, 0x1b);
                    destination(&t[0], 127, 15, mux, temporary, 15, 15);
                    source(&t[1], 0, 1, temporary, 0xe4);
                    destination(&t[1], 128, 15, 0, 0, 0, 0);
                    source(&t[2], 0, 1, 1, 0xe4);
                    destination(&t[2], 191, 15, 0, 0, 0, 0);
                    t[2].word[3] |= 1;
                    memcpy(expected, original, sizeof(expected));
                    memcpy(expected[127], mux ? ilu[i - 1] : vector, 16);
                    memcpy(expected[128], collision ? ilu[i - 1] : vector, 16);
                    memcpy(expected[191], ilu[i - 1], 16);
                    memset(flags, 0, sizeof(flags));
                    flags[127] = flags[128] = flags[191] = 1;
                    check(execute(executor, t, 3, constants, launch), expected,
                          flags);
                }
            }
        }
    }
    puts("State ALU transport: 304 masked single-unit/336 paired selection, R1 "
         "collision and R11 chains PASS");
}

static void exerciseStateEdges(NV2AMetalStateProgram *executor)
{
    float original[192][4];
    uint32_t expected[192][4], flags[192];
    for (unsigned row = 0; row < 192; row++)
        for (unsigned k = 0; k < 4; k++)
            original[row][k] = 100 * row + k;
    NSData *constants = [NSData dataWithBytes:original length:sizeof(original)];
    const int addresses[] = { -96, -1, 0, 1, 95 };
    for (unsigned i = 0; i < 5; i++) {
        float v0[4] = { addresses[i], 2, 3, 4 };
        NSData *launch = [NSData dataWithBytes:v0 length:sizeof(v0)];
        Token t[3] = { token(13, 1, 96), token(1, 0, 96), token(1, 0, 0) };
        source(&t[0], 0, 2, 0, 0xe4);
        source(&t[0], 2, 3, 0, 0xe4);
        destination(&t[0], 190, 15, 1, 0, 8, 15);
        t[0].word[3] |= 2;
        source(&t[1], 0, 3, 0, 0xe4);
        destination(&t[1], 191, 15, 0, 0, 0, 0);
        t[1].word[3] |= 2;
        source(&t[2], 0, 1, 1, 0xe4);
        destination(&t[2], 189, 15, 0, 0, 0, 0);
        t[2].word[3] |= 1;
        memcpy(expected, original, sizeof(expected));
        memcpy(expected[190], original[96], 16);
        memcpy(expected[189], original[96], 16);
        memcpy(expected[191], original[96 + addresses[i]], 16);
        memset(flags, 0, sizeof(flags));
        flags[189] = flags[190] = flags[191] = 1;
        check(execute(executor, t, 3, constants, launch), expected, flags);
    }
    const float v0[4] = { 1, 2, 3, 4 };
    NSData *launch = [NSData dataWithBytes:v0 length:sizeof(v0)];
    Token none = token(0, 0, 255);
    destination(&none, 255, 0, 0, 15, 0, 0);
    none.word[3] |= 1;
    memset(flags, 0, sizeof(flags));
    memcpy(expected, original, sizeof(expected));
    check(execute(executor, &none, 1, constants, launch), expected, flags);
    Token padded[2] = { none, token(15, 0, 0) };
    check(execute(executor, padded, 2, constants, launch), expected, flags);
    Token maximum[136];
    for (unsigned i = 0; i < 135; i++) {
        maximum[i] = none;
        maximum[i].word[3] &= ~1u;
    }
    maximum[135] = token(1, 0, 0);
    source(&maximum[135], 0, 2, 0, 0xe4);
    destination(&maximum[135], 191, 15, 0, 0, 0, 0);
    maximum[135].word[3] |= 1;
    memcpy(expected, original, sizeof(expected));
    memcpy(expected[191], v0, 16);
    flags[191] = 1;
    check(execute(executor, maximum, 136, constants, launch), expected, flags);
    reject(executor, NULL, 1, constants, launch);
    puts("State edges: 5 paired ARL old-address chains, NOP, first EOF and "
         "maximum136 span PASS");
}


int main(void)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device);
        NSError *error = nil;
        NV2AMetalStateProgram *executor =
            [[NV2AMetalStateProgram alloc] initWithDevice:device error:&error];
        if (!executor) {
            fprintf(stderr, "State host init: %s\n",
                    error.localizedDescription.UTF8String);
            abort();
        }
        exerciseALUs(executor);
        exerciseStateEdges(executor);
        uint32_t original[192][4], expected[192][4], flags[192] = { 0 };
        uint32_t values[] = { 0,          0x80000000, 1,          0x807fffff,
                              0x3f800000, 0xbf800000, 0x7fc12345, 0xff854321 };
        for (unsigned i = 0; i < 192; i++)
            for (unsigned k = 0; k < 4; k++)
                original[i][k] = values[(i + k * 3) % 8];
        uint32_t input[] = { 0x7f812345, 0x80000000, 0x807fffff, 0x3f800000 };
        NSData *constants = [NSData dataWithBytes:original
                                           length:sizeof(original)];
        NSData *launch = [NSData dataWithBytes:input length:sizeof(input)];
        NSData *savedConstants = [constants copy], *savedLaunch = [launch copy];
        unsigned rows[] = { 0, 1, 15, 16, 58, 59, 95, 96, 127, 128, 191 };
        NV2AMetalStateResult *first = nil;
        NSData *firstConstants = nil, *firstWritten = nil;
        for (unsigned i = 0; i < sizeof(rows) / sizeof(rows[0]); i++)
            for (unsigned mask = 0; mask < 16; mask++)
                for (unsigned unit = 0; unit < 2; unit++) {
                    Token t = token(unit ? 0 : 1, unit ? 1 : 0, 0);
                    source(&t, unit ? 2 : 0, 2, 0, 0xe4);
                    destination(&t, rows[i], mask, unit, 0, 0, 0);
                    t.word[3] |= 1;
                    memcpy(expected, original, sizeof(expected));
                    memset(flags, 0, sizeof(flags));
                    for (unsigned k = 0; k < 4; k++)
                        if (mask & (8 >> k))
                            expected[rows[i]][k] = input[k];
                    flags[rows[i]] = mask != 0;
                    NV2AMetalStateResult *result =
                        execute(executor, &t, 1, constants, launch);
                    check(result, expected, flags);
                    if (!first) {
                        first = result;
                        firstConstants = [result.constants copy];
                        firstWritten = [result.written copy];
                    }
                }
        assert([first.constants isEqualToData:firstConstants] &&
               [first.written isEqualToData:firstWritten]);
        assert([constants isEqualToData:savedConstants] &&
               [launch isEqualToData:savedLaunch]);

        /* All12 temporaries start at0; no state-program output alias exists. */
        for (unsigned reg = 0; reg < 12; reg++) {
            Token t = token(1, 0, 0);
            source(&t, 0, 1, reg, 0xe4);
            destination(&t, 190, 15, 0, 0, 0, 0);
            t.word[3] |= 1;
            memcpy(expected, original, sizeof(expected));
            memset(expected[190], 0, sizeof(expected[190]));
            memset(flags, 0, sizeof(flags));
            flags[190] = 1;
            check(execute(executor, &t, 1, constants, launch), expected, flags);
        }
        /* Unchanged bits are nevertheless a context write. */
        Token same = token(1, 0, 191);
        source(&same, 0, 3, 0, 0xe4);
        destination(&same, 191, 15, 0, 0, 0, 0);
        same.word[3] |= 1;
        memset(flags, 0, sizeof(flags));
        flags[191] = 1;
        check(execute(executor, &same, 1, constants, launch), original, flags);

        Token paired[3] = { token(1, 1, 0), token(1, 0, 0), token(1, 0, 0) };
        source(&paired[0], 0, 3, 0, 0x1b);
        source(&paired[0], 2, 3, 0, 0xe4);
        destination(&paired[0], 0, 15, 0, 2, 15, 15);
        source(&paired[1], 0, 1, 2, 0xe4);
        destination(&paired[1], 128, 15, 0, 0, 0, 0);
        source(&paired[2], 0, 1, 1, 0xe4);
        destination(&paired[2], 191, 15, 0, 0, 0, 0);
        paired[2].word[3] |= 1;
        memcpy(expected, original, sizeof(expected));
        for (unsigned k = 0; k < 4; k++)
            expected[0][k] = expected[128][k] = original[0][3 - k];
        memcpy(expected[191], original[0], sizeof(expected[191]));
        memset(flags, 0, sizeof(flags));
        flags[0] = flags[128] = flags[191] = 1;
        check(execute(executor, paired, 3, constants, launch), expected, flags);

        /* Relative reads use the instruction's pre-write address state. */
        int address[] = { -96, -1, 0, 1, 95 };
        for (unsigned i = 0; i < sizeof(address) / sizeof(address[0]); i++) {
            float a = address[i];
            uint32_t v0[4] = { 0 };
            memcpy(v0, &a, 4);
            NSData *argument = [NSData dataWithBytes:v0 length:sizeof(v0)];
            Token t[2] = { token(13, 0, 0), token(1, 0, 96) };
            source(&t[0], 0, 2, 0, 0xe4);
            destination(&t[0], 0, 0, 0, 0, 0, 0);
            source(&t[1], 0, 3, 0, 0xe4);
            destination(&t[1], 190, 15, 0, 0, 0, 0);
            t[1].word[3] |= 3;
            memcpy(expected, original, sizeof(expected));
            memcpy(expected[190], original[96 + address[i]],
                   sizeof(expected[190]));
            memset(flags, 0, sizeof(flags));
            flags[190] = 1;
            check(execute(executor, t, 2, constants, argument), expected,
                  flags);
        }
        /* A later fault must not publish any partially written snapshot. */
        uint32_t faultValues[] = { 0x3f800000, 0xbf800000, 0x7f800000,
                                   0x7fc12345 };
        for (unsigned i = 0; i < 4; i++) {
            uint32_t v0[4] = { faultValues[i], 0, 0, 0 };
            NSData *argument = [NSData dataWithBytes:v0 length:sizeof(v0)];
            Token t[3] = { token(1, 0, 0), token(13, 0, 0),
                           token(1, 0, i == 1 ? 0 : 191) };
            source(&t[0], 0, 2, 0, 0xe4);
            destination(&t[0], 127, 15, 0, 0, 0, 0);
            source(&t[1], 0, 2, 0, 0xe4);
            destination(&t[1], 0, 0, 0, 0, 0, 0);
            source(&t[2], 0, 3, 0, 0xe4);
            destination(&t[2], 190, 15, 0, 0, 0, 0);
            t[2].word[3] |= 3;
            reject(executor, t[0].word, 3, constants, argument);
        }
        Token valid = token(1, 0, 0);
        source(&valid, 0, 2, 0, 0xe4);
        destination(&valid, 191, 15, 0, 0, 0, 0);
        valid.word[3] |= 1;
        memcpy(expected, original, sizeof(expected));
        memcpy(expected[191], input, sizeof(input));
        memset(flags, 0, sizeof(flags));
        flags[191] = 1;
        check(execute(executor, &valid, 1, constants, launch), expected, flags);

        reject(executor, valid.word, 0, constants, launch);
        reject(executor, valid.word, 137, constants, launch);
        Token bad = valid;
        bad.word[3] &= ~1u;
        reject(executor, bad.word, 1, constants, launch);
        bad = valid;
        bad.word[3] |= 1u << 11;
        reject(executor, bad.word, 1, constants, launch);
        for (unsigned row = 192; row < 256; row++) {
            bad = valid;
            destination(&bad, row, 15, 0, 0, 0, 0);
            bad.word[3] |= 1;
            reject(executor, bad.word, 1, constants, launch);
        }
        bad = valid;
        bad.word[1] |= 1 << 9;
        reject(executor, bad.word, 1, constants, launch);
        bad = valid;
        source(&bad, 0, 1, 12, 0xe4);
        reject(executor, bad.word, 1, constants, launch);
        NSData *shortConstants =
            [constants subdataWithRange:NSMakeRange(0, 3071)];
        NSData *shortLaunch = [launch subdataWithRange:NSMakeRange(0, 15)];
        reject(executor, valid.word, 1, shortConstants, launch);
        reject(executor, valid.word, 1, constants, shortLaunch);
        check(execute(executor, &valid, 1, constants, launch), expected, flags);
        assert([constants isEqualToData:savedConstants] &&
               [launch isEqualToData:savedLaunch]);
        printf("State host wrapper: %u synchronous native executions/%u "
               "rejected inputs/faults PASS\n",
               successCount, rejectionCount);
    }
}
