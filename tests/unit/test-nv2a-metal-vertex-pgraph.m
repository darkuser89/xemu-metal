/* Native PGRAPH vertex capture and full GPU fetch/vertex/geometry/pixel chain.
 * No VM, application or window is started.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/vertex-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-fetch.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-pgraph.h"

static PGRAPHState *pg;
static NV2AMetalCommands *commands;
static NV2AMetalVertexProgram *program;
static NV2AMetalVertexFixed *fixed;
static unsigned captures, dispatches, chains;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Vertex PGRAPH: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void close_float(float actual, float expected)
{
    if (!isfinite(actual) ||
        fabsf(actual - expected) > .00001f * fmaxf(1, fabsf(expected))) {
        fprintf(stderr, "Vertex capture value %g expected %g\n", actual,
                expected);
        abort();
    }
}
static void reg_float(unsigned reg, float f)
{
    memcpy(&pg->regs_[reg], &f, 4);
}
static void constant(unsigned index, unsigned component, float f)
{
    memcpy(&pg->vsh_constants[index][component], &f, 4);
}
static void matrix(unsigned index, float scale)
{
    memset(pg->vsh_constants[index], 0, 64);
    for (unsigned i = 0; i < 3; i++)
        constant(index + i, i, scale);
    constant(index + 3, 3, 1);
}
static void initialize(unsigned aa, unsigned scale)
{
    memset(pg, 0, sizeof(*pg));
    pg->primitive_mode = PRIM_TYPE_TRIANGLES;
    pg->surface_scale_factor = scale;
    pg->surface_shape = (SurfaceShape){ .zeta_format = 1,
                                        .color_format = 8,
                                        .clip_width = 8,
                                        .clip_height = 8,
                                        .anti_aliasing = aa };
    pg->surface_binding_dim.width = 8 * (aa ? 2 : 1);
    pg->surface_binding_dim.height = 8 * (aa == 2 ? 2 : 1);
    pg->regs_[NV_PGRAPH_POINTSIZE] = 24;
    pg->regs_[NV_PGRAPH_CONTROL_3] = NV_PGRAPH_CONTROL_3_SHADEMODE;
    pg->material_alpha = 1;
    pg->specular_params[2] = 1;
    matrix(NV_IGRAPH_XF_XFCTX_CMAT0, 1);
    for (unsigned i = 0; i < 4; i++) {
        matrix(NV_IGRAPH_XF_XFCTX_MMAT0 + 8 * i, 1);
        matrix(NV_IGRAPH_XF_XFCTX_IMMAT0 + 8 * i, 1);
        matrix(NV_IGRAPH_XF_XFCTX_T0MAT + 8 * i, 1);
        matrix(NV_IGRAPH_XF_XFCTX_TG0MAT + 8 * i, 1);
    }
}
/* Original raw token fields: MOV A from attribute/constant, full output mask.
 */
