/* Bounded optional Metal 4 specialization.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "pipeline-compiler.h"
#import "lru-cache.h"

@class NV2AMetalPipelineCompiler;
@interface NV2AMetalPipelineCompilerResult : NSObject
@property(nonatomic, strong) id<MTLLibrary> library;
@property(nonatomic, strong, nullable) id<MTLRenderPipelineState> pipeline;
@end
@implementation NV2AMetalPipelineCompilerResult
@end

@interface NV2AMetalPipelineCompilerJob : NSObject
@property(nonatomic, strong) NSData *key;
@property(nonatomic, strong) NSObject *generation;
@property(nonatomic, strong, nullable) NV2AMetalPipelineCompiler *owner;
@property(nonatomic, strong) id<MTLLibrary> library;
@property(nonatomic, strong, nullable) MTL4RenderPipelineDescriptor *descriptor;
@property(nonatomic, strong, nullable) id<MTL4CompilerTask> task;
@property(nonatomic, strong, nullable) id<MTLRenderPipelineState> pipeline;
@property(nonatomic) BOOL finished;
@end
@implementation NV2AMetalPipelineCompilerJob
@end

@interface NV2AMetalPipelineCompiler ()
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                               compiler:(id<MTL4Compiler>)compiler;
- (void)drainCompletedLocked;
- (void)finishJob:(NV2AMetalPipelineCompilerJob *)job
         pipeline:(nullable id<MTLRenderPipelineState>)pipeline
            error:(nullable NSError *)error;
@end

@implementation NV2AMetalPipelineCompiler {
    id<MTL4Compiler> _compiler;
    NSLock *_lock;
    NSObject *_generation;
    NSMutableDictionary<NSData *, NV2AMetalPipelineCompilerJob *> *_jobs;
    NSMutableArray<NV2AMetalPipelineCompilerJob *> *_completed;
    NV2AMetalLRUCache<NSData *, NV2AMetalPipelineCompilerResult *> *_ready;
    NSUInteger _pending;
}

+ (instancetype)sharedForDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (error)
        *error = nil;
    if (!device)
        return nil;
    static NSMapTable<id<MTLDevice>, NV2AMetalPipelineCompiler *> *controllers;
    @synchronized(NV2AMetalPipelineCompiler.class) {
        if (!controllers)
            controllers = [[NSMapTable alloc]
                initWithKeyOptions:NSPointerFunctionsWeakMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsWeakMemory
                          capacity:1];
        NV2AMetalPipelineCompiler *controller =
            [controllers objectForKey:device];
        if (!controller) {
            /* This compiler is deliberately separate from the shared module's
             * synchronous compiler and its long application lock. Metal may
             * still share internal compiler capacity; no latency guarantee.
             */
            id<MTL4Compiler> compiler =
                [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                            error:error];
            if (!compiler || compiler.device != device)
                return nil;
            controller = [[self alloc] initWithDevice:device compiler:compiler];
            if (controller)
                [controllers setObject:controller forKey:device];
        }
        return controller;
    }
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                      compiler:(id<MTL4Compiler>)compiler
{
    self = [super init];
    if (!self)
        return nil;
    _device = device;
    _compiler = compiler;
    _lock = [NSLock new];
    _generation = [NSObject new];
    _jobs = [NSMutableDictionary dictionaryWithCapacity:2];
    _completed = [NSMutableArray arrayWithCapacity:2];
    _ready = [[NV2AMetalLRUCache alloc] initWithCapacity:256];
    return _lock && _generation && _jobs && _completed && _ready ? self : nil;
}

- (void)drainCompletedLocked
{
    /* Only callers touch the LRU. Since every new reservation drains first,
     * completed plus pending jobs never exceed two, even with inline callbacks.
     */
    for (NV2AMetalPipelineCompilerJob *job in _completed) {
        if (_jobs[job.key] != job)
            continue;
        [_jobs removeObjectForKey:job.key];
        if (job.generation == _generation) {
            NV2AMetalPipelineCompilerResult *result =
                [NV2AMetalPipelineCompilerResult new];
            if (result) {
                result.library = job.library;
                result.pipeline = job.pipeline;
                _ready[job.key] = result;
            }
        }
    }
    [_completed removeAllObjects];
}

- (id<MTLRenderPipelineState>)readyPipelineForKey:(NSData *)key
{
    if (!key.length || key.length > 256 || ![_lock tryLock])
        return nil;
    [self drainCompletedLocked];
    id<MTLRenderPipelineState> pipeline = _ready[key].pipeline;
    [_lock unlock];
    return pipeline;
}

