/* Captured constant ARL proofs versus the serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CAPTURED_WRITES_H
#define TEST_METAL_CAPTURED_WRITES_H

static void captured_bits(float *value, uint32_t bits)
{
    memcpy(value, &bits, sizeof(bits));
}

static NV2AMetalValidatedProgram *captured_tokens(Token *tokens,
                                                  unsigned length)
{
    NSError *error = nil;
    tokens[length - 1].word[3] |= 1;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:length
                                                    error:&error];
    require(program != nil, error);
    return program;
}

static void captured_admission(NV2AMetalValidatedProgram *program,
                               const NV2AMetalProgramUniforms *u,
                               unsigned access, BOOL expected, unsigned test)
{
    independent_reference = NO;
    BOOL actual = independent_captured_proof(
        program, @selector(hasIndependentConstantWrites:constants:), access,
        &u->constants[0][0]);
    if (actual != expected) {
        fprintf(stderr,
                "Captured XF admission:test%u access%u selected%d expected%d\n",
                test, access, actual, expected);
        abort();
    }
}

static NV2AMetalValidatedProgram *
captured_program(unsigned base, unsigned row, unsigned writeMask, BOOL negate)
{
    Token tokens[5];
    tokens[0] = token(1, 0, 0);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(13, 0, 120);
    source(&tokens[1], 0, 3, 0, 0x00);
    if (negate)
        tokens[1].word[1] |= 1u << 8;
    destination(&tokens[1], 0, 0, 0, 0, 0, 0);
    tokens[2] = token(1, 0, base);
    source(&tokens[2], 0, 3, 0, 0xe4);
    destination(&tokens[2], 0x103, 8, 0, 0, 0, 0);
    tokens[2].word[3] |= 2;
    tokens[3] = token(1, 0, 0);
    tokens[3].word[1] |= 5u << 9;
    source(&tokens[3], 0, 2, 0, 0xe4);
    destination(&tokens[3], row, writeMask, 0, 0, 0, 0);
    tokens[4] = token(0, 0, 0);
    return captured_tokens(tokens, 5);
}

static unsigned captured_direct_pairs(NV2AMetalWritableProgram *engine,
                                      NV2AMetalCommands *commands,
                                      id<MTLBuffer> input,
                                      const NV2AMetalProgramUniforms *initial)
{
    /* The fractional contracts deliberately enclose both adjacent integers.
     * They do not replace the GPU's biased ARL floor with a host emulator. */
    static const struct CapturedValue {
        uint32_t bits;
        int low, high;
        BOOL bounded;
    } values[] = {
        { 0x00000000, 0, 0, YES },     { 0x80000000, 0, 0, YES },
        { 0x3f800000, 1, 1, YES },     { 0xbf800000, -1, -1, YES },
        { 0x40000000, 2, 2, YES },     { 0xc0000000, -2, -2, YES },
        { 0x43000000, 128, 128, YES }, { 0xc3000000, -128, -128, YES },
        { 0x3f000000, 0, 1, YES },     { 0xbf000000, -1, 0, YES },
        { 0x3a800000, 0, 1, YES },     { 0xba800000, -1, 0, YES },
        { 0x3b000000, 0, 1, YES },     { 0xbb000000, -1, 0, YES },
        { 0x7fc12345, 0, 0, NO },      { 0x7f800000, 0, 0, NO },
        { 0xff800000, 0, 0, NO },      { 0x4f000000, 0, 0, NO },
    };
    const unsigned bases[] = { 0, 95, 96, 191 };
    const unsigned rows[] = { 96, 97, 120, 150 };
    const unsigned masks[] = { 4, 8 };
    const unsigned counts[] = { 0, 1, 17, 257 };
    unsigned pairs = 0;
    for (unsigned b = 0; b < 4; b++)
        for (unsigned r = 0; r < 4; r++)
            for (unsigned m = 0; m < 2; m++)
                for (unsigned negate = 0; negate < 2; negate++) {
                    @autoreleasepool {
                        NV2AMetalValidatedProgram *program = captured_program(
                            bases[b], rows[r], masks[m], negate);
                        assert(!independent_proof(
                            program, @selector(hasIndependentConstantWrites:),
                            1));
                        assert(!independent_captured_proof(
                            program,
                            @selector(hasIndependentConstantWrites:constants:),
                            0, NULL));
                        for (unsigned v = 0; v < 18; v++)
                            for (unsigned access = 0; access < 2; access++) {
                                NV2AMetalProgramUniforms u = *initial;
                                captured_bits(&u.constants[120][0],
                                              values[v].bits);
                                int low =
                                    (int)bases[b] +
                                    (negate ? -values[v].high : values[v].low);
                                int high =
                                    (int)bases[b] +
                                    (negate ? -values[v].low : values[v].high);
                                BOOL legal = values[v].bounded && low >= 0 &&
                                             high < 192 &&
                                             (access || low >= 96);
                                BOOL feedback =
                                    (masks[m] & 8) &&
                                    (rows[r] == 120 || ((int)rows[r] >= low &&
                                                        (int)rows[r] <= high));
                                captured_admission(program, &u, access,
                                                   legal && !feedback,
                                                   v + 32 * b + 128 * negate);
                                assert(!independent_captured_proof(
                                    program,
                                    @selector(hasIndependentConstantWrites:
                                              constants:),
                                    2, &u.constants[0][0]));
                                independent_pair(
                                    engine, commands, program, &u, input,
                                    counts[(v + b + r + m + negate) % 4],
                                    access, !!(v & 1), !!(r & 1));
                                pairs++;
                            }
                    }
                }
    assert(pairs == 2304);
    return pairs;
}

