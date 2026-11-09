/* Monotone watch registration and the separate live-reader/dirty contracts.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_WATCH_REGISTRATION_H
#define TEST_METAL_WATCH_REGISTRATION_H

#include <stdatomic.h>
static BOOL wr_watched(NV2AMetalSurfaceCache *cache, NSUInteger page, BOOL write)
{
    const NV2AMetalCPUAccessGuard *g = cache.cpuAccessGuard;
    NSUInteger word = page / 64 + (write ? g->words : 0);
    return !!(atomic_load_explicit(g->watched + word, memory_order_acquire) &
              (UINT64_C(1) << (page % 64)));
}

@interface NV2AMetalSurfaceCache (WatchRegistrationTest)
- (void)watchCPUReadsAtAddress:(NSUInteger)address length:(NSUInteger)length;
- (void)watchCPUWritesAtAddress:(NSUInteger)address length:(NSUInteger)length;
@end
static void wr_register(NV2AMetalSurfaceCache *cache, NSUInteger address,
                        NSUInteger length, BOOL reads)
{
    /* Private helpers have the same metadata-lock contract as their callers. */
    @synchronized([cache valueForKey:@"stateLock"]) {
        if (reads)
            [cache watchCPUReadsAtAddress:address length:length];
        else
            [cache watchCPUWritesAtAddress:address length:length];
    }
}
static void wr_hook(NSArray<NSValue *> *hooks, NSUInteger count,
                    NSUInteger address, NSUInteger length)
{
    assert(hooks.count == count && NSEqualRanges(hooks.lastObject.rangeValue,
                                                 NSMakeRange(address, length)));
}
static void wr_store(NV2AMetalSurfaceCache *cache, NSUInteger address,
                     uint32_t value)
{
    NSError *error = nil;
    uint64_t before, after, again;
    require([cache sourceVersionAtAddress:address
                                   length:4
                                  version:&before
                                    error:&error],
            error);
    uint64_t generation =
        [[cache valueForKey:@"generation"] unsignedLongLongValue];
    /* This is a real pre-write callback followed by its actual RAM store. */
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, address, 4, YES));
    memcpy((uint8_t *)cache.vram.contents + address, &value, sizeof(value));
    require([cache sourceVersionAtAddress:address
                                   length:4
                                  version:&after
                                    error:&error] &&
                [cache sourceVersionAtAddress:address
                                       length:4
                                      version:&again
                                        error:&error],
            error);
    assert(after == generation + 1 && after > before && again == after);
    uint32_t stored;
    memcpy(&stored, (const uint8_t *)cache.vram.contents + address, 4);
    assert(stored == value);
}
static void watch_registration_tests(id<MTLDevice> device)
{
    const NSUInteger page = 4096;
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:132 * page
                            options:MTLResourceStorageModeShared];
    require(commands && ram, error);
    memset(ram.contents, 0, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    NSMutableArray<NSValue *> *hooks = [NSMutableArray new];
    cache.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
      [hooks addObject:[NSValue valueWithRange:NSMakeRange(address, length)]];
    };
    wr_register(cache, 63 * page + 17, 4, NO);
    wr_hook(hooks, 1, 63 * page, page);
    wr_register(cache, 63 * page + 20, 1, NO);
    wr_hook(hooks, 1, 63 * page, page);
    wr_register(cache, 64 * page - 2, 4, NO);
    wr_hook(hooks, 2, 63 * page, 2 * page);
    wr_register(cache, 62 * page + 8, 3 * page, NO);
    wr_hook(hooks, 3, 62 * page, 4 * page);
    wr_register(cache, 62 * page, 4 * page, NO);
    wr_hook(hooks, 3, 62 * page, 4 * page);
    /* Source watches already installed both-direction QEMU callbacks. A
     * target-role upgrade still sets read bits, without installing another. */
    wr_register(cache, 63 * page + 31, 1, YES);
    wr_register(cache, 64 * page - 1, 2, YES);
    wr_hook(hooks, 3, 62 * page, 4 * page);
    wr_register(cache, 66 * page + 3, 1, YES);
    wr_hook(hooks, 4, 66 * page, page);
    wr_register(cache, 66 * page - 2, 4, YES);
    wr_register(cache, ram.length, 0, YES);
    wr_register(cache, ram.length, 0, NO);
    wr_hook(hooks, 4, 66 * page, page);
    for (NSUInteger p = 0; p < 132; p++) {
        BOOL source = p >= 62 && p <= 66;
        BOOL target = p >= 63 && p <= 66;
        assert(wr_watched(cache, p, YES) == source &&
               wr_watched(cache, p, NO) == target);
        assert(nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard, p * page,
                                               page, YES) == !source);
        /* These registrations install hooks/bits, but own no target lease. */
        assert(nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard, p * page,
                                               page, NO));
    }
    assert(!nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard, 62 * page - 1,
                                            2, YES));
    assert(nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard, 62 * page - 1,
                                           2, NO));
    wr_store(cache, 62 * page + 20, UINT32_C(0x13579bdf));
    wr_hook(hooks, 4, 66 * page, page);
    require([cache prepareGPUReadAtAddress:62 * page + 20
                                    length:4
                                     error:&error],
            error);
    NV2AMetalSurfaceRecording *reader = cache.recording;
    assert(reader && !nv2a_metal_try_cpu_access(cache.cpuAccessGuard,
                                                62 * page + 20, 4, YES));
    /* Re-register a fully covered range while its live reader still owns it. */
    wr_register(cache, 62 * page, page, NO);
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 62 * page + 20, 4,
                                      YES));
    wr_hook(hooks, 4, 66 * page, page);
    [cache cancel];
    assert(reader.cancelled);
    wr_store(cache, 62 * page + 20, UINT32_C(0x2468ace0));
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache selectSurfaceAtAddress:10 * page
                                                             config:&c
                                                              frame:1
                                                              error:&error];
    require(surface != nil, error);
    wr_hook(hooks, 5, 10 * page, page);
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 10 * page, 4, NO) &&
           !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 10 * page, 4, YES));
    require([cache discardForRestoreWithError:&error], error);
    assert(!surface.valid && !cache.count);
    /* Restore drops the binding lease, while both historical watch masks
     * and every previously installed frontend callback remain monotone. */
    assert(wr_watched(cache, 10, NO) && wr_watched(cache, 10, YES));
    assert(nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard, 10 * page, 4,
                                            NO) &&
           !nv2a_metal_untracked_cpu_access(cache.cpuAccessGuard, 62 * page, 4,
                                            YES));
    wr_store(cache, 62 * page + 20, UINT32_C(0x98765432));
    wr_hook(hooks, 5, 10 * page, page);
    puts("Watch registration: warm/partial/cross-word/read-upgrade masks and "
         "exact hook ranges/counts; CPU dirty versions, active reader/cancel, "
         "target and Restore guards PASS (no measured RMW count)");
    checks++;
}

#endif
