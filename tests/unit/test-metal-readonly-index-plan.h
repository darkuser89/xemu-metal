/* Pure readonly index compaction metadata, with fresh native fetch guards.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_READONLY_INDEX_PLAN_H
#define TEST_METAL_READONLY_INDEX_PLAN_H
#import <objc/runtime.h>
#import "hw/xbox/nv2a/pgraph/metal/pending-archive.h"
@interface NV2AMetalPGRAPHFetch (ReadonlyIndexPlanTest)
- (NSData *)buildReadonlyIndices:(NV2AMetalPendingInput *)input
                          prefix:(NSUInteger)prefix
                           remap:(NSData **)remap
                         current:(NSUInteger *)current
                        computed:(BOOL *)computed;
@end
static _Thread_local BOOL rip_building, rip_fail;
static _Thread_local NSUInteger rip_builds, rip_data, rip_copies;
static _Thread_local NSUInteger rip_nil_data, rip_nil_copy;
static NSUInteger rip_pairs;
static NV2AMetalWritableProgram *rip_xf;
static id (*rip_builder_original)(id, SEL, id, NSUInteger, NSData **,
                                  NSUInteger *, BOOL *);
static id rip_builder(id object, SEL selector, id input, NSUInteger prefix,
                      NSData **remap, NSUInteger *current, BOOL *computed)
{
    rip_builds++;
    if (rip_fail) {
        *computed = NO;
        return nil;
    }
    rip_building = YES;
    @try {
        return rip_builder_original(object, selector, input, prefix, remap,
                                    current, computed);
    } @finally {
        rip_building = NO;
    }
}
static id (*rip_data_original)(id, SEL, NSUInteger);
static id rip_data_factory(id object, SEL selector, NSUInteger length)
{
    if (rip_building) {
        rip_data++;
        if (rip_nil_data && rip_data == rip_nil_data)
            return nil;
    }
    return rip_data_original(object, selector, length);
}
@interface NSMutableData (ReadonlyIndexPlanCopies)
- (id)rip_copyWithZone:(NSZone *)zone __attribute__((objc_method_family(copy)));
@end
@implementation NSMutableData (ReadonlyIndexPlanCopies)
- (id)rip_copyWithZone:(NSZone *)zone
{
    if (rip_building) {
        rip_copies++;
        if (rip_nil_copy && rip_copies == rip_nil_copy)
            return nil;
    }
    return [self rip_copyWithZone:zone];
}
@end
@interface ReadonlyIndexPlanSubclass : NV2AMetalPendingInput
@end
@implementation ReadonlyIndexPlanSubclass
@end
static void rip_reset_counts(void)
{
    rip_builds = rip_data = rip_copies = 0;
}
static void rip_uncache(NV2AMetalPGRAPHFetch *owner)
{
    [owner setValue:@NO forKey:@"readonlyIndexComputed"];
    for (NSString *key in @[
             @"readonlyIndexInput", @"readonlyIndexData",
             @"readonlyUniqueIndices", @"readonlyRemap"
         ])
        [owner setValue:nil forKey:key];
}
static NSUInteger rip_payload(NV2AMetalPGRAPHFetch *owner)
{
    NSUInteger bytes = 0;
    for (NSString *key in @[
             @"arrayRangesKey", @"arrayRanges", @"indexRangesKey",
             @"indexRanges", @"readonlyUniqueIndices", @"readonlyRemap"
         ])
        bytes += ((NSData *)[owner valueForKey:key]).length;
    assert(bytes <= 65536);
    return bytes;
}
static NV2AMetalPendingInput *rip_input(const uint32_t *indices,
                                        NSUInteger count,
                                        NV2AMetalPendingInput *previous)
{
    state->pgraph.draw_arrays_length = 0;
    state->pgraph.inline_elements_length = count;
    memcpy(state->pgraph.inline_elements, indices, count * 4);
    return [NV2AMetalPendingInput indexedBytes:indices
                                         count:count
                              matchingPrevious:previous];
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
rip_encode(NV2AMetalPGRAPHFetch *owner, NV2AMetalPendingInput *input,
           NSUInteger prefix, BOOL host, BOOL dedupe, NSError **error)
{
    return host ? [owner encodeCurrentSnapshotsWithPrefixes:@[ @(prefix) ]
                                               indexedInput:input
                                        deduplicateReadonly:dedupe
                                                      error:error] :
                  [owner encodeIndependentSnapshotsWithPrefixes:@[ @(prefix) ]
                                                   indexedInput:input
                                            deduplicateReadonly:dedupe
                                                          error:error];
}
/* The unchanged GPU fetch and XF consume each plan. Logical GPU inputs,
 * Current, transformed records and canonical archive bytes are all compared. */
