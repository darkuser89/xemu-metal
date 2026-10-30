/* Native wide/smooth line validation against independent double references.
 * No VM, app or window is started. SPDX-License-Identifier: LGPL-2.0-or-later
 */
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    double x, y;
} LinePoint;
static NV2AMetalCommands *commands;
static NV2AMetalGeometry *geometry;
static NV2AMetalPixelShader *pixel;
static unsigned images, rejected, w_clip_images, w_clip_depths;
static unsigned w_clip_boundaries;
static unsigned w_triangle_images, w_triangle_depths, w_triangle_boundaries;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Native lines: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void close_value(float actual, double expected, unsigned x, unsigned y)
{
    if (!isfinite(actual) || fabs(actual - expected) > .00004) {
        fprintf(stderr, "Line pixel%u,%u: %g expected%.9g\n", x, y, actual,
                expected);
        abort();
    }
}
/* Independent reference: finite perturbation in double, slab clipping of a
 * transformed diamond. Test coordinates are multiples of 1/16, so these two
 * perturbations are much smaller than every nonzero geometric separation. */
static bool diamond(LinePoint a, LinePoint b, LinePoint centre)
{
    a.x -= 1e-8;
    b.x -= 1e-8;
    a.y += 1e-12;
    b.y += 1e-12;
    double pa[2] = { a.x + a.y, a.x - a.y }, pb[2] = { b.x + b.y, b.x - b.y };
    double pc[2] = { centre.x + centre.y, centre.x - centre.y };
    double enter = 0, leave = 1;
    bool end_inside = true;
    for (unsigned i = 0; i < 2; i++) {
        double lo = pc[i] - .5, hi = pc[i] + .5, d = pb[i] - pa[i];
        end_inside &= pb[i] > lo && pb[i] < hi;
        if (d == 0) {
            if (!(pa[i] > lo && pa[i] < hi))
                return false;
        } else {
            double p = (lo - pa[i]) / d, q = (hi - pa[i]) / d;
            enter = fmax(enter, fmin(p, q));
            leave = fmin(leave, fmax(p, q));
        }
    }
    return !end_inside && enter < leave;
}
static bool alias_reference(LinePoint a, LinePoint b, LinePoint centre,
                            double width)
{
    unsigned w = (unsigned)fmax(1, floor(width + .5));
    bool x_major = fabs(b.x - a.x) >= fabs(b.y - a.y);
    if (x_major) {
        a.y += (w - 1) * .5;
        b.y += (w - 1) * .5;
    } else {
        a.x -= (w - 1) * .5;
        b.x -= (w - 1) * .5;
    }
    for (unsigned k = 0; k < w; k++) {
        LinePoint c = centre;
        if (x_major)
            c.y += k;
        else
            c.x -= k;
        if (diamond(a, b, c))
            return true;
    }
    return false;
}
/* GPU clips a pixel square by oblique halfplanes. This reference instead
 * clips the oblique line rectangle by the pixel's four axis-aligned sides. */
