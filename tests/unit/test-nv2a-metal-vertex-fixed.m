/*
 * Offscreen native Metal 4 fixed-function vertex tests
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#import "hw/xbox/nv2a/pgraph/metal/vertex-fixed.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Fixed vertex test failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static void check_float(float actual, float expected)
{
    if (!isfinite(actual) ||
        fabsf(actual - expected) > 0.00003f * fmaxf(1, fabsf(expected))) {
        fprintf(stderr, "Fixed vertex value: got %g, expected %g\n", actual,
                expected);
        abort();
    }
}

static void matrix(NV2AMetalFixedUniforms *u, unsigned offset, float scale)
{
    memset(u->common.constants[offset], 0, 4 * 4 * sizeof(float));
    for (unsigned i = 0; i < 3; i++) {
        u->common.constants[offset + i][i] = scale;
    }
    u->common.constants[offset + 3][3] = 1;
}

static NV2AMetalFixedUniforms uniforms(void)
{
    NV2AMetalFixedUniforms u = { 0 };
    u.common.surface_size[0] = u.common.surface_size[1] = 4;
    u.common.zmax = 16;
    u.common.point_size = 3;
    u.common.point_scale = 2;
    u.common.specular_enable = YES;
    u.separate_specular = YES;
    u.specular_params[2] = 1;
    matrix(&u, NV_IGRAPH_XF_XFCTX_CMAT0, 1);
    for (unsigned i = 0; i < 4; i++) {
        matrix(&u, NV_IGRAPH_XF_XFCTX_MMAT0 + 8 * i, 1);
        matrix(&u, NV_IGRAPH_XF_XFCTX_IMMAT0 + 8 * i, 1);
        matrix(&u, NV_IGRAPH_XF_XFCTX_T0MAT + 8 * i, 1);
        matrix(&u, NV_IGRAPH_XF_XFCTX_TG0MAT + 8 * i, 1);
    }
    return u;
}

static NV2AMetalProgramInput input(void)
{
    NV2AMetalProgramInput v = { 0 };
    const float position[] = { 1, 2, 2, 1 };
    memcpy(v.attributes[0], position, sizeof(position));
    v.attributes[2][2] = 1;
    for (unsigned color = 3; color <= 8; color++) {
        for (unsigned k = 0; k < 4; k++) {
            v.attributes[color][k] = .05f * color + .01f * k;
        }
    }
    for (unsigned t = 0; t < 4; t++) {
        for (unsigned k = 0; k < 4; k++) {
            v.attributes[9 + t][k] = 10 * t + k + .25f;
        }
    }
    return v;
}

static void begin(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
}

static void finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}

static NV2AMetalFixedResult *encode(NV2AMetalVertexFixed *fixed,
                                    NV2AMetalCommands *commands,
                                    const NV2AMetalFixedUniforms *u,
                                    const NV2AMetalProgramInput *v,
                                    NSUInteger count)
{
    NSError *error = nil;
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:v
                                     length:count * sizeof(*v)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    NV2AMetalFixedResult *result = [fixed encodeAttributes:attributes
                                                     count:count
                                                  uniforms:u
                                                  commands:commands
                                                     error:&error];
    require(result != nil, error);
    return result;
}

static NV2AMetalFixedResult *run(NV2AMetalVertexFixed *fixed,
                                 NV2AMetalCommands *commands,
                                 const NV2AMetalFixedUniforms *u,
                                 const NV2AMetalProgramInput *v)
{
    begin(commands);
    NV2AMetalFixedResult *result = encode(fixed, commands, u, v, 1);
    finish(commands);
    return result;
}

static const NV2AMetalProgramOutput *raw(NV2AMetalFixedResult *result)
{
    const NV2AMetalProgramOutput *r = result.registers.contents;
    assert(r->fault == 0);
    return r;
}

static const NV2AMetalVertex *processed(NV2AMetalFixedResult *result)
{
    return result.vertices.contents;
}

/* Nine D3D-programmed triples from the versioned Xbox spotlight suite,
 * plus exact linear and zero-denominator controls. */
static void spotlight_tests(NV2AMetalVertexFixed *fixed,
                            NV2AMetalCommands *commands)
{
    const float coefficients[][3] = {
        { 0, -.494592f, 1.494592f },
        { 0, 1, 0 },
        { -.000244f, .500122f, .499634f },
        { -.170208f, -.855843f, 1.685635f },
        { -.706496f, -2.507095f, 2.800600f },
        { -.932112f, -3.097628f, 3.165516f },
        { -.986137f, -3.165117f, 3.178980f },
        { -.993286f, -2.953324f, 2.960038f },
        { -.996561f, -3.084043f, 3.087482f },
        { 0, 0, 1 },
        { 0, 0, 0 },
    };
    const float intensities[] = { 1, 3, 7 };
    unsigned vertices = 0;
    for (unsigned light = 0; light < 8; light++) {
        for (unsigned c = 0; c < 11; c++) {
            for (unsigned a = 0; a < 3; a++) {
                float samples[] = {
                    -.25f,
                    0,
                    1.f / 1024,
                    .0625f,
                    .125f,
                    .25f,
                    .375f,
                    .5f,
                    .625f,
                    .75f,
                    .875f,
                    .9375f,
                    nextafterf(1, 0),
                    1,
                    nextafterf(1, 2),
                    1.25f,
                    1.5f,
                    -coefficients[c][0] - .00001f,
                    -coefficients[c][0],
                    -coefficients[c][0] + .00001f,
                };
                NV2AMetalProgramInput inputs[20];
                NV2AMetalFixedUniforms u = uniforms();
                u.lighting = YES;
                u.normalization = YES;
                u.specular_power = 2;
                u.material_alpha = .625f;
                u.light[light] = NV2AMetalLightSpot;
                u.ltc1[NV_IGRAPH_XF_LTC1_r0 + light][0] = 2;
                u.light_attenuation[light][0] = intensities[a];
                for (unsigned other = 0; other < 8; other++) {
                    float *k = u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * other];
                    k[0] = -1;
                    k[1] = 17;
                    k[2] = 31;
                }
                memcpy(u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * light],
                       coefficients[c], sizeof(coefficients[c]));
                u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_SPT + 2 * light][2] = 2;
                u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_SPT + 2 * light][3] = -.25f;
                for (unsigned k = 0; k < 3; k++) {
                    u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_AMB + 6 * light][k] =
                        .05f * (k + 1);
                    u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF + 6 * light][k] =
                        .1f * (k + 1);
                    u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * light][k] =
                        .075f * (k + 1);
                }
                if (c == 10) {
                    u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_AMB + 6 * light][1] = 0;
                    u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF + 6 * light][1] = 0;
                    u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * light][1] = 0;
                }
                for (unsigned i = 0; i < 20; i++) {
                    inputs[i] = input();
                    float z = (samples[i] + .25f) / 2;
                    float x = sqrtf(1 - z * z);
                    inputs[i].attributes[0][0] = -x;
                    inputs[i].attributes[0][1] = 0;
                    inputs[i].attributes[0][2] = -z;
                    inputs[i].attributes[2][0] = x;
                    inputs[i].attributes[2][1] = 0;
                    inputs[i].attributes[2][2] = z;
                }
                begin(commands);
                NV2AMetalFixedResult *result =
                    encode(fixed, commands, &u, inputs, 20);
                finish(commands);
                const NV2AMetalProgramOutput *outputs =
                    result.registers.contents;
                for (unsigned i = 0; i < 20; i++) {
                    assert(!outputs[i].fault);
                    double x = inputs[i].attributes[2][0];
                    double z = inputs[i].attributes[2][2];
                    double coordinate =
                        fmin(1, 2 * z / sqrt(x * x + z * z) - .25);
                    double factor = 0;
                    if (coordinate > 0 && coordinate > -coefficients[c][0]) {
                        double numerator = coordinate + coefficients[c][0];
                        double denominator = coefficients[c][1] * coordinate +
                                             coefficients[c][2];
                        factor = denominator == 0 ?
                                     0x1.fffffep127 :
                                     fmax(0, numerator / denominator);
                    }
                    for (unsigned k = 0; k < 3; k++) {
                        float diffuse =
                            .15f * (k + 1) * factor / intensities[a];
                        float specular =
                            .075f * (k + 1) * factor / intensities[a];
                        if (c == 10 && k == 1) {
                            diffuse = specular = 0;
                        }
                        if (fabsf(outputs[i].registers[3][k] - diffuse) >
                            .00003f * fmaxf(1, fabsf(diffuse))) {
                            fprintf(
                                stderr,
                                "Spotlight light=%u coeff=%u attenuation=%u "
                                "sample=%u: got=%g expected=%g\n",
                                light, c, a, i, outputs[i].registers[3][k],
                                diffuse);
                            abort();
                        }
                        check_float(outputs[i].registers[3][k], diffuse);
                        check_float(outputs[i].registers[4][k], specular);
                        const NV2AMetalVertex *native =
                            result.vertices.contents;
                        check_float(native[i].color[0][k], fminf(1, diffuse));
                        check_float(native[i].color[1][k], fminf(1, specular));
                    }
                    check_float(outputs[i].registers[3][3], .625f);
                    check_float(outputs[i].registers[4][3],
                                inputs[i].attributes[4][3]);
                    vertices++;
                }
            }
        }
    }
    assert(vertices == 5280);
    printf("Metal4 spotlight: %u coefficient/angle/light/attenuation vertices "
           "PASS\n",
           vertices);
}

