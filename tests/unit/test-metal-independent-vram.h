/* Independent producer VRAM ownership across queues, cancellation and restore.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_INDEPENDENT_VRAM_H
#define TEST_METAL_INDEPENDENT_VRAM_H
@interface IndependentReadReceipt : NSObject
@property(nonatomic) BOOL ready;
@property(nonatomic) NSError *failure;
@property(nonatomic) NV2AMetalSubmission *nativeSubmission;
@property(nonatomic) BOOL waitForNativeFeedback;
- (BOOL)completedWithError:(NSError **)error;
- (BOOL)hasSeparateProducerFeedback;
- (BOOL)belongsToOwner:(NV2AMetalCommands *)owner;
- (id<MTLEvent>)signalEvent;
- (uint64_t)signalValue;
@end
@implementation IndependentReadReceipt
- (BOOL)hasSeparateProducerFeedback
{
    return NO;
}
- (BOOL)belongsToOwner:(NV2AMetalCommands *)owner
{
    return [owner ownsSubmission:_nativeSubmission];
}
- (id<MTLEvent>)signalEvent
{
    return [_nativeSubmission valueForKey:@"signalEvent"];
}
- (uint64_t)signalValue
{
    return
        [[_nativeSubmission valueForKey:@"signalValue"] unsignedLongLongValue];
}
- (BOOL)completedWithError:(NSError **)error
{
    if (error)
        *error = _ready ? _failure : nil;
    return _ready;
}
@end

@interface CountedIndependentReadReceipt : IndependentReadReceipt
@property(nonatomic) unsigned polls;
@end
@implementation CountedIndependentReadReceipt
- (BOOL)completedWithError:(NSError **)error
{
    _polls++;
    return [super completedWithError:error];
}
@end

@interface NV2AMetalSurfaceCache (IndependentReadPrefixTest)
- (NSArray<NV2AMetalIndependentReads *> *)
    independentReadDependenciesMatching:
        (NS_NOESCAPE BOOL (^)(NV2AMetalIndependentReads *))matches
                                   error:(NSError **)error;
- (BOOL)orderAfterIndependentReadsAtAddress:(NSUInteger)address
                                     length:(NSUInteger)length
                                      error:(NSError **)error;
@end
@interface IndependentReadCommands : NV2AMetalCommands
@property(nonatomic) id<MTLSharedEvent> gate;
@property(nonatomic) unsigned waits;
@property(nonatomic) unsigned idleWaits;
@property(nonatomic) BOOL failWait, omitWaitError;
@property(nonatomic) BOOL manualGate;
@end
@implementation IndependentReadCommands
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    _idleWaits++;
    return [super waitUntilIdleWithError:error];
}
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    _waits++;
    IndependentReadReceipt *receipt = nil;
    if ([(id)submission isKindOfClass:IndependentReadReceipt.class]) {
        receipt = (id)submission;
        submission = receipt.nativeSubmission;
    }
    if (!receipt || receipt.waitForNativeFeedback) {
        if (_gate && !_gate.signaledValue && !_manualGate)
            _gate.signaledValue = 1;
        if (![super waitForSubmission:submission error:error])
            return NO;
    }
    if (receipt) {
        receipt.ready = YES;
        if (error)
            *error = receipt.failure;
        return !receipt.failure;
    }
    if (!_failWait)
        return YES;
    if (error && !_omitWaitError)
        *error = [NSError errorWithDomain:@"test.independent.completion"
                                     code:1
                                 userInfo:nil];
    return NO;
}
@end

static id<MTLBuffer> independent_read_copy(NV2AMetalCommands *commands,
                                           id<MTLBuffer> ram)
{
    NSError *error = nil;
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:8
                                     options:MTLResourceStorageModeShared];
    assert(output);
    require([commands addResource:output error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:ram
               sourceOffset:32764
                   toBuffer:output
          destinationOffset:0
                       size:8];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return output;
}

static unsigned independent_completion_prefix_tests(id<MTLDevice> device)
{
    unsigned cases = 0;
    for (unsigned copied = 0; copied < 2; copied++)
        for (unsigned later = 0; later < 3; later++) {
            NSError *error = nil;
            NV2AMetalCommands *surface =
                [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
            IndependentReadCommands *producer =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            id<MTLBuffer> input =
                copied ?
                    [device newBufferWithLength:65536
                                        options:MTLResourceStorageModeShared] :
                    ram;
            assert(ram && input);
            memset(input.contents, 0x57, input.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:surface
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            NV2AMetalVRAMReadSpan span = { 32764, 8 };
            NV2AMetalIndependentReads *first = nil, *second = nil;
            require([cache tryBeginIndependentReads:copied ? NULL : &span
                                              count:copied ? 0 : 1
                                           commands:producer
                                              reads:&first
                                              error:&error],
                    error);
            require([producer addResource:input error:&error], error);
            id<MTLBuffer> a = independent_read_copy(producer, input);
            require([cache submitIndependentReads:first error:&error], error);
            require([producer waitForSubmission:producer.lastSubmitted
                                          error:&error],
                    error);
            /* Real GPU work is complete. Delay only its receipt publication
             * so the first scope remains live while the second is recorded. */
            IndependentReadReceipt *delayed = [IndependentReadReceipt new];
            delayed.nativeSubmission = producer.lastSubmitted;
            [first setValue:delayed forKey:@"submission"];
            require([cache tryBeginIndependentReads:copied ? NULL : &span
                                              count:copied ? 0 : 1
                                           commands:producer
                                              reads:&second
                                              error:&error],
                    error);
            require([producer addResource:input error:&error], error);
            id<MTLBuffer> b = independent_read_copy(producer, input);
            memset(b.contents, 0, b.length);
            id<MTL4CommandBuffer> recording = producer.commandBuffer;
            id<MTLSharedEvent> gate = [device newSharedEvent];
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(producer, queueIvar);
            assert(recording && gate && queue);
            [queue waitForEvent:gate value:1];
            NV2AMetalSubmission *secondReceipt = nil;
            if (later) {
                require([cache submitIndependentReads:second error:&error],
                        error);
                secondReceipt = producer.lastSubmitted;
                if (later == 2)
                    [cache cancelIndependentReads:second];
            }
            /* A broken full-queue wait must fail quickly without leaving a
             * gated queue behind after an assertion. */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             if (!gate.signaledValue)
                                 gate.signaledValue = 2;
                           });
            unsigned waits = producer.waits;
            require([cache completeIndependentReads:first error:&error], error);
            assert(delayed.ready && !gate.signaledValue &&
                   !producer.idleWaits && producer.waits == waits + 1);
            assert(*(uint64_t *)a.contents == UINT64_C(0x5757575757575757) &&
                   !*(uint64_t *)b.contents);
            assert(later ? !producer.commandBuffer :
                           producer.commandBuffer == recording);
            if (secondReceipt)
                assert(![secondReceipt completedWithError:&error]);
            assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8,
                                             YES) == !!copied);
            gate.signaledValue = 1;
            if (later) {
                require([cache completeIndependentReads:second error:&error],
                        error);
                assert(*(uint64_t *)b.contents == UINT64_C(0x5757575757575757));
            } else {
                [cache cancelIndependentReads:second];
            }
            assert(
                nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8, YES));
            /* Collection may already have retired the requested scope. */
            waits = producer.waits;
            require([cache completeIndependentReads:first error:&error], error);
            assert(producer.waits == waits && !producer.idleWaits);
            cases++;
        }
    puts("Independent completion prefix: six VRAM/copied cases preserve later "
         "recorded/submitted/cancelled work behind a GPU gate, exact bytes, "
         "CPU write guards, delayed feedback and retired receipts; zero drains "
         "or repeat waits for confirmed readers "
         "PASS");
    return cases;
}

