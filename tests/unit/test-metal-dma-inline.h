/* Current and Immediate boundaries with CPU-readable DMA under a GPU gate.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DMA_INLINE_H
#define TEST_METAL_DMA_INLINE_H
static void dma_inline_current_tests(void)
{
    const unsigned formats[] = { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP };
    unsigned cases = 0;
    for (unsigned mode = 0; mode < 3; mode++)
        for (unsigned indexed = 0; indexed < 2; indexed++)
            for (unsigned f = 0; f < G_N_ELEMENTS(formats); f++) {
                uint32_t expected[16][4];
                uint8_t image[256];
                for (unsigned captured = 0; captured < 2; captured++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    VertexAttribute *diffuse = &pg->vertex_attributes[3];
                    diffuse->format = formats[f];
                    diffuse->count = f == 5 ? 1 : 4;
                    diffuse->size = f == 0 || f == 5 ? 4 :
                                    f == 3 || f == 4 ? 2 :
                                                       1;
                    unsigned element = diffuse->size * diffuse->count;
                    diffuse->offset = 512;
                    diffuse->stride = element + 3;
                    cpu_write(16384 + 512, 128);
                    for (unsigned index = 0; index < 6; index++)
                        for (unsigned k = 0; k < diffuse->count; k++) {
                            uint32_t code =
                                f == 1 || f == 2 ?
                                    (unsigned[]){ 17 + index, 127 - index,
                                                  241 - index, 255 }[k] :
                                f == 5 ?
                                    (511 + index) | ((511 - index) << 11) |
                                        ((512 + index) << 22) :
                                    (unsigned[]){ 1234 + index, 23456 - index,
                                                  32768 + index, 32767 }[k];
                            if (!f) {
                                float v =
                                    (float[]){ index / 16.f, .5f, .25f, 1 }[k];
                                memcpy(&code, &v, 4);
                            }
                            uint8_t *out = state->vram_ptr + 16384 + 512 +
                                           index * diffuse->stride +
                                           k * diffuse->size;
                            for (unsigned b = 0; b < diffuse->size; b++)
                                out[b] = code >> (8 * b);
                        }
                    if (mode) {
                        pg->regs_[NV_PGRAPH_CSV0_D] =
                            2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                        pg->enable_vertex_program_write = mode == 2;
                        for (unsigned slot = 0; slot < 2; slot++) {
                            uint32_t *t = pg->program_data[slot];
                            unsigned a = slot ? 3 : 0;
                            t[1] = 1u << 21 | a << 9 | 27;
                            t[2] = 2u << 26;
                            t[3] = 1u << 11 | a << 3 | 15u << 12 | slot;
                        }
                    }
                    begin(PRIM_TYPE_TRIANGLES);
                    if (indexed) {
                        send_method(NV097_ARRAY_ELEMENT32, 5);
                        send_method(NV097_ARRAY_ELEMENT32, 4);
                        send_method(NV097_ARRAY_ELEMENT32, 2);
                    } else {
                        arrays(3, 3);
                        arrays(0, 3);
                    }
                    NSError *error = nil;
                    id<MTLSharedEvent> gate = nil;
                    Method submit = class_getInstanceMethod(
                        NV2AMetalCommands.class, @selector(submitWithError:));
                    Method wait = class_getInstanceMethod(
                        NV2AMetalCommands.class,
                        @selector(waitUntilIdleWithError:));
                    Method receipt = class_getInstanceMethod(
                        NV2AMetalCommands.class,
                        @selector(waitForSubmission:error:));
                    if (!captured) {
                        /* A real GPU writer forces the reference to complete
                         * Fetch feedback. Its equal bytes are not assumed ready
                         * by the host. */
                        NSUInteger tail = 16384 + (indexed ? 2 : 5) * 16;
                        id<MTLBuffer> source = [surfaces.cache.commands.device
                            newBufferWithBytes:state->vram_ptr + tail
                                        length:16
                                       options:MTLResourceStorageModeShared];
                        assert(source);
                        require([surfaces.cache
                                    prepareGPUWriteAtAddress:tail
                                                      length:16
                                                       error:&error],
                                error);
                        require([surfaces.cache.commands addResource:source
                                                               error:&error],
                                error);
                        id<MTL4ComputeCommandEncoder> e =
                            [surfaces.cache.commands
                                    .commandBuffer computeCommandEncoder];
                        assert(e);
                        [e copyFromBuffer:source
                                 sourceOffset:0
                                     toBuffer:surfaces.cache.vram
                            destinationOffset:tail
                                         size:16];
                        [e endEncoding];
                    } else {
                        NV2AMetalCommands *commands = surfaces.cache.commands;
                        gate = [commands.device newSharedEvent];
                        assert(gate);
                        Ivar ivar = class_getInstanceVariable(
                            NV2AMetalCommands.class, "_queue");
                        id<MTL4CommandQueue> queue =
                            object_getIvar(commands, ivar);
                        [queue waitForEvent:gate value:1];
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                              if (!gate.signaledValue)
                                  gate.signaledValue = 2;
                            });
                        packed_inline_submit = (void *)method_setImplementation(
                            submit, (IMP)packed_inline_count_submit);
                        packed_inline_wait = (void *)method_setImplementation(
                            wait, (IMP)packed_inline_count_wait);
                        packed_inline_receipt =
                            (void *)method_setImplementation(
                                receipt, (IMP)packed_inline_count_receipt);
                        packed_inline_submits = packed_inline_waits = 0;
                    }
                    end();
                    if (captured) {
                        assert(!gate.signaledValue && !packed_inline_submits &&
                               !packed_inline_waits);
                        for (unsigned a = 0; a < 16; a++)
                            assert(
                                !memcmp(pg->vertex_attributes[a].inline_value,
                                        expected[a], 16));
                        assert(!nv2a_metal_try_cpu_access(
                            surfaces.cache.cpuAccessGuard,
                            16384 + (indexed ? 2 : 5) * 16, 16, YES));
                        begin(PRIM_TYPE_POINTS);
                        inline_position(100, 100);
                        const float blue[] = { 0, 0, 1, 1 };
                        uint32_t data[4];
                        memcpy(data, blue, 16);
                        assert(method(NV097_SET_VERTEX_DATA4F_M + 3 * 16,
                                      data[0], data, 4, 0, true) == 4);
                        assert(
                            diffuse->inline_buffer_populated &&
                            !memcmp(diffuse->inline_buffer, expected[3], 16));
                        end();
                        method_setImplementation(submit,
                                                 (IMP)packed_inline_submit);
                        method_setImplementation(wait, (IMP)packed_inline_wait);
                        method_setImplementation(receipt,
                                                 (IMP)packed_inline_receipt);
                        assert(!gate.signaledValue && !packed_inline_submits &&
                               !packed_inline_waits);
                        gate.signaledValue = 1;
                    }
                    (void)color(0, 0);
                    if (!captured) {
                        for (unsigned a = 0; a < 16; a++)
                            memcpy(expected[a],
                                   pg->vertex_attributes[a].inline_value, 16);
                        memcpy(image, state->vram_ptr + 1024, 256);
                    } else {
                        assert(!memcmp(image, state->vram_ptr + 1024, 256));
                        uint32_t current[16][4];
                        for (unsigned a = 0; a < 16; a++)
                            memcpy(current[a],
                                   pg->vertex_attributes[a].inline_value, 16);
                        int fd = new_vertex_snapshot_file();
                        save_vertex_snapshot(fd);
                        before_ram_load();
                        for (unsigned a = 0; a < 16; a++)
                            memset(pg->vertex_attributes[a].inline_value, 0,
                                   16);
                        assert(load_vertex_snapshot(fd) == 0);
                        after_ram_load();
                        close(fd);
                        for (unsigned a = 0; a < 16; a++)
                            assert(!memcmp(
                                current[a],
                                pg->vertex_attributes[a].inline_value, 16));
                        cases++;
                    }
                }
            }
    assert(cases == 36);
    groups++;
    puts("PGRAPH DMA Current:36 exact GPU-feedback-reference frame/Current "
         "pairs;all six formats,Arrays highest-versus-last and Indexed last "
         "selection,Fixed/readonly/nonwriting;zero submit/wait before GPU gate "
         "release,VRAM write guard,real Immediate allocation before completion "
         "and36 VMState Current roundtrips PASS");
}
#endif
