/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#import "pixel-shader.h"
#import "pixel-combiner.h"
#import "lru-cache.h"
#import "shader-library.h"
#include "color-format.h"
#include "geometry-types.h"
#include "pixel-shader-source.h"
#include <math.h>
#include <stdint.h>

_Static_assert(sizeof(NV2AMetalTextureStage) == 152, "CPU/MSL texture stage");
_Static_assert(sizeof(NV2AMetalPixelUniforms) == 1332,
               "CPU/MSL pixel uniforms");

_Static_assert(sizeof(NV2AMetalPixelStorageInfo) == 8,
               "CPU/MSL private pixel storage");

static BOOL pixel_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pixel-shader"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

/* Zero denotes no sampler; otherwise the exact texture object type required
 * by the reference's sampler selection, rather than just the cube flag. */
static MTLTextureType
texture_type(unsigned mode, const NV2AMetalTextureStage *s, bool constantEye)
{
    switch (mode) {
    case PS_TEXTUREMODES_PROJECT2D:
        return s->shadow || s->convolution ? MTLTextureType2D :
               s->dimension == 3           ? MTLTextureType3D :
               s->cubemap                  ? MTLTextureTypeCube :
                                             MTLTextureType2D;
    case PS_TEXTUREMODES_PROJECT3D:
    case PS_TEXTUREMODES_DOT_STR_3D:
        return s->shadow || s->dimension == 2 ? MTLTextureType2D :
                                                MTLTextureType3D;
    case PS_TEXTUREMODES_BRDF:
        return MTLTextureType3D;
    case PS_TEXTUREMODES_BUMPENVMAP:
    case PS_TEXTUREMODES_BUMPENVMAP_LUM:
        return s->dimension == 3 ? MTLTextureType3D : MTLTextureType2D;
    case PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST:
        return constantEye ?
                   (s->cubemap ? MTLTextureTypeCube : MTLTextureType2D) :
                   MTLTextureType1D;
    case PS_TEXTUREMODES_CUBEMAP:
    case PS_TEXTUREMODES_DOT_RFLCT_DIFF:
    case PS_TEXTUREMODES_DOT_RFLCT_SPEC:
    case PS_TEXTUREMODES_DOT_STR_CUBE:
        return s->cubemap ? MTLTextureTypeCube : MTLTextureType2D;
    case PS_TEXTUREMODES_DOT_ST:
    case PS_TEXTUREMODES_DPNDNT_AR:
    case PS_TEXTUREMODES_DPNDNT_GB:
        return MTLTextureType2D;
    default:
        return MTLTextureType1D;
    }
}

static BOOL has_dot(unsigned mode)
{
    return mode == PS_TEXTUREMODES_DOTPRODUCT ||
           mode == PS_TEXTUREMODES_DOT_ZW ||
           (mode >= PS_TEXTUREMODES_DOT_ST &&
            mode <= PS_TEXTUREMODES_DOT_STR_CUBE);
}

static unsigned pixel_combiner_control(const NV2AMetalCombinerState *c)
{
    unsigned unused = (c->control >> 8) &
                      (PS_COMBINERCOUNT_UNIQUE_C0 | PS_COMBINERCOUNT_UNIQUE_C1 |
                       PS_COMBINERCOUNT_MUX_MSB);
    for (unsigned i = 0; unused && i < (c->control & 255); i++) {
        if ((c->rgb_outputs[i] | c->alpha_outputs[i]) &
            (PS_COMBINEROUTPUT_AB_CD_MUX << 12))
            unused &= ~PS_COMBINERCOUNT_MUX_MSB;
        /* Stage zero uses row zero with either policy. Final-combiner reads
         * always use row eight, independent of these flags. */
        if (i && (unused &
                  (PS_COMBINERCOUNT_UNIQUE_C0 | PS_COMBINERCOUNT_UNIQUE_C1))) {
            unsigned rgb = c->rgb_inputs[i], alpha = c->alpha_inputs[i];
            for (unsigned k = 0; k < 4; k++, rgb >>= 8, alpha >>= 8) {
                if ((rgb & 15) == PS_REGISTER_C0 ||
                    (alpha & 15) == PS_REGISTER_C0)
                    unused &= ~PS_COMBINERCOUNT_UNIQUE_C0;
                if ((rgb & 15) == PS_REGISTER_C1 ||
                    (alpha & 15) == PS_REGISTER_C1)
                    unused &= ~PS_COMBINERCOUNT_UNIQUE_C1;
            }
        }
    }
    return c->control & ~(unused << 8);
}

/* Only executed stages affect the fragment program. Keep raw guest words in
 * uniforms/captures, and canonicalize the same inactive words in the cache key
 * and the function constants. */
static void pixel_combiner_words(const NV2AMetalCombinerState *c,
                                 unsigned words[4][8])
{
    const unsigned *source[] = { c->rgb_inputs, c->rgb_outputs, c->alpha_inputs,
                                 c->alpha_outputs };
    unsigned count = MIN(c->control & 255, 8u);
    memset(words, 0, 4 * 8 * sizeof(unsigned));
    for (unsigned i = 0; i < 4; i++)
        memcpy(words[i], source[i], count * sizeof(unsigned));
}