static void independent_cpu_access_scope_test(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *surface =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    IndependentReadCommands *reader =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    IndependentReadCommands *unrelated =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    NV2AMetalCommands *recording =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    require(surface && reader && unrelated && recording && ram, error);
    memset(ram.contents, 0x37, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:surface
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    const NV2AMetalVRAMReadSpan span = { 32764, 8 }, other = { 16384, 8 },
                               open = { 49152, 8 };
    NV2AMetalIndependentReads *prefix = nil, *reads = nil, *next = nil;
    NV2AMetalIndependentReads *others = nil, *pending = nil;
    Ivar queueIvar =
        class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    for (IndependentReadCommands *producer in @[ reader, unrelated ]) {
        producer.gate = [device newSharedEvent];
        id<MTL4CommandQueue> queue = object_getIvar(producer, queueIvar);
        assert(queue && producer.gate);
        [queue waitForEvent:producer.gate value:1];
    }
    require([cache tryBeginIndependentReads:&other count:1 commands:reader
                                      reads:&prefix error:&error] && prefix &&
                [cache submitIndependentReads:prefix error:&error],
            error);
    require([cache tryBeginIndependentReads:&span count:1 commands:reader
                                      reads:&reads error:&error] && reads,
            error);
    id<MTLBuffer> readback = independent_read_copy(reader, ram);
    require([cache submitIndependentReads:reads error:&error], error);
    require([cache tryBeginIndependentReads:&span count:1 commands:reader
                                      reads:&next error:&error] && next,
            error);
    id<MTLBuffer> nextReadback = independent_read_copy(reader, ram);
    require([cache submitIndependentReads:next error:&error], error);
    require([cache tryBeginIndependentReads:&other count:1 commands:unrelated
                                      reads:&others error:&error] && others &&
                [cache submitIndependentReads:others error:&error],
            error);
    require([cache tryBeginIndependentReads:&open count:1 commands:recording
                                      reads:&pending error:&error] && pending,
            error);
    id<MTL4CommandBuffer> pendingBuffer = recording.commandBuffer;
    assert(pendingBuffer);

    /* Count discovery polls independently of registration and submission,
     * which also check for feedback arriving after this pass. */
    NSArray *readers = @[ prefix, reads, next, others ];
    NSMutableArray<CountedIndependentReadReceipt *> *receipts =
        [NSMutableArray new];
    for (NV2AMetalIndependentReads *item in readers) {
        CountedIndependentReadReceipt *receipt = [CountedIndependentReadReceipt new];
        receipt.nativeSubmission = [item valueForKey:@"submission"];
        [item setValue:receipt forKey:@"submission"];
        [receipts addObject:receipt];
    }
    NSArray *dependencies =
        [cache independentReadDependenciesMatching:
          ^BOOL(NV2AMetalIndependentReads *reader) {
          NSData *spans = [reader valueForKey:@"spans"];
          const NV2AMetalVRAMReadPattern *pattern = spans.bytes;
          return spans.length == sizeof(*pattern) &&
                 pattern->address == span.address;
        } error:&error];
    NSArray *expected = @[ prefix, reads, next ];
    assert([dependencies isEqualToArray:expected]);
    for (unsigned i = 0; i < receipts.count; i++) {
        assert(receipts[i].polls == (i < 3));
        [readers[i] setValue:receipts[i].nativeSubmission forKey:@"submission"];
    }
    puts("GPU VRAM reader prefix: each selected receipt checked once, "
         "same-queue disjoint prefix included and other queues skipped PASS");

    id<MTLBuffer> surfaceCopy = encode_vram_copy(cache, 60000, 4);
    NV2AMetalSurfaceRecording *token = cache.recording;
    require([cache prepareCPUAccessAtAddress:span.address length:span.length
                                       write:NO error:&error],
            error);
    assert(token.completed && !reader.waits && !unrelated.waits &&
           !reader.gate.signaledValue && !unrelated.gate.signaledValue &&
           recording.commandBuffer == pendingBuffer &&
           ![unrelated.lastSubmitted completedWithError:&error] && !error &&
           *(uint32_t *)surfaceCopy.contents == 0x37373737);
    /* Keep the selected callbacks pending until their waits, regardless of
     * how quickly the real GPU reaches the later copies after the first gate. */
    for (unsigned i = 0; i < 3; i++) {
        receipts[i].waitForNativeFeedback = YES;
        [readers[i] setValue:receipts[i] forKey:@"submission"];
    }
    require([cache prepareCPUAccessAtAddress:span.address length:span.length
                                       write:YES error:&error],
            error);
    memset((uint8_t *)ram.contents + span.address, 0x94, span.length);
    assert(reader.waits == 3 && !unrelated.waits &&
           !unrelated.gate.signaledValue &&
           recording.commandBuffer == pendingBuffer &&
           ![unrelated.lastSubmitted completedWithError:&error] && !error &&
           *(uint64_t *)readback.contents == UINT64_C(0x3737373737373737) &&
           *(uint64_t *)nextReadback.contents == UINT64_C(0x3737373737373737));
    [cache cancelIndependentReads:pending];
    unrelated.gate.signaledValue = 1;
    require([cache completeIndependentReads:others error:&error], error);
    puts("CPU VRAM reader scope: read shares GPU source, write waits only "
         "overlap, unrelated submitted and open readers survive PASS");
    puts("CPU VRAM reader prefix: two overlapping submissions share three "
         "ordered waits including their disjoint queue prefix PASS");
}

static void clean_surface_retirement_tests(id<MTLDevice> device)
{
    const uint32_t value = 0xff267ade;
    for (unsigned rebind = 0; rebind < 2; rebind++) {
        NSError *error = nil;
        IndependentReadCommands *commands =
            [[IndependentReadCommands alloc] initWithDevice:device error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        require(commands && ram, error);
        memcpy(ram.contents, &value, sizeof(value));
        NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
            initWithCommands:commands vram:ram didWriteVRAM:nil error:&error];
        require(cache != nil, error);
        NV2AMetalSurfaceConfig c =
            config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
        NV2AMetalCachedSurface *old = [cache prepareSurfaceAtAddress:0
                                                              config:&c frame:0
                                                               error:&error];
        require(old != nil, error);
        id<MTLBuffer> pixels =
            [device newBufferWithLength:old.transfer.sourceLength
                                options:MTLResourceStorageModeShared];
        require(pixels && [old.transfer encodeDownloadToBuffer:pixels offset:0
                                                       swizzle:YES flip:NO
                                                      downscale:YES
                                                       commands:commands
                                                          error:&error], error);
        commands.gate = [device newSharedEvent];
        Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(commands, ivar);
        assert(queue && commands.gate);
        [queue waitForEvent:commands.gate value:1];
        require([cache submitWithError:&error], error);
        NV2AMetalSubmission *submitted = commands.lastSubmitted;
        assert(!old.dirty);

        require([cache prepareGPUReadAtAddress:8192 length:4 error:&error], error);
        NV2AMetalSurfaceRecording *sealed = cache.recording;
        require([cache checkpointWithError:&error] &&
                    [cache prepareGPUReadAtAddress:12288 length:4 error:&error],
                error);
        NV2AMetalSurfaceRecording *open = cache.recording;
        if (rebind) {
            c.format = NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8;
            NV2AMetalCachedSurface *replacement =
                [cache selectSurfaceAtAddress:0 config:&c frame:5 error:&error];
            require(replacement != nil, error);
            assert(replacement != old && replacement.valid &&
                   replacement.needsUpload);
        } else {
            require([cache evictBeforeFrame:5 error:&error], error);
        }
        assert(!old.valid && cache.count == rebind && !commands.waits &&
               !commands.gate.signaledValue && commands.lastSubmitted == submitted &&
               commands.sealedBufferCount == 1 && !sealed.submitted &&
               cache.recording == open);
        old = nil;
        BOOL ready = YES;
        require([cache tryIdleCPUAccessAtAddress:0 length:4 write:YES
                                       completed:&ready error:&error], error);
        assert(!ready);
        commands.gate.signaledValue = 1;
        require([cache waitForSubmission:submitted error:&error], error);
        assert(!memcmp(pixels.contents, &value, sizeof(value)) &&
               cache.recording == open && !sealed.submitted);
        [cache cancel];
        require([cache flushWithError:&error], error);
        assert(open.cancelled && sealed.completed);
    }
    puts("Clean surface retirement: eviction and format rebind keep gated "
         "uploads, VRAM guards and unrelated recording state intact PASS");
    checks++;
}

static void guarded_surface_writeback_tests(id<MTLDevice> device)
{
    const uint32_t initial = 0x12274269, cleared = 0xffff0000;
    for (unsigned rebind = 0; rebind < 2; rebind++) {
        NSError *error = nil;
        IndependentReadCommands *commands =
            [[IndependentReadCommands alloc] initWithDevice:device error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        require(commands && ram, error);
        memcpy(ram.contents, &initial, sizeof(initial));
        __block unsigned watches = 0, notifications = 0;
        NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
            initWithCommands:commands vram:ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(!address && length);
              notifications++;
            } error:&error];
        require(cache != nil, error);
        cache.willWatchVRAM = ^(NSUInteger address, NSUInteger length) {
          assert(!address && length == 4096);
          watches++;
        };
        NV2AMetalSurfaceConfig c =
            config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
        NV2AMetalCachedSurface *old = [cache prepareSurfaceAtAddress:0
                                                              config:&c frame:0
                                                               error:&error];
        require(old != nil, error);
        clear_surface(cache, old, MTLClearColorMake(1, 0, 0, 1), 0, 0);
        NV2AMetalSurfaceRecording *writeback = cache.recording;
        commands.gate = [device newSharedEvent];
        Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(commands, ivar);
        assert(queue && commands.gate);
        [queue waitForEvent:commands.gate value:1];
        if (rebind)
            c.format = NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8;
        else
            require([cache evictBeforeFrame:5 error:&error], error);
        NV2AMetalCachedSurface *next = [cache prepareSurfaceAtAddress:0
                                                               config:&c frame:5
                                                                error:&error];
        require(next != nil, error);
        assert(next != old && !old.valid && writeback.submitted &&
               !writeback.completed && !commands.waits &&
               !commands.gate.signaledValue && !notifications && watches == 1);
        assert(!memcmp(ram.contents, &initial, sizeof(initial)));
        for (unsigned write = 0; write < 2; write++) {
            BOOL ready = YES;
            require([cache tryIdleCPUAccessAtAddress:0 length:4 write:write
                                           completed:&ready error:&error], error);
            assert(!ready);
        }
        NV2AMetalCommands *reader =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        require(reader != nil, error);
        NV2AMetalVRAMReadSpan span = { 0, sizeof(initial) };
        NV2AMetalIndependentReads *reads = nil;
        require([cache tryBeginIndependentReads:&span count:1 commands:reader
                                          reads:&reads error:&error], error);
        assert(!reads && !reader.commandBuffer);
        NV2AMetalSurfaceRecording *upload = cache.recording;
        commands.gate.signaledValue = 1;
        require([cache resolveCPUAccessAtAddress:0 length:4 write:NO
                                           error:&error], error);
        assert(upload && cache.recording == upload && !upload.submitted &&
               writeback.completed && notifications == 1 &&
               !memcmp(ram.contents, &cleared, sizeof(cleared)));
        id<MTLBuffer> pixels = gpu_pixels(cache, next);
        assert(writeback.completed && notifications == 1 &&
               !memcmp(ram.contents, &cleared, sizeof(cleared)) &&
               !memcmp(pixels.contents, &cleared, sizeof(cleared)));
    }
    puts("Guarded surface writeback: retirement submits while the queue is "
         "gated; CPU and independent reads stay protected and the replacement "
         "sees the exact pixels PASS");
    checks++;
}

