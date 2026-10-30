/* Native Save ownership with real QEMU mutexes, events and VMState encoding.
 * GPU capture and the outer VM are stand-ins; no device, VM or window starts.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#include "hw/xbox/nv2a/pgraph/metal/renderer.h"
#include "migration/misc.h"
#include "migration/qemu-file.h"
#include "io/channel-buffer.h"
#include "qemu/module.h"

static NV2AState *device;
static PGRAPHRenderer metal = { .type = CONFIG_DISPLAY_RENDERER_METAL4 };
static PGRAPHRenderer legacy;
static NotifierWithReturnList notifiers;
static QemuMutex bql;
static QemuEvent kick, complete;
static QemuThread worker;
static bool bql_owned, fifo_owned, stop_worker, fail_capture;
static unsigned captures, requested, lock_calls, unlock_calls, checks, cases;
static RunState current_state;

bool bql_locked(void)
{
    return bql_owned;
}
bool mutex_is_bql(QemuMutex *mutex)
{
    return mutex == &bql;
}
void bql_update_status(bool locked)
{
    (void)locked;
}
void bql_lock_impl(const char *file, int line)
{
    (void)file;
    (void)line;
    assert(!bql_owned);
    qemu_mutex_lock(&bql);
    bql_owned = true;
}
void bql_unlock(void)
{
    assert(bql_owned);
    bql_owned = false;
    qemu_mutex_unlock(&bql);
}
RunState runstate_get(void)
{
    return current_state;
}
void precopy_add_notifier(NotifierWithReturn *n)
{
    notifier_with_return_list_add(&notifiers, n);
}
void precopy_remove_notifier(NotifierWithReturn *n)
{
    notifier_with_return_remove(n);
}

/* Stand-in for FIFO-idle coordination; the two actual QEMU locks and their
 * ownership are enforced. The production idle condition is tested separately.
 */
