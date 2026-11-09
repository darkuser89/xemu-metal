/* CPU conflicts retire only the necessary producer hazards.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CPU_PREFIX_H
#define TEST_METAL_CPU_PREFIX_H
#include <stdatomic.h>

/* Read the private page counters without invoking a CPU pre-write callback.
 * A successful try_cpu_access(write:YES) would publish deferred dirty bits. */
struct NV2AMetalCPUAccessGuard {
    NSUInteger length, words;
    atomic_bool failed;
    _Atomic(uint64_t) watched[];
};
static BOOL cpu_prefix_write_allowed(NV2AMetalSurfaceCache *cache,
                                     NSUInteger address, NSUInteger length,
                                     BOOL write)
{
    assert(write && length && address + length <= cache.vram.length);
    const NV2AMetalCPUAccessGuard *guard = cache.cpuAccessGuard;
    assert(guard->length == cache.vram.length && guard->words);
    if (atomic_load_explicit(&guard->failed, memory_order_acquire))
        return NO;
    const _Atomic(uint64_t) *readers = guard->watched + 3 * guard->words;
    NSUInteger pages = (guard->length - 1) / 4096 + 1;
    const _Atomic(uint64_t) *targets = readers + pages;
    for (NSUInteger page = address / 4096;
         page <= (address + length - 1) / 4096; page++) {
        if (atomic_load_explicit(&targets[page], memory_order_acquire) ||
            atomic_load_explicit(&readers[page], memory_order_acquire))
            return NO;
    }
    return YES;
}

