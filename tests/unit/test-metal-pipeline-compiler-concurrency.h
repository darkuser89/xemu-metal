/* CPU-only pipeline compiler concurrency tests. No Metal device is created.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_PIPELINE_COMPILER_CONCURRENCY_H
#define TEST_METAL_PIPELINE_COMPILER_CONCURRENCY_H
#include "test-metal-pipeline-compiler-fake.h"
#include <dispatch/dispatch.h>

@interface PCCSchedule : NSObject
@property(nonatomic) NSCondition *condition;
@property(nonatomic) NSUInteger arrived, start, published;
@property(nonatomic) BOOL capacityChecked, returnCallbacks;
- (void)arriveAndWait:(NSUInteger)index;
- (void)publishAndWait:(NSUInteger)index;
- (void)waitArrived:(NSUInteger)mask;
- (void)waitPublished:(NSUInteger)mask;
- (void)releaseStart:(NSUInteger)mask;
- (void)markCapacityChecked;
- (void)waitCapacityChecked;
- (void)releaseReturns;
@end

@implementation PCCSchedule
- (instancetype)init
{
    self = [super init];
    if (self)
        _condition = [NSCondition new];
    return self;
}
- (void)arriveAndWait:(NSUInteger)index
{
    [self.condition lock];
    self.arrived |= 1u << index;
    [self.condition broadcast];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!(self.start & (1u << index)))
        assert([self.condition waitUntilDate:deadline]);
    [self.condition unlock];
}
- (void)publishAndWait:(NSUInteger)index
{
    [self.condition lock];
    self.published |= 1u << index;
    [self.condition broadcast];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!self.returnCallbacks)
        assert([self.condition waitUntilDate:deadline]);
    [self.condition unlock];
}
- (void)waitArrived:(NSUInteger)mask
{
    [self.condition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while ((self.arrived & mask) != mask)
        assert([self.condition waitUntilDate:deadline]);
    [self.condition unlock];
}
- (void)waitPublished:(NSUInteger)mask
{
    [self.condition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while ((self.published & mask) != mask)
        assert([self.condition waitUntilDate:deadline]);
    [self.condition unlock];
}
- (void)releaseStart:(NSUInteger)mask
{
    [self.condition lock];
    self.start |= mask;
    [self.condition broadcast];
    [self.condition unlock];
}
- (void)markCapacityChecked
{
    [self.condition lock];
    self.capacityChecked = YES;
    [self.condition broadcast];
    [self.condition unlock];
}
- (void)waitCapacityChecked
{
    [self.condition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!self.capacityChecked)
        assert([self.condition waitUntilDate:deadline]);
    [self.condition unlock];
}
- (void)releaseReturns
{
    [self.condition lock];
    self.returnCallbacks = YES;
    [self.condition broadcast];
    [self.condition unlock];
}
@end

@interface PCCFakeCompiler : PCTFakeCompiler
@property(nonatomic) PCCSchedule *schedule;
@end
@implementation PCCFakeCompiler
- (id<MTL4CompilerTask>)
    newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                     compilerTaskOptions:(MTL4CompilerTaskOptions *)options
                       completionHandler:
                           (MTLNewRenderPipelineStateCompletionHandler)handler
{
    NSUInteger index = self.jobCount;
    if (index >= 2)
        return [super newRenderPipelineStateWithDescriptor:descriptor
                                       compilerTaskOptions:options
                                         completionHandler:handler];
    PCCSchedule *schedule = self.schedule;
    /* This wrapper holds the actual registered completion block and its job
     * until the callback thread returns. It never captures the descriptor,
     * library, caller controller, Device or a Draw owner itself. */
    return [super newRenderPipelineStateWithDescriptor:descriptor
                                   compilerTaskOptions:options
                                     completionHandler:^(
                                         id<MTLRenderPipelineState> pipeline,
                                         NSError *error) {
                                       [schedule arriveAndWait:index];
                                       handler(pipeline, error);
                                       [schedule publishAndWait:index];
                                     }];
}
@end

