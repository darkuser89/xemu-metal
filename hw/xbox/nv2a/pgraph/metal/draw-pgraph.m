/* Native PGRAPH draw orchestration from gl/draw.c and gl/surface.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "draw-pgraph.h"
#import "fetch-pgraph.h"
#import "vertex-pgraph.h"
#import "vertex-epoch.h"
#import "input-checkpoint.h"
#import "pending-pgraph.h"
#import "pending-native.h"
#import "state-pgraph.h"
#import "archive-native.h"
#import "pixel-pgraph.h"
#import "geometry.h"
#import "lru-cache.h"
#include "renderer.h"

static BOOL pgraph_draw_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pgraph-draw"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
static NV2AMetalPGRAPHVertexState *capture_only(PGRAPHState *pg,
                                                NSError **error)
{
    return [[NV2AMetalPGRAPHVertexState alloc] initRawXFWithState:pg
                                                            error:error];
}
/* Current must be host-readable. New XF output additionally needs a proven
 * nonwriting, fault-free context. Fully accepted prefixes execute no XF and
 * must neither wait for new feedback nor replay earlier context stores. */
static BOOL can_queue_captured_context(NV2AMetalPGRAPHFetch *fetch,
                                       NV2AMetalPendingInput *input,
                                       NV2AMetalPGRAPHVertexState *vertex,
                                       BOOL suffix)
{
    return vertex &&
           (!suffix || !vertex.programmed ||
            ((!vertex.writeEnable ||
              !vertex.validatedProgram.mayWriteConstants) &&
             vertex.faultFreeReadOnlyAccess)) &&
           [fetch canCaptureCurrentForInput:input];
}
static NV2AMetalGeometryRasterConfig raster_config(PGRAPHState *pg)
{
    unsigned setup = pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER);
    unsigned cull = setup & NV_PGRAPH_SETUPRASTER_CULLENABLE ?
                        GET_MASK(setup, NV_PGRAPH_SETUPRASTER_CULLCTRL) :
                        0;
    /* Vertex processing negates GL NDC Y for Metal, reversing the clip-space
     * determinant used by the geometry stage to classify polygon faces. */
    NV2AMetalGeometryRasterConfig result = {
        .front = GET_MASK(setup, NV_PGRAPH_SETUPRASTER_FRONTFACEMODE),
        .back = GET_MASK(setup, NV_PGRAPH_SETUPRASTER_BACKFACEMODE),
        .frontClockwise = !(setup & NV_PGRAPH_SETUPRASTER_FRONTFACE),
        .cullFront = cull == NV_PGRAPH_SETUPRASTER_CULLCTRL_FRONT ||
                     cull == NV_PGRAPH_SETUPRASTER_CULLCTRL_FRONT_AND_BACK,
        .cullBack = cull == NV_PGRAPH_SETUPRASTER_CULLCTRL_BACK ||
                    cull == NV_PGRAPH_SETUPRASTER_CULLCTRL_FRONT_AND_BACK,
        .lineWidth = pg->surface_scale_factor,
        .lineSmooth = !(pgraph_reg_r(pg, NV_PGRAPH_ANTIALIASING) &
                        NV_PGRAPH_ANTIALIASING_ENABLE) &&
                      !!(setup & NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE),
        .polygonSmooth = !(pgraph_reg_r(pg, NV_PGRAPH_ANTIALIASING) &
                           NV_PGRAPH_ANTIALIASING_ENABLE) &&
                         !!(setup & NV_PGRAPH_SETUPRASTER_POLYSMOOTHENABLE),
    };
    return result;
}
enum { BeginCaptureWords = 11 };
typedef struct BeginCapture {
    uint32_t primitive, control, stencil;
    BOOL nop, firstProvoking;
    NV2AMetalGeometryRasterConfig geometry;
    NSData *pixel, *textures;
    BOOL hasBindings;
    NV2AMetalSurfaceBindings bindings;
} BeginCapture;
static BOOL begin_decode(NSData *data, BeginCapture *capture, NSError **error)
{
    if (data.length < BeginCaptureWords * 4)
        return pgraph_draw_error(error, @"Truncated Begin capture");
    const uint8_t *bytes = data.bytes;
    uint32_t words[BeginCaptureWords];
    for (unsigned i = 0; i < BeginCaptureWords; i++)
        words[i] = ldl_be_p(bytes + i * 4);
    BOOL version3 = words[1] == 3;
    BOOL version2 = words[1] == 2 || version3;
    NSUInteger header = (BeginCaptureWords + version2) * 4;
    if (data.length < header)
        return pgraph_draw_error(error, @"Truncated Begin v2 header");
    NSUInteger textureSize = version2 ? (uint32_t)ldl_be_p(bytes + 44) : 0;
    float lineWidth;
    memcpy(&lineWidth, words + 9, 4);
    BOOL nop = words[5] & 1;
    NSUInteger bindingSize =
        version3 && !nop ? NV2AMetalSurfaceBindingsBytes : 0;
    BOOL no_access = !(words[3] & (NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                   NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                   NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                   NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                                   NV_PGRAPH_CONTROL_0_ZENABLE)) &&
                     !(words[4] & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE);
    if (words[0] != 0x4d344243 || (words[1] != 1 && !version2) ||
        words[2] < PRIM_TYPE_POINTS || words[2] > PRIM_TYPE_POLYGON ||
        words[5] > 3 || words[6] > (nop ? 3u : 2u) ||
        words[7] > (nop ? 3u : 2u) || words[8] > 31 || !isfinite(lineWidth) ||
        lineWidth <= 0 || lineWidth > 16384 || no_access != nop ||
        words[10] > 16384 ||
        textureSize > NV2A_METAL_BEGIN_CAPTURE_MAX - header - words[10] ||
        data.length != header + words[10] + textureSize + bindingSize ||
        (nop ? (words[10] || textureSize) : !words[10]) ||
        (version2 && !nop && textureSize < 12))
        return pgraph_draw_error(error, @"Invalid Begin capture metadata");
    NSData *pixel = [data subdataWithRange:NSMakeRange(header, words[10])];
    NSData *textures =
        textureSize ? [data subdataWithRange:NSMakeRange(header + words[10],
                                                         textureSize)] :
                      nil;
    if (textures && ![NV2AMetalPGRAPHTextureSnapshot validateSnapshot:textures
                                                                error:error])
        return NO;
    uint32_t mask =
        textures ? (uint32_t)ldl_be_p((const uint8_t *)textures.bytes + 8) : 0;
    if (!nop && ![NV2AMetalPGRAPHPixelState validateBoundSnapshot:pixel
                                                          control:words[3]
                                                          stencil:words[4]
                                                      textureMask:mask
                                                         textures:textures])
        return pgraph_draw_error(error, @"Inconsistent Begin pixel capture");
    NV2AMetalSurfaceBindings bindings = { 0 };
    if (bindingSize) {
        NSData *bound =
            [data subdataWithRange:NSMakeRange(header + words[10] + textureSize,
                                               bindingSize)];
        if (!nv2a_metal_surface_bindings_decode(bound, &bindings, error))
            return NO;
    }
    if (capture) {
        capture->hasBindings = !!bindingSize;
        capture->bindings = bindings;
        capture->primitive = words[2];
        capture->control = words[3];
        capture->stencil = words[4];
        capture->nop = nop;
        capture->firstProvoking = !!(words[5] & 2);
        capture->geometry = (NV2AMetalGeometryRasterConfig){
            .front = words[6],
            .back = words[7],
            /* Begin versions 1-3 store the original SETUPRASTER front bit. */
            .frontClockwise = !(words[8] & 1),
            .cullFront = !!(words[8] & 2),
            .cullBack = !!(words[8] & 4),
            .lineSmooth = !!(words[8] & 8),
            .polygonSmooth = !!(words[8] & 16),
            .lineWidth = lineWidth,
        };
        capture->pixel = pixel;
        capture->textures = textures;
    }
    return YES;
}
bool pgraph_metal4_validate_begin_capture(const uint8_t *bytes, size_t size)
{
    if (!bytes || size < BeginCaptureWords * 4 ||
        size > NV2A_METAL_BEGIN_CAPTURE_MAX)
        return false;
    @autoreleasepool {
        return begin_decode([NSData dataWithBytes:bytes length:size], NULL,
                            NULL);
    }
}

bool pgraph_metal4_validate_pending_capture(const uint8_t *bytes, size_t size)
{
    if (!bytes || size < 32 || size > NV2A_METAL_PENDING_CAPTURE_MAX ||
        ldl_be_p(bytes) != 0x4d345045)
        return false;
    const uint32_t version = ldl_be_p(bytes + 4), flags = ldl_be_p(bytes + 8);
    /* V1 retains old dirty-only snapshots. V2 marks an XF-only pending
     * prefix, whose zero raster vertices must never be used by a raster Begin.
     */
    if (!((version == 1 && flags <= 1) ||
          (version == 2 && (flags == 2 || flags == 3))))
        return false;
    @autoreleasepool {
        return [[NV2AMetalPendingArchive alloc]
                   initWithData:[NSData dataWithBytes:bytes + 12
                                               length:size - 12]
                          limit:524287
                          error:NULL] != nil;
    }
}

