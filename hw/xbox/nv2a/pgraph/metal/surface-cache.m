/*
 * Native surface cache from gl/surface.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "surface-cache.h"
#include <stdatomic.h>

struct NV2AMetalCPUAccessGuard {
    NSUInteger length, words;
    atomic_bool failed;
    _Atomic(uint64_t) watched[];
};

/* Preserve the three historical watch/dirty bitmaps and the existing reader
 * offsets. Active destination references follow the reader array privately. */
static _Atomic(uint64_t) *
target_page_references(const NV2AMetalCPUAccessGuard *guard)
{
    NSUInteger pages = (guard->length - 1) / 4096 + 1;
    return (_Atomic(uint64_t) *)(guard->watched + 3 * guard->words + pages);
}

static BOOL gpu_targets_touch_pages(const NV2AMetalCPUAccessGuard *guard,
                                    NSUInteger first, NSUInteger last)
{
    const _Atomic(uint64_t) *targets = target_page_references(guard);
    for (NSUInteger word = first / 64; word <= last / 64; word++) {
        unsigned low = word == first / 64 ? first % 64 : 0;
        unsigned high = word == last / 64 ? last % 64 : 63;
        uint64_t mask = (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
        /* Most pages have never been destinations. Keep their old bitmap-only
         * path; only historically watched pages need an active-reference load.
         */
        uint64_t pending =
            atomic_load_explicit(&guard->watched[word], memory_order_acquire) &
            mask;
        while (pending) {
            NSUInteger page = word * 64 + __builtin_ctzll(pending);
            if (atomic_load_explicit(&targets[page], memory_order_acquire))
                return YES;
            pending &= pending - 1;
        }
    }
    return NO;
}

BOOL nv2a_metal_untracked_cpu_access(const NV2AMetalCPUAccessGuard *guard,
                                     NSUInteger address, NSUInteger length,
                                     BOOL write)
{
    if (!guard || address > guard->length || length > guard->length - address ||
        atomic_load_explicit(&guard->failed, memory_order_acquire))
        return NO;
    if (!length)
        return YES;
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    if (!write)
        return !gpu_targets_touch_pages(guard, first, last);
    for (NSUInteger word = first / 64; word <= last / 64; word++) {
        unsigned low = word == first / 64 ? first % 64 : 0;
        unsigned high = word == last / 64 ? last % 64 : 63;
        uint64_t mask = (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
        if (atomic_load_explicit(
                &guard->watched[word + guard->words],
                memory_order_acquire) &
            mask)
            return NO;
    }
    return YES;
}

static BOOL gpu_readers_touch_pages(const NV2AMetalCPUAccessGuard *guard,
                                    NSUInteger first, NSUInteger last)
{
    const _Atomic(uint64_t) *readers = guard->watched + 3 * guard->words;
    for (NSUInteger page = first; page <= last; page++)
        if (atomic_load_explicit(&readers[page], memory_order_acquire))
            return YES;
    return NO;
}

static BOOL cpu_source_write_safe(const NV2AMetalCPUAccessGuard *guard,
                                  NSUInteger address, NSUInteger length)
{
    if (atomic_load_explicit(&guard->failed, memory_order_acquire))
        return NO;
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    return !gpu_targets_touch_pages(guard, first, last) &&
           !gpu_readers_touch_pages(guard, first, last);
}

/* The metadata lock covers both the exact read lists and page references.
 * One page probe can reject all readers on a small CPU store or report.
 * Wider ranges keep the exact scan, including strided holes. */
static BOOL cpu_write_may_overlap_gpu_readers(
    const NV2AMetalCPUAccessGuard *guard, NSUInteger address, NSUInteger length)
{
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    return first != last || gpu_readers_touch_pages(guard, first, last);
}

BOOL nv2a_metal_try_cpu_access(NV2AMetalCPUAccessGuard *guard,
                               NSUInteger address, NSUInteger length,
                               BOOL write)
{
    if (!guard)
        return NO;
    if (nv2a_metal_untracked_cpu_access(guard, address, length, write))
        return YES;
    if (!write || !length || address > guard->length ||
        length > guard->length - address ||
        !cpu_source_write_safe(guard, address, length))
        return NO;
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    for (NSUInteger word = first / 64; word <= last / 64; word++) {
        unsigned low = word == first / 64 ? first % 64 : 0;
        unsigned high = word == last / 64 ? last % 64 : 63;
        uint64_t mask = (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
        mask &= atomic_load_explicit(&guard->watched[word + guard->words],
                                     memory_order_acquire);
        atomic_fetch_or_explicit(&guard->watched[word + 2 * guard->words], mask,
                                 memory_order_release);
    }
    /* A newly registered producer/destination must still take the synchronized
     * path. Dirty bits already published above remain conservative. As with the
     * synchronized callback, ownership covers work registered before the
     * access; the callback returns before QEMU performs the actual RAM store.
     */
    return cpu_source_write_safe(guard, address, length);
}

static BOOL cache_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.surface-cache"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

@interface NV2AMetalCachedSurface ()
@property(nonatomic) NSObject *stateLock;
@property(nonatomic, readwrite) NV2AMetalSurfaceTransfer *transfer;
@property(nonatomic, readwrite) NSUInteger address, reservationLength;
@property(nonatomic, readwrite) uint64_t frame;
@property(nonatomic) uint64_t committedGeneration, pendingGeneration;
/* A writer generation is usable on another queue only after full, ordered
 * Surface feedback through its originating recording. */
@property(nonatomic) uint64_t committedWriterGeneration,
    pendingWriterGeneration;
@property(nonatomic) uint64_t committedWriterSerial, pendingWriterSerial;
@property(nonatomic) uint64_t committedCaptureSerial, pendingCaptureSerial;
@property(nonatomic, readwrite) BOOL valid;
@property(nonatomic) BOOL targetWatchOwned;
@property(nonatomic) BOOL committedDirty, committedUpload, recording;
@property(nonatomic) BOOL pendingDirty, pendingUpload, pendingBorder,
    committedBorder;
- (instancetype)initWithTransfer:(NV2AMetalSurfaceTransfer *)transfer
                         address:(NSUInteger)address
                          length:(NSUInteger)length
                       stateLock:(NSObject *)stateLock;
@end

@class NV2AMetalSurfaceSubmission;

@interface NV2AMetalSurfaceRecording ()
@property(nonatomic, readwrite) BOOL submitted, completed, cancelled;
@property(nonatomic, readwrite) BOOL producersCompleted;
@property(nonatomic, readwrite) BOOL cpuHazardsRetired;
@property(nonatomic) BOOL producerOnlyHazards;
/* Intent is sticky even when an already captured surface is upgraded. Guest
 * spans retain alias evidence without extending a Surface/texture lifetime. */
@property(nonatomic) BOOL hasNonProducerSurfaceCapture;
@property(nonatomic) NSMutableData *nonProducerCaptures;
@property(nonatomic) NSUInteger readEnd, writeEnd, downloadEnd;
@property(nonatomic, nullable) NV2AMetalSubmission *producerSubmission;
@property(nonatomic, weak, nullable) NV2AMetalSurfaceSubmission *producerEntry;
@property(nonatomic) NSUInteger producerSection, dependencyEnd, witnessEnd;
@property(nonatomic) uint64_t producerBatchSerial;
@property(nonatomic, nullable) NSMutableIndexSet *readerPages;
@property(nonatomic, nullable) NSMutableIndexSet *targetPages;
@property(nonatomic, weak, nullable)
    NV2AMetalSurfaceSubmission *submissionEntry;
- (instancetype)initWithSerial:(uint64_t)serial;
@end
@implementation NV2AMetalSurfaceRecording
- (instancetype)initWithSerial:(uint64_t)serial
{
    self = [super init];
    if (self)
        _serial = serial;
    return self;
}
@end

@implementation NV2AMetalCachedSurface {
    _Atomic(uint64_t) _dirtyEpoch;
}
@synthesize recording = _recording, pendingDirty = _pendingDirty,
            committedDirty = _committedDirty;
- (uint64_t)dirtyEpoch
{
    return atomic_load_explicit(&_dirtyEpoch, memory_order_acquire);
}
- (void)invalidateDirtyPublication
{
    /* These private setters run under stateLock. Invalidate before changing
     * a field so an observer cannot skip a transaction still in progress. */
    uint64_t epoch = atomic_load_explicit(&_dirtyEpoch, memory_order_relaxed);
    if (epoch != UINT64_MAX)
        atomic_fetch_add_explicit(&_dirtyEpoch, 1, memory_order_acq_rel);
}
- (void)setRecording:(BOOL)value
{
    if (_recording != value) {
        [self invalidateDirtyPublication];
        _recording = value;
    }
}
- (void)setPendingDirty:(BOOL)value
{
    if (_pendingDirty != value) {
        [self invalidateDirtyPublication];
        _pendingDirty = value;
    }
}
- (void)setCommittedDirty:(BOOL)value
{
    if (_committedDirty != value) {
        [self invalidateDirtyPublication];
        _committedDirty = value;
    }
}
- (instancetype)initWithTransfer:(NV2AMetalSurfaceTransfer *)transfer
                         address:(NSUInteger)address
                          length:(NSUInteger)length
                       stateLock:(NSObject *)stateLock
{
    self = [super init];
    if (self) {
        atomic_init(&_dirtyEpoch, 0);
        _stateLock = stateLock;
        _transfer = transfer;
        _address = address;
        _reservationLength = length;
        _valid = _committedUpload = YES;
    }
    return self;
}
- (uint64_t)generation
{
    @synchronized (_stateLock) {
        return _recording ? _pendingGeneration : _committedGeneration;
    }
}
- (BOOL)dirty
{
    @synchronized (_stateLock) {
        return _recording ? _pendingDirty : _committedDirty;
    }
}
- (BOOL)scanoutClampToBorder
{
    @synchronized (_stateLock) {
        return _recording ? _pendingBorder : _committedBorder;
    }
}
- (BOOL)needsUpload
{
    @synchronized (_stateLock) {
        return _recording ? _pendingUpload : _committedUpload;
    }
}
@end

typedef NV2AMetalVRAMReadSpan NV2AMetalVRAMRead;

@interface NV2AMetalIndependentReads ()
@property(nonatomic, weak) NV2AMetalSurfaceCache *owner;
@property(nonatomic) NV2AMetalCommands *commands;
@property(nonatomic) NSData *spans;
@property(nonatomic) NSRange spanBounds;
@property(nonatomic, nullable) NSIndexSet *readerPages;
@property(nonatomic, nullable) NV2AMetalSubmission *submission;
/* The cache owns a single pending batch, including its sealed sections. */
@property(nonatomic) BOOL hasPendingWitness;
@property(nonatomic, weak, nullable) NV2AMetalSurfaceSubmission *lastWitnessWriter;
@property(nonatomic, weak, nullable)
    NV2AMetalSurfaceSubmission *lastCheckedWitnessWriter;
@property(nonatomic, nullable) NV2AMetalIndependentReads *previousOnQueue;
@property(nonatomic, weak, nullable) NV2AMetalIndependentReads *nextOnQueue;
@property(nonatomic) id<MTLBuffer> completionMarker;
@property(nonatomic) BOOL retired;
- (instancetype)initRecording;
- (BOOL)completedWithError:(NSError **)error;
- (BOOL)waitForFeedbackWithError:(NSError **)error;
@end
@implementation NV2AMetalIndependentReads {
    atomic_bool _feedbackSucceeded;
}
- (instancetype)initRecording
{
    self = [super init];
    if (self)
        atomic_init(&_feedbackSucceeded, false);
    return self;
}

- (BOOL)completedWithError:(NSError **)error
{
    /* Success is final and can be shared by all writers using this scope.
     * A successful receipt alone does not validate any execution witness. */
    NSError *failure = nil;
    BOOL completed = atomic_load_explicit(&_feedbackSucceeded,
                                          memory_order_acquire);
    if (!completed) {
        completed = [_submission completedWithError:&failure];
        if (completed && !failure)
            atomic_store_explicit(&_feedbackSucceeded, true,
                                  memory_order_release);
    }
    if (error)
        *error = failure;
    return completed;
}

- (BOOL)waitForFeedbackWithError:(NSError **)error
{
    NSError *failure = nil;
    if ([self completedWithError:&failure]) {
        if (error)
            *error = failure;
        return !failure;
    }
    if (!_submission || ![_commands waitForSubmission:_submission error:error])
        return NO;
    atomic_store_explicit(&_feedbackSucceeded, true, memory_order_release);
    return YES;
}
@end

static id<MTL4ComputeCommandEncoder>
begin_read_marker_copies(NV2AMetalCommands *commands, NSError **error)
{
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        cache_error(error, @"Could not encode VRAM read completion marker");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    return encoder;
}

static void end_read_marker_copies(id<MTL4ComputeCommandEncoder> encoder)
{
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
}

@interface NV2AMetalReadWitness : NSObject
@property(nonatomic) NV2AMetalIndependentReads *reader;
@property(nonatomic, nullable) id<MTLBuffer> observed;
@property(nonatomic) NSUInteger observedOffset;
@property(nonatomic) BOOL validated, producerCommitted, pendingStorage;
@end
@implementation NV2AMetalReadWitness
@end

/* Both ranges have already passed validRange. Relative arithmetic avoids
 * overflow and checks the first intersected cell without enumerating vertices.
 */
static BOOL read_pattern_overlap(NV2AMetalVRAMReadPattern p, NSUInteger address,
                                 NSUInteger length)
{
    if (!length || !p.length || address >= p.address + p.length ||
        p.address >= address + length)
        return NO;
    if (!p.stride)
        return YES;
    NSUInteger first = MAX(address, p.address) - p.address;
    NSUInteger end = MIN(address + length, p.address + p.length) - p.address;
    NSUInteger within = first % p.stride;
    return within < p.element || p.stride - within < end - first;
}

static BOOL read_span_range_overlap(NSData *data, NSRange bytes,
                                    NSUInteger address, NSUInteger length)
{
    const NV2AMetalVRAMReadPattern *spans = data.bytes;
    for (NSUInteger i = bytes.location / sizeof(*spans);
         i < NSMaxRange(bytes) / sizeof(*spans); i++)
        if (read_pattern_overlap(spans[i], address, length))
            return YES;
    return NO;
}

static BOOL read_spans_overlap(NSData *data, NSUInteger address,
                               NSUInteger length)
{
    return read_span_range_overlap(data, NSMakeRange(0, data.length), address,
                                   length);
}

static BOOL independent_reader_overlaps(NV2AMetalIndependentReads *reader,
                                        NSUInteger address, NSUInteger length)
{
    NSRange bounds = reader.spanBounds;
    return length && bounds.length && address < NSMaxRange(bounds) &&
           bounds.location < address + length &&
           read_spans_overlap(reader.spans, address, length);
}

static BOOL vram_bounds_overlap(NSRange a, NSRange b)
{
    return a.length && b.length && a.location < NSMaxRange(b) &&
           b.location < NSMaxRange(a);
}

static NSRange extend_write_bounds(NSRange bounds, NSUInteger address,
                                   NSUInteger length)
{
    NSRange range = NSMakeRange(address, length);
    return bounds.length ? NSUnionRange(bounds, range) : range;
}

static BOOL read_batch_overlaps(const NV2AMetalVRAMReadPattern *patterns,
                               NSUInteger count, NSRange bounds,
                               NSUInteger address, NSUInteger length)
{
    if (!length || address >= NSMaxRange(bounds) ||
        bounds.location >= address + length)
        return NO;
    for (NSUInteger i = 0; i < count; i++)
        if (read_pattern_overlap(patterns[i], address, length))
            return YES;
    return NO;
}

typedef NS_ENUM(NSUInteger, NV2AMetalVRAMWriterConflict) {
    NV2AMetalVRAMWriterNone,
    NV2AMetalVRAMWriterPending,
    NV2AMetalVRAMWriterSubmitted,
};

/* Each receipt owns its submitted hazard data. Later and pending spans are
 * independent of prefix retirement and never move when an earlier entry ends. */
@interface NV2AMetalSurfaceSubmission : NSObject
@property(nonatomic, strong) NV2AMetalSubmission *submission;
@property(nonatomic) NSOrderedSet<NV2AMetalIndependentReads *> *dependencies;
@property(nonatomic) NSUInteger completedDependencyCount;
@property(nonatomic) NSArray<NV2AMetalReadWitness *> *readWitnesses;
@property(nonatomic) NSArray<NV2AMetalSurfaceRecording *> *recordings;
/* Producer completion remains separate from full raster-token completion. */
@property(nonatomic) NSArray<NV2AMetalSurfaceRecording *> *producerRecordings;
/* A raster-free download prefix owns its CPU hazards separately from the
 * still-open full Surface batch. Command-slot lifetimes remain unchanged. */
@property(nonatomic) NSArray<NV2AMetalSurfaceRecording *> *cpuRecordings;
@property(nonatomic) uint64_t producerBatchSerial;
@property(nonatomic) NSUInteger readEnd, writeEnd, downloadEnd;
@property(nonatomic) NSData *readSpans, *writeSpans;
@property(nonatomic) NSArray<NV2AMetalCachedSurface *> *downloads;
@property(nonatomic) NSRange writeBounds;
@property(nonatomic) NSUInteger queuePosition;
- (BOOL)completedWithError:(NSError **)error;
@end
@implementation NV2AMetalSurfaceSubmission {
    atomic_bool _feedbackSucceeded;
}
- (instancetype)init
{
    self = [super init];
    if (self)
        atomic_init(&_feedbackSucceeded, false);
    return self;
}

- (BOOL)completedWithError:(NSError **)error
{
    /* A receipt is immutable once attached. A successful observation can
     * be reused by cache collection and by waiters outside the metadata lock. */
    if (atomic_load_explicit(&_feedbackSucceeded, memory_order_acquire)) {
        if (error)
            *error = nil;
        return YES;
    }
    NSError *failure = nil;
    BOOL completed = [_submission completedWithError:&failure];
    if (completed && !failure)
        atomic_store_explicit(&_feedbackSucceeded, true, memory_order_release);
    if (error)
        *error = failure;
    return completed;
}
@end

@implementation NV2AMetalSurfaceCache {
    NSObject *_stateLock;
    uint64_t _gpuWriteEpoch;
    NV2AMetalCPUAccessGuard *_cpuAccessGuard;
    NSMutableArray<NV2AMetalCachedSurface *> *_surfaces, *_recordingEntries;
    NV2AMetalSurfaceTexturePool *_texturePool;
    NSMutableArray<NV2AMetalCachedSurface *> *_pendingDownloads;
    NSMutableData *_pendingDownloadGenerations;
    NSUInteger _submittedDownloadCount;
    NV2AMetalVRAMWriteHandler _didWriteVRAM;
    NSError *_failure;
    BOOL _recording;
    BOOL _rasterProducers;
    NSArray<NV2AMetalCachedSurface *> *_rasterTargets;
    uint64_t _generation;
    uint64_t _completedRecordingSerial;
    NV2AMetalCommands *_completedDownloadCommands;
    NSMutableIndexSet *_completedDownloadTargets;
    NV2AMetalSubmission *_completedDownloadSubmission;
    NSMutableData *_vramVersions, *_pendingReads, *_pendingWrites;
    NSRange _pendingWriteBounds, _sealedWriteBounds;
    NSArray<NV2AMetalCachedSurface *> *_overwriteTargets;
    NV2AMetalSurfaceRecording *_token;
    NSMutableArray<NV2AMetalSurfaceRecording *> *_sealedTokens;
    NSUInteger _sealedReadBytes, _sealedWriteBytes, _sealedDownloads,
        _sealedDependencies, _sealedReadWitnesses;
    /* Absolute offsets: sealing/cancel keep their original append-only cuts. */
    NSUInteger _retiredReadBytes, _retiredWriteBytes;
    NSUInteger _retiredDownloads;
    /* Metadata already transferred to an immutable producer-prefix receipt.
     * Pending scanners retain it until feedback; full submission skips it. */
    NSUInteger _prefixReadBytes, _prefixWriteBytes, _prefixDownloads;
    NSMutableArray<NV2AMetalSurfaceSubmission *> *_submissions;
    /* Ordered subset with writes or downloads targeting guest VRAM. */
    NSMutableArray<NV2AMetalSurfaceSubmission *> *_writerSubmissions;
    NSMutableArray<NV2AMetalIndependentReads *> *_independentReads;
    NSMapTable<NV2AMetalCommands *, NV2AMetalIndependentReads *> *_lastReaderOnQueue;
    NSMutableOrderedSet<NV2AMetalIndependentReads *> *_pendingDependencies;
    NSMutableArray<NV2AMetalReadWitness *> *_pendingReadWitnesses;
}

- (instancetype)initWithCommands:(NV2AMetalCommands *)commands
                            vram:(id<MTLBuffer>)vram
                    didWriteVRAM:(NV2AMetalVRAMWriteHandler)handler
                           error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!commands || commands.commandBuffer || vram.device != commands.device ||
        vram.storageMode != MTLStorageModeShared || !vram.length ||
        !vram.contents) {
        cache_error(
            error,
            @"Surface cache requires idle commands and shared Apple VRAM");
        return nil;
    }
    _stateLock = [NSObject new];
    _commands = commands;
    _vram = vram;
    _texturePool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:commands.device];
    NSUInteger pages = (vram.length - 1) / 4096 + 1;
    NSUInteger words = (pages + 63) / 64;
    _cpuAccessGuard = calloc(1, sizeof(*_cpuAccessGuard) +
                                    (3 * words + 2 * pages) *
                                        sizeof(_cpuAccessGuard->watched[0]));
    if (!_cpuAccessGuard) {
        cache_error(error, @"Cannot allocate CPU ownership map");
        return nil;
    }
    _cpuAccessGuard->length = vram.length;
    _cpuAccessGuard->words = words;
    atomic_init(&_cpuAccessGuard->failed, false);
    for (NSUInteger i = 0; i < 3 * words + 2 * pages; i++)
        atomic_init(&_cpuAccessGuard->watched[i], 0);
    _didWriteVRAM = [handler copy];
    _surfaces = [NSMutableArray new];
    _recordingEntries = [NSMutableArray new];
    _pendingDownloads = [NSMutableArray new];
    _pendingDownloadGenerations = [NSMutableData new];
    _sealedTokens = [NSMutableArray new];
    _submissions = [NSMutableArray new];
    _writerSubmissions = [NSMutableArray new];
    _independentReads = [NSMutableArray new];
    _lastReaderOnQueue = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality |
                               NSPointerFunctionsStrongMemory
                   valueOptions:NSPointerFunctionsStrongMemory];
    _pendingDependencies = [NSMutableOrderedSet new];
    _pendingReadWitnesses = [NSMutableArray new];
    _pendingWrites = [NSMutableData new];
    _pendingReads = [NSMutableData new];
    _vramVersions = [NSMutableData
        dataWithLength:((vram.length - 1) / 4096 + 1) * sizeof(uint64_t)];
    return self;
}

