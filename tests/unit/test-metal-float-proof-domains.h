/* Host Float summaries versus the unchanged scalar numerical proof.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FLOAT_PROOF_DOMAINS_H
#define TEST_METAL_FLOAT_PROOF_DOMAINS_H

static NV2AMetalValidatedProgram *fpd_program(BOOL writer, BOOL reciprocal)
{
    Token t[6];
    unsigned n = 0;
    t[n] = token(NV2AMetalMACMov, 0, 0);
    source(t + n, 0, 2, 0, 0xe4);
    destination(t + n++, 0x100, 15, 0, 0, 0, 0);
    if (reciprocal) {
        t[n] = token(0, NV2AMetalILURcp, 0);
        t[n].word[1] |= 15u << 9;
        source(t + n, 2, 2, 0, 0xff);
        destination(t + n++, 0, 0, 0, 2, 0, 8);
    }
    t[n] = token(NV2AMetalMACArl, 0, 0);
    t[n].word[1] |= 15u << 9;
    source(t + n++, 0, reciprocal ? 1 : 2, reciprocal ? 2 : 0,
           reciprocal ? 0 : 0xff);
    t[n] = token(NV2AMetalMACMov, 0, 96);
    source(t + n, 0, 3, 0, 0);
    destination(t + n, 0x103, 8, 0, 0, 0, 0);
    t[n++].word[3] |= 2;
    if (writer) {
        t[n] = token(NV2AMetalMACMov, 0, 0);
        t[n].word[1] |= 5u << 9;
        source(t + n, 0, 2, 0, 0xe4);
        destination(t + n++, 150, 4, 0, 0, 0, 0);
    }
    t[n - 1].word[3] |= 1;
    NSError *error = nil;
    NV2AMetalValidatedProgram *p =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:n
                                                    error:&error];
    require(p != nil, error);
    assert(p.readonlyProofAttributeLanes64 == (UINT64_C(1) << 63));
    return p;
}
static uint32_t fpd_order(uint32_t bits)
{
    return bits & 0x80000000u ? ~bits : bits ^ 0x80000000u;
}
/* Build a truthful numeric fixture from all its source values. This helper
 * never attaches a summary to a Fetch result or grants encoder provenance. */
