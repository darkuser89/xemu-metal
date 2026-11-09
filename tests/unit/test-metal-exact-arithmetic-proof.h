/* Exact CPU domains are checked against the unchanged GPU interpreters.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_EXACT_ARITHMETIC_PROOF_H
#define TEST_METAL_EXACT_ARITHMETIC_PROOF_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-program.h"
#include <limits.h>

typedef struct ExactArithmeticCase {
    const char *name;
    unsigned opcode, lane;
    uint32_t a[4], b[4], c[4], scale, intermediate, final;
    int address; /* INT_MAX means the real ARL faults, not a numeric domain. */
    uint32_t adjustment;
    unsigned base;
} ExactArithmeticCase;
#define EAP4(x) { x, x, x, x }
/* These are individual arithmetic witnesses, not a second implementation of
 * the integer proof. In particular MAD truncates the product before adding,
 * whereas DOT aligns all products together before its one sum. */
static const ExactArithmeticCase eap_cases[] = {
    { "large product then reciprocal scale", NV2AMetalMACMul, 0,
      EAP4(0x49800000), EAP4(0x49800000), EAP4(0), 0x2b800000, 0x53800000,
      0x3f800000, 1, 0, 96 },
    { "large exact ADD cancellation", NV2AMetalMACAdd, 0, EAP4(0x71800000),
      EAP4(0x7fc12345), EAP4(0xf1800000), 0, 0, 0, 0, 0, 96 },
    { "large MAD cancellation", NV2AMetalMACMad, 0, EAP4(0x49800000),
      EAP4(0x49800000), EAP4(0xd3800000), 0, 0, 0, 0, 0, 96 },
    { "MUL RZ differs from nearest-even", NV2AMetalMACMul, 0, EAP4(0x3f800001),
      EAP4(0x3fc00000), EAP4(0x7fc12345), 0x4b000000, 0x3fc00001, 0, 0,
      0xbfc00001, 191 },
    { "ADD truncates three-quarter ULP", NV2AMetalMACAdd, 0, EAP4(0x3f800000),
      EAP4(0), EAP4(0x33c00000), 0x4b000000, 0x3f800000, 0, 0, 0xbf800000,
      191 },
    { "MAD separate RZ product is not FMA", NV2AMetalMACMad, 0,
      EAP4(0x3f800001), EAP4(0x3f7ffffe), EAP4(0xbf800000), 0x4b800000,
      0xb3800000, 0, 0, 0x33800000, 191 },
    { "DP3 common alignment drops tiny residual",
      NV2AMetalMACDp3,
      0,
      { 0x49800000, 0x49800000, 0x3f800000, 0x7fc12345 },
      { 0x49800000, 0xc9800000, 0x3f800000, 0x7fc12345 },
      EAP4(0),
      0,
      0,
      0,
      0,
      0,
      191 },
    { "DP4 common alignment is not pairwise ADD",
      NV2AMetalMACDp4,
      0,
      { 0x49800000, 0x49800000, 0x3f800000, 0x3f800000 },
      { 0x49800000, 0xc9800000, 0x3f800000, 0x3f800000 },
      EAP4(0),
      0,
      0,
      0,
      0,
      0,
      191 },
    { "DPH replaces unused NaN A.w by one",
      NV2AMetalMACDph,
      0,
      { 0x49800000, 0xc9800000, 0, 0x7fc12345 },
      EAP4(0x3f800000),
      EAP4(0),
      0,
      0x3f800000,
      0x3f800000,
      1,
      0,
      96 },
    { "DST.y large product ignores unused NaN X",
      NV2AMetalMACDst,
      1,
      { 0x7fc12345, 0x49800000, 0, 0 },
      { 0x7fc12345, 0x49800000, 0, 0 },
      EAP4(0),
      0x2b800000,
      0x53800000,
      0x3f800000,
      1,
      0,
      96 },
    { "normal product underflows to negative zero", NV2AMetalMACMul, 0,
      EAP4(0x80800000), EAP4(0x3f000000), EAP4(0), 0, 0x80000000, 0x80000000, 0,
      0, 96 },
    { "subnormal input is positive-zero winner", NV2AMetalMACMul, 0,
      EAP4(0x80000001), EAP4(0x7f7fffff), EAP4(0), 0, 0, 0, 0, 0, 96 },
    { "negative zero multiply returns positive zero", NV2AMetalMACMul, 0,
      EAP4(0x80000000), EAP4(0xbf800000), EAP4(0), 0, 0, 0, 0, 0, 96 },
    { "sum of negative zeros returns positive zero", NV2AMetalMACAdd, 0,
      EAP4(0x80000000), EAP4(0), EAP4(0x80000000), 0, 0, 0, 0, 0, 96 },
    { "MUL finite saturation before scale", NV2AMetalMACMul, 0,
      EAP4(0x7f7fffff), EAP4(0x40000000), EAP4(0), 0x00800000, 0x7f7fffff,
      0x407fffff, 4, 0, 96 },
    { "ADD finite saturation before scale", NV2AMetalMACAdd, 0,
      EAP4(0x7f7fffff), EAP4(0), EAP4(0x7f7fffff), 0x00800000, 0x7f7fffff,
      0x407fffff, 4, 0, 96 },
    { "DP3 retains representable cancellation residual",
      NV2AMetalMACDp3,
      0,
      { 0x49800000, 0xc9800000, 0x3f800000, 0x7fc12345 },
      { 0x3f800000, 0x3f800000, 0x3f800000, 0x7fc12345 },
      EAP4(0),
      0,
      0x3f800000,
      0x3f800000,
      1,
      0,
      96 },
    { "DP4 retained guard bits then scale",
      NV2AMetalMACDp4,
      0,
      { 0x53800000, 0xd3800000, 0x48000000, 0x48000000 },
      EAP4(0x3f800000),
      EAP4(0),
      0x36800000,
      0x48800000,
      0x3f800000,
      1,
      0,
      96 },
    { "negative exact offset USER vs FULL", NV2AMetalMACAdd, 0,
      EAP4(0xc0000000), EAP4(0), EAP4(0x3f800000), 0, 0xbf800000, 0xbf800000,
      -1, 0, 96 },
    { "last valid relative row", NV2AMetalMACAdd, 0, EAP4(0x42bc0000), EAP4(0),
      EAP4(0x3f800000), 0, 0x42be0000, 0x42be0000, 95, 0, 96 },
    { "one past constant bank", NV2AMetalMACAdd, 0, EAP4(0x42be0000), EAP4(0),
      EAP4(0x3f800000), 0, 0x42c00000, 0x42c00000, 96, 0, 96 },
    { "needed NaN stays unproven", NV2AMetalMACMul, 0, EAP4(0x7fc12345),
      EAP4(0x3f800000), EAP4(0), 0, 0x7fffffff, 0x7fffffff, INT_MAX, 0, 96 },
    { "opposite infinities stay unproven", NV2AMetalMACAdd, 0, EAP4(0x7f800000),
      EAP4(0), EAP4(0xff800000), 0, 0x7fffffff, 0x7fffffff, INT_MAX, 0, 96 },
    { "unscaled finite huge ARL faults", NV2AMetalMACMul, 0, EAP4(0x49800000),
      EAP4(0x49800000), EAP4(0), 0, 0x53800000, 0x53800000, INT_MAX, 0, 96 },
    { "MAD saturates product before cancellation", NV2AMetalMACMad, 0,
      EAP4(0x7f7fffff), EAP4(0x40000000), EAP4(0xff7fffff), 0, 0, 0, 0, 0, 96 },
};
#undef EAP4