- (void)dealloc
{
    /* A submitted helper owns guest RAM independently of the main queue.
     * Drain it before destroying the lock-free CPU guard. */
    [self drainCompletedDownloadsWithError:NULL];
    free(_cpuAccessGuard);
}

- (void)watchCPUReadsAtAddress:(NSUInteger)address length:(NSUInteger)length
{
    if (!length)
        return;
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    BOOL added = NO;
    for (NSUInteger word = first / 64; word <= last / 64; word++) {
        unsigned low = word == first / 64 ? first % 64 : 0;
        unsigned high = word == last / 64 ? last % 64 : 63;
        uint64_t mask = (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
        /* Watch bits are monotone; reader and dirty-state publication uses
         * separate atomics. Covered masks need no new release publication. */
        if ((atomic_load_explicit(&_cpuAccessGuard->watched[word],
                                  memory_order_acquire) &
             mask) != mask)
            atomic_fetch_or_explicit(&_cpuAccessGuard->watched[word], mask,
                                     memory_order_release);
        _Atomic(uint64_t) *writes =
            &_cpuAccessGuard->watched[word + _cpuAccessGuard->words];
        uint64_t old = atomic_load_explicit(writes, memory_order_acquire);
        if ((old & mask) != mask)
            old = atomic_fetch_or_explicit(writes, mask, memory_order_release);
        added |= (old & mask) != mask;
    }
    if (added && _willWatchVRAM)
        _willWatchVRAM(first * 4096,
                       MIN((last + 1) * 4096, _vram.length) - first * 4096);
}

- (void)watchCPUWritesAtAddress:(NSUInteger)address length:(NSUInteger)length
{
    if (!length)
        return;
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    BOOL added = NO;
    for (NSUInteger word = first / 64; word <= last / 64; word++) {
        unsigned low = word == first / 64 ? first % 64 : 0;
        unsigned high = word == last / 64 ? last % 64 : 63;
        uint64_t mask = (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
        _Atomic(uint64_t) *writes =
            &_cpuAccessGuard->watched[word + _cpuAccessGuard->words];
        uint64_t old = atomic_load_explicit(writes, memory_order_acquire);
        if ((old & mask) != mask)
            old = atomic_fetch_or_explicit(writes, mask, memory_order_release);
        added |= (old & mask) != mask;
    }
    if (added && _willWatchVRAM)
        _willWatchVRAM(first * 4096,
                       MIN((last + 1) * 4096, _vram.length) - first * 4096);
}

/* Each registered range owns one reference per touched page. Separate
 * references keep a page protected while another recording is cancelled. */
- (void)addGPUReaderAtAddress:(NSUInteger)address length:(NSUInteger)length
{
    if (!length)
        return;
    _Atomic(uint64_t) *readers =
        _cpuAccessGuard->watched + 3 * _cpuAccessGuard->words;
    NSUInteger last = (address + length - 1) / 4096;
    for (NSUInteger page = address / 4096; page <= last; page++)
        atomic_fetch_add_explicit(&readers[page], 1, memory_order_release);
}

static void retire_page_references(_Atomic(uint64_t) *references, NSRange pages)
{
    for (NSUInteger page = pages.location; page < NSMaxRange(pages); page++) {
        uint64_t previous = atomic_fetch_sub_explicit(&references[page], 1,
                                                      memory_order_release);
        assert(previous);
    }
}

- (void)addTargetReferencesAtAddress:(NSUInteger)address
                              length:(NSUInteger)length
{
    if (!length)
        return;
    /* Keep historical source bits and the frontend hook installed, even when
     * the final active target reference is released later. */
    [self watchCPUReadsAtAddress:address length:length];
    _Atomic(uint64_t) *targets = target_page_references(_cpuAccessGuard);
    NSUInteger last = (address + length - 1) / 4096;
    for (NSUInteger page = address / 4096; page <= last; page++)
        atomic_fetch_add_explicit(&targets[page], 1, memory_order_release);
}

- (void)acquireSurfaceTarget:(NV2AMetalCachedSurface *)surface
{
    if (!surface.targetWatchOwned) {
        [self addTargetReferencesAtAddress:surface.address
                                    length:surface.reservationLength];
        surface.targetWatchOwned = YES;
    }
}
- (void)releaseSurfaceTarget:(NV2AMetalCachedSurface *)surface
{
    if (surface.targetWatchOwned) {
        NSUInteger first = surface.address / 4096;
        NSUInteger last =
            (surface.address + surface.reservationLength - 1) / 4096;
        retire_page_references(target_page_references(_cpuAccessGuard),
                               NSMakeRange(first, last - first + 1));
        surface.targetWatchOwned = NO;
    }
}
- (BOOL)registerTargetAtAddress:(NSUInteger)address
                         length:(NSUInteger)length
                          error:(NSError **)error
{
    if (![self validRange:address length:length error:error])
        return NO;
    if (!length)
        return YES;
    assert(_recording && _token);
    NSMutableIndexSet *pages = _token.targetPages;
    if (!pages) {
        pages = [NSMutableIndexSet new];
        if (!pages)
            return cache_error(error, @"Cannot retain GPU destination pages");
        _token.targetPages = pages;
    }
    NSUInteger last = (address + length - 1) / 4096;
    for (NSUInteger page = address / 4096; page <= last; page++) {
        if ([pages containsIndex:page])
            continue;
        [pages addIndex:page];
        NSUInteger start = page * 4096;
        [self addTargetReferencesAtAddress:start
                                    length:MIN((NSUInteger)4096,
                                               _vram.length - start)];
    }
    return YES;
}
- (void)retireSurfaceTargets:(NV2AMetalSurfaceRecording *)token
{
    _Atomic(uint64_t) *targets = target_page_references(_cpuAccessGuard);
    [token.targetPages enumerateRangesUsingBlock:^(NSRange pages, BOOL *stop) {
      (void)stop;
      retire_page_references(targets, pages);
    }];
    token.targetPages = nil;
}

static NSRange read_page_range(NV2AMetalVRAMReadPattern pattern)
{
    assert(pattern.length);
    NSUInteger first = pattern.address / 4096;
    NSUInteger last = (pattern.address + pattern.length - 1) / 4096;
    return NSMakeRange(first, last - first + 1);
}

static NSMutableIndexSet *add_reader_page_run(NSMutableIndexSet *pages,
                                               NSIndexSet *registered,
                                               NSRange run)
{
    if (!run.length || [registered containsIndexesInRange:run])
        return pages;
    if (!pages)
        pages = [NSMutableIndexSet new];
    [pages addIndexesInRange:run];
    return pages;
}

static NSMutableIndexSet *reader_pattern_pages(
    const NV2AMetalVRAMReadPattern *patterns, NSUInteger count,
    NSIndexSet *registered, NSMutableData *recordedReads)
{
    NSMutableIndexSet *pages = nil;
    NSRange run = { 0, 0 };
    NSUInteger firstRecord = 0;
    for (NSUInteger i = 0; i < count; i++) {
        NV2AMetalVRAMReadPattern p = patterns[i];
        if (!p.length) {
            if (recordedReads && i > firstRecord)
                [recordedReads appendBytes:patterns + firstRecord
                                    length:(i - firstRecord) * sizeof(*patterns)];
            firstRecord = i + 1;
            continue;
        }
        NSRange range = read_page_range(p);
        if (run.length && range.location <= NSMaxRange(run) &&
            run.location <= NSMaxRange(range)) {
            run = NSUnionRange(run, range);
        } else {
            pages = add_reader_page_run(pages, registered, run);
            run = range;
        }
    }
    if (recordedReads && count > firstRecord)
        [recordedReads appendBytes:patterns + firstRecord
                            length:(count - firstRecord) * sizeof(*patterns)];
    return add_reader_page_run(pages, registered, run);
}

- (void)registerReaderPages:(NSIndexSet *)pages
{
    [pages enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
      (void)stop;
      NSUInteger address = range.location * 4096;
      NSUInteger length = MIN(range.length * 4096, _vram.length - address);
      [self watchCPUWritesAtAddress:address length:length];
      [self addGPUReaderAtAddress:address length:length];
    }];
}

- (void)registerSurfaceReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                              count:(NSUInteger)count
{
    assert(_recording && _token);
    NSMutableIndexSet *registered = _token.readerPages;
    NSMutableIndexSet *pages =
        reader_pattern_pages(patterns, count, registered, _pendingReads);
    if (!pages)
        return;
    if (registered) {
        [pages removeIndexes:registered];
        [registered addIndexes:pages];
    } else {
        _token.readerPages = pages;
    }
    [self registerReaderPages:pages];
}

- (void)retireReaderPages:(NSIndexSet *)pages
{
    _Atomic(uint64_t) *readers =
        _cpuAccessGuard->watched + 3 * _cpuAccessGuard->words;
    [pages enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
      (void)stop;
      retire_page_references(readers, range);
    }];
}

- (void)retireIndependentReader:(NV2AMetalIndependentReads *)reader
{
    assert(!reader.retired);
    NV2AMetalIndependentReads *previous = reader.previousOnQueue;
    NV2AMetalIndependentReads *next = reader.nextOnQueue;
    previous.nextOnQueue = next;
    if (next) {
        next.previousOnQueue = previous;
    } else if (previous) {
        [_lastReaderOnQueue setObject:previous forKey:reader.commands];
    } else {
        [_lastReaderOnQueue removeObjectForKey:reader.commands];
    }
    reader.previousOnQueue = nil;
    reader.nextOnQueue = nil;
    if (reader.readerPages) {
        [self retireReaderPages:reader.readerPages];
    } else if (reader.spans.length) {
        const NV2AMetalVRAMReadPattern *span = reader.spans.bytes;
        assert(reader.spans.length == sizeof(*span));
        _Atomic(uint64_t) *readers =
            _cpuAccessGuard->watched + 3 * _cpuAccessGuard->words;
        retire_page_references(readers, read_page_range(*span));
    }
    reader.retired = YES;
}

- (void)retireSurfaceReader:(NV2AMetalSurfaceRecording *)token
{
    [self retireReaderPages:token.readerPages];
    token.readerPages = nil;
}

- (NSUInteger)count
{
    @synchronized (_stateLock) {
        return _surfaces.count;
    }
}

- (uint64_t)gpuWriteEpoch
{
    @synchronized (_stateLock) {
        return _gpuWriteEpoch;
    }
}

- (NV2AMetalSurfaceRecording *)recording
{
    @synchronized (_stateLock) {
        return _token;
    }
}

- (void)stamp:(NSUInteger)address
       length:(NSUInteger)length
      version:(uint64_t)version
{
    if (!length) {
        return;
    }
    uint64_t *pages = _vramVersions.mutableBytes;
    NSUInteger last = (address + length - 1) / 4096;
    for (NSUInteger p = address / 4096; p <= last; p++) {
        if (pages[p] < version) {
            pages[p] = version;
        }
    }
}

/* Without active destination pages, this span cannot overlap a live binding.
 * Bound the probe by the surface scan's size; sparse wide ranges keep it. */
- (BOOL)surfaceTargetsMayOverlapAddress:(NSUInteger)address
                                 length:(NSUInteger)length
{
    if (address > _cpuAccessGuard->length ||
        length > _cpuAccessGuard->length - address ||
        atomic_load_explicit(&_cpuAccessGuard->failed, memory_order_acquire))
        return YES;
    NSUInteger count = _surfaces.count;
    if (!length || !count)
        return NO;
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    if (last - first + 1 > count)
        return YES;
    return !nv2a_metal_untracked_cpu_access(_cpuAccessGuard, address, length,
                                            NO);
}

/* Caller holds the cache lock and has validated the range. */
- (BOOL)sourceVersionForValidatedSpan:(NV2AMetalVRAMReadSpan)span
                              version:(uint64_t *)version
                    containingSurface:(NV2AMetalCachedSurface **)surface
                                error:(NSError **)error
{
    NSUInteger address = span.address, length = span.length;
    [self watchCPUWritesAtAddress:address length:length];
    if (length) {
        NSUInteger first = address / 4096;
        NSUInteger last = (address + length - 1) / 4096;
        BOOL exhausted = _generation == UINT64_MAX;
        uint64_t changedVersion = 0;
        uint64_t *pages = _vramVersions.mutableBytes;
        for (NSUInteger word = first / 64; word <= last / 64; word++) {
            unsigned low = word == first / 64 ? first % 64 : 0;
            unsigned high = word == last / 64 ? last % 64 : 63;
            uint64_t mask =
                (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
            _Atomic(uint64_t) *dirty =
                &_cpuAccessGuard
                     ->watched[word + 2 * _cpuAccessGuard->words];
            if (exhausted) {
                if (atomic_load_explicit(dirty, memory_order_acquire) &
                    mask)
                    return cache_error(
                        error, @"Deferred source generation is exhausted");
            } else {
                uint64_t bits = atomic_fetch_and_explicit(
                                    dirty, ~mask, memory_order_acq_rel) &
                                mask;
                if (bits && !changedVersion)
                    changedVersion = ++_generation;
                while (bits) {
                    NSUInteger page = word * 64 + __builtin_ctzll(bits);
                    pages[page] = MAX(pages[page], changedVersion);
                    bits &= bits - 1;
                }
            }
        }
    }
    *version = 0;
    if (length) {
        const uint64_t *pages = _vramVersions.bytes;
        NSUInteger last = (address + length - 1) / 4096;
        for (NSUInteger p = address / 4096; p <= last; p++) {
            if (pages[p] > *version) {
                *version = pages[p];
            }
        }
        if ([self surfaceTargetsMayOverlapAddress:address length:length]) {
            for (NV2AMetalCachedSurface *s in _surfaces) {
                if (s.address < address + length &&
                    address < s.address + s.reservationLength) {
                    *version = MAX(*version, s.generation);
                    if (surface && !*surface && address >= s.address)
                        *surface = s;
                }
            }
        }
    }
    return YES;
}

- (BOOL)readSourceVersions:(const NV2AMetalVRAMReadSpan *)spans
                      count:(NSUInteger)count
                   versions:(uint64_t *)versions
                    maximum:(uint64_t *)maximum
               firstSurface:(NV2AMetalCachedSurface **)firstSurface
                      error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error])
            return NO;
        if (count && !spans)
            return cache_error(error, @"Missing texture source version spans");
        for (NSUInteger i = 0; i < count; i++)
            if (![self validRange:spans[i].address length:spans[i].length
                            error:error])
                return NO;
        if (!versions && !maximum)
            return cache_error(error, @"Invalid texture source version request");
        uint64_t newest = 0;
        if (firstSurface)
            *firstSurface = nil;
        for (NSUInteger i = 0; i < count; i++) {
            uint64_t observed;
            if (![self sourceVersionForValidatedSpan:spans[i]
                                              version:&observed
                                    containingSurface:i == 0 ? firstSurface : NULL
                                                error:error])
                return NO;
            if (versions)
                versions[i] = observed;
            if (maximum)
                newest = MAX(newest, observed);
        }
        if (maximum)
            *maximum = newest;
        return YES;
    }
}

- (BOOL)sourceVersionAtAddress:(NSUInteger)address
                        length:(NSUInteger)length
                       version:(uint64_t *)version
                         error:(NSError **)error
{
    NV2AMetalVRAMReadSpan span = { address, length };
    return [self sourceVersionForReadSpans:&span count:1 version:version
                                    error:error];
}

- (BOOL)sourceVersionForReadSpans:(const NV2AMetalVRAMReadSpan *)spans
                            count:(NSUInteger)count
                          version:(uint64_t *)version
                            error:(NSError **)error
{
    return [self readSourceVersions:spans count:count versions:NULL
                            maximum:version firstSurface:NULL error:error];
}

- (BOOL)sourceVersionsForReadSpans:(const NV2AMetalVRAMReadSpan *)spans
                             count:(NSUInteger)count
                          versions:(uint64_t *)versions
                      firstSurface:(NV2AMetalCachedSurface **)firstSurface
                             error:(NSError **)error
{
    return [self readSourceVersions:spans count:count versions:versions
                            maximum:NULL firstSurface:firstSurface error:error];
}

- (BOOL)healthy:(NSError **)error
{
    if (_failure) {
        if (error) {
            *error = _failure;
        }
        return NO;
    }
    if (_recording != (_commands.commandBuffer != nil) ||
        _sealedTokens.count != _commands.sealedBufferCount) {
        return cache_error(
            error, @"Surface cache commands were changed outside the cache");
    }
    return YES;
}

- (BOOL)beginNativeRecordingWithError:(NSError **)error
{
    if (![_commands beginWithError:error])
        return NO;
    _recording = YES;
    _token = [[NV2AMetalSurfaceRecording alloc]
        initWithSerial:_commands.recordingSerial];
    _token.producerBatchSerial = _commands.batchSerial;
    return YES;
}

- (BOOL)begin:(NSError **)error
{
    if (![self healthy:error]) {
        return NO;
    }
    if (!_rasterProducers && _commands.hasPendingRasterPass &&
        ![self submitWithError:error])
        return NO;
    if (!_recording) {
        if (_sealedTokens.count && _commands.batchNeedsSubmit &&
            ![self submitWithError:error])
            return NO;
        if (![self collectCompletedWithError:error] ||
            ![self beginNativeRecordingWithError:error]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)beginRecordingWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        return [self begin:error];
    }
}

- (BOOL)beginRasterProducersWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (_rasterProducers)
            return cache_error(error, @"Invalid raster producer scope");
        _rasterProducers = YES;
        return YES;
    }
}
- (void)endRasterProducers
{
    @synchronized(_stateLock) {
        _rasterProducers = NO;
    }
}
- (BOOL)validateRasterContinuationWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (![_commands validateRasterContinuationWithError:error]) {
            for (NV2AMetalIndependentReads *reader in _pendingDependencies) {
                NSError *failure = nil;
                if ([reader completedWithError:&failure] && failure)
                    return [self independentReadFailure:failure error:error];
            }
            return NO;
        }
        return YES;
    }
}
- (BOOL)prepareTextureRead:(NV2AMetalCachedSurface *)surface
                     error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (!surface.valid || ![_surfaces containsObject:surface])
            return cache_error(error, @"Invalid pending raster texture read");
        return !_commands.hasPendingRasterPass ||
               ![_rasterTargets containsObject:surface] ||
               [self submitWithError:error];
    }
}
/* A completed surface can be copied into a private RTT texture ahead of an
 * unrelated suspended raster pass. Keep the source and every pending VRAM
 * owner disjoint; a current upload or an uncertain writer uses begin's normal
 * full-submit path instead. No guest RAM is written by the private copy. */
