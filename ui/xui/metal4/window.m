/*
 * xemu SDL window presentation with the Metal 4 core API
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#import "window.h"
#include <SDL3/SDL_metal.h>
#include <assert.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/CATransaction.h>

static BOOL window_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.ui.metal4.window"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

@implementation XemuMetal4Window {
    SDL_Window *_window;
    SDL_MetalView _view;
    CAMetalLayer *_layer;
    BOOL _frameActive;
    BOOL _closed;
}

- (nullable instancetype)initWithWindow:(SDL_Window *)window
                               commands:(NV2AMetalCommands *)commands
                                  vsync:(BOOL)vsync
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (![NSThread isMainThread] || !window || !commands.device) {
        window_error(error,
                     @"Metal window requires the main thread and a device");
        return nil;
    }
    SDL_WindowFlags flags = SDL_GetWindowFlags(window);
    if (!(flags & SDL_WINDOW_METAL) ||
        (flags & (SDL_WINDOW_OPENGL | SDL_WINDOW_VULKAN))) {
        window_error(error, @"Metal 4 requires an SDL_WINDOW_METAL window");
        return nil;
    }
    _window = window;
    _commands = commands;
    _view = SDL_Metal_CreateView(window);
    if (!_view) {
        window_error(error, [NSString stringWithUTF8String:SDL_GetError()]);
        return nil;
    }
    _layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(_view);
    if (!_layer) {
        window_error(error, @"SDL did not create a CAMetalLayer");
        return nil;
    }
    _layer.device = commands.device;
    /* Gamma is applied by the display shader. Do not use an sRGB texture,
     * which would encode the shader output a second time. */
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.framebufferOnly = YES;
    _layer.opaque = YES;
    _layer.maximumDrawableCount = 3;
    _layer.allowsNextDrawableTimeout = YES;
    _layer.presentsWithTransaction = NO;
    _layer.displaySyncEnabled = vsync;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _layer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    return self;
}

- (BOOL)setVsync:(BOOL)vsync error:(NSError **)error
{
    if (![NSThread isMainThread] || _closed) {
        return window_error(
            error, @"Metal Vsync requires an open window on the main thread");
    }
    _layer.displaySyncEnabled = vsync;
    return YES;
}

- (BOOL)beginFrameWithError:(NSError **)error
{
    if (![NSThread isMainThread] || _closed || _frameActive ||
        _commands.commandBuffer) {
        return window_error(error, @"Cannot begin a Metal window frame");
    }
    SDL_WindowFlags flags = SDL_GetWindowFlags(_window);
    if (flags & (SDL_WINDOW_MINIMIZED | SDL_WINDOW_HIDDEN)) {
        return YES;
    }
    int width, height;
    if (!SDL_GetWindowSizeInPixels(_window, &width, &height)) {
        return window_error(error,
                            [NSString stringWithUTF8String:SDL_GetError()]);
    }
    if (width <= 0 || height <= 0) {
        return YES;
    }
    if (!CGSizeEqualToSize(_layer.drawableSize, CGSizeMake(width, height))) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _layer.drawableSize = CGSizeMake(width, height);
        [CATransaction commit];
    }
    /* Reclaim a completed command slot FIRST. Its old drawable must be
     * released before asking the bounded three-drawable pool for another. */
    if (![_commands beginWithError:error]) {
        return NO;
    }
    _frameActive = YES;
    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) {
        [self cancelFrame];
        return YES;
    }
    if (![_commands presentDrawableOnSubmit:drawable error:error]) {
        [self cancelFrame];
        return NO;
    }
    _target = drawable.texture;
    return YES;
}

- (BOOL)presentWithError:(NSError **)error
{
    if (![NSThread isMainThread] || !_frameActive) {
        return window_error(error, @"No Metal window frame is recording");
    }
    if (![_commands submitWithError:error]) {
        return NO;
    }
    _frameActive = NO;
    _target = nil;
    return YES;
}

- (void)cancelFrame
{
    assert([NSThread isMainThread]);
    if (_frameActive) {
        [_commands cancel];
        _frameActive = NO;
        _target = nil;
    }
}

- (BOOL)closeWithError:(NSError **)error
{
    if (![NSThread isMainThread]) {
        return window_error(error,
                            @"Metal window teardown requires the main thread");
    }
    if (_closed) {
        return YES;
    }
    if (_commands.commandBuffer && !_frameActive) {
        return window_error(
            error,
            @"Finish the other command recording before closing the window");
    }
    [self cancelFrame];
    BOOL success = [_commands waitUntilIdleWithError:error];
    _layer = nil;
    SDL_Metal_DestroyView(_view);
    _view = NULL;
    _window = NULL;
    _closed = YES;
    return success;
}

- (void)dealloc
{
    /* Submission owns the drawable/layer until GPU completion, independently
     * of this view wrapper. Explicit close normally drains the queue first. */
    if (_view) {
        assert([NSThread isMainThread]);
        [self cancelFrame];
        SDL_Metal_DestroyView(_view);
    }
}

@end
