/*
 * NV2A Metal 4 framebuffer display
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "display.h"
#import "shader-library.h"
#include "texture-alias.h"
#include "display-source.h"
#include <stddef.h>
#include <math.h>

_Static_assert(sizeof(unsigned int) == 4, "MSL uint must match C unsigned int");
_Static_assert(offsetof(NV2AMetalDisplayUniforms, palette) == 16,
               "Display palette offset must match MSL");
_Static_assert(sizeof(NV2AMetalDisplayUniforms) == 1040,
               "Display uniforms size must match MSL");

static BOOL display_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.display"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

@implementation NV2AMetalDisplay {
    id<MTLDevice> _device;
    MTLPixelFormat _pixelFormat;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLSamplerState> _nearest;
    id<MTLSamplerState> _linear;
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
    _device = device;
    _pixelFormat = pixelFormat;
    if (![_device supportsFamily:MTLGPUFamilyApple7] ||
        ![_device supportsFamily:MTLGPUFamilyMetal4] ||
        !_device.hasUnifiedMemory) {
        display_error(error, @"Metal 4 display requires Apple Silicon");
        return nil;
    }
    /* DAC palette values already encode gamma. An sRGB render target would
     * apply a second transfer function and change the displayed colors. */
    if (pixelFormat != MTLPixelFormatBGRA8Unorm &&
        pixelFormat != MTLPixelFormatRGBA8Unorm) {
        display_error(error, @"Metal display requires an unorm RGBA8 target");
        return nil;
    }

    return self;
}

- (BOOL)prepareDisplayWithError:(NSError **)error
{
    if (_pipeline)
        return YES;
    id<MTLRenderPipelineState> pipeline;
    /* PNG captures create a new display for each image. Retain only the
     * current device's immutable library and two supported target pipelines;
     * each display still owns its mutable argument table. */
    static NV2AMetalShaderLibrary *cachedModule;
    static id<MTLRenderPipelineState> cachedBGRA, cachedRGBA;
    @synchronized(NV2AMetalDisplay.class) {
        BOOL sameDevice = cachedModule.library.device == _device;
        pipeline = sameDevice ? (_pixelFormat == MTLPixelFormatBGRA8Unorm ?
                                     cachedBGRA : cachedRGBA) :
                                nil;
        if (!pipeline) {
            NV2AMetalShaderLibrary *module =
                sameDevice ? cachedModule :
                             [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                                source:metal_shader_source
                                                                 error:error];
            if (!module)
                return NO;
            MTL4LibraryFunctionDescriptor *vertex =
                [MTL4LibraryFunctionDescriptor new];
            vertex.library = module.library;
            vertex.name = @"nv2a_display_vertex";
            MTL4LibraryFunctionDescriptor *fragment =
                [MTL4LibraryFunctionDescriptor new];
            fragment.library = module.library;
            fragment.name = @"nv2a_display_fragment";
            MTL4RenderPipelineDescriptor *descriptor =
                [MTL4RenderPipelineDescriptor new];
            descriptor.label = @"NV2A framebuffer gamma and scaling";
            descriptor.vertexFunctionDescriptor = vertex;
            descriptor.fragmentFunctionDescriptor = fragment;
            descriptor.colorAttachments[0].pixelFormat = _pixelFormat;
            descriptor.inputPrimitiveTopology =
                MTLPrimitiveTopologyClassTriangle;
            @synchronized(module.compiler) {
                pipeline = [module.compiler
                    newRenderPipelineStateWithDescriptor:descriptor
                                     compilerTaskOptions:nil
                                                   error:error];
            }
            if (!pipeline)
                return NO;
            if (!sameDevice) {
                cachedBGRA = nil;
                cachedRGBA = nil;
                cachedModule = module;
            }
            if (_pixelFormat == MTLPixelFormatBGRA8Unorm)
                cachedBGRA = pipeline;
            else
                cachedRGBA = pipeline;
        }
    }

    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.supportArgumentBuffers = YES;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.minFilter = MTLSamplerMinMagFilterNearest;
    sampler.magFilter = MTLSamplerMinMagFilterNearest;
    id<MTLSamplerState> nearest = [_device newSamplerStateWithDescriptor:sampler];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    id<MTLSamplerState> linear = [_device newSamplerStateWithDescriptor:sampler];
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 1;
    arguments.maxTextureBindCount = 1;
    arguments.maxSamplerStateBindCount = 1;
    arguments.initializeBindings = YES;
    id<MTL4ArgumentTable> table =
        [_device newArgumentTableWithDescriptor:arguments error:error];
    if (!nearest || !linear || !table)
        return display_error(error, @"Could not allocate Metal display bindings");
    _nearest = nearest;
    _linear = linear;
    _arguments = table;
    _pipeline = pipeline;
    return YES;
}

