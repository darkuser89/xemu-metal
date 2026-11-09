/* Exact immutable suffix witnesses reuse readonly plans across descriptors.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_READONLY_INDEX_PLAN_REUSE_H
#define TEST_METAL_READONLY_INDEX_PLAN_REUSE_H
@interface NV2AMetalPGRAPHFetch (ReadonlyIndexPlanReuseTest)
- (BOOL)canReuseReadonlyIndexPlanForInput:(NV2AMetalPendingInput *)input
                                   prefix:(NSUInteger)prefix;
@end
static _Thread_local __unsafe_unretained NV2AMetalPGRAPHFetch *rpr_old;
static _Thread_local const void *rpr_key_pointer;
static _Thread_local NSUInteger rpr_key_length, rpr_key_calls;
static _Thread_local BOOL rpr_nil_key;
static _Thread_local const char *rpr_group;
static _Thread_local NSUInteger rpr_pair_number;
static BOOL (*rpr_reuse_original)(id, SEL, NV2AMetalPendingInput *, NSUInteger);
static BOOL rpr_reuse(id owner, SEL selector, NV2AMetalPendingInput *input,
                      NSUInteger prefix)
{
    return owner != rpr_old &&
           rpr_reuse_original(owner, selector, input, prefix);
}
static id (*rpr_key_original)(id, SEL, const void *, NSUInteger);
static id rpr_key(id owner, SEL selector, const void *bytes, NSUInteger length)
{
    if (rpr_key_pointer && bytes == rpr_key_pointer &&
        length == rpr_key_length) {
        rpr_key_calls++;
        if (rpr_nil_key)
            return nil;
    }
    return rpr_key_original(owner, selector, bytes, length);
}
static NSUInteger rpr_payload(NV2AMetalPGRAPHFetch *owner)
{
    NSUInteger payload =
        rip_payload(owner) +
        [[owner valueForKey:@"floatProofPayload"] unsignedIntegerValue];
    assert(payload <= 65536);
    return payload;
}
static NSMutableData *rpr_words(NSUInteger count)
{
    NSMutableData *words = [NSMutableData dataWithLength:count * 4];
    uint32_t *p = words.mutableBytes;
    for (NSUInteger i = 0; i < count; i++)
        p[i] = (uint32_t)((i * 13 + 19) % 32);
    p[count - 1] = 7; /* Current is not the last physical unique record. */
    return words;
}
static NV2AMetalPendingInput *rpr_input(NSData *words)
{
    NV2AMetalPendingInput *input =
        rip_input(words.bytes, words.length / 4, nil);
    require(input != nil, nil);
    return input;
}
typedef struct ReadonlyReuseWork {
    NSUInteger builds, data, copies, keys;
} ReadonlyReuseWork;
static NSArray *rpr_observe(NV2AMetalPGRAPHFetch *owner,
                            NV2AMetalPendingInput *input, NSUInteger prefix,
                            BOOL host, BOOL old, BOOL dedupe,
                            ReadonlyReuseWork *work)
{
    rip_reset_counts();
    rpr_key_calls = 0;
    rpr_key_pointer = (const uint8_t *)input.indices.bytes + prefix * 4;
    rpr_key_length = (input.count - prefix) * 4;
    rpr_old = old ? owner : nil;
    NSArray *result;
    @try {
        result = rip_run(owner, input, prefix, host, dedupe);
    } @finally {
        rpr_old = nil;
        rpr_key_pointer = NULL;
    }
    *work =
        (ReadonlyReuseWork){ rip_builds, rip_data, rip_copies, rpr_key_calls };
    rpr_payload(owner);
    return result;
}
/* Both captures use new owners of immutable bytes. NO changes only the new
 * cross-descriptor matcher; the original identity fast path stays intact. */
