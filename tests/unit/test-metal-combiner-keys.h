/* Canonical fragment structure versus the unmodified GPU combiner.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_COMBINER_KEYS_H
#define TEST_METAL_COMBINER_KEYS_H
#import "hw/xbox/nv2a/pgraph/metal/pixel-combiner.h"

static unsigned ck_word(unsigned a, unsigned b, unsigned c, unsigned d)
{
    return a << 24 | b << 16 | c << 8 | d;
}

static NV2AMetalPixelUniforms ck_uniforms(unsigned stages, unsigned family,
                                          unsigned slot, BOOL alpha,
                                          unsigned reg)
{
    NV2AMetalPixelUniforms u = uniforms();
    u.combiner.control = stages;
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PASSTHRU;
    u.combiner.final_inputs[0] = PS_REGISTER_R0;
    u.combiner.final_inputs[1] = (PS_REGISTER_R0 | PS_CHANNEL_ALPHA) << 8;
    for (unsigned i = 0; i < stages; i++) {
        u.combiner.rgb_inputs[i] =
            ck_word(PS_REGISTER_V0, PS_REGISTER_ONE, 0, 0);
        u.combiner.alpha_inputs[i] =
            ck_word(PS_REGISTER_V0 | PS_CHANNEL_ALPHA, PS_REGISTER_ONE, 0, 0);
        u.combiner.rgb_outputs[i] = u.combiner.alpha_outputs[i] =
            PS_REGISTER_R0;
    }
    if (stages) {
        unsigned i = stages - 1;
        if (family == 1 || family == 3)
            u.combiner.rgb_inputs[i] =
                ck_word(PS_REGISTER_C0, PS_REGISTER_ONE, 0, 0);
        if (family == 2 || family == 3)
            u.combiner.alpha_inputs[i] = ck_word(
                PS_REGISTER_C1 | PS_CHANNEL_ALPHA, PS_REGISTER_ONE, 0, 0);
        if (family == 4 || family == 5) {
            for (unsigned k = 0; k < stages; k++)
                u.combiner.alpha_outputs[k] = 0;
            unsigned inputs = ck_word(PS_REGISTER_V0, PS_REGISTER_ONE,
                                      PS_REGISTER_V1, PS_REGISTER_ONE);
            unsigned outputs = PS_REGISTER_R0 << 8 | PS_COMBINEROUTPUT_AB_CD_MUX
                                                         << 12;
            if (family == 4) {
                u.combiner.rgb_inputs[i] = inputs;
                u.combiner.rgb_outputs[i] = outputs;
            } else {
                u.combiner.alpha_inputs[i] = inputs | 0x10101010u;
                u.combiner.alpha_outputs[i] = outputs;
            }
        }
        if (family == 6) {
            unsigned operands[4] = { 0 };
            operands[slot] = reg;
            operands[slot ^ 1] = PS_REGISTER_ONE;
            unsigned inputs =
                ck_word(operands[0], operands[1], operands[2], operands[3]);
            if (alpha) {
                u.combiner.alpha_inputs[i] = inputs | 0x10101010u;
                u.combiner.alpha_outputs[i] = PS_REGISTER_R0 << 8;
            } else {
                u.combiner.rgb_inputs[i] = inputs;
                u.combiner.rgb_outputs[i] = PS_REGISTER_R0 << 8;
            }
        }
    }
    if (family == 7) {
        u.combiner.final_inputs[0] = PS_REGISTER_C0;
        u.combiner.final_inputs[1] = (PS_REGISTER_C1 | PS_CHANNEL_ALPHA) << 8;
    }
    return u;
}

static id<MTLBuffer> ck_read(NV2AMetalCommands *commands, id<MTLTexture> color)
{
    NSError *error = nil;
    id<MTLBuffer> buffer =
        [commands.device newBufferWithLength:8 * 256
                                     options:MTLResourceStorageModeShared];
    require(buffer && [commands addResource:buffer error:&error] &&
                [commands addResource:color error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:color
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:buffer
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return buffer;
}

static void combiner_key_tests(NV2AMetalCommands *commands,
                               id<MTLBuffer> original)
{
    NSError *error = nil;
    NV2AMetalPixelCombiner *reference =
        [[NV2AMetalPixelCombiner alloc] initWithDevice:commands.device
                                                 error:&error];
    id<MTLTexture> color =
        attachment(commands.device, MTLPixelFormatRGBA32Float, 1);
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:color.pixelFormat
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(reference && shader, error);
    NV2AMetalVertex v[6];
    memcpy(v, original.contents, sizeof(v));
    const float diffuse[4] = { .125f, .25f, .375f, .25f };
    const float specular[4] = { .625f, .5f, .75f, .75f };
    const float coordinate[4] = { .125f, .5f, .875f, .375f };
    for (unsigned i = 0; i < 6; i++) {
        memcpy(v[i].color[0], diffuse, sizeof(diffuse));
        memcpy(v[i].color[1], specular, sizeof(specular));
        memcpy(v[i].texcoord[0], coordinate, sizeof(coordinate));
    }
    id<MTLBuffer> vertices =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalDrawConfig config = { 0 };
    config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    NV2AMetalDrawState *raster =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(vertices && raster, error);
    NV2AMetalLRUCache *cache = [shader valueForKey:@"fragmentPipelines"];
    unsigned cases = 0, pipelines = 0, continuous = 0, raw = 0, inactive = 0,
             activationRejects = 0, drawsCompared = 0;
    /* Keep the second sweep's cache across programs: live-word collisions
     * must also be caught by the independent GPU oracle. */
    for (unsigned sweep = 0; sweep < 190; sweep++)
        @autoreleasepool {
            unsigned phase = sweep / 95, test = sweep % 95;
            unsigned stages, family, slot = 0, reg = PS_REGISTER_C0;
            BOOL alpha = NO;
            unsigned needed = 0;
            if (test < 63) {
                stages = test / 7;
                family = test % 7;
                if (family == 6)
                    family = 7;
                if (stages > 1) {
                    if (family == 1 || family == 3)
                        needed |= PS_COMBINERCOUNT_UNIQUE_C0;
                    if (family == 2 || family == 3)
                        needed |= PS_COMBINERCOUNT_UNIQUE_C1;
                }
                if (stages && (family == 4 || family == 5))
                    needed |= PS_COMBINERCOUNT_MUX_MSB;
            } else {
                unsigned n = test - 63;
                stages = n & 1 ? 8 : 2;
                reg = n & 2 ? PS_REGISTER_C1 : PS_REGISTER_C0;
                alpha = !!(n & 4);
                slot = n >> 3;
                family = 6;
                needed = reg == PS_REGISTER_C0 ? PS_COMBINERCOUNT_UNIQUE_C0 :
                                                 PS_COMBINERCOUNT_UNIQUE_C1;
            }
            unsigned drawCount = stages < 8 ? 48 : 16;
            if (!phase || !test)
                [cache removeAllObjects];
            uint64_t misses = cache.missCount, hits = cache.hitCount;
            NV2AMetalCombinerInput inputs[48] = { 0 };
            NV2AMetalCombinerState states[48];
            NV2AMetalPixelUniforms draws[48];
            for (unsigned i = 0; i < drawCount; i++) {
                draws[i] = ck_uniforms(stages, family, slot, alpha, reg);
                unsigned flags = (i & 7) ^ (i < 8 ? 7 : 0);
                draws[i].combiner.control |=
                    ((flags & 1 ? PS_COMBINERCOUNT_UNIQUE_C0 : 0) |
                     (flags & 2 ? PS_COMBINERCOUNT_UNIQUE_C1 : 0) |
                     (flags & 4 ? PS_COMBINERCOUNT_MUX_MSB : 0))
                    << 8;
                for (unsigned row = 0; row < 18; row++)
                    for (unsigned lane = 0; lane < 4; lane++)
                        draws[i].combiner.constants[row][lane] =
                            ((row * 3 + lane + (i / 8) * 5) % 32 + 1) / 64.f;
                if (i >= 16) {
                    unsigned variant = i - 16;
                    unsigned stage = stages + (variant / 4) % (8 - stages);
                    unsigned *words[] = { draws[i].combiner.rgb_inputs,
                                          draws[i].combiner.rgb_outputs,
                                          draws[i].combiner.alpha_inputs,
                                          draws[i].combiner.alpha_outputs };
                    /* Include arbitrary/reserved/invalid encodings in words
                     * that the stage-count contract never executes. */
                    words[variant % 4][stage] =
                        family & 1 ? UINT32_MAX : 0xdeadbeefu ^ (1u << variant);
                }
                states[i] = draws[i].combiner;
                memcpy(inputs[i].diffuse, diffuse, sizeof(diffuse));
                memcpy(inputs[i].specular, specular, sizeof(specular));
                memcpy(inputs[i].textures[0], coordinate, sizeof(coordinate));
                for (unsigned k = 1; k < 4; k++)
                    inputs[i].textures[k][3] = 1;
            }
            id<MTLBuffer> input = [commands.device
                newBufferWithBytes:inputs
                            length:sizeof(inputs)
                           options:MTLResourceStorageModeShared];
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalCombinerResult *expected =
                [reference encodeInputs:input
                                  count:drawCount
                                 states:states
                             stateCount:drawCount
                               commands:commands
                                  error:&error];
            require(expected != nil, error);
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = color;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            NV2AMetalPixelTexture textures[4] = { 0 };
            id<MTLBuffer> outputs[48];
            for (unsigned n = 0; n < drawCount; n++) {
                /* Create cold pipelines from noisy inactive words first;
                 * pristine packets must then reuse those same entries. */
                unsigned i = drawCount > 16 ? (n + 16) % drawCount : n;
                NV2AMetalPixelUniforms before = draws[i];
                require([shader encodeVertices:vertices
                                         count:6
                                     primitive:MTLPrimitiveTypeTriangle
                                      uniforms:&draws[i]
                                      textures:textures
                                          pass:pass
                                     drawState:raster
                                      commands:commands
                                         error:&error],
                        error);
                assert(!memcmp(&before, &draws[i], sizeof(before)));
                outputs[i] = ck_read(commands, color);
            }
            if (stages < 8) {
                NV2AMetalPixelUniforms invalid = draws[0];
                invalid.combiner.control =
                    (invalid.combiner.control & ~255u) | (stages + 1);
                invalid.combiner.rgb_inputs[stages] = 6u << 24;
                NV2AMetalPixelUniforms before = invalid;
                assert(![shader encodeVertices:vertices
                                         count:6
                                     primitive:MTLPrimitiveTypeTriangle
                                      uniforms:&invalid
                                      textures:textures
                                          pass:pass
                                     drawState:raster
                                      commands:commands
                                         error:&error] &&
                       error);
                assert(!memcmp(&before, &invalid, sizeof(invalid)));
                error = nil;
                activationRejects++;
            }
            unsigned distinct = 1u << __builtin_popcount(needed);
            uint64_t created = cache.missCount - misses;
            assert((phase ? created <= distinct :
                            cache.count == distinct && created == distinct) &&
                   cache.hitCount - hits == drawCount - created);
            require([commands submitWithError:&error] &&
                        [commands waitUntilIdleWithError:&error],
                    error);
            const NV2AMetalCombinerOutput *e = expected.outputs.contents;
            for (unsigned i = 0; i < drawCount; i++)
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 8; x++) {
                        const float *actual =
                            (const float *)((const uint8_t *)outputs[i]
                                                .contents +
                                            y * 256) +
                            4 * x;
                        if (memcmp(actual, e[i].color, 16)) {
                            fprintf(stderr,
                                    "Combiner key test%u stages%u family%u "
                                    "draw%u pixel%u,%u differs\n",
                                    test, stages, family, i, x, y);
                            abort();
                        }
                    }
            if (phase)
                continuous += (unsigned)created;
            else
                pipelines += distinct;
            raw += 8;
            inactive += drawCount - 16;
            drawsCompared += drawCount;
            cases++;
        }
    assert(cases == 190 && pipelines == 178 && raw == 1520 &&
           inactive == 4608 && activationRejects == 144 &&
           drawsCompared == 7648 && continuous > 1 && continuous <= 178 &&
           cache.count == continuous);
    printf(
        "Metal combiner keys:190 cases/7648 draws/489472 exact Float4 pixels "
        "versus raw-control GPU interpreter;"
        "1520 raw controls plus4608 inactive-word mutations;"
        "178 cold-fixture pipeline requests,%u continuous-cache requests;"
        "144 active-source rejects;0..8 stages,RGB/alpha "
        "MUX,C0/C1 "
        "in all four operands,"
        "row0/final row8,live constants,immutable uniforms PASS\n",
        continuous);
}
#endif