static NV2AMetalValidatedProgram *
captured_relative_program(unsigned base, unsigned row, unsigned mask)
{
    Token tokens[6];
    tokens[0] = token(1, 0, 0);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(13, 0, 120);
    source(&tokens[1], 0, 3, 0, 0x00);
    destination(&tokens[1], 0, 0, 0, 0, 0, 0);
    tokens[2] = token(13, 0, base);
    source(&tokens[2], 0, 3, 0, 0x00);
    destination(&tokens[2], 0, 0, 0, 0, 0, 0);
    tokens[2].word[3] |= 2;
    tokens[3] = token(1, 0, 96);
    source(&tokens[3], 0, 3, 0, 0xe4);
    destination(&tokens[3], 0x103, 8, 0, 0, 0, 0);
    tokens[3].word[3] |= 2;
    tokens[4] = token(1, 0, 0);
    tokens[4].word[1] |= 5u << 9;
    source(&tokens[4], 0, 2, 0, 0xe4);
    destination(&tokens[4], row, mask, 0, 0, 0, 0);
    tokens[5] = token(0, 0, 0);
    return captured_tokens(tokens, 6);
}

static unsigned captured_relative_pairs(NV2AMetalWritableProgram *engine,
                                        NV2AMetalCommands *commands,
                                        id<MTLBuffer> input,
                                        const NV2AMetalProgramUniforms *initial)
{
    static const struct CapturedRelative {
        uint32_t first;
        unsigned base, sourceLow, sourceHigh;
        uint32_t lowBits, highBits;
        int resultLow, resultHigh;
        BOOL bounded;
    } cases[] = {
        { 0x3f800000, 130, 131, 131, 0, 0, 0, 0, YES },
        { 0xbf800000, 130, 129, 129, 0x3f800000, 0x3f800000, 1, 1, YES },
        { 0x3f000000, 130, 130, 131, 0, 0x3f800000, 0, 1, YES },
        { 0x3f000000, 130, 130, 131, 0xbf800000, 0, -1, 0, YES },
        { 0x3f000000, 130, 130, 131, 0x7fc12345, 0x3f800000, 0, 0, NO },
        { 0xc3000000, 255, 127, 127, 0x3f800000, 0x3f800000, 1, 1, YES },
        { 0x3f800000, 58, 59, 59, 0x3f800000, 0x3f800000, 1, 1, YES },
        { 0, 58, 58, 58, 0, 0, 0, 0, YES },
    };
    const unsigned masks[] = { 4, 8 };
    unsigned pairs = 0;
    for (unsigned c = 0; c < 8; c++) {
        const struct CapturedRelative *test = &cases[c];
        const unsigned rows[] = { 96, 97, 120, test->sourceHigh };
        NV2AMetalProgramUniforms u = *initial;
        captured_bits(&u.constants[120][0], test->first);
        captured_bits(&u.constants[test->sourceLow][0], test->lowBits);
        captured_bits(&u.constants[test->sourceHigh][0], test->highBits);
        for (unsigned r = 0; r < 4; r++)
            for (unsigned m = 0; m < 2; m++)
                for (unsigned access = 0; access < 2; access++) {
                    NV2AMetalValidatedProgram *program =
                        captured_relative_program(test->base, rows[r],
                                                  masks[m]);
                    int low = 96 + test->resultLow;
                    int high = 96 + test->resultHigh;
                    BOOL legal =
                        test->bounded && low >= 0 && high < 192 &&
                        (access || (test->sourceLow >= 96 && low >= 96));
                    BOOL feedback =
                        (masks[m] & 8) &&
                        (rows[r] == 120 ||
                         (rows[r] >= test->sourceLow &&
                          rows[r] <= test->sourceHigh) ||
                         ((int)rows[r] >= low && (int)rows[r] <= high));
                    captured_admission(program, &u, access, legal && !feedback,
                                       1000 + c * 192 + rows[r]);
                    independent_pair(engine, commands, program, &u, input, 17,
                                     access, !!m, !!(c & 1));
                    pairs++;
                }
    }
    assert(pairs == 128);
    return pairs;
}

