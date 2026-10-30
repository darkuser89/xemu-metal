/* Native Metal4 NV2A state-program execution.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_STATE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_STATE_H

#import "command.h"

NS_ASSUME_NONNULL_BEGIN
/* Software policy for the documented XFCTX access apertures, not new
 * hardware bits. Forbidden-access result values are not specified by the
 * family documentation; this wrapper reports a validation failure. */
typedef NS_ENUM(unsigned, NV2AMetalStateAccess) {
    NV2AMetalStateUserOnly = 0,
    NV2AMetalStateFull = 1,
};

API_AVAILABLE(macos(26.0))
@interface NV2AMetalStateResult : NSObject
/* Raw 192x4 DWORD constants and 192 DWORD written flags, each 0 or 1.
 * Both snapshots are independent of the executor's next recording. */
@property(nonatomic, readonly) NSData *constants;
@property(nonatomic, readonly) NSData *written;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* Owns its command queue. Caller serializes prior XF work before invoking
 * this synchronous operation. Return occurs only after GPU completion and
 * fault inspection; it never modifies caller buffers or PGRAPH state.
 * Only state programs are accepted, with v0 input and constant destinations.
 * FULL/USER policies apply to direct/relative reads and context writes. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalStateProgram : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable NV2AMetalStateResult *)executeTokens:(const uint32_t *)tokens
                                          length:(NSUInteger)length
                                       constants:(NSData *)constants
                                          launch:(NSData *)launch
                                           error:(NSError *_Nullable *_Nullable)
                                                     error;
- (nullable NV2AMetalStateResult *)executeTokens:(const uint32_t *)tokens
                                          length:(NSUInteger)length
                                       constants:(NSData *)constants
                                          launch:(NSData *)launch
                                          access:(NV2AMetalStateAccess)access
                                           error:(NSError *_Nullable *_Nullable)
                                                     error;
@end

NS_ASSUME_NONNULL_END
#endif
