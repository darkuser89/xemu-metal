/* Read-only XFCTX: exact inputs, context bits, raw mode and later faults.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_READONLY_H
#define TEST_METAL_READONLY_H
static void readonly_contract(NV2AMetalWritableProgram *program,
                              NV2AMetalCommands *commands)
{
    const unsigned count = 257, first = 7, total = first + count + 19;
    NV2AMetalProgramInput *input = calloc(total, sizeof(*input));
    assert(input);
    for (unsigned v = 0; v < total; v++) {
        writable_input(&input[v], v);
        input[v].attributes[0][0] = v + 1;
        input[v].attributes[0][3] = 1;
    }
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:input
                                     length:total * sizeof(*input)
                                    options:MTLResourceStorageModeShared];
    assert(buffer);
    NV2AMetalProgramUniforms u = uniforms();
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x7f7fffff, 0xff7fffff, 0x7f800000,
                              0xff800000, 0x7fc00123, 0x7f800123 };
    for (unsigned row = 0; row < 192; row++)
        for (unsigned k = 0; k < 4; k++) {
            uint32_t word =
                bits[(row * 4 + k) % (sizeof(bits) / sizeof(*bits))];
            memcpy(&u.constants[row][k], &word, 4);
        }
    const float seed[] = { 17, 23, 37, 41 };
    memcpy(u.constants[104], seed, sizeof(seed));
    Token tokens[7];
    writable_tokens(tokens, 104, 3, 15);
    unsigned checked = 0, faults = 0, validAperture = 0;
    for (unsigned rawMode = 0; rawMode < 2; rawMode++)
        for (unsigned access = 0; access < 2; access++) {
            NSError *error = nil;
            NV2AMetalWritableResult *result =
                [program executeTokens:tokens[0].word
                                length:7
                              uniforms:&u
                       attributeBuffer:buffer
                                 first:first
                                 count:count
                                access:access
                           writeEnable:NO
                             rasterize:!rawMode
                                 error:&error];
            require(result != nil, error);
            assert(result.vertexCount == count &&
                   result.constants.length == sizeof(u.constants));
            assert(!memcmp(result.constants.bytes, u.constants,
                           sizeof(u.constants)));
            const uint32_t *dirty = result.written.bytes;
            assert(result.written.length == 192 * 4);
            for (unsigned row = 0; row < 192; row++)
                assert(!dirty[row]);
            const NV2AMetalProgramOutput *registers = result.registers.contents;
            const NV2AMetalVertex *vertices = result.vertices.contents;
            NV2AMetalVertex empty = { 0 };
            for (unsigned v = 0; v < count; v++) {
                assert(!registers[v].fault);
                assert(!memcmp(registers[v].registers[0],
                               input[first + v].attributes[0], 16));
                assert(!memcmp(registers[v].registers[9], seed, 16));
                assert(!memcmp(registers[v].registers[10], seed, 16));
                for (unsigned k = 0; k < 4; k++) {
                    assert(registers[v].registers[11][k] ==
                           seed[k] + input[first + v].attributes[3][k]);
                    assert(registers[v].registers[12][k] == 0);
                }
                if (rawMode)
                    assert(!memcmp(&vertices[v], &empty, sizeof(empty)));
                else
                    assert(!memcmp(vertices[v].screen,
                                   input[first + v].attributes[0], 16));
                checked++;
            }
            assert(!memcmp(buffer.contents, input, total * sizeof(*input)));
        }
    Token dynamic[3] = { token(1, 0, 0), token(13, 0, 0), token(1, 0, 96) };
    source(&dynamic[0], 0, 2, 0, 0xe4);
    destination(&dynamic[0], 191, 15, 0, 0, 0, 0);
    dynamic[1].word[1] |= 1u << 9;
    source(&dynamic[1], 0, 2, 0, 0xe4);
    destination(&dynamic[1], 0, 0, 0, 0, 8, 0);
    source(&dynamic[2], 0, 3, 0, 0xe4);
    destination(&dynamic[2], 0x109, 15, 0, 0, 0, 0);
    dynamic[2].word[3] |= 3;
    const unsigned positions[] = { 0, 32, 128, 256 };
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned access = 0; access < 2; access++)
            for (unsigned location = 0; location < 4; location++) {
                for (unsigned v = 0; v < total; v++)
                    input[v].attributes[1][0] = 0;
                uint32_t nan = 0x7fc12345;
                float bad = kind == 0 ? 1000 : -1;
                if (kind == 2)
                    memcpy(&bad, &nan, 4);
                input[first + positions[location]].attributes[1][0] = bad;
                memcpy(buffer.contents, input, total * sizeof(*input));
                NSError *error = nil;
                NV2AMetalWritableResult *result =
                    [program executeTokens:dynamic[0].word
                                    length:3
                                  uniforms:&u
                           attributeBuffer:buffer
                                     first:first
                                     count:count
                                    access:access
                               writeEnable:NO
                                 rasterize:YES
                                     error:&error];
                BOOL rejected = kind != 1 || !access;
                if (rejected) {
                    if (result || !error) {
                        fprintf(stderr,
                                "Readonly later fault kind%u access%u vertex%u "
                                "was exposed\n",
                                kind, access, positions[location]);
                        abort();
                    }
                    assert([error.localizedDescription
                        isEqualToString:
                            @"Native writable-vertex address fault"]);
                    faults++;
                } else {
                    require(result != nil, error);
                    assert(!memcmp(result.constants.bytes, u.constants,
                                   sizeof(u.constants)));
                    validAperture++;
                }
                assert(!memcmp(buffer.contents, input, total * sizeof(*input)));
                error = nil;
                NV2AMetalWritableResult *retry =
                    [program executeTokens:tokens[0].word
                                    length:7
                                  uniforms:&u
                           attributeBuffer:buffer
                                     first:first
                                     count:count
                                    access:access
                               writeEnable:NO
                                 rasterize:YES
                                     error:&error];
                require(retry != nil, error);
                assert(!memcmp(retry.constants.bytes, u.constants,
                               sizeof(u.constants)));
                const NV2AMetalProgramOutput *registers =
                    retry.registers.contents;
                for (unsigned v = 0; v < count; v++)
                    assert(!registers[v].fault);
            }
    free(input);
    assert(checked == 1028 && faults == 20 && validAperture == 4);
    printf("Read-only XF: %u exact suffix/raw/context vertices, %u early/later "
           "ARL/range/USER faults, %u FULL aperture accepts and24 clean "
           "retries PASS\n",
           checked, faults, validAperture);
}
#endif