static unsigned eap_tokens(Token t[9], const ExactArithmeticCase *c)
{
    t[0] = token(NV2AMetalMACMov, 0, 0);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    for (unsigned i = 0; i < 3; i++) {
        t[1 + i] = token(NV2AMetalMACMov, 0, 100 + i);
        source(t + 1 + i, 0, 3, 0, 0xe4);
        destination(t + 1 + i, 0, 0, 0, 4 + i, 15, 0);
    }
    t[4] = token(c->opcode, 0, 0);
    for (unsigned i = 0; i < 3; i++)
        source(t + 4, i, 1, 4 + i, 0xe4);
    destination(t + 4, 0x109, 15, 0, 2, 15, 0);
    unsigned n = 5, lane = c->lane;
    if (c->adjustment) {
        /* An incorrect nearest/FMA bit becomes a different whole ARL row.
         * At base191, true0 is legal and wrong1 reaches forbidden row192. */
        t[n] = token(NV2AMetalMACAdd, 0, 104);
        source(t + n, 0, 1, 2, lane * 0x55);
        source(t + n, 2, 3, 0, 0);
        destination(t + n++, 0, 0, 0, 2, 15, 0);
        lane = 0;
    }
    t[n] = token(c->scale ? NV2AMetalMACMul : NV2AMetalMACMov, 0, 103);
    source(t + n, 0, 1, 2, lane * 0x55);
    source(t + n, 1, 3, 0, 0);
    destination(t + n++, 0x10a, 15, 0, 2, 15, 0);
    t[n] = token(NV2AMetalMACArl, 0, 0);
    source(t + n++, 0, 1, 2, 0);
    t[n] = token(NV2AMetalMACMov, 0, c->base);
    source(t + n, 0, 3, 0, 0xe4);
    destination(t + n, 0x103, 15, 0, 0, 0, 0);
    t[n++].word[3] |= 3;
    return n;
}
static unsigned eap_fault(int address, unsigned access, unsigned base)
{
    if (address == INT_MAX)
        return NV2AMetalProgramFaultAddressRange;
    int64_t row = (int64_t)base + address;
    if (row < 0 || row >= 192 || (!access && row < 96))
        return NV2AMetalProgramFaultConstantRange;
    return 0;
}
static void eap_run(NV2AMetalWritableProgram *engine,
                    SpecializedReadonlyReference *reference,
                    NV2AMetalVertexProgram *generic,
                    NV2AMetalCommands *commands, const Token *t,
                    unsigned length, NV2AMetalProgramUniforms *u,
                    const NV2AMetalProgramInput *input, unsigned count,
                    const uint32_t *intermediate, const uint32_t *final,
                    const int *addresses, unsigned lane, unsigned base,
                    unsigned access, BOOL admitted, const char *name)
{
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:length
                                                    error:&error];
    require(program != nil, error);
    BOOL cold = [program hasFaultFreeReadOnlyAccess:access
                                          constants:u->constants[0]];
    BOOL warm = [program hasFaultFreeReadOnlyAccess:access
                                          constants:u->constants[0]];
    require([commands beginWithError:&error] != nil, error);
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:count * sizeof(*input)
                                    options:MTLResourceStorageModeShared];
    require(attributes != nil, nil);
    NV2AMetalProgramResult *rawGPU = [generic encodeTokens:t[0].word
                                                    length:length
                                                  uniforms:u
                                                attributes:attributes
                                                     count:count
                                                  commands:commands
                                                     error:&error];
    NV2AMetalWritableEncoding *full = [reference encodeProgram:program
                                                      uniforms:u
                                               attributeBuffer:attributes
                                                         first:0
                                                         count:count
                                                        access:access
                                                   writeEnable:NO
                                                     rasterize:YES
                                              compactRegisters:NO
                                                      commands:commands
                                                         error:&error];
    NV2AMetalWritableEncoding *compact = [engine encodeProgram:program
                                                      uniforms:u
                                               attributeBuffer:attributes
                                                         first:0
                                                         count:count
                                                        access:access
                                                   writeEnable:NO
                                                     rasterize:YES
                                              compactRegisters:YES
                                                      commands:commands
                                                         error:&error];
    require(rawGPU && full && compact, error);
    BOOL pending = [compact canUsePendingReadOnlyResultForCommands:commands];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    const NV2AMetalProgramOutput *raw = rawGPU.registers.contents;
    id<MTLBuffer> fullBuffer = [full valueForKey:@"raw"],
                  compactFault = [compact valueForKey:@"raw"];
    const NV2AMetalProgramOutput *fullRaw = fullBuffer.contents;
    assert(compactFault.length >= sizeof(uint32_t));
    const uint32_t *faultSummary = compactFault.contents;
    id<MTLBuffer> fullVertices = [full valueForKey:@"vertices"],
                  compactVertices = [compact valueForKey:@"vertices"];
    BOOL safe = YES;
    uint32_t expectedSummary = 0;
    for (unsigned i = 0; i < count; i++) {
        uint32_t mid, end;
        memcpy(&mid, raw[i].registers[9] + lane, 4);
        memcpy(&end, raw[i].registers[10], 4);
        if (mid != intermediate[i] || end != final[i]) {
            fprintf(stderr,
                    "Exact arithmetic GPU bits %s access%u vertex%u "
                    "mid%08x/%08x end%08x/%08x\n",
                    name, access, i, mid, intermediate[i], end, final[i]);
            abort();
        }
        assert(!memcmp(fullRaw[i].registers[9] + lane, &mid, 4) &&
               !memcmp(fullRaw[i].registers[10], &end, 4));
        unsigned fault = eap_fault(addresses[i], access, base);
        unsigned genericFault = eap_fault(addresses[i], 1, base);
        if (raw[i].fault != genericFault || fullRaw[i].fault != fault) {
            fprintf(stderr,
                    "Exact arithmetic GPU fault %s access%u vertex%u "
                    "generic%u/%u full%u/%u\n",
                    name, access, i, raw[i].fault, genericFault,
                    fullRaw[i].fault, fault);
            abort();
        }
        expectedSummary |= fault;
        safe &= !fault;
    }
    if (*faultSummary != expectedSummary) {
        fprintf(stderr,
                "Exact arithmetic compact fault %s access%u vertices%u "
                "summary%u/%u\n",
                name, access, count, *faultSummary, expectedSummary);
        abort();
    }
    assert(!memcmp(fullVertices.contents, compactVertices.contents,
                   count * sizeof(NV2AMetalVertex)));
    NV2AMetalWritableResult *a = [compact resolveWithError:NULL],
                            *b = [full resolveWithError:NULL];
    assert(!!a == safe && !!b == safe);
    if (safe)
        assert([a.constants isEqualToData:b.constants] &&
               [a.written isEqualToData:b.written]);
    // Bit/vertex/fault oracles precede metadata assertions, including mutants.
    if (cold != admitted || warm != admitted || pending != admitted) {
        fprintf(stderr,
                "Exact arithmetic admission %s access%u cold%d warm%d "
                "pending%d expected%d\n",
                name, access, cold, warm, pending, admitted);
        abort();
    }
}