- (BOOL)encodeWithCommands:(NV2AMetalCommands *)commands
                    source:(nullable id<MTLTexture>)source
                    target:(id<MTLTexture>)target
                  uniforms:(const NV2AMetalDisplayUniforms *)uniforms
                    linear:(BOOL)linear
                 screenOff:(BOOL)screenOff
                     error:(NSError **)error
{
    id<MTL4CommandBuffer> commandBuffer = commands.commandBuffer;
    if (!commandBuffer) {
        return display_error(error, @"No Metal 4 command buffer is recording");
    }
    if (!uniforms || !isfinite(uniforms->scale[0]) ||
        !isfinite(uniforms->scale[1]) || uniforms->scale[0] <= 0 ||
        uniforms->scale[1] <= 0) {
        return display_error(error, @"Invalid Metal display scaling");
    }
    if (commands.device != _device || target.device != _device ||
        target.pixelFormat != _pixelFormat || target.sampleCount != 1 ||
        target.textureType != MTLTextureType2D ||
        !(target.usage & MTLTextureUsageRenderTarget) ||
        nv2a_metal_textures_alias(source, target)) {
        return display_error(error, @"Invalid Metal display target");
    }
    if (!screenOff &&
        (!source || source.device != _device ||
         source.textureType != MTLTextureType2D || source.sampleCount != 1 ||
         !(source.usage & MTLTextureUsageShaderRead) ||
         (source.pixelFormat != MTLPixelFormatBGRA8Unorm &&
          source.pixelFormat != MTLPixelFormatRGBA8Unorm &&
          source.pixelFormat != MTLPixelFormatR8Unorm &&
          source.pixelFormat != MTLPixelFormatRG8Unorm &&
          source.pixelFormat != MTLPixelFormatB5G6R5Unorm &&
          source.pixelFormat != MTLPixelFormatBGR5A1Unorm &&
          source.pixelFormat != MTLPixelFormatRGBA32Float))) {
        return display_error(error, @"Invalid Metal display source");
    }
    if (!screenOff && ![self prepareDisplayWithError:error])
        return NO;
    if (![commands addResource:target error:error] ||
        ![commands keepAlive:self error:error]) {
        return NO;
    }

    if (!screenOff) {
        NV2AMetalDisplayUniforms captured = *uniforms;
        captured.reserved = source.pixelFormat == MTLPixelFormatRGBA32Float ?
                                (linear ? 2 : 1) :
                                0;
        NSUInteger offset;
        id<MTLBuffer> constants = [commands uploadBytes:&captured
                                                 length:sizeof(captured)
                                                 offset:&offset
                                                  error:error];
        if (!constants || ![commands addResource:source error:error]) {
            return NO;
        }
        [_arguments setAddress:constants.gpuAddress + offset atIndex:0];
        [_arguments setTexture:source.gpuResourceID atIndex:0];
        [_arguments setSamplerState:(linear ? _linear : _nearest).gpuResourceID
                            atIndex:0];
    }

    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTL4RenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        return display_error(error, @"Could not create Metal display encoder");
    }
    /* Vertices read only this call's immutable CPU snapshot. GPU-produced
     * textures and attachment actions belong to the fragment stage, including
     * a clear-only pass that issues no draw. */
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageFragment
                   visibilityOptions:MTL4VisibilityOptionDevice];
    if (!screenOff) {
        [encoder setRenderPipelineState:_pipeline];
        [encoder setViewport:(MTLViewport){ 0, 0, target.width, target.height,
                                            0, 1 }];
        [encoder setCullMode:MTLCullModeNone];
        [encoder
            setArgumentTable:_arguments
                    atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
    }
    [encoder barrierAfterStages:MTLStageFragment
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return YES;
}

@end