BOOL nv2a_metal_pixel_validate(const NV2AMetalPixelUniforms *u, NSError **error)
{
    if (!u || !nv2a_metal_combiner_validate(&u->combiner, error)) {
        return NO;
    }
    if (!isfinite(u->surface_scale[0]) || u->surface_scale[0] <= 0 ||
        !isfinite(u->surface_scale[1]) || u->surface_scale[1] <= 0 ||
        !isfinite(u->clip_range[1]) || u->clip_range[1] <= 0 ||
        !isfinite(u->clip_range[2]) || !isfinite(u->clip_range[3]) ||
        u->clip_range[2] > u->clip_range[3] ||
        u->depth_format > NV2AMetalPixelDepthF16 || u->legacy_spec_const > 1 ||
        u->two_side > 1 || u->point_sprite > 1 || u->hilo16_mask > 15 ||
        u->shadow_func > SHADOW_DEPTH_FUNC_ALWAYS ||
        u->alpha_func > ALPHA_FUNC_ALWAYS || u->alpha_ref < 0 ||
        u->alpha_ref > 255) {
        return pixel_error(error, @"Invalid Metal pixel raster state");
    }
    unsigned modes[4];
    for (unsigned i = 0; i < 4; i++) {
        modes[i] = (u->combiner.shader_stage_program >> (5 * i)) & 31;
    }
    for (unsigned i = 0; i < 4; i++) {
        const NV2AMetalSamplingUniforms *sampling = &u->textures[i].sampling;
        if (sampling->enabled) {
            if (sampling->enabled != 1 || sampling->min_linear > 1 ||
                sampling->mag_linear > 1 || sampling->mip_filter > 2 ||
                (u->textures[i].rectangle && sampling->mip_filter != 0) ||
                (sampling->anisotropy != 1 && sampling->anisotropy != 2 &&
                 sampling->anisotropy != 4 && sampling->anisotropy != 8) ||
                !isfinite(sampling->lod_bias) || sampling->lod_bias < -16 ||
                sampling->lod_bias > 4095.0f / 256) {
                return pixel_error(error,
                                   @"Invalid manual Metal sampling state");
            }
            for (unsigned axis = 0; axis < 3; axis++) {
                if (sampling->address[axis] < 1 ||
                    sampling->address[axis] > 5) {
                    return pixel_error(error,
                                       @"Invalid manual texture address");
                }
            }
            for (unsigned channel = 0; channel < 4; channel++) {
                if (!isfinite(sampling->border_color[channel])) {
                    return pixel_error(error, @"Invalid manual texture border");
                }
            }
        }
        if (u->textures[i].signed_channels > 15 ||
            (u->textures[i].signed_channels &&
             (!u->textures[i].dimension ||
              u->textures[i].snorm ==
                  NV2AMetalTextureNormalizationLegacySigned ||
              u->textures[i].shadow))) {
            return pixel_error(error, @"Invalid signed8 texture stage");
        }
        unsigned mode = modes[i];
        const NV2AMetalTextureStage *s = &u->textures[i];
        if (s->snorm > NV2AMetalTextureNormalizationMixedHalf ||
            (s->snorm == NV2AMetalTextureNormalizationMixedHalf &&
             (!s->dimension || s->sampling.enabled != 1 ||
              !s->signed_channels || s->signed_channels == 15)))
            return pixel_error(error, @"Invalid mixed Signed8 half storage");
        if ((u->hilo16_mask & (1u << i)) &&
            (!s->dimension || s->snorm || s->shadow ||
             (s->signed_channels && s->signed_channels != 15))) {
            return pixel_error(error, @"Invalid HILO16 texture stage");
        }
        unsigned previous =
            i == 1 ? 0 : (u->other_stage_input >> (i == 2 ? 16 : 20)) & 15;
        unsigned dotmap =
            i == 0 ? 0 : (u->other_stage_input >> (4 * (i - 1))) & 15;
        if (mode > PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST || dotmap > 7 ||
            (mode >= PS_TEXTUREMODES_BUMPENVMAP && (!i || previous >= i)) ||
            ((mode == PS_TEXTUREMODES_BRDF || mode == PS_TEXTUREMODES_DOT_ST ||
              mode == PS_TEXTUREMODES_DOT_ZW) &&
             i < 2) ||
            (mode == PS_TEXTUREMODES_DOT_RFLCT_DIFF &&
             (i != 2 || ((u->other_stage_input >> 20) & 15) >= 2)) ||
            ((mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC ||
              mode == PS_TEXTUREMODES_DOT_STR_3D ||
              mode == PS_TEXTUREMODES_DOT_STR_CUBE ||
              mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST) &&
             i != 3) ||
            (mode == PS_TEXTUREMODES_DOTPRODUCT && (i < 1 || i > 2)) ||
            (mode == PS_TEXTUREMODES_DOT_ZW &&
             modes[i - 1] != PS_TEXTUREMODES_DOTPRODUCT) ||
            ((mode == PS_TEXTUREMODES_DOT_ST ||
              mode == PS_TEXTUREMODES_DOT_RFLCT_DIFF) &&
             !has_dot(modes[i - 1])) ||
            ((mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC ||
              mode == PS_TEXTUREMODES_DOT_STR_3D ||
              mode == PS_TEXTUREMODES_DOT_STR_CUBE ||
              (mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST &&
               !u->legacy_spec_const)) &&
             (!has_dot(modes[1]) || !has_dot(modes[2])))) {
            return pixel_error(error,
                               @"Invalid Metal texture stage dependency");
        }
        MTLTextureType type = texture_type(mode, s, !u->legacy_spec_const);
        if (type != MTLTextureType1D &&
            ((s->dimension != 2 && s->dimension != 3) ||
             (mode == PS_TEXTUREMODES_BRDF &&
              (s->dimension != 3 || s->cubemap)) ||
             (s->rectangle && (s->dimension != 2 || s->cubemap)) ||
             ((mode == PS_TEXTUREMODES_DPNDNT_AR ||
               mode == PS_TEXTUREMODES_DPNDNT_GB) &&
              s->rectangle) ||
             (s->convolution &&
              (s->dimension != 2 || s->cubemap ||
               s->convolution > CONVOLUTION_FILTER_GAUSSIAN)) ||
             (s->shadow &&
              (s->dimension != 2 || (mode != PS_TEXTUREMODES_PROJECT2D &&
                                     mode != PS_TEXTUREMODES_PROJECT3D))) ||
             ((mode == PS_TEXTUREMODES_CUBEMAP ||
               mode == PS_TEXTUREMODES_DOT_ST ||
               mode == PS_TEXTUREMODES_DOT_RFLCT_DIFF ||
               mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC ||
               mode == PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST ||
               mode == PS_TEXTUREMODES_DOT_STR_CUBE ||
               mode == PS_TEXTUREMODES_DPNDNT_AR ||
               mode == PS_TEXTUREMODES_DPNDNT_GB) &&
              s->dimension != 2) ||
             !isfinite(s->scale) || s->scale <= 0 ||
             s->colorkey_mode > COLOR_KEY_DISCARD)) {
            return pixel_error(error,
                               @"Unsupported Metal texture sampling state");
        }
        if (mode == PS_TEXTUREMODES_PASSTHRU &&
            s->border_logical_size[0] != 0) {
            return pixel_error(error, @"Border texture on a passthrough stage");
        }
        if (s->border_logical_size[0] != 0) {
            for (unsigned k = 0; k < 3; k++) {
                if (!isfinite(s->border_logical_size[k]) ||
                    s->border_logical_size[k] <= 0 ||
                    !isfinite(s->border_inv_real_size[k]) ||
                    s->border_inv_real_size[k] <= 0) {
                    return pixel_error(
                        error, @"Invalid Metal texture border dimensions");
                }
            }
        }
    }
    return YES;
}

