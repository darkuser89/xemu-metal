/* Portable snapshots of native decoded GPU textures.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SNAPSHOT_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SNAPSHOT_H
#import "command.h"
NS_ASSUME_NONNULL_BEGIN
/* Host memory bound, not an NV2A limit. Large captures require streaming. */
#define NV2A_METAL_TEXTURE_SNAPSHOT_MAX (512u * 1024 * 1024)
/* Caller completes earlier source writes. No existing recording may be open.
 * All transfers use Metal4 blits; CPU only packs exact payload bytes.
 * Version 1 preserves RGBA32Float words in BE order. Version 2 adds an explicit
 * format word:1=RGBA8,2=RGBA16Float,3=R32(1RR1),4=RG32(RGG1),
 * 5=R32(R000),6=R32(R100),7=R32(R110),8=R32(R010),9=B5G6R5.
 * Float32/half/packed16 lanes use BE words;RGBA8 uses byte order. Compact
 * Float32 layouts preserve their exact native swizzle. No value conversion
 * occurs. The selected mip view is flattened, retaining its dimensions and
 * levels. */
API_AVAILABLE(macos(26.0))
NSData *_Nullable nv2a_metal_texture_snapshot(
    id<MTLTexture> texture, NV2AMetalCommands *commands,
    NSError *_Nullable *_Nullable error);
BOOL nv2a_metal_texture_snapshot_validate(NSData *data,
                                          NSError *_Nullable *_Nullable error);
API_AVAILABLE(macos(26.0))
id<MTLTexture> _Nullable nv2a_metal_texture_restore(
    NSData *data, NV2AMetalCommands *commands,
    NSError *_Nullable *_Nullable error);
NS_ASSUME_NONNULL_END
#endif
