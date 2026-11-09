/* Overwritten output/context dependencies versus the serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_STORE_WRITES_H
#define TEST_METAL_STORE_WRITES_H

static unsigned store_fog_mask(unsigned mask)
{
    /* Independent table for Fog's packed destinations, indexed by mask. */
    static const unsigned packed[] = { 0, 8,  8,  12, 8,  12, 12, 14,
                                       8, 12, 12, 14, 12, 14, 14, 15 };
    return packed[mask];
}

static NV2AMetalValidatedProgram *
store_write_program(unsigned row, unsigned seedMask, unsigned killMask,
                    unsigned writeMask, BOOL ilu, BOOL relative)
{
    Token tokens[5];
    tokens[0] = token(1, 0, 0);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(!ilu, ilu, 96);
    source(&tokens[1], ilu ? 2 : 0, 3, 0, 0xe4);
    destination(&tokens[1], row, seedMask, ilu, 0, 0, 0);
    if (relative)
        tokens[1].word[3] |= 2;
    tokens[2] = token(ilu, !ilu, 0);
    tokens[2].word[1] |= 6u << 9;
    source(&tokens[2], ilu ? 0 : 2, 2, 0, 0xe4);
    destination(&tokens[2], row, killMask, !ilu, 0, 0, 0);
    tokens[3] = token(1, 0, 0);
    tokens[3].word[1] |= 4u << 9;
    source(&tokens[3], 0, 2, 0, 0xe4);
    destination(&tokens[3], 96, writeMask, 0, 0, 0, 0);
    tokens[4] = token(0, 0, 0);
    tokens[4].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:5
                                                    error:&error];
    require(program != nil, error);
    return program;
}

static unsigned store_snapshot_pairs(NV2AMetalWritableProgram *engine,
                                     NV2AMetalCommands *commands,
                                     id<MTLBuffer> input,
                                     const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = 0;
    for (unsigned constant = 0; constant < 2; constant++)
        for (unsigned ilu = 0; ilu < 2; ilu++)
            for (unsigned use = 0; use < 16; use++) {
                Token tokens[6];
                tokens[0] = token(1, 0, 0);
                source(&tokens[0], 0, 2, 0, 0xe4);
                destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
                tokens[1] = token(!ilu, ilu, 96);
                source(&tokens[1], ilu ? 2 : 0, 3, 0, 0xe4);
                destination(&tokens[1], constant ? 130 : 0x100, 15, ilu, 0, 0,
                            0);
                tokens[2] = token(1, 0, 130);
                source(&tokens[2], 0, constant ? 3 : 1, constant ? 0 : 12,
                       0xe4);
                destination(&tokens[2], 0x109, use, 0, 0, 0, 0);
                tokens[3] = token(1, 0, 0);
                tokens[3].word[1] |= 6u << 9;
                source(&tokens[3], 0, 2, 0, 0xe4);
                destination(&tokens[3], constant ? 130 : 0x100, 15, 0, 0, 0, 0);
                tokens[4] = token(1, 0, 0);
                tokens[4].word[1] |= 4u << 9;
                source(&tokens[4], 0, 2, 0, 0xe4);
                destination(&tokens[4], 96, 15, 0, 0, 0, 0);
                tokens[5] = token(0, 0, 0);
                tokens[5].word[3] |= 1;
                NSError *error = nil;
                NV2AMetalValidatedProgram *program =
                    [[NV2AMetalValidatedProgram alloc]
                        initWithTokens:tokens[0].word
                                length:6
                                 error:&error];
                require(program != nil, error);
                component_admission(program, 0, use == 0, constant, use);
                independent_pair(engine, commands, program, u, input, 17, 0,
                                 !!ilu, YES);
                pairs++;
            }
    assert(pairs == 64);
    return pairs;
}

