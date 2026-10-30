/* Native PGRAPH attribute/batch capture from gl/vertex.c and gl/draw.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "fetch-pgraph.h"
#import "pending-journal.h"
#include "vertex-normalize.h"

/* Only Current is host-visible state. Vertex decoding and XF still consume
 * the immutable upload on the GPU. Keep D3D Current unswizzled and clamp CMP
 * endpoints, as the existing GPU Current record does. */
static void inline_current_value(const uint8_t *source, unsigned format,
                                 unsigned count, float value[4])
{
    uint32_t bits[4] = { 0, 0, 0, 0x3f800000 };
    if (format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F) {
        memcpy(bits, source, count * 4);
    } else if (format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP) {
        uint32_t packed = (uint32_t)source[0] | (uint32_t)source[1] << 8 |
                          (uint32_t)source[2] << 16 | (uint32_t)source[3] << 24;
        const int signedValues[3] = {
            (int)(packed & 0x7ff) - (int)((packed & 0x400) << 1),
            (int)((packed >> 11) & 0x7ff) - (int)((packed & 0x200000) >> 10),
            (int)(packed >> 22) - (int)((packed & 0x80000000) >> 21)
        };
        for (unsigned k = 0; k < 3; k++) {
            float lane =
                MAX(-1.0f, signedValues[k] / (k == 2 ? 511.0f : 1023.0f));
            memcpy(bits + k, &lane, 4);
        }
    } else {
        for (unsigned k = 0; k < count; k++) {
            if (format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D ||
                format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL) {
                bits[k] = nv2a_metal_ubyte_bits(source[k]);
            } else {
                int16_t raw = (int16_t)((uint16_t)source[2 * k] |
                                        (uint16_t)source[2 * k + 1] << 8);
                if (format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1) {
                    bits[k] = nv2a_metal_nshort_bits(raw);
                } else {
                    float lane = raw;
                    memcpy(bits + k, &lane, 4);
                }
            }
        }
    }
    memcpy(value, bits, sizeof(bits));
}

static BOOL fetch_pgraph_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pgraph-fetch"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
static BOOL dma_attribute_source(NV2AState *d, const VertexAttribute *a,
                                 id<MTLBuffer> vram,
                                 NV2AMetalAttributeSource *source,
                                 NSError **error)
{
    NSUInteger size = vram.length;
    DMAObject dma = nv_dma_load(d, a->dma_select ? d->pgraph.dma_vertex_b :
                                                   d->pgraph.dma_vertex_a);
    NSUInteger base = dma.address & 0x07ffffff;
    if (dma.dma_class != NV_DMA_IN_MEMORY_CLASS || a->offset > dma.limit ||
        base >= size || a->offset >= size - base) {
        return fetch_pgraph_error(error,
                                  @"Invalid NV2A vertex DMA class/offset");
    }
    source->buffer = vram;
    source->offset = base + a->offset;
    source->byteLength =
        MIN(dma.limit - a->offset, size - source->offset - 1) + 1;
    source->format = a->format;
    source->count = a->count;
    source->stride = a->stride;
    return YES;
}
static BOOL fetch_pgraph_prefix(NSArray<NSNumber *> *prefixes, NSUInteger batch,
                                NSUInteger count, NSUInteger *prefix,
                                NSError **error)
{
    *prefix = 0;
    if (!prefixes)
        return YES;
    id value = prefixes[batch];
    if (![value isKindOfClass:NSNumber.class] ||
        [value unsignedIntegerValue] > count ||
        [value doubleValue] != (double)[value unsignedIntegerValue])
        return fetch_pgraph_error(error, @"Invalid accepted fetch prefix");
    *prefix = [value unsignedIntegerValue];
    return YES;
}
static int fetch_index_order(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}
static NSMutableData *fetch_index_ranges(const uint32_t *indices,
                                         NSUInteger count)
{
    NSMutableData *ranges = [NSMutableData new];
    if (!count)
        return ranges;
    NSMutableData *ordered = nil;
    for (NSUInteger i = 1; i < count; i++) {
        if (indices[i] < indices[i - 1]) {
            ordered = [NSMutableData dataWithBytes:indices length:count * 4];
            qsort(ordered.mutableBytes, count, 4, fetch_index_order);
            indices = ordered.bytes;
            break;
        }
    }
    NSRange range = NSMakeRange(indices[0], 1);
    for (NSUInteger i = 1; i < count; i++) {
        if ((NSUInteger)indices[i] > NSMaxRange(range)) {
            [ranges appendBytes:&range length:sizeof(range)];
            range = NSMakeRange(indices[i], 1);
        } else if ((NSUInteger)indices[i] == NSMaxRange(range)) {
            range.length++;
        }
    }
    [ranges appendBytes:&range length:sizeof(range)];
    return ranges;
}
static int fetch_range_order(const void *a, const void *b)
{
    NSUInteger x = ((const NSRange *)a)->location,
               y = ((const NSRange *)b)->location;
    return (x > y) - (x < y);
}
static void fetch_merge_ranges(NSMutableData *data)
{
    NSUInteger count = data.length / sizeof(NSRange);
    if (count < 2)
        return;
    NSRange *ranges = data.mutableBytes;
    qsort(ranges, count, sizeof(*ranges), fetch_range_order);
    NSUInteger retained = 1;
    for (NSUInteger i = 1; i < count; i++) {
        NSRange *last = &ranges[retained - 1];
        if (ranges[i].location <= NSMaxRange(*last)) {
            last->length =
                MAX(NSMaxRange(*last), NSMaxRange(ranges[i])) - last->location;
        } else {
            ranges[retained++] = ranges[i];
        }
    }
    data.length = retained * sizeof(*ranges);
}
@interface NV2AMetalPGRAPHFetchBatch ()
- (instancetype)initWithFetch:(NV2AMetalFetchResult *)fetch
                        first:(unsigned)first
                      indexed:(BOOL)indexed
                        input:(NSUInteger)input
                       prefix:(NSUInteger)prefix;
