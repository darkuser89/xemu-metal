/* Pending service under one PGRAPH ownership interval.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PENDING_LOCKS_H
#define TEST_METAL_PENDING_LOCKS_H
#include <dispatch/dispatch.h>

static QemuMutexLockFunc pl_lock_original;
static BOOL (*pl_drain_original)(id, SEL, NSError **);
static _Thread_local bool pl_count_locks, pl_cpu_thread;
static unsigned pl_pg_locks, pl_fifo_locks;
static bool pl_arrival;
static dispatch_semaphore_t pl_entered, pl_blocked, pl_done;
static bool pl_write;
static bool pl_late;
static BOOL (*pl_needs_original)(id, SEL);
static void pl_wait(dispatch_semaphore_t semaphore);
static void *pl_cpu_access(void *opaque);

static void pl_lock(QemuMutex *mutex, const char *file, int line)
{
    if (pl_count_locks) {
        pl_pg_locks += mutex == &state->pgraph.lock;
        pl_fifo_locks += mutex == &state->pfifo.lock;
    }
    if (pl_cpu_thread && mutex == &state->pgraph.lock &&
        qatomic_read(&pl_arrival))
        dispatch_semaphore_signal(pl_blocked);
    if (pl_cpu_thread && mutex == &state->pfifo.lock && qatomic_read(&pl_late))
        dispatch_semaphore_signal(pl_blocked);
    pl_lock_original(mutex, file, line);
}
static BOOL pl_late_needs(id object, SEL selector)
{
    BOOL needed = pl_needs_original(object, selector);
    if (qatomic_read(&pl_late) && !needed) {
        dispatch_semaphore_signal(pl_entered);
        pl_wait(pl_blocked);
        qatomic_set(&pl_late, false);
    }
    return needed;
}
static BOOL pl_force_needs(id object, SEL selector)
{
    (void)object;
    (void)selector;
    return YES;
}
static void *pl_hold_guards(void *opaque)
{
    @autoreleasepool {
        assert(opaque == state);
        qemu_mutex_lock(&state->pgraph.lock);
        @synchronized([surfaces.cache valueForKey:@"stateLock"]) {
            dispatch_semaphore_signal(pl_entered);
            pl_wait(pl_blocked);
        }
        qemu_mutex_unlock(&state->pgraph.lock);
    }
    return NULL;
}
static BOOL (*pl_dirty_original)(id, SEL);
static BOOL pl_cancel_dirty;
static BOOL pl_dirty_change(id object, SEL selector)
{
    if (pl_cancel_dirty && object == surfaces.color) {
        pl_cancel_dirty = NO;
        [surfaces.cache cancel];
    }
    return pl_dirty_original(object, selector);
}
static uint64_t pl_epoch_max(id object, SEL selector)
{
    (void)object;
    (void)selector;
    return UINT64_MAX;
}

static void pending_no_work_tests(void)
{
    unsigned skipped = 0;
    pl_lock_original = qatomic_read(&qemu_mutex_lock_func);
    qatomic_set(&qemu_mutex_lock_func, pl_lock);
    @try {
        for (unsigned dirty = 0; dirty < 2; dirty++) {
            fixture();
            if (dirty)
                query_triangle(0);
            qemu_mutex_lock(&state->pfifo.lock);
            renderer.ops.process_pending(state);
            qemu_mutex_unlock(&state->pfifo.lock);
            assert(![surfaces needsCPUService]);
            pl_entered = dispatch_semaphore_create(0);
            pl_blocked = dispatch_semaphore_create(0);
            QemuThread holder;
            qemu_thread_create(&holder, "pending-held-guards", pl_hold_guards,
                               state, QEMU_THREAD_JOINABLE);
            pl_wait(pl_entered);
            dispatch_semaphore_t release = pl_blocked;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             dispatch_semaphore_signal(release);
                           });
            qemu_mutex_lock(&state->pfifo.lock);
            pl_pg_locks = pl_fifo_locks = 0;
            pl_count_locks = true;
            for (unsigned i = 0; i < 1000; i++)
                renderer.ops.process_pending(state);
            pl_count_locks = false;
            assert(!pl_pg_locks && !pl_fifo_locks &&
                   state->pgraph.surface_color.draw_dirty == !!dirty);
            assert(qemu_mutex_trylock(&state->pfifo.lock) == -EBUSY);
            qemu_mutex_unlock(&state->pfifo.lock);
            dispatch_semaphore_signal(pl_blocked);
            qemu_thread_join(&holder);
            skipped += 1000;
        }
        /* A cache change during the locked dirty getter must leave its earlier
         * observer stamp invalid, even though the published value is current.
         */
        fixture();
        query_triangle(0);
        NSError *error = nil;
        qemu_mutex_lock(&state->pgraph.lock);
        require([surfaces prepareColor:YES zeta:NO error:&error] &&
                    [surfaces.cache markWritten:surfaces.color error:&error],
                error);
        qemu_mutex_unlock(&state->pgraph.lock);
        Method dirty = class_getInstanceMethod(NV2AMetalCachedSurface.class,
                                               @selector(dirty));
        pl_dirty_original =
            (void *)method_setImplementation(dirty, (IMP)pl_dirty_change);
        pl_cancel_dirty = YES;
        qemu_mutex_lock(&state->pfifo.lock);
        renderer.ops.process_pending(state);
        method_setImplementation(dirty, (IMP)pl_dirty_original);
        assert(!pl_cancel_dirty && surfaces.color.dirty &&
               [surfaces needsCPUService]);
        renderer.ops.process_pending(state);
        assert(![surfaces needsCPUService]);
        Method epoch = class_getInstanceMethod(NV2AMetalCachedSurface.class,
                                               @selector(dirtyEpoch));
        IMP oldEpoch = method_setImplementation(epoch, (IMP)pl_epoch_max);
        renderer.ops.process_pending(state);
        assert([surfaces needsCPUService]);
        renderer.ops.process_pending(state);
        assert([surfaces needsCPUService]);
        method_setImplementation(epoch, oldEpoch);
        renderer.ops.process_pending(state);
        assert(![surfaces needsCPUService]);
        qemu_mutex_unlock(&state->pfifo.lock);
        /* Post after a no-work decision, while FIFO is still held. The CPU's
         * subsequent kick must arrange a later service, not lose the request.
         */
        Method needs = class_getInstanceMethod(NV2AMetalPGRAPHSurfaces.class,
                                               @selector(needsCPUService));
        pl_needs_original =
            (void *)method_setImplementation(needs, (IMP)pl_late_needs);
        for (unsigned i = 0; i < 32; i++) {
            fixture();
            query_triangle(0);
            qemu_mutex_lock(&state->pfifo.lock);
            renderer.ops.process_pending(state);
            qemu_mutex_unlock(&state->pfifo.lock);
            assert(![surfaces needsCPUService]);
            pl_entered = dispatch_semaphore_create(0);
            pl_blocked = dispatch_semaphore_create(0);
            pl_done = dispatch_semaphore_create(0);
            pl_write = i & 1;
            qatomic_set(&pl_late, true);
            QemuThread cpu;
            qemu_thread_create(&cpu, "pending-late-post", pl_cpu_access, state,
                               QEMU_THREAD_JOINABLE);
            start_worker();
            qemu_event_set(&worker_kick);
            pl_wait(pl_done);
            qemu_thread_join(&cpu);
            stop_worker();
            assert(!qatomic_read(&pl_late) && !surfaces.color.dirty &&
                   !state->pgraph.surface_color.draw_dirty);
        }
        method_setImplementation(needs, (IMP)pl_needs_original);
        /* Same native empty service as before, versus the actual no-work
         * branch. Only force admission; retain real PGRAPH/cache/FIFO work. */
        fixture();
        query_triangle(0);
        qemu_mutex_lock(&state->pfifo.lock);
        renderer.ops.process_pending(state);
        double samples[2][9];
        for (unsigned sample = 0; sample < 11; sample++)
            for (unsigned order = 0; order < 2; order++) {
                unsigned forced = (sample + order) & 1;
                IMP saved =
                    forced ?
                        method_setImplementation(needs, (IMP)pl_force_needs) :
                        NULL;
                int64_t begin = g_get_monotonic_time();
                for (unsigned i = 0; i < 5000; i++)
                    renderer.ops.process_pending(state);
                double ms = (g_get_monotonic_time() - begin) / 1000.;
                if (saved)
                    method_setImplementation(needs, saved);
                if (sample >= 2)
                    samples[forced][sample - 2] = ms;
            }
        qemu_mutex_unlock(&state->pfifo.lock);
        for (unsigned k = 0; k < 2; k++)
            for (unsigned i = 0; i < 9; i++)
                for (unsigned j = i + 1; j < 9; j++)
                    if (samples[k][j] < samples[k][i]) {
                        double t = samples[k][j];
                        samples[k][j] = samples[k][i];
                        samples[k][i] = t;
                    }
        printf("Pending no-work:2000 native services with PGRAPH/cache guards "
               "held by another thread;zero PGRAPH/FIFO reacquisitions;32 late "
               "read/write posts after admission,cache-cancel publication "
               "retry,epoch saturation PASS\n");
        printf("Pending no-work host:5000 calls fast/full %.6f/%.6f ms "
               "medians;2 warmups/9 alternating samples;real empty "
               "service,component host timing only PASS\n",
               samples[0][4], samples[1][4]);
    } @finally {
        pl_count_locks = false;
        qatomic_set(&qemu_mutex_lock_func, pl_lock_original);
        pl_entered = pl_blocked = pl_done = nil;
    }
    assert(skipped == 2000);
    groups++;
}

