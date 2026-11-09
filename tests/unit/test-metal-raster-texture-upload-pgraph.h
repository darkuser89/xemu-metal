/* Cold texture producers may finish ahead of an unrelated real raster chain.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RASTER_TEXTURE_UPLOAD_PGRAPH_H
#define TEST_METAL_RASTER_TEXTURE_UPLOAD_PGRAPH_H

static BOOL rtp_reference, rtp_scope, rtp_arm_a, rtp_fail_emit, rtp_known_error;
static NV2AMetalCommands *rtp_commands, *rtp_foreign;
static NV2AMetalSurfaceRecording *rtp_a;
static id<MTL4CommandQueue> rtp_queue;
static id<MTLSharedEvent> rtp_gate, rtp_foreign_gate;
static id<MTLBuffer> rtp_foreign_marker;
static NSMapTable<id, NSNumber *> *rtp_rasters;
static NSError *rtp_failure;
static unsigned rtp_full, rtp_commits, rtp_raster_commits, rtp_waits,
    rtp_uploads, rtp_admissions;
static BOOL (*rtp_admit_original)(id, SEL, const NV2AMetalVRAMReadPattern *,
                                  NSUInteger, NSRange);
static BOOL rtp_admit(id owner, SEL selector,
                      const NV2AMetalVRAMReadPattern *patterns,
                      NSUInteger count, NSRange bounds)
{
    BOOL allowed = rtp_admit_original(owner, selector, patterns, count, bounds);
    if (rtp_scope && owner == surfaces.cache) {
        rtp_admissions += allowed;
        if (rtp_reference)
            return NO;
    }
    return allowed;
}
static void (*rtp_begin_original)(id, SEL, id<MTL4CommandAllocator>);
static void rtp_begin(id owner, SEL selector,
                      id<MTL4CommandAllocator> allocator)
{
    [rtp_rasters removeObjectForKey:owner];
    rtp_begin_original(owner, selector, allocator);
}
static id<MTL4RenderCommandEncoder> (*rtp_encoder_original)(
    id, SEL, MTL4RenderPassDescriptor *, MTL4RenderEncoderOptions);
static id<MTL4RenderCommandEncoder>
rtp_encoder(id owner, SEL selector, MTL4RenderPassDescriptor *pass,
            MTL4RenderEncoderOptions options)
{
    id<MTL4RenderCommandEncoder> encoder =
        rtp_encoder_original(owner, selector, pass, options);
    if (encoder && options)
        [rtp_rasters setObject:@(options) forKey:owner];
    return encoder;
}
static void (*rtp_commit_original)(id, SEL, const id<MTL4CommandBuffer> *,
                                   NSUInteger, MTL4CommitOptions *);
static void rtp_commit(id owner, SEL selector,
                       const id<MTL4CommandBuffer> *buffers, NSUInteger count,
                       MTL4CommitOptions *options)
{
    if (owner == rtp_queue) {
        BOOL raster = NO;
        for (NSUInteger i = 0; i < count; i++)
            raster |= [rtp_rasters objectForKey:buffers[i]] != nil;
        if (raster) {
            for (NSUInteger i = 0; i < count; i++)
                assert([rtp_rasters objectForKey:buffers[i]]);
            /* The actual raster commit is the ONLY queue gate insertion.
             * Producer-prefix commits before it remain executable. */
            [rtp_queue waitForEvent:rtp_gate value:1];
            rtp_raster_commits++;
        }
        rtp_commits++;
        for (NSUInteger i = 0; i < count; i++)
            [rtp_rasters removeObjectForKey:buffers[i]];
    }
    rtp_commit_original(owner, selector, buffers, count, options);
}
static void rtp_waiting(id owner)
{
    if (owner != rtp_commands)
        return;
    rtp_waits++;
    if (rtp_raster_commits && !rtp_gate.signaledValue)
        rtp_gate.signaledValue = 1;
}
static BOOL (*rtp_wait_original)(id, SEL, id, NSError **);
static BOOL rtp_wait(id owner, SEL selector, id receipt, NSError **error)
{
    rtp_waiting(owner);
    return rtp_wait_original(owner, selector, receipt, error);
}
static BOOL (*rtp_producer_original)(id, SEL, id, NSError **);
static BOOL rtp_producer(id owner, SEL selector, id receipt, NSError **error)
{
    rtp_waiting(owner);
    return rtp_producer_original(owner, selector, receipt, error);
}
static BOOL (*rtp_idle_original)(id, SEL, NSError **);
static BOOL rtp_idle(id owner, SEL selector, NSError **error)
{
    rtp_waiting(owner);
    return rtp_idle_original(owner, selector, error);
}
static BOOL (*rtp_full_original)(id, SEL, NSError **);
static BOOL rtp_submit(id owner, SEL selector, NSError **error)
{
    rtp_full += owner == rtp_commands;
    return rtp_full_original(owner, selector, error);
}
static id (*rtp_upload_original)(id, SEL, id, NSUInteger, id, NSUInteger,
                                 NSUInteger, const NV2AMetalTextureShape *, id,
                                 NSError **);
