/* Native decoded-program reuse with live per-dispatch state.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_PROGRAM_CACHE_H
#define TEST_METAL_PROGRAM_CACHE_H

static id program_cache_entry(NV2AMetalWritableProgram *program)
{
    return [program valueForKey:@"decodedProgram"];
}
static id<MTLBuffer> program_cache_buffer(id entry)
{
    return [entry valueForKey:@"buffer"];
}
static NV2AMetalWritableResult *
program_cache_run(NV2AMetalWritableProgram *program, const Token *tokens,
                  NSUInteger length, NV2AMetalProgramUniforms *u,
                  id<MTLBuffer> inputs, NSUInteger first, NSUInteger count,
                  unsigned access, BOOL enabled, BOOL rasterize)
{
    NSError *error = nil;
    NV2AMetalWritableResult *result = [program executeTokens:tokens[0].word
                                                      length:length
                                                    uniforms:u
                                             attributeBuffer:inputs
                                                       first:first
                                                       count:count
                                                      access:access
                                                 writeEnable:enabled
                                                   rasterize:rasterize
                                                       error:&error];
    require(result != nil, error);
    return result;
}
static void program_cache_feedback(NV2AMetalWritableResult *result,
                                   NV2AMetalProgramUniforms *u,
                                   const NV2AMetalProgramInput *inputs,
                                   NSUInteger first, NSUInteger count,
                                   unsigned attribute, BOOL enabled)
{
    float expected[192][4];
    memcpy(expected, u->constants, sizeof(expected));
    const NV2AMetalProgramOutput *raw = result.registers.contents;
    assert(result.vertexCount == count);
    for (NSUInteger v = 0; v < count; v++) {
        assert(!raw[v].fault);
        for (unsigned k = 0; k < 4; k++) {
            float before = expected[96][k];
            float sum = before + inputs[first + v].attributes[attribute][k];
            if (enabled)
                expected[96][k] = sum;
            assert(raw[v].registers[0][k] ==
                   inputs[first + v].attributes[0][k]);
            assert(raw[v].registers[9][k] == before);
            assert(raw[v].registers[10][k] == expected[96][k]);
            assert(raw[v].registers[11][k] == sum &&
                   raw[v].registers[12][k] == 0);
        }
    }
    assert(!memcmp(result.constants.bytes, expected, sizeof(expected)));
    const uint32_t *dirty = result.written.bytes;
    for (unsigned row = 0; row < 192; row++)
        assert(dirty[row] == (unsigned)(row == 96 && enabled && count));
}
static void program_cache_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *program =
        [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                   error:&error];
    require(program != nil, error);
    assert(!program_cache_entry(program));
    Token tokens[7];
    writable_tokens(tokens, 96, 3, 15);
    NSData *originalTokens = [NSData dataWithBytes:tokens
                                            length:sizeof(tokens)];
    NV2AMetalProgramInput inputs[3];
    for (unsigned i = 0; i < 3; i++)
        writable_input(&inputs[i], i);
    id<MTLBuffer> inputBuffer =
        [commands.device newBufferWithBytes:inputs
                                     length:sizeof(inputs)
                                    options:MTLResourceStorageModeShared];
    assert(inputBuffer);
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalWritableResult *r = program_cache_run(
        program, tokens, 7, &u, inputBuffer, 0, 3, 1, YES, YES);
    program_cache_feedback(r, &u, inputs, 0, 3, 3, YES);
    id firstEntry = program_cache_entry(program);
    id<MTLBuffer> firstBuffer = program_cache_buffer(firstEntry);
    assert(firstEntry && firstBuffer &&
           firstBuffer.length == 7 * sizeof(NV2AMetalProgramInstruction));
    NSData *immutableSource = [firstEntry valueForKey:@"tokens"];
    assert([immutableSource isEqualToData:originalTokens]);
    NSData *decodedBytes = [NSData dataWithBytes:firstBuffer.contents
                                          length:firstBuffer.length];

    /* Same bytes at a different host pointer, live constants and both
     * pipelines. */
    Token same[7];
    memcpy(same, tokens, sizeof(same));
    for (unsigned enabled = 0; enabled < 2; enabled++) {
        for (unsigned rasterize = 0; rasterize < 2; rasterize++) {
            u.constants[96][0] += 16;
            r = program_cache_run(program, same, 7, &u, inputBuffer, 1, 2,
                                  enabled, enabled, rasterize);
            program_cache_feedback(r, &u, inputs, 1, 2, 3, enabled);
            assert(program_cache_entry(program) == firstEntry);
            assert(program_cache_buffer(program_cache_entry(program)) ==
                   firstBuffer);
            assert(!memcmp(firstBuffer.contents, decodedBytes.bytes,
                           decodedBytes.length));
        }
    }
    r = program_cache_run(program, tokens, 7, &u, inputBuffer, 3, 0, 1, YES,
                          NO);
    program_cache_feedback(r, &u, inputs, 3, 0, 3, YES);
    assert(program_cache_entry(program) == firstEntry);

    /* A mutation at the same address must miss; the old key remains immutable.
     */
    tokens[2].word[1] = (tokens[2].word[1] & ~(15u << 9)) | 4u << 9;
    r = program_cache_run(program, tokens, 7, &u, inputBuffer, 0, 3, 1, YES,
                          YES);
    program_cache_feedback(r, &u, inputs, 0, 3, 4, YES);
    id changed = program_cache_entry(program);
    assert(changed != firstEntry &&
           program_cache_buffer(changed) != firstBuffer);
    assert([immutableSource isEqualToData:originalTokens]);
    assert(
        !memcmp(firstBuffer.contents, decodedBytes.bytes, decodedBytes.length));
    memcpy(tokens, originalTokens.bytes, sizeof(tokens));
    r = program_cache_run(program, tokens, 7, &u, inputBuffer, 0, 3, 1, YES,
                          YES);
    program_cache_feedback(r, &u, inputs, 0, 3, 3, YES);
    assert(program_cache_entry(program) == firstEntry);

    /* Declared trailing slots remain outside execution after the first END. */
    Token padded[8];
    memcpy(padded, tokens, sizeof(tokens));
    memset(&padded[7], 0xff, sizeof(padded[7]));
    r = program_cache_run(program, padded, 8, &u, inputBuffer, 0, 3, 1, YES,
                          YES);
    program_cache_feedback(r, &u, inputs, 0, 3, 3, YES);
    id paddedEntry = program_cache_entry(program);
    assert([[paddedEntry valueForKey:@"slots"] unsignedIntegerValue] == 7);
    assert(program_cache_buffer(paddedEntry).length == firstBuffer.length);
    padded[7].word[0] ^= 1;
    r = program_cache_run(program, padded, 8, &u, inputBuffer, 0, 3, 1, YES,
                          YES);
    program_cache_feedback(r, &u, inputs, 0, 3, 3, YES);
    assert(program_cache_entry(program) != paddedEntry);

    Token early[7];
    memcpy(early, tokens, sizeof(early));
    early[0].word[3] |= 1;
    r = program_cache_run(program, early, 7, &u, inputBuffer, 0, 3, 1, YES, NO);
    id earlyEntry = program_cache_entry(program);
    assert([[earlyEntry valueForKey:@"slots"] unsignedIntegerValue] == 1);
    assert(program_cache_buffer(earlyEntry).length ==
           sizeof(NV2AMetalProgramInstruction));
    const NV2AMetalProgramOutput *raw = r.registers.contents;
    for (unsigned v = 0; v < 3; v++) {
        assert(!raw[v].fault);
        for (unsigned k = 0; k < 4; k++) {
            assert(raw[v].registers[0][k] == inputs[v].attributes[0][k]);
            assert(raw[v].registers[9][k] == (k == 3 ? 1 : 0));
        }
    }
    assert(!memcmp(r.constants.bytes, u.constants, sizeof(u.constants)));
    r = program_cache_run(program, tokens, 7, &u, inputBuffer, 0, 3, 1, YES,
                          YES);
    program_cache_feedback(r, &u, inputs, 0, 3, 3, YES);
    id good = program_cache_entry(program);
    for (unsigned mode = 0; mode < 4; mode++) {
        Token bad[7];
        memcpy(bad, tokens, sizeof(bad));
        NSUInteger length = 7;
        if (mode == 0)
            bad[0].word[1] = (bad[0].word[1] & ~(15u << 21)) | 15u << 21;
        else if (mode == 1)
            bad[6].word[3] &= ~1u;
        else if (mode == 2)
            length = 0;
        else
            length = NSUIntegerMax;
        error = nil;
        assert(![program executeTokens:bad[0].word
                                length:length
                              uniforms:&u
                       attributeBuffer:inputBuffer
                                 first:0
                                 count:3
                                access:1
                           writeEnable:YES
                                 error:&error]);
        assert(error && program_cache_entry(program) == good);
    }
    r = program_cache_run(program, tokens, 7, &u, inputBuffer, 0, 3, 1, YES,
                          YES);
    program_cache_feedback(r, &u, inputs, 0, 3, 3, YES);
    assert(program_cache_entry(program) == good);

    /* Hits never skip per-dispatch argument/uniform validation. */
    for (unsigned mode = 0; mode < 3; mode++) {
        NV2AMetalProgramUniforms badUniforms = u;
        if (mode == 0)
            badUniforms.surface_size[0] = 0;
        error = nil;
        assert(![program executeTokens:tokens[0].word
                                length:7
                              uniforms:&badUniforms
                       attributeBuffer:inputBuffer
                                 first:mode == 2 ? 4 : 0
                                 count:1
                                access:mode == 1 ? 2 : 1
                           writeEnable:YES
                                 error:&error]);
        assert(error && program_cache_entry(program) == good);
    }

    /* A dynamic address fault must not cache failure or old mutable context. */
    Token fault[3] = { token(1, 0, 0), token(13, 0, 0), token(1, 0, 96) };
    source(&fault[0], 0, 2, 0, 0xe4);
    destination(&fault[0], 191, 15, 0, 0, 0, 0);
    fault[1].word[1] |= 1u << 9;
    source(&fault[1], 0, 2, 0, 0xe4);
    destination(&fault[1], 0, 0, 0, 0, 8, 0);
    source(&fault[2], 0, 3, 0, 0xe4);
    destination(&fault[2], 0x109, 15, 0, 0, 0, 0);
    fault[2].word[3] |= 3;
    NV2AMetalProgramInput *live = inputBuffer.contents;
    live[0].attributes[1][0] = 1000;
    error = nil;
    assert(![program executeTokens:fault[0].word
                            length:3
                          uniforms:&u
                   attributeBuffer:inputBuffer
                             first:0
                             count:1
                            access:1
                       writeEnable:YES
                         rasterize:NO
                             error:&error]);
    assert(error &&
           [error.localizedDescription containsString:@"address fault"]);
    id faultEntry = program_cache_entry(program);
    live[0].attributes[1][0] = 0;
    r = program_cache_run(program, fault, 3, &u, inputBuffer, 0, 1, 1, YES, NO);
    assert(program_cache_entry(program) == faultEntry);
    raw = r.registers.contents;
    assert(!raw[0].fault);
    const float (*constants)[4] = r.constants.bytes;
    for (unsigned k = 0; k < 4; k++) {
        assert(raw[0].registers[9][k] == u.constants[96][k]);
        assert(constants[191][k] == live[0].attributes[0][k]);
    }
    const uint32_t *dirty = r.written.bytes;
    for (unsigned row = 0; row < 192; row++)
        assert(dirty[row] == (unsigned)(row == 191));
    puts("Decoded program cache: immutable content reuse, live "
         "uniforms/pipelines/"
         "suffixes, source mutation, length/END changes, invalid-program "
         "rollback "
         "and dynamic-fault retry with fresh context PASS");
}
#endif
