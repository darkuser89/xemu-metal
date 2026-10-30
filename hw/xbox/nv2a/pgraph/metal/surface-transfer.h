/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_TRANSFER_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_TRANSFER_H

#import "command.h"
#include "../../nv2a_regs.h"

NS_ASSUME_NONNULL_BEGIN

/* Original NV097 surface format numbers. Dimensions include the frontend's
 * AA/clip extent; scale is the separate integer surface enhancement factor.
 * color=NO supports fixed Z16/Z24S8 and positive NV2A F16/F24. Floating
 * surfaces store ordered guest codes normalized by the code-space maximum;
 * Clear and transfer preserve raw words rather than decode physical depth.
 * NaN native depth packs to zero as a defined robustness choice; this is not
 * a claim about Xbox behavior.
 * R8/RG8 and X/Z alpha semantics follow GL's existing transfer layouts. */
typedef struct NV2AMetalSurfaceConfig {
    unsigned int format, width, height, pitch, scale;
    BOOL color, swizzle, floating_depth;
} NV2AMetalSurfaceConfig;

typedef struct NV2AMetalSurfaceLayout {
    MTLPixelFormat pixel_format;
    unsigned int bytes_per_pixel;
    NSUInteger source_length, reservation_length;
} NV2AMetalSurfaceLayout;

/* CPU layout validation shared by transfer allocation and cache lookup.
 * reservation_length includes every pitched row, matching GL's overlaps. */
BOOL nv2a_metal_surface_layout(const NV2AMetalSurfaceConfig *_Nullable config,
                               NV2AMetalSurfaceLayout *_Nullable layout,
                               NSError *_Nullable *_Nullable error);

/* A native, single-sample private render target with immutable layout.
 * Byte-identical linear color transfers use Metal 4 blits directly. Compute
 * rearranges bytes/replicates pixels for other layouts. The PGRAPH frontend
 * owns VRAM coherence, dirty tracking, overlaps,
 * DMA validation and scheduling. This object is not a surface cache. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalSurfaceTransfer : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) NV2AMetalSurfaceConfig config;
/* Actual touched byte span, excluding final row padding. The frontend's VRAM
 * overlap reservation may include additional pitch padding. */
@property(nonatomic, readonly) NSUInteger sourceLength;

- (nullable instancetype)
    initWithDevice:(id<MTLDevice>)device
            config:(const NV2AMetalSurfaceConfig *_Nullable)config
             error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Buffer spans are checked before encoding. Caller must keep source bytes
 * GPU-readable until completion; the command slot retains resources. CPU
 * VRAM capture/copy is outside this object; no CPU pixel transform is used. */
- (BOOL)encodeUploadFromBuffer:(id<MTLBuffer>)source
                        offset:(NSUInteger)offset
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError *_Nullable *_Nullable)error;

/* Downscale picks the first sample of each replicated block as GL does.
 * Without downscale, output width/height/pitch are multiplied by scale.
 * flip reverses physical rows before that selection. swizzle applies only to
 * swizzled surfaces and requires downscale or scale=1. Linear pitch padding
 * and bytes outside the actual touched span remain unchanged. Byte UNORM
 * color targets read selected texels directly when a byte-identical blit is
 * ineligible; packed color and depth/stencil retain raw staging in that case. */
- (BOOL)encodeDownloadToBuffer:(id<MTLBuffer>)destination
                        offset:(NSUInteger)offset
                       swizzle:(BOOL)swizzle
                          flip:(BOOL)flip
                     downscale:(BOOL)downscale
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
