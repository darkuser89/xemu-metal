/* Exercise independent XF execution while real Metal surface work is gated.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import <objc/runtime.h>
#import "hw/xbox/nv2a/pgraph/metal/vertex-epoch.h"

static BOOL (*independent_submit)(id, SEL, NSError **);
static NV2AMetalEpochResult *(*independent_execute)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NSError **);
static id<MTLSharedEvent> independent_gate;
static id<MTLBuffer> independent_source, independent_destination;
static unsigned independent_submissions, independent_epochs;
static BOOL independent_enabled, independent_shared;
static NV2AMetalEpochResult *(*independent_resolve)(id, SEL, NSError **);

static void independent_gate_recording(NSError **error)
{
    require([surfaces.cache prepareGPUReadAtAddress:60000 length:4 error:error],
            *error);
    NV2AMetalCommands *commands = surfaces.cache.commands;
    assert(commands.commandBuffer);
    Ivar queue_ivar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    assert(queue_ivar);
    id<MTL4CommandQueue> queue = object_getIvar(commands, queue_ivar);
    assert(queue);
    [queue waitForEvent:independent_gate value:1];
    require([commands addResource:independent_source error:error], *error);
    require([commands addResource:independent_destination error:error], *error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:independent_source
               sourceOffset:60000
                   toBuffer:independent_destination
          destinationOffset:0
                       size:4];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    /* A regression still terminates, then fails the event assertion. */
    id<MTLSharedEvent> gate = independent_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     gate.signaledValue = 1;
                   });
}

static BOOL independent_submit_hook(id object, SEL selector, NSError **error)
{
    if (independent_enabled && object == surfaces.cache &&
        ++independent_submissions == 3 && !independent_shared) {
        independent_gate_recording(error);
    }
    return independent_submit(object, selector, error);
}

static NV2AMetalEpochResult *
independent_execute_hook(id object, SEL selector,
                         NV2AMetalPGRAPHVertexState *captured,
                         id<MTLBuffer> attributes, NSUInteger first,
                         NSUInteger count, NSError **error)
{
    NV2AMetalEpochResult *result = independent_execute(
        object, selector, captured, attributes, first, count, error);
    if (independent_enabled) {
        require(result != nil, *error);
        assert(independent_submissions == 3 && count == 3 && first == 0);
        assert(independent_gate.signaledValue == 0);
        assert(*(uint32_t *)independent_destination.contents == 0);
        assert(result.vertexCount == count && result.vertices);
        independent_epochs++;
        independent_gate.signaledValue = 1;
    }
    return result;
}

static NV2AMetalEpochResult *independent_resolve_hook(id object, SEL selector,
                                                      NSError **error)
{
    if (!independent_enabled || !independent_shared)
        return independent_resolve(object, selector, error);
    /* Fetch/XF are already complete. Queue unrelated surface work now; CPU
     * result validation must not drain that future recording. */
    independent_gate_recording(error);
    require([surfaces.cache submitWithError:error], *error);
    NV2AMetalEpochResult *result = independent_resolve(object, selector, error);
    require(result != nil, *error);
    assert(independent_gate.signaledValue == 0);
    assert(*(uint32_t *)independent_destination.contents == 0);
    assert(result.vertexCount == 3 && result.vertices);
    independent_epochs++;
    independent_gate.signaledValue = 1;
    return result;
}

static void independent_surface_queue_tests(void)
{
    for (unsigned mode = 0; mode < 3; mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        if (mode) {
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            pg->enable_vertex_program_write = mode == 2;
            mov(0, 0, 0, false);
            mov(1, 3, 3, true);
        }
        uint32_t value = 0x12345678;
        cpu_write(60000, 4);
        stl_le_p(state->vram_ptr + 60000, value);
        id<MTLDevice> device = surfaces.cache.commands.device;
        /* This suite checks required feedback against later unrelated work.
         * A pending GPU Current writer keeps that dependency real for every
         * XF mode, including otherwise queue-resident readonly producers. */
        NSError *error = nil;
        id<MTLBuffer> current =
            [device newBufferWithBytes:state->vram_ptr + 16384 + 2 * 16
                                length:16
                               options:MTLResourceStorageModeShared];
        assert(current);
        require([surfaces.cache prepareGPUWriteAtAddress:16384 + 2 * 16
                                                  length:16
                                                   error:&error],
                error);
        require([surfaces.cache.commands addResource:current error:&error],
                error);
        id<MTL4ComputeCommandEncoder> writer =
            [surfaces.cache.commands.commandBuffer computeCommandEncoder];
        assert(writer);
        [writer copyFromBuffer:current
                  sourceOffset:0
                      toBuffer:surfaces.cache.vram
             destinationOffset:16384 + 2 * 16
                          size:16];
        [writer endEncoding];
        independent_gate = [device newSharedEvent];
        independent_source = surfaces.cache.vram;
        independent_destination =
            [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        assert(independent_gate && independent_source &&
               independent_destination);
        *(uint32_t *)independent_destination.contents = 0;
        Method submit_method = class_getInstanceMethod(
            NV2AMetalSurfaceCache.class, @selector(submitWithError:));
        Method epoch_method = class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(executeRasterState:attributeBuffer:first:count:error:));
        assert(submit_method && epoch_method);
        independent_submit = (void *)method_setImplementation(
            submit_method, (IMP)independent_submit_hook);
        independent_execute = (void *)method_setImplementation(
            epoch_method, (IMP)independent_execute_hook);
        Method resolve_method = class_getInstanceMethod(
            NV2AMetalEpochEncoding.class, @selector(resolveWithError:));
        assert(resolve_method);
        independent_resolve = (void *)method_setImplementation(
            resolve_method, (IMP)independent_resolve_hook);
        independent_submissions = independent_epochs = 0;
        independent_shared = YES;
        independent_enabled = YES;
        render();
        independent_enabled = NO;
        method_setImplementation(submit_method, (IMP)independent_submit);
        method_setImplementation(epoch_method, (IMP)independent_execute);
        method_setImplementation(resolve_method, (IMP)independent_resolve);
        assert(independent_epochs == 1);
        assert(pg->vertex_attributes[0].inline_value[0] == 0 &&
               pg->vertex_attributes[0].inline_value[1] == 8);
        read_vram(1024, 256);
        assert(*(uint32_t *)independent_destination.contents == value);
        color(1, 1, 0xff00ff00);
        color(7, 7, 0xffff0000);
        independent_gate = nil;
        independent_source = independent_destination = nil;
    }
    groups++;
    puts("Independent surface queue:fixed, readonly and writable XF complete "
         "before gated surface work; current attributes, ordered copy and "
         "raster readback PASS");
}
