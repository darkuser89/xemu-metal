/* Deferred Metal raster bindings and command-recording ownership.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_PIXEL_PACKETS_H
#define TEST_METAL_PIXEL_PACKETS_H

static id<MTLBuffer> packet_read(NV2AMetalCommands *commands,
                                 id<MTLTexture> texture)
{
    NSError *error = nil;
    id<MTLBuffer> bytes =
        [commands.device newBufferWithLength:256 * 8
                                     options:MTLResourceStorageModeShared];
    assert(bytes);
    require([commands addResource:bytes error:&error], error);
    require([commands addResource:texture error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:bytes
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [encoder endEncoding];
    return bytes;
}
static id<MTLTexture> packet_texture(id<MTLDevice> device, unsigned kind,
                                     unsigned value)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind == 1 ? MTLTextureType2D :
                    kind == 2 ? MTLTextureType3D :
                                MTLTextureTypeCube;
    d.pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.width = d.height = 1;
    d.depth = 1;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:d];
    assert(texture);
    uint8_t rgba[4] = { (value * 37 + 11) % 251, (value * 71 + 23) % 251,
                        (value * 113 + 43) % 251, 255 };
    for (unsigned slice = 0; slice < (kind == 3 ? 6u : 1u); slice++)
        [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1)
                   mipmapLevel:0
                         slice:slice
                     withBytes:rgba
                   bytesPerRow:4
                 bytesPerImage:4];
    return texture;
}
static void pixel_packet_tests(NV2AMetalCommands *commands,
                               id<MTLBuffer> vertices)
{
    NSError *error = nil;
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(geometry && shader, error);
    NV2AMetalVertex input[6];
    assert(vertices.length == sizeof(input));
    memcpy(input, vertices.contents, sizeof(input));
    for (unsigned i = 0; i < 6; i++) {
        const float coordinates[4] = { .5f, .25f, .75f, 1 };
        memcpy(input[i].texcoord[0], coordinates, sizeof(coordinates));
    }
    vertices =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(vertices);
    unsigned pairs = 0, rejected = 0;
    NV2AMetalPixelDraw *old = nil;
    NV2AMetalPixelDraw *last = nil;
    for (unsigned scene = 0; scene < 4; scene++) {
        uint8_t reference[8][32];
        uint64_t referenceQuery = 0;
        for (unsigned deferred = 0; deferred < 2; deferred++) {
            id<MTLTexture> color =
                attachment(commands.device, MTLPixelFormatRGBA8Unorm, 1);
            uint64_t zero = 0;
            id<MTLBuffer> query = [commands.device
                newBufferWithBytes:&zero
                            length:8
                           options:MTLResourceStorageModeShared];
            assert(query);
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalGeometryResult *g =
                [geometry encodeVertices:vertices
                                   count:6
                               primitive:NV2AMetalPrimitiveTriangles
                                 polygon:NV2AMetalPolygonFill
                                  smooth:YES
                          firstProvoking:NO
                            zPerspective:NO
                                commands:commands
                                   error:&error];
            require(g != nil, error);
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = color;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.visibilityResultBuffer = query;
            pass.visibilityResultType = MTLVisibilityResultTypeReset;
            NSMutableArray<NV2AMetalPixelDraw *> *packets =
                [NSMutableArray new];
            for (unsigned i = 0; i < 32; i++) {
                @autoreleasepool {
                    NV2AMetalDrawConfig config = { 0 };
                    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
                    config.scissor_enabled = YES;
                    config.scissor = (MTLScissorRect){ i % 8, 0, 1, 8 };
                    if (scene == 1)
                        config.blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12;
                    if (scene == 2)
                        config.blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
                    if (scene == 3 && (i & 1))
                        config.scissor.width = 0;
                    NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                        initWithDevice:commands.device
                                config:&config
                                 error:&error];
                    require(state != nil, error);
                    NV2AMetalPixelUniforms u = uniforms();
                    unsigned kind = (i + scene) % 4;
                    unsigned reg = kind ? PS_REGISTER_T0 : PS_REGISTER_C0;
                    u.combiner.final_inputs[0] = reg;
                    u.combiner.final_inputs[1] = (reg | PS_CHANNEL_ALPHA) << 8;
                    u.combiner.constants[16][0] = (i * 7 % 255) / 255.f;
                    u.combiner.constants[16][1] = (i * 13 % 255) / 255.f;
                    u.combiner.constants[16][2] = (i * 19 % 255) / 255.f;
                    u.combiner.constants[16][3] = .5;
                    NV2AMetalPixelTexture bindings[4] = { 0 };
                    id<MTLTexture> source =
                        kind ? packet_texture(commands.device, kind, i) : nil;
                    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
                    sd.supportArgumentBuffers = YES;
                    sd.minFilter = sd.magFilter =
                        i & 1 ? MTLSamplerMinMagFilterLinear :
                                MTLSamplerMinMagFilterNearest;
                    id<MTLSamplerState> sampler =
                        [commands.device newSamplerStateWithDescriptor:sd];
                    assert(sampler);
                    if (kind) {
                        u.combiner.shader_stage_program =
                            kind == 1 ? PS_TEXTUREMODES_PROJECT2D :
                            kind == 2 ? PS_TEXTUREMODES_PROJECT3D :
                                        PS_TEXTUREMODES_CUBEMAP;
                        u.textures[0].dimension = kind == 2 ? 3 : 2;
                        u.textures[0].cubemap = kind == 3;
                        bindings[0] =
                            (NV2AMetalPixelTexture){ source, sampler };
                    }
                    if (deferred) {
                        NV2AMetalPixelDraw *packet =
                            [shader prepareGeometry:g
                                              offset:0
                                               count:6
                                            uniforms:&u
                                            textures:bindings
                                                pass:pass
                                           drawState:state
                                         rasterClass:NV2AMetalPixelRasterNative
                                ignorePolygonCulling:NO
                                            commands:commands
                                               error:&error];
                        require(packet != nil, error);
                        [packets addObject:packet];
                        last = packet;
                        memset(&u, 0xa5, sizeof(u));
                        memset(bindings, 0, sizeof(bindings));
                        /* Later captures are different; retain no
                         * source/sampler here. The command recording must own
                         * every GPU input. */
                        source = nil;
                        sampler = nil;
                    } else {
                        require(
                            [shader encodeGeometry:g
                                              offset:0
                                               count:6
                                            uniforms:&u
                                            textures:bindings
                                                pass:pass
                                           drawState:state
                                         rasterClass:NV2AMetalPixelRasterNative
                                ignorePolygonCulling:NO
                                       renderEncoder:nil
                                            commands:commands
                                               error:&error],
                            error);
                        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                        pass.visibilityResultType =
                            MTLVisibilityResultTypeAccumulate;
                    }
                }
            }
            if (deferred) {
                /* Rejected late preparations cannot alter the ready packets.
                 * No raster encoder has been opened at this point. */
                NV2AMetalPixelUniforms invalid = uniforms();
                NV2AMetalPixelTexture bindings[4] = { 0 };
                NV2AMetalDrawConfig config = { 0 };
                NV2AMetalDrawState *state =
                    [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                        config:&config
                                                         error:&error];
                require(state != nil, error);
                for (unsigned bad = 0; bad < 3; bad++) {
                    error = nil;
                    invalid = uniforms();
                    if (bad == 1)
                        invalid.surface_scale[0] = 0;
                    assert(![shader prepareGeometry:g
                                             offset:bad == 0 ? 1 : 0
                                              count:bad == 2 ? 7 : 6
                                           uniforms:&invalid
                                           textures:bindings
                                               pass:pass
                                          drawState:state
                                        rasterClass:NV2AMetalPixelRasterNative
                               ignorePolygonCulling:NO
                                           commands:commands
                                              error:&error] &&
                           error);
                    rejected++;
                }
                NV2AMetalPixelUniforms u = uniforms();
                error = nil;
                NV2AMetalPixelDraw *empty =
                    [shader prepareGeometry:g
                                      offset:0
                                       count:0
                                    uniforms:&u
                                    textures:bindings
                                        pass:pass
                                   drawState:state
                                 rasterClass:NV2AMetalPixelRasterNative
                        ignorePolygonCulling:NO
                                    commands:commands
                                       error:&error];
                require(empty != nil && !empty.vertexCount, error);
                id<MTL4RenderCommandEncoder> e = [commands.commandBuffer
                    renderCommandEncoderWithDescriptor:pass];
                assert(e);
                [e barrierAfterQueueStages:MTLStageAll
                              beforeStages:nv2a_metal_pixel_pass_stages()
                         visibilityOptions:MTL4VisibilityOptionDevice];
                [e setVisibilityResultMode:MTLVisibilityResultModeCounting
                                    offset:0];
                if (old) {
                    error = nil;
                    assert(![old encodeWithRenderEncoder:e
                                                commands:commands
                                                   error:&error] &&
                           error);
                    rejected++;
                }
                require([empty encodeWithRenderEncoder:e
                                              commands:commands
                                                 error:&error],
                        error);
                for (NV2AMetalPixelDraw *packet in packets)
                    require([packet encodeWithRenderEncoder:e
                                                   commands:commands
                                                      error:&error],
                            error);
                [e barrierAfterStages:nv2a_metal_pixel_pass_stages()
                    beforeQueueStages:MTLStageAll
                    visibilityOptions:MTL4VisibilityOptionDevice];
                [e endEncoding];
                old = packets[0];
            }
            id<MTLBuffer> image = packet_read(commands, color);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            uint64_t samples = *(uint64_t *)query.contents;
            assert(samples == (scene == 3 ? 128u : 256u));
            for (unsigned y = 0; y < 8; y++) {
                const uint8_t *row = (const uint8_t *)image.contents + y * 256;
                if (deferred)
                    assert(!memcmp(reference[y], row, 32));
                else
                    memcpy(reference[y], row, 32);
            }
            if (!deferred)
                referenceQuery = samples;
            else {
                assert(samples == referenceQuery);
                pairs++;
            }
        }
    }
    /* Cancel/rebegin uses a new identity even if the same command slot is
     * reused. A packet cannot escape into that recording or another queue. */
    NV2AMetalCommands *other =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(other != nil, error);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalGeometryResult *cancelGeometry =
        [geometry encodeVertices:vertices
                           count:6
                       primitive:NV2AMetalPrimitiveTriangles
                         polygon:NV2AMetalPolygonFill
                          smooth:YES
                  firstProvoking:NO
                    zPerspective:NO
                        commands:commands
                           error:&error];
    require(cancelGeometry != nil, error);
    MTL4RenderPassDescriptor *cancelPass = [MTL4RenderPassDescriptor new];
    cancelPass.colorAttachments[0].texture =
        attachment(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    cancelPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    cancelPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    NV2AMetalDrawConfig cancelConfig = { 0 };
    NV2AMetalDrawState *cancelState =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&cancelConfig
                                             error:&error];
    require(cancelState != nil, error);
    NV2AMetalPixelUniforms cancelUniforms = uniforms();
    NV2AMetalPixelTexture cancelBindings[4] = { 0 };
    NV2AMetalPixelDraw *cancelled =
        [shader prepareGeometry:cancelGeometry
                          offset:0
                           count:6
                        uniforms:&cancelUniforms
                        textures:cancelBindings
                            pass:cancelPass
                       drawState:cancelState
                     rasterClass:NV2AMetalPixelRasterNative
            ignorePolygonCulling:NO
                        commands:commands
                           error:&error];
    require(cancelled != nil, error);
    [commands cancel];
    for (unsigned foreign = 0; foreign < 2; foreign++) {
        NV2AMetalCommands *queue = foreign ? other : commands;
        require([queue beginWithError:&error] != nil, error);
        id<MTLTexture> color =
            attachment(queue.device, MTLPixelFormatRGBA8Unorm, 1);
        require([queue addResource:color error:&error], error);
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTL4RenderCommandEncoder> e =
            [queue.commandBuffer renderCommandEncoderWithDescriptor:pass];
        assert(e);
        error = nil;
        assert(![last encodeWithRenderEncoder:e commands:queue error:&error] &&
               error);
        rejected++;
        error = nil;
        assert(![cancelled encodeWithRenderEncoder:e
                                          commands:queue
                                             error:&error] &&
               error);
        rejected++;
        [e endEncoding];
        [queue cancel];
    }
    assert(pairs == 4 && rejected == 19);
    printf(
        "Metal raster packets: %u exact 32-draw color/query pairs, 128 "
        "deferred slices, "
        "2D/3D/cube/constants, logic/blend/scissor, immutable bindings and %u "
        "late-input/stale/foreign rejects PASS; no window\n",
        pairs, rejected);
}
#endif
