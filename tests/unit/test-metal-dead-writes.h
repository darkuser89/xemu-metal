/* Dead temporary dependencies versus the serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DEAD_WRITES_H
#define TEST_METAL_DEAD_WRITES_H

static NV2AMetalValidatedProgram *
dead_write_program(ComponentReadCase test, BOOL seedILU, unsigned reg,
                   unsigned kill, unsigned swizzle, unsigned kind, unsigned row,
                   BOOL relative)
{
    Token tokens[7];
    unsigned length = 0;
    tokens[length] = token(1, 0, 0);
    source(&tokens[length], 0, 2, 0, 0xe4);
    destination(&tokens[length++], 0x100, 15, 0, 0, 0, 0);
    tokens[length] = token(!seedILU, seedILU, row);
    source(&tokens[length], seedILU ? 2 : 0, 3, 0, 0xe4);
    destination(&tokens[length], 0, 0, 0, reg, seedILU ? 0 : 15,
                seedILU ? 15 : 0);
    if (relative)
        tokens[length].word[3] |= 2;
    length++;
    if (kind == 1 || kind == 3) {
        tokens[length] = token(1, 0, 0);
        source(&tokens[length], 0, 1, reg, 0xe4);
        reg = (reg + 1) % 12;
        destination(&tokens[length++], 0, 0, 0, reg, 15, 0);
    }
    tokens[length] = token(!seedILU, seedILU, 0);
    tokens[length].word[1] |= 6u << 9;
    source(&tokens[length], seedILU ? 2 : 0, kind == 2 ? 1 : 2, reg, 0xe4);
    destination(&tokens[length++], 0, 0, 0, reg, seedILU ? 0 : kill,
                seedILU ? kill : 0);
    tokens[length] = token(test.mac, test.ilu, 0);
    tokens[length].word[1] |= 7u << 9;
    for (unsigned operand = 0; operand < 3; operand++)
        source(&tokens[length], operand, 2, 0, 0xe4);
    source(&tokens[length], test.operand, 1, reg, swizzle);
    destination(&tokens[length++],
                kind == 4 ? 130 :
                test.fog  ? 0x105 :
                            0x103,
                kind == 3 ? 0 : test.output, test.iluOutput, 0, 0, 0);
    tokens[length] = token(1, 0, 0);
    tokens[length].word[1] |= 4u << 9;
    source(&tokens[length], 0, 2, 0, 0xe4);
    destination(&tokens[length++], 96, 15, 0, 0, 0, 0);
    tokens[length] = token(1, 0, 0);
    tokens[length].word[1] |= 3u << 9;
    source(&tokens[length], 0, 2, 0, 0xe4);
    destination(&tokens[length], 0x104, 15, 0, 0, 0, 0);
    tokens[length++].word[3] |= 1;
    assert(length <= 7);
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:length
                                                    error:&error];
    require(program != nil, error);
    return program;
}

static unsigned dead_paired_pairs(NV2AMetalWritableProgram *engine,
                                  NV2AMetalCommands *commands,
                                  id<MTLBuffer> input,
                                  const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = 0;
    for (unsigned seed = 1; seed <= 2; seed++)
        for (unsigned output = 1; output <= 2; output++) {
            Token tokens[5];
            tokens[0] = token(1, 0, 96);
            source(&tokens[0], 0, 3, 0, 0xe4);
            destination(&tokens[0], 0, 0, 0, seed, 15, 0);
            tokens[1] = token(1, 1, 0);
            source(&tokens[1], 0, 1, 1, 0xe4);
            source(&tokens[1], 2, 1, 2, 0xe4);
            destination(&tokens[1], 0, 0, 0, 2, 8, 8);
            tokens[2] = token(1, 0, 0);
            source(&tokens[2], 0, 1, output, 0xe4);
            destination(&tokens[2], 0x103, 8, 0, 0, 0, 0);
            tokens[3] = token(1, 0, 0);
            tokens[3].word[1] |= 4u << 9;
            source(&tokens[3], 0, 2, 0, 0xe4);
            destination(&tokens[3], 96, 15, 0, 0, 0, 0);
            tokens[4] = token(1, 0, 0);
            source(&tokens[4], 0, 2, 0, 0xe4);
            destination(&tokens[4], 0x100, 15, 0, 0, 0, 0);
            tokens[4].word[3] |= 1;
            NSError *error = nil;
            NV2AMetalValidatedProgram *program =
                [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                           length:5
                                                            error:&error];
            require(program != nil, error);
            /* Both operands are snapshots: R1/R2 exchange X simultaneously. */
            component_admission(program, 0, seed == output, seed, output);
            independent_pair(engine, commands, program, u, input, 17, 0, NO,
                             YES);
            pairs++;
        }
    return pairs;
}

