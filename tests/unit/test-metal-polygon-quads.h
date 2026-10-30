/* Whole-empty-quad discard versus the previous late per-pixel discard.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_QUADS_H
#define TEST_METAL_POLYGON_QUADS_H
#include "test-metal-sampling-reference.h"
#define metal_shader_source pq_pixel_source
#include "pixel-shader-source.h"
#undef metal_shader_source

static NV2AMetalPixelShader *pq_comparison_shader(BOOL previous)
{
    NSError *error = nil;
    NSString *source = sampling_force_gradients(@(pq_pixel_source));
    NSString *gate =
        @"        if (!pixel_quad_helpers("
         "NV2A_COMBINER_SHADER_STAGE_PROGRAM(u.combiner),\n"
         "                                u.legacy_spec_const, u.textures)) {\n"
         "            if (!(coverage > 0))\n"
         "                discard_fragment();\n"
         "        } else if (!quad_or(uint(coverage > 0))) {\n"
         "            discard_fragment();\n"
         "        }\n";
    assert([source componentsSeparatedByString:gate].count == 2);
    NSString *replacement =
        previous ? @"        if "
                   @"(NV2A_COMBINER_SHADER_STAGE_PROGRAM(u.combiner) == 0) {\n"
                    "            if (!(coverage > 0))\n"
                    "                discard_fragment();\n"
                    "        } else if (!quad_or(uint(coverage > 0))) {\n"
                    "            discard_fragment();\n"
                    "        }\n" :
                   @"";
    source = [source stringByReplacingOccurrencesOfString:gate
                                               withString:replacement];
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
    NV2AMetalPixelShader *result =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatDepth32Float
                                         sampleCount:1
                                               error:&error];
    require(result != nil, error);
    /* This fresh instance has no cached pipelines. Keep production encoding,
     * specialization and bindings; change only its library to the late-discard
     * reference. Both sides receive the exact same geometry/projection buffers.
     */
    [result setValue:library forKey:@"library"];
    return result;
}