static BOOL sampleable(MTLPixelFormat format)
{
    switch (format) {
    case MTLPixelFormatR8Unorm:
    case MTLPixelFormatR8Snorm:
    case MTLPixelFormatRG8Unorm:
    case MTLPixelFormatRG8Snorm:
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Snorm:
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatB5G6R5Unorm:
    case MTLPixelFormatBGR5A1Unorm:
    case MTLPixelFormatABGR4Unorm:
    case MTLPixelFormatR16Float:
    case MTLPixelFormatRG16Float:
    case MTLPixelFormatRGBA16Float:
    case MTLPixelFormatR32Float:
    case MTLPixelFormatRG32Float:
    case MTLPixelFormatRGBA32Float:
    case MTLPixelFormatBC1_RGBA:
    case MTLPixelFormatBC2_RGBA:
    case MTLPixelFormatBC3_RGBA:
        return YES;
    default:
        return NO;
    }
}

static id<MTLTexture> texture_root(id<MTLTexture> texture)
{
    while (texture.parentTexture) {
        texture = texture.parentTexture;
    }
    return texture;
}

static BOOL alias(id<MTLTexture> a, id<MTLTexture> b)
{
    if (!a || !b) {
        return NO;
    }
    a = texture_root(a);
    b = texture_root(b);
    return a == b || (a.buffer && a.buffer == b.buffer);
}

@interface NV2AMetalPixelDraw () {
@public
    __weak NV2AMetalCommands *_commands;
    uint64_t _serial;
    NSUInteger _width, _height, _vertexCount;
    MTLPrimitiveType _primitive;
    BOOL _ignoreCulling;
    id<MTL4ArgumentTable> _arguments;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthStencil;
    NV2AMetalDrawState *_drawState;
    uint64_t _addresses[4];
    MTLResourceID _textures[12], _samplers[4];
}
- (instancetype)initForCommands:(NV2AMetalCommands *)commands;
@end

@implementation NV2AMetalPixelDraw
- (instancetype)initForCommands:(NV2AMetalCommands *)commands
{
    self = [super init];
    if (self) {
        _commands = commands;
        _serial = commands.recordingSerial;
    }
    return self;
}
- (NSUInteger)vertexCount
{
    return _vertexCount;
}
- (BOOL)encodeWithRenderEncoder:(id<MTL4RenderCommandEncoder>)encoder
                       commands:(NV2AMetalCommands *)commands
                          error:(NSError **)error
{
    if (!encoder || !commands || commands != _commands ||
        !commands.commandBuffer || commands.recordingSerial != _serial)
        return pixel_error(error, @"Pixel draw belongs to another recording");
    if (!_vertexCount)
        return YES;
    /* The renderer-local table is scratch. Restore every entry immediately
     * before binding; preparation never mutates it. */
    for (unsigned i = 0; i < 4; i++) {
        [_arguments setAddress:_addresses[i] atIndex:i];
        [_arguments setSamplerState:_samplers[i] atIndex:i];
    }
    for (unsigned i = 0; i < 12; i++)
        [_arguments setTexture:_textures[i] atIndex:i];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setViewport:(MTLViewport){ 0, 0, _width, _height, 0, 1 }];
    [encoder setDepthClipMode:MTLDepthClipModeClamp];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setDepthStencilState:_depthStencil];
    [encoder setArgumentTable:_arguments
                     atStages:MTLRenderStageVertex | MTLRenderStageFragment];
    if (!_drawState || [_drawState applyToEncoder:encoder
                                            width:_width
                                           height:_height
                                        primitive:_primitive
                             ignorePolygonCulling:_ignoreCulling])
        [encoder drawPrimitives:_primitive
                    vertexStart:0
                    vertexCount:_vertexCount];
    return YES;
}
@end

@implementation NV2AMetalPixelShader {
    id<MTLDevice> _device;
    NV2AMetalShaderLibrary *_sharedLibrary;
    id<MTL4Compiler> _compiler;
    id<MTLLibrary> _library;
    NV2AMetalLRUCache<NSData *, id<MTLRenderPipelineState>> *_fragmentPipelines;
    id<MTL4ArgumentTable> _arguments;
    id<MTLTexture> _dummy2D, _dummy3D, _dummyCube;
    id<MTLSamplerState> _sampler;
    MTLPixelFormat _colorFormat, _depthFormat;
    NSUInteger _sampleCount;
    unsigned int _surfaceChannels;
}