static unsigned captured_cache_pairs(NV2AMetalWritableProgram *engine,
                                     NV2AMetalCommands *commands,
                                     id<MTLBuffer> input,
                                     const NV2AMetalProgramUniforms *initial)
{
    Token tokens[7];
    tokens[0] = token(1, 0, 121);
    source(&tokens[0], 0, 3, 0, 0x00);
    destination(&tokens[0], 0, 0, 0, 2, 8, 0);
    tokens[1] = token(11, 0, 120);
    source(&tokens[1], 0, 3, 0, 0x00);
    source(&tokens[1], 1, 1, 2, 0x00);
    destination(&tokens[1], 0, 0, 0, 3, 8, 0);
    tokens[2] = token(13, 0, 0);
    source(&tokens[2], 0, 1, 3, 0x00);
    destination(&tokens[2], 0, 0, 0, 0, 0, 0);
    tokens[3] = token(1, 0, 96);
    source(&tokens[3], 0, 3, 0, 0xe4);
    destination(&tokens[3], 0x103, 8, 0, 0, 0, 0);
    tokens[3].word[3] |= 2;
    tokens[4] = token(1, 0, 0);
    tokens[4].word[1] |= 5u << 9;
    source(&tokens[4], 0, 2, 0, 0xe4);
    destination(&tokens[4], 97, 8, 0, 0, 0, 0);
    tokens[5] = token(1, 0, 0);
    source(&tokens[5], 0, 2, 0, 0xe4);
    destination(&tokens[5], 0x100, 15, 0, 0, 0, 0);
    tokens[6] = token(0, 0, 0);
    NV2AMetalValidatedProgram *program = captured_tokens(tokens, 7);
    /* Static fault-freedom does not imply static independence. Captures
     * narrow SLT's [0,1] to {0}, making the writer to c97 independent. */
    assert([program hasFaultFreeReadOnlyAccess:0] &&
           [program hasFaultFreeReadOnlyAccess:1]);
    assert(!independent_proof(program, @selector(hasIndependentConstantWrites:),
                              1));
    static const struct CapturedCache {
        uint32_t a, b;
        BOOL allowed;
    } states[] = {
        { 0x40000000, 0x3f800000, YES }, { 0x40000000, 0x3f800000, YES },
        { 0, 0x3f800000, NO },           { 0x40000000, 0x3f800000, YES },
        { 0x40000000, 0x40400000, NO },  { 0x40800000, 0x40400000, YES },
        { 0, 0x80000000, NO },           { 0x80000000, 0, NO },
    };
    NSData *lastInputs = nil;
    unsigned pairs = 0;
    for (unsigned state = 0; state < 8; state++) {
        NV2AMetalProgramUniforms u = *initial;
        captured_bits(&u.constants[120][0], states[state].a);
        captured_bits(&u.constants[121][0], states[state].b);
        if (state) {
            captured_bits(&u.constants[120][1], 0x7fc54321);
            captured_bits(&u.constants[121][2], 0xff800000);
            captured_bits(&u.constants[96][0], 0x7fa12345);
        }
        for (unsigned access = 0; access < 2; access++) {
            captured_admission(program, &u, access, states[state].allowed,
                               2000 + state);
            NSData *inputs = [program valueForKey:@"writerProofInputs"];
            unsigned known =
                [[program valueForKey:@"writerProofKnown"] unsignedIntValue];
            unsigned allowed =
                [[program valueForKey:@"writerProofAllowed"] unsignedIntValue];
            assert(inputs.length && (known & (1u << access)));
            assert(!!(allowed & (1u << access)) == states[state].allowed);
            if (!access) {
                if (state == 1)
                    assert(inputs == lastInputs);
                else if (state)
                    assert(inputs != lastInputs);
            } else
                assert((known & 3u) == 3u);
            independent_pair(engine, commands, program, &u, input, 17, access,
                             !!(state & 1), !!(state & 2));
            pairs++;
        }
        lastInputs = [program valueForKey:@"writerProofInputs"];
    }
    assert(pairs == 16);
    return pairs;
}

