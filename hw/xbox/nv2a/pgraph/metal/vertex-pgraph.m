/* Native PGRAPH vertex capture from glsl/vsh.c and glsl/common.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "vertex-pgraph.h"
#import "vertex-writable.h"

_Static_assert(NV2A_VERTEXSHADER_CONSTANTS == NV2A_METAL_VP_CONSTANTS,
               "Native/QEMU vertex constants");
_Static_assert(NV2A_MAX_TRANSFORM_PROGRAM_LENGTH == NV2A_METAL_VP_SLOTS &&
                   VSH_TOKEN_SIZE == 4,
               "Native/QEMU vertex program slots");
_Static_assert(sizeof(((NV2AMetalProgramUniforms *)0)->constants) ==
                   sizeof(((PGRAPHState *)0)->vsh_constants),
               "Native/QEMU constant payload");
_Static_assert(sizeof(((NV2AMetalFixedUniforms *)0)->ltctxa) ==
                       sizeof(((PGRAPHState *)0)->ltctxa) &&
                   sizeof(((NV2AMetalFixedUniforms *)0)->ltctxb) ==
                       sizeof(((PGRAPHState *)0)->ltctxb) &&
                   sizeof(((NV2AMetalFixedUniforms *)0)->ltc1) ==
                       sizeof(((PGRAPHState *)0)->ltc1),
               "Native/QEMU lighting contexts");
static BOOL capture_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pgraph-vertex"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
static float register_float(PGRAPHState *pg, unsigned reg)
{
    uint32_t word = pgraph_reg_r(pg, reg);
    float value;
    memcpy(&value, &word, sizeof(value));
    return value;
}
@interface NV2AMetalPGRAPHVertexResult ()
- (instancetype)initWithVertices:(nullable id<MTLBuffer>)vertices
                       registers:(nullable id<MTLBuffer>)registers
                           count:(NSUInteger)count
                      programmed:(BOOL)programmed;
@end
@implementation NV2AMetalPGRAPHVertexResult
- (instancetype)initWithVertices:(id<MTLBuffer>)vertices
                       registers:(id<MTLBuffer>)registers
                           count:(NSUInteger)count
                      programmed:(BOOL)programmed
{
    self = [super init];
    if (self) {
        _vertices = vertices;
        _registers = registers;
        _vertexCount = count;
        _programmed = programmed;
    }
    return self;
}
@end
_Static_assert(sizeof(float) == 4 && sizeof(unsigned int) == 4 &&
                   sizeof(NV2AMetalProgramUniforms) == 784 * 4,
               "Vertex snapshot word layout");
_Static_assert(
    sizeof(NV2AMetalFixedUniforms) ==
        sizeof(NV2AMetalProgramUniforms) +
            4 * (NV2A_LTCTXA_COUNT + NV2A_LTCTXB_COUNT + NV2A_LTC1_COUNT) *
                sizeof(float) +
            (12 * NV2A_MAX_LIGHTS + 8 + 2) * sizeof(float) +
            (11 + 4 + 16 + NV2A_MAX_LIGHTS + 3 + 4 + 9) * sizeof(unsigned int),
    "Fixed vertex snapshot has no padding");
static void capture_append_words(NSMutableData *data, const void *source,
                                 size_t size)
{
    const uint8_t *bytes = source;
    for (size_t i = 0; i < size; i += 4) {
        uint32_t word;
        memcpy(&word, bytes + i, 4);
        uint8_t wire[4] = { word >> 24, word >> 16, word >> 8, word };
        [data appendBytes:wire length:4];
    }
}
static uint32_t capture_word(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 |
           (uint32_t)bytes[2] << 8 | bytes[3];
}
static void capture_read_words(void *destination, const uint8_t *source,
                               size_t size)
{
    uint8_t *bytes = destination;
    for (size_t i = 0; i < size; i += 4) {
        uint32_t word = capture_word(source + i);
        memcpy(bytes + i, &word, 4);
    }
}
static BOOL capture_common_valid(const NV2AMetalProgramUniforms *u)
{
    return u->point_programmed <= 1 && u->fog_enable <= 1 &&
           u->specular_enable <= 1 && u->ignore_specular_alpha <= 1 &&
           !u->vertex_count && !u->program_length && !u->reserved[0] &&
           !u->reserved[1] && u->point_scale <= 16384 &&
           u->surface_size[0] <= 16384 && u->surface_size[1] <= 16384;
}

@implementation NV2AMetalPGRAPHVertexState {
    uint32_t _captureVersion;
}
- (instancetype)initWithCapture:(NV2AMetalPGRAPHVertexState *)source
{
    self = [super init];
    if (!self)
        return nil;
    _captureVersion = source->_captureVersion;
    _fullAccess = source->_fullAccess;
    _writeEnable = source->_writeEnable;
    _rasterDiscard = source->_rasterDiscard;
    _programmed = source->_programmed;
    _dynamicAddressing = source->_dynamicAddressing;
    _smooth = source->_smooth;
    _zPerspective = source->_zPerspective;
    _compressedAttributes = source->_compressedAttributes;
    _uniformAttributes = source->_uniformAttributes;
    _swizzleAttributes = source->_swizzleAttributes;
    _inlineValues = source->_inlineValues;
    _programUniforms = source->_programUniforms;
    _fixedUniforms = source->_fixedUniforms;
    _programBytes = source->_programBytes;
    _validatedProgram = source->_validatedProgram;
    _faultFreeReadOnlyAccess = source->_faultFreeReadOnlyAccess;
    return self;
}
- (instancetype)initWithState:(PGRAPHState *)pg error:(NSError **)error
{
    return [self initWithState:pg unbound:NO error:error];
}
- (instancetype)initForTransformOnlyWithState:(PGRAPHState *)pg
                                        error:(NSError **)error
{
    return [self initWithState:pg unbound:YES error:error];
}
- (instancetype)initRawProgramWithState:(PGRAPHState *)pg
                                  error:(NSError **)error
{
    if (!pg || GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CSV0_D),
                        NV_PGRAPH_CSV0_D_MODE) != 2) {
        capture_error(error,
                      @"Raw program capture requires a programmed vertex mode");
        return nil;
    }
    return [self initRawXFWithState:pg error:error];
}
- (instancetype)initRawXFWithState:(PGRAPHState *)pg error:(NSError **)error
{
    return [self initWithState:pg unbound:YES rasterDiscard:YES error:error];
}
- (instancetype)initWithState:(PGRAPHState *)pg
                      unbound:(BOOL)unbound
                        error:(NSError **)error
{
    return [self initWithState:pg unbound:unbound rasterDiscard:NO error:error];
}
- (instancetype)initWithState:(PGRAPHState *)pg
                      unbound:(BOOL)unbound
                rasterDiscard:(BOOL)rasterDiscard
                        error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    _captureVersion = rasterDiscard ? 6 : 5;
    _rasterDiscard = rasterDiscard;
    if (!pg) {
        capture_error(error, @"Missing NV2A vertex state");
        return nil;
    }
    uint64_t width = pg->surface_binding_dim.width;
    uint64_t height = pg->surface_binding_dim.height;
    if (!rasterDiscard) {
        if (unbound && (!width || !height)) {
            const SurfaceShape *shape = &pg->surface_shape;
            BOOL swizzle =
                pg->surface_type == NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
            if (swizzle && (shape->log_width > 14 || shape->log_height > 14)) {
                capture_error(error,
                              @"Invalid unbound NV2A surface dimensions");
                return nil;
            }
            width = swizzle ? 1ull << shape->log_width : shape->clip_width;
            height = swizzle ? 1ull << shape->log_height : shape->clip_height;
            if (shape->anti_aliasing)
                width *= 2;
            if (shape->anti_aliasing ==
                NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4)
                height *= 2;
            if (!swizzle) {
                width += shape->clip_x;
                height += shape->clip_y;
            }
        }
        if (!pg->surface_scale_factor || pg->surface_scale_factor > 16384 ||
            !width || !height || width > 16384 / pg->surface_scale_factor ||
            height > 16384 / pg->surface_scale_factor ||
            pg->surface_shape.anti_aliasing >
                NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4) {
            capture_error(
                error,
                @"Vertex capture requires valid NV2A surface dimensions");
            return nil;
        }
    }
    unsigned csvc = pgraph_reg_r(pg, NV_PGRAPH_CSV0_C),
             csvd = pgraph_reg_r(pg, NV_PGRAPH_CSV0_D);
    unsigned mode = GET_MASK(csvd, NV_PGRAPH_CSV0_D_MODE);
    if (mode != 0 && mode != 2) {
        capture_error(error, @"Unsupported NV2A vertex mode");
        return nil;
    }
    _programmed = mode == 2;
    _fullAccess = !!(csvd & NV_PGRAPH_CSV0_D_RANGE_MODE);
    _writeEnable = pg->enable_vertex_program_write;
    _smooth = GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3),
                       NV_PGRAPH_CONTROL_3_SHADEMODE) ==
              NV_PGRAPH_CONTROL_3_SHADEMODE_SMOOTH;
    _zPerspective = !!(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0) &
                       NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE);
    _compressedAttributes = pg->compressed_attrs;
    _uniformAttributes = pg->uniform_attrs;
    _swizzleAttributes = pg->swizzle_attrs;
    for (unsigned i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++)
        memcpy(_inlineValues.attributes[i],
               pg->vertex_attributes[i].inline_value,
               sizeof(_inlineValues.attributes[i]));
    NV2AMetalProgramUniforms common = { 0 };
    memcpy(common.constants, pg->vsh_constants, sizeof(common.constants));
    if (!rasterDiscard) {
        unsigned aa = pg->surface_shape.anti_aliasing;
        common.surface_size[0] = width / (aa ? 2.f : 1.f);
        common.surface_size[1] = height / (aa == 2 ? 2.f : 1.f);
        BOOL floating = !!(pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER) &
                           NV_PGRAPH_SETUPRASTER_Z_FORMAT);
        switch (pg->surface_shape.zeta_format) {
        case NV097_SET_SURFACE_FORMAT_ZETA_Z16:
            common.zmax = floating ? f16_max : 65535.f;
            break;
        case NV097_SET_SURFACE_FORMAT_ZETA_Z24S8:
            common.zmax = floating ? f24_max : 16777215.f;
            break;
        default:
            capture_error(error, @"Invalid NV2A vertex depth format");
            return nil;
        }
    }
    if (!rasterDiscard || !_programmed) {
        common.point_size = pgraph_reg_r(pg, NV_PGRAPH_POINTSIZE) / 8.f;
        common.point_scale = pg->surface_scale_factor;
        common.point_programmed = !!(csvd & NV_PGRAPH_CSV0_D_POINTPARAMSENABLE);
        common.specular_enable = !!(csvc & NV_PGRAPH_CSV0_C_SPECULAR_ENABLE);
        common.ignore_specular_alpha =
            !(csvc & NV_PGRAPH_CSV0_C_ALPHA_FROM_MATERIAL_SPECULAR);
        common.fog_enable = !!(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3) &
                               NV_PGRAPH_CONTROL_3_FOGENABLE);
        if (common.fog_enable)
            common.fog_mode = GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3),
                                       NV_PGRAPH_CONTROL_3_FOG_MODE);
        common.fog[0] = register_float(pg, NV_PGRAPH_FOGPARAM0);
        common.fog[1] = register_float(pg, NV_PGRAPH_FOGPARAM1);
    }
    _programUniforms = common;
    if (_programmed) {
        unsigned start = GET_MASK(csvc, NV_PGRAPH_CSV0_C_CHEOPS_PROGRAM_START);
        if (start >= NV2A_METAL_VP_SLOTS) {
            capture_error(error, @"NV2A vertex program start exceeds slots");
            return nil;
        }
        unsigned length = 0;
        for (unsigned i = start; i < NV2A_METAL_VP_SLOTS; i++) {
            length++;
            if (pg->program_data[i][3] & 1)
                break;
        }
        if (!rasterDiscard &&
            !nv2a_metal_writable_validate_uniforms(&common, error))
            return nil;
        _validatedProgram = [[NV2AMetalValidatedProgram alloc]
            initWithTokens:pg->program_data[start]
                    length:length
                     error:error];
        if (!_validatedProgram)
            return nil;
        _programBytes = _validatedProgram.tokens;
        _faultFreeReadOnlyAccess = [_validatedProgram
            hasFaultFreeReadOnlyAccess:_fullAccess ? 1 : 0
                             constants:&_programUniforms.constants[0][0]];
        const uint32_t *tokens = _programBytes.bytes;
        for (unsigned i = 0; i < length; i++) {
            /* ARL can fault on NaN/overflow even with no relative constant
             * operand. The draw controller must check that result as well. */
            unsigned mac = (tokens[i * 4 + 1] >> 21) & 15;
            _dynamicAddressing |=
                !!(tokens[i * 4 + 3] & 2) || mac == NV2AMetalMACArl;
        }
        return self;
    }
    _programBytes = [NSData data];
    NV2AMetalFixedUniforms fixed = { .common = common };
    memcpy(fixed.ltctxa, pg->ltctxa, sizeof(fixed.ltctxa));
    memcpy(fixed.ltctxb, pg->ltctxb, sizeof(fixed.ltctxb));
    memcpy(fixed.ltc1, pg->ltc1, sizeof(fixed.ltc1));
    memcpy(fixed.light_direction, pg->light_infinite_direction,
           sizeof(fixed.light_direction));
    memcpy(fixed.light_half_vector, pg->light_infinite_half_vector,
           sizeof(fixed.light_half_vector));
    memcpy(fixed.light_position, pg->light_local_position,
           sizeof(fixed.light_position));
    memcpy(fixed.light_attenuation, pg->light_local_attenuation,
           sizeof(fixed.light_attenuation));
    memcpy(fixed.point_params, pg->point_params, sizeof(fixed.point_params));
    fixed.specular_power = pg->specular_power;
    memcpy(fixed.specular_params, pg->specular_params,
           sizeof(fixed.specular_params));
    fixed.material_alpha = pg->material_alpha;
    fixed.material_alpha_back = pg->material_alpha_back;
    memcpy(fixed.specular_params_back, pg->specular_params_back,
           sizeof(fixed.specular_params_back));
    fixed.two_side = !!(csvc & NV_PGRAPH_CSV0_C_TWO_SIDE);
    fixed.back_emission_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_EMISSION);
    fixed.back_ambient_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_AMBIENT);
    fixed.back_diffuse_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_DIFFUSE);
    fixed.back_specular_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_SPECULAR);
    fixed.skinning = GET_MASK(csvd, NV_PGRAPH_CSV0_D_SKIN);
    fixed.texgen_infinite_viewer = !!(csvd & NV_PGRAPH_CSV0_D_TEXGEN_REF);
    fixed.normalization = !!(csvc & NV_PGRAPH_CSV0_C_NORMALIZATION_ENABLE);
    fixed.lighting = !!(csvc & NV_PGRAPH_CSV0_C_LIGHTING);
    fixed.local_eye = !!(csvc & NV_PGRAPH_CSV0_C_LOCALEYE);
    fixed.emission_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_EMISSION);
    fixed.ambient_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_AMBIENT);
    fixed.diffuse_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_DIFFUSE);
    fixed.specular_src = GET_MASK(csvc, NV_PGRAPH_CSV0_C_SPECULAR);
    fixed.separate_specular = !!(csvc & NV_PGRAPH_CSV0_C_SEPARATE_SPECULAR);
    fixed.point_params_enable = !!(csvd & NV_PGRAPH_CSV0_D_POINTPARAMSENABLE);
    if (common.fog_enable)
        fixed.foggen = GET_MASK(csvd, NV_PGRAPH_CSV0_D_FOGGENMODE);
    for (unsigned i = 0; i < NV2A_MAX_LIGHTS; i++)
        if (fixed.lighting)
            fixed.light[i] = GET_MASK(csvd, NV_PGRAPH_CSV0_D_LIGHT0 << (2 * i));
    const unsigned masks[2][4] = {
        { NV_PGRAPH_CSV1_A_T0_S, NV_PGRAPH_CSV1_A_T0_T, NV_PGRAPH_CSV1_A_T0_R,
          NV_PGRAPH_CSV1_A_T0_Q },
        { NV_PGRAPH_CSV1_A_T1_S, NV_PGRAPH_CSV1_A_T1_T, NV_PGRAPH_CSV1_A_T1_R,
          NV_PGRAPH_CSV1_A_T1_Q }
    };
    for (unsigned i = 0; i < 4; i++) {
        fixed.texture_matrix_enable[i] = pg->texture_matrix_enable[i];
        unsigned word =
            pgraph_reg_r(pg, i < 2 ? NV_PGRAPH_CSV1_A : NV_PGRAPH_CSV1_B);
        for (unsigned j = 0; j < 4; j++)
            fixed.texgen[i][j] = GET_MASK(word, masks[i % 2][j]);
    }
    if (!(rasterDiscard ? nv2a_metal_fixed_validate_context(&fixed, error) :
                          nv2a_metal_fixed_validate(&fixed, error)))
        return nil;
    _fixedUniforms = fixed;
    return self;
}
- (NSData *)snapshotData
{
    size_t fixed_size = _captureVersion == 1 ?
                            offsetof(NV2AMetalFixedUniforms, specular_params) :
                        _captureVersion < 4 ? offsetof(NV2AMetalFixedUniforms,
                                                       specular_params_back) :
                                              sizeof(_fixedUniforms);
    uint32_t header[] = {
        0x4d345643,
        _captureVersion,
        _programmed | _dynamicAddressing << 1 | _smooth << 2 |
            _zPerspective << 3 |
            (_captureVersion >= 5 ? (_fullAccess << 4 | _writeEnable << 5) :
                                    0) |
            (_captureVersion >= 6 ? _rasterDiscard << 6 : 0),
        _compressedAttributes,
        _uniformAttributes,
        _swizzleAttributes,
        (uint32_t)(_programmed ? sizeof(_programUniforms) : fixed_size) / 4,
        (uint32_t)_programBytes.length / 16,
    };
    NSMutableData *data = [NSMutableData new];
    capture_append_words(data, header, sizeof(header));
    capture_append_words(data, &_inlineValues, sizeof(_inlineValues));
    if (_programmed)
        capture_append_words(data, &_programUniforms, sizeof(_programUniforms));
    else
        capture_append_words(data, &_fixedUniforms, fixed_size);
    capture_append_words(data, _programBytes.bytes, _programBytes.length);
    return [data copy];
}
- (instancetype)initWithSnapshot:(NSData *)data error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    const uint8_t *bytes = data.bytes;
    if (data.length < 32 || capture_word(bytes) != 0x4d345643 ||
        (capture_word(bytes + 4) < 1 || capture_word(bytes + 4) > 6)) {
        capture_error(error, @"Invalid native vertex capture header");
        return nil;
    }
    uint32_t version = capture_word(bytes + 4);
    uint32_t flags = capture_word(bytes + 8);
    uint32_t compressed = capture_word(bytes + 12),
             uniform = capture_word(bytes + 16),
             swizzle = capture_word(bytes + 20),
             uniform_words = capture_word(bytes + 24),
             slots = capture_word(bytes + 28);
    BOOL programmed = flags & 1;
    BOOL rasterDiscard = version == 6 && (flags & 64);
    size_t uniform_size =
        programmed   ? sizeof(_programUniforms) :
        version == 1 ? offsetof(NV2AMetalFixedUniforms, specular_params) :
        version < 4  ? offsetof(NV2AMetalFixedUniforms, specular_params_back) :
                       sizeof(_fixedUniforms);
    if (flags > (version == 6 ? 127u :
                 version >= 5 ? 63u :
                                15u) ||
        (version == 6 && !rasterDiscard) || compressed > UINT16_MAX ||
        uniform > UINT16_MAX || swizzle > UINT16_MAX ||
        uniform_words != uniform_size / 4 || slots > NV2A_METAL_VP_SLOTS ||
        (programmed ? !slots : slots != 0) || (!programmed && (flags & 2)) ||
        data.length != 32 + sizeof(_inlineValues) + uniform_size + slots * 16) {
        capture_error(error, @"Invalid native vertex capture sizes or flags");
        return nil;
    }
    bytes += 32;
    capture_read_words(&_inlineValues, bytes, sizeof(_inlineValues));
    bytes += sizeof(_inlineValues);
    if (programmed) {
        capture_read_words(&_programUniforms, bytes, uniform_size);
    } else {
        capture_read_words(&_fixedUniforms, bytes, uniform_size);
        if (version == 1) {
            _fixedUniforms.legacy_specular = 1;
        }
        _programUniforms = _fixedUniforms.common;
    }
    bytes += uniform_size;
    if (!capture_common_valid(&_programUniforms)) {
        capture_error(error, @"Invalid native vertex capture uniform metadata");
        return nil;
    }
    if (rasterDiscard && programmed) {
        const uint8_t *tail = (const uint8_t *)&_programUniforms +
                              sizeof(_programUniforms.constants);
        for (size_t i = 0;
             i < sizeof(_programUniforms) - sizeof(_programUniforms.constants);
             i++) {
            if (tail[i]) {
                capture_error(error,
                              @"Raw XF capture contains raster metadata");
                return nil;
            }
        }
    }
    if (rasterDiscard && !programmed) {
        uint32_t surface[2], zmax;
        memcpy(surface, _programUniforms.surface_size, sizeof(surface));
        memcpy(&zmax, &_programUniforms.zmax, sizeof(zmax));
        if (surface[0] || surface[1] || zmax) {
            capture_error(error,
                          @"Raw fixed capture contains raster dimensions");
            return nil;
        }
    }
    NSMutableData *tokens = [NSMutableData dataWithLength:slots * 16];
    capture_read_words(tokens.mutableBytes, bytes, slots * 16);
    BOOL dynamic = NO;
    if (programmed) {
        /* Legacy wire versions retain their stricter readonly decoder policy.
         * Every external restore rebuilds metadata from raw token bytes. */
        if (!rasterDiscard &&
            !(version >= 5 ?
                  nv2a_metal_writable_validate_uniforms(&_programUniforms,
                                                        error) :
                  nv2a_metal_program_validate(tokens.bytes, slots,
                                              &_programUniforms, error)))
            return nil;
        _validatedProgram =
            [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens.bytes
                                                       length:slots
                                                        error:error];
        if (!_validatedProgram)
            return nil;
        const uint32_t *words = tokens.bytes;
        for (uint32_t i = 0; i < slots; i++) {
            if (!!(words[i * 4 + 3] & 1) != (i + 1 == slots)) {
                capture_error(error,
                              @"Vertex capture has surplus program slots");
                return nil;
            }
            dynamic |= !!(words[i * 4 + 3] & 2) ||
                       ((words[i * 4 + 1] >> 21) & 15) == NV2AMetalMACArl;
        }
        if (dynamic != !!(flags & 2)) {
            capture_error(error,
                          @"Vertex capture address-fault policy mismatch");
            return nil;
        }
    } else {
        const NV2AMetalFixedUniforms *u = &_fixedUniforms;
        if (u->normalization > 1 || u->lighting > 1 || u->local_eye > 1 ||
            u->separate_specular > 1 || u->point_params_enable > 1 ||
            u->reserved[0] || u->reserved[1] ||
            (version < 3 && u->texgen_infinite_viewer) ||
            (version >= 2 && u->legacy_specular) ||
            !(rasterDiscard ? nv2a_metal_fixed_validate_context(u, error) :
                              nv2a_metal_fixed_validate(u, error))) {
            capture_error(error, @"Invalid native fixed vertex capture");
            return nil;
        }
        for (unsigned i = 0; i < 4; i++) {
            if (u->texture_matrix_enable[i] > 1) {
                capture_error(error, @"Invalid vertex texture-matrix flag");
                return nil;
            }
        }
    }
    _captureVersion = version;
    _rasterDiscard = rasterDiscard;
    /* Legacy snapshots preserve their old full-window, read-only semantics. */
    _fullAccess = version < 5 || !!(flags & 16);
    _writeEnable = version >= 5 && !!(flags & 32);
    _programmed = programmed;
    _dynamicAddressing = dynamic;
    _smooth = !!(flags & 4);
    _zPerspective = !!(flags & 8);
    _compressedAttributes = compressed;
    _uniformAttributes = uniform;
    _swizzleAttributes = swizzle;
    _programBytes =
        _validatedProgram ? _validatedProgram.tokens : [tokens copy];
    _faultFreeReadOnlyAccess = [_validatedProgram
        hasFaultFreeReadOnlyAccess:_fullAccess ? 1 : 0
                         constants:&_programUniforms.constants[0][0]];
    return self;
}
- (NV2AMetalPGRAPHVertexState *)stateByApplyingConstants:(NSData *)constants
                                                 written:(NSData *)written
                                                   error:(NSError **)error
{
    const NSUInteger rows = NV2A_METAL_VP_CONSTANTS;
    if (constants.length != rows * 16 || written.length != rows * 4) {
        if (error)
            *error =
                [NSError errorWithDomain:@"xemu.nv2a.metal4.constant-epoch"
                                    code:1
                                userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"Invalid constant epoch dimensions"
                                }];
        return nil;
    }
    const uint8_t *flags = written.bytes;
    BOOL changed = NO;
    for (NSUInteger row = 0; row < rows; row++) {
        uint32_t flag;
        memcpy(&flag, flags + row * 4, 4);
        if (flag > 1) {
            if (error)
                *error =
                    [NSError errorWithDomain:@"xemu.nv2a.metal4.constant-epoch"
                                        code:1
                                    userInfo:@{
                                        NSLocalizedDescriptionKey :
                                            @"Invalid constant epoch write flag"
                                    }];
            return nil;
        }
        changed |= flag != 0;
    }
    if (!changed)
        return self;
    NV2AMetalPGRAPHVertexState *copy =
        [[NV2AMetalPGRAPHVertexState alloc] initWithCapture:self];
    if (!copy)
        return nil;
    const uint8_t *source = constants.bytes;
    for (NSUInteger row = 0; row < rows; row++) {
        uint32_t flag;
        memcpy(&flag, flags + row * 4, 4);
        if (flag) {
            memcpy(copy->_programUniforms.constants[row], source + row * 16,
                   16);
            if (!_programmed)
                memcpy(copy->_fixedUniforms.common.constants[row],
                       source + row * 16, 16);
        }
    }
    copy->_faultFreeReadOnlyAccess = [copy->_validatedProgram
        hasFaultFreeReadOnlyAccess:copy->_fullAccess ? 1 : 0
                         constants:&copy->_programUniforms.constants[0][0]];
    return copy;
}

