/* Native texture storage comparison; no emulator launch.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SIGNED8_BENCHMARK_H
#define TEST_METAL_SIGNED8_BENCHMARK_H
#import <objc/runtime.h>

static void (*signed8_feedback_original)(id, SEL, MTL4CommitFeedbackHandler);
static double signed8_gpu_seconds;
static void signed8_feedback(id owner, SEL selector,
                             MTL4CommitFeedbackHandler handler)
{
    signed8_feedback_original(
        owner, selector, ^(id<MTL4CommitFeedback> feedback) {
          signed8_gpu_seconds = feedback.GPUEndTime - feedback.GPUStartTime;
          handler(feedback);
        });
}
static int signed8_time_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void texture_storage_benchmark(unsigned mode)
{
    BOOL packed = mode != 0;
    const unsigned formats[] = { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4 };
    for (unsigned family = 0; family < (mode == 1 ? 4u : 1u); family++) {
        NSError *error = nil;
        NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA32Float
               depthFormat:MTLPixelFormatInvalid
               sampleCount:1
                     error:&error];
        require(shader != nil, error);
        NV2AMetalTextureSampler *sampler =
            [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                      error:&error];
        require(sampler != nil, error);
        NV2AMetalTextureShape s =
            shape(mode == 2 ? NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5 :
                  packed    ? formats[family] :
                              NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8);
        s.width = s.height = 256;
        s.levels = 9;
        s.max_level = 8;
        NSUInteger length = 0;
        require([uploader sourceLengthForShape:&s
                                 paletteLength:0
                                        length:&length
                                         error:&error],
                error);
        NSMutableData *seed = [NSMutableData dataWithLength:length];
        uint8_t *bytes = seed.mutableBytes;
        for (NSUInteger i = 0; i < length; i++)
            bytes[i] = (i * 71 + i / 17) & 255;
        id<MTLBuffer> source = buffer(bytes, length);
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:512
                                        height:512
                                     mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [commands.device newTextureWithDescriptor:td];
        assert(target);
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                                @selector(addFeedbackHandler:));
        signed8_feedback_original =
            (void *)method_setImplementation(method, (IMP)signed8_feedback);
        s.signed_channels = packed ? 0 : 15;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *result = upload(s, source, 0, nil, 0);
        id<MTLTexture> reference =
            packed ? lane_float_decoder(s, (LaneCase){ s.format, 0, 9, 2, NO },
                                        source, 0) :
                     test_metal_float_reference(commands, result.texture);
        finish();
        for (unsigned profile = 0; profile < 3; profile++) {
            NV2AMetalSamplerConfig config = {
                .filter = (profile == 0 ? 1u :
                           profile == 1 ? 2u :
                                          6u)
                              << 16 |
                          (profile == 0 ? 1u : 2u) << 24 |
                          (profile == 2 ? 64u : 0u),
                .address = 1 | (1 << 8),
                .max_level = s.max_level,
                .anisotropy = profile == 2 ? 4 : 1,
                .signed_channels = s.signed_channels,
            };
            NV2AMetalTextureBinding *binding[2] = {
                [sampler bindingForTexture:result.texture
                                    config:&config
                                     error:&error],
                [sampler bindingForTexture:reference
                                    config:&config
                                     error:&error],
            };
            require(binding[0] && binding[1], error);
            NV2AMetalVertex v[6] = { 0 };
            const float xy[6][2] = { { 0, 0 },   { 512, 0 },   { 0, 512 },
                                     { 512, 0 }, { 512, 512 }, { 0, 512 } };
            for (unsigned i = 0; i < 6; i++) {
                v[i].clip[0] = xy[i][0] / 256 - 1;
                v[i].clip[1] = 1 - xy[i][1] / 256;
                v[i].clip[2] = .5f;
                v[i].clip[3] = 1;
                v[i].texcoord[0][0] =
                    xy[i][0] / 512 * (profile == 2 ? 8 : 1) - .125f;
                v[i].texcoord[0][1] = xy[i][1] / 512 - .125f;
                v[i].texcoord[0][3] = 1;
                v[i].plane[0][2] = v[i].plane[1][2] = v[i].plane[2][2] = .5f;
            }
            id<MTLBuffer> input = buffer(v, sizeof(v));
            NV2AMetalPixelUniforms u = { 0 };
            u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
            u.combiner.final_inputs[0] =
                PS_REGISTER_T0 | PS_INPUTMAPPING_SIGNED_IDENTITY;
            u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA |
                                          PS_INPUTMAPPING_SIGNED_IDENTITY)
                                         << 8;
            u.surface_scale[0] = u.surface_scale[1] = 1;
            u.clip_range[1] = u.clip_range[3] = 65535;
            u.clip_regions[0][2] = u.clip_regions[0][3] = 512;
            u.textures[0].dimension = 2;
            u.textures[0].scale = 1;
            u.textures[0].snorm = result.signedNormalized;
            u.textures[0].signed_channels = s.signed_channels;
            u.textures[0].sampling = binding[0].sampling;
            double times[2][9];
            uint64_t nonclearPixels = 0;
            for (unsigned trial = 0; trial < 11; trial++) {
                id<MTLBuffer> out[2];
                for (unsigned order = 0; order < 2; order++) {
                    unsigned selected = (trial + order) & 1;
                    NV2AMetalPixelTexture textures[4] = { 0 };
                    textures[0].texture = binding[selected].texture;
                    textures[0].sampler = binding[selected].sampler;
                    require([commands beginWithError:&error] != nil, error);
                    for (unsigned repeat = 0; repeat < 8; repeat++)
                        require([shader encodeVertices:input
                                                 count:6
                                             primitive:MTLPrimitiveTypeTriangle
                                              uniforms:&u
                                              textures:textures
                                                  pass:pass
                                          depthStencil:nil
                                              commands:commands
                                                 error:&error],
                                error);
                    finish();
                    assert(signed8_gpu_seconds > 0);
                    if (trial >= 2)
                        times[selected][trial - 2] = signed8_gpu_seconds;
                    require([commands beginWithError:&error] != nil, error);
                    out[selected] = read_texture(target, 0, 0);
                    finish();
                }
                assert(
                    !memcmp(out[0].contents, out[1].contents, 512 * 512 * 16));
                if (packed) {
                    const uint32_t *words = out[0].contents;
                    unsigned visible = 0;
                    BOOL varied = NO;
                    for (unsigned pixel = 0; pixel < 512 * 512; pixel++) {
                        uint32_t rgb =
                            (words[pixel * 4] | words[pixel * 4 + 1] |
                             words[pixel * 4 + 2]) &
                            0x7fffffffu;
                        visible += rgb != 0;
                        varied |= memcmp(words, words + pixel * 4, 12) != 0;
                    }
                    assert(visible > 512 * 512 / 2 && varied);
                    nonclearPixels += visible;
                }
            }
            for (unsigned i = 0; i < 2; i++)
                qsort(times[i], 9, sizeof(double), signed8_time_compare);
            printf("Metal4 %s benchmark family%u mask%u profile%u: 8 "
                   "draws/512x512,11 exact pairs/2 warmups/9 alternating "
                   "samples;GPU compact/Float32 %.6f/%.6f ms;%llu non-clear "
                   "RGB pixels PASS\n",
                   mode == 2 ? "R6G5B5 Snorm8" :
                   packed    ? "packed16" :
                               "signed8",
                   family, s.signed_channels, profile, times[0][4] * 1000,
                   times[1][4] * 1000, (unsigned long long)nonclearPixels);
        }

        method_setImplementation(method, (IMP)signed8_feedback_original);
    }
}
#endif