static unsigned eap_union_tokens(Token t[9])
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
    destination(t + 3, 0, 0, 0, 2, 8, 0);
    t[3].word[3] |= 2;
    t[4] = token(NV2AMetalMACAdd, 0, 122);
    source(t + 4, 0, 1, 2, 0);
    source(t + 4, 2, 3, 0, 0);
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
static void exact_arithmetic_proof_tests(NV2AMetalWritableProgram *engine,
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
    for (unsigned v = 0; v < 2; v++) {
        input[v].attributes[0][0] = input[v].attributes[0][1] = 1;
        input[v].attributes[0][2] = 8;
        input[v].attributes[0][3] = 1;
        input[v].attributes[1][0] = v ? 1 : -1;
    }
    unsigned triples = 0;
    for (unsigned i = 0; i < ARRAY_SIZE(eap_cases); i++) {
        const ExactArithmeticCase *c = eap_cases + i;
        Token t[9];
        unsigned length = eap_tokens(t, c);
        NV2AMetalProgramUniforms u = uniforms();
        memcpy(u.constants[100], c->a, 16);
        memcpy(u.constants[101], c->b, 16);
        memcpy(u.constants[102], c->c, 16);
        memcpy(u.constants[103], &c->scale, 4);
        memcpy(u.constants[104], &c->adjustment, 4);
        for (unsigned access = 0; access < 2; access++) {
            eap_run(engine, reference, generic, commands, t, length, &u, input,
                    1, &c->intermediate, &c->final, &c->address, c->lane,
                    c->base, access, !eap_fault(c->address, access, c->base),
                    c->name);
            triples++;
        }
    }
    for (unsigned variant = 0; variant < 3; variant++) {
        Token t[9];
        unsigned length = eap_union_tokens(t);
        NV2AMetalProgramUniforms u = uniforms();
        const uint32_t constants[][2] = { { 0x53800000, 0x53800000 },
                                          { 0x53800000, 0x53800001 },
                                          { 0x53800000, 0x7fc12345 } };
        uint32_t zero = 0, negative = 0xd3800000, coefficient = 0x37000000;
        memcpy(u.constants[119], &zero, 4);
        memcpy(u.constants[120], constants[variant], 4);
        memcpy(u.constants[121], constants[variant] + 1, 4);
        memcpy(u.constants[122], &negative, 4);
        memcpy(u.constants[123], &coefficient, 4);
        uint32_t mid[2] = { variant == 1 ? 0x48000000 :
                            variant == 2 ? 0x7fffffff :
                                           0,
                            0 };
        uint32_t end[2] = { variant == 1 ? 0x3f800000 :
                            variant == 2 ? 0x7fffffff :
                                           0,
                            0 };
        int address[2] = { variant == 1 ? 1 : variant == 2 ? INT_MAX : 0, 0 };
        for (unsigned access = 0; access < 2; access++) {
            eap_run(engine, reference, generic, commands, t, length, &u, input,
                    2, mid, end, address, 0, 96, access, variant == 0,
                    "relative constant union");
            triples++;
        }
    }
    assert(triples == 56);
    printf("Exact arithmetic proof:%u bare-generic/full/compact GPU triples, "
           "hand-written RZ bits; "
           "ADD/MUL/MAD/DP3/DPH/DP4/DST,large "
           "intermediate/cancellation,non-FMA/dot order,"
           "FTZ/signedzero/finite saturation,USER/FULL and mixed-union "
           "rejection PASS\n",
           triples);
}
#endif