@end
@implementation NV2AMetalPGRAPHFetchBatch
- (instancetype)initWithFetch:(NV2AMetalFetchResult *)fetch
                        first:(unsigned)first
                      indexed:(BOOL)indexed
                        input:(NSUInteger)input
                       prefix:(NSUInteger)prefix
{
    self = [super init];
    if (self) {
        _fetch = fetch;
        _firstVertex = first;
        _indexed = indexed;
        _inputVertexCount = input;
        _firstDecodedVertex = prefix;
    }
    return self;
}
@end
@implementation NV2AMetalPGRAPHFetch {
    NV2AState *_d;
    NV2AMetalVertexFetch *_fetch;
    BOOL _closed;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *_encodedBatches;
    NV2AMetalFetchResult *_last;
    NSData *_capturedCurrent;
    NV2AMetalSubmission *_submission;
    NV2AMetalCommands *_independentCommands, *_encodingCommands;
    NV2AMetalIndependentReads *_independentReads;
    uint16_t _update, _populated;
}
+ (BOOL)canCaptureInlineCurrentForState:(NV2AState *)d
{
    if (!d)
        return NO;
    const PGRAPHState *pg = &d->pgraph;
    if (pg->draw_arrays_length || pg->inline_elements_length)
        return NO;
    if (pg->inline_buffer_length)
        return !pg->inline_array_length;
    if (!pg->inline_array_length ||
        pg->inline_array_length > NV2A_MAX_BATCH_LENGTH)
        return NO;
    NSUInteger stride = 0;
    for (unsigned i = 0; i < 16; i++) {
        const VertexAttribute *a = &pg->vertex_attributes[i];
        if (!a->count)
            continue;
        unsigned element = nv2a_metal_attribute_size(a->format, a->count);
        if (!element || !a->size || a->size * a->count != element ||
            (a->size & (a->size - 1)))
            return NO;
        stride = (stride + a->size - 1) & ~(NSUInteger)(a->size - 1);
        stride += element;
        stride = (stride + a->size - 1) & ~(NSUInteger)(a->size - 1);
    }
    return stride && (NSUInteger)pg->inline_array_length * 4 >= stride;
}
- (BOOL)canCaptureCurrentForInput:(NV2AMetalPendingInput *)input
{
    if (_closed || _encodedBatches)
        return NO;
    PGRAPHState *pg = &_d->pgraph;
    if (pg->inline_buffer_length || pg->inline_array_length)
        return !input &&
               [NV2AMetalPGRAPHFetch canCaptureInlineCurrentForState:_d];
    uint32_t current = 0;
    if (pg->draw_arrays_length) {
        if (input || pg->inline_elements_length ||
            pg->draw_arrays_length > ARRAY_SIZE(pg->draw_arrays_start))
            return NO;
        for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
            int32_t first = pg->draw_arrays_start[i],
                    count = pg->draw_arrays_count[i];
            if (first < 0 || count <= 0 ||
                (uint64_t)first + count - 1 > UINT32_MAX)
                return NO;
            current = MAX(current, (uint32_t)((uint64_t)first + count - 1));
        }
    } else if (pg->inline_elements_length &&
               pg->inline_elements_length <= NV2A_MAX_BATCH_LENGTH) {
        if (input && (![input isKindOfClass:NV2AMetalPendingInput.class] ||
                      input.kind != NV2AMetalInputIndexed ||
                      input.count != pg->inline_elements_length ||
                      input.indices.length != input.count * 4))
            return NO;
        memcpy(&current,
               input ? (const uint8_t *)input.indices.bytes +
                           input.indices.length - 4 :
                       (const uint8_t *)(pg->inline_elements +
                                         pg->inline_elements_length - 1),
               4);
    } else {
        return NO;
    }
    NV2AMetalCPUAccessGuard *guard = _surfaces.cpuAccessGuard;
    BOOL checked = NO;
    for (unsigned i = 0; i < 16; i++) {
        VertexAttribute *a = &pg->vertex_attributes[i];
        if (!a->count)
            continue;
        NV2AMetalAttributeSource source = { 0 };
        unsigned element = nv2a_metal_attribute_size(a->format, a->count);
        if (!element ||
            !dma_attribute_source(_d, a, _surfaces.vram, &source, NULL))
            return NO;
        uint64_t offset = (uint64_t)current * source.stride;
        if (offset > source.byteLength || element > source.byteLength - offset)
            return NO;
        /* The first query retains cache health/recording validation. Only
         * the PGRAPH owner can register GPU work during this method; later
         * unwatched source reads use the same atomic guard as CPU hooks. */
        if (checked &&
            nv2a_metal_untracked_cpu_access(
                guard, source.offset + (NSUInteger)offset, element, NO))
            continue;
        BOOL ready = NO;
        if (![_surfaces
                tryIdleCPUAccessAtAddress:source.offset + (NSUInteger)offset
                                   length:element
                                    write:NO
                                completed:&ready
                                    error:NULL] ||
            !ready)
            return NO;
        checked = YES;
    }
    return YES;
}
- (instancetype)initWithState:(NV2AState *)d
                     surfaces:(NV2AMetalSurfaceCache *)surfaces
                        error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!d || !d->vram || surfaces.vram.contents != d->vram_ptr ||
        surfaces.vram.length != memory_region_size(d->vram)) {
        fetch_pgraph_error(error,
                           @"Vertex fetch requires live NV2A shared VRAM");
        return nil;
    }
    _d = d;
    _surfaces = surfaces;
    _fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:surfaces.commands.device
                                               error:error];
    return _fetch ? self : nil;
}
- (void)cancel
{
    NV2AMetalCommands *commands = _encodingCommands;
    if (_independentReads)
        [_surfaces cancelIndependentReads:_independentReads];
    _independentReads = nil;
    _encodedBatches = nil;
    _last = nil;
    _capturedCurrent = nil;
    _submission = nil;
    _encodingCommands = nil;
    if (commands && commands != _surfaces.commands)
        [commands cancel];
    else
        [_surfaces cancel];
}
- (void)close
{
    if (_encodedBatches)
        [self cancel];
    _closed = YES;
}
- (BOOL)prepareRange:(NSUInteger)address
              length:(NSUInteger)length
       deferredReads:(NSMutableData *)deferredReads
               error:(NSError **)error
{
    return
        [self preparePattern:(NV2AMetalVRAMReadPattern){ address, length, 0, 0 }
               deferredReads:deferredReads
                       error:error];
}
- (BOOL)preparePattern:(NV2AMetalVRAMReadPattern)pattern
         deferredReads:(NSMutableData *)deferredReads
                 error:(NSError **)error
{
    NSUInteger address = pattern.address, length = pattern.length;
    if (!length)
        return YES;
    NSUInteger size = _surfaces.vram.length;
    if (address > size || length > size - address)
        return fetch_pgraph_error(error, @"Vertex read exceeds VRAM");
    NSUInteger begin = address & TARGET_PAGE_MASK, end = address + length;
    NSUInteger padding =
        (TARGET_PAGE_SIZE - end % TARGET_PAGE_SIZE) % TARGET_PAGE_SIZE;
    end += MIN(padding, size - end);
    if (memory_region_test_and_clear_dirty(_d->vram, begin, end - begin,
                                           DIRTY_MEMORY_NV2A) &&
        !tcg_enabled()) {
        if (![_surfaces observeCPUWriteAtAddress:begin
                                          length:end - begin
                                           error:error]) {
            memory_region_set_client_dirty(_d->vram, begin, end - begin,
                                           DIRTY_MEMORY_NV2A);
            return NO;
        }
    }
    if (deferredReads) {
        [deferredReads appendBytes:&pattern length:sizeof(pattern)];
        return YES;
    }
    return [_surfaces prepareGPUReadPattern:pattern error:error];
}
- (BOOL)mapAttribute:(VertexAttribute *)a
              source:(NV2AMetalAttributeSource *)source
                 max:(uint32_t)maximum
               reads:(NSData *)reads
             current:(uint32_t)current
       deferredReads:(NSMutableData *)deferredReads
               error:(NSError **)error
{
    if (!dma_attribute_source(_d, a, _surfaces.vram, source, error))
        return NO;
    unsigned element = nv2a_metal_attribute_size(a->format, a->count);
    uint64_t last = source->stride ? (uint64_t)maximum * source->stride : 0;
    if (!element || last > source->byteLength ||
        element > source->byteLength - last) {
        return fetch_pgraph_error(error,
                                  @"NV2A vertex stream exceeds DMA span");
    }
    /* Validate the whole input above, but protect/download only bytes the
     * compact kernel or Current capture will actually read. An accepted XF
     * prefix must not turn an unrelated dirty surface into a producer fence. */
    if (!source->stride)
        return [self prepareRange:source->offset
                           length:element
                    deferredReads:deferredReads
                            error:error];
    BOOL includesCurrent = NO;
    const NSRange *ranges = reads.bytes;
    for (NSUInteger i = 0; i < reads.length / sizeof(*ranges); i++) {
        NSUInteger first = ranges[i].location * source->stride;
        NSUInteger length = (ranges[i].length - 1) * source->stride + element;
        NV2AMetalVRAMReadPattern pattern = { source->offset + first, length,
                                            0, 0 };
        if (source->stride > element) {
            pattern.stride = source->stride;
            pattern.element = element;
        }
        if (![self preparePattern:pattern
                    deferredReads:deferredReads
                            error:error])
            return NO;
        includesCurrent |= NSLocationInRange(current, ranges[i]);
    }
    if (includesCurrent)
        return YES;
    return
        [self prepareRange:source->offset + (NSUInteger)current * source->stride
                    length:element
             deferredReads:deferredReads
                     error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)prepareWithError:(NSError **)error
{
    NSArray *batches = [self encodeWithError:error];
    return batches && [self completeWithError:error] ? batches : nil;
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)encodeWithError:(NSError **)error
{
    return [self encodeIndependentSnapshots:NO
                                   prefixes:nil
                               indexedInput:nil
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)encodeIndependentSnapshotsWithError:
    (NSError **)error
{
    return [self encodeIndependentSnapshots:YES
                                   prefixes:nil
                               indexedInput:nil
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                                     error:(NSError **)error
{
    return [self encodeIndependentSnapshotsWithPrefixes:prefixes
                                           indexedInput:nil
                                                  error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                              indexedInput:(NV2AMetalPendingInput *)input
                                     error:(NSError **)error
{
    return [self encodeIndependentSnapshots:YES
                                   prefixes:prefixes
                               indexedInput:input
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshots:(BOOL)independent
                      prefixes:(NSArray<NSNumber *> *)prefixes
                  indexedInput:(NV2AMetalPendingInput *)input
                         error:(NSError **)error
{
    return [self encodeIndependentSnapshots:independent
                                   prefixes:prefixes
                               indexedInput:input
                             captureCurrent:NO
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeInlineCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                                       error:(NSError **)error
{
    if (![NV2AMetalPGRAPHFetch canCaptureInlineCurrentForState:_d]) {
        fetch_pgraph_error(error,
                           @"Known inline Current requires owned inline input");
        return nil;
    }
    return [self encodeCurrentSnapshotsWithPrefixes:prefixes
                                       indexedInput:nil
                                              error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                          indexedInput:(NV2AMetalPendingInput *)input
                                 error:(NSError **)error
{
    return [self encodeIndependentSnapshots:NO
                                   prefixes:prefixes
                               indexedInput:input
                             captureCurrent:YES
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshots:(BOOL)independent
                      prefixes:(NSArray<NSNumber *> *)prefixes
                  indexedInput:(NV2AMetalPendingInput *)input
                captureCurrent:(BOOL)captureCurrent
                         error:(NSError **)error
{
    if (_closed || _encodedBatches) {
        fetch_pgraph_error(error,
                           @"Native PGRAPH fetch is closed or already encoded");
        return nil;
    }
    PGRAPHState *pg = &_d->pgraph;
    if (input &&
        (![input isKindOfClass:NV2AMetalPendingInput.class] ||
         input.kind != NV2AMetalInputIndexed || !pg->inline_elements_length ||
         input.count != pg->inline_elements_length ||
         input.indices.length != input.count * 4)) {
        fetch_pgraph_error(error, @"Invalid captured PGRAPH index input");
        return nil;
    }
    if (captureCurrent &&
        (independent || ![self canCaptureCurrentForInput:input])) {
        fetch_pgraph_error(
            error,
            @"Current source requires GPU completion or has invalid bounds");
        return nil;
    }
    unsigned kinds = !!pg->draw_arrays_length + !!pg->inline_elements_length +
                     !!pg->inline_buffer_length + !!pg->inline_array_length;
    NSUInteger batchCount =
        pg->draw_arrays_length ? pg->draw_arrays_length : !!kinds;
    if (prefixes && prefixes.count != batchCount) {
        fetch_pgraph_error(error, @"Fetch prefix/input count mismatch");
        return nil;
    }
    if (!kinds) {
        _encodedBatches = @[];
        return _encodedBatches;
    }
    if (kinds != 1 ||
        pg->draw_arrays_length > ARRAY_SIZE(pg->draw_arrays_start) ||
        pg->inline_elements_length > NV2A_MAX_BATCH_LENGTH ||
        pg->inline_buffer_length > NV2A_MAX_BATCH_LENGTH ||
        pg->inline_array_length > NV2A_MAX_BATCH_LENGTH) {
        fetch_pgraph_error(error, @"Conflicting or oversized NV2A draw inputs");
        return nil;
    }
    _encodingCommands = _surfaces.commands;
    NV2AMetalAttributeSource sources[16] = { 0 };
    NV2AMetalProgramInput knownCurrent = { 0 };
    NSMutableArray<id<MTLBuffer>> *owners = [NSMutableArray new];
    NSMutableArray<NV2AMetalPGRAPHFetchBatch *> *batches = [NSMutableArray new];
    NSMutableData *deferredReads = independent ? [NSMutableData new] : nil;
    uint32_t maximum = 0, current = 0;
    NSMutableData *readRanges = [NSMutableData new];
    NSUInteger currentBatch = 0;
    NSUInteger vertices = 0;
    NSUInteger singlePrefix = 0, captureFirst = 0;
    id<MTLBuffer> indices = nil;
    NV2AMetalFetchResult *last = nil;
    uint16_t update = 0, populated = 0;
    for (unsigned i = 0; i < 16; i++)
        memcpy(sources[i].inline_value, pg->vertex_attributes[i].inline_value,
               16);
    if (pg->draw_arrays_length) {
        for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
            int32_t first = pg->draw_arrays_start[i],
                    count = pg->draw_arrays_count[i];
            if (first < 0 || count <= 0 ||
                (uint64_t)first + count - 1 > UINT32_MAX) {
                fetch_pgraph_error(error, @"Invalid NV2A multi-draw range");
                goto fail;
            }
            NSUInteger prefix = 0;
            if (!fetch_pgraph_prefix(prefixes, i, count, &prefix, error))
                goto fail;
            uint32_t end = (uint32_t)((uint64_t)first + count - 1);
            if (prefix < (NSUInteger)count) {
                NSRange range = NSMakeRange(first + prefix, count - prefix);
                [readRanges appendBytes:&range length:sizeof(range)];
            }
            if (end >= maximum) {
                maximum = end;
                currentBatch = i;
            }
        }
        fetch_merge_ranges(readRanges);
        current = maximum;
    } else if (pg->inline_elements_length) {
        vertices = pg->inline_elements_length;
        if (input) {
            maximum = input.maximumIndex;
        } else {
            for (NSUInteger i = 0; i < vertices; i++) {
                maximum = MAX(maximum, pg->inline_elements[i]);
            }
        }
        if (!fetch_pgraph_prefix(prefixes, 0, vertices, &singlePrefix, error))
            goto fail;
        const uint32_t *indexValues =
            input ? input.indices.bytes : pg->inline_elements;
        memcpy(&current, indexValues + vertices - 1, 4);
        readRanges = fetch_index_ranges(indexValues + singlePrefix,
                                         vertices - singlePrefix);
        captureFirst =
            captureCurrent ? singlePrefix : MIN(singlePrefix, vertices - 1);
        if (captureFirst < vertices) {
            indices = [_surfaces.commands.device
                newBufferWithBytes:indexValues + captureFirst
                            length:(vertices - captureFirst) * 4
                           options:MTLResourceStorageModeShared];
            if (!indices) {
                fetch_pgraph_error(error,
                                   @"Cannot snapshot NV2A inline indices");
                goto fail;
            }
            [owners addObject:indices];
        }
    } else if (pg->inline_buffer_length) {
        vertices = pg->inline_buffer_length;
        if (!fetch_pgraph_prefix(prefixes, 0, vertices, &singlePrefix, error))
            goto fail;
        captureFirst =
            captureCurrent ? singlePrefix : MIN(singlePrefix, vertices - 1);
        maximum = (uint32_t)vertices - 1;
        for (unsigned i = 0; i < 16; i++) {
            VertexAttribute *a = &pg->vertex_attributes[i];
            if (!a->inline_buffer_populated)
                continue;
            if (!a->inline_buffer) {
                fetch_pgraph_error(error, @"Missing NV2A inline buffer");
                goto fail;
            }
            if (captureFirst == vertices) {
                memcpy(knownCurrent.attributes[i],
                       a->inline_buffer + (vertices - 1) * 4, 16);
                update |= 1u << i;
                populated |= 1u << i;
                continue;
            }
            id<MTLBuffer> buffer = [_surfaces.commands.device
                newBufferWithBytes:a->inline_buffer + captureFirst * 4
                            length:(vertices - captureFirst) * 16
                           options:MTLResourceStorageModeShared];
            if (!buffer) {
                fetch_pgraph_error(error,
                                   @"Cannot snapshot NV2A inline buffer");
                goto fail;
            }
            [owners addObject:buffer];
            if (captureCurrent)
                memcpy(knownCurrent.attributes[i],
                       (const uint8_t *)buffer.contents + buffer.length - 16,
                       16);
            sources[i].buffer = buffer;
            sources[i].byteLength = buffer.length;
            sources[i].count = 4;
            sources[i].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
            sources[i].stride = 16;
            update |= 1u << i;
            populated |= 1u << i;
        }
    } else {
        NSUInteger stride = 0, offsets[16] = { 0 };
        for (unsigned i = 0; i < 16; i++) {
            VertexAttribute *a = &pg->vertex_attributes[i];
            if (!a->count)
                continue;
            unsigned element = nv2a_metal_attribute_size(a->format, a->count);
            if (!element || !a->size || a->size * a->count != element ||
                (a->size & (a->size - 1))) {
                fetch_pgraph_error(error, @"Invalid NV2A packed inline layout");
                goto fail;
            }
            stride = (stride + a->size - 1) & ~(NSUInteger)(a->size - 1);
            offsets[i] = stride;
            stride += element;
            stride = (stride + a->size - 1) & ~(NSUInteger)(a->size - 1);
        }
        if (!stride) {
            fetch_pgraph_error(
                error, @"Packed inline stream has no enabled attributes");
            goto fail;
        }
        vertices = (NSUInteger)pg->inline_array_length * 4 / stride;
        if (!vertices) {
            fetch_pgraph_error(error, @"Incomplete NV2A inline vertex");
            goto fail;
        }
        if (!fetch_pgraph_prefix(prefixes, 0, vertices, &singlePrefix, error))
            goto fail;
        captureFirst =
            captureCurrent ? singlePrefix : MIN(singlePrefix, vertices - 1);
        maximum = (uint32_t)vertices - 1;
        id<MTLBuffer> buffer = nil;
        if (captureFirst < vertices)
            buffer = [_surfaces.commands.device
                newBufferWithBytes:(const uint8_t *)pg->inline_array +
                                   captureFirst * stride
                            length:(vertices - captureFirst) * stride
                           options:MTLResourceStorageModeShared];
        if (!buffer && captureFirst < vertices) {
            fetch_pgraph_error(error,
                               @"Cannot snapshot packed NV2A inline data");
            goto fail;
        }
        if (buffer)
            [owners addObject:buffer];
        for (unsigned i = 0; i < 16; i++) {
            VertexAttribute *a = &pg->vertex_attributes[i];
            if (!a->count)
                continue;
            if (buffer) {
                sources[i].buffer = buffer;
                sources[i].offset = offsets[i];
                sources[i].byteLength = buffer.length - offsets[i];
                sources[i].format = a->format;
                sources[i].count = a->count;
                sources[i].stride = (unsigned)stride;
            }
            if (captureCurrent) {
                const uint8_t *last = buffer ?
                                          (const uint8_t *)buffer.contents +
                                              buffer.length - stride :
                                          (const uint8_t *)pg->inline_array +
                                              (vertices - 1) * stride;
                inline_current_value(last + offsets[i], a->format, a->count,
                                     knownCurrent.attributes[i]);
            }
            update |= 1u << i;
        }
    }
    if (pg->draw_arrays_length || pg->inline_elements_length) {
        for (unsigned i = 0; i < 16; i++) {
            VertexAttribute *a = &pg->vertex_attributes[i];
            if (!a->count)
                continue;
            if (![self mapAttribute:a
                             source:&sources[i]
                                max:maximum
                              reads:readRanges
                            current:current
                      deferredReads:deferredReads
                              error:error])
                goto fail;
            update |= 1u << i;
        }
        if (captureCurrent) {
            /* Source read guards are installed before this copy. The
             * selected bytes must still be CPU-readable; downloads/writers
             * never become host Current speculatively. */
            for (unsigned i = 0; i < 16; i++) {
                if (!sources[i].count)
                    continue;
                unsigned element = nv2a_metal_attribute_size(sources[i].format,
                                                             sources[i].count);
                uint64_t offset = (uint64_t)current * sources[i].stride;
                BOOL ready = NO;
                if (offset > sources[i].byteLength ||
                    element > sources[i].byteLength - offset ||
                    ![_surfaces tryIdleCPUAccessAtAddress:sources[i].offset +
                                                          (NSUInteger)offset
                                                   length:element
                                                    write:NO
                                                completed:&ready
                                                    error:error] ||
                    !ready) {
                    fetch_pgraph_error(
                        error, @"Captured Current source is not CPU-readable");
                    goto fail;
                }
                inline_current_value(
                    (const uint8_t *)sources[i].buffer.contents +
                        sources[i].offset + (NSUInteger)offset,
                    sources[i].format, sources[i].count,
                    knownCurrent.attributes[i]);
            }
        }
    }
    if (deferredReads) {
        if (!_independentCommands) {
            _independentCommands = [[NV2AMetalCommands alloc]
                initWithDevice:_surfaces.commands.device
                         error:error];
            if (!_independentCommands)
                goto fail;
        }
        NV2AMetalIndependentReads *reads = nil;
        if (![_surfaces
                tryBeginIndependentReadPatterns:deferredReads.bytes
                                          count:deferredReads.length /
                                                sizeof(NV2AMetalVRAMReadPattern)
                                       commands:_independentCommands
                                          reads:&reads
                                          error:error])
            goto fail;
        _independentReads = reads;
        if (_independentReads) {
            _encodingCommands = _independentCommands;
        } else {
            const NV2AMetalVRAMReadPattern *spans = deferredReads.bytes;
            for (NSUInteger i = 0; i < deferredReads.length / sizeof(*spans);
                 i++)
                if (![_surfaces prepareGPUReadPattern:spans[i] error:error])
                    goto fail;
        }
    }
    if (!_independentReads && ![_surfaces prepareGPUReadAtAddress:0
                                                           length:0
                                                            error:error])
        goto fail;
    if (pg->draw_arrays_length) {
        for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
            NSUInteger prefix = prefixes ? prefixes[i].unsignedIntegerValue : 0;
            NV2AMetalFetchResult *f =
                [_fetch encodeSources:sources
                                count:pg->draw_arrays_count[i]
                          firstVertex:pg->draw_arrays_start[i]
                              indices:nil
                          indexOffset:0
                            indexSize:0
                        currentVertex:!captureCurrent && i == currentBatch ?
                                          pg->draw_arrays_count[i] - 1 :
                                          NSNotFound
                       skippingPrefix:prefix
                             commands:_encodingCommands
                                error:error];
            if (!f)
                goto fail;
            if (i == currentBatch)
                last = f;
            [batches addObject:[[NV2AMetalPGRAPHFetchBatch alloc]
                                   initWithFetch:f
                                           first:pg->draw_arrays_start[i]
                                         indexed:NO
                                           input:pg->draw_arrays_count[i]
                                          prefix:prefix]];
        }
    } else {
        NV2AMetalFetchResult *f =
            [_fetch encodeSources:sources
                            count:vertices - captureFirst
                      firstVertex:0
                          indices:indices
                      indexOffset:0
                        indexSize:indices ? 4 : 0
                    currentVertex:captureCurrent ? NSNotFound :
                                                   vertices - captureFirst - 1
                   skippingPrefix:singlePrefix - captureFirst
                         commands:_encodingCommands
                            error:error];
        if (!f)
            goto fail;
        last = f;
        [batches addObject:[[NV2AMetalPGRAPHFetchBatch alloc]
                               initWithFetch:f
                                       first:0
                                     indexed:pg->inline_elements_length != 0
                                       input:vertices
                                      prefix:singlePrefix]];
    }
    if (captureCurrent)
        _capturedCurrent = [NSData dataWithBytes:&knownCurrent
                                        length:sizeof(knownCurrent)];
    _encodedBatches = [batches copy];
    _last = last;
    _update = update;
    _populated = populated;
    return _encodedBatches;
fail:
    [self cancel];
    return nil;
}
- (BOOL)completeInlineCurrentSnapshotsWithError:(NSError **)error
{
    return [self completeCurrentSnapshotsWithError:error];
}
- (BOOL)completeCurrentSnapshotsWithError:(NSError **)error
{
    if (!_encodedBatches || !_encodedBatches.count || _submission ||
        _independentReads || _encodingCommands != _surfaces.commands ||
        !_encodingCommands.commandBuffer ||
        _capturedCurrent.length != sizeof(NV2AMetalProgramInput))
        return fetch_pgraph_error(error, @"No captured Current to publish");
    const NV2AMetalProgramInput *values = _capturedCurrent.bytes;
    PGRAPHState *pg = &_d->pgraph;
    for (unsigned i = 0; i < 16; i++) {
        if (_update & (1u << i))
            memcpy(pg->vertex_attributes[i].inline_value, values->attributes[i],
                   16);
        if (_populated & (1u << i))
            pg->vertex_attributes[i].inline_buffer_populated = false;
    }
    pg->compressed_attrs = 0;
    _encodedBatches = nil;
    _last = nil;
    _capturedCurrent = nil;
    _encodingCommands = nil;
    return YES;
}
- (BOOL)submitWithError:(NSError **)error
{
    if (!_encodedBatches || _submission)
        return fetch_pgraph_error(error, @"No unsubmitted PGRAPH fetch");
    if (!_encodedBatches.count)
        return YES;
    if (!(_independentReads ?
              [_surfaces submitIndependentReads:_independentReads error:error] :
          _encodingCommands == _surfaces.commands ?
              [_surfaces submitWithError:error] :
              [_encodingCommands submitWithError:error]))
        return NO;
    _submission = _encodingCommands.lastSubmitted;
    return _submission ?
               YES :
               fetch_pgraph_error(error, @"Missing PGRAPH fetch submission");
}
- (BOOL)completeWithError:(NSError **)error
{
    PGRAPHState *pg = &_d->pgraph;
    if (!_encodedBatches)
        return fetch_pgraph_error(error,
                                  @"No encoded PGRAPH fetch to complete");
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = _encodedBatches;
    NV2AMetalFetchResult *last = _last;
    NSData *capturedCurrent = _capturedCurrent;
    uint16_t update = _update, populated = _populated;
    if (!_submission && ![self submitWithError:error]) {
        [self cancel];
        return NO;
    }
    NV2AMetalSubmission *submission = _submission;
    NV2AMetalCommands *commands = _encodingCommands;
    NV2AMetalIndependentReads *independentReads = _independentReads;
    _encodedBatches = nil;
    _last = nil;
    _capturedCurrent = nil;
    _submission = nil;
    _encodingCommands = nil;
    _independentReads = nil;
    if (!batches.count)
        return YES;
    if (!(independentReads ?
              [_surfaces completeIndependentReads:independentReads
                                            error:error] :
              [_surfaces waitForSubmission:submission error:error]))
        goto fail;
    for (NV2AMetalPGRAPHFetchBatch *b in batches) {
        if (!b.fetch.faults)
            continue; /* Entirely cached, no Current selected in this batch. */
        uint32_t fault;
        memcpy(&fault,
               (const uint8_t *)b.fetch.faults.contents +
                   b.fetch.faultSummaryOffset,
               sizeof(fault));
        if (fault) {
            fetch_pgraph_error(error, @"NV2A vertex fetch bounds fault");
            goto fail;
        }
    }
    if (!capturedCurrent &&
        ((uint32_t *)last.faults.contents)[last.vertexCount]) {
        fetch_pgraph_error(error, @"NV2A current-attribute bounds fault");
        goto fail;
    }
    /* A later host XF encoding error can require completed prefix retention.
     * That path still validates every GPU suffix fault above, but Current is
     * the same bounded immutable host capture used by no-wait completion. */
    const NV2AMetalProgramInput *values =
        capturedCurrent ?
            capturedCurrent.bytes :
            (const NV2AMetalProgramInput *)last.attributes.contents +
                last.vertexCount;
    for (unsigned i = 0; i < 16; i++) {
        if (update & (1u << i))
            memcpy(pg->vertex_attributes[i].inline_value, values->attributes[i],
                   16);
        if (populated & (1u << i))
            pg->vertex_attributes[i].inline_buffer_populated = false;
    }
    /* Native shaders always consume already-decoded Float4 attributes. */
    pg->compressed_attrs = 0;
    return YES;
fail:
    if (independentReads) {
        [_surfaces cancelIndependentReads:independentReads];
        [_surfaces collectCompletedWithError:NULL];
    }
    if (commands == _surfaces.commands)
        [_surfaces cancel];
    else
        [commands cancel];
    return NO;
}
@end