static double coverage_reference(LinePoint a, LinePoint b, LinePoint centre,
                                 double width)
{
    double dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy);
    double nx = -dy / length * width * .5, ny = dx / length * width * .5;
    LinePoint polygon[12] = { { a.x + nx, a.y + ny },
                              { a.x - nx, a.y - ny },
                              { b.x - nx, b.y - ny },
                              { b.x + nx, b.y + ny } };
    unsigned count = 4;
    for (unsigned side = 0; side < 4 && count; side++) {
        LinePoint next[12];
        unsigned n = 0;
        unsigned axis = side / 2;
        double boundary = (axis ? centre.y : centre.x) + (side % 2 ? .5 : -.5);
        LinePoint previous = polygon[count - 1];
        double pv = axis ? previous.y : previous.x;
        bool pi = side % 2 ? pv <= boundary : pv >= boundary;
        for (unsigned i = 0; i < count; i++) {
            LinePoint current = polygon[i];
            double cv = axis ? current.y : current.x;
            bool ci = side % 2 ? cv <= boundary : cv >= boundary;
            if (pi != ci) {
                double t = (boundary - pv) / (cv - pv);
                next[n++] =
                    (LinePoint){ previous.x + t * (current.x - previous.x),
                                 previous.y + t * (current.y - previous.y) };
            }
            if (ci)
                next[n++] = current;
            previous = current;
            pv = cv;
            pi = ci;
        }
        count = n;
        memcpy(polygon, next, n * sizeof(LinePoint));
    }
    double area = 0;
    for (unsigned i = 0; i < count; i++) {
        LinePoint a = polygon[i], b = polygon[(i + 1) % count];
        a.x -= centre.x;
        a.y -= centre.y;
        b.x -= centre.x;
        b.y -= centre.y;
        area += a.x * b.y - a.y * b.x;
    }
    return fmin(1, fabs(area) * .5);
}
static NV2AMetalVertex vertex(LinePoint p, float w, bool second)
{
    NV2AMetalVertex v = { 0 };
    v.clip[0] = (p.x / 8 - 1) * w;
    v.clip[1] = (1 - p.y / 8) * w;
    v.clip[2] = .5f * w;
    v.clip[3] = w;
    v.screen[0] = p.x;
    v.screen[1] = p.y;
    v.screen[2] = second ? 2000 : 1000;
    v.screen[3] = w;
    v.color[0][second ? 1 : 0] = 1;
    v.color[0][3] = 1;
    v.fog = second ? .8f : .2f;
    v.texcoord[0][0] = second ? .8f : .1f;
    v.texcoord[0][1] = .5f;
    v.texcoord[0][3] = 1;
    return v;
}
static void render_depth_case(LinePoint original_a, LinePoint original_b,
                              LinePoint clipped_a, LinePoint clipped_b,
                              float wa, float wb, float width, bool smooth,
                              bool flat, bool texture, bool blend,
                              bool alpha_test, bool perspective_depth, bool f24,
                              bool triangle)
{
    NSError *error = nil;
    LinePoint third = { original_a.x - (original_b.y - original_a.y),
                        original_a.y + (original_b.x - original_a.x) };
    NV2AMetalVertex input[3] = { vertex(original_a, wa, false),
                                 vertex(original_b, wb, true),
                                 vertex(third, wa, false) };
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(buffer);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryRasterConfig c = { .lineWidth = width,
                                        .lineSmooth = smooth,
                                        .viewportWidth = 16,
                                        .viewportHeight = 16,
                                        .cullFront = !triangle,
                                        .cullBack = !triangle };
    NSArray<NV2AMetalGeometryResult *> *streams =
        [geometry encodeRasterVertices:buffer
                                 count:triangle ? 3 : 2
                             primitive:triangle ? NV2AMetalPrimitiveTriangles :
                                                  NV2AMetalPrimitiveLines
                                config:&c
                                smooth:!flat
                        firstProvoking:YES
                          zPerspective:perspective_depth
                              commands:commands
                                 error:&error];
    require(streams != nil, error);
    NV2AMetalGeometryResult *g = streams[0];
    assert(g.expandedLines ==
           (!triangle && (width > 1 || smooth || perspective_depth)));
    assert(g.vertexCount == (triangle ? 3 : g.expandedLines ? 6 : 2));
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:16
                                    height:16
                                 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
    assert(target);
    d.pixelFormat = MTLPixelFormatDepth32Float;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [commands.device newTextureWithDescriptor:d];
    assert(depth);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    NV2AMetalDrawConfig draw = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                     NV_PGRAPH_CONTROL_0_ZENABLE |
                     NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16 },
        .setup_raster = NV_PGRAPH_SETUPRASTER_CULLENABLE | 3 << 21,
        .blend = blend ? NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8 : 0
    };
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&draw
                                             error:&error];
    require(raster != nil, error);
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, 16, 16 } },
                                 .surface_scale = { 1, 1 },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .smooth_shading = !flat,
                                 .alpha_test = alpha_test,
                                 .alpha_func = 4,
                                 .alpha_ref = 254,
                                 .z_perspective = perspective_depth };
    if (f24) {
        u.depth_format = NV2AMetalPixelDepthF24;
        u.clip_range[1] = u.clip_range[3] = 0x1.ffffp127f;
    }
    u.combiner.final_inputs[0] = texture ? PS_REGISTER_T0 : PS_REGISTER_V0;
    u.combiner.final_inputs[1] =
        ((texture ? PS_REGISTER_T0 : PS_REGISTER_V0) | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { 0 };
    id<MTLTexture> sampled = nil;
    if (texture) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:8
                                        height:1
                                     mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        sampled = [commands.device newTextureWithDescriptor:td];
        assert(sampled);
        float texels[8][4];
        for (unsigned i = 0; i < 8; i++) {
            texels[i][0] = i / 8.f;
            texels[i][1] = .25f;
            texels[i][2] = .5f;
            texels[i][3] = 1;
        }
        [sampled replaceRegion:MTLRegionMake2D(0, 0, 8, 1)
                   mipmapLevel:0
                     withBytes:texels
                   bytesPerRow:sizeof(texels)];
        textures[0].texture = sampled;
        u.textures[0].dimension = 2;
        u.textures[0].scale = 1;
        u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    }
    require([pixel encodeVertices:g.vertices
                              offset:0
                               count:g.vertexCount
                           primitive:g.primitiveType
                            uniforms:&u
                            textures:textures
                                pass:pass
                           drawState:raster
                ignorePolygonCulling:YES
                            commands:commands
                               error:&error],
            error);
    id<MTLBuffer> depths =
        [commands.device newBufferWithLength:16 * 256
                                     options:MTLResourceStorageModeShared];
    assert(depths);
    require([commands addResource:depths error:&error], error);
    id<MTL4ComputeCommandEncoder> copy =
        [commands.commandBuffer computeCommandEncoder];
    assert(copy);
    [copy barrierAfterQueueStages:MTLStageAll
                     beforeStages:MTLStageBlit
                visibilityOptions:MTL4VisibilityOptionDevice];
    [copy copyFromTexture:depth
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(16, 16, 1)
                        toBuffer:depths
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [copy endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    float pixels[16][16][4];
    [target getBytes:pixels
         bytesPerRow:16 * 16
          fromRegion:MTLRegionMake2D(0, 0, 16, 16)
         mipmapLevel:0];
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            LinePoint centre = { x + .5, y + .5 };
            double coverage =
                smooth ?
                    coverage_reference(clipped_a, clipped_b, centre, width) :
                    alias_reference(clipped_a, clipped_b, centre, width);
            double dx = original_b.x - original_a.x,
                   dy = original_b.y - original_a.y;
            double t = ((centre.x - original_a.x) * dx +
                        (centre.y - original_a.y) * dy) /
                       (dx * dx + dy * dy);
            if (triangle) {
                double along = (centre.x - original_a.x) * dx +
                               (centre.y - original_a.y) * dy;
                double across = dx * (centre.y - original_a.y) -
                                dy * (centre.x - original_a.x);
                BOOL top_left =
                    third.y < original_b.y ||
                    (third.y == original_b.y && third.x > original_b.x);
                coverage = along >= 0 && across >= 0 &&
                           (along + across < dx * dx + dy * dy ||
                            (top_left && along + across == dx * dx + dy * dy));
            }
            double pt = (t / wb) / ((1 - t) / wa + t / wb);
            double expected[4] = { 0, 0, 1, 0 }, z = 1;
            uint32_t expected_bits = 0;
            if (coverage > 1e-7) {
                if (texture) {
                    int texel = (int)floor((.1 + pt * .7) * 8);
                    texel = texel < 0 ? 0 : texel > 7 ? 7 : texel;
                    expected[0] = texel / 8.;
                    expected[1] = .25;
                    expected[2] = .5;
                } else {
                    expected[0] = flat ? 1 : fmax(0, 1 - pt);
                    expected[1] = flat ? 0 : fmax(0, pt);
                    expected[2] = 0;
                }
                expected[3] = coverage;
                if (blend) {
                    expected[0] *= coverage;
                    expected[1] *= coverage;
                    expected[2] = expected[2] * coverage + 1 - coverage;
                    expected[3] = coverage * coverage;
                }
                if (f24) {
                    // Reciprocal interpolation avoids cancelling large W in
                    // the reference itself; never reuse the GPU arithmetic.
                    float physical = 1 / ((1 - t) / wa + t / wb);
                    memcpy(&expected_bits, &physical, 4);
                    z = (float)(expected_bits >> 7) / 16777215.0f;
                } else {
                    z = floor(perspective_depth ? wa + pt * (wb - wa) :
                                                  1000 + t * 1000) /
                        65535.;
                }
            }
            for (unsigned i = 0; i < 4; i++) {
                if (f24 && (!isfinite(pixels[y][x][i]) ||
                            fabs(pixels[y][x][i] - expected[i]) > .00004)) {
                    fprintf(stderr,
                            "W clip color W%.9g/%.9g width%g smooth%u "
                            "segment(%g,%g)-(%g,%g) pixel%u,%u channel%u: "
                            "%.9g expected%.9g\n",
                            wa, wb, width, smooth, original_a.x, original_a.y,
                            original_b.x, original_b.y, x, y, i,
                            pixels[y][x][i], expected[i]);
                    abort();
                }
                close_value(pixels[y][x][i], expected[i], x, y);
            }
            float actual_depth;
            memcpy(&actual_depth, (char *)depths.contents + y * 256 + x * 4, 4);
            if (f24) {
                BOOL matched = actual_depth == (float)z;
                if (!matched && coverage > 1e-7) {
                    // Float32 division can straddle an F24 truncation edge.
                    // Allow only its adjacent code within four Float32 ULPs
                    // of that edge, not a general depth-word tolerance.
                    unsigned remainder = expected_bits & 127;
                    uint32_t code = expected_bits >> 7;
                    if (remainder <= 4 && code)
                        matched = actual_depth == (code - 1) / 16777215.0f;
                    if (remainder >= 124)
                        matched = actual_depth == (code + 1) / 16777215.0f;
                    if (triangle)
                        w_triangle_boundaries += matched;
                    else
                        w_clip_boundaries += matched;
                }
                if (!matched) {
                    fprintf(stderr,
                            "W clip W%.9g/%.9g width%g smooth%u "
                            "pixel%u,%u: %.9g expected%.9g\n",
                            wa, wb, width, smooth, x, y, actual_depth,
                            (float)z);
                    abort();
                }
                if (triangle)
                    w_triangle_depths++;
                else
                    w_clip_depths++;
            } else {
                close_value(actual_depth, z, x, y);
            }
        }
    images++;
    w_clip_images += f24 && !triangle;
    w_triangle_images += triangle;
}

