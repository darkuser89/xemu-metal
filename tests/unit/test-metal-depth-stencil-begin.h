/* Reuse survives completed captures in the actual PGRAPH controller.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DEPTH_STENCIL_BEGIN_H
#define TEST_METAL_DEPTH_STENCIL_BEGIN_H
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
static void depth_stencil_begin_tests(void)
{
    fixture();
    id owner = [draw valueForKey:@"depthStencilCache"];
    assert(owner);
    NV2AMetalLRUCache *cache = [owner valueForKey:@"states"];
    [cache removeAllObjects];
    uint64_t builds = [[owner valueForKey:@"buildCount"] unsignedLongLongValue];
    uint64_t hits = cache.hitCount;
    for (unsigned n = 0; n < 32; n++) {
        NSError *error = nil;
        qemu_mutex_lock(&state->pgraph.lock);
        /* Every iteration starts with a new nonempty immutable input batch. */
        state->pgraph.draw_arrays_length = 1;
        state->pgraph.draw_arrays_start[0] = 0;
        state->pgraph.draw_arrays_count[0] = 3;
        require([draw beginWithError:&error], error);
        NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
        assert([pixel.raster valueForKey:@"depthStencilCache"] == owner);
        require([draw endWithError:&error], error);
        require([draw flushWithError:&error], error);
        assert(![draw valueForKey:@"pixelState"] &&
               !surfaces.cache.commands.commandBuffer);
        qemu_mutex_unlock(&state->pgraph.lock);
    }
    assert(cache.count == 1 && cache.hitCount - hits == 31);
    assert([[owner valueForKey:@"buildCount"] unsignedLongLongValue] - builds ==
           1);
    printf(
        "Depth/stencil Begin reuse:32 actual Begin/Draw/End cycles with full "
        "drains and released captures,one native creation/31 hits PASS\n");
    fixture();
}
#endif