static void specular_tests(NV2AMetalVertexFixed *fixed,
                           NV2AMetalCommands *commands)
{
    float parameters[][3] = {
        { -.838916f, -2.887156f, 3.048239f },
        { -.932112f, -3.097628f, 3.165516f },
        { 0, 0, 0 },
        { .838916f, 2.887156f, -3.048239f },
        { 0, .9f, .1f },
        { 0, -.494592f, 1.49459f },
        { -.170208f, -.855843f, 1.68563f },
        { -.421539f, -1.70592f, 2.28438f },
        { -.64766f, -2.36199f, 2.71433f },
        { -.803673f, -2.7813f, 2.97762f },
        { -.863702f, -2.92701f, 3.06331f },
        { 0, 0, 0 },
    };
    /* Exact parameters of the Xbox NonUnitNormal tests. */
    const uint32_t nonunit[] = { 0xbf78df9c, 0xc04d3531, 0x404efd4a };
    memcpy(parameters[11], nonunit, sizeof(nonunit));
    unsigned vertices = 0;
    for (unsigned light = 0; light < 8; light++) {
        for (unsigned c = 0; c < 12; c++) {
            for (unsigned material = 0; material < 3; material++) {
                for (unsigned enabled = 0; enabled < 2; enabled++) {
                    NV2AMetalFixedUniforms u = uniforms();
                    u.lighting = YES;
                    u.specular_power = 37; /* Deliberately conflicts. */
                    memcpy(u.specular_params, parameters[c],
                           sizeof(parameters[c]));
                    u.specular_src = material;
                    u.common.specular_enable = enabled;
                    u.material_alpha = .625f;
                    u.light[light] = NV2AMetalLightInfinite;
                    u.light_direction[light][2] = 1;
                    u.light_half_vector[light][0] = 1;
                    for (unsigned k = 0; k < 3; k++) {
                        u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * light][k] =
                            k == 1 ? 0 : .1f * (k + 1);
                    }
                    float angles[] = {
                        -.25f,
                        0,
                        .001f,
                        .25f,
                        .5f,
                        .75f,
                        .875f,
                        .9375f,
                        .972f,
                        .973f,
                        1,
                        1.008f,
                        1.009f,
                        1.125f,
                        -parameters[c][0] - .00001f,
                        -parameters[c][0],
                        -parameters[c][0] + .00001f,
                    };
                    NV2AMetalProgramInput inputs[51];
                    for (unsigned gate = 0; gate < 3; gate++) {
                        for (unsigned angle = 0; angle < 17; angle++) {
                            unsigned i = gate * 17 + angle;
                            inputs[i] = input();
                            inputs[i].attributes[2][0] = angles[angle];
                            inputs[i].attributes[2][1] = 0;
                            inputs[i].attributes[2][2] = 1 - (float)gate;
                        }
                    }
                    begin(commands);
                    NV2AMetalFixedResult *result =
                        encode(fixed, commands, &u, inputs, 51);
                    finish(commands);
                    const NV2AMetalProgramOutput *out =
                        result.registers.contents;
                    const NV2AMetalVertex *native = result.vertices.contents;
                    for (unsigned i = 0; i < 51; i++) {
                        double coordinate = fmax(0, inputs[i].attributes[2][0]);
                        double factor = 0;
                        if (inputs[i].attributes[2][2] > 0 &&
                            coordinate > -parameters[c][0]) {
                            double denominator = parameters[c][1] * coordinate +
                                                 parameters[c][2];
                            factor = denominator == 0 ?
                                         0x1.fffffep127 :
                                         fmin(0x1.fffffep127,
                                              fmax(0, (coordinate +
                                                       parameters[c][0]) /
                                                          denominator));
                        }
                        assert(!out[i].fault);
                        for (unsigned k = 0; k < 3; k++) {
                            double color = k == 1 ? 0 : .1f * (k + 1);
                            double material_factor =
                                material == 0 ?
                                    1 :
                                    inputs[i]
                                        .attributes[material == 1 ? 3 : 4][k];
                            float expected =
                                enabled ? color * factor * material_factor : 0;
                            if (!isfinite(out[i].registers[4][k]) ||
                                fabsf(out[i].registers[4][k] - expected) >
                                    .00003f * fmaxf(1, fabsf(expected))) {
                                fprintf(stderr,
                                        "Specular light=%u coefficients=%u "
                                        "material=%u enabled=%u input=%u: "
                                        "got=%g expected=%g\n",
                                        light, c, material, enabled, i,
                                        out[i].registers[4][k], expected);
                                abort();
                            }
                            check_float(out[i].registers[4][k], expected);
                            check_float(native[i].color[1][k],
                                        fminf(1, expected));
                            check_float(out[i].registers[3][k], 0);
                        }
                        check_float(out[i].registers[3][3], .625f);
                        check_float(out[i].registers[4][3],
                                    enabled ? inputs[i].attributes[4][3] : 1);
                        vertices++;
                    }
                }
            }
        }
    }
    assert(vertices == 29376);
    printf(
        "Metal4 specular: %u coefficient/light/material/gate vertices PASS\n",
        vertices);
}

static void specular_hardware_samples(NV2AMetalVertexFixed *fixed,
                                      NV2AMetalCommands *commands)
{
    /* Original Xbox NonUnitNormal captures, Golden commit 48dd6b93.
     * Compare center-vertex colors; this is not full raster parity. */
    const float lengths[] = { .972f, .973f, 1, 1.008f, 1.009f };
    const unsigned codes[] = { 0, 2, 255, 255, 0 };
    const uint32_t parameters[] = { 0xbf78df9c, 0xc04d3531, 0x404efd4a };
    NV2AMetalFixedUniforms u = uniforms();
    memcpy(u.specular_params, parameters, sizeof(parameters));
    u.specular_power = 125;
    u.lighting = YES;
    u.light[0] = NV2AMetalLightInfinite;
    u.light_direction[0][2] = 1;
    u.light_half_vector[0][2] = 1;
    for (unsigned k = 0; k < 3; k++) {
        u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC][k] = 1;
    }
    NV2AMetalProgramInput inputs[5];
    for (unsigned i = 0; i < 5; i++) {
        inputs[i] = input();
        inputs[i].attributes[2][2] = lengths[i];
    }
    begin(commands);
    NV2AMetalFixedResult *result = encode(fixed, commands, &u, inputs, 5);
    finish(commands);
    const NV2AMetalVertex *out = result.vertices.contents;
    for (unsigned i = 0; i < 5; i++) {
        for (unsigned k = 0; k < 3; k++) {
            unsigned code = lroundf(out[i].color[1][k] * 255);
            assert(code == codes[i]);
        }
        printf("Metal4 specular hardware center %.3f: %u/255 PASS\n",
               lengths[i], codes[i]);
    }
}