static void render_case(LinePoint a, LinePoint b, LinePoint ca, LinePoint cb,
                        float wa, float wb, float width, bool smooth, bool flat,
                        bool texture, bool blend, bool alpha_test,
                        bool perspective_depth)
{
    render_depth_case(a, b, ca, cb, wa, wb, width, smooth, flat, texture, blend,
                      alpha_test, perspective_depth, false, false);
}

static void w_clipped_depth_tests(void)
{
    const LinePoint segments[][2] = {
        { { -3.5, 7.5 }, { 19.5, 7.5 } },  { { 7.5, -3.5 }, { 7.5, 19.5 } },
        { { -3.5, 2.5 }, { 19.5, 13.5 } }, { { 19.5, 2.5 }, { -3.5, 13.5 } },
        { { 3.5, 7.5 }, { 12.5, 7.5 } },   { { -16384, 7.5 }, { 15.5625, 7.5 } }
    };
    for (unsigned segment = 0; segment < 6; segment++)
        for (unsigned exponent = 0; exponent <= 128; exponent++)
            for (unsigned reverse = 0; reverse < 2; reverse++)
                for (unsigned mode = 0; mode < 3; mode++) {
                    LinePoint a = segments[segment][0],
                              b = segments[segment][1];
                    LinePoint ca, cb;
                    if (segment == 4) {
                        // The positive-W ray enters from the right viewport
                        // boundary; it is not the finite screen-space segment.
                        ca = (LinePoint){ 16, 7.5 };
                        cb = b;
                    } else {
                        double start[2] = { a.x, a.y }, end[2] = { b.x, b.y };
                        double enter = 0, leave = 1;
                        for (unsigned axis = 0; axis < 2; axis++) {
                            double delta = end[axis] - start[axis];
                            if (!delta)
                                continue;
                            double t0 = -start[axis] / delta;
                            double t1 = (16 - start[axis]) / delta;
                            enter = fmax(enter, fmin(t0, t1));
                            leave = fmin(leave, fmax(t0, t1));
                        }
                        ca = (LinePoint){ a.x + enter * (b.x - a.x),
                                          a.y + enter * (b.y - a.y) };
                        cb = (LinePoint){ a.x + leave * (b.x - a.x),
                                          a.y + leave * (b.y - a.y) };
                    }
                    float wa =
                        ldexpf(segment == 4 ? -1 : 1, (int)exponent - 64);
                    float wb = ldexpf(1, 64 - (int)exponent);
                    if (reverse) {
                        LinePoint v = a;
                        a = b;
                        b = v;
                        v = ca;
                        ca = cb;
                        cb = v;
                        float w = wa;
                        wa = wb;
                        wb = w;
                    }
                    render_depth_case(a, b, ca, cb, wa, wb, mode ? 3 : 1,
                                      mode == 2, false, false, false, false,
                                      true, true, false);
                }
    assert(w_clip_images == 4644 && w_clip_depths == 1188864);
    printf("Metal4 W clipped lines: %u draws/%u depth words/%u boundary "
           "candidates, 129 W pairs/6 segments/2 orders/3 raster modes PASS\n",
           w_clip_images, w_clip_depths, w_clip_boundaries);
}