@interface CPUPrefixCommands : SurfacePrefixCommands
@property(nonatomic) NSUInteger lastCut;
@property(nonatomic) BOOL rejectPrefix;
@property(nonatomic) BOOL rejectFull;
@property(nonatomic) unsigned rejectedFullCalls;
@end
@implementation CPUPrefixCommands
- (BOOL)submitWithError:(NSError **)error
{
    if (_rejectFull) {
        _rejectFull = NO;
        _rejectedFullCalls++;
        if (error)
            *error = [NSError errorWithDomain:@"test.cpu-prefix.full-submit"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return [super submitWithError:error];
}
- (NV2AMetalSubmission *)submitProducersThroughSectionCount:(NSUInteger)count
                                                batchSerial:(uint64_t)serial
                                                      error:(NSError **)error
{
    _lastCut = count;
    if (_rejectPrefix) {
        _rejectPrefix = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.cpu-prefix.encode"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return [super submitProducersThroughSectionCount:count
                                         batchSerial:serial
                                               error:error];
}
@end

static NV2AMetalSurfaceCache *cpu_prefix_cache(id<MTLDevice> device,
                                               CPUPrefixCommands **commands,
                                               unsigned *notifications)
{
    NSError *error = nil;
    *commands = [[CPUPrefixCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(*commands && ram, error);
    memset(ram.contents, 0x37, ram.length);
    NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:*commands
                    vram:ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address < 65536 && length && length <= 65536 - address);
              (*notifications)++;
            }
                   error:&error];
    require(cache != nil, error);
    return cache;
}

/* Genuine raster work, independent of Surface metadata. */
static id<MTLTexture> cpu_prefix_raster(NV2AMetalSurfaceCache *cache)
{
    NSError *error = nil;
    require([cache beginRasterProducersWithError:&error], error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [cache.commands.device newTextureWithDescriptor:td];
    const uint32_t zero[16] = { 0 };
    assert(color);
    [color replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0
               withBytes:zero
             bytesPerRow:16];
    require([cache.commands addResource:color error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:cache.commands.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(pixel != nil, error);
    NV2AMetalVertex point = { 0 };
    point.clip[2] = .5f;
    point.clip[3] = 1;
    point.point_size = 1;
    point.screen[0] = point.screen[1] = 2;
    point.color[0][1] = point.color[0][3] = 1;
    id<MTLBuffer> vertices =
        [cache.commands.device newBufferWithBytes:&point
                                           length:sizeof(point)
                                          options:MTLResourceStorageModeShared];
    assert(vertices);
    NV2AMetalPixelUniforms uniforms = { 0 };
    uniforms.combiner.final_inputs[0] = PS_REGISTER_V0;
    uniforms.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                        << 8;
    uniforms.smooth_shading = 1;
    uniforms.depth_format = NV2AMetalPixelDepthD24;
    uniforms.surface_scale[0] = uniforms.surface_scale[1] = 1;
    uniforms.clip_range[1] = uniforms.clip_range[3] = 16777215;
    uniforms.clip_regions[0][2] = uniforms.clip_regions[0][3] = 4;
    for (unsigned k = 0; k < 4; k++) {
        uniforms.textures[k].dimension = 2;
        uniforms.textures[k].scale = 1;
    }
    NV2AMetalDrawConfig config = { 0 };
    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:cache.commands.device
                                            config:&config
                                             error:&error];
    require(state != nil, error);
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTL4RenderCommandEncoder> encoder =
        [cache.commands beginRasterPass:pass error:&error];
    require(encoder != nil, error);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    require([pixel encodeVertices:vertices
                              offset:0
                               count:1
                           primitive:MTLPrimitiveTypePoint
                            uniforms:&uniforms
                            textures:textures
                                pass:pass
                           drawState:state
                         rasterClass:NV2AMetalPixelRasterDirectPoint
                ignorePolygonCulling:NO
                       renderEncoder:encoder
                            commands:cache.commands
                               error:&error],
            error);
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    [cache endRasterProducers];
    return color;
}
static void cpu_prefix_color(id<MTLTexture> color, uint32_t expected)
{
    uint32_t words[16];
    [color getBytes:words
        bytesPerRow:16
         fromRegion:MTLRegionMake2D(0, 0, 4, 4)
        mipmapLevel:0];
    unsigned green = 0;
    for (unsigned i = 0; i < 16; i++) {
        assert(words[i] == 0 || words[i] == expected);
        green += words[i] == UINT32_C(0xff00ff00);
    }
    assert(green == (expected ? 1 : 0));
}

static void cpu_prefix_scope_tests(id<MTLDevice> device)
{
    for (unsigned snapshot = 0; snapshot < 2; snapshot++) {
        for (unsigned samePage = 0; samePage < 2; samePage++) {
            @autoreleasepool {
                NSError *error = nil;
                unsigned notifications = 0;
                CPUPrefixCommands *commands = nil;
                NV2AMetalSurfaceCache *cache =
                    cpu_prefix_cache(device, &commands, &notifications);
                const NSUInteger a = 16380, b = 32768;
                const NSUInteger tailRead = samePage ? b + 64 : 49152;
                id<MTLBuffer> headCopy = encode_vram_copy(cache, b, 8);
                gpu_dep_write(cache, a, UINT64_C(0x0123456789abcdef));
                NV2AMetalSurfaceRecording *head = cache.recording;
                require([cache checkpointWithError:&error], error);
                if (snapshot) {
                    require([cache waitForProducersOfRecording:head
                                                         error:&error],
                            error);
                    assert(head.producersCompleted && !head.cpuHazardsRetired &&
                           !cpu_prefix_write_allowed(cache, b, 8, YES));
                }
                IndependentReadCommands *late =
                    [[IndependentReadCommands alloc] initWithDevice:device
                                                              error:&error];
                require(late != nil, error);
                gpu_dep_gate(late);
                id<MTLBuffer> lateCopy = nil;
                (void)gpu_dep_read(cache, late, 57344, &lateCopy);
                gpu_dep_write(cache, 24576, UINT64_C(0xfedcba9876543210));
                require([commands orderAfterSubmission:late.lastSubmitted
                                          fromCommands:late
                                                 error:&error],
                        error);
                id<MTLBuffer> tailCopy = encode_vram_copy(cache, tailRead, 8);
                id<MTLTexture> color = cpu_prefix_raster(cache);
                NV2AMetalSurfaceRecording *tail = cache.recording;
                require([cache checkpointWithError:&error], error);
                unsigned lateWaits = late.waits;
                require([cache resolveCPUAccessAtAddress:a
                                                  length:8
                                                   write:NO
                                                   error:&error],
                        error);
                assert(!late.gate.signaledValue && late.waits == lateWaits &&
                       commands.prefixCalls == 1 && commands.lastCut == 1 &&
                       !commands.fullCalls && head.cpuHazardsRetired &&
                       head.producersCompleted && !head.completed &&
                       !head.submitted && !tail.cpuHazardsRetired &&
                       !tail.producersCompleted && !tail.submitted &&
                       commands.hasPendingRasterPass && !notifications &&
                       gpu_dep_word(cache.vram, a) ==
                           UINT64_C(0x0123456789abcdef) &&
                       gpu_dep_word(cache.vram, 24576) ==
                           UINT64_C(0x3737373737373737) &&
                       gpu_dep_word(headCopy, 0) ==
                           UINT64_C(0x3737373737373737));
                cpu_prefix_color(color, 0);
                /* A Tail span on the same page keeps the conservative guard. */
                assert(cpu_prefix_write_allowed(cache, b, 8, YES) == !samePage);
                assert(!cpu_prefix_write_allowed(cache, tailRead, 8, YES));
                unsigned waits = commands.waits;
                require([cache resolveCPUAccessAtAddress:a
                                                  length:8
                                                   write:NO
                                                   error:&error] &&
                            [cache resolveCPUAccessAtAddress:b
                                                      length:8
                                                       write:YES
                                                       error:&error],
                        error);
                const uint64_t cpuWord = UINT64_C(0xdeadbeef0badf00d);
                memcpy((uint8_t *)cache.vram.contents + b, &cpuWord, 8);
                assert(commands.prefixCalls == 1 && !commands.fullCalls &&
                       commands.waits == waits && !late.gate.signaledValue);
                late.gate.signaledValue = 1;
                require([cache submitWithError:&error] &&
                            [cache waitForRecording:tail error:&error],
                        error);
                assert(head.completed && tail.completed &&
                       gpu_dep_word(cache.vram, b) == cpuWord &&
                       gpu_dep_word(tailCopy, 0) ==
                           UINT64_C(0x3737373737373737) &&
                       gpu_dep_word(cache.vram, 24576) ==
                           UINT64_C(0xfedcba9876543210) &&
                       cpu_prefix_write_allowed(cache, tailRead, 8, YES));
                cpu_prefix_color(color, UINT32_C(0xff00ff00));
                checks++;
            }
        }
    }
}

static void cpu_prefix_last_conflict_tests(id<MTLDevice> device)
{
    for (unsigned write = 0; write < 2; write++) {
        NSError *error = nil;
        unsigned notifications = 0;
        CPUPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            cpu_prefix_cache(device, &commands, &notifications);
        NV2AMetalSurfaceRecording *tokens[3];
        for (unsigned i = 0; i < 3; i++) {
            if (write)
                (void)encode_vram_copy(cache, i < 2 ? 16384 : 24576, 8);
            else
                gpu_dep_write(cache, i < 2 ? 16384 : 24576, 0x1111u + i);
            tokens[i] = cache.recording;
            require([cache checkpointWithError:&error], error);
        }
        require([cache resolveCPUAccessAtAddress:16384
                                          length:8
                                           write:write
                                           error:&error],
                error);
        assert(commands.lastCut == 2 && commands.prefixCalls == 1 &&
               !commands.fullCalls && tokens[0].cpuHazardsRetired &&
               tokens[1].cpuHazardsRetired && !tokens[2].cpuHazardsRetired &&
               !tokens[2].producersCompleted && !tokens[0].completed);
        if (!write)
            assert(gpu_dep_word(cache.vram, 16384) == 0x1112 &&
                   gpu_dep_word(cache.vram, 24576) ==
                       UINT64_C(0x3737373737373737));
        require([cache submitWithError:&error] &&
                    [cache waitForRecording:tokens[2] error:&error],
                error);
        checks++;
    }
}

static void cpu_prefix_failure_tests(id<MTLDevice> device)
{
    for (unsigned earlier = 0; earlier < 2; earlier++) {
        NSError *error = nil;
        unsigned notifications = 0;
        CPUPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            cpu_prefix_cache(device, &commands, &notifications);
        NSError *oldFailure = [NSError errorWithDomain:@"test.cpu-prefix.old"
                                                  code:1
                                              userInfo:nil];
        NSError *headFailure = [NSError errorWithDomain:@"test.cpu-prefix.head"
                                                   code:2
                                               userInfo:nil];
        if (earlier) {
            gpu_dep_write(cache, 8192, 42);
            require([cache submitWithError:&error] &&
                        [commands waitForSubmission:commands.lastSubmitted
                                              error:&error],
                    error);
            NSArray *entries = [cache valueForKey:@"submissions"];
            CountedIndependentReadReceipt *old =
                [CountedIndependentReadReceipt new];
            old.nativeSubmission = commands.lastSubmitted;
            old.failure = oldFailure;
            [entries.lastObject setValue:old forKey:@"submission"];
        }
        (void)encode_vram_copy(cache, 32768, 8);
        gpu_dep_write(cache, 16384, 99);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        gpu_dep_write(cache, 24576, 77);
        commands.prefixFailure = headFailure;
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:8
                                           write:NO
                                           error:&error] &&
               error == (earlier ? oldFailure : headFailure) &&
               !head.cpuHazardsRetired && !head.completed &&
               !cpu_prefix_write_allowed(cache, 32768, 8, YES) &&
               !notifications);
        if (earlier)
            assert(!commands.injectedReceipt.polls);
        NSError *sticky = error;
        error = nil;
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:8
                                           write:NO
                                           error:&error] &&
               error == sticky);
        NV2AMetalSubmission *native = commands.injectedReceipt.nativeSubmission;
        [commands cancel];
        commands.prefixFailure = nil;
        require([commands waitForSubmission:native error:&error], error);
        checks++;
    }
}
static void cpu_prefix_retry_cancel_tests(id<MTLDevice> device)
{
    for (unsigned restore = 0; restore < 2; restore++) {
        NSError *error = nil;
        unsigned notifications = 0;
        CPUPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            cpu_prefix_cache(device, &commands, &notifications);
        gpu_dep_write(cache, 16384, 123);
        (void)encode_vram_copy(cache, 32768, 8);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        commands.rejectPrefix = YES;
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:8
                                           write:NO
                                           error:&error] &&
               error && !head.cpuHazardsRetired && !head.producersCompleted &&
               !commands.prefixCalls && !commands.fullCalls &&
               gpu_dep_word(cache.vram, 16384) == UINT64_C(0x3737373737373737));
        error = nil;
        require([cache resolveCPUAccessAtAddress:16384
                                          length:8
                                           write:NO
                                           error:&error],
                error);
        assert(head.cpuHazardsRetired && commands.prefixCalls == 1);
        gpu_dep_write(cache, 24576, UINT64_MAX);
        (void)encode_vram_copy(cache, 32768, 8);
        NV2AMetalSurfaceRecording *tail = cache.recording;
        if (restore)
            require([cache discardForRestoreWithError:&error], error);
        else
            [cache cancel];
        assert(tail.cancelled && gpu_dep_word(cache.vram, 16384) == 123 &&
               gpu_dep_word(cache.vram, 24576) ==
                   UINT64_C(0x3737373737373737) &&
               !notifications);
        gpu_dep_write(cache, 24576, 456);
        id<MTLBuffer> retryCopy = encode_vram_copy(cache, 32768, 8);
        assert(!cpu_prefix_write_allowed(cache, 32768, 8, YES));
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(gpu_dep_word(cache.vram, 16384) == 123 &&
               gpu_dep_word(cache.vram, 24576) == 456 &&
               gpu_dep_word(retryCopy, 0) == UINT64_C(0x3737373737373737) &&
               cpu_prefix_write_allowed(cache, 32768, 8, YES));
        checks++;
    }
}

