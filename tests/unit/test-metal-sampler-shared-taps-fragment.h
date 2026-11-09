/* Shared manual taps through the actual fragment pipeline.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_SHARED_TAPS_FRAGMENT_H
#define TEST_METAL_SAMPLER_SHARED_TAPS_FRAGMENT_H

typedef struct SamplerSharedTapsFragmentWork {
    float color[8][8][4];
    float depth[8][8];
    uint64_t samples;
} SamplerSharedTapsFragmentWork;

static NV2AMetalPixelShader *stf_shader(BOOL reference)
{
    NSError *error = nil;
    NSString *source = @(metal_shader_source);
    NSString *start = @"static bool sample_collapsed_taps(";
    NSString *end = @"\ntemplate <typename T>\nstatic float4 sample_level(";
    assert([source componentsSeparatedByString:start].count == 2 &&
           [source componentsSeparatedByString:end].count == 2);
    NSRange a = [source rangeOfString:start], b = [source rangeOfString:end];
    assert(a.location < b.location);
    if (reference) {
        NSRange body = [source
            rangeOfString:@"{"
                  options:0
                    range:NSMakeRange(a.location, b.location - a.location)];
        assert(body.location != NSNotFound);
        source = [source
            stringByReplacingCharactersInRange:NSMakeRange(body.location,
                                                           b.location -
                                                               body.location)
                                    withString:@"{ return false; }\n"];
    }
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
    /* Fresh, private pipeline caches, exactly as pq_comparison_shader. Never
     * change a shared library module or the production shader instance. */
    [result setValue:library forKey:@"library"];
    return result;
}

/* mode 0 is an affine texel pattern; mode 1 has distinct constant mip colors.
 * An optional constant supplies actual decoded Half/HILO/extreme texels. */
static id<MTLTexture> stf_texture(unsigned kind, unsigned size, unsigned levels,
                                  MTLPixelFormat format, unsigned mode,
                                  const float *constant)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind == 1 ? MTLTextureType3D :
                    kind == 2 ? MTLTextureTypeCube :
                                MTLTextureType2D;
    d.pixelFormat = format;
    d.width = d.height = size;
    d.depth = kind == 1 ? size : 1;
    d.mipmapLevelCount = levels;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:d];
    assert(texture);
    unsigned bytes = format == MTLPixelFormatRGBA16Float ? 8 : 16;
    for (unsigned face = 0; face < (kind == 2 ? 6u : 1u); face++)
        for (unsigned level = 0; level < levels; level++) {
            unsigned n = MAX(1u, size >> level), z = kind == 1 ? n : 1;
            NSMutableData *data =
                [NSMutableData dataWithLength:n * n * z * bytes];
            assert(data);
            for (unsigned k = 0; k < n * n * z; k++) {
                float value[4] = { ((k % n) + 1) / 8.f, ((k / n % n) + 1) / 8.f,
                                   ((k / (n * n)) + face + 1) / 16.f, .75f };
                if (mode == 1) {
                    value[0] = (level + 1) / 8.f;
                    value[1] = .25f;
                    value[2] = .375f;
                }
                if (constant)
                    memcpy(value, constant, sizeof(value));
                if (bytes == 16)
                    memcpy((uint8_t *)data.mutableBytes + k * bytes, value,
                           bytes);
                else {
                    _Float16 half[4];
                    for (unsigned c = 0; c < 4; c++)
                        half[c] = value[c];
                    memcpy((uint8_t *)data.mutableBytes + k * bytes, half,
                           bytes);
                }
            }
            [texture replaceRegion:MTLRegionMake3D(0, 0, 0, n, n, z)
                       mipmapLevel:level
                             slice:face
                         withBytes:data.bytes
                       bytesPerRow:n * bytes
                     bytesPerImage:n * n * bytes];
        }
    return texture;
}

