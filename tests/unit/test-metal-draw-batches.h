/* Cross-guest-draw native batches versus explicit per-draw commits.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DRAW_BATCHES_H
#define TEST_METAL_DRAW_BATCHES_H
static NSMutableArray<NSNumber *> *batch_commits;
static BOOL batch_fail_next;
static BOOL (*batch_original_submit)(id, SEL, NSError **);
static BOOL batch_submit(id owner, SEL selector, NSError **error)
{
    if (owner != surfaces.cache.commands)
        return batch_original_submit(owner, selector, error);
    if (batch_fail_next) {
        batch_fail_next = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.draw-batch"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    NSUInteger n = surfaces.cache.commands.sealedBufferCount +
                   (surfaces.cache.commands.commandBuffer != nil);
    BOOL ok = batch_original_submit(owner, selector, error);
    if (ok)
        [batch_commits addObject:@(n)];
    return ok;
}
static uint32_t batch_report(void)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw.reports getReport:1u << 24 error:&error], error);
    require([draw.reports processWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    return reported;
}
static void draw_batch_tests(void)
{
    NSError *error = nil;
    unsigned pairs = 0;
    for (unsigned active = 0; active < 2; active++)
        for (unsigned mode = 0; mode < 3; mode++) {
            uint8_t reference[256];
            uint32_t constants[192][4];
            float current[4];
            uint32_t query = 0;
            for (unsigned grouped = 0; grouped < 2; grouped++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                qemu_mutex_lock(&pg->lock);
                [draw.reports clear];
                qemu_mutex_unlock(&pg->lock);
                dma[2].limit = 8191;
                pg->dma_report = 64;
                pg->zpass_pixel_count_enable = true;
                if (mode) {
                    pg->regs_[NV_PGRAPH_CSV0_D] =
                        2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                    pg->enable_vertex_program_write = mode == 2;
                    if (mode == 2) {
                        feedback_program(191, 15);
                        pg->draw_arrays_length = 1;
                    } else {
                        mov(0, 0, 0, false);
                        mov(1, 3, 3, true);
                    }
                }
                Method submit = class_getInstanceMethod(
                    NV2AMetalCommands.class, @selector(submitWithError:));
                assert(submit);
                batch_commits = [NSMutableArray new];
                batch_original_submit =
                    (void *)method_setImplementation(submit, (IMP)batch_submit);
                for (unsigned i = 0; i < 74; i++) {
                    pg->vertex_attributes[3].inline_value[0] =
                        (i * 7 % 255) / 255.f;
                    pg->vertex_attributes[3].inline_value[1] =
                        (i * 13 % 255) / 255.f;
                    pg->vertex_attributes[3].inline_value[2] =
                        (i * 19 % 255) / 255.f;
                    pg->vertex_attributes[3].inline_value[3] = .5f;
                    pg->regs_[NV_PGRAPH_BLEND] =
                        (i % 3 == 0) ?
                            NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12 :
                        (i % 3 == 1) ?
                            NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8 :
                            0;
                    qemu_mutex_lock(&pg->lock);
                    if (active) {
                        uint64_t serial =
                            surfaces.cache.commands.recordingSerial;
                        NSUInteger sections =
                            surfaces.cache.commands.sealedBufferCount;
                        require([draw beginWithError:&error], error);
                        if (i) {
                            assert(surfaces.cache.commands.recordingSerial ==
                                       serial &&
                                   surfaces.cache.commands.sealedBufferCount ==
                                       sections);
                        }
                        require([draw endWithError:&error], error);
                    } else
                        require([draw drawWithError:&error], error);
                    assert(pg->draw_time == (int)i + 1);
                    if (mode == 2)
                        expect_context(191, 15, (i + 1) * 3, YES);
                    if (!grouped)
                        require([surfaces.cache submitWithError:&error], error);
                    qemu_mutex_unlock(&pg->lock);
                }
                qemu_mutex_lock(&pg->lock);
                require([surfaces.cache submitWithError:&error], error);
                qemu_mutex_unlock(&pg->lock);
                method_setImplementation(submit, (IMP)batch_original_submit);
                /* Cold Begin uploads once; the 73 warm Begins need no section. */
                unsigned sections = 74 * (mode == 1 ? 2u : 1u) + active;
                if (grouped) {
                    /* Allocator/resource pressure may submit before 32
                     * sections. Every grouping must still reduce commits. */
                    assert(batch_commits.count >= (sections + 31) / 32 &&
                           batch_commits.count < 74);
                    printf("Metal batch grouping: Begin/End=%u XF=%u "
                           "74 draws, %u sections, %zu commits\n",
                           active, mode, sections, (size_t)batch_commits.count);
                } else
                    assert(batch_commits.count == 74);
                unsigned total = 0;
                for (NSNumber *size in batch_commits) {
                    assert(size.unsignedIntegerValue &&
                           size.unsignedIntegerValue <= 32);
                    total += size.unsignedIntegerValue;
                }
                assert(total == sections);
                uint32_t count = batch_report();
                read_vram(1024, 256);
                assert(count > 0);
                if (!grouped) {
                    memcpy(reference, state->vram_ptr + 1024, 256);
                    memcpy(constants, pg->vsh_constants, sizeof(constants));
                    memcpy(current, pg->vertex_attributes[0].inline_value, 16);
                    query = count;
                } else {
                    assert(!memcmp(reference, state->vram_ptr + 1024, 256));
                    assert(!memcmp(constants, pg->vsh_constants,
                                   sizeof(constants)));
                    assert(!memcmp(current,
                                   pg->vertex_attributes[0].inline_value, 16));
                    assert(query == count);
                    pairs++;
                }
            }
        }
    /* A failed capacity/pressure-boundary commit keeps the accepted draws.
     * Retry consumes the new suffix once and preserves its prior XF progress.
     */
    for (unsigned mode = 0; mode < 3; mode++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        if (mode) {
            pg->regs_[NV_PGRAPH_CSV0_D] =
                2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
            pg->enable_vertex_program_write = mode == 2;
            if (mode == 2) {
                feedback_program(191, 15);
                pg->draw_arrays_length = 1;
            } else {
                mov(0, 0, 0, false);
                mov(1, 3, 3, true);
            }
        }
        Method submit = class_getInstanceMethod(NV2AMetalCommands.class,
                                                @selector(submitWithError:));
        batch_commits = [NSMutableArray new];
        batch_original_submit =
            (void *)method_setImplementation(submit, (IMP)batch_submit);
        batch_fail_next = YES;
        unsigned prefix = 0;
        qemu_mutex_lock(&pg->lock);
        for (; prefix < 32; prefix++) {
            error = nil;
            if (![draw drawWithError:&error])
                break;
        }
        assert(prefix && prefix < 32 && !batch_fail_next &&
               !batch_commits.count &&
               [error.domain isEqualToString:@"test.draw-batch"]);
        assert(pg->draw_time == (int)prefix &&
               surfaces.cache.commands.sealedBufferCount ==
                   prefix * (mode == 1 ? 2u : 1u) + (mode == 1) &&
               !surfaces.cache.commands.commandBuffer);
        if (mode == 2)
            expect_context(191, 15, (prefix + 1) * 3, YES);
        require([draw drawWithError:&error], error);
        assert(pg->draw_time == (int)prefix + 1 &&
               !surfaces.cache.commands.sealedBufferCount);
        if (mode == 2)
            expect_context(191, 15, (prefix + 1) * 3, YES);
        qemu_mutex_unlock(&pg->lock);
        method_setImplementation(submit, (IMP)batch_original_submit);
        assert(batch_commits.count == 1 &&
               batch_commits[0].unsignedIntegerValue ==
                   (prefix + 1) * (mode == 1 ? 2u : 1u));
        read_vram(1024, 256);
        color(1, 1, 0xff00ff00);
    }
    assert(pairs == 6);
    printf("Metal cross-draw batches: %u exact 74-draw color/Current/XF/query "
           "pairs, "
           "standalone and Begin/End fixed/readonly/writable; 74 raster "
           "commits reduced in every pair; "
           "accepted prefix survives failed boundary commit and retry PASS\n",
           pairs);
    batch_commits = nil;
    groups++;
}
#endif
