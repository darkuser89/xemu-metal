/* Native Metal Save ownership across QEMU snapshot phases.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#include "migration/misc.h"
#include "renderer.h"
#include "save-lifecycle.h"

static bool uses_metal4(NV2AState *d)
{
    return d->pgraph.renderer &&
           d->pgraph.renderer->type == CONFIG_DISPLAY_RENDERER_METAL4;
}

void nv2a_metal4_save_prepare(NV2AState *d)
{
    NV2AMetalSaveLifecycle *save = &d->metal4_save;
    if (!save->prepared) {
        nv2a_lock_fifo(d);
        save->previous_halt = qatomic_read(&d->pfifo.halt);
        qatomic_set(&d->pfifo.halt, true);
        pgraph_pre_savevm_trigger(d);
        nv2a_unlock_fifo(d);
        bql_unlock();
        pgraph_pre_savevm_wait(d);
        bql_lock();
        nv2a_lock_fifo(d);
        save->prepared = true;
        save->locked = true;
    } else if (!save->locked) {
        nv2a_lock_fifo(d);
        save->locked = true;
    }
}

void nv2a_metal4_save_release(NV2AState *d)
{
    NV2AMetalSaveLifecycle *save = &d->metal4_save;
    if (save->locked) {
        save->locked = false;
        nv2a_unlock_fifo(d);
    }
}

void nv2a_metal4_save_cleanup(NV2AState *d)
{
    NV2AMetalSaveLifecycle *save = &d->metal4_save;
    if (!save->prepared)
        return;
    if (!save->locked) {
        nv2a_lock_fifo(d);
        save->locked = true;
    }
    qatomic_set(&d->pfifo.halt, save->previous_halt);
    save->prepared = false;
    nv2a_metal4_save_release(d);
}

bool nv2a_metal4_save_pre_save(NV2AState *d, Error **errp)
{
    NV2AMetalSaveLifecycle *save = &d->metal4_save;
    if (!save->prepared || !save->locked) {
        error_setg(errp, "Metal 4 save capture has not been prepared");
        return false;
    }
    if (!pgraph_metal4_pre_save_check(d, errp)) {
        nv2a_metal4_save_release(d);
        return false;
    }
    return true;
}

static int save_notify(NotifierWithReturn *notifier, void *data, Error **errp)
{
    NV2AState *d = container_of(notifier, NV2AState, metal4_save.notifier);
    PrecopyNotifyData *event = data;
    if (event->reason == PRECOPY_NOTIFY_CLEANUP) {
        nv2a_metal4_save_cleanup(d);
    } else if (event->reason == PRECOPY_NOTIFY_SETUP && uses_metal4(d) &&
               !runstate_is_live(runstate_get())) {
        /* Snapshot setup runs even when vm_stop skipped a paused VM. This
         * notifier precedes RAM iteration; a late device pre_save cannot
         * make already serialized RAM consistent with GPU writebacks. */
        nv2a_metal4_save_prepare(d);
        if (!nv2a_metal4_save_pre_save(d, errp))
            return -EINVAL;
    }
    return 0;
}

void nv2a_metal4_save_init(NV2AState *d)
{
    d->metal4_save.notifier.notify = save_notify;
    precopy_add_notifier(&d->metal4_save.notifier);
}

void nv2a_metal4_save_destroy(NV2AState *d)
{
    nv2a_metal4_save_cleanup(d);
    precopy_remove_notifier(&d->metal4_save.notifier);
}
