/* Slot-private transfer scratch versus dedicated buffers; no app or VM.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TRANSFER_SCRATCH_H
#define TEST_METAL_TRANSFER_SCRATCH_H
typedef id<MTLBuffer> (*ScratchBufferFactory)(
    id, SEL, NSUInteger, MTLResourceOptions) NS_RETURNS_RETAINED;
static ScratchBufferFactory scratch_original_buffer;
static _Thread_local BOOL scratch_watch, scratch_fail;
static _Thread_local NSUInteger scratch_allocations, scratch_allocated_bytes;
static id<MTLBuffer>
scratch_buffer(id object, SEL selector, NSUInteger length,
               MTLResourceOptions options) NS_RETURNS_RETAINED;
static id<MTLBuffer> scratch_buffer(id object, SEL selector, NSUInteger length,
                                    MTLResourceOptions options)
{
    BOOL watched = scratch_watch && (options & MTLResourceStorageModeMask) ==
                                        MTLResourceStorageModePrivate;
    if (watched) {
        scratch_allocations++;
        if (scratch_fail)
            return nil;
    }
    id<MTLBuffer> buffer =
        scratch_original_buffer(object, selector, length, options);
    if (watched)
        scratch_allocated_bytes += buffer.allocatedSize;
    return buffer;
}

@interface TransferScratchCommands : NV2AMetalCommands
@property(nonatomic) BOOL dedicated, poison, failAllocation, failRegistration;
@property(nonatomic) BOOL insideScratch;
@property(nonatomic) NSUInteger requests, allocations, allocatedBytes;
@end
@implementation TransferScratchCommands
- (BOOL)addResource:(id<MTLResource>)resource error:(NSError **)error
{
    if (_insideScratch && _failRegistration) {
        if (error)
            *error = [NSError errorWithDomain:@"test.transfer-scratch"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return [super addResource:resource error:error];
}
- (id<MTLBuffer>)orderedTransferScratchWithLength:(NSUInteger)length
                                            error:(NSError **)error
{
    NSUInteger before = scratch_allocations, bytes = scratch_allocated_bytes;
    _requests++;
    id<MTLBuffer> buffer;
    scratch_watch = _insideScratch = YES;
    scratch_fail = _failAllocation;
    @try {
        if (_dedicated) {
            buffer =
                [self.device newBufferWithLength:length
                                         options:MTLResourceStorageModePrivate];
            if (buffer && ![self addResource:buffer error:error])
                buffer = nil;
        } else {
            buffer = [super orderedTransferScratchWithLength:length
                                                       error:error];
        }
    } @finally {
        scratch_watch = scratch_fail = _insideScratch = NO;
        _allocations += scratch_allocations - before;
        _allocatedBytes += scratch_allocated_bytes - bytes;
    }
    if (buffer && _poison) {
        NSMutableData *data = [NSMutableData dataWithLength:buffer.length];
        memset(data.mutableBytes, 0xa5, data.length);
        id<MTLBuffer> source =
            [self.device newBufferWithBytes:data.bytes
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
        if (!source || ![self addResource:source error:error])
            return nil;
        id<MTL4ComputeCommandEncoder> e =
            [self.commandBuffer computeCommandEncoder];
        assert(e);
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e copyFromBuffer:source
                 sourceOffset:0
                     toBuffer:buffer
            destinationOffset:0
                         size:buffer.length];
        [e barrierAfterStages:MTLStageBlit
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
    }
    return buffer;
}
@end

static id scratch_slot(NV2AMetalCommands *owner)
{
    return [owner valueForKey:@"current"];
}
static NSUInteger scratch_cached_bytes(NV2AMetalCommands *owner)
{
    NSUInteger total = 0;
    for (id slot in [owner valueForKey:@"slots"]) {
        id<MTLBuffer> buffer = [slot valueForKey:@"transferScratch"];
        assert(buffer.allocatedSize <= NV2AMetalCommandTransferScratchLimit);
        total += buffer.allocatedSize;
    }
    assert(total <= 3u * NV2AMetalCommandTransferScratchLimit);
    return total;
}
static void scratch_api_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    TransferScratchCommands *owner =
        [[TransferScratchCommands alloc] initWithDevice:device error:&error];
    require(owner != nil, error);
    assert(![owner orderedTransferScratchWithLength:1 error:&error] && error);
    require([owner beginWithError:&error] != nil, error);
    error = nil;
    assert(![owner orderedTransferScratchWithLength:0 error:&error] && error);
    error = nil;
    assert(![owner orderedTransferScratchWithLength:NSUIntegerMax
                                              error:&error] &&
           error);
    owner.failAllocation = YES;
    error = nil;
    assert(![owner orderedTransferScratchWithLength:512 error:&error] && error);
    assert(![scratch_slot(owner) valueForKey:@"transferScratch"]);
    owner.failAllocation = NO;
    id<MTLBuffer> a = [owner orderedTransferScratchWithLength:512 error:&error];
    assert(a && a.storageMode == MTLStorageModePrivate && a.length >= 512);
    assert([owner orderedTransferScratchWithLength:64 error:&error] == a);
    id<MTLBuffer> b = [owner orderedTransferScratchWithLength:8193
                                                        error:&error];
    assert(b && b != a && b.length >= 8193);
    NSArray *retained = [scratch_slot(owner) valueForKey:@"resources"];
    assert([retained containsObject:a] && [retained containsObject:b]);
    [owner cancel];
    require([owner beginWithError:&error] != nil, error);
    assert([owner orderedTransferScratchWithLength:8193 error:&error] == b);
    require([owner sealWithError:&error], error);
    require([owner beginWithError:&error] != nil, error);
    owner.failRegistration = YES;
    error = nil;
    assert(![owner orderedTransferScratchWithLength:32769 error:&error] &&
           error);
    id<MTLBuffer> grown = [scratch_slot(owner) valueForKey:@"transferScratch"];
    assert(grown && grown != b && grown.length >= 32769);
    [owner cancelUnsealed];
    owner.failRegistration = NO;
    require([owner beginWithError:&error] != nil, error);
    assert([owner orderedTransferScratchWithLength:32769
                                             error:&error] == grown);
    retained = [scratch_slot(owner) valueForKey:@"resources"];
    assert([retained containsObject:b] && [retained containsObject:grown]);
    require([owner submitWithError:&error] &&
                [owner waitUntilIdleWithError:&error],
            error);
    /* Both oversized buffers are live simultaneously, so identities cannot be
     * recycled. Neither may replace a bounded cached backing. */
    require([owner beginWithError:&error] != nil, error);
    NSUInteger over = NV2AMetalCommandTransferScratchLimit + 4096u;
    id<MTLBuffer> largeA = [owner orderedTransferScratchWithLength:over
                                                             error:&error];
    id<MTLBuffer> largeB = [owner orderedTransferScratchWithLength:over
                                                             error:&error];
    assert(largeA && largeB && largeA != largeB && largeA.length == over &&
           largeB.length == over &&
           [scratch_slot(owner) valueForKey:@"transferScratch"] == nil);
    [owner cancel];
    assert(scratch_cached_bytes(owner) <= NV2AMetalCommandTransferScratchLimit);
    puts("Transfer scratch API:invalid/zero/overflow,allocation failure/retry,"
         "growth and sealed-resource retention,cancel/re-registration,"
         "registration failure/retry,oversized standalone requests "
         "and16MiB/slot cap PASS");
}

