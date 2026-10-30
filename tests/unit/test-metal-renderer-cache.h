/* Renderer-cache pressure with native Metal4 work retained across eviction.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RENDERER_CACHE_H
#define TEST_METAL_RENDERER_CACHE_H
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
@interface NV2AMetalPGRAPHDraw (RendererCacheTest)
- (NV2AMetalPixelShader *)pixelForColor:(MTLPixelFormat)color
                                  depth:(MTLPixelFormat)depth
                                  error:(NSError **)error;
@end
static const unsigned renderer_sizes[] = { 0, 2, 2, 2, 4, 4, 4, 4, 4, 1, 2 };
static const uint32_t renderer_green[] = { 0,          0x03e0,     0x83e0,
                                           0x07e0,     0x0000ff00, 0xff00ff00,
                                           0x7f00ff00, 0xff00ff00, 0xff00ff00,
                                           0,          0xff00 };
static NV2AMetalPixelShader *renderer_select(unsigned format,
                                             MTLPixelFormat depth)
{
    NSError *error = nil;
    state->pgraph.surface_shape.color_format = format;
    state->pgraph.surface_color.pitch = renderer_sizes[format] * 8;
    require([surfaces prepareColor:YES zeta:NO error:&error], error);
    NV2AMetalPixelShader *pixel =
        [draw pixelForColor:surfaces.color.transfer.texture.pixelFormat
                      depth:depth
                      error:&error];
    require(pixel != nil, error);
    return pixel;
}
static id<MTLTexture> renderer_attachment(id<MTLDevice> device,
                                          MTLPixelFormat format, BOOL depth)
{
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    td.storageMode = depth ? MTLStorageModePrivate : MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    assert(texture);
    return texture;
}
static void renderer_encode(NV2AMetalPixelShader *pixel,
                            NV2AMetalCommands *commands, id<MTLBuffer> vertices,
                            id<MTLBuffer> query, NV2AMetalDrawState *raster,
                            unsigned format, MTLPixelFormat depth,
                            NSMutableArray *outputs)
{
    NSError *error = nil;
    MTLPixelFormat color = surfaces.color.transfer.texture.pixelFormat;
    id<MTLTexture> texture = renderer_attachment(commands.device, color, NO);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, .25);
    if (depth != MTLPixelFormatInvalid) {
        pass.depthAttachment.texture =
            renderer_attachment(commands.device, depth, YES);
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 1;
        if (depth == MTLPixelFormatDepth32Float_Stencil8) {
            pass.stencilAttachment.texture = pass.depthAttachment.texture;
            pass.stencilAttachment.loadAction = MTLLoadActionClear;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    }
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = 1;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 8;
    u.depth_format = NV2AMetalPixelDepthD24;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
    }
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([pixel encodeVertices:vertices
                            count:6
                        primitive:MTLPrimitiveTypeTriangle
                         uniforms:&u
                         textures:textures
                             pass:pass
                        drawState:raster
                         commands:commands
                            error:&error],
            error);
    [outputs addObject:@[ texture, @(format) ]];
}
static void renderer_cache_contract_test(void)
{
    fixture();
    NSError *error = nil;
    NV2AMetalLRUCache *cache = [draw valueForKey:@"pixels"];
    assert([cache isKindOfClass:NV2AMetalLRUCache.class]);
    [cache removeAllObjects];
    uint64_t hits = cache.hitCount, misses = cache.missCount,
             evictions = cache.evictionCount;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(commands != nil, error);
    NV2AMetalVertex v[6] = { 0 };
    const float xy[6][2] = { { -1, -1 }, { 1, -1 }, { -1, 1 },
                             { 1, -1 },  { 1, 1 },  { -1, 1 } };
    for (unsigned i = 0; i < 6; i++) {
        v[i].clip[0] = xy[i][0];
        v[i].clip[1] = xy[i][1];
        v[i].clip[2] = .5;
        v[i].clip[3] = 1;
        v[i].color[0][1] = v[i].color[0][3] = 1;
        const float plane[3][4] = { { 0, 0, 32768, 1 },
                                    { 8, 0, 32768, 1 },
                                    { 0, 8, 32768, 1 } };
        memcpy(v[i].plane, plane, sizeof(plane));
    }
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    uint64_t zero = 0;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&zero
                                     length:8
                                    options:MTLResourceStorageModeShared];
    assert(vertices && query);
    NV2AMetalDrawConfig config = { 0 };
    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(raster != nil, error);
    NSMutableArray *outputs = [NSMutableArray new];
    NSHashTable *owners = [NSHashTable weakObjectsHashTable];
    __weak NV2AMetalPixelShader *hot = nil;
    __weak NV2AMetalPixelShader *oldest = nil;
    const MTLPixelFormat depths[] = { MTLPixelFormatInvalid,
                                      MTLPixelFormatDepth16Unorm,
                                      MTLPixelFormatDepth32Float,
                                      MTLPixelFormatDepth32Float_Stencil8 };
    NSUInteger maxCached = 0, libraryCountAfterFirst = 0;
    qemu_mutex_lock(&state->pgraph.lock);
    require([commands beginWithError:&error] != nil, error);
    for (unsigned format = 1; format <= 10; format++)
        for (unsigned z = 0; z < 4; z++) {
            @autoreleasepool {
                NV2AMetalPixelShader *pixel =
                    renderer_select(8, MTLPixelFormatInvalid);
                if (!hot)
                    hot = pixel;
                assert(pixel == hot);
                if (format == 1 && z == 0) {
                    id module = [pixel valueForKey:@"sharedLibrary"];
                    id context = [module valueForKey:@"context"];
                    libraryCountAfterFirst =
                        [[context valueForKey:@"libraryBuildCount"]
                            unsignedIntegerValue];
                }
                [owners addObject:pixel];
                renderer_encode(pixel, commands, vertices, query, raster, 8,
                                MTLPixelFormatInvalid, outputs);
                pixel = renderer_select(format, depths[z]);
                if (format == 1 && z == 0)
                    oldest = pixel;
                [owners addObject:pixel];
                renderer_encode(pixel, commands, vertices, query, raster,
                                format, depths[z], outputs);
                maxCached = MAX(maxCached, cache.count);
                assert(cache.count <= 32);
            }
        }
    /* Revisit the newest 16 format states. All must survive the capacity
     * crossing, including entries that a whole-cache reset would discard. */
    for (unsigned format = 7; format <= 10; format++)
        for (unsigned z = 0; z < 4; z++) {
            @autoreleasepool {
                uint64_t previousMisses = cache.missCount;
                NV2AMetalPixelShader *pixel =
                    renderer_select(format, depths[z]);
                assert(cache.missCount == previousMisses);
                renderer_encode(pixel, commands, vertices, query, raster,
                                format, depths[z], outputs);
            }
        }
    /* Weak loads and weak-table enumeration can create autoreleased strong
     * temporaries. Drain those test observations before checking retirement. */
    @autoreleasepool {
        assert(cache.count == 32 && maxCached == 32 &&
               owners.allObjects.count == 40 && hot && oldest);
    }
    assert(cache.hitCount - hits == 56 && cache.missCount - misses == 40 &&
           cache.evictionCount - evictions == 8);
    unsigned pipelineMisses = 0, pipelineHits = 0;
    @autoreleasepool {
        for (NV2AMetalPixelShader *pixel in owners) {
            NV2AMetalLRUCache *pipeline =
                [pixel valueForKey:@"fragmentPipelines"];
            pipelineMisses += pipeline.missCount;
            pipelineHits += pipeline.hitCount;
        }
    }
    assert(pipelineMisses == 40 && pipelineHits == 56);
    @autoreleasepool {
        NV2AMetalShaderLibrary *pixelModule =
            [hot valueForKey:@"sharedLibrary"];
        NV2AMetalSurfaceTransfer *transfer = surfaces.color.transfer;
        assert(![transfer valueForKey:@"sharedLibrary"] &&
               ![transfer valueForKey:@"arguments"]);
        id context = [pixelModule valueForKey:@"context"];
        /* Prior tests may have released an older library. No further library
         * request is allowed across this trace's forty renderer variants. */
        assert(libraryCountAfterFirst >= 1 &&
               [[context valueForKey:@"libraryBuildCount"]
                   unsignedIntegerValue] == libraryCountAfterFirst);
        NV2AMetalShaderLibrary *priorSurfaceModule = nil;
        NSMapTable *modules = [context valueForKey:@"modules"];
        for (NV2AMetalShaderLibrary *module in modules.objectEnumerator) {
            if ([module.library.functionNames
                    containsObject:@"nv2a_surface_upload"]) {
                assert(!priorSurfaceModule);
                priorSurfaceModule = module;
            }
        }
        NSUInteger priorBuilds = [[priorSurfaceModule
            valueForKey:@"computeBuildCount"] unsignedIntegerValue];
        id priorDownload = [[priorSurfaceModule valueForKey:@"compute"]
            objectForKey:@"nv2a_surface_download_color"];
        id<MTLBuffer> readback =
            [commands.device newBufferWithLength:transfer.sourceLength
                                         options:MTLResourceStorageModeShared];
        assert(readback);
        require([transfer encodeDownloadToBuffer:readback
                                          offset:0
                                         swizzle:NO
                                            flip:YES
                                       downscale:YES
                                        commands:surfaces.cache.commands
                                           error:&error],
                error);
        require([surfaces.cache submitWithError:&error] &&
                    [surfaces.cache waitUntilIdleWithError:&error],
                error);
        NV2AMetalShaderLibrary *surfaceModule =
            [transfer valueForKey:@"sharedLibrary"];
        assert(surfaceModule && pixelModule != surfaceModule &&
               pixelModule.compiler == surfaceModule.compiler);
        assert(!priorSurfaceModule || surfaceModule == priorSurfaceModule);
        assert(
            [[context valueForKey:@"libraryBuildCount"] unsignedIntegerValue] ==
            libraryCountAfterFirst + !priorSurfaceModule);
        assert(![transfer valueForKey:@"upload"] &&
               [transfer valueForKey:@"download"] &&
               [transfer valueForKey:@"arguments"]);
        assert([[surfaceModule valueForKey:@"computeBuildCount"]
                   unsignedIntegerValue] == priorBuilds + !priorDownload);
        if (priorDownload)
            assert([transfer valueForKey:@"download"] == priorDownload);
        NSMutableSet *arguments = [NSMutableSet new];
        for (NV2AMetalPixelShader *pixel in owners) {
            assert([pixel valueForKey:@"sharedLibrary"] == pixelModule);
            [arguments addObject:[pixel valueForKey:@"arguments"]];
        }
        assert(arguments.count == 40);
    }
    /* Invalid construction must neither clear nor evict an existing entry. */
    assert(![draw pixelForColor:MTLPixelFormatRGBA16Float
                          depth:MTLPixelFormatInvalid
                          error:&error] &&
           error);
    assert(cache.count == 32 && cache.evictionCount - evictions == 8);
    error = nil;
    @autoreleasepool {
        assert(renderer_select(8, MTLPixelFormatInvalid) == hot);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    @autoreleasepool {
        assert(!oldest && hot && owners.allObjects.count == 32);
    }
    assert(*(uint64_t *)query.contents == 96 * 64);
    unsigned pixels = 0;
    for (NSArray *entry in outputs) {
        id<MTLTexture> texture = entry[0];
        unsigned format = [entry[1] unsignedIntValue];
        unsigned bytes = renderer_sizes[format];
        uint8_t data[256];
        [texture getBytes:data
              bytesPerRow:8 * bytes
               fromRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0];
        for (unsigned i = 0; i < 64; i++) {
            uint32_t word = 0;
            memcpy(&word, data + i * bytes, bytes);
            assert(word == renderer_green[format]);
            pixels++;
        }
    }
    /* Recreate an evicted entry, then clear while it owns unsubmitted work. */
    __weak NV2AMetalPixelShader *recreated = nil;
    @autoreleasepool {
        NV2AMetalPixelShader *pixel = renderer_select(1, MTLPixelFormatInvalid);
        recreated = pixel;
        assert(cache.missCount - misses == 42 &&
               cache.evictionCount - evictions == 9);
        require([commands beginWithError:&error] != nil, error);
        renderer_encode(pixel, commands, vertices, query, raster, 1,
                        MTLPixelFormatInvalid, outputs);
        [cache removeAllObjects];
    }
    @autoreleasepool {
        assert(recreated && !hot && cache.count == 0 &&
               owners.allObjects.count == 0);
    }
    [commands cancel];
    assert(!recreated);
    qemu_mutex_unlock(&state->pgraph.lock);
    printf(
        "Metal renderer cache: 40 format/depth variants, 56 renderer hits, "
        "8 selective evictions, peak32 cached/40 recording-retained; 40 "
        "complete pipeline builds and56 pipeline hits; %u exact "
        "color pixels/6144 GPU samples; failed construction, evicted "
        "recreation, completion/clear/cancel lifetime; one shared compiler, "
        "transfer library/one pipeline on first compute use,40 private "
        "argument tables PASS\n",
        pixels);
    groups++;
}
#endif
