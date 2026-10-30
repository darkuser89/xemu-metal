/*
 * Native masked clear from gl/draw.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */
#import "clear.h"
#import "lru-cache.h"
#include "clear-source.h"
#include <math.h>
#include "color-format.h"

_Static_assert(sizeof(NV2AMetalClearUniforms) == 40, "CPU/MSL clear uniforms");

static BOOL clear_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.clear"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}
static NSUInteger clear_min(NSUInteger a, NSUInteger b)
{
    return a < b ? a : b;
}
static BOOL color_format(MTLPixelFormat f)
{
    return f == MTLPixelFormatR8Unorm || f == MTLPixelFormatRG8Unorm ||
           f == MTLPixelFormatRGBA8Unorm || f == MTLPixelFormatBGRA8Unorm ||
           f == MTLPixelFormatB5G6R5Unorm || f == MTLPixelFormatBGR5A1Unorm ||
           f == MTLPixelFormatRGBA32Float;
}
static BOOL valid_texture(id<MTLTexture> t, id<MTLDevice> d)
{
    return t.device == d && t.width && t.height &&
           (t.usage & MTLTextureUsageRenderTarget) &&
           (t.textureType == MTLTextureType2D ||
            t.textureType == MTLTextureType2DMultisample);
}

@implementation NV2AMetalClear {
    id<MTLDevice> _device;
    id<MTL4Compiler> _compiler;
    id<MTLLibrary> _library;
    id<MTL4ArgumentTable> _arguments;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_bases;
    NV2AMetalLRUCache<NSNumber *, id<MTLRenderPipelineState>> *_pipelines;
    id<MTLDepthStencilState> _states[2][2];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4]) {
        clear_error(error, @"Native clear requires Apple Silicon Metal 4");
        return nil;
    }
    _device = device;
    _compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                            error:error];
    if (!_compiler) {
        return nil;
    }
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = @(metal_shader_source);
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    _library = [_compiler newLibraryWithDescriptor:ld error:error];
    if (!_library) {
        return nil;
    }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:ad error:error];
    if (!_arguments) {
        return nil;
    }
    _bases = [NSMutableDictionary new];
    _pipelines = [[NV2AMetalLRUCache alloc] initWithCapacity:256];
    for (unsigned z = 0; z < 2; z++) {
        for (unsigned s = 0; s < 2; s++) {
            MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
            ds.depthCompareFunction = MTLCompareFunctionAlways;
            ds.depthWriteEnabled = z;
            if (s) {
                MTLStencilDescriptor *st = [MTLStencilDescriptor new];
                st.stencilCompareFunction = MTLCompareFunctionAlways;
                st.depthStencilPassOperation = MTLStencilOperationReplace;
                st.readMask = st.writeMask = 255;
                ds.frontFaceStencil = ds.backFaceStencil = st;
            }
            _states[z][s] = [device newDepthStencilStateWithDescriptor:ds];
            if (!_states[z][s]) {
                clear_error(
                    error, @"Cannot allocate native clear depth/stencil state");
                return nil;
            }
        }
    }
    return self;
}

- (id<MTLRenderPipelineState>)pipeline:(MTLPixelFormat)format
                               samples:(NSUInteger)samples
                                  mask:(MTLColorWriteMask)mask
                                 error:(NSError **)error
{
    NSNumber *base_key = @(((NSUInteger)format << 8) | samples);
    NSNumber *key = @((base_key.unsignedIntegerValue << 4) | mask);
    id<MTLRenderPipelineState> pipeline = _pipelines[key];
    if (pipeline) {
        return pipeline;
    }
    id<MTLRenderPipelineState> base = _bases[base_key];
    if (!base) {
        MTL4LibraryFunctionDescriptor *v = [MTL4LibraryFunctionDescriptor new];
        v.library = _library;
        v.name = @"nv2a_clear_vertex";
        MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new];
        f.library = _library;
        f.name = format == MTLPixelFormatInvalid ? @"nv2a_clear_depth" :
                                                   @"nv2a_clear_color";
        MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
        pd.vertexFunctionDescriptor = v;
        pd.fragmentFunctionDescriptor = f;
        pd.rasterSampleCount = samples;
        pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
        pd.colorAttachments[0].pixelFormat = format;
        pd.colorAttachments[0].writeMask = MTLColorWriteMaskUnspecialized;
        pd.colorAttachments[0].blendingState = MTL4BlendStateDisabled;
        base = [_compiler newRenderPipelineStateWithDescriptor:pd
                                           compilerTaskOptions:nil
                                                         error:error];
        if (!base) {
            return nil;
        }
        _bases[base_key] = base;
    }
    MTL4RenderPipelineDescriptor *pd = (MTL4RenderPipelineDescriptor *)
        [base newRenderPipelineDescriptorForSpecialization];
    pd.rasterSampleCount = samples;
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    pd.colorAttachments[0].pixelFormat = format;
    pd.colorAttachments[0].writeMask = mask;
    pipeline =
        [_compiler newRenderPipelineStateBySpecializationWithDescriptor:pd
                                                               pipeline:base
                                                                  error:error];
    if (pipeline) {
        _pipelines[key] = pipeline;
    }
    return pipeline;
}

