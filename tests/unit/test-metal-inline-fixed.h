/* Known Float4/context producer/raster recording without a CPU GPU wait.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INLINE_FIXED_H
#define TEST_METAL_INLINE_FIXED_H
static BOOL inline_fixed_fail;
static BOOL (*inline_fixed_original_emit)(id, SEL, id<MTL4RenderCommandEncoder>,
                                          NV2AMetalCommands *, NSError **);
static BOOL inline_fixed_emit(id object, SEL selector,
                              id<MTL4RenderCommandEncoder> encoder,
                              NV2AMetalCommands *commands, NSError **error)
{
    if (inline_fixed_fail) {
        inline_fixed_fail = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.inline-fixed"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return inline_fixed_original_emit(object, selector, encoder, commands,
                                      error);
}
static void inline_fixed_context(PGRAPHState *pg, unsigned mode)
{
    if (!mode)
        return;
    unsigned policy = mode > 4 ? mode - 4 : mode;
    pg->regs_[NV_PGRAPH_CSV0_D] =
        2u << 30 | (policy % 2 ? 0 : NV_PGRAPH_CSV0_D_RANGE_MODE);
    pg->enable_vertex_program_write = policy >= 3;
    mov(0, 0, 0, false);
    mov(1, 3, 3, true);
    if (mode > 4) {
        pg->program_data[1][1] =
            (pg->program_data[1][1] & ~(255u << 13)) | 96u << 13;
        pg->program_data[1][2] =
            (pg->program_data[1][2] & ~(3u << 26)) | 3u << 26;
        pg->program_data[1][3] |= 2;
        const float green[4] = { 0, 1, 0, 1 };
        memcpy(pg->vsh_constants[96], green, sizeof(green));
    }
}
static void inline_fixed_tests(void)
{
    NSError *error = nil;
    unsigned pairs = 0;
    const unsigned primitives[] = {
        PRIM_TYPE_POINTS,         PRIM_TYPE_LINES, PRIM_TYPE_TRIANGLES,
        PRIM_TYPE_TRIANGLE_STRIP, PRIM_TYPE_QUADS, PRIM_TYPE_LINE_LOOP
    };
    for (unsigned mode = 0; mode < 9; mode++)
        for (unsigned active = 0; active < 2; active++)
            for (unsigned query = 0; query < 2; query++)
                for (unsigned primitive = 0; primitive < 6; primitive++) {
                    uint8_t reference[256];
                    uint32_t current[16][4], constants[192][4], count = 0;
                    for (unsigned known = 0; known < 4; known++) {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        pg->primitive_mode = primitives[primitive];
                        inline_fixed_context(pg, mode);
                        pg->draw_arrays_length = 0;
                        pg->zpass_pixel_count_enable = query;
                        pg->dma_report = 64;
                        dma[2].limit = 8191;
                        float positions[4][4] = { { 0, 0, 32768, 1 },
                                                  { 8, 0, 32768, 1 },
                                                  { 0, 8, 32768, 1 },
                                                  { 8, 8, 32768, 1 } };
                        unsigned vertices = primitive == 2 ? 3 : 4;
                        if (known == 1) {
                            pg->inline_buffer_length = vertices;
                            pg->vertex_attributes[0].inline_buffer =
                                (float *)positions;
                            pg->vertex_attributes[0].inline_buffer_populated =
                                true;
                        } else if (known == 2) {
                            pg->inline_array_length = vertices * 4;
                            memcpy(pg->inline_array, positions, vertices * 16);
                        } else if (known == 3) {
                            VertexAttribute *diffuse =
                                &pg->vertex_attributes[3];
                            diffuse->format =
                                NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
                            diffuse->size = 1;
                            diffuse->count = 4;
                            pg->inline_array_length = vertices * 5;
                            for (unsigned v = 0; v < vertices; v++) {
                                memcpy(pg->inline_array + v * 5, positions[v],
                                       16);
                                pg->inline_array[v * 5 + 4] = 0xff00ff00;
                            }
                        } else {
                            pg->draw_arrays_length = 1;
                            pg->draw_arrays_count[0] = vertices;
                            cpu_write(16384, vertices * 16);
                            memcpy(state->vram_ptr + 16384, positions,
                                   vertices * 16);
                        }
                        qemu_mutex_lock(&pg->lock);
                        [draw.reports clear];
                        if (active)
                            require([draw beginWithError:&error], error);
                        id<MTLSharedEvent> gate = nil;
                        Method submit = class_getInstanceMethod(
                            NV2AMetalCommands.class,
                            @selector(submitWithError:));
                        Method wait = class_getInstanceMethod(
                            NV2AMetalCommands.class,
                            @selector(waitUntilIdleWithError:));
                        Method receiptWait = class_getInstanceMethod(
                            NV2AMetalCommands.class,
                            @selector(waitForSubmission:error:));
                        {
                            gate =
                                [surfaces.cache.commands.device newSharedEvent];
                            Ivar queueIvar = class_getInstanceVariable(
                                NV2AMetalCommands.class, "_queue");
                            id<MTL4CommandQueue> queue = object_getIvar(
                                surfaces.cache.commands, queueIvar);
                            assert(gate && queue && submit && wait &&
                                   receiptWait);
                            [queue waitForEvent:gate value:1];
                            id<MTLSharedEvent> watchdog = gate;
                            dispatch_after(
                                dispatch_time(DISPATCH_TIME_NOW,
                                              10 * NSEC_PER_SEC),
                                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                ^{
                                  if (!watchdog.signaledValue)
                                      watchdog.signaledValue = 2;
                                });
                            shared_original_submit =
                                (void *)method_setImplementation(
                                    submit, (IMP)shared_submit_count);
                            shared_original_wait =
                                (void *)method_setImplementation(
                                    wait, (IMP)shared_wait_count);
                            shared_original_submission_wait =
                                (void *)method_setImplementation(
                                    receiptWait,
                                    (IMP)shared_submission_wait_count);
                            shared_draw_submits = shared_draw_waits = 0;
                        }
                        require(active ? [draw endWithError:&error] :
                                         [draw drawWithError:&error],
                                error);
                        assert(
                            pg->draw_time == 1 && !pg->compressed_attrs &&
                            !pg->vertex_attributes[0].inline_buffer_populated);
                        {
                            method_setImplementation(
                                submit, (IMP)shared_original_submit);
                            method_setImplementation(wait,
                                                     (IMP)shared_original_wait);
                            method_setImplementation(
                                receiptWait,
                                (IMP)shared_original_submission_wait);
                            assert(!shared_draw_submits && !shared_draw_waits &&
                                   !gate.signaledValue);
                            if (known)
                                for (unsigned a = 0; a < 16; a++)
                                    assert(!memcmp(
                                        pg->vertex_attributes[a].inline_value,
                                        current[a], 16));
                            if (known)
                                assert(!memcmp(pg->vsh_constants, constants,
                                               sizeof(constants)));
                            memset(positions, 0xa5, sizeof(positions));
                            if (known >= 2)
                                memset(pg->inline_array, 0xa5,
                                       sizeof(pg->inline_array));
                            require([surfaces.cache submitWithError:&error],
                                    error);
                            assert(![surfaces.cache.commands.lastSubmitted
                                completedWithError:NULL]);
                            gate.signaledValue = 1;
                        }
                        qemu_mutex_unlock(&pg->lock);
                        uint32_t actualCount = query ? batch_report() : 0;
                        read_vram(1024, 256);
                        if (!known) {
                            memcpy(reference, state->vram_ptr + 1024, 256);
                            for (unsigned a = 0; a < 16; a++)
                                memcpy(current[a],
                                       pg->vertex_attributes[a].inline_value,
                                       16);
                            memcpy(constants, pg->vsh_constants,
                                   sizeof(constants));
                            count = actualCount;
                        } else {
                            assert(!memcmp(reference, state->vram_ptr + 1024,
                                           256));
                            assert(actualCount == count);
                            pairs++;
                        }
                    }
                }
    /* A later failed draw must not discard a queued successful GPU prefix. */
    for (unsigned mode = 0; mode < 9; mode++)
        for (unsigned packed = 0; packed < 3; packed++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            inline_fixed_context(pg, mode);
            float positions[3][4] = { { 0, 0, 32768, 1 },
                                      { 8, 0, 32768, 1 },
                                      { 0, 8, 32768, 1 } };
            pg->draw_arrays_length = 0;
            if (packed == 2) {
                VertexAttribute *diffuse = &pg->vertex_attributes[3];
                diffuse->format =
                    NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
                diffuse->size = 1;
                diffuse->count = 4;
                pg->inline_array_length = 15;
                for (unsigned v = 0; v < 3; v++) {
                    memcpy(pg->inline_array + v * 5, positions[v], 16);
                    pg->inline_array[v * 5 + 4] = 0xff00ff00;
                }
            } else if (packed) {
                pg->inline_array_length = 12;
                memcpy(pg->inline_array, positions, sizeof(positions));
            } else {
                pg->inline_buffer_length = 3;
                pg->vertex_attributes[0].inline_buffer = (float *)positions;
                pg->vertex_attributes[0].inline_buffer_populated = true;
            }
            render();
            NSUInteger prefix = surfaces.cache.commands.sealedBufferCount;
            assert(prefix);
            uint32_t saved[4];
            memcpy(saved, pg->vertex_attributes[0].inline_value, sizeof(saved));
            pg->vertex_attributes[0].inline_buffer_populated = !packed;
            pg->vertex_attributes[3].inline_value[1] = 0;
            pg->vertex_attributes[3].inline_value[2] = 1;
            if (packed == 2)
                for (unsigned v = 0; v < 3; v++)
                    pg->inline_array[v * 5 + 4] = 0xff0000ff;
            if (mode > 4) {
                const float blue[4] = { 0, 0, 1, 1 };
                memcpy(pg->vsh_constants[96], blue, sizeof(blue));
            }
            Method emit = class_getInstanceMethod(
                NV2AMetalPixelDraw.class,
                @selector(encodeWithRenderEncoder:commands:error:));
            assert(emit);
            inline_fixed_original_emit =
                (void *)method_setImplementation(emit, (IMP)inline_fixed_emit);
            inline_fixed_fail = YES;
            qemu_mutex_lock(&pg->lock);
            assert(![draw drawWithError:&error] &&
                   [error.domain isEqualToString:@"test.inline-fixed"]);
            qemu_mutex_unlock(&pg->lock);
            method_setImplementation(emit, (IMP)inline_fixed_original_emit);
            assert(!inline_fixed_fail && pg->draw_time == 1 &&
                   surfaces.cache.commands.sealedBufferCount ==
                       prefix + (mode != 0) &&
                   pg->vertex_attributes[0].inline_buffer_populated ==
                       !packed &&
                   !memcmp(saved, pg->vertex_attributes[0].inline_value,
                           sizeof(saved)));
            read_vram(1024, 256);
            color(1, 1, 0xff00ff00);
            render();
            read_vram(1024, 256);
            color(1, 1, 0xff0000ff);
        }
    assert(pairs == 648);
    printf(
        "Proven inline GPU chain: %u DMA/Float4/Float32-array/D3D-byte-array "
        "exact "
        "image/Current/constants/query pairs; "
        "Fixed/readonly/WriteEnable-without-stores, direct/zero-IDX relative, "
        "USER/FULL, six "
        "primitives, standalone/Begin-End, GPU gate pending while Draw "
        "returns with "
        "zero producer submits/waits; source mutation and failed "
        "suffix/prefix/retry PASS\n",
        pairs);
    groups++;
}
#endif
