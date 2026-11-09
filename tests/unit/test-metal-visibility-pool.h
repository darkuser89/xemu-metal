/* Bounded visibility ranges, real GPU writes, frozen reports and pressure.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_VISIBILITY_POOL_H
#define TEST_METAL_VISIBILITY_POOL_H
static NV2AMetalCommands *vp_wait_commands;
static id<MTLSharedEvent> vp_release_on_wait;
static unsigned vp_waits;
static BOOL (*vp_original_wait)(id, SEL, NV2AMetalSubmission *, NSError **);
static BOOL vp_wait(id owner, SEL selector, NV2AMetalSubmission *submission,
                    NSError **error)
{
    if (owner == vp_wait_commands) {
        vp_waits++;
        if (vp_release_on_wait) {
            vp_release_on_wait.signaledValue = 1;
            vp_release_on_wait = nil;
        }
    }
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
static NV2AMetalCommands *vp_gated_producer(id<MTLDevice> device,
                                            id<MTLSharedEvent> gate)
{
    NSError *error = nil;
    NV2AMetalCommands *producer =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(producer != nil, error);
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(producer, queueIvar);
    assert(queue && gate);
    [queue waitForEvent:gate value:1];
    require([producer beginWithError:&error] != nil, error);
    id<MTLBuffer> buffer =
        [device newBufferWithLength:8 options:MTLResourceStorageModePrivate];
    require(buffer && [producer addResource:buffer error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [producer.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder fillBuffer:buffer range:NSMakeRange(0, 8) value:1];
    [encoder endEncoding];
    require([producer submitWithError:&error], error);
    return producer;
}
static void vp_oldest_recording_test(void)
{
    fixture();
    qemu_mutex_lock(&state->pgraph.lock);
    state->pgraph.dma_report = 80;
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *commands = cache.commands;
    const NSUInteger capacity = 64;
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state
                                                cache:cache
                                      counterCapacity:capacity];
    NV2AMetalVisibilityCounter *first = [reports allocateCounterWithError:&error];
    NSMutableArray<NV2AMetalVisibilityCounter *> *reservations =
        [NSMutableArray new];
    for (NSUInteger i = 1; i < capacity - 1; i++) {
        NV2AMetalVisibilityCounter *reserved =
            [reports allocateCounterWithError:&error];
        require(reserved != nil, error);
        [reservations addObject:reserved];
    }
    NV2AMetalVisibilityCounter *second = [reports allocateCounterWithError:&error];
    require(first && second, error);
    NV2AMetalPGRAPHQuery *query = [reports beginQuery];
    id<MTLSharedEvent> earlyGate = [commands.device newSharedEvent];
    id<MTLSharedEvent> laterGate = [commands.device newSharedEvent];
    NV2AMetalCommands *early = vp_gated_producer(commands.device, earlyGate);
    NV2AMetalCommands *later = vp_gated_producer(commands.device, laterGate);
    NV2AMetalCommands *producers[] = { early, later };
    NV2AMetalVisibilityCounter *counters[] = { second, first };
    for (unsigned i = 0; i < 2; i++) {
        NV2AMetalCommands *producer = producers[i];
        require([cache prepareGPUReadAtAddress:0 length:0 error:&error] &&
                    [commands orderAfterSubmission:producer.lastSubmitted
                                       fromCommands:producer
                                               error:&error],
                error);
        if (i == 1)
            for (NV2AMetalVisibilityCounter *reserved in reservations) {
                if (reserved == reservations.lastObject)
                    continue;
                require([reports recordCounter:reserved error:&error], error);
            }
        vp_write(reports, counters[i], query, i + 3);
        require([cache submitWithError:&error], error);
    }
    NV2AMetalSubmission *last = commands.lastSubmitted;
    assert(last && ![last completedWithError:&error] && !error);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!laterGate.signaledValue)
                         laterGate.signaledValue = 2;
                   });
    vp_wait_commands = commands;
    vp_release_on_wait = earlyGate;
    vp_waits = 0;
    SEL retireSelector = sel_registerName("retireCounterAtIndex:");
    Method retireMethod = class_getInstanceMethod(NV2AMetalPGRAPHReports.class,
                                                  retireSelector);
    assert(retireMethod);
    BOOL (*originalRetire)(id, SEL, NSUInteger) =
        (void *)method_getImplementation(retireMethod);
    __block NSUInteger retireChecks = 0;
    IMP retireSpy = imp_implementationWithBlock(
        ^BOOL(NV2AMetalPGRAPHReports *owner, NSUInteger index) {
            if (owner == reports)
                retireChecks++;
            return originalRetire(owner, retireSelector, index);
        });
    method_setImplementation(retireMethod, retireSpy);
    NV2AMetalVisibilityCounter *hole = reservations.lastObject;
    [reports cancelCounter:hole];
    NV2AMetalVisibilityCounter *replacement =
        [reports allocateCounterWithError:&error];
    require(replacement != nil, error);
    assert(replacement.offset == hole.offset && !retireChecks && !vp_waits &&
           !earlyGate.signaledValue && !laterGate.signaledValue &&
           commands.lastSubmitted == last);
    NV2AMetalVisibilityCounter *reuse = [reports allocateCounterWithError:&error];
    method_setImplementation(retireMethod, (IMP)originalRetire);
    assert(imp_removeBlock(retireSpy));
    require(reuse != nil, error);
    assert(retireChecks == 3 && vp_waits == 1 &&
           earlyGate.signaledValue == 1 &&
           !laterGate.signaledValue && ![last completedWithError:&error] &&
           !error && reuse.offset == second.offset && !second.buffer &&
           first.buffer == reuse.buffer);
    [reports cancelCounter:reuse];
    [reports cancelCounter:replacement];
    vp_wait_commands = nil;
    laterGate.signaledValue = 1;
    require([cache waitForSubmission:last error:&error], error);
    for (NV2AMetalVisibilityCounter *reserved in reservations)
        [reports cancelCounter:reserved];
    vp_get(reports, 0);
    [reports endQuery:query];
    require([reports processWithError:&error], error);
    assert(report_value(0) == 7);
    qemu_mutex_unlock(&state->pgraph.lock);
    puts("Visibility pool submission scope: reverse reservation order; oldest "
         "recording frees one slot while later GPU work stays gated PASS");
    puts("Visibility pool pressure lookup: three retirement checks for 64 "
         "slots sharing two recordings, including the oldest after its wait PASS");
    puts("Visibility pool free slot: a sparse vacancy bypasses all busy "
         "counter retirement checks and GPU waits PASS");
}
static void vp_report_prefix_test(BOOL snapshot)
{
    fixture();
    qemu_mutex_lock(&state->pgraph.lock);
    state->pgraph.dma_report = 80;
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *commands = cache.commands;
    NV2AMetalPGRAPHReports *reports =
        [[NV2AMetalPGRAPHReports alloc] initWithState:state cache:cache
                                     counterCapacity:2];
    NV2AMetalPGRAPHQuery *query = [reports beginQuery];
    id<MTLSharedEvent> gate = [commands.device newSharedEvent];
    Ivar queueIvar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(commands, queueIvar);
    assert(reports && query && queue && gate);
    [queue waitForEvent:gate value:1];
    NV2AMetalSurfaceRecording *latest = nil;
    NV2AMetalVisibilityCounter *counters[2] = { nil, nil };
    for (unsigned i = 0; i < 2; i++) {
        NV2AMetalVisibilityCounter *counter =
            [reports allocateCounterWithError:&error];
        counters[i] = counter;
        require(counter && [cache prepareGPUReadAtAddress:0 length:0 error:&error],
                error);
        latest = cache.recording;
        vp_write(reports, counter, query, i + 3);
        require([cache submitWithError:&error], error);
    }
    vp_get(reports, 0);
    vp_get(reports, 1);
    vp_get(reports, 2);
    [reports endQuery:query];
    vp_get(reports, 3);
    NSArray *queued = [reports valueForKey:@"reports"];
    assert(queued.count == 4);
    NSArray *firstQueries = [queued[0] valueForKey:@"queries"];
    assert(firstQueries.count == 1);
    for (unsigned i = 1; i < 4; i++)
        assert(![[queued[i] valueForKey:@"queries"] count]);
    require([cache prepareGPUReadAtAddress:0 length:0 error:&error], error);
    NV2AMetalSurfaceRecording *pending = cache.recording;

    SEL selector = @selector(waitForRecording:error:);
    Method method = class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                            selector);
    assert(method);
    BOOL (*original)(id, SEL, NV2AMetalSurfaceRecording *, NSError **) =
        (void *)method_getImplementation(method);
    __block unsigned waits = 0;
    __block unsigned receiptLookups = 0;
    __block NV2AMetalSurfaceRecording *selected = nil;
    IMP spy = imp_implementationWithBlock(
        ^BOOL(NV2AMetalSurfaceCache *owner, NV2AMetalSurfaceRecording *token,
              NSError **failure) {
            selected = token;
            waits++;
            gate.signaledValue = 1;
            return original(owner, selector, token, failure);
        });
    method_setImplementation(method, spy);
    SEL receiptSelector = @selector(waitForSubmission:error:);
    Method receiptMethod = class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                                   receiptSelector);
    assert(receiptMethod);
    BOOL (*originalReceipt)(id, SEL, NV2AMetalSubmission *, NSError **) =
        (void *)method_getImplementation(receiptMethod);
    IMP receiptSpy = imp_implementationWithBlock(
        ^BOOL(NV2AMetalSurfaceCache *owner, NV2AMetalSubmission *submission,
              NSError **failure) {
            if (owner == cache)
                receiptLookups++;
            return originalReceipt(owner, receiptSelector, submission, failure);
        });
    method_setImplementation(receiptMethod, receiptSpy);
    memset(report_bytes(0), 0xa5, 4 * 16);
    NSData *wire = nil;
    BOOL ok;
    if (snapshot) {
        wire = [reports snapshotWithActiveQuery:nil error:&error];
        ok = wire != nil;
    } else {
        ok = [reports processWithError:&error];
    }
    method_setImplementation(method, (IMP)original);
    method_setImplementation(receiptMethod, (IMP)originalReceipt);
    assert(imp_removeBlock(spy));
    assert(imp_removeBlock(receiptSpy));
    require(ok, error);
    assert(waits == 1 && !receiptLookups && selected == latest && latest.completed &&
           cache.recording == pending && !pending.submitted);
    assert(!counters[0].buffer && !counters[1].buffer &&
           ![[firstQueries[0] valueForKey:@"buffers"] count]);
    puts("Visibility recording lookup: direct submission prefix without a "
         "receipt scan PASS");
    if (snapshot) {
        const uint8_t expected[] = { 0, 0, 0, 0, 0, 0, 0, 7 };
        assert(!report_was_written(0) && wire.length >= 28 + sizeof(expected) &&
               !memcmp((const uint8_t *)wire.bytes + 28, expected,
                       sizeof(expected)));
        assert([wire isEqualToData:[reports snapshotWithActiveQuery:nil
                                                              error:&error]]);
        require([reports processWithError:&error], error);
        assert(cache.recording == pending && !pending.submitted);
    }
    for (unsigned i = 0; i < 4; i++)
        assert(report_was_written(i) && report_value(i) == 7);
    puts("Visibility empty reports: four FIFO writes use one counter prefix PASS");
    puts("Visibility report counters: first read releases completed slots "
         "and preserves the raw result PASS");
    [cache cancel];
    qemu_mutex_unlock(&state->pgraph.lock);
    puts(snapshot ? "Visibility report snapshot: exact counter bytes, one "
                    "producer wait, later open section preserved PASS" :
                    "Visibility report prefix: two gated submissions use one "
                    "recording wait and leave the later open section intact PASS");
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
        assert(![[query valueForKey:@"buffers"] count]);
        vp_get(reports, 2);
        [reports endQuery:query];
        require([reports processWithError:&error], error);
        unsigned divisor = scale * scale;
        assert(report_value(0) == (UINT32_MAX - 2) / divisor &&
               report_value(1) == 2 / divisor &&
               report_value(2) == 9 / divisor);
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
            memset(report_bytes(i), 0xa5, 16);
        require([restored processWithError:&error], error);
        assert(report_was_written(0) && report_was_written(1) && report_was_written(2) &&
               report_value(0) == (UINT32_MAX - 2) / divisor &&
               report_value(1) == 2 / divisor &&
               report_value(2) == 9 / divisor);
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
                memset(report_bytes(index), 0xa5, 16);
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
            assert(report_was_written(4 + i) && report_value(4 + i) == expected[i]);
        assert(report_value(12) == total / divisor);
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
        assert(report_value(13) == 1 / divisor);
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
    vp_oldest_recording_test();
    vp_report_prefix_test(NO);
    vp_report_prefix_test(YES);
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
