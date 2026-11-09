/* Quad point/wire raster parity against the unchanged compute expansion.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_QUAD_RASTER_H
#define TEST_METAL_QUAD_RASTER_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"
static unsigned qr_computes, qr_pairs, qr_direct, qr_fallback, qr_rejects;
static uint64_t qr_visible, qr_avoided;
static id (*qr_original_compute)(id, SEL);
static id qr_compute(id object, SEL selector)
{
    qr_computes++;
    return qr_original_compute(object, selector);
}
static void qr_require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Quad raster: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
@interface QuadRasterInput : NSObject
@property(nonatomic) NSData *logical;
@property(nonatomic) id<MTLBuffer> linear, physical;
@property(nonatomic) NV2AMetalIndexedVertices *owner;
@property(nonatomic) NSUInteger first;
@end
@implementation QuadRasterInput
@end
static QuadRasterInput *qr_input(id<MTLDevice> device, BOOL strip,
                                 unsigned transport)
{
    NV2AMetalVertex records[12] = { 0 };
    const float listXY[8][2] = { { 3, 3 },  { 14, 3 },  { 14, 15 }, { 3, 15 },
                                 { 18, 4 }, { 18, 20 }, { 29, 20 }, { 29, 4 } };
    const float stripXY[6][2] = { { 3, 3 },   { 3, 17 }, { 14, 3 },
                                  { 14, 17 }, { 28, 3 }, { 28, 17 } };
    const float z[4] = { 0x300000, 0x480000, 0x900000, 0xc00000 };
    for (unsigned i = 0; i < 12; i++) {
        NV2AMetalVertex *v = &records[i];
        const float *xy = strip ? stripXY[i % 6] : listXY[i % 8];
        v->screen[0] = xy[0];
        v->screen[1] = xy[1];
        v->screen[2] = z[i % 4];
        v->screen[3] = .5f + (i % 4) / 8.f;
        v->clip[0] = xy[0] / 16 - 1;
        v->clip[1] = 1 - xy[1] / 16;
        v->clip[2] = .25f;
        v->clip[3] = 1;
        v->point_size = 1 + i % 3;
        for (unsigned k = 0; k < 4; k++) {
            v->color[0][k] = k == 3 ? 1 : (float)((i + k * 2) % 5) / 4;
            v->color[2][k] = k == 3 ? 1 : 1 - v->color[0][k];
            v->color[1][k] = v->color[3][k] = 0;
            v->texcoord[3][k] = (float)(i + k) / 16;
            for (unsigned p = 0; p < 3; p++)
                v->plane[p][k] = 100 + p + k;
        }
        v->face = NV2AMetalFaceBack;
        v->slope = 999;
    }
    /* Real repeated transformed records, not just a nonidentity permutation. */
    for (unsigned i = strip ? 6 : 8; i < 12; i++)
        records[i] = records[i - (strip ? 6 : 8)];
    QuadRasterInput *input = [QuadRasterInput new];
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
        NSUInteger uniqueCount = strip ? 6 : 8;
        id<MTLBuffer> physical =
            [device newBufferWithLength:uniqueCount * sizeof(*records)
                                options:MTLResourceStorageModeShared];
        NSMutableData *mapping =
            [NSMutableData dataWithLength:17 * sizeof(uint32_t)];
        uint32_t *map = mapping.mutableBytes;
        for (NSUInteger i = 0; i < uniqueCount; i++)
            ((NV2AMetalVertex *)physical.contents)[uniqueCount - i - 1] =
                records[i];
        for (NSUInteger i = 0; i < 12; i++)
            map[i + 5] = (uint32_t)(uniqueCount - i % uniqueCount - 1);
        NSError *error = nil;
        input.owner =
            [[NV2AMetalIndexedVertices alloc] initWithVertices:physical
                                                 physicalCount:uniqueCount
                                                         remap:mapping
                                                         error:&error];
        qr_require(input.owner != nil, error);
        input.physical = physical;
        assert(input.owner.physicalVertexCount < 12 &&
               input.physical.length == uniqueCount * sizeof(*records));
    }
    assert(input.linear && input.physical);
    return input;
}
static id<MTLTexture> qr_texture(id<MTLDevice> device, MTLPixelFormat format,
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
static NV2AMetalPixelRasterClass qr_class(NV2AMetalGeometryResult *g)
{
    return g.directQuadOptions ?
               (NV2AMetalPixelRasterClass)(NV2AMetalPixelRasterDirectTriangle |
                                           g.directQuadOptions) :
           g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
           g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
                                NV2AMetalPixelRasterNative;
}
static NSArray<NV2AMetalGeometryResult *> *
qr_geometry(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
            QuadRasterInput *input, NSUInteger count,
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
static NSData *qr_frame(NV2AMetalCommands *commands,
                        NV2AMetalGeometry *geometry,
                        NV2AMetalPixelShader *pixel, QuadRasterInput *input,
                        NSUInteger count, enum NV2AMetalPrimitive primitive,
                        NV2AMetalGeometryRasterConfig config, BOOL smooth,
                        BOOL first, BOOL w, BOOL two, BOOL depthOffset,
                        BOOL scale, unsigned samples, unsigned slicePlan,
                        BOOL direct, BOOL expectedDirect, BOOL wire,
                        uint64_t *visible)
{
    NSError *error = nil;
    id<MTLTexture> color =
        qr_texture(commands.device, MTLPixelFormatRGBA8Unorm, samples);
    id<MTLTexture> depth =
        qr_texture(commands.device, MTLPixelFormatDepth32Float, samples);
    id<MTLTexture> resolve =
        samples == 1 ? color :
                       qr_texture(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&initial
                                     length:8
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:16384
                                     options:MTLResourceStorageModeShared];
    assert(query && readback);
    memset(readback.contents, 0x5a, readback.length);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = smooth;
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
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    qr_require(state != nil, error);
    qr_require([commands beginWithError:&error] != nil, error);
    unsigned before = qr_computes;
    NSArray<NV2AMetalGeometryResult *> *gs =
        qr_geometry(commands, geometry, input, count, primitive, &config,
                    smooth, first, w, direct, &error);
    qr_require(gs != nil, error);
    NSUInteger primitives = primitive == NV2AMetalPrimitiveQuads ? count / 4 :
                            count < 4 ? 0 :
                                        count / 2 - 1;
    NSUInteger generated = primitives * (wire ? 8 : 4);
    if (direct && expectedDirect) {
        assert(gs.count == 1 && qr_computes == before);
        NV2AMetalGeometryResult *g = gs[0];
        assert(g.vertexCount == generated && !g.expandedLines &&
               !g.expandedPolygons && !g.directPoints && !g.directTriangles &&
               !g.directLineMode);
        if (generated) {
            assert(g.directQuadOptions && g.vertices == input.physical &&
                   g.indexedVertices == input.owner &&
                   g.sourceVertexCount ==
                       (primitive == NV2AMetalPrimitiveQuads ? count / 4 * 4 :
                                                               count / 2 * 2) &&
                   g.firstVertex == (input.owner ? 0 : input.first) &&
                   g.indexOffset == (input.owner ? input.first : 0));
            qr_direct++;
        }
    } else if (direct) {
        for (NV2AMetalGeometryResult *g in gs)
            assert(!g.directQuadOptions);
        qr_fallback++;
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
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    qr_require([commands addResource:query error:&error], error);
    qr_require([commands addResource:color error:&error] &&
                   [commands addResource:depth error:&error] &&
                   [commands addResource:resolve error:&error],
               error);
    NV2AMetalPixelTexture bindings[4] = { 0 };
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    BOOL mixed = gs.count > 1;
    NSUInteger rounds =
        mixed ? ((NV2AMetalGeometryResult *)gs[0]).primitiveCount : 1;
    for (NSUInteger p = 0; p < rounds; p++)
        for (NV2AMetalGeometryResult *g in gs) {
            if (!g.vertexCount)
                continue;
            NSUInteger firstDraw = mixed          ? p * g.verticesPerPrimitive :
                                   slicePlan == 1 ? 1 :
                                   slicePlan == 2 ? (wire ? 4 : 3) :
                                                    0;
            NSUInteger drawCount = mixed          ? g.verticesPerPrimitive :
                                   slicePlan == 1 ? g.vertexCount - 2 :
                                   slicePlan == 2 ? (wire ? 2 : 1) :
                                                    g.vertexCount;
            if (firstDraw > g.vertexCount ||
                drawCount > g.vertexCount - firstDraw)
                continue;
            qr_require(
                [pixel encodeGeometry:g
                                  offset:firstDraw * sizeof(NV2AMetalVertex)
                                   count:drawCount
                                uniforms:&u
                                textures:bindings
                                    pass:pass
                               drawState:state
                             rasterClass:qr_class(g)
                    ignorePolygonCulling:g.expandedLines || g.expandedPolygons
                           renderEncoder:encoder
                                commands:commands
                                   error:&error],
                error);
            if (!direct && expectedDirect)
                qr_avoided += g.vertices.length;
        }
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    qr_require([commands addResource:readback error:&error], error);
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
            destinationBytesPerImage:8192];
    [copy endEncoding];
    qr_require([commands submitWithError:&error] &&
                   [commands waitUntilIdleWithError:&error],
               error);
    *visible = *(const uint64_t *)query.contents;
    return [NSData dataWithBytes:readback.contents length:readback.length];
}
static void qr_pair(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                    NV2AMetalPixelShader *pixel, QuadRasterInput *input,
                    NSUInteger count, enum NV2AMetalPrimitive primitive,
                    NV2AMetalGeometryRasterConfig config, unsigned shading,
                    unsigned samples, unsigned slicePlan, BOOL expectedDirect,
                    BOOL wire, BOOL w)
{
    uint64_t queries[2];
    NSData *frames[2];
    for (unsigned direct = 0; direct < 2; direct++)
        frames[direct] = qr_frame(
            commands, geometry, pixel, input, count, primitive, config,
            shading & 1, shading & 2, w, shading & 4, shading & 2, shading & 1,
            samples, slicePlan, direct, expectedDirect, wire, &queries[direct]);
    if (queries[0] != queries[1] || ![frames[0] isEqualToData:frames[1]]) {
        fprintf(stderr,
                "Quad raster mismatch wire%d primitive%u count%lu samples%u "
                "shading%u slice%u direct%d w%d front%d back%d cull%d%d cw%d "
                "query%llu/%llu\n",
                wire, primitive, (unsigned long)count, samples, shading,
                slicePlan, expectedDirect, w, config.front, config.back,
                config.cullFront, config.cullBack, config.frontClockwise,
                (unsigned long long)queries[0], (unsigned long long)queries[1]);
        abort();
    }
    qr_visible += queries[1] - 7;
    qr_pairs++;
}
static void qr_bounds(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                      NV2AMetalPixelShader *pixel, BOOL wire)
{
    NSError *error = nil;
    QuadRasterInput *input = qr_input(commands.device, NO, 2);
    NV2AMetalGeometryRasterConfig config = {
        .front = wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
        .back = wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
        .lineWidth = 1,
        .viewportWidth = 32,
        .viewportHeight = 32
    };
    qr_require([commands beginWithError:&error] != nil, error);
    unsigned before = qr_computes;
    NSArray<NV2AMetalGeometryResult *> *gs =
        qr_geometry(commands, geometry, input, 12, NV2AMetalPrimitiveQuads,
                    &config, YES, YES, NO, YES, &error);
    qr_require(gs.count == 1, error);
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
                                    primitive:NV2AMetalPrimitiveQuads
                                       config:&config
                                       smooth:NO
                               firstProvoking:NO
                                 zPerspective:NO
                                     commands:commands
                                        error:&error] &&
               error);
        qr_rejects++;
    }
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:12
                                                error:&error];
    qr_require([stream appendIndexedVertices:input.owner
                                       first:5
                                       count:12
                                       error:&error],
               error);
    NV2AMetalVertexSlice *slice =
        [stream encodeSliceForDrawingWithCommands:commands error:&error];
    qr_require(slice != nil, error);
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        [slice setValue:invalid == 0 ? @13 : @12 forKey:@"vertexCount"];
        [slice setValue:invalid == 1 ? @(NSUIntegerMax) : @5
                 forKey:@"firstVertex"];
        [slice setValue:invalid == 2 ? input.linear : input.physical
                 forKey:@"buffer"];
        error = nil;
        assert(![geometry encodeNativeRasterSlice:slice
                                        primitive:NV2AMetalPrimitiveQuads
                                           config:&config
                                           smooth:NO
                                   firstProvoking:NO
                                     zPerspective:NO
                                         commands:commands
                                            error:&error] &&
               error);
        qr_rejects++;
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
    qr_require(state != nil, error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture =
        qr_texture(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture =
        qr_texture(commands.device, MTLPixelFormatDepth32Float, 1);
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
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
                        rasterClass:qr_class(g)
               ignorePolygonCulling:NO
                           commands:commands
                              error:&error] &&
           error);
    qr_rejects++;
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
                            rasterClass:qr_class(g)
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] &&
               error);
        qr_rejects++;
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
                     rasterClass:qr_class(g)
            ignorePolygonCulling:NO
                        commands:commands
                           error:&error];
    qr_require(empty != nil, error);
    assert(!empty.vertexCount && qr_computes == before);
    [commands cancel];
    for (unsigned submit = 0; submit < 2; submit++) {
        __weak NV2AMetalIndexedVertices *weakOwner;
        @autoreleasepool {
            QuadRasterInput *temporary = qr_input(commands.device, NO, 2);
            weakOwner = temporary.owner;
            qr_require([commands beginWithError:&error] != nil, error);
            NSArray *results = qr_geometry(commands, geometry, temporary, 12,
                                           NV2AMetalPrimitiveQuads, &config,
                                           YES, YES, NO, YES, &error);
            qr_require(results.count == 1, error);
            assert(((NV2AMetalGeometryResult *)results[0]).indexedVertices ==
                   temporary.owner);
        }
        @autoreleasepool {
            assert(weakOwner);
        }
        if (submit)
            qr_require([commands submitWithError:&error] &&
                           [commands waitUntilIdleWithError:&error],
                       error);
        else
            [commands cancel];
        assert(!weakOwner);
    }
}
static void quad_raster_tests(BOOL wire)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        qr_require(commands != nil, error);
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        qr_require(geometry != nil, error);
        qr_require([commands beginWithError:&error] != nil, error);
        Class cls = object_getClass(commands.commandBuffer);
        SEL selector = @selector(computeCommandEncoder);
        Method cm = class_getInstanceMethod(cls, selector);
        class_addMethod(cls, selector, method_getImplementation(cm),
                        method_getTypeEncoding(cm));
        cm = class_getInstanceMethod(cls, selector);
        qr_original_compute =
            (void *)method_setImplementation(cm, (IMP)qr_compute);
        [commands cancel];
        @try {
            for (unsigned samples = 1; samples <= 4; samples *= 4) {
                NV2AMetalPixelShader *pixel = [[NV2AMetalPixelShader alloc]
                    initWithDevice:commands.device
                       colorFormat:MTLPixelFormatRGBA8Unorm
                       depthFormat:MTLPixelFormatDepth32Float
                       sampleCount:samples
                             error:&error];
                qr_require(pixel != nil, error);
                if (samples == 1)
                    qr_bounds(commands, geometry, pixel, wire);
                for (unsigned topology = 0; topology < 2; topology++) {
                    enum NV2AMetalPrimitive primitive =
                        topology ? NV2AMetalPrimitiveQuadStrip :
                                   NV2AMetalPrimitiveQuads;
                    for (unsigned face = 0; face < 8; face++)
                        for (unsigned shading = 0; shading < 8; shading++)
                            @autoreleasepool {
                                unsigned transport = (face + shading) % 3;
                                QuadRasterInput *input = qr_input(
                                    commands.device, topology, transport);
                                NV2AMetalGeometryRasterConfig config = {
                                    .front = wire ? NV2AMetalPolygonLine :
                                                    NV2AMetalPolygonPoint,
                                    .back = wire ? NV2AMetalPolygonLine :
                                                   NV2AMetalPolygonPoint,
                                    .frontClockwise = face & 1,
                                    .cullFront = face & 2,
                                    .cullBack = face & 4,
                                    .lineWidth = 1,
                                    .viewportWidth = 32,
                                    .viewportHeight = 32
                                };
                                qr_pair(commands, geometry, pixel, input, 12,
                                        primitive, config, shading, samples,
                                        (face + shading / 2) % 3, YES, wire,
                                        !wire && !!(shading & 4));
                            }
                    /* Isolate the fourth point / a second-plane edge. Enabled
                     * depth writes and nonzero depth factor make plane1/plane2
                     * substitutions visible without occlusion by other draws.
                     */
                    QuadRasterInput *probe =
                        qr_input(commands.device, topology, 2);
                    NV2AMetalGeometryRasterConfig probeConfig = {
                        .front =
                            wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
                        .back =
                            wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
                        .lineWidth = 1,
                        .viewportWidth = 32,
                        .viewportHeight = 32
                    };
                    qr_pair(commands, geometry, pixel, probe, 4, primitive,
                            probeConfig, 2, samples, 2, YES, wire, NO);
                    qr_pair(commands, geometry, pixel, probe, 4, primitive,
                            probeConfig, 3, samples, 0, YES, wire, NO);
                    probeConfig.polygonSmooth = YES;
                    qr_pair(commands, geometry, pixel, probe, 12, primitive,
                            probeConfig, 3, samples, 0, YES, wire, NO);
                    const NSUInteger incomplete[] = { 0, 1, 2, 3, 4,  5,
                                                      6, 7, 8, 9, 10, 11 };
                    QuadRasterInput *input =
                        qr_input(commands.device, topology, 2);
                    NV2AMetalGeometryRasterConfig config = {
                        .front =
                            wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
                        .back =
                            wire ? NV2AMetalPolygonLine : NV2AMetalPolygonPoint,
                        .lineWidth = 1,
                        .viewportWidth = 32,
                        .viewportHeight = 32
                    };
                    for (unsigned n = 0;
                         n < sizeof(incomplete) / sizeof(incomplete[0]); n++)
                        qr_pair(commands, geometry, pixel, input, incomplete[n],
                                primitive, config, 0, samples, 0, YES, wire,
                                NO);
                    for (unsigned fallback = 0; fallback < (wire ? 5u : 2u);
                         fallback++) {
                        NV2AMetalGeometryRasterConfig c = config;
                        if (wire && fallback == 0)
                            c.lineWidth = 3;
                        else if (wire && fallback == 1)
                            c.lineSmooth = YES;
                        else if (!wire)
                            c.back = fallback ? NV2AMetalPolygonFill :
                                                NV2AMetalPolygonLine;
                        else if (fallback >= 3)
                            c.back = fallback & 1 ? NV2AMetalPolygonFill :
                                                    NV2AMetalPolygonPoint;
                        if ((!wire && fallback == 0) || (wire && fallback == 4))
                            c.lineWidth = 3;
                        if ((!wire && fallback == 1) || (wire && fallback == 3))
                            c.polygonSmooth = YES;
                        qr_pair(commands, geometry, pixel, input, 12, primitive,
                                c, 1, samples, 0, NO, wire,
                                wire && fallback == 2);
                    }
                }
            }
        } @finally {
            method_setImplementation(cm, (IMP)qr_original_compute);
        }
        assert(qr_pairs && qr_direct && qr_fallback && qr_visible &&
               qr_rejects);
        printf("Quad %s raster: %u exact color/query pairs (single-sample "
               "depth exact), %u borrowed direct results, %u fallbacks, %llu "
               "visible samples; tight indexed duplicates/offsets, "
               "face/cull/winding, colors/provoker, nonplanar depth slope, "
               "MSAA/scale and slices PASS\n",
               wire ? "wire" : "points", qr_pairs, qr_direct, qr_fallback,
               (unsigned long long)qr_visible);
    }
}
#endif
