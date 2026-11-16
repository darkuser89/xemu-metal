/* Native visibility reports from gl/reports.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "reports-pgraph.h"
#include "renderer.h"

static BOOL report_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.reports"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}
@interface NV2AMetalVisibilityCounter ()
@property(nonatomic, readwrite, nullable) id<MTLBuffer> buffer;
@property(nonatomic, readwrite) NSUInteger offset;
@property(nonatomic, weak) NV2AMetalPGRAPHReports *owner;
@property(nonatomic, nullable) NV2AMetalSurfaceRecording *token;
@property(nonatomic) BOOL captured, cancelled, committed, zeroSamples;
@property(nonatomic) uint64_t value, recordingSerial;
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset;
@end
@implementation NV2AMetalVisibilityCounter
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset
{
    self = [super init];
    if (self) {
        _buffer = buffer;
        _offset = offset;
    }
    return self;
}
@end
@interface NV2AMetalPGRAPHQuery ()
@property(nonatomic, readwrite) BOOL discarded, open;
@property(nonatomic, readonly)
    NSMutableArray<NV2AMetalVisibilityCounter *> *buffers;
@property(nonatomic) uint64_t savedCount, reportedCount;
@property(nonatomic) NSUInteger reportedBuffers;
- (instancetype)initQuery;
@end
static void capture_zero_counter(NV2AMetalVisibilityCounter *counter)
{
    NV2AMetalSurfaceRecording *token = counter.token;
    if (counter.zeroSamples && !counter.captured && !counter.cancelled &&
        token.completed && !token.cancelled) {
        counter.value = 0;
        counter.captured = YES;
        counter.token = nil;
    }
}
static void compact_query(NV2AMetalPGRAPHQuery *query)
{
    NSUInteger prefix = 0, reported = query.reportedBuffers;
    for (NV2AMetalVisibilityCounter *counter in query.buffers) {
        capture_zero_counter(counter);
        if (!counter.captured || counter.cancelled)
            break;
        query.savedCount += counter.value;
        if (prefix < reported)
            query.reportedCount += counter.value;
        prefix++;
    }
    if (prefix) {
        [query.buffers removeObjectsInRange:NSMakeRange(0, prefix)];
        query.reportedBuffers = reported > prefix ? reported - prefix : 0;
    }
}
@implementation NV2AMetalPGRAPHQuery
- (instancetype)initQuery
{
    self = [super init];
    if (self) {
        _open = YES;
        _buffers = [NSMutableArray new];
    }
    return self;
}
@end
static NV2AMetalPGRAPHQuery *frozen_prefix(NV2AMetalPGRAPHQuery *query)
{
    NV2AMetalPGRAPHQuery *prefix = [[NV2AMetalPGRAPHQuery alloc] initQuery];
    prefix.open = NO;
    prefix.savedCount = query.savedCount;
    prefix.reportedCount = query.reportedCount;
    prefix.reportedBuffers = query.reportedBuffers;
    [prefix.buffers addObjectsFromArray:query.buffers];
    return prefix;
}
@interface NV2AMetalPGRAPHReport : NSObject
@property(nonatomic) BOOL clear;
@property(nonatomic) uint32_t parameter;
@property(nonatomic, copy) NSArray<NV2AMetalPGRAPHQuery *> *queries;
@end
@implementation NV2AMetalPGRAPHReport
@end

@interface NV2AMetalPGRAPHReports ()
- (instancetype)initForSnapshotValidation;
- (BOOL)restoreSnapshot:(NSData *)data
            activeQuery:(NV2AMetalPGRAPHQuery **)active
           validateOnly:(BOOL)validateOnly
                  error:(NSError **)error;
@end

@implementation NV2AMetalPGRAPHReports {
    NV2AState *_d;
    NV2AMetalSurfaceCache *_cache;
    NSMutableArray<NV2AMetalPGRAPHQuery *> *_queries;
    NSMutableArray<NV2AMetalPGRAPHReport *> *_reports;
    uint32_t _result;
    id<MTLBuffer> _counterBuffer;
    NSMutableArray *_counterSlots;
    NSMutableIndexSet *_freeCounterSlots;
    NSUInteger _counterCapacity, _counterCursor;
}
- (instancetype)initForSnapshotValidation
{
    return [super init];
}
- (instancetype)initWithState:(NV2AState *)state
                        cache:(NV2AMetalSurfaceCache *)cache
{
    return [self initWithState:state cache:cache counterCapacity:1024];
}
- (instancetype)initWithState:(NV2AState *)state
                        cache:(NV2AMetalSurfaceCache *)cache
              counterCapacity:(NSUInteger)capacity
{
    if (!state || !cache || !capacity || capacity > 1024 ||
        capacity > cache.commands.device.maxBufferLength / sizeof(uint64_t))
        return nil;
    self = [super init];
    if (self) {
        _d = state;
        _cache = cache;
        _queries = [NSMutableArray new];
        _reports = [NSMutableArray new];
        _counterCapacity = capacity;
        _counterSlots = [NSMutableArray arrayWithCapacity:capacity];
        _freeCounterSlots =
            [[NSMutableIndexSet alloc] initWithIndexesInRange:NSMakeRange(0, capacity)];
        for (NSUInteger i = 0; i < capacity; i++)
            [_counterSlots addObject:NSNull.null];
    }
    return self;
}
- (BOOL)retireCounterAtIndex:(NSUInteger)index
{
    id slot = _counterSlots[index];
    if (slot == NSNull.null)
        return YES;
    NV2AMetalVisibilityCounter *counter = slot;
    if (!counter.token ||
        (!counter.token.completed && !counter.token.cancelled))
        return NO;
    counter.cancelled |= counter.token.cancelled;
    if (!counter.cancelled) {
        uint64_t value;
        memcpy(&value,
               (const uint8_t *)counter.buffer.contents + counter.offset,
               sizeof(uint64_t));
        counter.value = value;
    }
    counter.captured = YES;
    counter.buffer = nil;
    counter.token = nil;
    _counterSlots[index] = NSNull.null;
    [_freeCounterSlots addIndex:index];
    return YES;
}
- (id<MTLBuffer>)visibilityBuffer
{
    return _counterBuffer;
}

- (NV2AMetalVisibilityCounter *)reserveCounterAtIndex:(NSUInteger)index
                                                error:(NSError **)error
{
    assert(_counterSlots[index] == NSNull.null);
    NSUInteger offset = index * sizeof(uint64_t);
    NV2AMetalVisibilityCounter *counter =
        [[NV2AMetalVisibilityCounter alloc] initWithBuffer:_counterBuffer
                                                    offset:offset];
    if (!counter) {
        report_error(error, @"Cannot allocate native visibility range");
        return nil;
    }
    uint64_t zero = 0;
    memcpy((uint8_t *)_counterBuffer.contents + offset, &zero, sizeof(zero));
    counter.owner = self;
    _counterSlots[index] = counter;
    [_freeCounterSlots removeIndex:index];
    _counterCursor = (index + 1) % _counterCapacity;
    return counter;
}

- (NV2AMetalVisibilityCounter *)allocateCounterWithError:(NSError **)error
{
    if (![_cache collectCompletedWithError:error])
        return nil;
    if (!_counterBuffer) {
        _counterBuffer = [_cache.commands.device
            newBufferWithLength:_counterCapacity * sizeof(uint64_t)
                        options:MTLResourceStorageModeShared];
        if (!_counterBuffer) {
            report_error(error, @"Cannot allocate native visibility pool");
            return nil;
        }
    }
    /* Free slots need no retirement checks on the busy prefix of the pool. */
    NSUInteger freeIndex = [_freeCounterSlots indexGreaterThanOrEqualToIndex:
                                                   _counterCursor];
    if (freeIndex == NSNotFound)
        freeIndex = _freeCounterSlots.firstIndex;
    if (freeIndex != NSNotFound)
        return [self reserveCounterAtIndex:freeIndex error:error];

    NV2AMetalVisibilityCounter *oldest = nil;
    NV2AMetalSurfaceRecording *lastPending = nil;
    NSUInteger oldestIndex = 0;
    for (NSUInteger i = 0; i < _counterCapacity; i++) {
        NSUInteger index = (_counterCursor + i) % _counterCapacity;
        NV2AMetalVisibilityCounter *busy = _counterSlots[index];
        NV2AMetalSurfaceRecording *token = busy.token;
        /* Recording state is published by the PGRAPH owner, so it cannot
         * change between two slots in this scan. */
        if (!token || token == lastPending)
            continue;
        if ([self retireCounterAtIndex:index])
            return [self reserveCounterAtIndex:index error:error];
        lastPending = token;
        if (!oldest || busy.recordingSerial < oldest.recordingSerial) {
            oldest = busy;
            oldestIndex = index;
        }
    }
    /* Reservations can be recorded out of slot order. Once the earliest
     * recording completes, reuse its selected slot directly. */
    if (oldest) {
        if (![_cache waitForRecording:oldest.token error:error])
            return nil;
        if ([self retireCounterAtIndex:oldestIndex])
            return [self reserveCounterAtIndex:oldestIndex error:error];
    }
    report_error(error, @"Native visibility pool has unrecorded reservations");
    return nil;
}
- (NV2AMetalVisibilityCounter *)allocateZeroSampleCounterWithError:
    (NSError **)error
{
    if (![_cache collectCompletedWithError:error])
        return nil;
    NV2AMetalVisibilityCounter *counter =
        [[NV2AMetalVisibilityCounter alloc] initWithBuffer:nil
                                                    offset:NSNotFound];
    if (!counter) {
        report_error(error,
                     @"Cannot allocate zero-sample visibility recording");
        return nil;
    }
    counter.owner = self;
    counter.zeroSamples = YES;
    return counter;
}
- (BOOL)recordCounter:(NV2AMetalVisibilityCounter *)counter
                error:(NSError **)error
{
    if (!counter || counter.owner != self || counter.cancelled ||
        counter.captured || counter.token || !_cache.recording ||
        (counter.zeroSamples ?
             (counter.buffer || counter.offset != NSNotFound) :
             (counter.buffer != _counterBuffer ||
              counter.offset % sizeof(uint64_t) ||
              counter.offset / sizeof(uint64_t) >= _counterCapacity ||
              _counterSlots[counter.offset / sizeof(uint64_t)] != counter)))
        return report_error(error,
                            @"Invalid native visibility range or recording");
    counter.token = _cache.recording;
    counter.recordingSerial = _cache.commands.recordingSerial;
    return YES;
}
/* Only an unreported zero run can move its completion boundary forward.
 * Waiting for the newest recording validates its chronological cache prefix.
 * Frozen prefixes retain their original counters, which are never mutated. */
