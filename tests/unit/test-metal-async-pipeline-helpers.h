/* Real Metal frames, raw storage and literal pixel oracles for the optional
 * pipeline compiler integration test.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ASYNC_PIPELINE_HELPERS_H
#define TEST_METAL_ASYNC_PIPELINE_HELPERS_H
#include <time.h>
#include "hw/xbox/nv2a/pgraph/metal/color-format.h"

@interface NV2AMetalPixelShader (GenericRenderProbe)
- (MTLGPUAddress)addressForConstants:(const SumFlagsProbeConstants *)constants
                            commands:(NV2AMetalCommands *)q
                               error:(NSError **)error;
- (NV2AMetalPixelDraw *)prepareVertices:(id<MTLBuffer>)vertices
                                 offset:(NSUInteger)offset
                                  count:(NSUInteger)count
                              primitive:(MTLPrimitiveType)primitive
                               uniforms:(const NV2AMetalPixelUniforms *)u
                               textures:(const NV2AMetalPixelTexture *)textures
                                   pass:(MTL4RenderPassDescriptor *)pass
                           depthStencil:(id<MTLDepthStencilState>)depthStencil
                              drawState:(NV2AMetalDrawState *)state
                            rasterClass:(NV2AMetalPixelRasterClass)raster
                     polygonProjections:(id<MTLBuffer>)projection
                          polygonFacing:(id<MTLBuffer>)facing
                         rasterCoverage:(id<MTLBuffer>)coverage
                   sourceVertexCapacity:(NSUInteger)capacity
                        indexedVertices:(NV2AMetalIndexedVertices *)indexed
                            indexOffset:(NSUInteger)indexOffset
                   ignorePolygonCulling:(BOOL)ignore
                               commands:(NV2AMetalCommands *)q
                                  error:(NSError **)error;
@end
@interface GenericRenderShader : NV2AMetalPixelShader
@property(nonatomic) NSData *expected, *storage;
@end
@implementation GenericRenderShader
- (MTLGPUAddress)addressForConstants:(const SumFlagsProbeConstants *)constants
                            commands:(NV2AMetalCommands *)q
                               error:(NSError **)error
{
    assert(_expected.length == sizeof(*constants) &&
           !memcmp(constants, _expected.bytes, sizeof(*constants)));
    _storage = [NSData dataWithBytes:constants length:sizeof(*constants)];
    return [super addressForConstants:constants commands:q error:error];
}
@end

typedef struct GenericRenderFrame {
    uint32_t pixels[64][6]; // RGBA32 bits, depth bits, stencil integer.
    uint64_t query;
} GenericRenderFrame;
_Static_assert(sizeof(GenericRenderFrame) == 64 * 24 + 8, "No frame padding");
@interface GenericRenderScene : NSObject {
@public
    NV2AMetalPixelUniforms u;
    NV2AMetalVertex vertices[6];
    NV2AMetalPixelTexture textures[4];
    float brdfExpected[4];
}
@property(nonatomic) NSMutableArray *owners;
@property(nonatomic) unsigned group, variant, entry, geometryMode, profile,
    flags;
@property(nonatomic) BOOL halfDepth;
@property(nonatomic) uint64_t expectedQuery;
@end
@implementation GenericRenderScene
@end

static double grp_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec + t.tv_nsec * 1e-9;
}
typedef id<MTLRenderPipelineState> (*GenericRenderNativePSO)(
    id, SEL, MTL4PipelineDescriptor *, MTL4CompilerTaskOptions *, NSError **)
    __attribute__((ns_returns_retained));
static GenericRenderNativePSO grp_native_original;
static _Thread_local __unsafe_unretained id<MTL4Compiler> grp_compiler;
static _Thread_local const SumFlagsProbeConstants *grp_expected;
static _Thread_local unsigned grp_requests, grp_uploads;
static _Thread_local BOOL grp_guard_upload_scope;
static _Thread_local double grp_request_seconds;
static id<MTLRenderPipelineState> grp_native(id, SEL, MTL4PipelineDescriptor *,
                                             MTL4CompilerTaskOptions *,
                                             NSError **)
    __attribute__((ns_returns_retained));
static id<MTLRenderPipelineState> grp_native(id owner, SEL selector,
                                             MTL4PipelineDescriptor *descriptor,
                                             MTL4CompilerTaskOptions *options,
                                             NSError **error)
{
    BOOL measured = owner == grp_compiler;
    double start = measured ? grp_clock() : 0;
    id<MTLRenderPipelineState> p =
        grp_native_original(owner, selector, descriptor, options, error);
    if (measured) {
        grp_requests++;
        grp_request_seconds += grp_clock() - start;
    }
    return p;
}
static id<MTLBuffer> (*grp_upload_original)(id, SEL, const void *, NSUInteger,
                                            NSUInteger *, NSError **);
static id<MTLBuffer> grp_upload(id owner, SEL selector, const void *bytes,
                                NSUInteger length, NSUInteger *offset,
                                NSError **error)
{
    BOOL uniform = grp_expected && owner == commands &&
                   length == sizeof(SumFlagsProbeConstants);
    BOOL observed = uniform || (grp_guard_upload_scope && owner == commands);
    if (observed) {
        if (uniform)
            assert(!memcmp(bytes, grp_expected, length));
        grp_uploads++;
    }
    id<MTLBuffer> result =
        grp_upload_original(owner, selector, bytes, length, offset, error);
    if (observed && result) {
        assert(*offset <= result.length && length <= result.length - *offset);
        assert(
            !memcmp((const uint8_t *)result.contents + *offset, bytes, length));
    }
    return result;
}
static id<MTLComputePipelineState> grp_reader;
static void grp_prepare_reader(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new];
    d.source = @"#include <metal_stdlib>\nusing namespace metal;\n"
                "kernel void grp_read(device uint*o[[buffer(0)]],"
                "texture2d<float,access::read>c[[texture(0)]],"
                "texture2d<float,access::read>z[[texture(1)]],"
                "texture2d<uint,access::read>s[[texture(2)]],"
                "uint i[[thread_position_in_grid]]){if(i>=64)return;"
                "uint2 p(i%8,i/8);uint4 v=as_type<uint4>(c.read(p));"
                "o[6*i]=v.x;o[6*i+1]=v.y;o[6*i+2]=v.z;o[6*i+3]=v.w;"
                "o[6*i+4]=as_type<uint>(z.read(p).x);o[6*i+5]=s.read(p).x;}";
    d.options = [MTLCompileOptions new];
    d.options.languageVersion = MTLLanguageVersion4_0;
    d.options.mathMode = MTLMathModeSafe;
    d.options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:d error:&error];
    require(library != nil, error);
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = library;
    function.name = @"grp_read";
    MTL4ComputePipelineDescriptor *pipeline =
        [MTL4ComputePipelineDescriptor new];
    pipeline.computeFunctionDescriptor = function;
    grp_reader = [compiler newComputePipelineStateWithDescriptor:pipeline
                                             compilerTaskOptions:nil
                                                           error:&error];
    require(grp_reader != nil, error);
}
static id<MTLBuffer> grp_read(id<MTLTexture> colorTarget, id<MTLTexture> zeta)
{
    NSError *error = nil;
    id<MTLTexture> stencil =
        [zeta newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:64 * 24
                                     options:MTLResourceStorageModeShared];
    require(stencil && output, nil);
    for (id resource in @[ colorTarget, zeta, stencil, output ])
        require([commands addResource:resource error:&error], error);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.maxTextureBindCount = 3;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> a =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(a && [commands keepAlive:a error:&error] &&
                [commands keepAlive:grp_reader error:&error],
            error);
    [a setAddress:output.gpuAddress atIndex:0];
    [a setTexture:colorTarget.gpuResourceID atIndex:0];
    [a setTexture:zeta.gpuResourceID atIndex:1];
    [a setTexture:stencil.gpuResourceID atIndex:2];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setArgumentTable:a];
    [e setComputePipelineState:grp_reader];
    [e dispatchThreads:MTLSizeMake(64, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return output;
}
static void grp_texture(GenericRenderScene *scene, unsigned stage,
                        id<MTLTexture> __strong texture)
{
    assert(stage < 4 && texture);
    /* The public binding field is unsafe: retain the +0 helper result before
     * storing its borrowed address, within the same full expression. */
    [scene.owners addObject:texture];
    scene->textures[stage].texture = texture;
}
static GenericRenderScene *grp_scene(unsigned group, unsigned variant)
{
    GenericRenderScene *s = [GenericRenderScene new];
    s.group = group;
    s.variant = variant;
    s.expectedQuery = 64;
    s.owners = [NSMutableArray new];
    s->u = uniforms();
    quad(s->vertices);
    for (unsigned i = 0; i < 6; i++) {
        const float front[] = { .125f, .25f, .375f, .75f },
                    specular[] = { .5f, .75f, .25f, .5f };
        memcpy(s->vertices[i].color[0], front, sizeof(front));
        memcpy(s->vertices[i].color[1], specular, sizeof(specular));
    }
    if (group < 2) {
        const unsigned profiles[2][4] = {
            { SFPNoSUM0, SFPNoSUM8, SFPRGBSUM, SFPLastRGBSUM },
            { SFPRGBSUM, SFPAlphaBlueSUM, SFPFinalA, SFPFinalG }
        };
        const unsigned flags[4] = { 0, 3, 5, 7 };
        s.profile = profiles[group][variant];
        s.flags = group ? flags[variant] : 0;
        s->u = sfp_state(s.profile, s.flags);
        /* Native Tag0 quad; match the old literal SUM fixture's depth. */
        for (unsigned i = 0; i < 6; i++)
            for (unsigned k = 0; k < 3; k++)
                s->vertices[i].plane[k][2] = 16384.75f;
        grp_texture(s, 0, solid(.125f, .25f, .375f, .5f));
    } else if (group == 2) {
        const uint32_t bits[3][4] = { { 0x80000000, 0, 1, 0x80000000 },
                                      { 0x7fc12345, 0xff800000, 0x7f800000, 0 },
                                      { 0x7fa54321, 0, 0x80000000,
                                        0x7fc54321 } };
        if (variant < 3) {
            for (unsigned i = 0; i < 6; i++)
                memcpy(s->vertices[i].color[0], bits[variant],
                       sizeof(bits[variant]));
            if (variant == 1) {
                float value[4];
                memcpy(value, bits[variant], sizeof(value));
                grp_texture(
                    s, 0,
                    stf_texture(0, 1, 1, MTLPixelFormatRGBA32Float, 0, value));
                texture_mode(&s->u, 0, PS_TEXTUREMODES_PROJECT2D);
                show_texture(&s->u, 0);
                s->u.textures[0].sampling.min_linear = 1;
                s->u.textures[0].sampling.mag_linear = 1;
                coord(s->vertices, 0, .5f, .5f, 0, 1);
            } else if (variant == 2) {
                texture_mode(&s->u, 0, PS_TEXTUREMODES_PASSTHRU);
                for (unsigned i = 0; i < 6; i++)
                    memcpy(s->vertices[i].texcoord[0], bits[variant],
                           sizeof(bits[variant]));
                show_texture(&s->u, 0);
            }
        } else {
            s->u = sfp_state(SFPInactiveSUMGarbage, 7);
            grp_texture(s, 0, solid(.125f, .25f, .375f, .5f));
        }
        assert(!s->u.alpha_test);
    } else if (group == 3) {
        const uint32_t eyeWords[] = { 0x1289e237, 0x0102ff00, 0x30001000,
                                      0x55aa3322 },
                       lightWords[] = { 0xabe36519, 0xfefd00ff, 0xd0007000,
                                        0xaa557766 };
        unsigned stage = 2 + (variant & 1);
        BOOL hilo = variant >= 2, cubemap = variant & 1, linear = variant & 1;
        if (stage == 3) {
            texture_mode(&s->u, 0, PS_TEXTUREMODES_PASSTHRU);
            coord(s->vertices, 0, 1, 0, 1, 0);
        }
        for (unsigned source = stage - 2; source < stage; source++) {
            texture_mode(&s->u, source,
                         cubemap ? PS_TEXTUREMODES_CUBEMAP :
                                   PS_TEXTUREMODES_PROJECT2D);
            s->u.textures[source].cubemap = cubemap;
            coord(s->vertices, source, 1, .25f, -.5f, 1);
            grp_texture(s, source,
                        brdf_angles(source == stage - 2 ? eyeWords[variant] :
                                                          lightWords[variant],
                                    cubemap, hilo));
        }
        s->u.hilo16_mask = hilo ? 3u << (stage - 2) : 0;
        texture_mode(&s->u, stage, PS_TEXTUREMODES_BRDF);
        s->u.textures[stage].dimension = 3;
        s->u.textures[stage].sampling.min_linear = linear;
        s->u.textures[stage].sampling.mag_linear = linear;
        grp_texture(s, stage, brdf_lookup(NO));
        show_texture(&s->u, stage);
        brdf_reference(eyeWords[variant], lightWords[variant], linear, 3, NO,
                       s->brdfExpected);
    } else if (group == 4) {
        s->u.hilo16_mask = 1;
        texture_mode(&s->u, 0, PS_TEXTUREMODES_PROJECT2D);
        if (variant < 2) {
            grp_texture(
                s, 0, brdf_angles(variant ? 0xabe36519 : 0x1289e237, NO, YES));
            texture_mode(&s->u, 1, PS_TEXTUREMODES_DOTPRODUCT);
            texture_mode(&s->u, 2, PS_TEXTUREMODES_DOT_ST);
            s->u.other_stage_input = variant ? 3 | 3 << 4 : 0;
            coord(s->vertices, 1, .25f, .5f, .125f, 1);
            coord(s->vertices, 2, .5f, .25f, .0625f, 1);
            grp_texture(s, 2, gradient(4));
            s->u.textures[2].sampling.min_linear = 1;
            s->u.textures[2].sampling.mag_linear = 1;
            show_texture(&s->u, 2);
        } else {
            grp_texture(s, 0,
                        solid(variant == 2 ? 32767.f / 32768 : -1.f / 32768,
                              variant == 2 ? -1 : 1.f / 32768, .25f, 1));
            s->u.textures[0].signed_channels = 15;
            texture_mode(&s->u, 1,
                         variant == 2 ? PS_TEXTUREMODES_DPNDNT_AR :
                                        PS_TEXTUREMODES_DPNDNT_GB);
            grp_texture(s, 1, gradient(16));
            s->u.textures[1].sampling.min_linear = 1;
            s->u.textures[1].sampling.mag_linear = 1;
            show_texture(&s->u, 1);
        }
    } else if (group == 5) {
        texture_mode(&s->u, 0, PS_TEXTUREMODES_PROJECT2D);
        texture_mode(&s->u, 1, PS_TEXTUREMODES_DPNDNT_AR);
        show_texture(&s->u, 1);
        for (unsigned stage = 0; stage < 2; stage++) {
            s->u.textures[stage].sampling.min_linear = 1;
            s->u.textures[stage].sampling.mag_linear = 1;
        }
        s->u.textures[1].sampling.mip_filter = 2;
        s->u.textures[1].sampling.lod_bias = 1.5f;
        s->u.textures[1].sampling.anisotropy = variant & 1 ? 4 : 1;
        s->u.clip_regions[0][0] = 1;
        s->u.clip_regions[0][2] = 5;
        s.expectedQuery = 32;
        for (unsigned i = 0; i < 6; i++) {
            float x = (s->vertices[i].clip[0] + 1) * 4;
            s->vertices[i].texcoord[0][0] =
                variant < 2 ? -.25f + x / 8 : 2 * (x - 3.5f) + .25f;
            s->vertices[i].texcoord[0][1] = -.125f;
        }
        grp_texture(s, 0,
                    stf_texture(0, variant < 2 ? 4 : 8, 1,
                                MTLPixelFormatRGBA32Float, 0, NULL));
        grp_texture(s, 1,
                    stf_texture(0, 16, 5, MTLPixelFormatRGBA32Float, 1, NULL));
        assert(s->textures[1].texture.mipmapLevelCount == 5);
    } else if (group == 6) {
        if (variant == 0) {
            texture_mode(&s->u, 0, PS_TEXTUREMODES_PROJECT2D);
            show_texture(&s->u, 0);
            s->u.textures[0].alphakill = 1;
            grp_texture(s, 0, solid(.25f, .5f, .75f, 0));
            s.expectedQuery = 0;
        } else if (variant == 1) {
            s.halfDepth = YES;
            s->u.alpha_test = 1;
            s->u.alpha_func = ALPHA_FUNC_GREATER;
            s->u.alpha_ref = 63;
            s.expectedQuery = 32;
        } else {
            s.entry = variant == 2 ? 1 : 2;
            for (unsigned i = 0; i < 6; i++) {
                const float rgba[] = { .25f, .5f, .75f, .75f };
                memcpy(s->vertices[i].color[0], rgba, sizeof(rgba));
            }
        }
    } else {
        assert(group == 7);
        s.geometryMode = variant < 2 ? 1 : 2;
        s->u = sfp_state(SFPNoSUM0, 0);
        grp_texture(s, 0, solid(.125f, .25f, .375f, .5f));
    }
    return s;
}