static void mov(unsigned slot, unsigned input, unsigned output,
                bool from_constant, bool final)
{
    uint32_t *t = pg->program_data[slot];
    memset(t, 0, 16);
    t[1] = 1 << 21 | (from_constant ? input << 13 : input << 9) | 27;
    t[2] = (from_constant ? 3u : 2u) << 26;
    t[3] = 1 << 11 | output << 3 | 15 << 12 | final;
}
static NV2AMetalPGRAPHVertexState *capture(void)
{
    NSError *error = nil;
    NV2AMetalPGRAPHVertexState *s =
        [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg error:&error];
    require(s != nil, error);
    captures++;
    return s;
}
static void begin(void)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
}
static void finish(void)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static NV2AMetalPGRAPHVertexResult *encode(NV2AMetalPGRAPHVertexState *s,
                                           NV2AMetalProgramInput *input,
                                           NSUInteger count)
{
    NSError *error = nil;
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:input
                                     length:count * sizeof(*input)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    NV2AMetalPGRAPHVertexResult *r = [s encodeAttributes:attributes
                                                   count:count
                                                 program:program
                                                   fixed:fixed
                                                commands:commands
                                                   error:&error];
    require(r != nil, error);
    dispatches++;
    return r;
}
static void metadata_tests(void)
{
    initialize(2, 3);
    pg->regs_[NV_PGRAPH_CSV0_C] =
        NV_PGRAPH_CSV0_C_SPECULAR_ENABLE | NV_PGRAPH_CSV0_C_SEPARATE_SPECULAR |
        NV_PGRAPH_CSV0_C_LIGHTING | NV_PGRAPH_CSV0_C_LOCALEYE |
        NV_PGRAPH_CSV0_C_NORMALIZATION_ENABLE | 1u << 19 | 2u << 21 | 1u << 23 |
        2u << 25;
    pg->regs_[NV_PGRAPH_CSV0_D] =
        6u << 26 | 4u << 22 | NV_PGRAPH_CSV0_D_POINTPARAMSENABLE;
    for (unsigned i = 0; i < 8; i++)
        pg->regs_[NV_PGRAPH_CSV0_D] |= (i % 4) << (2 * i);
    pg->regs_[NV_PGRAPH_CONTROL_3] |= NV_PGRAPH_CONTROL_3_FOGENABLE | 4 << 16;
    reg_float(NV_PGRAPH_FOGPARAM0, 1.25f);
    reg_float(NV_PGRAPH_FOGPARAM1, .5f);
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;
    pg->compressed_attrs = 0x1234;
    pg->uniform_attrs = 0x5678;
    pg->swizzle_attrs = 0x9abc;
    for (unsigned i = 0; i < 16; i++)
        for (unsigned j = 0; j < 4; j++)
            pg->vertex_attributes[i].inline_value[j] = i + j * .25f;
    for (unsigned i = 0; i < NV2A_LTCTXA_COUNT; i++)
        for (unsigned j = 0; j < 4; j++) {
            float f = i + j * .5f;
            memcpy(&pg->ltctxa[i][j], &f, 4);
        }
    for (unsigned i = 0; i < 8; i++) {
        pg->point_params[i] = i * .5f;
        for (unsigned j = 0; j < 3; j++) {
            pg->light_infinite_direction[i][j] = i + j;
            pg->light_infinite_half_vector[i][j] = i - j * .5f;
            pg->light_local_position[i][j] = i + j * .25f;
            pg->light_local_attenuation[i][j] = i + j * .75f;
        }
    }
    pg->material_alpha = .75f;
    pg->specular_power = 12.5f;
    pg->texture_matrix_enable[2] = true;
    pg->regs_[NV_PGRAPH_CSV1_A] = 1 << 4 | 2 << 7 | 1 << 10 | 2 << 13 |
                                  2 << 20 | 1 << 23 | 2 << 26 | 1u << 29;
    pg->regs_[NV_PGRAPH_CSV1_B] = pg->regs_[NV_PGRAPH_CSV1_A];
    NV2AMetalPGRAPHVertexState *s = capture();
    NV2AMetalFixedUniforms u = s.fixedUniforms;
    assert(!s.programmed && !s.programBytes.length && s.smooth &&
           s.zPerspective);
    assert(s.compressedAttributes == 0x1234 && s.uniformAttributes == 0x5678 &&
           s.swizzleAttributes == 0x9abc);
    assert(s.inlineValues.attributes[15][3] == 15.75f);
    assert(u.common.surface_size[0] == 8 && u.common.surface_size[1] == 8);
    assert(u.common.point_size == 3 && u.common.point_scale == 3);
    assert(u.common.fog_enable && u.common.fog_mode == 4 &&
           u.common.fog[0] == 1.25f);
    assert(u.common.specular_enable && u.common.ignore_specular_alpha);
    assert(u.skinning == 6 && u.lighting && u.local_eye && u.normalization &&
           u.separate_specular);
    assert(u.emission_src == 2 && u.ambient_src == 1 && u.diffuse_src == 2 &&
           u.specular_src == 1);
    assert(u.foggen == 4 && u.point_params_enable &&
           u.specular_power == 12.5f && u.material_alpha == .75f);
    assert(u.ltctxa[9][3] == 10.5f && u.point_params[7] == 3.5f);
    assert(u.light[7] == 3 && u.light_position[5][2] == 5.5f &&
           u.light_attenuation[5][2] == 6.5f);
    assert(u.texture_matrix_enable[2] && u.texgen[0][0] == 1 &&
           u.texgen[3][3] == 1);
    memset(pg, 0, sizeof(*pg));
    assert(s.fixedUniforms.material_alpha == .75f &&
           s.inlineValues.attributes[15][3] == 15.75f);
    u.common.constants[0][0] = 0;
    assert(s.fixedUniforms.common.constants[0][0] != 0);
    for (unsigned f = 0; f < 4; f++) {
        initialize(0, 1);
        pg->surface_shape.zeta_format = f & 1 ? 2 : 1;
        pg->surface_shape.z_format = !(f & 2);
        pg->regs_[NV_PGRAPH_SETUPRASTER] =
            f & 2 ? NV_PGRAPH_SETUPRASTER_Z_FORMAT : 0;
        s = capture();
        float expected = f & 2 ? f & 1 ? f24_max : f16_max :
                         f & 1 ? 16777215.f :
                                 65535.f;
        assert(s.programUniforms.zmax == expected);
    }
}
static void programmable_tests(void)
{
    initialize(1, 2);
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
    pg->regs_[NV_PGRAPH_CSV0_C] = 10 << 8;
    mov(10, 0, 0, false, false);
    mov(11, 5, 3, true, true);
    float color[] = { .25f, .5f, .75f, 1 };
    memcpy(pg->vsh_constants[5], color, 16);
    NV2AMetalPGRAPHVertexState *s = capture();
    assert(s.programmed && s.programBytes.length == 32 && !s.dynamicAddressing);
    NV2AMetalProgramInput input = { 0 };
    float position[] = { 1.375f, 2.5625f, 32768, 1 };
    memcpy(input.attributes[0], position, 16);
    memset(pg->program_data, 0, sizeof(pg->program_data));
    memset(pg->vsh_constants, 0, sizeof(pg->vsh_constants));
    begin();
    NV2AMetalPGRAPHVertexResult *r = encode(s, &input, 1);
    finish();
    const NV2AMetalProgramOutput *raw = r.registers.contents;
    const NV2AMetalVertex *v = r.vertices.contents;
    assert(r.programmed && !raw->fault && r.vertexCount == 1);
    close_float(raw->registers[3][2], .75f);
    close_float(v->screen[0], 1.375f);
    close_float(v->point_size, 6);
    close_float(v->clip[0], 2 * position[0] / 8 - 1);
    close_float(v->clip[1], 1 - 2 * position[1] / 8);
    /* Programmed v1 has the same ABI and must preserve its wire version. */
    NSMutableData *old = [s.snapshotData mutableCopy];
    ((uint8_t *)old.mutableBytes)[7] = 1;
    ((uint8_t *)old.mutableBytes)[11] &= 15;
    NSError *error = nil;
    NV2AMetalPGRAPHVertexState *legacy =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:old error:&error];
    require(legacy != nil, error);
    assert([old isEqualToData:legacy.snapshotData]);
    begin();
    NV2AMetalPGRAPHVertexResult *legacy_result = encode(legacy, &input, 1);
    finish();
    assert(!memcmp(r.registers.contents, legacy_result.registers.contents,
                   r.registers.length));
    assert(!memcmp(r.vertices.contents, legacy_result.vertices.contents,
                   r.vertices.length));

    initialize(0, 2);
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE |
                                  NV_PGRAPH_CSV0_D_POINTPARAMSENABLE;
    mov(0, 0, 0, false, false);
    mov(1, 6, 6, false, true);
    input.attributes[6][0] = 7;
    begin();
    r = encode(capture(), &input, 1);
    finish();
    v = r.vertices.contents;
    close_float(v->point_size, 7);
    initialize(0, 1);
    pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
    /* ARL A0.x <- v0.x, then relative constant MOV to oPos. */
    mov(0, 0, 0, false, false);
    pg->program_data[0][1] = 13 << 21 | 27;
    pg->program_data[0][3] = 0;
    mov(1, 255, 0, true, true);
    pg->program_data[1][3] |= 2;
    input.attributes[0][0] = 1000;
    s = capture();
    assert(s.dynamicAddressing);
    begin();
    r = encode(s, &input, 1);
    finish();
    raw = r.registers.contents;
    v = r.vertices.contents;
    assert(raw->fault && !v->clip[3]);
}
static void fixed_tests(void)
{
    NV2AMetalProgramInput input = { 0 };
    float pos[] = { 2.5f, 3.25f, 32768, 1 };
    memcpy(input.attributes[0], pos, 16);
    input.attributes[2][2] = 1;
    input.attributes[3][0] = .75f;
    input.attributes[3][3] = 1;
    input.attributes[4][0] = .25f;
    input.attributes[4][3] = .5f;
    input.attributes[5][0] = 2;
    for (unsigned aa = 0; aa < 3; aa++) {
        initialize(aa, 2);
        NV2AMetalPGRAPHVertexState *s = capture();
        memset(pg->vsh_constants, 0, sizeof(pg->vsh_constants));
        begin();
        NV2AMetalPGRAPHVertexResult *r = encode(s, &input, 1);
        finish();
        const NV2AMetalVertex *v = r.vertices.contents;
        const NV2AMetalProgramOutput *raw = r.registers.contents;
        assert(!r.programmed && !raw->fault);
        close_float(v->screen[0], 2.5f);
        close_float(v->clip[0], 2 * 2.5f / 8 - 1);
        close_float(v->color[0][0], .75f);
        close_float(v->color[1][0], 0);
        close_float(v->color[1][3], 1);
        close_float(v->point_size, 6);
    }
    initialize(0, 2);
    pg->regs_[NV_PGRAPH_CSV0_D] = NV_PGRAPH_CSV0_D_POINTPARAMSENABLE | 4u << 22;
    pg->point_params[0] = 1;
    pg->point_params[3] = 4;
    pg->point_params[7] = 1;
    pg->regs_[NV_PGRAPH_CONTROL_3] |= NV_PGRAPH_CONTROL_3_FOGENABLE;
    reg_float(NV_PGRAPH_FOGPARAM0, 1.5f);
    reg_float(NV_PGRAPH_FOGPARAM1, .25f);
    begin();
    NV2AMetalPGRAPHVertexResult *r = encode(capture(), &input, 1);
    finish();
    const NV2AMetalVertex *v = r.vertices.contents;
    close_float(v->point_size, 10);
    close_float(v->fog, 1);
}
static void spotlight_capture_tests(void)
{
    const float coefficients[][3] = {
        { 0, 0, 1 },
        { -.170208f, -.855843f, 1.685635f },
        { -.706496f, -2.507095f, 2.800600f },
    };
    unsigned cases = 0;
    for (unsigned light = 0; light < 8; light++) {
        for (unsigned c = 0; c < 3; c++) {
            initialize(0, 1);
            pg->regs_[NV_PGRAPH_CSV0_C] =
                NV_PGRAPH_CSV0_C_LIGHTING | NV_PGRAPH_CSV0_C_SPECULAR_ENABLE |
                NV_PGRAPH_CSV0_C_SEPARATE_SPECULAR |
                NV_PGRAPH_CSV0_C_ALPHA_FROM_MATERIAL_SPECULAR;
            pg->regs_[NV_PGRAPH_CSV0_D] = NV_PGRAPH_CSV0_D_LIGHT0_SPOT
                                          << (2 * light);
            pg->material_alpha = .75f;
            pg->specular_power = 2;
            pg->light_local_position[light][2] = 2;
            pg->light_local_attenuation[light][0] = 1;
            float range = 2;
            memcpy(&pg->ltc1[NV_IGRAPH_XF_LTC1_r0 + light][0], &range, 4);
            for (unsigned other = 0; other < 8; other++) {
                const float sentinel[3] = { -1, 17, 31 };
                memcpy(pg->ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * other],
                       sentinel, sizeof(sentinel));
            }
            memcpy(pg->ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * light],
                   coefficients[c], sizeof(coefficients[c]));
            const float spot[4] = { 0, 0, 1.5f, -1 };
            memcpy(pg->ltctxa[NV_IGRAPH_XF_LTCTXA_L0_SPT + 2 * light], spot,
                   sizeof(spot));
            for (unsigned k = 0; k < 3; k++) {
                float ambient = .1f, diffuse = .6f, specular = .2f;
                memcpy(&pg->ltctxb[NV_IGRAPH_XF_LTCTXB_L0_AMB + 6 * light][k],
                       &ambient, 4);
                memcpy(&pg->ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF + 6 * light][k],
                       &diffuse, 4);
                memcpy(&pg->ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * light][k],
                       &specular, 4);
            }
            NV2AMetalPGRAPHVertexState *fresh = capture();
            NSData *wire = fresh.snapshotData;
            NSError *error = nil;
            NV2AMetalPGRAPHVertexState *restored =
                [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire
                                                               error:&error];
            require(restored != nil, error);
            assert([wire isEqualToData:restored.snapshotData]);
            /* Both immutable states must survive replacement of the live
             * spotlight context before their GPU encoding. */
            memset(pg->ltctxa, 0, sizeof(pg->ltctxa));
            NV2AMetalProgramInput input = { 0 };
            input.attributes[0][3] = 1;
            input.attributes[2][2] = 1;
            input.attributes[4][3] = .5f;
            double factor = fmin(
                1, fmax(0, (.5 + coefficients[c][0]) /
                               (.5 * coefficients[c][1] + coefficients[c][2])));
            for (NV2AMetalPGRAPHVertexState *state in @[ fresh, restored ]) {
                NV2AMetalFixedUniforms u = state.fixedUniforms;
                assert(memcmp(u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * light],
                              coefficients[c], sizeof(coefficients[c])) == 0);
                begin();
                NV2AMetalPGRAPHVertexResult *result = encode(state, &input, 1);
                finish();
                const NV2AMetalProgramOutput *out = result.registers.contents;
                assert(!out->fault);
                for (unsigned k = 0; k < 3; k++) {
                    close_float(out->registers[3][k], .7 * factor);
                    close_float(out->registers[4][k], .2 * factor);
                }
                close_float(out->registers[3][3], .75f);
                close_float(out->registers[4][3], .5f);
                cases++;
            }
        }
    }
    assert(cases == 48);
    printf("Metal4 spotlight capture/restore: %u GPU cases PASS\n", cases);
}

