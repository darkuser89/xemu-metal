/* Known-zero raster ranges preserve ordered feedback without pool pressure.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ZERO_SAMPLE_QUERY_H
#define TEST_METAL_ZERO_SAMPLE_QUERY_H

@interface NV2AMetalPGRAPHDraw (ZeroSampleProofTest)
- (BOOL)hasNoRasterSamplesForPrimitive:(enum NV2AMetalPrimitive)primitive
                                raster:(const NV2AMetalDrawConfig *)raster
                              geometry:(const NV2AMetalGeometryRasterConfig *)
                                           geometry
                              uniforms:(const NV2AMetalPixelUniforms *)uniforms
                                 width:(NSUInteger)width
                                height:(NSUInteger)height;
@end
static BOOL zs_reference, zs_fail_prepare;
static unsigned zs_physical, zs_zero, zs_prepares;
static NV2AMetalVisibilityCounter *zs_last;
static NSError *zs_failure;
static BOOL (*zs_proof_original)(id, SEL, enum NV2AMetalPrimitive,
                                 const NV2AMetalDrawConfig *,
                                 const NV2AMetalGeometryRasterConfig *,
                                 const NV2AMetalPixelUniforms *, NSUInteger,
                                 NSUInteger);
static BOOL zs_proof(id owner, SEL selector, enum NV2AMetalPrimitive primitive,
                     const NV2AMetalDrawConfig *raster,
                     const NV2AMetalGeometryRasterConfig *geometry,
                     const NV2AMetalPixelUniforms *uniforms, NSUInteger width,
                     NSUInteger height)
{
    if (owner == draw && zs_reference)
        return NO; /* Only counter selection changes; all rendering is real. */
    return zs_proof_original(owner, selector, primitive, raster, geometry,
                             uniforms, width, height);
}
static id (*zs_allocate_original)(id, SEL, NSError **);
static id (*zs_allocate_zero_original)(id, SEL, NSError **);
static id zs_allocate(id owner, SEL selector, NSError **error)
{
    id counter = zs_allocate_original(owner, selector, error);
    if (owner == draw.reports) {
        zs_physical++;
        zs_last = counter;
    }
    return counter;
}
static id zs_allocate_zero(id owner, SEL selector, NSError **error)
{
    id counter = zs_allocate_zero_original(owner, selector, error);
    if (owner == draw.reports) {
        zs_zero++;
        zs_last = counter;
    }
    return counter;
}
static NV2AMetalPixelDraw *(*zs_prepare_original)(
    id, SEL, NV2AMetalGeometryResult *, NSUInteger, NSUInteger,
    const NV2AMetalPixelUniforms *, const NV2AMetalPixelTexture *,
    MTL4RenderPassDescriptor *, NV2AMetalDrawState *, NV2AMetalPixelRasterClass,
    BOOL, NV2AMetalCommands *, NSError **);
