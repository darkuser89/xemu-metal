/* Pending transformed-stream bookkeeping.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "pending-journal.h"
#include <stdint.h>
#include <string.h>
static BOOL journal_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pending-journal"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@interface NV2AMetalPendingInput ()
@property(nonatomic, weak) NV2AMetalPendingInput *verifiedPrefix;
- (instancetype)initKind:(NV2AMetalInputKind)kind
                   first:(NSUInteger)first
                   count:(NSUInteger)count
                 indices:(NSData *)indices
          verifiedPrefix:(NV2AMetalPendingInput *)prefix;
@end
@implementation NV2AMetalPendingInput
- (instancetype)initKind:(NV2AMetalInputKind)kind
                   first:(NSUInteger)first
                   count:(NSUInteger)count
                 indices:(NSData *)indices
          verifiedPrefix:(NV2AMetalPendingInput *)prefix
{
    self = [super init];
    if (self) {
        _kind = kind;
        _first = first;
        _count = count;
        _indices = [indices copy];
        if (kind == NV2AMetalInputIndexed) {
            _minimumIndex = prefix ? prefix.minimumIndex : UINT32_MAX;
            _maximumIndex = prefix ? prefix.maximumIndex : 0;
            const uint8_t *bytes = _indices.bytes;
            for (NSUInteger i = prefix ? prefix.count : 0; i < count; i++) {
                const uint8_t *p = bytes + i * 4;
                uint32_t value = (uint32_t)p[0] | (uint32_t)p[1] << 8 |
                                 (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
                _minimumIndex = MIN(_minimumIndex, value);
                _maximumIndex = MAX(_maximumIndex, value);
            }
            /* A strong link would retain a full snapshot for every growth. */
            _verifiedPrefix = prefix;
        }
    }
    return self;
}
+ (instancetype)arraysFrom:(NSUInteger)first count:(NSUInteger)count
{
    if (!count || first > UINT32_MAX || count - 1 > UINT32_MAX - first)
        return nil;
    return [[self alloc] initKind:NV2AMetalInputArrays
                            first:first
                            count:count
                          indices:[NSData data]
                   verifiedPrefix:nil];
}
+ (instancetype)indexed:(NSData *)indices
{
    if (!indices.length || indices.length % 4)
        return nil;
    return [[self alloc] initKind:NV2AMetalInputIndexed
                            first:0
                            count:indices.length / 4
                          indices:indices
                   verifiedPrefix:nil];
}
+ (instancetype)indexedBytes:(const void *)bytes
                       count:(NSUInteger)count
            matchingPrevious:(NV2AMetalPendingInput *)previous
{
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
    return [[self alloc] initKind:NV2AMetalInputIndexed
                            first:0
                            count:count
                          indices:[NSData dataWithBytes:bytes length:count * 4]
                   verifiedPrefix:prefix];
}
+ (instancetype)inlineKind:(NV2AMetalInputKind)kind count:(NSUInteger)count
{
    if (!count || (kind != NV2AMetalInputInlineBuffer &&
                   kind != NV2AMetalInputInlineArray))
        return nil;
    return [[self alloc] initKind:kind
                            first:0
                            count:count
                          indices:[NSData data]
                   verifiedPrefix:nil];
}
@end
@interface NV2AMetalPendingSpan ()
- (instancetype)initResource:(id)resource
                       first:(NSUInteger)first
                       count:(NSUInteger)count;
@end
@implementation NV2AMetalPendingSpan
- (instancetype)initResource:(id)resource
                       first:(NSUInteger)first
                       count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _resource = resource;
        _first = first;
        _count = count;
    }
    return self;
}
+ (instancetype)resource:(id)resource
                   first:(NSUInteger)first
                   count:(NSUInteger)count
{
    if (!resource || !count || first > NSUIntegerMax - count)
        return nil;
    return [[self alloc] initResource:resource first:first count:count];
}
@end
@class NV2AMetalPendingJournal;
@interface NV2AMetalPendingPlan ()
@property(nonatomic, weak) NV2AMetalPendingJournal *owner;
@property(nonatomic) NSUInteger version;
@property(nonatomic) NSArray<NSArray<NV2AMetalPendingSpan *> *> *previous;
- (instancetype)initInputs:(NSArray *)inputs
                  prefixes:(NSArray *)prefixes
                  previous:(NSArray *)previous
                     owner:(NV2AMetalPendingJournal *)owner
                   version:(NSUInteger)version;
