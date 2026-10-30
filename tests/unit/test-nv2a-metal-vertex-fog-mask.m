/* Native Fog write selection within a vertex; no cross-draw carryover claim.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/vertex-writable.h"
#include "test-metal-vertex-context.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(float actual, float expected, unsigned first, unsigned last,
                  unsigned mux, unsigned vertex, unsigned component)
{
    if (actual != expected) {
        fprintf(stderr,
                "Fog masks %x/%x mux%u vertex%u component%u: got %.9g, "
                "expected %.9g\n",
                first, last, mux, vertex, component, actual, expected);
        exit(1);
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
        assert(program && !error);
        NV2AMetalProgramUniforms u = { 0 };
        u.surface_size[0] = u.surface_size[1] = 4;
        u.zmax = 16;
        u.point_size = u.point_scale = 1;
        u.fog_enable = 1;
        u.fog[0] = u.fog[1] = 1;
        for (unsigned row = 0; row < 192; row++)
            for (unsigned k = 0; k < 4; k++)
                u.constants[row][k] = (float)(row * 4 + k + 1);
        NV2AMetalProgramInput inputs[5] = { 0 };
        for (unsigned v = 0; v < 5; v++) {
            inputs[v].attributes[0][0] = inputs[v].attributes[0][1] = 1;
            inputs[v].attributes[0][2] = 2;
            inputs[v].attributes[0][3] = 1;
            for (unsigned a = 1; a <= 4; a++)
                for (unsigned k = 0; k < 4; k++)
                    inputs[v].attributes[a][k] =
                        (float)(v * 4 + a * 16 + k + 1) / 128;
        }
        id<MTLBuffer> input =
            [device newBufferWithBytes:inputs
                                length:sizeof(inputs)
                               options:MTLResourceStorageModeShared];
        assert(input);
        /* OGL fog_mask_str maps each nonzero destination mask to an output
         * prefix. It does not mask the source a second time. Only X is a
         * hardware Fog coordinate; the other lanes check OGL representation.
         */
        const unsigned width[] = { 0, 1, 1, 2, 1, 2, 2, 3,
                                   1, 2, 2, 3, 2, 3, 3, 4 };
        const unsigned components[2][2][4] = {
            { { 1, 2, 3, 0 }, { 3, 2, 1, 0 } },
            { { 3, 2, 1, 0 }, { 0, 1, 2, 3 } },
        };
        const unsigned swizzles[2][2] = { { 0x39, 0x1b }, { 0x1b, 0xe4 } };
        unsigned cases = 0, vertices = 0, rasterVertices = 0;
        for (unsigned first = 0; first < 16; first++)
            for (unsigned last = 0; last < 16; last++)
                for (unsigned mux = 0; mux < 4; mux++)
                    for (unsigned raster = 0; raster < 2; raster++)
                        for (unsigned enabled = 0; enabled < 2; enabled++)
                            @autoreleasepool {
                                Token tokens[5];
                                for (unsigned i = 0; i < 5; i++) {
                                    tokens[i] = token(NV2AMetalMACMov,
                                                      NV2AMetalILUNop, 0);
                                    tokens[i].word[1] |= i << 9;
                                    source(&tokens[i], 0, 2, 0, 0xe4);
                                    destination(&tokens[i],
                                                0x100u | (i == 0 ? 0 :
                                                          i == 4 ? 9 :
                                                                   5),
                                                15, 0, 0, 0, 0);
                                }
                                for (unsigned i = 0; i < 2; i++) {
                                    unsigned selected = (mux >> i) & 1;
                                    tokens[i + 2] = token(NV2AMetalMACMov,
                                                          NV2AMetalILUMov, 0);
                                    tokens[i + 2].word[1] |= (i + 2) << 9;
                                    source(&tokens[i + 2], 0, 2, 0,
                                           swizzles[i][0]);
                                    source(&tokens[i + 2], 2, 2, 0,
                                           swizzles[i][1]);
                                    destination(&tokens[i + 2], 0x105,
                                                i ? last : first, selected, 0,
                                                0, 0);
                                }
                                tokens[4].word[3] |= 1;
                                error = nil;
                                NV2AMetalWritableResult *result =
                                    [program executeTokens:tokens[0].word
                                                    length:5
                                                  uniforms:&u
                                           attributeBuffer:input
                                                     first:1
                                                     count:3
                                                    access:1
                                               writeEnable:enabled
                                                 rasterize:raster
                                                     error:&error];
                                if (!result) {
                                    fprintf(
                                        stderr, "%s\n",
                                        error.localizedDescription.UTF8String);
                                    return 1;
                                }
                                assert(!error && result.vertexCount == 3);
                                const NV2AMetalProgramOutput *raw =
                                    result.registers.contents;
                                const NV2AMetalVertex *out =
                                    result.vertices.contents;
                                for (unsigned v = 0; v < 3; v++) {
                                    assert(!raw[v].fault);
                                    float expected[13][4] = { 0 };
                                    for (unsigned row = 0; row < 13; row++)
                                        expected[row][3] = 1;
                                    memcpy(expected[0],
                                           inputs[v + 1].attributes[0], 16);
                                    memcpy(expected[5],
                                           inputs[v + 1].attributes[1], 16);
                                    memcpy(expected[9],
                                           inputs[v + 1].attributes[4], 16);
                                    for (unsigned i = 0; i < 2; i++)
                                        for (unsigned k = 0;
                                             k < width[i ? last : first]; k++)
                                            expected[5][k] =
                                                inputs[v + 1].attributes
                                                    [i + 2]
                                                    [components[i][(mux >> i) &
                                                                   1][k]];
                                    for (unsigned row = 0; row < 13; row++)
                                        for (unsigned k = 0; k < 4; k++)
                                            check(raw[v].registers[row][k],
                                                  expected[row][k], first, last,
                                                  mux, v, row * 4 + k);
                                    if (raster) {
                                        /* Independent scalar oracle: any
                                         * nonzero output mask writes the
                                         * selected result's X.
                                         */
                                        unsigned a = last ? 3 : first ? 2 : 1;
                                        unsigned k =
                                            last  ? ((mux & 2) ? 0 : 3) :
                                            first ? ((mux & 1) ? 3 : 1) :
                                                    0;
                                        check(out[v].fog,
                                              inputs[v + 1].attributes[a][k],
                                              first, last, mux, v, 52);
                                        assert(!memcmp(out[v].screen,
                                                       expected[0], 16));
                                        assert(!memcmp(out[v].texcoord[0],
                                                       expected[9], 16));
                                        rasterVertices++;
                                    } else {
                                        NV2AMetalVertex zero = { 0 };
                                        assert(!memcmp(&out[v], &zero,
                                                       sizeof(zero)));
                                    }
                                    vertices++;
                                }
                                assert(!memcmp(result.constants.bytes,
                                               u.constants,
                                               sizeof(u.constants)));
                                const uint32_t *dirty = result.written.bytes;
                                for (unsigned row = 0; row < 192; row++)
                                    assert(!dirty[row]);
                                assert(!memcmp(input.contents, inputs,
                                               sizeof(inputs)));
                                cases++;
                            }
        assert(cases == 4096 && vertices == 12288 && rasterVertices == 6144);
        puts("Native Fog output masks: 4096 ordered "
             "mask/mux/raster/write-policy "
             "cases, 12288 raw vertices and 6144 Fog factors PASS; seeded "
             "within "
             "each vertex, cross-draw carryover untested");
    }
    return 0;
}
