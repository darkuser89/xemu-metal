/* Native serial XFCTX feedback and prewrite experiment, no app or window. */
#import "hw/xbox/nv2a/pgraph/metal/vertex-writable.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
/* Exact finite integer feedback cases, independently CPU-API checked. */
#include <stdint.h>
#include <string.h>
#include <time.h>
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
#include "test-metal-proof-lanes.h"
#include "test-metal-large-scale-proof.h"
#include "test-metal-large-union-proof.h"
#include "test-metal-large-reciprocal-proof.h"

static void proof_cache_tokens(Token t[2], BOOL attribute)
{
    t[0] = token(NV2AMetalMACArl, 0, 100);
    source(&t[0], 0, attribute ? 2 : 3, 0, 0);
    destination(&t[0], 0, 0, 0, 0, 0, 0);
    t[1] = token(NV2AMetalMACMov, 0, 96);
    source(&t[1], 0, 3, 0, 0xe4);
    destination(&t[1], 0x103, 15, 0, 0, 0, 0);
    t[1].word[3] |= 3;
}
static void readonly_proof_cache_tests(void)
{
    NSError *error = nil;
    Token t[2];
    proof_cache_tokens(t, NO);
    NV2AMetalValidatedProgram *constant = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:t[0].word length:2 error:&error];
    require(constant != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    for (int offset = -256; offset <= 256; offset++) {
        u.constants[100][0] = offset;
        int row = 96 + offset;
        NV2AMetalValidatedProgram *fresh = [[NV2AMetalValidatedProgram alloc]
            initWithTokens:t[0].word length:2 error:&error];
        require(fresh != nil, error);
        for (unsigned access = 0; access < 2; access++) {
            BOOL expected = row >= 0 && row < 192 && (access || row >= 96);
            for (unsigned repeat = 0; repeat < 4; repeat++) {
                assert([constant hasFaultFreeReadOnlyAccess:access
                    constants:u.constants[0]] == expected);
                assert([fresh hasFaultFreeReadOnlyAccess:access
                    constants:u.constants[0]] == expected);
            }
        }
    }
    NSData *constantKey = [constant valueForKey:@"constantProofInputs"];
    assert(![constant hasFaultFreeReadOnlyAccess:2 constants:u.constants[0]] &&
           ![constant hasFaultFreeReadOnlyAccess:1 constants:NULL] &&
           [constant valueForKey:@"constantProofInputs"] == constantKey);
    proof_cache_tokens(t, YES);
    NV2AMetalValidatedProgram *attribute = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:t[0].word length:2 error:&error];
    require(attribute != nil, error);
    const unsigned formats[] = {
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP
    };
    for (unsigned kind = 0; kind < 4; kind++)
        for (unsigned fallback = 0; fallback < 2; fallback++) {
            NV2AMetalFetchUniforms fetch = { 0 };
            fetch.attributes[0].count = 4;
            fetch.attributes[0].format = formats[kind];
            fetch.attributes[0].stride = 4;
            fetch.attributes[0].inline_value[0] = 128;
            fetch.index_size = fallback ? 4 : 0;
            fetch.first_vertex = fallback;
            NV2AMetalValidatedProgram *fresh = [[NV2AMetalValidatedProgram alloc]
                initWithTokens:t[0].word length:2 error:&error];
            require(fresh != nil, error);
            for (unsigned access = 0; access < 2; access++) {
                BOOL expected = !fallback && kind != 2 && (access || kind == 0);
                for (unsigned repeat = 0; repeat < 4; repeat++) {
                    assert([attribute hasFaultFreeReadOnlyAccess:access
                        constants:u.constants[0] sourceUniforms:&fetch] == expected);
                    assert([fresh hasFaultFreeReadOnlyAccess:access
                        constants:u.constants[0] sourceUniforms:&fetch] == expected);
                }
            }
            NSData *key = [attribute valueForKey:@"fetchProofInputs"];
            fetch.vertex_count = 100;
            fetch.attributes[0].max_index = 4096;
            fetch.attributes[15].inline_value[0] = -256;
            (void)[attribute hasFaultFreeReadOnlyAccess:1
                constants:u.constants[0] sourceUniforms:&fetch];
            assert([attribute valueForKey:@"fetchProofInputs"] == key);
            assert(![attribute hasFaultFreeReadOnlyAccess:1
                constants:u.constants[0]]);
            assert([attribute valueForKey:@"fetchProofInputs"] == key);
        }
    dispatch_apply(256, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
        ^(size_t i) {
          @autoreleasepool {
              NV2AMetalProgramUniforms context = uniforms();
              context.constants[100][0] = (int)(i % 192) - 96;
              unsigned access = (unsigned)i & 1;
              BOOL expected = access || i % 192 >= 96;
              assert([constant hasFaultFreeReadOnlyAccess:access
                  constants:context.constants[0]] == expected);
              NV2AMetalFetchUniforms fetch = { 0 };
              fetch.attributes[0].inline_value[0] = context.constants[100][0];
              assert([attribute hasFaultFreeReadOnlyAccess:access
                  constants:context.constants[0] sourceUniforms:&fetch] == expected);
          }
        });
    puts("Readonly proof cache: 513 constant epochs, both access policies, "
         "four formats, indexed overflow fallback, independent constant/source "
         "keys, irrelevant metadata reuse and 256 concurrent epochs PASS "
         "(CPU only)");
}
static void reciprocal_proof_cache_tests(void)
{
    NSError *error = nil;
    Token t[] = { token(0, NV2AMetalILURcp, 96),
                  token(NV2AMetalMACArl, 0, 96),
                  token(NV2AMetalMACMov, 0, 187) };
    t[0].word[1] |= 1u << 9;
    source(&t[0], 2, 2, 0, 0);
    destination(&t[0], 0, 0, 0, 2, 0, 15);
    source(&t[1], 0, 1, 2, 0);
    source(&t[2], 0, 3, 0, 0xe4);
    destination(&t[2], 0x103, 15, 0, 0, 0, 0);
    t[2].word[3] |= 3;
    NV2AMetalValidatedProgram *attribute = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:t[0].word length:3 error:&error];
    require(attribute != nil, error);
    const float values[] = { .5f, .25f, .125f, 0, NAN, -.5f };
    const BOOL expected[] = { YES, YES, NO, NO, NO, YES };
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalFetchUniforms fetch = { 0 };
    for (unsigned repeat = 0; repeat < 4; repeat++)
        for (unsigned i = 0; i < sizeof(values) / sizeof(*values); i++) {
            fetch.attributes[1].inline_value[0] = values[i];
            assert([attribute hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]
                sourceUniforms:&fetch] == expected[i]);
        }
    fetch.attributes[1].inline_value[0] = .5f;
    assert([attribute hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]
        sourceUniforms:&fetch]);
    NSData *key = [attribute valueForKey:@"fetchProofInputs"];
    fetch.attributes[1].inline_value[0] = .75f;
    assert([attribute hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]
        sourceUniforms:&fetch] && [attribute valueForKey:@"fetchProofInputs"] != key);
    key = [attribute valueForKey:@"fetchProofInputs"];
    assert([attribute hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]
        sourceUniforms:&fetch] && [attribute valueForKey:@"fetchProofInputs"] == key);
    fetch.attributes[1].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    fetch.attributes[1].count = 1;
    assert(![attribute hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]
        sourceUniforms:&fetch]);

    /* SLT selects rows 100/101. The reciprocal must enclose both values,
     * and must lose its magnitude lower bound if either row can be zero. */
    Token unionTokens[] = { token(NV2AMetalMACSlt, 0, 96),
                            token(NV2AMetalMACArl, 0, 96),
                            token(NV2AMetalMACMov, 0, 100),
                            token(0, NV2AMetalILURcp, 96),
                            t[1], t[2] };
    source(&unionTokens[0], 0, 2, 0, 0);
    source(&unionTokens[0], 1, 1, 0, 0);
    destination(&unionTokens[0], 0, 0, 0, 3, 15, 0);
    source(&unionTokens[1], 0, 1, 3, 0);
    source(&unionTokens[2], 0, 3, 0, 0);
    destination(&unionTokens[2], 0, 0, 0, 4, 15, 0);
    unionTokens[2].word[3] |= 2;
    source(&unionTokens[3], 2, 1, 4, 0);
    destination(&unionTokens[3], 0, 0, 0, 2, 0, 15);
    NV2AMetalValidatedProgram *constant = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:unionTokens[0].word length:6 error:&error];
    require(constant != nil, error);
    const float other[] = { .25f, .125f, 0, -.5f, NAN };
    const BOOL allowed[] = { YES, NO, NO, YES, NO };
    u.constants[100][0] = .5f;
    for (unsigned repeat = 0; repeat < 4; repeat++)
        for (unsigned i = 0; i < sizeof(other) / sizeof(*other); i++) {
            u.constants[101][0] = other[i];
            assert([constant hasFaultFreeReadOnlyAccess:0
                constants:u.constants[0]] == allowed[i]);
        }
    Token scaled[] = { token(NV2AMetalMACMul, 0, 100), t[1], t[2] };
    scaled[0].word[1] |= 1u << 9;
    source(&scaled[0], 0, 3, 0, 0);
    source(&scaled[0], 1, 2, 0, 0);
    destination(&scaled[0], 0, 0, 0, 2, 15, 0);
    scaled[2] = token(NV2AMetalMACMov, 0, 96);
    source(&scaled[2], 0, 3, 0, 0xe4);
    destination(&scaled[2], 0x103, 15, 0, 0, 0, 0);
    scaled[2].word[3] |= 3;
    NV2AMetalValidatedProgram *product = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:scaled[0].word length:3 error:&error];
    require(product != nil, error);
    u.constants[100][0] = 128;
    fetch.attributes[1].count = 0;
    for (unsigned repeat = 0; repeat < 8; repeat++) {
        fetch.attributes[1].inline_value[0] = repeat & 1 ? .75f : .5f;
        assert([product hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]
            sourceUniforms:&fetch] == !(repeat & 1));
    }

    /* A relative coefficient is exact only when every possible row has
     * identical bits. Keeping the first row's .5 when another is .75 would
     * incorrectly admit the out-of-window row 96 + 128 * .75. */
    Token coefficientUnion[] = { unionTokens[0], unionTokens[1], unionTokens[2],
        token(NV2AMetalMACMul, 0, 102), t[1], scaled[2] };
    source(&coefficientUnion[3], 0, 3, 0, 0);
    source(&coefficientUnion[3], 1, 1, 4, 0);
    destination(&coefficientUnion[3], 0, 0, 0, 2, 15, 0);
    NV2AMetalValidatedProgram *joined = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:coefficientUnion[0].word length:6 error:&error];
    require(joined != nil, error);
    u.constants[100][0] = .5f;
    u.constants[102][0] = 128;
    for (unsigned repeat = 0; repeat < 8; repeat++) {
        u.constants[101][0] = repeat & 1 ? .75f : .5f;
        assert([joined hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]] ==
               !(repeat & 1));
    }
    puts("Reciprocal proof cache:changed fractional binades,zero/NaN,"
         "same-binade fraction changes,identical reuse,arbitrary Float exclusion and mixed-sign/zero "
         "relative constant unions,exact coefficient changes/unions PASS (CPU only)");
}

