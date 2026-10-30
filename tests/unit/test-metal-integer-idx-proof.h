/* Bounded integer arithmetic before ARL, against the full GPU interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INTEGER_IDX_PROOF_H
#define TEST_METAL_INTEGER_IDX_PROOF_H
#include "test-metal-range-idx.h"
static void integer_step(Token *t, unsigned *count, unsigned mac,
                         unsigned destination_register, unsigned a, unsigned b,
                         unsigned c)
{
    Token *op = &t[(*count)++];
    *op = token(mac, 0, 96);
    source(op, 0, 1, a, a == 12 ? 0xff : 0xe4);
    source(op, 1, 1, b, b == 12 ? 0xff : 0xe4);
    source(op, 2, 1, c, c == 12 ? 0xff : 0xe4);
    destination(op, 0, 0, 0, destination_register, 15, 0);
}
static unsigned integer_idx_tokens(Token t[20], unsigned kind, unsigned base,
                                   BOOL read)
{
    if (kind >= 40)
        return range_idx_tokens(t, kind - 40, base, read);
    unsigned n = 0;
    BOOL variable =
        kind == 1 || kind == 2 || kind == 3 || (kind >= 16 && kind <= 19);
    integer_step(t, &n, variable ? NV2AMetalMACSlt : NV2AMetalMACMov, 2,
                 kind >= 13 && kind <= 15 ? 0 : 12, 0, 0);
    if (variable)
        source(&t[0], 0, 2, 0, 0xe4);
    if (kind >= 20) {
        unsigned opcode = kind == 24 || kind == 33 ? NV2AMetalMACDp3 :
                          kind == 25 || kind == 32 ? NV2AMetalMACDp4 :
                          kind == 26 || kind == 27 ? NV2AMetalMACDph :
                          kind == 28 || kind == 29 ? NV2AMetalMACDst :
                          kind == 30 || kind == 31 ? NV2AMetalMACMad :
                                                     NV2AMetalMACMul;
        unsigned reg_a = 0, reg_b = 0;
        if (kind == 27 || kind == 33) {
            integer_step(t, &n, NV2AMetalMACMov, 3, 0, 0, 0);
            source(&t[n - 1], 0, 2, 0, 0xe4);
            integer_step(t, &n, NV2AMetalMACMov, 3, 0, 0, 0);
            destination(&t[n - 1], 0, 0, 0, 3, kind == 27 ? 1 : 14, 0);
            if (kind == 33)
                reg_a = 3;
            else
                reg_b = 3;
        }
        if (kind == 32) {
            integer_step(t, &n, NV2AMetalMACMov, 3, 12, 0, 0);
            destination(&t[n - 1], 0, 0, 0, 3, 1, 0);
            reg_a = 3;
        }
        if (kind == 39) {
            for (unsigned i = 0; i < 9; i++)
                integer_step(t, &n, NV2AMetalMACAdd, 2, 2, 0, 2);
            reg_b = 2;
        }
        integer_step(t, &n, opcode, 2, reg_a, reg_b, 12);
        Token *op = &t[n - 1];
        if (kind == 20 || kind == 30)
            source(op, 0, 2, 0, 0xe4);
        else if (kind >= 21 && kind <= 23) {
            unsigned row = base < 256 ? base : 96;
            op->word[1] = (op->word[1] & ~(255u << 13)) | row << 13;
            source(op, 1, 3, 0, 0xe4);
            if (kind != 23 || row >= 192)
                op->word[3] |= 2;
        } else if (kind != 27 && kind != 39)
            source(op, 1, 2, 0, 0xe4);
        if (kind == 31)
            source(op, 2, 2, 0, 0xe4);
        if (kind == 34)
            op->word[1] |= 1u << 8;
        if (kind == 35)
            destination(op, 0, 0, 0, 2, 4, 0);
        if (kind == 36)
            destination(op, 0x100, 1, 0, 0, 0, 0);
        if (kind == 37 || kind == 38) {
            op->word[1] |= (kind == 37 ? 1u : 7u) << 25;
            source(op, 2, kind == 37 ? 2 : 1, 0, 0xe4);
            destination(op, 0, 0, 0, 1, 15, 15);
        }
    } else if (kind <= 1)
        integer_step(t, &n, NV2AMetalMACAdd, 2, 2, 0, 2);
    else if (kind == 2 || kind == 3 || kind == 19) {
        integer_step(t, &n, NV2AMetalMACAdd, 2, 2, 0, 12);
        integer_step(t, &n, kind == 2 ? NV2AMetalMACMul : NV2AMetalMACMad, 2, 2,
                     2, 12);
    } else if (kind >= 4 && kind <= 7) {
        if (kind == 6) {
            integer_step(t, &n, NV2AMetalMACMov, 2, 0, 0, 0);
            source(&t[n - 1], 0, 2, 0, 0xe4);
            destination(&t[n - 1], 0, 0, 0, 2, 1, 0);
        }
        if (kind == 7)
            integer_step(t, &n, NV2AMetalMACAdd, 2, 2, 0, 2);
        integer_step(t, &n,
                     kind == 4 ? NV2AMetalMACDp3 :
                     kind == 5 ? NV2AMetalMACDp4 :
                     kind == 6 ? NV2AMetalMACDph :
                                 NV2AMetalMACDst,
                     2, 2, kind == 6 ? 12 : 2, 0);
    } else if ((kind >= 8 && kind <= 10) || (kind >= 16 && kind <= 18)) {
        unsigned doubles = kind == 10 || kind == 18 ? 9 : kind >= 16 ? 7 : 8;
        for (unsigned i = 0; i < doubles; i++)
            integer_step(t, &n, NV2AMetalMACAdd, 2, 2, 0, 2);
    } else if (kind == 11) {
        for (unsigned i = 0; i < 4; i++)
            integer_step(t, &n, NV2AMetalMACAdd, 2, 2, 0, 2);
        integer_step(t, &n, NV2AMetalMACAdd, 3, 2, 0, 12);
        integer_step(t, &n, NV2AMetalMACMul, 4, 2, 2, 0);
        integer_step(t, &n, NV2AMetalMACMad, 2, 2, 3, 4);
        t[n - 1].word[2] |= 1u << 10;
    } else if (kind == 12) {
        for (unsigned i = 0; i < 8; i++)
            integer_step(t, &n, NV2AMetalMACAdd, 2, 2, 0, 2);
        integer_step(t, &n, NV2AMetalMACMov, 3, 2, 0, 0);
        integer_step(t, &n, NV2AMetalMACMov, 3, 2, 0, 0);
        t[n - 1].word[1] |= 1u << 8;
        destination(&t[n - 1], 0, 0, 0, 3, 3, 0);
        integer_step(t, &n, NV2AMetalMACDp4, 2, 2, 3, 0);
    } else {
        integer_step(t, &n,
                     kind == 13 ? NV2AMetalMACMul :
                     kind == 14 ? NV2AMetalMACAdd :
                                  NV2AMetalMACMad,
                     2, 2, 0, 12);
        source(&t[n - 1], kind == 14 ? 2 : 1, 2, 0, 0xe4);
    }
    t[n] = token(NV2AMetalMACArl, 0, 96);
    source(&t[n], 0, 1,
           kind == 36               ? 12 :
           kind == 37 || kind == 38 ? 1 :
                                      2,
           kind == 7 || kind == 28                ? 0x55 :
           kind == 29 || kind == 36 || kind == 38 ? 0xff :
                                                    0);
    if (kind == 9 || kind == 17 || kind == 19)
        t[n].word[1] |= 1u << 8;
    destination(&t[n], 0, 0, 0, 0, 0, 0);
    n++;
    if (read) {
        t[n] = token(NV2AMetalMACMov, 0, base);
        source(&t[n], 0, 3, 0, 0xe4);
        destination(&t[n], 0x103, 15, 0, 0, 0, 0);
        t[n++].word[3] |= 2;
    }
    t[n - 1].word[3] |= 1;
    return n;
}
static void integer_idx_proof_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput inputs[16];
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x00800000, 0x3f800000, 0xbf800000,
                              0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
                              0x7fc12345, 0x7f800001, 0x3f000000, 0xbf000000 };
    for (unsigned v = 0; v < 16; v++) {
        writable_input(&inputs[v], v);
        for (unsigned lane = 0; lane < 4; lane++)
            memcpy(&inputs[v].attributes[0][lane], &bits[(v + lane) % 16], 4);
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:inputs
                                     length:sizeof(inputs)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    unsigned cases = 0, proven = 0, faults = 0;
    /* Bounds are the mathematical outcomes of these independent token
     * constructions, not calls into the production range analyzer. */
    const int lows[] = { 2, 0, 1, 2,  3,    4, 4,  4, 256, -256, 0, 16, 0,
                         0, 0, 1, 0,  -128, 0, -5, 0, 0,   0,    0, 0,  0,
                         0, 0, 0, 0,  1,    0, 0,  0, 0,   1,    0, 0,  1,
                         0, 0, 1, -1, 0,    1, 0,  0, 1,   0,    0, 0,  1 };
    const int highs[] = { 2, 2, 4, 5,   3, 4, 4,  4, 256, -256, 0, 16, 0,
                          0, 0, 1, 128, 0, 0, -2, 0, 0,   0,    0, 0,  0,
                          0, 0, 0, 0,   1, 0, 0,  0, 0,   1,    0, 0,  1,
                          0, 0, 1, 0,   1, 1, 0,  0, 1,   1,    1, 0,  1 };
    for (unsigned kind = 0; kind < 52; kind++)
        for (unsigned span = 0; span < 257; span++)
            for (unsigned access = 0; access < 2; access++) {
                @autoreleasepool {
                    BOOL read = span < 256 && kind != 22 && kind != 23;
                    BOOL known = kind != 10 && kind != 14 && kind != 18 &&
                                 kind != 26 && kind != 29 && kind != 31 &&
                                 kind != 32 && kind != 37;
                    BOOL safe = known &&
                                (!read ||
                                 ((int)span + lows[kind] >= (access ? 0 : 96) &&
                                  (int)span + highs[kind] < 192));
                    if (kind >= 21 && kind <= 23) {
                        unsigned row = span < 256 ? span : 96;
                        safe &= row < 192 &&
                                (access || row >= 96 ||
                                 (kind == 23 && (row == 58 || row == 59)));
                    }
                    Token t[20];
                    unsigned slots = integer_idx_tokens(t, kind, span, read);
                    NV2AMetalValidatedProgram *program =
                        [[NV2AMetalValidatedProgram alloc]
                            initWithTokens:t[0].word
                                    length:slots
                                     error:&error];
                    require(program != nil, error);
                    if ([program hasFaultFreeReadOnlyAccess:access] != safe) {
                        fprintf(stderr,
                                "Integer IDX kind%u base%u access%u "
                                "read%d expected%d observed%d\n",
                                kind, span, access, read, safe,
                                [program hasFaultFreeReadOnlyAccess:access]);
                        abort();
                    }
                    NV2AMetalProgramUniforms u = uniforms();
                    for (unsigned row = 0; row < 192; row++)
                        for (unsigned lane = 0; lane < 4; lane++)
                            memcpy(&u.constants[row][lane],
                                   &bits[(row + lane) % 16], 4);
                    require([commands beginWithError:&error] != nil, error);
                    BOOL raster = (span + kind) % 2;
                    NV2AMetalWritableEncoding *compact =
                        [reference encodeProgram:program
                                        uniforms:&u
                                 attributeBuffer:attributes
                                           first:0
                                           count:16
                                          access:access
                                     writeEnable:NO
                                       rasterize:raster
                                compactRegisters:YES
                                        commands:commands
                                           error:&error];
                    NV2AMetalWritableEncoding *full =
                        [reference encodeProgram:program
                                        uniforms:&u
                                 attributeBuffer:attributes
                                           first:0
                                           count:16
                                          access:access
                                     writeEnable:NO
                                       rasterize:raster
                                compactRegisters:NO
                                        commands:commands
                                           error:&error];
                    require(compact && full, error);
                    NV2AMetalWritableResult *pending =
                        [compact pendingReadOnlyResultForCommands:commands
                                                            error:&error];
                    BOOL contextSafe =
                        [program hasFaultFreeReadOnlyAccess:access
                                                  constants:&u.constants[0][0]];
                    assert(!!pending == contextSafe && (!safe || contextSafe));
                    require([commands submitWithError:&error] &&
                                [commands waitUntilIdleWithError:&error],
                            error);
                    NSError *ae = nil, *be = nil;
                    NV2AMetalWritableResult *a = [compact resolveWithError:&ae],
                                            *b = [full resolveWithError:&be];
                    assert(!!a == !!b && (!contextSafe || a));
                    if (a) {
                        assert([a.constants isEqual:b.constants] &&
                               [a.written isEqual:b.written] &&
                               [a.constants
                                   isEqualToData:
                                       [NSData
                                           dataWithBytes:u.constants
                                                  length:sizeof(u.constants)]]);
                        if (raster)
                            assert(!memcmp(a.vertices.contents,
                                           b.vertices.contents,
                                           16 * sizeof(NV2AMetalVertex)));
                        else
                            assert(!a.vertices);
                        if (contextSafe)
                            assert([pending.constants isEqual:a.constants] &&
                                   [pending.written isEqual:a.written]);
                    } else {
                        assert(ae && be && ae.code == be.code &&
                               [ae.localizedDescription
                                   isEqual:be.localizedDescription]);
                        faults++;
                    }
                    proven += safe;
                    cases++;
                }
            }
    assert(!memcmp(attributes.contents, inputs, sizeof(inputs)) &&
           cases == 26728);
    printf(
        "Integer IDX proof:%u native compact/full-interpreter pairs/%u "
        "proven/%u GPU faults;all256 bases,USER/FULL,no-read ARL,ADD/MUL/MAD/"
        "DP3/DPH/DP4/DST,negative/swizzled/masked and large-cancellation "
        "chains,256/512 range bounds,NaN/Inf/denormals,exact context/vertices "
        "and unchanged inputs;zero-wins/signed-zero/unknown/NaN/Inf products, "
        "unskipped operand apertures,DPH/DST exclusions,R12 and paired R1 "
        "ordering;6168 MIN/MAX/SLT/SGE boundary pairs with conservative "
        "signed-zero ties PASS\n",
        cases, proven, faults);
}
static unsigned constant_idx_pairs, constant_idx_safe, constant_idx_faults;
static void constant_idx_pair(NV2AMetalCommands *commands,
                              NV2AMetalWritableProgram *reference,
                              const Token *tokens, unsigned slots,
                              const NV2AMetalProgramUniforms *u,
                              id<MTLBuffer> attributes, unsigned access,
                              BOOL expected, int expectedFault)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalValidatedProgram *program =
            [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                       length:slots
                                                        error:&error];
        require(program != nil, error);
        assert([program
                   hasFaultFreeReadOnlyAccess:access
                                    constants:&u->constants[0][0]] == expected);
        assert(![program hasFaultFreeReadOnlyAccess:2
                                          constants:&u->constants[0][0]]);
        assert(![program hasFaultFreeReadOnlyAccess:access constants:NULL]);
        require([commands beginWithError:&error] != nil, error);
        BOOL raster = constant_idx_pairs & 1;
        NV2AMetalWritableEncoding *compact = [reference encodeProgram:program
                                                             uniforms:u
                                                      attributeBuffer:attributes
                                                                first:0
                                                                count:4
                                                               access:access
                                                          writeEnable:NO
                                                            rasterize:raster
                                                     compactRegisters:YES
                                                             commands:commands
                                                                error:&error];
        NV2AMetalWritableEncoding *full = [reference encodeProgram:program
                                                          uniforms:u
                                                   attributeBuffer:attributes
                                                             first:0
                                                             count:4
                                                            access:access
                                                       writeEnable:NO
                                                         rasterize:raster
                                                  compactRegisters:NO
                                                          commands:commands
                                                             error:&error];
        require(compact && full, error);
        NV2AMetalWritableResult *pending =
            [compact pendingReadOnlyResultForCommands:commands error:&error];
        assert(!!pending == expected);
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        NSError *ae = nil, *be = nil;
        NV2AMetalWritableResult *a = [compact resolveWithError:&ae],
                                *b = [full resolveWithError:&be];
        assert(!!a == !!b && (!expected || a));
        if (expectedFault >= 0)
            assert(!a == !!expectedFault);
        if (a) {
            assert(
                [a.constants isEqual:b.constants] &&
                [a.written isEqual:b.written] &&
                [a.constants
                    isEqualToData:[NSData dataWithBytes:u->constants
                                                 length:sizeof(u->constants)]]);
            const uint32_t *written = a.written.bytes;
            for (unsigned row = 0; row < 192; row++)
                assert(!written[row]);
            if (raster)
                assert(!memcmp(a.vertices.contents, b.vertices.contents,
                               4 * sizeof(NV2AMetalVertex)));
            else
                assert(!a.vertices);
            if (pending)
                assert([pending.constants isEqual:a.constants] &&
                       [pending.written isEqual:a.written]);
        } else {
            assert(ae && be && ae.code == be.code &&
                   [ae.localizedDescription isEqual:be.localizedDescription]);
            constant_idx_faults++;
        }
        constant_idx_pairs++;
        constant_idx_safe += expected;
    }
}
static void constant_idx_proof_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput inputs[4];
    for (unsigned v = 0; v < 4; v++) {
        writable_input(&inputs[v], v);
        inputs[v].attributes[0][0] = v & 1 ? -1 : 1;
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:inputs
                                     length:sizeof(inputs)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    /* Every bounded integer, both access windows and all encoded bases.
     * Expected addresses below are ordinary integer sums, independent of the
     * production bit classifier and range analyzer. */
    for (int value = -256; value <= 256; value++)
        for (unsigned baseIndex = 0; baseIndex < 4; baseIndex++)
            for (unsigned access = 0; access < 2; access++) {
                unsigned base = (unsigned[]){ 0, 95, 96, 191 }[baseIndex];
                NV2AMetalProgramUniforms u = uniforms();
                u.constants[100][0] = (float)value;
                Token t[2] = { token(13, 0, 100), token(1, 0, base) };
                source(&t[0], 0, 3, 0, 0);
                destination(&t[0], 0, 0, 0, 0, 0, 0);
                source(&t[1], 0, 3, 0, 0xe4);
                destination(&t[1], 0x103, 15, 0, 0, 0, 0);
                t[1].word[3] |= 3;
                int row = (int)base + value;
                BOOL safe = row >= 0 && row < 192 && (access || row >= 96);
                constant_idx_pair(commands, reference, t, 2, &u, attributes,
                                  access, safe, !safe);
            }
    const int offsets[] = { -256, -96, -1, 0, 1, 95, 191, 256, 257 };
    for (unsigned base = 0; base < 256; base++)
        for (unsigned i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++)
            for (unsigned access = 0; access < 2; access++) {
                NV2AMetalProgramUniforms u = uniforms();
                u.constants[100][0] = (float)offsets[i];
                Token t[2] = { token(13, 0, 100), token(1, 0, base) };
                source(&t[0], 0, 3, 0, 0);
                destination(&t[0], 0, 0, 0, 0, 0, 0);
                source(&t[1], 0, 3, 0, 0xe4);
                destination(&t[1], 0x103, 15, 0, 0, 0, 0);
                t[1].word[3] |= 3;
                int row = (int)base + offsets[i];
                BOOL valid = row >= 0 && row < 192 && (access || row >= 96);
                constant_idx_pair(commands, reference, t, 2, &u, attributes,
                                  access, valid && offsets[i] <= 256, !valid);
            }
    /* Fraction/exponent boundaries, both signed zeros, denormals, infinities
     * and NaNs; select every lane with both signs and no later constant read.
     * Unproven values may execute successfully, but may never bypass feedback.
     */
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x00800000, 0x3f000000, 0xbf000000,
                              0x3f7fffff, 0x3f800000, 0xbf800000, 0x3f800001,
                              0x437fffff, 0x43800000, 0xc3800000, 0x43800001,
                              0x43808000, 0x7f800000, 0xff800000, 0x7fc12345,
                              0x7f800001, 0x4f000000 };
    const unsigned rows[] = { 58, 59, 95, 96, 191 };
    for (unsigned i = 0; i < sizeof(bits) / sizeof(bits[0]); i++)
        for (unsigned r = 0; r < 5; r++)
            for (unsigned lane = 0; lane < 4; lane++)
                for (unsigned negate = 0; negate < 2; negate++)
                    for (unsigned access = 0; access < 2; access++) {
                        NV2AMetalProgramUniforms u = uniforms();
                        memcpy(&u.constants[rows[r]][lane], &bits[i], 4);
                        Token t = token(13, 0, rows[r]);
                        source(&t, 0, 3, 0, lane * 0x55);
                        t.word[1] |= negate << 8;
                        destination(&t, 0, 0, 0, 0, 0, 0);
                        t.word[3] |= 1;
                        BOOL integer = i == 0 || i == 1 || i == 9 || i == 10 ||
                                       i == 13 || i == 14;
                        BOOL readable = access || rows[r] >= 96 ||
                                        rows[r] == 58 || rows[r] == 59;
                        constant_idx_pair(commands, reference, &t, 1, &u,
                                          attributes, access,
                                          integer && readable, -1);
                    }
    /* Input-selected relative rows feed another ARL. The two possible rows
     * must both be known, even if only one of their values is dangerous. */
    for (unsigned mode = 0; mode < 6; mode++)
        for (unsigned access = 0; access < 2; access++) {
            NV2AMetalProgramUniforms u = uniforms();
            u.constants[100][0] = 0;
            u.constants[101][0] = mode == 1 ? 1 : 0;
            if (mode == 2)
                u.constants[101][0] = 0.5f;
            if (mode == 3)
                memcpy(&u.constants[101][0], &(uint32_t){ 0x7fc12345 }, 4);
            if (mode == 4)
                u.constants[101][0] = -1;
            if (mode == 5)
                u.constants[101][0] = 256;
            Token t[5] = { token(11, 0, 96), token(13, 0, 96), token(1, 0, 100),
                           token(13, 0, 96),
                           token(1, 0, mode == 1 ? 191 : 96) };
            source(&t[0], 0, 2, 0, 0xe4);
            source(&t[0], 1, 1, 0, 0xe4);
            destination(&t[0], 0, 0, 0, 2, 15, 0);
            source(&t[1], 0, 1, 2, 0);
            destination(&t[1], 0, 0, 0, 0, 0, 0);
            source(&t[2], 0, 3, 0, 0xe4);
            destination(&t[2], 0, 0, 0, 3, 15, 0);
            t[2].word[3] |= 2;
            source(&t[3], 0, 1, 3, 0);
            destination(&t[3], 0, 0, 0, 0, 0, 0);
            source(&t[4], 0, 3, 0, 0xe4);
            destination(&t[4], 0x103, 15, 0, 0, 0, 0);
            t[4].word[3] |= 3;
            BOOL safe = mode == 0 || (mode == 4 && access);
            constant_idx_pair(
                commands, reference, t, 5, &u, attributes, access, safe,
                mode == 1 || mode == 3 || mode == 5 || (mode == 4 && !access));
        }
    assert(constant_idx_pairs == 10484 && constant_idx_safe &&
           constant_idx_faults &&
           !memcmp(attributes.contents, inputs, sizeof(inputs)));
    printf("Constant IDX proof:%u native compact/full-interpreter pairs/%u "
           "proven/%u GPU faults;all513 bounded integers/all256 bases,"
           "USER/FULL/58+59,swizzles/negation,no-read ARL,Float32 boundaries/"
           "signed-zero/NaN/Inf/denormals,input-selected relative constants,"
           "exact context/vertices and unchanged inputs PASS\n",
           constant_idx_pairs, constant_idx_safe, constant_idx_faults);
}
#endif
