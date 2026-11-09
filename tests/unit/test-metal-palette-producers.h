/* Short-palette faults belong to compute producers, not raster completion.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PALETTE_PRODUCERS_H
#define TEST_METAL_PALETTE_PRODUCERS_H
#include "test-metal-raster-feedback.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-snapshot.h"

static NV2AMetalSurfaceCache *palette_full_wait_cache;
static BOOL (*palette_original_wait)(id, SEL, NV2AMetalSurfaceRecording *,
                                     NSError **);
static BOOL palette_full_wait(id owner, SEL selector,
                              NV2AMetalSurfaceRecording *recording,
                              NSError **error)
{
    return owner == palette_full_wait_cache ?
               [owner waitForRecording:recording error:error] :
               palette_original_wait(owner, selector, recording, error);
}

/* Scope feedback classification to one command owner's options factory.
 * Validation can install callbacks while creating options, and can recurse
 * while a callback is registered. Only the final top-level registration on
 * the returned options is the explicit owner callback in optionsForSlot:part:.
 * No GPU callback can run before the factory returns and the queue commits. */
@interface PaletteFeedbackRegistration : NSObject
@property(nonatomic, weak) MTL4CommitOptions *options;
@property(nonatomic, copy) MTL4CommitFeedbackHandler handler;
@property(nonatomic) ReaderRasterFeedbackGate *gate;
@property(nonatomic) BOOL rasterOwner;
@end
@implementation PaletteFeedbackRegistration
@end
static NV2AMetalCommands *palette_options_commands;
static ReaderRasterFeedbackGate *palette_options_gate;
static NSMutableArray<PaletteFeedbackRegistration *> *palette_registrations;
static _Thread_local unsigned palette_registration_depth;
static unsigned palette_producer_options, palette_raster_options;
static MTL4CommitOptions *(*palette_original_options)(id, SEL, id, id);
static void (*palette_original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static void palette_register_feedback(id options, SEL selector,
                                      MTL4CommitFeedbackHandler handler)
{
    PaletteFeedbackRegistration *registration = nil;
    if (!palette_registration_depth && NSThread.isMainThread &&
        palette_registrations) {
        registration = [PaletteFeedbackRegistration new];
        registration.options = options;
        registration.handler = handler;
        registration.gate = palette_options_gate;
        [palette_registrations addObject:registration];
    }
    palette_registration_depth++;
    if (registration)
        palette_original_feedback(
            options, selector, ^(id<MTL4CommitFeedback> feedback) {
              if (registration.rasterOwner)
                  [registration.gate receive:feedback
                                     handler:registration.handler];
              else
                  registration.handler(feedback);
            });
    else
        palette_original_feedback(options, selector, handler);
    palette_registration_depth--;
}
static MTL4CommitOptions *palette_options(id owner, SEL selector, id slot,
                                          id part)
{
    if (owner != palette_options_commands)
        return palette_original_options(owner, selector, slot, part);
    assert(NSThread.isMainThread && !palette_registrations &&
           !palette_registration_depth);
    palette_registrations = [NSMutableArray new];
    MTL4CommitOptions *options =
        palette_original_options(owner, selector, slot, part);
    PaletteFeedbackRegistration *registration =
        palette_registrations.lastObject;
    /* The explicit owner registration follows options construction, so it
     * must be the final top-level call and belong to the returned options. */
    assert(options && registration && registration.options == options);
    BOOL producer = [[part valueForKey:@"producer"] boolValue];
    registration.rasterOwner = !producer;
    palette_producer_options += producer;
    palette_raster_options += !producer;
    palette_registrations = nil;
    return options;
}

static void palette_producer_tests(void)
{
    for (unsigned mode = 0; mode < 4; mode++) {
        fixture();
        BOOL badIndex = mode == 1;
        BOOL fullControl = mode == 3, fullPalette = mode == 2;
        PGRAPHState *pg = &state->pgraph;
        cpu_write(32768, 64);
        memset(state->vram_ptr + 32768,
               badIndex    ? 32 :
               fullPalette ? 255 :
                             31,
               64);
        cpu_write(49152, 1024);
        for (unsigned i = 0; i < 256; i++) {
            uint32_t color = 0xff112233;
            memcpy(state->vram_ptr + 49152 + 4 * i, &color, 4);
        }
        qemu_mutex_lock(&pg->lock);
        NSError *error = nil;
        NV2AMetalSurfaceCache *cache = surfaces.cache;
        NV2AMetalCommands *commands = cache.commands;
        require([draw beginWithError:&error] &&
                    [draw flushDrawWithError:&error],
                error);
        assert(commands.hasPendingRasterPass);
        texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8, 0);
        pg->regs_[NV_PGRAPH_TEXPALETTE0] =
            NV_PGRAPH_TEXPALETTE0_CONTEXT_DMA | (fullPalette ? 0 : 3u << 2);
        NV2AMetalPGRAPHTextures *textures = [draw valueForKey:@"textures"];
        ReaderRasterFeedbackGate *gate = [ReaderRasterFeedbackGate new];
        palette_options_commands = commands;
        palette_options_gate = gate;
        palette_producer_options = palette_raster_options = 0;
        Method feedback = class_getInstanceMethod(
            MTL4CommitOptions.class, @selector(addFeedbackHandler:));
        assert(feedback);
        Method options = class_getInstanceMethod(
            NV2AMetalCommands.class, @selector(optionsForSlot:part:));
        assert(options);
        palette_original_feedback = (void *)method_setImplementation(
            feedback, (IMP)palette_register_feedback);
        palette_original_options =
            (void *)method_setImplementation(options, (IMP)palette_options);
        Method wait = NULL;
        if (fullControl) {
            palette_full_wait_cache = cache;
            wait = class_getInstanceMethod(
                NV2AMetalSurfaceCache.class,
                @selector(waitForProducersOfRecording:error:));
            palette_original_wait =
                (void *)method_setImplementation(wait, (IMP)palette_full_wait);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         [gate releaseFeedback];
                       });
        NV2AMetalSubmission *previous = commands.lastSubmitted;
        require([cache beginRasterProducersWithError:&error], error);
        NV2AMetalPGRAPHTextureSnapshot *snapshot =
            [textures prepareWithError:&error];
        [cache endRasterProducers];
        if (fullControl) {
            method_setImplementation(wait, (IMP)palette_original_wait);
            palette_full_wait_cache = nil;
        }
        NV2AMetalCachedTexture *texture = [snapshot textureAtIndex:0];
        if (fullPalette) {
            require(snapshot && !error, error);
            assert(!palette_producer_options && !palette_raster_options &&
                   commands.lastSubmitted == previous &&
                   !texture.decodeValidated &&
                   !texture.producerRecording.submitted &&
                   commands.hasPendingRasterPass);
            require(
                [cache submitWithError:&error] &&
                    [cache waitForProducersOfRecording:texture.producerRecording
                                                 error:&error] &&
                    [texture validateCompletedWithError:&error],
                error);
        }
        if (!fullPalette && !fullControl) {
            /* The short-palette check now commits only producers. Submit the
             * still-pending raster explicitly to retain this test's delayed
             * raster-feedback coverage after proving the earlier boundary. */
            NV2AMetalSubmission *producer = commands.lastSubmitted;
            assert(palette_producer_options >= 1 && !palette_raster_options &&
                   producer != previous &&
                   !producer.hasSeparateProducerFeedback &&
                   [producer completedWithError:NULL] &&
                   commands.hasPendingRasterPass);
            NSError *submitError = nil;
            require([cache submitWithError:&submitError], submitError);
        }
        method_setImplementation(options, (IMP)palette_original_options);
        method_setImplementation(feedback, (IMP)palette_original_feedback);
        palette_options_commands = nil;
        palette_options_gate = nil;
        NV2AMetalSubmission *receipt = commands.lastSubmitted;
        assert(palette_producer_options >= 1 && palette_raster_options == 1 &&
               receipt.hasSeparateProducerFeedback);
        require([gate waitForNativeFeedback], error);
        assert(gate.delivered == fullControl);
        if (badIndex) {
            assert(!snapshot && error && pg->texture_dirty[0] &&
                   [error.localizedDescription
                       containsString:@"palette index fault"] &&
                   ![receipt completedWithError:NULL]);
            error = nil;
        } else {
            require(snapshot && !error, error);
            assert(texture.decodeValidated &&
                   texture.producerRecording.producersCompleted &&
                   texture.producerRecording.completed == fullControl &&
                   [receipt completedWithError:&error] == fullControl &&
                   !error);
            /* Read the real GPU decode on a private queue while raster feedback
             * is held. The test gate delays feedback, not GPU execution. */
            NV2AMetalCommands *readback =
                [[NV2AMetalCommands alloc] initWithDevice:commands.device
                                                    error:&error];
            require(readback != nil, error);
            NSData *image = nv2a_metal_texture_snapshot(texture.binding.texture,
                                                        readback, &error);
            require(image != nil, error);
            const uint8_t *wire = image.bytes;
            assert(image.length == 40 + 64 * 4 && ldl_be_p(wire + 4) == 2 &&
                   ldl_be_p(wire + 36) == 1);
            for (unsigned i = 40; i < image.length; i += 4)
                assert(wire[i] == 0x11 && wire[i + 1] == 0x22 &&
                       wire[i + 2] == 0x33 && wire[i + 3] == 0xff);
            pg->regs_[NV_PGRAPH_BORDERCOLOR0] = 0x33557799;
            NV2AMetalPGRAPHTextureSnapshot *hit =
                [textures prepareWithError:&error];
            require(hit != nil, error);
            assert([hit textureAtIndex:0].binding.texture ==
                       texture.binding.texture &&
                   [hit textureAtIndex:0].decodeValidated &&
                   commands.lastSubmitted == receipt &&
                   gate.delivered == fullControl);
            /* A following draw consumes the validated texture while the old
             * raster receipt is still pending. Use the live controller path,
             * including attachment reuse and its own queue dependency. */
            [draw invalidateSession];
            require([draw drawWithError:&error], error);
            assert(gate.delivered == fullControl);
        }
        require([cache submitWithError:&error], error);
        assert(gate.delivered == fullControl);
        [gate releaseFeedback];
        require([cache waitUntilIdleWithError:&error], error);
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        color(1, 1, badIndex ? 0xff00ff00 : 0xff112233);
    }
    groups++;
    puts("Palette producer feedback:4 native "
         "valid/invalid/full-wait-control/full-palette cases;"
         "short faults checked before return,64 exact decoded texels,warm "
         "binding reuse;"
         "following draw pixels and raster lifetime preserved,full palette "
         "stays "
         "asynchronous PASS");
}
#endif
