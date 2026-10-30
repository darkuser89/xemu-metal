/*
 * Native QEMU surface adapter from gl/surface.c and gl/renderer.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

/* QEMU's existing inline headers are built without these extra warnings.
 * Keep the adapter/test code under -Wextra/-Werror after the include boundary.
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "surface-pgraph.h"
#import "clear.h"

static BOOL pgraph_surface_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pgraph-surfaces"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

@interface NV2AMetalCPUAccess : NSObject {
@public
    QemuEvent complete;
}
@property(nonatomic) NSUInteger address, length;
@property(nonatomic) BOOL write;
@property(nonatomic, nullable) NSError *failure;
@end
@implementation NV2AMetalCPUAccess
- (instancetype)init
{
    self = [super init];
    if (self) {
        qemu_event_init(&complete, false);
    }
    return self;
}
- (void)dealloc
{
    qemu_event_destroy(&complete);
}
@end

typedef struct NV2AMetalCPUAccessContext {
    void *surfaces;
    NV2AMetalCPUAccessGuard *guard;
} NV2AMetalCPUAccessContext;

static void pgraph_metal_cpu_access(void *opaque, MemoryRegion *mr,
                                    hwaddr address, hwaddr length, bool write)
{
    const NV2AMetalCPUAccessContext *context = opaque;
    if (nv2a_metal_try_cpu_access(context->guard, address, length, write))
        return;
    @autoreleasepool {
        NV2AMetalPGRAPHSurfaces *surfaces =
            (__bridge NV2AMetalPGRAPHSurfaces *)context->surfaces;
        NSError *error = nil;
        (void)mr;
        /* QEMU passes the original access length even when it crosses this
         * region. Synchronize only the part covered by the installed hook. */
        NSUInteger size = surfaces.cache.vram.length;
        if (address >= size) {
            return;
        }
        if (length > size - address) {
            length = size - address;
        }
        if (![surfaces requestCPUAccessAtAddress:address
                                          length:length
                                           write:write
                                           error:&error]) {
            /* The callback cannot deny a RAM access. Stop on a host GPU failure
             * rather than letting the vCPU read or overwrite unpreserved data.
             */
            error_report("Metal 4 VRAM access failed: %s",
                         error.localizedDescription.UTF8String);
            abort();
        }
    }
}

/* Layout checks are shared by internal structs and external wire decoding.
 * Layouts depend only on these immutable scalars, not recording generations. */
static BOOL binding_layouts(const NV2AMetalSurfaceBinding parts[2],
                            NV2AMetalSurfaceLayout layouts[2], NSError **error)
{
    memset(layouts, 0, 2 * sizeof(*layouts));
    for (unsigned i = 0; i < 2; i++) {
        NV2AMetalSurfaceConfig c = parts[i].config;
        if (!c.width)
            continue;
        if (c.color != (i == 0) || (c.swizzle != NO && c.swizzle != YES) ||
            (c.floating_depth != NO && c.floating_depth != YES) ||
            !nv2a_metal_surface_layout(&c, &layouts[i], error) ||
            parts[i].address > 0x07ffffffu ||
            layouts[i].reservation_length > 0x08000000u - parts[i].address)
            return pgraph_surface_error(error, @"Invalid bound surface layout");
    }
    if (parts[0].config.width && parts[1].config.width) {
        NV2AMetalSurfaceConfig color = parts[0].config, zeta = parts[1].config;
        if (color.width != zeta.width || color.height != zeta.height ||
            color.scale != zeta.scale ||
            (parts[0].address <
                 parts[1].address + layouts[1].reservation_length &&
             parts[1].address <
                 parts[0].address + layouts[0].reservation_length))
            return pgraph_surface_error(error,
                                        @"Inconsistent bound surface pair");
    }
    return YES;
}
BOOL nv2a_metal_surface_bindings_validate(NV2AMetalSurfaceBindings bindings,
                                          NSError **error)
{
    const NV2AMetalSurfaceBinding parts[] = { bindings.color, bindings.zeta };
    NV2AMetalSurfaceLayout layouts[2];
    return binding_layouts(parts, layouts, error);
}
static BOOL bindings_fit_vram(const NV2AMetalSurfaceBinding parts[2],
                              const NV2AMetalSurfaceLayout layouts[2],
                              NSUInteger length, NSError **error)
{
    for (unsigned i = 0; i < 2; i++) {
        if (parts[i].config.width &&
            (parts[i].address > length ||
             layouts[i].reservation_length > length - parts[i].address))
            return pgraph_surface_error(error, @"Bound surface exceeds VRAM");
    }
    return YES;
}

