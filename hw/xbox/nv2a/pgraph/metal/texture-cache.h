/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_CACHE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_CACHE_H

#import "surface-cache.h"
#import "texture-upload.h"
#import "texture-sampler.h"

NS_ASSUME_NONNULL_BEGIN
typedef struct NV2AMetalTextureSource {
    NV2AMetalTextureShape shape;
    NSUInteger address, length, palette_address, palette_length;
} NV2AMetalTextureSource;

API_AVAILABLE(macos(26.0))
@interface NV2AMetalCachedTexture : NSObject
@property(nonatomic, readonly) NV2AMetalTextureBinding *binding;
@property(nonatomic, readonly) unsigned int scale;
@property(nonatomic, readonly) BOOL rectangle, signedNormalized, depth;
@property(nonatomic, readonly) BOOL mixedSignedHalf;
/* Shared by bindings of the same immutable decoded content. Becomes true
 * only after successful GPU completion and fault validation (or restore).
 * The PGRAPH owner may skip another completion wait for a validated hit. */
@property(nonatomic, readonly) BOOL decodeValidated;
/* False while GPU decode is still pending. Faults are only inspected after
 * the surface cache has successfully waited for idle; no CPU pixel decoding.
 * Frontends must validate before accepting an upload with emulation faults. */
- (BOOL)validateCompletedWithError:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithRestoredBinding:
                             (NV2AMetalTextureBinding *)binding
                                           scale:(unsigned int)scale
                                           flags:(unsigned int)flags;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* PGRAPH-thread-only LRU (512 entries), using the same VRAM/recording as the
 * surface cache. All CPU writes must pass its prepareCPUAccess/invalidate;
 * removeAllTextures before restoring/replacing VRAM or changing global scale.
 * Address/length are frontend DMA captures. Length must match native mip/face
 * layout exactly. Incompatible surface byte aliases download/decode on GPU;
 * compatible color targets copy to an immutable, scaled sampling snapshot.
 * An encoding failure cancels this recording, including pending surface work.
 * Sampling-only state changes reuse texture content. Caller retains returned
 * binding until its fragment encode returns; command resources survive LRU.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalTextureCache : NSObject
@property(nonatomic, readonly) NV2AMetalSurfaceCache *surfaces;
@property(nonatomic, readonly) NSUInteger count;
- (nullable instancetype)initWithSurfaces:(NV2AMetalSurfaceCache *)surfaces
                                    error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable NV2AMetalCachedTexture *)
    prepareSource:(const NV2AMetalTextureSource *_Nullable)source
          sampler:(const NV2AMetalSamplerConfig *_Nullable)sampler
            frame:(uint64_t)frame
            error:(NSError *_Nullable *_Nullable)error;
/* Capture immutable binding state. A hit does not open a recording or retain
 * resources in an unrelated command section. Misses still decode/copy on the
 * GPU. The eventual GPU consumer must register its own resources, as the
 * pixel encoder and texture snapshot readback already do. */
- (nullable NV2AMetalCachedTexture *)
    captureSource:(const NV2AMetalTextureSource *_Nullable)source
          sampler:(const NV2AMetalSamplerConfig *_Nullable)sampler
            frame:(uint64_t)frame
            error:(NSError *_Nullable *_Nullable)error;
- (BOOL)sourceLengthForShape:(const NV2AMetalTextureShape *_Nullable)shape
               paletteLength:(NSUInteger)paletteLength
                      length:(NSUInteger *_Nullable)length
                       error:(NSError *_Nullable *_Nullable)error;
- (void)removeAllTextures;
@end
NS_ASSUME_NONNULL_END
#endif