static void pl_wait(dispatch_semaphore_t semaphore)
{
    assert(!dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)));
}

static BOOL pl_drain(id self, SEL selector, NSError **error)
{
    /* The renderer must already own PGRAPH and release FIFO while servicing
     * CPU requests. A trylock probes ownership without waiting or nesting. */
    assert(qemu_mutex_trylock(&state->pgraph.lock) == -EBUSY);
    assert(!qemu_mutex_trylock(&state->pfifo.lock));
    qemu_mutex_unlock(&state->pfifo.lock);
    if (qatomic_read(&pl_arrival)) {
        dispatch_semaphore_signal(pl_entered);
        pl_wait(pl_blocked);
        qatomic_set(&pl_arrival, false);
    }
    return pl_drain_original(self, selector, error);
}

static void *pl_cpu_access(void *opaque)
{
    assert(opaque == state);
    @autoreleasepool {
        pl_wait(pl_entered);
        pl_cpu_thread = true;
        NSError *error = nil;
        require([surfaces requestCPUAccessAtAddress:1024 + 36
                                             length:4
                                              write:pl_write
                                              error:&error],
                error);
        pl_cpu_thread = false;
        assert(raw_color(1, 1) == 0xff00ff00);
        dispatch_semaphore_signal(pl_done);
    }
    return NULL;
}

