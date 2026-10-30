/* Native Metal4 point-sprite topology regression; no app/VM/window.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-sampler.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static NV2AMetalCommands *commands;
static NV2AMetalGeometry *geometry;
static NV2AMetalPixelShader *pixel;
static unsigned pairs, point_pairs, selected;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Point sprite: %s\n",
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
        v[i].point_size = 4;
        v[i].texcoord[3][0] = .2f;
        v[i].texcoord[3][1] = .4f;
        v[i].texcoord[3][2] = .6f;
        v[i].texcoord[3][3] = .8f;
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

static id<MTLTexture> render(NV2AMetalGeometryResult *g, bool enabled,
                             unsigned output, bool rectangle)
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
        .smooth_shading = 1,
        .point_sprite = enabled,
    };
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PASSTHRU << 15;
    u.combiner.final_inputs[0] = PS_REGISTER_T3;
    u.combiner.final_inputs[1] = (PS_REGISTER_T3 | PS_CHANNEL_ALPHA) << 8;
    u.textures[3].rectangle = rectangle;
    NV2AMetalPixelUniforms original = u;
    NV2AMetalPixelTexture textures[4] = {};
    BOOL ok = [pixel encodeVertices:g.vertices
                             offset:0
                              count:g.vertexCount
                          primitive:g.primitiveType
                           uniforms:&u
                           textures:textures
                               pass:pass
                          drawState:raster
               ignorePolygonCulling:YES
                           commands:commands
                              error:&error];
    assert(!memcmp(&original, &u, sizeof(u)));
    require(ok, error);
    return target;
}
static void compare_images(id<MTLTexture> off, id<MTLTexture> on, bool points,
                           const NV2AMetalVertex *v, unsigned count,
                           unsigned primitive, unsigned mode,
                           unsigned transport, unsigned output, bool rectangle)
{
    uint8_t a[16][16][4], b[16][16][4];
    [off getBytes:a
        bytesPerRow:64
         fromRegion:MTLRegionMake2D(0, 0, 16, 16)
        mipmapLevel:0];
    [on getBytes:b
        bytesPerRow:64
         fromRegion:MTLRegionMake2D(0, 0, 16, 16)
        mipmapLevel:0];
    const uint8_t clear[] = { 17, 31, 47, 63 };
    unsigned differences = 0, covered = 0;
    for (unsigned y = 0; y < 16; y++)
        for (unsigned x = 0; x < 16; x++) {
            bool changed = memcmp(a[y][x], b[y][x], 4) != 0;
            if (!points && changed) {
                fprintf(stderr,
                        "Sprite eligibility primitive%u mode%u transport%u "
                        "output%u rectangle%u pixel%u,%u\n",
                        primitive, mode, transport, output, rectangle, x, y);
                abort();
            }
            differences += changed;
            if (memcmp(b[y][x], clear, 4)) {
                covered++;
                if (points && output == 0) {
                    bool found = false;
                    for (unsigned i = 0; i < count; i++) {
                        float dx = x + .5f - (v[i].screen[0] - 2),
                              dy = y + .5f - (v[i].screen[1] - 2);
                        if (dx >= 0 && dx < 4 && dy >= 0 && dy < 4) {
                            const float expected[] = { dx / 4, dy / 4, 1, 1 };
                            for (unsigned k = 0; k < 4; k++)
                                assert(abs((int)b[y][x][k] -
                                           (int)lroundf(expected[k] * 255)) <=
                                       1);
                            found = true;
                        }
                    }
                    assert(found);
                }
            }
        }
    assert(covered > 0 && (points ? differences > 0 : differences == 0));
    selected += covered;
    pairs++;
    point_pairs += points;
}
static void raster_case(unsigned primitive, unsigned mode, unsigned back,
                        unsigned transport, unsigned output, bool rectangle)
{
    NSError *error = nil;
    NV2AMetalVertex v[8];
    unsigned count = inputs(v, primitive, false);
    if (mode != back) {
        assert(primitive == NV2AMetalPrimitiveTriangles);
        assert(inputs(v + 3, primitive, true) == 3);
        count = 6;
    }
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:v
                                     length:count * sizeof(*v)
                                    options:MTLResourceStorageModeShared];
    assert(buffer);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryRasterConfig c = {
        .front = mode,
        .back = back,
        .lineWidth = transport == 0 ? 1 :
                     transport == 1 ? 3 :
                                      2.25f,
        .lineSmooth = transport == 2,
        .polygonSmooth = transport == 2,
        .viewportWidth = 16,
        .viewportHeight = 16,
    };
    NSArray<NV2AMetalGeometryResult *> *streams =
        [geometry encodeRasterVertices:buffer
                                 count:count
                             primitive:primitive
                                config:&c
                                smooth:YES
                        firstProvoking:NO
                          zPerspective:NO
                              commands:commands
                                 error:&error];
    require(streams.count == (mode == back ? 1 : 2), error);
    id<MTLTexture> off[2] = {}, on[2] = {};
    bool points[2] = {};
    for (unsigned i = 0; i < streams.count; i++) {
        NV2AMetalGeometryResult *g = streams[i];
        points[i] = primitive == NV2AMetalPrimitivePoints ||
                    (primitive >= NV2AMetalPrimitiveTriangles &&
                     g.polygonMode == NV2AMetalPolygonPoint);
        assert((g.primitiveType == MTLPrimitiveTypePoint) == points[i]);
        off[i] = render(g, false, output, rectangle);
        on[i] = render(g, true, output, rectangle);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    for (unsigned i = 0; i < streams.count; i++)
        compare_images(off[i], on[i], points[i], v, count, primitive,
                       streams[i].polygonMode, transport, output, rectangle);
}

/* NV_point_sprite replaces S/T with 0..1 independently of texture size.
 * NV_texture_rectangle keeps those values in texel units, including the
 * existing physical texture scale. Check every covered and clear pixel. */