static unsigned captured_previous_pairs(NV2AMetalWritableProgram *engine,
                                        NV2AMetalCommands *commands,
                                        id<MTLBuffer> input,
                                        const NV2AMetalProgramUniforms *initial)
{
    Token tokens[3];
    tokens[0] = token(1, 0, 130);
    source(&tokens[0], 0, 3, 0, 0xe4);
    destination(&tokens[0], 120, 8, 0, 0, 0, 0);
    tokens[1] = token(1, 0, 0);
    source(&tokens[1], 0, 2, 0, 0xe4);
    destination(&tokens[1], 0x100, 15, 0, 0, 0, 0);
    tokens[2] = token(0, 0, 0);
    NV2AMetalValidatedProgram *a = captured_tokens(tokens, 3);
    NV2AMetalValidatedProgram *b = captured_program(191, 150, 4, NO);
    const uint32_t actual[] = { 0x3f800000, 0xbf800000, 0x7fc12345, 0 };
    const unsigned counts[] = { 0, 1, 17, 257 };
    component_admission(a, 0, YES, 120, 8);
    component_admission(b, 0, NO, 150, 4);
    unsigned pairs = 0;
    for (unsigned value = 0; value < 4; value++)
        for (unsigned c = 0; c < 4; c++)
            for (unsigned raster = 0; raster < 2; raster++) {
                NSError *error = nil;
                NV2AMetalProgramUniforms u = *initial, stale = u;
                captured_bits(&u.constants[130][0], actual[value]);
                captured_bits(&stale.constants[130][0], actual[value]);
                stale.constants[120][0] = 0;
                captured_admission(b, &stale, 0, YES, 3000 + value);
                NV2AMetalWritableEncoding *first[2], *second[2];
                require([commands beginWithError:&error] != nil, error);
                for (unsigned reference = 0; reference < 2; reference++) {
                    independent_expect(a, 0, 5, reference);
                    first[reference] = [engine encodeSerialProgram:a
                                                          uniforms:&u
                                                   attributeBuffer:input
                                                             first:3
                                                             count:5
                                                            access:0
                                                         rasterize:raster
                                                          previous:nil
                                                          commands:commands
                                                             error:&error];
                    require(first[reference] != nil, error);
                    independent_prefill(first[reference]);
                    /* The public captured proof is YES for stale CPU data,
                     * but every real GPU predecessor requires the static NO. */
                    independent_expect(b, 0, counts[c], reference);
                    second[reference] =
                        [engine encodeSerialProgram:b
                                           uniforms:&stale
                                    attributeBuffer:input
                                              first:8
                                              count:counts[c]
                                             access:0
                                          rasterize:raster
                                           previous:first[reference]
                                           commands:commands
                                              error:&error];
                    require(second[reference] != nil, error);
                    assert(!independent_pending);
                    independent_prefill(second[reference]);
                }
                require([commands submitWithError:&error] &&
                            [commands waitUntilIdleWithError:&error],
                        error);
                independent_compare(first[0], first[1]);
                independent_compare(second[0], second[1]);
                pairs++;
            }
    assert(pairs == 32);
    return pairs;
}

