/* Shared compact smooth-fill migration for the existing raster regressions.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_POLYGON_FALLBACK_H
#define TEST_METAL_COMPACT_POLYGON_FALLBACK_H

/* These former fallback cases now borrow compact source records. Compare
 * completed raster output while both geometry recordings are still live. */
static id<MTLBuffer>
compact_fallback_frame(NV2AMetalCommands *commands,
                       NSArray<NV2AMetalGeometryResult *> *results,
                       enum NV2AMetalPrimitive primitive, BOOL perspective)
{
    NSError *error = nil;
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatDepth32Float
                                         sampleCount:1
                                               error:&error];
    require(pixel != nil, error);
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 16777215, 0, 16777215 },
                                 .clip_regions = { { 0, 0, 32, 32 } },
                                 .surface_scale = { 1, 1 },
                                 .depth_format = NV2AMetalPixelDepthD24,
                                 .two_side = 1,
                                 .z_perspective = perspective,
                                 .depth_offset = .125f,
                                 .depth_factor = 2 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalDrawConfig config = { 0 };
    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ZENABLE |
                        NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7 << 16;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(state != nil, error);
    id<MTLTexture> color =
        texture(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    id<MTLTexture> depth =
        texture(commands.device, MTLPixelFormatDepth32Float, 1);
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&initial
                                     length:8
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:16392
                                     options:MTLResourceStorageModeShared];
    require(query && output && [commands addResource:query error:&error] &&
                [commands addResource:output error:&error],
            error);
    memset(output.contents, 0x5a, output.length);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    NSMutableArray<NV2AMetalPixelDraw *> *packets = [NSMutableArray new];
    for (NV2AMetalGeometryResult *g in results) {
        unsigned options = g.directPolygonOptions  ?:
                               g.directQuadOptions ?:
                                                     g.directTriangleOptions;
        NV2AMetalPixelRasterClass raster =
            g.compactPolygons ? NV2AMetalPixelRasterCompactPolygon :
            g.compactLines    ? NV2AMetalPixelRasterCompactLine :
            g.directPolygonOptions || g.directQuadOptions || g.directTriangles ?
                             NV2AMetalPixelRasterDirectTriangle | options :
            g.directPoints     ? NV2AMetalPixelRasterDirectPoint :
            g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
            g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
                                 NV2AMetalPixelRasterNative;
        NV2AMetalPixelDraw *packet = [pixel prepareGeometry:g
                                                     offset:0
                                                      count:g.vertexCount
                                                   uniforms:&u
                                                   textures:bindings
                                                       pass:pass
                                                  drawState:state
                                                rasterClass:raster
                                       ignorePolygonCulling:NO
                                                   commands:commands
                                                      error:&error];
        require(packet != nil, error);
        [packets addObject:packet];
    }
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    require(encoder != nil, nil);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    if (results.count == 2 && primitive != NV2AMetalPrimitivePolygon) {
        assert(results[0].primitiveCount == results[1].primitiveCount);
        for (NSUInteger p = 0; p < results[0].primitiveCount; p++)
            for (NSUInteger mode = 0; mode < results.count; mode++) {
                NSUInteger width = results[mode].verticesPerPrimitive;
                require([packets[mode] encodeWithRenderEncoder:encoder
                                                      commands:commands
                                                   firstVertex:p * width
                                                   vertexCount:width
                                                         error:&error],
                        error);
            }
    } else {
        for (NV2AMetalPixelDraw *packet in packets)
            require([packet encodeWithRenderEncoder:encoder
                                           commands:commands
                                              error:&error],
                    error);
    }
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    id<MTL4ComputeCommandEncoder> copy =
        [commands.commandBuffer computeCommandEncoder];
    require(copy != nil, nil);
    [copy barrierAfterQueueStages:MTLStageAll
                     beforeStages:MTLStageBlit
                visibilityOptions:MTL4VisibilityOptionDevice];
    [copy copyFromTexture:color
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(32, 32, 1)
                        toBuffer:output
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:8192];
    [copy copyFromTexture:depth
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(32, 32, 1)
                        toBuffer:output
               destinationOffset:8192
          destinationBytesPerRow:256
        destinationBytesPerImage:8192];
    [copy copyFromBuffer:query
             sourceOffset:0
                 toBuffer:output
        destinationOffset:16384
                     size:8];
    [copy endEncoding];
    return output;
}

static void compact_fallback_source(NV2AMetalGeometryResult *g,
                                    enum NV2AMetalPrimitive primitive,
                                    id<MTLBuffer> source,
                                    NV2AMetalIndexedVertices *owner,
                                    NV2AMetalCommands *commands)
{
    assert(g.vertices == (owner ? owner.vertices : source) &&
           g.indexedVertices == owner && !g.firstVertex &&
           g.indexOffset == (owner ? 5u : 0u) &&
           g.physicalVertexCount ==
               (owner ? owner.physicalVertexCount : g.sourceVertexCount) &&
           g.sourcePrimitive == primitive && !g.polygonFacing);
    assert(g.sourceVertexCount ==
               (primitive == NV2AMetalPrimitiveQuads ? 4u : 6u) &&
           !(g.vertexCount % 6) &&
           g.physicalVertexCount <=
               g.vertices.length / sizeof(NV2AMetalVertex));
    if (g.compactPolygons) {
        assert(!g.compactLines && g.expandedPolygons && !g.expandedLines &&
               [g canUsePolygonCoverageForCommands:commands] &&
               g.polygonCoverage.device == commands.device &&
               g.polygonCoverage.storageMode == MTLStorageModePrivate &&
               g.polygonCoverage.length ==
                   g.vertexCount / 6 * sizeof(NV2AMetalCompactPolygon) &&
               g.polygonProjections.device == commands.device &&
               g.polygonProjections.storageMode == MTLStorageModePrivate &&
               g.polygonProjections.length ==
                   g.vertexCount / 6 * sizeof(NV2AMetalPolygonProjection));
    } else {
        assert(g.compactLines && g.expandedLines && !g.expandedPolygons &&
               [g canUseLineCoverageForCommands:commands] &&
               g.lineCoverage.device == commands.device &&
               g.lineCoverage.storageMode == MTLStorageModePrivate &&
               g.lineCoverage.length ==
                   g.vertexCount / 6 * sizeof(NV2AMetalCompactLine));
    }
}

#endif
