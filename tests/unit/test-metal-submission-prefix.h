/* Delayed earlier feedback must not disappear behind a later receipt.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_SUBMISSION_PREFIX_H
#define TEST_METAL_SUBMISSION_PREFIX_H

static NV2AMetalCommands *prefix_commands;
static NV2AMetalSubmission *prefix_first;
static NSError *prefix_error;
static BOOL prefix_delayed;
static unsigned prefix_waits;
static void (*prefix_original_finish)(id, SEL, NSError *);
static BOOL (*prefix_original_wait)(id, SEL, NV2AMetalSubmission *, NSError **);

static void prefix_finish(id object, SEL selector, NSError *error)
{
    @synchronized(prefix_commands) {
        if (object == prefix_first) {
            assert(!error);
            prefix_delayed = YES;
            return;
        }
    }
    prefix_original_finish(object, selector, error);
}
static BOOL prefix_wait(id object, SEL selector,
                        NV2AMetalSubmission *submission, NSError **error)
{
    if (object == prefix_commands) {
        prefix_waits++;
        if (submission == prefix_first) {
            assert(prefix_delayed);
            prefix_original_finish(submission, @selector(finishWithError:),
                                   prefix_error);
            prefix_delayed = NO;
        }
    }
    return prefix_original_wait(object, selector, submission, error);
}
static void submission_prefix_tests(id<MTLDevice> device)
{
    for (unsigned failure = 0; failure < 2; failure++) {
        NSError *error = nil;
        prefix_commands = [[NV2AMetalCommands alloc] initWithDevice:device
                                                              error:&error];
        require(prefix_commands != nil, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:8192
                                options:MTLResourceStorageModeShared];
        assert(ram);
        memset(ram.contents, 0x5a, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:prefix_commands
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        id<MTLBuffer> firstBytes = encode_vram_copy(cache, 0, 4);
        NV2AMetalSurfaceRecording *firstToken = cache.recording;
        id<MTLSharedEvent> gate = [device newSharedEvent];
        Ivar queueIvar =
            class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(prefix_commands, queueIvar);
        assert(gate && queue);
        [queue waitForEvent:gate value:1];
        Method finish = class_getInstanceMethod(NV2AMetalSubmission.class,
                                                @selector(finishWithError:));
        Method wait = class_getInstanceMethod(NV2AMetalCommands.class, @selector
                                              (waitForSubmission:error:));
        assert(finish && wait);
        prefix_first = nil;
        prefix_delayed = NO;
        prefix_waits = 0;
        prefix_error = failure ?
                           [NSError errorWithDomain:@"test.earlier-feedback"
                                               code:27
                                           userInfo:nil] :
                           nil;
        prefix_original_finish =
            (void *)method_setImplementation(finish, (IMP)prefix_finish);
        require([cache submitWithError:&error], error);
        @synchronized(prefix_commands) {
            prefix_first = prefix_commands.lastSubmitted;
        }
        id<MTLBuffer> secondBytes = encode_vram_copy(cache, 4096, 4);
        NV2AMetalSurfaceRecording *secondToken = cache.recording;
        require([cache submitWithError:&error], error);
        NV2AMetalSubmission *second = prefix_commands.lastSubmitted;
        gate.signaledValue = 1;
        /* The native GPU and its slot callbacks are complete before injecting
         * delayed receipt publication. No buffer is edited while in flight. */
        require([prefix_commands waitUntilIdleWithError:&error], error);
        assert(prefix_delayed && ![prefix_first completedWithError:&error] &&
               [second completedWithError:&error] && !error);
        assert(*(uint32_t *)firstBytes.contents == 0x5a5a5a5au &&
               *(uint32_t *)secondBytes.contents == 0x5a5a5a5au);
        prefix_original_wait =
            (void *)method_setImplementation(wait, (IMP)prefix_wait);
        BOOL ok = [cache waitForSubmission:second error:&error];
        method_setImplementation(wait, (IMP)prefix_original_wait);
        method_setImplementation(finish, (IMP)prefix_original_finish);
        assert(!prefix_delayed && prefix_waits == (failure ? 1u : 2u));
        if (failure) {
            assert(!ok && error == prefix_error && !firstToken.completed &&
                   !secondToken.completed);
            assert(
                !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, 8192, NO));
            assert(![cache collectCompletedWithError:&error] &&
                   error == prefix_error);
        } else {
            require(ok, error);
            assert(firstToken.completed && secondToken.completed);
            require([cache flushWithError:&error], error);
        }
        prefix_first = nil;
        prefix_commands = nil;
        prefix_error = nil;
    }
    puts(
        "Surface submission prefix:later success cannot hide delayed earlier "
        "success/error;ordered waits,pixels,sticky failure and CPU guard PASS");
    checks += 2;
}
#endif
