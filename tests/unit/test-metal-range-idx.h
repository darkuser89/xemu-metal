/* MIN/MAX and ordered integer comparisons before ARL.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RANGE_IDX_H
#define TEST_METAL_RANGE_IDX_H
static void range_idx_step(Token *t, unsigned *count, unsigned opcode,
                           unsigned target, unsigned a, unsigned b)
{
    Token *op = &t[(*count)++];
    *op = token(opcode, 0, 96);
    source(op, 0, 1, a, a == 12 ? 0xff : 0xe4);
    source(op, 1, 1, b, b == 12 ? 0xff : 0xe4);
    destination(op, 0, 0, 0, target, 15, 0);
}
static unsigned range_idx_tokens(Token *t, unsigned kind, unsigned base,
                                 BOOL read)
{
    assert(kind < 12);
    unsigned n = 0;
    range_idx_step(t, &n, NV2AMetalMACSlt, 2, 0, 0);
    source(&t[0], 0, 2, 0, 0xe4);
    if (kind < 2)
        range_idx_step(t, &n, kind ? NV2AMetalMACMax : NV2AMetalMACMin, 2, 2,
                       kind ? 12 : 0);
    else if (kind < 4) {
        range_idx_step(t, &n, NV2AMetalMACMov, 3, 2, 0);
        t[n - 1].word[1] |= 1u << 8;
        range_idx_step(t, &n, kind == 2 ? NV2AMetalMACMin : NV2AMetalMACMax, 2,
                       3, 2);
    } else if (kind < 8) {
        range_idx_step(t, &n, kind < 6 ? NV2AMetalMACAdd : NV2AMetalMACMov, 3,
                       12, 0);
        if (kind < 6)
            source(&t[n - 1], 2, 1, 12, 0xff);
        else
            t[n - 1].word[1] |= 1u << 8;
        range_idx_step(t, &n, kind & 1 ? NV2AMetalMACSge : NV2AMetalMACSlt, 2,
                       2, 3);
    } else {
        range_idx_step(t, &n, kind & 1 ? NV2AMetalMACSge : NV2AMetalMACSlt, 2,
                       kind < 10 ? 0 : 12, kind < 10 ? 0 : 12);
        if (kind < 10)
            t[n - 1].word[1] |= 1u << 8; /* -0 against +0 */
    }
    t[n] = token(NV2AMetalMACArl, 0, 96);
    source(&t[n], 0, 1, 2, 0);
    destination(&t[n++], 0, 0, 0, 0, 0, 0);
    if (read) {
        t[n] = token(NV2AMetalMACMov, 0, base);
        source(&t[n], 0, 3, 0, 0xe4);
        destination(&t[n], 0x103, 15, 0, 0, 0, 0);
        t[n++].word[3] |= 2;
    }
    t[n - 1].word[3] |= 1;
    return n;
}
#endif