- (BOOL)canQueuePrivateRTTSnapshot:(NV2AMetalCachedSurface *)surface
{
    return !_rasterProducers && _rasterTargets.count &&
           _commands.hasPendingRasterPass &&
           _commands.recordingAllowsProducerWork &&
           !_commands.batchNeedsSubmit &&
           ![_rasterTargets containsObject:surface] &&
           (!_recording || (_token && !_token.hasNonProducerSurfaceCapture)) &&
           !_overwriteTargets.count &&
           _pendingWrites.length == _sealedWriteBytes &&
           _pendingDownloads.count == _sealedDownloads &&
           [self canDownloadCompletedSurfaces:@[ surface ]];
}
- (NV2AMetalCachedSurface *)prepareSurfaceForRTTSnapshot:
                                (NV2AMetalCachedSurface *)surface
                                                   frame:(uint64_t)frame
                                                   error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self prepareTextureRead:surface error:error])
            return nil;
        NV2AMetalSurfaceConfig config = surface.transfer.config;
        surface = [self prepareSurfaceAtAddress:surface.address
                                         config:&config
                                          frame:frame
                                   forRendering:NO
                                          error:error];
        if (!surface)
            return nil;
        BOOL continuation = [self canQueuePrivateRTTSnapshot:surface];
        BOOL reprepare = continuation;
        if (continuation) {
            NV2AMetalSurfaceTransfer *sourceTransfer = surface.transfer;
            uint64_t sourceGeneration = surface.generation;
            NSArray<NV2AMetalCachedSurface *> *rasterTargets = _rasterTargets;
            NV2AMetalSurfaceRecording *token = _token;
            BOOL recording = _recording;
            id<MTL4CommandBuffer> commandBuffer = _commands.commandBuffer;
            uint64_t batchSerial = _commands.batchSerial;
            NSUInteger sealedCount = _sealedTokens.count;
            NSUInteger readBytes = _pendingReads.length;
            NSUInteger writeBytes = _pendingWrites.length;
            NSUInteger downloadCount = _pendingDownloads.count;
            NSUInteger dependencyCount = _pendingDependencies.count;
            NSUInteger witnessCount = _pendingReadWitnesses.count;
            if (![self validateRasterContinuationWithError:error] ||
                (!recording && ![self collectCompletedWithError:error]))
                return nil;
            /* Collection may notify the VRAM owner. A callback can change the
             * source or even the batch while the recursive guard is held. */
            if (![self healthy:error])
                return nil;
            continuation = surface.transfer == sourceTransfer &&
                           surface.generation == sourceGeneration &&
                           _rasterTargets == rasterTargets && _token == token &&
                           _recording == recording &&
                           _commands.commandBuffer == commandBuffer &&
                           _commands.batchSerial == batchSerial &&
                           _sealedTokens.count == sealedCount &&
                           _pendingReads.length == readBytes &&
                           _pendingWrites.length == writeBytes &&
                           _pendingDownloads.count == downloadCount &&
                           _pendingDependencies.count == dependencyCount &&
                           _pendingReadWitnesses.count == witnessCount &&
                           [self canQueuePrivateRTTSnapshot:surface];
            if (continuation &&
                ![self validateRasterContinuationWithError:error])
                return nil;
        }
        if (!continuation) {
            /* Reenter the original preparation once after a changed callback.
             * Never encode a copy of the stale binding from the first pass. */
            if (reprepare) {
                if (![self prepareTextureRead:surface error:error])
                    return nil;
                surface = [self prepareSurfaceAtAddress:surface.address
                                                 config:&config
                                                  frame:frame
                                           forRendering:NO
                                                  error:error];
                if (!surface)
                    return nil;
            }
            uint64_t preparedGeneration = surface.generation;
            NV2AMetalSurfaceTransfer *preparedTransfer = surface.transfer;
            if (![self begin:error])
                return nil;
            if (reprepare &&
                (surface.generation != preparedGeneration ||
                 surface.transfer != preparedTransfer)) {
                cache_error(error, @"RTT source changed during recording");
                return nil;
            }
        } else if (!_recording &&
                   ![self beginNativeRecordingWithError:error]) {
            return nil;
        }
        if (![self healthy:error] || !surface.valid ||
            ![_surfaces containsObject:surface])
            return nil;
        if (![self captureState:surface error:error])
            return nil;
        return surface;
    }
}
- (BOOL)markRTTSnapshotCaptured:(NV2AMetalCachedSurface *)surface
                          error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (!_recording || !surface.valid || !surface.recording ||
            ![_surfaces containsObject:surface])
            return cache_error(error, @"Invalid surface RTT snapshot capture");
        if (![self captureState:surface error:error])
            return NO;
        surface.pendingBorder = YES;
        return YES;
    }
}
- (BOOL)prepareRasterPass:(MTL4RenderPassDescriptor *)pass
                  targets:(NSArray<NV2AMetalCachedSurface *> *)targets
                    error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (!_rasterProducers)
            return cache_error(error,
                               @"Raster pass requires its producer scope");
        for (NV2AMetalCachedSurface *s in targets)
            if (!s.valid || ![_surfaces containsObject:s] || s.needsUpload)
                return cache_error(error, @"Raster attachment is not prepared");
        if (_commands.hasPendingRasterPass &&
            ![_commands rasterPassMatches:pass] &&
            ![self submitWithError:error])
            return NO;
        if (![self begin:error])
            return NO;
        for (NV2AMetalCachedSurface *s in targets)
            if (![self capture:s error:error])
                return NO;
        _rasterTargets = [targets copy];
        return YES;
    }
}

- (BOOL)capture:(NV2AMetalCachedSurface *)s error:(NSError **)error
{
    _token.hasNonProducerSurfaceCapture = YES;
    if (!_token.nonProducerCaptures)
        _token.nonProducerCaptures = [NSMutableData new];
    const NV2AMetalVRAMRead *captures = _token.nonProducerCaptures.bytes;
    NSUInteger count = _token.nonProducerCaptures.length / sizeof(*captures);
    BOOL found = NO;
    for (NSUInteger i = 0; !found && i < count; i++)
        found = captures[i].address == s.address &&
                captures[i].length == s.reservationLength;
    if (!found) {
        NV2AMetalVRAMRead span = { s.address, s.reservationLength };
        [_token.nonProducerCaptures appendBytes:&span length:sizeof(span)];
    }
    return [self captureState:s error:error];
}

/* Only uploads, private RTT snapshots and downloads may enter without recording
 * a non-producer intent. Snapshot deduplication must never hide an upgrade. */
- (BOOL)captureState:(NV2AMetalCachedSurface *)s error:(NSError **)error
{
    /* Every section that can use this target owns its transfer until full
     * command feedback, including a new section opened by a raster boundary. */
    if (![s.transfer textureForCommands:_commands error:error])
        return NO;
    if (!s.recording) {
        s.pendingDirty = s.committedDirty;
        s.pendingUpload = s.committedUpload;
        s.pendingBorder = s.committedBorder;
        s.pendingGeneration = s.committedGeneration;
        s.pendingWriterGeneration = s.committedWriterGeneration;
        s.pendingWriterSerial = s.committedWriterSerial;
        s.pendingCaptureSerial = _token.serial;
        s.recording = YES;
        [_recordingEntries addObject:s];
    }
    return YES;
}

- (BOOL)validRange:(NSUInteger)address
            length:(NSUInteger)length
             error:(NSError **)error
{
    if (address > _vram.length || length > _vram.length - address) {
        return cache_error(error, @"Surface cache range exceeds VRAM");
    }
    return YES;
}

- (NSArray<NV2AMetalCachedSurface *> *)overlaps:(NSUInteger)address
                                         length:(NSUInteger)length
{
    NSMutableArray *selected = [NSMutableArray new];
    if (length) {
        for (NV2AMetalCachedSurface *s in _surfaces) {
            if (s.address < address + length &&
                address < s.address + s.reservationLength) {
                [selected addObject:s];
            }
        }
    }
    return selected;
}

- (NV2AMetalCachedSurface *)surfaceContainingAddress:(NSUInteger)address
{
    @synchronized (_stateLock) {
        for (NV2AMetalCachedSurface *s in _surfaces) {
            if (address >= s.address && address - s.address < s.reservationLength) {
                return s;
            }
        }
        return nil;
    }
}

- (BOOL)download:(NSArray<NV2AMetalCachedSurface *> *)surfaces
           error:(NSError **)error
{
    if (surfaces.count > 1 && !_recording && _sealedTokens.count &&
        _independentReads.count) {
        /* The first dirty surface may open the recording before a later
         * surface introduces a queue wait. Inspect the whole operation at
         * the accepted boundary, before encoding any of its downloads. */
        NSArray<NV2AMetalIndependentReads *> *readers =
            [self independentReadDependenciesMatching:
              ^BOOL(NV2AMetalIndependentReads *reader) {
              for (NV2AMetalCachedSurface *s in surfaces)
                  if (s.dirty && independent_reader_overlaps(
                                     reader, s.address, s.reservationLength))
                      return YES;
              return NO;
            } error:error];
        if (!readers || ![self submitAcceptedPrefixBeforeReaders:readers
                                                         error:error])
            return NO;
    }
    for (NV2AMetalCachedSurface *s in surfaces) {
        if (!s.dirty) {
            continue;
        }
        if (![self prepareTextureRead:s error:error])
            return NO;
        if (![self orderAfterIndependentReadsAtAddress:s.address
                                                length:s.reservationLength
                                                 error:error])
            return NO;
        if (![self begin:error]) {
            return NO;
        }
        if (![self captureState:s error:error])
            return NO;
        if (![self registerTargetAtAddress:s.address
                                    length:s.reservationLength
                                     error:error])
            return NO;
        if (![s.transfer encodeDownloadToBuffer:_vram
                                         offset:s.address
                                        swizzle:YES
                                           flip:NO
                                      downscale:YES
                                       commands:_commands
                                          error:error]) {
            return NO;
        }
        s.pendingDirty = NO;
        [_pendingDownloads addObject:s];
        uint64_t generation = s.generation;
        [_pendingDownloadGenerations appendBytes:&generation
                                          length:sizeof(generation)];
        _pendingWriteBounds = extend_write_bounds(
            _pendingWriteBounds, s.address, s.reservationLength);
    }
    return YES;
}

- (BOOL)markRTTSampling:(NV2AMetalCachedSurface *)surface
                  error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error] || !surface.valid ||
            ![_surfaces containsObject:surface] || ![self begin:error])
            return cache_error(error, @"Invalid surface RTT sampling capture");
        if (![self capture:surface error:error])
            return NO;
        surface.pendingBorder = YES;
        return YES;
    }
}
- (BOOL)currentRecordingHasProducerOnlyHazards
{
    return !_commands.hasPendingRasterPass &&
           !_token.hasNonProducerSurfaceCapture && !_overwriteTargets.count;
}
- (void)acceptRecording
{
    _token.producerOnlyHazards = [self currentRecordingHasProducerOnlyHazards];
    _token.readEnd = _pendingReads.length;
    _token.writeEnd = _pendingWrites.length;
    _token.downloadEnd = _pendingDownloads.count;
    for (NV2AMetalCachedSurface *s in _recordingEntries) {
        s.committedDirty = s.pendingDirty;
        s.committedUpload = s.pendingUpload;
        s.committedBorder = s.pendingBorder;
        s.committedGeneration = s.pendingGeneration;
        s.committedWriterGeneration = s.pendingWriterGeneration;
        s.committedWriterSerial = s.pendingWriterSerial;
        s.committedCaptureSerial = s.pendingCaptureSerial;
        s.recording = NO;
    }
    [_recordingEntries removeAllObjects];
    _token.producerSection = _sealedTokens.count + 1;
    _token.dependencyEnd = _pendingDependencies.count;
    _token.witnessEnd = _pendingReadWitnesses.count;
    [_sealedTokens addObject:_token];
    _token = nil;
    _recording = NO;
    _sealedReadBytes = _pendingReads.length;
    _sealedWriteBytes = _pendingWrites.length;
    _sealedDownloads = _pendingDownloads.count;
    _sealedWriteBounds = _pendingWriteBounds;
    _sealedDependencies = _pendingDependencies.count;
    _sealedReadWitnesses = _pendingReadWitnesses.count;
}

- (BOOL)checkpointWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (_recording) {
            /* A failed full-batch submission must leave the newest section
             * cancellable, rather than accepting a draw the caller retries. */
            if (_overwriteTargets.count ||
                _sealedTokens.count + 1 == NV2AMetalCommandBatchLimit ||
                _commands.batchNeedsSubmit)
                return [self submitWithError:error];
            if (![_commands sealWithError:error])
                return NO;
            [self acceptRecording];
        }
        return YES;
    }
}

- (BOOL)submitWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error]) {
            return NO;
        }
        if (!_recording && !_sealedTokens.count) {
            return YES;
        }
        if (![_commands submitWithError:error]) {
            for (NV2AMetalIndependentReads *reader in _pendingDependencies) {
                NSError *failure = nil;
                if ([reader completedWithError:&failure] && failure)
                    return [self independentReadFailure:failure error:error];
            }
            return NO;
        }
        _rasterTargets = nil;
        if (_recording)
            [self acceptRecording];
        NV2AMetalSurfaceSubmission *submitted =
            [NV2AMetalSurfaceSubmission new];
        submitted.submission = _commands.lastSubmitted;
        submitted.dependencies = [_pendingDependencies copy];
        NSMutableArray *uncommittedWitnesses = [NSMutableArray new];
        for (NV2AMetalReadWitness *witness in _pendingReadWitnesses) {
            witness.reader.hasPendingWitness = NO;
            witness.pendingStorage = NO;
            if (!witness.producerCommitted)
                [uncommittedWitnesses addObject:witness];
            else if (witness.validated)
                witness.observed = nil;
        }
        submitted.readWitnesses = uncommittedWitnesses;
        [_pendingReadWitnesses removeAllObjects];
        [_pendingDependencies removeAllObjects];
        NSUInteger readStart = MAX(_retiredReadBytes, _prefixReadBytes);
        NSUInteger writeStart = MAX(_retiredWriteBytes, _prefixWriteBytes);
        /* Transfer these backing stores. New recordings get private mutable
         * storage instead of copying into and compacting aggregate arrays. */
        submitted.readSpans =
            readStart ? [_pendingReads
                            subdataWithRange:NSMakeRange(readStart,
                                                         _pendingReads.length -
                                                             readStart)] :
            _pendingReads.length ? _pendingReads :
                                   [NSData data];
        submitted.writeSpans =
            writeStart ?
                [_pendingWrites
                    subdataWithRange:NSMakeRange(writeStart,
                                                 _pendingWrites.length -
                                                     writeStart)] :
            _pendingWrites.length ? _pendingWrites :
                                    [NSData data];
        submitted.downloads =
            _prefixDownloads ?
                [_pendingDownloads
                    subarrayWithRange:NSMakeRange(_prefixDownloads,
                                                  _pendingDownloads.count -
                                                      _prefixDownloads)] :
            _pendingDownloads.count ? _pendingDownloads :
                                      @[];
        _submittedDownloadCount += submitted.downloads.count;
        submitted.recordings = _sealedTokens;
        if (_submissions.count)
            submitted.queuePosition = _submissions.lastObject.queuePosition + 1;
        [_submissions addObject:submitted];
        /* Only a committed writer can bound a reader's feedback prefix. */
        for (NV2AMetalReadWitness *witness in submitted.readWitnesses) {
            witness.reader.hasPendingWitness = NO;
            witness.reader.lastWitnessWriter = submitted;
        }
        if (_pendingWrites.length)
            _pendingWrites = [NSMutableData new];
        for (NV2AMetalCachedSurface *s in _overwriteTargets) {
            s.valid = NO;
            [_surfaces removeObjectIdenticalTo:s];
            [self releaseSurfaceTarget:s];
        }
        _overwriteTargets = nil;
        if (_pendingReads.length)
            _pendingReads = [NSMutableData new];
        for (NV2AMetalCachedSurface *s in submitted.downloads) {
            [self stamp:s.address
                 length:s.reservationLength
                version:s.generation];
        }
        submitted.writeBounds = _pendingWriteBounds;
        if (writeStart || _prefixDownloads) {
            NSRange active = NSMakeRange(0, 0);
            const NV2AMetalVRAMRead *writes = submitted.writeSpans.bytes;
            for (NSUInteger i = 0;
                 i < submitted.writeSpans.length / sizeof(*writes); i++)
                active = extend_write_bounds(active, writes[i].address,
                                             writes[i].length);
            for (NV2AMetalCachedSurface *surface in submitted.downloads)
                active = extend_write_bounds(active, surface.address,
                                             surface.reservationLength);
            submitted.writeBounds = active;
        }
        if (submitted.writeBounds.length)
            [_writerSubmissions addObject:submitted];
        _pendingWriteBounds = _sealedWriteBounds = NSMakeRange(0, 0);
        if (_pendingDownloads.count)
            _pendingDownloads = [NSMutableArray new];
        _pendingDownloadGenerations.length = 0;
        for (NV2AMetalSurfaceRecording *token in submitted.recordings) {
            token.submissionEntry = submitted;
            token.submitted = YES;
        }
        _sealedTokens = [NSMutableArray new];
        _sealedReadBytes = _sealedWriteBytes = _sealedDownloads = 0;
        _retiredReadBytes = _retiredWriteBytes = 0;
        _retiredDownloads = 0;
        _prefixReadBytes = _prefixWriteBytes = _prefixDownloads = 0;
        _sealedDependencies = _sealedReadWitnesses = 0;
        return YES;
    }
}

- (void)cancel
{
    @synchronized(_stateLock) {
        if (!_recording) {
            return;
        }
        [_commands cancelUnsealed];
        if (!_commands.hasPendingRasterPass)
            _rasterTargets = nil;
        _token.cancelled = YES;
        [self retireSurfaceReader:_token];
        [self retireSurfaceTargets:_token];
        _token = nil;
        for (NV2AMetalCachedSurface *s in _recordingEntries) {
            s.recording = NO;
        }
        [_recordingEntries removeAllObjects];
        [_pendingDependencies
            removeObjectsInRange:NSMakeRange(_sealedDependencies,
                                             _pendingDependencies.count -
                                                 _sealedDependencies)];
        [self discardPendingWitnessesAfter:_sealedReadWitnesses];
        [_pendingDownloads
            removeObjectsInRange:NSMakeRange(_sealedDownloads,
                                             _pendingDownloads.count -
                                                 _sealedDownloads)];
        _pendingDownloadGenerations.length =
            _sealedDownloads * sizeof(uint64_t);
        _pendingReads.length = _sealedReadBytes;
        _pendingWrites.length = _sealedWriteBytes;
        _pendingWriteBounds = _sealedWriteBounds;
        _overwriteTargets = nil;
        _recording = NO;
    }
}

- (void)discardPendingWitnessesAfter:(NSUInteger)count
{
    NSUInteger end = _pendingReadWitnesses.count;
    for (NSUInteger i = count; i < end; i++)
        _pendingReadWitnesses[i].reader.hasPendingWitness = NO;
    [_pendingReadWitnesses removeObjectsInRange:NSMakeRange(count, end - count)];
}

- (BOOL)independentReadFailure:(NSError *)failure error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (!failure)
            cache_error(&failure, @"Independent VRAM reader completion failed");
        _failure = failure;
        atomic_store_explicit(&_cpuAccessGuard->failed, true,
                              memory_order_release);
        if (error)
            *error = failure;
        return NO;
    }
}

- (BOOL)validateReadWitness:(NV2AMetalReadWitness *)witness
                      error:(NSError **)error
{
    if (witness.validated)
        return YES;
    id<MTLBuffer> buffer = witness.observed;
    assert(buffer);
    uint64_t observed;
    memcpy(&observed, (const uint8_t *)buffer.contents + witness.observedOffset,
           sizeof(observed));
    if (observed == 1) {
        /* Every caller holds the metadata lock and has confirmed the writer's
         * feedback. The GPU copy is final; later retirement needs the result.
         */
        witness.validated = YES;
        /* A still-open batch may append another witness in this same page.
         * Keep its backing buffer until the pending arena is transferred. */
        if (!witness.pendingStorage)
            witness.observed = nil;
        return YES;
    }
    NSError *failure = nil;
    cache_error(&failure, @"VRAM write executed before its GPU readers completed");
    return [self independentReadFailure:failure error:error];
}

/* The owner holds the metadata guard. Keep a completed reader's scope until
 * every submitted writer that can invalidate its result has passed its
 * execution witness, including the writer queue's earlier feedback prefix. */