static void texgen_transform(const float rows[4][4], const double in[4],
                             double out[4])
{
    for (unsigned k = 0; k < 4; k++) {
        out[k] = 0;
        for (unsigned j = 0; j < 4; j++) {
            out[k] += rows[k][j] * in[j];
        }
    }
}

static void texgen_view_tests(NV2AMetalVertexFixed *fixed,
                              NV2AMetalCommands *commands)
{
    const float positions[][4] = {
        { 1, 2, 3, 1 }, { -2, 1, 4, 1 }, { .5f, -3, -1, 1 }, { 2, 1, .5f, 2 }
    };
    const float normals[][3] = {
        { .2f, .4f, .6f }, { -.5f, .75f, .25f }, { 0, 1, 0 }, { 1, 0, 0 }
    };
    unsigned vertices = 0;
    for (unsigned stage = 0; stage < 4; stage++) {
        for (unsigned mode = 0; mode < 6; mode++) {
            for (unsigned viewer = 0; viewer < 2; viewer++) {
                for (unsigned normalize_normal = 0; normalize_normal < 2;
                     normalize_normal++) {
                    for (unsigned texture_matrix = 0; texture_matrix < 2;
                         texture_matrix++) {
                        NV2AMetalFixedUniforms u = uniforms();
                        u.texgen_infinite_viewer = viewer;
                        u.normalization = normalize_normal;
                        u.texture_matrix_enable[stage] = texture_matrix;
                        unsigned components =
                            mode == NV2AMetalTexgenSphere ? 2 :
                            mode == NV2AMetalTexgenNormal ||
                                    mode == NV2AMetalTexgenReflection ?
                                                            3 :
                                                            4;
                        for (unsigned k = 0; k < components; k++) {
                            u.texgen[stage][k] = mode;
                        }
                        float (*mv)[4] =
                            &u.common.constants[NV_IGRAPH_XF_XFCTX_MMAT0];
                        mv[0][0] = 1.5f;
                        mv[1][1] = .75f;
                        mv[2][2] = 2;
                        mv[0][3] = .25f;
                        mv[1][3] = -.5f;
                        mv[2][3] = .125f;
                        float (*imv)[4] =
                            &u.common.constants[NV_IGRAPH_XF_XFCTX_IMMAT0];
                        imv[0][0] = .5f;
                        imv[1][1] = 1.25f;
                        imv[2][2] = .75f;
                        float (*tm)[4] =
                            &u.common.constants[NV_IGRAPH_XF_XFCTX_T0MAT +
                                                8 * stage];
                        tm[0][0] = .75f;
                        tm[1][1] = 1.25f;
                        tm[2][2] = .5f;
                        tm[0][1] = .125f;
                        tm[1][3] = -.25f;
                        NV2AMetalProgramInput inputs[16];
                        for (unsigned i = 0; i < 16; i++) {
                            inputs[i] = input();
                            memcpy(inputs[i].attributes[0], positions[i / 4],
                                   sizeof(positions[0]));
                            memcpy(inputs[i].attributes[2], normals[i % 4],
                                   sizeof(normals[0]));
                        }
                        begin(commands);
                        NV2AMetalFixedResult *result =
                            encode(fixed, commands, &u, inputs, 16);
                        finish(commands);
                        const NV2AMetalProgramOutput *out =
                            result.registers.contents;
                        const NV2AMetalVertex *native =
                            result.vertices.contents;
                        for (unsigned i = 0; i < 16; i++) {
                            double pos[4], normal[4], transformed[4], n[4];
                            for (unsigned k = 0; k < 4; k++) {
                                pos[k] = inputs[i].attributes[0][k];
                                normal[k] =
                                    k < 3 ? inputs[i].attributes[2][k] : 0;
                            }
                            texgen_transform(mv, pos, transformed);
                            texgen_transform(imv, normal, n);
                            if (normalize_normal) {
                                double length = sqrt(n[0] * n[0] + n[1] * n[1] +
                                                     n[2] * n[2]);
                                for (unsigned k = 0; k < 3; k++)
                                    n[k] /= length;
                            }
                            double view[3] = { 0, 0, 1 };
                            if (!viewer) {
                                double length =
                                    sqrt(transformed[0] * transformed[0] +
                                         transformed[1] * transformed[1] +
                                         transformed[2] * transformed[2]);
                                for (unsigned k = 0; k < 3; k++)
                                    view[k] = transformed[k] / length;
                            }
                            double dot = view[0] * n[0] + view[1] * n[1] +
                                         view[2] * n[2],
                                   reflection[3];
                            for (unsigned k = 0; k < 3; k++)
                                reflection[k] = view[k] - 2 * dot * n[k];
                            double sphere_denominator =
                                2 *
                                sqrt(reflection[0] * reflection[0] +
                                     reflection[1] * reflection[1] +
                                     (reflection[2] + 1) * (reflection[2] + 1));
                            assert(!out[i].fault);
                            for (unsigned t = 0; t < 4; t++) {
                                double expected[4];
                                for (unsigned k = 0; k < 4; k++)
                                    expected[k] =
                                        inputs[i].attributes[9 + t][k];
                                if (t == stage) {
                                    double plane[4];
                                    texgen_transform(
                                        &u.common.constants
                                             [NV_IGRAPH_XF_XFCTX_TG0MAT +
                                              8 * t],
                                        mode == NV2AMetalTexgenObjectLinear ?
                                            pos :
                                            transformed,
                                        plane);
                                    for (unsigned k = 0; k < components; k++) {
                                        switch (mode) {
                                        case NV2AMetalTexgenEyeLinear:
                                        case NV2AMetalTexgenObjectLinear:
                                            expected[k] = plane[k];
                                            break;
                                        case NV2AMetalTexgenNormal:
                                            expected[k] = n[k];
                                            break;
                                        case NV2AMetalTexgenReflection:
                                            expected[k] = reflection[k];
                                            break;
                                        case NV2AMetalTexgenSphere:
                                            expected[k] =
                                                reflection[k] /
                                                    sphere_denominator +
                                                .5;
                                            break;
                                        default:
                                            break;
                                        }
                                    }
                                    if (texture_matrix) {
                                        double value[4];
                                        memcpy(value, expected, sizeof(value));
                                        texgen_transform(tm, value, expected);
                                    }
                                }
                                for (unsigned k = 0; k < 4; k++) {
                                    check_float(out[i].registers[9 + t][k],
                                                expected[k]);
                                    check_float(native[i].texcoord[t][k],
                                                expected[k]);
                                }
                            }
                            vertices++;
                        }
                    }
                }
            }
        }
    }
    assert(vertices == 3072);
    printf("Metal4 texgen view model: %u stage/mode/view/normal/matrix "
           "vertices PASS\n",
           vertices);
}


