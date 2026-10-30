/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_METAL_SAVE_LIFECYCLE_H
#define HW_XBOX_NV2A_METAL_SAVE_LIFECYCLE_H

#include <stdbool.h>
#include "qemu/notify.h"

typedef struct NV2AState NV2AState;
typedef struct Error Error;

/* Host-only ownership; never serialized as Xbox device state. */
typedef struct NV2AMetalSaveLifecycle {
    NotifierWithReturn notifier;
    bool prepared;
    bool locked;
    bool previous_halt;
} NV2AMetalSaveLifecycle;

#ifdef __cplusplus
extern "C" {
#endif
void nv2a_metal4_save_init(NV2AState *d);
void nv2a_metal4_save_destroy(NV2AState *d);
void nv2a_metal4_save_prepare(NV2AState *d);
void nv2a_metal4_save_release(NV2AState *d);
void nv2a_metal4_save_cleanup(NV2AState *d);
bool nv2a_metal4_save_pre_save(NV2AState *d, Error **errp);
#ifdef __cplusplus
}
#endif

#endif