static void pcc_run(BOOL reverse)
{
    @autoreleasepool {
        NSUInteger firstMask = reverse ? 2 : 1;
        PCTFakeDevice *device = [PCTFakeDevice new];
        PCCFakeCompiler *native = [PCCFakeCompiler new];
        native.device = device;
        native.schedule = [PCCSchedule new];
        device.fakeCompiler = native;
        PCTFakeLibrary *library = nil;
        @autoreleasepool {
            library = pct_library(device);
        }
        __weak PCTFakeLibrary *weakLibrary = library;
        NSData *k0 = pct_key(library, 0), *k1 = pct_key(library, 1);
        NSData *k2 = pct_key(library, 2), *k3 = pct_key(library, 3);
        __weak NV2AMetalPipelineCompiler *weakController = nil;
        @autoreleasepool {
            NV2AMetalPipelineCompiler *owner = pct_shared(device);
            weakController = owner;
            NSUInteger builds = 0;
            assert(pct_request(owner, k0, library, &builds));
            assert(pct_request(owner, k1, library, &builds));
            assert(builds == 2 && native.jobCount == 2);
        }
        @autoreleasepool {
            assert(weakController);
        }
        __weak PCTFakeDescriptor *d0 = nil;
        __weak PCTFakeDescriptor *d1 = nil;
        @autoreleasepool {
            d0 = native.jobs[0].descriptor;
            d1 = native.jobs[1].descriptor;
            assert(d0 && d1);
        }
        dispatch_group_t callbacks = dispatch_group_create();
        dispatch_group_t caller = dispatch_group_create();
        dispatch_queue_t workers =
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        for (NSUInteger i = 0; i < 2; i++) {
            dispatch_group_async(callbacks, workers, ^{
              @autoreleasepool {
                  [native finish:i pipeline:pct_pipeline(device) error:nil];
              }
            });
        }
        __block NSUInteger acceptedBuilders = 0, refusedBuilders = 0;
        __block NSUInteger nilBuilders = 0;
        dispatch_group_async(caller, workers, ^{
          @autoreleasepool {
              [native.schedule waitArrived:3];
              NV2AMetalPipelineCompiler *owner = pct_shared(device);
              PCTFakeLibrary *activeLibrary = weakLibrary;
              assert(activeLibrary && owner == weakController);
              assert(device.compilerRequests == 1);
              /* All original caller references have gone. A fresh lookup
               * still cannot reset two real held compiler permits. */
              assert(!pct_request(owner, k2, activeLibrary, &refusedBuilders));
              assert(!refusedBuilders && native.jobCount == 2);
              assert(![owner readyPipelineForKey:k0]);
              [owner invalidate];
              assert(!pct_request(owner, k0, activeLibrary, &refusedBuilders));
              assert(!pct_request(owner, k2, activeLibrary, &refusedBuilders));
              assert(!refusedBuilders && native.jobCount == 2);
              [native.schedule markCapacityChecked];

              [native.schedule waitPublished:firstMask];
              assert(![owner readyPipelineForKey:k0]);
              assert(pct_request(owner, k2, activeLibrary, &acceptedBuilders));
              assert(acceptedBuilders == 1 && native.jobCount == 3);
              assert(!pct_request(owner, k3, activeLibrary, &refusedBuilders));
              assert(!refusedBuilders);
              /* Exactly one actual callback released one permit. The other
               * original callback is still before its production handler. */
              [native finish:2 pipeline:pct_pipeline(device) error:nil];
              [owner invalidate];
              [native.schedule releaseStart:3 ^ firstMask];
              for (NSUInteger i = 0; i < 256; i++) {
                  assert(![owner readyPipelineForKey:k0]);
                  assert(![owner readyPipelineForKey:k1]);
                  [owner invalidate];
                  NSData *key = pct_key(activeLibrary, 100 + i);
                  BOOL accepted = [owner
                      requestPipelineForKey:key
                                    library:(id)activeLibrary
                          descriptorBuilder:^MTL4RenderPipelineDescriptor * {
                            ++nilBuilders;
                            return nil;
                          }];
                  assert(!accepted);
              }
              [native.schedule waitPublished:3];
              assert(![owner readyPipelineForKey:k0]);
              assert(![owner readyPipelineForKey:k1]);
              [owner invalidate];
              assert(native.jobCount == 3 && nilBuilders <= 256);
          }
        });
        [native.schedule waitCapacityChecked];
        [native.schedule releaseStart:firstMask];
        assert(dispatch_group_wait(caller, dispatch_time(DISPATCH_TIME_NOW,
                                                         10 * NSEC_PER_SEC)) ==
               0);
        assert(acceptedBuilders == 1 && !refusedBuilders);
        library = nil;
        /* Both callbacks published, callers drained/invalidated and released
         * the controller, yet the actual completion blocks are still live on
         * their respective callback stacks. FakeJob only has weak graph refs.
         */
        @autoreleasepool {
            assert(d0 && d1 && weakLibrary);
            assert(d0.library == weakLibrary && d1.library == weakLibrary);
        }
        [native.schedule releaseReturns];
        assert(dispatch_group_wait(
                   callbacks,
                   dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
        assert(!d0 && !d1 && !weakLibrary && !weakController);
        assert(native.jobCount == 3 && device.compilerRequests == 1);
    }
}

static void pipeline_compiler_concurrency_tests(void)
{
    pcc_run(NO);
    pcc_run(YES);
}
#endif
