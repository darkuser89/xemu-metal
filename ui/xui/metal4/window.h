/*
 * xemu SDL window presentation with the Metal 4 core API
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef XEMU_UI_METAL4_WINDOW_H
#define XEMU_UI_METAL4_WINDOW_H

#import "hw/xbox/nv2a/pgraph/metal/command.h"
#include <SDL3/SDL_video.h>

NS_ASSUME_NONNULL_BEGIN

/* All methods, including destruction, belong to the main thread. The caller
 * owns the SDL_WINDOW_METAL window and closes this view before destroying it.
 * The commands object must be dedicated to presentation on this window. */
API_AVAILABLE(macos(26.0))
@interface XemuMetal4Window : NSObject
@property(nonatomic, readonly) NV2AMetalCommands *commands;
@property(nonatomic, readonly, nullable) id<MTLTexture> target;

- (nullable instancetype)initWithWindow:(SDL_Window *)window
                               commands:(NV2AMetalCommands *)commands
                                  vsync:(BOOL)vsync
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)setVsync:(BOOL)vsync error:(NSError *_Nullable *_Nullable)error;

/* YES with a nil target means a skipped frame (hidden/minimized/zero size or
 * temporarily no drawable). Otherwise encode to the BGRA8Unorm target and
 * finish with presentWithError: or cancelFrame. */
- (BOOL)beginFrameWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)presentWithError:(NSError *_Nullable *_Nullable)error;
- (void)cancelFrame;

/* Cancel any active frame, drain submitted work, then destroy the SDL Metal
 * view. Even on GPU failure the view is closed; the error is returned. */
- (BOOL)closeWithError:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END

#endif
