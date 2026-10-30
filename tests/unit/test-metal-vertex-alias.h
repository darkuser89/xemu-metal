/* Finite independent R12 prewrite fixtures; CPU API verified separately.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_VERTEX_ALIAS_H
#define TEST_METAL_VERTEX_ALIAS_H
#include <stdint.h>
#include <string.h>
typedef struct AliasToken {
    uint32_t word[4];
} AliasToken;
typedef struct AliasCase {
    AliasToken tokens[5];
    float expected[4][4]; /* oPos, R2->oT0, R1->oT1, R12->oT2 */
    unsigned family, mac, ilu, swizzle, output_mux, output_mask, temp_mask;
} AliasCase;
static AliasToken alias_token(unsigned mac, unsigned ilu, unsigned attribute)
{
    AliasToken t = { { 0, (mac << 21) | (ilu << 25) | (attribute << 9), 0,
                       0 } };
    return t;
}
static void alias_source(AliasToken *t, unsigned operand, unsigned mux,
                         unsigned reg, unsigned swizzle)
{
    if (operand == 0) {
        t->word[1] &= ~511u;
        t->word[2] = (t->word[2] & 0x03ffffffu) | (reg << 28) | (mux << 26);
    } else if (operand == 1) {
        t->word[2] = (t->word[2] & ~0x03fff800u) | (reg << 13) | (mux << 11);
    } else {
        t->word[2] = (t->word[2] & ~0x7ffu) | (reg >> 2);
        t->word[3] =
            (t->word[3] & 0x0fffffffu) | ((reg & 3) << 30) | (mux << 28);
    }
    unsigned word = operand == 0 ? 1 : 2;
    unsigned start = operand == 0 ? 6 : operand == 1 ? 23 : 8;
    for (unsigned k = 0; k < 4; k++)
        t->word[word] |= ((swizzle >> (2 * k)) & 3) << (start - 2 * k);
}
static void alias_destination(AliasToken *t, unsigned output, unsigned mask,
                              unsigned mux, unsigned macMask, unsigned iluMask)
{
    t->word[3] &= ~0x0ffffffcu;
    t->word[3] |= (macMask << 24) | (2u << 20) | (iluMask << 16) |
                  (mask << 12) | ((0x100u | output) << 3) | (mux << 2);
}
static AliasCase alias_case(unsigned family, unsigned mac, unsigned swizzle,
                            unsigned outputMux, unsigned outputMask,
                            unsigned tempMask)
{
    AliasCase c = { 0 };
    c.family = family;
    c.mac = mac;
    c.ilu = family == 0 ? 0 : 1;
    c.swizzle = swizzle;
    c.output_mux = outputMux;
    c.output_mask = outputMask;
    c.temp_mask = tempMask;
    c.tokens[0] = alias_token(1, 0, 0);
    alias_source(&c.tokens[0], 0, 2, 0, 0xe4);
    alias_destination(&c.tokens[0], 0, 15, 0, 0, 0);
    c.tokens[1] = alias_token(mac, family == 0 ? 0 : 1, 1);
    alias_source(&c.tokens[1], 0, family == 0 ? 1 : 2, family == 0 ? 12 : 0,
                 0xe4);
    alias_source(&c.tokens[1], 1, 2, 0, 0xe4);
    alias_source(&c.tokens[1], 2, family == 0 ? 2 : 1, family == 0 ? 0 : 12,
                 swizzle);
    alias_destination(&c.tokens[1], 0, outputMask, outputMux,
                      family == 2 ? 0 : tempMask,
                      family == 0 ? 0 : (family == 1 ? 15 : tempMask));
    for (unsigned i = 2; i < 5; i++) {
        c.tokens[i] = alias_token(1, 0, 0);
        alias_source(&c.tokens[i], 0, 1, i == 2 ? 2 : i == 3 ? 1 : 12, 0xe4);
        alias_destination(&c.tokens[i], i + 7, 15, 0, 0, 0);
    }
    c.tokens[4].word[3] |= 1;
    const float a[4] = { 1, 2, 3, 4 }, b[4] = { 5, 6, 7, 8 };
    for (unsigned k = 0; k < 4; k++) {
        unsigned lane = (swizzle >> (2 * k)) & 3;
        float vector = family == 0 ?
                           (mac == 3 ? a[k] + b[lane] : a[k] * b[k] + b[lane]) :
                       mac == 1 ? b[k] :
                       mac == 3 ? b[k] + a[lane] :
                                  b[k] * b[k] + a[lane];
        float scalar = a[lane]; /* ILU MOV remains a vector operation. */
        float selected = outputMux ? scalar : vector;
        c.expected[0][k] = outputMask & (8u >> k) ? selected : a[k];
        c.expected[1][k] =
            tempMask & (8u >> k) ? (family == 2 ? scalar : vector) : 0;
        c.expected[2][k] = family == 1 ? scalar : 0;
        c.expected[3][k] = c.expected[0][k];
    }
    return c;
}

/* Original envytools NV20 ILU version2, pinned
 * f102b82381f3f11cee113d16374c87091db039d9. swizzles of [1,2,3,4]: identity,
 * reverse, xxxx, wwww. */
static const uint32_t alias_family_ilu[4][7][4] = {
    {
        { 0x3f800000u, 0x40000000u, 0x40400000u, 0x40800000u },
        { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
        { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
        { 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu },
        { 0x40000000u, 0x00000000u, 0x40000000u, 0x3f800000u },
        { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
        { 0x3f800000u, 0x3f800000u, 0x41800000u, 0x3f800000u },
    },
    {
        { 0x40800000u, 0x40400000u, 0x40000000u, 0x3f800000u },
        { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
        { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
        { 0x3effffffu, 0x3effffffu, 0x3effffffu, 0x3effffffu },
        { 0x41800000u, 0x00000000u, 0x41800000u, 0x3f800000u },
        { 0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u },
        { 0x3f800000u, 0x40800000u, 0x404001e0u, 0x3f800000u },
    },
    {
        { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
        { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
        { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
        { 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu, 0x3f7fffffu },
        { 0x40000000u, 0x00000000u, 0x40000000u, 0x3f800000u },
        { 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u },
        { 0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u },
    },
    {
        { 0x40800000u, 0x40800000u, 0x40800000u, 0x40800000u },
        { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
        { 0x3e800000u, 0x3e800000u, 0x3e800000u, 0x3e800000u },
        { 0x3effffffu, 0x3effffffu, 0x3effffffu, 0x3effffffu },
        { 0x41800000u, 0x00000000u, 0x41800000u, 0x3f800000u },
        { 0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u },
        { 0x3f800000u, 0x40800000u, 0x43800000u, 0x3f800000u },
    },
};
static inline AliasCase alias_ilu(AliasCase fixture, unsigned ilu)
{
    fixture.ilu = ilu;
    fixture.tokens[1].word[1] =
        (fixture.tokens[1].word[1] & ~(7u << 25)) | (ilu << 25);
    unsigned sw = fixture.swizzle == 0xe4 ? 0 :
                  fixture.swizzle == 0x1b ? 1 :
                  fixture.swizzle == 0    ? 2 :
                                            3;
    for (unsigned k = 0; k < 4; k++) {
        float value;
        memcpy(&value, &alias_family_ilu[sw][ilu - 1][k], 4);
        fixture.expected[2][k] = value;
        if (fixture.output_mux && (fixture.output_mask & (8u >> k))) {
            fixture.expected[0][k] = value;
            fixture.expected[3][k] = value;
        }
    }
    return fixture;
}
#endif
