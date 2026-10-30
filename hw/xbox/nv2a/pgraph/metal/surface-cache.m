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
    for (NSUInteger word = first / 64; word <= last / 64; word++) {
        unsigned low = word == first / 64 ? first % 64 : 0;
        unsigned high = word == last / 64 ? last % 64 : 63;
        uint64_t mask = (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
        if (atomic_load_explicit(
                &guard->watched[word + (write ? guard->words : 0)],
                memory_order_acquire) &
            mask)
            return NO;
    }
    return YES;
}

static BOOL cpu_source_write_safe(const NV2AMetalCPUAccessGuard *guard,
                                  NSUInteger address, NSUInteger length)
{
    if (atomic_load_explicit(&guard->failed, memory_order_acquire))
        return NO;
    NSUInteger first = address / 4096, last = (address + length - 1) / 4096;
    for (NSUInteger word = first / 64; word <= last / 64; word++) {
        unsigned low = word == first / 64 ? first % 64 : 0;
        unsigned high = word == last / 64 ? last % 64 : 63;
        uint64_t mask = (UINT64_MAX << low) & (UINT64_MAX >> (63 - high));
        if (atomic_load_explicit(&guard->watched[word], memory_order_acquire) &
            mask)
            return NO;
    }
    const _Atomic(uint64_t) *readers = guard->watched + 3 * guard->words;
    for (NSUInteger page = first; page <= last; page++)
        if (atomic_load_explicit(&readers[page], memory_order_acquire))
            return NO;
    return YES;
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
@property(nonatomic, readwrite) BOOL valid;
@property(nonatomic) BOOL committedDirty, committedUpload, recording;
@property(nonatomic) BOOL pendingDirty, pendingUpload, pendingBorder,
    committedBorder;
- (instancetype)initWithTransfer:(NV2AMetalSurfaceTransfer *)transfer
                         address:(NSUInteger)address
                          length:(NSUInteger)length
                       stateLock:(NSObject *)stateLock;
@end

@interface NV2AMetalSurfaceRecording ()
@property(nonatomic, readwrite) BOOL submitted, completed, cancelled;
- (instancetype)initRecording;
@end
@implementation NV2AMetalSurfaceRecording
- (instancetype)initRecording
{
    return [super init];
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
@property(nonatomic, nullable) NV2AMetalSubmission *submission;
@property(nonatomic) id<MTLBuffer> completionMarker;
- (instancetype)initRecording;
@end
@implementation NV2AMetalIndependentReads
- (instancetype)initRecording
{
    return [super init];
}
@end

/* Source markers change once, from zero to one, after every preceding GPU
 * read. Consumers snapshot that value before a conflicting VRAM write. A
 * timed-out queue event must never turn a premature write into valid CPU
 * state merely because both feedback callbacks eventually report success. */
static BOOL copy_read_marker(NV2AMetalCommands *commands, id<MTLBuffer> source,
                             NSUInteger offset, id<MTLBuffer> destination,
                             NSError **error)
{
    if (![commands addResource:source error:error] ||
        ![commands addResource:destination error:error])
        return NO;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder)
        return cache_error(error,
                           @"Could not encode VRAM read completion marker");
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:source
               sourceOffset:offset
                   toBuffer:destination
          destinationOffset:0
                       size:sizeof(uint64_t)];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return YES;
}

@interface NV2AMetalReadWitness : NSObject
@property(nonatomic) NV2AMetalIndependentReads *reader;
@property(nonatomic) id<MTLBuffer> observed;
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

static BOOL read_spans_overlap(NSData *data, NSUInteger address,
                               NSUInteger length)
{
    const NV2AMetalVRAMReadPattern *spans = data.bytes;
    for (NSUInteger i = 0; i < data.length / sizeof(*spans); i++)
        if (read_pattern_overlap(spans[i], address, length))
            return YES;
    return NO;
}

static BOOL writes_overlap_pattern(NSData *data, NV2AMetalVRAMReadPattern p)
{
    const NV2AMetalVRAMRead *spans = data.bytes;
    for (NSUInteger i = 0; i < data.length / sizeof(*spans); i++)
        if (read_pattern_overlap(p, spans[i].address, spans[i].length))
            return YES;
    return NO;
}

/* Metadata stays ordered exactly like submissions. Counts select the prefix
 * of the aggregate hazard arrays; later and pending spans remain protected. */