static void cpu_prefix_fallback_tests(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 3; mode++) {
        NSError *error = nil;
        unsigned notifications = 0;
        CPUPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            cpu_prefix_cache(device, &commands, &notifications);
        NV2AMetalSurfaceConfig cfg =
            config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
        NV2AMetalCachedSurface *surface =
            [cache prepareSurfaceAtAddress:16384
                                    config:&cfg
                                     frame:0
                                     error:&error];
        require(surface != nil, error);
        clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        gpu_dep_write(cache, 24576, 456);
        if (mode == 0)
            require([cache resolveCPUAccessAtAddress:16384
                                              length:4
                                               write:NO
                                               error:&error],
                    error);
        else if (mode == 1)
            require([cache resolveCPUAccessAtAddress:16384
                                              length:4
                                               write:YES
                                               error:&error],
                    error);
        else
            require([cache prepareCPUAccessAtAddress:16384
                                              length:4
                                               write:NO
                                               error:&error],
                    error);
        assert(commands.fullCalls == 1 && !commands.prefixCalls &&
               head.completed &&
               (uint32_t)gpu_dep_word(cache.vram, 16384) == 0xff00ff00 &&
               gpu_dep_word(cache.vram, 24576) == 456 && notifications == 1);
        checks++;
    }
}