static SamplerSharedTapsFragmentWork stf_render(NV2AMetalPixelShader *pixel,
                                                const NV2AMetalVertex *v,
                                                const NV2AMetalPixelUniforms *u,
                                                NV2AMetalPixelTexture *textures,
                                                BOOL halfDepth)
{
    NSError *error = nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:8
                                    height:8
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> colorTarget = [commands.device newTextureWithDescriptor:d];
    d.pixelFormat = MTLPixelFormatDepth32Float;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depthTarget = [commands.device newTextureWithDescriptor:d];
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:6 * sizeof(*v)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:8 * 256
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> query =
        [commands.device newBufferWithLength:8
                                     options:MTLResourceStorageModeShared];
    assert(colorTarget && depthTarget && input && readback && query);
    memset(readback.contents, 0xcd, readback.length);
    memset(query.contents, 0, query.length);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = colorTarget;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor =
        MTLClearColorMake(.91f, .92f, .93f, .94f);
    p.depthAttachment.texture = depthTarget;
    p.depthAttachment.loadAction =
        halfDepth ? MTLLoadActionLoad : MTLLoadActionClear;
    p.depthAttachment.storeAction = MTLStoreActionStore;
    p.depthAttachment.clearDepth = .99f;
    p.visibilityResultBuffer = query;
    p.visibilityResultType = MTLVisibilityResultTypeReset;
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionLess;
    ds.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState =
        [commands.device newDepthStencilStateWithDescriptor:ds];
    assert(depthState);
    require([commands beginWithError:&error] != nil, error);
    if (halfDepth) {
        id<MTLBuffer> seed =
            [commands.device newBufferWithLength:8 * 256
                                         options:MTLResourceStorageModeShared];
        assert(seed);
        memset(seed.contents, 0, seed.length);
        for (unsigned y = 0; y < 8; y++)
            for (unsigned x = 0; x < 8; x++) {
                float z = x < 4 ? 0 : .99f;
                memcpy((uint8_t *)seed.contents + 256 * y + 4 * x, &z, 4);
            }
        require([commands addResource:seed error:&error] &&
                    [commands addResource:depthTarget error:&error],
                error);
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        assert(e);
        [e copyFromBuffer:seed
                   sourceOffset:0
              sourceBytesPerRow:256
            sourceBytesPerImage:0
                     sourceSize:MTLSizeMake(8, 8, 1)
                      toTexture:depthTarget
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)
                        options:MTLBlitOptionNone];
        [e barrierAfterStages:MTLStageBlit
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
    }
    require([pixel encodeVertices:input
                            count:6
                        primitive:MTLPrimitiveTypeTriangle
                         uniforms:u
                         textures:textures
                             pass:p
                     depthStencil:depthState
                         commands:commands
                            error:&error],
            error);
    require([commands addResource:readback error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:depthTarget
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:readback
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    SamplerSharedTapsFragmentWork result = { 0 };
    [colorTarget getBytes:result.color
              bytesPerRow:sizeof(result.color[0])
               fromRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0];
    for (unsigned y = 0; y < 8; y++)
        memcpy(result.depth[y], (const uint8_t *)readback.contents + 256 * y,
               32);
    memcpy(&result.samples, query.contents, sizeof(result.samples));
    return result;
}

static void stf_equal(const SamplerSharedTapsFragmentWork *a,
                      const SamplerSharedTapsFragmentWork *b, unsigned group,
                      unsigned stage)
{
    /* Whole float words, including signed zero and NaN payloads, not a color
     * epsilon. All bytes are read only after native command completion. */
    if (memcmp(a->color, b->color, sizeof(a->color)) ||
        memcmp(a->depth, b->depth, sizeof(a->depth)) ||
        a->samples != b->samples) {
        fprintf(
            stderr,
            "Shared taps fragment group%u stage%u: GPU bytes/query differ\n",
            group, stage);
        abort();
    }
}

static void stf_golden(const SamplerSharedTapsFragmentWork *a,
                       const float expected[4], BOOL killed, BOOL halfDepth)
{
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            BOOL visible = !killed && (!halfDepth || x >= 4);
            const float *c = visible ? expected : clear_color;
            for (unsigned k = 0; k < 4; k++)
                check(a->color[y][x][k], c[k]);
            float z = visible ? 2.f / 65535 : halfDepth && x < 4 ? 0 : .99f;
            check_depth(a->depth[y][x], z);
        }
    assert(a->samples == (killed ? 0u : halfDepth ? 32u : 64u));
}

static void sampler_shared_taps_fragment_tests(void)
{
    NV2AMetalPixelShader *pixels[2] = { stf_shader(YES), stf_shader(NO) };
    unsigned stageProbes = 0;
    for (unsigned group = 0; group < 16; group++) {
        @autoreleasepool {
            NV2AMetalPixelUniforms u = uniforms();
            NV2AMetalVertex v[6];
            quad(v);
            NV2AMetalPixelTexture t[4] = { 0 };
            /* Strong owners survive the complete pair and every stage probe. */
            __attribute__((
                objc_precise_lifetime)) NSMutableArray<id<MTLTexture>> *owners =
                [NSMutableArray new];
            for (unsigned i = 0; i < 4; i++) {
                u.textures[i].sampling.enabled = 1;
                u.textures[i].sampling.min_linear = 1;
                u.textures[i].sampling.mag_linear = 1;
            }
            texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
            show_texture(&u, 0);
            coord(v, 0, -.125f, -.125f, -.125f, 1);
            float expected[4] = { .125f, .125f, .0625f, .75f };
            unsigned kind = group == 2 ? 1 : group == 3 ? 2 : 0;
            unsigned size = group == 6 || group == 7 || group == 8 ||
                                    group == 9 || group == 10 || group == 15 ?
                                1 :
                                4;
            unsigned levels = group == 4 ? 3 : 1;
            float constant[4] = { .25f, .5f, .75f, 1 };
            const float *value = NULL;
            MTLPixelFormat format = group == 6 ? MTLPixelFormatRGBA16Float :
                                                 MTLPixelFormatRGBA32Float;
            if (group == 1) {
                coord(v, 0, 1.125f, 1.125f, 0, 1);
                expected[0] = expected[1] = .5f;
            } else if (group == 2) {
                texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT3D);
                u.textures[0].dimension = 3;
            } else if (group == 3) {
                texture_mode(&u, 0, PS_TEXTUREMODES_CUBEMAP);
                u.textures[0].cubemap = 1;
                coord(v, 0, 1, 1, 1, 1); /* +X, lower/lower corner of face0. */
            } else if (group == 4 || group == 5) {
                for (unsigned i = 0; i < 6; i++) {
                    float x = (v[i].clip[0] + 1) * 4;
                    v[i].texcoord[0][0] =
                        group == 4 ? -4 + x * .25f : -8 + x * .5f;
                    v[i].texcoord[0][1] = -2;
                }
                if (group == 4) {
                    u.textures[0].sampling.mip_filter = 2;
                    u.textures[0].sampling.lod_bias = 1.5f;
                    expected[0] = .3125f; /* mix(level1=.25, level2=.375). */
                    expected[1] = .25f;
                    expected[2] = .375f;
                } else
                    u.textures[0].sampling.anisotropy = 4;
            } else if (group == 6) {
                value = constant;
                u.textures[0].snorm = NV2AMetalTextureNormalizationMixedHalf;
                u.textures[0].signed_channels = 1;
                for (unsigned k = 0; k < 4; k++)
                    expected[k] = constant[k] * 256.f / 255;
            } else if (group == 7) {
                value = constant;
                constant[1] = constant[2] = -.25f;
                u.hilo16_mask = 1;
                u.textures[0].signed_channels = 15;
                expected[0] = .25f * 65536.f / 65535;
                expected[1] = expected[2] = 0;
                expected[3] = 1;
            } else if (group == 8 || group == 9 || group == 10) {
                value = constant;
                if (group < 10) {
                    texture_mode(&u, 1,
                                 group == 8 ? PS_TEXTUREMODES_DPNDNT_AR :
                                              PS_TEXTUREMODES_DPNDNT_GB);
                    show_texture(&u, 1);
                    expected[0] = group == 8 ? .5f : .3125f;
                    expected[1] = group == 8 ? .1875f : .4375f;
                } else {
                    texture_mode(&u, 1, PS_TEXTUREMODES_DOTPRODUCT);
                    texture_mode(&u, 2, PS_TEXTUREMODES_DOTPRODUCT);
                    texture_mode(&u, 3, PS_TEXTUREMODES_DOT_STR_3D);
                    coord(v, 1, 1, 0, 0, 1);
                    coord(v, 2, 0, 1, 0, 1);
                    coord(v, 3, 0, 0, 1, 1);
                    u.textures[3].dimension = 3;
                    show_texture(&u, 3);
                    expected[0] = .1875f;
                    expected[1] = .3125f;
                    expected[2] = .21875f;
                }
            } else if (group == 11 || group == 12) {
                value = constant;
                constant[3] = group == 11 ? 0 : .75f;
                memcpy(expected, constant, sizeof(expected));
                u.textures[0].alphakill = 1;
            } else if (group == 13) {
                coord(v, 0, .5f, .5f, 0, 1); /* distinct x/y neighbors. */
                expected[0] = expected[1] = .3125f;
            } else if (group == 14) {
                /* Actual BORDER leaves base/base+1 distinct. No fabricated
                 * equal-outbound-address claim: x spans border/texel0. */
                u.textures[0].sampling.address[0] = 4;
                const float border[4] = { .75f, .5f, .25f, .125f };
                memcpy(u.textures[0].sampling.border_color, border,
                       sizeof(border));
                coord(v, 0, 0, -.125f, 0, 1);
                for (unsigned k = 0; k < 4; k++)
                    expected[k] = (expected[k] + border[k]) * .5f;
            } else if (group == 15) {
                /* f=0 causes real zero-weight Inf/NaN products even though
                 * all addressed positions name the same physical texel. */
                const uint32_t words[4] = { 0x80000000, 1, 0x7f800000,
                                            0x7fc00005 };
                memcpy(constant, words, sizeof(constant));
                value = constant;
                coord(v, 0, .5f, .5f, 0, 1);
            }
            id<MTLTexture> primary =
                stf_texture(kind, size, levels, format, group == 4, value);
            [owners addObject:primary];
            t[0].texture = primary;
            if (group >= 8 && group <= 10) {
                unsigned stage = group == 10 ? 3 : 1;
                id<MTLTexture> lookup = stf_texture(
                    group == 10, 4, 1, MTLPixelFormatRGBA32Float, 0, NULL);
                [owners addObject:lookup];
                t[stage].texture = lookup;
            }
            SamplerSharedTapsFragmentWork a =
                stf_render(pixels[0], v, &u, t, group == 12);
            SamplerSharedTapsFragmentWork b =
                stf_render(pixels[1], v, &u, t, group == 12);
            stf_equal(&a, &b, group, 4);
            if (group != 15)
                stf_golden(&b, expected, group == 11, group == 12);
            else {
                /* The exact reference includes the unchanged combiner's NaN
                 * handling too. Depth/query remain independently finite. */
                assert(b.samples == 64);
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++)
                        check_depth(b.depth[y][x], 2.f / 65535);
            }
            if (group >= 8 && group <= 10) {
                NV2AMetalPixelUniforms probe = u;
                show_texture(&probe, 0);
                a = stf_render(pixels[0], v, &probe, t, NO);
                b = stf_render(pixels[1], v, &probe, t, NO);
                stf_equal(&a, &b, group, 0);
                stf_golden(&b, constant, NO, NO);
                stageProbes++;
            }
            if (group == 8) {
                /* The guard now differs within the native pixel quad at
                 * x2/x3, before a dependent lookup takes derivatives of T0.
                 * Preserve the real gradient policy on BOTH shader variants. */
                NV2AMetalPixelUniforms dependent = uniforms();
                NV2AMetalVertex transition[6];
                quad(transition);
                for (unsigned i = 0; i < 6; i++) {
                    float x = (transition[i].clip[0] + 1) * 4;
                    transition[i].texcoord[0][0] = -.25f + x / 8;
                    transition[i].texcoord[0][1] = -.125f;
                }
                NV2AMetalPixelTexture chain[4] = { 0 };
                for (unsigned i = 0; i < 4; i++) {
                    dependent.textures[i].sampling.enabled = 1;
                    dependent.textures[i].sampling.min_linear = 1;
                    dependent.textures[i].sampling.mag_linear = 1;
                }
                texture_mode(&dependent, 0, PS_TEXTUREMODES_PROJECT2D);
                texture_mode(&dependent, 1, PS_TEXTUREMODES_DPNDNT_AR);
                dependent.textures[1].sampling.mip_filter = 2;
                dependent.textures[1].sampling.lod_bias = 1.5f;
                show_texture(&dependent, 1);
                id<MTLTexture> transitionSource =
                    stf_texture(0, 4, 1, MTLPixelFormatRGBA32Float, 0, NULL);
                id<MTLTexture> dependentMips =
                    stf_texture(0, 16, 5, MTLPixelFormatRGBA32Float, 1, NULL);
                [owners addObject:transitionSource];
                [owners addObject:dependentMips];
                chain[0].texture = transitionSource;
                chain[1].texture = dependentMips;
                a = stf_render(pixels[0], transition, &dependent, chain, NO);
                b = stf_render(pixels[1], transition, &dependent, chain, NO);
                stf_equal(&a, &b, group, 5);
                SamplerSharedTapsFragmentWork final = b;
                show_texture(&dependent, 0);
                a = stf_render(pixels[0], transition, &dependent, chain, NO);
                b = stf_render(pixels[1], transition, &dependent, chain, NO);
                stf_equal(&a, &b, group, 6);
                /* R is flat until x2; the mixed quad's ddx is 1/32,
                 * subsequent quads have ddx=1/16. At width16+bias1.5 this
                 * selects LOD0, LOD.5 and LOD1.5 respectively. */
                const float sourceR[8] = { .125f,   .125f,   .125f,   .15625f,
                                           .21875f, .28125f, .34375f, .40625f };
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        float mipR = x < 2 ? .125f : x < 4 ? .1875f : .3125f;
                        const float sourceColor[4] = { sourceR[x], .125f,
                                                       .0625f, .75f };
                        const float mipColor[4] = { mipR, .25f, .375f, .75f };
                        for (unsigned k = 0; k < 4; k++) {
                            check(b.color[y][x][k], sourceColor[k]);
                            check(final.color[y][x][k], mipColor[k]);
                        }
                        check_depth(b.depth[y][x], 2.f / 65535);
                        check_depth(final.depth[y][x], 2.f / 65535);
                    }
                assert(b.samples == 64 && final.samples == 64);
                assert(b.color[3][0][0] != b.color[3][7][0] &&
                       final.color[3][0][0] != final.color[3][7][0] &&
                       final.color[3][1][0] != final.color[3][2][0]);
                stageProbes++;
            }
        }
    }
    printf("Shared manual taps fragments:16 exact color/depth/physical-query "
           "groups, divergent dependent-mip phase, "
           "%u dependent-source stage probes PASS\n",
           stageProbes);
}
#endif
