/* Native polygon coverage validation against independent double references.
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
} PolygonPoint;
static NV2AMetalCommands *commands;
static NV2AMetalGeometry *geometry;
static NV2AMetalPixelShader *pixel;
static unsigned images, projection_pairs;
static NSData *legacy_pixels;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Native polygons: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void close_value(float actual, double expected, unsigned x, unsigned y)
{
    if (!isfinite(actual) || fabs(actual - expected) > .00004) {
        fprintf(stderr, "Polygon image%u pixel%u,%u: %g expected%.9g\n", images,
                x, y, actual, expected);
        abort();
    }
}

/* Independent reference clips the pixel square by the original triangle's
 * oblique edges. The GPU clips the projected triangle by the square sides.
 * Perspective weights use composite Simpson integration, not GPU Gaussian
 * nodes; equal-W weights follow the exact area centroid. */
static double cross_point(PolygonPoint a, PolygonPoint b)
{
    return a.x * b.y - a.y * b.x;
}
static PolygonPoint subtract(PolygonPoint a, PolygonPoint b)
{
    return (PolygonPoint){ a.x - b.x, a.y - b.y };
}
static void barycentric(PolygonPoint p, const PolygonPoint *v, const float *w,
                        double *weights)
{
    double sum = 0;
    for (unsigned i = 0; i < 3; i++) {
        weights[i] = cross_point(subtract(v[(i + 1) % 3], p),
                                 subtract(v[(i + 2) % 3], p)) /
                     w[i];
        sum += weights[i];
    }
    for (unsigned i = 0; i < 3; i++)
        weights[i] /= sum;
}
static double polygon_reference(const PolygonPoint *v, const float *w,
                                PolygonPoint centre, double *weights)
{
    PolygonPoint polygon[8] = { { centre.x - .5, centre.y - .5 },
                                { centre.x + .5, centre.y - .5 },
                                { centre.x + .5, centre.y + .5 },
                                { centre.x - .5, centre.y + .5 } };
    unsigned count = 4;
    double sign =
        cross_point(subtract(v[1], v[0]), subtract(v[2], v[0])) > 0 ? 1 : -1;
    for (unsigned edge = 0; edge < 3 && count; edge++) {
        PolygonPoint a = v[edge], d = subtract(v[(edge + 1) % 3], a), next[8];
        unsigned n = 0;
        PolygonPoint previous = polygon[count - 1];
        double edge_sign = sign * (w[(edge + 2) % 3] > 0 ? 1 : -1);
        double pd = edge_sign * cross_point(d, subtract(previous, a));
        bool pi = pd >= 0;
        for (unsigned i = 0; i < count; i++) {
            PolygonPoint current = polygon[i];
            double cd = edge_sign * cross_point(d, subtract(current, a));
            bool ci = cd >= 0;
            if (pi != ci) {
                double t = pd / (pd - cd);
                next[n++] =
                    (PolygonPoint){ previous.x + t * (current.x - previous.x),
                                    previous.y + t * (current.y - previous.y) };
            }
            if (ci)
                next[n++] = current;
            previous = current;
            pd = cd;
            pi = ci;
        }
        count = n;
        memcpy(polygon, next, n * sizeof(PolygonPoint));
    }
    if (count < 3)
        return 0;
    double area2 = 0, cx = 0, cy = 0;
    for (unsigned i = 0; i < count; i++) {
        PolygonPoint a = subtract(polygon[i], centre),
                     b = subtract(polygon[(i + 1) % count], centre);
        double cross = cross_point(a, b);
        area2 += cross;
        cx += (a.x + b.x) * cross;
        cy += (a.y + b.y) * cross;
    }
    double area = fmin(1, fabs(area2) * .5);
    if (area < 1e-12)
        return 0;
    if (area > 1 - 1e-12) {
        barycentric(centre, v, w, weights);
        return area;
    }
    if (w[0] == w[1] && w[1] == w[2]) {
        PolygonPoint centroid = { centre.x + cx / (3 * area2),
                                  centre.y + cy / (3 * area2) };
        barycentric(centroid, v, w, weights);
        return area;
    }
    for (unsigned k = 0; k < 3; k++)
        weights[k] = 0;
    double total = 0;
    const unsigned steps = 256;
    for (unsigned i = 1; i + 1 < count; i++) {
        PolygonPoint a = polygon[0], b = subtract(polygon[i], a),
                     c = subtract(polygon[i + 1], a);
        double det = fabs(cross_point(b, c));
        for (unsigned j = 0; j <= steps; j++)
            for (unsigned k = 0; k <= steps; k++) {
                double s = (double)j / steps, t = (1 - s) * k / steps;
                double sj = (j == 0 || j == steps) ? 1 : j % 2 ? 4 : 2;
                double sk = (k == 0 || k == steps) ? 1 : k % 2 ? 4 : 2;
                double factor = det * (1 - s) * sj * sk;
                if (factor == 0)
                    continue;
                PolygonPoint p = { a.x + s * b.x + t * c.x,
                                   a.y + s * b.y + t * c.y };
                double values[3];
                barycentric(p, v, w, values);
                for (unsigned z = 0; z < 3; z++)
                    weights[z] += factor * values[z];
                total += factor;
            }
    }
    for (unsigned k = 0; k < 3; k++)
        weights[k] /= total;
    return area;
}
static NV2AMetalVertex vertex(PolygonPoint p, float w, unsigned index)
{
    NV2AMetalVertex v = { 0 };
    v.clip[0] = (p.x / 8 - 1) * w;
    v.clip[1] = (1 - p.y / 8) * w;
    v.clip[2] = .5f * w;
    v.clip[3] = w;
    v.screen[0] = p.x;
    v.screen[1] = p.y;
    v.screen[2] = 1000 + index * 1000;
    v.screen[3] = w;
    v.color[0][index] = 1;
    v.color[0][3] = 1;
    v.fog = .2f + index * .3f;
    v.texcoord[0][0] = .1f + index * .3f;
    v.texcoord[0][1] = .5f;
    v.texcoord[0][3] = 1;
    return v;
}
static void render_case_impl(const PolygonPoint *points, const float *w,
                             bool flat, bool texture, bool blend,
                             bool alpha_test, bool perspective_depth,
                             bool reverse, bool cull, BOOL projected)
{
    NSError *error = nil;
    NV2AMetalVertex input[3];
    for (unsigned i = 0; i < 3; i++)
        input[i] = vertex(points[i], w[i], i);
    if (reverse) {
        NV2AMetalVertex temporary = input[1];
        input[1] = input[2];
        input[2] = temporary;
    }
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(buffer);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryRasterConfig c = { .polygonSmooth = YES,
                                        .viewportWidth = 16,
                                        .viewportHeight = 16,
                                        .cullFront = cull && reverse,
                                        .cullBack = cull && !reverse };
    NSArray<NV2AMetalGeometryResult *> *streams =
        [geometry encodeRasterVertices:buffer
                                 count:3
                             primitive:NV2AMetalPrimitiveTriangles
                                config:&c
                                smooth:!flat
                        firstProvoking:YES
                          zPerspective:perspective_depth
                              commands:commands
                                 error:&error];
    require(streams != nil, error);
    NV2AMetalGeometryResult *g = streams[0];
    assert(g.expandedPolygons && g.vertexCount == 6 &&
           g.primitiveType == MTLPrimitiveTypeTriangle);
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
    assert(g.polygonProjections &&
           g.polygonProjections.storageMode == MTLStorageModePrivate &&
           g.polygonProjections.length == sizeof(NV2AMetalPolygonProjection));
    if (projected) {
        require([pixel encodeGeometry:g
                                  offset:0
                                   count:6
                                uniforms:&u
                                textures:textures
                                    pass:pass
                               drawState:raster
                             rasterClass:NV2AMetalPixelRasterExpandedPolygon
                    ignorePolygonCulling:YES
                           renderEncoder:nil
                                commands:commands
                                   error:&error],
                error);
    } else {
        require([pixel encodeVertices:g.vertices
                                  offset:0
                                   count:6
                               primitive:g.primitiveType
                                uniforms:&u
                                textures:textures
                                    pass:pass
                               drawState:raster
                    ignorePolygonCulling:YES
                                commands:commands
                                   error:&error],
                error);
    }
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
    NSMutableData *actual = [NSMutableData dataWithBytes:pixels
                                                  length:sizeof(pixels)];
    for (unsigned y = 0; y < 16; y++)
        [actual appendBytes:(const char *)depths.contents + y * 256
                     length:16 * sizeof(float)];
    if (projected) {
        assert([actual isEqualToData:legacy_pixels]);
        projection_pairs++;
        legacy_pixels = nil;
    } else {
        legacy_pixels = actual;
    }
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            PolygonPoint centre = { x + .5, y + .5 };
            double values[3] = { 0 };
            double coverage =
                cull ? 0 : polygon_reference(points, w, centre, values);
            double db[3];
            const float ones[3] = { 1, 1, 1 };
            barycentric(centre, points, perspective_depth ? w : ones, db);
            double expected[4] = { 0, 0, 1, 0 }, z = 1;
            if (coverage > 1e-7) {
                if (texture) {
                    int texel = (int)floor(
                        (.1 * values[0] + .4 * values[1] + .7 * values[2]) * 8);
                    texel = texel < 0 ? 0 : texel > 7 ? 7 : texel;
                    expected[0] = texel / 8.;
                    expected[1] = .25;
                    expected[2] = .5;
                } else {
                    expected[0] = flat ? 1 : fmax(0, values[0]);
                    expected[1] = flat ? 0 : fmax(0, values[1]);
                    expected[2] = flat ? 0 : fmax(0, values[2]);
                }
                expected[3] = coverage;
                if (blend) {
                    expected[0] *= coverage;
                    expected[1] *= coverage;
                    expected[2] = expected[2] * coverage + 1 - coverage;
                    expected[3] = coverage * coverage;
                }
                z = floor(perspective_depth ?
                              db[0] * w[0] + db[1] * w[1] + db[2] * w[2] :
                              1000 + db[1] * 1000 + db[2] * 2000) /
                    65535.;
            }
            z = fmin(1, fmax(0, z));
            for (unsigned i = 0; i < 4; i++)
                close_value(pixels[y][x][i], expected[i], x, y);
            float actual_depth;
            memcpy(&actual_depth, (char *)depths.contents + y * 256 + x * 4, 4);
            close_value(actual_depth, z, x, y);
        }
    images++;
}
static void render_case(const PolygonPoint *points, const float *w, bool flat,
                        bool texture, bool blend, bool alpha_test,
                        bool perspective_depth, bool reverse, bool cull)
{
    render_case_impl(points, w, flat, texture, blend, alpha_test,
                     perspective_depth, reverse, cull, NO);
    render_case_impl(points, w, flat, texture, blend, alpha_test,
                     perspective_depth, reverse, cull, YES);
}
#include "test-metal-polygon-projection.h"
#include "test-metal-polygon-transport.h"
#include "test-metal-polygon-quads.h"
#include "test-metal-compact-polygon-fill.h"
#include "test-metal-polygon-window-clip.h"
#include "test-metal-polygon-window-benchmark.h"
#include "test-metal-projection-mode.h"