static void texgen_mixed_tests(NV2AMetalVertexFixed *fixed,
                               NV2AMetalCommands *commands)
{
    const unsigned r_modes[] = { NV2AMetalTexgenDisabled,
                                 NV2AMetalTexgenEyeLinear,
                                 NV2AMetalTexgenObjectLinear,
                                 NV2AMetalTexgenNormal,
                                 NV2AMetalTexgenReflection };
    NV2AMetalProgramInput inputs[4];
    for (unsigned i = 0; i < 4; i++) {
        inputs[i] = input();
        inputs[i].attributes[0][0] = -.75f + .5f * i;
        inputs[i].attributes[0][1] = .25f - .75f * i;
        inputs[i].attributes[0][2] = 1.5f + .25f * i;
        inputs[i].attributes[0][3] = 1 + .25f * i;
        inputs[i].attributes[2][0] = .2f - .15f * i;
        inputs[i].attributes[2][1] = .3f + .1f * i;
        inputs[i].attributes[2][2] = .4f - .1f * i;
    }
    unsigned vertices = 0, rejected = 0;
    bool seen[4][6][6][6][6] = {};
    for (unsigned viewer = 0; viewer < 2; viewer++) {
        for (unsigned pattern = 0; pattern < 540; pattern++) {
            NV2AMetalFixedUniforms u = uniforms();
            u.texgen_infinite_viewer = viewer;
            u.normalization = pattern & 1;
            float (*mv)[4] = &u.common.constants[NV_IGRAPH_XF_XFCTX_MMAT0];
            mv[0][0] = 1.25f;
            mv[0][3] = .5f;
            mv[1][1] = .75f;
            mv[1][3] = -.25f;
            mv[2][2] = 1.5f;
            float (*imv)[4] = &u.common.constants[NV_IGRAPH_XF_XFCTX_IMMAT0];
            imv[0][0] = .75f;
            imv[1][1] = 1.25f;
            imv[2][2] = .5f;
            for (unsigned t = 0; t < 4; t++) {
                unsigned code = (pattern + 137 * t) % 540;
                u.texgen[t][0] = code % 6;
                code /= 6;
                u.texgen[t][1] = code % 6;
                code /= 6;
                u.texgen[t][2] = r_modes[code % 5];
                u.texgen[t][3] = code / 5;
                seen[t][u.texgen[t][0]][u.texgen[t][1]][u.texgen[t][2]]
                    [u.texgen[t][3]] = true;
                u.texture_matrix_enable[t] = (pattern >> 1 ^ t) & 1;
                float (*plane)[4] =
                    &u.common.constants[NV_IGRAPH_XF_XFCTX_TG0MAT + 8 * t];
                plane[0][1] = .125f * (t + 1);
                plane[1][3] = -.25f * (t + 1);
                plane[2][0] = -.125f;
                plane[3][2] = .0625f;
                float (*tm)[4] =
                    &u.common.constants[NV_IGRAPH_XF_XFCTX_T0MAT + 8 * t];
                tm[0][0] = .75f;
                tm[0][2] = .125f;
                tm[0][3] = .25f;
                tm[1][1] = 1.25f;
                tm[1][3] = -.125f;
                tm[2][0] = -.25f;
                tm[3][1] = .0625f;
            }
            begin(commands);
            NV2AMetalFixedResult *result =
                encode(fixed, commands, &u, inputs, 4);
            finish(commands);
            const NV2AMetalProgramOutput *out = result.registers.contents;
            const NV2AMetalVertex *native = result.vertices.contents;
            for (unsigned i = 0; i < 4; i++) {
                double pos[4], normal[4], eye[4], n[4];
                for (unsigned k = 0; k < 4; k++) {
                    pos[k] = inputs[i].attributes[0][k];
                    normal[k] = k < 3 ? inputs[i].attributes[2][k] : 0;
                }
                texgen_transform(mv, pos, eye);
                texgen_transform(imv, normal, n);
                if (u.normalization) {
                    double length =
                        sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
                    for (unsigned k = 0; k < 3; k++)
                        n[k] /= length;
                }
                double view[3] = { 0, 0, 1 };
                if (!viewer) {
                    double length = sqrt(eye[0] * eye[0] + eye[1] * eye[1] +
                                         eye[2] * eye[2]);
                    for (unsigned k = 0; k < 3; k++)
                        view[k] = eye[k] / length;
                }
                double dot = view[0] * n[0] + view[1] * n[1] + view[2] * n[2];
                double reflected[3];
                for (unsigned k = 0; k < 3; k++)
                    reflected[k] = view[k] - 2 * dot * n[k];
                double denominator =
                    2 * sqrt(reflected[0] * reflected[0] +
                             reflected[1] * reflected[1] +
                             (reflected[2] + 1) * (reflected[2] + 1));
                assert(!out[i].fault);
                for (unsigned t = 0; t < 4; t++) {
                    double expected[4], value[4];
                    for (unsigned k = 0; k < 4; k++) {
                        unsigned mode = u.texgen[t][k];
                        const float *plane =
                            u.common.constants[NV_IGRAPH_XF_XFCTX_TG0MAT +
                                               8 * t + k];
                        value[k] = inputs[i].attributes[9 + t][k];
                        if (mode == NV2AMetalTexgenEyeLinear ||
                            mode == NV2AMetalTexgenObjectLinear) {
                            value[k] = 0;
                            for (unsigned j = 0; j < 4; j++)
                                value[k] +=
                                    plane[j] *
                                    (mode == NV2AMetalTexgenEyeLinear ? eye[j] :
                                                                        pos[j]);
                        } else if (mode == NV2AMetalTexgenNormal) {
                            value[k] = n[k];
                        } else if (mode == NV2AMetalTexgenReflection) {
                            value[k] = reflected[k];
                        } else if (mode == NV2AMetalTexgenSphere) {
                            value[k] = reflected[k] / denominator + .5;
                        }
                    }
                    if (u.texture_matrix_enable[t]) {
                        texgen_transform(
                            &u.common
                                 .constants[NV_IGRAPH_XF_XFCTX_T0MAT + 8 * t],
                            value, expected);
                    } else {
                        memcpy(expected, value, sizeof(expected));
                    }
                    for (unsigned k = 0; k < 4; k++) {
                        check_float(out[i].registers[9 + t][k], expected[k]);
                        check_float(native[i].texcoord[t][k], expected[k]);
                    }
                }
                vertices++;
            }
        }
    }
    NV2AMetalFixedUniforms u = uniforms();
    for (unsigned t = 0; t < 4; t++) {
        for (unsigned s = 0; s < 6; s++)
            for (unsigned v = 0; v < 6; v++)
                for (unsigned r = 0; r < 6; r++)
                    for (unsigned q = 0; q < 6; q++) {
                        u.texgen[t][0] = s;
                        u.texgen[t][1] = v;
                        u.texgen[t][2] = r;
                        u.texgen[t][3] = q;
                        bool valid = r != NV2AMetalTexgenSphere &&
                                     q < NV2AMetalTexgenSphere;
                        assert(seen[t][s][v][r][q] == valid);
                        NSError *error = nil;
                        assert(nv2a_metal_fixed_validate(&u, &error) == valid);
                        assert((error != nil) == !valid);
                        rejected += !valid;
                    }
        memset(u.texgen[t], 0, sizeof(u.texgen[t]));
    }
    assert(vertices == 4320 && rejected == 3024);
    printf("Metal4 mixed texgen: 540 mode tuples per stage, %u GPU vertices, "
           "%u invalid states PASS\n",
           vertices, rejected);
}

