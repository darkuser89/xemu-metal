/* Native PGRAPH image blit from gl/blit.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "blit-pgraph.h"
static BOOL adapter_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pgraph-blit"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@implementation NV2AMetalPGRAPHBlit {
    NV2AState *_d;
    NV2AMetalSurfaceCache *_cache;
    NV2AMetalPGRAPHSurfaces *_surfaces;
    NV2AMetalBlit *_blit;
}
- (instancetype)initWithState:(NV2AState *)state
                     surfaces:(NV2AMetalPGRAPHSurfaces *)surfaces
                        error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    if (!state || !state->vram || cache.vram.contents != state->vram_ptr ||
        cache.vram.length != memory_region_size(state->vram)) {
        adapter_error(error, @"Blit adapter requires live native VRAM");
        return nil;
    }
    _d = state;
    _cache = cache;
    _surfaces = surfaces;
    _blit = [[NV2AMetalBlit alloc] initWithDevice:cache.commands.device
                                            error:error];
    return _blit ? self : nil;
}
- (BOOL)blitWithError:(NSError **)error
{
    PGRAPHState *pg = &_d->pgraph;
    ContextSurfaces2DState *s = &pg->context_surfaces_2d;
    ImageBlitState *b = &pg->image_blit;
    if (s->object_instance != b->context_surfaces)
        return adapter_error(error, @"Mismatched blit surface context");
    if (!b->width || !b->height)
        return YES; // Common NV09F_SIZE also skips these.
    NV2AMetalBlitConfig c = { .format = s->color_format,
                              .operation = b->operation,
                              .beta = pg->beta.beta,
                              .source_pitch = s->source_pitch,
                              .destination_pitch = s->dest_pitch };
    NV2AMetalBlitLayout l;
    if (!nv2a_metal_blit_layout(&c, &l, error))
        return NO;
    if (!s->source_pitch || !s->dest_pitch || s->source_offset > UINT32_MAX ||
        s->dest_offset > UINT32_MAX || b->width > UINT16_MAX ||
        b->height > UINT16_MAX)
        return adapter_error(error, @"Invalid blit dimensions or pitches");
    DMAObject source = nv_dma_load(_d, s->dma_image_source);
    DMAObject dest = nv_dma_load(_d, s->dma_image_dest);
    uint64_t source_base = (source.address & 0x07ffffff) + s->source_offset;
    uint64_t dest_base = (dest.address & 0x07ffffff) + s->dest_offset;
    uint64_t source_delta = (uint64_t)b->in_y * s->source_pitch +
                            (uint64_t)b->in_x * l.bytes_per_pixel;
    uint64_t dest_delta = (uint64_t)b->out_y * s->dest_pitch +
                          (uint64_t)b->out_x * l.bytes_per_pixel;
    uint64_t source_start = source_base + source_delta,
             dest_start = dest_base + dest_delta;
    if (source.dma_class != NV_DMA_IN_MEMORY_CLASS ||
        dest.dma_class != NV_DMA_IN_MEMORY_CLASS || source_start > UINT32_MAX ||
        dest_start > UINT32_MAX || s->source_offset >= source.limit ||
        s->dest_offset >= dest.limit)
        return adapter_error(error, @"Invalid blit DMA address/class");
    uint64_t requested = (uint64_t)(b->height - 1) * s->dest_pitch +
                         (uint64_t)b->width * l.bytes_per_pixel;
    hwaddr clipped = nv_clip_gpu_tile_blit(_d, dest_start, requested);
    if (clipped > requested)
        return adapter_error(error, @"Invalid tile clipped blit span");
    c.source_offset = (unsigned)source_start;
    c.destination_offset = (unsigned)dest_start;
    c.row_bytes =
        MIN(MIN(s->source_pitch, s->dest_pitch) / l.bytes_per_pixel, b->width) *
        l.bytes_per_pixel;
    c.rows = b->height;
    if (clipped < requested) {
        c.rows = (unsigned)(clipped / s->dest_pitch);
        c.tail_bytes = (unsigned)(clipped % s->dest_pitch);
    }
    if (!nv2a_metal_blit_layout(&c, &l, error))
        return NO;
    uint64_t source_relative = s->source_offset + source_delta;
    uint64_t dest_relative = s->dest_offset + dest_delta;
    if (source_relative > source.limit ||
        l.source_length > (uint64_t)source.limit + 1 - source_relative ||
        dest_relative > dest.limit ||
        l.destination_length > (uint64_t)dest.limit + 1 - dest_relative ||
        source_start > _cache.vram.length ||
        l.source_length > _cache.vram.length - source_start ||
        dest_start > _cache.vram.length ||
        l.destination_length > _cache.vram.length - dest_start)
        return adapter_error(error, @"Blit spans exceed DMA or VRAM bounds");
    if (!l.source_length && !l.destination_length)
        return YES;
    NV2AMetalCachedSurface *binding =
        [_cache surfaceContainingAddress:(NSUInteger)dest_base];
    BOOL bound_dest = binding && binding.address == dest_base;
    /* Preserve earlier guest commands on this queue. All validation precedes
     * cache changes; partial destination updates preserve untouched GPU pixels.
     * No render bytes are copied/converted on the CPU. */
    if (![_cache submitWithError:error] ||
        ![_cache prepareGPUReadAtAddress:c.source_offset
                                  length:l.source_length
                                   error:error] ||
        ![_cache invalidateAddress:c.destination_offset
                            length:l.destination_length
                             error:error])
        return NO;
    if (![_cache prepareGPUReadAtAddress:c.source_offset
                                  length:l.source_length
                                   error:error] ||
        ![_cache prepareGPUWriteAtAddress:c.destination_offset
                                    length:l.destination_length
                                     error:error] ||
        ![_blit encodeSource:_cache.vram
                 destination:_cache.vram
                      config:&c
                    commands:_cache.commands
                       error:error] ||
        ![_cache submitWithError:error]) {
        [_cache cancel];
        return NO;
    }
    /* Publish this blit's writes and earlier feedback prefix. Independent
     * readers of other VRAM spans remain owned by their original queues. */
    NV2AMetalSubmission *submission = _cache.commands.lastSubmitted;
    if (![_cache waitForSubmission:submission error:error] ||
        ![_cache noticeTextureDirtyAtAddress:c.destination_offset
                                      length:l.destination_length
                                       error:error])
        return NO;
    if (bound_dest)
        pg->draw_time++;
    pg->surface_color.draw_dirty =
        _surfaces.color.valid && _surfaces.color.dirty;
    pg->surface_zeta.draw_dirty = _surfaces.zeta.valid && _surfaces.zeta.dirty;
    if (_surfaces.color && !_surfaces.color.valid)
        pg->surface_color.buffer_dirty = true;
    if (_surfaces.zeta && !_surfaces.zeta.valid)
        pg->surface_zeta.buffer_dirty = true;
    memory_region_set_client_dirty(_d->vram, c.destination_offset,
                                   l.destination_length, DIRTY_MEMORY_VGA);
    memory_region_set_client_dirty(_d->vram, c.destination_offset,
                                   l.destination_length, DIRTY_MEMORY_NV2A_TEX);
    return YES;
}
@end
