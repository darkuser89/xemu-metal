/*
 * NV2A Metal 4 command submission
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "command.h"
#include <stdatomic.h>
#include <string.h>

static const NSUInteger command_slot_count = 3;
static const NSUInteger upload_page_size = 64 * 1024;
static const NSUInteger upload_page_limit = 16;
static const NSUInteger upload_alignment = 256;
static const int64_t completion_timeout_ns = 30 * NSEC_PER_SEC;
static NSString *const command_error_domain = @"xemu.nv2a.metal4";

static BOOL command_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:command_error_domain
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

@interface NV2AMetalSubmission ()
- (instancetype)initPendingWithOwner:(NV2AMetalCommands *)owner
                               event:(id<MTLEvent>)event
                               value:(uint64_t)value
                               parts:(NSUInteger)parts;
@property(nonatomic, readonly) id<MTLEvent> signalEvent;
@property(nonatomic, readonly) uint64_t signalValue;
- (void)finishWithError:(nullable NSError *)error;
- (BOOL)completePartWithError:(nullable NSError *)error
                      failure:(NSError **)failure;
- (BOOL)waitForOwner:(NV2AMetalCommands *)owner error:(NSError **)error;
- (void)finishProducersWithError:(nullable NSError *)error;
- (BOOL)waitForProducersForOwner:(NV2AMetalCommands *)owner
                           error:(NSError **)error;
- (BOOL)belongsToOwner:(NV2AMetalCommands *)owner;
@end
@implementation NV2AMetalSubmission {
    atomic_bool _completed;
    NSError *_error;
    __weak NV2AMetalCommands *_owner;
    dispatch_group_t _completion;
    dispatch_group_t _producerCompletion;
    atomic_bool _producersCompleted;
    NSError *_producerError;
    NSUInteger _parts;
}
- (instancetype)initPendingWithOwner:(NV2AMetalCommands *)owner
                               event:(id<MTLEvent>)event
                               value:(uint64_t)value
                               parts:(NSUInteger)parts
{
    self = [super init];
    if (self) {
        atomic_init(&_completed, false);
        atomic_init(&_producersCompleted, false);
        _owner = owner;
        _signalEvent = event;
        _signalValue = value;
        _parts = parts;
        _completion = dispatch_group_create();
        dispatch_group_enter(_completion);
        if (parts > 1) {
            _producerCompletion = dispatch_group_create();
            dispatch_group_enter(_producerCompletion);
        }
    }
    return self;
}
- (BOOL)completePartWithError:(NSError *)error failure:(NSError **)failure
{
    @synchronized(self) {
        if (!_error)
            _error = error;
        if (--_parts)
            return NO;
        *failure = _error;
    }
    [self finishWithError:*failure];
    return YES;
}
- (void)finishWithError:(NSError *)error
{
    @synchronized(self) {
        _error = error;
        atomic_store_explicit(&_completed, true, memory_order_release);
    }
    dispatch_group_leave(_completion);
}
- (BOOL)waitForOwner:(NV2AMetalCommands *)owner error:(NSError **)error
{
    if (![self belongsToOwner:owner])
        return command_error(error,
                             @"Submission belongs to another Metal queue");
    if (dispatch_group_wait(_completion, dispatch_time(DISPATCH_TIME_NOW,
                                                       completion_timeout_ns)))
        return command_error(error, @"Timed out waiting for Metal submission");
    NSError *failure = nil;
    if (![self completedWithError:&failure])
        return command_error(error, @"Metal submission completion is missing");
    if (error)
        *error = failure;
    return !failure;
}
- (BOOL)belongsToOwner:(NV2AMetalCommands *)owner
{
    return owner && _owner == owner;
}
- (BOOL)hasSeparateProducerFeedback
{
    return _producerCompletion != nil;
}
- (void)finishProducersWithError:(NSError *)error
{
    assert(_producerCompletion);
    _producerError = error;
    atomic_store_explicit(&_producersCompleted, true, memory_order_release);
    dispatch_group_leave(_producerCompletion);
}
- (BOOL)completedProducersWithError:(NSError **)error
{
    if (!_producerCompletion)
        return [self completedWithError:error];
    BOOL completed =
        atomic_load_explicit(&_producersCompleted, memory_order_acquire);
    /* Full completion can publish just before the producer callback reaches
     * its separate flag. That full receipt already covers every producer. */
    if (!completed)
        return [self completedWithError:error];
    NSError *failure = nil;
    /* The producer callback publishes its part after the aggregate update.
     * If raster feedback arrived first, preserve its now-known failure. */
    if (completed && !([self completedWithError:&failure] && failure))
        failure = _producerError;
    if (error)
        *error = failure;
    return completed;
}
- (BOOL)waitForProducersForOwner:(NV2AMetalCommands *)owner
                           error:(NSError **)error
{
    if (!_producerCompletion)
        return [self waitForOwner:owner error:error];
    if (![self belongsToOwner:owner])
        return command_error(error,
                             @"Submission belongs to another Metal queue");
    if (dispatch_group_wait(
            _producerCompletion,
            dispatch_time(DISPATCH_TIME_NOW, completion_timeout_ns)))
        return command_error(error, @"Timed out waiting for Metal producers");
    NSError *failure = nil;
    if (![self completedProducersWithError:&failure])
        return command_error(error, @"Metal producer completion is missing");
    if (error)
        *error = failure;
    return !failure;
}
- (BOOL)completedWithError:(NSError **)error
{
    /* The last feedback publishes the immutable result and GPU visibility.
     * Pending readers never access the error while parts can still write it. */
    BOOL completed = atomic_load_explicit(&_completed, memory_order_acquire);
    if (error)
        *error = completed ? _error : nil;
    return completed;
}
@end

@interface NV2AMetalQueueWait : NSObject
@property(nonatomic) NV2AMetalSubmission *submission;
@property(nonatomic) id<MTL4CommandQueue> queue;
@property(nonatomic) id<MTLEvent> event;
@property(nonatomic) uint64_t value;
@property(nonatomic) BOOL feedbackSucceeded, needsEventWait;
@end
@implementation NV2AMetalQueueWait
@end