NSData *nv2a_metal_surface_bindings_encode(NV2AMetalSurfaceBindings bindings)
{
    uint32_t words[17] = { 0x4d345342, 1, 0 };
    NV2AMetalSurfaceBinding parts[] = { bindings.color, bindings.zeta };
    for (unsigned i = 0; i < 2; i++) {
        NV2AMetalSurfaceConfig c = parts[i].config;
        if (!c.width)
            continue;
        words[2] |= 1u << i;
        uint32_t *r = words + 3 + i * 7;
        r[0] = (uint32_t)parts[i].address;
        r[1] = c.format;
        r[2] = c.width;
        r[3] = c.height;
        r[4] = c.pitch;
        r[5] = c.scale;
        r[6] = c.color | c.swizzle << 1 | c.floating_depth << 2;
    }
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(words)];
    for (unsigned i = 0; i < 17; i++)
        stl_be_p((uint8_t *)data.mutableBytes + i * 4, words[i]);
    return [data copy];
}
BOOL nv2a_metal_surface_bindings_decode(NSData *data,
                                        NV2AMetalSurfaceBindings *bindings,
                                        NSError **error)
{
    if (data.length != NV2AMetalSurfaceBindingsBytes)
        return pgraph_surface_error(error,
                                    @"Invalid bound surface packet length");
    uint32_t words[17];
    for (unsigned i = 0; i < 17; i++)
        words[i] = ldl_be_p((const uint8_t *)data.bytes + i * 4);
    if (words[0] != 0x4d345342 || words[1] != 1 || words[2] > 3)
        return pgraph_surface_error(error,
                                    @"Invalid bound surface packet header");
    NV2AMetalSurfaceBindings decoded = { 0 };
    NV2AMetalSurfaceBinding *parts[] = { &decoded.color, &decoded.zeta };
    for (unsigned i = 0; i < 2; i++) {
        uint32_t *r = words + 3 + i * 7;
        if (!(words[2] & (1u << i))) {
            for (unsigned j = 0; j < 7; j++)
                if (r[j])
                    return pgraph_surface_error(error,
                                                @"Nonempty absent surface");
            continue;
        }
        parts[i]->address = r[0];
        parts[i]->config = (NV2AMetalSurfaceConfig){
            .format = r[1],
            .width = r[2],
            .height = r[3],
            .pitch = r[4],
            .scale = r[5],
            .color = !!(r[6] & 1),
            .swizzle = !!(r[6] & 2),
            .floating_depth = !!(r[6] & 4),
        };
        if (!r[2] || r[6] > 7)
            return pgraph_surface_error(error, @"Invalid bound surface layout");
    }
    if (!nv2a_metal_surface_bindings_validate(decoded, error))
        return NO;
    if (bindings)
        *bindings = decoded;
    return YES;
}

@interface NV2AMetalCPUWatch : NSObject
@property(nonatomic) NSUInteger address, end;
@property(nonatomic) MemAccessCallback *callback;
@end
@implementation NV2AMetalCPUWatch
@end

@implementation NV2AMetalPGRAPHSurfaces {
    NV2AState *_d;
    NSMutableArray<NV2AMetalCPUAccess *> *_requests;
    NSMutableArray<NV2AMetalCPUWatch *> *_accesses;
    NV2AMetalCPUAccessContext _accessContext;
    BOOL _closed;
    NV2AMetalClear *_clear;
    bool _requestsPending;
    NV2AMetalCachedSurface *_publishedColor, *_publishedZeta;
    uint64_t _publishedColorEpoch, _publishedZetaEpoch;
    BOOL _publishedColorDirty, _publishedZetaDirty;
}

- (instancetype)initWithState:(NV2AState *)d error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!d || !d->vram || !d->vram_ptr) {
        pgraph_surface_error(error, @"Native surfaces require live NV2A VRAM");
        return nil;
    }
    NSUInteger length = memory_region_size(d->vram);
    NSUInteger page = (NSUInteger)getpagesize();
    if (!length || length % page || (uintptr_t)d->vram_ptr % page ||
        d->vram_ptr != memory_region_get_ram_ptr(d->vram)) {
        pgraph_surface_error(error,
                             @"NV2A VRAM must be page-aligned shared RAM");
        return nil;
    }
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithError:error];
    if (!commands) {
        return nil;
    }
    id<MTLBuffer> vram =
        [commands.device newBufferWithBytesNoCopy:d->vram_ptr
                                           length:length
                                          options:MTLResourceStorageModeShared
                                      deallocator:nil];
    if (!vram || vram.contents != d->vram_ptr) {
        pgraph_surface_error(error, @"Cannot wrap NV2A VRAM without copying");
        return nil;
    }
    _d = d;
    _requests = [NSMutableArray new];
    _cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:commands
                    vram:vram
            didWriteVRAM:^(NSUInteger address, NSUInteger size) {
              memory_region_set_client_dirty(d->vram, address, size,
                                             DIRTY_MEMORY_VGA);
              memory_region_set_client_dirty(d->vram, address, size,
                                             DIRTY_MEMORY_NV2A_TEX);
            }
                   error:error];
    if (!_cache) {
        return nil;
    }
    _accesses = [NSMutableArray new];
    if (tcg_enabled()) {
        _accessContext.surfaces = (__bridge void *)self;
        _accessContext.guard = _cache.cpuAccessGuard;
        __weak NV2AMetalPGRAPHSurfaces *owner = self;
        _cache.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
          [owner watchAddress:address length:length];
        };
    }
    return self;
}

