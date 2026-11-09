/* Partial manual taps through the real pixel pipeline.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_PARTIAL_TAPS_FRAGMENT_H
#define TEST_METAL_SAMPLER_PARTIAL_TAPS_FRAGMENT_H

typedef SamplerSharedTapsFragmentWork SamplerPartialTapsFragmentWork;

static NV2AMetalPixelShader *ptf_shader(BOOL reference)
{
    NSError *error = nil;
    NSString *source = spt_source(@(metal_shader_source), reference ? 1 : 0);
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = source;
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatDepth32Float
                                         sampleCount:1
                                               error:&error];
    require(pixel != nil, error);
    [pixel setValue:library forKey:@"library"];
    return pixel;
}

/* Hand-authored T0 data: independent R/X and A/Y gradients, or a true
 * zero-alpha band. The ordinary affine helper is otherwise untouched. */
static id<MTLTexture> ptf_source(unsigned mode)
{
    id<MTLTexture> texture =
        stf_texture(0, 4, 1, MTLPixelFormatRGBA32Float, 0, NULL);
    float texels[4][4][4];
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++) {
            texels[y][x][0] = (x + 1) / 8.f;
            texels[y][x][1] = (y + 1) / 8.f;
            texels[y][x][2] = .0625f;
            texels[y][x][3] = mode == 0 ? (y + 1) / 8.f :
                              mode == 1 ? .75f :
                              y < 2     ? 0 :
                                          .75f;
        }
    [texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
               mipmapLevel:0
                 withBytes:texels
               bytesPerRow:sizeof(texels[0])];
    return texture;
}

static SamplerPartialTapsFragmentWork
ptf_render(NV2AMetalPixelShader *pixel, const NV2AMetalVertex *v,
           const NV2AMetalPixelUniforms *u, NV2AMetalPixelTexture *t,
           BOOL halfDepth, unsigned mipCount, unsigned anisotropy)
{
    /* These are the actual public encode arguments and texture objects, not
     * an independently reconstructed register/layout expectation. */
    if (mipCount) {
        assert(t[1].texture.mipmapLevelCount == mipCount &&
               u->textures[1].sampling.enabled == 1 &&
               u->textures[1].sampling.min_linear == 1 &&
               u->textures[1].sampling.mag_linear == 1 &&
               u->textures[1].sampling.mip_filter == 2 &&
               u->textures[1].sampling.anisotropy == anisotropy &&
               u->textures[1].sampling.lod_bias == 1.5f);
    }
    return stf_render(pixel, v, u, t, halfDepth);
}

static void ptf_pixel(const SamplerPartialTapsFragmentWork *work, unsigned x,
                      unsigned y, const float value[4], BOOL visible,
                      BOOL halfDepth)
{
    for (unsigned k = 0; k < 4; k++)
        check(work->color[y][x][k], visible ? value[k] : clear_color[k]);
    check_depth(work->depth[y][x], visible            ? 2.f / 65535 :
                                   halfDepth && x < 4 ? 0 :
                                                        .99f);
}

