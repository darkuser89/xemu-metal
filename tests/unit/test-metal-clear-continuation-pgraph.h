/* Shader clears preserve an earlier real PGRAPH raster chain.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_CLEAR_CONTINUATION_PGRAPH_H
#define TEST_METAL_CLEAR_CONTINUATION_PGRAPH_H
#import "hw/xbox/nv2a/pgraph/metal/clear.h"

static _Thread_local BOOL ccn_scope, ccn_reference, ccn_fail, ccn_bad_receipt;
static _Thread_local unsigned ccn_admissions, ccn_continuations, ccn_standalone,
    ccn_mismatches;
static NSError *ccn_injected_error;
static BOOL (*ccn_admit_original)(id, SEL, MTL4RenderPassDescriptor *,
                                  const NV2AMetalClearConfig *);
static BOOL ccn_admit(id object, SEL selector, MTL4RenderPassDescriptor *pass,
                      const NV2AMetalClearConfig *config)
{
    BOOL allowed = ccn_admit_original(object, selector, pass, config);
    if (ccn_scope) {
        ccn_admissions += allowed;
        if (ccn_reference)
            return NO;
    }
    return allowed;
}
static BOOL ccn_after_encode(BOOL ok, NSError **error)
{
    if (ok && ccn_scope && ccn_fail) {
        ccn_fail = NO;
        if (error)
            *error = ccn_injected_error;
        return NO;
    }
    return ok;
}
static BOOL (*ccn_encode_original)(id, SEL, id<MTLTexture>, id<MTLTexture>,
                                   const NV2AMetalClearConfig *,
                                   MTL4RenderPassDescriptor *,
                                   NV2AMetalCommands *, NSError **);
static BOOL ccn_encode(id object, SEL selector, id<MTLTexture> color,
                       id<MTLTexture> zeta, const NV2AMetalClearConfig *config,
                       MTL4RenderPassDescriptor *pass,
                       NV2AMetalCommands *commands, NSError **error)
{
    BOOL ok = ccn_encode_original(object, selector, color, zeta, config, pass,
                                  commands, error);
    if (ccn_scope && commands == cpp_commands)
        ccn_continuations += ok;
    return ccn_after_encode(ok, error);
}
static BOOL (*ccn_old_encode_original)(id, SEL, id<MTLTexture>, id<MTLTexture>,
                                       const NV2AMetalClearConfig *,
                                       NV2AMetalCommands *, NSError **);
static BOOL ccn_old_encode(id object, SEL selector, id<MTLTexture> color,
                           id<MTLTexture> zeta,
                           const NV2AMetalClearConfig *config,
                           NV2AMetalCommands *commands, NSError **error)
{
    BOOL ok = ccn_old_encode_original(object, selector, color, zeta, config,
                                      commands, error);
    if (ccn_scope && commands == cpp_commands)
        ccn_standalone += ok;
    return ccn_after_encode(ok, error);
}
static BOOL (*ccn_match_original)(id, SEL, MTL4RenderPassDescriptor *);
static BOOL ccn_match(id object, SEL selector, MTL4RenderPassDescriptor *pass)
{
    BOOL matches = ccn_match_original(object, selector, pass);
    if (ccn_scope && object == cpp_commands && !matches)
        ccn_mismatches++;
    return matches;
}
static BOOL (*ccn_receipt_original)(id, SEL, NSError **);
static BOOL ccn_receipt(id object, SEL selector, NSError **error)
{
    /* Deterministic known dependency failure, not a claimed driver failure.
     * The real blocked native receipt is drained after disabling this stub. */
    if (ccn_scope && ccn_bad_receipt && object == cpp_blocker.lastSubmitted) {
        if (error)
            *error = ccn_injected_error;
        return YES;
    }
    return ccn_receipt_original(object, selector, error);
}

