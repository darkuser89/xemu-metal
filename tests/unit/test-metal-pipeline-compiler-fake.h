/* CPU-only pipeline compiler behavior tests. No Metal device is created.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_PIPELINE_COMPILER_FAKE_H
#define TEST_METAL_PIPELINE_COMPILER_FAKE_H
#import "hw/xbox/nv2a/pgraph/metal/pipeline-compiler.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>

@class PCTFakeDevice, PCTFakeCompiler;

@interface PCTFakeLibrary : NSObject
@property(nonatomic, weak) PCTFakeDevice *device;
@end
@implementation PCTFakeLibrary
@end

/* The controller only copies this opaque CPU descriptor. A separate copy keeps
 * the library alive; the fake compiler never keeps either alive itself. */
@interface PCTFakeDescriptor : NSObject <NSCopying>
@property(nonatomic) PCTFakeLibrary *library;
@property(nonatomic) MTL4PipelineOptions *options;
@end
@implementation PCTFakeDescriptor
- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    PCTFakeDescriptor *copy = [PCTFakeDescriptor new];
    copy.library = self.library;
    copy.options = self.options;
    return copy;
}
@end

@interface PCTFakePipeline : NSObject
@property(nonatomic, weak) PCTFakeDevice *device;
@end
@implementation PCTFakePipeline
@end

@interface PCTFakeTask : NSObject
@property(nonatomic, weak) PCTFakeCompiler *compiler;
@end
@implementation PCTFakeTask
- (MTL4CompilerTaskStatus)status
{
    assert(!"The controller must not poll a compiler task");
    return MTL4CompilerTaskStatusNone;
}
- (void)waitUntilCompleted
{
    assert(!"The controller must not wait for a compiler task");
}
@end

@interface PCTFakeJob : NSObject
@property(nonatomic, weak) PCTFakeDescriptor *descriptor;
@property(nonatomic, weak) PCTFakeLibrary *library;
@property(nonatomic, copy) MTLNewRenderPipelineStateCompletionHandler handler;
@property(nonatomic) PCTFakeTask *task;
@property(nonatomic) BOOL completed;
@end
@implementation PCTFakeJob
@end

@interface PCTFakeCompiler : NSObject
@property(nonatomic, weak) PCTFakeDevice *device;
@property(nonatomic) NSCondition *events;
@property(nonatomic) NSMutableArray<PCTFakeJob *> *jobs;
@property(nonatomic) BOOL inlineNext;
@property(nonatomic) PCTFakePipeline *inlinePipeline;
@property(nonatomic) NSError *inlineError;
- (void)finish:(NSUInteger)index
      pipeline:(PCTFakePipeline *)pipeline
         error:(NSError *)error;
- (NSUInteger)jobCount;
@end

@implementation PCTFakeCompiler
- (instancetype)init
{
    self = [super init];
    if (self) {
        _events = [NSCondition new];
        _jobs = [NSMutableArray new];
    }
    return self;
}
- (id<MTL4CompilerTask>)
    newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                     compilerTaskOptions:(MTL4CompilerTaskOptions *)options
                       completionHandler:
                           (MTLNewRenderPipelineStateCompletionHandler)handler
{
    (void)options;
    assert([(id)descriptor isKindOfClass:PCTFakeDescriptor.class] && handler);
    PCTFakeJob *job = [PCTFakeJob new];
    job.descriptor = (id)descriptor;
    job.library = ((PCTFakeDescriptor *)(id)descriptor).library;
    assert(job.library.device == self.device);
    job.handler = handler;
    PCTFakeTask *task = [PCTFakeTask new];
    task.compiler = self;
    job.task = task;
    [self.events lock];
    NSUInteger index = self.jobs.count;
    [self.jobs addObject:job];
    BOOL inlineCompletion = self.inlineNext;
    PCTFakePipeline *pipeline = self.inlinePipeline;
    NSError *error = self.inlineError;
    self.inlineNext = NO;
    self.inlinePipeline = nil;
    self.inlineError = nil;
    [self.events broadcast];
    [self.events unlock];
    if (inlineCompletion)
        [self finish:index pipeline:pipeline error:error];
    return (id)task;
}
- (NSUInteger)jobCount
{
    [self.events lock];
    NSUInteger count = self.jobs.count;
    [self.events unlock];
    return count;
}
- (void)finish:(NSUInteger)index
      pipeline:(PCTFakePipeline *)pipeline
         error:(NSError *)error
{
    [self.events lock];
    assert(index < self.jobs.count);
    PCTFakeJob *job = self.jobs[index];
    assert(!job.completed && job.handler);
    job.completed = YES;
    MTLNewRenderPipelineStateCompletionHandler handler = job.handler;
    job.handler = nil;
    job.task = nil;
    [self.events unlock];
    /* Never invoke production callbacks while holding the fake event lock. */
    handler((id)pipeline, error);
    [self.events lock];
    [self.events broadcast];
    [self.events unlock];
}
@end

