/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#import "pixel-shader.h"
#import "vertex-stream.h"
#import "pixel-combiner.h"
#import "lru-cache.h"
#import "shader-library.h"
#import "pipeline-compiler.h"
#include "color-format.h"
#include "geometry-types.h"
#include "pixel-shader-source.h"
#define metal_shader_source nv2a_pixel_interpreter_source
#include "pixel-interpreter-source.h"
#undef metal_shader_source
#include <math.h>
#include <stdint.h>
#include <string.h>

_Static_assert(sizeof(NV2AMetalTextureStage) == 152, "CPU/MSL texture stage");
_Static_assert(sizeof(NV2AMetalPixelUniforms) == 1332,
               "CPU/MSL pixel uniforms");

_Static_assert(sizeof(NV2AMetalPixelStorageInfo) == 12,
               "CPU/MSL private pixel storage");
_Static_assert(NV2AMetalPixelRasterCompactPolygon == 9 &&
                   NV2AMetalPixelRasterCompactLine == 8,
               "MSL compact raster class");

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

static unsigned pixel_combiner_final_input(const NV2AMetalCombinerState *c)
{
    const unsigned sumFlags = PS_FINALCOMBINERSETTING_CLAMP_SUM |
                              PS_FINALCOMBINERSETTING_COMPLEMENT_V1 |
                              PS_FINALCOMBINERSETTING_COMPLEMENT_R0;
    unsigned second = c->final_inputs[1];
    if (!(second & sumFlags))
        return second;
    /* SUM flags are read only by explicit V1R0_SUM operands. Keep every
     * active RGB/alpha and final operand conservative, including alpha SUM.
     * The low flag byte is not an operand; raw guest uniforms stay intact. */
    unsigned first = c->final_inputs[0];
    for (unsigned k = 0; k < 4; k++, first >>= 8)
        if ((first & 15) == PS_REGISTER_V1R0_SUM)
            return second;
    unsigned inputs = second >> 8;
    for (unsigned k = 0; k < 3; k++, inputs >>= 8)
        if ((inputs & 15) == PS_REGISTER_V1R0_SUM)
            return second;
    unsigned count = MIN(c->control & 255, 8u);
    for (unsigned i = 0; i < count; i++) {
        unsigned rgb = c->rgb_inputs[i], alpha = c->alpha_inputs[i];
        for (unsigned k = 0; k < 4; k++, rgb >>= 8, alpha >>= 8)
            if ((rgb & 15) == PS_REGISTER_V1R0_SUM ||
                (alpha & 15) == PS_REGISTER_V1R0_SUM)
                return second;
    }
    return second & ~sumFlags;
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

typedef struct NV2AMetalPixelBindings {
    uint64_t addresses[7];
    MTLResourceID textures[12], samplers[4];
} NV2AMetalPixelBindings;

typedef struct NV2AMetalPixelSampleIDs {
    MTLResourceID texture, sampler;
} NV2AMetalPixelSampleIDs;

enum { NV2AMetalPixelRasterIndexed = 1u << 24 };

static NSUInteger pixel_source_vertex_count(NV2AMetalPixelRasterClass raster,
                                            NSUInteger count)
{
    BOOL direct = (raster & ~NV2AMetalDirectTriangleMask) ==
                  NV2AMetalPixelRasterDirectTriangle;
    unsigned topology = raster & NV2AMetalDirectTriangleTopologyMask;
    unsigned quadMode = raster & NV2AMetalDirectQuadModeMask;
    unsigned polygonMode = raster & NV2AMetalDirectPolygonModeMask;
    if (direct && topology == NV2AMetalDirectTrianglePolygon && count)
        return polygonMode == NV2AMetalDirectPolygonLine ? count / 2 : count / 3 + 2;
    if (direct && polygonMode && count) {
        NSUInteger per = polygonMode == NV2AMetalDirectPolygonPoint ? 3 : 6;
        return topology ? count / per + 2 : count / per * 3;
    }
    if (direct && quadMode && count) {
        NSUInteger perQuad = quadMode == NV2AMetalDirectQuadPoint ? 4 : 8;
        return topology == NV2AMetalDirectTriangleQuads ? count / perQuad * 4 :
                                                        count / perQuad * 2 + 2;
    }
    if (direct && topology && count)
        return topology == NV2AMetalDirectTriangleQuads ? count / 6 * 4 : count / 3 + 2;
    BOOL mappedLine = (raster & ~NV2AMetalDirectLineMask) ==
                      NV2AMetalPixelRasterDirectMappedLine;
    return mappedLine && count ? count / 2 +
        ((raster & NV2AMetalDirectLineTopologyMask) == NV2AMetalDirectLineStrip) : count;
}

@interface NV2AMetalPixelShader ()
- (id<MTL4ArgumentTable>)
    argumentsForBindings:(const NV2AMetalPixelBindings *)bindings
                commands:(NV2AMetalCommands *)commands
                  serial:(uint64_t)serial;
- (BOOL)hasEncodedBindingsForDraw:(NV2AMetalPixelDraw *)draw
                          encoder:(id<MTL4RenderCommandEncoder>)encoder;
- (BOOL)applyRasterStateForDraw:(NV2AMetalPixelDraw *)draw
                         encoder:(id<MTL4RenderCommandEncoder>)encoder;
@end

@interface NV2AMetalPixelDraw () {
@public
    __weak NV2AMetalCommands *_commands;
    uint64_t _serial;
    NSUInteger _width, _height, _vertexCount, _firstVertex, _rangeAlignment;
    /* Unmapped slices move their binding instead of their draw IDs. */
    NSUInteger _groupFirstVertex;
    MTLPrimitiveType _primitive;
    BOOL _ignoreCulling;
    NV2AMetalPixelShader *_shader;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthStencil;
    NV2AMetalDrawState *_drawState;
    NV2AMetalPixelBindings _bindings;
}
- (instancetype)initForCommands:(NV2AMetalCommands *)commands;
- (BOOL)emitWithRenderEncoder:(id<MTL4RenderCommandEncoder>)encoder
                     commands:(NV2AMetalCommands *)commands
                  firstVertex:(NSUInteger)first
                  vertexCount:(NSUInteger)count
                        error:(NSError **)error;
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
    return [self emitWithRenderEncoder:encoder
                              commands:commands
                           firstVertex:_firstVertex
                           vertexCount:_vertexCount
                                 error:error];
}
- (BOOL)encodeWithRenderEncoder:(id<MTL4RenderCommandEncoder>)encoder
                       commands:(NV2AMetalCommands *)commands
                    firstVertex:(NSUInteger)first
                    vertexCount:(NSUInteger)count
                          error:(NSError **)error
{
    if (!encoder || !commands || commands != _commands ||
        !commands.commandBuffer || commands.recordingSerial != _serial)
        return pixel_error(error, @"Pixel draw belongs to another recording");
    NSUInteger primitiveAlignment = _primitive == MTLPrimitiveTypePoint    ? 1 :
                                    _primitive == MTLPrimitiveTypeLine     ? 2 :
                                    _primitive == MTLPrimitiveTypeTriangle ? 3 :
                                                                             0;
    if (first > _vertexCount || count > _vertexCount - first ||
        first > NSUIntegerMax - _firstVertex ||
        first > NSUIntegerMax - _groupFirstVertex ||
        (count && primitiveAlignment &&
         ((_firstVertex + first) % primitiveAlignment ||
          count % primitiveAlignment)) ||
        (count &&
         (_rangeAlignment ? ((_groupFirstVertex + first) % _rangeAlignment ||
                             count % _rangeAlignment) :
                            ((_primitive != MTLPrimitiveTypeLineStrip &&
                              _primitive != MTLPrimitiveTypeTriangleStrip) ||
                             first || count != _vertexCount))) ||
        encoder.commandBuffer != commands.commandBuffer) {
        return pixel_error(error, @"Invalid prepared pixel draw range");
    }
    return [self emitWithRenderEncoder:encoder
                              commands:commands
                           firstVertex:_firstVertex + first
                           vertexCount:count
                                 error:error];
}
- (BOOL)emitWithRenderEncoder:(id<MTL4RenderCommandEncoder>)encoder
                     commands:(NV2AMetalCommands *)commands
                  firstVertex:(NSUInteger)first
                  vertexCount:(NSUInteger)count
                        error:(NSError **)error
{
    if (!encoder || !commands || commands != _commands ||
        !commands.commandBuffer || commands.recordingSerial != _serial)
        return pixel_error(error, @"Pixel draw belongs to another recording");
    if (!count)
        return YES;
    BOOL bound = [_shader hasEncodedBindingsForDraw:self encoder:encoder];
    id<MTL4ArgumentTable> arguments = bound ? nil :
        [_shader argumentsForBindings:&_bindings commands:commands serial:_serial];
    BOOL drawable = [_shader applyRasterStateForDraw:self encoder:encoder];
    if (!bound)
        [encoder setArgumentTable:arguments
                         atStages:MTLRenderStageVertex | MTLRenderStageFragment];
    if (drawable)
        [encoder drawPrimitives:_primitive vertexStart:first vertexCount:count];
    return YES;
}
@end

