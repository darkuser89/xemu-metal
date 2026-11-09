/* Immutable index views versus complete NSData copies. CPU only.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_INDEX_CAPTURE_GROWTH_H
#define TEST_METAL_INDEX_CAPTURE_GROWTH_H

#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

/* Observe the real allocation and copy primitives, without production counters.
 */
@interface NV2AMetalIndexSnapshotBacking : NSObject
- (nullable instancetype)initWithCapacity:(NSUInteger)capacity;
- (void)copyBytes:(const void *)bytes
           offset:(NSUInteger)offset
           length:(NSUInteger)length;
@end
static _Atomic(NSUInteger) icg_allocations, icg_capacityBytes, icg_copiedBytes;
static _Atomic(BOOL) icg_rejectAllocation;
@interface NV2AMetalIndexSnapshotBacking (IndexCaptureGrowthTest)
- (nullable instancetype)icg_initWithCapacity:(NSUInteger)capacity
    __attribute__((objc_method_family(init)));
- (void)icg_copyBytes:(const void *)bytes
               offset:(NSUInteger)offset
               length:(NSUInteger)length;
@end
@implementation NV2AMetalIndexSnapshotBacking (IndexCaptureGrowthTest)
- (nullable instancetype)icg_initWithCapacity:(NSUInteger)capacity
{
    if (atomic_exchange(&icg_rejectAllocation, NO))
        return nil;
    self = [self icg_initWithCapacity:capacity];
    if (self) {
        atomic_fetch_add(&icg_allocations, 1);
        atomic_fetch_add(&icg_capacityBytes, capacity);
    }
    return self;
}
- (void)icg_copyBytes:(const void *)bytes
               offset:(NSUInteger)offset
               length:(NSUInteger)length
{
    atomic_fetch_add(&icg_copiedBytes, length);
    [self icg_copyBytes:bytes offset:offset length:length];
}
@end

@interface IndexCaptureValue : NSObject
@property(nonatomic) NV2AMetalPendingInput *input;
@property(nonatomic) NSData *reference, *copied, *archive, *propertyList;
@property(nonatomic) NSString *base64;
@property(nonatomic) NSDictionary<NSData *, NSString *> *dictionary;
@property(nonatomic) NSUInteger hashValue;
@property(nonatomic) const void *address;
@end
@implementation IndexCaptureValue
@end

