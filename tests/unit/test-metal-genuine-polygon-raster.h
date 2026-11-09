/* Genuine whole-boundary polygon raster parity against compute geometry.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_GENUINE_POLYGON_RASTER_H
#define TEST_METAL_GENUINE_POLYGON_RASTER_H
static unsigned gp_computes, gp_dispatches, gp_face_dispatches,
    gp_reference_dispatches;
static unsigned gp_pairs, gp_direct, gp_fallback, gp_rejects;
static uint64_t gp_visible, gp_avoided;
static id (*gp_original_compute)(id, SEL);
static void (*gp_original_dispatch)(id, SEL, MTLSize, MTLSize);
static id gp_compute(id object, SEL selector)
{
    gp_computes++;
    return gp_original_compute(object, selector);
}
static void gp_dispatch(id object, SEL selector, MTLSize threads, MTLSize group)
{
    gp_dispatches++;
    gp_original_dispatch(object, selector, threads, group);
}
static PolygonModesInput *gp_input(id<MTLDevice> device, unsigned fixture,
                                   unsigned transport)
{
    const float convex[8][2] = { { 4, 8 },   { 8, 4 },   { 24, 4 }, { 28, 8 },
                                 { 28, 24 }, { 24, 28 }, { 8, 28 }, { 4, 24 } };
    const float nonconvex[8][2] = {
        { 4, 4 }, { 12, 4 },  { 20, 4 }, { 28, 12 },
        { 8, 8 }, { 28, 28 }, { 4, 28 }, { 12, 12 }
    };
    NV2AMetalVertex records[8] = { 0 };
    for (unsigned i = 0; i < 8; i++) {
        NV2AMetalVertex *v = &records[i];
        const float *xy = fixture == 2 ? nonconvex[i] : convex[i];
        float x = xy[0], y = fixture == 3 ? 16 : xy[1];
        v->screen[0] = x;
        v->screen[1] = y;
        v->screen[2] = (float)(0x200000 + (i % 4) * 0x280000);
        v->screen[3] = .5f + i / 16.f;
        v->clip[0] = x / 16 - 1;
        v->clip[1] = 1 - y / 16;
        v->clip[2] = .25f;
        v->clip[3] = 1;
        if (fixture == 4 && i < 2)
            v->clip[3] = -1;
        if (fixture == 5) {
            float w = i & 1 ? .5f : 2;
            v->clip[0] *= w;
            v->clip[1] *= w;
            v->clip[3] = w;
        }
        v->point_size = 3;
        v->fog = (i + 1) / 8.f;
        v->face = NV2AMetalFaceNative;
        v->slope = 999;
        for (unsigned k = 0; k < 4; k++) {
            v->color[0][k] = k == 3 ? .5f : ((i + 2 * k) % 5) / 4.f;
            v->color[2][k] = k == 3 ? .5f : 1 - v->color[0][k];
            v->texcoord[3][k] = k == 3 ? 1 : (i + k) / 16.f;
            for (unsigned p = 0; p < 3; p++)
                v->plane[p][k] = 100 + p + k;
        }
    }
    /* First two fan triangles are genuinely degenerate; later ones determine
     * the whole face. Physical duplicate elimination is real, not a
     * permutation. */
    if (fixture == 1) {
        records[1] = records[0];
        records[2] = records[0];
    }
    PolygonModesInput *input = [PolygonModesInput new];
    input.logical = [NSData dataWithBytes:records length:sizeof(records)];
    input.linear = [device newBufferWithBytes:records
                                       length:sizeof(records)
                                      options:MTLResourceStorageModeShared];
    input.first = transport ? 5 : 0;
    if (transport < 2) {
        input.physical =
            [device newBufferWithLength:(8 + input.first) * sizeof(*records)
                                options:MTLResourceStorageModeShared];
        memset(input.physical.contents, 0x5a, input.physical.length);
        memcpy((uint8_t *)input.physical.contents +
                   input.first * sizeof(*records),
               records, sizeof(records));
    } else {
        NV2AMetalVertex unique[8];
        uint32_t ordinals[8];
        unsigned n = 0;
        for (unsigned i = 0; i < 8; i++) {
            unsigned j = 0;
            while (j < n && memcmp(unique + j, records + i, sizeof(*records)))
                j++;
            if (j == n)
                unique[n++] = records[i];
            ordinals[i] = j;
        }
        id<MTLBuffer> physical =
            [device newBufferWithLength:n * sizeof(*records)
                                options:MTLResourceStorageModeShared];
        NSMutableData *mapping =
            [NSMutableData dataWithLength:13 * sizeof(uint32_t)];
        for (unsigned i = 0; i < n; i++)
            ((NV2AMetalVertex *)physical.contents)[n - i - 1] = unique[i];
        for (unsigned i = 0; i < 8; i++)
            ((uint32_t *)mapping.mutableBytes)[5 + i] = n - ordinals[i] - 1;
        NSError *error = nil;
        input.owner =
            [[NV2AMetalIndexedVertices alloc] initWithVertices:physical
                                                 physicalCount:n
                                                         remap:mapping
                                                         error:&error];
        pm_require(input.owner != nil, error);
        input.physical = physical;
        assert(physical.length == n * sizeof(*records));
        if (fixture == 1)
            assert(n == 6 && input.owner.physicalVertexCount < 8);
    }
    assert(input.linear && input.physical);
    return input;
}
static NSData *gp_frame(NV2AMetalCommands *commands,
                        NV2AMetalGeometry *geometry,
                        NV2AMetalPixelShader *pixel, PolygonModesInput *input,
                        NSUInteger count, enum NV2AMetalPrimitive primitive,
                        NV2AMetalGeometryRasterConfig config, BOOL smooth,
                        BOOL first, BOOL w, BOOL two, BOOL depthOffset,
                        BOOL scale, unsigned samples, unsigned slicePlan,
                        BOOL direct, BOOL expectedDirect, unsigned effects,
                        uint64_t *visible, uint32_t *facing)
{
    NSError *error = nil;
    id<MTLTexture> color =
        pm_texture(commands.device, MTLPixelFormatRGBA8Unorm, samples);
    id<MTLTexture> depth = pm_texture(
        commands.device, MTLPixelFormatDepth32Float_Stencil8, samples);
    id<MTLTexture> resolve =
        samples == 1 ? color :
                       pm_texture(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&initial
                                     length:8
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:24580
                                     options:MTLResourceStorageModeShared];
    assert(query && readback);
    memset(readback.contents, 0x5a, readback.length);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = smooth;
    if (effects & 16) {
        u.combiner.final_inputs[0] = PS_REGISTER_FOG;
        u.combiner.final_inputs[1] = (PS_REGISTER_FOG | PS_CHANNEL_ALPHA) << 8;
        u.fog_color[0] = .25f;
        u.fog_color[1] = .5f;
        u.fog_color[2] = .75f;
    } else if (effects & (32 | 64)) {
        u.combiner.final_inputs[0] = PS_REGISTER_T3;
        u.combiner.shader_stage_program =
            (effects & 64 ? PS_TEXTUREMODES_PROJECT2D :
                            PS_TEXTUREMODES_PASSTHRU)
            << 15;
        u.point_sprite = !!(effects & 64);
    }
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
    if (effects & 8) {
        /* Keep blending and stencil active while the shared whole-boundary
         * face selects the permitted mode stream. */
        dc.blend = NV_PGRAPH_BLEND_EN | 2 | 5 << 4 | 6 << 8;
        dc.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 4 << 4 |
                        2 << 8 | 255 << 16 | 255u << 24;
        dc.control[2] = 1 | 1 << 4 | 4 << 8;
    }
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    pm_require(state != nil, error);
    pm_require([commands beginWithError:&error] != nil, error);
    unsigned before = gp_computes, dispatchBefore = gp_dispatches;
    NSArray<NV2AMetalGeometryResult *> *gs =
        pm_geometry(commands, geometry, input, count, primitive, &config,
                    smooth, first, w, direct, &error);
    pm_require(gs != nil, error);
    id<MTLBuffer> faceBuffer = nil;
    unsigned nonempty = 0;
    for (NV2AMetalGeometryResult *g in gs)
        nonempty += g.vertexCount != 0;
    if (direct && expectedDirect) {
        assert(gs.count == (config.front == config.back ? 1u : 2u));
        assert(gp_dispatches - dispatchBefore == !!nonempty &&
               gp_computes - before == !!nonempty);
        gp_face_dispatches += !!nonempty;
        for (NV2AMetalGeometryResult *g in gs) {
            NSUInteger generated = g.polygonMode == NV2AMetalPolygonLine ?
                                       (count < 2 ? 0 : count * 2) :
                                       (count < 3 ? 0 : (count - 2) * 3);
            assert(g.vertexCount == generated && !g.expandedLines &&
                   !g.expandedPolygons);
            if (generated) {
                assert((g.directPolygonOptions || g.directTriangles) &&
                       g.vertices == input.physical &&
                       g.indexedVertices == input.owner &&
                       g.sourceVertexCount == count &&
                       g.firstVertex == (input.owner ? 0 : input.first) &&
                       g.indexOffset == (input.owner ? input.first : 0));
                unsigned options = g.directTriangles ? g.directTriangleOptions :
                                                       g.directPolygonOptions;
                assert((options & NV2AMetalDirectTrianglePolygon) &&
                       !(options & NV2AMetalDirectTriangleFirst));
                assert(g.polygonFacing && g.polygonFacing.length == 4 &&
                       g.polygonFacing.storageMode == MTLStorageModePrivate &&
                       g.polygonFacing.device == commands.device);
                if (faceBuffer)
                    assert(faceBuffer == g.polygonFacing);
                faceBuffer = g.polygonFacing;
                gp_direct++;
            } else
                assert(!g.polygonFacing && !g.indexedVertices &&
                       !g.sourceVertexCount);
        }
    } else if (direct) {
        for (NV2AMetalGeometryResult *g in gs)
            assert(!g.directPolygonOptions && !g.directTriangles &&
                   !g.polygonFacing);
        gp_fallback++;
    } else {
        assert(gp_dispatches - dispatchBefore == 2 * nonempty &&
               gp_computes - before == nonempty);
        gp_reference_dispatches += 2 * nonempty;
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
    pass.stencilAttachment.texture = depth;
    pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.clearStencil = 0;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    pm_require([commands addResource:query error:&error], error);
    pm_require([commands addResource:color error:&error] &&
                   [commands addResource:depth error:&error] &&
                   [commands addResource:resolve error:&error],
               error);
    NV2AMetalPixelTexture bindings[4] = { 0 };
    MTLTextureDescriptor *sampleDescriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:2
                                    height:2
                                 mipmapped:NO];
    sampleDescriptor.storageMode = MTLStorageModeShared;
    sampleDescriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> sampled =
        [commands.device newTextureWithDescriptor:sampleDescriptor];
    const uint32_t texels[4] = { 0xff0000ff, 0xff00ff00, 0xffff0000,
                                 0xff7f3f1f };
    [sampled replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
               mipmapLevel:0
                 withBytes:texels
               bytesPerRow:8];
    MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
    samplerDescriptor.supportArgumentBuffers = YES;
    samplerDescriptor.sAddressMode = samplerDescriptor.tAddressMode =
        MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [commands.device newSamplerStateWithDescriptor:samplerDescriptor];
    assert(sampled && sampler);
    if (effects & 64) {
        bindings[3].texture = sampled;
        bindings[3].sampler = sampler;
    }
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    /* PRIM_POLYGON is one whole boundary. Mixed modes draw whole streams. */
    for (NV2AMetalGeometryResult *g in gs) {
        if (!g.vertexCount)
            continue;
        BOOL line = g.polygonMode == NV2AMetalPolygonLine;
        NSUInteger firstDraw = slicePlan == 1 ? 1 :
                               slicePlan == 2 ? g.vertexCount - (line ? 2 : 3) :
                                                0;
        NSUInteger drawCount = slicePlan == 1 ? g.vertexCount - (line ? 2 : 3) :
                               slicePlan == 2 ? (line ? 2 : 3) :
                                                g.vertexCount;
        if (firstDraw > g.vertexCount || drawCount > g.vertexCount - firstDraw)
            continue;
        BOOL encoded =
            [pixel encodeGeometry:g
                              offset:firstDraw * sizeof(NV2AMetalVertex)
                               count:drawCount
                            uniforms:&u
                            textures:bindings
                                pass:pass
                           drawState:state
                         rasterClass:pm_class(g)
                ignorePolygonCulling:g.expandedLines || g.expandedPolygons
                       renderEncoder:encoder
                            commands:commands
                               error:&error];
        if (!encoded)
            fprintf(stderr,
                    "Genuine polygon encode: direct%d source%lu mode%u "
                    "generated%lu first%lu count%lu slice%u samples%u "
                    "class%u faceBytes%lu\n",
                    direct, (unsigned long)count, g.polygonMode,
                    (unsigned long)g.vertexCount, (unsigned long)firstDraw,
                    (unsigned long)drawCount, slicePlan, samples, pm_class(g),
                    (unsigned long)g.polygonFacing.length);
        pm_require(encoded, error);
        if (!direct && expectedDirect)
            gp_avoided += g.vertices.length;
    }
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    pm_require([commands addResource:readback error:&error], error);
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
            destinationBytesPerImage:8192
                             options:MTLBlitOptionDepthFromDepthStencil];
    if (samples == 1)
        [copy copyFromTexture:depth
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(32, 32, 1)
                            toBuffer:readback
                   destinationOffset:16384
              destinationBytesPerRow:256
            destinationBytesPerImage:8192
                             options:MTLBlitOptionStencilFromDepthStencil];
    if (faceBuffer) {
        pm_require([commands addResource:faceBuffer error:&error], error);
        [copy copyFromBuffer:faceBuffer
                 sourceOffset:0
                     toBuffer:readback
            destinationOffset:24576
                         size:4];
    }
    [copy endEncoding];
    pm_require([commands submitWithError:&error] &&
                   [commands waitUntilIdleWithError:&error],
               error);
    *visible = *(const uint64_t *)query.contents;
    *facing = UINT32_MAX;
    if (faceBuffer) {
        memcpy(facing, (const uint8_t *)readback.contents + 24576, 4);
        assert(*facing <= 1);
    } else if (!direct && !config.cullFront && !config.cullBack) {
        for (NV2AMetalGeometryResult *g in gs) {
            if (g.vertexCount) {
                const NV2AMetalVertex *v = g.vertices.contents;
                if (v[0].face == NV2AMetalFaceFront ||
                    v[0].face == NV2AMetalFaceBack) {
                    *facing = v[0].face == NV2AMetalFaceFront;
                    break;
                }
            }
        }
    }
    return [NSData dataWithBytes:readback.contents length:24576];
}
static void gp_pair(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                    NV2AMetalPixelShader *pixel, PolygonModesInput *input,
                    NSUInteger count, NV2AMetalGeometryRasterConfig config,
                    unsigned shading, unsigned samples, unsigned slice,
                    BOOL expectedDirect, BOOL w)
{
    uint64_t queries[2];
    uint32_t face[2];
    NSData *frames[2];
    for (unsigned direct = 0; direct < 2; direct++)
        frames[direct] = gp_frame(
            commands, geometry, pixel, input, count, NV2AMetalPrimitivePolygon,
            config, shading & 1, shading & 2, w, shading & 4, shading & 2,
            shading & 1, samples, slice, direct, expectedDirect, shading,
            &queries[direct], &face[direct]);
    if (queries[0] != queries[1] || ![frames[0] isEqualToData:frames[1]] ||
        (face[0] != UINT32_MAX && face[1] != UINT32_MAX &&
         face[0] != face[1])) {
        fprintf(
            stderr,
            "Genuine polygon count%lu sample%u shading%u slice%u direct%d W%d "
            "modes%u/%u cull%d%d clockwise%d query%llu/%llu face%u/%u\n",
            (unsigned long)count, samples, shading, slice, expectedDirect, w,
            config.front, config.back, config.cullFront, config.cullBack,
            config.frontClockwise, (unsigned long long)queries[0],
            (unsigned long long)queries[1], face[0], face[1]);
        abort();
    }
    gp_visible += queries[1] - 7;
    gp_pairs++;
}
static void gp_bounds(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                      NV2AMetalPixelShader *pixel, BOOL wire)
{
    NSError *error = nil;
    PolygonModesInput *input = gp_input(commands.device, 1, 2);
    NV2AMetalGeometryRasterConfig config = {
        .front = wire ? NV2AMetalPolygonLine : NV2AMetalPolygonFill,
        .back = wire ? NV2AMetalPolygonLine : NV2AMetalPolygonFill,
        .lineWidth = 1,
        .viewportWidth = 32,
        .viewportHeight = 32
    };
    pm_require([commands beginWithError:&error] != nil, error);
    unsigned before = gp_computes;
    NSArray<NV2AMetalGeometryResult *> *gs =
        pm_geometry(commands, geometry, input, 8, NV2AMetalPrimitivePolygon,
                    &config, YES, YES, NO, YES, &error);
    pm_require(gs.count == 1, error);
    NV2AMetalGeometryResult *g = gs[0];
    assert(gp_computes == before + 1 && g.polygonFacing.length == 4);
    before = gp_computes;
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
                                    primitive:NV2AMetalPrimitivePolygon
                                       config:&config
                                       smooth:NO
                               firstProvoking:NO
                                 zPerspective:NO
                                     commands:commands
                                        error:&error] &&
               error);
        gp_rejects++;
    }
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:8
                                                error:&error];
    pm_require([stream appendIndexedVertices:input.owner
                                       first:5
                                       count:8
                                       error:&error],
               error);
    NV2AMetalVertexSlice *slice =
        [stream encodeSliceForDrawingWithCommands:commands error:&error];
    pm_require(slice != nil, error);
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        [slice setValue:invalid == 0 ? @9 : @8 forKey:@"vertexCount"];
        [slice setValue:invalid == 1 ? @(NSUIntegerMax) : @5
                 forKey:@"firstVertex"];
        [slice setValue:invalid == 2 ? input.linear : input.physical
                 forKey:@"buffer"];
        error = nil;
        assert(![geometry encodeNativeRasterSlice:slice
                                        primitive:NV2AMetalPrimitivePolygon
                                           config:&config
                                           smooth:NO
                                   firstProvoking:NO
                                     zPerspective:NO
                                         commands:commands
                                            error:&error] &&
               error);
        gp_rejects++;
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
    pm_require(state != nil, error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture =
        pm_texture(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture =
        pm_texture(commands.device, MTLPixelFormatDepth32Float_Stencil8, 1);
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    pass.stencilAttachment.texture = pass.depthAttachment.texture;
    pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    error = nil;
    assert(![pixel encodeVertices:g.vertices
                             offset:0
                              count:wire ? 2 : 3
                          primitive:g.primitiveType
                           uniforms:&u
                           textures:bindings
                               pass:pass
                          drawState:state
                        rasterClass:pm_class(g)
               ignorePolygonCulling:NO
                           commands:commands
                              error:&error] &&
           error);
    gp_rejects++;
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
                            rasterClass:pm_class(g)
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] &&
               error);
        gp_rejects++;
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
                     rasterClass:pm_class(g)
            ignorePolygonCulling:NO
                        commands:commands
                           error:&error];
    pm_require(empty != nil, error);
    assert(!empty.vertexCount && gp_computes == before);
    id<MTLBuffer> originalFace = g.polygonFacing;
    for (unsigned invalid = 0; invalid < 4; invalid++) {
        id<MTLBuffer> face =
            invalid == 0 ?
                nil :
                [commands.device
                    newBufferWithLength:invalid == 1 ? 3 :
                                        invalid == 2 ? 8 :
                                                       4
                                options:invalid == 3 ?
                                            MTLResourceStorageModeShared :
                                            MTLResourceStorageModePrivate];
        [g setValue:face forKey:@"polygonFacing"];
        error = nil;
        assert(![pixel prepareGeometry:g
                                 offset:0
                                  count:g.vertexCount
                               uniforms:&u
                               textures:bindings
                                   pass:pass
                              drawState:state
                            rasterClass:pm_class(g)
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] &&
               error);
        gp_rejects++;
        [g setValue:originalFace forKey:@"polygonFacing"];
    }
    for (unsigned invalid = 0; invalid < 2; invalid++) {
        error = nil;
        assert(![pixel prepareGeometry:g
                                 offset:0
                                  count:g.vertexCount
                               uniforms:&u
                               textures:bindings
                                   pass:pass
                              drawState:state
                            rasterClass:invalid ?
                                            NV2AMetalPixelRasterDirectTriangle :
                                            NV2AMetalPixelRasterNative
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] &&
               error);
        gp_rejects++;
    }
    error = nil;
    pm_require([pixel prepareGeometry:g
                                 offset:0
                                  count:g.vertexCount
                               uniforms:&u
                               textures:bindings
                                   pass:pass
                              drawState:state
                            rasterClass:pm_class(g)
                   ignorePolygonCulling:NO
                               commands:commands
                                  error:&error] != nil,
               error);
    NSArray<NV2AMetalGeometryResult *> *triangles =
        pm_geometry(commands, geometry, input, 8, NV2AMetalPrimitiveTriangles,
                    &config, NO, NO, NO, YES, &error);
    pm_require(triangles.count == 1, error);
    NV2AMetalGeometryResult *forged = triangles[0];
    [forged setValue:originalFace forKey:@"polygonFacing"];
    error = nil;
    assert(![pixel prepareGeometry:forged
                             offset:0
                              count:forged.vertexCount
                           uniforms:&u
                           textures:bindings
                               pass:pass
                          drawState:state
                        rasterClass:pm_class(forged)
               ignorePolygonCulling:NO
                           commands:commands
                              error:&error] &&
           error);
    gp_rejects++;
    assert(gp_computes == before);
    [commands cancel];
    for (unsigned submit = 0; submit < 2; submit++) {
        __weak NV2AMetalIndexedVertices *weakOwner;
        __weak id<MTLBuffer> weakFace;
        @autoreleasepool {
            PolygonModesInput *temporary = gp_input(commands.device, 1, 2);
            weakOwner = temporary.owner;
            pm_require([commands beginWithError:&error] != nil, error);
            NSArray *results = pm_geometry(commands, geometry, temporary, 8,
                                           NV2AMetalPrimitivePolygon, &config,
                                           YES, YES, NO, YES, &error);
            pm_require(results.count == 1, error);
            assert(((NV2AMetalGeometryResult *)results[0]).indexedVertices ==
                   temporary.owner);
            weakFace = ((NV2AMetalGeometryResult *)results[0]).polygonFacing;
        }
        @autoreleasepool {
            assert(weakOwner && weakFace);
        }
        if (submit)
            pm_require([commands submitWithError:&error] &&
                           [commands waitUntilIdleWithError:&error],
                       error);
        else
            [commands cancel];
        assert(!weakOwner && !weakFace);
    }
}
static void genuine_polygon_tests(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        pm_require(commands != nil, error);
        NV2AMetalGeometry *geometry =
            [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                error:&error];
        pm_require(geometry != nil, error);
        pm_require([commands beginWithError:&error] != nil, error);
        Class cls = object_getClass(commands.commandBuffer);
        SEL computeSelector = @selector(computeCommandEncoder);
        Method compute = class_getInstanceMethod(cls, computeSelector);
        id encoder = ((id (*)(id, SEL))method_getImplementation(compute))(
            commands.commandBuffer, computeSelector);
        pm_require(encoder != nil, error);
        Class ec = object_getClass(encoder);
        SEL dispatchSelector =
            @selector(dispatchThreads:threadsPerThreadgroup:);
        Method dispatch = class_getInstanceMethod(ec, dispatchSelector);
        [encoder endEncoding];
        [commands cancel];
        class_addMethod(cls, computeSelector, method_getImplementation(compute),
                        method_getTypeEncoding(compute));
        class_addMethod(ec, dispatchSelector,
                        method_getImplementation(dispatch),
                        method_getTypeEncoding(dispatch));
        compute = class_getInstanceMethod(cls, computeSelector);
        dispatch = class_getInstanceMethod(ec, dispatchSelector);
        gp_original_compute =
            (void *)method_setImplementation(compute, (IMP)gp_compute);
        gp_original_dispatch =
            (void *)method_setImplementation(dispatch, (IMP)gp_dispatch);
        @try {
            for (unsigned samples = 1; samples <= 4; samples *= 4) {
                NV2AMetalPixelShader *pixel = [[NV2AMetalPixelShader alloc]
                    initWithDevice:commands.device
                       colorFormat:MTLPixelFormatRGBA8Unorm
                       depthFormat:MTLPixelFormatDepth32Float_Stencil8
                       sampleCount:samples
                             error:&error];
                pm_require(pixel != nil, error);
                if (samples == 1) {
                    gp_bounds(commands, geometry, pixel, NO);
                    gp_bounds(commands, geometry, pixel, YES);
                }
                for (unsigned fixture = 0; fixture < 6; fixture++) {
                    PolygonModesInput *input =
                        gp_input(commands.device, fixture, 2);
                    for (unsigned modes = 0; modes < 4; modes++)
                        for (unsigned flags = 0; flags < 16; flags++) {
                            NV2AMetalGeometryRasterConfig c = {
                                .front = modes & 1 ? NV2AMetalPolygonLine :
                                                     NV2AMetalPolygonFill,
                                .back = modes & 2 ? NV2AMetalPolygonLine :
                                                    NV2AMetalPolygonFill,
                                .frontClockwise = flags & 1,
                                .cullFront =
                                    (flags & 6) == 2 || (flags & 6) == 6,
                                .cullBack =
                                    (flags & 6) == 4 || (flags & 6) == 6,
                                .lineWidth = 1,
                                .viewportWidth = 32,
                                .viewportHeight = 32
                            };
                            gp_pair(commands, geometry, pixel, input, 8, c,
                                    flags ^ 4, samples, flags & 8 ? 1 : 0, YES,
                                    NO);
                        }
                }
                PolygonModesInput *input = gp_input(commands.device, 0, 2);
                for (unsigned modes = 0; modes < 4; modes++) {
                    NV2AMetalGeometryRasterConfig c = {
                        .front = modes & 1 ? NV2AMetalPolygonLine :
                                             NV2AMetalPolygonFill,
                        .back = modes & 2 ? NV2AMetalPolygonLine :
                                            NV2AMetalPolygonFill,
                        .lineWidth = 1,
                        .viewportWidth = 32,
                        .viewportHeight = 32
                    };
                    for (unsigned n = 0; n <= 7; n++)
                        gp_pair(commands, geometry, pixel, input, n, c, 0,
                                samples, 0, YES, NO);
                    for (unsigned transport = 0; transport < 3; transport++)
                        gp_pair(commands, geometry, pixel,
                                gp_input(commands.device, 2, transport), 8, c,
                                7, samples, 2, YES, NO);
                    for (unsigned effect = 16; effect <= 64; effect *= 2)
                        gp_pair(commands, geometry, pixel, input, 8, c,
                                effect | 7, samples, 0, YES, NO);
                    if (modes == 0)
                        gp_pair(commands, geometry, pixel, input, 8, c, 2,
                                samples, 0, YES, YES);
                    else
                        for (unsigned fallback = 0; fallback < 3; fallback++) {
                            NV2AMetalGeometryRasterConfig bad = c;
                            if (fallback == 0)
                                bad.lineWidth = 3;
                            if (fallback == 1)
                                bad.lineSmooth = YES;
                            gp_pair(commands, geometry, pixel, input, 8, bad, 7,
                                    samples, 0, NO, fallback == 2);
                        }
                    if (modes != 3) {
                        c.polygonSmooth = YES;
                        gp_pair(commands, geometry, pixel, input, 8, c, 7,
                                samples, 0, NO, NO);
                    }
                }
            }
        } @finally {
            method_setImplementation(compute, (IMP)gp_original_compute);
            method_setImplementation(dispatch, (IMP)gp_original_dispatch);
        }
        assert(gp_pairs && gp_direct && gp_fallback && gp_rejects &&
               gp_visible && gp_face_dispatches && gp_reference_dispatches &&
               gp_avoided);
        printf(
            "Genuine polygons: %u exact color/query pairs (sample1 "
            "depth/stencil), %u borrowed direct results/%u fallbacks/%u guard "
            "rejects; %u native whole-face vs %u reference face+expansion "
            "dispatches; whole boundary/cull/provoker/closure/slope, tight "
            "remaps, slices, cancel and lifetime PASS\n",
            gp_pairs, gp_direct, gp_fallback, gp_rejects, gp_face_dispatches,
            gp_reference_dispatches);
    }
}
#endif
