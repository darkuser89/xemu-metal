/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "frontend.h"
#import "window.h"
#import "imgui-renderer.h"
#import "decal.h"
#import "hw/xbox/nv2a/pgraph/metal/scanout-pgraph.h"
#include <imgui.h>
#include <cmath>

@interface XemuMetal4Frontend : NSObject
@property(nonatomic, strong) NV2AMetalCommands *commands;
@property(nonatomic, strong) XemuMetal4Window *window;
@property(nonatomic, strong) XemuMetal4ImGui *imgui;
@property(nonatomic, strong) NV2AMetalFramebuffer *frame;
@property(nonatomic, strong) id<MTLTexture> target;
@property(nonatomic, strong) NSMutableArray *targets;
@property(nonatomic, strong) NSMutableArray<XemuMetal4Decal *> *decals;
@property(nonatomic, strong) NSMutableDictionary *decalPipelines;
@property(nonatomic, strong) NSMutableDictionary *displayPipelines;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL drawable;
@end
@implementation XemuMetal4Frontend
@end

static XemuMetal4Frontend *ui;
static NSError *ui_error;

struct UIErrorCapture {
    NSError *__strong &value;
    explicit UIErrorCapture(NSError *__strong &error) : value(error)
    {
    }
    ~UIErrorCapture()
    {
        if (value)
            ui_error = value;
    }
};

