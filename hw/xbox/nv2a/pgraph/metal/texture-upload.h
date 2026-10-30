/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_UPLOAD_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_UPLOAD_H

#import "command.h"
#include "../../nv2a_regs.h"

NS_ASSUME_NONNULL_BEGIN

/* Captured TextureShape values; register/DMA/cache ownership stays with the
 * PGRAPH frontend. Linear images have exactly one level and no cubemap. */
typedef struct NV2AMetalTextureShape {
    unsigned int format, dimension, width, height, depth, levels;
    unsigned int pitch, min_level, max_level;
    BOOL cubemap, border;
    /* Logical RGBA bits0..3. Signed8 texels are decoded as int8/128 before
     * filtering; the separate combiner transfer is not applied here. */
    unsigned int signed_channels;
} NV2AMetalTextureShape;

API_AVAILABLE(macos(26.0))
@interface NV2AMetalTextureUploadResult : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) id<MTLBuffer> faults;
@property(nonatomic, readonly) NSUInteger sourceLength;
@property(nonatomic, readonly) unsigned int minLevel, maxLevel;
@property(nonatomic, readonly) BOOL rectangle, signedNormalized, depth;
/* Mixed Signed8: signed lanes are exact half values; unsigned lanes store
 * byte/256 and must be expanded to byte/255 before filtering. */
@property(nonatomic, readonly) BOOL mixedSignedHalf;
@end

/* Native GPU decode/unswizzle followed by Metal 4 buffer-to-texture copies.
 * Compatible linear RGBA8/R5G6B5 data uses a direct copy without
 * decode/scratch. Unsigned byte-channel decoders use RGBA8Unorm. Fully signed8
 * RGBA values are exact in RGBA16Float. Y16/depth retain one Float32 lane and
 * HILO16 two, with native read swizzles restoring the original logical RGBA
 * values. R5G6B5 retains native packed16 storage. Other packed precision
 * retains RGBA32Float. Mixed Signed8 uses an explicitly
 * marked Half4 codec; unsigned lanes are reconstructed before filtering.
 * Does not implement the texture cache,
 * VRAM coherence or sampler policy. Palette out-of-range indices set faults
 * bit0; callers must handle the fault before treating the upload as a valid
 * emulated texture. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalTextureUpload : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* CPU metadata only, using exactly the decoder's border/mip/face layout.
 * No buffers/textures are allocated and no command recording is required. */
- (BOOL)sourceLengthForShape:(const NV2AMetalTextureShape *_Nullable)shape
               paletteLength:(NSUInteger)paletteLength
                      length:(NSUInteger *_Nullable)length
                       error:(NSError *_Nullable *_Nullable)error;

/* Data/palette remain GPU-readable until command completion. Offsets and the
 * complete mip/face spans are checked before any encoding. Physical cube
 * borders and their mip levels remain in the decoded texture; sampling
 * applies the logical-to-physical face transform.
 * F16 uploads preserve exponent-zero values through the NV2A depth decode. */
- (nullable NV2AMetalTextureUploadResult *)
       encodeData:(id<MTLBuffer>)data
           offset:(NSUInteger)offset
          palette:(nullable id<MTLBuffer>)palette
    paletteOffset:(NSUInteger)paletteOffset
    paletteLength:(NSUInteger)paletteLength
            shape:(const NV2AMetalTextureShape *)shape
         commands:(NV2AMetalCommands *)commands
            error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
