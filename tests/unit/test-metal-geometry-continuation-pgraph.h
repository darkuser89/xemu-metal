/* Submit-bound compact geometry outputs, versus the original serial rebuild.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_GEOMETRY_CONTINUATION_PGRAPH_H
#define TEST_METAL_GEOMETRY_CONTINUATION_PGRAPH_H

typedef struct GeometryContinuationPgraphWork {
    BOOL reference, metadata;
    unsigned encodes, packs, faces, allocations, counters, rasters;
    unsigned fetches, xfs, submits, waits, handoffs, failures;
    NSUInteger allocationBytes;
    __unsafe_unretained NV2AMetalSurfaceRecording *producer;
} GeometryContinuationPgraphWork;
static _Thread_local GeometryContinuationPgraphWork *gcp_work;
static _Thread_local unsigned gcp_depth, gcp_failure;
static NSMapTable<id, NSString *> *gcp_names, *gcp_encoders;
static NSMapTable<id, NSArray *> *gcp_originals;
static NSMapTable<id, NSNumber *> *gcp_rasters;
static id<MTLSharedEvent> gcp_gate;
static id<MTL4CommandQueue> gcp_queue;
static NV2AMetalCommands *gcp_commands;
static NSError *gcp_error;
static unsigned gcp_raster_commits;
static BOOL gcp_gate_raster;
static BOOL (*gcp_admission_original)(id, SEL);
static BOOL gcp_admission(id owner, SEL selector)
{
    return !(gcp_work && gcp_work->reference) &&
           gcp_admission_original(owner, selector);
}
static NSArray *(*gcp_encode_original)(id, SEL, NV2AMetalVertexSlice *,
                                       enum NV2AMetalPrimitive,
                                       const NV2AMetalGeometryRasterConfig *,
                                       BOOL, BOOL, BOOL, NV2AMetalCommands *,
                                       NSError **);
static NSArray *gcp_encode(id owner, SEL selector, NV2AMetalVertexSlice *slice,
                           enum NV2AMetalPrimitive primitive,
                           const NV2AMetalGeometryRasterConfig *c, BOOL smooth,
                           BOOL first, BOOL perspective,
                           NV2AMetalCommands *commands, NSError **error)
{
    if (gcp_work)
        gcp_work->encodes++;
    gcp_depth++;
    @try {
        return gcp_encode_original(owner, selector, slice, primitive, c, smooth,
                                   first, perspective, commands, error);
    } @finally {
        gcp_depth--;
    }
}
static NSArray *(*gcp_ticket_original)(id, SEL, NV2AMetalVertexSlice *,
                                       enum NV2AMetalPrimitive,
                                       const NV2AMetalGeometryRasterConfig *,
                                       BOOL, BOOL, BOOL, NV2AMetalCommands *,
                                       NV2AMetalSurfaceCache *,
                                       NV2AMetalGeometryContinuation **,
                                       NSError **);
static NSArray *gcp_ticket(id owner, SEL selector, NV2AMetalVertexSlice *slice,
                           enum NV2AMetalPrimitive primitive,
                           const NV2AMetalGeometryRasterConfig *c, BOOL smooth,
                           BOOL first, BOOL perspective,
                           NV2AMetalCommands *commands,
                           NV2AMetalSurfaceCache *cache,
                           NV2AMetalGeometryContinuation **ticket,
                           NSError **error)
{
    NSArray *results =
        gcp_ticket_original(owner, selector, slice, primitive, c, smooth, first,
                            perspective, commands, cache, ticket, error);
    if (gcp_work && results) {
        gcp_work->producer = cache.recording;
        if (ticket && *ticket)
            [gcp_originals setObject:results forKey:*ticket];
    }
    return results;
}
static NSArray *(*gcp_continue_original)(id, SEL, id, NV2AMetalSurfaceCache *,
                                         NV2AMetalCommands *);
static NSArray *gcp_continue(id owner, SEL selector, id ticket,
                             NV2AMetalSurfaceCache *cache,
                             NV2AMetalCommands *commands)
{
    NSArray<NV2AMetalGeometryResult *> *old =
        [gcp_originals objectForKey:ticket];
    NSArray<NV2AMetalGeometryResult *> *fresh =
        gcp_continue_original(owner, selector, ticket, cache, commands);
    if (gcp_work && fresh) {
        gcp_work->handoffs++;
        BOOL same = old && fresh != old && fresh.count == old.count &&
                    gcp_work->producer.submitted &&
                    !gcp_work->producer.cancelled;
        for (NSUInteger i = 0; same && i < old.count; i++) {
            NV2AMetalGeometryResult *a = old[i], *b = fresh[i];
            same = a != b && a.vertices == b.vertices &&
                   a.indexedVertices == b.indexedVertices &&
                   a.lineCoverage == b.lineCoverage &&
                   a.polygonCoverage == b.polygonCoverage &&
                   a.polygonProjections == b.polygonProjections &&
                   a.polygonFacing == b.polygonFacing &&
                   a.vertexCount == b.vertexCount &&
                   a.sourceVertexCount == b.sourceVertexCount &&
                   a.physicalVertexCount == b.physicalVertexCount &&
                   a.firstVertex == b.firstVertex &&
                   a.indexOffset == b.indexOffset &&
                   a.verticesPerPrimitive == b.verticesPerPrimitive &&
                   a.primitiveCount == b.primitiveCount &&
                   a.primitiveType == b.primitiveType &&
                   a.polygonMode == b.polygonMode &&
                   a.sourcePrimitive == b.sourcePrimitive &&
                   a.compactLines == b.compactLines &&
                   a.compactPolygons == b.compactPolygons &&
                   a.expandedLines == b.expandedLines &&
                   a.expandedPolygons == b.expandedPolygons &&
                   a.directPoints == b.directPoints &&
                   a.directTriangles == b.directTriangles &&
                   a.directTriangleOptions == b.directTriangleOptions &&
                   a.directQuadOptions == b.directQuadOptions &&
                   a.directPolygonOptions == b.directPolygonOptions &&
                   a.directLineMode == b.directLineMode &&
                   a.directLineOptions == b.directLineOptions;
            if (a.compactLines)
                same &= ![a canUseLineCoverageForCommands:commands] &&
                        [b canUseLineCoverageForCommands:commands];
            if (a.compactPolygons)
                same &= ![a canUsePolygonCoverageForCommands:commands] &&
                        [b canUsePolygonCoverageForCommands:commands];
        }
        gcp_work->metadata &= same;
    }
    return fresh;
}
static id (*gcp_compute_original)(id, SEL, NSString *, NSError **);
static id gcp_compute(id owner, SEL selector, NSString *name, NSError **error)
{
    if (gcp_work && gcp_depth && gcp_failure == 1 &&
        [name hasPrefix:@"nv2a_compact_"]) {
        gcp_failure = 0;
        gcp_work->failures++;
        if (error)
            *error = gcp_error;
        return nil;
    }
    id result = gcp_compute_original(owner, selector, name, error);
    if (result && gcp_work && gcp_depth)
        [gcp_names setObject:name forKey:result];
    return result;
}
static void (*gcp_pipeline_original)(id, SEL, id);
static void gcp_pipeline(id owner, SEL selector, id pipeline)
{
    if (gcp_work) {
        NSString *name = [gcp_names objectForKey:pipeline];
        if (name)
            [gcp_encoders setObject:name forKey:owner];
        else
            [gcp_encoders removeObjectForKey:owner];
    }
    gcp_pipeline_original(owner, selector, pipeline);
}
static void (*gcp_dispatch_original)(id, SEL, MTLSize, MTLSize);
static void gcp_dispatch(id owner, SEL selector, MTLSize grid, MTLSize group)
{
    if (gcp_work) {
        NSString *name = [gcp_encoders objectForKey:owner];
        gcp_work->packs += [name hasPrefix:@"nv2a_compact_"];
        gcp_work->faces += [name containsString:@"polygon_face"];
    }
    gcp_dispatch_original(owner, selector, grid, group);
}
@interface NSObject (GeometryContinuationAllocation)
- (id<MTLBuffer>)gcp_newBufferWithLength:(NSUInteger)length
                                 options:(MTLResourceOptions)options
    __attribute__((objc_method_family(new)));
@end
@implementation NSObject (GeometryContinuationAllocation)
- (id<MTLBuffer>)gcp_newBufferWithLength:(NSUInteger)length
                                 options:(MTLResourceOptions)options
{
    BOOL privateGeometry =
        gcp_work && gcp_depth &&
        (options & MTLResourceStorageModeMask) == MTLResourceStorageModePrivate;
    if (privateGeometry && gcp_failure == 2) {
        gcp_failure = 0;
        gcp_work->failures++;
        return nil;
    }
    id<MTLBuffer> buffer = [self gcp_newBufferWithLength:length
                                                 options:options];
    if (privateGeometry && buffer) {
        gcp_work->allocations++;
        gcp_work->allocationBytes += length;
    }
    return buffer;
}
@end
static id (*gcp_upload_original)(id, SEL, const void *, NSUInteger,
                                 NSUInteger *, NSError **);
static id gcp_upload(id owner, SEL selector, const void *bytes,
                     NSUInteger length, NSUInteger *offset, NSError **error)
{
    if (gcp_work && gcp_depth && gcp_failure == 3) {
        gcp_failure = 0;
        gcp_work->failures++;
        if (error)
            *error = gcp_error;
        return nil;
    }
    return gcp_upload_original(owner, selector, bytes, length, offset, error);
}
static id (*gcp_encoder_original)(id, SEL);
static id gcp_encoder(id owner, SEL selector)
{
    if (gcp_work && gcp_depth && gcp_failure == 4) {
        gcp_failure = 0;
        gcp_work->failures++;
        return nil;
    }
    return gcp_encoder_original(owner, selector);
}
static id (*gcp_counter_original)(id, SEL, NSError **);
static id gcp_counter(id owner, SEL selector, NSError **error)
{
    if (gcp_work)
        gcp_work->counters++;
    return gcp_counter_original(owner, selector, error);
}
static id (*gcp_raster_original)(id, SEL, id, MTL4RenderEncoderOptions);
static id gcp_raster(id owner, SEL selector, id pass,
                     MTL4RenderEncoderOptions options)
{
    id encoder = gcp_raster_original(owner, selector, pass, options);
    if (encoder && options) {
        [gcp_rasters setObject:@YES forKey:owner];
        if (gcp_work)
            gcp_work->rasters++;
    }
    return encoder;
}
static void (*gcp_buffer_begin_original)(id, SEL, id);
static void gcp_buffer_begin(id owner, SEL selector, id allocator)
{
    [gcp_rasters removeObjectForKey:owner];
    gcp_buffer_begin_original(owner, selector, allocator);
}
static void (*gcp_commit_original)(id, SEL, const id<MTL4CommandBuffer> *,
                                   NSUInteger, MTL4CommitOptions *);
static void gcp_commit(id owner, SEL selector,
                       const id<MTL4CommandBuffer> *buffers, NSUInteger count,
                       MTL4CommitOptions *options)
{
    if (owner == gcp_queue) {
        BOOL raster = NO;
        for (NSUInteger i = 0; i < count; i++)
            raster |= [gcp_rasters objectForKey:buffers[i]] != nil;
        if (raster && gcp_gate_raster) {
            [gcp_queue waitForEvent:gcp_gate value:1];
            gcp_raster_commits++;
        }
    }
    gcp_commit_original(owner, selector, buffers, count, options);
}
static BOOL (*gcp_submit_original)(id, SEL, NSError **);
static BOOL gcp_submit(id owner, SEL selector, NSError **error)
{
    if (gcp_work)
        gcp_work->submits++;
    return gcp_submit_original(owner, selector, error);
}
static BOOL (*gcp_wait_original)(id, SEL, id, NSError **);
static BOOL gcp_wait(id owner, SEL selector, id receipt, NSError **error)
{
    if (gcp_work) {
        gcp_work->waits++;
        if (owner == gcp_commands && gcp_gate_raster && gcp_raster_commits &&
            !gcp_gate.signaledValue)
            gcp_gate.signaledValue = 1;
    }
    return gcp_wait_original(owner, selector, receipt, error);
}
static BOOL (*gcp_begin_original)(id, SEL, NSError **);
static BOOL gcp_begin(id owner, SEL selector, NSError **error)
{
    if (gcp_work && owner == surfaces.cache && gcp_failure == 5) {
        gcp_failure = 0;
        gcp_work->failures++;
        if (error)
            *error = gcp_error;
        return NO;
    }
    return gcp_begin_original(owner, selector, error);
}
static BOOL (*gcp_emit_original)(id, SEL, id, id, NSError **);
static BOOL gcp_emit(id owner, SEL selector, id encoder, id commands,
                     NSError **error)
{
    BOOL ok = gcp_emit_original(owner, selector, encoder, commands, error);
    if (ok && gcp_work && gcp_failure == 6) {
        gcp_failure = 0;
        gcp_work->failures++;
        if (error)
            *error = gcp_error;
        return NO; /* A real GPU draw was encoded into the cancelled section. */
    }
    return ok;
}
static id gcp_fetch(id owner, SEL selector, NSArray *prefixes,
                    NV2AMetalPendingInput *input, BOOL deduplicate,
                    uint64_t lanes, NSError **error)
{
    if (gcp_work)
        gcp_work->fetches++;
    return cpw_fetch(owner, selector, prefixes, input, deduplicate, lanes,
                     error);
}
static id gcp_xf(id owner, SEL selector, NV2AMetalPGRAPHVertexState *vertex,
                 id<MTLBuffer> attributes, NSUInteger first, NSUInteger count,
                 NV2AMetalFetchResult *fetch, NV2AMetalCommands *commands,
                 NSError **error)
{
    if (gcp_work)
        gcp_work->xfs++;
    return cpw_xf(owner, selector, vertex, attributes, first, count, fetch,
                  commands, error);
}
static BOOL gcp_attempt(GeometryContinuationPgraphWork *work, unsigned action,
                        NSError **error)
{
    assert(!gcp_work);
    gcp_work = work;
    @try {
        return action == 1 ? [draw endWithError:error] :
               action == 2 ? [draw flushDrawWithError:error] :
                             [draw drawWithError:error];
    } @finally {
        gcp_work = NULL;
        [gcp_originals removeAllObjects];
    }
}
static void gcp_scene(unsigned scene)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw closeWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    draw = nil;
    surfaces = [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state
                                                        error:&error];
    draw = [[NV2AMetalPGRAPHDraw alloc] initWithState:state
                                             surfaces:surfaces
                                                error:&error];
    require(surfaces && draw, error);
    if (scene == 1)
        clp_scene(1, 1, 1, YES, 0, 0);
    else
        cff_scene(scene == 3 ? 5 : 0, scene == 2 || scene == 3 ? 2 : 0, 1, YES,
                  13, scene != 2 && scene != 3);
    gcp_commands = surfaces.cache.commands;
    gcp_queue = [gcp_commands valueForKey:@"queue"];
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:surfaces.cache
                                      counterCapacity:1];
    require(reports != nil, nil);
    [draw setValue:reports forKey:@"reports"];
    gcp_raster_commits = 0;
    gcp_gate_raster = NO;
    gcp_gate = nil;
}
static NSData *gcp_capture(BOOL secondTarget)
{
    NSError *error = nil;
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(query);
    qemu_mutex_unlock(&state->pgraph.lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    if (secondTarget)
        read_vram(8192, 256);
    qemu_mutex_lock(&state->pgraph.lock);
    NSMutableData *actual = [cpw_capture(query) mutableCopy];
    if (secondTarget)
        [actual appendBytes:state->vram_ptr + 8192 length:256];
    return actual;
}
static void gcp_pressure_pair(unsigned scene)
{
    NSArray *reference = nil;
    GeometryContinuationPgraphWork work[2][2] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            gcp_scene(scene);
            NSError *error = nil;
            PGRAPHState *pg = &state->pgraph;
            NSMutableArray *actual = [NSMutableArray new];
            qemu_mutex_lock(&pg->lock);
            work[candidate][0] =
                (GeometryContinuationPgraphWork){ .reference = !candidate,
                                                  .metadata = YES };
            require(gcp_attempt(&work[candidate][0], 0, &error), error);
            NV2AMetalVisibilityCounter *first =
                [[draw.reports valueForKey:@"counterSlots"] firstObject];
            NV2AMetalSurfaceRecording *token = [first valueForKey:@"token"];
            assert(token && !token.submitted && !token.completed &&
                   gcp_commands.hasPendingRasterPass && pg->draw_time == 1);
            uint64_t batch = gcp_commands.batchSerial;
            NV2AMetalSubmission *receipt = gcp_commands.lastSubmitted;
            work[candidate][1] =
                (GeometryContinuationPgraphWork){ .reference = !candidate,
                                                  .metadata = YES };
            require(gcp_attempt(&work[candidate][1], 0, &error), error);
            BOOL drained =
                token.completed && !first.buffer &&
                [[first valueForKey:@"captured"] boolValue] &&
                [[first valueForKey:@"value"] unsignedLongLongValue] > 0 &&
                gcp_commands.batchSerial != batch &&
                gcp_commands.lastSubmitted != receipt;
            [actual addObject:gcp_capture(NO)];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(drained && pg->draw_time == 2);
            qemu_mutex_unlock(&pg->lock);
        }
    }
    assert(work[0][0].encodes == 1 && work[1][0].encodes == 1 &&
           work[0][0].packs == work[1][0].packs &&
           work[1][0].packs == (scene >= 2 ? 2u : 1u) &&
           work[0][0].faces == (scene == 3 ? 1u : 0u) &&
           work[1][0].faces == work[0][0].faces &&
           work[0][0].allocations == work[1][0].allocations &&
           work[0][0].allocationBytes == work[1][0].allocationBytes &&
           !work[0][0].handoffs && !work[1][0].handoffs);
    assert(work[0][1].encodes == 2 && work[1][1].encodes == 1 &&
           work[0][1].packs == 2 * work[1][1].packs && work[1][1].packs &&
           work[1][1].packs == work[1][0].packs &&
           work[0][1].faces == 2 * work[1][1].faces &&
           work[1][1].faces == work[1][0].faces &&
           work[0][1].allocations == 2 * work[1][1].allocations &&
           work[0][1].allocationBytes == 2 * work[1][1].allocationBytes &&
           !work[0][1].handoffs && work[1][1].handoffs == 1 &&
           work[1][1].metadata);
    for (unsigned step = 0; step < 2; step++) {
        assert(work[0][step].fetches == 1 && work[1][step].fetches == 1 &&
               work[0][step].xfs == 1 && work[1][step].xfs == 1 &&
               work[0][step].counters == 1 && work[1][step].counters == 1 &&
               work[0][step].submits == work[1][step].submits &&
               work[0][step].waits == work[1][step].waits);
    }
}

