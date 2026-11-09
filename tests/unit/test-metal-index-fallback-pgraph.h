/* Failed CPU captures retain fetch-first error ordering and full index input.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEX_FALLBACK_PGRAPH_H
#define TEST_METAL_INDEX_FALLBACK_PGRAPH_H
static BOOL ifb_active, ifb_reference, ifb_xf_boundary, ifb_fail_capture;
static unsigned ifb_api_depth, ifb_fetch_depth, ifb_routes, ifb_max_reads,
    ifb_recaptures, ifb_capture_failures, ifb_nested_captures;
static NSUInteger ifb_index_bytes, ifb_fetch_records;
static const void *ifb_index_pointer;
static __weak NV2AMetalPendingInput *ifb_expected_input;

@interface NV2AMetalPGRAPHVertexState (IndexFallbackFailure)
- (instancetype)ifb_initWithState:(PGRAPHState *)state
                          unbound:(BOOL)unbound
                    rasterDiscard:(BOOL)discard
               reusingProgramFrom:(NV2AMetalPGRAPHVertexState *)previous
                            error:(NSError **)error
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalPGRAPHVertexState (IndexFallbackFailure)
- (instancetype)ifb_initWithState:(PGRAPHState *)pg
                          unbound:(BOOL)unbound
                    rasterDiscard:(BOOL)discard
               reusingProgramFrom:(NV2AMetalPGRAPHVertexState *)previous
                            error:(NSError **)error
{
    // This selector is exchanged with the real initializer only in this suite.
    // ARC init-family ownership releases the strong successful capture when
    // the one-shot host-allocation-failure model returns nil. No guest state
    // is modified between the speculative capture and the real recapture.
    self = [self ifb_initWithState:pg
                           unbound:unbound
                     rasterDiscard:discard
                reusingProgramFrom:previous
                             error:error];
    if (ifb_active && pg == &state->pgraph) {
        ifb_recaptures++;
        if (self && ifb_fail_capture) {
            ifb_fail_capture = NO;
            ifb_capture_failures++;
            if (error)
                *error =
                    [NSError errorWithDomain:@"test.index-fallback.host-capture"
                                        code:1
                                    userInfo:nil];
            return nil;
        }
    }
    return self;
}
@end
static id (*ifb_input_original)(id, SEL, const void *, NSUInteger, id);
static id ifb_input(id cls, SEL selector, const void *bytes, NSUInteger count,
                    id previous)
{
    id result = ifb_input_original(cls, selector, bytes, count, previous);
    if (ifb_active && bytes == state->pgraph.inline_elements) {
        ifb_nested_captures += ifb_api_depth != 0;
        ifb_expected_input = result;
    }
    return result;
}
static id (*ifb_prepare_original)(id, SEL, id, NSError **);
static id (*ifb_independent_original)(id, SEL, id, NSError **);
static id ifb_route(id fetch, SEL selector, NV2AMetalPendingInput *input,
                    NSError **error, BOOL independent)
{
    if (!ifb_active)
        return independent ?
                   ifb_independent_original(fetch, selector, input, error) :
                   ifb_prepare_original(fetch, selector, input, error);
    if (input) {
        assert(input == ifb_expected_input && input.count == 12 &&
               independent == ifb_xf_boundary);
        ifb_routes++;
    }
    ifb_api_depth++;
    id result;
    if (ifb_reference && input) {
        // The previous fallback API, including its original queue choice and
        // GPU completion policy. The old wrapper delegates with nil input.
        result = independent ?
                     [fetch encodeIndependentSnapshotsWithError:error] :
                     [fetch prepareWithError:error];
    } else
        result = independent ?
                     ifb_independent_original(fetch, selector, input, error) :
                     ifb_prepare_original(fetch, selector, input, error);
    ifb_api_depth--;
    return result;
}
static id ifb_prepare(id fetch, SEL selector, id input, NSError **error)
{
    return ifb_route(fetch, selector, input, error, NO);
}
static id ifb_independent(id fetch, SEL selector, id input, NSError **error)
{
    return ifb_route(fetch, selector, input, error, YES);
}
static id (*ifb_fetch_original)(id, SEL, BOOL, id, id, BOOL, BOOL, uint64_t,
                                NSError **);
static id ifb_fetch(NV2AMetalPGRAPHFetch *fetch, SEL selector, BOOL independent,
                    id prefixes, NV2AMetalPendingInput *input, BOOL current,
                    BOOL dedupe, uint64_t proofLanes, NSError **error)
{
    if (!ifb_active || !ifb_api_depth)
        return ifb_fetch_original(fetch, selector, independent, prefixes, input,
                                  current, dedupe, proofLanes, error);
    assert(!prefixes && !current && !dedupe && !proofLanes &&
           independent == ifb_xf_boundary);
    assert(ifb_reference ? !input : input == ifb_expected_input);
    ifb_index_pointer =
        input ? input.indices.bytes : state->pgraph.inline_elements;
    ifb_fetch_depth++;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *result =
        ifb_fetch_original(fetch, selector, independent, prefixes, input,
                           current, dedupe, proofLanes, error);
    ifb_fetch_depth--;
    if (result) {
        assert(result.count == 1 && result[0].inputVertexCount == 12 &&
               result[0].firstDecodedVertex == 0 &&
               result[0].physicalVertexCount == 12 && !result[0].remap);
        ifb_fetch_records += result[0].physicalVertexCount;
        assert(independent ? fetch.encodingCommands != surfaces.cache.commands :
                             fetch.encodingCommands == surfaces.cache.commands);
    }
    ifb_index_pointer = NULL;
    return result;
}
static uint32_t (*ifb_max_original)(id, SEL);
static uint32_t ifb_max(id input, SEL selector)
{
    if (ifb_active && ifb_fetch_depth && input == ifb_expected_input)
        ifb_max_reads++;
    return ifb_max_original(input, selector);
}
static id (*ifb_upload_original)(id, SEL, const void *, NSUInteger,
                                 NSUInteger *, NSError **);
static id ifb_upload(id commands, SEL selector, const void *bytes,
                     NSUInteger length, NSUInteger *offset, NSError **error)
{
    if (ifb_active && ifb_fetch_depth && bytes == ifb_index_pointer) {
        assert(length == 48);
        ifb_index_bytes += length;
    }
    return ifb_upload_original(commands, selector, bytes, length, offset,
                               error);
}
static void ifb_reset_attempt(void)
{
    ifb_routes = ifb_max_reads = ifb_recaptures = ifb_nested_captures = 0;
    ifb_fetch_records = ifb_index_bytes = 0;
    ifb_expected_input = nil;
}
static void ifb_probe(BOOL fetched)
{
    assert(ifb_routes == 1 && !ifb_nested_captures);
    assert(ifb_reference ? !ifb_max_reads : ifb_max_reads > 0);
    assert(ifb_fetch_records == (fetched ? 12u : 0u) &&
           ifb_index_bytes == (fetched ? 48u : 0u));
}
static BOOL ifb_attempt(NSError **error)
{
    return ifb_xf_boundary ? [draw prepareVertexStateChangeWithError:error] :
                             [draw flushDrawWithError:error];
}
static NSData *ifb_pending(NSError **error)
{
    NSData *wire = [draw pendingSnapshotWithError:error];
    if (wire.length)
        assert(pgraph_metal4_validate_pending_capture(wire.bytes, wire.length));
    return wire;
}
static NSData *ifb_run(unsigned mode, BOOL boundary, BOOL transient,
                       BOOL reference)
{
    ifb_active = NO;
    ig_scene(PRIM_TYPE_POINTS, mode);
    ifb_reference = reference;
    ifb_xf_boundary = boundary;
    indexed_reference = NO;
    indexed_fail_emit = NO;
    indexed_xf_records = indexed_owners = indexed_fetch_maps = 0;
    PGRAPHState *pg = &state->pgraph;
    NSError *error = nil;
    const uint32_t indices[] = { 31, 2, 7, 20, 7, 2, 20, 2, 7, 20, 7, 20 };
    memcpy(pg->inline_elements, indices, sizeof(indices));
    pg->inline_elements_length = 6;
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    require([draw beginWithError:&error] &&
                [draw prepareVertexStateChangeWithError:&error],
            error);
    NSData *prefix = ifb_pending(&error);
    require(prefix.length != 0, error);
    NV2AMetalPendingInput *old =
        ((NV2AMetalPendingJournal *)[draw valueForKey:@"pending"])
            .retainedInputs[0];
    NSData *oldIndices = [NSData dataWithBytes:old.indices.bytes
                                        length:old.indices.length];
    uint32_t current[16][4], constants[192][4];
    bool dirty[192];
    for (unsigned i = 0; i < 16; i++)
        memcpy(current[i], pg->vertex_attributes[i].inline_value, 16);
    memcpy(constants, pg->vsh_constants, sizeof(constants));
    memcpy(dirty, pg->vsh_constants_dirty, sizeof(dirty));
    NSUInteger prefixXF = indexed_xf_records;
    pg->inline_elements_length = 12;
    uint32_t csvc = pg->regs_[NV_PGRAPH_CSV0_C],
             csvd = pg->regs_[NV_PGRAPH_CSV0_D];
    ifb_active = YES;
    if (!transient) {
        if (mode)
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C],
                     NV_PGRAPH_CSV0_C_CHEOPS_PROGRAM_START,
                     NV2A_METAL_VP_SLOTS);
        else
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_D], NV_PGRAPH_CSV0_D_MODE, 1);
        // The already accepted prefix contains index31; every new suffix
        // index is <=20. DMA639 fits the suffix but not the full color lane.
        dma[2].limit = 639;
        ifb_reset_attempt();
        assert(!ifb_attempt(&error) &&
               [error.localizedDescription
                   isEqualToString:@"NV2A vertex stream exceeds DMA span"]);
        assert(ifb_recaptures == 1 && indexed_xf_records == prefixXF);
        ifb_probe(NO);
        error = nil;
        dma[2].limit = 1023;
        ifb_reset_attempt();
        assert(
            !ifb_attempt(&error) &&
            [error.localizedDescription
                isEqualToString:mode ?
                                    @"NV2A vertex program start exceeds slots" :
                                    @"Unsupported NV2A vertex mode"]);
        assert(ifb_recaptures == 2 && indexed_xf_records == prefixXF);
        ifb_probe(YES);
        error = nil;
        assert(!memcmp(constants, pg->vsh_constants, sizeof(constants)) &&
               !memcmp(dirty, pg->vsh_constants_dirty, sizeof(dirty)));
        for (unsigned i = 0; i < 16; i++)
            assert(
                !memcmp(current[i], pg->vertex_attributes[i].inline_value, 16));
        NSData *failed = ifb_pending(&error);
        require(failed != nil, error);
        assert([prefix isEqualToData:failed] &&
               [old.indices isEqualToData:oldIndices] && !pg->draw_time);
        pg->regs_[NV_PGRAPH_CSV0_C] = csvc;
        pg->regs_[NV_PGRAPH_CSV0_D] = csvd;
        // This is a subsequent explicit guest retry, not a mutation during
        // fallback fetch or between its speculative capture and recapture.
        ifb_active = NO;
        require(ifb_attempt(&error), error);
    } else {
        unsigned failures = ifb_capture_failures;
        ifb_reset_attempt();
        ifb_fail_capture = YES;
        require(ifb_attempt(&error), error);
        assert(!ifb_fail_capture && ifb_capture_failures == failures + 1 &&
               ifb_recaptures == 2);
        ifb_probe(YES);
    }
    ifb_active = NO;
    NSData *after = ifb_pending(&error);
    require(after != nil, error);
    NSMutableData *snapshots = [prefix mutableCopy];
    [snapshots appendData:after];
    if (boundary && mode == 1 && transient) {
        NSData *vertex = draw.vertexSnapshot,
               *begin = [draw beginSnapshotWithError:&error];
        require(vertex && begin, error);
        require([draw flushWithError:&error] &&
                    [draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    [draw restorePendingSnapshot:after error:&error] &&
                    [draw beginWithError:&error],
                error);
        NSData *restored = ifb_pending(&error);
        require(restored != nil, error);
        assert([after isEqualToData:restored]);
    }
    NSUInteger xf = indexed_xf_records;
    if (!boundary)
        pg->inline_elements_length = 0;
    require([draw endWithError:&error], error);
    assert(indexed_xf_records == xf && pg->draw_time == 1 &&
           [old.indices isEqualToData:oldIndices]);
    require([surfaces.cache submitWithError:&error] &&
                [surfaces.cache waitUntilIdleWithError:&error],
            error);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    qemu_mutex_lock(&pg->lock);
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(query);
    assert(!memcmp(pg->vertex_attributes[3].inline_value,
                   state->vram_ptr + 16640 + 20 * 16, 16));
    if (mode == 2)
        expect_context(191, 15, 12, YES);
    NSMutableData *result = [cpp_capture(query) mutableCopy];
    [result appendData:snapshots];
    [result appendBytes:&xf length:sizeof(xf)];
    qemu_mutex_unlock(&pg->lock);
    ifb_expected_input = nil;
    return result;
}
static void index_fallback_pgraph_tests(void)
{
    Method capture = class_getInstanceMethod(
        NV2AMetalPGRAPHVertexState.class,
        sel_registerName(
            "initWithState:unbound:rasterDiscard:reusingProgramFrom:error:"));
    Method hook = class_getInstanceMethod(
        NV2AMetalPGRAPHVertexState.class,
        @selector(
            ifb_initWithState:unbound:rasterDiscard:reusingProgramFrom:error:));
    assert(capture && hook);
    method_exchangeImplementations(capture, hook);
    Method methods[] = {
        class_getClassMethod(NV2AMetalPendingInput.class,
                             @selector(indexedBytes:count:matchingPrevious:)),
        class_getInstanceMethod(NV2AMetalPGRAPHFetch.class,
                                @selector(prepareWithIndexedInput:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeIndependentSnapshotsWithIndexedInput:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(
                encodeIndependentSnapshots:prefixes:indexedInput:captureCurrent:
                deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(NV2AMetalPendingInput.class,
                                @selector(maximumIndex)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(uploadBytes:length:offset:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(executeRasterState:attributeBuffer:first:count:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeIndependentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:))
    };
    IMP replacements[] = { (IMP)ifb_input,       (IMP)ifb_prepare,
                           (IMP)ifb_independent, (IMP)ifb_fetch,
                           (IMP)ifb_max,         (IMP)ifb_upload,
                           (IMP)indexed_encode,  (IMP)indexed_execute,
                           (IMP)indexed_serial,  (IMP)indexed_independent,
                           (IMP)indexed_current },
        originals[11];
    for (unsigned i = 0; i < 11; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    ifb_input_original = (void *)originals[0];
    ifb_prepare_original = (void *)originals[1];
    ifb_independent_original = (void *)originals[2];
    ifb_fetch_original = (void *)originals[3];
    ifb_max_original = (void *)originals[4];
    ifb_upload_original = (void *)originals[5];
    indexed_epoch_encode = (void *)originals[6];
    indexed_epoch_execute = (void *)originals[7];
    indexed_epoch_serial = (void *)originals[8];
    indexed_fetch_independent = (void *)originals[9];
    indexed_fetch_current = (void *)originals[10];
    unsigned pairs = 0;
    @try {
        for (unsigned mode = 0; mode < 3; mode++)
            for (unsigned boundary = 0; boundary < 2; boundary++)
                for (unsigned transient = 0; transient < 2; transient++)
                    @autoreleasepool {
                        NSData *output[2];
                        for (unsigned order = 0; order < 2; order++) {
                            unsigned reference =
                                (order + mode + boundary + transient) & 1;
                            output[reference] =
                                ifb_run(mode, boundary, transient, reference);
                        }
                        if (![output[0] isEqualToData:output[1]]) {
                            fprintf(stderr,
                                    "Index fallback PGRAPH mode%u boundary%u "
                                    "transient%u mismatch\n",
                                    mode, boundary, transient);
                            abort();
                        }
                        pairs++;
                    }
    } @finally {
        ifb_active = ifb_reference = ifb_fail_capture = NO;
        ifb_expected_input = nil;
        for (unsigned i = 0; i < 11; i++)
            method_setImplementation(methods[i], originals[i]);
        method_exchangeImplementations(capture, hook);
    }
    printf("Index fallback PGRAPH:%u exact "
           "framebuffer/zeta/Current/context/query/archive pairs; real "
           "invalid-capture/DMA priority+retry, full sparse "
           "input/no-dedupe/queue identity, unchanged index uploads, explicit "
           "one-shot host capture failure, Restore PASS\n",
           pairs);
    groups += pairs;
}
#endif
