/* Complete setters between End/Begin; no claim about inside-Begin legality.
 * Reuses the actual PGRAPH/Metal Renderer fixture and GLSL capture functions.
 * No OpenGL context, application, VM or window starts.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_XF_BOUNDARIES_H
#define TEST_METAL_XF_BOUNDARIES_H

#include "hw/xbox/nv2a/pgraph/glsl/vsh.h"

typedef struct XfBoundaryMethod {
    const char *name;
    unsigned method, words, stride;
    uint32_t values[2];
    bool floats, matrix;
} XfBoundaryMethod;

#define XF_WORD(name, a, b) \
    { #name, NV097_##name, 1, 4, { a, b }, false, false }
#define XF_FLOAT(name, words) \
    { #name, NV097_##name, words, 4, { 0, 0 }, true, false }
#define XF_MATRIX(name, words) \
    { #name, NV097_##name, words, 4, { 0, 0 }, true, true }
#define XF_TEXGEN(name)                                                 \
    { #name,                                                            \
      NV097_##name,                                                     \
      4,                                                                \
      16,                                                               \
      { NV097_SET_TEXGEN_S_DISABLE, NV097_SET_TEXGEN_S_OBJECT_LINEAR }, \
      false,                                                            \
      false }
static const XfBoundaryMethod xf_boundary_methods[] = {
    XF_FLOAT(SET_BACK_LIGHT_AMBIENT_COLOR, 8 * 16),
    XF_FLOAT(SET_BACK_MATERIAL_ALPHA, 1),
    XF_FLOAT(SET_BACK_MATERIAL_EMISSION, 3),
    XF_FLOAT(SET_BACK_SCENE_AMBIENT_COLOR, 3),
    XF_WORD(SET_COLOR_MATERIAL, 0x5555, 0xaaaa),
    XF_MATRIX(SET_COMPOSITE_MATRIX, 16),
    XF_WORD(SET_CONTROL0, 0, NV097_SET_CONTROL0_Z_PERSPECTIVE_ENABLE),
    XF_FLOAT(SET_EYE_DIRECTION, 3),
    XF_FLOAT(SET_EYE_POSITION, 4),
    XF_WORD(SET_FOG_ENABLE, 0, 1),
    XF_WORD(SET_FOG_GEN_MODE, NV097_SET_FOG_GEN_MODE_V_PLANAR,
            NV097_SET_FOG_GEN_MODE_V_RADIAL),
    XF_WORD(SET_FOG_MODE, NV097_SET_FOG_MODE_V_LINEAR,
            NV097_SET_FOG_MODE_V_EXP2),
    XF_FLOAT(SET_FOG_PARAMS, 3),
    XF_FLOAT(SET_FOG_PLANE, 4),
    XF_MATRIX(SET_INVERSE_MODEL_VIEW_MATRIX, 64),
    XF_WORD(SET_LIGHTING_ENABLE, 0, 1),
    XF_FLOAT(SET_LIGHT_AMBIENT_COLOR, 8 * 32),
    XF_WORD(SET_LIGHT_CONTROL, 0,
            NV097_SET_LIGHT_CONTROL_SEPARATE_SPECULAR |
                NV097_SET_LIGHT_CONTROL_LOCALEYE |
                NV097_SET_LIGHT_CONTROL_ALPHA_FROM_MATERIAL_SPECULAR),
    XF_WORD(SET_LIGHT_ENABLE_MASK, 0x5555, 0xaaaa),
    XF_WORD(SET_LIGHT_TWO_SIDE_ENABLE, 0, 1),
    XF_FLOAT(SET_MATERIAL_ALPHA, 1),
    XF_FLOAT(SET_MATERIAL_EMISSION, 3),
    XF_MATRIX(SET_MODEL_VIEW_MATRIX, 64),
    XF_WORD(SET_NORMALIZATION_ENABLE, 0, 1),
    XF_FLOAT(SET_POINT_PARAMS, 8),
    XF_WORD(SET_POINT_PARAMS_ENABLE, 0, 1),
    XF_WORD(SET_POINT_SIZE, 8, 16),
    XF_MATRIX(SET_PROJECTION_MATRIX, 16),
    XF_FLOAT(SET_SCENE_AMBIENT_COLOR, 3),
    XF_WORD(SET_SKIN_MODE, 0, 1),
    XF_WORD(SET_SPECULAR_ENABLE, 0, 1),
    XF_FLOAT(SET_SPECULAR_PARAMS, 6),
    XF_FLOAT(SET_SPECULAR_PARAMS_BACK, 6),
    XF_FLOAT(SET_TEXGEN_PLANE_S, 64),
    XF_TEXGEN(SET_TEXGEN_Q),
    XF_TEXGEN(SET_TEXGEN_R),
    XF_TEXGEN(SET_TEXGEN_S),
    XF_TEXGEN(SET_TEXGEN_T),
    XF_WORD(SET_TEXGEN_VIEW_MODEL, 0, 1),
    XF_MATRIX(SET_TEXTURE_MATRIX, 64),
    { "SET_TEXTURE_MATRIX_ENABLE",
      NV097_SET_TEXTURE_MATRIX_ENABLE,
      4,
      4,
      { 0, 1 },
      false,
      false },
    XF_FLOAT(SET_VIEWPORT_OFFSET, 4),
    XF_FLOAT(SET_VIEWPORT_SCALE, 4),
};
#undef XF_WORD
#undef XF_FLOAT
#undef XF_MATRIX
#undef XF_TEXGEN

static void xf_boundary_set(const XfBoundaryMethod *m, unsigned generation)
{
    assert(state->pgraph.primitive_mode == PRIM_TYPE_INVALID);
    for (unsigned word = 0; word < m->words; word++) {
        /* These two dispatch ranges include holes between light records. */
        if ((m->method == NV097_SET_BACK_LIGHT_AMBIENT_COLOR &&
             word % 16 >= 9) ||
            (m->method == NV097_SET_LIGHT_AMBIENT_COLOR && word % 32 >= 29))
            continue;
        if (m->floats) {
            float value = m->matrix ?
                              ((word % 16) % 5 == 0 ? 1.f + generation : 0.f) :
                              .125f * (1 + generation) + .015625f * word;
            send_float_method(m->method + word * m->stride, value);
        } else {
            send_method(m->method + word * m->stride, m->values[generation]);
        }
    }
}