static BOOL (*captured_snapshot_previous)(id, SEL, unsigned, const float *);
static NV2AMetalProgramUniforms *captured_snapshot_caller;
static unsigned captured_snapshot_mutations;

static BOOL captured_snapshot_spy(id object, SEL selector, unsigned access,
                                  const float *constants)
{
    BOOL result =
        captured_snapshot_previous(object, selector, access, constants);
    if (captured_snapshot_caller) {
        captured_snapshot_caller->constants[120][0] = 1;
        captured_snapshot_caller = NULL;
        captured_snapshot_mutations++;
    }
    return result;
}

static unsigned captured_snapshot_pairs(NV2AMetalWritableProgram *engine,
                                        NV2AMetalCommands *commands,
                                        id<MTLBuffer> input,
                                        const NV2AMetalProgramUniforms *initial)
{
    NV2AMetalValidatedProgram *program = captured_program(96, 97, 8, NO);
    NV2AMetalProgramUniforms u = *initial;
    u.constants[120][0] = 0;
    captured_admission(program, &u, 0, YES, 4000);
    Method method = class_getInstanceMethod(
        NV2AMetalValidatedProgram.class,
        @selector(hasIndependentConstantWrites:constants:));
    assert(method);
    captured_snapshot_previous =
        (void *)method_setImplementation(method, (IMP)captured_snapshot_spy);
    captured_snapshot_mutations = 0;
    unsigned pairs = 0;
    @try {
        for (unsigned compact = 0; compact < 2; compact++) {
            NSError *error = nil;
            NV2AMetalProgramUniforms caller = u;
            NV2AMetalWritableEncoding *candidate, *reference;
            require([commands beginWithError:&error] != nil, error);
            independent_expect(program, 0, 17, NO);
            independent_expected = YES;
            captured_snapshot_caller = &caller;
            candidate = [engine encodeProgram:program
                                     uniforms:&caller
                              attributeBuffer:input
                                        first:3
                                        count:17
                                       access:0
                                  writeEnable:YES
                                    rasterize:YES
                             compactRegisters:compact
                                     commands:commands
                                        error:&error];
            require(candidate != nil, error);
            assert(!independent_pending && !captured_snapshot_caller &&
                   caller.constants[120][0] == 1);
            independent_prefill(candidate);
            independent_expect(program, 0, 17, YES);
            reference = [engine encodeProgram:program
                                     uniforms:&u
                              attributeBuffer:input
                                        first:3
                                        count:17
                                       access:0
                                  writeEnable:YES
                                    rasterize:YES
                             compactRegisters:compact
                                     commands:commands
                                        error:&error];
            require(reference != nil, error);
            assert(!independent_pending && u.constants[120][0] == 0);
            independent_prefill(reference);
            require([commands submitWithError:&error] &&
                        [commands waitUntilIdleWithError:&error],
                    error);
            independent_compare(candidate, reference);
            pairs++;
        }
    } @finally {
        method_setImplementation(method, (IMP)captured_snapshot_previous);
        captured_snapshot_previous = NULL;
        captured_snapshot_caller = NULL;
    }
    assert(pairs == 2 && captured_snapshot_mutations == 2);
    return pairs;
}

static unsigned captured_write_pairs(NV2AMetalWritableProgram *engine,
                                     NV2AMetalCommands *commands,
                                     id<MTLBuffer> input,
                                     const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = captured_direct_pairs(engine, commands, input, u);
    pairs += captured_relative_pairs(engine, commands, input, u);
    pairs += captured_cache_pairs(engine, commands, input, u);
    pairs += captured_previous_pairs(engine, commands, input, u);
    pairs += captured_snapshot_pairs(engine, commands, input, u);
    assert(pairs == 2482);
    return pairs;
}
#endif