static void rectangle_texture_tests(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    unsigned draws = 0, channels = 0, covered = 0;
    for (unsigned shape = 0; shape < 2; shape++)
        for (unsigned scale = 1; scale <= 2; scale++) {
            unsigned width = (shape ? 7 : 3) * scale;
            unsigned height = (shape ? 2 : 5) * scale;
            uint8_t texels[10][14][4] = {};
            for (unsigned y = 0; y < height; y++)
                for (unsigned x = 0; x < width; x++)
                    for (unsigned k = 0; k < 4; k++)
                        texels[y][x][k] = 13 + (29 * x + 47 * y + 53 * k) % 229;
            MTLTextureDescriptor *td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                             width:width
                                            height:height
                                         mipmapped:NO];
            td.storageMode = MTLStorageModeShared;
            td.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture =
                [commands.device newTextureWithDescriptor:td];
            assert(texture);
            [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                       mipmapLevel:0
                         withBytes:texels
                       bytesPerRow:sizeof(texels[0])];
            for (unsigned linear = 0; linear < 2; linear++) {
                NV2AMetalSamplerConfig config = {
                    .filter = (linear + 1) << 16 | (linear + 1) << 24,
                    .address = 3 | 3 << 8 | 3 << 16,
                    .anisotropy = 1,
                    .rectangle = YES,
                };
                NV2AMetalTextureBinding *binding =
                    [sampler bindingForTexture:texture
                                        config:&config
                                         error:&error];
                require(binding != nil, error);
                MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
                sd.minFilter = sd.magFilter = linear ?
                                                  MTLSamplerMinMagFilterLinear :
                                                  MTLSamplerMinMagFilterNearest;
                sd.sAddressMode = sd.tAddressMode =
                    MTLSamplerAddressModeClampToEdge;
                sd.supportArgumentBuffers = YES;
                id<MTLSamplerState> nativeSampler =
                    [commands.device newSamplerStateWithDescriptor:sd];
                assert(nativeSampler);
                for (unsigned native = 0; native < 2; native++)
                    for (unsigned enabled = 0; enabled < 2; enabled++)
                        for (unsigned polygon = 0; polygon < 2; polygon++)
                            for (unsigned large = 0; large < 2; large++) {
                                unsigned primitive =
                                    polygon ? NV2AMetalPrimitiveTriangles :
                                              NV2AMetalPrimitivePoints;
                                NV2AMetalVertex v[4];
                                unsigned count = inputs(v, primitive, false);
                                unsigned size = large ? 8 : 4;
                                for (unsigned i = 0; i < count; i++) {
                                    v[i].point_size = size;
                                    v[i].texcoord[3][0] = .6f;
                                    v[i].texcoord[3][1] = .9f;
                                    v[i].texcoord[3][3] = 1.5f;
                                }
                                id<MTLBuffer> vertices = [commands.device
                                    newBufferWithBytes:v
                                                length:count * sizeof(*v)
                                               options:
                                                   MTLResourceStorageModeShared];
                                assert(vertices);
                                require([commands beginWithError:&error] != nil,
                                        error);
                                NV2AMetalGeometryRasterConfig raster = {
                                    .front = NV2AMetalPolygonPoint,
                                    .back = NV2AMetalPolygonPoint,
                                    .lineWidth = 1,
                                    .viewportWidth = 16,
                                    .viewportHeight = 16,
                                };
                                NSArray<NV2AMetalGeometryResult *> *streams =
                                    [geometry encodeRasterVertices:vertices
                                                             count:count
                                                         primitive:primitive
                                                            config:&raster
                                                            smooth:YES
                                                    firstProvoking:NO
                                                      zPerspective:NO
                                                          commands:commands
                                                             error:&error];
                                require(streams.count == 1, error);
                                NV2AMetalGeometryResult *g = streams[0];
                                assert(g.primitiveType ==
                                       MTLPrimitiveTypePoint);
                                td = [MTLTextureDescriptor
                                    texture2DDescriptorWithPixelFormat:
                                        MTLPixelFormatRGBA32Float
                                                                 width:16
                                                                height:16
                                                             mipmapped:NO];
                                td.storageMode = MTLStorageModeShared;
                                td.usage = MTLTextureUsageRenderTarget;
                                id<MTLTexture> target = [commands.device
                                    newTextureWithDescriptor:td];
                                assert(target);
                                MTL4RenderPassDescriptor *pass =
                                    [MTL4RenderPassDescriptor new];
                                pass.colorAttachments[0].texture = target;
                                pass.colorAttachments[0].loadAction =
                                    MTLLoadActionClear;
                                pass.colorAttachments[0].clearColor =
                                    MTLClearColorMake(.125, .25, .375, .5);
                                pass.colorAttachments[0].storeAction =
                                    MTLStoreActionStore;
                                NV2AMetalPixelUniforms u = {
                                    .clip_range = { 0, 65535, 0, 65535 },
                                    .clip_regions = { { 0, 0, 16, 16 } },
                                    .surface_scale = { 1, 1 },
                                    .depth_format = NV2AMetalPixelDepthD16,
                                    .smooth_shading = 1,
                                    .point_sprite = enabled,
                                };
                                u.combiner.shader_stage_program =
                                    PS_TEXTUREMODES_PROJECT2D << 15;
                                u.combiner.final_inputs[0] = PS_REGISTER_T3;
                                u.combiner.final_inputs[1] =
                                    (PS_REGISTER_T3 | PS_CHANNEL_ALPHA) << 8;
                                u.textures[3].dimension = 2;
                                u.textures[3].rectangle = 1;
                                u.textures[3].scale = scale;
                                u.textures[3].sampling = binding.sampling;
                                if (native)
                                    u.textures[3].sampling.enabled = 0;
                                NV2AMetalPixelUniforms original = u;
                                NV2AMetalPixelTexture textures[4] = {};
                                textures[3].texture = binding.texture;
                                textures[3].sampler =
                                    native ? nativeSampler : binding.sampler;
                                require([shader encodeVertices:g.vertices
                                                         count:g.vertexCount
                                                     primitive:g.primitiveType
                                                      uniforms:&u
                                                      textures:textures
                                                          pass:pass
                                                  depthStencil:nil
                                                      commands:commands
                                                         error:&error],
                                        error);
                                assert(!memcmp(&u, &original, sizeof(u)));
                                require([commands submitWithError:&error],
                                        error);
                                require(
                                    [commands waitUntilIdleWithError:&error],
                                    error);
                                float image[16][16][4];
                                [target getBytes:image
                                     bytesPerRow:sizeof(image[0])
                                      fromRegion:MTLRegionMake2D(0, 0, 16, 16)
                                     mipmapLevel:0];
                                for (unsigned y = 0; y < 16; y++)
                                    for (unsigned x = 0; x < 16; x++) {
                                        double s = 0, t = 0;
                                        bool hit = false;
                                        for (unsigned i = 0; i < count; i++) {
                                            double dx = x + .5 - v[i].screen[0];
                                            double dy = y + .5 - v[i].screen[1];
                                            if (fabs(dx) < size / 2. &&
                                                fabs(dy) < size / 2.) {
                                                hit = true;
                                                s = enabled ? .5 + dx / size :
                                                              .6 / 1.5;
                                                t = enabled ? .5 + dy / size :
                                                              .9 / 1.5;
                                            }
                                        }
                                        covered += hit;
                                        double px =
                                            s * scale - (linear ? .5 : 0);
                                        double py =
                                            t * scale - (linear ? .5 : 0);
                                        int ix = floor(px), iy = floor(py);
                                        double fx = px - ix, fy = py - iy;
                                        for (unsigned k = 0; k < 4; k++) {
                                            double expected = (k + 1) * .125;
                                            if (hit) {
                                                expected = 0;
                                                for (unsigned j = 0;
                                                     j < (linear ? 2u : 1u);
                                                     j++)
                                                    for (unsigned i = 0;
                                                         i < (linear ? 2u : 1u);
                                                         i++) {
                                                        int tx = ix + i,
                                                            ty = iy + j;
                                                        tx = tx < 0 ?
                                                                 0 :
                                                             tx >= (int)width ?
                                                                 width - 1 :
                                                                 tx;
                                                        ty = ty < 0 ?
                                                                 0 :
                                                             ty >= (int)height ?
                                                                 height - 1 :
                                                                 ty;
                                                        double weight =
                                                            linear ?
                                                                (i ? fx :
                                                                     1 - fx) *
                                                                    (j ? fy :
                                                                         1 - fy) :
                                                                1;
                                                        expected +=
                                                            weight *
                                                            texels[ty][tx][k] /
                                                            255.;
                                                    }
                                            }
                                            /* Native RGBA8 linear filtering
                                             * can quantize interpolated values
                                             * within one source code step. */
                                            double tolerance =
                                                hit && native && linear ?
                                                    1. / 255 :
                                                    1e-6;
                                            if (fabs(image[y][x][k] -
                                                     expected) > tolerance) {
                                                fprintf(
                                                    stderr,
                                                    "Rectangle sprite shape%u "
                                                    "scale%u linear%u native%u "
                                                    "enabled%u polygon%u "
                                                    "size%u at%u,%u/%u: %.9g "
                                                    "expected %.9g\n",
                                                    shape, scale, linear,
                                                    native, enabled, polygon,
                                                    size, x, y, k,
                                                    image[y][x][k], expected);
                                                abort();
                                            }
                                            channels++;
                                        }
                                    }
                                draws++;
                            }
            }
        }
    assert(draws == 128 && channels == 131072 && covered > 0);
    printf("Metal4 rectangle point-sprite textures: %u draws/%u full-frame "
           "channels/%u covered pixels PASS\n",
           draws, channels, covered);
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
        for (unsigned primitive = NV2AMetalPrimitivePoints;
             primitive <= NV2AMetalPrimitivePolygon; primitive++)
            for (unsigned mode = 0; mode < 3; mode++) {
                if (primitive == NV2AMetalPrimitivePolygon &&
                    mode == NV2AMetalPolygonPoint)
                    continue;
                for (unsigned transport = 0; transport < 3; transport++)
                    for (unsigned output = 0; output < 4; output++)
                        for (unsigned rectangle = 0; rectangle < 2; rectangle++)
                            raster_case(primitive, mode, mode, transport,
                                        output, rectangle);
            }
        for (unsigned front = 0; front < 3; front++)
            for (unsigned back = 0; back < 3; back++) {
                if (front == back)
                    continue;
                for (unsigned transport = 0; transport < 3; transport++)
                    for (unsigned output = 0; output < 4; output++)
                        for (unsigned rectangle = 0; rectangle < 2; rectangle++)
                            raster_case(NV2AMetalPrimitiveTriangles, front,
                                        back, transport, output, rectangle);
            }
        assert(pairs == 984 && point_pairs == 288);
        printf("Metal4 point-sprite topology: %u image pairs, %u point pairs, "
               "%u selected pixels PASS\n",
               pairs, point_pairs, selected);
        rectangle_texture_tests();
    }
    return 0;
}
