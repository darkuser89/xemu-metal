/*
 * Native masked clear from gl/draw.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */
#import "clear.h"
#import "lru-cache.h"
#import "shader-library.h"
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

static BOOL exact_unorm_color(MTLPixelFormat format, const float color[4])
{
    unsigned bits[4];
    nv2a_metal_color_bits(format, bits);
    if (!bits[0])
        return NO;
    for (unsigned i = 0; i < 4 && bits[i]; i++) {
        float maximum = (1u << bits[i]) - 1;
        if (color[i] < 0 || color[i] > 1 ||
            color[i] != roundf(color[i] * maximum) / maximum)
            return NO;
    }
    return YES;
}

BOOL nv2a_metal_clear_layout_uses_load_actions(
    const NV2AMetalClearAttachmentLayout *color,
    const NV2AMetalClearAttachmentLayout *zeta, const NV2AMetalClearConfig *c)
{
    const NV2AMetalClearAttachmentLayout *target = color ?: zeta;
    unsigned mask = c->parameter & NV097_CLEAR_SURFACE_COLOR;
    /* D16 load actions can truncate interior values, including normalized
     * guest depth codes. Keep those on the shader path. */
    BOOL exactDepth =
        !(c->parameter & NV097_CLEAR_SURFACE_Z) ||
        (!zeta || zeta->pixel_format != MTLPixelFormatDepth16Unorm) ||
        c->uniforms.depth <= 0 || c->uniforms.depth >= 1;
    return target && !c->rect.x && !c->rect.y &&
           c->rect.width >= target->width && c->rect.height >= target->height &&
           exactDepth &&
           (!mask || (mask == NV097_CLEAR_SURFACE_COLOR && !c->dither &&
                      exact_unorm_color(color ? color->pixel_format :
                                                MTLPixelFormatInvalid,
                                        c->uniforms.color)));
}

BOOL nv2a_metal_clear_uses_load_actions(id<MTLTexture> color,
                                        id<MTLTexture> zeta,
                                        const NV2AMetalClearConfig *c)
{
    NV2AMetalClearAttachmentLayout colorLayout = { color.pixelFormat,
                                                   color.width, color.height },
                                   zetaLayout = { zeta.pixelFormat, zeta.width,
                                                  zeta.height };
    return nv2a_metal_clear_layout_uses_load_actions(
        color ? &colorLayout : NULL, zeta ? &zetaLayout : NULL, c);
}

@implementation NV2AMetalClear {
    id<MTLDevice> _device;
    NV2AMetalShaderLibrary *_module;
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
    _bases = [NSMutableDictionary new];
    _pipelines = [[NV2AMetalLRUCache alloc] initWithCapacity:256];
    return self;
}

- (BOOL)prepareShaderWithError:(NSError **)error
{
    if (_module)
        return YES;
    NV2AMetalShaderLibrary *module =
        [NV2AMetalShaderLibrary sharedWithDevice:_device
                                         source:metal_shader_source
                                          error:error];
    if (!module)
        return NO;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [_device newArgumentTableWithDescriptor:ad error:error];
    if (!arguments)
        return NO;
    id<MTLDepthStencilState> states[2][2];
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
            states[z][s] = [_device newDepthStencilStateWithDescriptor:ds];
            if (!states[z][s]) {
                return clear_error(
                    error, @"Cannot allocate native clear depth/stencil state");
            }
        }
    }
    for (unsigned z = 0; z < 2; z++)
        for (unsigned s = 0; s < 2; s++)
            _states[z][s] = states[z][s];
    _arguments = arguments;
    _module = module;
    return YES;
}