- (void)watchAddress:(NSUInteger)address length:(NSUInteger)length
{
    NSUInteger end = address + length;
    NSMutableArray<NV2AMetalCPUWatch *> *replaced = [NSMutableArray new];
    for (NV2AMetalCPUWatch *watch in _accesses) {
        if (watch.end < address || end < watch.address)
            continue;
        if (watch.address <= address && end <= watch.end)
            return;
        address = MIN(address, watch.address);
        end = MAX(end, watch.end);
        [replaced addObject:watch];
    }
    NV2AMetalCPUWatch *watch = [NV2AMetalCPUWatch new];
    watch.address = address;
    watch.end = end;
    /* Install the union before retiring older hooks. QEMU queues these
     * operations and their TLB flushes on the CPU, as in the official backends.
     * There must never be an unprotected gap while replacing watched ranges. */
    watch.callback = mem_access_callback_insert(
        qemu_get_cpu(0), _d->vram, address, end - address,
        pgraph_metal_cpu_access, &_accessContext);
    assert(watch.callback);
    [_accesses addObject:watch];
    for (NV2AMetalCPUWatch *old in replaced) {
        mem_access_callback_remove_by_ref(qemu_get_cpu(0), old.callback);
        [_accesses removeObjectIdenticalTo:old];
    }
}

- (void)dealloc
{
    /* The VM owns the aliased RAM and the callback list. */
    assert(!_accesses.count && !_requests.count);
}

- (NV2AMetalCachedSurface *)prepare:(BOOL)color
                       forRendering:(BOOL)forRendering
                              error:(NSError **)error
{
    PGRAPHState *pg = &_d->pgraph;
    Surface *s = color ? &pg->surface_color : &pg->surface_zeta;
    SurfaceShape shape = pg->surface_shape;
    BOOL swizzle = pg->surface_type == NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
    uint64_t width, height;
    if (!color && _color.valid) {
        width = _color.transfer.config.width;
        height = _color.transfer.config.height;
    } else {
        if (swizzle) {
            if (shape.log_width > 14 || shape.log_height > 14) {
                pgraph_surface_error(
                    error, @"Invalid swizzled NV2A surface dimensions");
                return nil;
            }
            width = 1ull << shape.log_width;
            height = 1ull << shape.log_height;
        } else {
            width = shape.clip_width;
            height = shape.clip_height;
        }
        switch (shape.anti_aliasing) {
        case NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_CENTER_1:
            break;
        case NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_CENTER_CORNER_2:
            width *= 2;
            break;
        case NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4:
            width *= 2;
            height *= 2;
            break;
        default:
            pgraph_surface_error(error,
                                 @"Invalid NV2A surface antialiasing mode");
            return nil;
        }
        if (!swizzle) {
            width += shape.clip_x;
            height += shape.clip_y;
        }
    }
    if (!width || !height || width > UINT32_MAX || height > UINT32_MAX) {
        pgraph_surface_error(error,
                             @"Empty or overflowing NV2A surface extent");
        return nil;
    }
    uint32_t setup = pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER);
    NV2AMetalSurfaceConfig c = {
        .format = color ? shape.color_format : shape.zeta_format,
        .width = (unsigned int)width,
        .height = (unsigned int)height,
        .pitch = s->pitch,
        .scale = pg->surface_scale_factor,
        .color = color,
        .swizzle = swizzle,
        .floating_depth = !!(setup & NV_PGRAPH_SETUPRASTER_Z_FORMAT),
    };
    NV2AMetalSurfaceLayout layout;
    if (!nv2a_metal_surface_layout(&c, &layout, error)) {
        return nil;
    }
    DMAObject dma = nv_dma_load(_d, color ? pg->dma_color : pg->dma_zeta);
    if (dma.dma_class != NV_DMA_IN_MEMORY_CLASS ||
        (dma.address & ~0x07ffffffull) || s->offset > dma.limit ||
        layout.reservation_length > dma.limit - s->offset + 1 ||
        dma.address > _cache.vram.length ||
        s->offset > _cache.vram.length - dma.address ||
        layout.reservation_length >
            _cache.vram.length - dma.address - s->offset) {
        pgraph_surface_error(
            error, @"NV2A surface DMA span exceeds its limit or VRAM");
        return nil;
    }
    NSUInteger address = dma.address + s->offset;
    if (!tcg_enabled() &&
        memory_region_test_and_clear_dirty(
            _d->vram, address, layout.reservation_length, DIRTY_MEMORY_NV2A)) {
        /* A dirty-page notification arrives after the CPU write. Normally such
         * hosts must drain writes every draw, as GL does, before a later
         * upload. */
        if (![_cache observeCPUWriteAtAddress:address
                                       length:layout.reservation_length
                                        error:error]) {
            memory_region_set_client_dirty(_d->vram, address,
                                           layout.reservation_length,
                                           DIRTY_MEMORY_NV2A);
            return nil;
        }
    }
    NV2AMetalCachedSurface *entry =
        [_cache prepareSurfaceAtAddress:address
                                 config:&c
                                  frame:(uint32_t)pg->frame_time
                           forRendering:forRendering
                                  error:error];
    if (entry) {
        s->buffer_dirty = false;
        pg->surface_binding_dim.width = entry.transfer.config.width;
        pg->surface_binding_dim.height = entry.transfer.config.height;
        pg->surface_binding_dim.clip_x = shape.clip_x;
        pg->surface_binding_dim.clip_y = shape.clip_y;
        pg->surface_binding_dim.clip_width = shape.clip_width;
        pg->surface_binding_dim.clip_height = shape.clip_height;
    }
    return entry;
}