static NSData *fpd_summary(const uint32_t *values, NSUInteger count)
{
    assert(count);
    NV2AMetalFloatLaneSummary lanes[64] = { 0 };
    NV2AMetalFloatLaneSummary *s = lanes + 63;
    s->minBits = s->maxBits = values[0];
    s->minExponent = 255;
    s->flags = NV2AMetalFloatLaneSummaryFinite;
    for (NSUInteger i = 0; i < count; i++) {
        uint32_t bits = values[i];
        if (fpd_order(bits) < fpd_order(s->minBits))
            s->minBits = bits;
        if (fpd_order(bits) > fpd_order(s->maxBits))
            s->maxBits = bits;
        unsigned exponent = (bits >> 23) & 255;
        s->minExponent = MIN(s->minExponent, exponent);
        if (exponent == 255)
            s->flags = 0;
    }
    return [NSData dataWithBytes:lanes length:sizeof(lanes)];
}
static BOOL fpd_query(NV2AMetalValidatedProgram *p, BOOL writer,
                      unsigned access, const NV2AMetalProgramUniforms *u,
                      const NV2AMetalFetchUniforms *f, NSData *summary,
                      uint64_t mask)
{
    return writer ? [p hasIndependentConstantWrites:access
                                          constants:u->constants[0]
                                     sourceUniforms:f
                                     floatSummaries:summary
                                           laneMask:mask] :
                    [p hasFaultFreeReadOnlyAccess:access
                                        constants:u->constants[0]
                                   sourceUniforms:f
                                   floatSummaries:summary
                                         laneMask:mask];
}
static BOOL fpd_scalar(NV2AMetalValidatedProgram *p, BOOL writer,
                       unsigned access, const NV2AMetalProgramUniforms *u,
                       NV2AMetalFetchUniforms f, uint32_t bits)
{
    f.attributes[15].count = 0;
    memcpy(f.attributes[15].inline_value + 3, &bits, sizeof(bits));
    return writer ? [p hasIndependentConstantWrites:access
                                          constants:u->constants[0]
                                     sourceUniforms:&f] :
                    [p hasFaultFreeReadOnlyAccess:access
                                        constants:u->constants[0]
                                   sourceUniforms:&f];
}
static void float_proof_domain_tests(void)
{
    struct Fixture {
        uint32_t values[4];
        unsigned count, direct, reciprocal;
    } fixtures[] = {
        { { 0, 0x3f800000, 0x40000000 }, 3, 3, 0 },
        { { 0xbf800000, 0, 0x3f800000 }, 3, 2, 0 },
        { { 0xbf800000, 0x3f800000 }, 2, 2, 2 },
        { { 0x80000000, 0 }, 2, 3, 0 },
        { { 0, 0x42be0000 }, 2, 3, 0 },
        { { 0, 0x42c00000 }, 2, 0, 0 },
        { { 0x7fc12345 }, 1, 0, 0 },
        { { 0xff800000, 0x7f800000 }, 2, 0, 0 },
        { { 0x71800000, 0xf1800000 }, 2, 0, 0 },
        { { 0x71800000, 0x71800000 }, 2, 0, 2 },
        { { 1, 0x80000001 }, 2, 2, 0 },
        { { 0x40000000, 0x40800000 }, 2, 3, 3 },
    };
    unsigned checks = 0;
    for (unsigned writer = 0; writer < 2; writer++)
        for (unsigned reciprocal = 0; reciprocal < 2; reciprocal++) {
            NV2AMetalValidatedProgram *p = fpd_program(writer, reciprocal);
            NV2AMetalProgramUniforms u = uniforms();
            NV2AMetalFetchUniforms f = { 0 };
            f.attributes[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
            f.attributes[15].count = 4;
            f.attributes[15].stride = 16;
            for (unsigned i = 0; i < sizeof(fixtures) / sizeof(fixtures[0]);
                 i++) {
                @autoreleasepool {
                    struct Fixture fixture = fixtures[i];
                    unsigned allowed =
                        reciprocal ? fixture.reciprocal : fixture.direct;
                    NSData *s = fpd_summary(fixture.values, fixture.count);
                    for (unsigned access = 0; access < 2; access++) {
                        /* First warm the old unknown cache, then change only
                         * its numerical input. Neither cached NO nor YES may
                         * bypass freshly translated summary domains. */
                        assert(!fpd_query(p, writer, access, &u, &f, nil, 0));
                        BOOL expected = !!(allowed & (1u << access));
                        assert(fpd_query(p, writer, access, &u, &f, s,
                                         UINT64_C(1) << 63) == expected);
                        assert(fpd_query(p, writer, access, &u, &f, s,
                                         UINT64_C(1) << 63) == expected);
                        if (expected)
                            for (unsigned v = 0; v < fixture.count; v++)
                                assert(fpd_scalar(p, writer, access, &u, f,
                                                  fixture.values[v]));
                        assert(!fpd_query(p, writer, access, &u, &f, s, 1));
                        assert(!fpd_query(
                            p, writer, access, &u, &f,
                            [s subdataWithRange:NSMakeRange(0, 1023)],
                            UINT64_C(1) << 63));
                        f.attributes[15].stride = 0;
                        assert(!fpd_query(p, writer, access, &u, &f, s,
                                          UINT64_C(1) << 63));
                        f.attributes[15].stride = 16;
                        checks++;
                    }
                }
            }
        }
    printf("Float proof domains:%u readonly/writer/access cases; old scalar "
           "proof witnesses, zero-interior reciprocal, exact large values, "
           "NaN/Inf, raw zero signs, cache transitions and invalid metadata "
           "remain conservative PASS (CPU only)\n",
           checks);
}
#endif