static id rtp_upload(id owner, SEL selector, id data, NSUInteger offset,
                     id palette, NSUInteger paletteOffset,
                     NSUInteger paletteLength,
                     const NV2AMetalTextureShape *shape, id commands,
                     NSError **error)
{
    id result = rtp_upload_original(owner, selector, data, offset, palette,
                                    paletteOffset, paletteLength, shape,
                                    commands, error);
    if (rtp_scope && commands == rtp_commands)
        rtp_uploads += result != nil;
    return result;
}
static BOOL (*rtp_emit_original)(id, SEL, id, id, NSError **);
static BOOL rtp_emit(id owner, SEL selector, id encoder, id commands,
                     NSError **error)
{
    BOOL ok = rtp_emit_original(owner, selector, encoder, commands, error);
    if (ok && commands == rtp_commands && rtp_arm_a) {
        rtp_arm_a = NO;
        rtp_a = surfaces.cache.recording;
        if (rtp_foreign)
            return [rtp_commands orderAfterSubmission:rtp_foreign.lastSubmitted
                                         fromCommands:rtp_foreign
                                                error:error];
    }
    if (ok && commands == rtp_commands && rtp_fail_emit) {
        rtp_fail_emit = NO;
        if (error)
            *error = rtp_failure;
        return NO;
    }
    return ok;
}
static BOOL (*rtp_feedback_original)(id, SEL, NSError **);
static BOOL rtp_feedback(id owner, SEL selector, NSError **error)
{
    NSError *failure = nil;
    BOOL ready = rtp_feedback_original(owner, selector, &failure);
    /* Decorate only real, already successful native feedback. No completion
     * or GPU output is substituted by the known-error fixture. */
    if (rtp_known_error && owner == rtp_foreign.lastSubmitted) {
        assert(ready && !failure);
        failure = rtp_failure;
    }
    if (error)
        *error = failure;
    return ready;
}
static uint32_t rtp_color(unsigned stage)
{
    const uint32_t colors[] = { UINT32_C(0xff0000ff), UINT32_C(0xff00ffff),
                                UINT32_C(0xffff00ff), UINT32_C(0xffff8000) };
    return colors[stage];
}
static NSUInteger rtp_palette(unsigned stage)
{
    return 49152 + 4096 + stage * 1024; /* Report DMA remains at49152. */
}
static void rtp_registers(unsigned stages, BOOL shortPalette, BOOL bad,
                          BOOL rtt)
{
    PGRAPHState *pg = &state->pgraph;
    texture_registers(NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 32);
    const unsigned outputs[] = { PS_REGISTER_T0, PS_REGISTER_T1, PS_REGISTER_T2,
                                 PS_REGISTER_T3 };
    pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
    for (unsigned i = 0; i < 4; i++) {
        pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] =
            i < stages ? NV_PGRAPH_TEXCTL0_0_ENABLE : 0;
        if (i >= stages)
            continue;
        BOOL palette = shortPalette || (i & 1);
        unsigned format = palette ?
                              NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8 :
                              NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8;
        pg->regs_[NV_PGRAPH_TEXFMT0 + i * 4] = format << 8 | 2 << 6 |
                                               NV_PGRAPH_TEXFMT0_BORDER_SOURCE |
                                               1 << 16 | 3 << 20 | 3 << 24;
        pg->regs_[NV_PGRAPH_TEXOFFSET0 + i * 4] = i * 512;
        pg->regs_[NV_PGRAPH_TEXCTL1_0 + i * 4] = palette ? 0 : 32 << 16;
        pg->regs_[NV_PGRAPH_TEXIMAGERECT0 + i * 4] = 8 << 16 | 8;
        pg->regs_[NV_PGRAPH_TEXFILTER0 + i * 4] = 1 << 16 | 1 << 24;
        pg->regs_[NV_PGRAPH_TEXADDRESS0 + i * 4] = 3 | 3 << 8 | 3 << 16;
        pg->regs_[NV_PGRAPH_TEXPALETTE0 + i * 4] =
            NV_PGRAPH_TEXPALETTE0_CONTEXT_DMA | (shortPalette ? 3u << 2 : 0) |
            (4096 + i * 1024);
        pg->regs_[NV_PGRAPH_SHADERPROG] |= PS_TEXTUREMODES_PROJECT2D << (5 * i);
        pg->texture_dirty[i] = true;
        pg->vertex_attributes[9 + i].inline_value[0] =
            pg->vertex_attributes[9 + i].inline_value[1] =
                palette ? .1875f : 1.5f;
    }
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = outputs[stages - 1];
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
        (outputs[stages - 1] | PS_CHANNEL_ALPHA) << 8;
    pg->vertex_attributes[0].offset = 512;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 3;
    if (rtt)
        dma[3].address = 1024;
    (void)bad; /* The invalid byte was initialized before A's reader leases. */
}
static void rtp_foreign_start(void)
{
    NSError *error = nil;
    rtp_foreign = [[NV2AMetalCommands alloc] initWithDevice:rtp_commands.device
                                                      error:&error];
    rtp_foreign_gate = [rtp_commands.device newSharedEvent];
    require(rtp_foreign && rtp_foreign_gate, error);
    [((id<MTL4CommandQueue>)[rtp_foreign
        valueForKey:@"queue"]) waitForEvent:rtp_foreign_gate value:1];
    require([rtp_foreign beginWithError:&error] != nil, error);
    rtp_foreign_marker =
        [rtp_commands.device newBufferWithLength:4
                                         options:MTLResourceStorageModeShared];
    require(rtp_foreign_marker && [rtp_foreign addResource:rtp_foreign_marker
                                                     error:&error],
            error);
    memset(rtp_foreign_marker.contents, 0xcd, 4);
    id<MTL4ComputeCommandEncoder> e =
        [rtp_foreign.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e fillBuffer:rtp_foreign_marker range:NSMakeRange(0, 4) value:0x6b];
    [e endEncoding];
    require([rtp_foreign submitWithError:&error], error);
}
static NSData *rtp_texture(NV2AMetalCachedTexture *texture, unsigned stage,
                           BOOL rtt)
{
    NSError *error = nil;
    NV2AMetalCommands *q =
        [[NV2AMetalCommands alloc] initWithDevice:rtp_commands.device
                                            error:&error];
    require(q && [q beginWithError:&error], error);
    id<MTLBuffer> read =
        test_metal_read_texture(q, texture.binding.texture, 0, 0);
    require(read && [q submitWithError:&error] &&
                [q waitUntilIdleWithError:&error],
            error);
    NSMutableData *result = [NSMutableData new];
    for (unsigned y = 0; y < 8; y++) {
        const float *row =
            (const float *)((const uint8_t *)read.contents + y * 256);
        for (unsigned x = 0; x < 8; x++) {
            BOOL green =
                (x == 1 && y == 1) || (x == 4 && y == 1) || (x == 1 && y == 4);
            uint32_t word =
                rtt ? (green ? UINT32_C(0xff00ff00) : UINT32_C(0xffff0000)) :
                      rtp_color(stage);
            float expected[] = { ((word >> 16) & 255) / 255.f,
                                 ((word >> 8) & 255) / 255.f,
                                 (word & 255) / 255.f, (word >> 24) / 255.f };
            for (unsigned c = 0; c < 4; c++)
                assert(fabsf(row[x * 4 + c] - expected[c]) < .000001f);
        }
        [result appendBytes:row length:8 * 16];
    }
    return result;
}
static NSData *rtp_frame(unsigned queryCount)
{
    NSError *error = nil;
    require([surfaces.cache submitWithError:&error] &&
                [surfaces.cache waitUntilIdleWithError:&error] &&
                [surfaces.cache prepareCPUAccessAtAddress:1024
                                                   length:256
                                                    write:NO
                                                    error:&error] &&
                [surfaces.cache prepareCPUAccessAtAddress:4096
                                                   length:256
                                                    write:NO
                                                    error:&error] &&
                [draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    assert(report_value(0) == queryCount);
    return cpp_capture(queryCount);
}
typedef struct RasterTextureUploadWork {
    unsigned full, raster, uploads, admissions, waits;
    BOOL aSubmitted, pending;
    uint64_t gate;
} RasterTextureUploadWork;
static NSData *rtp_run(unsigned kind, BOOL reference,
                       RasterTextureUploadWork *work)
{
    BOOL ro = kind & 1;
    cpp_scene(NO, ro);
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    rtp_commands = cache.commands;
    rtp_queue = [rtp_commands valueForKey:@"queue"];
    rtp_reference = reference;
    rtp_known_error = NO;
    rtp_foreign = nil;
    rtp_foreign_gate = nil;
    rtp_foreign_marker = nil;
    unsigned stages = kind < 4 ? kind + 1 : kind == 6 || kind == 9 ? 2 : 1;
    BOOL shortPalette = kind == 4 || kind == 5;
    dma[3].limit = 8191;
    dma[4].limit = 16383;
    if (ro) {
        mov(0, 0, 0, false);
        mov(1, 3, 3, false);
        for (unsigned i = 0; i < 4; i++)
            mov(2 + i, 9 + i, 9 + i, i == 3);
    }
    const float positions[3][4] = { { 6.5f, 6.5f, 16384, 1 },
                                    { 5.5f, 6.5f, 16384, 1 },
                                    { 6.5f, 5.5f, 16384, 1 } };
    cpu_write(16896, sizeof(positions));
    memcpy(state->vram_ptr + 16896, positions, sizeof(positions));
    /* All cold bytes are announced BEFORE A. No CPU prewrite can secretly
     * perform the very Full boundary this test is intended to observe. */
    for (unsigned i = 0; i < stages; i++) {
        cpu_write(32768 + i * 512, 256);
        if (shortPalette || (i & 1))
            memset(state->vram_ptr + 32768 + i * 512, kind == 5 ? 32 : 0, 256);
        else
            for (unsigned p = 0; p < 64; p++)
                stl_le_p(state->vram_ptr + 32768 + i * 512 + p * 4,
                         rtp_color(i));
        cpu_write(rtp_palette(i), 1024);
        for (unsigned p = 0; p < 256; p++)
            stl_le_p(state->vram_ptr + rtp_palette(i) + p * 4,
                     kind == 6 && i == 1 ? UINT32_C(0xffff0000) : rtp_color(i));
    }
    qemu_mutex_lock(&pg->lock);
    require([surfaces prepareColor:YES zeta:YES forRendering:NO error:&error] &&
                [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    if (kind == 6) {
        NV2AMetalSurfaceConfig c = {
            .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            .width = 8,
            .height = 4,
            .pitch = 32,
            .scale = 1,
            .color = YES
        };
        NV2AMetalCachedSurface *alias =
            [cache prepareSurfaceAtAddress:rtp_palette(1)
                                    config:&c
                                     frame:1
                              forRendering:YES
                                     error:&error];
        NV2AMetalClear *clear =
            [[NV2AMetalClear alloc] initWithDevice:rtp_commands.device
                                             error:&error];
        NV2AMetalClearConfig cc = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                    .rect = { 0, 0, 8, 4 },
                                    .uniforms = { .color = { 0, 1, 1, 1 } } };
        id<MTLTexture> t = [alias.transfer textureForCommands:rtp_commands
                                                        error:&error];
        require(alias && clear && t &&
                    [clear encodeColor:t
                                  zeta:nil
                                config:&cc
                              commands:rtp_commands
                                 error:&error] &&
                    [cache markWritten:alias
                        replacingContents:YES
                                    error:&error] &&
                    [cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
    }
    rtp_gate = [rtp_commands.device newSharedEvent];
    require(rtp_gate != nil, nil);
    id<MTLSharedEvent> watchdog = rtp_gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!watchdog.signaledValue)
                         watchdog.signaledValue = 2;
                   });
    rtp_failure = [NSError errorWithDomain:@"test.raster-texture-upload"
                                      code:79
                                  userInfo:nil];
    if (kind == 8)
        rtp_foreign_start();
    rtp_arm_a = YES;
    require([draw drawWithError:&error], error);
    assert(!rtp_arm_a && rtp_a && !rtp_a.submitted &&
           rtp_commands.hasPendingRasterPass);
    if (kind == 8) {
        rtp_foreign_gate.signaledValue = 1;
        require([rtp_foreign waitUntilIdleWithError:&error], error);
        assert(
            [rtp_foreign.lastSubmitted completedWithError:&error] && !error &&
            *(uint32_t *)rtp_foreign_marker.contents == UINT32_C(0x6b6b6b6b));
        rtp_known_error = YES;
    }
    rtp_registers(stages, shortPalette, kind == 5, kind == 7);
    rtp_full = rtp_commits = rtp_raster_commits = rtp_waits = rtp_uploads =
        rtp_admissions = 0;
    rtp_scope = YES;
    NSData *checkpoint = fpp_host();
    BOOL ok = [draw beginWithError:&error];
    NSMutableData *actual = [NSMutableData new];
    if (kind == 5 || kind == 8) {
        assert(!ok && error && [checkpoint isEqualToData:fpp_host()] &&
               pg->draw_time == 1);
        if (kind == 8)
            assert(error == rtp_failure && !rtp_uploads && !rtp_raster_commits);
        else {
            assert([error.localizedDescription
                containsString:@"palette index fault"]);
            if (reference)
                assert(rtp_full == 1 && rtp_raster_commits == 1 &&
                       rtp_gate.signaledValue == 1);
            else
                assert(!rtp_full && !rtp_raster_commits &&
                       !rtp_gate.signaledValue && !rtp_a.submitted &&
                       rtp_uploads == 1);
        }
        [actual
            appendData:[error.domain dataUsingEncoding:NSUTF8StringEncoding]];
        [actual appendBytes:&(NSInteger){ error.code }
                     length:sizeof(NSInteger)];
        rtp_known_error = NO;
        error = nil;
        if (kind == 8) {
            *work =
                (RasterTextureUploadWork){ rtp_full,
                                           rtp_raster_commits,
                                           rtp_uploads,
                                           rtp_admissions,
                                           rtp_waits,
                                           rtp_a.submitted,
                                           rtp_commands.hasPendingRasterPass,
                                           rtp_gate.signaledValue };
            rtp_scope = NO;
            rtp_gate.signaledValue = 1;
            [actual appendData:rtp_frame(3)];
            qemu_mutex_unlock(&pg->lock);
            return actual;
        }
        require([cache resolveCPUAccessAtAddress:32768
                                          length:64
                                           write:YES
                                           error:&error],
                error);
        /* Producer feedback does not retire CPU-write hazards from a
         * section sealed while A's raster pass was pending. This source
         * repair requires the original Full boundary before changing RAM. */
        if (rtp_gate.signaledValue != 1 || !rtp_a.submitted)
            fprintf(stderr,
                    "Raster texture repair reference%d full%u raster%u "
                    "waits%u gate%llu submitted%d\n",
                    reference, rtp_full, rtp_raster_commits, rtp_waits,
                    (unsigned long long)rtp_gate.signaledValue,
                    rtp_a.submitted);
        assert(rtp_gate.signaledValue == 1 && rtp_a.submitted);
        memset(state->vram_ptr + 32768, 0, 64);
        rtp_scope = NO;
        rtp_full = rtp_commits = rtp_raster_commits = rtp_waits = rtp_uploads =
            rtp_admissions = 0;
        rtp_scope = YES;
        require([draw beginWithError:&error], error);
    } else
        require(ok, error);
    NV2AMetalPGRAPHPixelState *pixel = [draw valueForKey:@"pixelState"];
    NV2AMetalPGRAPHTextureSnapshot *textures = pixel.textureSnapshot;
    NSData *begin = [draw beginSnapshotWithError:&error];
    require(begin != nil, error);
    for (unsigned i = 0; i < stages; i++) {
        NV2AMetalCachedTexture *texture = [textures textureAtIndex:i];
        require(texture && texture.producerRecording.producersCompleted, nil);
        [actual appendData:rtp_texture(texture, i, kind == 7)];
    }
    if (kind == 6)
        assert((uint32_t)ldl_le_p(state->vram_ptr + rtp_palette(1)) ==
               rtp_color(1));
    [actual appendData:begin];
    *work = (RasterTextureUploadWork){ rtp_full,
                                       rtp_raster_commits,
                                       rtp_uploads,
                                       rtp_admissions,
                                       rtp_waits,
                                       rtp_a.submitted,
                                       rtp_commands.hasPendingRasterPass,
                                       rtp_gate.signaledValue };
    rtp_scope = NO;
    if (kind == 9) {
        NV2AMetalCachedTexture *old = [textures textureAtIndex:0];
        NSData *oldPixels = rtp_texture(old, 0, NO);
        unsigned fullBefore = rtp_full;
        require([cache resolveCPUAccessAtAddress:32768
                                          length:256
                                           write:YES
                                           error:&error],
                error);
        /* Snapshot feedback leaves CPU-write hazards intact. Candidate A
         * now needs one Full boundary; the reference already completed A. */
        assert(rtp_full == fullBefore + !reference &&
               rtp_gate.signaledValue == 1 && rtp_a.submitted);
        memset(state->vram_ptr + 32768, 0x35, 256);
        assert([oldPixels isEqualToData:rtp_texture(old, 0, NO)]);
        require([draw prepareVertexStateChangeWithError:&error], error);
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *vertex = draw.vertexSnapshot;
        require(pending && vertex, error);
        NSData *host = fpp_host();
        rtp_fail_emit = YES;
        assert(![draw flushDrawWithError:&error] && error == rtp_failure &&
               !rtp_fail_emit && [host isEqualToData:fpp_host()]);
        error = nil;
        require([draw endWithError:&error], error);
        rtp_gate.signaledValue = 1;
        [actual appendData:rtp_frame(6)];
        require([draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    (!pending.length || [draw restorePendingSnapshot:pending
                                                               error:&error]) &&
                    [draw beginWithError:&error] && [draw endWithError:&error],
                error);
        [actual appendData:rtp_frame(3)];
        [actual appendData:pending];
        [actual appendData:vertex];
    } else {
        require([draw endWithError:&error], error);
        rtp_gate.signaledValue = 1;
        [actual appendData:rtp_frame(6)];
    }
    color(1, 1, UINT32_C(0xff00ff00));
    color(4, 1, UINT32_C(0xff00ff00));
    color(1, 4, UINT32_C(0xff00ff00));
    uint32_t expected =
        kind == 7 ? UINT32_C(0xff00ff00) : rtp_color(stages - 1);
    color(6, 6, expected);
    color(5, 6, expected);
    color(6, 5, expected);
    qemu_mutex_unlock(&pg->lock);
    return actual;
}
static void raster_texture_upload_pgraph_tests(void)
{
    id<MTL4CommandBuffer> probe =
        [surfaces.cache.commands.device newCommandBuffer];
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            NSSelectorFromString(
                @"canQueueTextureUploadReadPatterns:count:bounds:")),
        class_getInstanceMethod([probe class],
                                @selector(beginCommandBufferWithAllocator:)),
        class_getInstanceMethod(
            [probe class],
            @selector(renderCommandEncoderWithDescriptor:options:)),
        class_getInstanceMethod(
            [object_getIvar(surfaces.cache.commands, queueIvar) class],
            @selector(commit:count:options:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitForProducersOfSubmission:error:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(waitUntilIdleWithError:)),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(submitWithError:)),
        class_getInstanceMethod(
            NV2AMetalTextureUpload.class,
            @selector(encodeData:offset:palette:paletteOffset:paletteLength:
                      shape:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
        class_getInstanceMethod(NV2AMetalSubmission.class,
                                @selector(completedWithError:))
    };
    IMP replacements[] = { (IMP)rtp_admit,  (IMP)rtp_begin,   (IMP)rtp_encoder,
                           (IMP)rtp_commit, (IMP)rtp_wait,    (IMP)rtp_producer,
                           (IMP)rtp_idle,   (IMP)rtp_submit,  (IMP)rtp_upload,
                           (IMP)rtp_emit,   (IMP)rtp_feedback };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    rtp_admit_original = (void *)originals[0];
    rtp_begin_original = (void *)originals[1];
    rtp_encoder_original = (void *)originals[2];
    rtp_commit_original = (void *)originals[3];
    rtp_wait_original = (void *)originals[4];
    rtp_producer_original = (void *)originals[5];
    rtp_idle_original = (void *)originals[6];
    rtp_full_original = (void *)originals[7];
    rtp_upload_original = (void *)originals[8];
    rtp_emit_original = (void *)originals[9];
    rtp_feedback_original = (void *)originals[10];
    rtp_rasters = [[NSMapTable alloc]
        initWithKeyOptions:NSPointerFunctionsWeakMemory |
                           NSPointerFunctionsObjectPointerPersonality
              valueOptions:NSPointerFunctionsStrongMemory
                  capacity:32];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned kind = 0; kind < 10; kind++) {
            @autoreleasepool {
                RasterTextureUploadWork work[2] = { 0 };
                NSData *old = rtp_run(kind, YES, &work[0]);
                NSData *actual = rtp_run(kind, NO, &work[1]);
                if (![old isEqualToData:actual])
                    fprintf(stderr,
                            "Raster texture upload byte mismatch kind%u\n",
                            kind);
                assert([old isEqualToData:actual]); /* Full GPU/Current/archive
                                                       bytes first. */
                if (kind < 5 || kind == 9) {
                    assert(work[0].full == 1 && work[0].raster == 1 &&
                           work[0].gate == 1);
                    assert(!work[1].full && !work[1].raster && !work[1].gate &&
                           !work[1].aSubmitted && work[1].pending &&
                           work[1].admissions &&
                           work[1].uploads == (kind < 4  ? kind + 1 :
                                               kind == 9 ? 2 :
                                                           1));
                } else if (kind == 6 || kind == 7) {
                    BOOL expected =
                        kind == 6 ?
                            work[0].full == 1 && work[0].raster == 1 &&
                                work[0].gate == 1 && work[0].aSubmitted &&
                                !work[0].pending && !work[1].full &&
                                !work[1].raster && !work[1].gate &&
                                !work[1].aSubmitted && work[1].pending &&
                                work[0].uploads == 2 && work[1].uploads == 2 &&
                                work[1].admissions :
                            work[0].full == 1 && work[1].full == 1 &&
                                work[0].raster == 1 && work[1].raster == 1 &&
                                work[0].gate == 1 && work[1].gate == 1 &&
                                !work[0].uploads && !work[1].uploads;
                    if (!expected)
                        for (unsigned i = 0; i < 2; i++)
                            fprintf(
                                stderr,
                                "Raster upload legacy kind%u reference%u "
                                "full%u raster%u gate%llu submitted%d "
                                "pending%d uploads%u admissions%u waits%u\n",
                                kind, !i, work[i].full, work[i].raster,
                                (unsigned long long)work[i].gate,
                                work[i].aSubmitted, work[i].pending,
                                work[i].uploads, work[i].admissions,
                                work[i].waits);
                    if (kind == 6) {
                        /* The completed palette's full-reservation proof now
                         * downloads it independently of the open raster.
                         * Stage0 still uploads before the Stage1 alias. */
                        assert(work[0].full == 1 && work[0].raster == 1 &&
                               work[0].gate == 1 && work[0].aSubmitted &&
                               !work[0].pending);
                        assert(!work[1].full && !work[1].raster &&
                               !work[1].gate && !work[1].aSubmitted &&
                               work[1].pending);
                        assert(work[0].uploads == 2 && work[1].uploads == 2 &&
                               work[1].admissions);
                    } else {
                        assert(work[0].full == 1 && work[1].full == 1 &&
                               work[0].raster == 1 && work[1].raster == 1 &&
                               work[0].gate == 1 && work[1].gate == 1);
                        assert(!work[0].uploads &&
                               !work[1].uploads); /* Real RTT. */
                    }
                } else if (kind == 8) {
                    assert(!work[0].uploads && !work[1].uploads &&
                           !work[0].raster && !work[1].raster && !work[1].gate);
                } else {
                    /* The required CPU-write repair already released A's
                     * gate. Retry and snapshot add no Full/raster submit. */
                    assert(kind == 5 && !work[1].full && !work[1].raster &&
                           work[1].gate == 1 && work[1].aSubmitted);
                }
            }
        }
    } @finally {
        if (rtp_gate)
            rtp_gate.signaledValue = 1;
        if (rtp_foreign_gate)
            rtp_foreign_gate.signaledValue = 1;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
        rtp_scope = rtp_reference = rtp_arm_a = rtp_fail_emit =
            rtp_known_error = NO;
        rtp_commands = rtp_foreign = nil;
        rtp_a = nil;
        rtp_queue = nil;
        rtp_gate = rtp_foreign_gate = nil;
        rtp_foreign_marker = nil;
        rtp_rasters = nil;
        rtp_failure = nil;
    }
    puts(
        "Raster texture upload PGRAPH:10 actual A-raster/cold-B pairs; "
        "1..4stages, "
        "GPUdecoded pixels before raster-commit gate, producer snapshot fence, "
        "short palette/fault/repair, mixed palette alias/RTT/known error, "
        "late retry/Restore/CPUlease; "
        "framebuffer/Zeta/query/Current/context/archive PASS");
    groups += 10;
}
#endif
