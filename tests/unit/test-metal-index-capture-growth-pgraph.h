/* Immutable index capture growth against the original full-copy factory.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEX_CAPTURE_GROWTH_PGRAPH_H
#define TEST_METAL_INDEX_CAPTURE_GROWTH_PGRAPH_H
@interface NV2AMetalPendingInput (IndexGrowthLegacyReference)
- (instancetype)initKind:(NV2AMetalInputKind)kind
                   first:(NSUInteger)first
                   count:(NSUInteger)count
                 indices:(NSData *)indices
          verifiedPrefix:(NV2AMetalPendingInput *)prefix;
@end
static BOOL ig_active, ig_reference;
static unsigned ig_factory_depth, ig_shared_views, ig_suffix_calls;
static NSUInteger ig_capture_bytes, ig_logical_records;
static id (*ig_factory_original)(id, SEL, const void *, NSUInteger, id);
static id ig_factory(id cls, SEL selector, const void *bytes, NSUInteger count,
                     NV2AMetalPendingInput *previous)
{
    if (!ig_active || bytes != state->pgraph.inline_elements)
        return ig_factory_original(cls, selector, bytes, count, previous);
    if (ig_reference) {
        if (!bytes || !count || count > NSUIntegerMax / 4)
            return nil;
        NV2AMetalPendingInput *prefix = nil;
        if ([previous isKindOfClass:NV2AMetalPendingInput.class] &&
            previous.kind == NV2AMetalInputIndexed && previous.count <= count &&
            !memcmp(bytes, previous.indices.bytes, previous.indices.length)) {
            if (previous.count == count)
                return previous;
            prefix = previous;
        }
        ig_capture_bytes += count * 4;
        // The original factory's weak prefix and suffix-only bounds remain;
        // only its full NSData storage copy differs from the new backing.
        return [[cls alloc] initKind:NV2AMetalInputIndexed
                               first:0
                               count:count
                             indices:[NSData dataWithBytes:bytes
                                                    length:count * 4]
                      verifiedPrefix:prefix];
    }
    ig_factory_depth++;
    id result = ig_factory_original(cls, selector, bytes, count, previous);
    ig_factory_depth--;
    return result;
}
static void (*ig_copy_original)(id, SEL, const void *, NSUInteger, NSUInteger);
static void ig_copy(id owner, SEL selector, const void *bytes,
                    NSUInteger offset, NSUInteger length)
{
    if (ig_active && !ig_reference && ig_factory_depth) {
        uintptr_t start = (uintptr_t)state->pgraph.inline_elements;
        uintptr_t p = (uintptr_t)bytes;
        NSUInteger live = state->pgraph.inline_elements_length * 4;
        assert(p >= start && p - start <= live && length <= live - (p - start));
        ig_capture_bytes += length;
    }
    ig_copy_original(owner, selector, bytes, offset, length);
}
static BOOL (*ig_suffix_original)(id, SEL, id, id, NSError **);
static BOOL ig_suffix(id journal, SEL selector, NV2AMetalPendingSpan *span,
                      id progress, NSError **error)
{
    BOOL ok = ig_suffix_original(journal, selector, span, progress, error);
    if (ok && ig_active && span.count) {
        ig_logical_records += span.count;
        ig_suffix_calls++;
        if ([span.resource isKindOfClass:NV2AMetalIndexedVertices.class]) {
            NV2AMetalIndexedVertices *owner = span.resource;
            assert(span.first == 0 && span.count == owner.vertexCount &&
                   owner.physicalVertexCount < owner.vertexCount);
            indexed_owners++;
        }
    }
    return ok;
}
static void ig_scene(unsigned primitive, unsigned mode)
{
    indexed_scene(primitive, mode == 2 ? 3 : mode);
    PGRAPHState *pg = &state->pgraph;
    const unsigned guest[] = { 2, 7, 20, 31 };
    const float position[4][4] = { { .5f, .5f, 31000, 1 },
                                   { 6.5f, 1.5f, 32000, 1 },
                                   { 1.5f, 6.5f, 33000, 1 },
                                   { 6.5f, 6.5f, 34000, 1 } };
    const float colors[4][4] = { { 1, .125f, .25f, 1 },
                                 { .25f, 1, .125f, 1 },
                                 { .125f, .25f, 1, 1 },
                                 { 1, .75f, .25f, 1 } };
    for (unsigned i = 0; i < 4; i++) {
        cpu_write(16384 + guest[i] * 16, 16);
        memcpy(state->vram_ptr + 16384 + guest[i] * 16, position[i], 16);
        cpu_write(16640 + guest[i] * 16, 16);
        memcpy(state->vram_ptr + 16640 + guest[i] * 16, colors[i], 16);
    }
    const uint32_t pattern[] = { 20, 2, 7, 20, 7, 2, 31, 7, 20, 31, 2, 20 };
    for (unsigned i = 0; i < 192; i++)
        pg->inline_elements[i] = pattern[i % 12];
    pg->inline_elements_length = 6;
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                      NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                      NV_PGRAPH_CONTROL_0_ZFUNC_ALWAYS << 16;
    pg->dma_report = 80;
    pg->zpass_pixel_count_enable = true;
}
static void ig_archive(NSData *wire, NSUInteger count)
{
    assert(pgraph_metal4_validate_pending_capture(wire.bytes, wire.length));
    NSError *error = nil;
    NV2AMetalPendingArchive *a = [[NV2AMetalPendingArchive alloc]
        initWithData:[wire subdataWithRange:NSMakeRange(12, wire.length - 12)]
               limit:524287
               error:&error];
    require(a != nil, error);
    assert(a.inputs.count == 1 && a.inputs[0].count == count &&
           a.inputs[0].indices.length == count * 4);
    const uint32_t pattern[] = { 20, 2, 7, 20, 7, 2, 31, 7, 20, 31, 2, 20 };
    const uint32_t *indices = a.inputs[0].indices.bytes;
    for (NSUInteger i = 0; i < count; i++)
        assert(indices[i] == pattern[i % 12]);
}
@interface IndexGrowthOutput : NSObject
@property(nonatomic) NSData *image;
@property(nonatomic) NSArray<NSData *> *archives;
@property(nonatomic) NSUInteger copied, xfRecords, logicalRecords;
@property(nonatomic) unsigned suffixCalls, sharedViews;
@end
@implementation IndexGrowthOutput
@end
static IndexGrowthOutput *ig_run(unsigned mode, unsigned primitive,
                                 unsigned boundary, BOOL reference)
{
    ig_active = NO;
    ig_scene(primitive, mode);
    ig_reference = reference;
    indexed_reference = NO;
    indexed_fail_emit = NO;
    indexed_xf_records = indexed_owners = indexed_fetch_maps = 0;
    ig_capture_bytes = ig_logical_records = 0;
    ig_suffix_calls = ig_shared_views = 0;
    PGRAPHState *pg = &state->pgraph;
    NSError *error = nil;
    NSMutableArray<NV2AMetalPendingInput *> *retained = [NSMutableArray new];
    NSMutableArray<NSData *> *frozen = [NSMutableArray new],
                             *archives = [NSMutableArray new];
    NSData *restorePending = nil, *restoreBegin = nil, *restoreVertex = nil;
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    ig_active = YES;
    require([draw beginWithError:&error], error);
    for (unsigned step = 1; step <= 32; step++) {
        pg->inline_elements_length = step * 6;
        if (boundary == 1 && step == 17) {
            NSData *before = [draw pendingSnapshotWithError:&error];
            require(before != nil, error);
            uint32_t current[16][4], constants[192][4];
            for (unsigned i = 0; i < 16; i++)
                memcpy(current[i], pg->vertex_attributes[i].inline_value, 16);
            memcpy(constants, pg->vsh_constants, sizeof(constants));
            NSUInteger xf = indexed_xf_records, logical = ig_logical_records;
            uint32_t first = pg->inline_elements[0];
            pg->inline_elements[0] = 7;
            assert(![draw prepareVertexStateChangeWithError:&error] && error);
            error = nil;
            assert(indexed_xf_records == xf && ig_logical_records == logical &&
                   !pg->draw_time &&
                   !memcmp(constants, pg->vsh_constants, sizeof(constants)));
            for (unsigned i = 0; i < 16; i++)
                assert(!memcmp(current[i],
                               pg->vertex_attributes[i].inline_value, 16));
            NSData *after = [draw pendingSnapshotWithError:&error];
            require(after != nil, error);
            assert([before isEqualToData:after]);
            pg->inline_elements[0] = first;
        }
        require([draw prepareVertexStateChangeWithError:&error], error);
        NV2AMetalPendingJournal *journal = [draw valueForKey:@"pending"];
        NV2AMetalPendingInput *input = journal.retainedInputs.firstObject;
        assert(input.kind == NV2AMetalInputIndexed && input.count == step * 6 &&
               input.minimumIndex == 2 &&
               input.maximumIndex == (step == 1 ? 20u : 31u));
        if (retained.count &&
            input.indices.bytes == retained.lastObject.indices.bytes)
            ig_shared_views++;
        [retained addObject:input];
        [frozen addObject:[NSData dataWithBytes:input.indices.bytes
                                         length:input.indices.length]];
        for (NSUInteger i = 0; i < retained.count; i++) {
            assert(retained[i].indices.length == (i + 1) * 24 &&
                   [retained[i].indices isEqualToData:frozen[i]]);
        }
        // An unchanged live list keeps identity and performs no snapshot copy.
        NSUInteger copied = ig_capture_bytes, xf = indexed_xf_records;
        require([draw prepareVertexStateChangeWithError:&error], error);
        assert(ig_capture_bytes == copied && indexed_xf_records == xf &&
               ((NV2AMetalPendingJournal *)[draw valueForKey:@"pending"])
                       .retainedInputs.firstObject == input);
        if (step == 8 || step == 16 || step == 32) {
            NSData *wire = [draw pendingSnapshotWithError:&error];
            require(wire != nil, error);
            ig_archive(wire, step * 6);
            [archives addObject:wire];
            if (boundary == 2 && step == 16) {
                restorePending = wire;
                restoreVertex = draw.vertexSnapshot;
                restoreBegin = [draw beginSnapshotWithError:&error];
                require(restoreVertex && restoreBegin, error);
                require([draw flushWithError:&error] &&
                            [draw discardForRestoreWithError:&error] &&
                            [draw restoreVertexSnapshot:restoreVertex
                                                  error:&error] &&
                            [draw restoreBeginSnapshot:restoreBegin
                                                 error:&error] &&
                            [draw restorePendingSnapshot:restorePending
                                                   error:&error] &&
                            [draw beginWithError:&error],
                        error);
                NSData *restored = [draw pendingSnapshotWithError:&error];
                require(restored != nil, error);
                assert([restorePending isEqualToData:restored]);
            }
        }
    }
    for (NSUInteger i = 0; i < archives.count; i++)
        ig_archive(archives[i], (i == 0 ? 8 : i == 1 ? 16 : 32) * 6);
    NSUInteger xf = indexed_xf_records, logical = ig_logical_records;
    if (boundary == 3) {
        indexed_fail_emit = YES;
        assert(![draw flushDrawWithError:&error] && error &&
               !indexed_fail_emit && !pg->draw_time);
        error = nil;
        assert(indexed_xf_records == xf && ig_logical_records == logical);
    }
    require([draw endWithError:&error], error);
    assert(indexed_xf_records == xf && ig_logical_records == logical &&
           pg->draw_time == 1);
    ig_active = NO;
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
    if (mode == 2)
        expect_context(191, 15, 192, YES);
    for (NSUInteger i = 0; i < retained.count; i++)
        assert([retained[i].indices isEqualToData:frozen[i]]);
    IndexGrowthOutput *result = [IndexGrowthOutput new];
    result.image = cpp_capture(query);
    result.archives = archives;
    result.copied = ig_capture_bytes;
    result.xfRecords = indexed_xf_records;
    result.logicalRecords = ig_logical_records;
    result.suffixCalls = ig_suffix_calls;
    result.sharedViews = ig_shared_views;
    assert(ig_logical_records == 192 && ig_suffix_calls == 32);
    assert(mode == 2 ? indexed_xf_records == 192 :
                       indexed_xf_records == 112 && indexed_owners &&
                           indexed_fetch_maps);
    qemu_mutex_unlock(&pg->lock);
    return result;
}
static void index_capture_growth_pgraph_tests(void)
{
    Class backing = NSClassFromString(@"NV2AMetalIndexSnapshotBacking");
    assert(backing);
    Method methods[] = {
        class_getClassMethod(NV2AMetalPendingInput.class,
                             @selector(indexedBytes:count:matchingPrevious:)),
        class_getInstanceMethod(backing,
                                sel_registerName("copyBytes:offset:length:")),
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
        class_getInstanceMethod(NV2AMetalPendingJournal.class,
                                @selector(commitNextSuffix:progress:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeIndependentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    IMP replacements[] = { (IMP)ig_factory,          (IMP)ig_copy,
                           (IMP)indexed_encode,      (IMP)indexed_execute,
                           (IMP)indexed_serial,      (IMP)ig_suffix,
                           (IMP)indexed_independent, (IMP)indexed_current,
                           (IMP)indexed_emit },
        originals[9];
    for (unsigned i = 0; i < 9; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    ig_factory_original = (void *)originals[0];
    ig_copy_original = (void *)originals[1];
    indexed_epoch_encode = (void *)originals[2];
    indexed_epoch_execute = (void *)originals[3];
    indexed_epoch_serial = (void *)originals[4];
    ig_suffix_original = (void *)originals[5];
    indexed_fetch_independent = (void *)originals[6];
    indexed_fetch_current = (void *)originals[7];
    indexed_pixel_emit = (void *)originals[8];
    NSUInteger fullBytes = 0, growthBytes = 0;
    unsigned pairs = 0;
    @try {
        for (unsigned mode = 0; mode < 3; mode++)
            for (unsigned topology = 0; topology < 2; topology++)
                @autoreleasepool {
                    unsigned boundary = topology ? (mode == 0 ? 1 :
                                                    mode == 1 ? 2 :
                                                                3) :
                                                   0;
                    unsigned primitive =
                        topology ? PRIM_TYPE_TRIANGLE_STRIP : PRIM_TYPE_POINTS;
                    IndexGrowthOutput *output[2];
                    for (unsigned order = 0; order < 2; order++) {
                        unsigned reference = (order + mode + topology) & 1;
                        output[reference] =
                            ig_run(mode, primitive, boundary, reference);
                    }
                    if (![output[0].image isEqualToData:output[1].image] ||
                        ![output[0].archives
                            isEqualToArray:output[1].archives] ||
                        output[0].xfRecords != output[1].xfRecords ||
                        output[0].logicalRecords != output[1].logicalRecords ||
                        output[0].suffixCalls != output[1].suffixCalls) {
                        fprintf(stderr,
                                "Index growth PGRAPH mode%u topology%u "
                                "boundary%u mismatch\n",
                                mode, topology, boundary);
                        abort();
                    }
                    assert(output[0].sharedViews && !output[1].sharedViews &&
                           output[0].copied < output[1].copied);
                    if (!boundary) {
                        assert(output[1].copied == 12672);
                        fullBytes += output[1].copied;
                        growthBytes += output[0].copied;
                    }
                    pairs++;
                }
    } @finally {
        ig_active = ig_reference = indexed_reference = indexed_fail_emit = NO;
        for (unsigned i = 0; i < 9; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    printf("Index capture growth PGRAPH:%u exact "
           "image/zeta/Current/context/query/archive pairs; unchanged "
           "suffix/XF execution, immutable old views, prefix rejection/retry, "
           "Restore and late raster retry;32-step normal capture copies "
           "%lu/%lu optimized/full bytes PASS\n",
           pairs, (unsigned long)growthBytes, (unsigned long)fullBytes);
    groups += pairs;
}
#endif
