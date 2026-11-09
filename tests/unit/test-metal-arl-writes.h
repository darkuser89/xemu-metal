/* Bounded ARL constant writers versus the serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ARL_WRITES_H
#define TEST_METAL_ARL_WRITES_H

static NV2AMetalValidatedProgram *arl_tokens(Token *tokens, unsigned length)
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

static unsigned arl_address_prefix(Token tokens[16], unsigned mode,
                                   BOOL addressConstant)
{
    unsigned n = 0;
    tokens[n] = token(1, 0, 0);
    source(&tokens[n], 0, 2, 0, 0xe4);
    destination(&tokens[n++], 0x100, 15, 0, 0, 0, 0);
    if (mode) {
        BOOL one = mode == 1 || mode == 2 || mode >= 8;
        tokens[n] = token(one ? 8 : 11, 0, addressConstant ? 120 : 0);
        tokens[n].word[1] |= 4u << 9;
        source(&tokens[n], 0, addressConstant ? 3 : 2, 0, 0x00);
        source(&tokens[n], 1, 2, 0, 0x55);
        destination(&tokens[n++], 0, 0, 0, 2, 8, 0);
        unsigned doubles = mode >= 8 ? 7 : mode == 5 || mode == 6;
        for (unsigned i = 0; i < doubles; i++) {
            tokens[n] = token(3, 0, 0);
            source(&tokens[n], 0, 1, 2, 0x00);
            source(&tokens[n], 2, 1, 2, 0x00);
            destination(&tokens[n++], 0, 0, 0, 2, 8, 0);
        }
        if (mode == 7) {
            tokens[n] = token(8, 0, 0);
            source(&tokens[n], 0, 1, 0, 0xe4);
            source(&tokens[n], 1, 1, 0, 0xe4);
            destination(&tokens[n++], 0, 0, 0, 3, 8, 0);
            tokens[n] = token(3, 0, 0);
            source(&tokens[n], 0, 1, 2, 0x00);
            source(&tokens[n], 2, 1, 3, 0x00);
            destination(&tokens[n++], 0, 0, 0, 2, 8, 0);
        }
    }
    tokens[n] = token(13, 0, 0);
    source(&tokens[n], 0, 1, mode ? 2 : 0, 0x00);
    if (mode == 2 || mode == 4 || mode == 6 || mode == 8)
        tokens[n].word[1] |= 1u << 8;
    destination(&tokens[n++], 0, 0, 0, 0, 0, 0);
    return n;
}

static NV2AMetalValidatedProgram *
arl_write_program(unsigned mode, unsigned base, unsigned row,
                  unsigned writeMask, unsigned readMask, unsigned swizzle,
                  BOOL addressConstant)
{
    Token tokens[16];
    unsigned n = arl_address_prefix(tokens, mode, addressConstant);
    tokens[n] = token(1, 0, base);
    source(&tokens[n], 0, 3, 0, swizzle);
    destination(&tokens[n], 0x103, readMask, 0, 0, 0, 0);
    tokens[n++].word[3] |= 2;
    tokens[n] = token(1, 0, 0);
    tokens[n].word[1] |= 5u << 9;
    source(&tokens[n], 0, 2, 0, 0xe4);
    destination(&tokens[n++], row, writeMask, 0, 0, 0, 0);
    tokens[n++] = token(0, 0, 0);
    assert(n <= 16);
    return arl_tokens(tokens, n);
}

static unsigned arl_range_pairs(NV2AMetalWritableProgram *engine,
                                NV2AMetalCommands *commands,
                                id<MTLBuffer> input,
                                const NV2AMetalProgramUniforms *u)
{
    /* These are fixture contracts, not a host implementation of ARL:
     * initial zero; DST.X=1; SLT in {0,1}; negation, one addition or seven
     * exact doublings; SLT+1. The last two also exercise selector255. */
    static const int bounds[][2] = { { 0, 0 },    { 1, 1 },  { -1, -1 },
                                     { 0, 1 },    { -1, 0 }, { 0, 2 },
                                     { -2, 0 },   { 1, 2 },  { -128, -128 },
                                     { 128, 128 } };
    const unsigned bases[] = { 0,  1,  57,  58,  59,  94,  95,
                               96, 97, 189, 190, 191, 192, 255 };
    const unsigned masks[] = { 1, 4, 8, 15 };
    const unsigned reads[] = { 0, 8, 4, 15 };
    const unsigned counts[] = { 0, 1, 17, 257 };
    const unsigned components[2][4] = { { 8, 4, 2, 1 }, { 1, 2, 4, 8 } };
    unsigned pairs = 0;
    for (unsigned mode = 0; mode < 10; mode++)
        for (unsigned b = 0; b < 14; b++) {
            int low = (int)bases[b] + bounds[mode][0];
            int high = (int)bases[b] + bounds[mode][1];
            int candidates[] = { low,     (low + high) / 2, high,
                                 low - 1, high + 1,         120 };
            for (unsigned r = 0; r < 6; r++)
                for (unsigned w = 0; w < 4; w++)
                    for (unsigned access = 0; access < 2; access++) {
                        @autoreleasepool {
                            unsigned row =
                                candidates[r] < 0 || candidates[r] >= 192 ?
                                    191 :
                                    (unsigned)candidates[r];
                            unsigned read = reads[(b + r + w) % 4];
                            unsigned reverse = (mode + w) & 1;
                            unsigned physical = 0;
                            for (unsigned lane = 0; lane < 4; lane++)
                                if (read & (8u >> lane))
                                    physical |= components[reverse][lane];
                            BOOL legal = low >= 0 && high < 192 &&
                                         (access || low >= 96) &&
                                         writable_allowed(access, row);
                            BOOL overlap = (int)row >= low &&
                                           (int)row <= high &&
                                           (physical & masks[w]);
                            NV2AMetalValidatedProgram *program =
                                arl_write_program(mode, bases[b], row, masks[w],
                                                  read, reverse ? 0x1b : 0xe4,
                                                  NO);
                            component_admission(
                                program, access, legal && !overlap,
                                mode * 256 + bases[b], masks[w]);
                            independent_pair(engine, commands, program, u,
                                             input,
                                             counts[(mode + b + r + w) % 4],
                                             access, !!(b & 1), !!(r & 1));
                            pairs++;
                        }
                    }
        }
    assert(pairs == 6720);
    return pairs;
}

