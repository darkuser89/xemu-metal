/* Real Metal XF execution with concurrent CPU VRAM access.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CACHE_CONCURRENCY_H
#define TEST_METAL_CACHE_CONCURRENCY_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-epoch.h"
#import "hw/xbox/nv2a/pgraph/metal/fetch-pgraph.h"
#import <objc/runtime.h>

@interface XFMetalCacheProbe : NSObject
@property(atomic) BOOL releasedByTimeout;
@end
@implementation XFMetalCacheProbe
@end

static NV2AMetalEpochResult *(*XF_cache_original_execute)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NSError **);
static id<MTLSharedEvent> XF_cache_gate;
static QemuThread XF_cache_cpu;
static BOOL XF_cache_enabled, XF_cache_cpu_before_release,
    XF_cache_feedback_old;
static unsigned XF_cache_cpu_accesses, XF_cache_executions;
static uint32_t XF_cache_expected_constant[4];
static BOOL XF_cache_raster, XF_cache_expected_kick, XF_cache_overlap_requested;
static QemuThread XF_cache_overlap_cpu;
static dispatch_semaphore_t XF_cache_queued, XF_cache_overlap_started,
    XF_cache_overlap_done;
static id<MTLBuffer> XF_cache_copy_destination;
static NV2AMetalSurfaceRecording *XF_cache_reader_token;
static BOOL (*XF_cache_original_submit)(id, SEL, NSError **);
static unsigned XF_cache_submissions;
static NV2AMetalEpochEncoding *(*XF_cache_original_encode)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NV2AMetalCommands *, NSError **);
static BOOL (*XF_cache_original_wait)(id, SEL, NV2AMetalSubmission *,
                                      NSError **);
static BOOL XF_cache_shared, XF_cache_shared_submitted, XF_cache_shared_probed;
static NV2AMetalCommands *XF_cache_shared_commands;
static BOOL (*XF_cache_original_producer_submit)(id, SEL, NSError **);
static BOOL (*XF_cache_original_producer_wait)(id, SEL, NV2AMetalSubmission *,
                                               NSError **);
static unsigned cache_register_calls;


static BOOL XF_cache_handle_kick(NV2AState *d)
{
    if (!XF_cache_enabled || !XF_cache_expected_kick)
        return NO;
    assert(d == state);
    dispatch_semaphore_signal(XF_cache_queued);
    return YES;
}
static void *XF_cache_overlap_work(void *opaque)
{
    (void)opaque;
    dispatch_semaphore_signal(XF_cache_overlap_started);
    hook->func(hook->opaque, state->vram, 60600, 4, true);
    stl_le_p(state->vram_ptr + 60600, 0xaabbccdd);
    dispatch_semaphore_signal(XF_cache_overlap_done);
    return NULL;
}
static BOOL XF_cache_submit_hook(id object, SEL selector, NSError **error)
{
    BOOL inject = NO;
    if (XF_cache_enabled && (XF_cache_raster || XF_cache_shared) &&
        object == surfaces.cache) {
        XF_cache_submissions++;
        inject = XF_cache_shared ? !XF_cache_shared_submitted :
                                   XF_cache_submissions == 3;
    }
    if (inject) {
        if (XF_cache_shared)
            XF_cache_shared_submitted = YES;
        NV2AMetalCommands *commands = surfaces.cache.commands;
        require([surfaces.cache prepareGPUReadAtAddress:60600
                                                 length:4
                                                  error:error],
                *error);
        require([commands addResource:XF_cache_copy_destination error:error],
                *error);
        Ivar queue_ivar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        assert(queue_ivar);
        id<MTL4CommandQueue> queue = object_getIvar(commands, queue_ivar);
        [queue waitForEvent:XF_cache_gate value:1];
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        assert(encoder);
        [encoder barrierAfterQueueStages:MTLStageAll
                            beforeStages:MTLStageBlit
                       visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder copyFromBuffer:surfaces.cache.vram
                   sourceOffset:60600
                       toBuffer:XF_cache_copy_destination
              destinationOffset:0
                           size:4];
        [encoder barrierAfterStages:MTLStageBlit
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
        XF_cache_reader_token = surfaces.cache.recording;
    }
    return XF_cache_original_submit(object, selector, error);
}

static BOOL XF_cache_producer_submit_hook(id object, SEL selector,
                                          NSError **error)
{
    if (XF_cache_enabled && XF_cache_shared && !XF_cache_shared_submitted &&
        XF_cache_shared_commands != surfaces.cache.commands) {
        /* Keep a real, separately queued surface reader alive while the
         * independent producer completes. Both queues share the explicit gate.
         */
        require([surfaces.cache submitWithError:error], *error);
        Ivar ivar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue =
            object_getIvar(XF_cache_shared_commands, ivar);
        [queue waitForEvent:XF_cache_gate value:1];
    }
    return XF_cache_original_producer_submit(object, selector, error);
}

