/*
 * Offscreen native Metal 4 register-combiner tests
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#import "hw/xbox/nv2a/pgraph/metal/pixel-combiner.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Case {
    NV2AMetalCombinerState state;
    NV2AMetalCombinerInput input;
    float color[4];
    unsigned register_mask;
    float registers[16][4];
} Case;

static Case cases[2048];
static unsigned case_count;

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Pixel combiner failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static void check_float(float actual, float expected, unsigned test,
                        unsigned reg, unsigned component)
{
    if (!isfinite(actual) ||
        fabsf(actual - expected) > 0.000006f * fmaxf(1, fabsf(expected))) {
        fprintf(
            stderr,
            "Combiner case %u register %u component %u: got %g expected %g\n",
            test, reg, component, actual, expected);
        abort();
    }
}

static unsigned inputs(unsigned a, unsigned b, unsigned c, unsigned d)
{
    return a << 24 | b << 16 | c << 8 | d;
}

static unsigned output(unsigned ab, unsigned cd, unsigned sum, unsigned flags)
{
    return cd | ab << 4 | sum << 8 | flags << 12;
}

static NV2AMetalCombinerState state(void)
{
    NV2AMetalCombinerState u = { 0 };
    u.shader_stage_program = PS_TEXTUREMODES_PASSTHRU;
    u.final_inputs[0] = PS_REGISTER_R0 | PS_INPUTMAPPING_SIGNED_IDENTITY;
    u.final_inputs[1] =
        (PS_REGISTER_R0 | PS_CHANNEL_ALPHA | PS_INPUTMAPPING_SIGNED_IDENTITY)
        << 8;
    return u;
}

static NV2AMetalCombinerInput input(void)
{
    NV2AMetalCombinerInput v = { 0 };
    for (unsigned k = 0; k < 4; k++) {
        v.diffuse[k] = .1f * (k + 1);
        v.specular[k] = .1f * (k + 2);
        v.fog[k] = .1f * (k + 3);
        for (unsigned t = 0; t < 4; t++) {
            v.textures[t][k] = .1f * (t + k + 4);
        }
    }
    return v;
}

static Case *add(NV2AMetalCombinerState u, NV2AMetalCombinerInput v, float r,
                 float g, float b, float a)
{
    assert(case_count < sizeof(cases) / sizeof(*cases));
    Case *c = &cases[case_count++];
    *c = (Case){ .state = u, .input = v, .color = { r, g, b, a } };
    return c;
}

static void expect_register(Case *c, unsigned reg, float r, float g, float b,
                            float a)
{
    c->register_mask |= 1u << reg;
    const float values[] = { r, g, b, a };
    memcpy(c->registers[reg], values, sizeof(values));
}

/* Integer outputs observed in the pinned Xbox CombinerOps/ShiftClamping
 * captures. These isolate output bias from product rounding. */
