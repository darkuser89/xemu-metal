/* Native State/PGRAPH transaction test. No app/VM/window.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/state-pgraph.h"
#include "test-metal-vertex-context.h"
#include <stddef.h>

static unsigned accepted, rejected, stale;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "State PGRAPH test: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void setup(PGRAPHState *pg, unsigned row, unsigned mask, unsigned start,
                  unsigned full)
{
    memset(pg, 0, sizeof(*pg));
    pg->regs_[NV_PGRAPH_CSV0_D] = full ? NV_PGRAPH_CSV0_D_RANGE_MODE : 0;
    /* The ordinary vertex entry point deliberately differs from LAUNCH. */
    pg->regs_[NV_PGRAPH_CSV0_C] = 9u << 8;
    for (unsigned r = 0; r < 192; r++) {
        pg->vsh_constants_dirty[r] = r % 7 == 0;
        for (unsigned k = 0; k < 4; k++) {
            uint32_t bits = 0x3f000000u + r * 4 + k;
            memcpy(&pg->vsh_constants[r][k], &bits, 4);
        }
    }
    const uint32_t launch[] = { 0x7fa12345u, 0x80000000u, 0x7f800000u, 1 };
    memcpy(pg->vertex_state_shader_v0, launch, sizeof(launch));
    for (unsigned k = 0; k < 4; k++)
        pg->vertex_attributes[0].inline_value[k] = 42 + k;
    Token t = token(1, 0, 0);
    source(&t, 0, 2, 0, 0xe4);
    destination(&t, row, mask, 0, 0, 0, 0);
    t.word[3] |= 1;
    memcpy(pg->program_data[start], t.word, sizeof(t.word));
}
static void compare_other_state(PGRAPHState *pg, PGRAPHState *before)
{
    size_t offset = offsetof(PGRAPHState, vsh_constants);
    assert(!memcmp(pg, before, offset));
    offset = offsetof(PGRAPHState, vsh_constants_dirty) +
             sizeof(pg->vsh_constants_dirty);
    assert(!memcmp((uint8_t *)pg + offset, (uint8_t *)before + offset,
                   sizeof(*pg) - offset));
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalPGRAPHStateProgram *program =
            [[NV2AMetalPGRAPHStateProgram alloc] initWithDevice:commands.device
                                                          error:&error];
        require(program != nil, error);
        PGRAPHState *pg = calloc(1, sizeof(*pg)),
                    *before = calloc(1, sizeof(*pg));
        assert(pg && before);
        for (unsigned row = 0; row < 192; row++)
            for (unsigned full = 0; full < 2; full++)
                for (unsigned mask = 0; mask < 16; mask++) {
                    @autoreleasepool {
                        unsigned start = (row * 13 + mask) % 136;
                        setup(pg, row, mask, start, full);
                        memcpy(before, pg, sizeof(*pg));
                        error = nil;
                        NV2AMetalStateTransaction *t =
                            [program executeWithState:pg
                                         programStart:start
                                                error:&error];
                        assert(!memcmp(pg, before, sizeof(*pg)));
                        BOOL allowed = full || row >= 96 || row == 58 ||
                                       row == 59 || !mask;
                        if (!allowed) {
                            assert(!t && error);
                            rejected++;
                            continue;
                        }
                        require(t != nil, error);
                        error = nil;
                        assert(![t commitWithState:before error:&error] &&
                               error);
                        assert(!memcmp(pg, before, sizeof(*pg)));
                        error = nil;
                        require([t commitWithState:pg error:&error], error);
                        for (unsigned r = 0; r < 192; r++) {
                            assert(pg->vsh_constants_dirty[r] ==
                                   (before->vsh_constants_dirty[r] ||
                                    (r == row && mask)));
                            for (unsigned k = 0; k < 4; k++) {
                                uint32_t expected =
                                    r == row && (mask & (8u >> k)) ?
                                        before->vertex_state_shader_v0[k] :
                                        before->vsh_constants[r][k];
                                assert(pg->vsh_constants[r][k] == expected);
                            }
                        }
                        compare_other_state(pg, before);
                        memcpy(before, pg, sizeof(*pg));
                        error = nil;
                        assert(![t commitWithState:pg error:&error] && error);
                        assert(!memcmp(pg, before, sizeof(*pg)));
                        accepted++;
                    }
                }
        for (unsigned row = 0; row < 192; row++) {
            setup(pg, row, 15, 135, 1);
            error = nil;
            NV2AMetalStateTransaction *t = [program executeWithState:pg
                                                        programStart:135
                                                               error:&error];
            require(t != nil, error);
            pg->vsh_constants[(row + 1) % 192][0] ^= 1;
            memcpy(before, pg, sizeof(*pg));
            error = nil;
            assert(![t commitWithState:pg error:&error] && error);
            assert(!memcmp(pg, before, sizeof(*pg)));
            stale++;
        }
        setup(pg, 96, 15, 135, 1);
        memcpy(before, pg, sizeof(*pg));
        for (unsigned start = 136; start < 140; start++) {
            error = nil;
            assert(![program executeWithState:pg
                                 programStart:start
                                        error:&error] &&
                   error);
            assert(!memcmp(pg, before, sizeof(*pg)));
        }
        error = nil;
        assert(![program executeWithState:NULL programStart:0 error:&error] &&
               error);
        setup(pg, 96, 15, 0, 1);
        Token fault[] = { token(1, 0, 0), token(13, 0, 0) };
        source(&fault[0], 0, 2, 0, 0xe4);
        destination(&fault[0], 191, 15, 0, 0, 0, 0);
        source(&fault[1], 0, 2, 0, 0xe4);
        destination(&fault[1], 0, 0, 0, 0, 8, 0);
        fault[1].word[3] |= 1;
        memcpy(pg->program_data, fault, sizeof(fault));
        memcpy(before, pg, sizeof(*pg));
        error = nil;
        assert(![program executeWithState:pg programStart:0 error:&error] &&
               error);
        assert(!memcmp(pg, before, sizeof(*pg)));
        setup(pg, 96, 15, 135, 1);
        error = nil;
        NV2AMetalStateTransaction *retry = [program executeWithState:pg
                                                        programStart:135
                                                               error:&error];
        require(retry != nil, error);
        require([retry commitWithState:pg error:&error], error);
        assert(!memcmp(pg->vsh_constants[96], pg->vertex_state_shader_v0, 16));
        memset(pg->program_data, 0, sizeof(pg->program_data));
        memcpy(before, pg, sizeof(*pg));
        error = nil;
        assert(![program executeWithState:pg programStart:135 error:&error] &&
               error);
        assert(!memcmp(pg, before, sizeof(*pg)));
        assert(accepted == 4734 && rejected == 1410 && stale == 192);
        printf("Native State/PGRAPH transactions: %u accepted/%u aperture "
               "rejections, %u stale contexts and single-commit protection "
               "PASS; primitive ordering integration remains separate\n",
               accepted, rejected, stale);
        puts("Late State fault after private write, valid retry, missing EOF "
             "and cross-PGRAPH commit rejection PASS");
        free(before);
        free(pg);
    }
    return 0;
}