static NV2AMetalPixelDraw *zs_prepare(
    id owner, SEL selector, NV2AMetalGeometryResult *geometry,
    NSUInteger offset, NSUInteger count, const NV2AMetalPixelUniforms *uniforms,
    const NV2AMetalPixelTexture *textures, MTL4RenderPassDescriptor *pass,
    NV2AMetalDrawState *raster, NV2AMetalPixelRasterClass rasterClass,
    BOOL ignore, NV2AMetalCommands *commands, NSError **error)
{
    NV2AMetalPixelDraw *packet = zs_prepare_original(
        owner, selector, geometry, offset, count, uniforms, textures, pass,
        raster, rasterClass, ignore, commands, error);
    if (commands == surfaces.cache.commands) {
        zs_prepares++;
        if (packet && zs_fail_prepare) {
            zs_fail_prepare = NO;
            if (error)
                *error = zs_failure;
            return nil;
        }
    }
    return packet;
}
static void zs_reset(BOOL reference)
{
    zs_reference = reference;
    zs_physical = zs_zero = zs_prepares = 0;
    zs_last = nil;
}
static void zs_empty_windows(PGRAPHState *pg)
{
    for (unsigned i = 0; i < 8; i++) {
        pg->regs_[NV_PGRAPH_WINDOWCLIPX0 + i * 4] = 1;
        pg->regs_[NV_PGRAPH_WINDOWCLIPY0 + i * 4] = 7u << 16;
    }
}
static void zs_cpu_bounds(void)
{
    NV2AMetalDrawConfig raster = { 0 };
    NV2AMetalGeometryRasterConfig geometry = { 0 };
    NV2AMetalPixelUniforms uniforms = { 0 };
    uniforms.window_clip_exclusive = 1;
    zs_reference = NO;
    SEL selector = @selector(
        hasNoRasterSamplesForPrimitive:raster:geometry:uniforms:width:height:);
#define ZS_PROOF(p) \
    zs_proof_original(draw, selector, p, &raster, &geometry, &uniforms, 8, 8)
    assert(!ZS_PROOF(NV2AMetalPrimitiveTriangles));
    raster.scissor_enabled = YES;
    raster.scissor = (MTLScissorRect){ 8, 0, NSUIntegerMax, 8 };
    assert(ZS_PROOF(NV2AMetalPrimitivePoints));
    raster.scissor = (MTLScissorRect){ 0, 8, 8, NSUIntegerMax };
    assert(ZS_PROOF(NV2AMetalPrimitiveLines));
    raster.scissor = (MTLScissorRect){ 1, 1, NSUIntegerMax, NSUIntegerMax };
    assert(!ZS_PROOF(NV2AMetalPrimitiveTriangles));
    raster.scissor_enabled = NO;
    geometry.cullFront = geometry.cullBack = YES;
    for (unsigned p = NV2AMetalPrimitivePoints; p <= NV2AMetalPrimitivePolygon;
         p++)
        assert(ZS_PROOF((enum NV2AMetalPrimitive)p) ==
               (p >= NV2AMetalPrimitiveTriangles));
    geometry.cullFront = NO;
    assert(!ZS_PROOF(NV2AMetalPrimitiveTriangles));
    geometry.cullFront = YES;
    geometry.cullBack = NO;
    assert(!ZS_PROOF(NV2AMetalPrimitiveTriangles));
    geometry.cullFront = NO;
    uniforms.window_clip_exclusive = 0;
    assert(ZS_PROOF(NV2AMetalPrimitivePoints));
    uniforms.clip_regions[7][2] = uniforms.clip_regions[7][3] = 1;
    assert(!ZS_PROOF(NV2AMetalPrimitivePoints));
#undef ZS_PROOF
}
static void zs_scene(unsigned mode, unsigned program)
{
    pm_scene(0,
             mode == 4 ? 1 :
             mode == 5 ? 2 :
                         0,
             mode == 4              ? 1 :
             mode == 5 || mode == 6 ? 2 :
                                      0,
             program, YES, 0, 0);
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_SETUPRASTER] &=
        ~(NV_PGRAPH_SETUPRASTER_CULLENABLE | (3u << 21) |
          NV_PGRAPH_SETUPRASTER_WINDOWCLIPTYPE);
    if (mode == 0 || mode == 1 || mode == 13) {
        /* A swizzled target has its own fixed 8x8 extent, independent of
         * the guest scissor, including a legal zero scissor extent. */
        pg->surface_type = NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
        pg->surface_shape.log_width = pg->surface_shape.log_height = 3;
        if (mode == 0)
            pg->surface_shape.clip_width = 0;
        else if (mode == 1)
            pg->surface_shape.clip_height = 0;
        else
            pg->surface_shape.clip_x = 8;
    }
    if (mode == 2 || mode == 9 || mode == 10) {
        zs_empty_windows(pg);
        if (mode == 9)
            pg->regs_[NV_PGRAPH_SETUPRASTER] |=
                NV_PGRAPH_SETUPRASTER_WINDOWCLIPTYPE;
        if (mode == 10)
            pg->regs_[NV_PGRAPH_WINDOWCLIPX0] = 7u << 16;
    }
    if (mode >= 3 && mode <= 8)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_CULLENABLE | (3u << 21);
    if (mode == 7)
        pg->primitive_mode = PRIM_TYPE_POINTS;
    if (mode == 8)
        pg->primitive_mode = PRIM_TYPE_LINES;
    if (mode == 11 || mode == 12)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_CULLENABLE | ((mode - 10) << 21);
}
static NSData *zs_draw_case(unsigned mode, unsigned program, BOOL reference,
                            BOOL retry, NSData **wire)
{
    zs_scene(mode, program);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:surfaces.cache
                                      counterCapacity:1];
    assert(reports);
    [draw setValue:reports forKey:@"reports"];
    zs_reset(reference);
    if (retry) {
        zs_fail_prepare = YES;
        assert(![draw drawWithError:&error] && error == zs_failure &&
               zs_prepares && !zs_fail_prepare && !pg->draw_time);
        NV2AMetalVisibilityCounter *cancelled = zs_last;
        assert([[cancelled valueForKey:@"cancelled"] boolValue]);
        if (!reference)
            assert(!cancelled.buffer && cancelled.offset == NSNotFound &&
                   [[reports valueForKey:@"freeCounterSlots"] count] == 1);
        zs_reset(reference);
        error = nil;
    }
    require([draw drawWithError:&error], error);
    assert(pg->draw_time == 1 && zs_prepares);
    NV2AMetalVisibilityCounter *counter = zs_last;
    BOOL expectedZero = mode <= 6 || mode == 13;
    assert(zs_zero == (!reference && expectedZero) &&
           zs_physical == (reference || !expectedZero));
    if (!reference && expectedZero)
        assert(!counter.buffer && counter.offset == NSNotFound &&
               [[counter valueForKey:@"committed"] boolValue] &&
               [[reports valueForKey:@"freeCounterSlots"] count] == 1);
    require([reports getReport:1u << 24 error:&error] &&
                [reports processWithError:&error],
            error);
    uint32_t count = report_value(0);
    if (expectedZero)
        assert(!count);
    else
        assert(count); /* Real points/lines and both single-face controls. */
    *wire = [reports snapshotWithActiveQuery:nil error:&error];
    require(*wire != nil, error);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    return cpw_capture(count);
}
static NSData *zs_pressure(BOOL reference)
{
    fixture();
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    pg->dma_report = 64;
    pg->zpass_pixel_count_enable = true;
    qemu_mutex_lock(&pg->lock);
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *commands = cache.commands;
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:1];
    [draw setValue:reports forKey:@"reports"];
    zs_reset(reference);
    id<MTLSharedEvent> gate = [commands.device newSharedEvent];
    NV2AMetalCommands *producer = vp_gated_producer(commands.device, gate);
    require([cache beginRecordingWithError:&error] &&
                [commands orderAfterSubmission:producer.lastSubmitted
                                  fromCommands:producer
                                         error:&error],
            error);
    /* Finite escape for a regressed unexpected wait; value2 fails the oracle.
     */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
    vp_wait_commands = commands;
    vp_release_on_wait = gate;
    vp_waits = 0;
    require([draw drawWithError:&error] && [cache submitWithError:&error],
            error);
    assert(zs_physical == 1 && !zs_zero && !vp_waits && !gate.signaledValue);
    zs_empty_windows(pg);
    zs_reset(reference);
    require([draw drawWithError:&error], error);
    assert(zs_prepares && pg->draw_time == 2 && zs_zero == !reference &&
           zs_physical == reference);
    if (reference)
        assert(vp_waits == 1 && gate.signaledValue == 1);
    else
        assert(!vp_waits && !gate.signaledValue && !zs_last.buffer);
    gate.signaledValue = 1;
    vp_release_on_wait = nil;
    require([producer waitUntilIdleWithError:&error], error);
    require([reports getReport:1u << 24 error:&error] &&
                [reports processWithError:&error],
            error);
    uint32_t count = report_value(0);
    assert(count == 28);
    vp_wait_commands = nil;
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    return cpw_capture(count);
}
static NSData *zs_feedback(BOOL reference, BOOL snapshot)
{
    fixture();
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    pg->dma_report = 80;
    qemu_mutex_lock(&pg->lock);
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:1];
    NV2AMetalPGRAPHQuery *query = [reports beginQuery];
    NV2AMetalVisibilityCounter *counter =
        reference ? [reports allocateCounterWithError:&error] :
                    [reports allocateZeroSampleCounterWithError:&error];
    require(counter && [cache beginRecordingWithError:&error], error);
    NV2AMetalSurfaceRecording *token = cache.recording;
    require([reports recordCounter:counter error:&error], error);
    id<MTLBuffer> output = [cache.commands.device
        newBufferWithLength:8
                    options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0xcd, 8);
    id<MTLSharedEvent> gate = [cache.commands.device newSharedEvent];
    NV2AMetalCommands *producer =
        vp_gated_producer(cache.commands.device, gate);
    require([cache.commands orderAfterSubmission:producer.lastSubmitted
                                    fromCommands:producer
                                           error:&error] &&
                [cache.commands addResource:output error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [cache.commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder fillBuffer:output range:NSMakeRange(0, 8) value:0x5a];
    if (reference) {
        require([cache.commands addResource:counter.buffer error:&error],
                error);
        [encoder fillBuffer:counter.buffer
                      range:NSMakeRange(counter.offset, 8)
                      value:0];
    }
    [encoder endEncoding];
    require([cache checkpointWithError:&error], error);
    [reports commitCounter:counter query:query];
    [reports endQuery:query];
    vp_get(reports, 0);
    vp_get(reports, 1);
    memset(report_bytes(0), 0xa5, 32);
    assert(!token.completed && !token.submitted &&
           ![[counter valueForKey:@"captured"] boolValue]);
    SEL selector = @selector(waitForRecording:error:);
    Method method =
        class_getInstanceMethod(NV2AMetalSurfaceCache.class, selector);
    BOOL (*original)(id, SEL, NV2AMetalSurfaceRecording *, NSError **) =
        (void *)method_getImplementation(method);
    __block unsigned waits = 0;
    __block BOOL reject = YES;
    IMP replacement = imp_implementationWithBlock(
        ^BOOL(NV2AMetalSurfaceCache *owner, NV2AMetalSurfaceRecording *selected,
              NSError **failure) {
          if (owner == cache) {
              waits++;
              assert(selected == token && !gate.signaledValue &&
                     !token.completed && !report_was_written(0) &&
                     ![[counter valueForKey:@"captured"] boolValue]);
              if (reject) {
                  if (failure)
                      *failure = zs_failure;
                  return NO;
              }
              gate.signaledValue = 1;
          }
          return original(owner, selector, selected, failure);
        });
    method_setImplementation(method, replacement);
    NSData *wire = nil;
    @try {
        if (snapshot)
            assert(![reports snapshotWithActiveQuery:nil error:&error] &&
                   error == zs_failure);
        else
            assert(![reports processWithError:&error] && error == zs_failure);
        assert(waits == 1 && !token.submitted && !token.completed &&
               !gate.signaledValue && !report_was_written(0) &&
               !report_was_written(1) && *(uint8_t *)output.contents == 0xcd);
        reject = NO;
        error = nil;
        wire = [reports snapshotWithActiveQuery:nil error:&error];
        require(wire != nil, error);
        assert(waits == 2 && token.completed && gate.signaledValue == 1 &&
               !report_was_written(0));
    } @finally {
        method_setImplementation(method, (IMP)original);
        assert(imp_removeBlock(replacement));
        gate.signaledValue = 1;
    }
    const uint8_t expected[8] = {
        0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a
    };
    assert(!memcmp(output.contents, expected, sizeof(expected)));
    require([producer waitUntilIdleWithError:&error] &&
                [reports processWithError:&error],
            error);
    assert(report_value(0) == 0 && report_value(1) == 0 &&
           [[counter valueForKey:@"captured"] boolValue] &&
           ![counter valueForKey:@"token"]);
    NV2AMetalPGRAPHReports *restored =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:1];
    NV2AMetalPGRAPHQuery *active = nil;
    require([restored restoreSnapshot:wire activeQuery:&active error:&error],
            error);
    memset(report_bytes(0), 0xa5, 32);
    require([restored processWithError:&error], error);
    assert(!active && !report_value(0) && !report_value(1));
    qemu_mutex_unlock(&pg->lock);
    return wire;
}
static void zs_zero_lifecycle(void)
{
    fixture();
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    state->pgraph.dma_report = 80;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:1];
    NV2AMetalVisibilityCounter *cancelled =
        [reports allocateZeroSampleCounterWithError:&error];
    assert(cancelled && ![reports recordCounter:cancelled error:&error]);
    error = nil;
    require([cache beginRecordingWithError:&error] &&
                [reports recordCounter:cancelled error:&error],
            error);
    NV2AMetalSurfaceRecording *old = cache.recording;
    [cache cancel];
    [reports cancelCounter:cancelled];
    assert(old.cancelled && ![cancelled valueForKey:@"token"] &&
           [[cancelled valueForKey:@"cancelled"] boolValue] &&
           [[reports valueForKey:@"freeCounterSlots"] count] == 1 &&
           !reports.visibilityBuffer);
    NV2AMetalPGRAPHQuery *query = [reports beginQuery];
    for (unsigned i = 0; i < 5; i++) {
        NV2AMetalVisibilityCounter *counter =
            [reports allocateZeroSampleCounterWithError:&error];
        require(counter && [cache beginRecordingWithError:&error] &&
                    [reports recordCounter:counter error:&error],
                error);
        [reports commitCounter:counter query:query];
        assert([[query valueForKey:@"buffers"] count] <= 1);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        /* No report/readCounts here: the NEXT commit must harvest success. */
    }
    [reports endQuery:query];
    require([reports getReport:1u << 24 error:&error] &&
                [reports processWithError:&error],
            error);
    assert(![[query valueForKey:@"buffers"] count] &&
           !reports.visibilityBuffer &&
           [[reports valueForKey:@"freeCounterSlots"] count] == 1);
    qemu_mutex_unlock(&state->pgraph.lock);
}
/* Keep the legacy append/compact path as the scoped reference. */
static NV2AMetalPGRAPHReports *zsr_observed;
static BOOL zsr_reference;
static BOOL (*zsr_match_original)(id, SEL, NV2AMetalVisibilityCounter *,
                                  NV2AMetalPGRAPHQuery *);