@interface NV2AMetalCommandPart : NSObject
@property(nonatomic) BOOL producer, completed;
@property(nonatomic, nullable) NSError *error;
@property(nonatomic, nullable) NV2AMetalSubmission *receipt;
@end
@implementation NV2AMetalCommandPart
@end

API_AVAILABLE(macos(26.0))
@interface NV2AMetalCommandSlot : NSObject
@property(nonatomic, strong) id<MTL4CommandAllocator> allocator;
@property(nonatomic, strong) id<MTL4CommandBuffer> buffer;
@property(nonatomic, strong) NSMutableArray<id<MTL4CommandBuffer>> *buffers;
@property(nonatomic) NSMutableArray<id<MTL4CommandBuffer>> *rasters;
@property(nonatomic, nullable) id<MTL4CommandBuffer> rasterTail;
@property(nonatomic, nullable) MTL4RenderPassDescriptor *rasterPass;
@property(nonatomic) NSUInteger sealedRasters;
@property(nonatomic) BOOL inRaster;
@property(nonatomic, strong) id<MTLResidencySet> residency;
@property(nonatomic, strong) NSMutableArray *objects;
/* Raw identity index. The ordered objects array owns every entry. */
@property(nonatomic, readonly) CFMutableSetRef objectIdentities;
@property(nonatomic) NSMutableArray<NV2AMetalQueueWait *> *waits;
/* The ordered waits retain queue/event state and determine error priority. */
@property(nonatomic)
    NSMapTable<NV2AMetalSubmission *, NV2AMetalQueueWait *> *waitReceipts;
@property(nonatomic, strong) NSMutableArray<id<MTLResource>> *resources;
@property(nonatomic, strong) NSHashTable<id<MTLResource>> *registeredResources;
@property(nonatomic, strong) NSHashTable<id<MTLResource>> *resourceRoots;
@property(nonatomic, strong) NSMutableArray<id<MTLResource>> *sectionRoots;
@property(nonatomic) NSUInteger resourceBytes, sealedResourceBytes,
    baselineResourceBytes;
@property(nonatomic) uint64_t baselineAllocatorBytes;
@property(nonatomic) BOOL hasBudgetBaseline;
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *uploadPages;
@property(nonatomic, strong, nullable) id<MTLBuffer> transferScratch;
@property(nonatomic) NSUInteger uploadPage, uploadOffset;
@property(nonatomic) NSUInteger sealedCount, sealedObjects, sealedResources,
    sealedUploadPage, sealedUploadOffset, sealedWaits;
/* Encoding owner appends section metadata; callbacks touch only part status
 * under this slot's monitor. The open host lease prevents early slot reuse. */
@property(nonatomic) uint64_t batchSerial;
@property(nonatomic) NSUInteger submittedProducers;
@property(nonatomic) NSMutableArray<NSNumber *> *sectionWaitCounts, *prefixEnds;
@property(nonatomic) NSMutableArray<NV2AMetalSubmission *> *prefixReceipts;
@property(nonatomic) NSMutableArray<NV2AMetalCommandPart *> *parts;
@property(nonatomic) NSUInteger pendingParts;
@property(nonatomic) BOOL closed, signaled, aggregateFinished,
    producersFinished;
@property(nonatomic, nullable) NV2AMetalSubmission *aggregate;
- (nullable NSError *)knownFailure;
- (void)registerPart:(NV2AMetalCommandPart *)part;
- (void)completePart:(NV2AMetalCommandPart *)part
               error:(nullable NSError *)error;
- (void)closeWithAggregate:(nullable NV2AMetalSubmission *)aggregate;
@property(nonatomic, strong) dispatch_semaphore_t available;
@property(nonatomic, strong, nullable) NSError *failure;
@property(nonatomic, strong, nullable) id<CAMetalDrawable> drawable;
@end

@implementation NV2AMetalCommandSlot
- (instancetype)init
{
    self = [super init];
    if (self) {
        _objectIdentities = CFSetCreateMutable(NULL, 0, NULL);
        if (!_objectIdentities)
            return nil;
    }
    return self;
}

- (NSError *)knownFailure
{
    @synchronized(self) {
        for (NV2AMetalCommandPart *part in _parts)
            if (part.completed && part.error)
                return part.error;
        return nil;
    }
}
- (void)registerPart:(NV2AMetalCommandPart *)part
{
    @synchronized(self) {
        assert(!_closed);
        [_parts addObject:part];
        _pendingParts++;
    }
}
- (void)publishCompletion
{
    /* Called only under the slot monitor. Commit order, rather than callback
     * order, selects the error. No resource collections change on this thread.
     */
    if (!_closed)
        return;
    NSError *failure = [self knownFailure];
    BOOL producersPending = NO;
    for (NV2AMetalCommandPart *part in _parts)
        producersPending |= part.producer && !part.completed;
    if (_aggregate.hasSeparateProducerFeedback && !_producersFinished &&
        !producersPending) {
        _producersFinished = YES;
        [_aggregate finishProducersWithError:failure];
    }
    if (!_pendingParts) {
        if (_aggregate && !_aggregateFinished) {
            _aggregateFinished = YES;
            [_aggregate finishWithError:failure];
        }
        if (!_signaled) {
            _signaled = YES;
            _failure = failure;
            dispatch_semaphore_signal(_available);
        }
    }
}
- (void)completePart:(NV2AMetalCommandPart *)part error:(NSError *)error
{
    @synchronized(self) {
        assert(!part.completed && _pendingParts);
        part.error = error;
        part.completed = YES;
        _pendingParts--;
        if (part.receipt) {
            NSError *failure = nil;
            [part.receipt completePartWithError:error failure:&failure];
        }
        [self publishCompletion];
    }
}
- (void)closeWithAggregate:(NV2AMetalSubmission *)aggregate
{
    @synchronized(self) {
        assert(!_closed);
        _aggregate = aggregate;
        _closed = YES;
        [self publishCompletion];
    }
}
- (void)dealloc
{
    if (_objectIdentities)
        CFRelease(_objectIdentities);
}
@end

