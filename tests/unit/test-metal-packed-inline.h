/* Converted inline Current before the real common Immediate allocator.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PACKED_INLINE_H
#define TEST_METAL_PACKED_INLINE_H
static unsigned packed_inline_submits, packed_inline_waits;
static BOOL (*packed_inline_submit)(id, SEL, NSError **);
static BOOL (*packed_inline_wait)(id, SEL, NSError **);
static BOOL (*packed_inline_receipt)(id, SEL, NV2AMetalSubmission *,
                                     NSError **);
static BOOL packed_inline_count_submit(id object, SEL selector, NSError **error)
{
    packed_inline_submits++;
    return packed_inline_submit(object, selector, error);
}
static BOOL packed_inline_count_wait(id object, SEL selector, NSError **error)
{
    packed_inline_waits++;
    return packed_inline_wait(object, selector, error);
}
static BOOL packed_inline_count_receipt(id object, SEL selector,
                                        NV2AMetalSubmission *submission,
                                        NSError **error)
{
    packed_inline_waits++;
    return packed_inline_receipt(object, selector, submission, error);
}
static void packed_inline_current_tests(void)
{
    const unsigned formats[] = { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP };
    const float positions[3][4] = { { 0, 0, 32768, 1 },
                                    { 8, 0, 32768, 1 },
                                    { 0, 8, 32768, 1 } };
    for (unsigned f = 0; f < G_N_ELEMENTS(formats); f++) {
        unsigned format = formats[f], components = f == 4 ? 1 : 4;
        unsigned laneBytes = f < 2 ? 1 : f == 4 ? 4 : 2;
        unsigned element = components * laneBytes;
        uint8_t colors[24] = { 0 };
        for (unsigned v = 0; v < 3; v++)
            for (unsigned k = 0; k < components; k++) {
                uint32_t code =
                    f < 2  ? (unsigned[]){ 17, 127, 241, 255 }[k] :
                    f == 4 ? 511u | (1536u << 11) | (512u << 22) :
                             (unsigned[]){ 1234, 23456, 65413, 32767 }[k];
                for (unsigned b = 0; b < laneBytes; b++)
                    colors[v * element + k * laneBytes + b] = code >> (8 * b);
            }
        uint32_t expected[4];
        for (unsigned captured = 0; captured < 2; captured++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            VertexAttribute *diffuse = &pg->vertex_attributes[3];
            diffuse->format = format;
            diffuse->count = components;
            diffuse->size = laneBytes;
            diffuse->stride = element;
            diffuse->offset = 512;
            if (!captured) {
                cpu_write(16384 + 512, 3 * element);
                memcpy(state->vram_ptr + 16384 + 512, colors, 3 * element);
                begin(PRIM_TYPE_TRIANGLES);
                arrays(0, 3);
                end();
                memcpy(expected, diffuse->inline_value, 16);
                continue;
            }
            uint32_t words[18] = { 0 };
            unsigned stride = 4 + element / 4;
            for (unsigned v = 0; v < 3; v++) {
                memcpy(words + v * stride, positions[v], 16);
                memcpy(words + v * stride + 4, colors + v * element, element);
            }
            begin(PRIM_TYPE_TRIANGLES);
            assert(method(NV097_INLINE_ARRAY, words[0], words, 3 * stride, 0,
                          false) == (int)(3 * stride));
            NV2AMetalCommands *commands = surfaces.cache.commands;
            id<MTLSharedEvent> gate = [commands.device newSharedEvent];
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
            assert(gate && queue);
            [queue waitForEvent:gate value:1];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             if (!gate.signaledValue)
                                 gate.signaledValue = 2;
                           });
            Method submit = class_getInstanceMethod(
                NV2AMetalCommands.class, @selector(submitWithError:));
            Method wait = class_getInstanceMethod(
                NV2AMetalCommands.class, @selector(waitUntilIdleWithError:));
            Method receipt = class_getInstanceMethod(
                NV2AMetalCommands.class, @selector(waitForSubmission:error:));
            packed_inline_submit = (void *)method_setImplementation(
                submit, (IMP)packed_inline_count_submit);
            packed_inline_wait = (void *)method_setImplementation(
                wait, (IMP)packed_inline_count_wait);
            packed_inline_receipt = (void *)method_setImplementation(
                receipt, (IMP)packed_inline_count_receipt);
            packed_inline_submits = packed_inline_waits = 0;
            end();
            assert(!gate.signaledValue && !packed_inline_submits &&
                   !packed_inline_waits &&
                   !memcmp(diffuse->inline_value, expected, 16));
            memset(words, 0xa5, sizeof(words));
            begin(PRIM_TYPE_POINTS);
            inline_position(4, 4);
            const float blue[4] = { 0, 0, 1, 1 };
            uint32_t bits[4];
            memcpy(bits, blue, 16);
            assert(method(NV097_SET_VERTEX_DATA4F_M + 3 * 16, bits[0], bits, 4,
                          0, true) == 4);
            assert(diffuse->inline_buffer_populated &&
                   !memcmp(diffuse->inline_buffer, expected, 16));
            end();
            method_setImplementation(submit, (IMP)packed_inline_submit);
            method_setImplementation(wait, (IMP)packed_inline_wait);
            method_setImplementation(receipt, (IMP)packed_inline_receipt);
            assert(!gate.signaledValue && !packed_inline_submits &&
                   !packed_inline_waits);
            gate.signaledValue = 1;
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            require([draw flushWithError:&error], error);
            qemu_mutex_unlock(&pg->lock);
            assert(!memcmp(diffuse->inline_value, expected, 16));
            int fd = new_vertex_snapshot_file();
            save_vertex_snapshot(fd);
            before_ram_load();
            memset(diffuse->inline_value, 0, 16);
            assert(load_vertex_snapshot(fd) == 0);
            after_ram_load();
            close(fd);
            assert(!memcmp(diffuse->inline_value, expected, 16));
            begin(PRIM_TYPE_POINTS);
            inline_position(4, 4);
            assert(method(NV097_SET_VERTEX_DATA4F_M + 3 * 16, bits[0], bits, 4,
                          0, true) == 4);
            assert(diffuse->inline_buffer_populated &&
                   !memcmp(diffuse->inline_buffer, expected, 16));
            end();
            (void)color(1, 1);
        }
    }
    groups++;
    puts("PGRAPH converted InlineArray:five byte/short/CMP formats match "
         "completed DMA Current;real common dispatch and Immediate allocator "
         "before GPU gate release with zero submits/waits,source "
         "mutation,native completion,vertex VMState roundtrip and following "
         "Immediate Current PASS");
}
#endif
