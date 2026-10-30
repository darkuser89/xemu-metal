/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef XEMU_UI_TEXTURE_H
#define XEMU_UI_TEXTURE_H
#include <stdint.h>
#include <stdbool.h>
#if defined(__APPLE__) && defined(__aarch64__) && \
    __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 260000
#error "The native Metal4 UI requires a macOS 26 deployment target"
#endif
#if defined(__APPLE__) && defined(__aarch64__)
#define XEMU_NATIVE_METAL4_UI 1
typedef uintptr_t XemuTexture;
#ifdef __cplusplus
extern "C" {
#endif
bool xemu_hud_uses_metal4(void);
#ifdef __cplusplus
}
#endif
#else
typedef unsigned int XemuTexture;
#endif
#endif