static NSMutableData *legacy_fixed_capture(NSData *wire, unsigned version)
{
    assert(version >= 1 && version <= 3);
    NSMutableData *old = [wire mutableCopy];
    size_t prefix = version == 1 ?
                        offsetof(NV2AMetalFixedUniforms, specular_params) :
                        offsetof(NV2AMetalFixedUniforms, specular_params_back);
    old.length = 32 + sizeof(NV2AMetalProgramInput) + prefix;
    uint8_t *bytes = old.mutableBytes;
    bytes[7] = version;
    bytes[11] &= 15;
    uint32_t words = prefix / 4;
    for (unsigned k = 0; k < 4; k++)
        bytes[24 + k] = words >> (24 - 8 * k);
    return old;
}

static void specular_capture_tests(void)
{
    unsigned cases = 0;
    for (unsigned light = 0; light < 8; light++) {
        initialize(0, 1);
        pg->regs_[NV_PGRAPH_CSV0_C] =
            NV_PGRAPH_CSV0_C_LIGHTING | NV_PGRAPH_CSV0_C_SPECULAR_ENABLE |
            NV_PGRAPH_CSV0_C_SEPARATE_SPECULAR |
            NV_PGRAPH_CSV0_C_ALPHA_FROM_MATERIAL_SPECULAR;
        pg->regs_[NV_PGRAPH_CSV0_D] = NV_PGRAPH_CSV0_D_LIGHT0_INFINITE
                                      << (2 * light);
        pg->light_infinite_direction[light][2] = 1;
        pg->light_infinite_half_vector[light][2] = .5f;
        pg->specular_power = 2;
        const float parameters[] = { 0, 0, 1 };
        memcpy(pg->specular_params, parameters, sizeof(parameters));
        for (unsigned k = 0; k < 3; k++) {
            float color = .4f;
            memcpy(&pg->ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * light][k],
                   &color, 4);
        }
        NV2AMetalPGRAPHVertexState *fresh = capture();
        NSData *wire = fresh.snapshotData;
        const uint8_t *bytes = wire.bytes;
        assert(bytes[7] == 5);
        NSError *error = nil;
        NV2AMetalPGRAPHVertexState *restored =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire
                                                           error:&error];
        require(restored != nil, error);
        assert([wire isEqualToData:restored.snapshotData]);
        NSMutableData *v2_wire = legacy_fixed_capture(wire, 2);
        NV2AMetalPGRAPHVertexState *v2 =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:v2_wire
                                                           error:&error];
        require(v2 != nil, error);
        assert([v2_wire isEqualToData:v2.snapshotData]);
        NSMutableData *old = legacy_fixed_capture(wire, 1);
        NV2AMetalPGRAPHVertexState *legacy =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:old
                                                           error:&error];
        require(legacy != nil, error);
        assert([old isEqualToData:legacy.snapshotData]);
        assert(legacy.fixedUniforms.legacy_specular == 1);
        assert(!fresh.fixedUniforms.legacy_specular);
        memset(pg->specular_params, 0xff, sizeof(pg->specular_params));
        pg->specular_power = 99;
        NV2AMetalProgramInput input = { 0 };
        input.attributes[0][3] = 1;
        input.attributes[2][2] = 1;
        input.attributes[4][3] = .75f;
        for (NV2AMetalPGRAPHVertexState *state in
             @[ fresh, restored, v2, legacy ]) {
            begin();
            NV2AMetalPGRAPHVertexResult *result = encode(state, &input, 1);
            finish();
            const NV2AMetalProgramOutput *out = result.registers.contents;
            assert(!out->fault);
            for (unsigned k = 0; k < 3; k++) {
                close_float(out->registers[4][k], state == legacy ? .1f : .2f);
            }
            close_float(out->registers[4][3], .75f);
            cases++;
        }
        /* A current capture cannot inject the decoder-only legacy switch. */
        for (unsigned value = 1; value <= 2; value++) {
            NSMutableData *bad = [wire mutableCopy];
            uint8_t *tail = (uint8_t *)bad.mutableBytes + 32 +
                            sizeof(NV2AMetalProgramInput) +
                            offsetof(NV2AMetalFixedUniforms, legacy_specular);
            tail[3] = value;
            assert(![[NV2AMetalPGRAPHVertexState alloc]
                initWithSnapshot:bad
                           error:&error]);
        }
        NSMutableData *wrong_version = [wire mutableCopy];
        ((uint8_t *)wrong_version.mutableBytes)[7] = 1;
        assert(![[NV2AMetalPGRAPHVertexState alloc]
            initWithSnapshot:wrong_version
                       error:&error]);
        wrong_version = [old mutableCopy];
        ((uint8_t *)wrong_version.mutableBytes)[7] = 2;
        assert(![[NV2AMetalPGRAPHVertexState alloc]
            initWithSnapshot:wrong_version
                       error:&error]);
    }
    assert(cases == 32);
    printf("Metal4 specular capture/restore/legacy: %u GPU cases PASS\n",
           cases);
}

