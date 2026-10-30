/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_PGRAPH_H
#import "texture-cache.h"
#import "pixel-shader.h"
typedef struct NV2AState NV2AState;

NS_ASSUME_NONNULL_BEGIN
/* Immutable four-stage capture, retained independently of cache eviction.
 * Retain until fragment encode returns; bindings
 * exported below are borrowed from this snapshot. Non-texture pixel state is
 * untouched. Unbound stages export nil textures/samplers and zero metadata. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHTextureSnapshot : NSObject
@property(nonatomic, readonly) unsigned int enabledMask;
+ (instancetype)emptySnapshot;
- (nullable NSData *)snapshotWithCommands:(NV2AMetalCommands *)commands
                                    error:(NSError *_Nullable *_Nullable)error;
+ (BOOL)validateSnapshot:(NSData *)data
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                   error:(NSError *_Nullable *_Nullable)error;
+ (BOOL)validateSnapshot:(NSData *)data
                   error:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithSnapshot:(NSData *)data
                                 commands:(NV2AMetalCommands *)commands
                                    error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalCachedTexture *)textureAtIndex:(NSUInteger)index;
- (BOOL)applyToUniforms:(NV2AMetalPixelUniforms *_Nullable)uniforms
               textures:(NV2AMetalPixelTexture *_Nullable)textures
                  error:(NSError *_Nullable *_Nullable)error;
- (BOOL)validateCompletedWithError:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* Requires pg.lock and the live VRAM cache owned by the surface adapter.
 * NV2AState/VRAM outlive this object. TCG CPU hooks and NV2ATEX dirty pages
 * maintain source versions; other hosts reject GPU/CPU ownership conflicts.
 * Palette decodes submit and wait before return so faults cannot
 * reach a draw; prepare render attachments AFTER this call, since that wait
 * ends a recording. Other sources stay asynchronous on the same native command
 * queue. Flush cache content on save/restore/scale teardown along with surface
 * flush. This adapter is not an active renderer registration. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHTextures : NSObject
@property(nonatomic, readonly) NV2AMetalTextureCache *cache;
- (nullable instancetype)initWithState:(NV2AState *)state
                              surfaces:(NV2AMetalSurfaceCache *)surfaces
                                 error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable NV2AMetalPGRAPHTextureSnapshot *)prepareWithError:
    (NSError *_Nullable *_Nullable)error;
- (void)flush;
- (void)close;
@end
NS_ASSUME_NONNULL_END
#endif
