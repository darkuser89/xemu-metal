/* Surface allocation reuse, independent transfer bytes and complete GPU leases.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SURFACE_POOL_H
#define TEST_METAL_SURFACE_POOL_H
#import <objc/runtime.h>
static _Thread_local BOOL sp_allocating, sp_fail_allocation;
static _Thread_local NSUInteger sp_allocations, sp_attempts;
static _Thread_local NSUInteger sp_width, sp_height;
static _Thread_local MTLPixelFormat sp_format;
@interface NSObject (SurfacePoolDeviceSpy)
- (id<MTLTexture>)sp_newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
    __attribute__((objc_method_family(new)));
@end
@implementation NSObject (SurfacePoolDeviceSpy)
- (id<MTLTexture>)sp_newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
{
    BOOL watched = sp_allocating && descriptor.width == sp_width &&
                   descriptor.height == sp_height &&
                   descriptor.pixelFormat == sp_format &&
                   descriptor.storageMode == MTLStorageModePrivate &&
                   descriptor.usage == (MTLTextureUsageRenderTarget |
                                        MTLTextureUsageShaderRead |
                                        MTLTextureUsagePixelFormatView);
    if (watched) {
        sp_attempts++;
        if (sp_fail_allocation)
            return nil;
    }
    id<MTLTexture> texture = [self sp_newTextureWithDescriptor:descriptor];
    if (watched && texture)
        sp_allocations++;
    return texture;
}
@end
static NV2AMetalSurfaceConfig sp_config(void)
{
    return (NV2AMetalSurfaceConfig){
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 8,
        .height = 4,
        .pitch = 40,
        .scale = 1,
        .color = YES
    };
}
static uint64_t sp_resource(id<MTLTexture> texture)
{
    MTLResourceID resource = texture.gpuResourceID;
    uint64_t value;
    _Static_assert(sizeof(resource) == sizeof(value),
                   "Native resource identity");
    memcpy(&value, &resource, sizeof(value));
    assert(value);
    return value;
}
static NV2AMetalSurfaceTransfer *sp_create(id<MTLDevice> device,
                                           NV2AMetalSurfaceTexturePool *pool,
                                           NV2AMetalSurfaceConfig c,
                                           NSError **error)
{
    NV2AMetalSurfaceLayout layout;
    assert(nv2a_metal_surface_layout(&c, &layout, NULL));
    sp_width = c.width * c.scale;
    sp_height = c.height * c.scale;
    sp_format = layout.pixel_format;
    sp_allocating = YES;
    NV2AMetalSurfaceTransfer *transfer =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:device
                                                  config:&c
                                             texturePool:pool
                                                   error:error];
    sp_allocating = NO;
    return transfer;
}
static void sp_finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
}
static uint64_t sp_identity(NV2AMetalSurfaceTransfer *transfer,
                            NV2AMetalCommands *commands, NSUInteger *allocated)
{
    NSError *error = nil;
    uint64_t result;
    @autoreleasepool {
        require([commands beginWithError:&error] != nil, error);
        id<MTLTexture> texture = [transfer textureForCommands:commands
                                                        error:&error];
        require(texture != nil, error);
        result = sp_resource(texture);
        if (allocated)
            *allocated = texture.allocatedSize;
        [commands cancel];
    }
    return result;
}
static id<MTLBuffer> sp_ram(id<MTLDevice> device, NV2AMetalSurfaceConfig c,
                            unsigned seed)
{
    NV2AMetalSurfaceLayout layout;
    assert(nv2a_metal_surface_layout(&c, &layout, NULL) && !c.swizzle);
    id<MTLBuffer> buffer =
        [device newBufferWithLength:layout.reservation_length
                            options:MTLResourceStorageModeShared];
    assert(buffer);
    memset(buffer.contents, 0xcd, buffer.length);
    uint8_t *bytes = buffer.contents;
    for (unsigned y = 0; y < c.height; y++)
        for (unsigned x = 0; x < c.width; x++)
            for (unsigned b = 0; b < layout.bytes_per_pixel; b++)
                bytes[y * c.pitch + x * layout.bytes_per_pixel + b] =
                    (seed + y * 31 + x * 17 + b * 73) & 255;
    return buffer;
}
static NSData *sp_roundtrip(NV2AMetalSurfaceTransfer *transfer,
                            NV2AMetalCommands *commands, unsigned seed)
{
    NSError *error = nil;
    id<MTLBuffer> source = sp_ram(commands.device, transfer.config, seed);
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:source.length
                                     options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0xcd, output.length);
    require([commands beginWithError:&error] != nil, error);
    require([transfer encodeUploadFromBuffer:source
                                      offset:0
                                    commands:commands
                                       error:&error] &&
                [transfer encodeDownloadToBuffer:output
                                          offset:0
                                         swizzle:NO
                                            flip:NO
                                       downscale:YES
                                        commands:commands
                                           error:&error],
            error);
    sp_finish(commands);
    assert(!memcmp(output.contents, source.contents, output.length));
    return [NSData dataWithBytes:output.contents length:output.length];
}
static NSData *sp_texture_bytes(id<MTLTexture> texture,
                                NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NSUInteger pitch = (texture.width * 4 + 255) & ~255u;
    id<MTLBuffer> buffer =
        [commands.device newBufferWithLength:pitch * texture.height
                                     options:MTLResourceStorageModeShared];
    require(buffer && [commands beginWithError:&error] &&
                [commands addResource:texture error:&error] &&
                [commands addResource:buffer error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                        toBuffer:buffer
               destinationOffset:0
          destinationBytesPerRow:pitch
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [encoder endEncoding];
    sp_finish(commands);
    NSMutableData *result = [NSMutableData new];
    for (NSUInteger y = 0; y < texture.height; y++)
        [result appendBytes:(const uint8_t *)buffer.contents + y * pitch
                     length:texture.width * 4];
    return result;
}
static id<MTL4CommandQueue> sp_queue(NV2AMetalCommands *commands)
{
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    assert(queue);
    return object_getIvar(commands, queue);
}
static NSData *sp_reuse_run(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalSurfaceTexturePool *pool = [[NV2AMetalSurfaceTexturePool alloc]
        initWithDevice:device
          maximumBytes:reference ? 0 : 8 * 1024 * 1024
          maximumCount:4];
    require(commands && pool, error);
    sp_allocations = sp_attempts = 0;
    NSMutableData *bytes = [NSMutableData new];
    uint64_t first = 0;
    for (unsigned pass = 0; pass < 3; pass++) {
        __weak NV2AMetalSurfaceTransfer *weakTransfer;
        @autoreleasepool {
            NV2AMetalSurfaceConfig c = sp_config();
            if (pass == 1) {
                /* Same native8x4 allocation, new guest pitch/scale/extent. */
                c.width = 4;
                c.height = 2;
                c.pitch = 24;
                c.scale = 2;
            }
            NV2AMetalSurfaceTransfer *transfer =
                sp_create(device, pool, c, &error);
            require(transfer != nil, error);
            weakTransfer = transfer;
            uint64_t identity = sp_identity(transfer, commands, NULL);
            if (!pass)
                first = identity;
            else if (!reference)
                assert(identity == first);
            [bytes appendData:sp_roundtrip(transfer, commands, 11 + 41 * pass)];
        }
        assert(!weakTransfer);
    }
    assert(sp_allocations == (reference ? 3 : 1) &&
           sp_attempts == sp_allocations);
    return bytes;
}
static void sp_limits(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    NV2AMetalSurfaceConfig base = sp_config();
    for (unsigned disabled = 0; disabled < 3; disabled++) {
        NV2AMetalSurfaceTexturePool *pool = [[NV2AMetalSurfaceTexturePool alloc]
            initWithDevice:device
              maximumBytes:disabled == 0 ? 0 :
                           disabled == 1 ? 8 * 1024 * 1024 :
                                           1
              maximumCount:disabled == 1 ? 0 : 8];
        sp_allocations = 0;
        for (unsigned pass = 0; pass < 2; pass++) {
            @autoreleasepool {
                NV2AMetalSurfaceTransfer *transfer =
                    sp_create(device, pool, base, &error);
                require(transfer != nil, error);
                (void)sp_identity(transfer, commands, NULL);
            }
        }
        assert(sp_allocations == 2 &&
               ![[pool valueForKey:@"freeTextures"] count] &&
               ![[pool valueForKey:@"freeBytes"] unsignedIntegerValue]);
    }
    NV2AMetalSurfaceTexturePool *pool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:device
                                               maximumBytes:8 * 1024 * 1024
                                               maximumCount:1];
    sp_allocations = 0;
    for (unsigned pass = 0; pass < 3; pass++) {
        @autoreleasepool {
            NV2AMetalSurfaceConfig c = base;
            if (pass == 1) {
                c.width = 9;
                c.pitch = 40;
            }
            NV2AMetalSurfaceTransfer *transfer =
                sp_create(device, pool, c, &error);
            require(transfer != nil, error);
            (void)sp_identity(transfer, commands, NULL);
        }
        assert([[pool valueForKey:@"freeTextures"] count] == 1);
    }
    assert(sp_allocations == 3);
    /* Exact native format differs although the guest footprint is similar. */
    @autoreleasepool {
        NV2AMetalSurfaceConfig c = base;
        c.format = NV097_SET_SURFACE_FORMAT_COLOR_LE_B8;
        c.pitch = 12;
        NV2AMetalSurfaceTransfer *transfer = sp_create(device, pool, c, &error);
        require(transfer != nil, error);
        assert(transfer.nativePixelFormat == MTLPixelFormatR8Unorm);
    }
    assert(sp_allocations == 4);
    /* Borrow rejection must not turn the public escape bit on. */
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *transfer =
            sp_create(device, pool, base, &error);
        require(transfer != nil, error);
        assert(![transfer textureForCommands:nil error:&error] && error);
        error = nil;
        assert(![transfer textureForCommands:commands error:&error] && error);
    }
    puts("Surface pool: exact extent/format misses, count eviction, zero "
         "limits, over-budget and invalid borrow guards PASS");
}
static void sp_budget_and_failure(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    NV2AMetalSurfaceConfig a = sp_config(), b = a;
    b.width = 9;
    b.pitch = 40;
    NSUInteger sizes[2] = { 0 };
    for (unsigned i = 0; i < 2; i++) {
        @autoreleasepool {
            NV2AMetalSurfaceTransfer *probe =
                [[NV2AMetalSurfaceTransfer alloc] initWithDevice:device
                                                          config:i ? &b : &a
                                                           error:&error];
            require(probe != nil, error);
            (void)sp_identity(probe, commands, &sizes[i]);
        }
    }
    assert(sizes[0] && sizes[1]);
    NSUInteger maximum = MAX(sizes[0], sizes[1]);
    NV2AMetalSurfaceTexturePool *pool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:device
                                               maximumBytes:maximum
                                               maximumCount:8];
    sp_allocations = 0;
    for (unsigned i = 0; i < 3; i++) {
        @autoreleasepool {
            NV2AMetalSurfaceTransfer *transfer =
                sp_create(device, pool, i == 1 ? b : a, &error);
            require(transfer != nil, error);
            (void)sp_identity(transfer, commands, NULL);
        }
        assert([[pool valueForKey:@"freeTextures"] count] == 1 &&
               [[pool valueForKey:@"freeBytes"] unsignedIntegerValue] <=
                   maximum);
    }
    assert(sp_allocations ==
           3); // Both fit alone; their reported sizes cannot fit together.
    pool = [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:device];
    uint64_t identity;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *transfer = sp_create(device, pool, a, &error);
        require(transfer != nil, error);
        identity = sp_identity(transfer, commands, NULL);
    }
    NSUInteger attempts = sp_attempts, allocations = sp_allocations;
    sp_fail_allocation = YES;
    error = nil;
    assert(!sp_create(device, pool, b, &error) && error);
    sp_fail_allocation = NO;
    assert(sp_attempts == attempts + 1 && sp_allocations == allocations &&
           [[pool valueForKey:@"freeTextures"] count] == 1);
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *retry = sp_create(device, pool, a, &error);
        require(retry != nil, error);
        assert(sp_identity(retry, commands, NULL) == identity);
        (void)sp_roundtrip(retry, commands, 61);
    }
    /* Identity-only host preflight. This sentinel never reaches a Metal API. */
    id<MTLDevice> foreign = (id<MTLDevice>)[NSObject new];
    NV2AMetalSurfaceTexturePool *foreignPool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:foreign];
    attempts = sp_attempts;
    error = nil;
    assert(!sp_create(device, foreignPool, a, &error) && error &&
           [error.localizedDescription
               isEqual:@"Surface texture pool belongs to a different GPU"] &&
           sp_attempts == attempts);
    puts("Surface pool: actual allocatedSize byte eviction, failed device "
         "allocation/retry and foreign-pool preflight PASS");
}
static void sp_escapes(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalSurfaceTexturePool *pool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:device];
    require(commands && pool, error);
    id<MTLTexture> raw, view;
    __weak NV2AMetalSurfaceTransfer *weakTransfer;
    NSData *expected;
    uint64_t identity;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *transfer =
            sp_create(device, pool, sp_config(), &error);
        require(transfer != nil, error);
        weakTransfer = transfer;
        (void)sp_roundtrip(transfer, commands, 7);
        raw = transfer.texture;
        view = [raw newTextureViewWithPixelFormat:raw.pixelFormat];
        require(view != nil, error);
        identity = sp_resource(raw);
        expected = sp_texture_bytes(raw, commands);
    }
    BOOL ownerReleased = weakTransfer == nil;
    NSUInteger freeAfterEscape = [[pool valueForKey:@"freeTextures"] count];
    uint64_t freshIdentities[3];
    for (unsigned pass = 0; pass < 3; pass++) {
        @autoreleasepool {
            NV2AMetalSurfaceTransfer *fresh =
                sp_create(device, pool, sp_config(), &error);
            require(fresh != nil, error);
            freshIdentities[pass] = sp_identity(fresh, commands, NULL);
            (void)sp_roundtrip(fresh, commands, 90 + pass);
        }
    }
    assert([sp_texture_bytes(raw, commands) isEqual:expected] &&
           [sp_texture_bytes(view, commands) isEqual:expected]);
    assert(ownerReleased && !freeAfterEscape);
    for (unsigned pass = 0; pass < 3; pass++)
        assert(freshIdentities[pass] != identity);
    puts("Surface pool: public texture and derived view keep exact old GPU "
         "bytes after owner release and pool reuse PASS");
}
static void sp_pending(id<MTLDevice> device, unsigned mode)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalCommands *freshCommands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalSurfaceTexturePool *pool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:device];
    require(commands && freshCommands && pool, error);
    NV2AMetalSurfaceConfig c = sp_config();
    id<MTLBuffer> source = sp_ram(device, c, 21);
    id<MTLBuffer> output =
        [device newBufferWithLength:source.length
                            options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0xcd, output.length);
    id<MTLSharedEvent> gate = [device newSharedEvent];
    require(gate != nil, error);
    __weak NV2AMetalSurfaceTransfer *weakTransfer;
    uint64_t identity;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *transfer = sp_create(device, pool, c, &error);
        require(transfer != nil, error);
        weakTransfer = transfer;
        identity = sp_identity(transfer, commands, NULL);
        /* A download-only pending use starts from established GPU contents. */
        (void)sp_roundtrip(transfer, commands, 21);
        if (mode < 2 || mode == 4)
            [sp_queue(commands) waitForEvent:gate value:1];
        require([commands beginWithError:&error] != nil, error);
        if (mode != 1)
            require([transfer encodeUploadFromBuffer:source
                                              offset:0
                                            commands:commands
                                               error:&error],
                    error);
        require([transfer encodeDownloadToBuffer:output
                                          offset:0
                                         swizzle:NO
                                            flip:NO
                                       downscale:YES
                                        commands:commands
                                           error:&error],
                error);
        if (mode < 2 || mode == 4)
            require([commands submitWithError:&error], error);
    }
    BOOL held = weakTransfer != nil;
    uint64_t freshIdentity = 0;
    if (mode == 2 || mode == 3) {
        if (mode == 2)
            [commands cancelUnsealed];
        else
            [commands cancel];
        assert(!weakTransfer);
        const uint8_t *bytes = output.contents;
        for (NSUInteger i = 0; i < output.length; i++)
            assert(bytes[i] == 0xcd);
    } else {
        if (mode == 4)
            [commands cancel];
        assert(!gate.signaledValue);
        @autoreleasepool {
            NV2AMetalSurfaceTransfer *fresh =
                sp_create(device, pool, c, &error);
            require(fresh != nil, error);
            freshIdentity = sp_identity(fresh, freshCommands, NULL);
            (void)sp_roundtrip(fresh, freshCommands, 199);
        }
        assert(!gate.signaledValue);
        gate.signaledValue = 1;
        require([commands waitUntilIdleWithError:&error], error);
        assert(!memcmp(output.contents, source.contents, output.length));
        assert(held && !weakTransfer && freshIdentity != identity);
    }
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *reused = sp_create(device, pool, c, &error);
        require(reused != nil, error);
        assert(sp_identity(reused, freshCommands, NULL) == identity);
        (void)sp_roundtrip(reused, freshCommands, 231);
    }
}
static void sp_borrow_only(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalCommands *other =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalSurfaceTexturePool *pool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:device];
    require(commands && other && pool, error);
    NV2AMetalSurfaceConfig c = sp_config();
    const NSUInteger pitch = 256;
    id<MTLBuffer> output =
        [device newBufferWithLength:pitch * c.height
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> oldRAM = sp_ram(device, c, 59);
    require(output != nil, error);
    memset(output.contents, 0xcd, output.length);
    NSMutableData *expected = [NSMutableData dataWithLength:output.length];
    memset(expected.mutableBytes, 0xcd, expected.length);
    for (unsigned y = 0; y < c.height; y++)
        memcpy((uint8_t *)expected.mutableBytes + y * pitch,
               (const uint8_t *)oldRAM.contents + y * c.pitch, c.width * 4);
    id<MTLSharedEvent> gate = [device newSharedEvent];
    require(gate != nil, error);
    __weak NV2AMetalSurfaceTransfer *weakTransfer;
    uint64_t identity;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *transfer = sp_create(device, pool, c, &error);
        require(transfer != nil, error);
        weakTransfer = transfer;
        (void)sp_roundtrip(transfer, commands, 59);
        [sp_queue(commands) waitForEvent:gate value:1];
        require([commands beginWithError:&error] != nil, error);
        id<MTLTexture> texture = [transfer textureForCommands:commands
                                                        error:&error];
        require(texture && [commands addResource:texture error:&error] &&
                    [commands addResource:output error:&error],
                error);
        identity = sp_resource(texture);
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        assert(encoder);
        [encoder barrierAfterQueueStages:MTLStageAll
                            beforeStages:MTLStageBlit
                       visibilityOptions:MTL4VisibilityOptionDevice];
        /* No Transfer encodeUpload/Download here: only the new borrow API can
         * pin this owner, while addResource holds only its raw MTLTexture. */
        [encoder copyFromTexture:texture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(c.width, c.height, 1)
                            toBuffer:output
                   destinationOffset:0
              destinationBytesPerRow:pitch
            destinationBytesPerImage:0
                             options:MTLBlitOptionNone];
        [encoder endEncoding];
        require([commands submitWithError:&error], error);
    }
    BOOL held = weakTransfer != nil;
    NV2AMetalSubmission *receipt = commands.lastSubmitted;
    NSError *pendingError = nil;
    assert(receipt && !gate.signaledValue &&
           ![receipt completedWithError:&pendingError] && !pendingError);
    const uint8_t *sentinel = output.contents;
    for (NSUInteger i = 0; i < output.length; i++)
        assert(sentinel[i] == 0xcd);
    uint64_t freshIdentity;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *fresh = sp_create(device, pool, c, &error);
        require(fresh != nil, error);
        freshIdentity = sp_identity(fresh, other, NULL);
        (void)sp_roundtrip(fresh, other, 149);
    }
    assert(!gate.signaledValue && ![receipt completedWithError:&pendingError] &&
           !pendingError);
    for (NSUInteger i = 0; i < output.length; i++)
        assert(sentinel[i] == 0xcd);
    gate.signaledValue = 1;
    require([commands waitUntilIdleWithError:&error], error);
    /* Compare actual old GPU pixels before identity/lifetime assertions so a
     * missing borrow pin is exposed as bytes changed by the other queue. */
    assert(!memcmp(output.contents, expected.bytes, output.length));
    assert(held && !weakTransfer && freshIdentity != identity);
    puts("Surface pool: standalone borrow-only gated GPU blit preserves old "
         "bytes across completed foreign-queue writes, full-feedback owner "
         "lifetime PASS");
}
static void sp_producer_only(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalCommands *other =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalSurfaceTexturePool *pool =
        [[NV2AMetalSurfaceTexturePool alloc] initWithDevice:device];
    require(commands && other && pool, error);
    NV2AMetalSurfaceConfig c = sp_config();
    id<MTLBuffer> source = sp_ram(device, c, 43);
    id<MTLBuffer> output =
        [device newBufferWithLength:source.length
                            options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0xcd, output.length);
    __weak NV2AMetalSurfaceTransfer *weakTransfer;
    uint64_t identity;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *transfer = sp_create(device, pool, c, &error);
        require(transfer != nil, error);
        weakTransfer = transfer;
        identity = sp_identity(transfer, commands, NULL);
        require([commands beginWithError:&error] &&
                    [transfer encodeUploadFromBuffer:source
                                              offset:0
                                            commands:commands
                                               error:&error] &&
                    [commands sealWithError:&error] &&
                    [commands beginWithError:&error],
                error);
        require([transfer encodeDownloadToBuffer:output
                                          offset:0
                                         swizzle:NO
                                            flip:NO
                                       downscale:YES
                                        commands:commands
                                           error:&error] &&
                    [commands sealWithError:&error],
                error);
    }
    NV2AMetalSubmission *head =
        [commands submitProducersThroughSectionCount:1
                                         batchSerial:commands.batchSerial
                                               error:&error];
    require(head && [commands waitForSubmission:head error:&error], error);
    BOOL held = weakTransfer != nil;
    const uint8_t *bytes = output.contents;
    for (NSUInteger i = 0; i < output.length; i++)
        assert(bytes[i] == 0xcd);
    uint64_t freshIdentity;
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *fresh = sp_create(device, pool, c, &error);
        require(fresh != nil, error);
        freshIdentity = sp_identity(fresh, other, NULL);
        (void)sp_roundtrip(fresh, other, 177);
    }
    sp_finish(commands);
    assert(!memcmp(output.contents, source.contents, output.length));
    assert(held && !weakTransfer && freshIdentity != identity);
    puts("Surface pool: producer-only receipt retains complete lease through "
         "unsubmitted tail, exact later download PASS");
}
static void __attribute__((unused)) surface_pool_tests(id<MTLDevice> device)
{
    Method original = class_getInstanceMethod(
        object_getClass(device), @selector(newTextureWithDescriptor:));
    Method replacement = class_getInstanceMethod(
        NSObject.class, @selector(sp_newTextureWithDescriptor:));
    assert(original && replacement);
    method_exchangeImplementations(original, replacement);
    @try {
        NSData *reference = sp_reuse_run(device, YES);
        NSData *actual = sp_reuse_run(device, NO);
        assert([actual isEqual:reference]);
        sp_limits(device);
        sp_budget_and_failure(device);
        sp_escapes(device);
        for (unsigned mode = 0; mode < 5; mode++)
            sp_pending(device, mode);
        sp_borrow_only(device);
        sp_producer_only(device);
    } @finally {
        sp_allocating = sp_fail_allocation = NO;
        method_exchangeImplementations(original, replacement);
    }
    puts("Surface pool:3 exact no-pool reference transfers, real "
         "allocations3->1 and5 upload/download/cancel GPU lease cases PASS");
}
#endif