- (BOOL)checkReadWitnessesForReader:(NV2AMetalIndependentReads *)reader
                          completed:(BOOL *)completed
                              error:(NSError **)error
{
    *completed = NO;
    NV2AMetalSurfaceSubmission *lastWriter = reader.lastWitnessWriter;
    if (!lastWriter) {
        *completed = YES;
        return YES;
    }
    /* Feedback and witnesses already checked for this reader stay valid.
     * A retired cursor is outside the current queue and starts at its head. */
    NV2AMetalSurfaceSubmission *checked = reader.lastCheckedWitnessWriter;
    NSUInteger start = [self prefixThroughSubmission:checked];
    if (start && checked == lastWriter) {
        *completed = YES;
        return YES;
    }
    for (NSUInteger i = start; i < _submissions.count; i++) {
        NV2AMetalSurfaceSubmission *writer = _submissions[i];
        NSError *failure = nil;
        BOOL full = [writer completedWithError:&failure];
        BOOL ready = full;
        if (!ready && writer == lastWriter &&
            writer.submission.hasSeparateProducerFeedback)
            ready = [writer.submission completedProducersWithError:&failure];
        if (!ready) {
            if (i != start)
                reader.lastCheckedWitnessWriter = checked;
            return YES;
        }
        if (failure)
            return [self independentReadFailure:failure error:error];
        for (NV2AMetalReadWitness *witness in writer.readWitnesses)
            if (witness.reader == reader &&
                ![self validateReadWitness:witness error:error])
                return NO;
        if (writer == lastWriter) {
            /* Only full feedback can become the cursor for a future writer.
             * This tail's witnesses are compute-owned, not raster-owned. */
            reader.lastCheckedWitnessWriter = full ? writer : checked;
            *completed = YES;
            return YES;
        }
        checked = writer;
    }
    NSError *failure = nil;
    cache_error(&failure, @"Missing VRAM reader's submitted writer");
    return [self independentReadFailure:failure error:error];
}

/* Explicit completion waits through a shared writer prefix. Inspect that
 * prefix once, retaining only the readers whose last writer is still ahead. */
- (BOOL)validateReadWitnessesForPrefix:
            (NSArray<NV2AMetalIndependentReads *> *)prefix
                           producerTail:(NV2AMetalSurfaceSubmission *)tail
                                 error:(NSError **)error
{
    NV2AMetalIndependentReads *first = nil;
    NSHashTable<NV2AMetalIndependentReads *> *remaining = nil;
    for (NV2AMetalIndependentReads *reader in prefix) {
        if (!reader.lastWitnessWriter)
            continue;
        if (!first) {
            first = reader;
            continue;
        }
        if (!remaining) {
            remaining = [NSHashTable
                hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
            [remaining addObject:first];
        }
        [remaining addObject:reader];
    }
    if (!first)
        return YES;
    if (!remaining) {
        BOOL checked = NO;
        if (![self checkReadWitnessesForReader:first completed:&checked
                                         error:error])
            return NO;
        if (checked)
            return YES;
    } else {
        for (NV2AMetalSurfaceSubmission *writer in _submissions) {
            NSError *failure = nil;
            BOOL ready = [writer completedWithError:&failure];
            if (!ready && writer == tail && writer.submission.hasSeparateProducerFeedback)
                ready = [writer.submission completedProducersWithError:&failure];
            if (!ready)
                break;
            if (failure)
                return [self independentReadFailure:failure error:error];
            for (NV2AMetalReadWitness *witness in writer.readWitnesses) {
                NV2AMetalIndependentReads *reader = witness.reader;
                if (![remaining containsObject:reader])
                    continue;
                if (![self validateReadWitness:witness error:error])
                    return NO;
                if (reader.lastWitnessWriter == writer)
                    [remaining removeObject:reader];
            }
            if (!remaining.count)
                return YES;
            if (writer == tail)
                break;
        }
    }
    NSError *failure = nil;
    cache_error(&failure, @"GPU reader execution witness feedback is missing");
    return [self independentReadFailure:failure error:error];
}

typedef NSMapTable<NV2AMetalCommands *,
                   NSMutableArray<NV2AMetalIndependentReads *> *>
    NV2AMetalReaderPrefixes;

static NV2AMetalReaderPrefixes *
defer_independent_reader(NV2AMetalReaderPrefixes *prefixes,
                         NV2AMetalIndependentReads *reader)
{
    if (!prefixes) {
        prefixes = [NSMapTable
            mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                       valueOptions:NSPointerFunctionsStrongMemory];
    }
    NV2AMetalCommands *queue = reader.commands;
    NSMutableArray *prefix = [prefixes objectForKey:queue];
    if (!prefix) {
        prefix = [NSMutableArray new];
        [prefixes setObject:prefix forKey:queue];
    }
    [prefix addObject:reader];
    return prefixes;
}

- (BOOL)waitForIndependentReader:(NV2AMetalIndependentReads *)reader
                           error:(NSError **)error
{
    NSError *failure = nil;
    /* Native feedback is final. Still inspect each earlier receipt because
     * a later successful callback says nothing about earlier feedback. */
    if (![reader waitForFeedbackWithError:&failure])
        return [self independentReadFailure:failure error:error];
    return YES;
}

- (BOOL)waitForIndependentReadsAtAddress:(NSUInteger)address
                                  length:(NSUInteger)length
                                     all:(BOOL)all
                                   error:(NSError **)error
{
    NSArray<NV2AMetalIndependentReads *> *readers;
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (!_independentReads.count)
            return YES;
        if (!all &&
            (!length || !cpu_write_may_overlap_gpu_readers(
                            _cpuAccessGuard, address, length)))
            return YES;
        readers = [_independentReads copy];
    }
    for (NV2AMetalIndependentReads *reader in readers) {
        if (!all && !independent_reader_overlaps(reader, address, length))
            continue;
        if (!reader.submission) {
            return cache_error(
                error,
                @"Submit or cancel independent VRAM reads before writing");
        }
        /* The selected queue prefix also needs its execution witnesses.
         * Other queues and later receipts do not own these CPU bytes. */
        if (![self completeIndependentReads:reader error:error])
            return NO;
    }
    return YES;
}

- (BOOL)appendIndependentReadDependency:(NV2AMetalIndependentReads *)reader
                                      to:(NSMutableArray *)required
                                   error:(NSError **)error
{
    if (!reader.submission)
        return cache_error(error,
                           @"Submit or cancel independent VRAM reads before writing");
    NSError *failure = nil;
    if ([reader completedWithError:&failure] && failure)
        return [self independentReadFailure:failure error:error];
    [required addObject:reader];
    return YES;
}

- (NSArray<NV2AMetalIndependentReads *> *)
    independentReadDependenciesMatching:
        (NS_NOESCAPE BOOL (^)(NV2AMetalIndependentReads *))matches
                                   error:(NSError **)error
{
    /* Avoid building per-queue prefixes for a completely disjoint write. */
    NSUInteger count = _independentReads.count, firstMatch = 0;
    while (firstMatch < count && !matches(_independentReads[firstMatch]))
        firstMatch++;
    if (firstMatch == count)
        return @[];
    NSMutableArray<NV2AMetalIndependentReads *> *required =
        [NSMutableArray new];
    NV2AMetalReaderPrefixes *deferred = nil;
    for (NSUInteger i = 0; i < count; i++) {
        NV2AMetalIndependentReads *reader = _independentReads[i];
        if (i < firstMatch || (i > firstMatch && !matches(reader))) {
            deferred = defer_independent_reader(deferred, reader);
            continue;
        }
        /* A GPU event orders execution, not callback arrival. Retain and
         * validate each earlier receipt once. Registration and submission
         * recheck feedback that can arrive after this discovery pass. */
        NSMutableArray *prefix = [deferred objectForKey:reader.commands];
        for (NV2AMetalIndependentReads *prior in prefix)
            if (![self appendIndependentReadDependency:prior
                                                   to:required error:error])
                return nil;
        if (![self appendIndependentReadDependency:reader
                                               to:required error:error])
            return nil;
        [prefix removeAllObjects];
    }
    return required;
}

- (BOOL)submitAcceptedPrefixBeforeReaders:
            (NSArray<NV2AMetalIndependentReads *> *)readers
                                    error:(NSError **)error
{
    if (!_recording && _sealedTokens.count) {
        for (NV2AMetalIndependentReads *reader in readers) {
            if (![_pendingDependencies containsObject:reader] &&
                ![reader completedWithError:NULL]) {
                /* Queue waits apply to the whole commit. Keep an accepted
                 * prefix ahead of a new dependency owned by its successor. */
                return [self submitWithError:error];
            }
        }
    }
    return YES;
}

- (BOOL)orderAfterIndependentReadsAtAddress:(NSUInteger)address
                                     length:(NSUInteger)length
                                      error:(NSError **)error
{
    if (![self healthy:error])
        return NO;
    if (!_independentReads.count || !length)
        return YES;
    NSArray<NV2AMetalIndependentReads *> *required =
        [self independentReadDependenciesMatching:
          ^BOOL(NV2AMetalIndependentReads *reader) {
          return independent_reader_overlaps(reader, address, length);
        } error:error];
    if (!required ||
        ![self submitAcceptedPrefixBeforeReaders:required error:error])
        return NO;
    if (required.count && ![self begin:error])
        return NO;
    NSMutableArray<NV2AMetalReadWitness *> *newWitnesses = nil;
    for (NV2AMetalIndependentReads *reader in required) {
        if (![_commands orderAfterSubmission:reader.submission
                                fromCommands:reader.commands
                                       error:error]) {
            NSError *failure = nil;
            if ([reader completedWithError:&failure] && failure)
                return [self independentReadFailure:failure error:error];
            return NO;
        }
        [_pendingDependencies addObject:reader];
        if (!independent_reader_overlaps(reader, address, length))
            continue;
        NSError *failure = nil;
        if ([reader completedWithError:&failure]) {
            if (failure)
                return [self independentReadFailure:failure error:error];
            continue; /* CPU feedback already precedes this writer's submit. */
        }
        if (reader.hasPendingWitness)
            continue;
        if (!reader.completionMarker)
            return cache_error(
                error, @"Missing submitted VRAM read completion marker");
        /* Each pending batch owns its pages. Cancelled suffix slots can be
         * reused because their copies were never submitted. */
        const NSUInteger markersPerPage = 64;
        NSUInteger count = _pendingReadWitnesses.count + newWitnesses.count;
        NSUInteger offset = (count % markersPerPage) * sizeof(uint64_t);
        id<MTLBuffer> observed;
        if (offset) {
            NV2AMetalReadWitness *last = newWitnesses.lastObject ?:
                _pendingReadWitnesses.lastObject;
            observed = last.observed;
        } else {
            observed = [_commands.device
                newBufferWithLength:markersPerPage * sizeof(uint64_t)
                            options:MTLResourceStorageModeShared];
        }
        if (!observed)
            return cache_error(
                error, @"Could not allocate VRAM read completion witness");
        memset((uint8_t *)observed.contents + offset, 0, sizeof(uint64_t));
        if (![_commands addResource:reader.completionMarker error:error] ||
            ![_commands addResource:observed error:error])
            return NO;
        NV2AMetalReadWitness *witness = [NV2AMetalReadWitness new];
        witness.reader = reader;
        witness.observed = observed;
        witness.observedOffset = offset;
        if (!newWitnesses)
            newWitnesses = [NSMutableArray new];
        [newWitnesses addObject:witness];
    }
    if (!newWitnesses.count)
        return YES;
    /* Snapshot every marker before the conflicting VRAM write. A later
     * successful callback cannot make a timed-out queue dependency safe. */
    id<MTL4ComputeCommandEncoder> encoder =
        begin_read_marker_copies(_commands, error);
    if (!encoder)
        return NO;
    for (NV2AMetalReadWitness *witness in newWitnesses) {
        [encoder copyFromBuffer:witness.reader.completionMarker
                   sourceOffset:0
                       toBuffer:witness.observed
              destinationOffset:witness.observedOffset
                           size:sizeof(uint64_t)];
    }
    end_read_marker_copies(encoder);
    for (NV2AMetalReadWitness *witness in newWitnesses)
        witness.reader.hasPendingWitness = YES;
    [_pendingReadWitnesses addObjectsFromArray:newWitnesses];
    return YES;
}

/* The caller holds the metadata guard and has confirmed this prefix entry
 * and its source receipts. Publish only after validating GPU execution. */
- (BOOL)retireSurfaceSubmission:(NV2AMetalSurfaceSubmission *)submitted
                          error:(NSError **)error
{
    assert(_submissions.firstObject == submitted);
    for (NV2AMetalReadWitness *witness in submitted.readWitnesses) {
        if (![self validateReadWitness:witness error:error])
            return NO;
        if (witness.reader.lastWitnessWriter == submitted)
            witness.reader.lastWitnessWriter = nil;
    }
    submitted.readSpans = nil;
    submitted.writeSpans = nil;
    for (NV2AMetalSurfaceRecording *recording in submitted.producerRecordings) {
        recording.producersCompleted = YES;
        recording.producerEntry = nil;
    }
    for (NV2AMetalSurfaceRecording *recording in submitted.cpuRecordings) {
        [self retireSurfaceReader:recording];
        [self retireSurfaceTargets:recording];
        recording.cpuHazardsRetired = YES;
    }
    if (submitted.cpuRecordings.count &&
        submitted.producerBatchSerial == _commands.batchSerial) {
        assert(submitted.readEnd <= _pendingReads.length &&
               submitted.writeEnd <= _pendingWrites.length &&
               submitted.downloadEnd <= _pendingDownloads.count);
        _retiredReadBytes = MAX(_retiredReadBytes, submitted.readEnd);
        _retiredWriteBytes = MAX(_retiredWriteBytes, submitted.writeEnd);
        _retiredDownloads = MAX(_retiredDownloads, submitted.downloadEnd);
    }
    submitted.cpuRecordings = nil;
    for (NV2AMetalSurfaceRecording *recording in submitted.recordings) {
        [self retireSurfaceReader:recording];
        [self retireSurfaceTargets:recording];
        recording.producersCompleted = YES;
        recording.completed = YES;
        _completedRecordingSerial =
            MAX(_completedRecordingSerial, recording.serial);
        recording.submissionEntry = nil;
    }
    if (_writerSubmissions.firstObject == submitted)
        [_writerSubmissions removeObjectAtIndex:0];
    [_submissions removeObjectAtIndex:0];
    NSArray<NV2AMetalCachedSurface *> *downloads = submitted.downloads;
    assert(_submittedDownloadCount >= downloads.count);
    _submittedDownloadCount -= downloads.count;
    submitted.downloads = nil;
    /* Receipt metadata is retired before notifying clients. The transferred
     * list keeps the surfaces alive without copying or shifting later lists. */
    if (_didWriteVRAM) {
        for (NV2AMetalCachedSurface *surface in downloads)
            _didWriteVRAM(surface.address, surface.reservationLength);
    }
    return YES;
}

/* A writeback callback can retire the rest of the original prefix or append
 * a later receipt. Keep the original tail by identity across those callbacks. */
- (BOOL)collectSurfaceSubmissionsThrough:(NV2AMetalSurfaceSubmission *)tail
                                  error:(NSError **)error
{
    while ([self prefixThroughSubmission:tail]) {
        NV2AMetalSurfaceSubmission *submitted = _submissions.firstObject;
        BOOL pending = NO;
        NSOrderedSet<NV2AMetalIndependentReads *> *dependencies =
            submitted.dependencies;
        NSUInteger confirmed = submitted.completedDependencyCount;
        for (NSUInteger i = confirmed; i < dependencies.count; i++) {
            NSError *failure = nil;
            BOOL ready = [dependencies[i] completedWithError:&failure];
            if (ready && failure)
                return [self independentReadFailure:failure error:error];
            pending |= !ready;
            if (!pending)
                confirmed = i + 1;
        }
        /* Successful feedback is final. Keep checking beyond a pending
         * dependency so later failures still surface immediately. */
        submitted.completedDependencyCount = confirmed;
        NSError *failure = nil;
        if (![submitted completedWithError:&failure])
            break;
        if (failure) {
            _failure = failure;
            atomic_store_explicit(&_cpuAccessGuard->failed, true,
                                  memory_order_release);
            if (error)
                *error = failure;
            return NO;
        }
        if (pending)
            break;
        if (![self retireSurfaceSubmission:submitted error:error] ||
            ![self healthy:error])
            return NO;
    }
    return YES;
}

/* Caller holds the metadata guard. Stop at the requested receipt prefix
 * without probing unrelated reader queues or later submissions. */
- (BOOL)collectSurfaceSubmissions:(NSUInteger)count error:(NSError **)error
{
    if (!count)
        return YES;
    if (count > _submissions.count)
        return cache_error(error, @"Invalid surface submission prefix");
    NV2AMetalSurfaceSubmission *tail = _submissions[count - 1];
    return [self collectSurfaceSubmissionsThrough:tail error:error];
}

- (BOOL)collectCompletedWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        while (_independentReads.count) {
            NV2AMetalIndependentReads *reader = _independentReads[0];
            NSError *failure = nil;
            if (![reader completedWithError:&failure])
                break;
            if (failure)
                return [self independentReadFailure:failure error:error];
            BOOL checked = NO;
            if (![self checkReadWitnessesForReader:reader
                                         completed:&checked
                                             error:error])
                return NO;
            if (!checked)
                break;
            [self retireIndependentReader:reader];
            [_independentReads removeObjectAtIndex:0];
        }
        return [self collectSurfaceSubmissions:_submissions.count error:error];
    }
}

/* Positions are contiguous; only the head can retire. Unsigned subtraction
 * gives the offset even if the queue position counter wrapped. */
- (NSUInteger)prefixThroughSubmission:(NV2AMetalSurfaceSubmission *)entry
{
    if (!entry)
        return 0;
    NSUInteger offset = entry.queuePosition - _submissions.firstObject.queuePosition;
    return offset < _submissions.count && _submissions[offset] == entry ?
               offset + 1 : 0;
}

- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    NSUInteger prefix = 0;
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (![_commands ownsSubmission:submission])
            return cache_error(error,
                               @"Submission belongs to another surface queue");
        if (_submissions.lastObject.submission == submission) {
            prefix = _submissions.count;
        } else {
            for (NSUInteger i = 0; i < _submissions.count; i++) {
                if (_submissions[i].submission == submission) {
                    prefix = i + 1;
                    break;
                }
            }
        }
    }
    return [self waitForSubmission:submission prefix:prefix error:error];
}

- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    prefix:(NSUInteger)prefix
                     error:(NSError **)error
{
    return [self waitForSubmission:submission prefix:prefix
                    producersOnly:NO error:error];
}

- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    prefix:(NSUInteger)prefix
             producersOnly:(BOOL)producersOnly
                     error:(NSError **)error
{
    NV2AMetalSurfaceSubmission *originalTail = nil;
    if (prefix) {
        @synchronized(_stateLock) {
            if (prefix > _submissions.count)
                return cache_error(error, @"Invalid surface submission prefix");
            originalTail = _submissions[prefix - 1];
        }
    }
    /* GPU execution is ordered, but feedback callbacks need not arrive in
     * that order. Validate the earlier prefix before publishing dependent
     * state. The PGRAPH owner alone changes this array. */
    for (NSUInteger i = 0; i < MAX(prefix, 1u); i++) {
        NV2AMetalSurfaceSubmission *writer = nil;
        NSUInteger confirmed = 0;
        if (prefix) {
            @synchronized(_stateLock) {
                writer = _submissions[i];
                confirmed = writer.completedDependencyCount;
            }
        }
        NSOrderedSet<NV2AMetalIndependentReads *> *dependencies = writer.dependencies;
        for (NSUInteger j = confirmed; j < dependencies.count; j++)
            if (![self waitForIndependentReader:dependencies[j] error:error])
                return NO;
        if (confirmed < dependencies.count) {
            @synchronized(_stateLock) {
                writer.completedDependencyCount = dependencies.count;
            }
        }
        /* Feedback can arrive while the CPU waits for a source reader. */
        NV2AMetalSubmission *prior = writer ? writer.submission : submission;
        NSError *failure = nil;
        BOOL producer = producersOnly && writer && i + 1 == prefix &&
                        prior.hasSeparateProducerFeedback;
        BOOL ready = producer ? [prior completedProducersWithError:&failure] :
                     writer ? [writer completedWithError:&failure] :
                              [prior completedWithError:&failure];
        BOOL succeeded = ready ? !failure : producer ?
            [_commands waitForProducersOfSubmission:prior error:&failure] :
            [_commands waitForSubmission:prior error:&failure];
        if (!succeeded) {
            if (!failure)
                cache_error(&failure, @"Surface submission completion failed");
            @synchronized(_stateLock) {
                atomic_store_explicit(&_cpuAccessGuard->failed, true,
                                      memory_order_release);
                _failure = failure;
                if (error)
                    *error = failure;
            }
            return NO;
        }
    }
    if (!prefix)
        return [self collectCompletedWithError:error];
    @synchronized (_stateLock) {
        if (producersOnly) {
            /* Only the final receipt can be partial. Its GPU read witnesses
             * are compute copies, but its raster work and downloads are not
             * yet publishable. Collection retires full receipts only. */
            while ([self prefixThroughSubmission:originalTail] > 1)
                if (![self retireSurfaceSubmission:_submissions.firstObject
                                              error:error] ||
                    ![self healthy:error])
                    return NO;
            if (![self prefixThroughSubmission:originalTail])
                return YES;
            for (NV2AMetalReadWitness *witness in originalTail.readWitnesses)
                if (![self validateReadWitness:witness error:error])
                    return NO;
            for (NV2AMetalSurfaceRecording *recording in originalTail.recordings)
                recording.producersCompleted = YES;
            return [self collectSurfaceSubmissionsThrough:originalTail
                                                   error:error];
        }
        /* The required receipts were validated above. Later feedback and
         * independent reader retirement belong to the next collection. */
        while ([self prefixThroughSubmission:originalTail])
            if (![self retireSurfaceSubmission:_submissions.firstObject
                                          error:error] ||
                ![self healthy:error])
                return NO;
        return YES;
    }
}