@implementation NV2AMetalPGRAPHDraw {
    NV2AState *_d;
    NV2AMetalPGRAPHTextures *_textures;
    NV2AMetalPGRAPHFetch *_fetch;
    NV2AMetalCommands *_snapshotCommands;
    NV2AMetalEpochExecutor *_epoch;
    NV2AMetalPendingJournal *_pending, *_restoredPending;
    NV2AMetalPGRAPHStateProgram *_stateProgram;
    BOOL _vertexCaptureDirty, _restoredVertexCaptureDirty;
    BOOL _restoredPendingRawOnly;
    NV2AMetalGeometry *_geometry;
    NV2AMetalLRUCache<NSNumber *, NV2AMetalPixelShader *> *_pixels;
    BOOL _closed, _active, _nop, _resumeQuery;
    NV2AMetalPGRAPHQuery *_query;
    unsigned _control, _stencil, _primitive;
    BOOL _firstProvoking;
    NV2AMetalGeometryRasterConfig _rasterConfig;
    NV2AMetalPGRAPHVertexState *_vertexState, *_restoredVertexState;
    NV2AMetalPGRAPHPixelState *_pixelState;
    NV2AMetalDepthStencilCache *_depthStencilCache;
    NSData *_restoredBeginSnapshot;
    NV2AMetalSurfaceBindings _surfaceBindings;
}
- (instancetype)initWithState:(NV2AState *)d
                     surfaces:(NV2AMetalPGRAPHSurfaces *)surfaces
                        error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!d || !d->vram || surfaces.cache.vram.contents != d->vram_ptr ||
        surfaces.cache.vram.length != memory_region_size(d->vram)) {
        pgraph_draw_error(error,
                          @"Draw controller requires live NV2A surfaces");
        return nil;
    }
    _d = d;
    _surfaces = surfaces;
    id<MTLDevice> device = surfaces.cache.commands.device;
    _textures = [[NV2AMetalPGRAPHTextures alloc] initWithState:d
                                                      surfaces:surfaces.cache
                                                         error:error];
    _fetch = [[NV2AMetalPGRAPHFetch alloc] initWithState:d
                                                surfaces:surfaces.cache
                                                   error:error];
    _epoch = [[NV2AMetalEpochExecutor alloc] initWithDevice:device error:error];
    _stateProgram = [[NV2AMetalPGRAPHStateProgram alloc] initWithDevice:device
                                                                  error:error];
    _pending = [[NV2AMetalPendingJournal alloc] initWithLimit:NSUIntegerMax];
    _geometry = [[NV2AMetalGeometry alloc] initWithDevice:device error:error];
    _pixels = [[NV2AMetalLRUCache alloc] initWithCapacity:32];
    _depthStencilCache = [NV2AMetalDepthStencilCache sharedWithDevice:device
                                                               error:error];
    _blitter = [[NV2AMetalPGRAPHBlit alloc] initWithState:d
                                                 surfaces:surfaces
                                                    error:error];
    _reports = [[NV2AMetalPGRAPHReports alloc] initWithState:d
                                                       cache:surfaces.cache];
    return _textures && _fetch && _epoch && _pending && _stateProgram &&
                   _geometry && _blitter && _depthStencilCache ?
               self :
               nil;
}
- (NV2AMetalPixelShader *)pixelForColor:(MTLPixelFormat)color
                                  depth:(MTLPixelFormat)depth
                                  error:(NSError **)error
{
    unsigned channels = NV2AMetalSurfaceStorageNative;
    unsigned format =
        _surfaces.color ? _surfaces.color.transfer.config.format : 0;
    switch (format) {
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_B8:
        channels = NV2AMetalSurfaceStorageB8;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8:
        channels = NV2AMetalSurfaceStorageG8B8;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5:
        channels = NV2AMetalSurfaceStorageZ1;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5:
        channels = NV2AMetalSurfaceStorageO1;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8:
        channels = NV2AMetalSurfaceStorageZ8;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8:
        channels = NV2AMetalSurfaceStorageO8;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8:
        channels = NV2AMetalSurfaceStorageZ7;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8:
        channels = NV2AMetalSurfaceStorageO7;
        break;
    }
    NSNumber *key = @((NSUInteger)color | (NSUInteger)channels << 16 |
                      (NSUInteger)depth << 32);
    NV2AMetalPixelShader *pixel = _pixels[key];
    if (!pixel) {
        pixel = [[NV2AMetalPixelShader alloc]
             initWithDevice:_surfaces.cache.commands.device
                colorFormat:color
                depthFormat:depth
                sampleCount:1
            surfaceChannels:channels
                      error:error];
        if (pixel) {
            /* Submitted command slots retain evicted renderers until idle. */
            _pixels[key] = pixel;
        }
    }
    return pixel;
}
- (BOOL)drawWithError:(NSError **)error
{
    if (_active)
        return pgraph_draw_error(error, @"Standalone draw inside native Begin");
    if (_d->pgraph.zpass_pixel_count_enable)
        _query = [_reports beginQuery];
    BOOL ok = [self drawBatchWithError:error advanceTime:YES];
    if (ok)
        [_reports endQuery:_query];
    else if (_query)
        [_reports cancelQuery:_query];
    _query = nil;
    return ok;
}
- (NV2AMetalPGRAPHVertexState *)
    transformBatches:(NSArray<NV2AMetalPGRAPHFetchBatch *> *)batches
              inputs:(NSArray<NV2AMetalPendingInput *> *)inputs
              vertex:(NV2AMetalPGRAPHVertexState *)vertex
    preserveMetadata:(BOOL)preserveMetadata
               error:(NSError **)error
{
    return [self transformBatches:batches
                           inputs:inputs
                           vertex:vertex
                 preserveMetadata:preserveMetadata
                        encodings:nil
                     pendingGPU:NO
                            error:error];
}
- (NV2AMetalPGRAPHVertexState *)
    transformBatches:(NSArray<NV2AMetalPGRAPHFetchBatch *> *)batches
              inputs:(NSArray<NV2AMetalPendingInput *> *)inputs
              vertex:(NV2AMetalPGRAPHVertexState *)vertex
    preserveMetadata:(BOOL)preserveMetadata
           encodings:(NSArray *)encodings
        pendingGPU:(BOOL)pendingGPU
               error:(NSError **)error
{
    PGRAPHState *pg = &_d->pgraph;
    NV2AMetalPendingPlan *plan = [_pending planInputs:inputs
                                  preservingLastArray:YES
                                                error:error];
    NV2AMetalPendingProgress *progress =
        plan ? [_pending beginProgressForPlan:plan error:error] : nil;
    if (!progress || batches.count != inputs.count) {
        if (progress)
            pgraph_draw_error(error, @"Pending input/fetch range count mismatch");
        return nil;
    }
    for (NSUInteger index = 0; index < batches.count; index++) {
        NV2AMetalPGRAPHFetchBatch *b = batches[index];
        if (b.inputVertexCount != inputs[index].count) {
            pgraph_draw_error(error,
                              @"Pending input/fetch vertex count mismatch");
            return nil;
        }
        NSUInteger first = plan.prefixCounts[index].unsignedIntegerValue;
        NSUInteger count = inputs[index].count - first;
        if (first < b.firstDecodedVertex ||
            first - b.firstDecodedVertex > b.fetch.vertexCount ||
            count > b.fetch.vertexCount - (first - b.firstDecodedVertex)) {
            pgraph_draw_error(error,
                              @"Pending suffix exceeds compact fetch output");
            return nil;
        }
        NSUInteger attributeFirst = first - b.firstDecodedVertex;
        if (!count) {
            if (![_pending commitNextSuffix:nil progress:progress error:error])
                return nil;
            continue;
        }
        NV2AMetalEpochResult *r = nil;
        if (encodings) {
            if (index < encodings.count && [encodings[index]
                                               isKindOfClass:NSError.class]) {
                if (error)
                    *error = encodings[index];
                return nil;
            }
            if (index >= encodings.count ||
                ![encodings[index]
                    isKindOfClass:NV2AMetalEpochEncoding.class]) {
                pgraph_draw_error(error, @"Missing shared XF epoch result");
                return nil;
            }
            NV2AMetalEpochEncoding *encoded = encodings[index];
            r = pendingGPU ?
                    [encoded pendingResultForCommands:_surfaces.cache.commands
                                              error:error] :
                    [encoded resolveWithError:error];
            if (r && r.vertexCount != count) {
                pgraph_draw_error(error,
                                  @"Shared XF epoch suffix count changed");
                return nil;
            }
        } else {
            r = [_epoch executeRasterState:vertex
                           attributeBuffer:b.fetch.attributes
                                     first:attributeFirst
                                     count:count
                                     error:error];
        }
        if (!r)
            return nil;
        NV2AMetalPGRAPHVertexState *next =
            [vertex stateByApplyingConstants:r.constants
                                     written:r.written
                                       error:error];
        if (!next)
            return nil;
        NV2AMetalPGRAPHVertexState *cached =
            _active && preserveMetadata ?
                [_vertexState stateByApplyingConstants:r.constants
                                               written:r.written
                                                 error:error] :
                next;
        if (!cached)
            return nil;
        id resource = r.vertices;
        if (!resource && vertex.rasterDiscard)
            resource = [[NV2AMetalDiscardedVertices alloc] initWithCount:count];
        NV2AMetalPendingSpan *span = [NV2AMetalPendingSpan resource:resource
                                                              first:0
                                                              count:count];
        if (!span)
            return nil;
        if (![_pending commitNextSuffix:span progress:progress error:error])
            return nil;
        /* Publish validated result ranges and context in input order. Readonly
         * buffers may still be queued on this same GPU transaction; its private
         * journal is discarded if later raster preparation fails. */
        const uint8_t *flags = r.written.bytes, *constants = r.constants.bytes;
        for (unsigned row = 0; row < NV2A_METAL_VP_CONSTANTS; row++) {
            uint32_t written;
            memcpy(&written, flags + row * 4, 4);
            if (written) {
                memcpy(pg->vsh_constants[row], constants + row * 16, 16);
                pg->vsh_constants_dirty[row] = true;
            }
        }
        vertex = next;
        _vertexCaptureDirty = NO;
        if (_active)
            _vertexState = cached;
    }
    return vertex;
}
- (BOOL)drawBatchWithError:(NSError **)error advanceTime:(BOOL)advanceTime
{
    if (![_surfaces.cache beginRasterProducersWithError:error])
        return NO;
    @try {
        return [self encodeDrawBatchWithError:error advanceTime:advanceTime];
    } @finally {
        [_surfaces.cache endRasterProducers];
    }
}
- (BOOL)encodeDrawBatchWithError:(NSError **)error advanceTime:(BOOL)advanceTime
{
    if (_closed)
        return pgraph_draw_error(error, @"Native PGRAPH draw is closed");
    PGRAPHState *pg = &_d->pgraph;
    uint32_t control =
        _active ? _control : pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0);
    uint32_t stencil =
        _active ? _stencil : pgraph_reg_r(pg, NV_PGRAPH_CONTROL_1);
    NV2AMetalGeometryRasterConfig geometry_config =
        _active ? _rasterConfig : raster_config(pg);
    BOOL first_provoking = _active ? _firstProvoking :
                                     !!(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3) &
                                        NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX);
    BOOL color_write = !!(control & (NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE));
    BOOL depth_test = !!(control & NV_PGRAPH_CONTROL_0_ZENABLE);
    BOOL stencil_test = !!(stencil & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE);
    BOOL zeta = depth_test || stencil_test;
    if (!color_write && !zeta)
        return [self transformAndConsumeWithError:error standalone:!_active];
    if (pg->primitive_mode < PRIM_TYPE_POINTS ||
        pg->primitive_mode > PRIM_TYPE_POLYGON) {
        return pgraph_draw_error(error, @"Invalid primitive");
    }
    if (_active && !_surfaceBindings.color.config.width &&
        !_surfaceBindings.zeta.config.width) {
        BOOL writes = _vertexCaptureDirty ?
                          (GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CSV0_D),
                                    NV_PGRAPH_CSV0_D_MODE) == 2 &&
                           pg->enable_vertex_program_write) :
                          (_vertexState.programmed && _vertexState.writeEnable);
        /* With no attachments or XF writes, GL skips even invalid late
         * fetches. A writable XF epoch must still run before discarding raster.
         */
        return !writes || [self transformAndConsumeWithError:error
                                                  standalone:NO];
    }
    NV2AMetalSurfaceCache *cache = _surfaces.cache;
    NV2AMetalCommands *commands = cache.commands;
    /* Preserve earlier successful guest commands without submitting every draw.
     * A later failure cancels only this new transaction's unaccepted section. */
    if (![cache checkpointWithError:error])
        return NO;
    NV2AMetalPGRAPHInputCheckpoint *checkpoint =
        [[NV2AMetalPGRAPHInputCheckpoint alloc] initWithState:pg error:error];
    if (!checkpoint)
        return NO;
    bool dirty_textures[4];
    uint16_t compressed = pg->compressed_attrs;
    BOOL rebind = _active && pg->inline_buffer_length && compressed;
    bool color_dirty = pg->surface_color.draw_dirty;
    bool zeta_dirty = pg->surface_zeta.draw_dirty;
    memcpy(dirty_textures, pg->texture_dirty, sizeof(dirty_textures));
    NV2AMetalPGRAPHTextureSnapshot *textures = nil;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = nil;
    NSMutableArray *encodings = nil;
    NV2AMetalPGRAPHVertexState *vertex = nil, *producerVertex = nil;
    NSError *captureError = nil, *fragmentError = nil, *pixelError = nil;
    NV2AMetalPGRAPHPixelState *fragment = nil;
    NV2AMetalPixelShader *pixel = nil;
    NV2AMetalDrawState *drawRaster = nil;
    NSArray<NV2AMetalPendingInput *> *inputs = nil;
    NV2AMetalPendingPlan *plan = nil;
    NV2AMetalPendingJournal *originalPending = nil;
    NV2AMetalPGRAPHVertexState *originalVertexState = nil;
    BOOL originalCaptureDirty = NO;
    NV2AMetalPendingUpdate *pending = nil;
    NV2AMetalPendingNative *native = nil;
    NSArray<NV2AMetalVertexSlice *> *vertices = nil;
    NSMutableArray<NSArray<NV2AMetalGeometryResult *> *> *preparedGeometry =
        nil;
    NSMutableArray<NV2AMetalPixelDraw *> *preparedPixels = nil;
    NSMutableArray<NV2AMetalCachedSurface *> *rasterTargets = nil;
    NSMutableArray *completed = nil;
    MTL4RenderPassDescriptor *pass = nil;
    id<MTL4RenderCommandEncoder> renderEncoder = nil;
    NV2AMetalVisibilityCounter *visibility = nil;
    id<MTLTexture> viewport = nil;
    MTLPixelFormat preparedColor = MTLPixelFormatInvalid,
                   preparedDepth = MTLPixelFormatInvalid;
    unsigned preparedSurfaceFormat = 0;
    BOOL drew = NO, suffix = NO, fragmentPrepared = NO, pixelPrepared = NO;
    BOOL currentQueued = NO;
    /* Discover/upload bindings before RTT capture, without recording a warm
     * attachment just for metadata. Fetch may retire aliases or finish an
     * upload; acquire write ownership only before encoding raster work. Keep
     * completed feedback checks even when no recording is needed. */
    if (!(_active ? [_surfaces prepareBindings:_surfaceBindings
                                  forRendering:NO
                                         error:error] :
                    [_surfaces prepareColor:color_write
                                       zeta:zeta
                               forRendering:NO
                                      error:error]) ||
        (!cache.recording && ![cache collectCompletedWithError:error]))
        goto fail;
    if (!_active) {
        textures = [_textures prepareWithError:error];
        if (!textures)
            goto fail;
    }
    inputs =
        [NV2AMetalPGRAPHPendingInputs inputsWithState:pg
                                        reusingInputs:_pending.retainedInputs
                                                error:error];
    if (!inputs)
        goto fail;
    plan = [_pending planInputs:inputs preservingLastArray:YES error:error];
    if (!plan)
        goto fail;
    for (NSUInteger i = 0; i < inputs.count; i++)
        suffix |= inputs[i].count > plan.prefixCounts[i].unsignedIntegerValue;
    producerVertex =
        _active && (!suffix || (!rebind && !_vertexCaptureDirty)) ?
            _vertexState :
            [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                        error:&captureError];
    /* An invalid capture keeps the fetch/validation order. Context writers
     * publish only after producer completion; proven readonly context may stay
     * queued with its immutable inputs and outputs. */
    if (producerVertex) {
        currentQueued = can_queue_captured_context(
            _fetch,
            inputs.count == 1 && inputs[0].kind == NV2AMetalInputIndexed ?
                inputs[0] :
                nil,
            producerVertex, suffix);
        if (currentQueued)
            batches = [_fetch
                encodeCurrentSnapshotsWithPrefixes:plan.prefixCounts
                                      indexedInput:
                                          inputs.count == 1 &&
                                                  inputs[0].kind ==
                                                      NV2AMetalInputIndexed ?
                                              inputs[0] :
                                              nil
                                             error:error];
        else
            batches = [_fetch
                encodeIndependentSnapshotsWithPrefixes:plan.prefixCounts
                                          indexedInput:
                                              inputs.count == 1 &&
                                                      inputs[0].kind ==
                                                          NV2AMetalInputIndexed ?
                                                  inputs[0] :
                                                  nil
                                                 error:error];
        if (!batches)
            goto fail;
        if (batches.count != inputs.count) {
            pgraph_draw_error(error, @"Shared fetch range count mismatch");
            goto fail;
        }
        encodings = [NSMutableArray new];
        NV2AMetalEpochEncoding *previous = nil;
        for (NSUInteger i = 0; i < batches.count; i++) {
            NSUInteger first = plan.prefixCounts[i].unsignedIntegerValue;
            if (batches[i].inputVertexCount != inputs[i].count ||
                batches[i].firstDecodedVertex != first ||
                batches[i].fetch.vertexCount != inputs[i].count - first) {
                pgraph_draw_error(error, @"Shared fetch input count mismatch");
                goto fail;
            }
            NSUInteger count = inputs[i].count - first;
            if (!count) {
                [encodings addObject:NSNull.null];
                continue;
            }
            NSError *epochError = nil;
            NV2AMetalEpochEncoding *encoded =
                producerVertex.programmed && producerVertex.writeEnable &&
                        producerVertex.validatedProgram.mayWriteConstants ?
                    [_epoch encodeSerialRasterState:producerVertex
                                    attributeBuffer:batches[i].fetch.attributes
                                              first:0
                                              count:count
                                           previous:previous
                                           commands:_fetch.encodingCommands
                                              error:&epochError] :
                    [_epoch encodeRasterState:producerVertex
                              attributeBuffer:batches[i].fetch.attributes
                                        first:0
                                        count:count
                                     commands:_fetch.encodingCommands
                                        error:&epochError];
            if (!encoded) {
                if (!epochError)
                    pgraph_draw_error(&epochError,
                                      @"Cannot encode shared XF epoch");
                /* Preserve completed leading ranges when a later host encoding
                 * fails, just as the synchronous epoch loop does. */
                [encodings addObject:epochError];
                break;
            }
            [encodings addObject:encoded];
            previous = encoded;
        }
        /* A later host encoding error must retain completed leading ranges.
         * Resolve that error path before publishing its Pending prefix, rather
         * than leaving it in the cancellable raster transaction. */
        if ([encodings.lastObject isKindOfClass:NSError.class])
            currentQueued = NO;
        if (!currentQueued && ![_fetch submitWithError:error])
            goto fail;
        /* Fragment capture reads no Current or XF feedback. Submitted
         * producers overlap it; known Current/context retains one GPU chain.
         * A capture failure stays deferred behind fetch validation. */
        if (batches.count) {
            fragmentPrepared = YES;
            fragment =
                rebind ? [_pixelState recaptureShaderWithState:pg
                                                        device:commands.device
                                                         error:&fragmentError] :
                _active ? _pixelState :
                          [[NV2AMetalPGRAPHPixelState alloc]
                              initWithState:pg
                                   textures:textures
                                     device:commands.device
                                      error:&fragmentError];
            if (fragment) {
                preparedColor =
                    _surfaces.color ?
                        _surfaces.color.transfer.texture.pixelFormat :
                        MTLPixelFormatInvalid;
                preparedDepth =
                    _surfaces.zeta ?
                        _surfaces.zeta.transfer.texture.pixelFormat :
                        MTLPixelFormatInvalid;
                preparedSurfaceFormat =
                    _surfaces.color ? _surfaces.color.transfer.config.format :
                                      0;
                pixelPrepared = YES;
                pixel = [self pixelForColor:preparedColor
                                      depth:preparedDepth
                                      error:&pixelError];
            }
        }
        /* Sources are fully bounded and CPU-readable; Current is captured
         * from the immutable source. Other inputs validate their GPU fault
         * summary before publishing. Proven output stays on the same GPU queue.
         */
        if (!(currentQueued ?
                  [_fetch completeCurrentSnapshotsWithError:error] :
                  [_fetch completeWithError:error]))
            goto fail;
    } else {
        batches = [_fetch prepareWithError:error];
        if (!batches)
            goto fail;
    }
    if (batches.count != inputs.count) {
        pgraph_draw_error(error, @"Pending input/fetch range count mismatch");
        goto fail;
    }
    if (!batches.count) {
        if (![cache checkpointWithError:error])
            goto fail;
        return YES;
    }
    if (!(_active ? [_surfaces prepareBindings:_surfaceBindings
                                  forRendering:NO
                                         error:error] :
                    [_surfaces prepareColor:color_write
                                       zeta:zeta
                               forRendering:NO
                                      error:error]))
        goto fail;
    /* GL clears compressed_attrs and rebinds both shaders before drawing
     * immediate Float4 buffers. The fetch decoder has already cleared it. */
    for (NSUInteger i = 0; i < inputs.count; i++)
        suffix |= inputs[i].count > plan.prefixCounts[i].unsignedIntegerValue;
    vertex = _active && (!suffix || (!rebind && !_vertexCaptureDirty)) ?
                 _vertexState :
                 [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                             error:error];
    if (!fragmentPrepared)
        fragment = rebind ?
                       [_pixelState recaptureShaderWithState:pg
                                                      device:commands.device
                                                       error:error] :
                   _active ? _pixelState :
                             [[NV2AMetalPGRAPHPixelState alloc]
                                 initWithState:pg
                                      textures:textures
                                        device:commands.device
                                         error:error];
    else if (vertex && !fragment && error)
        *error = fragmentError;
    if (!vertex || !fragment)
        goto fail;
    viewport = _surfaces.color ? _surfaces.color.transfer.texture :
                                 _surfaces.zeta.transfer.texture;
    NV2AMetalDrawConfig boundRaster = fragment.raster.config;
    drawRaster = fragment.raster;
    BOOL hasStencil =
        _surfaces.zeta && _surfaces.zeta.transfer.texture.pixelFormat ==
                              MTLPixelFormatDepth32Float_Stencil8;
    if ((!_surfaces.zeta && drawRaster.requiresDepth) ||
        (!hasStencil && drawRaster.requiresStencil)) {
        NV2AMetalDrawConfig effective = boundRaster;
        // GL tests pass when the corresponding attachment is absent.
        if (!_surfaces.zeta)
            effective.control[0] &= ~NV_PGRAPH_CONTROL_0_ZENABLE;
        if (!hasStencil)
            effective.control[1] &= ~NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE;
        drawRaster = [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                         config:&effective
                                                          error:error];
        if (!drawRaster)
            goto fail;
    }
    geometry_config.viewportWidth =
        boundRaster.viewport_width ?: viewport.width;
    geometry_config.viewportHeight =
        boundRaster.viewport_height ?: viewport.height;
    /* Queue-resident readonly output is consumed on these same commands.
     * Serial context feedback still publishes in completed range order. */
    if (!encodings && ![cache submitWithError:error])
        goto fail;
    if (currentQueued) {
        /* These vertices are still in this cancellable GPU transaction.
         * Do not leave them as completed Pending spans after a raster fault. */
        originalPending = _pending;
        originalVertexState = _vertexState;
        originalCaptureDirty = _vertexCaptureDirty;
        _pending = [_pending copyForTransaction];
        if (!_pending) {
            pgraph_draw_error(error, @"Cannot stage pending GPU vertices");
            goto fail;
        }
    }
    vertex = [self transformBatches:batches
                             inputs:inputs
                             vertex:vertex
                   preserveMetadata:rebind && !_vertexCaptureDirty
                          encodings:encodings
                         pendingGPU:currentQueued
                              error:error];
    if (!vertex)
        goto fail;
    if (currentQueued && producerVertex.programmed && suffix) {
        /* A later raster fault must retain programmed XF's frozen input
         * prefix, just as a completed producer did. Accept its GPU section
         * before opening the separately cancellable raster transaction.
         * A fully cached retry has no new XF output to retain. */
        if (![cache checkpointWithError:error])
            goto fail;
        originalPending = nil;
    }
    plan = [_pending planInputs:inputs preservingLastArray:YES error:error];
    if (!plan)
        goto fail;
    completed = [NSMutableArray new];
    for (NSUInteger index = 0; index < inputs.count; index++)
        [completed addObject:NSNull.null];
    pending = [_pending preparePlan:plan suffixes:completed error:error];
    if (!pending || ![_pending commitUpdate:pending error:error])
        goto fail;
    native = [[NV2AMetalPendingNative alloc]
        initWithUpdate:pending
                device:commands.device
           streamLimit:MIN(commands.device.maxBufferLength /
                               sizeof(NV2AMetalVertex),
                           (NSUInteger)UINT32_MAX)
            totalLimit:NSUIntegerMax
                 error:error];
    if (!native)
        goto fail;
    if (!(_active ? [_surfaces prepareBindings:_surfaceBindings error:error] :
                    [_surfaces prepareColor:color_write zeta:zeta error:error]))
        goto fail;
    vertices = [native encodeSlicesWithCommands:commands error:error];
    if (!vertices)
        goto fail;
    /* Fetch may have retired aliased attachments. Reuse CPU preparation only
     * if the revalidated attachment formats and guest storage policy match. */
    MTLPixelFormat colorFormat =
        _surfaces.color ? _surfaces.color.transfer.texture.pixelFormat :
                          MTLPixelFormatInvalid;
    MTLPixelFormat depthFormat =
        _surfaces.zeta ? _surfaces.zeta.transfer.texture.pixelFormat :
                         MTLPixelFormatInvalid;
    unsigned surfaceFormat =
        _surfaces.color ? _surfaces.color.transfer.config.format : 0;
    if (!pixelPrepared || preparedColor != colorFormat ||
        preparedDepth != depthFormat || preparedSurfaceFormat != surfaceFormat)
        pixel = [self pixelForColor:colorFormat depth:depthFormat error:error];
    else if (!pixel && error)
        *error = pixelError;
    if (!pixel)
        goto fail;
    pass = [MTL4RenderPassDescriptor new];
    if (_query && !_query.discarded) {
        visibility = [_reports allocateCounterWithError:error];
        if (!visibility)
            goto fail;
        if (![cache prepareGPUReadAtAddress:0 length:0 error:error])
            goto fail;
    }
    pass.visibilityResultBuffer = _reports.visibilityBuffer;
    if (pass.visibilityResultBuffer)
        pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    if (_surfaces.color) {
        pass.colorAttachments[0].texture = _surfaces.color.transfer.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    if (_surfaces.zeta) {
        pass.depthAttachment.texture = _surfaces.zeta.transfer.texture;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        if (pass.depthAttachment.texture.pixelFormat ==
            MTLPixelFormatDepth32Float_Stencil8) {
            pass.stencilAttachment.texture = pass.depthAttachment.texture;
            pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    }
    /* All streams use the same captured attachments, textures and raster
     * state. Geometry reads only their immutable vertex buffers, so prepare
     * every producer before opening the shared raster pass. Keep stream and
     * per-primitive front/back ordering in the following draw loop. */
    preparedGeometry = [NSMutableArray new];
    for (NSUInteger index = 0; index < vertices.count; index++) {
        NSArray<NV2AMetalGeometryResult *> *geometries =
            [_geometry encodeNativeRasterVertices:vertices[index].buffer
                                            first:vertices[index].firstVertex
                                            count:vertices[index].vertexCount
                                        primitive:(enum NV2AMetalPrimitive)
                                                      pg->primitive_mode
                                           config:&geometry_config
                                           smooth:vertex.smooth
                                   firstProvoking:first_provoking
                                     zPerspective:vertex.zPerspective
                                         commands:commands
                                            error:error];
        if (!geometries)
            goto fail;
        [preparedGeometry addObject:geometries];
    }
    rasterTargets = [NSMutableArray new];
    if (_surfaces.color)
        [rasterTargets addObject:_surfaces.color];
    if (_surfaces.zeta)
        [rasterTargets addObject:_surfaces.zeta];
    if (![cache prepareRasterPass:pass targets:rasterTargets error:error])
        goto fail;
    /* Finish every fallible pipeline/binding/upload operation before opening
     * the pass. This makes the raster group ready for a shared recording. */
    preparedPixels = [NSMutableArray new];
    for (NSArray<NV2AMetalGeometryResult *> *geometries in preparedGeometry) {
        BOOL slices =
            geometries.count > 1 && pg->primitive_mode != PRIM_TYPE_POLYGON;
        NSUInteger rounds = slices ? geometries[0].primitiveCount : 1;
        for (NSUInteger p = 0; p < rounds; p++) {
            for (NV2AMetalGeometryResult *g in geometries) {
                if (!g.vertexCount)
                    continue;
                NSUInteger count =
                    slices ? g.verticesPerPrimitive : g.vertexCount;
                NSUInteger offset =
                    slices ? p * count * sizeof(NV2AMetalVertex) : 0;
                NV2AMetalPixelUniforms uniforms =
                    [fragment uniformsForPolygon:g.polygonMode];
                NV2AMetalPixelTexture bindings[4] = { 0 };
                NV2AMetalPixelRasterClass rasterClass =
                    g.directTriangles ?
                        (NV2AMetalPixelRasterClass)(NV2AMetalPixelRasterDirectTriangle |
                                                    g.directTriangleOptions) :
                    g.directPoints ? NV2AMetalPixelRasterDirectPoint :
                    g.directLineMode == NV2AMetalGeometryDirectLineSmooth ?
                                     NV2AMetalPixelRasterDirectLineSmooth :
                    g.directLineMode == NV2AMetalGeometryDirectLineFlatFirst ?
                                     NV2AMetalPixelRasterDirectLineFlatFirst :
                    g.directLineMode == NV2AMetalGeometryDirectLineFlatLast ?
                                     NV2AMetalPixelRasterDirectLineFlatLast :
                    g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
                    g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
                                         NV2AMetalPixelRasterNative;
                if (![fragment copyTextureBindings:bindings error:error])
                    goto fail;
                NV2AMetalPixelDraw *prepared = [pixel
                         prepareGeometry:g
                                  offset:offset
                                   count:count
                                uniforms:&uniforms
                                textures:bindings
                                    pass:pass
                               drawState:drawRaster
                             rasterClass:rasterClass
                    ignorePolygonCulling:g.expandedLines || g.expandedPolygons
                                commands:commands
                                   error:error];
                if (!prepared)
                    goto fail;
                [preparedPixels addObject:prepared];
            }
        }
    }
    if (preparedPixels.count) {
        if (visibility && ![_reports recordCounter:visibility error:error])
            goto fail;
        renderEncoder = [commands beginRasterPass:pass error:error];
        if (!renderEncoder) {
            pgraph_draw_error(error, @"Cannot begin geometry render pass");
            goto fail;
        }
        if (pass.visibilityResultBuffer)
            [renderEncoder
                setVisibilityResultMode:visibility ?
                                            MTLVisibilityResultModeCounting :
                                            MTLVisibilityResultModeDisabled
                                 offset:visibility ? visibility.offset : 0];
        for (NV2AMetalPixelDraw *prepared in preparedPixels) {
            if (![prepared encodeWithRenderEncoder:renderEncoder
                                          commands:commands
                                             error:error])
                goto fail;
            drew = YES;
        }
    }
    /* Close before surface bookkeeping, submission and any following producer.
     * Failure above cancels the entire raster recording, including all streams.
     */
    if (renderEncoder) {
        [renderEncoder endEncoding];
        renderEncoder = nil;
    }
    if (drew &&
        ![_surfaces
            markColorWritten:color_write && _surfaces.color
                 zetaWritten:_surfaces.zeta &&
                             ((depth_test &&
                               (control & NV_PGRAPH_CONTROL_0_ZWRITEENABLE)) ||
                              (hasStencil && stencil_test &&
                               (stencil &
                                NV_PGRAPH_CONTROL_1_STENCIL_MASK_WRITE)))
                       error:error])
        goto fail;
    if (![cache checkpointWithError:error])
        goto fail;
    if (![_pending consumeUpdate:pending error:error])
        goto fail;
    if (rebind) {
        _vertexState = vertex;
        _pixelState = fragment;
    }
    if (visibility && drew)
        [_reports commitCounter:visibility query:_query];
    else
        [_reports cancelCounter:visibility];
    if (advanceTime)
        pg->draw_time++;
    return YES;
fail:
    if (originalPending) {
        _pending = originalPending;
        _vertexState = originalVertexState;
        _vertexCaptureDirty = originalCaptureDirty;
    }
    [renderEncoder endEncoding];
    if (_fetch.encodingCommands && _fetch.encodingCommands != cache.commands)
        [cache cancel];
    [_fetch cancel];
    [_reports cancelCounter:visibility];
    /* A host validation/encoding failure is not a completed guest draw.
     * In particular an inline-buffer retry must keep its populated streams. */
    NSError *checkpointError = nil;
    if (![checkpoint restoreWithState:pg error:&checkpointError] && error)
        *error = checkpointError;
    memcpy(pg->texture_dirty, dirty_textures, sizeof(dirty_textures));
    pg->surface_color.draw_dirty = color_dirty;
    pg->surface_zeta.draw_dirty = zeta_dirty;
    return NO;
}
- (BOOL)transformPendingWithError:(NSError **)error
{
    return [self transformPendingWithError:error standalone:NO];
}
- (BOOL)transformPendingWithError:(NSError **)error standalone:(BOOL)standalone
{
    if (_closed)
        return pgraph_draw_error(error, @"Closed native XF boundary");
    if (!_active && !standalone)
        return YES;
    PGRAPHState *pg = &_d->pgraph;
    NSArray<NV2AMetalPendingInput *> *inputs =
        [NV2AMetalPGRAPHPendingInputs inputsWithState:pg
                                        reusingInputs:_pending.retainedInputs
                                                error:error];
    NV2AMetalPendingPlan *plan = inputs ? [_pending planInputs:inputs
                                              preservingLastArray:YES
                                                            error:error] :
                                          nil;
    if (!plan)
        return NO;
    BOOL suffix = NO;
    for (NSUInteger i = 0; i < inputs.count; i++)
        suffix |= inputs[i].count > plan.prefixCounts[i].unsignedIntegerValue;
    /* Program uploads may be incomplete between consecutive method words. */
    if (!suffix)
        return YES;
    NV2AMetalSurfaceCache *cache = _surfaces.cache;
    NV2AMetalPGRAPHVertexState *producer = nil;
    /* A speculative capture is CPU-only. An invalid one keeps the original
     * fetch-first fallback and its error ordering. */
    if (!_active || _vertexCaptureDirty)
        producer = _nop || standalone ?
                       capture_only(pg, NULL) :
                       [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                                   error:NULL];
    else
        producer = _vertexState;
    BOOL currentQueued = can_queue_captured_context(
        _fetch,
        inputs.count == 1 && inputs[0].kind == NV2AMetalInputIndexed ?
            inputs[0] :
            nil,
        producer, suffix);
    if (!(currentQueued ? [cache checkpointWithError:error] :
                          [cache submitWithError:error]))
        return NO;
    NV2AMetalPGRAPHInputCheckpoint *checkpoint =
        [[NV2AMetalPGRAPHInputCheckpoint alloc] initWithState:pg error:error];
    if (!checkpoint)
        return NO;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = nil;
    NV2AMetalPGRAPHVertexState *vertex = nil, *originalVertexState = nil;
    NV2AMetalPendingJournal *originalPending = nil;
    NSMutableArray *encodings = nil;
    BOOL ok = NO, originalCaptureDirty = NO;
    NSError *restoreError = nil;
    if (producer) {
        if (currentQueued)
            batches = [_fetch
                encodeCurrentSnapshotsWithPrefixes:plan.prefixCounts
                                      indexedInput:
                                          inputs.count == 1 &&
                                                  inputs[0].kind ==
                                                      NV2AMetalInputIndexed ?
                                              inputs[0] :
                                              nil
                                             error:error];
        else
            batches = [_fetch
                encodeIndependentSnapshotsWithPrefixes:plan.prefixCounts
                                          indexedInput:
                                              inputs.count == 1 &&
                                                      inputs[0].kind ==
                                                          NV2AMetalInputIndexed ?
                                                  inputs[0] :
                                                  nil
                                                 error:error];
        if (!batches || batches.count != inputs.count) {
            if (batches)
                pgraph_draw_error(error, @"XF boundary input/fetch mismatch");
            goto done;
        }
        encodings = [NSMutableArray new];
        NV2AMetalEpochEncoding *previous = nil;
        for (NSUInteger i = 0; i < batches.count; i++) {
            NSError *epochError = nil;
            NSUInteger first = plan.prefixCounts[i].unsignedIntegerValue;
            if (batches[i].inputVertexCount != inputs[i].count ||
                batches[i].firstDecodedVertex != first ||
                batches[i].fetch.vertexCount != inputs[i].count - first) {
                pgraph_draw_error(&epochError,
                                  @"Pending input/fetch vertex count mismatch");
                [encodings addObject:epochError];
                break;
            }
            NSUInteger count = inputs[i].count - first;
            if (!count) {
                [encodings addObject:NSNull.null];
                continue;
            }
            NV2AMetalEpochEncoding *encoded =
                producer.programmed && producer.writeEnable &&
                        producer.validatedProgram.mayWriteConstants ?
                    [_epoch encodeSerialRasterState:producer
                                    attributeBuffer:batches[i].fetch.attributes
                                              first:0
                                              count:count
                                           previous:previous
                                           commands:_fetch.encodingCommands
                                              error:&epochError] :
                    [_epoch encodeRasterState:producer
                              attributeBuffer:batches[i].fetch.attributes
                                        first:0
                                        count:count
                                     commands:_fetch.encodingCommands
                                        error:&epochError];
            if (!encoded) {
                if (!epochError)
                    pgraph_draw_error(&epochError,
                                      @"Cannot encode shared XF boundary");
                [encodings addObject:epochError];
                break;
            }
            [encodings addObject:encoded];
            previous = encoded;
        }
        /* Preserve successful leading ranges across a later host error, just
         * as the required-feedback path does. */
        if ([encodings.lastObject isKindOfClass:NSError.class])
            currentQueued = NO;
        if (!(currentQueued ? [_fetch completeCurrentSnapshotsWithError:error] :
                              [_fetch completeWithError:error]))
            goto done;
    } else {
        batches = [_fetch prepareWithError:error];
    }
    if (!batches || batches.count != inputs.count) {
        if (batches)
            pgraph_draw_error(error, @"XF boundary input/fetch mismatch");
        goto done;
    }
    if (!_active || _vertexCaptureDirty) {
        vertex = _nop || standalone ?
                     capture_only(pg, error) :
                     [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                                 error:error];
    } else {
        vertex = _vertexState;
    }
    if (!vertex || (!encodings && (![cache submitWithError:error] ||
                                   ![cache waitUntilIdleWithError:error])))
        goto done;
    if (currentQueued) {
        /* A failed host transaction must not retain unsubmitted GPU spans. */
        originalPending = _pending;
        originalVertexState = _vertexState;
        originalCaptureDirty = _vertexCaptureDirty;
        _pending = [_pending copyForTransaction];
        if (!_pending) {
            pgraph_draw_error(error, @"Cannot stage XF-only GPU vertices");
            goto done;
        }
    }
    ok = [self transformBatches:batches
                         inputs:inputs
                         vertex:vertex
               preserveMetadata:NO
                      encodings:encodings
                     pendingGPU:currentQueued
                          error:error] != nil;
done:
    /* Restore the common controller's input state before accepting GPU work.
     * State changes following this method must observe the original bits. */
    if (![checkpoint restoreWithState:pg error:&restoreError]) {
        if (error)
            *error = restoreError;
        ok = NO;
    }
    if (ok && currentQueued && ![cache checkpointWithError:error])
        ok = NO;
    if (!ok) {
        if (originalPending) {
            _pending = originalPending;
            _vertexState = originalVertexState;
            _vertexCaptureDirty = originalCaptureDirty;
        }
        if (_fetch.encodingCommands &&
            _fetch.encodingCommands != cache.commands)
            [cache cancel];
        [_fetch cancel];
    }
    return ok;
}
/* XF precedes rasterization. Finish the current input ranges without issuing
 * raster work, preserving Current/populated/compressed through the checkpoint.
 * Hidden last ranges remain retained by the same journal consume operation. */
- (BOOL)transformAndConsumeWithError:(NSError **)error
                          standalone:(BOOL)standalone
{
    if (![self transformPendingWithError:error standalone:standalone])
        return NO;
    NSArray<NV2AMetalPendingInput *> *inputs =
        [NV2AMetalPGRAPHPendingInputs inputsWithState:&_d->pgraph
                                        reusingInputs:_pending.retainedInputs
                                                error:error];
    NV2AMetalPendingPlan *plan = inputs ? [_pending planInputs:inputs
                                              preservingLastArray:YES
                                                            error:error] :
                                          nil;
    if (!plan)
        return NO;
    NSMutableArray *completed = [NSMutableArray new];
    for (NSUInteger i = 0; i < inputs.count; i++)
        [completed addObject:NSNull.null];
    NV2AMetalPendingUpdate *update = [_pending preparePlan:plan
                                                  suffixes:completed
                                                     error:error];
    return update && [_pending commitUpdate:update error:error] &&
           [_pending consumeUpdate:update error:error];
}
- (BOOL)prepareVertexStateChangeWithError:(NSError **)error
{
    if (![self transformPendingWithError:error])
        return NO;
    if (_active)
        _vertexCaptureDirty = YES;
    return YES;
}
- (BOOL)launchStateProgram:(NSUInteger)start error:(NSError **)error
{
    if (![self transformPendingWithError:error])
        return NO;
    NV2AMetalStateTransaction *transaction =
        [_stateProgram executeWithState:&_d->pgraph
                           programStart:start
                                  error:error];
    if (!transaction)
        return NO;
    NV2AMetalPGRAPHVertexState *next = nil;
    if (_active) {
        next =
            [_vertexState stateByApplyingConstants:transaction.result.constants
                                           written:transaction.result.written
                                             error:error];
        if (!next)
            return NO;
    }
    if (![transaction commitWithState:&_d->pgraph error:error])
        return NO;
    if (next)
        _vertexState = next;
    return YES;
}
- (NSData *)pendingSnapshotWithError:(NSError **)error
{
    if (!_active || (!_pending.streamCount && !_vertexCaptureDirty))
        return [NSData data];
    NV2AMetalSurfaceCache *cache = _surfaces.cache;
    if (![cache submitWithError:error] || ![cache waitUntilIdleWithError:error])
        return nil;
    NV2AMetalPendingArchive *archive =
        nv2a_metal_pending_capture(_pending, cache.commands, error);
    if (!archive)
        return nil;
    uint32_t words[] = { 0x4d345045, _nop ? 2u : 1u,
                         (unsigned)_vertexCaptureDirty | (_nop ? 2u : 0u) };
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(words)];
    for (unsigned i = 0; i < 3; i++)
        stl_be_p((uint8_t *)data.mutableBytes + i * 4, words[i]);
    [data appendData:archive.data];
    return data;
}
- (BOOL)restorePendingSnapshot:(NSData *)data error:(NSError **)error
{
    if (_closed || _active ||
        !pgraph_metal4_validate_pending_capture(data.bytes, data.length))
        return pgraph_draw_error(error,
                                 @"Invalid restored XF boundary capture");
    NV2AMetalPendingArchive *archive = [[NV2AMetalPendingArchive alloc]
        initWithData:[data subdataWithRange:NSMakeRange(12, data.length - 12)]
               limit:524287
               error:error];
    if (!archive)
        return NO;
    BOOL raw = ldl_be_p((const uint8_t *)data.bytes + 4) == 2;
    NV2AMetalPendingJournal *pending =
        raw ? nv2a_metal_pending_restore_raw(archive, _surfaces.cache.commands,
                                             NSUIntegerMax, error) :
              nv2a_metal_pending_restore(archive, _surfaces.cache.commands,
                                         NSUIntegerMax, error);
    if (!pending)
        return NO;
    NSArray<NV2AMetalPendingInput *> *live =
        [NV2AMetalPGRAPHPendingInputs inputsWithState:&_d->pgraph
                                        reusingInputs:pending.retainedInputs
                                                error:error];
    if (!live || ![pending planInputs:live preservingLastArray:NO error:error])
        return NO;
    _restoredPending = pending;
    _restoredVertexCaptureDirty = ldl_be_p((const uint8_t *)data.bytes + 8) & 1;
    _restoredPendingRawOnly = ldl_be_p((const uint8_t *)data.bytes + 4) == 2;
    return YES;
}
- (void)resetSession
{
    [_pending reset];
    _restoredPending = nil;
    _restoredVertexCaptureDirty = NO;
    _restoredPendingRawOnly = NO;
    _active = _nop = _vertexCaptureDirty = NO;
    _surfaceBindings = (NV2AMetalSurfaceBindings){ 0 };
    _vertexState = nil;
    _pixelState = nil;
}
- (NV2AMetalCommands *)snapshotCommandsWithError:(NSError **)error
{
    if (!_snapshotCommands)
        _snapshotCommands = [[NV2AMetalCommands alloc]
            initWithDevice:_surfaces.cache.commands.device
                     error:error];
    return _snapshotCommands;
}
- (BOOL)beginWithError:(NSError **)error
{
    if (_closed || _active || _pending.streamCount)
        return pgraph_draw_error(error, @"Invalid native Begin lifecycle");
    PGRAPHState *pg = &_d->pgraph;
    if (pg->primitive_mode < PRIM_TYPE_POINTS ||
        pg->primitive_mode > PRIM_TYPE_POLYGON)
        return pgraph_draw_error(
            error, @"Invalid native Begin primitive or pending query");
    _control = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0);
    _stencil = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_1);
    _primitive = pg->primitive_mode;
    _firstProvoking = !!(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3) &
                         NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX);
    _rasterConfig = raster_config(pg);
    BOOL color = !!(_control & (NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE));
    BOOL zeta = (_control & NV_PGRAPH_CONTROL_0_ZENABLE) ||
                (_stencil & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE);
    _nop = !color && !zeta;
    BeginCapture restored = { 0 };
    if (_restoredBeginSnapshot) {
        if (!begin_decode(_restoredBeginSnapshot, &restored, error) ||
            restored.primitive != pg->primitive_mode)
            return pgraph_draw_error(error, @"Restored Begin mismatch");
        _control = restored.control;
        _stencil = restored.stencil;
        _firstProvoking = restored.firstProvoking;
        _rasterConfig = restored.geometry;
        _nop = restored.nop;
        color = !!(_control & (NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                               NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                               NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                               NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE));
        zeta = (_control & NV_PGRAPH_CONTROL_0_ZENABLE) ||
               (_stencil & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE);
    }
    if (!_nop && _restoredPendingRawOnly)
        return pgraph_draw_error(
            error, @"Raw XF pending prefix cannot restore a raster Begin");
    if (_restoredVertexState.rasterDiscard && _restoredPending &&
        !_restoredPendingRawOnly)
        return pgraph_draw_error(
            error, @"Raw XF capture requires raw pending metadata");
    if (!_nop && _restoredVertexState.rasterDiscard)
        return pgraph_draw_error(
            error, @"Raw XF capture cannot restore a raster Begin");
    if (_nop) {
        /* Raster masks do not disable serial vertex-context writes. Capturing
         * XF does not bind surfaces, pixel shaders, textures or a query. */
        _vertexState = _restoredVertexState ?: capture_only(pg, error);
        if (!_vertexState)
            return NO;
        if (_restoredPending) {
            _pending = _restoredPending;
            _vertexCaptureDirty = _restoredVertexCaptureDirty;
        }
        _active = YES;
        _restoredPending = nil;
        _restoredVertexCaptureDirty = NO;
        _restoredPendingRawOnly = NO;
        _restoredVertexState = nil;
        _restoredBeginSnapshot = nil;
        return YES;
    }
    bool dirty_textures[4];
    memcpy(dirty_textures, pg->texture_dirty, sizeof(dirty_textures));
    bool color_dirty = pg->surface_color.draw_dirty;
    bool zeta_dirty = pg->surface_zeta.draw_dirty;
    NV2AMetalSurfaceCache *cache = _surfaces.cache;
    if (![cache checkpointWithError:error])
        return NO;
    NV2AMetalPGRAPHTextureSnapshot *textures = nil;
    if (!(restored.hasBindings ? [_surfaces prepareBindings:restored.bindings
                                               forRendering:NO
                                                      error:error] :
                                 [_surfaces prepareColor:color
                                                    zeta:zeta
                                            forRendering:NO
                                                   error:error]))
        goto fail;
    if (_restoredBeginSnapshot && restored.textures) {
        if (![cache submitWithError:error] ||
            ![cache waitUntilIdleWithError:error])
            goto fail;
        NV2AMetalCommands *snapshot = [self snapshotCommandsWithError:error];
        if (!snapshot)
            goto fail;
        textures = [[NV2AMetalPGRAPHTextureSnapshot alloc]
            initWithSnapshot:restored.textures
                    commands:snapshot
                       error:error];
        if (!textures)
            goto fail;
    } else if (!_restoredBeginSnapshot) {
        textures = [_textures prepareWithError:error];
        if (!textures)
            goto fail;
    }
    if (!(restored.hasBindings ? [_surfaces prepareBindings:restored.bindings
                                               forRendering:NO
                                                      error:error] :
                                 [_surfaces prepareColor:color
                                                    zeta:zeta
                                            forRendering:NO
                                                   error:error]))
        goto fail;
    _vertexState = _restoredVertexState ?:
                       [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                                   error:error];
    _pixelState = _restoredBeginSnapshot ?
                      [[NV2AMetalPGRAPHPixelState alloc]
                          initWithSnapshot:restored.pixel
                                  textures:textures
                                    device:cache.commands.device
                                     error:error] :
                      [[NV2AMetalPGRAPHPixelState alloc]
                          initWithState:pg
                               textures:textures
                                 device:cache.commands.device
                                  error:error];
    _surfaceBindings = [_surfaces captureBindings];
    if (!_vertexState || !_pixelState || ![cache checkpointWithError:error])
        goto fail;
    if (!_resumeQuery)
        _query = pg->zpass_pixel_count_enable ? [_reports beginQuery] : nil;
    _resumeQuery = NO;
    _active = YES;
    if (_restoredPending) {
        _pending = _restoredPending;
        _vertexCaptureDirty = _restoredVertexCaptureDirty;
        _restoredPending = nil;
        _restoredVertexCaptureDirty = NO;
        _restoredPendingRawOnly = NO;
    }
    _restoredVertexState = nil;
    _restoredBeginSnapshot = nil;
    return YES;