typedef struct {
    float clips[3][4], viewport[2], centre[2];
    NV2AMetalPolygonProjection projection;
    unsigned preprojected;
} PolygonInteriorCase;
_Static_assert(sizeof(PolygonInteriorCase) == 136, "Interior test MSL ABI");

static NSString *interior_slice(NSString *source, NSString *start,
                                NSString *end)
{
    NSRange first = [source rangeOfString:start];
    assert(first.location != NSNotFound);
    NSRange last =
        [source rangeOfString:end
                      options:0
                        range:NSMakeRange(NSMaxRange(first),
                                          source.length - NSMaxRange(first))];
    assert(last.location != NSNotFound);
    return
        [source substringWithRange:NSMakeRange(first.location,
                                               last.location - first.location)];
}

/* Exercise the admission bound under both arithmetic modes allowed by MSL
 * 8.2, including output FTZ. The GPU itself exposes no mode selector. */
static float interior_round(double value, BOOL towardZero)
{
    float rounded = (float)value;
    if (towardZero && fabs((double)rounded) > fabs(value)) {
        uint32_t bits;
        memcpy(&bits, &rounded, 4);
        bits--;
        memcpy(&rounded, &bits, 4);
    }
    return fabsf(rounded) < 0x1p-126f ? copysignf(0, rounded) : rounded;
}