- (BOOL)canCoalesceZeroCounter:(NV2AMetalVisibilityCounter *)counter
                         query:(NV2AMetalPGRAPHQuery *)query
{
    NV2AMetalVisibilityCounter *previous = query.buffers.lastObject;
    return query.open && !query.discarded && counter.zeroSamples &&
           previous.zeroSamples && counter.owner == self &&
           previous.owner == self && previous.committed && !counter.cancelled &&
           !previous.cancelled && counter.token && previous.token &&
           !counter.token.cancelled && !previous.token.cancelled &&
           !counter.captured && !previous.captured &&
           counter.recordingSerial >= previous.recordingSerial &&
           query.buffers.count > query.reportedBuffers;
}
- (void)commitCounter:(NV2AMetalVisibilityCounter *)counter
                query:(NV2AMetalPGRAPHQuery *)query
{
    assert(counter.owner == self && counter.token && !counter.cancelled &&
           !counter.committed);
    if (!query.discarded) {
        counter.committed = YES;
        if (counter.zeroSamples && [self canCoalesceZeroCounter:counter
                                                          query:query])
            query.buffers[query.buffers.count - 1] = counter;
        else
            [query.buffers addObject:counter];
        compact_query(query);
    }
}
- (void)cancelCounter:(NV2AMetalVisibilityCounter *)counter
{
    if (!counter || counter.owner != self || counter.committed)
        return;
    counter.cancelled = YES;
    if (counter.token && !counter.token.cancelled && !counter.token.completed)
        return;
    if (counter.zeroSamples) {
        counter.token = nil;
        return;
    }
    NSUInteger index = counter.offset / sizeof(uint64_t);
    if (index < _counterCapacity && _counterSlots[index] == counter) {
        _counterSlots[index] = NSNull.null;
        [_freeCounterSlots addIndex:index];
    }
    counter.buffer = nil;
    counter.token = nil;
}
- (NV2AMetalPGRAPHQuery *)beginQuery
{
    NV2AMetalPGRAPHQuery *query = [[NV2AMetalPGRAPHQuery alloc] initQuery];
    [_queries addObject:query];
    return query;
}
- (void)endQuery:(NV2AMetalPGRAPHQuery *)query
{
    query.open = NO;
}
- (void)cancelQuery:(NV2AMetalPGRAPHQuery *)query
{
    query.open = NO;
    query.discarded = YES;
    [_queries removeObjectIdenticalTo:query];
}
- (void)commitBuffer:(id<MTLBuffer>)buffer query:(NV2AMetalPGRAPHQuery *)query
{
    assert(buffer.device == _cache.commands.device &&
           buffer.storageMode == MTLStorageModeShared &&
           buffer.length >= sizeof(uint64_t));
    if (!query.discarded) {
        NV2AMetalVisibilityCounter *counter =
            [[NV2AMetalVisibilityCounter alloc] initWithBuffer:buffer offset:0];
        [query.buffers addObject:counter];
    }
}
- (void)clear
{
    NSMutableArray *continuing = [NSMutableArray new];
    for (NV2AMetalPGRAPHQuery *query in _queries) {
        if (query.open) {
            /* Earlier reports own frozen prefixes. Clear starts a new count
             * window while the same guest Begin continues collecting batches.
             */
            query.savedCount = query.reportedCount = 0;
            query.reportedBuffers = 0;
            [query.buffers removeAllObjects];
            [continuing addObject:query];
        } else {
            query.discarded = YES;
        }
    }
    _queries = continuing;
    NV2AMetalPGRAPHReport *report = [NV2AMetalPGRAPHReport new];
    report.clear = YES;
    [_reports addObject:report];
}
- (BOOL)getReport:(uint32_t)parameter error:(NSError **)error
{
    if (GET_MASK(parameter, NV097_GET_REPORT_TYPE) !=
        NV097_GET_REPORT_TYPE_ZPASS_PIXEL_CNT) {
        return report_error(error, @"Unsupported NV2A report type");
    }
    NV2AMetalPGRAPHReport *report = [NV2AMetalPGRAPHReport new];
    report.parameter = parameter;
    NSMutableArray *frozen = [NSMutableArray new];
    NSMutableArray *continuing = [NSMutableArray new];
    for (NV2AMetalPGRAPHQuery *query in _queries) {
        compact_query(query);
        if (query.open)
            [continuing addObject:query];
        /* A query with no new samples contributes zero at any scale. Its
         * previously reported buffers belong to an earlier FIFO entry. */
        if (query.savedCount == query.reportedCount &&
            query.buffers.count == query.reportedBuffers)
            continue;
        if (!query.open) {
            [frozen addObject:query];
            continue;
        }
        [frozen addObject:frozen_prefix(query)];
        query.reportedCount = query.savedCount;
        query.reportedBuffers = query.buffers.count;
    }
    report.queries = frozen;
    _queries = continuing;
    [_reports addObject:report];
    return YES;
}
/* Count the frozen prefix, and the part published by an earlier report from
 * this same Begin. Both are raw uint64 counters, including wraparound. */