- (BOOL)prepareCurrentAttachments:(NSError **)error
{
    return [self prepareCurrentAttachments:error forRendering:YES];
}
- (BOOL)prepareCurrentAttachments:(NSError **)error
                     forRendering:(BOOL)forRendering
{
    /* Replacing the second attachment can submit the first attachment's
     * upload. Capture both live entries in the resulting recording. */
    NV2AMetalCachedSurface *parts[] = { _color, _zeta };
    for (unsigned i = 0; i < 2; i++) {
        NV2AMetalCachedSurface *entry = parts[i];
        if (!entry)
            continue;
        if (!entry.valid)
            return pgraph_surface_error(error, @"Invalid bound attachment");
        NV2AMetalSurfaceConfig config = entry.transfer.config;
        if (![_cache prepareSurfaceAtAddress:entry.address
                                      config:&config
                                       frame:(uint32_t)_d->pgraph.frame_time
                                forRendering:forRendering
                                       error:error])
            return NO;
    }
    return YES;
}

- (BOOL)prepareColor:(BOOL)color zeta:(BOOL)zeta error:(NSError **)error
{
    return [self prepareColor:color zeta:zeta forRendering:YES error:error];
}
- (BOOL)prepareColor:(BOOL)color
                zeta:(BOOL)zeta
        forRendering:(BOOL)forRendering
               error:(NSError **)error
{
    if (qatomic_read(&_closed)) {
        return pgraph_surface_error(error,
                                    @"Native PGRAPH surfaces are closed");
    }
    PGRAPHState *pg = &_d->pgraph;
    pg->surface_shape.z_format = !!(pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER) &
                                    NV_PGRAPH_SETUPRASTER_Z_FORMAT);
    if (memcmp(&pg->surface_shape, &pg->last_surface_shape,
               sizeof(SurfaceShape)) &&
        (pg->surface_shape.color_format || pg->surface_shape.zeta_format)) {
        pg->last_surface_shape = pg->surface_shape;
        pg->surface_color.buffer_dirty = pg->surface_zeta.buffer_dirty = true;
    }
    if (![_cache evictBeforeFrame:(uint32_t)_d->pgraph.frame_time
                            error:error]) {
        return NO;
    }
    if (color) {
        _color = [self prepare:YES forRendering:forRendering error:error];
        if (!_color) {
            return NO;
        }
    } else {
        _color = nil;
    }
    if (zeta) {
        _zeta = [self prepare:NO forRendering:forRendering error:error];
        if (!_zeta) {
            return NO;
        }
        if (_color && (!_color.valid || !_zeta.valid)) {
            return pgraph_surface_error(
                error, @"Overlapping NV2A color/zeta attachments");
        }
    } else {
        _zeta = nil;
    }
    return [self prepareCurrentAttachments:error forRendering:forRendering];
}