static id<MTLResource> allocation_root(id<MTLResource> resource)
{
    if ([resource conformsToProtocol:@protocol(MTLTexture)]) {
        id<MTLTexture> texture = (id)resource;
        while (texture.parentTexture)
            texture = texture.parentTexture;
        id<MTLResource> buffer = texture.buffer;
        return buffer ?: (id<MTLResource>)texture;
    }
    return resource;
}

static BOOL raster_attachment_matches(MTLRenderPassAttachmentDescriptor *a,
                                      MTLRenderPassAttachmentDescriptor *b)
{
    if (a.texture != b.texture)
        return NO;
    if (!a.texture)
        return YES;
    return a.loadAction == MTLLoadActionLoad &&
           b.loadAction == MTLLoadActionLoad &&
           a.storeAction == MTLStoreActionStore &&
           b.storeAction == MTLStoreActionStore && a.level == b.level &&
           a.slice == b.slice && a.depthPlane == b.depthPlane &&
           !a.resolveTexture && !b.resolveTexture;
}

static BOOL raster_pass_matches(MTL4RenderPassDescriptor *a,
                                MTL4RenderPassDescriptor *b)
{
    if (!a || !b || a.renderTargetArrayLength != b.renderTargetArrayLength ||
        a.imageblockSampleLength != b.imageblockSampleLength ||
        a.threadgroupMemoryLength != b.threadgroupMemoryLength ||
        a.tileWidth != b.tileWidth || a.tileHeight != b.tileHeight ||
        a.defaultRasterSampleCount != b.defaultRasterSampleCount ||
        a.renderTargetWidth != b.renderTargetWidth ||
        a.renderTargetHeight != b.renderTargetHeight ||
        a.rasterizationRateMap || b.rasterizationRateMap ||
        a.visibilityResultBuffer != b.visibilityResultBuffer ||
        a.visibilityResultType != b.visibilityResultType ||
        a.supportColorAttachmentMapping || b.supportColorAttachmentMapping ||
        [a getSamplePositions:NULL count:0] ||
        [b getSamplePositions:NULL count:0])
        return NO;
    for (NSUInteger i = 0; i < 8; i++)
        if (!raster_attachment_matches(a.colorAttachments[i],
                                       b.colorAttachments[i]))
            return NO;
    return raster_attachment_matches(a.depthAttachment, b.depthAttachment) &&
           raster_attachment_matches(a.stencilAttachment, b.stencilAttachment);
}

@implementation NV2AMetalCommands {
    NSArray<NV2AMetalCommandSlot *> *_slots;
    NV2AMetalCommandSlot *_current, *_batch;
    id<MTL4CommandQueue> _queue;
    id<MTLEvent> _submissionEvent;
    uint64_t _lastSubmission;
    NSUInteger _nextSlot;
}

- (nullable instancetype)initWithError:(NSError **)error
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        command_error(error, @"No Metal GPU is available");
        return nil;
    }
    return [self initWithDevice:device error:error];
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _device = device;
    if (!_device || ![_device supportsFamily:MTLGPUFamilyApple7] ||
        ![_device supportsFamily:MTLGPUFamilyMetal4] ||
        !_device.hasUnifiedMemory) {
        command_error(error, @"Metal 4 requires a supported Apple Silicon GPU");
        return nil;
    }

    _queue = [_device newMTL4CommandQueue];
    _submissionEvent = [_device newEvent];
    if (!_queue || !_submissionEvent) {
        command_error(
            error, @"Could not create the Metal 4 submission queue and event");
        return nil;
    }

    NSMutableArray *slots = [NSMutableArray array];
    for (NSUInteger i = 0; i < command_slot_count; i++) {
        NV2AMetalCommandSlot *slot = [NV2AMetalCommandSlot new];
        slot.allocator = [_device newCommandAllocator];
        slot.buffer = [_device newCommandBuffer];
        MTLResidencySetDescriptor *descriptor = [MTLResidencySetDescriptor new];
        descriptor.label = @"NV2A submission resources";
        descriptor.initialCapacity = 128;
        NSError *residencyError = nil;
        slot.residency =
            [_device newResidencySetWithDescriptor:descriptor
                                             error:&residencyError];
        if (!slot.allocator || !slot.buffer || !slot.residency) {
            if (residencyError && error) {
                *error = residencyError;
            } else {
                command_error(error,
                              @"Could not allocate Metal 4 submission state");
            }
            return nil;
        }
        slot.objects = [NSMutableArray array];
        slot.waits = [NSMutableArray array];
        slot.waitReceipts = [NSMapTable
            mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsStrongMemory];
        slot.resources = [NSMutableArray array];
        slot.registeredResources = [NSHashTable
            hashTableWithOptions:NSPointerFunctionsStrongMemory |
                                 NSPointerFunctionsObjectPointerPersonality];
        slot.resourceRoots = [NSHashTable
            hashTableWithOptions:NSPointerFunctionsStrongMemory |
                                 NSPointerFunctionsObjectPointerPersonality];
        slot.sectionRoots = [NSMutableArray new];
        slot.buffers = [NSMutableArray arrayWithObject:slot.buffer];
        slot.rasters = [NSMutableArray new];
        slot.uploadPages = [NSMutableArray array];
        slot.sectionWaitCounts = [NSMutableArray new];
        slot.prefixEnds = [NSMutableArray new];
        slot.prefixReceipts = [NSMutableArray new];
        slot.parts = [NSMutableArray new];
        slot.available = dispatch_semaphore_create(1);
        [slots addObject:slot];
    }
    _slots = slots;
    return self;
}