- (nullable id<MTLRenderPipelineState>)
    newPipelineForTopology:(unsigned)topology
                 drawState:(nullable NV2AMetalDrawState *)state
                logicFetch:(BOOL)logicFetch
                  uniforms:(const NV2AMetalPixelUniforms *)uniforms
               rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                     error:(NSError **)error
{
    if (!uniforms) {
        pixel_error(error, @"Missing Metal fragment pipeline uniforms");
        return nil;
    }
    if (_surfaceChannels > NV2AMetalSurfaceStorageNative &&
        _surfaceChannels <= NV2AMetalSurfaceStorageG8B8 &&
        (state.blendWord & NV_PGRAPH_BLEND_EN) && !state.logicEnabled) {
        pixel_error(error, @"NV2A B8/G8B8 surfaces do not support blending");
        return nil;
    }
    MTL4LibraryFunctionDescriptor *vertex = [MTL4LibraryFunctionDescriptor new];
    vertex.library = _library;
    BOOL directTriangle = (rasterClass & ~NV2AMetalDirectTriangleMask) ==
                          NV2AMetalPixelRasterDirectTriangle;
    vertex.name = directTriangle ? @"nv2a_pixel_direct_triangle_vertex" :
                  rasterClass == NV2AMetalPixelRasterDirectPoint ?
                                   @"nv2a_pixel_direct_point_vertex" :
                  rasterClass == NV2AMetalPixelRasterDirectLineSmooth ?
                                   @"nv2a_pixel_direct_line_smooth_vertex" :
                  rasterClass == NV2AMetalPixelRasterDirectLineFlatFirst ?
                                   @"nv2a_pixel_direct_line_first_vertex" :
                  rasterClass == NV2AMetalPixelRasterDirectLineFlatLast ?
                                   @"nv2a_pixel_direct_line_last_vertex" :
                  topology == 0 ? @"nv2a_pixel_point_vertex" :
                  topology == 1 ? @"nv2a_pixel_line_vertex" :
                                  @"nv2a_pixel_vertex";
    MTL4LibraryFunctionDescriptor *fragment =
        [MTL4LibraryFunctionDescriptor new];
    fragment.library = _library;
    fragment.name =
        logicFetch ? @"nv2a_pixel_logic_fragment" : @"nv2a_pixel_fragment";
    MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
    pd.vertexFunctionDescriptor = vertex;
    if (directTriangle) {
        unsigned options = rasterClass & NV2AMetalDirectTriangleMask;
        MTLFunctionConstantValues *vertexValues =
            [MTLFunctionConstantValues new];
        [vertexValues setConstantValue:&options
                                  type:MTLDataTypeUInt
                               atIndex:12];
        MTL4SpecializedFunctionDescriptor *specializedVertex =
            [MTL4SpecializedFunctionDescriptor new];
        specializedVertex.functionDescriptor = vertex;
        specializedVertex.constantValues = vertexValues;
        pd.vertexFunctionDescriptor = specializedVertex;
    }
    MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
    const NV2AMetalCombinerState *c = &uniforms->combiner;
    unsigned control = pixel_combiner_control(c);
    [values setConstantValue:&control type:MTLDataTypeUInt atIndex:0];
    [values setConstantValue:&c->shader_stage_program
                        type:MTLDataTypeUInt
                     atIndex:1];
    [values setConstantValue:c->final_inputs type:MTLDataTypeUInt2 atIndex:2];
    unsigned words[4][8];
    pixel_combiner_words(c, words);
    for (unsigned i = 0; i < 4; i++)
        for (unsigned j = 0; j < 2; j++)
            [values setConstantValue:words[i] + j * 4
                                type:MTLDataTypeUInt4
                             atIndex:3 + i * 2 + j];
    unsigned fragmentRasterClass =
        rasterClass >= NV2AMetalPixelRasterDirectPoint ?
            NV2AMetalPixelRasterNative : rasterClass;
    [values setConstantValue:&fragmentRasterClass type:MTLDataTypeUInt atIndex:11];
    MTL4SpecializedFunctionDescriptor *specialized =
        [MTL4SpecializedFunctionDescriptor new];
    specialized.functionDescriptor = fragment;
    specialized.constantValues = values;
    pd.fragmentFunctionDescriptor = specialized;
    /* Compile the complete attachment state together with the fragment body.
     * Render-state specialization produced unequal blended MSAA images even
     * for repeated draws of the same input. The bounded full-pipeline cache
     * still shares identical draw/combiner configurations. */
    if (state && _colorFormat != MTLPixelFormatInvalid) {
        pd.colorAttachments[0] = [state colorAttachment];
        MTL4RenderPipelineColorAttachmentDescriptor *a = pd.colorAttachments[0];
        if (logicFetch && (state.ditherEnabled ||
                           _surfaceChannels >= NV2AMetalSurfaceStorageZ1))
            a.blendingState = MTL4BlendStateDisabled;
        if (_surfaceChannels > NV2AMetalSurfaceStorageNative &&
            _surfaceChannels <= NV2AMetalSurfaceStorageG8B8) {
            MTLColorWriteMask guest = a.writeMask;
            a.writeMask =
                (guest & MTLColorWriteMaskBlue ? MTLColorWriteMaskRed : 0) |
                (_surfaceChannels == NV2AMetalSurfaceStorageG8B8 ?
                     guest & MTLColorWriteMaskGreen :
                     0);
        }
    }
    pd.colorAttachments[0].pixelFormat = _colorFormat;
    pd.rasterSampleCount = _sampleCount;
    pd.inputPrimitiveTopology =
        topology == 0 ? MTLPrimitiveTopologyClassPoint :
        topology == 1 ? MTLPrimitiveTopologyClassLine :
                        MTLPrimitiveTopologyClassTriangle;
    @synchronized(_compiler) {
        return [_compiler newRenderPipelineStateWithDescriptor:pd
                                           compilerTaskOptions:nil
                                                         error:error];
    }
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                                  error:(NSError **)error
{
    return [self initWithDevice:device
                    colorFormat:colorFormat
                    depthFormat:depthFormat
                    sampleCount:sampleCount
                surfaceChannels:0
                          error:error];
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                        surfaceChannels:(unsigned int)surfaceChannels
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (surfaceChannels > NV2AMetalSurfaceStorageO7 ||
        ((surfaceChannels == NV2AMetalSurfaceStorageZ1 ||
          surfaceChannels == NV2AMetalSurfaceStorageO1) &&
         colorFormat != MTLPixelFormatBGR5A1Unorm) ||
        ((surfaceChannels == NV2AMetalSurfaceStorageZ8 ||
          surfaceChannels == NV2AMetalSurfaceStorageO8 ||
          surfaceChannels == NV2AMetalSurfaceStorageZ7 ||
          surfaceChannels == NV2AMetalSurfaceStorageO7) &&
         colorFormat != MTLPixelFormatBGRA8Unorm) ||
        (surfaceChannels == 1 && colorFormat != MTLPixelFormatR8Unorm) ||
        (surfaceChannels == 2 && colorFormat != MTLPixelFormatRG8Unorm) ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4] ||
        !device.hasUnifiedMemory ||
        (colorFormat != MTLPixelFormatInvalid &&
         colorFormat != MTLPixelFormatRGBA8Unorm &&
         colorFormat != MTLPixelFormatBGRA8Unorm &&
         colorFormat != MTLPixelFormatR8Unorm &&
         colorFormat != MTLPixelFormatRG8Unorm &&
         colorFormat != MTLPixelFormatB5G6R5Unorm &&
         colorFormat != MTLPixelFormatBGR5A1Unorm &&
         colorFormat != MTLPixelFormatRGBA32Float) ||
        (depthFormat != MTLPixelFormatInvalid &&
         depthFormat != MTLPixelFormatDepth16Unorm &&
         depthFormat != MTLPixelFormatDepth32Float &&
         depthFormat != MTLPixelFormatDepth32Float_Stencil8) ||
        (colorFormat == MTLPixelFormatInvalid &&
         depthFormat == MTLPixelFormatInvalid) ||
        ![device supportsTextureSampleCount:sampleCount]) {
        pixel_error(
            error,
            @"Invalid Apple Silicon Metal 4 pixel pipeline configuration");
        return nil;
    }
    _device = device;
    _colorFormat = colorFormat;
    _depthFormat = depthFormat;
    _sampleCount = sampleCount;
    _surfaceChannels = surfaceChannels;
    _sharedLibrary =
        [NV2AMetalShaderLibrary sharedWithDevice:device
                                          source:metal_shader_source
                                           error:error];
    if (!_sharedLibrary)
        return nil;
    _compiler = _sharedLibrary.compiler;
    _library = _sharedLibrary.library;
    _fragmentPipelines = [[NV2AMetalLRUCache alloc] initWithCapacity:256];

    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 4;
    ad.maxTextureBindCount = 12;
    ad.maxSamplerStateBindCount = 4;
    ad.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:ad error:error];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode =
        MTLSamplerAddressModeClampToEdge;
    _sampler = [device newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:1
                                    height:1
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    _dummy2D = [device newTextureWithDescriptor:td];
    td.textureType = MTLTextureType3D;
    td.depth = 1;
    _dummy3D = [device newTextureWithDescriptor:td];
    td.textureType = MTLTextureTypeCube;
    td.depth = 1;
    td.arrayLength = 1;
    _dummyCube = [device newTextureWithDescriptor:td];
    if (!_arguments || !_sampler || !_dummy2D || !_dummy3D || !_dummyCube) {
        pixel_error(error,
                    @"Could not allocate Metal pixel pipeline resources");
        return nil;
    }
    const float zero[4] = { 0 };
    [_dummy2D replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                mipmapLevel:0
                  withBytes:zero
                bytesPerRow:sizeof(zero)];
    [_dummy3D replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1)
                mipmapLevel:0
                      slice:0
                  withBytes:zero
                bytesPerRow:sizeof(zero)
              bytesPerImage:sizeof(zero)];
    for (unsigned face = 0; face < 6; face++) {
        [_dummyCube replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                      mipmapLevel:0
                            slice:face
                        withBytes:zero
                      bytesPerRow:sizeof(zero)
                    bytesPerImage:sizeof(zero)];
    }
    return self;
}

- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                 count:(NSUInteger)count
             primitive:(MTLPrimitiveType)primitive
              uniforms:(const NV2AMetalPixelUniforms *)uniforms
              textures:(const NV2AMetalPixelTexture *)textures
                  pass:(MTL4RenderPassDescriptor *)pass
          depthStencil:(nullable id<MTLDepthStencilState>)depthStencil
              commands:(NV2AMetalCommands *)commands
                 error:(NSError **)error
{
    return [self encodeVertices:vertices
                         offset:0
                          count:count
                      primitive:primitive
                       uniforms:uniforms
                       textures:textures
                           pass:pass
                   depthStencil:depthStencil
                      drawState:nil
                    rasterClass:NV2AMetalPixelRasterDynamic
             polygonProjections:nil
           ignorePolygonCulling:NO
                  renderEncoder:nil
                       commands:commands
                          error:error];
}

- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                 count:(NSUInteger)count
             primitive:(MTLPrimitiveType)primitive
              uniforms:(const NV2AMetalPixelUniforms *)uniforms
              textures:(const NV2AMetalPixelTexture *)textures
                  pass:(MTL4RenderPassDescriptor *)pass
             drawState:(NV2AMetalDrawState *)drawState
              commands:(NV2AMetalCommands *)commands
                 error:(NSError **)error
{
    return [self encodeVertices:vertices
                         offset:0
                          count:count
                      primitive:primitive
                       uniforms:uniforms
                       textures:textures
                           pass:pass
                      drawState:drawState
                       commands:commands
                          error:error];
}
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                offset:(NSUInteger)offset
                 count:(NSUInteger)count
             primitive:(MTLPrimitiveType)primitive
              uniforms:(const NV2AMetalPixelUniforms *)uniforms
              textures:(const NV2AMetalPixelTexture *)textures
                  pass:(MTL4RenderPassDescriptor *)pass
             drawState:(NV2AMetalDrawState *)drawState
              commands:(NV2AMetalCommands *)commands
                 error:(NSError **)error
{
    return [self encodeVertices:vertices
                         offset:offset
                          count:count
                      primitive:primitive
                       uniforms:uniforms
                       textures:textures
                           pass:pass
                      drawState:drawState
           ignorePolygonCulling:NO
                       commands:commands
                          error:error];
}
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
    ignorePolygonCulling:(BOOL)ignore
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    return [self encodeVertices:vertices
                         offset:offset
                          count:count
                      primitive:primitive
                       uniforms:uniforms
                       textures:textures
                           pass:pass
                      drawState:drawState
                    rasterClass:NV2AMetalPixelRasterDynamic
           ignorePolygonCulling:ignore
                       commands:commands
                          error:error];
}

- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
    ignorePolygonCulling:(BOOL)ignore
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    return [self encodeVertices:vertices
                         offset:offset
                          count:count
                      primitive:primitive
                       uniforms:uniforms
                       textures:textures
                           pass:pass
                      drawState:drawState
                    rasterClass:rasterClass
           ignorePolygonCulling:ignore
                  renderEncoder:nil
                       commands:commands
                          error:error];
}

- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
    ignorePolygonCulling:(BOOL)ignore
           renderEncoder:(nullable id<MTL4RenderCommandEncoder>)renderEncoder
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    if (!drawState || drawState.device != _device ||
        (drawState.requiresDepth && !pass.depthAttachment.texture) ||
        (drawState.requiresStencil &&
         (_depthFormat != MTLPixelFormatDepth32Float_Stencil8 ||
          pass.stencilAttachment.texture != pass.depthAttachment.texture ||
          !pass.stencilAttachment.texture))) {
        return pixel_error(error, @"Invalid native draw state/attachments");
    }
    return [self encodeVertices:vertices
                         offset:offset
                          count:count
                      primitive:primitive
                       uniforms:uniforms
                       textures:textures
                           pass:pass
                   depthStencil:drawState.depthStencil
                      drawState:drawState
                    rasterClass:rasterClass
             polygonProjections:nil
           ignorePolygonCulling:ignore
                  renderEncoder:renderEncoder
                       commands:commands
                          error:error];
}

- (BOOL)encodeGeometry:(NV2AMetalGeometryResult *)geometry
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
    ignorePolygonCulling:(BOOL)ignore
           renderEncoder:(nullable id<MTL4RenderCommandEncoder>)renderEncoder
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    NV2AMetalPixelDraw *prepared = [self prepareGeometry:geometry
                                                  offset:offset
                                                   count:count
                                                uniforms:uniforms
                                                textures:textures
                                                    pass:pass
                                               drawState:drawState
                                             rasterClass:rasterClass
                                    ignorePolygonCulling:ignore
                                                commands:commands
                                                   error:error];
    return prepared && [self encodePrepared:prepared
                                       pass:pass
                              renderEncoder:renderEncoder
                                   commands:commands
                                      error:error];
}