- (NV2AMetalSurfaceBindings)captureBindings
{
    NV2AMetalSurfaceBindings result = { 0 };
    if (_color)
        result.color =
            (NV2AMetalSurfaceBinding){ _color.transfer.config, _color.address };
    if (_zeta)
        result.zeta =
            (NV2AMetalSurfaceBinding){ _zeta.transfer.config, _zeta.address };
    return result;
}
- (BOOL)prepareBindings:(NV2AMetalSurfaceBindings)bindings
                  error:(NSError **)error
{
    return [self prepareBindings:bindings forRendering:YES error:error];
}
- (BOOL)prepareBindings:(NV2AMetalSurfaceBindings)bindings
           forRendering:(BOOL)forRendering
                  error:(NSError **)error
{
    if (qatomic_read(&_closed))
        return pgraph_surface_error(error,
                                    @"Native PGRAPH surfaces are closed");
    NV2AMetalSurfaceBinding parts[] = { bindings.color, bindings.zeta };
    NV2AMetalSurfaceLayout layouts[2];
    if (!binding_layouts(parts, layouts, error))
        return NO;
    unsigned scale = _d->pgraph.surface_scale_factor;
    BOOL rescale = NO;
    for (unsigned i = 0; i < 2; i++) {
        if (parts[i].config.width) {
            rescale |= parts[i].config.scale != scale;
            parts[i].config.scale = scale;
        }
    }
    id<MTLBuffer> vram = _cache.vram;
    NSUInteger length = vram.length;
    /* Both spans validate before eviction/texture allocation. Reuse layouts
     * when captured scale is current, retaining validation on scale changes. */
    if ((rescale && !binding_layouts(parts, layouts, error)) ||
        !bindings_fit_vram(parts, layouts, length, error))
        return NO;
    if (![_cache evictBeforeFrame:(uint32_t)_d->pgraph.frame_time error:error])
        return NO;
    NV2AMetalCachedSurface *prepared[2] = { nil, nil };
    for (unsigned i = 0; i < 2; i++) {
        /* Downloads/eviction may cross a recording boundary. A new scale or
         * backing range invalidates the pure layout result; recording changes
         * alone do not. Cache preparation keeps its normal health checks. */
        if (scale != _d->pgraph.surface_scale_factor || vram != _cache.vram ||
            length != _cache.vram.length) {
            scale = _d->pgraph.surface_scale_factor;
            vram = _cache.vram;
            length = vram.length;
            for (unsigned j = 0; j < 2; j++)
                if (parts[j].config.width)
                    parts[j].config.scale = scale;
            if (!binding_layouts(parts, layouts, error) ||
                !bindings_fit_vram(parts, layouts, length, error))
                return NO;
        }
        NV2AMetalSurfaceConfig c = parts[i].config;
        if (!c.width)
            continue;
        NV2AMetalSurfaceLayout layout = layouts[i];
        if (!tcg_enabled() &&
            memory_region_test_and_clear_dirty(_d->vram, parts[i].address,
                                               layout.reservation_length,
                                               DIRTY_MEMORY_NV2A)) {
            if (![_cache observeCPUWriteAtAddress:parts[i].address
                                           length:layout.reservation_length
                                            error:error]) {
                memory_region_set_client_dirty(_d->vram, parts[i].address,
                                               layout.reservation_length,
                                               DIRTY_MEMORY_NV2A);
                return NO;
            }
        }
        prepared[i] =
            [_cache prepareSurfaceAtAddress:parts[i].address
                                     config:&c
                                      frame:(uint32_t)_d->pgraph.frame_time
                               forRendering:forRendering
                                      error:error];
        if (!prepared[i])
            return NO;
    }
    if (prepared[0] && prepared[1] &&
        (!prepared[0].valid || !prepared[1].valid))
        return pgraph_surface_error(error, @"Overlapping bound attachments");
    _color = prepared[0];
    _zeta = prepared[1];
    return [self prepareCurrentAttachments:error forRendering:forRendering];
}
- (BOOL)releaseColor:(BOOL)color zeta:(BOOL)zeta error:(NSError **)error
{
    if (qatomic_read(&_closed))
        return pgraph_surface_error(error,
                                    @"Native PGRAPH surfaces are closed");
    PGRAPHState *pg = &_d->pgraph;
    BOOL selected[] = {
        pg->surface_color.draw_dirty &&
            ((color && (pg->clearing || pgraph_color_write_enabled(pg))) ||
             pg->surface_color.write_enabled_cache),
        pg->surface_zeta.draw_dirty &&
            ((zeta && (pg->clearing || pgraph_zeta_write_enabled(pg))) ||
             pg->surface_zeta.write_enabled_cache)
    };
    if (!tcg_enabled()) {
        if (![self downloadColor:selected[0] zeta:selected[1] error:error])
            return NO;
    } else {
        BOOL completed;
        if (![_cache tryIdleCPUAccessAtAddress:0
                                        length:0
                                         write:NO
                                     completed:&completed
                                         error:error])
            return NO;
    }
    /* Retain cache.dirty and its CPU hooks. Only the guest binding's release
     * bookkeeping changes here, matching GL/VK update_surface_part. */
    Surface *parts[] = { &pg->surface_color, &pg->surface_zeta };
    for (unsigned i = 0; i < 2; i++) {
        if (selected[i]) {
            parts[i]->write_enabled_cache = false;
            parts[i]->draw_dirty = false;
        }
    }
    return YES;
}

- (BOOL)downloadColor:(BOOL)color zeta:(BOOL)zeta error:(NSError **)error
{
    if (qatomic_read(&_closed))
        return pgraph_surface_error(error,
                                    @"Native PGRAPH surfaces are closed");
    NV2AMetalCachedSurface *parts[] = { color ? _color : nil,
                                        zeta ? _zeta : nil };
    for (unsigned i = 0; i < 2; i++)
        if (parts[i].valid && parts[i].dirty &&
            ![_cache prepareCPUAccessAtAddress:parts[i].address
                                        length:parts[i].reservationLength
                                         write:NO
                                         error:error])
            return NO;
    _d->pgraph.surface_color.draw_dirty = _color.dirty;
    _d->pgraph.surface_zeta.draw_dirty = _zeta.dirty;
    return YES;
}

