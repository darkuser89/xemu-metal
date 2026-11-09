/* Immutable prepared-packet ranges versus legacy per-slice preparation.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PREPARED_RANGES_H
#define TEST_METAL_PREPARED_RANGES_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"
#import <objc/runtime.h>
@interface NV2AMetalPixelShader (PreparedRangeTest)
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
                   ignorePolygonCulling:(BOOL)ignore
                               commands:(NV2AMetalCommands *)commands
                                  error:(NSError **)error;
@end
@interface PreparedRangeEncoder : NSProxy
@property(nonatomic) id<MTL4RenderCommandEncoder> encoder;
@property(nonatomic) NSUInteger changes;
@end
@implementation PreparedRangeEncoder
- (id<MTL4CommandBuffer>)commandBuffer
{
    return _encoder.commandBuffer;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    return [(NSObject *)_encoder methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation
{
    _changes++;
    [invocation invokeWithTarget:_encoder];
}
@end
static PreparedRangeEncoder *pr_proxy(id<MTL4RenderCommandEncoder> encoder)
{
    PreparedRangeEncoder *proxy = [PreparedRangeEncoder alloc];
    proxy.encoder = encoder;
    return proxy;
}
static unsigned pr_rejections, pr_pairs;
static NV2AMetalDrawState *pr_state;
static NV2AMetalPixelDraw *pr_raw(id<MTLBuffer> vertices, NSUInteger count,
                                  MTLPrimitiveType primitive,
                                  MTL4RenderPassDescriptor *p)
{
    NSError *error = nil;
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalPixelDraw *packet =
        [shader prepareVertices:vertices
                          offset:0
                           count:count
                       primitive:primitive
                        uniforms:&u
                        textures:textures
                            pass:p
                    depthStencil:pr_state.depthStencil
                       drawState:pr_state
                     rasterClass:NV2AMetalPixelRasterNative
              polygonProjections:nil
            ignorePolygonCulling:NO
                        commands:commands
                           error:&error];
    require(packet != nil, error);
    return packet;
}
static NV2AMetalPixelRasterClass pr_class(NV2AMetalGeometryResult *g)
{
    return g.compactLines ?
               NV2AMetalPixelRasterCompactLine :
           g.directTriangles ?
               (NV2AMetalPixelRasterClass)(NV2AMetalPixelRasterDirectTriangle |
                                           g.directTriangleOptions) :
           g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
                                NV2AMetalPixelRasterNative;
}
static NV2AMetalPixelDraw *pr_packet(NV2AMetalGeometryResult *g,
                                     NSUInteger first, NSUInteger count,
                                     MTL4RenderPassDescriptor *p)
{
    NSError *error = nil;
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalPixelDraw *packet =
        [shader prepareGeometry:g
                          offset:first * sizeof(NV2AMetalVertex)
                           count:count
                        uniforms:&u
                        textures:textures
                            pass:p
                       drawState:pr_state
                     rasterClass:pr_class(g)
            ignorePolygonCulling:g.expandedLines || g.expandedPolygons
                        commands:commands
                           error:&error];
    require(packet != nil, error);
    return packet;
}
static void pr_reject(NV2AMetalPixelDraw *packet, PreparedRangeEncoder *proxy,
                      NV2AMetalCommands *owner, NSUInteger first,
                      NSUInteger count)
{
    NSError *error = nil;
    NSUInteger changes = proxy.changes;
    assert(![packet encodeWithRenderEncoder:(id)proxy
                                   commands:owner
                                firstVertex:first
                                vertexCount:count
                                      error:&error] &&
           error && proxy.changes == changes);
    pr_rejections++;
}
static NSData *pr_packet_bytes(NV2AMetalPixelDraw *packet)
{
    NSMutableData *bytes = [NSMutableData new];
    for (NSString *name in @[
             @"_bindings", @"_firstVertex", @"_vertexCount",
             @"_groupFirstVertex", @"_rangeAlignment"
         ]) {
        Ivar ivar = class_getInstanceVariable(NV2AMetalPixelDraw.class,
                                              name.UTF8String);
        assert(ivar);
        NSUInteger size = 0;
        NSGetSizeAndAlignment(ivar_getTypeEncoding(ivar), &size, NULL);
        [bytes appendBytes:(const uint8_t *)(__bridge const void *)packet +
                           ivar_getOffset(ivar)
                    length:size];
    }
    return bytes;
}
static id<MTLBuffer> pr_vertices(BOOL physical)
{
    NV2AMetalVertex unique[4] = { 0 }, records[17] = { 0 };
    const float xy[4][2] = {
        { 1.25f, 1.25f }, { 6.75f, 1.25f }, { 6.75f, 6.75f }, { 1.25f, 6.75f }
    };
    for (unsigned i = 0; i < 4; i++) {
        NV2AMetalVertex *v = &unique[i];
        v->clip[0] = xy[i][0] / 4 - 1;
        v->clip[1] = 1 - xy[i][1] / 4;
        v->clip[2] = .5f;
        v->clip[3] = 1;
        v->point_size = 2;
        v->screen[0] = xy[i][0];
        v->screen[1] = xy[i][1];
        v->screen[2] = 42.5f + i * 3;
        v->screen[3] = 1;
        for (unsigned c = 0; c < 4; c++) {
            v->color[c][0] = (i + 1) / 5.f;
            v->color[c][1] = (c + 1) / 5.f;
            v->color[c][2] = .3f;
            v->color[c][3] = .75f;
        }
        for (unsigned p = 0; p < 3; p++)
            memcpy(v->plane[p], v->screen, sizeof(v->screen));
    }
    for (unsigned i = 0; i < 17; i++)
        records[i] = unique[i < 5 ? 3 : (i - 5) % 4];
    id<MTLBuffer> result = [commands.device
        newBufferWithBytes:physical ? (const void *)unique :
                                      (const void *)records
                    length:physical ? sizeof(unique) : sizeof(records)
                   options:MTLResourceStorageModeShared];
    assert(result);
    return result;
}
static NV2AMetalGeometryResult *pr_geometry(unsigned kind, BOOL indexed)
{
    NSError *error = nil;
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    require(geometry != nil, error);
    id<MTLBuffer> input = pr_vertices(indexed);
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:12
                                                error:&error];
    require(stream != nil, error);
    if (indexed) {
        uint32_t map[17];
        for (unsigned i = 0; i < 17; i++)
            map[i] = i < 5 ? 3 : (i - 5) % 4;
        NV2AMetalIndexedVertices *owner = [[NV2AMetalIndexedVertices alloc]
            initWithVertices:input
               physicalCount:4
                       remap:[NSData dataWithBytes:map length:sizeof(map)]
                       error:&error];
        require(owner && [stream appendIndexedVertices:owner
                                                 first:5
                                                 count:12
                                                 error:&error],
                error);
    } else
        require([stream appendVertices:input first:5 count:12 error:&error],
                error);
    NV2AMetalVertexSlice *slice =
        [stream encodeSliceForDrawingWithCommands:commands error:&error];
    require(slice != nil, error);
    NV2AMetalGeometryRasterConfig config = { .front = NV2AMetalPolygonFill,
                                             .back = NV2AMetalPolygonFill,
                                             .lineWidth = 1,
                                             .viewportWidth = 8,
                                             .viewportHeight = 8 };
    enum NV2AMetalPrimitive primitive =
        kind == 0 ? NV2AMetalPrimitiveTriangles :
        kind == 1 ? NV2AMetalPrimitiveTriangleFan :
                    NV2AMetalPrimitiveQuads;
    NSArray *results = [geometry encodeNativeRasterSlice:slice
                                               primitive:primitive
                                                  config:&config
                                                  smooth:YES
                                          firstProvoking:NO
                                            zPerspective:NO
                                                commands:commands
                                                   error:&error];
    require(results.count == 1, error);
    NV2AMetalGeometryResult *g = results[0];
    assert(g.vertices == slice.buffer && g.firstVertex == (indexed ? 0 : 5));
    if (indexed)
        assert(g.indexedVertices == slice.indexedVertices &&
               g.indexOffset == 5 && g.physicalVertexCount == 4);
    return g;
}
static NSData *pr_finish(id<MTLBuffer> counter)
{
    NSError *error = nil;
    read_depth();
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    [target getBytes:pixels
         bytesPerRow:sizeof(pixels[0])
          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
         mipmapLevel:0];
    NSMutableData *result = [NSMutableData dataWithBytes:pixels
                                                  length:sizeof(pixels)];
    unsigned colored = 0, changedDepth = 0;
    for (unsigned y = 0; y < 8; y++) {
        const float *row =
            (const float *)((const uint8_t *)depth_readback.contents + y * 256);
        [result appendBytes:row length:8 * sizeof(float)];
        for (unsigned x = 0; x < 8; x++) {
            colored +=
                memcmp(pixels[y][x], clear_color, sizeof(clear_color)) != 0;
            changedDepth += row[x] != draw_clear_depth;
        }
    }
    uint64_t samples = *(const uint64_t *)counter.contents;
    assert(samples && colored && changedDepth);
    [result appendBytes:&samples length:sizeof(samples)];
    return result;
}
static void pr_pair(unsigned kind, BOOL indexed, BOOL partial)
{
    NSData *reference = nil;
    for (unsigned ranged = 0; ranged < 2; ranged++) {
        NSError *error = nil;
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalGeometryResult *g = pr_geometry(kind, indexed);
        NSUInteger width = g.verticesPerPrimitive;
        NSUInteger base = partial ? 1 : 0;
        NSUInteger capacity = partial ? g.vertexCount - 3 : g.vertexCount;
        MTL4RenderPassDescriptor *p = pass();
        id<MTLBuffer> counter =
            [commands.device newBufferWithLength:8
                                         options:MTLResourceStorageModeShared];
        assert(counter);
        memset(counter.contents, 0, 8);
        p.visibilityResultBuffer = counter;
        p.visibilityResultType = MTLVisibilityResultTypeAccumulate;
        NV2AMetalPixelDraw *packet =
            ranged ? pr_packet(g, base, capacity, p) : nil;
        NSUInteger starts[2] = { partial ? width - 1 : 0,
                                 partial ? 2 * width - 1 : width };
        NV2AMetalPixelDraw *clones[2] = { nil, nil };
        if (!ranged)
            for (unsigned i = 0; i < 2; i++)
                clones[i] = pr_packet(g, base + starts[i], width, p);
        NSData *snapshot = ranged ? pr_packet_bytes(packet) : nil;
        id<MTL4RenderCommandEncoder> encoder =
            [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
        require(encoder != nil, error);
        [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting
                                  offset:0];
        if (ranged) {
            PreparedRangeEncoder *proxy = pr_proxy(encoder);
            require([packet encodeWithRenderEncoder:(id)proxy
                                           commands:commands
                                        firstVertex:capacity
                                        vertexCount:0
                                              error:&error],
                    error);
            assert(!proxy.changes);
            for (unsigned i = 0; i < 2; i++)
                require([packet encodeWithRenderEncoder:encoder
                                               commands:commands
                                            firstVertex:starts[i]
                                            vertexCount:width
                                                  error:&error],
                        error);
            assert([snapshot isEqualToData:pr_packet_bytes(packet)]);
        } else
            for (unsigned i = 0; i < 2; i++)
                require([clones[i] encodeWithRenderEncoder:encoder
                                                  commands:commands
                                                     error:&error],
                        error);
        [encoder endEncoding];
        NSData *actual = pr_finish(counter);
        if (!ranged)
            reference = actual;
        else if (![reference isEqualToData:actual]) {
            fprintf(stderr,
                    "Prepared ranges mismatch kind%u indexed%d partial%d\n",
                    kind, indexed, partial);
            abort();
        }
    }
    pr_pairs++;
}
static void pr_guard_tests(void)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    id<MTLBuffer> vertices = pr_vertices(NO);
    MTL4RenderPassDescriptor *p = pass();
    NV2AMetalPixelDraw *triangle =
        pr_raw(vertices, 12, MTLPrimitiveTypeTriangle, p);
    NV2AMetalPixelDraw *line = pr_raw(vertices, 12, MTLPrimitiveTypeLine, p);
    NV2AMetalPixelDraw *point = pr_raw(vertices, 12, MTLPrimitiveTypePoint, p);
    NV2AMetalPixelDraw *strip =
        pr_raw(vertices, 4, MTLPrimitiveTypeTriangleStrip, p);
    NV2AMetalPixelDraw *lineStrip =
        pr_raw(vertices, 4, MTLPrimitiveTypeLineStrip, p);
    NV2AMetalGeometryResult *native = pr_geometry(0, NO),
                            *mapped = pr_geometry(1, YES);
    NV2AMetalPixelDraw *partialNative = pr_packet(native, 1, 9, p);
    NV2AMetalPixelDraw *partialMapped = pr_packet(mapped, 1, 9, p);
    NV2AMetalGeometryResult *quadGeometry = pr_geometry(2, NO);
    NV2AMetalPixelDraw *quads =
        pr_packet(quadGeometry, 0, quadGeometry.vertexCount, p);
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(foreign && [foreign beginWithError:&error] &&
                [foreign addResource:target error:&error] &&
                [foreign addResource:depth error:&error],
            error);
    id<MTL4RenderCommandEncoder> other =
        [foreign.commandBuffer renderCommandEncoderWithDescriptor:p];
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    assert(other && encoder);
    PreparedRangeEncoder *proxy = pr_proxy(encoder),
                         *foreignProxy = pr_proxy(other);
    const NSUInteger invalid[][2] = { { 13, 0 },
                                      { 0, 13 },
                                      { NSUIntegerMax, 0 },
                                      { 0, NSUIntegerMax },
                                      { 1, NSUIntegerMax },
                                      { UINT32_MAX, 3 },
                                      { NSUIntegerMax, NSUIntegerMax },
                                      { 1, 3 },
                                      { 0, 4 } };
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++)
        pr_reject(triangle, proxy, commands, invalid[i][0], invalid[i][1]);
    pr_reject(line, proxy, commands, 1, 2);
    pr_reject(line, proxy, commands, 0, 3);
    pr_reject(strip, proxy, commands, 1, 3);
    pr_reject(strip, proxy, commands, 0, 3);
    pr_reject(lineStrip, proxy, commands, 1, 3);
    pr_reject(lineStrip, proxy, commands, 0, 3);
    pr_reject(quads, proxy, commands, 3, 3);
    pr_reject(partialNative, proxy, commands, 0, 3); /* Geometry origin1. */
    pr_reject(partialNative, proxy, commands, 2,
              3); /* DrawID2 despite origin3. */
    pr_reject(partialMapped, proxy, commands, 0, 3);
    pr_reject(triangle, foreignProxy, commands, 0, 3);
    pr_reject(triangle, proxy, foreign, 0, 3);
    require([triangle encodeWithRenderEncoder:(id)proxy
                                     commands:commands
                                  firstVertex:1
                                  vertexCount:0
                                        error:&error] &&
                [triangle encodeWithRenderEncoder:(id)proxy
                                         commands:commands
                                      firstVertex:12
                                      vertexCount:0
                                            error:&error],
            error);
    assert(!proxy.changes && !foreignProxy.changes);
    require([triangle encodeWithRenderEncoder:encoder
                                     commands:commands
                                  firstVertex:3
                                  vertexCount:3
                                        error:&error] &&
                [line encodeWithRenderEncoder:encoder
                                     commands:commands
                                  firstVertex:2
                                  vertexCount:2
                                        error:&error] &&
                [point encodeWithRenderEncoder:encoder
                                      commands:commands
                                   firstVertex:1
                                   vertexCount:1
                                         error:&error] &&
                [strip encodeWithRenderEncoder:encoder
                                      commands:commands
                                   firstVertex:0
                                   vertexCount:4
                                         error:&error] &&
                [lineStrip encodeWithRenderEncoder:encoder
                                          commands:commands
                                       firstVertex:0
                                       vertexCount:4
                                             error:&error] &&
                [partialMapped encodeWithRenderEncoder:encoder
                                              commands:commands
                                           firstVertex:2
                                           vertexCount:3
                                                 error:&error],
            error);
    [other endEncoding];
    [foreign cancel];
    [encoder endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    pr_reject(triangle, proxy, commands, 0, 0); /* Submitted recording. */
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalPixelDraw *cancelled =
        pr_raw(vertices, 12, MTLPrimitiveTypeTriangle, p);
    encoder = [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    require(encoder != nil, error);
    [encoder endEncoding];
    [commands cancel];
    pr_reject(cancelled, proxy, commands, 0, 0);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalPixelDraw *fresh =
        pr_raw(vertices, 12, MTLPrimitiveTypeTriangle, p);
    encoder = [commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    require(encoder != nil, error);
    proxy = pr_proxy(encoder);
    pr_reject(cancelled, proxy, commands, 0, 3); /* Same owner, new serial. */
    pr_reject(triangle, proxy, commands, 0, 0);
    require([fresh encodeWithRenderEncoder:(id)proxy
                                  commands:commands
                               firstVertex:12
                               vertexCount:0
                                     error:&error],
            error);
    assert(!proxy.changes);
    [encoder endEncoding];
    [commands cancel];
}
static void prepared_range_tests(void)
{
    NSError *error = nil;
    NV2AMetalDrawConfig config = draw_config();
    config.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                         NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7u << 16;
    pr_state = [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                   config:&config
                                                    error:&error];
    require(pr_state != nil, error);
    pr_guard_tests();
    pr_pair(1, NO, YES);
    pr_pair(1, YES, YES);
    pr_state = nil;
    printf("Prepared ranges: %u exact legacy-clone RGBA/Zeta/query pairs, %u "
           "rejected ranges with zero encoder changes; "
           "immutable packets, native/mapped origins, tight remap, "
           "count0/overflow/groups/strip/foreign "
           "encoder-owner/submit/cancel/reuse PASS\n",
           pr_pairs, pr_rejections);
}
#endif
