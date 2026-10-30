/* Exact decoded texture storage, shared by upload and portable snapshots.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_STORAGE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_STORAGE_H
#import <Metal/Metal.h>
#include "texture-upload-types.h"

static inline unsigned nv2a_metal_texture_storage_bytes(unsigned storage)
{
    switch (storage) {
    case NV2AMetalTextureStoragePackedR565:
    case NV2AMetalTextureStoragePackedA1555:
    case NV2AMetalTextureStoragePackedX1555:
    case NV2AMetalTextureStoragePackedA4444:
        return 2;
    case NV2AMetalTextureStorageFloat32:
        return 16;
    case NV2AMetalTextureStorageHalf4:
    case NV2AMetalTextureStorageFloatHILO16:
        return 8;
    case NV2AMetalTextureStorageUnorm8:
    case NV2AMetalTextureStorageSnorm8:
    case NV2AMetalTextureStorageFloatY16:
    case NV2AMetalTextureStorageFloatDepthY16:
    case NV2AMetalTextureStorageFloatDepth24Fixed:
    case NV2AMetalTextureStorageFloatDepth24Float:
    case NV2AMetalTextureStorageFloatDepth16Float:
        return 4;
    default:
        return 0;
    }
}
static inline MTLPixelFormat nv2a_metal_texture_storage_format(unsigned storage)
{
    switch (storage) {
    case NV2AMetalTextureStoragePackedR565:
        return MTLPixelFormatB5G6R5Unorm;
    case NV2AMetalTextureStoragePackedA1555:
    case NV2AMetalTextureStoragePackedX1555:
        return MTLPixelFormatBGR5A1Unorm;
    case NV2AMetalTextureStoragePackedA4444:
        return MTLPixelFormatABGR4Unorm;
    case NV2AMetalTextureStorageFloat32:
        return MTLPixelFormatRGBA32Float;
    case NV2AMetalTextureStorageUnorm8:
        return MTLPixelFormatRGBA8Unorm;
    case NV2AMetalTextureStorageSnorm8:
        return MTLPixelFormatRGBA8Snorm;
    case NV2AMetalTextureStorageHalf4:
        return MTLPixelFormatRGBA16Float;
    case NV2AMetalTextureStorageFloatHILO16:
        return MTLPixelFormatRG32Float;
    case NV2AMetalTextureStorageFloatY16:
    case NV2AMetalTextureStorageFloatDepthY16:
    case NV2AMetalTextureStorageFloatDepth24Fixed:
    case NV2AMetalTextureStorageFloatDepth24Float:
    case NV2AMetalTextureStorageFloatDepth16Float:
        return MTLPixelFormatR32Float;
    default:
        return MTLPixelFormatInvalid;
    }
}
static inline MTLTextureSwizzleChannels
nv2a_metal_texture_storage_swizzle(unsigned storage)
{
    switch (storage) {
    case NV2AMetalTextureStoragePackedX1555:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
            MTLTextureSwizzleOne);
    case NV2AMetalTextureStoragePackedA4444:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
            MTLTextureSwizzleAlpha, MTLTextureSwizzleRed);
    case NV2AMetalTextureStorageFloatY16:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleOne, MTLTextureSwizzleRed, MTLTextureSwizzleRed,
            MTLTextureSwizzleOne);
    case NV2AMetalTextureStorageFloatHILO16:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
            MTLTextureSwizzleGreen, MTLTextureSwizzleOne);
    case NV2AMetalTextureStorageFloatDepthY16:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleZero, MTLTextureSwizzleZero,
            MTLTextureSwizzleZero);
    case NV2AMetalTextureStorageFloatDepth24Fixed:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleOne, MTLTextureSwizzleZero,
            MTLTextureSwizzleZero);
    case NV2AMetalTextureStorageFloatDepth24Float:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleOne, MTLTextureSwizzleOne,
            MTLTextureSwizzleZero);
    case NV2AMetalTextureStorageFloatDepth16Float:
        return MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleZero, MTLTextureSwizzleOne,
            MTLTextureSwizzleZero);
    default:
        return MTLTextureSwizzleChannelsDefault;
    }
}
/* Capture only layouts whose full logical RGBA read contract is portable.
 * Pixel-format equality alone would silently discard a texture's swizzle. */
static inline BOOL nv2a_metal_texture_storage(id<MTLTexture> texture,
                                              unsigned *storage)
{
    if (!texture)
        return NO;
    MTLTextureSwizzleChannels actual = texture.swizzle;
    for (unsigned i = NV2AMetalTextureStorageFloat32;
         i < NV2AMetalTextureStorageCount; i++) {
        MTLTextureSwizzleChannels expected =
            nv2a_metal_texture_storage_swizzle(i);
        if (texture.pixelFormat == nv2a_metal_texture_storage_format(i) &&
            actual.red == expected.red && actual.green == expected.green &&
            actual.blue == expected.blue && actual.alpha == expected.alpha) {
            if (storage)
                *storage = i;
            return YES;
        }
    }
    return NO;
}
#endif
