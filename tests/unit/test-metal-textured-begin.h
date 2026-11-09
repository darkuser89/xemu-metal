/* Warm texture-state capture must not consume an empty native section.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TEXTURED_BEGIN_H
#define TEST_METAL_TEXTURED_BEGIN_H
#include "test-metal-raster-feedback.h"

static void snapshot_producer_feedback_tests(void)
{
    for (unsigned textured = 0; textured < 2; textured++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        /* A state boundary can retain the last array range while a shorter
         * visible prefix is drawn. Its XF producer then shares that raster
         * submission, without consuming the hidden range. */
        pg->draw_arrays_length = 2;
        pg->draw_arrays_count[1] = 3;
        if (textured)
            texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
        qemu_mutex_lock(&pg->lock);
        NSError *error = nil;
        NV2AMetalSurfaceCache *cache = surfaces.cache;
        NV2AMetalCommands *commands = cache.commands;
        require([draw beginWithError:&error] &&
                [draw prepareVertexStateChangeWithError:&error], error);
        pg->draw_arrays_length = 1;
        require([draw flushDrawWithError:&error], error);
        NV2AMetalPendingJournal *journal = [draw valueForKey:@"pending"];
        assert(journal.retainedStreams.count);
        NV2AMetalPendingSpan *span = [journal.retainedStreams.lastObject lastObject];
        assert(span.producerRecording && !span.producerRecording.completed);
        assert(commands.hasPendingRasterPass);
        ReaderRasterFeedbackGate *gate = [ReaderRasterFeedbackGate new];
        publication_feedback_gate = gate;
        publication_feedback_handlers = 0;
        Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
            @selector(addFeedbackHandler:));
        assert(feedback);
        publication_original_feedback = (void *)method_setImplementation(feedback,
            (IMP)publication_split_feedback);
        require([cache submitWithError:&error], error);
        method_setImplementation(feedback, (IMP)publication_original_feedback);
        publication_feedback_gate = nil;
        NV2AMetalSubmission *receipt = commands.lastSubmitted;
        assert(publication_feedback_handlers == 2 && receipt.hasSeparateProducerFeedback);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [gate releaseFeedback]; });
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *begin = [draw beginSnapshotWithError:&error];
        require(pending.length > 12 && begin.length, error);
        assert(span.producerRecording.producersCompleted && !span.producerRecording.completed);
        require([gate waitForNativeFeedback], error);
        assert(!gate.delivered && ![receipt completedWithError:&error] && !error);
        if (textured) {
            const uint8_t *wire = begin.bytes;
            NSUInteger offset = 48 + ldl_be_p(wire + 40);
            assert(offset + 12 <= begin.length && ldl_be_p(wire + offset + 8) == 1);
        }
        require([cache prepareGPUReadAtAddress:49152 length:4 error:&error], error);
        NV2AMetalSurfaceRecording *open = cache.recording;
        require([[draw pendingSnapshotWithError:&error] isEqualToData:pending] &&
                [[draw beginSnapshotWithError:&error] isEqualToData:begin], error);
        assert(!gate.delivered && !open.submitted && cache.recording == open &&
               commands.lastSubmitted == receipt);
        [cache cancel];
        [gate releaseFeedback];
        require([cache waitUntilIdleWithError:&error], error);
        require([[draw pendingSnapshotWithError:&error] isEqualToData:pending] &&
                [[draw beginSnapshotWithError:&error] isEqualToData:begin] &&
                [draw endWithError:&error], error);
        qemu_mutex_unlock(&pg->lock);
    }
    puts("Snapshot producer feedback:2 native fixed/textured raster cases;"
         "pending XF and captured textures byte-identical before/after full raster feedback;"
         "unrelated open recording preserved PASS");
}