static void interior_rounding_checks(const float *points, unsigned count,
                                     const float *centre, unsigned *admissions)
{
    double orientation = 0;
    for (unsigned j = 0; j < count; j++) {
        unsigned k = (j + 1) % count;
        orientation += (double)points[2 * j] * points[2 * k + 1] -
                       (double)points[2 * j + 1] * points[2 * k];
    }
    double sign = orientation > 0 ? 1 : -1;
    for (unsigned mode = 0; mode < 2; mode++)
        for (unsigned j = 0; j < count; j++) {
            unsigned k = (j + 1) % count;
            float a[2], b[2], d[2];
            for (unsigned axis = 0; axis < 2; axis++) {
                a[axis] = interior_round(
                    (double)points[2 * j + axis] - centre[axis], mode);
                b[axis] = interior_round(
                    (double)points[2 * k + axis] - centre[axis], mode);
                d[axis] = interior_round((double)b[axis] - a[axis], mode);
            }
            float left = interior_round((double)d[1] * a[0], mode),
                  right = interior_round((double)d[0] * a[1], mode),
                  cross = interior_round((double)left - right, mode),
                  span =
                      interior_round((double)fabsf(d[0]) + fabsf(d[1]), mode),
                  radius = interior_round(.5 * span, mode),
                  minimum = interior_round(sign * cross - radius, mode),
                  magnitude = fmaxf(fmaxf(fabsf(a[0]), fabsf(a[1])),
                                    fmaxf(fabsf(b[0]), fabsf(b[1]))),
                  scale = interior_round(1.0 + magnitude, mode),
                  bound = interior_round(
                      (double)interior_round(0x1p-18 * scale, mode) * scale,
                      mode);
            if (!(magnitude <= 32768 && isfinite(minimum) && minimum > bound))
                continue;
            double ax = (double)points[2 * j] - centre[0],
                   ay = (double)points[2 * j + 1] - centre[1],
                   dx = (double)points[2 * k] - points[2 * j],
                   dy = (double)points[2 * k + 1] - points[2 * j + 1];
            assert(sign * (dy * ax - dx * ay) - .5 * (fabs(dx) + fabs(dy)) > 0);
            admissions[mode]++;
        }
}