@interface PCTFakeDevice : NSObject
@property(nonatomic) PCTFakeCompiler *fakeCompiler;
@property(nonatomic) NSUInteger compilerRequests;
@end
@implementation PCTFakeDevice
- (instancetype)init
{
    self = [super init];
    if (self) {
        _fakeCompiler = [PCTFakeCompiler new];
        _fakeCompiler.device = self;
    }
    return self;
}
- (BOOL)hasUnifiedMemory
{
    return YES;
}
- (BOOL)supportsFamily:(MTLGPUFamily)family
{
    return family == MTLGPUFamilyApple7 || family == MTLGPUFamilyMetal4;
}
- (id<MTL4Compiler>)newCompilerWithDescriptor:
                        (MTL4CompilerDescriptor *)descriptor
                                        error:(NSError **)error
{
    (void)descriptor;
    if (error)
        *error = nil;
    self.compilerRequests++;
    return (id)self.fakeCompiler;
}
@end

static PCTFakeLibrary *pct_library(PCTFakeDevice *device)
{
    PCTFakeLibrary *library = [PCTFakeLibrary new];
    library.device = device;
    return library;
}

static PCTFakePipeline *pct_pipeline(PCTFakeDevice *device)
{
    PCTFakePipeline *pipeline = [PCTFakePipeline new];
    pipeline.device = device;
    return pipeline;
}

static NSData *pct_key(PCTFakeLibrary *library, uint64_t tag)
{
    uint64_t words[2] = { (uintptr_t)(__bridge void *)library, tag };
    return [NSData dataWithBytes:words length:sizeof(words)];
}

static NV2AMetalPipelineCompiler *pct_shared(PCTFakeDevice *device)
{
    NSError *error = nil;
    NV2AMetalPipelineCompiler *compiler =
        [NV2AMetalPipelineCompiler sharedForDevice:(id)device error:&error];
    assert(compiler && !error && compiler.device == (id)device);
    return compiler;
}

static BOOL pct_request(NV2AMetalPipelineCompiler *compiler, NSData *key,
                        PCTFakeLibrary *library, NSUInteger *builds)
{
    return [compiler requestPipelineForKey:key
                                   library:(id)library
                         descriptorBuilder:^MTL4RenderPipelineDescriptor * {
                           ++*builds;
                           PCTFakeDescriptor *descriptor =
                               [PCTFakeDescriptor new];
                           descriptor.library = library;
                           return (id)descriptor;
                         }];
}

/* No worker races are needed for held-callback tests: every transition below
 * is driven by a real fake completion on this thread, not by a sleep. */
static void pct_two_jobs(BOOL reverse)
{
    @autoreleasepool {
        PCTFakeDevice *device = [PCTFakeDevice new];
        PCTFakeLibrary *library = pct_library(device);
        NV2AMetalPipelineCompiler *a = pct_shared(device);
        NV2AMetalPipelineCompiler *b = pct_shared(device);
        assert(a == b && device.compilerRequests == 1);
        NSUInteger builds[3] = { 0 };
        NSData *k0 = pct_key(library, 0), *k1 = pct_key(library, 1);
        NSData *k2 = pct_key(library, 2);
        assert(pct_request(a, k0, library, &builds[0]));
        assert(pct_request(b, k1, library, &builds[1]));
        assert(pct_request(b, k0, library, &builds[0]));
        assert(!pct_request(a, k2, library, &builds[2]));
        assert(builds[0] == 1 && builds[1] == 1 && !builds[2]);
        assert(device.fakeCompiler.jobCount == 2);
        NSUInteger first = reverse ? 1 : 0;
        PCTFakePipeline *p0 = pct_pipeline(device);
        [device.fakeCompiler finish:first pipeline:p0 error:nil];
        assert([a readyPipelineForKey:(first ? k1 : k0)] == (id)p0);
        assert(pct_request(b, k2, library, &builds[2]));
        assert(builds[2] == 1 && device.fakeCompiler.jobCount == 3);
        [device.fakeCompiler finish:first ^ 1
                           pipeline:pct_pipeline(device)
                              error:nil];
        [device.fakeCompiler finish:2 pipeline:pct_pipeline(device) error:nil];
        [a invalidate];
    }
}