static void xf_boundary_compare(NV2AMetalPGRAPHVertexState *capture)
{
    PGRAPHState *pg = &state->pgraph;
    VshState reference = { 0 };
    VshUniformValues values = { 0 };
    VshUniformLocs locations = { 0 }; /* Request every GLSL uniform. */
    pgraph_glsl_set_vsh_state(pg, &reference);
    pgraph_glsl_set_vsh_uniform_values(pg, &reference, locations, &values);
    assert(reference.is_fixed_function && !capture.programmed);
    NV2AMetalFixedUniforms fixed = capture.fixedUniforms;
    NV2AMetalProgramUniforms common = capture.programUniforms;
    assert(!memcmp(common.constants, values.c, sizeof(values.c)));
    assert(!memcmp(fixed.ltctxa, values.ltctxa, sizeof(values.ltctxa)));
    assert(!memcmp(fixed.ltctxb, values.ltctxb, sizeof(values.ltctxb)));
    assert(!memcmp(fixed.ltc1, values.ltc1, sizeof(values.ltc1)));
    assert(!memcmp(fixed.light_direction, values.lightInfiniteDirection,
                   sizeof(values.lightInfiniteDirection)));
    assert(!memcmp(fixed.light_half_vector, values.lightInfiniteHalfVector,
                   sizeof(values.lightInfiniteHalfVector)));
    assert(!memcmp(fixed.light_position, values.lightLocalPosition,
                   sizeof(values.lightLocalPosition)));
    assert(!memcmp(fixed.light_attenuation, values.lightLocalAttenuation,
                   sizeof(values.lightLocalAttenuation)));
    assert(!memcmp(fixed.point_params, values.pointParams,
                   sizeof(values.pointParams)));
    assert(!memcmp(common.fog, values.fogParam, sizeof(values.fogParam)));
    assert(fixed.material_alpha == values.material_alpha[0]);
    assert(fixed.specular_power == values.specularPower[0]);
    assert(fixed.specular_power == reference.specular_power);
    assert(fixed.common.point_size == reference.point_size);
    assert(fixed.common.point_scale == reference.surface_scale_factor);
    assert(fixed.common.point_programmed == reference.point_params_enable);
    assert(fixed.common.specular_enable == reference.specular_enable);
    assert(fixed.common.ignore_specular_alpha ==
           reference.ignore_specular_alpha);
    assert(fixed.common.fog_enable == reference.fog_enable);
    if (reference.fog_enable) {
        assert(fixed.common.fog_mode == (unsigned)reference.fog_mode);
        assert(fixed.foggen == (unsigned)reference.fixed_function.foggen);
    }
    assert(capture.zPerspective == reference.z_perspective);
    assert(capture.smooth == reference.smooth_shading);
    assert(fixed.skinning == (unsigned)reference.fixed_function.skinning);
    assert(fixed.normalization == reference.fixed_function.normalization);
    assert(fixed.lighting == reference.fixed_function.lighting);
    assert(fixed.local_eye == reference.fixed_function.local_eye);
    assert(fixed.separate_specular == reference.separate_specular);
    assert(fixed.emission_src ==
           (unsigned)reference.fixed_function.emission_src);
    assert(fixed.ambient_src == (unsigned)reference.fixed_function.ambient_src);
    assert(fixed.diffuse_src == (unsigned)reference.fixed_function.diffuse_src);
    assert(fixed.specular_src ==
           (unsigned)reference.fixed_function.specular_src);
    for (unsigned light = 0; light < 8; light++)
        assert(fixed.light[light] ==
               (unsigned)reference.fixed_function.light[light]);
    for (unsigned stage = 0; stage < 4; stage++) {
        assert(fixed.texture_matrix_enable[stage] ==
               reference.fixed_function.texture_matrix_enable[stage]);
        for (unsigned component = 0; component < 4; component++)
            assert(fixed.texgen[stage][component] ==
                   (unsigned)reference.fixed_function.texgen[stage][component]);
    }
    /* These native fields have no corresponding GLSL capture field. */
    unsigned csvc = pgraph_reg_r(pg, NV_PGRAPH_CSV0_C);
    assert(fixed.two_side == !!(csvc & NV_PGRAPH_CSV0_C_TWO_SIDE));
    assert(fixed.back_emission_src ==
           GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_EMISSION));
    assert(fixed.back_ambient_src ==
           GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_AMBIENT));
    assert(fixed.back_diffuse_src ==
           GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_DIFFUSE));
    assert(fixed.back_specular_src ==
           GET_MASK(csvc, NV_PGRAPH_CSV0_C_BACK_SPECULAR));
    assert(fixed.material_alpha_back == pg->material_alpha_back);
    assert(!memcmp(fixed.specular_params, pg->specular_params,
                   sizeof(fixed.specular_params)));
    assert(!memcmp(fixed.specular_params_back, pg->specular_params_back,
                   sizeof(fixed.specular_params_back)));
    assert(
        fixed.texgen_infinite_viewer ==
        !!(pgraph_reg_r(pg, NV_PGRAPH_CSV0_D) & NV_PGRAPH_CSV0_D_TEXGEN_REF));
}

