/* Native triangle/quad graphics versus compute geometry, without xemu or a
 * window. SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "test-metal-indexed-raster.h"

static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Direct triangles: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static id (*original_compute)(id, SEL);
static unsigned computeEncoders;
static id compute_encoder(id object, SEL selector)
{
    computeEncoders++;
    return original_compute(object, selector);
}
static void (*original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static double gpuSeconds;
static void feedback_handler(id object, SEL selector,
                             MTL4CommitFeedbackHandler handler)
{
    original_feedback(object, selector, ^(id<MTL4CommitFeedback> f) {
      gpuSeconds = f.GPUEndTime - f.GPUStartTime;
      handler(f);
    });
}
static int compare_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static id<MTLTexture> texture(id<MTLDevice> device, MTLPixelFormat format,
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
    id<MTLTexture> t = [device newTextureWithDescriptor:d];
    assert(t);
    return t;
}
#include "test-metal-polygon-modes-raster.h"
#include "test-metal-genuine-polygon-raster.h"

#include "test-metal-compact-polygon-fallback.h"

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--genuine-polygons")) {
        genuine_polygon_tests();
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--polygon-modes")) {
        polygon_modes_tests();
        return 0;
    }
    assert(argc == 1 || ((argc == 2 || argc == 3) &&
        (!strcmp(argv[1], "--strip") || !strcmp(argv[1], "--fan") ||
         !strcmp(argv[1], "--quads") || !strcmp(argv[1], "--quad-strip"))));
    BOOL four = argc == 3 && !strcmp(argv[2], "--four");
    BOOL sliced = argc == 3 && !four;
    BOOL oddSlice = sliced && !strcmp(argv[2], "--odd-slice");
    assert(!sliced || oddSlice || !strcmp(argv[2], "--slices"));
    enum NV2AMetalPrimitive primitive = argc == 1 ? NV2AMetalPrimitiveTriangles :
        !strcmp(argv[1], "--strip") ? NV2AMetalPrimitiveTriangleStrip :
        !strcmp(argv[1], "--fan") ? NV2AMetalPrimitiveTriangleFan :
        !strcmp(argv[1], "--quads") ? NV2AMetalPrimitiveQuads : NV2AMetalPrimitiveQuadStrip;
    BOOL quads = primitive == NV2AMetalPrimitiveQuads || primitive == NV2AMetalPrimitiveQuadStrip;
    assert(!four || quads);
    unsigned topology = primitive == NV2AMetalPrimitiveTriangleStrip ? NV2AMetalDirectTriangleStrip :
                        primitive == NV2AMetalPrimitiveTriangleFan ? NV2AMetalDirectTriangleFan :
                        primitive == NV2AMetalPrimitiveQuads ? NV2AMetalDirectTriangleQuads :
                        primitive == NV2AMetalPrimitiveQuadStrip ? NV2AMetalDirectTriangleQuadStrip : 0;
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        require(geometry != nil, error);
        NV2AMetalVertex v[32] = { 0 };
        for (unsigned i = 0; i < 32; i++) {
            unsigned triangle = i / 3, corner = i % 3;
            /* Alternate winding without changing the set of covered positions.
             */
            if (triangle & 1)
                corner = 2 - corner;
            float x = (triangle % 3) * 10 + 1.5f + (corner == 1 ? 7 : 0);
            float y = (triangle / 3) * 8 + .5f + (corner == 2 ? 6 : 0);
            v[i].screen[0] = x;
            v[i].screen[1] = y;
            v[i].screen[2] = .125f + i / 128.f;
            v[i].screen[3] = .5f + i / 64.f;
            v[i].clip[0] = x / 16 - 1;
            v[i].clip[1] = 1 - y / 16;
            v[i].clip[2] = .5f;
            v[i].clip[3] = 1;
            v[i].point_size = 1 + i % 3;
            for (unsigned k = 0; k < 4; k++) {
                v[i].color[0][k] = k == 3 ? 1 : (i >> k) & 1;
                v[i].color[2][k] = 1 - v[i].color[0][k];
                v[i].texcoord[3][k] = (i % 7) / 8.f;
                /* Deliberately stale polygon metadata: the triangle shader must
                 * replace it, including restored/preexisting triangle records.
                 */
                for (unsigned j = 0; j < 3; j++)
                    v[i].plane[j][k] = 100 + j + k;
            }
            v[i].face = NV2AMetalFaceBack;
            v[i].slope = 999;
        }
        v[24].clip[0] =
            2; /* Clipped triangle, including a negative-W corner. */
        v[25].clip[3] = -1;
        memcpy(v[28].clip, v[27].clip, sizeof(v[27].clip)); /* Degenerate. */
        v[18].screen[3] = 0x1p-70f;
        v[19].screen[3] = 0x1p-69f;
        v[20].screen[3] = 0x1p-68f;
        v[21].screen[3] = 0x1p70f;
        v[22].screen[3] = 0x1p69f;
        v[23].screen[3] = 0x1p68f;
        /* Repeated logical records exercise physical counts smaller than
         * the logical source while retaining a materialized reference. */
        if (getenv("XEMU_TEST_INDEXED_DUPLICATES"))
            for (unsigned i = 16; i < 32; i++)
                v[i] = v[i - 16];
        id<MTLBuffer> source =
            [commands.device newBufferWithBytes:v
                                         length:sizeof(v)
                                        options:MTLResourceStorageModeShared];
        assert(source);
        BOOL indexedTest = getenv("XEMU_TEST_INDEXED_RASTER") != NULL;
        NV2AMetalIndexedVertices *indexedSource = indexedTest ?
            indexed_raster_source(commands.device, v, 32, &error) : nil;
        id<MTLBuffer> shifted = [commands.device newBufferWithLength:37 * sizeof(NV2AMetalVertex)
                                                            options:MTLResourceStorageModeShared];
        assert(shifted);
        memset(shifted.contents, 0x5a, shifted.length);
        memcpy((uint8_t *)shifted.contents + 5 * sizeof(NV2AMetalVertex), v, sizeof(v));
        require([commands beginWithError:&error] != nil, error);
        Class cls = object_getClass(commands.commandBuffer);
        SEL selector = @selector(computeCommandEncoder);
        Method cm = class_getInstanceMethod(cls, selector);
        assert(cm);
        class_addMethod(cls, selector, method_getImplementation(cm),
                        method_getTypeEncoding(cm));
        cm = class_getInstanceMethod(cls, selector);
        original_compute =
            (void *)method_setImplementation(cm, (IMP)compute_encoder);
        Method fm = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
        assert(fm);
        original_feedback =
            (void *)method_setImplementation(fm, (IMP)feedback_handler);
        [commands cancel];
        unsigned pairs = 0, geometryReferenceEncoders = 0,
                 geometryDirectEncoders = 0;
        uint64_t copiedBytes = 0, visible = 0;
        double times[2][9] = { { 0 } };
        for (unsigned samples = 1; samples <= 4; samples *= 4) {
            NV2AMetalPixelShader *pixel = [[NV2AMetalPixelShader alloc]
                initWithDevice:commands.device
                   colorFormat:MTLPixelFormatRGBA8Unorm
                   depthFormat:MTLPixelFormatDepth32Float
                   sampleCount:samples
                         error:&error];
            require(pixel != nil, error);
            for (unsigned test = 0; test < 139; test++) {
                /* 128 state combinations, then an isolated paired timing case.
                 */
                unsigned flags = test < 128 ? test : 0;
                unsigned sourceCount = four ? 4 : flags & 2 ? 31 : 32;
                unsigned outputCount = primitive == NV2AMetalPrimitiveQuads ? sourceCount / 4 * 6 :
                    primitive == NV2AMetalPrimitiveQuadStrip ? (sourceCount / 2 - 1) * 6 :
                    topology ? (sourceCount - 2) * 3 : 30;
                unsigned nativeSourceCount = primitive == NV2AMetalPrimitiveQuads ? sourceCount / 4 * 4 :
                    primitive == NV2AMetalPrimitiveQuadStrip ? sourceCount / 2 * 2 :
                    topology ? sourceCount : 30;
                unsigned options = (flags & (quads ? 61 : 63)) | topology;
                unsigned draws = test < 128 ? 1 : 32;
                NSData *referenceImage = nil;
                uint64_t referenceCount = 0;
                for (unsigned variant = 0; variant < 2; variant++) {
                    @autoreleasepool {
                        BOOL direct = (variant ^ (test & 1)) != 0;
                        NV2AMetalGeometryRasterConfig c = {
                            .front = NV2AMetalPolygonFill,
                            .back = NV2AMetalPolygonFill,
                            .cullFront = !!(flags & 16),
                            .cullBack = !!(flags & 32),
                            .frontClockwise = !!(flags & 8),
                            .lineWidth = 1,
                            .viewportWidth = 32,
                            .viewportHeight = 32
                        };
                        NV2AMetalPixelUniforms u = { 0 };
                        u.combiner.final_inputs[0] =
                            flags & 64 ? PS_REGISTER_T3 : PS_REGISTER_V0;
                        u.combiner.final_inputs[1] =
                            (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
                        u.combiner.shader_stage_program =
                            flags & 64 ? PS_TEXTUREMODES_PASSTHRU << 15 : 0;
                        u.smooth_shading = flags & 1;
                        u.two_side = 1;
                        u.z_perspective = !!(flags & 4);
                        u.point_sprite = 1;
                        u.depth_offset = .125f;
                        u.depth_factor = 2;
                        u.depth_format = flags & 64 ? NV2AMetalPixelDepthF24 :
                                                      NV2AMetalPixelDepthD24;
                        u.surface_scale[0] = u.surface_scale[1] = 1;
                        if (getenv("XEMU_TEST_INDEXED_SCALE")) {
                            u.surface_scale[0] = 2;
                            u.surface_scale[1] = 3;
                        }
                        u.clip_range[1] = u.clip_range[3] = 16777215;
                        u.clip_regions[0][2] = u.clip_regions[0][3] = 32;
                        for (unsigned k = 0; k < 4; k++) {
                            u.textures[k].dimension = 2;
                            u.textures[k].scale = 1;
                        }
                        NV2AMetalDrawConfig config = { 0 };
                        config.control[0] =
                            NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                            NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                            NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                            NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                            NV_PGRAPH_CONTROL_0_ZENABLE |
                            NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16;
                        NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                            initWithDevice:commands.device
                                    config:&config
                                     error:&error];
                        require(state != nil, error);
                        id<MTLTexture> color = texture(
                            commands.device, MTLPixelFormatRGBA8Unorm, samples);
                        id<MTLTexture> depth =
                            texture(commands.device, MTLPixelFormatDepth32Float,
                                    samples);
                        id<MTLTexture> resolve =
                            samples == 1 ? color :
                                           texture(commands.device,
                                                   MTLPixelFormatRGBA8Unorm, 1);
                        uint64_t initial = 7;
                        id<MTLBuffer> query = [commands.device
                            newBufferWithBytes:&initial
                                        length:8
                                       options:MTLResourceStorageModeShared];
                        id<MTLBuffer> readback = [commands.device
                            newBufferWithLength:16384
                                        options:MTLResourceStorageModeShared];
                        assert(query && readback);
                        memset(readback.contents, 0x5a, readback.length);
                        require([commands beginWithError:&error] != nil, error);
                        MTL4RenderPassDescriptor *pass =
                            [MTL4RenderPassDescriptor new];
                        pass.colorAttachments[0].texture = color;
                        pass.colorAttachments[0].loadAction =
                            MTLLoadActionClear;
                        pass.colorAttachments[0].storeAction =
                            samples == 1 ? MTLStoreActionStore :
                                           MTLStoreActionMultisampleResolve;
                        if (samples > 1)
                            pass.colorAttachments[0].resolveTexture = resolve;
                        pass.depthAttachment.texture = depth;
                        pass.depthAttachment.loadAction = MTLLoadActionClear;
                        pass.depthAttachment.storeAction = MTLStoreActionStore;
                        pass.depthAttachment.clearDepth = 1;
                        pass.visibilityResultBuffer = query;
                        pass.visibilityResultType =
                            MTLVisibilityResultTypeAccumulate;
                        for (unsigned draw = 0; draw < draws; draw++) {
                            unsigned before = computeEncoders;
                            NSArray<NV2AMetalGeometryResult *> *gs =
                                direct && indexedTest ?
                                    [geometry encodeNativeRasterSlice:indexed_raster_slice(indexedSource, sourceCount, commands, &error)
                                        primitive:primitive config:&c smooth:flags & 1
                                        firstProvoking:flags & 2 zPerspective:!!(flags & 4)
                                        commands:commands error:&error] :
                                direct ?
                                    [geometry
                                        encodeNativeRasterVertices:sliced ? shifted : source
                                                             first:sliced ? 5 : 0
                                                             count:sourceCount
                                                         primitive:
                                                             primitive
                                                            config:&c
                                                            smooth:flags & 1
                                                    firstProvoking:flags & 2
                                                      zPerspective:!!(flags & 4)
                                                          commands:commands
                                                             error:&error] :
                                    [geometry
                                        encodeRasterVertices:source
                                                       count:sourceCount
                                                   primitive:
                                                       primitive
                                                      config:&c
                                                      smooth:flags & 1
                                              firstProvoking:flags & 2
                                                zPerspective:!!(flags & 4)
                                                    commands:commands
                                                       error:&error];
                            require(gs.count == 1, error);
                            NV2AMetalGeometryResult *g = gs[0];
                            assert(g.vertexCount == outputCount &&
                                   g.primitiveCount == outputCount / (quads ? 6 : 3) &&
                                   g.verticesPerPrimitive == (quads ? 6u : 3u) && !g.directPoints &&
                                   !g.directLineMode);
                            assert(g.directTriangles == direct);
                            assert(g.sourceVertexCount == (direct ? nativeSourceCount : outputCount));
                            assert(g.directTriangleOptions ==
                                   (direct ? options : 0));
                            NV2AMetalPixelRasterClass raster =
                                direct ?
                                    (NV2AMetalPixelRasterClass)(NV2AMetalPixelRasterDirectTriangle |
                                                                options) :
                                    NV2AMetalPixelRasterNative;
                            assert(!g.expandedLines && !g.expandedPolygons);
                            assert((g.vertices == (indexedTest && direct ? indexedSource.vertices : sliced && direct ? shifted : source)) == direct);
                            assert(g.firstVertex == (sliced && direct && !indexedTest ? 5u : 0u));
                            if (direct) {
                                assert(g.indexedVertices == (indexedTest ? indexedSource : nil));
                                assert(g.indexOffset == (indexedTest ? 5u : 0u));
                                assert(computeEncoders == before);
                                geometryDirectEncoders +=
                                    computeEncoders - before;
                            } else {
                                assert(computeEncoders == before + 1);
                                geometryReferenceEncoders++;
                                copiedBytes += g.vertices.length;
                            }
                            NV2AMetalPixelTexture bindings[4] = { 0 };
                            if (direct && topology && test == 0 && samples == 1 && draw == 0) {
                                /* The raw API can use all bound storage, even
                                 * when geometry selected only one quad. */
                                NSUInteger excessCount =
                                    (g.vertices.length / sizeof(NV2AMetalVertex) + 1) * 6;
                                assert(![pixel encodeVertices:g.vertices offset:g.firstVertex * sizeof(NV2AMetalVertex)
                                    count:excessCount primitive:MTLPrimitiveTypeTriangle
                                    uniforms:&u textures:bindings pass:pass drawState:state rasterClass:raster
                                    ignorePolygonCulling:NO commands:commands error:&error] && error);
                                error = nil;
                                assert(![pixel encodeVertices:g.vertices offset:0 count:3 primitive:MTLPrimitiveTypeTriangle
                                    uniforms:&u textures:bindings pass:pass drawState:state
                                    rasterClass:(NV2AMetalPixelRasterClass)(NV2AMetalPixelRasterDirectTriangle |
                                        NV2AMetalDirectTriangleTopologyMask)
                                    ignorePolygonCulling:NO commands:commands error:&error] && error);
                                error = nil;
                                assert(![pixel encodeGeometry:g offset:0 count:2 uniforms:&u textures:bindings
                                    pass:pass drawState:state rasterClass:raster ignorePolygonCulling:NO
                                    renderEncoder:nil commands:commands error:&error] && error);
                                error = nil;
                                assert(![pixel encodeGeometry:g offset:g.vertexCount * sizeof(NV2AMetalVertex)
                                    count:3 uniforms:&u textures:bindings pass:pass drawState:state
                                    rasterClass:raster ignorePolygonCulling:NO renderEncoder:nil
                                    commands:commands error:&error] && error);
                                error = nil;
                                NV2AMetalPixelDraw *emptyPacket = [pixel prepareGeometry:g
                                    offset:g.vertexCount * sizeof(NV2AMetalVertex) count:0
                                    uniforms:&u textures:bindings pass:pass drawState:state rasterClass:raster
                                    ignorePolygonCulling:NO commands:commands error:&error];
                                require(emptyPacket != nil, error);
                                assert(!emptyPacket.vertexCount);
                            }
                            if (sliced) {
                                id<MTL4RenderCommandEncoder> encoder =
                                    [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
                                assert(encoder);
                                [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll
                                               visibilityOptions:MTL4VisibilityOptionDevice];
                                [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
                                const NSUInteger firsts[] = { oddSlice ? 1u : 0u, 3, 9 };
                                const NSUInteger counts[] = { oddSlice ? g.vertexCount - 3 : 3, 6, g.vertexCount - 9 };
                                for (unsigned part = 0; part < (oddSlice ? 1u : 3u); part++)
                                    require([pixel encodeGeometry:g offset:firsts[part] * sizeof(NV2AMetalVertex)
                                        count:counts[part] uniforms:&u textures:bindings pass:pass drawState:state
                                        rasterClass:raster ignorePolygonCulling:NO renderEncoder:encoder
                                        commands:commands error:&error], error);
                                [encoder barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll
                                          visibilityOptions:MTL4VisibilityOptionDevice];
                                [encoder endEncoding];
                            } else {
                                require([pixel encodeGeometry:g
                                                          offset:0
                                                           count:g.vertexCount
                                                        uniforms:&u
                                                        textures:bindings
                                                            pass:pass
                                                       drawState:state
                                                     rasterClass:raster
                                            ignorePolygonCulling:NO renderEncoder:nil
                                                        commands:commands
                                                           error:&error],
                                        error);
                            }
                        }
                        require([commands addResource:readback error:&error],
                                error);
                        id<MTL4ComputeCommandEncoder> copy =
                            [commands.commandBuffer computeCommandEncoder];
                        assert(copy);
                        [copy
                            barrierAfterQueueStages:MTLStageAll
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
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error],
                                error);
                        uint64_t count = *(uint64_t *)query.contents;
                        assert(count >= 7);
                        if ((flags & 48) == 48)
                            assert(count == 7);
                        visible += count - 7;
                        if (variant == 0) {
                            referenceImage =
                                [NSData dataWithBytes:readback.contents
                                               length:readback.length];
                            referenceCount = count;
                        } else {
                            assert(count == referenceCount);
                            if (memcmp(referenceImage.bytes, readback.contents,
                                       readback.length)) {
                                fprintf(stderr,
                                        "Triangle mismatch samples=%u flags=%u "
                                        "direct=%d\n",
                                        samples, flags, direct);
                                abort();
                            }
                            pairs++;
                        }
                        if (test >= 130) {
                            assert(gpuSeconds > 0);
                            times[direct][test - 130] = gpuSeconds;
                        }
                    }
                }
            }
            qsort(times[0], 9, sizeof(double), compare_double);
            qsort(times[1], 9, sizeof(double), compare_double);
            printf("Direct triangles samples=%u: 32-draw GPU median "
                   "direct/reference=%.6f/%.6f ms (2 warmups,9 paired "
                   "alternating samples)\n",
                   samples, times[1][4] * 1000, times[0][4] * 1000);
        }
        /* Empty/cancelled recordings and the generic triangle/line/polygon
         * paths retain their existing result contracts. */
        NV2AMetalGeometryRasterConfig c = { .front = NV2AMetalPolygonFill,
                                            .back = NV2AMetalPolygonFill,
                                            .lineWidth = 1 };
        require([commands beginWithError:&error] != nil, error);
        NSArray *empty =
            [geometry encodeNativeRasterVertices:source
                                           count:0
                                       primitive:primitive
                                          config:&c
                                          smooth:NO
                                  firstProvoking:NO
                                    zPerspective:NO
                                        commands:commands
                                           error:&error];
        require(empty.count == 1, error);
        assert(((NV2AMetalGeometryResult *)empty[0]).vertexCount == 0);
        assert(![geometry encodeNativeRasterVertices:source
                                               count:33
                                           primitive:primitive
                                              config:&c
                                              smooth:NO
                                      firstProvoking:NO
                                        zPerspective:NO
                                            commands:commands
                                               error:&error]);
        assert(![geometry encodeNativeRasterVertices:source
                                               count:32
                                           primitive:primitive
                                              config:NULL
                                              smooth:NO
                                      firstProvoking:NO
                                        zPerspective:NO
                                            commands:commands
                                               error:&error]);
        [commands cancel];
        /* Invalid indexed fallbacks must fail before the gather opens an
         * encoder, including a contradictory borrowed buffer. */
        NV2AMetalIndexedVertices *preflightSource = indexedSource ?:
            indexed_raster_source(commands.device, v, 32, &error);
        require(preflightSource != nil, error);
        for (unsigned invalid = 0; invalid < 9; invalid++) {
            require([commands beginWithError:&error] != nil, error);
            unsigned before = computeEncoders;
            NV2AMetalVertexSlice *slice =
                indexed_raster_slice(preflightSource, 6, commands, &error);
            NV2AMetalGeometryRasterConfig bad = c;
            bad.lineWidth = 2;
            bad.viewportWidth = bad.viewportHeight = 32;
            const NV2AMetalGeometryRasterConfig *config = &bad;
            enum NV2AMetalPrimitive mode = NV2AMetalPrimitiveLines;
            if (invalid == 0)
                bad.lineWidth = -1;
            else if (invalid == 1)
                config = NULL;
            else if (invalid == 2)
                mode = 0;
            else if (invalid == 3)
                mode = NV2AMetalPrimitivePolygon + 1;
            else if (invalid == 4)
                [slice setValue:source forKey:@"buffer"];
            else if (invalid == 5)
                [slice setValue:@(preflightSource.vertexCount) forKey:@"firstVertex"];
            else if (invalid == 6)
                [slice setValue:@((NSUInteger)UINT32_MAX + 1) forKey:@"vertexCount"];
            else if (invalid == 7) {
                mode = NV2AMetalPrimitivePolygon;
                bad.front = NV2AMetalPolygonPoint;
            } else
                [commands cancel];
            error = nil;
            assert(![geometry encodeNativeRasterSlice:slice primitive:mode
                config:config smooth:NO firstProvoking:YES zPerspective:YES
                commands:commands error:&error] && error);
            assert(computeEncoders == before);
            [commands cancel];
        }
        error = nil;
        for (unsigned tailCount = 1; tailCount < (quads ? 4u : 3u); tailCount++) {
            require([commands beginWithError:&error] != nil, error);
            NSArray *tail =
                [geometry encodeNativeRasterVertices:source
                                               count:tailCount
                                           primitive:primitive
                                              config:&c
                                              smooth:NO
                                      firstProvoking:NO
                                        zPerspective:NO
                                            commands:commands
                                               error:&error];
            require(tail.count == 1, error);
            assert(((NV2AMetalGeometryResult *)tail[0]).vertexCount == 0);
            [commands cancel];
        }
        for (unsigned special = 0; special < 3; special++) {
            c.front =
                special == 0 ? NV2AMetalPolygonLine : NV2AMetalPolygonFill;
            c.back =
                special == 1 ? NV2AMetalPolygonPoint : NV2AMetalPolygonFill;
            c.polygonSmooth = special >= 1;
            c.viewportWidth = c.viewportHeight = 32;
            require([commands beginWithError:&error] != nil, error);
            NSArray *a =
                indexedTest ?
                    [geometry encodeNativeRasterSlice:indexed_raster_slice(
                                                          indexedSource, 6,
                                                          commands, &error)
                                            primitive:primitive
                                               config:&c
                                               smooth:NO
                                       firstProvoking:YES
                                         zPerspective:YES
                                             commands:commands
                                                error:&error] :
                    [geometry encodeNativeRasterVertices:source
                                                   count:6
                                               primitive:primitive
                                                  config:&c
                                                  smooth:NO
                                          firstProvoking:YES
                                            zPerspective:YES
                                                commands:commands
                                                   error:&error];
            NSArray *b = [geometry encodeRasterVertices:source
                                                  count:6
                                              primitive:primitive
                                                 config:&c
                                                 smooth:NO
                                         firstProvoking:YES
                                           zPerspective:YES
                                               commands:commands
                                                  error:&error];
            require(a.count && a.count == b.count, error);
            for (NV2AMetalGeometryResult *g in a)
                if (g.compactPolygons || g.compactLines)
                    compact_fallback_source(g, primitive, source, indexedSource,
                                            commands);
            id<MTLBuffer> nativeFrame =
                compact_fallback_frame(commands, a, primitive, YES);
            id<MTLBuffer> legacyFrame =
                compact_fallback_frame(commands, b, primitive, YES);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            assert(nativeFrame.length == legacyFrame.length &&
                   !memcmp(nativeFrame.contents, legacyFrame.contents,
                           nativeFrame.length));
            for (unsigned k = 0; k < a.count; k++) {
                NV2AMetalGeometryResult *x = a[k], *y = b[k];
                assert(x.vertexCount == y.vertexCount &&
                       x.primitiveType == y.primitiveType);
                if (!x.compactPolygons && !x.compactLines && !x.directPoints &&
                    !x.directTriangles && !x.directQuadOptions &&
                    !x.directPolygonOptions) {
                    assert(x.vertexCount <=
                               x.vertices.length / sizeof(NV2AMetalVertex) &&
                           y.vertexCount <=
                               y.vertices.length / sizeof(NV2AMetalVertex));
                    assert(!memcmp(x.vertices.contents, y.vertices.contents,
                                   x.vertexCount * sizeof(NV2AMetalVertex)));
                }
            }
        }
        c.front = c.back = NV2AMetalPolygonFill;
        c.lineSmooth = NO;
        c.lineWidth = 2;
        c.viewportWidth = c.viewportHeight = 32;
        c.polygonSmooth = YES;
        for (unsigned primitive = NV2AMetalPrimitiveTriangles;
             primitive <= NV2AMetalPrimitivePolygon; primitive++) {
            require([commands beginWithError:&error] != nil, error);
            NSArray *a =
                indexedTest ?
                    [geometry encodeNativeRasterSlice:indexed_raster_slice(
                                                          indexedSource, 6,
                                                          commands, &error)
                                            primitive:primitive
                                               config:&c
                                               smooth:NO
                                       firstProvoking:YES
                                         zPerspective:NO
                                             commands:commands
                                                error:&error] :
                    [geometry encodeNativeRasterVertices:source
                                                   count:6
                                               primitive:primitive
                                                  config:&c
                                                  smooth:NO
                                          firstProvoking:YES
                                            zPerspective:NO
                                                commands:commands
                                                   error:&error];
            NSArray *b = [geometry encodeRasterVertices:source
                                                  count:6
                                              primitive:primitive
                                                 config:&c
                                                 smooth:NO
                                         firstProvoking:YES
                                           zPerspective:NO
                                               commands:commands
                                                  error:&error];
            require(a.count == 1 && b.count == 1, error);
            NV2AMetalGeometryResult *x = a[0], *y = b[0];
            assert(!x.compactLines && !y.compactLines && !x.directPoints &&
                   !y.directPoints && !x.directTriangles &&
                   !y.directTriangles && !x.directQuadOptions &&
                   !y.directQuadOptions && !x.directPolygonOptions &&
                   !y.directPolygonOptions && !x.directLineMode &&
                   !y.directLineMode && !x.directLineOptions &&
                   !y.directLineOptions);
            compact_fallback_source(x, primitive, source, indexedSource,
                                    commands);
            assert(x.compactPolygons && !y.compactPolygons);
            id<MTLBuffer> nativeFrame =
                compact_fallback_frame(commands, a, primitive, NO);
            id<MTLBuffer> legacyFrame =
                compact_fallback_frame(commands, b, primitive, NO);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            assert(nativeFrame.length == legacyFrame.length &&
                   !memcmp(nativeFrame.contents, legacyFrame.contents,
                           nativeFrame.length));
            assert(x.vertexCount == y.vertexCount &&
                   x.primitiveType == y.primitiveType);
            assert(y.vertexCount <=
                       y.vertices.length / sizeof(NV2AMetalVertex) &&
                   y.vertices.contents &&
                   ![x canUsePolygonCoverageForCommands:commands]);
        }
        assert(visible > 0);
        method_setImplementation(cm, (IMP)original_compute);
        method_setImplementation(fm, (IMP)original_feedback);
        printf(
            "Direct triangles topology%u slices%u odd%u: %u exact color/query "
            "pairs (single-sample depth "
            "exact too), %llu visible samples; geometry encoders "
            "direct/reference=%u/%u, output bytes avoided=%llu;6 smooth-fill "
            "topologies,empty/cancel/input rejects PASS\n",
            primitive, (unsigned)sliced, (unsigned)oddSlice, pairs,
            (unsigned long long)visible, geometryDirectEncoders,
            geometryReferenceEncoders, (unsigned long long)copiedBytes);
    }
    return 0;
}