static void cpu_prefix_witness_tests(id<MTLDevice> device)
{
    for (unsigned failure = 0; failure < 2; failure++) {
        NSError *error = nil;
        unsigned notifications = 0;
        CPUPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            cpu_prefix_cache(device, &commands, &notifications);
        IndependentReadCommands *early =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        IndependentReadCommands *late =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        require(early && late, error);
        id<MTLBuffer> earlyCopy = nil, lateCopy = nil;
        NV2AMetalIndependentReads *first =
            surface_prefix_reader(cache, early, 16384, &earlyCopy);
        gpu_dep_write(cache, 16384, 123);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        gpu_dep_gate(late);
        NV2AMetalIndependentReads *second =
            surface_prefix_reader(cache, late, 24576, &lateCopy);
        /* Open the Tail before adding its new reader dependency. With no
         * recording, submitAcceptedPrefixBeforeReaders deliberately flushes
         * the sealed Head before introducing that dependency. */
        require([cache prepareGPUReadAtAddress:57344 length:8 error:&error],
                error);
        gpu_dep_write(cache, 24576, 456);
        NV2AMetalSurfaceRecording *tail = cache.recording;
        require([cache checkpointWithError:&error], error);
        NSArray *witnesses = [[cache valueForKey:@"pendingReadWitnesses"] copy];
        assert(witnesses.count == 2);
        id page = [witnesses[0] valueForKey:@"observed"];
        assert(page && [witnesses[1] valueForKey:@"observed"] == page);
        CountedIndependentReadReceipt *later =
            [CountedIndependentReadReceipt new];
        later.nativeSubmission = late.lastSubmitted;
        later.waitForNativeFeedback = YES;
        later.ready = failure;
        NSError *laterFailure = [NSError errorWithDomain:@"test.cpu-prefix.tail"
                                                    code:3
                                                userInfo:nil];
        later.failure = failure ? laterFailure : nil;
        [second setValue:later forKey:@"submission"];
        unsigned polls = later.polls;
        require([cache resolveCPUAccessAtAddress:16384
                                          length:8
                                           write:NO
                                           error:&error],
                error);
        assert(head.cpuHazardsRetired && !tail.cpuHazardsRetired &&
               !later.polls && polls == later.polls && !late.waits &&
               !late.gate.signaledValue &&
               [[witnesses[0] valueForKey:@"validated"] boolValue] &&
               ![[witnesses[1] valueForKey:@"validated"] boolValue] &&
               [witnesses[0] valueForKey:@"observed"] == page &&
               gpu_dep_word(earlyCopy, 0) == UINT64_C(0x3737373737373737));
        require([cache completeIndependentReads:first error:&error], error);
        late.gate.signaledValue = 1;
        if (failure) {
            assert(![cache resolveCPUAccessAtAddress:24576
                                              length:8
                                               write:NO
                                               error:&error] &&
                   error == laterFailure && !tail.cpuHazardsRetired);
            [commands cancel];
            require([late waitForSubmission:late.lastSubmitted error:&error],
                    error);
            NV2AMetalSubmission *submitted =
                [tail valueForKey:@"producerSubmission"];
            if (submitted)
                require([commands waitForSubmission:submitted error:&error],
                        error);
        } else {
            /* Append another marker in the still-owned arena after the Head
             * witness has been checked; this catches premature page release. */
            IndependentReadCommands *thirdQueue =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            require(thirdQueue != nil, error);
            id<MTLBuffer> thirdCopy = nil;
            NV2AMetalIndependentReads *third =
                surface_prefix_reader(cache, thirdQueue, 32768, &thirdCopy);
            require([cache prepareGPUReadAtAddress:57344 length:8 error:&error],
                    error);
            gpu_dep_write(cache, 32768, 789);
            NSArray *all = [cache valueForKey:@"pendingReadWitnesses"];
            assert(all.count == 3 && [all[2] valueForKey:@"observed"] == page);
            require([cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error] &&
                        [cache completeIndependentReads:third error:&error],
                    error);
            assert(gpu_dep_word(cache.vram, 24576) == 456 &&
                   gpu_dep_word(cache.vram, 32768) == 789 &&
                   gpu_dep_word(lateCopy, 0) == UINT64_C(0x3737373737373737) &&
                   gpu_dep_word(thirdCopy, 0) == UINT64_C(0x3737373737373737));
        }
        assert(!notifications);
        checks++;
    }
}

