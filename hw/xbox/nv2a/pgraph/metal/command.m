/*
 * NV2A Metal 4 command submission
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "command.h"
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
- (BOOL)belongsToOwner:(NV2AMetalCommands *)owner;
@end
@implementation NV2AMetalSubmission {
    BOOL _completed;
    NSError *_error;
    __weak NV2AMetalCommands *_owner;
    dispatch_group_t _completion;
    NSUInteger _parts;
}
- (instancetype)initPendingWithOwner:(NV2AMetalCommands *)owner
                               event:(id<MTLEvent>)event
                               value:(uint64_t)value
                               parts:(NSUInteger)parts
{
    self = [super init];
    if (self) {
        _owner = owner;
        _signalEvent = event;
        _signalValue = value;
        _parts = parts;
        _completion = dispatch_group_create();
        dispatch_group_enter(_completion);
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
        _completed = YES;
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
- (BOOL)completedWithError:(NSError **)error
{
    @synchronized(self) {
        if (error)
            *error = _completed ? _error : nil;
        return _completed;
    }
}
@end

@interface NV2AMetalQueueWait : NSObject
@property(nonatomic) NV2AMetalSubmission *submission;
@property(nonatomic) id<MTL4CommandQueue> queue;
@property(nonatomic) id<MTLEvent> event;
@property(nonatomic) uint64_t value;
@end
@implementation NV2AMetalQueueWait
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
@property(nonatomic) NSMutableArray<NV2AMetalQueueWait *> *waits;
@property(nonatomic, strong) NSMutableArray<id<MTLResource>> *resources;
@property(nonatomic, strong) NSHashTable<id<MTLResource>> *resourceRoots;
@property(nonatomic) NSUInteger resourceBytes, baselineResourceBytes;
@property(nonatomic) uint64_t baselineAllocatorBytes;
@property(nonatomic) BOOL hasBudgetBaseline;
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *uploadPages;
@property(nonatomic) NSUInteger uploadPage, uploadOffset;
@property(nonatomic) NSUInteger sealedCount, sealedObjects, sealedResources,
    sealedUploadPage, sealedUploadOffset, sealedWaits;
@property(nonatomic, strong) dispatch_semaphore_t available;
@property(nonatomic, strong, nullable) NSError *failure;
@property(nonatomic, strong, nullable) id<CAMetalDrawable> drawable;
@end

@implementation NV2AMetalCommandSlot
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

static void track_allocation(NSHashTable<id<MTLResource>> *roots,
                             id<MTLResource> resource, NSUInteger *total)
{
    if ([roots containsObject:resource])
        return;
    id<MTLResource> root = allocation_root(resource);
    if ([roots containsObject:root])
        return;
    [roots addObject:root];
    NSUInteger bytes = root.allocatedSize;
    *total = bytes > NSUIntegerMax - *total ? NSUIntegerMax : *total + bytes;
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
        slot.resources = [NSMutableArray array];
        slot.resourceRoots = [NSHashTable
            hashTableWithOptions:NSPointerFunctionsStrongMemory |
                                 NSPointerFunctionsObjectPointerPersonality];
        slot.buffers = [NSMutableArray arrayWithObject:slot.buffer];
        slot.rasters = [NSMutableArray new];
        slot.uploadPages = [NSMutableArray array];
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
    slot.resourceBytes = slot.baselineResourceBytes = 0;
    slot.baselineAllocatorBytes = 0;
    slot.buffer = slot.buffers[0];
    slot.drawable = nil;
    [slot.objects removeAllObjects];
    [slot.waits removeAllObjects];
    [slot.resources removeAllObjects];
    [slot.resourceRoots removeAllObjects];
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
    NSUInteger bytes = _current.resourceBytes;
    track_allocation(_current.resourceRoots, resource, &bytes);
    _current.resourceBytes = bytes;
}

- (BOOL)orderAfterSubmission:(NV2AMetalSubmission *)submission
                fromCommands:(NV2AMetalCommands *)source
                       error:(NSError **)error
{
    if (!_current || !source || !submission || source.device != _device ||
        ![source ownsSubmission:submission])
        return command_error(
            error, @"Invalid Metal GPU dependency owner or recording");
    NSError *failure = nil;
    if ([submission completedWithError:&failure] && failure) {
        if (error)
            *error = failure;
        return NO;
    }
    if (source == self)
        return YES;
    if (!submission.signalEvent || !submission.signalValue)
        return command_error(error,
                             @"Metal GPU dependency has no submitted timeline");
    for (NV2AMetalQueueWait *prior in _current.waits)
        if (prior.submission == submission)
            return YES;
    NV2AMetalQueueWait *wait = [NV2AMetalQueueWait new];
    wait.submission = submission;
    wait.queue = source->_queue;
    wait.event = submission.signalEvent;
    wait.value = submission.signalValue;
    [_current.waits addObject:wait];
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
    [_current.residency addAllocation:resource];
    [_current.resources addObject:resource];
    [self trackResource:resource];
    return [self keepAlive:resource error:error];
}

- (nullable id<MTL4CommandBuffer>)commandBuffer
{
    return _current.buffer;
}

- (NSUInteger)sealedBufferCount
{
    return _batch.sealedCount;
}

- (BOOL)hasPendingRasterPass
{
    return _batch.rasterPass != nil;
}

- (BOOL)rasterPassMatches:(MTL4RenderPassDescriptor *)pass
{
    return raster_pass_matches(_batch.rasterPass ?: pass, pass);
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
    _current.sealedWaits = _current.waits.count;
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

- (BOOL)keepAlive:(id)object error:(NSError **)error
{
    if (!_current) {
        return command_error(error, @"No Metal 4 command buffer is recording");
    }
    [_current.objects addObject:object];
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
    if (![self addResource:drawable.texture error:error]) {
        return NO;
    }
    /* The layer's set includes private presentation resources as well as the
     * drawable texture. Apple owns and updates this set; never mutate it. */
    [_current.buffer useResidencySet:residency];
    [_current.objects addObject:residency];
    [_current.objects addObject:layer];
    _current.drawable = drawable;
    return YES;
}