- (void)finishJob:(NV2AMetalPipelineCompilerJob *)job
         pipeline:(id<MTLRenderPipelineState>)pipeline
            error:(NSError *)error
{
    BOOL valid = pipeline && !error && pipeline.device == _device;
    [_lock lock];
    if (!job.finished && _jobs[job.key] == job) {
        job.finished = YES;
        job.pipeline = valid ? pipeline : nil;
        _pending--;
        [_completed addObject:job];
    }
    [_lock unlock];
    /* No LRU mutation or caller error publication. Break the owner/task cycle
     * outside the lock. Keep the immutable descriptor/options on the job:
     * the callback captures that job until it returns, even if a caller drains
     * this result concurrently. Do not assume native descriptor retention.
     */
    job.task = nil;
    job.owner = nil;
}

- (BOOL)requestPipelineForKey:(NSData *)key
                      library:(id<MTLLibrary>)library
            descriptorBuilder:(NV2AMetalPipelineDescriptorBuilder)builder
{
    if (!key.length || key.length > 256 || !builder ||
        library.device != _device)
        return NO;
    NSData *ownedKey = [key copy];
    if (!ownedKey || ![_lock tryLock])
        return NO;
    [self drainCompletedLocked];
    NV2AMetalPipelineCompilerResult *ready = _ready[ownedKey];
    if (ready && ready.library == library) {
        BOOL available = ready.pipeline != nil;
        [_lock unlock];
        return available;
    }
    if (ready)
        [_ready removeObjectForKey:ownedKey];
    NV2AMetalPipelineCompilerJob *existing = _jobs[ownedKey];
    if (existing) {
        BOOL current = existing.generation == _generation &&
                       existing.library == library && !existing.finished;
        [_lock unlock];
        return current;
    }
    if (_pending == 2 || !_generation) {
        [_lock unlock];
        return NO;
    }
    NV2AMetalPipelineCompilerJob *job = [NV2AMetalPipelineCompilerJob new];
    if (!job) {
        [_lock unlock];
        return NO;
    }
    job.key = ownedKey;
    job.generation = _generation;
    job.library = library;
    job.owner = self;
    _jobs[ownedKey] = job;
    _pending++;
    [_lock unlock];

    /* Nothing stores builder. Its call and all descriptor preparation happen
     * before the asynchronous API, with the permit already reserved. The
     * builder's exclusive-graph contract covers nested mutable descriptors.
     */
    MTL4RenderPipelineDescriptor *descriptor = nil;
    @try {
        descriptor = [builder() copy];
        descriptor.options = [descriptor.options copy];
    } @catch (NSException *exception) {
        (void)exception;
        [self finishJob:job pipeline:nil error:nil];
        return NO;
    }
    if (!descriptor) {
        [self finishJob:job pipeline:nil error:nil];
        return NO;
    }
    [_lock lock];
    BOOL current = job.generation == _generation;
    if (current)
        job.descriptor = descriptor;
    [_lock unlock];
    if (!current) {
        [self finishJob:job pipeline:nil error:nil];
        return NO;
    }

    id<MTL4CompilerTask> task = nil;
    @try {
        task = [_compiler
            newRenderPipelineStateWithDescriptor:descriptor
                             compilerTaskOptions:nil
                               completionHandler:^(
                                   id<MTLRenderPipelineState> pipeline,
                                   NSError *error) {
                                 /* Queue/order is not specified by the SDK.
                                  * Never touch a Draw, Command recording, guest
                                  * state or caller cache from here.
                                  */
                                 NV2AMetalPipelineCompiler *owner = job.owner;
                                 [owner finishJob:job
                                         pipeline:pipeline
                                            error:error];
                               }];
    } @catch (NSException *exception) {
        (void)exception;
        /* An exception is not a documented compiler rejection. We cannot know
         * whether work was accepted: keep the bounded permit until a real
         * callback, if any. The caller may still use its valid generic PSO.
         */
        return NO;
    }
    if (!task) {
        /* The SDK promises a nonnull task. An unexpected nil does not prove
         * that no work was accepted; only an actual callback may free this
         * permit. Without a callback it remains conservatively occupied.
         */
        return NO;
    }
    [_lock lock];
    /* Completion may already have run before new... returns its task. Never
     * resurrect the completed job's task/handler retain cycle in that case.
     */
    if (!job.finished)
        job.task = task;
    [_lock unlock];
    return YES;
}

- (void)invalidate
{
    [_lock lock];
    _generation = [NSObject new];
    [_ready removeAllObjects];
    [self drainCompletedLocked];
    /* _jobs retains reserved/running jobs. Metal exposes no task cancel API;
     * owner release/invalidate must not make their permits available early.
     */
    [_lock unlock];
}
@end