static void sampler_partial_taps_fragment_tests(void)
{
    NV2AMetalPixelShader *pixels[2] = { ptf_shader(YES), ptf_shader(NO) };
    unsigned probes = 0, afControls = 0;
    for (unsigned group = 0; group < 10; group++) {
        @autoreleasepool {
            NV2AMetalPixelUniforms u = uniforms();
            NV2AMetalVertex v[6];
            quad(v);
            NV2AMetalPixelTexture t[4] = { 0 };
            __attribute__((objc_precise_lifetime)) NSMutableArray *owners =
                [NSMutableArray new];
            for (unsigned i = 0; i < 4; i++) {
                u.textures[i].sampling.enabled = 1;
                u.textures[i].sampling.min_linear = 1;
                u.textures[i].sampling.mag_linear = 1;
            }
            texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
            show_texture(&u, 0);
            coord(v, 0, -.125f, .5f, 0, 1);
            float expected[4] = { .125f, .3125f, .0625f, .75f };
            unsigned kind = group == 2 ? 2 : group == 3 || group == 4 ? 1 : 0;
            unsigned mipCount = 0, anisotropy = 1;
            if (group == 1) {
                coord(v, 0, .5f, -.125f, 0, 1);
                expected[0] = .3125f;
                expected[1] = .125f;
            } else if (group == 2) {
                texture_mode(&u, 0, PS_TEXTUREMODES_CUBEMAP);
                u.textures[0].cubemap = 1;
                coord(v, 0, 1, 1, 0, 1); /* +X, one face-edge axis only. */
                expected[0] = .3125f;
                expected[1] = .125f;
            } else if (group == 3 || group == 4) {
                texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT3D);
                u.textures[0].dimension = 3;
                coord(v, 0, -.125f, group == 3 ? .5f : -.125f, .5f, 1);
                expected[1] = group == 3 ? .3125f : .125f;
                expected[2] = .15625f;
            }
            id<MTLTexture> source =
                stf_texture(kind, 4, 1, MTLPixelFormatRGBA32Float, 0, NULL);
            if (group >= 5 && group <= 8) {
                source = ptf_source(group == 6 ? 1 : group == 8 ? 2 : 0);
                for (unsigned i = 0; i < 6; i++) {
                    float x = (v[i].clip[0] + 1) * 4;
                    float y = (1 - v[i].clip[1]) * 4;
                    v[i].texcoord[0][0] = group == 8 ? -.125f : -.25f + x / 8;
                    v[i].texcoord[0][1] = group == 6 ? -.125f :
                                          group == 8 ? y / 8 :
                                                       -.25f + y / 8;
                }
                if (group != 8) {
                    mipCount = group == 6 ? 7 : 5;
                    anisotropy = group == 6 ? 4 : 1;
                    texture_mode(&u, 1, PS_TEXTUREMODES_DPNDNT_AR);
                    show_texture(&u, 1);
                    u.textures[1].sampling.mip_filter = 2;
                    u.textures[1].sampling.lod_bias = 1.5f;
                    u.textures[1].sampling.anisotropy = anisotropy;
                    id<MTLTexture> mips =
                        stf_texture(0, group == 6 ? 64 : 16, mipCount,
                                    MTLPixelFormatRGBA32Float, 1, NULL);
                    [owners addObject:mips];
                    t[1].texture = mips;
                }
                if (group == 7) {
                    u.clip_regions[0][0] = 3;
                    u.clip_regions[0][1] = 1;
                    u.clip_regions[0][2] = 7;
                    u.clip_regions[0][3] = 7;
                } else if (group == 8)
                    u.textures[0].alphakill = 1;
            } else if (group == 9) {
                /* Real border/texel0 taps stay distinct; only Y collapses.
                 * The independent clip-plane stage removes three columns. */
                coord(v, 0, 0, -.125f, 0, 1);
                u.textures[0].sampling.address[0] = 4;
                const float border[4] = { .75f, .5f, .25f, .125f };
                memcpy(u.textures[0].sampling.border_color, border,
                       sizeof(border));
                const float color[4] = { .4375f, .3125f, .15625f, .4375f };
                memcpy(expected, color, sizeof(color));
                texture_mode(&u, 1, PS_TEXTUREMODES_CLIPPLANE);
                for (unsigned i = 0; i < 6; i++) {
                    float x = (v[i].clip[0] + 1) * 4;
                    v[i].texcoord[1][0] = x - 3;
                    v[i].texcoord[1][1] = v[i].texcoord[1][2] = .5f;
                    v[i].texcoord[1][3] = 1;
                }
            }
            [owners addObject:source];
            t[0].texture = source;
            SamplerPartialTapsFragmentWork a = ptf_render(
                pixels[0], v, &u, t, group == 8, mipCount, anisotropy);
            SamplerPartialTapsFragmentWork b = ptf_render(
                pixels[1], v, &u, t, group == 8, mipCount, anisotropy);
            stf_equal(&a, &b, group, 0);
            SamplerPartialTapsFragmentWork final = b;

            /* Full color/depth/query bytes precede every hand/spatial oracle.
             */
            const float axis[8] = { .125f,   .125f,   .125f,   .15625f,
                                    .21875f, .28125f, .34375f, .40625f };
            const float alpha[8] = {
                0, 0, 0, .1875f, .5625f, .75f, .75f, .75f
            };
            const float green[8] = { .125f,   .15625f, .21875f, .28125f,
                                     .34375f, .40625f, .46875f, .5f };
            for (unsigned y = 0; y < 8; y++)
                for (unsigned x = 0; x < 8; x++) {
                    float value[4];
                    memcpy(value, expected, sizeof(value));
                    BOOL visible = YES;
                    if (group == 5 || group == 7) {
                        unsigned dx = x < 2 ? 0 : x < 4 ? 1 : 2;
                        unsigned dy = y < 2 ? 0 : y < 4 ? 1 : 2;
                        value[0] = MAX(dx, dy) == 0 ? .125f :
                                   MAX(dx, dy) == 1 ? .1875f :
                                                      .3125f;
                        value[1] = .25f;
                        value[2] = .375f;
                        value[3] = .75f;
                        visible =
                            group != 7 || (x >= 3 && x < 7 && y >= 1 && y < 7);
                    } else if (group == 6) {
                        /* The mixed quad has major2, minor0: AF4 uses its
                         * configured ceiling, hence LOD.5, not LOD1.5. */
                        value[0] = x < 2 ? .125f : x < 4 ? .1875f : .3125f;
                        value[1] = .25f;
                        value[2] = .375f;
                        value[3] = .75f;
                    } else if (group == 8) {
                        value[0] = .125f;
                        value[1] = green[y];
                        value[2] = .0625f;
                        value[3] = alpha[y];
                        visible = x >= 4 && y >= 3;
                    } else if (group == 9)
                        visible = x >= 3;
                    ptf_pixel(&b, x, y, value, visible, group == 8);
                }
            assert(b.samples == (group == 7 ? 24u :
                                 group == 8 ? 20u :
                                 group == 9 ? 40u :
                                              64u));
            if (group == 5 || group == 6) {
                NV2AMetalPixelUniforms probe = u;
                show_texture(&probe, 0);
                a = ptf_render(pixels[0], v, &probe, t, NO, mipCount,
                               anisotropy);
                b = ptf_render(pixels[1], v, &probe, t, NO, mipCount,
                               anisotropy);
                stf_equal(&a, &b, group, 1);
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        const float value[4] = { axis[x],
                                                 group == 6 ? .125f : axis[y],
                                                 .0625f,
                                                 group == 6 ? .75f : axis[y] };
                        ptf_pixel(&b, x, y, value, YES, NO);
                    }
                assert(b.samples == 64 && b.color[0][0][0] != b.color[0][7][0]);
                if (group == 5)
                    assert(b.color[0][0][3] != b.color[7][0][3]);
                probes++;
            }
            if (group == 6) {
                NV2AMetalPixelUniforms one = u;
                one.textures[1].sampling.anisotropy = 1;
                a = ptf_render(pixels[0], v, &one, t, NO, mipCount, 1);
                b = ptf_render(pixels[1], v, &one, t, NO, mipCount, 1);
                stf_equal(&a, &b, group, 2);
                SamplerPartialTapsFragmentWork four =
                    ptf_render(pixels[1], v, &u, t, NO, mipCount, 4);
                stf_equal(&final, &four, group, 3);
                assert(!memcmp(four.depth, b.depth, sizeof(b.depth)) &&
                       four.samples == b.samples && b.samples == 64);
                BOOL different = NO;
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        const float value[4] = { x < 2 ? .125f :
                                                 x < 4 ? .4375f :
                                                         .5625f,
                                                 .25f, .375f, .75f };
                        ptf_pixel(&b, x, y, value, YES, NO);
                        for (unsigned k = 0; k < 3; k++)
                            different |=
                                b.color[y][x][k] != four.color[y][x][k];
                    }
                assert(different);
                afControls++;
            }
        }
    }
    assert(probes == 2 && afControls == 1);
    puts("Partial manual taps fragments: 10 exact color/depth/physical-query "
         "groups, "
         "2 independent T0 probes and a discriminating dependent AF1 control "
         "PASS");
}
#endif
