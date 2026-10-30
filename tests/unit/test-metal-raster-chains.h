/* Real Metal suspend/resume chains across independent guest draws.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RASTER_CHAINS_H
#define TEST_METAL_RASTER_CHAINS_H
static id chain_queue;
static NSMutableDictionary<NSValue *, NSNumber *> *chain_flags;
static unsigned chain_passes, chain_draws;
static BOOL chain_fail_emit;
static id<MTL4RenderCommandEncoder> (*chain_original_encoder)(
    id, SEL, MTL4RenderPassDescriptor *, MTL4RenderEncoderOptions);
static void (*chain_original_begin)(id, SEL, id<MTL4CommandAllocator>);
static void (*chain_original_commit)(id, SEL, const id<MTL4CommandBuffer> *,
                                     NSUInteger, MTL4CommitOptions *);
static BOOL (*chain_original_emit)(id, SEL, id<MTL4RenderCommandEncoder>,
                                   NV2AMetalCommands *, NSError **);
static void chain_begin(id owner, SEL selector,
                        id<MTL4CommandAllocator> allocator)
{
    /* A cancelled buffer may be deallocated or recycled before any commit.
     * Pointer identity is meaningful only for its current recording. */
    [chain_flags removeObjectForKey:[NSValue valueWithNonretainedObject:owner]];
    chain_original_begin(owner, selector, allocator);
}
static id<MTL4RenderCommandEncoder>
chain_encoder(id owner, SEL selector, MTL4RenderPassDescriptor *pass,
              MTL4RenderEncoderOptions options)
{
    id<MTL4RenderCommandEncoder> encoder =
        chain_original_encoder(owner, selector, pass, options);
    if (encoder && options)
        chain_flags[[NSValue valueWithNonretainedObject:owner]] = @(options);
    return encoder;
}
static void chain_commit(id owner, SEL selector,
                         const id<MTL4CommandBuffer> *buffers, NSUInteger count,
                         MTL4CommitOptions *options)
{
    if (owner == chain_queue) {
        BOOL raster =
            chain_flags[[NSValue valueWithNonretainedObject:buffers[0]]] != nil;
        for (NSUInteger i = 0; i < count; i++) {
            NSValue *key = [NSValue valueWithNonretainedObject:buffers[i]];
            NSNumber *flags = chain_flags[key];
            assert((flags != nil) ==
                   raster); /* No producer inside the chain. */
            if (raster) {
                unsigned expected = !i ? MTL4RenderEncoderOptionSuspending :
                                    i + 1 == count ?
                                         MTL4RenderEncoderOptionResuming :
                                         MTL4RenderEncoderOptionSuspending |
                                             MTL4RenderEncoderOptionResuming;
                assert(flags.unsignedIntegerValue == expected);
            }
            [chain_flags removeObjectForKey:key];
        }
        if (raster) {
            assert(count >= 2 && count <= NV2AMetalCommandBatchLimit + 1);
            chain_passes++;
            chain_draws += count - 1;
        }
    }
    chain_original_commit(owner, selector, buffers, count, options);
}
static BOOL chain_emit(id owner, SEL selector,
                       id<MTL4RenderCommandEncoder> encoder,
                       NV2AMetalCommands *commands, NSError **error)
{
    BOOL ok = chain_original_emit(owner, selector, encoder, commands, error);
    if (ok && chain_fail_emit) {
        chain_fail_emit = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.raster-chain"
                                         code:1
                                     userInfo:nil];
        return NO; /* The cancelled section already contains a raster draw. */
    }
    return ok;
}
static void raster_chain_tests(void)
{
    NSError *error = nil;
    id<MTL4CommandBuffer> probe =
        [surfaces.cache.commands.device newCommandBuffer];
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    Method encoder = class_getInstanceMethod(
        [probe class], @selector(renderCommandEncoderWithDescriptor:options:));
    Method begin = class_getInstanceMethod(
        [probe class], @selector(beginCommandBufferWithAllocator:));
    Method commit = class_getInstanceMethod(
        [object_getIvar(surfaces.cache.commands, queueIvar) class],
        @selector(commit:count:options:));
    Method emit = class_getInstanceMethod(
        NV2AMetalPixelDraw.class,
        @selector(encodeWithRenderEncoder:commands:error:));
    assert(encoder && begin && commit && emit && queueIvar);
    chain_flags = [NSMutableDictionary new];
    chain_original_encoder =
        (void *)method_setImplementation(encoder, (IMP)chain_encoder);
    chain_original_begin =
        (void *)method_setImplementation(begin, (IMP)chain_begin);
    chain_original_commit =
        (void *)method_setImplementation(commit, (IMP)chain_commit);
    chain_original_emit =
        (void *)method_setImplementation(emit, (IMP)chain_emit);
    unsigned pairs = 0, separate = 0, merged = 0;
    for (unsigned boundaries = 0; boundaries < 2; boundaries++)
        for (unsigned active = 0; active < 2; active++)
            for (unsigned mode = 0; mode < 6; mode++) {
                uint8_t reference[256];
                uint32_t constants[192][4], referenceQuery = 0;
                float current[16][4];
                for (unsigned grouped = 0; grouped < 2; grouped++) {
                    fixture();
                    PGRAPHState *pg = &state->pgraph;
                    qemu_mutex_lock(&pg->lock);
                    [draw.reports clear];
                    qemu_mutex_unlock(&pg->lock);
                    chain_queue =
                        object_getIvar(surfaces.cache.commands, queueIvar);
                    chain_passes = chain_draws = 0;
                    [chain_flags removeAllObjects];
                    pg->zpass_pixel_count_enable = false;
                    dma[4].limit = 8191;
                    pg->dma_report = 80;
                    if (mode) {
                        pg->regs_[NV_PGRAPH_CSV0_D] =
                            2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                        pg->enable_vertex_program_write = mode == 2;
                        if (mode == 2)
                            feedback_program(191, 15);
                        else if (mode >= 3)
                            queued_xf_bounded_program(pg, mode == 3 ? 2 : mode);
                        else {
                            mov(0, 0, 0, false);
                            mov(1, 3, 3, true);
                        }
                    }
                    for (unsigned i = 0; i < 70; i++) {
                        if (boundaries && i == 20) {
                            require(
                                [surfaces.cache
                                    prepareGPUReadAtAddress:1024
                                                     length:256
                                                      error:&error] &&
                                    [surfaces.cache checkpointWithError:&error],
                                error);
                        }
                        if (boundaries && i == 35) {
                            cpu_write(1024, 4);
                            uint32_t color = 0xff123456;
                            memcpy(state->vram_ptr + 1024, &color, 4);
                        }
                        if (boundaries && i == 26) {
                            pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0xff234567;
                            pg->regs_[NV_PGRAPH_CLEARRECTX] =
                                pg->regs_[NV_PGRAPH_CLEARRECTY] = 7u << 16 | 7;
                            qemu_mutex_lock(&pg->lock);
                            require([draw clearSurface:NV097_CLEAR_SURFACE_COLOR
                                                 error:&error],
                                    error);
                            qemu_mutex_unlock(&pg->lock);
                        }
                        if (boundaries && i == 44) {
                            dma[3].address = 1024;
                            texture_registers(
                                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
                                32);
                        } else if (boundaries && i == 45) {
                            dma[3].address = 32768;
                            pg->regs_[NV_PGRAPH_TEXCTL0_0] = 0;
                            pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
                            pg->regs_[NV_PGRAPH_COMBINESPECFOG0] =
                                PS_REGISTER_V0;
                            pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
                                (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
                            pg->texture_dirty[0] = true;
                        }
                        if (boundaries && i == 58) {
                            qemu_mutex_lock(&pg->lock);
                            NSData *snapshot =
                                [draw pendingSnapshotWithError:&error];
                            require(snapshot != nil, error);
                            qemu_mutex_unlock(&pg->lock);
                        }
                        pg->zpass_pixel_count_enable =
                            !boundaries || (i >= 50 && i < 53);
                        for (unsigned k = 0; k < 3; k++)
                            pg->vertex_attributes[3].inline_value[k] =
                                ((i * (7 + k * 6)) % 255) / 255.f;
                        pg->vertex_attributes[3].inline_value[3] = .5f;
                        pg->regs_[NV_PGRAPH_BLEND] =
                            i % 2 ? NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12 :
                                    NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
                        qemu_mutex_lock(&pg->lock);
                        if (active)
                            require([draw beginWithError:&error], error);
                        if (grouped && i == 17) {
                            chain_fail_emit = YES;
                            assert(!(active ? [draw flushDrawWithError:&error] :
                                              [draw drawWithError:&error]) &&
                                   error);
                            assert(
                                !chain_fail_emit && pg->draw_time == (int)i &&
                                surfaces.cache.commands.hasPendingRasterPass);
                            error = nil;
                        }
                        require(active ? [draw endWithError:&error] :
                                         [draw drawWithError:&error],
                                error);
                        assert(pg->draw_time == (int)i + 1);
                        if (!grouped)
                            require([surfaces.cache submitWithError:&error],
                                    error);
                        qemu_mutex_unlock(&pg->lock);
                    }
                    require([surfaces.cache submitWithError:&error] &&
                                [surfaces.cache waitUntilIdleWithError:&error],
                            error);
                    unsigned query = batch_report();
                    assert(query > 0);
                    read_vram(1024, 256);
                    assert(chain_draws == 70);
                    if (!grouped) {
                        assert(chain_passes == chain_draws);
                        separate += chain_passes;
                        memcpy(reference, state->vram_ptr + 1024, 256);
                        memcpy(constants, pg->vsh_constants, sizeof(constants));
                        for (unsigned k = 0; k < 16; k++)
                            memcpy(current[k],
                                   pg->vertex_attributes[k].inline_value, 16);
                        referenceQuery = query;
                    } else {
                        assert(chain_passes < 16 && chain_passes < chain_draws);
                        merged += chain_passes;
                        if (memcmp(reference, state->vram_ptr + 1024, 256) ||
                            memcmp(constants, pg->vsh_constants,
                                   sizeof(constants)) ||
                            query != referenceQuery) {
                            fprintf(
                                stderr,
                                "Raster chain mismatch:boundaries%u active%u "
                                "mode%u "
                                "passes%u color%d context%d query%u/%u\n",
                                boundaries, active, mode, chain_passes,
                                memcmp(reference, state->vram_ptr + 1024, 256),
                                memcmp(constants, pg->vsh_constants,
                                       sizeof(constants)),
                                query, referenceQuery);
                            for (unsigned pixel = 0; pixel < 64; pixel++)
                                if (memcmp(reference + pixel * 4,
                                           state->vram_ptr + 1024 + pixel * 4,
                                           4)) {
                                    uint32_t before, after;
                                    memcpy(&before, reference + pixel * 4, 4);
                                    memcpy(&after,
                                           state->vram_ptr + 1024 + pixel * 4,
                                           4);
                                    fprintf(stderr,
                                            "First pixel%u:0x%08x/0x%08x\n",
                                            pixel, before, after);
                                    break;
                                }
                        }
                        assert(
                            !memcmp(reference, state->vram_ptr + 1024, 256) &&
                            !memcmp(constants, pg->vsh_constants,
                                    sizeof(constants)) &&
                            query == referenceQuery);
                        for (unsigned k = 0; k < 16; k++)
                            assert(!memcmp(
                                current[k],
                                pg->vertex_attributes[k].inline_value, 16));
                        pairs++;
                    }
                }
            }
    method_setImplementation(encoder, (IMP)chain_original_encoder);
    method_setImplementation(begin, (IMP)chain_original_begin);
    method_setImplementation(commit, (IMP)chain_original_commit);
    method_setImplementation(emit, (IMP)chain_original_emit);
    chain_queue = nil;
    chain_flags = nil;
    printf("Metal native raster chains:%u exact 70-draw "
           "image/Current/context/query pairs;"
           "%u separate versus %u merged suspend-resume chains;"
           "Fixed/readonly/writable/bounded/zero-product-ARL,standalone/"
           "Begin-End,partial raster "
           "cancellation/retry,"
           "all-query/mixed-query,download/CPU-upload/clear/RTT/snapshot/query "
           "boundaries and "
           "contiguous commit flags "
           "PASS\n",
           pairs, separate, merged);
    groups++;
}
#endif