static unsigned dead_write_pairs(NV2AMetalWritableProgram *engine,
                                 NV2AMetalCommands *commands,
                                 id<MTLBuffer> input,
                                 const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = 0;
    const unsigned swizzles[] = { 0xe4, 0x1b, 0x00, 0x55, 0xaa, 0xff };
    const unsigned components[6][4] = {
        { 8, 4, 2, 1 }, { 1, 2, 4, 8 }, { 8, 8, 8, 8 },
        { 4, 4, 4, 4 }, { 2, 2, 2, 2 }, { 1, 1, 1, 1 },
    };
    const unsigned counts[] = { 0, 1, 17, 257 };
    for (unsigned ilu = 0; ilu < 2; ilu++)
        for (unsigned swizzle = 0; swizzle < 6; swizzle++)
            for (unsigned use = 0; use < 16; use++)
                for (unsigned kill = 0; kill < 16; kill++) {
                    @autoreleasepool {
                        ComponentReadCase test = { 1, 0, 0,  use, 0, 0,
                                                   0, 0, NO, NO,  NO };
                        unsigned reads = 0;
                        for (unsigned lane = 0; lane < 4; lane++)
                            if (use & (8u >> lane))
                                reads |= components[swizzle][lane];
                        NV2AMetalValidatedProgram *program = dead_write_program(
                            test, ilu, (kill + swizzle) % 12, kill,
                            swizzles[swizzle], 0, 96, swizzle & 1);
                        unsigned access = kill & 1;
                        component_admission(program, access, !(reads & ~kill),
                                            use + 16 * swizzle, kill);
                        independent_pair(engine, commands, program, u, input,
                                         counts[(kill + use) % 4], access,
                                         !!(kill & 2), !!(use & 1));
                        pairs++;
                    }
                }
    assert(pairs == 3072);

    /* Hand-selected consumer dependencies, including packed Fog and scalar
     * ILU input. Read bits refer to the unswizzled private temporary. */
    const ComponentReadCase cases[] = {
        { 5, 0, 0, 8, 14, 0, 0, 0, NO, NO, NO },
        { 6, 0, 1, 8, 15, 0, 0, 0, NO, NO, NO },
        { 7, 0, 0, 8, 15, 0, 0, 0, NO, NO, NO },
        { 8, 0, 0, 8, 0, 0, 0, 0, NO, NO, NO },
        { 8, 0, 0, 2, 2, 0, 0, 0, NO, NO, NO },
        { 8, 0, 1, 1, 1, 0, 0, 0, NO, NO, NO },
        { 0, 2, 2, 4, 8, 0, 0, 0, YES, NO, NO },
        { 0, 5, 2, 1, 0, 0, 0, 0, YES, NO, NO },
        { 0, 7, 2, 2, 13, 0, 0, 0, YES, NO, NO },
        { 1, 0, 0, 1, 8, 0, 0, 0, NO, YES, NO },
        { 0, 6, 2, 1, 8, 0, 0, 0, YES, YES, NO },
        { 0, 7, 2, 6, 8, 0, 0, 0, YES, YES, NO },
    };
    for (unsigned c = 0; c < 12; c++)
        for (unsigned kind = 1; kind <= 3; kind++)
            for (unsigned kill = 0; kill < 16; kill++) {
                @autoreleasepool {
                    ComponentReadCase test = cases[c];
                    NV2AMetalValidatedProgram *program = dead_write_program(
                        test, c & 1, 2, kill, 0xe4, kind, 96, NO);
                    BOOL allowed =
                        kind == 3 || !(test.reads & (kind == 2 ? 15 : ~kill));
                    component_admission(program, c & 1, allowed, c, kill);
                    independent_pair(engine, commands, program, u, input, 17,
                                     c & 1, !!(kill & 1), !!(c & 1));
                    pairs++;
                }
            }
    assert(pairs == 3648);

    /* A temporary feeding a context store is observable even without any
     * corresponding vertex output. */
    for (unsigned ilu = 0; ilu < 2; ilu++)
        for (unsigned kill = 0; kill < 16; kill++) {
            ComponentReadCase test = { 1, 0, 0, 8, 0, 0, 0, 0, NO, NO, NO };
            NV2AMetalValidatedProgram *program =
                dead_write_program(test, ilu, 4, kill, 0xe4, 4, 96, NO);
            component_admission(program, 0, !(8u & ~kill), 130, kill);
            independent_pair(engine, commands, program, u, input, 17, 0, YES,
                             YES);
            pairs++;
        }

    /* R12 aliases a published output. Its surviving lanes remain observable,
     * even when the ordinary temporary consumer is dead. */
    for (unsigned ilu = 0; ilu < 2; ilu++)
        for (unsigned kill = 0; kill < 16; kill++) {
            ComponentReadCase test = { 1, 0, 0, 0, 0, 0, 0, 0, NO, NO, NO };
            NV2AMetalValidatedProgram *program =
                dead_write_program(test, ilu, 12, kill, 0xe4, 0, 96, NO);
            component_admission(program, 0, kill == 15, 12, kill);
            independent_pair(engine, commands, program, u, input, 17, 0, NO,
                             YES);
            pairs++;
        }
    const unsigned rows[] = { 58, 59, 95, 96, 192, 255 };
    for (unsigned r = 0; r < 6; r++)
        for (unsigned relative = 0; relative < 2; relative++)
            for (unsigned access = 0; access < 2; access++) {
                if (rows[r] >= 192 && !relative)
                    continue;
                ComponentReadCase test = { 1, 0, 0, 0, 0, 0, 0, 0, NO, NO, NO };
                NV2AMetalValidatedProgram *program = dead_write_program(
                    test, YES, 11, 15, 0xe4, 3, rows[r], relative);
                BOOL allowed = rows[r] < 192 && (access || rows[r] >= 96 ||
                                                 (!relative && rows[r] < 60));
                component_admission(program, access, allowed, r, 15);
                independent_pair(engine, commands, program, u, input, 17,
                                 access, YES, YES);
                pairs++;
            }
    pairs += dead_paired_pairs(engine, commands, input, u);
    assert(pairs == 3736);
    return pairs;
}
#endif