@interface NV2AMetalSurfaceSubmission : NSObject
@property(nonatomic, strong) NV2AMetalSubmission *submission;
@property(nonatomic) NSArray<NV2AMetalIndependentReads *> *dependencies;
@property(nonatomic) NSArray<NV2AMetalReadWitness *> *readWitnesses;
@property(nonatomic) NSUInteger readBytes, writeBytes, downloads, tokens;
@end
@implementation NV2AMetalSurfaceSubmission
@end

@implementation NV2AMetalSurfaceCache {
    NSObject *_stateLock;
    NV2AMetalCPUAccessGuard *_cpuAccessGuard;
    NSMutableArray<NV2AMetalCachedSurface *> *_surfaces, *_recordingEntries;
    NSMutableArray<NV2AMetalCachedSurface *> *_pendingDownloads,
        *_submittedDownloads;
    NV2AMetalVRAMWriteHandler _didWriteVRAM;
    NSError *_failure;
    BOOL _recording;
    BOOL _rasterProducers;
    NSArray<NV2AMetalCachedSurface *> *_rasterTargets;
    uint64_t _generation;
    NSMutableData *_vramVersions, *_pendingReads, *_submittedReads;
    NSMutableData *_pendingWrites, *_submittedWrites;
    NV2AMetalSurfaceRecording *_token;
    NSMutableArray<NV2AMetalSurfaceRecording *> *_submittedTokens;
    NSMutableArray<NV2AMetalSurfaceRecording *> *_sealedTokens;
    NSUInteger _sealedReadBytes, _sealedWriteBytes, _sealedDownloads,
        _sealedDependencies, _sealedReadWitnesses;
    NSMutableArray<NV2AMetalSurfaceSubmission *> *_submissions;
    NSMutableArray<NV2AMetalIndependentReads *> *_independentReads;
    NSMutableArray<NV2AMetalIndependentReads *> *_pendingDependencies;
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
    NSUInteger pages = (vram.length - 1) / 4096 + 1;
    NSUInteger words = (pages + 63) / 64;
    _cpuAccessGuard = calloc(1, sizeof(*_cpuAccessGuard) +
                                    (3 * words + pages) *
                                        sizeof(_cpuAccessGuard->watched[0]));
    if (!_cpuAccessGuard) {
        cache_error(error, @"Cannot allocate CPU ownership map");
        return nil;
    }
    _cpuAccessGuard->length = vram.length;
    _cpuAccessGuard->words = words;
    atomic_init(&_cpuAccessGuard->failed, false);
    for (NSUInteger i = 0; i < 3 * words + pages; i++)
        atomic_init(&_cpuAccessGuard->watched[i], 0);
    _didWriteVRAM = [handler copy];
    _surfaces = [NSMutableArray new];
    _recordingEntries = [NSMutableArray new];
    _pendingDownloads = [NSMutableArray new];
    _submittedDownloads = [NSMutableArray new];
    _submittedTokens = [NSMutableArray new];
    _sealedTokens = [NSMutableArray new];
    _submissions = [NSMutableArray new];
    _independentReads = [NSMutableArray new];
    _pendingDependencies = [NSMutableArray new];
    _pendingReadWitnesses = [NSMutableArray new];
    _pendingWrites = [NSMutableData new];
    _submittedWrites = [NSMutableData new];
    _pendingReads = [NSMutableData new];
    _submittedReads = [NSMutableData new];
    _vramVersions = [NSMutableData
        dataWithLength:((vram.length - 1) / 4096 + 1) * sizeof(uint64_t)];
    return self;
}

- (void)dealloc
{
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
        atomic_fetch_or_explicit(&_cpuAccessGuard->watched[word], mask,
                                 memory_order_release);
        uint64_t old = atomic_fetch_or_explicit(
            &_cpuAccessGuard->watched[word + _cpuAccessGuard->words], mask,
            memory_order_release);
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
        uint64_t old = atomic_fetch_or_explicit(
            &_cpuAccessGuard->watched[word + _cpuAccessGuard->words], mask,
            memory_order_release);
        added |= (old & mask) != mask;
    }
    if (added && _willWatchVRAM)
        _willWatchVRAM(first * 4096,
                       MIN((last + 1) * 4096, _vram.length) - first * 4096);
}

/* Each span owns one reference per touched page. Submit only moves spans;
 * cancel drops recorded references, and successful idle drops submitted ones.
 * Separate references avoid temporarily unprotecting a shared page while a
 * different recording is cancelled. The span arrays bound the reference count.
 */
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

- (void)retireGPUReaders:(NSData *)data
{
    [self retireGPUReaders:data length:data.length];
}