fail:
    [cache cancel];
    memcpy(pg->texture_dirty, dirty_textures, sizeof(dirty_textures));
    pg->surface_color.draw_dirty = color_dirty;
    pg->surface_zeta.draw_dirty = zeta_dirty;
    [self resetSession];
    return NO;
}
- (BOOL)clearSurface:(uint32_t)parameter error:(NSError **)error
{
    NV2AMetalPGRAPHPixelState *next = nil;
    if (_active && !_nop) {
        next = [_pixelState stateByApplyingClear:parameter
                                           state:&_d->pgraph
                                          device:_surfaces.cache.commands.device
                                           error:error];
        if (!next)
            return NO;
        if (![_surfaces prepareBindings:_surfaceBindings error:error])
            return NO;
    }
    if (![_surfaces clearSurface:parameter error:error])
        return NO;
    if (next) {
        _pixelState = next;
        NV2AMetalDrawConfig config = next.raster.config;
        _control = config.control[0];
        _stencil = config.control[1];
        _surfaceBindings = [_surfaces captureBindings];
    }
    return YES;
}
- (BOOL)flushDrawWithError:(NSError **)error
{
    if (_closed || !_active || _d->pgraph.primitive_mode != _primitive)
        return pgraph_draw_error(error, @"Invalid native Flush lifecycle");
    return _nop ? [self transformAndConsumeWithError:error standalone:NO] :
                  [self drawBatchWithError:error advanceTime:NO];
}
- (BOOL)endWithError:(NSError **)error
{
    if (_closed || !_active || _d->pgraph.primitive_mode != _primitive)
        return pgraph_draw_error(error, @"Invalid native End lifecycle");
    PGRAPHState *pg = &_d->pgraph;
    unsigned control = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0);
    unsigned stencil = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_1);
    BOOL live_nop = !(control & (NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                 NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                 NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                 NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                                 NV_PGRAPH_CONTROL_0_ZENABLE)) &&
                    !(stencil & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE);
    /* Keep GL's live End raster-mask and Current behavior. XF context writes
     * must still finish when raster work is skipped. Earlier state mutations
     * have already drained their old policy; only the current suffix remains.
     */
    BOOL writes = _vertexCaptureDirty ?
                      (GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CSV0_D),
                                NV_PGRAPH_CSV0_D_MODE) == 2 &&
                       pg->enable_vertex_program_write) :
                      (_vertexState.programmed && _vertexState.writeEnable);
    if (_nop || (live_nop && writes)) {
        if (![self transformAndConsumeWithError:error standalone:NO])
            return NO;
    } else if (!live_nop && ![self flushDrawWithError:error])
        return NO;
    if (!_nop && !live_nop)
        pg->draw_time++;
    [_reports endQuery:_query];
    _query = nil;
    _resumeQuery = NO;
    [self resetSession];
    return YES;
}
- (void)invalidateSession
{
    _restoredVertexState = nil;
    _restoredBeginSnapshot = nil;
    _resumeQuery = _resumeQuery || _active;
    [self resetSession];
}
- (BOOL)flushWithError:(NSError **)error
{
    if (_closed)
        return pgraph_draw_error(error, @"Native PGRAPH draw is closed");
    BOOL colorDirty = _d->pgraph.surface_color.buffer_dirty;
    BOOL zetaDirty = _d->pgraph.surface_zeta.buffer_dirty;
    if (![_surfaces flushWithError:error])
        return NO;
    // Cache eviction during quiescence does not change guest binding metadata.
    _d->pgraph.surface_color.buffer_dirty = colorDirty;
    _d->pgraph.surface_zeta.buffer_dirty = zetaDirty;
    [_textures flush];
    return YES;
}
- (BOOL)flushSurfacesWithError:(NSError **)error
{
    BOOL hadBindings = _surfaces.color || _surfaces.zeta ||
                       (_active && (_surfaceBindings.color.config.width ||
                                    _surfaceBindings.zeta.config.width));
    if (![self flushWithError:error])
        return NO;
    if (!hadBindings)
        return YES;
    PGRAPHState *pg = &_d->pgraph;
    pg->surface_color.buffer_dirty = pg->surface_zeta.buffer_dirty = true;
    if (![_surfaces prepareColor:pgraph_color_write_enabled(pg)
                            zeta:pgraph_zeta_write_enabled(pg)
                           error:error] ||
        ![_surfaces.cache submitWithError:error]) {
        [_surfaces.cache cancel];
        return NO;
    }
    if (_active && !_nop)
        _surfaceBindings = [_surfaces captureBindings];
    return YES;
}
- (BOOL)discardForRestoreWithError:(NSError **)error
{
    if (_closed)
        return pgraph_draw_error(error, @"Native PGRAPH draw is closed");
    BOOL colorDirty = _d->pgraph.surface_color.buffer_dirty;
    BOOL zetaDirty = _d->pgraph.surface_zeta.buffer_dirty;
    if (![_surfaces discardForRestoreWithError:error])
        return NO;
    // The base NV2A loader has already restored these guest binding flags.
    _d->pgraph.surface_color.buffer_dirty = colorDirty;
    _d->pgraph.surface_zeta.buffer_dirty = zetaDirty;
    [self resetSession];
    _restoredVertexState = nil;
    _restoredBeginSnapshot = nil;
    [_reports discard];
    _query = nil;
    _resumeQuery = NO;
    [_textures flush];
    return YES;
}
- (BOOL)closeWithError:(NSError **)error
{
    if (_closed)
        return YES;
    if (![_surfaces closeWithError:error])
        return NO;
    [self resetSession];
    _restoredVertexState = nil;
    _restoredBeginSnapshot = nil;
    [_reports discard];
    _query = nil;
    _resumeQuery = NO;
    [_textures close];
    [_fetch close];
    [_pixels removeAllObjects];
    _depthStencilCache = nil;
    _closed = YES;
    return YES;
}
- (NSData *)beginSnapshotWithError:(NSError **)error
{
    if (_restoredBeginSnapshot)
        return _restoredBeginSnapshot;
    if (!_active)
        return [NSData data];
    NSData *pixel = _nop ? [NSData data] : [_pixelState snapshotData];
    NSData *textures = [NSData data];
    if (!_nop) {
        NV2AMetalPGRAPHTextureSnapshot *bound = _pixelState.textureSnapshot;
        if (!bound)
            bound = [NV2AMetalPGRAPHTextureSnapshot emptySnapshot];
        /* Texture readback uses a private command transaction. Complete the
         * cache-owned prefix before validating or serializing its bindings. */
        if (bound.enabledMask &&
            (![_surfaces.cache submitWithError:error] ||
             ![_surfaces.cache waitUntilIdleWithError:error]))
            return nil;
        /* Keep private snapshot transactions off the cache-owned queue so
         * concurrent CPU access checks never observe a foreign recording. */
        NV2AMetalCommands *snapshot = _surfaces.cache.commands;
        if (bound.enabledMask) {
            snapshot = [self snapshotCommandsWithError:error];
            if (!snapshot)
                return nil;
        }
        textures = [bound snapshotWithCommands:snapshot error:error];
        if (!textures)
            return nil;
    }
    NSData *bindings = _nop ?
                           [NSData data] :
                           nv2a_metal_surface_bindings_encode(_surfaceBindings);
    NSUInteger header = 48 + bindings.length;
    if (textures.length >
        NV2A_METAL_BEGIN_CAPTURE_MAX - header - pixel.length) {
        pgraph_draw_error(error, @"Begin capture exceeds host memory bound");
        return nil;
    }
    uint32_t lineWidth;
    memcpy(&lineWidth, &_rasterConfig.lineWidth, 4);
    uint32_t words[12] = {
        0x4d344243,
        3,
        _primitive,
        _control,
        _stencil,
        _nop | _firstProvoking << 1,
        _rasterConfig.front,
        _rasterConfig.back,
        !_rasterConfig.frontClockwise | _rasterConfig.cullFront << 1 |
            _rasterConfig.cullBack << 2 | _rasterConfig.lineSmooth << 3 |
            _rasterConfig.polygonSmooth << 4,
        lineWidth,
        (uint32_t)pixel.length,
        (uint32_t)textures.length,
    };
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(words)];
    for (unsigned i = 0; i < 12; i++)
        stl_be_p((uint8_t *)data.mutableBytes + i * 4, words[i]);
    [data appendData:pixel];
    [data appendData:textures];
    [data appendData:bindings];
    return [data copy];
}
- (BOOL)restoreBeginSnapshot:(NSData *)data error:(NSError **)error
{
    BeginCapture capture;
    if (!begin_decode(data, &capture, error) ||
        capture.primitive != _d->pgraph.primitive_mode)
        return pgraph_draw_error(error, @"Restored Begin primitive mismatch");
    _restoredBeginSnapshot = [data copy];
    return YES;
}
- (NSData *)vertexSnapshot
{
    NV2AMetalPGRAPHVertexState *capture =
        _restoredVertexState ?: (_active ? _vertexState : nil);
    return capture ? [capture snapshotData] : [NSData data];
}
- (BOOL)restoreVertexSnapshot:(NSData *)data error:(NSError **)error
{
    NV2AMetalPGRAPHVertexState *capture =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:data error:error];
    if (!capture)
        return NO;
    _restoredVertexState = capture;
    return YES;
}
- (NSData *)reportSnapshotWithError:(NSError **)error
{
    return [_reports snapshotWithActiveQuery:_query error:error];
}
- (BOOL)restoreReportSnapshot:(NSData *)data error:(NSError **)error
{
    NV2AMetalPGRAPHQuery *query = nil;
    if (![_reports restoreSnapshot:data activeQuery:&query error:error])
        return NO;
    _query = query;
    _resumeQuery = query != nil;
    return YES;
}
@end
