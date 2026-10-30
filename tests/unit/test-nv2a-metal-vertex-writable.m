/* Native serial XFCTX feedback and prewrite experiment, no app or window. */
#import "hw/xbox/nv2a/pgraph/metal/vertex-writable.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
/* Exact finite integer feedback cases, independently CPU-API checked. */
#include <stdint.h>
#include <string.h>
#include "hw/xbox/nv2a/pgraph/metal/vertex-program-types.h"
#include "test-metal-vertex-context.h"
static void writable_tokens(Token tokens[7], unsigned row, unsigned attribute,
                            unsigned mask)
{
    for (unsigned i = 0; i < 7; i++)
        tokens[i] = token(1, 0, row);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    source(&tokens[1], 0, 3, 0, 0xe4);
    destination(&tokens[1], 0x109, 15, 0, 0, 0, 0);
    tokens[2] = token(3, 0, row);
    tokens[2].word[1] |= attribute << 9;
    source(&tokens[2], 0, 2, 0, 0xe4);
    source(&tokens[2], 2, 3, 0, 0xe4);
    destination(&tokens[2], row, mask, 0, 2, 15, 0);
    source(&tokens[3], 0, 3, 0, 0xe4);
    destination(&tokens[3], 0x10a, 15, 0, 0, 0, 0);
    source(&tokens[4], 0, 1, 2, 0xe4);
    destination(&tokens[4], 0x10b, 15, 0, 0, 0, 0);
    source(&tokens[5], 0, 1, 11, 0xe4);
    destination(&tokens[5], 0x10c, 15, 0, 0, 0, 0);
    source(&tokens[6], 0, 2, 0, 0xe4);
    destination(&tokens[6], 0, 0, 0, 11, 15, 0);
    tokens[6].word[3] |= 1;
}
static void writable_constants(float constants[192][4])
{
    for (unsigned row = 0; row < 192; row++)
        for (unsigned k = 0; k < 4; k++)
            constants[row][k] = (float)(row + k + 1);
}
static void writable_input(NV2AMetalProgramInput *input, unsigned vertex)
{
    for (unsigned a = 0; a < 16; a++)
        for (unsigned k = 0; k < 4; k++)
            input->attributes[a][k] = (float)(1 + vertex % 3 + k + a % 4);
}
static int writable_allowed(unsigned access, unsigned row)
{
    return access || row >= 96 || row == 58 || row == 59;
}