/* Seed all later data before any read lease. Only live DMA descriptors change
 * between draws; an old-result-for-new-draw mixup then moves the real image. */
static void gcp_seed_next(void)
{
    dma[2].limit = 65536 - 16384 - 1;
    cpu_write(32768, 2048);
    memcpy(state->vram_ptr + 32768, state->vram_ptr + 16384, 2048);
    for (unsigned i = 0; i < 16; i++) {
        float x;
        memcpy(&x, state->vram_ptr + 32768 + i * 16, 4);
        x += 1;
        memcpy(state->vram_ptr + 32768 + i * 16, &x, 4);
    }
}
static void gcp_use_next(void)
{
    for (unsigned i = 0; i < 16; i++) {
        VertexAttribute *a = &state->pgraph.vertex_attributes[i];
        if (a->count && a->stride) {
            assert(a->offset < 2048);
            a->offset += 16384;
        }
    }
}
static void gcp_attachment_pair(void)
{
    NSData *reference = nil;
    GeometryContinuationPgraphWork work[2] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            gcp_scene(0);
            gcp_seed_next();
            dma[0].limit = 16383;
            cpu_write(8192, 256);
            for (unsigned i = 0; i < 64; i++) {
                const uint32_t red = UINT32_C(0xffff0000);
                memcpy(state->vram_ptr + 8192 + i * 4, &red, 4);
            }
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            require([surfaces prepareColor:YES
                                      zeta:YES
                              forRendering:NO
                                     error:&error],
                    error);
            pg->surface_color.offset = 8192 - 1024;
            pg->surface_color.buffer_dirty = true;
            require([surfaces prepareColor:YES
                                      zeta:YES
                              forRendering:NO
                                     error:&error] &&
                        [surfaces.cache submitWithError:&error] &&
                        [surfaces.cache waitUntilIdleWithError:&error],
                    error);
            pg->surface_color.offset = 0;
            pg->surface_color.buffer_dirty = true;
            GeometryContinuationPgraphWork firstWork = { .reference =
                                                             !candidate,
                                                         .metadata = YES };
            require(gcp_attempt(&firstWork, 0, &error), error);
            NV2AMetalVisibilityCounter *first =
                [[draw.reports valueForKey:@"counterSlots"] firstObject];
            NV2AMetalSurfaceRecording *firstToken =
                [first valueForKey:@"token"];
            assert(firstToken && !firstToken.submitted &&
                   !firstToken.completed);
            gcp_gate = [gcp_commands.device newSharedEvent];
            require(gcp_gate != nil, nil);
            gcp_gate_raster = YES;
            id<MTLSharedEvent> watchdog = gcp_gate;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             if (!watchdog.signaledValue)
                                 watchdog.signaledValue = 2;
                           });
            /* The pool stays capacity one on both sides. Disable only B's
             * query so the busy A slot cannot introduce a counter wait; A's
             * real query still validates its blocked raster submission. */
            pg->zpass_pixel_count_enable = false;
            pg->surface_color.offset = 8192 - 1024;
            pg->surface_color.buffer_dirty = true;
            gcp_use_next();
            work[candidate] =
                (GeometryContinuationPgraphWork){ .reference = !candidate,
                                                  .metadata = YES };
            require(gcp_attempt(&work[candidate], 0, &error), error);
            NV2AMetalSurfaceRecording *producer = work[candidate].producer;
            BOOL pending =
                !gcp_gate.signaledValue && gcp_raster_commits &&
                producer.submitted && !producer.completed &&
                !producer.cancelled && firstToken.submitted &&
                !firstToken.completed && gcp_commands.hasPendingRasterPass &&
                gcp_commands.lastSubmitted &&
                ![gcp_commands.lastSubmitted completedWithError:&error] &&
                !error;
            gcp_gate.signaledValue = 1;
            gcp_gate_raster = NO;
            NSData *actual = gcp_capture(YES);
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToData:actual]);
            assert(pending && pg->draw_time == 2 &&
                   memcmp(state->vram_ptr + 1024, state->vram_ptr + 8192, 256));
            qemu_mutex_unlock(&pg->lock);
        }
    }
    assert(work[0].encodes == 2 && work[1].encodes == 1 && work[0].packs == 2 &&
           work[1].packs == 1 &&
           work[0].allocations == 2 * work[1].allocations &&
           work[0].allocationBytes == 2 * work[1].allocationBytes &&
           work[0].submits == 1 && work[1].submits == 1 && !work[0].waits &&
           !work[1].waits && !work[0].counters && !work[1].counters &&
           work[0].fetches == 1 && work[1].fetches == 1 && work[0].xfs == 1 &&
           work[1].xfs == 1 && !work[0].handoffs && work[1].handoffs == 1 &&
           work[1].metadata);
}
static void gcp_early_failures_pair(void)
{
    NSArray *reference = nil;
    GeometryContinuationPgraphWork failed[2][4] = { 0 }, retry[2][4] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        NSMutableArray *actual = [NSMutableArray new];
        for (unsigned failure = 0; failure < 4; failure++) {
            @autoreleasepool {
                gcp_scene(0);
                gcp_seed_next();
                NSError *error = nil;
                PGRAPHState *pg = &state->pgraph;
                qemu_mutex_lock(&pg->lock);
                GeometryContinuationPgraphWork first = { .reference =
                                                             !candidate,
                                                         .metadata = YES };
                require(gcp_attempt(&first, 0, &error), error);
                NV2AMetalVisibilityCounter *counter =
                    [[draw.reports valueForKey:@"counterSlots"] firstObject];
                NV2AMetalSurfaceRecording *token =
                    [counter valueForKey:@"token"];
                gcp_use_next();
                /* A previously unused compact-line PSO is naturally cold.
                 * No existing pipeline field or program is overwritten. */
                pg->regs_[NV_PGRAPH_SETUPRASTER] &=
                    ~(NV_PGRAPH_SETUPRASTER_FRONTFACEMODE |
                      NV_PGRAPH_SETUPRASTER_BACKFACEMODE);
                pg->regs_[NV_PGRAPH_SETUPRASTER] |=
                    2 | 2 << 2 | NV_PGRAPH_SETUPRASTER_LINESMOOTHENABLE;
                NSData *host = fpp_host();
                failed[candidate][failure] =
                    (GeometryContinuationPgraphWork){ .reference = !candidate,
                                                      .metadata = YES };
                gcp_failure = failure + 1;
                assert(!gcp_attempt(&failed[candidate][failure], 0, &error) &&
                       error && !gcp_failure && pg->draw_time == 1 &&
                       [host isEqualToData:fpp_host()]);
                if (failure < 1 || failure == 2)
                    assert(error == gcp_error);
                [actual addObjectsFromArray:@[
                    error.domain, error.localizedDescription, @(error.code)
                ]];
                BOOL untouched = !token.submitted && !token.completed &&
                                 counter.buffer &&
                                 gcp_commands.hasPendingRasterPass;
                error = nil;
                retry[candidate][failure] =
                    (GeometryContinuationPgraphWork){ .reference = !candidate,
                                                      .metadata = YES };
                require(gcp_attempt(&retry[candidate][failure], 0, &error),
                        error);
                [actual addObject:gcp_capture(NO)];
                assert(untouched && pg->draw_time == 2);
                qemu_mutex_unlock(&pg->lock);
            }
        }
        /* A real incomplete stream performs XF but reserves no counter and
         * opens no new raster section, despite a busy single-slot pool. */
        @autoreleasepool {
            gcp_scene(0);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            qemu_mutex_lock(&pg->lock);
            GeometryContinuationPgraphWork first = { .reference = !candidate,
                                                     .metadata = YES };
            require(gcp_attempt(&first, 0, &error), error);
            pg->inline_elements_length = 1;
            GeometryContinuationPgraphWork empty = { .reference = !candidate,
                                                     .metadata = YES };
            require(gcp_attempt(&empty, 0, &error), error);
            [actual addObject:gcp_capture(NO)];
            assert(!empty.packs && !empty.allocations && !empty.counters &&
                   !empty.rasters && !empty.submits && !empty.waits &&
                   empty.fetches == 1 && empty.xfs == 1);
            qemu_mutex_unlock(&pg->lock);
        }
        if (!candidate)
            reference = actual;
        else
            assert([reference isEqualToArray:actual]);
    }
    for (unsigned failure = 0; failure < 4; failure++) {
        for (unsigned candidate = 0; candidate < 2; candidate++)
            assert(failed[candidate][failure].failures == 1 &&
                   !failed[candidate][failure].counters &&
                   !failed[candidate][failure].submits &&
                   !failed[candidate][failure].waits &&
                   !failed[candidate][failure].rasters &&
                   !failed[candidate][failure].packs);
        assert(retry[0][failure].packs == 2 && retry[1][failure].packs == 1 &&
               retry[0][failure].fetches == retry[1][failure].fetches &&
               retry[0][failure].xfs == retry[1][failure].xfs &&
               retry[0][failure].submits == retry[1][failure].submits &&
               retry[0][failure].waits == retry[1][failure].waits &&
               retry[1][failure].metadata && retry[1][failure].handoffs == 1);
    }
}
static void gcp_begin_failure_pair(void)
{
    NSArray *reference = nil;
    GeometryContinuationPgraphWork failed[2] = { 0 }, retry[2] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            gcp_scene(0);
            NSError *error = nil;
            PGRAPHState *pg = &state->pgraph;
            NSMutableArray *actual = [NSMutableArray new];
            qemu_mutex_lock(&pg->lock);
            GeometryContinuationPgraphWork firstWork = { .reference =
                                                             !candidate,
                                                         .metadata = YES };
            require(gcp_attempt(&firstWork, 0, &error), error);
            NV2AMetalVisibilityCounter *first =
                [[draw.reports valueForKey:@"counterSlots"] firstObject];
            NV2AMetalSurfaceRecording *token = [first valueForKey:@"token"];
            NSData *host = fpp_host();
            gcp_failure = 5;
            failed[candidate] =
                (GeometryContinuationPgraphWork){ .reference = !candidate,
                                                  .metadata = YES };
            assert(!gcp_attempt(&failed[candidate], 0, &error) &&
                   error == gcp_error && !gcp_failure && pg->draw_time == 1 &&
                   [host isEqualToData:fpp_host()]);
            NSArray *slots = [draw.reports valueForKey:@"counterSlots"];
            NSIndexSet *free = [draw.reports valueForKey:@"freeCounterSlots"];
            BOOL drained =
                token.completed && !first.buffer &&
                [[first valueForKey:@"captured"] boolValue] &&
                [[first valueForKey:@"value"] unsignedLongLongValue] > 0 &&
                !gcp_commands.commandBuffer && !gcp_commands.batchSerial &&
                slots.count == 1 && slots[0] == NSNull.null &&
                free.count == 1 && free.firstIndex == 0;
            uint64_t prefix =
                [[first valueForKey:@"value"] unsignedLongLongValue];
            [actual addObjectsFromArray:@[
                error.domain, @(error.code), @(prefix)
            ]];
            error = nil;
            retry[candidate] =
                (GeometryContinuationPgraphWork){ .reference = !candidate,
                                                  .metadata = YES };
            /* No readback or extra boundary between real drain failure/retry.
             */
            require(gcp_attempt(&retry[candidate], 0, &error), error);
            [actual addObject:gcp_capture(NO)];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(drained && pg->draw_time == 2);
            qemu_mutex_unlock(&pg->lock);
        }
    }
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        assert(failed[candidate].failures == 1 &&
               failed[candidate].packs == 1 &&
               failed[candidate].counters == 1 && !failed[candidate].rasters &&
               retry[candidate].fetches == 1 && !retry[candidate].xfs &&
               retry[candidate].packs == 1 && retry[candidate].encodes == 1);
    }
    assert(failed[0].submits == failed[1].submits &&
           failed[0].waits == failed[1].waits &&
           retry[0].submits == retry[1].submits &&
           retry[0].waits == retry[1].waits);
}
static void gcp_late_pair(void)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            gcp_scene(0);
            NSError *error = nil;
            PGRAPHState *pg = &state->pgraph;
            NSMutableArray *actual = [NSMutableArray new];
            qemu_mutex_lock(&pg->lock);
            GeometryContinuationPgraphWork first = { .reference = !candidate,
                                                     .metadata = YES };
            require(gcp_attempt(&first, 0, &error), error);
            require([draw beginWithError:&error] &&
                        [draw prepareVertexStateChangeWithError:&error],
                    error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            NSData *begin = [draw beginSnapshotWithError:&error];
            NSData *vertex = draw.vertexSnapshot;
            require(pending && begin && vertex, error);
            [actual addObjectsFromArray:@[ pending, begin, vertex ]];
            NSData *host = fpp_host();
            GeometryContinuationPgraphWork failed = { .reference = !candidate,
                                                      .metadata = YES };
            gcp_failure = 6;
            assert(!gcp_attempt(&failed, 1, &error) && error == gcp_error &&
                   !gcp_failure && pg->draw_time == 1 &&
                   [host isEqualToData:fpp_host()]);
            [actual addObjectsFromArray:@[ error.domain, @(error.code) ]];
            error = nil;
            GeometryContinuationPgraphWork retry = { .reference = !candidate,
                                                     .metadata = YES };
            require(gcp_attempt(&retry, 1, &error), error);
            [actual addObject:gcp_capture(NO)];
            require([draw discardForRestoreWithError:&error] &&
                        [draw restoreVertexSnapshot:vertex error:&error] &&
                        [draw restoreBeginSnapshot:begin error:&error] &&
                        (!pending.length ||
                         [draw restorePendingSnapshot:pending error:&error]) &&
                        [draw beginWithError:&error],
                    error);
            GeometryContinuationPgraphWork restored = { .reference = !candidate,
                                                        .metadata = YES };
            require(gcp_attempt(&restored, 1, &error), error);
            [actual addObject:gcp_capture(NO)];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(failed.failures == 1 && failed.rasters && failed.metadata &&
                   retry.packs == 1 && restored.packs == 1 && !retry.xfs &&
                   !restored.xfs && pg->draw_time == 3);
            qemu_mutex_unlock(&pg->lock);
        }
    }
}