typedef struct NV2AMetalFragmentPipelineKey {
    uint64_t raster[4];
    unsigned control, program, finalInputs[2], words[4][8];
} NV2AMetalFragmentPipelineKey;

_Static_assert(sizeof(NV2AMetalFragmentPipelineKey) ==
                   4 * sizeof(uint64_t) + 36 * sizeof(unsigned),
               "Fragment pipeline key has no padding");
/* Process-local recipe identity. The controller's entries retain the actual
 * library, so its address cannot be recycled while a matching entry lives.
 * The device is fixed by the controller; source/options by this exact library.
 * Bump recipeVersion when descriptor/key interpretation changes. */
typedef struct NV2AMetalPixelPipelineRecipe {
    uint64_t recipeVersion, libraryIdentity, colorFormat, depthFormat;
    uint64_t sampleCount, surfaceChannels;
    NV2AMetalFragmentPipelineKey fragment;
} NV2AMetalPixelPipelineRecipe;
_Static_assert(sizeof(NV2AMetalPixelPipelineRecipe) == 224,
               "Bounded async pixel recipe has no padding");

enum {
    PixelCombinerProgramBytes = offsetof(NV2AMetalCombinerState, constants)
};

typedef struct NV2AMetalPixelConstants {
    NV2AMetalPixelUniforms uniforms;
    NV2AMetalPixelStorageInfo info;
    NV2AMetalPolygonProjection emptyProjection;
} NV2AMetalPixelConstants;

_Static_assert(offsetof(NV2AMetalPixelConstants, info) ==
                   sizeof(NV2AMetalPixelUniforms),
               "Surface storage argument follows immutable pixel uniforms");

typedef struct NV2AMetalPixelConstantSlot {
    const void *bytes;
    MTLGPUAddress address;
} NV2AMetalPixelConstantSlot;

typedef struct NV2AMetalPixelSampleCheck {
    MTLTextureType type;
    unsigned normalization;
    BOOL hilo16;
} NV2AMetalPixelSampleCheck;

/* Render variants share immutable zero textures and the default sampler.
 * Argument tables and their binding history remain private to each shader. */
@interface NV2AMetalPixelFallbacks : NSObject
@property(nonatomic, readonly) id<MTLTexture> dummy2D, dummy3D, dummyCube;
@property(nonatomic, readonly) id<MTLSamplerState> sampler;
@property(nonatomic, readonly) NV2AMetalPixelBindings bindings;
+ (instancetype)sharedWithDevice:(id<MTLDevice>)device error:(NSError **)error;
@end

@implementation NV2AMetalPixelFallbacks
+ (instancetype)sharedWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    static NSMapTable<id<MTLDevice>, NV2AMetalPixelFallbacks *> *devices;
    @synchronized(NV2AMetalPixelFallbacks.class) {
        if (!devices)
            devices = [[NSMapTable alloc]
                initWithKeyOptions:NSPointerFunctionsWeakMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsWeakMemory
                          capacity:1];
        NV2AMetalPixelFallbacks *fallbacks = [devices objectForKey:device];
        if (!fallbacks) {
            fallbacks = [[self alloc] initWithDevice:device error:error];
            if (fallbacks)
                [devices setObject:fallbacks forKey:device];
        }
        return fallbacks;
    }
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
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
    if (!_sampler || !_dummy2D || !_dummy3D || !_dummyCube) {
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
    MTLResourceID dummy2D = _dummy2D.gpuResourceID;
    MTLResourceID dummy3D = _dummy3D.gpuResourceID;
    MTLResourceID dummyCube = _dummyCube.gpuResourceID;
    MTLResourceID sampler = _sampler.gpuResourceID;
    for (unsigned i = 0; i < 4; i++) {
        _bindings.textures[i] = dummy2D;
        _bindings.textures[4 + i] = dummy3D;
        _bindings.textures[8 + i] = dummyCube;
        _bindings.samplers[i] = sampler;
    }
    return self;
}
@end

typedef NS_ENUM(unsigned, NV2AMetalPixelPostprocess) {
    NV2AMetalPixelPostprocessNone,
    NV2AMetalPixelPostprocessSource,
    NV2AMetalPixelPostprocessDestination,
};

static BOOL blend_reads_destination(unsigned blend, unsigned surface_channels)
{
    if (!(blend & NV_PGRAPH_BLEND_EN))
        return NO;
    unsigned equation = blend & NV_PGRAPH_BLEND_EQN;
    if (equation == 3 || equation == 4)
        return YES;
    unsigned source = nv2a_metal_surface_blend_factor(
        (blend & NV_PGRAPH_BLEND_SFACTOR) >> 4, surface_channels);
    unsigned destination = nv2a_metal_surface_blend_factor(
        (blend & NV_PGRAPH_BLEND_DFACTOR) >> 8, surface_channels);
    /* All postprocessed targets are UNORM, so destination * ZERO is exact.
     * The remaining source factors read only source/constant values. */
    return destination != 0 || (source >= 6 && source <= 10);
}

@implementation NV2AMetalPixelShader {
    id<MTLDevice> _device;
    NV2AMetalShaderLibrary *_sharedLibrary;
    id<MTL4Compiler> _compiler;
    id<MTLLibrary> _library;
    id<MTLLibrary> _canonicalLibrary;
    NV2AMetalPipelineCompiler *_pipelineCompiler;
    NV2AMetalShaderLibrary *_interpreterModule;
    NV2AMetalLRUCache<NSData *, id<MTLRenderPipelineState>> *_interpreterPipelines;
    NV2AMetalLRUCache<NSData *, id<MTLRenderPipelineState>> *_fragmentPipelines;
    NSMutableData *_fragmentLookupKey;
    id<MTL4ArgumentTable> _arguments;
    __weak NV2AMetalCommands *_bindingCommands;
    uint64_t _bindingSerial;
    NV2AMetalPixelBindings _bound;
    __weak id<MTL4RenderCommandEncoder> _encodingEncoder;
    __weak NV2AMetalPixelDraw *_encodedDraw;
    BOOL _encodedDrawable;
    __weak NV2AMetalCommands *_constantCommands;
    uint64_t _constantSerial;
    NV2AMetalPixelConstantSlot _constantSlots[4];
    unsigned _constantSlotCount, _nextConstantSlot;
    MTL4RenderPassDescriptor *_preparationPass;
    __weak NV2AMetalCommands *_preparationCommands;
    uint64_t _preparationSerial;
    BOOL _preparationValidated;
    BOOL _preparationResourcesRegistered;
    unsigned _registeredSampleMask;
    id<MTLTexture> _checkedTextures[4];
    id<MTLSamplerState> _checkedSamplers[4];
    NV2AMetalPixelSampleCheck _sampleChecks[4];
    NV2AMetalPixelSampleIDs _registeredSampleIDs[4];
    BOOL _preparedProgramValid;
    uint8_t _preparedProgram[PixelCombinerProgramBytes];
    NV2AMetalFragmentPipelineKey _preparedFragmentKey;
    uint64_t _preparedRasterKeys[4][4];
    id<MTLRenderPipelineState> _preparedPipelines[4];
    unsigned _preparedPipelineCount;
    NV2AMetalDrawState *_retainedDrawState;
    id<MTLDepthStencilState> _retainedDepthStencil;
    NV2AMetalPixelFallbacks *_fallbacks;
    MTLPixelFormat _colorFormat, _depthFormat;
    NSUInteger _sampleCount;
    unsigned int _surfaceChannels;
}

- (void)beginRasterEncoding:(id<MTL4RenderCommandEncoder>)encoder
{
    _encodingEncoder = encoder;
    _encodedDraw = nil;
}

- (void)endRasterEncoding
{
    _encodingEncoder = nil;
    _encodedDraw = nil;
}

- (BOOL)hasEncodedBindingsForDraw:(NV2AMetalPixelDraw *)draw
                          encoder:(id<MTL4RenderCommandEncoder>)encoder
{
    NV2AMetalPixelDraw *previous = encoder == _encodingEncoder ? _encodedDraw : nil;
    return previous && previous->_commands == draw->_commands &&
           previous->_serial == draw->_serial &&
           !memcmp(&previous->_bindings, &draw->_bindings, sizeof(_bound)) &&
           !memcmp(&_bound, &draw->_bindings, sizeof(_bound));
}