- (nullable id<MTL4CommandBuffer>)beginWithError:(NSError **)error
{
    if (_current) {
        command_error(error, @"A Metal 4 command buffer is already recording");
        return nil;
    }
    if (_recordingSerial == UINT64_MAX) {
        command_error(error, @"Metal 4 recording identity is exhausted");
        return nil;
    }

    if (_batch) {
        NSError *failure = [_batch knownFailure];
        if (failure) {
            if (error)
                *error = failure;
            return nil;
        }
        if (_batch.sealedCount == NV2AMetalCommandBatchLimit) {
            command_error(error, @"Submit the full Metal command batch first");
            return nil;
        }
        if (_batch.sealedCount == _batch.buffers.count) {
            id<MTL4CommandBuffer> buffer = [_device newCommandBuffer];
            if (!buffer) {
                command_error(error, @"Could not allocate Metal batch section");
                return nil;
            }
            [_batch.buffers addObject:buffer];
        }
        _batch.buffer = _batch.buffers[_batch.sealedCount];
        _batch.inRaster = NO;
        [_batch.buffer beginCommandBufferWithAllocator:_batch.allocator];
        [_batch.buffer useResidencySet:_batch.residency];
        _current = _batch;
        _recordingSerial++;
        return _current.buffer;
    }

    NV2AMetalCommandSlot *slot = _slots[_nextSlot];
    if (dispatch_semaphore_wait(
            slot.available,
            dispatch_time(DISPATCH_TIME_NOW, completion_timeout_ns))) {
        command_error(error, @"Timed out waiting for Metal 4 GPU completion");
        return nil;
    }
    if (slot.failure) {
        if (error) {
            *error = slot.failure;
        }
        dispatch_semaphore_signal(slot.available);
        return nil;
    }

    /* Return secondary buffers' storage before recycling its allocator
     * generation. Only the head is rebound on every reuse; an unused tail
     * must not retain command storage across subsequent allocator resets. */
    slot.batchSerial = _recordingSerial + 1;
    slot.submittedProducers = slot.pendingParts = 0;
    slot.closed = slot.signaled = slot.aggregateFinished =
        slot.producersFinished = NO;
    slot.aggregate = nil;
    [slot.sectionWaitCounts removeAllObjects];
    [slot.prefixEnds removeAllObjects];
    [slot.prefixReceipts removeAllObjects];
    [slot.parts removeAllObjects];
    slot.buffer = slot.buffers[0];
    [slot.rasters removeAllObjects];
    slot.rasterTail = nil;
    slot.rasterPass = nil;
    slot.sealedRasters = 0;
    slot.inRaster = NO;
    [slot.buffers removeObjectsInRange:NSMakeRange(1, slot.buffers.count - 1)];
    /* Reset only after feedback confirms that the GPU finished this slot. */
    [slot.allocator reset];
    slot.uploadPage = slot.uploadOffset = 0;
    slot.sealedCount = slot.sealedObjects = slot.sealedResources = 0;
    slot.sealedWaits = 0;
    slot.sealedUploadPage = slot.sealedUploadOffset = 0;
    slot.hasBudgetBaseline = NO;
    slot.resourceBytes = slot.sealedResourceBytes = slot.baselineResourceBytes =
        0;
    slot.baselineAllocatorBytes = 0;
    slot.buffer = slot.buffers[0];
    slot.drawable = nil;
    CFSetRemoveAllValues(slot.objectIdentities);
    [slot.objects removeAllObjects];
    [slot.waits removeAllObjects];
    [slot.waitReceipts removeAllObjects];
    [slot.resources removeAllObjects];
    [slot.registeredResources removeAllObjects];
    [slot.resourceRoots removeAllObjects];
    [slot.sectionRoots removeAllObjects];
    [slot.residency removeAllAllocations];
    [slot.residency commit];
    [slot.buffer beginCommandBufferWithAllocator:slot.allocator];
    [slot.buffer useResidencySet:slot.residency];
    _current = _batch = slot;
    _recordingSerial++;
    return slot.buffer;
}

- (void)trackResource:(id<MTLResource>)resource
{
    NSHashTable *roots = _current.resourceRoots;
    if ([roots containsObject:resource])
        return;
    id<MTLResource> root = allocation_root(resource);
    if ([roots containsObject:root])
        return;
    [roots addObject:root];
    if (_current.sealedCount)
        [_current.sectionRoots addObject:root];
    NSUInteger total = _current.resourceBytes, bytes = root.allocatedSize;
    _current.resourceBytes =
        bytes > NSUIntegerMax - total ? NSUIntegerMax : total + bytes;
}

- (BOOL)orderAfterSubmission:(NV2AMetalSubmission *)submission
                fromCommands:(NV2AMetalCommands *)source
                       error:(NSError **)error
{
    if (!_current || !source || !submission || source.device != _device ||
        ![source ownsSubmission:submission])
        return command_error(
            error, @"Invalid Metal GPU dependency owner or recording");
    NV2AMetalQueueWait *wait = [_current.waitReceipts objectForKey:submission];
    BOOL ready = wait.feedbackSucceeded;
    if (!ready) {
        NSError *failure = nil;
        ready = [submission completedWithError:&failure];
        if (ready && failure) {
            if (error)
                *error = failure;
            return NO;
        }
    }
    if (source == self)
        return YES;
    if (wait) {
        wait.feedbackSucceeded = ready;
        return YES;
    }
    if (!submission.signalEvent || !submission.signalValue)
        return command_error(error,
                             @"Metal GPU dependency has no submitted timeline");
    wait = [NV2AMetalQueueWait new];
    wait.submission = submission;
    wait.queue = source->_queue;
    wait.event = submission.signalEvent;
    wait.value = submission.signalValue;
    wait.feedbackSucceeded = ready;
    [_current.waits addObject:wait];
    [_current.waitReceipts setObject:wait forKey:submission];
    return YES;
}

- (BOOL)addResource:(id<MTLResource>)resource error:(NSError **)error
{
    if (!_current) {
        return command_error(error, @"No Metal 4 command buffer is recording");
    }
    if (resource.device != _device) {
        return command_error(error,
                             @"Metal resource belongs to a different GPU");
    }
    /* Deduplicate the exact resource. Views sharing an allocation root
     * still need their own residency and lifetime registration. */
    if ([_current.registeredResources containsObject:resource])
        return YES;
    [_current.registeredResources addObject:resource];
    [_current.residency addAllocation:resource];
    [_current.resources addObject:resource];
    [self trackResource:resource];
    /* The exact-resource list already retains this allocation. */
    return YES;
}

