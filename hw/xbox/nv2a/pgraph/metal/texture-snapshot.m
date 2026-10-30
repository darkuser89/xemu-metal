/* GPU texture snapshot transport; no CPU texture decode or rasterization.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "texture-snapshot.h"
#import "texture-storage.h"
#include <stdint.h>
#include <string.h>

enum {
    TextureHeaderWords = 9,
    TextureCompactHeaderWords = 10,
    TextureSubresources = 90,
};
typedef struct TextureSlice {
    NSUInteger width, height, depth, row, image, offset, packedOffset;
    unsigned face, level;
} TextureSlice;
typedef struct TextureLayout {
    unsigned type, width, height, depth, levels, count;
    unsigned bytesPerPixel, headerWords, storage;
    MTLPixelFormat format;
    NSUInteger stagingSize, packedSize;
    TextureSlice slices[TextureSubresources];
} TextureLayout;

static BOOL snapshot_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.texture-snapshot"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
static uint32_t read_word(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 |
           (uint32_t)bytes[2] << 8 | bytes[3];
}
static void write_word(uint8_t *bytes, uint32_t word)
{
    bytes[0] = word >> 24;
    bytes[1] = word >> 16;
    bytes[2] = word >> 8;
    bytes[3] = word;
}
static MTLTextureType texture_type(unsigned type)
{
    return type == 1 ? MTLTextureType2D :
           type == 2 ? MTLTextureType3D :
                       MTLTextureTypeCube;
}
static BOOL layout(unsigned type, unsigned width, unsigned height,
                   unsigned depth, unsigned levels, unsigned storage,
                   TextureLayout *out, NSError **error)
{
    MTLPixelFormat format = nv2a_metal_texture_storage_format(storage);
    if (format == MTLPixelFormatInvalid)
        return snapshot_error(error, @"Unsupported texture snapshot format");
    if (type < 1 || type > 3 || !width || !height || !depth || width > 16384 ||
        height > 16384 || depth > 16384 || (type != 2 && depth != 1) ||
        (type == 3 && width != height) || !levels || levels > 15)
        return snapshot_error(error, @"Invalid texture snapshot dimensions");
    unsigned maximum = MAX(width, MAX(height, depth)), maximumLevels = 1;
    while (maximum >>= 1)
        maximumLevels++;
    if (levels > maximumLevels)
        return snapshot_error(error,
                              @"Texture snapshot has surplus mip levels");
    TextureLayout result = { .type = type,
                             .width = width,
                             .height = height,
                             .depth = depth,
                             .levels = levels,
                             .format = format,
                             .storage = storage,
                             .bytesPerPixel =
                                 nv2a_metal_texture_storage_bytes(storage),
                             .headerWords =
                                 storage == NV2AMetalTextureStorageFloat32 ?
                                     TextureHeaderWords :
                                     TextureCompactHeaderWords };
    for (unsigned face = 0; face < (type == 3 ? 6u : 1u); face++) {
        for (unsigned level = 0; level < levels; level++) {
            NSUInteger w = MAX(1u, width >> level),
                       h = MAX(1u, height >> level),
                       d = MAX(1u, depth >> level);
            NSUInteger row =
                (w * result.bytesPerPixel + 255) & ~(NSUInteger)255;
            NSUInteger image = row * h;
            NSUInteger bytes = image * d;
            NSUInteger packed = w * h * d * result.bytesPerPixel;
            if (bytes > NV2A_METAL_TEXTURE_SNAPSHOT_MAX - result.stagingSize ||
                packed > NV2A_METAL_TEXTURE_SNAPSHOT_MAX - result.packedSize)
                return snapshot_error(
                    error, @"Texture snapshot exceeds host memory bound");
            result.slices[result.count++] = (TextureSlice){
                .width = w,
                .height = h,
                .depth = d,
                .row = row,
                .image = image,
                .offset = result.stagingSize,
                .packedOffset = result.packedSize,
                .face = face,
                .level = level,
            };
            result.stagingSize += bytes;
            result.packedSize += packed;
        }
    }
    *out = result;
    return YES;
}
static BOOL decode(NSData *data, TextureLayout *out, NSError **error)
{
    if (data.length < TextureHeaderWords * 4)
        return snapshot_error(error, @"Truncated texture snapshot header");
    const uint8_t *bytes = data.bytes;
    unsigned version = read_word(bytes + 4);
    unsigned storage;
    if (version == 1) {
        storage = NV2AMetalTextureStorageFloat32;
    } else if (version == 2 && data.length >= TextureCompactHeaderWords * 4 &&
               read_word(bytes + 36) > NV2AMetalTextureStorageFloat32 &&
               read_word(bytes + 36) < NV2AMetalTextureStorageCount) {
        storage = read_word(bytes + 36);
    } else {
        return snapshot_error(
            error, @"Unsupported texture snapshot version or format");
    }
    if (read_word(bytes) != 0x4d345458 ||
        !layout(read_word(bytes + 8), read_word(bytes + 12),
                read_word(bytes + 16), read_word(bytes + 20),
                read_word(bytes + 24), storage, out, error))
        return snapshot_error(error, @"Invalid texture snapshot header");
    uint64_t length =
        (uint64_t)read_word(bytes + 28) << 32 | read_word(bytes + 32);
    if (length != out->packedSize ||
        data.length != out->headerWords * 4 + out->packedSize)
        return snapshot_error(error,
                              @"Invalid texture snapshot payload length");
    return YES;
}
BOOL nv2a_metal_texture_snapshot_validate(NSData *data, NSError **error)
{
    TextureLayout image;
    return decode(data, &image, error);
}
static BOOL transfer(id<MTLTexture> texture, id<MTLBuffer> buffer,
                     const TextureLayout *image, BOOL upload,
                     NV2AMetalCommands *commands, NSError **error)
{
    if (commands.commandBuffer)
        return snapshot_error(error,
                              @"Texture snapshot needs an idle recording");
    if (![commands beginWithError:error])
        return NO;
    if (![commands addResource:texture error:error] ||
        ![commands addResource:buffer error:error]) {
        [commands cancel];
        return NO;
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        [commands cancel];
        return snapshot_error(error,
                              @"Cannot encode texture snapshot transfer");
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    for (unsigned i = 0; i < image->count; i++) {
        TextureSlice s = image->slices[i];
        MTLSize size = MTLSizeMake(s.width, s.height, s.depth);
        if (upload) {
            [encoder copyFromBuffer:buffer
                       sourceOffset:s.offset
                  sourceBytesPerRow:s.row
                sourceBytesPerImage:s.image
                         sourceSize:size
                          toTexture:texture
                   destinationSlice:s.face
                   destinationLevel:s.level
                  destinationOrigin:MTLOriginMake(0, 0, 0)];
        } else {
            [encoder copyFromTexture:texture
                             sourceSlice:s.face
                             sourceLevel:s.level
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:size
                                toBuffer:buffer
                       destinationOffset:s.offset
                  destinationBytesPerRow:s.row
                destinationBytesPerImage:s.image
                                 options:MTLBlitOptionNone];
        }
    }
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    if (![commands submitWithError:error] ||
        ![commands waitUntilIdleWithError:error]) {
        [commands cancel];
        return NO;
    }
    return YES;
}
NSData *nv2a_metal_texture_snapshot(id<MTLTexture> texture,
                                    NV2AMetalCommands *commands,
                                    NSError **error)
{
    unsigned type = texture.textureType == MTLTextureType2D   ? 1 :
                    texture.textureType == MTLTextureType3D   ? 2 :
                    texture.textureType == MTLTextureTypeCube ? 3 :
                                                                0;
    TextureLayout image;
    unsigned storage;
    if (!texture || !nv2a_metal_texture_storage(texture, &storage) ||
        texture.device != commands.device || texture.sampleCount != 1 ||
        texture.arrayLength != 1 ||
        !layout(type, (unsigned)texture.width, (unsigned)texture.height,
                (unsigned)texture.depth, (unsigned)texture.mipmapLevelCount,
                storage, &image, error)) {
        snapshot_error(error,
                       @"Snapshot requires a supported native texture layout");
        return nil;
    }
    if (image.stagingSize > commands.device.maxBufferLength) {
        snapshot_error(error, @"Texture snapshot exceeds device buffer length");
        return nil;
    }
    id<MTLBuffer> buffer =
        [commands.device newBufferWithLength:image.stagingSize
                                     options:MTLResourceStorageModeShared];
    if (!buffer || !transfer(texture, buffer, &image, NO, commands, error))
        return nil;
    NSMutableData *data =
        [NSMutableData dataWithLength:image.headerWords * 4 + image.packedSize];
    uint32_t header[] = { 0x4d345458,
                          image.storage == NV2AMetalTextureStorageFloat32 ? 1u :
                                                                            2u,
                          type,
                          image.width,
                          image.height,
                          image.depth,
                          image.levels,
                          (uint32_t)(image.packedSize >> 32),
                          (uint32_t)image.packedSize,
                          image.storage };
    unsigned wordBytes = image.storage == NV2AMetalTextureStorageHalf4 ||
                                 image.bytesPerPixel == 2 ?
                             2 :
                             4;
    uint8_t *output = data.mutableBytes;
    for (unsigned i = 0; i < image.headerWords; i++)
        write_word(output + i * 4, header[i]);
    for (unsigned i = 0; i < image.count; i++) {
        TextureSlice s = image.slices[i];
        for (NSUInteger z = 0; z < s.depth; z++) {
            for (NSUInteger y = 0; y < s.height; y++) {
                const uint8_t *source = (const uint8_t *)buffer.contents +
                                        s.offset + z * s.image + y * s.row;
                uint8_t *target =
                    output + image.headerWords * 4 + s.packedOffset +
                    (z * s.height + y) * s.width * image.bytesPerPixel;
                if (image.storage == NV2AMetalTextureStorageUnorm8 ||
                    image.storage == NV2AMetalTextureStorageSnorm8) {
                    memcpy(target, source, s.width * 4);
                    continue;
                }
                for (NSUInteger x = 0;
                     x < s.width * image.bytesPerPixel / wordBytes; x++) {
                    if (wordBytes == 2) {
                        uint16_t word;
                        memcpy(&word, source + x * 2, 2);
                        target[x * 2] = word >> 8;
                        target[x * 2 + 1] = word;
                    } else {
                        uint32_t word;
                        memcpy(&word, source + x * 4, 4);
                        write_word(target + x * 4, word);
                    }
                }
            }
        }
    }
    return [data copy];
}
id<MTLTexture> nv2a_metal_texture_restore(NSData *data,
                                          NV2AMetalCommands *commands,
                                          NSError **error)
{
    TextureLayout image;
    if (!decode(data, &image, error))
        return nil;
    if (image.stagingSize > commands.device.maxBufferLength) {
        snapshot_error(error, @"Texture snapshot exceeds device buffer length");
        return nil;
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = texture_type(image.type);
    descriptor.pixelFormat = image.format;
    descriptor.swizzle = nv2a_metal_texture_storage_swizzle(image.storage);
    descriptor.width = image.width;
    descriptor.height = image.height;
    descriptor.depth = image.depth;
    descriptor.mipmapLevelCount = image.levels;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage =
        MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture =
        [commands.device newTextureWithDescriptor:descriptor];
    id<MTLBuffer> buffer =
        [commands.device newBufferWithLength:image.stagingSize
                                     options:MTLResourceStorageModeShared];
    if (!texture || !buffer) {
        snapshot_error(error, @"Cannot allocate texture snapshot resources");
        return nil;
    }
    unsigned wordBytes = image.storage == NV2AMetalTextureStorageHalf4 ||
                                 image.bytesPerPixel == 2 ?
                             2 :
                             4;
    const uint8_t *input = data.bytes;
    for (unsigned i = 0; i < image.count; i++) {
        TextureSlice s = image.slices[i];
        for (NSUInteger z = 0; z < s.depth; z++) {
            for (NSUInteger y = 0; y < s.height; y++) {
                const uint8_t *source =
                    input + image.headerWords * 4 + s.packedOffset +
                    (z * s.height + y) * s.width * image.bytesPerPixel;
                uint8_t *target = (uint8_t *)buffer.contents + s.offset +
                                  z * s.image + y * s.row;
                if (image.storage == NV2AMetalTextureStorageUnorm8 ||
                    image.storage == NV2AMetalTextureStorageSnorm8) {
                    memcpy(target, source, s.width * 4);
                    continue;
                }
                for (NSUInteger x = 0;
                     x < s.width * image.bytesPerPixel / wordBytes; x++) {
                    if (wordBytes == 2) {
                        uint16_t word =
                            (uint16_t)source[x * 2] << 8 | source[x * 2 + 1];
                        memcpy(target + x * 2, &word, 2);
                    } else {
                        uint32_t word = read_word(source + x * 4);
                        memcpy(target + x * 4, &word, 4);
                    }
                }
            }
        }
    }
    return transfer(texture, buffer, &image, YES, commands, error) ? texture :
                                                                     nil;
}
