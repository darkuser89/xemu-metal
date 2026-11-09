/* Masked constant dependencies versus the serial GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPONENT_WRITES_H
#define TEST_METAL_COMPONENT_WRITES_H

typedef struct ComponentReadCase {
    unsigned mac, ilu, operand, output, reads;
    unsigned macTemporary, iluTemporary, temporary;
    BOOL iluOutput, fog, serial;
} ComponentReadCase;

static NV2AMetalValidatedProgram *
component_program(ComponentReadCase test, unsigned writeMask, unsigned swizzle,
                  unsigned readRow, BOOL relative)
{
    Token tokens[7];
    tokens[0] = token(1, 0, 0);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(test.mac, test.ilu, readRow);
    tokens[1].word[1] |= 6u << 9;
    for (unsigned operand = 0; operand < 3; operand++)
        source(&tokens[1], operand, 2, 0, 0xe4);
    source(&tokens[1], test.operand, 3, 0, swizzle);
    if (writeMask & 4) {
        unsigned word = test.operand == 0 ? 1 : 2;
        unsigned bit = test.operand == 0 ? 8 : test.operand == 1 ? 25 : 10;
        tokens[1].word[word] |= 1u << bit;
    }
    destination(&tokens[1], test.fog ? 0x105 : 0x103, test.output,
                test.iluOutput, test.temporary, test.macTemporary,
                test.iluTemporary);
    if (relative)
        tokens[1].word[3] |= 2u;
    tokens[2] = token(1, 0, 0);
    tokens[2].word[1] |= 4u << 9;
    source(&tokens[2], 0, 2, 0, 0xe4);
    destination(&tokens[2], 96, writeMask, 0, 0, 0, 0);
    tokens[3] = token(0, 1, 0);
    tokens[3].word[1] |= 5u << 9;
    source(&tokens[3], 2, 2, 0, 0xe4);
    /* Keep an actual context store even when the tested write mask is zero. */
    destination(&tokens[3], 130, 1, 1, 0, 0, 0);
    unsigned length = 4;
    /* Keep the tested temporary results observable, independently of the
     * separate admission tests for dead/overwritten temporary components. */
    for (unsigned ilu = 0; ilu < 2; ilu++) {
        if (!(ilu ? test.iluTemporary : test.macTemporary))
            continue;
        unsigned reg = ilu && test.mac && test.ilu ? 1 : test.temporary;
        tokens[length] = token(1, 0, 0);
        source(&tokens[length], 0, 1, reg, 0xe4);
        destination(&tokens[length++], 0x109 + ilu, 15, 0, 0, 0, 0);
    }
    tokens[length] = token(1, 0, 0);
    tokens[length].word[1] |= 3u << 9;
    source(&tokens[length], 0, 2, 0, 0xe4);
    destination(&tokens[length], 0x104, 15, 0, 0, 0, 0);
    tokens[length++].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:length
                                                    error:&error];
    require(program != nil, error);
    return program;
}

static void component_admission(NV2AMetalValidatedProgram *program,
                                unsigned access, BOOL expected, unsigned test,
                                unsigned writeMask)
{
    BOOL actual = independent_proof(
        program, @selector(hasIndependentConstantWrites:), access);
    if (actual != expected) {
        fprintf(stderr,
                "Component XF admission:test%u mask%u access%u "
                "selected%d expected%d\n",
                test, writeMask, access, actual, expected);
        abort();
    }
}