static NSArray<NSData *> *rip_run(NV2AMetalPGRAPHFetch *owner,
                                  NV2AMetalPendingInput *input,
                                  NSUInteger prefix, BOOL host, BOOL dedupe)
{
    NSError *error = nil;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
        rip_encode(owner, input, prefix, host, dedupe, &error);
    require(batches != nil, error);
    NV2AMetalPGRAPHFetchBatch *b = batches[0];
    NV2AMetalWritableEncoding *encoding = nil;
    NV2AMetalProgramUniforms uniforms = { 0 };
    uniforms.surface_size[0] = uniforms.surface_size[1] = 64;
    uniforms.zmax = 65535;
    uniforms.point_scale = uniforms.point_size = 1;
    if (b.fetch.vertexCount) {
        Token t = token(1, 0, 96);
        source(&t, 0, 2, 0, 0xe4);
        destination(&t, 0x100, 15, 0, 0, 0, 0);
        t.word[3] |= 1;
        encoding = [rip_xf encodeTokens:t.word
                                 length:1
                               uniforms:&uniforms
                        attributeBuffer:b.fetch.attributes
                                  first:0
                                  count:b.fetch.vertexCount
                                 access:1
                            writeEnable:NO
                              rasterize:YES
                               commands:owner.encodingCommands
                                  error:&error];
        require(encoding != nil, error);
    }
    require(host ? [owner completeCurrentSnapshotsWithError:&error] :
                   [owner completeWithError:&error],
            error);
    if (host)
        require([surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error],
                error);
    NV2AMetalWritableResult *transformed =
        encoding ? [encoding resolveWithError:&error] : nil;
    require(!encoding || transformed != nil, error);
    NSUInteger suffix = input.count - prefix;
    const NV2AMetalProgramInput *physical = b.fetch.attributes.contents;
    const uint32_t *map = b.remap.bytes;
    const uint32_t *indices = input.indices.bytes;
    NSMutableData *logical = [NSMutableData new];
    for (NSUInteger i = 0; i < suffix; i++) {
        NSUInteger ordinal = map ? map[i] : i;
        assert(ordinal < b.fetch.vertexCount);
        const NV2AMetalProgramInput *v = physical + ordinal;
        [logical appendBytes:v length:sizeof(*v)];
        if (state->pgraph.vertex_attributes[0].format ==
                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F &&
            state->pgraph.vertex_attributes[0].count == 4) {
            VertexAttribute *a = &state->pgraph.vertex_attributes[0];
            const void *expected = state->vram_ptr + dma_a.address + a->offset +
                                   indices[prefix + i] * a->stride;
            /* Real source bytes before cache/copy/identity assertions. */
            assert(!memcmp(v->attributes[0], expected, 16));
            const NV2AMetalProgramOutput *raw = transformed.registers.contents;
            assert(!raw[ordinal].fault &&
                   !memcmp(raw[ordinal].registers[0], expected, 16));
        }
    }
    for (unsigned a = 0; a < 16; a++)
        [logical appendBytes:state->pgraph.vertex_attributes[a].inline_value
                      length:16];
    if (state->pgraph.vertex_attributes[0].format ==
            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F &&
        state->pgraph.vertex_attributes[0].count == 4) {
        VertexAttribute *a = &state->pgraph.vertex_attributes[0];
        assert(!memcmp(a->inline_value,
                       state->vram_ptr + dma_a.address + a->offset +
                           indices[input.count - 1] * a->stride,
                       16));
    }
    NSData *archiveBytes = [NSData data];
    if (suffix) {
        NSData *guest = [input.indices
            subdataWithRange:NSMakeRange(prefix * 4, suffix * 4)];
        NV2AMetalPendingInput *suffixInput =
            [NV2AMetalPendingInput indexed:guest];
        NSData *records = [NSData
            dataWithBytes:transformed.vertices.contents
                   length:b.fetch.vertexCount * sizeof(NV2AMetalVertex)];
        NV2AMetalPendingArchive *archive = [[NV2AMetalPendingArchive alloc]
              initWithInputs:@[ suffixInput ]
            physicalVertices:@[ records ]
                      remaps:@[ b.remap ?: [NSData data] ]
                       limit:524287
                       error:&error];
        require(archive != nil, error);
        archiveBytes = archive.data;
        NV2AMetalPendingArchive *restored =
            [[NV2AMetalPendingArchive alloc] initWithData:archiveBytes
                                                    limit:524287
                                                    error:&error];
        require(restored != nil, error);
        assert([restored.physicalVertices[0] isEqualToData:records] &&
               [restored.remaps[0] isEqualToData:b.remap ?: [NSData data]]);
    }
    assert(b.inputVertexCount == input.count &&
           b.firstDecodedVertex == prefix &&
           b.physicalVertexCount == b.fetch.vertexCount);
    rip_payload(owner);
    return @[ logical, archiveBytes ];
}
static void rip_pair(NV2AMetalPGRAPHFetch *owner, NV2AMetalPendingInput *input,
                     NSUInteger prefix, BOOL host, BOOL positive)
{
    rip_reset_counts();
    NSArray *cold = rip_run(owner, input, prefix, host, YES);
    NSUInteger builds = rip_builds, data = rip_data, copies = rip_copies;
    NSData *unique = [owner valueForKey:@"readonlyUniqueIndices"];
    NSData *remap = [owner valueForKey:@"readonlyRemap"];
    rip_reset_counts();
    NSArray *warm = rip_run(owner, input, prefix, host, YES);
    NSUInteger warmBuilds = rip_builds, warmData = rip_data,
               warmCopies = rip_copies;
    rip_uncache(owner);
    rip_reset_counts();
    NSArray *old = rip_run(owner, input, prefix, host, YES);
    assert([cold isEqualToArray:warm] && [warm isEqualToArray:old]);
    assert(builds == 1 && !warmBuilds && !warmData && !warmCopies &&
           rip_builds == 1);
    assert(!positive ||
           (data == 2 && copies == 2 && rip_data == 2 && rip_copies == 2));
    assert(!positive ||
           (unique && remap && ![unique isKindOfClass:NSMutableData.class] &&
            ![remap isKindOfClass:NSMutableData.class]));
    rip_pairs++;
}
static void rip_shapes(void)
{
    const uint32_t shapes[][8] = { { 5, 2, 5, 1, 2, 5, 2, 1 },
                                   { 3, 3, 3, 3, 3, 3, 3, 3 },
                                   { 0, 1, 2, 3, 4, 5, 6, 7 },
                                   { 7, 6, 5, 4, 3, 2, 1, 0 },
                                   { 5, 2, 7, 1, 3, 6, 4, 0 } };
    for (unsigned host = 0; host < 2; host++) {
        arp_setup();
        tcg_allowed = YES;
        NV2AMetalPGRAPHFetch *owner = arp_owner();
        for (unsigned shape = 0; shape < ARRAY_SIZE(shapes); shape++) {
            NV2AMetalPendingInput *input = rip_input(shapes[shape], 8, nil);
            rip_pair(owner, input, 0, host, shape < 2);
            rip_pair(owner, input, 3, host, shape < 2);
        }
        [owner close];
        assert(![owner valueForKey:@"readonlyUniqueIndices"] &&
               ![owner valueForKey:@"readonlyRemap"] &&
               ![[owner valueForKey:@"readonlyIndexComputed"] boolValue]);
    }
}
static void rip_lifetimes_and_guards(void)
{
    arp_setup();
    tcg_allowed = YES;
    NV2AMetalPGRAPHFetch *owner = arp_owner();
    const uint32_t initial[] = { 5, 2, 5, 1, 2, 5, 2, 1 };
    NV2AMetalPendingInput *input = rip_input(initial, 6, nil);
    rip_pair(owner, input, 0, NO, YES);
    NV2AMetalPendingInput *grown = rip_input(initial, 8, input);
    assert(grown != input && grown.indices != input.indices &&
           grown.indices.bytes == input.indices.bytes);
    rip_pair(owner, grown, 0, NO, YES);
    uint32_t changed[8];
    memcpy(changed, initial, sizeof(changed));
    changed[0] = 4;
    NV2AMetalPendingInput *mutated = rip_input(changed, 8, grown);
    assert(mutated != grown);
    rip_pair(owner, mutated, 0, NO, YES);
    rip_reset_counts();
    rip_run(owner, mutated, 0, NO, NO);
    assert(!rip_builds && !rip_data && !rip_copies);
    NSError *error = nil;
    require(rip_encode(owner, mutated, 0, NO, YES, &error) != nil, error);
    [owner cancel];
    rip_reset_counts();
    rip_run(owner, mutated, 0, NO, YES);
    assert(!rip_builds);
    error = nil;
    rip_reset_counts();
    assert(!rip_encode(owner, mutated, mutated.count + 1, NO, YES, &error) &&
           error && !rip_builds);
    error = nil;
    assert(![owner encodeIndependentSnapshotsWithPrefixes:@[ @0.5 ]
                                             indexedInput:mutated
                                      deduplicateReadonly:YES
                                                    error:&error] &&
           error && !rip_builds);
    rip_reset_counts();
    NSArray *legacy = [owner encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
                                                       indexedInput:nil
                                                deduplicateReadonly:YES
                                                              error:&error];
    require(legacy != nil && [owner completeWithError:&error], error);
    assert(!((NV2AMetalPGRAPHFetchBatch *)legacy[0]).remap && !rip_builds);
    VertexAttribute saved = state->pgraph.vertex_attributes[0];
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        dma_a.limit = invalid == 0 ? 15 : 65535;
        state->pgraph.vertex_attributes[0] = saved;
        if (invalid == 1)
            state->pgraph.vertex_attributes[0].format = UINT32_MAX;
        if (invalid == 2)
            state->pgraph.vertex_attributes[0].stride = UINT32_MAX;
        error = nil;
        rip_reset_counts();
        assert(!rip_encode(owner, mutated, 0, NO, YES, &error) && error &&
               !rip_builds);
    }
    dma_a.limit = 65535;
    state->pgraph.vertex_attributes[0] = saved;
    for (unsigned format = 0; format < 2; format++) {
        state->pgraph.vertex_attributes[0].format =
            format ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D :
                     NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        state->pgraph.vertex_attributes[0].size = format ? 1 : 4;
        state->pgraph.vertex_attributes[0].stride = format ? 4 : 16;
        rip_reset_counts();
        NSArray *warm = rip_run(owner, mutated, 0, NO, YES);
        assert(!rip_builds);
        rip_uncache(owner);
        NSArray *old = rip_run(owner, mutated, 0, NO, YES);
        assert([warm isEqualToArray:old]);
    }
    state->pgraph.vertex_attributes[0] = saved;
    NV2AMetalCachedSurface *dirty = index_ranges_writer(4);
    unsigned notices = notifications;
    rip_reset_counts();
    rip_run(owner, mutated, 0, NO, YES);
    assert(!rip_builds && !dirty.dirty && notifications == notices + 1);
    /* No plan owns the immutable input/view. An exact retained range-key
     * witness may still prove a new descriptor after both objects die. */
    __weak NV2AMetalPendingInput *weakInput;
    __weak NSData *weakData;
    @autoreleasepool {
        NV2AMetalPendingInput *temporary = rip_input(initial, 8, nil);
        weakInput = temporary;
        weakData = temporary.indices;
        rip_run(owner, temporary, 0, NO, YES);
    }
    assert(!weakInput && !weakData);
    rip_reset_counts();
    rip_run(owner, rip_input(initial, 8, nil), 0, NO, YES);
    assert(rip_builds == 0);
    ReadonlyIndexPlanSubclass *subclass = [ReadonlyIndexPlanSubclass
        indexed:[NSData dataWithBytes:initial length:sizeof(initial)]];
    rip_input(initial, 8, nil);
    rip_reset_counts();
    NSArray *one = rip_run(owner, subclass, 0, NO, YES);
    NSArray *two = rip_run(owner, subclass, 0, NO, YES);
    assert([one isEqualToArray:two] && rip_builds == 2);
    rip_uncache(owner);
    rip_fail = YES;
    rip_reset_counts();
    NSArray *fallback = rip_run(owner, mutated, 0, NO, YES);
    assert(rip_builds == 1 &&
           ![[owner valueForKey:@"readonlyIndexComputed"] boolValue]);
    rip_fail = NO;
    rip_reset_counts();
    NSArray *retry = rip_run(owner, mutated, 0, NO, YES);
    assert([fallback[0] isEqualToData:retry[0]] && rip_builds == 1 &&
           [owner valueForKey:@"readonlyRemap"]);
    rip_reset_counts();
    rip_run(owner, mutated, 0, NO, YES);
    assert(!rip_builds);
    [owner close];
}
static void rip_allocation_failures(void)
{
    arp_setup();
    tcg_allowed = YES;
    NV2AMetalPGRAPHFetch *owner = arp_owner();
    const uint32_t indices[] = { 5, 2, 5, 1, 2, 5, 2, 1 };
    NV2AMetalPendingInput *input = rip_input(indices, ARRAY_SIZE(indices), nil);
    for (unsigned failure = 0; failure < 4; failure++) {
        BOOL host = failure & 1;
        rip_uncache(owner);
        rip_reset_counts();
        rip_nil_data = failure < 2 ? failure + 1 : 0;
        rip_nil_copy = failure >= 2 ? failure - 1 : 0;
        NSArray *fallback = rip_run(owner, input, 0, host, YES);
        NSUInteger builds = rip_builds, data = rip_data, copies = rip_copies;
        BOOL computed =
            [[owner valueForKey:@"readonlyIndexComputed"] boolValue];
        NSData *partialRemap = [owner valueForKey:@"readonlyRemap"];
        rip_nil_data = rip_nil_copy = 0;
        /* The reference runs exactly the original linear upload/Fetch/XF.
         * Check actual GPU records, Current and v1 archive before metadata. */
        NSArray *linear = rip_run(owner, input, 0, host, NO);
        assert([fallback isEqualToArray:linear]);
        assert(builds == 1 && data == 2 && copies == (failure < 2 ? 0 : 2) &&
               !computed && !partialRemap);
        rip_reset_counts();
        NSArray *retry = rip_run(owner, input, 0, host, YES);
        NSUInteger retryBuilds = rip_builds, retryData = rip_data,
                   retryCopies = rip_copies;
        rip_reset_counts();
        NSArray *warm = rip_run(owner, input, 0, host, YES);
        assert([fallback[0] isEqualToData:retry[0]] &&
               [retry isEqualToArray:warm]);
        assert(retryBuilds == 1 && retryData == 2 && retryCopies == 2 &&
               !rip_builds && !rip_data && !rip_copies &&
               [owner valueForKey:@"readonlyRemap"] &&
               [[owner valueForKey:@"readonlyIndexComputed"] boolValue]);
    }
    [owner close];
}
static void rip_budget(void)
{
    arp_setup();
    tcg_allowed = YES;
    NV2AMetalPGRAPHFetch *owner = arp_owner();
    PGRAPHState *pg = &state->pgraph;
    const uint32_t small[] = { 0, 1, 0, 2, 1, 0, 2, 0 };
    NV2AMetalPendingInput *input = rip_input(small, 8, nil);
    rip_run(owner, input, 0, NO, YES);
    assert([owner valueForKey:@"indexRanges"] &&
           [owner valueForKey:@"readonlyRemap"]);
    pg->inline_elements_length = 0;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_start[0] = 0;
    pg->draw_arrays_count[0] = 1;
    arp_run(owner, nil, NO);
    assert([owner valueForKey:@"arrayRanges"] &&
           [owner valueForKey:@"indexRanges"] &&
           [owner valueForKey:@"readonlyRemap"] && rip_payload(owner));

    /* A large valid compact plan uses 64008 payload bytes. Zero-stride
     * attributes need no new range plan; all source guards remain real. */
    NSMutableData *words = [NSMutableData dataWithLength:16000 * 4];
    uint32_t *indices = words.mutableBytes;
    for (unsigned i = 0; i < 16000; i++)
        indices[i] = i & 1;
    input = rip_input(indices, 16000, nil);
    pg->vertex_attributes[0].stride = 0;
    rip_run(owner, input, 0, NO, YES);
    assert([[owner valueForKey:@"readonlyRemap"] length] == 64000 &&
           [[owner valueForKey:@"readonlyUniqueIndices"] length] == 8 &&
           rip_payload(owner) <= 65536);

    /* A 65536-byte sparse range plan excludes all other payloads. */
    words.length = 4096 * 4;
    indices = words.mutableBytes;
    for (unsigned i = 0; i < 4096; i++)
        indices[i] = i * 2;
    NV2AMetalPendingInput *sparse = rip_input(indices, 4096, nil);
    pg->vertex_attributes[0].count = 4;
    pg->vertex_attributes[0].stride = 4;
    index_ranges_run(owner, sparse, 0, NO);
    assert([[owner valueForKey:@"indexRanges"] length] == 65536 &&
           ![owner valueForKey:@"readonlyRemap"] &&
           ![owner valueForKey:@"arrayRanges"] && rip_payload(owner) == 65536);

    /* Rebuilding the compact plan evicts that range plan in turn. */
    pg->vertex_attributes[0].count = 4;
    pg->vertex_attributes[0].stride = 0;
    rip_input(input.indices.bytes, input.count, nil);
    rip_run(owner, input, 0, NO, YES);
    assert(![owner valueForKey:@"indexRanges"] &&
           [[owner valueForKey:@"readonlyRemap"] length] == 64000);

    /* Largest DrawArrays metadata is built before a fresh DMA rejection.
     * This tests its budget admission without issuing 1250 useless kernels. */
    pg->inline_elements_length = 0;
    pg->draw_arrays_length = ARRAY_SIZE(pg->draw_arrays_start);
    pg->vertex_attributes[0].count = 1;
    pg->vertex_attributes[0].stride = 4;
    for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
        pg->draw_arrays_start[i] = i * 2;
        pg->draw_arrays_count[i] = 1;
    }
    dma_a.limit = 1;
    arp_reject(owner, nil);
    assert(![owner valueForKey:@"readonlyRemap"] &&
           [[owner valueForKey:@"arrayRanges"] length] == 20000 &&
           rip_payload(owner) == 35004);

    /* Compact admission must also evict a pre-existing large array plan. */
    dma_a.limit = 65535;
    pg->vertex_attributes[0].count = 4;
    pg->vertex_attributes[0].stride = 0;
    rip_input(input.indices.bytes, input.count, nil);
    rip_run(owner, input, 0, NO, YES);
    assert(![owner valueForKey:@"arrayRanges"] &&
           [[owner valueForKey:@"readonlyRemap"] length] == 64000 &&
           rip_payload(owner) == 64008);

    /* Above-budget positive results still execute correctly, but never pin
     * their large remap in the cache. They rebuild on the next request. */
    words.length = 17000 * 4;
    indices = words.mutableBytes;
    for (unsigned i = 0; i < 17000; i++)
        indices[i] = i & 1;
    NV2AMetalPendingInput *large = rip_input(indices, 17000, nil);
    rip_reset_counts();
    NSArray *first = rip_run(owner, large, 0, NO, YES);
    NSArray *second = rip_run(owner, large, 0, NO, YES);
    assert([first isEqualToArray:second] && rip_builds == 2 &&
           ![owner valueForKey:@"readonlyRemap"] &&
           rip_payload(owner) <= 65536);
    [owner close];
}