static unsigned arl_address_dependency_pairs(NV2AMetalWritableProgram *engine,
                                             NV2AMetalCommands *commands,
                                             id<MTLBuffer> input,
                                             const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = 0;
    for (unsigned mask = 1; mask < 16; mask++)
        for (unsigned access = 0; access < 2; access++) {
            /* SLT(c120.X, attribute.Y) determines the address. The relative
             * result reads c96/c97, so c120.X is only a control dependency. */
            NV2AMetalValidatedProgram *program =
                arl_write_program(3, 96, 120, mask, 8, 0xe4, YES);
            component_admission(program, access, !(mask & 8), 120, mask);
            independent_pair(engine, commands, program, u, input, 17, access,
                             !!(mask & 1), !!(mask & 2));
            pairs++;
        }
    assert(pairs == 30);
    return pairs;
}

static unsigned arl_unknown_pairs(NV2AMetalWritableProgram *engine,
                                  NV2AMetalCommands *commands,
                                  id<MTLBuffer> input,
                                  const NV2AMetalProgramUniforms *u)
{
    const unsigned counts[] = { 0, 1, 17, 257 };
    unsigned pairs = 0;
    for (unsigned constant = 0; constant < 2; constant++)
        for (unsigned used = 0; used < 2; used++) {
            Token tokens[5];
            tokens[0] = token(1, 0, 0);
            source(&tokens[0], 0, 2, 0, 0xe4);
            destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
            tokens[1] = token(13, 0, 120);
            tokens[1].word[1] |= 4u << 9;
            source(&tokens[1], 0, constant ? 3 : 2, 0, 0x00);
            destination(&tokens[1], 0, 0, 0, 0, 0, 0);
            unsigned n = 2;
            if (used) {
                tokens[n] = token(1, 0, 0);
                source(&tokens[n], 0, 3, 0, 0xe4);
                destination(&tokens[n], 0x103, 15, 0, 0, 0, 0);
                tokens[n++].word[3] |= 2;
            }
            tokens[n] = token(1, 0, 0);
            tokens[n].word[1] |= 5u << 9;
            source(&tokens[n], 0, 2, 0, 0xe4);
            destination(&tokens[n++], 150, 15, 0, 0, 0, 0);
            tokens[n++] = token(0, 0, 0);
            NV2AMetalValidatedProgram *program = arl_tokens(tokens, n);
            for (unsigned access = 0; access < 2; access++)
                for (unsigned c = 0; c < 4; c++) {
                    /* Even an unused ARL may fault. Finite captured constants
                     * are not a value-independent proof for a writer. */
                    component_admission(program, access, NO, constant, used);
                    independent_pair(engine, commands, program, u, input,
                                     counts[c], access, !!constant, !!used);
                    pairs++;
                }
        }
    assert(pairs == 32);
    return pairs;
}

