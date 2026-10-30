/* Native Metal 4 original-face/color selection, no app/VM/window.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NV2AMetalCommands *commands;
static NV2AMetalGeometry *geometry;
static NV2AMetalPixelShader *pixel;
static unsigned cases, selected_pixels, clipped_cases, native_cases;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Two-sided: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static unsigned inputs(NV2AMetalVertex *v, unsigned primitive, bool reverse)
{
    const float triangle[4][2] = { { 3, 3 }, { 13, 3 }, { 3, 13 }, { 13, 13 } };
    const float quad[4][2] = { { 3, 3 }, { 13, 3 }, { 13, 13 }, { 3, 13 } };
    bool cyclic = primitive == NV2AMetalPrimitiveQuads ||
                  primitive == NV2AMetalPrimitivePolygon;
    unsigned count = cyclic || primitive == NV2AMetalPrimitiveQuadStrip ? 4 :
                     primitive == NV2AMetalPrimitiveLines               ? 2 :
                                                                          3;
    memset(v, 0, sizeof(*v) * 4);
    for (unsigned i = 0; i < count; i++) {
        float x = cyclic ? quad[i][0] : triangle[i][0];
        float y = cyclic ? quad[i][1] : triangle[i][1];
        if (reverse)
            x = 16 - x;
        float w = (float[]){ 1, .75f, 2, 1.25f }[i];
        v[i].clip[0] = (x / 8 - 1) * w;
        v[i].clip[1] = (1 - y / 8) * w;
        v[i].clip[2] = .5f * w;
        v[i].clip[3] = w;
        v[i].screen[0] = x;
        v[i].screen[1] = y;
        v[i].screen[2] = 32768;
        v[i].screen[3] = w;
        v[i].point_size = 3;
        for (unsigned side = 0; side < 2; side++) {
            v[i].color[2 * side][0] = .1f + .4f * side + .05f * i;
            v[i].color[2 * side][1] = .2f + .3f * side + .04f * i;
            v[i].color[2 * side][2] = .3f + .2f * side + .03f * i;
            v[i].color[2 * side][3] = .4f + .15f * side + .05f * i;
            v[i].color[2 * side + 1][0] = .2f + .3f * side + .02f * i;
            v[i].color[2 * side + 1][1] = .3f + .2f * side + .03f * i;
            v[i].color[2 * side + 1][2] = .4f + .1f * side + .04f * i;
            v[i].color[2 * side + 1][3] = .3f + .4f * side + .02f * i;
        }
        /* Geometry must derive the source face, never trust input transport. */
        v[i].face = NV2AMetalFaceBack;
    }
    return count;
}
static bool front_face(const NV2AMetalVertex *v, bool clockwise)
{
    double x0 = v[0].clip[0] / v[0].clip[3], y0 = v[0].clip[1] / v[0].clip[3];
    double x1 = v[1].clip[0] / v[1].clip[3], y1 = v[1].clip[1] / v[1].clip[3];
    double x2 = v[2].clip[0] / v[2].clip[3], y2 = v[2].clip[1] / v[2].clip[3];
    double area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0);
    return clockwise ? area < 0 : area > 0;
}
static id<MTLTexture> render(id<MTLBuffer> buffer, NSUInteger count,
                             MTLPrimitiveType primitive, bool two_side,
                             bool smooth, bool specular, unsigned output,
                             bool clockwise, bool ignore)
{
    NSError *error = nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:16
                                    height:16
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
    assert(target);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(17. / 255, 31. / 255, 47. / 255, 63. / 255);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    NV2AMetalDrawConfig c = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE },
        .setup_raster = clockwise ? 0 : NV_PGRAPH_SETUPRASTER_FRONTFACE,
        .viewport_width = 16,
        .viewport_height = 16,
    };
    if (output == 1 || output == 3)
        c.blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
    if (output == 2)
        c.blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12;
    if (output == 3)
        c.control[0] |= NV_PGRAPH_CONTROL_0_DITHERENABLE;
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&c
                                             error:&error];
    require(raster != nil, error);
    NV2AMetalPixelUniforms u = {
        .clip_range = { 0, 65535, 0, 65535 },
        .clip_regions = { { 0, 0, 16, 16 } },
        .surface_scale = { 1, 1 },
        .depth_format = NV2AMetalPixelDepthD16,
        .smooth_shading = smooth,
        .two_side = two_side,
    };
    unsigned channel = specular ? PS_REGISTER_V1 : PS_REGISTER_V0;
    u.combiner.final_inputs[0] = channel;
    u.combiner.final_inputs[1] = (channel | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([pixel encodeVertices:buffer
                              offset:0
                               count:count
                           primitive:primitive
                            uniforms:&u
                            textures:textures
                                pass:pass
                           drawState:raster
                ignorePolygonCulling:ignore
                            commands:commands
                               error:&error],
            error);
    return target;
}
static void compare(id<MTLTexture> actual, id<MTLTexture> expected, bool empty)
{
    uint8_t a[16][16][4], b[16][16][4];
    [actual getBytes:a
         bytesPerRow:64
          fromRegion:MTLRegionMake2D(0, 0, 16, 16)
         mipmapLevel:0];
    [expected getBytes:b
           bytesPerRow:64
            fromRegion:MTLRegionMake2D(0, 0, 16, 16)
           mipmapLevel:0];
    unsigned covered = 0;
    const uint8_t clear[] = { 17, 31, 47, 63 };
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            if (memcmp(a[y][x], b[y][x], 4)) {
                fprintf(stderr,
                        "Two-sided case%u pixel%u,%u actual %u/%u/%u/%u "
                        "expected %u/%u/%u/%u\n",
                        cases, x, y, a[y][x][0], a[y][x][1], a[y][x][2],
                        a[y][x][3], b[y][x][0], b[y][x][1], b[y][x][2],
                        b[y][x][3]);
                abort();
            }
            covered += memcmp(a[y][x], clear, 4) != 0;
        }
    assert(empty ? covered == 0 : covered > 0);
    selected_pixels += covered;
    clipped_cases += empty;
    cases++;
}
static void raster_case(unsigned primitive, unsigned mode, unsigned transport,
                        bool clockwise, bool reverse, bool smooth, bool enabled,
                        bool specular, unsigned cull)
{
    NSError *error = nil;
    NV2AMetalVertex a[4], b[4];
    unsigned count = inputs(a, primitive, reverse);
    bool polygon = primitive >= NV2AMetalPrimitiveTriangles;
    bool front = !polygon || front_face(a, clockwise);
    memcpy(b, a, sizeof(b));
    if (enabled && !front)
        for (unsigned i = 0; i < count; i++) {
            memcpy(b[i].color[0], a[i].color[2], 16);
            memcpy(b[i].color[1], a[i].color[3], 16);
        }
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryRasterConfig c = {
        .front = mode,
        .back = mode,
        .frontClockwise = clockwise,
        .lineWidth = transport == 0 ? 1 :
                     transport == 1 ? 3 :
                                      2.25f,
        .lineSmooth = transport == 2,
        .polygonSmooth = transport == 2,
        .viewportWidth = 16,
        .viewportHeight = 16,
        .cullFront = cull == 1 || cull == 3,
        .cullBack = cull == 2 || cull == 3,
    };
    id<MTLTexture> targets[2];
    NV2AMetalGeometryResult *results[2];
    unsigned output = (primitive + mode + transport + clockwise + reverse +
                       smooth + enabled + specular) %
                      4;
    for (unsigned side = 0; side < 2; side++) {
        id<MTLBuffer> buffer =
            [commands.device newBufferWithBytes:side ? b : a
                                         length:count * sizeof(*a)
                                        options:MTLResourceStorageModeShared];
        assert(buffer);
        NSArray<NV2AMetalGeometryResult *> *streams =
            [geometry encodeRasterVertices:buffer
                                     count:count
                                 primitive:primitive
                                    config:&c
                                    smooth:smooth
                            firstProvoking:!reverse
                              zPerspective:NO
                                  commands:commands
                                     error:&error];
        require(streams != nil && streams.count == 1, error);
        results[side] = streams[0];
        targets[side] =
            render(results[side].vertices, results[side].vertexCount,
                   results[side].primitiveType, side ? false : enabled, smooth,
                   specular, output, clockwise, YES);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    bool empty = polygon && (front ? c.cullFront : c.cullBack);
    for (unsigned side = 0; side < 2; side++) {
        const NV2AMetalVertex *v = results[side].vertices.contents;
        for (NSUInteger i = 0; i < results[side].vertexCount; i++)
            if (!empty)
                assert(v[i].face ==
                       (front ? NV2AMetalFaceFront : NV2AMetalFaceBack));
    }
    compare(targets[0], targets[1], empty);
}
static void mixed_modes(unsigned front_mode, unsigned back_mode,
                        unsigned transport, bool clockwise, bool smooth)
{
    NSError *error = nil;
    NV2AMetalVertex a[6], b[6], first[4], second[4];
    inputs(first, NV2AMetalPrimitiveTriangles, false);
    inputs(second, NV2AMetalPrimitiveTriangles, true);
    memcpy(a, first, 3 * sizeof(*a));
    memcpy(a + 3, second, 3 * sizeof(*a));
    memcpy(b, a, sizeof(b));
    for (unsigned p = 0; p < 2; p++)
        if (!front_face(a + 3 * p, clockwise))
            for (unsigned i = 0; i < 3; i++) {
                memcpy(b[3 * p + i].color[0], a[3 * p + i].color[2], 16);
                memcpy(b[3 * p + i].color[1], a[3 * p + i].color[3], 16);
            }
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryRasterConfig c = {
        .front = front_mode,
        .back = back_mode,
        .frontClockwise = clockwise,
        .lineWidth = transport == 0 ? 1 :
                     transport == 1 ? 3 :
                                      2.25f,
        .lineSmooth = transport == 2,
        .polygonSmooth = transport == 2,
        .viewportWidth = 16,
        .viewportHeight = 16,
    };
    NSArray<NV2AMetalGeometryResult *> *streams[2];
    id<MTLTexture> targets[2][2];
    for (unsigned side = 0; side < 2; side++) {
        id<MTLBuffer> buffer =
            [commands.device newBufferWithBytes:side ? b : a
                                         length:sizeof(a)
                                        options:MTLResourceStorageModeShared];
        streams[side] =
            [geometry encodeRasterVertices:buffer
                                     count:6
                                 primitive:NV2AMetalPrimitiveTriangles
                                    config:&c
                                    smooth:smooth
                            firstProvoking:YES
                              zPerspective:NO
                                  commands:commands
                                     error:&error];
        require(streams[side] != nil &&
                    streams[side].count == (front_mode == back_mode ? 1 : 2),
                error);
        for (unsigned i = 0; i < streams[side].count; i++) {
            NV2AMetalGeometryResult *g = streams[side][i];
            targets[side][i] = render(
                g.vertices, g.vertexCount, g.primitiveType, !side, smooth,
                (front_mode + back_mode) % 2,
                (front_mode + back_mode + transport + clockwise + smooth) % 4,
                clockwise, YES);
        }
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    for (unsigned i = 0; i < streams[0].count; i++) {
        NV2AMetalGeometryResult *g = streams[0][i];
        const NV2AMetalVertex *v = g.vertices.contents;
        for (unsigned p = 0; p < 2; p++) {
            bool front = front_face(a + 3 * p, clockwise);
            for (NSUInteger k = 0; k < g.verticesPerPrimitive; k++) {
                const NV2AMetalVertex *out = v + p * g.verticesPerPrimitive + k;
                if (streams[0].count == 1 || i == (front ? 0 : 1))
                    assert(out->face ==
                           (front ? NV2AMetalFaceFront : NV2AMetalFaceBack));
                else
                    assert(out->face == NV2AMetalFaceNative &&
                           out->clip[0] == 2);
            }
        }
        compare(targets[0][i], targets[1][i], false);
    }
}

static void direct_case(unsigned primitive, bool clockwise, bool reverse,
                        bool enabled, bool specular)
{
    NSError *error = nil;
    NV2AMetalVertex a[4], b[4];
    unsigned count = inputs(a, primitive, reverse);
    bool front =
        primitive != NV2AMetalPrimitiveTriangles || front_face(a, clockwise);
    memcpy(b, a, sizeof(b));
    for (unsigned i = 0; i < count; i++) {
        a[i].face = b[i].face = NV2AMetalFaceNative;
        for (unsigned j = 0; j < 3; j++)
            memcpy(a[i].plane[j],
                   a[primitive == NV2AMetalPrimitiveTriangles ? j : i].screen,
                   16);
        memcpy(b[i].plane, a[i].plane, sizeof(a[i].plane));
        if (enabled && !front) {
            memcpy(b[i].color[0], a[i].color[2], 16);
            memcpy(b[i].color[1], a[i].color[3], 16);
        }
    }
    require([commands beginWithError:&error] != nil, error);
    id<MTLTexture> targets[2];
    for (unsigned side = 0; side < 2; side++) {
        id<MTLBuffer> buffer =
            [commands.device newBufferWithBytes:side ? b : a
                                         length:count * sizeof(*a)
                                        options:MTLResourceStorageModeShared];
        targets[side] = render(
            buffer, count,
            primitive == NV2AMetalPrimitivePoints ? MTLPrimitiveTypePoint :
            primitive == NV2AMetalPrimitiveLines  ? MTLPrimitiveTypeLine :
                                                    MTLPrimitiveTypeTriangle,
            side ? false : enabled, YES, specular,
            (clockwise + reverse + enabled + specular) % 4, clockwise, NO);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    compare(targets[0], targets[1], false);
    native_cases++;
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        geometry = [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                       error:&error];
        require(geometry != nil, error);
        pixel = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA8Unorm
               depthFormat:MTLPixelFormatInvalid
               sampleCount:1
                     error:&error];
        require(pixel != nil, error);
        for (unsigned primitive = 1; primitive <= 10; primitive++)
            for (unsigned mode = 0; mode < (primitive < 5 ? 1 : 3); mode++) {
                /* Existing PRIM_POLYGON point-mode limitation needs hardware
                 * proof. */
                if (primitive == NV2AMetalPrimitivePolygon &&
                    mode == NV2AMetalPolygonPoint)
                    continue;
                for (unsigned transport = 0; transport < 3; transport++)
                    for (unsigned clockwise = 0; clockwise < 2; clockwise++)
                        for (unsigned reverse = 0; reverse < 2; reverse++)
                            for (unsigned smooth = 0; smooth < 2; smooth++)
                                for (unsigned enabled = 0; enabled < 2;
                                     enabled++)
                                    for (unsigned specular = 0; specular < 2;
                                         specular++)
                                        raster_case(primitive, mode, transport,
                                                    clockwise, reverse, smooth,
                                                    enabled, specular, 0);
            }
        for (unsigned cull = 0; cull < 4; cull++)
            for (unsigned mode = 0; mode < 3; mode++)
                for (unsigned reverse = 0; reverse < 2; reverse++)
                    for (unsigned clockwise = 0; clockwise < 2; clockwise++)
                        raster_case(NV2AMetalPrimitiveTriangles, mode, 2,
                                    clockwise, reverse, YES, YES, NO, cull);
        for (unsigned front = 0; front < 3; front++)
            for (unsigned back = 0; back < 3; back++)
                for (unsigned transport = 0; transport < 3; transport++)
                    for (unsigned clockwise = 0; clockwise < 2; clockwise++)
                        for (unsigned smooth = 0; smooth < 2; smooth++)
                            mixed_modes(front, back, transport, clockwise,
                                        smooth);
        for (unsigned primitive = 1; primitive <= 5;
             primitive += primitive == 1 ? 1 : 3)
            for (unsigned clockwise = 0; clockwise < 2; clockwise++)
                for (unsigned reverse = 0; reverse < 2; reverse++)
                    for (unsigned enabled = 0; enabled < 2; enabled++)
                        for (unsigned specular = 0; specular < 2; specular++)
                            direct_case(primitive, clockwise, reverse, enabled,
                                        specular);
        printf("Metal4 two-sided raster: %u image pairs, %u selected pixels, "
               "%u culled cases, %u native cases PASS\n",
               cases, selected_pixels, clipped_cases, native_cases);
    }
    return 0;
}