static void ccn_scene(unsigned program, unsigned kind)
{
    cpp_scene(NO, program);
    PGRAPHState *pg = &state->pgraph;
    pg->surface_scale_factor = kind == 1 ? 2 : 1;
    pg->surface_shape.anti_aliasing =
        kind == 2 ? NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4 : 0;
    unsigned extent = kind == 2 ? 16 : 8;
    pg->surface_color.pitch = pg->surface_zeta.pitch = extent * 4;
    cpu_write(1024, extent * extent * 4);
    cpu_write(4096, extent * extent * 4);
    for (unsigned i = 0; i < extent * extent; i++) {
        stl_le_p(state->vram_ptr + 1024 + i * 4, UINT32_C(0xffff0000));
        stl_le_p(state->vram_ptr + 4096 + i * 4, UINT32_C(0xffffff11));
    }
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE;
    pg->regs_[NV_PGRAPH_CONTROL_1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                                     7u << 4 | 0x31u << 8 | 0xffu << 16 |
                                     0xffu << 24;
    pg->regs_[NV_PGRAPH_CONTROL_2] = 1 | 1 << 4 | 3 << 8;
    if (kind == 3)
        pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_DITHERENABLE;
    /* C's inputs are initialized before A owns any source reader lease.
     * No in-flight DMA source is mutated to manufacture a state change. */
    const float c[3][4] = { { 6.5f, 6.5f, 16384, 1 },
                            { 5.5f, 6.5f, 16384, 1 },
                            { 6.5f, 5.5f, 16384, 1 } };
    const float blue[4] = { 0, 0, 1, 1 };
    cpu_write(16896, sizeof(c));
    memcpy(state->vram_ptr + 16896, c, sizeof(c));
    cpu_write(17152, 48);
    for (unsigned i = 0; i < 3; i++)
        memcpy(state->vram_ptr + 17152 + i * 16, blue, 16);
}
static id<MTLBuffer> ccn_gate_start(NSError **error)
{
    cpp_blocker = [[NV2AMetalCommands alloc] initWithDevice:cpp_commands.device
                                                      error:error];
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    cpp_queue = object_getIvar(cpp_commands, ivar);
    id<MTL4CommandQueue> queue = object_getIvar(cpp_blocker, ivar);
    cpp_gate = [cpp_commands.device newSharedEvent];
    require(cpp_blocker && cpp_queue && queue && cpp_gate, *error);
    [queue waitForEvent:cpp_gate value:1];
    require([cpp_blocker beginWithError:error] != nil, *error);
    id<MTLBuffer> marker =
        [cpp_commands.device newBufferWithLength:4
                                         options:MTLResourceStorageModeShared];
    require(marker && [cpp_blocker addResource:marker error:error], *error);
    memset(marker.contents, 0xcd, marker.length);
    id<MTL4ComputeCommandEncoder> e =
        [cpp_blocker.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e fillBuffer:marker range:NSMakeRange(0, 4) value:0x5a];
    [e endEncoding];
    require([cpp_blocker submitWithError:error], *error);
    id<MTLSharedEvent> watchdog = cpp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    return marker;
}
/* Read every native pixel, including all supersampled guest AA/scale pixels.
 * GPU completion precedes this independent queue, and padding is excluded. */
static NSData *ccn_native(NV2AMetalCachedSurface *colorSurface,
                          NV2AMetalCachedSurface *zetaSurface)
{
    NSError *error = nil;
    NV2AMetalCommands *q =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(q && [q beginWithError:&error], error);
    id<MTLTexture> color = [colorSurface.transfer textureForCommands:q
                                                               error:&error];
    id<MTLTexture> zeta = [zetaSurface.transfer textureForCommands:q
                                                             error:&error];
    require(color && zeta && color.width == zeta.width &&
                color.height == zeta.height,
            error);
    NSUInteger row = (color.width * 4 + 255) & ~(NSUInteger)255;
    NSUInteger plane = row * color.height;
    id<MTLBuffer> bytes =
        [q.device newBufferWithLength:3 * plane
                              options:MTLResourceStorageModeShared];
    require(bytes && [q addResource:bytes error:&error], error);
    memset(bytes.contents, 0xcd, bytes.length);
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    id<MTLTexture> textures[] = { color, zeta, zeta };
    MTLBlitOption options[] = { MTLBlitOptionNone,
                                MTLBlitOptionDepthFromDepthStencil,
                                MTLBlitOptionStencilFromDepthStencil };
    for (unsigned p = 0; p < 3; p++)
        [e copyFromTexture:textures[p]
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(color.width, color.height, 1)
                            toBuffer:bytes
                   destinationOffset:p * plane
              destinationBytesPerRow:row
            destinationBytesPerImage:plane
                             options:options[p]];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([q submitWithError:&error] && [q waitUntilIdleWithError:&error],
            error);
    NSMutableData *result = [NSMutableData new];
    for (unsigned p = 0; p < 3; p++)
        for (NSUInteger y = 0; y < color.height; y++)
            [result appendBytes:(uint8_t *)bytes.contents + p * plane + y * row
                         length:color.width * (p == 2 ? 1 : 4)];
    return result;
}
static uint32_t ccn_parameter(unsigned kind)
{
    return kind == 0 ? NV097_CLEAR_SURFACE_R | NV097_CLEAR_SURFACE_A :
           kind == 1 ? NV097_CLEAR_SURFACE_Z :
           kind == 2 ? NV097_CLEAR_SURFACE_STENCIL :
                       NV097_CLEAR_SURFACE_COLOR;
}

typedef struct ClearContinuationWork {
    unsigned full, commits, buffers, waits, active, standalone, admissions,
        mismatches;
    uint64_t gate, batchBefore, batchAfter;
    NSUInteger sectionsBefore, sectionsAfter;
    BOOL pending, markerPending, failed;
} ClearContinuationWork;
static NSData *ccn_run(unsigned program, unsigned kind, unsigned boundary,
                       BOOL reference, ClearContinuationWork *work)
{
    ccn_scene(program, kind);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    cpp_commands = cache.commands;
    qemu_mutex_lock(&pg->lock);
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    if (boundary == 1 || boundary == 4) {
        /* Announce both B fixtures before A. A CPU write during the gated
         * batch would itself exercise the CPU coherence boundary, rather
         * than leave that boundary to the clear under test. */
        dma[0].limit = 65535 - 1024;
        cpu_write(8192, 256);
        memset(state->vram_ptr + 8192, 0x35, 256);
    }
    if (boundary == 1) {
        /* Warm B through its real upload transaction before A. Switching to
         * B below passes initial layout/needsUpload admission, but must
         * reject the different actual texture after entering the scope.
         * Boundary4 deliberately performs no B prepare/upload here. */
        pg->surface_color.offset = 8192 - 1024;
        pg->surface_color.buffer_dirty = true;
        require([surfaces prepareColor:YES
                                  zeta:YES
                          forRendering:NO
                                 error:&error] &&
                    [cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        pg->surface_color.offset = 0;
        pg->surface_color.buffer_dirty = true;
        require([surfaces prepareColor:YES
                                  zeta:YES
                          forRendering:NO
                                 error:&error] &&
                    [cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
    }
    require([draw beginWithError:&error], error);
    id<MTLBuffer> marker = ccn_gate_start(&error);
    cpp_inject = YES;
    cpp_release_on_wait = NO;
    /* prepareRasterPass hook inserts the actual queue dependency only after
     * A's required XF/Writer context publication has completed. */
    require([draw flushDrawWithError:&error], error);
    pg->draw_arrays_length = 0;
    assert(!cpp_inject && cpp_commands.hasPendingRasterPass &&
           !cpp_gate.signaledValue);
    NV2AMetalCachedSurface *oldColor = surfaces.color, *oldZeta = surfaces.zeta;
    if (boundary == 2) {
        /* Earlier successful A survives a known dependency rejection of B. */
        require([cache checkpointWithError:&error], error);
    }
    if (boundary == 1 || boundary == 4) {
        /* A genuine attachment switch retains the conservative old boundary. */
        dma[0].limit = 65535 - 1024;
        pg->surface_color.offset = 8192 - 1024;
        pg->surface_color.buffer_dirty = true;
    }
    pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = UINT32_C(0x80336699);
    pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = UINT32_C(0x004000a5);
    unsigned lo = boundary == 3 ? 0 : 2, hi = boundary == 3 ? 7 : 5;
    pg->regs_[NV_PGRAPH_CLEARRECTX] = pg->regs_[NV_PGRAPH_CLEARRECTY] =
        lo | hi << 16;
    unsigned flags = boundary == 3 ?
                         NV097_CLEAR_SURFACE_COLOR | NV097_CLEAR_SURFACE_Z |
                             NV097_CLEAR_SURFACE_STENCIL :
                         ccn_parameter(kind);
    work->batchBefore = cpp_commands.batchSerial;
    work->sectionsBefore = cpp_commands.sealedBufferCount;
    cpp_commits = cpp_buffers = cpp_full = cpp_waits = 0;
    ccn_admissions = ccn_continuations = ccn_standalone = ccn_mismatches = 0;
    ccn_reference = reference;
    ccn_scope = YES;
    ccn_bad_receipt = boundary == 2;
    BOOL late = !boundary && !program && !kind;
    ccn_fail = late;
    ccn_injected_error =
        [NSError errorWithDomain:late ? @"test.clear-continuation.late" :
                                        @"test.clear-continuation.dependency"
                            code:1
                        userInfo:nil];
    cpp_release_on_wait = reference || boundary;
    BOOL ok = [draw clearSurface:flags error:&error];
    if (late) {
        assert(!ok && error == ccn_injected_error && !ccn_fail);
        error = nil;
        ok = [draw clearSurface:flags error:&error];
    }
    work->failed = !ok;
    if (boundary == 2)
        assert(!ok && error == ccn_injected_error);
    else
        require(ok, error);
    ccn_scope = ccn_bad_receipt = NO;
    ccn_reference = NO;
    cpp_release_on_wait = NO;
    work->full = cpp_full;
    work->commits = cpp_commits;
    work->buffers = cpp_buffers;
    work->waits = cpp_waits;
    work->active = ccn_continuations;
    work->standalone = ccn_standalone;
    work->admissions = ccn_admissions;
    work->mismatches = ccn_mismatches;
    work->gate = cpp_gate.signaledValue;
    work->batchAfter = cpp_commands.batchSerial;
    work->sectionsAfter = cpp_commands.sealedBufferCount;
    work->pending = cpp_commands.hasPendingRasterPass;
    work->markerPending =
        !work->gate && *(uint32_t *)marker.contents == UINT32_C(0xcdcdcdcd);
    error = nil;
    NSData *pending = nil, *begin = nil, *vertex = nil;
    if (boundary == 2) {
        /* The simulation is gone; neither the real GPU receipt nor its data
         * was replaced. Submit A after releasing the actual dependency. */
        pending = [draw pendingSnapshotWithError:&error];
        begin = [draw beginSnapshotWithError:&error];
        vertex = draw.vertexSnapshot;
        require(pending && begin && vertex && [draw endWithError:&error],
                error);
        cpp_gate.signaledValue = 1;
    } else {
        /* C consumes disjoint DMA bytes in the SAME active Begin. This
         * exercises stateByApplyingClear and the original captured bindings,
         * rather than replacing the pixel state with a fresh Begin. */
        require([draw prepareVertexStateChangeWithError:&error], error);
        pg->vertex_attributes[0].offset = 512;
        pg->vertex_attributes[3].offset = 768;
        pg->draw_arrays_length = 1;
        require([draw flushDrawWithError:&error], error);
        pg->draw_arrays_length = 0;
        pending = [draw pendingSnapshotWithError:&error];
        begin = [draw beginSnapshotWithError:&error];
        vertex = draw.vertexSnapshot;
        require(pending && begin && vertex && [draw endWithError:&error],
                error);
        cpp_gate.signaledValue = 1;
    }
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error] &&
                [cpp_blocker waitUntilIdleWithError:&error],
            error);
    /* No host GPU-output reads occur before all real feedback above. */
    NSMutableData *actual =
        [ccn_native(surfaces.color, surfaces.zeta) mutableCopy];
    if (boundary == 1 || boundary == 4)
        [actual appendData:ccn_native(oldColor, oldZeta)];
    NV2AMetalSurfaceConfig config = surfaces.color.transfer.config;
    NSUInteger span = config.pitch * config.height;
    require([cache prepareCPUAccessAtAddress:surfaces.color.address
                                      length:span
                                       write:NO
                                       error:&error] &&
                [cache prepareCPUAccessAtAddress:4096
                                          length:span
                                           write:NO
                                           error:&error],
            error);
    [actual appendBytes:state->vram_ptr + surfaces.color.address length:span];
    [actual appendBytes:state->vram_ptr + 4096 length:span];
    if (boundary != 1 && boundary != 3 && boundary != 4) {
        /* Downloads remove enhancement scale, but preserve the guest AA
         * layout (16x16 and pitch64 for SQUARE_OFFSET_4). */
        unsigned ax = pg->surface_shape.anti_aliasing ? 2 : 1;
        unsigned ay =
            pg->surface_shape.anti_aliasing ==
                    NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4 ?
                2 :
                1;
        uint32_t a = (uint32_t)ldl_le_p(state->vram_ptr + 1024 +
                                        ay * config.pitch + ax * 4);
        if (a != UINT32_C(0xff00ff00))
            fprintf(stderr,
                    "Clear continuation A witness program%u kind%u "
                    "boundary%u reference%d value%08x pitch%u scale%u "
                    "AA%u full%u active%u standalone%u gate%llu\n",
                    program, kind, boundary, reference, a, config.pitch,
                    config.scale, pg->surface_shape.anti_aliasing, work->full,
                    work->active, work->standalone,
                    (unsigned long long)work->gate);
        assert(a == UINT32_C(0xff00ff00)); /* A lies outside B and C. */
    }
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    require(query != 0, nil);
    [actual appendData:cpp_capture(query)];
    [actual appendData:pending];
    [actual appendData:begin];
    [actual appendData:vertex];
    BOOL dirty[] = { surfaces.color.dirty, surfaces.zeta.dirty,
                     pg->surface_color.draw_dirty,
                     pg->surface_zeta.draw_dirty };
    [actual appendBytes:dirty length:sizeof(dirty)];
    if (!boundary && program == 1 && kind == 1) {
        /* Restore uses the public archive boundary after successful feedback,
         * never mutable/no-copy views into earlier GPU or host state. */
        require([draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    (!pending.length || [draw restorePendingSnapshot:pending
                                                               error:&error]) &&
                    [draw beginWithError:&error],
                error);
        NSData *resaved = [draw beginSnapshotWithError:&error];
        require(resaved && [draw endWithError:&error], error);
        assert([begin isEqualToData:resaved]);
        [actual appendData:resaved];
    }
    if (!boundary && program == 1 && kind == 3) {
        /* Real post-clear RTT capture, followed by an announced CPU alias
         * store, cannot alter the retained private snapshot. */
        dma[3].address = 1024;
        texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
        require([draw beginWithError:&error], error);
        NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
        NV2AMetalCachedTexture *snapshot =
            [pixel.textureSnapshot textureAtIndex:0];
        require(snapshot != nil, nil);
        require([draw endWithError:&error] && [cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        NSData *before = rttp_texture_bytes(snapshot.binding.texture, &error);
        require(before && [cache resolveCPUAccessAtAddress:1024
                                                    length:256
                                                     write:YES
                                                     error:&error],
                error);
        memset(state->vram_ptr + 1024, 0x46, 256);
        NSData *after = rttp_texture_bytes(snapshot.binding.texture, &error);
        require(after != nil, error);
        assert([before isEqualToData:after]);
        [actual appendData:before];
        [actual appendData:after];
    }
    assert(*(uint32_t *)marker.contents == UINT32_C(0x5a5a5a5a));
    qemu_mutex_unlock(&pg->lock);
    cpp_tail = nil;
    cpp_commands = cpp_blocker = nil;
    cpp_queue = nil;
    cpp_gate = nil;
    ccn_injected_error = nil;
    return actual;
}

static void clear_continuation_pgraph_tests(void)
{
    fixture();
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:NULL];
    Ivar queue = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalClear.class,
                                @selector(canContinueRasterPass:config:)),
        class_getInstanceMethod(
            NV2AMetalClear.class,
            @selector(encodeColor:zeta:config:rasterPass:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalClear.class,
            @selector(encodeColor:zeta:config:commands:error:)),
        class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                @selector(prepareRasterPass:targets:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitUntilIdleWithError:)),
        class_getInstanceMethod(object_getClass(object_getIvar(probe, queue)),
                                @selector(commit:count:options:)),
        class_getInstanceMethod(NV2AMetalSubmission.class,
                                @selector(completedWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(rasterPassMatches:))
    };
    IMP replacements[] = { (IMP)ccn_admit,      (IMP)ccn_encode,
                           (IMP)ccn_old_encode, (IMP)cpp_raster,
                           (IMP)cpp_submit,     (IMP)cpp_wait,
                           (IMP)cpp_producers,  (IMP)cpp_idle,
                           (IMP)cpp_commit,     (IMP)ccn_receipt,
                           (IMP)ccn_match },
        originals[G_N_ELEMENTS(methods)];
    for (unsigned i = 0; i < G_N_ELEMENTS(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    ccn_admit_original = (void *)originals[0];
    ccn_encode_original = (void *)originals[1];
    ccn_old_encode_original = (void *)originals[2];
    cpp_raster_original = (void *)originals[3];
    cpp_full_original = (void *)originals[4];
    cpp_wait_original = (void *)originals[5];
    cpp_producers_original = (void *)originals[6];
    cpp_idle_original = (void *)originals[7];
    cpp_commit_original = (void *)originals[8];
    ccn_receipt_original = (void *)originals[9];
    ccn_match_original = (void *)originals[10];
    for (unsigned i = 0; i < G_N_ELEMENTS(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned test = 0; test < 16; test++) {
            unsigned program = test < 12 ? test / 4 : 0;
            unsigned kind = test < 12 ? test % 4 : 0;
            unsigned boundary = test < 12  ? 0 :
                                test == 12 ? 3 :
                                test == 13 ? 1 :
                                test == 14 ? 2 :
                                             4;
            ClearContinuationWork work[2] = { 0 };
            NSData *reference = ccn_run(program, kind, boundary, YES, &work[0]);
            NSData *actual = ccn_run(program, kind, boundary, NO, &work[1]);
            if (![reference isEqualToData:actual]) {
                fprintf(stderr,
                        "Clear continuation PGRAPH byte mismatch case%u "
                        "program%u kind%u boundary%u\n",
                        test, program, kind, boundary);
                abort();
            }
            /* All Color/nativeDepth/Stencil/query/Current/constants/archive
             * comparisons above precede these route observations. */
            if (!boundary) {
                unsigned encodes = !program && !kind ? 2 : 1;
                assert(work[0].full == 1 && work[0].standalone == encodes &&
                       work[0].active == 0 && work[1].full == 0 &&
                       work[1].active == encodes && !work[1].standalone &&
                       work[0].admissions && work[1].admissions &&
                       work[1].gate == 0 && !work[1].commits &&
                       !work[1].waits && work[1].markerPending &&
                       work[1].pending &&
                       work[1].batchBefore == work[1].batchAfter &&
                       work[1].sectionsAfter > work[1].sectionsBefore);
            } else if (boundary == 2) {
                assert(work[0].failed && work[1].failed && !work[0].active &&
                       !work[0].standalone && !work[1].active &&
                       !work[1].standalone && work[1].gate == 0 &&
                       !work[1].commits);
            } else {
                if (!(work[0].standalone == 1 && work[1].standalone == 1 &&
                      !work[0].active && !work[1].active && work[0].full == 1 &&
                      work[1].full == 1))
                    for (unsigned side = 0; side < 2; side++)
                        fprintf(stderr,
                                "Clear boundary%u reference%d full%u "
                                "active%u standalone%u admission%u mismatch%u "
                                "commits%u buffers%u waits%u gate%llu "
                                "batch%llu/%llu sections%lu/%lu pending%d\n",
                                boundary, side == 0, work[side].full,
                                work[side].active, work[side].standalone,
                                work[side].admissions, work[side].mismatches,
                                work[side].commits, work[side].buffers,
                                work[side].waits,
                                (unsigned long long)work[side].gate,
                                (unsigned long long)work[side].batchBefore,
                                (unsigned long long)work[side].batchAfter,
                                (unsigned long)work[side].sectionsBefore,
                                (unsigned long)work[side].sectionsAfter,
                                work[side].pending);
                assert(work[0].standalone == 1 && work[1].standalone == 1 &&
                       !work[0].active && !work[1].active &&
                       work[0].full == 1 && work[1].full == 1);
                if (boundary == 1)
                    assert(work[0].admissions && work[1].admissions &&
                           !work[0].mismatches && work[1].mismatches == 1);
                if (boundary == 4)
                    assert(!work[0].admissions && !work[1].admissions &&
                           !work[0].mismatches && !work[1].mismatches);
            }
        }
    } @finally {
        if (cpp_gate)
            cpp_gate.signaledValue = 1;
        for (unsigned i = 0; i < G_N_ELEMENTS(methods); i++)
            method_setImplementation(methods[i], originals[i]);
        ccn_scope = ccn_reference = ccn_fail = ccn_bad_receipt = NO;
        ccn_injected_error = nil;
        cpp_inject = cpp_release_on_wait = NO;
        cpp_commands = cpp_blocker = nil;
        cpp_tail = nil;
        cpp_gate = nil;
        cpp_queue = nil;
    }
    printf("Clear continuation PGRAPH: 12 exact draw/clear/draw pairs + "
           "load/warm-cold-attachment/dependency boundaries PASS; late retry, "
           "Restore, "
           "RTT/CPU alias; guest scale/AA, simulated known error\n");
    groups++;
}
#endif