static void readonly_index_plan_tests(void)
{
    NSError *error = nil;
    rip_xf = [[NV2AMetalWritableProgram alloc]
        initWithDevice:surfaces.commands.device
                 error:&error];
    require(rip_xf != nil, error);
    SEL builderSelector =
        @selector(buildReadonlyIndices:prefix:remap:current:computed:);
    Method builder =
        class_getInstanceMethod(NV2AMetalPGRAPHFetch.class, builderSelector);
    assert(builder);
    rip_builder_original = (void *)method_getImplementation(builder);
    Method data =
        class_getClassMethod(NSMutableData.class, @selector(dataWithLength:));
    Class dataMeta = object_getClass(NSMutableData.class);
    class_addMethod(dataMeta, @selector(dataWithLength:),
                    method_getImplementation(data),
                    method_getTypeEncoding(data));
    data =
        class_getClassMethod(NSMutableData.class, @selector(dataWithLength:));
    rip_data_original = (void *)method_getImplementation(data);
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
    BOOL savedTCG = tcg_allowed;
    method_setImplementation(builder, (IMP)rip_builder);
    method_setImplementation(data, (IMP)rip_data_factory);
    method_exchangeImplementations(originalCopy, replacementCopy);
    @try {
        rip_shapes();
        rip_lifetimes_and_guards();
        rip_allocation_failures();
        rip_budget();
    } @finally {
        rip_building = rip_fail = NO;
        rip_nil_data = rip_nil_copy = 0;
        tcg_allowed = savedTCG;
        method_exchangeImplementations(originalCopy, replacementCopy);
        method_setImplementation(data, (IMP)rip_data_original);
        method_setImplementation(builder, (IMP)rip_builder_original);
        rip_xf = nil;
    }
    printf("Readonly index plan:%lu exact forced-miss GPU/archive pairs; warm "
           "builder/hash/data/copy0,positive/negative plans,fresh "
           "guards,immutable/weak keys,cancel/close/OOM retry PASS\n",
           (unsigned long)rip_pairs);
    groups++;
}
#endif
