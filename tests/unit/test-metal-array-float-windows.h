/* Exact repeated DrawArrays windows with full Fetch/XF/Current and
 * original scanner-summary oracles.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ARRAY_FLOAT_WINDOWS_H
#define TEST_METAL_ARRAY_FLOAT_WINDOWS_H

@interface NV2AMetalPGRAPHFetch (ArrayFloatWindowsTest)
- (NSMutableData *)floatProofArrayWindowsForBatches:(NSArray *)batches
                                     maximumRecords:(NSUInteger)maximum
                                            records:(NSUInteger *)records;
@end
static _Thread_local BOOL afw_scope, afw_reference;
static _Thread_local NSUInteger afw_scans, afw_words, afw_guards;
static NSMutableData *(*afw_plan_original)(id, SEL, NSArray *, NSUInteger,
                                           NSUInteger *);
static NSMutableData *afw_plan(id owner, SEL selector, NSArray *batches,
                               NSUInteger maximum, NSUInteger *records)
{
    if (afw_scope && afw_reference)
        return nil; /* Only the new oversized-array path is disabled. */
    return afw_plan_original(owner, selector, batches, maximum, records);
}
static NSData *(*afw_scan_original)(id, SEL, const NV2AMetalAttributeSource *,
                                    const uint32_t *, NSUInteger, NSUInteger,
                                    uint64_t);
static NSData *afw_scan(id owner, SEL selector,
                        const NV2AMetalAttributeSource *sources,
                        const uint32_t *indices, NSUInteger first,
                        NSUInteger count, uint64_t lanes)
{
    if (afw_scope) {
        assert(!indices && lanes == 1);
        afw_scans++;
        /* Scan extent, not actual loads: a nonfinite word may stop a lane. */
        afw_words += count;
    }
    return afw_scan_original(owner, selector, sources, indices, first, count,
                             lanes);
}
static BOOL (*afw_guard_original)(id, SEL, const NV2AMetalVRAMReadSpan *,
                                  NSUInteger, BOOL *, NSError **);
static BOOL afw_guard(id owner, SEL selector,
                      const NV2AMetalVRAMReadSpan *spans, NSUInteger count,
                      BOOL *ready, NSError **error)
{
    if (afw_scope)
        afw_guards++;
    return afw_guard_original(owner, selector, spans, count, ready, error);
}
@interface ArrayFloatWindowsResult : NSObject
@property(nonatomic) NSArray<NSData *> *output;
@property(nonatomic) NSArray<NSArray *> *summaries;
@property(nonatomic) NSData *work;
@end
@implementation ArrayFloatWindowsResult
@end
typedef struct ArrayFloatWindowsWork {
    NSUInteger scans, words, guards, records;
} ArrayFloatWindowsWork;

/* Range values are actual DrawArrays first/count fields.
 * Profile2 deliberately overlaps distinct windows: unioning them is NOT
 * allowed by this change. Profile3/4 have valid source bounds at 4096/4097. */
static NSArray<NSValue *> *afw_windows(unsigned profile, BOOL oracle)
{
    NSMutableArray *ranges = [NSMutableArray new];
    NSUInteger count = profile == 3 || profile == 4 ? 17 : 16;
    if (oracle)
        count = profile == 3 ? 16 : 1;
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger first = profile == 2 ? i + 1 : 1;
        NSUInteger length = 384;
        if (profile == 3) {
            first = 1 + (i % 16) * 256;
            length = 256;
        } else if (profile == 4) {
            first = i == 16 ? 1 : i ? 258 + (i - 1) * 256 : 1;
            length = i == 0 || i == 16 ? 257 : 256;
        }
        [ranges addObject:[NSValue valueWithRange:NSMakeRange(first, length)]];
    }
    return ranges;
}
static uint32_t afw_bits(NSUInteger row, unsigned profile)
{
    if (!row || ((profile == 1 || profile == 5) && row == 5))
        return UINT32_C(0x7fc12345);
    if (row == 4096 || row == 4097)
        return row == 4096 ? UINT32_C(0x40000000) : UINT32_C(0x40400000);
    const uint32_t bits[] = { UINT32_C(0xbf800000), UINT32_C(0x80000000), 0,
                              UINT32_C(0x3f800000) };
    return bits[row % 4];
}
/* Raw GPU Fetch/XF/Current is compared for every actual execution. This uses
 * the unchanged generic XF shader and checks its oT0 against fetched v0;
 * metadata never substitutes for GPU records or fault verification. */
