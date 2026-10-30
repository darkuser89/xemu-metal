/* Validated effect metadata versus actual full serial GPU context writes.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_NONWRITING_PROGRAM_H
#define TEST_METAL_NONWRITING_PROGRAM_H
static unsigned effect_cases, effect_writers, effect_rejects;
static void effect_resolve(NSArray<NV2AMetalWritableEncoding *> *encodings,
                           NSArray<NV2AMetalValidatedProgram *> *programs)
{
    for (NSUInteger i = 0; i < encodings.count; i++) {
        NSError *error = nil;
        NV2AMetalWritableResult *r = [encodings[i] resolveWithError:&error];
        require(r != nil, error);
        assert(r.registers && r.vertexCount == 1);
        const uint32_t *dirty = r.written.bytes;
        BOOL wrote = NO;
        for (unsigned row = 0; row < 192; row++) {
            assert(dirty[row] <= 1);
            wrote |= dirty[row] != 0;
        }
        assert(wrote == programs[i].mayWriteConstants);
        effect_writers += wrote;
        effect_cases++;
    }
}
static void nonwriting_opcode_pairs(NV2AMetalWritableProgram *serial,
                                    NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *parallel =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(parallel != nil, error);
    NV2AMetalProgramInput values[68];
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x00800000, 0x3f800001, 0x3f7fffff,
                              0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
                              0x7fc00123, 0x7f800123, 0x3f000000, 0xbf800000 };
    for (unsigned v = 0; v < 68; v++) {
        writable_input(&values[v], v);
        values[v].attributes[0][0] = v % 4;
        values[v].attributes[0][1] = v % 7;
        values[v].attributes[0][2] = 8;
        values[v].attributes[0][3] = 1;
        for (unsigned a = 1; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                memcpy(&values[v].attributes[a][k], &bits[(v + a * 3 + k) % 16],
                       4);
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    NV2AMetalProgramUniforms u = uniforms();
    for (unsigned row = 0; row < 192; row++)
        for (unsigned k = 0; k < 4; k++)
            memcpy(&u.constants[row][k], &bits[(row + k) % 16], 4);
    unsigned pairs = 0, faults = 0;
    for (unsigned mac = 0; mac <= 13; mac++)
        for (unsigned ilu = 0; ilu <= 7; ilu++)
            for (unsigned temp = 0; temp < 2; temp++)
                for (unsigned swizzle = 0; swizzle < 2; swizzle++) {
                    Token tokens[6];
                    specialized_op_tokens(tokens, mac, ilu, 15, temp ? 12 : 1,
                                          swizzle ? 0x1b : 0xe4);
                    NV2AMetalValidatedProgram *validated =
                        [[NV2AMetalValidatedProgram alloc]
                            initWithTokens:tokens[0].word
                                    length:6
                                     error:&error];
                    require(validated != nil, error);
                    assert(!validated.mayWriteConstants);
                    for (unsigned access = 0; access < 2; access++)
                        for (unsigned raster = 0; raster < 2; raster++) {
                            require([commands beginWithError:&error] != nil,
                                    error);
                            NV2AMetalWritableEncoding *a =
                                [serial encodeProgram:validated
                                             uniforms:&u
                                      attributeBuffer:input
                                                first:3
                                                count:64
                                               access:access
                                          writeEnable:YES
                                            rasterize:raster
                                     compactRegisters:NO
                                             commands:commands
                                                error:&error];
                            NV2AMetalWritableEncoding *b =
                                [parallel encodeProgram:validated
                                               uniforms:&u
                                        attributeBuffer:input
                                                  first:3
                                                  count:64
                                                 access:access
                                            writeEnable:NO
                                              rasterize:raster
                                       compactRegisters:NO
                                               commands:commands
                                                  error:&error];
                            require(a && b, error);
                            require(
                                [commands submitWithError:&error] &&
                                    [commands waitUntilIdleWithError:&error],
                                error);
                            NSError *ae = nil, *be = nil;
                            NV2AMetalWritableResult *ar = [a
                                                        resolveWithError:&ae],
                                                    *br = [b
                                                        resolveWithError:&be];
                            assert(!!ar == !!br);
                            if (!ar) {
                                assert(ae && be &&
                                       [ae.domain isEqual:be.domain] &&
                                       ae.code == be.code &&
                                       [ae.localizedDescription
                                           isEqual:be.localizedDescription]);
                                faults++;
                            } else {
                                assert(
                                    [ar.constants isEqual:br.constants] &&
                                    [ar.written isEqual:br.written] &&
                                    !memcmp(
                                        ar.registers.contents,
                                        br.registers.contents,
                                        64 * sizeof(NV2AMetalProgramOutput)) &&
                                    !memcmp(ar.vertices.contents,
                                            br.vertices.contents,
                                            64 * sizeof(NV2AMetalVertex)));
                            }
                            pairs++;
                        }
                }
    assert(pairs == 1792 && !memcmp(input.contents, values, sizeof(values)));
    assert(![[parallel valueForKey:@"specializationAttempts"]
        unsignedIntegerValue]);
    printf("Nonwriting opcode parity:%u full-serial/general-parallel64-vertex "
           "pairs/%u fault pairs;all14 MACx8 "
           "ILU,R1/R12,swizzles,USER/FULL,raw/raster,NaN/Inf/zero/denormal "
           "constants and inputs PASS\n",
           pairs, faults);
    fflush(stdout);
}

static void nonwriting_program_tests(NV2AMetalWritableProgram *program,
                                     NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalProgramInput value;
    writable_input(&value, 0);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:&value
                                     length:sizeof(value)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    NV2AMetalProgramUniforms u = uniforms();
    NSMutableArray *encodings = [NSMutableArray new],
                   *programs = [NSMutableArray new];
    for (unsigned mac = 0; mac <= 13; mac++)
        for (unsigned ilu = 0; ilu <= 7; ilu++)
            for (unsigned mux = 0; mux < 2; mux++)
                for (unsigned vertex = 0; vertex < 2; vertex++)
                    for (unsigned mask = 0; mask < 16; mask++) {
                        Token t = token(mac, ilu, 96);
                        for (unsigned sourceIndex = 0; sourceIndex < 3;
                             sourceIndex++)
                            source(&t, sourceIndex, 2, 0, 0xe4);
                        destination(&t, vertex ? 0x100 : 96, mask, mux, 0, 0,
                                    0);
                        t.word[3] |= 1;
                        error = nil;
                        NV2AMetalValidatedProgram *validated =
                            [[NV2AMetalValidatedProgram alloc]
                                initWithTokens:t.word
                                        length:1
                                         error:&error];
                        if (!validated) {
                            assert(error && mac == 13 && !mux && mask);
                            effect_rejects++;
                            continue;
                        }
                        if (!encodings.count)
                            require([commands beginWithError:&error] != nil,
                                    error);
                        NV2AMetalWritableEncoding *encoded =
                            [program encodeProgram:validated
                                          uniforms:&u
                                   attributeBuffer:input
                                             first:0
                                             count:1
                                            access:1
                                       writeEnable:YES
                                         rasterize:NO
                                  compactRegisters:NO
                                          commands:commands
                                             error:&error];
                        require(encoded != nil, error);
                        [encodings addObject:encoded];
                        [programs addObject:validated];
                        if (encodings.count == 64) {
                            require(
                                [commands submitWithError:&error] &&
                                    [commands waitUntilIdleWithError:&error],
                                error);
                            effect_resolve(encodings, programs);
                            [encodings removeAllObjects];
                            [programs removeAllObjects];
                        }
                    }
    if (encodings.count) {
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        effect_resolve(encodings, programs);
    }
    /* Neither dead slots after END nor later mutation changes the owned proof.
     */
    Token dead[2] = { token(1, 0, 96), token(1, 0, 96) };
    source(&dead[0], 0, 2, 0, 0xe4);
    destination(&dead[0], 0x100, 15, 0, 0, 0, 0);
    dead[0].word[3] |= 1;
    source(&dead[1], 0, 2, 0, 0xe4);
    destination(&dead[1], 96, 15, 0, 0, 0, 0);
    NV2AMetalValidatedProgram *owned =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:dead[0].word
                                                   length:2
                                                    error:&error];
    require(owned != nil, error);
    assert(owned.slots == 1 && !owned.mayWriteConstants);
    destination(&dead[0], 96, 15, 0, 0, 0, 0);
    assert(!owned.mayWriteConstants);
    NV2AMetalValidatedProgram *changed =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:dead[0].word
                                                   length:2
                                                    error:&error];
    require(changed != nil, error);
    assert(changed.mayWriteConstants);
    assert(effect_cases + effect_rejects == 7168 && effect_rejects == 240);
    printf("Program constant effects:%u full serial GPU contexts/%u actual "
           "writers,%u invalid ARL destinations;all14 MACx8 ILU/both output "
           "muxes/constant-or-vertex/all16 masks;dead END tail and immutable "
           "source mutation PASS\n",
           effect_cases, effect_writers, effect_rejects);
    fflush(stdout);
    nonwriting_opcode_pairs(program, commands);
}
#endif
