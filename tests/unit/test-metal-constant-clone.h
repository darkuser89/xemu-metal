/* Typed constant cloning versus the portable API roundtrip it replaces.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_CONSTANT_CLONE_H
#define TEST_METAL_CONSTANT_CLONE_H
#include <time.h>
@interface ConstantCloneProbe : NV2AMetalPGRAPHVertexState
@property(nonatomic) unsigned snapshots;
@end
@implementation ConstantCloneProbe
- (NSData *)snapshotData
{
    _snapshots++;
    return [super snapshotData];
}
@end
static double constant_clone_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static int constant_clone_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static NV2AMetalPGRAPHVertexState *
constant_clone_reference(NV2AMetalPGRAPHVertexState *state, NSData *constants,
                         NSData *written)
{
    const uint32_t *flags = written.bytes;
    for (unsigned row = 0; row < 192; row++)
        assert(flags[row] <= 1);
    NSMutableData *wire = [[state snapshotData] mutableCopy];
    uint8_t *dst =
        (uint8_t *)wire.mutableBytes + 32 + sizeof(NV2AMetalProgramInput);
    const uint8_t *src = constants.bytes;
    for (unsigned row = 0; row < 192; row++) {
        if (!flags[row])
            continue;
        for (unsigned k = 0; k < 4; k++) {
            uint32_t word;
            memcpy(&word, src + row * 16 + k * 4, 4);
            for (unsigned b = 0; b < 4; b++)
                dst[row * 16 + k * 4 + b] = word >> (24 - 8 * b);
        }
    }
    NSError *error = nil;
    NV2AMetalPGRAPHVertexState *next =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire error:&error];
    assert(next && !error);
    return next;
}
static void constant_clone_pair_test(void)
{
    NSError *error = nil;
    ConstantCloneProbe *left =
        [[ConstantCloneProbe alloc] initWithSnapshot:capture(5, 1, 0)
                                               error:&error];
    ConstantCloneProbe *right =
        [[ConstantCloneProbe alloc] initWithSnapshot:capture(5, 1, 128)
                                               error:&error];
    assert(left && right && !error);
    NSData *beforeLeft = left.snapshotData, *beforeRight = right.snapshotData;
    uint32_t values[192][4], flags[192] = { 0 };
    for (unsigned r = 0; r < 192; r++)
        for (unsigned k = 0; k < 4; k++)
            values[r][k] = 0x7fa00000 + r * 4 + k;
    flags[17] = flags[191] = 1;
    NSMutableData *constants = [NSMutableData dataWithBytes:values
                                                     length:sizeof(values)];
    NSData *written = [NSData dataWithBytes:flags length:sizeof(flags)];
    NV2AMetalPGRAPHVertexState *a = [left stateByApplyingConstants:constants
                                                           written:written
                                                             error:&error];
    NV2AMetalPGRAPHVertexState *b = [right stateByApplyingConstants:constants
                                                            written:written
                                                              error:&error];
    assert(a && b && !error && a != left && b != right);
    assert(a.writeEnable == left.writeEnable &&
           b.writeEnable == right.writeEnable &&
           a.writeEnable != b.writeEnable);
    NV2AMetalProgramUniforms x = a.programUniforms, y = b.programUniforms,
                             oldX = left.programUniforms,
                             oldY = right.programUniforms;
    for (unsigned r = 0; r < 192; r++) {
        assert(!memcmp(x.constants[r],
                       flags[r] ? (const void *)values[r] :
                                  (const void *)oldX.constants[r],
                       16));
        assert(!memcmp(y.constants[r],
                       flags[r] ? (const void *)values[r] :
                                  (const void *)oldY.constants[r],
                       16));
    }
    assert(a.validatedProgram == left.validatedProgram &&
           b.validatedProgram == right.validatedProgram);
    NSData *afterLeft = a.snapshotData, *afterRight = b.snapshotData;
    memset(constants.mutableBytes, 0, constants.length);
    assert([a.snapshotData isEqual:afterLeft] &&
           [b.snapshotData isEqual:afterRight]);
    assert([left.snapshotData isEqual:beforeLeft] &&
           [right.snapshotData isEqual:beforeRight]);
    puts("Typed constants: distinct frozen/live policy captures preserve "
         "unmarked rows, "
         "NaN bits, program metadata and ownership after source mutation PASS");
}
static void constant_clone_benchmark(void)
{
    constant_clone_pair_test();
    NSError *error = nil;
    ConstantCloneProbe *state =
        [[ConstantCloneProbe alloc] initWithSnapshot:capture(5, 1, 0)
                                               error:&error];
    assert(state && !error);
    uint32_t values[192][4], flags[192];
    for (unsigned r = 0; r < 192; r++)
        for (unsigned k = 0; k < 4; k++)
            values[r][k] = 0x7fa00000 + r * 4 + k;
    NSData *constants = [NSData dataWithBytes:values length:sizeof(values)];
    for (unsigned kind = 0; kind < 3; kind++) {
        for (unsigned r = 0; r < 192; r++)
            flags[r] = kind == 0 ? 0 : kind == 1 ? (r == 191) : 1;
        NSData *written = [NSData dataWithBytes:flags length:sizeof(flags)];
        double times[2][7];
        NV2AMetalPGRAPHVertexState *expected =
            constant_clone_reference(state, constants, written);
        NSData *expectedWire = expected.snapshotData;
        for (unsigned pair = 0; pair < 9; pair++)
            for (unsigned order = 0; order < 2; order++) {
                unsigned mode = (pair + order) & 1;
                state.snapshots = 0;
                double start = constant_clone_clock();
                for (unsigned n = 0; n < 128; n++)
                    @autoreleasepool {
                        NV2AMetalPGRAPHVertexState *next =
                            mode ? constant_clone_reference(state, constants,
                                                            written) :
                                   [state stateByApplyingConstants:constants
                                                           written:written
                                                             error:&error];
                        assert(next && !error);
                        if (!mode)
                            assert((next == state) == (kind == 0));
                    }
                double ms = constant_clone_clock() - start;
                assert(state.snapshots == (mode ? 128u : 0u));
                if (pair >= 2)
                    times[mode][pair - 2] = ms;
            }
        for (unsigned mode = 0; mode < 2; mode++)
            qsort(times[mode], 7, sizeof(double), constant_clone_compare);
        NV2AMetalPGRAPHVertexState *actual =
            [state stateByApplyingConstants:constants
                                    written:written
                                      error:&error];
        assert([actual.snapshotData isEqual:expectedWire]);
        assert(actual.validatedProgram == state.validatedProgram);
        printf("Typed constants kind=%u:128 updates median direct/portable "
               "%.6f/%.6f ms;"
               "0/128 snapshot+restore calls, direct new captures %u/128;"
               "2 warmups/7 alternating pairs,no GPU/app\n",
               kind, times[0][3], times[1][3], kind ? 128 : 0);
    }
}
#endif