static void texgen_capture_tests(void)
{
    unsigned cases = 0;
    for (unsigned stage = 0; stage < 4; stage++) {
        for (unsigned sphere = 0; sphere < 2; sphere++) {
            for (unsigned viewer = 0; viewer < 2; viewer++) {
                initialize(0, 1);
                pg->regs_[NV_PGRAPH_CSV0_D] =
                    viewer ? NV_PGRAPH_CSV0_D_TEXGEN_REF : 0;
                unsigned mode =
                    sphere ? NV2AMetalTexgenSphere : NV2AMetalTexgenReflection;
                unsigned reg = stage < 2 ? NV_PGRAPH_CSV1_A : NV_PGRAPH_CSV1_B;
                for (unsigned k = 0; k < (sphere ? 2 : 3); k++) {
                    pg->regs_[reg] |= mode << (4 + 16 * (stage % 2) + 3 * k);
                }
                NV2AMetalPGRAPHVertexState *fresh = capture();
                assert(fresh.fixedUniforms.texgen_infinite_viewer == viewer);
                NSData *wire = fresh.snapshotData;
                assert(((const uint8_t *)wire.bytes)[7] == 5);
                NSError *error = nil;
                NV2AMetalPGRAPHVertexState *restored =
                    [[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:wire
                                   error:&error];
                require(restored != nil, error);
                assert([wire isEqualToData:restored.snapshotData]);
                pg->regs_[NV_PGRAPH_CSV0_D] ^= NV_PGRAPH_CSV0_D_TEXGEN_REF;
                NV2AMetalProgramInput input = { 0 };
                input.attributes[0][0] = 3;
                input.attributes[0][2] = 4;
                input.attributes[0][3] = 1;
                input.attributes[2][0] = input.attributes[2][2] = .5f;
                input.attributes[9 + stage][2] = 77;
                input.attributes[9 + stage][3] = .75f;
                double reflected[3] = { viewer ? -.5 : -.1, 0,
                                        viewer ? .5 : .1 };
                double denominator =
                    2 * sqrt(reflected[0] * reflected[0] +
                             (reflected[2] + 1) * (reflected[2] + 1));
                for (NV2AMetalPGRAPHVertexState *state in
                     @[ fresh, restored ]) {
                    begin();
                    NV2AMetalPGRAPHVertexResult *result =
                        encode(state, &input, 1);
                    finish();
                    const NV2AMetalProgramOutput *out =
                        result.registers.contents;
                    const NV2AMetalVertex *native = result.vertices.contents;
                    assert(!out->fault);
                    for (unsigned k = 0; k < 4; k++) {
                        float expected =
                            k == 3           ? .75f :
                            sphere && k == 2 ? 77 :
                            sphere           ? reflected[k] / denominator + .5 :
                                               reflected[k];
                        close_float(out->registers[9 + stage][k], expected);
                        close_float(native->texcoord[stage][k], expected);
                    }
                    cases++;
                }
                size_t offset =
                    32 + sizeof(NV2AMetalProgramInput) +
                    offsetof(NV2AMetalFixedUniforms, texgen_infinite_viewer);
                for (uint32_t value = 2; value <= 3; value++) {
                    NSMutableData *bad = [wire mutableCopy];
                    uint8_t *field = (uint8_t *)bad.mutableBytes + offset;
                    field[3] = value;
                    assert(![[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:bad
                                   error:&error]);
                }
                if (viewer) {
                    NSMutableData *bad = [wire mutableCopy];
                    ((uint8_t *)bad.mutableBytes)[7] = 2;
                    assert(![[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:bad
                                   error:&error]);
                    bad = legacy_fixed_capture(wire, 1);
                    assert(![[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:bad
                                   error:&error]);
                }
            }
        }
    }
    assert(cases == 32);
    printf("Metal4 texgen capture/restore: %u GPU cases PASS\n", cases);
}

static void back_lighting_capture_tests(void)
{
    unsigned cases = 0;
    for (unsigned light = 0; light < 8; light++) {
        for (unsigned material = 0; material < 81; material++) {
            initialize(0, 1);
            pg->regs_[NV_PGRAPH_CSV0_C] =
                NV_PGRAPH_CSV0_C_LIGHTING | NV_PGRAPH_CSV0_C_TWO_SIDE |
                NV_PGRAPH_CSV0_C_SPECULAR_ENABLE |
                NV_PGRAPH_CSV0_C_SEPARATE_SPECULAR |
                NV_PGRAPH_CSV0_C_ALPHA_FROM_MATERIAL_SPECULAR;
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C],
                     NV_PGRAPH_CSV0_C_BACK_EMISSION, material % 3);
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C], NV_PGRAPH_CSV0_C_BACK_AMBIENT,
                     material / 3 % 3);
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C], NV_PGRAPH_CSV0_C_BACK_DIFFUSE,
                     material / 9 % 3);
            SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C],
                     NV_PGRAPH_CSV0_C_BACK_SPECULAR, material / 27);
            pg->regs_[NV_PGRAPH_CSV0_D] = NV_PGRAPH_CSV0_D_LIGHT0_INFINITE
                                          << (2 * light);
            pg->light_infinite_direction[light][2] = -1;
            pg->light_infinite_half_vector[light][2] = -.5f;
            pg->material_alpha_back = .375f;
            pg->specular_params_back[2] = 2;
            for (unsigned k = 0; k < 3; k++) {
                float color = .4f;
                memcpy(&pg->ltctxb[NV_IGRAPH_XF_LTCTXB_L0_BSPC + 6 * light][k],
                       &color, 4);
            }
            NV2AMetalPGRAPHVertexState *fresh = capture();
            NSData *wire = fresh.snapshotData;
            NSError *error = nil;
            NV2AMetalPGRAPHVertexState *restored =
                [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire
                                                               error:&error];
            require(restored != nil, error);
            assert([wire isEqualToData:restored.snapshotData]);
            for (unsigned version = 1; version <= 3; version++) {
                NSData *old = legacy_fixed_capture(wire, version);
                NV2AMetalPGRAPHVertexState *legacy =
                    [[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:old
                                   error:&error];
                require(legacy != nil, error);
                assert([old isEqualToData:legacy.snapshotData]);
                assert(!legacy.fixedUniforms.two_side &&
                       !legacy.fixedUniforms.material_alpha_back);
            }
            const size_t fields[] = {
                offsetof(NV2AMetalFixedUniforms, back_emission_src),
                offsetof(NV2AMetalFixedUniforms, back_ambient_src),
                offsetof(NV2AMetalFixedUniforms, back_diffuse_src),
                offsetof(NV2AMetalFixedUniforms, back_specular_src),
                offsetof(NV2AMetalFixedUniforms, two_side),
            };
            for (unsigned field = 0; field < 5; field++) {
                NSMutableData *bad = [wire mutableCopy];
                ((uint8_t *)
                     bad.mutableBytes)[32 + sizeof(NV2AMetalProgramInput) +
                                       fields[field] + 3] = field == 4 ? 2 : 3;
                assert(![[NV2AMetalPGRAPHVertexState alloc]
                    initWithSnapshot:bad
                               error:&error]);
            }
            pg->material_alpha_back = 99;
            memset(pg->specular_params_back, 0xff,
                   sizeof(pg->specular_params_back));
            pg->regs_[NV_PGRAPH_CSV0_C] = 0;
            memset(pg->ltctxb, 0xff, sizeof(pg->ltctxb));
            NV2AMetalProgramInput input = { 0 };
            input.attributes[0][3] = input.attributes[2][2] = 1;
            for (unsigned k = 0; k < 4; k++) {
                input.attributes[3][k] = .5f;
                input.attributes[4][k] = .25f;
                input.attributes[7][k] = 9;
                input.attributes[8][k] = -9;
            }
            for (NV2AMetalPGRAPHVertexState *s in @[ fresh, restored ]) {
                begin();
                NV2AMetalPGRAPHVertexResult *result = encode(s, &input, 1);
                finish();
                const NV2AMetalProgramOutput *raw = result.registers.contents;
                const NV2AMetalVertex *native = result.vertices.contents;
                float alpha = material / 9 % 3 == 0 ? .375f :
                              material / 9 % 3 == 1 ? .5f :
                                                      .25f;
                close_float(raw->registers[7][3], alpha);
                close_float(native->color[2][3], alpha);
                for (unsigned k = 0; k < 3; k++) {
                    float multiplier = material / 27 == 0 ? 1 :
                                       material / 27 == 1 ? .5f :
                                                            .25f;
                    close_float(raw->registers[8][k], .1f * multiplier);
                    close_float(native->color[3][k], .1f * multiplier);
                }
                close_float(raw->registers[8][3], .25f);
                cases++;
            }
        }
    }
    assert(cases == 1296);
    printf("Metal4 back lighting capture/restore: %u GPU cases PASS\n", cases);
}

