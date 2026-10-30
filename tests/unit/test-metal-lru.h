/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_LRU_H
#define TEST_METAL_LRU_H
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#include <assert.h>
#include <stdint.h>

static void check_lru(void)
{
    assert(![[NV2AMetalLRUCache alloc] initWithCapacity:0]);
    for (NSUInteger capacity = 1; capacity <= 256; capacity = capacity == 1 ? 3
                                                              : capacity == 3
                                                                  ? 256
                                                                  : 257) {
        NV2AMetalLRUCache<NSNumber *, NSNumber *> *cache =
            [[NV2AMetalLRUCache alloc] initWithCapacity:capacity];
        NSMutableArray<NSNumber *> *order = [NSMutableArray new];
        NSMutableDictionary<NSNumber *, NSNumber *> *values =
            [NSMutableDictionary new];
        uint32_t random = 0x12345678;
        for (unsigned i = 0; i < 10000; i++) {
            random = random * 1664525u + 1013904223u;
            NSNumber *key = @((random >> 8) % 400);
            if ((random >> 16) % 5 == 0) {
                uint64_t hits = cache.hitCount, misses = cache.missCount,
                         evictions = cache.evictionCount;
                [cache removeObjectForKey:key];
                [order removeObject:key];
                [values removeObjectForKey:key];
                assert(cache.hitCount == hits && cache.missCount == misses &&
                       cache.evictionCount == evictions);
            } else if (random & 1) {
                NSNumber *value = @(i);
                cache[key] = value;
                [order removeObject:key];
                [order addObject:key];
                values[key] = value;
                if (order.count > capacity) {
                    [values removeObjectForKey:order.firstObject];
                    [order removeObjectAtIndex:0];
                }
            } else {
                NSNumber *actual = cache[key], *wanted = values[key];
                assert(actual == wanted || [actual isEqual:wanted]);
                if (wanted) {
                    [order removeObject:key];
                    [order addObject:key];
                }
            }
            assert(cache.count == values.count && cache.count <= capacity);
        }
        [cache removeAllObjects];
        assert(!cache.count);
        cache[@0] = @1;
        assert([cache[@0] isEqual:@1] && cache.count == 1);
    }
    NV2AMetalLRUCache<NSNumber *, NSNumber *> *cache =
        [[NV2AMetalLRUCache alloc] initWithCapacity:256];
    for (unsigned i = 0; i < 256; i++)
        cache[@(i)] = @(i);
    assert(cache[@0]);
    cache[@256] = @256;
    assert(cache.count == 256 && !cache[@1] && cache[@0] && cache[@255]);
    /* A frequently used 128-entry working set survives 512 cold insertions. */
    for (unsigned cold = 257; cold < 769; cold++) {
        for (unsigned hot = 128; hot < 256; hot++)
            assert([cache[@(hot)] isEqual:@(hot)]);
        cache[@(cold)] = @(cold);
        assert(cache.count == 256);
    }
    NV2AMetalLRUCache<NSNumber *, NSNumber *> *removals =
        [[NV2AMetalLRUCache alloc] initWithCapacity:4];
    for (unsigned i = 0; i < 4; i++)
        removals[@(i)] = @(i);
    [removals removeObjectForKey:@1]; /* Middle. */
    [removals removeObjectForKey:@0]; /* Oldest. */
    [removals removeObjectForKey:@3]; /* Newest. */
    assert(removals.count == 1 && removals[@2]);
    [removals removeObjectForKey:@2]; /* Sole entry. */
    [removals removeObjectForKey:@2]; /* Absent entry. */
    assert(!removals.count && !removals.evictionCount);
    for (unsigned i = 0; i < 5; i++)
        removals[@(i)] = @(i);
    assert(removals.count == 4 && removals.evictionCount == 1 &&
           !removals[@0] && removals[@1]);
    NV2AMetalLRUCache<NSData *, NSObject *> *copiedKeys =
        [[NV2AMetalLRUCache alloc] initWithCapacity:1];
    __weak NSObject *released;
    @autoreleasepool {
        NSMutableData *key = [NSMutableData dataWithBytes:"a" length:1];
        NSObject *object = [NSObject new];
        released = object;
        copiedKeys[key] = object;
        ((char *)key.mutableBytes)[0] = 'b';
        assert(copiedKeys[[NSData dataWithBytes:"a" length:1]] == object);
        assert(!copiedKeys[key]);
        copiedKeys[key] = [NSObject new];
    }
    assert(!released);
    @autoreleasepool {
        NSObject *object = [NSObject new];
        released = object;
        copiedKeys[[NSData dataWithBytes:"c" length:1]] = object;
        [copiedKeys removeAllObjects];
    }
    assert(!released);
    @autoreleasepool {
        NSObject *object = [NSObject new];
        released = object;
        NSData *key = [NSData dataWithBytes:"d" length:1];
        copiedKeys[key] = object;
        [copiedKeys removeObjectForKey:key];
    }
    assert(!released);
    @autoreleasepool {
        NV2AMetalLRUCache *temporary =
            [[NV2AMetalLRUCache alloc] initWithCapacity:3];
        NSObject *object = [NSObject new];
        released = object;
        temporary[@0] = object;
        temporary[@1] = [NSObject new];
        temporary[@2] = [NSObject new];
        assert(temporary[@0] == object);
    }
    assert(!released);
    puts("Metal LRU: 30,000 oracle operations, capacities 1/3/256, "
         "256-entry boundary, 128 hot entries/512 cold inserts, copied keys "
         "and explicit removal/eviction/clear/destruction lifetime PASS (CPU "
         "only)");
}
#endif