static id _Nullable icg_backing(NSData *data)
{
    return [data respondsToSelector:NSSelectorFromString(@"backing")] ?
               [data valueForKey:@"backing"] :
               nil;
}
static NSUInteger icg_capacity(id backing)
{
    return [[backing valueForKey:@"capacity"] unsignedIntegerValue];
}
static void icg_word(uint8_t *bytes, NSUInteger index, uint32_t value)
{
    for (unsigned b = 0; b < 4; b++)
        bytes[index * 4 + b] = value >> (8 * b);
}
static void icg_bounds(IndexCaptureValue *value)
{
    uint32_t minimum = UINT32_MAX, maximum = 0;
    const uint8_t *bytes = value.reference.bytes;
    for (NSUInteger i = 0; i < value.reference.length; i += 4) {
        uint32_t word = (uint32_t)bytes[i] | (uint32_t)bytes[i + 1] << 8 |
                        (uint32_t)bytes[i + 2] << 16 |
                        (uint32_t)bytes[i + 3] << 24;
        minimum = MIN(minimum, word);
        maximum = MAX(maximum, word);
    }
    assert(value.input.minimumIndex == minimum &&
           value.input.maximumIndex == maximum);
}
static IndexCaptureValue *icg_value(NV2AMetalPendingInput *input,
                                    NSData *reference, BOOL coding)
{
    assert(input && input.kind == NV2AMetalInputIndexed && !input.first &&
           input.count * 4 == reference.length);
    IndexCaptureValue *value = [IndexCaptureValue new];
    value.input = input;
    value.reference = reference;
    value.copied = [input.indices copy];
    value.address = input.indices.bytes;
    value.hashValue = input.indices.hash;
    value.dictionary = @{ input.indices : @"immutable" };
    if (coding) {
        NSError *error = nil;
        value.archive =
            [NSKeyedArchiver archivedDataWithRootObject:input.indices
                                  requiringSecureCoding:YES
                                                  error:&error];
        assert(value.archive && !error);
        value.propertyList = [NSPropertyListSerialization
            dataWithPropertyList:@{ @"indices" : input.indices }
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:&error];
        assert(value.propertyList && !error);
        value.base64 = [input.indices base64EncodedStringWithOptions:0];
    }
    return value;
}
static IndexCaptureValue *icg_capture(const void *bytes, NSUInteger count,
                                      NV2AMetalPendingInput *_Nullable previous,
                                      BOOL coding)
{
    /* This complete copy is the independent former capture representation. */
    NSData *reference = [NSData dataWithBytes:bytes length:count * 4];
    NV2AMetalPendingInput *input =
        [NV2AMetalPendingInput indexedBytes:bytes
                                      count:count
                           matchingPrevious:previous];
    return icg_value(input, reference, coding);
}
static void icg_check(IndexCaptureValue *value)
{
    NSData *view = value.input.indices, *reference = value.reference;
    assert(view.length == reference.length && view.bytes == value.address &&
           !memcmp(view.bytes, reference.bytes, reference.length) &&
           [view isEqualToData:reference] && [reference isEqualToData:view] &&
           [value.copied isEqualToData:reference] &&
           view.hash == value.hashValue && view.hash == reference.hash &&
           [value.dictionary[view] isEqualToString:@"immutable"] &&
           [value.dictionary[reference] isEqualToString:@"immutable"]);
    icg_bounds(value);
    if (!value.archive)
        return;
    NSError *error = nil;
    NSData *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:NSData.class
                                                        fromData:value.archive
                                                           error:&error];
    assert(decoded && !error && [decoded isEqualToData:reference]);
    NSDictionary *plist = [NSPropertyListSerialization
        propertyListWithData:value.propertyList
                     options:NSPropertyListImmutable
                      format:NULL
                       error:&error];
    assert(plist && !error && [plist[@"indices"] isEqualToData:reference]);
    assert(
        [[view base64EncodedStringWithOptions:0] isEqualToString:value.base64]);
    NSData *base64 = [[NSData alloc] initWithBase64EncodedString:value.base64
                                                         options:0];
    assert([base64 isEqualToData:reference]);
    NSMutableData *mutable = [view mutableCopy];
    assert([mutable isEqualToData:reference]);
    ((uint8_t *)mutable.mutableBytes)[0] ^= 0x7f;
    assert([view isEqualToData:reference] && ![mutable isEqualToData:view]);
    NSMutableData *read = [NSMutableData dataWithLength:view.length];
    [view getBytes:read.mutableBytes length:read.length];
    assert([read isEqualToData:reference]);
    NSRange middle = NSMakeRange(1, view.length - 2);
    NSMutableData *ranged = [NSMutableData dataWithLength:middle.length];
    [view getBytes:ranged.mutableBytes range:middle];
    assert([ranged isEqualToData:[reference subdataWithRange:middle]] &&
           [[view subdataWithRange:middle]
               isEqualToData:[reference subdataWithRange:middle]]);
    /* Re-encoding after later appends must still expose only this view. */
    NSData *encoded = [NSKeyedArchiver archivedDataWithRootObject:view
                                            requiringSecureCoding:YES
                                                            error:&error];
    decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:NSData.class
                                                fromData:encoded
                                                   error:&error];
    assert(encoded && decoded && !error && [decoded isEqualToData:reference]);
}
static void icg_check_all(NSArray<IndexCaptureValue *> *values)
{
    for (IndexCaptureValue *value in values)
        icg_check(value);
}
static void icg_reset_counts(void)
{
    atomic_store(&icg_allocations, 0);
    atomic_store(&icg_capacityBytes, 0);
    atomic_store(&icg_copiedBytes, 0);
}