static void pq_material(unsigned kind, unsigned stage, unsigned sampling_case)
{
    pt_vertex_material = ^(NV2AMetalVertex *v, unsigned index) {
      for (unsigned k = 0; k < 4; k++) {
          v->texcoord[k][0] = .1f + index * .3f + k * .04f;
          v->texcoord[k][1] = .2f + index * .1f;
          v->texcoord[k][2] = .3f;
          v->texcoord[k][3] = 1;
      }
      if (kind == 1 || kind == 10)
          v->texcoord[kind == 1 ? stage : 0][0] = index ? .6f : -.3f;
      if (kind == 3)
          for (unsigned k = 0; k < 3; k++)
              v->texcoord[stage - 1][k] *= .25f + index * .125f;
    };
    pt_material = ^(NV2AMetalPixelUniforms *u,
                    NV2AMetalPixelTexture *textures) {
      NV2AMetalPixelTexture texture = textures[0];
      NV2AMetalTextureStage sampling = u->textures[0];
      memset(textures, 0, 4 * sizeof(*textures));
      memset(u->textures, 0, sizeof(u->textures));
      unsigned modes[4] = {}, output = PS_REGISTER_T0;
      modes[0] = PS_TEXTUREMODES_PASSTHRU;
      switch (kind) {
      case 0:
          modes[stage] = PS_TEXTUREMODES_PASSTHRU;
          output += stage;
          break;
      case 1:
          modes[stage] = PS_TEXTUREMODES_CLIPPLANE;
          output = PS_REGISTER_V0;
          break;
      case 2:
          modes[stage] = PS_TEXTUREMODES_DOTPRODUCT;
          break;
      case 3:
          modes[stage - 1] = PS_TEXTUREMODES_DOTPRODUCT;
          modes[stage] = PS_TEXTUREMODES_DOT_ZW;
          break;
      case 4:
      case 8:
          modes[1] = modes[2] = PS_TEXTUREMODES_DOTPRODUCT;
          modes[3] = PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST;
          u->legacy_spec_const = kind == 4;
          u->eye_vector[0] = 1;
          u->eye_vector[1] = .5f;
          u->eye_vector[2] = 1;
          if (kind == 4)
              break;
          textures[3] = texture;
          u->textures[3] = sampling;
          output = PS_REGISTER_T3;
          break;
      default:
          for (unsigned k = 0; k < stage; k++)
              modes[k] = PS_TEXTUREMODES_PASSTHRU;
          modes[stage] = kind == 6 ? PS_TEXTUREMODES_DPNDNT_AR :
                         kind == 7 ? PS_TEXTUREMODES_DPNDNT_GB :
                         kind == 9 ? PS_TEXTUREMODES_BUMPENVMAP_LUM :
                                     PS_TEXTUREMODES_PROJECT2D;
          if (kind == 10)
              modes[0] = PS_TEXTUREMODES_CLIPPLANE;
          textures[stage] = texture;
          u->textures[stage] = sampling;
          if (kind == 9) {
              u->textures[stage].bump_matrix[0] = .25f;
              u->textures[stage].bump_matrix[3] = .5f;
              u->textures[stage].bump_scale = .75f;
              u->textures[stage].bump_offset = .25f;
          }
          output += stage;
          break;
      }
      u->combiner.shader_stage_program = 0;
      for (unsigned k = 0; k < 4; k++)
          u->combiner.shader_stage_program |= modes[k] << (5 * k);
      u->combiner.final_inputs[0] = output;
      u->combiner.final_inputs[1] = (output | PS_CHANNEL_ALPHA) << 8;
      if (sampling_case == 11) {
          /* Deliberate zero-alpha texels exercise sample rejection before
           * the fragment's deferred coverage discard. Both shaders read this
           * same newly allocated texture, populated before GPU encoding. */
          for (unsigned level = 0; level < texture.texture.mipmapLevelCount;
               level++) {
              unsigned width = 16 >> level;
              float data[16 * 16 * 4];
              for (unsigned i = 0; i < width * width * 4; i++)
                  data[i] = (i * 71 + level * 19) % 256 / 255.f;
              for (unsigned y = 0; y < width; y++)
                  for (unsigned x = 0; x < width; x++)
                      data[(y * width + x) * 4 + 3] =
                          (x / 2 + y / 2) & 1 ? 0 : 1;
              [texture.texture replaceRegion:MTLRegionMake2D(0, 0, width, width)
                                 mipmapLevel:level
                                   withBytes:data
                                 bytesPerRow:width * 16];
          }
      }
      if (sampling_case) {
          for (unsigned k = 0; k < 4; k++) {
              NV2AMetalSamplingUniforms *s = &u->textures[k].sampling;
              if (!s->enabled)
                  continue;
              if (sampling_case == 11)
                  u->textures[k].alphakill = 1;
              s->min_linear = s->mag_linear =
                  sampling_case == 1 || sampling_case == 11 ? 0 : 1;
              s->mip_filter = 0;
              s->anisotropy = 1;
              if (sampling_case == 3)
                  s->mag_linear = 0;
              if (sampling_case == 4)
                  s->min_linear = 0;
              if (sampling_case == 5)
                  s->enabled = 0;
              if (sampling_case == 6 || sampling_case == 7)
                  s->mip_filter = sampling_case - 5;
              if (sampling_case == 8)
                  s->anisotropy = 2;
          }
          if (sampling_case == 9 || sampling_case == 10) {
              textures[0] = texture;
              u->textures[0] = sampling;
              u->textures[0].sampling.anisotropy = 1;
              u->textures[0].sampling.mip_filter = sampling_case == 9 ? 0 : 2;
              u->combiner.shader_stage_program =
                  (u->combiner.shader_stage_program & ~31u) |
                  PS_TEXTUREMODES_PROJECT2D;
              u->textures[stage].sampling.mip_filter =
                  sampling_case == 9 ? 2 : 0;
          }
      }
    };
}

