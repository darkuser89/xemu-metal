/* Native framebuffer/PVIDEO composition from gl/display.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "scanout.h"
#include "texture-alias.h"
#include "scanout-source.h"
#include "color-format.h"
#include <math.h>
#include <float.h>
#include <stddef.h>
_Static_assert(sizeof(NV2AMetalScanoutUniforms) == 92, "CPU/MSL scanout ABI");
_Static_assert(offsetof(NV2AMetalScanoutUniforms, color_key) == 56,
               "Scanout key ABI");
static BOOL scanout_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.scanout"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
static BOOL color_format(MTLPixelFormat format)
{
    return format == MTLPixelFormatR8Unorm ||
           format == MTLPixelFormatRG8Unorm ||
           format == MTLPixelFormatB5G6R5Unorm ||
           format == MTLPixelFormatBGR5A1Unorm ||
           format == MTLPixelFormatRGBA8Unorm ||
           format == MTLPixelFormatBGRA8Unorm ||
           format == MTLPixelFormatRGBA32Float;
}
static BOOL readable(id<MTLTexture> texture, id<MTLDevice> device)
{
    return texture.device == device &&
           texture.textureType == MTLTextureType2D &&
           texture.sampleCount == 1 && texture.width && texture.height &&
           (texture.usage & MTLTextureUsageShaderRead) &&
           color_format(texture.pixelFormat);
}
@implementation NV2AMetalScanout {
    id<MTLDevice> _device;
    MTLPixelFormat _format;
    id<MTLRenderPipelineState> _pipeline;
    id<MTL4ArgumentTable> _arguments;
    id<MTLTexture> _dummy;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)format
                         error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4] || !color_format(format)) {
        scanout_error(
            error,
            @"Scanout requires Apple Silicon Metal4 and a native color target");
        return nil;
    }
    _device = device;
    _format = format;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!compiler)
        return nil;
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = @(metal_shader_source);
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld error:error];
    if (!library)
        return nil;
    MTL4LibraryFunctionDescriptor *vs = [MTL4LibraryFunctionDescriptor new];
    vs.library = library;
    vs.name = @"nv2a_scanout_vertex";
    MTL4LibraryFunctionDescriptor *fs = [MTL4LibraryFunctionDescriptor new];
    fs.library = library;
    fs.name = @"nv2a_scanout_fragment";
    MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
    pd.vertexFunctionDescriptor = vs;
    pd.fragmentFunctionDescriptor = fs;
    pd.colorAttachments[0].pixelFormat = format;
    pd.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
    _pipeline = [compiler newRenderPipelineStateWithDescriptor:pd
                                           compilerTaskOptions:nil
                                                         error:error];
    if (!_pipeline)
        return nil;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.maxTextureBindCount = 2;
    ad.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:ad error:error];
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:1
                                    height:1
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    _dummy = [device newTextureWithDescriptor:td];
    if (!_dummy) {
        scanout_error(error, @"Cannot allocate inactive overlay");
        return nil;
    }
    uint32_t zero = 0;
    [_dummy replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
              mipmapLevel:0
                withBytes:&zero
              bytesPerRow:4];
    return _arguments ? self : nil;
}
- (BOOL)encodeSource:(id<MTLTexture>)source
             overlay:(id<MTLTexture>)overlay
              target:(id<MTLTexture>)target
            uniforms:(const NV2AMetalScanoutUniforms *)u
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    if (!u || !commands.commandBuffer || commands.device != _device ||
        !readable(source, _device) || target.device != _device ||
        target.textureType != MTLTextureType2D || target.sampleCount != 1 ||
        target.pixelFormat != _format ||
        !(target.usage & MTLTextureUsageRenderTarget) || !target.width ||
        !target.height || nv2a_metal_textures_alias(source, target) ||
        u->output_size[0] != target.width ||
        u->output_size[1] != target.height || !isfinite(u->line_offset) ||
        u->line_offset < FLT_MIN || u->overlay_enable > 1 ||
        u->color_key_enable > 1 || u->source_border > 1 || u->dither > 1 ||
        (u->overlay_enable && (!readable(overlay, _device) ||
                               nv2a_metal_textures_alias(overlay, target))))
        return scanout_error(error,
                             @"Invalid scanout textures, size or line stride");
    if ((double)target.height / source.height / u->line_offset > 1e30)
        return scanout_error(
            error, @"Scanout line stride exceeds finite coordinate range");
    if (u->overlay_enable) {
        for (unsigned i = 0; i < 4; i++)
            if (!isfinite(u->overlay_rect[i]) || u->overlay_rect[i] < 0)
                return scanout_error(error, @"Invalid PVIDEO rectangle");
        for (unsigned i = 0; i < 3; i++)
            if (!isfinite(u->overlay_scale[i]) || u->overlay_scale[i] < 0 ||
                !isfinite(u->color_key[i]) || u->color_key[i] < 0 ||
                u->color_key[i] > 1)
                return scanout_error(error, @"Invalid PVIDEO scale/key");
        for (unsigned i = 0; i < 2; i++)
            if (!isfinite(u->overlay_input[i]))
                return scanout_error(error, @"Invalid PVIDEO input position");
        // Keep interpolated texel coordinates finite before repeat reduction.
        for (unsigned i = 0; i < 2; i++) {
            double extent =
                (double)target.width + target.height + u->overlay_rect[i];
            double coordinate =
                fabs((double)u->overlay_input[i]) +
                extent * u->overlay_scale[2] * u->overlay_scale[i];
            if (extent * u->overlay_scale[2] > 1e30 || coordinate > 1e30)
                return scanout_error(
                    error, @"PVIDEO coordinate exceeds finite native range");
        }
    }
    id<MTLTexture> ov = u->overlay_enable ? overlay : _dummy;
    NV2AMetalScanoutUniforms snapshot = *u;
    nv2a_metal_color_bits(_format, snapshot.color_bits);
    id<MTLBuffer> constants =
        [_device newBufferWithBytes:&snapshot
                             length:sizeof(*u)
                            options:MTLResourceStorageModeShared];
    if (!constants)
        return scanout_error(error, @"Cannot allocate scanout uniforms");
    if (![commands addResource:source error:error] ||
        ![commands addResource:ov error:error] ||
        ![commands addResource:target error:error] ||
        ![commands addResource:constants error:error] ||
        ![commands keepAlive:self error:error])
        return NO;
    [_arguments setAddress:constants.gpuAddress atIndex:0];
    [_arguments setTexture:source.gpuResourceID atIndex:0];
    [_arguments setTexture:ov.gpuResourceID atIndex:1];
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!e)
        return scanout_error(error, @"Cannot create scanout render encoder");
    /* Only the fragment stage accesses GPU-produced inputs or attachments;
     * the fullscreen vertex shader has no resource bindings. */
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageFragment
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setRenderPipelineState:_pipeline];
    [e setViewport:(MTLViewport){ 0, 0, target.width, target.height, 0, 1 }];
    [e setCullMode:MTLCullModeNone];
    [e setArgumentTable:_arguments atStages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e barrierAfterStages:MTLStageFragment
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return YES;
}
@end
