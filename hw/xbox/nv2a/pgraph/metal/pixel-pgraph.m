/* Native fragment/raster capture from glsl/psh.c, glsl/common.c and gl/draw.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "pixel-pgraph.h"

static BOOL capture_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pgraph-pixel"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}
static float register_float(PGRAPHState *pg, unsigned reg)
{
    uint32_t word = pgraph_reg_r(pg, reg);
    float value;
    memcpy(&value, &word, sizeof(value));
    return value;
}
static void rgba(uint32_t color, float output[4])
{
    output[0] = ((color >> 16) & 255) / 255.f;
    output[1] = ((color >> 8) & 255) / 255.f;
    output[2] = (color & 255) / 255.f;
    output[3] = (color >> 24) / 255.f;
}
_Static_assert(sizeof(NV2AMetalCombinerState) == 108 * 4 &&
                   sizeof(NV2AMetalTextureStage) == 38 * 4 &&
                   sizeof(NV2AMetalPixelUniforms) == 333 * 4 &&
                   offsetof(NV2AMetalPixelUniforms, eye_vector) == 327 * 4,
               "Pixel capture v6 scalar layout has no padding");
enum {
    PixelCaptureWords = 25,
    PixelCaptureLegacyWords = 23,
    PixelCaptureLegacyUniformWords = 323,
    PixelCaptureV3UniformWords = 327,
    PixelCaptureV4UniformWords = 331,
    PixelCaptureV5UniformWords = 332
};
typedef struct PixelCapture {
    NV2AMetalPixelUniforms uniforms;
    NV2AMetalDrawConfig raster;
    uint32_t textureMask, offsetMask, version;
    float offsetFactor, offsetBias;
} PixelCapture;
static void pixel_append_words(NSMutableData *data, const void *source,
                               size_t length)
{
    const uint8_t *bytes = source;
    for (size_t i = 0; i < length; i += 4) {
        uint32_t word;
        memcpy(&word, bytes + i, 4);
        uint8_t wire[] = { word >> 24, word >> 16, word >> 8, word };
        [data appendBytes:wire length:4];
    }
}
static void pixel_read_words(void *destination, const uint8_t *source,
                             size_t length)
{
    uint8_t *bytes = destination;
    for (size_t i = 0; i < length; i += 4) {
        uint32_t word = ldl_be_p(source + i);
        memcpy(bytes + i, &word, 4);
    }
}
/* v4 appends one mask to each texture stage. Legacy scalar records retain
 * their exact wire layout; never memcpy the shifted raster tail into v4. */
static void pixel_uniform_read(NV2AMetalPixelUniforms *u, const uint8_t *source,
                               unsigned version, size_t length)
{
    if (version >= 4) {
        pixel_read_words(u, source, length);
        return;
    }
    uint32_t old[PixelCaptureV3UniformWords] = { 0 };
    pixel_read_words(old, source, length);
    memcpy(&u->combiner, old, 108 * 4);
    for (unsigned i = 0; i < 4; i++) {
        memcpy(&u->textures[i], old + 108 + 37 * i, 37 * 4);
    }
    memcpy(u->fog_color, old + 256, length - 256 * 4);
}
static void pixel_uniform_append(NSMutableData *data,
                                 const NV2AMetalPixelUniforms *u,
                                 unsigned version, size_t length)
{
    if (version >= 4) {
        pixel_append_words(data, u, length);
        return;
    }
    uint32_t old[PixelCaptureV3UniformWords] = { 0 };
    memcpy(old, &u->combiner, 108 * 4);
    for (unsigned i = 0; i < 4; i++) {
        memcpy(old + 108 + 37 * i, &u->textures[i], 37 * 4);
    }
    memcpy(old + 256, u->fog_color, length - 256 * 4);
    pixel_append_words(data, old, length);
}