static NV2AMetalDrawState *grp_state(unsigned entry)
{
    NV2AMetalDrawConfig c = { 0 };
    c.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_ZENABLE |
                   NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                   NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE |
                   1 << 16; // LESS; half-depth fixture independently suppresses
                            // left pixels.
    c.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 |
                   0x13 << 8 | 0xff << 16 | 0xffu << 24;
    c.control[2] = 1 | 1 << 4 | 3 << 8;
    if (entry == 1)
        c.control[0] |= NV_PGRAPH_CONTROL_0_DITHERENABLE;
    if (entry == 2)
        c.blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12;
    NSError *error = nil;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&c
                                             error:&error];
    require(state != nil, error);
    return state;
}
static id<MTLTexture> grp_target(MTLPixelFormat format)
{
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
              MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:d];
    assert(t);
    return t;
}
static void grp_depth_seed(id<MTLTexture> zeta)
{
    NSError *error = nil;
    float values[8][64] = { 0 };
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 4; x < 8; x++)
            values[y][x] = .99f;
    id<MTLBuffer> seed =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    require(seed && [commands addResource:seed error:&error] &&
                [commands addResource:zeta error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:seed
               sourceOffset:0
          sourceBytesPerRow:256
        sourceBytesPerImage:0
                 sourceSize:MTLSizeMake(8, 8, 1)
                  toTexture:zeta
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)
                    options:MTLBlitOptionDepthFromDepthStencil];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