static void *XF_cache_cpu_work(void *opaque)
{
    (void)opaque;
    @autoreleasepool {
        for (unsigned i = 0; i < 64; i++) {
            hook->func(hook->opaque, state->vram, 60000, 4, false);
            assert((uint32_t)ldl_le_p(state->vram_ptr + 60000) ==
                   (i ? i - 1 : 0));
            hook->func(hook->opaque, state->vram, 60000, 4, true);
            stl_le_p(state->vram_ptr + 60000, i);
            XF_cache_cpu_accesses += 2;
        }
        hook->func(hook->opaque, state->vram, 1276, 4, true);
        stl_le_p(state->vram_ptr + 1276, 0xff0000ff);
        if (XF_cache_raster) {
            XF_cache_expected_kick = YES;
            XF_cache_overlap_requested = YES;
            qemu_thread_create(&XF_cache_overlap_cpu, "xf-lock-overlap",
                               XF_cache_overlap_work, NULL,
                               QEMU_THREAD_JOINABLE);
            long waited = dispatch_semaphore_wait(
                XF_cache_overlap_started,
                dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
            assert(!waited);
            waited = dispatch_semaphore_wait(
                XF_cache_overlap_done,
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC));
            assert(waited != 0);
            assert((uint32_t)ldl_le_p(state->vram_ptr + 60600) == 0x11223344);
        }
        XF_cache_cpu_before_release = XF_cache_gate.signaledValue == 0;
        XF_cache_gate.signaledValue = 1;
    }
    return NULL;
}

