/* Controlled raster feedback delivery for native Metal component tests.
 * This delays the callback, not GPU execution.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RASTER_FEEDBACK_H
#define TEST_METAL_RASTER_FEEDBACK_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
@interface ReaderRasterErrorFeedback : NSObject <MTL4CommitFeedback>
@property(nonatomic) NSError *error;
@property(nonatomic) id<MTL4CommitFeedback> native;
@end
@implementation ReaderRasterErrorFeedback
- (CFTimeInterval)GPUStartTime
{
    return _native.GPUStartTime;
}
- (CFTimeInterval)GPUEndTime
{
    return _native.GPUEndTime;
}
@end

@interface ReaderRasterFeedbackGate : NSObject
@property(nonatomic, readonly) BOOL delivered;
@property(nonatomic) NSError *injectedFailure;
- (void)receive:(id<MTL4CommitFeedback>)feedback
        handler:(MTL4CommitFeedbackHandler)handler;
- (void)releaseFeedback;
- (BOOL)waitForNativeFeedback;
@end
@implementation ReaderRasterFeedbackGate {
    dispatch_semaphore_t _ready;
    MTL4CommitFeedbackHandler _handler;
    id<MTL4CommitFeedback> _feedback;
    BOOL _releaseRequested, _delivered;
}
- (instancetype)init
{
    self = [super init];
    if (self)
        _ready = dispatch_semaphore_create(0);
    return self;
}
- (BOOL)delivered
{
    @synchronized(self) {
        return _delivered;
    }
}
- (void)receive:(id<MTL4CommitFeedback>)feedback
        handler:(MTL4CommitFeedbackHandler)handler
{
    @synchronized(self) {
        assert(!_handler && !_feedback && !_delivered);
        _handler = [handler copy];
        _feedback = feedback;
    }
    dispatch_semaphore_signal(_ready);
    [self releaseIfRequested];
}
- (void)releaseIfRequested
{
    MTL4CommitFeedbackHandler handler = nil;
    id<MTL4CommitFeedback> feedback = nil;
    @synchronized(self) {
        if (_releaseRequested && _handler) {
            handler = _handler;
            feedback = _feedback;
            _handler = nil;
            _feedback = nil;
            _delivered = YES;
        }
    }
    if (handler) {
        if (_injectedFailure) {
            ReaderRasterErrorFeedback *failed = [ReaderRasterErrorFeedback new];
            failed.native = feedback;
            failed.error = _injectedFailure;
            feedback = failed;
        }
        handler(feedback);
    }
}
- (void)releaseFeedback
{
    @synchronized(self) {
        _releaseRequested = YES;
    }
    [self releaseIfRequested];
}
- (BOOL)waitForNativeFeedback
{
    return !dispatch_semaphore_wait(
        _ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}
@end
static ReaderRasterFeedbackGate *publication_feedback_gate;
static unsigned publication_feedback_handlers;
static _Thread_local unsigned publication_feedback_depth;
static void (*publication_original_feedback)(id, SEL,
                                             MTL4CommitFeedbackHandler);
static void publication_split_feedback(id options, SEL selector,
                                       MTL4CommitFeedbackHandler handler)
{
    /* Only the two owner registrations select producer/raster. Validation
     * layers can add nested or later internal handlers of their own. */
    unsigned stage = 0;
    if (!publication_feedback_depth && NSThread.isMainThread &&
        publication_feedback_handlers < 2)
        stage = ++publication_feedback_handlers;
    publication_feedback_depth++;
    if (stage == 2) {
        ReaderRasterFeedbackGate *gate = publication_feedback_gate;
        publication_original_feedback(options, selector,
                                      ^(id<MTL4CommitFeedback> feedback) {
                                        [gate receive:feedback handler:handler];
                                      });
    } else {
        publication_original_feedback(options, selector, handler);
    }
    publication_feedback_depth--;
}
#endif