static BOOL pixel_decode(NSData *data, PixelCapture *capture, NSError **error)
{
    if (data.length < PixelCaptureLegacyWords * 4)
        return capture_error(error, @"Invalid pixel capture length");
    const uint8_t *bytes = data.bytes;
    unsigned version = (uint32_t)ldl_be_p(bytes + 4);
    size_t headerWords =
        version >= 2 ? PixelCaptureWords : PixelCaptureLegacyWords;
    size_t uniformBytes = version >= 6 ? sizeof(capture->uniforms) :
                          version == 5 ? PixelCaptureV5UniformWords * 4 :
                          version == 4 ? PixelCaptureV4UniformWords * 4 :
                          version == 3 ? PixelCaptureV3UniformWords * 4 :
                                         PixelCaptureLegacyUniformWords * 4;
    if ((version != 1 && version != 2 && version != 3 && version != 4 &&
         version != 5 && version != 6) ||
        data.length != headerWords * 4 + uniformBytes)
        return capture_error(error, @"Invalid pixel capture version or length");
    uint32_t words[PixelCaptureWords] = { 0 };
    pixel_read_words(words, bytes, headerWords * 4);
    if (words[0] != 0x4d345043 || words[2] != uniformBytes / 4 ||
        words[3] > 15 || words[4] > 7 || words[7] > 1 ||
        (version >= 2 && (!words[23] || !words[24])))
        return capture_error(error, @"Invalid pixel capture header");
    memset(capture, 0, sizeof(*capture));
    capture->version = version;
    capture->textureMask = words[3];
    capture->offsetMask = words[4];
    memcpy(&capture->offsetFactor, words + 5, 4);
    memcpy(&capture->offsetBias, words + 6, 4);
    NV2AMetalDrawConfig *r = &capture->raster;
    r->scissor_enabled = words[7];
    memcpy(r->control, words + 8, 12);
    r->blend = words[11];
    r->blend_color = words[12];
    r->setup_raster = words[13];
    r->antialiasing = words[14];
    r->viewport_width = words[23];
    r->viewport_height = words[24];
    r->scissor.x = (uint64_t)words[15] << 32 | words[16];
    r->scissor.y = (uint64_t)words[17] << 32 | words[18];
    r->scissor.width = (uint64_t)words[19] << 32 | words[20];
    r->scissor.height = (uint64_t)words[21] << 32 | words[22];
    if (r->scissor.x > INT32_MAX || r->scissor.y > INT32_MAX ||
        r->scissor.width > INT32_MAX || r->scissor.height > INT32_MAX ||
        !nv2a_metal_draw_config_validate(r, error))
        return capture_error(error, @"Invalid pixel capture raster");
    pixel_uniform_read(&capture->uniforms,
                       (const uint8_t *)data.bytes + headerWords * 4, version,
                       uniformBytes);
    NV2AMetalPixelUniforms *u = &capture->uniforms;
    if (version < 3 && ((u->combiner.shader_stage_program >> 15) & 31) ==
                           PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST)
        u->legacy_spec_const = 1;
    if ((u->hilo16_mask & ~capture->textureMask) || u->smooth_shading > 1 ||
        u->point_sprite > 1 || u->window_clip_exclusive > 1 ||
        u->depth_clipping > 1 || u->z_perspective > 1 || u->alpha_test > 1 ||
        u->vertex_capacity || u->logic_op || u->dither || u->blend)
        return capture_error(error, @"Invalid pixel capture flags");
    for (unsigned i = 0; i < 4; i++) {
        if (u->color_bits[i] || u->blend_color[i] != 0 ||
            (u->textures[i].sampling.enabled && !(words[3] & (1u << i))))
            return capture_error(error,
                                 @"Invalid pixel capture dispatch state");
    }
    if (version >= 5 &&
        u->two_side != !!(r->setup_raster & NV_PGRAPH_SETUPRASTER_TWO_SIDE))
        return capture_error(error, @"Pixel capture TwoSide/raster mismatch");
    return nv2a_metal_pixel_validate(u, error);
}