static void pct_key_and_inline(void)
{
    @autoreleasepool {
        PCTFakeDevice *device = [PCTFakeDevice new];
        PCTFakeLibrary *library = pct_library(device);
        NV2AMetalPipelineCompiler *compiler = pct_shared(device);
        NSData *original = pct_key(library, 10);
        NSMutableData *mutable = [original mutableCopy];
        NSUInteger builds = 0;
        assert(pct_request(compiler, mutable, library, &builds));
        ((uint64_t *)mutable.mutableBytes)[1] = 11;
        assert(pct_request(compiler, original, library, &builds));
        assert(builds == 1 && device.fakeCompiler.jobCount == 1);
        PCTFakePipeline *pipeline = pct_pipeline(device);
        [device.fakeCompiler finish:0 pipeline:pipeline error:nil];
        assert([compiler readyPipelineForKey:original] == (id)pipeline);
        assert(![compiler readyPipelineForKey:mutable]);
        [compiler invalidate];
        device.fakeCompiler.inlineNext = YES;
        device.fakeCompiler.inlinePipeline = pipeline;
        assert(pct_request(compiler, original, library, &builds));
        assert([compiler readyPipelineForKey:original] == (id)pipeline);
        NSUInteger held = 0, refused = 0;
        assert(pct_request(compiler, pct_key(library, 12), library, &held));
        assert(pct_request(compiler, pct_key(library, 13), library, &held));
        assert(!pct_request(compiler, pct_key(library, 14), library, &refused));
        assert(held == 2 && refused == 0);
        [device.fakeCompiler finish:2 pipeline:pipeline error:nil];
        [device.fakeCompiler finish:3 pipeline:pipeline error:nil];
        [compiler invalidate];
        device.fakeCompiler.inlineNext = YES;
        device.fakeCompiler.inlineError = [NSError errorWithDomain:@"PCTFake"
                                                              code:8
                                                          userInfo:nil];
        assert(pct_request(compiler, original, library, &builds));
        assert(![compiler readyPipelineForKey:original]);
        NSUInteger before = builds;
        assert(!pct_request(compiler, original, library, &builds));
        assert(builds == before);
        held = 0;
        assert(pct_request(compiler, pct_key(library, 15), library, &held));
        assert(pct_request(compiler, pct_key(library, 16), library, &held));
        assert(!pct_request(compiler, pct_key(library, 17), library, &refused));
        assert(held == 2 && !refused);
        [device.fakeCompiler finish:5 pipeline:pipeline error:nil];
        [device.fakeCompiler finish:6 pipeline:pipeline error:nil];
        [compiler invalidate];
    }
}

static void pct_errors_and_invalidate(BOOL reverse)
{
    @autoreleasepool {
        PCTFakeDevice *device = [PCTFakeDevice new];
        PCTFakeLibrary *library = pct_library(device);
        NV2AMetalPipelineCompiler *compiler = pct_shared(device);
        NSError *error = [NSError errorWithDomain:@"PCTFake"
                                             code:7
                                         userInfo:nil];
        NSUInteger builds = 0;
        NSData *k0 = pct_key(library, 20), *k1 = pct_key(library, 21);
        assert(pct_request(compiler, k0, library, &builds));
        assert(pct_request(compiler, k1, library, &builds));
        [device.fakeCompiler finish:0 pipeline:nil error:nil];
        [device.fakeCompiler finish:1
                           pipeline:pct_pipeline(device)
                              error:error];
        assert(![compiler readyPipelineForKey:k0]);
        assert(![compiler readyPipelineForKey:k1]);
        assert(!pct_request(compiler, k0, library, &builds));
        assert(!pct_request(compiler, k1, library, &builds));
        assert(builds == 2);
        [compiler invalidate];
        assert(pct_request(compiler, k0, library, &builds));
        assert(pct_request(compiler, k1, library, &builds));
        [compiler invalidate];
        NSUInteger refused = 0;
        assert(!pct_request(compiler, k0, library, &refused));
        assert(!pct_request(compiler, pct_key(library, 22), library, &refused));
        assert(!refused);
        NSUInteger first = reverse ? 2 : 3;
        NSData *finishedKey = reverse ? k0 : k1;
        NSData *pendingKey = reverse ? k1 : k0;
        [device.fakeCompiler finish:first
                           pipeline:pct_pipeline(device)
                              error:nil];
        assert(![compiler readyPipelineForKey:finishedKey]);
        assert(!pct_request(compiler, pendingKey, library, &refused));
        assert(pct_request(compiler, pct_key(library, 22), library, &refused));
        assert(refused == 1);
        [device.fakeCompiler finish:5 - first
                           pipeline:pct_pipeline(device)
                              error:nil];
        assert(![compiler readyPipelineForKey:pendingKey]);
        [device.fakeCompiler finish:4 pipeline:pct_pipeline(device) error:nil];
        [compiler invalidate];
    }
}

