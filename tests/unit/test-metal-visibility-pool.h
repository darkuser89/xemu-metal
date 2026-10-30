/* Bounded visibility ranges, real GPU writes, frozen reports and pressure.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_VISIBILITY_POOL_H
#define TEST_METAL_VISIBILITY_POOL_H
static NV2AMetalCommands *vp_wait_commands;
static unsigned vp_waits;
static BOOL (*vp_original_wait)(id, SEL, NV2AMetalSubmission *, NSError **);
static BOOL vp_wait(id owner, SEL selector, NV2AMetalSubmission *submission,
                    NSError **error)
{
    if (owner == vp_wait_commands)
        vp_waits++;
    return vp_original_wait(owner, selector, submission, error);
}
static void vp_write(NV2AMetalPGRAPHReports *reports,
                     NV2AMetalVisibilityCounter *counter,
                     NV2AMetalPGRAPHQuery *query, uint64_t value)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    require([cache prepareGPUReadAtAddress:0 length:0 error:&error] &&
                [reports recordCounter:counter error:&error],
            error);
    assert(counter.buffer && !(counter.offset & 7) &&
           counter.offset + 8 <= counter.buffer.length);
    NV2AMetalCommands *commands = cache.commands;
    NSUInteger offset;
    id<MTLBuffer> source = [commands uploadBytes:&value
                                          length:8
                                          offset:&offset
                                           error:&error];
    require(source && [commands addResource:counter.buffer error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
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
    [reports commitCounter:counter query:query];
}
static void vp_get(NV2AMetalPGRAPHReports *reports, unsigned index)
{
    NSError *error = nil;
    require([reports getReport:1u << 24 | index * 16 error:&error], error);
}
static void vp_draw_pressure_tests(void)
{
    NSError *error = nil;
    for (unsigned mode = 0; mode < 3; mode++) {
        uint8_t pixels[256];
        uint32_t constants[192][4], count = 0;
        float current[16][4];
        for (unsigned small = 0; small < 2; small++) {
            fixture();
            PGRAPHState *pg = &state->pgraph;
            pg->zpass_pixel_count_enable = true;
            pg->dma_report = 80;
            dma[4].limit = 8191;
            if (mode) {
                pg->regs_[NV_PGRAPH_CSV0_D] =
                    2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                pg->enable_vertex_program_write = mode == 2;
                if (mode == 2)
                    feedback_program(191, 15);
                else {
                    mov(0, 0, 0, false);
                    mov(1, 3, 3, true);
                }
            }
            NV2AMetalPGRAPHReports *reports =
                [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                        cache:surfaces.cache
                                              counterCapacity:small ? 2 : 1024];
            assert(reports);
            [draw setValue:reports forKey:@"reports"];
            NV2AMetalCommands *commands = surfaces.cache.commands;
            vp_wait_commands = commands;
            vp_waits = 0;
            id<MTLSharedEvent> gate = [commands.device newSharedEvent];
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
            assert(gate && queue);
            [queue waitForEvent:gate value:1];
            for (unsigned i = 0; i < 3; i++) {
                if (small && i == 2)
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                          gate.signaledValue = 1;
                        });
                qemu_mutex_lock(&pg->lock);
                require([draw drawWithError:&error], error);
                assert(pg->draw_time == (int)i + 1);
                qemu_mutex_unlock(&pg->lock);
                if (i < 2 || !small)
                    assert(!vp_waits && !gate.signaledValue);
            }
            if (small)
                assert(vp_waits && gate.signaledValue == 1);
            else
                gate.signaledValue = 1;
            require([surfaces.cache submitWithError:&error] &&
                        [surfaces.cache waitUntilIdleWithError:&error],
                    error);
            uint32_t actual = batch_report();
            assert(actual);
            read_vram(1024, 256);
            if (!small) {
                memcpy(pixels, state->vram_ptr + 1024, sizeof(pixels));
                memcpy(constants, pg->vsh_constants, sizeof(constants));
                for (unsigned a = 0; a < 16; a++)
                    memcpy(current[a], pg->vertex_attributes[a].inline_value,
                           16);
                count = actual;
            } else {
                assert(
                    actual == count &&
                    !memcmp(pixels, state->vram_ptr + 1024, sizeof(pixels)) &&
                    !memcmp(constants, pg->vsh_constants, sizeof(constants)));
                for (unsigned a = 0; a < 16; a++)
                    assert(!memcmp(current[a],
                                   pg->vertex_attributes[a].inline_value, 16));
            }
        }
    }
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:surfaces.cache];
    assert(reports);
    [draw setValue:reports forKey:@"reports"];
    puts("Visibility draw pressure:three fixed/readonly/writable "
         "image/Current/context/query "
         "pairs;two gated draws return without waits,third drains the two-slot "
         "pool,"
         "reopens producers and preserves exact raster results PASS");
}
static void visibility_pool_tests(void)
{
    NSError *error = nil;
    Method wait = class_getInstanceMethod(NV2AMetalCommands.class,
                                          @selector(waitForSubmission:error:));
    vp_original_wait = (void *)method_setImplementation(wait, (IMP)vp_wait);
    for (unsigned scale = 1; scale <= 3; scale++) {
        fixture();
        PGRAPHState *pg = &state->pgraph;
        qemu_mutex_lock(&pg->lock);
        pg->surface_scale_factor = scale;
        pg->dma_report = 80;
        dma[4].limit = 8191;
        NV2AMetalSurfaceCache *cache = surfaces.cache;
        NV2AMetalPGRAPHReports *reports =
            [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                    cache:cache
                                          counterCapacity:2];
        assert(reports &&
               ![[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                        cache:cache
                                              counterCapacity:0] &&
               ![[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                        cache:cache
                                              counterCapacity:1025]);
        NV2AMetalVisibilityCounter *a =
            [reports allocateCounterWithError:&error];
        NV2AMetalVisibilityCounter *b =
            [reports allocateCounterWithError:&error];
        assert(a && b && a.buffer == b.buffer && a.buffer.length == 16 &&
               a.offset == 0 && b.offset == 8);
        assert(![reports allocateCounterWithError:&error] && error);
        assert(![reports recordCounter:a error:&error]); /* No recording. */
        [reports cancelCounter:a];
        [reports cancelCounter:b];
        NV2AMetalPGRAPHQuery *query = [reports beginQuery];
        id<MTLSharedEvent> gate = [cache.commands.device newSharedEvent];
        Ivar queueIvar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(cache.commands, queueIvar);
        assert(gate && queue);
        [queue waitForEvent:gate value:1];
        a = [reports allocateCounterWithError:&error];
        require(a != nil, error);
        id<MTLBuffer> pool = a.buffer;
        vp_write(reports, a, query, UINT64_MAX - 2);
        vp_get(reports, 0);
        b = [reports allocateCounterWithError:&error];
        require(b != nil, error);
        vp_write(reports, b, query, 5);
        vp_get(reports, 1);
        /* A pool drain must not consume an unrelated unsubmitted reader. */
        NV2AMetalCommands *other =
            [[NV2AMetalCommands alloc] initWithDevice:cache.commands.device
                                                error:&error];
        NV2AMetalIndependentReads *reader = nil;
        require(other && [cache tryBeginIndependentReads:NULL
                                                   count:0
                                                commands:other
                                                   reads:&reader
                                                   error:&error],
                error);
        assert(reader && other.commandBuffer && !gate.signaledValue);
        vp_wait_commands = cache.commands;
        vp_waits = 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         gate.signaledValue = 1;
                       });
        NV2AMetalVisibilityCounter *c =
            [reports allocateCounterWithError:&error];
        require(c != nil, error);
        assert(vp_waits && gate.signaledValue == 1 && other.commandBuffer &&
               c.buffer == pool && c.offset == a.offset && !a.buffer &&
               b.buffer == pool && !*(uint64_t *)pool.contents);
        [cache cancelIndependentReads:reader];
        vp_write(reports, c, query, 7);
        NSData *snapshot = [reports snapshotWithActiveQuery:query error:&error];
        require(snapshot != nil, error);
        vp_get(reports, 2);
        [reports endQuery:query];
        require([reports processWithError:&error], error);
        unsigned divisor = scale * scale;
        assert(report_values[0] == (UINT32_MAX - 2) / divisor &&
               report_values[1] == 2 / divisor &&
               report_values[2] == 9 / divisor);
        NV2AMetalPGRAPHReports *restored =
            [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                    cache:cache
                                          counterCapacity:2];
        NV2AMetalPGRAPHQuery *active = nil;
        require([restored restoreSnapshot:snapshot
                              activeQuery:&active
                                    error:&error],
                error);
        assert(active);
        vp_get(restored, 2);
        [restored endQuery:active];
        for (unsigned i = 0; i < 3; i++)
            report_seen[i] = false;
        require([restored processWithError:&error], error);
        assert(report_seen[0] && report_seen[1] && report_seen[2] &&
               report_values[0] == (UINT32_MAX - 2) / divisor &&
               report_values[1] == 2 / divisor &&
               report_values[2] == 9 / divisor);
        [reports clear];
        query = [reports beginQuery];
        uint32_t total = 0;
        for (unsigned i = 0; i < 130; i++) {
            NV2AMetalVisibilityCounter *counter =
                [reports allocateCounterWithError:&error];
            require(counter != nil, error);
            assert(counter.buffer == pool && counter.buffer.length == 16);
            unsigned value = i % 7 + 1;
            total += value;
            vp_write(reports, counter, query, value);
            assert([[query valueForKey:@"buffers"] count] <= 2);
            if (i % 17 == 16) {
                unsigned index = 4 + i / 17;
                vp_get(reports, index);
                report_seen[index] = false;
            }
        }
        uint32_t expected[7];
        uint32_t sum = 0;
        for (unsigned i = 0; i < 119; i++) {
            sum += i % 7 + 1;
            if (i % 17 == 16)
                expected[i / 17] = sum / divisor;
        }
        vp_get(reports, 12);
        [reports endQuery:query];
        require([reports processWithError:&error], error);
        for (unsigned i = 0; i < 7; i++)
            assert(report_seen[4 + i] && report_values[4 + i] == expected[i]);
        assert(report_values[12] == total / divisor);
        [reports clear];
        query = [reports beginQuery];
        a = [reports allocateCounterWithError:&error];
        require(a != nil, error);
        vp_write(reports, a, query, divisor - 1);
        [reports clear];
        b = [reports allocateCounterWithError:&error];
        require(b != nil, error);
        vp_write(reports, b, query, 1);
        vp_get(reports, 13);
        [reports endQuery:query];
        require([reports processWithError:&error], error);
        assert(report_values[13] == 1 / divisor);
        a = [reports allocateCounterWithError:&error];
        require(a != nil, error);
        require([cache prepareGPUReadAtAddress:0 length:0 error:&error] &&
                    [reports recordCounter:a error:&error],
                error);
        assert(![reports recordCounter:a error:&error] && error &&
               ![restored recordCounter:a error:&error]);
        [cache cancel];
        [reports cancelCounter:a];
        b = [reports allocateCounterWithError:&error];
        require(b != nil, error);
        [reports cancelCounter:b];
        [reports discard];
        [restored discard];
        qemu_mutex_unlock(&pg->lock);
    }
    vp_draw_pressure_tests();
    vp_wait_commands = nil;
    method_setImplementation(wait, (IMP)vp_original_wait);
    puts("Visibility pool:three two-slot GPU pressure/offset-reuse cases;"
         "unrelated reader stays open,frozen FIFO/native uint64/uint32 wrap,"
         "scale1/2/3,v3 snapshot continuation,390 long-query counters with "
         "bounded "
         "pending records,Clear,cancel,foreign/duplicate/missing recording and "
         "reservation exhaustion PASS");
    groups++;
}
#endif
