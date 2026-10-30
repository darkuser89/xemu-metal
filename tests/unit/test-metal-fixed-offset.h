/* Native fixed-function input offsets compared with copied suffixes.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_FIXED_OFFSET_H
#define TEST_METAL_FIXED_OFFSET_H

static void fixed_offset_copy(NV2AMetalCommands *commands, id<MTLBuffer> source,
                              id<MTLBuffer> destination)
{
    NSError *error = nil;
    begin(commands);
    require([commands addResource:source error:&error], error);
    require([commands addResource:destination error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:source
               sourceOffset:0
                   toBuffer:destination
          destinationOffset:0
                       size:source.length];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    finish(commands);
}

static void fixed_input_offset_tests(NV2AMetalVertexFixed *fixed,
                                     NV2AMetalCommands *commands)
{
    enum { Count = 7 };
    NV2AMetalProgramInput inputs[Count];
    for (unsigned i = 0; i < Count; i++) {
        inputs[i] = input();
        inputs[i].attributes[0][0] = .25f + i;
        inputs[i].attributes[0][1] = .5f + i * .25f;
        inputs[i].attributes[0][2] = .75f + i * .5f;
        inputs[i].attributes[0][3] = 1;
        for (unsigned a = 3; a <= 12; a++)
            for (unsigned c = 0; c < 4; c++)
                inputs[i].attributes[a][c] += i * .125f;
    }
    const NSUInteger ranges[][2] = {
        { 0, 1 }, { 1, 1 }, { 3, 2 }, { 6, 1 }, { 1, 6 }, { 7, 0 }, { 0, 0 },
    };
    NSError *error = nil;
    id<MTLBuffer> staging =
        [commands.device newBufferWithLength:sizeof(inputs) + 4
                                     options:MTLResourceStorageModeShared];
    assert(staging);
    memcpy(staging.contents, inputs, sizeof(inputs));
    memset((uint8_t *)staging.contents + sizeof(inputs), 0xa5, 4);
    NSData *original = [NSData dataWithBytes:staging.contents
                                      length:staging.length];
    unsigned comparisons = 0, rejections = 0;
    for (unsigned storage = 0; storage < 2; storage++) {
        id<MTLBuffer> source =
            storage ? [commands.device
                          newBufferWithLength:staging.length
                                      options:MTLResourceStorageModePrivate] :
                      staging;
        assert(source);
        if (storage)
            fixed_offset_copy(commands, staging, source);
        for (unsigned rasterize = 0; rasterize < 2; rasterize++) {
            NV2AMetalFixedUniforms u = uniforms();
            for (unsigned range = 0; range < sizeof(ranges) / sizeof(ranges[0]);
                 range++) {
                NSUInteger first = ranges[range][0], count = ranges[range][1];
                id<MTLBuffer> selected = [commands.device
                    newBufferWithBytes:count ? inputs + first : inputs
                                length:MAX(count, 1u) * sizeof(inputs[0])
                               options:MTLResourceStorageModeShared];
                assert(selected);
                begin(commands);
                NV2AMetalFixedResult *actual = [fixed encodeAttributes:source
                                                                 first:first
                                                                 count:count
                                                              uniforms:&u
                                                             rasterize:rasterize
                                                              commands:commands
                                                                 error:&error];
                require(actual != nil, error);
                NV2AMetalFixedResult *expected =
                    [fixed encodeAttributes:selected
                                      count:count
                                   uniforms:&u
                                  rasterize:rasterize
                                   commands:commands
                                      error:&error];
                require(expected != nil, error);
                finish(commands);
                assert(actual.vertexCount == count);
                if (count) {
                    assert(!memcmp(actual.registers.contents,
                                   expected.registers.contents,
                                   count * sizeof(NV2AMetalProgramOutput)));
                    assert(!memcmp(actual.vertices.contents,
                                   expected.vertices.contents,
                                   count * sizeof(NV2AMetalVertex)));
                    const NV2AMetalProgramOutput *registers =
                        actual.registers.contents;
                    for (NSUInteger i = 0; i < count; i++) {
                        assert(!registers[i].fault);
                        check_float(registers[i].registers[0][0],
                                    inputs[first + i].attributes[0][0]);
                    }
                } else {
                    assert(!actual.registers && !actual.vertices);
                }
                comparisons++;
            }
            const NSUInteger bad[][2] = {
                { 8, 0 },
                { 7, 1 },
                { 6, 2 },
                { NSUIntegerMax, 0 },
                { 0, NSUIntegerMax },
                { 1, NSUIntegerMax },
            };
            for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
                begin(commands);
                error = nil;
                assert(![fixed encodeAttributes:source
                                          first:bad[i][0]
                                          count:bad[i][1]
                                       uniforms:&u
                                      rasterize:rasterize
                                       commands:commands
                                          error:&error]);
                assert(error && commands.commandBuffer);
                [commands cancel];
                rejections++;
            }
        }
        id<MTLBuffer> readback =
            [commands.device newBufferWithLength:source.length
                                         options:MTLResourceStorageModeShared];
        assert(readback);
        fixed_offset_copy(commands, source, readback);
        assert(!memcmp(readback.contents, original.bytes, original.length));
    }
    assert(comparisons == 28 && rejections == 24);
    puts("Fixed input offset:28 shared/private/raster/raw suffix GPU "
         "comparisons, "
         "24 boundary/overflow rejections and unchanged input/tail bytes PASS");
}
#endif