static unsigned arl_paired_pairs(NV2AMetalWritableProgram *engine,
                                 NV2AMetalCommands *commands,
                                 id<MTLBuffer> input,
                                 const NV2AMetalProgramUniforms *u)
{
    const unsigned masks[] = { 1, 4, 8, 15 };
    unsigned pairs = 0;
    for (unsigned old = 0; old < 2; old++)
        for (unsigned next = 0; next < 2; next++)
            for (unsigned follow = 0; follow < 2; follow++)
                for (unsigned row = 96; row <= 98; row++)
                    for (unsigned w = 0; w < 4; w++)
                        for (unsigned access = 0; access < 2; access++) {
                            Token tokens[7];
                            tokens[0] = token(8, 0, 0);
                            source(&tokens[0], 0, 1, 0, 0xe4);
                            source(&tokens[0], 1, 1, 0, 0xe4);
                            destination(&tokens[0], 0, 0, 0, 2, 8, 0);
                            tokens[1] = token(13, 0, 0);
                            source(&tokens[1], 0, 1, old ? 2 : 0, 0x00);
                            destination(&tokens[1], 0, 0, 0, 0, 0, 0);
                            tokens[2] = token(13, 1, 96);
                            source(&tokens[2], 0, 1, next ? 2 : 0, 0x00);
                            source(&tokens[2], 2, 3, 0, 0xe4);
                            destination(&tokens[2], 0x103, 8, 1, 0, 0, 0);
                            tokens[2].word[3] |= 2;
                            tokens[3] = token(1, 0, 96);
                            source(&tokens[3], 0, 3, 0, 0xe4);
                            destination(&tokens[3], 0x104, follow ? 8 : 0, 0, 0,
                                        0, 0);
                            tokens[3].word[3] |= 2;
                            tokens[4] = token(1, 0, 0);
                            tokens[4].word[1] |= 5u << 9;
                            source(&tokens[4], 0, 2, 0, 0xe4);
                            destination(&tokens[4], row, masks[w], 0, 0, 0, 0);
                            tokens[5] = token(1, 0, 0);
                            source(&tokens[5], 0, 2, 0, 0xe4);
                            destination(&tokens[5], 0x100, 15, 0, 0, 0, 0);
                            tokens[6] = token(0, 0, 0);
                            NV2AMetalValidatedProgram *program =
                                arl_tokens(tokens, 7);
                            BOOL overlap = (masks[w] & 8) &&
                                           (row == 96 + old ||
                                            (follow && row == 96 + next));
                            component_admission(program, access, !overlap,
                                                10 * old + next, row);
                            independent_pair(engine, commands, program, u,
                                             input, 17, access, !!follow,
                                             !!next);
                            pairs++;
                        }
    assert(pairs == 192);
    return pairs;
}