static NSData *cpu_prefix_final_bytes(id<MTLDevice> device, BOOL prefix,
                                      uint64_t *version)
{
    NSError *error = nil;
    unsigned notifications = 0;
    CPUPrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache =
        cpu_prefix_cache(device, &commands, &notifications);
    require([cache sourceVersionAtAddress:32768
                                   length:8
                                  version:version
                                    error:&error],
            error);
    gpu_dep_write(cache, 16384, UINT64_C(0x0123456789abcdef));
    id<MTLBuffer> first = encode_vram_copy(cache, 32768, 8);
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error], error);
    gpu_dep_write(cache, 24576, UINT64_C(0xfedcba9876543210));
    id<MTLBuffer> tail = encode_vram_copy(cache, 49152, 8);
    require([cache checkpointWithError:&error], error);
    if (prefix)
        require([cache resolveCPUAccessAtAddress:32768
                                          length:8
                                           write:YES
                                           error:&error],
                error);
    else
        require([cache prepareCPUAccessAtAddress:32768
                                          length:8
                                           write:YES
                                           error:&error],
                error);
    assert(prefix ? (head.cpuHazardsRetired && !head.completed &&
                     commands.prefixCalls == 1 && !commands.fullCalls) :
                    (head.completed && !commands.prefixCalls));
    const uint64_t cpuWord = UINT64_C(0xdeadbeef0badf00d);
    memcpy((uint8_t *)cache.vram.contents + 32768, &cpuWord, 8);
    id<MTLBuffer> after = encode_vram_copy(cache, 32768, 8);
    NV2AMetalSurfaceConfig cfg =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:4096
                                                              config:&cfg
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    require([cache flushWithError:&error], error);
    assert(head.completed && notifications == 1 &&
           gpu_dep_word(first, 0) == UINT64_C(0x3737373737373737) &&
           gpu_dep_word(tail, 0) == UINT64_C(0x3737373737373737) &&
           gpu_dep_word(after, 0) == cpuWord &&
           cpu_prefix_write_allowed(cache, 32768, 8, YES));
    require([cache sourceVersionAtAddress:32768
                                   length:8
                                  version:version
                                    error:&error],
            error);
    return [NSData dataWithBytes:cache.vram.contents length:cache.vram.length];
}
static void cpu_prefix_boundary_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    CPUPrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache =
        cpu_prefix_cache(device, &commands, &notifications);
    gpu_dep_write(cache, 16384, 123);
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error], error);
    require([cache resolveCPUAccessAtAddress:16376
                                      length:8
                                       write:NO
                                       error:&error] &&
                [cache resolveCPUAccessAtAddress:16392
                                          length:8
                                           write:NO
                                           error:&error] &&
                [cache resolveCPUAccessAtAddress:16384
                                          length:0
                                           write:YES
                                           error:&error],
            error);
    assert(!commands.prefixCalls && !commands.fullCalls && !commands.waits &&
           !head.cpuHazardsRetired && !head.producersCompleted);
    assert(![cache resolveCPUAccessAtAddress:65532
                                      length:8
                                       write:NO
                                       error:&error] &&
           error && !commands.prefixCalls && !commands.fullCalls);
    error = nil;
    require([cache resolveCPUAccessAtAddress:16388
                                      length:1
                                       write:NO
                                       error:&error],
            error);
    assert(head.cpuHazardsRetired && commands.prefixCalls == 1);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    uint64_t prefixVersion = 0, referenceVersion = 0;
    NSData *actual = cpu_prefix_final_bytes(device, YES, &prefixVersion);
    NSData *reference = cpu_prefix_final_bytes(device, NO, &referenceVersion);
    assert([actual isEqualToData:reference] &&
           prefixVersion == referenceVersion);
    checks++;
}

