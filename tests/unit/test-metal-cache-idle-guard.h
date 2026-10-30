/* Offscreen GPU completion and concurrent CPU coherence checks.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CACHE_IDLE_GUARD_H
#define TEST_METAL_CACHE_IDLE_GUARD_H

#import <objc/runtime.h>
#import "hw/xbox/nv2a/pgraph/metal/blit.h"

@interface CacheIdleWaitProbe : NSObject
@property(nonatomic) NV2AMetalSurfaceCache *cache;
@property(nonatomic) id<MTLSharedEvent> gate;
@property(nonatomic) BOOL nested, download;
@property(atomic) BOOL watchdogReleased;
@property(nonatomic) BOOL CPUFinishedBeforeRelease, readProtected,
    downloadReadProtected, downloadWriteProtected, rawWriteReadProtected,
    rawWriteWriteProtected;
@property(nonatomic) unsigned CPUAccesses;
@property(nonatomic) dispatch_group_t worker;
@property(nonatomic) dispatch_semaphore_t started, finished;
@end
@implementation CacheIdleWaitProbe
@end

static void cache_idle_CPU_work(CacheIdleWaitProbe *probe)
{
    @autoreleasepool {
        dispatch_semaphore_signal(probe.started);
        NSError *error = nil;
        uint8_t *ram = probe.cache.vram.contents;
        for (unsigned i = 0; i < 64; i++) {
            BOOL completed = NO;
            require([probe.cache tryIdleCPUAccessAtAddress:60000
                                                    length:4
                                                     write:NO
                                                 completed:&completed
                                                     error:&error],
                    error);
            assert(completed);
            uint32_t value;
            memcpy(&value, ram + 60000, 4);
            assert(value == (i ? i - 1 : 0));
            require([probe.cache tryIdleCPUAccessAtAddress:60000
                                                    length:4
                                                     write:YES
                                                 completed:&completed
                                                     error:&error],
                    error);
            assert(completed);
            memcpy(ram + 60000, &i, 4);
            probe.CPUAccesses += 2;
        }
        BOOL completed = NO;
        require([probe.cache tryIdleCPUAccessAtAddress:60600
                                                length:4
                                                 write:YES
                                             completed:&completed
                                                 error:&error],
                error);
        probe.readProtected = !completed;
        if (completed) {
            uint32_t word = 0xaabbccdd;
            memcpy(ram + 60600, &word, 4);
        }
        require([probe.cache tryIdleCPUAccessAtAddress:60800
                                                length:4
                                                 write:NO
                                             completed:&completed
                                                 error:&error],
                error);
        probe.rawWriteReadProtected = !completed;
        require([probe.cache tryIdleCPUAccessAtAddress:60800
                                                length:4
                                                 write:YES
                                             completed:&completed
                                                 error:&error],
                error);
        probe.rawWriteWriteProtected = !completed;
        if (probe.download) {
            require([probe.cache tryIdleCPUAccessAtAddress:1024
                                                    length:4
                                                     write:NO
                                                 completed:&completed
                                                     error:&error],
                    error);
            probe.downloadReadProtected = !completed;
            require([probe.cache tryIdleCPUAccessAtAddress:1024
                                                    length:4
                                                     write:YES
                                                 completed:&completed
                                                     error:&error],
                    error);
            probe.downloadWriteProtected = !completed;
        } else {
            require([probe.cache tryIdleCPUAccessAtAddress:1024
                                                    length:4
                                                     write:YES
                                                 completed:&completed
                                                     error:&error],
                    error);
            assert(completed);
            uint32_t blue = 0xff0000ff;
            memcpy(ram + 1024, &blue, 4);
        }
        probe.CPUFinishedBeforeRelease = probe.gate.signaledValue == 0;
        if (!probe.nested)
            probe.gate.signaledValue = 1;
        dispatch_semaphore_signal(probe.finished);
    }
}

@interface CacheIdleWaitCommands : CacheFailureCommands
@property(nonatomic, weak) CacheIdleWaitProbe *probe;
@end
@implementation CacheIdleWaitCommands
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    CacheIdleWaitProbe *probe = _probe;
    if (!probe)
        return [super waitUntilIdleWithError:error];
    dispatch_group_async(probe.worker,
                         dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                           cache_idle_CPU_work(probe);
                         });
    long started = dispatch_semaphore_wait(
        probe.started, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    assert(!started);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (probe.gate.signaledValue == 0) {
                         probe.watchdogReleased = YES;
                         probe.gate.signaledValue = 1;
                     }
                   });
    BOOL ok = [super waitUntilIdleWithError:error];
    if (probe.nested) {
        assert(probe.watchdogReleased);
        assert(dispatch_semaphore_wait(probe.finished, DISPATCH_TIME_NOW));
    } else {
        assert(!probe.watchdogReleased);
    }
    return ok;
}
@end

static void cache_idle_guard_tests(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 4; mode++) {
        NSError *error = nil;
        CacheIdleWaitCommands *commands =
            [[CacheIdleWaitCommands alloc] initWithDevice:device error:&error];
        require(commands != nil, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        assert(ram);
        memset(ram.contents, 0x33, ram.length);
        uint32_t zero = 0, marker = 0x11223344;
        memcpy((uint8_t *)ram.contents + 60000, &zero, 4);
        memcpy((uint8_t *)ram.contents + 60600, &marker, 4);
        __block unsigned published = 0;
        NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
            initWithCommands:commands
                        vram:ram
                didWriteVRAM:^(NSUInteger address, NSUInteger length) {
                  assert(address == 1024 && length == 192);
                  published++;
                }
                       error:&error];
        require(cache != nil, error);
        NV2AMetalSurfaceConfig c =
            config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
        NV2AMetalCachedSurface *surface =
            [cache prepareSurfaceAtAddress:1024 config:&c frame:0 error:&error];
        require(surface != nil, error);
        require([cache submitWithError:&error], error);
        require([cache waitUntilIdleWithError:&error], error);
        uint64_t generation = surface.generation, before = 0, after = 0;
        require([cache sourceVersionAtAddress:60000
                                       length:4
                                      version:&before
                                        error:&error],
                error);
        CacheIdleWaitProbe *probe = [CacheIdleWaitProbe new];
        probe.cache = cache;
        probe.gate = [device newSharedEvent];
        probe.nested = mode == 2;
        probe.download = mode == 1 || mode == 3;
        probe.worker = dispatch_group_create();
        probe.started = dispatch_semaphore_create(0);
        probe.finished = dispatch_semaphore_create(0);
        assert(probe.gate);
        if (probe.download) {
            require([cache prepareSurfaceAtAddress:1024
                                            config:&c
                                             frame:0
                                             error:&error] != nil,
                    error);
            clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
            require([cache prepareGPUReadAtAddress:1024
                                            length:192
                                             error:&error],
                    error);
        }
        id<MTLBuffer> output = encode_vram_copy(cache, 60600, 4);
        NV2AMetalBlit *blitter = [[NV2AMetalBlit alloc] initWithDevice:device
                                                                 error:&error];
        require(blitter != nil, error);
        NV2AMetalBlitConfig blit = {
            .format = NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
            .operation = NV09F_SET_OPERATION_SRCCOPY,
            .source_offset = 60600,
            .destination_offset = 60800,
            .source_pitch = 4,
            .destination_pitch = 4,
            .row_bytes = 4,
            .rows = 1,
        };
        require([cache prepareGPUWriteAtAddress:60800 length:4 error:&error],
                error);
        require([blitter encodeSource:ram
                          destination:ram
                               config:&blit
                             commands:commands
                                error:&error],
                error);
        NV2AMetalSurfaceRecording *token = cache.recording;
        Ivar queueIvar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        assert(queueIvar);
        id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
        [queue waitForEvent:probe.gate value:1];
        require([cache submitWithError:&error], error);
        assert(token.submitted && !token.completed && !published);
        commands.failCompletion = mode == 3;
        commands.probe = probe;
        BOOL ok = probe.nested ? [cache prepareCPUAccessAtAddress:65000
                                                           length:4
                                                            write:NO
                                                            error:&error] :
                                 [cache waitUntilIdleWithError:&error];
        commands.probe = nil;
        long finished = dispatch_group_wait(
            probe.worker, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        assert(!finished && probe.CPUAccesses == 128);
        assert(probe.CPUFinishedBeforeRelease == !probe.nested);
        assert(probe.watchdogReleased == probe.nested);
        assert(probe.readProtected == !probe.nested);
        assert(probe.rawWriteReadProtected == !probe.nested &&
               probe.rawWriteWriteProtected == !probe.nested);
        assert(*(uint32_t *)((uint8_t *)ram.contents + 60800) == marker);
        if (probe.download)
            assert(probe.downloadReadProtected && probe.downloadWriteProtected);
        assert(*(uint32_t *)output.contents == marker);
        assert(*(uint32_t *)((uint8_t *)ram.contents + 60000) == 63);
        if (mode == 3) {
            assert(!ok && error.code == 2 && !token.completed && !published);
            BOOL completed = YES;
            assert(![cache tryIdleCPUAccessAtAddress:60000
                                              length:4
                                               write:YES
                                           completed:&completed
                                               error:&error]);
            assert(!completed && error.code == 2);
        } else {
            require(ok, error);
            assert(token.completed && published == (probe.download ? 1 : 0));
            require([cache sourceVersionAtAddress:60000
                                           length:4
                                          version:&after
                                            error:&error],
                    error);
            assert(after > before);
            if (probe.download) {
                check_region(ram, 1024, c, 0xff00ff00, 0x33);
            } else {
                assert(surface.needsUpload && surface.generation > generation);
                assert(*(uint32_t *)((uint8_t *)ram.contents + 1024) ==
                       0xff0000ff);
            }
            BOOL completed = NO;
            require([cache tryIdleCPUAccessAtAddress:60600
                                              length:4
                                               write:YES
                                           completed:&completed
                                               error:&error],
                    error);
            assert(completed);
            require([cache flushWithError:&error], error);
        }
        checks++;
    }
    puts(
        "Cache idle guard: four direct/nested/download/injected-completion-"
        "failure cases, 512 unrelated CPU checks, protected GPU source copies, "
        "download pixels, CPU versions and completion publication PASS");
}

static void raw_GPU_write_range_tests(NV2AMetalCommands *commands,
                                      id<MTLBuffer> vram)
{
    const NSUInteger ranges[][2] = {
        { 0, 1 }, { 1, 3 }, { 4095, 1 }, { 4096, 0 }, { 4092, 4 }, { 128, 64 },
    };
    const NSUInteger probes[][2] = {
        { 0, 4096 }, { 0, 1 },    { 0, 0 },    { 1, 1 },
        { 127, 1 },  { 128, 1 },  { 191, 1 },  { 192, 1 },
        { 4091, 1 }, { 4092, 4 }, { 4095, 1 }, { 4096, 0 },
    };
    unsigned cases = 0;
    for (unsigned span = 0; span < sizeof(ranges) / sizeof(ranges[0]); span++) {
        NSError *error = nil;
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:vram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        assert(![cache prepareGPUWriteAtAddress:NSUIntegerMax
                                         length:1
                                          error:&error]);
        assert(!cache.recording);
        for (unsigned lifecycle = 0; lifecycle < 2; lifecycle++) {
            require([cache prepareGPUWriteAtAddress:ranges[span][0]
                                             length:ranges[span][1]
                                              error:&error],
                    error);
            NV2AMetalSurfaceRecording *token = cache.recording;
            for (unsigned phase = 0; phase < 3; phase++) {
                if (phase == 1) {
                    if (!lifecycle)
                        [cache cancel];
                    else
                        require([cache submitWithError:&error], error);
                }
                if (phase == 2 && lifecycle)
                    require([cache waitUntilIdleWithError:&error], error);
                BOOL pending = phase == 0 || (phase == 1 && lifecycle);
                for (unsigned probe = 0;
                     probe < sizeof(probes) / sizeof(probes[0]); probe++) {
                    BOOL overlap =
                        ranges[span][1] && probes[probe][1] &&
                        ranges[span][0] < probes[probe][0] + probes[probe][1] &&
                        probes[probe][0] < ranges[span][0] + ranges[span][1];
                    for (unsigned write = 0; write < 2; write++) {
                        BOOL completed = NO;
                        require([cache
                                    tryIdleCPUAccessAtAddress:probes[probe][0]
                                                       length:probes[probe][1]
                                                        write:write
                                                    completed:&completed
                                                        error:&error],
                                error);
                        assert(completed == !(pending && overlap));
                        cases++;
                    }
                }
                if (pending && ranges[span][1])
                    assert(![cache observeCPUWriteAtAddress:ranges[span][0]
                                                     length:1
                                                      error:&error]);
            }
            assert(lifecycle ? token.completed && token.submitted :
                               token.cancelled);
        }
        require([cache flushWithError:&error], error);
    }
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    require([cache prepareSurfaceAtAddress:0 config:&c frame:0
                                     error:&error] != nil,
            error);
    assert(![cache prepareGPUWriteAtAddress:0 length:1 error:&error]);
    [cache cancel];
    require([cache flushWithError:&error], error);
    checks += cases;
    printf("Raw GPU writes: %u boundary/read/write/cancel/submit/idle cases, "
           "dirty-notification and live-surface rejection PASS\n",
           cases);
}
#endif
