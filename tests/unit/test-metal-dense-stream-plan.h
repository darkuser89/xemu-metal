/* Dense indexed joins preserve the original compact-plan and archive bytes.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DENSE_STREAM_PLAN_H
#define TEST_METAL_DENSE_STREAM_PLAN_H
#import "hw/xbox/nv2a/pgraph/metal/archive-native.h"

@interface NV2AMetalVertexStream (DenseStreamPlanTest)
- (id)densePlan;
- (id)compactPlan;
@end
static _Thread_local BOOL dsp_reference, dsp_plan_scope, dsp_inside_dense;
static _Thread_local NSUInteger dsp_calls, dsp_hits, dsp_maps, dsp_factories,
    dsp_fail_factory;
static id (*dsp_dense_original)(id, SEL);
static id dsp_dense(id object, SEL selector)
{
    if (dsp_plan_scope)
        dsp_calls++;
    if (dsp_reference)
        return nil;
    BOOL saved = dsp_inside_dense;
    dsp_inside_dense = YES;
    @try {
        id result = dsp_dense_original(object, selector);
        if (dsp_plan_scope && result)
            dsp_hits++;
        return result;
    } @finally {
        dsp_inside_dense = saved;
    }
}
static id (*dsp_data_original)(id, SEL, NSUInteger);
static id dsp_data(id object, SEL selector, NSUInteger length)
{
    if (dsp_inside_dense && dsp_plan_scope) {
        dsp_factories++;
        if (dsp_fail_factory && dsp_factories == dsp_fail_factory) {
            dsp_fail_factory = 0;
            return nil;
        }
    }
    return dsp_data_original(object, selector, length);
}
static id (*dsp_map_original)(id, SEL, NSPointerFunctionsOptions,
                              NSPointerFunctionsOptions);
static id dsp_map(id object, SEL selector, NSPointerFunctionsOptions keys,
                  NSPointerFunctionsOptions values)
{
    if (dsp_plan_scope)
        dsp_maps++;
    return dsp_map_original(object, selector, keys, values);
}
@interface DenseStreamFixture : NSObject {
@public
    NV2AMetalVertexStream *stream;
    NSMutableArray<NSData *> *raw;
    NSMutableArray<id<MTLBuffer>> *buffers;
    NSMutableArray<NV2AMetalIndexedVertices *> *owners;
    NSMutableArray<NV2AMetalPendingSpan *> *spans;
    NSMutableData *expected;
    BOOL discarded;
}
@end
@implementation DenseStreamFixture
@end
static NSData *dsp_raw(NSUInteger source, NSUInteger records)
{
    NSMutableData *data =
        [NSMutableData dataWithLength:records * sizeof(NV2AMetalVertex)];
    uint32_t *words = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length / 4; i++)
        words[i] =
            (uint32_t)(0x9e3779b9u * (i + 1) ^ (source + 1) * 0x13579bdu);
    for (NSUInteger i = 0; i < records; i++) {
        words[i * (sizeof(NV2AMetalVertex) / 4)] = 0x7fc12345u ^ (uint32_t)i;
        words[i * (sizeof(NV2AMetalVertex) / 4) + 1] = 0x80000000;
    }
    return data;
}
static void dsp_append(DenseStreamFixture *f, id resource, NSUInteger first,
                       NSUInteger count)
{
    NSError *error = nil;
    NSUInteger stride = sizeof(NV2AMetalVertex);
    if ([resource isKindOfClass:NV2AMetalDiscardedVertices.class]) {
        require([f->stream appendDiscardedVertices:count error:&error], error);
        [f->expected increaseLengthBy:count * stride];
        f->discarded = YES;
    } else {
        NV2AMetalIndexedVertices *owner =
            [resource isKindOfClass:NV2AMetalIndexedVertices.class] ? resource :
                                                                      nil;
        id<MTLBuffer> buffer = owner ? owner.vertices : resource;
        NSUInteger source = [f->buffers indexOfObjectIdenticalTo:buffer];
        assert(source != NSNotFound);
        NSData *bytes = f->raw[source];
        require(owner ? [f->stream appendIndexedVertices:owner
                                                   first:first
                                                   count:count
                                                   error:&error] :
                        [f->stream appendVertices:buffer
                                            first:first
                                            count:count
                                            error:&error],
                error);
        const uint32_t *map = owner.remap.bytes;
        for (NSUInteger i = 0; i < count; i++) {
            NSUInteger physical = owner ? map[first + i] : first + i;
            assert(physical < bytes.length / stride);
            [f->expected
                appendBytes:(const uint8_t *)bytes.bytes + physical * stride
                     length:stride];
        }
    }
    NV2AMetalPendingSpan *span = [NV2AMetalPendingSpan resource:resource
                                                          first:first
                                                          count:count];
    require(span != nil, nil);
    [f->spans addObject:span];
}
static DenseStreamFixture *dsp_fixture(unsigned mode, BOOL private)
{
    NSError *error = nil;
    DenseStreamFixture *f = [DenseStreamFixture new];
    f->stream = [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                        limit:524287
                                                        error:&error];
    require(f->stream != nil, error);
    f->raw = [NSMutableArray new];
    f->buffers = [NSMutableArray new];
    f->owners = [NSMutableArray new];
    f->spans = [NSMutableArray new];
    f->expected = [NSMutableData new];
    NSUInteger sources = mode == 0 ? 2 : mode == 2 ? 4 : mode == 9 ? 2049 : 3;
    const NSUInteger small[] = { 7, 11, 5, 13 }, large[] = { 256, 257, 511 };
    begin();
    for (NSUInteger s = 0; s < sources; s++) {
        NSUInteger physical = mode == 9 ? 1 : mode == 3 ? large[s] : small[s];
        if (mode == 6 && s == 1)
            physical = small[0];
        NSData *data = dsp_raw(
            s, physical + 3); // Hidden source tail must never be copied.
        id<MTLBuffer> buffer;
        if (mode == 6 && s == 1) {
            buffer = f->buffers[0];
            data = f->raw[0];
        } else {
            id<MTLBuffer> shared = [commands.device
                newBufferWithBytes:data.bytes
                            length:data.length
                           options:MTLResourceStorageModeShared];
            require(shared != nil, nil);
            if (private) {
                buffer = [commands.device
                    newBufferWithLength:data.length
                                options:MTLResourceStorageModePrivate];
                require(buffer != nil, nil);
                upload(shared, buffer);
            } else
                buffer = shared;
        }
        [f->raw addObject:data];
        [f->buffers addObject:buffer];
        NSUInteger logical = physical * 2 + 3;
        NSMutableData *map = [NSMutableData dataWithLength:logical * 4];
        uint32_t *indices = map.mutableBytes;
        for (NSUInteger i = 0; i < logical; i++) {
            NSUInteger domain = mode == 5 && s == 0 ? physical - 1 : physical;
            indices[i] = (uint32_t)((i * 17 + 3) % domain);
        }
        NV2AMetalIndexedVertices *owner =
            [[NV2AMetalIndexedVertices alloc] initWithVertices:buffer
                                                 physicalCount:physical
                                                         remap:map
                                                         error:&error];
        require(owner != nil, error);
        [f->owners addObject:owner];
        NSUInteger first = mode == 4 && s == 0 ? 1 : 0;
        dsp_append(f, owner, first, logical - first);
    }
    if (mode == 7)
        dsp_append(f, f->buffers[0], 2, 3);
    if (mode == 8) {
        NV2AMetalDiscardedVertices *zero =
            [[NV2AMetalDiscardedVertices alloc] initWithCount:3];
        dsp_append(f, zero, 0, 3);
    }
    finish();
    return f;
}
@interface DenseStreamObservation : NSObject
@property(nonatomic, strong) NSData *remap, *physical, *logical, *copies;
@property(nonatomic) NSUInteger physicalCount, calls, hits, maps, factories;
@property(nonatomic) NSUInteger captureCalls, captureHits, captureMaps,
    captureFactories;
@end
@implementation DenseStreamObservation
@end
static NSData *dsp_copies(id plan)
{
    NSMutableData *result = [NSMutableData data];
    for (id copy in [plan valueForKey:@"copies"]) {
        id buffer = [copy valueForKey:@"buffer"];
        const uint64_t fields[] = {
            (uint64_t)(uintptr_t)(__bridge void *)buffer,
            [[copy valueForKey:@"first"] unsignedLongLongValue],
            [[copy valueForKey:@"count"] unsignedLongLongValue],
            [[copy valueForKey:@"destination"] unsignedLongLongValue]
        };
        [result appendBytes:fields length:sizeof(fields)];
    }
    return result;
}
static NSData *dsp_physical(DenseStreamFixture *f, id plan)
{
    NSUInteger stride = sizeof(NV2AMetalVertex);
    NSUInteger count =
        [[plan valueForKey:@"physicalCount"] unsignedIntegerValue];
    NSMutableData *result = [NSMutableData dataWithLength:count * stride];
    for (id copy in [plan valueForKey:@"copies"]) {
        id buffer = [copy valueForKey:@"buffer"];
        if (!buffer)
            continue;
        NSUInteger source = [f->buffers indexOfObjectIdenticalTo:buffer];
        assert(source != NSNotFound);
        NSUInteger first = [[copy valueForKey:@"first"] unsignedIntegerValue],
                   length = [[copy valueForKey:@"count"] unsignedIntegerValue],
                   destination =
                       [[copy valueForKey:@"destination"] unsignedIntegerValue];
        assert(first <= f->raw[source].length / stride &&
               length <= f->raw[source].length / stride - first &&
               destination <= count && length <= count - destination);
        memcpy((uint8_t *)result.mutableBytes + destination * stride,
               (const uint8_t *)f->raw[source].bytes + first * stride,
               length * stride);
    }
    return result;
}
static DenseStreamObservation *dsp_observe(DenseStreamFixture *f,
                                           BOOL reference, NSUInteger fail)
{
    NSError *error = nil;
    dsp_reference = reference;
    dsp_calls = dsp_hits = dsp_maps = dsp_factories = 0;
    dsp_fail_factory = fail;
    dsp_plan_scope = YES;
    id plan;
    @try {
        plan = [f->stream compactPlan];
    } @finally {
        dsp_plan_scope = NO;
    }
    require(plan != nil, nil);
    DenseStreamObservation *o = [DenseStreamObservation new];
    o.remap = [[plan valueForKey:@"remap"] copy];
    o.copies = dsp_copies(plan);
    o.physicalCount =
        [[plan valueForKey:@"physicalCount"] unsignedIntegerValue];
    o.calls = dsp_calls;
    o.hits = dsp_hits;
    o.maps = dsp_maps;
    o.factories = dsp_factories;
    NSData *expectedPhysical = dsp_physical(f, plan);
    begin();
    BOOL drawingRejected = YES;
    if (f->discarded) {
        drawingRejected =
            ![f->stream encodeSliceForDrawingWithCommands:commands
                                                    error:&error] &&
            error;
        error = nil;
    }
    // Rearm the same nil ordinal in the real capture encode: it must
    // execute the original General plan, not a successful dense recomputation.
    dsp_calls = dsp_hits = dsp_maps = dsp_factories = 0;
    dsp_fail_factory = fail;
    dsp_plan_scope = YES;
    NV2AMetalVertexSlice *slice;
    @try {
        slice = [f->stream encodeCompactSliceForCaptureWithCommands:commands
                                                              error:&error];
    } @finally {
        dsp_plan_scope = NO;
    }
    o.captureCalls = dsp_calls;
    o.captureHits = dsp_hits;
    o.captureMaps = dsp_maps;
    o.captureFactories = dsp_factories;
    require(slice != nil, error);
    id<MTLBuffer> linear = [f->stream encodeWithCommands:commands error:&error];
    require(linear != nil, error);
    id<MTLBuffer> physicalRead = read_buffer(
        slice.buffer, 0,
        slice.indexedVertices.physicalVertexCount * sizeof(NV2AMetalVertex));
    id<MTLBuffer> logicalRead = read_buffer(linear, 0, f->expected.length);
    finish();
    o.physical = [NSData dataWithBytes:physicalRead.contents
                                length:physicalRead.length];
    o.logical = [NSData dataWithBytes:logicalRead.contents
                               length:logicalRead.length];
    // Real GPU logical bytes and complete physical payload precede work counts.
    assert([o.logical isEqualToData:f->expected] &&
           [o.physical isEqualToData:expectedPhysical]);
    assert([slice.indexedVertices.remap isEqualToData:o.remap] &&
           slice.indexedVertices.physicalVertexCount == o.physicalCount &&
           slice.vertexCount == f->stream.vertexCount && drawingRejected);
    NSMutableData *expanded = [NSMutableData data];
    const uint32_t *map = o.remap.bytes;
    for (NSUInteger i = 0; i < f->stream.vertexCount; i++) {
        assert(map[i] < o.physicalCount);
        [expanded appendBytes:(const uint8_t *)o.physical.bytes +
                              map[i] * sizeof(NV2AMetalVertex)
                       length:sizeof(NV2AMetalVertex)];
    }
    assert([expanded isEqualToData:f->expected]);
    NSData *hostMap = nil,
           *host = [f->stream completedHostCompactVertexDataWithRemap:&hostMap];
    if (host)
        assert([host isEqualToData:o.physical] &&
               [hostMap isEqualToData:o.remap]);
    dsp_fail_factory = 0;
    return o;
}
static void dsp_pair(unsigned mode, BOOL private, NSUInteger fail)
{
    @autoreleasepool {
        DenseStreamFixture *f = dsp_fixture(mode, private);
        DenseStreamObservation *old = dsp_observe(f, YES, 0),
                               *actual = dsp_observe(f, NO, fail);
        assert([old.logical isEqualToData:actual.logical] &&
               [old.physical isEqualToData:actual.physical] &&
               [old.remap isEqualToData:actual.remap] &&
               [old.copies isEqualToData:actual.copies] &&
               old.physicalCount == actual.physicalCount);
        BOOL dense = mode < 4 && !fail;
        assert(old.calls == 1 && !old.hits && old.maps == 1 &&
               actual.calls == 1 && actual.hits == dense &&
               actual.maps == !dense);
        assert(old.captureCalls == 1 && !old.captureHits &&
               old.captureMaps == 1 && actual.captureCalls == 1 &&
               actual.captureHits == dense && actual.captureMaps == !dense);
        if (dense) {
            NSUInteger total = 0;
            for (NV2AMetalIndexedVertices *owner in f->owners)
                total += owner.physicalVertexCount;
            assert(actual.physicalCount == total &&
                   actual.copies.length ==
                       f->owners.count * 4 * sizeof(uint64_t));
            const uint32_t *map = actual.remap.bytes;
            NSUInteger logical = 0, base = 0;
            for (NV2AMetalIndexedVertices *owner in f->owners) {
                const uint32_t *source = owner.remap.bytes;
                for (NSUInteger i = 0; i < owner.vertexCount; i++)
                    assert(map[logical++] == base + source[i]);
                base += owner.physicalVertexCount;
            }
        }
        if (fail) {
            assert(actual.factories == fail && actual.captureFactories == fail);
            DenseStreamObservation *retry = dsp_observe(f, NO, 0);
            assert([old.logical isEqualToData:retry.logical] &&
                   [old.physical isEqualToData:retry.physical] &&
                   [old.remap isEqualToData:retry.remap] &&
                   [old.copies isEqualToData:retry.copies]);
            assert(retry.hits == 1 && !retry.maps && retry.captureHits == 1 &&
                   !retry.captureMaps);
        }
    }
}
static NV2AMetalPendingJournal *dsp_journal(DenseStreamFixture *f)
{
    NV2AMetalPendingJournal *journal =
        [[NV2AMetalPendingJournal alloc] initWithLimit:524287];
    NSError *error = nil;
    NSUInteger total = 0;
    for (NV2AMetalPendingSpan *span in f->spans) {
        total += span.count;
        NV2AMetalPendingInput *input =
            [NV2AMetalPendingInput inlineKind:NV2AMetalInputInlineBuffer
                                        count:total];
        NV2AMetalPendingPlan *plan = [journal planInputs:@[ input ]
                                     preservingLastArray:NO
                                                   error:&error];
        NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                     suffixes:@[ span ]
                                                        error:&error];
        require(update && [journal commitUpdate:update error:&error], error);
    }
    return journal;
}
static void dsp_archive(BOOL private)
{
    @autoreleasepool {
        DenseStreamFixture *f = dsp_fixture(1, private);
        NV2AMetalPendingJournal *journal = dsp_journal(f);
        NSError *error = nil;
        dsp_reference = YES;
        NV2AMetalPendingArchive *old =
            nv2a_metal_pending_capture(journal, commands, &error);
        require(old != nil, error);
        dsp_reference = NO;
        NV2AMetalPendingArchive *actual =
            nv2a_metal_pending_capture(journal, commands, &error);
        require(actual != nil, error);
        assert([old.vertices[0] isEqualToData:f->expected] &&
               [actual.vertices[0] isEqualToData:f->expected] &&
               [[old data] isEqualToData:[actual data]] &&
               [old.remaps isEqualToArray:actual.remaps] &&
               [old.physicalVertices isEqualToArray:actual.physicalVertices]);
        NV2AMetalPendingJournal *restored =
            nv2a_metal_pending_restore(actual, commands, 524287, &error);
        require(restored != nil, error);
        NV2AMetalPendingArchive *again =
            nv2a_metal_pending_capture(restored, commands, &error);
        require(again != nil, error);
        assert([[actual data] isEqualToData:[again data]] &&
               [again.vertices[0] isEqualToData:f->expected]);
    }
}
static void dense_stream_plan_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalVertexStream.class,
                                @selector(densePlan)),
        class_getClassMethod(NSMutableData.class, @selector(dataWithLength:)),
        class_getClassMethod(NSMapTable.class,
                             @selector(mapTableWithKeyOptions:valueOptions:))
    };
    IMP originals[3];
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    dsp_dense_original = (void *)originals[0];
    dsp_data_original = (void *)originals[1];
    dsp_map_original = (void *)originals[2];
    IMP replacements[] = { (IMP)dsp_dense, (IMP)dsp_data, (IMP)dsp_map };
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned cases = 0;
    @try {
        for (unsigned mode = 0; mode < 6; mode++)
            for (unsigned private = 0; private < 2; private ++) {
                dsp_pair(mode, private, 0);
                cases++;
            }
        dsp_pair(6, NO, 0);
        dsp_pair(7, NO, 0);
        dsp_pair(8, YES, 0);
        dsp_pair(9, NO, 0);
        cases += 4;
        dsp_pair(1, NO, 1);
        dsp_pair(1, NO, 2);
        cases += 2;
        dsp_archive(NO);
        dsp_archive(YES);
    } @finally {
        dsp_reference = dsp_plan_scope = dsp_inside_dense = NO;
        dsp_fail_factory = 0;
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    assert(cases == 18);
    puts("Dense stream plan:18 original-builder GPU/raw244B/remap/copy-range "
         "pairs; "
         "Shared/Private,multi-source/duplicates/hidden-tail,partial/sparse/"
         "shared-buffer/raw/discard/budget,"
         "two allocation-nil fallbacks+retry,two native archive cycles PASS");
}
#endif
