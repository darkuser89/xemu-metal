/* Inline Fetch/XF must finish before unrelated, gated surface work.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_INLINE_PRODUCER_H
#define TEST_METAL_INLINE_PRODUCER_H
static id<MTLSharedEvent> ip_gate;
static id<MTLBuffer> ip_source, ip_destination;
static BOOL ip_enabled;
static BOOL ip_clean_alias;
static unsigned ip_encodes, ip_resolves;
static NSTimeInterval ip_gate_started;
static NSArray *(*ip_original_encode)(id, SEL, NSArray<NSNumber *> *,
                                      NV2AMetalPendingInput *, NSError **);
static NV2AMetalEpochResult *(*ip_original_resolve)(id, SEL, NSError **);

static NSArray *ip_encode(id object, SEL selector,
                          NSArray<NSNumber *> *prefixes,
                          NV2AMetalPendingInput *input, NSError **error)
{
    if (!ip_enabled)
        return ip_original_encode(object, selector, prefixes, input, error);
    NV2AMetalCommands *surface = surfaces.cache.commands;
    if (ip_clean_alias) {
        NV2AMetalSurfaceConfig c = {
            .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            .width = 8,
            .height = 4,
            .pitch = 32,
            .scale = 1,
            .color = YES
        };
        NV2AMetalCachedSurface *alias =
            [surfaces.cache prepareSurfaceAtAddress:16384
                                             config:&c
                                              frame:0
                                              error:error];
        require(alias != nil, *error);
        assert(!alias.dirty);
    }
    require([surfaces.cache prepareGPUReadAtAddress:0 length:0 error:error],
            *error);
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    assert(queueIvar);
    id<MTL4CommandQueue> queue = object_getIvar(surface, queueIvar);
    [queue waitForEvent:ip_gate value:1];
    require([surface addResource:ip_source error:error], *error);
    require([surface addResource:ip_destination error:error], *error);
    id<MTL4ComputeCommandEncoder> e =
        [surface.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:ip_source
             sourceOffset:0
                 toBuffer:ip_destination
        destinationOffset:0
                     size:4];
    [e endEncoding];
    require([surfaces.cache submitWithError:error], *error);
    id<MTLSharedEvent> gate = ip_gate;
    ip_gate_started = NSProcessInfo.processInfo.systemUptime;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
    NSArray *batches =
        ip_original_encode(object, selector, prefixes, input, error);
    require(batches != nil, *error);
    NV2AMetalCommands *producer = [object encodingCommands];
    assert(producer && producer != surface && producer.commandBuffer &&
           producer.device == surface.device);
    assert(!surface.commandBuffer && !ip_gate.signaledValue);
    ip_encodes++;
    return batches;
}
static NV2AMetalEpochResult *ip_resolve(id object, SEL selector,
                                        NSError **error)
{
    NV2AMetalEpochResult *result = ip_original_resolve(object, selector, error);
    if (!ip_enabled)
        return result;
    require(result != nil, *error);
    if (ip_gate.signaledValue || *(uint32_t *)ip_destination.contents)
        fprintf(stderr,
                "Independent producer gate: encode%u resolve%u value%llu "
                "copy=%08x elapsed=%.3fs\n",
                ip_encodes, ip_resolves,
                (unsigned long long)ip_gate.signaledValue,
                *(uint32_t *)ip_destination.contents,
                NSProcessInfo.processInfo.systemUptime - ip_gate_started);
    assert(!ip_gate.signaledValue && !*(uint32_t *)ip_destination.contents);
    assert(result.vertexCount == 3 && result.vertices);
    assert(state->pgraph.vertex_attributes[0].inline_value[0] == 0 &&
           state->pgraph.vertex_attributes[0].inline_value[1] == 8);
    ip_resolves++;
    ip_gate.signaledValue = 1;
    return result;
}
static void inline_producer_tests(void)
{
    Method encode = class_getInstanceMethod(
        NV2AMetalPGRAPHFetch.class,
        @selector(encodeIndependentSnapshotsWithPrefixes:indexedInput:error:));
    Method resolve = class_getInstanceMethod(NV2AMetalEpochEncoding.class,
                                             @selector(resolveWithError:));
    assert(encode && resolve);
    ip_original_encode =
        (void *)method_setImplementation(encode, (IMP)ip_encode);
    ip_original_resolve =
        (void *)method_setImplementation(resolve, (IMP)ip_resolve);
    ip_encodes = ip_resolves = 0;
    for (unsigned active = 0; active < 2; active++)
        for (unsigned kind = 0; kind < 6; kind++)
            for (unsigned mode = 0; mode < 3; mode++) {
                if (mode < 2)
                    continue; /* Covered by the no-wait captured-Current/context tests. */
                fixture();
                PGRAPHState *pg = &state->pgraph;
                ip_clean_alias = kind >= 4;
                float positions[3][4] = { { 0, 0, 32768, 1 },
                                          { 8, 0, 32768, 1 },
                                          { 0, 8, 32768, 1 } };
                pg->draw_arrays_length = 0;
                if (kind == 3 || kind == 5) {
                    pg->inline_elements_length = 3;
                    for (unsigned i = 0; i < 3; i++)
                        pg->inline_elements[i] = i;
                } else if (kind == 2 || kind == 4) {
                    pg->draw_arrays_length = 1;
                    pg->draw_arrays_count[0] = 3;
                } else if (kind == 1) {
                    const int16_t packed[3][4] = { { 0, 0, 0, 1 },
                                                   { 8, 0, 0, 1 },
                                                   { 0, 8, 0, 1 } };
                    pg->vertex_attributes[0].format =
                        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K;
                    pg->vertex_attributes[0].size = 2;
                    pg->inline_array_length = sizeof(packed) / 4;
                    memcpy(pg->inline_array, packed, sizeof(packed));
                } else {
                    pg->inline_buffer_length = 3;
                    pg->vertex_attributes[0].inline_buffer_populated = true;
                    pg->vertex_attributes[0].inline_buffer = &positions[0][0];
                }
                if (mode) {
                    pg->regs_[NV_PGRAPH_CSV0_D] =
                        2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                    pg->enable_vertex_program_write = mode == 2;
                    mov(0, 0, 0, false);
                    mov(1, 3, 3, true);
                    if (mode == 2) {
                        mov(0, 3, 20, false);
                        pg->program_data[0][3] &= ~(1u << 11);
                        mov(1, 0, 0, false);
                        mov(2, 3, 3, true);
                    }
                }
                id<MTLDevice> device = surfaces.cache.commands.device;
                uint32_t value = 0x12345678;
                ip_gate = [device newSharedEvent];
                ip_source =
                    [device newBufferWithBytes:&value
                                        length:4
                                       options:MTLResourceStorageModeShared];
                ip_destination =
                    [device newBufferWithLength:4
                                        options:MTLResourceStorageModeShared];
                assert(ip_gate && ip_source && ip_destination);
                *(uint32_t *)ip_destination.contents = 0;
                NSError *error = nil;
                qemu_mutex_lock(&pg->lock);
                if (active)
                    require([draw beginWithError:&error], error);
                ip_enabled = YES;
                require(active ? [draw endWithError:&error] :
                                 [draw drawWithError:&error],
                        error);
                ip_enabled = NO;
                assert(ip_gate.signaledValue == 1);
                if (mode == 2) {
                    const float green[4] = { 0, 1, 0, 1 };
                    assert(!memcmp(pg->vsh_constants[20], green, 16) &&
                           pg->vsh_constants_dirty[20]);
                }
                qemu_mutex_unlock(&pg->lock);
                read_vram(1024, 256);
                assert(*(uint32_t *)ip_destination.contents == value);
                color(1, 1, 0xff00ff00);
                color(7, 7, 0xffff0000);
            }
    method_setImplementation(encode, (IMP)ip_original_encode);
    method_setImplementation(resolve, (IMP)ip_original_resolve);
    assert(ip_encodes == 12 && ip_resolves == 12);
    ip_clean_alias = NO;
    ip_gate = nil;
    ip_source = ip_destination = nil;
    puts("Independent producer:12 required-feedback gated surface-queue cases;"
         "InlineBuffer/InlineArray/DrawArrays/InlineElements,constant-writing "
         "XF,standalone/Begin-End,including12 clean surface alias cases;"
         "Current and XF complete before gate release,context and raster "
         "readback PASS");
}
#endif