/* Range lookups already found the entry while holding the metadata lock. */
- (BOOL)waitForSurfaceSubmission:(NV2AMetalSurfaceSubmission *)entry
                         error:(NSError **)error
{
    return [self waitForSubmission:entry.submission
                             prefix:[self prefixThroughSubmission:entry]
                              error:error];
}

- (BOOL)finishSurfaceQueueWithError:(NSError **)error
{
    if (![self drainCompletedDownloadsWithError:error] ||
        ![self submitWithError:error] || ![self collectCompletedWithError:error])
        return NO;
    NV2AMetalSubmission *pending;
    @synchronized (_stateLock) {
        pending = _submissions.lastObject.submission;
    }
    if (pending && ![self waitForSubmission:pending error:error])
        return NO;
    /* Command helpers may submit directly on this queue. A completed,
     * successful receipt needs no wait; report an incomplete or failed one
     * through the usual cache error path. */
    NV2AMetalSubmission *last = _commands.lastSubmitted;
    if (!last || last == pending)
        return YES;
    NSError *failure = nil;
    return ([last completedWithError:&failure] && !failure) ||
           [self waitForSubmission:last error:error];
}

- (BOOL)waitForRecording:(NV2AMetalSurfaceRecording *)recording
                  error:(NSError **)error
{
    return [self waitForRecording:recording producersOnly:NO error:error];
}

- (BOOL)waitForProducersOfRecording:(NV2AMetalSurfaceRecording *)recording
                             error:(NSError **)error
{
    return [self waitForRecording:recording producersOnly:YES error:error];
}

/* A download prefix can publish only after every producer through its seal.
 * Later generic captures/overwrites of its bindings retain the full fallback,
 * including distinct Surface objects that alias the same guest bytes. The
 * current virtual section is inspected before any irreversible seal. */
- (BOOL)canOwnDownloadPrefix:(NV2AMetalSurfaceRecording *)recording
{
    BOOL current = _recording && recording == _token;
    NSUInteger section = current ?
                             _sealedTokens.count :
                             [_sealedTokens indexOfObjectIdenticalTo:recording];
    NSUInteger downloadEnd =
        current ? _pendingDownloads.count : recording.downloadEnd;
    if (section == NSNotFound || downloadEnd > _pendingDownloads.count ||
        _pendingDownloads.count > NSUIntegerMax / sizeof(uint64_t) ||
        _pendingDownloadGenerations.length !=
            _pendingDownloads.count * sizeof(uint64_t))
        return NO;
    for (NSUInteger i = 0; i <= section; i++) {
        BOOL virtual = i == _sealedTokens.count;
        NV2AMetalSurfaceRecording *token = virtual ? _token : _sealedTokens[i];
        if (token.producerBatchSerial != _commands.batchSerial ||
            !(virtual ? [self currentRecordingHasProducerOnlyHazards] :
                        token.producerOnlyHazards))
            return NO;
    }
    for (NSUInteger i = section + 1;
         i < _sealedTokens.count + (_recording != NO); i++) {
        NV2AMetalSurfaceRecording *later =
            i == _sealedTokens.count ? _token : _sealedTokens[i];
        if (later.hasNonProducerSurfaceCapture &&
            !later.nonProducerCaptures.length)
            return NO;
        const NV2AMetalVRAMRead *captures = later.nonProducerCaptures.bytes;
        NSUInteger count = later.nonProducerCaptures.length / sizeof(*captures);
        for (NSUInteger capture = 0; capture < count; capture++)
            for (NSUInteger j = _retiredDownloads; j < downloadEnd; j++) {
                NV2AMetalCachedSurface *download = _pendingDownloads[j];
                if (vram_bounds_overlap(
                        NSMakeRange(captures[capture].address,
                                    captures[capture].length),
                        NSMakeRange(download.address,
                                    download.reservationLength)))
                    return NO;
            }
    }
    for (NV2AMetalCachedSurface *surface in _overwriteTargets)
        for (NSUInteger j = _retiredDownloads; j < downloadEnd; j++) {
            NV2AMetalCachedSurface *download = _pendingDownloads[j];
            if (vram_bounds_overlap(
                    NSMakeRange(surface.address, surface.reservationLength),
                    NSMakeRange(download.address, download.reservationLength)))
                return NO;
        }
    return YES;
}

/* Seal and commit the immutable producer prefix. A strictly raster-free
 * download prefix owns its precise CPU metadata; other snapshot/control
 * receipts keep the existing deferred full-batch publication contract. */
- (NV2AMetalSurfaceSubmission *)submitProducerPrefix:
                                    (NV2AMetalSurfaceRecording *)recording
                                               error:(NSError **)error
{
    if (_recording && ![self checkpointWithError:error])
        return nil;
    if (recording.submitted)
        return recording.submissionEntry; /* Full/pressure boundary fallback. */
    if (recording.producerEntry)
        return recording.producerEntry;
    NSUInteger section = [_sealedTokens indexOfObjectIdenticalTo:recording];
    if (section == NSNotFound || recording.producerSection != section + 1 ||
        recording.dependencyEnd > _pendingDependencies.count ||
        recording.witnessEnd > _pendingReadWitnesses.count) {
        cache_error(error, @"Surface producer prefix is unavailable");
        return nil;
    }
    NV2AMetalSurfaceSubmission *entry = [NV2AMetalSurfaceSubmission new];
    NSArray *dependencies = [_pendingDependencies.array
        subarrayWithRange:NSMakeRange(0, recording.dependencyEnd)];
    entry.dependencies = [NSOrderedSet orderedSetWithArray:dependencies];
    NSMutableArray *witnesses = [NSMutableArray new],
                   *tokens = [NSMutableArray new];
    for (NSUInteger i = 0; i < recording.witnessEnd; i++) {
        NV2AMetalReadWitness *witness = _pendingReadWitnesses[i];
        if (!witness.producerCommitted)
            [witnesses addObject:witness];
    }
    for (NSUInteger i = 0; i <= section; i++) {
        NV2AMetalSurfaceRecording *token = _sealedTokens[i];
        if (!token.producerSubmission)
            [tokens addObject:token];
    }
    entry.readWitnesses = witnesses;
    entry.producerRecordings = tokens;
    entry.recordings = @[];
    entry.downloads = @[];
    entry.readSpans = entry.writeSpans = [NSData data];
    BOOL ownsDownloads = recording.downloadEnd > _prefixDownloads &&
                         [self canOwnDownloadPrefix:recording];
    if (ownsDownloads) {
        NSUInteger readStart = MAX(_retiredReadBytes, _prefixReadBytes);
        NSUInteger writeStart = MAX(_retiredWriteBytes, _prefixWriteBytes);
        if (recording.readEnd < readStart ||
            recording.readEnd > _pendingReads.length ||
            recording.writeEnd < writeStart ||
            recording.writeEnd > _pendingWrites.length ||
            _pendingDownloadGenerations.length !=
                _pendingDownloads.count * sizeof(uint64_t)) {
            cache_error(error, @"Invalid producer download ledger");
            return nil;
        }
        entry.cpuRecordings =
            [_sealedTokens subarrayWithRange:NSMakeRange(0, section + 1)];
        entry.producerBatchSerial = recording.producerBatchSerial;
        entry.readEnd = recording.readEnd;
        entry.writeEnd = recording.writeEnd;
        entry.downloadEnd = recording.downloadEnd;
        entry.readSpans = [_pendingReads
            subdataWithRange:NSMakeRange(readStart,
                                         recording.readEnd - readStart)];
        entry.writeSpans = [_pendingWrites
            subdataWithRange:NSMakeRange(writeStart,
                                         recording.writeEnd - writeStart)];
        entry.downloads = [_pendingDownloads
            subarrayWithRange:NSMakeRange(_prefixDownloads,
                                          recording.downloadEnd -
                                              _prefixDownloads)];
        NSRange bounds = NSMakeRange(0, 0);
        const NV2AMetalVRAMRead *writes = entry.writeSpans.bytes;
        for (NSUInteger i = 0; i < entry.writeSpans.length / sizeof(*writes);
             i++)
            bounds = extend_write_bounds(bounds, writes[i].address,
                                         writes[i].length);
        for (NV2AMetalCachedSurface *surface in entry.downloads)
            bounds = extend_write_bounds(bounds, surface.address,
                                         surface.reservationLength);
        entry.writeBounds = bounds;
    }
    NV2AMetalSubmission *receipt = [_commands
        submitProducersThroughSectionCount:recording.producerSection
                               batchSerial:recording.producerBatchSerial
                                     error:error];
    if (!receipt)
        return nil;
    entry.submission = receipt;
    if (ownsDownloads) {
        const uint64_t *versions = _pendingDownloadGenerations.bytes;
        for (NSUInteger i = _prefixDownloads; i < recording.downloadEnd; i++) {
            NV2AMetalCachedSurface *surface = _pendingDownloads[i];
            [self stamp:surface.address
                 length:surface.reservationLength
                version:versions[i]];
        }
        _prefixReadBytes = recording.readEnd;
        _prefixWriteBytes = recording.writeEnd;
        _prefixDownloads = recording.downloadEnd;
        _submittedDownloadCount += entry.downloads.count;
        if (entry.writeBounds.length)
            [_writerSubmissions addObject:entry];
    }
    if (_submissions.count)
        entry.queuePosition = _submissions.lastObject.queuePosition + 1;
    [_submissions addObject:entry];
    for (NV2AMetalSurfaceRecording *token in tokens) {
        token.producerSubmission = receipt;
        token.producerEntry = entry;
    }
    for (NV2AMetalReadWitness *witness in witnesses) {
        witness.producerCommitted = YES;
        witness.pendingStorage = YES;
        witness.reader.lastWitnessWriter = entry;
    }
    return entry;
}
- (BOOL)waitForRecording:(NV2AMetalSurfaceRecording *)recording
           producersOnly:(BOOL)producersOnly
                   error:(NSError **)error
{
    NV2AMetalSubmission *submission = nil;
    NSUInteger prefix;
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (!recording || recording.cancelled)
            return cache_error(error, @"Surface recording is unavailable");
        if (recording.completed)
            return YES;
        if (producersOnly && recording.producersCompleted) {
            /* Producer data stays ready, but a subsequently submitted full
             * receipt can have a now-known aggregate/raster failure. Inspect
             * only this token's own receipt without extending the wait scope.
             */
            NV2AMetalSubmission *full = recording.submissionEntry.submission;
            NSError *failure = nil;
            BOOL ready = full.hasSeparateProducerFeedback ?
                             [full completedProducersWithError:&failure] :
                             [full completedWithError:&failure];
            if (ready && failure)
                return [self independentReadFailure:failure error:error];
            return YES;
        }
        NV2AMetalSurfaceSubmission *entry = recording.submissionEntry;
        if (!recording.submitted) {
            if (_token != recording &&
                [_sealedTokens indexOfObjectIdenticalTo:recording] ==
                    NSNotFound)
                return cache_error(error, @"Surface recording is unavailable");
            if (producersOnly) {
                entry = [self submitProducerPrefix:recording error:error];
                if (!entry)
                    return NO;
            } else {
                if (![self submitWithError:error])
                    return NO;
                entry = recording.submissionEntry;
            }
        }
        prefix = [self prefixThroughSubmission:entry];
        submission = entry.submission;
    }
    if (!prefix || !submission)
        return cache_error(error, @"Surface recording has no submission");
    return producersOnly ?
               [self waitForSubmission:submission
                                prefix:prefix
                         producersOnly:YES
                                 error:error] :
               [self waitForSubmission:submission prefix:prefix error:error];
}

- (BOOL)collectCompletedThroughRecording:(NV2AMetalSurfaceRecording *)recording
                                   error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (recording.completed)
            return YES;
        NSUInteger prefix = [self prefixThroughSubmission:recording.submissionEntry];
        if (!recording.submitted || !prefix)
            return cache_error(error, @"No submitted surface recording to collect");
        return [self collectSurfaceSubmissions:prefix error:error];
    }
}

- (BOOL)waitUntilIdleAtAddress:(NSUInteger)address
                        length:(NSUInteger)length
                    allReaders:(BOOL)allReaders
                         error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error]) {
            return NO;
        }
        if (_recording || _sealedTokens.count) {
            return cache_error(error,
                               @"Submit or cancel surface work before waiting");
        }
    }
    /* Only the PGRAPH owner can change submissions. Concurrent CPU checks
     * still see all submitted read/download spans until completion below.
     * An enclosing cache transaction retains its recursive guard. */
    NSError *failure = nil;
    if ((allReaders || length) &&
        ![self waitForIndependentReadsAtAddress:address
                                         length:length
                                            all:allReaders
                                          error:error])
        return NO;
    BOOL idle = [_commands waitUntilIdleWithError:&failure];
    @synchronized (_stateLock) {
        if (!idle) {
            atomic_store_explicit(&_cpuAccessGuard->failed, true,
                                  memory_order_release);
            _failure =
                failure ? failure :
                          [NSError errorWithDomain:@"xemu.nv2a.metal4.surface-cache"
                                              code:2
                                          userInfo:@{
                                              NSLocalizedDescriptionKey :
                                                  @"Surface GPU completion failed"
                                          }];
            if (error) {
                *error = _failure;
            }
            return NO;
        }
        return [self collectCompletedWithError:error];
    }
}

- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    if (![self drainCompletedDownloadsWithError:error])
        return NO;
    return [self waitUntilIdleAtAddress:0 length:0 allReaders:YES error:error];
}

- (NV2AMetalSurfaceSubmission *)submittedDownloadForSurfaces:
    (NSArray<NV2AMetalCachedSurface *> *)selected
{
    if (!_submittedDownloadCount)
        return nil;
    for (NV2AMetalSurfaceSubmission *entry in
         [_writerSubmissions reverseObjectEnumerator]) {
        for (NV2AMetalCachedSurface *surface in entry.downloads)
            if ([selected containsObject:surface])
                return entry;
    }
    return nil;
}

- (BOOL)hasUnownedDownloadForSurface:(NV2AMetalCachedSurface *)surface
{
    for (NSUInteger i = _prefixDownloads; i < _pendingDownloads.count; i++)
        if (_pendingDownloads[i] == surface)
            return YES;
    return NO;
}

- (BOOL)downloadSurfacesForCPU:(NSArray<NV2AMetalCachedSurface *> *)surfaces
                         error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error])
            return NO;
        BOOL dirty = NO;
        for (NV2AMetalCachedSurface *surface in surfaces) {
            if (!surface.valid || ![_surfaces containsObject:surface])
                return cache_error(error, @"Cannot download an invalid surface");
            dirty |= surface.dirty;
        }
        if (dirty) {
            /* Preserve accepted GPU writes if a later download fails to encode. */
            if (![self checkpointWithError:error])
                return NO;
            /* Close a split raster pass before encoding either download. */
            for (NV2AMetalCachedSurface *surface in surfaces)
                if (surface.dirty && ![self prepareTextureRead:surface error:error])
                    return NO;
            if (![self download:surfaces error:error]) {
                [self cancel];
                return NO;
            }
        }
        for (NV2AMetalCachedSurface *surface in surfaces) {
            if ([self hasUnownedDownloadForSurface:surface]) {
                if (![self submitWithError:error]) {
                    if (dirty)
                        [self cancel];
                    return NO;
                }
                break;
            }
        }
        NV2AMetalSurfaceSubmission *entry =
            [self submittedDownloadForSurfaces:surfaces];
        return entry ? [self waitForSurfaceSubmission:entry error:error] :
                       [self collectCompletedWithError:error];
    }
}

- (BOOL)retire:(NSArray<NV2AMetalCachedSurface *> *)selected
    synchronize:(BOOL)synchronize
         error:(NSError **)error
{
    if (!selected.count) {
        return YES;
    }
    /* The CPU hook routes reads and writes through the submitted download
     * guard, while future texture uploads stay on this queue. */
    const BOOL waitForCPU = synchronize || !_willWatchVRAM;
    BOOL needsSubmit = synchronize;
    if (!needsSubmit) {
        /* Recorded reads keep their resources and VRAM guards. Only a
         * retirement that still needs to submit relevant work seals the
         * current batch. Already submitted downloads have their own receipt. */
        for (NV2AMetalCachedSurface *s in selected) {
            if (s.dirty || s.recording || [self hasUnownedDownloadForSurface:s]) {
                needsSubmit = YES;
                break;
            }
        }
    }
    NV2AMetalSubmission *submission = nil;
    NV2AMetalSurfaceSubmission *entry = nil;
    if (needsSubmit) {
        if (![self download:selected error:error] ||
            ![self submitWithError:error])
            return NO;
        submission = _commands.lastSubmitted;
    } else if (waitForCPU) {
        entry = [self submittedDownloadForSurfaces:selected];
    }
    BOOL ready = entry ? [self waitForSurfaceSubmission:entry error:error] :
                 submission && waitForCPU ?
                     [self waitForSubmission:submission error:error] :
                     [self collectCompletedWithError:error];
    if (!ready)
        return NO;
    for (NV2AMetalCachedSurface *s in selected) {
        s.valid = NO;
        [_surfaces removeObjectIdenticalTo:s];
        [self releaseSurfaceTarget:s];
    }
    return YES;
}

- (NV2AMetalCachedSurface *)
    prepareSurfaceAtAddress:(NSUInteger)address
                     config:(const NV2AMetalSurfaceConfig *)c
                      frame:(uint64_t)frame
                      error:(NSError **)error
{
    return [self prepareSurfaceAtAddress:address
                                  config:c
                                   frame:frame
                            forRendering:YES
                                   error:error];
}
- (NV2AMetalCachedSurface *)
    prepareSurfaceAtAddress:(NSUInteger)address
                     config:(const NV2AMetalSurfaceConfig *)c
                      frame:(uint64_t)frame
               forRendering:(BOOL)forRendering
                      error:(NSError **)error
{
    return [self prepareSurfaceAtAddress:address
                                  config:c
                                   frame:frame
                            forRendering:forRendering
                           selectingOnly:NO
                                   error:error];
}
- (NV2AMetalCachedSurface *)
    selectSurfaceAtAddress:(NSUInteger)address
                    config:(const NV2AMetalSurfaceConfig *)c
                     frame:(uint64_t)frame
                     error:(NSError **)error
{
    return [self prepareSurfaceAtAddress:address
                                  config:c
                                   frame:frame
                            forRendering:NO
                           selectingOnly:YES
                                   error:error];
}
- (NV2AMetalCachedSurface *)
    prepareSurfaceAtAddress:(NSUInteger)address
                     config:(const NV2AMetalSurfaceConfig *)c
                      frame:(uint64_t)frame
               forRendering:(BOOL)forRendering
              selectingOnly:(BOOL)selectOnly
                      error:(NSError **)error
{
    @synchronized(_stateLock) {
        NV2AMetalSurfaceLayout layout;
        if (![self healthy:error] ||
            !nv2a_metal_surface_layout(c, &layout, error) ||
            ![self validRange:address
                       length:layout.reservation_length
                        error:error]) {
            return nil;
        }
        /* Uploads only read VRAM and render targets use private textures.
         * Keep independent readers live until an actual VRAM writer needs
         * their bytes, rather than serializing two read-only consumers. */
        /* Never clear ownership bits on retirement/cancel/restore: false
         * positives are safe, while a forgotten download target is not. */
        [self watchCPUReadsAtAddress:address length:layout.reservation_length];
        NV2AMetalCachedSurface *surface = nil;
        for (NV2AMetalCachedSurface *s in _surfaces) {
            NV2AMetalSurfaceConfig old = s.transfer.config;
            /* Only zeta storage depends on the depth interpretation bit. */
            if (s.address == address && old.color == c->color &&
                old.format == c->format &&
                (c->color || old.floating_depth == c->floating_depth) &&
                old.pitch == c->pitch && old.scale == c->scale &&
                old.swizzle == c->swizzle &&
                s.transfer.nativePixelFormat == layout.pixel_format &&
                old.width >= c->width && old.height >= c->height) {
                surface = s;
                break;
            }
        }
        if (!surface) {
            if (_generation == UINT64_MAX) {
                cache_error(error, @"Surface content generation is exhausted");
                return nil;
            }
            NV2AMetalSurfaceTransfer *transfer =
                [[NV2AMetalSurfaceTransfer alloc]
                    initWithDevice:_commands.device
                            config:c
                       texturePool:_texturePool
                             error:error];
            if (!transfer ||
                ![self retire:[self overlaps:address
                                      length:layout.reservation_length]
                    synchronize:NO
                          error:error]) {
                return nil;
            }
            surface = [[NV2AMetalCachedSurface alloc]
                initWithTransfer:transfer
                         address:address
                          length:layout.reservation_length
                       stateLock:_stateLock];
            if (!surface) {
                cache_error(error, @"Cannot allocate native surface binding");
                return nil;
            }
            [self acquireSurfaceTarget:surface];
            surface.committedGeneration = ++_generation;
            [_surfaces addObject:surface];
        }
        if (!selectOnly && ![self prepareSelectedSurface:surface
                                            forRendering:forRendering
                                      discardingContents:NO
                                                   error:error])
            return nil;
        surface.frame = frame;
        return surface;
    }
}