static void unlit_back_color_tests(NV2AMetalVertexFixed *fixed,
                                   NV2AMetalCommands *commands)
{
    NV2AMetalProgramInput inputs[4];
    for (unsigned i = 0; i < 4; i++) {
        inputs[i] = input();
        for (unsigned k = 0; k < 4; k++) {
            inputs[i].attributes[3][k] = .1f * (i + k + 1);
            inputs[i].attributes[4][k] = .125f * (i + k + 1);
            inputs[i].attributes[7][k] = .15f * (i + k + 1);
            inputs[i].attributes[8][k] = .2f * (i + k + 1);
        }
    }
    unsigned vertices = 0;
    for (unsigned flags = 0; flags < 8; flags++) {
        for (unsigned material = 0; material < 81; material++) {
            NV2AMetalFixedUniforms u = uniforms();
            u.lighting = NO;
            u.common.specular_enable = flags & 1;
            u.separate_specular = !!(flags & 2);
            u.common.ignore_specular_alpha = !!(flags & 4);
            u.material_alpha = .9375f;
            u.emission_src = material % 3;
            u.ambient_src = material / 3 % 3;
            u.diffuse_src = material / 9 % 3;
            u.specular_src = material / 27;
            begin(commands);
            NV2AMetalFixedResult *result =
                encode(fixed, commands, &u, inputs, 4);
            finish(commands);
            const NV2AMetalProgramOutput *out = result.registers.contents;
            const NV2AMetalVertex *native = result.vertices.contents;
            for (unsigned i = 0; i < 4; i++) {
                assert(!out[i].fault);
                for (unsigned k = 0; k < 4; k++) {
                    float diffuse = inputs[i].attributes[3][k];
                    float specular = !(flags & 1) ? (k == 3) :
                                     k == 3 && (flags & 4) ?
                                                    1 :
                                                    inputs[i].attributes[4][k];
                    check_float(out[i].registers[3][k], diffuse);
                    check_float(out[i].registers[4][k], specular);
                    check_float(native[i].color[0][k], fminf(1, diffuse));
                    check_float(native[i].color[1][k], fminf(1, specular));
                    for (unsigned side = 0; side < 2; side++) {
                        float expected = k == 3;
                        if (out[i].registers[7 + side][k] != expected) {
                            fprintf(stderr,
                                    "Unlit back color flags=%u material=%u "
                                    "vertex=%u side=%u component=%u: got=%g "
                                    "expected=%g\n",
                                    flags, material, i, side, k,
                                    out[i].registers[7 + side][k], expected);
                            abort();
                        }
                        check_float(native[i].color[2 + side][k], expected);
                    }
                }
                vertices++;
            }
        }
    }
    assert(vertices == 2592);
    printf("Metal4 unlit back colors: %u flag/material/input vertices PASS\n",
           vertices);
}

static void back_no_light_hardware_controls(NV2AMetalVertexFixed *fixed,
                                            NV2AMetalCommands *commands)
{
    unsigned vertices = 0;
    for (unsigned flags = 0; flags < 8; flags++) {
        NV2AMetalFixedUniforms u = uniforms();
        u.lighting = u.two_side = YES;
        u.material_alpha = .15f;
        u.material_alpha_back = .75f;
        u.common.specular_enable = flags & 1;
        u.separate_specular = !!(flags & 2);
        u.common.ignore_specular_alpha = !!(flags & 4);
        NV2AMetalProgramInput inputs[4];
        for (unsigned i = 0; i < 4; i++) {
            inputs[i] = input();
            const float front[] = { 0, 0, 1, .33f };
            memcpy(inputs[i].attributes[4], front, sizeof(front));
            for (unsigned k = 0; k < 4; k++) {
                inputs[i].attributes[7][k] = .1f * (i + k + 1);
                inputs[i].attributes[8][k] = .2f * (i + k + 1);
            }
        }
        begin(commands);
        NV2AMetalFixedResult *result = encode(fixed, commands, &u, inputs, 4);
        finish(commands);
        const NV2AMetalProgramOutput *raw = result.registers.contents;
        const NV2AMetalVertex *native = result.vertices.contents;
        for (unsigned i = 0; i < 4; i++) {
            for (unsigned k = 0; k < 4; k++) {
                float diffuse = k == 3 ? .75f : 0;
                float specular = k == 3 ?
                                     (!(flags & 1) || (flags & 4) ? 1 : .33f) :
                                     (k == 2 && (flags & 1) && !(flags & 2));
                check_float(raw[i].registers[7][k], diffuse);
                check_float(raw[i].registers[8][k], specular);
                check_float(native[i].color[2][k], diffuse);
                check_float(native[i].color[3][k], specular);
            }
            vertices++;
        }
    }
    assert(vertices == 32);
    printf("Metal4 back no-light hardware controls: %u GPU vertices PASS\n",
           vertices);
}

static float material_value(unsigned source, float constant,
                            const NV2AMetalProgramInput *v, unsigned k)
{
    return source == 0 ? constant : v->attributes[source == 1 ? 3 : 4][k];
}

static void back_lighting_tests(NV2AMetalVertexFixed *fixed,
                                NV2AMetalCommands *commands)
{
    NV2AMetalProgramInput inputs[4];
    const float normals[] = { .5f, 1, -.5f, -1.5f };
    for (unsigned i = 0; i < 4; i++) {
        inputs[i] = input();
        inputs[i].attributes[0][0] = inputs[i].attributes[0][1] = 0;
        inputs[i].attributes[0][2] = inputs[i].attributes[0][3] = 1;
        inputs[i].attributes[2][2] = normals[i];
        for (unsigned k = 0; k < 4; k++) {
            inputs[i].attributes[3][k] = .1f * (i + k + 1);
            inputs[i].attributes[4][k] = .075f * (i + k + 1);
            inputs[i].attributes[7][k] = 7 + i + k;
            inputs[i].attributes[8][k] = -(float)(8 + i + k);
        }
    }
    unsigned vertices = 0;
    for (unsigned light = 0; light < 8; light++) {
        for (unsigned kind = NV2AMetalLightInfinite; kind <= NV2AMetalLightSpot;
             kind++) {
            for (unsigned material = 0; material < 81; material++) {
                unsigned flags = (material + light + kind) % 8;
                NV2AMetalFixedUniforms u = uniforms();
                u.lighting = u.two_side = YES;
                u.normalization = (material + light) % 2;
                u.common.specular_enable = flags & 1;
                u.separate_specular = !!(flags & 2);
                u.common.ignore_specular_alpha = !!(flags & 4);
                u.back_emission_src = material % 3;
                u.back_ambient_src = material / 3 % 3;
                u.back_diffuse_src = material / 9 % 3;
                u.back_specular_src = material / 27;
                u.material_alpha = .875f;
                u.material_alpha_back = .375f;
                u.specular_params[2] = 4;
                u.specular_params_back[2] = 2;
                u.light[light] = kind;
                u.light_direction[light][2] = -2;
                u.light_half_vector[light][2] = -.5f;
                u.ltc1[NV_IGRAPH_XF_LTC1_r0 + light][0] = 10;
                u.light_attenuation[light][0] = 2;
                u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_SPT + 2 * light][2] = -1;
                u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K + 2 * light][2] = 2;
                for (unsigned k = 0; k < 3; k++) {
                    u.ltctxa[NV_IGRAPH_XF_LTCTXA_FR_AMB][k] = .01f;
                    u.ltctxa[NV_IGRAPH_XF_LTCTXA_CM_COL][k] = .02f;
                    u.ltctxa[NV_IGRAPH_XF_LTCTXA_BR_AMB][k] = .03f * (k + 1);
                    u.ltctxa[NV_IGRAPH_XF_LTCTXA_BCM_COL][k] = .04f * (k + 1);
                    for (unsigned side = 0; side < 2; side++) {
                        u.ltctxb[6 * light + 3 * side][k] = .02f * (k + 1);
                        u.ltctxb[6 * light + 3 * side + 1][k] = .1f * (k + 1);
                        u.ltctxb[6 * light + 3 * side + 2][k] = .05f * (k + 1);
                    }
                }
                begin(commands);
                NV2AMetalFixedResult *result =
                    encode(fixed, commands, &u, inputs, 4);
                finish(commands);
                const NV2AMetalProgramOutput *raw = result.registers.contents;
                const NV2AMetalVertex *native = result.vertices.contents;
                for (unsigned i = 0; i < 4; i++) {
                    assert(!raw[i].fault);
                    float normal =
                        u.normalization ? copysignf(1, normals[i]) : normals[i];
                    float attenuation = kind == NV2AMetalLightInfinite ? 1 :
                                        kind == NV2AMetalLightLocal    ? .5f :
                                                                         .25f;
                    for (unsigned side = 0; side < 2; side++) {
                        float ndotl = fmaxf(0, side ? normal : -normal);
                        float power =
                            ndotl * (kind == NV2AMetalLightInfinite ? .5f : 1) /
                            (side ? 2 : 4);
                        for (unsigned k = 0; k < 4; k++) {
                            float diffuse, specular;
                            if (k == 3) {
                                diffuse =
                                    side ? material_value(u.back_diffuse_src,
                                                          u.material_alpha_back,
                                                          &inputs[i], k) :
                                           u.material_alpha;
                                specular = !(flags & 1) || (flags & 4) ?
                                               1 :
                                               inputs[i].attributes[4][k];
                            } else {
                                float ambient = side ? .03f * (k + 1) : .01f;
                                float emission = side ? .04f * (k + 1) : .02f;
                                diffuse =
                                    material_value(side ? u.back_ambient_src :
                                                          0,
                                                   ambient, &inputs[i], k) *
                                        emission +
                                    material_value(side ? u.back_emission_src :
                                                          0,
                                                   ambient, &inputs[i], k) +
                                    .02f * (k + 1) * attenuation +
                                    material_value(side ? u.back_diffuse_src :
                                                          0,
                                                   1, &inputs[i], k) *
                                        .1f * (k + 1) * attenuation * ndotl;
                                specular = material_value(
                                               side ? u.back_specular_src : 0,
                                               1, &inputs[i], k) *
                                           .05f * (k + 1) * attenuation * power;
                                if (!(flags & 1)) {
                                    specular = 0;
                                } else if (!(flags & 2)) {
                                    diffuse += specular;
                                    specular = inputs[i].attributes[4][k];
                                }
                            }
                            check_float(raw[i].registers[side ? 7 : 3][k],
                                        diffuse);
                            check_float(raw[i].registers[side ? 8 : 4][k],
                                        specular);
                            check_float(native[i].color[2 * side][k],
                                        fminf(1, fmaxf(0, diffuse)));
                            check_float(native[i].color[2 * side + 1][k],
                                        fminf(1, fmaxf(0, specular)));
                        }
                    }
                    vertices++;
                }
            }
        }
    }
    assert(vertices == 7776);
    printf("Metal4 front/back lighting: %u material/light/flag vertices PASS\n",
           vertices);
}