- (NV2AMetalPixelDraw *)prepareGeometry:(NV2AMetalGeometryResult *)geometry
                                 offset:(NSUInteger)offset
                                  count:(NSUInteger)count
                               uniforms:(const NV2AMetalPixelUniforms *)uniforms
                               textures:(const NV2AMetalPixelTexture *)textures
                                   pass:(MTL4RenderPassDescriptor *)pass
                              drawState:(NV2AMetalDrawState *)drawState
                            rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                   ignorePolygonCulling:(BOOL)ignore
                               commands:(NV2AMetalCommands *)commands
                                  error:(NSError **)error
{
    if (!geometry || offset % sizeof(NV2AMetalVertex) ||
        offset / sizeof(NV2AMetalVertex) > geometry.vertexCount ||
        count > geometry.vertexCount - offset / sizeof(NV2AMetalVertex) ||
        geometry.firstVertex >
            geometry.vertices.length / sizeof(NV2AMetalVertex) ||
        geometry.vertexCount >
            geometry.vertices.length / sizeof(NV2AMetalVertex) -
                geometry.firstVertex ||
        (geometry.expandedPolygons && geometry.firstVertex) || !drawState ||
        drawState.device != _device ||
        (drawState.requiresDepth && !pass.depthAttachment.texture) ||
        (drawState.requiresStencil &&
         (_depthFormat != MTLPixelFormatDepth32Float_Stencil8 ||
          pass.stencilAttachment.texture != pass.depthAttachment.texture ||
          !pass.stencilAttachment.texture)) ||
        (geometry.expandedPolygons && geometry.vertexCount &&
         !geometry.polygonProjections) ||
        (!geometry.expandedPolygons && geometry.polygonProjections)) {
        pixel_error(error, @"Invalid geometry-owned pixel binding");
        return nil;
    }
    return [self
             prepareVertices:geometry.vertices
                      offset:geometry.firstVertex * sizeof(NV2AMetalVertex) +
                             offset
                       count:count
                   primitive:geometry.primitiveType
                    uniforms:uniforms
                    textures:textures
                        pass:pass
                depthStencil:drawState.depthStencil
                   drawState:drawState
                 rasterClass:rasterClass
          polygonProjections:geometry.polygonProjections
        ignorePolygonCulling:ignore
                    commands:commands
                       error:error];
}

- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
            depthStencil:(nullable id<MTLDepthStencilState>)depthStencil
               drawState:(nullable NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
      polygonProjections:(nullable id<MTLBuffer>)projections
    ignorePolygonCulling:(BOOL)ignore
           renderEncoder:(nullable id<MTL4RenderCommandEncoder>)renderEncoder
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    NV2AMetalPixelDraw *prepared = [self prepareVertices:vertices
                                                  offset:offset
                                                   count:count
                                               primitive:primitive
                                                uniforms:uniforms
                                                textures:textures
                                                    pass:pass
                                            depthStencil:depthStencil
                                               drawState:drawState
                                             rasterClass:rasterClass
                                      polygonProjections:projections
                                    ignorePolygonCulling:ignore
                                                commands:commands
                                                   error:error];
    return prepared && [self encodePrepared:prepared
                                       pass:pass
                              renderEncoder:renderEncoder
                                   commands:commands
                                      error:error];
}


