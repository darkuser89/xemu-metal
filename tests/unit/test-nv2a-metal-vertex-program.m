/*
 * Native Metal 4 microcode tests; no emulator or window
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#import "hw/xbox/nv2a/pgraph/metal/vertex-program.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#include <assert.h>
#include "test-metal-vertex-alias.h"
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Token {
    uint32_t word[4];
} Token;

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Vertex program test failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static void check_float(float a, float b)
{
    BOOL same =
        isnan(b) ? isnan(a) :
        isinf(b) ? a == b :
                   isfinite(a) && fabsf(a - b) <= 0.00003f * fmaxf(1, fabsf(b));
    if (!same) {
        fprintf(stderr, "Vertex program value: got %g, expected %g\n", a, b);
        abort();
    }
}

/* Test assembler uses the original raw token format from vsh-prog.c. */
static Token token(unsigned mac, unsigned ilu, unsigned attribute,
                   unsigned constant)
{
    Token t = {
        { 0,
          (mac << 21) | (ilu << 25) | (attribute << 9) | (constant << 13) | 27,
          (2u << 26) | (3u << 11) | (1u << 21) | (2u << 19) | (3u << 17) | 108,
          (1u << 28) | (2u << 30) | (1u << 11) | (3u << 3) | (15u << 12) | 1 }
    };
    return t;
}

static void source(Token *t, unsigned operand, unsigned mux, unsigned reg,
                   unsigned swizzle, BOOL negate)
{
    if (operand == 0) {
        t->word[1] = (t->word[1] & ~511u) | ((unsigned)negate << 8);
        t->word[2] = (t->word[2] & 0x03ffffffu) | (reg << 28) | (mux << 26);
    } else if (operand == 1) {
        t->word[2] = (t->word[2] & ~0x03fff800u) | ((unsigned)negate << 25) |
                     (reg << 13) | (mux << 11);
    } else {
        t->word[2] =
            (t->word[2] & ~0x7ffu) | ((unsigned)negate << 10) | (reg >> 2);
        t->word[3] =
            (t->word[3] & 0x0fffffffu) | ((reg & 3) << 30) | (mux << 28);
    }
    unsigned word = operand == 0 ? 1 : 2;
    unsigned start = operand == 0 ? 6 : operand == 1 ? 23 : 8;
    for (unsigned i = 0; i < 4; i++) {
        t->word[word] |= ((swizzle >> (2 * i)) & 3) << (start - 2 * i);
    }
}

static void destination(Token *t, unsigned output, unsigned mask, unsigned mux,
                        unsigned temp, unsigned macMask, unsigned iluMask)
{
    t->word[3] &= ~0x0ffff7fcu;
    t->word[3] |= (macMask << 24) | (temp << 20) | (iluMask << 16) |
                  (mask << 12) | (output << 3) | (mux << 2);
}

static NV2AMetalProgramUniforms uniforms(void)
{
    NV2AMetalProgramUniforms u = { 0 };
    u.surface_size[0] = u.surface_size[1] = 4;
    u.zmax = 16;
    u.point_scale = 2;
    u.point_size = 3;
    return u;
}

static NV2AMetalProgramResult *
encode(NV2AMetalVertexProgram *executor, NV2AMetalCommands *commands,
       Token *tokens, NSUInteger slots, NV2AMetalProgramUniforms *u,
       id<MTLBuffer> attributes, NSUInteger count)
{
    NSError *error = nil;
    NV2AMetalProgramResult *result = [executor encodeTokens:tokens[0].word
                                                     length:slots
                                                   uniforms:u
                                                 attributes:attributes
                                                      count:count
                                                   commands:commands
                                                      error:&error];
    require(result != nil, error);
    return result;
}

static void begin(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
}

static void finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}

static const NV2AMetalProgramOutput *raw(NV2AMetalProgramResult *result)
{
    const NV2AMetalProgramOutput *r = result.registers.contents;
    for (NSUInteger i = 0; i < result.vertexCount; i++) {
        assert(r[i].fault == NV2AMetalProgramFaultNone);
    }
    return r;
}