static void w_triangle_depth_tests(void)
{
    for (unsigned axis = 0; axis < 2; axis++)
        for (unsigned exponent = 0; exponent <= 128; exponent++) {
            LinePoint a = axis ? (LinePoint){ 15, 1 } : (LinePoint){ 1, 1 };
            LinePoint b = axis ? (LinePoint){ 15, 15 } : (LinePoint){ 15, 1 };
            render_depth_case(a, b, a, b, ldexpf(1, (int)exponent - 64),
                              ldexpf(1, 64 - (int)exponent), 1, false, false,
                              false, false, false, true, true, true);
        }
    assert(w_triangle_images == 258 && w_triangle_depths == 66048);
    printf("Metal4 W triangles: %u draws/%u depth words/%u boundary "
           "candidates, 129 W pairs/2 axes PASS\n",
           w_triangle_images, w_triangle_depths, w_triangle_boundaries);
}

static void f24_depth_tests(void)
{
    const unsigned size = 256, lines = 255, count = lines * 2;
    NSError *error = nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [commands.device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    id<MTLTexture> depth = [commands.device newTextureWithDescriptor:td];
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:size * size * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionAlways;
    ds.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depth_state =
        [commands.device newDepthStencilStateWithDescriptor:ds];
    assert(color && depth && input && readback && depth_state);
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 0x1.ffffp127f, 0,
                                                 0x1.ffffp127f },
                                 .clip_regions = { { 0, 0, size, size } },
                                 .surface_scale = { 1, 1 },
                                 .depth_format = NV2AMetalPixelDepthF24,
                                 .smooth_shading = 1 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalPixelTexture textures[4] = { 0 };
    unsigned checked = 0;
    for (unsigned axis = 0; axis < 2; axis++)
        for (unsigned reverse = 0; reverse < 2; reverse++)
            for (unsigned descending = 0; descending < 2; descending++)
                for (unsigned mode = 0; mode < 3; mode++) {
                    NV2AMetalVertex *v = input.contents;
                    memset(v, 0, input.length);
                    for (unsigned exponent = 0; exponent < lines; exponent++)
                        for (unsigned i = 0; i < 2; i++) {
                            unsigned endpoint = i ^ reverse;
                            unsigned fraction =
                                (endpoint ^ descending) ? 0x8000 : 0x4000;
                            uint32_t bits = ((exponent << 16) | fraction) << 7;
                            float x = (exponent % 32) * 8 +
                                      (axis ? 3.5f : endpoint * 8);
                            float y = (exponent / 32) * 8 +
                                      (axis ? endpoint * 8 : 3.5f);
                            NV2AMetalVertex *out = &v[2 * exponent + i];
                            out->screen[0] = x;
                            out->screen[1] = y;
                            memcpy(&out->screen[2], &bits, sizeof(bits));
                            out->screen[3] = 1;
                            out->clip[0] = x / (size * .5f) - 1;
                            out->clip[1] = 1 - y / (size * .5f);
                            out->clip[2] = .5f;
                            out->clip[3] = 1;
                        }
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalGeometryRasterConfig config = {
                        .lineWidth = mode ? 3 : 1,
                        .lineSmooth = mode == 2,
                        .viewportWidth = size,
                        .viewportHeight = size
                    };
                    NSArray<NV2AMetalGeometryResult *> *streams =
                        [geometry encodeRasterVertices:input
                                                 count:count
                                             primitive:NV2AMetalPrimitiveLines
                                                config:&config
                                                smooth:YES
                                        firstProvoking:YES
                                          zPerspective:NO
                                              commands:commands
                                                 error:&error];
                    require(streams != nil, error);
                    NV2AMetalGeometryResult *g = streams[0];
                    assert(g.expandedLines == (mode != 0));
                    MTL4RenderPassDescriptor *pass =
                        [MTL4RenderPassDescriptor new];
                    pass.colorAttachments[0].texture = color;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].storeAction =
                        MTLStoreActionDontCare;
                    pass.depthAttachment.texture = depth;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = .123f;
                    require([pixel encodeVertices:g.vertices
                                            count:g.vertexCount
                                        primitive:g.primitiveType
                                         uniforms:&u
                                         textures:textures
                                             pass:pass
                                     depthStencil:depth_state
                                         commands:commands
                                            error:&error],
                            error);
                    require([commands addResource:readback error:&error],
                            error);
                    id<MTL4ComputeCommandEncoder> copy =
                        [commands.commandBuffer computeCommandEncoder];
                    assert(copy);
                    [copy barrierAfterQueueStages:MTLStageAll
                                     beforeStages:MTLStageBlit
                                visibilityOptions:MTL4VisibilityOptionDevice];
                    [copy copyFromTexture:depth
                                     sourceSlice:0
                                     sourceLevel:0
                                    sourceOrigin:MTLOriginMake(0, 0, 0)
                                      sourceSize:MTLSizeMake(size, size, 1)
                                        toBuffer:readback
                               destinationOffset:0
                          destinationBytesPerRow:size * sizeof(float)
                        destinationBytesPerImage:0
                                         options:MTLBlitOptionNone];
                    [copy barrierAfterStages:MTLStageBlit
                           beforeQueueStages:MTLStageAll
                           visibilityOptions:MTL4VisibilityOptionDevice];
                    [copy endEncoding];
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                    const float *actual = readback.contents;
                    for (unsigned exponent = 0; exponent < lines; exponent++)
                        for (unsigned k = 1; k < 7; k++) {
                            /* Inner centreline samples avoid endpoint coverage
                             * differences. Low-exponent controls retain the
                             * original subtraction underflow. Other samples
                             * have exact integer fractions at pixel centres.
                             */
                            unsigned fraction =
                                exponent < 3 ?
                                    ((reverse ^ descending) ? 0x8000 : 0x4000) :
                                descending ? 0x8000 - 2048 * k - 1024 :
                                             0x4000 + 2048 * k + 1024;
                            unsigned code =
                                exponent ? (exponent << 16) | fraction : 0;
                            float expected = code / 16777215.0f;
                            unsigned x = (exponent % 32) * 8 + (axis ? 3 : k);
                            unsigned y = (exponent / 32) * 8 + (axis ? k : 3);
                            if (actual[y * size + x] != expected) {
                                fprintf(stderr,
                                        "F24 line axis%u reverse%u "
                                        "descending%u mode%u exponent%u k%u: "
                                        "%.9g expected %.9g\n",
                                        axis, reverse, descending, mode,
                                        exponent, k, actual[y * size + x],
                                        expected);
                                abort();
                            }
                            checked++;
                        }
                    images++;
                }
    assert(checked == 36720);
    printf("Metal 4 F24 lines: 24 Geometry->Fragment draws/36720 exact depths "
           "PASS\n");
}

