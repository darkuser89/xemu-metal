/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_LRU_CACHE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_LRU_CACHE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Encoding-thread-owned bounded cache. Reads promote entries; inserting a
 * new key at capacity evicts only the least recently used entry. Keys are
 * copied. Command slots must independently retain GPU objects in flight. */
@interface NV2AMetalLRUCache<KeyType : id <NSCopying>, ObjectType> : NSObject
@property(nonatomic, readonly) NSUInteger count;
/* Lifetime diagnostics; clearing entries does not reset these counters. */
@property(nonatomic, readonly) uint64_t hitCount, missCount, evictionCount;
- (nullable instancetype)initWithCapacity:(NSUInteger)capacity;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable ObjectType)objectForKeyedSubscript:(KeyType)key;
- (void)setObject:(ObjectType)object forKeyedSubscript:(KeyType)key;
/* Explicit invalidation does not count as capacity eviction or a lookup. */
- (void)removeObjectForKey:(KeyType)key;
- (void)removeAllObjects;
@end
NS_ASSUME_NONNULL_END
#endif
