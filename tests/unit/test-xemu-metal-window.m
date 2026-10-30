/*
 * CPU-only SDL/Metal window lifecycle tests. No window or GPU is created.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#import "ui/xui/metal4/window.h"
#include <SDL3/SDL_metal.h>
#include <assert.h>
#include <stdio.h>

static BOOL test_error(NSError **error)
{
    if (error) {
        *error = [NSError errorWithDomain:@"test.window" code:1 userInfo:nil];
    }
    return NO;
}

@interface WindowTestDrawable : NSObject
@property(nonatomic, strong) id texture;
@end
@implementation WindowTestDrawable
@end

@interface WindowTestCommands : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic, strong) id commandBuffer;
@property(nonatomic, strong) id drawable;
@property(nonatomic) unsigned begins;
@property(nonatomic) unsigned submits;
@property(nonatomic) unsigned cancels;
@property(nonatomic) unsigned waits;
@property(nonatomic) BOOL failBegin;
@property(nonatomic) BOOL failAttach;
@property(nonatomic) BOOL failSubmit;
@property(nonatomic) BOOL failWait;
- (id)beginWithError:(NSError **)error;
- (BOOL)presentDrawableOnSubmit:(id)drawable error:(NSError **)error;
- (BOOL)submitWithError:(NSError **)error;
- (void)cancel;
- (BOOL)waitUntilIdleWithError:(NSError **)error;
@end

@implementation WindowTestCommands
- (id)beginWithError:(NSError **)error
{
    assert(!self.commandBuffer);
    if (self.failBegin) {
        test_error(error);
        return nil;
    }
    self.begins++;
    self.commandBuffer = [NSObject new];
    return self.commandBuffer;
}
- (BOOL)presentDrawableOnSubmit:(id)drawable error:(NSError **)error
{
    assert(self.commandBuffer && drawable && !self.drawable);
    if (self.failAttach) {
        return test_error(error);
    }
    self.drawable = drawable;
    return YES;
}
- (BOOL)submitWithError:(NSError **)error
{
    assert(self.commandBuffer && self.drawable);
    if (self.failSubmit) {
        return test_error(error);
    }
    self.submits++;
    self.commandBuffer = nil;
    self.drawable = nil;
    return YES;
}
- (void)cancel
{
    assert(self.commandBuffer);
    self.cancels++;
    self.commandBuffer = nil;
    self.drawable = nil;
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    assert(!self.commandBuffer);
    self.waits++;
    return self.failWait ? test_error(error) : YES;
}
@end

@interface WindowTestLayer : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic) MTLPixelFormat pixelFormat;
@property(nonatomic) BOOL framebufferOnly;
@property(nonatomic) BOOL opaque;
@property(nonatomic) NSUInteger maximumDrawableCount;
@property(nonatomic) BOOL allowsNextDrawableTimeout;
@property(nonatomic) BOOL presentsWithTransaction;
@property(nonatomic) BOOL displaySyncEnabled;
@property(nonatomic) CGSize drawableSize;
@property(nonatomic) CGColorSpaceRef colorspace;
@property(nonatomic) BOOL unavailable;
@property(nonatomic) unsigned requests;
@property(nonatomic, strong) WindowTestCommands *commands;
- (id)nextDrawable;
@end

@implementation WindowTestLayer {
    CGColorSpaceRef _colorSpace;
}
- (CGColorSpaceRef)colorspace
{
    return _colorSpace;
}
- (void)setColorspace:(CGColorSpaceRef)colorSpace
{
    CGColorSpaceRetain(colorSpace);
    CGColorSpaceRelease(_colorSpace);
    _colorSpace = colorSpace;
}
- (id)nextDrawable
{
    /* The command ring must retire its old drawable BEFORE this request. */
    assert(self.commands.commandBuffer);
    self.requests++;
    if (self.unavailable) {
        return nil;
    }
    WindowTestDrawable *drawable = [WindowTestDrawable new];
    drawable.texture = [NSObject new];
    return drawable;
}
- (void)dealloc
{
    CGColorSpaceRelease(_colorSpace);
}
@end

static WindowTestLayer *test_layer;
static SDL_WindowFlags test_flags;
static int pixel_width = 4, pixel_height = 4;
static BOOL fail_view, fail_layer, fail_size;
static unsigned views_created, views_destroyed;

/* These definitions replace the SDL calls made by window.m. The unit test
 * never initializes SDL video or creates a real NSView/CAMetalLayer. */
SDL_WindowFlags SDL_GetWindowFlags(SDL_Window *window)
{
    assert(window);
    return test_flags;
}
bool SDL_GetWindowSizeInPixels(SDL_Window *window, int *width, int *height)
{
    assert(window);
    *width = pixel_width;
    *height = pixel_height;
    return !fail_size;
}
const char *SDL_GetError(void)
{
    return "simulated SDL failure";
}
SDL_MetalView SDL_Metal_CreateView(SDL_Window *window)
{
    assert(window);
    if (fail_view) {
        return NULL;
    }
    views_created++;
    return (__bridge void *)test_layer;
}
void *SDL_Metal_GetLayer(SDL_MetalView view)
{
    assert(view == (__bridge void *)test_layer);
    return fail_layer ? NULL : view;
}
void SDL_Metal_DestroyView(SDL_MetalView view)
{
    assert(view == (__bridge void *)test_layer);
    views_destroyed++;
}