static NV2AMetalEpochResult *
XF_cache_execute_hook(id object, SEL selector,
                      NV2AMetalPGRAPHVertexState *captured,
                      id<MTLBuffer> attributes, NSUInteger first,
                      NSUInteger count, NSError **error)
{
    if (!XF_cache_enabled)
        return XF_cache_original_execute(object, selector, captured, attributes,
                                         first, count, error);
    id executor = object;
    if (captured.programmed) {
        Ivar program =
            class_getInstanceVariable(NV2AMetalEpochExecutor.class, "_program");
        assert(program);
        executor = object_getIvar(object, program);
    }
    Ivar commands_ivar =
        class_getInstanceVariable([executor class], "_commands");
    assert(commands_ivar);
    NV2AMetalCommands *commands = object_getIvar(executor, commands_ivar);
    Ivar queue_ivar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    assert(commands && queue_ivar && !surfaces.cache.commands.commandBuffer);
    id<MTL4CommandQueue> queue = object_getIvar(commands, queue_ivar);
    assert(queue && XF_cache_gate);
    [queue waitForEvent:XF_cache_gate value:1];
    XF_cache_feedback_old =
        !memcmp(state->pgraph.vsh_constants[6], XF_cache_expected_constant,
                sizeof(XF_cache_expected_constant));
    assert(XF_cache_feedback_old);
    XF_cache_cpu_accesses = 0;
    XF_cache_cpu_before_release = NO;
    qemu_thread_create(&XF_cache_cpu, "xf-lock-cpu", XF_cache_cpu_work, NULL,
                       QEMU_THREAD_JOINABLE);
    id<MTLSharedEvent> gate = XF_cache_gate;
    XFMetalCacheProbe *probe = [XFMetalCacheProbe new];
    /* Bound a failing old-lock run; it must fail the progress assertion. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (gate.signaledValue == 0) {
                         probe.releasedByTimeout = YES;
                         gate.signaledValue = 1;
                     }
                   });
    NV2AMetalEpochResult *result = XF_cache_original_execute(
        object, selector, captured, attributes, first, count, error);
    assert(!probe.releasedByTimeout);
    qemu_thread_join(&XF_cache_cpu);
    assert(XF_cache_cpu_before_release && XF_cache_cpu_accesses == 128);
    assert(XF_cache_feedback_old);
    XF_cache_executions++;
    return result;
}

static void *XF_cache_probe_held(void *opaque)
{
    BOOL *held = opaque;
    int result = qemu_mutex_trylock(&state->pgraph.lock);
    *held = result != 0;
    if (!result)
        qemu_mutex_unlock(&state->pgraph.lock);
    return NULL;
}

static NV2AMetalEpochEncoding *XF_cache_encode_hook(
    id object, SEL selector, NV2AMetalPGRAPHVertexState *captured,
    id<MTLBuffer> attributes, NSUInteger first, NSUInteger count,
    NV2AMetalCommands *commands, NSError **error)
{
    NV2AMetalEpochEncoding *encoded = XF_cache_original_encode(
        object, selector, captured, attributes, first, count, commands, error);
    if (XF_cache_enabled) {
        require(encoded != nil, *error);
        assert(XF_cache_raster != captured.rasterDiscard &&
               commands.commandBuffer && first == 0 && count == 3);
        XF_cache_shared_commands = commands;
        XF_cache_shared = YES;
    }
    return encoded;
}
static NV2AMetalEpochEncoding *(*XF_cache_original_serial)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NV2AMetalEpochEncoding *, NV2AMetalCommands *, NSError **);
static NV2AMetalEpochEncoding *
XF_cache_serial_hook(id object, SEL selector,
                     NV2AMetalPGRAPHVertexState *captured,
                     id<MTLBuffer> attributes, NSUInteger first,
                     NSUInteger count, NV2AMetalEpochEncoding *previous,
                     NV2AMetalCommands *commands, NSError **error)
{
    NV2AMetalEpochEncoding *encoded =
        XF_cache_original_serial(object, selector, captured, attributes, first,
                                 count, previous, commands, error);
    if (XF_cache_enabled) {
        require(encoded != nil, *error);
        assert(XF_cache_raster != captured.rasterDiscard &&
               commands.commandBuffer && first == 0 && count == 3);
        XF_cache_shared_commands = commands;
        XF_cache_shared = YES;
    }
    return encoded;
}
static BOOL XF_cache_probe_producer_wait(BOOL (^wait)(void))
{
    XF_cache_shared_probed = YES;
    XF_cache_feedback_old =
        !memcmp(state->pgraph.vsh_constants[6], XF_cache_expected_constant,
                sizeof(XF_cache_expected_constant));
    assert(XF_cache_feedback_old && XF_cache_gate.signaledValue == 0);
    XF_cache_cpu_accesses = 0;
    XF_cache_cpu_before_release = NO;
    qemu_thread_create(&XF_cache_cpu, "shared-xf-cpu", XF_cache_cpu_work, NULL,
                       QEMU_THREAD_JOINABLE);
    id<MTLSharedEvent> gate = XF_cache_gate;
    XFMetalCacheProbe *probe = [XFMetalCacheProbe new];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (gate.signaledValue == 0) {
                         probe.releasedByTimeout = YES;
                         gate.signaledValue = 1;
                     }
                   });
    BOOL ok = wait();
    qemu_thread_join(&XF_cache_cpu);
    assert(!probe.releasedByTimeout && XF_cache_cpu_before_release &&
           XF_cache_cpu_accesses == 128);
    XF_cache_executions++;
    return ok;
}

static BOOL XF_cache_wait_hook(id object, SEL selector,
                               NV2AMetalSubmission *submission, NSError **error)
{
    if (!XF_cache_enabled || !XF_cache_shared || !XF_cache_shared_submitted ||
        XF_cache_shared_probed || object != surfaces.cache)
        return XF_cache_original_wait(object, selector, submission, error);
    __block NSError *failure = nil;
    BOOL ok = XF_cache_probe_producer_wait(^{
      return XF_cache_original_wait(object, selector, submission, &failure);
    });
    if (error)
        *error = failure;
    return ok;
}

static BOOL XF_cache_producer_wait_hook(id object, SEL selector,
                                        NV2AMetalSubmission *submission,
                                        NSError **error)
{
    if (!XF_cache_enabled || !XF_cache_shared || !XF_cache_shared_submitted ||
        XF_cache_shared_probed || object != XF_cache_shared_commands)
        return XF_cache_original_producer_wait(object, selector, submission,
                                               error);
    __block NSError *failure = nil;
    BOOL ok = XF_cache_probe_producer_wait(^{
      return XF_cache_original_producer_wait(object, selector, submission,
                                             &failure);
    });
    if (error)
        *error = failure;
    return ok;
}

static void XF_cache_concurrent_tests(void)
{
    for (unsigned mode = 0; mode < 5; mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        XF_cache_shared = XF_cache_shared_submitted = XF_cache_shared_probed =
            NO;
        if (mode < 4) {
            /* All XF modes share the producer queue. The probe writes the
             * bound target during XF. Finish its real
             * upload first, so this is independent of producer RAM reads. */
            NSError *warmError = nil;
            qemu_mutex_lock(&pg->lock);
            require([surfaces prepareColor:YES zeta:NO error:&warmError],
                    warmError);
            require([surfaces.cache submitWithError:&warmError], warmError);
            require([surfaces.cache waitUntilIdleWithError:&warmError],
                    warmError);
            qemu_mutex_unlock(&pg->lock);
        }
        stl_le_p(state->vram_ptr + 60000, 0);
        cpu_write(60600, 4);
        stl_le_p(state->vram_ptr + 60600, 0x11223344);
        XF_cache_raster = mode < 4;
        XF_cache_expected_kick = XF_cache_overlap_requested = NO;
        XF_cache_submissions = 0;
        XF_cache_reader_token = nil;
        XF_cache_queued = dispatch_semaphore_create(0);
        XF_cache_overlap_started = dispatch_semaphore_create(0);
        XF_cache_overlap_done = dispatch_semaphore_create(0);
        XF_cache_gate = [surfaces.cache.commands.device newSharedEvent];
        XF_cache_copy_destination = [surfaces.cache.commands.device
            newBufferWithLength:4
                        options:MTLResourceStorageModeShared];
        assert(XF_cache_gate && XF_cache_copy_destination);
        *(uint32_t *)XF_cache_copy_destination.contents = 0;
        Method submit = class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                                @selector(submitWithError:));
        assert(submit);
        XF_cache_original_submit =
            (void *)method_setImplementation(submit, (IMP)XF_cache_submit_hook);
        const uint32_t seed[] = { 0x3f000000, 0x3e800000, 0x3f800000, 0 };
        memcpy(pg->vsh_constants[6], seed, sizeof(seed));
        memcpy(XF_cache_expected_constant, seed, sizeof(seed));
        if (mode == 4)
            pg->regs_[NV_PGRAPH_CONTROL_0] = 0; // XF-only fixed function.
        if (mode > 0 && mode < 4) {
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            pg->enable_vertex_program_write = mode >= 2;
            mov(0, 0, 0, false);
            mov(1, 3, 3, mode != 2);
            if (mode == 2) {
                mov(2, 3, 6, true);
                pg->program_data[2][3] &= ~(1u << 11); // c[6] <- v3.
            } else if (mode == 3) {
                pg->program_data[0][1] = 13u << 21 | 27;
                pg->program_data[0][3] = 0; // ARL a0.x <- v0.x.
                pg->program_data[1][1] = 1 << 21 | 255 << 13 | 27;
                pg->program_data[1][2] = 3u << 26;
                pg->program_data[1][3] |= 2;
                float invalid = 1000;
                cpu_write(16384, 4);
                memcpy(state->vram_ptr + 16384, &invalid, 4);
            }
        }
        NSError *error = nil;
        /* Exercise the required-feedback lock handoff even for Fixed/readonly
         * XF: a real pending GPU Current source is not CPU-readable yet. */
        id<MTLBuffer> current = [surfaces.cache.commands.device
            newBufferWithBytes:state->vram_ptr + 16384 + 2 * 16
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
        uint64_t before = 0, after = 0;
        require([surfaces.cache sourceVersionAtAddress:60000
                                                length:4
                                               version:&before
                                                 error:&error],
                error);
        Method method = class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(executeRasterState:attributeBuffer:first:count:error:));
        assert(method);
        XF_cache_original_execute = (void *)method_setImplementation(
            method, (IMP)XF_cache_execute_hook);
        Method encodeMethod = class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(
                encodeRasterState:attributeBuffer:first:count:commands:error:));
        Method waitMethod = class_getInstanceMethod(
            NV2AMetalSurfaceCache.class, @selector(waitForSubmission:error:));
        assert(encodeMethod && waitMethod);
        XF_cache_original_encode = (void *)method_setImplementation(
            encodeMethod, (IMP)XF_cache_encode_hook);
        Method serialMethod = class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeSerialRasterState:attributeBuffer:first:count:
                      previous:commands:error:));
        XF_cache_original_serial = (void *)method_setImplementation(
            serialMethod, (IMP)XF_cache_serial_hook);
        XF_cache_original_wait = (void *)method_setImplementation(
            waitMethod, (IMP)XF_cache_wait_hook);
        Method producerSubmit = class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class, @selector(submitWithError:));
        Method producerWait = class_getInstanceMethod(
            NV2AMetalCommands.class, @selector(waitForSubmission:error:));
        XF_cache_original_producer_submit = (void *)method_setImplementation(
            producerSubmit, (IMP)XF_cache_producer_submit_hook);
        XF_cache_original_producer_wait = (void *)method_setImplementation(
            producerWait, (IMP)XF_cache_producer_wait_hook);
        XF_cache_enabled = YES;
        XF_cache_executions = 0;
        qemu_mutex_lock(&pg->lock);
        BOOL ok = [draw drawWithError:&error];
        BOOL held = NO;
        QemuThread probe;
        qemu_thread_create(&probe, "xf-lock-held", XF_cache_probe_held, &held,
                           QEMU_THREAD_JOINABLE);
        qemu_thread_join(&probe);
        assert(held && XF_cache_executions == 1);
        method_setImplementation(method, (IMP)XF_cache_original_execute);
        method_setImplementation(submit, (IMP)XF_cache_original_submit);
        method_setImplementation(encodeMethod, (IMP)XF_cache_original_encode);
        method_setImplementation(serialMethod, (IMP)XF_cache_original_serial);
        method_setImplementation(waitMethod, (IMP)XF_cache_original_wait);
        method_setImplementation(producerSubmit,
                                 (IMP)XF_cache_original_producer_submit);
        method_setImplementation(producerWait,
                                 (IMP)XF_cache_original_producer_wait);
        if (mode == 3) {
            assert(!ok && [error.localizedDescription
                              containsString:@"address fault"]);
            assert(!pg->draw_time && !surfaces.color.dirty);
            assert(!memcmp(pg->vsh_constants[6], seed, sizeof(seed)));
            rejected++;
        } else {
            require(ok, error);
            assert(pg->draw_time == (mode == 4 ? 0 : 1));
            if (mode == 2) {
                const float green[] = { 0, 1, 0, 1 };
                assert(!memcmp(pg->vsh_constants[6], green, sizeof(green)));
                assert(pg->vsh_constants_dirty[6]);
            }
            draws++;
        }
        require([surfaces.cache sourceVersionAtAddress:60000
                                                length:4
                                               version:&after
                                                 error:&error],
                error);
        assert(after > before && ldl_le_p(state->vram_ptr + 60000) == 63);
        qemu_mutex_unlock(&pg->lock);
        if (XF_cache_raster) {
            assert(XF_cache_overlap_requested);
            assert(XF_cache_reader_token);
            if (XF_cache_reader_token.completed) {
                /* Either the shared drain or owner-side submission collection
                 * has retired this actual reader. CPU lock recheck can finish
                 * without a worker request. An unretired reader still follows
                 * the queued path below; never assume completion from mode. */
                long done = dispatch_semaphore_wait(
                    XF_cache_overlap_done,
                    dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
                assert(!done);
            } else {
                long queued = dispatch_semaphore_wait(
                    XF_cache_queued,
                    dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
                assert(!queued);
                assert((uint32_t)ldl_le_p(state->vram_ptr + 60600) ==
                       0x11223344);
                qemu_mutex_lock(&state->pfifo.lock);
                error = nil;
                require([surfaces processPendingWithError:&error], error);
                qemu_mutex_unlock(&state->pfifo.lock);
            }
            qemu_thread_join(&XF_cache_overlap_cpu);
            assert((uint32_t)ldl_le_p(state->vram_ptr + 60600) == 0xaabbccdd);
            assert(*(uint32_t *)XF_cache_copy_destination.contents ==
                   0x11223344);
        }
        XF_cache_enabled = NO;
        XF_cache_gate = nil;
        XF_cache_shared_commands = nil;
        XF_cache_copy_destination = nil;
        XF_cache_reader_token = nil;
        XF_cache_queued = nil;
        read_vram(1024, 256);
        color(1, 1, mode < 3 ? 0xff00ff00 : 0xffff0000);
        color(7, 7, 0xff0000ff);
    }
    groups++;
    puts("Separate cache lock:5 fixed/readonly/writable/fault/XF-only cases; "
         "640 unrelated CPU callback accesses before GPU release, four "
         "protected "
         "overlapping writes/GPU copy readbacks, five bound-surface CPU writes "
         "preserved through rasterization/fault, deferred "
         "constant feedback, CPU versions/bytes, register lock retention and "
         "raster readback PASS");
}

