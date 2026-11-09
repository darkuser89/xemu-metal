/* Active target leases versus the former monotone-target slow path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TARGET_RETIREMENT_H
#define TEST_METAL_TARGET_RETIREMENT_H
#include <stdatomic.h>
@interface TargetRetirementCache : NV2AMetalSurfaceCache
@property(nonatomic) NSUInteger slowCalls;
@end
@implementation TargetRetirementCache
- (BOOL)tryIdleCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                        completed:(BOOL *)completed
                            error:(NSError **)error
{
    _slowCalls++;
    return [super tryIdleCPUAccessAtAddress:address
                                     length:length
                                      write:write
                                  completed:completed
                                      error:error];
}
@end
/* Guard prefix and existing reader-tail layout are intentionally unchanged.
 * Read-only inspection verifies lease cardinality after public byte oracles. */
static uint64_t tr_refs(NV2AMetalSurfaceCache *cache, NSUInteger page)
{
    const NV2AMetalCPUAccessGuard *g = cache.cpuAccessGuard;
    NSUInteger pages = (g->length + 4095) / 4096;
    assert(page < pages);
    const _Atomic(uint64_t) *refs = g->watched + 3 * g->words + pages;
    return atomic_load_explicit(refs + page, memory_order_acquire);
}
static TargetRetirementCache *tr_cache(id<MTLDevice> device,
                                       CacheFailureCommands **commandsOut)
{
    NSError *error = nil;
    CacheFailureCommands *commands =
        [[CacheFailureCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(commands && ram, error);
    memset(ram.contents, 0x33, ram.length);
    TargetRetirementCache *cache =
        [[TargetRetirementCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    if (commandsOut)
        *commandsOut = commands;
    return cache;
}
static NV2AMetalSurfaceConfig tr_config(void)
{
    return config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
}
static void tr_idle(NV2AMetalSurfaceCache *cache)
{
    NSError *error = nil;
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
}
/* Discard preparation keeps needsUpload until an actual complete overwrite
 * is marked replaced. The generic clear_surface helper marks an ordinary write.
 */
static void tr_clear_replacing(NV2AMetalSurfaceCache *cache,
                               NV2AMetalCachedSurface *surface)
{
    NSError *error = nil;
    id<MTLTexture> texture = [surface.transfer textureForCommands:cache.commands
                                                            error:&error];
    require(texture != nil && [cache.commands addResource:texture error:&error],
            error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
    id<MTL4RenderCommandEncoder> encoder =
        [cache.commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    require(encoder != nil, error);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([cache markWritten:surface replacingContents:YES error:&error],
            error);
}
static BOOL tr_fast(NV2AMetalSurfaceCache *cache, NSUInteger address,
                    BOOL write)
{
    return nv2a_metal_try_cpu_access(cache.cpuAccessGuard, address, 4, write);
}
static uint32_t tr_cpu(TargetRetirementCache *cache, NSUInteger address,
                       BOOL write, uint32_t value, BOOL reference)
{
    NSError *error = nil;
    /* Every address used here was a target: the old monotone target guard
     * necessarily took this exact synchronized path on every later access. */
    BOOL fast = !reference && tr_fast(cache, address, write);
    if (!fast) {
        BOOL completed = NO;
        require([cache tryIdleCPUAccessAtAddress:address
                                          length:4
                                           write:write
                                       completed:&completed
                                           error:&error],
                error);
        if (!completed)
            require([cache resolveCPUAccessAtAddress:address
                                              length:4
                                               write:write
                                               error:&error],
                    error);
    }
    uint32_t *word = (void *)((uint8_t *)cache.vram.contents + address);
    if (write)
        *word = value;
    return *word;
}
static NSData *tr_bindings(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    TargetRetirementCache *cache = tr_cache(device, NULL);
    NV2AMetalSurfaceConfig c = tr_config();
    const NSUInteger first = 4096 + 16, second = 4096 + 512;
    __block unsigned hooks = 0;
    cache.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
      assert(address == 4096 && length == 4096);
      hooks++;
    };
    NV2AMetalCachedSurface *a = [cache selectSurfaceAtAddress:first
                                                       config:&c
                                                        frame:0
                                                        error:&error];
    NV2AMetalCachedSurface *b = [cache selectSurfaceAtAddress:second
                                                       config:&c
                                                        frame:0
                                                        error:&error];
    require(a && b, error);
    assert(!tr_fast(cache, first, NO) && !tr_fast(cache, first, YES));
    require([cache prepareSurfaceAtAddress:first
                                    config:&c
                                     frame:0
                                     error:&error] != nil,
            error);
    tr_idle(cache);
    assert(!a.dirty && !a.needsUpload && !tr_fast(cache, first, NO));
    require([cache prepareSurfaceAtAddress:first
                                    config:&c
                                     frame:1
                                     error:&error] != nil,
            error);
    clear_surface(cache, a, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    assert(!tr_fast(cache, first, NO) && !tr_fast(cache, first, YES));
    uint32_t green = tr_cpu(cache, first, NO, 0, reference);
    assert(green == UINT32_C(0xff00ff00));
    assert(tr_refs(cache, 1) == 2 && hooks == 1 && !a.dirty);
    require([cache invalidateAddress:first length:1 error:&error], error);
    assert(!a.valid && b.valid && !tr_fast(cache, first, NO) &&
           tr_refs(cache, 1) == 1);
    require([cache invalidateAddress:second length:1 error:&error], error);
    uint64_t before, after, again;
    require([cache sourceVersionAtAddress:first
                                   length:4
                                  version:&before
                                    error:&error],
            error);
    uint64_t generation =
        [[cache valueForKey:@"generation"] unsignedLongLongValue];
    NSUInteger slow = cache.slowCalls;
    assert(tr_cpu(cache, first, YES, UINT32_C(0x12345678), reference) ==
           UINT32_C(0x12345678));
    assert(tr_cpu(cache, first, NO, 0, reference) == UINT32_C(0x12345678));
    require([cache sourceVersionAtAddress:first
                                   length:4
                                  version:&after
                                    error:&error] &&
                [cache sourceVersionAtAddress:first
                                       length:4
                                      version:&again
                                        error:&error],
            error);
    assert(after == generation + 1 && after > before && again == after &&
           !tr_refs(cache, 1));
    assert(cache.slowCalls - slow == (reference ? 2 : 0));
    require([cache prepareSurfaceAtAddress:first
                                    config:&c
                                     frame:2
                                     error:&error] != nil,
            error);
    NV2AMetalCachedSurface *fresh = [cache surfaceContainingAddress:first];
    id<MTLBuffer> pixels = gpu_pixels(cache, fresh);
    assert(*(uint32_t *)pixels.contents == UINT32_C(0x12345678));
    assert(hooks == 1 && !tr_fast(cache, first, NO));
    require([cache discardForRestoreWithError:&error], error);
    assert(!tr_refs(cache, 1) && tr_fast(cache, first, NO));
    return [NSData dataWithBytes:cache.vram.contents length:cache.vram.length];
}
static void tr_tokens(id<MTLDevice> device, BOOL samePage)
{
    NSError *error = nil;
    CacheFailureCommands *commands;
    TargetRetirementCache *cache = tr_cache(device, &commands);
    const NSUInteger headAddress = 16384,
                     tailAddress = samePage ? 16392 : 20480;
    gpu_dep_write(cache, headAddress, UINT64_C(0x1122334455667788));
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error], error);
    gpu_dep_write(cache, tailAddress, UINT64_C(0x8877665544332211));
    NV2AMetalSurfaceRecording *tail = cache.recording;
    require([cache checkpointWithError:&error], error);
    require([cache waitForProducersOfRecording:head error:&error], error);
    uint64_t bytes;
    memcpy(&bytes, (uint8_t *)cache.vram.contents + headAddress, 8);
    assert(bytes == UINT64_C(0x1122334455667788));
    assert(head.producersCompleted && !head.completed &&
           !head.cpuHazardsRetired && !tail.submitted &&
           !tr_fast(cache, headAddress, NO));
    assert(tr_refs(cache, 4) == (samePage ? 2 : 1));
    /* Only a proven CPU-hazard retirement may release the producer lease. */
    require([cache resolveCPUAccessAtAddress:headAddress
                                      length:8
                                       write:NO
                                       error:&error],
            error);
    assert(head.cpuHazardsRetired && !tail.submitted &&
           tr_refs(cache, 4) == (samePage ? 1 : 0));
    assert(tr_fast(cache, headAddress, NO) == !samePage);
    id<MTLSharedEvent> gate = [device newSharedEvent];
    id<MTL4CommandQueue> queue = object_getIvar(
        commands, class_getInstanceVariable(NV2AMetalCommands.class, "_queue"));
    assert(gate && queue);
    [queue waitForEvent:gate value:1];
    require([cache submitWithError:&error], error);
    NV2AMetalSubmission *receipt = commands.lastSubmitted;
    memcpy(&bytes, (uint8_t *)cache.vram.contents + tailAddress, 8);
    assert(bytes == UINT64_C(0x3333333333333333));
    assert(![receipt completedWithError:NULL] &&
           !tr_fast(cache, tailAddress, NO) &&
           !tr_fast(cache, tailAddress, YES));
    [cache cancel];
    assert(!tr_fast(cache, tailAddress, NO));
    gate.signaledValue = 1;
    require([cache waitUntilIdleWithError:&error], error);
    memcpy(&bytes, (uint8_t *)cache.vram.contents + tailAddress, 8);
    assert(bytes == UINT64_C(0x8877665544332211));
    assert(tail.completed && !tr_refs(cache, 4) && !tr_refs(cache, 5) &&
           tr_fast(cache, headAddress, NO) && tr_fast(cache, tailAddress, NO));
    require([cache discardForRestoreWithError:&error], error);
}
static void tr_download(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands;
    TargetRetirementCache *cache = tr_cache(device, &commands);
    NV2AMetalSurfaceConfig c = tr_config();
    const NSUInteger address = 8192 - 16;
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:address
                                                              config:&c
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    require([cache prepareGPUReadAtAddress:address length:16 error:&error],
            error);
    NV2AMetalSurfaceRecording *token = cache.recording;
    id<MTLSharedEvent> gate = [device newSharedEvent];
    id<MTL4CommandQueue> queue = object_getIvar(
        commands, class_getInstanceVariable(NV2AMetalCommands.class, "_queue"));
    assert(gate && queue);
    [queue waitForEvent:gate value:1];
    assert(!tr_fast(cache, address, NO) && !tr_fast(cache, address + 16, NO));
    require([cache submitWithError:&error], error);
    NV2AMetalSubmission *receipt = commands.lastSubmitted;
    assert(![receipt completedWithError:NULL] &&
           *(uint32_t *)((uint8_t *)cache.vram.contents + address) ==
               UINT32_C(0x33333333));
    gate.signaledValue = 1;
    require([commands waitForSubmission:receipt error:&error], error);
    check_region(cache.vram, address, c, UINT32_C(0xffff0000), 0x33);
    /* GPU feedback alone does not mutate the PGRAPH-owned guard counts. */
    assert(!token.completed && tr_refs(cache, 1) == 2 &&
           tr_refs(cache, 2) == 2 && !tr_fast(cache, address, NO));
    require([cache collectCompletedWithError:&error], error);
    assert(token.completed && tr_refs(cache, 1) == 1 &&
           tr_refs(cache, 2) == 1 && !tr_fast(cache, address, NO));
    require([cache invalidateAddress:address length:1 error:&error], error);
    assert(!surface.valid && !tr_refs(cache, 1) && !tr_refs(cache, 2) &&
           tr_fast(cache, address, NO) && tr_fast(cache, address + 16, NO));
    require([cache discardForRestoreWithError:&error], error);
}
static void tr_reader_after_retirement(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands;
    TargetRetirementCache *cache = tr_cache(device, &commands);
    NV2AMetalSurfaceConfig c = tr_config();
    const NSUInteger address = 24576;
    NV2AMetalCachedSurface *surface = [cache selectSurfaceAtAddress:address
                                                             config:&c
                                                              frame:0
                                                              error:&error];
    require(surface != nil && [cache invalidateAddress:address
                                                length:1
                                                 error:&error],
            error);
    id<MTLBuffer> copied = encode_vram_copy(cache, address, 8);
    id<MTLSharedEvent> gate = [device newSharedEvent];
    id<MTL4CommandQueue> queue = object_getIvar(
        commands, class_getInstanceVariable(NV2AMetalCommands.class, "_queue"));
    assert(gate && queue);
    [queue waitForEvent:gate value:1];
    require([cache submitWithError:&error], error);
    assert(![commands.lastSubmitted completedWithError:NULL] &&
           tr_fast(cache, address, NO) && !tr_fast(cache, address, YES) &&
           !tr_refs(cache, address / 4096));
    gate.signaledValue = 1;
    require([cache waitUntilIdleWithError:&error], error);
    assert(*(uint64_t *)copied.contents == UINT64_C(0x3333333333333333));
    uint64_t before, after, again;
    require([cache sourceVersionAtAddress:address
                                   length:4
                                  version:&before
                                    error:&error],
            error);
    uint64_t generation =
        [[cache valueForKey:@"generation"] unsignedLongLongValue];
    assert(tr_fast(cache, address, YES));
    *(uint32_t *)((uint8_t *)cache.vram.contents + address) =
        UINT32_C(0xfedcba98);
    require([cache sourceVersionAtAddress:address
                                   length:4
                                  version:&after
                                    error:&error] &&
                [cache sourceVersionAtAddress:address
                                       length:4
                                      version:&again
                                        error:&error],
            error);
    assert(after == generation + 1 && after > before && again == after &&
           *(uint32_t *)((uint8_t *)cache.vram.contents + address) ==
               UINT32_C(0xfedcba98));
    require([cache discardForRestoreWithError:&error], error);
}
static void tr_cancel_and_concurrent(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands;
    TargetRetirementCache *cache = tr_cache(device, &commands);
    const NSUInteger address = 32768;
    gpu_dep_write(cache, address, UINT64_C(0x0123456789abcdef));
    NV2AMetalSurfaceRecording *cancelled = cache.recording;
    [cache cancel];
    assert(*(uint64_t *)((uint8_t *)cache.vram.contents + address) ==
           UINT64_C(0x3333333333333333));
    assert(cancelled.cancelled && !tr_refs(cache, 8) &&
           tr_fast(cache, address, NO));
    gpu_dep_write(cache, address, UINT64_C(0xfedcba9876543210));
    commands.failSubmit = YES;
    assert(![cache submitWithError:&error] && error &&
           !tr_fast(cache, address, NO));
    error = nil;
    tr_idle(cache);
    assert(*(uint64_t *)((uint8_t *)cache.vram.contents + address) ==
           UINT64_C(0xfedcba9876543210));
    assert(!tr_refs(cache, 8) && tr_fast(cache, address, NO));
    NV2AMetalSurfaceConfig c = tr_config();
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:address
                                                              config:&c
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    [cache cancel];
    assert(surface.valid && !tr_fast(cache, address, NO) &&
           tr_refs(cache, 8) == 1);
    require([cache prepareSelectedSurface:surface
                       discardingContents:YES
                                    error:&error],
            error);
    tr_clear_replacing(cache, surface);
    tr_idle(cache);
    assert(tr_cpu(cache, address, NO, 0, NO) == UINT32_C(0xff00ff00));
    assert(surface.valid && tr_refs(cache, 8) == 1 &&
           !tr_fast(cache, address, NO));
    require([cache discardForRestoreWithError:&error], error);
    assert(!surface.valid && !tr_refs(cache, 8));
    NSObject *lock = [cache valueForKey:@"stateLock"];
    dispatch_semaphore_t held = dispatch_semaphore_create(0),
                         release = dispatch_semaphore_create(0);
    dispatch_group_t workers = dispatch_group_create();
    dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
      @synchronized(lock) {
          dispatch_semaphore_signal(held);
          dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
      }
    });
    assert(!dispatch_semaphore_wait(
        held, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSUInteger successes = 0;
    dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
      for (unsigned i = 0; i < 10000; i++)
          successes += nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard,
                                                       address, 4, NO);
      dispatch_semaphore_signal(done);
    });
    long blocked = dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    dispatch_semaphore_signal(release);
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
    assert(!blocked && successes == 10000);
    commands.failCompletion = YES;
    assert(![cache waitUntilIdleWithError:&error] && error &&
           !tr_fast(cache, address, NO));
}
static void target_retirement_tests(id<MTLDevice> device)
{
    NSData *candidate = tr_bindings(device, NO),
           *reference = tr_bindings(device, YES);
    assert([candidate isEqualToData:reference]);
    tr_tokens(device, NO);
    tr_tokens(device, YES);
    tr_download(device);
    tr_reader_after_retirement(device);
    tr_cancel_and_concurrent(device);
    puts("Target retirement: conservative CPU-path A/B exact VRAM/GPUbytes; "
         "clean/dirty and overlapping bindings,cross-page downloads,two-token "
         "producer/full "
         "boundaries,cancel/retry/Restore/failure,sourceepochs/hooks and10000 "
         "lock-free concurrent reads PASS");
    checks++;
}
#endif
