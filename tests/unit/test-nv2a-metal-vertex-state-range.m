/* Documented FULL/USER aperture software validation, no hardware fault claim.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/vertex-state.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "test-metal-vertex-context.h"

static BOOL allowed(unsigned access, int index, BOOL relative)
{
    if (index < 0 || index >= 192)
        return NO;
    return access || index >= 96 || (!relative && (index == 58 || index == 59));
}
static unsigned accepted, rejected;
static void check(NV2AMetalStateProgram *program, const Token *tokens,
                  unsigned slots, NSData *constants, const uint32_t launch[4],
                  unsigned access, BOOL pass, unsigned destinationRow,
                  unsigned mask, const uint32_t value[4])
{
    NSError *error = nil;
    NV2AMetalStateResult *result =
        [program executeTokens:tokens[0].word
                        length:slots
                     constants:constants
                        launch:[NSData dataWithBytes:launch length:16]
                        access:access
                         error:&error];
    if (!pass) {
        if (result || !error) {
            fprintf(stderr, "Range validation missed access%u row%u\n", access,
                    destinationRow);
            abort();
        }
        rejected++;
        return;
    }
    if (!result) {
        fprintf(stderr, "Unexpected aperture rejection: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
    const uint32_t (*before)[4] = constants.bytes;
    const uint32_t (*after)[4] = result.constants.bytes;
    const uint32_t *written = result.written.bytes;
    for (unsigned row = 0; row < 192; row++) {
        assert(written[row] == (unsigned)(row == destinationRow && mask != 0));
        for (unsigned k = 0; k < 4; k++) {
            uint32_t expected = row == destinationRow && (mask & (8u >> k)) ?
                                    value[k] :
                                    before[row][k];
            if (after[row][k] != expected) {
                fprintf(stderr,
                        "Range raw access%u row%u component%u: %08x vs %08x\n",
                        access, row, k, after[row][k], expected);
                abort();
            }
        }
    }
    accepted++;
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        assert(commands);
        NV2AMetalStateProgram *program =
            [[NV2AMetalStateProgram alloc] initWithDevice:commands.device
                                                    error:&error];
        if (!program) {
            fprintf(stderr, "State range init: %s\n",
                    error.localizedDescription.UTF8String);
            abort();
        }
        uint32_t raw[192][4];
        for (unsigned row = 0; row < 192; row++)
            for (unsigned k = 0; k < 4; k++)
                raw[row][k] = 0x3f000000u + row * 4096 + k * 257;
        raw[58][1] = 0x7f800001;
        raw[59][2] = 0xff800001;
        raw[96][0] = 0x80000000;
        raw[191][3] = 0x00000001;
        NSData *constants = [NSData dataWithBytes:raw length:sizeof(raw)];
        const uint32_t launch[4] = { 0x3f800000, 0x7f800001, 0xff800001,
                                     0x80000000 };
        for (unsigned access = 0; access < 2; access++) {
            for (unsigned row = 0; row < 192; row++) {
                @autoreleasepool {
                    Token read = token(1, 0, row);
                    source(&read, 0, 3, 0, 0xe4);
                    destination(&read, 191, 15, 0, 0, 0, 0);
                    read.word[3] |= 1;
                    check(program, &read, 1, constants, launch, access,
                          allowed(access, row, NO), 191, 15, raw[row]);
                    for (unsigned mask = 0; mask < 16; mask++) {
                        Token write = token(1, 0, 0);
                        source(&write, 0, 2, 0, 0xe4);
                        destination(&write, row, mask, 0, 0, 0, 0);
                        write.word[3] |= 1;
                        check(program, &write, 1, constants, launch, access,
                              !mask || allowed(access, row, NO), row, mask,
                              launch);
                    }
                }
            }
        }
        const unsigned bases[] = { 0,  1,  57, 58,  59,  60,
                                   95, 96, 97, 191, 192, 255 };
        for (unsigned access = 0; access < 2; access++) {
            for (unsigned b = 0; b < sizeof(bases) / sizeof(bases[0]); b++) {
                for (int target = -1; target <= 192; target++) {
                    @autoreleasepool {
                        uint32_t addressInput[4] = { 0 };
                        float address = target - (int)bases[b];
                        memcpy(addressInput, &address, 4);
                        Token tokens[2] = { token(13, 0, 0),
                                            token(1, 0, bases[b]) };
                        source(&tokens[0], 0, 2, 0, 0xe4);
                        destination(&tokens[0], 0, 0, 0, 0, 8, 0);
                        source(&tokens[1], 0, 3, 0, 0xe4);
                        destination(&tokens[1], 191, 15, 0, 0, 0, 0);
                        tokens[1].word[3] |= 3;
                        check(program, tokens, 2, constants, addressInput,
                              access, allowed(access, target, YES), 191, 15,
                              raw[target >= 0 && target < 192 ? target : 0]);
                    }
                }
            }
        }
        Token invalid = token(1, 0, 96);
        source(&invalid, 0, 3, 0, 0xe4);
        destination(&invalid, 191, 15, 0, 0, 0, 0);
        invalid.word[3] |= 1;
        check(program, &invalid, 1, constants, launch, 2, NO, 191, 15, raw[96]);
        check(program, &invalid, 1, constants, launch, 1, YES, 191, 15,
              raw[96]);
        assert(accepted == 8481 && rejected == 2705);
        printf(
            "Native State FULL/USER apertures: %u accepted/%u rejected, all192 "
            "direct sources/targets, all16 masks, 12 relative bases PASS\n",
            accepted, rejected);
        puts("Forbidden accesses are backend validation failures, not inferred "
             "NV2A hardware results");
    }
    return 0;
}