static unsigned component_chain_pairs(NV2AMetalWritableProgram *engine,
                                      NV2AMetalCommands *commands,
                                      id<MTLBuffer> input)
{
    const unsigned counts[] = { 0, 1, 17, 257 };
    unsigned pairs = 0;
    for (unsigned n = 0; n < 4; n++)
        for (unsigned raster = 0; raster < 2; raster++) {
            NSError *error = nil;
            ComponentReadCase readOther = {
                1, 0, 0, 8, 8, 0, 0, 0, NO, NO, NO
            };
            ComponentReadCase readY = { 1, 0, 0, 4, 4, 0, 0, 0, NO, NO, NO };
            NV2AMetalValidatedProgram *a =
                component_program(readOther, 4, 0xe4, 120, NO);
            NV2AMetalValidatedProgram *b =
                component_program(readY, 8, 0xe4, 96, YES);
            component_admission(a, 0, YES, 0, 4);
            component_admission(b, 0, YES, 1, 8);
            NV2AMetalProgramUniforms u = uniforms(), stale = u;
            u.constants[96][1] = 123.5f;
            stale.constants[96][1] = -999.625f;
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
                independent_expect(b, 0, counts[n], reference);
                second[reference] = [engine encodeSerialProgram:b
                                                       uniforms:&stale
                                                attributeBuffer:input
                                                          first:8
                                                          count:counts[n]
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

static unsigned component_write_pairs(NV2AMetalWritableProgram *engine,
                                      NV2AMetalCommands *commands,
                                      id<MTLBuffer> input,
                                      const NV2AMetalProgramUniforms *u)
{
    unsigned pairs = 0;
    /* Manual constant-component maps, independent of the production decoder. */
    const unsigned swizzles[] = { 0xe4, 0x1b, 0x00, 0x55, 0xaa, 0xff };
    const unsigned components[6][4] = {
        { 8, 4, 2, 1 }, { 1, 2, 4, 8 }, { 8, 8, 8, 8 },
        { 4, 4, 4, 4 }, { 2, 2, 2, 2 }, { 1, 1, 1, 1 },
    };
    for (unsigned swizzle = 0; swizzle < 6; swizzle++)
        for (unsigned readMask = 0; readMask < 16; readMask++)
            for (unsigned writeMask = 0; writeMask < 16; writeMask++) {
                @autoreleasepool {
                    unsigned read = 0;
                    for (unsigned lane = 0; lane < 4; lane++)
                        if (readMask & (8u >> lane))
                            read |= components[swizzle][lane];
                    ComponentReadCase test = { 1, 0, 0,  readMask, 0, 0,
                                               0, 0, NO, NO,       NO };
                    NV2AMetalValidatedProgram *program = component_program(
                        test, writeMask, swizzles[swizzle], 96, swizzle & 1);
                    unsigned access = writeMask & 1;
                    component_admission(program, access, !(read & writeMask),
                                        swizzle * 16 + readMask, writeMask);
                    independent_pair(engine, commands, program, u, input, 17,
                                     access, !!(writeMask & 2),
                                     !!(readMask & 1));
                    pairs++;
                }
            }
    assert(pairs == 1536);

#define CR_MAC(M, S, O, R) { M, 0, S, O, R, 0, 0, 0, NO, NO, M == 13 }
#define CR_ILU(I, O, R) { 0, I, 2, O, R, 0, 0, 0, YES, NO, NO }
#define CR_FOG(M, I, S, O, R)                   \
    {                                           \
        M, I, S, O, R, 0, 0, 0, M == 0, YES, NO \
    }
    const ComponentReadCase cases[] = {
        CR_MAC(0, 0, 8, 0),
        CR_MAC(1, 0, 8, 8),
        CR_MAC(2, 0, 8, 8),
        CR_MAC(2, 1, 8, 8),
        CR_MAC(3, 0, 8, 8),
        CR_MAC(3, 2, 8, 8),
        CR_MAC(4, 0, 8, 8),
        CR_MAC(4, 1, 8, 8),
        CR_MAC(4, 2, 8, 8),
        CR_MAC(5, 0, 8, 14),
        CR_MAC(5, 1, 8, 14),
        CR_MAC(6, 0, 8, 14),
        CR_MAC(6, 1, 8, 15),
        CR_MAC(7, 0, 8, 15),
        CR_MAC(7, 1, 8, 15),
        CR_MAC(8, 0, 8, 0),
        CR_MAC(8, 1, 8, 0),
        CR_MAC(8, 0, 4, 4),
        CR_MAC(8, 1, 4, 4),
        CR_MAC(8, 0, 2, 2),
        CR_MAC(8, 1, 2, 0),
        CR_MAC(8, 0, 1, 0),
        CR_MAC(8, 1, 1, 1),
        CR_MAC(9, 0, 8, 8),
        CR_MAC(9, 1, 8, 8),
        CR_MAC(10, 0, 8, 8),
        CR_MAC(10, 1, 8, 8),
        CR_MAC(11, 0, 8, 8),
        CR_MAC(11, 1, 8, 8),
        CR_MAC(12, 0, 8, 8),
        CR_MAC(12, 1, 8, 8),
        CR_MAC(13, 0, 0, 8),
        CR_ILU(1, 8, 8),
        CR_ILU(1, 4, 4),
        CR_ILU(1, 2, 2),
        CR_ILU(1, 1, 1),
        CR_ILU(2, 8, 8),
        CR_ILU(2, 4, 8),
        CR_ILU(2, 2, 8),
        CR_ILU(2, 1, 8),
        CR_ILU(3, 8, 8),
        CR_ILU(3, 4, 8),
        CR_ILU(3, 2, 8),
        CR_ILU(3, 1, 8),
        CR_ILU(4, 8, 8),
        CR_ILU(4, 4, 8),
        CR_ILU(4, 2, 8),
        CR_ILU(4, 1, 8),
        CR_ILU(5, 8, 8),
        CR_ILU(5, 4, 8),
        CR_ILU(5, 2, 8),
        CR_ILU(5, 1, 0),
        CR_ILU(6, 8, 8),
        CR_ILU(6, 4, 8),
        CR_ILU(6, 2, 8),
        CR_ILU(6, 1, 0),
        CR_ILU(7, 8, 0),
        CR_ILU(7, 4, 8),
        CR_ILU(7, 2, 13),
        CR_ILU(7, 1, 0),
        CR_FOG(1, 0, 0, 1, 8),
        CR_FOG(1, 0, 0, 2, 8),
        CR_FOG(1, 0, 0, 6, 12),
        CR_FOG(1, 0, 0, 9, 12),
        CR_FOG(1, 0, 0, 15, 15),
        CR_FOG(0, 1, 2, 1, 8),
        CR_FOG(0, 1, 2, 2, 8),
        CR_FOG(0, 1, 2, 6, 12),
        CR_FOG(0, 1, 2, 9, 12),
        CR_FOG(0, 1, 2, 15, 15),
        /* Fog W selects the ILU's X, not EXP/LOG's constant W result. */
        CR_FOG(0, 5, 2, 1, 8),
        CR_FOG(0, 6, 2, 1, 8),
        CR_FOG(0, 7, 2, 2, 0),
        CR_FOG(0, 7, 2, 6, 8),
        /* Shared C: vector MAC W plus scalar ILU X; paired R1 suppression. */
        { 3, 2, 2, 4, 9, 1, 0, 2, YES, NO, NO },
        { 3, 2, 2, 4, 8, 1, 0, 1, YES, NO, NO },
        /* Suppressed MAC A is unused; an R2 temporary keeps its W input. */
        { 3, 2, 0, 4, 0, 1, 0, 1, YES, NO, NO },
        { 3, 2, 0, 4, 1, 1, 0, 2, YES, NO, NO },
        /* MAD C and LIT share X/Y/W, including packed Fog output. */
        { 4, 7, 2, 1, 13, 1, 2, 2, NO, YES, NO },
        { 4, 7, 2, 1, 13, 1, 2, 1, NO, YES, NO },
    };
#undef CR_MAC
#undef CR_ILU
#undef CR_FOG
    assert(sizeof(cases) / sizeof(cases[0]) == 80);
    for (unsigned c = 0; c < 80; c++)
        for (unsigned variant = 0; variant < 2; variant++)
            for (unsigned writeMask = 0; writeMask < 16; writeMask++) {
                @autoreleasepool {
                    ComponentReadCase test = cases[c];
                    unsigned map = variant ? test.operand + 1 : 0;
                    unsigned reads = 0;
                    for (unsigned lane = 0; lane < 4; lane++)
                        if (test.reads & (8u >> lane))
                            reads |= components[map][lane];
                    NV2AMetalValidatedProgram *program = component_program(
                        test, writeMask, swizzles[map], 96, NO);
                    unsigned access = writeMask & 1;
                    component_admission(program, access,
                                        !test.serial && !(reads & writeMask), c,
                                        writeMask);
                    independent_pair(engine, commands, program, u, input, 17,
                                     access, !!(c & 1), !!(writeMask & 1));
                    pairs++;
                }
            }
    assert(pairs == 4096);

    /* Unobservable values still perform the interpreter's aperture checks. */
    const unsigned rows[] = { 58, 95, 96, 192, 255 };
    for (unsigned r = 0; r < 5; r++)
        for (unsigned relative = 0; relative < 2; relative++)
            for (unsigned access = 0; access < 2; access++) {
                if (rows[r] >= 192 && !relative)
                    continue; /* The token validator rejects these upfront. */
                ComponentReadCase test = { 1, 0, 0, 0, 0, 0, 0, 0, NO, NO, NO };
                NV2AMetalValidatedProgram *program =
                    component_program(test, 15, 0xe4, rows[r], relative);
                BOOL allowed = rows[r] < 192 && (access || rows[r] >= 96 ||
                                                 (!relative && rows[r] == 58));
                component_admission(program, access, allowed, r, 15);
                independent_pair(engine, commands, program, u, input, 17,
                                 access, YES, YES);
                pairs++;
            }
    assert(pairs == 4112);
    pairs += component_chain_pairs(engine, commands, input);
    return pairs;
}
#endif
