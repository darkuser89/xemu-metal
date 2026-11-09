/* GPU-ordered RAM writes keep exact cancellation and feedback boundaries.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_GPU_WRITE_DEPENDENCIES_H
#define TEST_METAL_GPU_WRITE_DEPENDENCIES_H
static id<MTLBuffer> gpu_dep_copy(NV2AMetalCommands *commands,
                                  id<MTLBuffer> input, NSUInteger address,
                                  id<MTLBuffer> output, NSUInteger destination)
{
    NSError *error = nil;
    if (!output) {
        output =
            [commands.device newBufferWithLength:8
                                         options:MTLResourceStorageModeShared];
        assert(output);
        memset(output.contents, 0, 8);
    }
    require([commands addResource:input error:&error] &&
                [commands addResource:output error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:input
               sourceOffset:address
                   toBuffer:output
          destinationOffset:destination
                       size:8];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return output;
}
static void gpu_dep_write(NV2AMetalSurfaceCache *cache, NSUInteger address,
                          uint64_t word)
{
    NSError *error = nil;
    require([cache prepareGPUWriteAtAddress:address length:8 error:&error],
            error);
    id<MTLBuffer> input =
        [cache.commands.device newBufferWithBytes:&word
                                           length:8
                                          options:MTLResourceStorageModeShared];
    assert(input);
    gpu_dep_copy(cache.commands, input, 0, cache.vram, address);
}
static NV2AMetalIndependentReads *gpu_dep_read(NV2AMetalSurfaceCache *cache,
                                               IndependentReadCommands *source,
                                               NSUInteger address,
                                               id<MTLBuffer> *bytes)
{
    NSError *error = nil;
    NV2AMetalVRAMReadSpan span = { address, 8 };
    NV2AMetalIndependentReads *reads = nil;
    require([cache tryBeginIndependentReads:&span
                                      count:1
                                   commands:source
                                      reads:&reads
                                      error:&error] &&
                reads,
            error);
    *bytes = gpu_dep_copy(source, cache.vram, address, nil, 0);
    require([cache submitIndependentReads:reads error:&error], error);
    return reads;
}
static void gpu_dep_gate(IndependentReadCommands *source)
{
    source.gate = [source.device newSharedEvent];
    source.manualGate = YES;
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(source, ivar);
    assert(queue && source.gate);
    [queue waitForEvent:source.gate value:1];
    id<MTLSharedEvent> gate = source.gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!gate.signaledValue)
                         gate.signaledValue = 2;
                   });
}
static uint64_t gpu_dep_word(id<MTLBuffer> buffer, NSUInteger address)
{
    uint64_t word;
    memcpy(&word, (const uint8_t *)buffer.contents + address, sizeof(word));
    return word;
}

static void pending_writer_bounds_test(NV2AMetalSurfaceCache *cache,
                                       NSUInteger address, NSUInteger distant)
{
    NSData *writes = [cache valueForKey:@"pendingWrites"];
    SEL selector = @selector(bytes);
    Method getter = class_getInstanceMethod(object_getClass(writes), selector);
    assert(getter);
    const void *(*original)(id, SEL) = (void *)method_getImplementation(getter);
    __block unsigned scans = 0;
    IMP spy = imp_implementationWithBlock(^const void *(id data) {
        scans += data == writes;
        return original(data, selector);
    });
    method_setImplementation(getter, spy);
    NSUInteger addresses[] = { address - 4, distant + 8, address + 2048,
                               address, distant };
    for (NSUInteger i = 0; i < sizeof(addresses) / sizeof(*addresses); i++) {
        NSError *error = nil;
        BOOL cpu = NO, gpu = NO;
        NV2AMetalVRAMReadPattern pattern = { addresses[i], 4, 0, 0 };
        unsigned before = scans;
        require([cache tryIdleCPUAccessAtAddress:pattern.address length:4
                                          write:NO completed:&cpu error:&error] &&
                    [cache tryIdleGPUReadPatterns:&pattern count:1
                                         completed:&gpu error:&error], error);
        assert(cpu == (i < 3) && gpu == cpu &&
               scans - before == (i < 2 ? 0 : 2));
    }
    method_setImplementation(getter, (IMP)original);
    assert(imp_removeBlock(spy));
}

static void cpu_submission_scope_tests(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 3; mode++) {
        @autoreleasepool {
            NSError *error = nil;
            BOOL download = mode != 0;
            IndependentReadCommands *commands =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                           error:&error];
            IndependentReadCommands *early =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                           error:&error];
            IndependentReadCommands *late =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                           error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(commands && early && late && ram, error);
            memset(ram.contents, 0x33, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            id<MTLBuffer> scratch = nil;
            gpu_dep_gate(early);
            NV2AMetalIndependentReads *first =
                gpu_dep_read(cache, early, 16384, &scratch);
            const NSUInteger address = 32764;
            NV2AMetalCachedSurface *downloadSurface = nil;
            if (download) {
                NV2AMetalSurfaceConfig cfg =
                    config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                           YES, 4, 1, NO);
                NV2AMetalCachedSurface *s =
                    [cache prepareSurfaceAtAddress:address
                                            config:&cfg
                                             frame:0
                                             error:&error];
                require(s != nil, error);
                downloadSurface = s;
                clear_surface(cache, s, MTLClearColorMake(0, 1, 0, 1), 0, 0);
                require([cache prepareGPUReadAtAddress:address
                                                length:4
                                                 error:&error],
                        error);
            } else {
                gpu_dep_write(cache, address, UINT64_C(0x4455667744556677));
            }
            const NSUInteger distant = address + 4096;
            gpu_dep_write(cache, distant, UINT64_C(0x1122334411223344));
            pending_writer_bounds_test(cache, address, distant);
            require([commands orderAfterSubmission:early.lastSubmitted
                                      fromCommands:early
                                              error:&error],
                    error);
            NV2AMetalSurfaceRecording *writer = cache.recording;
            require([cache checkpointWithError:&error], error);
            const NSUInteger cancelledAddress = distant + 4096;
            gpu_dep_write(cache, cancelledAddress, UINT64_MAX);
            NV2AMetalSurfaceRecording *cancelled = cache.recording;
            NSRange openBounds =
                [[cache valueForKey:@"pendingWriteBounds"] rangeValue];
            assert(openBounds.location == address &&
                   NSMaxRange(openBounds) == cancelledAddress + 8);
            [cache cancel];
            assert(cancelled.cancelled && !writer.cancelled && !writer.submitted);
            pending_writer_bounds_test(cache, address, distant);
            require([cache submitWithError:&error], error);
            assert(![[cache valueForKey:@"pendingWriteBounds"] rangeValue].length);

            gpu_dep_gate(late);
            NV2AMetalIndependentReads *second =
                gpu_dep_read(cache, late, 24576, &scratch);
            const NSUInteger source = 49152;
            require([cache prepareGPUReadAtAddress:source length:8 error:&error] &&
                        [commands orderAfterSubmission:late.lastSubmitted
                                           fromCommands:late
                                                   error:&error],
                    error);
            id<MTLBuffer> copy = gpu_dep_copy(commands, ram, source, nil, 0);
            NV2AMetalSurfaceRecording *reader = cache.recording;
            require([cache submitWithError:&error], error);
            NV2AMetalSubmission *tail = commands.lastSubmitted;
            const NSUInteger pendingSource = 57344;
            id<MTLBuffer> pendingCopy =
                encode_vram_copy(cache, pendingSource, 4);
            NV2AMetalSurfaceRecording *pending = cache.recording;
            __weak NSObject *pendingLifetime;
            @autoreleasepool {
                NSObject *lifetime = [NSObject new];
                pendingLifetime = lifetime;
                require([commands keepAlive:lifetime error:&error], error);
                lifetime = nil;
            }
            assert(pendingLifetime &&
                   [[pending valueForKey:@"readerPages"] count]);
            id<MTL4CommandBuffer> pendingBuffer = commands.commandBuffer;
            assert(writer.submitted && reader.submitted && !writer.completed &&
                   !reader.completed);
            NSArray *submissions = [cache valueForKey:@"submissions"];
            NSRange bounds =
                [[submissions[0] valueForKey:@"writeBounds"] rangeValue];
            assert(bounds.location == address && NSMaxRange(bounds) == distant + 8);
            id readOnly = submissions.lastObject;
            SEL downloadsSelector = sel_registerName("downloads");
            Method downloads = class_getInstanceMethod([readOnly class],
                                                        downloadsSelector);
            assert(submissions.count == 2 && downloads);
            NSUInteger (*originalDownloads)(id, SEL) =
                (void *)method_getImplementation(downloads);
            __block unsigned readOnlyVisits = 0;
            IMP downloadsSpy = imp_implementationWithBlock(^NSUInteger(id entry) {
                readOnlyVisits += entry == readOnly;
                return originalDownloads(entry, downloadsSelector);
            });
            method_setImplementation(downloads, downloadsSpy);
            commands.gate = early.gate;
            SEL selector = @selector(waitForSubmission:error:);
            Method lookup = class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                                     selector);
            assert(lookup);
            BOOL (*original)(id, SEL, NV2AMetalSubmission *, NSError **) =
                (void *)method_getImplementation(lookup);
            __block unsigned receiptLookups = 0;
            IMP spy = imp_implementationWithBlock(
                ^BOOL(id owner, NV2AMetalSubmission *submission,
                      NSError **failure) {
                    receiptLookups += owner == cache;
                    return original(owner, selector, submission, failure);
                });
            method_setImplementation(lookup, spy);
            const NSUInteger idleAddresses[] = {
                address - 4, address + 2048, address, distant,
            };
            for (NSUInteger i = 0; i < sizeof(idleAddresses) /
                                         sizeof(idleAddresses[0]); i++) {
                BOOL idle = NO;
                require([cache tryIdleCPUAccessAtAddress:idleAddresses[i]
                                                  length:4 write:NO
                                               completed:&idle error:&error],
                        error);
                assert(idle == (i < 2));
            }
            NV2AMetalVRAMReadSpan batch[18];
            for (NSUInteger i = 0; i < 18; i++)
                batch[i] = (NV2AMetalVRAMReadSpan){ address + 2048, 4 };
            BOOL idleBatch = NO;
            require([cache tryIdleCPUReadSpans:batch count:18
                                      completed:&idleBatch error:&error], error);
            assert(idleBatch);
            batch[16].address = address;
            batch[17].address = ram.length;
            require([cache tryIdleCPUReadSpans:batch count:18
                                      completed:&idleBatch error:&error], error);
            assert(!idleBatch && !error);
            batch[16].address = address + 2048;
            assert(![cache tryIdleCPUReadSpans:batch count:18
                                       completed:&idleBatch error:&error] &&
                   !idleBatch && error);
            error = nil;
            require([cache resolveCPUAccessAtAddress:address - 4 length:4
                                               write:NO error:&error] &&
                        [cache resolveCPUAccessAtAddress:address + 2048 length:4
                                                    write:NO error:&error],
                    error);
            assert(!commands.waits && !early.gate.signaledValue && !writer.completed);
            NV2AMetalCommands *probe =
                [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
            require(probe != nil, error);
            const NV2AMetalVRAMReadPattern probes[] = {
                { address - 8, 8, 0, 0 },
                { address + 2048, 4, 0, 0 },
                { distant - 8, 20, 16, 4 },
                { address, 4, 0, 0 },
                { distant, 8, 0, 0 },
            };
            for (NSUInteger i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
                NV2AMetalIndependentReads *reads = nil;
                require([cache tryBeginIndependentReadPatterns:&probes[i]
                                                        count:1
                                                     commands:probe
                                                        reads:&reads
                                                        error:&error],
                        error);
                assert((reads != nil) == (i < 3) &&
                       (probe.commandBuffer != nil) == (i < 3));
                if (reads)
                    [cache cancelIndependentReads:reads];
            }
            assert(!commands.waits && !early.gate.signaledValue && !writer.completed);
            if (mode == 2) {
                require([cache downloadSurfacesForCPU:@[downloadSurface]
                                                error:&error], error);
            } else {
                require([cache resolveCPUAccessAtAddress:address length:4
                                                   write:NO error:&error], error);
            }
            assert(writer.completed && commands.waits == 1 &&
                   !commands.idleWaits && !reader.completed &&
                   !late.gate.signaledValue &&
                   cache.recording == pending && !pending.submitted &&
                   commands.lastSubmitted == tail &&
                   commands.commandBuffer == pendingBuffer &&
                   gpu_dep_word(ram, distant) == UINT64_C(0x1122334411223344) &&
                   (uint32_t)gpu_dep_word(ram, address) ==
                       (download ? 0xff00ff00 : 0x44556677));
            require([cache resolveCPUAccessAtAddress:source length:8 write:NO
                                               error:&error],
                    error);
            method_setImplementation(downloads, (IMP)originalDownloads);
            assert(imp_removeBlock(downloadsSpy));
            assert(commands.waits == 1 && !late.gate.signaledValue &&
                   !readOnlyVisits);
            BOOL idle = YES;
            require([cache tryIdleCPUAccessAtAddress:source length:8 write:YES
                                           completed:&idle error:&error], error);
            assert(!idle && commands.waits == 1 && !late.gate.signaledValue);
            commands.gate = late.gate;
            require([cache resolveCPUAccessAtAddress:source length:8 write:YES
                                               error:&error],
                    error);
            assert(reader.completed && commands.waits == 2 &&
                   !commands.idleWaits && cache.recording == pending &&
                   !pending.submitted && commands.lastSubmitted == tail &&
                   gpu_dep_word(copy, 0) == UINT64_C(0x3333333333333333) &&
                   !receiptLookups);
            method_setImplementation(lookup, (IMP)original);
            assert(imp_removeBlock(spy));
            /* Keep the last submission pending until its own wait. */
            gpu_dep_gate(commands);
            require([cache resolveCPUAccessAtAddress:pendingSource
                                              length:4
                                               write:YES
                                               error:&error],
                    error);
            /* Targeted CPU resolution completes the producer and retires
             * its exact VRAM hazards. The sealed token/allocator generation
             * still belongs to the open batch until explicit Fullsubmit. */
            assert(!pending.completed && pending.producersCompleted &&
                   pending.cpuHazardsRetired && !pending.submitted &&
                   !pending.cancelled && commands.waits == 3 &&
                   !commands.idleWaits && !cache.recording &&
                   !commands.commandBuffer && commands.sealedBufferCount == 1 &&
                   commands.lastSubmitted != tail && pendingLifetime &&
                   ![[pending valueForKey:@"readerPages"] count] &&
                   *(uint32_t *)pendingCopy.contents == 0x33333333);
            const uint32_t cpuValue = 0x7c7c7c7c;
            memcpy((uint8_t *)ram.contents + pendingSource, &cpuValue, 4);
            require([cache submitWithError:&error] &&
                        [cache waitForRecording:pending error:&error],
                    error);
            assert(pending.completed && pending.submitted &&
                   pending.cpuHazardsRetired && !pending.cancelled &&
                   !commands.sealedBufferCount && pendingLifetime &&
                   ![[pending valueForKey:@"readerPages"] count] &&
                   *(uint32_t *)pendingCopy.contents == 0x33333333 &&
                   *(uint32_t *)((uint8_t *)ram.contents + pendingSource) ==
                       cpuValue);
            /* Full feedback makes the slot reusable; this explicit final
             * drain additionally releases its retained host objects. */
            require([cache waitUntilIdleWithError:&error], error);
            assert(!pendingLifetime);
            require([cache completeIndependentReads:first error:&error] &&
                        [cache completeIndependentReads:second error:&error],
                    error);
        }
    }
    puts("CPU VRAM submission scope: raw writes and downloads wait through "
         "their owning submission; disjoint open recording stays intact; "
         "overlapping producer-only Head retires hazards while token/resources "
         "remain owned until explicit Fullsubmit/final drain PASS");
    puts("CPU VRAM submission entry: raw conflicts and explicit downloads "
         "use the matched entry without a second receipt lookup PASS");
    puts("CPU VRAM writer candidates: raw writes and downloads skip later "
         "read-only submissions; CPU writes still wait for readers PASS");
    puts("CPU VRAM writer bounds: adjacent and in-bounds gap reads skip waits; "
         "real raw writes and downloads still publish exact bytes PASS");
    puts("GPU VRAM writer bounds: adjacent ranges and strided gaps admit "
         "independent readers; real writes and downloads reject them PASS");
    puts("CPU VRAM idle bounds: gaps stay idle, pending writes/downloads "
         "and overlapping submitted readers decline without waiting PASS");
    puts("CPU VRAM read batches: 18 spans cross the stack chunk boundary; "
         "an earlier conflict takes precedence over an invalid range PASS");
    puts("Pending VRAM writer bounds: CPU/GPU skip disjoint span scans, "
         "test gaps and real writes/downloads, and restore sealed bounds "
         "on cancellation PASS");
}