- (BOOL)prepareSelectedSurface:(NV2AMetalCachedSurface *)surface
            discardingContents:(BOOL)discard
                         error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (!surface.valid || ![_surfaces containsObject:surface])
            return cache_error(error, @"Invalid selected surface");
        return [self prepareSelectedSurface:surface
                               forRendering:YES
                         discardingContents:discard
                                      error:error];
    }
}
- (BOOL)prepareSelectedSurface:(NV2AMetalCachedSurface *)surface
                  forRendering:(BOOL)forRendering
            discardingContents:(BOOL)discard
                         error:(NSError **)error
{
    BOOL upload = surface.needsUpload && !discard;
    if (upload && ![self prepareTextureRead:surface error:error])
        return NO;
    if (forRendering || upload) {
        if (![self begin:error])
            return NO;
        if (!(forRendering ? [self capture:surface error:error] :
                             [self captureState:surface error:error]))
            return NO;
    }
    if (upload) {
        NV2AMetalVRAMReadPattern read = { surface.address,
                                          surface.reservationLength, 0, 0 };
        [self registerSurfaceReadPatterns:&read count:1];
        if (![surface.transfer encodeUploadFromBuffer:_vram
                                               offset:surface.address
                                             commands:_commands
                                                error:error])
            return NO;
        surface.pendingUpload = NO;
    }
    return YES;
}

- (BOOL)markWritten:(NV2AMetalCachedSurface *)s error:(NSError **)error
{
    return [self markWritten:s replacingContents:NO error:error];
}
- (BOOL)markWritten:(NV2AMetalCachedSurface *)s
    replacingContents:(BOOL)replaced
                error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error]) {
            return NO;
        }
        if (!_recording || ![_surfaces containsObject:s] || !s.valid ||
            !s.recording || (s.needsUpload && !replaced)) {
            return cache_error(
                error,
                @"Draw requires a prepared live surface in this recording");
        }
        if (_generation == UINT64_MAX) {
            return cache_error(error,
                               @"Surface content generation is exhausted");
        }
        if (![self capture:s error:error])
            return NO;
        s.pendingUpload = NO;
        s.pendingDirty = YES;
        s.pendingGeneration = ++_generation;
        s.pendingWriterGeneration = s.pendingGeneration;
        s.pendingWriterSerial = _token.serial;
        return YES;
    }
}

- (NV2AMetalSurfaceSubmission *)submittedCPUConflictAtAddress:(NSUInteger)address
                                                length:(NSUInteger)length
                                                 write:(BOOL)write
{
    NSUInteger end = address + length;
    BOOL checkReads = write &&
        cpu_write_may_overlap_gpu_readers(_cpuAccessGuard, address, length);
    /* Read-only submissions cannot conflict with a CPU read or a CPU write
     * whose page guard has excluded every GPU reader. */
    NSArray<NV2AMetalSurfaceSubmission *> *candidates =
        checkReads ? _submissions : _writerSubmissions;
    NSUInteger candidate = candidates.count;
    while (candidate) {
        NV2AMetalSurfaceSubmission *entry = candidates[--candidate];
        NSRange bounds = entry.writeBounds;
        if (bounds.length && bounds.location < end && address < NSMaxRange(bounds)) {
            const NV2AMetalVRAMRead *writes = entry.writeSpans.bytes;
            NSUInteger writeCount = entry.writeSpans.length / sizeof(*writes);
            for (NSUInteger i = 0; i < writeCount; i++)
                if (writes[i].address < end &&
                    address < writes[i].address + writes[i].length)
                    return entry;
            for (NV2AMetalCachedSurface *s in entry.downloads) {
                if (s.address < end && address < s.address + s.reservationLength)
                    return entry;
            }
        }
        if (checkReads && read_spans_overlap(entry.readSpans, address, length))
            return entry;
    }
    return nil;
}

- (BOOL)pendingCPUConflictAtAddress:(NSUInteger)address
                             length:(NSUInteger)length
                              write:(BOOL)write
                           surfaces:(NSArray<NV2AMetalCachedSurface *> *)selected
{
    NV2AMetalVRAMReadPattern range = { address, length, 0, 0 };
    if ([self pendingWriteConflictForReadPatterns:&range count:1
                                            bounds:NSMakeRange(address, length)])
        return YES;
    if (write) {
        if (_pendingReads.length &&
            cpu_write_may_overlap_gpu_readers(_cpuAccessGuard, address,
                                              length) &&
            read_span_range_overlap(
                _pendingReads,
                NSMakeRange(_retiredReadBytes,
                            _pendingReads.length - _retiredReadBytes),
                address, length))
            return YES;
        /* Accept a captured binding before a CPU write changes its upload
         * state, so later section acceptance cannot restore stale metadata. */
        for (NV2AMetalCachedSurface *s in selected)
            if (s.recording)
                return YES;
    }
    return NO;
}

/* The command cursor and these byte cuts remain absolute after a partial
 * commit. A raster pass present at seal also excludes all later sections;
 * a raster tail appended after this immutable seal does not exclude it. */
- (NV2AMetalSurfaceRecording *)cpuProducerPrefixAtAddress:(NSUInteger)address
                                                   length:(NSUInteger)length
                                                    write:(BOOL)write
{
    NV2AMetalSurfaceRecording *last = nil;
    NSUInteger readStart = 0, writeStart = 0, downloadStart = 0;
    const NV2AMetalVRAMRead *writes = _pendingWrites.bytes;
    BOOL eligible = YES;
    for (NSUInteger i = 0; i < _sealedTokens.count + (_recording != NO); i++) {
        BOOL current = i == _sealedTokens.count;
        NV2AMetalSurfaceRecording *token = current ? _token : _sealedTokens[i];
        NSUInteger readEnd = current ? _pendingReads.length : token.readEnd;
        NSUInteger writeEnd = current ? _pendingWrites.length : token.writeEnd;
        NSUInteger downloadEnd =
            current ? _pendingDownloads.count : token.downloadEnd;
        if ((!current && token.producerSection != i + 1) ||
            token.producerBatchSerial != _commands.batchSerial ||
            readEnd < readStart || readEnd > _pendingReads.length ||
            writeEnd < writeStart || writeEnd > _pendingWrites.length ||
            downloadEnd < downloadStart ||
            downloadEnd > _pendingDownloads.count)
            return nil;
        eligible &= current ? [self currentRecordingHasProducerOnlyHazards] :
                              token.producerOnlyHazards;
        if (!token.cpuHazardsRetired) {
            BOOL conflict =
                write &&
                read_span_range_overlap(
                    _pendingReads, NSMakeRange(readStart, readEnd - readStart),
                    address, length);
            for (NSUInteger j = writeStart / sizeof(*writes);
                 !conflict && j < writeEnd / sizeof(*writes); j++)
                conflict = writes[j].address < address + length &&
                           address < writes[j].address + writes[j].length;
            for (NSUInteger j = MAX(downloadStart, _retiredDownloads);
                 !conflict && j < downloadEnd; j++) {
                NV2AMetalCachedSurface *surface = _pendingDownloads[j];
                conflict =
                    surface.address < address + length &&
                    address < surface.address + surface.reservationLength;
            }
            if (conflict) {
                if (!eligible)
                    return nil;
                last = token;
            }
        }
        readStart = readEnd;
        writeStart = writeEnd;
        downloadStart = downloadEnd;
    }
    if (last) {
        NSUInteger end =
            last == _token ? _pendingDownloads.count : last.downloadEnd;
        if (end > _retiredDownloads &&
            (![self canOwnDownloadPrefix:last] ||
             (end > _prefixDownloads && last.producerSubmission)))
            return nil; /* Never promote an earlier metadata-free control
                           receipt. */
    }
    return last;
}

/* Feedback validation alone never releases pending hazards (snapshot users
 * rely on that). Only a CPU conflict explicitly retires this proven scope. */
- (BOOL)retireCPUHazardsThroughRecording:(NV2AMetalSurfaceRecording *)last
                                   error:(NSError **)error
{
    if (![self waitForRecording:last producersOnly:YES error:error])
        return NO;
    for (NV2AMetalSurfaceRecording *token in _sealedTokens) {
        if (!token.cpuHazardsRetired) {
            [self retireSurfaceReader:token];
            [self retireSurfaceTargets:token];
            token.cpuHazardsRetired = YES;
        }
        if (token == last) {
            _retiredReadBytes = MAX(_retiredReadBytes, token.readEnd);
            _retiredWriteBytes = MAX(_retiredWriteBytes, token.writeEnd);
            if (token.downloadEnd <= _prefixDownloads)
                _retiredDownloads = MAX(_retiredDownloads, token.downloadEnd);
            return YES;
        }
    }
    return cache_error(error, @"CPU producer hazard prefix is unavailable");
}

/* This proof covers the entire writeback reservation, including padding and
 * pages outside the CPU request. No pending queue dependency is introduced:
 * an uncertain source or reader remains on the ordinary full-submit route. */
- (BOOL)canDownloadCompletedSurfaces:
    (NSArray<NV2AMetalCachedSurface *> *)surfaces
{
    BOOL dirty = NO;
    for (NV2AMetalCachedSurface *surface in surfaces) {
        if (!surface.valid || surface.recording ||
            ![_surfaces containsObject:surface])
            return NO;
        if (!surface.dirty)
            continue;
        dirty = YES;
        if (surface.needsUpload || !surface.committedWriterSerial ||
            surface.committedWriterSerial > _completedRecordingSerial ||
            surface.committedCaptureSerial > _completedRecordingSerial ||
            surface.committedWriterGeneration != surface.committedGeneration)
            return NO;
        NSRange range = NSMakeRange(surface.address, surface.reservationLength);
        for (NV2AMetalCachedSurface *other in _surfaces)
            if (other != surface && other.valid &&
                vram_bounds_overlap(
                    range, NSMakeRange(other.address, other.reservationLength)))
                return NO;
        for (NV2AMetalCachedSurface *other in _overwriteTargets)
            if (vram_bounds_overlap(
                    range, NSMakeRange(other.address, other.reservationLength)))
                return NO;
        NV2AMetalVRAMReadPattern pattern = { range.location, range.length, 0,
                                             0 };
        if ([self pendingWriteConflictForReadPatterns:&pattern
                                                count:1
                                               bounds:range] ||
            read_span_range_overlap(
                _pendingReads,
                NSMakeRange(_retiredReadBytes,
                            _pendingReads.length - _retiredReadBytes),
                range.location, range.length) ||
            [self submittedCPUConflictAtAddress:range.location
                                         length:range.length
                                          write:YES])
            return NO;
        for (NV2AMetalIndependentReads *reader in _independentReads)
            if (independent_reader_overlaps(reader, range.location,
                                            range.length))
                return NO;
        for (NSUInteger i = 0; i < _sealedTokens.count + (_recording != NO);
             i++) {
            NV2AMetalSurfaceRecording *token =
                i == _sealedTokens.count ? _token : _sealedTokens[i];
            if (token.hasNonProducerSurfaceCapture &&
                !token.nonProducerCaptures.length)
                return NO;
            const NV2AMetalVRAMRead *captures = token.nonProducerCaptures.bytes;
            for (NSUInteger j = 0;
                 j < token.nonProducerCaptures.length / sizeof(*captures); j++)
                if (vram_bounds_overlap(range, NSMakeRange(captures[j].address,
                                                           captures[j].length)))
                    return NO;
        }
    }
    return dirty;
}

- (NV2AMetalCommands *)completedDownloadCommandsWithError:(NSError **)error
{
    if (!_completedDownloadCommands)
        _completedDownloadCommands =
            [[NV2AMetalCommands alloc] initWithDevice:_commands.device
                                                error:error];
    return _completedDownloadCommands;
}

- (void)releaseCompletedDownloadTargets
{
    _Atomic(uint64_t) *targets = target_page_references(_cpuAccessGuard);
    [_completedDownloadTargets
        enumerateRangesUsingBlock:^(NSRange pages, BOOL *stop) {
          (void)stop;
          retire_page_references(targets, pages);
        }];
    _completedDownloadTargets = nil;
    _completedDownloadSubmission = nil;
}

- (BOOL)drainCompletedDownloadsWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (!_completedDownloadTargets && !_completedDownloadSubmission)
            return YES;
        [_completedDownloadCommands cancel];
        NSError *failure = nil;
        BOOL idle =
            [_completedDownloadCommands waitUntilIdleWithError:&failure];
        if (idle || [_completedDownloadSubmission completedWithError:NULL])
            [self releaseCompletedDownloadTargets];
        if (!idle && _failure) {
            if (error)
                *error = _failure;
            return NO;
        }
        return idle || [self independentReadFailure:failure error:error];
    }
}

/* The caller holds stateLock across this synchronous transaction. Resource
 * and target leases remain independent of the still-open main batch. */
- (BOOL)downloadCompletedSurfaces:(NSArray<NV2AMetalCachedSurface *> *)surfaces
                        completed:(BOOL *)completed
                            error:(NSError **)error
{
    *completed = NO;
    if (![self canDownloadCompletedSurfaces:surfaces])
        return YES;
    /* The source writer's ordered full feedback was already validated.
     * Disjoint, later receipts must not expand this helper's error scope. */
    NSError *optionalError = nil;
    NV2AMetalCommands *commands =
        [self completedDownloadCommandsWithError:&optionalError];
    if (!commands)
        return YES; /* Optional queue allocation preserves the old route. */
    if (commands == _commands || commands.device != _commands.device ||
        commands.commandBuffer || commands.batchSerial)
        return cache_error(error, @"Invalid completed surface download queue");
    NSMutableIndexSet *pages = [NSMutableIndexSet new];
    NSMutableArray<NV2AMetalCachedSurface *> *downloads =
        [NSMutableArray arrayWithCapacity:surfaces.count];
    if (!pages || !downloads)
        return YES;
    for (NV2AMetalCachedSurface *surface in surfaces)
        if (surface.dirty) {
            [downloads addObject:surface];
            NSUInteger first = surface.address / 4096;
            NSUInteger last =
                (surface.address + surface.reservationLength - 1) / 4096;
            [pages addIndexesInRange:NSMakeRange(first, last - first + 1)];
        }
    if (![commands beginWithError:error])
        return NO;
    _completedDownloadTargets = pages;
    [pages enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
      (void)stop;
      NSUInteger start = range.location * 4096;
      [self addTargetReferencesAtAddress:start
                                  length:MIN(range.length * 4096,
                                             _vram.length - start)];
    }];
    for (NV2AMetalCachedSurface *surface in downloads)
        if (![surface.transfer textureForCommands:commands error:error] ||
            ![surface.transfer encodeDownloadToBuffer:_vram
                                               offset:surface.address
                                              swizzle:YES
                                                 flip:NO
                                            downscale:YES
                                             commands:commands
                                                error:error]) {
            [commands cancel];
            [self releaseCompletedDownloadTargets];
            return NO;
        }
    NSError *failure = nil;
    NV2AMetalSubmission *previous = commands.lastSubmitted;
    if (![commands submitWithError:&failure]) {
        [commands cancel];
        if (commands.lastSubmitted != previous) {
            _completedDownloadSubmission = commands.lastSubmitted;
            return [self independentReadFailure:failure error:error];
        }
        /* A rejected, unsubmitted section remains retryable. The open main
         * transaction is unaffected; a native commit above retains its lease.
         */
        [self releaseCompletedDownloadTargets];
        if (error)
            *error = failure;
        return NO;
    }
    _completedDownloadSubmission = commands.lastSubmitted;
    if (![commands waitForSubmission:_completedDownloadSubmission
                               error:&failure])
        return [self independentReadFailure:failure error:error];
    for (NV2AMetalCachedSurface *surface in downloads) {
        surface.committedDirty = NO;
        [self stamp:surface.address
             length:surface.reservationLength
            version:surface.committedWriterGeneration];
    }
    [self releaseCompletedDownloadTargets];
    *completed = YES;
    /* Publish the complete selection and release helper ownership before a
     * notification can reenter. The private list survives cache invalidation.
     */
    if (_didWriteVRAM)
        for (NV2AMetalCachedSurface *surface in downloads)
            _didWriteVRAM(surface.address, surface.reservationLength);
    return YES;
}

- (BOOL)synchronizeCPUAccessAtAddress:(NSUInteger)address
                               length:(NSUInteger)length
                                write:(BOOL)write
                           commitOpen:(BOOL)commitOpen
                                error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error] || ![self validRange:address
                                                length:length
                                                 error:error]) {
            return NO;
        }
        if (!length) {
            return YES;
        }
        NSArray<NV2AMetalCachedSurface *> *selected = [self overlaps:address
                                                              length:length];
        if (write && _generation == UINT64_MAX) {
            return cache_error(error,
                               @"Surface content generation is exhausted");
        }
        BOOL downloaded = NO;
        if (!commitOpen && _commands.hasPendingRasterPass &&
            ![self pendingCPUConflictAtAddress:address
                                        length:length
                                         write:write
                                      surfaces:selected] &&
            ![self submittedCPUConflictAtAddress:address
                                          length:length
                                           write:write]) {
            BOOL readers = NO;
            for (NV2AMetalIndependentReads *reader in _independentReads)
                readers |= independent_reader_overlaps(reader, address, length);
            if (!readers && ![self downloadCompletedSurfaces:selected
                                                   completed:&downloaded
                                                       error:error])
                return NO;
        }
        if (!downloaded && ![self download:selected error:error])
            return NO;
        BOOL submitOpen =
            (_recording || _sealedTokens.count) &&
            (commitOpen || [self pendingCPUConflictAtAddress:address
                                                      length:length
                                                       write:write
                                                    surfaces:selected]);
        BOOL prefixResolved = NO;
        if (submitOpen && !commitOpen) {
            BOOL captured = NO;
            if (write && ![self currentRecordingHasProducerOnlyHazards])
                for (NV2AMetalCachedSurface *surface in selected)
                    captured |= surface.recording;
            NV2AMetalSurfaceRecording *prefix =
                captured ? nil :
                           [self cpuProducerPrefixAtAddress:address
                                                     length:length
                                                      write:write];
            if (prefix) {
                /* Do not accept an open fallback transaction before its full
                 * submit succeeds. Preview the unsealed section above; only
                 * a proven prefix may seal it. Pressure retains the original
                 * full-submit/cancel contract and can consume the candidate. */
                if (![self checkpointWithError:error])
                    return NO;
                prefix = [self cpuProducerPrefixAtAddress:address
                                                   length:length
                                                    write:write];
            }
            if (prefix) {
                /* Commit before waiting for CPU-write readers: their witness
                 * scope may require this producer. Preserve the full route's
                 * reader-error priority before inspecting Surface feedback. */
                if (!prefix.producersCompleted &&
                    ![self submitProducerPrefix:prefix error:error])
                    return NO;
                if (write && ![self waitForIndependentReadsAtAddress:address
                                                              length:length
                                                                 all:NO
                                                               error:error])
                    return NO;
                if (![self retireCPUHazardsThroughRecording:prefix error:error])
                    return NO;
                prefixResolved = YES;
            }
        }
        if (submitOpen && !prefixResolved && ![self submitWithError:error])
            return NO;
        if (submitOpen && commitOpen) {
            if (![self waitUntilIdleAtAddress:address
                                       length:write ? length : 0
                                   allReaders:NO
                                        error:error])
                return NO;
        } else {
            if (write && !prefixResolved &&
                ![self waitForIndependentReadsAtAddress:address
                                                 length:length
                                                    all:NO
                                                  error:error])
                return NO;
            /* A conflicting open section is part of the just-submitted
             * batch. Wait for that receipt, without draining reusable slots. */
            if (submitOpen && !prefixResolved) {
                NV2AMetalSubmission *submission = _commands.lastSubmitted;
                if (submission && ![self waitForSubmission:submission
                                                     error:error])
                    return NO;
            } else if (!prefixResolved) {
                /* A queued CPU request only needs the submission that owns
                 * its bytes. Waiting on that prefix publishes its feedback
                 * without first polling unrelated readers or later writers. */
                if (commitOpen && ![self collectCompletedWithError:error])
                    return NO;
                NV2AMetalSurfaceSubmission *conflict =
                    [self submittedCPUConflictAtAddress:address
                                                 length:length
                                                  write:write];
                if (conflict && ![self waitForSurfaceSubmission:conflict
                                                          error:error])
                    return NO;
            }
        }
        if (write) {
            uint64_t version = ++_generation;
            [self stamp:address length:length version:version];
            for (NV2AMetalCachedSurface *s in selected) {
                s.committedUpload = YES;
                s.committedGeneration = version;
            }
        }
        return YES;
    }
}