- (nullable id<MTL4CommandBuffer>)commandBuffer
{
    return _current.buffer;
}

- (uint64_t)batchSerial
{
    return _batch.batchSerial;
}

- (NSUInteger)sealedBufferCount
{
    return _batch.sealedCount;
}

- (BOOL)hasPendingRasterPass
{
    return _batch.rasterPass != nil;
}

- (BOOL)recordingAllowsProducerWork
{
    return !_current || (!_current.inRaster && !_current.drawable);
}

- (BOOL)rasterPassMatches:(MTL4RenderPassDescriptor *)pass
{
    return raster_pass_matches(_batch.rasterPass ?: pass, pass);
}

- (MTL4RenderPassDescriptor *)copyPendingRasterPass
{
    return [_batch.rasterPass copy];
}

- (id<MTL4RenderCommandEncoder>)beginRasterPass:(MTL4RenderPassDescriptor *)pass
                                          error:(NSError **)error
{
    if (!_current || _current.inRaster || _current.drawable ||
        ![self rasterPassMatches:pass]) {
        command_error(error, @"Raster pass requires compatible producer work");
        return nil;
    }
    NV2AMetalCommandSlot *slot = _current;
    id<MTL4CommandBuffer> buffer = [_device newCommandBuffer];
    if (!buffer) {
        command_error(error, @"Could not allocate raster section");
        return nil;
    }
    if (!slot.rasterPass) {
        id<MTL4CommandBuffer> tail = [_device newCommandBuffer];
        if (!tail) {
            command_error(error, @"Could not allocate raster terminator");
            return nil;
        }
        MTL4RenderPassDescriptor *captured = [pass copy];
        [slot.buffer endCommandBuffer];
        /* One allocator may have only one open buffer. Keep the terminator
         * as the cancellable current buffer if its encoder cannot be made. */
        slot.buffer = tail;
        [tail beginCommandBufferWithAllocator:slot.allocator];
        [tail useResidencySet:slot.residency];
        id<MTL4RenderCommandEncoder> end = [tail
            renderCommandEncoderWithDescriptor:captured
                                       options:MTL4RenderEncoderOptionResuming];
        if (!end) {
            command_error(error, @"Could not encode raster terminator");
            return nil;
        }
        [end endEncoding];
        [tail endCommandBuffer];
        slot.rasterPass = captured;
        slot.rasterTail = tail;
    } else {
        [slot.buffer endCommandBuffer];
    }
    slot.buffer = buffer;
    slot.inRaster = YES;
    [slot.rasters addObject:buffer];
    [buffer beginCommandBufferWithAllocator:slot.allocator];
    [buffer useResidencySet:slot.residency];
    MTL4RenderEncoderOptions options = MTL4RenderEncoderOptionSuspending;
    if (slot.sealedRasters)
        options |= MTL4RenderEncoderOptionResuming;
    return [buffer renderCommandEncoderWithDescriptor:slot.rasterPass
                                              options:options];
}

- (BOOL)batchNeedsSubmit
{
    if (!_batch)
        return NO;
    if (_batch.sealedCount == NV2AMetalCommandBatchLimit)
        return YES;
    if (!_batch.hasBudgetBaseline)
        return NO;
    NSUInteger bytes = _batch.resourceBytes > _batch.baselineResourceBytes ?
                           _batch.resourceBytes - _batch.baselineResourceBytes :
                           0;
    uint64_t allocated = [_batch.allocator allocatedSize];
    uint64_t extra = allocated > _batch.baselineAllocatorBytes ?
                         allocated - _batch.baselineAllocatorBytes :
                         0;
    return bytes >= NV2AMetalCommandBatchExtraBytes ||
           extra >= NV2AMetalCommandBatchExtraBytes - bytes;
}

- (BOOL)sealWithError:(NSError **)error
{
    if (!_current || _current.drawable)
        return command_error(
            error, @"Only an open non-presenting section can be sealed");
    [_current.buffer endCommandBuffer];
    _current.sealedCount++;
    _current.sealedRasters += _current.inRaster;
    _current.sealedObjects = _current.objects.count;
    _current.sealedResources = _current.resources.count;
    _current.sealedResourceBytes = _current.resourceBytes;
    [_current.sectionRoots removeAllObjects];
    _current.sealedWaits = _current.waits.count;
    [_current.sectionWaitCounts addObject:@(_current.sealedWaits)];
    _current.sealedUploadPage = _current.uploadPage;
    _current.sealedUploadOffset = _current.uploadOffset;
    if (!_current.hasBudgetBaseline && _current.resourceRoots.count) {
        _current.hasBudgetBaseline = YES;
        _current.baselineResourceBytes = _current.resourceBytes;
        _current.baselineAllocatorBytes = [_current.allocator allocatedSize];
    }
    _current = nil;
    return YES;
}

- (nullable id<MTLBuffer>)uploadBytes:(const void *)bytes
                               length:(NSUInteger)length
                               offset:(NSUInteger *)offset
                                error:(NSError **)error
{
    if (!_current || !bytes || !offset || !length ||
        length > _device.maxBufferLength) {
        command_error(error, @"Invalid Metal 4 upload data or recording");
        return nil;
    }
    if (length > upload_page_size || _current.uploadPage >= upload_page_limit) {
        id<MTLBuffer> buffer =
            [_device newBufferWithBytes:bytes
                                 length:length
                                options:MTLResourceStorageModeShared];
        if (!buffer) {
            command_error(error, @"Could not allocate Metal 4 upload buffer");
            return nil;
        }
        if (![self addResource:buffer error:error])
            return nil;
        *offset = 0;
        return buffer;
    }
    if (length > upload_page_size - _current.uploadOffset) {
        _current.uploadPage++;
        _current.uploadOffset = 0;
        return [self uploadBytes:bytes length:length offset:offset error:error];
    }
    if (_current.uploadPage == _current.uploadPages.count) {
        id<MTLBuffer> page =
            [_device newBufferWithLength:upload_page_size
                                 options:MTLResourceStorageModeShared];
        if (!page) {
            command_error(error, @"Could not allocate Metal 4 upload page");
            return nil;
        }
        [_current.uploadPages addObject:page];
    }
    id<MTLBuffer> page = _current.uploadPages[_current.uploadPage];
    if (!_current.uploadOffset && ![self addResource:page error:error])
        return nil;
    *offset = _current.uploadOffset;
    memcpy((char *)page.contents + *offset, bytes, length);
    _current.uploadOffset +=
        (length + upload_alignment - 1) & ~(upload_alignment - 1);
    return page;
}