static void readonly_proof_cache_benchmark(void)
{
    Token t[NV2A_METAL_VP_SLOTS];
    proof_cache_tokens(t, NO);
    for (unsigned i = 1; i < NV2A_METAL_VP_SLOTS; i++) {
        t[i] = token(NV2AMetalMACMov, 0, 96);
        source(&t[i], 0, 3, 0, 0xe4);
        destination(&t[i], 0, 0, 0, 2, 15, 0);
        t[i].word[3] |= 2;
    }
    t[NV2A_METAL_VP_SLOTS - 1].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *program = [[NV2AMetalValidatedProgram alloc]
        initWithTokens:t[0].word length:NV2A_METAL_VP_SLOTS error:&error];
    require(program != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    u.constants[100][0] = 0;
    for (unsigned access = 0; access < 2; access++)
        assert([program hasFaultFreeReadOnlyAccess:access constants:u.constants[0]]);
    struct timespec start, finish;
    assert(!clock_gettime(CLOCK_MONOTONIC, &start));
    for (unsigned i = 0; i < 10000; i++)
        assert([program hasFaultFreeReadOnlyAccess:i & 1 constants:u.constants[0]]);
    assert(!clock_gettime(CLOCK_MONOTONIC, &finish));
    double seconds = finish.tv_sec - start.tv_sec +
                     (finish.tv_nsec - start.tv_nsec) * 1e-9;
    printf("Readonly proof CPU benchmark: 10000 warm 136-slot queries "
           "%.3f ms PASS; no guest or GPU timing\n", seconds * 1000);
}

static void lazy_interpreter_test(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *program =
        [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                   error:&error];
    require(program != nil, error);
    assert(![program valueForKey:@"interpreterLibrary"] &&
           ![program valueForKey:@"specializationCompiler"]);
    Token tokens[7];
    writable_tokens(tokens, 96, 3, 15);
    NV2AMetalProgramUniforms u = uniforms();
    writable_constants(u.constants);
    NV2AMetalProgramInput input;
    writable_input(&input, 0);
    NSData *attributes = [NSData dataWithBytes:&input length:sizeof(input)];
    NV2AMetalWritableResult *readonly = [program
        executeTokens:tokens[0].word length:7 uniforms:&u attributes:attributes
                count:1 access:1 writeEnable:NO error:&error];
    require(readonly != nil, error);
    id library = [program valueForKey:@"interpreterLibrary"];
    id pipeline = [program valueForKey:@"readonlyPipeline"];
    assert(library && pipeline && ![program valueForKey:@"pipeline"] &&
           ![program valueForKey:@"rasterPipeline"] &&
           !memcmp(readonly.constants.bytes, u.constants, sizeof(u.constants)));
    NV2AMetalWritableResult *written = [program
        executeTokens:tokens[0].word length:7 uniforms:&u attributes:attributes
                count:1 access:1 writeEnable:YES error:&error];
    require(written != nil, error);
    const float (*constants)[4] = written.constants.bytes;
    for (unsigned k = 0; k < 4; k++)
        assert(constants[96][k] == u.constants[96][k] + input.attributes[3][k]);
    assert([program valueForKey:@"pipeline"] &&
           [program valueForKey:@"interpreterLibrary"] == library &&
           [program valueForKey:@"readonlyPipeline"] == pipeline &&
           ![program valueForKey:@"rasterPipeline"]);
    puts("XF interpreter startup: cold initialization compiles nothing; "
         "readonly and writable each build only their own pipeline PASS");
}

#include "test-metal-independent-writes.h"
#include "test-metal-captured-attribute-writes.h"
#include "test-metal-writer-proof-reuse.h"
#include "test-metal-writer-chain-proof.h"

static void maskless_destination_tests(void)
{
    unsigned accepted = 0, rejected = 0;
    for (unsigned reg = 13; reg < 16; reg++) {
        for (unsigned mac = 0; mac < 14; mac++)
            for (unsigned ilu = 0; ilu < 8; ilu++) {
                Token t = token(mac, ilu, 0);
                for (unsigned operand = 0; operand < 3; operand++)
                    source(&t, operand, 1, 0, 0xe4);
                destination(&t, 0, 0, 0, reg, 0, 0);
                t.word[3] |= 1;
                NSError *error = nil;
                NV2AMetalValidatedProgram *program =
                    [[NV2AMetalValidatedProgram alloc] initWithTokens:t.word
                                                               length:1
                                                                error:&error];
                require(program != nil, error);
                assert([program hasFaultFreeReadOnlyAccess:0] &&
                       [program hasFaultFreeReadOnlyAccess:1] &&
                       !program.mayWriteConstants);
                accepted++;
            }
        for (unsigned mac = 0; mac < 2; mac++) {
            Token t = token(mac, !mac, 0);
            source(&t, mac ? 0 : 2, 1, 0, 0xe4);
            destination(&t, 0, 0, 0, reg, mac ? 8 : 0, mac ? 0 : 8);
            t.word[3] |= 1;
            NSError *error = nil;
            assert(![[NV2AMetalValidatedProgram alloc] initWithTokens:t.word
                                                               length:1
                                                                error:&error] &&
                   error);
            rejected++;
        }
        /* The encoded field is inactive for paired ILU: its real target is R1. */
        Token paired = token(1, 1, 0);
        source(&paired, 0, 1, 0, 0xe4);
        source(&paired, 2, 1, 0, 0xe4);
        destination(&paired, 0, 0, 0, reg, 0, 8);
        paired.word[3] |= 1;
        NSError *error = nil;
        require([[NV2AMetalValidatedProgram alloc] initWithTokens:paired.word
                                                          length:1
                                                           error:&error] != nil,
                error);
        accepted++;
    }
    assert(accepted == 339 && rejected == 6);
    puts("Maskless XF destinations:336 MAC/ILU programs plus3 paired R1 stores;"
         "six active out-of-range destinations rejected;CPU-only PASS");
}

#include "test-metal-initial-constants.h"
#include "test-metal-program-key-reuse.h"
#include "test-metal-writable-uniform-cache.h"
#include "test-metal-sparse-proof-inputs.h"
#include "test-metal-bound-writer-proof-reuse.h"
#include "test-metal-bound-writer-proof-reuse-gpu.h"
#include "test-metal-float-proof-domains.h"
#include "test-metal-bound-float-proof.h"
#include "test-metal-indexed-float-proof.h"
#include "test-metal-exact-arithmetic-proof.h"
#include "test-metal-exact-selection-proof.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--float-proof-domains")))
            float_proof_domain_tests();
        if (argc == 2 && !strcmp(argv[1], "--float-proof-domains"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--bound-writer-proof-reuse")))
            bound_writer_proof_reuse_tests();
        if (argc == 2 && !strcmp(argv[1], "--bound-writer-proof-reuse"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--sparse-proof-inputs")))
            sparse_proof_input_tests();
        if (argc == 2 && !strcmp(argv[1], "--sparse-proof-inputs"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--maskless-destinations")))
            maskless_destination_tests();
        if (argc == 2 && !strcmp(argv[1], "--maskless-destinations"))
            return 0;
        if (argc == 1) {
            readonly_proof_cache_tests();
            reciprocal_proof_cache_tests();
        }
        if (argc == 2 && !strcmp(argv[1], "--readonly-proof-cache")) {
            proof_lane_cache_tests();
            readonly_proof_cache_tests();
            reciprocal_proof_cache_tests();
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--readonly-proof-benchmark")) {
            readonly_proof_cache_benchmark();
            return 0;
        }
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalWritableProgram *program =
            [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                       error:&error];
        require(program != nil, error);
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--exact-selection-proof")))
            exact_selection_proof_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--exact-selection-proof"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--exact-arithmetic-proof")))
            exact_arithmetic_proof_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--exact-arithmetic-proof"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--indexed-float-proof")))
            indexed_float_proof_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--indexed-float-proof"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--bound-float-proof")))
            bound_float_proof_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--bound-float-proof"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--bound-writer-proof-reuse-gpu")))
            bound_writer_proof_reuse_gpu_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--bound-writer-proof-reuse-gpu"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--writable-uniform-cache")))
            writable_uniform_cache_tests(commands.device);
        if (argc == 2 && !strcmp(argv[1], "--writable-uniform-cache"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--program-key-reuse")))
            program_key_reuse_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--program-key-reuse"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--initial-constants")))
            initial_constants_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--initial-constants"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--writer-chain-proof")))
            writer_chain_proof_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--writer-chain-proof"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--writer-proof-reuse")))
            writer_proof_reuse_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--writer-proof-reuse"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--captured-attribute-writes")))
            captured_attribute_write_tests(program, commands);
        if (argc == 2 && !strcmp(argv[1], "--captured-attribute-writes"))
            return 0;
        BOOL componentsOnly =
            argc == 2 && !strcmp(argv[1], "--component-writes");
        BOOL deadOnly = argc == 2 && !strcmp(argv[1], "--dead-writes");
        BOOL storesOnly = argc == 2 && !strcmp(argv[1], "--store-writes");
        BOOL arlOnly = argc == 2 && !strcmp(argv[1], "--arl-writes");
        BOOL capturedOnly = argc == 2 && !strcmp(argv[1], "--captured-writes");
        if (argc == 1 || componentsOnly || deadOnly || storesOnly || arlOnly ||
            capturedOnly ||
            (argc == 2 && !strcmp(argv[1], "--independent-writes")))
            independent_write_tests(program, commands,
                                    componentsOnly ? 1 : deadOnly ? 2 :
                                    storesOnly ? 3 : arlOnly ? 4 :
                                    capturedOnly ? 5 : 0);
        if (componentsOnly || deadOnly || storesOnly || arlOnly || capturedOnly ||
            (argc == 2 && !strcmp(argv[1], "--independent-writes")))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--large-reciprocal-proof")))
            large_reciprocal_gpu_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--large-reciprocal-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--large-union-proof")))
            large_union_gpu_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--large-union-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--large-scale-proof")))
            large_scale_gpu_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--large-scale-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--proof-lanes"))) {
            proof_lane_cache_tests();
            proof_lane_gpu_tests(commands, program);
        }
        if (argc == 2 && !strcmp(argv[1], "--proof-lanes"))
            return 0;
        if (argc == 2 && !strcmp(argv[1], "--attribute-readonly")) {
            attribute_readonly_tests(commands, program);
            return 0;
        }
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--constant-idx-proof")))
            constant_idx_proof_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--constant-idx-proof"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--clamped-idx-proof")))
            clamped_idx_proof_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--clamped-idx-proof"))
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
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--nonwriting-program"))) {
            lazy_interpreter_test(commands);
            nonwriting_program_tests(program, commands);
        }
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