static void cpu_prefix_reader_error_priority_tests(id<MTLDevice> device)
{
    for (unsigned full = 0; full < 2; full++) {
        NSError *error = nil;
        unsigned notifications = 0;
        CPUPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            cpu_prefix_cache(device, &commands, &notifications);
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        require(source != nil, error);
        id<MTLBuffer> independentCopy = nil;
        NV2AMetalIndependentReads *reader =
            gpu_dep_read(cache, source, 16384, &independentCopy);
        CountedIndependentReadReceipt *sourceReceipt =
            [CountedIndependentReadReceipt new];
        sourceReceipt.nativeSubmission = source.lastSubmitted;
        sourceReceipt.waitForNativeFeedback = YES;
        sourceReceipt.failure =
            [NSError errorWithDomain:@"test.cpu-prefix.reader-first"
                                code:1
                            userInfo:nil];
        [reader setValue:sourceReceipt forKey:@"submission"];
        id<MTLBuffer> headCopy = encode_vram_copy(cache, 16384, 8);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        NSError *headFailure =
            [NSError errorWithDomain:@"test.cpu-prefix.head-second"
                                code:2
                            userInfo:nil];
        CountedIndependentReadReceipt *fullReceipt = nil;
        if (full) {
            require([cache submitWithError:&error], error);
            fullReceipt = [CountedIndependentReadReceipt new];
            fullReceipt.nativeSubmission = commands.lastSubmitted;
            fullReceipt.failure = headFailure;
            NSArray *entries = [cache valueForKey:@"submissions"];
            [entries.lastObject setValue:fullReceipt forKey:@"submission"];
        } else {
            commands.prefixFailure = headFailure;
        }
        assert(![cache resolveCPUAccessAtAddress:16384
                                          length:8
                                           write:YES
                                           error:&error] &&
               error == sourceReceipt.failure && source.waits == 1 &&
               !head.cpuHazardsRetired && !head.completed &&
               !cpu_prefix_write_allowed(cache, 16384, 8, YES) &&
               commands.prefixCalls == !full && commands.fullCalls == full);
        CountedIndependentReadReceipt *headReceipt =
            full ? fullReceipt : commands.injectedReceipt;
        assert(headReceipt && !headReceipt.polls && !notifications);
        /* Drain real work for test resource lifetime, without publishing the
         * failed Surface transaction or hiding the expected first error. */
        [commands cancel];
        require([commands waitForSubmission:headReceipt.nativeSubmission
                                      error:&error],
                error);
        assert(gpu_dep_word(headCopy, 0) == UINT64_C(0x3737373737373737) &&
               gpu_dep_word(independentCopy, 0) ==
                   UINT64_C(0x3737373737373737));
        checks++;
    }
}