- (BOOL)prepareClearColor:(BOOL)color zeta:(BOOL)zeta error:(NSError **)error
{
    PGRAPHState *pg = &_d->pgraph;
    pg->surface_shape.z_format = !!(pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER) &
                                    NV_PGRAPH_SETUPRASTER_Z_FORMAT);
    BOOL was_clearing = pg->clearing;
    pg->clearing = true;
    BOOL shape_changed =
        memcmp(&pg->surface_shape, &pg->last_surface_shape,
               sizeof(SurfaceShape)) &&
        (pg->surface_shape.color_format || pg->surface_shape.zeta_format);
    NV2AMetalCachedSurface *retainedColor =
        !color && !shape_changed && !pg->surface_color.buffer_dirty ? _color :
                                                                      nil;
    NV2AMetalCachedSurface *retainedZeta =
        !zeta && !shape_changed && !pg->surface_zeta.buffer_dirty ? _zeta : nil;
    BOOL ok = [self prepareColor:color zeta:zeta error:error];
    NV2AMetalCachedSurface *retained[] = { retainedColor, retainedZeta };
    for (unsigned i = 0; ok && i < 2; i++) {
        NV2AMetalCachedSurface *old = retained[i];
        NV2AMetalCachedSurface *other = i ? _color : _zeta;
        if (!old.valid)
            continue;
        if (other &&
            (old.transfer.texture.width != other.transfer.texture.width ||
             old.transfer.texture.height != other.transfer.texture.height)) {
            (i ? &pg->surface_zeta : &pg->surface_color)->buffer_dirty = true;
            continue;
        }
        NV2AMetalSurfaceConfig config = old.transfer.config;
        NV2AMetalCachedSurface *prepared =
            [_cache prepareSurfaceAtAddress:old.address
                                     config:&config
                                      frame:(uint32_t)pg->frame_time
                                      error:error];
        ok = prepared != nil;
        if (i)
            _zeta = prepared;
        else
            _color = prepared;
    }
    pg->clearing = was_clearing;
    return ok && [self prepareCurrentAttachments:error];
}

- (BOOL)clearSurface:(uint32_t)parameter error:(NSError **)error
{
    PGRAPHState *pg = &_d->pgraph;
    BOOL color = !!(parameter & NV097_CLEAR_SURFACE_COLOR);
    BOOL zeta =
        !!(parameter & (NV097_CLEAR_SURFACE_Z | NV097_CLEAR_SURFACE_STENCIL));
    if (qatomic_read(&_closed)) {
        return pgraph_surface_error(error,
                                    @"Native PGRAPH surfaces are closed");
    }
    if (!color && !zeta) {
        return [self prepareClearColor:NO zeta:NO error:error];
    }
    if (color) {
        unsigned format = pg->surface_shape.color_format;
        if ((format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5 &&
             format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5 &&
             format != NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5 &&
             format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8 &&
             format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8 &&
             format !=
                 NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8 &&
             format !=
                 NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8 &&
             format != NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8)) {
            return pgraph_surface_error(error,
                                        @"Invalid native clear color format");
        }
    }
    uint32_t x = pgraph_reg_r(pg, NV_PGRAPH_CLEARRECTX);
    uint32_t y = pgraph_reg_r(pg, NV_PGRAPH_CLEARRECTY);
    NSUInteger xmin = x & NV_PGRAPH_CLEARRECTX_XMIN;
    NSUInteger xmax = (x & NV_PGRAPH_CLEARRECTX_XMAX) >> 16;
    NSUInteger ymin = y & NV_PGRAPH_CLEARRECTY_YMIN;
    NSUInteger ymax = (y & NV_PGRAPH_CLEARRECTY_YMAX) >> 16;
    if (xmax < xmin || ymax < ymin) {
        return pgraph_surface_error(error, @"Inverted NV2A clear rectangle");
    }
    unsigned aa = pg->surface_shape.anti_aliasing;
    if (aa > NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4) {
        return pgraph_surface_error(error,
                                    @"Invalid NV2A clear antialiasing mode");
    }
    NSUInteger sx = pg->surface_scale_factor * (aa ? 2ull : 1ull);
    NSUInteger sy =
        pg->surface_scale_factor *
        (aa == NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4 ? 2ull :
                                                                        1ull);
    NV2AMetalClearConfig c = {
        .parameter = parameter,
        .dither = !!(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0) &
                     NV_PGRAPH_CONTROL_0_DITHERENABLE),
        .rect = { xmin * sx, ymin * sy, (xmax - xmin + 1) * sx,
                  (ymax - ymin + 1) * sy },
    };
    pg->surface_shape.z_format = !!(pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER) &
                                    NV_PGRAPH_SETUPRASTER_Z_FORMAT);
    if (color) {
        unsigned format = pg->surface_shape.color_format;
        if (format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8 ||
            format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8) {
            // Common GL clear helper asserts for these untested formats. Keep
            // the native raw A7 field and force its storage bit independently.
            uint32_t value = pgraph_reg_r(pg, NV_PGRAPH_COLORCLEARVALUE);
            c.uniforms.color[0] = ((value >> 16) & 255) / 255.f;
            c.uniforms.color[1] = ((value >> 8) & 255) / 255.f;
            c.uniforms.color[2] = (value & 255) / 255.f;
            unsigned alpha = (value >> 24) & 127;
            if (format ==
                NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8)
                alpha |= 128;
            c.uniforms.color[3] = alpha / 255.f;
        } else {
            pgraph_get_clear_color(pg, c.uniforms.color);
        }
        if (pg->surface_shape.color_format ==
                NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5 ||
            pg->surface_shape.color_format ==
                NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8)
            c.uniforms.color[3] = 0;
        else if (pg->surface_shape.color_format ==
                     NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5 ||
                 pg->surface_shape.color_format ==
                     NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8)
            c.uniforms.color[3] = 1;
    }
    if (zeta) {
        int stencil;
        if (pg->surface_shape.zeta_format !=
                NV097_SET_SURFACE_FORMAT_ZETA_Z16 &&
            pg->surface_shape.zeta_format !=
                NV097_SET_SURFACE_FORMAT_ZETA_Z24S8) {
            return pgraph_surface_error(error,
                                        @"Invalid NV2A clear zeta format");
        }
        pgraph_get_clear_depth_stencil_value(pg, &c.uniforms.depth, &stencil);
        if (pg->surface_shape.z_format) {
            uint32_t raw = pgraph_reg_r(pg, NV_PGRAPH_ZSTENCILCLEARVALUE);
            c.uniforms.depth = pg->surface_shape.zeta_format ==
                                       NV097_SET_SURFACE_FORMAT_ZETA_Z16 ?
                                   (raw & 65535) / 65535.f :
                                   (raw >> 8) / 16777215.f;
        }
        c.stencil = (unsigned int)stencil;
    }
    if (!_clear) {
        _clear = [[NV2AMetalClear alloc] initWithDevice:_cache.commands.device
                                                  error:error];
        if (!_clear) {
            return NO;
        }
    }
    BOOL was_clearing = pg->clearing;
    pg->clearing = true;
    BOOL ok = [self prepareClearColor:color zeta:zeta error:error];
    if (ok) {
        ok = [_clear encodeColor:_color.transfer.texture
                            zeta:_zeta.transfer.texture
                          config:&c
                        commands:_cache.commands
                           error:error];
    }
    if (ok) {
        id<MTLTexture> target =
            _color ? _color.transfer.texture : _zeta.transfer.texture;
        BOOL covered = c.rect.width && c.rect.height &&
                       c.rect.x < target.width && c.rect.y < target.height;
        BOOL writes_zeta = (parameter & NV097_CLEAR_SURFACE_Z) ||
                           ((parameter & NV097_CLEAR_SURFACE_STENCIL) &&
                            _zeta.transfer.texture.pixelFormat ==
                                MTLPixelFormatDepth32Float_Stencil8);
        if (covered && (color || writes_zeta)) {
            ok = [self markColorWritten:color
                            zetaWritten:writes_zeta
                                  error:error];
        }
    }
    pg->clearing = was_clearing;
    if (!ok) {
        [_cache cancel];
    }
    return ok;
}

