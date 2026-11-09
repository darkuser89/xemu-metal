#import <objc/runtime.h>

static void pixel_argument_reuse_test(void)
{
    NSError *error = nil;
    id<MTL4ArgumentTable> table = [shader valueForKey:@"arguments"];
    SEL selectors[] = { @selector(setTexture:atIndex:),
                        @selector(setSamplerState:atIndex:) };
    Method methods[2];
    IMP originals[2], spies[2];
    unsigned writes[2] = { 0 };
    for (unsigned i = 0; i < 2; i++) {
        SEL selector = selectors[i];
        methods[i] = class_getInstanceMethod(object_getClass(table), selector);
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
        void (*original)(id, SEL, MTLResourceID, NSUInteger) =
            (void *)originals[i];
        unsigned *counter = &writes[i];
        spies[i] = imp_implementationWithBlock(
            ^void(id object, MTLResourceID resource, NSUInteger index) {
                if (object == table)
                    (*counter)++;
                original(object, selector, resource, index);
            });
        method_setImplementation(methods[i], spies[i]);
    }
    const float colors[][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 } };
    id<MTLTexture> sampled[2], outputs[4];
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:1 height:1 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    for (unsigned i = 0; i < 2; i++) {
        sampled[i] = [commands.device newTextureWithDescriptor:td];
        assert(sampled[i]);
        [sampled[i] replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                     mipmapLevel:0 withBytes:colors[i] bytesPerRow:16];
    }
    td.width = td.height = 8;
    td.usage = MTLTextureUsageRenderTarget;
    for (unsigned i = 0; i < 4; i++) {
        outputs[i] = [commands.device newTextureWithDescriptor:td];
        assert(outputs[i]);
    }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    id<MTLSamplerState> alternate =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(alternate);
    NV2AMetalVertex vertices[6];
    quad(vertices);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:vertices length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    NV2AMetalPixelUniforms u = uniforms();
    texture_mode(&u, 0, PS_TEXTUREMODES_PROJECT2D);
    show_texture(&u, 0);
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([commands beginWithError:&error] != nil, error);
    for (unsigned i = 0; i < 4; i++) {
        textures[0].texture = sampled[i >= 2];
        textures[0].sampler = i >= 2 ? alternate : nil;
        MTL4RenderPassDescriptor *renderPass = pass();
        renderPass.colorAttachments[0].texture = outputs[i];
        require([shader encodeVertices:input count:6
                              primitive:MTLPrimitiveTypeTriangle uniforms:&u
                               textures:textures pass:renderPass
                           depthStencil:depth_state commands:commands
                                  error:&error], error);
        const unsigned expected[][2] = { { 12, 4 }, { 12, 4 },
                                          { 13, 5 }, { 25, 9 } };
        assert(writes[0] == expected[i][0] && writes[1] == expected[i][1]);
        if (i == 2) {
            require([commands submitWithError:&error], error);
            require([commands beginWithError:&error] != nil, error);
        }
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    for (unsigned i = 0; i < 4; i++) {
        float actual[4];
        [outputs[i] getBytes:actual bytesPerRow:16
                  fromRegion:MTLRegionMake2D(4, 4, 1, 1) mipmapLevel:0];
        assert(!memcmp(actual, colors[i >= 2], sizeof(actual)));
    }
    for (unsigned i = 0; i < 2; i++) {
        method_setImplementation(methods[i], originals[i]);
        assert(imp_removeBlock(spies[i]));
    }
    puts("Metal 4 pixel arguments: unchanged setters skipped, changed texture "
         "and sampler rebound, fresh recording restored, exact pixels PASS");
}

/* Preserve the original float-tag comparisons for public dynamic vertices;
 * fractional/nonfinite values are neither expanded-line tag1 nor polygon tag2.
 */
static void dynamic_raster_tag_tests(void)
{
    NV2AMetalPixelUniforms u = uniforms();
    NV2AMetalPixelTexture textures[4] = { 0 };
    const float tags[] = { 1.25f, 2.25f, -1, NAN, INFINITY };
    for (unsigned i = 0; i < sizeof(tags) / sizeof(*tags); i++) {
        NV2AMetalVertex v[6];
        quad(v);
        for (unsigned k = 0; k < 6; k++)
            v[k].line_raster[2] = tags[i];
        render(&u, v, 6, MTLPrimitiveTypeTriangle, textures);
        color(3, 4, .1f, .2f, .3f, .4f);
        check_depth(depth_at(3, 4), 2.0f / 65535);
    }
    puts("Dynamic float raster tags: fractional/nonfinite values preserve "
         "original native path PASS");
}

/* Geometry class specialization must preserve dynamic coverage, interpolation,
 * clipping and fragment depth. SPDX-License-Identifier: GPL-2.0-or-later */