static GenericRenderFrame grp_render(GenericRenderShader *pixel,
                                     NV2AMetalGeometry *engine,
                                     GenericRenderScene *s, NSData **storage)
{
    NSError *error = nil;
    NSData *original = [NSData dataWithBytes:&s->u length:sizeof(s->u)];
    NV2AMetalDrawState *state = grp_state(s.entry);
    id<MTLTexture> colorTarget = grp_target(
        s.entry ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA32Float);
    id<MTLTexture> zeta = grp_target(MTLPixelFormatDepth32Float_Stencil8);
    id<MTLBuffer> query =
        [commands.device newBufferWithLength:8
                                     options:MTLResourceStorageModeShared];
    assert(query);
    memset(query.contents, 0, 8);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = colorTarget;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 0);
    p.depthAttachment.texture = zeta;
    p.depthAttachment.loadAction =
        s.halfDepth ? MTLLoadActionLoad : MTLLoadActionClear;
    p.depthAttachment.storeAction = MTLStoreActionStore;
    p.depthAttachment.clearDepth = .99;
    p.stencilAttachment.texture = zeta;
    p.stencilAttachment.loadAction = MTLLoadActionClear;
    p.stencilAttachment.storeAction = MTLStoreActionStore;
    p.stencilAttachment.clearStencil = 0x11;
    p.visibilityResultBuffer = query;
    p.visibilityResultType = MTLVisibilityResultTypeReset;
    require([commands beginWithError:&error] != nil, error);
    if (s.halfDepth)
        grp_depth_seed(zeta);
    NV2AMetalGeometryResult *g =
        s.geometryMode ? sfp_geometry(engine, s.geometryMode == 2) : nil;
    id<MTLBuffer> source =
        g ? g.vertices :
            [commands.device newBufferWithBytes:s->vertices
                                         length:sizeof(s->vertices)
                                        options:MTLResourceStorageModeShared];
    assert(source);
    BOOL projection = g && (s.group != 7 || (s.variant & 1));
    SumFlagsProbeConstants expected = { .uniforms = s->u };
    expected.uniforms.vertex_capacity = 6;
    expected.uniforms.point_sprite = 0;
    expected.uniforms.logic_op =
        state.logicEnabled ? state.logicOperation + 1 : 0;
    expected.uniforms.dither = state.ditherEnabled;
    expected.uniforms.blend = state.blendWord;
    nv2a_metal_color_bits(colorTarget.pixelFormat,
                          expected.uniforms.color_bits);
    expected.info.polygon_projection_count = projection ? 1 : 0;
    expected.info.source_vertex_count =
        s.geometryMode == 2 ? (unsigned)g.physicalVertexCount : 0;
    pixel.expected = [NSData dataWithBytes:&expected length:sizeof(expected)];
    grp_expected = &expected;
    NV2AMetalPixelDraw *draw;
    @try {
        draw = [pixel
                 prepareVertices:source
                          offset:g ? g.firstVertex * sizeof(NV2AMetalVertex) : 0
                           count:6
                       primitive:MTLPrimitiveTypeTriangle
                        uniforms:&s->u
                        textures:s->textures
                            pass:p
                    depthStencil:state.depthStencil
                       drawState:state
                     rasterClass:s.geometryMode == 2 ?
                                     NV2AMetalPixelRasterCompactPolygon :
                                 s.geometryMode == 1 ?
                                     NV2AMetalPixelRasterExpandedPolygon :
                                     NV2AMetalPixelRasterNative
              polygonProjections:projection ? g.polygonProjections : nil
                   polygonFacing:nil
                  rasterCoverage:s.geometryMode == 2 ? g.polygonCoverage : nil
            sourceVertexCapacity:s.geometryMode == 2 ? g.physicalVertexCount : 0
                 indexedVertices:g.indexedVertices
                     indexOffset:g.indexOffset
            ignorePolygonCulling:YES
                        commands:commands
                           error:&error];
    } @finally {
        grp_expected = NULL;
        pixel.expected = nil;
    }
    require(draw != nil, error);
    assert(pixel.storage.length == sizeof(expected));
    *storage = pixel.storage;
    for (id resource in @[ colorTarget, zeta, query ])
        require([commands addResource:resource error:&error], error);
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:nv2a_metal_pixel_pass_stages()
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    require([draw encodeWithRenderEncoder:e commands:commands error:&error],
            error);
    [e barrierAfterStages:nv2a_metal_pixel_pass_stages()
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    id<MTLBuffer> read = grp_read(colorTarget, zeta);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    NSError *feedbackError = nil;
    require([commands.lastSubmitted completedWithError:&feedbackError] &&
                !feedbackError,
            feedbackError);
    GenericRenderFrame frame = { 0 };
    memcpy(frame.pixels, read.contents, sizeof(frame.pixels));
    memcpy(&frame.query, query.contents, sizeof(frame.query));
    assert(!memcmp(original.bytes, &s->u, sizeof(s->u)));
    return frame;
}