void nv2a_lock_fifo(NV2AState *d)
{
    assert(d == device && bql_owned && !fifo_owned);
    qemu_mutex_lock(&d->pfifo.lock);
    qemu_mutex_lock(&d->pgraph.lock);
    fifo_owned = true;
    lock_calls++;
}
void nv2a_unlock_fifo(NV2AState *d)
{
    assert(d == device && bql_owned && fifo_owned);
    fifo_owned = false;
    unlock_calls++;
    qemu_mutex_unlock(&d->pgraph.lock);
    qemu_mutex_unlock(&d->pfifo.lock);
}
void pgraph_pre_savevm_trigger(NV2AState *d)
{
    assert(d == device && fifo_owned && d->pfifo.halt);
    qemu_event_reset(&complete);
    requested++;
    qemu_event_set(&kick);
}
void pgraph_pre_savevm_wait(NV2AState *d)
{
    assert(d == device && !fifo_owned && !bql_owned);
    qemu_event_wait(&complete);
}
bool pgraph_metal4_pre_save_check(NV2AState *d, Error **errp)
{
    assert(d == device && fifo_owned && captures == requested);
    checks++;
    if (fail_capture) {
        error_setg(errp, "Injected capture failure");
        return false;
    }
    return true;
}
static void *capture_worker(void *opaque)
{
    assert(opaque == device);
    for (;;) {
        qemu_event_wait(&kick);
        qemu_event_reset(&kick);
        if (qatomic_read(&stop_worker))
            break;
        qemu_mutex_lock(&device->pfifo.lock);
        qemu_mutex_lock(&device->pgraph.lock);
        captures++;
        /* Represents GPU writeback that must precede RAM serialization. */
        device->pmc.pending_interrupts = captures;
        qemu_mutex_unlock(&device->pgraph.lock);
        qemu_mutex_unlock(&device->pfifo.lock);
        qemu_event_set(&complete);
    }
    return NULL;
}
static int notify(PrecopyNotifyReason reason, Error **errp)
{
    PrecopyNotifyData data = { .reason = reason };
    return notifier_with_return_list_notify(&notifiers, &data, errp);
}
static void assert_idle(bool halt)
{
    assert(bql_owned && !fifo_owned && !device->metal4_save.prepared &&
           !device->metal4_save.locked && device->pfifo.halt == halt);
    assert(!qemu_mutex_trylock(&device->pfifo.lock));
    assert(!qemu_mutex_trylock(&device->pgraph.lock));
    qemu_mutex_unlock(&device->pgraph.lock);
    qemu_mutex_unlock(&device->pfifo.lock);
    assert(lock_calls == unlock_calls);
}
static bool parent_pre_save(void *opaque, Error **errp)
{
    return nv2a_metal4_save_pre_save(opaque, errp);
}
static int parent_post_save(void *opaque)
{
    nv2a_metal4_save_release(opaque);
    return 0;
}
/* QEMU VMSTATE macros use null-pointer subtraction for compile-time types. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnull-pointer-subtraction"
static void serialize(bool success)
{
    const VMStateDescription parent = {
        .name = "metal4-save-lifecycle-test",
        .version_id = 1,
        .minimum_version_id = 1,
        .pre_save_errp = parent_pre_save,
        .post_save = parent_post_save,
        .fields =
            (VMStateField[]){ VMSTATE_UINT32(pmc.pending_interrupts, NV2AState),
                              VMSTATE_END_OF_LIST() },
    };
    QIOChannelBuffer *buffer = qio_channel_buffer_new(16);
    QEMUFile *file = qemu_file_new_output(QIO_CHANNEL(buffer));
    Error *error = NULL;
    uint64_t transferred_before = qemu_file_transferred(file);
    int result = vmstate_save_state(file, &parent, device, NULL, &error);
    if (success) {
        assert(result == 0 && !error);
        qemu_fflush(file);
        assert(buffer->usage == 4);
        assert((uint32_t)ldl_be_p(buffer->data) == captures);
    } else {
        assert(result == -EINVAL && error);
        assert(qemu_file_transferred(file) == transferred_before &&
               !buffer->usage);
    }
    error_free(error);
    assert(qemu_fclose(file) == 0);
    object_unref(OBJECT(buffer));
}
#pragma clang diagnostic pop
static void snapshot_cases(void)
{
    const RunState states[] = { RUN_STATE_RUNNING, RUN_STATE_SUSPENDED,
                                RUN_STATE_PAUSED, RUN_STATE_PRELAUNCH };
    for (unsigned state = 0; state < G_N_ELEMENTS(states); state++)
        for (unsigned halted = 0; halted < 2; halted++)
            for (unsigned failure = 0; failure < 4; failure++) {
                /* 0: success, 1: capture failure, 2: other-device failure
                 * before NV2A serialization, 3: failure before setup. */
                current_state = states[state];
                qatomic_set(&device->pfifo.halt, halted);
                fail_capture = failure == 1;
                unsigned before = captures;
                if (runstate_is_live(current_state)) {
                    nv2a_metal4_save_prepare(device);
                    current_state = RUN_STATE_SAVE_VM;
                }
                Error *error = NULL;
                if (failure != 3) {
                    int result = notify(PRECOPY_NOTIFY_SETUP, &error);
                    assert((result == -EINVAL) == fail_capture);
                    assert(!!error == fail_capture);
                    assert(captures == before + 1);
                    assert(device->pmc.pending_interrupts == captures);
                    if (failure == 0)
                        serialize(true);
                    error_free(error);
                    assert(notify(PRECOPY_NOTIFY_CLEANUP, NULL) == 0);
                } else {
                    /* Resume fallback before qemu_savevm_state_cleanup. */
                    nv2a_metal4_save_cleanup(device);
                    assert(captures ==
                           before + (runstate_is_live(states[state]) ? 1 : 0));
                }
                nv2a_metal4_save_cleanup(device);
                nv2a_metal4_save_release(device);
                assert_idle(halted);
                cases++;
            }
}
static void additional_cases(void)
{
    current_state = RUN_STATE_PAUSED;
    fail_capture = false;
    unsigned before = captures, before_checks = checks;
    serialize(false); /* A stale successful renderer status is insufficient. */
    assert(captures == before && checks == before_checks);
    assert_idle(true);
    cases++;

    for (unsigned attempt = 0; attempt < 3; attempt++) {
        nv2a_metal4_save_prepare(device);
        nv2a_metal4_save_prepare(device);
        assert(captures == before + attempt + 1);
        fail_capture = attempt == 0;
        serialize(!fail_capture);
        assert(!fifo_owned);
        nv2a_metal4_save_cleanup(device);
        assert_idle(true);
        cases++;
    }
    fail_capture = false;
    for (unsigned state = 0; state < 2; state++) {
        current_state = state ? RUN_STATE_SUSPENDED : RUN_STATE_RUNNING;
        before = captures;
        assert(notify(PRECOPY_NOTIFY_SETUP, NULL) == 0);
        assert(captures == before && !device->metal4_save.prepared);
        /* Final stopped phase is prepared by the NV2A state adapter. */
        nv2a_metal4_save_prepare(device);
        serialize(true);
        assert(notify(PRECOPY_NOTIFY_CLEANUP, NULL) == 0);
        assert_idle(true);
        cases++;
    }
    device->pgraph.renderer = &legacy;
    current_state = RUN_STATE_PAUSED;
    before = captures;
    assert(notify(PRECOPY_NOTIFY_SETUP, NULL) == 0);
    assert(notify(PRECOPY_NOTIFY_CLEANUP, NULL) == 0);
    assert(captures == before);
    assert_idle(true);
    cases++;

    device->pgraph.renderer = &metal;
    nv2a_metal4_save_prepare(device);
    nv2a_metal4_save_destroy(device); /* Exit before post_save. */
    assert(QLIST_EMPTY(&notifiers.notifiers));
    assert_idle(true);
    cases++;
}
int main(void)
{
    module_call_init(MODULE_INIT_QOM);
    notifier_with_return_list_init(&notifiers);
    device = g_new0(NV2AState, 1);
    device->pgraph.renderer = &metal;
    qemu_mutex_init(&bql);
    qemu_mutex_init(&device->pfifo.lock);
    qemu_mutex_init(&device->pgraph.lock);
    qemu_event_init(&kick, false);
    qemu_event_init(&complete, false);
    qemu_thread_create(&worker, "metal-save-test", capture_worker, device,
                       QEMU_THREAD_JOINABLE);
    bql_lock();
    nv2a_metal4_save_init(device);
    snapshot_cases();
    additional_cases();
    bql_unlock();
    qatomic_set(&stop_worker, true);
    qemu_event_set(&kick);
    qemu_thread_join(&worker);
    qemu_event_destroy(&kick);
    qemu_event_destroy(&complete);
    qemu_mutex_destroy(&device->pfifo.lock);
    qemu_mutex_destroy(&device->pgraph.lock);
    qemu_mutex_destroy(&bql);
    g_free(device);
    printf("Metal Save lifecycle: %u cases / %u worker captures PASS; "
           "real locks and VMState; GPU/outer VM stand-ins\n",
           cases, captures);
    return 0;
}
