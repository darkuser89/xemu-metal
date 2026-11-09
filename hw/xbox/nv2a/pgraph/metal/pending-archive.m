/* Canonical pending-vertex transport. SPDX-License-Identifier:
 * GPL-2.0-only OR GPL-3.0-only */
#import "pending-archive.h"
#include <stdint.h>
#include <string.h>
/* Version 1 entries contain kind/first/logicalCount/guestIndexCount followed
 * by guest indices and linear vertices. Version 2 appends physicalCount and
 * remapCount to each entry's metadata, then stores guest indices, physical
 * vertices and remap ordinals. Every word is BE32. Version 2 requires at least
 * one indexed stream; all-linear streams retain the canonical version 1 wire. */
enum {
    ArchiveMagic = 0x4d345650u,
    ArchiveVersionLinear = 1,
    ArchiveVersionIndexed = 2,
    ArchiveMaxInputs = 1250,
    ArchiveMaxVertices = 524287
};
_Static_assert(sizeof(NV2AMetalVertex) == 244,
               "Version1 transformed vertex ABI");
static BOOL archive_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pending-archive"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
static void put_word(NSMutableData *data, uint32_t value)
{
    uint8_t b[] = { value >> 24, value >> 16, value >> 8, value };
    [data appendBytes:b length:4];
}
static uint32_t get_word(const uint8_t *b)
{
    return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 |
           b[3];
}
static void put_raw(NSMutableData *data, NSData *raw)
{
    for (NSUInteger i = 0; i < raw.length; i += 4) {
        uint32_t word;
        memcpy(&word, (const uint8_t *)raw.bytes + i, 4);
        put_word(data, word);
    }
}
static NSData *get_raw(const uint8_t *b, NSUInteger length)
{
    NSMutableData *raw = [NSMutableData dataWithLength:length];
    for (NSUInteger i = 0; i < length; i += 4) {
        uint32_t word = get_word(b + i);
        memcpy((uint8_t *)raw.mutableBytes + i, &word, 4);
    }
    return [raw copy];
}
@implementation NV2AMetalPendingArchive {
    NSUInteger _limit;
}
- (instancetype)initWithInputs:(NSArray<NV2AMetalPendingInput *> *)inputs
                      vertices:(NSArray<NSData *> *)vertices
                         limit:(NSUInteger)limit
                         error:(NSError **)error
{
    if (!vertices || vertices.count > ArchiveMaxInputs) {
        archive_error(error, @"Invalid pending archive entries");
        return nil;
    }
    NSMutableArray<NSData *> *remaps =
        [NSMutableArray arrayWithCapacity:vertices.count];
    for (NSUInteger i = 0; i < vertices.count; i++)
        [remaps addObject:[NSData data]];
    return [self initWithInputs:inputs
               physicalVertices:vertices
                         remaps:remaps
                          limit:limit
                          error:error];
}
- (instancetype)initWithInputs:(NSArray<NV2AMetalPendingInput *> *)inputs
              physicalVertices:(NSArray<NSData *> *)physicalVertices
                        remaps:(NSArray<NSData *> *)remaps
                         limit:(NSUInteger)limit
                         error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!inputs || !physicalVertices || !remaps || !limit ||
        limit > ArchiveMaxVertices || inputs.count > ArchiveMaxInputs ||
        inputs.count != physicalVertices.count ||
        inputs.count != remaps.count) {
        archive_error(error, @"Invalid pending archive entries or limit");
        return nil;
    }
    NSUInteger total = 0;
    NSMutableArray<NSData *> *physicalCopy = [NSMutableArray new],
                             *remapCopy = [NSMutableArray new];
    for (NSUInteger i = 0; i < inputs.count; i++) {
        NV2AMetalPendingInput *input = inputs[i];
        id physical = physicalVertices[i], remap = remaps[i];
        if (![input isKindOfClass:NV2AMetalPendingInput.class] ||
            ![physical isKindOfClass:NSData.class] ||
            ![remap isKindOfClass:NSData.class] || !input.count ||
            input.count > limit - total) {
            archive_error(error,
                          @"Invalid pending archive stream or logical count");
            return nil;
        }
        NSData *vertices = [physical copy], *mapping = [remap copy];
        NSUInteger physicalCount = vertices.length / sizeof(NV2AMetalVertex);
        if (!physicalCount || vertices.length % sizeof(NV2AMetalVertex) ||
            physicalCount > input.count ||
            (mapping.length ? mapping.length != input.count * sizeof(uint32_t) :
                              physicalCount != input.count)) {
            archive_error(
                error,
                @"Invalid pending archive physical length or remap count");
            return nil;
        }
        for (NSUInteger n = 0; n < mapping.length / sizeof(uint32_t); n++) {
            uint32_t ordinal;
            memcpy(&ordinal,
                   (const uint8_t *)mapping.bytes + n * sizeof(ordinal),
                   sizeof(ordinal));
            if (ordinal >= physicalCount) {
                archive_error(error,
                              @"Pending archive remap exceeds physical range");
                return nil;
            }
        }
        total += input.count;
        [physicalCopy addObject:vertices];
        [remapCopy addObject:mapping];
    }
    _inputs = [inputs copy];
    _physicalVertices = [physicalCopy copy];
    _remaps = [remapCopy copy];
    _limit = limit;
    return self;
}
- (NSArray<NSData *> *)vertices
{
    BOOL indexed = NO;
    for (NSData *remap in _remaps)
        indexed |= remap.length != 0;
    if (!indexed)
        return _physicalVertices;
    NSMutableArray<NSData *> *expanded =
        [NSMutableArray arrayWithCapacity:_inputs.count];
    for (NSUInteger i = 0; i < _inputs.count; i++) {
        NSData *remap = _remaps[i], *physical = _physicalVertices[i];
        if (!remap.length) {
            [expanded addObject:physical];
            continue;
        }
        NSUInteger stride = sizeof(NV2AMetalVertex);
        NSMutableData *logical =
            [NSMutableData dataWithLength:_inputs[i].count * stride];
        for (NSUInteger n = 0; n < _inputs[i].count; n++) {
            uint32_t ordinal;
            memcpy(&ordinal, (const uint8_t *)remap.bytes + n * sizeof(ordinal),
                   sizeof(ordinal));
            memcpy((uint8_t *)logical.mutableBytes + n * stride,
                   (const uint8_t *)physical.bytes + ordinal * stride, stride);
        }
        [expanded addObject:[logical copy]];
    }
    return [expanded copy];
}
- (NSData *)data
{
    NSMutableData *data = [NSMutableData new];
    NSUInteger total = 0;
    BOOL indexed = NO;
    for (NV2AMetalPendingInput *input in _inputs)
        total += input.count;
    for (NSData *remap in _remaps)
        indexed |= remap.length != 0;
    put_word(data, ArchiveMagic);
    put_word(data, indexed ? ArchiveVersionIndexed : ArchiveVersionLinear);
    put_word(data, sizeof(NV2AMetalVertex));
    put_word(data, (uint32_t)_inputs.count);
    put_word(data, (uint32_t)total);
    for (NSUInteger i = 0; i < _inputs.count; i++) {
        NV2AMetalPendingInput *input = _inputs[i];
        put_word(data, input.kind);
        put_word(data, (uint32_t)input.first);
        put_word(data, (uint32_t)input.count);
        put_word(data, (uint32_t)(input.indices.length / 4));
        if (indexed) {
            put_word(data, (uint32_t)(_physicalVertices[i].length /
                                      sizeof(NV2AMetalVertex)));
            put_word(data, (uint32_t)(_remaps[i].length / sizeof(uint32_t)));
        }
        put_raw(data, input.indices);
        put_raw(data, _physicalVertices[i]);
        if (indexed)
            put_raw(data, _remaps[i]);
    }
    return [data copy];
}
- (instancetype)initWithData:(NSData *)data
                       limit:(NSUInteger)limit
                       error:(NSError **)error
{
    if (!data || data.length < 20 || !limit || limit > ArchiveMaxVertices) {
        archive_error(error, @"Invalid pending archive size");
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    uint32_t version = get_word(bytes + 4), records = get_word(bytes + 12),
             expected = get_word(bytes + 16);
    BOOL indexed = version == ArchiveVersionIndexed;
    NSUInteger metadataSize = indexed ? 24 : 16;
    if (get_word(bytes) != ArchiveMagic ||
        (version != ArchiveVersionLinear && !indexed) ||
        get_word(bytes + 8) != sizeof(NV2AMetalVertex) ||
        records > ArchiveMaxInputs || expected > limit ||
        data.length > 20 + ArchiveMaxInputs * metadataSize +
                          (NSUInteger)ArchiveMaxVertices *
                              (sizeof(NV2AMetalVertex) + (indexed ? 8 : 4))) {
        archive_error(error, @"Invalid pending archive header");
        return nil;
    }
    NSUInteger offset = 20, total = 0;
    BOOL hasRemap = NO;
    NSMutableArray *inputs = [NSMutableArray new],
                   *vertices = [NSMutableArray new],
                   *remaps = [NSMutableArray new];
    for (unsigned i = 0; i < records; i++) {
        if (data.length - offset < metadataSize) {
            archive_error(error, @"Truncated pending archive entry");
            return nil;
        }
        unsigned kind = get_word(bytes + offset),
                 first = get_word(bytes + offset + 4),
                 count = get_word(bytes + offset + 8),
                 indices = get_word(bytes + offset + 12),
                 physical = indexed ? get_word(bytes + offset + 16) : count,
                 remap = indexed ? get_word(bytes + offset + 20) : 0;
        offset += metadataSize;
        if (!count || count > limit - total || !physical || physical > count ||
            (remap ? remap != count : physical != count) ||
            (kind == NV2AMetalInputIndexed ? indices != count : indices != 0) ||
            (kind != NV2AMetalInputArrays && first) ||
            indices > (data.length - offset) / sizeof(uint32_t)) {
            archive_error(error, @"Invalid pending archive entry metadata");
            return nil;
        }
        NSData *indexBytes =
            get_raw(bytes + offset, (NSUInteger)indices * sizeof(uint32_t));
        offset += (NSUInteger)indices * sizeof(uint32_t);
        if (physical > (data.length - offset) / sizeof(NV2AMetalVertex)) {
            archive_error(error, @"Truncated pending archive vertices");
            return nil;
        }
        NV2AMetalPendingInput *input =
            kind == NV2AMetalInputArrays ?
                [NV2AMetalPendingInput arraysFrom:first count:count] :
            kind == NV2AMetalInputIndexed ?
                [NV2AMetalPendingInput indexed:indexBytes] :
                [NV2AMetalPendingInput inlineKind:kind count:count];
        if (!input) {
            archive_error(error, @"Invalid pending archive input kind/range");
            return nil;
        }
        NSUInteger length = (NSUInteger)physical * sizeof(NV2AMetalVertex);
        NSData *physicalBytes = get_raw(bytes + offset, length);
        offset += length;
        if (remap > (data.length - offset) / sizeof(uint32_t)) {
            archive_error(error, @"Truncated pending archive remap");
            return nil;
        }
        NSData *mapping =
            get_raw(bytes + offset, (NSUInteger)remap * sizeof(uint32_t));
        for (NSUInteger n = 0; n < remap; n++) {
            if (get_word(bytes + offset + n * sizeof(uint32_t)) >= physical) {
                archive_error(error,
                              @"Pending archive remap exceeds physical range");
                return nil;
            }
        }
        hasRemap |= remap != 0;
        [vertices addObject:physicalBytes];
        [remaps addObject:mapping];
        [inputs addObject:input];
        offset += (NSUInteger)remap * sizeof(uint32_t);
        total += count;
    }
    if (offset != data.length || total != expected || (indexed && !hasRemap)) {
        archive_error(error, @"Pending archive trailing bytes, total mismatch "
                             @"or noncanonical version");
        return nil;
    }
    return [self initWithInputs:inputs
               physicalVertices:vertices
                         remaps:remaps
                          limit:limit
                          error:error];
}
- (NV2AMetalPendingJournal *)CPUJournal
{
    NV2AMetalPendingJournal *journal =
        [[NV2AMetalPendingJournal alloc] initWithLimit:_limit];
    NV2AMetalPendingPlan *plan = [journal planInputs:_inputs
                                 preservingLastArray:NO
                                               error:NULL];
    NSArray<NSData *> *vertices = self.vertices;
    NSMutableArray *spans = [NSMutableArray new];
    for (NSUInteger i = 0; i < _inputs.count; i++)
        [spans addObject:[NV2AMetalPendingSpan resource:vertices[i]
                                                  first:0
                                                  count:_inputs[i].count]];
    NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                 suffixes:spans
                                                    error:NULL];
    if (!update || ![journal commitUpdate:update error:NULL])
        return nil;
    return journal;
}
@end
