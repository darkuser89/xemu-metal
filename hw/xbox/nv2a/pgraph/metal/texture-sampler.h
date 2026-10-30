/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLER_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_SAMPLER_H

#import "command.h"
#include "texture-sampler-types.h"
#include "../../nv2a_regs.h"

NS_ASSUME_NONNULL_BEGIN

/* filter/address are original PGRAPH register words. anisotropy is the
 * decoded maximum (1, 2, 4, 8); levels refer to the uploaded texture. */
typedef struct NV2AMetalSamplerConfig {
    unsigned int filter, address, border_color, anisotropy;
    unsigned int min_level, max_level;
    BOOL rectangle, bordered, hilo16;
    unsigned int signed_channels; // Logical RGBA bits0..3 for border texels.
} NV2AMetalSamplerConfig;

float nv2a_metal_texture_lod_bias(unsigned int filter);
BOOL nv2a_metal_sampling_validate(
    const NV2AMetalSamplingUniforms *_Nullable sampling,
    NSError *_Nullable *_Nullable error);

API_AVAILABLE(macos(26.0))
@interface NV2AMetalTextureBinding : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) id<MTLSamplerState> sampler;
@property(nonatomic, readonly) NV2AMetalSamplingUniforms sampling;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* Pixel-stage sampling uses MSL texel reads, including RGBA32Float on M1/M2
 * where linear hardware filtering is unavailable. This preserves arbitrary
 * ARGB border colors and the full signed S4.8 bias. GL's CLAMP_OGL and
 * convolution-mag approximations are retained; anisotropy is a deterministic
 * footprint approximation, not a claim of Xbox hardware equivalence. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalTextureSampler : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Copy sampling into the texture stage and bind texture/sampler together.
 * Supports the native color/decoded-texture formats; integer/depth/compressed
 * input resources are rejected. The returned view selects the base/max mip
 * range. Commands retain bound resources; the caller owns this result until
 * encoding has returned. */
/* Restore the exact manual sampling state on a flattened mip-view texture. */
- (nullable NV2AMetalTextureBinding *)
    bindingForSnapshotTexture:(id<MTLTexture>)texture
                     sampling:
                         (const NV2AMetalSamplingUniforms *_Nullable)sampling
                        error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalTextureBinding *)
    bindingForTexture:(id<MTLTexture>)texture
               config:(const NV2AMetalSamplerConfig *_Nullable)config
                error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