static void geometry_continuation_pgraph_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(probe && [probe beginWithError:&error], error);
    id<MTL4CommandBuffer> buffer = probe.commandBuffer;
    id<MTL4ComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
    require(encoder != nil, nil);
    Class deviceClass = object_getClass(probe.device);
    Method allocation = class_getInstanceMethod(
        deviceClass, @selector(newBufferWithLength:options:));
    Method allocationHook = class_getInstanceMethod(
        NSObject.class, @selector(gcp_newBufferWithLength:options:));
    assert(allocation && allocationHook);
    class_addMethod(deviceClass, @selector(newBufferWithLength:options:),
                    method_getImplementation(allocation),
                    method_getTypeEncoding(allocation));
    class_addMethod(deviceClass, @selector(gcp_newBufferWithLength:options:),
                    method_getImplementation(allocationHook),
                    method_getTypeEncoding(allocationHook));
    allocation = class_getInstanceMethod(
        deviceClass, @selector(newBufferWithLength:options:));
    allocationHook = class_getInstanceMethod(
        deviceClass, @selector(gcp_newBufferWithLength:options:));
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalGeometry.class,
            NSSelectorFromString(@"canHandoffNativeRasterGeometry")),
        class_getInstanceMethod(
            NV2AMetalGeometry.class,
            @selector(encodeNativeRasterSlice:primitive:config:smooth:
                      firstProvoking:zPerspective:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalGeometry.class,
            @selector(
                encodeNativeRasterSlice:primitive:config:smooth:firstProvoking:
                zPerspective:commands:surfaceCache:continuation:error:)),
        class_getInstanceMethod(
            NV2AMetalGeometry.class,
            @selector(continueNativeRasterGeometry:surfaceCache:commands:)),
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(object_getClass(encoder),
                                @selector(setComputePipelineState:)),
        class_getInstanceMethod(
            object_getClass(encoder),
            @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(uploadBytes:length:offset:error:)),
        class_getInstanceMethod(object_getClass(buffer),
                                @selector(computeCommandEncoder)),
        class_getInstanceMethod(NV2AMetalPGRAPHReports.class,
                                @selector(allocateCounterWithError:)),
        class_getInstanceMethod(
            object_getClass(buffer),
            @selector(renderCommandEncoderWithDescriptor:options:)),
        class_getInstanceMethod(object_getClass(buffer),
                                @selector(beginCommandBufferWithAllocator:)),
        class_getInstanceMethod(
            object_getClass([surfaces.cache.commands valueForKey:@"queue"]),
            @selector(commit:count:options:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                @selector(beginRecordingWithError:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:))
    };
    IMP replacements[] = {
        (IMP)gcp_admission, (IMP)gcp_encode,  (IMP)gcp_ticket,
        (IMP)gcp_continue,  (IMP)gcp_compute, (IMP)gcp_pipeline,
        (IMP)gcp_dispatch,  (IMP)gcp_upload,  (IMP)gcp_encoder,
        (IMP)gcp_counter,   (IMP)gcp_raster,  (IMP)gcp_buffer_begin,
        (IMP)gcp_commit,    (IMP)gcp_submit,  (IMP)gcp_wait,
        (IMP)gcp_begin,     (IMP)gcp_emit,    (IMP)gcp_fetch,
        (IMP)gcp_xf
    };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    gcp_admission_original = (void *)originals[0];
    gcp_encode_original = (void *)originals[1];
    gcp_ticket_original = (void *)originals[2];
    gcp_continue_original = (void *)originals[3];
    gcp_compute_original = (void *)originals[4];
    gcp_pipeline_original = (void *)originals[5];
    gcp_dispatch_original = (void *)originals[6];
    gcp_upload_original = (void *)originals[7];
    gcp_encoder_original = (void *)originals[8];
    gcp_counter_original = (void *)originals[9];
    gcp_raster_original = (void *)originals[10];
    gcp_buffer_begin_original = (void *)originals[11];
    gcp_commit_original = (void *)originals[12];
    gcp_submit_original = (void *)originals[13];
    gcp_wait_original = (void *)originals[14];
    gcp_begin_original = (void *)originals[15];
    gcp_emit_original = (void *)originals[16];
    cpw_fetch = (void *)originals[17];
    cpw_xf = (void *)originals[18];
    [encoder endEncoding];
    [probe cancel];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    method_exchangeImplementations(allocation, allocationHook);
    NSPointerFunctionsOptions keys = NSPointerFunctionsWeakMemory |
                                     NSPointerFunctionsObjectPointerPersonality;
    gcp_names =
        [NSMapTable mapTableWithKeyOptions:keys
                              valueOptions:NSPointerFunctionsStrongMemory];
    gcp_encoders =
        [NSMapTable mapTableWithKeyOptions:keys
                              valueOptions:NSPointerFunctionsStrongMemory];
    gcp_originals =
        [NSMapTable mapTableWithKeyOptions:keys
                              valueOptions:NSPointerFunctionsStrongMemory];
    gcp_rasters =
        [NSMapTable mapTableWithKeyOptions:keys
                              valueOptions:NSPointerFunctionsStrongMemory];
    gcp_error = [NSError errorWithDomain:@"test.geometry-continuation"
                                    code:1
                                userInfo:nil];
    @try {
        for (unsigned scene = 0; scene < 4; scene++)
            gcp_pressure_pair(scene);
        gcp_attachment_pair();
        gcp_early_failures_pair();
        gcp_begin_failure_pair();
        gcp_late_pair();
    } @finally {
        if (gcp_gate)
            gcp_gate.signaledValue = 1;
        gcp_work = NULL;
        gcp_depth = gcp_failure = 0;
        gcp_gate_raster = NO;
        method_exchangeImplementations(allocation, allocationHook);
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
        gcp_names = gcp_encoders = nil;
        gcp_originals = nil;
        gcp_rasters = nil;
        gcp_gate = nil;
        gcp_queue = nil;
        gcp_commands = nil;
        gcp_error = nil;
    }
    groups += 8;
    puts("PGRAPH geometry continuation:8 exact frame/Zeta/query/Current/"
         "constants/wire pairs; same capacity1, original compact rebuild "
         "reference, 2->1 carrier dispatch/allocations under full-submit "
         "pressure, 1->1 normal, mixed/genuine/line, pending gated attachment, "
         "early faults/incomplete, postdrain begin and late emit/Restore/retry "
         "PASS");
}
#endif