static void pending_lock_tests(void)
{
    Method method = class_getInstanceMethod(
        NV2AMetalPGRAPHSurfaces.class, @selector(processCPURequestsWithError:));
    pl_drain_original = (void *)method_setImplementation(method, (IMP)pl_drain);
    pl_lock_original = qatomic_read(&qemu_mutex_lock_func);
    qatomic_set(&qemu_mutex_lock_func, pl_lock);
    unsigned cases = 0;
    @try {
        for (unsigned dirty = 0; dirty < 2; dirty++) {
            fixture();
            if (dirty)
                query_triangle(0);
            /* Force stale exported flags; even an empty CPU request queue
             * must publish the real cache state instead of skipping service. */
            state->pgraph.surface_color.draw_dirty = !dirty;
            state->pgraph.surface_zeta.draw_dirty = true;
            pl_pg_locks = pl_fifo_locks = 0;
            qemu_mutex_lock(&state->pfifo.lock);
            pl_count_locks = true;
            renderer.ops.process_pending(state);
            pl_count_locks = false;
            assert(pl_pg_locks == 1 && pl_fifo_locks == 1);
            assert(qemu_mutex_trylock(&state->pfifo.lock) == -EBUSY);
            qemu_mutex_unlock(&state->pfifo.lock);
            assert(!qemu_mutex_trylock(&state->pgraph.lock));
            qemu_mutex_unlock(&state->pgraph.lock);
            assert(state->pgraph.surface_color.draw_dirty == !!dirty &&
                   !state->pgraph.surface_zeta.draw_dirty &&
                   raw_color(1, 1) == 0xffff0000);
            cases++;
        }
        /* A CPU request arriving after the renderer acquired PGRAPH cannot
         * enter this drain. Its subsequent FIFO kick must service it on the
         * next iteration, without losing the wakeup or accessing stale RAM. */
        for (unsigned i = 0; i < 32; i++) {
            fixture();
            query_triangle(0);
            pl_write = i & 1;
            pl_entered = dispatch_semaphore_create(0);
            pl_blocked = dispatch_semaphore_create(0);
            pl_done = dispatch_semaphore_create(0);
            qatomic_set(&pl_arrival, true);
            QemuThread cpuAccess;
            qemu_thread_create(&cpuAccess, "pending-cpu-arrival", pl_cpu_access,
                               state, QEMU_THREAD_JOINABLE);
            start_worker();
            qemu_event_set(&worker_kick);
            pl_wait(pl_done);
            qemu_thread_join(&cpuAccess);
            stop_worker();
            assert(!qatomic_read(&pl_arrival) && !surfaces.color.dirty &&
                   !state->pgraph.surface_color.draw_dirty);
            pl_entered = pl_blocked = pl_done = nil;
            cases++;
        }
    } @finally {
        pl_count_locks = false;
        qatomic_set(&qemu_mutex_lock_func, pl_lock_original);
        method_setImplementation(method, (IMP)pl_drain_original);
    }
    assert(cases == 34);
    pending_no_work_tests();
    puts("Pending ownership:2 empty/dirty native cases with exactly1 PGRAPH/"
         "FIFO reacquisition;32 read/write CPU arrivals while PGRAPH held,"
         "subsequent kick,exact GPU pixel,dirty publication and FIFO return "
         "ownership PASS");
    groups++;
}
#endif
