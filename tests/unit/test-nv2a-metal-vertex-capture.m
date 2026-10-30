/* Pure v5 capture transport and full destination-field validation.
 * No Metal device, queue or dispatch. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/vertex-pgraph.h"

#include <stddef.h>
#include "test-metal-vertex-capture.h"
#include "test-metal-vertex-context.h"
static void word(NSMutableData *data, NSUInteger index, uint32_t value)
{
    assert(index < data.length / 4);
    uint8_t *bytes = (uint8_t *)data.mutableBytes + 4 * index;
    for (unsigned i = 0; i < 4; i++)
        bytes[i] = value >> (24 - 8 * i);
}
static uint32_t read_word(NSData *data, NSUInteger index)
{
    assert(index < data.length / 4);
    const uint8_t *b = (const uint8_t *)data.bytes + 4 * index;
    return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 |
           b[3];
}
static NV2AMetalPGRAPHVertexState *decode(NSData *wire)
{
    NSError *error = nil;
    NV2AMetalPGRAPHVertexState *s =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire error:&error];
    if (!s) {
        fprintf(stderr, "V5 capture: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
    assert([s.snapshotData isEqualToData:wire]);
    return s;
}
static void unbound_capture_tests(void)
{
    const unsigned widths[] = { 10, 17, 17, 16, 32, 32 };
    const unsigned heights[] = { 14, 14, 23, 8, 8, 16 };
    const unsigned scales[] = { 1, 2, 4, 64 };
    PGRAPHState *pg = calloc(1, sizeof(*pg));
    PGRAPHState *before = malloc(sizeof(*before));
    assert(pg && before);
    unsigned cases = 0;
    for (unsigned shape = 0; shape < 6; shape++)
        for (unsigned scale = 0; scale < 4; scale++)
            for (unsigned programmed = 0; programmed < 2; programmed++)
                for (unsigned write = 0; write < 2; write++) {
                    memset(pg, 0, sizeof(*pg));
                    pg->surface_scale_factor = scales[scale];
                    pg->surface_type =
                        shape < 3 ? NV097_SET_SURFACE_FORMAT_TYPE_PITCH :
                                    NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
                    pg->surface_shape =
                        (SurfaceShape){ .zeta_format =
                                            NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                                        .anti_aliasing = shape % 3,
                                        .clip_width = 7,
                                        .clip_height = 9,
                                        .clip_x = 3,
                                        .clip_y = 5,
                                        .log_width = 4,
                                        .log_height = 3 };
                    pg->surface_binding_dim.width = widths[shape];
                    pg->surface_binding_dim.height = heights[shape];
                    pg->regs_[NV_PGRAPH_CSV0_D] = (programmed ? 2u << 30 : 0) |
                                                  NV_PGRAPH_CSV0_D_RANGE_MODE;
                    pg->enable_vertex_program_write = write;
                    Token t = token(1, 0, 0);
                    source(&t, 0, 2, 0, 0xe4);
                    destination(&t, 256, 15, 0, 0, 0, 0);
                    t.word[3] |= 1;
                    memcpy(pg->program_data[0], t.word, sizeof(t.word));
                    NSError *error = nil;
                    NV2AMetalPGRAPHVertexState *bound =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithState:pg
                                    error:&error];
                    assert(bound && !error);
                    pg->surface_binding_dim.width =
                        pg->surface_binding_dim.height = 0;
                    memcpy(before, pg, sizeof(*pg));
                    NV2AMetalPGRAPHVertexState *unbound =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initForTransformOnlyWithState:pg
                                                    error:&error];
                    assert(unbound && !error &&
                           [bound.snapshotData
                               isEqualToData:unbound.snapshotData] &&
                           !memcmp(pg, before, sizeof(*pg)));
                    assert(![[NV2AMetalPGRAPHVertexState alloc]
                               initWithState:pg
                                       error:&error] &&
                           error);
                    cases++;
                }
    for (unsigned fault = 0; fault < 7; fault++) {
        memset(pg, 0, sizeof(*pg));
        pg->surface_scale_factor = 1;
        pg->surface_shape =
            (SurfaceShape){ .zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                            .clip_width = 8,
                            .clip_height = 8 };
        switch (fault) {
        case 0:
            pg->surface_scale_factor = 0;
            break;
        case 1:
            pg->surface_scale_factor = 16385;
            break;
        case 2:
            pg->surface_shape.clip_width = 0;
            break;
        case 3:
            pg->surface_type = NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
            pg->surface_shape.log_width = 15;
            break;
        case 4:
            pg->surface_shape.anti_aliasing = 3;
            break;
        case 5:
            pg->surface_scale_factor = 2;
            pg->surface_shape.clip_width = 16384;
            break;
        case 6:
            pg->surface_binding_dim.width = -1;
            pg->surface_binding_dim.height = 8;
            break;
        }
        memcpy(before, pg, sizeof(*pg));
        NSError *error = nil;
        assert(![[NV2AMetalPGRAPHVertexState alloc]
                   initForTransformOnlyWithState:pg
                                           error:&error] &&
               error && !memcmp(pg, before, sizeof(*pg)));
    }
    free(before);
    free(pg);
    assert(cases == 96);
    puts("Unbound XF capture:96 fixed/program/write/AA/linear-swizzle/scale "
         "snapshots equal prepared reference, complete PGRAPH unchanged; "
         "seven invalid extents rejected, bound-only API still strict PASS");
}
static void raw_capture_tests(void)
{
    PGRAPHState *pg = calloc(1, sizeof(*pg));
    PGRAPHState *before = malloc(sizeof(*before));
    assert(pg && before);
    unsigned cases = 0, rejected = 0;
    NSData *reference = nil;
    for (unsigned policy = 0; policy < 4; policy++)
        for (unsigned start = 0; start < 136; start++) {
            memset(pg, 0, sizeof(*pg));
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | ((policy & 1) ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0);
            pg->enable_vertex_program_write = !!(policy & 2);
            pg->regs_[NV_PGRAPH_CSV0_C] = start << 8;
            pg->vsh_constants[7][0] = 0x7fc01234;
            Token t = token(1, 0, 0);
            source(&t, 0, 2, 0, 0xe4);
            destination(&t, 191, 15, 0, 0, 0, 0);
            t.word[3] |= 1;
            memcpy(pg->program_data[start], t.word, sizeof(t.word));
            memcpy(before, pg, sizeof(*pg));
            NSError *error = nil;
            NV2AMetalPGRAPHVertexState *s = [[NV2AMetalPGRAPHVertexState alloc]
                initRawProgramWithState:pg
                                  error:&error];
            assert(s && !error && s.rasterDiscard && s.programmed &&
                   s.fullAccess == !!(policy & 1) &&
                   s.writeEnable == !!(policy & 2) &&
                   !memcmp(pg, before, sizeof(*pg)) &&
                   read_word(s.snapshotData, 1) == 6 &&
                   (read_word(s.snapshotData, 2) & 64));
            NV2AMetalPGRAPHVertexState *restored = decode(s.snapshotData);
            assert(restored.rasterDiscard &&
                   restored.fullAccess == s.fullAccess &&
                   restored.writeEnable == s.writeEnable);
            float constants[192][4] = { 0 };
            uint32_t flags[192] = { 0 };
            constants[191][0] = 99;
            constants[7][0] = 42;
            flags[191] = 1;
            NV2AMetalPGRAPHVertexState *changed =
                [s stateByApplyingConstants:[NSData
                                                dataWithBytes:constants
                                                       length:sizeof(constants)]
                                    written:[NSData dataWithBytes:flags
                                                           length:sizeof(flags)]
                                      error:&error];
            assert(changed && !error && changed.rasterDiscard &&
                   changed.fullAccess == s.fullAccess &&
                   changed.writeEnable == s.writeEnable &&
                   changed.programUniforms.constants[191][0] == 99);
            NV2AMetalProgramUniforms u = changed.programUniforms;
            uint32_t bits;
            memcpy(&bits, &u.constants[7][0], 4);
            assert(bits == 0x7fc01234);
            decode(changed.snapshotData);
            assert(!memcmp(pg, before, sizeof(*pg)));
            reference = s.snapshotData;
            cases++;
        }
    assert(reference);
    const NSUInteger uniformOffset = 32 + sizeof(NV2AMetalProgramInput);
    const NSUInteger tailOffset =
        uniformOffset + offsetof(NV2AMetalProgramUniforms, surface_size);
    const NSUInteger tailBytes =
        sizeof(NV2AMetalProgramUniforms) -
        offsetof(NV2AMetalProgramUniforms, surface_size);
    for (NSUInteger index = 0; index < tailBytes / 4; index++) {
        NSMutableData *bad = [reference mutableCopy];
        word(bad, tailOffset / 4 + index, 0x80000000);
        NSError *error = nil;
        assert(![[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bad
                                                               error:&error] &&
               error);
        rejected++;
    }
    for (unsigned bit = 7; bit < 32; bit++) {
        NSMutableData *bad = [reference mutableCopy];
        word(bad, 2, read_word(bad, 2) | (1u << bit));
        NSError *error = nil;
        assert(![[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bad
                                                               error:&error] &&
               error);
        rejected++;
    }
    for (unsigned kind = 0; kind < 5; kind++) {
        NSMutableData *bad = [reference mutableCopy];
        if (kind == 0)
            word(bad, 2, read_word(bad, 2) & ~64u);
        else if (kind == 1)
            word(bad, 2, read_word(bad, 2) & ~1u);
        else if (kind == 2)
            word(bad, 1, 5);
        else if (kind == 3)
            word(bad, 1, 7);
        else
            word(bad, bad.length / 4 - 1,
                 read_word(bad, bad.length / 4 - 1) & ~1u);
        NSError *error = nil;
        assert(![[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bad
                                                               error:&error] &&
               error);
        rejected++;
    }
    NSError *error = nil;
    assert(![[NV2AMetalPGRAPHVertexState alloc]
               initForTransformOnlyWithState:pg
                                       error:&error] &&
           error);
    error = nil;
    assert(![[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                        error:&error] &&
           error);
    pg->regs_[NV_PGRAPH_CSV0_D] = 0;
    error = nil;
    assert(![[NV2AMetalPGRAPHVertexState alloc]
               initRawProgramWithState:pg
                                 error:&error] &&
           error);
    assert(cases == 544 && rejected == tailBytes / 4 + 30);
    printf("Raw V6 capture prototype:544 policy/start roundtrips and "
           "marked-constant clones,"
           "%u malformed transports rejected; Surface0/Scale0 accepted only by "
           "new API,"
           " PGRAPH unchanged, prior APIs strict PASS\n",
           rejected);
    free(before);
    free(pg);
}

static void raw_fixed_capture_tests(void)
{
    PGRAPHState *pg = calloc(1, sizeof(*pg));
    PGRAPHState *before = malloc(sizeof(*before));
    assert(pg && before);
    NSData *reference = nil;
    unsigned cases = 0, rejected = 0;
    for (unsigned lighting = 0; lighting < 2; lighting++)
        for (unsigned normalize = 0; normalize < 2; normalize++)
            for (unsigned two = 0; two < 2; two++)
                for (unsigned point = 0; point < 2; point++)
                    for (unsigned fog = 0; fog < 5; fog++)
                        for (unsigned scale = 1; scale < 3; scale++)
                            for (unsigned write = 0; write < 2; write++) {
                                memset(pg, 0, sizeof(*pg));
                                pg->surface_scale_factor = scale;
                                pg->surface_binding_dim.width = 16;
                                pg->surface_binding_dim.height = 32;
                                pg->surface_shape.zeta_format =
                                    NV097_SET_SURFACE_FORMAT_ZETA_Z16;
                                pg->enable_vertex_program_write = write;
                                pg->regs_[NV_PGRAPH_CSV0_C] =
                                    (lighting ? NV_PGRAPH_CSV0_C_LIGHTING : 0) |
                                    (normalize ?
                                         NV_PGRAPH_CSV0_C_NORMALIZATION_ENABLE :
                                         0) |
                                    (two ? NV_PGRAPH_CSV0_C_TWO_SIDE : 0);
                                pg->regs_[NV_PGRAPH_CSV0_D] =
                                    (point ?
                                         NV_PGRAPH_CSV0_D_POINTPARAMSENABLE :
                                         0);
                                SET_MASK(pg->regs_[NV_PGRAPH_CSV0_D],
                                         NV_PGRAPH_CSV0_D_FOGGENMODE, fog);
                                pg->regs_[NV_PGRAPH_CONTROL_3] =
                                    NV_PGRAPH_CONTROL_3_FOGENABLE;
                                pg->regs_[NV_PGRAPH_POINTSIZE] = 48;
                                pg->vsh_constants[7][0] = 0x7fc01234;
                                NSError *error = nil;
                                NV2AMetalPGRAPHVertexState *raster =
                                    [[NV2AMetalPGRAPHVertexState alloc]
                                        initWithState:pg
                                                error:&error];
                                assert(raster && !error && !raster.programmed &&
                                       !raster.rasterDiscard);
                                NV2AMetalFixedUniforms expected =
                                    raster.fixedUniforms;
                                expected.common.surface_size[0] =
                                    expected.common.surface_size[1] = 0;
                                expected.common.zmax = 0;
                                pg->surface_binding_dim.width =
                                    pg->surface_binding_dim.height = 0;
                                memset(&pg->surface_shape, 0,
                                       sizeof(pg->surface_shape));
                                /* Deliberately invalid raster-only antialiasing
                                 * must not be consumed. */
                                pg->surface_shape.anti_aliasing = UINT32_MAX;
                                memcpy(before, pg, sizeof(*pg));
                                NV2AMetalPGRAPHVertexState *raw =
                                    [[NV2AMetalPGRAPHVertexState alloc]
                                        initRawXFWithState:pg
                                                     error:&error];
                                assert(raw && !error && raw.rasterDiscard &&
                                       !raw.programmed);
                                assert(!memcmp(pg, before, sizeof(*pg)) &&
                                       raw.writeEnable == write);
                                NV2AMetalFixedUniforms actual =
                                    raw.fixedUniforms;
                                assert(!memcmp(&actual, &expected,
                                               sizeof(actual)));
                                assert(raw.snapshotData.length ==
                                       32 + sizeof(NV2AMetalProgramInput) +
                                           sizeof(actual));
                                assert(read_word(raw.snapshotData, 1) == 6 &&
                                       (read_word(raw.snapshotData, 2) & 64));
                                NV2AMetalPGRAPHVertexState *restored =
                                    decode(raw.snapshotData);
                                assert(restored.rasterDiscard &&
                                       !restored.programmed);
                                NV2AMetalFixedUniforms copy =
                                    restored.fixedUniforms;
                                assert(!memcmp(&actual, &copy, sizeof(actual)));
                                float constants[192][4] = { 0 };
                                uint32_t flags[192] = { 0 };
                                flags[191] = 1;
                                constants[191][0] = 99;
                                NV2AMetalPGRAPHVertexState *changed = [raw
                                    stateByApplyingConstants:
                                        [NSData dataWithBytes:constants
                                                       length:sizeof(constants)]
                                                     written:
                                                         [NSData
                                                             dataWithBytes:flags
                                                                    length:
                                                                        sizeof(
                                                                            flags)]
                                                       error:&error];
                                assert(changed && !error &&
                                       changed.rasterDiscard &&
                                       !changed.programmed);
                                copy = changed.fixedUniforms;
                                expected.common.constants[191][0] = 99;
                                assert(!memcmp(&copy, &expected, sizeof(copy)));
                                decode(changed.snapshotData);
                                assert(!memcmp(pg, before, sizeof(*pg)));
                                error = nil;
                                assert(![[NV2AMetalPGRAPHVertexState alloc]
                                           initRawProgramWithState:pg
                                                             error:&error] &&
                                       error);
                                error = nil;
                                assert(
                                    ![[NV2AMetalPGRAPHVertexState alloc]
                                        initForTransformOnlyWithState:pg
                                                                error:&error] &&
                                    error);
                                reference = raw.snapshotData;
                                cases++;
                            }
    const NSUInteger base = (32 + sizeof(NV2AMetalProgramInput)) / 4;
    const NSUInteger surface =
        base + offsetof(NV2AMetalProgramUniforms, surface_size) / 4;
    const NSUInteger zmax = base + offsetof(NV2AMetalProgramUniforms, zmax) / 4;
    const NSUInteger pointScale =
        base + offsetof(NV2AMetalProgramUniforms, point_scale) / 4;
    for (unsigned kind = 0; kind < 10; kind++) {
        NSMutableData *bad = [reference mutableCopy];
        if (kind < 2)
            word(bad, surface + kind, 0x80000000);
        else if (kind == 2)
            word(bad, zmax, 0x80000000);
        else if (kind == 3)
            word(bad, 2, read_word(bad, 2) & ~64u);
        else if (kind == 4)
            word(bad, 1, 5);
        else if (kind == 5)
            word(bad, pointScale, 0);
        else if (kind == 6)
            word(bad, pointScale, 0x7fc01234);
        else if (kind == 7)
            word(bad,
                 base + offsetof(NV2AMetalFixedUniforms, normalization) / 4, 2);
        else if (kind == 8)
            word(bad, 2, read_word(bad, 2) | 2);
        else
            word(bad, 7, 1);
        NSError *error = nil;
        assert(![[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bad
                                                               error:&error] &&
               error);
        rejected++;
    }
    for (unsigned mode = 1; mode < 4; mode += 2) {
        SET_MASK(pg->regs_[NV_PGRAPH_CSV0_D], NV_PGRAPH_CSV0_D_MODE, mode);
        NSError *error = nil;
        assert(![[NV2AMetalPGRAPHVertexState alloc]
                   initRawXFWithState:pg
                                error:&error] &&
               error);
        rejected++;
    }
    assert(cases == 320 && rejected == 12);
    printf(
        "Raw fixed capture:320 lighting/normal/two-side/point/fog/scale/write "
        "cases; exact metadata, V6 roundtrips and constant clones;12 invalid "
        "transports/modes rejected PASS\n");
    free(before);
    free(pg);
}

