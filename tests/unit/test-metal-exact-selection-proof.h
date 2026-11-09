/* Hand-written selection witnesses, using the unchanged arithmetic GPU oracle.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_EXACT_SELECTION_PROOF_H
#define TEST_METAL_EXACT_SELECTION_PROOF_H

typedef enum ExactSelectionPost {
    ESPDirect,
    ESPScale,
    ESPBooleanScale,
    ESPLess,
    ESPGreaterEqual
} ExactSelectionPost;
typedef struct ExactSelectionCase {
    const char *name;
    unsigned opcode;
    uint32_t a, b, selected;
    ExactSelectionPost post;
    uint32_t threshold, bias;
    BOOL negateResult;
    uint32_t final;
    int address;
    unsigned base;
    BOOL conservative;
    unsigned aComponent, bComponent;
    BOOL negateA, negateB;
} ExactSelectionCase;
/* No CPU comparison implementation supplies these expected bits. The gain
 * witnesses finish at base191+0; choosing the other operand produces row192
 * (or beyond), so a wrong CPU selection cannot hide in a safe ARL interval. */
static const ExactSelectionCase esp_cases[] = {
    { "MIN large then fractional scale", NV2AMetalMACMin, 0x53800000,
      0x54000000, 0x53800000, ESPScale, 0, 0xbf800000, NO, 0, 0, 191, NO, 0, 0,
      NO, NO },
    { "MAX large then fractional scale", NV2AMetalMACMax, 0x53800000,
      0x54000000, 0x54000000, ESPScale, 0, 0x40000000, YES, 0, 0, 191, NO, 0, 0,
      NO, NO },
    { "true SLT then huge product and scale", NV2AMetalMACSlt, 0, 0x3f800000,
      0x3f800000, ESPBooleanScale, 0, 0x3f800000, YES, 0, 0, 191, NO, 0, 0, NO,
      NO },
    { "true SGE then huge product and scale", NV2AMetalMACSge, 0x3f800000, 0,
      0x3f800000, ESPBooleanScale, 0, 0x3f800000, YES, 0, 0, 191, NO, 0, 0, NO,
      NO },
    { "MIN reversed operands", NV2AMetalMACMin, 0x54000000, 0x53800000,
      0x53800000, ESPScale, 0, 0xbf800000, NO, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MAX reversed operands", NV2AMetalMACMax, 0x54000000, 0x53800000,
      0x54000000, ESPScale, 0, 0x40000000, YES, 0, 0, 191, NO, 0, 0, NO, NO },
    { "false SLT control", NV2AMetalMACSlt, 0x3f800000, 0, 0, ESPBooleanScale,
      0, 0, NO, 0, 0, 191, NO, 0, 0, NO, NO },
    { "false SGE control", NV2AMetalMACSge, 0, 0x3f800000, 0, ESPBooleanScale,
      0, 0, NO, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MIN negative large", NV2AMetalMACMin, 0xd3800000, 0xd4000000, 0xd4000000,
      ESPScale, 0, 0x40000000, NO, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MAX negative large", NV2AMetalMACMax, 0xd3800000, 0xd4000000, 0xd3800000,
      ESPScale, 0, 0xbf800000, YES, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MIN negative zero stays raw before comparison", NV2AMetalMACMin,
      0x80000000, 0, 0x80000000, ESPLess, 0, 0x3f800000, YES, 0, 0, 191, NO, 0,
      0, NO, NO },
    { "MAX positive zero stays raw before comparison", NV2AMetalMACMax,
      0x80000000, 0, 0, ESPGreaterEqual, 0, 0x3f800000, YES, 0, 0, 191, NO, 0,
      0, NO, NO },
    { "SLT negative zero below positive zero", NV2AMetalMACSlt, 0x80000000, 0,
      0x3f800000, ESPBooleanScale, 0, 0x3f800000, YES, 0, 0, 191, NO, 0, 0, NO,
      NO },
    { "SGE negative zero below positive zero", NV2AMetalMACSge, 0x80000000, 0,
      0, ESPBooleanScale, 0, 0, NO, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MIN raw subnormal survives selection", NV2AMetalMACMin, 1, 2, 1, ESPLess,
      2, 0x3f800000, YES, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MAX raw subnormal survives selection", NV2AMetalMACMax, 1, 2, 2,
      ESPGreaterEqual, 2, 0x3f800000, YES, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MIN swizzle and negated subnormal", NV2AMetalMACMin, 1, 2, 0x80000001,
      ESPLess, 0x80000000, 0x3f800000, YES, 0, 0, 191, NO, 2, 3, YES, NO },
    { "MAX swizzled negated inputs", NV2AMetalMACMax, 0xbf800000, 0x40000000,
      0x3f800000, ESPDirect, 0, 0x3f800000, YES, 0, 0, 191, NO, 3, 2, YES,
      YES },
    { "MIN identical large bits", NV2AMetalMACMin, 0x53800000, 0x53800000,
      0x53800000, ESPScale, 0, 0xbf800000, NO, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MAX identical negative bits", NV2AMetalMACMax, 0xd3800000, 0xd3800000,
      0xd3800000, ESPScale, 0, 0xbf800000, YES, 0, 0, 191, NO, 0, 0, NO, NO },
    { "MIN actual row192 fault", NV2AMetalMACMin, 0x3f800000, 0x40000000,
      0x3f800000, ESPDirect, 0, 0, NO, 0x3f800000, 1, 191, NO, 0, 0, NO, NO },
    { "MAX row95 USER versus FULL", NV2AMetalMACMax, 0xc0000000, 0xbf800000,
      0xbf800000, ESPDirect, 0, 0, NO, 0xbf800000, -1, 96, NO, 0, 0, NO, NO },
    { "needed NaN conservatively rejected despite finite MIN", NV2AMetalMACMin,
      0x3f800000, 0x7fc12345, 0x3f800000, ESPDirect, 0, 0, NO, 0x3f800000, 1,
      96, YES, 0, 0, NO, NO },
    { "needed Infinity stays unproven", NV2AMetalMACMax, 0x3f800000, 0x7f800000,
      0x7f800000, ESPDirect, 0, 0, NO, 0x7f800000, INT_MAX, 96, YES, 0, 0, NO,
      NO },
};
static unsigned esp_tokens(Token t[12], const ExactSelectionCase *c)
{
    t[0] = token(NV2AMetalMACMov, 0, 0);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    for (unsigned i = 0; i < 2; i++) {
        t[1 + i] = token(NV2AMetalMACMov, 0, 100 + i);
        source(t + 1 + i, 0, 3, 0, 0xe4);
        destination(t + 1 + i, 0, 0, 0, 4 + i, 15, 0);
    }
    t[3] = token(c->opcode, 0, 0);
    source(t + 3, 0, 1, 4, c->aComponent * 0x55);
    source(t + 3, 1, 1, 5, c->bComponent * 0x55);
    if (c->negateA)
        t[3].word[1] |= 1u << 8;
    if (c->negateB)
        t[3].word[2] |= 1u << 25;
    destination(t + 3, 0x109, 15, 0, 2, 15, 0);
    unsigned n = 4;
    if (c->post == ESPBooleanScale) {
        t[n] = token(NV2AMetalMACMul, 0, 102);
        source(t + n, 0, 1, 2, 0);
        source(t + n, 1, 3, 0, 0);
        destination(t + n++, 0, 0, 0, 2, 15, 0);
    }
    if (c->post == ESPScale || c->post == ESPBooleanScale) {
        t[n] = token(NV2AMetalMACMul, 0, 103);
        source(t + n, 0, 1, 2, 0);
        source(t + n, 1, 3, 0, 0);
        destination(t + n++, 0, 0, 0, 2, 15, 0);
    } else if (c->post == ESPLess || c->post == ESPGreaterEqual) {
        // A raw comparison makes loss of zero sign or subnormal bits visible
        // to the subsequent whole-row admission test, without arithmetic FTZ.
        t[n] = token(c->post == ESPLess ? NV2AMetalMACSlt : NV2AMetalMACSge, 0,
                     104);
        source(t + n, 0, 1, 2, 0);
        source(t + n, 1, 3, 0, 0);
        destination(t + n++, 0, 0, 0, 2, 15, 0);
    }
    t[n] = token(NV2AMetalMACAdd, 0, 105);
    source(t + n, 0, 1, 2, 0);
    source(t + n, 2, 3, 0, 0);
    if (c->negateResult)
        t[n].word[1] |= 1u << 8;
    destination(t + n++, 0x10a, 15, 0, 2, 15, 0);
    t[n] = token(NV2AMetalMACArl, 0, 0);
    source(t + n++, 0, 1, 2, 0);
    t[n] = token(NV2AMetalMACMov, 0, c->base);
    source(t + n, 0, 3, 0, 0xe4);
    destination(t + n, 0x103, 15, 0, 0, 0, 0);
    t[n++].word[3] |= 3;
    return n;
}
static unsigned esp_union_tokens(Token t[12])
{
    t[0] = token(NV2AMetalMACMov, 0, 0);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    t[1] = token(NV2AMetalMACSlt, 0, 119);
    t[1].word[1] |= 1u << 9;
    source(t + 1, 0, 2, 0, 0);
    source(t + 1, 1, 3, 0, 0);
    destination(t + 1, 0, 0, 0, 1, 8, 0);
    t[2] = token(NV2AMetalMACArl, 0, 0);
    source(t + 2, 0, 1, 1, 0);
    t[3] = token(NV2AMetalMACMov, 0, 120);
    source(t + 3, 0, 3, 0, 0);
    destination(t + 3, 0, 0, 0, 4, 15, 0);
    t[3].word[3] |= 2;
    t[4] = token(NV2AMetalMACMin, 0, 122);
    source(t + 4, 0, 1, 4, 0);
    source(t + 4, 1, 3, 0, 0);
    destination(t + 4, 0x109, 15, 0, 2, 15, 0);
    t[5] = token(NV2AMetalMACMul, 0, 123);
    source(t + 5, 0, 1, 2, 0);
    source(t + 5, 1, 3, 0, 0);
    destination(t + 5, 0x10a, 15, 0, 2, 15, 0);
    t[6] = token(NV2AMetalMACArl, 0, 0);
    source(t + 6, 0, 1, 2, 0);
    t[7] = token(NV2AMetalMACMov, 0, 96);
    source(t + 7, 0, 3, 0, 0xe4);
    destination(t + 7, 0x103, 15, 0, 0, 0, 0);
    t[7].word[3] |= 3;
    return 8;
}
static void exact_selection_proof_tests(NV2AMetalWritableProgram *engine,
                                        NV2AMetalCommands *commands)
{
    NSError *error = nil;
    SpecializedReadonlyReference *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    NV2AMetalVertexProgram *generic =
        [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                 error:&error];
    require(reference && generic, error);
    NV2AMetalProgramInput input[2] = { 0 };
    for (unsigned i = 0; i < 2; i++) {
        input[i].attributes[0][0] = input[i].attributes[0][1] = 1;
        input[i].attributes[0][2] = 8;
        input[i].attributes[0][3] = 1;
        input[i].attributes[1][0] = i ? 1 : -1;
    }
    unsigned triples = 0;
    for (unsigned i = 0; i < ARRAY_SIZE(esp_cases); i++) {
        const ExactSelectionCase *c = esp_cases + i;
        Token t[12];
        unsigned length = esp_tokens(t, c);
        NV2AMetalProgramUniforms u = uniforms();
        // Unused components deliberately contain nonfinite bits. Only the
        // selected swizzle lanes are relevant to this exact proof.
        const uint32_t unused[] = { 0x7fc12345, 0xff800000, 0x7f800000,
                                    0x7fc54321 };
        memcpy(u.constants[100], unused, 16);
        memcpy(u.constants[101], unused, 16);
        memcpy(u.constants[100] + c->aComponent, &c->a, 4);
        memcpy(u.constants[101] + c->bComponent, &c->b, 4);
        const uint32_t large = 0x53800000, small = 0x2b800000;
        memcpy(u.constants[102], &large, 4);
        memcpy(u.constants[103], &small, 4);
        memcpy(u.constants[104], &c->threshold, 4);
        memcpy(u.constants[105], &c->bias, 4);
        for (unsigned access = 0; access < 2; access++) {
            BOOL admitted =
                !c->conservative && !eap_fault(c->address, access, c->base);
            eap_run(engine, reference, generic, commands, t, length, &u, input,
                    1, &c->selected, &c->final, &c->address, 0, c->base, access,
                    admitted, c->name);
            triples++;
        }
    }
    for (unsigned variant = 0; variant < 4; variant++) {
        Token t[12];
        unsigned length = esp_union_tokens(t);
        NV2AMetalProgramUniforms u = uniforms();
        const uint32_t zero = 0, large = 0x53800000, threshold = 0x54000000,
                       small = 0x2b800000;
        const uint32_t alternatives[] = { 0x53800000, 0x54000000, 0x7fc12345,
                                          0x7f800000 };
        memcpy(u.constants[119], &zero, 4);
        memcpy(u.constants[120], &large, 4);
        memcpy(u.constants[121], alternatives + variant, 4);
        memcpy(u.constants[122], &threshold, 4);
        memcpy(u.constants[123], &small, 4);
        const uint32_t selected[] = { variant ? 0x54000000 : 0x53800000,
                                      0x53800000 };
        const uint32_t final[] = { variant ? 0x40000000 : 0x3f800000,
                                   0x3f800000 };
        const int addresses[] = { variant ? 2 : 1, 1 };
        for (unsigned access = 0; access < 2; access++) {
            eap_run(engine, reference, generic, commands, t, length, &u, input,
                    2, selected, final, addresses, 0, 96, access, variant == 0,
                    "selection relative union");
            triples++;
        }
    }
    assert(triples == 56);
    puts("Exact selection proof:56 bare-generic/full/compact GPU triples; "
         "MIN/MAX large and true SLT/SGE large-product gains,hand bits and "
         "row192,"
         "reverse/negative/swizzle/negation/signedzero/subnormal/samebits,"
         "USER/FULL,needed NaN/Inf and mixed relative-union rejection PASS");
}
#endif
