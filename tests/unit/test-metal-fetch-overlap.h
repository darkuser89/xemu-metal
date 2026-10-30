/* CPU fragment preparation while the native Fetch/XF producer is gated.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_FETCH_OVERLAP_H
#define TEST_METAL_FETCH_OVERLAP_H
#import "hw/xbox/nv2a/pgraph/metal/fetch-pgraph.h"

static BOOL (*overlap_original_submit)(id, SEL, NSError **);
static BOOL (*overlap_original_complete)(id, SEL, NSError **);
static NV2AMetalPixelShader *(*overlap_original_pixel)(id, SEL, MTLPixelFormat,
                                                       MTLPixelFormat,
                                                       NSError **);
typedef id (*OverlapCaptureIMP)(id __attribute__((ns_consumed)), SEL,
                                PGRAPHState *, NV2AMetalPGRAPHTextureSnapshot *,
                                id<MTLDevice>, NV2AMetalDrawState *, NSError **)
    __attribute__((ns_returns_retained));
static OverlapCaptureIMP overlap_original_capture;
static id<MTLSharedEvent> overlap_gate;
static NV2AMetalSubmission *overlap_receipt;
static NV2AMetalCommands *overlap_commands;
static NSData *overlap_snapshot;
static NV2AMetalPGRAPHTextureSnapshot *overlap_textures;
static NV2AMetalCachedSurface *overlap_original_color, *overlap_alternate;
static float overlap_current[4];
static unsigned overlap_mode, overlap_captures, overlap_pixels;
static BOOL overlap_submitted;

static BOOL overlap_submit(id object, SEL selector, NSError **error)
{
    assert(!overlap_submitted);
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    overlap_commands = [object encodingCommands];
    id<MTL4CommandQueue> queue = object_getIvar(overlap_commands, ivar);
    [queue waitForEvent:overlap_gate value:1];
    BOOL ok = overlap_original_submit(object, selector, error);
    overlap_submitted = ok;
    overlap_receipt = overlap_commands.lastSubmitted;
    if (overlap_mode == 5) {
        overlap_original_color = surfaces.color;
        [surfaces setValue:overlap_alternate forKey:@"color"];
    }
    return ok;
}
static id overlap_capture(id object __attribute__((ns_consumed)), SEL selector,
                          PGRAPHState *pg,
                          NV2AMetalPGRAPHTextureSnapshot *textures,
                          id<MTLDevice> device, NV2AMetalDrawState *raster,
                          NSError **error) __attribute__((ns_returns_retained));
static id overlap_capture(id object __attribute__((ns_consumed)), SEL selector,
                          PGRAPHState *pg,
                          NV2AMetalPGRAPHTextureSnapshot *textures,
                          id<MTLDevice> device, NV2AMetalDrawState *raster,
                          NSError **error)
{
    NSError *pendingError = nil;
    assert(overlap_submitted && overlap_receipt &&
           overlap_gate.signaledValue == 0 &&
           ![overlap_receipt completedWithError:&pendingError] &&
           !pendingError);
    assert(!memcmp(pg->vertex_attributes[0].inline_value, overlap_current, 16));
    overlap_captures++;
    id capture = overlap_original_capture(object, selector, pg, textures,
                                          device, raster, error);
    assert(capture);
    overlap_snapshot = [capture snapshotData];
    overlap_textures = textures;
    if (overlap_mode == 1 || overlap_mode == 2) {
        overlap_gate.signaledValue = 1;
        if (error)
            *error = [NSError errorWithDomain:@"test.fragment-overlap"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return capture;
}
static NV2AMetalPixelShader *overlap_pixel(id object, SEL selector,
                                           MTLPixelFormat color,
                                           MTLPixelFormat depth,
                                           NSError **error)
{
    NSError *pendingError = nil;
    if (overlap_mode == 5 && overlap_pixels == 1) {
        assert(overlap_gate.signaledValue == 1 &&
               [overlap_receipt completedWithError:&pendingError] &&
               !pendingError &&
               color == overlap_original_color.transfer.texture.pixelFormat);
        overlap_pixels++;
        return overlap_original_pixel(object, selector, color, depth, error);
    }
    assert(overlap_captures == 1 && overlap_gate.signaledValue == 0 &&
           ![overlap_receipt completedWithError:&pendingError] &&
           !pendingError);
    overlap_pixels++;
    NV2AMetalPixelShader *pixel =
        overlap_original_pixel(object, selector, color, depth, error);
    assert(pixel);
    if (overlap_mode == 5)
        [surfaces setValue:overlap_original_color forKey:@"color"];
    overlap_gate.signaledValue = 1;
    if (overlap_mode == 3 || overlap_mode == 4) {
        if (error)
            *error = [NSError errorWithDomain:@"test.renderer-overlap"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return pixel;
}
static BOOL overlap_complete(id object, SEL selector, NSError **error)
{
    assert(overlap_captures == 1 && overlap_gate.signaledValue == 1);
    if (overlap_mode == 2 || overlap_mode == 4) {
        require([overlap_commands waitForSubmission:overlap_receipt
                                              error:error],
                *error);
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            [object valueForKey:@"encodedBatches"];
        assert(batches.count);
        ((uint32_t *)batches[0].fetch.faults.contents)[0] = 1;
        *(uint32_t *)((uint8_t *)batches[0].fetch.faults.contents +
                      batches[0].fetch.faultSummaryOffset) = 1;
    }
    return overlap_original_complete(object, selector, error);
}
static void fetch_overlap_tests(void)
{
    for (overlap_mode = 0; overlap_mode < 6; overlap_mode++) {
        fixture();
        NSError *error = nil;
        PGRAPHState *pg = &state->pgraph;
        if (overlap_mode == 5) {
            /* Simulate a transient host binding that is replaced when the
             * captured guest attachments are prepared again after Fetch. */
            NV2AMetalSurfaceConfig alternate = {
                .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
                .width = 8,
                .height = 8,
                .pitch = 16,
                .scale = 1,
                .color = YES
            };
            qemu_mutex_lock(&pg->lock);
            overlap_alternate =
                [surfaces.cache prepareSurfaceAtAddress:49152
                                                 config:&alternate
                                                  frame:pg->frame_time
                                                  error:&error];
            qemu_mutex_unlock(&pg->lock);
            require(overlap_alternate != nil, error);
        }
        /* This suite needs producer feedback even for clean Current VRAM:
         * a real context store retains the submit/completion/error path. */
        pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
        pg->enable_vertex_program_write = true;
        mov(0,3,20,false);
        pg->program_data[0][3] &= ~(1u << 11);
        mov(1,0,0,false);mov(2,3,3,true);
        pg->vertex_attributes[0].inline_value[0] = 123;
        memcpy(overlap_current, pg->vertex_attributes[0].inline_value, 16);
        overlap_gate = [surfaces.cache.commands.device newSharedEvent];
        assert(overlap_gate);
        overlap_submitted = NO;
        overlap_captures = overlap_pixels = 0;
        overlap_receipt = nil;
        overlap_snapshot = nil;
        Method submit = class_getInstanceMethod(NV2AMetalPGRAPHFetch.class,
                                                @selector(submitWithError:));
        Method complete = class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class, @selector(completeWithError:));
        Method capture = class_getInstanceMethod(
            NV2AMetalPGRAPHPixelState.class,
            @selector(initWithState:textures:device:frozenRaster:error:));
        Method pixel = class_getInstanceMethod(
            NV2AMetalPGRAPHDraw.class, @selector(pixelForColor:depth:error:));
        assert(submit && complete && capture && pixel);
        overlap_original_submit =
            (void *)method_setImplementation(submit, (IMP)overlap_submit);
        overlap_original_complete =
            (void *)method_setImplementation(complete, (IMP)overlap_complete);
        overlap_original_capture =
            (void *)method_setImplementation(capture, (IMP)overlap_capture);
        overlap_original_pixel =
            (void *)method_setImplementation(pixel, (IMP)overlap_pixel);
        qemu_mutex_lock(&pg->lock);
        BOOL ok = [draw drawWithError:&error];
        qemu_mutex_unlock(&pg->lock);
        overlap_gate.signaledValue = 1;
        method_setImplementation(submit, (IMP)overlap_original_submit);
        method_setImplementation(complete, (IMP)overlap_original_complete);
        method_setImplementation(capture, (IMP)overlap_original_capture);
        method_setImplementation(pixel, (IMP)overlap_original_pixel);
        assert(overlap_captures == 1 && overlap_snapshot &&
               !surfaces.cache.commands.commandBuffer);
        assert(overlap_pixels == (overlap_mode == 1 || overlap_mode == 2 ? 0u :
                                  overlap_mode == 5                      ? 2u :
                                                                           1u));
        if (!overlap_mode || overlap_mode == 5) {
            require(ok, error);
            assert(pg->draw_time == 1 &&
                   pg->vertex_attributes[0].inline_value[0] == 0 &&
                   pg->vertex_attributes[0].inline_value[1] == 8);
            NV2AMetalPGRAPHPixelState *after =
                [[NV2AMetalPGRAPHPixelState alloc]
                    initWithState:pg
                         textures:overlap_textures
                           device:surfaces.cache.commands.device
                            error:&error];
            require(after != nil, error);
            assert([overlap_snapshot isEqual:after.snapshotData]);
            read_vram(1024, 256);
            color(1, 1, 0xff00ff00);
        } else {
            assert(!ok && error && !pg->draw_time &&
                   !memcmp(pg->vertex_attributes[0].inline_value,
                           overlap_current, 16));
            if (overlap_mode == 2 || overlap_mode == 4)
                assert([error.localizedDescription
                    containsString:@"vertex fetch"]);
            else if (overlap_mode == 1)
                assert([error.domain isEqualToString:@"test.fragment-overlap"]);
            else
                assert([error.domain isEqualToString:@"test.renderer-overlap"]);
            NV2AMetalPendingJournal *journal = [draw valueForKey:@"pending"];
            assert(journal.streamCount == (overlap_mode == 3 ? 1u : 0u));
            read_vram(1024, 256);
            for (unsigned i = 0; i < 64; i++)
                color(i % 8, i / 8, 0xffff0000);
            render();
            read_vram(1024, 256);
            color(1, 1, 0xff00ff00);
        }
    }
    overlap_gate = nil;
    overlap_receipt = nil;
    overlap_commands = nil;
    overlap_snapshot = nil;
    overlap_textures = nil;
    overlap_original_color = overlap_alternate = nil;
    puts("PGRAPH producer overlap:fragment capture/renderer selection while "
         "Fetch/XF GPU gate is "
         "closed;exact post-Current capture/pixels;capture/fetch failure order,"
         "changed attachment format reselects renderer,deferred renderer "
         "failure preserves completed XF,unchanged failed "
         "attachments/Current and four retries PASS");
    groups++;
}
#endif