- (id<MTLBuffer>)orderedTransferScratchWithLength:(NSUInteger)length
                                            error:(NSError **)error
{
    if (!_current || !length || length > _device.maxBufferLength) {
        command_error(error, @"Invalid Metal 4 transfer scratch or recording");
        return nil;
    }
    NSUInteger limit = MIN((NSUInteger)NV2AMetalCommandTransferScratchLimit,
                           _device.maxBufferLength);
    id<MTLBuffer> buffer = length <= limit ? _current.transferScratch : nil;
    if (buffer.length < length) {
        NSUInteger capacity = length;
        if (length <= limit) {
            capacity = MIN((NSUInteger)4096, limit);
            while (capacity < length) {
                if (capacity > limit / 2) {
                    capacity = length;
                    break;
                }
                capacity *= 2;
            }
        }
        buffer = [_device newBufferWithLength:capacity
                                      options:MTLResourceStorageModePrivate];
        if (!buffer) {
            command_error(error,
                          @"Could not allocate Metal 4 transfer scratch");
            return nil;
        }
        if (length <= limit && buffer.allocatedSize <= limit)
            _current.transferScratch = buffer;
    }
    return [self addResource:buffer error:error] ? buffer : nil;
}

- (BOOL)keepAlive:(id)object error:(NSError **)error
{
    if (!_current) {
        return command_error(error, @"No Metal 4 command buffer is recording");
    }
    if (!object)
        return command_error(error, @"Missing Metal 4 object to retain");
    CFMutableSetRef identities = _current.objectIdentities;
    const void *identity = (__bridge const void *)object;
    if (!CFSetContainsValue(identities, identity)) {
        [_current.objects addObject:object];
        CFSetAddValue(identities, identity);
    }
    return YES;
}

- (BOOL)presentDrawableOnSubmit:(id<CAMetalDrawable>)drawable
                          error:(NSError **)error
{
    if (!_current || _current.drawable || _batch.rasterPass) {
        return command_error(
            error, @"A drawable requires a recording without a drawable");
    }
    CAMetalLayer *layer = drawable.layer;
    id<MTLResidencySet> residency = layer.residencySet;
    if (!drawable || !drawable.texture || layer.device != _device ||
        !residency || residency.device != _device) {
        return command_error(error,
                             @"Drawable belongs to an invalid Metal layer");
    }
    if (![self addResource:drawable.texture error:error] ||
        ![self keepAlive:residency error:error] ||
        ![self keepAlive:layer error:error]) {
        return NO;
    }
    /* The layer's set includes private presentation resources as well as the
     * drawable texture. Apple owns and updates this set; never mutate it. */
    [_current.buffer useResidencySet:residency];
    _current.drawable = drawable;
    return YES;
}

/* Only dependencies introduced through this sealed cut can delay a prefix.
 * A later section's pending or failed receipt must remain entirely untouched.
 */
- (NSArray<NV2AMetalQueueWait *> *)waitsForSlot:(NV2AMetalCommandSlot *)slot
                                          count:(NSUInteger)count
                                          error:(NSError **)error
{
    NSError *failure = [slot knownFailure];
    if (failure) {
        if (error)
            *error = failure;
        return nil;
    }
    NV2AMetalQueueWait *singleEvent = nil;
    NSMapTable<id<MTLEvent>, NV2AMetalQueueWait *> *events = nil;
    for (NSUInteger i = 0; i < count; i++) {
        NV2AMetalQueueWait *wait = slot.waits[i];
        if (!wait.feedbackSucceeded) {
            NSError *errorValue = nil;
            BOOL ready = [wait.submission completedWithError:&errorValue];
            if (ready && errorValue) {
                if (error)
                    *error = errorValue;
                return nil;
            }
            wait.feedbackSucceeded = ready;
        }
        wait.needsEventWait = !wait.feedbackSucceeded;
        if (!events && singleEvent && singleEvent.event != wait.event) {
            events = [NSMapTable
                mapTableWithKeyOptions:
                    NSPointerFunctionsStrongMemory |
                    NSPointerFunctionsObjectPointerPersonality
                          valueOptions:NSPointerFunctionsStrongMemory];
            [events setObject:singleEvent forKey:singleEvent.event];
        }
        NV2AMetalQueueWait *highest =
            events ? [events objectForKey:wait.event] : singleEvent;
        if (!highest || highest.value < wait.value) {
            wait.needsEventWait |= highest.needsEventWait;
            if (events)
                [events setObject:wait forKey:wait.event];
            else
                singleEvent = wait;
        } else {
            highest.needsEventWait |= wait.needsEventWait;
        }
    }
    return events      ? events.objectEnumerator.allObjects :
           singleEvent ? @[ singleEvent ] :
                         @[];
}
- (BOOL)validateRasterContinuationWithError:(NSError **)error
{
    if (!_batch.rasterPass)
        return command_error(error, @"No pending raster continuation");
    return [self waitsForSlot:_batch count:_batch.waits.count
                        error:error] != nil;
}