- (BOOL)encodeColor:(id<MTLTexture>)color
               zeta:(id<MTLTexture>)zeta
             config:(const NV2AMetalClearConfig *)c
           commands:(NV2AMetalCommands *)commands
              error:(NSError **)error
{
    if (!c) {
        return clear_error(error, @"Missing native clear configuration");
    }
    unsigned flags = c->parameter;
    BOOL write_color = !!(flags & NV097_CLEAR_SURFACE_COLOR);
    BOOL write_depth = !!(flags & NV097_CLEAR_SURFACE_Z);
    BOOL write_stencil = !!(flags & NV097_CLEAR_SURFACE_STENCIL);
    if (!write_color && !write_depth && !write_stencil) {
        return YES;
    }
    if (commands.device != _device || !commands.commandBuffer ||
        (write_color && !color) || ((write_depth || write_stencil) && !zeta) ||
        (color && (!valid_texture(color, _device) ||
                   !color_format(color.pixelFormat))) ||
        (zeta && (!valid_texture(zeta, _device) ||
                  (zeta.pixelFormat != MTLPixelFormatDepth16Unorm &&
                   zeta.pixelFormat != MTLPixelFormatDepth32Float &&
                   zeta.pixelFormat != MTLPixelFormatDepth32Float_Stencil8))) ||
        (color && zeta &&
         (color.width != zeta.width || color.height != zeta.height ||
          color.sampleCount != zeta.sampleCount))) {
        return clear_error(error, @"Invalid native clear attachments/context");
    }
    id<MTLTexture> target = color ? color : zeta;
    if (![_device supportsTextureSampleCount:target.sampleCount] ||
        (write_depth && !isfinite(c->uniforms.depth))) {
        return clear_error(error, @"Invalid native clear sample/depth value");
    }
    if (write_color) {
        for (unsigned i = 0; i < 4; i++) {
            if (!isfinite(c->uniforms.color[i])) {
                return clear_error(error, @"Invalid native clear color value");
            }
        }
    }
    write_stencil &= zeta.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    if (!write_color && !write_depth && !write_stencil) {
        return YES;
    }
    MTLScissorRect rect = c->rect;
    rect.x = clear_min(rect.x, target.width);
    rect.y = clear_min(rect.y, target.height);
    rect.width = clear_min(rect.width, target.width - rect.x);
    rect.height = clear_min(rect.height, target.height - rect.y);
    if (!rect.width || !rect.height) {
        return YES;
    }
    MTLColorWriteMask mask = MTLColorWriteMaskNone;
    if (flags & NV097_CLEAR_SURFACE_R)
        mask |= MTLColorWriteMaskRed;
    if (flags & NV097_CLEAR_SURFACE_G)
        mask |= MTLColorWriteMaskGreen;
    if (flags & NV097_CLEAR_SURFACE_B)
        mask |= MTLColorWriteMaskBlue;
    if (flags & NV097_CLEAR_SURFACE_A)
        mask |= MTLColorWriteMaskAlpha;
    id<MTLRenderPipelineState> pipeline =
        [self pipeline:color ? color.pixelFormat : MTLPixelFormatInvalid
               samples:target.sampleCount
                  mask:mask
                 error:error];
    if (!pipeline) {
        return NO;
    }
    NV2AMetalClearUniforms u = c->uniforms;
    u.dither = c->dither;
    nv2a_metal_color_bits(color.pixelFormat, u.color_bits);
    if (!write_color)
        memset(u.color, 0, sizeof(u.color));
    if (!write_depth)
        u.depth = 0;
    NSUInteger uniformOffset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&u
                                             length:sizeof(u)
                                             offset:&uniformOffset
                                              error:error];
    id<MTLDepthStencilState> ds = _states[write_depth][write_stencil];
    if (!constants)
        return NO;
    if ((color && ![commands addResource:color error:error]) ||
        (zeta && ![commands addResource:zeta error:error]) ||
        ![commands keepAlive:self error:error] ||
        ![commands keepAlive:pipeline error:error]) {
        return clear_error(error, @"Cannot retain native clear resources");
    }
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    if (color) {
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    if (zeta) {
        pass.depthAttachment.texture = zeta;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        if (zeta.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            pass.stencilAttachment.texture = zeta;
            pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    }
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!e) {
        return clear_error(error, @"Cannot create native clear encoder");
    }
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setRenderPipelineState:pipeline];
    [e setDepthStencilState:ds];
    [e setStencilReferenceValue:c->stencil & 255];
    [e setCullMode:MTLCullModeNone];
    [e setViewport:(MTLViewport){ 0, 0, target.width, target.height, 0, 1 }];
    [e setScissorRect:rect];
    [_arguments setAddress:constants.gpuAddress + uniformOffset atIndex:0];
    [e setArgumentTable:_arguments atStages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return YES;
}
@end