static NSData *afw_output(FloatProofCaptureFixture *f,
                          NV2AMetalVertexProgram *xf, NSArray *batches)
{
    NSError *error = nil;
    NSMutableArray *results = [NSMutableArray new];
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        uint32_t tokens[2][4] = { 0 };
        tokens[0][1] = 1 << 21 | 27;
        tokens[0][2] = 2u << 26;
        tokens[0][3] = 1 << 11 | 9 << 3 | 15 << 12;
        tokens[1][1] = 1 << 21 | 96 << 13 | 27;
        tokens[1][2] = 3u << 26;
        tokens[1][3] = 1 << 11 | 15 << 12 | 1;
        NV2AMetalProgramUniforms u = { 0 };
        u.constants[96][3] = 1;
        u.surface_size[0] = u.surface_size[1] = 8;
        u.zmax = 65535;
        u.point_size = u.point_scale = 1;
        NV2AMetalProgramUniforms before = u;
        NV2AMetalProgramResult *result =
            [xf encodeTokens:&tokens[0][0]
                      length:2
                    uniforms:&u
                  attributes:batch.fetch.attributes
                       count:batch.fetch.vertexCount
                    commands:f.fetch.encodingCommands
                       error:&error];
        require(result != nil, error);
        assert(!memcmp(&u, &before, sizeof(u)));
        [results addObject:result];
    }
    NSMutableData *output = [NSMutableData dataWithData:fpc_output(f, batches)];
    for (NSUInteger b = 0; b < batches.count; b++) {
        NV2AMetalPGRAPHFetchBatch *batch = batches[b];
        NV2AMetalProgramResult *result = results[b];
        const NV2AMetalProgramOutput *raw = result.registers.contents;
        const NV2AMetalProgramInput *input = batch.fetch.attributes.contents;
        assert(result.vertexCount == batch.physicalVertexCount);
        for (NSUInteger i = 0; i < result.vertexCount; i++) {
            assert(!raw[i].fault &&
                   !memcmp(raw[i].registers[9], input[i].attributes[0], 16));
            NSUInteger row = batch.firstVertex + batch.firstDecodedVertex + i;
            assert(!memcmp(input[i].attributes[0],
                           state->vram_ptr + 4096 + row * 4, 4));
            const uint32_t defaults[] = { 0, 0, UINT32_C(0x3f800000) };
            assert(!memcmp(input[i].attributes[0] + 1, defaults, 12));
        }
        [output appendBytes:result.registers.contents
                     length:result.vertexCount * sizeof(*raw)];
        [output appendBytes:result.vertices.contents
                     length:result.vertexCount * sizeof(NV2AMetalVertex)];
    }
    /* DrawArrays Current follows the maximum original source index;
     * equal maxima select the last batch. It is not the final list slot. */
    NSUInteger current = 0;
    for (NV2AMetalPGRAPHFetchBatch *batch in batches)
        current = MAX(current, batch.firstVertex + batch.inputVertexCount - 1);
    assert(!memcmp(state->pgraph.vertex_attributes[0].inline_value,
                   state->vram_ptr + 4096 + current * 4, 4));
    return output;
}
static ArrayFloatWindowsResult *afw_run(unsigned profile, BOOL reference,
                                        BOOL oracle)
{
    FloatProofCaptureFixture *f = fpc_fixture();
    NSError *error = nil;
    NV2AMetalVertexProgram *xf =
        [[NV2AMetalVertexProgram alloc] initWithDevice:f.queue.device
                                                 error:&error];
    require(xf != nil, error);
    state->pgraph.vertex_attributes[0] =
        (VertexAttribute){ .offset = 4096,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 1,
                           .stride = 4 };
    /* 4098 words at stride4 are entirely inside the existing 64KiB DMA. */
    require([f.cache prepareCPUAccessAtAddress:4096
                                        length:4098 * 4
                                         write:YES
                                         error:&error],
            error);
    for (NSUInteger row = 0; row < 4098; row++) {
        uint32_t bits = afw_bits(row, profile == 5 ? 0 : profile);
        memcpy(state->vram_ptr + 4096 + row * 4, &bits, 4);
    }
    NSArray<NSValue *> *windows = afw_windows(profile, oracle);
    NSMutableArray *prefixes = [NSMutableArray new];
    state->pgraph.draw_arrays_length = windows.count;
    for (NSUInteger i = 0; i < windows.count; i++) {
        NSRange window = windows[i].rangeValue;
        state->pgraph.draw_arrays_start[i] = window.location;
        state->pgraph.draw_arrays_count[i] = window.length;
        [prefixes addObject:@0];
    }
    id<MTLSharedEvent> gate = nil;
    if (profile == 5 && !oracle) {
        gate = [f.queue.device newSharedEvent];
        assert(gate);
        fpc_gate(f.queue, gate);
        require([f.cache prepareGPUWriteAtAddress:4096 + 5 * 4
                                           length:4
                                            error:&error],
                error);
        uint32_t bits = afw_bits(5, 5);
        id<MTLBuffer> source =
            [f.queue.device newBufferWithBytes:&bits
                                        length:4
                                       options:MTLResourceStorageModeShared];
        require(source && [f.queue addResource:source error:&error], error);
        id<MTL4ComputeCommandEncoder> encoder =
            [f.queue.commandBuffer computeCommandEncoder];
        assert(encoder);
        [encoder copyFromBuffer:source
                   sourceOffset:0
                       toBuffer:f.cache.vram
              destinationOffset:4096 + 5 * 4
                           size:4];
        [encoder endEncoding];
        require([f.cache submitWithError:&error], error);
    } else if (profile == 5) {
        uint32_t bits = afw_bits(5, 5);
        memcpy(state->vram_ptr + 4096 + 5 * 4, &bits, 4);
    }
    NSMutableArray *outputs = [NSMutableArray new],
                   *summaries = [NSMutableArray new];
    NSMutableData *work = [NSMutableData new];
    unsigned passes = profile == 5 && !oracle ? 2 : 1;
    for (unsigned pass = 0; pass < passes; pass++) {
        afw_scans = afw_words = afw_guards = 0;
        afw_reference = reference;
        afw_scope = YES;
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches;
        @try {
            batches = fpc_encode(f, nil, prefixes, NO, NO, 1, NO);
        } @finally {
            afw_scope = NO;
        }
        ArrayFloatWindowsWork w = { afw_scans, afw_words, afw_guards, 0 };
        NSMutableArray *batchSummaries = [NSMutableArray new];
        for (NSUInteger i = 0; i < batches.count; i++) {
            NV2AMetalPGRAPHFetchBatch *batch = batches[i];
            NSRange window = windows[i].rangeValue;
            NSData *summary = nil;
            uint64_t lanes = 0;
            BOOL found =
                [batch.fetch getFloatProofSummaries:&summary
                                           laneMask:&lanes
                                    attributeBuffer:batch.fetch.attributes
                                              first:0
                                              count:batch.physicalVertexCount
                                           commands:f.fetch.encodingCommands];
            assert(found == (summary != nil));
            if (found)
                assert(lanes == 1 && summary.length == 1024);
            [batchSummaries addObject:summary ?: (id)NSNull.null];
            assert(batch.firstVertex == window.location &&
                   !batch.firstDecodedVertex && !batch.indexed &&
                   !batch.remap && batch.inputVertexCount == window.length &&
                   batch.physicalVertexCount == window.length);
            w.records += batch.physicalVertexCount;
        }
        if (gate && pass == 0) {
            assert(!gate.signaledValue);
            gate.signaledValue = 1;
        }
        [outputs addObject:afw_output(f, xf, batches)];
        [summaries addObject:batchSummaries];
        [work appendBytes:&w length:sizeof(w)];
    }
    ArrayFloatWindowsResult *result = [ArrayFloatWindowsResult new];
    result.output = outputs;
    result.summaries = summaries;
    result.work = work;
    [f.fetch close];
    afw_reference = NO;
    return result;
}
static void array_float_windows_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(
                floatProofArrayWindowsForBatches:maximumRecords:records:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(scanFloatProofSources:indices:first:count:lanes:)),
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            @selector(tryIdleCPUReadSpans:count:completed:error:)),
    };
    IMP replacements[] = { (IMP)afw_plan, (IMP)afw_scan, (IMP)afw_guard };
    IMP originals[3];
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    afw_plan_original = (void *)originals[0];
    afw_scan_original = (void *)originals[1];
    afw_guard_original = (void *)originals[2];
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned profile = 0; profile < 6; profile++) {
            @autoreleasepool {
                ArrayFloatWindowsResult *old = afw_run(profile, YES, NO);
                ArrayFloatWindowsResult *actual = afw_run(profile, NO, NO);
                /* All logical GPU Fetch/XF/fault/Current bytes first. */
                assert([old.output isEqualToArray:actual.output]);
                BOOL eligible = profile != 2 && profile != 4;
                ArrayFloatWindowsResult *oracle =
                    eligible ? afw_run(profile, YES, YES) : nil;
                const ArrayFloatWindowsWork *a = actual.work.bytes,
                                            *b = old.work.bytes;
                for (NSUInteger pass = 0; pass < actual.output.count; pass++) {
                    BOOL present = eligible && !(profile == 5 && !pass);
                    for (NSUInteger i = 0; i < actual.summaries[pass].count;
                         i++) {
                        id summary = actual.summaries[pass][i];
                        assert((summary != NSNull.null) == present);
                        assert(old.summaries[pass][i] == NSNull.null);
                        if (present) {
                            NSData *expected =
                                oracle.summaries[0][profile == 3 ? i % 16 : 0];
                            assert([summary isEqualToData:expected]);
                            const NV2AMetalFloatLaneSummary *lanes =
                                [summary bytes];
                            assert(lanes[0].flags ==
                                   ((profile == 1 || profile == 5) ?
                                        0 :
                                        NV2AMetalFloatLaneSummaryFinite));
                        }
                    }
                    /* Work follows whole output and exact old per-window
                     * summary. */
                    NSUInteger scans = present ? (profile == 3 ? 16 : 1) : 0;
                    NSUInteger words =
                        present ? (profile == 3 ? 4096 : 384) : 0;
                    assert(!b[pass].scans && !b[pass].words &&
                           a[pass].scans == scans && a[pass].words == words &&
                           a[pass].records == b[pass].records &&
                           a[pass].records > 4096);
                    assert(a[pass].words <= 4096);
                    if (eligible)
                        assert(a[pass].guards);
                }
            }
        }
    } @finally {
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
        afw_scope = afw_reference = NO;
    }
    puts("Array Float windows: six full-output/reference groups; exact-window "
         "summaries, "
         "4096/4097 boundary, unequal overlap, selected NaN and busy/repair "
         "PASS");
    groups++;
}
#endif
