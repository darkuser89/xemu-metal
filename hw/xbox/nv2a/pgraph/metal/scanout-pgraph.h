/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SCANOUT_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SCANOUT_PGRAPH_H
#import "surface-cache.h"
#import "scanout.h"
#import "display.h"
typedef struct NV2AState NV2AState;
NS_ASSUME_NONNULL_BEGIN
/* Immutable publication: a new texture for each completed frame. The frontend
 * retains this object while UI commands read it; later PGRAPH frames cannot
 * overwrite it. Palette and screen state are captured with the image. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalFramebuffer : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) NV2AMetalDisplayUniforms displayUniforms;
@property(nonatomic, readonly) BOOL screenOff;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* All calls on PGRAPH with pg.lock. Captures only existing GL/VGA/PVIDEO
 * interfaces. Without a cached color source, graphics/blank VGA modes decode
 * directly from VRAM on GPU. Text/glyph/cursor pixels also decode on GPU from
 * captured VGA metadata; transient invalid text dimensions yield nil. There
 * is never a GL or CPU-pixel fallback. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHScanout : NSObject
@property(nonatomic, readonly, nullable) NV2AMetalFramebuffer *frame;
- (nullable instancetype)initWithState:(NV2AState *)state
                                 cache:(NV2AMetalSurfaceCache *)cache
                                 error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)renderWithError:(NSError *_Nullable *_Nullable)error;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
#endif