static void cpu_prefix_raster_fallback_test(id<MTLDevice> device)
{
    NSError *error = nil;
    unsigned notifications = 0;
    CPUPrefixCommands *commands = nil;
    NV2AMetalSurfaceCache *cache =
        cpu_prefix_cache(device, &commands, &notifications);
    (void)encode_vram_copy(cache, 32768, 8);
    gpu_dep_write(cache, 16384, 123);
    id<MTLTexture> color = cpu_prefix_raster(cache);
    NV2AMetalSurfaceRecording *head = cache.recording;
    require([cache checkpointWithError:&error] &&
                [cache beginRasterProducersWithError:&error],
            error);
    gpu_dep_write(cache, 16384, 456);
    NV2AMetalSurfaceRecording *tail = cache.recording;
    [cache endRasterProducers];
    assert(commands.hasPendingRasterPass && !commands.fullCalls &&
           !commands.prefixCalls);
    cpu_prefix_color(color, 0);
    require([cache resolveCPUAccessAtAddress:16384
                                      length:8
                                       write:NO
                                       error:&error],
            error);
    assert(commands.fullCalls == 1 && !commands.prefixCalls && head.completed &&
           tail.completed && !head.cpuHazardsRetired && !notifications &&
           gpu_dep_word(cache.vram, 16384) == 456 &&
           cpu_prefix_write_allowed(cache, 32768, 8, YES));
    cpu_prefix_color(color, UINT32_C(0xff00ff00));
    checks++;
}

