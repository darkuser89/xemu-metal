/* RAM blits publish their own completion without draining unrelated readers.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BLIT_SUBMISSION_H
#define TEST_METAL_BLIT_SUBMISSION_H

static uint32_t texture_pixel(id<MTLTexture> texture, unsigned x, unsigned y);

@interface BlitBoundaryCommands : NV2AMetalCommands
@property(nonatomic) id<MTLSharedEvent> gate;
@property(nonatomic) NV2AMetalCachedSurface *replacedAtWait;
@property(nonatomic) NV2AMetalCommands *writer;
@property(nonatomic) uint64_t writerTimelineAtWait;
@property(nonatomic) unsigned waits, idleWaits;
@end
@implementation BlitBoundaryCommands
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    _waits++;
    assert(!_replacedAtWait.valid);
    if (_writer)
        assert([[_writer valueForKey:@"lastSubmission"] unsignedLongLongValue] ==
               _writerTimelineAtWait);
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
                  id<MTLBuffer> *output, NSUInteger address, BOOL submitted)
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
    NV2AMetalVRAMReadSpan span = { address, 8 };
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
               sourceOffset:address
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
                            cache, &source, &bytes, 24000, submitted);
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

static void blit_destination_reader_test(void)
{
    fixture();
    fill_blit_ram();
    blit_context(NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                 NV09F_SET_OPERATION_SRCCOPY, 64, 80, 32, 40);
    const NSUInteger sourceAddress = 32768, destination = 49152;
    uint8_t expected[65536];
    memcpy(expected, state->vram_ptr, sizeof(expected));
    expected_blit(expected, sourceAddress, destination, 32, 40, 7, 3, 4,
                  NV09F_SET_OPERATION_SRCCOPY, -1);
    uint64_t old;
    memcpy(&old, state->vram_ptr + destination, sizeof(old));
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    BlitBoundaryCommands *reader = nil;
    id<MTLBuffer> readback = nil;
    blit_gated_reader(cache, &reader, &readback, destination, YES);
    NSError *error = nil;
    require([cache prepareGPUReadAtAddress:24000 length:4 error:&error], error);
    NV2AMetalSurfaceRecording *prefix = cache.recording;
    require([cache checkpointWithError:&error], error);
    const uint64_t before =
        [[cache.commands valueForKey:@"lastSubmission"] unsignedLongLongValue];
    reader.writer = cache.commands;
    reader.writerTimelineAtWait = before + 2;
    class_method(NV_IMAGE_BLIT, NV09F_SIZE, 7 | 3 << 16);
    assert(prefix.completed && reader.waits == 1 && !reader.idleWaits &&
           reader.gate.signaledValue == 1 &&
           !memcmp(readback.contents, &old, sizeof(old)) &&
           !memcmp(state->vram_ptr, expected, sizeof(expected)));
    puts("Blit destination dependency: accepted prefix and GPU writer are "
         "submitted before CPU feedback; the reader sees the old bytes PASS");
    groups++;
}

static BOOL (*overwrite_download_original)(id, SEL, id<MTLBuffer>, NSUInteger,
                                           BOOL, BOOL, BOOL,
                                           NV2AMetalCommands *, NSError **);
static unsigned overwrite_downloads;
static NSUInteger overwrite_download_address;
static BOOL overwrite_download(id transfer, SEL selector, id<MTLBuffer> dest,
                               NSUInteger offset, BOOL swizzle, BOOL flip,
                               BOOL downscale, NV2AMetalCommands *commands,
                               NSError **error)
{
    assert(dest == surfaces.cache.vram && offset == overwrite_download_address);
    overwrite_downloads++;
    return overwrite_download_original(transfer, selector, dest, offset,
                                       swizzle, flip, downscale, commands,
                                       error);
}
static void overwrite_retry(NV2AMetalCachedSurface *old,
                            NV2AMetalCachedSurface *second, unsigned rows,
                            unsigned downloads)
{
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NSData *raw = [NSData dataWithBytes:state->vram_ptr length:65536];
    uint64_t generation = old.generation;
    uint64_t secondGeneration = second.generation;
    NSError *failure = [NSError errorWithDomain:@"test.blit.overwrite"
                                           code:1
                                       userInfo:nil];
    Method encode = class_getInstanceMethod(
        NV2AMetalBlit.class,
        @selector(encodeSource:destination:config:commands:error:));
    Method submit = class_getInstanceMethod(NV2AMetalCommands.class,
                                            @selector(submitWithError:));
    assert(encode && submit);
    IMP encodeFailure = imp_implementationWithBlock(
        ^BOOL(id owner, id<MTLBuffer> source, id<MTLBuffer> dest,
              const NV2AMetalBlitConfig *config, NV2AMetalCommands *commands,
              NSError **error) {
          (void)owner;
          (void)source;
          (void)dest;
          (void)config;
          (void)commands;
          if (error)
              *error = failure;
          return NO;
        });
    IMP submitFailure =
        imp_implementationWithBlock(^BOOL(id owner, NSError **error) {
          assert(owner == cache.commands);
          if (error)
              *error = failure;
          return NO;
        });
    Method methods[] = { encode, submit };
    IMP failures[] = { encodeFailure, submitFailure };
    for (unsigned i = 0; i < G_N_ELEMENTS(methods); i++) {
        overwrite_downloads = 0;
        qemu_mutex_lock(&pg->lock);
        pg->image_blit.width = 8;
        pg->image_blit.height = rows;
        IMP original = method_setImplementation(methods[i], failures[i]);
        NSError *error = nil;
        assert(![draw.blitter blitWithError:&error] && error == failure);
        method_setImplementation(methods[i], original);
        qemu_mutex_unlock(&pg->lock);
        assert(!cache.recording && !cache.commands.commandBuffer &&
               surfaces.color == (second ?: old) && old.valid && old.dirty &&
               old.generation == generation &&
               !memcmp(state->vram_ptr, raw.bytes, raw.length) &&
               overwrite_downloads == downloads);
        if (second)
            assert(second.valid && second.dirty &&
                   second.generation == secondGeneration);
    }
    overwrite_downloads = 0;
    assert(imp_removeBlock(encodeFailure));
    assert(imp_removeBlock(submitFailure));
}
static void blit_multiple_targets(void)
{
    const struct {
        unsigned firstOffset, rows;
        BOOL second, sourceAlias, preserveSecond;
    } cases[] = {
        { 0, 16, YES, NO, NO },   { 0, 12, YES, NO, YES },
        { 0, 10, NO, NO, NO },    { 128, 12, NO, NO, NO },
        { 0, 16, YES, YES, YES },
    };
    for (unsigned t = 0; t < G_N_ELEMENTS(cases); t++) {
        fixture();
        fill_blit_ram();
        PGRAPHState *pg = &state->pgraph;
        pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
            7 << 16;
        pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff112233;
        send_method(NV097_SET_SURFACE_COLOR_OFFSET, cases[t].firstOffset);
        send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
        NV2AMetalCachedSurface *first = surfaces.color;
        NV2AMetalCachedSurface *second = nil;
        if (cases[t].second) {
            pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff445566;
            send_method(NV097_SET_SURFACE_COLOR_OFFSET, 256);
            send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
            second = surfaces.color;
            assert(second.address == 1280 && second.valid && second.dirty);
        }
        assert(first.address == 1024 + cases[t].firstOffset && first.valid &&
               first.dirty);
        uint8_t expected[65536];
        memcpy(expected, state->vram_ptr, sizeof(expected));
        for (unsigned i = 0; i < 64; i++) {
            stl_le_p(expected + first.address + i * 4, 0xff112233);
            if (second)
                stl_le_p(expected + second.address + i * 4, 0xff445566);
        }
        blit_context(NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                     NV09F_SET_OPERATION_SRCCOPY,
                     cases[t].sourceAlias ? 16 : 64, 16, 32, 32);
        if (cases[t].sourceAlias)
            class_method(NV_CONTEXT_SURFACES_2D, NV062_SET_OFFSET_SOURCE, 256);
        expected_blit(expected, cases[t].sourceAlias ? 1280 : 32768, 1024, 32,
                      32, 8, cases[t].rows, 4, NV09F_SET_OPERATION_SRCCOPY, -1);
        Method method = class_getInstanceMethod(
            NV2AMetalSurfaceTransfer.class,
            @selector(encodeDownloadToBuffer:offset:swizzle:flip:downscale:
                      commands:error:));
        assert(method);
        overwrite_downloads = 0;
        overwrite_download_address = 1280;
        overwrite_download_original =
            (void *)method_setImplementation(method, (IMP)overwrite_download);
        if (t < 2)
            overwrite_retry(first, second, cases[t].rows,
                            cases[t].preserveSecond);
        class_method(NV_IMAGE_BLIT, NV09F_SIZE, 8 | cases[t].rows << 16);
        method_setImplementation(method, (IMP)overwrite_download_original);
        assert(overwrite_downloads == cases[t].preserveSecond && !first.valid &&
               !second.valid &&
               !memcmp(state->vram_ptr, expected, sizeof(expected)));
    }
    puts("PGRAPH blit overwrite: five multi-surface and overhang cases; "
         "partial and source-aliased targets alone download; exact RAM and "
         "multi-target retry PASS");
}
static void blit_overwrite_tests(void)
{
    const struct {
        unsigned targetPitch, blitPitch, pixels, clip, scale;
        BOOL alpha, blend, alias, overwrite, swizzled;
    } cases[] = {
        { 32, 32, 8, 0, 1, NO, NO, NO, YES, NO },
        { 40, 40, 8, 0, 1, NO, NO, NO, YES, NO },
        { 40, 40, 9, 312, 1, YES, NO, NO, YES, NO },
        { 40, 40, 9, 311, 1, YES, NO, NO, NO, NO },
        { 40, 36, 8, 0, 1, NO, NO, NO, NO, NO },
        { 32, 32, 8, 0, 1, NO, NO, YES, NO, NO },
        { 32, 32, 8, 0, 1, NO, YES, NO, NO, NO },
        { 32, 32, 8, 0, 2, NO, NO, NO, YES, NO },
        { 40, 40, 8, 0, 3, NO, NO, NO, YES, NO },
        { 40, 32, 8, 0, 1, NO, NO, NO, YES, YES },
        { 40, 32, 8, 0, 2, NO, NO, NO, YES, YES },
        { 40, 40, 8, 0, 3, NO, NO, NO, NO, YES },
    };
    for (unsigned t = 0; t < G_N_ELEMENTS(cases); t++) {
        fixture();
        fill_blit_ram();
        BlitBoundaryCommands *reader = nil;
        id<MTLBuffer> readback = nil;
        uint64_t prior = 0;
        if (t == 1) {
            memcpy(&prior, state->vram_ptr + 1024, sizeof(prior));
            require(blit_gated_reader(surfaces.cache, &reader, &readback, 1024,
                                      YES) != nil,
                    nil);
        }
        PGRAPHState *pg = &state->pgraph;
        unsigned targetPitch = cases[t].targetPitch;
        unsigned blitPitch = cases[t].blitPitch;
        pg->surface_color.pitch = targetPitch;
        pg->surface_scale_factor = cases[t].scale;
        if (cases[t].swizzled) {
            pg->surface_type = NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
            pg->surface_shape.log_width = pg->surface_shape.log_height = 3;
        }
        pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff237ce1;
        pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
            7 << 16;
        send_method(NV097_CLEAR_SURFACE, NV097_CLEAR_SURFACE_COLOR);
        NV2AMetalCachedSurface *old = surfaces.color;
        assert(old.address == 1024 && old.dirty &&
               old.reservationLength == targetPitch * 8 &&
               old.transfer.texture.width == 8 * cases[t].scale &&
               old.transfer.config.swizzle == cases[t].swizzled);
        reader.replacedAtWait = old;
        uint8_t expected[65536];
        memcpy(expected, state->vram_ptr, sizeof(expected));
        unsigned texelPitch = cases[t].swizzled ? 32 : targetPitch;
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++)
                stl_le_p(expected + 1024 + y * texelPitch + x * 4, 0xff237ce1);
        unsigned op = cases[t].blend ? NV09F_SET_OPERATION_BLEND_AND :
                                       NV09F_SET_OPERATION_SRCCOPY;
        blit_context(cases[t].alpha ? NV062_SET_COLOR_FORMAT_LE_X8R8G8B8 :
                                      NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                     op, cases[t].alias ? 16 : 64, 16, targetPitch, blitPitch);
        unsigned src = cases[t].alias ? 1024 : 32768;
        unsigned rows = cases[t].clip ? cases[t].clip / blitPitch : 8;
        unsigned tail = cases[t].clip % blitPitch;
        expected_blit(expected, src, 1024, targetPitch, blitPitch,
                      cases[t].pixels, rows, 4, op, cases[t].alpha ? 255 : -1);
        if (tail) {
            uint8_t *end = expected + 1024 + rows * blitPitch;
            memcpy(end, expected + src + rows * targetPitch, tail);
            if (cases[t].alpha)
                for (unsigned x = 3; x < tail - tail % 4; x += 4)
                    end[x] = 255;
            tile_clipped_length = cases[t].clip;
        }
        Method method = class_getInstanceMethod(
            NV2AMetalSurfaceTransfer.class,
            @selector(encodeDownloadToBuffer:offset:swizzle:flip:downscale:
                      commands:error:));
        assert(method);
        overwrite_downloads = 0;
        overwrite_download_address = 1024;
        overwrite_download_original =
            (void *)method_setImplementation(method, (IMP)overwrite_download);
        if (!t)
            overwrite_retry(old, nil, 8, 0);
        class_method(NV_IMAGE_BLIT, NV09F_SIZE, cases[t].pixels | 8 << 16);
        method_setImplementation(method, (IMP)overwrite_download_original);
        assert(overwrite_downloads == !cases[t].overwrite && !old.valid &&
               pg->surface_color.buffer_dirty &&
               !memcmp(state->vram_ptr, expected, sizeof(expected)));
        if (reader)
            assert(reader.waits == 1 && !reader.idleWaits &&
                   reader.gate.signaledValue == 1 &&
                   !memcmp(&prior, readback.contents, sizeof(prior)));
        if (cases[t].scale > 1) {
            NSError *error = nil;
            unsigned scale = cases[t].scale == 2 ? 3 : 2;
            pg->surface_scale_factor = scale;
            NV2AMetalSurfaceCache *cache = surfaces.cache;
            require([surfaces prepareColor:YES zeta:NO error:&error] &&
                        [cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            id<MTLTexture> texture = surfaces.color.transfer.texture;
            assert(surfaces.color != old && texture.width == 8 * scale &&
                   texture_pixel(texture, 0, 0) ==
                       (uint32_t)ldl_le_p(expected + 1024) &&
                   texture_pixel(texture, scale, 0) ==
                       (uint32_t)ldl_le_p(expected + 1028));
        }
    }
    puts(
        "PGRAPH blit overwrite: seven complete SRCCOPY targets skip downloads; "
        "five preservation cases, exact RAM, swizzle, scale changes, ordered "
        "reader and encode/submit retry PASS");
    blit_multiple_targets();
    groups++;
}
#endif