- (NV2AMetalPixelDraw *)prepareVertices:(id<MTLBuffer>)vertices
                                 offset:(NSUInteger)offset
                                  count:(NSUInteger)count
                              primitive:(MTLPrimitiveType)primitive
                               uniforms:(const NV2AMetalPixelUniforms *)uniforms
                               textures:(const NV2AMetalPixelTexture *)textures
                                   pass:(MTL4RenderPassDescriptor *)pass
                           depthStencil:
                               (nullable id<MTLDepthStencilState>)depthStencil
                              drawState:(nullable NV2AMetalDrawState *)drawState
                            rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                     polygonProjections:(nullable id<MTLBuffer>)projections
                   ignorePolygonCulling:(BOOL)ignore
                               commands:(NV2AMetalCommands *)commands
                                  error:(NSError **)error
{
    BOOL directTriangle = (rasterClass & ~NV2AMetalDirectTriangleMask) ==
                          NV2AMetalPixelRasterDirectTriangle;
    if ((rasterClass > NV2AMetalPixelRasterDirectLineFlatLast &&
         !directTriangle) ||
        (directTriangle &&
         (primitive != MTLPrimitiveTypeTriangle || count % 3)) ||
        (rasterClass == NV2AMetalPixelRasterDirectPoint &&
         primitive != MTLPrimitiveTypePoint) ||
        (rasterClass >= NV2AMetalPixelRasterDirectLineSmooth &&
         rasterClass <= NV2AMetalPixelRasterDirectLineFlatLast &&
         (primitive != MTLPrimitiveTypeLine || count % 2)) ||
        !commands.commandBuffer || commands.device != _device ||
        vertices.device != _device || offset > vertices.length ||
        offset % sizeof(NV2AMetalVertex) ||
        count > (vertices.length - offset) / sizeof(NV2AMetalVertex) ||
        count > UINT32_MAX || primitive > MTLPrimitiveTypeTriangleStrip ||
        !textures || !nv2a_metal_pixel_validate(uniforms, error)) {
        pixel_error(error, @"Invalid Metal pixel draw input or state");
        return nil;
    }
    if (projections &&
        (rasterClass != NV2AMetalPixelRasterExpandedPolygon ||
         primitive != MTLPrimitiveTypeTriangle || count % 6 ||
         offset % (6 * sizeof(NV2AMetalVertex)) ||
         projections.device != _device ||
         (offset / sizeof(NV2AMetalVertex) + count) / 6 >
             projections.length / sizeof(NV2AMetalPolygonProjection))) {
        pixel_error(error, @"Invalid polygon projection slice");
        return nil;
    }
    if (pass.visibilityResultBuffer &&
        (pass.visibilityResultBuffer.device != _device ||
         pass.visibilityResultBuffer.length < sizeof(uint64_t) ||
         (pass.visibilityResultType != MTLVisibilityResultTypeReset &&
          pass.visibilityResultType != MTLVisibilityResultTypeAccumulate))) {
        pixel_error(error, @"Invalid Metal visibility result buffer");
        return nil;
    }
    id<MTLTexture> color = pass.colorAttachments[0].texture;
    id<MTLTexture> depth = pass.depthAttachment.texture;
    id<MTLTexture> target = color ? color : depth;
    id<MTLTexture> resolve = pass.colorAttachments[0].resolveTexture;
    MTLTextureType targetType =
        _sampleCount == 1 ? MTLTextureType2D : MTLTextureType2DMultisample;
    MTLStoreAction colorStore = pass.colorAttachments[0].storeAction;
    BOOL resolves = colorStore == MTLStoreActionMultisampleResolve ||
                    colorStore == MTLStoreActionStoreAndMultisampleResolve;
    if (!target || target.width == 0 || target.height == 0 ||
        (_colorFormat == MTLPixelFormatInvalid ?
             color != nil :
             (!color || color.device != _device ||
              color.textureType != targetType ||
              color.pixelFormat != _colorFormat ||
              color.sampleCount != _sampleCount ||
              !(color.usage & MTLTextureUsageRenderTarget))) ||
        (_depthFormat == MTLPixelFormatInvalid ?
             depth != nil :
             (!depth || depth.device != _device ||
              depth.textureType != targetType ||
              depth.pixelFormat != _depthFormat ||
              depth.sampleCount != _sampleCount ||
              depth.width != target.width || depth.height != target.height ||
              !(depth.usage & MTLTextureUsageRenderTarget))) ||
        (depthStencil && depthStencil.device != _device) ||
        resolves != (resolve != nil) ||
        pass.depthAttachment.storeAction == MTLStoreActionMultisampleResolve ||
        pass.depthAttachment.storeAction ==
            MTLStoreActionStoreAndMultisampleResolve ||
        pass.stencilAttachment.storeAction ==
            MTLStoreActionMultisampleResolve ||
        pass.stencilAttachment.storeAction ==
            MTLStoreActionStoreAndMultisampleResolve ||
        pass.colorAttachments[0].level || pass.colorAttachments[0].slice ||
        pass.colorAttachments[0].depthPlane || pass.depthAttachment.level ||
        pass.depthAttachment.slice || pass.depthAttachment.depthPlane ||
        pass.depthAttachment.resolveTexture ||
        pass.stencilAttachment.resolveTexture ||
        (pass.stencilAttachment.texture &&
         (_depthFormat != MTLPixelFormatDepth32Float_Stencil8 ||
          pass.stencilAttachment.texture != depth ||
          pass.stencilAttachment.level || pass.stencilAttachment.slice ||
          pass.stencilAttachment.depthPlane)) ||
        (resolve &&
         (!color || _sampleCount == 1 || resolve.device != _device ||
          resolve.textureType != MTLTextureType2D || resolve.sampleCount != 1 ||
          resolve.pixelFormat != _colorFormat || resolve.width != color.width ||
          resolve.height != color.height ||
          !(resolve.usage & MTLTextureUsageRenderTarget) ||
          pass.colorAttachments[0].resolveLevel ||
          pass.colorAttachments[0].resolveSlice ||
          pass.colorAttachments[0].resolveDepthPlane || alias(resolve, color) ||
          alias(resolve, depth)))) {
        pixel_error(error, @"Invalid Metal pixel render attachments");
        return nil;
    }
    for (unsigned i = 1; i < 8; i++) {
        if (pass.colorAttachments[i].texture ||
            pass.colorAttachments[i].resolveTexture) {
            pixel_error(error, @"Unexpected Metal color attachment");
            return nil;
        }
    }
    for (unsigned i = 0; i < 4; i++) {
        unsigned mode =
            (uniforms->combiner.shader_stage_program >> (5 * i)) & 31;
        MTLTextureType type = texture_type(mode, &uniforms->textures[i],
                                           !uniforms->legacy_spec_const);
        if (type == MTLTextureType1D) {
            continue;
        }
        id<MTLTexture> tex = textures[i].texture;
        if (!tex || tex.device != _device || tex.textureType != type ||
            tex.sampleCount != 1 || !(tex.usage & MTLTextureUsageShaderRead) ||
            !sampleable(tex.pixelFormat) ||
            (uniforms->textures[i].snorm ==
                 NV2AMetalTextureNormalizationMixedHalf &&
             tex.pixelFormat != MTLPixelFormatRGBA16Float) ||
            ((uniforms->hilo16_mask & (1u << i)) &&
             tex.pixelFormat != MTLPixelFormatRGBA32Float &&
             tex.pixelFormat != MTLPixelFormatRG32Float) ||
            alias(tex, color) || alias(tex, depth) || alias(tex, resolve) ||
            (textures[i].sampler && textures[i].sampler.device != _device)) {
            pixel_error(error,
                        @"Invalid Metal pixel texture or feedback alias");
            return nil;
        }
    }
    if (_surfaceChannels > NV2AMetalSurfaceStorageNative &&
        _surfaceChannels <= NV2AMetalSurfaceStorageG8B8 &&
        (drawState.blendWord & NV_PGRAPH_BLEND_EN) && !drawState.logicEnabled) {
        pixel_error(error, @"NV2A B8/G8B8 surfaces do not support blending");
        return nil;
    }
    NV2AMetalPixelDraw *prepared =
        [[NV2AMetalPixelDraw alloc] initForCommands:commands];
    if (!count)
        return prepared;
    id<MTLBuffer> constants = nil;
    NV2AMetalPixelUniforms snapshot = *uniforms;
    /* Polygon point mode emits native points; real and expanded lines do not
     * replace TEX3, even when the guest leaves point sprites enabled. */
    snapshot.point_sprite =
        uniforms->point_sprite && primitive == MTLPrimitiveTypePoint;
    snapshot.vertex_capacity = (unsigned)count;
    snapshot.logic_op =
        drawState.logicEnabled ? drawState.logicOperation + 1 : 0;
    nv2a_metal_color_bits(_colorFormat, snapshot.color_bits);
    if (_surfaceChannels >= NV2AMetalSurfaceStorageZ7)
        snapshot.color_bits[3] = 7;
    snapshot.dither = drawState.ditherEnabled;
    snapshot.blend = drawState.blendWord;
    uint32_t blend_color = drawState.blendColor;
    snapshot.blend_color[0] = ((blend_color >> 16) & 255) / 255.f;
    snapshot.blend_color[1] = ((blend_color >> 8) & 255) / 255.f;
    snapshot.blend_color[2] = (blend_color & 255) / 255.f;
    snapshot.blend_color[3] = (blend_color >> 24) / 255.f;
    struct {
        NV2AMetalPixelUniforms uniforms;
        NV2AMetalPixelStorageInfo info;
        NV2AMetalPolygonProjection emptyProjection;
    } storage = { snapshot,
                  { _surfaceChannels, projections ? (unsigned)(count / 6) : 0 },
                  { { { 0 } }, 0 } };
    _Static_assert(offsetof(__typeof__(storage), info) == sizeof(snapshot),
                   "Surface storage argument follows immutable pixel uniforms");
    NSUInteger constantsOffset = 0;
    constants = [commands uploadBytes:&storage
                               length:sizeof(storage)
                               offset:&constantsOffset
                                error:error];
    if (!constants) {
        return nil;
    }
    if (![commands addResource:vertices error:error] ||
        (projections && ![commands addResource:projections error:error]) ||
        (color && ![commands addResource:color error:error]) ||
        (resolve && ![commands addResource:resolve error:error]) ||
        (depth && ![commands addResource:depth error:error]) ||
        (pass.visibilityResultBuffer &&
         ![commands addResource:pass.visibilityResultBuffer error:error]) ||
        ![commands addResource:_dummy2D error:error] ||
        ![commands addResource:_dummy3D error:error] ||
        ![commands addResource:_dummyCube error:error] ||
        ![commands keepAlive:self error:error] ||
        (depthStencil && ![commands keepAlive:depthStencil error:error])) {
        return nil;
    }
    prepared->_addresses[0] = vertices.gpuAddress + offset;
    prepared->_addresses[1] = constants.gpuAddress + constantsOffset;
    prepared->_addresses[2] =
        constants.gpuAddress + constantsOffset + sizeof(snapshot);
    NSUInteger projectionOffset = offset / (6 * sizeof(NV2AMetalVertex)) *
                                  sizeof(NV2AMetalPolygonProjection);
    prepared->_addresses[3] =
        projections ? projections.gpuAddress + projectionOffset :
                      constants.gpuAddress + constantsOffset +
                          offsetof(__typeof__(storage), emptyProjection);
    for (unsigned i = 0; i < 4; i++) {
        unsigned mode =
            (uniforms->combiner.shader_stage_program >> (5 * i)) & 31;
        MTLTextureType type = texture_type(mode, &uniforms->textures[i],
                                           !uniforms->legacy_spec_const);
        prepared->_textures[i] = _dummy2D.gpuResourceID;
        prepared->_textures[4 + i] = _dummy3D.gpuResourceID;
        prepared->_textures[8 + i] = _dummyCube.gpuResourceID;
        id<MTLSamplerState> sampler =
            type == MTLTextureType1D || !textures[i].sampler ?
                _sampler :
                textures[i].sampler;
        prepared->_samplers[i] = sampler.gpuResourceID;
        if (![commands keepAlive:sampler error:error])
            return nil;
        if (type != MTLTextureType1D) {
            id<MTLTexture> tex = textures[i].texture;
            if (![commands addResource:tex error:error])
                return nil;
            prepared->_textures[(type == MTLTextureType3D   ? 4 :
                                 type == MTLTextureTypeCube ? 8 :
                                                              0) +
                                i] = tex.gpuResourceID;
        }
    }
    unsigned topology = primitive == MTLPrimitiveTypePoint ? 0 :
                        primitive == MTLPrimitiveTypeLine ||
                                primitive == MTLPrimitiveTypeLineStrip ?
                                                             1 :
                                                             2;
    NSUInteger static_key = drawState.pipelineKey;
    if (drawState.ditherEnabled && _colorFormat != MTLPixelFormatRGBA32Float)
        static_key &= ~((NSUInteger)(1u << 17) - 1);
    /* No pointers, padding, colors, or unrelated raster values in the key. */
    uint64_t raster_key[] = { static_key, topology, drawState != nil,
                              rasterClass };
    NSMutableData *key = [NSMutableData
        dataWithCapacity:sizeof(raster_key) +
                         offsetof(NV2AMetalCombinerState, constants)];
    [key appendBytes:raster_key length:sizeof(raster_key)];
    unsigned control = pixel_combiner_control(&uniforms->combiner);
    [key appendBytes:&control length:sizeof(control)];
    [key appendBytes:&uniforms->combiner.shader_stage_program
              length:offsetof(NV2AMetalCombinerState, rgb_inputs) -
                     offsetof(NV2AMetalCombinerState, shader_stage_program)];
    unsigned words[4][8];
    pixel_combiner_words(&uniforms->combiner, words);
    [key appendBytes:words length:sizeof(words)];
    id<MTLRenderPipelineState> pipeline = _fragmentPipelines[key];
    if (!pipeline) {
        BOOL fetch = drawState && _colorFormat != MTLPixelFormatInvalid &&
                     _colorFormat != MTLPixelFormatRGBA32Float &&
                     (drawState.logicEnabled || drawState.ditherEnabled ||
                      _surfaceChannels >= NV2AMetalSurfaceStorageZ1);
        pipeline = [self newPipelineForTopology:topology
                                      drawState:drawState
                                     logicFetch:fetch
                                       uniforms:uniforms
                                    rasterClass:rasterClass
                                          error:error];
        if (!pipeline)
            return nil;
        _fragmentPipelines[key] = pipeline;
    }
    if (![commands keepAlive:pipeline error:error] ||
        (drawState && ![commands keepAlive:drawState error:error])) {
        return nil;
    }
    prepared->_arguments = _arguments;
    prepared->_pipeline = pipeline;
    prepared->_depthStencil = depthStencil;
    prepared->_drawState = drawState;
    prepared->_primitive = primitive;
    prepared->_ignoreCulling = ignore;
    prepared->_width = target.width;
    prepared->_height = target.height;
    prepared->_vertexCount = count;
    return prepared;
}

- (BOOL)encodePrepared:(NV2AMetalPixelDraw *)prepared
                  pass:(MTL4RenderPassDescriptor *)pass
         renderEncoder:(nullable id<MTL4RenderCommandEncoder>)renderEncoder
              commands:(NV2AMetalCommands *)commands
                 error:(NSError **)error
{
    if (!prepared.vertexCount)
        return YES;
    id<MTL4RenderCommandEncoder> encoder =
        renderEncoder ?:
            [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder)
        return pixel_error(error,
                           @"Could not create Metal pixel render encoder");
    if (!renderEncoder) {
        [encoder barrierAfterQueueStages:MTLStageAll
                            beforeStages:nv2a_metal_pixel_pass_stages()
                       visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder setVisibilityResultMode:pass.visibilityResultBuffer ?
                                             MTLVisibilityResultModeCounting :
                                             MTLVisibilityResultModeDisabled
                                  offset:0];
    }
    BOOL ok = [prepared encodeWithRenderEncoder:encoder
                                       commands:commands
                                          error:error];
    if (!renderEncoder) {
        [encoder barrierAfterStages:nv2a_metal_pixel_pass_stages()
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
    }
    return ok;
}
@end
