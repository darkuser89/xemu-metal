/*
 * Offscreen validation of native Metal 4 NV2A geometry expansion
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Metal geometry test failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static void close_float(float actual, float expected)
{
    if (!isfinite(actual) || fabsf(actual - expected) > 0.00001f) {
        fprintf(stderr, "Geometry value: got %g, expected %g\n", actual,
                expected);
        abort();
    }
}

static NV2AMetalGeometryResult *
expand(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
       id<MTLBuffer> input, NSUInteger count, enum NV2AMetalPrimitive primitive,
       enum NV2AMetalPolygonMode polygon, BOOL smooth, BOOL first,
       BOOL perspective)
{
    NSError *error = nil;
    NV2AMetalGeometryResult *result = [geometry encodeVertices:input
                                                         count:count
                                                     primitive:primitive
                                                       polygon:polygon
                                                        smooth:smooth
                                                firstProvoking:first
                                                  zPerspective:perspective
                                                      commands:commands
                                                         error:&error];
    require(result != nil, error);
    return result;
}

static void finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}

static void check_vertices(NV2AMetalGeometryResult *result,
                           const NV2AMetalVertex *source, const unsigned *order,
                           NSUInteger count, MTLPrimitiveType type)
{
    assert(result.vertexCount == count && result.primitiveType == type);
    const NV2AMetalVertex *output = result.vertices.contents;
    for (NSUInteger i = 0; i < count; i++) {
        const NV2AMetalVertex *a = &source[order[i]], *b = &output[i];
        assert(memcmp(a->clip, b->clip, sizeof(a->clip)) == 0);
        assert(memcmp(a->screen, b->screen, sizeof(a->screen)) == 0);
        assert(memcmp(a->texcoord, b->texcoord, sizeof(a->texcoord)) == 0);
        assert(a->fog == b->fog && a->point_size == b->point_size);
    }
}

static void check_flat(NV2AMetalGeometryResult *result,
                       const NV2AMetalVertex *source, const unsigned *provoking,
                       unsigned perPrimitive)
{
    const NV2AMetalVertex *output = result.vertices.contents;
    for (NSUInteger i = 0; i < result.vertexCount; i++) {
        assert(memcmp(output[i].color,
                      source[provoking[i / perPrimitive]].color,
                      sizeof(output[i].color)) == 0);
    }
}

static unsigned face_cases, cull_images, slice_rejects;
static void raster_faces(NV2AMetalCommands *commands,
                         NV2AMetalGeometry *geometry)
{
    NSError *error = nil;
    NV2AMetalVertex v[6] = { 0 };
    const float xy[6][2] = { { 1, 1 }, { 7, 1 }, { 1, 7 },
                             { 1, 1 }, { 1, 7 }, { 7, 1 } };
    for (unsigned i = 0; i < 6; i++) {
        v[i].screen[0] = xy[i][0];
        v[i].screen[1] = xy[i][1];
        v[i].screen[2] = 32768;
        v[i].screen[3] = 1;
        v[i].clip[0] = xy[i][0] / 4 - 1;
        v[i].clip[1] = 1 - xy[i][1] / 4;
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].point_size = 1;
        v[i].color[0][0] = i + .25f;
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    for (unsigned clockwise = 0; clockwise < 2; clockwise++)
        for (unsigned front = 0; front < 3; front++)
            for (unsigned back = 0; back < 3; back++)
                for (unsigned cull = 0; cull < 4; cull++) {
                    NV2AMetalGeometryRasterConfig c = {
                        .front = front,
                        .back = back,
                        .frontClockwise = clockwise,
                        .cullFront = cull == 1 || cull == 3,
                        .cullBack = cull == 2 || cull == 3,
                    };
                    require([commands beginWithError:&error] != nil, error);
                    NSArray<NV2AMetalGeometryResult *> *g = [geometry
                        encodeRasterVertices:input
                                       count:6
                                   primitive:NV2AMetalPrimitiveTriangles
                                      config:&c
                                      smooth:YES
                              firstProvoking:YES
                                zPerspective:NO
                                    commands:commands
                                       error:&error];
                    require(g != nil, error);
                    finish(commands);
                    assert(g.count == (front == back ? 1 : 2));
                    for (NSUInteger stream = 0; stream < g.count; stream++) {
                        NV2AMetalGeometryResult *r = g[stream];
                        unsigned mode = stream ? back : front;
                        unsigned per = mode == NV2AMetalPolygonLine ? 6 : 3;
                        assert(r.primitiveCount == 2 &&
                               r.verticesPerPrimitive == per &&
                               r.polygonMode == mode &&
                               r.vertexCount == 2 * per);
                        const NV2AMetalVertex *out = r.vertices.contents;
                        for (unsigned p = 0; p < 2; p++) {
                            bool facing_front = p == 0 ? clockwise : !clockwise;
                            bool kept =
                                !(facing_front ? c.cullFront : c.cullBack) &&
                                (g.count == 1 ||
                                 stream == (facing_front ? 0 : 1));
                            const unsigned line_order[] = { 0, 1, 1, 2, 2, 0 };
                            for (unsigned i = 0; i < per; i++) {
                                const NV2AMetalVertex *o = &out[p * per + i];
                                if (!kept) {
                                    assert(o->clip[0] == 2 && o->clip[1] == 2 &&
                                           o->clip[2] == 2 && o->clip[3] == 1 &&
                                           o->point_size == 0);
                                } else {
                                    unsigned index =
                                        p * 3 + (per == 6 ? line_order[i] : i);
                                    assert(!memcmp(o->clip, v[index].clip, 16));
                                    assert(o->color[0][0] ==
                                           v[index].color[0][0]);
                                }
                            }
                        }
                    }
                    face_cases++;
                }
}
static void compare_native_culling(NV2AMetalCommands *commands,
                                   NV2AMetalGeometry *geometry)
{
    NSError *error = nil;
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(pixel != nil, error);
    for (unsigned sign = 0; sign < 4; sign++)
        for (unsigned clockwise = 0; clockwise < 2; clockwise++)
            for (unsigned cull = 1; cull <= 3; cull++) {
                NV2AMetalVertex v[3] = { 0 };
                const float xy[3][2] = { { 1, 1 }, { 7, 1 }, { 1, 7 } };
                for (unsigned i = 0; i < 3; i++) {
                    float w = sign == 1 && i == 0 ? -1 :
                              sign == 2 && i != 0 ? -1 :
                              sign == 3           ? -1 :
                                                    1;
                    v[i].screen[0] = xy[i][0];
                    v[i].screen[1] = xy[i][1];
                    v[i].screen[2] = 32768;
                    v[i].screen[3] = w;
                    v[i].clip[0] = (xy[i][0] / 4 - 1) * w;
                    v[i].clip[1] = (1 - xy[i][1] / 4) * w;
                    v[i].clip[2] = .5f * w;
                    v[i].clip[3] = w;
                    v[i].color[0][1] = v[i].color[0][3] = 1;
                }
                id<MTLBuffer> input = [commands.device
                    newBufferWithBytes:v
                                length:sizeof(v)
                               options:MTLResourceStorageModeShared];
                assert(input);
                NV2AMetalGeometryRasterConfig config = {
                    .frontClockwise = clockwise,
                    .cullFront = cull == 1 || cull == 3,
                    .cullBack = cull == 2 || cull == 3,
                };
                NV2AMetalDrawConfig raster = {
                    .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                 NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                 NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                 NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE },
                    .setup_raster =
                        NV_PGRAPH_SETUPRASTER_CULLENABLE | cull << 21 |
                        (clockwise ? 0 : NV_PGRAPH_SETUPRASTER_FRONTFACE),
                };
                NV2AMetalDrawState *state =
                    [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                        config:&raster
                                                         error:&error];
                require(state != nil, error);
                NV2AMetalPixelUniforms u = {
                    .clip_range = { 0, 65535, 0, 65535 },
                    .surface_scale = { 1, 1 },
                    .depth_format = NV2AMetalPixelDepthD16,
                    .clip_regions = { { 0, 0, 8, 8 } },
                };
                u.combiner.final_inputs[0] = PS_REGISTER_V0;
                u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                             << 8;
                NV2AMetalPixelTexture textures[4] = { 0 };
                float images[2][8][8][4];
                for (unsigned filtered = 0; filtered < 2; filtered++) {
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalGeometryResult *g;
                    if (filtered) {
                        NSArray *streams = [geometry
                            encodeRasterVertices:input
                                           count:3
                                       primitive:NV2AMetalPrimitiveTriangles
                                          config:&config
                                          smooth:YES
                                  firstProvoking:YES
                                    zPerspective:NO
                                        commands:commands
                                           error:&error];
                        require(streams != nil, error);
                        g = streams[0];
                    } else {
                        g = expand(commands, geometry, input, 3,
                                   NV2AMetalPrimitiveTriangles,
                                   NV2AMetalPolygonFill, YES, YES, NO);
                    }
                    MTLTextureDescriptor *d = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:
                            MTLPixelFormatRGBA32Float
                                                     width:8
                                                    height:8
                                                 mipmapped:NO];
                    d.storageMode = MTLStorageModeShared;
                    d.usage = MTLTextureUsageRenderTarget;
                    id<MTLTexture> target =
                        [commands.device newTextureWithDescriptor:d];
                    assert(target);
                    MTL4RenderPassDescriptor *pass =
                        [MTL4RenderPassDescriptor new];
                    pass.colorAttachments[0].texture = target;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].clearColor =
                        MTLClearColorMake(1, 0, 0, 1);
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    require([pixel encodeVertices:g.vertices
                                            count:g.vertexCount
                                        primitive:g.primitiveType
                                         uniforms:&u
                                         textures:textures
                                             pass:pass
                                        drawState:state
                                         commands:commands
                                            error:&error],
                            error);
                    finish(commands);
                    [target getBytes:images[filtered]
                         bytesPerRow:8 * 16
                          fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                         mipmapLevel:0];
                }
                assert(!memcmp(images[0], images[1], sizeof(images[0])));
                cull_images++;
            }
    require([commands beginWithError:&error] != nil, error);
    id<MTLBuffer> vertices =
        [commands.device newBufferWithLength:3 * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    assert(vertices);
    NV2AMetalDrawConfig config = { 0 };
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(state != nil, error);
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:8
                                    height:8
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
    assert(target);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 65535, 0, 65535 },
                                 .surface_scale = { 1, 1 } };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([pixel encodeVertices:vertices
                           offset:0
                            count:0
                        primitive:MTLPrimitiveTypeTriangle
                         uniforms:&u
                         textures:textures
                             pass:pass
                        drawState:state
                         commands:commands
                            error:&error],
            error);
    const struct {
        NSUInteger offset, count;
    } bad[] = {
        { 1, 1 },
        { vertices.length + 1, 1 },
        { vertices.length, 1 },
        { sizeof(NV2AMetalVertex), 3 },
        { NSUIntegerMax, 0 },
    };
    for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        assert(![pixel encodeVertices:vertices
                               offset:bad[i].offset
                                count:bad[i].count
                            primitive:MTLPrimitiveTypeTriangle
                             uniforms:&u
                             textures:textures
                                 pass:pass
                            drawState:state
                             commands:commands
                                error:&error]);
        slice_rejects++;
    }
    [commands cancel];
}

static void w_slope_range(NV2AMetalCommands *commands,
                          NV2AMetalGeometry *geometry)
{
    enum { values = 145, cases = values * values * 8, count = cases * 3 };
    float w[values];
    for (unsigned i = 0; i < 129; i++)
        w[i] = ldexpf(1, (int)i - 64);
    for (unsigned i = 0; i < 8; i++) {
        uint32_t low = 0x1f800001u + i, high = 0x5f7fffffu - i;
        memcpy(&w[129 + i], &low, 4);
        memcpy(&w[137 + i], &high, 4);
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    assert(input);
    NV2AMetalVertex *v = input.contents;
    memset(v, 0, input.length);
    for (unsigned a = 0; a < values; a++)
        for (unsigned b = 0; b < values; b++)
            for (unsigned axis = 0; axis < 2; axis++)
                for (unsigned signs = 0; signs < 4; signs++) {
                    unsigned q = ((a * values + b) * 2 + axis) * 4 + signs;
                    float wa = signs & 1 ? -w[a] : w[a];
                    float wb = signs & 2 ? -w[b] : w[b];
                    for (unsigned i = 0; i < 3; i++) {
                        NV2AMetalVertex *out = &v[3 * q + i];
                        out->screen[0] = i == 1 ? 8 : 0;
                        out->screen[1] = i == 2 ? 8 : 0;
                        out->screen[2] = 1;
                        out->screen[3] = i == axis + 1 ? wb : wa;
                        out->clip[3] = 1;
                    }
                }
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryResult *result =
        expand(commands, geometry, input, count, NV2AMetalPrimitiveTriangles,
               NV2AMetalPolygonFill, YES, YES, YES);
    finish(commands);
    const NV2AMetalVertex *out = result.vertices.contents;
    for (unsigned a = 0; a < values; a++)
        for (unsigned b = 0; b < values; b++)
            for (unsigned axis = 0; axis < 2; axis++)
                for (unsigned signs = 0; signs < 4; signs++) {
                    unsigned q = ((a * values + b) * 2 + axis) * 4 + signs;
                    double wa = signs & 1 ? -w[a] : w[a];
                    double wb = signs & 2 ? -w[b] : w[b];
                    // Independent reciprocal-plane derivative in double.
                    double expected = fabs(1 / wb - 1 / wa) / 8;
                    for (unsigned i = 0; i < 3; i++) {
                        float actual = out[3 * q + i].slope;
                        if (!isfinite(actual) ||
                            fabs(actual - expected) > expected * 0.000002) {
                            fprintf(stderr,
                                    "W slope a%u b%u axis%u signs%u: %.9g "
                                    "expected%.17g\n",
                                    a, b, axis, signs, actual, expected);
                            abort();
                        }
                    }
                }
    printf(
        "Metal4 W slopes: %u planes/%u vertices across clamped W range PASS\n",
        cases, count);
}

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        require(geometry != nil, error);
        NV2AMetalVertex source[7] = { 0 };
        const float xy[7][2] = { { 0, 0 }, { 2, 0 }, { 0, 4 }, { 2, 4 },
                                 { 4, 0 }, { 4, 4 }, { 6, 0 } };
        for (unsigned i = 0; i < 7; i++) {
            /* Known plane z = 1 + 2x + 3y, max(|dz/dx|,|dz/dy|) = 3. */
            source[i].screen[0] = xy[i][0];
            source[i].screen[1] = xy[i][1];
            source[i].screen[2] = 1 + 2 * xy[i][0] + 3 * xy[i][1];
            source[i].screen[3] = (float)(1u << i);
            source[i].clip[0] = i;
            source[i].clip[3] = 1;
            source[i].fog = i + 0.125f;
            source[i].point_size = i + 1;
            for (unsigned c = 0; c < 4; c++) {
                for (unsigned k = 0; k < 4; k++) {
                    source[i].color[c][k] = 100 * i + 10 * c + k;
                    source[i].texcoord[c][k] = 1000 * i + 100 * c + k;
                }
            }
        }
        id<MTLBuffer> input =
            [commands.device newBufferWithBytes:source
                                         length:sizeof(source)
                                        options:MTLResourceStorageModeShared];
        assert(input);
        const struct {
            enum NV2AMetalPrimitive primitive;
            unsigned count;
            unsigned output[24];
            unsigned outputCount;
            MTLPrimitiveType type;
            unsigned provokingFirst[7], provokingLast[7];
            unsigned perPrimitive;
        } cases[] = {
            { NV2AMetalPrimitivePoints,
              3,
              { 0, 1, 2 },
              3,
              MTLPrimitiveTypePoint,
              { 0, 1, 2 },
              { 0, 1, 2 },
              1 },
            { NV2AMetalPrimitiveLines,
              7,
              { 0, 1, 2, 3, 4, 5 },
              6,
              MTLPrimitiveTypeLine,
              { 0, 2, 4 },
              { 1, 3, 5 },
              2 },
            { NV2AMetalPrimitiveLineStrip,
              4,
              { 0, 1, 1, 2, 2, 3 },
              6,
              MTLPrimitiveTypeLine,
              { 0, 1, 2 },
              { 1, 2, 3 },
              2 },
            { NV2AMetalPrimitiveLineLoop,
              4,
              { 0, 1, 1, 2, 2, 3, 3, 0 },
              8,
              MTLPrimitiveTypeLine,
              { 0, 1, 2, 3 },
              { 1, 2, 3, 0 },
              2 },
            { NV2AMetalPrimitiveTriangles,
              7,
              { 0, 1, 2, 3, 4, 5 },
              6,
              MTLPrimitiveTypeTriangle,
              { 0, 3 },
              { 2, 5 },
              3 },
            { NV2AMetalPrimitiveTriangleStrip,
              5,
              { 0, 1, 2, 1, 3, 2, 2, 3, 4 },
              9,
              MTLPrimitiveTypeTriangle,
              { 0, 1, 2 },
              { 2, 3, 4 },
              3 },
            { NV2AMetalPrimitiveTriangleFan,
              5,
              { 0, 1, 2, 0, 2, 3, 0, 3, 4 },
              9,
              MTLPrimitiveTypeTriangle,
              { 0, 0, 0 },
              { 1, 2, 3 },
              3 },
            { NV2AMetalPrimitiveQuads,
              7,
              { 1, 2, 0, 2, 3, 0 },
              6,
              MTLPrimitiveTypeTriangle,
              { 3 },
              { 3 },
              6 },
            { NV2AMetalPrimitiveQuadStrip,
              7,
              { 0, 1, 2, 2, 1, 3, 2, 3, 4, 4, 3, 5 },
              12,
              MTLPrimitiveTypeTriangle,
              { 3, 5 },
              { 3, 5 },
              6 },
            { NV2AMetalPrimitivePolygon,
              5,
              { 0, 1, 2, 0, 2, 3, 0, 3, 4 },
              9,
              MTLPrimitiveTypeTriangle,
              { 2, 3, 4 },
              { 2, 3, 4 },
              3 },
        };
        for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
            for (unsigned smooth = 0; smooth < 2; smooth++) {
                for (unsigned first = 0; first < 2; first++) {
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalGeometryResult *result =
                        expand(commands, geometry, input, cases[c].count,
                               cases[c].primitive, NV2AMetalPolygonFill, smooth,
                               first, NO);
                    finish(commands);
                    check_vertices(result, source, cases[c].output,
                                   cases[c].outputCount, cases[c].type);
                    if (smooth || c == 0) {
                        const NV2AMetalVertex *output =
                            result.vertices.contents;
                        for (unsigned i = 0; i < cases[c].outputCount; i++) {
                            assert(memcmp(output[i].color,
                                          source[cases[c].output[i]].color,
                                          sizeof(output[i].color)) == 0);
                        }
                    } else {
                        check_flat(result, source,
                                   first ? cases[c].provokingFirst :
                                           cases[c].provokingLast,
                                   cases[c].perPrimitive);
                    }
                }
            }
        }

        /* Polygon raster modes emit only original boundaries, never the
         * triangulation diagonal. Quad strips preserve their alternating edge.
         */
        const struct {
            enum NV2AMetalPrimitive primitive;
            enum NV2AMetalPolygonMode polygon;
            unsigned count, order[16], outputCount;
        } raster[] = {
            { NV2AMetalPrimitiveTriangles,
              NV2AMetalPolygonLine,
              3,
              { 0, 1, 1, 2, 2, 0 },
              6 },
            { NV2AMetalPrimitiveTriangles,
              NV2AMetalPolygonPoint,
              3,
              { 0, 1, 2 },
              3 },
            { NV2AMetalPrimitiveQuads,
              NV2AMetalPolygonLine,
              4,
              { 0, 1, 1, 2, 2, 3, 3, 0 },
              8 },
            { NV2AMetalPrimitiveQuads,
              NV2AMetalPolygonPoint,
              4,
              { 0, 1, 2, 3 },
              4 },
            { NV2AMetalPrimitiveQuadStrip,
              NV2AMetalPolygonLine,
              6,
              { 0, 1, 1, 3, 3, 2, 2, 0, 2, 3, 3, 5, 5, 4, 4, 2 },
              16 },
            { NV2AMetalPrimitiveQuadStrip,
              NV2AMetalPolygonPoint,
              6,
              { 0, 1, 2, 3, 2, 3, 4, 5 },
              8 },
            { NV2AMetalPrimitivePolygon,
              NV2AMetalPolygonLine,
              4,
              { 0, 1, 1, 2, 2, 3, 3, 0 },
              8 },
        };
        for (unsigned c = 0; c < sizeof(raster) / sizeof(raster[0]); c++) {
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalGeometryResult *result =
                expand(commands, geometry, input, raster[c].count,
                       raster[c].primitive, raster[c].polygon, YES, NO, NO);
            finish(commands);
            check_vertices(result, source, raster[c].order,
                           raster[c].outputCount,
                           raster[c].polygon == NV2AMetalPolygonLine ?
                               MTLPrimitiveTypeLine :
                               MTLPrimitiveTypePoint);
            const NV2AMetalVertex *output = result.vertices.contents;
            for (unsigned i = 0; i < raster[c].outputCount; i++) {
                close_float(
                    output[i].slope,
                    raster[c].primitive == NV2AMetalPrimitivePolygon ? 0 : 3);
                if (raster[c].polygon == NV2AMetalPolygonPoint) {
                    for (unsigned p = 0; p < 3; p++) {
                        assert(memcmp(output[i].plane[p],
                                      source[raster[c].order[i]].screen,
                                      sizeof(output[i].plane[p])) == 0);
                    }
                }
            }
        }

        /* Non-planar quads must retain two different depth planes, including
         * when their boundary is rendered as lines or points. */
        NV2AMetalVertex bent[4] = { source[0], source[1], source[2],
                                    source[3] };
        bent[3].screen[2] += 8;
        id<MTLBuffer> bentBuffer =
            [commands.device newBufferWithBytes:bent
                                         length:sizeof(bent)
                                        options:MTLResourceStorageModeShared];
        for (unsigned strip = 0; strip < 2; strip++) {
            for (unsigned polygon = NV2AMetalPolygonFill;
                 polygon <= NV2AMetalPolygonLine; polygon++) {
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalGeometryResult *result =
                    expand(commands, geometry, bentBuffer, 4,
                           strip ? NV2AMetalPrimitiveQuadStrip :
                                   NV2AMetalPrimitiveQuads,
                           polygon, NO, YES, NO);
                finish(commands);
                const NV2AMetalVertex *output = result.vertices.contents;
                const unsigned provoking[] = { 3 };
                check_flat(result, bent, provoking,
                           (unsigned)result.vertexCount);
                for (unsigned i = 0; i < result.vertexCount; i++) {
                    BOOL second = polygon == NV2AMetalPolygonLine ?
                                      (strip ? i >= 2 && i < 6 : i >= 4) :
                                      i >= 3;
                    close_float(output[i].slope, second ? 6 : 3);
                }
            }
        }

        require([commands beginWithError:&error] != nil, error);
        NV2AMetalGeometryResult *triangle =
            expand(commands, geometry, input, 3, NV2AMetalPrimitiveTriangles,
                   NV2AMetalPolygonFill, YES, YES, NO);
        /* Two dependent dispatches also test explicit compute barriers and
         * argument table snapshots within one command buffer. */
        NV2AMetalGeometryResult *again = expand(
            commands, geometry, triangle.vertices, 3,
            NV2AMetalPrimitiveTriangles, NV2AMetalPolygonFill, YES, YES, NO);
        NV2AMetalGeometryResult *perspective =
            expand(commands, geometry, input, 3, NV2AMetalPrimitiveTriangles,
                   NV2AMetalPolygonFill, YES, YES, YES);
        NV2AMetalGeometryResult *line =
            expand(commands, geometry, input, 2, NV2AMetalPrimitiveLines,
                   NV2AMetalPolygonFill, YES, YES, NO);
        finish(commands);
        const NV2AMetalVertex *a = again.vertices.contents;
        const NV2AMetalVertex *b = perspective.vertices.contents;
        for (unsigned i = 0; i < 3; i++) {
            close_float(a[i].slope, 3);
            close_float(b[i].slope, 0.25f);
            for (unsigned p = 0; p < 3; p++) {
                assert(memcmp(a[i].plane[p], source[p].screen,
                              sizeof(source[p].screen)) == 0);
            }
        }
        const NV2AMetalVertex *l = line.vertices.contents;
        close_float(l[0].plane[2][0], 0);
        close_float(l[0].plane[2][1], 2);
        close_float(l[0].plane[2][2], 1);
        close_float(l[0].plane[2][3], 1);
        close_float(l[0].slope, 0);

        /* Degenerate planes must not send a NaN/Inf depth slope downstream. */
        NV2AMetalVertex degenerate[3] = { source[0], source[1], source[2] };
        for (unsigned i = 0; i < 3; i++) {
            degenerate[i].screen[0] = degenerate[i].screen[1] = 0;
        }
        id<MTLBuffer> degenerateBuffer =
            [commands.device newBufferWithBytes:degenerate
                                         length:sizeof(degenerate)
                                        options:MTLResourceStorageModeShared];
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalGeometryResult *degenerateResult = expand(
            commands, geometry, degenerateBuffer, 3,
            NV2AMetalPrimitiveTriangles, NV2AMetalPolygonFill, NO, NO, NO);
        finish(commands);
        const NV2AMetalVertex *d = degenerateResult.vertices.contents;
        close_float(d[0].slope, 0);

        require([commands beginWithError:&error] != nil, error);
        for (unsigned primitive = NV2AMetalPrimitivePoints;
             primitive <= NV2AMetalPrimitivePolygon; primitive++) {
            NV2AMetalGeometryResult *empty =
                expand(commands, geometry, input, 0, primitive,
                       NV2AMetalPolygonFill, NO, NO, NO);
            assert(empty.vertexCount == 0 && !empty.vertices);
        }
        assert(![geometry encodeVertices:input
                                   count:8
                               primitive:NV2AMetalPrimitiveTriangles
                                 polygon:NV2AMetalPolygonFill
                                  smooth:NO
                          firstProvoking:NO
                            zPerspective:NO
                                commands:commands
                                   error:&error]);
        assert(error);
        error = nil;
        assert(![geometry encodeVertices:input
                                   count:3
                               primitive:NV2AMetalPrimitivePolygon
                                 polygon:NV2AMetalPolygonPoint
                                  smooth:NO
                          firstProvoking:NO
                            zPerspective:NO
                                commands:commands
                                   error:&error]);
        assert(error);
        [commands cancel];
        w_slope_range(commands, geometry);
        raster_faces(commands, geometry);
        compare_native_culling(commands, geometry);
        puts("Metal 4 geometry topology, winding, provoking colors, planes and "
             "hazards: PASS (offscreen)");
        printf("Metal 4 geometry raster: %u face-mode cases, %u native cull "
               "image comparisons, %u vertex-slice rejects PASS\n",
               face_cases, cull_images, slice_rejects);
    }
    return 0;
}