- (BOOL)applyRasterStateForDraw:(NV2AMetalPixelDraw *)draw
                         encoder:(id<MTL4RenderCommandEncoder>)encoder
{
    BOOL grouped = encoder == _encodingEncoder;
    NV2AMetalPixelDraw *previous = grouped ? _encodedDraw : nil;
    if (previous && (previous->_commands != draw->_commands ||
                     previous->_serial != draw->_serial))
        previous = nil;
    if (!previous || previous->_pipeline != draw->_pipeline)
        [encoder setRenderPipelineState:draw->_pipeline];
    if (!previous)
        [encoder setDepthClipMode:MTLDepthClipModeClamp];
    NV2AMetalDrawState *raster = draw->_drawState;
    BOOL sameRaster = previous && previous->_drawState == raster &&
                      previous->_depthStencil == draw->_depthStencil &&
                      previous->_width == draw->_width &&
                      previous->_height == draw->_height &&
                      previous->_ignoreCulling == draw->_ignoreCulling;
    /* With both faces culled, changing from triangles to points/lines
     * changes drawability even though the captured raster state is equal. */
    if (sameRaster && !draw->_ignoreCulling &&
        (previous->_primitive >= MTLPrimitiveTypeTriangle) !=
            (draw->_primitive >= MTLPrimitiveTypeTriangle) &&
        raster.cullsBothFaces)
        sameRaster = NO;
    BOOL drawable = YES;
    if (sameRaster) {
        drawable = _encodedDrawable;
    } else if (raster) {
        drawable = [raster applyToEncoder:encoder
                                     width:draw->_width
                                    height:draw->_height
                                 primitive:draw->_primitive
                      ignorePolygonCulling:draw->_ignoreCulling];
    } else {
        [encoder setViewport:(MTLViewport){ 0, 0, draw->_width, draw->_height, 0, 1 }];
        [encoder setCullMode:MTLCullModeNone];
        [encoder setDepthStencilState:draw->_depthStencil];
    }
    if (grouped) {
        _encodedDraw = draw;
        _encodedDrawable = drawable;
    }
    return drawable;
}

- (void)beginPreparationForPass:(MTL4RenderPassDescriptor *)pass
                         commands:(NV2AMetalCommands *)commands
{
    if (_preparationPass)
        [self endPreparation];
    _preparationPass = pass;
    _preparationCommands = commands;
    _preparationSerial = commands.recordingSerial;
    _preparationValidated = NO;
}

- (void)endPreparation
{
    if (_preparationPass) {
        for (unsigned i = 0; i < 4; i++) {
            _checkedTextures[i] = nil;
            _checkedSamplers[i] = nil;
            _preparedPipelines[i] = nil;
        }
    }
    _preparationPass = nil;
    _preparationCommands = nil;
    _preparationValidated = NO;
    _preparationResourcesRegistered = NO;
    _registeredSampleMask = 0;
    _preparedProgramValid = NO;
    _preparedPipelineCount = 0;
    _retainedDrawState = nil;
    _retainedDepthStencil = nil;
}

- (MTLGPUAddress)addressForConstants:(const NV2AMetalPixelConstants *)constants
                            commands:(NV2AMetalCommands *)commands
                               error:(NSError **)error
{
    /* The recording owns the upload pages. Sealing or rolling back a
     * section ends that recording before the upload cursor can be reused. */
    uint64_t serial = commands.recordingSerial;
    if (_constantCommands != commands || _constantSerial != serial) {
        _constantCommands = commands;
        _constantSerial = serial;
        _constantSlotCount = _nextConstantSlot = 0;
    }
    for (unsigned i = 0; i < _constantSlotCount; i++) {
        NV2AMetalPixelConstantSlot slot = _constantSlots[i];
        if (!memcmp(slot.bytes, constants, sizeof(*constants)))
            return slot.address;
    }

    NSUInteger offset;
    id<MTLBuffer> buffer = [commands uploadBytes:constants
                                          length:sizeof(*constants)
                                          offset:&offset
                                           error:error];
    if (!buffer)
        return 0;
    MTLGPUAddress address = buffer.gpuAddress + offset;
    _constantSlots[_nextConstantSlot] = (NV2AMetalPixelConstantSlot){
        (const char *)buffer.contents + offset, address
    };
    unsigned capacity = sizeof(_constantSlots) / sizeof(*_constantSlots);
    _nextConstantSlot = (_nextConstantSlot + 1) % capacity;
    _constantSlotCount = MIN(_constantSlotCount + 1, capacity);
    return address;
}

- (id<MTL4ArgumentTable>)
    argumentsForBindings:(const NV2AMetalPixelBindings *)bindings
                commands:(NV2AMetalCommands *)commands
                  serial:(uint64_t)serial
{
    /* Only this method changes the table, in emission order. A recording
     * retains every resource it references, so no equal address or ID can
     * be recycled for another resource while this comparison is valid. */
    BOOL reset = _bindingCommands != commands || _bindingSerial != serial;
    for (unsigned i = 0; i < 4; i++) {
        if (reset || _bound.addresses[i] != bindings->addresses[i]) {
            [_arguments setAddress:bindings->addresses[i] atIndex:i];
            _bound.addresses[i] = bindings->addresses[i];
        }
        if (reset || memcmp(&_bound.samplers[i], &bindings->samplers[i],
                            sizeof(MTLResourceID))) {
            [_arguments setSamplerState:bindings->samplers[i] atIndex:i];
            _bound.samplers[i] = bindings->samplers[i];
        }
    }
    if (reset || _bound.addresses[4] != bindings->addresses[4]) {
        [_arguments setAddress:bindings->addresses[4] atIndex:4];
        _bound.addresses[4] = bindings->addresses[4];
    }
    if (reset || _bound.addresses[5] != bindings->addresses[5]) {
        [_arguments setAddress:bindings->addresses[5] atIndex:5];
        _bound.addresses[5] = bindings->addresses[5];
    }
    if (reset || _bound.addresses[6] != bindings->addresses[6]) {
        [_arguments setAddress:bindings->addresses[6] atIndex:6];
        _bound.addresses[6] = bindings->addresses[6];
    }
    for (unsigned i = 0; i < 12; i++) {
        if (reset || memcmp(&_bound.textures[i], &bindings->textures[i],
                            sizeof(MTLResourceID))) {
            [_arguments setTexture:bindings->textures[i] atIndex:i];
            _bound.textures[i] = bindings->textures[i];
        }
    }
    if (reset) {
        _bindingCommands = commands;
        _bindingSerial = serial;
    }
    return _arguments;
}

- (nullable MTL4RenderPipelineDescriptor *)
    newPipelineDescriptorForTopology:(unsigned)topology
                 drawState:(nullable NV2AMetalDrawState *)state
               postprocess:(NV2AMetalPixelPostprocess)postprocess
               fragmentKey:(const NV2AMetalFragmentPipelineKey *)key
               rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                   library:(id<MTLLibrary>)library
               interpreter:(BOOL)interpreter
                     error:(NSError **)error
{
    BOOL indexed = (rasterClass & NV2AMetalPixelRasterIndexed) != 0;
    rasterClass &= ~NV2AMetalPixelRasterIndexed;
    MTL4LibraryFunctionDescriptor *vertex = [MTL4LibraryFunctionDescriptor new];
    vertex.library = library;
    BOOL directTriangle = (rasterClass & ~NV2AMetalDirectTriangleMask) ==
                          NV2AMetalPixelRasterDirectTriangle;
    BOOL mappedLine = (rasterClass & ~NV2AMetalDirectLineMask) ==
                      NV2AMetalPixelRasterDirectMappedLine;
    unsigned quadMode = rasterClass & NV2AMetalDirectQuadModeMask;
    unsigned polygonMode = rasterClass & NV2AMetalDirectPolygonModeMask;
    BOOL genuinePolygon =
        directTriangle && (rasterClass & NV2AMetalDirectTriangleTopologyMask) ==
                              NV2AMetalDirectTrianglePolygon;
    BOOL compactLine = rasterClass == NV2AMetalPixelRasterCompactLine;
    BOOL compactFill = rasterClass == NV2AMetalPixelRasterCompactPolygon;
    BOOL compact = compactLine || compactFill;
    vertex.name = compactFill ? @"nv2a_pixel_compact_polygon_vertex" :
                  compactLine ? @"nv2a_pixel_compact_line_vertex" :
                  genuinePolygon && polygonMode == NV2AMetalDirectPolygonLine ?
                                @"nv2a_pixel_direct_polygon_boundary_vertex" :
                  genuinePolygon ? @"nv2a_pixel_direct_polygon_fill_vertex" :
                  directTriangle && polygonMode == NV2AMetalDirectPolygonPoint ?
                                   @"nv2a_pixel_direct_polygon_point_vertex" :
                  directTriangle && polygonMode == NV2AMetalDirectPolygonLine ?
                                   @"nv2a_pixel_direct_polygon_line_vertex" :
                  directTriangle && quadMode == NV2AMetalDirectQuadPoint ?
                                   @"nv2a_pixel_direct_quad_point_vertex" :
                  directTriangle && quadMode == NV2AMetalDirectQuadLine ?
                                   @"nv2a_pixel_direct_quad_line_vertex" :
                  mappedLine     ? @"nv2a_pixel_direct_mapped_line_vertex" :
                  directTriangle ? @"nv2a_pixel_direct_triangle_vertex" :
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
    fragment.library = library;
    fragment.name = postprocess == NV2AMetalPixelPostprocessDestination ?
                        @"nv2a_pixel_logic_fragment" :
                    postprocess == NV2AMetalPixelPostprocessSource ?
                        @"nv2a_pixel_post_fragment" :
                        @"nv2a_pixel_fragment";
    MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
    pd.vertexFunctionDescriptor = vertex;
    BOOL direct = rasterClass >= NV2AMetalPixelRasterDirectPoint && !compact;
    if (direct) {
        unsigned options =
            rasterClass & (directTriangle ? NV2AMetalDirectTriangleMask :
                                            NV2AMetalDirectLineMask);
        MTLFunctionConstantValues *vertexValues =
            [MTLFunctionConstantValues new];
        [vertexValues setConstantValue:&indexed
                                  type:MTLDataTypeBool
                               atIndex:14];
        if (directTriangle || mappedLine)
            [vertexValues setConstantValue:&options
                                      type:MTLDataTypeUInt
                                   atIndex:directTriangle ? 12 : 13];
        MTL4SpecializedFunctionDescriptor *specializedVertex =
            [MTL4SpecializedFunctionDescriptor new];
        specializedVertex.functionDescriptor = vertex;
        specializedVertex.constantValues = vertexValues;
        pd.vertexFunctionDescriptor = specializedVertex;
    }
    MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
    [values setConstantValue:&compactLine type:MTLDataTypeBool atIndex:15];
    [values setConstantValue:&compactFill type:MTLDataTypeBool atIndex:16];
    BOOL polygonProjection = (key->raster[2] & (1u << 3)) != 0;
    [values setConstantValue:&polygonProjection
                        type:MTLDataTypeBool
                     atIndex:17];
    if (interpreter) {
        [values setConstantValue:&key->program type:MTLDataTypeUInt atIndex:1];
    } else {
        [values setConstantValue:&key->control type:MTLDataTypeUInt atIndex:0];
        [values setConstantValue:&key->program type:MTLDataTypeUInt atIndex:1];
        [values setConstantValue:key->finalInputs type:MTLDataTypeUInt2 atIndex:2];
        for (unsigned i = 0; i < 4; i++)
            for (unsigned j = 0; j < 2; j++)
                [values setConstantValue:key->words[i] + j * 4
                                    type:MTLDataTypeUInt4
                                 atIndex:3 + i * 2 + j];
    }
    unsigned fragmentRasterClass =
        rasterClass >= NV2AMetalPixelRasterDirectPoint && !compact ?
            NV2AMetalPixelRasterNative :
            rasterClass;
    [values setConstantValue:&fragmentRasterClass
                        type:MTLDataTypeUInt
                     atIndex:11];
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
        if (postprocess != NV2AMetalPixelPostprocessNone)
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
    return pd;
}

