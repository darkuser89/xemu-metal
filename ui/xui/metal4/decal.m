/*
 * Native Metal 4 rendering for xemu's controller, XMU and logo decals
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#import "decal.h"
#include "hw/xbox/nv2a/pgraph/metal/texture-alias.h"
#include "decal-uniforms.h"
#include "decal-source.h"
#include <limits.h>
#include <math.h>
#include <stddef.h>

_Static_assert(sizeof(XemuMetal4DecalUniforms) == 96,
               "Decal uniforms must match their scalar MSL layout");
_Static_assert(offsetof(XemuMetal4DecalUniforms, time) == 84,
               "Decal time offset must match MSL");

static BOOL decal_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.ui.metal4.decal"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

static BOOL valid_rect(CGRect rect)
{
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
           isfinite(rect.size.width) && isfinite(rect.size.height) &&
           fabs(rect.origin.x) <= INT_MAX && fabs(rect.origin.y) <= INT_MAX &&
           rect.size.width >= 0 && rect.size.height >= 0 &&
           rect.size.width <= INT_MAX && rect.size.height <= INT_MAX;
}

static void unpack_color(uint32_t color, float *values)
{
    for (unsigned i = 0; i < 4; i++) {
        values[i] = ((color >> (24 - 8 * i)) & 255) / 255.0f;
    }
}

@implementation XemuMetal4Decal
@end

@implementation XemuMetal4Decals {
    id<MTLDevice> _device;
    MTLPixelFormat _pixelFormat;
    id<MTLRenderPipelineState> _pipelines[2][3];
    id<MTLSamplerState> _sampler;
    id<MTL4ArgumentTable> _arguments;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4] ||
        !device.hasUnifiedMemory) {
        decal_error(error, @"Metal 4 decals require Apple Silicon");
        return nil;
    }
    if (pixelFormat != MTLPixelFormatRGBA8Unorm &&
        pixelFormat != MTLPixelFormatBGRA8Unorm) {
        decal_error(error, @"Metal decals require an unorm RGBA8 target");
        return nil;
    }
    _device = device;
    _pixelFormat = pixelFormat;
    MTL4CompilerDescriptor *compilerDescriptor = [MTL4CompilerDescriptor new];
    compilerDescriptor.label = @"xemu decal compiler";
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:compilerDescriptor error:error];
    if (!compiler) {
        return nil;
    }
    MTL4LibraryDescriptor *libraryDescriptor = [MTL4LibraryDescriptor new];
    libraryDescriptor.source = @(metal_shader_source);
    libraryDescriptor.options = [MTLCompileOptions new];
    libraryDescriptor.options.languageVersion = MTLLanguageVersion4_0;
    libraryDescriptor.options.mathMode = MTLMathModeSafe;
    id<MTLLibrary> library =
        [compiler newLibraryWithDescriptor:libraryDescriptor error:error];
    if (!library) {
        return nil;
    }
    MTL4LibraryFunctionDescriptor *vertex = [MTL4LibraryFunctionDescriptor new];
    vertex.library = library;
    vertex.name = @"xemu_decal_vertex";
    NSArray<NSString *> *fragments =
        @[ @"xemu_decal_mask", @"xemu_decal_logo" ];
    for (NSUInteger shader = 0; shader < 2; shader++) {
        MTL4LibraryFunctionDescriptor *fragment =
            [MTL4LibraryFunctionDescriptor new];
        fragment.library = library;
        fragment.name = fragments[shader];
        for (NSUInteger blend = 0; blend < 3; blend++) {
            MTL4RenderPipelineDescriptor *descriptor =
                [MTL4RenderPipelineDescriptor new];
            descriptor.label = @"xemu custom UI decal";
            descriptor.vertexFunctionDescriptor = vertex;
            descriptor.fragmentFunctionDescriptor = fragment;
            descriptor.inputPrimitiveTopology =
                MTLPrimitiveTopologyClassTriangle;
            MTL4RenderPipelineColorAttachmentDescriptor *color =
                descriptor.colorAttachments[0];
            color.pixelFormat = pixelFormat;
            if (blend == XemuMetal4DecalBlendAlpha) {
                color.blendingState = MTL4BlendStateEnabled;
                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                color.destinationRGBBlendFactor =
                    MTLBlendFactorOneMinusSourceAlpha;
                /* Match custom UI glBlendFunc, including its alpha equation. */
                color.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                color.destinationAlphaBlendFactor =
                    MTLBlendFactorOneMinusSourceAlpha;
            } else if (blend == XemuMetal4DecalBlendCutout) {
                color.blendingState = MTL4BlendStateEnabled;
                color.sourceRGBBlendFactor =
                    MTLBlendFactorOneMinusDestinationAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                color.sourceAlphaBlendFactor =
                    MTLBlendFactorOneMinusDestinationAlpha;
                color.destinationAlphaBlendFactor = MTLBlendFactorOne;
            }
            _pipelines[shader][blend] =
                [compiler newRenderPipelineStateWithDescriptor:descriptor
                                           compilerTaskOptions:nil
                                                         error:error];
            if (!_pipelines[shader][blend]) {
                return nil;
            }
        }
    }
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.supportArgumentBuffers = YES;
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToBorderColor;
    sampler.tAddressMode = MTLSamplerAddressModeClampToBorderColor;
    sampler.borderColor = MTLSamplerBorderColorTransparentBlack;
    _sampler = [device newSamplerStateWithDescriptor:sampler];
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 1;
    arguments.maxTextureBindCount = 1;
    arguments.maxSamplerStateBindCount = 1;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    if (!_sampler || !_arguments) {
        decal_error(error, @"Could not allocate decal bindings");
        return nil;
    }
    return self;
}