- (NV2AMetalPGRAPHVertexResult *)encodeAttributes:(id<MTLBuffer>)attributes
                                            count:(NSUInteger)count
                                          program:
                                              (NV2AMetalVertexProgram *)program
                                            fixed:(NV2AMetalVertexFixed *)fixed
                                         commands:(NV2AMetalCommands *)commands
                                            error:(NSError **)error
{
    if (_rasterDiscard || (_programmed && (!_fullAccess || _writeEnable))) {
        capture_error(
            error,
            @"Vertex context policy requires the ordered epoch executor");
        return nil;
    }
    if (_programmed) {
        if (!program) {
            capture_error(error, @"Missing native vertex-program engine");
            return nil;
        }
        NV2AMetalProgramResult *r =
            [program encodeTokens:_programBytes.bytes
                           length:_programBytes.length / 16
                         uniforms:&_programUniforms
                       attributes:attributes
                            count:count
                         commands:commands
                            error:error];
        if (!r)
            return nil;
        return
            [[NV2AMetalPGRAPHVertexResult alloc] initWithVertices:r.vertices
                                                        registers:r.registers
                                                            count:r.vertexCount
                                                       programmed:YES];
    }
    if (!fixed) {
        capture_error(error, @"Missing native fixed-function vertex engine");
        return nil;
    }
    NV2AMetalFixedResult *r = [fixed encodeAttributes:attributes
                                                count:count
                                             uniforms:&_fixedUniforms
                                             commands:commands
                                                error:error];
    if (!r)
        return nil;
    return [[NV2AMetalPGRAPHVertexResult alloc] initWithVertices:r.vertices
                                                       registers:r.registers
                                                           count:r.vertexCount
                                                      programmed:NO];
}
@end
