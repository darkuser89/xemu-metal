/* RAM blits publish their own completion without draining unrelated readers.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BLIT_SUBMISSION_H
#define TEST_METAL_BLIT_SUBMISSION_H

@interface BlitBoundaryCommands : NV2AMetalCommands
@property(nonatomic) id<MTLSharedEvent> gate;
@property(nonatomic) unsigned waits, idleWaits;
@end
@implementation BlitBoundaryCommands
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    _waits++;
    if (!_gate.signaledValue)
        _gate.signaledValue = 1;
    return [super waitForSubmission:submission error:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    _idleWaits++;
    return [super waitUntilIdleWithError:error];
}
@end

static NV2AMetalIndependentReads *
blit_gated_reader(NV2AMetalSurfaceCache *cache, BlitBoundaryCommands **commands,
                  id<MTLBuffer> *output, BOOL submitted)
{
    NSError *error = nil;
    *commands =
        [[BlitBoundaryCommands alloc] initWithDevice:cache.commands.device
                                               error:&error];
    require(*commands != nil, error);
    BlitBoundaryCommands *source = *commands;
    source.gate = [source.device newSharedEvent];
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(source, ivar);
    assert(queue && source.gate);
    if (submitted)
        [queue waitForEvent:source.gate value:1];
    id<MTLSharedEvent> gate = source.gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
    NV2AMetalVRAMReadSpan span = { 24000, 8 };
    NV2AMetalIndependentReads *reads = nil;
    require([cache tryBeginIndependentReads:&span
                                      count:1
                                   commands:source
                                      reads:&reads
                                      error:&error] &&
                reads,
            error);
    *output = [source.device newBufferWithLength:8
                                         options:MTLResourceStorageModeShared];
    assert(*output);
    memset((*output).contents, 0, 8);
    require([source addResource:cache.vram error:&error] &&
                [source addResource:*output error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [source.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:cache.vram
               sourceOffset:24000
                   toBuffer:*output
          destinationOffset:0
                       size:8];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    if (submitted)
        require([cache submitIndependentReads:reads error:&error], error);
    return reads;
}

static void blit_submission_tests(void)
{
    const unsigned formats[] = { NV062_SET_COLOR_FORMAT_LE_Y8,
                                 NV062_SET_COLOR_FORMAT_LE_R5G6B5,
                                 NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                                 NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
                                 NV062_SET_COLOR_FORMAT_LE_X8R8G8B8_Z8R8G8B8,
                                 NV062_SET_COLOR_FORMAT_LE_Y32 };
    unsigned cases = 0;
    for (unsigned submitted = 0; submitted < 2; submitted++)
        for (unsigned overlap = 0; overlap < 2; overlap++)
            for (unsigned f = 0; f < G_N_ELEMENTS(formats); f++)
                for (unsigned op = 2; op <= 3; op++) {
                    @autoreleasepool {
                        fixture();
                        fill_blit_ram();
                        cpu_write(24000, 8);
                        memset(state->vram_ptr + 24000, 0x5b, 8);
                        if (overlap)
                            dma[4].address = 32768;
                        blit_context(formats[f], op, 64, 80, 32, 40);
                        class_method(NV_IMAGE_BLIT, NV09F_CONTROL_POINT_IN,
                                     1 | 1 << 16);
                        class_method(NV_IMAGE_BLIT, NV09F_CONTROL_POINT_OUT,
                                     2 | 1 << 16);
                        unsigned bpp = f == 0 ? 1 : f == 1 ? 2 : 4;
                        unsigned dest = overlap ? 32768 : 49152;
                        uint8_t expected[65536];
                        memcpy(expected, state->vram_ptr, sizeof(expected));
                        expected_blit(expected, 32768 + 32 + bpp,
                                      dest + 40 + 2 * bpp, 32, 40, 7, 3, bpp,
                                      op,
                                      f == 3 ? 255 :
                                      f == 4 ? 0 :
                                               -1);
                        NV2AMetalSurfaceCache *cache = surfaces.cache;
                        BlitBoundaryCommands *source = nil;
                        id<MTLBuffer> bytes = nil;
                        NV2AMetalIndependentReads *reads = blit_gated_reader(
                            cache, &source, &bytes, submitted);
                        id recording = source.commandBuffer;
                        uint64_t serial = source.recordingSerial;
                        unsigned before = notifications;
                        class_method(NV_IMAGE_BLIT, NV09F_SIZE, 7 | 3 << 16);
                        assert(!source.waits && !source.idleWaits &&
                               !source.gate.signaledValue &&
                               source.commandBuffer == recording &&
                               source.recordingSerial == serial);
                        assert(!*(uint64_t *)bytes.contents &&
                               !memcmp(expected, state->vram_ptr,
                                       sizeof(expected)) &&
                               notifications == before + 1 &&
                               texture_dirty[dest / 4096]);
                        NSError *error = nil;
                        BOOL completed = YES;
                        require([cache tryIdleCPUAccessAtAddress:24000
                                                          length:8
                                                           write:YES
                                                       completed:&completed
                                                           error:&error],
                                error);
                        assert(!completed);
                        if (submitted) {
                            require([cache completeIndependentReads:reads
                                                              error:&error],
                                    error);
                            assert(source.waits == 1 && !source.idleWaits &&
                                   source.gate.signaledValue == 1 &&
                                   *(uint64_t *)bytes.contents ==
                                       UINT64_C(0x5b5b5b5b5b5b5b5b));
                        } else {
                            [cache cancelIndependentReads:reads];
                            assert(!source.waits && !source.idleWaits &&
                                   !source.commandBuffer &&
                                   !source.gate.signaledValue &&
                                   !*(uint64_t *)bytes.contents);
                        }
                        completed = NO;
                        require([cache tryIdleCPUAccessAtAddress:24000
                                                          length:8
                                                           write:YES
                                                       completed:&completed
                                                           error:&error],
                                error);
                        assert(completed);
                        cases++;
                    }
                }
    assert(cases == 48);
    groups++;
    puts(
        "PGRAPH blit submission:48 native format/operation/self-overlap cases;"
        "exact whole-RAM bytes and dirty notifications while unrelated GPU "
        "reader "
        "remains gated or unsubmitted;zero unrelated waits,recording unchanged,"
        "cancel/completion preserves CPU-write ownership "
        "PASS");
}
#endif