- (BOOL)prepareCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                            error:(NSError **)error
{
    return [self synchronizeCPUAccessAtAddress:address
                                        length:length
                                         write:write
                                    commitOpen:YES
                                         error:error];
}

- (BOOL)resolveCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                            error:(NSError **)error
{
    return [self synchronizeCPUAccessAtAddress:address
                                        length:length
                                         write:write
                                    commitOpen:NO
                                         error:error];
}

/* Caller holds the metadata guard and has validated the address range. */
- (BOOL)tryIdleCPUAccessInRange:(NSRange)range
                          write:(BOOL)write
                      completed:(BOOL *)completed
                          error:(NSError **)error
{
    NSUInteger address = range.location, length = range.length;
    *completed = NO;
    if (!length) {
        *completed = YES;
        return YES;
    }
    NV2AMetalVRAMReadPattern pattern = { address, length, 0, 0 };
    if ([self pendingWriteConflictForReadPatterns:&pattern count:1 bounds:range])
        return YES;
    if ((_writerSubmissions.count || (write && _submissions.count)) &&
        [self submittedCPUConflictAtAddress:address length:length write:write])
        return YES;
    if (write && (_independentReads.count || _pendingReads.length) &&
        cpu_write_may_overlap_gpu_readers(_cpuAccessGuard, address, length)) {
        for (NV2AMetalIndependentReads *reader in _independentReads)
            if (independent_reader_overlaps(reader, address, length))
                return YES;
        if (read_span_range_overlap(
                _pendingReads,
                NSMakeRange(_retiredReadBytes,
                            _pendingReads.length - _retiredReadBytes),
                address, length))
            return YES;
    }
    /* Most TCG accesses have no surface overlap. Avoid allocating a
     * temporary selection array for every intercepted RAM load or store. */
    BOOL overlapping = NO;
    for (NV2AMetalCachedSurface *surface in _surfaces) {
        if (surface.address < address + length &&
            address < surface.address + surface.reservationLength) {
            if (surface.dirty || (write && surface.recording))
                return YES;
            overlapping = YES;
        }
    }
    if (write) {
        if (_generation == UINT64_MAX)
            return cache_error(error,
                               @"Surface content generation is exhausted");
        uint64_t version = ++_generation;
        [self stamp:address length:length version:version];
        if (overlapping)
            for (NV2AMetalCachedSurface *surface in _surfaces) {
                if (surface.address < address + length &&
                    address < surface.address + surface.reservationLength) {
                    surface.committedUpload = YES;
                    surface.committedGeneration = version;
                }
            }
    }
    *completed = YES;
    return YES;
}

- (BOOL)tryIdleCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                        completed:(BOOL *)completed
                            error:(NSError **)error
{
    @synchronized (_stateLock) {
        *completed = NO;
        if (![self healthy:error] ||
            ![self validRange:address length:length error:error])
            return NO;
        return [self tryIdleCPUAccessInRange:NSMakeRange(address, length)
                                      write:write
                                  completed:completed
                                      error:error];
    }
}

- (BOOL)tryIdleCPUReadSpans:(const NV2AMetalVRAMReadSpan *)spans
                     count:(NSUInteger)count
                 completed:(BOOL *)completed
                     error:(NSError **)error
{
    return [self tryIdleCPUReadSpans:spans count:count collectCompleted:NO
                           completed:completed error:error];
}

- (BOOL)tryIdleCPUReadSpans:(const NV2AMetalVRAMReadSpan *)spans
                     count:(NSUInteger)count
          collectCompleted:(BOOL)collect
                 completed:(BOOL *)completed
                     error:(NSError **)error
{
    @synchronized (_stateLock) {
        *completed = NO;
        if (![self healthy:error])
            return NO;
        /* A full DMA Current input fits on the stack. Larger callers use
         * the same bounded workspace and preserve input order at errors. */
        NV2AMetalVRAMReadPattern patterns[16];
        /* Read watches only change under this lock. Adjacent attributes
         * often share one bitmap word even when their byte ranges differ. */
        NSUInteger cachedWord = NSUIntegerMax;
        uint64_t watched = 0;
        NSUInteger vramLength = _cpuAccessGuard->length;
        NSUInteger i = 0;
        while (i < count) {
            NSUInteger used = 0, first = NSUIntegerMax, end = 0;
            NSError *invalid = nil;
            BOOL valid = YES;
            for (; i < count && used < sizeof(patterns) / sizeof(patterns[0]); i++) {
                NV2AMetalVRAMReadSpan span = spans[i];
                if (span.address > vramLength ||
                    span.length > vramLength - span.address) {
                    valid = [self validRange:span.address length:span.length
                                       error:&invalid];
                    break;
                }
                if (!span.length)
                    continue;
                NSUInteger firstPage = span.address / 4096;
                NSUInteger lastPage = (span.address + span.length - 1) / 4096;
                NSUInteger word = firstPage / 64;
                if (word == lastPage / 64) {
                    if (word != cachedWord) {
                        watched = atomic_load_explicit(
                            &_cpuAccessGuard->watched[word], memory_order_acquire);
                        cachedWord = word;
                    }
                    uint64_t mask = (UINT64_MAX << (firstPage % 64)) &
                                    (UINT64_MAX >> (63 - lastPage % 64));
                    if (!(watched & mask))
                        continue;
                } else if (nv2a_metal_untracked_cpu_access(
                               _cpuAccessGuard, span.address, span.length, NO)) {
                    continue;
                }
                patterns[used++] = (NV2AMetalVRAMReadPattern){
                    span.address, span.length, 0, 0
                };
                first = MIN(first, span.address);
                end = MAX(end, span.address + span.length);
            }
            /* A conflict before an invalid range still requests the normal
             * fallback, just as it would in a one-span-at-a-time probe. */
            NSRange bounds = used ? NSMakeRange(first, end - first) :
                                    NSMakeRange(0, 0);
            if (used) {
                NV2AMetalVRAMWriterConflict conflict =
                    [self writerConflictForReadPatterns:patterns count:used
                                                  bounds:bounds];
                if (collect && conflict == NV2AMetalVRAMWriterSubmitted) {
                    collect = NO;
                    if (![self collectCompletedWithError:error])
                        return NO;
                    conflict = [self writerConflictForReadPatterns:patterns
                                                             count:used
                                                            bounds:bounds];
                }
                if (conflict ||
                    [self findDirtySurfacesForReadPatterns:patterns count:used
                                                    bounds:bounds selected:NULL])
                    return YES;
            }
            if (!valid) {
                if (error)
                    *error = invalid;
                return NO;
            }
        }
        *completed = YES;
        return YES;
    }
}

- (BOOL)validReadPattern:(NV2AMetalVRAMReadPattern)p error:(NSError **)error
{
    if (![self validRange:p.address length:p.length error:error])
        return NO;
    if ((!p.stride && p.element) ||
        (p.stride &&
         (!p.element || p.element > p.stride || p.element > p.length ||
          (p.length - p.element) % p.stride)))
        return cache_error(error, @"Invalid strided VRAM read pattern");
    return YES;
}

- (BOOL)validateReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                       count:(NSUInteger)count
                      bounds:(NSRange *)bounds
                    nonempty:(NSUInteger *)nonempty
                       error:(NSError **)error
{
    if ((!patterns && count) || count > NSUIntegerMax / sizeof(*patterns))
        return cache_error(error, @"Invalid VRAM read patterns");
    NSUInteger first = NSUIntegerMax, end = 0, records = 0;
    for (NSUInteger i = 0; i < count; i++) {
        NV2AMetalVRAMReadPattern p = patterns[i];
        if (![self validReadPattern:p error:error])
            return NO;
        if (p.length) {
            first = MIN(first, p.address);
            end = MAX(end, p.address + p.length);
            records++;
        }
    }
    *bounds = end ? NSMakeRange(first, end - first) : NSMakeRange(0, 0);
    if (nonempty)
        *nonempty = records;
    return YES;
}

static NSData *snapshot_read_patterns(const NV2AMetalVRAMReadPattern *patterns,
                                     NSUInteger count, NSUInteger nonempty)
{
    NSUInteger size = nonempty * sizeof(*patterns);
    if (!nonempty)
        return [NSData data];
    if (count == nonempty)
        return [NSData dataWithBytes:patterns length:size];

    /* The cache owns this data exclusively. Fill it once without retaining
     * the caller's storage or growing and copying a temporary buffer. */
    NSMutableData *snapshot = [NSMutableData dataWithLength:size];
    NV2AMetalVRAMReadPattern *records = snapshot.mutableBytes;
    for (NSUInteger i = 0; i < count; i++)
        if (patterns[i].length)
            *records++ = patterns[i];
    return snapshot;
}

- (BOOL)prepareGPUReadAtAddress:(NSUInteger)address
                         length:(NSUInteger)length
                          error:(NSError **)error
{
    return [self prepareGPUReadPattern:(NV2AMetalVRAMReadPattern){
                                           address, length, 0, 0 }
                                 error:error];
}

- (BOOL)prepareGPUReadPattern:(NV2AMetalVRAMReadPattern)p
                        error:(NSError **)error
{
    return [self prepareGPUReadPatterns:&p count:1 error:error];
}

/* A probe can stop at the first match. A fallback collects the matches in
 * cache order for the writeback pass while the metadata guard is held. */
- (BOOL)findDirtySurfacesForReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                                   count:(NSUInteger)count
                                  bounds:(NSRange)bounds
                                selected:(NSMutableArray<NV2AMetalCachedSurface *> **)selected
{
    if (!bounds.length || ![self surfaceTargetsMayOverlapAddress:bounds.location
                                                          length:bounds.length])
        return NO;
    for (NV2AMetalCachedSurface *surface in _surfaces) {
        if (!surface.dirty ||
            !read_batch_overlaps(patterns, count, bounds, surface.address,
                                 surface.reservationLength))
            continue;
        if (!selected)
            return YES;
        if (!*selected)
            *selected = [NSMutableArray new];
        [*selected addObject:surface];
    }
    return selected && (*selected).count;
}

- (BOOL)prepareValidatedGPUReadPatterns:
            (const NV2AMetalVRAMReadPattern *)patterns
                                   count:(NSUInteger)count
                                  bounds:(NSRange)bounds
                               downloads:(NSArray<NV2AMetalCachedSurface *> *)selected
                                   error:(NSError **)error
{
    /* Validation leaves bounds empty only when every pattern has zero length.
     * Such bindings open a command section without reading guest VRAM. */
    BOOL empty = !bounds.length;
    if (![self download:selected error:error] || ![self begin:error] ||
        (!empty && ![_commands addResource:_vram error:error]))
        return NO;
    if (!empty)
        [self registerSurfaceReadPatterns:patterns count:count];
    return YES;
}

/* A cache hit records no VRAM source. It only needs a command section in
 * which the already uploaded native texture can be retained for this draw. */
- (BOOL)canQueueCachedTextureBinding
{
    return _commands.hasPendingRasterPass && !_rasterProducers &&
           _commands.recordingAllowsProducerWork &&
           !(_recording && _token.hasNonProducerSurfaceCapture) &&
           !_overwriteTargets.count &&
           _pendingWrites.length == _sealedWriteBytes &&
           _pendingDownloads.count == _sealedDownloads &&
           !(_sealedTokens.count && _commands.batchNeedsSubmit);
}

- (BOOL)prepareCachedTextureBindingWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if ([self canQueueCachedTextureBinding]) {
            if (![self validateRasterContinuationWithError:error])
                return NO;
            if (!_recording && ![self collectCompletedWithError:error])
                return NO;
            /* Completion callbacks may change the batch or cache state. */
            if (![self healthy:error])
                return NO;
            if ([self canQueueCachedTextureBinding]) {
                if (![self validateRasterContinuationWithError:error])
                    return NO;
                if (!_recording && ![self beginNativeRecordingWithError:error])
                    return NO;
                /* The caller retains the private texture; no VRAM resource
                 * participates in this producer section. */
                return YES;
            }
        }
        return [self prepareGPUReadAtAddress:0 length:0 error:error];
    }
}

- (BOOL)prepareGPUReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                         count:(NSUInteger)count
                         error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        NSRange bounds;
        if (![self validateReadPatterns:patterns count:count bounds:&bounds
                                nonempty:NULL
                                  error:error])
            return NO;
        NSMutableArray<NV2AMetalCachedSurface *> *selected = nil;
        [self findDirtySurfacesForReadPatterns:patterns count:count
                                       bounds:bounds selected:&selected];
        return [self prepareValidatedGPUReadPatterns:patterns count:count
                                             bounds:bounds downloads:selected
                                              error:error];
    }
}

/* Caller holds the metadata lock and has validated every read pattern. Only
 * a pure producer section can be extended without accepting older work. */
- (BOOL)canQueueTextureUploadReadPatterns:
            (const NV2AMetalVRAMReadPattern *)patterns
                                    count:(NSUInteger)count
                                   bounds:(NSRange)bounds
{
    if (!bounds.length || !_commands.hasPendingRasterPass || _rasterProducers ||
        !_commands.recordingAllowsProducerWork ||
        (_recording && _token.hasNonProducerSurfaceCapture) ||
        _overwriteTargets.count || _pendingWrites.length != _sealedWriteBytes ||
        _pendingDownloads.count != _sealedDownloads)
        return NO;
    return [self writerConflictForReadPatterns:patterns
                                         count:count
                                        bounds:bounds] ==
               NV2AMetalVRAMWriterNone &&
           ![self findDirtySurfacesForReadPatterns:patterns
                                             count:count
                                            bounds:bounds
                                          selected:NULL];
}

/* The old clean-source admission is unchanged. This separate proof permits
 * only an already completed writeback before rechecking that same admission. */
- (BOOL)
    canDownloadCompletedTextureUploadReadPatterns:
        (const NV2AMetalVRAMReadPattern *)patterns
                                            count:(NSUInteger)count
                                           bounds:(NSRange)bounds
                                         surfaces:
                                             (NSArray<NV2AMetalCachedSurface *>
                                                  *)surfaces
{
    if (!surfaces.count || !bounds.length || !_commands.hasPendingRasterPass ||
        _rasterProducers || !_commands.recordingAllowsProducerWork ||
        (_recording && _token.hasNonProducerSurfaceCapture) ||
        _overwriteTargets.count || _pendingWrites.length != _sealedWriteBytes ||
        _pendingDownloads.count != _sealedDownloads)
        return NO;
    if ([self writerConflictForReadPatterns:patterns
                                      count:count
                                     bounds:bounds] != NV2AMetalVRAMWriterNone)
        return NO;
    /* Optional selection allocation must never hide one dirty reservation. */
    for (NV2AMetalCachedSurface *surface in _surfaces)
        if (surface.dirty &&
            read_batch_overlaps(patterns, count, bounds, surface.address,
                                surface.reservationLength) &&
            [surfaces indexOfObjectIdenticalTo:surface] == NSNotFound)
            return NO;
    return [self canDownloadCompletedSurfaces:surfaces];
}

- (BOOL)prepareTextureUploadReadPatterns:
            (const NV2AMetalVRAMReadPattern *)patterns
                                   count:(NSUInteger)count
                                   error:(NSError **)error
{
    @synchronized(_stateLock) {
        /* Ordinary reads and an existing producer scope retain their exact
         * old validation, ordering, and error path without a second probe. */
        if (!_commands.hasPendingRasterPass || _rasterProducers ||
            !_commands.recordingAllowsProducerWork)
            return [self prepareGPUReadPatterns:patterns
                                          count:count
                                          error:error];
        NSRange bounds;
        if (![self healthy:error] || ![self validateReadPatterns:patterns
                                                           count:count
                                                          bounds:&bounds
                                                        nonempty:NULL
                                                           error:error])
            return NO;
        if (![self canQueueTextureUploadReadPatterns:patterns
                                               count:count
                                              bounds:bounds]) {
            NSMutableArray<NV2AMetalCachedSurface *> *selected = nil;
            [self findDirtySurfacesForReadPatterns:patterns
                                             count:count
                                            bounds:bounds
                                          selected:&selected];
            if (![self canDownloadCompletedTextureUploadReadPatterns:patterns
                                                               count:count
                                                              bounds:bounds
                                                            surfaces:selected])
                return [self prepareGPUReadPatterns:patterns count:count error:error];
            if (![self validateRasterContinuationWithError:error])
                return NO;
            BOOL completed = NO;
            if (![self downloadCompletedSurfaces:selected
                                       completed:&completed
                                           error:error])
                return NO;
            if (!completed)
                return [self prepareGPUReadPatterns:patterns count:count error:error];
            /* Writeback callbacks may change every part of the caller's
             * eligibility. Revalidate once; never retry the optional helper. */
            if (![self healthy:error] || ![self validateReadPatterns:patterns
                                                               count:count
                                                              bounds:&bounds
                                                            nonempty:NULL
                                                               error:error])
                return NO;
            if (![self canQueueTextureUploadReadPatterns:patterns
                                                   count:count
                                                  bounds:bounds])
                return [self prepareGPUReadPatterns:patterns count:count error:error];
        }
        /* The old full submit checks these exact batch dependencies before
         * encoding the upload. Preserve their priority without submission. */
        if (![self validateRasterContinuationWithError:error])
            return NO;
        BOOL previous = _rasterProducers;
        @try {
            _rasterProducers = YES;
            return [self prepareValidatedGPUReadPatterns:patterns
                                                   count:count
                                                  bounds:bounds
                                               downloads:nil
                                                   error:error];
        } @finally {
            _rasterProducers = previous;
        }
    }
}

- (BOOL)tryBeginIndependentReads:(const NV2AMetalVRAMReadSpan *)spans
                           count:(NSUInteger)count
                        commands:(NV2AMetalCommands *)commands
                           reads:(NV2AMetalIndependentReads **)reads
                           error:(NSError **)error
{
    if ((!spans && count) ||
        count > NSUIntegerMax / sizeof(NV2AMetalVRAMReadPattern)) {
        *reads = nil;
        return cache_error(error, @"Invalid independent VRAM read spans");
    }
    NSMutableData *patterns = [NSMutableData new];
    for (NSUInteger i = 0; i < count; i++) {
        NV2AMetalVRAMReadPattern p = { spans[i].address, spans[i].length, 0,
                                       0 };
        [patterns appendBytes:&p length:sizeof(p)];
    }
    return [self tryBeginIndependentReadPatterns:patterns.bytes
                                           count:count
                                        commands:commands
                                           reads:reads
                                           error:error];
}

- (BOOL)pendingWriteConflictForReadPatterns:
            (const NV2AMetalVRAMReadPattern *)spans
                                      count:(NSUInteger)count
                                     bounds:(NSRange)bounds
{
    if (!vram_bounds_overlap(bounds, _pendingWriteBounds))
        return NO;
    const NV2AMetalVRAMRead *pending = _pendingWrites.bytes;
    NSUInteger pendingCount = _pendingWrites.length / sizeof(*pending);
    for (NSUInteger i = _retiredWriteBytes / sizeof(*pending); i < pendingCount;
         i++)
        if (read_batch_overlaps(spans, count, bounds, pending[i].address,
                                pending[i].length))
            return YES;
    for (NSUInteger i = _retiredDownloads; i < _pendingDownloads.count; i++) {
        NV2AMetalCachedSurface *surface = _pendingDownloads[i];
        if (read_batch_overlaps(spans, count, bounds, surface.address,
                                surface.reservationLength))
            return YES;
    }
    return NO;
}