- (void)enqueueWaits:(NSArray<NV2AMetalQueueWait *> *)waits
{
    if (_lastSubmission) {
        NSError *failure = nil;
        if (![_lastSubmitted completedWithError:&failure] || failure)
            [_queue waitForEvent:_submissionEvent value:_lastSubmission];
    }
    for (NV2AMetalQueueWait *wait in waits)
        if (wait.needsEventWait)
            [_queue waitForEvent:wait.event value:wait.value];
}
- (MTL4CommitOptions *)optionsForSlot:(NV2AMetalCommandSlot *)slot
                                 part:(NV2AMetalCommandPart *)part
{
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
      [slot completePart:part error:feedback.error];
    }];
    return options;
}
- (NV2AMetalSubmission *)submitProducersThroughSectionCount:(NSUInteger)count
                                                batchSerial:
                                                    (uint64_t)batchSerial
                                                      error:(NSError **)error
{
    NV2AMetalCommandSlot *slot = _batch;
    if (!slot || _current || !batchSerial || batchSerial != slot.batchSerial ||
        !count || count > slot.sealedCount) {
        command_error(error, @"Invalid sealed Metal producer prefix or batch");
        return nil;
    }
    if (count <= slot.submittedProducers) {
        for (NSUInteger i = 0; i < slot.prefixEnds.count; i++)
            if (count <= slot.prefixEnds[i].unsignedIntegerValue) {
                if (error)
                    *error = nil;
                return slot.prefixReceipts[i];
            }
        assert(false);
    }
    if (_lastSubmission == UINT64_MAX) {
        command_error(error, @"Metal 4 submission timeline is exhausted");
        return nil;
    }
    NSArray *waits = [self
        waitsForSlot:slot
               count:slot.sectionWaitCounts[count - 1].unsignedIntegerValue
               error:error];
    if (!waits)
        return nil;
    NV2AMetalSubmission *receipt =
        [[NV2AMetalSubmission alloc] initPendingWithOwner:self
                                                    event:_submissionEvent
                                                    value:_lastSubmission + 1
                                                    parts:1];
    NV2AMetalCommandPart *part = [NV2AMetalCommandPart new];
    part.producer = YES;
    part.receipt = receipt;
    MTL4CommitOptions *options = [self optionsForSlot:slot part:part];
    if (!receipt || !part || !options) {
        command_error(error, @"Cannot allocate Metal producer prefix receipt");
        return nil;
    }
    id<MTL4CommandBuffer> buffers[NV2AMetalCommandBatchLimit];
    NSUInteger pending = count - slot.submittedProducers;
    for (NSUInteger i = 0; i < pending; i++)
        buffers[i] = slot.buffers[slot.submittedProducers + i];
    [slot.residency commit];
    [slot registerPart:part];
    [self enqueueWaits:waits];
    [_queue commit:buffers count:pending options:options];
    [_queue signalEvent:_submissionEvent value:++_lastSubmission];
    slot.submittedProducers = count;
    [slot.prefixEnds addObject:@(count)];
    [slot.prefixReceipts addObject:receipt];
    _lastSubmitted = receipt;
    if (error)
        *error = nil;
    return receipt;
}
- (BOOL)submitWithError:(NSError **)error
{
    if (!_batch)
        return command_error(error, @"No Metal 4 command buffer is recording");
    NV2AMetalCommandSlot *slot = _batch;
    NSUInteger end = slot.sealedCount + (_current != nil);
    NSUInteger producers = end - slot.submittedProducers;
    NSUInteger commits = (producers != 0) + (slot.rasterPass != nil);
    if (_lastSubmission > UINT64_MAX - commits)
        return command_error(error,
                             @"Metal 4 submission timeline is exhausted");
    NSArray *waits = [self waitsForSlot:slot
                                  count:slot.waits.count
                                  error:error];
    if (!waits)
        return NO;
    /* This receipt aggregates the complete batch, including earlier partial
     * commits. Only a raster phase needs distinct producer completion; an
     * all-producer batch uses its full aggregate completion for both queries.
     */
    NV2AMetalSubmission *receipt = [[NV2AMetalSubmission alloc]
        initPendingWithOwner:self
                       event:_submissionEvent
                       value:_lastSubmission + commits
                       parts:slot.rasterPass ? 2 : 1];
    if (!receipt)
        return command_error(error,
                             @"Cannot allocate Metal submission identity");
    NV2AMetalCommandPart *producerPart =
        producers ? [NV2AMetalCommandPart new] : nil;
    producerPart.producer = YES;
    NV2AMetalCommandPart *rasterPart =
        slot.rasterPass ? [NV2AMetalCommandPart new] : nil;
    MTL4CommitOptions *producerOptions =
        producers ? [self optionsForSlot:slot part:producerPart] : nil;
    MTL4CommitOptions *rasterOptions =
        slot.rasterPass ? [self optionsForSlot:slot part:rasterPart] : nil;
    if ((producers && (!producerPart || !producerOptions)) ||
        (slot.rasterPass && (!rasterPart || !rasterOptions)))
        return command_error(error, @"Cannot allocate Metal commit feedback");
    [slot.residency commit];
    if (_current)
        [slot.buffer endCommandBuffer];
    if (producerPart)
        [slot registerPart:producerPart];
    if (rasterPart)
        [slot registerPart:rasterPart];
    if (commits) {
        [self enqueueWaits:waits];
        if (slot.drawable)
            [_queue waitForDrawable:slot.drawable];
    }
    if (producers) {
        id<MTL4CommandBuffer> buffers[NV2AMetalCommandBatchLimit];
        for (NSUInteger i = 0; i < producers; i++)
            buffers[i] = slot.buffers[slot.submittedProducers + i];
        [_queue commit:buffers count:producers options:producerOptions];
        [_queue signalEvent:_submissionEvent value:++_lastSubmission];
    }
    if (slot.rasterPass) {
        /* Preserve the complete suspended/resumed raster chain in exactly one
         * contiguous commit array. No producer head is replayed. */
        if (producers)
            [_queue waitForEvent:_submissionEvent value:_lastSubmission];
        id<MTL4CommandBuffer> rasters[NV2AMetalCommandBatchLimit + 1];
        NSUInteger rasterCount = slot.rasters.count;
        for (NSUInteger i = 0; i < rasterCount; i++)
            rasters[i] = slot.rasters[i];
        rasters[rasterCount++] = slot.rasterTail;
        [_queue commit:rasters count:rasterCount options:rasterOptions];
        [_queue signalEvent:_submissionEvent value:++_lastSubmission];
    }
    if (slot.drawable) {
        [_queue signalDrawable:slot.drawable];
        [slot.drawable present];
    }
    _lastSubmitted = receipt;
    [slot closeWithAggregate:receipt];
    _current = _batch = nil;
    _nextSlot = (_nextSlot + 1) % command_slot_count;
    return YES;
}