static void cpu_prefix_fallback_rollback_tests(id<MTLDevice> device)
{
    for (unsigned raster = 0; raster < 2; raster++) {
        NSError *error = nil;
        unsigned notifications = 0;
        CPUPrefixCommands *commands = nil;
        NV2AMetalSurfaceCache *cache =
            cpu_prefix_cache(device, &commands, &notifications);
        gpu_dep_write(cache, 16384, 123);
        if (raster)
            gpu_dep_write(cache, 24576, 123);
        NV2AMetalSurfaceRecording *head = cache.recording;
        require([cache checkpointWithError:&error], error);
        gpu_dep_write(cache, 24576, UINT64_MAX);
        (void)encode_vram_copy(cache, 32768, 8);
        NV2AMetalSurfaceConfig cfg =
            config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
        id<MTLTexture> cancelledColor = nil;
        if (raster) {
            cancelledColor = cpu_prefix_raster(cache);
        } else {
            NV2AMetalCachedSurface *surface =
                [cache prepareSurfaceAtAddress:4096
                                        config:&cfg
                                         frame:0
                                         error:&error];
            require(surface != nil, error);
            clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
        }
        NV2AMetalSurfaceRecording *tail = cache.recording;
        id<MTL4CommandBuffer> openBuffer = commands.commandBuffer;
        assert(tail && tail != head && openBuffer);
        commands.rejectFull = YES;
        assert(![cache resolveCPUAccessAtAddress:raster ? 24576 : 4096
                                          length:raster ? 8 : 4
                                           write:NO
                                           error:&error] &&
               [error.domain isEqualToString:@"test.cpu-prefix.full-submit"] &&
               cache.recording == tail &&
               commands.commandBuffer == openBuffer && !tail.submitted &&
               !tail.completed && !tail.cancelled && !head.submitted &&
               !head.completed && !head.cancelled && !commands.prefixCalls &&
               !commands.fullCalls && commands.rejectedFullCalls == 1);
        [cache cancel];
        assert(
            tail.cancelled && !head.cancelled && !head.submitted &&
            !cache.recording && commands.sealedBufferCount == 1 &&
            !commands.hasPendingRasterPass && !notifications &&
            gpu_dep_word(cache.vram, 16384) == UINT64_C(0x3737373737373737) &&
            gpu_dep_word(cache.vram, 24576) == UINT64_C(0x3737373737373737) &&
            gpu_dep_word(cache.vram, 4096) == UINT64_C(0x3737373737373737) &&
            cpu_prefix_write_allowed(cache, 32768, 8, YES));
        if (raster)
            cpu_prefix_color(cancelledColor, 0);
        error = nil;
        gpu_dep_write(cache, 24576, 456);
        id<MTLBuffer> retryRead = encode_vram_copy(cache, 32768, 8);
        id<MTLTexture> retryColor = nil;
        if (raster) {
            retryColor = cpu_prefix_raster(cache);
        } else {
            NV2AMetalCachedSurface *surface =
                [cache prepareSurfaceAtAddress:4096
                                        config:&cfg
                                         frame:0
                                         error:&error];
            require(surface != nil, error);
            clear_surface(cache, surface, MTLClearColorMake(0, 0, 1, 1), 0, 0);
        }
        NV2AMetalSurfaceRecording *retry = cache.recording;
        require([cache resolveCPUAccessAtAddress:raster ? 24576 : 4096
                                          length:raster ? 8 : 4
                                           write:NO
                                           error:&error],
                error);
        assert(head.completed && retry.completed && tail.cancelled &&
               commands.fullCalls == 1 && !commands.prefixCalls &&
               commands.rejectedFullCalls == 1 &&
               gpu_dep_word(cache.vram, 16384) == 123 &&
               gpu_dep_word(cache.vram, 24576) == 456 &&
               gpu_dep_word(retryRead, 0) == UINT64_C(0x3737373737373737) &&
               cpu_prefix_write_allowed(cache, 32768, 8, YES));
        if (raster) {
            cpu_prefix_color(cancelledColor, 0);
            cpu_prefix_color(retryColor, UINT32_C(0xff00ff00));
            assert(!notifications);
        } else {
            assert((uint32_t)gpu_dep_word(cache.vram, 4096) == 0xff0000ff &&
                   notifications == 1);
        }
        checks++;
    }
}

static void cpu_prefix_tests(id<MTLDevice> device)
{
    unsigned before = checks;
    cpu_prefix_scope_tests(device);
    cpu_prefix_last_conflict_tests(device);
    cpu_prefix_failure_tests(device);
    cpu_prefix_retry_cancel_tests(device);
    cpu_prefix_fallback_tests(device);
    cpu_prefix_witness_tests(device);
    cpu_prefix_boundary_tests(device);
    cpu_prefix_reader_error_priority_tests(device);
    cpu_prefix_raster_fallback_test(device);
    cpu_prefix_fallback_rollback_tests(device);
    printf(
        "Metal CPU conflict prefix: %u groups PASS; Gate0 Head bytes, "
        "Tail producer/raster preservation, exact last conflict, page guards, "
        "Snapshot-first retirement, idempotence, ordered failures, retry, "
        "cancel/restore and Surface/download fallback\n",
        checks - before);
}
#endif