static void gpu_dependency_batch_scope_tests(id<MTLDevice> device)
{
    for (unsigned shared = 0; shared < 2; shared++) {
        NSError *error = nil;
        NV2AMetalCommands *target =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        require(target && source && ram, error);
        memset(ram.contents, 0x33, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        gpu_dep_gate(source);
        const NSUInteger address = 32764;
        id<MTLBuffer> old = nil;
        NV2AMetalIndependentReads *reads =
            gpu_dep_read(cache, source, address, &old);
        NSUInteger prefixAddress = shared ? address : 16384;
        gpu_dep_write(cache, prefixAddress, UINT64_C(0x4545454545454545));
        NV2AMetalSurfaceRecording *prefix = cache.recording;
        require([cache checkpointWithError:&error], error);
        gpu_dep_write(cache, address, UINT64_C(0x6767676767676767));
        NV2AMetalSurfaceRecording *tail = cache.recording;
        assert(prefix.submitted == !shared && !tail.submitted &&
               !source.gate.signaledValue);
        if (!shared) {
            require([cache waitForSubmission:target.lastSubmitted error:&error],
                    error);
            assert(prefix.completed && cache.recording == tail &&
                   !source.gate.signaledValue &&
                   gpu_dep_word(ram, prefixAddress) ==
                       UINT64_C(0x4545454545454545));
        }
        require([cache submitWithError:&error], error);
        source.gate.signaledValue = 1;
        require([cache waitForSubmission:target.lastSubmitted error:&error] &&
                    [cache completeIndependentReads:reads error:&error],
                error);
        assert(prefix.completed && tail.completed &&
               gpu_dep_word(old, 0) == UINT64_C(0x3333333333333333) &&
               gpu_dep_word(ram, address) == UINT64_C(0x6767676767676767));
    }
    puts("GPU dependency batch scope: new gated reader leaves accepted "
         "prefix independent; existing dependency keeps both sections batched PASS");
}

static void gpu_download_batch_scope_test(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *target =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    IndependentReadCommands *source =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(target && source && ram, error);
    memset(ram.contents, 0x33, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    const NSUInteger firstAddress = 4096, secondAddress = 16384;
    NV2AMetalSurfaceConfig cfg =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *first =
        [cache prepareSurfaceAtAddress:firstAddress config:&cfg frame:0
                                  error:&error];
    NV2AMetalCachedSurface *second =
        [cache prepareSurfaceAtAddress:secondAddress config:&cfg frame:0
                                  error:&error];
    require(first && second && [cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    gpu_dep_gate(source);
    id<MTLBuffer> old = nil;
    NV2AMetalIndependentReads *reader =
        gpu_dep_read(cache, source, secondAddress, &old);
    require([cache prepareSelectedSurface:first discardingContents:YES
                                     error:&error] &&
                [cache prepareSelectedSurface:second discardingContents:YES
                                         error:&error],
            error);
    clear_surface(cache, first, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    clear_surface(cache, second, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    NV2AMetalSurfaceRecording *prefix = cache.recording;
    require([cache checkpointWithError:&error], error);
    require([cache prepareGPUReadAtAddress:firstAddress
                                     length:secondAddress - firstAddress + 8
                                      error:&error],
            error);
    NV2AMetalSurfaceRecording *downloads = cache.recording;
    assert(prefix.submitted && !downloads.submitted &&
           !source.gate.signaledValue);
    require([cache waitForSubmission:target.lastSubmitted error:&error], error);
    assert(prefix.completed && cache.recording == downloads &&
           !source.gate.signaledValue &&
           gpu_dep_word(ram, firstAddress) == UINT64_C(0x3333333333333333) &&
           gpu_dep_word(ram, secondAddress) == UINT64_C(0x3333333333333333));
    require([cache submitWithError:&error], error);
    source.gate.signaledValue = 1;
    require([cache waitForSubmission:target.lastSubmitted error:&error] &&
                [cache completeIndependentReads:reader error:&error],
            error);
    assert(downloads.completed &&
           gpu_dep_word(old, 0) == UINT64_C(0x3333333333333333) &&
           gpu_dep_word(ram, firstAddress) == UINT64_C(0xff00ff00ff00ff00) &&
           gpu_dep_word(ram, secondAddress) == UINT64_C(0xffff0000ffff0000));
    puts("GPU download batch scope: a later overlapping surface preserves "
         "the earlier accepted prefix and both writebacks PASS");
}

static void surface_wait_prefix_tests(id<MTLDevice> device)
{
    for (unsigned scenario = 0; scenario < 6; scenario++) {
        BOOL failLater = scenario & 1;
        BOOL poll = scenario >= 4;
        BOOL cpuAccess = !poll && (scenario & 2);
        NSError *error = nil;
        IndependentReadCommands *commands =
            [[IndependentReadCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *foreign =
            [[IndependentReadCommands alloc] initWithDevice:device error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        require(commands && foreign && ram, error);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                      vram:ram
                                              didWriteVRAM:nil error:&error];
        require(cache != nil, error);
        gpu_dep_gate(foreign);
        id<MTLBuffer> readback = nil;
        NV2AMetalIndependentReads *reader =
            gpu_dep_read(cache, foreign, 16384, &readback);
        gpu_dep_gate(commands);
        gpu_dep_write(cache, 4096, 1);
        NV2AMetalSurfaceRecording *first = cache.recording;
        require([cache submitWithError:&error], error);
        gpu_dep_write(cache, 8192, 2);
        NV2AMetalSurfaceRecording *later = cache.recording;
        require([cache submitWithError:&error], error);
        require([cache prepareGPUReadAtAddress:24576 length:8 error:&error],
                error);
        NV2AMetalSurfaceRecording *open = cache.recording;
        commands.gate.signaledValue = 1;
        require([commands waitForSubmission:commands.lastSubmitted error:&error],
                error);
        foreign.gate.signaledValue = 1;
        require([foreign waitForSubmission:foreign.lastSubmitted error:&error],
                error);

        NSArray *entries = [cache valueForKey:@"submissions"];
        assert(entries.count == 2);
        CountedIndependentReadReceipt *independent =
            [CountedIndependentReadReceipt new];
        independent.nativeSubmission = foreign.lastSubmitted;
        independent.ready = YES;
        [reader setValue:independent forKey:@"submission"];
        CountedIndependentReadReceipt *feedback =
            [CountedIndependentReadReceipt new];
        feedback.nativeSubmission = commands.lastSubmitted;
        feedback.ready = YES;
        if (failLater)
            feedback.failure = [NSError errorWithDomain:@"test.surface.later"
                                                   code:1 userInfo:nil];
        [entries.lastObject setValue:feedback forKey:@"submission"];
        commands.waits = 0;
        require([cache resolveCPUAccessAtAddress:40960 length:8 write:NO
                                          error:&error], error);
        assert(!first.completed && !later.completed && !feedback.polls &&
               !independent.polls && !commands.waits);
        if (poll) {
            NSError *unavailable = nil;
            assert(![cache collectCompletedThroughRecording:open
                                                      error:&unavailable] &&
                   unavailable && cache.recording == open && !open.submitted);
            CountedIndependentReadReceipt *earlier =
                [CountedIndependentReadReceipt new];
            earlier.nativeSubmission = [entries[0] valueForKey:@"submission"];
            [entries[0] setValue:earlier forKey:@"submission"];
            require([cache collectCompletedThroughRecording:first error:&error],
                    error);
            assert(!first.completed && earlier.polls == 1 && !commands.waits &&
                   !independent.polls && !feedback.polls);
            earlier.ready = YES;
        }
        require(poll ?
                    [cache collectCompletedThroughRecording:first error:&error] :
                cpuAccess ?
                    [cache resolveCPUAccessAtAddress:4096 length:8 write:NO
                                               error:&error] :
                    [cache waitForRecording:first error:&error],
                error);
        assert(first.completed && !later.completed && !feedback.polls &&
               !independent.polls && !commands.waits &&
               cache.recording == open && !open.submitted &&
               gpu_dep_word(ram, 4096) == 1);
        BOOL idle = YES;
        require([cache tryIdleCPUAccessAtAddress:8192 length:8 write:NO
                                      completed:&idle error:&error], error);
        assert(!idle);
        BOOL collected = [cache collectCompletedWithError:&error];
        assert(collected == !failLater && feedback.polls == 1 &&
               independent.polls == 1 && later.completed == !failLater);
        if (failLater)
            assert(error == feedback.failure &&
                   ![cache collectCompletedWithError:&error] &&
                   error == feedback.failure);
        else
            assert(gpu_dep_word(ram, 8192) == 2);
        [cache cancel];
    }
    puts("Surface wait retirement scope: earlier wait leaves foreign and "
         "later success/failure feedback unpolled until collection PASS");
    puts("CPU VRAM read scope: disjoint and exact writer requests skip "
         "unrelated feedback and preserve the open recording PASS");
    puts("Surface recording poll: pending feedback returns without waiting, "
         "ready prefix retires without probing later or foreign feedback PASS");
}

static void independent_retirement_scope_tests(id<MTLDevice> device)
{
    for (unsigned scenario = 0; scenario < 12; scenario++) {
        unsigned outcome = scenario % 6;
        BOOL multiple = outcome & 1;
        BOOL cpuWrite = scenario >= 6;
        NSError *error = nil;
        NV2AMetalCommands *surface =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *foreign =
            [[IndependentReadCommands alloc] initWithDevice:device error:&error];
        id<MTLBuffer> ram = [device newBufferWithLength:65536
                                              options:MTLResourceStorageModeShared];
        require(surface && source && foreign && ram, error);
        memset(ram.contents, 0x44, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:surface
                                                      vram:ram
                                              didWriteVRAM:nil error:&error];
        require(cache != nil, error);
        NV2AMetalIndependentReads *scopes[4];
        CountedIndependentReadReceipt *feedback[4];
        id<MTLBuffer> outputs[4];
        const NSUInteger addresses[] = { 16384, 4096, 8192, 24576 };
        for (unsigned i = 0; i < 4; i++) {
            IndependentReadCommands *queue = i ? source : foreign;
            id<MTLBuffer> output = nil;
            scopes[i] = gpu_dep_read(cache, queue, addresses[i], &output);
            outputs[i] = output;
            require([queue waitForSubmission:queue.lastSubmitted error:&error],
                    error);
            feedback[i] = [CountedIndependentReadReceipt new];
            feedback[i].nativeSubmission = queue.lastSubmitted;
            [scopes[i] setValue:feedback[i] forKey:@"submission"];
        }
        feedback[0].ready = feedback[3].ready = YES;
        unsigned failed = outcome / 2 == 1 ? 0 : 3;
        if (outcome >= 2)
            feedback[failed].failure =
                [NSError errorWithDomain:@"test.reader.unrelated"
                                    code:scenario userInfo:nil];
        for (unsigned i = 0; i < 4; i++)
            feedback[i].polls = 0;
        source.waits = foreign.waits = 0;
        NV2AMetalIndependentReads *requested = scopes[multiple ? 2 : 1];
        if (cpuWrite) {
            require([cache resolveCPUAccessAtAddress:32768 length:8 write:YES
                                               error:&error], error);
            assert(!feedback[0].polls && !feedback[3].polls &&
                   !source.waits && !foreign.waits);
        }
        require(cpuWrite ?
                    [cache resolveCPUAccessAtAddress:4096
                                             length:multiple ? 4104 : 8
                                              write:YES error:&error] :
                    [cache completeIndependentReads:requested error:&error],
                error);
        assert(source.waits == (multiple ? 2 : 1) && !foreign.waits &&
               !feedback[0].polls && !feedback[3].polls &&
               feedback[2].polls == (multiple ? 1u : 0u) &&
               gpu_dep_word(outputs[1], 0) == UINT64_C(0x4444444444444444) &&
               gpu_dep_word(outputs[2], 0) == UINT64_C(0x4444444444444444));
        assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 4096, 8, YES) &&
               nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 8192, 8, YES) ==
                   multiple &&
               !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 16384, 8, YES) &&
               !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 24576, 8, YES));
        unsigned waits = source.waits;
        require([cache completeIndependentReads:requested error:&error], error);
        assert(source.waits == waits && !feedback[0].polls && !feedback[3].polls);
        feedback[2].ready = YES;
        BOOL collected = [cache collectCompletedWithError:&error];
        assert(collected == (outcome < 2));
        if (outcome >= 2)
            assert(error == feedback[failed].failure);
        else
            assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 24576, 8, YES));
    }
    puts("Independent retirement scope: six single/multiple-prefix cases "
         "release exact CPU guards, skip later/foreign feedback and errors, "
         "and repeat without waits PASS");
    puts("CPU writer reader scope: six exact/disjoint write cases validate "
         "the selected queue prefix and leave foreign/later errors for "
         "collection PASS");
}

static void gpu_write_dependency_tests(id<MTLDevice> device)
{
    cpu_submission_scope_tests(device);
    surface_wait_prefix_tests(device);
    independent_retirement_scope_tests(device);
    gpu_dependency_batch_scope_tests(device);
    gpu_download_batch_scope_test(device);
    NSError *error = nil;
    unsigned cases = 0;
    @autoreleasepool {
        NV2AMetalCommands *target =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        require(target && source && ram, error);
        memset(ram.contents, 0x33, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        gpu_dep_gate(source);
        id<MTLBuffer> old = nil;
        gpu_dep_read(cache, source, 32764, &old);
        gpu_dep_write(cache, 32764, UINT64_C(0x8888888888888888));
        NV2AMetalSurfaceRecording *written = cache.recording;
        require([cache submitWithError:&error], error);
        assert(!source.waits && !source.gate.signaledValue);
        /* Release independently of source CPU waits. Waiting only on the
         * target exercises the actual cross-queue GPU dependency. */
        id<MTLSharedEvent> gate = source.gate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         gate.signaledValue = 1;
                       });
        require([target waitForSubmission:target.lastSubmitted error:&error],
                error);
        assert(!source.waits && source.gate.signaledValue == 1 &&
               gpu_dep_word(old, 0) == UINT64_C(0x3333333333333333) &&
               gpu_dep_word(ram, 32764) == UINT64_C(0x8888888888888888));
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        source.waits = 0;
        require([cache waitForSubmission:target.lastSubmitted error:&error],
                error);
        assert(written.completed && !source.waits);
        require([cache discardForRestoreWithError:&error], error);
        cases++;
    }
    for (unsigned prefix = 0; prefix < 2; prefix++) {
        @autoreleasepool {
            NV2AMetalCommands *target =
                [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
            IndependentReadCommands *source =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            source.manualGate = YES;
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && ram, error);
            memset(ram.contents, 0x11, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            NV2AMetalSurfaceRecording *accepted = nil;
            id<MTLBuffer> first = nil;
            if (prefix) {
                gpu_dep_read(cache, source, 32764, &first);
                /* Make the earlier callback available before introducing the
                 * artificial later queue gate. Receipt selection is tested
                 * separately from the driver's callback scheduling. */
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                source.waits = 0;
                gpu_dep_write(cache, 32764, UINT64_C(0x5555555555555555));
                accepted = cache.recording;
                require([cache checkpointWithError:&error], error);
            }
            gpu_dep_gate(source);
            id<MTLBuffer> later = nil;
            NV2AMetalIndependentReads *pending =
                gpu_dep_read(cache, source, 40000, &later);
            gpu_dep_write(cache, 40000, UINT64_C(0x7777777777777777));
            NV2AMetalSurfaceRecording *cancelled = cache.recording;
            assert(!source.waits && !source.gate.signaledValue);
            [cache cancel];
            assert(cancelled.cancelled && !source.gate.signaledValue);
            id<MTLBuffer> unrelated = nil;
            if (!prefix) {
                require([cache prepareGPUReadAtAddress:60000
                                                length:8
                                                 error:&error],
                        error);
                unrelated = gpu_dep_copy(target, ram, 60000, nil, 0);
                accepted = cache.recording;
            }
            require([cache submitWithError:&error], error);
            require([cache waitForSubmission:target.lastSubmitted error:&error],
                    error);
            assert(accepted.completed && !source.gate.signaledValue &&
                   !*(uint64_t *)later.contents &&
                   gpu_dep_word(ram, 40000) == UINT64_C(0x1111111111111111));
            if (prefix) {
                assert(!source.waits &&
                       *(uint64_t *)first.contents ==
                           UINT64_C(0x1111111111111111) &&
                       gpu_dep_word(ram, 32764) ==
                           UINT64_C(0x5555555555555555));
            } else
                assert(!source.waits && *(uint64_t *)unrelated.contents ==
                                            UINT64_C(0x1111111111111111));
            BOOL completed = YES;
            require([cache tryIdleCPUAccessAtAddress:40000
                                              length:8
                                               write:YES
                                           completed:&completed
                                               error:&error],
                    error);
            assert(!completed);
            source.gate.signaledValue = 1;
            require([cache completeIndependentReads:pending error:&error],
                    error);
            assert(*(uint64_t *)later.contents == UINT64_C(0x1111111111111111));
            require([cache discardForRestoreWithError:&error], error);
            cases++;
        }
    }
    for (unsigned failure = 0; failure < 3; failure++) {
        @autoreleasepool {
            NV2AMetalCommands *target =
                [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
            IndependentReadCommands *source =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            IndependentReadCommands *unrelated =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && unrelated && ram, error);
            memset(ram.contents, 0x22, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            gpu_dep_gate(unrelated);
            id<MTLBuffer> other = nil, a = nil, b = nil;
            gpu_dep_read(cache, unrelated, 40000, &other);
            id<MTLBuffer> prefixBytes = nil;
            NV2AMetalIndependentReads *confirmed =
                gpu_dep_read(cache, source, 32764, &prefixBytes);
            require([source waitForSubmission:source.lastSubmitted
                                        error:&error],
                    error);
            NV2AMetalIndependentReads *first =
                gpu_dep_read(cache, source, 32764, &a);
            require([source waitForSubmission:source.lastSubmitted
                                        error:&error],
                    error);
            IndependentReadReceipt *delayed = [IndependentReadReceipt new];
            delayed.nativeSubmission = source.lastSubmitted;
            [first setValue:delayed forKey:@"submission"];
            NV2AMetalIndependentReads *last =
                gpu_dep_read(cache, source, 32764, &b);
            require([source waitForSubmission:source.lastSubmitted
                                        error:&error],
                    error);
            source.waits = 0;
            gpu_dep_write(cache, 32764, UINT64_C(0x6666666666666666));
            NV2AMetalSurfaceRecording *written = cache.recording;
            if (failure == 2) {
                delayed.failure =
                    [NSError errorWithDomain:@"test.gpu-source-prefix"
                                        code:89
                                    userInfo:nil];
                delayed.ready = YES;
                assert(![cache submitWithError:&error] &&
                       error == delayed.failure && cache.recording == written &&
                       target.commandBuffer && !written.submitted &&
                       !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 60000,
                                                  8, NO));
                [cache cancel];
                assert(written.cancelled && !target.commandBuffer &&
                       gpu_dep_word(ram, 32764) ==
                           UINT64_C(0x2222222222222222));
                unrelated.gate.signaledValue = 1;
                require([unrelated waitForSubmission:unrelated.lastSubmitted
                                               error:&error],
                        error);
                cache = nil;
                require([target waitUntilIdleWithError:&error], error);
                cases++;
                continue;
            }
            require([cache submitWithError:&error], error);
            require([target waitForSubmission:target.lastSubmitted
                                        error:&error],
                    error);
            SEL feedbackSelector = @selector(completedWithError:);
            Method feedback = class_getInstanceMethod(
                NV2AMetalIndependentReads.class, feedbackSelector);
            assert(feedback);
            BOOL (*original)(id, SEL, NSError **) =
                (void *)method_getImplementation(feedback);
            __block unsigned confirmedChecks = 0;
            __block unsigned pendingChecks = 0;
            __block unsigned lastChecks = 0;
            IMP spy = imp_implementationWithBlock(
                ^BOOL(NV2AMetalIndependentReads *reader, NSError **failure) {
                    confirmedChecks += reader == confirmed;
                    pendingChecks += reader == first;
                    lastChecks += reader == last;
                    return original(reader, feedbackSelector, failure);
                });
            method_setImplementation(feedback, spy);
            for (unsigned i = 0; i < 32; i++)
                require([cache collectCompletedWithError:&error], error);
            method_setImplementation(feedback, (IMP)original);
            assert(confirmedChecks == 1 && pendingChecks == 32 &&
                   gpu_dep_word(prefixBytes, 0) == UINT64_C(0x2222222222222222));
            BOOL completed = YES;
            require([cache tryIdleCPUAccessAtAddress:32764
                                              length:8
                                               write:NO
                                           completed:&completed
                                               error:&error],
                    error);
            assert(!completed && !written.completed && written.submitted &&
                   !delayed.ready && !source.waits && !unrelated.waits &&
                   !unrelated.gate.signaledValue &&
                   *(uint64_t *)a.contents == UINT64_C(0x2222222222222222) &&
                   *(uint64_t *)b.contents == UINT64_C(0x2222222222222222) &&
                   gpu_dep_word(ram, 32764) == UINT64_C(0x6666666666666666));
            delayed.failure =
                failure ? [NSError errorWithDomain:@"test.gpu-source-prefix"
                                              code:88
                                          userInfo:nil] :
                          nil;
            error = nil;
            confirmedChecks = pendingChecks = lastChecks = 0;
            method_setImplementation(feedback, spy);
            BOOL ok = [cache waitForRecording:written error:&error];
            method_setImplementation(feedback, (IMP)original);
            assert(imp_removeBlock(spy));
            assert(ok == !failure && delayed.ready && source.waits == 1 &&
                   !confirmedChecks && pendingChecks == 1 &&
                   lastChecks == (failure ? 0u : 1u));
            if (failure) {
                assert(error == delayed.failure && !written.completed &&
                       !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 60000,
                                                  8, NO));
            } else {
                completed = NO;
                require([cache tryIdleCPUAccessAtAddress:32764
                                                  length:8
                                                   write:NO
                                               completed:&completed
                                                   error:&error],
                        error);
                assert(completed && written.completed);
            }
            assert(!unrelated.waits && !unrelated.gate.signaledValue &&
                   !*(uint64_t *)other.contents);
            unrelated.gate.signaledValue = 1;
            require([unrelated waitForSubmission:unrelated.lastSubmitted
                                           error:&error],
                    error);
            assert(*(uint64_t *)other.contents == UINT64_C(0x2222222222222222));
            if (!failure)
                require([cache discardForRestoreWithError:&error], error);
            cache = nil;
            require([target waitUntilIdleWithError:&error], error);
            cases++;
        }
    }
    assert(cases == 6);
    checks += cases;
    puts("Surface dependency collection: one check for confirmed reader "
         "feedback across 32 polls of a pending dependency PASS");
    puts("Surface dependency wait: skips confirmed readers, shares successful "
         "feedback with collection and preserves source failure order PASS");
    puts("GPU RAM dependencies:six native gate/cancel/prefix/feedback "
         "cases;direct "
         "copies keep old reader bytes,accepted writer survives cancelled "
         "later-source suffix,no ghost GPU wait,unrelated queue remains "
         "gated,CPU publication waits for earlier source feedback,late source "
         "errors before submit and after GPU completion are sticky despite "
         "later success PASS");
}
#endif