- (nullable id<MTLRenderPipelineState>)
    newPipelineForTopology:(unsigned)topology
                 drawState:(nullable NV2AMetalDrawState *)state
               postprocess:(NV2AMetalPixelPostprocess)postprocess
               fragmentKey:(const NV2AMetalFragmentPipelineKey *)key
               rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                     error:(NSError **)error
{
    if (_surfaceChannels > NV2AMetalSurfaceStorageNative &&
        _surfaceChannels <= NV2AMetalSurfaceStorageG8B8 &&
        (state.blendWord & NV_PGRAPH_BLEND_EN) && !state.logicEnabled) {
        pixel_error(error, @"NV2A B8/G8B8 surfaces do not support blending");
        return nil;
    }
    MTL4RenderPipelineDescriptor *pd = [self
        newPipelineDescriptorForTopology:topology drawState:state
                             postprocess:postprocess fragmentKey:key
                             rasterClass:rasterClass library:_library
                             interpreter:NO error:error];
    @synchronized(_compiler) {
        return [_compiler newRenderPipelineStateWithDescriptor:pd
                                           compilerTaskOptions:nil
                                                         error:error];
    }
}

/* This optional cache is owner-local; it never enters the shared specialized
 * LRU. Both the library and the 16 raster/program entries are created lazily,
 * only from the existing post-validation/post-residency pipeline callsite. */
- (nullable id<MTLRenderPipelineState>)
    interpreterPipelineForTopology:(unsigned)topology
                          drawState:(NV2AMetalDrawState *)state
                        postprocess:(NV2AMetalPixelPostprocess)postprocess
                        fragmentKey:(const NV2AMetalFragmentPipelineKey *)key
                        rasterClass:(NV2AMetalPixelRasterClass)rasterClass
{
    NSError *ignored = nil;
    if (!_interpreterModule) {
        _interpreterModule = [NV2AMetalShaderLibrary
            sharedWithDevice:_device source:nv2a_pixel_interpreter_source
                       error:&ignored];
        if (!_interpreterModule)
            return nil;
    }
    if (!_interpreterPipelines) {
        _interpreterPipelines = [[NV2AMetalLRUCache alloc] initWithCapacity:16];
        if (!_interpreterPipelines)
            return nil;
    }
    NV2AMetalFragmentPipelineKey generic = *key;
    generic.control = 0;
    memset(generic.finalInputs, 0,
           sizeof(generic) - offsetof(NV2AMetalFragmentPipelineKey, finalInputs));
    NSData *lookup = [NSData dataWithBytes:&generic length:sizeof(generic)];
    if (!lookup)
        return nil;
    id<MTLRenderPipelineState> pipeline = _interpreterPipelines[lookup];
    if (!pipeline) {
        MTL4RenderPipelineDescriptor *pd = [self
            newPipelineDescriptorForTopology:topology drawState:state
                                 postprocess:postprocess fragmentKey:&generic
                                 rasterClass:rasterClass
                                     library:_interpreterModule.library
                                 interpreter:YES error:&ignored];
        if (!pd)
            return nil;
        @synchronized(_interpreterModule.compiler) {
            pipeline = [_interpreterModule.compiler
                newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil
                                               error:&ignored];
        }
        if (!pipeline)
            return nil;
        _interpreterPipelines[lookup] = pipeline;
    }
    return pipeline;
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
    return [self initWithDevice:device
                    colorFormat:colorFormat
                    depthFormat:depthFormat
                    sampleCount:sampleCount
                surfaceChannels:surfaceChannels
                  pipelineCache:nil
                          error:error];
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                        surfaceChannels:(unsigned int)surfaceChannels
                          pipelineCache:(NV2AMetalLRUCache *)cache
                                  error:(NSError **)error
{
    return [self initWithDevice:device colorFormat:colorFormat
                    depthFormat:depthFormat sampleCount:sampleCount
                surfaceChannels:surfaceChannels pipelineCache:cache
               pipelineCompiler:nil error:error];
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                        surfaceChannels:(unsigned int)surfaceChannels
                          pipelineCache:(NV2AMetalLRUCache *)cache
                       pipelineCompiler:(NV2AMetalPipelineCompiler *)compiler
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
    if (compiler && compiler.device == device) {
        _pipelineCompiler = compiler;
        _canonicalLibrary = _library;
    }
    _fragmentPipelines = cache ?:
        [[NV2AMetalLRUCache alloc] initWithCapacity:256];
    _fragmentLookupKey =
        [NSMutableData dataWithLength:sizeof(NV2AMetalFragmentPipelineKey)];

    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 7;
    ad.maxTextureBindCount = 12;
    ad.maxSamplerStateBindCount = 4;
    ad.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:ad error:error];
    if (!_arguments) {
        pixel_error(error, @"Could not allocate Metal pixel pipeline resources");
        return nil;
    }
    _fallbacks = [NV2AMetalPixelFallbacks sharedWithDevice:device error:error];
    if (!_fallbacks)
        return nil;
    return self;
}

