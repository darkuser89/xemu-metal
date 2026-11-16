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

typedef struct FetchDMAContexts {
    DMAObject objects[2];
    unsigned loaded;
} FetchDMAContexts;

static BOOL dma_attribute_source(NV2AState *d, const VertexAttribute *a,
                                 id<MTLBuffer> vram,
                                 FetchDMAContexts *contexts,
                                 NV2AMetalAttributeSource *source,
                                 NSError **error)
{
    NSUInteger size = vram.length;
    /* Each probe or encoding attempt resolves a DMA context once. Keep
     * the snapshot local so encoding observes changes after the probe. */
    unsigned index = a->dma_select;
    unsigned bit = 1u << index;
    if (!(contexts->loaded & bit)) {
        if (contexts->loaded &&
            d->pgraph.dma_vertex_a == d->pgraph.dma_vertex_b) {
            contexts->objects[index] = contexts->objects[index ^ 1];
        } else {
            contexts->objects[index] =
                nv_dma_load(d, index ? d->pgraph.dma_vertex_b :
                                       d->pgraph.dma_vertex_a);
        }
        contexts->loaded |= bit;
    }
    DMAObject dma = contexts->objects[index];
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
/* No attribute values are read here. The immutable full input has already
 * supplied the DMA bounds/read guards; this only compacts the GPU index upload.
 * Current for indexed PGRAPH is always the last original input, hence belongs
 * to every nonempty suffix and has a unique ordinal without extra XF work. */
static NSData *fetch_readonly_indices(NV2AMetalPendingInput *input,
                                      NSUInteger prefix, NSData **remap,
                                      NSUInteger *current, BOOL *computed)
{
    *computed = NO;
    *remap = nil;
    if (prefix > input.count)
        return nil;
    NSUInteger count = input.count - prefix;
    if (count < 2) {
        *computed = YES;
        return nil;
    }
    const uint32_t *values = (const uint32_t *)input.indices.bytes + prefix;
    /* Strict monotonicity proves there are no duplicates. Equal adjacent
     * values in a monotone sequence can be remapped without a hash table. */
    BOOL increasing = YES, decreasing = YES;
    BOOL nondecreasing = YES, nonincreasing = YES;
    for (NSUInteger i = 1; i < count; i++) {
        increasing &= values[i] > values[i - 1];
        decreasing &= values[i] < values[i - 1];
        nondecreasing &= values[i] >= values[i - 1];
        nonincreasing &= values[i] <= values[i - 1];
        if (!nondecreasing && !nonincreasing)
            break;
    }
    if (increasing || decreasing) {
        *computed = YES;
        return nil;
    }
    if (nondecreasing || nonincreasing) {
        NSMutableData *unique = [NSMutableData dataWithLength:count * 4];
        NSMutableData *mapping = [NSMutableData dataWithLength:count * 4];
        if (!unique || !mapping)
            return nil;
        uint32_t *indices = unique.mutableBytes, *ordinals = mapping.mutableBytes;
        indices[0] = values[0];
        ordinals[0] = 0;
        NSUInteger retained = 1;
        for (NSUInteger i = 1; i < count; i++) {
            if (values[i] != values[i - 1])
                indices[retained++] = values[i];
            ordinals[i] = (uint32_t)(retained - 1);
        }
        NSUInteger last = ordinals[count - 1];
        unique.length = retained * 4;
        NSData *uniqueSnapshot = [unique copy], *remapSnapshot = [mapping copy];
        if (!uniqueSnapshot || !remapSnapshot)
            return nil;
        *current = last;
        *remap = remapSnapshot;
        *computed = YES;
        return uniqueSnapshot;
    }
    NSUInteger capacity = 1;
    while (capacity < 2 * count)
        capacity *= 2;
    typedef struct FetchIndexEntry {
        uint32_t index, ordinal;
    } FetchIndexEntry;
    g_autofree FetchIndexEntry *table = g_try_new(FetchIndexEntry, capacity);
    if (!table)
        return nil;
    for (NSUInteger i = 0; i < capacity; i++)
        table[i].ordinal = UINT32_MAX;
    NSMutableData *unique = [NSMutableData dataWithLength:count * 4];
    NSMutableData *mapping = [NSMutableData dataWithLength:count * 4];
    if (!unique || !mapping)
        return nil;
    uint32_t *indices = unique.mutableBytes, *ordinals = mapping.mutableBytes;
    NSUInteger retained = 0;
    for (NSUInteger i = 0; i < count; i++) {
        uint32_t index = values[i];
        NSUInteger slot = ((uint64_t)index * UINT64_C(2654435761)) &
                          (capacity - 1);
        while (table[slot].ordinal != UINT32_MAX && table[slot].index != index)
            slot = (slot + 1) & (capacity - 1);
        if (table[slot].ordinal == UINT32_MAX) {
            table[slot] = (FetchIndexEntry){ index, (uint32_t)retained };
            indices[retained++] = index;
        }
        ordinals[i] = table[slot].ordinal;
    }
    if (retained == count) {
        *computed = YES;
        return nil;
    }
    NSUInteger last = ordinals[count - 1];
    unique.length = retained * 4;
    NSData *uniqueSnapshot = [unique copy], *remapSnapshot = [mapping copy];
    if (!uniqueSnapshot || !remapSnapshot)
        return nil;
    *current = last;
    *remap = remapSnapshot;
    *computed = YES;
    return uniqueSnapshot;
}

typedef enum FetchPlanKind {
    FetchPlanIndexRanges,
    FetchPlanArrayRanges,
    FetchPlanReadonlyIndices,
    FetchPlanFloatProof,
} FetchPlanKind;
enum { FetchPlanMaximumPayload = 64 * 1024 };

/* Pure CPU metadata: no guest pointer, fetch result or command ownership. */
typedef struct FetchFloatProofSourceKey {
    NSUInteger offset, byteLength, bufferLength;
    unsigned format, count, stride;
} FetchFloatProofSourceKey;
typedef struct FetchFloatProofKey {
    uint64_t lanes;
    NSUInteger first, indexOffset, indexLength, batchCount, arrays, sequence;
    FetchFloatProofSourceKey sources[16];
} FetchFloatProofKey;
typedef struct FetchFloatProofBatchKey {
    NSUInteger first, prefix, physicalCount, inputCount, indexed;
} FetchFloatProofBatchKey;
/* Temporary exact DrawArrays windows; zero ordinal marks an empty slot.
 * This is metadata grouping only, never a change to Fetch/XF execution. */
typedef struct FetchFloatProofWindow {
    uint32_t first, count, ordinal;
} FetchFloatProofWindow;
static FetchFloatProofWindow *
fetch_float_window(NSMutableData *data, NSUInteger first, NSUInteger count)
{
    NSUInteger capacity = data.length / sizeof(FetchFloatProofWindow);
    if (!capacity || (capacity & (capacity - 1)))
        return NULL;
    FetchFloatProofWindow *table = data.mutableBytes;
    uint64_t hash = (uint64_t)first * UINT64_C(0x9e3779b97f4a7c15) ^
                    (uint64_t)count * UINT64_C(0xbf58476d1ce4e5b9);
    hash ^= hash >> 32;
    NSUInteger slot = hash & (capacity - 1);
    for (NSUInteger probe = 0; probe < capacity; probe++) {
        FetchFloatProofWindow *entry = &table[slot];
        if (!entry->ordinal || (entry->first == first && entry->count == count))
            return entry;
        slot = (slot + 1) & (capacity - 1);
    }
    return NULL;
}
static int fetch_index_order(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}
static void fetch_sort_indices(uint32_t *indices, NSUInteger count,
                                unsigned shift)
{
    if (count <= 64) {
        qsort(indices, count, sizeof(*indices), fetch_index_order);
        return;
    }
    /* In-place MSD radix partitioning keeps the single index copy. Each
     * level uses two fixed tables; uint32_t indices need at most four. */
    NSUInteger ends[256] = { 0 }, next[256];
    for (NSUInteger i = 0; i < count; i++)
        ends[(indices[i] >> shift) & 255]++;
    NSUInteger end = 0;
    for (unsigned bucket = 0; bucket < 256; bucket++) {
        next[bucket] = end;
        end += ends[bucket];
        ends[bucket] = end;
    }
    for (unsigned bucket = 0; bucket < 256; bucket++) {
        while (next[bucket] < ends[bucket]) {
            uint32_t value = indices[next[bucket]];
            unsigned target = (value >> shift) & 255;
            if (target == bucket) {
                next[bucket]++;
            } else {
                NSUInteger destination = next[target]++;
                indices[next[bucket]] = indices[destination];
                indices[destination] = value;
            }
        }
    }
    if (!shift)
        return;
    NSUInteger first = 0;
    for (unsigned bucket = 0; bucket < 256; bucket++) {
        NSUInteger length = ends[bucket] - first;
        if (length > 1)
            fetch_sort_indices(indices + first, length, shift - 8);
        first = ends[bucket];
    }
}
static BOOL fetch_bitmap_index_ranges(const uint32_t *indices, NSUInteger count,
                                      uint32_t minimum, uint32_t maximum,
                                      NSMutableData *ranges)
{
    NSUInteger words = ((NSUInteger)maximum - minimum) / 64 + 1;
    /* No larger than the uint32_t copy required by sorting a sparse domain. */
    if (words > count / 2)
        return NO;
    __attribute__((objc_precise_lifetime)) NSMutableData *bitmap =
        [NSMutableData dataWithLength:words * sizeof(uint64_t)];
    if (!bitmap)
        return NO;
    uint64_t *bits = bitmap.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger offset = (NSUInteger)indices[i] - minimum;
        bits[offset / 64] |= UINT64_C(1) << (offset % 64);
    }
    NSRange range = NSMakeRange(0, 0);
    for (NSUInteger i = 0; i < words; i++) {
        uint64_t word = bits[i];
        while (word) {
            NSUInteger index = (NSUInteger)minimum + i * 64 +
                               (unsigned)__builtin_ctzll(word);
            if (!range.length)
                range = NSMakeRange(index, 1);
            else if (index == NSMaxRange(range))
                range.length++;
            else {
                [ranges appendBytes:&range length:sizeof(range)];
                range = NSMakeRange(index, 1);
            }
            word &= word - 1;
        }
    }
    [ranges appendBytes:&range length:sizeof(range)];
    return YES;
}
static NSMutableData *fetch_index_ranges(const uint32_t *indices,
                                         NSUInteger count)
{
    NSMutableData *ranges = [NSMutableData new];
    if (!ranges)
        return nil;
    if (!count)
        return ranges;
    NSMutableData *ordered = nil;
    NSUInteger firstUnsorted = 1;
    while (firstUnsorted < count &&
           indices[firstUnsorted] >= indices[firstUnsorted - 1])
        firstUnsorted++;
    if (firstUnsorted < count) {
        /* The sorted prefix already proves its extrema. Scan only the
         * remaining suffix before choosing the bitmap or sort fallback. */
        uint32_t minimum = indices[0], maximum = indices[firstUnsorted - 1];
        for (NSUInteger i = firstUnsorted; i < count; i++) {
            minimum = MIN(minimum, indices[i]);
            maximum = MAX(maximum, indices[i]);
        }
        if (fetch_bitmap_index_ranges(indices, count, minimum, maximum,
                                      ranges))
            return ranges;
        ordered = [NSMutableData dataWithBytes:indices length:count * 4];
        if (!ordered)
            return nil;
        fetch_sort_indices(ordered.mutableBytes, count, 24);
        indices = ordered.bytes;
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
/* fetch_index_ranges represents each distinct suffix index exactly once.
 * Its cardinality therefore proves whether readonly remapping can help. */
static BOOL fetch_ranges_are_unique(NSData *ranges, NSUInteger count)
{
    if (!ranges || ranges.length % sizeof(NSRange))
        return NO;
    const NSRange *values = ranges.bytes;
    NSUInteger total = 0, end = 0;
    for (NSUInteger i = 0; i < ranges.length / sizeof(*values); i++) {
        NSRange range = values[i];
        if (!range.length || (i && range.location < end) ||
            range.length > count - total ||
            range.location > NSUIntegerMax - range.length)
            return NO;
        total += range.length;
        end = NSMaxRange(range);
    }
    return total == count;
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

static NSRange fetch_dirty_page_range(NV2AMetalVRAMReadPattern pattern,
                                      NSUInteger size)
{
    NSUInteger begin = pattern.address & TARGET_PAGE_MASK;
    NSUInteger end = pattern.address + pattern.length;
    NSUInteger padding = (TARGET_PAGE_SIZE - end % TARGET_PAGE_SIZE) %
                         TARGET_PAGE_SIZE;
    end += MIN(padding, size - end);
    return NSMakeRange(begin, end - begin);
}

static void fetch_clear_tcg_dirty(MemoryRegion *vram, NSUInteger size,
                                  const NV2AMetalVRAMReadPattern *patterns,
                                  NSUInteger count)
{
    NSMutableData *pages = nil;
    NSRange run = { 0, 0 };
    for (NSUInteger i = 0; i < count; i++) {
        NSRange range = fetch_dirty_page_range(patterns[i], size);
        if (!run.length) {
            run = range;
        } else if (range.location <= NSMaxRange(run) &&
                   run.location <= NSMaxRange(range)) {
            run = NSUnionRange(run, range);
        } else {
            if (!pages)
                pages = [NSMutableData new];
            [pages appendBytes:&run length:sizeof(run)];
            run = range;
        }
    }
    if (!pages) {
        if (run.length)
            memory_region_test_and_clear_dirty(vram, run.location, run.length,
                                               DIRTY_MEMORY_NV2A);
        return;
    }
    [pages appendBytes:&run length:sizeof(run)];
    fetch_merge_ranges(pages);
    const NSRange *ranges = pages.bytes;
    for (NSUInteger i = 0; i < pages.length / sizeof(*ranges); i++)
        memory_region_test_and_clear_dirty(vram, ranges[i].location,
                                           ranges[i].length, DIRTY_MEMORY_NV2A);
}

typedef struct FetchReadLane {
    NSUInteger offset, stride, element;
} FetchReadLane;

static NV2AMetalVRAMReadPattern fetch_read_pattern(FetchReadLane lane,
                                                 NSRange range)
{
    NSUInteger address = lane.offset + range.location * lane.stride;
    NSUInteger length = (range.length - 1) * lane.stride + lane.element;
    if (lane.stride > lane.element)
        return (NV2AMetalVRAMReadPattern){ address, length, lane.stride,
                                         lane.element };
    return (NV2AMetalVRAMReadPattern){ address, length, 0, 0 };
}

typedef struct FetchCurrentReads {
    NV2AMetalVRAMReadSpan spans[16];
    NSUInteger count;
} FetchCurrentReads;

typedef struct FetchConstantReads {
    NV2AMetalVRAMReadSpan spans[16];
    uint64_t versions[16];
    uint8_t attributes[16], components[16], formats[16];
    NSUInteger count;
} FetchConstantReads;

static uint32_t fetch_float_order(uint32_t bits)
{
    return bits & 0x80000000u ? ~bits : bits ^ 0x80000000u;
}

static NSUInteger fetch_float_index(const uint32_t *indices, NSUInteger ordinal)
{
    if (!indices)
        return ordinal;
    uint32_t index;
    memcpy(&index, indices + ordinal, sizeof(index));
    return index;
}

@interface NV2AMetalFetchResult (PGRAPHCurrentProof)
- (void)bindPGRAPHCurrentProof:(NSData *)current
                      commands:(NV2AMetalCommands *)commands;
- (void)bindPGRAPHFloatProofSummaries:(NSData *)summaries
                             laneMask:(uint64_t)laneMask
                                first:(NSUInteger)first
                                count:(NSUInteger)count
                             commands:(NV2AMetalCommands *)commands;
@end

static int fetch_lane_order(const void *left, const void *right)
{
    const FetchReadLane *a = left, *b = right;
    if (a->stride != b->stride)
        return (a->stride > b->stride) - (a->stride < b->stride);
    return (a->offset > b->offset) - (a->offset < b->offset);
}

static unsigned fetch_merge_read_lanes(FetchReadLane *lanes, unsigned count)
{
    if (count < 2)
        return count;
    for (unsigned i = 1; i < count; i++)
        if (fetch_lane_order(&lanes[i - 1], &lanes[i]) > 0) {
            qsort(lanes, count, sizeof(*lanes), fetch_lane_order);
            break;
        }
    unsigned retained = 1;
    for (unsigned i = 1; i < count; i++) {
        FetchReadLane lane = lanes[i];
        FetchReadLane *prior = &lanes[retained - 1];
        if (lane.stride == prior->stride) {
            NSUInteger delta = lane.offset - prior->offset;
            if (delta <= prior->element &&
                (!lane.stride || delta + lane.element <= lane.stride)) {
                prior->element = MAX(prior->element, delta + lane.element);
                continue;
            }
        }
        lanes[retained++] = lane;
    }
    return retained;
}

@interface NV2AMetalPGRAPHFetchBatch ()
- (instancetype)initWithFetch:(NV2AMetalFetchResult *)fetch
                        first:(unsigned)first
                      indexed:(BOOL)indexed
                        input:(NSUInteger)input
                       prefix:(NSUInteger)prefix
                        remap:(NSData *)remap;
@end
@implementation NV2AMetalPGRAPHFetchBatch
- (instancetype)initWithFetch:(NV2AMetalFetchResult *)fetch
                        first:(unsigned)first
                      indexed:(BOOL)indexed
                        input:(NSUInteger)input
                       prefix:(NSUInteger)prefix
                        remap:(NSData *)remap
{
    self = [super init];
    if (self) {
        _fetch = fetch;
        _firstVertex = first;
        _indexed = indexed;
        _inputVertexCount = input;
        _firstDecodedVertex = prefix;
        _remap = remap;
        _physicalVertexCount = fetch.vertexCount;
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
    __weak NV2AMetalPendingInput *_indexRangesInput;
    NSUInteger _indexRangesPrefix, _indexRangesFirstRead;
    NSData *_indexRanges, *_indexRangesKey;
    NSData *_arrayRanges, *_arrayRangesKey;
    uint32_t _arrayRangesMaximum;
    NSUInteger _arrayRangesCurrentBatch;
    __weak NV2AMetalPendingInput *_readonlyIndexInput;
    __weak NSData *_readonlyIndexData;
    __weak NSData *_readonlyIndexSequence;
    NSUInteger _readonlyIndexCount, _readonlyIndexLength, _readonlyIndexPrefix;
    NSData *_readonlyUniqueIndices, *_readonlyRemap;
    NSUInteger _readonlyCurrent;
    BOOL _readonlyIndexComputed;
    __weak id<MTLBuffer> _floatProofVram;
    __weak NSData *_floatProofIndices, *_floatProofSequence;
    NSData *_floatProofKey, *_floatProofSpans;
    NSArray<NSData *> *_floatProofSummaries;
    NSUInteger _floatProofPayload;
    uint64_t _floatProofVersion, _floatProofEpoch;
    FetchConstantReads _constantReads, _encodedConstantReads;
    NV2AMetalProgramInput _constantValues;
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
    FetchCurrentReads reads;
    return [self canCaptureCurrentForInput:input mappedSources:NULL
                                          currentReads:&reads];
}

- (BOOL)canCaptureCurrentForInput:(NV2AMetalPendingInput *)input
                    mappedSources:(NV2AMetalAttributeSource *)mapped
                     currentReads:(FetchCurrentReads *)reads
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
    reads->count = 0;
    id<MTLBuffer> vram = _surfaces.vram;
    FetchDMAContexts contexts = { 0 };
    for (unsigned i = 0; i < 16; i++) {
        VertexAttribute *a = &pg->vertex_attributes[i];
        if (!a->count)
            continue;
        NV2AMetalAttributeSource temporary = { 0 };
        NV2AMetalAttributeSource *source = mapped ? &mapped[i] : &temporary;
        unsigned element = nv2a_metal_attribute_size(a->format, a->count);
        if (!element ||
            !dma_attribute_source(_d, a, vram, &contexts, source, NULL))
            return NO;
        uint64_t offset = (uint64_t)current * source->stride;
        if (offset > source->byteLength || element > source->byteLength - offset)
            return NO;
        reads->spans[reads->count++] = (NV2AMetalVRAMReadSpan){
            source->offset + (NSUInteger)offset, element
        };
    }
    BOOL ready = NO;
    return [_surfaces tryIdleCPUReadSpans:reads->spans count:reads->count
                        collectCompleted:YES completed:&ready error:NULL] &&
           ready;
}
- (void)getSourcePreview:(NV2AMetalFetchUniforms *)preview
              attributes:(uint16_t)attributes
{
    uint16_t requested = attributes;
    const PGRAPHState *pg = &_d->pgraph;
    *preview = (NV2AMetalFetchUniforms){ 0 };
    /* PGRAPH indexed fetch adds zero; linear ranges validate the addition.
     * A packed inline attribute always has a nonzero interleaved stride. */
    while (attributes) {
        unsigned i = __builtin_ctz((unsigned)attributes);
        attributes &= attributes - 1;
        const VertexAttribute *attr = &pg->vertex_attributes[i];
        NV2AMetalFetchAttribute *source = &preview->attributes[i];
        memcpy(source->inline_value, attr->inline_value,
               sizeof(source->inline_value));
        if (pg->inline_buffer_length) {
            if (attr->inline_buffer_populated) {
                source->format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
                source->count = 4;
                source->stride = 16;
            }
        } else if (attr->count) {
            source->format = attr->format;
            source->count = attr->count;
            source->stride = pg->inline_array_length ? 1u : attr->stride;
        }
    }
    if (_closed || !_constantReads.count || pg->inline_buffer_length ||
        pg->inline_array_length)
        return;
    FetchConstantReads selected = { 0 };
    FetchDMAContexts contexts = { 0 };
    for (NSUInteger row = 0; row < _constantReads.count; row++) {
        unsigned i = _constantReads.attributes[row];
        const VertexAttribute *attr = &pg->vertex_attributes[i];
        if (!(requested & (1u << i)) || attr->stride ||
            attr->format != _constantReads.formats[row] ||
            attr->count != _constantReads.components[row])
            continue;
        NV2AMetalAttributeSource source = { 0 };
        if (!dma_attribute_source(_d, attr, _surfaces.vram, &contexts,
                                  &source, NULL) ||
            source.offset != _constantReads.spans[row].address ||
            source.byteLength < _constantReads.spans[row].length)
            continue;
        NSUInteger slot = selected.count++;
        selected.spans[slot] = _constantReads.spans[row];
        selected.versions[slot] = _constantReads.versions[row];
        selected.attributes[slot] = i;
    }
    if (!selected.count)
        return;
    BOOL ready = NO;
    uint64_t versions[16];
    /* Never read VRAM speculatively. A successful earlier Current supplies
     * values only while the exact mapped bytes retain their source version
     * and no writer/download is pending. The final proof uses a fresh capture. */
    if (![_surfaces tryIdleCPUReadSpans:selected.spans count:selected.count
                                completed:&ready error:NULL] || !ready ||
        ![_surfaces sourceVersionsForReadSpans:selected.spans
                                        count:selected.count versions:versions
                                 firstSurface:NULL error:NULL])
        return;
    for (NSUInteger row = 0; row < selected.count; row++) {
        if (versions[row] != selected.versions[row])
            continue;
        unsigned i = selected.attributes[row];
        preview->attributes[i].count = 0;
        memcpy(preview->attributes[i].inline_value,
               _constantValues.attributes[i], 16);
    }
}
- (void)rememberConstantCurrent:(const NV2AMetalProgramInput *)values
                          reads:(const FetchConstantReads *)reads
{
    if (!reads->count)
        return;
    uint64_t versions[16];
    if (![_surfaces sourceVersionsForReadSpans:reads->spans count:reads->count
                                      versions:versions firstSurface:NULL
                                         error:NULL] ||
        memcmp(versions, reads->versions, reads->count * sizeof(*versions)))
        return;
    _constantReads = *reads;
    _constantValues = *values;
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
                                   faultSummaryOnly:YES
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
    _encodedConstantReads.count = 0;
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
    _indexRangesInput = nil;
    _indexRanges = nil;
    _indexRangesKey = nil;
    _arrayRanges = nil;
    _arrayRangesKey = nil;
    [self clearReadonlyIndexPlan];
    [self clearFloatProofMemo];
    _constantReads.count = _encodedConstantReads.count = 0;
    _closed = YES;
}
- (void)clearReadonlyIndexPlan
{
    _readonlyIndexComputed = NO;
    _readonlyIndexInput = nil;
    _readonlyIndexData = nil;
    _readonlyIndexSequence = nil;
    _readonlyUniqueIndices = nil;
    _readonlyRemap = nil;
}
- (void)clearFloatProofMemo
{
    _floatProofKey = _floatProofSpans = nil;
    _floatProofSummaries = nil;
    _floatProofVram = nil;
    _floatProofIndices = _floatProofSequence = nil;
    _floatProofPayload = 0;
}
/* The index-range cache has already checked the exact suffix sequence, not
 * merely its sorted set. Its immutable byte key may prove equal new input
 * descriptors, including a deterministic readonly unique/remap choice.
 * Weak owners never extend a potentially much larger index snapshot's life.
 */
- (NSData *)floatProofSequenceForIndexData:(NSData *)data
                               indexOffset:(NSUInteger)offset
                                     first:(NSUInteger)first
                                  sequence:(NSUInteger *)sequence
{
    *sequence = 0;
    NV2AMetalPendingInput *input = _indexRangesInput;
    if (![input isMemberOfClass:NV2AMetalPendingInput.class] ||
        !_indexRangesKey || _indexRangesFirstRead != _indexRangesPrefix ||
        _indexRangesPrefix >= input.count || first ||
        _indexRangesKey.length != (input.count - _indexRangesPrefix) * 4)
        return nil;
    if (data == input.indices && offset == _indexRangesPrefix) {
        *sequence = 1;
        return _indexRangesKey;
    }
    if (!offset && _readonlyIndexComputed && _readonlyIndexInput == input &&
        _readonlyIndexData == input.indices &&
        _readonlyIndexPrefix == _indexRangesPrefix &&
        data == _readonlyUniqueIndices) {
        *sequence = 2;
        return _indexRangesKey;
    }
    return nil;
}
- (NSData *)floatProofKeyForBatches:
                (NSArray<NV2AMetalPGRAPHFetchBatch *> *)batches
                            sources:(const NV2AMetalAttributeSource *)sources
                          indexData:(NSData *)indexData
                        indexOffset:(NSUInteger)indexOffset
                              first:(NSUInteger)first
                             arrays:(BOOL)arrays
                              lanes:(uint64_t)lanes
{
    if ((!arrays &&
         (!indexData || [indexData isKindOfClass:NSMutableData.class])) ||
        batches.count > (FetchPlanMaximumPayload - sizeof(FetchFloatProofKey)) /
                            sizeof(FetchFloatProofBatchKey))
        return nil;
    NSUInteger length = sizeof(FetchFloatProofKey) +
                        batches.count * sizeof(FetchFloatProofBatchKey);
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (!data)
        return nil;
    FetchFloatProofKey *key = data.mutableBytes;
    key->lanes = lanes;
    key->first = first;
    key->indexOffset = indexOffset;
    key->indexLength = indexData.length;
    key->batchCount = batches.count;
    key->arrays = arrays;
    if (!arrays)
        [self floatProofSequenceForIndexData:indexData
                                 indexOffset:indexOffset
                                       first:first
                                    sequence:&key->sequence];
    while (lanes) {
        unsigned component = __builtin_ctzll(lanes);
        lanes &= lanes - 1;
        unsigned attribute = component / 4;
        const NV2AMetalAttributeSource *source = &sources[attribute];
        if (source->buffer != _surfaces.vram)
            return nil; /* Do not memoize upload-arena/inline snapshots. */
        FetchFloatProofSourceKey *selected = key->sources + attribute;
        selected->offset = source->offset;
        selected->byteLength = source->byteLength;
        selected->bufferLength = source->buffer.length;
        selected->format = source->format;
        selected->count = source->count;
        selected->stride = source->stride;
    }
    FetchFloatProofBatchKey *batchKeys = (void *)(key + 1);
    for (NSUInteger i = 0; i < batches.count; i++) {
        NV2AMetalPGRAPHFetchBatch *batch = batches[i];
        batchKeys[i] = (FetchFloatProofBatchKey){
            batch.firstVertex, batch.firstDecodedVertex,
            batch.physicalVertexCount, batch.inputVertexCount, batch.indexed
        };
    }
    return [data copy];
}
/* This is the natural warm boundary. Declining it executes the original
 * budget/bounds/guard/scan below, without a second summary lookup. Every new
 * result still receives its own exact output/recording binding.
 */
- (BOOL)reuseFloatProofForBatches:
            (NSArray<NV2AMetalPGRAPHFetchBatch *> *)batches
                          sources:(const NV2AMetalAttributeSource *)sources
                        indexData:(NSData *)indexData
                      indexOffset:(NSUInteger)indexOffset
                            first:(NSUInteger)first
                           arrays:(BOOL)arrays
                            lanes:(uint64_t)lanes
{
    if (_floatProofKey.length < sizeof(FetchFloatProofKey))
        return NO;
    const FetchFloatProofKey *key = _floatProofKey.bytes;
    if (!key || _floatProofVram != _surfaces.vram || key->lanes != lanes ||
        key->first != first || key->indexOffset != indexOffset ||
        key->indexLength != indexData.length || key->arrays != arrays ||
        key->batchCount != batches.count)
        return NO;
    if (!arrays) {
        if (!indexData || [indexData isKindOfClass:NSMutableData.class])
            return NO;
        /* Exact immutable view identity remains sufficient after a pure
         * plan eviction. Equal new views additionally need the still-live,
         * freshly checked exact sequence witness and the same scan choice. */
        if (indexData != _floatProofIndices && key->sequence) {
            NSUInteger sequence;
            NSData *owner = [self floatProofSequenceForIndexData:indexData
                                                     indexOffset:indexOffset
                                                           first:first
                                                        sequence:&sequence];
            if (!owner || owner != _floatProofSequence ||
                sequence != key->sequence)
                return NO;
        } else if (indexData != _floatProofIndices) {
            return NO;
        }
    }
    while (lanes) {
        unsigned component = __builtin_ctzll(lanes);
        lanes &= lanes - 1;
        const NV2AMetalAttributeSource *source = &sources[component / 4];
        const FetchFloatProofSourceKey *old = &key->sources[component / 4];
        if (source->buffer != _surfaces.vram || source->offset != old->offset ||
            source->byteLength != old->byteLength ||
            source->buffer.length != old->bufferLength ||
            source->format != old->format || source->count != old->count ||
            source->stride != old->stride)
            return NO;
    }
    const FetchFloatProofBatchKey *batchKeys = (const void *)(key + 1);
    for (NSUInteger i = 0; i < batches.count; i++) {
        NV2AMetalPGRAPHFetchBatch *batch = batches[i];
        const FetchFloatProofBatchKey *old = batchKeys + i;
        if (batch.firstVertex != old->first ||
            batch.firstDecodedVertex != old->prefix ||
            batch.physicalVertexCount != old->physicalCount ||
            batch.inputVertexCount != old->inputCount ||
            batch.indexed != old->indexed)
            return NO;
    }
    const NV2AMetalVRAMReadSpan *spans = _floatProofSpans.bytes;
    NSUInteger count = _floatProofSpans.length / sizeof(*spans);
    BOOL ready = NO;
    uint64_t version;
    uint64_t epoch = _surfaces.gpuWriteEpoch;
    if (epoch == UINT64_MAX || epoch != _floatProofEpoch ||
        ![_surfaces tryIdleCPUReadSpans:spans
                                  count:count
                              completed:&ready
                                  error:NULL] ||
        !ready ||
        ![_surfaces sourceVersionForReadSpans:spans
                                        count:count
                                      version:&version
                                        error:NULL] ||
        version != _floatProofVersion || _surfaces.gpuWriteEpoch != epoch)
        return NO;
    for (NSUInteger i = 0; i < batches.count; i++) {
        NV2AMetalPGRAPHFetchBatch *batch = batches[i];
        if (batch.physicalVertexCount)
            [batch.fetch bindPGRAPHFloatProofSummaries:_floatProofSummaries[i]
                                              laneMask:key->lanes
                                                 first:0
                                                 count:batch.physicalVertexCount
                                              commands:_encodingCommands];
    }
    return YES;
}
/* All pure plans share the existing payload limit. Drop only as much
 * other metadata as necessary; live local ranges keep their own owners. */
- (void)makeRoomForPlanPayload:(NSUInteger)payload kind:(FetchPlanKind)kind
{
    NSUInteger sizes[] = { _indexRanges.length + _indexRangesKey.length,
                           _arrayRanges.length + _arrayRangesKey.length,
                           _readonlyUniqueIndices.length +
                               _readonlyRemap.length,
                           _floatProofPayload };
    sizes[kind] = 0;
    NSUInteger available = FetchPlanMaximumPayload - payload;
    while (sizes[0] + sizes[1] + sizes[2] + sizes[3] > available) {
        NSUInteger largest = 0;
        for (NSUInteger i = 1; i < ARRAY_SIZE(sizes); i++)
            if (sizes[i] > sizes[largest])
                largest = i;
        switch ((FetchPlanKind)largest) {
        case FetchPlanIndexRanges:
            _indexRangesInput = nil;
            _indexRanges = nil;
            _indexRangesKey = nil;
            break;
        case FetchPlanArrayRanges:
            _arrayRanges = nil;
            _arrayRangesKey = nil;
            break;
        case FetchPlanReadonlyIndices:
            [self clearReadonlyIndexPlan];
            break;
        case FetchPlanFloatProof:
            [self clearFloatProofMemo];
            break;
        }
        sizes[largest] = 0;
    }
}
- (NSData *)buildReadonlyIndices:(NV2AMetalPendingInput *)input
                          prefix:(NSUInteger)prefix
                           remap:(NSData **)remap
                         current:(NSUInteger *)current
                        computed:(BOOL *)computed
{
    return fetch_readonly_indices(input, prefix, remap, current, computed);
}
/* This owner was checked against the current input's exact suffix sequence
 * while constructing its fresh read plan, not only the sorted source set. */
- (NSData *)readonlyIndexSequenceForInput:(NV2AMetalPendingInput *)input
                                   prefix:(NSUInteger)prefix
{
    if (![input isMemberOfClass:NV2AMetalPendingInput.class] ||
        input.kind != NV2AMetalInputIndexed || !input.count ||
        input.count > NSUIntegerMax / sizeof(uint32_t) || prefix >= input.count)
        return nil;
    NSData *data = input.indices;
    if ([data isKindOfClass:NSMutableData.class] ||
        data.length != input.count * sizeof(uint32_t) ||
        _indexRangesInput != input || _indexRangesPrefix != prefix ||
        _indexRangesFirstRead != prefix ||
        _indexRangesKey.length != (input.count - prefix) * sizeof(uint32_t))
        return nil;
    return _indexRangesKey;
}

/* Only the new cross-descriptor case enters this matcher. The existing
 * exact input/data identity fast path remains sufficient after plan eviction.
 */
- (BOOL)canReuseReadonlyIndexPlanForInput:(NV2AMetalPendingInput *)input
                                   prefix:(NSUInteger)prefix
{
    if (!_readonlyIndexComputed || _readonlyIndexCount != input.count ||
        _readonlyIndexLength != input.indices.length ||
        _readonlyIndexPrefix != prefix)
        return NO;
    NSData *sequence = [self readonlyIndexSequenceForInput:input prefix:prefix];
    return sequence && sequence == _readonlyIndexSequence;
}

- (NSData *)readonlyIndicesForInput:(NV2AMetalPendingInput *)input
                             prefix:(NSUInteger)prefix
                              remap:(NSData **)remap
                            current:(NSUInteger *)current
{
    *remap = nil;
    NSData *data = input.indices;
    /* Growing immutable views may share bytes but have different lengths.
     * Weak object bindings never pin their possibly larger snapshot backing. */
    BOOL eligible = [input isMemberOfClass:NV2AMetalPendingInput.class];
    if (eligible && _readonlyIndexComputed && _readonlyIndexInput == input &&
        _readonlyIndexData == data && _readonlyIndexCount == input.count &&
        _readonlyIndexLength == data.length && _readonlyIndexPrefix == prefix) {
        if (_readonlyUniqueIndices) {
            *remap = _readonlyRemap;
            *current = _readonlyCurrent;
        }
        return _readonlyUniqueIndices;
    }
    if (eligible && [self canReuseReadonlyIndexPlanForInput:input
                                                   prefix:prefix]) {
        _readonlyIndexInput = input;
        _readonlyIndexData = data;
        if (_readonlyUniqueIndices) {
            *remap = _readonlyRemap;
            *current = _readonlyCurrent;
        }
        return _readonlyUniqueIndices;
    }
    NSData *mapping = nil;
    NSUInteger ordinal = *current;
    BOOL computed = NO;
    NSData *unique = [self buildReadonlyIndices:input
                                         prefix:prefix
                                          remap:&mapping
                                        current:&ordinal
                                       computed:&computed];
    if (!computed || (unique && !mapping))
        return nil;
    if (eligible) {
        if (unique.length <= FetchPlanMaximumPayload &&
            mapping.length <= FetchPlanMaximumPayload - unique.length) {
            [self makeRoomForPlanPayload:unique.length + mapping.length
                                    kind:FetchPlanReadonlyIndices];
            _readonlyUniqueIndices = unique;
            _readonlyRemap = mapping;
            _readonlyCurrent = ordinal;
            _readonlyIndexCount = input.count;
            _readonlyIndexLength = data.length;
            _readonlyIndexPrefix = prefix;
            _readonlyIndexInput = input;
            _readonlyIndexData = data;
            /* Budget eviction may have removed the exact sequence owner.
             * Never retain it here just to preserve an optional future hit. */
            _readonlyIndexSequence =
                [self readonlyIndexSequenceForInput:input prefix:prefix];
            _readonlyIndexComputed = YES;
        } else {
            [self clearReadonlyIndexPlan];
        }
    }
    if (unique) {
        *remap = mapping;
        *current = ordinal;
    }
    return unique;
}
- (void)rememberUniqueReadonlyIndicesForInput:(NV2AMetalPendingInput *)input
                                       prefix:(NSUInteger)prefix
{
    [self clearReadonlyIndexPlan];
    _readonlyIndexCount = input.count;
    _readonlyIndexLength = input.indices.length;
    _readonlyIndexPrefix = prefix;
    _readonlyIndexInput = input;
    _readonlyIndexData = input.indices;
    _readonlyIndexSequence =
        [self readonlyIndexSequenceForInput:input prefix:prefix];
    _readonlyIndexComputed = YES;
}
- (BOOL)prepareRange:(NSUInteger)address
              length:(NSUInteger)length
        readPatterns:(NSMutableData *)readPatterns
               error:(NSError **)error
{
    return
        [self preparePattern:(NV2AMetalVRAMReadPattern){ address, length, 0, 0 }
                readPatterns:readPatterns
                       error:error];
}
- (BOOL)preparePattern:(NV2AMetalVRAMReadPattern)pattern
          readPatterns:(NSMutableData *)readPatterns
                 error:(NSError **)error
{
    NSUInteger address = pattern.address, length = pattern.length;
    if (!length)
        return YES;
    NSUInteger size = _surfaces.vram.length;
    if (address > size || length > size - address)
        return fetch_pgraph_error(error, @"Vertex read exceeds VRAM");
    NSRange pages = fetch_dirty_page_range(pattern, size);
    if (memory_region_test_and_clear_dirty(_d->vram, pages.location,
                                           pages.length, DIRTY_MEMORY_NV2A) &&
        ![_surfaces observeCPUWriteAtAddress:pages.location
                                      length:pages.length
                                       error:error]) {
        memory_region_set_client_dirty(_d->vram, pages.location, pages.length,
                                       DIRTY_MEMORY_NV2A);
        return NO;
    }
    [readPatterns appendBytes:&pattern length:sizeof(pattern)];
    return YES;
}
- (BOOL)mapAttribute:(VertexAttribute *)a
              source:(NV2AMetalAttributeSource *)source
            contexts:(FetchDMAContexts *)contexts
                 max:(uint32_t)maximum
                lane:(FetchReadLane *)lane
               error:(NSError **)error
{
    if (!source->buffer &&
        !dma_attribute_source(_d, a, _surfaces.vram, contexts, source, error))
        return NO;
    unsigned element = nv2a_metal_attribute_size(a->format, a->count);
    uint64_t last = source->stride ? (uint64_t)maximum * source->stride : 0;
    if (!element || last > source->byteLength ||
        element > source->byteLength - last) {
        return fetch_pgraph_error(error,
                                  @"NV2A vertex stream exceeds DMA span");
    }
    *lane = (FetchReadLane){ source->offset, source->stride, element };
    return YES;
}

- (BOOL)appendReadLane:(FetchReadLane)lane
                reads:(NSData *)reads
              current:(uint32_t)current
        appendCurrent:(BOOL)appendCurrent
         readPatterns:(NSMutableData *)readPatterns
                error:(NSError **)error
{
    /* Protect only the suffix and Current; cached XF prefixes read no VRAM. */
    if (!lane.stride)
        return [self prepareRange:lane.offset
                           length:lane.element
                     readPatterns:readPatterns
                            error:error];
    const NSRange *ranges = reads.bytes;
    for (NSUInteger i = 0; i < reads.length / sizeof(*ranges); i++) {
        if (![self preparePattern:fetch_read_pattern(lane, ranges[i])
                     readPatterns:readPatterns
                            error:error])
            return NO;
    }
    if (!appendCurrent)
        return YES;
    return
        [self prepareRange:lane.offset + (NSUInteger)current * lane.stride
                    length:lane.element
              readPatterns:readPatterns
                     error:error];
}
/* This is the only Float-word load boundary. The complete request has already
 * passed its word budget, full source bounds and fresh CPU-read guards. */
- (NSData *)scanFloatProofSources:(const NV2AMetalAttributeSource *)sources
                          indices:(const uint32_t *)indices
                            first:(NSUInteger)first
                            count:(NSUInteger)count
                            lanes:(uint64_t)lanes
{
    NV2AMetalFloatLaneSummary summaries[64] = { 0 };
    while (lanes) {
        unsigned component = __builtin_ctzll(lanes);
        lanes &= lanes - 1;
        const NV2AMetalAttributeSource *source = &sources[component / 4];
        const uint8_t *bytes = (const uint8_t *)source->buffer.contents +
                               source->offset + (component % 4) * 4;
        NV2AMetalFloatLaneSummary summary = { 0 };
        BOOL finite = YES;
        for (NSUInteger i = 0; i < count; i++) {
            NSUInteger index = fetch_float_index(indices, first + i);
            uint32_t bits;
            memcpy(&bits, bytes + index * source->stride, sizeof(bits));
            unsigned exponent = (bits >> 23) & 255u;
            if (exponent == 255u) {
                finite = NO;
                break;
            }
            if (!i) {
                summary.minBits = summary.maxBits = bits;
                summary.minExponent = exponent;
            } else {
                if (fetch_float_order(bits) <
                    fetch_float_order(summary.minBits))
                    summary.minBits = bits;
                if (fetch_float_order(bits) >
                    fetch_float_order(summary.maxBits))
                    summary.maxBits = bits;
                summary.minExponent = MIN(summary.minExponent, exponent);
            }
        }
        summary.flags = finite ? NV2AMetalFloatLaneSummaryFinite : 0;
        if (!finite)
            summary.minExponent = 0;
        summaries[component] = summary;
    }
    return [NSData dataWithBytes:summaries length:sizeof(summaries)];
}

/* Oversized arrays may repeat an identical physical source window. Keep
 * distinct overlapping windows separate: their scan order (including a NaN
 * prefix) is part of the original summary. Optional metadata failure retains
 * the old unknown result. The table has at least two slots per batch and a
 * bounded payload; no unbounded pairwise search or source-word hash occurs.
 * The current 12-byte entries allow at most 2048 batches (including every
 * guest DrawArrays slot); larger private requests keep the existing
 * conservative fallback. */
- (NSMutableData *)floatProofArrayWindowsForBatches:
                       (NSArray<NV2AMetalPGRAPHFetchBatch *> *)batches
                                     maximumRecords:(NSUInteger)maximumRecords
                                            records:(NSUInteger *)records
{
    *records = 0;
    NSUInteger maximumSlots =
        FetchPlanMaximumPayload / sizeof(FetchFloatProofWindow);
    if (!batches.count || batches.count > maximumSlots / 2)
        return nil;
    NSUInteger capacity = 1;
    while (capacity < batches.count * 2) {
        if (capacity > maximumSlots / 2)
            return nil;
        capacity *= 2;
    }
    NSMutableData *data =
        [NSMutableData dataWithLength:capacity * sizeof(FetchFloatProofWindow)];
    if (!data || data.length != capacity * sizeof(FetchFloatProofWindow) ||
        !data.mutableBytes)
        return nil;
    NSUInteger ordinal = 0;
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        NSUInteger count = batch.physicalVertexCount;
        if (!count)
            continue;
        NSUInteger first = batch.firstVertex;
        if (batch.indexed || batch.remap || first > UINT32_MAX ||
            batch.firstDecodedVertex > UINT32_MAX - first)
            return nil;
        first += batch.firstDecodedVertex;
        if (count - 1 > UINT32_MAX - first)
            return nil;
        FetchFloatProofWindow *entry = fetch_float_window(data, first, count);
        if (!entry)
            return nil;
        if (entry->ordinal)
            continue;
        if (count > maximumRecords - *records)
            return nil;
        *records += count;
        *entry = (FetchFloatProofWindow){ (uint32_t)first, (uint32_t)count,
                                          (uint32_t)++ordinal };
    }
    return data;
}
/* Sources are the exact PGRAPH DMA mappings or its private CPU snapshots.
 * All batches are checked together BEFORE any Float word is inspected. */
- (void)captureFloatProofForBatches:
            (NSArray<NV2AMetalPGRAPHFetchBatch *> *)batches
                            sources:(const NV2AMetalAttributeSource *)sources
                            indices:(const uint32_t *)indices
                          indexData:(NSData *)indexData
                        indexOffset:(NSUInteger)indexOffset
                              first:(NSUInteger)first
                             arrays:(BOOL)arrays
             exactIndexedReadRanges:(NSData *)exactIndexedReadRanges
                              lanes:(uint64_t)requested
{
    uint64_t lanes = 0;
    while (requested) {
        unsigned component = __builtin_ctzll(requested);
        requested &= requested - 1;
        const NV2AMetalAttributeSource *source = &sources[component / 4];
        if (source->format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F &&
            source->stride && component % 4 < source->count &&
            source->buffer.storageMode == MTLStorageModeShared)
            lanes |= UINT64_C(1) << component;
    }
    if (!lanes)
        return;
    if ([self reuseFloatProofForBatches:batches sources:sources
                              indexData:indexData indexOffset:indexOffset
                                  first:first arrays:arrays lanes:lanes])
        return;
    /* Keep the original index view/offset as the memo identity even if the
     * bounded oversized path below builds a temporary unique scan list. */
    NSUInteger memoFirst = first;
    NSUInteger maximumRecords =
        NV2AMetalFloatProofMaximumWords / __builtin_popcountll(lanes);
    NSUInteger records = 0;
    BOOL oversized = NO;
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        if (batch.physicalVertexCount > maximumRecords - records) {
            oversized = YES;
            break;
        }
        records += batch.physicalVertexCount;
    }
    g_autofree uint32_t *uniqueIndices = NULL;
    __attribute__((objc_precise_lifetime)) NSMutableData *arrayWindows = nil;
    NSMutableArray *windowSummaries = nil;
    if (oversized && arrays) {
        if (indices)
            return;
        arrayWindows = [self floatProofArrayWindowsForBatches:batches
                                             maximumRecords:maximumRecords
                                                    records:&records];
        windowSummaries = [NSMutableArray array];
        if (!arrayWindows || !windowSummaries)
            return;
    }
    if (oversized && !arrays) {
        /* The same immutable indexed suffix already owns an exact, sorted
         * source-read plan. Summarize its distinct source records, without
         * changing GPU indices, XF executions, or the output coverage below.
         * Small requests retain their original scan path. */
        if (arrays || !indices || batches.count != 1 ||
            !exactIndexedReadRanges.length ||
            exactIndexedReadRanges.length % sizeof(NSRange))
            return;
        const NSRange *ranges = exactIndexedReadRanges.bytes;
        NSUInteger count = exactIndexedReadRanges.length / sizeof(*ranges);
        records = 0;
        uint64_t end = 0;
        for (NSUInteger i = 0; i < count; i++) {
            NSRange range = ranges[i];
            if (!range.length || range.location > UINT32_MAX ||
                range.length - 1 > UINT32_MAX - range.location ||
                (i && range.location < end) ||
                range.length > maximumRecords - records)
                return;
            records += range.length;
            end = (uint64_t)range.location + range.length;
        }
        uniqueIndices = g_try_new(uint32_t, records);
        if (!uniqueIndices)
            return;
        NSUInteger ordinal = 0;
        for (NSUInteger i = 0; i < count; i++)
            for (NSUInteger j = 0; j < ranges[i].length; j++)
                uniqueIndices[ordinal++] = (uint32_t)(ranges[i].location + j);
        indices = uniqueIndices;
        first = 0;
    }
    if (!records)
        return;
    NSUInteger words = records * __builtin_popcountll(lanes);
    NV2AMetalVRAMReadSpan local[32];
    g_autofree NV2AMetalVRAMReadSpan *heap = NULL;
    NV2AMetalVRAMReadSpan *spans = local;
    if (words > ARRAY_SIZE(local)) {
        heap = g_try_new(NV2AMetalVRAMReadSpan, words);
        if (!heap)
            return;
        spans = heap;
    }
    NSUInteger spanCount = 0, nextWindow = 1;
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        if (arrayWindows && batch.physicalVertexCount) {
            FetchFloatProofWindow *entry = fetch_float_window(
                arrayWindows, batch.firstVertex + batch.firstDecodedVertex,
                batch.physicalVertexCount);
            if (!entry || !entry->ordinal)
                return;
            if (entry->ordinal != nextWindow)
                continue;
            nextWindow++;
        }
        NSUInteger start =
            arrays ? batch.firstVertex + batch.firstDecodedVertex : first;
        NSUInteger sourceRecords =
            uniqueIndices ? records : batch.physicalVertexCount;
        for (NSUInteger i = 0; i < sourceRecords; i++) {
            NSUInteger index = fetch_float_index(indices, start + i);
            uint64_t selected = lanes;
            while (selected) {
                unsigned component = __builtin_ctzll(selected);
                selected &= selected - 1;
                const NV2AMetalAttributeSource *source =
                    &sources[component / 4];
                uint64_t relative =
                    (uint64_t)index * source->stride + (component % 4) * 4;
                if (source->offset > source->buffer.length)
                    return;
                NSUInteger length = source->byteLength ?
                                        source->byteLength :
                                        source->buffer.length - source->offset;
                if (relative > length || 4 > length - relative ||
                    relative > source->buffer.length - source->offset ||
                    4 > source->buffer.length - source->offset - relative)
                    return;
                if (source->buffer != _surfaces.vram)
                    continue; /* PGRAPH owns this immutable inline snapshot. */
                NSUInteger address = source->offset + (NSUInteger)relative;
                if (spanCount && spans[spanCount - 1].address +
                                         spans[spanCount - 1].length ==
                                     address)
                    spans[spanCount - 1].length += 4;
                else
                    spans[spanCount++] = (NV2AMetalVRAMReadSpan){ address, 4 };
            }
        }
    }
    BOOL ready = NO;
    if (spanCount && (![_surfaces tryIdleCPUReadSpans:spans
                                                count:spanCount
                                            completed:&ready
                                                error:NULL] ||
                      !ready))
        return;
    NSData *memoKey = nil, *memoSpans = nil, *memoSequence = nil;
    NSMutableArray<NSData *> *memoSummaries = nil;
    uint64_t memoEpoch = 0, memoVersion = 0;
    NSUInteger payload = 0;
    BOOL memo =
        arrays || (indexData && ![indexData isKindOfClass:NSMutableData.class]);
    uint64_t selected = lanes;
    while (memo && selected) {
        unsigned component = __builtin_ctzll(selected);
        selected &= selected - 1;
        memo = sources[component / 4].buffer == _surfaces.vram;
    }
    if (memo && batches.count <=
                    (FetchPlanMaximumPayload - sizeof(FetchFloatProofKey)) /
                        (sizeof(FetchFloatProofBatchKey) +
                         64 * sizeof(NV2AMetalFloatLaneSummary))) {
        payload = sizeof(FetchFloatProofKey) +
                  batches.count * (sizeof(FetchFloatProofBatchKey) +
                                   64 * sizeof(NV2AMetalFloatLaneSummary));
        memo =
            spanCount <= (FetchPlanMaximumPayload - payload) / sizeof(*spans);
        if (memo) {
            payload += spanCount * sizeof(*spans);
            memoKey = [[self floatProofKeyForBatches:batches
                                             sources:sources
                                           indexData:indexData
                                         indexOffset:indexOffset
                                               first:memoFirst
                                              arrays:arrays
                                               lanes:lanes] copy];
            NSUInteger keyLength =
                sizeof(FetchFloatProofKey) +
                batches.count * sizeof(FetchFloatProofBatchKey);
            if (memoKey.length != keyLength)
                memo = NO;
            if (memo) {
                memoSpans = [NSData dataWithBytes:spans
                                           length:spanCount * sizeof(*spans)];
                memoSummaries =
                    [NSMutableArray arrayWithCapacity:batches.count];
                memoEpoch = _surfaces.gpuWriteEpoch;
                /* Capture versions BEFORE the first word load. After a
                 * reader retires, CPU fast-writes publish deferred dirty bits
                 * consumed by the next version query; raw GPU writes also
                 * advance the independent, saturating write epoch. */
                memo = memoSpans && memoSummaries && memoEpoch != UINT64_MAX &&
                       [_surfaces sourceVersionForReadSpans:spans
                                                      count:spanCount
                                                    version:&memoVersion
                                                      error:NULL];
                const FetchFloatProofKey *key = memoKey.bytes;
                if (memo && key->sequence) {
                    NSUInteger sequence;
                    memoSequence =
                        [self floatProofSequenceForIndexData:indexData
                                                 indexOffset:indexOffset
                                                       first:memoFirst
                                                    sequence:&sequence];
                    memo = memoSequence && sequence == key->sequence;
                }
            }
        }
    } else {
        memo = NO;
    }
    /* Reader leases were installed for the same DMA words before this
     * point. Other CPU writes cannot invalidate any batch during the scans. */
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        if (!batch.physicalVertexCount) {
            if (memo) {
                /* This slot is never bound; reuse an already owning object
                 * instead of introducing a fallible empty-data allocation. */
                [memoSummaries addObject:memoKey];
            }
            continue;
        }
        NSUInteger start =
            arrays ? batch.firstVertex + batch.firstDecodedVertex : first;
        FetchFloatProofWindow *window = arrayWindows ?
            fetch_float_window(arrayWindows, start, batch.physicalVertexCount) :
            NULL;
        if (arrayWindows && (!window || !window->ordinal))
            return;
        NSData *summary;
        if (window && window->ordinal <= windowSummaries.count) {
            id saved = windowSummaries[window->ordinal - 1];
            summary = saved == NSNull.null ? nil : saved;
        } else {
            if (window && window->ordinal != windowSummaries.count + 1)
                return;
            summary = [self
                scanFloatProofSources:sources
                              indices:indices
                                first:start
                                count:uniqueIndices ? records :
                                                      batch.physicalVertexCount
                                lanes:lanes];
            if (window)
                [windowSummaries addObject:summary ?: (id)NSNull.null];
        }
        if (summary)
            [batch.fetch bindPGRAPHFloatProofSummaries:summary
                                              laneMask:lanes
                                                 first:0
                                                 count:batch.physicalVertexCount
                                              commands:_encodingCommands];
        if (memo) {
            memo = summary.length == 64 * sizeof(NV2AMetalFloatLaneSummary);
            if (memo)
                [memoSummaries addObject:summary];
        }
    }
    if (memo && _surfaces.gpuWriteEpoch == memoEpoch) {
        NSArray<NSData *> *summaries = [memoSummaries copy];
        if (summaries) {
            [self makeRoomForPlanPayload:payload kind:FetchPlanFloatProof];
            _floatProofKey = memoKey;
            _floatProofSpans = memoSpans;
            _floatProofSummaries = summaries;
            _floatProofIndices = indexData;
            _floatProofSequence = memoSequence;
            _floatProofVram = _surfaces.vram;
            _floatProofVersion = memoVersion;
            _floatProofEpoch = memoEpoch;
            _floatProofPayload = payload;
        }
    }
}

- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)prepareWithError:(NSError **)error
{
    NSArray *batches = [self encodeWithError:error];
    return batches && [self completeWithError:error] ? batches : nil;
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    prepareWithIndexedInput:(NV2AMetalPendingInput *)input
                      error:(NSError **)error
{
    NSArray *batches = [self encodeIndependentSnapshots:NO
                                               prefixes:nil
                                           indexedInput:input
                                         captureCurrent:NO
                                    deduplicateReadonly:NO
                                                  error:error];
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
    encodeIndependentSnapshotsWithIndexedInput:(NV2AMetalPendingInput *)input
                                         error:(NSError **)error
{
    return [self encodeIndependentSnapshots:YES
                                   prefixes:nil
                               indexedInput:input
                             captureCurrent:NO
                        deduplicateReadonly:NO
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
    encodeIndependentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                              indexedInput:(NV2AMetalPendingInput *)input
                       deduplicateReadonly:(BOOL)deduplicateReadonly
                                     error:(NSError **)error
{
    return [self encodeIndependentSnapshotsWithPrefixes:prefixes
                                           indexedInput:input
                                    deduplicateReadonly:deduplicateReadonly
                                    proofAttributeLanes:0
                                                  error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                              indexedInput:(NV2AMetalPendingInput *)input
                       deduplicateReadonly:(BOOL)deduplicateReadonly
                       proofAttributeLanes:(uint64_t)proofAttributeLanes
                                     error:(NSError **)error
{
    return [self encodeIndependentSnapshots:YES
                                   prefixes:prefixes
                               indexedInput:input
                             captureCurrent:NO
                        deduplicateReadonly:deduplicateReadonly
                        proofAttributeLanes:proofAttributeLanes
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
                        deduplicateReadonly:NO
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeInlineCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                                       error:(NSError **)error
{
    return [self encodeInlineCurrentSnapshotsWithPrefixes:prefixes
                                      proofAttributeLanes:0
                                                    error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeInlineCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                         proofAttributeLanes:(uint64_t)proofAttributeLanes
                                       error:(NSError **)error
{
    if (![NV2AMetalPGRAPHFetch canCaptureInlineCurrentForState:_d]) {
        fetch_pgraph_error(error,
                           @"Known inline Current requires owned inline input");
        return nil;
    }
    return [self encodeCurrentSnapshotsWithPrefixes:prefixes
                                       indexedInput:nil
                                deduplicateReadonly:NO
                                proofAttributeLanes:proofAttributeLanes
                                              error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                          indexedInput:(NV2AMetalPendingInput *)input
                                 error:(NSError **)error
{
    return [self encodeCurrentSnapshotsWithPrefixes:prefixes
                                       indexedInput:input
                                deduplicateReadonly:NO
                                              error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                          indexedInput:(NV2AMetalPendingInput *)input
                   deduplicateReadonly:(BOOL)deduplicateReadonly
                                 error:(NSError **)error
{
    return [self encodeCurrentSnapshotsWithPrefixes:prefixes
                                       indexedInput:input
                                deduplicateReadonly:deduplicateReadonly
                                proofAttributeLanes:0
                                              error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeCurrentSnapshotsWithPrefixes:(NSArray<NSNumber *> *)prefixes
                          indexedInput:(NV2AMetalPendingInput *)input
                   deduplicateReadonly:(BOOL)deduplicateReadonly
                   proofAttributeLanes:(uint64_t)proofAttributeLanes
                                 error:(NSError **)error
{
    return [self encodeIndependentSnapshots:NO
                                   prefixes:prefixes
                               indexedInput:input
                             captureCurrent:YES
                        deduplicateReadonly:deduplicateReadonly
                        proofAttributeLanes:proofAttributeLanes
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshots:(BOOL)independent
                      prefixes:(NSArray<NSNumber *> *)prefixes
                  indexedInput:(NV2AMetalPendingInput *)input
                captureCurrent:(BOOL)captureCurrent
           deduplicateReadonly:(BOOL)deduplicateReadonly
                         error:(NSError **)error
{
    return [self encodeIndependentSnapshots:independent
                                   prefixes:prefixes
                               indexedInput:input
                             captureCurrent:captureCurrent
                        deduplicateReadonly:deduplicateReadonly
                        proofAttributeLanes:0
                                      error:error];
}
- (NSArray<NV2AMetalPGRAPHFetchBatch *> *)
    encodeIndependentSnapshots:(BOOL)independent
                      prefixes:(NSArray<NSNumber *> *)prefixes
                  indexedInput:(NV2AMetalPendingInput *)input
                captureCurrent:(BOOL)captureCurrent
           deduplicateReadonly:(BOOL)deduplicateReadonly
           proofAttributeLanes:(uint64_t)proofAttributeLanes
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
    /* Keep these mappings only for this encoding attempt. The later VRAM
     * readability check uses the same source as the GPU fetch. */
    NV2AMetalAttributeSource sources[16] = { 0 };
    FetchCurrentReads currentReads;
    if (captureCurrent &&
        (independent || ![self canCaptureCurrentForInput:input
                                            mappedSources:sources
                                             currentReads:&currentReads])) {
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
    NV2AMetalProgramInput knownCurrent = { 0 };
    /* Keep the inline source alive until fetch registers it on its queue. */
    __attribute__((objc_precise_lifetime)) id<MTLBuffer> inlineBuffer = nil;
    __attribute__((objc_precise_lifetime)) NSData *proofIndexData = nil;
    NSUInteger proofFirst = 0, proofIndexOffset = 0;
    NSMutableArray<NV2AMetalPGRAPHFetchBatch *> *batches = [NSMutableArray new];
    BOOL dmaInput = pg->draw_arrays_length || pg->inline_elements_length;
    BOOL tcg = dmaInput && tcg_enabled();
    __attribute__((objc_precise_lifetime)) NSMutableData *readPatterns =
        dmaInput && !tcg ? [NSMutableData new] : nil;
    NV2AMetalVRAMReadPattern localPatterns[32];
    g_autofree NV2AMetalVRAMReadPattern *heapPatterns = NULL;
    const NV2AMetalVRAMReadPattern *patterns = NULL;
    NSUInteger readCount = 0;
    uint32_t maximum = 0, current = 0;
    __attribute__((objc_precise_lifetime)) NSData *readRanges = nil;
    BOOL exactIndexSuffixRanges = NO;
    NSUInteger currentBatch = 0;
    NSUInteger vertices = 0;
    NSUInteger singlePrefix = 0, captureFirst = 0;
    NV2AMetalFetchResult *last = nil;
    uint16_t update = 0, populated = 0;
    for (unsigned i = 0; i < 16; i++)
        memcpy(sources[i].inline_value, pg->vertex_attributes[i].inline_value,
               16);
    if (pg->draw_arrays_length) {
        /* Only pure range metadata is cached. Build and validate the complete
         * ordered key on the bounded stack, including normalized prefixes and
         * the hooked Current policy, before considering a hit. */
        uint32_t key[1 + 3 * ARRAY_SIZE(pg->draw_arrays_start)];
        key[0] = tcg;
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
            key[1 + i * 3] = first;
            key[2 + i * 3] = count;
            key[3 + i * 3] = (uint32_t)prefix;
        }
        NSUInteger keyBytes = (1 + 3 * pg->draw_arrays_length) * sizeof(*key);
        if (_arrayRangesKey.length == keyBytes &&
            !memcmp(_arrayRangesKey.bytes, key, keyBytes)) {
            readRanges = _arrayRanges;
            maximum = _arrayRangesMaximum;
            currentBatch = _arrayRangesCurrentBatch;
        } else {
            NSMutableData *arrayRanges = [NSMutableData new];
            if (!arrayRanges) {
                fetch_pgraph_error(error, @"Cannot allocate NV2A array ranges");
                goto fail;
            }
            BOOL currentInSuffix = NO;
            for (unsigned i = 0; i < pg->draw_arrays_length; i++) {
                uint32_t first = key[1 + i * 3], count = key[2 + i * 3],
                         prefix = key[3 + i * 3];
                uint32_t end = first + count - 1;
                if (prefix < count) {
                    NSRange range = NSMakeRange((NSUInteger)first + prefix,
                                               count - prefix);
                    [arrayRanges appendBytes:&range length:sizeof(range)];
                }
                if (end >= maximum) {
                    maximum = end;
                    currentBatch = i;
                    currentInSuffix = prefix < count;
                }
            }
            /* In the hooked path, fold Current into the exact sorted ranges
             * once. Adjacent suffix indices can share the same stride record. */
            if (tcg && !currentInSuffix) {
                NSRange range = NSMakeRange(maximum, 1);
                [arrayRanges appendBytes:&range length:sizeof(range)];
            }
            fetch_merge_ranges(arrayRanges);
            /* All plan kinds share one bounded metadata payload budget.
             * Never cache DMA mappings, page versions or reader ownership. */
            NSUInteger payload = keyBytes + arrayRanges.length;
            if (payload <= 64 * 1024) {
                NSData *keySnapshot = [NSData dataWithBytes:key
                                                     length:keyBytes];
                NSData *rangeSnapshot = [arrayRanges copy];
                if (keySnapshot && rangeSnapshot) {
                    [self makeRoomForPlanPayload:payload
                                            kind:FetchPlanArrayRanges];
                    _arrayRangesKey = keySnapshot;
                    _arrayRanges = rangeSnapshot;
                    _arrayRangesMaximum = maximum;
                    _arrayRangesCurrentBatch = currentBatch;
                    readRanges = rangeSnapshot;
                } else {
                    _arrayRangesKey = _arrayRanges = nil;
                    readRanges = arrayRanges;
                }
            } else {
                _arrayRangesKey = nil;
                _arrayRanges = nil;
                readRanges = arrayRanges;
            }
        }
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
        NSUInteger firstRead = tcg ? MIN(singlePrefix, vertices - 1) :
                                     singlePrefix;
        NSUInteger keyBytes = (vertices - firstRead) * sizeof(*indexValues);
        BOOL needsIndexRanges = NO;
        for (unsigned i = 0; i < 16 && !needsIndexRanges; i++)
            needsIndexRanges = pg->vertex_attributes[i].count &&
                               pg->vertex_attributes[i].stride;
        exactIndexSuffixRanges = needsIndexRanges && input &&
                                 singlePrefix < vertices;
        if (!needsIndexRanges) {
            /* Zero-stride lanes register their one element below. Inline
             * lanes read no VRAM. Still validate/map every enabled DMA lane;
             * keep the pure cached plan for a later stride change. */
            readRanges = [NSData data];
        } else if (input && _indexRanges && _indexRangesPrefix == singlePrefix &&
            _indexRangesFirstRead == firstRead &&
            (_indexRangesInput == input ||
             (_indexRangesKey && _indexRangesKey.length == keyBytes &&
              (!keyBytes || !memcmp(_indexRangesKey.bytes,
                                    indexValues + firstRead, keyBytes))))) {
            readRanges = _indexRanges;
            _indexRangesInput = input;
        } else {
            readRanges = fetch_index_ranges(indexValues + firstRead,
                                            vertices - firstRead);
            if (!readRanges) {
                fetch_pgraph_error(error, @"Cannot allocate NV2A index ranges");
                goto fail;
            }
            /* Recheck DMA limits, dirty pages and dependencies on every use.
             * Keep the weak identity fast path without pinning a full index
             * snapshot. Optional suffix bytes allow equal new descriptors to
             * reuse the plan within the same combined 64KiB payload budget. */
            if (input && readRanges.length <= 64 * 1024) {
                NSData *rangeSnapshot = [readRanges copy];
                if (rangeSnapshot) {
                    _indexRanges = rangeSnapshot;
                    _indexRangesInput = input;
                    _indexRangesPrefix = singlePrefix;
                    _indexRangesFirstRead = firstRead;
                    _indexRangesKey =
                        keyBytes <= 64 * 1024 - rangeSnapshot.length ?
                            [NSData dataWithBytes:indexValues + firstRead
                                           length:keyBytes] : nil;
                    NSUInteger payload =
                        rangeSnapshot.length + _indexRangesKey.length;
                    [self makeRoomForPlanPayload:payload
                                            kind:FetchPlanIndexRanges];
                    readRanges = rangeSnapshot;
                } else {
                    _indexRangesInput = nil;
                    _indexRanges = nil;
                    _indexRangesKey = nil;
                }
            } else {
                _indexRangesInput = nil;
                _indexRanges = nil;
                _indexRangesKey = nil;
            }
        }
        captureFirst =
            captureCurrent ? singlePrefix : MIN(singlePrefix, vertices - 1);
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
            update |= 1u << i;
            if (captureFirst == vertices) {
                memcpy(knownCurrent.attributes[i],
                       a->inline_buffer + (vertices - 1) * 4, 16);
            }
        }
        populated = update;
        if (update && captureFirst < vertices) {
            /* Store each populated attribute's suffix in its own bounded
             * slice of a single shared allocation. */
            NSUInteger length = (vertices - captureFirst) * 16;
            inlineBuffer = [_surfaces.commands.device
                newBufferWithLength:length * __builtin_popcount(update)
                            options:MTLResourceStorageModeShared];
            if (!inlineBuffer) {
                fetch_pgraph_error(error,
                                   @"Cannot snapshot NV2A inline buffer");
                goto fail;
            }
            uint8_t *bytes = inlineBuffer.contents;
            NSUInteger offset = 0;
            for (unsigned i = 0; i < 16; i++) {
                if (!(update & (1u << i)))
                    continue;
                const float *source = pg->vertex_attributes[i].inline_buffer;
                memcpy(bytes + offset, source + captureFirst * 4, length);
                if (captureCurrent)
                    memcpy(knownCurrent.attributes[i],
                           bytes + offset + length - 16, 16);
                sources[i].buffer = inlineBuffer;
                sources[i].offset = offset;
                sources[i].byteLength = length;
                sources[i].count = 4;
                sources[i].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
                sources[i].stride = 16;
                offset += length;
            }
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
        if (captureFirst < vertices)
            inlineBuffer = [_surfaces.commands.device
                newBufferWithBytes:(const uint8_t *)pg->inline_array +
                                   captureFirst * stride
                            length:(vertices - captureFirst) * stride
                           options:MTLResourceStorageModeShared];
        if (!inlineBuffer && captureFirst < vertices) {
            fetch_pgraph_error(error,
                               @"Cannot snapshot packed NV2A inline data");
            goto fail;
        }
        for (unsigned i = 0; i < 16; i++) {
            VertexAttribute *a = &pg->vertex_attributes[i];
            if (!a->count)
                continue;
            if (inlineBuffer) {
                sources[i].buffer = inlineBuffer;
                sources[i].offset = offsets[i];
                sources[i].byteLength = inlineBuffer.length - offsets[i];
                sources[i].format = a->format;
                sources[i].count = a->count;
                sources[i].stride = (unsigned)stride;
            }
            if (captureCurrent) {
                const uint8_t *last =
                    inlineBuffer ? (const uint8_t *)inlineBuffer.contents +
                                       inlineBuffer.length - stride :
                                   (const uint8_t *)pg->inline_array +
                                       (vertices - 1) * stride;
                inline_current_value(last + offsets[i], a->format, a->count,
                                     knownCurrent.attributes[i]);
            }
            update |= 1u << i;
        }
    }
    if (dmaInput) {
        BOOL separateCurrent = !tcg;
        const NSRange *ranges = readRanges.bytes;
        for (NSUInteger i = 0;
             separateCurrent && i < readRanges.length / sizeof(*ranges); i++)
            separateCurrent = !NSLocationInRange(current, ranges[i]);
        FetchReadLane lanes[16];
        unsigned laneCount = 0;
        FetchDMAContexts contexts = { 0 };
        for (unsigned i = 0; i < 16; i++) {
            VertexAttribute *a = &pg->vertex_attributes[i];
            if (!a->count)
                continue;
            FetchReadLane lane;
            if (![self mapAttribute:a
                             source:&sources[i]
                           contexts:&contexts
                                max:maximum
                               lane:&lane
                              error:error])
                goto fail;
            if (tcg)
                lanes[laneCount++] = lane;
            else if (![self appendReadLane:lane
                                     reads:readRanges
                                   current:current
                             appendCurrent:separateCurrent
                              readPatterns:readPatterns
                                     error:error])
                goto fail;
            update |= 1u << i;
        }
        if (tcg) {
            /* Each lane already passed its DMA bounds check at the largest
             * input index. Build the exact records in one bounded array. */
            laneCount = fetch_merge_read_lanes(lanes, laneCount);
            NSUInteger rangeCount = readRanges.length / sizeof(*ranges);
            for (unsigned i = 0; i < laneCount; i++)
                readCount += lanes[i].stride ? rangeCount : 1;
            NV2AMetalVRAMReadPattern *output = localPatterns;
            if (readCount > ARRAY_SIZE(localPatterns)) {
                heapPatterns = g_try_new(NV2AMetalVRAMReadPattern, readCount);
                if (!heapPatterns) {
                    fetch_pgraph_error(error, @"Cannot allocate vertex read ranges");
                    goto fail;
                }
                output = heapPatterns;
            }
            patterns = output;
            for (unsigned i = 0; i < laneCount; i++) {
                FetchReadLane lane = lanes[i];
                if (!lane.stride) {
                    *output++ = fetch_read_pattern(lane, NSMakeRange(0, 1));
                    continue;
                }
                for (NSUInteger j = 0; j < rangeCount; j++)
                    *output++ = fetch_read_pattern(lane, ranges[j]);
            }
        } else {
            patterns = readPatterns.bytes;
            readCount = readPatterns.length / sizeof(*patterns);
        }
    }
    /* TCG hooks already own coherence. Clear the shared dirty client once
     * per page run, without widening the exact GPU read patterns below. */
    if (readCount && tcg)
        fetch_clear_tcg_dirty(_d->vram, _surfaces.vram.length, patterns,
                              readCount);
    /* Sample versions before registering this reader: a later writer must
     * never lend its newer version to an older GPU/host Current value. */
    if (dmaInput) {
        FetchConstantReads *reads = &_encodedConstantReads;
        reads->count = 0;
        for (unsigned i = 0; i < 16; i++) {
            const NV2AMetalAttributeSource *s = &sources[i];
            if (!s->stride && nv2a_metal_attribute_size(s->format, s->count) &&
                s->buffer == _surfaces.vram) {
                NSUInteger row = reads->count++;
                reads->spans[row] = (NV2AMetalVRAMReadSpan){
                    s->offset, nv2a_metal_attribute_size(s->format, s->count)
                };
                reads->attributes[row] = i;
                reads->components[row] = s->count;
                reads->formats[row] = s->format;
            }
        }
        if (reads->count &&
            ![_surfaces sourceVersionsForReadSpans:reads->spans count:reads->count
                                          versions:reads->versions
                                     firstSurface:NULL error:NULL])
            reads->count = 0;
    }
    if (independent) {
        if (!_independentCommands) {
            _independentCommands = [[NV2AMetalCommands alloc]
                initWithDevice:_surfaces.commands.device
                         error:error];
            if (!_independentCommands)
                goto fail;
        }
        NV2AMetalIndependentReads *reads = nil;
        if (![_surfaces prepareGPUReadPatterns:patterns
                                         count:readCount
                           independentCommands:_independentCommands
                                         reads:&reads
                                         error:error])
            goto fail;
        _independentReads = reads;
        if (reads)
            _encodingCommands = _independentCommands;
    } else if (![_surfaces prepareGPUReadPatterns:patterns
                                            count:readCount
                                            error:error]) {
        goto fail;
    }
    if (captureCurrent && dmaInput) {
        /* Source read guards are installed before this copy. The
         * selected bytes must still be CPU-readable; downloads/writers
         * never become host Current speculatively. */
        BOOL ready = NO;
        if (![_surfaces tryIdleCPUReadSpans:currentReads.spans
                                         count:currentReads.count
                                  completed:&ready error:error])
            goto fail;
        if (!ready) {
            fetch_pgraph_error(error, @"Captured Current source is not CPU-readable");
            goto fail;
        }
        for (unsigned i = 0, span = 0; i < 16; i++) {
            if (!sources[i].count)
                continue;
            inline_current_value(
                (const uint8_t *)sources[i].buffer.contents +
                    currentReads.spans[span++].address,
                sources[i].format, sources[i].count,
                knownCurrent.attributes[i]);
        }
    }
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
                                          prefix:prefix
                                           remap:nil]];
        }
    } else {
        id<MTLBuffer> indices = nil;
        NSUInteger indexOffset = 0;
        NSData *remap = nil, *uniqueIndices = nil;
        NSUInteger fetchCurrent = vertices - captureFirst - 1;
        if (deduplicateReadonly && input && singlePrefix < vertices) {
            BOOL knownPlan = _readonlyIndexComputed &&
                ((_readonlyIndexInput == input &&
                  _readonlyIndexData == input.indices &&
                  _readonlyIndexCount == input.count &&
                  _readonlyIndexLength == input.indices.length &&
                  _readonlyIndexPrefix == singlePrefix) ||
                 [self canReuseReadonlyIndexPlanForInput:input
                                                prefix:singlePrefix]);
            if (!knownPlan && exactIndexSuffixRanges &&
                fetch_ranges_are_unique(readRanges, vertices - singlePrefix))
                [self rememberUniqueReadonlyIndicesForInput:input
                                                     prefix:singlePrefix];
            uniqueIndices = [self readonlyIndicesForInput:input
                                                   prefix:singlePrefix
                                                    remap:&remap
                                                  current:&fetchCurrent];
        }
        NSUInteger fetchCount = uniqueIndices ? uniqueIndices.length / 4 :
                                               vertices - captureFirst;
        NSUInteger fetchPrefix = uniqueIndices ? 0 : singlePrefix - captureFirst;
        proofFirst = fetchPrefix;
        if (proofAttributeLanes && pg->inline_elements_length) {
            if ([input isMemberOfClass:NV2AMetalPendingInput.class] &&
                ![input.indices isKindOfClass:NSMutableData.class])
                proofIndexData = uniqueIndices ?: input.indices;
            else
                proofAttributeLanes = 0;
            proofIndexOffset = uniqueIndices ? 0 : captureFirst;
        }
        if (pg->inline_elements_length && captureFirst < vertices) {
            const uint32_t *values =
                input ? input.indices.bytes : pg->inline_elements;
            /* Copy only the logical suffix to its actual producer recording. */
            indices = [_encodingCommands
                uploadBytes:uniqueIndices ? uniqueIndices.bytes :
                                            values + captureFirst
                     length:fetchCount * sizeof(*values)
                     offset:&indexOffset
                      error:error];
            if (!indices)
                goto fail;
        }
        NV2AMetalFetchResult *f =
            [_fetch encodeSources:sources
                            count:fetchCount
                      firstVertex:0
                          indices:indices
                      indexOffset:indexOffset
                        indexSize:indices ? 4 : 0
                    currentVertex:captureCurrent ? NSNotFound : fetchCurrent
                   skippingPrefix:fetchPrefix
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
                                      prefix:singlePrefix
                                       remap:remap]];
    }
    if (proofAttributeLanes) {
        const uint32_t *proofIndices = proofIndexData.bytes;
        if (proofIndices)
            proofIndices += proofIndexOffset;
        /* Nonempty indexed suffixes have firstRead == singlePrefix, so
         * readRanges describes exactly the same source set as this full,
         * unremapped output batch, including the guest index used by Current.
         * A fully cached suffix or a readonly remap must not borrow this plan.
         */
        NSData *exactIndexedReadRanges = nil;
        if (pg->inline_elements_length && batches.count == 1 &&
            [input isMemberOfClass:NV2AMetalPendingInput.class] &&
            proofIndexData == input.indices &&
            ![proofIndexData isKindOfClass:NSMutableData.class] &&
            singlePrefix < vertices && proofIndexOffset == singlePrefix &&
            !proofFirst) {
            NV2AMetalPGRAPHFetchBatch *batch = batches[0];
            if (batch.indexed && !batch.remap &&
                batch.inputVertexCount == vertices &&
                batch.firstDecodedVertex == singlePrefix &&
                batch.physicalVertexCount == vertices - singlePrefix)
                exactIndexedReadRanges = readRanges;
        }
        [self captureFloatProofForBatches:batches
                                  sources:sources
                                  indices:proofIndices
                                indexData:proofIndexData
                              indexOffset:proofIndexOffset
                                    first:proofFirst
                                   arrays:pg->draw_arrays_length != 0
                   exactIndexedReadRanges:exactIndexedReadRanges
                                    lanes:proofAttributeLanes];
    }
    if (captureCurrent) {
        _capturedCurrent = [NSData dataWithBytes:&knownCurrent
                                        length:sizeof(knownCurrent)];
        if (dmaInput)
            for (NV2AMetalPGRAPHFetchBatch *batch in batches)
                [batch.fetch bindPGRAPHCurrentProof:_capturedCurrent
                                           commands:_encodingCommands];
    }
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
    [self rememberConstantCurrent:values reads:&_encodedConstantReads];
    _encodedConstantReads.count = 0;
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
    FetchConstantReads constantReads = _encodedConstantReads;
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
    _encodedConstantReads.count = 0;
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
    /* A later host XF encoding error can require completed prefix retention.
     * That path still validates every GPU suffix fault above, but Current is
     * the same bounded immutable host capture used by no-wait completion. */
    const NV2AMetalProgramInput *values =
        capturedCurrent ?
            capturedCurrent.bytes :
            (const NV2AMetalProgramInput *)last.attributes.contents +
                last.vertexCount;
    [self rememberConstantCurrent:values reads:&constantReads];
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