static void unlit_back_capture_tests(void)
{
    NV2AMetalProgramInput inputs[4] = { 0 };
    for (unsigned i = 0; i < 4; i++) {
        inputs[i].attributes[0][3] = 1;
        for (unsigned k = 0; k < 4; k++) {
            inputs[i].attributes[7][k] = .125f * (i + k + 1);
            inputs[i].attributes[8][k] = .2f * (i + k + 1);
        }
    }
    unsigned vertices = 0;
    for (unsigned flags = 0; flags < 8; flags++) {
        for (unsigned programmed = 0; programmed < 2; programmed++) {
            initialize(0, 1);
            pg->regs_[NV_PGRAPH_CSV0_C] =
                (flags & 1 ? NV_PGRAPH_CSV0_C_SPECULAR_ENABLE : 0) |
                (flags & 2 ? NV_PGRAPH_CSV0_C_SEPARATE_SPECULAR : 0) |
                (flags & 4 ? 0 : NV_PGRAPH_CSV0_C_ALPHA_FROM_MATERIAL_SPECULAR);
            if (programmed) {
                pg->regs_[NV_PGRAPH_CSV0_D] =
                    2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                mov(0, 0, 0, false, false);
                mov(1, 7, 7, false, false);
                mov(2, 8, 8, false, true);
            }
            NV2AMetalPGRAPHVertexState *fresh = capture();
            NSError *error = nil;
            NSData *wire = fresh.snapshotData;
            NV2AMetalPGRAPHVertexState *restored =
                [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire
                                                               error:&error];
            require(restored != nil, error);
            assert([wire isEqualToData:restored.snapshotData]);
            pg->regs_[NV_PGRAPH_CSV0_C] |= NV_PGRAPH_CSV0_C_LIGHTING;
            memset(pg->program_data, 0, sizeof(pg->program_data));
            for (NV2AMetalPGRAPHVertexState *state in @[ fresh, restored ]) {
                begin();
                NV2AMetalPGRAPHVertexResult *result = encode(state, inputs, 4);
                finish();
                const NV2AMetalProgramOutput *out = result.registers.contents;
                const NV2AMetalVertex *native = result.vertices.contents;
                for (unsigned i = 0; i < 4; i++) {
                    assert(!out[i].fault);
                    for (unsigned side = 0; side < 2; side++) {
                        for (unsigned k = 0; k < 4; k++) {
                            float expected =
                                programmed ? inputs[i].attributes[7 + side][k] :
                                             k == 3;
                            close_float(out[i].registers[7 + side][k],
                                        expected);
                            expected = fminf(1, expected);
                            if (programmed && side == 1) {
                                if (!(flags & 1))
                                    expected = k == 3;
                                if (k == 3 && (flags & 4))
                                    expected = 1;
                            }
                            close_float(native[i].color[2 + side][k], expected);
                        }
                    }
                    vertices++;
                }
            }
        }
    }
    assert(vertices == 128);
    printf("Metal4 unlit back capture/program controls: %u GPU vertices PASS\n",
           vertices);
}