- (BOOL)markColorWritten:(BOOL)color
             zetaWritten:(BOOL)zeta
                   error:(NSError **)error
{
    if (qatomic_read(&_closed) ||
        (color && (!_color || ![_cache markWritten:_color error:error])) ||
        (zeta && (!_zeta || ![_cache markWritten:_zeta error:error]))) {
        return pgraph_surface_error(
            error, @"Invalid native PGRAPH written attachments");
    }
    _d->pgraph.surface_color.draw_dirty |= color;
    _d->pgraph.surface_zeta.draw_dirty |= zeta;
    if (!tcg_enabled()) {
        BOOL ok = [_cache prepareCPUAccessAtAddress:0
                                             length:_cache.vram.length
                                              write:NO
                                              error:error];
        _d->pgraph.surface_color.draw_dirty = _color.dirty;
        _d->pgraph.surface_zeta.draw_dirty = _zeta.dirty;
        return ok;
    }
    return YES;
}

- (BOOL)flushWithError:(NSError **)error
{
    if (qatomic_read(&_closed)) {
        return pgraph_surface_error(error,
                                    @"Native PGRAPH surfaces are closed");
    }
    if (![_cache flushWithError:error]) {
        return NO;
    }
    _color = _zeta = nil;
    _publishedColor = _publishedZeta = nil;
    _d->pgraph.surface_color.draw_dirty = _d->pgraph.surface_zeta.draw_dirty =
        false;
    _d->pgraph.surface_color.buffer_dirty =
        _d->pgraph.surface_zeta.buffer_dirty = true;
    return YES;
}

- (BOOL)discardForRestoreWithError:(NSError **)error
{
    if (qatomic_read(&_closed)) {
        return pgraph_surface_error(error,
                                    @"Native PGRAPH surfaces are closed");
    }
    if (![_cache discardForRestoreWithError:error]) {
        return NO;
    }
    _color = _zeta = nil;
    _publishedColor = _publishedZeta = nil;
    _d->pgraph.surface_color.draw_dirty = _d->pgraph.surface_zeta.draw_dirty =
        false;
    _d->pgraph.surface_color.buffer_dirty =
        _d->pgraph.surface_zeta.buffer_dirty = true;
    return YES;
}

