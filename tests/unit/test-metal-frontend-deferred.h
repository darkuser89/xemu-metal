/* Skipped drawable frames retain host state and defer only GPU recording.
 * No SDL video initialization, native window or application is created.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TEST_METAL_FRONTEND_DEFERRED_H
#define TEST_METAL_FRONTEND_DEFERRED_H
#import "ui/xui/metal4/window.h"

static __weak NV2AMetalCommands *df_commands;
static BOOL df_observe, df_fail_begin, df_fail_pin, df_fail_submit;
static unsigned df_begins, df_pins, df_submits, df_waits;
static id (*df_begin_original)(id, SEL, NSError **);
static BOOL (*df_pin_original)(id, SEL, id, NSError **);
static BOOL (*df_submit_original)(id, SEL, NSError **);
static BOOL (*df_wait_original)(id, SEL, NSError **);
static BOOL df_error(NSError **error, NSString *phase)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"test.frontend.deferred"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : phase }];
    return NO;
}
static id df_begin(id object, SEL selector, NSError **error)
{
    if (df_observe && object == df_commands) {
        df_begins++;
        if (df_fail_begin) {
            df_fail_begin = NO;
            df_error(error, @"begin");
            return nil;
        }
    }
    return df_begin_original(object, selector, error);
}
static BOOL df_pin(id object, SEL selector, id value, NSError **error)
{
    if (df_observe && object == df_commands &&
        [value isKindOfClass:FrontendFrame.class]) {
        df_pins++;
        if (df_fail_pin) {
            df_fail_pin = NO;
            return df_error(error, @"pin");
        }
    }
    return df_pin_original(object, selector, value, error);
}
static BOOL df_submit(id object, SEL selector, NSError **error)
{
    if (df_observe && object == df_commands) {
        df_submits++;
        if (df_fail_submit) {
            df_fail_submit = NO;
            return df_error(error, @"submit");
        }
    }
    return df_submit_original(object, selector, error);
}
static BOOL df_wait(id object, SEL selector, NSError **error)
{
    if (df_observe && object == df_commands)
        df_waits++;
    return df_wait_original(object, selector, error);
}
@interface DeferredFrontendWindow : NSObject
@property(nonatomic) NV2AMetalCommands *commands;
@property(nonatomic, readonly) id<MTLTexture> target;
@property(nonatomic) unsigned frames, presents;
- (BOOL)beginFrameWithError:(NSError **)error;
- (BOOL)presentWithError:(NSError **)error;
- (void)cancelFrame;
- (BOOL)closeWithError:(NSError **)error;
- (BOOL)setVsync:(BOOL)vsync error:(NSError **)error;
@end
@implementation DeferredFrontendWindow
- (id<MTLTexture>)target
{
    return nil;
}
- (BOOL)beginFrameWithError:(NSError **)error
{
    (void)error;
    assert(!self.commands.commandBuffer);
    _frames++;
    return YES;
}
- (BOOL)presentWithError:(NSError **)error
{
    _presents++;
    return df_error(error, @"Unexpected drawable presentation");
}
- (void)cancelFrame
{
}
- (BOOL)closeWithError:(NSError **)error
{
    return [_commands waitUntilIdleWithError:error];
}
- (BOOL)setVsync:(BOOL)vsync error:(NSError **)error
{
    (void)vsync;
    (void)error;
    return YES;
}
@end
static DeferredFrontendWindow *df_window;
@interface XemuMetal4Window (DeferredFrontendConstructor)
- (instancetype)df_initWithWindow:(SDL_Window *)window
                         commands:(NV2AMetalCommands *)commands
                            vsync:(BOOL)vsync
                            error:(NSError **)error
    __attribute__((objc_method_family(init)));
@end
@implementation XemuMetal4Window (DeferredFrontendConstructor)
- (instancetype)df_initWithWindow:(SDL_Window *)window
                         commands:(NV2AMetalCommands *)commands
                            vsync:(BOOL)vsync
                            error:(NSError **)error
{
    (void)window;
    (void)vsync;
    (void)error;
    self = (id)[DeferredFrontendWindow new];
    df_window = (DeferredFrontendWindow *)self;
    df_window.commands = commands;
    df_commands = commands;
    return self;
}
@end
static void df_reset(void)
{
    df_begins = df_pins = df_submits = df_waits = 0;
    df_fail_begin = df_fail_pin = df_fail_submit = NO;
}
static FrontendFrame *df_frame(id<MTLDevice> device, unsigned r, unsigned g,
                               unsigned b)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    FrontendFrame *frame = [FrontendFrame new];
    frame.texture = [device newTextureWithDescriptor:td];
    assert(frame.texture);
    uint8_t bytes[64];
    for (unsigned i = 0; i < sizeof(bytes); i += 4) {
        bytes[i] = r;
        bytes[i + 1] = g;
        bytes[i + 2] = b;
        bytes[i + 3] = 255;
    }
    [frame.texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                     mipmapLevel:0
                       withBytes:bytes
                     bytesPerRow:16];
    NV2AMetalDisplayUniforms u = { .scale = { 1, 1 } };
    for (unsigned i = 0; i < 256; i++)
        u.palette[i] = i | i << 8 | i << 16;
    frame.displayUniforms = u;
    return frame;
}
static id<MTLTexture> df_target(id<MTLDevice> device)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    assert(texture);
    uint8_t bytes[64];
    memset(bytes, 0x7c, sizeof(bytes));
    [texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
               mipmapLevel:0
                 withBytes:bytes
               bytesPerRow:16];
    return texture;
}
static void df_texture_color(id<MTLTexture> texture, unsigned r, unsigned g,
                             unsigned b)
{
    uint8_t bytes[64];
    [texture getBytes:bytes
          bytesPerRow:16
           fromRegion:MTLRegionMake2D(0, 0, 4, 4)
          mipmapLevel:0];
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++)
            pixel(bytes, x, y, r, g, b);
}
static void df_unchanged(id<MTLTexture> texture)
{
    uint8_t bytes[64];
    [texture getBytes:bytes
          bytesPerRow:16
           fromRegion:MTLRegionMake2D(0, 0, 4, 4)
          mipmapLevel:0];
    for (uint8_t value : bytes)
        assert(value == 0x7c);
}
static void df_drain(void)
{
    NSError *error = nil;
    assert([df_commands waitUntilIdleWithError:&error]);
}
static id<MTLBuffer> df_copy_before_alias(id<MTLTexture> texture)
{
    NSError *error = nil;
    NV2AMetalCommands *commands = df_commands;
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:1024
                                     options:MTLResourceStorageModeShared];
    assert(output && [commands addResource:output error:&error] &&
           [commands addResource:texture error:&error]);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(4, 4, 1)
                        toBuffer:output
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [encoder endEncoding];
    return output;
}
static void df_idle_frames(id<MTLDevice> device)
{
    __weak FrontendFrame *old;
    __weak FrontendFrame *latest;
    df_reset();
    @autoreleasepool {
        ok(xemu_metal4_ui_begin(0));
        FrontendFrame *a = df_frame(device, 255, 0, 0);
        old = a;
        ok(xemu_metal4_ui_set_frame((__bridge void *)a));
        a = nil;
        assert(old);
        FrontendFrame *b = df_frame(device, 0, 255, 0);
        latest = b;
        ok(xemu_metal4_ui_set_frame((__bridge void *)b));
        b = nil;
        ok(xemu_metal4_ui_framebuffer(1, 1, false));
        ImDrawData empty;
        empty.DisplaySize = ImVec2(4, 4);
        ok(xemu_metal4_ui_end(&empty));
        assert(latest);
        ok(xemu_metal4_ui_set_frame(nullptr));
    }
    assert(!old && !latest);
    ok(xemu_metal4_ui_begin(0));
    xemu_metal4_ui_cancel();
    ok(xemu_metal4_ui_begin(0));
    ok(xemu_metal4_ui_end(nullptr));
    assert(!df_commands.commandBuffer && !df_begins && !df_pins &&
           !df_submits && !df_waits && !df_window.presents);
}
static void df_nested_frames(id<MTLDevice> device)
{
    id<MTLTexture> parent = df_target(device), child = df_target(device);
    id<MTLTexture> alias =
        [parent newTextureViewWithPixelFormat:parent.pixelFormat];
    assert(alias && alias.parentTexture == parent);
    id<MTLBuffer> green;
    __weak FrontendFrame *first;
    __weak FrontendFrame *second;
    df_reset();
    @autoreleasepool {
        FrontendFrame *a = df_frame(device, 0, 255, 0);
        first = a;
        ok(xemu_metal4_ui_set_frame((__bridge void *)a));
        ok(xemu_metal4_ui_begin(0));
        assert(!df_commands.commandBuffer && !df_begins && !df_pins);
        assert(
            !xemu_metal4_ui_push_target((uintptr_t)(__bridge void *)a.texture));
        assert(!df_begins);
        ok(xemu_metal4_ui_push_target((uintptr_t)(__bridge void *)parent));
        ok(xemu_metal4_ui_framebuffer(1, 1, false));
        green = df_copy_before_alias(parent);
        FrontendFrame *b = df_frame(device, 0, 0, 255);
        second = b;
        ok(xemu_metal4_ui_set_frame((__bridge void *)b));
        ok(xemu_metal4_ui_push_target((uintptr_t)(__bridge void *)alias));
        ok(xemu_metal4_ui_framebuffer(1, 1, false));
        ok(xemu_metal4_ui_pop_target());
        ok(xemu_metal4_ui_push_target((uintptr_t)(__bridge void *)child));
        ok(xemu_metal4_ui_framebuffer(1, 1, false));
        ok(xemu_metal4_ui_pop_target());
        ok(xemu_metal4_ui_set_frame(nullptr));
        ok(xemu_metal4_ui_pop_target());
        ok(xemu_metal4_ui_end(nullptr));
    }
    assert(first && second && !df_commands.commandBuffer);
    assert(df_begins == 1 && df_pins == 2 && df_submits == 1 && !df_waits);
    df_drain();
    /* Actual GPU bytes precede final lease/identity checks. The early copy
     * also proves the first frame was sampled before the aliased blue draw. */
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++) {
            const uint8_t *p =
                (const uint8_t *)green.contents + y * 256 + x * 4;
            assert(p[0] == 0 && p[1] == 255 && p[2] == 0 && p[3] == 255);
        }
    df_texture_color(parent, 0, 0, 255);
    df_texture_color(child, 0, 0, 255);
    assert(!first && !second && !df_window.presents);
}
static void df_failures(id<MTLDevice> device)
{
    for (unsigned phase = 0; phase < 4; phase++) {
        id<MTLTexture> target = df_target(device);
        df_reset();
        @autoreleasepool {
            FrontendFrame *frame = df_frame(device, 255, 0, 0);
            ok(xemu_metal4_ui_set_frame((__bridge void *)frame));
            ok(xemu_metal4_ui_begin(0));
            if (!phase) {
                df_fail_begin = YES;
                assert(!xemu_metal4_ui_push_target(
                    (uintptr_t)(__bridge void *)target));
                assert(strstr(xemu_metal4_ui_error(), "begin") &&
                       !df_commands.commandBuffer && df_begins == 1 &&
                       !df_pins);
                /* A failed lazy begin leaves the same host frame retryable. */
                ok(xemu_metal4_ui_push_target(
                    (uintptr_t)(__bridge void *)target));
            } else if (phase == 1) {
                df_fail_pin = YES;
                assert(!xemu_metal4_ui_push_target(
                    (uintptr_t)(__bridge void *)target));
                assert(strstr(xemu_metal4_ui_error(), "pin") &&
                       !df_commands.commandBuffer && !df_submits);
                df_unchanged(target);
                ok(xemu_metal4_ui_begin(0));
                ok(xemu_metal4_ui_push_target(
                    (uintptr_t)(__bridge void *)target));
            } else {
                ok(xemu_metal4_ui_push_target(
                    (uintptr_t)(__bridge void *)target));
            }
            ok(xemu_metal4_ui_framebuffer(1, 1, false));
            if (phase == 2) {
                xemu_metal4_ui_cancel();
                df_unchanged(target);
                assert(!df_submits && !df_commands.commandBuffer);
                ok(xemu_metal4_ui_begin(0));
                ok(xemu_metal4_ui_push_target(
                    (uintptr_t)(__bridge void *)target));
                ok(xemu_metal4_ui_framebuffer(1, 1, false));
            }
            ok(xemu_metal4_ui_pop_target());
            if (phase == 3) {
                df_fail_submit = YES;
                assert(!xemu_metal4_ui_end(nullptr));
                df_unchanged(target);
                assert(strstr(xemu_metal4_ui_error(), "submit") &&
                       !df_commands.commandBuffer);
                ok(xemu_metal4_ui_begin(0));
                ok(xemu_metal4_ui_push_target(
                    (uintptr_t)(__bridge void *)target));
                ok(xemu_metal4_ui_framebuffer(1, 1, false));
                ok(xemu_metal4_ui_pop_target());
            }
            ok(xemu_metal4_ui_set_frame(nullptr));
            ok(xemu_metal4_ui_end(nullptr));
        }
        df_drain();
        df_texture_color(target, 255, 0, 0);
        assert(!df_window.presents);
    }
}
static void frontend_deferred_tests(void)
{
    Method constructor = class_getInstanceMethod(
        XemuMetal4Window.class,
        @selector(initWithWindow:commands:vsync:error:));
    Method replacement = class_getInstanceMethod(
        XemuMetal4Window.class,
        @selector(df_initWithWindow:commands:vsync:error:));
    Method begin = class_getInstanceMethod(NV2AMetalCommands.class,
                                           @selector(beginWithError:));
    Method pin = class_getInstanceMethod(NV2AMetalCommands.class,
                                         @selector(keepAlive:error:));
    Method submit = class_getInstanceMethod(NV2AMetalCommands.class,
                                            @selector(submitWithError:));
    Method wait = class_getInstanceMethod(NV2AMetalCommands.class,
                                          @selector(waitUntilIdleWithError:));
    assert(constructor && replacement && begin && pin && submit && wait);
    df_begin_original =
        (decltype(df_begin_original))method_getImplementation(begin);
    df_pin_original = (decltype(df_pin_original))method_getImplementation(pin);
    df_submit_original =
        (decltype(df_submit_original))method_getImplementation(submit);
    df_wait_original =
        (decltype(df_wait_original))method_getImplementation(wait);
    method_exchangeImplementations(constructor, replacement);
    method_setImplementation(begin, (IMP)df_begin);
    method_setImplementation(pin, (IMP)df_pin);
    method_setImplementation(submit, (IMP)df_submit);
    method_setImplementation(wait, (IMP)df_wait);
    @try {
        char token;
        ok(xemu_metal4_ui_init((SDL_Window *)&token, false));
        assert(df_window && df_commands);
        id<MTLDevice> device = df_commands.device;
        df_observe = YES;
        df_idle_frames(device);
        df_nested_frames(device);
        df_failures(device);
        df_observe = NO;
        ok(xemu_metal4_ui_close());
    } @finally {
        df_observe = NO;
        df_window = nil;
        df_commands = nil;
        method_setImplementation(begin, (IMP)df_begin_original);
        method_setImplementation(pin, (IMP)df_pin_original);
        method_setImplementation(submit, (IMP)df_submit_original);
        method_setImplementation(wait, (IMP)df_wait_original);
        method_exchangeImplementations(constructor, replacement);
    }
    puts(
        "Metal4 deferred frontend: nil-root host frames make no GPU recording, "
        "nested/aliased child GPU pixels and two frame leases, lazy begin/pin "
        "failure, cancel and failed-submit retry PASS (no SDL/window/app)");
}
#endif