int main(void)
{
    @autoreleasepool {
        raw_fixed_capture_tests();
        raw_capture_tests();
        unbound_capture_tests();
        unsigned legacy = 0, current = 0, destinations = 0, invalid = 0,
                 live = 0;
        for (unsigned v = 1; v <= 5; v++)
            for (unsigned programmed = 0; programmed < 2; programmed++)
                for (unsigned seed = 0; seed < 64; seed++)
                    for (unsigned policy = 0; policy < (v == 5 ? 4u : 1u);
                         policy++) {
                        NSMutableData *wire =
                            [capture(v, programmed, seed) mutableCopy];
                        if (v == 5)
                            word(wire, 2, read_word(wire, 2) | (policy << 4));
                        NV2AMetalPGRAPHVertexState *s = decode(wire);
                        assert(s.fullAccess == (v < 5 || (policy & 1)));
                        assert(s.writeEnable == (v >= 5 && !!(policy & 2)));
                        if (v < 5) {
                            legacy++;
                        } else
                            current++;
                    }
        assert(legacy == 512 && current == 512);
        for (unsigned kind = 0; kind < 2; kind++)
            for (unsigned row = 0; row < 256; row++)
                for (unsigned mask = 0; mask < 16; mask++) {
                    NSMutableData *wire = [capture(5, 1, 0) mutableCopy];
                    Token t = token(1, 0, 96);
                    source(&t, 0, 2, 0, 0xe4);
                    destination(&t, row | (kind ? 256 : 0), mask, 0, 0, 0, 0);
                    t.word[3] |= 1;
                    NSMutableData *raw = [NSMutableData new];
                    append(raw, t.word, sizeof(t.word));
                    [wire replaceBytesInRange:NSMakeRange(wire.length - 16, 16)
                                    withBytes:raw.bytes];
                    BOOL legal =
                        !mask ||
                        (kind ? ((row & 15u) == 0 ||
                                 ((row & 15u) >= 3 && (row & 15u) <= 12)) :
                                row < 192);
                    NSError *error = nil;
                    NV2AMetalPGRAPHVertexState *s =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithSnapshot:wire
                                       error:&error];
                    assert((s != nil) == legal);
                    if (legal)
                        assert(!error && [s.snapshotData isEqualToData:wire]);
                    else
                        assert(error);
                    destinations++;
                }
        assert(destinations == 8192);
        for (unsigned version = 1; version <= 5; version++)
            for (unsigned bit = (version == 5 ? 6 : 4); bit < 32; bit++) {
                NSMutableData *wire = [capture(version, 1, 0) mutableCopy];
                word(wire, 2, read_word(wire, 2) | (1u << bit));
                NSError *error = nil;
                assert(![[NV2AMetalPGRAPHVertexState alloc]
                           initWithSnapshot:wire
                                      error:&error] &&
                       error);
                invalid++;
            }
        PGRAPHState *pg = calloc(1, sizeof(*pg));
        assert(pg);
        pg->surface_scale_factor = 1;
        pg->surface_binding_dim.width = 8;
        pg->surface_binding_dim.height = 8;
        pg->surface_shape.zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z16;
        for (unsigned mode = 0; mode <= 2; mode += 2)
            for (unsigned policy = 0; policy < 4; policy++)
                for (unsigned start = 0; start < 136; start++) {
                    pg->regs_[NV_PGRAPH_CSV0_D] =
                        (mode << 30) |
                        ((policy & 1) ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0);
                    pg->enable_vertex_program_write = !!(policy & 2);
                    pg->regs_[NV_PGRAPH_CSV0_C] = start << 8;
                    Token t = token(1, 0, 0);
                    source(&t, 0, 2, 0, 0xe4);
                    destination(&t, 191, 15, 0, 0, 0, 0);
                    t.word[3] |= 1;
                    memcpy(pg->program_data[start], t.word, sizeof(t.word));
                    NSError *error = nil;
                    NV2AMetalPGRAPHVertexState *s =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithState:pg
                                    error:&error];
                    if (!s)
                        fprintf(stderr, "V5 live mode%u policy%u start%u: %s\n",
                                mode, policy, start,
                                error.localizedDescription.UTF8String);
                    assert(s && !error && s.programmed == (mode == 2));
                    assert(s.fullAccess == !!(policy & 1) &&
                           s.writeEnable == !!(policy & 2));
                    assert(read_word(s.snapshotData, 1) == 5);
                    NV2AMetalPGRAPHVertexState *restored =
                        decode(s.snapshotData);
                    assert(restored.fullAccess == s.fullAccess &&
                           restored.writeEnable == s.writeEnable);
                    if (mode == 2)
                        assert(!memcmp(s.programBytes.bytes, t.word,
                                       sizeof(t.word)));
                    live++;
                }
        free(pg);
        assert(live == 1088);
        printf("V5 capture: %u legacy/%u policy roundtrips, %u "
               "destination/mask fields, %u invalid flags, %u live PGRAPH "
               "captures PASS; no Metal device/queue/dispatch\n",
               legacy, current, destinations, invalid, live);
    }
    return 0;
}