static void textured_snapshot_scope_test(BOOL rtt)
{
    fixture();
    PGRAPHState *pg = &state->pgraph;
    pg->draw_arrays_length = pg->inline_elements_length =
        pg->inline_buffer_length = pg->inline_array_length = 0;
    texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
    const unsigned stageRegs[] = { NV_PGRAPH_TEXFMT0, NV_PGRAPH_TEXCTL0_0,
                                   NV_PGRAPH_TEXCTL1_0, NV_PGRAPH_TEXIMAGERECT0,
                                   NV_PGRAPH_TEXFILTER0, NV_PGRAPH_TEXADDRESS0 };
    for (unsigned i = 1; i < 4; i++) {
        for (unsigned j = 0; j < G_N_ELEMENTS(stageRegs); j++)
            pg->regs_[stageRegs[j] + i * 4] = pg->regs_[stageRegs[j]];
        pg->regs_[NV_PGRAPH_TEXOFFSET0 + i * 4] = i * 256;
        pg->regs_[NV_PGRAPH_SHADERPROG] |= PS_TEXTUREMODES_PROJECT2D << (i * 5);
        pg->texture_dirty[i] = true;
    }
    if (rtt)
        pg->dma_a = 16;
    unsigned address = rtt ? 1024 : 32768;
    cpu_write(address, 1024);
    for (unsigned i = 0; i < 4; i++)
        memset(state->vram_ptr + address + i * 256, 0x33 + i, 256);
    qemu_mutex_lock(&pg->lock);
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *commands = cache.commands;
    NV2AMetalCommands *independent =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(independent != nil, error);
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> uploadQueue = object_getIvar(commands, queue);
    id<MTL4CommandQueue> otherQueue = object_getIvar(independent, queue);
    id<MTLSharedEvent> uploadGate = [commands.device newSharedEvent];
    id<MTLSharedEvent> otherGate = [commands.device newSharedEvent];
    assert(uploadQueue && otherQueue && uploadGate && otherGate);
    [uploadQueue waitForEvent:uploadGate value:1];
    require([draw beginWithError:&error], error);
    assert(!uploadGate.signaledValue && commands.sealedBufferCount);

    NV2AMetalIndependentReads *reader = nil;
    require([cache tryBeginIndependentReads:NULL count:0 commands:independent
                                       reads:&reader error:&error] && reader,
            error);
    [otherQueue waitForEvent:otherGate value:1];
    id<MTLBuffer> marker = [commands.device newBufferWithLength:4
                                        options:MTLResourceStorageModeShared];
    require(marker && [independent addResource:marker error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [independent.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder fillBuffer:marker range:NSMakeRange(0, 4) value:0x5a];
    [encoder endEncoding];
    require([cache submitIndependentReads:reader error:&error], error);

    dispatch_queue_t timer = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), timer, ^{
      uploadGate.signaledValue = 1;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), timer, ^{
      if (!otherGate.signaledValue)
          otherGate.signaledValue = 2;
    });
    NSData *snapshot = [draw beginSnapshotWithError:&error];
    require(snapshot.length != 0, error);
    const uint8_t *wire = snapshot.bytes;
    NSUInteger textureOffset = 48 + ldl_be_p(wire + 40);
    assert(textureOffset + 12 <= snapshot.length &&
           ldl_be_p(wire + textureOffset + 8) == 15);
    assert(uploadGate.signaledValue == 1 && !otherGate.signaledValue &&
           ![independent.lastSubmitted completedWithError:&error] && !error);

    require([cache prepareGPUReadAtAddress:49152 length:4 error:&error], error);
    NV2AMetalSurfaceRecording *pending = cache.recording;
    NSData *again = [draw beginSnapshotWithError:&error];
    require(again != nil, error);
    assert([again isEqualToData:snapshot] && !otherGate.signaledValue &&
           cache.recording == pending && !pending.submitted);
    [cache cancel];
    require([draw endWithError:&error], error);
    cpu_write(address, 1024);
    memset(state->vram_ptr + address, 0x66, 1024);
    require([draw restoreBeginSnapshot:snapshot error:&error], error);
    require([cache prepareGPUReadAtAddress:49152 length:4 error:&error], error);
    pending = cache.recording;
    NV2AMetalSubmission *lastSurface = commands.lastSubmitted;
    NV2AMetalCommands *textureCommands = [draw valueForKey:@"snapshotCommands"];
    uint64_t restoreSerial = textureCommands.recordingSerial;
    require([draw beginWithError:&error], error);
    assert(!otherGate.signaledValue && !pending.submitted &&
           commands.lastSubmitted == lastSurface && commands.sealedBufferCount);
    assert(textureCommands.recordingSerial == restoreSerial + 1);
    NSData *restored = [draw beginSnapshotWithError:&error];
    require(restored != nil, error);
    assert([restored isEqualToData:snapshot] && !otherGate.signaledValue &&
           !pending.submitted && commands.lastSubmitted == lastSurface);
    otherGate.signaledValue = 1;
    require([cache completeIndependentReads:reader error:&error], error);
    assert(*(const uint32_t *)marker.contents == 0x5a5a5a5a);
    require([draw endWithError:&error], error);
    require([cache submitWithError:&error] && [cache waitUntilIdleWithError:&error],
            error);
    qemu_mutex_unlock(&pg->lock);
    printf("Textured Begin snapshot scope: cold %s completes, gated "
           "independent work and disjoint open section survive PASS\n",
           rtt ? "RTT copy" : "DMA decode");
    printf("Textured Begin restore scope: %s snapshot bytes survive a VRAM "
           "change; unrelated reader and sealed surface work stay pending PASS\n",
           rtt ? "RTT" : "DMA");
    puts("Textured Begin restore batch: four distinct stages use one private "
         "recording and preserve every snapshot byte PASS");
}

