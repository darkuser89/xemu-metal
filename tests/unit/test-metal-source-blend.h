/* Source-only blend packets versus an actual destination-fetch GPU reference.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SOURCE_BLEND_H
#define TEST_METAL_SOURCE_BLEND_H
#import <objc/runtime.h>

typedef id (*SourceBlendBuilder)(id, SEL, id, id, NSError **)
    __attribute__((ns_returns_retained));
static SourceBlendBuilder source_blend_builder;
static BOOL (*source_blend_encode)(id, SEL, id, NV2AMetalCommands *,
                                   NSError **);
static NSMutableDictionary<NSValue *, NSString *> *source_blend_names;
static NSString *source_blend_expected;
static BOOL source_blend_reference;
static unsigned source_blend_source_draws, source_blend_fetch_draws;

static id source_blend_pipeline(id object, SEL selector, id descriptor,
                                id options, NSError **error)
    __attribute__((ns_returns_retained));
static id source_blend_pipeline(id object, SEL selector, id descriptor,
                                id options, NSError **error)
{
    MTL4SpecializedFunctionDescriptor *specialized =
        (MTL4SpecializedFunctionDescriptor *)
            [descriptor fragmentFunctionDescriptor];
    MTL4LibraryFunctionDescriptor *function =
        (MTL4LibraryFunctionDescriptor *)specialized.functionDescriptor;
    if (source_blend_reference &&
        [function.name isEqualToString:@"nv2a_pixel_post_fragment"])
        function.name = @"nv2a_pixel_logic_fragment";
    id pipeline =
        source_blend_builder(object, selector, descriptor, options, error);
    if (pipeline)
        source_blend_names[[NSValue
            valueWithPointer:(__bridge const void *)pipeline]] = function.name;
    return pipeline;
}
static BOOL source_blend_packet(id object, SEL selector, id encoder,
                                NV2AMetalCommands *queue, NSError **error)
{
    id pipeline = [object valueForKey:@"pipeline"];
    NSString *name = source_blend_names[
        [NSValue valueWithPointer:(__bridge const void *)pipeline]];
    if (![name isEqualToString:source_blend_expected]) {
        fprintf(stderr, "Source blend selected %s expected %s\n",
                name.UTF8String, source_blend_expected.UTF8String);
        abort();
    }
    if (!source_blend_reference) {
        source_blend_source_draws +=
            [name isEqualToString:@"nv2a_pixel_post_fragment"];
        source_blend_fetch_draws +=
            [name isEqualToString:@"nv2a_pixel_logic_fragment"];
    }
    return source_blend_encode(object, selector, encoder, queue, error);
}

typedef struct SourceBlendCase {
    unsigned equation, source, destination;
    /* 0: needs destination, 1: source-only, 2: source-only on X1/X8. */
    unsigned sourceOnly;
    BOOL enabled;
} SourceBlendCase;
static const SourceBlendCase source_blend_cases[] = {
    { 2, 1, 0, 1, YES },  { 0, 4, 0, 1, YES },  { 1, 1, 0, 1, YES },
    { 5, 5, 0, 1, YES },  { 6, 14, 0, 1, YES }, { 2, 0, 0, 1, YES },
    { 2, 2, 0, 1, YES },  { 2, 3, 0, 1, YES },  { 2, 12, 0, 1, YES },
    { 2, 13, 0, 1, YES }, { 2, 15, 0, 1, YES }, { 3, 1, 0, 0, YES },
    { 4, 0, 0, 0, YES },  { 2, 8, 0, 0, YES },  { 2, 9, 0, 0, YES },
    { 2, 10, 0, 0, YES }, { 2, 1, 1, 0, YES },  { 2, 0, 6, 0, YES },
    { 2, 6, 0, 2, YES },  { 2, 7, 0, 2, YES },  { 2, 14, 7, 2, YES },
    { 0, 0, 0, 1, NO },
};