static void polygon_quad_tests(void)
{
    NV2AMetalPixelShader *late = pq_comparison_shader(NO);
    unsigned saved_pairs = pt_pairs;
    uint64_t saved_depths = pt_written_depths;
    for (unsigned angle = 0; angle < 16; angle++)
        for (unsigned shape = 0; shape < 4; shape++)
            for (unsigned mode = 0; mode < 4; mode++)
                @autoreleasepool {
                    unsigned flags = (mode & 1) | (mode & 2 ? 2 : 0) |
                                     ((angle & 1) ? 256 | 128 | 64 : 0) |
                                     ((angle & 2) ? 16 : 0) |
                                     ((angle & 4) ? 8 : 0) |
                                     ((angle & 8) ? 32 : 0);
                    pt_case(angle, shape, flags, 64, NO, NO, late);
                }
    for (unsigned angle = 1; angle < 16; angle += 2)
        pt_case(angle, 0, 4 | 1 | 256, 128, NO, NO, late);
    for (unsigned angle = 0; angle < 16; angle++)
        for (unsigned mode = 0; mode < 4; mode++)
            pt_case(angle, 1, 1024 | (mode & 1) | (mode & 2 ? 256 : 0), 64, NO,
                    NO, late);
    unsigned material_pairs = pt_pairs;
    const unsigned materials[][2] = {
        { 0, 0 }, { 0, 1 }, { 0, 2 }, { 0, 3 },  { 1, 0 },  { 1, 1 },
        { 1, 2 }, { 1, 3 }, { 2, 1 }, { 2, 2 },  { 3, 2 },  { 3, 3 },
        { 4, 3 }, { 5, 0 }, { 5, 1 }, { 5, 2 },  { 5, 3 },  { 6, 1 },
        { 6, 2 }, { 6, 3 }, { 7, 1 }, { 7, 2 },  { 7, 3 },  { 8, 3 },
        { 9, 1 }, { 9, 2 }, { 9, 3 }, { 10, 1 }, { 10, 2 }, { 10, 3 }
    };
    for (unsigned m = 0; m < sizeof(materials) / sizeof(*materials); m++) {
        pq_material(materials[m][0], materials[m][1], 0);
        for (unsigned angle = 0; angle < 16; angle++)
            for (unsigned mode = 0; mode < 4; mode++)
                @autoreleasepool {
                    pt_case(angle, mode & 1 ? 2 : 0,
                            256 | (mode & 1) | (mode & 2) |
                                (angle & 1 ? 128 | 64 : 0) |
                                (angle & 2 ? 16 : 0) | (angle & 4 ? 32 : 0),
                            64, NO, NO, late);
                }
    }
    material_pairs = pt_pairs - material_pairs;
    unsigned base_pairs = pt_pairs;
    const unsigned base_materials[][2] = { { 5, 0 }, { 5, 3 }, { 6, 3 },
                                           { 7, 1 }, { 8, 3 }, { 9, 2 },
                                           { 10, 1 } };
    for (unsigned m = 0; m < 7; m++)
        for (unsigned sampling_case = 1; sampling_case <= 11; sampling_case++) {
            if (!base_materials[m][1] &&
                (sampling_case == 9 || sampling_case == 10))
                continue;
            pq_material(base_materials[m][0], base_materials[m][1],
                        sampling_case);
            for (unsigned angle = 0; angle < 16; angle++)
                for (unsigned mode = 0; mode < 4; mode++)
                    @autoreleasepool {
                        pt_case(angle, mode & 1 ? 2 : 0,
                                256 | (mode & 1) | (mode & 2) |
                                    (angle & 1 ? 128 | 64 : 0) |
                                    (angle & 2 ? 16 : 0) | (angle & 4 ? 32 : 0),
                                64, NO, NO, late);
                    }
        }
    base_pairs = pt_pairs - base_pairs;
    pt_material = nil;
    pt_vertex_material = nil;
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    pp_feedback_original =
        (void *)method_setImplementation(feedback, (IMP)pp_feedback);
    pt_case(1, 2, 1, 512, YES, NO, late);
    pt_case(1, 2, 1 | 256 | 128 | 64, 512, YES, NO, late);
    NV2AMetalPixelShader *previous = pq_comparison_shader(YES);
    const unsigned timed_materials[][3] = { { 0, 3, 0 }, { 3, 2, 0 },
                                            { 4, 3, 0 }, { 5, 0, 1 },
                                            { 5, 3, 2 }, { 6, 3, 2 } };
    for (unsigned i = 0; i < 6; i++) {
        pq_material(timed_materials[i][0], timed_materials[i][1],
                    timed_materials[i][2]);
        printf("Derivative-free polygon program kind%u stage%u "
               "sampling%u,prior gate "
               "reference:\n",
               timed_materials[i][0], timed_materials[i][1],
               timed_materials[i][2]);
        pt_case(1, 2, 1 | 256, 512, YES, NO, previous);
    }
    pt_material = nil;
    pt_vertex_material = nil;
    method_setImplementation(feedback, (IMP)pp_feedback_original);
    assert(material_pairs == 1920 && base_pairs == 4800 &&
           pt_pairs - saved_pairs == 7136 && pt_written_depths > saved_depths);
    printf(
        "Metal4 empty polygon quads:7136 exact early/reference "
        "color/depth/query "
        "pairs on identical geometry;16 directions,thin/wide,W/side "
        "clipping,large clip scales,flat/two-side,mip/AF/alpha/blend/logic/"
        "W-depth;1920 additional NONE/PASSTHRU/CLIP/DOT/ZW/legacy and "
        "later-stage mip/AF/dependent/bump/clip+sample/real SPEC_CONST pairs;"
        "66 prior-gate benchmark pairs;"
        "4800 base-only,alpha-kill and mixed later-gradient controls;"
        "%llu non-clear depth words PASS\n",
        (unsigned long long)(pt_written_depths - saved_depths));
    pt_pairs = saved_pairs;
    pt_written_depths = saved_depths;
}
#endif