static void textured_begin_tests(void)
{
    snapshot_producer_feedback_tests();
    NSError *error = nil;
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8
    };
    unsigned captures = 0;
    for (unsigned mode = 0; mode < 4; mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        BOOL rtt = mode == 3;
        unsigned format = formats[rtt ? 2 : mode];
        unsigned bpp = mode == 0 ? 1 : mode == 1 ? 2 : 4;
        pg->draw_arrays_length = pg->inline_elements_length =
            pg->inline_buffer_length = pg->inline_array_length = 0;
        texture_registers(format, 8 * bpp);
        if (rtt)
            pg->dma_a = 16;
        unsigned address = rtt ? 1024 : 32768;
        cpu_write(address, 64 * bpp);
        memset(state->vram_ptr + address, 0x33, 64 * bpp);
        qemu_mutex_lock(&pg->lock);
        require([draw beginWithError:&error] && [draw endWithError:&error],
                error);
        NV2AMetalSurfaceCache *cache = surfaces.cache;
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        for (unsigned i = 0; i < 64; i++) {
            uint64_t serial = cache.commands.recordingSerial;
            NSUInteger sections = cache.commands.sealedBufferCount;
            require([draw beginWithError:&error], error);
            assert(cache.commands.recordingSerial == serial &&
                   cache.commands.sealedBufferCount == sections &&
                   !cache.commands.commandBuffer && !cache.recording);
            require([draw endWithError:&error], error);
            assert(cache.commands.recordingSerial == serial &&
                   cache.commands.sealedBufferCount == sections &&
                   !cache.commands.commandBuffer && !cache.recording);
            captures++;
        }
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        qemu_mutex_unlock(&pg->lock);
    }
    textured_snapshot_scope_test(NO);
    textured_snapshot_scope_test(YES);
    assert(captures == 256);
    groups++;
    puts("Warm textured Begin:256 Y8/R565/A8R8G8B8/RTT captures;zero native "
         "recording/"
         "section changes at Begin/empty End,real cold uploads "
         "preserved PASS");
}
#endif
