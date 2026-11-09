/* Relative choices retain a large value only when every row is identical.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_LARGE_UNION_PROOF_H
#define TEST_METAL_LARGE_UNION_PROOF_H

static void large_union_tokens(Token t[6], unsigned base)
{
    t[0] = token(NV2AMetalMACMov, 0, 96);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    t[1] = token(NV2AMetalMACSlt, 0, 96);
    t[1].word[1] |= 1u << 9;
    source(t + 1, 0, 2, 0, 0);
    source(t + 1, 1, 1, 0, 0);
    destination(t + 1, 0, 0, 0, 2, 8, 0);
    t[2] = token(NV2AMetalMACArl, 0, 96);
    source(t + 2, 0, 1, 2, 0);
    t[3] = token(NV2AMetalMACMul, 0, base);
    source(t + 3, 0, 3, 0, 0);
    source(t + 3, 1, 3, 0, 0x55);
    destination(t + 3, 0x109, 15, 0, 3, 8, 0);
    t[3].word[3] |= 2;
    t[4] = token(NV2AMetalMACArl, 0, 96);
    source(t + 4, 0, 1, 3, 0);
    t[5] = token(NV2AMetalMACMov, 0, 160);
    source(t + 5, 0, 3, 0, 0xe4);
    destination(t + 5, 0x103, 15, 0, 0, 0, 0);
    t[5].word[3] |= 3;
}

static void large_union_constants(NV2AMetalProgramUniforms *u, unsigned base,
                                  unsigned mode)
{
    for (unsigned i = 0; i < 2 && base + i < 192; i++) {
        const uint32_t pair[] = {mode == 1 ? 0xf1800000u : 0x71800000u,
                                 0x0d800000};
        memcpy(u->constants[base + i], pair, sizeof(pair));
    }
    if (base + 1 >= 192)
        return;
    uint32_t value = 0;
    switch (mode) {
    case 2:
        value = 0x72000000;
        break;
    case 3:
        value = 0x0e000000;
        break;
    case 4:
        value = 0x7fc12345;
        break;
    case 5:
        value = 0x7f800000;
        break;
    case 6:
        value = 0xf1800000;
        break;
    case 7:
        value = 0;
        break;
    case 8:
        value = 0x7fc12345;
        break;
    default:
        return;
    }
    unsigned lane = mode == 3 ? 1 : mode == 8 ? 2 : 0;
    memcpy(u->constants[base + 1] + lane, &value, 4);
}

static void large_union_cache_tests(void)
{
    NSError *error = nil;
    Token t[6];
    large_union_tokens(t, 100);
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:6
                                                    error:&error];
    require(program != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    large_union_constants(&u, 100, 0);
    for (unsigned access = 0; access < 2; access++)
        assert([program hasFaultFreeReadOnlyAccess:access
                                         constants:u.constants[0]]);
    NSData *key = [program valueForKey:@"constantProofInputs"];
    for (unsigned epoch = 0; epoch < 32; epoch++) {
        memcpy(u.constants[101] + 2, &(uint32_t){0x7fc12345u + epoch}, 4);
        assert([program hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]]);
        assert([program valueForKey:@"constantProofInputs"] == key);
    }
    for (unsigned mode = 2; mode < 8; mode++) {
        large_union_constants(&u, 100, mode);
        assert(![program hasFaultFreeReadOnlyAccess:0
                                          constants:u.constants[0]]);
        large_union_constants(&u, 100, 0);
        assert([program hasFaultFreeReadOnlyAccess:0 constants:u.constants[0]]);
    }
    puts("Large union cache:32 irrelevant-lane epochs reuse proof; changed "
         "large/coefficient/NaN/Inf/sign/zero rows invalidate it PASS");
}

static void large_union_span_tests(void)
{
    NSError *error = nil;
    unsigned checked = 0;
    for (unsigned base = 0; base < 192; base++) {
        Token original[6], t[7];
        large_union_tokens(original, base);
        memcpy(t, original, 2 * sizeof(Token));
        memcpy(t + 3, original + 2, 4 * sizeof(Token));
        t[2] = token(NV2AMetalMACMul, 0, 96);
        source(t + 2, 0, 1, 2, 0);
        source(t + 2, 1, 3, 0, 0xaa);
        destination(t + 2, 0, 0, 0, 2, 8, 0);
        NV2AMetalValidatedProgram *program =
            [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                       length:7
                                                        error:&error];
        require(program != nil, error);
        NV2AMetalProgramUniforms u = uniforms();
        for (unsigned row = 0; row < 192; row++) {
            const uint32_t values[] = {0x71800000, 0x0d800000};
            memcpy(u.constants[row], values, sizeof(values));
        }
        for (unsigned width = 2; width <= 193 - base; width++) {
            u.constants[96][2] = width - 1;
            for (unsigned access = 0; access < 2; access++) {
                BOOL safe = base + width <= 192 && (access || base >= 96);
                assert([program
                           hasFaultFreeReadOnlyAccess:access
                                            constants:u.constants[0]] == safe);
                checked++;
                if (!safe)
                    continue;
                /* A late mismatch must invalidate both an earlier admitted
                 * proof and the union; checking only its first rows is unsafe.
                 */
                unsigned last = base + width - 1;
                memcpy(u.constants[last], &(uint32_t){0x72000000}, 4);
                assert(![program hasFaultFreeReadOnlyAccess:access
                                                  constants:u.constants[0]]);
                memcpy(u.constants[last], &(uint32_t){0x71800000}, 4);
                assert([program hasFaultFreeReadOnlyAccess:access
                                                 constants:u.constants[0]]);
            }
        }
    }
    assert(checked == 37056);
    printf("Large union spans: %u aperture checks, every base and width, "
           "last-row mismatch/cache restoration, USER/FULL PASS (CPU only)\n",
           checked);
}

static void large_union_gpu_tests(NV2AMetalCommands *commands)
{
    large_union_cache_tests();
    large_union_span_tests();
    NSError *error = nil;
    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput vertices[4];
    const uint32_t selectors[] = {0xbf800000, 0x3f800000, 0x80000000,
                                  0x7fc12345};
    for (unsigned i = 0; i < 4; i++) {
        writable_input(vertices + i, i);
        memcpy(vertices[i].attributes[1], selectors + i, 4);
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    const unsigned bases[] = {0, 58, 59, 95, 96, 100, 190, 191};
    unsigned before = constant_idx_pairs;
    unsigned beforeSafe = constant_idx_safe, beforeFaults = constant_idx_faults;
    for (unsigned mode = 0; mode < 9; mode++)
        for (unsigned b = 0; b < 8; b++)
            for (unsigned access = 0; access < 2; access++) {
                NV2AMetalProgramUniforms u = uniforms();
                large_union_constants(&u, bases[b], mode);
                Token t[6];
                large_union_tokens(t, bases[b]);
                BOOL identical = mode == 0 || mode == 1 || mode == 8;
                BOOL safe =
                    identical && bases[b] < 191 && (access || bases[b] >= 96);
                constant_idx_pair(commands, reference, t, 6, &u, attributes,
                                  access, safe, -1);
            }
    printf(
        "Large relative union: %u compact/full GPU pairs/%u admitted; "
        "SLT/ARL/relative MUL/ARL, both row choices, USER/FULL/58/59/192, "
        "finite identity/mismatch/NaN/Inf/sign/zero and exact contexts PASS\n",
        constant_idx_pairs - before, constant_idx_safe - beforeSafe);
    constant_idx_pairs = before;
    constant_idx_safe = beforeSafe;
    constant_idx_faults = beforeFaults;
}
#endif
