/* SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_BLIT_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_BLIT_PGRAPH_H
#import "blit.h"
#import "surface-pgraph.h"
typedef struct NV2AState NV2AState;
NS_ASSUME_NONNULL_BEGIN
/* PGRAPH-thread adapter with pg.lock held. Captures existing NV062/NV09F/NV012
 * state, checks full DMA spans and calls the original tile clipping helper.
 * GPU-owned source/destination pixels are preserved with native transfers.
 * Waits for this blit's submission prefix before publishing RAM dirty
 * notifications; unrelated independent readers remain in flight. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHBlit : NSObject
- (nullable instancetype)initWithState:(NV2AState *)state
                              surfaces:(NV2AMetalPGRAPHSurfaces *)surfaces
                                 error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)blitWithError:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