- (BOOL)closeWithError:(NSError **)error
{
    if (qatomic_read(&_closed)) {
        return YES;
    }
    if (![self flushWithError:error] || _requests.count) {
        return pgraph_surface_error(
            error, @"Cannot close native surfaces with outstanding work");
    }
    _cache.willWatchVRAM = nil;
    for (NV2AMetalCPUWatch *watch in _accesses)
        mem_access_callback_remove_by_ref(qemu_get_cpu(0), watch.callback);
    [_accesses removeAllObjects];
    qatomic_set(&_closed, YES);
    return YES;
}

- (BOOL)requestCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                            error:(NSError **)error
{
    if (qatomic_read(&_closed) || address > _cache.vram.length ||
        length > _cache.vram.length - address)
        return pgraph_surface_error(error,
                                    @"Invalid or closed CPU VRAM access");
    BOOL completed = NO;
    BOOL ok = [_cache tryIdleCPUAccessAtAddress:address
                                         length:length
                                          write:write
                                      completed:&completed
                                          error:error];
    if (!ok || completed)
        return ok;
    /* Release the cache's metadata guard before taking PGRAPH. Register/RDI
     * accesses remain serialized while unrelated RAM can pass private XF. */
    qemu_mutex_lock(&_d->pgraph.lock);
    if (qatomic_read(&_closed)) {
        qemu_mutex_unlock(&_d->pgraph.lock);
        return pgraph_surface_error(error,
                                    @"Invalid or closed CPU VRAM access");
    }
    ok = [_cache tryIdleCPUAccessAtAddress:address
                                  length:length
                                   write:write
                               completed:&completed
                                   error:error];
    if (!ok || completed) {
        qemu_mutex_unlock(&_d->pgraph.lock);
        return ok;
    }
    NV2AMetalCPUAccess *request = [NV2AMetalCPUAccess new];
    request.address = address;
    request.length = length;
    request.write = write;
    [_requests addObject:request];
    qatomic_set(&_requestsPending, true);
    qemu_mutex_unlock(&_d->pgraph.lock);
    /* Interrupt delivery can access RAM with BQL held. The FIFO worker may
     * need BQL to deliver a notification before servicing this request. */
    bool had_bql = bql_locked();
    if (had_bql)
        bql_unlock();
    qemu_mutex_lock(&_d->pfifo.lock);
    pfifo_kick(_d);
    qemu_mutex_unlock(&_d->pfifo.lock);
    qemu_event_wait(&request->complete);
    if (had_bql)
        bql_lock();
    if (request.failure) {
        if (error) {
            *error = request.failure;
        }
        return NO;
    }
    return YES;
}

- (BOOL)processPendingWithError:(NSError **)error
{
    qemu_mutex_unlock(&_d->pfifo.lock);
    qemu_mutex_lock(&_d->pgraph.lock);
    BOOL ok = [self processCPURequestsWithError:error];
    qemu_mutex_unlock(&_d->pgraph.lock);
    qemu_mutex_lock(&_d->pfifo.lock);
    return ok;
}

- (BOOL)needsCPUService
{
    return qatomic_read(&_requestsPending) || _color != _publishedColor ||
           _zeta != _publishedZeta || _publishedColorEpoch == UINT64_MAX ||
           _publishedZetaEpoch == UINT64_MAX ||
           _color.dirtyEpoch != _publishedColorEpoch ||
           _zeta.dirtyEpoch != _publishedZetaEpoch ||
           _d->pgraph.surface_color.draw_dirty != _publishedColorDirty ||
           _d->pgraph.surface_zeta.draw_dirty != _publishedZetaDirty;
}
- (BOOL)processCPURequestsWithError:(NSError **)error
{
    NSArray<NV2AMetalCPUAccess *> *requests = [_requests copy];
    [_requests removeAllObjects];
    qatomic_set(&_requestsPending, false);
    NSError *failure = nil;
    for (NV2AMetalCPUAccess *request in requests) {
        NSError *one = nil;
        if (![_cache prepareCPUAccessAtAddress:request.address
                                        length:request.length
                                         write:request.write
                                         error:&one]) {
            if (!one) {
                pgraph_surface_error(&one,
                                     @"Native CPU VRAM synchronization failed");
            }
            request.failure = one;
            failure = one;
        }
        qemu_event_set(&request->complete);
    }
    /* A stamp taken before the locked getter is conservative if another CPU
     * changes the cache during/after publication: the next precheck retries. */
    _publishedColor = _color;
    _publishedZeta = _zeta;
    _publishedColorEpoch = _color.dirtyEpoch;
    _publishedZetaEpoch = _zeta.dirtyEpoch;
    _d->pgraph.surface_color.draw_dirty = _publishedColorDirty = _color.dirty;
    _d->pgraph.surface_zeta.draw_dirty = _publishedZetaDirty = _zeta.dirty;
    if (failure && error) {
        *error = failure;
    }
    return failure == nil;
}
@end
