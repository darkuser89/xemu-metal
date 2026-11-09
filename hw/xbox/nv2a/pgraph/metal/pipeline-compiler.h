/* Bounded optional Metal 4 specialization.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIPELINE_COMPILER_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PIPELINE_COMPILER_H
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef MTL4RenderPipelineDescriptor *_Nullable (
    ^NV2AMetalPipelineDescriptorBuilder)(void);

/* One optional controller per exact live device. The registry is weak; each
 * accepted job holds the controller until its real completion. This prevents
 * releasing a Draw owner and acquiring a new controller from resetting cap2.
 * No command queue, draw owner, GPU recording or guest object belongs here.
 * A valid generic pipeline remains usable when optional work is refused.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPipelineCompiler : NSObject
@property(nonatomic, readonly) id<MTLDevice> device;
+ (nullable instancetype)sharedForDevice:(id<MTLDevice>)device
                                   error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Key contract: 1..256 opaque immutable recipe bytes, including the complete
 * pipeline state, recipe version and exact library identity. No source hashing
 * is required. Jobs and ready/failed entries retain the exact library strongly,
 * so its identity cannot be recycled while the corresponding key is cached.
 * Canonical-library/override admission belongs to the caller, not this class.
 * A returned pipeline still needs the caller's ordinary fresh keepAlive.
 * Lookup/request never wait for a compiler or for a busy controller lock.
 */
- (nullable id<MTLRenderPipelineState>)readyPipelineForKey:(NSData *)key;

/* YES: a new job was enqueued, or an exact current pending/success entry
 * exists. NO: budget/lock unavailable, failed entry, invalid input or optional
 * setup failure. No NSError is forwarded into the draw transaction. NO never
 * asks the caller to compile a specialization synchronously: keep a valid
 * generic PSO. Only an unavailable/ineligible generic path uses the original
 * synchronous construction, independently of this optional request's return
 * value.
 *
 * The builder executes synchronously on this caller ONLY after reserving a
 * permit, outside every controller lock. It is never stored. It must return a
 * fresh, exclusively owned descriptor graph whose functions/options/constants
 * nobody subsequently mutates. Its graph may reference only immutable compiler
 * input (not Draw/Commands/textures/argument tables). NSCopying support does
 * not document an asynchronous deep snapshot; the job owns the resulting
 * descriptor and a separate copy of its options until the callback. No task
 * wait/cancel.
 *
 * Ready AND failed entries share an LRU256. A failed optional key is not
 * retried until eviction or invalidate; its error is never a cached draw error.
 */
- (BOOL)requestPipelineForKey:(NSData *)key
                      library:(id<MTLLibrary>)library
            descriptorBuilder:(NV2AMetalPipelineDescriptorBuilder)builder;

/* Drop results and the current generation. Running/reserved jobs retain their
 * permits until actual completion (or a pre-enqueue failure); old results never
 * publish into the new generation. Invalidation does not wait or cancel.
 */
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
#endif