static void raster_class_tests(void)
{
    NSError *error = nil;
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    require(geometry != nil, error);
    /* Separate caches prevent a dynamic pipeline from hiding a missing class
     * in the specialized instance's key. Prime native, then line/polygon. */
    NV2AMetalPixelShader *dynamicReference =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatDepth32Float
                                         sampleCount:1
                                               error:&error];
    require(dynamicReference != nil, error);
    NV2AMetalDrawConfig config = draw_config();
    config.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                         NV_PGRAPH_CONTROL_0_ZWRITEENABLE | (7u << 16);
    set_draw_state(&config);
    unsigned pairs = 0;
    const unsigned order[] = { 0, 1, 2, 1, 0, 2 };
    for (unsigned scenario = 0; scenario < 6; scenario++) {
        unsigned mode = order[scenario];
        for (unsigned perspective = 0; perspective < 2; perspective++) {
            NV2AMetalVertex v[6];
            quad(v);
            const float xy[3][2] = { { 1, 1 }, { 7, 2 }, { 2, 7 } };
            for (unsigned i = 0; i < 3; i++) {
                float w = perspective ? 1 + .5f * i : 1;
                v[i].clip[0] = (xy[i][0] / 4 - 1) * w;
                v[i].clip[1] = (1 - xy[i][1] / 4) * w;
                v[i].clip[2] = .5f * w;
                v[i].clip[3] = w;
                v[i].screen[0] = xy[i][0];
                v[i].screen[1] = xy[i][1];
                v[i].screen[2] = 1234 + 53 * i;
                v[i].screen[3] = w;
                for (unsigned k = 0; k < 4; k++)
                    v[i].color[0][k] += .07f * i;
            }
            id<MTLBuffer> input = [commands.device
                newBufferWithBytes:v
                            length:sizeof(v)
                           options:MTLResourceStorageModeShared];
            NV2AMetalGeometryRasterConfig c = { .front = NV2AMetalPolygonFill,
                                                .back = NV2AMetalPolygonFill,
                                                .lineWidth =
                                                    mode == 1 ? 2.5f : 1,
                                                .lineSmooth = mode == 1,
                                                .polygonSmooth = mode == 2,
                                                .viewportWidth = 8,
                                                .viewportHeight = 8 };
            require([commands beginWithError:&error] != nil, error);
            NSArray<NV2AMetalGeometryResult *> *results = [geometry
                encodeRasterVertices:input
                               count:mode == 1 ? 2 : 3
                           primitive:mode == 1 ? NV2AMetalPrimitiveLines :
                                                 NV2AMetalPrimitiveTriangles
                              config:&c
                              smooth:YES
                      firstProvoking:YES
                        zPerspective:perspective
                            commands:commands
                               error:&error];
            require(results != nil && results.count == 1, error);
            NV2AMetalGeometryResult *g = results[0];
            assert(g.expandedLines == (mode == 1) &&
                   g.expandedPolygons == (mode == 2));
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            NV2AMetalPixelUniforms u = uniforms();
            u.z_perspective = perspective;
            NV2AMetalPixelTexture textures[4] = { 0 };
            float reference[8][8][4], referenceDepth[8][8];
            for (unsigned path = 0; path < 2; path++) {
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalPixelRasterClass rasterClass =
                    !path     ? NV2AMetalPixelRasterDynamic :
                    mode == 1 ? NV2AMetalPixelRasterExpandedLine :
                    mode == 2 ? NV2AMetalPixelRasterExpandedPolygon :
                                NV2AMetalPixelRasterNative;
                if (!path) {
                    require([dynamicReference encodeVertices:g.vertices
                                                       count:g.vertexCount
                                                   primitive:g.primitiveType
                                                    uniforms:&u
                                                    textures:textures
                                                        pass:pass()
                                                depthStencil:depth_state
                                                    commands:commands
                                                       error:&error],
                            error);
                } else {
                    require([shader encodeVertices:g.vertices
                                              offset:0
                                               count:g.vertexCount
                                           primitive:g.primitiveType
                                            uniforms:&u
                                            textures:textures
                                                pass:pass()
                                           drawState:draw_state
                                         rasterClass:rasterClass
                                ignorePolygonCulling:mode != 0
                                            commands:commands
                                               error:&error],
                            error);
                }
                read_depth();
                require([commands submitWithError:&error], error);
                require([commands waitUntilIdleWithError:&error], error);
                [target getBytes:pixels
                     bytesPerRow:sizeof(pixels[0])
                      fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                     mipmapLevel:0];
                draws++;
                if (!path) {
                    memcpy(reference, pixels, sizeof(reference));
                    for (unsigned y = 0; y < 8; y++)
                        for (unsigned x = 0; x < 8; x++)
                            referenceDepth[y][x] = depth_at(x, y);
                } else {
                    unsigned visible = 0;
                    for (unsigned y = 0; y < 8; y++)
                        for (unsigned x = 0; x < 8; x++) {
                            for (unsigned k = 0; k < 4; k++)
                                check(pixels[y][x][k], reference[y][x][k]);
                            check_depth(depth_at(x, y), referenceDepth[y][x]);
                            visible += pixels[y][x][0] != clear_color[0];
                        }
                    assert(visible > 0);
                }
            }
            pairs++;
        }
    }
    draw_state = nil;
    assert(pairs == 12);
    printf(
        "Raster-class specialization: 12 dynamic/native/expanded-line/polygon "
        "GPU pairs, alternating keys and W-depth PASS\n");
}