- (id<MTLRenderPipelineState>)pipelineForCombiner:(const NV2AMetalCombinerState *)c
                                        topology:(unsigned)topology
                                       drawState:(NV2AMetalDrawState *)drawState
                                     rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                               polygonProjection:(BOOL)polygonProjection
                                      sharedPass:(BOOL)sharedPass
                                        commands:(NV2AMetalCommands *)commands
                                           error:(NSError **)error
{
    BOOL hasColorState = drawState && _colorFormat != MTLPixelFormatInvalid;
    NV2AMetalPixelPostprocess postprocess = NV2AMetalPixelPostprocessNone;
    if (hasColorState && _colorFormat != MTLPixelFormatRGBA32Float &&
        (drawState.logicEnabled || drawState.ditherEnabled ||
         (_surfaceChannels >= NV2AMetalSurfaceStorageZ1 &&
          (drawState.blendWord & NV_PGRAPH_BLEND_EN)))) {
        unsigned logic = drawState.logicOperation;
        /* CLEAR, COPY, COPY_INVERTED and SET ignore the old destination.
         * Dither and packed-alpha output need it only for shader blending. */
        BOOL destination = drawState.logicEnabled ?
            !(logic == 0 || logic == 3 || logic == 12 || logic == 15) :
            blend_reads_destination(drawState.blendWord, _surfaceChannels);
        postprocess = destination ? NV2AMetalPixelPostprocessDestination :
                                    NV2AMetalPixelPostprocessSource;
    }
    NSUInteger attachmentKey = hasColorState ? drawState.pipelineKey : 0;
    /* Postprocessing uses uniforms for logic, dither and blend.
     * Only the entry point and actual native attachment state select a
     * pipeline. A depth-only pass has no color state. */
    if (postprocess != NV2AMetalPixelPostprocessNone)
        attachmentKey &= ~(((NSUInteger)1 <<
                            NV2AMetalDrawPipelineWriteMaskShift) - 1);
    const uint64_t raster[] = {
        attachmentKey, topology,
        hasColorState | postprocess << 1 | polygonProjection << 3, rasterClass
    };
    BOOL sameProgram = sharedPass && _preparedProgramValid &&
                       !memcmp(c, _preparedProgram, sizeof(_preparedProgram));
    NV2AMetalFragmentPipelineKey fragmentKey;
    if (sameProgram) {
        for (unsigned i = 0; i < _preparedPipelineCount; i++) {
            if (!memcmp(_preparedRasterKeys[i], raster, sizeof(raster)))
                return _preparedPipelines[i];
        }
        fragmentKey = _preparedFragmentKey;
    } else {
        /* Preserve the complete guest program in uniforms. Canonicalize
         * only the fields that can change Metal function constants. */
        fragmentKey = (NV2AMetalFragmentPipelineKey){
            .control = pixel_combiner_control(c),
            .program = c->shader_stage_program & ((1u << 20) - 1),
            .finalInputs = { c->final_inputs[0], pixel_combiner_final_input(c) },
        };
        pixel_combiner_words(c, fragmentKey.words);
        if (sharedPass) {
            memcpy(_preparedProgram, c, sizeof(_preparedProgram));
            _preparedFragmentKey = fragmentKey;
            _preparedProgramValid = YES;
            _preparedPipelineCount = 0;
        }
    }
    memcpy(fragmentKey.raster, raster, sizeof(raster));
    [_fragmentLookupKey replaceBytesInRange:NSMakeRange(0, sizeof(fragmentKey))
                                 withBytes:&fragmentKey];
    id<MTLRenderPipelineState> pipeline = _fragmentPipelines[_fragmentLookupKey];
    if (!pipeline) {
        BOOL specialized = YES;
        /* A library override belongs to the old synchronous API. The optional
         * route is valid only for the exact original constructor library. */
        if (_pipelineCompiler && _canonicalLibrary &&
            _library == _canonicalLibrary &&
            _sharedLibrary.library == _canonicalLibrary) {
            NV2AMetalPixelPipelineRecipe recipe = { 0 };
            recipe.recipeVersion = 1;
            recipe.libraryIdentity = (uint64_t)(uintptr_t)
                (__bridge const void *)_canonicalLibrary;
            recipe.colorFormat = _colorFormat;
            recipe.depthFormat = _depthFormat;
            recipe.sampleCount = _sampleCount;
            recipe.surfaceChannels = _surfaceChannels;
            recipe.fragment = fragmentKey;
            NSData *recipeKey = [NSData dataWithBytes:&recipe length:sizeof(recipe)];
            if (recipeKey)
                pipeline = [_pipelineCompiler readyPipelineForKey:recipeKey];
            if (!pipeline) {
                pipeline = [self interpreterPipelineForTopology:topology
                    drawState:drawState postprocess:postprocess
                    fragmentKey:&fragmentKey rasterClass:rasterClass];
                if (pipeline) {
                    specialized = NO;
                    if (recipeKey) {
                        const NV2AMetalFragmentPipelineKey captured = fragmentKey;
                        /* The builder is called synchronously or not at all.
                         * Only its fresh descriptor graph escapes to the job;
                         * no worker retains this block/self/drawState. */
                        [_pipelineCompiler requestPipelineForKey:recipeKey
                            library:_canonicalLibrary descriptorBuilder:^{
                                NSError *ignored = nil;
                                return [self newPipelineDescriptorForTopology:topology
                                    drawState:drawState postprocess:postprocess
                                    fragmentKey:&captured rasterClass:rasterClass
                                    library:_canonicalLibrary interpreter:NO
                                    error:&ignored];
                            }];
                    }
                    /* An optional request rejection/failure must keep this
                     * valid generic pipeline; never add a main-thread stall. */
                }
            }
        }
        if (!pipeline) {
            pipeline = [self newPipelineForTopology:topology
                                          drawState:drawState
                                        postprocess:postprocess
                                        fragmentKey:&fragmentKey
                                        rasterClass:rasterClass
                                              error:error];
            if (!pipeline)
                return nil;
        }
        if (specialized) {
            /* Each shared cache entry owns an immutable key. */
            NSData *key = [NSData dataWithBytes:&fragmentKey length:sizeof(fragmentKey)];
            _fragmentPipelines[key] = pipeline;
        }
    }
    /* Entries in the preparation cache already belong to this recording. */
    if (![commands keepAlive:pipeline error:error])
        return nil;
    if (sharedPass && _preparedPipelineCount <
                          sizeof(_preparedPipelines) / sizeof(*_preparedPipelines)) {
        unsigned i = _preparedPipelineCount++;
        memcpy(_preparedRasterKeys[i], raster, sizeof(raster));
        _preparedPipelines[i] = pipeline;
    }
    return pipeline;
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
    BOOL compactLine = geometry.compactLines;
    BOOL compactFill = geometry.compactPolygons;
    BOOL compact = compactLine || compactFill;
    BOOL mappedTriangle =
        geometry.directTriangles &&
        (geometry.directTriangleOptions & NV2AMetalDirectTriangleTopologyMask);
    BOOL mappedLine =
        geometry.directLineMode &&
        (geometry.directLineOptions & NV2AMetalDirectLineTopologyMask);
    BOOL mappedQuad = geometry.directQuadOptions != 0;
    BOOL mappedPolygon = geometry.directPolygonOptions != 0;
    unsigned quadMode =
        geometry.directQuadOptions & NV2AMetalDirectQuadModeMask;
    BOOL quadPoint = quadMode == NV2AMetalDirectQuadPoint;
    BOOL quadLine = quadMode == NV2AMetalDirectQuadLine;
    NSUInteger perQuad = quadPoint ? 4 : 8;
    unsigned polygonMode =
        geometry.directPolygonOptions & NV2AMetalDirectPolygonModeMask;
    BOOL polygonPoint = polygonMode == NV2AMetalDirectPolygonPoint;
    BOOL polygonLine = polygonMode == NV2AMetalDirectPolygonLine;
    BOOL genuineFill =
        geometry.directTriangles &&
        (geometry.directTriangleOptions &
         NV2AMetalDirectTriangleTopologyMask) == NV2AMetalDirectTrianglePolygon;
    BOOL genuineWire = mappedPolygon && (geometry.directPolygonOptions &
                                         NV2AMetalDirectTriangleTopologyMask) ==
                                            NV2AMetalDirectTrianglePolygon;
    BOOL genuinePolygon = genuineFill || genuineWire;
    NSUInteger perPolygon = genuineWire ? 2 : polygonPoint ? 3 : 6;
    BOOL mapped =
        compact || mappedTriangle || mappedLine || mappedQuad || mappedPolygon;
    unsigned lineTopology =
        geometry.directLineOptions & NV2AMetalDirectLineTopologyMask;
    NSUInteger lineSegments = geometry.vertexCount / 6;
    enum NV2AMetalPrimitive sourcePrimitive = geometry.sourcePrimitive;
    BOOL compactPolygon = compactLine &&
                          sourcePrimitive >= NV2AMetalPrimitiveTriangles &&
                          sourcePrimitive <= NV2AMetalPrimitivePolygon;
    BOOL compactSourceValid =
        compactPolygon || (sourcePrimitive >= NV2AMetalPrimitiveLines &&
                           sourcePrimitive <= NV2AMetalPrimitiveLineStrip);
    BOOL compactQuad = sourcePrimitive == NV2AMetalPrimitiveQuads ||
                       sourcePrimitive == NV2AMetalPrimitiveQuadStrip;
    NSUInteger compactEdges =
        compactPolygon && sourcePrimitive != NV2AMetalPrimitivePolygon ?
            (compactQuad ? 4 : 3) :
            1;
    NSUInteger compactGroups = lineSegments / compactEdges;
    unsigned compactLineTopology =
        sourcePrimitive == NV2AMetalPrimitiveLineStrip ?
            NV2AMetalDirectLineStrip :
        sourcePrimitive == NV2AMetalPrimitiveLineLoop ?
            NV2AMetalDirectLineLoop :
            0;
    NSUInteger compactSources =
        !lineSegments                                  ? 0 :
        sourcePrimitive == NV2AMetalPrimitiveLines     ? lineSegments * 2 :
        sourcePrimitive == NV2AMetalPrimitiveLineStrip ? lineSegments + 1 :
        sourcePrimitive == NV2AMetalPrimitiveLineLoop ||
                sourcePrimitive == NV2AMetalPrimitivePolygon ?
                                                         lineSegments :
        sourcePrimitive == NV2AMetalPrimitiveTriangles ? compactGroups * 3 :
        sourcePrimitive == NV2AMetalPrimitiveQuads     ? compactGroups * 4 :
        sourcePrimitive == NV2AMetalPrimitiveQuadStrip ? compactGroups * 2 + 2 :
                                                         compactGroups + 2;
    NSUInteger polygonCarriers = geometry.vertexCount / 6;
    NSUInteger polygonGroups =
        compactQuad ? polygonCarriers / 2 : polygonCarriers;
    NSUInteger polygonSources =
        !polygonCarriers                               ? 0 :
        sourcePrimitive == NV2AMetalPrimitiveTriangles ? polygonCarriers * 3 :
        sourcePrimitive == NV2AMetalPrimitiveQuads     ? polygonGroups * 4 :
        sourcePrimitive == NV2AMetalPrimitiveQuadStrip ? polygonGroups * 2 + 2 :
                                                         polygonCarriers + 2;
    unsigned expectedRaster =
        compactFill ?
            NV2AMetalPixelRasterCompactPolygon :
        compactLine ?
            NV2AMetalPixelRasterCompactLine :
        mappedPolygon ?
            NV2AMetalPixelRasterDirectTriangle | geometry.directPolygonOptions :
        mappedQuad ?
            NV2AMetalPixelRasterDirectTriangle | geometry.directQuadOptions :
        mappedTriangle ?
            NV2AMetalPixelRasterDirectTriangle |
                geometry.directTriangleOptions :
            NV2AMetalPixelRasterDirectMappedLine | geometry.directLineOptions;
    if (!geometry || offset % sizeof(NV2AMetalVertex) ||
        (geometry.directTriangles &&
         rasterClass != (NV2AMetalPixelRasterDirectTriangle |
                         geometry.directTriangleOptions)) ||
        offset / sizeof(NV2AMetalVertex) > geometry.vertexCount ||
        count > geometry.vertexCount - offset / sizeof(NV2AMetalVertex) ||
        (compactFill &&
         (![geometry canUsePolygonCoverageForCommands:commands] ||
          compactLine || geometry.directPoints || geometry.directTriangles ||
          geometry.directLineMode || geometry.directLineOptions ||
          geometry.directTriangleOptions || mappedQuad || mappedPolygon ||
          geometry.expandedLines || !geometry.expandedPolygons ||
          geometry.primitiveType != MTLPrimitiveTypeTriangle ||
          geometry.polygonMode != NV2AMetalPolygonFill ||
          sourcePrimitive < NV2AMetalPrimitiveTriangles ||
          sourcePrimitive > NV2AMetalPrimitivePolygon ||
          geometry.vertexCount > UINT32_MAX || geometry.vertexCount % 6 ||
          (compactQuad && polygonCarriers % 2) ||
          geometry.verticesPerPrimitive != (compactQuad ? 12 : 6) ||
          geometry.primitiveCount != polygonGroups ||
          geometry.sourceVertexCount != polygonSources ||
          (!geometry.indexedVertices &&
           geometry.physicalVertexCount != polygonSources) ||
          (geometry.vertexCount &&
           (!geometry.polygonCoverage ||
            geometry.polygonCoverage.device != _device ||
            geometry.polygonCoverage.storageMode != MTLStorageModePrivate ||
            geometry.polygonCoverage.length !=
                polygonCarriers * sizeof(NV2AMetalCompactPolygon) ||
            geometry.polygonProjections.device != _device ||
            geometry.polygonProjections.storageMode != MTLStorageModePrivate ||
            geometry.polygonProjections.length !=
                polygonCarriers * sizeof(NV2AMetalPolygonProjection))) ||
          (!geometry.vertexCount &&
           (geometry.polygonCoverage || geometry.polygonProjections)))) ||
        (!compactFill && geometry.polygonCoverage) ||
        (compactLine &&
         (![geometry canUseLineCoverageForCommands:commands] ||
          geometry.directPoints || geometry.directTriangles ||
          geometry.directLineMode || mappedQuad || mappedPolygon ||
          geometry.expandedPolygons || !geometry.expandedLines ||
          geometry.primitiveType != MTLPrimitiveTypeTriangle ||
          geometry.polygonMode !=
              (compactPolygon ? NV2AMetalPolygonLine : NV2AMetalPolygonFill) ||
          !compactSourceValid || geometry.vertexCount > UINT32_MAX ||
          geometry.vertexCount % 6 || lineSegments % compactEdges ||
          geometry.verticesPerPrimitive != 6 * compactEdges ||
          geometry.primitiveCount != compactGroups ||
          (compactPolygon ?
               geometry.directLineOptions != 0 :
               (geometry.directLineOptions & ~NV2AMetalDirectLineMask) != 0) ||
          lineTopology != compactLineTopology ||
          ((sourcePrimitive == NV2AMetalPrimitivePolygon ||
            sourcePrimitive == NV2AMetalPrimitiveLineLoop) &&
           lineSegments == 1) ||
          geometry.sourceVertexCount != compactSources ||
          (!geometry.indexedVertices &&
           geometry.physicalVertexCount != compactSources) ||
          (geometry.vertexCount &&
           (!geometry.lineCoverage || geometry.lineCoverage.device != _device ||
            geometry.lineCoverage.storageMode != MTLStorageModePrivate ||
            geometry.lineCoverage.length !=
                lineSegments * sizeof(NV2AMetalCompactLine))) ||
          (!geometry.vertexCount && geometry.lineCoverage))) ||
        (!compactLine && geometry.lineCoverage) ||
        (genuinePolygon && geometry.vertexCount &&
         (!geometry.polygonFacing || geometry.polygonFacing.device != _device ||
          geometry.polygonFacing.length != sizeof(uint32_t) ||
          geometry.polygonFacing.storageMode != MTLStorageModePrivate)) ||
        ((!genuinePolygon || !geometry.vertexCount) &&
         geometry.polygonFacing) ||
        (geometry.indexedVertices &&
         (geometry.vertices != geometry.indexedVertices.vertices ||
          geometry.physicalVertexCount !=
              geometry.indexedVertices.physicalVertexCount ||
          geometry.physicalVertexCount >
              geometry.vertices.length / sizeof(NV2AMetalVertex) ||
          geometry.indexOffset > geometry.indexedVertices.vertexCount ||
          geometry.sourceVertexCount >
              geometry.indexedVertices.vertexCount - geometry.indexOffset ||
          !(compact || geometry.directPoints || geometry.directTriangles ||
            geometry.directLineMode || mappedQuad || mappedPolygon))) ||
        (!geometry.indexedVertices &&
         (geometry.firstVertex >
              geometry.vertices.length / sizeof(NV2AMetalVertex) ||
          geometry.sourceVertexCount >
              geometry.vertices.length / sizeof(NV2AMetalVertex) -
                  geometry.firstVertex)) ||
        (genuineFill &&
         (geometry.directPoints || geometry.directLineMode || mappedQuad ||
          mappedPolygon || geometry.expandedLines ||
          geometry.expandedPolygons || geometry.vertexCount % 3 ||
          geometry.verticesPerPrimitive != 3 ||
          geometry.primitiveCount != geometry.vertexCount / 3 ||
          geometry.sourceVertexCount !=
              pixel_source_vertex_count(rasterClass, geometry.vertexCount) ||
          geometry.primitiveType != MTLPrimitiveTypeTriangle ||
          geometry.polygonMode != NV2AMetalPolygonFill)) ||
        (mappedQuad &&
         ((!quadPoint && !quadLine) || geometry.directPoints ||
          geometry.directTriangles || geometry.directLineMode ||
          mappedPolygon || geometry.expandedLines ||
          geometry.expandedPolygons || geometry.vertexCount % perQuad ||
          geometry.verticesPerPrimitive != perQuad ||
          geometry.primitiveCount != geometry.vertexCount / perQuad ||
          geometry.sourceVertexCount !=
              pixel_source_vertex_count(expectedRaster, geometry.vertexCount) ||
          geometry.primitiveType !=
              (quadPoint ? MTLPrimitiveTypePoint : MTLPrimitiveTypeLine) ||
          geometry.polygonMode !=
              (quadPoint ? NV2AMetalPolygonPoint : NV2AMetalPolygonLine))) ||
        (mappedPolygon &&
         ((!polygonPoint && !polygonLine) || geometry.directPoints ||
          geometry.directTriangles || geometry.directLineMode || mappedQuad ||
          geometry.expandedLines || geometry.expandedPolygons ||
          geometry.vertexCount % perPolygon ||
          geometry.verticesPerPrimitive != perPolygon ||
          geometry.primitiveCount != geometry.vertexCount / perPolygon ||
          geometry.sourceVertexCount !=
              pixel_source_vertex_count(expectedRaster, geometry.vertexCount) ||
          geometry.primitiveType !=
              (polygonPoint ? MTLPrimitiveTypePoint : MTLPrimitiveTypeLine) ||
          geometry.polygonMode !=
              (polygonPoint ? NV2AMetalPolygonPoint : NV2AMetalPolygonLine))) ||
        (mapped &&
         ((!compact && count % (mappedPolygon  ? (polygonPoint ? 1 : 2) :
                                mappedQuad     ? (quadPoint ? 1 : 2) :
                                mappedTriangle ? 3 :
                                                 2)) ||
          rasterClass != expectedRaster)) ||
        (geometry.expandedPolygons && !compactFill && geometry.firstVertex) ||
        !drawState || drawState.device != _device ||
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
    NV2AMetalPixelDraw *prepared = [self
             prepareVertices:geometry.vertices
                      offset:geometry.indexedVertices ? 0 :
                             geometry.firstVertex * sizeof(NV2AMetalVertex) +
                                         (mapped ? 0 : offset)count:mapped &&
                                     count ?
                                                        geometry.vertexCount :
                                                        count
                   primitive:geometry.primitiveType
                    uniforms:uniforms
                    textures:textures
                        pass:pass
                depthStencil:drawState.depthStencil
                   drawState:drawState
                 rasterClass:rasterClass
          polygonProjections:geometry.polygonProjections
               polygonFacing:geometry.polygonFacing
              rasterCoverage:compactFill ? geometry.polygonCoverage :
                                           geometry.lineCoverage
        sourceVertexCapacity:compact ? geometry.physicalVertexCount : 0
             indexedVertices:geometry.indexedVertices
                 indexOffset:geometry.indexOffset +
                             (mapped ? 0 : offset / sizeof(NV2AMetalVertex))
        ignorePolygonCulling:ignore
                    commands:commands
                       error:error];
    if (prepared && mapped) {
        /* Keep fan anchors, strip parity and loop closure on the full source;
         * the packet's draw IDs select the requested generated slice. */
        prepared->_firstVertex = offset / sizeof(NV2AMetalVertex);
        prepared->_vertexCount = count;
    }
    if (prepared) {
        prepared->_rangeAlignment = geometry.verticesPerPrimitive;
        prepared->_groupFirstVertex = offset / sizeof(NV2AMetalVertex);
    }
    return prepared;
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
    return [self prepareVertices:vertices
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
                   polygonFacing:nil
                  rasterCoverage:nil
            sourceVertexCapacity:0
                 indexedVertices:nil
                     indexOffset:0
            ignorePolygonCulling:ignore
                        commands:commands
                           error:error];
}
- (NV2AMetalPixelDraw *)
         prepareVertices:(id<MTLBuffer>)vertices
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
           polygonFacing:(nullable id<MTLBuffer>)facing
          rasterCoverage:(nullable id<MTLBuffer>)coverage
    sourceVertexCapacity:(NSUInteger)sourceCapacity
         indexedVertices:(nullable NV2AMetalIndexedVertices *)indexed
             indexOffset:(NSUInteger)indexOffset
    ignorePolygonCulling:(BOOL)ignore
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    BOOL directTriangle = (rasterClass & ~NV2AMetalDirectTriangleMask) ==
                          NV2AMetalPixelRasterDirectTriangle;
    BOOL mappedLine = (rasterClass & ~NV2AMetalDirectLineMask) ==
                      NV2AMetalPixelRasterDirectMappedLine;
    unsigned lineTopology = rasterClass & NV2AMetalDirectLineTopologyMask;
    unsigned triangleTopology =
        rasterClass & NV2AMetalDirectTriangleTopologyMask;
    BOOL quads = triangleTopology == NV2AMetalDirectTriangleQuads ||
                 triangleTopology == NV2AMetalDirectTriangleQuadStrip;
    unsigned quadMode = rasterClass & NV2AMetalDirectQuadModeMask;
    BOOL directQuad = directTriangle && quadMode;
    BOOL quadPoint = quadMode == NV2AMetalDirectQuadPoint;
    unsigned polygonMode = rasterClass & NV2AMetalDirectPolygonModeMask;
    BOOL directPolygon = directTriangle && polygonMode;
    BOOL polygonPoint = polygonMode == NV2AMetalDirectPolygonPoint;
    BOOL genuinePolygon =
        directTriangle && triangleTopology == NV2AMetalDirectTrianglePolygon;
    BOOL compactLine = rasterClass == NV2AMetalPixelRasterCompactLine;
    BOOL compactFill = rasterClass == NV2AMetalPixelRasterCompactPolygon;
    BOOL compact = compactLine || compactFill;
    NSUInteger coverageStride = compactFill ? sizeof(NV2AMetalCompactPolygon) :
                                              sizeof(NV2AMetalCompactLine);
    if ((rasterClass > NV2AMetalPixelRasterDirectLineFlatLast &&
         !directTriangle && !mappedLine && !compact) ||
        (compact &&
         (!coverage || coverage.device != _device ||
          coverage.storageMode != MTLStorageModePrivate ||
          coverage.length % coverageStride ||
          (count &&
           (count % 6 || coverage.length != count / 6 * coverageStride)) ||
          primitive != MTLPrimitiveTypeTriangle || !sourceCapacity ||
          sourceCapacity > UINT32_MAX ||
          sourceCapacity > (vertices.length - MIN(offset, vertices.length)) /
                               sizeof(NV2AMetalVertex) ||
          (indexed && sourceCapacity != indexed.physicalVertexCount))) ||
        (!compact && (coverage || sourceCapacity)) ||
        (directTriangle && !directQuad && !directPolygon &&
         (primitive != MTLPrimitiveTypeTriangle || count % (quads ? 6 : 3) ||
          (triangleTopology &&
           triangleTopology != NV2AMetalDirectTriangleStrip &&
           triangleTopology != NV2AMetalDirectTriangleFan && !quads &&
           !genuinePolygon))) ||
        (directQuad &&
         ((quadMode != NV2AMetalDirectQuadPoint &&
           quadMode != NV2AMetalDirectQuadLine) ||
          !quads || polygonMode ||
          (rasterClass & NV2AMetalDirectTriangleFirst) ||
          (!quadPoint && (rasterClass & NV2AMetalDirectTriangleWDepth)) ||
          primitive !=
              (quadPoint ? MTLPrimitiveTypePoint : MTLPrimitiveTypeLine) ||
          count % (quadPoint ? 4 : 8))) ||
        (directPolygon &&
         ((polygonMode != NV2AMetalDirectPolygonPoint &&
           polygonMode != NV2AMetalDirectPolygonLine) ||
          quadMode ||
          (triangleTopology &&
           triangleTopology != NV2AMetalDirectTriangleStrip &&
           triangleTopology != NV2AMetalDirectTriangleFan && !genuinePolygon) ||
          (!polygonPoint && (rasterClass & NV2AMetalDirectTriangleWDepth)) ||
          (genuinePolygon && (polygonPoint || (count && count < 4))) ||
          primitive !=
              (polygonPoint ? MTLPrimitiveTypePoint : MTLPrimitiveTypeLine) ||
          count % (genuinePolygon ? 2 :
                   polygonPoint   ? 3 :
                                    6))) ||
        (genuinePolygon &&
         ((rasterClass & NV2AMetalDirectTriangleFirst) || !facing ||
          facing.device != _device || facing.length != sizeof(uint32_t) ||
          facing.storageMode != MTLStorageModePrivate)) ||
        (!genuinePolygon && facing) ||
        (mappedLine &&
         (primitive != MTLPrimitiveTypeLine || count % 2 ||
          (lineTopology != NV2AMetalDirectLineStrip &&
           lineTopology != NV2AMetalDirectLineLoop) ||
          (lineTopology == NV2AMetalDirectLineLoop && count && count < 4))) ||
        (rasterClass == NV2AMetalPixelRasterDirectPoint &&
         primitive != MTLPrimitiveTypePoint) ||
        (rasterClass >= NV2AMetalPixelRasterDirectLineSmooth &&
         rasterClass <= NV2AMetalPixelRasterDirectLineFlatLast &&
         (primitive != MTLPrimitiveTypeLine || count % 2)) ||
        !commands.commandBuffer || commands.device != _device ||
        vertices.device != _device || offset > vertices.length ||
        offset % sizeof(NV2AMetalVertex) ||
        (indexed && (vertices != indexed.vertices || offset ||
                     indexed.indices.device != _device ||
                     indexOffset > indexed.vertexCount ||
                     rasterClass < NV2AMetalPixelRasterDirectPoint)) ||
        (!compact && pixel_source_vertex_count(rasterClass, count) >
                         (indexed ? indexed.vertexCount - indexOffset :
                                    (vertices.length - offset) /
                                        sizeof(NV2AMetalVertex))) ||
        count > UINT32_MAX || primitive > MTLPrimitiveTypeTriangleStrip ||
        !textures || !nv2a_metal_pixel_validate(uniforms, error)) {
        pixel_error(error, @"Invalid Metal pixel draw input or state");
        return nil;
    }
    if (projections &&
        ((rasterClass != NV2AMetalPixelRasterExpandedPolygon && !compactFill) ||
         primitive != MTLPrimitiveTypeTriangle || count % 6 ||
         (!compactFill && offset % (6 * sizeof(NV2AMetalVertex))) ||
         projections.device != _device ||
         ((compactFill ? 0 : offset / sizeof(NV2AMetalVertex)) + count) / 6 >
             projections.length / sizeof(NV2AMetalPolygonProjection))) {
        pixel_error(error, @"Invalid polygon projection slice");
        return nil;
    }
    BOOL sharedPass = pass && pass == _preparationPass &&
                      commands == _preparationCommands &&
                      commands.recordingSerial == _preparationSerial;
    BOOL checkPass = !sharedPass || !_preparationValidated;
    if (checkPass && pass.visibilityResultBuffer &&
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
    if (depthStencil && depthStencil.device != _device) {
        pixel_error(error, @"Invalid Metal pixel render attachments");
        return nil;
    }
    if (checkPass) {
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
        if (sharedPass)
            _preparationValidated = YES;
    }
    MTLTextureType sampledTypes[4];
    for (unsigned i = 0; i < 4; i++) {
        unsigned mode =
            (uniforms->combiner.shader_stage_program >> (5 * i)) & 31;
        MTLTextureType type = texture_type(mode, &uniforms->textures[i],
                                           !uniforms->legacy_spec_const);
        sampledTypes[i] = type;
        if (type == MTLTextureType1D) {
            continue;
        }
        id<MTLTexture> tex = textures[i].texture;
        id<MTLSamplerState> sampler = textures[i].sampler;
        unsigned normalization = uniforms->textures[i].snorm;
        BOOL hilo16 = !!(uniforms->hilo16_mask & (1u << i));
        /* A successful check belongs to this stage, resource pair and
         * immutable attachment set. A different requirement checks again. */
        if (sharedPass && tex && tex == _checkedTextures[i] &&
            sampler == _checkedSamplers[i] && type == _sampleChecks[i].type &&
            normalization == _sampleChecks[i].normalization &&
            hilo16 == _sampleChecks[i].hilo16)
            continue;
        if (!tex || tex.device != _device || tex.textureType != type ||
            tex.sampleCount != 1 || !(tex.usage & MTLTextureUsageShaderRead) ||
            !sampleable(tex.pixelFormat) ||
            (normalization == NV2AMetalTextureNormalizationMixedHalf &&
             tex.pixelFormat != MTLPixelFormatRGBA16Float) ||
            (hilo16 &&
             tex.pixelFormat != MTLPixelFormatRGBA32Float &&
             tex.pixelFormat != MTLPixelFormatRG32Float) ||
            alias(tex, color) || alias(tex, depth) || alias(tex, resolve) ||
            (sampler && sampler.device != _device)) {
            pixel_error(error,
                        @"Invalid Metal pixel texture or feedback alias");
            return nil;
        }
        if (sharedPass) {
            _registeredSampleMask &= ~(1u << i);
            _checkedTextures[i] = tex;
            _checkedSamplers[i] = sampler;
            _sampleChecks[i] = (NV2AMetalPixelSampleCheck){
                type, normalization, hilo16
            };
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
    NV2AMetalPixelConstants storage = {
        .uniforms = snapshot,
        .info = { _surfaceChannels, projections ? (unsigned)(count / 6) : 0,
                  (unsigned)sourceCapacity },
    };
    MTLGPUAddress constants = [self addressForConstants:&storage
                                               commands:commands
                                                  error:error];
    if (!constants)
        return nil;
    if (![commands addResource:vertices error:error] ||
        (indexed && (![commands addResource:indexed.indices error:error] ||
                     ![commands keepAlive:indexed error:error])) ||
        (projections && ![commands addResource:projections error:error])) {
        return nil;
    }
    if (facing && ![commands addResource:facing error:error])
        return nil;
    if (coverage && ![commands addResource:coverage error:error])
        return nil;
    /* A live recording retains the pass resources. Mark the shared set
     * only after every registration succeeds. */
    if (!sharedPass || !_preparationResourcesRegistered) {
        if ((color && ![commands addResource:color error:error]) ||
            (resolve && ![commands addResource:resolve error:error]) ||
            (depth && ![commands addResource:depth error:error]) ||
            (pass.visibilityResultBuffer &&
             ![commands addResource:pass.visibilityResultBuffer error:error]) ||
            ![commands addResource:_fallbacks.dummy2D error:error] ||
            ![commands addResource:_fallbacks.dummy3D error:error] ||
            ![commands addResource:_fallbacks.dummyCube error:error] ||
            ![commands keepAlive:self error:error]) {
            return nil;
        }
        if (sharedPass)
            _preparationResourcesRegistered = YES;
    }
    if (depthStencil && (!sharedPass || depthStencil != _retainedDepthStencil)) {
        if (![commands keepAlive:depthStencil error:error])
            return nil;
        if (sharedPass)
            _retainedDepthStencil = depthStencil;
    }
    prepared->_bindings = _fallbacks.bindings;
    prepared->_bindings.addresses[0] = vertices.gpuAddress + offset;
    prepared->_bindings.addresses[4] =
        indexed && !compact ?
            indexed.indices.gpuAddress + indexOffset * sizeof(uint32_t) :
            0;
    prepared->_bindings.addresses[5] = facing ? facing.gpuAddress : 0;
    prepared->_bindings.addresses[6] = coverage ? coverage.gpuAddress : 0;
    prepared->_bindings.addresses[1] = constants;
    prepared->_bindings.addresses[2] = constants + sizeof(snapshot);
    NSUInteger projectionOffset =
        (compactFill ? 0 : offset / (6 * sizeof(NV2AMetalVertex))) *
        sizeof(NV2AMetalPolygonProjection);
    prepared->_bindings.addresses[3] =
        projections ?
            projections.gpuAddress + projectionOffset :
            constants + offsetof(NV2AMetalPixelConstants, emptyProjection);
    for (unsigned i = 0; i < 4; i++) {
        MTLTextureType type = sampledTypes[i];
        if (type == MTLTextureType1D)
            continue;
        unsigned bit = 1u << i;
        NV2AMetalPixelSampleIDs ids;
        if (sharedPass && (_registeredSampleMask & bit)) {
            ids = _registeredSampleIDs[i];
        } else {
            id<MTLTexture> tex = textures[i].texture;
            id<MTLSamplerState> sampler = textures[i].sampler;
            BOOL customSampler = sampler && sampler != _fallbacks.sampler;
            /* The retained shader owns its default sampler. */
            if ((customSampler && ![commands keepAlive:sampler error:error]) ||
                ![commands addResource:tex error:error]) {
                return nil;
            }
            ids.texture = tex.gpuResourceID;
            ids.sampler = customSampler ? sampler.gpuResourceID :
                                          prepared->_bindings.samplers[i];
            if (sharedPass) {
                _registeredSampleIDs[i] = ids;
                _registeredSampleMask |= bit;
            }
        }
        unsigned base = type == MTLTextureType3D ? 4 :
                        type == MTLTextureTypeCube ? 8 : 0;
        prepared->_bindings.textures[base + i] = ids.texture;
        prepared->_bindings.samplers[i] = ids.sampler;
    }
    unsigned topology = primitive == MTLPrimitiveTypePoint ? 0 :
                        primitive == MTLPrimitiveTypeLine ||
                                primitive == MTLPrimitiveTypeLineStrip ?
                                                             1 :
                                                             2;
    id<MTLRenderPipelineState> pipeline =
        [self pipelineForCombiner:&uniforms->combiner topology:topology
                        drawState:drawState rasterClass:rasterClass |
                            (indexed ? NV2AMetalPixelRasterIndexed : 0)
                polygonProjection:storage.info.polygon_projection_count != 0
                       sharedPass:sharedPass commands:commands error:error];
    if (!pipeline)
        return nil;
    if (drawState && (!sharedPass || drawState != _retainedDrawState)) {
        if (![commands keepAlive:drawState error:error])
            return nil;
        if (sharedPass)
            _retainedDrawState = drawState;
    }
    prepared->_shader = self;
    prepared->_pipeline = pipeline;
    prepared->_depthStencil = depthStencil;
    prepared->_drawState = drawState;
    prepared->_primitive = primitive;
    prepared->_ignoreCulling = ignore;
    prepared->_width = target.width;
    prepared->_height = target.height;
    prepared->_vertexCount = count;
    prepared->_rangeAlignment = primitive == MTLPrimitiveTypePoint    ? 1 :
                                primitive == MTLPrimitiveTypeLine     ? 2 :
                                primitive == MTLPrimitiveTypeTriangle ? 3 :
                                                                        0;
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
