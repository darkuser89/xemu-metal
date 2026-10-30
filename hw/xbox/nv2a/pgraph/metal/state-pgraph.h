#ifndef HW_XBOX_NV2A_PGRAPH_METAL_STATE_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_STATE_PGRAPH_H
/* Two-phase native State/PGRAPH transaction.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "vertex-state.h"
typedef struct PGRAPHState PGRAPHState;
NS_ASSUME_NONNULL_BEGIN
API_AVAILABLE(macos(26.0))
@interface NV2AMetalStateTransaction : NSObject
@property(nonatomic, readonly) NV2AMetalStateResult *result;
/* pg.lock must remain held across execution/staging/commit. The draw frontend
 * must finish pending vertex transforms before executing a State program.
 * Commit validates the original constant context and changes only GPU-marked
 * constants, ORing their dirty bits. A transaction can commit only once. */
- (BOOL)commitWithState:(PGRAPHState *_Nullable)state
                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHStateProgram : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
/* Starts at the raw LAUNCH method's program_start, not the ordinary vertex
 * program's CHEOPS_PROGRAM_START. v0 is the separate launch-data register.
 * This does not mutate PGRAPH or finish any primitive. Caller stages its new
 * immutable capture before committing the returned transaction. */
- (nullable NV2AMetalStateTransaction *)
    executeWithState:(PGRAPHState *_Nullable)state
        programStart:(NSUInteger)start
               error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
#endif
