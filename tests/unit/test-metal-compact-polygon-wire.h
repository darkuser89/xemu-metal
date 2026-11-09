/* Polygon wire carriers versus the unchanged full-record compute transport.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_POLYGON_WIRE_H
#define TEST_METAL_COMPACT_POLYGON_WIRE_H

typedef struct CompactPolygonCase {
    CompactLineCase line;
    unsigned faceFlags, mixed;
    NSUInteger first, length;
} CompactPolygonCase;
@interface CompactPolygonOutput : NSObject
@property(nonatomic) NSData *pixels, *source;
@property(nonatomic) NSArray<NSData *> *records;
@property(nonatomic) NSArray<NV2AMetalGeometryResult *> *results;
@property(nonatomic) CompactLineInput *input;
@property(nonatomic) uint64_t query;
@end
@implementation CompactPolygonOutput
@end
static unsigned cpw_pairs, cpw_pack, cpw_fill_pack, cpw_expand, cpw_gather,
    cpw_face;
static void cpw_dispatch(id object, SEL selector, MTLSize threads,
                         MTLSize group)
{
    NSString *name =
        cl_encoders[[NSValue valueWithPointer:(__bridge const void *)object]];
    if (cl_observe) {
        cpw_pack +=
            [name isEqualToString:@"nv2a_compact_polygon_lines"] ||
            [name isEqualToString:@"nv2a_compact_indexed_polygon_lines"];
        cpw_fill_pack +=
            [name isEqualToString:@"nv2a_compact_polygon_fill"] ||
            [name isEqualToString:@"nv2a_compact_indexed_polygon_fill"];
        cpw_expand += [name isEqualToString:@"nv2a_expand_geometry"];
        cpw_gather += [name isEqualToString:@"nv2a_vertex_stream_gather"];
        cpw_face += [name isEqualToString:@"nv2a_polygon_face"] ||
                    [name isEqualToString:@"nv2a_direct_polygon_face"] ||
                    [name isEqualToString:@"nv2a_direct_indexed_polygon_face"];
    }
    cl_dispatch(object, selector, threads, group);
}
static NSUInteger cpw_primitives(enum NV2AMetalPrimitive primitive,
                                 NSUInteger n)
{
    return primitive == NV2AMetalPrimitiveTriangles ? n / 3 :
           primitive == NV2AMetalPrimitiveQuads     ? n / 4 :
           primitive == NV2AMetalPrimitiveQuadStrip ? (n < 4 ? 0 : n / 2 - 1) :
           primitive == NV2AMetalPrimitivePolygon   ? (n < 2 ? 0 : n) :
           n < 3                                    ? 0 :
                                                      n - 2;
}
static NSUInteger cpw_edges(enum NV2AMetalPrimitive primitive)
{
    return primitive == NV2AMetalPrimitivePolygon ? 1 :
           primitive == NV2AMetalPrimitiveQuads ||
                   primitive == NV2AMetalPrimitiveQuadStrip ?
                                                    4 :
                                                    3;
}
static CompactLineInput *cpw_input(NV2AMetalCommands *commands,
                                   CompactLineCase c)
{
    CompactLineInput *input = cl_input(commands, c.scene < 10 ? c.transport : 0,
                                       c.scene < 10 ? c.scene : 0, c.count);
    if (c.scene >= 10) {
        NV2AMetalVertex *v = input.source.contents;
        if (c.scene == 10) {
            // Two distinct quad depth planes, with visible edges on both.
            const float xy[4][2] = {
                { 4.5, 4.5 }, { 27.5, 4.5 }, { 27.5, 27.5 }, { 4.5, 27.5 }
            };
            for (unsigned i = 0; i < 4; i++) {
                v[i].screen[0] = xy[i][0];
                v[i].screen[1] = xy[i][1];
                v[i].screen[2] = (float[]){ 10000, 18000, 24000, 50000 }[i];
                v[i].clip[0] = (xy[i][0] / 16 - 1) * v[i].screen[3];
                v[i].clip[1] = (1 - xy[i][1] / 16) * v[i].screen[3];
            }
        } else if (c.scene == 11) {
            // First fan area is zero; a later boundary triangle picks face.
            for (unsigned i = 0; i < 3; i++) {
                v[i].screen[0] = 3.5f + 10 * i;
                v[i].screen[1] = 4.5f;
                v[i].clip[0] = (v[i].screen[0] / 16 - 1) * v[i].screen[3];
                v[i].clip[1] = (1 - v[i].screen[1] / 16) * v[i].screen[3];
            }
        } else if (c.scene == 12) {
            // Valid XY coverage but nonfinite plane slope must become zero.
            v[0].screen[2] = INFINITY;
            v[1].screen[2] = NAN;
        } else if (c.scene == 13) {
            // Degenerate screen plane without collapsing the clip-space line.
            for (unsigned i = 0; i < 4; i++)
                v[i].screen[1] = 12;
        }
    }
    return input;
}
static NSArray<NV2AMetalGeometryResult *> *
cpw_geometry(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
             CompactLineInput *input, CompactPolygonCase c, BOOL direct)
{
    NV2AMetalGeometryRasterConfig config = {
        .front = c.mixed == 1 ? NV2AMetalPolygonFill :
                 c.mixed == 2 ? NV2AMetalPolygonPoint :
                                NV2AMetalPolygonLine,
        .back = NV2AMetalPolygonLine,
        .frontClockwise = !!(c.faceFlags & 1),
        .cullFront = !!(c.faceFlags & 2),
        .cullBack = !!(c.faceFlags & 4),
        .lineWidth = c.line.width,
        .lineSmooth = c.line.smoothLine,
        .polygonSmooth = c.mixed == 3,
        .viewportWidth = 32,
        .viewportHeight = 32
    };
    if (c.mixed == 3)
        config.front = NV2AMetalPolygonFill;
    NSError *error = nil;
    NSArray *results;
    cl_observe = YES;
    if (direct && input.owner) {
        NV2AMetalVertexStream *stream =
            [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                    limit:input.count
                                                    error:&error];
        cl_require(stream && [stream appendIndexedVertices:input.owner
                                                     first:input.first
                                                     count:input.count
                                                     error:&error],
                   error);
        NV2AMetalVertexSlice *slice =
            [stream encodeSliceForDrawingWithCommands:commands error:&error];
        cl_require(slice != nil, error);
        results = [geometry encodeNativeRasterSlice:slice
                                          primitive:c.line.primitive
                                             config:&config
                                             smooth:c.line.smooth
                                     firstProvoking:c.line.first
                                       zPerspective:c.line.w
                                           commands:commands
                                              error:&error];
    } else {
        id<MTLBuffer> source = input.source;
        NSUInteger first = input.first;
        if (!direct && input.owner && input.count) {
            NV2AMetalVertexStream *stream =
                [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                        limit:input.count
                                                        error:&error];
            cl_require(stream && [stream appendIndexedVertices:input.owner
                                                         first:first
                                                         count:input.count
                                                         error:&error],
                       error);
            source = [stream encodeWithCommands:commands error:&error];
            cl_require(source != nil, error);
            first = 0;
        }
        results = direct ? [geometry encodeNativeRasterVertices:source
                                                          first:first
                                                          count:input.count
                                                      primitive:c.line.primitive
                                                         config:&config
                                                         smooth:c.line.smooth
                                                 firstProvoking:c.line.first
                                                   zPerspective:c.line.w
                                                       commands:commands
                                                          error:&error] :
                           [geometry encodeRasterVertices:source
                                                    first:first
                                                    count:input.count
                                                primitive:c.line.primitive
                                                   config:&config
                                                   smooth:c.line.smooth
                                           firstProvoking:c.line.first
                                             zPerspective:c.line.w
                                                 commands:commands
                                                    error:&error];
    }
    cl_observe = NO;
    cl_require(results.count == (c.mixed ? 2u : 1u), error);
    return results;
}
static NV2AMetalPixelRasterClass cpw_class(NV2AMetalGeometryResult *g)
{
    return g.compactPolygons ?
               NV2AMetalPixelRasterCompactPolygon :
           g.compactLines ?
               NV2AMetalPixelRasterCompactLine :
           g.directTriangles ?
               NV2AMetalPixelRasterDirectTriangle | g.directTriangleOptions :
           g.directQuadOptions ?
               NV2AMetalPixelRasterDirectTriangle | g.directQuadOptions :
           g.directPolygonOptions ?
               NV2AMetalPixelRasterDirectTriangle | g.directPolygonOptions :
           g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
           g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
                                NV2AMetalPixelRasterNative;
}
static CompactPolygonOutput *cpw_render(NV2AMetalCommands *commands,
                                        NV2AMetalGeometry *geometry,
                                        id<MTLTexture> pattern,
                                        CompactPolygonCase c, BOOL direct)
{
    NSError *error = nil;
    cl_require([commands beginWithError:&error] != nil, error);
    CompactLineInput *input = cpw_input(commands, c.line);
    unsigned pack = cpw_pack, fill = cpw_fill_pack, expand = cpw_expand,
             gather = cpw_gather, face = cpw_face;
    NSArray<NV2AMetalGeometryResult *> *results =
        cpw_geometry(commands, geometry, input, c, direct);
    NSUInteger polygons = cpw_primitives(c.line.primitive, c.line.count),
               edges = cpw_edges(c.line.primitive);
    NV2AMetalGeometryResult *wire = results.lastObject;
    assert(wire.vertexCount == polygons * edges * 6 &&
           wire.polygonMode == NV2AMetalPolygonLine);
    if (direct) {
        assert(wire.compactLines && wire.expandedLines &&
               !wire.expandedPolygons &&
               wire.sourcePrimitive == c.line.primitive &&
               wire.verticesPerPrimitive == edges * 6 &&
               wire.primitiveCount == polygons &&
               wire.lineCoverage.length ==
                   polygons * edges * sizeof(NV2AMetalCompactLine));
        assert(cpw_pack - pack == !!polygons &&
               cpw_fill_pack - fill == (c.mixed == 3 && polygons ? 1u : 0u) &&
               cpw_expand == expand && cpw_gather == gather);
        assert(cpw_face - face ==
               (c.line.primitive == NV2AMetalPrimitivePolygon && polygons ?
                    1u :
                    0u));
        if (polygons) {
            NSUInteger used = c.line.primitive == NV2AMetalPrimitiveTriangles ?
                                  c.line.count / 3 * 3 :
                              c.line.primitive == NV2AMetalPrimitiveQuads ?
                                  c.line.count / 4 * 4 :
                              c.line.primitive == NV2AMetalPrimitiveQuadStrip ?
                                  c.line.count / 2 * 2 :
                                  c.line.count;
            assert(wire.vertices == input.source &&
                   wire.indexedVertices == input.owner &&
                   wire.sourceVertexCount == used &&
                   wire.physicalVertexCount ==
                       (input.owner ? input.owner.physicalVertexCount : used) &&
                   wire.firstVertex == (input.owner ? 0 : input.first) &&
                   wire.indexOffset == (input.owner ? input.first : 0) &&
                   wire.lineCoverage.storageMode == MTLStorageModePrivate &&
                   !wire.polygonFacing &&
                   [wire canUseLineCoverageForCommands:commands]);
        } else
            assert(!wire.vertices && !wire.lineCoverage &&
                   !wire.indexedVertices && !wire.sourceVertexCount &&
                   !wire.physicalVertexCount);
    } else
        assert(!wire.compactLines && cpw_pack == pack &&
               cpw_fill_pack == fill &&
               cpw_expand - expand == (polygons ? results.count : 0u) &&
               cpw_gather - gather == (input.owner && input.count ? 1u : 0u));
    NSMutableArray *geometryReadbacks = [NSMutableArray new];
    for (NV2AMetalGeometryResult *g in results)
        [geometryReadbacks
            addObject:
                cl_copy(commands, g.compactLines ? g.lineCoverage :
                                  g.compactPolygons ? g.polygonCoverage : g.vertices) ?:
                    (id)[NSNull null]];
    id<MTLBuffer> originalReadback = cl_copy(commands, input.source);
    if (!cl_pixels[c.line.samples > 1])
        cl_pixels[c.line.samples > 1] = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA8Unorm
               depthFormat:MTLPixelFormatDepth32Float_Stencil8
               sampleCount:c.line.samples
                     error:&error];
    NV2AMetalPixelShader *pixel = cl_pixels[c.line.samples > 1];
    cl_require(pixel != nil, error);
    id<MTLTexture> color =
                       cl_attachment(commands.device, MTLPixelFormatRGBA8Unorm,
                                     c.line.samples),
                   depth = cl_attachment(commands.device,
                                         MTLPixelFormatDepth32Float_Stencil8,
                                         c.line.samples);
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&initial
                                     length:8
                                    options:MTLResourceStorageModeShared];
    assert(query);
    cl_require([commands addResource:query error:&error], error);
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
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] =
        c.line.profile == 1 ? PS_REGISTER_T0 :
        c.line.profile == 2 ? (PS_REGISTER_FOG | PS_CHANNEL_ALPHA) :
        c.line.profile == 3 ? PS_REGISTER_V1 :
                              PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = c.line.smooth;
    u.two_side = 1;
    u.z_perspective = c.line.w;
    u.depth_format =
        (unsigned[]){ NV2AMetalPixelDepthD16, NV2AMetalPixelDepthD24,
                      NV2AMetalPixelDepthF16,
                      NV2AMetalPixelDepthF24 }[c.line.profile % 4];
    u.depth_offset = 128;
    u.depth_factor = 1.5f;
    u.surface_scale[0] = c.line.profile & 1 ? 2 : 1;
    u.surface_scale[1] = c.line.profile & 1 ? 3 : 1;
    u.clip_range[1] = u.clip_range[3] = 16777215;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 32;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
        u.fog_color[i] = i / 4.f;
    }
    NV2AMetalPixelTexture textures[4] = { 0 };
    if (c.line.profile == 1) {
        u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
        u.textures[0].sampling =
            (NV2AMetalSamplingUniforms){ .enabled = 1,
                                         .address = { 1, 1, 3 },
                                         .min_linear = 1,
                                         .mag_linear = 1,
                                         .mip_filter = 2,
                                         .anisotropy = 4 };
        textures[0].texture = pattern;
    }
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
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    cl_require(state != nil, error);
    NSMutableArray *draws = [NSMutableArray new];
    for (NV2AMetalGeometryResult *g in results) {
        if (!g.vertexCount) {
            [draws addObject:[NSNull null]];
            continue;
        }
        NSUInteger start = c.length ? c.first : 0,
                   count = c.length ? c.length : g.vertexCount;
        NV2AMetalPixelDraw *prepared = [pixel
                 prepareGeometry:g
                          offset:direct ? start * sizeof(NV2AMetalVertex) : 0
                           count:direct ? count : g.vertexCount
                        uniforms:&u
                        textures:textures
                            pass:pass
                       drawState:state
                     rasterClass:cpw_class(g)
            ignorePolygonCulling:g.expandedLines || g.expandedPolygons
                        commands:commands
                           error:&error];
        cl_require(prepared != nil, error);
        if (!direct && c.length) {
            [prepared setValue:@(start) forKey:@"firstVertex"];
            [prepared setValue:@(count) forKey:@"vertexCount"];
        }
        [draws addObject:prepared];
    }
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    BOOL slicedModes = c.mixed && c.line.primitive != NV2AMetalPrimitivePolygon;
    for (NSUInteger p = 0; p < (slicedModes ? results[0].primitiveCount : 1);
         p++)
        for (NSUInteger mode = 0; mode < results.count; mode++) {
            if (draws[mode] == [NSNull null])
                continue;
            NV2AMetalPixelDraw *draw = draws[mode];
            NV2AMetalGeometryResult *g = results[mode];
            cl_require(
                slicedModes ?
                    [draw encodeWithRenderEncoder:e
                                         commands:commands
                                      firstVertex:p * g.verticesPerPrimitive
                                      vertexCount:g.verticesPerPrimitive
                                            error:&error] :
                    [draw encodeWithRenderEncoder:e
                                         commands:commands
                                            error:&error],
                error);
        }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    id<MTLBuffer> readback = cl_read(commands, color, depth, c.line.samples);
    cl_require([commands submitWithError:&error] &&
                   [commands waitUntilIdleWithError:&error],
               error);
    CompactPolygonOutput *result = [CompactPolygonOutput new];
    result.input = input;
    result.results = results;
    result.query = *(const uint64_t *)query.contents;
    result.pixels = [NSData dataWithBytes:readback.contents
                                   length:readback.length];
    result.source = [NSData dataWithBytes:originalReadback.contents
                                   length:originalReadback.length];
    NSMutableArray *records = [NSMutableArray new];
    for (id item in geometryReadbacks) {
        if (item == [NSNull null])
            [records addObject:[NSData data]];
        else {
            id<MTLBuffer> buffer = item;
            [records addObject:[NSData dataWithBytes:buffer.contents
                                              length:buffer.length]];
        }
    }
    result.records = records;
    return result;
}
static unsigned cpw_valid, cpw_plane2, cpw_sanitized;
static void cpw_packets(CompactPolygonOutput *candidate,
                        CompactPolygonOutput *reference, CompactPolygonCase c)
{
    NSData *packets = candidate.records.lastObject,
           *expanded = reference.records.lastObject;
    NSUInteger n = candidate.results.lastObject.vertexCount / 6;
    assert(packets.length == n * sizeof(NV2AMetalCompactLine) &&
           expanded.length >= n * 6 * sizeof(NV2AMetalVertex));
    const NV2AMetalCompactLine *p = packets.bytes;
    const NV2AMetalVertex *v = expanded.bytes;
    const NV2AMetalVertex *source = candidate.source.bytes;
    if (!candidate.input.owner)
        source += candidate.input.first;
    for (NSUInteger i = 0; i < n; i++) {
        const NV2AMetalVertex *r = v + 6 * i;
        assert(!!p[i].valid == (r[0].line_raster[2] == 1));
        for (unsigned k = 0; k < 3; k++)
            assert(!p[i].reserved[k]);
        if (!p[i].valid)
            continue;
        cpw_valid++;
        const unsigned order[] = { 0, 1, 2, 5 };
        for (unsigned k = 0; k < 4; k++)
            assert(!memcmp(p[i].clip[k], r[order[k]].clip, 8));
        assert(!memcmp(p[i].p0, r[0].plane[0], 16) &&
               !memcmp(p[i].p1, r[0].plane[1], 16) &&
               !memcmp(p[i].p2, r[0].plane[2], 16) &&
               !memcmp(&p[i].slope, &r[0].slope, 4) && isfinite(p[i].slope) &&
               p[i].face == r[0].face && p[i].width == r[0].line_raster[0] &&
               p[i].smooth == (unsigned)r[0].line_raster[1] &&
               p[i].color_smooth == c.line.smooth);
        NSUInteger capacity = candidate.results.lastObject.physicalVertexCount;
        assert(p[i].source[0] < capacity && p[i].source[1] < capacity &&
               p[i].provoking < capacity);
        for (unsigned k = 0; k < 2; k++) {
            const NV2AMetalVertex *s = source + p[i].source[k],
                                  *e = r + (k ? 2 : 0);
            // Original fog/texture/position identify the remapped endpoints;
            // color is compared independently to the compute-selected provoker.
            assert(!memcmp(s->screen, e->screen, sizeof(s->screen)) &&
                   !memcmp(&s->fog, &e->fog, 4) &&
                   !memcmp(s->texcoord, e->texcoord, sizeof(s->texcoord)));
            const NV2AMetalVertex *color =
                c.line.smooth ? s : source + p[i].provoking;
            assert(!memcmp(color->color, e->color, sizeof(color->color)));
        }
        for (unsigned k = 0; k < 3; k++)
            assert(!p[i].reserved[k]);
        if (c.line.scene == 10 &&
            c.line.primitive != NV2AMetalPrimitivePolygon && i >= 2) {
            assert(v[0].slope != v[12].slope);
            cpw_plane2++;
        }
        if (c.line.scene == 12 && i == 0) {
            assert(p[i].slope == 0);
            cpw_sanitized++;
        }
    }
}
static void cpw_pair(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                     id<MTLTexture> pattern, CompactPolygonCase c)
{
    CompactPolygonOutput *result[2];
    for (unsigned order = 0; order < 2; order++) {
        unsigned direct = (order + cpw_pairs) & 1;
        result[direct] = cpw_render(commands, geometry, pattern, c, direct);
    }
    if (![result[0].pixels isEqualToData:result[1].pixels] ||
        result[0].query != result[1].query) {
        fprintf(stderr,
                "Compact polygon pair%u topo%u n%lu transport%u scene%u mode%u "
                "faces%u width%g smooth%d W%d slice%lu/%lu query%llu/%llu\n",
                cpw_pairs, c.line.primitive, (unsigned long)c.line.count,
                c.line.transport, c.line.scene, c.mixed, c.faceFlags,
                c.line.width, c.line.smoothLine, c.line.w,
                (unsigned long)c.first, (unsigned long)c.length,
                (unsigned long long)result[0].query,
                (unsigned long long)result[1].query);
        abort();
    }
    cpw_packets(result[1], result[0], c);
    if (c.line.scene == 10)
        assert(result[1].query > 7);
    cpw_pairs++;
}
static void cpw_compare_legacy(NV2AMetalCommands *commands,
                               NV2AMetalGeometryResult *candidate,
                               NV2AMetalGeometryResult *reference,
                               id<MTLBuffer> source,
                               enum NV2AMetalPrimitive primitive)
{
    assert(candidate.compactLines && candidate.vertices == source &&
           candidate.sourcePrimitive == primitive &&
           candidate.vertexCount == reference.vertexCount);
    id<MTLBuffer> packets = cl_copy(commands, candidate.lineCoverage),
                  records = cl_copy(commands, reference.vertices);
    NSError *error = nil;
    cl_require([commands submitWithError:&error] &&
                   [commands waitUntilIdleWithError:&error],
               error);
    CompactLineInput *input = [CompactLineInput new];
    input.source = source;
    CompactPolygonOutput *a = [CompactPolygonOutput new],
                         *b = [CompactPolygonOutput new];
    a.input = input;
    a.results = @[ candidate ];
    a.source = [NSData dataWithBytes:source.contents length:source.length];
    a.records = @[ [NSData dataWithBytes:packets.contents
                                  length:packets.length] ];
    b.records = @[ [NSData dataWithBytes:records.contents
                                  length:records.length] ];
    CompactPolygonCase c = { .line = { .primitive = primitive, .count = 6 } };
    cpw_packets(a, b, c);
}
static unsigned cpw_rejects;
static void cpw_guards(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry)
{
    NSError *error = nil;
    cl_require([commands beginWithError:&error] != nil, error);
    CompactPolygonCase c = { .line = { .primitive = NV2AMetalPrimitiveQuadStrip,
                                       .count = 12,
                                       .transport = 2,
                                       .width = 3,
                                       .samples = 1 } };
    CompactLineInput *input = cpw_input(commands, c.line);
    __block NV2AMetalGeometryResult *g =
        cpw_geometry(commands, geometry, input, c, YES).lastObject;
    NV2AMetalPixelShader *pixel = cl_pixels[0];
    assert(pixel);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture =
        cl_attachment(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    pass.depthAttachment.texture =
        cl_attachment(commands.device, MTLPixelFormatDepth32Float_Stencil8, 1);
    pass.stencilAttachment.texture = pass.depthAttachment.texture;
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 16777215, 0, 16777215 },
                                 .surface_scale = { 1, 1 } };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
    }
    NV2AMetalPixelTexture bindings[4] = { 0 };
    const NV2AMetalPixelTexture *bindingPointer = bindings;
    NV2AMetalDrawConfig dc = { 0 };
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    cl_require(state != nil, error);
    NV2AMetalPixelDraw * (^prepare)(NV2AMetalCommands *, NSUInteger, NSUInteger,
                                    NV2AMetalPixelRasterClass) =
        ^(NV2AMetalCommands *owner, NSUInteger offset, NSUInteger count,
          NV2AMetalPixelRasterClass cls) {
          return [pixel prepareGeometry:g
                                 offset:offset
                                  count:count
                               uniforms:&u
                               textures:bindingPointer
                                   pass:pass
                              drawState:state
                            rasterClass:cls
                   ignorePolygonCulling:YES
                               commands:owner
                                  error:NULL];
        };
    unsigned before =
        cpw_pack + cpw_fill_pack + cpw_expand + cpw_gather + cpw_face;
    assert(
        !prepare(commands, 0, g.vertexCount, NV2AMetalPixelRasterExpandedLine));
    cpw_rejects++;
    assert(!prepare(commands, 1, 1, NV2AMetalPixelRasterCompactLine));
    cpw_rejects++;
    assert(!prepare(commands, g.vertexCount * sizeof(NV2AMetalVertex), 1,
                    NV2AMetalPixelRasterCompactLine));
    cpw_rejects++;
    assert(
        !prepare(commands, NSUIntegerMax, 0, NV2AMetalPixelRasterCompactLine));
    cpw_rejects++;
    assert(![pixel encodeVertices:g.vertices
                           offset:0
                            count:6
                        primitive:MTLPrimitiveTypeTriangle
                         uniforms:&u
                         textures:bindings
                             pass:pass
                        drawState:state
                      rasterClass:NV2AMetalPixelRasterCompactLine
             ignorePolygonCulling:YES
                         commands:commands
                            error:NULL]);
    cpw_rejects++;
    NV2AMetalPixelDraw *empty =
        prepare(commands, g.vertexCount * sizeof(NV2AMetalVertex), 0,
                NV2AMetalPixelRasterCompactLine);
    assert(empty && !empty.vertexCount);
    NSArray *keys = @[
        @"sourcePrimitive", @"sourceVertexCount", @"physicalVertexCount",
        @"verticesPerPrimitive", @"primitiveCount", @"vertexCount",
        @"lineCoverage"
    ];
    NSArray *bad = @[
        @(NV2AMetalPrimitivePoints), @(g.sourceVertexCount - 1),
        @(g.physicalVertexCount + 1), @6, @(g.primitiveCount + 1),
        @(g.vertexCount - 1),
        [commands.device newBufferWithLength:g.lineCoverage.length - 1
                                     options:MTLResourceStorageModePrivate]
    ];
    for (NSUInteger i = 0; i < keys.count; i++) {
        id old = [g valueForKey:keys[i]];
        [g setValue:bad[i] forKey:keys[i]];
        assert(!prepare(commands, 0, g.vertexCount,
                        NV2AMetalPixelRasterCompactLine));
        cpw_rejects++;
        [g setValue:old forKey:keys[i]];
    }
    NV2AMetalCommands *other =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    cl_require(other && [other beginWithError:&error], error);
    assert(!prepare(other, 0, g.vertexCount, NV2AMetalPixelRasterCompactLine));
    cpw_rejects++;
    [other cancel];
    assert(before ==
           cpw_pack + cpw_fill_pack + cpw_expand + cpw_gather + cpw_face);
    [commands cancel];
    cl_require([commands beginWithError:&error] != nil, error);
    assert(
        !prepare(commands, 0, g.vertexCount, NV2AMetalPixelRasterCompactLine));
    cpw_rejects++;
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(encoder);
    assert(![empty encodeWithRenderEncoder:encoder
                                  commands:commands
                                     error:NULL]);
    cpw_rejects++;
    [encoder endEncoding];
    [commands cancel];
    cl_require([commands beginWithError:&error] != nil, error);
    input = cpw_input(commands, c.line);
    g = cpw_geometry(commands, geometry, input, c, YES).lastObject;
    assert(
        prepare(commands, 0, g.vertexCount, NV2AMetalPixelRasterCompactLine));
    cl_require([commands submitWithError:&error] &&
                   [commands waitUntilIdleWithError:&error],
               error);
    cl_require([commands beginWithError:&error] != nil, error);
    assert(
        !prepare(commands, 0, g.vertexCount, NV2AMetalPixelRasterCompactLine));
    cpw_rejects++;
    [commands cancel];
    for (unsigned submit = 0; submit < 2; submit++) {
        __weak NV2AMetalIndexedVertices *weakOwner;
        __weak id<MTLBuffer> weakPackets;
        @autoreleasepool {
            cl_require([commands beginWithError:&error] != nil, error);
            CompactLineInput *temporary = cpw_input(commands, c.line);
            NV2AMetalGeometryResult *result =
                cpw_geometry(commands, geometry, temporary, c, YES).lastObject;
            weakOwner = temporary.owner;
            weakPackets = result.lineCoverage;
        }
        assert(weakOwner && weakPackets);
        if (submit)
            cl_require([commands submitWithError:&error] &&
                           [commands waitUntilIdleWithError:&error],
                       error);
        else
            [commands cancel];
        assert(!weakOwner && !weakPackets);
    }
    // Invalid API inputs must not create any producer dispatch.
    cl_require([commands beginWithError:&error] != nil, error);
    input = cl_input(commands, 0, 0, 12);
    NV2AMetalGeometryRasterConfig config = { .front = NV2AMetalPolygonLine,
                                             .back = NV2AMetalPolygonLine,
                                             .lineWidth = 3,
                                             .viewportWidth = 32,
                                             .viewportHeight = 32 };
    before = cpw_pack + cpw_fill_pack + cpw_expand + cpw_gather + cpw_face;
    cl_observe = YES;
    for (unsigned invalid = 0; invalid < 7; invalid++) {
        config.lineWidth = invalid == 0 ? -1 : invalid == 1 ? NAN : 3;
        config.viewportWidth = invalid == 2 ? 0 : invalid == 3 ? 16385 : 32;
        NSUInteger first = invalid == 4 ? NSUIntegerMax : 0,
                   count = invalid == 5 ? 21 :
                           invalid == 6 ? NSUIntegerMax :
                                          12;
        assert(![geometry encodeNativeRasterVertices:input.source
                                               first:first
                                               count:count
                                           primitive:NV2AMetalPrimitiveTriangles
                                              config:&config
                                              smooth:NO
                                      firstProvoking:NO
                                        zPerspective:NO
                                            commands:commands
                                               error:NULL]);
        cpw_rejects++;
    }
    cl_observe = NO;
    assert(before ==
           cpw_pack + cpw_fill_pack + cpw_expand + cpw_gather + cpw_face);
    [commands cancel];
}
static void compact_polygon_wire_tests(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        cl_require(commands != nil, error);
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        cl_require(geometry != nil, error);
        cl_read_libraries(commands);
        id<MTLTexture> pattern = cl_pattern(commands.device);
        cl_require([commands beginWithError:&error] != nil, error);
        id e = [commands.commandBuffer computeCommandEncoder];
        Method methods[] = {
            class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                    @selector(computeFunction:error:)),
            class_getInstanceMethod(object_getClass(e),
                                    @selector(setComputePipelineState:)),
            class_getInstanceMethod(
                object_getClass(e),
                @selector(dispatchThreads:threadsPerThreadgroup:))
        };
        [e endEncoding];
        [commands cancel];
        IMP replacements[] = { (IMP)cl_compute_spy, (IMP)cl_pipeline_spy,
                               (IMP)cpw_dispatch },
            originals[3];
        cl_names = [NSMutableDictionary new];
        cl_encoders = [NSMutableDictionary new];
        for (unsigned i = 0; i < 3; i++) {
            assert(methods[i]);
            originals[i] =
                method_setImplementation(methods[i], replacements[i]);
        }
        cl_compute = (void *)originals[0];
        cl_pipeline = (void *)originals[1];
        cl_dispatch = (void *)originals[2];
        @try {
            for (unsigned topology = 0; topology < 6; topology++)
                for (unsigned profile = 0; profile < 3; profile++)
                    for (unsigned transport = 0; transport < 2; transport++) {
                        CompactPolygonCase c = {
                            .line = { .primitive = NV2AMetalPrimitiveTriangles +
                                                   topology,
                                      .count = 12,
                                      .transport = transport ? 2 : 1,
                                      .samples =
                                          (topology + profile) & 1 ? 4 : 1,
                                      .profile = (topology + profile) % 4,
                                      .width = profile == 0 ? 3 : 1,
                                      .smoothLine = profile == 1,
                                      .w = profile == 2,
                                      .smooth = (topology + profile) & 1,
                                      .first = (topology + transport) & 1 },
                            .faceFlags = (topology + profile + transport) % 8
                        };
                        cpw_pair(commands, geometry, pattern, c);
                    }
            for (unsigned topology = 0; topology < 6; topology++)
                for (unsigned n = 0; n < 8; n++) {
                    CompactPolygonCase c = {
                        .line = { .primitive =
                                      NV2AMetalPrimitiveTriangles + topology,
                                  .count = n,
                                  .transport = n & 1 ? 3 : 0,
                                  .samples = 1,
                                  .profile = 0,
                                  .width = 3,
                                  .smooth = n & 1,
                                  .first = n & 2 }
                    };
                    cpw_pair(commands, geometry, pattern, c);
                }
            for (unsigned topology = 0; topology < 6; topology++)
                for (unsigned mode = 1; mode <= 3; mode++) {
                    if (topology == 5 && mode == 2)
                        continue;
                    CompactPolygonCase c = {
                        .line = { .primitive =
                                      NV2AMetalPrimitiveTriangles + topology,
                                  .count = 12,
                                  .transport = 2,
                                  .samples = 1,
                                  .profile = mode % 4,
                                  .width = 3,
                                  .smoothLine = mode == 2,
                                  .w = mode == 3,
                                  .smooth = mode & 1,
                                  .first = YES },
                        .mixed = mode,
                        .faceFlags = topology & 1
                    };
                    cpw_pair(commands, geometry, pattern, c);
                }
            for (unsigned topology = 0; topology < 6; topology++)
                for (unsigned scene = 2; scene < 14; scene++) {
                    if (scene == 10 && topology < 3)
                        continue;
                    CompactPolygonCase c = {
                        .line = { .primitive =
                                      NV2AMetalPrimitiveTriangles + topology,
                                  .count = topology == 5 ? 8 : 12,
                                  .transport = scene < 10 ? scene % 4 : 0,
                                  .scene = scene,
                                  .samples = scene & 1 ? 4 : 1,
                                  .profile = scene % 4,
                                  .width = scene & 1 ? 2.5f : 3,
                                  .smoothLine = scene & 2,
                                  .w = scene & 4,
                                  .smooth = scene & 1,
                                  .first = scene & 2 },
                        .faceFlags = scene & 1
                    };
                    if (scene == 10) {
                        c.line.count = 4;
                        c.first = 12;
                        c.length = 12;
                    }
                    if (scene == 12)
                        c.line.w = NO;
                    cpw_pair(commands, geometry, pattern, c);
                }
            // Arbitrary generated slices retain global carrier IDs, including
            // odd starts inside the six-corner carrier.
            for (unsigned topology = 0; topology < 6; topology++) {
                CompactPolygonCase c = {
                    .line = { .primitive =
                                  NV2AMetalPrimitiveTriangles + topology,
                              .count = 12,
                              .transport = 2,
                              .samples = 1,
                              .profile = 1,
                              .width = 3,
                              .w = YES },
                    .first = 1,
                    .length = 7
                };
                cpw_pair(commands, geometry, pattern, c);
            }
            cpw_guards(commands, geometry);
            assert(cpw_valid && cpw_plane2 && cpw_sanitized);
            printf("Compact polygon wire: %u exact GPU pairs; %u valid "
                   "carriers, %u second-plane carriers, %u rejects PASS\n",
                   cpw_pairs, cpw_valid, cpw_plane2, cpw_rejects);
        } @finally {
            for (unsigned i = 0; i < 3; i++)
                method_setImplementation(methods[i], originals[i]);
            cl_names = nil;
            cl_encoders = nil;
        }
    }
}
#endif