static void icg_growth(void)
{
    const NSUInteger count = 4096;
    NSMutableData *source = [NSMutableData dataWithLength:count * 4 + 1];
    uint8_t *bytes = (uint8_t *)source.mutableBytes + 1;
    for (NSUInteger i = 0; i < count; i++)
        icg_word(bytes, i,
                 i == 0 ? UINT32_MAX :
                 i == 1 ? 0 :
                          (uint32_t)(i * UINT32_C(1103515245) + 12345));
    NSMutableArray<IndexCaptureValue *> *values = [NSMutableArray new];
    NV2AMetalPendingInput *previous = nil;
    id owner = nil;
    NSUInteger capacity = 0, formerCopiedBytes = 0;
    icg_reset_counts();
    for (NSUInteger n = 1; n <= count; n++) {
        @autoreleasepool {
            BOOL coding = n <= 17 || !(n & (n - 1));
            IndexCaptureValue *value = icg_capture(bytes, n, previous, coding);
            formerCopiedBytes += n * 4;
            [values addObject:value];
            icg_check(value);
            if (previous)
                icg_check(values[n - 2]);
            icg_check(values[0]);
            id nextOwner = icg_backing(value.input.indices);
            assert(nextOwner &&
                   [value.input.indices copy] == value.input.indices);
            NSUInteger nextCapacity = icg_capacity(nextOwner);
            assert(nextCapacity >= n * 4);
            if (nextOwner != owner || nextCapacity != capacity)
                icg_check_all(values);
            owner = nextOwner;
            capacity = nextCapacity;
            previous = value.input;
        }
    }
    NSUInteger allocations = atomic_load(&icg_allocations);
    NSUInteger copied = atomic_load(&icg_copiedBytes);
    NSUInteger requestedCapacity = atomic_load(&icg_capacityBytes);
    assert(allocations && allocations <= 16 && copied >= count * 4 &&
           copied <= count * 4 * 3 &&
           formerCopiedBytes == count * (count + 1) * 2 &&
           copied < formerCopiedBytes / 100 &&
           requestedCapacity <= count * 4 * 4);
    memset(bytes, 0x5a, count * 4);
    icg_check_all(values);
    printf("Index capture growth: %zu retained snapshots; actual backing "
           "allocations=%zu/copied=%zuB/requested-capacity=%zuB versus full "
           "NSData "
           "copies=%zu/copied=%zuB; immutable Foundation values PASS\n",
           (size_t)count, (size_t)allocations, (size_t)copied,
           (size_t)requestedCapacity, (size_t)count, (size_t)formerCopiedBytes);
}