static bool fail(NSString *message)
{
    ui_error =
        [NSError errorWithDomain:@"xemu.ui.metal4.frontend"
                            code:1
                        userInfo:@{ NSLocalizedDescriptionKey : message }];
    return false;
}
static bool ready()
{
    if (![NSThread isMainThread])
        return false;
    return ui ? true : fail(@"Metal UI requires an open session");
}
static id<MTLTexture> texture(uintptr_t handle)
{
    return (__bridge id<MTLTexture>)(void *)handle;
}
static bool flush_decals()
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    if (!ui.decals.count)
        return true;
    XemuMetal4Decals *pipeline = ui.decalPipelines[@(ui.target.pixelFormat)];
    BOOL ok = [pipeline encodeDecals:ui.decals
                            commands:ui.commands
                              target:ui.target
                               clear:NO
                               error:&error];
    if (ok)
        [ui.decals removeAllObjects];
    return ok;
}
static bool clear_target(id<MTLTexture> target)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    if (!target)
        return true;
    XemuMetal4Decals *pipeline = ui.decalPipelines[@(target.pixelFormat)];
    return [pipeline encodeDecals:@[]
                         commands:ui.commands
                           target:target
                            clear:YES
                            error:&error];
}
const char *xemu_metal4_ui_error(void)
{
    return ui_error ? ui_error.localizedDescription.UTF8String : "";
}
const char *xemu_metal4_ui_device_name(void)
{
    return ui ? ui.commands.device.name.UTF8String : "";
}
bool xemu_metal4_ui_init(SDL_Window *window, bool vsync)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    @autoreleasepool {
        if (![NSThread isMainThread])
            return false;
        if (ui || !ImGui::GetCurrentContext())
            return fail(@"Create Metal UI once, on the main ImGui thread");
        ui_error = nil;
        XemuMetal4Frontend *session = [XemuMetal4Frontend new];
        session.commands = [[NV2AMetalCommands alloc] initWithError:&error];
        if (!session.commands)
            return false;
        if (window) {
            session.window =
                [[XemuMetal4Window alloc] initWithWindow:window
                                                commands:session.commands
                                                   vsync:vsync
                                                   error:&error];
            if (!session.window)
                return false;
        }
        session.imgui =
            [[XemuMetal4ImGui alloc] initWithDevice:session.commands.device
                                        pixelFormat:MTLPixelFormatBGRA8Unorm
                                              error:&error];
        if (!session.imgui)
            return false;
        session.targets = [NSMutableArray new];
        session.decals = [NSMutableArray new];
        session.decalPipelines = [NSMutableDictionary new];
        session.displayPipelines = [NSMutableDictionary new];
        for (NSNumber *format in
             @[ @(MTLPixelFormatRGBA8Unorm), @(MTLPixelFormatBGRA8Unorm) ]) {
            XemuMetal4Decals *decal = [[XemuMetal4Decals alloc]
                initWithDevice:session.commands.device
                   pixelFormat:(MTLPixelFormat)format.unsignedIntegerValue
                         error:&error];
            NV2AMetalDisplay *display = [[NV2AMetalDisplay alloc]
                initWithDevice:session.commands.device
                   pixelFormat:(MTLPixelFormat)format.unsignedIntegerValue
                         error:&error];
            if (!decal || !display) {
                [session.imgui shutdown];
                return false;
            }
            session.decalPipelines[format] = decal;
            session.displayPipelines[format] = display;
        }
        ui = session;
        return true;
    }
}
void xemu_metal4_ui_cancel(void)
{
    if (!ready())
        return;
    [ui.window cancelFrame];
    [ui.commands cancel];
    [ui.decals removeAllObjects];
    [ui.targets removeAllObjects];
    ui.target = nil;
    ui.active = ui.drawable = NO;
}
bool xemu_metal4_ui_close(void)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    if (!ready())
        return false;
    xemu_metal4_ui_cancel();
    BOOL ok = ui.window ? [ui.window closeWithError:&error] :
                          [ui.commands waitUntilIdleWithError:&error];
    [ui.imgui shutdown];
    ui = nil;
    return ok;
}
bool xemu_metal4_ui_set_vsync(bool vsync)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    return ready() && (!ui.window || [ui.window setVsync:vsync error:&error]);
}
bool xemu_metal4_ui_new_frame(void)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    return ready() && [ui.imgui newFrameWithError:&error];
}
void xemu_metal4_ui_invalidate_fonts(void)
{
    if (ready())
        [ui.imgui invalidateFonts];
}
void xemu_metal4_ui_with_pool(void (*callback)(void *), void *opaque)
{
    @autoreleasepool {
        if ([NSThread isMainThread] && callback)
            callback(opaque);
    }
}
bool xemu_metal4_ui_set_frame(void *handle)
{
    if (!ready())
        return false;
    ui.frame = (__bridge NV2AMetalFramebuffer *)handle;
    return true;
}
uintptr_t xemu_metal4_ui_frame_texture(void)
{
    return ready() ? (uintptr_t)(__bridge void *)ui.frame.texture : 0;
}
bool xemu_metal4_ui_begin(uintptr_t target_handle)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    if (!ready())
        return false;
    if (ui.active)
        return fail(@"A Metal UI frame is already recording");
    if (ui.window && target_handle)
        return fail(@"A window session obtains its own drawable");
    if (!ui.window && !target_handle)
        return fail(@"Offscreen UI requires a target");
    if (ui.window) {
        if (![ui.window beginFrameWithError:&error])
            return false;
        ui.target = ui.window.target;
        ui.drawable = ui.target != nil;
    } else {
        id<MTLTexture> target = texture(target_handle);
        if (target.device != ui.commands.device ||
            target.pixelFormat != MTLPixelFormatBGRA8Unorm ||
            target.textureType != MTLTextureType2D || target.sampleCount != 1 ||
            !(target.usage & MTLTextureUsageRenderTarget))
            return fail(@"Invalid offscreen UI target");
        ui.target = target;
    }
    if (!ui.commands.commandBuffer && ![ui.commands beginWithError:&error])
        return false;
    ui.active = YES;
    if (!clear_target(ui.target)) {
        xemu_metal4_ui_cancel();
        return false;
    }
    return true;
}
bool xemu_metal4_ui_end(const ImDrawData *data)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    if (!ready())
        return false;
    if (!ui.active || ui.targets.count)
        return fail(@"Finish nested UI targets before ending the frame");
    if (!flush_decals() || (data && ui.target &&
                            ![ui.imgui encodeDrawData:data
                                             commands:ui.commands
                                               target:ui.target
                                                error:&error])) {
        xemu_metal4_ui_cancel();
        return false;
    }
    BOOL ok = ui.drawable ? [ui.window presentWithError:&error] :
                            [ui.commands submitWithError:&error];
    if (!ok) {
        xemu_metal4_ui_cancel();
        return false;
    }
    ui.active = ui.drawable = NO;
    ui.target = nil;
    return true;
}
bool xemu_metal4_ui_framebuffer(float sx, float sy, bool linear)
{
    NSError *error = nil;
    UIErrorCapture capture(error);
    if (!ready() || !ui.active || !flush_decals())
        return false;
    if (!ui.target)
        return true;
    NV2AMetalDisplayUniforms u =
        ui.frame ? ui.frame.displayUniforms : NV2AMetalDisplayUniforms{};
    u.scale[0] = sx;
    u.scale[1] = sy;
    NV2AMetalDisplay *display = ui.displayPipelines[@(ui.target.pixelFormat)];
    return [display encodeWithCommands:ui.commands
                                source:ui.frame.texture
                                target:ui.target
                              uniforms:&u
                                linear:linear
                             screenOff:!ui.frame || ui.frame.screenOff
                                 error:&error];
}
static uintptr_t make_texture(const void *rgba, uint32_t w, uint32_t h)
{
    if (!ready() || !w || !h || w > 16384 || h > 16384)
        return 0;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    td.storageMode = rgba ? MTLStorageModeShared : MTLStorageModePrivate;
    td.usage =
        MTLTextureUsageShaderRead | (rgba ? 0 : MTLTextureUsageRenderTarget);
    id<MTLTexture> result = [ui.commands.device newTextureWithDescriptor:td];
    if (!result) {
        fail(@"Cannot allocate a native UI texture");
        return 0;
    }
    if (rgba)
        [result replaceRegion:MTLRegionMake2D(0, 0, w, h)
                  mipmapLevel:0
                    withBytes:rgba
                  bytesPerRow:NSUInteger(w) * 4];
    return (uintptr_t)(__bridge_retained void *)result;
}
uintptr_t xemu_metal4_ui_texture(const void *rgba, uint32_t w, uint32_t h)
{
    return rgba ? make_texture(rgba, w, h) : 0;
}
uintptr_t xemu_metal4_ui_target(uint32_t w, uint32_t h)
{
    return make_texture(nullptr, w, h);
}
void xemu_metal4_ui_release_texture(uintptr_t handle)
{
    id released = (__bridge_transfer id)(void *)handle;
    (void)released;
}
bool xemu_metal4_ui_texture_size(uintptr_t handle, uint32_t *w, uint32_t *h)
{
    if (!ready() || !handle || !w || !h)
        return false;
    *w = uint32_t(texture(handle).width);
    *h = uint32_t(texture(handle).height);
    return true;
}
bool xemu_metal4_ui_push_target(uintptr_t handle)
{
    if (!ready() || !ui.active || !handle || !flush_decals())
        return false;
    id<MTLTexture> target = texture(handle);
    if (target.device != ui.commands.device ||
        target.textureType != MTLTextureType2D || target.sampleCount != 1 ||
        !(target.usage & MTLTextureUsageRenderTarget) ||
        !ui.decalPipelines[@(target.pixelFormat)])
        return fail(@"Invalid nested Metal UI target");
    if (!clear_target(target))
        return false;
    [ui.targets addObject:(id)ui.target ?: (id)[NSNull null]];
    ui.target = target;
    return true;
}
bool xemu_metal4_ui_pop_target(void)
{
    if (!ready() || !ui.active || !ui.targets.count || !flush_decals())
        return false;
    id previous = ui.targets.lastObject;
    ui.target = previous == [NSNull null] ? nil : previous;
    [ui.targets removeLastObject];
    return true;
}
bool xemu_metal4_ui_decal(uintptr_t handle, const float dst[4],
                          const float src[4], uint32_t primary,
                          uint32_t secondary, uint32_t fill, float time,
                          bool flip, unsigned shader, unsigned blend)
{
    if (!ready() || !ui.active || !handle || !dst || !src || !ui.target ||
        shader > 2 || blend > 2 || !std::isfinite(time))
        return false;
    XemuMetal4Decal *d = [XemuMetal4Decal new];
    d.texture = texture(handle);
    d.destination = CGRectMake(dst[0], dst[1], dst[2], dst[3]);
    d.source = CGRectMake(src[0], src[1], src[2], src[3]);
    d.primary = primary;
    d.secondary = secondary;
    d.fill = fill;
    d.time = time;
    d.flipY = flip;
    d.shader =
        shader == 2 ? XemuMetal4DecalShaderLogo : (XemuMetal4DecalShader)shader;
    d.framebufferRows = shader == 2;
    d.blend = (XemuMetal4DecalBlend)blend;
    [ui.decals addObject:d];
    return true;
}