- (NV2AMetalVRAMWriterConflict)writerConflictForReadPatterns:
                                   (const NV2AMetalVRAMReadPattern *)spans
                                                       count:(NSUInteger)count
                                                      bounds:(NSRange)bounds
{
    if (!bounds.length)
        return NV2AMetalVRAMWriterNone;
    if ([self pendingWriteConflictForReadPatterns:spans
                                            count:count
                                           bounds:bounds])
        return NV2AMetalVRAMWriterPending;

    /* Skip disjoint submissions before walking their exact writer ranges.
     * The aggregate bounds alone cannot detect a strided or inter-range gap. */
    for (NV2AMetalSurfaceSubmission *entry in _writerSubmissions) {
        NSRange writes = entry.writeBounds;
        if (vram_bounds_overlap(bounds, writes)) {
            const NV2AMetalVRAMRead *submitted = entry.writeSpans.bytes;
            NSUInteger writeCount = entry.writeSpans.length / sizeof(*submitted);
            for (NSUInteger i = 0; i < writeCount; i++)
                if (read_batch_overlaps(spans, count, bounds,
                                        submitted[i].address, submitted[i].length))
                    return NV2AMetalVRAMWriterSubmitted;
            for (NV2AMetalCachedSurface *surface in entry.downloads) {
                if (read_batch_overlaps(spans, count, bounds, surface.address,
                                        surface.reservationLength))
                    return NV2AMetalVRAMWriterSubmitted;
            }
        }
    }
    return NV2AMetalVRAMWriterNone;
}

- (BOOL)tryIdleGPUReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                         count:(NSUInteger)count
                     completed:(BOOL *)completed
                         error:(NSError **)error
{
    @synchronized (_stateLock) {
        *completed = NO;
        NSRange bounds;
        if (![self healthy:error] ||
            ![self validateReadPatterns:patterns count:count bounds:&bounds
                                nonempty:NULL error:error])
            return NO;
        *completed = ![self writerConflictForReadPatterns:patterns count:count
                                                  bounds:bounds] &&
                     ![self findDirtySurfacesForReadPatterns:patterns count:count
                                                     bounds:bounds selected:NULL];
        return YES;
    }
}

- (BOOL)beginIndependentReadPatterns:(const NV2AMetalVRAMReadPattern *)spans
                               count:(NSUInteger)count
                            commands:(NV2AMetalCommands *)commands
                               reads:(NV2AMetalIndependentReads **)reads
                allowSurfaceFallback:(BOOL)allowSurfaceFallback
                               error:(NSError **)error
{
    @synchronized(_stateLock) {
        *reads = nil;
        if (![self collectCompletedWithError:error])
            return NO;
        if (!commands || commands == _commands ||
            commands.device != _commands.device || commands.commandBuffer)
            return cache_error(error,
                               @"Invalid independent VRAM read queue/spans");
        NSRange bounds;
        NSUInteger nonempty;
        if (![self validateReadPatterns:spans count:count bounds:&bounds
                                nonempty:&nonempty
                                  error:error])
            return NO;
        NV2AMetalVRAMWriterConflict writer =
            [self writerConflictForReadPatterns:spans count:count bounds:bounds];
        if (writer && !allowSurfaceFallback)
            return YES;
        NSMutableArray<NV2AMetalCachedSurface *> *selected = nil;
        BOOL dirty = [self findDirtySurfacesForReadPatterns:spans count:count
                                                      bounds:bounds
                                                    selected:allowSurfaceFallback ?
                                                                 &selected : NULL];
        if (writer || dirty)
            return !allowSurfaceFallback ||
                   [self prepareValidatedGPUReadPatterns:spans count:count
                                                  bounds:bounds
                                               downloads:selected error:error];
        if (![commands beginWithError:error])
            return NO;
        if (nonempty && ![commands addResource:_vram error:error]) {
            [commands cancel];
            return NO;
        }
        NV2AMetalIndependentReads *reader =
            [[NV2AMetalIndependentReads alloc] initRecording];
        reader.commands = commands;
        reader.owner = self;
        reader.spanBounds = bounds;
        reader.spans = snapshot_read_patterns(spans, count, nonempty);
        const NV2AMetalVRAMReadPattern *registered = reader.spans.bytes;
        if (nonempty == 1) {
            [self watchCPUWritesAtAddress:registered[0].address
                                   length:registered[0].length];
            [self addGPUReaderAtAddress:registered[0].address
                                 length:registered[0].length];
        } else if (nonempty) {
            /* CPU interception works at page granularity. Keep exact GPU
             * spans for conflict checks but own each page only once per reader. */
            NSMutableIndexSet *pages =
                reader_pattern_pages(registered, nonempty, nil, nil);
            reader.readerPages = pages;
            [self registerReaderPages:pages];
        }
        /* Keep global order for VRAM hazards and queue order for feedback. */
        NV2AMetalIndependentReads *previous = [_lastReaderOnQueue objectForKey:commands];
        reader.previousOnQueue = previous;
        previous.nextOnQueue = reader;
        [_lastReaderOnQueue setObject:reader forKey:commands];
        [_independentReads addObject:reader];
        *reads = reader;
        return YES;
    }
}

- (BOOL)tryBeginIndependentReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                                  count:(NSUInteger)count
                               commands:(NV2AMetalCommands *)commands
                                  reads:(NV2AMetalIndependentReads **)reads
                                  error:(NSError **)error
{
    return [self beginIndependentReadPatterns:patterns count:count
                                       commands:commands reads:reads
                           allowSurfaceFallback:NO error:error];
}

- (BOOL)prepareGPUReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                         count:(NSUInteger)count
            independentCommands:(NV2AMetalCommands *)commands
                         reads:(NV2AMetalIndependentReads **)reads
                         error:(NSError **)error
{
    return [self beginIndependentReadPatterns:patterns count:count
                                       commands:commands reads:reads
                           allowSurfaceFallback:YES error:error];
}

- (BOOL)submitIndependentReads:(NV2AMetalIndependentReads *)reads
                         error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (![_independentReads containsObject:reads] || reads.submission ||
            !reads.commands.commandBuffer)
            return cache_error(error, @"No unsubmitted independent VRAM reads");
        if (reads.spans.length && !reads.completionMarker) {
            id<MTLBuffer> marker = [_commands.device
                newBufferWithLength:sizeof(uint64_t)
                            options:MTLResourceStorageModeShared];
            if (!marker)
                return cache_error(
                    error, @"Could not allocate VRAM read completion marker");
            memset(marker.contents, 0, marker.length);
            uint64_t completed = 1;
            NSUInteger offset;
            id<MTLBuffer> constant =
                [reads.commands uploadBytes:&completed
                                     length:sizeof(completed)
                                     offset:&offset
                                      error:error];
            if (!constant || ![reads.commands addResource:constant error:error] ||
                ![reads.commands addResource:marker error:error])
                return NO;
            id<MTL4ComputeCommandEncoder> encoder =
                begin_read_marker_copies(reads.commands, error);
            if (!encoder)
                return NO;
            [encoder copyFromBuffer:constant
                       sourceOffset:offset
                           toBuffer:marker
                  destinationOffset:0
                               size:sizeof(completed)];
            end_read_marker_copies(encoder);
            reads.completionMarker = marker;
        }
        if (![reads.commands submitWithError:error])
            return NO;
        reads.submission = reads.commands.lastSubmitted;
        return YES;
    }
}

- (BOOL)completeIndependentReads:(NV2AMetalIndependentReads *)reads
                           error:(NSError **)error
{
    NSMutableArray<NV2AMetalIndependentReads *> *prefix = [NSMutableArray new];
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (reads.owner != self || !reads.submission)
            return cache_error(
                error, @"No submitted independent VRAM reads to complete");
        if (reads.retired)
            return YES;
        for (NV2AMetalIndependentReads *prior = reads; prior;
             prior = prior.previousOnQueue)
            [prefix addObject:prior];
    }
    /* Feedback may arrive out of order. Include earlier scopes on this queue,
     * including submitted cancellations, but never wait for a later scope or
     * alter a later recording. Already retired scopes passed this check. */
    for (NV2AMetalIndependentReads *prior in prefix.reverseObjectEnumerator)
        if (![self waitForIndependentReader:prior error:error])
            return NO;
    NSMutableArray<NV2AMetalSubmission *> *pendingWriters = nil;
    NV2AMetalSubmission *pendingProducers = nil;
    NV2AMetalSurfaceSubmission *producerTail = nil;
    NSError *writerFailure = nil;
    NSUInteger writerCount = 0;
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        for (NV2AMetalIndependentReads *prior in prefix) {
            NV2AMetalSurfaceSubmission *writer = prior.lastWitnessWriter;
            if (!writer)
                continue;
            NSUInteger writerPrefix = [self prefixThroughSubmission:writer];
            if (!writerPrefix) {
                NSError *failure = nil;
                cache_error(&failure, @"Missing VRAM reader's submitted writer");
                return [self independentReadFailure:failure error:error];
            }
            writerCount = MAX(writerCount, writerPrefix);
        }
        for (NSUInteger i = 0; i < writerCount; i++) {
            NV2AMetalSurfaceSubmission *writer = _submissions[i];
            BOOL producer = i + 1 == writerCount &&
                            writer.submission.hasSeparateProducerFeedback;
            if (i + 1 == writerCount)
                producerTail = writer;
            NSError *failure = nil;
            BOOL ready = producer ? [writer.submission completedProducersWithError:&failure] :
                                    [writer completedWithError:&failure];
            if (ready) {
                if (failure) {
                    /* Earlier pending feedback still has error priority. */
                    writerFailure = failure;
                    break;
                }
                continue;
            }
            if (producer) {
                pendingProducers = writer.submission;
                continue;
            }
            if (!pendingWriters)
                pendingWriters = [NSMutableArray new];
            [pendingWriters addObject:writer.submission];
        }
    }
    /* An event timeout can damage reader bytes even if source feedback
     * succeeds. Wait only the native writer prefix needed to inspect these
     * witnesses; do not wait other producers' later feedback or recordings. */
    for (NV2AMetalSubmission *writer in pendingWriters) {
        NSError *failure = nil;
        if (![_commands waitForSubmission:writer error:&failure])
            return [self independentReadFailure:failure error:error];
    }
    if (pendingProducers) {
        NSError *failure = nil;
        if (![_commands waitForProducersOfSubmission:pendingProducers error:&failure])
            return [self independentReadFailure:failure error:error];
    }
    if (writerFailure)
        return [self independentReadFailure:writerFailure error:error];
    @synchronized(_stateLock) {
        if (![self validateReadWitnessesForPrefix:prefix producerTail:producerTail error:error] ||
            (producerTail && ![self collectSurfaceSubmissionsThrough:producerTail
                                                               error:error]))
            return NO;
        /* Release only this queue's validated reader prefix. A foreign or
         * later receipt belongs to its own completion or normal collection. */
        if (prefix.count == 1) {
            [self retireIndependentReader:reads];
            [_independentReads removeObjectIdenticalTo:reads];
        } else {
            NSHashTable *selected = [NSHashTable
                hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
            for (NV2AMetalIndependentReads *reader in prefix)
                [selected addObject:reader];
            NSMutableIndexSet *indices = [NSMutableIndexSet new];
            for (NSUInteger i = 0; i < _independentReads.count; i++) {
                NV2AMetalIndependentReads *reader = _independentReads[i];
                if ([selected containsObject:reader]) {
                    [self retireIndependentReader:reader];
                    [indices addIndex:i];
                }
            }
            [_independentReads removeObjectsAtIndexes:indices];
        }
        return YES;
    }
}

- (void)cancelIndependentReads:(NV2AMetalIndependentReads *)reads
{
    @synchronized(_stateLock) {
        if (![_independentReads containsObject:reads] || reads.submission)
            return;
        [reads.commands cancel];
        [self retireIndependentReader:reads];
        [_independentReads removeObjectIdenticalTo:reads];
    }
}

- (BOOL)prepareGPUWriteAtAddress:(NSUInteger)address
                          length:(NSUInteger)length
                           error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error] || ![self validRange:address
                                                length:length
                                                 error:error])
            return NO;
        if ([self overlaps:address length:length].count)
            return cache_error(error,
                               @"Invalidate surfaces before a GPU RAM write");
        return [self registerGPUWriteAtAddress:address
                                        length:length
                                         error:error];
    }
}
- (BOOL)prepareGPUBlitFrom:(NSRange)source
                        to:(NSRange)destination
          replacingSurface:
              (NS_NOESCAPE BOOL (^)(NV2AMetalCachedSurface *))replaces
                     error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error] ||
            ![self validRange:source.location length:source.length error:error] ||
            ![self validRange:destination.location length:destination.length
                        error:error])
            return NO;
        if (_overwriteTargets.count)
            return cache_error(error,
                               @"A surface overwrite is already recording");
        if (destination.length && _generation == UINT64_MAX)
            return cache_error(error, @"Surface content generation is exhausted");
        if (!_recording && _sealedTokens.count && _independentReads.count &&
            destination.length) {
            NSArray<NV2AMetalIndependentReads *> *readers =
                [self independentReadDependenciesMatching:
                  ^BOOL(NV2AMetalIndependentReads *reader) {
                  return independent_reader_overlaps(reader, destination.location,
                                                     destination.length);
                } error:error];
            if (!readers || ![self submitAcceptedPrefixBeforeReaders:readers
                                                             error:error])
                return NO;
        }
        NSArray<NV2AMetalCachedSurface *> *targets =
            [self overlaps:destination.location length:destination.length];
        NSMutableArray<NV2AMetalCachedSurface *> *downloads =
            [[self overlaps:source.location length:source.length] mutableCopy];
        for (NV2AMetalCachedSurface *s in targets)
            if (s.dirty && ![downloads containsObject:s] && !replaces(s))
                [downloads addObject:s];
        /* A download preceding the blit is still reversible until submit.
         * Retain every target in the cache until the overwrite is accepted. */
        if (![self download:downloads error:error] ||
            ![self prepareGPUReadAtAddress:source.location length:source.length
                                    error:error] ||
            ![self registerGPUWriteAtAddress:destination.location
                                      length:destination.length error:error])
            return NO;
        _overwriteTargets = targets;
        return YES;
    }
}
- (BOOL)registerGPUWriteAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            error:(NSError **)error
{
    if (![self orderAfterIndependentReadsAtAddress:address
                                            length:length
                                             error:error])
        return NO;
    [self watchCPUReadsAtAddress:address length:length];
    if (![self begin:error] || ![_commands addResource:_vram error:error] ||
        ![self registerTargetAtAddress:address length:length error:error])
        return NO;
    if (length) {
        NV2AMetalVRAMRead span = { address, length };
        [_pendingWrites appendBytes:&span length:sizeof(span)];
        _pendingWriteBounds = extend_write_bounds(_pendingWriteBounds,
                                                  address, length);
        if (_gpuWriteEpoch != UINT64_MAX)
            _gpuWriteEpoch++;
    }
    return YES;
}

- (BOOL)observeCPUWriteAtAddress:(NSUInteger)address
                          length:(NSUInteger)length
                           error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error] || ![self validRange:address
                                                length:length
                                                 error:error]) {
            return NO;
        }
        for (NSUInteger i = 0; i <= _writerSubmissions.count; i++) {
            NSData *writes =
                i ? _writerSubmissions[i - 1].writeSpans : _pendingWrites;
            const NV2AMetalVRAMRead *spans = writes.bytes;
            for (NSUInteger j = i ? 0 : _retiredWriteBytes / sizeof(*spans);
                 j < writes.length / sizeof(*spans); j++)
                if (length && spans[j].address < address + length &&
                    address < spans[j].address + spans[j].length)
                    return cache_error(error, @"CPU dirty notification "
                                              @"conflicts with GPU-owned VRAM");
        }
        for (NV2AMetalCachedSurface *s in [self overlaps:address
                                                  length:length]) {
            if (s.dirty) {
                return cache_error(
                    error,
                    @"CPU dirty notification conflicts with GPU-owned VRAM");
            }
        }
        /* Dirty source pages do not depend on unrelated surface work. Reuse
         * the exact-span ownership check and its persistent invalidation;
         * overlapping readers/downloads/recorded surfaces still drain below. */
        BOOL completed = NO;
        if (![self tryIdleCPUAccessAtAddress:address
                                      length:length
                                       write:YES
                                   completed:&completed
                                       error:error])
            return NO;
        if (completed)
            return YES;
        return [self resolveCPUAccessAtAddress:address
                                        length:length
                                         write:YES
                                         error:error];
    }
}

- (BOOL)invalidateAddress:(NSUInteger)address
                   length:(NSUInteger)length
                    error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error] || ![self validRange:address
                                                length:length
                                                 error:error]) {
            return NO;
        }
        if (length && _generation == UINT64_MAX) {
            return cache_error(error, @"Surface content generation is exhausted");
        }
        if (![self waitForIndependentReadsAtAddress:address
                                             length:length
                                                all:NO
                                              error:error])
            return NO;
        if (![self retire:[self overlaps:address length:length]
               synchronize:YES error:error]) {
            return NO;
        }
        if (length) {
            [self stamp:address length:length version:++_generation];
        }
        return YES;
    }
}

- (BOOL)noticeTextureDirtyAtAddress:(NSUInteger)address
                             length:(NSUInteger)length
                              error:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error] || ![self validRange:address
                                                length:length
                                                 error:error]) {
            return NO;
        }
        if (length) {
            if (_generation == UINT64_MAX) {
                return cache_error(error,
                                   @"Texture source generation is exhausted");
            }
            uint64_t version = ++_generation;
            [self stamp:address length:length version:version];
            for (NV2AMetalCachedSurface *s in [self overlaps:address
                                                      length:length]) {
                if (s.dirty) {
                    continue;
                }
                /* An observed RAM change cannot be rolled back with GPU work.
                 * Preserve invalidation of a clean committed texture on cancel. */
                if (!s.committedDirty) {
                    s.committedUpload = YES;
                    s.committedGeneration = version;
                }
                if (s.recording) {
                    s.pendingUpload = YES;
                    s.pendingGeneration = version;
                }
            }
        }
        return YES;
    }
}

- (BOOL)touchSurface:(NV2AMetalCachedSurface *)surface
               frame:(uint64_t)frame
               error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error])
            return NO;
        if (!surface.valid || ![_surfaces containsObject:surface])
            return cache_error(error, @"Cannot touch an invalid cached surface");
        surface.frame = frame;
        return YES;
    }
}

- (BOOL)evictBeforeFrame:(uint64_t)frame error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error]) {
            return NO;
        }
        NSMutableArray *selected = [NSMutableArray new];
        for (NV2AMetalCachedSurface *s in _surfaces) {
            if (frame >= s.frame && frame - s.frame >= 5) {
                [selected addObject:s];
            }
        }
        return [self retire:selected synchronize:NO error:error];
    }
}

- (BOOL)flushWithError:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self drainCompletedDownloadsWithError:error] ||
            ![self healthy:error] ||
            ![self retire:[_surfaces copy] synchronize:YES error:error] ||
            ![self submitWithError:error] || ![self waitUntilIdleWithError:error]) {
            return NO;
        }
        return YES;
    }
}

- (BOOL)discardForRestoreWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self drainCompletedDownloadsWithError:error] ||
            ![self healthy:error]) {
            return NO;
        }
        if (_generation == UINT64_MAX) {
            return cache_error(error,
                               @"Cannot invalidate restore source versions");
        }
        NV2AMetalSurfaceSubmission *producer = nil;
        for (NV2AMetalSurfaceSubmission *entry in _submissions)
            if (entry.producerRecordings.count)
                producer = entry;
        /* Producer work already executed even though its Surface batch is
         * still unsubmitted. Drain its chronological prefix before dropping
         * readerPages: CPU source writes have a lock-free fast path. */
        if (producer && ![self waitForSurfaceSubmission:producer error:error])
            return NO;
        [self cancel];
        [_commands cancel];
        _rasterTargets = nil;
        for (NV2AMetalSurfaceRecording *token in _sealedTokens) {
            token.cancelled = YES;
            [self retireSurfaceReader:token];
            [self retireSurfaceTargets:token];
        }
        [_sealedTokens removeAllObjects];
        _pendingReads.length = _pendingWrites.length = 0;
        _retiredReadBytes = _retiredWriteBytes = 0;
        _retiredDownloads = 0;
        _prefixReadBytes = _prefixWriteBytes = _prefixDownloads = 0;
        _pendingWriteBounds = _sealedWriteBounds = NSMakeRange(0, 0);
        [_pendingDownloads removeAllObjects];
        _pendingDownloadGenerations.length = 0;
        [_pendingDependencies removeAllObjects];
        [self discardPendingWitnessesAfter:0];
        _sealedReadBytes = _sealedWriteBytes = _sealedDownloads = 0;
        _sealedDependencies = _sealedReadWitnesses = 0;
        /* Submitted downloads may still target shared VRAM. They must finish
         * before the loader replaces those bytes; never encode another
         * download. */
        if (![self waitUntilIdleWithError:error]) {
            return NO;
        }
        for (NV2AMetalCachedSurface *s in _surfaces) {
            s.valid = NO;
            [self releaseSurfaceTarget:s];
        }
        [_surfaces removeAllObjects];
        _completedRecordingSerial = 0;
        [self stamp:0 length:_vram.length version:++_generation];
        return YES;
    }
}
@end