static void icg_branches(void)
{
    uint8_t words[80];
    for (NSUInteger i = 0; i < 20; i++)
        icg_word(words, i, (uint32_t)(20 - i));
    NSMutableArray *values = [NSMutableArray new];
    IndexCaptureValue *base = icg_capture(words, 4, nil, YES);
    [values addObject:base];
    IndexCaptureValue *grown = icg_capture(words, 12, base.input, YES);
    [values addObject:grown];
    assert(icg_backing(base.input.indices) == icg_backing(grown.input.indices));
    /* Branch from an older, shorter published view inside the same capacity. */
    icg_word(words, 4, UINT32_MAX);
    IndexCaptureValue *branch = icg_capture(words, 8, base.input, YES);
    [values addObject:branch];
    assert(icg_backing(branch.input.indices) !=
           icg_backing(base.input.indices));
    icg_check_all(values);
    icg_word(words, 0, 0);
    IndexCaptureValue *changed = icg_capture(words, 13, grown.input, YES);
    [values addObject:changed];
    assert(changed.input != grown.input && changed.input.minimumIndex == 0);
    icg_check_all(values);
    IndexCaptureValue *shorter = icg_capture(words, 2, changed.input, YES);
    [values addObject:shorter];
    assert(shorter.input.maximumIndex == 19 && shorter.input.minimumIndex == 0);
    icg_check_all(values);
    assert([NV2AMetalPendingInput indexedBytes:words
                                         count:2
                              matchingPrevious:shorter.input] == shorter.input);
    /* Matching a former frontier must not become appendable when its larger
     * sibling dies. Keep only its immutable smaller NSData view alive. */
    __weak NV2AMetalPendingInput *dead = nil;
    @autoreleasepool {
        NV2AMetalPendingInput *temporary =
            [NV2AMetalPendingInput indexedBytes:base.reference.bytes
                                          count:4
                               matchingPrevious:nil];
        IndexCaptureValue *old = icg_value(temporary, base.reference, YES);
        [values addObject:old];
        uint8_t extended[32];
        memcpy(extended, base.reference.bytes, base.reference.length);
        memset(extended + 16, 0xee, 16);
        @autoreleasepool {
            NV2AMetalPendingInput *larger =
                [NV2AMetalPendingInput indexedBytes:extended
                                              count:8
                                   matchingPrevious:temporary];
            dead = larger;
            assert(icg_backing(larger.indices) ==
                   icg_backing(temporary.indices));
        }
        assert(!dead);
        IndexCaptureValue *fork = icg_capture(extended, 6, temporary, YES);
        [values addObject:fork];
        assert(icg_backing(fork.input.indices) !=
               icg_backing(temporary.indices));
    }
    memset(words, 0xa5, sizeof(words));
    icg_check_all(values);
    /* Source validation must not be bypassed by the weak verified-prefix link.
     */
    NV2AMetalPendingJournal *journal =
        [[NV2AMetalPendingJournal alloc] initWithLimit:32];
    NSError *error = nil;
    NV2AMetalPendingPlan *plan = [journal planInputs:@[ base.input ]
                                 preservingLastArray:NO
                                               error:&error];
    NV2AMetalPendingSpan *span = [NV2AMetalPendingSpan resource:@"old"
                                                          first:0
                                                          count:4];
    NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                 suffixes:@[ span ]
                                                    error:&error];
    assert(update && [journal commitUpdate:update error:&error] && !error);
    assert(![journal planInputs:@[ changed.input ]
               preservingLastArray:NO
                             error:&error] &&
           error);
    icg_check_all(values);
}

