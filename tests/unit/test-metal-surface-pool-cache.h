/* Cache-local surface storage reuse through cancellation, RTT and Restore.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SURFACE_POOL_CACHE_H
#define TEST_METAL_SURFACE_POOL_CACHE_H
#include "test-metal-surface-pool.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-cache.h"
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
@interface SurfacePoolCacheCommands : NV2AMetalCommands
@property(nonatomic) BOOL rejectSubmit, rejectTransferPin;
@property(nonatomic) unsigned idleWaits, transferPins;
@property(nonatomic, copy) void (^beforeIdle)(void);
@end
@implementation SurfacePoolCacheCommands
- (BOOL)keepAlive:(id)object error:(NSError **)error
{
    if ([object isKindOfClass:NV2AMetalSurfaceTransfer.class]) {
        _transferPins++;
        if (_rejectTransferPin) {
            if (error)
                *error = [NSError errorWithDomain:@"test.surface-pool.pin"
                                             code:1
                                         userInfo:nil];
            return NO;
        }
    }
    return [super keepAlive:object error:error];
}
- (BOOL)submitWithError:(NSError **)error
{
    if (_rejectSubmit) {
        if (error)
            *error = [NSError errorWithDomain:@"test.surface-pool.submit"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return [super submitWithError:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    _idleWaits++;
    void (^before)(void) = _beforeIdle;
    _beforeIdle = nil;
    if (before)
        before();
    return [super waitUntilIdleWithError:error];
}
@end
static _Thread_local BOOL spc_fail_pool_init;
@interface NV2AMetalSurfaceTexturePool (SurfacePoolCacheInitHook)
- (instancetype)spc_initWithDevice:(id<MTLDevice>)device
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalSurfaceTexturePool (SurfacePoolCacheInitHook)
- (instancetype)spc_initWithDevice:(id<MTLDevice>)device
{
    self = [self spc_initWithDevice:device];
    if (self && spc_fail_pool_init) {
        spc_fail_pool_init = NO;
        return nil;
    }
    return self;
}
@end
static _Thread_local BOOL spc_observe;
static _Thread_local unsigned spc_public_getters;
static id (*spc_texture_original)(id, SEL);
static id spc_texture(id transfer, SEL selector)
{
    if (spc_observe)
        spc_public_getters++;
    return spc_texture_original(transfer, selector);
}
static NV2AMetalSurfaceCache *spc_cache(id<MTLDevice> device, BOOL reference,
                                        SurfacePoolCacheCommands **commands,
                                        NV2AMetalSurfaceTexturePool **pool)
{
    NSError *error = nil;
    *commands = [[SurfacePoolCacheCommands alloc] initWithDevice:device
                                                           error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(*commands && ram, error);
    memset(ram.contents, 0x37, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:*commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    *pool = [[NV2AMetalSurfaceTexturePool alloc]
        initWithDevice:device
          maximumBytes:reference ? 0 : 8 * 1024 * 1024
          maximumCount:8];
    require(cache && *pool, error);
    [cache setValue:*pool forKey:@"texturePool"];
    cache.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
      assert(address < 65536 && length && length <= 65536 - address);
    };
    return cache;
}
static void spc_store(NV2AMetalSurfaceCache *cache, NV2AMetalSurfaceConfig c,
                      unsigned seed)
{
    NSError *error = nil;
    id<MTLBuffer> bytes = sp_ram(cache.commands.device, c, seed);
    require([cache prepareCPUAccessAtAddress:128
                                      length:bytes.length
                                       write:YES
                                       error:&error],
            error);
    memcpy((uint8_t *)cache.vram.contents + 128, bytes.contents, bytes.length);
}
static NV2AMetalCachedSurface *spc_prepare(NV2AMetalSurfaceCache *cache,
                                           NV2AMetalSurfaceConfig c)
{
    NSError *error = nil;
    NV2AMetalSurfaceLayout layout;
    assert(nv2a_metal_surface_layout(&c, &layout, NULL));
    sp_width = c.width * c.scale;
    sp_height = c.height * c.scale;
    sp_format = layout.pixel_format;
    sp_allocating = YES;
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:128
                                                              config:&c
                                                               frame:0
                                                        forRendering:NO
                                                               error:&error];
    sp_allocating = NO;
    require(surface != nil, error);
    return surface;
}
static id<MTLBuffer> spc_output(NV2AMetalCachedSurface *surface,
                                NV2AMetalSurfaceCache *cache)
{
    NSError *error = nil;
    NV2AMetalSurfaceLayout layout;
    NV2AMetalSurfaceConfig c = surface.transfer.config;
    assert(nv2a_metal_surface_layout(&c, &layout, NULL));
    id<MTLBuffer> output = [cache.commands.device
        newBufferWithLength:layout.reservation_length
                    options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0xcd, output.length);
    require([surface.transfer encodeDownloadToBuffer:output
                                              offset:0
                                             swizzle:NO
                                                flip:NO
                                           downscale:YES
                                            commands:cache.commands
                                               error:&error],
            error);
    return output;
}
static void spc_clear(NV2AMetalCachedSurface *surface,
                      NV2AMetalSurfaceCache *cache)
{
    NSError *error = nil;
    require([cache prepareSelectedSurface:surface
                       discardingContents:YES
                                    error:&error],
            error);
    NV2AMetalClear *clear =
        [[NV2AMetalClear alloc] initWithDevice:cache.commands.device
                                         error:&error];
    NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                               .rect = { 0, 0, surface.transfer.nativeWidth,
                                         surface.transfer.nativeHeight } };
    c.uniforms.color[1] = c.uniforms.color[3] = 1;
    id<MTLTexture> texture = [surface.transfer textureForCommands:cache.commands
                                                            error:&error];
    require(clear && texture &&
                [clear encodeColor:texture
                              zeta:nil
                            config:&c
                          commands:cache.commands
                             error:&error] &&
                [cache markWritten:surface replacingContents:YES error:&error],
            error);
}
static void spc_green(id<MTLBuffer> output, NV2AMetalSurfaceConfig c)
{
    const uint8_t *bytes = output.contents;
    for (unsigned y = 0; y < c.height; y++) {
        for (unsigned x = 0; x < c.width; x++) {
            uint32_t word;
            memcpy(&word, bytes + y * c.pitch + x * 4, 4);
            assert(word == UINT32_C(0xff00ff00));
        }
        for (unsigned b = c.width * 4; b < c.pitch; b++)
            assert(bytes[y * c.pitch + b] == 0xcd);
    }
}
static NSData *spc_cycles(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    SurfacePoolCacheCommands *commands;
    NV2AMetalSurfaceTexturePool *pool;
    NV2AMetalSurfaceCache *cache =
        spc_cache(device, reference, &commands, &pool);
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(probe != nil, error);
    NV2AMetalSurfaceConfig c = sp_config();
    NSMutableData *result = [NSMutableData new];
    sp_allocations = 0;
    uint64_t first = 0;
    for (unsigned pass = 0; pass < 2; pass++) {
        __weak NV2AMetalSurfaceTransfer *weakTransfer;
        @autoreleasepool {
            spc_store(cache, c, 20 + 70 * pass);
            NV2AMetalCachedSurface *surface = spc_prepare(cache, c);
            weakTransfer = surface.transfer;
            uint64_t identity = sp_identity(surface.transfer, probe, NULL);
            if (!pass)
                first = identity;
            else if (!reference)
                assert(identity == first);
            id<MTLBuffer> fresh = spc_output(surface, cache);
            require([cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            id<MTLBuffer> expected = sp_ram(device, c, 20 + 70 * pass);
            assert(!memcmp(fresh.contents, expected.contents, fresh.length));
            [result appendBytes:fresh.contents length:fresh.length];
            spc_clear(surface, cache);
            id<MTLBuffer> cleared = spc_output(surface, cache);
            require([cache flushWithError:&error], error);
            spc_green(cleared, c);
            assert(!surface.valid && !cache.count);
            [result appendBytes:cache.vram.contents length:cache.vram.length];
        }
        assert(!weakTransfer);
    }
    assert(sp_allocations == (reference ? 2 : 1) && commands.transferPins);
    return result;
}
static NSData *spc_cancel_retry(id<MTLDevice> device, BOOL reference,
                                BOOL failSubmit)
{
    NSError *error = nil;
    SurfacePoolCacheCommands *commands;
    NV2AMetalSurfaceTexturePool *pool;
    NV2AMetalSurfaceCache *cache =
        spc_cache(device, reference, &commands, &pool);
    NV2AMetalSurfaceConfig c = sp_config();
    spc_store(cache, c, 31);
    NSData *ram = [NSData dataWithBytes:cache.vram.contents
                                 length:cache.vram.length];
    id<MTLBuffer> output;
    NV2AMetalSurfaceRecording *token;
    __weak NV2AMetalSurfaceTransfer *weakTransfer;
    @autoreleasepool {
        NV2AMetalCachedSurface *surface = spc_prepare(cache, c);
        weakTransfer = surface.transfer;
        spc_clear(surface, cache);
        output = spc_output(surface, cache);
        token = cache.recording;
        if (failSubmit) {
            commands.rejectSubmit = YES;
            error = nil;
            assert(![cache submitWithError:&error] && error &&
                   [error.domain isEqual:@"test.surface-pool.submit"]);
            commands.rejectSubmit = NO;
            assert(cache.recording == token && !token.cancelled &&
                   !token.submitted);
        }
        [cache cancel];
        require([cache discardForRestoreWithError:&error], error);
    }
    assert(!weakTransfer && token.cancelled && !token.submitted &&
           !memcmp(cache.vram.contents, ram.bytes, ram.length));
    const uint8_t *sentinel = output.contents;
    for (NSUInteger i = 0; i < output.length; i++)
        assert(sentinel[i] == 0xcd);
    spc_store(cache, c, 103);
    NV2AMetalCachedSurface *retry = spc_prepare(cache, c);
    id<MTLBuffer> fresh = spc_output(retry, cache);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    id<MTLBuffer> expected = sp_ram(device, c, 103);
    assert(!memcmp(fresh.contents, expected.contents, fresh.length));
    return [NSData dataWithBytes:fresh.contents length:fresh.length];
}
static NSData *spc_restore_gate(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    SurfacePoolCacheCommands *commands;
    NV2AMetalSurfaceTexturePool *pool;
    NV2AMetalSurfaceCache *cache =
        spc_cache(device, reference, &commands, &pool);
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(probe != nil, error);
    NV2AMetalSurfaceConfig c = sp_config();
    spc_store(cache, c, 49);
    id<MTLSharedEvent> gate = [device newSharedEvent];
    require(gate != nil, error);
    id<MTLBuffer> output;
    NV2AMetalSubmission *receipt;
    __weak NV2AMetalSurfaceTransfer *weakTransfer;
    uint64_t oldIdentity;
    @autoreleasepool {
        NV2AMetalCachedSurface *surface = spc_prepare(cache, c);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        weakTransfer = surface.transfer;
        oldIdentity = sp_identity(surface.transfer, probe, NULL);
        [sp_queue(commands) waitForEvent:gate value:1];
        spc_clear(surface, cache);
        output = spc_output(surface, cache);
        require([cache submitWithError:&error], error);
        receipt = commands.lastSubmitted;
        assert(receipt && !gate.signaledValue);
    }
    __block BOOL inspected = NO;
    commands.beforeIdle = ^{
      assert(!inspected && !gate.signaledValue && weakTransfer);
      inspected = YES;
      NSError *failure = nil;
      assert(![receipt completedWithError:&failure] && !failure);
      const uint8_t *sentinel = output.contents;
      for (NSUInteger i = 0; i < output.length; i++)
          assert(sentinel[i] == 0xcd);
      uint64_t freshIdentity;
      @autoreleasepool {
          NV2AMetalSurfaceTransfer *fresh =
              sp_create(device, pool, c, &failure);
          require(fresh != nil, failure);
          freshIdentity = sp_identity(fresh, probe, NULL);
          (void)sp_roundtrip(fresh, probe, 119);
      }
      assert(!gate.signaledValue && ![receipt completedWithError:&failure] &&
             !failure && weakTransfer);
      for (NSUInteger i = 0; i < output.length; i++)
          assert(sentinel[i] == 0xcd);
      assert(freshIdentity != oldIdentity);
      gate.signaledValue = 1;
    };
    unsigned waits = commands.idleWaits;
    /* Restore invokes the actual full Commands drain, including private GPU
     * uses. Release only at that real wait; no VRAM hazard is invented. */
    require([cache discardForRestoreWithError:&error], error);
    spc_green(output, c);
    assert(inspected && commands.idleWaits > waits && gate.signaledValue == 1 &&
           !weakTransfer && !cache.count);
    spc_store(cache, c, 169);
    NV2AMetalCachedSurface *fresh = spc_prepare(cache, c);
    uint64_t freshIdentity = sp_identity(fresh.transfer, probe, NULL);
    id<MTLBuffer> bytes = spc_output(fresh, cache);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    id<MTLBuffer> expected = sp_ram(device, c, 169);
    assert(!memcmp(bytes.contents, expected.contents, bytes.length));
    if (!reference)
        assert(freshIdentity == oldIdentity);
    return [NSData dataWithBytes:bytes.contents length:bytes.length];
}
static NSData *spc_rtt_prefix(id<MTLDevice> device, BOOL reference,
                              BOOL cancelTail)
{
    NSError *error = nil;
    SurfacePoolCacheCommands *commands;
    NV2AMetalSurfaceTexturePool *pool;
    NV2AMetalSurfaceCache *cache =
        spc_cache(device, reference, &commands, &pool);
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalTextureCache *textures =
        [[NV2AMetalTextureCache alloc] initWithSurfaces:cache error:&error];
    require(probe && textures, error);
    NV2AMetalSurfaceConfig c = sp_config();
    spc_store(cache, c, 67);
    NSMutableData *expected = [NSMutableData new];
    for (unsigned y = 0; y < c.height; y++)
        [expected
            appendBytes:(const uint8_t *)cache.vram.contents + 128 + y * c.pitch
                 length:c.width * 4];
    NV2AMetalCachedTexture *snapshot;
    NV2AMetalSurfaceRecording *head, *tail;
    id<MTLBuffer> tailOutput;
    uint64_t batchSerial;
    __weak NV2AMetalSurfaceTransfer *weakTransfer;
    uint64_t identity;
    @autoreleasepool {
        NV2AMetalCachedSurface *surface = spc_prepare(cache, c);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        weakTransfer = surface.transfer;
        identity = sp_identity(surface.transfer, probe, NULL);
        NV2AMetalTextureSource source = {
            .shape = { .format =
                           NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
                       .dimension = 2,
                       .width = 8,
                       .height = 4,
                       .depth = 1,
                       .levels = 1,
                       .pitch = 40 },
            .address = 128,
            .length = 160
        };
        NV2AMetalSamplerConfig sampler = { .filter = 1 << 16 | 1 << 24,
                                           .address = 3 | 3 << 8 | 3 << 16,
                                           .anisotropy = 1,
                                           .rectangle = YES };
        BOOL collected = NO;
        snapshot = [textures captureSource:&source
                                   sampler:&sampler
                                     frame:0
                         collectedFeedback:&collected
                                     error:&error];
        require(snapshot != nil, error);
        head = cache.recording;
        assert(head && snapshot.producerRecording == head);
        require([cache checkpointWithError:&error], error);
        batchSerial = commands.batchSerial;
        tailOutput = encode_vram_copy(cache, 49152, 8);
        memset(tailOutput.contents, 0xcd, tailOutput.length);
        tail = cache.recording;
        require([cache waitForProducersOfRecording:head error:&error], error);
        const uint8_t *sentinel = tailOutput.contents;
        for (NSUInteger i = 0; i < tailOutput.length; i++)
            assert(sentinel[i] == 0xcd);
        /* Prefix submission seals the open tail before committing only head.
         * No live encoder remains, but the whole unsubmitted batch is owned. */
        BOOL sealed = head.producersCompleted && !head.completed &&
                      !head.submitted && tail && !tail.submitted &&
                      !tail.completed && !tail.producersCompleted &&
                      !commands.commandBuffer && batchSerial &&
                      commands.batchSerial == batchSerial &&
                      commands.sealedBufferCount == 2;
        if (!sealed)
            fprintf(stderr,
                    "Pool RTT prefix: head=%u/%u/%u tail=%u/%u/%u buffer=%u "
                    "batch=%llu/%llu sealed=%zu\n",
                    (unsigned)head.producersCompleted, (unsigned)head.completed,
                    (unsigned)head.submitted, (unsigned)tail.producersCompleted,
                    (unsigned)tail.completed, (unsigned)tail.submitted,
                    (unsigned)(commands.commandBuffer != nil),
                    (unsigned long long)commands.batchSerial,
                    (unsigned long long)batchSerial,
                    (size_t)commands.sealedBufferCount);
        assert(sealed);
        require([cache evictBeforeFrame:6 error:&error], error);
        assert(!surface.valid && !cache.count);
    }
    BOOL held = weakTransfer != nil;
    NSData *old = sp_texture_bytes(snapshot.binding.texture, probe);
    assert([old isEqual:expected]);
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *fresh = sp_create(device, pool, c, &error);
        require(fresh != nil, error);
        uint64_t freshIdentity = sp_identity(fresh, probe, NULL);
        (void)sp_roundtrip(fresh, probe, 213);
        assert(freshIdentity != identity);
    }
    assert(held && weakTransfer && !head.completed && !tail.submitted &&
           !tail.completed && commands.batchSerial == batchSerial);
    const uint8_t *sentinel = tailOutput.contents;
    for (NSUInteger i = 0; i < tailOutput.length; i++)
        assert(sentinel[i] == 0xcd);
    if (cancelTail) {
        [cache cancel];
        require([cache discardForRestoreWithError:&error], error);
        for (NSUInteger i = 0; i < tailOutput.length; i++)
            assert(sentinel[i] == 0xcd);
        assert(tail.cancelled && !tail.submitted && !tail.completed);
    } else {
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(!memcmp(tailOutput.contents,
                       (const uint8_t *)cache.vram.contents + 49152,
                       tailOutput.length));
        assert(tail.submitted && tail.completed && head.completed);
    }
    assert(!weakTransfer && [sp_texture_bytes(snapshot.binding.texture, probe)
                                isEqual:expected]);
    return old;
}
static void spc_pin_failure(id<MTLDevice> device)
{
    NSError *error = nil;
    SurfacePoolCacheCommands *commands;
    NV2AMetalSurfaceTexturePool *pool;
    NV2AMetalSurfaceCache *cache = spc_cache(device, NO, &commands, &pool);
    NV2AMetalSurfaceConfig c = sp_config();
    spc_store(cache, c, 73);
    NV2AMetalCachedSurface *surface = [cache selectSurfaceAtAddress:128
                                                             config:&c
                                                              frame:0
                                                              error:&error];
    require(surface != nil, error);
    commands.rejectTransferPin = YES;
    assert(![cache prepareSelectedSurface:surface
                       discardingContents:NO
                                    error:&error] &&
           [error.domain isEqual:@"test.surface-pool.pin"]);
    [cache cancel];
    assert(surface.valid && surface.needsUpload && !surface.dirty);
    commands.rejectTransferPin = NO;
    require([cache prepareSelectedSurface:surface
                       discardingContents:NO
                                    error:&error],
            error);
    id<MTLBuffer> output = spc_output(surface, cache);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    id<MTLBuffer> expected = sp_ram(device, c, 73);
    assert(!memcmp(output.contents, expected.contents, output.length));
}
static void spc_missing_pool(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(commands && ram, error);
    memset(ram.contents, 0x37, ram.length);
    spc_fail_pool_init = YES;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    assert(!spc_fail_pool_init && ![cache valueForKey:@"texturePool"]);
    NV2AMetalSurfaceConfig c = sp_config();
    spc_store(cache, c, 97);
    NV2AMetalCachedSurface *surface = spc_prepare(cache, c);
    id<MTLBuffer> output = spc_output(surface, cache);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    id<MTLBuffer> expected = sp_ram(device, c, 97);
    assert(!memcmp(output.contents, expected.contents, output.length));
    puts("Surface pool cache: injected nil optional pool retains old direct "
         "allocation and exact upload/download PASS");
}
static void surface_pool_cache_tests(id<MTLDevice> device)
{
    Method original = class_getInstanceMethod(
        object_getClass(device), @selector(newTextureWithDescriptor:));
    Method replacement = class_getInstanceMethod(
        NSObject.class, @selector(sp_newTextureWithDescriptor:));
    Method getter = class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                            @selector(texture));
    Method poolInit = class_getInstanceMethod(NV2AMetalSurfaceTexturePool.class,
                                              @selector(initWithDevice:));
    Method poolHook = class_getInstanceMethod(NV2AMetalSurfaceTexturePool.class,
                                              @selector(spc_initWithDevice:));
    assert(original && replacement && getter && poolInit && poolHook);
    spc_texture_original = (void *)method_getImplementation(getter);
    method_exchangeImplementations(original, replacement);
    method_setImplementation(getter, (IMP)spc_texture);
    method_exchangeImplementations(poolInit, poolHook);
    spc_observe = YES;
    spc_public_getters = 0;
    @try {
        assert([spc_cycles(device, NO) isEqual:spc_cycles(device, YES)]);
        for (unsigned failure = 0; failure < 2; failure++)
            assert([spc_cancel_retry(device, NO, failure)
                isEqual:spc_cancel_retry(device, YES, failure)]);
        assert([spc_restore_gate(device, NO)
            isEqual:spc_restore_gate(device, YES)]);
        for (unsigned cancel = 0; cancel < 2; cancel++)
            assert([spc_rtt_prefix(device, NO, cancel)
                isEqual:spc_rtt_prefix(device, YES, cancel)]);
        spc_pin_failure(device);
        spc_missing_pool(device);
        assert(!spc_public_getters);
    } @finally {
        spc_observe = sp_allocating = spc_fail_pool_init = NO;
        method_exchangeImplementations(poolInit, poolHook);
        method_setImplementation(getter, (IMP)spc_texture_original);
        method_exchangeImplementations(original, replacement);
    }
    puts("Surface pool cache:6 exact no-pool pairs, real allocation2->1, fresh "
         "RAM/clear/download, RTT-prefix+tailcancel, submitted Restore and "
         "failed pin/submit retry PASS");
}
#endif
