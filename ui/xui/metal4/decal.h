/*
 * Native Metal 4 rendering for xemu's controller, XMU and logo decals
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef XEMU_UI_METAL4_DECAL_H
#define XEMU_UI_METAL4_DECAL_H

#import "hw/xbox/nv2a/pgraph/metal/command.h"
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, XemuMetal4DecalShader) {
    XemuMetal4DecalShaderMask,
    XemuMetal4DecalShaderLogo,
};

typedef NS_ENUM(NSUInteger, XemuMetal4DecalBlend) {
    XemuMetal4DecalBlendReplace,
    XemuMetal4DecalBlendAlpha,
    XemuMetal4DecalBlendCutout,
};

/* Rectangles use top-left pixel coordinates. Colors use the existing UI's
 * 0xRRGGBBAA packing. The texture's row zero is at the top; flipY flips only
 * the selected source rectangle. Values are copied when encoding the draw. */
API_AVAILABLE(macos(26.0))
@interface XemuMetal4Decal : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) CGRect destination;
@property(nonatomic) CGRect source;
@property(nonatomic) uint32_t primary;
@property(nonatomic) uint32_t secondary;
@property(nonatomic) uint32_t fill;
@property(nonatomic) float time;
@property(nonatomic) BOOL flipY;
/* Match GL FBO memory rows for ImGui consumers that invert their UVs: stored
 * row zero corresponds to gl_FragCoord.y=0, rather than the display's top. */
@property(nonatomic) BOOL framebufferRows;
@property(nonatomic) XemuMetal4DecalShader shader;
@property(nonatomic) XemuMetal4DecalBlend blend;
@end

API_AVAILABLE(macos(26.0))
@interface XemuMetal4Decals : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Single-sample 2D unorm RGBA8/BGRA8 source and target textures. A clear sets
 * transparent black; otherwise the existing target contents are loaded.
 * Begin commands first. This method ends its own render encoder. */
- (BOOL)encodeDecals:(NSArray<XemuMetal4Decal *> *)decals
            commands:(NV2AMetalCommands *)commands
              target:(id<MTLTexture>)target
               clear:(BOOL)clear
               error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END

#endif
