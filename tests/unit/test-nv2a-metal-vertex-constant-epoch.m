/* Pure capture transformation test. No Metal device or queue is created.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/vertex-pgraph.h"
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "test-metal-vertex-capture.h"
#include "test-metal-constant-clone.h"

static NV2AMetalPGRAPHVertexState *decode(NSData *wire)
{
    NSError *error = nil;
    NV2AMetalPGRAPHVertexState *s =
        [[ConstantCloneProbe alloc] initWithSnapshot:wire error:&error];
    if (!s) {
        fprintf(stderr, "Constant epoch capture: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
    assert([s.snapshotData isEqualToData:wire]);
    return s;
}
int main(void)
{
    @autoreleasepool {
        unsigned cases = 0, rejections = 0;
        for (unsigned version = 1; version <= 5; version++)
            for (unsigned programmed = 0; programmed < 2; programmed++)
                for (unsigned seed = 0; seed < (version == 5 ? 256u : 64u);
                     seed++) {
                    @autoreleasepool {
                        NSData *wire = capture(version, programmed, seed);
                        NV2AMetalPGRAPHVertexState *s = decode(wire);
                        uint32_t constants[192][4], flags[192];
                        for (unsigned row = 0; row < 192; row++) {
                            flags[row] =
                                seed == 0 ? 0 :
                                seed == 1 ? 1 :
                                            ((row * 13 + seed) % 5 == 0);
                            for (unsigned k = 0; k < 4; k++)
                                constants[row][k] =
                                    0x9e3779b9u * (row * 4 + k + 1) + seed;
                        }
                        /* Include signaling NaN, signed zero, infinity and
                         * denorm raw bits. */
                        constants[0][0] = 0x7fa12345u;
                        constants[0][1] = 0x80000000u;
                        constants[0][2] = 0xff800000u;
                        constants[0][3] = 1;
                        NSData *c = [NSData dataWithBytes:constants
                                                   length:sizeof(constants)];
                        NSData *f = [NSData dataWithBytes:flags
                                                   length:sizeof(flags)];
                        NSError *error = nil;
                        ((ConstantCloneProbe *)s).snapshots = 0;
                        NV2AMetalPGRAPHVertexState *next =
                            [s stateByApplyingConstants:c
                                                written:f
                                                  error:&error];
                        assert(next && !error);
                        assert(!((ConstantCloneProbe *)s).snapshots);
                        assert((next == s) == (seed == 0));
                        assert(next.programBytes == s.programBytes &&
                               next.validatedProgram == s.validatedProgram);
                        assert([s.snapshotData isEqualToData:wire]);
                        NSData *after = next.snapshotData;
                        assert(after.length == wire.length);
                        const uint8_t *beforeBytes = wire.bytes,
                                      *afterBytes = after.bytes;
                        size_t offset = 32 + sizeof(NV2AMetalProgramInput);
                        for (size_t i = 0; i < wire.length; i++) {
                            uint8_t expected = beforeBytes[i];
                            if (i >= offset && i < offset + sizeof(constants)) {
                                size_t j = i - offset;
                                unsigned row = (unsigned)(j / 16),
                                         k = (unsigned)(j % 16) / 4;
                                if (flags[row])
                                    expected =
                                        constants[row][k] >> (24 - 8 * (j % 4));
                            }
                            assert(afterBytes[i] == expected);
                        }
                        decode(after);
                        NV2AMetalProgramUniforms before = s.programUniforms,
                                                 changed = next.programUniforms;
                        for (unsigned row = 0; row < 192; row++)
                            assert(!memcmp(changed.constants[row],
                                           flags[row] ?
                                               (const void *)constants[row] :
                                               before.constants[row],
                                           16));
                        if (!programmed) {
                            NV2AMetalFixedUniforms value = next.fixedUniforms;
                            assert(!memcmp(value.common.constants,
                                           changed.constants,
                                           sizeof(constants)));
                            assert(value.legacy_specular == (version == 1));
                        }
                        cases++;
                    }
                }
        NV2AMetalPGRAPHVertexState *s = decode(capture(4, 1, 0));
        uint32_t constants[192][4] = { 0 }, flags[192] = { 0 };
        NSData *wire = s.snapshotData;
        NSData *c = [NSData dataWithBytes:constants length:sizeof(constants)];
        for (unsigned row = 0; row < 192; row++) {
            flags[row] = row & 1 ? 2 : UINT32_MAX;
            NSError *error = nil;
            assert(![s stateByApplyingConstants:c
                                        written:[NSData
                                                    dataWithBytes:flags
                                                           length:sizeof(flags)]
                                          error:&error] &&
                   error);
            assert([s.snapshotData isEqualToData:wire]);
            flags[row] = 0;
            rejections++;
        }
        NSError *error = nil;
        assert(![s stateByApplyingConstants:[NSData data]
                                    written:[NSData dataWithBytes:flags
                                                           length:sizeof(flags)]
                                      error:&error] &&
               error);
        error = nil;
        assert(![s stateByApplyingConstants:c
                                    written:[NSData data]
                                      error:&error] &&
               error);
        rejections += 2;
        assert(cases == 1024 && rejections == 194);
        constant_clone_benchmark();
        puts(
            "Immutable constant epochs: 1024 fixed/programmed v1..v5 captures, "
            "786432 raw constant channels and 194 rejected inputs PASS; no "
            "Metal device/queue/dispatch");
    }
    return 0;
}
