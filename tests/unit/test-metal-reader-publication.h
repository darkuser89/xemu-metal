/* Reader publication must include conflicting writers' execution witnesses.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_READER_PUBLICATION_H
#define TEST_METAL_READER_PUBLICATION_H
@interface ReaderPublicationCommands : MissingReadEventCommands
@property(nonatomic) unsigned publicationWaits;
@property(nonatomic) BOOL omitWaitError;
@property(nonatomic) id<MTLSharedEvent> laterGate;
@property(nonatomic) NV2AMetalSubmission *laterSubmission;
@property(nonatomic) unsigned laterWaits, idleWaits;
@end
@implementation ReaderPublicationCommands
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    if (submission == _laterSubmission) {
        _laterWaits++;
        if (!_laterGate.signaledValue)
            _laterGate.signaledValue = 1;
    }
    if ([(id)submission isKindOfClass:IndependentReadReceipt.class]) {
        _publicationWaits++;
        IndependentReadReceipt *receipt = (id)submission;
        receipt.ready = YES;
        if (error)
            *error = _omitWaitError ? nil : receipt.failure;
        return !_omitWaitError && !receipt.failure;
    }
    return [super waitForSubmission:submission error:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    _idleWaits++;
    if (_laterGate && !_laterGate.signaledValue)
        _laterGate.signaledValue = 1;
    return [super waitUntilIdleWithError:error];
}
@end
static IndependentReadReceipt *
reader_delayed_feedback(NV2AMetalCommands *commands)
{
    IndependentReadReceipt *receipt = [IndependentReadReceipt new];
    receipt.nativeSubmission = commands.lastSubmitted;
    return receipt;
}
static void reader_publication_tests(id<MTLDevice> device)
{
    unsigned cases = 0;
    for (unsigned mode = 0; mode < 6; mode++) {
        @autoreleasepool {
            NSError *error = nil;
            BOOL badOrder = mode < 3, laterReader = mode == 1;
            BOOL otherHead = mode == 2 || mode == 3;
            ReaderPublicationCommands *target =
                [[ReaderPublicationCommands alloc] initWithDevice:device
                                                            error:&error];
            target.omitReadEvent = badOrder;
            target.omitWaitError = mode == 5;
            IndependentReadCommands *source =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            IndependentReadCommands *other =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && other && ram, error);
            memset(ram.contents, 0x44, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            IndependentReadReceipt *head = nil;
            if (otherHead) {
                id<MTLBuffer> bytes = nil;
                NV2AMetalIndependentReads *scope =
                    gpu_dep_read(cache, other, 24000, &bytes);
                require([other waitForSubmission:other.lastSubmitted
                                           error:&error],
                        error);
                head = reader_delayed_feedback(other);
                [scope setValue:head forKey:@"submission"];
            }
            if (badOrder)
                gpu_dep_gate(source);
            id<MTLBuffer> old = nil;
            NV2AMetalIndependentReads *reads =
                gpu_dep_read(cache, source, 32764, &old);
            if (!badOrder) {
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                [reads setValue:reader_delayed_feedback(source)
                         forKey:@"submission"];
            }
            gpu_dep_write(cache, 32764, UINT64_C(0x7777777777777777));
            NV2AMetalSurfaceRecording *written = cache.recording;
            require([cache submitWithError:&error] &&
                        [target waitForSubmission:target.lastSubmitted
                                            error:&error],
                    error);
            NSArray *submitted = [cache valueForKey:@"submissions"];
            assert(submitted.count == 1);
            IndependentReadReceipt *writer = reader_delayed_feedback(target);
            NSError *writerError =
                mode == 4 ? [NSError errorWithDomain:@"test.reader.writer"
                                                code:77
                                            userInfo:nil] :
                            nil;
            writer.failure = writerError;
            [submitted[0] setValue:writer forKey:@"submission"];
            if (badOrder) {
                assert(!source.gate.signaledValue &&
                       ![source.lastSubmitted completedWithError:NULL]);
                source.gate.signaledValue = 1;
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                assert(gpu_dep_word(old, 0) == UINT64_C(0x7777777777777777));
            } else {
                assert(gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444));
            }
            NV2AMetalIndependentReads *requested = reads;
            if (laterReader) {
                id<MTLBuffer> bytes = nil;
                requested = gpu_dep_read(cache, source, 48000, &bytes);
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                assert(gpu_dep_word(bytes, 0) == UINT64_C(0x4444444444444444));
            }
            other.waits = 0;
            error = nil;
            BOOL ok = [cache completeIndependentReads:requested error:&error];
            assert(ok == (mode == 3));
            assert(writer.ready && target.publicationWaits == 1 &&
                   !other.waits && (!head || !head.ready));
            if (ok) {
                assert(!error && written.completed);
                head.ready = YES;
                require([cache collectCompletedWithError:&error] &&
                            [cache discardForRestoreWithError:&error],
                        error);
            } else {
                assert(error && !written.completed &&
                       !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 60000,
                                                  4, NO));
                if (writerError)
                    assert(error == writerError);
                if (badOrder)
                    assert([error.localizedDescription
                        containsString:@"GPU readers"]);
                NSError *failure = error;
                assert(![cache completeIndependentReads:requested
                                                  error:&error] &&
                       error == failure);
            }
            cache = nil;
            require([source waitUntilIdleWithError:&error] &&
                        [other waitUntilIdleWithError:&error] &&
                        [target waitUntilIdleWithError:&error],
                    error);
            cases++;
        }
    }
    for (unsigned submitted = 0; submitted < 2; submitted++) {
        @autoreleasepool {
            NSError *error = nil;
            ReaderPublicationCommands *target =
                [[ReaderPublicationCommands alloc] initWithDevice:device
                                                            error:&error];
            IndependentReadCommands *source =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && ram, error);
            memset(ram.contents, 0x44, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            id<MTLBuffer> old = nil;
            NV2AMetalIndependentReads *reads =
                gpu_dep_read(cache, source, 32764, &old);
            require([source waitForSubmission:source.lastSubmitted
                                        error:&error],
                    error);
            [reads setValue:reader_delayed_feedback(source)
                     forKey:@"submission"];
            gpu_dep_write(cache, 32764, UINT64_C(0x7777777777777777));
            NV2AMetalSurfaceRecording *writer = cache.recording;
            id<MTLBuffer> laterBytes = nil;
            NV2AMetalSurfaceRecording *laterToken = nil;
            NV2AMetalSubmission *laterSubmission = nil;
            if (submitted) {
                require([cache submitWithError:&error] &&
                            [target waitForSubmission:target.lastSubmitted
                                                error:&error],
                        error);
                NSArray *entries = [cache valueForKey:@"submissions"];
                [entries[0] setValue:reader_delayed_feedback(target)
                              forKey:@"submission"];
                target.laterGate = [device newSharedEvent];
                id<MTL4CommandQueue> queue = object_getIvar(
                    target, class_getInstanceVariable(NV2AMetalCommands.class,
                                                      "_queue"));
                [queue waitForEvent:target.laterGate value:1];
                require([cache prepareGPUReadAtAddress:60000
                                                length:8
                                                 error:&error],
                        error);
                laterBytes = gpu_dep_copy(target, ram, 60000, nil, 0);
                laterToken = cache.recording;
                require([cache submitWithError:&error], error);
                laterSubmission = target.lastSubmitted;
                target.laterSubmission = laterSubmission;
                require([cache prepareGPUReadAtAddress:61000
                                                length:8
                                                 error:&error],
                        error);
                gpu_dep_copy(target, ram, 61000, nil, 0);
            }
            id recording = target.commandBuffer;
            uint64_t serial = target.recordingSerial;
            NV2AMetalSurfaceRecording *open = cache.recording;
            require([cache completeIndependentReads:reads error:&error], error);
            assert(gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444) &&
                   target.commandBuffer == recording &&
                   target.recordingSerial == serial &&
                   cache.recording == open && !open.submitted &&
                   !open.cancelled && !target.laterWaits && !target.idleWaits &&
                   target.publicationWaits == submitted);
            if (submitted) {
                assert(writer.completed && !laterToken.completed &&
                       !target.laterGate.signaledValue &&
                       ![laterSubmission completedWithError:NULL] &&
                       !gpu_dep_word(laterBytes, 0));
                [cache cancel];
                assert(open.cancelled);
                target.laterGate.signaledValue = 1;
                require([cache waitForSubmission:laterSubmission error:&error],
                        error);
                assert(laterToken.completed &&
                       gpu_dep_word(laterBytes, 0) ==
                           UINT64_C(0x4444444444444444));
            } else {
                assert(writer == open && !writer.submitted &&
                       gpu_dep_word(ram, 32764) ==
                           UINT64_C(0x4444444444444444));
                require([cache submitWithError:&error] &&
                            [cache waitForSubmission:target.lastSubmitted
                                               error:&error],
                        error);
                assert(writer.completed && gpu_dep_word(ram, 32764) ==
                                               UINT64_C(0x7777777777777777));
            }
            require([cache discardForRestoreWithError:&error], error);
            cases++;
        }
    }
    @autoreleasepool {
        NSError *error = nil;
        ReaderPublicationCommands *target =
            [[ReaderPublicationCommands alloc] initWithDevice:device
                                                        error:&error];
        target.omitReadEvent = YES;
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        require(target && source && ram, error);
        memset(ram.contents, 0x44, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        id<MTLBuffer> old = nil, laterBytes = nil;
        NV2AMetalIndependentReads *first =
            gpu_dep_read(cache, source, 32764, &old);
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        gpu_dep_gate(source);
        NV2AMetalIndependentReads *later =
            gpu_dep_read(cache, source, 40000, &laterBytes);
        gpu_dep_write(cache, 40000, UINT64_C(0x8888888888888888));
        require([cache submitWithError:&error] &&
                    [target waitForSubmission:target.lastSubmitted
                                        error:&error],
                error);
        NSArray *entries = [cache valueForKey:@"submissions"];
        IndependentReadReceipt *writer = reader_delayed_feedback(target);
        [entries[0] setValue:writer forKey:@"submission"];
        require([cache completeIndependentReads:first error:&error], error);
        assert(!target.publicationWaits && !writer.ready &&
               !source.gate.signaledValue &&
               ![source.lastSubmitted completedWithError:NULL] &&
               gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444));
        source.gate.signaledValue = 1;
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        assert(gpu_dep_word(laterBytes, 0) == UINT64_C(0x8888888888888888));
        assert(![cache completeIndependentReads:later error:&error] && error &&
               writer.ready && target.publicationWaits == 1);
        cache = nil;
        require([source waitUntilIdleWithError:&error] &&
                    [target waitUntilIdleWithError:&error],
                error);
        cases++;
    }
    assert(cases == 9);
    checks += cases;
    puts("Metal reader publication:9 native "
         "damaged-reader/later-source-prefix/unrelated-head/"
         "writer-error/missing-error cases;delayed writer feedback cannot "
         "publish invalid "
         "reader bytes,required writer prefix checked,unrelated queue feedback "
         "untouched;unsubmitted writes and later surface "
         "submissions/recordings stay intact;"
         "later reader failure does not poison a valid earlier reader PASS");
}
#endif