static void pct_owner_release(void)
{
    PCTFakeDevice *device = [PCTFakeDevice new];
    PCTFakeLibrary *library = pct_library(device);
    __weak NV2AMetalPipelineCompiler *old = nil;
    @autoreleasepool {
        NV2AMetalPipelineCompiler *compiler = pct_shared(device);
        old = compiler;
        NSUInteger builds = 0;
        assert(pct_request(compiler, pct_key(library, 30), library, &builds));
        assert(pct_request(compiler, pct_key(library, 31), library, &builds));
        assert(builds == 2);
    }
    assert(old);
    NV2AMetalPipelineCompiler *fresh = pct_shared(device);
    assert(fresh == old && device.compilerRequests == 1);
    NSUInteger refused = 0;
    assert(!pct_request(fresh, pct_key(library, 32), library, &refused));
    assert(!refused);
    [device.fakeCompiler finish:0 pipeline:pct_pipeline(device) error:nil];
    assert(pct_request(fresh, pct_key(library, 32), library, &refused));
    [device.fakeCompiler finish:1 pipeline:pct_pipeline(device) error:nil];
    [device.fakeCompiler finish:2 pipeline:pct_pipeline(device) error:nil];
    [fresh invalidate];
}

static void pct_ready_and_failed_eviction(void)
{
    @autoreleasepool {
        PCTFakeDevice *device = [PCTFakeDevice new];
        PCTFakeLibrary *library = pct_library(device);
        NV2AMetalPipelineCompiler *compiler = pct_shared(device);
        NSUInteger builds = 0;
        PCTFakePipeline *first = nil;
        for (NSUInteger i = 0; i < 256; i++) {
            assert(pct_request(compiler, pct_key(library, 100 + i), library,
                               &builds));
            PCTFakePipeline *pipeline = pct_pipeline(device);
            if (!i)
                first = pipeline;
            [device.fakeCompiler finish:i pipeline:pipeline error:nil];
            assert([compiler readyPipelineForKey:pct_key(library, 100 + i)] ==
                   (id)pipeline);
        }
        assert([compiler readyPipelineForKey:pct_key(library, 100)] ==
               (id)first);
        assert(pct_request(compiler, pct_key(library, 356), library, &builds));
        [device.fakeCompiler finish:256
                           pipeline:pct_pipeline(device)
                              error:nil];
        (void)[compiler readyPipelineForKey:pct_key(library, 356)];
        assert([compiler readyPipelineForKey:pct_key(library, 100)] ==
               (id)first);
        assert(![compiler readyPipelineForKey:pct_key(library, 101)]);
        assert(pct_request(compiler, pct_key(library, 101), library, &builds));
        assert(builds == 258);
        [device.fakeCompiler finish:257 pipeline:nil error:nil];
        assert(![compiler readyPipelineForKey:pct_key(library, 101)]);
        NSUInteger before = builds;
        assert(!pct_request(compiler, pct_key(library, 101), library, &builds));
        assert(builds == before);
        [compiler invalidate];
        assert(pct_request(compiler, pct_key(library, 101), library, &builds));
        assert(builds == before + 1);
        [device.fakeCompiler finish:258
                           pipeline:pct_pipeline(device)
                              error:nil];
        [compiler invalidate];
        NSData *failed = pct_key(library, 700);
        assert(pct_request(compiler, failed, library, &builds));
        [device.fakeCompiler finish:259 pipeline:nil error:nil];
        assert(![compiler readyPipelineForKey:failed]);
        before = builds;
        assert(!pct_request(compiler, failed, library, &builds));
        assert(builds == before);
        for (NSUInteger i = 0; i < 256; i++) {
            NSData *key = pct_key(library, 701 + i);
            assert(pct_request(compiler, key, library, &builds));
            [device.fakeCompiler finish:260 + i
                               pipeline:pct_pipeline(device)
                                  error:nil];
            assert([compiler readyPipelineForKey:key]);
        }
        before = builds;
        assert(pct_request(compiler, failed, library, &builds));
        assert(builds == before + 1);
        [device.fakeCompiler finish:516
                           pipeline:pct_pipeline(device)
                              error:nil];
        [compiler invalidate];
    }
}