- (BOOL)readCountsForQuery:(NV2AMetalPGRAPHQuery *)query
                     total:(uint64_t *)total
                  previous:(uint64_t *)previous
                     error:(NSError **)error
{
    *total = query.savedCount;
    *previous = query.reportedCount;
    assert(query.reportedBuffers <= query.buffers.count);
    NSUInteger index = 0;
    for (NV2AMetalVisibilityCounter *counter in query.buffers) {
        capture_zero_counter(counter);
        NV2AMetalSurfaceRecording *token = counter.token;
        uint64_t count;
        if (counter.cancelled ||
            (token && (!token.completed || token.cancelled)))
            return report_error(error,
                                @"Native visibility counter is not complete");
        if (counter.captured)
            count = counter.value;
        else if (counter.zeroSamples)
            return report_error(
                error, @"Zero-sample visibility recording is not complete");
        else if (!counter.buffer || counter.offset > counter.buffer.length ||
                 sizeof(count) > counter.buffer.length - counter.offset)
            return report_error(
                error, @"Native visibility counter exceeds its buffer");
        else if (counter.owner == self) {
            NSUInteger slot = counter.offset / sizeof(count);
            if (slot >= _counterCapacity || _counterSlots[slot] != counter ||
                ![self retireCounterAtIndex:slot])
                return report_error(error,
                                    @"Native visibility counter lost its slot");
            count = counter.value;
        } else {
            memcpy(&count,
                   (const uint8_t *)counter.buffer.contents + counter.offset,
                   sizeof(count));
        }
        *total += count;
        if (index++ < query.reportedBuffers)
            *previous += count;
    }
    /* Frozen reports can share counters with the live query and each other.
     * The first read owns the value before the GPU slot is made reusable. */
    compact_query(query);
    return YES;
}
- (BOOL)waitForQueries:(NSArray<NV2AMetalPGRAPHQuery *> *)queries
                error:(NSError **)error
{
    NV2AMetalSurfaceRecording *latest = nil;
    uint64_t latestSerial = 0;
    for (NV2AMetalPGRAPHQuery *query in queries) {
        for (NV2AMetalVisibilityCounter *counter in query.buffers) {
            NV2AMetalSurfaceRecording *token = counter.token;
            if (token.cancelled)
                return report_error(error,
                                    @"Native visibility counter was cancelled");
            if (token && !token.completed &&
                (!latest || counter.recordingSerial > latestSerial)) {
                latest = token;
                latestSerial = counter.recordingSerial;
            }
        }
    }
    /* All counters are recorded on this cache. The latest recording's
     * wait validates its entire feedback prefix, including dependencies. */
    return !latest || [_cache waitForRecording:latest error:error];
}
- (BOOL)processWithError:(NSError **)error
{
    BOOL collected = NO;
    BOOL success = YES;
    NSUInteger completed = 0;
    while (completed < _reports.count) {
        NV2AMetalPGRAPHReport *report = _reports[completed];
        if (report.clear) {
            _result = 0;
            completed++;
            continue;
        }
        for (NV2AMetalPGRAPHQuery *query in report.queries) {
            if (query.open) {
                goto done;
            }
        }
        /* The report owns the frozen query prefix. Later surface submissions
         * only matter if they overlap the CPU destination checked below. */
        if (!collected) {
            if (![_cache collectCompletedWithError:error]) {
                success = NO;
                goto done;
            }
            collected = YES;
        }
        if (![self waitForQueries:report.queries error:error]) {
            success = NO;
            goto done;
        }
        DMAObject dma = nv_dma_load(_d, _d->pgraph.dma_report);
        NSUInteger base = dma.address & 0x07ffffff;
        NSUInteger offset = GET_MASK(report.parameter, NV097_GET_REPORT_OFFSET);
        if (dma.dma_class != NV_DMA_IN_MEMORY_CLASS || offset > dma.limit ||
            15 > dma.limit - offset || base > _cache.vram.length ||
            offset > _cache.vram.length - base ||
            16 > _cache.vram.length - base - offset) {
            success = report_error(error,
                                   @"NV2A report exceeds DMA or VRAM bounds");
            goto done;
        }
        NSUInteger destination = base + offset;
        /* Report destinations may alias a dirty render target. Preserve its
         * untouched pixels and invalidate both surface and texture sources. */
        BOOL ready;
        if (![_cache tryIdleCPUAccessAtAddress:destination
                                        length:16
                                         write:YES
                                     completed:&ready
                                         error:error] ||
            (!ready && ![_cache resolveCPUAccessAtAddress:destination
                                                   length:16
                                                    write:YES
                                                    error:error])) {
            success = NO;
            goto done;
        }
        unsigned scale = _d->pgraph.surface_scale_factor;
        if (!scale || scale > 16384) {
            success = report_error(error, @"Invalid report surface scale");
            goto done;
        }
        uint32_t result = _result;
        uint32_t divisor = scale * scale;
        for (NV2AMetalPGRAPHQuery *query in report.queries) {
            uint64_t total, previous;
            if (![self readCountsForQuery:query total:&total previous:&previous
                                     error:error]) {
                success = NO;
                goto done;
            }
            /* Preserve the existing GLuint-wrap and per-Begin scale policy.
             * Rounding each report's delta would lose fractional samples. */
            result += (uint32_t)total / divisor - (uint32_t)previous / divisor;
        }
        _result = result;
        /* Publish to the validated DMA span. Resolving the DMA object again
         * could redirect the write after the coherence check. Match the
         * shared PGRAPH report's timestamp, count and done fields. */
        uint8_t *data = (uint8_t *)_cache.vram.contents + destination;
        stq_le_p(data, UINT64_C(0x0011223344556677));
        stl_le_p(data + 8, _result);
        stl_le_p(data + 12, 0);
        NV2A_DPRINTF("Report result %" PRIu32 " @%" HWADDR_PRIx, _result,
                     (hwaddr)offset);
        memory_region_set_client_dirty(_d->vram, destination, 16,
                                       DIRTY_MEMORY_VGA);
        memory_region_set_client_dirty(_d->vram, destination, 16,
                                       DIRTY_MEMORY_NV2A_TEX);
        completed++;
    }
done:
    /* Preserve the first failed/unready entry for retry, while retiring the
     * processed FIFO prefix with one array shift. */
    if (completed)
        [_reports removeObjectsInRange:NSMakeRange(0, completed)];
    return success;
}

