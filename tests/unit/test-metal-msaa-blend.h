/* Independent per-sample blend/resolve oracle. No emulator or window.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_MSAA_BLEND_H
#define TEST_METAL_MSAA_BLEND_H

static void msaa_blend_oracle(void)
{
    NSError *error = nil;
    unsigned frames = 0, partial = 0;
    uint64_t samplesChecked = 0;
    for (unsigned samples = 1; samples <= 4; samples *= 2) {
        assert([commands.device supportsTextureSampleCount:samples]);
        MTLSamplePosition positions[4];
        [commands.device getDefaultSamplePositions:positions count:samples];
        NV2AMetalPixelShader *shader = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA8Unorm
               depthFormat:MTLPixelFormatInvalid
               sampleCount:samples
                     error:&error];
        require(shader != nil, error);
        NV2AMetalDrawConfig config = {
            .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                             NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                             NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                             NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE,
                         0, 0 },
            .blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8
        };
        NV2AMetalDrawState *state =
            [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                config:&config
                                                 error:&error];
        require(state != nil, error);
        for (unsigned variant = 0; variant < 16; variant++) {
            @autoreleasepool {
                unsigned reverse = variant & 1, passthru = (variant >> 1) & 1;
                /* The last triangle's hypotenuse misses all default sample
                 * positions. The first two triangles cover the full target. */
                const float xy[9][2] = { { 0, 0 },      { 32, 0 },
                                         { 0, 32 },     { 32, 0 },
                                         { 32, 32 },    { 0, 32 },
                                         { 0, 0 },      { 31.875f, 0 },
                                         { 0, 31.875f } };
                NV2AMetalVertex vertices[9] = { 0 };
                for (unsigned i = 0; i < 9; i++) {
                    NV2AMetalVertex *v = &vertices[i];
                    v->clip[0] = xy[i][0] / 16 - 1;
                    v->clip[1] = 1 - xy[i][1] / 16;
                    v->clip[2] = .5f;
                    v->clip[3] = v->screen[3] = 1;
                    v->screen[0] = xy[i][0];
                    v->screen[1] = xy[i][1];
                    v->screen[2] = 32768;
                    v->face = NV2AMetalFaceFront;
                    v->point_size = 1;
                    v->color[0][(i >= 6) ^ reverse] = 1;
                    v->color[0][3] = .5f;
                    memcpy(v->texcoord[3], v->color[0], sizeof(v->color[0]));
                    for (unsigned row = 0; row < 3; row++) {
                        v->plane[row][0] = xy[i / 3 * 3 + row][0];
                        v->plane[row][1] = xy[i / 3 * 3 + row][1];
                        v->plane[row][2] = 32768;
                        v->plane[row][3] = 1;
                    }
                }
                id<MTLBuffer> input = [commands.device
                    newBufferWithBytes:vertices
                                length:sizeof(vertices)
                               options:MTLResourceStorageModeShared];
                uint64_t initial = 7;
                id<MTLBuffer> query = [commands.device
                    newBufferWithBytes:&initial
                                length:sizeof(initial)
                               options:MTLResourceStorageModeShared];
                id<MTLTexture> color =
                    texture(MTLPixelFormatRGBA8Unorm, samples);
                id<MTLTexture> resolve =
                    samples == 1 ? color : texture(MTLPixelFormatRGBA8Unorm, 1);
                assert(input && query);
                begin();
                require([commands addResource:color error:&error] &&
                            [commands addResource:resolve error:&error] &&
                            [commands addResource:query error:&error],
                        error);
                MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
                pass.colorAttachments[0].texture = color;
                pass.colorAttachments[0].resolveTexture =
                    samples == 1 ? nil : resolve;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor =
                    MTLClearColorMake(0, 0, 0, 0);
                pass.colorAttachments[0].storeAction =
                    samples == 1 ? MTLStoreActionStore :
                                   MTLStoreActionMultisampleResolve;
                pass.visibilityResultBuffer = query;
                pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
                id<MTL4RenderCommandEncoder> e = [commands.commandBuffer
                    renderCommandEncoderWithDescriptor:pass];
                assert(e);
                [e barrierAfterQueueStages:MTLStageAll
                              beforeStages:MTLStageAll
                         visibilityOptions:MTL4VisibilityOptionDevice];
                [e setVisibilityResultMode:MTLVisibilityResultModeCounting
                                    offset:0];
                NV2AMetalPixelUniforms u = { 0 };
                u.smooth_shading = 1;
                u.combiner.final_inputs[0] =
                    passthru ? PS_REGISTER_T3 : PS_REGISTER_V0;
                u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                             << 8;
                u.combiner.shader_stage_program =
                    passthru ? PS_TEXTUREMODES_PASSTHRU << 15 : 0;
                u.surface_scale[0] = u.surface_scale[1] = 1;
                u.depth_format = NV2AMetalPixelDepthD16;
                u.clip_range[1] = u.clip_range[3] = 65535;
                u.clip_regions[0][2] = u.clip_regions[0][3] = 32;
                NV2AMetalPixelTexture bindings[4] = { 0 };
                for (unsigned draw = 0; draw < 2; draw++)
                    require([shader encodeVertices:input
                                              offset:draw * 6 *
                                                     sizeof(NV2AMetalVertex)
                                               count:draw ? 3 : 6
                                           primitive:MTLPrimitiveTypeTriangle
                                            uniforms:&u
                                            textures:bindings
                                                pass:pass
                                           drawState:state
                                         rasterClass:NV2AMetalPixelRasterNative
                                ignorePolygonCulling:NO
                                       renderEncoder:e
                                            commands:commands
                                               error:&error],
                            error);
                [e barrierAfterStages:MTLStageAll
                    beforeQueueStages:MTLStageAll
                    visibilityOptions:MTL4VisibilityOptionDevice];
                [e endEncoding];
                id<MTLBuffer> image = read_texture(resolve, MTLBlitOptionNone);
                finish();
                uint64_t covered = 0;
                for (unsigned y = 0; y < 32; y++) {
                    const uint8_t *row =
                        (const uint8_t *)image.contents + y * 256;
                    for (unsigned x = 0; x < 32; x++) {
                        unsigned k = 0;
                        for (unsigned s = 0; s < samples; s++) {
                            float sum = x + positions[s].x + y + positions[s].y;
                            assert(sum != 31.875f);
                            k += sum < 31.875f;
                        }
                        covered += k;
                        partial += k && k < samples;
                        /* UNorm8 values after each draw: (128,0,0,64),
                         * then (64,128,0,96) in each newly covered sample.
                         * Resolve is their arithmetic mean; all expectations
                         * are exact integers at 1/2/4 samples, no tolerance. */
                        uint8_t expected[4] = {
                            0, 0, 0, (k * 96 + (samples - k) * 64) / samples
                        };
                        expected[reverse] =
                            (k * 64 + (samples - k) * 128) / samples;
                        expected[!reverse] = k * 128 / samples;
                        if (memcmp(row + x * 4, expected, 4)) {
                            fprintf(stderr,
                                    "MSAA blend oracle samples%u variant%u "
                                    "pixel%u,%u covered%u: %u,%u,%u,%u "
                                    "expected %u,%u,%u,%u\n",
                                    samples, variant, x, y, k, row[x * 4],
                                    row[x * 4 + 1], row[x * 4 + 2],
                                    row[x * 4 + 3], expected[0], expected[1],
                                    expected[2], expected[3]);
                            abort();
                        }
                    }
                    for (unsigned i = 128; i < 256; i++)
                        assert(row[i] == 0xcd);
                }
                assert(*(uint64_t *)query.contents ==
                       initial + 1024 * samples + covered);
                samplesChecked += 1024 * samples + covered;
                frames++;
            }
        }
    }
    assert(frames == 48 && partial);
    printf("Metal4 blend oracle:48 exact RGBA8 frames/49152 pixels at1/2/4 "
           "samples,two color orders,V0/T3,per-sample coverage/resolve,write "
           "padding; %u partial pixels/%llu counted samples PASS\n",
           partial, (unsigned long long)samplesChecked);
}

#endif