- (void)cancelUnsealed
{
    if (!_current)
        return;
    if (!_current.sealedCount) {
        [self cancel];
        return;
    }
    [_current.buffer endCommandBuffer];
    if (_current.inRaster) {
        [_current.rasters removeLastObject];
        if (!_current.sealedRasters) {
            _current.rasterPass = nil;
            _current.rasterTail = nil;
        }
    }
    _current.drawable = nil;
    if (!_current.submittedProducers) {
        NSRange objects =
            NSMakeRange(_current.sealedObjects,
                        _current.objects.count - _current.sealedObjects);
        for (NSUInteger i = objects.location; i < NSMaxRange(objects); i++)
            CFSetRemoveValue(_current.objectIdentities,
                             (__bridge const void *)_current.objects[i]);
        [_current.objects removeObjectsInRange:objects];
    }
    NSUInteger end = _current.waits.count;
    for (NSUInteger i = _current.sealedWaits; i < end; i++)
        [_current.waitReceipts removeObjectForKey:_current.waits[i].submission];
    [_current.waits
        removeObjectsInRange:NSMakeRange(_current.sealedWaits,
                                         end - _current.sealedWaits)];
    NSRange discarded =
        NSMakeRange(_current.sealedResources,
                    _current.resources.count - _current.sealedResources);
    if (discarded.length && !_current.submittedProducers) {
        /* Remove only discarded resource identities. A view can share the
         * sealed prefix's backing allocation and still have its own entry. */
        for (NSUInteger i = discarded.location; i < NSMaxRange(discarded);
             i++) {
            id<MTLResource> resource = _current.resources[i];
            [_current.residency removeAllocation:resource];
            [_current.registeredResources removeObject:resource];
        }
        [_current.residency commit];
        [_current.resources removeObjectsInRange:discarded];
        for (id<MTLResource> root in _current.sectionRoots)
            [_current.resourceRoots removeObject:root];
        [_current.sectionRoots removeAllObjects];
        _current.resourceBytes = _current.sealedResourceBytes;
    }
    _current.uploadPage = _current.sealedUploadPage;
    _current.uploadOffset = _current.sealedUploadOffset;
    _current = nil;
}

- (void)cancel
{
    if (!_batch)
        return;
    NV2AMetalCommandSlot *slot = _batch;
    if (_current)
        [slot.buffer endCommandBuffer];
    [slot.rasters removeAllObjects];
    slot.rasterTail = nil;
    slot.rasterPass = nil;
    slot.buffer = slot.buffers[0];
    slot.drawable = nil;
    if (!slot.submittedProducers) {
        CFSetRemoveAllValues(slot.objectIdentities);
        [slot.objects removeAllObjects];
        [slot.waits removeAllObjects];
        [slot.waitReceipts removeAllObjects];
        [slot.resources removeAllObjects];
        [slot.registeredResources removeAllObjects];
        [slot.resourceRoots removeAllObjects];
        [slot.sectionRoots removeAllObjects];
        [slot.residency removeAllAllocations];
        [slot.residency commit];
    } else {
        /* Committed heads still own this allocator generation and residency.
         * Cancel ends only the host lease; final feedback releases the slot. */
        _nextSlot = (_nextSlot + 1) % command_slot_count;
    }
    [slot closeWithAggregate:nil];
    _current = _batch = nil;
}

- (BOOL)ownsSubmission:(NV2AMetalSubmission *)submission
{
    return [submission belongsToOwner:self];
}

- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    if (!submission)
        return command_error(error, @"No Metal submission to wait for");
    return [submission waitForOwner:self error:error];
}

- (BOOL)waitForProducersOfSubmission:(NV2AMetalSubmission *)submission
                               error:(NSError **)error
{
    if (!submission)
        return command_error(error, @"No Metal submission to wait for");
    return [submission waitForProducersForOwner:self error:error];
}

- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    if (_batch) {
        return command_error(error,
                             @"Submit or cancel before waiting for Metal 4");
    }
    for (NV2AMetalCommandSlot *slot in _slots) {
        if (dispatch_semaphore_wait(
                slot.available,
                dispatch_time(DISPATCH_TIME_NOW, completion_timeout_ns))) {
            return command_error(
                error, @"Timed out waiting for Metal 4 GPU completion");
        }
        NSError *failure = slot.failure;
        /* A full drain also retires completed drawables and cached resources.
         * This is needed when closing a window without reusing its slots. */
        slot.drawable = nil;
        [slot.rasters removeAllObjects];
        slot.rasterTail = nil;
        slot.rasterPass = nil;
        slot.buffer = slot.buffers[0];
        slot.aggregate = nil;
        [slot.parts removeAllObjects];
        [slot.prefixReceipts removeAllObjects];
        [slot.prefixEnds removeAllObjects];
        CFSetRemoveAllValues(slot.objectIdentities);
        [slot.objects removeAllObjects];
        [slot.waits removeAllObjects];
        [slot.waitReceipts removeAllObjects];
        [slot.resources removeAllObjects];
        [slot.registeredResources removeAllObjects];
        [slot.resourceRoots removeAllObjects];
        [slot.sectionRoots removeAllObjects];
        [slot.residency removeAllAllocations];
        [slot.residency commit];
        dispatch_semaphore_signal(slot.available);
        if (failure) {
            if (error) {
                *error = failure;
            }
            return NO;
        }
    }
    return YES;
}

- (void)dealloc
{
    [self cancel];
}

@end