- (BOOL)submitWithError:(NSError **)error
{
    if (!_batch) {
        return command_error(error, @"No Metal 4 command buffer is recording");
    }
    NSUInteger parts = _batch.rasterPass ? 2 : 1;
    if (_lastSubmission > UINT64_MAX - parts) {
        return command_error(error,
                             @"Metal 4 submission timeline is exhausted");
    }

    NV2AMetalCommandSlot *slot = _batch;
    NSMutableDictionary<NSValue *, NV2AMetalQueueWait *> *waits =
        slot.waits.count ? [NSMutableDictionary new] : nil;
    NSMutableSet<NSValue *> *pending =
        slot.waits.count ? [NSMutableSet new] : nil;
    for (NV2AMetalQueueWait *wait in slot.waits) {
        NSError *failure = nil;
        BOOL ready = [wait.submission completedWithError:&failure];
        if (ready && failure) {
            if (error)
                *error = failure;
            return NO;
        }
        NSValue *key = [NSValue valueWithNonretainedObject:wait.event];
        if (!ready)
            [pending addObject:key];
        if (!waits[key] || waits[key].value < wait.value)
            waits[key] = wait;
    }
    NV2AMetalSubmission *submission = [[NV2AMetalSubmission alloc]
        initPendingWithOwner:self
                       event:_submissionEvent
                       value:_lastSubmission + parts
                       parts:parts];
    if (!submission)
        return command_error(error,
                             @"Could not allocate Metal submission identity");
    [slot.residency commit];
    if (_current)
        [slot.buffer endCommandBuffer];
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    /* The feedback block owns the slot until completion, even if the renderer
     * is destroyed. This retains the allocator and every referenced resource.
     */
    MTL4CommitFeedbackHandler handler = ^(id<MTL4CommitFeedback> feedback) {
      NSError *failure = nil;
      if ([submission completePartWithError:feedback.error failure:&failure]) {
          slot.failure = failure;
          dispatch_semaphore_signal(slot.available);
      }
    };
    [options addFeedbackHandler:handler];
    MTL4CommitOptions *rasterOptions = nil;
    if (slot.rasterPass) {
        rasterOptions = [MTL4CommitOptions new];
        [rasterOptions addFeedbackHandler:handler];
    }
    id<MTL4CommandBuffer> buffers[NV2AMetalCommandBatchLimit];
    NSUInteger count = slot.sealedCount + (_current != nil);
    for (NSUInteger i = 0; i < count; i++)
        buffers[i] = slot.buffers[i];
    /* Metal 4 does not insert the implicit hazards of the legacy API. Keep
     * NV2A submissions ordered, including render-target reuse across buffers.
     * Encoders must still issue barriers for hazards within a command buffer.
     */
    if (_lastSubmission) {
        [_queue waitForEvent:_submissionEvent value:_lastSubmission];
    }
    for (NV2AMetalQueueWait *wait in waits.allValues) {
        NSValue *key = [NSValue valueWithNonretainedObject:wait.event];
        /* Skip only when every requested workload on this event is complete.
         * A later callback alone must not erase an earlier pending one. */
        if ([pending containsObject:key])
            [_queue waitForEvent:wait.event value:wait.value];
    }
    if (slot.drawable) {
        [_queue waitForDrawable:slot.drawable];
    }
    [_queue commit:buffers count:count options:options];
    [_queue signalEvent:_submissionEvent value:++_lastSubmission];
    if (slot.rasterPass) {
        /* A suspended/resumed chain must be one contiguous commit array,
         * without interleaved compute or blits. Complete every independent
         * producer first; the GPU event orders the raster-only commit. Both
         * feedback callbacks retain this slot and contribute to its receipt. */
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
    _lastSubmitted = submission;
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
    [_current.objects
        removeObjectsInRange:NSMakeRange(_current.sealedObjects,
                                         _current.objects.count -
                                             _current.sealedObjects)];
    [_current.waits removeObjectsInRange:NSMakeRange(_current.sealedWaits,
                                                     _current.waits.count -
                                                         _current.sealedWaits)];
    [_current.resources
        removeObjectsInRange:NSMakeRange(_current.sealedResources,
                                         _current.resources.count -
                                             _current.sealedResources)];
    [_current.residency removeAllAllocations];
    NSHashTable<id<MTLResource>> *roots = [NSHashTable
        hashTableWithOptions:NSPointerFunctionsStrongMemory |
                             NSPointerFunctionsObjectPointerPersonality];
    NSUInteger bytes = 0;
    for (id<MTLResource> resource in _current.resources) {
        [_current.residency addAllocation:resource];
        track_allocation(roots, resource, &bytes);
    }
    _current.resourceRoots = roots;
    _current.resourceBytes = bytes;
    [_current.residency commit];
    _current.uploadPage = _current.sealedUploadPage;
    _current.uploadOffset = _current.sealedUploadOffset;
    _current = nil;
}

- (void)cancel
{
    if (!_batch)
        return;
    if (_current)
        [_current.buffer endCommandBuffer];
    [_batch.rasters removeAllObjects];
    _batch.rasterTail = nil;
    _batch.rasterPass = nil;
    _batch.buffer = _batch.buffers[0];
    _batch.drawable = nil;
    [_batch.objects removeAllObjects];
    [_batch.waits removeAllObjects];
    [_batch.resources removeAllObjects];
    [_batch.resourceRoots removeAllObjects];
    [_batch.residency removeAllAllocations];
    [_batch.residency commit];
    dispatch_semaphore_signal(_batch.available);
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
        [slot.objects removeAllObjects];
        [slot.waits removeAllObjects];
        [slot.resources removeAllObjects];
        [slot.resourceRoots removeAllObjects];
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
