#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PENDING_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PENDING_PGRAPH_H
/* PGRAPH batch descriptor. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#import "pending-journal.h"
typedef struct PGRAPHState PGRAPHState;
NS_ASSUME_NONNULL_BEGIN
@interface NV2AMetalPGRAPHPendingInputs : NSObject
/* Mirrors existing fetch batch boundaries/counts; reads no vertex values and
 * mutates no PGRAPH fields. Packed counts use the same checked layout helper.
 * GPU fetch is still responsible for DMA validity and decoded attributes. */
+ (nullable NSArray<NV2AMetalPendingInput *> *)
    inputsWithState:(PGRAPHState *_Nullable)state
              error:(NSError *_Nullable *_Nullable)error;
/* Previous inputs must be the journal's accepted snapshots. Equality is
 * checked against the live indices under pg.lock before any reuse. */
+ (nullable NSArray<NV2AMetalPendingInput *> *)
    inputsWithState:(PGRAPHState *_Nullable)state
      reusingInputs:(nullable NSArray<NV2AMetalPendingInput *> *)previous
              error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
#endif
