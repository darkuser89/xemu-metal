/* Offscreen ownership-map and concurrent CPU-read regression.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CPU_READ_GUARD_H
#define TEST_METAL_CPU_READ_GUARD_H
static void cpu_deferred_write_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands =
        [[CacheFailureCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    id<MTLBuffer> ram =
        [device newBufferWithLength:1024 * 1024
                            options:MTLResourceStorageModeShared];
    assert(ram);
    memset(ram.contents, 0x31, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    NV2AMetalCPUAccessGuard *guard = cache.cpuAccessGuard;
    assert(!nv2a_metal_try_cpu_access(NULL, 0, 1, YES));
    assert(!nv2a_metal_try_cpu_access(guard, NSUIntegerMax, 2, YES));
    assert(!nv2a_metal_try_cpu_access(guard, ram.length, 1, YES));
    assert(nv2a_metal_try_cpu_access(guard, ram.length, 0, YES));
    uint64_t before[256], after, same;
    for (unsigned page = 0; page < 256; page++)
        require([cache sourceVersionAtAddress:page * 4096
                                       length:4096
                                      version:&before[page]
                                        error:&error],
                error);
    assert(nv2a_metal_try_cpu_access(guard, 64 * 4096 - 1, 2, YES));
    require([cache sourceVersionAtAddress:62 * 4096
                                   length:4 * 4096
                                  version:&after
                                    error:&error],
            error);
    for (unsigned page = 62; page <= 65; page++) {
        require([cache sourceVersionAtAddress:page * 4096
                                       length:4096
                                      version:&after
                                        error:&error],
                error);
        assert((after > before[page]) == (page == 63 || page == 64));
        before[page] = after;
    }
    for (unsigned i = 0; i < 32; i++)
        assert(nv2a_metal_try_cpu_access(guard, 4096, 4, YES));
    require([cache sourceVersionAtAddress:4096
                                   length:4
                                  version:&after
                                    error:&error],
            error);
    require([cache sourceVersionAtAddress:4096
                                   length:4
                                  version:&same
                                    error:&error],
            error);
    assert(after > before[1] && same == after);
    assert(nv2a_metal_try_cpu_access(guard, 4096, 4, YES));
    require([cache sourceVersionAtAddress:4096
                                   length:4
                                  version:&same
                                    error:&error],
            error);
    assert(same > after);

    id<MTLBuffer> copied = encode_vram_copy(cache, 4 * 4096, 32);
    assert(!nv2a_metal_try_cpu_access(guard, 4 * 4096, 4, YES));
    assert(nv2a_metal_try_cpu_access(guard, 8 * 4096, 4, YES));
    assert(nv2a_metal_try_cpu_access(guard, 4 * 4096, 4, NO));
    require([cache submitWithError:&error], error);
    assert(!nv2a_metal_try_cpu_access(guard, 4 * 4096, 4, YES));
    encode_vram_copy(cache, 8 * 4096, 32);
    encode_vram_copy(cache, 4 * 4096 + 4, 4);
    [cache cancel];
    assert(!nv2a_metal_try_cpu_access(guard, 4 * 4096, 4, YES));
    assert(nv2a_metal_try_cpu_access(guard, 8 * 4096, 4, YES));
    require([cache waitUntilIdleWithError:&error], error);
    assert(nv2a_metal_try_cpu_access(guard, 4 * 4096, 4, YES));
    memset((uint8_t *)ram.contents + 4 * 4096, 0xa5, 32);
    for (unsigned i = 0; i < 32; i++)
        assert(((const uint8_t *)copied.contents)[i] == 0x31);
    assert(nv2a_metal_try_cpu_access(guard, 8 * 4096, 4, YES));

    NV2AMetalSurfaceConfig c = config(8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface =
        [cache prepareSurfaceAtAddress:128 * 4096 - 6
                                config:&c
                                 frame:1
                                 error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    assert(!nv2a_metal_try_cpu_access(guard, 128 * 4096 - 6, 4, YES));
    require([cache prepareCPUAccessAtAddress:128 * 4096 - 6
                                      length:4
                                       write:NO
                                       error:&error],
            error);
    uint32_t pixel;
    memcpy(&pixel, (const uint8_t *)ram.contents + 128 * 4096 - 6, 4);
    assert(pixel == 0xffff0000);
    assert(!nv2a_metal_try_cpu_access(guard, 127 * 4096, 1, YES));
    assert(!nv2a_metal_try_cpu_access(guard, 128 * 4096, 1, YES));
    require([cache discardForRestoreWithError:&error], error);
    assert(!nv2a_metal_try_cpu_access(guard, 128 * 4096, 1, YES));

    NSObject *lock = [cache valueForKey:@"stateLock"];
    dispatch_semaphore_t held = dispatch_semaphore_create(0);
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_group_t workers = dispatch_group_create();
    dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
      @synchronized(lock) {
          dispatch_semaphore_signal(held);
          dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
      }
    });
    assert(!dispatch_semaphore_wait(
        held, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
      for (unsigned i = 0; i < 100000; i++) {
          assert(nv2a_metal_try_cpu_access(guard, 200 * 4096, 4, YES));
          ((volatile uint32_t *)ram.contents)[200 * 4096 / 4] = i;
      }
      dispatch_semaphore_signal(finished);
    });
    long stalled = dispatch_semaphore_wait(
        finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    dispatch_semaphore_signal(release);
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
    assert(!stalled &&
           ((const uint32_t *)ram.contents)[200 * 4096 / 4] == 99999);
    require([cache sourceVersionAtAddress:200 * 4096
                                   length:4
                                  version:&after
                                    error:&error],
            error);
    assert(after > before[200]);
    // Concurrent writers to different pages must not lose dirty bits in one
    // word.
    for (unsigned page = 160; page < 168; page++)
        require([cache sourceVersionAtAddress:page * 4096
                                       length:4
                                      version:&before[page]
                                        error:&error],
                error);
    for (unsigned page = 160; page < 168; page++)
        dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
          for (unsigned i = 0; i < 10000; i++) {
              assert(nv2a_metal_try_cpu_access(guard, page * 4096, 4, YES));
              ((volatile uint32_t *)ram.contents)[page * 4096 / 4] = i;
          }
        });
    // Consume notifications while writers publish further notifications.
    for (unsigned i = 0; i < 1000; i++)
        require([cache sourceVersionAtAddress:(160 + i % 8) * 4096
                                       length:4
                                      version:&after
                                        error:&error],
                error);
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
    for (unsigned page = 160; page < 168; page++) {
        require([cache sourceVersionAtAddress:page * 4096
                                       length:4
                                      version:&after
                                        error:&error],
                error);
        assert(after > before[page] &&
               ((const uint32_t *)ram.contents)[page * 4096 / 4] == 9999);
    }
    // Exhaustion must not wrap or consume the pending invalidation.
    [cache setValue:@(UINT64_MAX) forKey:@"generation"];
    assert(nv2a_metal_try_cpu_access(guard, 200 * 4096, 4, YES));
    for (unsigned i = 0; i < 2; i++) {
        error = nil;
        assert(![cache sourceVersionAtAddress:200 * 4096
                                       length:4
                                      version:&after
                                        error:&error] &&
               error);
    }
    commands.failCompletion = YES;
    error = nil;
    assert(![cache waitUntilIdleWithError:&error] && error);
    assert(!nv2a_metal_try_cpu_access(guard, 200 * 4096, 4, YES));
    puts("Deferred CPU writes: 256 pages, cross-word keys, coalescing, actual "
         "GPU copy/download, "
         "submit/cancel/idle, 100000 writes under metadata lock, eight racing "
         "writers, overflow/sticky failure PASS");
}

static void cpu_read_guard_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands =
        [[CacheFailureCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    id<MTLBuffer> ram =
        [device newBufferWithLength:1024 * 1024
                            options:MTLResourceStorageModeShared];
    assert(ram);
    memset(ram.contents, 0xa5, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    const NV2AMetalCPUAccessGuard *guard = cache.cpuAccessGuard;
    assert(nv2a_metal_untracked_cpu_access(guard, 0, ram.length, NO));
    assert(!nv2a_metal_untracked_cpu_access(guard, ram.length, 1, NO));
    assert(!nv2a_metal_untracked_cpu_access(guard, NSUIntegerMax, 2, NO));
    assert(nv2a_metal_untracked_cpu_access(guard, ram.length, 0, NO));
    NV2AMetalSurfaceConfig c = config(8, YES, 4, 1, NO);
    const NSUInteger surfaceAddress = 64 * 4096 - 6;
    NV2AMetalCachedSurface *surface =
        [cache prepareSurfaceAtAddress:surfaceAddress
                                config:&c
                                 frame:1
                                 error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    assert(!nv2a_metal_untracked_cpu_access(guard, 63 * 4096, 1, NO));
    assert(!nv2a_metal_untracked_cpu_access(guard, 64 * 4096, 1, NO));
    assert(!nv2a_metal_untracked_cpu_access(guard, 63 * 4096 - 1, 2, NO));
    assert(nv2a_metal_untracked_cpu_access(guard, 62 * 4096, 4096, NO));
    require([cache prepareCPUAccessAtAddress:surfaceAddress
                                      length:4
                                       write:NO
                                       error:&error],
            error);
    uint32_t pixel;
    memcpy(&pixel, (const uint8_t *)ram.contents + surfaceAddress, 4);
    assert(pixel == 0xffff0000);
    require([cache invalidateAddress:surfaceAddress length:1 error:&error],
            error);
    assert(!nv2a_metal_untracked_cpu_access(guard, surfaceAddress, 4, NO));
    require([cache prepareGPUWriteAtAddress:128 * 4096 - 1
                                     length:8194
                                      error:&error],
            error);
    for (unsigned page = 0; page < 256; page++) {
        BOOL watched = page == 63 || page == 64 || (page >= 127 && page <= 130);
        assert(nv2a_metal_untracked_cpu_access(guard, page * 4096, 4096, NO) ==
               !watched);
    }
    [cache cancel];
    assert(nv2a_metal_untracked_cpu_access(guard, 4096, 16, YES));
    memset((uint8_t *)ram.contents + 4096, 0x5a, 16);
    uint64_t before, after;
    require([cache sourceVersionAtAddress:4096
                                   length:16
                                  version:&before
                                    error:&error],
            error);
    assert(!nv2a_metal_untracked_cpu_access(guard, 4096, 16, YES));
    assert(nv2a_metal_untracked_cpu_access(guard, 4096, 16, NO));
    BOOL completed = NO;
    require([cache tryIdleCPUAccessAtAddress:4096
                                      length:16
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed);
    memset((uint8_t *)ram.contents + 4096, 0xa5, 16);
    require([cache sourceVersionAtAddress:4096
                                   length:16
                                  version:&after
                                    error:&error],
            error);
    assert(after > before);
    require([cache prepareGPUReadAtAddress:8192 length:16 error:&error], error);
    assert(!nv2a_metal_untracked_cpu_access(guard, 8192, 16, YES));
    assert(nv2a_metal_untracked_cpu_access(guard, 8192, 16, NO));
    [cache cancel];
    assert(!nv2a_metal_untracked_cpu_access(guard, 8192, 16, YES));
    assert(!nv2a_metal_untracked_cpu_access(guard, 128 * 4096, 1, NO));
    require([cache discardForRestoreWithError:&error], error);
    assert(!nv2a_metal_untracked_cpu_access(guard, 128 * 4096, 1, NO));
    NSObject *lock = [cache valueForKey:@"stateLock"];
    dispatch_semaphore_t held = dispatch_semaphore_create(0);
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    dispatch_group_t workers = dispatch_group_create();
    dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
      @synchronized(lock) {
          dispatch_semaphore_signal(held);
          dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
      }
    });
    assert(!dispatch_semaphore_wait(
        held, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block unsigned sum = 0;
    dispatch_group_async(workers, dispatch_get_global_queue(0, 0), ^{
      for (unsigned i = 0; i < 100000; i++) {
          assert(nv2a_metal_untracked_cpu_access(guard, 4096, 4, NO));
          sum += ((const volatile uint8_t *)ram.contents)[4096];
      }
      dispatch_semaphore_signal(finished);
    });
    long stalled = dispatch_semaphore_wait(
        finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    dispatch_semaphore_signal(release);
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
    assert(!stalled && sum == 16500000);
    commands.failCompletion = YES;
    assert(![cache waitUntilIdleWithError:&error] && error);
    assert(!nv2a_metal_untracked_cpu_access(guard, 4096, 4, NO));
    cpu_deferred_write_tests(device);
    printf("CPU read guard: dirty GPU download, 256 pages, cross-word bounds, "
           "cancel/restore, sticky failure, 100000 concurrent reads PASS\n");
}
#endif
