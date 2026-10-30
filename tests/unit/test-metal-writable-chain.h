/* Serial GPU context chaining versus completed full diagnostic ranges.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_WRITABLE_CHAIN_H
#define TEST_METAL_WRITABLE_CHAIN_H
static unsigned chain_cases, chain_ranges, chain_faults, chain_stopped;
static BOOL chain_edge_bits;
static unsigned writable_chain_case(
    NV2AMetalWritableProgram *program, NV2AMetalCommands *commands,
    NV2AMetalCommands *referenceCommands, const Token tokens[4][7],
    const unsigned lengths[4], id<MTLBuffer> input, const unsigned counts[4],
    unsigned access, BOOL rasterize)
{
    NSError *error = nil;
    NSData *source = [NSData dataWithBytes:input.contents length:input.length];
    NV2AMetalProgramUniforms initial = uniforms();
    if (chain_edge_bits) {
        const uint32_t bits[] = { 0,          0x80000000, 1,
                                  0x80000001, 0x007fffff, 0x00800000,
                                  0x7f800000, 0xff800000, 0x7fc00123,
                                  0x7f800123, 0x3f800001, 0x3f7fffff };
        for (unsigned row = 0; row < 192; row++)
            for (unsigned k = 0; k < 4; k++)
                memcpy(&initial.constants[row][k], &bits[(row * 4 + k) % 12],
                       4);
    }
    NV2AMetalProgramUniforms current = initial;
    NSMutableArray<NV2AMetalWritableEncoding *> *encoded = [NSMutableArray new];
    NSMutableArray<NV2AMetalValidatedProgram *> *programs =
        [NSMutableArray new];
    require([commands beginWithError:&error] != nil, error);
    for (unsigned i = 0; i < 4; i++) {
        NV2AMetalValidatedProgram *validated =
            [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[i][0].word
                                                       length:lengths[i]
                                                        error:&error];
        require(validated != nil, error);
        [programs addObject:validated];
        NV2AMetalProgramUniforms u = initial;
        u.point_size = i + 1;
        NV2AMetalWritableEncoding *next =
            [program encodeSerialProgram:validated
                                uniforms:&u
                         attributeBuffer:input
                                   first:3 + i
                                   count:counts[i]
                                  access:access
                               rasterize:rasterize
                                previous:encoded.lastObject
                                commands:commands
                                   error:&error];
        require(next != nil, error);
        assert(![next valueForKey:@"raw"]);
        id<MTLBuffer> vertices = [next valueForKey:@"vertices"];
        assert(vertices.length ==
               (rasterize ? MAX(counts[i], 1u) * sizeof(NV2AMetalVertex) : 0));
        if (vertices)
            memset(vertices.contents, 0xa5, vertices.length);
        [encoded addObject:next];
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    BOOL stopped = NO;
    unsigned firstFault = 4;
    NV2AMetalWritableContext failed = { 0 };
    for (unsigned i = 0; i < 4; i++) {
        id<MTLBuffer> context = [encoded[i] valueForKey:@"context"];
        id<MTLBuffer> vertices = [encoded[i] valueForKey:@"vertices"];
        assert(context.length == sizeof(NV2AMetalWritableContext));
        const NV2AMetalWritableContext *actual = context.contents;
        if (stopped) {
            NV2AMetalWritableContext expected = { 0 };
            memcpy(expected.constants, failed.constants,
                   sizeof(expected.constants));
            expected.fault = failed.fault;
            assert(!memcmp(actual, &expected, sizeof(expected)));
            if (vertices)
                for (NSUInteger k = 0; k < vertices.length; k++)
                    assert(((const uint8_t *)vertices.contents)[k] == 0xa5);
            chain_stopped++;
        } else {
            current.point_size = i + 1;
            require([referenceCommands beginWithError:&error] != nil, error);
            NV2AMetalWritableEncoding *reference =
                [program encodeProgram:programs[i]
                              uniforms:&current
                       attributeBuffer:input
                                 first:3 + i
                                 count:counts[i]
                                access:access
                           writeEnable:YES
                             rasterize:rasterize
                      compactRegisters:NO
                              commands:referenceCommands
                                 error:&error];
            require(reference != nil, error);
            id<MTLBuffer> rv = [reference valueForKey:@"vertices"];
            memset(rv.contents, 0xa5, rv.length);
            require([referenceCommands submitWithError:&error], error);
            require([referenceCommands waitUntilIdleWithError:&error], error);
            id<MTLBuffer> rc = [reference valueForKey:@"context"];
            assert(!memcmp(actual, rc.contents, sizeof(*actual)));
            if (rasterize)
                assert(vertices.length == rv.length &&
                       !memcmp(vertices.contents, rv.contents, rv.length));
            memcpy(current.constants, actual->constants,
                   sizeof(current.constants));
            if (actual->fault) {
                stopped = YES;
                firstFault = i;
                failed = *actual;
                chain_faults++;
            }
        }
        NSError *resolvedError = nil;
        NV2AMetalWritableResult *result =
            [encoded[i] resolveWithError:&resolvedError];
        if (actual->fault)
            assert(!result && resolvedError);
        else {
            require(result != nil, resolvedError);
            assert(result.vertexCount == counts[i] && !result.registers &&
                   !memcmp(result.constants.bytes, actual->constants,
                           sizeof(actual->constants)) &&
                   !memcmp(result.written.bytes, actual->dirty,
                           sizeof(actual->dirty)));
        }
        chain_ranges++;
    }
    assert(!memcmp(source.bytes, input.contents, input.length));
    chain_cases++;
    return firstFault;
}
static void writable_chain_tests(NV2AMetalWritableProgram *program,
                                 NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalCommands *reference =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput values[32];
    for (unsigned i = 0; i < 32; i++)
        writable_input(&values[i], i);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    const unsigned rows[] = { 0, 58, 59, 95, 96, 191 },
                   lengths[] = { 7, 7, 7, 7 }, counts[] = { 0, 1, 3, 17 };
    for (unsigned access = 0; access < 2; access++)
        for (unsigned row = 0; row < 6; row++)
            for (unsigned mask = 0; mask < 16; mask++)
                for (unsigned raster = 0; raster < 2; raster++) {
                    Token tokens[4][7];
                    for (unsigned i = 0; i < 4; i++)
                        writable_tokens(tokens[i], rows[row], 3, mask);
                    writable_chain_case(program, commands, reference, tokens,
                                        lengths, input, counts, access, raster);
                }
    const unsigned changedRows[] = { 96, 191, 96, 58 },
                   changedCounts[] = { 1, 3, 0, 17 };
    for (unsigned raster = 0; raster < 2; raster++) {
        Token tokens[4][7];
        for (unsigned i = 0; i < 4; i++)
            writable_tokens(tokens[i], changedRows[i], 3, 1u << i);
        writable_chain_case(program, commands, reference, tokens, lengths,
                            input, changedCounts, 0, raster);
    }
    chain_edge_bits = YES;
    for (unsigned raster = 0; raster < 2; raster++) {
        Token tokens[4][7];
        for (unsigned i = 0; i < 4; i++)
            writable_tokens(tokens[i], 96, 3, 15);
        writable_chain_case(program, commands, reference, tokens, lengths,
                            input, counts, 1, raster);
    }
    chain_edge_bits = NO;
    for (unsigned i = 0; i < 32; i++)
        values[i].attributes[1][0] = 1000;
    memcpy(input.contents, values, sizeof(values));
    /* A different range owns each first fault; later ranges must not execute.
     */
    for (unsigned bad = 0; bad < 4; bad++)
        for (unsigned access = 0; access < 2; access++)
            for (unsigned raster = 0; raster < 2; raster++) {
                Token tokens[4][7];
                for (unsigned i = 0; i < 4; i++)
                    writable_tokens(tokens[i], i == bad && !access ? 0 : 96, 3,
                                    15);
                if (access) {
                    tokens[bad][5] = token(13, 0, 96);
                    tokens[bad][5].word[1] |= 1u << 9;
                    source(&tokens[bad][5], 0, 2, 0, 0xe4);
                    destination(&tokens[bad][5], 0, 0, 0, 0, 8, 0);
                    tokens[bad][6] = token(1, 0, 96);
                    source(&tokens[bad][6], 0, 3, 0, 0xe4);
                    destination(&tokens[bad][6], 0x10c, 15, 0, 0, 0, 0);
                    tokens[bad][6].word[3] |= 3;
                }
                const unsigned active[] = { 1, 3, 17, 1 };
                unsigned firstFault =
                    writable_chain_case(program, commands, reference, tokens,
                                        lengths, input, active, access, raster);
                if (firstFault != bad) {
                    fprintf(stderr,
                            "Expected first fault range%u actual%u access%u "
                            "raster%u\n",
                            bad, firstFault, access, raster);
                    abort();
                }
            }
    /* Same MTL command buffer is reused after cancel; its old context is
     * invalid. */
    Token tokens[7];
    writable_tokens(tokens, 96, 3, 15);
    NV2AMetalValidatedProgram *validated =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:7
                                                    error:&error];
    require(validated != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *previous = [program encodeSerialProgram:validated
                                                              uniforms:&u
                                                       attributeBuffer:input
                                                                 first:3
                                                                 count:1
                                                                access:0
                                                             rasterize:YES
                                                              previous:nil
                                                              commands:commands
                                                                 error:&error];
    require(previous != nil, error);
    uint64_t serial = commands.recordingSerial;
    require([reference beginWithError:&error] != nil, error);
    error = nil;
    assert(![program encodeSerialProgram:validated
                                uniforms:&u
                         attributeBuffer:input
                                   first:3
                                   count:1
                                  access:0
                               rasterize:YES
                                previous:previous
                                commands:reference
                                   error:&error] &&
           error);
    [reference cancel];
    [commands cancel];
    require([commands beginWithError:&error] != nil, error);
    assert(commands.recordingSerial > serial);
    error = nil;
    assert(![program encodeSerialProgram:validated
                                uniforms:&u
                         attributeBuffer:input
                                   first:3
                                   count:1
                                  access:0
                               rasterize:YES
                                previous:previous
                                commands:commands
                                   error:&error] &&
           error);
    [commands cancel];
    require([commands beginWithError:&error] != nil, error);
    previous = [program encodeSerialProgram:validated
                                   uniforms:&u
                            attributeBuffer:input
                                      first:3
                                      count:1
                                     access:0
                                  rasterize:YES
                                   previous:nil
                                   commands:commands
                                      error:&error];
    require(previous != nil, error);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    require([commands beginWithError:&error] != nil, error);
    error = nil;
    assert(![program encodeSerialProgram:validated
                                uniforms:&u
                         attributeBuffer:input
                                   first:3
                                   count:1
                                  access:0
                               rasterize:YES
                                previous:previous
                                commands:commands
                                   error:&error] &&
           error);
    previous = [program encodeProgram:validated
                             uniforms:&u
                      attributeBuffer:input
                                first:3
                                count:1
                               access:0
                          writeEnable:NO
                            rasterize:YES
                     compactRegisters:YES
                             commands:commands
                                error:&error];
    require(previous != nil, error);
    error = nil;
    assert(![program encodeSerialProgram:validated
                                uniforms:&u
                         attributeBuffer:input
                                   first:3
                                   count:1
                                  access:0
                               rasterize:YES
                                previous:previous
                                commands:commands
                                   error:&error] &&
           error);
    [commands cancel];
    [reference setValue:@(UINT64_MAX) forKey:@"recordingSerial"];
    error = nil;
    assert(![reference beginWithError:&error] && error &&
           !reference.commandBuffer);
    printf("Serial writable chain:%u four-range cases/%u exact contexts,%u "
           "first faults/%u skipped fault suffixes;full diagnostic sequential "
           "GPU reference,per-range masks/empty/raw/raster/USER/FULL,unchanged "
           "inputs,cancel/submitted/readonly/foreign-owner/serial-overflow "
           "guards PASS\n",
           chain_cases, chain_ranges, chain_faults, chain_stopped);
    fflush(stdout);
}
#endif