#include "test-metal-fixed-offset.h"
#include "test-metal-specialized-fixed.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalVertexFixed *fixed =
            [[NV2AMetalVertexFixed alloc] initWithDevice:commands.device
                                                   error:&error];
        require(fixed != nil, error);
        sf_cold_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--cold-fixed"))
            return 0;
        specialized_fixed_tests(commands);
        if (argc == 2 && !strcmp(argv[1],"--specialized-fixed")) return 0;
        assert(argc == 1);
        unlit_back_color_tests(fixed, commands);
        back_lighting_tests(fixed, commands);
        back_no_light_hardware_controls(fixed, commands);
        texgen_mixed_tests(fixed, commands);
        texgen_view_tests(fixed, commands);
        specular_tests(fixed, commands);
        specular_hardware_samples(fixed, commands);
        NV2AMetalFixedUniforms u = uniforms();
        NV2AMetalProgramInput v = input();
        const float position[] = { 1.19f, 2.26f, 8, 2 };
        memcpy(v.attributes[0], position, sizeof(position));
        u.common.constants[NV_IGRAPH_XF_XFCTX_VPOFF][0] = .25f;
        u.common.constants[NV_IGRAPH_XF_XFCTX_VPOFF][1] = -.5f;
        NV2AMetalFixedResult *result = run(fixed, commands, &u, &v);
        const float screen[] = { .8125f, .625f, 4, 2 },
                    clip[] = { -1.1875f, 1.375f, .5f, 2 };
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(result)->registers[0][k], position[k]);
            check_float(processed(result)->screen[k], screen[k]);
            check_float(processed(result)->clip[k], clip[k]);
        }
        unsigned colorAttributes[] = { 3, 4, 7, 8 };
        for (unsigned c = 0; c < 4; c++) {
            for (unsigned k = 0; k < 4; k++) {
                check_float(processed(result)->color[c][k],
                            c < 2  ? v.attributes[colorAttributes[c]][k] :
                            k == 3 ? 1 :
                                     0);
            }
        }
        for (unsigned t = 0; t < 4; t++) {
            for (unsigned k = 0; k < 4; k++) {
                check_float(processed(result)->texcoord[t][k],
                            v.attributes[9 + t][k]);
            }
        }
        check_float(processed(result)->point_size, 6);
        check_float(processed(result)->fog, 1);

        /* Matrix direction is fixed by a nonsymmetric matrix. With skinning
         * disabled, the composite transform must not apply modelview twice. */
        u = uniforms();
        v = input();
        v.attributes[0][2] = 3;
        const float columns[][4] = {
            { 1, 2, 3, 4 }, { 5, 6, 7, 8 }, { 9, 10, 11, 12 }, { 0, 0, 0, 2 }
        };
        memcpy(u.common.constants[NV_IGRAPH_XF_XFCTX_CMAT0], columns,
               sizeof(columns));
        matrix(&u, NV_IGRAPH_XF_XFCTX_MMAT0, 9);
        for (unsigned t = 0; t < 4; t++) {
            memcpy(v.attributes[9 + t], v.attributes[0], 4 * sizeof(float));
            memcpy(u.common.constants[NV_IGRAPH_XF_XFCTX_T0MAT + 8 * t],
                   columns, sizeof(columns));
            u.texture_matrix_enable[t] = YES;
        }
        result = run(fixed, commands, &u, &v);
        const float multiplied[] = { 18, 46, 74, 2 };
        for (unsigned k = 0; k < 4; k++) {
            check_float(raw(result)->registers[0][k], multiplied[k]);
            for (unsigned t = 0; t < 4; t++) {
                check_float(raw(result)->registers[9 + t][k], multiplied[k]);
            }
        }

        /* Seven skinning modes distinguish supplied weights from a generated
         * final unity weight. Normals use the separate inverse matrices. */
        u = uniforms();
        v = input();
        v.attributes[0][2] = 3;
        v.attributes[2][2] = 2;
        const float weights[] = { .1f, .2f, .3f, .9f };
        memcpy(v.attributes[1], weights, sizeof(weights));
        for (unsigned i = 0; i < 4; i++) {
            matrix(&u, NV_IGRAPH_XF_XFCTX_MMAT0 + 8 * i, i + 1);
            matrix(&u, NV_IGRAPH_XF_XFCTX_IMMAT0 + 8 * i, i + 2);
        }
        u.texgen[0][2] = NV2AMetalTexgenNormal;
        for (unsigned k = 0; k < 4; k++) {
            u.texgen[1][k] = NV2AMetalTexgenEyeLinear;
        }
        const float positionScale[] = { 1, 1.9f, .5f, 2.6f, 1.4f, 3, 5 };
        const float normalScale[] = { 2, 2.9f, .8f, 3.6f, 2, 4, 6.5f };
        const float wScale[] = { 1, 1, .3f, 1, .6f, 1, 1.5f };
        for (unsigned mode = 0; mode < 7; mode++) {
            for (unsigned normalized = 0; normalized < 2; normalized++) {
                u.skinning = mode;
                u.normalization = normalized;
                result = run(fixed, commands, &u, &v);
                for (unsigned k = 0; k < 3; k++) {
                    check_float(raw(result)->registers[0][k],
                                v.attributes[0][k] * positionScale[mode]);
                    check_float(raw(result)->registers[10][k],
                                v.attributes[0][k] * positionScale[mode]);
                }
                check_float(raw(result)->registers[0][3], wScale[mode]);
                check_float(raw(result)->registers[10][3], wScale[mode]);
                check_float(raw(result)->registers[9][2],
                            normalized ? 1 : 2 * normalScale[mode]);
            }
        }
        u.skinning = NV2AMetalSkinningTwoWeights;
        u.normalization = NO;
        v.attributes[1][0] = .3f;
        v.attributes[1][1] = .8f;
        result = run(fixed, commands, &u, &v);
        check_float(raw(result)->registers[0][0], 1.6f);

        /* Eye/object planes cover every stage and channel. */
        u = uniforms();
        v = input();
        matrix(&u, NV_IGRAPH_XF_XFCTX_MMAT0, 1);
        u.common.constants[NV_IGRAPH_XF_XFCTX_MMAT0][0] = 2;
        u.common.constants[NV_IGRAPH_XF_XFCTX_MMAT0 + 1][1] = 3;
        u.common.constants[NV_IGRAPH_XF_XFCTX_MMAT0 + 2][2] = 4;
        for (unsigned mode = NV2AMetalTexgenEyeLinear;
             mode <= NV2AMetalTexgenObjectLinear; mode++) {
            for (unsigned t = 0; t < 4; t++) {
                for (unsigned k = 0; k < 4; k++) {
                    u.texgen[t][k] = mode;
                    for (unsigned p = 0; p < 4; p++) {
                        u.common.constants[NV_IGRAPH_XF_XFCTX_TG0MAT + 8 * t +
                                           k][p] = (p + 1) * (t + 1) * (k + 1);
                    }
                }
            }
            result = run(fixed, commands, &u, &v);
            for (unsigned t = 0; t < 4; t++) {
                for (unsigned k = 0; k < 4; k++) {
                    check_float(raw(result)->registers[9 + t][k],
                                (mode == NV2AMetalTexgenEyeLinear ? 42 : 15) *
                                    (t + 1) * (k + 1));
                }
            }
        }
        u = uniforms();
        v = input();
        for (unsigned mode = NV2AMetalTexgenSphere;
             mode <= NV2AMetalTexgenReflection; mode++) {
            for (unsigned t = 0; t < 4; t++) {
                for (unsigned k = 0; k < 4; k++) {
                    u.texgen[t][k] =
                        k < (mode == NV2AMetalTexgenSphere ? 2 : 3) ?
                            mode :
                            NV2AMetalTexgenDisabled;
                }
            }
            result = run(fixed, commands, &u, &v);
            const float sphere[] = { .5f + 1.0f / (2 * sqrtf(6)),
                                     .5f + 1.0f / sqrtf(6) };
            const float reflected[] = { 1.0f / 3, 2.0f / 3, -2.0f / 3 };
            const float normal[] = { 0, 0, 1 };
            for (unsigned t = 0; t < 4; t++) {
                for (unsigned k = 0; k < 4; k++) {
                    float expected = v.attributes[9 + t][k];
                    if (mode == NV2AMetalTexgenSphere && k < 2) {
                        expected = sphere[k];
                    } else if (mode == NV2AMetalTexgenNormal && k < 3) {
                        expected = normal[k];
                    } else if (mode == NV2AMetalTexgenReflection && k < 3) {
                        expected = reflected[k];
                    }
                    check_float(raw(result)->registers[9 + t][k], expected);
                }
            }
        }

        /* All fog generators use transformed position before the composite
         * stage. Linear parameters here leave the signed distance unchanged. */
        u = uniforms();
        v = input();
        u.common.fog_enable = YES;
        u.common.fog[0] = u.common.fog[1] = 1;
        v.attributes[4][3] = 2;
        v.attributes[5][0] = -2;
        const float fogPlane[] = { .5f, -1, 2, -4 };
        memcpy(u.common.constants[NV_IGRAPH_XF_XFCTX_FOG], fogPlane,
               sizeof(fogPlane));
        const float fogDistance[] = { 1, 3, -1.5f, 1.5f, -2 };
        for (unsigned mode = 0; mode < 5; mode++) {
            u.foggen = mode;
            result = run(fixed, commands, &u, &v);
            check_float(raw(result)->registers[5][0], fogDistance[mode]);
            check_float(processed(result)->fog, fogDistance[mode]);
        }

        /* Point attenuation includes homogeneous W in the eye distance. */
        u = uniforms();
        v = input();
        u.point_params_enable = YES;
        u.point_params[2] = 1;
        u.point_params[3] = 10;
        u.point_params[7] = 2;
        result = run(fixed, commands, &u, &v);
        check_float(processed(result)->point_size, 2 * (10 / sqrtf(10) + 2));
        u.point_params[0] = 1;
        u.point_params[2] = 0;
        u.point_params[6] = -10;
        result = run(fixed, commands, &u, &v);
        check_float(processed(result)->point_size, 4);
        u.point_params[6] = 100;
        result = run(fixed, commands, &u, &v);
        check_float(processed(result)->point_size, 24);
        u.point_params[3] = 100;
        u.point_params[7] = 70;
        result = run(fixed, commands, &u, &v);
        check_float(processed(result)->point_size, 127.75f);
        u.point_params_enable = NO;
        u.common.point_size = .5f;
        result = run(fixed, commands, &u, &v);
        check_float(processed(result)->point_size, 2);

        /* Material sources are independent. Test all 3^4 choices against fixed
         * colors, with light 7 to cover the last context/array offsets. */
        u = uniforms();
        v = input();
        u.lighting = YES;
        u.specular_power = 2;
        u.specular_params[2] = 2;
        const float diffuse[] = { .2f, .4f, .6f, .8f },
                    specular[] = { .3f, .5f, .7f, .9f };
        memcpy(v.attributes[3], diffuse, sizeof(diffuse));
        memcpy(v.attributes[4], specular, sizeof(specular));
        const float ambient[] = { .1f, .2f, .3f },
                    emission[] = { .5f, .25f, .1f };
        memcpy(u.ltctxa[NV_IGRAPH_XF_LTCTXA_FR_AMB], ambient, sizeof(ambient));
        memcpy(u.ltctxa[NV_IGRAPH_XF_LTCTXA_CM_COL], emission,
               sizeof(emission));
        u.material_alpha = .6f;
        u.light[7] = NV2AMetalLightInfinite;
        u.light_direction[7][2] = 2;
        u.light_half_vector[7][2] = .5f;
        const float la[] = { .01f, .02f, .03f }, ld[] = { .1f, .2f, .3f },
                    ls[] = { .4f, .2f, .1f };
        memcpy(u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_AMB + 6 * 7], la, sizeof(la));
        memcpy(u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF + 6 * 7], ld, sizeof(ld));
        memcpy(u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * 7], ls, sizeof(ls));
        NSMutableArray<NV2AMetalFixedResult *> *materials =
            [NSMutableArray array];
        begin(commands);
        for (unsigned em = 0; em < 3; em++) {
            for (unsigned am = 0; am < 3; am++) {
                for (unsigned di = 0; di < 3; di++) {
                    for (unsigned sp = 0; sp < 3; sp++) {
                        u.emission_src = em;
                        u.ambient_src = am;
                        u.diffuse_src = di;
                        u.specular_src = sp;
                        [materials
                            addObject:encode(fixed, commands, &u, &v, 1)];
                    }
                }
            }
        }
        finish(commands);
        unsigned materialIndex = 0;
        const float *base[] = { ambient, diffuse, specular };
        const float unity[] = { 1, 1, 1 };
        const float *factor[] = { unity, diffuse, specular };
        const float alpha[] = { .6f, .8f, .9f };
        for (unsigned em = 0; em < 3; em++) {
            for (unsigned am = 0; am < 3; am++) {
                for (unsigned di = 0; di < 3; di++) {
                    for (unsigned sp = 0; sp < 3; sp++) {
                        const NV2AMetalProgramOutput *r =
                            raw(materials[materialIndex++]);
                        for (unsigned k = 0; k < 3; k++) {
                            check_float(r->registers[3][k],
                                        base[am][k] * emission[k] +
                                            base[em][k] + la[k] +
                                            factor[di][k] * ld[k]);
                            check_float(r->registers[4][k],
                                        factor[sp][k] * ls[k] * .25f);
                            check_float(r->registers[7][k], v.attributes[7][k]);
                        }
                        check_float(r->registers[3][3], alpha[di]);
                        check_float(r->registers[4][3], specular[3]);
                    }
                }
            }
        }

        /* Range is inclusive in the GL reference. Local attenuation is 1/7
         * at distance 2. Spot cases distinguish full/partial/zero intensity. */
        u = uniforms();
        v = input();
        memset(v.attributes[0], 0, 3 * sizeof(float));
        u.lighting = YES;
        u.specular_power = 2;
        u.light[0] = NV2AMetalLightLocal;
        u.light_position[0][2] = 2;
        u.ltc1[NV_IGRAPH_XF_LTC1_r0][0] = 2;
        for (unsigned k = 0; k < 3; k++) {
            u.light_attenuation[0][k] = 1;
            u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF][k] = .7f;
            u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC][k] = .35f;
        }
        result = run(fixed, commands, &u, &v);
        for (unsigned k = 0; k < 3; k++) {
            check_float(raw(result)->registers[3][k], .1f);
            check_float(raw(result)->registers[4][k], .05f);
        }
        u.ltc1[NV_IGRAPH_XF_LTC1_r0][0] = 1.999f;
        result = run(fixed, commands, &u, &v);
        check_float(raw(result)->registers[3][0], 0);
        u.ltc1[NV_IGRAPH_XF_LTC1_r0][0] = 2;
        u.light[0] = NV2AMetalLightSpot;
        u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_K][2] = 1;
        const float spots[][4] = { { 0, 0, 2, 0 },
                                   { sqrtf(1.75f), 0, 1.5f, -1 },
                                   { 2, 0, 0, -1 } };
        const float spotFactor[] = { 1, .5f, 0 };
        for (unsigned s = 0; s < 3; s++) {
            memcpy(u.ltctxa[NV_IGRAPH_XF_LTCTXA_L0_SPT], spots[s],
                   sizeof(spots[s]));
            result = run(fixed, commands, &u, &v);
            check_float(raw(result)->registers[3][0], .1f * spotFactor[s]);
            check_float(raw(result)->registers[4][0], .05f * spotFactor[s]);
        }
        u.light[0] = NV2AMetalLightInfinite;
        u.light_direction[0][2] = 1;
        u.light_half_vector[0][2] = .5f;
        u.local_eye = YES;
        u.common.constants[NV_IGRAPH_XF_XFCTX_EYEP][0] = 2;
        u.common.constants[NV_IGRAPH_XF_XFCTX_EYEP][3] = 1;
        result = run(fixed, commands, &u, &v);
        check_float(raw(result)->registers[4][0], .35f / sqrtf(2));
        u.separate_specular = NO;
        result = run(fixed, commands, &u, &v);
        check_float(raw(result)->registers[3][0], .7f + .35f / sqrtf(2));
        check_float(raw(result)->registers[4][0], v.attributes[4][0]);
        check_float(raw(result)->registers[7][0],
                    v.attributes[7][0] + v.attributes[8][0]);
        u.common.specular_enable = NO;
        result = run(fixed, commands, &u, &v);
        check_float(raw(result)->registers[4][0], 0);
        check_float(raw(result)->registers[4][3], 1);

        /* Sum all eight lights, then suppress specular when N dot L is zero. */
        u = uniforms();
        v = input();
        u.lighting = YES;
        u.specular_power = 1;
        for (unsigned i = 0; i < 8; i++) {
            u.light[i] = NV2AMetalLightInfinite;
            u.light_direction[i][2] = u.light_half_vector[i][2] = 1;
            for (unsigned k = 0; k < 3; k++) {
                u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_AMB + 6 * i][k] = .01f;
                u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_DIF + 6 * i][k] = .02f;
                u.ltctxb[NV_IGRAPH_XF_LTCTXB_L0_SPC + 6 * i][k] = .03f;
            }
        }
        result = run(fixed, commands, &u, &v);
        check_float(raw(result)->registers[3][0], .24f);
        check_float(raw(result)->registers[4][0], .24f);
        v.attributes[2][2] = -1;
        result = run(fixed, commands, &u, &v);
        check_float(raw(result)->registers[3][0], .08f);
        check_float(raw(result)->registers[4][0], 0);

        spotlight_tests(fixed, commands);

        /* Native geometry consumes fixed-function output without CPU readback.
         */
        u = uniforms();
        v = input();
        NV2AMetalProgramInput triangle[] = { v, v, v };
        triangle[1].attributes[0][0] += 2;
        triangle[2].attributes[0][1] += 1;
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        require(geometry != nil, error);
        begin(commands);
        NV2AMetalFixedResult *vertices =
            encode(fixed, commands, &u, triangle, 3);
        NV2AMetalGeometryResult *expanded =
            [geometry encodeVertices:vertices.vertices
                               count:3
                           primitive:NV2AMetalPrimitiveTriangles
                             polygon:NV2AMetalPolygonFill
                              smooth:YES
                      firstProvoking:NO
                        zPerspective:NO
                            commands:commands
                               error:&error];
        require(expanded != nil, error);
        finish(commands);
        assert(expanded.vertexCount == 3);
        check_float(((NV2AMetalVertex *)expanded.vertices.contents)[0].slope,
                    0);

        /* Invalid state/length is rejected before encoding; empty draws
         * allocate no outputs. */
        id<MTLBuffer> one =
            [commands.device newBufferWithBytes:&v
                                         length:sizeof(v)
                                        options:MTLResourceStorageModeShared];
        begin(commands);
        assert(![fixed encodeAttributes:one
                                  count:2
                               uniforms:&u
                               commands:commands
                                  error:&error]);
        assert(error);
        u.texgen[0][3] = NV2AMetalTexgenSphere;
        error = nil;
        assert(![fixed encodeAttributes:one
                                  count:1
                               uniforms:&u
                               commands:commands
                                  error:&error]);
        assert(error);
        u.texgen[0][3] = 0;
        u.skinning = 7;
        error = nil;
        assert(![fixed encodeAttributes:one
                                  count:1
                               uniforms:&u
                               commands:commands
                                  error:&error]);
        assert(error);
        u.skinning = 0;
        u.light[7] = 4;
        error = nil;
        assert(![fixed encodeAttributes:one
                                  count:1
                               uniforms:&u
                               commands:commands
                                  error:&error]);
        assert(error);
        u.light[7] = 0;
        NV2AMetalFixedResult *empty = [fixed encodeAttributes:one
                                                        count:0
                                                     uniforms:&u
                                                     commands:commands
                                                        error:&error];
        assert(empty && empty.vertexCount == 0 && !empty.registers &&
               !empty.vertices);
        [commands cancel];
        fixed_input_offset_tests(fixed, commands);
        puts("Metal 4 fixed transform, skinning, texgen, fog, point size and "
             "lighting: PASS (offscreen)");
    }
    return 0;
}
