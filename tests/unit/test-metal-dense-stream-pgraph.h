/* Dense source joins from real indexed XF suffixes, versus the old plan.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DENSE_STREAM_PGRAPH_H
#define TEST_METAL_DENSE_STREAM_PGRAPH_H

@interface DensePGRAPHExpected : NSObject
@property(nonatomic) NSData *vertices, *remap, *copies;
@property(nonatomic) NSArray<NSNumber *> *sources;
@end
@implementation DensePGRAPHExpected
@end
static BOOL dsp_reference, dsp_drawing, dsp_building;
static unsigned dsp_dense_calls, dsp_dense_hits, dsp_plan_calls;
static unsigned dsp_suffix_calls, dsp_copy_calls;
static NSUInteger dsp_logical, dsp_copy_bytes;
static NSMutableArray<NSNumber *> *dsp_suffix_sources;
static DensePGRAPHExpected *dsp_expected;
static NSMutableArray<NSArray *> *dsp_plans;
static NSMutableArray<NV2AMetalVertexSlice *> *dsp_slices;
static id (*dsp_dense_original)(id, SEL);
static id dsp_dense(id object, SEL selector)
{
    if (dsp_drawing)
        dsp_dense_calls++;
    /* The reference executes the complete original dictionary/sort builder.
     * It never computes the new plan and then discards its answer. */
    id plan = dsp_reference ? nil : dsp_dense_original(object, selector);
    if (dsp_drawing && plan)
        dsp_dense_hits++;
    return plan;
}
static id (*dsp_plan_original)(id, SEL);
static id dsp_plan(id object, SEL selector)
{
    id plan = dsp_plan_original(object, selector);
    if (dsp_drawing && plan) {
        dsp_plan_calls++;
        NSMutableData *shape = [NSMutableData new];
        for (id copy in [plan valueForKey:@"copies"]) {
            id buffer = [copy valueForKey:@"buffer"];
            NSNumber *identity = @((uintptr_t)(__bridge const void *)buffer);
            NSUInteger ordinal = [dsp_expected.sources indexOfObject:identity];
            uint64_t record[] = {
                ordinal, [[copy valueForKey:@"first"] unsignedLongLongValue],
                [[copy valueForKey:@"count"] unsignedLongLongValue],
                [[copy valueForKey:@"destination"] unsignedLongLongValue]
            };
            [shape appendBytes:record length:sizeof(record)];
        }
        [dsp_plans addObject:@[
            [[plan valueForKey:@"remap"] copy], [shape copy],
            [plan valueForKey:@"physicalCount"]
        ]];
    }
    return plan;
}
static id (*dsp_slice_original)(id, SEL, id, NSError **);
static id dsp_slice(id object, SEL selector, id commands, NSError **error)
{
    NV2AMetalVertexSlice *slice =
        dsp_slice_original(object, selector, commands, error);
    if (dsp_drawing && slice)
        [dsp_slices addObject:slice];
    return slice;
}
static BOOL (*dsp_suffix_original)(id, SEL, id, id, NSError **);
static BOOL dsp_suffix(id object, SEL selector, NV2AMetalPendingSpan *span,
                       id progress, NSError **error)
{
    BOOL ok = dsp_suffix_original(object, selector, span, progress, error);
    if (ok && dsp_building && span.count) {
        assert([span.resource isMemberOfClass:NV2AMetalIndexedVertices.class]);
        NV2AMetalIndexedVertices *owner = span.resource;
        assert(span.first == 0 && span.count == owner.vertexCount &&
               owner.physicalVertexCount < owner.vertexCount);
        dsp_logical += span.count;
        dsp_suffix_calls++;
        [dsp_suffix_sources
            addObject:@((uintptr_t)(__bridge const void *)owner.vertices)];
    }
    return ok;
}
static void (*dsp_copy_original)(id, SEL, id, NSUInteger, id, NSUInteger,
                                 NSUInteger);
