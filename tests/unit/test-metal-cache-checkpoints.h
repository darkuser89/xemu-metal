/* Accepted Metal sections, suffix rollback and bounded native commits.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CACHE_CHECKPOINTS_H
#define TEST_METAL_CACHE_CHECKPOINTS_H

@interface CheckpointCommands : NV2AMetalCommands
@property(nonatomic) NSMutableArray<NSNumber *> *batchSizes;
@end
@implementation CheckpointCommands
- (BOOL)submitWithError:(NSError **)error
{
    NSUInteger count = self.sealedBufferCount + (self.commandBuffer != nil);
    BOOL ok = [super submitWithError:error];
    if (ok) {
        if (!_batchSizes)
            _batchSizes = [NSMutableArray new];
        [_batchSizes addObject:@(count)];
    }
    return ok;
}
@end
static void cache_checkpoint_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    CheckpointCommands *commands =
        [[CheckpointCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    id<MTLBuffer> ram =
        [device newBufferWithLength:32768 options:MTLResourceStorageModeShared];
    assert(ram);
    memset(ram.contents, 0x5a, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    id<MTLBuffer> first = encode_vram_copy(cache, 0, 4);
    NV2AMetalSurfaceRecording *prefix = cache.recording;
    require([cache checkpointWithError:&error], error);
    assert(!prefix.submitted && !prefix.cancelled && !commands.commandBuffer &&
           commands.sealedBufferCount == 1 && !commands.lastSubmitted);
    assert(![cache waitUntilIdleWithError:&error]);
    (void)encode_vram_copy(cache, 4096, 4);
    NV2AMetalSurfaceRecording *aborted = cache.recording;
    [cache cancel];
    assert(aborted.cancelled && !prefix.cancelled &&
           commands.sealedBufferCount == 1);
    for (unsigned attempt = 0; attempt < 40; attempt++) {
        (void)encode_vram_copy(cache, 4096, 4);
        NV2AMetalSurfaceRecording *suffix = cache.recording;
        [cache cancel];
        assert(suffix.cancelled && !prefix.cancelled &&
               commands.sealedBufferCount == 1);
    }
    BOOL completed = YES;
    require([cache tryIdleCPUAccessAtAddress:0
                                      length:4
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(!completed);
    require([cache prepareCPUAccessAtAddress:4096
                                      length:4
                                       write:YES
                                       error:&error],
            error);
    /* A CPU access is an actual submission boundary, even when it addresses
     * only the cancelled suffix. It must preserve the accepted GPU source. */
    assert(prefix.submitted && prefix.completed &&
           commands.batchSizes.count == 1 &&
           commands.batchSizes[0].unsignedIntegerValue == 1);
    *(uint32_t *)((uint8_t *)ram.contents + 4096) = 0x12345678;
    id<MTLBuffer> second = encode_vram_copy(cache, 4096, 4);
    NV2AMetalSurfaceRecording *retry = cache.recording;
    require([cache checkpointWithError:&error], error);
    id<MTLBuffer> third = encode_vram_copy(cache, 0, 4);
    NV2AMetalSurfaceRecording *tail = cache.recording;
    require([cache checkpointWithError:&error], error);
    id<MTLSharedEvent> gate = [device newSharedEvent];
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
    assert(gate && queue);
    [queue waitForEvent:gate value:1];
    require([cache submitWithError:&error], error);
    require([cache collectCompletedWithError:&error], error);
    assert(retry.submitted && tail.submitted && !retry.completed &&
           !tail.completed &&
           commands.batchSizes.lastObject.unsignedIntegerValue == 2);
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, 4, YES));
    NV2AMetalSubmission *receipt = commands.lastSubmitted;
    id<MTLBuffer> laterBytes = encode_vram_copy(cache, 12288, 4);
    NV2AMetalSurfaceRecording *later = cache.recording;
    require([cache checkpointWithError:&error], error);
    gate.signaledValue = 1;
    require([cache waitForSubmission:receipt error:&error], error);
    assert(retry.completed && tail.completed && !later.submitted &&
           !later.completed && !later.cancelled &&
           commands.sealedBufferCount == 1);
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 12288, 4, YES));
    require([cache submitWithError:&error], error);
    require([cache waitUntilIdleWithError:&error], error);
    assert(later.completed && *(uint32_t *)laterBytes.contents == 0x5a5a5a5a);
    assert(*(uint32_t *)first.contents == 0x5a5a5a5a &&
           *(uint32_t *)second.contents == 0x12345678 &&
           *(uint32_t *)third.contents == 0x5a5a5a5a);

    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:8192
                                                              config:&c
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    uint64_t redGeneration = surface.generation;
    NV2AMetalSurfaceRecording *red = cache.recording;
    require([cache checkpointWithError:&error], error);
    surface = [cache prepareSurfaceAtAddress:8192
                                      config:&c
                                       frame:0
                                       error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    NV2AMetalSurfaceRecording *blue = cache.recording;
    assert(surface.generation > redGeneration);
    [cache cancel];
    assert(blue.cancelled && !red.cancelled &&
           surface.generation == redGeneration && surface.dirty &&
           !surface.needsUpload);
    require([cache prepareCPUAccessAtAddress:8192
                                      length:192
                                       write:NO
                                       error:&error],
            error);
    assert(red.completed && !blue.completed);
    check_region(ram, 8192, c, 0xffff0000, 0x5a);
    require([cache prepareCPUAccessAtAddress:8192
                                      length:192
                                       write:YES
                                       error:&error],
            error);
    memset((uint8_t *)ram.contents + 8192, 0x33, 192);
    surface = [cache prepareSurfaceAtAddress:8192
                                      config:&c
                                       frame:0
                                       error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    NV2AMetalSurfaceRecording *discarded = cache.recording;
    require([cache checkpointWithError:&error], error);
    NSData *before = [NSData dataWithBytes:ram.contents length:ram.length];
    require([cache discardForRestoreWithError:&error], error);
    assert(discarded.cancelled && !discarded.submitted && !surface.valid &&
           !commands.sealedBufferCount);
    assert(!memcmp(before.bytes, ram.contents, ram.length));

    [commands.batchSizes removeAllObjects];
    NSMutableArray *images = [NSMutableArray new],
                   *tokens = [NSMutableArray new];
    for (unsigned i = 0; i < 257; i++) {
        [images addObject:encode_vram_copy(cache, 0, 4)];
        [tokens addObject:cache.recording];
        require([cache checkpointWithError:&error], error);
    }
    assert(commands.batchSizes.count == 8 && commands.sealedBufferCount == 1);
    require([cache submitWithError:&error], error);
    require([cache waitUntilIdleWithError:&error], error);
    assert(commands.batchSizes.count == 9);
    for (unsigned i = 0; i < 9; i++)
        assert(commands.batchSizes[i].unsignedIntegerValue ==
               (i == 8 ? 1 : 32));
    for (id<MTLBuffer> bytes in images)
        assert(*(uint32_t *)bytes.contents == 0x5a5a5a5a);
    for (NV2AMetalSurfaceRecording *token in tokens)
        assert(token.submitted && token.completed && !token.cancelled);

    NSUInteger beforePressure = commands.batchSizes.count;
    id<MTLBuffer> budgetFirst = encode_vram_copy(cache, 0, 4);
    NV2AMetalSurfaceRecording *budgetPrefix = cache.recording;
    require([cache checkpointWithError:&error], error);
    id<MTLBuffer> budgetSecond = encode_vram_copy(cache, 0, 4);
    NV2AMetalSurfaceRecording *budgetSuffix = cache.recording;
    id<MTLBuffer> large = [device
        newBufferWithLength:NV2AMetalCommandBatchExtraBytes + 1024 * 1024
                    options:MTLResourceStorageModePrivate];
    assert(large);
    require([commands addResource:large error:&error], error);
    assert(commands.batchNeedsSubmit);
    require([cache checkpointWithError:&error], error);
    assert(commands.batchSizes.count == beforePressure + 1 &&
           commands.batchSizes.lastObject.unsignedIntegerValue == 2 &&
           !commands.sealedBufferCount);
    require([cache waitUntilIdleWithError:&error], error);
    assert(budgetPrefix.completed && budgetSuffix.completed &&
           *(uint32_t *)budgetFirst.contents == 0x5a5a5a5a &&
           *(uint32_t *)budgetSecond.contents == 0x5a5a5a5a);
    large = nil;
    CacheFailureCommands *submitFailure =
        [[CacheFailureCommands alloc] initWithDevice:device error:&error];
    require(submitFailure != nil, error);
    NV2AMetalSurfaceCache *submissionCache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:submitFailure
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(submissionCache != nil, error);
    NSMutableArray *accepted = [NSMutableArray new];
    for (unsigned i = 0; i < NV2AMetalCommandBatchLimit - 1; i++) {
        (void)encode_vram_copy(submissionCache, 0, 4);
        [accepted addObject:submissionCache.recording];
        require([submissionCache checkpointWithError:&error], error);
    }
    (void)encode_vram_copy(submissionCache, 4096, 4);
    NV2AMetalSurfaceRecording *unaccepted = submissionCache.recording;
    submitFailure.failSubmit = YES;
    error = nil;
    assert(![submissionCache checkpointWithError:&error] && error);
    assert(!unaccepted.submitted && !unaccepted.cancelled &&
           submitFailure.commandBuffer);
    [submissionCache cancel];
    assert(unaccepted.cancelled &&
           submitFailure.sealedBufferCount == NV2AMetalCommandBatchLimit - 1);
    require([submissionCache submitWithError:&error], error);
    require([submissionCache waitUntilIdleWithError:&error], error);
    for (NV2AMetalSurfaceRecording *token in accepted)
        assert(token.submitted && token.completed && !token.cancelled);
    CacheFailureCommands *failure =
        [[CacheFailureCommands alloc] initWithDevice:device error:&error];
    require(failure != nil, error);
    NV2AMetalSurfaceCache *failed =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:failure
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(failed != nil, error);
    (void)encode_vram_copy(failed, 0, 4);
    NV2AMetalSurfaceRecording *a = failed.recording;
    require([failed checkpointWithError:&error], error);
    (void)encode_vram_copy(failed, 4096, 4);
    NV2AMetalSurfaceRecording *b = failed.recording;
    require([failed checkpointWithError:&error], error);
    require([failed submitWithError:&error], error);
    failure.failCompletion = YES;
    error = nil;
    assert(![failed waitForSubmission:failure.lastSubmitted error:&error] &&
           error);
    assert(a.submitted && b.submitted && !a.completed && !b.completed);
    assert(
        !nv2a_metal_try_cpu_access(failed.cpuAccessGuard, 0, ram.length, YES));
    puts("Metal surface checkpoints: accepted source/clear survives suffix "
         "cancel, CPU boundary, gated batch feedback, exact RAM, full restore "
         "discard, 257 GPU copies in nine bounded batches and sticky "
         "failed-prefix "
         "ownership PASS");
    checks++;
}
#endif