#include "test-metal-vertex-alias.h"
static unsigned accepted, rejected, vertices, aliases;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Writable native test: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static NV2AMetalProgramUniforms uniforms(void)
{
    NV2AMetalProgramUniforms u = { 0 };
    writable_constants(u.constants);
    u.surface_size[0] = u.surface_size[1] = 4;
    u.zmax = 16;
    u.point_size = u.point_scale = 1;
    return u;
}
static void check_feedback(NV2AMetalWritableProgram *program, unsigned row,
                           unsigned attribute, unsigned mask, unsigned count,
                           unsigned enabled, unsigned access)
{
    Token tokens[7];
    writable_tokens(tokens, row, attribute, mask);
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalProgramInput input[128];
    for (unsigned v = 0; v < count; v++)
        writable_input(&input[v], v);
    NSError *error = nil;
    NV2AMetalWritableResult *result =
        [program executeTokens:tokens[0].word
                        length:7
                      uniforms:&u
                    attributes:[NSData dataWithBytes:input
                                              length:count * sizeof(input[0])]
                         count:count
                        access:access
                   writeEnable:enabled
                         error:&error];
    if (count && !writable_allowed(access, row)) {
        assert(!result && error);
        rejected++;
        return;
    }
    if (!result)
        fprintf(
            stderr,
            "Failure feedback row%u attr%u mask%x count%u enabled%u access%u\n",
            row, attribute, mask, count, enabled, access);
    require(result != nil, error);
    assert(result.vertexCount == count);
    const NV2AMetalProgramOutput *raw = result.registers.contents;
    float expected[192][4];
    memcpy(expected, u.constants, sizeof(expected));
    for (unsigned v = 0; v < count; v++) {
        assert(!raw[v].fault);
        float before[4];
        memcpy(before, expected[row], sizeof(before));
        for (unsigned k = 0; k < 4; k++) {
            float sum = before[k] + input[v].attributes[attribute][k];
            if (enabled && (mask & (8u >> k)))
                expected[row][k] = sum;
            if (raw[v].registers[9][k] != before[k] ||
                raw[v].registers[10][k] != expected[row][k] ||
                raw[v].registers[11][k] != sum ||
                raw[v].registers[12][k] != 0 ||
                raw[v].registers[0][k] != input[v].attributes[0][k]) {
                fprintf(stderr,
                        "Writable feedback row%u attr%u mask%x count%u "
                        "enabled%u access%u vertex%u/%u\n",
                        row, attribute, mask, count, enabled, access, v, k);
                abort();
            }
        }
        vertices++;
    }
    if (memcmp(result.constants.bytes, expected, sizeof(expected))) {
        fprintf(
            stderr,
            "Writable final context row%u mask%x count%u enabled%u access%u\n",
            row, mask, count, enabled, access);
        abort();
    }
    const uint32_t *dirty = result.written.bytes;
    for (unsigned k = 0; k < 192; k++)
        assert(dirty[k] == (unsigned)(k == row && count && enabled && mask));
    accepted++;
}
static void check_alias(NV2AMetalWritableProgram *program, AliasCase fixture)
{
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalProgramInput input = { 0 };
    for (unsigned k = 0; k < 4; k++) {
        input.attributes[0][k] = (float)k + 1;
        input.attributes[1][k] = (float)k + 5;
    }
    NSError *error = nil;
    NV2AMetalWritableResult *result = [program
        executeTokens:fixture.tokens[0].word
               length:5
             uniforms:&u
           attributes:[NSData dataWithBytes:&input length:sizeof(input)]
                count:1
               access:1
          writeEnable:YES
                error:&error];
    require(result != nil, error);
    const NV2AMetalProgramOutput *raw = result.registers.contents;
    assert(!raw->fault);
    const unsigned rows[] = { 0, 9, 10, 11 };
    for (unsigned row = 0; row < 4; row++) {
        if (memcmp(raw->registers[rows[row]], fixture.expected[row], 16)) {
            fprintf(stderr,
                    "Writable R12 family%u MAC%u ILU%u swz%02x mux%u mask%x "
                    "temp%x row%u\n",
                    fixture.family, fixture.mac, fixture.ilu, fixture.swizzle,
                    fixture.output_mux, fixture.output_mask, fixture.temp_mask,
                    rows[row]);
            abort();
        }
    }
    assert(!memcmp(result.constants.bytes, u.constants, sizeof(u.constants)));
    const uint32_t *dirty = result.written.bytes;
    for (unsigned row = 0; row < 192; row++)
        assert(!dirty[row]);
    aliases++;
}
static void suffixes(NV2AMetalWritableProgram *program,
                     NV2AMetalCommands *commands)
{
    NV2AMetalProgramInput input[32];
    for (unsigned v = 0; v < 32; v++)
        for (unsigned a = 0; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                input[v].attributes[a][k] = (float)(v * 16 + a * 4 + k + 1);
    id<MTLBuffer> upload =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> gpu =
        [commands.device newBufferWithLength:sizeof(input)
                                     options:MTLResourceStorageModePrivate];
    NSError *error = nil;
    require(upload && gpu, error);
    require([commands beginWithError:&error], error);
    require([commands addResource:upload error:&error], error);
    require([commands addResource:gpu error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    require(encoder != nil, error);
    [encoder copyFromBuffer:upload
               sourceOffset:0
                   toBuffer:gpu
          destinationOffset:0
                       size:sizeof(input)];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    unsigned cases = 0, raw_vertices = 0;
    const unsigned masks[] = { 0, 1, 8, 15 };
    for (unsigned first = 0; first <= 32; first++)
        for (unsigned count = 0; count <= 32 - first; count++)
            for (unsigned m = 0; m < 4; m++)
                for (unsigned enabled = 0; enabled < 2; enabled++) {
                    @autoreleasepool {
                        Token tokens[7];
                        writable_tokens(tokens, 96, 3, masks[m]);
                        NV2AMetalProgramUniforms u = uniforms();
                        error = nil;
                        NV2AMetalWritableResult *r =
                            [program executeTokens:tokens[0].word
                                            length:7
                                          uniforms:&u
                                   attributeBuffer:gpu
                                             first:first
                                             count:count
                                            access:1
                                       writeEnable:enabled
                                             error:&error];
                        require(r != nil, error);
                        assert(r.vertexCount == count);
                        const NV2AMetalProgramOutput *raw =
                            r.registers.contents;
                        float context[192][4];
                        memcpy(context, u.constants, sizeof(context));
                        for (unsigned v = 0; v < count; v++) {
                            assert(!raw[v].fault);
                            for (unsigned k = 0; k < 4; k++) {
                                float before = context[96][k],
                                      sum = before +
                                            input[first + v].attributes[3][k];
                                if (enabled && (masks[m] & (8u >> k)))
                                    context[96][k] = sum;
                                assert(raw[v].registers[9][k] == before &&
                                       raw[v].registers[10][k] ==
                                           context[96][k]);
                                assert(raw[v].registers[11][k] == sum &&
                                       raw[v].registers[12][k] == 0 &&
                                       raw[v].registers[0][k] ==
                                           input[first + v].attributes[0][k]);
                            }
                            raw_vertices++;
                        }
                        assert(!memcmp(r.constants.bytes, context,
                                       sizeof(context)));
                        const uint32_t *dirty = r.written.bytes;
                        for (unsigned row = 0; row < 192; row++)
                            assert(dirty[row] ==
                                   (unsigned)(row == 96 && count && enabled &&
                                              masks[m]));
                        cases++;
                    }
                }
    Token tokens[7];
    writable_tokens(tokens, 96, 3, 15);
    NV2AMetalProgramUniforms u = uniforms();
    const NSUInteger bad[][2] = {
        { 33, 0 }, { 32, 1 }, { NSUIntegerMax, 0 }, { 0, NSUIntegerMax }
    };
    for (unsigned i = 0; i < 4; i++) {
        error = nil;
        assert(![program executeTokens:tokens[0].word
                                length:7
                              uniforms:&u
                       attributeBuffer:gpu
                                 first:bad[i][0]
                                 count:bad[i][1]
                                access:1
                           writeEnable:YES
                                 error:&error] &&
               error);
    }
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:sizeof(input)
                                     options:MTLResourceStorageModeShared];
    require(readback != nil, error);
    require([commands beginWithError:&error], error);
    require([commands addResource:gpu error:&error], error);
    require([commands addResource:readback error:&error], error);
    encoder = [commands.commandBuffer computeCommandEncoder];
    require(encoder != nil, error);
    [encoder copyFromBuffer:gpu
               sourceOffset:0
                   toBuffer:readback
          destinationOffset:0
                       size:sizeof(input)];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    assert(!memcmp(readback.contents, input, sizeof(input)));
    assert(cases == 4488 && raw_vertices == 47872);
    printf("Writable GPU-buffer suffixes: %u spans/%u transformed vertices, 4 "
           "invalid ranges, private source buffer unchanged PASS\n",
           cases, raw_vertices);
}

#include "test-metal-readonly.h"

#include "test-metal-program-cache.h"
#include "test-metal-program-lru.h"
#include "test-metal-readonly-constants.h"
#include "test-metal-specialized-readonly.h"
#include "test-metal-compact-writable.h"
#include "test-metal-writable-chain.h"
#include "test-metal-nonwriting-program.h"
#include "test-metal-fault-free-readonly.h"
#include "test-metal-zero-idx-proof.h"
#include "test-metal-integer-idx-proof.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalWritableProgram *program =
            [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                       error:&error];
        require(program != nil, error);
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--constant-idx-proof")))
            constant_idx_proof_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--constant-idx-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--integer-idx-proof")))
            integer_idx_proof_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--integer-idx-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--bounded-idx-proof")))
            bounded_idx_proof_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--bounded-idx-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--zero-idx-proof")))
            zero_idx_proof_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--zero-idx-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--fault-free-readonly")))
            fault_free_readonly_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--fault-free-readonly"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--nonwriting-program")))
            nonwriting_program_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--nonwriting-program"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--writable-chain")))
            writable_chain_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--writable-chain"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--compact-writable")))
            compact_writable_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--compact-writable"))
            return 0;
        if (argc == 2 && !strcmp(argv[1], "--readonly-constants")) {
            readonly_constant_tests(program, commands);
            return 0;
        }
        specialized_readonly_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--specialized-readonly"))
            return 0;
        program_cache_tests(commands);
        program_lru_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--program-cache"))
            return 0;
        assert(argc == 1);
        const unsigned counts[] = { 0, 1, 2, 3, 7, 16, 32, 65, 128 };
        const unsigned rows[] = { 0, 58, 59, 95, 96, 191 };
        for (unsigned n = 0; n < 9; n++)
            for (unsigned r = 0; r < 6; r++)
                for (unsigned access = 0; access < 2; access++)
                    for (unsigned enabled = 0; enabled < 2; enabled++)
                        for (unsigned mask = 0; mask < 16; mask++)
                            @autoreleasepool {
                                check_feedback(program, rows[r], 3, mask,
                                               counts[n], enabled, access);
                            }
        for (unsigned attribute = 0; attribute < 16; attribute++)
            for (unsigned enabled = 0; enabled < 2; enabled++)
                @autoreleasepool {
                    check_feedback(program, 96, attribute, 15, 17, enabled, 1);
                }
        assert(accepted == 2976 && rejected == 512 && vertices == 81824);
        const unsigned swizzles[] = { 0xe4, 0x1b, 0x00, 0xff };
        for (unsigned sw = 0; sw < 4; sw++) {
            for (unsigned mask = 0; mask < 16; mask++) {
                for (unsigned temp = 0; temp < 16; temp++) {
                    @autoreleasepool {
                        check_alias(program, alias_case(0, 3, swizzles[sw], 0,
                                                        mask, temp));
                        check_alias(program, alias_case(0, 4, swizzles[sw], 0,
                                                        mask, temp));
                        check_alias(program, alias_case(2, 0, swizzles[sw], 1,
                                                        mask, temp));
                    }
                }
                const unsigned paired[] = { 1, 3, 4 };
                for (unsigned m = 0; m < 3; m++)
                    for (unsigned mux = 0; mux < 2; mux++)
                        for (unsigned ilu = 1; ilu <= 7; ilu++)
                            @autoreleasepool {
                                check_alias(program,
                                            alias_ilu(alias_case(1, paired[m],
                                                                 swizzles[sw],
                                                                 mux, mask, 15),
                                                      ilu));
                            }
            }
        }
        assert(aliases == 5760);
        Token blocked[2] = { token(1, 0, 0), token(1, 0, 0) };
        source(&blocked[0], 0, 2, 0, 0xe4);
        destination(&blocked[0], 0, 15, 0, 0, 0, 0);
        source(&blocked[1], 0, 2, 0, 0xe4);
        destination(&blocked[1], 0x100, 15, 0, 0, 0, 0);
        blocked[1].word[3] |= 1;
        NV2AMetalProgramInput input;
        writable_input(&input, 0);
        NSData *attributes = [NSData dataWithBytes:&input length:sizeof(input)];
        NV2AMetalProgramUniforms u = uniforms();
        error = nil;
        NV2AMetalWritableResult *disabled =
            [program executeTokens:blocked[0].word
                            length:2
                          uniforms:&u
                        attributes:attributes
                             count:1
                            access:0
                       writeEnable:NO
                             error:&error];
        require(disabled != nil, error);
        assert(!memcmp(disabled.constants.bytes, u.constants,
                       sizeof(u.constants)));
        error = nil;
        assert(![program executeTokens:blocked[0].word
                                length:2
                              uniforms:&u
                            attributes:attributes
                                 count:1
                                access:0
                           writeEnable:YES
                                 error:&error] &&
               error);
        Token fault[3] = { token(1, 0, 0), token(13, 0, 0), token(1, 0, 96) };
        source(&fault[0], 0, 2, 0, 0xe4);
        destination(&fault[0], 191, 15, 0, 0, 0, 0);
        fault[1].word[1] |= 1u << 9;
        source(&fault[1], 0, 2, 0, 0xe4);
        destination(&fault[1], 0, 0, 0, 0, 8, 0);
        source(&fault[2], 0, 3, 0, 0xe4);
        destination(&fault[2], 0x109, 15, 0, 0, 0, 0);
        fault[2].word[3] |= 3;
        NV2AMetalProgramInput faultInput[3];
        for (unsigned v = 0; v < 3; v++) {
            writable_input(&faultInput[v], v);
            faultInput[v].attributes[1][0] = v == 2 ? 1000 : 0;
        }
        error = nil;
        assert(![program executeTokens:fault[0].word
                                length:3
                              uniforms:&u
                            attributes:[NSData dataWithBytes:faultInput
                                                      length:sizeof(faultInput)]
                                 count:3
                                access:1
                           writeEnable:YES
                                 error:&error] &&
               error);
        check_feedback(program, 96, 3, 15, 2, 1, 1);
        suffixes(program, commands);
        readonly_contract(program, commands);
        readonly_constant_tests(program, commands);
        printf("Native writable vertex programs: 2976 feedback cases/81824 "
               "transformed vertices, 512 aperture rejections, %u R12 cases "
               "PASS\n",
               aliases);
        puts("Write-disabled forbidden destination, later-vertex fault "
             "rejection and valid retry PASS; PGRAPH integration remains "
             "separate");
    }
    return 0;
}