- (void)retireGPUReaders:(NSData *)data length:(NSUInteger)length
{
    assert(length <= data.length);
    _Atomic(uint64_t) *readers =
        _cpuAccessGuard->watched + 3 * _cpuAccessGuard->words;
    const NV2AMetalVRAMReadPattern *spans = data.bytes;
    for (NSUInteger i = 0; i < length / sizeof(*spans); i++) {
        NSUInteger last = (spans[i].address + spans[i].length - 1) / 4096;
        for (NSUInteger page = spans[i].address / 4096; page <= last; page++) {
            uint64_t previous = atomic_fetch_sub_explicit(&readers[page], 1,
                                                          memory_order_release);
            assert(previous);
        }
    }
}

- (NSUInteger)count
{
    @synchronized (_stateLock) {
        return _surfaces.count;
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

- (BOOL)sourceVersionAtAddress:(NSUInteger)address
                        length:(NSUInteger)length
                       version:(uint64_t *)version
                         error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error] || ![self validRange:address
                                                length:length
                                                 error:error]) {
            return NO;
        }
        if (!version) {
            return cache_error(error, @"Invalid texture source version request");
        }
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
            for (NV2AMetalCachedSurface *s in [self overlaps:address
                                                      length:length]) {
                if (s.generation > *version) {
                    *version = s.generation;
                }
            }
        }
        return YES;
    }
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
            ![_commands beginWithError:error]) {
            return NO;
        }
        _recording = YES;
        _token = [[NV2AMetalSurfaceRecording alloc] initRecording];
    }
    return YES;
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
            [self capture:s];
        _rasterTargets = [targets copy];
        return YES;
    }
}

- (void)capture:(NV2AMetalCachedSurface *)s
{
    if (!s.recording) {
        s.pendingDirty = s.committedDirty;
        s.pendingUpload = s.committedUpload;
        s.pendingBorder = s.committedBorder;
        s.pendingGeneration = s.committedGeneration;
        s.recording = YES;
        [_recordingEntries addObject:s];
    }
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
        [self capture:s];
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
    }
    return YES;
}