@end
@implementation NV2AMetalPendingPlan
- (instancetype)initInputs:(NSArray *)inputs
                  prefixes:(NSArray *)prefixes
                  previous:(NSArray *)previous
                     owner:(NV2AMetalPendingJournal *)owner
                   version:(NSUInteger)version
{
    self = [super init];
    if (self) {
        _inputs = [inputs copy];
        _prefixCounts = [prefixes copy];
        _previous = [previous copy];
        _owner = owner;
        _version = version;
    }
    return self;
}
@end
@interface NV2AMetalPendingUpdate ()
@property(nonatomic) NV2AMetalPendingPlan *plan;
@property(nonatomic) NSUInteger committedVersion;
@property(nonatomic) BOOL committed, consumed, partial;
- (instancetype)initPlan:(NV2AMetalPendingPlan *)plan
                 streams:(NSArray *)streams;
@end
@implementation NV2AMetalPendingUpdate
- (instancetype)initPlan:(NV2AMetalPendingPlan *)plan streams:(NSArray *)streams
{
    self = [super init];
    if (self) {
        _plan = plan;
        _streams = [streams copy];
    }
    return self;
}
@end
@interface NV2AMetalPendingProgress ()
@property(nonatomic) NV2AMetalPendingPlan *plan;
@property(nonatomic) NSUInteger version, nextInput, published;
- (instancetype)initPlan:(NV2AMetalPendingPlan *)plan;
@end
@implementation NV2AMetalPendingProgress
- (instancetype)initPlan:(NV2AMetalPendingPlan *)plan
{
    self = [super init];
    if (self) {
        _plan = plan;
        _version = plan.version;
    }
    return self;
}
@end
static BOOL same_prefix(NV2AMetalPendingInput *old, NV2AMetalPendingInput *next)
{
    if (old == next || next.verifiedPrefix == old)
        return YES;
    if (next.count < old.count)
        return NO;
    if (old.kind == NV2AMetalInputArrays) {
        if (next.kind == NV2AMetalInputArrays)
            return old.first == next.first;
        if (next.kind != NV2AMetalInputIndexed)
            return NO;
        const uint8_t *indices = next.indices.bytes;
        for (NSUInteger i = 0; i < old.count; i++) {
            uint32_t value;
            memcpy(&value, indices + 4 * i, 4);
            if (value != old.first + i)
                return NO;
        }
        return YES;
    }
    if (old.kind != next.kind)
        return NO;
    if (old.kind == NV2AMetalInputIndexed)
        return !memcmp(old.indices.bytes, next.indices.bytes,
                       old.indices.length);
    return YES;
}
@implementation NV2AMetalPendingJournal {
    NSUInteger _limit;
    NSMutableArray<NV2AMetalPendingInput *> *_inputs;
    NSMutableArray<NSArray<NV2AMetalPendingSpan *> *> *_streams;
}
- (instancetype)initWithLimit:(NSUInteger)limit
{
    self = [super init];
    if (!self || !limit)
        return nil;
    _limit = limit;
    _inputs = [NSMutableArray new];
    _streams = [NSMutableArray new];
    return self;
}
- (NSUInteger)streamCount
{
    return _inputs.count;
}
- (NSArray<NV2AMetalPendingInput *> *)retainedInputs
{
    return [_inputs copy];
}
- (NSArray<NSArray<NV2AMetalPendingSpan *> *> *)retainedStreams
{
    return [_streams copy];
}
- (NV2AMetalPendingPlan *)planInputs:(NSArray<NV2AMetalPendingInput *> *)inputs
                 preservingLastArray:(BOOL)preserve
                               error:(NSError **)error
{
    if (!inputs || _generation == NSUIntegerMax ||
        (_inputs.count > inputs.count &&
         (!preserve || !inputs.count || _inputs.count - inputs.count != 1 ||
          _inputs.lastObject.kind != NV2AMetalInputArrays))) {
        journal_error(error, @"Invalid pending-stream range transition");
        return nil;
    }
    NSMutableArray *prefixes = [NSMutableArray new],
                   *previous = [NSMutableArray new];
    NSUInteger total = 0;
    for (NSUInteger i = 0; i < inputs.count; i++) {
        NV2AMetalPendingInput *next = inputs[i];
        if (![next isKindOfClass:NV2AMetalPendingInput.class] ||
            next.count > _limit - total ||
            (_inputs.count > inputs.count &&
             next.kind != NV2AMetalInputArrays)) {
            journal_error(error, @"Invalid or oversized pending-stream inputs");
            return nil;
        }
        total += next.count;
        if (i < _inputs.count) {
            if (!same_prefix(_inputs[i], next)) {
                journal_error(
                    error, @"Pending vertex prefix no longer matches inputs");
                return nil;
            }
            [prefixes addObject:@(_inputs[i].count)];
            [previous addObject:_streams[i]];
        } else {
            [prefixes addObject:@0];
            [previous addObject:@[]];
        }
    }
    /* Include a preserved last range in the retained memory limit. */
    if (_inputs.count > inputs.count &&
        _inputs.lastObject.count > _limit - total) {
        journal_error(error, @"Preserved array exceeds pending limit");
        return nil;
    }
    return [[NV2AMetalPendingPlan alloc] initInputs:inputs
                                           prefixes:prefixes
                                           previous:previous
                                              owner:self
                                            version:_generation];
}
- (NV2AMetalPendingProgress *)beginProgressForPlan:(NV2AMetalPendingPlan *)plan
                                             error:(NSError **)error
{
    if (!plan || plan.owner != self || plan.version != _generation ||
        _generation >= NSUIntegerMax - 1) {
        journal_error(error, @"Stale pending-stream progress plan");
        return nil;
    }
    return [[NV2AMetalPendingProgress alloc] initPlan:plan];
}
- (BOOL)commitNextSuffix:(NV2AMetalPendingSpan *)suffix
                progress:(NV2AMetalPendingProgress *)progress
                   error:(NSError **)error
{
    NV2AMetalPendingPlan *plan = progress.plan;
    NSUInteger index = progress.nextInput;
    if (!progress || plan.owner != self || progress.version != _generation ||
        _generation >= NSUIntegerMax - 1 || index >= plan.inputs.count)
        return journal_error(error,
                             @"Stale or exhausted pending-stream progress");
    NSUInteger required = plan.inputs[index].count -
                          plan.prefixCounts[index].unsignedIntegerValue;
    if (required) {
        if (![suffix isKindOfClass:NV2AMetalPendingSpan.class] ||
            suffix.count != required)
            return journal_error(error, @"Transformed suffix count mismatch");
    } else if (suffix) {
        return journal_error(error,
                             @"Unexpected repeated vertex transformation");
    }
    if (required) {
        /* Copy only this stream's segments. Earlier completed streams and
         * unfinished future streams keep their immutable owners. Outer arrays
         * are private mutable storage; public snapshots always copy them. */
        NSArray *segments = [plan.previous[index] arrayByAddingObject:suffix];
        for (NSUInteger i = progress.published; i <= index; i++) {
            _inputs[i] = plan.inputs[i];
            if (i == index)
                _streams[i] = segments;
        }
        _generation++;
        progress.version = _generation;
        progress.published = index + 1;
    }
    progress.nextInput++;
    return YES;
}
- (NV2AMetalPendingUpdate *)preparePlan:(NV2AMetalPendingPlan *)plan
                               suffixes:(NSArray *)suffixes
                                  error:(NSError **)error
{
    return [self preparePlan:plan
             completedInputs:plan.inputs.count
                    suffixes:suffixes
                     partial:NO
                       error:error];
}
- (NV2AMetalPendingUpdate *)preparePlan:(NV2AMetalPendingPlan *)plan
                        completedInputs:(NSUInteger)completed
                               suffixes:(NSArray *)suffixes
                                  error:(NSError **)error
{
    return [self preparePlan:plan
             completedInputs:completed
                    suffixes:suffixes
                     partial:YES
                       error:error];
}
- (NV2AMetalPendingUpdate *)preparePlan:(NV2AMetalPendingPlan *)plan
                        completedInputs:(NSUInteger)completed
                               suffixes:(NSArray *)suffixes
                                partial:(BOOL)partial
                                  error:(NSError **)error
{
    if (!plan || plan.owner != self || plan.version != _generation ||
        _generation >= NSUIntegerMax - 1 || completed > plan.inputs.count ||
        (partial && !completed) || suffixes.count != completed) {
        journal_error(error, @"Stale pending-stream plan or result count");
        return nil;
    }
    NSMutableArray *streams = [NSMutableArray new];
    for (NSUInteger i = 0; i < completed; i++) {
        NSUInteger required =
            plan.inputs[i].count - plan.prefixCounts[i].unsignedIntegerValue;
        id value = suffixes[i];
        NSMutableArray *segments = [plan.previous[i] mutableCopy];
        if (required) {
            if (![value isKindOfClass:NV2AMetalPendingSpan.class] ||
                ((NV2AMetalPendingSpan *)value).count != required) {
                journal_error(error, @"Transformed suffix count mismatch");
                return nil;
            }
            [segments addObject:value];
        } else if (value != NSNull.null) {
            journal_error(error, @"Unexpected repeated vertex transformation");
            return nil;
        }
        [streams addObject:[segments copy]];
    }
    NSRange range = NSMakeRange(0, completed);
    NV2AMetalPendingPlan *prefix = [[NV2AMetalPendingPlan alloc]
        initInputs:[plan.inputs subarrayWithRange:range]
          prefixes:[plan.prefixCounts subarrayWithRange:range]
          previous:[plan.previous subarrayWithRange:range]
             owner:self
           version:_generation];
    NV2AMetalPendingUpdate *update =
        [[NV2AMetalPendingUpdate alloc] initPlan:prefix streams:streams];
    update.partial = partial;
    return update;
}
- (BOOL)commitUpdate:(NV2AMetalPendingUpdate *)update error:(NSError **)error
{
    if (!update || update.committed || update.plan.owner != self ||
        update.plan.version != _generation || _generation == NSUIntegerMax)
        return journal_error(error, @"Stale or repeated pending-stream commit");
    NSMutableArray *inputs = [update.plan.inputs mutableCopy],
                   *streams = [update.streams mutableCopy];
    for (NSUInteger i = inputs.count; i < _inputs.count; i++) {
        [inputs addObject:_inputs[i]];
        [streams addObject:_streams[i]];
    }
    _inputs = inputs;
    _streams = streams;
    _generation++;
    update.committed = YES;
    update.committedVersion = _generation;
    return YES;
}
- (BOOL)consumeUpdate:(NV2AMetalPendingUpdate *)update error:(NSError **)error
{
    if (!update || update.partial || !update.committed || update.consumed ||
        update.plan.owner != self || update.committedVersion != _generation ||
        _generation == NSUIntegerMax)
        return journal_error(error,
                             @"Stale or repeated pending-stream consume");
    NSRange remaining =
        NSMakeRange(update.streams.count, _inputs.count - update.streams.count);
    _inputs = [[_inputs subarrayWithRange:remaining] mutableCopy];
    _streams = [[_streams subarrayWithRange:remaining] mutableCopy];
    _generation++;
    update.consumed = YES;
    return YES;
}
- (NV2AMetalPendingJournal *)copyForTransaction
{
    NV2AMetalPendingJournal *copy =
        [[NV2AMetalPendingJournal alloc] initWithLimit:_limit];
    if (copy) {
        copy->_inputs = [_inputs mutableCopy];
        copy->_streams = [_streams mutableCopy];
        copy->_generation = _generation;
    }
    return copy;
}
- (void)reset
{
    _inputs = [NSMutableArray new];
    _streams = [NSMutableArray new];
    /* Exhausted generations remain exhausted instead of revalidating an old
     * plan. */
    if (_generation < NSUIntegerMax)
        _generation++;
}
@end