static NSArray<NV2AMetalSurfaceTransfer *> *
scratch_surfaces(id<MTLDevice> device)
{
    NSError *error = nil;
    NSMutableArray *surfaces = [NSMutableArray new];
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
        NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        NV097_SET_SURFACE_FORMAT_ZETA_Z24S8,
        NV097_SET_SURFACE_FORMAT_ZETA_Z24S8
    };
    for (unsigned i = 0; i < 6; i++) {
        unsigned bytes = i < 4 ? 2 : 4;
        NV2AMetalSurfaceConfig c = { .format = formats[i],
                                     .width = 8,
                                     .height = 4,
                                     .pitch = 11 * bytes,
                                     .scale = i & 1 ? 3 : 2,
                                     .color = i < 2,
                                     .swizzle = !(i & 1),
                                     .floating_depth = i == 3 || i == 5 };
        NV2AMetalSurfaceTransfer *surface =
            [[NV2AMetalSurfaceTransfer alloc] initWithDevice:device
                                                      config:&c
                                                       error:&error];
        require(surface != nil, error);
        [surfaces addObject:surface];
    }
    return surfaces;
}
static NSArray *
scratch_encode_batch(TransferScratchCommands *owner,
                     NSArray<NV2AMetalSurfaceTransfer *> *surfaces,
                     unsigned salt, unsigned cancelKind)
{
    NSError *error = nil;
    NSMutableArray *results = [NSMutableArray new];
    require([owner beginWithError:&error] != nil, error);
    for (unsigned i = 0; i < 18; i++) {
        NV2AMetalSurfaceTransfer *surface = surfaces[i % 6];
        NV2AMetalSurfaceConfig c = surface.config;
        unsigned pixelBytes = i % 6 < 4 ? 2 : 4;
        NSUInteger length = surface.sourceLength;
        id<MTLBuffer> input =
            [owner.device newBufferWithLength:length + 10
                                      options:MTLResourceStorageModeShared];
        id<MTLBuffer> output =
            [owner.device newBufferWithLength:length + 16
                                      options:MTLResourceStorageModeShared];
        assert(input && output);
        memset(input.contents, 0xbd, input.length);
        memset(output.contents, 0xcd, output.length);
        NSMutableData *expected = [NSMutableData dataWithLength:output.length];
        memset(expected.mutableBytes, 0xcd, expected.length);
        for (unsigned y = 0; y < c.height; y++)
            for (unsigned x = 0; x < c.width; x++)
                for (unsigned b = 0; b < pixelBytes; b++) {
                    NSUInteger at =
                        c.swizzle ?
                            morton(x, y, c.width, c.height) * pixelBytes + b :
                            y * c.pitch + x * pixelBytes + b;
                    uint8_t value = (uint8_t)(pattern(x, y, b) + salt + i * 17);
                    ((uint8_t *)input.contents)[3 + at] = value;
                    ((uint8_t *)expected.mutableBytes)[5 + at] = value;
                }
        if (i == 6 && cancelKind == 1) {
            owner.failRegistration = YES;
            error = nil;
            assert(![surface encodeUploadFromBuffer:input
                                             offset:3
                                           commands:owner
                                              error:&error] &&
                   error);
            owner.failRegistration = NO;
            [owner cancelUnsealed];
            require([owner beginWithError:&error] != nil, error);
        } else if (i == 6 && cancelKind == 2) {
            require([surface encodeUploadFromBuffer:input
                                             offset:3
                                           commands:owner
                                              error:&error],
                    error);
            [owner cancelUnsealed];
            require([owner beginWithError:&error] != nil, error);
        }
        require([surface encodeUploadFromBuffer:input
                                         offset:3
                                       commands:owner
                                          error:&error] &&
                    [surface encodeDownloadToBuffer:output
                                             offset:5
                                            swizzle:c.swizzle
                                               flip:NO
                                          downscale:YES
                                           commands:owner
                                              error:&error],
                error);
        [results addObject:@[ output, expected ]];
        if (i == 5 || i == 11) {
            require([owner sealWithError:&error], error);
            require([owner beginWithError:&error] != nil, error);
        }
    }
    return results;
}
static void scratch_check_batch(NSArray *results)
{
    assert(results.count == 18);
    for (NSArray *pair in results) {
        id<MTLBuffer> output = pair[0];
        NSData *expected = pair[1];
        compare_bytes(output.contents, expected.bytes, expected.length);
    }
}
static void scratch_surface_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    TransferScratchCommands *owners[2] = {
        [[TransferScratchCommands alloc] initWithDevice:device error:&error],
        [[TransferScratchCommands alloc] initWithDevice:device error:&error]
    };
    require(owners[0] && owners[1], error);
    owners[1].dedicated = YES;
    NSArray *surfaces[2] = { scratch_surfaces(device),
                             scratch_surfaces(device) };
    unsigned batches = 0;
    for (unsigned variant = 0; variant < 2; variant++) {
        TransferScratchCommands *owner = owners[variant];
        owner.poison = YES;
        id<MTLSharedEvent> gate = [device newSharedEvent];
        id<MTL4CommandQueue> queue = object_getIvar(
            owner,
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue"));
        assert(gate && queue);
        [queue waitForEvent:gate value:1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!gate.signaledValue)
                             gate.signaledValue = 2;
                       });
        NSMutableArray *results = [NSMutableArray new],
                       *backings = [NSMutableArray new];
        @try {
            for (unsigned slot = 0; slot < 3; slot++) {
                [results addObject:scratch_encode_batch(
                                       owner, surfaces[variant], slot * 31, 0)];
                id<MTLBuffer> backing =
                    [scratch_slot(owner) valueForKey:@"transferScratch"];
                if (!variant) {
                    assert(backing &&
                           backing.storageMode == MTLStorageModePrivate);
                    for (id<MTLBuffer> earlier in backings)
                        assert(backing != earlier &&
                               backing.gpuAddress != earlier.gpuAddress);
                    [backings addObject:backing];
                } else
                    assert(!backing);
                require([owner submitWithError:&error], error);
                assert(![owner.lastSubmitted completedWithError:NULL] &&
                       !gate.signaledValue);
            }
            gate.signaledValue = 1;
            require([owner waitUntilIdleWithError:&error], error);
            for (NSArray *batch in results) {
                scratch_check_batch(batch);
                batches++;
            }
        } @finally {
            if (!gate.signaledValue)
                gate.signaledValue = 1;
        }
        assert(!variant ? scratch_cached_bytes(owner) > 0 :
                          !scratch_cached_bytes(owner));
        owner.poison = NO;
    }
    NSUInteger pooledAttempts = 0, dedicatedAttempts = 0;
    for (unsigned round = 0; round < 5; round++)
        for (unsigned order = 0; order < 2; order++) {
            unsigned variant = (round + order) & 1;
            TransferScratchCommands *owner = owners[variant];
            NSUInteger before = owner.allocations, requests = owner.requests;
            unsigned cancel = round == 3 ? 1 : round == 4 ? 2 : 0;
            NSArray *results = scratch_encode_batch(owner, surfaces[variant],
                                                    round * 59, cancel);
            require([owner submitWithError:&error] &&
                        [owner waitUntilIdleWithError:&error],
                    error);
            scratch_check_batch(results);
            NSUInteger allocations = owner.allocations - before;
            assert(allocations == (variant ? owner.requests - requests : 0));
            if (variant)
                dedicatedAttempts += allocations;
            else
                pooledAttempts += allocations;
            batches++;
        }
    printf(
        "Transfer scratch surfaces:%u native batches/%u exact upload-download "
        "pairs;"
        "three GPU-gated slots with separate backings,poisoned reuse,swizzle/"
        "scale2+3,R565/X1555/Z16/F16/Z24S8/F24+stencil,sealed cancellation/"
        "registration failure and retry;warm new private buffers "
        "pool/dedicated="
        "%zu/%zu,cached backing=%zu bytes PASS\n",
        batches, batches * 18, (size_t)pooledAttempts,
        (size_t)dedicatedAttempts, (size_t)scratch_cached_bytes(owners[0]));
}
static void transfer_scratch_tests(id<MTLDevice> device)
{
    Method factory = class_getInstanceMethod(
        object_getClass(device), @selector(newBufferWithLength:options:));
    assert(factory);
    scratch_original_buffer =
        (void *)method_setImplementation(factory, (IMP)scratch_buffer);
    @try {
        scratch_api_tests(device);
        scratch_surface_tests(device);
    } @finally {
        scratch_watch = scratch_fail = NO;
        method_setImplementation(factory, (IMP)scratch_original_buffer);
    }
}
#endif
