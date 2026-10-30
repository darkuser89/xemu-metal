/* Attachment discovery precedes fetch; recording ownership belongs to raster.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DRAW_ATTACHMENTS_H
#define TEST_METAL_DRAW_ATTACHMENTS_H
static NSArray<NV2AMetalPGRAPHFetchBatch *> *(*attachment_original_fetch)(
    id, SEL, NSArray<NSNumber *> *, NV2AMetalPendingInput *, NSError **);
static uint64_t attachment_expected_serial;
static unsigned attachment_fetch_calls;
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
attachment_fetch(id owner, SEL selector, NSArray<NSNumber *> *prefixes,
                 NV2AMetalPendingInput *input, NSError **error)
{
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    assert(cache.commands.recordingSerial == attachment_expected_serial &&
           !cache.commands.commandBuffer && !cache.recording &&
           !cache.commands.sealedBufferCount);
    attachment_fetch_calls++;
    return attachment_original_fetch(owner, selector, prefixes, input, error);
}
static unsigned attachment_fault_polls;
static BOOL attachment_feedback_failure(id owner, SEL selector, NSError **error)
{
    (void)owner;
    (void)selector;
    attachment_fault_polls++;
    if (error)
        *error = [NSError errorWithDomain:@"test.attachment.feedback"
                                     code:1
                                 userInfo:nil];
    return NO;
}
static void draw_attachment_tests(void)
{
    NSError *error = nil;
    unsigned empty = 0, raster = 0;
    for (unsigned attachments = 0; attachments < 3; attachments++)
        for (unsigned z24 = 0; z24 < 2; z24++)
            for (unsigned swizzle = 0; swizzle < 2; swizzle++)
                for (unsigned scale = 1; scale <= 2; scale++)
                    for (unsigned active = 0; active < 2; active++) {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        if (attachments == 1)
                            pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
                        if (attachments)
                            pg->regs_[NV_PGRAPH_CONTROL_0] |=
                                NV_PGRAPH_CONTROL_0_ZENABLE |
                                NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16;
                        pg->surface_shape.zeta_format =
                            z24 ? NV097_SET_SURFACE_FORMAT_ZETA_Z24S8 :
                                  NV097_SET_SURFACE_FORMAT_ZETA_Z16;
                        pg->surface_zeta.pitch = z24 ? 32 : 16;
                        pg->surface_scale_factor = scale;
                        if (swizzle) {
                            pg->surface_type =
                                NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
                            pg->surface_shape.log_width =
                                pg->surface_shape.log_height = 3;
                        }
                        pg->draw_arrays_length = pg->inline_elements_length =
                            pg->inline_buffer_length = pg->inline_array_length =
                                0;
                        qemu_mutex_lock(&pg->lock);
                        require([surfaces prepareColor:attachments != 1
                                                  zeta:attachments != 0
                                          forRendering:NO
                                                 error:&error],
                                error);
                        NV2AMetalSurfaceCache *cache = surfaces.cache;
                        require([cache submitWithError:&error] &&
                                    [cache waitUntilIdleWithError:&error],
                                error);
                        uint64_t serial = cache.commands.recordingSerial;
                        NV2AMetalCachedSurface *color = surfaces.color;
                        NV2AMetalCachedSurface *zeta = surfaces.zeta;
                        uint64_t colorGeneration = color.generation;
                        uint64_t zetaGeneration = zeta.generation;
                        float current[16][4];
                        for (unsigned i = 0; i < 16; i++)
                            memcpy(current[i],
                                   pg->vertex_attributes[i].inline_value, 16);
                        if (active)
                            require([draw beginWithError:&error] &&
                                        [draw endWithError:&error],
                                    error);
                        else
                            require([draw drawWithError:&error], error);
                        assert(cache.commands.recordingSerial == serial &&
                               !cache.commands.sealedBufferCount &&
                               !cache.commands.commandBuffer &&
                               !cache.recording);
                        assert(
                            surfaces.color == color && surfaces.zeta == zeta &&
                            color.generation == colorGeneration &&
                            zeta.generation == zetaGeneration && !color.dirty &&
                            !zeta.dirty && pg->draw_time == (int)active);
                        for (unsigned i = 0; i < 16; i++)
                            assert(!memcmp(
                                current[i],
                                pg->vertex_attributes[i].inline_value, 16));
                        qemu_mutex_unlock(&pg->lock);
                        empty++;
                    }
    for (unsigned active = 0; active < 2; active++) {
        fixture();
        render();
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = 0;
        qemu_mutex_lock(&pg->lock);
        NV2AMetalSurfaceCache *cache = surfaces.cache;
        uint64_t serial = cache.commands.recordingSerial;
        NSUInteger sections = cache.commands.sealedBufferCount;
        NV2AMetalSubmission *receipt = cache.commands.lastSubmitted;
        uint64_t generation = surfaces.color.generation;
        float current[4];
        memcpy(current, pg->vertex_attributes[0].inline_value, 16);
        assert(sections && surfaces.color.dirty);
        for (unsigned i = 0; i < 64; i++) {
            require(active ? [draw beginWithError:&error] &&
                                 [draw endWithError:&error] :
                             [draw drawWithError:&error],
                    error);
            assert(cache.commands.recordingSerial == serial &&
                   cache.commands.sealedBufferCount == sections &&
                   cache.commands.lastSubmitted == receipt &&
                   !cache.commands.commandBuffer && !cache.recording &&
                   surfaces.color.dirty &&
                   surfaces.color.generation == generation &&
                   !memcmp(current, pg->vertex_attributes[0].inline_value, 16));
        }
        assert(pg->draw_time == 1 + (active ? 64 : 0));
        qemu_mutex_unlock(&pg->lock);
        read_vram(1024, 256);
        color(1, 1, 0xff00ff00);
    }
    Method method = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:error:));
    assert(method);
    for (unsigned mode = 0; mode < 3; mode++)
        for (unsigned active = 0; active < 2; active++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            if (mode) {
                pg->regs_[NV_PGRAPH_CSV0_D] =
                    2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                pg->enable_vertex_program_write = mode == 2;
                mov(0, 0, 0, false);
                mov(1, 3, 3, true);
            }
            qemu_mutex_lock(&pg->lock);
            require([surfaces prepareColor:YES
                                      zeta:NO
                              forRendering:NO
                                     error:&error],
                    error);
            NV2AMetalSurfaceCache *cache = surfaces.cache;
            require([cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            if (active)
                require([draw beginWithError:&error], error);
            attachment_expected_serial = cache.commands.recordingSerial;
            attachment_fetch_calls = 0;
            attachment_original_fetch =
                (void *)method_setImplementation(method, (IMP)attachment_fetch);
            BOOL ok = active ? [draw endWithError:&error] :
                               [draw drawWithError:&error];
            method_setImplementation(method, (IMP)attachment_original_fetch);
            require(ok, error);
            assert(attachment_fetch_calls == 1 && surfaces.color.dirty &&
                   !cache.commands.commandBuffer);
            qemu_mutex_unlock(&pg->lock);
            read_vram(1024, 256);
            color(1, 1, 0xff00ff00);
            assert(pg->vertex_attributes[0].inline_value[0] == 0 &&
                   pg->vertex_attributes[0].inline_value[1] == 8);
            raster++;
        }
    Method collect = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class, @selector(collectCompletedWithError:));
    assert(collect);
    for (unsigned active = 0; active < 2; active++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = 0;
        qemu_mutex_lock(&pg->lock);
        require([surfaces prepareColor:YES
                                  zeta:NO
                          forRendering:NO
                                 error:&error],
                error);
        NV2AMetalSurfaceCache *cache = surfaces.cache;
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        if (active)
            require([draw beginWithError:&error], error);
        uint64_t serial = cache.commands.recordingSerial;
        float current[4];
        memcpy(current, pg->vertex_attributes[0].inline_value, 16);
        attachment_fault_polls = 0;
        IMP original =
            method_setImplementation(collect, (IMP)attachment_feedback_failure);
        error = nil;
        BOOL ok =
            active ? [draw endWithError:&error] : [draw drawWithError:&error];
        method_setImplementation(collect, original);
        assert(!ok && attachment_fault_polls == 1 &&
               [error.domain isEqualToString:@"test.attachment.feedback"] &&
               !memcmp(current, pg->vertex_attributes[0].inline_value, 16) &&
               !pg->draw_time && !surfaces.color.dirty &&
               cache.commands.recordingSerial == serial &&
               !cache.commands.commandBuffer && !cache.recording &&
               !cache.commands.sealedBufferCount);
        require(active ? [draw endWithError:&error] :
                         [draw drawWithError:&error],
                error);
        assert(cache.commands.recordingSerial == serial &&
               !cache.commands.commandBuffer && !cache.recording &&
               !cache.commands.sealedBufferCount);
        qemu_mutex_unlock(&pg->lock);
    }
    assert(empty == 48 && raster == 6);
    groups++;
    puts("Draw attachment discovery:48 empty standalone/Begin-End cases "
         "without native recordings/sections or Current/dirty/generation "
         "changes across color/zeta/both,Z16/Z24S8,linear/swizzled,scale1/2;"
         "128 empty draws preserve unsubmitted raster sections/receipts,dirty "
         "GPU pixels and Current;"
         "six fixed/program/write-enabled warm raster paths acquire no "
         "attachment recording before fetch,exact green GPU pixel/Current;"
         "injected feedback-poll failure rejects both empty paths before "
         "recording,preserves Current/dirty state;retry after restoring poll "
         "succeeds PASS");
}
#endif