static void append32(NSMutableData *data, uint32_t value)
{
    value = cpu_to_be32(value);
    [data appendBytes:&value length:4];
}
static void append64(NSMutableData *data, uint64_t value)
{
    value = cpu_to_be64(value);
    [data appendBytes:&value length:8];
}
- (NSData *)snapshotWithActiveQuery:(NV2AMetalPGRAPHQuery *)active
                              error:(NSError **)error
{
    unsigned scale = _d->pgraph.surface_scale_factor;
    if (!scale || scale > 16384) {
        report_error(error, @"Invalid snapshot surface scale");
        return nil;
    }
    NSMutableArray<NV2AMetalPGRAPHQuery *> *queries = [NSMutableArray new];
    NSMapTable *ids = [NSMapTable strongToStrongObjectsMapTable];
    void (^add)(NV2AMetalPGRAPHQuery *) = ^(NV2AMetalPGRAPHQuery *q) {
      if (q && ![ids objectForKey:q]) {
          [ids setObject:@(queries.count) forKey:q];
          [queries addObject:q];
      }
    };
    for (NV2AMetalPGRAPHQuery *q in _queries)
        add(q);
    for (NV2AMetalPGRAPHReport *r in _reports)
        for (NV2AMetalPGRAPHQuery *q in r.queries)
            add(q);
    add(active);
    if (queries.count > UINT32_MAX || _reports.count > UINT32_MAX ||
        _queries.count > UINT32_MAX) {
        report_error(error, @"Too many native report snapshot entries");
        return nil;
    }
    uint64_t length = 32 + queries.count * 20ull + _queries.count * 4ull +
                      _reports.count * 12ull;
    for (NV2AMetalPGRAPHReport *r in _reports) {
        if (r.queries.count > UINT32_MAX)
            return nil;
        length += r.queries.count * 4ull;
    }
    if (length > 64u * 1024 * 1024) {
        report_error(error,
                     @"Native report snapshot exceeds host format limit");
        return nil;
    }
    if (![_cache collectCompletedWithError:error] ||
        ![self waitForQueries:queries error:error])
        return nil;
    NSMutableData *data = [NSMutableData new];
    append32(data, 0x4d345250); /* M4RP, host wire format, not a register. */
    append32(data, 3);
    append32(data, _result);
    append32(data, (uint32_t)queries.count);
    append32(data, (uint32_t)_reports.count);
    append32(data, active ? [[ids objectForKey:active] unsignedIntValue] :
                            UINT32_MAX);
    /* Restored counters and any resumed Begin must use the same physical
     * raster scale; rescaling integer counts would discard fractional samples.
     */
    append32(data, scale);
    for (NV2AMetalPGRAPHQuery *q in queries) {
        uint64_t total, previous;
        if (![self readCountsForQuery:q total:&total previous:&previous
                                 error:error])
            return nil;
        append64(data, total);
        append64(data, previous);
        append32(data, q.open | (q.discarded << 1));
    }
    append32(data, (uint32_t)_queries.count);
    for (NV2AMetalPGRAPHQuery *q in _queries)
        append32(data, [[ids objectForKey:q] unsignedIntValue]);
    for (NV2AMetalPGRAPHReport *r in _reports) {
        append32(data, r.clear);
        append32(data, r.parameter);
        append32(data, (uint32_t)r.queries.count);
        for (NV2AMetalPGRAPHQuery *q in r.queries)
            append32(data, [[ids objectForKey:q] unsignedIntValue]);
    }
    if (data.length > 64u * 1024 * 1024) {
        report_error(error,
                     @"Native report snapshot exceeds host format limit");
        return nil;
    }
    return data;
}
- (BOOL)restoreSnapshot:(NSData *)data
            activeQuery:(NV2AMetalPGRAPHQuery **)active
                  error:(NSError **)error
{
    return [self restoreSnapshot:data
                     activeQuery:active
                    validateOnly:NO
                           error:error];
}
- (BOOL)restoreSnapshot:(NSData *)data
            activeQuery:(NV2AMetalPGRAPHQuery **)active
           validateOnly:(BOOL)validateOnly
                  error:(NSError **)error
{
    const uint8_t *bytes = data.bytes;
    __block NSUInteger cursor = 0;
    __block BOOL valid = data.length <= 64u * 1024 * 1024;
    uint32_t (^read32)(void) = ^uint32_t {
      if (cursor > data.length || data.length - cursor < 4) {
          valid = NO;
          return 0;
      }
      uint32_t value = ldl_be_p(bytes + cursor);
      cursor += 4;
      return value;
    };
    uint64_t (^read64)(void) = ^uint64_t {
      if (cursor > data.length || data.length - cursor < 8) {
          valid = NO;
          return 0;
      }
      uint64_t value = ldq_be_p(bytes + cursor);
      cursor += 8;
      return value;
    };
    uint32_t magic = read32(), version = read32(), result = read32();
    uint32_t nqueries = read32(), nreports = read32(), activeID = read32();
    uint32_t scale = version >= 2 ? read32() : 0;
    unsigned queryBytes = version == 3 ? 20 : 12;
    if (!valid || magic != 0x4d345250 ||
        (version != 1 && version != 2 && version != 3) ||
        (version >= 2 && (!scale || scale > 16384)) ||
        nqueries > (data.length - cursor) / queryBytes ||
        (activeID != UINT32_MAX && activeID >= nqueries))
        return report_error(error, @"Invalid native report snapshot header");
    NSMutableArray<NV2AMetalPGRAPHQuery *> *queries = [NSMutableArray new];
    for (uint32_t i = 0; i < nqueries; i++) {
        NV2AMetalPGRAPHQuery *q = [[NV2AMetalPGRAPHQuery alloc] initQuery];
        q.savedCount = read64();
        q.reportedCount = version == 3 ? read64() : 0;
        uint32_t flags = read32();
        if (flags > 2 || ((flags & 1) && i != activeID))
            valid = NO;
        q.open = flags & 1;
        q.discarded = flags & 2;
        [queries addObject:q];
    }
    NSMutableArray<NV2AMetalPGRAPHQuery *> *pending = [NSMutableArray new];
    NSMutableSet<NV2AMetalPGRAPHQuery *> *owned = [NSMutableSet new];
    uint32_t count = read32();
    if (!valid || count > (data.length - cursor) / 4)
        return report_error(error, @"Invalid native pending query list");
    for (uint32_t i = 0; i < count; i++) {
        uint32_t index = read32();
        if (index >= nqueries || queries[index].discarded ||
            [owned containsObject:queries[index]])
            return report_error(error,
                                @"Invalid native pending query reference");
        [pending addObject:queries[index]];
        [owned addObject:queries[index]];
    }
    NSMutableArray<NV2AMetalPGRAPHReport *> *reports = [NSMutableArray new];
    if (nreports > (data.length - cursor) / 12)
        return report_error(error, @"Invalid native report list");
    for (uint32_t i = 0; i < nreports; i++) {
        NV2AMetalPGRAPHReport *r = [NV2AMetalPGRAPHReport new];
        uint32_t clear = read32();
        r.clear = clear;
        r.parameter = read32();
        count = read32();
        if (!valid || clear > 1 || count > (data.length - cursor) / 4 ||
            (clear && (count || r.parameter)) ||
            (!clear && GET_MASK(r.parameter, NV097_GET_REPORT_TYPE) !=
                           NV097_GET_REPORT_TYPE_ZPASS_PIXEL_CNT))
            return report_error(error, @"Invalid native report entry");
        NSMutableArray *members = [NSMutableArray new];
        for (uint32_t j = 0; j < count; j++) {
            uint32_t index = read32();
            if (index >= nqueries || queries[index].discarded ||
                (version >= 3 && queries[index].open) ||
                [owned containsObject:queries[index]])
                return report_error(error,
                                    @"Invalid native report query reference");
            [members addObject:queries[index]];
            [owned addObject:queries[index]];
        }
        r.queries = members;
        [reports addObject:r];
    }
    if (!valid || cursor != data.length)
        return report_error(error,
                            @"Truncated or trailing native report snapshot");
    for (uint32_t i = 0; i < nqueries; i++) {
        NV2AMetalPGRAPHQuery *q = queries[i];
        if ((!q.discarded && ![owned containsObject:q]) ||
            (q.discarded && i != activeID) ||
            (i == activeID && !q.open && !q.discarded))
            return report_error(error, @"Invalid native query ownership");
    }
    if (validateOnly)
        return YES;
    if (version < 3 && activeID != UINT32_MAX) {
        NV2AMetalPGRAPHQuery *activeQuery = queries[activeID];
        if (activeQuery.discarded) {
            /* Legacy Clear disabled the rest of an enabled Begin. Its active
             * identity retains the enable capture, not a cancelled session. */
            activeQuery.discarded = NO;
            activeQuery.open = YES;
            activeQuery.savedCount = 0;
            [pending addObject:activeQuery];
        } else if (activeQuery.open && ![pending containsObject:activeQuery]) {
            /* Legacy reports could own the active query. The saved counter
             * is the only recoverable prefix: freeze it at the snapshot,
             * then continue without replaying it or rounding it twice. */
            for (NV2AMetalPGRAPHReport *report in reports) {
                NSUInteger index =
                    [report.queries indexOfObjectIdenticalTo:activeQuery];
                if (index != NSNotFound) {
                    NSMutableArray *members = [report.queries mutableCopy];
                    members[index] = frozen_prefix(activeQuery);
                    report.queries = members;
                }
            }
            activeQuery.reportedCount = activeQuery.savedCount;
            [pending addObject:activeQuery];
        }
    }
    [self discard];
    _queries = pending;
    _reports = reports;
    _result = result;
    *active = activeID == UINT32_MAX ? nil : queries[activeID];
    if (version >= 2)
        _d->pgraph.surface_scale_factor = scale;
    return YES;
}
- (void)discard
{
    for (NV2AMetalPGRAPHQuery *query in _queries) {
        query.discarded = YES;
        query.open = NO;
    }
    for (NV2AMetalPGRAPHReport *report in _reports) {
        for (NV2AMetalPGRAPHQuery *query in report.queries) {
            query.discarded = YES;
            query.open = NO;
        }
    }
    [_queries removeAllObjects];
    [_reports removeAllObjects];
    _result = 0;
}
@end

bool pgraph_metal4_validate_report_snapshot(const uint8_t *bytes, size_t size)
{
    @autoreleasepool {
        if (!bytes || size > 64u * 1024 * 1024)
            return false;
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes
                                            length:size
                                      freeWhenDone:NO];
        NV2AMetalPGRAPHReports *validator =
            [[NV2AMetalPGRAPHReports alloc] initForSnapshotValidation];
        NV2AMetalPGRAPHQuery *query = nil;
        return [validator restoreSnapshot:data
                              activeQuery:&query
                             validateOnly:YES
                                    error:NULL];
    }
}