static void polygon_interior_tests(void)
{
    NSError *error = nil;
    NSString *source = @(pq_pixel_source);
    NSString *weights =
        interior_slice(source, @"static float3 polygon_weights(",
                       @"static float polygon_sample(");
    NSString *sample = interior_slice(source, @"static float polygon_sample(",
                                      @"static bool pixel_quad_helpers(");
    NSString *gate = @"    if (interior)\n        return 1.0f;\n";
    assert([sample componentsSeparatedByString:gate].count == 2);
    NSString *previous = [[sample stringByReplacingOccurrencesOfString:gate
                                                            withString:@""]
        stringByReplacingOccurrencesOfString:@"polygon_sample("
                                  withString:@"pi_previous_sample("];
    sample = [sample
        stringByReplacingOccurrencesOfString:gate
                                  withString:@"    if (interior) { hit = true; "
                                             @"return 1.0f; }\n"];
    assert([sample componentsSeparatedByString:@"bool preprojected)"].count ==
           2);
    sample = [sample
        stringByReplacingOccurrencesOfString:@"bool preprojected)"
                                  withString:
                                      @"bool preprojected, thread bool &hit)"];
    NSMutableString *test = [NSMutableString
        stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
    [test appendString:
              interior_slice(
                  source, @"typedef struct NV2AMetalPolygonProjection {",
                  @"/* Scalar arrays keep the CPU and MSL layouts identical.")];
    [test appendString:interior_slice(source, @"static uint polygon_project(",
                                      @"#endif")];
    [test appendString:weights];
    [test appendString:previous];
    [test appendString:sample];
    [test appendString:
              @"struct PICase { float clips[3][4], viewport[2], centre[2];"
               " NV2AMetalPolygonProjection projection; uint preprojected; };\n"
               "kernel void pi_check(device const PICase *cases [[buffer(0)]],"
               "device float *results [[buffer(1)]], uint id "
               "[[thread_position_in_grid]]) {"
               "device const PICase &c=cases[id]; float4 clips[3];"
               "for(uint "
               "i=0;i<3;i++)clips[i]=float4(c.clips[i][0],c.clips[i][1],c."
               "clips[i][2],c.clips[i][3]);"
               "float2 "
               "viewport(c.viewport[0],c.viewport[1]),centre(c.centre[0],c."
               "centre[1]);"
               "float3 a,b;bool hit=false;"
               "float "
               "coverage=polygon_sample(clips,viewport,centre,a,&c.projection,"
               "c.preprojected!=0,hit);"
               "float "
               "old=pi_previous_sample(clips,viewport,centre,b,&c.projection,c."
               "preprojected!=0);"
               "device float *out=results+id*26;for(uint i=0;i<26;i++)out[i]=0;"
               "for(uint i=0;i<3;i++){out[i]=a[i];out[4+i]=b[i];}"
               "out[3]=coverage;out[7]=old;out[8]=hit;float2 points[8];uint n;"
               "if(c.preprojected){n=min(c.projection.count,8u);for(uint "
               "i=0;i<n;i++)"
               "points[i]=float2(c.projection.points[i][0],c.projection.points["
               "i][1]);}"
               "else n=polygon_project(clips,viewport,points);out[9]=n;"
               "for(uint "
               "i=0;i<n;i++){out[10+i*2]=points[i].x;out[11+i*2]=points[i].y;} "
               "}\n"];
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = test;
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
    fn.library = library;
    fn.name = @"pi_check";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    id<MTLComputePipelineState> pipeline =
        [compiler newComputePipelineStateWithDescriptor:pd
                                    compilerTaskOptions:nil
                                                  error:&error];
    require(pipeline != nil, error);
    const unsigned count = 8256;
    NSMutableData *data =
        [NSMutableData dataWithLength:count * sizeof(PolygonInteriorCase)];
    PolygonInteriorCase *cases = data.mutableBytes;
    for (unsigned i = 0; i < count; i++) {
        PolygonInteriorCase *c = &cases[i];
        const unsigned sizes[] = { 16, 256, 4096, 16384 };
        float size = sizes[(i / 64) % 4];
        c->viewport[0] = c->viewport[1] = size;
        c->centre[0] = c->centre[1] = size * .5f + .5f;
        c->preprojected = i < 8192 && (i & 4);
        unsigned n = c->projection.count = 3 + i % 6;
        float radius = (i & 16) ? size * .25f : 1 + (i % 5) * .25f;
        for (unsigned j = 0; j < n; j++) {
            double angle = 6.283185307179586 * j / n + .125 * (i % 8);
            unsigned index = i & 1 ? n - 1 - j : j;
            c->projection.points[index][0] = c->centre[0] + radius * cos(angle);
            c->projection.points[index][1] = c->centre[1] + radius * sin(angle);
        }
        /* Axis-aligned near-boundaries include exact and adjacent Float32
         * edge coordinates at all viewport sizes, with both windings. */
        if (i & 8) {
            c->projection.count = 4;
            float edge = c->centre[0] + .5f;
            int steps = (int)(i % 9) - 4;
            for (int j = 0; j < abs(steps); j++)
                edge = nextafterf(edge, steps < 0 ? -INFINITY : INFINITY);
            const float p[4][2] = {
                { c->centre[0] - radius, c->centre[1] - radius },
                { edge, c->centre[1] - radius },
                { edge, c->centre[1] + radius },
                { c->centre[0] - radius, c->centre[1] + radius }
            };
            for (unsigned j = 0; j < 4; j++)
                memcpy(c->projection.points[i & 1 ? 3 - j : j], p[j], 8);
        }
        for (unsigned j = 0; j < 3; j++) {
            float w = (i & 32) ? (float[]){ .25f, 1, 64 }[j] : 1;
            float x = c->projection.points[j][0],
                  y = c->projection.points[j][1];
            c->clips[j][0] = (x / size * 2 - 1) * w;
            c->clips[j][1] = (1 - y / size * 2) * w;
            c->clips[j][2] = .5f * w;
            c->clips[j][3] = w;
        }
        if (i >= 8192) {
            unsigned which = (i - 8192) % 3;
            c->clips[which][3] = i & 1 ? 0 : -1;
        }
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:data.bytes
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:count * 26 * 4
                                     options:MTLResourceStorageModeShared];
    assert(input && output);
    memset(output.contents, 0xcc, output.length);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 2;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(arguments != nil, error);
    pp_begin();
    require([commands addResource:input error:&error] &&
                [commands addResource:output error:&error],
            error);
    [arguments setAddress:input.gpuAddress atIndex:0];
    [arguments setAddress:output.gpuAddress atIndex:1];
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder setComputePipelineState:pipeline];
    [encoder setArgumentTable:arguments];
    [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [encoder endEncoding];
    pp_finish();
    unsigned hits = 0, misses = 0, boundary = 0, arithmetic[2] = { 0 };
    float max_previous_error = 0;
    for (unsigned i = 0; i < count; i++) {
        const float *o = (const float *)output.contents + i * 26;
        assert(o[9] >= 0 && o[9] <= 8);
        interior_rounding_checks(o + 10, o[9], cases[i].centre, arithmetic);
        if (!o[8]) {
            assert(!memcmp(o, o + 4, 16));
            misses++;
            boundary += o[3] > 0 && o[3] < 1;
            continue;
        }
        assert(o[8] == 1 && o[3] == 1 && !memcmp(o, o + 4, 12));
        hits++;
        max_previous_error = fmaxf(max_previous_error, fabsf(1 - o[7]));
        unsigned n = o[9];
        assert(n >= 3 && n <= 8);
        double orientation = 0;
        for (unsigned j = 0; j < n; j++) {
            unsigned k = (j + 1) % n;
            orientation += (double)o[10 + 2 * j] * o[11 + 2 * k] -
                           (double)o[11 + 2 * j] * o[10 + 2 * k];
        }
        assert(orientation != 0);
        /* Independent double half-plane checks on the actual GPU-projected
         * points: every admitted pixel square must be strictly contained. */
        for (unsigned j = 0; j < n; j++) {
            unsigned k = (j + 1) % n;
            double ax = o[10 + 2 * j], ay = o[11 + 2 * j],
                   dx = (double)o[10 + 2 * k] - ax,
                   dy = (double)o[11 + 2 * k] - ay;
            for (unsigned corner = 0; corner < 4; corner++) {
                double x = (double)cases[i].centre[0] + (corner & 1 ? .5 : -.5),
                       y = (double)cases[i].centre[1] + (corner & 2 ? .5 : -.5);
                assert((dx * (y - ay) - dy * (x - ax)) *
                           (orientation > 0 ? 1 : -1) >
                       0);
            }
        }
    }
    assert(hits > 500 && misses > 500 && boundary > 100 &&
           arithmetic[0] > 1000 && arithmetic[1] > 1000);
    printf(
        "Polygon full-square admission:%u GPU samples,%u strict double-oracle "
        "interiors with exact centre weights,%u bit-exact fallbacks(%u "
        "partial),"
        "3..8 edges,both windings,16..16K viewports,ULP boundaries,W<=0;"
        "RNE/RZ+FTZ edge admissions=%u/%u;"
        "previous full-square coverage error<=%g PASS\n",
        count, hits, misses, boundary, arithmetic[0], arithmetic[1],
        max_previous_error);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc >= 2 && (!strcmp(argv[1], "--projection-mode") ||
                          !strcmp(argv[1], "--projection-mode-reference"))) {
            assert(argc == 2 || argc == 3);
            projection_mode_tests(!strcmp(argv[1], "--projection-mode") ? 2 : 1,
                                  argc == 3 ? argv[2] : NULL);
            return 0;
        }
        if (argc == 1)
            projection_mode_tests(2, NULL);
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--polygon-window-clip")))
            polygon_window_clip_tests();
        if (argc == 2 && !strcmp(argv[1], "--polygon-window-clip"))
            return 0;
        if (argc == 2 && !strcmp(argv[1], "--polygon-window-benchmark")) {
            polygon_window_benchmark();
            return 0;
        }
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--compact-polygon-fill")))
            compact_polygon_fill_tests();
        if (argc == 2 && !strcmp(argv[1], "--compact-polygon-fill"))
            return 0;
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
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--interior")))
            polygon_interior_tests();
        if (argc == 2 && !strcmp(argv[1], "--interior"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--quad-discard")))
            polygon_quad_tests();
        if (argc == 2 && !strcmp(argv[1], "--quad-discard"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--transport")))
            polygon_transport_tests();
        if (argc == 2 && !strcmp(argv[1], "--transport"))
            return 0;
        if (argc == 2 && !strcmp(argv[1], "--projection")) {
            polygon_projection_tests();
            return 0;
        }
        assert(argc == 1);
        polygon_projection_tests();
        const PolygonPoint triangles[][3] = {
            { { 2.25, 2.25 }, { 13.75, 3.25 }, { 4.25, 13.75 } },
            { { 2.5, 2.5 }, { 13.5, 2.5 }, { 2.5, 13.5 } },
            { { 7.25, 1.75 }, { 8.75, 14.25 }, { 6.25, 9.75 } },
            { { -5.25, 3.25 }, { 12.75, 1.25 }, { 7.25, 18.75 } },
            { { 2.25, 7.25 }, { 13.75, 7.5 }, { 4.25, 7.75 } },
            { { -3.25, -5.25 }, { 20.75, 2.25 }, { 3.25, 21.75 } }
        };
        for (unsigned t = 0; t < sizeof(triangles) / sizeof(triangles[0]); t++)
            for (unsigned reverse = 0; reverse < 2; reverse++)
                for (unsigned perspective = 0; perspective < 2; perspective++) {
                    const float w[3] = { 1, perspective ? 3 : 1,
                                         perspective ? 2 : 1 };
                    render_case(triangles[t], w, false, false, false, false,
                                false, reverse, false);
                }
        const float w[3] = { 10, 30, 20 };
        render_case(triangles[0], w, true, false, false, false, false, false,
                    false);
        render_case(triangles[0], w, false, true, false, false, false, false,
                    false);
        render_case(triangles[0], w, false, false, true, false, false, false,
                    false);
        render_case(triangles[0], w, false, false, false, true, false, false,
                    false);
        render_case(triangles[0], w, false, false, false, false, true, false,
                    false);
        render_case(triangles[0], w, false, false, false, false, false, false,
                    true);
        render_case(triangles[0], w, false, false, false, false, false, true,
                    true);
        const float negative_w[][3] = { { -1, 1, 1 },
                                        { -1, -2, 1 },
                                        { -1, -2, -3 } };
        for (unsigned i = 0; i < 3; i++)
            render_case(triangles[1], negative_w[i], false, false, false, false,
                        false, false, false);
        const float steep_w[3] = { 1, 64, .25f };
        render_case(triangles[0], steep_w, false, false, false, false, false,
                    false, false);
        render_case(triangles[1], steep_w, false, false, false, false, false,
                    false, false);
        // Perspective ratios around the compact quadrature limit. The CPU
        // reference retains independent composite Simpson integration.
        for (unsigned edge = 0; edge < 3; edge++) {
            const float compact_w[3] = { 1,
                                         1.03125f + ((int)edge - 1) * 0x1p-20f,
                                         1.015625f };
            for (unsigned reverse = 0; reverse < 2; reverse++)
                for (unsigned thin = 0; thin < 2; thin++)
                    render_case(triangles[thin ? 4 : 0], compact_w, false,
                                false, false, false, false, reverse, false);
        }
        assert(projection_pairs == 48);
        printf("Metal 4 polygons: %u analytic color/depth images; %u bit-exact "
               "projected/legacy pairs PASS\n",
               images, projection_pairs);
    }
    return 0;
}
