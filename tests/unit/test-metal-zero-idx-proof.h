/* Relative zero-IDX proof checked against actual generic GPU fault/output.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ZERO_IDX_PROOF_H
#define TEST_METAL_ZERO_IDX_PROOF_H
static void zero_idx_proof_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput values[4];
    for (unsigned v = 0; v < 4; v++)
        writable_input(&values[v], v);
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    unsigned cases = 0, proven = 0, faults = 0;
    for (unsigned base = 0; base < 256; base++)
        for (unsigned access = 0; access < 2; access++)
            for (unsigned masked = 0; masked < 2; masked++) {
                @autoreleasepool {
                    Token t = token(1, 0, base);
                    source(&t, 0, 3, 0, 0xe4);
                    destination(&t, 0x103, masked ? 0 : 15, 0, 0, 0, 0);
                    t.word[3] |= 3;
                    NV2AMetalValidatedProgram *program =
                        [[NV2AMetalValidatedProgram alloc]
                            initWithTokens:t.word
                                    length:1
                                     error:&error];
                    require(program != nil, error);
                    BOOL safe = base < 192 && (access || base >= 96);
                    assert([program hasFaultFreeReadOnlyAccess:access] == safe);
                    NV2AMetalProgramUniforms u = uniforms();
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalWritableEncoding *compact =
                        [reference encodeProgram:program
                                        uniforms:&u
                                 attributeBuffer:attributes
                                           first:0
                                           count:4
                                          access:access
                                     writeEnable:NO
                                       rasterize:YES
                                compactRegisters:YES
                                        commands:commands
                                           error:&error];
                    NV2AMetalWritableEncoding *full =
                        [reference encodeProgram:program
                                        uniforms:&u
                                 attributeBuffer:attributes
                                           first:0
                                           count:4
                                          access:access
                                     writeEnable:NO
                                       rasterize:YES
                                compactRegisters:NO
                                        commands:commands
                                           error:&error];
                    require(compact && full, error);
                    NSError *pendingError = nil;
                    NV2AMetalWritableResult *pending = [compact
                        pendingReadOnlyResultForCommands:commands
                                                   error:&pendingError];
                    assert(safe ? (pending && !pendingError) :
                                  (!pending && pendingError));
                    require([commands submitWithError:&error] &&
                                [commands waitUntilIdleWithError:&error],
                            error);
                    NV2AMetalWritableResult *a =
                        [compact resolveWithError:&error];
                    NV2AMetalWritableResult *b = [full resolveWithError:&error];
                    assert(!!a == safe && !!b == safe);
                    if (safe) {
                        assert([a.constants isEqual:b.constants] &&
                               [a.written isEqual:b.written] &&
                               [a.constants isEqual:pending.constants] &&
                               [a.written isEqual:pending.written] &&
                               !memcmp(a.vertices.contents, b.vertices.contents,
                                       4 * sizeof(NV2AMetalVertex)));
                        NV2AMetalProgramOutput *raw = b.registers.contents;
                        for (unsigned v = 0; v < 4; v++) {
                            assert(!raw[v].fault);
                            const float *expected =
                                masked ? (const float[]){ 0, 0, 0, 1 } :
                                         u.constants[base];
                            assert(!memcmp(raw[v].registers[3], expected, 16));
                        }
                        proven++;
                    } else {
                        assert(error);
                        faults++;
                    }
                    cases++;
                }
            }
    /* An input-dependent ARL before END stays unproven, including when
     * its result is not consumed. A dead ARL after END is not executable. */
    for (unsigned order = 0; order < 3; order++) {
        Token t[2] = { token(1, 0, 96), token(13, 0, 96) };
        source(&t[0], 0, 3, 0, 0xe4);
        destination(&t[0], 0x103, 15, 0, 0, 0, 0);
        t[0].word[3] |= 2;
        source(&t[1], 0, 2, 0, 0xe4);
        destination(&t[1], 0, 0, 0, 0, 0, 0);
        if (order == 1) {
            Token swap = t[0];
            t[0] = t[1];
            t[1] = swap;
        }
        t[order == 2 ? 0 : 1].word[3] |= 1;
        NV2AMetalValidatedProgram *program =
            [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                       length:2
                                                        error:&error];
        require(program != nil, error);
        assert([program hasFaultFreeReadOnlyAccess:0] == (order == 2) &&
               [program hasFaultFreeReadOnlyAccess:1] == (order == 2));
        memset(t, 0xff, sizeof(t));
        assert([program hasFaultFreeReadOnlyAccess:0] == (order == 2));
    }
    assert(cases == 1024 && proven == 576 && faults == 448);
    printf(
        "Zero-IDX readonly proof:%u native compact/full-interpreter pairs/"
        "%u proven/%u GPU faults;all256 relative bases,USER/FULL,zero/full "
        "output masks,four vertices,exact registers/vertices/context;"
        "Input-dependent ARL before/after read stays synchronous,dead END tail "
        "and immutable "
        "tokens PASS\n",
        cases, proven, faults);
}
static void bounded_idx_tokens(Token t[4], unsigned kind, unsigned base)
{
    for (unsigned i = 0; i < 4; i++)
        t[i] = token(0, 0, 96);
    unsigned reg = kind == 0 ? 11 : kind <= 2 ? 12 : 2;
    unsigned swizzle = kind == 1 || kind == 2 ? 0xff : 0;
    if (kind >= 3) {
        unsigned mac = kind == 4  ? 12 :
                       kind == 12 ? 8 :
                       kind == 11 || kind == 13 || kind == 14 || kind == 15 ?
                                    0 :
                                    11;
        unsigned ilu = kind == 8 || kind == 9 || kind == 11 ? 1 :
                       kind == 13                           ? 7 :
                       kind == 14                           ? 5 :
                       kind == 15                           ? 6 :
                                                              0;
        t[0] = token(mac, ilu, 96);
        source(&t[0], 0, 2, 0, 0xe4);
        source(&t[0], 1, 1, 0, 0xe4);
        source(&t[0], 2, kind == 11 ? 1 : 2, kind == 11 ? 12 : 0,
               kind == 11 ? 0xff : 0xe4);
        unsigned temp = kind == 8 ? 1 : kind == 10 ? 12 : 2;
        destination(&t[0], 0, 0, 0, temp, kind == 6 ? 1 : 15, ilu ? 15 : 0);
        if (kind == 8)
            reg = 1;
        if (kind == 10)
            reg = 12;
        if (kind == 14 || kind == 15)
            swizzle = 0xff;
        if (kind == 7) {
            t[1] = token(1, 0, 96);
            source(&t[1], 0, 2, 0, 0xe4);
            destination(&t[1], 0, 0, 0, 2, 8, 0);
        }
        if (kind == 16 || kind == 17) {
            t[1] = token(kind == 16 ? 9 : 10, 0, 96);
            source(&t[1], 0, 1, 2, 0xe4);
            t[1].word[1] |= 1u << 8;
            source(&t[1], 1, 1, 12, 0xff);
            destination(&t[1], 0, 0, 0, 2, 15, 0);
        }
        if (kind == 18) {
            t[1] = token(1, 0, 96);
            source(&t[1], 0, 1, 2, 0xff);
            destination(&t[1], 0, 0, 0, 3, 8, 0);
            reg = 3;
        }
        if (kind == 19) {
            t[1] = token(0, 1, 96);
            source(&t[1], 2, 1, 2, 0xe4);
            t[1].word[2] |= 1u << 10;
            destination(&t[1], 0, 0, 0, 12, 0, 15);
            reg = 12;
        }
    }
    t[2] = token(13, 0, 96);
    source(&t[2], 0, kind == 5 ? 2 : 1, reg, swizzle);
    if (kind == 2 || kind == 4)
        t[2].word[1] |= 1u << 8;
    destination(&t[2], 0, 0, 0, 0, 0, 0);
    t[3] = token(1, 0, base);
    source(&t[3], 0, 3, 0, 0xe4);
    destination(&t[3], 0x103, 15, 0, 0, 0, 0);
    t[3].word[3] |= 3;
}
static void bounded_idx_proof_tests(NV2AMetalCommands *commands)
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
    for (unsigned kind = 0; kind < 20; kind++)
        for (unsigned base = 0; base < 256; base++)
            for (unsigned access = 0; access < 2; access++) {
                @autoreleasepool {
                    Token t[4];
                    bounded_idx_tokens(t, kind, base);
                    NV2AMetalValidatedProgram *program =
                        [[NV2AMetalValidatedProgram alloc]
                            initWithTokens:t[0].word
                                    length:4
                                     error:&error];
                    require(program != nil, error);
                    /* Independent mathematical bounds: MIN(-boolean,1) is
                     * [-1,0], MAX(-boolean,1) is1. No analyzer output is
                     * used to derive the expected access apertures. */
                    static const int lows[] = {
                        0, 1, -1, 0, -1, 0, 0,  0, 0, 0,
                        0, 1, 1,  1, 1,  1, -1, 1, 0, -1
                    };
                    static const int highs[] = {
                        0, 1, -1, 1, 0, 1, 0, 1, 1, 1,
                        1, 1, 1,  1, 1, 1, 0, 1, 1, 0
                    };
                    int low = lows[kind], high = highs[kind];
                    BOOL safe = kind != 5 && kind != 7 && kind != 8 &&
                                (int)base + low >= (access ? 0 : 96) &&
                                (int)base + high < 192;
                    if ([program hasFaultFreeReadOnlyAccess:access] != safe) {
                        fprintf(stderr,
                                "Bounded IDX kind%u base%u access%u "
                                "expected%d observed%d\n",
                                kind, base, access, safe,
                                [program hasFaultFreeReadOnlyAccess:access]);
                        abort();
                    }
                    NV2AMetalProgramUniforms u = uniforms();
                    for (unsigned row = 0; row < 192; row++)
                        for (unsigned lane = 0; lane < 4; lane++)
                            memcpy(&u.constants[row][lane],
                                   &bits[(row + lane) % 16], 4);
                    require([commands beginWithError:&error] != nil, error);
                    BOOL raster = (base + kind) % 2;
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
                    assert(!!pending == safe);
                    require([commands submitWithError:&error] &&
                                [commands waitUntilIdleWithError:&error],
                            error);
                    NSError *ae = nil, *be = nil;
                    NV2AMetalWritableResult *a = [compact resolveWithError:&ae],
                                            *b = [full resolveWithError:&be];
                    assert(!!a == !!b && (!safe || a));
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
                        if (safe)
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
    unsigned ordered = 0;
    const unsigned boundaries[] = { 95, 96, 190, 191 };
    for (unsigned mode = 0; mode < 5; mode++)
        for (unsigned boundary = 0; boundary < 4; boundary++)
            for (unsigned access = 0; access < 2; access++) {
                Token t[3] = { token(0, 0, 96),
                               token(13, 1, boundaries[boundary]),
                               token(1, 0, 96) };
                BOOL oldOne = mode != 1 && mode != 4;
                if (oldOne) {
                    t[0] = token(13, 0, 96);
                    source(&t[0], 0, 1, 12, 0xff);
                }
                source(&t[1], 0, 1,
                       mode == 1 ? 12 :
                       mode == 4 ? 1 :
                                   0,
                       mode == 1 ? 0xff : 0);
                source(&t[1], 2, mode == 4 ? 2 : 3, 0, 0xe4);
                destination(&t[1], 0x100,
                            mode == 3 ? 1 :
                            mode == 4 ? 0 :
                                        15,
                            1, 0, 0, mode == 4 ? 8 : 0);
                t[1].word[3] |= 2;
                if (mode == 2 || mode == 3) {
                    t[2] = token(13, 0, 96);
                    source(&t[2], 0, 1, 12, 0);
                } else {
                    if (mode == 4)
                        t[2] = token(1, 0, boundaries[boundary]);
                    source(&t[2], 0, 3, 0, 0xe4);
                    destination(&t[2], 0x103, 15, 0, 0, 0, 0);
                    t[2].word[3] |= 2;
                }
                t[2].word[3] |= 1;
                unsigned index = boundaries[boundary] + oldOne;
                BOOL safe = mode != 2 && index < 192 && (access || index >= 96);
                NV2AMetalValidatedProgram *validated =
                    [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                               length:3
                                                                error:&error];
                require(validated != nil, error);
                assert([validated hasFaultFreeReadOnlyAccess:access] == safe);
                NV2AMetalProgramUniforms u = uniforms();
                if (mode == 2)
                    for (unsigned row = 0; row < 192; row++)
                        memcpy(&u.constants[row][0], &bits[12], 4);
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalWritableEncoding *a =
                    [reference encodeProgram:validated
                                    uniforms:&u
                             attributeBuffer:attributes
                                       first:0
                                       count:16
                                      access:access
                                 writeEnable:NO
                                   rasterize:NO
                            compactRegisters:YES
                                    commands:commands
                                       error:&error];
                NV2AMetalWritableEncoding *b =
                    [reference encodeProgram:validated
                                    uniforms:&u
                             attributeBuffer:attributes
                                       first:0
                                       count:16
                                      access:access
                                 writeEnable:NO
                                   rasterize:NO
                            compactRegisters:NO
                                    commands:commands
                                       error:&error];
                require(a && b, error);
                assert(!![a pendingReadOnlyResultForCommands:commands
                                                       error:&error] == safe);
                require([commands submitWithError:&error] &&
                            [commands waitUntilIdleWithError:&error],
                        error);
                NV2AMetalWritableResult *ar = [a resolveWithError:&error],
                                        *br = [b resolveWithError:&error];
                assert(!!ar == safe && !!br == safe);
                if (safe && mode != 3) {
                    const NV2AMetalProgramOutput *raw = br.registers.contents;
                    unsigned row = mode == 4 ? boundaries[boundary] :
                                   mode == 1 ? 97 :
                                               96;
                    for (unsigned v = 0; v < 16; v++)
                        assert(
                            !memcmp(raw[v].registers[3], u.constants[row], 16));
                }
                ordered++;
            }
    assert(cases == 10240 && ordered == 40 && proven && faults &&
           !memcmp(attributes.contents, inputs, sizeof(inputs)));
    printf("Bounded IDX proof:%u native compact/full-interpreter pairs/%u "
           "proven/%u GPU faults;all256 bases,USER/FULL,initial R12/temps,"
           "comparison/negation/moves/masks,paired R1 suppression/R12 alias,"
           "MIN/MAX and DST/LIT/EXP/LOG lanes;40 paired "
           "old-IDX/source-before-output/R1/R12 "
           "ordering checks;raw/raster,NaN/Inf/denorms,exact context/"
           "vertices and unchanged inputs PASS\n",
           cases, proven, faults);
}
#endif