static void xf_between_draws(void)
{
    assert(ARRAY_SIZE(xf_boundary_methods) == 43);
    unsigned cases = 0;
    for (unsigned raw = 0; raw < 2; raw++)
        for (unsigned index = 0; index < ARRAY_SIZE(xf_boundary_methods);
             index++)
            @autoreleasepool {
                const XfBoundaryMethod *m = &xf_boundary_methods[index];
                fixture();
                send_method(NV097_SET_LIGHTING_ENABLE, 1);
                send_method(NV097_SET_LIGHT_ENABLE_MASK, 0x5555);
                send_method(NV097_SET_FOG_MODE, NV097_SET_FOG_MODE_V_LINEAR);
                send_method(NV097_SET_FOG_GEN_MODE,
                            NV097_SET_FOG_GEN_MODE_V_PLANAR);
                send_method(NV097_SET_FOG_ENABLE, 1);
                send_method(NV097_SET_POINT_PARAMS_ENABLE, 1);
                if (raw)
                    send_method(NV097_SET_COLOR_MASK, 0);
                NV2AMetalPGRAPHVertexState *old = nil;
                NSData *oldBytes = nil;
                for (unsigned generation = 0; generation < 2; generation++) {
                    xf_boundary_set(m, generation);
                    if (old)
                        assert([old.snapshotData isEqualToData:oldBytes]);
                    begin(PRIM_TYPE_POINTS);
                    NSError *error = nil;
                    NV2AMetalPGRAPHVertexState *capture =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithSnapshot:draw.vertexSnapshot
                                       error:&error];
                    require(capture != nil, error);
                    xf_boundary_compare(capture);
                    if (old &&
                        [old.snapshotData isEqualToData:capture.snapshotData]) {
                        fprintf(stderr,
                                "XF boundary did not change: %s raw=%u\n",
                                m->name, raw);
                        abort();
                    }
                    old = capture;
                    oldBytes = capture.snapshotData;
                    end();
                    assert(!draw.vertexSnapshot.length);
                    cases++;
                }
            }
    assert(cases == 172);
    groups++;
    printf("XF between draws:43 complete setter families / %u captures; "
           "actual GLSL state/uniform parity, fresh raster/raw Begin, old "
           "capture immutable PASS; no inside-Begin or GPU-output claim\n",
           cases);
}
#endif