static void independent_vram_tests(id<MTLDevice> device)
{
    clean_surface_retirement_tests(device);
    guarded_surface_writeback_tests(device);
    independent_cpu_access_scope_test(device);
    NSError *error = nil;
    unsigned cases = independent_completion_prefix_tests(device);
    for (unsigned action = 0; action < 8; action++) {
        NV2AMetalCommands *surfaceCommands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *producer =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        require(surfaceCommands && producer, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        assert(ram);
        memset(ram.contents, 0x33, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:surfaceCommands
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        id<MTLBuffer> surfaceCopy = encode_vram_copy(cache, 60000, 4);
        NV2AMetalSurfaceRecording *token = cache.recording;
        id recording = surfaceCommands.commandBuffer;
        NV2AMetalVRAMReadSpan spans[] = { { 32764, 8 },
                                          { 32768, 4 },
                                          { 65536, 0 } };
        NV2AMetalIndependentReads *reads = nil;
        require([cache tryBeginIndependentReads:spans
                                          count:3
                                       commands:producer
                                          reads:&reads
                                          error:&error],
                error);
        assert(reads && producer.commandBuffer);
        id<MTLBuffer> output = independent_read_copy(producer, ram);
        assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8, YES));
        assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8, NO));
        BOOL completed = YES;
        require([cache tryIdleCPUAccessAtAddress:32764
                                          length:8
                                           write:YES
                                       completed:&completed
                                           error:&error],
                error);
        assert(!completed);
        require([cache tryIdleCPUAccessAtAddress:32780
                                          length:4
                                           write:YES
                                       completed:&completed
                                           error:&error],
                error);
        assert(completed);
        /* An unsent producer must be explicitly resolved before any writer. */
        assert(![cache prepareGPUWriteAtAddress:32764 length:8 error:&error] &&
               error);
        assert(![cache discardForRestoreWithError:&error] && error);
        /* Restore cancels only its own unsent surface work, never these reads.
         */
        assert(token.cancelled && producer.commandBuffer != nil);
        require([cache prepareGPUReadAtAddress:60000 length:4 error:&error],
                error);
        recording = surfaceCommands.commandBuffer;
        token = cache.recording;
        if (action == 0 || action == 1) {
            if (action == 1) {
                require([cache prepareGPUReadAtAddress:32768
                                                length:4
                                                 error:&error],
                        error);
            }
            [cache cancelIndependentReads:reads];
            assert(!producer.commandBuffer && cache.recording == token &&
                   surfaceCommands.commandBuffer == recording &&
                   !token.cancelled);
            assert(
                nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 4, YES));
            assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32768, 4,
                                             YES) == !action);
            [cache cancel];
        } else {
            producer.gate = [device newSharedEvent];
            assert(producer.gate);
            Ivar queueIvar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(producer, queueIvar);
            [queue waitForEvent:producer.gate value:1];
            require([cache submitIndependentReads:reads error:&error], error);
            assert(![cache submitIndependentReads:reads error:&error] && error);
            [cache cancelIndependentReads:reads];
            require([cache collectCompletedWithError:&error], error);
            assert(!producer.gate.signaledValue &&
                   !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8,
                                              YES));
            if (action == 2) {
                require([cache prepareGPUWriteAtAddress:32764
                                                 length:8
                                                  error:&error],
                        error);
                assert(cache.recording == token &&
                       surfaceCommands.commandBuffer == recording);
                [cache cancel];
                assert(!producer.waits && !producer.gate.signaledValue);
                require([cache completeIndependentReads:reads error:&error], error);
            } else if (action == 3) {
                NV2AMetalSurfaceConfig c = config(
                    NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
                require([cache prepareSurfaceAtAddress:32764
                                                config:&c
                                                 frame:0
                                                 error:&error] != nil,
                        error);
                [cache cancel];
                assert(!producer.waits && !producer.gate.signaledValue &&
                       !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764,
                                                  8, YES));
                require([cache completeIndependentReads:reads error:&error],
                        error);
            } else if (action == 4) {
                require([cache discardForRestoreWithError:&error], error);
                assert(token.cancelled);
            } else if (action == 5) {
                require([cache flushWithError:&error], error);
                assert(token.submitted && token.completed);
            } else if (action == 6) {
                require([cache prepareCPUAccessAtAddress:32764
                                                  length:8
                                                   write:YES
                                                   error:&error],
                        error);
                assert(token.submitted && token.completed);
            } else {
                [cache cancel];
                /* Cache owns the submitted reader even if the caller drops it.
                 */
                __weak IndependentReadCommands *weakProducer = producer;
                id<MTLSharedEvent> gate = producer.gate;
                producer = nil;
                reads = nil;
                assert(weakProducer && !gate.signaledValue);
                require([cache waitUntilIdleWithError:&error], error);
                assert(gate.signaledValue == 1);
            }
            if (producer)
                assert(producer.waits && producer.gate.signaledValue == 1);
            assert(*(uint64_t *)output.contents ==
                   UINT64_C(0x3333333333333333));
        }
        require([cache tryIdleCPUAccessAtAddress:32764
                                          length:8
                                           write:YES
                                       completed:&completed
                                           error:&error],
                error);
        assert(completed); /* Destination watches may remain conservative. */
        require([cache discardForRestoreWithError:&error], error);
        (void)surfaceCopy;
        cases++;
    }
    /* Dirty surface aliases and GPU destinations request the existing queue
     * path; invalid/foreign input does not start or steal any recording. */
    for (unsigned kind = 0; kind < 5; kind++) {
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        NV2AMetalCommands *producer =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        require(commands && producer, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        assert(ram);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        if (kind < 2) {
            NV2AMetalSurfaceConfig c = config(
                NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
            NV2AMetalCachedSurface *surface =
                [cache prepareSurfaceAtAddress:32764
                                        config:&c
                                         frame:0
                                         error:&error];
            require(surface != nil, error);
            clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
        } else
            require([cache prepareGPUWriteAtAddress:32764
                                             length:8
                                              error:&error],
                    error);
        id<MTLSharedEvent> pendingGate = nil;
        if (kind == 1 || kind == 3) {
            pendingGate = [device newSharedEvent];
            assert(pendingGate);
            Ivar ivar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, ivar);
            [queue waitForEvent:pendingGate value:1];
            require([cache submitWithError:&error], error);
        }
        NV2AMetalVRAMReadSpan span = { kind == 4 ? 65535 : 32764, 8 };
        NV2AMetalIndependentReads *reads = nil;
        BOOL ok = [cache tryBeginIndependentReads:&span
                                            count:1
                                         commands:producer
                                            reads:&reads
                                            error:&error];
        assert(ok == (kind != 4) && !reads && !producer.commandBuffer);
        [cache cancel];
        pendingGate.signaledValue = 1;
        require([cache waitUntilIdleWithError:&error], error);
        cases++;
    }
    /* Real copies finish first; only feedback arrival/error is injected. A
     * later success cannot retire an older delayed failure or open CPU access.
     */
    for (unsigned mode = 0; mode < 6; mode++) {
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *producer =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        require(commands && producer, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        assert(ram);
        memset(ram.contents, 0x33, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        NV2AMetalVRAMReadSpan span = { 32764, 8 };
        NV2AMetalIndependentReads *first = nil, *second = nil;
        require([cache tryBeginIndependentReads:&span
                                          count:1
                                       commands:producer
                                          reads:&first
                                          error:&error],
                error);
        id<MTLBuffer> a = independent_read_copy(producer, ram);
        require([cache submitIndependentReads:first error:&error], error);
        require([producer waitForSubmission:producer.lastSubmitted
                                      error:&error],
                error);
        IndependentReadReceipt *delayed = [IndependentReadReceipt new];
        delayed.nativeSubmission = producer.lastSubmitted;
        [first setValue:delayed forKey:@"submission"];
        require([cache tryBeginIndependentReads:&span
                                          count:1
                                       commands:producer
                                          reads:&second
                                          error:&error],
                error);
        id<MTLBuffer> b = independent_read_copy(producer, ram);
        require([cache submitIndependentReads:second error:&error], error);
        require([producer waitForSubmission:producer.lastSubmitted
                                      error:&error],
                error);
        assert(*(uint64_t *)a.contents == UINT64_C(0x3333333333333333) &&
               *(uint64_t *)b.contents == UINT64_C(0x3333333333333333));
        require([cache collectCompletedWithError:&error], error);
        assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8, YES));
        encode_vram_copy(cache, 60000, 4);
        NV2AMetalSurfaceRecording *token = cache.recording;
        id recording = commands.commandBuffer;
        delayed.failure = [NSError errorWithDomain:@"test.independent.feedback"
                                              code:7
                                          userInfo:nil];
        error = nil;
        if (mode < 2) {
            require([cache prepareGPUWriteAtAddress:32764 length:8 error:&error], error);
            assert(!delayed.ready);
            require([cache submitWithError:&error], error);
            require([commands waitForSubmission:commands.lastSubmitted
                                          error:&error],
                    error);
            require([cache collectCompletedWithError:&error], error);
            assert(
                !delayed.ready && token.submitted && !token.completed &&
                !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 32764, 8, NO));
            assert(![cache waitForSubmission:commands.lastSubmitted
                                       error:mode ? NULL : &error]);
        } else if (mode < 4) {
            delayed.ready = YES;
            assert(
                ![cache collectCompletedWithError:mode == 3 ? NULL : &error]);
        } else {
            assert(![cache completeIndependentReads:second
                                              error:mode == 5 ? NULL : &error]);
        }
        assert(delayed.ready && !token.cancelled);
        assert(mode < 2 ? token.submitted && !token.completed &&
                              !commands.commandBuffer :
                          cache.recording == token &&
                              commands.commandBuffer == recording);
        assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, ram.length,
                                          NO));
        error = nil;
        assert(![cache collectCompletedWithError:&error] &&
               error == delayed.failure);
        assert(![cache tryBeginIndependentReads:&span
                                          count:1
                                       commands:producer
                                          reads:&second
                                          error:&error]);
        [cache cancel];
        assert(token.cancelled == (mode >= 2));
        cases++;
    }
    for (unsigned omit = 0; omit < 2; omit++) {
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        IndependentReadCommands *producer =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        require(commands && producer, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        assert(ram);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        NV2AMetalVRAMReadSpan span = { 32764, 8 };
        NV2AMetalIndependentReads *reads = nil;
        require([cache tryBeginIndependentReads:&span
                                          count:1
                                       commands:producer
                                          reads:&reads
                                          error:&error],
                error);
        assert(![cache completeIndependentReads:reads error:&error] && error);
        producer.gate = [device newSharedEvent];
        id<MTL4CommandQueue> queue = object_getIvar(
            producer, class_getInstanceVariable(NV2AMetalCommands.class,
                                                "_queue"));
        assert(queue && producer.gate);
        [queue waitForEvent:producer.gate value:1];
        independent_read_copy(producer, ram);
        require([cache submitIndependentReads:reads error:&error], error);
        producer.failWait = YES;
        producer.omitWaitError = omit;
        error = nil;
        assert(![cache completeIndependentReads:reads
                                          error:omit ? NULL : &error]);
        assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, ram.length,
                                          NO));
        error = nil;
        assert(![cache collectCompletedWithError:&error] && error);
        cases++;
    }
    checks += cases;
    printf("Independent VRAM readers: %u "
           "span/overlap/cancel/inflight/CPU/GPU/restore/owner cases PASS\n",
           cases);
}
#endif