static NV2AMetalEpochResult *
cache_register_isolation_hook(id object, SEL selector,
                              NV2AMetalPGRAPHVertexState *captured,
                              id<MTLBuffer> attributes, NSUInteger first,
                              NSUInteger count, NSError **error)
{
    cache_register_calls++;
    int acquired = qemu_mutex_trylock(&state->pgraph.lock);
    if (!acquired)
        qemu_mutex_unlock(&state->pgraph.lock);
    /* pgraph_read serializes register and RDI reads with this mutex. */
    assert(acquired != 0);
    return XF_cache_original_execute(object, selector, captured, attributes,
                                     first, count, error);
}
static NV2AMetalEpochEncoding *cache_register_encoding_hook(
    id object, SEL selector, NV2AMetalPGRAPHVertexState *captured,
    id<MTLBuffer> attributes, NSUInteger first, NSUInteger count,
    NV2AMetalCommands *commands, NSError **error)
{
    int acquired = qemu_mutex_trylock(&state->pgraph.lock);
    if (!acquired)
        qemu_mutex_unlock(&state->pgraph.lock);
    assert(acquired != 0);
    cache_register_calls++;
    return XF_cache_original_encode(object, selector, captured, attributes,
                                    first, count, commands, error);
}
static void cache_register_isolation_test(void)
{
    fixture();
    Method method = class_getInstanceMethod(
        NV2AMetalEpochExecutor.class,
        @selector(executeRasterState:attributeBuffer:first:count:error:));
    assert(method);
    XF_cache_original_execute = (void *)method_setImplementation(
        method, (IMP)cache_register_isolation_hook);
    Method encodeMethod = class_getInstanceMethod(
        NV2AMetalEpochExecutor.class,
        @selector(
            encodeRasterState:attributeBuffer:first:count:commands:error:));
    assert(encodeMethod);
    XF_cache_original_encode = (void *)method_setImplementation(
        encodeMethod, (IMP)cache_register_encoding_hook);
    cache_register_calls = 0;
    render();
    assert(cache_register_calls == 1);
    method_setImplementation(method, (IMP)XF_cache_original_execute);
    method_setImplementation(encodeMethod, (IMP)XF_cache_original_encode);
    read_vram(1024, 256);
    color(1, 1, 0xff00ff00);
    puts("PGRAPH register isolation: register/RDI mutex remains held during XF "
         "execution; raster readback PASS");
}