int main(void)
{
    @autoreleasepool {
        char window_token;
        SDL_Window *window = (SDL_Window *)&window_token;
        WindowTestCommands *commands = [WindowTestCommands new];
        commands.device = [NSObject new];
        test_layer = [WindowTestLayer new];
        test_layer.commands = commands;
        NSError *error = nil;
        test_flags = SDL_WINDOW_METAL | SDL_WINDOW_OPENGL;
        assert(![[XemuMetal4Window alloc]
            initWithWindow:window
                  commands:(NV2AMetalCommands *)commands
                     vsync:YES
                     error:&error]);
        assert(views_created == 0);
        test_flags = SDL_WINDOW_METAL;
        fail_view = YES;
        assert(![[XemuMetal4Window alloc]
            initWithWindow:window
                  commands:(NV2AMetalCommands *)commands
                     vsync:YES
                     error:&error]);
        assert(views_created == 0);
        fail_view = NO;
        fail_layer = YES;
        assert(![[XemuMetal4Window alloc]
            initWithWindow:window
                  commands:(NV2AMetalCommands *)commands
                     vsync:YES
                     error:&error]);
        assert(views_created == 1 && views_destroyed == 1);
        fail_layer = NO;
        XemuMetal4Window *host = [[XemuMetal4Window alloc]
            initWithWindow:window
                  commands:(NV2AMetalCommands *)commands
                     vsync:YES
                     error:&error];
        assert(host);
        assert(test_layer.device == commands.device);
        assert(test_layer.pixelFormat == MTLPixelFormatBGRA8Unorm);
        assert(test_layer.framebufferOnly && test_layer.opaque);
        assert(test_layer.maximumDrawableCount == 3);
        assert(test_layer.allowsNextDrawableTimeout &&
               !test_layer.presentsWithTransaction);
        assert(test_layer.displaySyncEnabled);
        assert([host setVsync:NO error:&error] &&
               !test_layer.displaySyncEnabled);
        CGColorSpaceRef expected =
            CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        assert(CFEqual(test_layer.colorspace, expected));
        CGColorSpaceRelease(expected);

        test_flags |= SDL_WINDOW_HIDDEN;
        assert([host beginFrameWithError:&error] && !host.target);
        assert(commands.begins == 0 && test_layer.requests == 0);
        test_flags = SDL_WINDOW_METAL | SDL_WINDOW_MINIMIZED;
        assert([host beginFrameWithError:&error] && !host.target);
        test_flags = SDL_WINDOW_METAL;
        fail_size = YES;
        assert(![host beginFrameWithError:&error]);
        fail_size = NO;
        pixel_width = 0;
        assert([host beginFrameWithError:&error] && !host.target);
        pixel_width = 8;
        pixel_height = 6;
        commands.failBegin = YES;
        assert(![host beginFrameWithError:&error]);
        commands.failBegin = NO;
        test_layer.unavailable = YES;
        assert([host beginFrameWithError:&error] && !host.target &&
               !commands.commandBuffer);
        assert(commands.cancels == 1);
        test_layer.unavailable = NO;
        assert([host beginFrameWithError:&error] && host.target);
        assert(CGSizeEqualToSize(test_layer.drawableSize, CGSizeMake(8, 6)));
        assert(![host beginFrameWithError:&error]);
        assert([host presentWithError:&error] && !host.target &&
               !commands.commandBuffer);
        assert(commands.submits == 1);
        assert(![host presentWithError:&error]);

        commands.failSubmit = YES;
        assert([host beginFrameWithError:&error] && host.target);
        assert(![host presentWithError:&error] && host.target);
        [host cancelFrame];
        assert(!host.target && !commands.commandBuffer);
        commands.failSubmit = NO;
        commands.failAttach = YES;
        assert(![host beginFrameWithError:&error] && !host.target &&
               !commands.commandBuffer);
        commands.failAttach = NO;
        assert([commands beginWithError:&error]);
        assert(![host beginFrameWithError:&error]);
        assert(![host closeWithError:&error] && views_destroyed == 1);
        [commands cancel];

        assert([host beginFrameWithError:&error] && host.target);
        commands.failWait = YES;
        assert(![host closeWithError:&error] && !host.target);
        assert(views_destroyed == 2 && commands.waits == 1);
        assert([host closeWithError:&error] && views_destroyed == 2);
        assert(![host beginFrameWithError:&error]);
        assert(![host setVsync:YES error:&error]);
        host = nil;
        assert(views_destroyed == views_created);
        puts("Metal window lifecycle, resize, Vsync, drawable pool and "
             "cancellation: PASS (CPU only)");
    }
    return 0;
}