static unsigned store_alias_pairs(NV2AMetalWritableProgram *engine,
                                  NV2AMetalCommands *commands,
                                  id<MTLBuffer> input,
                                  const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = 0;
    for (unsigned output = 0; output < 2; output++)
        for (unsigned mac = 0; mac < 16; mac++)
            for (unsigned kill = 0; kill < 16; kill++) {
                Token tokens[5];
                tokens[0] = token(1, 0, 0);
                source(&tokens[0], 0, 2, 0, 0xe4);
                destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
                tokens[1] = token(1, 1, 96);
                tokens[1].word[1] |= 6u << 9;
                source(&tokens[1], 0, 3, 0, 0xe4);
                source(&tokens[1], 2, 2, 0, 0xe4);
                /* ILU writes oPos first; the MAC R12 store then overrides it.
                 */
                destination(&tokens[1], 0x100, output ? 15 : 0, 1, 12, mac, 0);
                tokens[2] = token(1, 0, 0);
                tokens[2].word[1] |= 7u << 9;
                source(&tokens[2], 0, 2, 0, 0xe4);
                destination(&tokens[2], 0x100, kill, 0, 0, 0, 0);
                tokens[3] = token(1, 0, 0);
                tokens[3].word[1] |= 4u << 9;
                source(&tokens[3], 0, 2, 0, 0xe4);
                destination(&tokens[3], 96, 15, 0, 0, 0, 0);
                tokens[4] = token(0, 0, 0);
                tokens[4].word[3] |= 1;
                NSError *error = nil;
                NV2AMetalValidatedProgram *program =
                    [[NV2AMetalValidatedProgram alloc]
                        initWithTokens:tokens[0].word
                                length:5
                                 error:&error];
                require(program != nil, error);
                component_admission(program, 0, !(mac & ~kill), mac, kill);
                independent_pair(engine, commands, program, u, input, 17, 0,
                                 !!(mac & 1), !!output);
                pairs++;
            }
    assert(pairs == 512);
    return pairs;
}

static unsigned store_write_pairs(NV2AMetalWritableProgram *engine,
                                  NV2AMetalCommands *commands,
                                  id<MTLBuffer> input,
                                  const NV2AMetalProgramUniforms *u)
{
    const unsigned rows[] = { 0x100, 0x103, 0x104, 0x105, 0x106, 0x107,
                              0x108, 0x109, 0x10a, 0x10b, 0x10c, 58,
                              59,    95,    96,    130,   191 };
    const unsigned writeMasks[] = { 1, 2, 4, 8, 15 };
    const unsigned counts[] = { 0, 1, 17, 257 };
    unsigned pairs = 0;
    for (unsigned ilu = 0; ilu < 2; ilu++)
        for (unsigned r = 0; r < 17; r++)
            for (unsigned seed = 0; seed < 16; seed++)
                for (unsigned kill = 0; kill < 16; kill++) {
                    @autoreleasepool {
                        unsigned row = rows[r];
                        unsigned write = writeMasks[(r + seed + kill) % 5];
                        unsigned read =
                            row == 0x105 ? store_fog_mask(seed) : seed;
                        unsigned overwritten =
                            row == 0x105 ? store_fog_mask(kill) : kill;
                        unsigned access = (seed + kill) & 1;
                        BOOL legal = (row & 256) ||
                                     writable_allowed(access, row) ||
                                     !(seed | kill);
                        unsigned needed = read & ~overwritten;
                        if (row == 96)
                            needed &= ~write;
                        BOOL allowed =
                            legal && !(needed & (row == 96 ? 15 : write));
                        NV2AMetalValidatedProgram *program =
                            store_write_program(row, seed, kill, write, ilu,
                                                !!(seed & 1));
                        component_admission(program, access, allowed, row,
                                            kill);
                        independent_pair(engine, commands, program, u, input,
                                         counts[(r + seed + kill) % 4], access,
                                         !!(seed & 2), !!(kill & 1));
                        pairs++;
                    }
                }
    assert(pairs == 8704);
    pairs += store_snapshot_pairs(engine, commands, input, u);
    pairs += store_alias_pairs(engine, commands, input, u);
    assert(pairs == 9280);
    return pairs;
}
#endif