static void rpr_pair(NV2AMetalPGRAPHFetch *actual,
                     NV2AMetalPGRAPHFetch *reference, NSData *words,
                     NSUInteger prefix, BOOL host, NSUInteger expectedBuilds)
{
    NV2AMetalPendingInput *a = rpr_input(words), *b = rpr_input(words);
    assert(a != b && a.indices != b.indices);
    ReadonlyReuseWork aw = { 0 }, bw = { 0 };
    NSArray *one = rpr_observe(actual, a, prefix, host, NO, YES, &aw);
    NSArray *two = rpr_observe(reference, b, prefix, host, YES, YES, &bw);
    assert([one isEqualToArray:two]); /* All GPU/Current/archive bytes first. */
    rpr_pair_number++;
    if (aw.builds != expectedBuilds || bw.builds != 1) {
        fprintf(
            stderr,
            "Readonly reuse group%s pair%lu prefix%lu host%u count%lu "
            "expected%lu actual%lu ref%lu data%lu/%lu copies%lu/%lu "
            "keys%lu/%lu keyLength%lu/%lu computed%u/%u "
            "sequenceMatches%u/%u boundInput%u/%u first%u last%u\n",
            rpr_group, (unsigned long)rpr_pair_number, (unsigned long)prefix,
            host, (unsigned long)a.count, (unsigned long)expectedBuilds,
            (unsigned long)aw.builds, (unsigned long)bw.builds,
            (unsigned long)aw.data, (unsigned long)bw.data,
            (unsigned long)aw.copies, (unsigned long)bw.copies,
            (unsigned long)aw.keys, (unsigned long)bw.keys,
            (unsigned long)[[actual valueForKey:@"indexRangesKey"] length],
            (unsigned long)[[reference valueForKey:@"indexRangesKey"] length],
            [[actual valueForKey:@"readonlyIndexComputed"] boolValue],
            [[reference valueForKey:@"readonlyIndexComputed"] boolValue],
            [actual valueForKey:@"readonlyIndexSequence"] ==
                [actual valueForKey:@"indexRangesKey"],
            [reference valueForKey:@"readonlyIndexSequence"] ==
                [reference valueForKey:@"indexRangesKey"],
            [actual valueForKey:@"indexRangesInput"] == a,
            [reference valueForKey:@"indexRangesInput"] == b,
            ((const uint32_t *)words.bytes)[0],
            ((const uint32_t *)words.bytes)[a.count - 1]);
        abort();
    }
    if (!expectedBuilds)
        assert(!aw.data && !aw.copies);
}
static void rpr_sequences(void)
{
    rpr_group = "sequences";
    rpr_pair_number = 0;
    for (unsigned host = 0; host < 2; host++) {
        arp_setup();
        tcg_allowed = YES;
        NV2AMetalPGRAPHFetch *a = arp_owner(), *b = arp_owner();
        NSMutableData *words = rpr_words(6144);
        rpr_pair(a, b, words, 0, host, 1);
        rpr_pair(a, b, words, 0, host, 0);
        rpr_pair(a, b, words, 0, host, 0);
        assert([[a valueForKey:@"readonlyUniqueIndices"] length] == 32 * 4 &&
               [[a valueForKey:@"readonlyRemap"] length] == 6144 * 4);
        /* Same selected set is insufficient: first-occurrence order, every
         * remap and final Current ordinal must follow the new sequence. */
        uint32_t *p = words.mutableBytes;
        uint32_t first = p[0];
        memmove(p, p + 1, (6144 - 1) * 4);
        p[6143] = first;
        rpr_pair(a, b, words, 0, host, 1);
        rpr_pair(a, b, words, 0, host, 0);
        p[6143] = 18;
        rpr_pair(a, b, words, 0, host, 1);
        rpr_pair(a, b, words, 2048, host, 1);
        rpr_pair(a, b, words, 2048, host, 0);
        rpr_pair(a, b, words, 2049, host, 1);
        [a close];
        [b close];
        groups++;
    }
}
static void rpr_negative_and_growth(void)
{
    rpr_group = "negative-growth";
    rpr_pair_number = 0;
    arp_setup();
    tcg_allowed = YES;
    NV2AMetalPGRAPHFetch *a = arp_owner(), *b = arp_owner();
    NSMutableData *words = [NSMutableData dataWithLength:64 * 4];
    for (unsigned shape = 0; shape < 3; shape++) {
        for (unsigned i = 0; i < 64; i++)
            ((uint32_t *)words.mutableBytes)[i] = shape == 2 ?
                                                      (i * 13 + 19) % 64 :
                                                  shape ? 63 - i :
                                                          i;
        rpr_pair(a, b, words, 0, NO, 1);
        rpr_pair(a, b, words, 0, NO, 0);
        assert([[a valueForKey:@"readonlyIndexComputed"] boolValue] &&
               ![a valueForKey:@"readonlyUniqueIndices"] &&
               ![a valueForKey:@"readonlyRemap"]);
    }
    const uint32_t small[] = { 5, 2, 5, 1, 2, 5, 2, 1 };
    NV2AMetalPendingInput *old = rip_input(small, 6, nil);
    ReadonlyReuseWork work = { 0 };
    rpr_observe(a, old, 0, NO, NO, YES, &work);
    NV2AMetalPendingInput *grown = rip_input(small, 8, old);
    assert(old.indices != grown.indices &&
           old.indices.bytes == grown.indices.bytes);
    NSArray *one = rpr_observe(a, grown, 0, NO, NO, YES, &work);
    NV2AMetalPendingInput *fresh = rip_input(small, 8, nil);
    ReadonlyReuseWork rw = { 0 };
    NSArray *two = rpr_observe(b, fresh, 0, NO, YES, YES, &rw);
    assert([one isEqualToArray:two] && work.builds == 1);
    words = [NSMutableData dataWithBytes:small length:sizeof(small)];
    rpr_pair(a, b, words, 0, NO, 0);
    [a close];
    [b close];
    groups++;
}
static void rpr_lifetime_and_guards(void)
{
    rpr_group = "lifetime-guards";
    rpr_pair_number = 0;
    arp_setup();
    tcg_allowed = YES;
    NV2AMetalPGRAPHFetch *a = arp_owner(), *b = arp_owner();
    NSMutableData *words = rpr_words(6144);
    __weak NV2AMetalPendingInput *weakInput;
    __weak NSData *weakData;
    @autoreleasepool {
        NV2AMetalPendingInput *input = rpr_input(words);
        weakInput = input;
        weakData = input.indices;
        ReadonlyReuseWork work = { 0 };
        rpr_observe(a, input, 0, NO, NO, YES, &work);
    }
    assert(!weakInput && !weakData);
    rpr_pair(a, b, words, 0, NO,
             0); /* Only the exact range-key witness survives. */
    NV2AMetalPendingInput *input = rpr_input(words);
    NSError *error = nil;
    require(rip_encode(a, input, 0, NO, YES, &error) != nil, error);
    [a cancel];
    rpr_pair(a, b, words, 0, NO, 0);
    VertexAttribute saved = state->pgraph.vertex_attributes[0];
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        state->pgraph.vertex_attributes[0] = saved;
        dma_a.limit = invalid == 0 ? 15 : 65535;
        if (invalid == 1)
            state->pgraph.vertex_attributes[0].format = UINT32_MAX;
        if (invalid == 2)
            state->pgraph.vertex_attributes[0].stride = UINT32_MAX;
        error = nil;
        rip_reset_counts();
        NV2AMetalPendingInput *fresh = rpr_input(words);
        assert(!rip_encode(a, fresh, 0, NO, YES, &error) && error &&
               !rip_builds);
    }
    state->pgraph.vertex_attributes[0] = saved;
    dma_a.limit = 65535;
    rpr_pair(a, b, words, 0, NO, 0);
    /* The writer/non-deduplicating contract still runs every logical record. */
    ReadonlyReuseWork aw = { 0 }, bw = { 0 };
    NSArray *one = rpr_observe(a, rpr_input(words), 0, NO, NO, NO, &aw);
    NSArray *two = rpr_observe(b, rpr_input(words), 0, NO, YES, NO, &bw);
    assert([one isEqualToArray:two] && !aw.builds && !bw.builds);
    [a close];
    [b close];
    assert(![a valueForKey:@"readonlyRemap"] &&
           ![[a valueForKey:@"readonlyIndexComputed"] boolValue]);
    groups++;
}
static void rpr_optional_keys(void)
{
    rpr_group = "optional-keys";
    rpr_pair_number = 0;
    arp_setup();
    tcg_allowed = YES;
    NV2AMetalPGRAPHFetch *a = arp_owner(), *b = arp_owner();
    NSMutableData *words = rpr_words(6144);
    rpr_nil_key = YES;
    for (unsigned i = 0; i < 2; i++) {
        NV2AMetalPendingInput *input = rpr_input(words);
        ReadonlyReuseWork aw = { 0 }, bw = { 0 };
        NSArray *one = rpr_observe(a, input, 0, NO, NO, YES, &aw);
        NSArray *two = rpr_observe(b, rpr_input(words), 0, NO, YES, YES, &bw);
        assert([one isEqualToArray:two] && aw.builds == 1 && bw.builds == 1);
        assert(aw.keys == 1 && bw.keys == 1 &&
               ![a valueForKey:@"indexRangesKey"]);
        /* Optional byte-key OOM cannot invalidate the old identity fastpath. */
        one = rpr_observe(a, input, 0, NO, NO, YES, &aw);
        assert([one isEqualToArray:two] && !aw.builds);
    }
    rpr_nil_key = NO;
    /* Existing range identity may have no optional key. Change the sequence
     * to construct a genuinely new keyed plan, then prove reuse/retry. */
    ((uint32_t *)words.mutableBytes)[0] = 31;
    rpr_pair(a, b, words, 0, NO, 1);
    rpr_pair(a, b, words, 0, NO, 0);
    [a close];
    [b close];
    groups++;
}
static void rpr_oom(void)
{
    rpr_group = "builder-oom";
    rpr_pair_number = 0;
    for (unsigned failure = 0; failure < 4; failure++) {
        arp_setup();
        tcg_allowed = YES;
        NV2AMetalPGRAPHFetch *a = arp_owner(), *b = arp_owner();
        NSMutableData *words = rpr_words(6144);
        ReadonlyReuseWork aw = { 0 }, bw = { 0 };
        rip_nil_data = failure < 2 ? failure + 1 : 0;
        rip_nil_copy = failure >= 2 ? failure - 1 : 0;
        NSArray *one = rpr_observe(a, rpr_input(words), 0, NO, NO, YES, &aw);
        NSArray *two = rpr_observe(b, rpr_input(words), 0, NO, YES, YES, &bw);
        rip_nil_data = rip_nil_copy = 0;
        assert([one isEqualToArray:two]);
        assert(aw.builds == 1 && bw.builds == 1 && aw.data == 2 &&
               bw.data == 2 && aw.copies == (failure < 2 ? 0 : 2) &&
               bw.copies == aw.copies &&
               ![[a valueForKey:@"readonlyIndexComputed"] boolValue] &&
               ![a valueForKey:@"readonlyRemap"]);
        rpr_pair(a, b, words, 0, NO, 1);
        rpr_pair(a, b, words, 0, NO, 0);
        [a close];
        [b close];
        groups++;
    }
}
static void rpr_eviction(void)
{
    rpr_group = "eviction";
    rpr_pair_number = 0;
    arp_setup();
    tcg_allowed = YES;
    NV2AMetalPGRAPHFetch *a = arp_owner(), *b = arp_owner();
    NSMutableData *words = rpr_words(6144);
    rpr_pair(a, b, words, 0, NO, 1);
    /* Real, valid sparse DMA records occupy the entire shared plan budget. */
    NSMutableData *sparse = [NSMutableData dataWithLength:4096 * 4];
    for (unsigned i = 0; i < 4096; i++)
        ((uint32_t *)sparse.mutableBytes)[i] = i * 2;
    state->pgraph.vertex_attributes[0].count = 4;
    state->pgraph.vertex_attributes[0].stride = 4;
    NV2AMetalPendingInput *input = rpr_input(sparse);
    index_ranges_run(a, input, 0, NO);
    assert([[a valueForKey:@"indexRanges"] length] == 65536 &&
           ![a valueForKey:@"readonlyRemap"] && rpr_payload(a) == 65536);
    state->pgraph.vertex_attributes[0].stride = 16;
    rpr_pair(a, b, words, 0, NO, 1);
    rpr_pair(a, b, words, 0, NO, 0);
    [a close];
    [b close];
    groups++;
}
static void readonly_index_plan_reuse_tests(void)
{
    NSError *error = nil;
    rip_xf = [[NV2AMetalWritableProgram alloc]
        initWithDevice:surfaces.commands.device
                 error:&error];
    require(rip_xf != nil, error);
    Method reuse = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(canReuseReadonlyIndexPlanForInput:prefix:));
    Method builder = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(buildReadonlyIndices:prefix:remap:current:computed:));
    Method data =
        class_getClassMethod(NSMutableData.class, @selector(dataWithLength:));
    Method key =
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:));
    Class concrete = object_getClass([NSMutableData dataWithLength:32]);
    Method originalCopy =
        class_getInstanceMethod(concrete, @selector(copyWithZone:));
    Method copyHook = class_getInstanceMethod(NSMutableData.class,
                                              @selector(rip_copyWithZone:));
    class_addMethod(concrete, @selector(copyWithZone:),
                    method_getImplementation(originalCopy),
                    method_getTypeEncoding(originalCopy));
    class_addMethod(concrete, @selector(rip_copyWithZone:),
                    method_getImplementation(copyHook),
                    method_getTypeEncoding(copyHook));
    originalCopy = class_getInstanceMethod(concrete, @selector(copyWithZone:));
    Method replacementCopy =
        class_getInstanceMethod(concrete, @selector(rip_copyWithZone:));
    assert(reuse && builder && data && key && originalCopy && replacementCopy);
    rpr_reuse_original = (void *)method_getImplementation(reuse);
    rip_builder_original = (void *)method_getImplementation(builder);
    rip_data_original = (void *)method_getImplementation(data);
    rpr_key_original = (void *)method_getImplementation(key);
    BOOL savedTCG = tcg_allowed;
    method_setImplementation(reuse, (IMP)rpr_reuse);
    method_setImplementation(builder, (IMP)rip_builder);
    method_setImplementation(data, (IMP)rip_data_factory);
    method_setImplementation(key, (IMP)rpr_key);
    method_exchangeImplementations(originalCopy, replacementCopy);
    @try {
        rpr_sequences();
        rpr_negative_and_growth();
        rpr_lifetime_and_guards();
        rpr_optional_keys();
        rpr_oom();
        rpr_eviction();
    } @finally {
        rpr_old = nil;
        rpr_key_pointer = NULL;
        rpr_nil_key = NO;
        rip_building = rip_fail = NO;
        rip_nil_data = rip_nil_copy = 0;
        tcg_allowed = savedTCG;
        method_exchangeImplementations(originalCopy, replacementCopy);
        method_setImplementation(key, (IMP)rpr_key_original);
        method_setImplementation(data, (IMP)rip_data_original);
        method_setImplementation(builder, (IMP)rip_builder_original);
        method_setImplementation(reuse, (IMP)rpr_reuse_original);
        rip_xf = nil;
    }
    puts("Readonly index plan reuse: new immutable descriptors, full "
         "GPU/XF/Current/archive bytes; exact sequence/prefix/weak "
         "lifetime/budget/OOM guards PASS");
}
#endif
