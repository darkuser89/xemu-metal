/* Native final-combiner pipeline keys, raw uniforms and complete GPU results.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FINAL_COMBINER_KEYS_H
#define TEST_METAL_FINAL_COMBINER_KEYS_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"
#import <objc/runtime.h>

typedef struct SumFlagsProbeConstants {
    NV2AMetalPixelUniforms uniforms;
    NV2AMetalPixelStorageInfo info;
    NV2AMetalPolygonProjection emptyProjection;
} SumFlagsProbeConstants;
typedef struct SumFlagsProbeImage {
    SamplerSharedTapsFragmentWork gpu;
} SumFlagsProbeImage;
_Static_assert(sizeof(SumFlagsProbeImage) ==
                   8 * 8 * 5 * sizeof(float) + sizeof(uint64_t),
               "Full color/depth/query comparison has no padding");

typedef id<MTLRenderPipelineState> (*SumFlagsNativePSO)(
    id, SEL, MTL4PipelineDescriptor *, MTL4CompilerTaskOptions *, NSError **)
    __attribute__((ns_returns_retained));
static SumFlagsNativePSO sfp_native_original;
static id<MTLRenderPipelineState> sfp_native(id, SEL, MTL4PipelineDescriptor *,
                                             MTL4CompilerTaskOptions *,
                                             NSError **)
    __attribute__((ns_returns_retained));
static _Thread_local __unsafe_unretained id<MTL4Compiler> sfp_compiler;
static _Thread_local const NV2AMetalPixelUniforms *sfp_uniforms;
static _Thread_local unsigned sfp_native_calls, sfp_uploads;
static id<MTLRenderPipelineState> sfp_native(id owner, SEL selector,
                                             MTL4PipelineDescriptor *descriptor,
                                             MTL4CompilerTaskOptions *options,
                                             NSError **error)
{
    if (owner == sfp_compiler)
        sfp_native_calls++;
    return sfp_native_original(owner, selector, descriptor, options, error);
}
static id<MTLBuffer> (*sfp_upload_original)(id, SEL, const void *, NSUInteger,
                                            NSUInteger *, NSError **);
static id<MTLBuffer> sfp_upload(id owner, SEL selector, const void *bytes,
                                NSUInteger length, NSUInteger *offset,
                                NSError **error)
{
    BOOL observed = sfp_uniforms && owner == commands &&
                    length == sizeof(SumFlagsProbeConstants);
    if (observed) {
        /* Check the REAL constant-upload source, including inactive words and
         * all raw SUM flag bits. The caller already supplies the normalized
         * raster fields, so the complete uniform block must be byte-identical.
         */
        assert(!memcmp(bytes, sfp_uniforms, sizeof(*sfp_uniforms)));
        sfp_uploads++;
    }
    id<MTLBuffer> buffer =
        sfp_upload_original(owner, selector, bytes, length, offset, error);
    if (buffer && observed) {
        assert(offset && *offset <= buffer.length &&
               sizeof(*sfp_uniforms) <= buffer.length - *offset);
        assert(!memcmp((const uint8_t *)buffer.contents + *offset, sfp_uniforms,
                       sizeof(*sfp_uniforms)));
    }
    return buffer;
}

