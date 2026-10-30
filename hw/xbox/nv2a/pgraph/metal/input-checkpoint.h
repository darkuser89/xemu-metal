/* PGRAPH fetch checkpoint. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_INPUT_CHECKPOINT_H
#define HW_XBOX_NV2A_PGRAPH_METAL_INPUT_CHECKPOINT_H
#import <Foundation/Foundation.h>
typedef struct PGRAPHState PGRAPHState;
NS_ASSUME_NONNULL_BEGIN
@interface NV2AMetalPGRAPHInputCheckpoint : NSObject
/* pg.lock must remain held; no guest method may run between capture/restore.
 * Fetch may change current attributes, populated flags and compressed flags.
 * This checkpoint preserves their pre-fetch state without rewinding constants,
 * surface writes, guest batches or GPU commands. No vertex math runs here. */
- (nullable instancetype)initWithState:(PGRAPHState *_Nullable)state
                                 error:(NSError *_Nullable *_Nullable)error;
- (BOOL)restoreWithState:(PGRAPHState *_Nullable)state
                   error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
#endif