@interface NV2AMetalPGRAPHPixelState ()
- (instancetype)initWithState:(PGRAPHState *)pg
                     textures:(NV2AMetalPGRAPHTextureSnapshot *)textures
                       device:(id<MTLDevice>)device
                 frozenRaster:(NV2AMetalDrawState *)boundRaster
                        error:(NSError **)error;
@end
@implementation NV2AMetalPGRAPHPixelState {
    NV2AMetalPGRAPHTextureSnapshot *_textures;
    unsigned _offsetMask;
    float _offsetFactor, _offsetBias;
    unsigned _snapshotVersion;
}
/* Only a validated in-memory capture can use this clone. The public wire
 * initializer keeps its complete scalar/texture validation. */
- (instancetype)initWithCapture:(NV2AMetalPGRAPHPixelState *)source
                         config:(const NV2AMetalDrawConfig *)config
                         device:(id<MTLDevice>)device
                          error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    _raster = [[NV2AMetalDrawState alloc] initWithDevice:device
                                                  config:config
                                                   error:error];
    if (!_raster)
        return nil;
    _snapshotVersion = source->_snapshotVersion;
    _uniforms = source->_uniforms;
    _textures = source->_textures;
    _offsetMask = source->_offsetMask;
    _offsetFactor = source->_offsetFactor;
    _offsetBias = source->_offsetBias;
    return self;
}
- (instancetype)initWithState:(PGRAPHState *)pg
                     textures:(NV2AMetalPGRAPHTextureSnapshot *)textures
                       device:(id<MTLDevice>)device
                        error:(NSError **)error
{
    return [self initWithState:pg
                      textures:textures
                        device:device
                  frozenRaster:nil
                         error:error];
}
- (instancetype)initWithState:(PGRAPHState *)pg
                     textures:(NV2AMetalPGRAPHTextureSnapshot *)textures
                       device:(id<MTLDevice>)device
                 frozenRaster:(NV2AMetalDrawState *)boundRaster
                        error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!pg || !pg->surface_scale_factor || pg->surface_scale_factor > 16384 ||
        pg->surface_binding_dim.width <= 0 ||
        pg->surface_binding_dim.height <= 0 ||
        (unsigned)pg->surface_binding_dim.width >
            16384 / pg->surface_scale_factor ||
        (unsigned)pg->surface_binding_dim.height >
            16384 / pg->surface_scale_factor ||
        pg->surface_shape.anti_aliasing >
            NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4 ||
        pg->primitive_mode < PRIM_TYPE_POINTS ||
        pg->primitive_mode > PRIM_TYPE_POLYGON) {
        capture_error(error, @"Pixel capture requires prepared NV2A surfaces "
                             @"and a valid primitive");
        return nil;
    }
    _snapshotVersion = 6;
    unsigned control = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0);
    unsigned setup = pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.control = pgraph_reg_r(pg, NV_PGRAPH_COMBINECTL);
    if ((u.combiner.control & 255) > 8) {
        capture_error(error, @"Invalid NV2A combiner stage count");
        return nil;
    }
    u.combiner.shader_stage_program = pgraph_reg_r(pg, NV_PGRAPH_SHADERPROG);
    u.combiner.final_inputs[0] = pgraph_reg_r(pg, NV_PGRAPH_COMBINESPECFOG0);
    u.combiner.final_inputs[1] = pgraph_reg_r(pg, NV_PGRAPH_COMBINESPECFOG1);
    for (unsigned i = 0; i < (u.combiner.control & 255); i++) {
        u.combiner.rgb_inputs[i] =
            pgraph_reg_r(pg, NV_PGRAPH_COMBINECOLORI0 + i * 4);
        u.combiner.rgb_outputs[i] =
            pgraph_reg_r(pg, NV_PGRAPH_COMBINECOLORO0 + i * 4);
        u.combiner.alpha_inputs[i] =
            pgraph_reg_r(pg, NV_PGRAPH_COMBINEALPHAI0 + i * 4);
        u.combiner.alpha_outputs[i] =
            pgraph_reg_r(pg, NV_PGRAPH_COMBINEALPHAO0 + i * 4);
    }
    for (unsigned i = 0; i < 8; i++) {
        rgba(pgraph_reg_r(pg, NV_PGRAPH_COMBINEFACTOR0 + i * 4),
             u.combiner.constants[i * 2]);
        rgba(pgraph_reg_r(pg, NV_PGRAPH_COMBINEFACTOR1 + i * 4),
             u.combiner.constants[i * 2 + 1]);
    }
    rgba(pgraph_reg_r(pg, NV_PGRAPH_SPECFOGFACTOR0), u.combiner.constants[16]);
    rgba(pgraph_reg_r(pg, NV_PGRAPH_SPECFOGFACTOR1), u.combiner.constants[17]);
    rgba(pgraph_reg_r(pg, NV_PGRAPH_FOGCOLOR), u.fog_color);
    u.other_stage_input = pgraph_reg_r(pg, NV_PGRAPH_SHADERCTL);
    for (unsigned i = 0; i < 3; i++)
        u.eye_vector[i] = register_float(pg, NV_PGRAPH_EYEVEC0 + i * 4);

    u.smooth_shading = GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3),
                                NV_PGRAPH_CONTROL_3_SHADEMODE) ==
                       NV_PGRAPH_CONTROL_3_SHADEMODE_SMOOTH;
    u.two_side = !!((boundRaster ? boundRaster.config.setup_raster : setup) &
                    NV_PGRAPH_SETUPRASTER_TWO_SIDE);
    u.point_sprite = !!(setup & NV_PGRAPH_SETUPRASTER_POINTSMOOTHENABLE);
    u.window_clip_exclusive = !!(setup & NV_PGRAPH_SETUPRASTER_WINDOWCLIPTYPE);
    u.depth_clipping = GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_ZCOMPRESSOCCLUDE),
                                NV_PGRAPH_ZCOMPRESSOCCLUDE_ZCLAMP_EN) ==
                       NV_PGRAPH_ZCOMPRESSOCCLUDE_ZCLAMP_EN_CULL;
    u.z_perspective = !!(control & NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE);
    u.shadow_func = GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_SHADOWCTL),
                             NV_PGRAPH_SHADOWCTL_SHADOW_ZFUNC);
    u.alpha_test = !!(control & NV_PGRAPH_CONTROL_0_ALPHATESTENABLE);
    u.alpha_func = GET_MASK(control, NV_PGRAPH_CONTROL_0_ALPHAFUNC);
    u.alpha_ref = GET_MASK(control, NV_PGRAPH_CONTROL_0_ALPHAREF);
    BOOL floating = !!(setup & NV_PGRAPH_SETUPRASTER_Z_FORMAT);
    switch (pg->surface_shape.zeta_format) {
    case NV097_SET_SURFACE_FORMAT_ZETA_Z16:
        u.depth_format =
            floating ? NV2AMetalPixelDepthF16 : NV2AMetalPixelDepthD16;
        u.clip_range[1] = floating ? f16_max : 65535.f;
        break;
    case NV097_SET_SURFACE_FORMAT_ZETA_Z24S8:
        u.depth_format =
            floating ? NV2AMetalPixelDepthF24 : NV2AMetalPixelDepthD24;
        u.clip_range[1] = floating ? f24_max : 16777215.f;
        break;
    default:
        capture_error(error, @"Invalid NV2A pixel depth format");
        return nil;
    }
    u.clip_range[2] = register_float(pg, NV_PGRAPH_ZCLIPMIN);
    u.clip_range[3] = register_float(pg, NV_PGRAPH_ZCLIPMAX);
    unsigned polygon_mode =
        GET_MASK(setup, NV_PGRAPH_SETUPRASTER_FRONTFACEMODE);
    if (pg->primitive_mode >= PRIM_TYPE_TRIANGLES) {
        _offsetMask =
            (setup & NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE ? 1 : 0) |
            (setup & NV_PGRAPH_SETUPRASTER_POFFSETPOINTENABLE ? 2 : 0) |
            (setup & NV_PGRAPH_SETUPRASTER_POFFSETLINEENABLE ? 4 : 0);
        _offsetFactor = register_float(pg, NV_PGRAPH_ZOFFSETFACTOR);
        _offsetBias = register_float(pg, NV_PGRAPH_ZOFFSETBIAS);
    }
    BOOL offset = polygon_mode <= NV2AMetalPolygonLine &&
                  (_offsetMask & (1u << polygon_mode));
    if (offset) {
        u.depth_factor = _offsetFactor;
        u.depth_offset = _offsetBias;
    }
    unsigned aa = pg->surface_shape.anti_aliasing;
    NSUInteger sx = pg->surface_scale_factor * (aa ? 2ull : 1ull);
    NSUInteger sy =
        pg->surface_scale_factor *
        (aa == NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4 ? 2ull :
                                                                        1ull);
    u.surface_scale[0] = sx;
    u.surface_scale[1] = sy;
    for (unsigned i = 0; i < 8; i++) {
        uint32_t x = pgraph_reg_r(pg, NV_PGRAPH_WINDOWCLIPX0 + i * 4);
        uint32_t y = pgraph_reg_r(pg, NV_PGRAPH_WINDOWCLIPY0 + i * 4);
        u.clip_regions[i][0] = GET_MASK(x, NV_PGRAPH_WINDOWCLIPX0_XMIN) * sx;
        u.clip_regions[i][1] = GET_MASK(y, NV_PGRAPH_WINDOWCLIPY0_YMIN) * sy;
        u.clip_regions[i][2] =
            (GET_MASK(x, NV_PGRAPH_WINDOWCLIPX0_XMAX) + 1) * sx;
        u.clip_regions[i][3] =
            (GET_MASK(y, NV_PGRAPH_WINDOWCLIPY0_YMAX) + 1) * sy;
    }
    NV2AMetalPixelTexture unused[4] = { 0 };
    if (textures && ![textures applyToUniforms:&u textures:unused error:error])
        return nil;
    /* Clip-plane modes do not require a bound/enabled texture; GL captures
     * their compare bits before its per-stage enable check. */
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].compare_mask =
            (pgraph_reg_r(pg, NV_PGRAPH_SHADERCLIPMODE) >> (4 * i)) & 15;
    }
    if (!nv2a_metal_pixel_validate(&u, error))
        return nil;
    NV2AMetalDrawConfig raster = {
        .control = { control, pgraph_reg_r(pg, NV_PGRAPH_CONTROL_1),
                     pgraph_reg_r(pg, NV_PGRAPH_CONTROL_2) },
        .blend = pgraph_reg_r(pg, NV_PGRAPH_BLEND),
        .blend_color = pgraph_reg_r(pg, NV_PGRAPH_BLENDCOLOR),
        .setup_raster = setup,
        .antialiasing = pgraph_reg_r(pg, NV_PGRAPH_ANTIALIASING),
        .viewport_width =
            pg->surface_binding_dim.width * pg->surface_scale_factor,
        .viewport_height =
            pg->surface_binding_dim.height * pg->surface_scale_factor,
        .scissor_enabled = YES,
        .scissor = { (NSUInteger)pg->surface_shape.clip_x * sx,
                     (NSUInteger)pg->surface_shape.clip_y * sy,
                     (NSUInteger)pg->surface_shape.clip_width * sx,
                     (NSUInteger)pg->surface_shape.clip_height * sy },
    };
    _raster = boundRaster ?:
                            [[NV2AMetalDrawState alloc] initWithDevice:device
                                                                config:&raster
                                                                 error:error];
    if (!_raster)
        return nil;
    _uniforms = u;
    _textures = textures;
    return self;
}
- (NV2AMetalPGRAPHPixelState *)recaptureShaderWithState:(PGRAPHState *)pg
                                                 device:(id<MTLDevice>)device
                                                  error:(NSError **)error
{
    NV2AMetalPGRAPHPixelState *state =
        [[NV2AMetalPGRAPHPixelState alloc] initWithState:pg
                                                textures:_textures
                                                  device:device
                                            frozenRaster:_raster
                                                   error:error];
    if (state) {
        state->_offsetMask = _offsetMask;
        state->_offsetFactor = _offsetFactor;
        state->_offsetBias = _offsetBias;
        state->_uniforms.depth_factor = _uniforms.depth_factor;
        state->_uniforms.depth_offset = _uniforms.depth_offset;
    }
    return state;
}
- (NV2AMetalPGRAPHPixelState *)stateByApplyingClear:(uint32_t)parameter
                                              state:(PGRAPHState *)pg
                                             device:(id<MTLDevice>)device
                                              error:(NSError **)error
{
    NV2AMetalDrawConfig config = _raster.config;
    if (parameter & NV097_CLEAR_SURFACE_COLOR) {
        config.control[0] &= ~(NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                               NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                               NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                               NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE);
        if (parameter & NV097_CLEAR_SURFACE_R)
            config.control[0] |= NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE;
        if (parameter & NV097_CLEAR_SURFACE_G)
            config.control[0] |= NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE;
        if (parameter & NV097_CLEAR_SURFACE_B)
            config.control[0] |= NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE;
        if (parameter & NV097_CLEAR_SURFACE_A)
            config.control[0] |= NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    }
    if (parameter & NV097_CLEAR_SURFACE_Z)
        config.control[0] |= NV_PGRAPH_CONTROL_0_ZWRITEENABLE;
    if (parameter & NV097_CLEAR_SURFACE_STENCIL)
        config.control[1] |= NV_PGRAPH_CONTROL_1_STENCIL_MASK_WRITE;
    config.control[0] &= ~NV_PGRAPH_CONTROL_0_DITHERENABLE;
    config.control[0] |= pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0) &
                         NV_PGRAPH_CONTROL_0_DITHERENABLE;
    config.scissor_enabled = NO;
    return [[NV2AMetalPGRAPHPixelState alloc] initWithCapture:self
                                                       config:&config
                                                       device:device
                                                        error:error];
}
- (NV2AMetalPGRAPHTextureSnapshot *)textureSnapshot
{
    return _textures;
}
- (unsigned int)textureMask
{
    return _textures.enabledMask;
}
- (NSData *)snapshotData
{
    NV2AMetalDrawConfig r = _raster.config;
    uint32_t words[PixelCaptureWords] = {
        0x4d345043,
        _snapshotVersion,
        _snapshotVersion >= 6 ? sizeof(_uniforms) / 4 :
        _snapshotVersion == 5 ? PixelCaptureV5UniformWords :
        _snapshotVersion == 4 ? PixelCaptureV4UniformWords :
        _snapshotVersion == 3 ? PixelCaptureV3UniformWords :
                                PixelCaptureLegacyUniformWords,
        self.textureMask,
        _offsetMask,
        0,
        0,
        r.scissor_enabled,
        r.control[0],
        r.control[1],
        r.control[2],
        r.blend,
        r.blend_color,
        r.setup_raster,
        r.antialiasing,
        (uint32_t)(r.scissor.x >> 32),
        (uint32_t)r.scissor.x,
        (uint32_t)(r.scissor.y >> 32),
        (uint32_t)r.scissor.y,
        (uint32_t)(r.scissor.width >> 32),
        (uint32_t)r.scissor.width,
        (uint32_t)(r.scissor.height >> 32),
        (uint32_t)r.scissor.height,
        r.viewport_width,
        r.viewport_height,
    };
    memcpy(words + 5, &_offsetFactor, 4);
    memcpy(words + 6, &_offsetBias, 4);
    NSMutableData *data = [NSMutableData new];
    pixel_append_words(
        data, words,
        (_snapshotVersion >= 2 ? PixelCaptureWords : PixelCaptureLegacyWords) *
            4);
    pixel_uniform_append(data, &_uniforms, _snapshotVersion, words[2] * 4);
    return [data copy];
}
+ (BOOL)validateBoundSnapshot:(NSData *)data
                      control:(uint32_t)control
                      stencil:(uint32_t)stencil
                  textureMask:(uint32_t)mask
                     textures:(NSData *)textures
{
    PixelCapture capture;
    return pixel_decode(data, &capture, NULL) && capture.textureMask == mask &&
           capture.raster.control[0] == control &&
           capture.raster.control[1] == stencil &&
           (textures ? ([NV2AMetalPGRAPHTextureSnapshot
                            validateSnapshot:textures
                                    uniforms:&capture.uniforms
                                       error:NULL] &&
                        (uint32_t)ldl_be_p((const uint8_t *)textures.bytes +
                                           8) == mask) :
                       !mask);
}
+ (BOOL)validateSnapshot:(NSData *)data error:(NSError **)error
{
    PixelCapture capture;
    return pixel_decode(data, &capture, error);
}
- (instancetype)initWithSnapshot:(NSData *)data
                        textures:(NV2AMetalPGRAPHTextureSnapshot *)textures
                          device:(id<MTLDevice>)device
                           error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    PixelCapture capture;
    if (!pixel_decode(data, &capture, error))
        return nil;
    if (textures.enabledMask != capture.textureMask) {
        capture_error(error,
                      @"Pixel capture requires its bound texture stages");
        return nil;
    }
    if (textures) {
        NV2AMetalPixelUniforms bound = { 0 };
        NV2AMetalPixelTexture bindings[4] = { 0 };
        if (![textures applyToUniforms:&bound textures:bindings error:error])
            return nil;
        for (unsigned i = 0; i < 4; i++) {
            if (!(capture.textureMask & (1u << i)))
                continue;
            NV2AMetalTextureStage stage = capture.uniforms.textures[i];
            // Shader rebinding can change compare bits without new textures.
            stage.compare_mask = bound.textures[i].compare_mask;
            if (memcmp(&stage, &bound.textures[i], sizeof(stage))) {
                capture_error(error, @"Pixel capture and bound texture "
                                     @"metadata disagree");
                return nil;
            }
        }
    }
    _raster = [[NV2AMetalDrawState alloc] initWithDevice:device
                                                  config:&capture.raster
                                                   error:error];
    if (!_raster)
        return nil;
    _snapshotVersion = capture.version;
    _uniforms = capture.uniforms;
    _textures = textures;
    _offsetMask = capture.offsetMask;
    _offsetFactor = capture.offsetFactor;
    _offsetBias = capture.offsetBias;
    return self;
}
- (NV2AMetalPixelUniforms)uniformsForPolygon:(enum NV2AMetalPolygonMode)polygon
{
    NV2AMetalPixelUniforms u = _uniforms;
    BOOL offset = polygon >= NV2AMetalPolygonFill &&
                  polygon <= NV2AMetalPolygonLine &&
                  (_offsetMask & (1u << polygon));
    u.depth_factor = offset ? _offsetFactor : 0;
    u.depth_offset = offset ? _offsetBias : 0;
    return u;
}
- (BOOL)copyTextureBindings:(NV2AMetalPixelTexture *)bindings
                      error:(NSError **)error
{
    if (!bindings)
        return capture_error(error, @"Missing pixel texture binding storage");
    for (unsigned i = 0; i < 4; i++) {
        bindings[i].texture = [_textures textureAtIndex:i].binding.texture;
        bindings[i].sampler = [_textures textureAtIndex:i].binding.sampler;
    }
    return YES;
}
@end
