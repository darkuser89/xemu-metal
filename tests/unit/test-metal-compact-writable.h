/* Serial Writable XF: full diagnostics versus draw-only output.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_WRITABLE_H
#define TEST_METAL_COMPACT_WRITABLE_H
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-types.h"
static unsigned compact_writable_pairs, compact_writable_faults;
static void compact_writable_pair(NV2AMetalWritableProgram *program,
                                  NV2AMetalCommands *commands,
                                  const Token *tokens, NSUInteger length,
                                  const NV2AMetalProgramUniforms *u,
                                  id<MTLBuffer> input, NSUInteger first,
                                  NSUInteger count, unsigned access,
                                  BOOL rasterize, unsigned expectedFault)
{
    NSError *error = nil;
    NSData *original = [NSData dataWithBytes:input.contents
                                      length:input.length];
    NV2AMetalValidatedProgram *validated =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:length
                                                    error:&error];
    require(validated != nil, error);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *encodings[2];
    id<MTLBuffer> contexts[2], vertices[2];
    for (unsigned compact = 0; compact < 2; compact++) {
        encodings[compact] = [program encodeProgram:validated
                                           uniforms:u
                                    attributeBuffer:input
                                              first:first
                                              count:count
                                             access:access
                                        writeEnable:YES
                                          rasterize:rasterize
                                   compactRegisters:compact
                                           commands:commands
                                              error:&error];
        require(encodings[compact] != nil, error);
        id<MTLBuffer> raw = [encodings[compact] valueForKey:@"raw"];
        contexts[compact] = [encodings[compact] valueForKey:@"context"];
        vertices[compact] = [encodings[compact] valueForKey:@"vertices"];
        assert(contexts[compact].length == sizeof(NV2AMetalWritableContext));
        assert(vertices[compact].length ==
               (compact && !rasterize ?
                    0 :
                    MAX(count, 1u) * sizeof(NV2AMetalVertex)));
        if (compact)
            assert(!raw);
        else
            assert(raw.length ==
                   MAX(count, 1u) * sizeof(NV2AMetalProgramOutput));
        if (vertices[compact])
            memset(vertices[compact].contents, 0xa5, vertices[compact].length);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    assert(!memcmp(input.contents, original.bytes, input.length));
    assert(!memcmp(contexts[0].contents, contexts[1].contents,
                   sizeof(NV2AMetalWritableContext)));
    if (rasterize)
        assert(!memcmp(vertices[0].contents, vertices[1].contents,
                       vertices[0].length));
    else
        assert(!vertices[1]);
    const NV2AMetalWritableContext *context = contexts[0].contents;
    if (expectedFault != UINT_MAX)
        assert(context->fault == expectedFault);
    NSError *errors[2] = { nil, nil };
    NV2AMetalWritableResult *results[2];
    for (unsigned compact = 0; compact < 2; compact++) {
        NSError *resolveError = nil;
        results[compact] = [encodings[compact] resolveWithError:&resolveError];
        errors[compact] = resolveError;
    }
    if (context->fault) {
        assert(!results[0] && !results[1] && errors[0] && errors[1] &&
               [errors[0].localizedDescription
                   isEqual:errors[1].localizedDescription]);
        compact_writable_faults++;
    } else {
        require(results[0] && results[1], errors[1]);
        assert(results[0].registers && !results[1].registers &&
               results[0].vertexCount == count &&
               results[1].vertexCount == count &&
               [results[0].constants isEqualToData:results[1].constants] &&
               [results[0].written isEqualToData:results[1].written]);
    }
    compact_writable_pairs++;
}
static void compact_writable_tests(NV2AMetalWritableProgram *program,
                                   NV2AMetalCommands *commands)
{
    const NSUInteger first = 3, total = 270;
    NV2AMetalProgramInput inputValues[270];
    for (unsigned v = 0; v < total; v++)
        writable_input(&inputValues[v], v);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:inputValues
                                     length:sizeof(inputValues)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    NV2AMetalProgramUniforms u = uniforms();
    const unsigned counts[] = { 0, 1, 3, 17, 257 };
    const unsigned rows[] = { 0, 58, 59, 95, 96, 191 };
    for (unsigned access = 0; access < 2; access++)
        for (unsigned row = 0; row < 6; row++)
            for (unsigned mask = 0; mask < 16; mask++)
                for (unsigned n = 0; n < 5; n++)
                    for (unsigned rasterize = 0; rasterize < 2; rasterize++) {
                        Token tokens[7];
                        writable_tokens(tokens, rows[row], 3, mask);
                        compact_writable_pair(
                            program, commands, tokens, 7, &u, input, first,
                            counts[n], access, rasterize,
                            counts[n] && !writable_allowed(access, rows[row]) ?
                                NV2AMetalProgramFaultConstantRange :
                                0);
                    }
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x00800000, 0x3f800001, 0x3f7fffff,
                              0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
                              0x7fc00123, 0x7f800123, 0x3f000000, 0xbf800000 };
    for (unsigned v = 0; v < total; v++)
        for (unsigned a = 1; a < 16; a++)
            for (unsigned k = 0; k < 4; k++) {
                uint32_t word = bits[(v + a * 3 + k) % 16];
                memcpy(&inputValues[v].attributes[a][k], &word, 4);
            }
    memcpy(input.contents, inputValues, sizeof(inputValues));
    for (unsigned mac = 0; mac <= 13; mac++)
        for (unsigned ilu = 0; ilu <= 7; ilu++) {
            Token tokens[6];
            specialized_op_tokens(tokens, mac, ilu, 15,
                                  ((mac + ilu) & 1) ? 1 : 12,
                                  (mac & 1) ? 0x1b : 0xe4);
            unsigned mux = ilu && ((mac + ilu) & 1);
            destination(&tokens[3], 96, mac == 13 && !mux ? 0 : 15, mux,
                        ((mac + ilu) & 1) ? 1 : 12, 15, 15);
            for (unsigned access = 0; access < 2; access++)
                for (unsigned rasterize = 0; rasterize < 2; rasterize++)
                    compact_writable_pair(program, commands, tokens, 6, &u,
                                          input, first, 64, access, rasterize,
                                          UINT_MAX);
        }
    Token dynamic[4] = { token(1, 0, 96), token(1, 0, 96), token(13, 0, 96),
                         token(1, 0, 96) };
    source(&dynamic[0], 0, 2, 0, 0xe4);
    destination(&dynamic[0], 0x100, 15, 0, 0, 0, 0);
    dynamic[1].word[1] |= 3u << 9;
    source(&dynamic[1], 0, 2, 0, 0xe4);
    destination(&dynamic[1], 191, 15, 0, 0, 0, 0);
    dynamic[2].word[1] |= 1u << 9;
    source(&dynamic[2], 0, 2, 0, 0xe4);
    destination(&dynamic[2], 0, 0, 0, 0, 8, 0);
    source(&dynamic[3], 0, 3, 0, 0xe4);
    destination(&dynamic[3], 0x103, 15, 0, 0, 0, 0);
    dynamic[3].word[3] |= 3;
    const unsigned locations[] = { 0, 1, 32, 256 };
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned access = 0; access < 2; access++)
            for (unsigned n = 0; n < 4; n++)
                for (unsigned rasterize = 0; rasterize < 2; rasterize++) {
                    for (unsigned v = 0; v < total; v++) {
                        writable_input(&inputValues[v], v);
                        inputValues[v].attributes[1][0] = 0;
                    }
                    float bad = kind == 0 ? 1000 : -200;
                    if (kind == 2) {
                        uint32_t nan = 0x7fc12345;
                        memcpy(&bad, &nan, 4);
                    }
                    inputValues[first + locations[n]].attributes[1][0] = bad;
                    memcpy(input.contents, inputValues, sizeof(inputValues));
                    compact_writable_pair(
                        program, commands, dynamic, 4, &u, input, first, 257,
                        access, rasterize,
                        kind == 2 ? NV2AMetalProgramFaultAddressRange :
                                    NV2AMetalProgramFaultConstantRange);
                }
    assert(compact_writable_pairs == 2416);
    printf(
        "Compact Writable XF:%u exact full/compact pairs,%u fault pairs;"
        "empty/suffix/USER/FULL/all masks,14MACx8ILU,NaN/Inf/denormals,"
        "first/middle/last relative faults,complete context/dirty/first-fault,"
        "unchanged inputs and sentinel vertices;zero raw-buffer bytes PASS\n",
        compact_writable_pairs, compact_writable_faults);
}
#endif
