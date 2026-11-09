/* Projection presence specialization; the identical fixture also runs with
 * the original host object and original count-selected MSL library.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PROJECTION_MODE_H
#define TEST_METAL_PROJECTION_MODE_H
#include "hw/xbox/nv2a/pgraph/metal/color-format.h"

typedef struct ProjectionModeConstants {
    NV2AMetalPixelUniforms uniforms;
    NV2AMetalPixelStorageInfo info;
    NV2AMetalPolygonProjection emptyProjection;
} ProjectionModeConstants;
@interface NV2AMetalPixelShader (ProjectionModeLowlevel)
- (NV2AMetalPixelDraw *)prepareVertices:(id<MTLBuffer>)vertices
                                 offset:(NSUInteger)offset
                                  count:(NSUInteger)count
                              primitive:(MTLPrimitiveType)primitive
                               uniforms:(const NV2AMetalPixelUniforms *)uniforms
                               textures:(const NV2AMetalPixelTexture *)textures
                                   pass:(MTL4RenderPassDescriptor *)pass
                           depthStencil:(id<MTLDepthStencilState>)depthStencil
                              drawState:(NV2AMetalDrawState *)drawState
                            rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                     polygonProjections:(id<MTLBuffer>)projections
                          polygonFacing:(id<MTLBuffer>)facing
                         rasterCoverage:(id<MTLBuffer>)coverage
                   sourceVertexCapacity:(NSUInteger)capacity
                        indexedVertices:(NV2AMetalIndexedVertices *)indexed
                            indexOffset:(NSUInteger)indexOffset
                   ignorePolygonCulling:(BOOL)ignore
                               commands:(NV2AMetalCommands *)commands
                                  error:(NSError **)error;
- (MTLGPUAddress)addressForConstants:(const ProjectionModeConstants *)constants
                            commands:(NV2AMetalCommands *)commands
                               error:(NSError **)error;
- (BOOL)encodePrepared:(NV2AMetalPixelDraw *)prepared
                  pass:(MTL4RenderPassDescriptor *)pass
         renderEncoder:(id<MTL4RenderCommandEncoder>)encoder
              commands:(NV2AMetalCommands *)commands
                 error:(NSError **)error;
@end

@interface ProjectionModeShader : NV2AMetalPixelShader
@property(nonatomic) NSData *expectedConstants;
@property(nonatomic) NSMutableArray<NSData *> *capturedConstants;
@end
@implementation ProjectionModeShader
- (MTLGPUAddress)addressForConstants:(const ProjectionModeConstants *)constants
                            commands:(NV2AMetalCommands *)commands
                               error:(NSError **)error
{
    assert(_expectedConstants.length == sizeof(*constants) &&
           !memcmp(constants, _expectedConstants.bytes, sizeof(*constants)));
    if (!_capturedConstants)
        _capturedConstants = [NSMutableArray new];
    [_capturedConstants addObject:[NSData dataWithBytes:constants
                                                 length:sizeof(*constants)]];
    return [super addressForConstants:constants commands:commands error:error];
}
@end

typedef id<MTLRenderPipelineState> (*ProjectionModeNativePSO)(
    id, SEL, MTL4PipelineDescriptor *, MTL4CompilerTaskOptions *, NSError **)
    __attribute__((ns_returns_retained));
static ProjectionModeNativePSO pm_native_original;
static id<MTLRenderPipelineState> pm_native(id, SEL, MTL4PipelineDescriptor *,
                                            MTL4CompilerTaskOptions *,
                                            NSError **)
    __attribute__((ns_returns_retained));
static _Thread_local __unsafe_unretained id<MTL4Compiler> pm_compiler;
static _Thread_local __unsafe_unretained NV2AMetalCommands *pm_commands;
static _Thread_local const ProjectionModeConstants *pm_constants;
static _Thread_local unsigned pm_psos[3], pm_uploads, pm_encoders;
static id<MTLRenderPipelineState> pm_native(id owner, SEL selector,
                                            MTL4PipelineDescriptor *descriptor,
                                            MTL4CompilerTaskOptions *options,
                                            NSError **error)
{
    if (owner == pm_compiler) {
        id fragment = ((MTL4RenderPipelineDescriptor *)descriptor)
                          .fragmentFunctionDescriptor;
        if ([fragment isKindOfClass:MTL4SpecializedFunctionDescriptor.class])
            fragment = [(MTL4SpecializedFunctionDescriptor *)
                    fragment functionDescriptor];
        NSString *name = [fragment name];
        const char *entries[] = { "nv2a_pixel_fragment",
                                  "nv2a_pixel_post_fragment",
                                  "nv2a_pixel_logic_fragment" };
        for (unsigned i = 0; i < 3; i++)
            if ([name isEqualToString:@(entries[i])])
                pm_psos[i]++;
    }
    return pm_native_original(owner, selector, descriptor, options, error);
}
static id<MTLBuffer> (*pm_upload_original)(id, SEL, const void *, NSUInteger,
                                           NSUInteger *, NSError **);
static id<MTLBuffer> pm_upload(id owner, SEL selector, const void *bytes,
                               NSUInteger length, NSUInteger *offset,
                               NSError **error)
{
    BOOL observe =
        owner == pm_commands && length == sizeof(ProjectionModeConstants);
    if (observe) {
        assert(pm_constants && !memcmp(bytes, pm_constants, length));
        pm_uploads++;
    }
    id<MTLBuffer> result =
        pm_upload_original(owner, selector, bytes, length, offset, error);
    if (observe && result) {
        assert(*offset <= result.length && length <= result.length - *offset);
        assert(
            !memcmp((const uint8_t *)result.contents + *offset, bytes, length));
    }
    return result;
}
static id (*pm_render_original)(id, SEL, MTL4RenderPassDescriptor *);
static id pm_render(id owner, SEL selector, MTL4RenderPassDescriptor *pass)
{
    if (pm_commands && owner == pm_commands.commandBuffer)
        pm_encoders++;
    return pm_render_original(owner, selector, pass);
}

@interface ProjectionModeTargets : NSObject
@property(nonatomic) id<MTLTexture> color, zeta;
@property(nonatomic) id<MTLBuffer> query;
@property(nonatomic) MTL4RenderPassDescriptor *pass;
@end
@implementation ProjectionModeTargets
@end
@interface ProjectionModeImage : NSObject
@property(nonatomic) NSData *pixels;
@property(nonatomic) uint64_t query;
@end
@implementation ProjectionModeImage
@end

static void pm_begin(NV2AMetalCommands *q)
{
    NSError *error = nil;
    require([q beginWithError:&error] != nil, error);
}
static void pm_finish(NV2AMetalCommands *q)
{
    NSError *error = nil;
    require([q submitWithError:&error] && [q waitUntilIdleWithError:&error],
            error);
}
static ProjectionModeTargets *pm_targets(NV2AMetalCommands *q, unsigned entry)
{
    ProjectionModeTargets *t = [ProjectionModeTargets new];
    t.color = cpf_target(q.device, entry ? MTLPixelFormatRGBA8Unorm :
                                           MTLPixelFormatRGBA32Float);
    t.zeta = cpf_target(q.device, MTLPixelFormatDepth32Float_Stencil8);
    t.query = [q.device newBufferWithLength:8
                                    options:MTLResourceStorageModeShared];
    assert(t.query);
    memset(t.query.contents, 0, 8);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = t.color;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 0);
    p.depthAttachment.texture = t.zeta;
    p.depthAttachment.loadAction = MTLLoadActionClear;
    p.depthAttachment.storeAction = MTLStoreActionStore;
    p.depthAttachment.clearDepth = 1;
    p.stencilAttachment.texture = t.zeta;
    p.stencilAttachment.loadAction = MTLLoadActionClear;
    p.stencilAttachment.storeAction = MTLStoreActionStore;
    p.stencilAttachment.clearStencil = 0x11;
    p.visibilityResultBuffer = t.query;
    p.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    t.pass = p;
    return t;
}
static NV2AMetalDrawState *pm_state(NV2AMetalCommands *q, unsigned entry)
{
    NV2AMetalDrawConfig dc = { 0 };
    dc.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ZENABLE |
                    NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                    NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE | 7 << 16;
    dc.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 |
                    0x13 << 8 | 0xff << 16 | 0xffu << 24;
    dc.control[2] = 1 | 1 << 4 | 3 << 8;
    if (entry == 1)
        dc.control[0] |= NV_PGRAPH_CONTROL_0_DITHERENABLE;
    if (entry == 2)
        dc.blend =
            NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12; // XOR uses destination.
    NSError *error = nil;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:q.device
                                            config:&dc
                                             error:&error];
    require(state != nil, error);
    return state;
}
static PolygonWindowCase pm_case(unsigned scene, BOOL compact)
{
    return (PolygonWindowCase){ .window = 3,
                                .material = scene,
                                .scale = 1,
                                .samples = 1,
                                .compact = compact,
                                .sourceAF = 1,
                                .dependentAF = 1,
                                .lodBias = 1.5f };
}
static NV2AMetalPixelDraw *
pm_prepare(ProjectionModeShader *shader, NV2AMetalCommands *q,
           NV2AMetalGeometryResult *g, id<MTLBuffer> projection,
           NSUInteger count, NSUInteger offset,
           NV2AMetalPixelRasterClass raster, NV2AMetalPixelUniforms *u,
           NV2AMetalPixelTexture textures[4], ProjectionModeTargets *t,
           NV2AMetalDrawState *state, NSError **error)
{
    ProjectionModeConstants expected = { .uniforms = *u };
    expected.uniforms.vertex_capacity = (unsigned)count;
    expected.uniforms.point_sprite = 0;
    expected.uniforms.logic_op =
        state.logicEnabled ? state.logicOperation + 1 : 0;
    expected.uniforms.blend = state.blendWord;
    expected.uniforms.dither = state.ditherEnabled;
    nv2a_metal_color_bits(t.color.pixelFormat, expected.uniforms.color_bits);
    expected.info.polygon_projection_count =
        projection ? (unsigned)(count / 6) : 0;
    expected.info.source_vertex_count =
        g.compactPolygons ? (unsigned)g.physicalVertexCount : 0;
    NSData *input = [NSData dataWithBytes:u length:sizeof(*u)];
    shader.expectedConstants = [NSData dataWithBytes:&expected
                                              length:sizeof(expected)];
    pm_constants = &expected;
    NV2AMetalPixelDraw *draw;
    @try {
        draw = [shader
                 prepareVertices:g.vertices
                          offset:offset
                           count:count
                       primitive:g.primitiveType
                        uniforms:u
                        textures:textures
                            pass:t.pass
                    depthStencil:state.depthStencil
                       drawState:state
                     rasterClass:raster
              polygonProjections:projection
                   polygonFacing:nil
                  rasterCoverage:g.compactPolygons ? g.polygonCoverage : nil
            sourceVertexCapacity:g.compactPolygons ? g.physicalVertexCount : 0
                 indexedVertices:g.indexedVertices
                     indexOffset:g.indexOffset
            ignorePolygonCulling:YES
                        commands:q
                           error:error];
    } @finally {
        shader.expectedConstants = nil;
        pm_constants = NULL;
    }
    assert(!memcmp(input.bytes, u, sizeof(*u)));
    return draw;
}
static void pm_emit(NV2AMetalCommands *q, ProjectionModeShader *shader,
                    NSArray<NV2AMetalPixelDraw *> *draws,
                    ProjectionModeTargets *t)
{
    NSError *error = nil;
    for (id r in @[ t.color, t.zeta, t.query ])
        require([q addResource:r error:&error], error);
    id<MTL4RenderCommandEncoder> e =
        [q.commandBuffer renderCommandEncoderWithDescriptor:t.pass];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:nv2a_metal_pixel_pass_stages()
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    [shader beginRasterEncoding:e];
    for (NV2AMetalPixelDraw *draw in draws)
        require([draw encodeWithRenderEncoder:e commands:q error:&error],
                error);
    [shader endRasterEncoding];
    [e barrierAfterStages:nv2a_metal_pixel_pass_stages()
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
static ProjectionModeImage *pm_image(NV2AMetalCommands *q,
                                     ProjectionModeTargets *t)
{
    id<MTLBuffer> read = cpf_read(q, t.color, t.zeta);
    pm_finish(q);
    ProjectionModeImage *image = [ProjectionModeImage new];
    image.pixels = [NSData dataWithBytes:read.contents length:read.length];
    uint64_t query = 0;
    memcpy(&query, t.query.contents, sizeof(query));
    image.query = query;
    return image;
}
static void pm_golden(ProjectionModeImage *image, unsigned scene,
                      unsigned entry, unsigned draws, BOOL empty,
                      ProjectionModeImage *alphaWitness)
{
    assert(image.pixels.length == 32 * 32 * 24);
    const uint32_t *raw = image.pixels.bytes;
    NSMutableData *withoutStencil = [NSMutableData dataWithLength:32 * 32 * 20];
    uint64_t visible = 0;
    for (unsigned y = 0; y < 32; y++)
        for (unsigned x = 0; x < 32; x++) {
            NSUInteger i = y * 32 + x;
            BOOL inside = !empty && x >= 3 && x < 29 && y >= 5 && y < 27;
            visible += inside;
            assert(raw[6 * i + 5] == (inside ? 0x13u : 0x11u));
            memcpy((uint8_t *)withoutStencil.mutableBytes + i * 20, raw + i * 6,
                   20);
            if (!inside) {
                const float clear[5] = { 0, 0, 1, 0, 1 };
                assert(!memcmp(raw + i * 6, clear, sizeof(clear)));
            } else {
                const float *color = (const float *)(raw + i * 6);
                assert(isfinite(color[4]) && color[4] < 1 && color[4] >= 0);
                if (entry == 2) {
                    /* Undithered color_quantize floors before XOR. */
                    float xorColor[4] = { 63 / 255.f, 127 / 255.f, 64 / 255.f,
                                          1 };
                    assert(alphaWitness.pixels.length == image.pixels.length);
                    const uint32_t *normal = alphaWitness.pixels.bytes;
                    uint32_t alphaBits = normal[6 * i + 3];
                    float alpha;
                    memcpy(&alpha, &alphaBits, sizeof(alpha));
                    /* Independent existing RGBA32 GPU output, before the
                     * logic entry's quantizer. Preserve the Alpha1 edge. */
                    if (!(isfinite(alpha) &&
                          (alpha >= 1 || (alpha > 254.f / 255.f && alpha < 1))))
                        fprintf(stderr,
                                "Projection normal alpha pixel%u,%u "
                                "draws%u raw%08x value%.9g\n",
                                x, y, draws, alphaBits, alpha);
                    assert(
                        isfinite(alpha) &&
                        (alpha >= 1 || (alpha > 254.f / 255.f && alpha < 1)));
                    xorColor[3] = alpha >= 1 ? 1 : 254.f / 255.f;
                    const float clear[4] = { 0, 0, 1, 0 };
                    const float *expected = draws % 2 ? xorColor : clear;
                    for (unsigned k = 0; k < 4; k++) {
                        if (!(fabsf(color[k] - expected[k]) < 0.00001f))
                            fprintf(
                                stderr,
                                "Projection logic pixel%u,%u entry%u draws%u "
                                "channel%u actual(%.9g,%.9g,%.9g,%.9g) "
                                "expected(%.9g,%.9g,%.9g,%.9g) "
                                "normalAlpha%08x/%.9g\n",
                                x, y, entry, draws, k, color[0], color[1],
                                color[2], color[3], expected[0], expected[1],
                                expected[2], expected[3], alphaBits, alpha);
                        assert(fabsf(color[k] - expected[k]) < 0.00001f);
                    }
                }
            }
        }
    assert(image.query == visible * draws);
    if (!entry && !empty) {
        PolygonWindowImage *oracle = [PolygonWindowImage new];
        oracle.bytes = withoutStencil;
        oracle.query = visible;
        pwc_golden(oracle, pm_case(scene, NO), scene != 0);
    }
}
static void pm_append(NSMutableData *dump, ProjectionModeImage *image,
                      NSArray<NSData *> *constants)
{
    uint32_t count = (uint32_t)constants.count;
    [dump appendBytes:&count length:4];
    for (NSData *data in constants)
        [dump appendData:data];
    [dump appendData:image.pixels];
    uint64_t query = image.query;
    [dump appendBytes:&query length:sizeof(query)];
}
static id<MTLBuffer> pm_zero_projection(NV2AMetalCommands *q)
{
    NV2AMetalPolygonProjection zero = { 0 };
    id<MTLBuffer> staging =
        [q.device newBufferWithBytes:&zero
                              length:sizeof(zero)
                             options:MTLResourceStorageModeShared];
    id<MTLBuffer> result =
        [q.device newBufferWithLength:sizeof(zero)
                              options:MTLResourceStorageModePrivate];
    NSError *error = nil;
    require(staging && result && [q addResource:staging error:&error] &&
                [q addResource:result error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:staging
             sourceOffset:0
                 toBuffer:result
        destinationOffset:0
                     size:sizeof(zero)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}

static ProjectionModeImage *pm_group(NV2AMetalCommands *q,
                                     NV2AMetalGeometry *engine, unsigned scene,
                                     unsigned entry, unsigned expectedModes,
                                     NSMutableData *dump,
                                     ProjectionModeImage *alphaWitness)
{
    NSError *error = nil;
    ProjectionModeShader *shader = [[ProjectionModeShader alloc]
        initWithDevice:q.device
           colorFormat:entry ? MTLPixelFormatRGBA8Unorm :
                               MTLPixelFormatRGBA32Float
           depthFormat:MTLPixelFormatDepth32Float_Stencil8
           sampleCount:1
                 error:&error];
    require(shader != nil, error);
    NV2AMetalDrawState *state = pm_state(q, entry);
    pm_begin(q);
    NV2AMetalGeometryResult *geometries[2];
    for (unsigned compact = 0; compact < 2; compact++)
        geometries[compact] =
            pwc_geometry(q, engine, pm_case(scene, compact), 32);
    id<MTLBuffer> zero = pm_zero_projection(q);
    pm_finish(q);
    memset(pm_psos, 0, sizeof(pm_psos));
    pm_compiler = [shader valueForKey:@"compiler"];
    ProjectionModeImage *first = nil;
    NSMutableArray<id<MTLRenderPipelineState>> *soloPipelines =
        [NSMutableArray new];
    for (unsigned pass = 0; pass < 2; pass++) {
        for (unsigned binding = 0; binding < 4; binding++) {
            unsigned compact = binding / 2;
            NV2AMetalGeometryResult *g = geometries[compact];
            id<MTLBuffer> projection = binding & 1 ? g.polygonProjections : nil;
            pm_begin(q);
            ProjectionModeTargets *t = pm_targets(q, entry);
            NV2AMetalPixelTexture textures[4] = { 0 };
            NV2AMetalPixelUniforms u =
                pwc_uniforms(pm_case(scene, compact), 32, textures);
            [shader.capturedConstants removeAllObjects];
            pm_commands = q;
            NV2AMetalPixelDraw *draw =
                pm_prepare(shader, q, g, projection, g.vertexCount,
                           g.firstVertex * sizeof(NV2AMetalVertex),
                           cpf_class(g), &u, textures, t, state, &error);
            pm_commands = nil;
            require(draw != nil, error);
            id<MTLRenderPipelineState> pipeline =
                [draw valueForKey:@"pipeline"];
            assert(pipeline);
            if (!pass)
                [soloPipelines addObject:pipeline];
            else
                assert(pipeline == soloPipelines[binding]);
            pm_emit(q, shader, @[ draw ], t);
            ProjectionModeImage *image = pm_image(q, t);
            pm_golden(image, scene, entry, 1, NO, alphaWitness);
            if (!first)
                first = image;
            else
                assert([first.pixels isEqualToData:image.pixels] &&
                       first.query == image.query);
            pm_append(dump, image, shader.capturedConstants);
        }
        unsigned total = pm_psos[0] + pm_psos[1] + pm_psos[2];
        assert(total == 2 * expectedModes && pm_psos[entry] == total);
    }
    for (unsigned compact = 0; compact < 2; compact++)
        assert((soloPipelines[2 * compact] == soloPipelines[2 * compact + 1]) ==
               (expectedModes == 1));
    /* All four modes coexist in the shared-pass cache and packet bindings. */
    pm_begin(q);
    ProjectionModeTargets *t = pm_targets(q, entry);
    NSMutableArray<NV2AMetalPixelDraw *> *draws = [NSMutableArray new];
    [shader.capturedConstants removeAllObjects];
    [shader beginPreparationForPass:t.pass commands:q];
    pm_commands = q;
    @try {
        for (unsigned binding = 0; binding < 4; binding++) {
            NV2AMetalGeometryResult *g = geometries[binding / 2];
            NV2AMetalPixelTexture textures[4] = { 0 };
            NV2AMetalPixelUniforms u =
                pwc_uniforms(pm_case(scene, binding / 2), 32, textures);
            NV2AMetalPixelDraw *draw = pm_prepare(
                shader, q, g, binding & 1 ? g.polygonProjections : nil,
                g.vertexCount, g.firstVertex * sizeof(NV2AMetalVertex),
                cpf_class(g), &u, textures, t, state, &error);
            require(draw != nil, error);
            assert([draw valueForKey:@"pipeline"] == soloPipelines[binding]);
            [draws addObject:draw];
        }
    } @finally {
        pm_commands = nil;
        [shader endPreparation];
    }
    pm_emit(q, shader, draws, t);
    ProjectionModeImage *shared = pm_image(q, t);
    pm_golden(shared, scene, entry, 4, NO, alphaWitness);
    pm_append(dump, shared, shader.capturedConstants);
    if (!scene && !entry) {
        for (unsigned compact = 0; compact < 2; compact++) {
            pm_begin(q);
            ProjectionModeTargets *target = pm_targets(q, entry);
            NV2AMetalGeometryResult *g = geometries[compact];
            NV2AMetalPixelTexture textures[4] = { 0 };
            NV2AMetalPixelUniforms u =
                pwc_uniforms(pm_case(scene, compact), 32, textures);
            [shader.capturedConstants removeAllObjects];
            pm_commands = q;
            NV2AMetalPixelDraw *draw =
                pm_prepare(shader, q, g, zero, g.vertexCount,
                           g.firstVertex * sizeof(NV2AMetalVertex),
                           cpf_class(g), &u, textures, target, state, &error);
            pm_commands = nil;
            require(draw != nil, error);
            pm_emit(q, shader, @[ draw ], target);
            ProjectionModeImage *image = pm_image(q, target);
            pm_golden(image, scene, entry, 1, YES, nil);
            pm_append(dump, image, shader.capturedConstants);
        }
    }
    assert(pm_psos[0] + pm_psos[1] + pm_psos[2] == 2 * expectedModes);
    pm_compiler = nil;
    return first;
}

static void pm_boundaries(NV2AMetalCommands *q, NV2AMetalGeometry *engine,
                          NSMutableData *dump)
{
    NSError *error = nil;
    ProjectionModeShader *shader = [[ProjectionModeShader alloc]
        initWithDevice:q.device
           colorFormat:MTLPixelFormatRGBA32Float
           depthFormat:MTLPixelFormatDepth32Float_Stencil8
           sampleCount:1
                 error:&error];
    require(shader != nil, error);
    NV2AMetalDrawState *state = pm_state(q, 0);
    pm_begin(q);
    NV2AMetalGeometryResult *geometries[2];
    for (unsigned compact = 0; compact < 2; compact++)
        geometries[compact] = pwc_geometry(q, engine, pm_case(0, compact), 32);
    pm_finish(q);
    pm_compiler = [shader valueForKey:@"compiler"];
    memset(pm_psos, 0, sizeof(pm_psos));
    for (unsigned binding = 0; binding < 4; binding++) {
        pm_begin(q);
        ProjectionModeTargets *t = pm_targets(q, 0);
        pm_emit(q, shader, @[],
                t); // Real initialization, outside zero-work scope.
        NV2AMetalGeometryResult *g = geometries[binding / 2];
        NV2AMetalPixelTexture textures[4] = { 0 };
        NV2AMetalPixelUniforms u =
            pwc_uniforms(pm_case(0, binding / 2), 32, textures);
        pm_uploads = pm_encoders = 0;
        pm_commands = q;
        NV2AMetalPixelDraw *empty =
            pm_prepare(shader, q, g, binding & 1 ? g.polygonProjections : nil,
                       0, g.firstVertex * sizeof(NV2AMetalVertex), cpf_class(g),
                       &u, textures, t, state, &error);
        require(empty && !empty.vertexCount &&
                    [shader encodePrepared:empty
                                      pass:t.pass
                             renderEncoder:nil
                                  commands:q
                                     error:&error],
                error);
        pm_commands = nil;
        ProjectionModeImage *image = pm_image(q, t);
        pm_golden(image, 0, 0, 1, YES, nil);
        pm_append(dump, image, @[]);
        assert(!pm_uploads && !pm_encoders && !pm_psos[0]);
    }
    pm_begin(q);
    ProjectionModeTargets *t = pm_targets(q, 0);
    NV2AMetalGeometryResult *expanded = geometries[0], *compact = geometries[1];
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalPixelUniforms u = pwc_uniforms(pm_case(0, NO), 32, textures);
    id<MTLBuffer> shortProjection =
        [q.device newBufferWithLength:67 options:MTLResourceStorageModePrivate];
    pm_commands = q;
    pm_uploads = pm_encoders = 0;
    assert(!pm_prepare(shader, q, expanded, shortProjection, 6, 0,
                       cpf_class(expanded), &u, textures, t, state, &error) &&
           error);
    error = nil;
    assert(!pm_prepare(shader, q, compact, shortProjection, 6, 0,
                       cpf_class(compact), &u, textures, t, state, &error) &&
           error);
    error = nil;
    assert(!pm_prepare(shader, q, expanded, expanded.polygonProjections, 0,
                       sizeof(NV2AMetalVertex), cpf_class(expanded), &u,
                       textures, t, state, &error) &&
           error);
    error = nil;
    assert(!pm_prepare(shader, q, expanded, expanded.polygonProjections, 0, 0,
                       NV2AMetalPixelRasterNative, &u, textures, t, state,
                       &error) &&
           error);
    error = nil;
    u.depth_format = UINT32_MAX;
    assert(!pm_prepare(shader, q, compact, nil, 0, 0, cpf_class(compact), &u,
                       textures, t, state, &error) &&
           error);
    error = nil;
    u = pwc_uniforms(pm_case(1, NO), 32, textures);
    textures[0].texture = nil;
    assert(!pm_prepare(shader, q, expanded, nil, 0, 0, cpf_class(expanded), &u,
                       textures, t, state, &error) &&
           error);
    pm_commands = nil;
    assert(!pm_uploads && !pm_encoders && !pm_psos[0]);
    [q cancel];
    pm_begin(q);
    compact = pwc_geometry(q, engine, pm_case(0, YES), 32);
    id<MTLBuffer> original = compact.polygonProjections;
    [compact setValue:nil forKey:@"polygonProjections"];
    memset(textures, 0, sizeof(textures));
    u = pwc_uniforms(pm_case(0, YES), 32, textures);
    error = nil;
    assert(![shader prepareGeometry:compact
                             offset:0
                              count:compact.vertexCount
                           uniforms:&u
                           textures:textures
                               pass:t.pass
                          drawState:state
                        rasterClass:cpf_class(compact)
               ignorePolygonCulling:YES
                           commands:q
                              error:&error] &&
           error);
    [compact setValue:original forKey:@"polygonProjections"];
    [q cancel];
    pm_begin(q);
    NV2AMetalGeometryRasterConfig cfg = { .polygonSmooth = YES,
                                          .viewportWidth = 32,
                                          .viewportHeight = 32 };
    for (NSUInteger n = 0; n < 3; n++) {
        NSArray<NV2AMetalGeometryResult *> *empty =
            [engine encodeNativeRasterVertices:compact.vertices
                                         count:n
                                     primitive:NV2AMetalPrimitivePolygon
                                        config:&cfg
                                        smooth:YES
                                firstProvoking:NO
                                  zPerspective:NO
                                      commands:q
                                         error:&error];
        require(empty.count == 1, error);
        NV2AMetalGeometryResult *g = empty[0];
        assert(g.compactPolygons && !g.vertexCount && !g.polygonCoverage &&
               !g.polygonProjections);
        error = nil;
        assert(!pm_prepare(shader, q, g, nil, 0, 0, cpf_class(g), &u, textures,
                           t, state, &error) &&
               error);
    }
    [q cancel];
    pm_compiler = nil;
}

static void projection_mode_tests(unsigned expectedModes, const char *dumpPath)
{
    assert(expectedModes == 1 || expectedModes == 2);
    NSError *error = nil;
    NV2AMetalCommands *q = [[NV2AMetalCommands alloc] initWithError:&error];
    require(q != nil, error);
    NV2AMetalGeometry *engine =
        [[NV2AMetalGeometry alloc] initWithDevice:q.device error:&error];
    require(engine != nil, error);
    cpf_init_read(q.device);
    pwc_textures(q);
    pm_begin(q);
    Method native = class_getInstanceMethod(
        [[q.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                       error:&error] class],
        @selector(
            newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:));
    Method upload = class_getInstanceMethod(
        NV2AMetalCommands.class, @selector(uploadBytes:length:offset:error:));
    Method render =
        class_getInstanceMethod([q.commandBuffer class],
                                @selector(renderCommandEncoderWithDescriptor:));
    assert(native && upload && render);
    [q cancel];
    pm_native_original = (void *)method_getImplementation(native);
    pm_upload_original = (void *)method_getImplementation(upload);
    pm_render_original = (void *)method_getImplementation(render);
    method_setImplementation(native, (IMP)pm_native);
    method_setImplementation(upload, (IMP)pm_upload);
    method_setImplementation(render, (IMP)pm_render);
    NSMutableData *dump = [NSMutableData new];
    @try {
        ProjectionModeImage *normal =
            pm_group(q, engine, 0, 0, expectedModes, dump, nil);
        pm_group(q, engine, 1, 0, expectedModes, dump, nil);
        pm_group(q, engine, 0, 1, expectedModes, dump, nil);
        pm_group(q, engine, 0, 2, expectedModes, dump, normal);
        pm_boundaries(q, engine, dump);
        if (dumpPath) {
            require([dump writeToFile:@(dumpPath)
                              options:NSDataWritingAtomic
                                error:&error],
                    error);
        }
        printf(
            "Metal4 projection mode:4 binding groups+zero/invalid boundaries;"
            "whole color/depth/stencil/query/raw storage,shared packets,"
            "%u native PSO modes per class,warm0 PASS\n",
            expectedModes);
    } @finally {
        pm_compiler = nil;
        pm_commands = nil;
        pm_constants = NULL;
        method_setImplementation(native, (IMP)pm_native_original);
        method_setImplementation(upload, (IMP)pm_upload_original);
        method_setImplementation(render, (IMP)pm_render_original);
    }
}
#endif
