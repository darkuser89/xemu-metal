/* Native polygon window-work gate: full old-source and physical-query oracle.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_WINDOW_CLIP_H
#define TEST_METAL_POLYGON_WINDOW_CLIP_H
#include "test-metal-polygon-window-reference.h"

typedef struct {
    unsigned window, material, scale, samples;
    BOOL flat, reverse, extremes, compact, sourceProbe, anisotropic,
        wideFootprint;
    unsigned sourceAF, dependentAF;
    float lodBias;
} PolygonWindowCase;
@interface PolygonWindowImage : NSObject
@property(nonatomic) NSData *bytes;
@property(nonatomic) uint64_t query;
@end
@implementation PolygonWindowImage
@end
@interface PolygonWindowTargets : NSObject
@property(nonatomic) id<MTLTexture> color, depth;
@property(nonatomic) id<MTLBuffer> query;
@property(nonatomic) MTL4RenderPassDescriptor *pass;
@end
@implementation PolygonWindowTargets
@end

static id<MTLLibrary> pwc_libraries[4];
static id<MTLComputePipelineState> pwc_read_pipelines[2];
static id<MTLTexture> pwc_source, pwc_mips;
static id<MTLLibrary> pwc_library(NV2AMetalCommands *q, unsigned variant)
{
    if (pwc_libraries[variant])
        return pwc_libraries[variant];
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [q.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                      error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new];
    d.source = polygon_window_source(@(pq_pixel_source), variant);
    d.options = [MTLCompileOptions new];
    d.options.languageVersion = MTLLanguageVersion4_0;
    d.options.mathMode = MTLMathModeSafe;
    d.options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
    pwc_libraries[variant] = [compiler newLibraryWithDescriptor:d error:&error];
    require(pwc_libraries[variant] != nil, error);
    return pwc_libraries[variant];
}
static NV2AMetalPixelShader *pwc_shader(NV2AMetalCommands *q, unsigned variant,
                                        unsigned samples)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:q.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatDepth32Float
                                         sampleCount:samples
                                               error:&error];
    require(shader != nil, error);
    [shader setValue:pwc_library(q, variant) forKey:@"library"];
    return shader;
}
static void pwc_textures(NV2AMetalCommands *q)
{
    if (pwc_source)
        return;
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4
                                    height:4
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    pwc_source = [q.device newTextureWithDescriptor:d];
    assert(pwc_source);
    float values[4][4][4];
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++) {
            values[y][x][0] = (x + 1) / 8.f;
            values[y][x][1] = (y + 1) / 8.f;
            values[y][x][2] = .0625f;
            values[y][x][3] = .75f;
        }
    [pwc_source replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                  mipmapLevel:0
                    withBytes:values
                  bytesPerRow:sizeof(values[0])];
    d.width = d.height = 16;
    d.mipmapLevelCount = 5;
    pwc_mips = [q.device newTextureWithDescriptor:d];
    assert(pwc_mips);
    for (unsigned level = 0; level < 5; level++) {
        unsigned size = 16 >> level;
        float mip[16 * 16][4];
        for (unsigned i = 0; i < size * size; i++) {
            mip[i][0] = (level + 1) / 8.f;
            mip[i][1] = .25f;
            mip[i][2] = .375f;
            mip[i][3] = .75f;
        }
        [pwc_mips replaceRegion:MTLRegionMake2D(0, 0, size, size)
                    mipmapLevel:level
                      withBytes:mip
                    bytesPerRow:size * 16];
    }
}
static void pwc_regions(NV2AMetalPixelUniforms *u, unsigned profile,
                        unsigned size)
{
    memset(u->clip_regions, 0, sizeof(u->clip_regions));
    u->window_clip_exclusive = profile == 2 || profile == 4 || profile == 7;
    const int bounds[9][8] = { { 0, 0, 32, 32 },
                               { 0 },
                               { 0 },
                               { 3, 5, 29, 27 },
                               { 3, 5, 29, 27 },
                               { 1, 3, 11, 19, 7, 5, 25, 27 },
                               { 3, 5, 9, 11, 19, 17, 29, 27 },
                               { 0, 0, 32, 32 },
                               { 15, 0, 17, 32 } };
    for (unsigned r = 0; r < 2; r++)
        for (unsigned k = 0; k < 4; k++)
            u->clip_regions[r][k] = bounds[profile][4 * r + k] * (int)size / 32;
}
static BOOL pwc_visible(const NV2AMetalPixelUniforms *u, unsigned x, unsigned y)
{
    BOOL contained = NO;
    for (unsigned r = 0; r < 8; r++)
        contained |= (int)x >= u->clip_regions[r][0] &&
                     (int)y >= u->clip_regions[r][1] &&
                     (int)x < u->clip_regions[r][2] &&
                     (int)y < u->clip_regions[r][3];
    return contained != !!u->window_clip_exclusive;
}
static NV2AMetalPixelUniforms pwc_uniforms(PolygonWindowCase c, unsigned size,
                                           NV2AMetalPixelTexture *textures)
{
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 65535, 0, 65535 },
                                 .surface_scale = { c.scale, c.scale },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .smooth_shading = !c.flat,
                                 .two_side = 1 };
    pwc_regions(&u, c.window, size);
    u.combiner.final_inputs[0] =
        c.material ? (c.sourceProbe ? PS_REGISTER_T0 : PS_REGISTER_T1) :
                     PS_REGISTER_V0;
    u.combiner.final_inputs[1] =
        ((c.material ? (c.sourceProbe ? PS_REGISTER_T0 : PS_REGISTER_T1) :
                       PS_REGISTER_V0) |
         PS_CHANNEL_ALPHA)
        << 8;
    if (c.material) {
        u.combiner.shader_stage_program =
            PS_TEXTUREMODES_PROJECT2D | PS_TEXTUREMODES_DPNDNT_AR << 5;
        textures[0].texture = pwc_source;
        textures[1].texture = pwc_mips;
        for (unsigned i = 0; i < 2; i++) {
            u.textures[i].dimension = 2;
            u.textures[i].scale = 1;
            u.textures[i].sampling =
                (NV2AMetalSamplingUniforms){ .enabled = 1,
                                             .address = { 3, 3, 3 },
                                             .min_linear = 1,
                                             .mag_linear = 1,
                                             .anisotropy =
                                                 c.anisotropic ? 4 : 1 };
        }
        if (c.sourceAF)
            u.textures[0].sampling.anisotropy = c.sourceAF;
        if (c.dependentAF)
            u.textures[1].sampling.anisotropy = c.dependentAF;
        u.textures[1].sampling.mip_filter = 2;
        u.textures[1].sampling.lod_bias = c.lodBias ? c.lodBias : 1.5f;
    }
    return u;
}
static NV2AMetalGeometryResult *pwc_geometry(NV2AMetalCommands *q,
                                             NV2AMetalGeometry *engine,
                                             PolygonWindowCase c, unsigned size)
{
    NSError *error = nil;
    /* A single polygon covers every viewport pixel, including helper lanes
     * outside odd window edges. Its binary affine T0 crosses clamp at x2/3. */
    const float xy[3][2] = { { -32, -32 }, { 96, -32 }, { -32, 96 } };
    NV2AMetalVertex v[3] = { 0 };
    for (unsigned i = 0; i < 3; i++) {
        unsigned k = c.reverse && i ? 3 - i : i;
        float x = xy[k][0], y = xy[k][1];
        v[i].clip[0] = x / 16 - 1;
        v[i].clip[1] = 1 - y / 16;
        v[i].clip[2] = .25f;
        v[i].clip[3] = 1;
        v[i].screen[0] = x * c.scale;
        v[i].screen[1] = y * c.scale;
        v[i].screen[2] = 16384;
        v[i].screen[3] = 1;
        const float front[4] = { .25f, .5f, .75f, 1 },
                    back[4] = { .75f, .25f, .5f, 1 };
        const float flatColors[3][4] = { { .25f, .5f, .75f, 1 },
                                         { .5f, .25f, .125f, 1 },
                                         { .75f, .125f, .25f, 1 } };
        const float *selected = c.flat ? flatColors[i] : front;
        memcpy(v[i].color[0], selected, sizeof(front));
        memcpy(v[i].color[2], c.reverse ? back : selected, sizeof(back));
        /* The focused AF witness has a physical du/dx=2 at every
         * viewport size. Keep the original cold/partial-quad probes intact. */
        v[i].texcoord[0][0] =
            c.wideFootprint ? 2 * (x * size / 32 - (size / 2.f - .5f)) + .25f :
                              -.25f + x / 8;
        v[i].texcoord[0][1] = -.125f;
        v[i].texcoord[0][3] = 1;
        if (c.extremes) {
            const uint32_t raw[4] = { 0x7fc12345, 0x7f800000, 0xff800000,
                                      0x80000000 };
            memcpy(v[i].texcoord[3], raw, sizeof(raw));
        }
    }
    id<MTLBuffer> source =
        [q.device newBufferWithBytes:v
                              length:sizeof(v)
                             options:MTLResourceStorageModeShared];
    assert(source);
    /* Clip-XY reverses screen Y: normal order has negative area, and
     * the reversed control must select the distinct back colors. */
    NV2AMetalGeometryRasterConfig cfg = { .frontClockwise = YES,
                                          .polygonSmooth = YES,
                                          .viewportWidth = size,
                                          .viewportHeight = size };
    NSArray *results;
    if (c.compact) {
        NV2AMetalVertexStream *stream =
            [[NV2AMetalVertexStream alloc] initWithDevice:q.device
                                                    limit:3
                                                    error:&error];
        require(stream && [stream appendVertices:source
                                           first:0
                                           count:3
                                           error:&error],
                error);
        NV2AMetalVertexSlice *slice =
            [stream encodeSliceForDrawingWithCommands:q error:&error];
        require(slice != nil, error);
        results = [engine encodeNativeRasterSlice:slice
                                        primitive:NV2AMetalPrimitiveTriangles
                                           config:&cfg
                                           smooth:!c.flat
                                   firstProvoking:YES
                                     zPerspective:NO
                                         commands:q
                                            error:&error];
    } else {
        results = [engine encodeRasterVertices:source
                                         count:3
                                     primitive:NV2AMetalPrimitiveTriangles
                                        config:&cfg
                                        smooth:!c.flat
                                firstProvoking:YES
                                  zPerspective:NO
                                      commands:q
                                         error:&error];
    }
    require(results.count == 1, error);
    NV2AMetalGeometryResult *g = results[0];
    assert(g.compactPolygons || g.expandedPolygons);
    return g;
}
static PolygonWindowTargets *pwc_targets(NV2AMetalCommands *q, unsigned size,
                                         unsigned samples)
{
    PolygonWindowTargets *t = [PolygonWindowTargets new];
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (samples > 1) {
        d.textureType = MTLTextureType2DMultisample;
        d.sampleCount = samples;
    }
    t.color = [q.device newTextureWithDescriptor:d];
    d.pixelFormat = MTLPixelFormatDepth32Float;
    t.depth = [q.device newTextureWithDescriptor:d];
    t.query = [q.device newBufferWithLength:8
                                    options:MTLResourceStorageModeShared];
    assert(t.color && t.depth && t.query);
    memset(t.query.contents, 0, 8);
    return t;
}
static NV2AMetalPixelDraw *pwc_prepare(NV2AMetalCommands *q,
                                       NV2AMetalPixelShader *shader,
                                       NV2AMetalGeometryResult *g,
                                       PolygonWindowCase c,
                                       PolygonWindowTargets *t)
{
    NSError *error = nil;
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalPixelUniforms u =
        pwc_uniforms(c, (unsigned)t.color.width, textures);
    NV2AMetalDrawConfig dc = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ZENABLE |
                     NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16 }
    };
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:q.device
                                            config:&dc
                                             error:&error];
    require(state != nil, error);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = t.color;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 0);
    p.depthAttachment.texture = t.depth;
    p.depthAttachment.loadAction = MTLLoadActionClear;
    p.depthAttachment.storeAction = MTLStoreActionStore;
    p.depthAttachment.clearDepth = 1;
    p.visibilityResultBuffer = t.query;
    p.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    t.pass = p;
    require([q addResource:t.query error:&error], error);
    NV2AMetalPixelDraw *draw = [shader prepareGeometry:g
                                                offset:0
                                                 count:g.vertexCount
                                              uniforms:&u
                                              textures:textures
                                                  pass:p
                                             drawState:state
                                           rasterClass:cpf_class(g)
                                  ignorePolygonCulling:YES
                                              commands:q
                                                 error:&error];
    require(draw != nil, error);
    return draw;
}
static id<MTLBuffer> pwc_read(NV2AMetalCommands *q, PolygonWindowTargets *t)
{
    NSError *error = nil;
    unsigned ms = t.color.sampleCount > 1;
    if (!pwc_read_pipelines[ms]) {
        id<MTL4Compiler> compiler =
            [q.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                          error:&error];
        require(compiler != nil, error);
        MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new];
        d.source =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void pwc_read(texture2d<float> c "
             "[[texture(0)]],texture2d<float> z [[texture(1)]],device uint *o "
             "[[buffer(0)]],uint i [[thread_position_in_grid]]) { uint "
             "n=c.get_width()*c.get_height();if(i>=n)return;uint2 "
             "p(i%c.get_width(),i/c.get_width());uint4 "
             "v=as_type<uint4>(c.read(p));o[5*i]=v.x;o[5*i+1]=v.y;o[5*i+2]=v.z;"
             "o[5*i+3]=v.w;o[5*i+4]=as_type<uint>(z.read(p).x);}\n"
             "kernel void pwc_read_ms(texture2d_ms<float> c "
             "[[texture(0)]],texture2d_ms<float> z [[texture(1)]],device uint "
             "*o [[buffer(0)]],uint i [[thread_position_in_grid]]) { uint "
             "s=c.get_num_samples(),n=c.get_width()*c.get_height()*s;if(i>=n)"
             "return;uint j=i/s;uint2 p(j%c.get_width(),j/c.get_width());uint4 "
             "v=as_type<uint4>(c.read(p,i%s));o[5*i]=v.x;o[5*i+1]=v.y;o[5*i+2]="
             "v.z;o[5*i+3]=v.w;o[5*i+4]=as_type<uint>(z.read(p,i%s).x);}\n";
        d.options = [MTLCompileOptions new];
        d.options.languageVersion = MTLLanguageVersion4_0;
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:d
                                                              error:&error];
        require(library != nil, error);
        MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new];
        f.library = library;
        f.name = ms ? @"pwc_read_ms" : @"pwc_read";
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = f;
        pwc_read_pipelines[ms] =
            [compiler newComputePipelineStateWithDescriptor:pd
                                        compilerTaskOptions:nil
                                                      error:&error];
        require(pwc_read_pipelines[ms] != nil, error);
    }
    NSUInteger count = t.color.width * t.color.height * t.color.sampleCount;
    id<MTLBuffer> out =
        [q.device newBufferWithLength:count * 20
                              options:MTLResourceStorageModeShared];
    assert(out);
    for (id r in @[ t.color, t.depth, out ])
        require([q addResource:r error:&error], error);
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 1;
    d.maxTextureBindCount = 2;
    d.initializeBindings = YES;
    id<MTL4ArgumentTable> a = [q.device newArgumentTableWithDescriptor:d
                                                                 error:&error];
    require(a && [q keepAlive:a error:&error] &&
                [q keepAlive:pwc_read_pipelines[ms] error:&error],
            error);
    [a setAddress:out.gpuAddress atIndex:0];
    [a setTexture:t.color.gpuResourceID atIndex:0];
    [a setTexture:t.depth.gpuResourceID atIndex:1];
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setArgumentTable:a];
    [e setComputePipelineState:pwc_read_pipelines[ms]];
    [e dispatchThreads:MTLSizeMake(count, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return out;
}
static void pwc_emit(NV2AMetalCommands *q, NV2AMetalPixelDraw *draw,
                     PolygonWindowTargets *t)
{
    NSError *error = nil;
    id<MTL4RenderCommandEncoder> e =
        [q.commandBuffer renderCommandEncoderWithDescriptor:t.pass];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    BOOL ok = [draw encodeWithRenderEncoder:e commands:q error:&error];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require(ok, error);
}
static PolygonWindowImage *pwc_render(NV2AMetalCommands *q,
                                      NV2AMetalGeometry *engine,
                                      NV2AMetalPixelShader *shader,
                                      PolygonWindowCase c)
{
    NSError *error = nil;
    require([q beginWithError:&error] != nil, error);
    pwc_textures(q);
    NV2AMetalGeometryResult *g = pwc_geometry(q, engine, c, 32 * c.scale);
    PolygonWindowTargets *t = pwc_targets(q, 32 * c.scale, c.samples);
    NV2AMetalPixelDraw *draw = pwc_prepare(q, shader, g, c, t);
    pwc_emit(q, draw, t);
    id<MTLBuffer> read = pwc_read(q, t);
    require([q submitWithError:&error] && [q waitUntilIdleWithError:&error],
            error);
    PolygonWindowImage *out = [PolygonWindowImage new];
    out.bytes = [NSData dataWithBytes:read.contents length:read.length];
    uint64_t query;
    memcpy(&query, t.query.contents, 8);
    out.query = query;
    return out;
}
static void pwc_equal(PolygonWindowImage *a, PolygonWindowImage *b,
                      unsigned group)
{
    if (![a.bytes isEqual:b.bytes] || a.query != b.query) {
        fprintf(stderr,
                "Polygon window group%u: raw color/depth or query mismatch "
                "(%llu/%llu)\n",
                group, (unsigned long long)a.query,
                (unsigned long long)b.query);
        abort();
    }
}
static void pwc_golden(PolygonWindowImage *image, PolygonWindowCase c,
                       BOOL derivative)
{
    unsigned size = 32 * c.scale;
    NV2AMetalPixelTexture unused[4] = { 0 };
    NV2AMetalPixelUniforms u = pwc_uniforms(c, size, unused);
    assert(image.bytes.length == (NSUInteger)size * size * c.samples * 20);
    const float *p = image.bytes.bytes;
    uint64_t count = 0;
    const float sourceR[10] = { .125f,   .125f,   .125f,   .15625f, .21875f,
                                .28125f, .34375f, .40625f, .46875f, .5f };
    for (unsigned y = 0; y < size; y++)
        for (unsigned x = 0; x < size; x++)
            for (unsigned s = 0; s < c.samples; s++) {
                BOOL visible = pwc_visible(&u, x, y);
                count += visible;
                NSUInteger offset =
                    ((NSUInteger)y * size + x) * c.samples * 5 + s * 5;
                if (!visible) {
                    const float clear[5] = { 0, 0, 1, 0, 1 };
                    assert(!memcmp(p + offset, clear, sizeof(clear)));
                } else if (!c.material) {
                    const float expected[4] = { c.reverse ? .75f : .25f,
                                                c.reverse ? .25f : .5f,
                                                c.reverse ? .5f : .75f, 1 };
                    for (unsigned k = 0; k < 4; k++)
                        assert(isfinite(p[offset + k]) &&
                               fabsf(p[offset + k] - expected[k]) < .00001f);
                } else if (derivative) {
                    float red = c.sourceProbe    ? (x < 10 ? sourceR[x] : .5f) :
                                x < 2 || x >= 10 ? .125f :
                                (x < 4 || (x < 10 && x >= 8)) ? .1875f :
                                                                .3125f;
                    const float expected[4] = { red,
                                                c.sourceProbe ? .125f : .25f,
                                                c.sourceProbe ? .0625f : .375f,
                                                .75f };
                    for (unsigned k = 0; k < 4; k++)
                        if (!(isfinite(p[offset + k]) &&
                              fabsf(p[offset + k] - expected[k]) < .00001f)) {
                            fprintf(stderr,
                                    "Polygon window handgolden %u,%u channel%u "
                                    "got%.9g expected%.9g probe%d\n",
                                    x, y, k, p[offset + k], expected[k],
                                    c.sourceProbe);
                            abort();
                        }
                }
                if (visible)
                    assert(isfinite(p[offset + 4]) && p[offset + 4] >= 0 &&
                           p[offset + 4] < 1);
            }
    assert(image.query == count);
}
/* AF controls preserve the entire depth plane and counting query; the
 * selected visible pixel must discriminate the real sampling policy. */
static void pwc_af_difference(PolygonWindowImage *af4, PolygonWindowImage *af1,
                              unsigned size, unsigned samples, BOOL dependent)
{
    assert(af4.bytes.length == (NSUInteger)size * size * samples * 20 &&
           af4.bytes.length == af1.bytes.length && af4.query == af1.query &&
           af4.query > 0);
    const uint32_t *a = af4.bytes.bytes, *b = af1.bytes.bytes;
    for (NSUInteger i = 0; i < af4.bytes.length / 20; i++)
        assert(a[5 * i + 4] == b[5 * i + 4]);
    NSUInteger i = ((NSUInteger)5 * size + size / 2 - 1) * samples * 5;
    float x, y;
    memcpy(&x, a + i, sizeof(x));
    memcpy(&y, b + i, sizeof(y));
    assert(isfinite(x) && isfinite(y) &&
           fabsf(x - y) > (dependent ? .1f : .01f));
}
static PolygonWindowImage *pwc_af_pair(NV2AMetalCommands *q,
                                       NV2AMetalGeometry *engine,
                                       NV2AMetalPixelShader *current,
                                       NV2AMetalPixelShader *previous,
                                       PolygonWindowCase c, unsigned label)
{
    PolygonWindowImage *a = pwc_render(q, engine, current, c);
    PolygonWindowImage *b = pwc_render(q, engine, previous, c);
    pwc_equal(a, b, label);
    pwc_golden(a, c, NO);
    return a;
}
static void polygon_window_clip_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *q = [[NV2AMetalCommands alloc] initWithError:&error];
    require(q != nil, error);
    NV2AMetalGeometry *engine =
        [[NV2AMetalGeometry alloc] initWithDevice:q.device error:&error];
    require(engine != nil, error);
    NV2AMetalPixelShader *shaders[2][2];
    for (unsigned v = 0; v < 2; v++)
        for (unsigned ms = 0; ms < 2; ms++)
            shaders[v][ms] = pwc_shader(q, v, ms ? 4 : 1);
    for (unsigned group = 0; group < 24; group++) {
        @autoreleasepool {
            PolygonWindowCase c = { .window = group < 16 ? group / 2 : 3,
                                    .material = group & 1,
                                    .scale = group == 18 || group == 19 ? 2 : 1,
                                    .samples =
                                        group == 20 || group == 21 ? 4 : 1,
                                    .flat = group == 16,
                                    .reverse = group == 17,
                                    .extremes = group >= 22,
                                    .compact = group % 4 >= 2,
                                    .anisotropic = group >= 16 && (group & 1) };
            c.wideFootprint = group == 19 || group == 21 || group == 23;
            if (group == 17)
                c.material = 0; /* Observe V0's distinct back face, not T1. */
            PolygonWindowImage *current =
                pwc_render(q, engine, shaders[0][c.samples > 1], c);
            PolygonWindowImage *previous =
                pwc_render(q, engine, shaders[1][c.samples > 1], c);
            pwc_equal(current, previous, group);
            pwc_golden(current, c, group == 7);
            if (group == 23) {
                PolygonWindowImage *finalAF4 = current;
                c.sourceProbe = YES;
                PolygonWindowImage *sourceAF4 =
                    pwc_af_pair(q, engine, shaders[0][0], shaders[1][0], c, 26);
                c.sourceAF = 1;
                PolygonWindowImage *sourceAF1 =
                    pwc_af_pair(q, engine, shaders[0][0], shaders[1][0], c, 27);
                pwc_af_difference(sourceAF4, sourceAF1, 32, 1, NO);
                const float *r4 = sourceAF4.bytes.bytes,
                            *r1 = sourceAF1.bytes.bytes;
                NSUInteger index = (5 * 32 + 15) * 5;
                assert(fabsf(r4[index] - .25625f) < .00001f &&
                       fabsf(r1[index] - .1875f) < .00001f);
                /* Hold T0's AF4 result fixed while changing only the
                 * dependent stage to AF1. Its nonzero major axis is real. */
                c.sourceAF = 4;
                c.dependentAF = 1;
                c.sourceProbe = NO;
                PolygonWindowImage *dependentAF1 =
                    pwc_af_pair(q, engine, shaders[0][0], shaders[1][0], c, 28);
                pwc_af_difference(finalAF4, dependentAF1, 32, 1, YES);
            }
            if (group == 7) {
                c.sourceProbe = YES;
                current = pwc_render(q, engine, shaders[0][0], c);
                previous = pwc_render(q, engine, shaders[1][0], c);
                pwc_equal(current, previous, 24);
                pwc_golden(current, c, YES);
                /* GuardOFF must preserve the complete old result; Poison
                 * must reach this visible carrier and alter actual bytes. */
                PolygonWindowImage *off =
                    pwc_render(q, engine, pwc_shader(q, 2, 1), c);
                pwc_equal(current, off, 25);
                PolygonWindowImage *poison =
                    pwc_render(q, engine, pwc_shader(q, 3, 1), c);
                assert(![current.bytes isEqual:poison.bytes] ||
                       current.query != poison.query);
            }
        }
    }
    printf("Polygon window:24 exact full-source color/depth/physical-query "
           "pairs, T0/LOD handgoldens, separate source/dependent AF4-vs-AF1 "
           "byte witnesses and gate controls PASS\n");
}
#endif