static void full_chain_tests(void)
{
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    require(fetch != nil, error);
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    require(geometry != nil, error);
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(pixel != nil, error);
    for (unsigned programmable = 0; programmable < 2; programmable++) {
        initialize(0, 1);
        if (programmable) {
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            mov(0, 0, 0, false, false);
            mov(1, 3, 3, false, true);
        }
        pg->regs_[NV_PGRAPH_CONTROL_0] =
            NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
            NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
            NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
            NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
        pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_V0;
        pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
            (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
        reg_float(NV_PGRAPH_ZCLIPMAX, 65535);
        pg->regs_[NV_PGRAPH_WINDOWCLIPX0] = pg->regs_[NV_PGRAPH_WINDOWCLIPY0] =
            7 << 16;
        for (unsigned i = 1; i < 8; i++)
            pg->regs_[NV_PGRAPH_WINDOWCLIPX0 + i * 4] =
                pg->regs_[NV_PGRAPH_WINDOWCLIPY0 + i * 4] = 1;
        pg->vertex_attributes[3].inline_value[1] =
            pg->vertex_attributes[3].inline_value[3] = 1;
        NV2AMetalPGRAPHVertexState *s = capture();
        NV2AMetalPGRAPHPixelState *ps =
            [[NV2AMetalPGRAPHPixelState alloc] initWithState:pg
                                                    textures:nil
                                                      device:commands.device
                                                       error:&error];
        require(ps != nil, error);
        const float positions[3][4] = { { 0, 0, 32768, 1 },
                                        { 8, 0, 32768, 1 },
                                        { 0, 8, 32768, 1 } };
        id<MTLBuffer> positions_buffer =
            [commands.device newBufferWithBytes:positions
                                         length:sizeof(positions)
                                        options:MTLResourceStorageModeShared];
        assert(positions_buffer);
        NV2AMetalAttributeSource sources[16] = { 0 };
        NV2AMetalProgramInput values = s.inlineValues;
        for (unsigned i = 0; i < 16; i++)
            memcpy(sources[i].inline_value, values.attributes[i], 16);
        sources[0] = (NV2AMetalAttributeSource){
            .buffer = positions_buffer,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .count = 4,
            .stride = 16
        };
        memset(pg, 0, sizeof(*pg));
        begin();
        NV2AMetalFetchResult *f = [fetch encodeSources:sources
                                                 count:3
                                           firstVertex:0
                                               indices:nil
                                           indexOffset:0
                                             indexSize:0
                                              commands:commands
                                                 error:&error];
        require(f != nil, error);
        NV2AMetalPGRAPHVertexResult *r = [s encodeAttributes:f.attributes
                                                       count:3
                                                     program:program
                                                       fixed:fixed
                                                    commands:commands
                                                       error:&error];
        require(r != nil, error);
        NV2AMetalGeometryResult *g =
            [geometry encodeVertices:r.vertices
                               count:3
                           primitive:NV2AMetalPrimitiveTriangles
                             polygon:NV2AMetalPolygonFill
                              smooth:s.smooth
                      firstProvoking:YES
                        zPerspective:s.zPerspective
                            commands:commands
                               error:&error];
        require(g != nil, error);
        MTLTextureDescriptor *d = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:8
                                        height:8
                                     mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        d.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
        assert(target);
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        NV2AMetalPixelUniforms u = ps.uniforms;
        NV2AMetalPixelTexture textures[4] = { 0 };
        require([ps copyTextureBindings:textures error:&error], error);
        require([pixel encodeVertices:g.vertices
                                count:g.vertexCount
                            primitive:g.primitiveType
                             uniforms:&u
                             textures:textures
                                 pass:pass
                            drawState:ps.raster
                             commands:commands
                                error:&error],
                error);
        finish();
        const uint32_t *faults = f.faults.contents;
        const NV2AMetalProgramOutput *raw = r.registers.contents;
        for (unsigned i = 0; i < 3; i++)
            assert(!faults[i] && !raw[i].fault);
        float color[4];
        [target getBytes:color
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(1, 1, 1, 1)
             mipmapLevel:0];
        assert(color[0] == 0 && color[1] == 1 && color[2] == 0 &&
               color[3] == 1);
        [target getBytes:color
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(7, 7, 1, 1)
             mipmapLevel:0];
        assert(color[0] == 1 && color[1] == 0);
        chains++;
    }
}
static void rejection_tests(void)
{
    NSError *error = nil;
    for (unsigned i = 0; i < 9; i++) {
        initialize(0, 1);
        switch (i) {
        case 0:
            pg->surface_binding_dim.width = -1;
            break;
        case 1:
            pg->surface_shape.anti_aliasing = 3;
            break;
        case 2:
            pg->regs_[NV_PGRAPH_CSV0_D] = 1u << 30;
            break;
        case 3:
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            pg->regs_[NV_PGRAPH_CSV0_C] = 136 << 8;
            break;
        case 4:
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            break;
        case 5:
            pg->regs_[NV_PGRAPH_CSV0_D] = 7u << 26;
            break;
        case 6:
            pg->regs_[NV_PGRAPH_CSV0_C] = 3u << 19;
            break;
        case 7:
            pg->regs_[NV_PGRAPH_CONTROL_3] |=
                NV_PGRAPH_CONTROL_3_FOGENABLE | 2u << 16;
            break;
        case 8:
            pg->regs_[NV_PGRAPH_CSV1_A] = 3u << 13;
            break;
        }
        assert(![[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                            error:&error] &&
               !commands.commandBuffer);
    }
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        pg = g_new0(PGRAPHState, 1);
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        program = [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                           error:&error];
        require(program != nil, error);
        fixed = [[NV2AMetalVertexFixed alloc] initWithDevice:commands.device
                                                       error:&error];
        require(fixed != nil, error);
        metadata_tests();
        programmable_tests();
        fixed_tests();
        spotlight_capture_tests();
        specular_capture_tests();
        texgen_capture_tests();
        unlit_back_capture_tests();
        back_lighting_capture_tests();
        full_chain_tests();
        rejection_tests();
        g_free(pg);
        printf("Metal 4 PGRAPH vertex: %u immutable captures, %u GPU vertex "
               "dispatches, %u full GPU chains PASS\n",
               captures, dispatches, chains);
    }
    return 0;
}
