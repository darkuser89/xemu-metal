/* Readonly static fault proof versus the native generic interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FAULT_FREE_READONLY_H
#define TEST_METAL_FAULT_FREE_READONLY_H
static unsigned proof_cases, proof_safe, proof_faults;
static void proof_finish(NV2AMetalCommands *commands, NSArray *encodings,
                         NSArray *programs, NSArray *accesses,
                         NSArray *expected)
{
    NSError *error = nil;
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (NSUInteger i = 0; i < encodings.count; i++) {
        NV2AMetalWritableEncoding *encoded = encodings[i];
        NV2AMetalValidatedProgram *program = programs[i];
        BOOL safe =
            [program hasFaultFreeReadOnlyAccess:[accesses[i] unsignedIntValue]];
        assert(safe == [expected[i] boolValue]);
        NV2AMetalWritableResult *actual = [encoded resolveWithError:&error];
        if (safe) {
            require(actual != nil, error);
            assert(actual.vertexCount == 4 && !actual.registers &&
                   actual.vertices);
            for (unsigned row = 0; row < 192; row++)
                assert(!((const uint32_t *)actual.written.bytes)[row]);
            proof_safe++;
        }
        proof_faults += !actual;
        proof_cases++;
    }
}
static void fault_free_readonly_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    /* Keep this an interpreter proof, independent of the specialization/JIT
     * thresholds and of the new host metadata being checked. */
    NV2AMetalWritableProgram *program =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(program != nil, error);
    NV2AMetalProgramInput values[4];
    const uint32_t inputs[] = { 0x3f000000, 0x7fc12345, 0x7f800000,
                                0x4f000000 };
    for (unsigned v = 0; v < 4; v++) {
        writable_input(&values[v], v);
        memcpy(&values[v].attributes[0][0], &inputs[v], 4);
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    /* Operand use from the existing instruction ISA: A, AB, AC, ABC. ILU
     * independently consumes C. Destination masks never disable operand reads.
     */
    static const unsigned operands[] = { 0, 1, 3, 5, 7, 3, 3,
                                         3, 3, 3, 3, 3, 3, 1 };
    const unsigned rows[] = { 0, 57, 58, 59, 60, 95, 96, 191 };
    NSMutableArray *encodings = [NSMutableArray new],
                   *programs = [NSMutableArray new],
                   *accesses = [NSMutableArray new],
                   *expected = [NSMutableArray new];
    proof_cases = proof_safe = proof_faults = 0;
    for (unsigned mac = 0; mac <= 13; mac++)
        for (unsigned ilu = 0; ilu <= 7; ilu++)
            for (unsigned sourceIndex = 0; sourceIndex < 3; sourceIndex++)
                for (unsigned rowIndex = 0; rowIndex < 8; rowIndex++)
                    for (unsigned relative = 0; relative < 2; relative++)
                        for (unsigned masked = 0; masked < 2; masked++)
                            for (unsigned access = 0; access < 2; access++) {
                                @autoreleasepool {
                                    unsigned row = rows[rowIndex];
                                    Token t = token(mac, ilu, row);
                                    for (unsigned s = 0; s < 3; s++)
                                        source(&t, s, s == sourceIndex ? 3 : 2,
                                               0, 0xe4);
                                    destination(
                                        &t, 0x103,
                                        masked || (mac == 13 && !ilu) ? 0 : 15,
                                        ilu != 0, 0, 0, 0);
                                    t.word[3] |= 1u | relative << 1;
                                    NV2AMetalValidatedProgram *validated =
                                        [[NV2AMetalValidatedProgram alloc]
                                            initWithTokens:t.word
                                                    length:1
                                                     error:&error];
                                    require(validated != nil, error);
                                    assert(![validated
                                        hasFaultFreeReadOnlyAccess:2]);
                                    unsigned reads =
                                        operands[mac] | (ilu ? 4 : 0);
                                    BOOL needed = reads & (1u << sourceIndex);
                                    BOOL safe =
                                        mac != 13 &&
                                        (!needed || access || row >= 96 ||
                                         (!relative &&
                                          (row == 58 || row == 59)));
                                    if (!encodings.count)
                                        require(
                                            [commands beginWithError:&error] !=
                                                nil,
                                            error);
                                    NV2AMetalProgramUniforms u = uniforms();
                                    for (unsigned r = 0; r < 192; r++)
                                        memcpy(&u.constants[r][0],
                                               &inputs[r % 4], 4);
                                    NV2AMetalWritableEncoding *encoded =
                                        [program encodeProgram:validated
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
                                    require(encoded != nil, error);
                                    NSError *pendingError = nil;
                                    NV2AMetalWritableResult *pending = [encoded
                                        pendingReadOnlyResultForCommands:
                                            commands
                                                                   error:
                                                                       &
                                                                       pendingError];
                                    assert(safe ? (pending && !pendingError) :
                                                  (!pending && pendingError));
                                    if (pending) {
                                        assert(!memcmp(pending.constants.bytes,
                                                       u.constants,
                                                       sizeof(u.constants)));
                                        assert(!pending.registers &&
                                               pending.vertices &&
                                               pending.vertexCount == 4);
                                    }
                                    [encodings addObject:encoded];
                                    [programs addObject:validated];
                                    [accesses addObject:@(access)];
                                    [expected addObject:@(safe)];
                                    if (encodings.count == 64) {
                                        proof_finish(commands, encodings,
                                                     programs, accesses,
                                                     expected);
                                        [encodings removeAllObjects];
                                        [programs removeAllObjects];
                                        [accesses removeAllObjects];
                                        [expected removeAllObjects];
                                    }
                                }
                            }
    if (encodings.count)
        proof_finish(commands, encodings, programs, accesses, expected);
    /* A proof does not authorize another queue, a discarded recording or
     * a real constant-writing serial context. */
    Token t = token(1, 0, 96);
    source(&t, 0, 3, 0, 0xe4);
    destination(&t, 0x103, 15, 0, 0, 0, 0);
    t.word[3] |= 3;
    NV2AMetalValidatedProgram *safe =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t.word
                                                   length:1
                                                    error:&error];
    assert([safe hasFaultFreeReadOnlyAccess:0] &&
           [safe hasFaultFreeReadOnlyAccess:1]);
    NV2AMetalProgramUniforms u = uniforms();
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *live = [program encodeProgram:safe
                                                    uniforms:&u
                                             attributeBuffer:attributes
                                                       first:0
                                                       count:4
                                                      access:0
                                                 writeEnable:NO
                                                   rasterize:YES
                                            compactRegisters:YES
                                                    commands:commands
                                                       error:&error];
    require(live != nil, error);
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(foreign != nil, error);
    assert(![live pendingReadOnlyResultForCommands:foreign error:&error]);
    [commands cancel];
    assert(![live pendingReadOnlyResultForCommands:commands error:&error]);
    require([commands beginWithError:&error] != nil, error);
    assert(![live pendingReadOnlyResultForCommands:commands error:&error]);
    [commands cancel];
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *raw = [program encodeProgram:safe uniforms:&u
        attributeBuffer:attributes first:0 count:4 access:0 writeEnable:NO
        rasterize:NO compactRegisters:YES commands:commands error:&error];
    require(raw != nil, error);
    NV2AMetalWritableResult *pendingRaw =
        [raw pendingReadOnlyResultForCommands:commands error:&error];
    require(pendingRaw != nil, error);
    assert(!pendingRaw.vertices && !pendingRaw.registers && pendingRaw.vertexCount == 4 &&
           !memcmp(pendingRaw.constants.bytes, u.constants, sizeof(u.constants)));
    require([commands submitWithError:&error] && [commands waitUntilIdleWithError:&error], error);
    NV2AMetalWritableResult *completedRaw = [raw resolveWithError:&error];
    require(completedRaw != nil, error);
    assert([pendingRaw.constants isEqual:completedRaw.constants] &&
           [pendingRaw.written isEqual:completedRaw.written] && !completedRaw.vertices);
    destination(&t, 191, 15, 0, 0, 0, 0);
    t.word[3] |= 1;
    NV2AMetalValidatedProgram *writer =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t.word
                                                   length:1
                                                    error:&error];
    assert(writer.mayWriteConstants && [writer hasFaultFreeReadOnlyAccess:1]);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *write = [program encodeProgram:writer
                                                     uniforms:&u
                                              attributeBuffer:attributes
                                                        first:0
                                                        count:4
                                                       access:1
                                                  writeEnable:YES
                                                    rasterize:YES
                                             compactRegisters:YES
                                                     commands:commands
                                                        error:&error];
    require(write != nil, error);
    assert(![write pendingReadOnlyResultForCommands:commands error:&error]);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    NV2AMetalWritableResult *written = [write resolveWithError:&error];
    require(written != nil, error);
    assert(((const uint32_t *)written.written.bytes)[191] == 1);
    assert(proof_cases == 14 * 8 * 3 * 8 * 2 * 2 * 2 && proof_safe &&
           proof_faults);
    printf(
        "Readonly fault proof:%u native interpreter cases/%u proven/%u GPU "
        "faults; "
        "all MAC/ILU/operands,USER/FULL,58/59 aperture,relative/ARL,zero masks,"
        "NaN/Inf/address overflow; known context and "
        "foreign/cancel/reuse/writer guards PASS\n",
        proof_cases, proof_safe, proof_faults);
}
#endif