static dispatch_semaphore_t cache_guard_started, cache_guard_done;
static QemuThread cache_guard_cpu;
static BOOL cache_guard_enabled;
static BOOL (*cache_guard_original_upload)(id, SEL, id<MTLBuffer>, NSUInteger,
                                           NV2AMetalCommands *, NSError **);
static void *cache_guard_CPU_work(void *opaque)
{
    (void)opaque;
    @autoreleasepool {
        dispatch_semaphore_signal(cache_guard_started);
        /* The installed hook can now defer this independent source write.
         * Exercise the direct metadata API here: it must still serialize with
         * the upload transaction. The callback fast path has separate tests. */
        NSError *error = nil;
        BOOL completed = NO;
        require([surfaces.cache tryIdleCPUAccessAtAddress:60000
                                                   length:4
                                                    write:YES
                                                completed:&completed
                                                    error:&error],
                error);
        assert(completed);
        stl_le_p(state->vram_ptr + 60000, 0x12345678);
        dispatch_semaphore_signal(cache_guard_done);
    }
    return NULL;
}
static BOOL cache_guard_upload_hook(id object, SEL selector,
                                    id<MTLBuffer> buffer, NSUInteger offset,
                                    NV2AMetalCommands *commands,
                                    NSError **error)
{
    if (cache_guard_enabled) {
        cache_guard_enabled = NO;
        qemu_thread_create(&cache_guard_cpu, "cache-transaction-cpu",
                           cache_guard_CPU_work, NULL, QEMU_THREAD_JOINABLE);
        long started = dispatch_semaphore_wait(
            cache_guard_started,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        assert(!started);
        long completed = dispatch_semaphore_wait(
            cache_guard_done,
            dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC));
        assert(completed != 0);
    }
    return cache_guard_original_upload(object, selector, buffer, offset,
                                       commands, error);
}
static void cache_guard_transaction_test(void)
{
    fixture();
    NSError *error = nil;
    require([surfaces.cache flushWithError:&error], error);
    cache_guard_started = dispatch_semaphore_create(0);
    cache_guard_done = dispatch_semaphore_create(0);
    Method upload = class_getInstanceMethod(
        NV2AMetalSurfaceTransfer.class,
        @selector(encodeUploadFromBuffer:offset:commands:error:));
    assert(upload);
    cache_guard_original_upload =
        (void *)method_setImplementation(upload, (IMP)cache_guard_upload_hook);
    cache_guard_enabled = YES;
    uint64_t before = 0, after = 0;
    require([surfaces.cache sourceVersionAtAddress:60000
                                            length:4
                                           version:&before
                                             error:&error],
            error);
    qemu_mutex_lock(&state->pgraph.lock);
    require([surfaces prepareColor:YES zeta:NO error:&error], error);
    assert(!cache_guard_enabled);
    /* The CPU may proceed once the cache transaction ends, even though the
     * owner still holds PGRAPH for register access. */
    long completed = dispatch_semaphore_wait(
        cache_guard_done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    assert(!completed);
    qemu_thread_join(&cache_guard_cpu);
    qemu_mutex_unlock(&state->pgraph.lock);
    method_setImplementation(upload, (IMP)cache_guard_original_upload);
    require([surfaces.cache sourceVersionAtAddress:60000
                                            length:4
                                           version:&after
                                             error:&error],
            error);
    assert(after > before);
    assert((uint32_t)ldl_le_p(state->vram_ptr + 60000) == 0x12345678);
    require([surfaces.cache submitWithError:&error], error);
    require([surfaces.cache waitUntilIdleWithError:&error], error);
    puts("Cache transaction isolation: direct CPU metadata API waits during "
         "upload "
         "transaction, then proceeds with PGRAPH still held PASS");
}

#endif