static void dsp_copy(id object, SEL selector, id source, NSUInteger first,
                     id destination, NSUInteger offset, NSUInteger bytes)
{
    NSNumber *identity = @((uintptr_t)(__bridge const void *)source);
    if (dsp_drawing && [dsp_expected.sources containsObject:identity]) {
        dsp_copy_calls++;
        dsp_copy_bytes += bytes;
    }
    dsp_copy_original(object, selector, source, first, destination, offset,
                      bytes);
}
/* pendingSnapshot has completed the actual XF producers/restored uploads.
 * Read the original buffers on a separate queue while the journal owns them,
 * without retaining those owners through the draw. Restored buffers may be
 * private. No CPU transformation or production join supplies expected bytes. */
static DensePGRAPHExpected *dsp_inputs(void)
{
    NV2AMetalPendingJournal *journal = [draw valueForKey:@"pending"];
    assert(journal.retainedStreams.count == 1);
    NSMutableData *vertices = [NSMutableData new], *remap = [NSMutableData new],
                  *copies = [NSMutableData new];
    NSMutableArray<NSNumber *> *sources = [NSMutableArray new];
    NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray new],
                                  *readbacks = [NSMutableArray new];
    NSError *error = nil;
    NV2AMetalCommands *reader =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(reader && [reader beginWithError:&error], error);
    NSUInteger base = 0;
    for (NV2AMetalPendingSpan *span in journal.retainedStreams[0]) {
        assert([span.resource isMemberOfClass:NV2AMetalIndexedVertices.class]);
        NV2AMetalIndexedVertices *owner = span.resource;
        assert(span.first == 0 && span.count == owner.vertexCount &&
               owner.remap.length == span.count * sizeof(uint32_t) &&
               owner.physicalVertexCount <=
                   owner.vertices.length / sizeof(NV2AMetalVertex));
        NSNumber *identity =
            @((uintptr_t)(__bridge const void *)owner.vertices);
        assert(![sources containsObject:identity]);
        uint64_t copy[] = { sources.count, 0, owner.physicalVertexCount, base };
        [sources addObject:identity];
        [copies appendBytes:copy length:sizeof(copy)];
        id<MTLBuffer> readback =
            [reader.device newBufferWithLength:owner.physicalVertexCount *
                                               sizeof(NV2AMetalVertex)
                                       options:MTLResourceStorageModeShared];
        require(readback && [reader addResource:owner.vertices error:&error] &&
                    [reader addResource:readback error:&error],
                error);
        [buffers addObject:owner.vertices];
        [readbacks addObject:readback];
        NSMutableIndexSet *seen = [NSMutableIndexSet new];
        const uint32_t *map = owner.remap.bytes;
        for (NSUInteger i = 0; i < span.count; i++) {
            assert(map[i] < owner.physicalVertexCount &&
                   base <= UINT32_MAX - map[i]);
            [seen addIndex:map[i]];
            uint32_t value = (uint32_t)(base + map[i]);
            [remap appendBytes:&value length:sizeof(value)];
        }
        assert(seen.count == owner.physicalVertexCount);
        base += owner.physicalVertexCount;
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [reader.commandBuffer computeCommandEncoder];
    require(encoder != nil, nil);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    for (NSUInteger i = 0; i < buffers.count; i++)
        [encoder copyFromBuffer:buffers[i]
                   sourceOffset:0
                       toBuffer:readbacks[i]
              destinationOffset:0
                           size:readbacks[i].length];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([reader submitWithError:&error] &&
                [reader waitUntilIdleWithError:&error],
            error);
    for (id<MTLBuffer> readback in readbacks)
        [vertices appendBytes:readback.contents length:readback.length];
    DensePGRAPHExpected *expected = [DensePGRAPHExpected new];
    expected.vertices = vertices;
    expected.remap = remap;
    expected.copies = copies;
    expected.sources = sources;
    return expected;
}
static void dsp_colors(unsigned step)
{
    const unsigned guest[] = { 2, 7, 20, 31 };
    for (unsigned i = 0; i < ARRAY_SIZE(guest); i++) {
        const float color[4] = { ((step + i) % 4) * .25f,
                                 ((2 * step + i + 1) % 5) * .25f,
                                 ((3 * step + 2 * i) % 5) * .25f, 1 };
        cpu_write(16640 + guest[i] * 16, 16);
        memcpy(state->vram_ptr + 16640 + guest[i] * 16, color, 16);
    }
}
static NSArray *dsp_run(BOOL programmed, BOOL strip, BOOL lifecycle,
                        BOOL reference)
{
    dsp_reference = reference;
    ig_scene(strip ? PRIM_TYPE_TRIANGLE_STRIP : PRIM_TYPE_TRIANGLES,
             programmed ? 1 : 0);
    indexed_reference = indexed_fail_emit = NO;
    indexed_xf_records = 0;
    dsp_logical = dsp_copy_bytes = 0;
    dsp_suffix_calls = dsp_copy_calls = 0;
    dsp_dense_calls = dsp_dense_hits = dsp_plan_calls = 0;
    dsp_suffix_sources = [NSMutableArray new];
    dsp_plans = [NSMutableArray new];
    dsp_slices = [NSMutableArray new];
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NSMutableArray<NSData *> *archives = [NSMutableArray new];
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    require([draw beginWithError:&error], error);
    for (unsigned step = 1; step <= 4; step++) {
        dsp_colors(step);
        pg->inline_elements_length = step * 6;
        dsp_building = YES;
        BOOL ok = [draw prepareVertexStateChangeWithError:&error];
        dsp_building = NO;
        require(ok, error);
        if (step == 2 || step == 4) {
            NSData *wire = [draw pendingSnapshotWithError:&error];
            require(wire != nil, error);
            ig_archive(wire, step * 6);
            [archives addObject:wire];
            if (lifecycle && step == 2) {
                NSData *begin = [draw beginSnapshotWithError:&error],
                       *vertex = draw.vertexSnapshot;
                require(begin && vertex && [draw flushWithError:&error] &&
                            [draw discardForRestoreWithError:&error] &&
                            [draw restoreVertexSnapshot:vertex error:&error] &&
                            [draw restoreBeginSnapshot:begin error:&error] &&
                            [draw restorePendingSnapshot:wire error:&error] &&
                            [draw beginWithError:&error],
                        error);
                NSData *restored = [draw pendingSnapshotWithError:&error];
                require(restored != nil, error);
                assert([wire isEqualToData:restored]);
            }
        }
    }
    dsp_expected = dsp_inputs();
    NSData *checkpoint = fpp_host();
    if (lifecycle) {
        indexed_fail_emit = YES;
        dsp_drawing = YES;
        BOOL ok = [draw flushDrawWithError:&error];
        dsp_drawing = NO;
        assert(!ok && error && !indexed_fail_emit &&
               [error.domain isEqualToString:@"test.indexed-late-raster"] &&
               [checkpoint isEqualToData:fpp_host()]);
        error = nil;
        NSData *after = [draw pendingSnapshotWithError:&error];
        require(after != nil, error);
        assert([after isEqualToData:archives.lastObject]);
    }
    dsp_drawing = YES;
    BOOL ok = [draw endWithError:&error];
    dsp_drawing = NO;
    require(ok, error);
    NSData *image = fpp_frame(pg);
    NV2AMetalVertexSlice *joined = dsp_slices.lastObject;
    assert(joined && joined.indexedVertices &&
           joined.buffer.storageMode == MTLStorageModeShared &&
           joined.buffer.length >= dsp_expected.vertices.length);
    /* GPU-produced physical bytes are checked before planner/route counts.
     * Failed unsubmitted attempts are intentionally not read as GPU outputs. */
    assert(!memcmp(joined.buffer.contents, dsp_expected.vertices.bytes,
                   dsp_expected.vertices.length));
    assert([joined.indexedVertices.remap isEqualToData:dsp_expected.remap]);
    NSArray *result = @[
        image, archives, dsp_expected.vertices, joined.indexedVertices.remap,
        dsp_expected.copies
    ];
    assert(dsp_logical == 24 && dsp_suffix_calls == 4 &&
           indexed_xf_records == 14 && pg->draw_time == 1);
    NSUInteger sources = lifecycle ? 3 : 4;
    unsigned attempts = lifecycle ? 2 : 1;
    assert(dsp_expected.sources.count == sources &&
           (lifecycle || [NSSet setWithArray:dsp_suffix_sources].count == 4));
    assert(dsp_plan_calls == attempts && dsp_dense_calls == attempts &&
           dsp_dense_hits == (reference ? 0u : attempts) &&
           dsp_slices.count == attempts);
    assert(dsp_copy_calls == sources * attempts &&
           dsp_copy_bytes == dsp_expected.vertices.length * attempts);
    for (NSArray *plan in dsp_plans)
        assert([plan[0] isEqualToData:dsp_expected.remap] &&
               [plan[1] isEqualToData:dsp_expected.copies] &&
               [plan[2] unsignedIntegerValue] ==
                   dsp_expected.vertices.length / sizeof(NV2AMetalVertex));
    qemu_mutex_unlock(&pg->lock);
    dsp_expected = nil;
    dsp_slices = nil;
    dsp_plans = nil;
    dsp_suffix_sources = nil;
    return result;
}
static void dense_stream_pgraph_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(probe && [probe beginWithError:&error], error);
    id encoder = [probe.commandBuffer computeCommandEncoder];
    require(encoder != nil, nil);
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalVertexStream.class,
                                NSSelectorFromString(@"densePlan")),
        class_getInstanceMethod(NV2AMetalVertexStream.class,
                                NSSelectorFromString(@"compactPlan")),
        class_getInstanceMethod(
            NV2AMetalVertexStream.class,
            @selector(encodeSliceForDrawingWithCommands:error:)),
        class_getInstanceMethod(NV2AMetalPendingJournal.class,
                                @selector(commitNextSuffix:progress:error:)),
        class_getInstanceMethod(
            [encoder class],
            @selector(
                copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:)),
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
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    IMP originals[ARRAY_SIZE(methods)];
    IMP replacements[] = { (IMP)dsp_dense,       (IMP)dsp_plan,
                           (IMP)dsp_slice,       (IMP)dsp_suffix,
                           (IMP)dsp_copy,        (IMP)indexed_encode,
                           (IMP)indexed_execute, (IMP)indexed_serial,
                           (IMP)indexed_emit };
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    dsp_dense_original = (void *)originals[0];
    dsp_plan_original = (void *)originals[1];
    dsp_slice_original = (void *)originals[2];
    dsp_suffix_original = (void *)originals[3];
    dsp_copy_original = (void *)originals[4];
    indexed_epoch_encode = (void *)originals[5];
    indexed_epoch_execute = (void *)originals[6];
    indexed_epoch_serial = (void *)originals[7];
    indexed_pixel_emit = (void *)originals[8];
    [encoder endEncoding];
    [probe cancel];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned pairs = 0;
    @try {
        for (unsigned programmed = 0; programmed < 2; programmed++)
            for (unsigned variant = 0; variant < 3; variant++)
                @autoreleasepool {
                    NSArray *old =
                        dsp_run(programmed, variant == 1, variant == 2, YES);
                    NSArray *actual =
                        dsp_run(programmed, variant == 1, variant == 2, NO);
                    assert([old isEqualToArray:actual]);
                    pairs++;
                }
    } @finally {
        dsp_reference = dsp_drawing = dsp_building = indexed_fail_emit = NO;
        dsp_expected = nil;
        dsp_slices = nil;
        dsp_plans = nil;
        dsp_suffix_sources = nil;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    assert(pairs == 6);
    puts("Dense stream PGRAPH:6 Fixed/RO triangles/strip/Restore-retry pairs; "
         "four real deduped XF suffixes, exact GPU physical/logical bytes, "
         "remap/source-order/copy-plan, unchanged GPU-copy/XF work, "
         "FB/Zeta/query/Current/context/archive PASS");
    groups += pairs;
}
#endif