static void kelvin_reciprocal(NV2AMetalVertexProgram *executor,
                              NV2AMetalCommands *commands)
{
    /* Original envytools xf_rcp(v2)/xf_rsq(version2,abs) raw results,
     * commit f102b82381f3f11cee113d16374c87091db039d9. Include LUT/RCC
     * boundaries, signed zero/denorm/NaN and power-of-two RSQ precision.
     * Adjacent rows differ only by their source sign bit.
     */
    static const struct {
        uint32_t input;
        uint32_t expected[3];
    } cases[] = {
        { 0x00000000u, { 0x7f800000u, 0x5f800000u, 0x7f800000u } },
        { 0x80000000u, { 0xff800000u, 0xdf800000u, 0x7f800000u } },
        { 0x00000001u, { 0x7f800000u, 0x5f800000u, 0x7f800000u } },
        { 0x80000001u, { 0xff800000u, 0xdf800000u, 0x7f800000u } },
        { 0x007fffffu, { 0x7f800000u, 0x5f800000u, 0x7f800000u } },
        { 0x807fffffu, { 0xff800000u, 0xdf800000u, 0x7f800000u } },
        { 0x00800000u, { 0x7e800000u, 0x5f800000u, 0x5effffffu } },
        { 0x80800000u, { 0xfe800000u, 0xdf800000u, 0x5effffffu } },
        { 0x00800001u, { 0x7e7ffffdu, 0x5f800000u, 0x5efffffeu } },
        { 0x80800001u, { 0xfe7ffffdu, 0xdf800000u, 0x5efffffeu } },
        { 0x3f800000u, { 0x3f800000u, 0x3f800000u, 0x3f7fffffu } },
        { 0xbf800000u, { 0xbf800000u, 0xbf800000u, 0x3f7fffffu } },
        { 0x3f800001u, { 0x3f7ffffdu, 0x3f7ffffdu, 0x3f7ffffeu } },
        { 0xbf800001u, { 0xbf7ffffdu, 0xbf7ffffdu, 0x3f7ffffeu } },
        { 0x3f7fffffu, { 0x3f800000u, 0x3f800000u, 0x3f800000u } },
        { 0xbf7fffffu, { 0xbf800000u, 0xbf800000u, 0x3f800000u } },
        { 0x3f000000u, { 0x40000000u, 0x40000000u, 0x3fb504f3u } },
        { 0xbf000000u, { 0xc0000000u, 0xc0000000u, 0x3fb504f3u } },
        { 0x40000000u, { 0x3f000000u, 0x3f000000u, 0x3f3504f3u } },
        { 0xc0000000u, { 0xbf000000u, 0xbf000000u, 0x3f3504f3u } },
        { 0x40800000u, { 0x3e800000u, 0x3e800000u, 0x3effffffu } },
        { 0xc0800000u, { 0xbe800000u, 0xbe800000u, 0x3effffffu } },
        { 0x7f7fffffu, { 0x00000000u, 0x1f800000u, 0x1f800000u } },
        { 0xff7fffffu, { 0x80000000u, 0x9f800000u, 0x1f800000u } },
        { 0x7f800000u, { 0x00000000u, 0x1f800000u, 0x00000000u } },
        { 0xff800000u, { 0x80000000u, 0x9f800000u, 0x00000000u } },
        { 0x7f800001u, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0xff800001u, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0x7fa00001u, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0xffa00001u, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0x7fc00000u, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0xffc00000u, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0x7fffffffu, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0xffffffffu, { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu } },
        { 0x1f800000u, { 0x5f800000u, 0x5f800000u, 0x4f7fffffu } },
        { 0x9f800000u, { 0xdf800000u, 0xdf800000u, 0x4f7fffffu } },
        { 0x1f7fffffu, { 0x5f800000u, 0x5f800000u, 0x4f800000u } },
        { 0x9f7fffffu, { 0xdf800000u, 0xdf800000u, 0x4f800000u } },
        { 0x1f800001u, { 0x5f7ffffdu, 0x5f7ffffdu, 0x4f7ffffeu } },
        { 0x9f800001u, { 0xdf7ffffdu, 0xdf7ffffdu, 0x4f7ffffeu } },
        { 0x5f800000u, { 0x1f800000u, 0x1f800000u, 0x2f7fffffu } },
        { 0xdf800000u, { 0x9f800000u, 0x9f800000u, 0x2f7fffffu } },
        { 0x5f7fffffu, { 0x1f800000u, 0x1f800000u, 0x2f800000u } },
        { 0xdf7fffffu, { 0x9f800000u, 0x9f800000u, 0x2f800000u } },
        { 0x5f800001u, { 0x1f7ffffdu, 0x1f800000u, 0x2f7ffffeu } },
        { 0xdf800001u, { 0x9f7ffffdu, 0x9f800000u, 0x2f7ffffeu } },
        { 0x42fd0000u, { 0x3c01848du, 0x3c01848du, 0x3db616e3u } },
        { 0xc2fd0000u, { 0xbc01848du, 0xbc01848du, 0x3db616e3u } },
        { 0x3f880000u, { 0x3f70f0f0u, 0x3f70f0f0u, 0x3f785b42u } },
        { 0xbf880000u, { 0xbf70f0f0u, 0xbf70f0f0u, 0x3f785b42u } },
        { 0x3fa00000u, { 0x3f4cccccu, 0x3f4cccccu, 0x3f64f92du } },
        { 0xbfa00000u, { 0xbf4cccccu, 0xbf4cccccu, 0x3f64f92du } },
        { 0x3fc00000u, { 0x3f2aaaaau, 0x3f2aaaaau, 0x3f5105ebu } },
        { 0xbfc00000u, { 0xbf2aaaaau, 0xbf2aaaaau, 0x3f5105ebu } },
        { 0x3f9c0000u, { 0x3f520d20u, 0x3f520d20u, 0x3f67e3ecu } },
        { 0xbf9c0000u, { 0xbf520d20u, 0xbf520d20u, 0x3f67e3ecu } },
        { 0x3f8ccccdu, { 0x3f68ba2eu, 0x3f68ba2eu, 0x3f74161fu } },
        { 0xbf8ccccdu, { 0xbf68ba2eu, 0xbf68ba2eu, 0x3f74161fu } },
        { 0x3f400000u, { 0x3faaaaaau, 0x3faaaaaau, 0x3f93cd39u } },
        { 0xbf400000u, { 0xbfaaaaaau, 0xbfaaaaaau, 0x3f93cd39u } },
    };
    enum { Count = sizeof(cases) / sizeof(cases[0]) };
    NV2AMetalProgramInput input[Count] = { 0 };
    for (unsigned i = 0; i < Count; i++) {
        for (unsigned k = 0; k < 4; k++) {
            uint32_t bits = cases[(i + 7 * k) % Count].input;
            memcpy(&input[i].attributes[0][k], &bits, sizeof(bits));
        }
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    NV2AMetalProgramUniforms u = uniforms(), original = u;
    for (unsigned opcode = NV2AMetalILURcp; opcode <= NV2AMetalILURsq;
         opcode++) {
        for (unsigned path = 0; path < 3; path++) {
            for (unsigned swizzle = 0; swizzle < 4; swizzle++) {
                for (unsigned negate = 0; negate < 2; negate++) {
                    Token tokens[] = { token(NV2AMetalMACMov, 0, 0, 0),
                                       token(0, opcode, 0, 0) };
                    unsigned reg = path == 1 ? 2 : 12;
                    destination(&tokens[0], 0, 0, 0, reg, 15, 0);
                    tokens[0].word[3] &= ~1u;
                    source(&tokens[1], 2, path ? 1 : 2, path ? reg : 0,
                           0x55 * swizzle, negate);
                    destination(&tokens[1], 3, 15, 1, 0, 0, 0);
                    begin(commands);
                    NV2AMetalProgramResult *result =
                        encode(executor, commands, tokens + (path ? 0 : 1),
                               path ? 2 : 1, &u, attributes, Count);
                    finish(commands);
                    const NV2AMetalProgramOutput *out = raw(result);
                    for (unsigned i = 0; i < Count; i++) {
                        unsigned index = (i + 7 * swizzle) % Count;
                        if (negate) {
                            index ^= 1;
                        }
                        uint32_t expected =
                            cases[index].expected[opcode - NV2AMetalILURcp];
                        for (unsigned k = 0; k < 4; k++) {
                            uint32_t actual;
                            memcpy(&actual, &out[i].registers[3][k],
                                   sizeof(actual));
                            if (actual != expected) {
                                fprintf(stderr,
                                        "Kelvin reciprocal opcode%u case%u "
                                        "path%u swizzle%u negate%u channel%u: "
                                        "%08x expected %08x\n",
                                        opcode, i, path, swizzle, negate, k,
                                        actual, expected);
                                abort();
                            }
                        }
                    }
                    assert(memcmp(attributes.contents, input, sizeof(input)) ==
                           0);
                    assert(memcmp(&u, &original, sizeof(u)) == 0);
                }
            }
        }
    }
    printf("Metal4 Kelvin reciprocal: %u cases/%u raw channels PASS\n",
           Count * 72u, Count * 288u);
}

static void kelvin_transcendentals(NV2AMetalVertexProgram *executor,
                                   NV2AMetalCommands *commands)
{
    /* Original envytools xf_exp_flr/frc/exp and xf_log_e/f/log(version2,
     * FP_ZERO_WINS), commit f102b82381f3f11cee113d16374c87091db039d9.
     * Fixed raw results include 13-bit EXP input quantization, LUT edges,
     * LOG quantization around one, subnormals and distinct NaN payloads.
     * Adjacent rows differ only by sign.
     */
    static const struct {
        uint32_t input;
        uint32_t expected[2][4];
    } cases[] = {
        { 0x00000000u,
          { { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u },
            { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
        { 0x80000000u,
          { { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u },
            { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
        { 0x00000001u,
          { { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u },
            { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
        { 0x80000001u,
          { { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u },
            { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
        { 0x007fffffu,
          { { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u },
            { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
        { 0x807fffffu,
          { { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u },
            { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
        { 0x00800000u,
          { { 0x3f800000u, 0x00800000u, 0x3f800000u, 0x3f800000u },
            { 0xc2fc0000u, 0x3f800000u, 0xc2fc0000u, 0x3f800000u } } },
        { 0x80800000u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0xc2fc0000u, 0x3f800000u, 0xc2fc0000u, 0x3f800000u } } },
        { 0x00800001u,
          { { 0x3f800000u, 0x00800001u, 0x3f800000u, 0x3f800000u },
            { 0xc2fc0000u, 0x3f800001u, 0xc2fc0000u, 0x3f800000u } } },
        { 0x80800001u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0xc2fc0000u, 0x3f800001u, 0xc2fc0000u, 0x3f800000u } } },
        { 0x7f7fffffu,
          { { 0x7f800000u, 0x00000000u, 0x7f800000u, 0x3f800000u },
            { 0x42fe0000u, 0x3fffffffu, 0x42fffff3u, 0x3f800000u } } },
        { 0xff7fffffu,
          { { 0x00000000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x42fe0000u, 0x3fffffffu, 0x42fffff3u, 0x3f800000u } } },
        { 0x7f800000u,
          { { 0x7f800000u, 0x00000000u, 0x7f800000u, 0x3f800000u },
            { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } } },
        { 0xff800000u,
          { { 0x00000000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } } },
        { 0x7f800001u,
          { { 0x7f800000u, 0x7f800001u, 0x7fffffffu, 0x3f800000u },
            { 0x7f800001u, 0x7f800001u, 0x7f800001u, 0x3f800000u } } },
        { 0xff800001u,
          { { 0x7f800000u, 0xff800001u, 0x7fffffffu, 0x3f800000u },
            { 0x7f800001u, 0x7f800001u, 0x7f800001u, 0x3f800000u } } },
        { 0x7fa12345u,
          { { 0x7f800000u, 0x7fa12345u, 0x7fffffffu, 0x3f800000u },
            { 0x7fa12345u, 0x7fa12345u, 0x7fa12345u, 0x3f800000u } } },
        { 0xffa12345u,
          { { 0x7f800000u, 0xffa12345u, 0x7fffffffu, 0x3f800000u },
            { 0x7fa12345u, 0x7fa12345u, 0x7fa12345u, 0x3f800000u } } },
        { 0x7fc12345u,
          { { 0x7f800000u, 0x7fc12345u, 0x7fffffffu, 0x3f800000u },
            { 0x7fc12345u, 0x7fc12345u, 0x7fc12345u, 0x3f800000u } } },
        { 0xffc12345u,
          { { 0x7f800000u, 0xffc12345u, 0x7fffffffu, 0x3f800000u },
            { 0x7fc12345u, 0x7fc12345u, 0x7fc12345u, 0x3f800000u } } },
        { 0x7fffffffu,
          { { 0x7f800000u, 0x7fffffffu, 0x7fffffffu, 0x3f800000u },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x3f800000u } } },
        { 0xffffffffu,
          { { 0x7f800000u, 0xffffffffu, 0x7fffffffu, 0x3f800000u },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x3f800000u } } },
        { 0x337fffffu,
          { { 0x3f800000u, 0x337fffffu, 0x3f800000u, 0x3f800000u },
            { 0xc1c80000u, 0x3fffffffu, 0xc1c00030u, 0x3f800000u } } },
        { 0xb37fffffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0xc1c80000u, 0x3fffffffu, 0xc1c00030u, 0x3f800000u } } },
        { 0x33800000u,
          { { 0x3f800000u, 0x33800000u, 0x3f800000u, 0x3f800000u },
            { 0xc1c00000u, 0x3f800000u, 0xc1c00000u, 0x3f800000u } } },
        { 0xb3800000u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0xc1c00000u, 0x3f800000u, 0xc1c00000u, 0x3f800000u } } },
        { 0x33800001u,
          { { 0x3f800000u, 0x33800001u, 0x3f800000u, 0x3f800000u },
            { 0xc1c00000u, 0x3f800001u, 0xc1c00000u, 0x3f800000u } } },
        { 0xb3800001u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0xc1c00000u, 0x3f800001u, 0xc1c00000u, 0x3f800000u } } },
        { 0x3f7fffffu,
          { { 0x3f800000u, 0x3f7fffffu, 0x3ffff88au, 0x3f800000u },
            { 0xbf800000u, 0x3fffffffu, 0xb8c15000u, 0x3f800000u } } },
        { 0xbf7fffffu,
          { { 0x3f000000u, 0x00000000u, 0x3f000000u, 0x3f800000u },
            { 0xbf800000u, 0x3fffffffu, 0xb8c15000u, 0x3f800000u } } },
        { 0x3f800000u,
          { { 0x40000000u, 0x00000000u, 0x40000000u, 0x3f800000u },
            { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u } } },
        { 0xbf800000u,
          { { 0x3f000000u, 0x00000000u, 0x3f000000u, 0x3f800000u },
            { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u } } },
        { 0x3f800001u,
          { { 0x40000000u, 0x34000000u, 0x40000000u, 0x3f800000u },
            { 0x00000000u, 0x3f800001u, 0x00000000u, 0x3f800000u } } },
        { 0xbf800001u,
          { { 0x3e800000u, 0x3f7ffffeu, 0x3efff88au, 0x3f800000u },
            { 0x00000000u, 0x3f800001u, 0x00000000u, 0x3f800000u } } },
        { 0x3fffffffu,
          { { 0x40000000u, 0x3f7ffffeu, 0x407ff88au, 0x3f800000u },
            { 0x00000000u, 0x3fffffffu, 0x3f7ff9f5u, 0x3f800000u } } },
        { 0xbfffffffu,
          { { 0x3e800000u, 0x34000000u, 0x3e800000u, 0x3f800000u },
            { 0x00000000u, 0x3fffffffu, 0x3f7ff9f5u, 0x3f800000u } } },
        { 0x40000000u,
          { { 0x40800000u, 0x00000000u, 0x40800000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } } },
        { 0xc0000000u,
          { { 0x3e800000u, 0x00000000u, 0x3e800000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } } },
        { 0x40000001u,
          { { 0x40800000u, 0x34800000u, 0x40800000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800001u, 0x3f800000u, 0x3f800000u } } },
        { 0xc0000001u,
          { { 0x3e000000u, 0x3f7ffffcu, 0x3e7ff88au, 0x3f800000u },
            { 0x3f800000u, 0x3f800001u, 0x3f800000u, 0x3f800000u } } },
        { 0x397fffffu,
          { { 0x3f800000u, 0x397fffffu, 0x3f8002ceu, 0x3f800000u },
            { 0xc1500000u, 0x3fffffffu, 0xc1400060u, 0x3f800000u } } },
        { 0xb97fffffu,
          { { 0x3f000000u, 0x3f7ff000u, 0x3f7ff314u, 0x3f800000u },
            { 0xc1500000u, 0x3fffffffu, 0xc1400060u, 0x3f800000u } } },
        { 0x39800000u,
          { { 0x3f800000u, 0x39800000u, 0x3f80059cu, 0x3f800000u },
            { 0xc1400000u, 0x3f800000u, 0xc1400000u, 0x3f800000u } } },
        { 0xb9800000u,
          { { 0x3f000000u, 0x3f7ff000u, 0x3f7ff314u, 0x3f800000u },
            { 0xc1400000u, 0x3f800000u, 0xc1400000u, 0x3f800000u } } },
        { 0x39800001u,
          { { 0x3f800000u, 0x39800001u, 0x3f80059cu, 0x3f800000u },
            { 0xc1400000u, 0x3f800001u, 0xc1400000u, 0x3f800000u } } },
        { 0xb9800001u,
          { { 0x3f000000u, 0x3f7feffeu, 0x3f7fed9eu, 0x3f800000u },
            { 0xc1400000u, 0x3f800001u, 0xc1400000u, 0x3f800000u } } },
        { 0x3cffffffu,
          { { 0x3f800000u, 0x3cffffffu, 0x3f82cb32u, 0x3f800000u },
            { 0xc0c00000u, 0x3fffffffu, 0xc0a000c1u, 0x3f800000u } } },
        { 0xbcffffffu,
          { { 0x3f000000u, 0x3f780000u, 0x3f7a8800u, 0x3f800000u },
            { 0xc0c00000u, 0x3fffffffu, 0xc0a000c1u, 0x3f800000u } } },
        { 0x3d000000u,
          { { 0x3f800000u, 0x3d000000u, 0x3f82ce00u, 0x3f800000u },
            { 0xc0a00000u, 0x3f800000u, 0xc0a00000u, 0x3f800000u } } },
        { 0xbd000000u,
          { { 0x3f000000u, 0x3f780000u, 0x3f7a8800u, 0x3f800000u },
            { 0xc0a00000u, 0x3f800000u, 0xc0a00000u, 0x3f800000u } } },
        { 0x3d000001u,
          { { 0x3f800000u, 0x3d000001u, 0x3f82ce00u, 0x3f800000u },
            { 0xc0a00000u, 0x3f800001u, 0xc0a00000u, 0x3f800000u } } },
        { 0xbd000001u,
          { { 0x3f000000u, 0x3f77fffeu, 0x3f7a829eu, 0x3f800000u },
            { 0xc0a00000u, 0x3f800001u, 0xc0a00000u, 0x3f800000u } } },
        { 0x3effffffu,
          { { 0x3f800000u, 0x3effffffu, 0x3fb5021eu, 0x3f800000u },
            { 0xc0000000u, 0x3fffffffu, 0xbf800305u, 0x3f800000u } } },
        { 0xbeffffffu,
          { { 0x3f000000u, 0x3f000000u, 0x3f350600u, 0x3f800000u },
            { 0xc0000000u, 0x3fffffffu, 0xbf800305u, 0x3f800000u } } },
        { 0x3f000000u,
          { { 0x3f800000u, 0x3f000000u, 0x3fb50600u, 0x3f800000u },
            { 0xbf800000u, 0x3f800000u, 0xbf800000u, 0x3f800000u } } },
        { 0xbf000000u,
          { { 0x3f000000u, 0x3f000000u, 0x3f350600u, 0x3f800000u },
            { 0xbf800000u, 0x3f800000u, 0xbf800000u, 0x3f800000u } } },
        { 0x3f000001u,
          { { 0x3f800000u, 0x3f000001u, 0x3fb50600u, 0x3f800000u },
            { 0xbf800000u, 0x3f800001u, 0xbf800000u, 0x3f800000u } } },
        { 0xbf000001u,
          { { 0x3f000000u, 0x3efffffcu, 0x3f35021eu, 0x3f800000u },
            { 0xbf800000u, 0x3f800001u, 0xbf800000u, 0x3f800000u } } },
        { 0x401fffffu,
          { { 0x40800000u, 0x3efffff8u, 0x40b5021eu, 0x3f800000u },
            { 0x3f800000u, 0x3f9fffffu, 0x3fa93513u, 0x3f800000u } } },
        { 0xc01fffffu,
          { { 0x3e000000u, 0x3f000004u, 0x3e350600u, 0x3f800000u },
            { 0x3f800000u, 0x3f9fffffu, 0x3fa93513u, 0x3f800000u } } },
        { 0x40200000u,
          { { 0x40800000u, 0x3f000000u, 0x40b50600u, 0x3f800000u },
            { 0x3f800000u, 0x3fa00000u, 0x3fa939c0u, 0x3f800000u } } },
        { 0xc0200000u,
          { { 0x3e000000u, 0x3f000000u, 0x3e350600u, 0x3f800000u },
            { 0x3f800000u, 0x3fa00000u, 0x3fa939c0u, 0x3f800000u } } },
        { 0x40200001u,
          { { 0x40800000u, 0x3f000004u, 0x40b50600u, 0x3f800000u },
            { 0x3f800000u, 0x3fa00001u, 0x3fa939c0u, 0x3f800000u } } },
        { 0xc0200001u,
          { { 0x3e000000u, 0x3efffff8u, 0x3e35021eu, 0x3f800000u },
            { 0x3f800000u, 0x3fa00001u, 0x3fa939c0u, 0x3f800000u } } },
        { 0x41b7ffffu,
          { { 0x4a800000u, 0x3f7fffe0u, 0x4afff88au, 0x3f800000u },
            { 0x40800000u, 0x3fb7ffffu, 0x4090c0f4u, 0x3f800000u } } },
        { 0xc1b7ffffu,
          { { 0x34000000u, 0x36000000u, 0x34000000u, 0x3f800000u },
            { 0x40800000u, 0x3fb7ffffu, 0x4090c0f4u, 0x3f800000u } } },
        { 0x41b80000u,
          { { 0x4b000000u, 0x00000000u, 0x4b000000u, 0x3f800000u },
            { 0x40800000u, 0x3fb80000u, 0x4090c1f8u, 0x3f800000u } } },
        { 0xc1b80000u,
          { { 0x34000000u, 0x00000000u, 0x34000000u, 0x3f800000u },
            { 0x40800000u, 0x3fb80000u, 0x4090c1f8u, 0x3f800000u } } },
        { 0x41b80001u,
          { { 0x4b000000u, 0x36000000u, 0x4b000000u, 0x3f800000u },
            { 0x40800000u, 0x3fb80001u, 0x4090c1f8u, 0x3f800000u } } },
        { 0xc1b80001u,
          { { 0x33800000u, 0x3f7fffe0u, 0x33fff88au, 0x3f800000u },
            { 0x40800000u, 0x3fb80001u, 0x4090c1f8u, 0x3f800000u } } },
        { 0x42fbffffu,
          { { 0x7e000000u, 0x3f7fff80u, 0x7e7ff88au, 0x3f800000u },
            { 0x40c00000u, 0x3ffbffffu, 0x40df45eau, 0x3f800000u } } },
        { 0xc2fbffffu,
          { { 0x00800000u, 0x37000000u, 0x00800000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffbffffu, 0x40df45eau, 0x3f800000u } } },
        { 0x42fc0000u,
          { { 0x7e800000u, 0x00000000u, 0x7e800000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffc0000u, 0x40df46a8u, 0x3f800000u } } },
        { 0xc2fc0000u,
          { { 0x00800000u, 0x00000000u, 0x00800000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffc0000u, 0x40df46a8u, 0x3f800000u } } },
        { 0x42fc0001u,
          { { 0x7e800000u, 0x37000000u, 0x7e800000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffc0001u, 0x40df46a8u, 0x3f800000u } } },
        { 0xc2fc0001u,
          { { 0x00000000u, 0x3f7fff80u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffc0001u, 0x40df46a8u, 0x3f800000u } } },
        { 0x42fcffffu,
          { { 0x7e800000u, 0x3effff00u, 0x7eb5021eu, 0x3f800000u },
            { 0x40c00000u, 0x3ffcffffu, 0x40df7442u, 0x3f800000u } } },
        { 0xc2fcffffu,
          { { 0x00000000u, 0x3f000080u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffcffffu, 0x40df7442u, 0x3f800000u } } },
        { 0x42fd0000u,
          { { 0x7e800000u, 0x3f000000u, 0x7eb50600u, 0x3f800000u },
            { 0x40c00000u, 0x3ffd0000u, 0x40df74fcu, 0x3f800000u } } },
        { 0xc2fd0000u,
          { { 0x00000000u, 0x3f000000u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffd0000u, 0x40df74fcu, 0x3f800000u } } },
        { 0x42fd0001u,
          { { 0x7e800000u, 0x3f000080u, 0x7eb50600u, 0x3f800000u },
            { 0x40c00000u, 0x3ffd0001u, 0x40df74fcu, 0x3f800000u } } },
        { 0xc2fd0001u,
          { { 0x00000000u, 0x3effff00u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffd0001u, 0x40df74fcu, 0x3f800000u } } },
        { 0x42fdffffu,
          { { 0x7e800000u, 0x3f7fff80u, 0x7efff88au, 0x3f800000u },
            { 0x40c00000u, 0x3ffdffffu, 0x40dfa296u, 0x3f800000u } } },
        { 0xc2fdffffu,
          { { 0x00000000u, 0x37000000u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffdffffu, 0x40dfa296u, 0x3f800000u } } },
        { 0x42fe0000u,
          { { 0x7f000000u, 0x00000000u, 0x7f000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffe0000u, 0x40dfa350u, 0x3f800000u } } },
        { 0xc2fe0000u,
          { { 0x00000000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffe0000u, 0x40dfa350u, 0x3f800000u } } },
        { 0x42fe0001u,
          { { 0x7f000000u, 0x37000000u, 0x7f000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffe0001u, 0x40dfa350u, 0x3f800000u } } },
        { 0xc2fe0001u,
          { { 0x00000000u, 0x3f7fff80u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffe0001u, 0x40dfa350u, 0x3f800000u } } },
        { 0x42feffffu,
          { { 0x7f000000u, 0x3effff00u, 0x7f35021eu, 0x3f800000u },
            { 0x40c00000u, 0x3ffeffffu, 0x40dfd0eau, 0x3f800000u } } },
        { 0xc2feffffu,
          { { 0x00000000u, 0x3f000080u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3ffeffffu, 0x40dfd0eau, 0x3f800000u } } },
        { 0x42ff0000u,
          { { 0x7f000000u, 0x3f000000u, 0x7f350600u, 0x3f800000u },
            { 0x40c00000u, 0x3fff0000u, 0x40dfd1a4u, 0x3f800000u } } },
        { 0xc2ff0000u,
          { { 0x00000000u, 0x3f000000u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3fff0000u, 0x40dfd1a4u, 0x3f800000u } } },
        { 0x42ff0001u,
          { { 0x7f000000u, 0x3f000080u, 0x7f350600u, 0x3f800000u },
            { 0x40c00000u, 0x3fff0001u, 0x40dfd1a4u, 0x3f800000u } } },
        { 0xc2ff0001u,
          { { 0x00000000u, 0x3effff00u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3fff0001u, 0x40dfd1a4u, 0x3f800000u } } },
        { 0x42ffffffu,
          { { 0x7f000000u, 0x3f7fff80u, 0x7f7ff88au, 0x3f800000u },
            { 0x40c00000u, 0x3fffffffu, 0x40dfff3eu, 0x3f800000u } } },
        { 0xc2ffffffu,
          { { 0x00000000u, 0x37000000u, 0x00000000u, 0x3f800000u },
            { 0x40c00000u, 0x3fffffffu, 0x40dfff3eu, 0x3f800000u } } },
        { 0x43000000u,
          { { 0x7f800000u, 0x00000000u, 0x7f800000u, 0x3f800000u },
            { 0x40e00000u, 0x3f800000u, 0x40e00000u, 0x3f800000u } } },
        { 0xc3000000u,
          { { 0x00000000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x40e00000u, 0x3f800000u, 0x40e00000u, 0x3f800000u } } },
        { 0x43000001u,
          { { 0x7f800000u, 0x37800000u, 0x7f800000u, 0x3f800000u },
            { 0x40e00000u, 0x3f800001u, 0x40e00000u, 0x3f800000u } } },
        { 0xc3000001u,
          { { 0x00000000u, 0x3f7fff00u, 0x00000000u, 0x3f800000u },
            { 0x40e00000u, 0x3f800001u, 0x40e00000u, 0x3f800000u } } },
        { 0x43007fffu,
          { { 0x7f800000u, 0x3efffe00u, 0x7f800000u, 0x3f800000u },
            { 0x40e00000u, 0x3f807fffu, 0x40e02c48u, 0x3f800000u } } },
        { 0xc3007fffu,
          { { 0x00000000u, 0x3f000100u, 0x00000000u, 0x3f800000u },
            { 0x40e00000u, 0x3f807fffu, 0x40e02c48u, 0x3f800000u } } },
        { 0x43008000u,
          { { 0x7f800000u, 0x3f000000u, 0x7f800000u, 0x3f800000u },
            { 0x40e00000u, 0x3f808000u, 0x40e02db6u, 0x3f800000u } } },
        { 0xc3008000u,
          { { 0x00000000u, 0x3f000000u, 0x00000000u, 0x3f800000u },
            { 0x40e00000u, 0x3f808000u, 0x40e02db6u, 0x3f800000u } } },
        { 0x43008001u,
          { { 0x7f800000u, 0x3f000100u, 0x7f800000u, 0x3f800000u },
            { 0x40e00000u, 0x3f808001u, 0x40e02db6u, 0x3f800000u } } },
        { 0xc3008001u,
          { { 0x00000000u, 0x3efffe00u, 0x00000000u, 0x3f800000u },
            { 0x40e00000u, 0x3f808001u, 0x40e02db6u, 0x3f800000u } } },
        { 0x487fffffu,
          { { 0x7f800000u, 0x3f7c0000u, 0x7f800000u, 0x3f800000u },
            { 0x41880000u, 0x3fffffffu, 0x418fffcfu, 0x3f800000u } } },
        { 0xc87fffffu,
          { { 0x00000000u, 0x3c800000u, 0x00000000u, 0x3f800000u },
            { 0x41880000u, 0x3fffffffu, 0x418fffcfu, 0x3f800000u } } },
        { 0x48800000u,
          { { 0x7f800000u, 0x00000000u, 0x7f800000u, 0x3f800000u },
            { 0x41900000u, 0x3f800000u, 0x41900000u, 0x3f800000u } } },
        { 0xc8800000u,
          { { 0x00000000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x41900000u, 0x3f800000u, 0x41900000u, 0x3f800000u } } },
        { 0x48800001u,
          { { 0x7f800000u, 0x3d000000u, 0x7f800000u, 0x3f800000u },
            { 0x41900000u, 0x3f800001u, 0x41900000u, 0x3f800000u } } },
        { 0xc8800001u,
          { { 0x00000000u, 0x3f780000u, 0x00000000u, 0x3f800000u },
            { 0x41900000u, 0x3f800001u, 0x41900000u, 0x3f800000u } } },
    };
    enum { Count = sizeof(cases) / sizeof(cases[0]) };
    NV2AMetalProgramInput input[Count] = { 0 };
    for (unsigned i = 0; i < Count; i++) {
        for (unsigned k = 0; k < 4; k++) {
            uint32_t bits = cases[(i + 7 * k) % Count].input;
            memcpy(&input[i].attributes[0][k], &bits, sizeof(bits));
        }
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    NV2AMetalProgramUniforms u = uniforms(), original = u;
    for (unsigned opcode = NV2AMetalILUExp; opcode <= NV2AMetalILULog;
         opcode++) {
        for (unsigned path = 0; path < 3; path++) {
            for (unsigned swizzle = 0; swizzle < 4; swizzle++) {
                for (unsigned negate = 0; negate < 2; negate++) {
                    Token tokens[] = { token(NV2AMetalMACMov, 0, 0, 0),
                                       token(0, opcode, 0, 0) };
                    unsigned reg = path == 1 ? 2 : 12;
                    destination(&tokens[0], 0, 0, 0, reg, 15, 0);
                    tokens[0].word[3] &= ~1u;
                    source(&tokens[1], 2, path ? 1 : 2, path ? reg : 0,
                           0x55 * swizzle, negate);
                    destination(&tokens[1], 3, 15, 1, 0, 0, 0);
                    begin(commands);
                    NV2AMetalProgramResult *result =
                        encode(executor, commands, tokens + (path ? 0 : 1),
                               path ? 2 : 1, &u, attributes, Count);
                    finish(commands);
                    const NV2AMetalProgramOutput *out = raw(result);
                    for (unsigned i = 0; i < Count; i++) {
                        unsigned index = (i + 7 * swizzle) % Count;
                        if (negate) {
                            index ^= 1;
                        }
                        for (unsigned k = 0; k < 4; k++) {
                            uint32_t expected =
                                cases[index]
                                    .expected[opcode - NV2AMetalILUExp][k];
                            uint32_t actual;
                            memcpy(&actual, &out[i].registers[3][k],
                                   sizeof(actual));
                            if (actual != expected) {
                                fprintf(stderr,
                                        "Kelvin transcendental opcode%u case%u "
                                        "path%u swizzle%u negate%u channel%u: "
                                        "%08x expected %08x\n",
                                        opcode, i, path, swizzle, negate, k,
                                        actual, expected);
                                abort();
                            }
                        }
                    }
                    assert(memcmp(attributes.contents, input, sizeof(input)) ==
                           0);
                    assert(memcmp(&u, &original, sizeof(u)) == 0);
                }
            }
        }
    }
    printf("Metal4 Kelvin transcendental: %u cases/%u raw channels PASS\n",
           Count * 48u, Count * 192u);
}

static void kelvin_lit(NV2AMetalVertexProgram *executor,
                       NV2AMetalCommands *commands)
{
    /* Original xf_lit results at the same envytools commit as above.
     * Clamp/quantization, raw positive X and exceptional branch ordering
     * are observable before vertex color clamping.
     */
    static const struct {
        uint32_t input[4];
        unsigned swizzle;
        uint32_t expected[2][4];
    } cases[] = {
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x80000000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x80000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x80000000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x80000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xbf800000u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xbf800000u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xbf800000u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xbf800000u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
          0x1bu,
          { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
          0xffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0xbf800000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0xbf800000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0xbf800000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000000u, 0x00000000u, 0xbf800000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x3f800000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x3f800000u },
          0x1bu,
          { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x3f800000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x3f800000u },
          0xffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0xbf800000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0xbf800000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0xbf800000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f800000u, 0x00000000u, 0xbf800000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } } },
        { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0xbf800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } } },
        { { 0xbf800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0xbf800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } } },
        { { 0xbf800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x40200000u, 0x40400000u, 0x40800000u, 0x40000000u },
          0xe4u,
          { { 0x3f800000u, 0x40200000u, 0x41100520u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x40200000u, 0x40400000u, 0x40800000u, 0x40000000u },
          0x1bu,
          { { 0x3f800000u, 0x40000000u, 0x42000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x40200000u, 0x40400000u, 0x40800000u, 0x40000000u },
          0x00u,
          { { 0x3f800000u, 0x40200000u, 0x411e29a0u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x40200000u, 0x40400000u, 0x40800000u, 0x40000000u },
          0xffu,
          { { 0x3f800000u, 0x40000000u, 0x40800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00000001u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
          0xe4u,
          { { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00000001u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
          0x1bu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00000001u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
          0x00u,
          { { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00000001u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
          0xffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x80000001u, 0x3f800000u, 0x7fc12345u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u } } },
        { { 0x80000001u, 0x3f800000u, 0x7fc12345u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x80000001u, 0x3f800000u, 0x7fc12345u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u } } },
        { { 0x80000001u, 0x3f800000u, 0x7fc12345u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x007fffffu, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0xe4u,
          { { 0x3f800000u, 0x007fffffu, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x007fffffu, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0x1bu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x007fffffu, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0x00u,
          { { 0x3f800000u, 0x007fffffu, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x007fffffu, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0xffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00800000u, 0x00800000u, 0x00000000u, 0x3f800000u },
          0xe4u,
          { { 0x3f800000u, 0x00800000u, 0x00800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00800000u, 0x00800000u, 0x00000000u, 0x3f800000u },
          0x1bu,
          { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00800000u, 0x00800000u, 0x00000000u, 0x3f800000u },
          0x00u,
          { { 0x3f800000u, 0x00800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x00800000u, 0x00800000u, 0x00000000u, 0x3f800000u },
          0xffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0xe4u,
          { { 0x3f800000u, 0x7fc12345u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0x1bu,
          { { 0x3f800000u, 0x3f800000u, 0x7fffffffu, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0x00u,
          { { 0x3f800000u, 0x7fc12345u, 0x7fffffffu, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x3f800000u, 0x00000000u, 0x3f800000u },
          0xffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x00000000u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x7fc12345u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x00000000u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x00000000u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x7fc12345u, 0x7fffffffu, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x7fc12345u, 0x00000000u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0xffc12345u, 0x3f800000u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x7fc12345u, 0x3f800000u, 0x3f800000u } } },
        { { 0xffc12345u, 0x3f800000u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0xffc12345u, 0x3f800000u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x7fc12345u, 0x7fffffffu, 0x3f800000u } } },
        { { 0xffc12345u, 0x3f800000u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x00000000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x00000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x00000000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x00000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x3f800000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x7fffffffu, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x3f800000u },
          0x1bu,
          { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x3f800000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x3f800000u },
          0xffu,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x7fc12345u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x7fffffffu, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x7fc12345u },
          0x1bu,
          { { 0x3f800000u, 0x7fc12345u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x7fc12345u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x7fc12345u },
          0xffu,
          { { 0x3f800000u, 0x7fc12345u, 0x7fffffffu, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xffc12345u, 0x00000000u, 0x80000001u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xffc12345u, 0x00000000u, 0x80000001u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xffc12345u, 0x00000000u, 0x80000001u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0xffc12345u, 0x00000000u, 0x80000001u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800001u, 0x00000000u, 0x42ffffffu },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800001u, 0x00000000u, 0x42ffffffu },
          0x1bu,
          { { 0x3f800000u, 0x42ffffffu, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800001u, 0x00000000u, 0x42ffffffu },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800001u, 0x00000000u, 0x42ffffffu },
          0xffu,
          { { 0x3f800000u, 0x42ffffffu, 0x7f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f7fffffu, 0x00000000u, 0xc3000000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f810d40u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f7fffffu, 0x00000000u, 0xc3000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x43000000u, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f7fffffu, 0x00000000u, 0xc3000000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f7fffffu, 0x00000000u, 0xc3000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x43000000u, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0x42ffffffu },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x4514cc76u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0x42ffffffu },
          0x1bu,
          { { 0x3f800000u, 0x42ffffffu, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0x42ffffffu },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0x42ffffffu },
          0xffu,
          { { 0x3f800000u, 0x42ffffffu, 0x7f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0xc3000000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x39dc35d8u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0xc3000000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x43000000u, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0xc3000000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f880000u, 0x00000000u, 0xc3000000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x43000000u, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fa00000u, 0x00000000u, 0x40200000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3fdfacc8u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fa00000u, 0x00000000u, 0x40200000u },
          0x1bu,
          { { 0x3f800000u, 0x40200000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fa00000u, 0x00000000u, 0x40200000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fa00000u, 0x00000000u, 0x40200000u },
          0xffu,
          { { 0x3f800000u, 0x40200000u, 0x411e29a0u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f7fffffu, 0x00000000u, 0x7f7fffffu },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f7fffffu, 0x00000000u, 0x7f7fffffu },
          0x1bu,
          { { 0x3f800000u, 0x7f7fffffu, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f7fffffu, 0x00000000u, 0x7f7fffffu },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x7f7fffffu, 0x00000000u, 0x7f7fffffu },
          0xffu,
          { { 0x3f800000u, 0x7f7fffffu, 0x7f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000001u, 0x00000000u, 0x80000001u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000001u, 0x00000000u, 0x80000001u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000001u, 0x00000000u, 0x80000001u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x00000001u, 0x00000000u, 0x80000001u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000001u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x80000001u, 0x00000000u, 0xbf800000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x80000001u, 0x00000000u, 0xbf800000u },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x80000001u, 0x00000000u, 0xbf800000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x80000001u, 0x00000000u, 0xbf800000u },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x33800000u },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x33800000u },
          0x1bu,
          { { 0x3f800000u, 0x33800000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x33800000u },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x33800000u },
          0xffu,
          { { 0x3f800000u, 0x33800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f900000u, 0x00000000u, 0xc2ffffffu },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3495ed98u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f900000u, 0x00000000u, 0xc2ffffffu },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x42ffffffu, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f900000u, 0x00000000u, 0xc2ffffffu },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3f900000u, 0x00000000u, 0xc2ffffffu },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x42ffffffu, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fb62eccu, 0x00000000u, 0xbf409bbbu },
          0xe4u,
          { { 0x3f800000u, 0x3f800000u, 0x3f444c4cu, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fb62eccu, 0x00000000u, 0xbf409bbbu },
          0x1bu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f409bbbu, 0x7f800000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fb62eccu, 0x00000000u, 0xbf409bbbu },
          0x00u,
          { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } } },
        { { 0x3f800000u, 0x3fb62eccu, 0x00000000u, 0xbf409bbbu },
          0xffu,
          { { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
            { 0x3f800000u, 0x3f409bbbu, 0x3f4eab78u, 0x3f800000u } } },
    };
    NV2AMetalProgramUniforms u = uniforms(), original = u;
    unsigned count = 0;
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        NV2AMetalProgramInput input = { 0 };
        memcpy(input.attributes[0], cases[i].input, sizeof(cases[i].input));
        id<MTLBuffer> attributes =
            [commands.device newBufferWithBytes:&input
                                         length:sizeof(input)
                                        options:MTLResourceStorageModeShared];
        assert(attributes);
        for (unsigned path = 0; path < 3; path++) {
            for (unsigned negate = 0; negate < 2; negate++) {
                Token tokens[] = { token(NV2AMetalMACMov, 0, 0, 0),
                                   token(0, NV2AMetalILULit, 0, 0) };
                unsigned reg = path == 1 ? 2 : 12;
                destination(&tokens[0], 0, 0, 0, reg, 15, 0);
                tokens[0].word[3] &= ~1u;
                source(&tokens[1], 2, path ? 1 : 2, path ? reg : 0,
                       cases[i].swizzle, negate);
                destination(&tokens[1], 3, 15, 1, 0, 0, 0);
                begin(commands);
                NV2AMetalProgramResult *result =
                    encode(executor, commands, tokens + (path ? 0 : 1),
                           path ? 2 : 1, &u, attributes, 1);
                finish(commands);
                for (unsigned k = 0; k < 4; k++) {
                    uint32_t actual;
                    memcpy(&actual, &raw(result)->registers[3][k], 4);
                    uint32_t expected = cases[i].expected[negate][k];
                    if (actual != expected) {
                        fprintf(stderr,
                                "Kelvin LIT case%u path%u negate%u channel%u: "
                                "%08x expected %08x\n",
                                i, path, negate, k, actual, expected);
                        abort();
                    }
                }
                assert(memcmp(attributes.contents, &input, sizeof(input)) == 0);
                assert(memcmp(&u, &original, sizeof(u)) == 0);
                count++;
            }
        }
    }
    printf("Metal4 Kelvin LIT: %u cases/%u raw channels PASS\n", count,
           count * 4);
}

static void kelvin_arithmetic(NV2AMetalVertexProgram *executor,
                              NV2AMetalCommands *commands)
{
    /* Raw expectations from envytools nvhw/fp.c:fp32_mul and
     * nvhw/xf.c:xf_sum(version2), commit
     * f102b82381f3f11cee113d16374c87091db039d9. NV20 flags:
     * FP_RZ|FP_FTZ|FP_ZERO_WINS|FP_MUL_POS_ZERO. Cover finite
     * truncation/cancellation, accumulation, under/overflow, generated NaNs and
     * raw DST components before color clamping.
     */
    static const struct {
        uint32_t input[3][4];
        uint32_t expected[7][4];
    } cases[] = {
        { { { 0x00000000u, 0x80000001u, 0x00800000u, 0x80800001u },
            { 0x00000000u, 0x807fffffu, 0x3f800000u, 0xbf000000u },
            { 0x00000000u, 0xbf800000u, 0x7f800001u, 0x807fffffu } },
          { { 0x00000000u, 0x00000000u, 0x00800000u, 0x00000000u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x80c00000u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x80000000u },
            { 0x00800000u, 0x00800000u, 0x00800000u, 0x00800000u },
            { 0xbf000000u, 0xbf000000u, 0xbf000000u, 0xbf000000u },
            { 0x00800000u, 0x00800000u, 0x00800000u, 0x00800000u },
            { 0x3f800000u, 0x00000000u, 0x00800000u, 0xbf000000u } } },
        { { { 0x00000000u, 0x80000001u, 0x00800000u, 0x80800001u },
            { 0x80000000u, 0x00800000u, 0xbf800000u, 0x40000000u },
            { 0x00000000u, 0xbf800000u, 0x7f800001u, 0x807fffffu } },
          { { 0x00000000u, 0x00000000u, 0x80800000u, 0x81000001u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x80c00000u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x81200000u },
            { 0x80800000u, 0x80800000u, 0x80800000u, 0x80800000u },
            { 0x40000000u, 0x40000000u, 0x40000000u, 0x40000000u },
            { 0x81400001u, 0x81400001u, 0x81400001u, 0x81400001u },
            { 0x3f800000u, 0x00000000u, 0x00800000u, 0x40000000u } } },
        { { { 0x00000000u, 0x80000001u, 0x00800000u, 0x80800001u },
            { 0x807fffffu, 0x3f800000u, 0xbf000000u, 0x7f800000u },
            { 0x00000000u, 0xbf800000u, 0x7f800001u, 0x807fffffu } },
          { { 0x00000000u, 0x00000000u, 0x80000000u, 0xff800000u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x80c00000u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0xff800000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
            { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
            { 0x3f800000u, 0x00000000u, 0x00800000u, 0x7f800000u } } },
        { { { 0x00000000u, 0x80000001u, 0x00800000u, 0x80800001u },
            { 0x80800000u, 0x3f800001u, 0xc0000000u, 0x7f800001u },
            { 0x00000000u, 0xbf800000u, 0x7f800001u, 0x807fffffu } },
          { { 0x00000000u, 0x00000000u, 0x81000000u, 0x7fffffffu },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x80c00000u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x7fffffffu },
            { 0x81000000u, 0x81000000u, 0x81000000u, 0x81000000u },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x3f800000u, 0x00000000u, 0x00800000u, 0x7f800001u } } },
        { { { 0x80000001u, 0x00800000u, 0x80800001u, 0x3f800001u },
            { 0x80000001u, 0x00800001u, 0xbf800001u, 0x7f7fffffu },
            { 0x00000000u, 0xbf800000u, 0x7f800001u, 0x807fffffu } },
          { { 0x00000000u, 0x00000000u, 0x00800002u, 0x7f7fffffu },
            { 0x80000000u, 0xbf800000u, 0x7fffffffu, 0x3f800001u },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x7f7fffffu },
            { 0x00800002u, 0x00800002u, 0x00800002u, 0x00800002u },
            { 0x7f7fffffu, 0x7f7fffffu, 0x7f7fffffu, 0x7f7fffffu },
            { 0x7f7fffffu, 0x7f7fffffu, 0x7f7fffffu, 0x7f7fffffu },
            { 0x3f800000u, 0x00000000u, 0x80800001u, 0x7f7fffffu } } },
        { { { 0x40000000u, 0xff7fffffu, 0x7f800001u, 0xffc00000u },
            { 0x00000000u, 0x807fffffu, 0x3f800000u, 0xbf000000u },
            { 0x00000000u, 0xbf800000u, 0x7f800001u, 0x807fffffu } },
          { { 0x00000000u, 0x00000000u, 0x7fffffffu, 0x7fffffffu },
            { 0x40000000u, 0xff7fffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x00000000u, 0xbf800000u, 0x7fffffffu, 0x7fffffffu },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x3f800000u, 0x00000000u, 0x7f800001u, 0xbf000000u } } },
        { { { 0x7f023f84u, 0x2d3b16bdu, 0x22f994eau, 0x599bc71bu },
            { 0xc8bec513u, 0x4bf368f8u, 0xff4abf41u, 0x4c4fd1beu },
            { 0xaf7f8756u, 0x53d617f7u, 0xa8c78facu, 0x659c4e05u } },
          { { 0xff7fffffu, 0x39b1e34bu, 0xe2c5a9f6u, 0x667ceb3fu },
            { 0x7f023f84u, 0x53d617f7u, 0xa8c78012u, 0x659c4e05u },
            { 0xff7fffffu, 0x53d617f7u, 0xe2c5a9f6u, 0x66a58920u },
            { 0xff7fffffu, 0xff7fffffu, 0xff7fffffu, 0xff7fffffu },
            { 0xff7fffffu, 0xff7fffffu, 0xff7fffffu, 0xff7fffffu },
            { 0xff7fffffu, 0xff7fffffu, 0xff7fffffu, 0xff7fffffu },
            { 0x3f800000u, 0x39b1e34bu, 0x22f994eau, 0x4c4fd1beu } } },
        { { { 0x9397cc88u, 0xf1ec5211u, 0xe16664ceu, 0x9313aecfu },
            { 0x2fea8647u, 0xb1cae43cu, 0x52ea25d5u, 0x9e4c4de2u },
            { 0x39c70efau, 0x6488726bu, 0x6f32bd30u, 0x4868f3d9u } },
          { { 0x840b1093u, 0x643b4b71u, 0xf4d2ba30u, 0x00000000u },
            { 0x39c70efau, 0xf1ec5210u, 0x6f32bd2fu, 0x4868f3d9u },
            { 0x39c70efau, 0x64e61823u, 0xf4d2a3d8u, 0x4868f3d9u },
            { 0xf4d2ba30u, 0xf4d2ba30u, 0xf4d2ba30u, 0xf4d2ba30u },
            { 0xf4d2ba30u, 0xf4d2ba30u, 0xf4d2ba30u, 0xf4d2ba30u },
            { 0xf4d2ba30u, 0xf4d2ba30u, 0xf4d2ba30u, 0xf4d2ba30u },
            { 0x3f800000u, 0x643b4b71u, 0xe16664ceu, 0x9e4c4de2u } } },
        { { { 0xc5770c27u, 0xc7a11b5au, 0x424d32f1u, 0x3aaf8f9cu },
            { 0xc44d664bu, 0xb8f2072eu, 0x3c93a4b5u, 0xc7bb6e90u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0x4a463772u, 0x4118505fu, 0x3f6cb08cu, 0xc30089b9u },
            { 0xc57706d1u, 0xc7a11b84u, 0x425132f1u, 0xbf7fa83au },
            { 0x4a463773u, 0x4112fb09u, 0x3ff65847u, 0xc30189b9u },
            { 0x4a46379bu, 0x4a46379bu, 0x4a46379bu, 0x4a46379bu },
            { 0x4a405c27u, 0x4a405c27u, 0x4a405c27u, 0x4a405c27u },
            { 0x4a463599u, 0x4a463599u, 0x4a463599u, 0x4a463599u },
            { 0x3f800000u, 0x4118505fu, 0x424d32f1u, 0xc7bb6e90u } } },
        { { { 0xb910f0afu, 0x3847e642u, 0xb5c5f0b9u, 0x39f6e2c4u },
            { 0x3b768f53u, 0x46aa4c96u, 0x36be9afdu, 0xc412a038u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0xb50b986du, 0x3f84fab5u, 0xad13607fu, 0xbe8d67d7u },
            { 0x3eaa988cu, 0xbeaaa46bu, 0x3f7fffe9u, 0xbf7fe125u },
            { 0x3eaaaa99u, 0x3f34a014u, 0x3f800001u, 0xbfa359f6u },
            { 0x3f84fab0u, 0x3f84fab0u, 0x3f84fab0u, 0x3f84fab0u },
            { 0xc4125dbau, 0xc4125dbau, 0xc4125dbau, 0xc4125dbau },
            { 0x3f434175u, 0x3f434175u, 0x3f434175u, 0x3f434175u },
            { 0x3f800000u, 0x3f84fab5u, 0xb5c5f0b9u, 0xc412a038u } } },
        { { { 0x38af6637u, 0x45700e2au, 0x38de6781u, 0x48109aecu },
            { 0xb68cd95bu, 0x3b133efeu, 0xbd505a45u, 0x373806e0u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0xafc101a4u, 0x410a1333u, 0xb6b50285u, 0x3fcfe677u },
            { 0x3eaab5a1u, 0x457008d4u, 0x3f80037au, 0x48109aacu },
            { 0x3eaaaaabu, 0x4104bdddu, 0x3f7fffa7u, 0x3f1fccecu },
            { 0x410a132du, 0x410a132du, 0x410a132du, 0x410a132du },
            { 0x410a1338u, 0x410a1338u, 0x410a1338u, 0x410a1338u },
            { 0x41240ffcu, 0x41240ffcu, 0x41240ffcu, 0x41240ffcu },
            { 0x3f800000u, 0x410a1333u, 0x38de6781u, 0x373806e0u } } },
        { { { 0x49648cbfu, 0x3ec53312u, 0xb90db749u, 0x3ec95814u },
            { 0x37b46463u, 0x3f427e66u, 0x46a2028du, 0xc5f24288u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0x41a10c95u, 0x3e95d211u, 0xc0335ecbu, 0xc53e8996u },
            { 0x49648cc4u, 0x3d544338u, 0x3f7ff726u, 0xbf1b53f8u },
            { 0x41a3b73fu, 0xbd26c4d0u, 0xbfe6bd95u, 0xc53e9996u },
            { 0x418cf803u, 0x418cf803u, 0x418cf803u, 0x418cf803u },
            { 0xc5f1b590u, 0xc5f1b590u, 0xc5f1b590u, 0xc5f1b590u },
            { 0xc53d6fa5u, 0xc53d6fa5u, 0xc53d6fa5u, 0xc53d6fa5u },
            { 0x3f800000u, 0x3e95d211u, 0xb90db749u, 0xc5f24288u } } },
        { { { 0x42068447u, 0x45e6f4fau, 0xbc2f0011u, 0x3b81ba3cu },
            { 0xc315506bu, 0x80000000u, 0x45b0b3d5u, 0xc7dbf330u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0xc59cea7du, 0x00000000u, 0xc27195f4u, 0xc3deeb1au },
            { 0x4207d99cu, 0x45e6f24fu, 0x3f7d4401u, 0xbf7efc8du },
            { 0xc59ce7d2u, 0xbeaaaaabu, 0xc26d95f3u, 0xc3df6b1au },
            { 0xc59ecda8u, 0xc59ecda8u, 0xc59ecda8u, 0xc59ecda8u },
            { 0xc7e5e00au, 0xc7e5e00au, 0xc7e5e00au, 0xc7e5e00au },
            { 0xc5acbc5au, 0xc5acbc5au, 0xc5acbc5au, 0xc5acbc5au },
            { 0x3f800000u, 0x00000000u, 0xbc2f0011u, 0xc7dbf330u } } },
        { { { 0xbfbd6657u, 0x49d2cfcau, 0xc127fca1u, 0x4257ed8cu },
            { 0xbd37cb7bu, 0xbdda4a9eu, 0xc4adb165u, 0xc0cc3380u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0x3d87fab3u, 0xc833c264u, 0x4663f441u, 0xc3ac3cbbu },
            { 0xbf92bbacu, 0x49d2cfc7u, 0xc117fca0u, 0x4253ed8bu },
            { 0x3ecca957u, 0xc833c279u, 0x4663f841u, 0xc3acbcbbu },
            { 0xc825831bu, 0xc825831bu, 0xc825831bu, 0xc825831bu },
            { 0xc82584b4u, 0xc82584b4u, 0xc82584b4u, 0xc82584b4u },
            { 0xc825d93au, 0xc825d93au, 0xc825d93au, 0xc825d93au },
            { 0x3f800000u, 0xc833c264u, 0xc127fca1u, 0xc0cc3380u } } },
        { { { 0xbc6ef8efu, 0xbf97d182u, 0x80000000u, 0xc7c43004u },
            { 0x3beafb93u, 0x40f54bd6u, 0xc801113du, 0x48d02178u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0xb8db5a61u, 0xc111787au, 0x00000000u, 0xd11f80a9u },
            { 0x3ea332e3u, 0xbfc27c2cu, 0x3f800001u, 0xc7c43084u },
            { 0x3eaa9cf5u, 0xc116cdcfu, 0x3f800001u, 0xd11f80a9u },
            { 0xc11178e7u, 0xc11178e7u, 0xc11178e7u, 0xc11178e7u },
            { 0x48d02055u, 0x48d02055u, 0x48d02055u, 0x48d02055u },
            { 0xd11f80a9u, 0xd11f80a9u, 0xd11f80a9u, 0xd11f80a9u },
            { 0x3f800000u, 0xc111787au, 0x80000000u, 0x48d02178u } } },
        { { { 0x3aa9b717u, 0x373f698au, 0x35ae4b61u, 0x49ca6d4cu },
            { 0xc92ec83bu, 0xbbd9a05eu, 0xc30f8c25u, 0xc52ccf40u },
            { 0x3eaaaaabu, 0xbeaaaaabu, 0x3f800001u, 0xbf800001u } },
          { { 0xc467be5fu, 0xb3a2b85eu, 0xb943770bu, 0xcf88a550u },
            { 0x3eab5462u, 0xbeaaa92cu, 0x3f80000bu, 0x49ca6d44u },
            { 0xc467a909u, 0xbeaaaaadu, 0x3f7ff3cau, 0xcf88a550u },
            { 0xc467be62u, 0xc467be62u, 0xc467be62u, 0xc467be62u },
            { 0xc566bed8u, 0xc566bed8u, 0xc566bed8u, 0xc566bed8u },
            { 0xcf88a551u, 0xcf88a551u, 0xcf88a551u, 0xcf88a551u },
            { 0x3f800000u, 0xb3a2b85eu, 0x35ae4b61u, 0xc52ccf40u } } },
        { { { 0x3f800000u, 0xbf800000u, 0x3f800000u, 0x33800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x33c00000u, 0xb3c00000u, 0xbf800000u, 0xb3800000u } },
          { { 0x3f800000u, 0xbf800000u, 0x3f800000u, 0x33800000u },
            { 0x3f800000u, 0xbf800000u, 0x00000000u, 0x00000000u },
            { 0x3f800000u, 0xbf800000u, 0x00000000u, 0x00000000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x40000000u, 0x40000000u, 0x40000000u, 0x40000000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x3f800000u, 0xbf800000u, 0x3f800000u, 0x3f800000u } } },
        { { { 0x7f800000u, 0xff800000u, 0x7f800000u, 0xff800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0xff800000u, 0x7f800000u, 0x7f800000u, 0xff800000u } },
          { { 0x7f800000u, 0xff800000u, 0x7f800000u, 0xff800000u },
            { 0x7fffffffu, 0x7fffffffu, 0x7f800000u, 0xff800000u },
            { 0x7fffffffu, 0x7fffffffu, 0x7f800000u, 0xff800000u },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x3f800000u, 0xff800000u, 0x7f800000u, 0x3f800000u } } },
        { { { 0x007fffffu, 0x807fffffu, 0x00000001u, 0x80000001u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x007fffffu, 0x807fffffu, 0x007fffffu, 0x807fffffu } },
          { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x00000000u, 0x80000000u, 0x00000000u, 0x80000000u },
            { 0x00000000u, 0x80000000u, 0x00000000u, 0x80000000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x3f800000u, 0x00000000u, 0x00000001u, 0x3f800000u } } },
        { { { 0x3f800000u, 0x33800000u, 0xbf800000u, 0x33800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u } },
          { { 0x3f800000u, 0x33800000u, 0xbf800000u, 0x33800000u },
            { 0x3f800000u, 0x33800000u, 0xbf800000u, 0x33800000u },
            { 0x3f800000u, 0x33800000u, 0xbf800000u, 0x33800000u },
            { 0x33800000u, 0x33800000u, 0x33800000u, 0x33800000u },
            { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
            { 0x34000000u, 0x34000000u, 0x34000000u, 0x34000000u },
            { 0x3f800000u, 0x33800000u, 0xbf800000u, 0x3f800000u } } },
        { { { 0x7f7fffffu, 0xff7fffffu, 0x00800000u, 0x80800000u },
            { 0x40000000u, 0x40000000u, 0x3f000000u, 0x3f000000u },
            { 0x7f7fffffu, 0xff7fffffu, 0x00000000u, 0x00000000u } },
          { { 0x7f7fffffu, 0xff7fffffu, 0x00000000u, 0x80000000u },
            { 0x7f7fffffu, 0xff7fffffu, 0x00800000u, 0x80800000u },
            { 0x7f7fffffu, 0xff7fffffu, 0x00000000u, 0x00000000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x3f800000u, 0xff7fffffu, 0x00800000u, 0x3f000000u } } },
        { { { 0x3f800001u, 0xbf800001u, 0x3f7fffffu, 0xbf7fffffu },
            { 0x3f800001u, 0x3f800001u, 0x3f7fffffu, 0x3f7fffffu },
            { 0xbf800002u, 0x3f800002u, 0xbf7ffffeu, 0x3f7ffffeu } },
          { { 0x3f800002u, 0xbf800002u, 0x3f7ffffeu, 0xbf7ffffeu },
            { 0xb4000000u, 0x34000000u, 0x33800000u, 0xb3800000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x3f7ffffeu, 0x3f7ffffeu, 0x3f7ffffeu, 0x3f7ffffeu },
            { 0x3ffffffeu, 0x3ffffffeu, 0x3ffffffeu, 0x3ffffffeu },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x3f800000u, 0xbf800002u, 0x3f7fffffu, 0x3f7fffffu } } },
        { { { 0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u },
            { 0x7f800000u, 0xff800000u, 0x7fc12345u, 0xff812345u },
            { 0x00000000u, 0x80000000u, 0x00000000u, 0x80000000u } },
          { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x80000000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
            { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
            { 0x3f800000u, 0x00000000u, 0x00000001u, 0xff812345u } } },
        { { { 0x3f800000u, 0xbf800000u, 0x3f000000u, 0xbf000000u },
            { 0x3f800001u, 0xbf800001u, 0x3f800001u, 0xbf800001u },
            { 0x00000001u, 0x80000001u, 0x007fffffu, 0x807fffffu } },
          { { 0x3f800001u, 0x3f800001u, 0x3f000001u, 0x3f000001u },
            { 0x3f800000u, 0xbf800000u, 0x3f000000u, 0xbf000000u },
            { 0x3f800001u, 0x3f800001u, 0x3f000001u, 0x3f000001u },
            { 0x40200001u, 0x40200001u, 0x40200001u, 0x40200001u },
            { 0x3fc00001u, 0x3fc00001u, 0x3fc00001u, 0x3fc00001u },
            { 0x40400001u, 0x40400001u, 0x40400001u, 0x40400001u },
            { 0x3f800000u, 0x3f800001u, 0x3f000000u, 0xbf800001u } } }
    };
    enum { Count = sizeof(cases) / sizeof(cases[0]) };
    NV2AMetalProgramInput input[Count] = { 0 };
    for (unsigned i = 0; i < Count; i++) {
        memcpy(input[i].attributes, cases[i].input, sizeof(cases[i].input));
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalProgramUniforms u = uniforms(), original = u;
    for (unsigned opcode = NV2AMetalMACMul; opcode <= NV2AMetalMACDst;
         opcode++) {
        Token tokens[] = { token(NV2AMetalMACMov, 0, 1, 0),
                           token(NV2AMetalMACMov, 0, 2, 0),
                           token(opcode, 0, 0, 0) };
        destination(&tokens[0], 0, 0, 0, 2, 15, 0);
        destination(&tokens[1], 0, 0, 0, 3, 15, 0);
        tokens[0].word[3] &= ~1u;
        tokens[1].word[3] &= ~1u;
        source(&tokens[2], 0, 2, 0, 0xe4, NO);
        source(&tokens[2], 1, 1, 2, 0xe4, NO);
        source(&tokens[2], 2, 1, 3, 0xe4, NO);
        destination(&tokens[2], 3, 15, 0, 0, 0, 0);
        begin(commands);
        NV2AMetalProgramResult *result =
            encode(executor, commands, tokens, 3, &u, attributes, Count);
        finish(commands);
        const NV2AMetalProgramOutput *out = raw(result);
        for (unsigned i = 0; i < Count; i++) {
            for (unsigned k = 0; k < 4; k++) {
                uint32_t actual;
                memcpy(&actual, &out[i].registers[3][k], sizeof(actual));
                uint32_t expected =
                    cases[i].expected[opcode - NV2AMetalMACMul][k];
                if (actual != expected) {
                    fprintf(stderr,
                            "Kelvin arithmetic opcode%u case%u channel%u: "
                            "%08x expected %08x\n",
                            opcode, i, k, actual, expected);
                    abort();
                }
            }
        }
        assert(memcmp(attributes.contents, input, sizeof(input)) == 0);
        assert(memcmp(&u, &original, sizeof(u)) == 0);
    }
    printf("Metal4 Kelvin arithmetic: %u cases/%u raw channels PASS\n",
           7u * Count, 28u * Count);
}

static void ilu_special_values(NV2AMetalVertexProgram *executor,
                               NV2AMetalCommands *commands)
{
    /* Same historical special-case inputs, with fixed raw Kelvin model
     * outputs from original envytools functions instead of host exp/log.
     */
    const struct {
        unsigned opcode;
        uint32_t input[4];
        uint32_t expected[4];
    } cases[] = {
        { 5,
          { 0x7f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f800000u, 0x00000000u, 0x7f800000u, 0x3f800000u } },
        { 5,
          { 0xff800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x00000000u, 0x00000000u, 0x00000000u, 0x3f800000u } },
        { 5,
          { 0x7f7fffffu, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f800000u, 0x00000000u, 0x7f800000u, 0x3f800000u } },
        { 5,
          { 0xff7fffffu, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x00000000u, 0x00000000u, 0x00000000u, 0x3f800000u } },
        { 5,
          { 0x43008000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f800000u, 0x3f000000u, 0x7f800000u, 0x3f800000u } },
        { 5,
          { 0xc3168000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x00000000u, 0x3f000000u, 0x00000000u, 0x3f800000u } },
        { 5,
          { 0xc2fd0000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x00000000u, 0x3f000000u, 0x00000000u, 0x3f800000u } },
        { 5,
          { 0x42ff0000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f000000u, 0x3f000000u, 0x7f350600u, 0x3f800000u } },
        { 5,
          { 0x7fc00000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f800000u, 0x7fc00000u, 0x7fffffffu, 0x3f800000u } },
        { 5,
          { 0x42fe0000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f000000u, 0x00000000u, 0x7f000000u, 0x3f800000u } },
        { 5,
          { 0xc2fc0000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x00800000u, 0x00000000u, 0x00800000u, 0x3f800000u } },
        { 5,
          { 0x40200000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x40800000u, 0x3f000000u, 0x40b50600u, 0x3f800000u } },
        { 5,
          { 0xc0200000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x3e000000u, 0x3f000000u, 0x3e350600u, 0x3f800000u } },
        { 5,
          { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u } },
        { 5,
          { 0x80000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x00000000u, 0x3f800000u, 0x3f800000u } },
        { 6,
          { 0x7f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } },
        { 6,
          { 0xff800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } },
        { 6,
          { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
        { 6,
          { 0x80000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
        { 6,
          { 0x7fc00000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x7fc00000u, 0x7fc00000u, 0x7fc00000u, 0x3f800000u } },
        { 6,
          { 0x3f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u } },
        { 6,
          { 0x40000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } },
        { 6,
          { 0x40400000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x3fc00000u, 0x3fcae3c0u, 0x3f800000u } },
        { 6,
          { 0x3f000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0xbf800000u, 0x3f800000u, 0xbf800000u, 0x3f800000u } },
        { 6,
          { 0x00800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0xc2fc0000u, 0x3f800000u, 0xc2fc0000u, 0x3f800000u } },
        { 6,
          { 0x7f7fffffu, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x42fe0000u, 0x3fffffffu, 0x42fffff3u, 0x3f800000u } },
        { 6,
          { 0x3fffffffu, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x00000000u, 0x3fffffffu, 0x3f7ff9f5u, 0x3f800000u } },
        { 6,
          { 0x3f7fffffu, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0xbf800000u, 0x3fffffffu, 0xb8c15000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x00000000u, 0x00000000u, 0x80000000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x80000000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0xbf800000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u },
          { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x00000000u, 0x00000000u, 0xbf800000u },
          { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x7f800000u, 0x00000000u, 0x3f800000u },
          { 0x3f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } },
        { 7,
          { 0x3f800000u, 0x7f800000u, 0x00000000u, 0xbf800000u },
          { 0x3f800000u, 0x3f800000u, 0x00000000u, 0x3f800000u } },
        { 7,
          { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } },
        { 7,
          { 0xbf800000u, 0x7f800000u, 0x00000000u, 0x00000000u },
          { 0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u } },
        { 7,
          { 0x40200000u, 0x40400000u, 0x40800000u, 0x40000000u },
          { 0x3f800000u, 0x40200000u, 0x41100520u, 0x3f800000u } },
    };
    NV2AMetalProgramUniforms u = uniforms();
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        NV2AMetalProgramInput input = { 0 };
        memcpy(input.attributes[0], cases[i].input, sizeof(cases[i].input));
        id<MTLBuffer> attributes =
            [commands.device newBufferWithBytes:&input
                                         length:sizeof(input)
                                        options:MTLResourceStorageModeShared];
        Token t = token(0, cases[i].opcode, 0, 0);
        source(&t, 2, 2, 0, 0xe4, NO);
        destination(&t, 3, 15, 1, 0, 0, 0);
        begin(commands);
        NV2AMetalProgramResult *result =
            encode(executor, commands, &t, 1, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            uint32_t actual;
            memcpy(&actual, &raw(result)->registers[3][k], 4);
            if (actual != cases[i].expected[k]) {
                fprintf(stderr,
                        "ILU case%u opcode%u channel%u: %08x expected %08x\n",
                        i, cases[i].opcode, k, actual, cases[i].expected[k]);
                abort();
            }
        }
    }
    printf("Metal4 ILU special values: 40 cases/160 raw channels PASS\n");
}

static void log_power_boundaries(NV2AMetalVertexProgram *executor,
                                 NV2AMetalCommands *commands)
{
    /* Original xf_log(version2, FP_ZERO_WINS) for each positive input;
     * negative partners have the same magnitude result.
     */
    static const uint32_t zExpected[761] = {
        0xc2fc0000u, 0xc2fc0000u, 0xc2fa000cu, 0xc2fa0000u, 0xc2fa0000u,
        0xc2f8000cu, 0xc2f80000u, 0xc2f80000u, 0xc2f6000cu, 0xc2f60000u,
        0xc2f60000u, 0xc2f4000cu, 0xc2f40000u, 0xc2f40000u, 0xc2f2000cu,
        0xc2f20000u, 0xc2f20000u, 0xc2f0000cu, 0xc2f00000u, 0xc2f00000u,
        0xc2ee000cu, 0xc2ee0000u, 0xc2ee0000u, 0xc2ec000cu, 0xc2ec0000u,
        0xc2ec0000u, 0xc2ea000cu, 0xc2ea0000u, 0xc2ea0000u, 0xc2e8000cu,
        0xc2e80000u, 0xc2e80000u, 0xc2e6000cu, 0xc2e60000u, 0xc2e60000u,
        0xc2e4000cu, 0xc2e40000u, 0xc2e40000u, 0xc2e2000cu, 0xc2e20000u,
        0xc2e20000u, 0xc2e0000cu, 0xc2e00000u, 0xc2e00000u, 0xc2de000cu,
        0xc2de0000u, 0xc2de0000u, 0xc2dc000cu, 0xc2dc0000u, 0xc2dc0000u,
        0xc2da000cu, 0xc2da0000u, 0xc2da0000u, 0xc2d8000cu, 0xc2d80000u,
        0xc2d80000u, 0xc2d6000cu, 0xc2d60000u, 0xc2d60000u, 0xc2d4000cu,
        0xc2d40000u, 0xc2d40000u, 0xc2d2000cu, 0xc2d20000u, 0xc2d20000u,
        0xc2d0000cu, 0xc2d00000u, 0xc2d00000u, 0xc2ce000cu, 0xc2ce0000u,
        0xc2ce0000u, 0xc2cc000cu, 0xc2cc0000u, 0xc2cc0000u, 0xc2ca000cu,
        0xc2ca0000u, 0xc2ca0000u, 0xc2c8000cu, 0xc2c80000u, 0xc2c80000u,
        0xc2c6000cu, 0xc2c60000u, 0xc2c60000u, 0xc2c4000cu, 0xc2c40000u,
        0xc2c40000u, 0xc2c2000cu, 0xc2c20000u, 0xc2c20000u, 0xc2c0000cu,
        0xc2c00000u, 0xc2c00000u, 0xc2be000cu, 0xc2be0000u, 0xc2be0000u,
        0xc2bc000cu, 0xc2bc0000u, 0xc2bc0000u, 0xc2ba000cu, 0xc2ba0000u,
        0xc2ba0000u, 0xc2b8000cu, 0xc2b80000u, 0xc2b80000u, 0xc2b6000cu,
        0xc2b60000u, 0xc2b60000u, 0xc2b4000cu, 0xc2b40000u, 0xc2b40000u,
        0xc2b2000cu, 0xc2b20000u, 0xc2b20000u, 0xc2b0000cu, 0xc2b00000u,
        0xc2b00000u, 0xc2ae000cu, 0xc2ae0000u, 0xc2ae0000u, 0xc2ac000cu,
        0xc2ac0000u, 0xc2ac0000u, 0xc2aa000cu, 0xc2aa0000u, 0xc2aa0000u,
        0xc2a8000cu, 0xc2a80000u, 0xc2a80000u, 0xc2a6000cu, 0xc2a60000u,
        0xc2a60000u, 0xc2a4000cu, 0xc2a40000u, 0xc2a40000u, 0xc2a2000cu,
        0xc2a20000u, 0xc2a20000u, 0xc2a0000cu, 0xc2a00000u, 0xc2a00000u,
        0xc29e000cu, 0xc29e0000u, 0xc29e0000u, 0xc29c000cu, 0xc29c0000u,
        0xc29c0000u, 0xc29a000cu, 0xc29a0000u, 0xc29a0000u, 0xc298000cu,
        0xc2980000u, 0xc2980000u, 0xc296000cu, 0xc2960000u, 0xc2960000u,
        0xc294000cu, 0xc2940000u, 0xc2940000u, 0xc292000cu, 0xc2920000u,
        0xc2920000u, 0xc290000cu, 0xc2900000u, 0xc2900000u, 0xc28e000cu,
        0xc28e0000u, 0xc28e0000u, 0xc28c000cu, 0xc28c0000u, 0xc28c0000u,
        0xc28a000cu, 0xc28a0000u, 0xc28a0000u, 0xc288000cu, 0xc2880000u,
        0xc2880000u, 0xc286000cu, 0xc2860000u, 0xc2860000u, 0xc284000cu,
        0xc2840000u, 0xc2840000u, 0xc282000cu, 0xc2820000u, 0xc2820000u,
        0xc280000cu, 0xc2800000u, 0xc2800000u, 0xc27c0018u, 0xc27c0000u,
        0xc27c0000u, 0xc2780018u, 0xc2780000u, 0xc2780000u, 0xc2740018u,
        0xc2740000u, 0xc2740000u, 0xc2700018u, 0xc2700000u, 0xc2700000u,
        0xc26c0018u, 0xc26c0000u, 0xc26c0000u, 0xc2680018u, 0xc2680000u,
        0xc2680000u, 0xc2640018u, 0xc2640000u, 0xc2640000u, 0xc2600018u,
        0xc2600000u, 0xc2600000u, 0xc25c0018u, 0xc25c0000u, 0xc25c0000u,
        0xc2580018u, 0xc2580000u, 0xc2580000u, 0xc2540018u, 0xc2540000u,
        0xc2540000u, 0xc2500018u, 0xc2500000u, 0xc2500000u, 0xc24c0018u,
        0xc24c0000u, 0xc24c0000u, 0xc2480018u, 0xc2480000u, 0xc2480000u,
        0xc2440018u, 0xc2440000u, 0xc2440000u, 0xc2400018u, 0xc2400000u,
        0xc2400000u, 0xc23c0018u, 0xc23c0000u, 0xc23c0000u, 0xc2380018u,
        0xc2380000u, 0xc2380000u, 0xc2340018u, 0xc2340000u, 0xc2340000u,
        0xc2300018u, 0xc2300000u, 0xc2300000u, 0xc22c0018u, 0xc22c0000u,
        0xc22c0000u, 0xc2280018u, 0xc2280000u, 0xc2280000u, 0xc2240018u,
        0xc2240000u, 0xc2240000u, 0xc2200018u, 0xc2200000u, 0xc2200000u,
        0xc21c0018u, 0xc21c0000u, 0xc21c0000u, 0xc2180018u, 0xc2180000u,
        0xc2180000u, 0xc2140018u, 0xc2140000u, 0xc2140000u, 0xc2100018u,
        0xc2100000u, 0xc2100000u, 0xc20c0018u, 0xc20c0000u, 0xc20c0000u,
        0xc2080018u, 0xc2080000u, 0xc2080000u, 0xc2040018u, 0xc2040000u,
        0xc2040000u, 0xc2000018u, 0xc2000000u, 0xc2000000u, 0xc1f80030u,
        0xc1f80000u, 0xc1f80000u, 0xc1f00030u, 0xc1f00000u, 0xc1f00000u,
        0xc1e80030u, 0xc1e80000u, 0xc1e80000u, 0xc1e00030u, 0xc1e00000u,
        0xc1e00000u, 0xc1d80030u, 0xc1d80000u, 0xc1d80000u, 0xc1d00030u,
        0xc1d00000u, 0xc1d00000u, 0xc1c80030u, 0xc1c80000u, 0xc1c80000u,
        0xc1c00030u, 0xc1c00000u, 0xc1c00000u, 0xc1b80030u, 0xc1b80000u,
        0xc1b80000u, 0xc1b00030u, 0xc1b00000u, 0xc1b00000u, 0xc1a80030u,
        0xc1a80000u, 0xc1a80000u, 0xc1a00030u, 0xc1a00000u, 0xc1a00000u,
        0xc1980030u, 0xc1980000u, 0xc1980000u, 0xc1900030u, 0xc1900000u,
        0xc1900000u, 0xc1880030u, 0xc1880000u, 0xc1880000u, 0xc1800030u,
        0xc1800000u, 0xc1800000u, 0xc1700060u, 0xc1700000u, 0xc1700000u,
        0xc1600060u, 0xc1600000u, 0xc1600000u, 0xc1500060u, 0xc1500000u,
        0xc1500000u, 0xc1400060u, 0xc1400000u, 0xc1400000u, 0xc1300060u,
        0xc1300000u, 0xc1300000u, 0xc1200060u, 0xc1200000u, 0xc1200000u,
        0xc1100060u, 0xc1100000u, 0xc1100000u, 0xc1000060u, 0xc1000000u,
        0xc1000000u, 0xc0e000c1u, 0xc0e00000u, 0xc0e00000u, 0xc0c000c1u,
        0xc0c00000u, 0xc0c00000u, 0xc0a000c1u, 0xc0a00000u, 0xc0a00000u,
        0xc08000c1u, 0xc0800000u, 0xc0800000u, 0xc0400182u, 0xc0400000u,
        0xc0400000u, 0xc0000182u, 0xc0000000u, 0xc0000000u, 0xbf800305u,
        0xbf800000u, 0xbf800000u, 0xb8c15000u, 0x00000000u, 0x00000000u,
        0x3f7ff9f5u, 0x3f800000u, 0x3f800000u, 0x3ffffcfau, 0x40000000u,
        0x40000000u, 0x403ffe7du, 0x40400000u, 0x40400000u, 0x407ffe7du,
        0x40800000u, 0x40800000u, 0x409fff3eu, 0x40a00000u, 0x40a00000u,
        0x40bfff3eu, 0x40c00000u, 0x40c00000u, 0x40dfff3eu, 0x40e00000u,
        0x40e00000u, 0x40ffff3eu, 0x41000000u, 0x41000000u, 0x410fff9fu,
        0x41100000u, 0x41100000u, 0x411fff9fu, 0x41200000u, 0x41200000u,
        0x412fff9fu, 0x41300000u, 0x41300000u, 0x413fff9fu, 0x41400000u,
        0x41400000u, 0x414fff9fu, 0x41500000u, 0x41500000u, 0x415fff9fu,
        0x41600000u, 0x41600000u, 0x416fff9fu, 0x41700000u, 0x41700000u,
        0x417fff9fu, 0x41800000u, 0x41800000u, 0x4187ffcfu, 0x41880000u,
        0x41880000u, 0x418fffcfu, 0x41900000u, 0x41900000u, 0x4197ffcfu,
        0x41980000u, 0x41980000u, 0x419fffcfu, 0x41a00000u, 0x41a00000u,
        0x41a7ffcfu, 0x41a80000u, 0x41a80000u, 0x41afffcfu, 0x41b00000u,
        0x41b00000u, 0x41b7ffcfu, 0x41b80000u, 0x41b80000u, 0x41bfffcfu,
        0x41c00000u, 0x41c00000u, 0x41c7ffcfu, 0x41c80000u, 0x41c80000u,
        0x41cfffcfu, 0x41d00000u, 0x41d00000u, 0x41d7ffcfu, 0x41d80000u,
        0x41d80000u, 0x41dfffcfu, 0x41e00000u, 0x41e00000u, 0x41e7ffcfu,
        0x41e80000u, 0x41e80000u, 0x41efffcfu, 0x41f00000u, 0x41f00000u,
        0x41f7ffcfu, 0x41f80000u, 0x41f80000u, 0x41ffffcfu, 0x42000000u,
        0x42000000u, 0x4203ffe7u, 0x42040000u, 0x42040000u, 0x4207ffe7u,
        0x42080000u, 0x42080000u, 0x420bffe7u, 0x420c0000u, 0x420c0000u,
        0x420fffe7u, 0x42100000u, 0x42100000u, 0x4213ffe7u, 0x42140000u,
        0x42140000u, 0x4217ffe7u, 0x42180000u, 0x42180000u, 0x421bffe7u,
        0x421c0000u, 0x421c0000u, 0x421fffe7u, 0x42200000u, 0x42200000u,
        0x4223ffe7u, 0x42240000u, 0x42240000u, 0x4227ffe7u, 0x42280000u,
        0x42280000u, 0x422bffe7u, 0x422c0000u, 0x422c0000u, 0x422fffe7u,
        0x42300000u, 0x42300000u, 0x4233ffe7u, 0x42340000u, 0x42340000u,
        0x4237ffe7u, 0x42380000u, 0x42380000u, 0x423bffe7u, 0x423c0000u,
        0x423c0000u, 0x423fffe7u, 0x42400000u, 0x42400000u, 0x4243ffe7u,
        0x42440000u, 0x42440000u, 0x4247ffe7u, 0x42480000u, 0x42480000u,
        0x424bffe7u, 0x424c0000u, 0x424c0000u, 0x424fffe7u, 0x42500000u,
        0x42500000u, 0x4253ffe7u, 0x42540000u, 0x42540000u, 0x4257ffe7u,
        0x42580000u, 0x42580000u, 0x425bffe7u, 0x425c0000u, 0x425c0000u,
        0x425fffe7u, 0x42600000u, 0x42600000u, 0x4263ffe7u, 0x42640000u,
        0x42640000u, 0x4267ffe7u, 0x42680000u, 0x42680000u, 0x426bffe7u,
        0x426c0000u, 0x426c0000u, 0x426fffe7u, 0x42700000u, 0x42700000u,
        0x4273ffe7u, 0x42740000u, 0x42740000u, 0x4277ffe7u, 0x42780000u,
        0x42780000u, 0x427bffe7u, 0x427c0000u, 0x427c0000u, 0x427fffe7u,
        0x42800000u, 0x42800000u, 0x4281fff3u, 0x42820000u, 0x42820000u,
        0x4283fff3u, 0x42840000u, 0x42840000u, 0x4285fff3u, 0x42860000u,
        0x42860000u, 0x4287fff3u, 0x42880000u, 0x42880000u, 0x4289fff3u,
        0x428a0000u, 0x428a0000u, 0x428bfff3u, 0x428c0000u, 0x428c0000u,
        0x428dfff3u, 0x428e0000u, 0x428e0000u, 0x428ffff3u, 0x42900000u,
        0x42900000u, 0x4291fff3u, 0x42920000u, 0x42920000u, 0x4293fff3u,
        0x42940000u, 0x42940000u, 0x4295fff3u, 0x42960000u, 0x42960000u,
        0x4297fff3u, 0x42980000u, 0x42980000u, 0x4299fff3u, 0x429a0000u,
        0x429a0000u, 0x429bfff3u, 0x429c0000u, 0x429c0000u, 0x429dfff3u,
        0x429e0000u, 0x429e0000u, 0x429ffff3u, 0x42a00000u, 0x42a00000u,
        0x42a1fff3u, 0x42a20000u, 0x42a20000u, 0x42a3fff3u, 0x42a40000u,
        0x42a40000u, 0x42a5fff3u, 0x42a60000u, 0x42a60000u, 0x42a7fff3u,
        0x42a80000u, 0x42a80000u, 0x42a9fff3u, 0x42aa0000u, 0x42aa0000u,
        0x42abfff3u, 0x42ac0000u, 0x42ac0000u, 0x42adfff3u, 0x42ae0000u,
        0x42ae0000u, 0x42affff3u, 0x42b00000u, 0x42b00000u, 0x42b1fff3u,
        0x42b20000u, 0x42b20000u, 0x42b3fff3u, 0x42b40000u, 0x42b40000u,
        0x42b5fff3u, 0x42b60000u, 0x42b60000u, 0x42b7fff3u, 0x42b80000u,
        0x42b80000u, 0x42b9fff3u, 0x42ba0000u, 0x42ba0000u, 0x42bbfff3u,
        0x42bc0000u, 0x42bc0000u, 0x42bdfff3u, 0x42be0000u, 0x42be0000u,
        0x42bffff3u, 0x42c00000u, 0x42c00000u, 0x42c1fff3u, 0x42c20000u,
        0x42c20000u, 0x42c3fff3u, 0x42c40000u, 0x42c40000u, 0x42c5fff3u,
        0x42c60000u, 0x42c60000u, 0x42c7fff3u, 0x42c80000u, 0x42c80000u,
        0x42c9fff3u, 0x42ca0000u, 0x42ca0000u, 0x42cbfff3u, 0x42cc0000u,
        0x42cc0000u, 0x42cdfff3u, 0x42ce0000u, 0x42ce0000u, 0x42cffff3u,
        0x42d00000u, 0x42d00000u, 0x42d1fff3u, 0x42d20000u, 0x42d20000u,
        0x42d3fff3u, 0x42d40000u, 0x42d40000u, 0x42d5fff3u, 0x42d60000u,
        0x42d60000u, 0x42d7fff3u, 0x42d80000u, 0x42d80000u, 0x42d9fff3u,
        0x42da0000u, 0x42da0000u, 0x42dbfff3u, 0x42dc0000u, 0x42dc0000u,
        0x42ddfff3u, 0x42de0000u, 0x42de0000u, 0x42dffff3u, 0x42e00000u,
        0x42e00000u, 0x42e1fff3u, 0x42e20000u, 0x42e20000u, 0x42e3fff3u,
        0x42e40000u, 0x42e40000u, 0x42e5fff3u, 0x42e60000u, 0x42e60000u,
        0x42e7fff3u, 0x42e80000u, 0x42e80000u, 0x42e9fff3u, 0x42ea0000u,
        0x42ea0000u, 0x42ebfff3u, 0x42ec0000u, 0x42ec0000u, 0x42edfff3u,
        0x42ee0000u, 0x42ee0000u, 0x42effff3u, 0x42f00000u, 0x42f00000u,
        0x42f1fff3u, 0x42f20000u, 0x42f20000u, 0x42f3fff3u, 0x42f40000u,
        0x42f40000u, 0x42f5fff3u, 0x42f60000u, 0x42f60000u, 0x42f7fff3u,
        0x42f80000u, 0x42f80000u, 0x42f9fff3u, 0x42fa0000u, 0x42fa0000u,
        0x42fbfff3u, 0x42fc0000u, 0x42fc0000u, 0x42fdfff3u, 0x42fe0000u,
        0x42fe0000u,
    };
    NV2AMetalProgramInput input[1524] = { 0 };
    unsigned count = 0;
    for (int exponent = -126; exponent <= 127; exponent++) {
        float power = ldexpf(1, exponent);
        float values[] = { nextafterf(power, 0), power,
                           nextafterf(power, INFINITY) };
        for (unsigned k = 0; k < 3; k++) {
            if (values[k] >= FLT_MIN) {
                input[count++].attributes[0][0] = values[k];
                input[count++].attributes[0][0] = -values[k];
            }
        }
    }
    assert(count == 1522);
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:count * sizeof(input[0])
                                    options:MTLResourceStorageModeShared];
    NV2AMetalProgramUniforms u = uniforms();
    Token t = token(0, NV2AMetalILULog, 0, 0);
    source(&t, 2, 2, 0, 0xe4, NO);
    destination(&t, 3, 15, 1, 0, 0, 0);
    begin(commands);
    NV2AMetalProgramResult *result =
        encode(executor, commands, &t, 1, &u, attributes, count);
    finish(commands);
    const NV2AMetalProgramOutput *outputs = raw(result);
    for (unsigned i = 0; i < count; i++) {
        float value = fabsf(input[i].attributes[0][0]), mantissa;
        uint32_t bits;
        memcpy(&bits, &value, sizeof(bits));
        int exponent = (int)((bits >> 23) & 255) - 127;
        bits = (bits & 0x7fffff) | 0x3f800000;
        memcpy(&mantissa, &bits, sizeof(mantissa));
        const float *v = outputs[i].registers[3];
        if (v[0] != exponent || v[1] != mantissa || v[3] != 1) {
            fprintf(stderr,
                    "LOG boundary %a: exponent %g expected %d, "
                    "mantissa %a expected %a, W %g\n",
                    input[i].attributes[0][0], v[0], exponent, v[1], mantissa,
                    v[3]);
            abort();
        }
        uint32_t actual;
        memcpy(&actual, &v[2], sizeof(actual));
        if (actual != zExpected[i / 2]) {
            fprintf(stderr, "LOG boundary%u Z %08x expected %08x\n", i, actual,
                    zExpected[i / 2]);
            abort();
        }
    }
    printf("Metal4 LOG power boundaries: 1522 inputs/6088 raw channels PASS\n");
}

static void mac_zero_products(NV2AMetalVertexProgram *executor,
                              NV2AMetalCommands *commands)
{
    /* NV_vertex_program 2.14.1.11: zero products are positive zero even
     * with infinity/NaN. DPH replaces A.w with one before multiplication.
     */
    const unsigned opcodes[] = { NV2AMetalMACMul, NV2AMetalMACMad,
                                 NV2AMetalMACDp3, NV2AMetalMACDph,
                                 NV2AMetalMACDp4, NV2AMetalMACDst };
    const float exceptional[] = { INFINITY, -INFINITY, NAN, -NAN };
    unsigned cases = 0;
    for (unsigned op = 0; op < sizeof(opcodes) / sizeof(opcodes[0]); op++) {
        for (unsigned e = 0; e < 4; e++) {
            for (unsigned negative = 0; negative < 2; negative++) {
                for (unsigned swap = 0; swap < 2; swap++) {
                    for (unsigned lane = 0; lane < 5; lane++) {
                        float a[] = { 2, 3, 4, 5 }, b[] = { -2, -3, -4, -5 },
                              c[] = { 1, 2, 3, 4 }, product[4], expected[4];
                        for (unsigned k = 0; k < 4; k++) {
                            if (lane == k || lane == 4) {
                                a[k] = negative ? -0.0f : 0.0f;
                                b[k] = exceptional[e];
                            }
                            if (swap) {
                                float tmp = a[k];
                                a[k] = b[k];
                                b[k] = tmp;
                            }
                            float first =
                                opcodes[op] == NV2AMetalMACDph && k == 3 ?
                                    1.0f :
                                    a[k];
                            product[k] =
                                first == 0 || b[k] == 0 ? 0.0f : first * b[k];
                            expected[k] = product[k];
                            if (opcodes[op] == NV2AMetalMACMad) {
                                expected[k] += c[k];
                            }
                        }
                        if (opcodes[op] == NV2AMetalMACDp3 ||
                            opcodes[op] == NV2AMetalMACDph ||
                            opcodes[op] == NV2AMetalMACDp4) {
                            float sum = product[0] + product[1] + product[2];
                            if (opcodes[op] != NV2AMetalMACDp3) {
                                sum += product[3];
                            }
                            for (unsigned k = 0; k < 4; k++) {
                                expected[k] = sum;
                            }
                        } else if (opcodes[op] == NV2AMetalMACDst) {
                            expected[0] = 1;
                            expected[1] = product[1];
                            expected[2] = a[2];
                            expected[3] = b[3];
                        }
                        NV2AMetalProgramInput input = { 0 };
                        memcpy(input.attributes[0], a, sizeof(a));
                        memcpy(input.attributes[1], c, sizeof(c));
                        NV2AMetalProgramUniforms u = uniforms();
                        memcpy(u.constants[0], b, sizeof(b));
                        id<MTLBuffer> attributes = [commands.device
                            newBufferWithBytes:&input
                                        length:sizeof(input)
                                       options:MTLResourceStorageModeShared];
                        Token tokens[] = { token(NV2AMetalMACMov, 0, 1, 0),
                                           token(opcodes[op], 0, 0, 0) };
                        destination(&tokens[0], 0, 0, 0, 2, 15, 0);
                        tokens[0].word[3] &= ~1u;
                        source(&tokens[1], 0, 2, 0, 0xe4, NO);
                        source(&tokens[1], 1, 3, 0, 0xe4, NO);
                        source(&tokens[1], 2, 1, 2, 0xe4, NO);
                        destination(&tokens[1], 3, 15, 0, 0, 0, 0);
                        begin(commands);
                        NV2AMetalProgramResult *result = encode(
                            executor, commands, tokens, 2, &u, attributes, 1);
                        finish(commands);
                        const float *v = raw(result)->registers[3];
                        for (unsigned k = 0; k < 4; k++) {
                            BOOL same = isnan(expected[k]) ?
                                            isnan(v[k]) :
                                            v[k] == expected[k] &&
                                                (v[k] != 0 ||
                                                 !!signbit(v[k]) ==
                                                     !!signbit(expected[k]));
                            if (!same) {
                                fprintf(stderr,
                                        "MAC zero case %u opcode %u "
                                        "exception%u negative%u swap%u "
                                        "lane%u channel%u: %a expected %a\n",
                                        cases, opcodes[op], e, negative, swap,
                                        lane, k, v[k], expected[k]);
                                abort();
                            }
                        }
                        cases++;
                    }
                }
            }
        }
    }
    assert(cases == 480);
    printf("Metal4 MAC zero products: 480 cases/1920 raw channels PASS\n");
}

static void comparison_classes(NV2AMetalVertexProgram *executor,
                               NV2AMetalCommands *commands)
{
    /* NV_vertex_program 2.14.1.11 orders signed zero and signed NaN classes.
     * Same-sign NaN pairs are not specified here and are excluded.
     */
    const uint32_t payload[] = { 0x7fc00001, 0x7fffffff, 0x7f800001,
                                 0x7f9fffff };
    NV2AMetalProgramInput input[264] = { 0 };
    float expected[2][264][4] = { 0 };
    unsigned count = 0;
    for (unsigned p = 0; p < 4; p++) {
        float positiveNaN, negativeNaN;
        uint32_t negativeBits = payload[p] | 0x80000000u;
        memcpy(&positiveNaN, &payload[p], sizeof(positiveNaN));
        memcpy(&negativeNaN, &negativeBits, sizeof(negativeNaN));
        float values[] = { negativeNaN, -INFINITY, -1,       -0.0f,
                           0,           1,         INFINITY, positiveNaN };
        for (unsigned a = 0; a < 8; a++) {
            for (unsigned b = 0; b < 8; b++) {
                if (a == b && (a == 0 || a == 7)) {
                    continue;
                }
                for (unsigned k = 0; k < 4; k++) {
                    input[count].attributes[0][k] = values[a];
                    input[count].attributes[1][k] = values[b];
                    expected[0][count][k] = a < b;
                    expected[1][count][k] = a >= b;
                }
                count++;
            }
        }
        const unsigned lanes[][2][4] = {
            { { 0, 7, 3, 4 }, { 1, 6, 4, 3 } },
            { { 2, 5, 1, 6 }, { 7, 0, 6, 1 } },
        };
        for (unsigned vector = 0; vector < 2; vector++) {
            for (unsigned swap = 0; swap < 2; swap++) {
                for (unsigned k = 0; k < 4; k++) {
                    unsigned a = lanes[vector][swap][k];
                    unsigned b = lanes[vector][!swap][k];
                    input[count].attributes[0][k] = values[a];
                    input[count].attributes[1][k] = values[b];
                    expected[0][count][k] = a < b;
                    expected[1][count][k] = a >= b;
                }
                count++;
            }
        }
    }
    assert(count == 264);
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalProgramUniforms u = uniforms();
    const unsigned opcodes[] = { NV2AMetalMACSlt, NV2AMetalMACSge };
    for (unsigned op = 0; op < 2; op++) {
        Token tokens[] = { token(NV2AMetalMACMov, 0, 1, 0),
                           token(opcodes[op], 0, 0, 0) };
        destination(&tokens[0], 0, 0, 0, 2, 15, 0);
        tokens[0].word[3] &= ~1u;
        source(&tokens[1], 0, 2, 0, 0xe4, NO);
        source(&tokens[1], 1, 1, 2, 0xe4, NO);
        destination(&tokens[1], 3, 15, 0, 0, 0, 0);
        begin(commands);
        NV2AMetalProgramResult *result =
            encode(executor, commands, tokens, 2, &u, attributes, count);
        finish(commands);
        const NV2AMetalProgramOutput *outputs = raw(result);
        for (unsigned i = 0; i < count; i++) {
            for (unsigned k = 0; k < 4; k++) {
                float value = outputs[i].registers[3][k];
                if (value != expected[op][i][k]) {
                    fprintf(stderr,
                            "Comparison opcode%u case%u channel%u: "
                            "%g expected %g (A=%a B=%a)\n",
                            opcodes[op], i, k, value, expected[op][i][k],
                            input[i].attributes[0][k],
                            input[i].attributes[1][k]);
                    abort();
                }
            }
        }
    }
    printf("Metal4 SLT/SGE classes: 528 cases/2112 raw channels PASS\n");
}

static void denormal_sources(NV2AMetalVertexProgram *executor,
                             NV2AMetalCommands *commands)
{
    /* Kelvin MOV and comparisons preserve source bits. Scalar
     * opcode classes use fixed raw original family-model results.
     */
    const uint32_t bits[][4] = {
        { 0x00000001, 0x80000001, 0x007fffff, 0x807fffff },
        { 0x00000000, 0x80000000, 0x00400000, 0x80400000 },
        { 0x00800000, 0x80800000, 0x00800001, 0x80800001 },
        { 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000 },
        { 0x7fc00001, 0xffc00001, 0x7f800001, 0xff800001 },
        { 0x00000100, 0x80000100, 0x007ffffe, 0x807ffffe },
    };
    /* Original scalar results, indexed by group/component/negate/opcode. */
    static const uint32_t scalarExpected[6][4][2][2][4] = {
        { { { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } } },
        { { { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } } },
        { { { { 0x7e800000u, 0x7e800000u, 0x7e800000u, 0x7e800000u },
              { 0xc2fc0000u, 0x3f800000u, 0xc2fc0000u, 0x3f800000u } },
            { { 0xfe800000u, 0xfe800000u, 0xfe800000u, 0xfe800000u },
              { 0xc2fc0000u, 0x3f800000u, 0xc2fc0000u, 0x3f800000u } } },
          { { { 0xfe800000u, 0xfe800000u, 0xfe800000u, 0xfe800000u },
              { 0xc2fc0000u, 0x3f800000u, 0xc2fc0000u, 0x3f800000u } },
            { { 0x7e800000u, 0x7e800000u, 0x7e800000u, 0x7e800000u },
              { 0xc2fc0000u, 0x3f800000u, 0xc2fc0000u, 0x3f800000u } } },
          { { { 0x7e7ffffdu, 0x7e7ffffdu, 0x7e7ffffdu, 0x7e7ffffdu },
              { 0xc2fc0000u, 0x3f800001u, 0xc2fc0000u, 0x3f800000u } },
            { { 0xfe7ffffdu, 0xfe7ffffdu, 0xfe7ffffdu, 0xfe7ffffdu },
              { 0xc2fc0000u, 0x3f800001u, 0xc2fc0000u, 0x3f800000u } } },
          { { { 0xfe7ffffdu, 0xfe7ffffdu, 0xfe7ffffdu, 0xfe7ffffdu },
              { 0xc2fc0000u, 0x3f800001u, 0xc2fc0000u, 0x3f800000u } },
            { { 0x7e7ffffdu, 0x7e7ffffdu, 0x7e7ffffdu, 0x7e7ffffdu },
              { 0xc2fc0000u, 0x3f800001u, 0xc2fc0000u, 0x3f800000u } } } },
        { { { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
              { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u } },
            { { 0xbf800000u, 0xbf800000u, 0xbf800000u, 0xbf800000u },
              { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u } } },
          { { { 0xbf800000u, 0xbf800000u, 0xbf800000u, 0xbf800000u },
              { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u } },
            { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
              { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u } } },
          { { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
              { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } },
            { { 0x80000000u, 0x80000000u, 0x80000000u, 0x80000000u },
              { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } } },
          { { { 0x80000000u, 0x80000000u, 0x80000000u, 0x80000000u },
              { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } },
            { { 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u },
              { 0x7f800000u, 0x3f800000u, 0x7f800000u, 0x3f800000u } } } },
        { { { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7fc00001u, 0x7fc00001u, 0x7fc00001u, 0x3f800000u } },
            { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7fc00001u, 0x7fc00001u, 0x7fc00001u, 0x3f800000u } } },
          { { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7fc00001u, 0x7fc00001u, 0x7fc00001u, 0x3f800000u } },
            { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7fc00001u, 0x7fc00001u, 0x7fc00001u, 0x3f800000u } } },
          { { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7f800001u, 0x7f800001u, 0x7f800001u, 0x3f800000u } },
            { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7f800001u, 0x7f800001u, 0x7f800001u, 0x3f800000u } } },
          { { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7f800001u, 0x7f800001u, 0x7f800001u, 0x3f800000u } },
            { { 0x7fffffffu, 0x7fffffffu, 0x7fffffffu, 0x7fffffffu },
              { 0x7f800001u, 0x7f800001u, 0x7f800001u, 0x3f800000u } } } },
        { { { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } },
          { { { 0xff800000u, 0xff800000u, 0xff800000u, 0xff800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } },
            { { 0x7f800000u, 0x7f800000u, 0x7f800000u, 0x7f800000u },
              { 0xff800000u, 0x3f800000u, 0xff800000u, 0x3f800000u } } } }
    };
    const unsigned swizzles[] = { 0xe4, 0x1b, 0, 0xff };
    unsigned cases = 0;
    for (unsigned path = 0; path < 6; path++) {
        for (unsigned group = 0; group < 6; group++) {
            NV2AMetalProgramInput input = { 0 };
            memcpy(input.attributes[0], bits[group], sizeof(bits[group]));
            input.attributes[1][0] = 40;
            for (unsigned k = 0; k < 4; k++) {
                input.attributes[2][k] = -0.0f;
            }
            NV2AMetalProgramUniforms u = uniforms();
            unsigned constant = path == 2 ? 191 : path == 3 ? 2 : 0;
            memcpy(u.constants[path == 3 ? 42 : constant], bits[group],
                   sizeof(bits[group]));
            NV2AMetalProgramUniforms original = u;
            id<MTLBuffer> attributes = [commands.device
                newBufferWithBytes:&input
                            length:sizeof(input)
                           options:MTLResourceStorageModeShared];
            for (unsigned sw = 0; sw < 4; sw++) {
                for (unsigned negate = 0; negate < 2; negate++) {
                    for (unsigned operation = 0; operation < 8; operation++) {
                        BOOL ilu =
                            operation == 1 || operation == 4 || operation == 5;
                        BOOL scalar = operation == 4 || operation == 5;
                        unsigned opcode =
                            operation < 2                    ? NV2AMetalMACMov :
                            operation == 2 || operation == 6 ? NV2AMetalMACSlt :
                            operation == 3 || operation == 7 ? NV2AMetalMACSge :
                            operation == 4                   ? NV2AMetalILURcp :
                                                               NV2AMetalILULog;
                        Token tokens[3];
                        unsigned slot = path >= 3;
                        if (path == 3) {
                            tokens[0] = token(NV2AMetalMACArl, 0, 1, 0);
                            destination(&tokens[0], 0, 0, 0, 0, 0, 0);
                        } else if (path >= 4) {
                            /* Real temporary/R12 chains retain the raw bits
                             * through the first MOV as Kelvin does.
                             */
                            tokens[0] = token(NV2AMetalMACMov, 0, 0, 0);
                            destination(&tokens[0], 0, 0, 0, path == 4 ? 2 : 12,
                                        15, 0);
                        }
                        if (slot) {
                            tokens[0].word[3] &= ~1u;
                        }
                        if (operation >= 6) {
                            /* -0 against subnormal B distinguishes the bit
                             * order from native comparisons that flush
                             * implicitly.
                             */
                            tokens[slot] = token(NV2AMetalMACMov, 0, 2, 0);
                            destination(&tokens[slot], 0, 0, 0, 3, 15, 0);
                            tokens[slot++].word[3] &= ~1u;
                        }
                        tokens[slot] = token(ilu ? 0 : opcode, ilu ? opcode : 0,
                                             0, constant);
                        source(&tokens[slot],
                               ilu            ? 2 :
                               operation >= 6 ? 1 :
                                                0,
                               path == 0 ? 2 :
                               path < 4  ? 3 :
                                           1,
                               path == 4 ? 2 :
                               path == 5 ? 12 :
                                           0,
                               swizzles[sw], negate);
                        source(&tokens[slot], operation >= 6 ? 0 : 1, 1, 3,
                               0xe4, NO);
                        destination(&tokens[slot], 3, 15, ilu, 0, 0, 0);
                        if (path == 3) {
                            tokens[slot].word[3] |= 2u;
                        }
                        begin(commands);
                        NV2AMetalProgramResult *result =
                            encode(executor, commands, tokens, slot + 1, &u,
                                   attributes, 1);
                        finish(commands);
                        const NV2AMetalProgramOutput *output = raw(result);
                        for (unsigned k = 0; k < 4; k++) {
                            unsigned component =
                                (swizzles[sw] >> (2 * (scalar ? 0 : k))) & 3;
                            uint32_t expectedBits = bits[group][component];
                            expectedBits ^= negate << 31;
                            float value;
                            memcpy(&value, &expectedBits, sizeof(value));
                            float expected = value;
                            if (operation == 2 || operation == 3 ||
                                operation >= 6) {
                                BOOL less = (expectedBits >> 31) != 0;
                                if (operation >= 6) {
                                    less = (expectedBits >> 31) == 0;
                                }
                                expected = operation == 2 || operation == 6 ?
                                               less :
                                               !less;
                            }
                            float actual = output->registers[3][k];
                            uint32_t actualBits, referenceBits;
                            memcpy(&actualBits, &actual, sizeof(actualBits));
                            memcpy(&referenceBits, &expected,
                                   sizeof(referenceBits));
                            if (scalar) {
                                referenceBits =
                                    scalarExpected[group][component][negate]
                                                  [operation - 4][k];
                                if (actualBits != referenceBits) {
                                    fprintf(
                                        stderr,
                                        "Kelvin scalar source path%u group%u "
                                        "swizzle%x negate%u opcode%u "
                                        "channel%u: "
                                        "%08x expected %08x\n",
                                        path, group, swizzles[sw], negate,
                                        opcode, k, actualBits, referenceBits);
                                    abort();
                                }
                                continue;
                            }
                            BOOL same = isnan(expected) ?
                                            isnan(actual) :
                                            actualBits == referenceBits;
                            if (operation < 2) {
                                same = actualBits == referenceBits;
                            }
                            if (!same) {
                                fprintf(stderr,
                                        "Denorm path%u group%u swizzle%x "
                                        "negate%u operation%u channel%u: "
                                        "%08x expected %08x\n",
                                        path, group, swizzles[sw], negate,
                                        operation, k, actualBits,
                                        referenceBits);
                                abort();
                            }
                        }
                        assert(memcmp(attributes.contents, &input,
                                      sizeof(input)) == 0);
                        assert(memcmp(&u, &original, sizeof(u)) == 0);
                        cases++;
                    }
                }
            }
        }
    }
    assert(cases == 2304);
    printf("Metal4 Kelvin source classes: 2304 cases/9216 raw channels PASS\n");
}

static void kelvin_ordering(NV2AMetalVertexProgram *executor,
                            NV2AMetalCommands *commands)
{
    /* envytools hwtest/xf.cc selects FP_ZERO_WINS for Kelvin. The independent
     * sign/magnitude relation below was checked against nvhw/xf.c.
     */
    const uint32_t bits[] = {
        0x00000000, 0x80000000, 0x00000001, 0x80000001, 0x007fffff, 0x807fffff,
        0x00400000, 0x80400000, 0x00800000, 0x80800000, 0x00800001, 0x80800001,
        0x3f800000, 0xbf800000, 0x3f800001, 0xbf800001, 0x7f7fffff, 0xff7fffff,
        0x7f800000, 0xff800000, 0x7f800001, 0xff800001, 0x7f9fffff, 0xff9fffff,
        0x7fc00001, 0xffc00001, 0x7fffffff, 0xffffffff, 0x3f000000, 0xbf000000,
        0x40000000, 0xc0000000,
    };
    NV2AMetalProgramInput *input = calloc(1024, sizeof(*input));
    assert(input);
    for (unsigned a = 0; a < 32; a++) {
        for (unsigned b = 0; b < 32; b++) {
            for (unsigned k = 0; k < 4; k++) {
                uint32_t abits = bits[(a + k * 7) % 32];
                uint32_t bbits = bits[(b + k * 11) % 32];
                memcpy(&input[a * 32 + b].attributes[0][k], &abits, 4);
                memcpy(&input[a * 32 + b].attributes[1][k], &bbits, 4);
            }
        }
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:1024 * sizeof(*input)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalProgramUniforms u = uniforms();
    const unsigned opcodes[] = { NV2AMetalMACMin, NV2AMetalMACMax,
                                 NV2AMetalMACSlt, NV2AMetalMACSge };
    for (unsigned op = 0; op < 4; op++) {
        for (unsigned negate = 0; negate < 4; negate++) {
            Token tokens[] = { token(NV2AMetalMACMov, 0, 1, 0),
                               token(opcodes[op], 0, 0, 0) };
            destination(&tokens[0], 0, 0, 0, 2, 15, 0);
            tokens[0].word[3] &= ~1u;
            source(&tokens[1], 0, 2, 0, 0xe4, negate & 1);
            source(&tokens[1], 1, 1, 2, 0x1b, negate & 2);
            destination(&tokens[1], 3, 15, 0, 0, 0, 0);
            begin(commands);
            NV2AMetalProgramResult *result =
                encode(executor, commands, tokens, 2, &u, attributes, 1024);
            finish(commands);
            const NV2AMetalProgramOutput *outputs = raw(result);
            for (unsigned a = 0; a < 32; a++) {
                for (unsigned b = 0; b < 32; b++) {
                    for (unsigned k = 0; k < 4; k++) {
                        uint32_t abits =
                            bits[(a + k * 7) % 32] ^ ((negate & 1) << 31);
                        uint32_t bbits = bits[(b + (3 - k) * 11) % 32] ^
                                         ((negate >> 1) << 31);
                        BOOL less = (abits ^ bbits) >> 31 ? (abits >> 31) != 0 :
                                    abits >> 31           ? abits > bbits :
                                                            abits < bbits;
                        uint32_t expected = op == 0 ? (less ? abits : bbits) :
                                            op == 1 ? (less ? bbits : abits) :
                                            op == 2 ? (less ? 0x3f800000 : 0) :
                                                      (less ? 0 : 0x3f800000);
                        uint32_t actual;
                        memcpy(&actual, &outputs[a * 32 + b].registers[3][k],
                               4);
                        if (actual != expected) {
                            fprintf(stderr,
                                    "Kelvin opcode%u neg%u A%08x B%08x "
                                    "channel%u: %08x expected %08x\n",
                                    opcodes[op], negate, abits, bbits, k,
                                    actual, expected);
                            abort();
                        }
                    }
                }
            }
            assert(memcmp(attributes.contents, input, 1024 * sizeof(*input)) ==
                   0);
        }
    }
    free(input);
    printf("Metal4 Kelvin ordering: 16384 cases/65536 raw channels PASS\n");
}

static void paired_c_vector(NV2AMetalVertexProgram *executor,
                            NV2AMetalCommands *commands)
{
    /* NV20 XF ISA reads three vector sources before its independent ALUs.
     * A scalar ILU opcode must not replace MAC ADD/MAD's vector C operand.
     * Fixed finite fixtures also agree with the public CPU interpreter. */
    const float a[4] = { 1, 2, 3, 4 }, b[4] = { 5, 6, 7, 8 };
    const float c[4] = { 4, 3, 2, 1 };
    const unsigned swizzles[4] = { 0xe4, 0x1b, 0, 0xff };
    static const uint32_t family[4][7][4] = {
        { { 0x40800000u, 0x40400000u, 0x40000000u, 0x3f800000u },
          { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
          { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
          { 0x3effffffu, 0x3effffffu, 0x3effffffu, 0x3effffffu },
          { 0x41800000u, 0x00000000u, 0x41800000u, 0x3f800000u },
          { 0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u },
          { 0x3f800000u, 0x40800000u, 0x404001e0u, 0x3f800000u } },
        { { 0x3f800000u, 0x40000000u, 0x40400000u, 0x40800000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
          { 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu },
          { 0x40000000u, 0x00000000u, 0x40000000u, 0x3f800000u },
          { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
          { 0x3f800000u, 0x3f800000u, 0x41800000u, 0x3f800000u } },
        { { 0x40800000u, 0x40800000u, 0x40800000u, 0x40800000u },
          { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
          { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
          { 0x3effffffu, 0x3effffffu, 0x3effffffu, 0x3effffffu },
          { 0x41800000u, 0x00000000u, 0x41800000u, 0x3f800000u },
          { 0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u },
          { 0x3f800000u, 0x40800000u, 0x43800000u, 0x3f800000u } },
        { { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
          { 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu },
          { 0x40000000u, 0x00000000u, 0x40000000u, 0x3f800000u },
          { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
          { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u } }
    };
    NV2AMetalProgramInput input = { 0 };
    memcpy(input.attributes[0], a, sizeof(a));
    memcpy(input.attributes[1], b, sizeof(b));
    memcpy(input.attributes[2], c, sizeof(c));
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:&input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    NV2AMetalProgramUniforms u = uniforms();
    memcpy(u.constants[96], c, sizeof(c));
    unsigned cases = 0;
    for (unsigned m = 0; m < 2; m++) {
        for (unsigned i = 1; i <= 7; i++) {
            for (unsigned path = 0; path < 3; path++) {
                for (unsigned sw = 0; sw < 4; sw++) {
                    float vector[4], mac[4], ilu[4];
                    for (unsigned k = 0; k < 4; k++) {
                        vector[k] = c[(swizzles[sw] >> (2 * k)) & 3];
                        mac[k] = (m ? a[k] * b[k] : a[k]) + vector[k];
                    }
                    memcpy(ilu, family[sw][i - 1], sizeof(ilu));
                    NSMutableArray<NV2AMetalProgramResult *> *results =
                        [NSMutableArray array];
                    begin(commands);
                    for (unsigned mux = 0; mux < 2; mux++) {
                        for (unsigned mask = 0; mask < 16; mask++) {
                            Token t[6] = { token(NV2AMetalMACMov, 0, 0, 0),
                                           token(NV2AMetalMACMov, 0, 1, 0),
                                           token(NV2AMetalMACMov, 0, 0, 96),
                                           token(m ? NV2AMetalMACMad :
                                                     NV2AMetalMACAdd,
                                                 i, 2, 96),
                                           token(NV2AMetalMACMov, 0, 0, 0),
                                           token(NV2AMetalMACMov, 0, 0, 0) };
                            destination(&t[0], 0, 0, 0, 2, 15, 0);
                            destination(&t[1], 0, 0, 0, 3, 15, 0);
                            source(&t[2], 0, 3, 0, 0xe4, NO);
                            destination(&t[2], 0, 0, 0, 11, 15, 0);
                            source(&t[3], 0, 1, 2, 0xe4, NO);
                            source(&t[3], 1, 1, 3, 0xe4, NO);
                            source(&t[3], 2,
                                   path == 0 ? 2 :
                                   path == 1 ? 3 :
                                               1,
                                   path == 2 ? 11 : 0, swizzles[sw], NO);
                            destination(&t[3], 3, mask, mux, 4, 15, 15);
                            source(&t[4], 0, 1, 4, 0xe4, NO);
                            destination(&t[4], 9, 15, 0, 0, 0, 0);
                            source(&t[5], 0, 1, 1, 0xe4, NO);
                            destination(&t[5], 10, 15, 0, 0, 0, 0);
                            for (unsigned slot = 0; slot < 5; slot++)
                                t[slot].word[3] &= ~1u;
                            [results addObject:encode(executor, commands, t, 6,
                                                      &u, attributes, 1)];
                        }
                    }
                    finish(commands);
                    for (unsigned mux = 0; mux < 2; mux++) {
                        for (unsigned mask = 0; mask < 16; mask++) {
                            const NV2AMetalProgramOutput *out =
                                raw(results[mux * 16 + mask]);
                            assert(!out->fault);
                            for (unsigned k = 0; k < 4; k++) {
                                float values[3] = {
                                    mask & (8u >> k) ? (mux ? ilu[k] : mac[k]) :
                                                       (k == 3 ? 1 : 0),
                                    mac[k], ilu[k]
                                };
                                const unsigned registers[3] = { 3, 9, 10 };
                                for (unsigned r = 0; r < 3; r++) {
                                    uint32_t actual, expected;
                                    memcpy(&actual,
                                           &out->registers[registers[r]][k], 4);
                                    memcpy(&expected, &values[r], 4);
                                    if (actual != expected) {
                                        fprintf(stderr,
                                                "Paired C MAC%u ILU%u path%u "
                                                "sw%u mux%u mask%u "
                                                "register%u/%u: %08x vs %08x\n",
                                                m, i, path, sw, mux, mask,
                                                registers[r], k, actual,
                                                expected);
                                        abort();
                                    }
                                }
                            }
                            cases++;
                        }
                    }
                }
            }
        }
    }
    assert(cases == 5376);
    puts("Metal4 paired MAC C: 5376 cases/64512 raw channels across input, "
         "constant and R11 sources PASS");
}

static void check_alias_case(NV2AMetalVertexProgram *executor,
                             NV2AMetalCommands *commands,
                             id<MTLBuffer> attributes,
                             NV2AMetalProgramUniforms *u, AliasCase fixture)
{
    NSError *error = nil;
    begin(commands);
    NV2AMetalProgramResult *result =
        [executor encodeTokens:fixture.tokens[0].word
                        length:5
                      uniforms:u
                    attributes:attributes
                         count:1
                      commands:commands
                         error:&error];
    require(result != nil, error);
    finish(commands);
    const NV2AMetalProgramOutput *r = raw(result);
    const unsigned rows[4] = { 0, 9, 10, 11 };
    for (unsigned row = 0; row < 4; row++) {
        for (unsigned k = 0; k < 4; k++) {
            uint32_t actual, expected;
            memcpy(&actual, &r->registers[rows[row]][k], 4);
            memcpy(&expected, &fixture.expected[row][k], 4);
            if (actual != expected) {
                fprintf(stderr,
                        "R12 prewrite family%u MAC%u ILU%u swz%02x mux%u "
                        "mask%x temp%x row%u/%u: %08x vs %08x\n",
                        fixture.family, fixture.mac, fixture.ilu,
                        fixture.swizzle, fixture.output_mux,
                        fixture.output_mask, fixture.temp_mask, rows[row], k,
                        actual, expected);
                abort();
            }
        }
    }
}
static void r12_prewrite(NV2AMetalVertexProgram *executor,
                         NV2AMetalCommands *commands)
{
    NV2AMetalProgramInput input = { 0 };
    for (unsigned k = 0; k < 4; k++) {
        input.attributes[0][k] = (float)k + 1;
        input.attributes[1][k] = (float)k + 5;
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:&input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    NV2AMetalProgramUniforms u = uniforms();
    const unsigned swizzles[] = { 0xe4, 0x1b, 0x00, 0xff };
    unsigned cases = 0;
    for (unsigned sw = 0; sw < 4; sw++) {
        for (unsigned mask = 0; mask < 16; mask++) {
            for (unsigned temp = 0; temp < 16; temp++) {
                check_alias_case(executor, commands, attributes, &u,
                                 alias_case(0, 3, swizzles[sw], 0, mask, temp));
                check_alias_case(executor, commands, attributes, &u,
                                 alias_case(0, 4, swizzles[sw], 0, mask, temp));
                check_alias_case(executor, commands, attributes, &u,
                                 alias_case(2, 0, swizzles[sw], 1, mask, temp));
                cases += 3;
            }
            const unsigned paired[] = { 1, 3, 4 };
            for (unsigned m = 0; m < 3; m++) {
                for (unsigned mux = 0; mux < 2; mux++) {
                    for (unsigned ilu = 1; ilu <= 7; ilu++) {
                        check_alias_case(
                            executor, commands, attributes, &u,
                            alias_ilu(alias_case(1, paired[m], swizzles[sw],
                                                 mux, mask, 15),
                                      ilu));
                        cases++;
                    }
                }
            }
        }
    }
    assert(cases == 5760);
    puts("Metal4 R12 prewrite: 5760 cases/92160 exact raw channels PASS");
}

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalVertexProgram *executor =
            [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                     error:&error];
        require(executor != nil, error);
        kelvin_reciprocal(executor, commands);
        kelvin_transcendentals(executor, commands);
        kelvin_lit(executor, commands);
        NV2AMetalProgramInput input[3] = { 0 };
        const float a[] = { 2, -3, 4, -5 }, b[] = { -1, 2, -3, 4 },
                    c[] = { 5, 6, 7, 8 };
        memcpy(input[0].attributes[0], a, sizeof(a));
        memcpy(input[0].attributes[1], c, sizeof(c));
        NV2AMetalProgramUniforms u = uniforms();
        memcpy(u.constants[0], b, sizeof(b));
        for (unsigned i = 0; i < 4; i++) {
            u.constants[1][i] = 1;
        }
        id<MTLBuffer> attributes =
            [commands.device newBufferWithBytes:input
                                         length:sizeof(input)
                                        options:MTLResourceStorageModeShared];
        const float macExpected[][4] = {
            { 2, -3, 4, -5 },       { -2, -6, -12, -20 },
            { 7, 3, 11, 3 },        { 3, 0, -5, -12 },
            { -20, -20, -20, -20 }, { -16, -16, -16, -16 },
            { -40, -40, -40, -40 }, { 1, -6, 4, 4 },
            { -1, -3, -3, -5 },     { 2, 2, 4, 4 },
            { 0, 1, 0, 1 },         { 1, 0, 1, 0 },
        };
        NSMutableArray<NV2AMetalProgramResult *> *results =
            [NSMutableArray array];
        begin(commands);
        for (unsigned mac = NV2AMetalMACMov; mac <= NV2AMetalMACSge; mac++) {
            Token tokens[] = { token(NV2AMetalMACMov, 0, 1, 0),
                               token(mac, 0, 0, 0) };
            destination(&tokens[0], 0, 0, 0, 2, 15, 0);
            tokens[0].word[3] &= ~1u;
            [results addObject:encode(executor, commands, tokens, 2, &u,
                                      attributes, 1)];
        }
        finish(commands);
        for (unsigned i = 0; i < results.count; i++) {
            const NV2AMetalProgramOutput *r = raw(results[i]);
            for (unsigned k = 0; k < 4; k++) {
                check_float(r->registers[3][k], macExpected[i][k]);
            }
        }

        const float iluInput[] = { 2.5f, 3, 4, 2 };
        memcpy(((NV2AMetalProgramInput *)attributes.contents)[0].attributes[0],
               iluInput, sizeof(iluInput));
        const uint32_t iluExpected[][4] = {
            { 0x40200000u, 0x40400000u, 0x40800000u, 0x40000000u },
            { 0x3eccccccu, 0x3eccccccu, 0x3eccccccu, 0x3eccccccu },
            { 0x3eccccccu, 0x3eccccccu, 0x3eccccccu, 0x3eccccccu },
            { 0x3f21e89bu, 0x3f21e89bu, 0x3f21e89bu, 0x3f21e89bu },
            { 0x40800000u, 0x3f000000u, 0x40b50600u, 0x3f800000u },
            { 0x3f800000u, 0x3fa00000u, 0x3fa939c0u, 0x3f800000u },
            { 0x3f800000u, 0x40200000u, 0x41100520u, 0x3f800000u },
        };
        [results removeAllObjects];
        begin(commands);
        for (unsigned ilu = NV2AMetalILUMov; ilu <= NV2AMetalILULit; ilu++) {
            Token t = token(0, ilu, 0, 0);
            source(&t, 2, 2, 0, 0xe4, NO);
            destination(&t, 3, 15, 1, 0, 0, 0);
            [results
                addObject:encode(executor, commands, &t, 1, &u, attributes, 1)];
        }
        finish(commands);
        for (unsigned i = 0; i < results.count; i++) {
            const NV2AMetalProgramOutput *r = raw(results[i]);
            for (unsigned k = 0; k < 4; k++) {
                uint32_t actual;
                memcpy(&actual, &r->registers[3][k], sizeof(actual));
                assert(actual == iluExpected[i][k]);
            }
        }

        paired_c_vector(executor, commands);
        r12_prewrite(executor, commands);
        kelvin_arithmetic(executor, commands);
        kelvin_ordering(executor, commands);
        denormal_sources(executor, commands);
        comparison_classes(executor, commands);
        mac_zero_products(executor, commands);
        ilu_special_values(executor, commands);
        log_power_boundaries(executor, commands);

        /* All 16 output masks, including fog's packed destination components.
         */
        [results removeAllObjects];
        begin(commands);
        for (unsigned fog = 0; fog < 2; fog++) {
            for (unsigned mask = 0; mask < 16; mask++) {
                Token t = token(NV2AMetalMACMov, 0, 0, 0);
                destination(&t, fog ? 5 : 3, mask, 0, 0, 0, 0);
                [results addObject:encode(executor, commands, &t, 1, &u,
                                          attributes, 1)];
            }
        }
        finish(commands);
        for (unsigned fog = 0; fog < 2; fog++) {
            for (unsigned mask = 0; mask < 16; mask++) {
                float expected[] = { 0, 0, 0, 1 };
                unsigned packed = 0;
                for (unsigned k = 0; k < 4; k++) {
                    if (mask & (8u >> k)) {
                        unsigned component = fog ? packed++ : k;
                        expected[component] = iluInput[component];
                    }
                }
                const NV2AMetalProgramOutput *r = raw(results[16 * fog + mask]);
                for (unsigned k = 0; k < 4; k++) {
                    check_float(r->registers[fog ? 5 : 3][k], expected[k]);
                }
            }
        }

        /* Exhaust every swizzle/negate combination on each input port. */
        [results removeAllObjects];
        begin(commands);
        for (unsigned operand = 0; operand < 3; operand++) {
            for (unsigned negative = 0; negative < 2; negative++) {
                for (unsigned swizzle = 0; swizzle < 256; swizzle++) {
                    Token t = token(operand == 0 ? NV2AMetalMACMov :
                                    operand == 1 ? NV2AMetalMACMul :
                                                   0,
                                    operand == 2 ? NV2AMetalILUMov : 0, 0, 1);
                    if (operand == 1) {
                        source(&t, 0, 3, 0, 0xe4, NO);
                    }
                    source(&t, operand, 2, 0, swizzle, negative);
                    destination(&t, 9, 15, operand == 2, 0, 0, 0);
                    [results addObject:encode(executor, commands, &t, 1, &u,
                                              attributes, 1)];
                }
            }
        }
        finish(commands);
        for (unsigned operand = 0; operand < 3; operand++) {
            for (unsigned negative = 0; negative < 2; negative++) {
                for (unsigned swizzle = 0; swizzle < 256; swizzle++) {
                    const NV2AMetalProgramOutput *r =
                        raw(results[512 * operand + 256 * negative + swizzle]);
                    for (unsigned k = 0; k < 4; k++) {
                        check_float(r->registers[9][k],
                                    iluInput[(swizzle >> (2 * k)) & 3] *
                                        (negative ? -1 : 1));
                    }
                }
            }
        }

        /* Paired MAC must read old R1 and defer its write until ILU completes.
         */
        memcpy(((NV2AMetalProgramInput *)attributes.contents)[0].attributes[0],
               a, sizeof(a));
        Token pair[] = { token(NV2AMetalMACMov, 0, 1, 0),
                         token(NV2AMetalMACAdd, NV2AMetalILUMov, 0, 0),
                         token(NV2AMetalMACMov, 0, 0, 0),
                         token(NV2AMetalMACMov, 0, 0, 0) };
        destination(&pair[0], 0, 0, 0, 1, 15, 0);
        source(&pair[1], 0, 1, 1, 0xe4, NO);
        source(&pair[1], 2, 2, 0, 0xe4, NO);
        destination(&pair[1], 0, 0, 0, 2, 15, 15);
        source(&pair[2], 0, 1, 2, 0xe4, NO);
        source(&pair[3], 0, 1, 1, 0xe4, NO);
        destination(&pair[3], 4, 15, 0, 0, 0, 0);
        for (unsigned i = 0; i < 3; i++) {
            pair[i].word[3] &= ~1u;
        }
        begin(commands);
        NV2AMetalProgramResult *paired =
            encode(executor, commands, pair, 4, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(paired)->registers[3][k], a[k] + c[k]);
            check_float(raw(paired)->registers[4][k], a[k]);
        }
        destination(&pair[1], 0, 0, 0, 1, 15, 15);
        source(&pair[2], 0, 1, 1, 0xe4, NO);
        begin(commands);
        paired = encode(executor, commands, pair, 4, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(paired)->registers[3][k], a[k]);
        }

        /* R12 sources are captured before either destination is written. */
        Token alias[] = { token(NV2AMetalMACMov, 0, 0, 0),
                          token(NV2AMetalMACMov, 0, 0, 0),
                          token(NV2AMetalMACAdd, 0, 0, 0),
                          token(NV2AMetalMACMov, 0, 0, 0) };
        destination(&alias[0], 0, 15, 0, 0, 0, 0);
        source(&alias[1], 0, 1, 12, 0xe4, NO);
        destination(&alias[1], 9, 15, 0, 0, 0, 0);
        source(&alias[2], 0, 1, 12, 0xe4, NO);
        source(&alias[2], 2, 2, 0, 0xe4, NO);
        destination(&alias[2], 0, 15, 0, 2, 15, 0);
        source(&alias[3], 0, 1, 2, 0xe4, NO);
        destination(&alias[3], 10, 15, 0, 0, 0, 0);
        for (unsigned i = 0; i < 3; i++) {
            alias[i].word[3] &= ~1u;
        }
        begin(commands);
        NV2AMetalProgramResult *aliased =
            encode(executor, commands, alias, 4, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(aliased)->registers[9][k], a[k]);
            check_float(raw(aliased)->registers[0][k], 2 * a[k]);
            check_float(raw(aliased)->registers[10][k], 2 * a[k]);
        }

        /* ARL bias and relative addressing, including explicit bounds faults.
         */
        ((NV2AMetalProgramInput *)attributes.contents)[0].attributes[0][0] =
            -1.0009f;
        Token relative[] = { token(NV2AMetalMACArl, 0, 0, 0),
                             token(NV2AMetalMACMov, 0, 0, 1) };
        destination(&relative[0], 0, 0, 0, 0, 0, 0);
        relative[0].word[3] &= ~1u;
        source(&relative[1], 0, 3, 0, 0xe4, NO);
        relative[1].word[3] |= 2;
        begin(commands);
        NV2AMetalProgramResult *addressed =
            encode(executor, commands, relative, 2, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(addressed)->registers[3][k], b[k]);
        }
        relative[1].word[1] &= ~(255u << 13);
        begin(commands);
        NV2AMetalProgramResult *faulted =
            encode(executor, commands, relative, 2, &u, attributes, 1);
        finish(commands);
        assert(((NV2AMetalProgramOutput *)faulted.registers.contents)->fault ==
               NV2AMetalProgramFaultConstantRange);

        /* Native viewport conversion feeds the geometry pass without a CPU
         * readback. Unrounded raw screen coordinates remain inspectable. */
        const float positions[3][4] = { { 1.19f, 2.26f, 8, 2 },
                                        { 3.1f, 2.26f, 8, 2 },
                                        { 1.19f, 3.26f, 8, 2 } };
        for (unsigned i = 0; i < 3; i++) {
            memcpy(
                ((NV2AMetalProgramInput *)attributes.contents)[i].attributes[0],
                positions[i], sizeof(positions[i]));
        }
        Token position = token(NV2AMetalMACMov, 0, 0, 0);
        destination(&position, 0, 15, 0, 0, 0, 0);
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        require(geometry != nil, error);
        begin(commands);
        NV2AMetalProgramResult *processed =
            encode(executor, commands, &position, 1, &u, attributes, 3);
        NV2AMetalGeometryResult *expanded =
            [geometry encodeVertices:processed.vertices
                               count:3
                           primitive:NV2AMetalPrimitiveTriangles
                             polygon:NV2AMetalPolygonFill
                              smooth:YES
                      firstProvoking:NO
                        zPerspective:NO
                            commands:commands
                               error:&error];
        require(expanded != nil, error);
        finish(commands);
        const NV2AMetalVertex *v = expanded.vertices.contents;
        check_float(v[0].screen[0], 1.1875f);
        check_float(v[0].screen[1], 2.25f);
        const float clip[] = { -.8125f, -.25f, 1, 2 };
        for (unsigned k = 0; k < 4; k++) {
            check_float(v[0].clip[k], clip[k]);
        }
        check_float(v[0].point_size, 6);
        check_float(v[0].fog, 1);
        check_float(v[0].slope, 0);
        assert(raw(processed)[0].registers[0][0] == positions[0][0]);

        /* Every direct constant and attribute address is independently tagged.
         * This covers the full encoded fields, not just low addresses. */
        [results removeAllObjects];
        for (unsigned i = 0; i < 16; i++) {
            for (unsigned k = 0; k < 4; k++) {
                ((NV2AMetalProgramInput *)attributes.contents)[0]
                    .attributes[i][k] = 100 * i + k;
            }
        }
        for (unsigned i = 0; i < NV2A_METAL_VP_CONSTANTS; i++) {
            for (unsigned k = 0; k < 4; k++) {
                u.constants[i][k] = 1000 * i + k;
            }
        }
        begin(commands);
        for (unsigned i = 0; i < 16; i++) {
            Token t = token(NV2AMetalMACMov, 0, i, 0);
            destination(&t, 9, 15, 0, 0, 0, 0);
            [results
                addObject:encode(executor, commands, &t, 1, &u, attributes, 1)];
        }
        for (unsigned i = 0; i < NV2A_METAL_VP_CONSTANTS; i++) {
            Token t = token(NV2AMetalMACMov, 0, 0, i);
            source(&t, 0, 3, 0, 0xe4, NO);
            destination(&t, 9, 15, 0, 0, 0, 0);
            [results
                addObject:encode(executor, commands, &t, 1, &u, attributes, 1)];
        }
        finish(commands);
        for (unsigned i = 0; i < results.count; i++) {
            for (unsigned k = 0; k < 4; k++) {
                check_float(raw(results[i])->registers[9][k],
                            i < 16 ? 100 * i + k : 1000 * (i - 16) + k);
            }
        }

        /* All temporary masks, from both arithmetic units. */
        [results removeAllObjects];
        begin(commands);
        for (unsigned ilu = 0; ilu < 2; ilu++) {
            for (unsigned mask = 0; mask < 16; mask++) {
                Token t[] = { token(ilu ? 0 : NV2AMetalMACMov,
                                    ilu ? NV2AMetalILUMov : 0, 1, 0),
                              token(NV2AMetalMACMov, 0, 0, 0) };
                source(&t[0], 2, 2, 0, 0xe4, NO);
                destination(&t[0], 0, 0, 0, 0, ilu ? 0 : mask, ilu ? mask : 0);
                t[0].word[3] &= ~1u;
                source(&t[1], 0, 1, 0, 0xe4, NO);
                destination(&t[1], 9, 15, 0, 0, 0, 0);
                [results addObject:encode(executor, commands, t, 2, &u,
                                          attributes, 1)];
            }
        }
        finish(commands);
        for (unsigned ilu = 0; ilu < 2; ilu++) {
            for (unsigned mask = 0; mask < 16; mask++) {
                for (unsigned k = 0; k < 4; k++) {
                    check_float(raw(results[16 * ilu + mask])->registers[9][k],
                                mask & (8u >> k) ? 100 + k : 0);
                }
            }
        }

        /* Scalar ILU leaves MAC C as a vector. */
        memcpy(((NV2AMetalProgramInput *)attributes.contents)[0].attributes[0],
               a, sizeof(a));
        memcpy(u.constants[0], b, sizeof(b));
        Token shared[] = { token(NV2AMetalMACAdd, NV2AMetalILURcp, 0, 0),
                           token(NV2AMetalMACMov, 0, 0, 0) };
        source(&shared[0], 2, 3, 0, 0xe4, NO);
        destination(&shared[0], 3, 15, 0, 2, 0, 15);
        shared[0].word[3] &= ~1u;
        source(&shared[1], 0, 1, 1, 0xe4, NO);
        destination(&shared[1], 4, 15, 0, 0, 0, 0);
        begin(commands);
        NV2AMetalProgramResult *scalar =
            encode(executor, commands, shared, 2, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(scalar)->registers[3][k], a[k] + b[k]);
            check_float(raw(scalar)->registers[4][k], -1);
        }

        /* Paired ARL leaves the old address visible to that slot's ILU. */
        ((NV2AMetalProgramInput *)attributes.contents)[0].attributes[0][0] = -1;
        for (unsigned k = 0; k < 4; k++) {
            u.constants[1][k] = c[k];
        }
        Token addressPair[] = { token(NV2AMetalMACArl, NV2AMetalILUMov, 0, 1),
                                token(NV2AMetalMACMov, 0, 0, 1) };
        source(&addressPair[0], 2, 3, 0, 0xe4, NO);
        destination(&addressPair[0], 3, 15, 1, 0, 0, 0);
        addressPair[0].word[3] = (addressPair[0].word[3] & ~1u) | 2;
        source(&addressPair[1], 0, 3, 0, 0xe4, NO);
        destination(&addressPair[1], 4, 15, 0, 0, 0, 0);
        addressPair[1].word[3] |= 2;
        begin(commands);
        NV2AMetalProgramResult *addressPaired =
            encode(executor, commands, addressPair, 2, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(addressPaired)->registers[3][k], c[k]);
            check_float(raw(addressPaired)->registers[4][k], b[k]);
        }

        /* Anything multiplied by zero becomes positive zero, including NaN
         * and infinity. MAD must add C after applying this correction. */
        const float specialA[] = { INFINITY, -INFINITY, NAN, 0 },
                    specialB[] = { 0, -0.0f, 0, NAN };
        memcpy(((NV2AMetalProgramInput *)attributes.contents)[0].attributes[0],
               specialA, sizeof(specialA));
        memcpy(((NV2AMetalProgramInput *)attributes.contents)[0].attributes[1],
               c, sizeof(c));
        memcpy(u.constants[0], specialB, sizeof(specialB));
        begin(commands);
        Token multiply = token(NV2AMetalMACMul, 0, 0, 0);
        destination(&multiply, 9, 15, 0, 0, 0, 0);
        NV2AMetalProgramResult *zeroProduct =
            encode(executor, commands, &multiply, 1, &u, attributes, 1);
        Token mad[] = { token(NV2AMetalMACMov, 0, 1, 0),
                        token(NV2AMetalMACMad, 0, 0, 0) };
        destination(&mad[0], 0, 0, 0, 2, 15, 0);
        mad[0].word[3] &= ~1u;
        destination(&mad[1], 9, 15, 0, 0, 0, 0);
        NV2AMetalProgramResult *zeroMad =
            encode(executor, commands, mad, 2, &u, attributes, 1);
        finish(commands);
        for (unsigned k = 0; k < 4; k++) {
            assert(raw(zeroProduct)->registers[9][k] == 0 &&
                   !signbit(raw(zeroProduct)->registers[9][k]));
            check_float(raw(zeroMad)->registers[9][k], c[k]);
        }

        const float exceptional[] = {
            0, -0.0f, INFINITY, -INFINITY, NAN, -4, 4
        };
        NV2AMetalProgramInput exceptionalInputs[7] = { 0 };
        for (unsigned i = 0; i < 7; i++) {
            exceptionalInputs[i].attributes[0][0] = exceptional[i];
        }
        id<MTLBuffer> exceptionalBuffer =
            [commands.device newBufferWithBytes:exceptionalInputs
                                         length:sizeof(exceptionalInputs)
                                        options:MTLResourceStorageModeShared];
        const float rcp[] = { INFINITY, -INFINITY, 0, -0.0f, NAN, -.25f, .25f };
        /* Kelvin canonicalizes RCC NaN instead of clamping it. RSQ uses
         * the original version2 LUT result, including powers of two. */
        const float rcc[] = { 0x1p64f, -0x1p64f, 0x1p-64f, -0x1p-64f,
                              NAN,     -.25f,    .25f };
        const float rsq[] = { INFINITY,       INFINITY,      0, 0, NAN,
                              0x1.fffffep-2f, 0x1.fffffep-2f };
        const float *expectedExceptional[] = { rcp, rcc, rsq };
        for (unsigned ilu = NV2AMetalILURcp; ilu <= NV2AMetalILURsq; ilu++) {
            Token t = token(0, ilu, 0, 0);
            source(&t, 2, 2, 0, 0xe4, NO);
            destination(&t, 9, 15, 1, 0, 0, 0);
            begin(commands);
            NV2AMetalProgramResult *value =
                encode(executor, commands, &t, 1, &u, exceptionalBuffer, 7);
            finish(commands);
            for (unsigned i = 0; i < 7; i++) {
                for (unsigned k = 0; k < 4; k++) {
                    float actual = raw(value)[i].registers[9][k];
                    float expected =
                        expectedExceptional[ilu - NV2AMetalILURcp][i];
                    BOOL same = isnan(expected) ? isnan(actual) :
                                                  memcmp(&actual, &expected,
                                                         sizeof(actual)) == 0;
                    if (!same) {
                        fprintf(
                            stderr,
                            "ILU %u input %u channel %u: got %g, expected %g\n",
                            ilu, i, k, actual, expected);
                        abort();
                    }
                }
            }
        }

        /* All fog modes, with finite, NaN and infinite distances. */
        unsigned fogModes[] = { 0, 1, 3, 4, 5, 7 };
        float expectedFog[] = { .5f, .25f, .0625f, 1, .25f, .0625f };
        ((NV2AMetalProgramInput *)exceptionalBuffer.contents)[0]
            .attributes[0][0] = 2;
        for (unsigned mode = 0; mode < 6; mode++) {
            u.fog_enable = YES;
            u.fog_mode = fogModes[mode];
            u.fog[0] = mode == 0 ? 2 : mode == 3 ? 1 : 1.5f;
            u.fog[1] = mode == 0              ? -.25f :
                       mode == 3              ? -.5f :
                       mode == 1 || mode == 4 ? -1.0f / 16 :
                                                1.0f / sqrtf(32);
            Token t = token(NV2AMetalMACMov, 0, 0, 0);
            destination(&t, 5, 8, 0, 0, 0, 0);
            begin(commands);
            NV2AMetalProgramResult *fog =
                encode(executor, commands, &t, 1, &u, exceptionalBuffer, 7);
            finish(commands);
            const NV2AMetalVertex *fogVertices = fog.vertices.contents;
            check_float(fogVertices[0].fog, expectedFog[mode]);
            check_float(fogVertices[2].fog,
                        mode == 0 || mode == 1 || mode == 3 ? 1 : 0);
            check_float(fogVertices[3].fog,
                        mode == 0 || mode == 1 || mode == 3 ? 1 : 0);
            check_float(fogVertices[4].fog,
                        mode == 0 || mode == 1 || mode == 3 ? 1 : 0);
        }
        u.fog_enable = NO;

        /* Color NaNs become one before clamping; specular alpha obeys its
         * independent control. Programmed point size bypasses the fallback. */
        NV2AMetalProgramUniforms colorUniforms = uniforms();
        colorUniforms.specular_enable = YES;
        colorUniforms.point_programmed = YES;
        const float diffuse[] = { NAN, -INFINITY, INFINITY, -.5f };
        const float specular[] = { -.2f, .4f, 1.2f, .2f };
        NV2AMetalProgramInput colorInput = { 0 };
        memcpy(colorInput.attributes[0], diffuse, sizeof(diffuse));
        memcpy(colorInput.attributes[1], specular, sizeof(specular));
        colorInput.attributes[2][0] = 7;
        id<MTLBuffer> colorBuffer =
            [commands.device newBufferWithBytes:&colorInput
                                         length:sizeof(colorInput)
                                        options:MTLResourceStorageModeShared];
        Token colors[] = { token(NV2AMetalMACMov, 0, 0, 0),
                           token(NV2AMetalMACMov, 0, 1, 0),
                           token(NV2AMetalMACMov, 0, 0, 0),
                           token(NV2AMetalMACMov, 0, 1, 0),
                           token(NV2AMetalMACMov, 0, 2, 0) };
        unsigned colorOutputs[] = { 3, 4, 7, 8, 6 };
        for (unsigned i = 0; i < 5; i++) {
            destination(&colors[i], colorOutputs[i], 15, 0, 0, 0, 0);
            if (i != 4) {
                colors[i].word[3] &= ~1u;
            }
        }
        for (unsigned ignore = 0; ignore < 2; ignore++) {
            colorUniforms.ignore_specular_alpha = ignore;
            begin(commands);
            NV2AMetalProgramResult *colored = encode(
                executor, commands, colors, 5, &colorUniforms, colorBuffer, 1);
            finish(commands);
            const NV2AMetalVertex *colorVertex = colored.vertices.contents;
            const float expectedDiffuse[] = { 1, 0, 1, 0 },
                        expectedSpecular[] = { 0, .4f, 1, .2f };
            for (unsigned side = 0; side < 2; side++) {
                for (unsigned k = 0; k < 4; k++) {
                    check_float(colorVertex->color[2 * side][k],
                                expectedDiffuse[k]);
                    check_float(colorVertex->color[2 * side + 1][k],
                                ignore && k == 3 ? 1 : expectedSpecular[k]);
                }
            }
            check_float(colorVertex->point_size, 7);
        }
        colorUniforms.specular_enable = NO;
        colorUniforms.point_programmed = NO;
        colorUniforms.point_size = -3;
        begin(commands);
        NV2AMetalProgramResult *fallback = encode(
            executor, commands, colors, 5, &colorUniforms, colorBuffer, 1);
        finish(commands);
        const NV2AMetalVertex *fallbackVertex = fallback.vertices.contents;
        check_float(fallbackVertex->point_size, 2);
        for (unsigned side = 0; side < 2; side++) {
            for (unsigned k = 0; k < 4; k++) {
                check_float(fallbackVertex->color[2 * side + 1][k],
                            k == 3 ? 1 : 0);
            }
        }

        /* Signed zero W is clamped away from zero with its sign preserved. */
        NV2AMetalProgramInput zeroW[2] = { 0 };
        for (unsigned i = 0; i < 2; i++) {
            zeroW[i].attributes[0][0] = -.1f;
            zeroW[i].attributes[0][1] = .1f;
            zeroW[i].attributes[0][3] = i == 0 ? 0.0f : -0.0f;
        }
        id<MTLBuffer> zeroWBuffer =
            [commands.device newBufferWithBytes:zeroW
                                         length:sizeof(zeroW)
                                        options:MTLResourceStorageModeShared];
        begin(commands);
        NV2AMetalProgramResult *clamped =
            encode(executor, commands, &position, 1, &u, zeroWBuffer, 2);
        finish(commands);
        const NV2AMetalVertex *clampedVertices = clamped.vertices.contents;
        for (unsigned i = 0; i < 2; i++) {
            float expectedW = i == 0 ? 0x1p-64f : -0x1p-64f;
            assert(memcmp(&clampedVertices[i].screen[3], &expectedW,
                          sizeof(expectedW)) == 0);
            check_float(clampedVertices[i].screen[0], -.0625f);
            check_float(clampedVertices[i].screen[1], .0625f);
        }

        /* Invalid ARL conversion is reported, never converted to an unchecked
         * buffer address. */
        ((NV2AMetalProgramInput *)exceptionalBuffer.contents)[0]
            .attributes[0][0] = FLT_MAX;
        Token arl = token(NV2AMetalMACArl, 0, 0, 0);
        destination(&arl, 0, 0, 0, 0, 0, 0);
        begin(commands);
        NV2AMetalProgramResult *badAddress =
            encode(executor, commands, &arl, 1, &u, exceptionalBuffer, 1);
        finish(commands);
        assert(
            ((NV2AMetalProgramOutput *)badAddress.registers.contents)->fault ==
            NV2AMetalProgramFaultAddressRange);

        /* Reject unsupported programs before encoding. */
        begin(commands);
        Token invalid = position;
        invalid.word[3] &= ~1u;
        assert(![executor encodeTokens:invalid.word
                                length:1
                              uniforms:&u
                            attributes:attributes
                                 count:1
                              commands:commands
                                 error:&error]);
        assert(error);
        error = nil;
        invalid = position;
        invalid.word[3] &= ~(1u << 11);
        assert(![executor encodeTokens:invalid.word
                                length:1
                              uniforms:&u
                            attributes:attributes
                                 count:1
                              commands:commands
                                 error:&error]);
        assert(error);
        error = nil;
        invalid = position;
        invalid.word[1] |= 15u << 21;
        assert(![executor encodeTokens:invalid.word
                                length:1
                              uniforms:&u
                            attributes:attributes
                                 count:1
                              commands:commands
                                 error:&error]);
        assert(error);
        error = nil;
        invalid = position;
        invalid.word[1] = (invalid.word[1] & ~(255u << 13)) | (192u << 13);
        source(&invalid, 0, 3, 0, 0xe4, NO);
        assert(![executor encodeTokens:invalid.word
                                length:1
                              uniforms:&u
                            attributes:attributes
                                 count:1
                              commands:commands
                                 error:&error]);
        assert(error);
        error = nil;
        invalid = position;
        source(&invalid, 0, 1, 13, 0xe4, NO);
        assert(![executor encodeTokens:invalid.word
                                length:1
                              uniforms:&u
                            attributes:attributes
                                 count:1
                              commands:commands
                                 error:&error]);
        assert(error);
        error = nil;
        invalid = position;
        destination(&invalid, 0, 0, 0, 13, 15, 0);
        assert(![executor encodeTokens:invalid.word
                                length:1
                              uniforms:&u
                            attributes:attributes
                                 count:1
                              commands:commands
                                 error:&error]);
        assert(error);
        error = nil;
        assert(![executor encodeTokens:position.word
                                length:1
                              uniforms:&u
                            attributes:attributes
                                 count:4
                              commands:commands
                                 error:&error]);
        assert(error);
        NV2AMetalProgramResult *empty =
            encode(executor, commands, &position, 1, &u, attributes, 0);
        assert(empty.vertexCount == 0 && !empty.registers && !empty.vertices);
        [commands cancel];
        /* The first FINAL terminates the program even if trailing slots are
         * invalid. No compiler must interpret padding as another instruction.
         */
        Token padded[] = { position, token(15, 0, 0, 0) };
        begin(commands);
        NV2AMetalProgramResult *terminated =
            encode(executor, commands, padded, 2, &u, attributes, 1);
        finish(commands);
        assert(raw(terminated)->fault == NV2AMetalProgramFaultNone);
        puts("Metal 4 NV2A MAC/ILU, masks, all swizzles, pairing, aliases, "
             "addresses and geometry handoff: PASS (offscreen)");
    }
    return 0;
}
