/* Compact smooth fill against the unchanged materialized geometry path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_POLYGON_FILL_H
#define TEST_METAL_COMPACT_POLYGON_FILL_H
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"
#import <objc/runtime.h>

@interface NV2AMetalGeometry (CompactPolygonFillReference)
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeRasterVertices:(id<MTLBuffer>)vertices
                   first:(NSUInteger)first
                   count:(NSUInteger)count
               primitive:(enum NV2AMetalPrimitive)primitive
                  config:(const NV2AMetalGeometryRasterConfig *)config
                  smooth:(BOOL)smooth
          firstProvoking:(BOOL)first
            zPerspective:(BOOL)perspective
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error;
@end
typedef struct CPFCase {
    enum NV2AMetalPrimitive primitive;
    NSUInteger count, first, length;
    unsigned transport, scene, mixed, material;
    BOOL smooth, provoking, perspective, clockwise, cullFront, cullBack;
} CPFCase;
@interface CPFInput : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) NV2AMetalIndexedVertices *owner;
@property(nonatomic) NSData *bytes;
@property(nonatomic) NSUInteger first, count;
@end
@implementation CPFInput
@end
@interface CPFOutput : NSObject
@property(nonatomic) NSData *pixels;
@property(nonatomic) NSArray<NSData *> *records, *projections;
@property(nonatomic) NSArray<NV2AMetalGeometryResult *> *geometry;
@property(nonatomic) CPFInput *input;
@property(nonatomic) uint64_t query;
@property(nonatomic) unsigned pack, expand, gather, face;
@end
@implementation CPFOutput
@end

static _Thread_local BOOL cpf_active, cpf_observe;
static _Thread_local BOOL cpf_injected;
static _Thread_local unsigned cpf_failure_stage, cpf_failure_left,
    cpf_failure_calls;
static id (*cpf_prepare_original)(id, SEL, id, NSUInteger, NSUInteger,
                                  const NV2AMetalPixelUniforms *,
                                  const NV2AMetalPixelTexture *, id, id,
                                  NV2AMetalPixelRasterClass, BOOL, id,
                                  NSError **);
static BOOL (*cpf_emit_original)(id, SEL, id, id, NSError **);
static id cpf_prepare_spy(id object, SEL selector, id geometry,
                          NSUInteger offset, NSUInteger count,
                          const NV2AMetalPixelUniforms *u,
                          const NV2AMetalPixelTexture *t, id pass, id state,
                          NV2AMetalPixelRasterClass raster, BOOL ignore, id q,
                          NSError **error)
{
    id result =
        cpf_prepare_original(object, selector, geometry, offset, count, u, t,
                             pass, state, raster, ignore, q, error);
    if (cpf_failure_stage == 1 && !cpf_injected) {
        cpf_failure_calls++;
        if (!--cpf_failure_left && result) {
            cpf_injected = YES;
            if (error)
                *error = [NSError errorWithDomain:@"test.compact-fill.prepare"
                                             code:1
                                         userInfo:nil];
            return nil;
        }
    }
    return result;
}
static BOOL cpf_emit_spy(id object, SEL selector, id encoder, id q,
                         NSError **error)
{
    BOOL result = cpf_emit_original(object, selector, encoder, q, error);
    if (cpf_failure_stage == 2 && !cpf_injected) {
        cpf_failure_calls++;
        if (!--cpf_failure_left && result) {
            cpf_injected = YES;
            if (error)
                *error = [NSError errorWithDomain:@"test.compact-fill.emit"
                                             code:1
                                         userInfo:nil];
            return NO;
        }
    }
    return result;
}
static unsigned cpf_pack, cpf_expand, cpf_gather, cpf_face;
static NSMutableDictionary<NSValue *, NSString *> *cpf_names, *cpf_encoders;
static id (*cpf_compute_original)(id, SEL, NSString *, NSError **);
static void (*cpf_pipeline_original)(id, SEL, id);
static void (*cpf_dispatch_original)(id, SEL, MTLSize, MTLSize);
static id cpf_compute(id object, SEL selector, NSString *name, NSError **error)
{
    id result = cpf_compute_original(object, selector, name, error);
    if (cpf_active && result)
        cpf_names[[NSValue valueWithPointer:(__bridge const void *)result]] =
            name;
    return result;
}
static void cpf_pipeline(id object, SEL selector, id pipeline)
{
    if (cpf_active) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
        NSString *name = cpf_names[
            [NSValue valueWithPointer:(__bridge const void *)pipeline]];
        if (name)
            cpf_encoders[key] = name;
        else
            [cpf_encoders removeObjectForKey:key];
    }
    cpf_pipeline_original(object, selector, pipeline);
}
static void cpf_dispatch(id object, SEL selector, MTLSize threads,
                         MTLSize group)
{
    if (cpf_active && cpf_observe) {
        NSString *name = cpf_encoders[
            [NSValue valueWithPointer:(__bridge const void *)object]];
        cpf_pack += [name isEqualToString:@"nv2a_compact_polygon_fill"] ||
                    [name isEqualToString:@"nv2a_compact_indexed_polygon_fill"];
        cpf_expand += [name isEqualToString:@"nv2a_expand_geometry"];
        cpf_gather += [name isEqualToString:@"nv2a_vertex_stream_gather"];
        cpf_face += [name isEqualToString:@"nv2a_polygon_face"] ||
                    [name isEqualToString:@"nv2a_direct_polygon_face"] ||
                    [name isEqualToString:@"nv2a_direct_indexed_polygon_face"];
    }
    cpf_dispatch_original(object, selector, threads, group);
}
static id<MTLBuffer> cpf_copy(NV2AMetalCommands *q, id<MTLBuffer> source)
{
    if (!source)
        return nil;
    NSError *error = nil;
    id<MTLBuffer> target =
        [q.device newBufferWithLength:source.length
                              options:MTLResourceStorageModeShared];
    require(target && [q addResource:source error:&error] &&
                [q addResource:target error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:target
        destinationOffset:0
                     size:source.length];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return target;
}
static CPFInput *cpf_input(NV2AMetalCommands *q, CPFCase c)
{
    NSUInteger first = c.transport == 2 ? 7 : c.transport == 1 ? 2 : 0;
    NSUInteger physical = c.transport == 1 ? 8 : first + c.count + 1;
    NSMutableData *bytes =
        [NSMutableData dataWithLength:physical * sizeof(NV2AMetalVertex)];
    NV2AMetalVertex *v = bytes.mutableBytes;
    const float xy[8][2] = { { 3.25f, 4.5f },   { 27.5f, 6.25f },
                             { 28.25f, 25.5f }, { 6.5f, 27.25f },
                             { 5.5f, 5.75f },   { 26.25f, 27.5f },
                             { 29.5f, 8.5f },   { 7.25f, 26.5f } };
    for (NSUInteger i = 0; i < physical; i++) {
        NSUInteger n = c.transport == 1 ? i : i >= first ? i - first : 7;
        float x = xy[n % 8][0], y = xy[n % 8][1];
        float w = .5f + (n % 4) * .25f;
        if (c.scene == 2 && n < 3) {
            x = 3.5f + 8 * n;
            y = 5.5f; // Whole-polygon facing must scan beyond this fan.
        }
        if (c.scene == 3 && n == 1)
            w = -w;
        if (c.scene == 4 && n == 1)
            w = 0;
        v[i].clip[0] = (x / 16 - 1) * w;
        v[i].clip[1] = (1 - y / 16) * w;
        v[i].clip[2] = .5f * w;
        v[i].clip[3] = w;
        v[i].screen[0] = x;
        v[i].screen[1] = y;
        v[i].screen[2] = 9000 + (n % 8) * (n % 8) * 600;
        v[i].screen[3] = w;
        v[i].fog = .1f + (n % 8) * .09f;
        v[i].point_size = 3;
        for (unsigned k = 0; k < 4; k++) {
            v[i].color[0][k] = k == 3 ? .55f : (n + k) % 5 / 4.f;
            v[i].color[1][k] = k == 3 ? .6f : (n + k * 2) % 7 / 6.f;
            v[i].color[2][k] = k == 3 ? .65f : (n + k + 2) % 7 / 6.f;
            v[i].color[3][k] = k == 3 ? .7f : (n + k + 1) % 5 / 4.f;
            for (unsigned t = 0; t < 4; t++)
                v[i].texcoord[t][k] = k == 3 ? 1 : .125f * (n + t + k);
        }
    }
    CPFInput *input = [CPFInput new];
    input.bytes = [bytes copy];
    input.buffer = [q.device newBufferWithBytes:bytes.bytes
                                         length:bytes.length
                                        options:MTLResourceStorageModeShared];
    input.first = first;
    input.count = c.count;
    require(input.buffer != nil, nil);
    if (c.transport == 1) {
        NSMutableData *mapping =
            [NSMutableData dataWithLength:(first + c.count) * 4];
        uint32_t *map = mapping.mutableBytes;
        const unsigned order[] = { 2, 0, 3, 1, 6, 4, 7, 5 };
        map[0] = 7;
        map[1] = 6;
        for (NSUInteger i = 0; i < c.count; i++)
            map[first + i] = order[i % 8];
        NSError *error = nil;
        input.owner =
            [[NV2AMetalIndexedVertices alloc] initWithVertices:input.buffer
                                                 physicalCount:physical
                                                         remap:mapping
                                                         error:&error];
        require(input.owner != nil, error);
    }
    return input;
}
static NV2AMetalGeometryRasterConfig cpf_config(CPFCase c)
{
    return (NV2AMetalGeometryRasterConfig){ .front = NV2AMetalPolygonFill,
                                            .back = c.mixed == 1 ?
                                                        NV2AMetalPolygonPoint :
                                                    c.mixed == 2 ?
                                                        NV2AMetalPolygonLine :
                                                        NV2AMetalPolygonFill,
                                            .frontClockwise = c.clockwise,
                                            .cullFront = c.cullFront,
                                            .cullBack = c.cullBack,
                                            .polygonSmooth = YES,
                                            .lineWidth = 3,
                                            .lineSmooth = YES,
                                            .viewportWidth = 32,
                                            .viewportHeight = 32 };
}
static NSArray<NV2AMetalGeometryResult *> *
cpf_geometry(NV2AMetalCommands *q, NV2AMetalGeometry *engine, CPFInput *input,
             CPFCase c, BOOL candidate)
{
    NSError *error = nil;
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:q.device
                                                limit:input.count
                                                error:&error];
    require(stream != nil, error);
    require(input.owner ? [stream appendIndexedVertices:input.owner
                                                  first:input.first
                                                  count:input.count
                                                  error:&error] :
                          [stream appendVertices:input.buffer
                                           first:input.first
                                           count:input.count
                                           error:&error],
            error);
    NV2AMetalGeometryRasterConfig config = cpf_config(c);
    if (candidate) {
        NV2AMetalVertexSlice *slice =
            [stream encodeSliceForDrawingWithCommands:q error:&error];
        require(slice != nil, error);
        return [engine encodeNativeRasterSlice:slice
                                     primitive:c.primitive
                                        config:&config
                                        smooth:c.smooth
                                firstProvoking:c.provoking
                                  zPerspective:c.perspective
                                      commands:q
                                         error:&error];
    }
    id<MTLBuffer> source = input.buffer;
    NSUInteger first = input.first;
    if (input.owner) {
        source = [stream encodeWithCommands:q error:&error];
        require(source != nil, error);
        first = 0;
    }
    return [engine encodeRasterVertices:source
                                  first:first
                                  count:input.count
                              primitive:c.primitive
                                 config:&config
                                 smooth:c.smooth
                         firstProvoking:c.provoking
                           zPerspective:c.perspective
                               commands:q
                                  error:&error];
}
static NV2AMetalPixelRasterClass cpf_class(NV2AMetalGeometryResult *g)
{
    return g.compactPolygons      ? NV2AMetalPixelRasterCompactPolygon :
           g.compactLines         ? NV2AMetalPixelRasterCompactLine :
           g.directQuadOptions    ? NV2AMetalPixelRasterDirectTriangle |
                                        g.directQuadOptions :
           g.directPolygonOptions ? NV2AMetalPixelRasterDirectTriangle |
                                        g.directPolygonOptions :
           g.directPoints         ? NV2AMetalPixelRasterDirectPoint :
           g.expandedPolygons     ? NV2AMetalPixelRasterExpandedPolygon :
           g.expandedLines        ? NV2AMetalPixelRasterExpandedLine :
                                    NV2AMetalPixelRasterNative;
}
static id<MTLTexture> cpf_target(id<MTLDevice> device, MTLPixelFormat format)
{
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:32
                                                          height:32
                                                       mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
              MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [device newTextureWithDescriptor:d];
    assert(texture);
    return texture;
}
static id<MTLComputePipelineState> cpf_read_pipeline;
static id<MTLTexture> cpf_pattern;
static void cpf_init_read(id<MTLDevice> device)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new];
    d.source = @"#include <metal_stdlib>\nusing namespace metal;\n"
                "kernel void cpf_read(texture2d<float> c "
                "[[texture(0)]],texture2d<float> z [[texture(1)]],"
                "texture2d<uint> s [[texture(2)]],device uint *o "
                "[[buffer(0)]],uint i [[thread_position_in_grid]]){"
                "if(i>=1024)return;uint2 p(i%32,i/32);uint4 "
                "v=as_type<uint4>(c.read(p));"
                "o[6*i]=v.x;o[6*i+1]=v.y;o[6*i+2]=v.z;o[6*i+3]=v.w;o[6*i+4]=as_"
                "type<uint>(z.read(p).x);o[6*i+5]=s.read(p).x;}";
    d.options = [MTLCompileOptions new];
    d.options.languageVersion = MTLLanguageVersion4_0;
    d.options.mathMode = MTLMathModeSafe;
    d.options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:d error:&error];
    require(library != nil, error);
    MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new];
    f.library = library;
    f.name = @"cpf_read";
    MTL4ComputePipelineDescriptor *p = [MTL4ComputePipelineDescriptor new];
    p.computeFunctionDescriptor = f;
    cpf_read_pipeline = [compiler newComputePipelineStateWithDescriptor:p
                                                    compilerTaskOptions:nil
                                                                  error:&error];
    require(cpf_read_pipeline != nil, error);
}
static id<MTLBuffer> cpf_read(NV2AMetalCommands *q, id<MTLTexture> color,
                              id<MTLTexture> depth)
{
    NSError *error = nil;
    id<MTLTexture> stencil =
        [depth newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
    id<MTLBuffer> output =
        [q.device newBufferWithLength:1024 * 24
                              options:MTLResourceStorageModeShared];
    require(stencil && output, nil);
    for (id resource in @[ color, depth, stencil, output ])
        require([q addResource:resource error:&error], error);
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 1;
    d.maxTextureBindCount = 3;
    d.initializeBindings = YES;
    id<MTL4ArgumentTable> a = [q.device newArgumentTableWithDescriptor:d
                                                                 error:&error];
    require(a && [q keepAlive:a error:&error] &&
                [q keepAlive:cpf_read_pipeline error:&error],
            error);
    [a setAddress:output.gpuAddress atIndex:0];
    [a setTexture:color.gpuResourceID atIndex:0];
    [a setTexture:depth.gpuResourceID atIndex:1];
    [a setTexture:stencil.gpuResourceID atIndex:2];
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setArgumentTable:a];
    [e setComputePipelineState:cpf_read_pipeline];
    [e dispatchThreads:MTLSizeMake(1024, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return output;
}
static NV2AMetalPixelDraw *
cpf_try_prepare(NV2AMetalPixelShader *shader, NV2AMetalCommands *q,
                NV2AMetalGeometryResult *g, CPFCase c,
                MTL4RenderPassDescriptor *pass, NSError **failure)
{
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 16777215, 0, 16777215 },
                                 .clip_regions = { { 0, 0, 32, 32 } },
                                 .surface_scale = { 1, 1 },
                                 .depth_format = NV2AMetalPixelDepthD24,
                                 .smooth_shading = c.smooth,
                                 .two_side = 1,
                                 .z_perspective = c.perspective,
                                 .depth_offset = 128,
                                 .depth_factor = 1.5f };
    u.combiner.final_inputs[0] =
        c.material == 1 ? PS_REGISTER_T0 :
        c.material == 2 ? (PS_REGISTER_FOG | PS_CHANNEL_ALPHA) :
        c.scene == 2    ? PS_REGISTER_V1 :
                          PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalDrawConfig dc = { 0 };
    dc.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ZENABLE |
                    NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                    NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE | 7 << 16;
    dc.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 5 << 4 |
                    0x13 << 8 | 0xff << 16 | 0xffu << 24;
    dc.control[2] = 1 | 1 << 4 | 4 << 8;
    dc.blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
    NSError *error = nil;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:q.device
                                            config:&dc
                                             error:&error];
    require(state != nil, error);
    NV2AMetalPixelTexture textures[4] = { 0 };
    if (c.material == 1) {
        textures[0].texture = cpf_pattern;
        u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
        u.textures[0].dimension = 2;
        u.textures[0].scale = 1;
        u.textures[0].alphakill = 1;
        u.textures[0].sampling =
            (NV2AMetalSamplingUniforms){ .enabled = 1,
                                         .address = { 1, 1, 3 },
                                         .min_linear = 1,
                                         .mag_linear = 1,
                                         .anisotropy = 1 };
    }
    NSUInteger first = c.length ? c.first : 0,
               count = c.length ? c.length : g.vertexCount;
    NV2AMetalPixelDraw *draw =
        [shader prepareGeometry:g
                          offset:first * sizeof(NV2AMetalVertex)
                           count:count
                        uniforms:&u
                        textures:textures
                            pass:pass
                       drawState:state
                     rasterClass:cpf_class(g)
            ignorePolygonCulling:g.expandedPolygons || g.expandedLines
                        commands:q
                           error:&error];
    if (!draw && failure)
        *failure = error;
    return draw;
}
static NV2AMetalPixelDraw *cpf_prepare(NV2AMetalPixelShader *shader,
                                       NV2AMetalCommands *q,
                                       NV2AMetalGeometryResult *g, CPFCase c,
                                       MTL4RenderPassDescriptor *pass)
{
    NSError *error = nil;
    NV2AMetalPixelDraw *draw = cpf_try_prepare(shader, q, g, c, pass, &error);
    if (!draw && cpf_injected)
        return nil;
    require(draw != nil, error);
    return draw;
}
static CPFOutput *cpf_render(NV2AMetalCommands *q, NV2AMetalGeometry *engine,
                             NV2AMetalPixelShader *shader, CPFCase c,
                             BOOL candidate, BOOL grouped)
{
    NSError *error = nil;
    require([q beginWithError:&error] != nil, error);
    CPFInput *input = cpf_input(q, c);
    cpf_pack = cpf_expand = cpf_gather = cpf_face = 0;
    cpf_observe = YES;
    NSArray<NV2AMetalGeometryResult *> *results =
        cpf_geometry(q, engine, input, c, candidate);
    cpf_observe = NO;
    require(results.count == (c.mixed ? 2u : 1u), nil);
    unsigned pack = cpf_pack, expand = cpf_expand, gather = cpf_gather,
             face = cpf_face;
    NSMutableArray *copies = [NSMutableArray new],
                   *projections = [NSMutableArray new];
    for (NV2AMetalGeometryResult *g in results) {
        [copies
            addObject:
                cpf_copy(q, g.compactPolygons ? g.polygonCoverage : g.vertices) ?:
                    (id)NSNull.null];
        [projections
            addObject:cpf_copy(q, g.polygonProjections) ?: (id)NSNull.null];
    }
    id<MTLTexture> color = cpf_target(q.device, MTLPixelFormatRGBA32Float);
    id<MTLTexture> depth =
        cpf_target(q.device, MTLPixelFormatDepth32Float_Stencil8);
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [q.device newBufferWithBytes:&initial
                              length:8
                             options:MTLResourceStorageModeShared];
    require(query && [q addResource:query error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(.91, .92, .93, .94);
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    pass.stencilAttachment.texture = depth;
    pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.clearStencil = 0x11;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NSMutableArray<NV2AMetalPixelDraw *> *draws = [NSMutableArray new];
    BOOL split = c.mixed && c.primitive != NV2AMetalPrimitivePolygon;
    if (candidate || !split)
        for (NV2AMetalGeometryResult *g in results) {
            CPFCase prepared = c;
            if (!candidate)
                prepared.length = 0;
            NV2AMetalPixelDraw *draw =
                cpf_prepare(shader, q, g, prepared, pass);
            if (!draw) {
                require(cpf_injected, nil);
                [q cancel];
                return nil;
            }
            if (!candidate && c.length) {
                /* Retain the complete unchanged expanded transport and its
                 * fragment capacity, then select global generated draw IDs.
                 * A sliced legacy buffer would reset id/6 incorrectly. */
                [draw setValue:@(c.first) forKey:@"firstVertex"];
                [draw setValue:@(c.length) forKey:@"vertexCount"];
            }
            [draws addObject:draw];
        }
    id<MTL4RenderCommandEncoder> e =
        [q.commandBuffer renderCommandEncoderWithDescriptor:pass];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    if (grouped || !split) {
        for (NV2AMetalPixelDraw *draw in draws) {
            BOOL ok = [draw encodeWithRenderEncoder:e commands:q error:&error];
            if (!ok && cpf_injected) {
                [e endEncoding];
                [q cancel];
                return nil;
            }
            require(ok, error);
        }
    } else {
        // Independent primitive/face ordinal, never copied from candidate draw
        // IDs.
        for (NSUInteger p = 0; p < results[0].primitiveCount; p++)
            for (NSUInteger mode = 0; mode < results.count; mode++) {
                NSUInteger width = results[mode].verticesPerPrimitive;
                if (candidate)
                    require([draws[mode] encodeWithRenderEncoder:e
                                                        commands:q
                                                     firstVertex:p * width
                                                     vertexCount:width
                                                           error:&error],
                            error);
                else {
                    /* Independent old preparation and whole emission for
                     * each primitive/face; never reuse the new range emitter.
                     */
                    CPFCase part = c;
                    part.first = p * width;
                    part.length = width;
                    NV2AMetalPixelDraw *old =
                        cpf_prepare(shader, q, results[mode], part, pass);
                    require([old encodeWithRenderEncoder:e
                                                commands:q
                                                   error:&error],
                            error);
                }
            }
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    id<MTLBuffer> readback = cpf_read(q, color, depth);
    require([q submitWithError:&error] && [q waitUntilIdleWithError:&error],
            error);
    CPFOutput *out = [CPFOutput new];
    out.pixels = [NSData dataWithBytes:readback.contents
                                length:readback.length];
    out.query = *(const uint64_t *)query.contents;
    out.input = input;
    out.geometry = results;
    out.pack = pack;
    out.expand = expand;
    out.gather = gather;
    out.face = face;
    NSMutableArray *records = [NSMutableArray new],
                   *projected = [NSMutableArray new];
    for (id item in copies) {
        id<MTLBuffer> buffer = item == NSNull.null ? nil : item;
        [records addObject:buffer ? [NSData dataWithBytes:buffer.contents
                                                   length:buffer.length] :
                                    [NSData data]];
    }
    for (id item in projections) {
        id<MTLBuffer> buffer = item == NSNull.null ? nil : item;
        [projected addObject:buffer ? [NSData dataWithBytes:buffer.contents
                                                     length:buffer.length] :
                                      [NSData data]];
    }
    out.records = records;
    out.projections = projected;
    return out;
}
static unsigned cpf_valid_packets, cpf_second_planes;
static uint64_t cpf_visible, cpf_changed_color, cpf_changed_zeta;
static void cpf_packets(CPFOutput *a, CPFOutput *b, CPFCase c)
{
    for (NSUInteger mode = 0; mode < a.geometry.count; mode++) {
        NV2AMetalGeometryResult *g = a.geometry[mode];
        if (!g.compactPolygons)
            continue;
        NSData *packets = a.records[mode], *expanded = b.records[mode];
        NSUInteger n = g.vertexCount / 6;
        assert(packets.length == n * sizeof(NV2AMetalCompactPolygon) &&
               expanded.length == n * 6 * sizeof(NV2AMetalVertex));
        const NV2AMetalCompactPolygon *p = packets.bytes;
        const NV2AMetalVertex *v = expanded.bytes,
                              *source = a.input.bytes.bytes;
        if (!a.input.owner)
            source += a.input.first;
        const NV2AMetalPolygonProjection *pa = a.projections[mode].bytes,
                                         *pb = b.projections[mode].bytes;
        for (NSUInteger i = 0; i < n; i++) {
            const NV2AMetalVertex *r = v + i * 6;
            assert(!!p[i].valid == (r[0].line_raster[2] == 2));
            assert(!p[i].reserved[0] && !p[i].reserved[1] &&
                   pa[i].count == pb[i].count && pa[i].count <= 8);
            assert(!memcmp(pa[i].points, pb[i].points,
                           pa[i].count * sizeof(pa[i].points[0])));
            if (!p[i].valid)
                continue;
            cpf_valid_packets++;
            assert(p[i].provoking < g.physicalVertexCount);
            const unsigned corners[] = { 0, 1, 2, 5 }, slots[] = { 0, 2, 5 };
            for (unsigned k = 0; k < 4; k++)
                assert(!memcmp(p[i].clip[k], r[corners[k]].clip, 8));
            assert(!memcmp(p[i].p0, r[0].plane[0], 16) &&
                   !memcmp(p[i].p1, r[0].plane[1], 16) &&
                   !memcmp(p[i].p2, r[0].plane[2], 16) &&
                   !memcmp(&p[i].slope, &r[0].slope, 4) &&
                   p[i].face == r[0].face && p[i].color_smooth == c.smooth &&
                   p[i].viewport[0] == 32 && p[i].viewport[1] == 32);
            for (unsigned k = 0; k < 3; k++) {
                assert(p[i].source[k] < g.physicalVertexCount);
                const NV2AMetalVertex *s = source + p[i].source[k];
                assert(!memcmp(s->texcoord, r[slots[k]].texcoord,
                               sizeof(s->texcoord)) &&
                       !memcmp(&s->fog, &r[slots[k]].fog, 4) &&
                       !memcmp(s->clip, r[slots[k]].coverage_clip, 8));
                const NV2AMetalVertex *color =
                    c.smooth ? s : source + p[i].provoking;
                assert(!memcmp(color->color, r[slots[k]].color,
                               sizeof(color->color)));
            }
            if (c.primitive == NV2AMetalPrimitiveQuads ||
                c.primitive == NV2AMetalPrimitiveQuadStrip)
                cpf_second_planes += !!(i & 1);
        }
    }
}
static void cpf_pair(NV2AMetalCommands *q, NV2AMetalGeometry *engine,
                     NV2AMetalPixelShader *shader, CPFCase c, unsigned index)
{
    CPFOutput *a = cpf_render(q, engine, shader, c, YES, NO);
    CPFOutput *b = cpf_render(q, engine, shader, c, NO, NO);
    if (![a.pixels isEqual:b.pixels] || a.query != b.query) {
        fprintf(stderr,
                "Compact polygon fill case%u primitive%u transport%u scene%u "
                "mixed%u: framebuffer/Zeta/query mismatch (%llu/%llu)\n",
                index, c.primitive, c.transport, c.scene, c.mixed,
                (unsigned long long)a.query, (unsigned long long)b.query);
        abort();
    }
    cpf_packets(a, b, c);
    unsigned fills = 0;
    for (NV2AMetalGeometryResult *g in a.geometry) {
        if (g.polygonMode != NV2AMetalPolygonFill)
            continue;
        fills++;
        assert(g.compactPolygons && g.expandedPolygons &&
               g.vertices == a.input.buffer &&
               g.indexedVertices == a.input.owner &&
               g.polygonCoverage.storageMode == MTLStorageModePrivate &&
               g.polygonCoverage.length == g.vertexCount / 6 * 128 &&
               g.polygonProjections.length == g.vertexCount / 6 * 68 &&
               g.firstVertex == (a.input.owner ? 0 : a.input.first) &&
               g.indexOffset == (a.input.owner ? a.input.first : 0));
    }
    assert(a.pack == fills && !a.expand && !a.gather &&
           b.expand == b.geometry.count && b.gather == !!b.input.owner);
    const uint32_t *words = a.pixels.bytes;
    const float initial[] = { .91f, .92f, .93f, .94f };
    for (unsigned i = 0; i < 1024; i++) {
        cpf_changed_color += !!memcmp(words + 6 * i, initial, 16);
        float z;
        memcpy(&z, words + 6 * i + 4, 4);
        cpf_changed_zeta += z != 1 || words[6 * i + 5] != 0x11;
    }
    cpf_visible += a.query - 7;
}
static void cpf_guards(NV2AMetalCommands *q, NV2AMetalGeometry *engine,
                       NV2AMetalPixelShader *shader)
{
    NSError *error = nil;
    require([q beginWithError:&error] != nil, error);
    CPFCase c = { .primitive = NV2AMetalPrimitiveTriangles,
                  .count = 6,
                  .transport = 1,
                  .smooth = YES };
    CPFInput *input = cpf_input(q, c);
    NV2AMetalGeometryResult *g =
        cpf_geometry(q, engine, input, c, YES).firstObject;
    require(g && [g canUsePolygonCoverageForCommands:q], nil);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture =
        cpf_target(q.device, MTLPixelFormatRGBA32Float);
    pass.depthAttachment.texture =
        cpf_target(q.device, MTLPixelFormatDepth32Float_Stencil8);
    pass.stencilAttachment.texture = pass.depthAttachment.texture;
    id<MTLBuffer> coverage = g.polygonCoverage;
    [g setValue:[q.device newBufferWithLength:coverage.length - 1
                                      options:MTLResourceStorageModePrivate]
         forKey:@"polygonCoverage"];
    assert(!cpf_try_prepare(shader, q, g, c, pass, &error) && error);
    [g setValue:coverage forKey:@"polygonCoverage"];
    error = nil;
    CPFCase invalid = c;
    invalid.first = g.vertexCount;
    invalid.length = 1;
    assert(!cpf_try_prepare(shader, q, g, invalid, pass, &error) && error);
    error = nil;
    NSUInteger physical = g.physicalVertexCount;
    [g setValue:@(physical - 1) forKey:@"physicalVertexCount"];
    assert(!cpf_try_prepare(shader, q, g, c, pass, &error) && error);
    [g setValue:@(physical) forKey:@"physicalVertexCount"];
    error = nil;
    NV2AMetalPixelDraw *prepared =
        cpf_try_prepare(shader, q, g, c, pass, &error);
    require(prepared != nil,
            error); // Retry after each rejected binding is valid.
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:q.device error:&error];
    require(foreign && [foreign beginWithError:&error], error);
    assert(![g canUsePolygonCoverageForCommands:foreign]);
    assert(!cpf_try_prepare(shader, foreign, g, c, pass, &error) && error);
    [foreign cancel];
    error = nil;
    NV2AMetalGeometryRasterConfig config = cpf_config(c);
    config.viewportWidth = 0;
    assert(![engine encodeNativeRasterVertices:input.buffer
                                         count:3
                                     primitive:c.primitive
                                        config:&config
                                        smooth:YES
                                firstProvoking:NO
                                  zPerspective:NO
                                      commands:q
                                         error:&error] &&
           error);
    [q cancel];
    error = nil;
    require([q beginWithError:&error] != nil, error);
    assert(![g canUsePolygonCoverageForCommands:q] &&
           !cpf_try_prepare(shader, q, g, c, pass, &error) && error);
    [q cancel];
    error = nil;
    require([q beginWithError:&error] != nil, error);
    config = cpf_config(c);
    for (NSUInteger n = 0; n < 3; n++) {
        NSArray<NV2AMetalGeometryResult *> *empty =
            [engine encodeNativeRasterVertices:input.buffer
                                         count:n
                                     primitive:NV2AMetalPrimitivePolygon
                                        config:&config
                                        smooth:NO
                                firstProvoking:YES
                                  zPerspective:NO
                                      commands:q
                                         error:&error];
        require(empty.count == 1, error);
        NV2AMetalGeometryResult *e = empty[0];
        assert(e.compactPolygons && !e.vertexCount && !e.vertices &&
               !e.indexedVertices && !e.sourceVertexCount &&
               !e.physicalVertexCount && !e.polygonCoverage &&
               !e.polygonProjections);
    }
    [q cancel];
}
static void cpf_failures(NV2AMetalCommands *q, NV2AMetalGeometry *engine,
                         NV2AMetalPixelShader *shader)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            @selector(
                prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                rasterClass:ignorePolygonCulling:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    assert(methods[0] && methods[1]);
    IMP originals[] = { method_getImplementation(methods[0]),
                        method_getImplementation(methods[1]) };
    cpf_prepare_original = (void *)originals[0];
    cpf_emit_original = (void *)originals[1];
    method_setImplementation(methods[0], (IMP)cpf_prepare_spy);
    method_setImplementation(methods[1], (IMP)cpf_emit_spy);
    @try {
        for (unsigned stage = 1; stage <= 2; stage++) {
            CPFCase c = { .primitive = NV2AMetalPrimitivePolygon,
                          .count = 6,
                          .transport = 1,
                          .mixed = 2,
                          .smooth = NO,
                          .provoking = YES,
                          .perspective = YES,
                          .material = 1 };
            cpf_failure_stage = stage;
            cpf_failure_left = 2; // Last real mode preparation/emission.
            cpf_failure_calls = 0;
            cpf_injected = NO;
            CPFOutput *failed = cpf_render(q, engine, shader, c, YES, NO);
            assert(!failed && cpf_injected && cpf_failure_calls == 2 &&
                   !q.commandBuffer);
            cpf_failure_stage = 0;
            cpf_injected = NO;
            CPFOutput *retry = cpf_render(q, engine, shader, c, YES, NO);
            CPFOutput *reference = cpf_render(q, engine, shader, c, NO, NO);
            assert([retry.pixels isEqual:reference.pixels] &&
                   retry.query == reference.query);
            cpf_packets(retry, reference, c);
        }
    } @finally {
        cpf_failure_stage = 0;
        cpf_injected = NO;
        for (unsigned i = 0; i < 2; i++)
            method_setImplementation(methods[i], originals[i]);
        [q cancel];
    }
}
static void compact_polygon_fill_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *q = [[NV2AMetalCommands alloc] initWithError:&error];
    require(q != nil, error);
    cpf_init_read(q.device);
    MTLTextureDescriptor *pattern = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:8
                                    height:8
                                 mipmapped:NO];
    pattern.storageMode = MTLStorageModeShared;
    pattern.usage = MTLTextureUsageShaderRead;
    cpf_pattern = [q.device newTextureWithDescriptor:pattern];
    require(cpf_pattern != nil, nil);
    float texels[8][8][4];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            texels[y][x][0] = x / 8.f;
            texels[y][x][1] = y / 8.f;
            texels[y][x][2] = (x ^ y) / 8.f;
            texels[y][x][3] = (x / 2 + y / 2) & 1 ? 1 : 0;
        }
    [cpf_pattern replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
                   mipmapLevel:0
                     withBytes:texels
                   bytesPerRow:sizeof(texels[0])];
    require([q beginWithError:&error] != nil, error);
    id encoder = [q.commandBuffer computeCommandEncoder];
    require(encoder != nil, nil);
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(object_getClass(encoder),
                                @selector(setComputePipelineState:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:))
    };
    [encoder endEncoding];
    [q cancel];
    IMP originals[3], replacements[] = { (IMP)cpf_compute, (IMP)cpf_pipeline,
                                         (IMP)cpf_dispatch };
    cpf_names = [NSMutableDictionary new];
    cpf_encoders = [NSMutableDictionary new];
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    cpf_compute_original = (void *)originals[0];
    cpf_pipeline_original = (void *)originals[1];
    cpf_dispatch_original = (void *)originals[2];
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    cpf_active = YES;
    cpf_valid_packets = cpf_second_planes = 0;
    cpf_visible = cpf_changed_color = cpf_changed_zeta = 0;
    @try {
        NV2AMetalGeometry *engine =
            [[NV2AMetalGeometry alloc] initWithDevice:q.device error:&error];
        NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
            initWithDevice:q.device
               colorFormat:MTLPixelFormatRGBA32Float
               depthFormat:MTLPixelFormatDepth32Float_Stencil8
               sampleCount:1
                     error:&error];
        require(engine && shader, error);
        enum NV2AMetalPrimitive topologies[] = {
            NV2AMetalPrimitiveTriangles,   NV2AMetalPrimitiveTriangleStrip,
            NV2AMetalPrimitiveTriangleFan, NV2AMetalPrimitiveQuads,
            NV2AMetalPrimitiveQuadStrip,   NV2AMetalPrimitivePolygon
        };
        unsigned pairs = 0;
        for (unsigned t = 0; t < 6; t++)
            for (unsigned variant = 0; variant < 3; variant++) {
                CPFCase c = { .primitive = topologies[t],
                              .count = t == 0           ? 12 :
                                       t == 3 || t == 4 ? 8 :
                                                          6,
                              .transport = variant,
                              .material = variant,
                              .scene = variant == 2 ? (t == 5 ? 2 :
                                                       t & 1  ? 3 :
                                                                4) :
                                                      0,
                              .smooth = variant == 0,
                              .provoking = variant == 1,
                              .perspective = variant != 0,
                              .clockwise = !!(t & 1),
                              .cullBack = variant == 2 && t == 0 };
                cpf_pair(q, engine, shader, c, pairs++);
            }
        for (unsigned i = 0; i < 4; i++) {
            CPFCase c = { .primitive = i & 1 ? NV2AMetalPrimitiveQuads :
                                               NV2AMetalPrimitiveTriangles,
                          .count = i & 1 ? 8 : 12,
                          .transport = i & 1,
                          .mixed = i < 2 ? 1 : 2,
                          .smooth = !!(i & 1),
                          .provoking = !(i & 1),
                          .perspective = YES };
            cpf_pair(q, engine, shader, c, pairs++);
        }
        for (unsigned i = 0; i < 2; i++) {
            CPFCase c = { .primitive = NV2AMetalPrimitiveTriangles,
                          .count = 12,
                          .transport = i + 1,
                          .smooth = YES,
                          .first = i ? 5 : 1,
                          .length = i ? 7 : 11 };
            cpf_pair(q, engine, shader, c, pairs++);
        }
        cpf_guards(q, engine, shader);
        cpf_failures(q, engine, shader);
        assert(pairs == 24 && cpf_valid_packets && cpf_second_planes &&
               cpf_visible && cpf_changed_color && cpf_changed_zeta);
        puts("Compact polygon fill:24 exact RGBA32/depth/stencil/query "
             "pairs;all6topologies,"
             "flat/smooth/TwoSide/first-last/clipW/Plane2/depth-offset,mixed "
             "modes,index remap/"
             "nonzero offset/odd global ranges;128B packet+projection versus "
             "old6x244B,"
             "textured alphakill/fog,empty/bounds/foreign/cancel guards,last "
             "prepare/emit retry PASS");
    } @finally {
        cpf_active = cpf_observe = NO;
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
        cpf_names = cpf_encoders = nil;
        cpf_read_pipeline = nil;
        cpf_pattern = nil;
        [q cancel];
    }
}
#endif