- (id<MTLRenderPipelineState>)pipeline:(MTLPixelFormat)format
                               samples:(NSUInteger)samples
                                  mask:(MTLColorWriteMask)mask
                                 error:(NSError **)error
{
    if (![self prepareShaderWithError:error])
        return nil;
    NSNumber *base_key = @(((NSUInteger)format << 8) | samples);
    NSNumber *key = @((base_key.unsignedIntegerValue << 4) | mask);
    id<MTLRenderPipelineState> pipeline = _pipelines[key];
    if (pipeline) {
        return pipeline;
    }
    id<MTLRenderPipelineState> base = _bases[base_key];
    if (!base) {
        MTL4LibraryFunctionDescriptor *v = [MTL4LibraryFunctionDescriptor new];
        v.library = _module.library;
        v.name = @"nv2a_clear_vertex";
        MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new];
        f.library = _module.library;
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
        @synchronized(_module.compiler) {
            base = [_module.compiler newRenderPipelineStateWithDescriptor:pd
                                                      compilerTaskOptions:nil
                                                                    error:error];
        }
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
    @synchronized(_module.compiler) {
        pipeline = [_module.compiler
            newRenderPipelineStateBySpecializationWithDescriptor:pd
                                                       pipeline:base
                                                          error:error];
    }
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
    if ((color && ![commands addResource:color error:error]) ||
        (zeta && ![commands addResource:zeta error:error])) {
        return clear_error(error, @"Cannot retain native clear resources");
    }
    BOOL loadClear = nv2a_metal_clear_uses_load_actions(color, zeta, c);
    id<MTLRenderPipelineState> pipeline = nil;
    id<MTLBuffer> constants = nil;
    NSUInteger uniformOffset = 0;
    if (!loadClear) {
        pipeline =
            [self pipeline:color ? color.pixelFormat : MTLPixelFormatInvalid
                   samples:target.sampleCount
                      mask:mask
                     error:error];
        if (!pipeline)
            return NO;
        NV2AMetalClearUniforms u = c->uniforms;
        u.dither = c->dither;
        nv2a_metal_color_bits(color.pixelFormat, u.color_bits);
        if (!write_color)
            memset(u.color, 0, sizeof(u.color));
        if (!write_depth)
            u.depth = 0;
        constants = [commands uploadBytes:&u
                                   length:sizeof(u)
                                   offset:&uniformOffset
                                    error:error];
        if (!constants || ![commands keepAlive:self error:error] ||
            ![commands keepAlive:pipeline error:error])
            return NO;
    }
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    if (color) {
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].loadAction =
            loadClear && write_color ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (loadClear && write_color) {
            const float *rgba = c->uniforms.color;
            pass.colorAttachments[0].clearColor =
                MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
        }
    }
    if (zeta) {
        pass.depthAttachment.texture = zeta;
        pass.depthAttachment.loadAction =
            loadClear && write_depth ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        if (loadClear && write_depth)
            pass.depthAttachment.clearDepth =
                fminf(1.0f, fmaxf(0.0f, c->uniforms.depth));
        if (zeta.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            pass.stencilAttachment.texture = zeta;
            pass.stencilAttachment.loadAction = loadClear && write_stencil ?
                                                    MTLLoadActionClear :
                                                    MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            if (loadClear && write_stencil)
                pass.stencilAttachment.clearStencil = c->stencil & 255;
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
    if (!loadClear) {
        [e setRenderPipelineState:pipeline];
        [e setDepthStencilState:_states[write_depth][write_stencil]];
        [e setStencilReferenceValue:c->stencil & 255];
        [e setCullMode:MTLCullModeNone];
        [e setViewport:(MTLViewport){ 0, 0, target.width, target.height, 0,
                                      1 }];
        [e setScissorRect:rect];
        [_arguments setAddress:constants.gpuAddress + uniformOffset atIndex:0];
        [e setArgumentTable:_arguments atStages:MTLRenderStageFragment];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return YES;
}
/* This admission is metadata-only and never changes the parent descriptor.
 * Full load-clears retain their existing standalone entry and store boundary.
 */
- (BOOL)canContinueRasterPass:(MTL4RenderPassDescriptor *)pass
                       config:(const NV2AMetalClearConfig *)c
{
    if (!pass || !c)
        return NO;
    id<MTLTexture> color = pass.colorAttachments[0].texture;
    id<MTLTexture> zeta = pass.depthAttachment.texture;
    unsigned flags = c->parameter;
    BOOL colorWrite = !!(flags & NV097_CLEAR_SURFACE_COLOR);
    BOOL depthWrite = !!(flags & NV097_CLEAR_SURFACE_Z);
    BOOL stencilWrite = (flags & NV097_CLEAR_SURFACE_STENCIL) &&
                        zeta.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    id<MTLTexture> target = color ?: zeta;
    if ((!colorWrite && !depthWrite && !stencilWrite) ||
        (colorWrite && !color) || (depthWrite && !zeta) || !target ||
        (color && (!valid_texture(color, _device) ||
                   !color_format(color.pixelFormat))) ||
        (zeta && (!valid_texture(zeta, _device) ||
                  (zeta.pixelFormat != MTLPixelFormatDepth16Unorm &&
                   zeta.pixelFormat != MTLPixelFormatDepth32Float &&
                   zeta.pixelFormat != MTLPixelFormatDepth32Float_Stencil8))) ||
        (pass.stencilAttachment.texture &&
         pass.stencilAttachment.texture != zeta) ||
        (stencilWrite && pass.stencilAttachment.texture != zeta) ||
        (pass.renderTargetWidth && pass.renderTargetWidth != target.width) ||
        (pass.renderTargetHeight && pass.renderTargetHeight != target.height) ||
        (color &&
         (pass.colorAttachments[0].level || pass.colorAttachments[0].slice ||
          pass.colorAttachments[0].depthPlane)) ||
        (zeta &&
         (pass.depthAttachment.level || pass.depthAttachment.slice ||
          pass.depthAttachment.depthPlane || pass.stencilAttachment.level ||
          pass.stencilAttachment.slice || pass.stencilAttachment.depthPlane)) ||
        (color && zeta &&
         (color.width != zeta.width || color.height != zeta.height ||
          color.sampleCount != zeta.sampleCount)) ||
        (depthWrite && !isfinite(c->uniforms.depth)) || !c->rect.width ||
        !c->rect.height || c->rect.x >= target.width ||
        c->rect.y >= target.height ||
        nv2a_metal_clear_uses_load_actions(color, zeta, c))
        return NO;
    for (unsigned i = 1; i < 8; i++)
        if (pass.colorAttachments[i].texture)
            return NO;
    if (colorWrite)
        for (unsigned i = 0; i < 4; i++)
            if (!isfinite(c->uniforms.color[i]))
                return NO;
    return YES;
}
- (BOOL)encodeColor:(id<MTLTexture>)color
               zeta:(id<MTLTexture>)zeta
             config:(const NV2AMetalClearConfig *)c
         rasterPass:(MTL4RenderPassDescriptor *)pass
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
    if ((color && ![commands addResource:color error:error]) ||
        (zeta && ![commands addResource:zeta error:error])) {
        return clear_error(error, @"Cannot retain native clear resources");
    }

    if (!commands.hasPendingRasterPass ||
        pass.colorAttachments[0].texture != color ||
        pass.depthAttachment.texture != zeta ||
        (pass.stencilAttachment.texture &&
         pass.stencilAttachment.texture != zeta) ||
        ![self canContinueRasterPass:pass config:c] ||
        ![commands rasterPassMatches:pass])
        return clear_error(error, @"Invalid shader-clear raster continuation");
    NSUInteger uniformOffset = 0;
    id<MTLRenderPipelineState> pipeline =
        [self pipeline:color ? color.pixelFormat : MTLPixelFormatInvalid
               samples:target.sampleCount
                  mask:mask
                 error:error];
    if (!pipeline)
        return NO;
    NV2AMetalClearUniforms u = c->uniforms;
    u.dither = c->dither;
    nv2a_metal_color_bits(color.pixelFormat, u.color_bits);
    if (!write_color)
        memset(u.color, 0, sizeof(u.color));
    if (!write_depth)
        u.depth = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&u
                                             length:sizeof(u)
                                             offset:&uniformOffset
                                              error:error];
    if (!constants || ![commands keepAlive:self error:error] ||
        ![commands keepAlive:pipeline error:error])
        return NO;

    id<MTL4RenderCommandEncoder> e = [commands beginRasterPass:pass
                                                         error:error];
    if (!e)
        return NO;
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    [e setRenderPipelineState:pipeline];
    [e setDepthStencilState:_states[write_depth][write_stencil]];
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