static NSData *source_blend_image(NV2AMetalPixelShader *shader,
                                  id<MTLBuffer> vertices, id<MTLTexture> target,
                                  id<MTLTexture> resolved, NSData *seed,
                                  unsigned bytes, unsigned policy, BOOL dither,
                                  BOOL reference, const unsigned *sequence,
                                  unsigned count)
{
    NSError *error = nil;
    if (target.sampleCount == 1)
        [target replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
                  mipmapLevel:0
                    withBytes:seed.bytes
                  bytesPerRow:8 * bytes];
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction =
        target.sampleCount == 1 ? MTLLoadActionLoad : MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(.17, .36, .81, .63);
    pass.colorAttachments[0].resolveTexture =
        target.sampleCount == 1 ? nil : resolved;
    pass.colorAttachments[0].storeAction = target.sampleCount == 1 ?
                                               MTLStoreActionStore :
                                               MTLStoreActionMultisampleResolve;
    require([commands beginWithError:&error] != nil, error);
    [shader beginPreparationForPass:pass commands:commands];
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [shader beginRasterEncoding:encoder];
    source_blend_reference = reference;
    @try {
        for (unsigned i = 0; i < count; i++) {
            SourceBlendCase test = source_blend_cases[sequence[i]];
            NV2AMetalDrawConfig config = draw_config();
            config.blend = test.enabled ?
                               NV_PGRAPH_BLEND_EN | test.equation |
                                   test.source << 4 | test.destination << 8 :
                               0;
            if (dither)
                config.control[0] |= NV_PGRAPH_CONTROL_0_DITHERENABLE;
            NV2AMetalDrawState *state =
                [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                    config:&config
                                                     error:&error];
            require(state != nil, error);
            BOOL opaque = policy >= NV2AMetalSurfaceStorageZ1 &&
                          policy <= NV2AMetalSurfaceStorageO8;
            BOOL onlySource =
                test.sourceOnly == 1 || (test.sourceOnly == 2 && opaque);
            BOOL post =
                dither || (policy >= NV2AMetalSurfaceStorageZ1 && test.enabled);
            source_blend_expected =
                !post ? @"nv2a_pixel_fragment" :
                !reference && (!test.enabled || onlySource) ?
                        @"nv2a_pixel_post_fragment" :
                        @"nv2a_pixel_logic_fragment";
            NV2AMetalPixelUniforms u = uniforms();
            NV2AMetalPixelTexture textures[4] = { 0 };
            require([shader encodeVertices:vertices
                                      offset:0
                                       count:6
                                   primitive:MTLPrimitiveTypeTriangle
                                    uniforms:&u
                                    textures:textures
                                        pass:pass
                                   drawState:state
                                 rasterClass:NV2AMetalPixelRasterNative
                        ignorePolygonCulling:NO
                               renderEncoder:encoder
                                    commands:commands
                                       error:&error],
                    error);
        }
    } @finally {
        [shader endRasterEncoding];
        [shader endPreparation];
        [encoder barrierAfterStages:MTLStageAll
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
    }
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    NSMutableData *image = [NSMutableData dataWithLength:64 * bytes];
    [resolved getBytes:image.mutableBytes
           bytesPerRow:8 * bytes
            fromRegion:MTLRegionMake2D(0, 0, 8, 8)
           mipmapLevel:0];
    return image;
}

static void source_blend_tests(void)
{
    NSError *error = nil;
    const struct {
        unsigned policy;
        MTLPixelFormat format;
        unsigned bytes;
    } targets[] = {
        { NV2AMetalSurfaceStorageNative, MTLPixelFormatBGRA8Unorm, 4 },
        { NV2AMetalSurfaceStorageNative, MTLPixelFormatRGBA8Unorm, 4 },
        { NV2AMetalSurfaceStorageNative, MTLPixelFormatBGR5A1Unorm, 2 },
        { NV2AMetalSurfaceStorageNative, MTLPixelFormatB5G6R5Unorm, 2 },
        { NV2AMetalSurfaceStorageZ1, MTLPixelFormatBGR5A1Unorm, 2 },
        { NV2AMetalSurfaceStorageO1, MTLPixelFormatBGR5A1Unorm, 2 },
        { NV2AMetalSurfaceStorageZ8, MTLPixelFormatBGRA8Unorm, 4 },
        { NV2AMetalSurfaceStorageO8, MTLPixelFormatBGRA8Unorm, 4 },
        { NV2AMetalSurfaceStorageZ7, MTLPixelFormatBGRA8Unorm, 4 },
        { NV2AMetalSurfaceStorageO7, MTLPixelFormatBGRA8Unorm, 4 }
    };
    NV2AMetalVertex v[6];
    quad(v);
    for (unsigned i = 0; i < 6; i++) {
        float x = (v[i].clip[0] + 1) * .5f, y = (v[i].clip[1] + 1) * .5f;
        const float color[] = { .1f + .7f * x, .2f + .6f * y, .9f - .7f * y,
                                .15f + .7f * x };
        memcpy(v[i].color[0], color, sizeof(color));
        v[i].clip[0] = v[i].clip[0] * .83f + .07f;
        v[i].clip[1] = v[i].clip[1] * .79f - .11f;
    }
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(vertices);
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    Method build = class_getInstanceMethod(
        object_getClass(compiler),
        @selector(
            newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:));
    Method encode = class_getInstanceMethod(
        NV2AMetalPixelDraw.class,
        @selector(encodeWithRenderEncoder:commands:error:));
    assert(build && encode);
    source_blend_names = [NSMutableDictionary new];
    source_blend_builder =
        (void *)method_setImplementation(build, (IMP)source_blend_pipeline);
    source_blend_encode =
        (void *)method_setImplementation(encode, (IMP)source_blend_packet);
    source_blend_source_draws = source_blend_fetch_draws = 0;
    unsigned pairs = 0;
    @try {
        for (unsigned p = 0; p < sizeof(targets) / sizeof(targets[0]); p++)
            for (unsigned samples = 1; samples <= 4; samples *= 4)
                for (unsigned dither =
                         targets[p].policy >= NV2AMetalSurfaceStorageZ1 ? 0 : 1;
                     dither < 2; dither++) {
                    MTLPixelFormat format = targets[p].format;
                    unsigned bytes = targets[p].bytes;
                    BOOL packed = format == MTLPixelFormatBGR5A1Unorm;
                    NV2AMetalPixelShader *candidate =
                        [[NV2AMetalPixelShader alloc]
                             initWithDevice:commands.device
                                colorFormat:format
                                depthFormat:MTLPixelFormatInvalid
                                sampleCount:samples
                            surfaceChannels:targets[p].policy
                                      error:&error];
                    NV2AMetalPixelShader *reference =
                        [[NV2AMetalPixelShader alloc]
                             initWithDevice:commands.device
                                colorFormat:format
                                depthFormat:MTLPixelFormatInvalid
                                sampleCount:samples
                            surfaceChannels:targets[p].policy
                                      error:&error];
                    require(candidate && reference, error);
                    MTLTextureDescriptor *desc = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:format
                                                     width:8
                                                    height:8
                                                 mipmapped:NO];
                    desc.storageMode = MTLStorageModeShared;
                    desc.usage = MTLTextureUsageRenderTarget;
                    id<MTLTexture> output =
                        [commands.device newTextureWithDescriptor:desc];
                    id<MTLTexture> resolved = output;
                    if (samples > 1) {
                        desc.textureType = MTLTextureType2DMultisample;
                        desc.sampleCount = samples;
                        desc.storageMode = MTLStorageModePrivate;
                        output =
                            [commands.device newTextureWithDescriptor:desc];
                    }
                    assert(output && resolved);
                    NSMutableData *seed =
                        [NSMutableData dataWithLength:64 * bytes];
                    for (unsigned i = 0; i < 64; i++) {
                        uint32_t word =
                            packed ?
                                ((i & 1) << 15 | ((i * 977 + 123) & 0x7fff)) :
                                ((i * 17) << 24 |
                                 ((i * 1103515245u + 12345) & 0xffffff));
                        memcpy((uint8_t *)seed.mutableBytes + i * bytes, &word,
                               bytes);
                    }
                    for (unsigned test = 0;
                         test < sizeof(source_blend_cases) /
                                    sizeof(source_blend_cases[0]);
                         test++) {
                        NSData *a = source_blend_image(
                            candidate, vertices, output, resolved, seed, bytes,
                            targets[p].policy, dither, NO, &test, 1);
                        NSData *b = source_blend_image(
                            reference, vertices, output, resolved, seed, bytes,
                            targets[p].policy, dither, YES, &test, 1);
                        assert([a isEqual:b]);
                        pairs++;
                    }
                    const unsigned sequence[] = { 0, 16, 11, 1, 18 };
                    for (unsigned count = 1; count <= 5; count++) {
                        NSData *a = source_blend_image(
                            candidate, vertices, output, resolved, seed, bytes,
                            targets[p].policy, dither, NO, sequence, count);
                        NSData *b = source_blend_image(
                            reference, vertices, output, resolved, seed, bytes,
                            targets[p].policy, dither, YES, sequence, count);
                        assert([a isEqual:b]);
                        pairs++;
                    }
                }
    } @finally {
        method_setImplementation(build, (IMP)source_blend_builder);
        method_setImplementation(encode, (IMP)source_blend_encode);
        source_blend_names = nil;
        source_blend_expected = nil;
    }
    assert(pairs == 864 && source_blend_source_draws &&
           source_blend_fetch_draws);
    printf("Source-only blend:864 bit-exact GPU frame pairs, %u source-only/%u "
           "destination "
           "packets, actual pipeline descriptors on cold/warm cache; 10 "
           "format/storage combinations,dither,MSAA1/4,subpixel edges and "
           "color/alpha gradients, "
           "factors/equations,MIN/MAX/destination controls and shared-pass "
           "prefixes PASS\n",
           source_blend_source_draws, source_blend_fetch_draws);
}
#endif