enum {
    SFPNoSUM0,
    SFPInactiveSUMGarbage,
    SFPNoSUM8,
    SFPRGBSUM,
    SFPAlphaBlueSUM,
    SFPAlphaChannelSUM,
    SFPLastRGBSUM,
    SFPFinalA,
    SFPFinalB,
    SFPFinalC,
    SFPFinalD,
    SFPFinalE,
    SFPFinalF,
    SFPFinalG,
    SFPProfiles
};
static const char *sfp_name(unsigned profile)
{
    static const char *names[] = { "NoSUM0",        "inactiveSUM+low0e",
                                   "NoSUM8",        "RGB-SUM",
                                   "AlphaBlue-SUM", "AlphaChannel-SUM",
                                   "RGB-row7-SUM",  "FINAL-A",
                                   "FINAL-B",       "FINAL-C",
                                   "FINAL-D",       "FINAL-E",
                                   "FINAL-F",       "FINAL-G" };
    assert(profile < SFPProfiles);
    return names[profile];
}
static NV2AMetalPixelUniforms sfp_state(unsigned profile, unsigned flags)
{
    NV2AMetalPixelUniforms u = uniforms();
    u.vertex_capacity = 6;
    u.textures[0].sampling.enabled = 1;
    u.textures[0].sampling.min_linear = 0;
    u.textures[0].sampling.mag_linear = 0;
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] =
        (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8 | flags << 5;
    const unsigned one = PS_REGISTER_ZERO | PS_INPUTMAPPING_UNSIGNED_INVERT;
    if (profile == SFPInactiveSUMGarbage) {
        /* Public API accepts these ignored low bits; this is a host-key
         * contract witness, not a claim about undocumented hardware flags. */
        u.combiner.final_inputs[1] |= 0x0e;
        u.combiner.rgb_inputs[7] = UINT32_C(0x0e1e8e9e);
        u.combiner.alpha_inputs[7] = UINT32_C(0x9e8e1e0e);
    }
    if (profile == SFPNoSUM8)
        u.combiner.control = 8;
    if (profile >= SFPRGBSUM) {
        const float r0[] = { .75f, .5f, .375f, .25f };
        memcpy(u.combiner.constants[0], r0, sizeof(r0));
        u.combiner.control = 1;
        u.combiner.rgb_inputs[0] = PS_REGISTER_C0 << 24 | one << 16;
        u.combiner.rgb_outputs[0] = PS_REGISTER_R0 << 4;
    }
    if (profile >= SFPRGBSUM && profile <= SFPLastRGBSUM) {
        unsigned stage = profile == SFPLastRGBSUM ? 7 : 1;
        u.combiner.control = stage + 1;
        unsigned input = PS_REGISTER_V1R0_SUM;
        if (profile == SFPAlphaChannelSUM)
            input |= PS_CHANNEL_ALPHA;
        if (profile == SFPRGBSUM || profile == SFPLastRGBSUM) {
            u.combiner.rgb_inputs[stage] = input << 24 | one << 16;
            u.combiner.rgb_outputs[stage] = PS_REGISTER_R1 << 4;
            u.combiner.final_inputs[0] = PS_REGISTER_R1;
        } else {
            u.combiner.alpha_inputs[stage] = input << 24 | one << 16;
            u.combiner.alpha_outputs[stage] = PS_REGISTER_R1 << 4;
            u.combiner.final_inputs[1] =
                (PS_REGISTER_R1 | PS_CHANNEL_ALPHA) << 8 | flags << 5;
        }
    } else if (profile >= SFPFinalA) {
        const unsigned sum = PS_REGISTER_V1R0_SUM;
        switch (profile) {
        case SFPFinalA:
            u.combiner.final_inputs[0] = sum << 24 | one << 16;
            break;
        case SFPFinalB:
            u.combiner.final_inputs[0] = one << 24 | sum << 16;
            break;
        case SFPFinalC:
            u.combiner.final_inputs[0] = sum << 8;
            break;
        case SFPFinalD:
            u.combiner.final_inputs[0] = sum;
            break;
        case SFPFinalE:
            u.combiner.final_inputs[0] = PS_REGISTER_EF_PROD;
            u.combiner.final_inputs[1] |= sum << 24 | one << 16;
            break;
        case SFPFinalF:
            u.combiner.final_inputs[0] = PS_REGISTER_EF_PROD;
            u.combiner.final_inputs[1] |= one << 24 | sum << 16;
            break;
        case SFPFinalG:
            u.combiner.final_inputs[1] = sum << 8 | flags << 5;
            break;
        default:
            abort();
        }
    }
    return u;
}
static void sfp_golden(const SumFlagsProbeImage *image, unsigned profile,
                       unsigned flags)
{
    /* Literal witnesses: V1=(.5,.75,.25), R0=(.75,.5,.375). No copy of the
     * production input-reader/selection algorithm serves as the oracle. */
    static const float sums[8][3] = {
        { 1.25f, 1.25f, .625f }, { .75f, 1.25f, .875f },
        { 1.25f, .75f, 1.125f }, { .75f, .75f, 1.375f },
        { 1, 1, .625f },         { .75f, 1, .875f },
        { 1, .75f, 1 },          { .75f, .75f, 1 }
    };
    float expected[] = { .125f, .25f, .375f, .5f };
    if (profile == SFPRGBSUM || profile == SFPLastRGBSUM)
        for (unsigned k = 0; k < 3; k++)
            expected[k] = fminf(sums[flags][k], 1);
    if (profile == SFPAlphaBlueSUM)
        expected[3] = fminf(sums[flags][2], 1);
    if (profile == SFPAlphaChannelSUM)
        expected[3] = 0;
    if (profile >= SFPFinalA && profile < SFPFinalG)
        memcpy(expected, sums[flags], 3 * sizeof(float));
    if (profile == SFPFinalG)
        expected[3] = sums[flags][2];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            for (unsigned k = 0; k < 4; k++) {
                float value = image->gpu.color[y][x][k];
                if (!(isfinite(value) &&
                      fabsf(value - expected[k]) < .00003f)) {
                    fprintf(stderr,
                            "SUMflags profile%s flag%u pixel%u,%u channel%u "
                            "got%.9g expected%.9g\n",
                            sfp_name(profile), flags, x, y, k, value,
                            expected[k]);
                    abort();
                }
            }
            float z = image->gpu.depth[y][x];
            assert(isfinite(z) && fabsf(z - 16384.f / 65535.f) < .000001f);
        }
    assert(image->gpu.samples == 64);
}
static NV2AMetalGeometryResult *sfp_geometry(NV2AMetalGeometry *engine,
                                             BOOL compact)
{
    NSError *error = nil;
    const float xy[3][2] = { { -8, -8 }, { 24, -8 }, { -8, 24 } };
    NV2AMetalVertex v[3] = { 0 };
    for (unsigned i = 0; i < 3; i++) {
        v[i].clip[0] = xy[i][0] / 4 - 1;
        v[i].clip[1] = 1 - xy[i][1] / 4;
        v[i].clip[2] = .25f;
        v[i].clip[3] = 1;
        v[i].screen[0] = xy[i][0];
        v[i].screen[1] = xy[i][1];
        v[i].screen[2] = 16384;
        v[i].screen[3] = 1;
        const float color[] = { .125f, .25f, .375f, .75f },
                    spec[] = { .5f, .75f, .25f, .5f };
        memcpy(v[i].color[0], color, sizeof(color));
        memcpy(v[i].color[1], spec, sizeof(spec));
        for (unsigned t = 0; t < 4; t++) {
            v[i].texcoord[t][0] = .5f;
            v[i].texcoord[t][1] = .5f;
            v[i].texcoord[t][3] = 1;
        }
    }
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(buffer);
    NV2AMetalGeometryRasterConfig config = { .polygonSmooth = YES,
                                             .viewportWidth = 8,
                                             .viewportHeight = 8 };
    NSArray *results;
    if (compact) {
        NV2AMetalVertexStream *stream =
            [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                    limit:3
                                                    error:&error];
        require(stream && [stream appendVertices:buffer
                                           first:0
                                           count:3
                                           error:&error],
                error);
        NV2AMetalVertexSlice *slice =
            [stream encodeSliceForDrawingWithCommands:commands error:&error];
        require(slice != nil, error);
        results = [engine encodeNativeRasterSlice:slice
                                        primitive:NV2AMetalPrimitiveTriangles
                                           config:&config
                                           smooth:YES
                                   firstProvoking:YES
                                     zPerspective:NO
                                         commands:commands
                                            error:&error];
    } else
        results = [engine encodeRasterVertices:buffer
                                         count:3
                                     primitive:NV2AMetalPrimitiveTriangles
                                        config:&config
                                        smooth:YES
                                firstProvoking:YES
                                  zPerspective:NO
                                      commands:commands
                                         error:&error];
    require(results.count == 1, error);
    NV2AMetalGeometryResult *g = results[0];
    assert(g.vertexCount == 6 && g.expandedPolygons &&
           g.compactPolygons == compact);
    return g;
}
static SumFlagsProbeImage sfp_render(NV2AMetalPixelShader *pixel,
                                     NV2AMetalGeometry *engine,
                                     NV2AMetalDrawState *raster,
                                     id<MTLTexture> texture, BOOL compact,
                                     NV2AMetalPixelUniforms *u)
{
    NSError *error = nil;
    NV2AMetalPixelUniforms original = *u;
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:8
                                    height:8
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [commands.device newTextureWithDescriptor:d];
    d.pixelFormat = MTLPixelFormatDepth32Float;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [commands.device newTextureWithDescriptor:d];
    id<MTLBuffer> read =
        [commands.device newBufferWithLength:8 * 256
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> query =
        [commands.device newBufferWithLength:8
                                     options:MTLResourceStorageModeShared];
    assert(color && depth && read && query);
    memset(query.contents, 0, 8);
    memset(read.contents, 0xcd, read.length);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(.91, .92, .93, .94);
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = .99;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeReset;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryResult *g = sfp_geometry(engine, compact);
    require([commands addResource:query error:&error], error);
    NV2AMetalPixelTexture textures[4] = { 0 };
    textures[0].texture = texture;
    unsigned uploads = sfp_uploads;
    sfp_uniforms = u;
    NV2AMetalPixelDraw *draw = nil;
    @try {
        draw = [pixel
                 prepareGeometry:g
                          offset:0
                           count:g.vertexCount
                        uniforms:u
                        textures:textures
                            pass:pass
                       drawState:raster
                     rasterClass:compact ? NV2AMetalPixelRasterCompactPolygon :
                                           NV2AMetalPixelRasterExpandedPolygon
            ignorePolygonCulling:YES
                        commands:commands
                           error:&error];
    } @finally {
        sfp_uniforms = NULL;
    }
    require(draw != nil, error);
    assert(sfp_uploads > uploads && !memcmp(&original, u, sizeof(original)));
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    BOOL ok = [draw encodeWithRenderEncoder:e commands:commands error:&error];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require(ok, error);
    require([commands addResource:read error:&error], error);
    id<MTL4ComputeCommandEncoder> copy =
        [commands.commandBuffer computeCommandEncoder];
    assert(copy);
    [copy barrierAfterQueueStages:MTLStageAll
                     beforeStages:MTLStageBlit
                visibilityOptions:MTL4VisibilityOptionDevice];
    [copy copyFromTexture:depth
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:read
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [copy barrierAfterStages:MTLStageBlit
           beforeQueueStages:MTLStageAll
           visibilityOptions:MTL4VisibilityOptionDevice];
    [copy endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    SumFlagsProbeImage result = { 0 };
    [color getBytes:result.gpu.color
        bytesPerRow:sizeof(result.gpu.color[0])
         fromRegion:MTLRegionMake2D(0, 0, 8, 8)
        mipmapLevel:0];
    for (unsigned y = 0; y < 8; y++)
        memcpy(result.gpu.depth[y], (const uint8_t *)read.contents + y * 256,
               32);
    memcpy(&result.gpu.samples, query.contents, 8);
    assert(!memcmp(&original, u, sizeof(original)));
    return result;
}
static void final_combiner_key_tests(void)
{
    @autoreleasepool {
        NSError *error = nil;
        /* Standard component tests supply their already-idle shared queue.
         * Keep all main-owned shader/target/depth/sampling state unchanged. */
        assert(commands && !commands.commandBuffer && !commands.batchSerial &&
               !commands.sealedBufferCount && !commands.hasPendingRasterPass);
        NSError *priorFailure = nil;
        assert(!commands.lastSubmitted ||
               ([commands.lastSubmitted completedWithError:&priorFailure] &&
                !priorFailure));
        NV2AMetalGeometry *engine =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        require(engine != nil, error);
        NV2AMetalDrawConfig config = {
            .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_ZENABLE |
                         NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16 }
        };
        NV2AMetalDrawState *raster =
            [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                config:&config
                                                 error:&error];
        require(raster != nil, error);
        const float texel[] = { .125f, .25f, .375f, .5f };
        id<MTLTexture> texture =
            stf_texture(0, 1, 1, MTLPixelFormatRGBA32Float, 0, texel);
        NV2AMetalPixelShader *probe = stf_shader(NO);
        id<MTL4Compiler> compiler = [probe valueForKey:@"compiler"];
        Method native = class_getInstanceMethod(
            object_getClass(compiler),
            @selector(newRenderPipelineStateWithDescriptor:compilerTaskOptions:
                      error:));
        Method upload = class_getInstanceMethod(
            NV2AMetalCommands.class,
            @selector(uploadBytes:length:offset:error:));
        assert(native && upload);
        IMP nativeSaved = method_getImplementation(native),
            uploadSaved = method_getImplementation(upload);
        sfp_native_original = (SumFlagsNativePSO)nativeSaved;
        sfp_upload_original = (void *)uploadSaved;
        method_setImplementation(native, (IMP)sfp_native);
        method_setImplementation(upload, (IMP)sfp_upload);
        NSMutableArray<NSData *> *expanded = [NSMutableArray new];
        @try {
            for (unsigned compact = 0; compact < 2; compact++)
                for (unsigned profile = 0; profile < SFPProfiles; profile++)
                    @autoreleasepool {
                        NV2AMetalPixelShader *pixel = stf_shader(NO);
                        id<MTL4Compiler> owner =
                            [pixel valueForKey:@"compiler"];
                        assert(owner == compiler);
                        sfp_compiler = owner;
                        sfp_native_calls = 0;
                        sfp_uploads = 0;
                        SumFlagsProbeImage first[8];
                        for (unsigned flag = 0; flag < 8; flag++) {
                            NV2AMetalPixelUniforms u = sfp_state(profile, flag);
                            first[flag] = sfp_render(pixel, engine, raster,
                                                     texture, compact, &u);
                            sfp_golden(&first[flag], profile, flag);
                            if (profile <= SFPNoSUM8 && flag)
                                assert(!memcmp(&first[0], &first[flag],
                                               sizeof(first[0])));
                            NSData *bytes =
                                [NSData dataWithBytes:&first[flag]
                                               length:sizeof(first[flag])];
                            if (!compact)
                                [expanded addObject:bytes];
                            else
                                assert([expanded[profile * 8 + flag]
                                    isEqualToData:bytes]);
                        }
                        unsigned firstRequests = sfp_native_calls;
                        for (unsigned flag = 0; flag < 8; flag++) {
                            NV2AMetalPixelUniforms u = sfp_state(profile, flag);
                            SumFlagsProbeImage warm = sfp_render(
                                pixel, engine, raster, texture, compact, &u);
                            sfp_golden(&warm, profile, flag);
                            assert(!memcmp(&first[flag], &warm, sizeof(warm)));
                        }
                        unsigned warm = sfp_native_calls - firstRequests;
                        if (profile >= SFPRGBSUM &&
                            profile != SFPAlphaChannelSUM)
                            assert(memcmp(first[0].gpu.color,
                                          first[1].gpu.color,
                                          sizeof(first[0].gpu.color)));
                        unsigned expected = profile <= SFPNoSUM8 ? 1u : 8u;
                        /* ALL GPU/host/upload bytes and handgoldens above
                         * precede every assertion about native compiler request
                         * counts. */
                        if (firstRequests != expected || warm) {
                            fprintf(
                                stderr,
                                "SUMflags %s compact%u nativeFirstRequests%u "
                                "expected%u warm%u uploads%u\n",
                                sfp_name(profile), compact, firstRequests,
                                expected, warm, sfp_uploads);
                            abort();
                        }
                        printf("SUMflags %s compact%u nativeFirstRequests%u "
                               "warm%u "
                               "uploads%u fullRGBA32/depth/query/rawUniform "
                               "PASS\n",
                               sfp_name(profile), compact, firstRequests, warm,
                               sfp_uploads);
                        sfp_compiler = nil;
                    }
        } @finally {
            sfp_uniforms = NULL;
            sfp_compiler = nil;
            method_setImplementation(upload, uploadSaved);
            method_setImplementation(native, nativeSaved);
        }
        require([commands waitUntilIdleWithError:&error], error);
    }
}
#endif
