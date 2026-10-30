/* Native address aliases and full constant destinations, offscreen only.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/vertex-writable.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "test-metal-vertex-context.h"
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Address native: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device && [device supportsFamily:MTLGPUFamilyMetal4]);
        NV2AMetalWritableProgram *program =
            [[NV2AMetalWritableProgram alloc] initWithDevice:device
                                                       error:&error];
        require(program != nil, error);
        const unsigned outputs[] = { 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
        const unsigned constants[] = { 10, 58, 59, 96, 154, 191 };
        unsigned cases = 0, vertices = 0;
        for (unsigned high = 0; high < 16; high++)
            for (unsigned mask = 0; mask < 16; mask++)
                for (unsigned mux = 0; mux < 2; mux++)
                    for (unsigned enabled = 0; enabled < 2; enabled++)
                        @autoreleasepool {
                            NV2AMetalProgramUniforms u = { 0 };
                            u.surface_size[0] = u.surface_size[1] = 4;
                            u.zmax = 16;
                            u.point_size = u.point_scale = 1;
                            for (unsigned r = 0; r < 192; r++)
                                for (unsigned k = 0; k < 4; k++)
                                    u.constants[r][k] =
                                        (float)(1000 + r * 4 + k);
                            Token tokens[17];
                            for (unsigned i = 0; i < 17; i++) {
                                tokens[i] = token(mux ? 0 : 1, mux ? 1 : 0, 96);
                                source(&tokens[i], mux ? 2 : 0, 2, 0, 0xe4);
                                unsigned row =
                                    i < 11 ? 256u | (high << 4) | outputs[i] :
                                             constants[i - 11];
                                destination(&tokens[i], row, mask, mux, 0, 0,
                                            0);
                            }
                            tokens[16].word[3] |= 1;
                            NV2AMetalProgramInput inputs[5] = { 0 };
                            for (unsigned v = 0; v < 5; v++)
                                for (unsigned k = 0; k < 4; k++)
                                    inputs[v].attributes[0][k] =
                                        (float)(100 + v * 4 + k);
                            id<MTLBuffer> input = [device
                                newBufferWithBytes:inputs
                                            length:sizeof(inputs)
                                           options:
                                               MTLResourceStorageModeShared];
                            assert(input);
                            error = nil;
                            NV2AMetalWritableResult *result =
                                [program executeTokens:tokens[0].word
                                                length:17
                                              uniforms:&u
                                       attributeBuffer:input
                                                 first:1
                                                 count:3
                                                access:1
                                           writeEnable:enabled
                                                 error:&error];
                            require(result != nil, error);
                            assert(result.vertexCount == 3);
                            const NV2AMetalProgramOutput *raw =
                                result.registers.contents;
                            assert(raw);
                            for (unsigned v = 0; v < 3; v++) {
                                assert(!raw[v].fault);
                                for (unsigned o = 0; o < 11; o++) {
                                    float expected[4] = { 0, 0, 0, 1 };
                                    unsigned packed = 0;
                                    for (unsigned k = 0; k < 4; k++)
                                        if (mask & (8u >> k)) {
                                            unsigned component =
                                                outputs[o] == 5 ? packed++ : k;
                                            expected[component] =
                                                inputs[v + 1]
                                                    .attributes[0][component];
                                        }
                                    assert(!memcmp(raw[v].registers[outputs[o]],
                                                   expected, sizeof(expected)));
                                }
                                vertices++;
                            }
                            float expectedConstants[192][4];
                            memcpy(expectedConstants, u.constants,
                                   sizeof(expectedConstants));
                            if (enabled)
                                for (unsigned i = 0; i < 6; i++)
                                    for (unsigned k = 0; k < 4; k++)
                                        if (mask & (8u >> k))
                                            expectedConstants[constants[i]][k] =
                                                inputs[3].attributes[0][k];
                            assert(!memcmp(result.constants.bytes,
                                           expectedConstants,
                                           sizeof(expectedConstants)));
                            const uint32_t *dirty = result.written.bytes;
                            for (unsigned r = 0; r < 192; r++) {
                                BOOL written = NO;
                                for (unsigned i = 0; i < 6; i++)
                                    written |= r == constants[i];
                                assert(dirty[r] ==
                                       (unsigned)(enabled && mask && written));
                            }
                            assert(!memcmp(input.contents, inputs,
                                           sizeof(inputs)));
                            cases++;
                        }
        assert(cases == 1024 && vertices == 3072);
        puts("Native output-address aliases: 1024 programs/3072 vertices, all "
             "16 upper nibbles, 11 output slots, six full constant rows, 16 "
             "masks, both muxes and write policies PASS; direct GPU suffix "
             "first1/count3, input unchanged");
    }
    return 0;
}