- (BOOL)markRTTSampling:(NV2AMetalCachedSurface *)surface
                  error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error] || !surface.valid ||
            ![_surfaces containsObject:surface] || ![self begin:error])
            return cache_error(error, @"Invalid surface RTT sampling capture");
        [self capture:surface];
        surface.pendingBorder = YES;
        return YES;
    }
}
- (void)acceptRecording
{
    for (NV2AMetalCachedSurface *s in _recordingEntries) {
        s.committedDirty = s.pendingDirty;
        s.committedUpload = s.pendingUpload;
        s.committedBorder = s.pendingBorder;
        s.committedGeneration = s.pendingGeneration;
        s.recording = NO;
    }
    [_recordingEntries removeAllObjects];
    [_sealedTokens addObject:_token];
    _token = nil;
    _recording = NO;
    _sealedReadBytes = _pendingReads.length;
    _sealedWriteBytes = _pendingWrites.length;
    _sealedDownloads = _pendingDownloads.count;
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
            if (_sealedTokens.count + 1 == NV2AMetalCommandBatchLimit ||
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
                if ([reader.submission completedWithError:&failure] && failure)
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
        submitted.readWitnesses = [_pendingReadWitnesses copy];
        [_pendingReadWitnesses removeAllObjects];
        [_pendingDependencies removeAllObjects];
        submitted.readBytes = _pendingReads.length;
        submitted.writeBytes = _pendingWrites.length;
        submitted.downloads = _pendingDownloads.count;
        submitted.tokens = _sealedTokens.count;
        [_submissions addObject:submitted];
        [_submittedWrites appendData:_pendingWrites];
        _pendingWrites.length = 0;
        [_submittedReads appendData:_pendingReads];
        _pendingReads.length = 0;
        [_submittedDownloads addObjectsFromArray:_pendingDownloads];
        for (NV2AMetalCachedSurface *s in _pendingDownloads) {
            [self stamp:s.address
                 length:s.reservationLength
                version:s.generation];
        }
        [_pendingDownloads removeAllObjects];
        for (NV2AMetalSurfaceRecording *token in _sealedTokens)
            token.submitted = YES;
        [_submittedTokens addObjectsFromArray:_sealedTokens];
        [_sealedTokens removeAllObjects];
        _sealedReadBytes = _sealedWriteBytes = _sealedDownloads = 0;
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
        _token = nil;
        for (NV2AMetalCachedSurface *s in _recordingEntries) {
            s.recording = NO;
        }
        [_recordingEntries removeAllObjects];
        [_pendingDependencies
            removeObjectsInRange:NSMakeRange(_sealedDependencies,
                                             _pendingDependencies.count -
                                                 _sealedDependencies)];
        [_pendingReadWitnesses
            removeObjectsInRange:NSMakeRange(_sealedReadWitnesses,
                                             _pendingReadWitnesses.count -
                                                 _sealedReadWitnesses)];
        [_pendingDownloads
            removeObjectsInRange:NSMakeRange(_sealedDownloads,
                                             _pendingDownloads.count -
                                                 _sealedDownloads)];
        [self retireGPUReaders:[_pendingReads
                                   subdataWithRange:NSMakeRange(
                                                        _sealedReadBytes,
                                                        _pendingReads.length -
                                                            _sealedReadBytes)]];
        _pendingReads.length = _sealedReadBytes;
        _pendingWrites.length = _sealedWriteBytes;
        _recording = NO;
    }
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

/* The owner holds the metadata guard. Keep a completed reader's scope until
 * every submitted writer that can invalidate its result has passed its
 * execution witness, including the writer queue's earlier feedback prefix. */
- (BOOL)checkReadWitnessesForReader:(NV2AMetalIndependentReads *)reader
                          completed:(BOOL *)completed
                              error:(NSError **)error
{
    *completed = NO;
    NSUInteger prefix = 0;
    for (NSUInteger i = 0; i < _submissions.count; i++)
        for (NV2AMetalReadWitness *witness in _submissions[i].readWitnesses)
            if (witness.reader == reader)
                prefix = i + 1;
    for (NSUInteger i = 0; i < prefix; i++) {
        NV2AMetalSurfaceSubmission *writer = _submissions[i];
        NSError *failure = nil;
        if (![writer.submission completedWithError:&failure])
            return YES;
        if (failure)
            return [self independentReadFailure:failure error:error];
        for (NV2AMetalReadWitness *witness in writer.readWitnesses) {
            if (witness.reader != reader)
                continue;
            uint64_t observed;
            memcpy(&observed, witness.observed.contents, sizeof(observed));
            if (observed != 1) {
                cache_error(
                    &failure,
                    @"VRAM write executed before its GPU readers completed");
                return [self independentReadFailure:failure error:error];
            }
        }
    }
    *completed = YES;
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
        readers = [_independentReads copy];
    }
    for (NSUInteger i = 0; i < readers.count; i++) {
        NV2AMetalIndependentReads *reader = readers[i];
        if (!all && !read_spans_overlap(reader.spans, address, length))
            continue;
        if (!reader.submission)
            return cache_error(
                error,
                @"Submit or cancel independent VRAM reads before writing");
        /* Validate this queue's feedback prefix too: callback arrival order
         * need not match GPU execution order. Do not touch a later recording.
         */
        for (NSUInteger j = 0; j <= i; j++) {
            NV2AMetalIndependentReads *prior = readers[j];
            if (prior.commands != reader.commands)
                continue;
            NSError *failure = nil;
            if (!prior.submission ||
                ![prior.commands waitForSubmission:prior.submission
                                             error:&failure])
                return [self independentReadFailure:failure error:error];
        }
    }
    return [self collectCompletedWithError:error];
}

- (BOOL)orderAfterIndependentReadsAtAddress:(NSUInteger)address
                                     length:(NSUInteger)length
                                      error:(NSError **)error
{
    if (![self healthy:error])
        return NO;
    if (!_independentReads.count || !length)
        return YES;
    NSMutableArray<NV2AMetalIndependentReads *> *required =
        [NSMutableArray new];
    for (NSUInteger i = 0; i < _independentReads.count; i++) {
        NV2AMetalIndependentReads *reader = _independentReads[i];
        if (!read_spans_overlap(reader.spans, address, length))
            continue;
        /* A GPU event orders execution, not callback arrival. Retain and
         * validate the source queue's earlier feedback prefix as well. */
        for (NSUInteger j = 0; j <= i; j++) {
            NV2AMetalIndependentReads *prior = _independentReads[j];
            if (prior.commands != reader.commands)
                continue;
            if (!prior.submission)
                return cache_error(
                    error,
                    @"Submit or cancel independent VRAM reads before writing");
            NSError *failure = nil;
            if ([prior.submission completedWithError:&failure] && failure)
                return [self independentReadFailure:failure error:error];
            if (![required containsObject:prior])
                [required addObject:prior];
        }
    }
    if (required.count && ![self begin:error])
        return NO;
    for (NV2AMetalIndependentReads *reader in required) {
        if (![_commands orderAfterSubmission:reader.submission
                                fromCommands:reader.commands
                                       error:error]) {
            NSError *failure = nil;
            if ([reader.submission completedWithError:&failure] && failure)
                return [self independentReadFailure:failure error:error];
            return NO;
        }
        if (![_pendingDependencies containsObject:reader])
            [_pendingDependencies addObject:reader];
        if (!read_spans_overlap(reader.spans, address, length))
            continue;
        NSError *failure = nil;
        if ([reader.submission completedWithError:&failure]) {
            if (failure)
                return [self independentReadFailure:failure error:error];
            continue; /* CPU feedback already precedes this writer's submit. */
        }
        BOOL recorded = NO;
        for (NV2AMetalReadWitness *witness in _pendingReadWitnesses)
            recorded |= witness.reader == reader;
        if (recorded)
            continue;
        if (!reader.completionMarker)
            return cache_error(
                error, @"Missing submitted VRAM read completion marker");
        id<MTLBuffer> observed =
            [_commands.device newBufferWithLength:sizeof(uint64_t)
                                          options:MTLResourceStorageModeShared];
        if (!observed)
            return cache_error(
                error, @"Could not allocate VRAM read completion witness");
        memset(observed.contents, 0, observed.length);
        if (!copy_read_marker(_commands, reader.completionMarker, 0, observed,
                              error))
            return NO;
        NV2AMetalReadWitness *witness = [NV2AMetalReadWitness new];
        witness.reader = reader;
        witness.observed = observed;
        [_pendingReadWitnesses addObject:witness];
    }
    return YES;
}