static void pct_builder_reservation(void)
{
    @autoreleasepool {
        PCTFakeDevice *device = [PCTFakeDevice new];
        PCTFakeLibrary *library = pct_library(device);
        NV2AMetalPipelineCompiler *compiler = pct_shared(device);
        NSData *outer = pct_key(library, 40);
        __block NSUInteger outerBuilds = 0, nestedBuilds = 0, refused = 0;
        BOOL accepted = [compiler
            requestPipelineForKey:outer
                          library:(id)library
                descriptorBuilder:^MTL4RenderPipelineDescriptor * {
                  ++outerBuilds;
                  /* Duplicate is registered before its builder. The
                   * second reservation consumes the remaining permit even
                   * though the first job has not reached the compiler API
                   * yet. */
                  assert(pct_request(compiler, outer, library, &refused));
                  assert(!refused);
                  assert(pct_request(compiler, pct_key(library, 41), library,
                                     &nestedBuilds));
                  assert(!pct_request(compiler, pct_key(library, 42), library,
                                      &refused));
                  assert(!refused && nestedBuilds == 1);
                  PCTFakeDescriptor *descriptor = [PCTFakeDescriptor new];
                  descriptor.library = library;
                  return (id)descriptor;
                }];
        assert(accepted && outerBuilds == 1 &&
               device.fakeCompiler.jobCount == 2);
        [device.fakeCompiler finish:1 pipeline:pct_pipeline(device) error:nil];
        [device.fakeCompiler finish:0 pipeline:pct_pipeline(device) error:nil];
        [compiler invalidate];
    }
}

@interface PCTFakeCaller : NSObject
@property(nonatomic) PCTFakeLibrary *library;
- (PCTFakeDescriptor *)freshDescriptor;
@end
@implementation PCTFakeCaller
- (PCTFakeDescriptor *)freshDescriptor
{
    PCTFakeDescriptor *descriptor = [PCTFakeDescriptor new];
    descriptor.library = self.library;
    return descriptor;
}
@end

static void pct_descriptor_lifetime(void)
{
    PCTFakeDevice *device = [PCTFakeDevice new];
    NV2AMetalPipelineCompiler *compiler = pct_shared(device);
    __weak PCTFakeCaller *weakCaller = nil;
    __weak PCTFakeLibrary *weakLibrary = nil;
    __weak PCTFakeDescriptor *weakDescriptor = nil;
    NSData *key = nil;
    @autoreleasepool {
        PCTFakeCaller *caller = [PCTFakeCaller new];
        caller.library = pct_library(device);
        weakCaller = caller;
        weakLibrary = caller.library;
        key = pct_key(caller.library, 50);
        assert([compiler requestPipelineForKey:key
                                       library:(id)caller.library
                             descriptorBuilder:^MTL4RenderPipelineDescriptor * {
                               return (id)[caller freshDescriptor];
                             }]);
        weakDescriptor = device.fakeCompiler.jobs[0].descriptor;
        assert(weakDescriptor && weakDescriptor.library == caller.library);
    }
    /* FakeJob's descriptor/library fields are weak and its task has no owner
     * reference. Only the controller can preserve the copied graph here. */
    assert(!weakCaller && weakLibrary && weakDescriptor);
    @autoreleasepool {
        [device.fakeCompiler finish:0 pipeline:pct_pipeline(device) error:nil];
        assert([compiler readyPipelineForKey:key]);
        [compiler invalidate];
    }
    assert(!weakDescriptor && !weakLibrary && !weakCaller);
}

/* This test is intentionally not a render fallback mock. Optional request NO
 * must leave a valid Generic draw usable; that separate integration behavior
 * belongs to A's real caller test, not a fake implementation of its policy. */
static void pipeline_compiler_fake_tests(void)
{
    pct_two_jobs(NO);
    pct_two_jobs(YES);
    pct_key_and_inline();
    pct_errors_and_invalidate(NO);
    pct_errors_and_invalidate(YES);
    pct_owner_release();
    pct_ready_and_failed_eviction();
    pct_builder_reservation();
    pct_descriptor_lifetime();
}
#endif
