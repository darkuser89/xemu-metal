/* SPDX-License-Identifier: LGPL-2.0-or-later */
#import "lru-cache.h"

@interface NV2AMetalLRUEntry : NSObject
@property(nonatomic, copy) id<NSCopying> key;
@property(nonatomic, strong) id object;
@property(nonatomic, weak) NV2AMetalLRUEntry *previous;
@property(nonatomic, strong) NV2AMetalLRUEntry *next;
@end
@implementation NV2AMetalLRUEntry
@end

@implementation NV2AMetalLRUCache {
    NSMutableDictionary<id<NSCopying>, NV2AMetalLRUEntry *> *_entries;
    NV2AMetalLRUEntry *_oldest, *_newest;
    NSUInteger _capacity;
}
- (instancetype)initWithCapacity:(NSUInteger)capacity
{
    self = [super init];
    if (!self || !capacity)
        return nil;
    _capacity = capacity;
    _entries = [NSMutableDictionary new];
    return self;
}
- (NSUInteger)count
{
    return _entries.count;
}
- (void)detach:(NV2AMetalLRUEntry *)entry
{
    NV2AMetalLRUEntry *previous = entry.previous, *next = entry.next;
    if (previous)
        previous.next = next;
    else
        _oldest = next;
    if (next)
        next.previous = previous;
    else
        _newest = previous;
    entry.previous = nil;
    entry.next = nil;
}
- (void)promote:(NV2AMetalLRUEntry *)entry
{
    if (entry == _newest)
        return;
    [self detach:entry];
    entry.previous = _newest;
    _newest.next = entry;
    if (!_oldest)
        _oldest = entry;
    _newest = entry;
}
- (id)objectForKeyedSubscript:(id<NSCopying>)key
{
    NV2AMetalLRUEntry *entry = _entries[key];
    if (entry) {
        _hitCount++;
        [self promote:entry];
    } else {
        _missCount++;
    }
    return entry.object;
}
- (void)setObject:(id)object forKeyedSubscript:(id<NSCopying>)key
{
    NSParameterAssert(object && key);
    NV2AMetalLRUEntry *entry = _entries[key];
    if (entry) {
        entry.object = object;
        [self promote:entry];
        return;
    }
    if (_entries.count == _capacity) {
        NV2AMetalLRUEntry *expired = _oldest;
        [self detach:expired];
        [_entries removeObjectForKey:expired.key];
        _evictionCount++;
    }
    entry = [NV2AMetalLRUEntry new];
    entry.key = key;
    entry.object = object;
    entry.previous = _newest;
    _newest.next = entry;
    if (!_oldest)
        _oldest = entry;
    _newest = entry;
    _entries[entry.key] = entry;
}
- (void)removeObjectForKey:(id<NSCopying>)key
{
    NV2AMetalLRUEntry *entry = _entries[key];
    if (entry) {
        [self detach:entry];
        [_entries removeObjectForKey:key];
    }
}
- (void)removeAllObjects
{
    _oldest = _newest = nil;
    [_entries removeAllObjects];
}
@end
