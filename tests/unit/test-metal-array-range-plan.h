/* Pure DrawArrays range metadata reuse with fresh native GPU fetches.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ARRAY_RANGE_PLAN_H
#define TEST_METAL_ARRAY_RANGE_PLAN_H

static BOOL arp_observing;
static NSUInteger arp_sorts, arp_keys, arp_key_length, arp_pairs;
static const uint32_t arp_observed_key[] = { 1, 4, 2, 0, 0, 2, 0, 8, 2, 0 };
static id (*arp_original_data)(id, SEL, const void *, NSUInteger);

typedef struct ArrayRangeComparator {
    int (*compare)(const void *, const void *);
} ArrayRangeComparator;
static int arp_compare(void *context, const void *a, const void *b)
{
    return ((ArrayRangeComparator *)context)->compare(a, b);
}
/* Keep the real sort semantics for every caller in this native test binary.
 * Count only calls during the explicitly observed fetch, with one DMA lane
 * and a single dirty-page run so unrelated planning needs no sorting. */
void qsort(void *base, size_t count, size_t width,
           int (*compare)(const void *, const void *))
{
    if (arp_observing)
        arp_sorts++;
    ArrayRangeComparator context = { compare };
    qsort_r(base, count, width, &context, arp_compare);
}
static id arp_data(id object, SEL selector, const void *bytes, NSUInteger size)
{
    if (arp_observing && size == arp_key_length &&
        !memcmp(bytes, arp_observed_key, size))
        arp_keys++;
    return arp_original_data(object, selector, bytes, size);
}
static void arp_uncache(NV2AMetalPGRAPHFetch *owner)
{
    [owner setValue:nil forKey:@"arrayRangesKey"];
    [owner setValue:nil forKey:@"arrayRanges"];
}
static NSUInteger arp_payload(NV2AMetalPGRAPHFetch *owner)
{
    NSUInteger total = 0;
    for (NSString *key in @[
             @"arrayRangesKey", @"arrayRanges", @"indexRangesKey",
             @"indexRanges"
         ])
        total += ((NSData *)[owner valueForKey:key]).length;
    assert(total <= 65536);
    return total;
}
static void arp_setup(void)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    cpu_write(1024, 60000);
    for (unsigned i = 0; i < 15000; i++) {
        float value = i + .25f;
        memcpy(state->vram_ptr + 1024 + i * 4, &value, 4);
    }
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
}
static NV2AMetalPGRAPHFetch *arp_owner(void)
{
    NSError *error = nil;
    NV2AMetalPGRAPHFetch *owner =
        [[NV2AMetalPGRAPHFetch alloc] initWithState:state
                                           surfaces:surfaces
                                              error:&error];
    require(owner != nil, error);
    return owner;
}
static NSArray *arp_encode(NV2AMetalPGRAPHFetch *owner, NSArray *prefixes,
                           BOOL host, NSError **error)
{
    return host ? [owner encodeCurrentSnapshotsWithPrefixes:prefixes
                                               indexedInput:nil
                                                      error:error] :
                  [owner encodeIndependentSnapshotsWithPrefixes:prefixes
                                                   indexedInput:nil
                                                          error:error];
}
static NSData *arp_run(NV2AMetalPGRAPHFetch *owner, NSArray *prefixes,
                       BOOL host)
{
    NSError *error = nil;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
        arp_encode(owner, prefixes, host, &error);
    require(batches != nil, error);
    require(host ? [owner completeCurrentSnapshotsWithError:&error] :
                   [owner completeWithError:&error],
            error);
    if (host)
        require([surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error],
                error);
    NSMutableData *result = [NSMutableData new];
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        const NSUInteger metadata[] = { batch.firstVertex,
                                        batch.firstDecodedVertex,
                                        batch.inputVertexCount,
                                        batch.fetch.vertexCount };
        [result appendBytes:metadata length:sizeof(metadata)];
        if (batch.fetch.faults) {
            uint32_t fault;
            memcpy(&fault,
                   (uint8_t *)batch.fetch.faults.contents +
                       batch.fetch.faultSummaryOffset,
                   4);
            assert(!fault);
        }
        NSUInteger bytes =
            batch.fetch.vertexCount * sizeof(NV2AMetalProgramInput);
        if (bytes)
            [result appendBytes:batch.fetch.attributes.contents length:bytes];
    }
    for (unsigned lane = 0; lane < 16; lane++)
        [result appendBytes:state->pgraph.vertex_attributes[lane].inline_value
                     length:16];
    arp_payload(owner);
    return result;
}
static void arp_pair(NV2AMetalPGRAPHFetch *owner, NSArray *prefixes, BOOL host)
{
    /* Each side uses the production fetch/guard path. Only the reference's
     * pure metadata cache is cleared; no shader or mapping formula is cloned.
     */
    NSData *warm = arp_run(owner, prefixes, host);
    NSData *key = [owner valueForKey:@"arrayRangesKey"];
    NSData *ranges = [owner valueForKey:@"arrayRanges"];
    NSData *again = arp_run(owner, prefixes, host);
    assert(key == [owner valueForKey:@"arrayRangesKey"] &&
           ranges == [owner valueForKey:@"arrayRanges"] &&
           [warm isEqualToData:again]);
    arp_uncache(owner);
    NSData *reference = arp_run(owner, prefixes, host);
    assert([warm isEqualToData:reference] &&
           [key isEqualToData:[owner valueForKey:@"arrayRangesKey"]] &&
           [ranges isEqualToData:[owner valueForKey:@"arrayRanges"]]);
    arp_pairs++;
}
static void arp_reject(NV2AMetalPGRAPHFetch *owner, NSArray *prefixes)
{
    NSError *error = nil;
    assert(!arp_encode(owner, prefixes, NO, &error) && error);
    assert(!owner.encodingCommands && !surfaces.commands.commandBuffer);
}
static void arp_layouts(void)
{
    for (unsigned tcg = 0; tcg < 2; tcg++)
        for (unsigned host = 0; host < 2; host++) {
            arp_setup();
            tcg_allowed = tcg;
            NV2AMetalPGRAPHFetch *owner = arp_owner();
            PGRAPHState *pg = &state->pgraph;
            pg->draw_arrays_length = 3;
            const int32_t starts[][3] = {
                { 4, 0, 3 }, { 0, 4, 3 }, { 0, 0, 4 }, { 0, 2, 4 }
            };
            for (unsigned shape = 0; shape < ARRAY_SIZE(starts); shape++) {
                memcpy(pg->draw_arrays_start, starts[shape],
                       sizeof(starts[shape]));
                for (unsigned i = 0; i < 3; i++)
                    pg->draw_arrays_count[i] = 2;
                for (unsigned prefix = 0; prefix < 3; prefix++)
                    arp_pair(owner, @[ @(prefix), @2, @(2 - prefix) ], host);
            }
            /* Nil and explicit zero prefixes have exactly the same key. */
            arp_run(owner, nil, host);
            NSData *key = [owner valueForKey:@"arrayRangesKey"];
            NSData *ranges = [owner valueForKey:@"arrayRanges"];
            arp_run(owner, @[ @0, @0, @0 ], host);
            assert(key == [owner valueForKey:@"arrayRangesKey"] &&
                   ranges == [owner valueForKey:@"arrayRanges"]);
            /* Maximum ties select the last batch, including an accepted
             * Current whose earlier equal-maximum batch still has a suffix. */
            const int32_t tied[] = { 4, 0, 4 };
            memcpy(pg->draw_arrays_start, tied, sizeof(tied));
            arp_pair(owner, @[ @0, @0, @2 ], host);
            assert([[owner valueForKey:@"arrayRangesCurrentBatch"]
                       unsignedIntegerValue] == 2 &&
                   [[owner valueForKey:@"arrayRangesMaximum"]
                       unsignedIntegerValue] == 5);
            float expected[4];
            memcpy(expected, state->vram_ptr + dma_a.address + 5 * 16, 16);
            assert(
                !memcmp(pg->vertex_attributes[0].inline_value, expected, 16));
            key = [owner valueForKey:@"arrayRangesKey"];
            tcg_allowed = !tcg;
            arp_run(owner, @[ @0, @0, @2 ], host);
            assert(![key isEqualToData:[owner valueForKey:@"arrayRangesKey"]]);
            /* Key hits must still observe fresh layouts and source mappings. */
            for (unsigned format = 0; format < 3; format++) {
                pg->vertex_attributes[0].format =
                    format == 1 ?
                        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D :
                        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
                pg->vertex_attributes[0].size = format == 1 ? 1 : 4;
                pg->vertex_attributes[0].stride = format == 1 ? 4 :
                                                  format == 2 ? 0 :
                                                                16;
                arp_pair(owner, @[ @0, @0, @2 ], host);
            }
            [owner close];
            assert(![owner valueForKey:@"arrayRangesKey"] &&
                   ![owner valueForKey:@"arrayRanges"]);
        }
}
static void arp_allocations_and_rejections(void)
{
    arp_setup();
    tcg_allowed = YES;
    PGRAPHState *pg = &state->pgraph;
    pg->draw_arrays_length = 3;
    const int32_t starts[] = { 4, 0, 8 };
    memcpy(pg->draw_arrays_start, starts, sizeof(starts));
    for (unsigned i = 0; i < 3; i++)
        pg->draw_arrays_count[i] = 2;
    NV2AMetalPGRAPHFetch *owner = arp_owner();
    arp_key_length = 10 * sizeof(uint32_t);
    arp_sorts = arp_keys = 0;
    arp_observing = YES;
    arp_run(owner, nil, NO);
    arp_observing = NO;
    assert(arp_sorts == 1 && arp_keys == 1);
    NSData *key = [owner valueForKey:@"arrayRangesKey"];
    NSData *ranges = [owner valueForKey:@"arrayRanges"];
    arp_sorts = arp_keys = 0;
    arp_observing = YES;
    arp_run(owner, @[ @0, @0, @0 ], NO);
    arp_observing = NO;
    assert(!arp_sorts && !arp_keys &&
           key == [owner valueForKey:@"arrayRangesKey"] &&
           ranges == [owner valueForKey:@"arrayRanges"]);
    /* Cancellation retains pure plans, but cannot retain a source guard or
     * excuse fresh validation in the next recording. */
    NSError *error = nil;
    require(arp_encode(owner, nil, NO, &error) != nil, error);
    [owner cancel];
    assert(key == [owner valueForKey:@"arrayRangesKey"]);
    for (unsigned invalid = 0; invalid < 7; invalid++) {
        pg->draw_arrays_length = invalid == 2 ? 1251 : 3;
        pg->draw_arrays_start[0] = invalid == 0 ? -1 : 4;
        pg->draw_arrays_count[0] = invalid == 1 ? 0 : 2;
        NSArray *prefixes = invalid == 3 ? @[ @3, @0, @0 ] :
                            invalid == 4 ? @[ @(-1), @0, @0 ] :
                            invalid == 5 ? @[ @0.5, @0, @0 ] :
                            invalid == 6 ? @[ @0, @0 ] :
                                           nil;
        arp_reject(owner, prefixes);
        assert(key == [owner valueForKey:@"arrayRangesKey"]);
    }
    pg->draw_arrays_length = 3;
    pg->draw_arrays_start[0] = 4;
    pg->draw_arrays_count[0] = 2;
    dma_a.limit = 1;
    arp_reject(owner, nil);
    assert(key == [owner valueForKey:@"arrayRangesKey"]);
    dma_a.limit = 65535;
    pg->vertex_attributes[0].format = 255;
    arp_reject(owner, nil);
    pg->vertex_attributes[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    arp_pair(owner, nil, NO);
    require([surfaces discardForRestoreWithError:&error], error);
    arp_pair(owner, nil, NO);
    [owner close];
}
static void arp_dirty_guards(void)
{
    for (unsigned host = 0; host < 2; host++) {
        arp_setup();
        tcg_allowed = YES;
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = 2;
        pg->draw_arrays_start[0] = 0;
        pg->draw_arrays_start[1] = 4;
        pg->draw_arrays_count[0] = pg->draw_arrays_count[1] = 1;
        NV2AMetalPGRAPHFetch *owner = arp_owner();
        arp_run(owner, nil, host);
        NSData *key = [owner valueForKey:@"arrayRangesKey"];
        NV2AMetalCachedSurface *hole = index_ranges_writer(8);
        unsigned before = notifications;
        arp_run(owner, nil, host);
        assert(hole.dirty && notifications == before &&
               key == [owner valueForKey:@"arrayRangesKey"]);
        NV2AMetalCachedSurface *selected = index_ranges_writer(4);
        if (host) {
            /* A warm plan cannot make the new GPU-written Current readable
             * on CPU. Reject host capture, then use the ordinary GPU path. */
            NSError *error = nil;
            assert(!arp_encode(owner, nil, YES, &error) && error);
        }
        arp_run(owner, nil, NO);
        assert(!selected.dirty && hole.dirty && notifications == before + 1);
        if (!host) {
            NSError *error = nil;
            NSArray *batches = arp_encode(owner, nil, NO, &error);
            require(batches != nil, error);
            BOOL done = YES;
            require([surfaces tryIdleCPUAccessAtAddress:1088
                                                 length:16
                                                  write:YES
                                              completed:&done
                                                  error:&error],
                    error);
            assert(!done);
            done = NO;
            require([surfaces tryIdleCPUAccessAtAddress:1120
                                                 length:16
                                                  write:YES
                                              completed:&done
                                                  error:&error],
                    error);
            assert(done);
            require([owner completeWithError:&error], error);
        }
        arp_pair(owner, nil, host);
        [owner close];
    }
}
static void arp_boundaries(void)
{
    arp_setup();
    tcg_allowed = YES;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalPGRAPHFetch *owner = arp_owner();
    pg->vertex_attributes[0].count = 1;
    pg->vertex_attributes[0].stride = 4;
    pg->draw_arrays_length = ARRAY_SIZE(pg->draw_arrays_start);
    NSMutableArray *accepted = [NSMutableArray new];
    for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
        pg->draw_arrays_start[i] = i * 2;
        pg->draw_arrays_count[i] = 1;
        [accepted addObject:@1];
    }
    /* Build the largest disjoint plan before a fresh DMA rejection, without
     * issuing 1250 GPU kernels solely to inspect metadata allocation. */
    dma_a.limit = 1;
    arp_reject(owner, nil);
    NSData *ranges = [owner valueForKey:@"arrayRanges"];
    assert(ranges.length == 1250 * sizeof(NSRange) &&
           arp_payload(owner) == 35004);
    dma_a.limit = 65535;
    arp_pair(owner, accepted, NO);
    /* Small plans coexist. A full 64KiB index plan must evict the array
     * metadata, and a later array plan must evict that large index plan. */
    pg->draw_arrays_length = 1;
    pg->draw_arrays_start[0] = 0;
    arp_run(owner, nil, NO);
    NSData *arrayKey = [owner valueForKey:@"arrayRangesKey"];
    pg->draw_arrays_length = 0;
    pg->vertex_attributes[0].count = 4;
    pg->inline_elements_length = 3;
    for (unsigned i = 0; i < 3; i++)
        pg->inline_elements[i] = i * 2;
    NV2AMetalPendingInput *small =
        [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                      count:3
                           matchingPrevious:nil];
    index_ranges_run(owner, small, 0, NO);
    assert(arrayKey == [owner valueForKey:@"arrayRangesKey"] &&
           arp_payload(owner));
    pg->inline_elements_length = 4096;
    for (unsigned i = 0; i < 4096; i++)
        pg->inline_elements[i] = i * 2;
    NV2AMetalPendingInput *large =
        [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                      count:4096
                           matchingPrevious:nil];
    index_ranges_run(owner, large, 0, NO);
    assert(![owner valueForKey:@"arrayRangesKey"] &&
           arp_payload(owner) == 65536);
    pg->inline_elements_length = 0;
    pg->draw_arrays_length = 1;
    arp_run(owner, nil, NO);
    assert(![owner valueForKey:@"indexRanges"] &&
           [owner valueForKey:@"arrayRangesKey"]);
    [owner close];
}
static void array_range_plan_tests(void)
{
    Class cls = object_getClass(NSData.class);
    SEL selector = @selector(dataWithBytes:length:);
    Method method = class_getInstanceMethod(cls, selector);
    class_addMethod(cls, selector, method_getImplementation(method),
                    method_getTypeEncoding(method));
    method = class_getInstanceMethod(cls, selector);
    arp_original_data = (void *)method_setImplementation(method, (IMP)arp_data);
    BOOL originalTCG = tcg_allowed;
    @try {
        arp_allocations_and_rejections();
        arp_layouts();
        arp_dirty_guards();
        arp_boundaries();
    } @finally {
        arp_observing = NO;
        tcg_allowed = originalTCG;
        method_setImplementation(method, (IMP)arp_original_data);
    }
    assert(arp_pairs);
    printf("Array range plan: %lu exact uncached GPU pairs; warm zero key "
           "allocations/sorts, "
           "ordered ranges/prefix/TCG, nil-zero equivalence, last maximum "
           "Current, "
           "fresh DMA/layout/dirty guards, cancel/retry/restore, 1250 ranges "
           "and shared "
           "64KiB eviction both ways PASS\n",
           (unsigned long)arp_pairs);
    groups++;
}
#endif
