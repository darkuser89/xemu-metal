/* Raw NV2A test tokens, following the existing vertex-program test.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_VERTEX_CONTEXT_H
#define TEST_METAL_VERTEX_CONTEXT_H
#include <stdint.h>
typedef struct Token {
    uint32_t word[4];
} Token;
static Token token(unsigned mac, unsigned ilu, unsigned constant)
{
    Token t = { { 0, (mac << 21) | (ilu << 25) | (constant << 13), 0, 0 } };
    return t;
}
static void source(Token *t, unsigned operand, unsigned mux, unsigned reg,
                   unsigned swizzle)
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
    for (unsigned i = 0; i < 4; i++)
        t->word[word] |= ((swizzle >> (2 * i)) & 3) << (start - 2 * i);
}
static void destination(Token *t, unsigned row, unsigned mask, unsigned mux,
                        unsigned temp, unsigned macMask, unsigned iluMask)
{
    t->word[3] &= ~0x0ffffffcu;
    t->word[3] |= (macMask << 24) | (temp << 20) | (iluMask << 16) |
                  (mask << 12) | (row << 3) | (mux << 2);
}

#endif
