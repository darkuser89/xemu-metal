/* Polygon point/wire/mixed parity against unchanged compute expansion.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_MODES_RASTER_H
#define TEST_METAL_POLYGON_MODES_RASTER_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"
static unsigned pm_computes, pm_pairs, pm_direct, pm_fallback, pm_rejects;
static uint64_t pm_visible, pm_avoided;
static BOOL pm_batch_wrong;
static unsigned pm_order_checks;
static id (*pm_original_compute)(id, SEL);
static id pm_compute(id object, SEL selector)
{
    pm_computes++;
    return pm_original_compute(object, selector);
}
static void pm_require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Polygon modes: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
@interface PolygonModesInput : NSObject
@property(nonatomic) NSData *logical;
@property(nonatomic) id<MTLBuffer> linear, physical;
@property(nonatomic) NV2AMetalIndexedVertices *owner;
@property(nonatomic) NSUInteger first;
@end
@implementation PolygonModesInput
@end
static PolygonModesInput *pm_input(id<MTLDevice> device,
                                   enum NV2AMetalPrimitive primitive,
                                   unsigned transport)
{
    NV2AMetalVertex records[12] = { 0 };
    const float triangle[6][2] = { { 5, 5 },  { 25, 5 }, { 5, 25 },
                                   { 5, 25 }, { 25, 5 }, { 5, 5 } };
    const float strip[8][2] = { { 4, 4 },  { 4, 26 },  { 12, 4 }, { 12, 26 },
                                { 20, 4 }, { 20, 26 }, { 28, 4 }, { 28, 26 } };
    const float fan[8][2] = { { 16, 16 }, { 4, 4 }, { 28, 4 },  { 28, 28 },
                              { 4, 28 },  { 4, 4 }, { 28, 28 }, { 28, 4 } };
    const float quads[8][2] = { { 5, 5 },  { 25, 5 },  { 25, 25 }, { 5, 25 },
                                { 5, 25 }, { 25, 25 }, { 25, 5 },  { 5, 5 } };
    BOOL list = primitive == NV2AMetalPrimitiveTriangles;
    BOOL quad = primitive == NV2AMetalPrimitiveQuads;
    unsigned unique = list ? 6 : 8;
    const float z[4] = { 0x300000, 0x480000, 0x900000, 0xc00000 };
    for (unsigned i = 0; i < unique; i++) {
        NV2AMetalVertex *v = &records[i];
        const float *xy = list ? triangle[i] :
                          quad ? quads[i] :
                          primitive == NV2AMetalPrimitiveTriangleFan ? fan[i] :
                                                                       strip[i];
        v->screen[0] = xy[0];
        v->screen[1] = xy[1];
        v->screen[2] = z[i % 4];
        v->screen[3] = .5f + (i % 4) / 8.f;
        v->clip[0] = xy[0] / 16 - 1;
        v->clip[1] = 1 - xy[1] / 16;
        v->clip[2] = .25f;
        v->clip[3] = 1;
        v->point_size = 3 + i % 3;
        v->fog = (i + 1) / 8.f;
        for (unsigned k = 0; k < 4; k++) {
            v->color[0][k] = k == 3 ? .5f : (float)((i + k * 2) % 5) / 4;
            v->color[2][k] = k == 3 ? .5f : 1 - v->color[0][k];
            v->texcoord[3][k] = k == 3 ? 1 : (float)(i + k) / 16;
            for (unsigned p = 0; p < 3; p++)
                v->plane[p][k] = 100 + p + k;
        }
        v->face = NV2AMetalFaceBack;
        v->slope = 999;
    }
    for (unsigned i = unique; i < 12; i++)
        records[i] = records[i - unique];
    PolygonModesInput *input = [PolygonModesInput new];
    input.logical = [NSData dataWithBytes:records length:sizeof(records)];
    input.linear = [device newBufferWithBytes:records
                                       length:sizeof(records)
                                      options:MTLResourceStorageModeShared];
    input.first = transport ? 5 : 0;
    if (transport < 2) {
        input.physical =
            [device newBufferWithLength:(12 + input.first) * sizeof(*records)
                                options:MTLResourceStorageModeShared];
        memset(input.physical.contents, 0x5a, input.physical.length);
        memcpy((uint8_t *)input.physical.contents +
                   input.first * sizeof(*records),
               records, sizeof(records));
    } else {
        id<MTLBuffer> physical =
            [device newBufferWithLength:unique * sizeof(*records)
                                options:MTLResourceStorageModeShared];
        NSMutableData *mapping =
            [NSMutableData dataWithLength:17 * sizeof(uint32_t)];
        uint32_t *map = mapping.mutableBytes;
        for (unsigned i = 0; i < unique; i++)
            ((NV2AMetalVertex *)physical.contents)[unique - i - 1] = records[i];
        for (unsigned i = 0; i < 12; i++)
            map[i + 5] = unique - i % unique - 1;
        NSError *error = nil;
        input.owner =
            [[NV2AMetalIndexedVertices alloc] initWithVertices:physical
                                                 physicalCount:unique
                                                         remap:mapping
                                                         error:&error];
        pm_require(input.owner != nil, error);
        input.physical = physical;
        assert(input.owner.physicalVertexCount < 12 &&
               physical.length == unique * sizeof(*records));
    }
    assert(input.linear && input.physical);
    return input;
}
static id<MTLTexture> pm_texture(id<MTLDevice> device, MTLPixelFormat format,
                                 unsigned samples)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.width = d.height = 32;
    d.pixelFormat = format;
    d.textureType =
        samples == 1 ? MTLTextureType2D : MTLTextureType2DMultisample;
    d.sampleCount = samples;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> result = [device newTextureWithDescriptor:d];
    assert(result);
    return result;
}
static NV2AMetalPixelRasterClass pm_class(NV2AMetalGeometryResult *g)
{
    unsigned options = g.directPolygonOptions ? g.directPolygonOptions :
                       g.directQuadOptions    ? g.directQuadOptions :
                                                g.directTriangleOptions;
    return g.directPolygonOptions || g.directQuadOptions || g.directTriangles ?
               (NV2AMetalPixelRasterClass)(NV2AMetalPixelRasterDirectTriangle |
                                           options) :
           g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
           g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
                                NV2AMetalPixelRasterNative;
}
static NSUInteger pm_primitives(enum NV2AMetalPrimitive primitive,
                                NSUInteger count)
{
    return primitive == NV2AMetalPrimitiveQuads ?
               count / 4 :
           primitive == NV2AMetalPrimitiveQuadStrip ?
               (count < 4 ? 0 : count / 2 - 1) :
           primitive == NV2AMetalPrimitiveTriangles ?
               count / 3 :
               (count < 3 ? 0 : count - 2);
}
static NSUInteger pm_sources(enum NV2AMetalPrimitive primitive,
                             NSUInteger count)
{
    return primitive == NV2AMetalPrimitiveQuads     ? count / 4 * 4 :
           primitive == NV2AMetalPrimitiveQuadStrip ? count / 2 * 2 :
           primitive == NV2AMetalPrimitiveTriangles ? count / 3 * 3 :
                                                      count;
}
static NSArray<NV2AMetalGeometryResult *> *
pm_geometry(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
            PolygonModesInput *input, NSUInteger count,
            enum NV2AMetalPrimitive primitive,
            const NV2AMetalGeometryRasterConfig *config, BOOL smooth,
            BOOL first, BOOL w, BOOL direct, NSError **error)
{
    if (!direct)
        return [geometry encodeRasterVertices:input.linear
                                        count:count
                                    primitive:primitive
                                       config:config
                                       smooth:smooth
                               firstProvoking:first
                                 zPerspective:w
                                     commands:commands
                                        error:error];
    if (!input.owner)
        return [geometry encodeNativeRasterVertices:input.physical
                                              first:input.first
                                              count:count
                                          primitive:primitive
                                             config:config
                                             smooth:smooth
                                     firstProvoking:first
                                       zPerspective:w
                                           commands:commands
                                              error:error];
    if (!count)
        return [geometry encodeNativeRasterVertices:input.linear
                                              count:0
                                          primitive:primitive
                                             config:config
                                             smooth:smooth
                                     firstProvoking:first
                                       zPerspective:w
                                           commands:commands
                                              error:error];
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:count
                                                error:error];
    if (!stream || ![stream appendIndexedVertices:input.owner
                                            first:input.first
                                            count:count
                                            error:error])
        return nil;
    NV2AMetalVertexSlice *slice =
        [stream encodeSliceForDrawingWithCommands:commands error:error];
    return slice ? [geometry encodeNativeRasterSlice:slice
                                           primitive:primitive
                                              config:config
                                              smooth:smooth
                                      firstProvoking:first
                                        zPerspective:w
                                            commands:commands
                                               error:error] :
                   nil;
}
static NSData *pm_frame(NV2AMetalCommands *commands,
                        NV2AMetalGeometry *geometry,
                        NV2AMetalPixelShader *pixel, PolygonModesInput *input,
                        NSUInteger count, enum NV2AMetalPrimitive primitive,
                        NV2AMetalGeometryRasterConfig config, BOOL smooth,
                        BOOL first, BOOL w, BOOL two, BOOL depthOffset,
                        BOOL scale, unsigned samples, unsigned slicePlan,
                        BOOL direct, BOOL expectedDirect, BOOL wire,
                        unsigned effects, uint64_t *visible)
{
    NSError *error = nil;
    id<MTLTexture> color =
        pm_texture(commands.device, MTLPixelFormatRGBA8Unorm, samples);
    id<MTLTexture> depth = pm_texture(
        commands.device, MTLPixelFormatDepth32Float_Stencil8, samples);
    id<MTLTexture> resolve =
        samples == 1 ? color :
                       pm_texture(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&initial
                                     length:8
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:24576
                                     options:MTLResourceStorageModeShared];
    assert(query && readback);
    memset(readback.contents, 0x5a, readback.length);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = smooth;
    if (effects & 16) {
        u.combiner.final_inputs[0] = PS_REGISTER_FOG;
        u.combiner.final_inputs[1] = (PS_REGISTER_FOG | PS_CHANNEL_ALPHA) << 8;
        u.fog_color[0] = .25f;
        u.fog_color[1] = .5f;
        u.fog_color[2] = .75f;
    } else if (effects & (32 | 64)) {
        u.combiner.final_inputs[0] = PS_REGISTER_T3;
        u.combiner.shader_stage_program =
            (effects & 64 ? PS_TEXTUREMODES_PROJECT2D :
                            PS_TEXTUREMODES_PASSTHRU)
            << 15;
        u.point_sprite = !!(effects & 64);
    }
    u.two_side = two;
    u.z_perspective = w;
    u.depth_offset = depthOffset ? 128 : 0;
    u.depth_factor = depthOffset ? 1.5f : 0;
    u.depth_format = NV2AMetalPixelDepthD24;
    u.surface_scale[0] = scale ? 2 : 1;
    u.surface_scale[1] = scale ? 3 : 1;
    u.clip_range[1] = u.clip_range[3] = 16777215;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 32;
    for (unsigned k = 0; k < 4; k++) {
        u.textures[k].dimension = 2;
        u.textures[k].scale = 1;
    }
    NV2AMetalDrawConfig dc = { 0 };
    dc.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ZENABLE |
                    NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16;
    if (effects & 8) {
        /* Noncommutative source-alpha blending plus a stencil threshold make
         * front/back batching observably different from primitive order. */
        dc.blend = NV_PGRAPH_BLEND_EN | 2 | 5 << 4 | 6 << 8;
        dc.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 4 << 4 |
                        2 << 8 | 255 << 16 | 255u << 24;
        dc.control[2] = 1 | 1 << 4 | 4 << 8;
    }
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    pm_require(state != nil, error);
    pm_require([commands beginWithError:&error] != nil, error);
    unsigned before = pm_computes;
    NSArray<NV2AMetalGeometryResult *> *gs =
        pm_geometry(commands, geometry, input, count, primitive, &config,
                    smooth, first, w, direct, &error);
    pm_require(gs != nil, error);
    NSUInteger primitives = pm_primitives(primitive, count);
    if (direct && expectedDirect) {
        assert(gs.count == (config.front == config.back ? 1u : 2u) &&
               pm_computes == before);
        for (NV2AMetalGeometryResult *g in gs) {
            unsigned corners =
                primitive == NV2AMetalPrimitiveQuads ||
                        primitive == NV2AMetalPrimitiveQuadStrip ?
                    4 :
                    3;
            NSUInteger generated =
                primitives *
                (g.polygonMode == NV2AMetalPolygonFill ?
                     (corners == 4 ? 6 : 3) :
                     corners * (g.polygonMode == NV2AMetalPolygonLine ? 2 : 1));
            assert(g.vertexCount == generated && !g.expandedLines &&
                   !g.expandedPolygons);
            if (generated) {
                assert((g.directPolygonOptions || g.directQuadOptions ||
                        g.directTriangles) &&
                       g.vertices == input.physical &&
                       g.indexedVertices == input.owner &&
                       g.sourceVertexCount == pm_sources(primitive, count) &&
                       g.firstVertex == (input.owner ? 0 : input.first) &&
                       g.indexOffset == (input.owner ? input.first : 0));
                pm_direct++;
            }
        }
    } else if (direct) {
        for (NV2AMetalGeometryResult *g in gs)
            assert(!g.directPolygonOptions && !g.directQuadOptions &&
                   !g.directTriangles);
        pm_fallback++;
    }
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction =
        samples == 1 ? MTLStoreActionStore : MTLStoreActionMultisampleResolve;
    if (samples > 1)
        pass.colorAttachments[0].resolveTexture = resolve;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    pass.stencilAttachment.texture = depth;
    pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.clearStencil = 0;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    pm_require([commands addResource:query error:&error], error);
    pm_require([commands addResource:color error:&error] &&
                   [commands addResource:depth error:&error] &&
                   [commands addResource:resolve error:&error],
               error);
    NV2AMetalPixelTexture bindings[4] = { 0 };
    MTLTextureDescriptor *sampleDescriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:2
                                    height:2
                                 mipmapped:NO];
    sampleDescriptor.storageMode = MTLStorageModeShared;
    sampleDescriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> sampled =
        [commands.device newTextureWithDescriptor:sampleDescriptor];
    const uint32_t texels[4] = { 0xff0000ff, 0xff00ff00, 0xffff0000,
                                 0xff7f3f1f };
    [sampled replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
               mipmapLevel:0
                 withBytes:texels
               bytesPerRow:8];
    MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
    samplerDescriptor.supportArgumentBuffers = YES;
    samplerDescriptor.sAddressMode = samplerDescriptor.tAddressMode =
        MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [commands.device newSamplerStateWithDescriptor:samplerDescriptor];
    assert(sampled && sampler);
    if (effects & 64) {
        bindings[3].texture = sampled;
        bindings[3].sampler = sampler;
    }
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    BOOL mixed = gs.count > 1;
    NSUInteger rounds = mixed && !pm_batch_wrong ?
                            ((NV2AMetalGeometryResult *)gs[0]).primitiveCount :
                            1;
    for (NSUInteger p = 0; p < rounds; p++)
        for (NV2AMetalGeometryResult *g in gs) {
            if (!g.vertexCount)
                continue;
            NSUInteger firstDraw = mixed && !pm_batch_wrong ?
                                       p * g.verticesPerPrimitive :
                                   pm_batch_wrong ? 0 :
                                   slicePlan == 1 ? 1 :
                                   slicePlan == 2 ? (wire ? 4 : 3) :
                                                    0;
            NSUInteger drawCount = mixed && !pm_batch_wrong ?
                                       g.verticesPerPrimitive :
                                   pm_batch_wrong ? g.vertexCount :
                                   slicePlan == 1 ? g.vertexCount - 2 :
                                   slicePlan == 2 ? (wire ? 2 : 1) :
                                                    g.vertexCount;
            if (firstDraw > g.vertexCount ||
                drawCount > g.vertexCount - firstDraw)
                continue;
            pm_require(
                [pixel encodeGeometry:g
                                  offset:firstDraw * sizeof(NV2AMetalVertex)
                                   count:drawCount
                                uniforms:&u
                                textures:bindings
                                    pass:pass
                               drawState:state
                             rasterClass:pm_class(g)
                    ignorePolygonCulling:g.expandedLines || g.expandedPolygons
                           renderEncoder:encoder
                                commands:commands
                                   error:&error],
                error);
            if (!direct && expectedDirect)
                pm_avoided += g.vertices.length;
        }
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    pm_require([commands addResource:readback error:&error], error);
    id<MTL4ComputeCommandEncoder> copy =
        [commands.commandBuffer computeCommandEncoder];
    assert(copy);
    [copy barrierAfterQueueStages:MTLStageAll
                     beforeStages:MTLStageBlit
                visibilityOptions:MTL4VisibilityOptionDevice];
    [copy copyFromTexture:resolve
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(32, 32, 1)
                        toBuffer:readback
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:8192];
    if (samples == 1)
        [copy copyFromTexture:depth
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(32, 32, 1)
                            toBuffer:readback
                   destinationOffset:8192
              destinationBytesPerRow:256
            destinationBytesPerImage:8192
                             options:MTLBlitOptionDepthFromDepthStencil];
    if (samples == 1)
        [copy copyFromTexture:depth
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(32, 32, 1)
                            toBuffer:readback
                   destinationOffset:16384
              destinationBytesPerRow:256
            destinationBytesPerImage:8192
                             options:MTLBlitOptionStencilFromDepthStencil];
    [copy endEncoding];
    pm_require([commands submitWithError:&error] &&
                   [commands waitUntilIdleWithError:&error],
               error);
    *visible = *(const uint64_t *)query.contents;
    return [NSData dataWithBytes:readback.contents length:readback.length];
}
static void pm_pair(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                    NV2AMetalPixelShader *pixel, PolygonModesInput *input,
                    NSUInteger count, enum NV2AMetalPrimitive primitive,
                    NV2AMetalGeometryRasterConfig config, unsigned shading,
                    unsigned samples, unsigned slicePlan, BOOL expectedDirect,
                    BOOL wire, BOOL w)
{
    uint64_t queries[2];
    NSData *frames[2];
    for (unsigned direct = 0; direct < 2; direct++)
        frames[direct] =
            pm_frame(commands, geometry, pixel, input, count, primitive, config,
                     shading & 1, shading & 2, w, shading & 4, shading & 2,
                     shading & 1, samples, slicePlan, direct, expectedDirect,
                     wire, shading, &queries[direct]);
    if (queries[0] != queries[1] || ![frames[0] isEqualToData:frames[1]]) {
        fprintf(stderr,
                "Polygon modes mismatch wire%d primitive%u count%lu samples%u "
                "shading%u slice%u direct%d w%d front%d back%d cull%d%d cw%d "
                "query%llu/%llu\n",
                wire, primitive, (unsigned long)count, samples, shading,
                slicePlan, expectedDirect, w, config.front, config.back,
                config.cullFront, config.cullBack, config.frontClockwise,
                (unsigned long long)queries[0], (unsigned long long)queries[1]);
        abort();
    }
    if (samples == 1 && shading == 12 && config.front == NV2AMetalPolygonFill &&
        config.back == NV2AMetalPolygonPoint && !config.frontClockwise &&
        !config.cullFront && !config.cullBack &&
        (primitive == NV2AMetalPrimitiveTriangles ||
         primitive == NV2AMetalPrimitiveQuads)) {
        uint64_t wrongQuery;
        pm_batch_wrong = YES;
        NSData *wrong =
            pm_frame(commands, geometry, pixel, input, count, primitive, config,
                     NO, NO, NO, YES, NO, NO, samples, 0, NO, expectedDirect,
                     wire, shading, &wrongQuery);
        pm_batch_wrong = NO;
        assert(wrongQuery != queries[0] || ![wrong isEqualToData:frames[0]]);
        pm_order_checks++;
    }
    pm_visible += queries[1] - 7;
    pm_pairs++;
}
static void pm_bounds(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                      NV2AMetalPixelShader *pixel, BOOL wire)
{
    NSError *error = nil;
    PolygonModesInput *input =
        pm_input(commands.device, NV2AMetalPrimitiveTriangles, 2);
    NV2AMetalGeometryRasterConfig config = {
        .front = wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
        .back = wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
        .lineWidth = 1,
        .viewportWidth = 32,
        .viewportHeight = 32
    };
    pm_require([commands beginWithError:&error] != nil, error);
    unsigned before = pm_computes;
    NSArray<NV2AMetalGeometryResult *> *gs =
        pm_geometry(commands, geometry, input, 12, NV2AMetalPrimitiveTriangles,
                    &config, YES, YES, NO, YES, &error);
    pm_require(gs.count == 1, error);
    NV2AMetalGeometryResult *g = gs[0];
    for (unsigned invalid = 0; invalid < 4; invalid++) {
        error = nil;
        assert(![geometry
                   encodeNativeRasterVertices:input.linear
                                        first:invalid == 0 ? 13 :
                                              invalid == 1 ? NSUIntegerMax :
                                                             0
                                        count:invalid == 2 ? 13 :
                                              invalid == 3 ? NSUIntegerMax :
                                                             0
                                    primitive:NV2AMetalPrimitiveTriangles
                                       config:&config
                                       smooth:NO
                               firstProvoking:NO
                                 zPerspective:NO
                                     commands:commands
                                        error:&error] &&
               error);
        pm_rejects++;
    }
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:12
                                                error:&error];
    pm_require([stream appendIndexedVertices:input.owner
                                       first:5
                                       count:12
                                       error:&error],
               error);
    NV2AMetalVertexSlice *slice =
        [stream encodeSliceForDrawingWithCommands:commands error:&error];
    pm_require(slice != nil, error);
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        [slice setValue:invalid == 0 ? @13 : @12 forKey:@"vertexCount"];
        [slice setValue:invalid == 1 ? @(NSUIntegerMax) : @5
                 forKey:@"firstVertex"];
        [slice setValue:invalid == 2 ? input.linear : input.physical
                 forKey:@"buffer"];
        error = nil;
        assert(![geometry encodeNativeRasterSlice:slice
                                        primitive:NV2AMetalPrimitiveTriangles
                                           config:&config
                                           smooth:NO
                                   firstProvoking:NO
                                     zPerspective:NO
                                         commands:commands
                                            error:&error] &&
               error);
        pm_rejects++;
    }
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.depth_format = NV2AMetalPixelDepthD24;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 16777215;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 32;
    for (unsigned k = 0; k < 4; k++) {
        u.textures[k].dimension = 2;
        u.textures[k].scale = 1;
    }
    NV2AMetalDrawConfig dc = { 0 };
    dc.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    pm_require(state != nil, error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture =
        pm_texture(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture =
        pm_texture(commands.device, MTLPixelFormatDepth32Float_Stencil8, 1);
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    pass.stencilAttachment.texture = pass.depthAttachment.texture;
    pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    error = nil;
    assert(![pixel encodeVertices:g.vertices
                             offset:0
                              count:wire ? 2 : 1
                          primitive:g.primitiveType
                           uniforms:&u
                           textures:bindings
                               pass:pass
                          drawState:state
                        rasterClass:pm_class(g)
               ignorePolygonCulling:NO
                           commands:commands
                              error:&error] &&
           error);
    pm_rejects++;
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        error = nil;
        NSUInteger first = invalid == 0 ? g.vertexCount :
                           invalid == 1 ? g.vertexCount + 1 :
                                          0;
        NSUInteger count = invalid == 0 ? (wire ? 2 : 1) :
                           invalid == 1 ? 0 :
                                          (wire ? 1 : g.vertexCount + 1);
        assert(![pixel prepareGeometry:g
                                 offset:first * sizeof(NV2AMetalVertex)
                                  count:count
                               uniforms:&u
                               textures:bindings
                                   pass:pass
                              drawState:state
                            rasterClass:pm_class(g)
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] &&
               error);
        pm_rejects++;
    }
    error = nil;
    NV2AMetalPixelDraw *empty =
        [pixel prepareGeometry:g
                          offset:g.vertexCount * sizeof(NV2AMetalVertex)
                           count:0
                        uniforms:&u
                        textures:bindings
                            pass:pass
                       drawState:state
                     rasterClass:pm_class(g)
            ignorePolygonCulling:NO
                        commands:commands
                           error:&error];
    pm_require(empty != nil, error);
    assert(!empty.vertexCount && pm_computes == before);
    NV2AMetalGeometryRasterConfig mixedConfig = config;
    mixedConfig.front = NV2AMetalPolygonFill;
    mixedConfig.back = NV2AMetalPolygonPoint;
    PolygonModesInput *mixedInput =
        pm_input(commands.device, NV2AMetalPrimitiveTriangles, 1);
    NSArray<NV2AMetalGeometryResult *> *mixed = pm_geometry(
        commands, geometry, mixedInput, 12, NV2AMetalPrimitiveTriangles,
        &mixedConfig, NO, NO, NO, YES, &error);
    pm_require(mixed.count == 2, error);
    NV2AMetalGeometryResult *fill = mixed[0];
    assert(fill.directTriangles && fill.directTriangleOptions);
    for (unsigned invalid = 0; invalid < 2; invalid++) {
        error = nil;
        assert(![pixel prepareGeometry:fill
                                 offset:0
                                  count:fill.vertexCount
                               uniforms:&u
                               textures:bindings
                                   pass:pass
                              drawState:state
                            rasterClass:invalid ?
                                            NV2AMetalPixelRasterNative :
                                            NV2AMetalPixelRasterDirectTriangle
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] &&
               error);
        pm_rejects++;
    }
    error = nil;
    pm_require([pixel prepareGeometry:fill
                                 offset:0
                                  count:fill.vertexCount
                               uniforms:&u
                               textures:bindings
                                   pass:pass
                              drawState:state
                            rasterClass:pm_class(fill)
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] != nil,
               error);
    assert(pm_computes == before);
    [commands cancel];
    for (unsigned submit = 0; submit < 2; submit++) {
        __weak NV2AMetalIndexedVertices *weakOwner;
        @autoreleasepool {
            PolygonModesInput *temporary =
                pm_input(commands.device, NV2AMetalPrimitiveTriangles, 2);
            weakOwner = temporary.owner;
            pm_require([commands beginWithError:&error] != nil, error);
            NSArray *results = pm_geometry(commands, geometry, temporary, 12,
                                           NV2AMetalPrimitiveTriangles, &config,
                                           YES, YES, NO, YES, &error);
            pm_require(results.count == 1, error);
            assert(((NV2AMetalGeometryResult *)results[0]).indexedVertices ==
                   temporary.owner);
        }
        @autoreleasepool {
            assert(weakOwner);
        }
        if (submit)
            pm_require([commands submitWithError:&error] &&
                           [commands waitUntilIdleWithError:&error],
                       error);
        else
            [commands cancel];
        assert(!weakOwner);
    }
}
static void polygon_modes_tests(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        pm_require(commands != nil, error);
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        pm_require(geometry != nil, error);
        pm_require([commands beginWithError:&error] != nil, error);
        Class cls = object_getClass(commands.commandBuffer);
        SEL selector = @selector(computeCommandEncoder);
        Method cm = class_getInstanceMethod(cls, selector);
        class_addMethod(cls, selector, method_getImplementation(cm),
                        method_getTypeEncoding(cm));
        cm = class_getInstanceMethod(cls, selector);
        pm_original_compute =
            (void *)method_setImplementation(cm, (IMP)pm_compute);
        [commands cancel];
        @try {
            for (unsigned samples = 1; samples <= 4; samples *= 4) {
                NV2AMetalPixelShader *pixel = [[NV2AMetalPixelShader alloc]
                    initWithDevice:commands.device
                       colorFormat:MTLPixelFormatRGBA8Unorm
                       depthFormat:MTLPixelFormatDepth32Float_Stencil8
                       sampleCount:samples
                             error:&error];
                pm_require(pixel != nil, error);
                if (samples == 1) {
                    pm_bounds(commands, geometry, pixel, NO);
                    pm_bounds(commands, geometry, pixel, YES);
                }
                for (unsigned primitive = NV2AMetalPrimitiveTriangles;
                     primitive <= NV2AMetalPrimitiveQuadStrip; primitive++) {
                    PolygonModesInput *input =
                        pm_input(commands.device, primitive, 2);
                    for (unsigned front = 0; front < 3; front++)
                        for (unsigned back = 0; back < 3; back++) {
                            if (front == NV2AMetalPolygonFill && back == front)
                                continue;
                            for (unsigned flags = 0; flags < 16; flags++) {
                                NV2AMetalGeometryRasterConfig c = {
                                    .front = front,
                                    .back = back,
                                    .frontClockwise = flags & 1,
                                    .cullFront =
                                        (flags & 6) == 2 || (flags & 6) == 6,
                                    .cullBack =
                                        (flags & 6) == 4 || (flags & 6) == 6,
                                    .lineWidth = 1,
                                    .viewportWidth = 32,
                                    .viewportHeight = 32
                                };
                                BOOL hasLine = front == NV2AMetalPolygonLine ||
                                               back == NV2AMetalPolygonLine;
                                pm_pair(commands, geometry, pixel, input, 12,
                                        primitive, c, flags ^ 4, samples,
                                        flags & 8 ? 1 : 0, YES, hasLine, NO);
                            }
                        }
                    /* The old mixed Fill/Point W-depth fallback is directly
                     * eligible now; retain its original configuration here. */
                    NV2AMetalGeometryRasterConfig mixedW = {
                        .front = NV2AMetalPolygonFill,
                        .back = NV2AMetalPolygonPoint,
                        .lineWidth = 1,
                        .viewportWidth = 32,
                        .viewportHeight = 32
                    };
                    pm_pair(commands, geometry, pixel, input, 6, primitive,
                            mixedW, 2, samples, 0, YES, NO, YES);
                    for (unsigned effect = 16; effect <= 64; effect *= 2) {
                        NV2AMetalGeometryRasterConfig c = {
                            .front = NV2AMetalPolygonPoint,
                            .back = NV2AMetalPolygonPoint,
                            .lineWidth = 1,
                            .viewportWidth = 32,
                            .viewportHeight = 32
                        };
                        pm_pair(commands, geometry, pixel, input, 12, primitive,
                                c, effect | 7, samples, 0, YES, NO, NO);
                    }
                    for (unsigned mode = NV2AMetalPolygonPoint;
                         mode <= NV2AMetalPolygonLine; mode++) {
                        NV2AMetalGeometryRasterConfig c = { .front = mode,
                                                            .back = mode,
                                                            .lineWidth = 1,
                                                            .viewportWidth = 32,
                                                            .viewportHeight =
                                                                32 };
                        for (unsigned count = 0; count <= 7; count++)
                            pm_pair(commands, geometry, pixel, input, count,
                                    primitive, c, 0, samples, 0, YES,
                                    mode == NV2AMetalPolygonLine, NO);
                        if (mode == NV2AMetalPolygonPoint) {
                            NV2AMetalGeometryRasterConfig mixed = c;
                            mixed.back = NV2AMetalPolygonFill;
                            for (unsigned count = 0; count <= 7; count++)
                                pm_pair(commands, geometry, pixel, input, count,
                                        primitive, mixed, 0, samples, 0, YES,
                                        NO, NO);
                        }
                        for (unsigned transport = 0; transport < 3;
                             transport++) {
                            PolygonModesInput *shifted =
                                pm_input(commands.device, primitive, transport);
                            pm_pair(commands, geometry, pixel, shifted, 12,
                                    primitive, c, 3, samples, 1, YES,
                                    mode == NV2AMetalPolygonLine, NO);
                        }
                        pm_pair(commands, geometry, pixel, input, 12, primitive,
                                c, 2, samples, 2, YES,
                                mode == NV2AMetalPolygonLine, NO);
                        c.polygonSmooth = YES;
                        pm_pair(commands, geometry, pixel, input, 12, primitive,
                                c, 1, samples, 0, YES,
                                mode == NV2AMetalPolygonLine, NO);
                        c.polygonSmooth = NO;
                        if (mode == NV2AMetalPolygonPoint)
                            pm_pair(commands, geometry, pixel, input, 12,
                                    primitive, c, 7, samples, 0, YES, NO, YES);
                        else
                            for (unsigned fallback = 0; fallback < 3;
                                 fallback++) {
                                NV2AMetalGeometryRasterConfig bad = c;
                                if (!fallback)
                                    bad.lineWidth = 3;
                                if (fallback == 1)
                                    bad.lineSmooth = YES;
                                pm_pair(commands, geometry, pixel, input, 12,
                                        primitive, bad, 1, samples, 0, NO, YES,
                                        fallback == 2);
                            }
                    }
                }
            }
        } @finally {
            method_setImplementation(cm, (IMP)pm_original_compute);
        }
        assert(pm_pairs && pm_direct && pm_fallback && pm_visible &&
               pm_rejects && pm_order_checks == 2);
        printf(
            "Polygon modes: %u exact color/depth/stencil/query GPU pairs; %u "
            "borrowed direct results/%u fallbacks; mixed primitive order, "
            "remaps, face/cull/provoker, slope, textures/fog and slices PASS\n",
            pm_pairs, pm_direct, pm_fallback);
    }
}
#endif
