/* Canonical pending-vertex transport. SPDX-License-Identifier:
 * GPL-2.0-only OR GPL-3.0-only */
#import "pending-archive.h"
#include <stdint.h>
#include <string.h>
enum {
    ArchiveMagic = 0x4d345650u,
    ArchiveVersion = 1,
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
    self = [super init];
    if (!self)
        return nil;
    if (!inputs || !vertices || !limit || limit > ArchiveMaxVertices ||
        inputs.count > ArchiveMaxInputs || inputs.count != vertices.count) {
        archive_error(error, @"Invalid pending archive entries or limit");
        return nil;
    }
    NSUInteger total = 0;
    NSMutableArray *copy = [NSMutableArray new];
    for (NSUInteger i = 0; i < inputs.count; i++) {
        NV2AMetalPendingInput *input = inputs[i];
        id value = vertices[i];
        if (![input isKindOfClass:NV2AMetalPendingInput.class] ||
            ![value isKindOfClass:NSData.class] || !input.count ||
            input.count > limit - total ||
            ((NSData *)value).length != input.count * sizeof(NV2AMetalVertex)) {
            archive_error(error, @"Invalid pending archive stream length");
            return nil;
        }
        total += input.count;
        [copy addObject:[value copy]];
    }
    _inputs = [inputs copy];
    _vertices = [copy copy];
    _limit = limit;
    return self;
}
- (NSData *)data
{
    NSMutableData *data = [NSMutableData new];
    NSUInteger total = 0;
    for (NV2AMetalPendingInput *input in _inputs)
        total += input.count;
    put_word(data, ArchiveMagic);
    put_word(data, ArchiveVersion);
    put_word(data, sizeof(NV2AMetalVertex));
    put_word(data, (uint32_t)_inputs.count);
    put_word(data, (uint32_t)total);
    for (NSUInteger i = 0; i < _inputs.count; i++) {
        NV2AMetalPendingInput *input = _inputs[i];
        put_word(data, input.kind);
        put_word(data, (uint32_t)input.first);
        put_word(data, (uint32_t)input.count);
        put_word(data, (uint32_t)(input.indices.length / 4));
        put_raw(data, input.indices);
        put_raw(data, _vertices[i]);
    }
    return [data copy];
}
- (instancetype)initWithData:(NSData *)data
                       limit:(NSUInteger)limit
                       error:(NSError **)error
{
    if (!data || data.length < 20 || !limit || limit > ArchiveMaxVertices ||
        data.length > 20 + ArchiveMaxInputs * 16 +
                          (NSUInteger)ArchiveMaxVertices *
                              (sizeof(NV2AMetalVertex) + 4)) {
        archive_error(error, @"Invalid pending archive size");
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    uint32_t records = get_word(bytes + 12), expected = get_word(bytes + 16);
    if (get_word(bytes) != ArchiveMagic ||
        get_word(bytes + 4) != ArchiveVersion ||
        get_word(bytes + 8) != sizeof(NV2AMetalVertex) ||
        records > ArchiveMaxInputs || expected > limit) {
        archive_error(error, @"Invalid pending archive header");
        return nil;
    }
    NSUInteger offset = 20, total = 0;
    NSMutableArray *inputs = [NSMutableArray new],
                   *vertices = [NSMutableArray new];
    for (unsigned i = 0; i < records; i++) {
        if (data.length - offset < 16) {
            archive_error(error, @"Truncated pending archive entry");
            return nil;
        }
        unsigned kind = get_word(bytes + offset),
                 first = get_word(bytes + offset + 4),
                 count = get_word(bytes + offset + 8),
                 indices = get_word(bytes + offset + 12);
        offset += 16;
        if (!count || count > limit - total ||
            (kind == NV2AMetalInputIndexed ? indices != count : indices != 0) ||
            (kind != NV2AMetalInputArrays && first) ||
            indices > (data.length - offset) / 4) {
            archive_error(error, @"Invalid pending archive entry metadata");
            return nil;
        }
        NSData *indexBytes = get_raw(bytes + offset, (NSUInteger)indices * 4);
        offset += (NSUInteger)indices * 4;
        if (count > (data.length - offset) / sizeof(NV2AMetalVertex)) {
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
        NSUInteger length = (NSUInteger)count * sizeof(NV2AMetalVertex);
        [vertices addObject:get_raw(bytes + offset, length)];
        [inputs addObject:input];
        offset += length;
        total += count;
    }
    if (offset != data.length || total != expected) {
        archive_error(error,
                      @"Pending archive trailing bytes or total mismatch");
        return nil;
    }
    return [self initWithInputs:inputs
                       vertices:vertices
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
    NSMutableArray *spans = [NSMutableArray new];
    for (NSUInteger i = 0; i < _inputs.count; i++)
        [spans addObject:[NV2AMetalPendingSpan resource:_vertices[i]
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