static void grp_golden(GenericRenderFrame *frame, GenericRenderScene *s)
{
    assert(frame->query == s.expectedQuery);
    SumFlagsProbeImage literal = { 0 };
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            NSUInteger i = y * 8 + x;
            float rgba[4], z;
            memcpy(rgba, frame->pixels[i], sizeof(rgba));
            memcpy(&z, frame->pixels[i] + 4, sizeof(z));
            BOOL survives = s.expectedQuery != 0 &&
                            !(s.group == 5 && (x < 1 || x >= 5)) &&
                            !(s.halfDepth && x < 4);
            assert(frame->pixels[i][5] == (survives ? 0x13u : 0x11u));
            float expectedDepth =
                survives ? (s.geometryMode || s.group < 2 ? 16384.f / 65535 :
                                                            2.f / 65535) :
                s.halfDepth && x < 4 ? 0 :
                                       .99f;
            assert(z == expectedDepth);
            if (!survives) {
                const float clear[4] = { 0, 0, 1, 0 };
                assert(!memcmp(rgba, clear, sizeof(clear)));
            }
            memcpy(literal.gpu.color[y][x], rgba, sizeof(rgba));
            literal.gpu.depth[y][x] = z;
            if (s.group == 3)
                for (unsigned k = 0; k < 4; k++)
                    assert(isfinite(rgba[k]) &&
                           fabsf(rgba[k] - s->brdfExpected[k]) < .000015f);
            if (s.group == 5 && s.variant == 0 && survives) {
                const float red[] = { .125f, .125f, .1875f, .1875f, .3125f };
                const float expected[4] = { red[x], .25f, .375f, .75f };
                for (unsigned k = 0; k < 4; k++)
                    assert(isfinite(rgba[k]) &&
                           fabsf(rgba[k] - expected[k]) < .000015f);
            }
            if (s.group == 6 && s.entry == 2) {
                const float expected[4] = { 63.f / 255, 127.f / 255, 64.f / 255,
                                            191.f / 255 };
                for (unsigned k = 0; k < 4; k++)
                    assert(fabsf(rgba[k] - expected[k]) < .00001f);
            }
            if (s.group == 7)
                for (unsigned k = 0; k < 4; k++) {
                    const float expected[] = { .125f, .25f, .375f, .5f };
                    assert(fabsf(rgba[k] - expected[k]) < .00003f);
                }
        }
    literal.gpu.samples = frame->query;
    if (s.group < 2)
        sfp_golden(&literal, s.profile, s.flags);
}
#endif