static unsigned arl_r12_pairs(NV2AMetalWritableProgram *engine,
                              NV2AMetalCommands *commands, id<MTLBuffer> input,
                              const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = 0;
    for (unsigned constant = 0; constant < 2; constant++)
        for (unsigned mask = 1; mask < 16; mask++)
            for (unsigned access = 0; access < 2; access++) {
                Token tokens[6];
                tokens[0] = token(constant ? 11 : 8, 0, 120);
                tokens[0].word[1] |= 4u << 9;
                source(&tokens[0], 0, constant ? 3 : 2, 0, 0x00);
                source(&tokens[0], 1, 2, 0, 0x55);
                destination(&tokens[0], 0x100, 8, 0, 0, 0, 0);
                tokens[1] = token(13, 0, 0);
                source(&tokens[1], 0, 1, 12, 0x00);
                destination(&tokens[1], 0, 0, 0, 0, 0, 0);
                tokens[2] = token(1, 0, 0);
                source(&tokens[2], 0, 2, 0, 0xe4);
                destination(&tokens[2], 0x100, 15, 0, 0, 0, 0);
                tokens[3] = token(1, 0, 96);
                source(&tokens[3], 0, 3, 0, 0xe4);
                destination(&tokens[3], 0x103, 8, 0, 0, 0, 0);
                tokens[3].word[3] |= 2;
                tokens[4] = token(1, 0, 0);
                tokens[4].word[1] |= 5u << 9;
                source(&tokens[4], 0, 2, 0, 0xe4);
                destination(&tokens[4], 120, mask, 0, 0, 0, 0);
                tokens[5] = token(0, 0, 0);
                NV2AMetalValidatedProgram *program = arl_tokens(tokens, 6);
                component_admission(program, access, !constant || !(mask & 8),
                                    12, mask);
                independent_pair(engine, commands, program, u, input, 17,
                                 access, !!constant, YES);
                pairs++;
            }
    assert(pairs == 60);
    return pairs;
}

static unsigned arl_chain_pairs(NV2AMetalWritableProgram *engine,
                                NV2AMetalCommands *commands,
                                id<MTLBuffer> input)
{
    const unsigned counts[] = { 0, 1, 17, 257 };
    unsigned pairs = 0;
    Token tokens[3];
    tokens[0] = token(1, 0, 0);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(1, 0, 0);
    tokens[1].word[1] |= 4u << 9;
    source(&tokens[1], 0, 2, 0, 0xe4);
    destination(&tokens[1], 97, 8, 0, 0, 0, 0);
    tokens[2] = token(0, 0, 0);
    NV2AMetalValidatedProgram *a = arl_tokens(tokens, 3);
    NV2AMetalValidatedProgram *b =
        arl_write_program(1, 96, 150, 4, 8, 0xe4, NO);
    component_admission(a, 0, YES, 97, 8);
    component_admission(b, 0, YES, 150, 4);
    for (unsigned c = 0; c < 4; c++)
        for (unsigned raster = 0; raster < 2; raster++) {
            NSError *error = nil;
            NV2AMetalProgramUniforms u = uniforms(), stale = u;
            u.constants[97][0] = 123.5f;
            stale.constants[97][0] = -999.625f;
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
                independent_expect(b, 0, counts[c], reference);
                second[reference] = [engine encodeSerialProgram:b
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
    assert(pairs == 8);
    return pairs;
}

static unsigned arl_write_pairs(NV2AMetalWritableProgram *engine,
                                NV2AMetalCommands *commands,
                                id<MTLBuffer> input,
                                const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = arl_range_pairs(engine, commands, input, u);
    pairs += arl_address_dependency_pairs(engine, commands, input, u);
    pairs += arl_unknown_pairs(engine, commands, input, u);
    pairs += arl_paired_pairs(engine, commands, input, u);
    pairs += arl_r12_pairs(engine, commands, input, u);
    pairs += arl_chain_pairs(engine, commands, input);
    assert(pairs == 7042);
    return pairs;
}
#endif
