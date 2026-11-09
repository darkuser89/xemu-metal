/* Never comparisons keep raster side effects but need no visibility slot.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_NEVER_SAMPLE_QUERY_H
#define TEST_METAL_NEVER_SAMPLE_QUERY_H
static BOOL nq_missing;
static BOOL (*nq_surface_original)(id, SEL, BOOL, BOOL, BOOL, BOOL, NSError **);
static BOOL nq_surface(id owner, SEL selector, BOOL color, BOOL zeta,
                       BOOL rendering, BOOL select, NSError **error)
{
    /* A boundary fixture omits the real depth attachment through the normal
     * preparation implementation. No framebuffer/readonly ivars are forged. */
    return nq_surface_original(owner, selector, color,
                               owner == surfaces && nq_missing ? NO : zeta,
                               rendering, select, error);
}
static NSData *nq_pgraph(unsigned mode, unsigned aa, unsigned scale,
                         unsigned program, BOOL reference)
{
    nq_missing = NO;
    pm_scene(0, 0, 0, program, YES, 0, 0);
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_SETUPRASTER] &=
        ~(NV_PGRAPH_SETUPRASTER_CULLENABLE | (3u << 21));
    pg->surface_shape.anti_aliasing = aa;
    pg->surface_scale_factor = scale;
    unsigned width = aa ? 16 : 8, height = aa ? 16 : 8;
    NSUInteger length = width * height * 4;
    pg->surface_color.pitch = pg->surface_zeta.pitch = width * 4;
    cpu_write(1024, length);
    cpu_write(4096, length);
    for (unsigned i = 0; i < width * height; i++) {
        uint32_t red = UINT32_C(0xffff0000), zeta = UINT32_C(0xffffff11);
        memcpy(state->vram_ptr + 1024 + i * 4, &red, 4);
        memcpy(state->vram_ptr + 4096 + i * 4, &zeta, 4);
    }
    pg->regs_[NV_PGRAPH_CONTROL_0] &=
        ~(NV_PGRAPH_CONTROL_0_ALPHATESTENABLE | NV_PGRAPH_CONTROL_0_ALPHAFUNC |
          NV_PGRAPH_CONTROL_0_ZFUNC);
    pg->regs_[NV_PGRAPH_CONTROL_0] |= 7u << 16;
    pg->regs_[NV_PGRAPH_CONTROL_1] &= ~NV_PGRAPH_CONTROL_1_STENCIL_FUNC;
    pg->regs_[NV_PGRAPH_CONTROL_1] |= 7u << 4;
    /* Replace on either fail path makes the zero-count side effect visible. */
    pg->regs_[NV_PGRAPH_CONTROL_2] = 3 | 3 << 4 | 1 << 8;
    if (mode == 0 || mode == 9)
        pg->regs_[NV_PGRAPH_CONTROL_0] |=
            NV_PGRAPH_CONTROL_0_ALPHATESTENABLE | (mode == 9 ? 7u << 8 : 0);
    if (mode == 1 || mode == 4 || mode == 6)
        pg->regs_[NV_PGRAPH_CONTROL_0] &= ~NV_PGRAPH_CONTROL_0_ZFUNC;
    if (mode == 2 || mode == 5 || mode == 7 || mode == 8)
        pg->regs_[NV_PGRAPH_CONTROL_1] &= ~NV_PGRAPH_CONTROL_1_STENCIL_FUNC;
    if (mode == 4)
        pg->regs_[NV_PGRAPH_CONTROL_0] &= ~NV_PGRAPH_CONTROL_0_ZENABLE;
    if (mode == 5)
        pg->regs_[NV_PGRAPH_CONTROL_1] &=
            ~NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE;
    if (mode == 7) {
        pg->surface_shape.zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z16;
        pg->surface_zeta.pitch = width * 2;
        memset(state->vram_ptr + 4096, 0xff, length);
    }
    nq_missing = mode == 6 || mode == 8;
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:surfaces.cache
                                      counterCapacity:1];
    assert(reports);
    [draw setValue:reports forKey:@"reports"];
    zs_reset(reference);
    require([draw drawWithError:&error], error);
    assert(pg->draw_time == 1 && zs_prepares);
    if (mode == 6 || mode == 8)
        assert(!surfaces.zeta);
    if (mode == 7)
        assert(surfaces.zeta.transfer.nativePixelFormat ==
               MTLPixelFormatDepth16Unorm);
    require([reports getReport:1u << 24 error:&error] &&
                [reports processWithError:&error],
            error);
    uint32_t count = report_value(0);
    BOOL zero = mode < 3;
    assert(zero ? !count : count != 0);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, length);
    read_vram(4096, length);
    unsigned changedStencil = 0, changedColor = 0;
    for (unsigned i = 0; i < width * height; i++) {
        uint32_t color, zeta;
        memcpy(&color, state->vram_ptr + 1024 + i * 4, 4);
        memcpy(&zeta, state->vram_ptr + 4096 + i * 4, 4);
        changedColor += color != UINT32_C(0xffff0000);
        changedStencil += (zeta & 255) != 0x11;
        if (mode == 1 || mode == 2)
            assert((zeta & 255) == 0x11 || (zeta & 255) == 0x5a);
    }
    if (zero)
        assert(!changedColor);
    else
        assert(changedColor);
    if (mode == 1 || mode == 2)
        assert(changedStencil); /* Real depth-fail/stencil-fail writes. */
    if (mode == 0)
        assert(!changedStencil); /* Fragment discard preserves stencil. */
    NSMutableData *actual = [cpp_capture(count) mutableCopy];
    [actual appendBytes:state->vram_ptr + 1024 length:length];
    [actual appendBytes:state->vram_ptr + 4096 length:length];
    /* GPU byte/count comparisons above precede counter-selection metadata. */
    assert(zs_zero == (!reference && zero) &&
           zs_physical == (reference || !zero));
    nq_missing = NO;
    return actual;
}
static id<MTLTexture> nq_texture(id<MTLDevice> device, MTLPixelFormat format,
                                 NSUInteger samples)
{
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    descriptor.textureType =
        samples == 1 ? MTLTextureType2D : MTLTextureType2DMultisample;
    descriptor.sampleCount = samples;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [device newTextureWithDescriptor:descriptor];
}
static NSData *nq_msaa(unsigned mode, BOOL reference)
{
    NSError *error = nil;
    id<MTLDevice> device = surfaces.cache.commands.device;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands && [commands beginWithError:&error], error);
    NV2AMetalVertex input[3] = { 0 };
    const float xy[3][2] = { { -.8f, -.8f }, { .8f, -.8f }, { -.8f, .8f } };
    for (unsigned v = 0; v < 3; v++) {
        input[v].clip[0] = xy[v][0];
        input[v].clip[1] = xy[v][1];
        input[v].clip[3] = 1;
        input[v].screen[0] = (xy[v][0] + 1) * 4;
        input[v].screen[1] = (xy[v][1] + 1) * 4;
        input[v].screen[2] = 32768;
        input[v].screen[3] = 1;
        for (unsigned c = 0; c < 4; c++)
            input[v].color[c][1] = input[v].color[c][3] = 1;
    }
    id<MTLBuffer> vertices =
        [device newBufferWithBytes:input
                            length:sizeof(input)
                           options:MTLResourceStorageModeShared];
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:device error:&error];
    NV2AMetalGeometryRasterConfig config = { .viewportWidth = 8,
                                             .viewportHeight = 8 };
    NSArray<NV2AMetalGeometryResult *> *results =
        [geometry encodeNativeRasterVertices:vertices
                                       count:3
                                   primitive:NV2AMetalPrimitiveTriangles
                                      config:&config
                                      smooth:YES
                              firstProvoking:NO
                                zPerspective:NO
                                    commands:commands
                                       error:&error];
    require(results.count == 1, error);
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatDepth32Float
                                         sampleCount:4
                                               error:&error];
    require(pixel != nil, error);
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 65535, 0, 65535 },
                                 .clip_regions = { { 0, 0, 8, 8 } },
                                 .surface_scale = { 1, 1 },
                                 .depth_format = NV2AMetalPixelDepthD16,
                                 .alpha_test = mode == 0,
                                 .alpha_func = ALPHA_FUNC_NEVER };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalDrawConfig raster = { 0 };
    raster.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ZENABLE |
                        (mode == 1 ? 0 : 7u << 16);
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:device
                                            config:&raster
                                             error:&error];
    id<MTLTexture> target = nq_texture(device, MTLPixelFormatRGBA8Unorm, 4);
    id<MTLTexture> resolve = nq_texture(device, MTLPixelFormatRGBA8Unorm, 1);
    id<MTLTexture> depth = nq_texture(device, MTLPixelFormatDepth32Float, 4);
    uint64_t initial = 0;
    id<MTLBuffer> query =
        [device newBufferWithBytes:&initial
                            length:8
                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [device newBufferWithLength:2048 options:MTLResourceStorageModeShared];
    require(state && target && resolve && depth && query && output &&
                [commands addResource:query error:&error] &&
                [commands addResource:output error:&error],
            error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].resolveTexture = resolve;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    NV2AMetalGeometryResult *g = results[0];
    NV2AMetalPixelDraw *packet =
        [pixel prepareGeometry:g
                          offset:0
                           count:g.vertexCount
                        uniforms:&u
                        textures:bindings
                            pass:pass
                       drawState:state
                     rasterClass:NV2AMetalPixelRasterDirectTriangle |
                                 g.directTriangleOptions
            ignorePolygonCulling:NO
                        commands:commands
                           error:&error];
    require(packet != nil, error);
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    require(encoder != nil, nil);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setVisibilityResultMode:reference || mode == 2 ?
                                         MTLVisibilityResultModeCounting :
                                         MTLVisibilityResultModeDisabled
                              offset:0];
    require([packet encodeWithRenderEncoder:encoder
                                   commands:commands
                                      error:&error],
            error);
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
    [copy copyFromTexture:resolve
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:output
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0];
    [copy barrierAfterStages:MTLStageBlit
           beforeQueueStages:MTLStageAll
           visibilityOptions:MTL4VisibilityOptionDevice];
    [copy endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    uint64_t count;
    memcpy(&count, query.contents, 8);
    assert(mode == 2 ? count != 0 : count == 0);
    NSMutableData *actual = [NSMutableData data];
    unsigned changed = 0;
    for (unsigned y = 0; y < 8; y++) {
        const uint32_t *row =
            (const uint32_t *)((const uint8_t *)output.contents + y * 256);
        for (unsigned x = 0; x < 8; x++)
            changed += row[x] != UINT32_C(0xff0000ff); /* RGBA red. */
        [actual appendBytes:row length:32];
    }
    assert(mode == 2 ? changed != 0 : changed == 0);
    [actual appendBytes:&count length:8];
    return actual;
}
static void never_sample_query_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalPGRAPHDraw.class,
                                @selector(hasNoRasterSamplesForPrimitive:raster:
                                          geometry:uniforms:width:height:)),
        class_getInstanceMethod(NV2AMetalPGRAPHReports.class,
                                @selector(allocateCounterWithError:)),
        class_getInstanceMethod(NV2AMetalPGRAPHReports.class,
                                @selector(allocateZeroSampleCounterWithError:)),
        class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            @selector(
                prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                rasterClass:ignorePolygonCulling:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHSurfaces.class,
            sel_registerName(
                "prepareColor:zeta:forRendering:selectingOnly:error:"))
    };
    IMP replacements[] = { (IMP)zs_proof, (IMP)zs_allocate,
                           (IMP)zs_allocate_zero, (IMP)zs_prepare,
                           (IMP)nq_surface },
        originals[5];
    for (unsigned i = 0; i < 5; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    zs_proof_original = (void *)originals[0];
    zs_allocate_original = (void *)originals[1];
    zs_allocate_zero_original = (void *)originals[2];
    zs_prepare_original = (void *)originals[3];
    nq_surface_original = (void *)originals[4];
    for (unsigned i = 0; i < 5; i++)
        method_setImplementation(methods[i], replacements[i]);
    unsigned nativePairs = 0;
    @try {
        for (unsigned aa = 0; aa < 3; aa += 2)
            for (unsigned scale = 1; scale <= 2; scale++)
                for (unsigned mode = 0; mode < 12; mode++) {
                    NSData *reference = nq_pgraph(mode, aa, scale, 1, YES);
                    NSData *actual = nq_pgraph(mode, aa, scale, 1, NO);
                    assert([reference isEqualToData:actual]);
                }
        for (unsigned program = 0; program < 3; program += 2)
            for (unsigned mode = 0; mode < 3; mode++) {
                NSData *reference = nq_pgraph(mode, 0, 1, program, YES);
                NSData *actual = nq_pgraph(mode, 0, 1, program, NO);
                assert([reference isEqualToData:actual]);
            }
        if ([surfaces.cache.commands.device supportsTextureSampleCount:4])
            for (unsigned mode = 0; mode < 3; mode++) {
                NSData *reference = nq_msaa(mode, YES);
                NSData *actual = nq_msaa(mode, NO);
                assert([reference isEqualToData:actual]);
                nativePairs++;
            }
        else
            puts("Never-sample native Metal-MSAA4: unavailable on this device; "
                 "untested");
    } @finally {
        for (unsigned i = 0; i < 5; i++)
            method_setImplementation(methods[i], originals[i]);
        nq_missing = zs_reference = NO;
        zs_last = nil;
    }
    assert(nativePairs ==
           ([surfaces.cache.commands.device supportsTextureSampleCount:4] ?
                3u :
                0u));
    printf(
        "Never-sample native Metal-MSAA4:%u actual GPU pairs "
        "(AlphaNever/DepthNever/Always), physical counting and color resolve\n",
        nativePairs);
    groups += 54 + nativePairs;
    puts("Never-sample queries:54 PGRAPH GPU "
         "framebuffer/zeta/Current/context/query "
         "pairs, NV-AA1/4 x Scale1/2, alpha/depth/stencil Never, real stencil "
         "fail "
         "writes and disabled/missing attachment positive counter controls "
         "PASS");
}
#endif