static BOOL zsr_match(id object, SEL selector,
                      NV2AMetalVisibilityCounter *counter,
                      NV2AMetalPGRAPHQuery *query)
{
    return object == zsr_observed && zsr_reference ?
               NO :
               zsr_match_original(object, selector, counter, query);
}
static NV2AMetalSurfaceCache *zsr_cache(void)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:commands
                    vram:surfaces.cache.vram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address <= 65536 && length <= 65536 - address);
            }
                   error:&error];
    require(cache != nil, error);
    return cache;
}
static NV2AMetalPGRAPHReports *zsr_reports(NV2AMetalSurfaceCache *cache,
                                           BOOL reference)
{
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:2];
    assert(reports);
    zsr_observed = reports;
    zsr_reference = reference;
    state->pgraph.dma_report = 80;
    memset(report_bytes(0), 0xa5, 32);
    return reports;
}
static NV2AMetalVisibilityCounter *
zsr_record(NV2AMetalSurfaceCache *cache, NV2AMetalPGRAPHReports *reports,
           NV2AMetalPGRAPHQuery *query, id<MTLBuffer> output, NSUInteger index,
           BOOL physical, BOOL commit)
{
    NSError *error = nil;
    NV2AMetalVisibilityCounter *counter =
        physical ? [reports allocateCounterWithError:&error] :
                   [reports allocateZeroSampleCounterWithError:&error];
    require(counter && [cache beginRecordingWithError:&error] &&
                [reports recordCounter:counter error:&error] &&
                [cache.commands addResource:output error:&error],
            error);
    NSUInteger offset = 0;
    uint64_t seven = 7;
    id<MTLBuffer> source = physical ? [cache.commands uploadBytes:&seven
                                                           length:8
                                                           offset:&offset
                                                            error:&error] :
                                      nil;
    require(!physical || (source && [cache.commands addResource:counter.buffer
                                                          error:&error]),
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [cache.commands.commandBuffer computeCommandEncoder];
    assert(encoder && index < output.length / 4);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder fillBuffer:output
                  range:NSMakeRange(index * 4, 4)
                  value:(uint8_t)(0x20 + index)];
    if (physical)
        [encoder copyFromBuffer:source
                   sourceOffset:offset
                       toBuffer:counter.buffer
              destinationOffset:counter.offset
                           size:8];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([cache checkpointWithError:&error], error);
    if (commit)
        [reports commitCounter:counter query:query];
    return counter;
}
static void zsr_order(NV2AMetalSurfaceCache *cache, NV2AMetalCommands *producer)
{
    NSError *error = nil;
    require([cache beginRecordingWithError:&error] &&
                [cache.commands orderAfterSubmission:producer.lastSubmitted
                                        fromCommands:producer
                                               error:&error],
            error);
}
static id<MTLBuffer> zsr_output(NV2AMetalSurfaceCache *cache)
{
    id<MTLBuffer> output = [cache.commands.device
        newBufferWithLength:256
                    options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0xcd, 256);
    return output;
}
static void zsr_expect(id<MTLBuffer> output, unsigned count)
{
    const uint8_t *bytes = output.contents;
    for (unsigned i = 0; i < 64; i++)
        for (unsigned k = 0; k < 4; k++)
            assert(bytes[i * 4 + k] == (i < count ? 0x20 + i : 0xcd));
}
static NSData *zsr_frozen(BOOL reference, BOOL feedbackFailure)
{
    fixture();
    qemu_mutex_lock(&state->pgraph.lock);
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = zsr_cache();
    NV2AMetalCommands *commands = cache.commands;
    NV2AMetalPGRAPHReports *reports = zsr_reports(cache, reference);
    NV2AMetalPGRAPHQuery *query = [reports beginQuery];
    id<MTLBuffer> output = zsr_output(cache);
    id<MTLSharedEvent> early = [commands.device newSharedEvent];
    id<MTLSharedEvent> later = [commands.device newSharedEvent];
    NV2AMetalCommands *a = vp_gated_producer(commands.device, early);
    NV2AMetalCommands *b = vp_gated_producer(commands.device, later);
    zsr_order(cache, a);
    NV2AMetalVisibilityCounter *first =
        zsr_record(cache, reports, query, output, 0, NO, YES);
    NV2AMetalSurfaceRecording *firstToken = [first valueForKey:@"token"];
    require([cache submitWithError:&error], error);
    id firstEntry = [[cache valueForKey:@"submissions"] firstObject];
    assert(firstEntry && firstToken.submitted && !firstToken.completed);
    if (!feedbackFailure)
        vp_get(reports, 0); /* This immutable report must retain firstToken. */
    zsr_order(cache, b);
    NV2AMetalVisibilityCounter *previous = nil, *last = nil;
    NV2AMetalSurfaceRecording *previousToken = nil;
    for (unsigned i = 1; i <= 32; i++) {
        NV2AMetalVisibilityCounter *counter =
            zsr_record(cache, reports, query, output, i, NO, YES);
        if (i == 1) {
            previous = counter;
            previousToken = [counter valueForKey:@"token"];
        }
        last = counter;
    }
    NV2AMetalSurfaceRecording *lastToken = [last valueForKey:@"token"];
    assert([first valueForKey:@"token"] == firstToken &&
           [previous valueForKey:@"token"] == previousToken &&
           ![[previous valueForKey:@"captured"] boolValue] &&
           !firstToken.cancelled && !previousToken.cancelled &&
           !early.signaledValue && !later.signaledValue);
    NSUInteger expected = reference ? 33 : feedbackFailure ? 1 : 2;
    assert([[query valueForKey:@"buffers"] count] == expected);
    require([cache submitWithError:&error], error);
    SEL waitSelector = @selector(waitForRecording:error:);
    Method waitMethod =
        class_getInstanceMethod(NV2AMetalSurfaceCache.class, waitSelector);
    BOOL (*waitOriginal)(id, SEL, NV2AMetalSurfaceRecording *, NSError **) =
        (void *)method_getImplementation(waitMethod);
    __block unsigned waits = 0;
    IMP waitSpy = imp_implementationWithBlock(
        ^BOOL(NV2AMetalSurfaceCache *owner, NV2AMetalSurfaceRecording *token,
              NSError **failure) {
          if (owner == cache) {
              waits++;
              assert(token ==
                     (feedbackFailure || waits > 1 ? lastToken : firstToken));
              early.signaledValue = 1;
              if (feedbackFailure || waits > 1)
                  later.signaledValue = 1;
              if (feedbackFailure) {
                  /* The cache polls each wrapper once before a native wait.
                   * Complete the real earlier receipt without publishing its
                   * cache token, so the delayed injected error is observable
                   * by that actual wrapper poll on every run. */
                  NSError *nativeError = nil;
                  NV2AMetalSubmission *native =
                      [firstEntry valueForKey:@"submission"];
                  require(native && [commands waitForSubmission:native
                                                          error:&nativeError],
                          nativeError);
              }
          }
          return waitOriginal(owner, waitSelector, token, failure);
        });
    NSError *injected =
        [NSError errorWithDomain:@"test.zero-run.earlier-feedback"
                            code:1
                        userInfo:nil];
    SEL feedbackSelector = @selector(completedWithError:);
    Method feedbackMethod =
        class_getInstanceMethod(object_getClass(firstEntry), feedbackSelector);
    BOOL (*feedbackOriginal)(id, SEL, NSError **) =
        (void *)method_getImplementation(feedbackMethod);
    __block unsigned feedbackPolls = 0, feedbackReady = 0, feedbackInjected = 0;
    IMP feedbackSpy =
        imp_implementationWithBlock(^BOOL(id entry, NSError **failure) {
          BOOL ready = feedbackOriginal(entry, feedbackSelector, failure);
          if (entry == firstEntry) {
              feedbackPolls++;
              feedbackReady += ready;
          }
          if (feedbackFailure && entry == firstEntry && ready) {
              feedbackInjected++;
              if (failure)
                  *failure = injected;
              return YES;
          }
          return ready;
        });
    method_setImplementation(waitMethod, waitSpy);
    method_setImplementation(feedbackMethod, feedbackSpy);
    NSData *wire = nil;
    @try {
        if (feedbackFailure) {
            [reports endQuery:query];
            vp_get(reports, 0);
            BOOL processed = [reports processWithError:&error];
            BOOL captured = [[last valueForKey:@"captured"] boolValue];
            if (processed || error != injected || waits != 1 ||
                report_was_written(0) || report_was_written(1) ||
                lastToken.completed || captured)
                fprintf(stderr,
                        "Zero-run feedback ref%u process%u identity%u "
                        "waits%u written%u/%u completed%u captured%u "
                        "polls%u ready%u injected%u\n",
                        reference, processed, error == injected, waits,
                        report_was_written(0), report_was_written(1),
                        lastToken.completed, captured, feedbackPolls,
                        feedbackReady, feedbackInjected);
            assert(!processed && error == injected && waits == 1 &&
                   !report_was_written(0) && !report_was_written(1) &&
                   !lastToken.completed && !captured);
            /* Finish real GPU work directly; do not publish failed cache data.
             */
            error = nil;
            require([commands waitUntilIdleWithError:&error], error);
            zsr_expect(output, 33);
            wire = [NSData dataWithBytes:report_bytes(0) length:32];
        } else {
            require([reports processWithError:&error], error);
            assert(!report_value(0) && waits == 1 && early.signaledValue == 1 &&
                   !later.signaledValue && !lastToken.completed);
            const uint8_t *bytes = output.contents;
            for (unsigned i = 0; i < 4; i++)
                assert(bytes[i] == 0x20);
            for (unsigned i = 4; i < 256; i++)
                assert(bytes[i] == 0xcd);
            vp_get(reports, 1);
            [reports endQuery:query];
            require([reports processWithError:&error], error);
            zsr_expect(output, 33);
            assert(!report_value(1) && waits == 2 && later.signaledValue == 1);
            wire = [reports snapshotWithActiveQuery:nil error:&error];
            require(wire != nil, error);
        }
    } @finally {
        method_setImplementation(waitMethod, (IMP)waitOriginal);
        method_setImplementation(feedbackMethod, (IMP)feedbackOriginal);
        assert(imp_removeBlock(waitSpy) && imp_removeBlock(feedbackSpy));
        early.signaledValue = later.signaledValue = 1;
    }
    require([a waitUntilIdleWithError:&error] &&
                [b waitUntilIdleWithError:&error],
            error);
    qemu_mutex_unlock(&state->pgraph.lock);
    return wire;
}
static NSData *zsr_boundaries(BOOL reference, unsigned mode)
{
    fixture();
    qemu_mutex_lock(&state->pgraph.lock);
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = zsr_cache();
    NV2AMetalPGRAPHReports *reports = zsr_reports(cache, reference);
    NV2AMetalPGRAPHQuery *query = [reports beginQuery];
    id<MTLBuffer> output = zsr_output(cache);
    NV2AMetalVisibilityCounter *first =
        zsr_record(cache, reports, query, output, 0, NO, mode != 2);
    if (mode == 0)
        require([cache discardForRestoreWithError:&error], error);
    if (mode == 3)
        [reports endQuery:query];
    NV2AMetalPGRAPHQuery *next = mode == 5 ? [reports beginQuery] : query;
    NV2AMetalVisibilityCounter *second =
        zsr_record(cache, reports, next, output, 1, mode == 4, YES);
    if (mode == 2)
        [reports commitCounter:first
                         query:query]; /* Older serial, appended last. */
    if (mode == 4) {
        zsr_record(cache, reports, query, output, 2, NO, YES);
        zsr_record(cache, reports, query, output, 3, NO, YES);
        assert([[query valueForKey:@"buffers"] count] == (reference ? 4u : 3u));
        vp_get(reports, 0);
        [reports clear];
        zsr_record(cache, reports, query, output, 4, NO, YES);
        zsr_record(cache, reports, query, output, 5, NO, YES);
        assert([[query valueForKey:@"buffers"] count] == (reference ? 2u : 1u));
        [reports endQuery:query];
        vp_get(reports, 1);
    } else if (mode == 5) {
        zsr_record(cache, reports, next, output, 2, NO, YES);
        assert([[query valueForKey:@"buffers"] count] == 1 &&
               [[next valueForKey:@"buffers"] count] == (reference ? 2u : 1u));
        [reports endQuery:query];
        [reports endQuery:next];
        vp_get(reports, 0);
    } else {
        assert([[query valueForKey:@"buffers"] count] ==
               (mode == 1 && !reference ? 1u : 2u));
        [reports endQuery:query];
        vp_get(reports, 0);
    }
    if (mode == 0 || mode == 1) {
        if (mode == 1) {
            /* Cancel AFTER coalescing: Restore invalidates every seal. */
            require([cache discardForRestoreWithError:&error], error);
            assert(((NV2AMetalSurfaceRecording *)[second valueForKey:@"token"])
                       .cancelled);
        }
        assert(![reports processWithError:&error] && error &&
               !report_was_written(0));
        error = nil;
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert(*(uint32_t *)output.contents == UINT32_C(0xcdcdcdcd));
        assert(((const uint32_t *)output.contents)[1] ==
               (mode == 0 ? UINT32_C(0x21212121) : UINT32_C(0xcdcdcdcd)));
    } else {
        require([reports processWithError:&error], error);
        zsr_expect(output, mode == 4 ? 6 : mode == 5 ? 3 : 2);
        assert(report_value(0) == (mode == 4 ? 7u : 0u));
        if (mode == 4)
            assert(!report_value(1));
    }
    NSData *bytes = [NSData dataWithBytes:output.contents length:256];
    qemu_mutex_unlock(&state->pgraph.lock);
    return bytes;
}
static void zs_run_tests(void)
{
    Method method = class_getInstanceMethod(
        NV2AMetalPGRAPHReports.class,
        sel_registerName("canCoalesceZeroCounter:query:"));
    assert(method);
    zsr_match_original =
        (void *)method_setImplementation(method, (IMP)zsr_match);
    @try {
        for (unsigned failure = 0; failure < 2; failure++) {
            NSData *old = zsr_frozen(YES, failure);
            NSData *actual = zsr_frozen(NO, failure);
            assert([old isEqualToData:actual]);
        }
        for (unsigned mode = 0; mode < 6; mode++) {
            NSData *old = zsr_boundaries(YES, mode);
            NSData *actual = zsr_boundaries(NO, mode);
            assert([old isEqualToData:actual]);
        }
    } @finally {
        method_setImplementation(method, (IMP)zsr_match_original);
        zsr_observed = nil;
        zsr_reference = NO;
    }
    puts(
        "Zero-run compaction:8 legacy append/compact pairs;32 pending zeros "
        "share one unreported completion, frozen queue gates/FIFO/snapshot, "
        "earlier feedback error identity/no RAM publication, cancelled tokens, "
        "Restore, reverse serial, closed queries and physical/Clear/new-query "
        "boundaries PASS");
}
static void zero_sample_query_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalPGRAPHDraw.class,
                                @selector(hasNoRasterSamplesForPrimitive:raster:
                                          geometry:uniforms:width:height:)),
        class_getInstanceMethod(NV2AMetalPGRAPHReports.class,
                                @selector(allocateCounterWithError:)),
        class_getInstanceMethod(NV2AMetalPGRAPHReports.class,
                                @selector(allocateZeroSampleCounterWithError:)),
        class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            @selector(
                prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                rasterClass:ignorePolygonCulling:commands:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:))
    };
    IMP replacements[] = { (IMP)zs_proof, (IMP)zs_allocate,
                           (IMP)zs_allocate_zero, (IMP)zs_prepare,
                           (IMP)vp_wait };
    IMP originals[5];
    for (unsigned i = 0; i < 5; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    zs_proof_original = (void *)originals[0];
    zs_allocate_original = (void *)originals[1];
    zs_allocate_zero_original = (void *)originals[2];
    zs_prepare_original = (void *)originals[3];
    vp_original_wait = (void *)originals[4];
    zs_failure = [NSError errorWithDomain:@"test.zero-sample-feedback"
                                     code:1
                                 userInfo:nil];
    for (unsigned i = 0; i < 5; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        zs_cpu_bounds();
        for (unsigned mode = 0; mode < 14; mode++)
            for (unsigned program = 0; program < 3; program++) {
                NSData *oldWire = nil, *newWire = nil;
                NSData *old = zs_draw_case(mode, program, YES, NO, &oldWire);
                NSData *actual = zs_draw_case(mode, program, NO, NO, &newWire);
                assert([old isEqualToData:actual] &&
                       [oldWire isEqualToData:newWire]);
            }
        NSData *oldWire = nil, *newWire = nil;
        NSData *old = zs_draw_case(2, 1, YES, YES, &oldWire);
        NSData *actual = zs_draw_case(2, 1, NO, YES, &newWire);
        assert([old isEqualToData:actual] && [oldWire isEqualToData:newWire]);
        old = zs_pressure(YES);
        actual = zs_pressure(NO);
        assert([old isEqualToData:actual]);
        for (unsigned snapshot = 0; snapshot < 2; snapshot++) {
            old = zs_feedback(YES, snapshot);
            actual = zs_feedback(NO, snapshot);
            assert([old isEqualToData:actual]);
        }
        zs_zero_lifecycle();
        zs_run_tests();
    } @finally {
        for (unsigned i = 0; i < 5; i++)
            method_setImplementation(methods[i], originals[i]);
        zs_reference = zs_fail_prepare = NO;
        zs_last = nil;
        zs_failure = nil;
        vp_wait_commands = nil;
        vp_release_on_wait = nil;
    }
    puts("Zero-sample queries:42 raster/Current/context/Depth/query/snapshot "
         "pairs, prepare retry, gated one-slot pressure, ordered zero-report "
         "failure/FIFO/restore and completion/cancel lifetime PASS");
}
#endif
