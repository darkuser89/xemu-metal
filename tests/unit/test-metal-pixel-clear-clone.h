/* Immutable clear derivation against the existing portable APIs.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PIXEL_CLEAR_CLONE_H
#define TEST_METAL_PIXEL_CLEAR_CLONE_H
#include <time.h>
#import "hw/xbox/nv2a/pgraph/metal/texture-snapshot.h"
@interface PixelClearProbe : NV2AMetalPGRAPHPixelState
@property(nonatomic) unsigned snapshots;
@end
@implementation PixelClearProbe
- (NSData *)snapshotData
{
    _snapshots++;
    return [super snapshotData];
}
@end
static unsigned typed_clear_cases, typed_clear_images;
static NV2AMetalPGRAPHPixelState *
pixel_clear_reference(NV2AMetalPGRAPHPixelState *p, uint32_t parameter)
{
    uint32_t c = p.raster.config.control[0], s = p.raster.config.control[1];
    if (parameter & NV097_CLEAR_SURFACE_COLOR) {
        const uint32_t bits[] = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE,
                                  NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE,
                                  NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE,
                                  NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE };
        const uint32_t clear[] = { NV097_CLEAR_SURFACE_R, NV097_CLEAR_SURFACE_G,
                                   NV097_CLEAR_SURFACE_B,
                                   NV097_CLEAR_SURFACE_A };
        for (unsigned k = 0; k < 4; k++) {
            c &= ~bits[k];
            if (parameter & clear[k])
                c |= bits[k];
        }
    }
    if (parameter & NV097_CLEAR_SURFACE_Z)
        c |= NV_PGRAPH_CONTROL_0_ZWRITEENABLE;
    if (parameter & NV097_CLEAR_SURFACE_STENCIL)
        s |= NV_PGRAPH_CONTROL_1_STENCIL_MASK_WRITE;
    c = (c & ~NV_PGRAPH_CONTROL_0_DITHERENABLE) |
        (state->pgraph.regs_[NV_PGRAPH_CONTROL_0] &
         NV_PGRAPH_CONTROL_0_DITHERENABLE);
    NSMutableData *wire = [[p snapshotData] mutableCopy];
    stl_be_p((uint8_t *)wire.mutableBytes + 7 * 4, 0);
    stl_be_p((uint8_t *)wire.mutableBytes + 8 * 4, c);
    stl_be_p((uint8_t *)wire.mutableBytes + 9 * 4, s);
    NSError *error = nil;
    NV2AMetalPGRAPHPixelState *result =
        [[NV2AMetalPGRAPHPixelState alloc] initWithSnapshot:wire
                                                   textures:p.textureSnapshot
                                                     device:commands.device
                                                      error:&error];
    require(result != nil, error);
    return result;
}
static void pixel_clear_equal(NV2AMetalPGRAPHPixelState *a,
                              NV2AMetalPGRAPHPixelState *b)
{
    assert([a.snapshotData isEqual:b.snapshotData]);
    assert(a.textureSnapshot == b.textureSnapshot &&
           !a.raster.config.scissor_enabled);
    for (unsigned p = 0; p < 3; p++) {
        NV2AMetalPixelUniforms x = [a uniformsForPolygon:p],
                               y = [b uniformsForPolygon:p];
        assert(!memcmp(&x, &y, sizeof(x)));
    }
    NV2AMetalPixelTexture x[4] = { 0 }, y[4] = { 0 };
    NSError *error = nil;
    require([a copyTextureBindings:x error:&error] &&
                [b copyTextureBindings:y error:&error],
            error);
    for (unsigned i = 0; i < 4; i++)
        assert(x[i].texture == y[i].texture && x[i].sampler == y[i].sampler);
}
static void typed_clear_texture_probe(NV2AMetalPGRAPHPixelState *p)
{
    NSError *error = nil;
    const uint32_t masks[] = { 0, NV097_CLEAR_SURFACE_R,
                               NV097_CLEAR_SURFACE_Z |
                                   NV097_CLEAR_SURFACE_STENCIL,
                               NV097_CLEAR_SURFACE_COLOR };
    NSData *before = p.snapshotData;
    for (unsigned i = 0; i < 4; i++) {
        NV2AMetalPGRAPHPixelState *next =
            [p stateByApplyingClear:masks[i]
                              state:&state->pgraph
                             device:commands.device
                              error:&error];
        require(next != nil, error);
        pixel_clear_equal(next, pixel_clear_reference(p, masks[i]));
        assert(next.textureSnapshot == p.textureSnapshot &&
               [p.snapshotData isEqual:before]);
        typed_clear_cases++;
    }
}
static double pixel_clear_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static int pixel_clear_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void typed_clear_tests(void)
{
    initialize(0, 1);
    state->pgraph.regs_[NV_PGRAPH_SETUPRASTER] |=
        NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE |
        NV_PGRAPH_SETUPRASTER_POFFSETPOINTENABLE |
        NV_PGRAPH_SETUPRASTER_POFFSETLINEENABLE;
    reg_float(NV_PGRAPH_ZOFFSETFACTOR, .5f);
    reg_float(NV_PGRAPH_ZOFFSETBIAS, 1.5f);
    NSError *error = nil;
    NV2AMetalPGRAPHPixelState *base = capture(nil);
    NSMutableData *current = [base.snapshotData mutableCopy];
    stl_be_p((uint8_t *)current.mutableBytes + 7 * 4, 1);
    stl_be_p((uint8_t *)current.mutableBytes + 16 * 4, 1);
    stl_be_p((uint8_t *)current.mutableBytes + 18 * 4, 1);
    stl_be_p((uint8_t *)current.mutableBytes + 20 * 4, 2);
    stl_be_p((uint8_t *)current.mutableBytes + 22 * 4, 2);
    for (unsigned version = 1; version <= 6; version++) {
        NSData *wire =
            version == 6 ? current : legacy_pixel_fixture(current, version);
        PixelClearProbe *p =
            [[PixelClearProbe alloc] initWithSnapshot:wire
                                             textures:nil
                                               device:commands.device
                                                error:&error];
        require(p != nil, error);
        for (unsigned dither = 0; dither < 2; dither++)
            for (unsigned n = 0; n < 64; n++) {
                state->pgraph.regs_[NV_PGRAPH_CONTROL_0] =
                    dither ? NV_PGRAPH_CONTROL_0_DITHERENABLE : 0;
                uint32_t parameter = (n & 1 ? NV097_CLEAR_SURFACE_R : 0) |
                                     (n & 2 ? NV097_CLEAR_SURFACE_G : 0) |
                                     (n & 4 ? NV097_CLEAR_SURFACE_B : 0) |
                                     (n & 8 ? NV097_CLEAR_SURFACE_A : 0) |
                                     (n & 16 ? NV097_CLEAR_SURFACE_Z : 0) |
                                     (n & 32 ? NV097_CLEAR_SURFACE_STENCIL : 0);
                p.snapshots = 0;
                NV2AMetalPGRAPHPixelState *next =
                    [p stateByApplyingClear:parameter
                                      state:&state->pgraph
                                     device:commands.device
                                      error:&error];
                require(next != nil, error);
                assert(!p.snapshots);
                NV2AMetalPGRAPHPixelState *expected =
                    pixel_clear_reference(p, parameter);
                assert(p.snapshots == 1);
                pixel_clear_equal(next, expected);
                assert([p.snapshotData isEqual:wire]);
                typed_clear_cases++;
                if (version == 6 && !dither && n % 4 == 0) {
                    id<MTLTexture> a = target(8, 8), b = target(8, 8);
                    render(next, a, nil, 1, .25f, 0);
                    render(expected, b, nil, 1, .25f, 0);
                    finish();
                    NSData *x =
                        nv2a_metal_texture_snapshot(a, commands, &error);
                    NSData *y =
                        nv2a_metal_texture_snapshot(b, commands, &error);
                    require(x && y, error);
                    assert([x isEqual:y]);
                    typed_clear_images++;
                }
            }
        double times[2][7];
        for (unsigned pair = 0; pair < 9; pair++)
            for (unsigned order = 0; order < 2; order++) {
                unsigned mode = (pair + order) & 1;
                p.snapshots = 0;
                double start = pixel_clear_clock();
                for (unsigned i = 0; i < 128; i++)
                    @autoreleasepool {
                        NV2AMetalPGRAPHPixelState *next =
                            mode ? pixel_clear_reference(
                                       p, NV097_CLEAR_SURFACE_COLOR) :
                                   [p stateByApplyingClear:
                                           NV097_CLEAR_SURFACE_COLOR
                                                     state:&state->pgraph
                                                    device:commands.device
                                                     error:&error];
                        require(next != nil, error);
                    }
                double ms = pixel_clear_clock() - start;
                assert(p.snapshots == (mode ? 128u : 0u));
                if (pair >= 2)
                    times[mode][pair - 2] = ms;
            }
        for (unsigned mode = 0; mode < 2; mode++)
            qsort(times[mode], 7, sizeof(double), pixel_clear_compare);
        printf("Typed clear v%u:128 clones median direct/portable %.6f/%.6f "
               "ms;0/128 "
               "snapshot+restore calls,one DrawState per clone,2 warmups/7 "
               "alternating pairs\n",
               version, times[0][3], times[1][3]);
    }
    printf("Typed clear: %u scalar/texture cases,%u exact GPU image "
           "pairs;v1-v6 masks/"
           "dither/scissor/offset metadata,immutable source/textures PASS\n",
           typed_clear_cases, typed_clear_images);
}
#endif