#include "test-metal-line-transport.h"

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
               colorFormat:MTLPixelFormatRGBA32Float
               depthFormat:MTLPixelFormatDepth32Float
               sampleCount:1
                     error:&error];
        require(pixel != nil, error);
        line_transport_tests();
        f24_depth_tests();
        w_clipped_depth_tests();
        w_triangle_depth_tests();
        const LinePoint segments[][2] = { { { 2.5, 7.5 }, { 13.5, 7.5 } },
                                          { { 7.5, 2.5 }, { 7.5, 13.5 } },
                                          { { 2.5, 2.5 }, { 13.5, 13.5 } },
                                          { { 13.5, 2.5 }, { 2.5, 13.5 } },
                                          { { 2.5, 4.5 }, { 13.5, 8.5 } },
                                          { { 2.5, 4.5 }, { 13.5, 5.5 } },
                                          { { 4.5, 2.5 }, { 8.5, 13.5 } },
                                          { { 2.25, 5.75 }, { 13.75, 9.25 } } };
        for (unsigned s = 0; s < sizeof(segments) / sizeof(segments[0]); s++)
            for (unsigned reverse = 0; reverse < 2; reverse++)
                for (unsigned smooth = 0; smooth < 2; smooth++)
                    for (unsigned width = 2; width <= 4; width++) {
                        LinePoint a = segments[s][reverse],
                                  b = segments[s][1 - reverse];
                        render_case(a, b, a, b, 1, 1, width, smooth, false,
                                    false, false, false, false);
                    }
        LinePoint a = { 2.5, 4.25 }, b = { 13.5, 8.25 };
        render_case(a, b, a, b, 1, 3, 1.5, true, false, true, false, false,
                    false);
        render_case(a, b, a, b, 1, 3, 2, true, true, false, false, false,
                    false);
        render_case(a, b, a, b, 1, 3, 2, true, false, false, true, false,
                    false);
        render_case(a, b, a, b, 1, 3, 2, true, false, false, false, true,
                    false);
        render_case(a, b, a, b, 10, 30, 2, true, false, false, false, false,
                    true);
        LinePoint outside = { -3.5, 7.5 }, inside = { 12.5, 7.5 },
                  edge = { 0, 7.5 };
        render_case(outside, inside, edge, inside, 1, 1, 3, false, false, false,
                    false, false, false);
        outside = (LinePoint){ 3.5, 7.5 };
        edge = (LinePoint){ 16, 7.5 };
        render_case(outside, inside, edge, inside, -1, 1, 3, true, false, false,
                    false, false, false);
        require([commands beginWithError:&error] != nil, error);
        id<MTLBuffer> dummy =
            [commands.device newBufferWithLength:2 * sizeof(NV2AMetalVertex)
                                         options:MTLResourceStorageModeShared];
        assert(dummy);
        for (unsigned i = 0; i < 5; i++) {
            NV2AMetalGeometryRasterConfig c = { .lineWidth = 2,
                                                .viewportWidth = 16,
                                                .viewportHeight = 16 };
            if (i == 0)
                c.lineWidth = NAN;
            if (i == 1)
                c.lineWidth = -1;
            if (i == 2)
                c.viewportWidth = 0;
            if (i == 3)
                c.lineWidth = 16385;
            if (i == 4) {
                c.lineWidth = 1;
                c.viewportWidth = 0;
            }
            assert(![geometry encodeRasterVertices:dummy
                                             count:2
                                         primitive:NV2AMetalPrimitiveLines
                                            config:&c
                                            smooth:YES
                                    firstProvoking:YES
                                      zPerspective:i == 4
                                          commands:commands
                                             error:&error]);
            rejected++;
        }
        [commands cancel];
        printf("Metal 4 wide/smooth lines: %u analytic color/depth images, %u "
               "rejects PASS\n",
               images, rejected);
    }
    return 0;
}