- (BOOL)encodeDecals:(NSArray<XemuMetal4Decal *> *)decals
            commands:(NV2AMetalCommands *)commands
              target:(id<MTLTexture>)target
               clear:(BOOL)clear
               error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device ||
        target.device != _device || target.pixelFormat != _pixelFormat ||
        target.sampleCount != 1 || target.textureType != MTLTextureType2D ||
        !(target.usage & MTLTextureUsageRenderTarget)) {
        return decal_error(error, @"Invalid Metal decal target or recording");
    }
    if (!clear && !decals.count) {
        return YES;
    }
    if (![commands addResource:target error:error] ||
        ![commands keepAlive:self error:error]) {
        return NO;
    }
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction =
        clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        return decal_error(error, @"Could not create decal render encoder");
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageVertex | MTLStageFragment
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder
        setViewport:(MTLViewport){ 0, 0, target.width, target.height, 0, 1 }];
    [encoder setCullMode:MTLCullModeNone];
    [_arguments setSamplerState:_sampler.gpuResourceID atIndex:0];
    BOOL success = YES;
    for (XemuMetal4Decal *decal in decals) {
        id<MTLTexture> texture = decal.texture;
        if (!texture || nv2a_metal_textures_alias(texture, target) ||
            texture.device != _device ||
            texture.textureType != MTLTextureType2D ||
            texture.sampleCount != 1 ||
            !(texture.usage & MTLTextureUsageShaderRead) ||
            (texture.pixelFormat != MTLPixelFormatRGBA8Unorm &&
             texture.pixelFormat != MTLPixelFormatBGRA8Unorm) ||
            decal.shader > XemuMetal4DecalShaderLogo ||
            decal.blend > XemuMetal4DecalBlendCutout ||
            !valid_rect(decal.destination) || !valid_rect(decal.source) ||
            !isfinite(decal.time)) {
            success = decal_error(error,
                                  @"Invalid Metal decal texture or parameters");
            break;
        }
        /* RenderDecal truncates all eight pixel coordinates before drawing. */
        float x = trunc(decal.destination.origin.x),
              y = trunc(decal.destination.origin.y);
        float w = trunc(decal.destination.size.width),
              h = trunc(decal.destination.size.height);
        if (!w || !h) {
            continue;
        }
        XemuMetal4DecalUniforms u = {
            .position = { w / target.width, h / target.height,
                          -1.0f + (2.0f * x + w) / target.width,
                          1.0f - (2.0f * y + h) / target.height },
            .texture = { truncf(decal.source.size.width) / texture.width,
                         truncf(decal.source.size.height) / texture.height,
                         truncf(decal.source.origin.x) / texture.width,
                         truncf(decal.source.origin.y) / texture.height },
            .target_height = target.height,
            .time = decal.time,
            .flip_y = decal.flipY,
            .reserved = decal.framebufferRows,
        };
        unpack_color(decal.primary, u.primary);
        unpack_color(decal.secondary, u.secondary);
        unpack_color(decal.fill, u.fill);
        id<MTLBuffer> constants =
            [_device newBufferWithBytes:&u
                                 length:sizeof(u)
                                options:MTLResourceStorageModeShared];
        if (!constants) {
            success = decal_error(error, @"Could not allocate decal uniforms");
            break;
        }
        if (![commands addResource:texture error:error] ||
            ![commands addResource:constants error:error]) {
            success = NO;
            break;
        }
        [_arguments setAddress:constants.gpuAddress atIndex:0];
        [_arguments setTexture:texture.gpuResourceID atIndex:0];
        [encoder setRenderPipelineState:_pipelines[decal.shader][decal.blend]];
        [encoder
            setArgumentTable:_arguments
                    atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
    }
    [encoder barrierAfterStages:MTLStageVertex | MTLStageFragment
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return success;
}

@end