static void icg_concurrent_branches(void)
{
    uint8_t raw[32];
    for (NSUInteger i = 0; i < 8; i++)
        icg_word(raw, i, (uint32_t)i + 1);
    IndexCaptureValue *base = icg_capture(raw, 4, nil, YES);
    NSMutableData *a = [NSMutableData dataWithBytes:raw length:sizeof(raw)];
    NSMutableData *b = [a mutableCopy];
    icg_word(a.mutableBytes, 4, 1000);
    icg_word(b.mutableBytes, 4, 2000);
    __block NV2AMetalPendingInput *left = nil, *right = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_semaphore_t start = dispatch_semaphore_create(0);
    dispatch_queue_t queue =
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(group, queue, ^{
      @autoreleasepool {
          dispatch_semaphore_signal(ready);
          dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
          left = [NV2AMetalPendingInput indexedBytes:a.bytes
                                               count:8
                                    matchingPrevious:base.input];
      }
    });
    dispatch_group_async(group, queue, ^{
      @autoreleasepool {
          dispatch_semaphore_signal(ready);
          dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
          right = [NV2AMetalPendingInput indexedBytes:b.bytes
                                                count:8
                                     matchingPrevious:base.input];
      }
    });
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(start);
    dispatch_semaphore_signal(start);
    assert(!dispatch_group_wait(
        group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    IndexCaptureValue *l = icg_value(left, [a copy], YES);
    IndexCaptureValue *r = icg_value(right, [b copy], YES);
    id owner = icg_backing(base.input.indices), lo = icg_backing(left.indices),
       ro = icg_backing(right.indices);
    assert(lo && ro && lo != ro && (lo == owner) + (ro == owner) <= 1);
    memset(a.mutableBytes, 0xcc, a.length);
    memset(b.mutableBytes, 0xdd, b.length);
    icg_check_all(@[ base, l, r ]);
}

static void icg_fallbacks(void)
{
    NSMutableData *source = [NSMutableData dataWithLength:2 * 1024 * 1024 + 4];
    uint8_t *bytes = source.mutableBytes;
    for (NSUInteger i = 0; i < source.length / 4; i++)
        icg_word(bytes, i, (uint32_t)i ^ UINT32_C(0x80000000));
    IndexCaptureValue *base = icg_capture(bytes, 16, nil, YES);
    icg_reset_counts();
    atomic_store(&icg_rejectAllocation, YES);
    IndexCaptureValue *fallback = icg_capture(bytes, 17, base.input, YES);
    assert(!atomic_load(&icg_rejectAllocation) &&
           !atomic_load(&icg_allocations) && !atomic_load(&icg_copiedBytes));
    icg_check_all(@[ base, fallback ]);
    IndexCaptureValue *retry = icg_capture(bytes, 18, fallback.input, YES);
    assert(icg_backing(retry.input.indices) &&
           atomic_load(&icg_allocations) == 1);
    icg_check_all(@[ base, fallback, retry ]);
    icg_reset_counts();
    IndexCaptureValue *capped =
        icg_capture(bytes, source.length / 4 - 1, retry.input, NO);
    assert(icg_backing(capped.input.indices) &&
           icg_capacity(icg_backing(capped.input.indices)) == 2 * 1024 * 1024 &&
           atomic_load(&icg_allocations) == 1);
    icg_reset_counts();
    IndexCaptureValue *large =
        icg_capture(bytes, source.length / 4, capped.input, YES);
    assert(!icg_backing(large.input.indices) && !atomic_load(&icg_allocations));
    icg_check(large);
    NSUInteger allocations = atomic_load(&icg_allocations),
               copied = atomic_load(&icg_copiedBytes);
    assert(![NV2AMetalPendingInput indexedBytes:NULL
                                          count:1
                               matchingPrevious:base.input] &&
           ![NV2AMetalPendingInput indexedBytes:bytes
                                          count:0
                               matchingPrevious:base.input] &&
           ![NV2AMetalPendingInput indexedBytes:bytes
                                          count:NSUIntegerMax / 4 + 1
                               matchingPrevious:base.input]);
    assert(atomic_load(&icg_allocations) == allocations &&
           atomic_load(&icg_copiedBytes) == copied);
    memset(bytes, 0x53, source.length);
    icg_check_all(@[ base, fallback, retry, capped, large ]);
    /* A view owns its backing, not its previous Input descriptor. */
    __weak NV2AMetalPendingInput *weak = nil;
    __block NSData *oldView = nil;
    NV2AMetalPendingInput *grown = nil;
    @autoreleasepool {
        NV2AMetalPendingInput *old = [NV2AMetalPendingInput indexedBytes:bytes
                                                                   count:2
                                                        matchingPrevious:nil];
        weak = old;
        oldView = old.indices;
        grown = [NV2AMetalPendingInput indexedBytes:bytes
                                              count:3
                                   matchingPrevious:old];
    }
    assert(!weak && grown && oldView.length == 8 && grown.count == 3);
    puts("Index capture branches/changed-prefix/shrink, concurrent distinct "
         "suffixes, unaligned LE32 bounds, allocation/size fallbacks and "
         "overflow/history lifetimes PASS (CPU only)");
}

static void index_capture_growth_tests(void)
{
    Class backing = NSClassFromString(@"NV2AMetalIndexSnapshotBacking");
    assert(backing);
    Method init =
        class_getInstanceMethod(backing, @selector(initWithCapacity:));
    Method spyInit =
        class_getInstanceMethod(backing, @selector(icg_initWithCapacity:));
    Method copy =
        class_getInstanceMethod(backing, @selector(copyBytes:offset:length:));
    Method spyCopy = class_getInstanceMethod(
        backing, @selector(icg_copyBytes:offset:length:));
    assert(init && spyInit && copy && spyCopy);
    method_exchangeImplementations(init, spyInit);
    method_exchangeImplementations(copy, spyCopy);
    @try {
        icg_growth();
        icg_branches();
        icg_concurrent_branches();
        icg_fallbacks();
    } @finally {
        atomic_store(&icg_rejectAllocation, NO);
        method_exchangeImplementations(copy, spyCopy);
        method_exchangeImplementations(init, spyInit);
    }
}

NS_ASSUME_NONNULL_END
#endif