static void output_bias_cases(void)
{
    const struct {
        unsigned a, b, flags, negative;
        int expected;
    } hardware[] = {
        { 255, 0, PS_COMBINEROUTPUT_BIAS, 0, 127 },
        { 255, 0, PS_COMBINEROUTPUT_SHIFTLEFT_1_BIAS, 0, 254 },
        { 95, 95, PS_COMBINEROUTPUT_SHIFTLEFT_1_BIAS, 0, 124 },
        { 191, 191, PS_COMBINEROUTPUT_BIAS, 0, 254 },
        { 159, 159, PS_COMBINEROUTPUT_BIAS, 0, 190 },
        { 31, 191, PS_COMBINEROUTPUT_BIAS, 1, 32 },
    };
    for (unsigned i = 0; i < sizeof(hardware) / sizeof(*hardware); i++) {
        NV2AMetalCombinerState u = state();
        u.control = hardware[i].negative ? 2 : 1;
        for (unsigned k = 0; k < 4; k++) {
            u.constants[0][k] = hardware[i].a / 255.0f;
            u.constants[1][k] = hardware[i].b / 255.0f;
        }
        unsigned a = PS_REGISTER_C0 |
                     (hardware[i].negative ? PS_INPUTMAPPING_SIGNED_NEGATE :
                                             PS_INPUTMAPPING_UNSIGNED_IDENTITY);
        u.rgb_inputs[0] =
            inputs(a, PS_REGISTER_ONE,
                   hardware[i].negative ? 0 : PS_REGISTER_C1, PS_REGISTER_ONE);
        u.alpha_inputs[0] = u.rgb_inputs[0] | 0x10101010;
        u.rgb_outputs[0] = u.alpha_outputs[0] =
            output(0, 0, PS_REGISTER_R0, hardware[i].flags);
        if (hardware[i].negative) {
            u.rgb_inputs[1] =
                inputs(PS_REGISTER_C1, PS_REGISTER_ONE,
                       PS_REGISTER_R0 | PS_INPUTMAPPING_SIGNED_IDENTITY,
                       PS_REGISTER_ONE);
            u.alpha_inputs[1] = u.rgb_inputs[1] | 0x10101010;
            u.rgb_outputs[1] = u.alpha_outputs[1] =
                output(0, 0, PS_REGISTER_R0, 0);
        }
        float expected = hardware[i].expected / 255.0f;
        add(u, input(), expected, expected, expected, expected);
    }

    /* Boundary codes exercise all three destinations and RGB/alpha paths.
     * This extends the selected hardware cases; it is not a hardware sweep. */
    const unsigned codes[] = { 0, 1, 127, 128, 129, 254, 255 };
    for (unsigned shift = 0; shift < 2; shift++) {
        for (unsigned slot = 0; slot < 3; slot++) {
            for (unsigned i = 0; i < sizeof(codes) / sizeof(*codes); i++) {
                NV2AMetalCombinerState u = state();
                u.control = 1;
                for (unsigned k = 0; k < 4; k++) {
                    u.constants[0][k] = codes[i] / 255.0f;
                }
                u.rgb_inputs[0] =
                    slot == 1 ? inputs(0, 0, PS_REGISTER_C0, PS_REGISTER_ONE) :
                                inputs(PS_REGISTER_C0, PS_REGISTER_ONE, 0, 0);
                u.alpha_inputs[0] = u.rgb_inputs[0] | 0x10101010;
                unsigned flags = shift ? PS_COMBINEROUTPUT_SHIFTLEFT_1_BIAS :
                                         PS_COMBINEROUTPUT_BIAS;
                u.rgb_outputs[0] = u.alpha_outputs[0] =
                    output(slot == 0 ? PS_REGISTER_R0 : 0,
                           slot == 1 ? PS_REGISTER_R0 : 0,
                           slot == 2 ? PS_REGISTER_R0 : 0, flags);
                int result = ((int)codes[i] - 128) * (shift ? 2 : 1);
                if (result < -255)
                    result = -255;
                float expected = result / 255.0f;
                add(u, input(), expected, expected, expected, expected);
            }
        }
    }
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

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalPixelCombiner *combiner =
            [[NV2AMetalPixelCombiner alloc] initWithDevice:commands.device
                                                     error:&error];
        require(combiner != nil, error);
        NV2AMetalCombinerState u = state();
        NV2AMetalCombinerInput v = input();

        /* The final stage does not clamp its result to [0,1]. */
        u.final_inputs[0] = PS_REGISTER_V0 | PS_INPUTMAPPING_SIGNED_IDENTITY;
        u.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA |
                             PS_INPUTMAPPING_SIGNED_IDENTITY)
                            << 8;
        const float mappingInput[] = { -.5f, .25f, .75f, 1.5f };
        memcpy(v.diffuse, mappingInput, sizeof(mappingInput));
        add(u, v, -.5f, .25f, .75f, 1.5f);

        /* Fixed analytical truth table for all eight mappings. Test final
         * inputs and ordinary stages separately, including RGB/blue/alpha. */
        const float mapped[8][4] = {
            { 0, .25f, .75f, 1.5f },    { 1, .75f, .25f, 0 },
            { -1, -.5f, .5f, 2 },       { 1, .5f, -.5f, -2 },
            { -.5f, -.25f, .25f, 1 },   { .5f, .25f, -.25f, -1 },
            { -.5f, .25f, .75f, 1.5f }, { .5f, -.25f, -.75f, -1.5f }
        };
        for (unsigned m = 0; m < 8; m++) {
            for (unsigned channel = 0; channel < 2; channel++) {
                unsigned word = PS_REGISTER_V0 | m << 5 | channel << 4;
                u = state();
                u.final_inputs[0] = word;
                u.final_inputs[1] = word << 8;
                float r = mapped[m][channel ? 3 : 0];
                float g = mapped[m][channel ? 3 : 1];
                float b = mapped[m][channel ? 3 : 2];
                float a = mapped[m][channel ? 3 : 2];
                add(u, v, r, g, b, a);
                u = state();
                u.control = 1;
                u.rgb_inputs[0] = u.alpha_inputs[0] =
                    inputs(word, PS_REGISTER_ONE, 0, 0);
                u.rgb_outputs[0] = u.alpha_outputs[0] =
                    output(PS_REGISTER_R0, 0, 0, 0);
                r = fmaxf(-1, fminf(1, r));
                g = fmaxf(-1, fminf(1, g));
                b = fmaxf(-1, fminf(1, b));
                a = fmaxf(-1, fminf(1, a));
                add(u, v, r, g, b, a);
            }
        }

        /* Read every source register with distinct values and both channels.
         * R0 starts with T0 alpha; R1 starts zero; SUM has zero alpha. */
        const unsigned registers[] = { 0, 1,  2,  3,  4,  5, 8,
                                       9, 10, 11, 12, 13, 14 };
        for (unsigned regIndex = 0;
             regIndex < sizeof(registers) / sizeof(*registers); regIndex++) {
            for (unsigned channel = 0; channel < 2; channel++) {
                unsigned reg = registers[regIndex];
                u = state();
                v = input();
                const float c0[] = { .11f, .12f, .13f, .14f };
                const float c1[] = { .21f, .22f, .23f, .24f };
                memcpy(u.constants[0], c0, sizeof(c0));
                memcpy(u.constants[1], c1, sizeof(c1));
                const float zero[] = { 0, 0, 0, 0 };
                const float initialR0[] = { 0, 0, 0, .7f };
                const float sum[] = { .2f, .3f, .4f, 0 };
                const float *source = reg == 1 ? c0 :
                                      reg == 2 ? c1 :
                                      reg == 3 ? v.fog :
                                      reg == 4 ? v.diffuse :
                                      reg == 5 ? v.specular :
                                      reg >= 8 && reg <= 11 ?
                                                 v.textures[reg - 8] :
                                      reg == 12 ? initialR0 :
                                      reg == 14 ? sum :
                                                  zero;
                unsigned word =
                    reg | PS_INPUTMAPPING_SIGNED_IDENTITY | channel << 4;
                u.control = 1;
                u.rgb_inputs[0] = u.alpha_inputs[0] =
                    inputs(word, PS_REGISTER_ONE, 0, 0);
                u.rgb_outputs[0] = u.alpha_outputs[0] =
                    output(PS_REGISTER_R1, 0, 0, 0);
                u.final_inputs[0] =
                    PS_REGISTER_R1 | PS_INPUTMAPPING_SIGNED_IDENTITY;
                u.final_inputs[1] = (PS_REGISTER_R1 | PS_CHANNEL_ALPHA |
                                     PS_INPUTMAPPING_SIGNED_IDENTITY)
                                    << 8;
                add(u, v, source[channel ? 3 : 0], source[channel ? 3 : 1],
                    source[channel ? 3 : 2], source[channel ? 3 : 2]);
            }
        }

        output_bias_cases();

        /* Six output mappings applied independently to AB, CD and raw AB+CD.
         * The sum must not add already mapped/clamped AB/CD values. */
        const unsigned outputModes[] = { 0, 8, 16, 24, 32, 48 };
        const float ab[6][3] = {
            { -.8f, .3f, .6f }, { -1, -.2019607843f, .0980392157f },
            { -1, .6f, 1 },     { -1, -.4039215686f, .1960784314f },
            { -1, 1, 1 },       { -.4f, .15f, .3f }
        };
        const float cd[6][3] = {
            { -.7f, .4f, .2f }, { -1, -.1019607843f, -.3019607843f },
            { -1, .8f, .4f },   { -1, -.2039215686f, -.6039215686f },
            { -1, 1, .8f },     { -.35f, .2f, .1f }
        };
        const float sums[6][3] = {
            { -1, .7f, .8f }, { -1, .1980392157f, .2980392157f },
            { -1, 1, 1 },     { -1, .3960784314f, .5960784314f },
            { -1, 1, 1 },     { -.75f, .35f, .4f }
        };
        const float alphaAB[] = { .3f, -.2019607843f, .6f, -.4039215686f,
                                  1,   .15f };
        const float alphaCD[] = { .2f,           -.3019607843f, .4f,
                                  -.6039215686f, .8f,           .1f };
        const float alphaSum[] = {
            .5f, -.0019607843f, 1, -.0039215686f, 1, .25f
        };
        for (unsigned m = 0; m < 6; m++) {
            u = state();
            v = input();
            const float a[] = { -.8f, .3f, .6f, .3f };
            const float c[] = { -.7f, .4f, .2f, .2f };
            memcpy(v.diffuse, a, sizeof(a));
            memcpy(v.specular, c, sizeof(c));
            u.control = 1;
            u.rgb_inputs[0] =
                inputs(PS_REGISTER_V0 | PS_INPUTMAPPING_SIGNED_IDENTITY,
                       PS_REGISTER_ONE,
                       PS_REGISTER_V1 | PS_INPUTMAPPING_SIGNED_IDENTITY,
                       PS_REGISTER_ONE);
            u.alpha_inputs[0] = u.rgb_inputs[0] | 0x10001000;
            u.rgb_outputs[0] = u.alpha_outputs[0] = output(
                PS_REGISTER_R0, PS_REGISTER_R1, PS_REGISTER_T0, outputModes[m]);
            Case *cse = add(u, v, ab[m][0], ab[m][1], ab[m][2], alphaAB[m]);
            expect_register(cse, PS_REGISTER_R0, ab[m][0], ab[m][1], ab[m][2],
                            alphaAB[m]);
            expect_register(cse, PS_REGISTER_R1, cd[m][0], cd[m][1], cd[m][2],
                            alphaCD[m]);
            expect_register(cse, PS_REGISTER_T0, sums[m][0], sums[m][1],
                            sums[m][2], alphaSum[m]);
        }

        /* Multiply/dot products in RGB; alpha dot flags still multiply scalars.
         */
        for (unsigned flags = 0; flags < 4; flags++) {
            u = state();
            v = input();
            const float a[] = { .2f, .3f, .4f, .5f },
                        b[] = { .5f, .6f, .7f, .6f };
            const float c[] = { .3f, .2f, .1f, .2f },
                        d[] = { .7f, .4f, .2f, .5f };
            memcpy(v.diffuse, a, sizeof(a));
            memcpy(v.specular, b, sizeof(b));
            memcpy(v.textures[0], c, sizeof(c));
            memcpy(v.textures[1], d, sizeof(d));
            u.control = 1;
            u.rgb_inputs[0] = inputs(PS_REGISTER_V0, PS_REGISTER_V1,
                                     PS_REGISTER_T0, PS_REGISTER_T1);
            u.alpha_inputs[0] = u.rgb_inputs[0] | 0x10101010;
            u.rgb_outputs[0] = u.alpha_outputs[0] =
                output(PS_REGISTER_R0, PS_REGISTER_R1, PS_REGISTER_T2, flags);
            const float abProduct[] = { .1f, .18f, .28f },
                        cdProduct[] = { .21f, .08f, .02f };
            float rgb[3], rgbCD[3], rgbSum[3];
            for (unsigned k = 0; k < 3; k++) {
                rgb[k] = flags & 2 ? .56f : abProduct[k];
                rgbCD[k] = flags & 1 ? .31f : cdProduct[k];
                rgbSum[k] = rgb[k] + rgbCD[k];
            }
            Case *cse = add(u, v, rgb[0], rgb[1], rgb[2], .3f);
            expect_register(cse, PS_REGISTER_R1, rgbCD[0], rgbCD[1], rgbCD[2],
                            .1f);
            expect_register(cse, PS_REGISTER_T2, rgbSum[0], rgbSum[1],
                            rgbSum[2], .4f);
        }

        /* All 256 R0 alpha values for LSB/MSB mux, including simultaneous
         * alpha writes to R0. RGB and alpha must both read the OLD alpha. */
        for (unsigned msb = 0; msb < 2; msb++) {
            for (unsigned alpha = 0; alpha < 256; alpha++) {
                u = state();
                v = input();
                for (unsigned k = 0; k < 3; k++) {
                    v.diffuse[k] = .2f;
                    v.specular[k] = .8f;
                }
                v.diffuse[3] = .25f;
                v.specular[3] = .75f;
                v.textures[0][3] = alpha / 255.0f;
                u.control = 1 | (msb ? PS_COMBINERCOUNT_MUX_MSB << 8 : 0);
                u.rgb_inputs[0] = inputs(PS_REGISTER_V0, PS_REGISTER_ONE,
                                         PS_REGISTER_V1, PS_REGISTER_ONE);
                u.alpha_inputs[0] = u.rgb_inputs[0] | 0x10001000;
                u.rgb_outputs[0] =
                    output(0, 0, PS_REGISTER_R1, PS_COMBINEROUTPUT_AB_CD_MUX);
                u.alpha_outputs[0] =
                    output(0, 0, PS_REGISTER_R0, PS_COMBINEROUTPUT_AB_CD_MUX);
                u.final_inputs[0] = PS_REGISTER_R1;
                BOOL chooseCD = msb ? alpha >= 128 : alpha & 1;
                add(u, v, chooseCD ? .8f : .2f, chooseCD ? .8f : .2f,
                    chooseCD ? .8f : .2f, chooseCD ? .75f : .25f);
            }
        }

        /* Destination collisions: AB, then CD, then SUM; blue-to-alpha is
         * applied before the alpha pipeline writes its destinations. */
        for (unsigned blue = 0; blue < 4; blue++) {
            for (unsigned alphaWrites = 0; alphaWrites < 2; alphaWrites++) {
                u = state();
                v = input();
                u.control = 1;
                u.rgb_inputs[0] = inputs(PS_REGISTER_V0, PS_REGISTER_ONE,
                                         PS_REGISTER_V1, PS_REGISTER_ONE);
                u.rgb_outputs[0] = output(
                    PS_REGISTER_R0, PS_REGISTER_R0, PS_REGISTER_R0,
                    (blue & 1 ? PS_COMBINEROUTPUT_AB_BLUE_TO_ALPHA : 0) |
                        (blue & 2 ? PS_COMBINEROUTPUT_CD_BLUE_TO_ALPHA : 0));
                float a = blue & 2 ? .4f : blue & 1 ? .3f : .7f;
                if (alphaWrites) {
                    u.alpha_inputs[0] =
                        inputs(PS_REGISTER_ONE_HALF, PS_REGISTER_ONE, 0, 0);
                    u.alpha_outputs[0] = output(PS_REGISTER_R0, 0, 0, 0);
                    a = .5f;
                }
                add(u, v, .3f, .5f, .7f, a);
            }
        }
        u = state();
        v = input();
        u.control = 1;
        u.rgb_inputs[0] = inputs(PS_REGISTER_ZERO, 0, 0, 0);
        u.rgb_outputs[0] =
            output(PS_REGISTER_V0, 0, 0, PS_COMBINEROUTPUT_AB_BLUE_TO_ALPHA);
        u.alpha_inputs[0] = inputs(PS_REGISTER_V0, PS_REGISTER_ONE, 0, 0);
        u.alpha_outputs[0] = output(PS_REGISTER_R0, 0, 0, 0);
        add(u, v, 0, 0, 0, .3f); /* Original V0.b, despite RGB write to V0. */

        /* Every writable destination, including the reference's local FOG. */
        const unsigned destinations[] = { 3, 4, 5, 8, 9, 10, 11, 12, 13 };
        for (unsigned i = 0; i < sizeof(destinations) / sizeof(*destinations);
             i++) {
            unsigned reg = destinations[i];
            u = state();
            v = input();
            u.control = 1;
            u.rgb_inputs[0] = u.alpha_inputs[0] =
                inputs(PS_REGISTER_ONE_HALF, PS_REGISTER_ONE, 0, 0);
            u.rgb_outputs[0] = u.alpha_outputs[0] = output(reg, 0, 0, 0);
            u.final_inputs[0] = reg;
            u.final_inputs[1] = (reg | PS_CHANNEL_ALPHA) << 8;
            Case *cse = add(u, v, .5f, .5f, .5f, .5f);
            expect_register(cse, reg, .5f, .5f, .5f, .5f);
        }

        /* SAME/UNIQUE constants are independent for C0 and C1. Stage7 differs
         * from stage0, while final constants always use indices16 and17. */
        for (unsigned unique = 0; unique < 4; unique++) {
            u = state();
            v = input();
            u.control = 8 | ((unique & 1 ? PS_COMBINERCOUNT_UNIQUE_C0 : 0) |
                             (unique & 2 ? PS_COMBINERCOUNT_UNIQUE_C1 : 0))
                                << 8;
            for (unsigned stage = 0; stage < 9; stage++) {
                for (unsigned k = 0; k < 4; k++) {
                    u.constants[2 * stage][k] = .01f * (stage + 1);
                    u.constants[2 * stage + 1][k] = .02f * (stage + 1);
                }
                if (stage < 8) {
                    u.rgb_inputs[stage] = u.alpha_inputs[stage] =
                        inputs(PS_REGISTER_C0, PS_REGISTER_ONE, PS_REGISTER_C1,
                               PS_REGISTER_ONE);
                    u.rgb_outputs[stage] = u.alpha_outputs[stage] =
                        output(PS_REGISTER_R0, PS_REGISTER_R1, 0, 0);
                }
            }
            u.final_inputs[0] = inputs(0, 0, PS_REGISTER_R1, PS_REGISTER_R0);
            float expected =
                (unique & 1 ? .08f : .01f) + (unique & 2 ? .16f : .02f);
            add(u, v, expected, expected, expected, unique & 1 ? .08f : .01f);
            u.final_inputs[0] = inputs(0, 0, PS_REGISTER_C1, PS_REGISTER_C0);
            u.final_inputs[1] = (PS_REGISTER_C1 | PS_CHANNEL_ALPHA) << 8;
            add(u, v, .27f, .27f, .27f, .18f);
        }

        /* Eight successive read/modify/write stages, with unique constants. */
        u = state();
        v = input();
        u.control = 8 | (PS_COMBINERCOUNT_UNIQUE_C0 << 8);
        for (unsigned stage = 0; stage < 8; stage++) {
            u.rgb_inputs[stage] = inputs(PS_REGISTER_R0, PS_REGISTER_ONE,
                                         PS_REGISTER_C0, PS_REGISTER_ONE);
            u.rgb_outputs[stage] = output(0, 0, PS_REGISTER_R0, 0);
            u.alpha_inputs[stage] = inputs(PS_REGISTER_R0 | PS_CHANNEL_ALPHA,
                                           PS_REGISTER_ONE_HALF, 0, 0);
            u.alpha_outputs[stage] = output(PS_REGISTER_R0, 0, 0, 0);
            for (unsigned k = 0; k < 4; k++) {
                u.constants[2 * stage][k] = .01f * (stage + 1);
            }
        }
        add(u, v, .36f, .36f, .36f, .7f / 256);

        /* R0 alpha starts at1 when texture stage0 is NONE. */
        u = state();
        v = input();
        u.shader_stage_program = PS_TEXTUREMODES_NONE;
        add(u, v, 0, 0, 0, 1);

        /* SUM complement/clamp combinations; its alpha remains zero. */
        const float sumExpected[4][3] = { { .5f, .9f, 1.3f },
                                          { 1.1f, 1.1f, 1.1f },
                                          { .9f, .9f, .9f },
                                          { 1.5f, 1.1f, .7f } };
        for (unsigned flags = 0; flags < 8; flags++) {
            u = state();
            v = input();
            v.specular[0] = .2f;
            v.specular[1] = .4f;
            v.specular[2] = .6f;
            u.constants[0][0] = .3f;
            u.constants[0][1] = .5f;
            u.constants[0][2] = .7f;
            u.control = 1;
            u.rgb_inputs[0] = inputs(PS_REGISTER_C0, PS_REGISTER_ONE, 0, 0);
            u.rgb_outputs[0] = output(PS_REGISTER_R0, 0, 0, 0);
            u.final_inputs[0] =
                PS_REGISTER_V1R0_SUM | PS_INPUTMAPPING_SIGNED_IDENTITY;
            u.final_inputs[1] =
                (PS_REGISTER_V1R0_SUM | PS_CHANNEL_ALPHA |
                 PS_INPUTMAPPING_UNSIGNED_INVERT)
                    << 8 |
                (flags & 1 ? PS_FINALCOMBINERSETTING_COMPLEMENT_V1 : 0) |
                (flags & 2 ? PS_FINALCOMBINERSETTING_COMPLEMENT_R0 : 0) |
                (flags & 4 ? PS_FINALCOMBINERSETTING_CLAMP_SUM : 0);
            float expected[3];
            for (unsigned k = 0; k < 3; k++) {
                expected[k] = flags & 4 ? fminf(1, sumExpected[flags & 3][k]) :
                                          sumExpected[flags & 3][k];
            }
            add(u, v, expected[0], expected[1], expected[2], 1);
        }

        /* E/F multiplication, all final A/B/C/D/G source positions, mix order.
         */
        u = state();
        v = input();
        v.diffuse[0] = .25f;
        v.diffuse[1] = .5f;
        v.diffuse[2] = .75f;
        v.specular[0] = .2f;
        v.specular[1] = .4f;
        v.specular[2] = .6f;
        u.final_inputs[0] = PS_REGISTER_EF_PROD;
        u.final_inputs[1] = inputs(PS_REGISTER_V0, PS_REGISTER_V1,
                                   PS_REGISTER_EF_PROD | PS_CHANNEL_ALPHA, 0);
        add(u, v, .05f, .2f, .45f, 0);
        u.final_inputs[0] = inputs(PS_REGISTER_V0, PS_REGISTER_C0,
                                   PS_REGISTER_C1, PS_REGISTER_T0);
        u.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_BLUE) << 8;
        const float c0[] = { 1, .5f, 0, 0 }, c1[] = { 0, .5f, 1, 0 },
                    d[] = { .1f, .2f, .3f, 0 };
        memcpy(u.constants[16], c0, sizeof(c0));
        memcpy(u.constants[17], c1, sizeof(c1));
        memcpy(v.textures[0], d, sizeof(d));
        add(u, v, .35f, .7f, .55f, .75f);

        NV2AMetalCombinerState *states = calloc(case_count, sizeof(*states));
        NV2AMetalCombinerInput *data = calloc(case_count, sizeof(*data));
        assert(states && data);
        for (unsigned i = 0; i < case_count; i++) {
            states[i] = cases[i].state;
            data[i] = cases[i].input;
        }
        id<MTLBuffer> in =
            [commands.device newBufferWithBytes:data
                                         length:case_count * sizeof(*data)
                                        options:MTLResourceStorageModeShared];
        free(data);
        assert(in);
        begin(commands);
        NV2AMetalCombinerResult *result = [combiner encodeInputs:in
                                                           count:case_count
                                                          states:states
                                                      stateCount:case_count
                                                        commands:commands
                                                           error:&error];
        require(result != nil, error);
        /* State is snapshotted; changing the caller's memory after encoding
         * must not change any in-flight pixel. */
        memset(states, 0, case_count * sizeof(*states));
        free(states);
        finish(commands);
        const NV2AMetalCombinerOutput *out = result.outputs.contents;
        for (unsigned i = 0; i < case_count; i++) {
            for (unsigned k = 0; k < 4; k++) {
                check_float(out[i].color[k], cases[i].color[k], i, 16, k);
            }
            for (unsigned reg = 0; reg < 16; reg++) {
                if (cases[i].register_mask & (1u << reg)) {
                    for (unsigned k = 0; k < 4; k++) {
                        check_float(out[i].registers[reg][k],
                                    cases[i].registers[reg][k], i, reg, k);
                    }
                }
            }
        }

        /* Broadcast and dependent GPU buffer reads. Output's register0..6
         * prefix is a valid input record; T1 in that record aliases output V0.
         * A second dispatch observes V0 written by the first, without readback.
         */
        u = state();
        u.control = 1;
        u.rgb_inputs[0] = inputs(PS_REGISTER_ONE_HALF, PS_REGISTER_ONE, 0, 0);
        u.rgb_outputs[0] =
            output(PS_REGISTER_V0, 0, 0, PS_COMBINEROUTPUT_AB_BLUE_TO_ALPHA);
        u.final_inputs[0] = PS_REGISTER_V0;
        begin(commands);
        NV2AMetalCombinerResult *first = [combiner encodeInputs:in
                                                          count:1
                                                         states:&u
                                                     stateCount:1
                                                       commands:commands
                                                          error:&error];
        require(first != nil, error);
        NV2AMetalCombinerState secondState = state();
        secondState.final_inputs[0] = PS_REGISTER_T1;
        secondState.final_inputs[1] = (PS_REGISTER_T1 | PS_CHANNEL_ALPHA) << 8;
        NV2AMetalCombinerResult *second = [combiner encodeInputs:first.outputs
                                                           count:1
                                                          states:&secondState
                                                      stateCount:1
                                                        commands:commands
                                                           error:&error];
        require(second != nil, error);
        NV2AMetalCombinerResult *broadcast = [combiner encodeInputs:in
                                                              count:case_count
                                                             states:&u
                                                         stateCount:1
                                                           commands:commands
                                                              error:&error];
        require(broadcast != nil, error);
        finish(commands);
        const NV2AMetalCombinerOutput *dependent = second.outputs.contents;
        const NV2AMetalCombinerOutput *same = broadcast.outputs.contents;
        for (unsigned k = 0; k < 4; k++) {
            check_float(dependent[0].color[k], .5f, 0, 16, k);
            check_float(same[case_count - 1].registers[PS_REGISTER_V0][k], .5f,
                        0, PS_REGISTER_V0, k);
        }

        /* Invalid input/output registers, mappings and undefined final stage.
         */
        for (unsigned variant = 0; variant < 9; variant++) {
            u = state();
            u.control = 1;
            switch (variant) {
            case 0:
                u.control = 9;
                break;
            case 1:
                u.final_inputs[0] = u.final_inputs[1] = 0;
                break;
            case 2:
                u.rgb_inputs[0] = 6u << 24;
                break;
            case 3:
                u.alpha_inputs[0] = 7u << 8;
                break;
            case 4:
                u.rgb_inputs[0] = PS_REGISTER_EF_PROD;
                break;
            case 5:
                u.final_inputs[1] = PS_REGISTER_EF_PROD << 24;
                break;
            case 6:
                u.rgb_outputs[0] = output(PS_REGISTER_C0, 0, 0, 0);
                break;
            case 7:
                u.alpha_outputs[0] = output(0, PS_REGISTER_V1R0_SUM, 0, 0);
                break;
            case 8:
                u.rgb_outputs[0] = output(PS_REGISTER_R0, 0, 0, 0x28);
                break;
            }
            error = nil;
            assert(!nv2a_metal_combiner_validate(&u, &error) && error);
        }
        u = state();
        begin(commands);
        error = nil;
        assert(![combiner encodeInputs:in
                                 count:case_count + 1
                                states:&u
                            stateCount:1
                              commands:commands
                                 error:&error] &&
               error);
        assert(![combiner encodeInputs:in
                                 count:1
                                states:&u
                            stateCount:2
                              commands:commands
                                 error:&error]);
        assert(![combiner encodeInputs:in
                                 count:1
                                states:&u
                            stateCount:0
                              commands:commands
                                 error:&error]);
        NV2AMetalCombinerResult *empty = [combiner encodeInputs:in
                                                          count:0
                                                         states:&u
                                                     stateCount:1
                                                       commands:commands
                                                          error:&error];
        require(empty != nil, error);
        assert(empty.count == 0 && !empty.outputs);
        [commands cancel];
        printf("Metal 4 register combiners: %u analytical cases, broadcast and "
               "GPU dependency PASS (offscreen)\n",
               case_count);
    }
    return 0;
}
