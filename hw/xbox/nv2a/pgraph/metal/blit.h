/* Native byte blits from gl/blit.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_BLIT_H
#define HW_XBOX_NV2A_PGRAPH_METAL_BLIT_H
#import "command.h"
#include "../../nv2a_regs.h"
NS_ASSUME_NONNULL_BEGIN
/* Capture after GL-compatible pitch/tile clipping. A partial last row is
 * represented in bytes, including its original non-pixel-aligned remainder. */
typedef struct NV2AMetalBlitConfig {
    unsigned int format, operation, beta;
    unsigned int source_offset, destination_offset, source_pitch,
        destination_pitch;
    unsigned int row_bytes, rows, tail_bytes;
} NV2AMetalBlitConfig;
typedef struct NV2AMetalBlitLayout {
    NSUInteger source_length, destination_length;
    unsigned int bytes_per_pixel;
    BOOL patch_alpha;
    unsigned int alpha_value;
} NV2AMetalBlitLayout;
BOOL nv2a_metal_blit_layout(const NV2AMetalBlitConfig *_Nullable config,
                            NV2AMetalBlitLayout *_Nullable layout,
                            NSError *_Nullable *_Nullable error);
/* Encodes only native Metal 4 compute, without submitting/waiting or CPU byte
 * conversion. Aliased rows retain GL's top-down memmove/blend order; alpha
 * patching runs after all data rows. GL's BLEND_AND accesses three bytes per
 * four-byte pixel even for its Y8/R5G6B5 formats; this literal byte policy is
 * retained with full bounds checks, not claimed as Xbox packed-color blending.
 */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalBlit : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)encodeSource:(id<MTLBuffer>)source
         destination:(id<MTLBuffer>)destination
              config:(const NV2AMetalBlitConfig *)config
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
