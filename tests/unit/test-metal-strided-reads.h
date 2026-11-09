/* Exact strided VRAM read ownership, independent of vertex decoding.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_STRIDED_READS_H
#define TEST_METAL_STRIDED_READS_H
#import <objc/runtime.h>

static BOOL (*strided_original_dirty)(id, SEL);
static unsigned strided_dirty_checks;
static void (*strided_original_page_reader)(id, SEL, NSUInteger, NSUInteger);
static unsigned strided_page_registrations;
static NSRange strided_registered_range;
static void (*strided_original_add_indexes)(id, SEL, NSRange);
static _Thread_local unsigned strided_index_runs;
static void (*strided_original_append_bytes)(id, SEL, const void *, NSUInteger);
static _Thread_local unsigned strided_pattern_appends;
static NSData *(*strided_original_spans)(id, SEL);
static unsigned strided_span_checks;
static BOOL strided_observe_dirty(id object, SEL selector)
{
    strided_dirty_checks++;
    return strided_original_dirty(object, selector);
}
static void strided_observe_page_reader(id object, SEL selector,
                                         NSUInteger address, NSUInteger length)
{
    strided_page_registrations++;
    strided_registered_range = NSMakeRange(address, length);
    strided_original_page_reader(object, selector, address, length);
}
static void strided_observe_add_indexes(id object, SEL selector, NSRange range)
{
    strided_index_runs++;
    strided_original_add_indexes(object, selector, range);
}
static void strided_observe_append_bytes(id object, SEL selector,
                                         const void *bytes, NSUInteger length)
{
    if (length == sizeof(NV2AMetalVRAMReadPattern))
        strided_pattern_appends++;
    strided_original_append_bytes(object, selector, bytes, length);
}
static NSData *strided_observe_spans(id object, SEL selector)
{
    strided_span_checks++;
    return strided_original_spans(object, selector);
}

static BOOL strided_oracle(NV2AMetalVRAMReadPattern p, NSUInteger address,
                           NSUInteger length)
{
    for (NSUInteger byte = address; byte < address + length; byte++)
        for (NSUInteger cell = p.address; cell < p.address + p.length;
             cell += p.stride)
            if (byte >= cell && byte - cell < p.element)
                return YES;
    return NO;
}

static void strided_ready(NV2AMetalSurfaceCache *cache, NSUInteger address,
                          NSUInteger length, BOOL expected)
{
    NSError *error = nil;
    BOOL ready = !expected;
    require([cache tryIdleCPUAccessAtAddress:address
                                      length:length
                                       write:YES
                                   completed:&ready
                                       error:&error],
            error);
    assert(ready == expected);
}

static void strided_read_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalCommands *producer =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> vram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(commands && producer && vram && cache, error);
    unsigned cases = 0, probes = 0;
    for (unsigned independent = 0; independent < 2; independent++)
        for (NSUInteger stride = 1; stride <= 12; stride++)
            for (NSUInteger element = 1; element <= stride; element++) {
                NV2AMetalVRAMReadPattern p = { 4093,
                                               (element % 5) * stride + element,
                                               stride, element };
                NV2AMetalIndependentReads *reader = nil;
                if (independent) {
                    require([cache tryBeginIndependentReadPatterns:&p
                                                             count:1
                                                          commands:producer
                                                             reads:&reader
                                                             error:&error],
                            error);
                    assert(reader);
                } else
                    require([cache prepareGPUReadPattern:p error:&error],
                            error);
                /* Compare every byte and crossings against a deliberately
                 * enumerating oracle, including half-open and zero lengths. */
                for (NSUInteger address = p.address - 2;
                     address <= p.address + p.length + 2; address++)
                    for (NSUInteger length = 0; length <= 4; length++) {
                        strided_ready(cache, address, length,
                                      !strided_oracle(p, address, length));
                        probes++;
                    }
                if (independent)
                    [cache cancelIndependentReads:reader];
                else
                    [cache cancel];
                strided_ready(cache, p.address, p.length, YES);
                assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard,
                                                 p.address, p.length, YES));
                cases++;
            }

    /* 16,384 cells use one record, not a per-vertex interval list. */
    NV2AMetalVRAMReadPattern large = { 0, 65533, 4, 1 };
    for (unsigned independent = 0; independent < 2; independent++) {
        NV2AMetalIndependentReads *reader = nil;
        if (independent) {
            require([cache tryBeginIndependentReadPatterns:&large
                                                     count:1
                                                  commands:producer
                                                     reads:&reader
                                                     error:&error],
                    error);
            assert(reader &&
                   [[reader valueForKey:@"spans"] length] == sizeof(large));
        } else {
            require([cache prepareGPUReadPattern:large error:&error], error);
            assert([[cache valueForKey:@"pendingReads"] length] ==
                   sizeof(large));
        }
        strided_ready(cache, 65532, 1, NO);
        strided_ready(cache, 65533, 3, YES);
        strided_ready(cache, 4093, 3, YES);
        strided_ready(cache, 4095, 2, NO);
        if (independent)
            [cache cancelIndependentReads:reader];
        else
            [cache cancel];
        assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, 65536, YES));
        cases++;
    }

    NV2AMetalVRAMReadPattern p = { 4093, 5 * 64 + 3, 64, 3 };
    /* A pending writer in padding must not prevent a separate producer.
     * Crossing either end of a payload must still request the ordered queue. */
    for (NSUInteger address = p.address - 1; address < p.address + p.length + 1;
         address++) {
        require([cache prepareGPUWriteAtAddress:address length:2 error:&error],
                error);
        NV2AMetalIndependentReads *reader = nil;
        require([cache tryBeginIndependentReadPatterns:&p
                                                 count:1
                                              commands:producer
                                                 reads:&reader
                                                 error:&error],
                error);
        assert((reader != nil) == !strided_oracle(p, address, 2));
        if (reader)
            [cache cancelIndependentReads:reader];
        [cache cancel];
        cases++;
    }

    /* Accepted read ownership survives cancellation of a later suffix. */
    require([cache prepareGPUReadPattern:p error:&error] &&
                [cache checkpointWithError:&error],
            error);
    NV2AMetalVRAMReadPattern suffix = { 8192, 33, 32, 1 };
    require([cache prepareGPUReadPattern:suffix error:&error], error);
    [cache cancel];
    strided_ready(cache, p.address, 1, NO);
    strided_ready(cache, p.address + p.element, p.stride - p.element, YES);
    strided_ready(cache, suffix.address, suffix.length, YES);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    strided_ready(cache, p.address, p.length, YES);
    for (unsigned cancel = 0; cancel < 2; cancel++) {
        NV2AMetalIndependentReads *reader = nil;
        require([cache tryBeginIndependentReadPatterns:&p
                                                 count:1
                                              commands:producer
                                                 reads:&reader
                                                 error:&error],
                error);
        require(reader && [cache submitIndependentReads:reader error:&error],
                error);
        if (cancel)
            [cache cancelIndependentReads:reader];
        strided_ready(cache, p.address, 1, NO);
        strided_ready(cache, p.address + p.element, p.stride - p.element, YES);
        require([cache completeIndependentReads:reader error:&error], error);
        strided_ready(cache, p.address, p.length, YES);
    }

    NV2AMetalVRAMReadPattern invalid[] = { { 0, 1, 0, 1 },
                                           { 0, 1, 4, 0 },
                                           { 0, 1, 4, 2 },
                                           { 0, 4, 2, 3 },
                                           { 0, 8, 4, 1 },
                                           { 65535, 2, 1, 1 },
                                           { NSUIntegerMax, 2, 1, 1 },
                                           { 65536, 0, 1, 1 } };
    for (NSUInteger i = 0; i < sizeof(invalid) / sizeof(*invalid); i++) {
        error = nil;
        assert(![cache prepareGPUReadPattern:invalid[i] error:&error] && error);
        error = nil;
        NV2AMetalIndependentReads *reader = nil;
        assert(![cache tryBeginIndependentReadPatterns:&invalid[i]
                                                 count:1
                                              commands:producer
                                                 reads:&reader
                                                 error:&error] &&
               error && !reader);
        assert(!commands.commandBuffer && !producer.commandBuffer);
    }
    error = nil;
    /* Exact end of VRAM and a one-cell strided range are legal. */
    NV2AMetalVRAMReadPattern end = { 65535, 1, 64, 1 };
    require([cache prepareGPUReadPattern:end error:&error], error);
    strided_ready(cache, 65535, 1, NO);
    [cache cancel];
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 65535, 1, YES));
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:60000
                                                              config:&c frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error], error);
    assert(surface.dirty && cache.count == 1);
    NV2AMetalVRAMReadPattern batch[257];
    for (NSUInteger i = 0; i < 256; i++)
        batch[i + (i >= 128)] =
            (NV2AMetalVRAMReadPattern){ 4096 + (255 - i) * 64, 10, 8, 2 };
    batch[128] = (NV2AMetalVRAMReadPattern){ 65536, 0, 0, 0 };
    Method dirty = class_getInstanceMethod(NV2AMetalCachedSurface.class,
                                            @selector(dirty));
    Method add = class_getInstanceMethod(NV2AMetalSurfaceCache.class,
        sel_registerName("addGPUReaderAtAddress:length:"));
    Method addIndexes = class_getInstanceMethod(
        object_getClass([NSMutableIndexSet new]), @selector(addIndexesInRange:));
    Method appendBytes = class_getInstanceMethod(
        object_getClass([NSMutableData new]), @selector(appendBytes:length:));
    assert(addIndexes && appendBytes);
    strided_original_add_indexes = (void *)method_setImplementation(
        addIndexes, (IMP)strided_observe_add_indexes);
    strided_original_append_bytes = (void *)method_setImplementation(
        appendBytes, (IMP)strided_observe_append_bytes);
    strided_original_dirty = (void *)method_setImplementation(
        dirty, (IMP)strided_observe_dirty);
    strided_original_page_reader = (void *)method_setImplementation(
        add, (IMP)strided_observe_page_reader);
    const NSUInteger writers[] = { 4094, 4098, 4103, 4160, 21000 };
    const BOOL conflicts[] = { NO, NO, YES, YES, NO };
    for (unsigned i = 0; i < sizeof(writers) / sizeof(*writers); i++) {
        require([cache prepareGPUWriteAtAddress:writers[i] length:2 error:&error],
                error);
        NV2AMetalIndependentReads *reader = nil;
        strided_dirty_checks = strided_page_registrations = strided_index_runs = 0;
        strided_pattern_appends = 0;
        require([cache tryBeginIndependentReadPatterns:batch
                                                 count:257
                                              commands:producer
                                                 reads:&reader
                                                 error:&error], error);
        assert((reader != nil) == !conflicts[i]);
        assert(strided_dirty_checks == (conflicts[i] ? 0u : 1u));
        assert(strided_page_registrations == (conflicts[i] ? 0u : 1u));
        assert(strided_index_runs == (conflicts[i] ? 0u : 1u));
        if (reader) {
            NSData *snapshot = [reader valueForKey:@"spans"];
            assert(snapshot.length == 256 * sizeof(*batch) &&
                   !strided_pattern_appends);
            NV2AMetalVRAMReadPattern saved = batch[0];
            batch[0] = (NV2AMetalVRAMReadPattern){ 0, 0, 0, 0 };
            assert(!memcmp(snapshot.bytes, &saved, sizeof(saved)));
            batch[0] = saved;
            assert(!memcmp(snapshot.bytes, batch, 128 * sizeof(*batch)) &&
                   !memcmp((const NV2AMetalVRAMReadPattern *)snapshot.bytes + 128,
                           batch + 129, 128 * sizeof(*batch)));
            [cache cancelIndependentReads:reader];
        }
        [cache cancel];
    }
    method_setImplementation(appendBytes, (IMP)strided_original_append_bytes);
    method_setImplementation(dirty, (IMP)strided_original_dirty);
    strided_page_registrations = strided_index_runs = 0;
    require([cache prepareGPUReadPatterns:batch count:257 error:&error] &&
                [cache prepareGPUReadPatterns:batch count:257 error:&error],
            error);
    NSData *records = [cache valueForKey:@"pendingReads"];
    assert(surface.dirty && records.length == 512 * sizeof(*batch) &&
           strided_page_registrations == 1 && strided_index_runs == 1);
    const NV2AMetalVRAMReadPattern *retained = records.bytes;
    for (unsigned i = 0; i < 512; i++) {
        unsigned index = i % 256;
        assert(!memcmp(&retained[i], &batch[index + (index >= 128)],
                       sizeof(*batch)));
    }
    method_setImplementation(addIndexes, (IMP)strided_original_add_indexes);
    require([cache prepareGPUReadAtAddress:20476 length:8 error:&error], error);
    assert(strided_page_registrations == 2 &&
           NSEqualRanges(strided_registered_range, NSMakeRange(20480, 4096)));
    method_setImplementation(add, (IMP)strided_original_page_reader);
    [cache cancel];
    require([cache flushWithError:&error], error);
    puts("Batched strided VRAM checks: 256 exact lanes, one disjoint dirty "
         "surface probe, padding writes and true conflicts PASS");
    puts("VRAM page run setup: one index-set insertion for 256 reversed "
         "patterns on either queue; exact byte records keep their order PASS");
    puts("Independent VRAM snapshot: 256 owned records with an empty input "
         "slot, zero per-pattern appends and no alias to caller storage PASS");
    NV2AMetalCommands *other =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(other != nil, error);
    NV2AMetalVRAMReadPattern disjoint[] = {
        { 24576, 2, 0, 0 }, { 24580, 2, 0, 0 }, { 32768, 1, 0, 0 },
    };
    NV2AMetalIndependentReads *first = nil, *second = nil;
    require([cache tryBeginIndependentReadPatterns:disjoint count:3
                                          commands:producer reads:&first
                                             error:&error] && first, error);
    require([cache tryBeginIndependentReadPatterns:disjoint count:3
                                          commands:other reads:&second
                                             error:&error] && second, error);
    NV2AMetalVRAMReadPattern original = disjoint[0];
    disjoint[0].address = 0;
    for (NV2AMetalIndependentReads *reader in @[ first, second ]) {
        NSData *snapshot = [reader valueForKey:@"spans"];
        assert(snapshot.length == sizeof(disjoint) &&
               !memcmp(snapshot.bytes, &original, sizeof(original)));
    }
    NV2AMetalCPUAccessGuard *guard = cache.cpuAccessGuard;
    assert(!nv2a_metal_try_cpu_access(guard, 24582, 1, YES) &&
           nv2a_metal_try_cpu_access(guard, 28672, 1, YES));
    SEL spanSelector = sel_registerName("spans");
    Method spans = class_getInstanceMethod(NV2AMetalIndependentReads.class,
                                            spanSelector);
    assert(spans);
    strided_original_spans = (void *)method_setImplementation(
        spans, (IMP)strided_observe_spans);
    strided_span_checks = 0;
    strided_ready(cache, 28672, 16, YES);
    require([cache resolveCPUAccessAtAddress:28672 length:16
                                       write:YES error:&error], error);
    assert(strided_span_checks == 0);
    /* The byte just past the reader bounds still shares its watched page. */
    assert(!nv2a_metal_try_cpu_access(guard, 32769, 1, YES));
    strided_ready(cache, 32769, 1, YES);
    require([cache resolveCPUAccessAtAddress:32769 length:1
                                       write:YES error:&error] &&
                [cache orderAfterIndependentReadsAtAddress:32769
                                                    length:1 error:&error],
            error);
    assert(strided_span_checks == 0);
    strided_ready(cache, 24582, 1, YES);
    assert(strided_span_checks == 2);
    strided_ready(cache, 32767, 2, NO);
    assert(strided_span_checks == 3);
    method_setImplementation(spans, (IMP)strided_original_spans);
    puts("CPU VRAM reader precheck: disjoint report-sized writes skip span "
         "scans; same-page padding and crossing conflicts stay exact PASS");
    puts("Independent VRAM reader bounds: same-page writes past the last "
         "byte skip exact span scans on CPU and GPU PASS");
    [cache cancelIndependentReads:first];
    assert(!nv2a_metal_try_cpu_access(guard, 24582, 1, YES));
    require([cache submitIndependentReads:second error:&error] &&
                [cache completeIndependentReads:second error:&error], error);
    assert(nv2a_metal_try_cpu_access(guard, 24582, 1, YES) &&
           nv2a_metal_try_cpu_access(guard, 32768, 1, YES));
    puts("Independent VRAM reader pages: one run for 256 patterns, "
         "disjoint pages and overlapping cancel/completion ownership PASS");
    const NSUInteger address = 45056;
    require([cache prepareGPUReadAtAddress:address length:4 error:&error] &&
                [cache checkpointWithError:&error], error);
    require([cache prepareGPUReadAtAddress:address + 8 length:4 error:&error],
            error);
    [cache cancel];
    assert(!nv2a_metal_try_cpu_access(guard, address, 1, YES));
    strided_ready(cache, address, 1, NO);
    strided_ready(cache, address + 8, 1, YES);
    require([cache submitWithError:&error], error);
    NV2AMetalSubmission *submitted = commands.lastSubmitted;
    require([cache prepareGPUReadAtAddress:address + 8 length:4 error:&error] &&
                [cache waitForSubmission:submitted error:&error], error);
    assert(!nv2a_metal_try_cpu_access(guard, address, 1, YES));
    strided_ready(cache, address, 1, YES);
    strided_ready(cache, address + 8, 1, NO);
    [cache cancel];
    assert(nv2a_metal_try_cpu_access(guard, address, 1, YES));
    require([cache prepareGPUReadAtAddress:address length:4 error:&error] &&
                [cache checkpointWithError:&error] &&
                [cache discardForRestoreWithError:&error], error);
    assert(nv2a_metal_try_cpu_access(guard, address, 1, YES));
    puts("Surface VRAM reader pages: 512 exact patterns share one run, "
         "partial page extension, sealed prefix, cancellation, completion "
         "and restore release PASS");
    printf("Strided read ownership:%u patterns/writers,%u exact byte probes;"
           "checkpoint/cancel/submit/retirement,range rejection PASS\n",
           cases, probes);
    checks++;
}
#endif