- (BOOL)collectCompletedWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        while (_independentReads.count) {
            NV2AMetalIndependentReads *reader = _independentReads[0];
            NSError *failure = nil;
            if (!reader.submission ||
                ![reader.submission completedWithError:&failure])
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
            [self retireGPUReaders:reader.spans];
            [_independentReads removeObjectAtIndex:0];
        }
        while (_submissions.count) {
            NV2AMetalSurfaceSubmission *submitted = _submissions[0];
            BOOL pending = NO;
            for (NV2AMetalIndependentReads *reader in submitted.dependencies) {
                NSError *failure = nil;
                BOOL ready = [reader.submission completedWithError:&failure];
                if (ready && failure)
                    return [self independentReadFailure:failure error:error];
                pending |= !ready;
            }
            NSError *failure = nil;
            if (![submitted.submission completedWithError:&failure])
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
            for (NV2AMetalReadWitness *witness in submitted.readWitnesses) {
                uint64_t observed;
                memcpy(&observed, witness.observed.contents, sizeof(observed));
                if (observed != 1) {
                    cache_error(&failure, @"VRAM write executed before its GPU "
                                          @"readers completed");
                    return [self independentReadFailure:failure error:error];
                }
            }
            NSRange reads = NSMakeRange(0, submitted.readBytes);
            [self retireGPUReaders:_submittedReads length:submitted.readBytes];
            [_submittedReads replaceBytesInRange:reads withBytes:NULL length:0];
            [_submittedWrites
                replaceBytesInRange:NSMakeRange(0, submitted.writeBytes)
                          withBytes:NULL
                             length:0];
            for (NSUInteger i = 0; i < submitted.tokens; i++)
                _submittedTokens[i].completed = YES;
            [_submittedTokens
                removeObjectsInRange:NSMakeRange(0, submitted.tokens)];
            [_submissions removeObjectAtIndex:0];
            for (NSUInteger i = 0; i < submitted.downloads; i++) {
                NV2AMetalCachedSurface *s = _submittedDownloads[0];
                if (_didWriteVRAM)
                    _didWriteVRAM(s.address, s.reservationLength);
                [_submittedDownloads removeObjectAtIndex:0];
            }
        }
        return YES;
    }
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
        for (NSUInteger i = 0; i < _submissions.count; i++) {
            if (_submissions[i].submission == submission) {
                prefix = i + 1;
                break;
            }
        }
    }
    /* GPU execution is ordered, but feedback callbacks need not arrive in
     * that order. Validate the earlier prefix before publishing dependent
     * state. The PGRAPH owner alone changes this array. */
    for (NSUInteger i = 0; i < MAX(prefix, 1u); i++) {
        NV2AMetalSubmission *prior = submission;
        NSArray<NV2AMetalIndependentReads *> *dependencies = nil;
        @synchronized(_stateLock) {
            if (prefix) {
                prior = _submissions[i].submission;
                dependencies = _submissions[i].dependencies;
            }
        }
        for (NV2AMetalIndependentReads *reader in dependencies) {
            NSError *failure = nil;
            if (![reader.commands waitForSubmission:reader.submission
                                              error:&failure])
                return [self independentReadFailure:failure error:error];
        }
        NSError *failure = nil;
        if (![_commands waitForSubmission:prior error:&failure]) {
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
    return [self collectCompletedWithError:error];
}

- (BOOL)waitUntilIdleWithError:(NSError **)error
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
    if (![self waitForIndependentReadsAtAddress:0 length:0 all:YES error:error])
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

- (BOOL)retire:(NSArray<NV2AMetalCachedSurface *> *)selected
         error:(NSError **)error
{
    if (!selected.count) {
        return YES;
    }
    if (![self download:selected error:error] ||
        ![self submitWithError:error]) {
        return NO;
    }
    /* Retire this queue's texture work and publish any writeback. Downloads
     * already wait for overlapping VRAM readers; unrelated or read-only
     * producers do not own these private textures. */
    NV2AMetalSubmission *submission = _commands.lastSubmitted;
    if (submission && ![self waitForSubmission:submission error:error])
        return NO;
    for (NV2AMetalCachedSurface *s in selected) {
        s.valid = NO;
        [_surfaces removeObjectIdenticalTo:s];
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
            if (s.address == address && old.color == c->color &&
                old.format == c->format &&
                old.floating_depth == c->floating_depth &&
                old.pitch == c->pitch && old.scale == c->scale &&
                old.swizzle == c->swizzle &&
                s.transfer.texture.pixelFormat == layout.pixel_format &&
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
                             error:error];
            if (!transfer ||
                ![self retire:[self overlaps:address
                                      length:layout.reservation_length]
                        error:error]) {
                return nil;
            }
            surface = [[NV2AMetalCachedSurface alloc]
                initWithTransfer:transfer
                         address:address
                          length:layout.reservation_length
                       stateLock:_stateLock];
            surface.committedGeneration = ++_generation;
            [_surfaces addObject:surface];
        }
        if (surface.needsUpload && ![self prepareTextureRead:surface
                                                       error:error])
            return nil;
        if (forRendering || surface.needsUpload) {
            if (![self begin:error])
                return nil;
            [self capture:surface];
        }
        if (surface.needsUpload) {
            NV2AMetalVRAMReadPattern read = { surface.address,
                                              surface.reservationLength, 0, 0 };
            [self addGPUReaderAtAddress:read.address length:read.length];
            [_pendingReads appendBytes:&read length:sizeof(read)];
            if (![surface.transfer encodeUploadFromBuffer:_vram
                                                   offset:surface.address
                                                 commands:_commands
                                                    error:error]) {
                return nil;
            }
            surface.pendingUpload = NO;
        }
        surface.frame = frame;
        return surface;
    }
}

