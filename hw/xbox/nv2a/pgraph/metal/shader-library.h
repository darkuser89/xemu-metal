/* Shared immutable Metal4 compilation resources.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SHADER_LIBRARY_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SHADER_LIBRARY_H
#import <Metal/Metal.h>
NS_ASSUME_NONNULL_BEGIN
/* One compiler context per live device, one library per static source array.
 * Sources must be immutable, null-terminated arrays with process lifetime.
 * All modules use MSL4 safe/precise math. No argument tables, bindings or
 * textures are shared. Owners retain this module through command completion.
 * The global index is weak: it does not pin devices or unused modules.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalShaderLibrary : NSObject
@property(nonatomic, readonly) id<MTL4Compiler> compiler;
@property(nonatomic, readonly) id<MTLLibrary> library;
/* Callers creating additional pipelines serialize compiler calls with
 * @synchronized(module.compiler). The descriptors remain caller-owned. */
+ (nullable instancetype)sharedWithDevice:(id<MTLDevice>)device
                                   source:(const char *)source
                                    error:(NSError *_Nullable *_Nullable)error;
/* Lazily cache an immutable, unspecialized compute pipeline by function name.
 * Failure is not cached; callers may retry. Compiler access is serialized. */
- (nullable id<MTLComputePipelineState>)
    computeFunction:(NSString *)name
              error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
#endif
