/* Incompatible RTT bytes download/decode before a disjoint raster tail.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DOWNLOAD_PREFIX_PGRAPH_H
#define TEST_METAL_DOWNLOAD_PREFIX_PGRAPH_H
#include "test-metal-texture-readback.h"

static BOOL dpp_reference;
static unsigned dpp_eligibility;
static BOOL (*dpp_can_own_original)(id, SEL, NV2AMetalSurfaceRecording *);
static BOOL dpp_can_own(id object, SEL selector,
                        NV2AMetalSurfaceRecording *recording)
{
    if (object == surfaces.cache) {
        dpp_eligibility++;
        if (dpp_reference)
            return NO; /* The exact conservative full-submit selection. */
    }
    return dpp_can_own_original(object, selector, recording);
}
static void dpp_expect_source(uint32_t expected)
{
    for (unsigned i = 0; i < 64; i++) {
        uint32_t value;
        memcpy(&value, state->vram_ptr + 32768 + i * 4, 4);
        assert(value == expected);
    }
}
static void dpp_expect_texture(NV2AMetalCachedTexture *texture)
{
    NSError *error = nil;
    id<MTLTexture> native = texture.binding.texture;
    assert(native.width == 8 && native.height == 8);
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:native.device error:&error];
    require(commands && [commands beginWithError:&error], error);
    id<MTLBuffer> values = test_metal_read_texture(commands, native, 0, 0);
    require(values && [commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    /* Signed red uses the established MixedHalf representation: unsigned
     * G/B/A store byte/256 and the sampling helper restores byte/255. This
     * raw GPU read checks that storage exactly; the real raster goldens below
     * independently require fully opaque green after sampling. */
    float one = texture.mixedSignedHalf ? 255.f / 256.f : 1;
    for (unsigned y = 0; y < 8; y++) {
        const float *row =
            (const float *)((const uint8_t *)values.contents + y * 256);
        for (unsigned x = 0; x < 8; x++)
            assert(row[x * 4] == 0 && row[x * 4 + 1] == one &&
                   row[x * 4 + 2] == 0 && row[x * 4 + 3] == one);
    }
}
static NSData *dpp_run(BOOL write, BOOL reference)
{
    cpp_scene(YES, write ? 1 : 0);
    dpp_reference = reference;
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    cpp_commands = cache.commands;
    qemu_mutex_lock(&pg->lock);
    /* Signed red remains incompatible with the direct opaque capture. Its
     * source red is exactly zero in both green and blue witnesses, so the
     * original sample/alpha goldens still apply after signed conversion. */
    texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
    pg->regs_[NV_PGRAPH_TEXFILTER0] |= NV_PGRAPH_TEXFILTER0_RSIGNED;
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    cpu_write(32768, 256);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t red = UINT32_C(0xffff0000);
        memcpy(state->vram_ptr + 32768 + i * 4, &red, 4);
    }
    dma[0].limit = 65535 - 1024;
    pg->surface_color.offset = 32768 - 1024;
    pg->surface_scale_factor = 2;
    pg->surface_color.buffer_dirty = true;
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = UINT32_C(0xff00ff00);
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] = 7u
                                                                        << 16;
    require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    NV2AMetalCachedSurface *source = surfaces.color;
    assert(source.address == 32768 && source.dirty &&
           source.transfer.config.format ==
               NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 &&
           source.transfer.config.pitch == 32 &&
           source.transfer.config.scale == 2 &&
           source.transfer.nativeWidth == 16 &&
           source.transfer.nativeHeight == 16 &&
           source.transfer.nativePixelFormat == MTLPixelFormatBGRA8Unorm);
    dpp_expect_source(UINT32_C(0xffff0000));
    pg->surface_color.offset = 0;
    pg->surface_scale_factor = 1;
    pg->surface_color.buffer_dirty = true;
    require([draw beginWithError:&error], error);
    NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
    NV2AMetalCachedTexture *snapshot = [pixel.textureSnapshot textureAtIndex:0];
    NV2AMetalSurfaceRecording *head = snapshot.producerRecording;
    assert(head && !head.submitted && !head.cpuHazardsRetired &&
           [[head valueForKey:@"downloadEnd"] unsignedIntegerValue] == 1 &&
           snapshot.scale == 1 &&
           snapshot.binding.texture.storageMode == MTLStorageModePrivate);
    dpp_expect_source(UINT32_C(0xffff0000));

    cpp_blocker = [[NV2AMetalCommands alloc] initWithDevice:cpp_commands.device
                                                      error:&error];
    require(cpp_blocker != nil, error);
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    cpp_queue = object_getIvar(cpp_commands, queue);
    id<MTL4CommandQueue> blockedQueue = object_getIvar(cpp_blocker, queue);
    cpp_gate = [cpp_commands.device newSharedEvent];
    assert(blockedQueue && cpp_queue && cpp_gate);
    [blockedQueue waitForEvent:cpp_gate value:1];
    require([cpp_blocker beginWithError:&error] != nil, error);
    id<MTLBuffer> blocked =
        [cpp_commands.device newBufferWithLength:4
                                         options:MTLResourceStorageModeShared];
    require(blocked && [cpp_blocker addResource:blocked error:&error], error);
    memset(blocked.contents, 0xcd, 4);
    id<MTL4ComputeCommandEncoder> e =
        [cpp_blocker.commandBuffer computeCommandEncoder];
    assert(e);
    [e fillBuffer:blocked range:NSMakeRange(0, 4) value:0x5a];
    [e endEncoding];
    require([cpp_blocker submitWithError:&error], error);
    id<MTLSharedEvent> watchdog = cpp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    cpp_inject = YES;
    cpp_release_on_wait = NO;
    require([draw flushDrawWithError:&error], error);
    assert(!cpp_inject && cpp_tail && !cpp_tail.submitted &&
           cpp_commands.hasPendingRasterPass && !cpp_gate.signaledValue &&
           *(uint32_t *)blocked.contents == UINT32_C(0xcdcdcdcd));
    pg->draw_arrays_length = 0;
    cpp_commits = cpp_buffers = cpp_full = cpp_waits = 0;
    dpp_eligibility = 0;
    uint64_t batch = cpp_commands.batchSerial;
    uint64_t generation =
        [[cache valueForKey:@"generation"] unsignedLongLongValue];
    cpp_release_on_wait = reference;
    require([cache resolveCPUAccessAtAddress:32768
                                      length:256
                                       write:write
                                       error:&error],
            error);
    cpp_release_on_wait = NO;
    /* Actual shared GPU download bytes, not stale RAM or a metadata flag. */
    dpp_expect_source(UINT32_C(0xff00ff00));
    dpp_expect_texture(snapshot);
    assert(dpp_eligibility);
    if (!reference) {
        assert(!cpp_gate.signaledValue && cpp_commits == 1 && cpp_buffers &&
               cpp_waits && !cpp_full && head.producersCompleted &&
               head.cpuHazardsRetired && !head.completed &&
               !cpp_tail.submitted && !cpp_tail.completed &&
               !cpp_tail.cpuHazardsRetired &&
               cpp_commands.batchSerial == batch &&
               cpp_commands.hasPendingRasterPass &&
               *(uint32_t *)blocked.contents == UINT32_C(0xcdcdcdcd) &&
               ![cpp_blocker.lastSubmitted completedWithError:NULL]);
        NSData *untouched = cpp_color_pixels(&error);
        require(untouched != nil, error);
        for (unsigned i = 0; i < 64; i++)
            assert(((const uint32_t *)untouched.bytes)[i] ==
                   UINT32_C(0xffff0000));
    } else
        assert(cpp_gate.signaledValue == 1 && cpp_full == 1 && cpp_commits &&
               cpp_waits && head.completed && cpp_tail.completed);
    uint64_t version;
    require([cache sourceVersionAtAddress:32768
                                   length:256
                                  version:&version
                                    error:&error],
            error);
    assert([[cache valueForKey:@"generation"] unsignedLongLongValue] ==
           generation + write);
    if (write) {
        assert(version == generation + 1);
        for (unsigned i = 0; i < 64; i++) {
            uint32_t blue = UINT32_C(0xff0000ff);
            memcpy(state->vram_ptr + 32768 + i * 4, &blue, 4);
        }
    }
    /* Private texture serialization must not require the disjoint raster
     * tail. Both routes serialize the same completed immutable upload. */
    NSData *begin = [draw beginSnapshotWithError:&error];
    NSData *pending = [draw pendingSnapshotWithError:&error];
    NSData *vertex = draw.vertexSnapshot;
    require(begin && pending && vertex, error);
    if (!reference)
        assert(!cpp_gate.signaledValue && !cpp_full && !cpp_tail.submitted);
    cpp_gate.signaledValue = 1;
    require([draw endWithError:&error] && [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error] &&
                [cpp_blocker waitUntilIdleWithError:&error] &&
                [cache prepareCPUAccessAtAddress:1024
                                          length:256
                                           write:NO
                                           error:&error] &&
                [cache prepareCPUAccessAtAddress:4096
                                          length:256
                                           write:NO
                                           error:&error],
            error);
    color(1, 1, UINT32_C(0xff00ff00));
    dpp_expect_texture(snapshot);
    if (write)
        dpp_expect_source(UINT32_C(0xff0000ff));
    else
        dpp_expect_source(UINT32_C(0xff00ff00));
    uint64_t after;
    require([cache sourceVersionAtAddress:32768
                                   length:256
                                  version:&after
                                    error:&error],
            error);
    assert(after == version);
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t count = report_value(0);
    assert(count && pg->draw_time == 1);
    NSMutableData *actual = [cpp_capture(count) mutableCopy];
    [actual appendData:begin];
    [actual appendData:pending];
    [actual appendData:vertex];
    if (write) {
        pg->draw_arrays_length = 1;
        require([draw beginWithError:&error], error);
        NV2AMetalPGRAPHPixelState *fresh = [draw valueForKey:@"pixelState"];
        assert([fresh.textureSnapshot textureAtIndex:0].binding.texture !=
               snapshot.binding.texture);
        require([draw endWithError:&error] && [cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error] &&
                    [cache prepareCPUAccessAtAddress:1024
                                              length:256
                                               write:NO
                                               error:&error] &&
                    [cache prepareCPUAccessAtAddress:4096
                                              length:256
                                               write:NO
                                               error:&error],
                error);
        color(1, 1, UINT32_C(0xff0000ff));
        dpp_expect_texture(snapshot);
        require([draw.reports getReport:1u << 24 error:&error] &&
                    [draw.reports processWithError:&error],
                error);
        count = report_value(0);
        assert(count && pg->draw_time == 2);
        [actual appendData:cpp_capture(count)];
    }
    qemu_mutex_unlock(&pg->lock);
    cpp_tail = nil;
    cpp_blocker = cpp_commands = nil;
    cpp_queue = nil;
    cpp_gate = nil;
    return actual;
}
static void download_prefix_pgraph_tests(void)
{
    fixture();
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:NULL];
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id nativeQueue = object_getIvar(probe, queue);
    Method methods[] = {
        class_getInstanceMethod(object_getClass(nativeQueue),
                                @selector(commit:count:options:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitUntilIdleWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                @selector(prepareRasterPass:targets:error:)),
        class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                sel_registerName("canOwnDownloadPrefix:"))
    };
    IMP replacements[] = { (IMP)cpp_commit, (IMP)cpp_wait,   (IMP)cpp_producers,
                           (IMP)cpp_idle,   (IMP)cpp_submit, (IMP)cpp_raster,
                           (IMP)dpp_can_own },
        originals[7];
    for (unsigned i = 0; i < 7; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    cpp_commit_original = (void *)originals[0];
    cpp_wait_original = (void *)originals[1];
    cpp_producers_original = (void *)originals[2];
    cpp_idle_original = (void *)originals[3];
    cpp_full_original = (void *)originals[4];
    cpp_raster_original = (void *)originals[5];
    dpp_can_own_original = (void *)originals[6];
    for (unsigned i = 0; i < 7; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned write = 0; write < 2; write++) {
            NSData *old = dpp_run(write, YES);
            NSData *actual = dpp_run(write, NO);
            assert([old isEqualToData:actual]);
        }
    } @finally {
        if (cpp_gate)
            cpp_gate.signaledValue = 1;
        for (unsigned i = 0; i < 7; i++)
            method_setImplementation(methods[i], originals[i]);
        dpp_reference = NO;
        cpp_inject = cpp_release_on_wait = NO;
        cpp_tail = nil;
        cpp_commands = cpp_blocker = nil;
        cpp_queue = nil;
        cpp_gate = nil;
    }
    groups += 2;
    puts("Download prefix PGRAPH:2 actual incompatible signed-R A8 texture "
         "Scale2-source/Scale1-texture Begin download+GPUupload heads; "
         "CPUread/write sees opaque GPUgreen/CPUblue with sampled alpha1, "
         "immutable texture alpha1, Gate0/noFull/pending disjoint raster, "
         "exact framebuffer/zeta/Current/constants/query/snapshots and fresh "
         "CPUblue sampling match conservative full-submit reference PASS");
}
#endif