- (BOOL)markWritten:(NV2AMetalCachedSurface *)s error:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error]) {
            return NO;
        }
        if (!_recording || ![_surfaces containsObject:s] || !s.valid ||
            !s.recording || s.needsUpload) {
            return cache_error(
                error, @"Draw requires a prepared live surface in this recording");
        }
        if (_generation == UINT64_MAX) {
            return cache_error(error, @"Surface content generation is exhausted");
        }
        [self capture:s];
        s.pendingDirty = YES;
        s.pendingGeneration = ++_generation;
        return YES;
    }
}

- (BOOL)prepareCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                            error:(NSError **)error
{
    @synchronized (_stateLock) {
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
            return cache_error(error, @"Surface content generation is exhausted");
        }
        if (![self download:selected error:error] ||
            ![self submitWithError:error] || ![self waitUntilIdleWithError:error]) {
            return NO;
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

- (BOOL)tryIdleCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                        completed:(BOOL *)completed
                            error:(NSError **)error
{
    @synchronized (_stateLock) {
        *completed = NO;
        if (![self healthy:error] || ![self validRange:address
                                                length:length
                                                 error:error])
            return NO;
        if (!length) {
            *completed = YES;
            return YES;
        }
        NSData *writes[] = { _pendingWrites, _submittedWrites };
        for (unsigned i = 0; i < 2; i++) {
            const NV2AMetalVRAMRead *spans = writes[i].bytes;
            for (NSUInteger j = 0; j < writes[i].length / sizeof(*spans); j++)
                if (spans[j].address < address + length &&
                    address < spans[j].address + spans[j].length)
                    return YES;
        }
        if (write) {
            for (NV2AMetalIndependentReads *reader in _independentReads)
                if (read_spans_overlap(reader.spans, address, length))
                    return YES;
            NSData *reads[] = { _pendingReads, _submittedReads };
            for (unsigned i = 0; i < 2; i++)
                if (read_spans_overlap(reads[i], address, length))
                    return YES;
        }
        /* Downloads conflict with both CPU reads and writes, including ones
         * already marked clean at submission. */
        {
            NSArray *downloads[] = { _pendingDownloads, _submittedDownloads };
            for (unsigned i = 0; i < 2; i++)
                for (NV2AMetalCachedSurface *surface in downloads[i])
                    if (surface.address < address + length &&
                        address < surface.address + surface.reservationLength)
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
    @synchronized(_stateLock) {
        if (![self healthy:error] || ![self validReadPattern:p error:error])
            return NO;
        NSMutableArray *selected = [NSMutableArray new];
        for (NV2AMetalCachedSurface *surface in _surfaces)
            if (read_pattern_overlap(p, surface.address,
                                     surface.reservationLength))
                [selected addObject:surface];
        if (![self download:selected error:error] || ![self begin:error] ||
            ![_commands addResource:_vram error:error])
            return NO;
        [self watchCPUWritesAtAddress:p.address length:p.length];
        if (p.length) {
            [self addGPUReaderAtAddress:p.address length:p.length];
            [_pendingReads appendBytes:&p length:sizeof(p)];
        }
        return YES;
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

- (BOOL)tryBeginIndependentReadPatterns:(const NV2AMetalVRAMReadPattern *)spans
                                  count:(NSUInteger)count
                               commands:(NV2AMetalCommands *)commands
                                  reads:(NV2AMetalIndependentReads **)reads
                                  error:(NSError **)error
{
    @synchronized(_stateLock) {
        *reads = nil;
        if (![self collectCompletedWithError:error])
            return NO;
        if (!commands || commands == _commands ||
            commands.device != _commands.device || commands.commandBuffer ||
            (!spans && count) || count > NSUIntegerMax / sizeof(*spans))
            return cache_error(error,
                               @"Invalid independent VRAM read queue/spans");
        NSMutableData *ranges = [NSMutableData new];
        for (NSUInteger i = 0; i < count; i++) {
            if (![self validReadPattern:spans[i] error:error])
                return NO;
            if (!spans[i].length)
                continue;
            if (writes_overlap_pattern(_pendingWrites, spans[i]) ||
                writes_overlap_pattern(_submittedWrites, spans[i]))
                return YES;
            /* Clean textures and their uploads do not write VRAM. A dirty
             * alias still needs this queue's ordered download before fetch. */
            for (NV2AMetalCachedSurface *surface in _surfaces)
                if (surface.dirty &&
                    read_pattern_overlap(spans[i], surface.address,
                                         surface.reservationLength))
                    return YES;
            NSArray *downloads[] = { _pendingDownloads, _submittedDownloads };
            for (unsigned j = 0; j < 2; j++)
                for (NV2AMetalCachedSurface *surface in downloads[j])
                    if (read_pattern_overlap(spans[i], surface.address,
                                             surface.reservationLength))
                        return YES;
            [ranges appendBytes:&spans[i] length:sizeof(*spans)];
        }
        if (![commands beginWithError:error])
            return NO;
        if (ranges.length && ![commands addResource:_vram error:error]) {
            [commands cancel];
            return NO;
        }
        NV2AMetalIndependentReads *reader =
            [[NV2AMetalIndependentReads alloc] initRecording];
        reader.commands = commands;
        reader.owner = self;
        reader.spans = [ranges copy];
        const NV2AMetalVRAMReadPattern *registered = reader.spans.bytes;
        for (NSUInteger i = 0; i < reader.spans.length / sizeof(*registered);
             i++) {
            [self watchCPUWritesAtAddress:registered[i].address
                                   length:registered[i].length];
            [self addGPUReaderAtAddress:registered[i].address
                                 length:registered[i].length];
        }
        [_independentReads addObject:reader];
        *reads = reader;
        return YES;
    }
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
            if (!constant || !copy_read_marker(reads.commands, constant, offset,
                                               marker, error))
                return NO;
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
    NSArray<NV2AMetalIndependentReads *> *prefix;
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        if (reads.owner != self || !reads.submission)
            return cache_error(
                error, @"No submitted independent VRAM reads to complete");
        NSUInteger index = [_independentReads indexOfObjectIdenticalTo:reads];
        prefix =
            index == NSNotFound ?
                @[ reads ] :
                [_independentReads subarrayWithRange:NSMakeRange(0, index + 1)];
    }
    /* Feedback may arrive out of order. Include earlier scopes on this queue,
     * including submitted cancellations, but never wait for a later scope or
     * alter a later recording. Already retired scopes passed this check. */
    for (NV2AMetalIndependentReads *prior in prefix) {
        if (prior.commands != reads.commands)
            continue;
        NSError *failure = nil;
        if (!prior.submission ||
            ![prior.commands waitForSubmission:prior.submission error:&failure])
            return [self independentReadFailure:failure error:error];
    }
    NSArray<NV2AMetalSurfaceSubmission *> *writers;
    @synchronized(_stateLock) {
        if (![self healthy:error])
            return NO;
        NSUInteger count = 0;
        for (NSUInteger i = 0; i < _submissions.count; i++)
            for (NV2AMetalReadWitness *witness in _submissions[i].readWitnesses)
                if (witness.reader.commands == reads.commands &&
                    [prefix containsObject:witness.reader])
                    count = i + 1;
        writers = [_submissions subarrayWithRange:NSMakeRange(0, count)];
    }
    /* An event timeout can damage reader bytes even if source feedback
     * succeeds. Wait only the native writer prefix needed to inspect these
     * witnesses; do not wait other producers' later feedback or recordings. */
    for (NV2AMetalSurfaceSubmission *writer in writers) {
        NSError *failure = nil;
        if (![_commands waitForSubmission:writer.submission error:&failure])
            return [self independentReadFailure:failure error:error];
    }
    @synchronized(_stateLock) {
        for (NV2AMetalIndependentReads *prior in prefix) {
            if (prior.commands != reads.commands)
                continue;
            BOOL checked = NO;
            if (![self checkReadWitnessesForReader:prior
                                         completed:&checked
                                             error:error])
                return NO;
            if (!checked) {
                NSError *failure = nil;
                cache_error(
                    &failure,
                    @"GPU reader execution witness feedback is missing");
                return [self independentReadFailure:failure error:error];
            }
        }
    }
    return [self collectCompletedWithError:error];
}

- (void)cancelIndependentReads:(NV2AMetalIndependentReads *)reads
{
    @synchronized(_stateLock) {
        if (![_independentReads containsObject:reads] || reads.submission)
            return;
        [reads.commands cancel];
        [self retireGPUReaders:reads.spans];
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
        if (![self orderAfterIndependentReadsAtAddress:address
                                                length:length
                                                 error:error])
            return NO;
        [self watchCPUReadsAtAddress:address length:length];
        if (![self begin:error] || ![_commands addResource:_vram error:error])
            return NO;
        if (length) {
            NV2AMetalVRAMRead span = { address, length };
            [_pendingWrites appendBytes:&span length:sizeof(span)];
        }
        return YES;
    }
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
        NSData *writes[] = { _pendingWrites, _submittedWrites };
        for (unsigned i = 0; i < 2; i++) {
            const NV2AMetalVRAMRead *spans = writes[i].bytes;
            for (NSUInteger j = 0; j < writes[i].length / sizeof(*spans); j++)
                if (length && spans[j].address < address + length &&
                    address < spans[j].address + spans[j].length)
                    return cache_error(error, @"CPU dirty notification conflicts with GPU-owned VRAM");
        }
        for (NV2AMetalCachedSurface *s in [self overlaps:address length:length]) {
            if (s.dirty) {
                return cache_error(
                    error, @"CPU dirty notification conflicts with GPU-owned VRAM");
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
        return [self prepareCPUAccessAtAddress:address
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
        if (![self retire:[self overlaps:address length:length] error:error]) {
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
        return [self retire:selected error:error];
    }
}

- (BOOL)flushWithError:(NSError **)error
{
    @synchronized (_stateLock) {
        if (![self healthy:error] || ![self retire:[_surfaces copy] error:error] ||
            ![self submitWithError:error] || ![self waitUntilIdleWithError:error]) {
            return NO;
        }
        return YES;
    }
}

- (BOOL)discardForRestoreWithError:(NSError **)error
{
    @synchronized(_stateLock) {
        if (![self healthy:error]) {
            return NO;
        }
        if (_generation == UINT64_MAX) {
            return cache_error(error,
                               @"Cannot invalidate restore source versions");
        }
        [self cancel];
        [_commands cancel];
        _rasterTargets = nil;
        for (NV2AMetalSurfaceRecording *token in _sealedTokens)
            token.cancelled = YES;
        [_sealedTokens removeAllObjects];
        [self retireGPUReaders:_pendingReads];
        _pendingReads.length = _pendingWrites.length = 0;
        [_pendingDownloads removeAllObjects];
        [_pendingDependencies removeAllObjects];
        [_pendingReadWitnesses removeAllObjects];
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
        }
        [_surfaces removeAllObjects];
        [self stamp:0 length:_vram.length version:++_generation];
        return YES;
    }
}
@end
